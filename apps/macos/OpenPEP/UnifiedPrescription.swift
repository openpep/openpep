// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// One editable list; output documents retain independent identities and number reservations.
struct UnifiedPrescription: Codable, Equatable {
    static let marker = "<!-- openpep:prescription-v1 "
    var draft: CockpitPrescription
    var legacyText: String = ""
    var locked = false
    var resumedDocumentID: UUID? = nil

    init(patient: PatientSummary, text: String) throws {
        if text.contains(Self.marker) {
            guard let start = text.range(of: Self.marker), let end = text.range(of: " -->", range: start.upperBound..<text.endIndex),
                  text[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let data = Data(base64Encoded: String(text[start.upperBound..<end.lowerBound])), data.count <= 2_000_000 else {
                throw CockpitError.message("O rascunho da receita não pôde ser lido. O texto original foi preservado.")
            }
            self = try JSONDecoder().decode(Self.self, from: data)
            guard Set(draft.medications.map(\.id)).count == draft.medications.count,
                  draft.medications.count <= 100 else { throw CockpitError.invalidRegistry }
        } else {
            draft = CockpitPrescription(patient: patient)
            legacyText = text
        }
    }
    func proposal(for patient: PatientSummary) throws -> Self {
        var result = try Self(patient: patient, text: "")
        result.legacyText = legacyText
        result.draft.medications = draft.medications.map { item in
            var copy = item; copy.id = UUID(); return copy
        }
        return result
    }
    var text: String {
        guard !legacyText.isEmpty || draft.medications.contains(where: { !$0.nome.isEmpty || !$0.posologia.isEmpty }) else { return "" }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(self) else { return "" }
        return (legacyText.isEmpty ? "" : legacyText + "\n\n") + Self.medicationText(draft.medications)
            + "\n\n" + Self.marker + data.base64EncodedString() + " -->"
    }
    /// Keep literal clinical prose available to the existing LLM/IPS extraction pipeline.
    /// The comment is UI state, not another clinical source or an instruction.
    static func clinicalText(_ text: String) -> String {
        text.replacingOccurrences(of: #"<!-- openpep:prescription-v1 [A-Za-z0-9+/=]+ -->"#, with: "", options: .regularExpression)
    }
    static func medicationText(_ items: [CockpitPrescription.Medication]) -> String {
        items.filter { !$0.nome.isEmpty }.map { medication in
            let description = [medication.nome, medication.concentracao, medication.forma].filter { !$0.isEmpty }.joined(separator: " · ")
            let quantity = [medication.quantidade, medication.unidade].filter { !$0.isEmpty }.joined(separator: " ")
            return "### " + description + "\n" + (quantity.isEmpty ? "" : "Quantidade: " + quantity + "\n")
                + medication.posologia + (medication.orientacoes.isEmpty ? "" : "\n" + medication.orientacoes)
        }.joined(separator: "\n\n")
    }
    static func type(for medication: CockpitPrescription.Medication, catalog: CockpitMedicationCatalog) throws -> String {
        if let value = medication.recipeOverride {
            guard value == "SIMPLE" || SNCRRegistry.types.contains(value) else { throw CockpitError.invalidRegistry }
            return value
        }
        if let entry = medication.assistance {
            guard entry.matches(medication) else { throw CockpitError.message("Confira a apresentação de \(medication.nome) na busca antes de revisar.") }
            return entry.recipeType
        }
        // CMED is a product catalog, not a regulatory classification. Known restricted
        // substances must use the curated presentation, including concentration exceptions.
        let words = PatientSearch.normalize([medication.nome, medication.catalog?.substance ?? ""].joined(separator: " "))
        let candidates = catalog.entries.filter { entry in entry.keys.contains { key in
            let normalized = PatientSearch.normalize(key)
            return normalized.count >= 3 && (" " + words + " ").contains(" " + normalized + " ")
        } }
        if !candidates.isEmpty {
            throw CockpitError.message("Escolha a apresentação de \(medication.nome) na busca para definir o receituário automaticamente.")
        }
        return "SIMPLE"
    }
    mutating func choose(_ entry: CockpitMedicationCatalog.Entry, for id: UUID) throws {
        guard let index = draft.medications.firstIndex(where: { $0.id == id }) else { throw CockpitError.invalidRegistry }
        var single = draft; single.medications = [draft.medications[index]]
        try single.choose(entry, for: id)
        draft.medications[index] = single.medications[0]
    }
    @MainActor func reviewedDocuments(catalog: CockpitMedicationCatalog, renderer: CockpitPDFRenderer) async throws -> [CockpitPrescription] {
        let proposed = try documents(catalog: catalog)
        if !locked {
            // A missing mandatory field in any output must be corrected before the first reservation.
            for document in proposed {
                if document.tipo == "SIMPLE" {
                    _ = try ClinicalDocumentPDF.make(title: "Receita simples", patientName: document.paciente.nome,
                        professional: document.prescriber.nome, body: Self.medicationText(document.medications))
                } else { _ = try await renderer.render(document.input()) }
            }
        }
        return proposed
    }
    func documents(catalog: CockpitMedicationCatalog) throws -> [CockpitPrescription] {
        if let resumedDocumentID {
            guard locked, resumedDocumentID == draft.id else { throw CockpitError.invalidRegistry }
            _ = try draft.input()
            return [draft]
        }
        guard legacyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CockpitError.message("Confira o texto anterior e inclua seus medicamentos na lista antes de revisar.")
        }
        var simple: [CockpitPrescription.Medication] = [], regulated: [CockpitPrescription] = []
        for medication in draft.medications {
            guard !medication.nome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !medication.posologia.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !medication.posologia.contains("__"), !medication.tempo.contains("__") else {
                throw CockpitError.message("Preencha medicamento e posologia de cada item antes de revisar.")
            }
            let type = try Self.type(for: medication, catalog: catalog)
            if type == "SIMPLE" { simple.append(medication) }
            else {
                var document = draft; document.id = medication.id; document.tipo = type; document.medications = [medication]
                _ = try document.input()
                regulated.append(document)
            }
        }
        if !simple.isEmpty {
            var document = draft; document.tipo = "SIMPLE"; document.medications = simple
            regulated.insert(document, at: 0)
        }
        guard !regulated.isEmpty else { throw ConsultationFieldsError.emptyDocument }
        guard Set(regulated.map(\.id)).count == regulated.count else { throw CockpitError.invalidRegistry }
        return regulated
    }
}
