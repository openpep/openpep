// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

struct PatientWikiExport {
    static let ipsProfile = "http://hl7.org/fhir/uv/ips/StructureDefinition/"
    static let absent: [[String: String]] = [[
        "url": "http://hl7.org/fhir/StructureDefinition/data-absent-reason", "valueCode": "unknown"
    ]]

    static func okf(summary: PatientWikiSummary, context: PatientWikiContext) throws -> [String: Data] {
        guard summary.sourceFingerprint == context.fingerprint else { throw PatientAIIssue.changed }
        var files: [String: Data] = [:]
        var sources: [[String: String]] = []
        var markdown = summary.markdown
        for (index, source) in summary.sources.enumerated() {
            guard let entry = context.entries.first(where: {
                $0.id == source.id && $0.source == source.path && PatientAIContext.digest(Data($0.text.utf8)) == source.sha256
            }) else { throw PatientAIIssue.changed }
            let path = "references/source-\(index + 1).md"
            sources.append(["id": source.id, "resource": path, "title": entry.title])
            markdown = markdown.replacingOccurrences(of: "[F\(index + 1)]", with: "[^\(source.id)]")
            markdown += "\n[^\(source.id)]: [\(escapeLinkText(entry.title))](\(path))\n"
            let fence = String(repeating: "`", count: max(3, (entry.text.components(separatedBy: CharacterSet(charactersIn: "`").inverted).map(\.count).max() ?? 0) + 1))
            files[path] = try page(metadata: ["type": "Clinical Source", "title": entry.title,
                "x_openpep": ["source_id": source.id, "extracted_text_sha256": source.sha256,
                              "source_recorded_at": entry.timestamp]],
                body: "# Fonte textual\n\n" + fence + "text\n" + entry.text + "\n" + fence + "\n")
        }
        files["summary.md"] = try page(metadata: [
            "type": "Patient Summary", "title": "Resumo do paciente",
            "description": summary.overview ?? "Interpretação longitudinal de IA.",
            "sources": sources,
            "generated": ["by": "openpep/" + summary.model, "at": summary.generatedAt],
            "x_openpep": ["patient_id": context.patient.patientID, "review_state": "unverified",
                          "source_fingerprint": summary.sourceFingerprint,
                          "omitted_fact_count": summary.omittedFactCount,
                          "coverage": summary.exclusions?.description ?? "Cobertura não registrada nesta versão."]
        ], body: markdown)
        let omission = summary.omittedFactCount > 0
            ? "\n* Dados não incluídos no IPS: \(summary.omittedFactCount). As fontes permanecem separadas deste recorte.\n"
            : ""
        files["index.md"] = Data(("---\n{\"okf_version\":\"0.2\"}\n---\n# Paciente\n\n"
            + "* [Resumo](summary.md) - Interpretação de IA com fontes.\n"
            + "* [Fontes](references/) - Textos usados na geração.\n"
            + omission).utf8)
        files["references/index.md"] = Data(("# Fontes\n\n" + summary.sources.enumerated().map {
            "* [Fonte \($0.offset + 1)](source-\($0.offset + 1).md) - Texto identificado."
        }.joined(separator: "\n") + "\n").utf8)
        return files
    }

