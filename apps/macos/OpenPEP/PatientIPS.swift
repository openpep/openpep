// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Optional on legacy facts so their serialized bytes and review identity stay stable.
struct PatientIPSDetails: Codable, Equatable, Sendable {
    var course = "unknown"
    var frequency = ""
    var route = ""
    var eventStatus = "unknown"
    var nextDate = ""
    var socialDomain: String? = nil

    var courseText: String {
        ["chronic": "Crônico", "recurrent": "Recorrente", "current": "Atual"][course] ?? "Evolução não informada"
    }
    var eventText: String {
        ["completed": "Realizado", "planned": "A avaliar"][eventStatus] ?? "Realização não confirmada"
    }

    func validate(kind: PatientWikiFactKind) throws {
        guard ["chronic", "recurrent", "current", "unknown"].contains(course),
              ["completed", "planned", "unknown"].contains(eventStatus),
              kind == .problem || course == "unknown",
              kind == .medication || (frequency.isEmpty && route.isEmpty),
              [.procedure, .result, .screening, .immunization].contains(kind) || eventStatus == "unknown",
              [.screening, .immunization].contains(kind) || nextDate.isEmpty,
              nextDate.isEmpty || PatientWikiFact.validDate(nextDate),
              kind == .socialHistory ? PatientIPSSocialDomain(rawValue: socialDomain ?? "") != nil : (socialDomain ?? "").isEmpty,
              [frequency, route].allSatisfy({ $0.count <= 300 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
            throw OpenAITextIssue.invalidResponse
        }
    }
}

enum PatientIPSSocialDomain: String, CaseIterable, Identifiable, Sendable {
    case tobacco, alcohol, activity, diet, sleep, substances, exposure, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tobacco: "Tabagismo"
        case .alcohol: "Álcool"
        case .activity: "Atividade física"
        case .diet: "Alimentação"
        case .sleep: "Sono"
        case .substances: "Outras substâncias"
        case .exposure: "Exposição ocupacional / ambiental"
        case .other: "Outros fatores sociais"
        }
    }
}

enum PatientIPSSection: String, CaseIterable, Identifiable, Sendable {
    case problems, medications, procedures, allergies, results, immunizations, socialHistory
    var id: String { rawValue }
    var title: String {
        switch self {
        case .problems: "Problemas e diagnósticos"
        case .medications: "Medicamentos em uso"
        case .procedures: "Procedimentos e cirurgias"
        case .allergies: "Alergias"
        case .results: "Exames e rastreamentos"
        case .immunizations: "Imunizações"
        case .socialHistory: "Estilo de vida"
        }
    }
    var symbol: String {
        switch self {
        case .problems: "heart.text.square"
        case .medications: "pills"
        case .procedures: "cross.case"
        case .allergies: "allergens"
        case .results: "testtube.2"
        case .immunizations: "syringe"
        case .socialHistory: "figure.walk"
        }
    }
    func contains(_ kind: PatientWikiFactKind) -> Bool {
        switch self {
        case .problems: kind == .problem
        case .medications: kind == .medication
        case .procedures: kind == .procedure
        case .allergies: kind == .allergy
        case .results: [.measurement, .result, .screening].contains(kind)
        case .immunizations: kind == .immunization
        case .socialHistory: kind == .socialHistory
        }
    }
}

extension PatientWikiFact {
    var ipsSection: PatientIPSSection { PatientIPSSection.allCases.first { $0.contains(draft.kind) }! }
    var isPlanned: Bool { draft.ips?.eventStatus == "planned" }
    var ipsDetail: String {
        let d = draft
        var parts: [String] = []
        if d.kind == .medication {
            parts = [d.dosage.isEmpty ? "Dose não informada" : d.dosage, d.ips?.frequency ?? "", d.ips?.route ?? ""]
            if d.medicationUse != "reported" { parts.append(d.medicationUseText) }
        } else if d.kind == .measurement { parts = [d.value + " " + d.unit] }
        else { parts = [d.text] }
        if d.clinicalStatus == "resolved" { parts.append("Resolvido / encerrado") }
        if d.certainty == "suspected" { parts.append("Suspeita") }
        if d.certainty == "refuted" { parts.append("Refutado na fonte") }
        if !d.date.isEmpty { parts.append(Self.ipsDate(d.date)) }
        if let next = d.ips?.nextDate, !next.isEmpty { parts.append("Próxima: " + Self.ipsDate(next)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    static func ipsDate(_ value: String) -> String {
        let components = value.split(separator: "-")
        guard components.count == 3 else { return value }
        return components.reversed().joined(separator: "/")
    }
}

/// Presentation groups preserve every distinct assertion and its review identity.
struct PatientIPSFactGroup: Identifiable {
    let primary: PatientWikiFact
    let alternatives: [PatientWikiFact]
    var id: String { primary.id }

    static func sameEvidence(_ lhs: PatientWikiFact, _ rhs: PatientWikiFact) -> Bool {
        guard lhs.patientID == rhs.patientID, lhs.source == rhs.source,
              lhs.mappingVersion == rhs.mappingVersion, lhs.terminology == rhs.terminology else { return false }
        var left = lhs.draft, right = rhs.draft
        // A social domain identifies the topic even when the AI rewords its label.
        // Other kinds require the same label to avoid grouping distinct diagnoses.
        if left.kind == .socialHistory { left.label = ""; right.label = "" }
        left.text = ""; right.text = ""
        return left == right
    }

    static func make(_ facts: [PatientWikiFact], reviews: PatientWikiReviews?) -> [Self] {
        var groups: [[PatientWikiFact]] = []
        for fact in facts {
            if let index = groups.firstIndex(where: { sameEvidence($0[0], fact) }) {
                groups[index].append(fact)
            } else { groups.append([fact]) }
        }
        return groups.map { group in
            let primary = group.first { reviews?.decision(for: $0) == .accepted }
                ?? group.first { reviews?.decision(for: $0) != nil } ?? group[0]
            return Self(primary: primary, alternatives: group.filter { $0.id != primary.id })
        }
    }
}

enum PatientIPSInputIssue: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

enum PatientIPSFormValidation {
    static func message(draft: PatientWikiFactDraft, original: PatientWikiFact?, note: String,
                        context: PatientWikiContext) -> String? {
        if draft.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Preencha o nome da informação." }
        if draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Preencha os detalhes da informação." }
        if !draft.date.isEmpty && !PatientWikiFact.validDate(draft.date) { return "Confira a data clínica. Use aaaa-mm-dd, por exemplo 2025-09-30." }
        if let next = draft.ips?.nextDate, !next.isEmpty && !PatientWikiFact.validDate(next) { return "Confira a próxima data. Use aaaa-mm-dd." }
        if original == nil && draft.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Copie o trecho do documento de origem que comprova a informação. Se ela ainda não consta no prontuário, registre-a na consulta primeiro."
        }
        if (original == nil || draft != original?.draft) && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return original == nil ? "Preencha a observação do médico para explicar a inclusão."
                : "Preencha a observação do médico para explicar o que foi ajustado."
        }
        do {
            if var fact = original {
                fact.draft = draft
                fact.terminology = PatientIPSTerminology.bundled?.match(label: draft.label, kind: draft.kind)
                try fact.validate()
            } else {
                var diagnostic: PatientWikiFactBindingDiagnostic?
                do { _ = try PatientWikiFact.bind([draft], to: context, diagnostic: { diagnostic = $0 }) }
                catch {
                    switch diagnostic?.code {
                    case .quoteMismatch: return "O trecho não foi encontrado no documento escolhido. Confira a origem e copie o texto sem alterá-lo."
                    case .measurementDate: return "A data informada não consta na fonte. Confira a data clínica e a próxima data no documento."
                    case .sourceReference: return "Escolha um documento de origem disponível."
                    default: return "Confira os campos preenchidos e os dados no documento de origem."
                    }
                }
            }
        } catch { return "Confira o formato e o tamanho dos campos preenchidos." }
        return nil
    }
}

/// Same append-only, CAS-protected review journal as export, independent of sharing.
enum PatientIPSReviewService {
    static func add(draft: PatientWikiFactDraft, decision: PatientWikiReview.Decision, note: String,
                    summary: PatientWikiSummary, context: PatientWikiContext,
                    historyContext: PatientHistoryContext, expectedReviews: Data?, reviewer: String) throws {
        let store = PatientWikiStore()
        if let message = PatientIPSFormValidation.message(draft: draft, original: nil, note: note, context: context) {
            throw PatientIPSInputIssue.invalid(message)
        }
        guard context.writingAllowed, !context.patient.isArchived,
              summary.sourceFingerprint == context.fingerprint,
              let fact = try PatientWikiFact.bind([draft], to: context).first else { throw PatientAIIssue.changed }
        let (reviews, bytes) = try store.loadReviews(for: context.patient)
        guard bytes == expectedReviews,
              !reviews.candidates(for: summary, in: context).contains(where: { $0.id == fact.id }) else {
            throw PatientAIIssue.changed
        }
        let record = PatientWikiReview(fact: fact, decision: decision, reviewer: reviewer,
            reviewedAt: ISO8601DateFormatter().string(from: Date()), note: note)
        try store.saveReviews([record], for: context.patient, expectedData: bytes) {
            let saved = try store.load(for: context.patient)
            let latest = try PatientWikiContext.load(context: historyContext, corrections: saved.corrections?.markdown ?? "")
            guard latest.fingerprint == context.fingerprint, latest.writingAllowed,
                  !latest.patient.isArchived, fact.matches(latest.entries),
                  saved.summary?.persistedData == summary.persistedData else { throw PatientAIIssue.changed }
        }
    }