    /// Deterministic mapping of a reviewed snapshot; no model call or code inference.
    static func ips(context: PatientWikiContext, reviews: PatientWikiReviews, author: String,
                    selectedIDs: Set<String>? = nil, date: Date = Date(),
                    omittedFactCount: Int = 0) throws -> Data {
        guard reviews.patientID == context.patient.patientID,
              !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, author.count <= 300,
              !author.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              (0...100).contains(omittedFactCount) else {
            throw PatientAIIssue.changed
        }
        let eligible = reviews.accepted(in: context)
        guard selectedIDs?.isSubset(of: Set(eligible.map(\.id))) != false else { throw PatientAIIssue.changed }
        let facts = eligible.filter { selectedIDs?.contains($0.id) ?? true }
        guard PatientWikiFact.conflictingIDs(in: facts).isEmpty else {
            throw VaultValidationIssue(rule: "wiki.unresolved_conflict", path: "wiki/review.json",
                message: "Há dados divergentes para o mesmo assunto. Revise a seleção do IPS antes de exportar.")
        }
        let now = ISO8601DateFormatter().string(from: date)
        let patientURL = "urn:uuid:" + UUID().uuidString.lowercased()
        let authorURL = "urn:uuid:" + UUID().uuidString.lowercased()
        let compositionURL = "urn:uuid:" + UUID().uuidString.lowercased()
        var resources: [[String: Any]] = []
        func ref(_ url: String) -> [String: String] { ["reference": url] }
        func add(_ resource: [String: Any], url: String = "urn:uuid:" + UUID().uuidString.lowercased()) -> String {
            var resource = resource
            resource["id"] = String(url.dropFirst("urn:uuid:".count))
            resource["language"] = "pt-BR"
            resources.append(["fullUrl": url, "resource": resource])
            return url
        }
        guard let patient = context.patient.record, patient.patientID == context.patient.patientID,
              let patientName = patient.fullName?.trimmingCharacters(in: .whitespacesAndNewlines), !patientName.isEmpty else {
            throw VaultValidationIssue(rule: "wiki.patient_name_required", path: "patient.yaml",
                message: "O nome do paciente não está disponível. Confira o cadastro antes de exportar o IPS.")
        }
        var patientResource: [String: Any] = ["resourceType": "Patient",
            "meta": profile("Patient-uv-ips"), "identifier": [["system": "urn:openpep:patient-id", "value": context.patient.patientID]],
            "name": [["text": patientName]], "text": narrative(patientName)]
        if let birth = patient.birthDate { patientResource["birthDate"] = birth }
        else { patientResource["_birthDate"] = ["extension": absent] }
        _ = add(patientResource, url: patientURL)
        _ = add(["resourceType": "Practitioner", "meta": profile("Practitioner-uv-ips"), "name": [["text": author]], "text": narrative(author)], url: authorURL)

        var refsBySection: [String: [[String: String]]] = [:]
        var textBySection: [String: [String]] = [:]
        var evidenceReferences: [[String: String]] = []
        for fact in facts {
            try fact.validate()
            let draft = fact.draft
            let text = factDescription(fact, note: reviews.latestReview(for: fact)?.note)
            let section: String
            var resource: [String: Any] = ["subject": ref(patientURL), "text": narrative(text)]
            switch draft.kind {
            case .problem:
                section = draft.clinicalStatus == "resolved" ? "past" : "problems"
                resource["resourceType"] = "Condition"
                resource["meta"] = profile("Condition-uv-ips")
                resource["code"] = clinicalCode(fact)
                if draft.clinicalStatus != "unknown" {
                    resource["clinicalStatus"] = code(draft.clinicalStatus, system: "http://terminology.hl7.org/CodeSystem/condition-clinical")
                }
                if draft.certainty != "unknown" {
                    resource["verificationStatus"] = code(draft.certainty == "suspected" ? "provisional" : draft.certainty,
                        system: "http://terminology.hl7.org/CodeSystem/condition-ver-status")
                }
                if !draft.date.isEmpty { resource["recordedDate"] = draft.date }
                resource["note"] = [["text": draft.text]]
            case .allergy:
                section = "allergies"
                resource["resourceType"] = "AllergyIntolerance"
                resource["meta"] = profile("AllergyIntolerance-uv-ips")
                resource.removeValue(forKey: "subject")
                resource["patient"] = ref(patientURL)
                resource["code"] = clinicalCode(fact)
                resource["clinicalStatus"] = draft.clinicalStatus == "unknown" ? ["extension": absent] : code(draft.clinicalStatus, system: "http://terminology.hl7.org/CodeSystem/allergyintolerance-clinical")
                if draft.certainty != "unknown" {
                    resource["verificationStatus"] = code(draft.certainty == "suspected" ? "unconfirmed" : draft.certainty,
                        system: "http://terminology.hl7.org/CodeSystem/allergyintolerance-verification")
                }
                resource["note"] = [["text": draft.text]]
            case .medication:
                section = "medications"
                let prescribed = draft.medicationUse == "prescribed"
                resource["resourceType"] = prescribed ? "MedicationRequest" : "MedicationStatement"
                resource["meta"] = profile(prescribed ? "MedicationRequest-uv-ips" : "MedicationStatement-uv-ips")
                resource["status"] = draft.clinicalStatus == "resolved" ? "stopped" : draft.clinicalStatus
                resource["medicationCodeableConcept"] = ["text": draft.label]
                resource["note"] = [["text": draft.text]]
                if prescribed { resource["intent"] = "order" }
                else if draft.date.isEmpty { resource["_effectiveDateTime"] = ["extension": absent] }
                else { resource["effectiveDateTime"] = draft.date }
                let dosage = [draft.dosage, draft.ips?.frequency ?? "", draft.ips?.route ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
                if !dosage.isEmpty { resource[prescribed ? "dosageInstruction" : "dosage"] = [["text": dosage]] }
            case .measurement:
                section = draft.measurement == "weight" ? "vitals" : "results"
                resource["resourceType"] = "Observation"
                resource["meta"] = draft.measurement == "weight"
                    ? ["profile": ["http://hl7.org/fhir/StructureDefinition/bodyweight|4.0.1"]]
                    : profile("Observation-results-laboratory-pathology-uv-ips")
                resource["status"] = draft.observationStatus
                resource["category"] = [code(draft.measurement == "weight" ? "vital-signs" : "laboratory",
                    system: "http://terminology.hl7.org/CodeSystem/observation-category")]
                // Let receivers choose a terminology display in their language; preserve the reviewed label as text.
                resource["code"] = ["coding": [["system": "http://loinc.org", "code": fact.loinc!]], "text": draft.label]
                resource["effectiveDateTime"] = draft.date
                resource["valueQuantity"] = ["value": fact.value!, "unit": draft.unit,
                    "system": "http://unitsofmeasure.org", "code": draft.unit]
                resource["performer"] = [["extension": absent, "display": "Executor não informado"]]
                if !draft.method.isEmpty { resource["method"] = ["text": draft.method] }
            case .socialHistory:
                section = "social"
                resource["resourceType"] = "Observation"
                resource["status"] = "unknown"
                resource["performer"] = [["extension": absent, "display": "Executor não informado"]]
                resource["category"] = [code("social-history", system: "http://terminology.hl7.org/CodeSystem/observation-category")]
                let domain = draft.ips?.socialDomain ?? "other"
                if domain == "tobacco" || domain == "alcohol" {
                    resource["meta"] = profile(domain == "tobacco" ? "Observation-tobaccouse-uv-ips" : "Observation-alcoholuse-uv-ips")
                    resource["code"] = code(domain == "tobacco" ? "72166-2" : "74013-4", system: "http://loinc.org")
                } else {
                    resource["code"] = ["text": PatientIPSSocialDomain(rawValue: domain)?.title ?? draft.label]
                }
                resource["valueString"] = draft.text
                if draft.date.isEmpty { resource["_effectiveDateTime"] = ["extension": absent] }
                else { resource["effectiveDateTime"] = draft.date }
            case .procedure, .result, .screening, .immunization:
                // Narrative and source evidence preserve performed/unknown/planned states.
                // A structured event mapping needs its own profile validation increment.
                section = draft.kind == .procedure ? "procedures" : draft.kind == .immunization ? "immunizations" : "results"
            }
            if let note = reviews.latestReview(for: fact)?.note, !note.isEmpty {
                var notes = resource["note"] as? [[String: String]] ?? []
                notes.append(["text": "Observação do médico: " + note])
                resource["note"] = notes
            }
            // R4 requires a coded allergy clinicalStatus and has no unknown value.
            // Preserve such an assertion in narrative and evidence without inventing an active allergy.
            let narrativeOnly = [.procedure, .result, .screening, .immunization].contains(draft.kind) || (draft.kind == .allergy && draft.clinicalStatus == "unknown")
            let resourceURL: String? = narrativeOnly ? nil : add(resource)
            if let resourceURL { refsBySection[section, default: []].append(ref(resourceURL)) }
            textBySection[section, default: []].append(text)
            let documentURL = add(["resourceType": "DocumentReference", "status": "current",
                "subject": ref(patientURL), "text": narrative("Trecho da fonte " + fact.source.id),
                "description": "Fonte \(fact.source.id); SHA-256 do texto extraído: \(fact.source.sha256)",
                "content": [["attachment": ["contentType": "text/plain", "title": "Evidência da extração",
                    "data": Data(draft.quote.utf8).base64EncodedString()]]]])
            evidenceReferences.append(ref(documentURL))
            guard let review = reviews.records.last(where: { $0.fact.id == fact.id }) else { throw PatientAIIssue.changed }
            var entities: [[String: Any]] = [["role": "source", "what": ref(documentURL)]]
            if let terminology = fact.terminology {
                entities.append(["role": "source", "what": [
                    "identifier": ["system": "urn:ietf:rfc:3986", "value": terminology.version],
                    "display": "Catálogo SNOMED CT IPS usado na associação local (snapshot 2024-07-01)"]])
            }
            _ = add(["resourceType": "Provenance", "target": [ref(resourceURL ?? compositionURL)], "recorded": review.reviewedAt,
                     "text": narrative("Extração revisada por " + review.reviewer + ": " + text),
                     "agent": [["who": ["display": review.reviewer], "role": [["text": "Revisão da extração"]]]],
                     "entity": entities])
        }
        let sectionDefinitions = [
            ("problems", "11450-4", "Problemas em acompanhamento"),
            ("allergies", "48765-2", "Alergias e intolerâncias"),
            ("medications", "10160-0", "Medicamentos"),
            ("past", "11348-0", "Problemas anteriores"),
            ("vitals", "8716-3", "Sinais vitais"),
            ("results", "30954-2", "Exames e rastreamentos"),
            ("procedures", "47519-4", "Procedimentos e cirurgias"),
            ("immunizations", "11369-6", "Imunizações"),
            ("social", "29762-2", "História social e estilo de vida")
        ]
        var sections: [[String: Any]] = []
        for (key, loinc, title) in sectionDefinitions {
            let entries = refsBySection[key] ?? []
            if entries.isEmpty && textBySection[key] == nil && !["problems", "allergies", "medications"].contains(key) { continue }
            let withheld = eligible.contains { fact in
                let d = fact.draft
                let factSection = d.kind == .problem ? (d.clinicalStatus == "resolved" ? "past" : "problems")
                    : d.kind == .allergy ? "allergies" : d.kind == .medication ? "medications"
                    : d.kind == .socialHistory ? "social" : d.kind == .procedure ? "procedures" : d.kind == .immunization ? "immunizations"
                    : d.measurement == "weight" ? "vitals" : "results"
                return factSection == key && !(selectedIDs?.contains(fact.id) ?? true)
            }
            var sectionText = textBySection[key]?.joined(separator: "\n\n") ?? "Informação não disponível no recorte revisado; não representa ausência clínica."
            if withheld { sectionText += "\nHá itens aceitos que não foram incluídos na seleção deste documento." }
            if key == "allergies" && facts.contains(where: { $0.draft.kind == .allergy && $0.draft.clinicalStatus == "unknown" }) {
                sectionText += "\nAlergia com estado clínico não informado foi preservada somente na narrativa e evidência."
            }
            var section: [String: Any] = ["title": title, "code": code(loinc, system: "http://loinc.org"), "text": narrative(sectionText)]
            if entries.isEmpty && textBySection[key] == nil { section["emptyReason"] = code(withheld ? "withheld" : "unavailable", system: "http://terminology.hl7.org/CodeSystem/list-empty-reason") }
            else if !entries.isEmpty { section["entry"] = entries }
            sections.append(section)
        }
        if !evidenceReferences.isEmpty {
            sections.append(["title": "Evidências da revisão", "code": ["text": "Evidências da revisão"],
                "text": narrative("Trechos das fontes que sustentam as extrações selecionadas."), "entry": evidenceReferences])
        }
        let omission = omittedFactCount > 0
            ? " Dados não incluídos no IPS: \(omittedFactCount). As fontes permanecem separadas deste recorte."
            : ""
        let composition: [String: Any] = ["resourceType": "Composition", "meta": profile("Composition-uv-ips"),
            "status": "final", "type": code("60591-5", system: "http://loinc.org"),
            "subject": ref(patientURL), "author": [ref(authorURL)], "date": now,
            "title": "Resumo Internacional do Paciente", "confidentiality": "N", "section": sections,
            "text": narrative("Resumo do recorte revisado: \(facts.count) de \(eligible.count) extrações aceitas incluídas.\(omission) Dados ausentes não representam ausência clínica. "
                              + "Datas dos fatos preservadas; revisão de extração não confirma diagnóstico suspeito."),
            "attester": [["mode": "professional", "time": now, "party": ref(authorURL)]]]
        _ = add(composition, url: compositionURL)
        let compositionEntry = resources.removeLast()
        resources.insert(compositionEntry, at: 0)
        let bundle: [String: Any] = ["resourceType": "Bundle", "type": "document", "language": "pt-BR",
            "meta": profile("Bundle-uv-ips"), "id": UUID().uuidString.lowercased(),
            "identifier": ["system": "urn:ietf:rfc:3986", "value": "urn:uuid:" + UUID().uuidString.lowercased()],
            "timestamp": now, "entry": resources]
        try validateDocument(bundle)
        return try JSONSerialization.data(withJSONObject: bundle, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Local structural checks; profile/terminology conformance is tested separately with HL7's validator.
    static func validateDocument(_ bundle: [String: Any]) throws {
        guard bundle["resourceType"] as? String == "Bundle", bundle["type"] as? String == "document",
              let entries = bundle["entry"] as? [[String: Any]],
              (entries.first?["resource"] as? [String: Any])?["resourceType"] as? String == "Composition" else {
            throw OpenAITextIssue.invalidResponse
        }
        let urls = entries.compactMap { $0["fullUrl"] as? String }
        guard urls.count == entries.count, Set(urls).count == urls.count else { throw OpenAITextIssue.invalidResponse }
        func visit(_ value: Any) throws {
            if let object = value as? [String: Any] {
                if let reference = object["reference"] as? String, !urls.contains(reference) { throw OpenAITextIssue.invalidResponse }
                for member in object.values { try visit(member) }
            } else if let array = value as? [Any] { for member in array { try visit(member) } }
        }
        try visit(bundle)
    }

    static func factDescription(_ fact: PatientWikiFact, note: String? = nil) -> String {
        let d = fact.draft
        return "\(d.label): \(d.text)\nData: \(d.date.isEmpty ? "não informada" : d.date). "
            + "Estado na fonte: \(d.clinicalStatusText). Certeza: \(d.certaintyText)."
            + (d.kind == .measurement ? "\n\(d.value) \(d.unit). Situação do resultado: \(d.observationStatusText). Método: \(d.method.isEmpty ? "não informado" : d.method)." : "")
            + (d.kind == .medication ? "\nUso: \(d.medicationUseText). Posologia: \(d.dosage.isEmpty ? "não informada" : d.dosage)." : "")
            + (d.ips.map { "\n" + (d.kind == .problem ? $0.courseText : "")
                + (d.kind == .medication ? [$0.frequency, $0.route].filter { !$0.isEmpty }.joined(separator: " · ") : "")
                + ([.procedure, .result, .screening, .immunization].contains(d.kind) ? $0.eventText : "")
                + ($0.nextDate.isEmpty ? "" : "; próxima data documentada: " + $0.nextDate) } ?? "")
            + (note.flatMap { $0.isEmpty ? nil : "\nObservação do médico: " + $0 } ?? "")
    }

    private static func clinicalCode(_ fact: PatientWikiFact) -> [String: Any] {
        var result: [String: Any] = ["text": fact.draft.label]
        if let coding = fact.terminology {
            // The subset identifier is retained in Provenance; it is not an international
            // edition available to IPS value-set bindings. Coding.version is optional.
            result["coding"] = [["system": coding.system, "code": coding.code, "display": coding.display]]
        }
        return result
    }

    static func write(_ files: [String: Data], to destination: URL, validate: () throws -> Void) throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else { throw PatientAIIssue.changed }
        let staging = destination.deletingLastPathComponent().appending(path: ".openpep-export-" + UUID().uuidString)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        for (path, data) in files {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  !path.contains("\\"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw OpenAITextIssue.invalidResponse
            }
            let url = staging.appending(path: path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .withoutOverwriting)
            guard try Data(contentsOf: url) == data else { throw PatientAIIssue.changed }
        }
        try validate()
        try manager.moveItem(at: staging, to: destination)
    }

    private static func profile(_ name: String) -> [String: [String]] { ["profile": [ipsProfile + name + "|2.0.1"]] }
    private static func code(_ value: String, system: String) -> [String: Any] { ["coding": [["system": system, "code": value]]] }
    private static func narrative(_ value: String) -> [String: String] {
        let escaped = value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br/>")
        return ["status": "generated", "div": "<div xmlns=\"http://www.w3.org/1999/xhtml\" lang=\"pt-BR\" xml:lang=\"pt-BR\">\(escaped)</div>"]
    }
    private static func escapeLinkText(_ text: String) -> String {
        text.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "\n", with: " ")
    }
    private static func page(metadata: [String: Any], body: String) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys, .withoutEscapingSlashes])
        return Data(("---\n" + String(decoding: json, as: UTF8.self) + "\n---\n" + body).utf8)
    }
}