    static func save(original: PatientWikiFact, edited: PatientWikiFact? = nil,
                     decision: PatientWikiReview.Decision, note: String,
                     summary: PatientWikiSummary, context: PatientWikiContext,
                     historyContext: PatientHistoryContext, expectedReviews: Data?,
                     reviewer: String, reloadContext: PatientWikiApproval.ReloadContext? = nil) throws {
        let store = PatientWikiStore()
        let (reviews, bytes) = try store.loadReviews(for: context.patient)
        let available = reviews.candidates(for: summary, in: context) + reviews.outdatedAccepted(in: context)
        guard bytes == expectedReviews, context.writingAllowed, !context.patient.isArchived,
              summary.sourceFingerprint == context.fingerprint,
              available.contains(original), !reviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PatientAIIssue.changed
        }
        var fact = edited ?? original
        // The editor may change assertions, never their evidence or patient identity.
        guard fact.patientID == original.patientID, fact.source == original.source,
              fact.draft.source == original.draft.source, fact.draft.quote == original.draft.quote,
              fact.draft.kind == original.draft.kind, fact.mappingVersion == original.mappingVersion,
              decision == .rejected || original.matches(context.entries) else { throw PatientAIIssue.changed }
        if fact.draft != original.draft {
            guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PatientIPSInputIssue.invalid("Preencha a observação do médico para explicar o que foi ajustado.")
            }
            fact.terminology = PatientIPSTerminology.bundled?.match(label: fact.draft.label, kind: fact.draft.kind)
        }
        try fact.validate()
        let stamp = ISO8601DateFormatter().string(from: Date())
        var records: [PatientWikiReview] = []
        if fact.id != original.id {
            records.append(PatientWikiReview(fact: original, decision: .rejected, reviewer: reviewer,
                reviewedAt: stamp, note: reviews.latestReview(for: original)?.note))
        }
        let previousWording = decision == .accepted && fact.id == original.id
            ? reviews.accepted(in: context).filter { $0.id != fact.id && PatientIPSFactGroup.sameEvidence($0, fact) }
            : []
        guard previousWording.count <= 1 else {
            throw PatientIPSInputIssue.invalid("Há mais de uma versão confirmada. Retire as versões anteriores antes de confirmar esta redação.")
        }
        for previous in previousWording {
            records.append(PatientWikiReview(fact: previous, decision: .rejected, reviewer: reviewer,
                reviewedAt: stamp, note: reviews.latestReview(for: previous)?.note))
        }
        records.append(PatientWikiReview(fact: fact, decision: decision, reviewer: reviewer,
            reviewedAt: stamp, note: note,
            replacesFactID: fact.id == original.id ? previousWording.first?.id : original.id))
        try store.saveReviews(records, for: context.patient, expectedData: bytes) {
            let saved = try store.load(for: context.patient)
            let current = try reloadContext?() ?? PatientWikiContext.load(context: historyContext,
                corrections: saved.corrections?.markdown ?? "")
            guard current.patient.patientID == context.patient.patientID,
                  current.patient.url.standardizedFileURL == context.patient.url.standardizedFileURL,
                  current.writingAllowed, !current.patient.isArchived,
                  current.fingerprint == context.fingerprint,
                  saved.summary?.persistedData == summary.persistedData,
                  decision == .rejected || fact.matches(current.entries) else { throw PatientAIIssue.changed }
        }
    }
}
