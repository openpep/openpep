// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

enum PatientWikiFactKind: String, Codable, CaseIterable, Sendable {
    case problem, medication, allergy, measurement, procedure, result, screening, immunization, socialHistory
}

/// A narrow extraction contract. Empty strings mean not documented, never clinical absence.
struct PatientWikiFactDraft: Codable, Equatable, Sendable {
    var kind: PatientWikiFactKind
    var label: String
    var text: String
    var source: String
    var quote: String
    var date = ""
    var clinicalStatus = "unknown"
    var certainty = "unknown"
    var medicationUse = "unknown"
    var dosage = ""
    var measurement = ""
    var value = ""
    var unit = ""
    var method = ""
    var observationStatus = "unknown"
    var ips: PatientIPSDetails? = nil

    var clinicalStatusText: String { ["active": "ativo", "resolved": "resolvido"][clinicalStatus] ?? "não informado" }
    var certaintyText: String { ["confirmed": "confirmado na fonte", "suspected": "suspeita na fonte", "refuted": "refutado na fonte"][certainty] ?? "não informada" }
    var medicationUseText: String { ["reported": "uso relatado", "prescribed": "prescrito"][medicationUse] ?? "não confirmado" }
    var observationStatusText: String { ["final": "final", "preliminary": "preliminar", "corrected": "corrigido"][observationStatus] ?? "não informada" }
}

/// Safe local reason for rejecting one extracted fact. It carries only bounded
/// indexes and a validation code; evidence text is intentionally excluded.
struct PatientWikiFactBindingDiagnostic: Equatable, Sendable {
    enum Code: String, Sendable {
        case tooManyFacts
        case sourceReference
        case invalidFields
        case nonMeasurementFields
        case observationStatusForKind
        case quoteMismatch
        case measurementDate
        case measurementUnit
        case measurementValue
        case duplicateFact
    }

    let code: Code
    let factIndex: Int?
    let sourceIndex: Int?

    init(code: Code, factIndex: Int? = nil, sourceIndex: Int? = nil) {
        self.code = code
        self.factIndex = factIndex
        self.sourceIndex = sourceIndex
    }

    var message: String {
        switch code {
        case .tooManyFacts: "A resposta trouxe mais fatos do que o limite local. O resumo anterior foi mantido."
        case .sourceReference: "Um fato aponta para uma fonte indisponível. O resumo anterior foi mantido."
        case .invalidFields: "Um fato contém formato de informação extraída pela IA que não é aceito. O resumo anterior foi mantido."
        case .nonMeasurementFields: "Um fato não quantitativo trouxe campos de medida inválidos. O resumo anterior foi mantido."
        case .observationStatusForKind: "Um fato não quantitativo trouxe um estado de observação inválido. O resumo anterior foi mantido."
        case .quoteMismatch: "A citação de um fato não corresponde exatamente à fonte carregada. O resumo anterior foi mantido."
        case .measurementDate: "A data clínica não corresponde à fonte carregada. O resumo anterior foi mantido."
        case .measurementUnit: "A unidade de uma medida não corresponde à fonte carregada. O resumo anterior foi mantido."
        case .measurementValue: "O valor de uma medida não corresponde à fonte carregada. O resumo anterior foi mantido."
        case .duplicateFact: "A resposta repetiu o mesmo fato. O resumo anterior foi mantido."
        }
    }
}

struct PatientWikiFactBindingResult: Equatable, Sendable {
    let facts: [PatientWikiFact]
    let omittedCount: Int
}

struct PatientWikiFact: Codable, Equatable, Identifiable, Sendable {
    let patientID: String
    var draft: PatientWikiFactDraft
    let source: PatientWikiSource
    var mappingVersion = "openpep/wiki-measurements@1"
    var terminology: PatientIPSCoding? = nil

    var requiresIPSSchema: Bool { draft.ips != nil || terminology != nil || [.procedure, .result, .screening, .immunization, .socialHistory].contains(draft.kind) }

    var id: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // All members are bounded values with a total Codable representation.
        return PatientAIContext.digest((try? encoder.encode(self)) ?? Data())
    }

    var value: Double? { Double(draft.value) }
    var loinc: String? {
        switch draft.measurement {
        case "weight": "29463-7"
        case "hba1c": "4548-4"
        default: nil
        }
    }

    var loincDisplay: String? {
        switch draft.measurement {
        case "weight": "Body weight"
        case "hba1c": "Hemoglobin A1c/Hemoglobin.total in Blood"
        default: nil
        }
    }

    func matches(_ entries: [PatientHistoryEntry]) -> Bool {
        entries.contains { $0.id == source.id && $0.source == source.path
            && PatientAIContext.digest(Data($0.text.utf8)) == source.sha256
            && Self.normalizedEvidenceText($0.text).contains(Self.normalizedEvidenceText(draft.quote)) }
    }

    /// The provider may change Unicode composition or line wrapping while
    /// copying evidence. Normalize only canonical composition and whitespace;
    /// punctuation, letters, numbers, and negations remain unchanged.
    static func normalizedEvidenceText(_ value: String) -> String {
        let canonical = value.precomposedStringWithCanonicalMapping
        var normalized = String()
        normalized.reserveCapacity(canonical.count)
        var pendingWhitespace = false
        for character in canonical {
            if character.isWhitespace {
                pendingWhitespace = true
                continue
            }
            if pendingWhitespace && !normalized.isEmpty {
                normalized.append(" ")
            }
            normalized.append(character)
            pendingWhitespace = false
        }
        return normalized
    }

    static func bind(_ drafts: [PatientWikiFactDraft], to context: PatientWikiContext,
                     diagnostic: ((PatientWikiFactBindingDiagnostic) -> Void)? = nil) throws -> [Self] {
        guard drafts.count <= 100 else {
            diagnostic?(.init(code: .tooManyFacts, factIndex: nil))
            throw OpenAITextIssue.invalidResponse
        }
        var facts: [Self] = []
        facts.reserveCapacity(drafts.count)
        for (factIndex, draft) in drafts.enumerated() {
            guard draft.source.hasPrefix("F"), let index = Int(draft.source.dropFirst()), index > 0,
                  draft.source == "F\(index)", context.entries.indices.contains(index - 1) else {
                let sourceIndex = Int(draft.source.dropFirst()).flatMap { $0 > 0 ? $0 - 1 : nil }
                diagnostic?(.init(code: .sourceReference, factIndex: factIndex,
                                  sourceIndex: sourceIndex))
                throw OpenAITextIssue.invalidResponse
            }
            let entry = context.entries[index - 1]
            var bound = draft
            bound.source = entry.id
            var fact = Self(patientID: context.patient.patientID, draft: bound,
                source: PatientWikiSource(id: entry.id, path: entry.source,
                    sha256: PatientAIContext.digest(Data(entry.text.utf8))))
            do {
                try fact.validate()
            } catch {
                if draft.kind == .measurement {
                    let code: PatientWikiFactBindingDiagnostic.Code
                    if draft.date.isEmpty || !Self.validDate(draft.date) {
                        code = .measurementDate
                    } else if !(draft.measurement == "weight" && draft.unit == "kg"
                                || draft.measurement == "hba1c" && draft.unit == "%") {
                        code = .measurementUnit
                    } else if fact.value == nil || draft.value.range(of: "^[0-9]+(?:\\.[0-9]+)?$",
                                                                     options: .regularExpression) == nil {
                        code = .measurementValue
                    } else {
                        code = .invalidFields
                    }
                    diagnostic?(.init(code: code, factIndex: factIndex, sourceIndex: index - 1))
                } else if draft.observationStatus != "unknown" {
                    diagnostic?(.init(code: .observationStatusForKind, factIndex: factIndex,
                                      sourceIndex: index - 1))
                } else if !draft.measurement.isEmpty || !draft.value.isEmpty || !draft.unit.isEmpty
                            || !draft.method.isEmpty || (draft.kind != .medication
                                && (!draft.dosage.isEmpty || draft.medicationUse != "unknown")) {
                    diagnostic?(.init(code: .nonMeasurementFields, factIndex: factIndex,
                                      sourceIndex: index - 1))
                } else {
                    diagnostic?(.init(code: .invalidFields, factIndex: factIndex, sourceIndex: index - 1))
                }
                throw OpenAITextIssue.invalidResponse
            }
            guard fact.matches(context.entries) else {
                diagnostic?(.init(code: .quoteMismatch, factIndex: factIndex, sourceIndex: index - 1))
                throw OpenAITextIssue.invalidResponse
            }
            if draft.kind == .measurement {
                let parts = draft.date.split(separator: "-")
                let localDate = "\(parts[2])/\(parts[1])/\(parts[0])"
                let encounterDate = entry.source.hasPrefix("content/notes/final/")
                    && entry.timestamp.hasPrefix(draft.date)
                guard encounterDate || entry.text.contains(draft.date) || entry.text.contains(localDate) else {
                    diagnostic?(.init(code: .measurementDate, factIndex: factIndex, sourceIndex: index - 1))
                    throw OpenAITextIssue.invalidResponse
                }
                guard draft.quote.contains(draft.unit) else {
                    diagnostic?(.init(code: .measurementUnit, factIndex: factIndex, sourceIndex: index - 1))
                    throw OpenAITextIssue.invalidResponse
                }
                let numbers = draft.quote.replacingOccurrences(of: ",", with: ".")
                    .components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
                    .compactMap(Double.init)
                guard let value = fact.value, numbers.contains(value) else {
                    diagnostic?(.init(code: .measurementValue, factIndex: factIndex, sourceIndex: index - 1))
                    throw OpenAITextIssue.invalidResponse
                }
            }
            if draft.ips != nil && draft.kind != .measurement {
                let permitsEncounterRecordDate: Bool = [.problem, .allergy, .socialHistory].contains(draft.kind)
                for (date, isNextDate) in [(draft.date, false), (draft.ips?.nextDate ?? "", true)] where !date.isEmpty {
                    let formatted = Self.ipsDate(date)
                    let encounterRecordDate = !isNextDate && permitsEncounterRecordDate
                        && entry.source.hasPrefix("content/notes/final/") && entry.timestamp.hasPrefix(date)
                    guard encounterRecordDate || entry.text.contains(date) || entry.text.contains(formatted) else {
                        diagnostic?(.init(code: .measurementDate, factIndex: factIndex, sourceIndex: index - 1))
                        throw OpenAITextIssue.invalidResponse
                    }
                }
            }
            if draft.ips != nil { fact.terminology = PatientIPSTerminology.bundled?.match(label: draft.label, kind: draft.kind) }
            facts.append(fact)
        }
        var seenIDs = Set<String>()
        for (factIndex, fact) in facts.enumerated() where !seenIDs.insert(fact.id).inserted {
            diagnostic?(.init(code: .duplicateFact, factIndex: factIndex))
            throw OpenAITextIssue.invalidResponse
        }
        return facts
    }

    /// Binds each extraction independently so one bad citation or field does
    /// not discard a structurally valid narrative. Global volume failures
    /// still throw; omitted facts are never returned as proposals.
    static func bindPartially(
        _ drafts: [PatientWikiFactDraft],
        to context: PatientWikiContext,
        diagnostic: ((PatientWikiFactBindingDiagnostic) -> Void)? = nil
    ) throws -> PatientWikiFactBindingResult {
        guard drafts.count <= 100 else {
            diagnostic?(.init(code: .tooManyFacts, factIndex: nil))
            throw OpenAITextIssue.invalidResponse
        }

        var facts: [Self] = []
        facts.reserveCapacity(drafts.count)
        var omittedCount = 0
        for (factIndex, draft) in drafts.enumerated() {
            var localDiagnostic: PatientWikiFactBindingDiagnostic?
            do {
                let bound = try bind([draft], to: context,
                    diagnostic: { localDiagnostic = $0 })
                guard let fact = bound.first else {
                    omittedCount += 1
                    diagnostic?(.init(code: .invalidFields, factIndex: factIndex,
                                      sourceIndex: sourceIndex(for: draft.source)))
                    continue
                }
                guard !facts.contains(where: { $0.id == fact.id }) else {
                    omittedCount += 1
                    diagnostic?(.init(code: .duplicateFact, factIndex: factIndex,
                                      sourceIndex: sourceIndex(for: draft.source)))
                    continue
                }
                facts.append(fact)
            } catch let error as OpenAITextIssue where error == .invalidResponse {
                omittedCount += 1
                if let localDiagnostic {
                    diagnostic?(.init(code: localDiagnostic.code, factIndex: factIndex,
                                      sourceIndex: localDiagnostic.sourceIndex))
                } else {
                    diagnostic?(.init(code: .invalidFields, factIndex: factIndex,
                                      sourceIndex: sourceIndex(for: draft.source)))
                }
            }
        }
        return PatientWikiFactBindingResult(facts: facts, omittedCount: omittedCount)
    }

    private static func sourceIndex(for reference: String) -> Int? {
        guard reference.hasPrefix("F"), let index = Int(reference.dropFirst()), index > 0 else {
            return nil
        }
        return index - 1
    }

    func validate() throws {
        if [.procedure, .result, .screening, .immunization, .socialHistory].contains(draft.kind), draft.ips == nil {
            throw OpenAITextIssue.invalidResponse
        }
        try draft.ips?.validate(kind: draft.kind)
        if let terminology { try PatientIPSTerminology.validate(terminology, label: draft.label, kind: draft.kind) }
        let fields = [draft.label, draft.text, draft.quote, draft.date, draft.dosage, draft.method]
        let registration = source.id == patientID && source.path == "patient.yaml"
        let validator = PatientWikiStore()
        guard OpenPEPIdentifier.isPatient(patientID),
              mappingVersion == "openpep/wiki-measurements@1",
              registration || (validator.isWikiSourceID(source.id) && validator.isSafeSourcePath(source.path)),
              draft.source == source.id,
              source.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              !draft.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              fields.allSatisfy({ $0.count <= 3_000 && !$0.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) && ![9, 10, 13].contains($0.value)
              }) }),
              ["active", "resolved", "unknown"].contains(draft.clinicalStatus),
              ["confirmed", "suspected", "refuted", "unknown"].contains(draft.certainty),
              ["reported", "prescribed", "unknown"].contains(draft.medicationUse),
              ["final", "preliminary", "corrected", "unknown"].contains(draft.observationStatus),
              draft.date.isEmpty || Self.validDate(draft.date) else { throw OpenAITextIssue.invalidResponse }
        if draft.kind == .measurement {
            guard let value, value.isFinite, value > 0, !draft.date.isEmpty,
                  draft.value.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
                  (draft.measurement == "weight" && draft.unit == "kg" && value <= 1_000)
                    || (draft.measurement == "hba1c" && draft.unit == "%" && value <= 100) else {
                throw OpenAITextIssue.invalidResponse
            }
        } else if !draft.measurement.isEmpty || !draft.value.isEmpty || !draft.unit.isEmpty || !draft.method.isEmpty || draft.observationStatus != "unknown" {
            throw OpenAITextIssue.invalidResponse
        }
        if draft.kind != .medication && (!draft.dosage.isEmpty || draft.medicationUse != "unknown") {
            throw OpenAITextIssue.invalidResponse
        }
    }

    static func validDate(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    /// Conservative exact-label checks, not a clinical reconciliation engine.
    static func conflictingIDs(in facts: [Self]) -> Set<String> {
        let groups = Dictionary(grouping: facts) { fact in
            let d = fact.draft
            if d.kind == .socialHistory { return "social|" + (d.ips?.socialDomain ?? "") }
            if d.kind == .measurement { return "measurement|\(d.measurement)|\(d.date)|\(d.unit)|\(d.method)" }
            if [.procedure, .result, .screening, .immunization].contains(d.kind) {
                return d.kind.rawValue + "|" + PatientSearch.normalize(d.label) + "|" + d.date + "|" + (d.ips?.eventStatus ?? "unknown")
            }
            return d.kind.rawValue + "|" + PatientSearch.normalize(d.label)
        }
        var conflicts = Set<String>()
        for values in groups.values where values.count > 1 {
            if values.first?.draft.kind == .socialHistory,
               ["tobacco", "alcohol"].contains(values.first?.draft.ips?.socialDomain ?? "") {
                conflicts.formUnion(values.map(\.id))
                continue
            }
            let variants = Set(values.map { fact -> String in
                let d = fact.draft
                if d.kind == .measurement { return d.value }
                if d.kind == .socialHistory { return d.text + "|" + d.date }
                if d.kind == .medication { return d.dosage + "|" + d.clinicalStatus + "|" + (d.ips?.frequency ?? "") + "|" + (d.ips?.route ?? "") }
                return d.clinicalStatus + "|" + d.certainty + "|" + (d.ips?.eventStatus ?? "unknown") + "|" + (d.ips?.course ?? "unknown")
            })
            if variants.count > 1 { conflicts.formUnion(values.map(\.id)) }
        }
        return conflicts
    }
}

struct PatientWikiReview: Codable, Equatable, Sendable {
    enum Decision: String, Codable, Sendable { case accepted, rejected, pending }
    let fact: PatientWikiFact
    let decision: Decision
    let reviewer: String
    let reviewedAt: String
    var note: String? = nil
    var replacesFactID: String? = nil

    var requiresIPSSchema: Bool { fact.requiresIPSSchema || decision == .pending || note != nil || replacesFactID != nil }

    func validateIPSFields() throws {
        guard note.map({ $0.count <= 3_000 && !$0.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) && ![9, 10, 13].contains($0.value)
        }) }) ?? true,
        replacesFactID.map({ $0 != fact.id && $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }) ?? true else {
            throw OpenAITextIssue.invalidResponse
        }
    }
}

struct PatientWikiReviews: Codable, Sendable {
    var schema = "openpep/wiki-reviews@1"
    let patientID: String
    var records: [PatientWikiReview] = []

    func latestReview(for fact: PatientWikiFact) -> PatientWikiReview? {
        records.last { $0.fact.id == fact.id }
    }

    var supersededIDs: Set<String> {
        var result = Set<String>()
        for record in records {
            if let replaced = record.replacesFactID {
                result.remove(record.fact.id)
                result.insert(replaced)
            }
        }
        return result
    }

    func validateReplacementHistory() throws {
        var latest: [String: PatientWikiReview] = [:]
        for record in records {
            if let id = record.replacesFactID {
                guard let original = latest[id], original.decision == .rejected,
                      original.fact.patientID == record.fact.patientID,
                      original.fact.source == record.fact.source,
                      original.fact.draft.kind == record.fact.draft.kind,
                      original.fact.draft.quote == record.fact.draft.quote,
                      original.fact.mappingVersion == record.fact.mappingVersion else {
                    throw OpenAITextIssue.invalidResponse
                }
            }
            latest[record.fact.id] = record
        }
    }

    func decision(for fact: PatientWikiFact) -> PatientWikiReview.Decision? {
        records.last(where: { $0.fact.id == fact.id })?.decision
    }

    /// Previously accepted extractions whose evidence no longer matches the loaded sources.
    /// This is documentary freshness, not confirmation of current clinical status.
    func outdatedAccepted(in context: PatientWikiContext) -> [PatientWikiFact] {
        guard patientID == context.patient.patientID else { return [] }
        var seen = Set<String>()
        return records.reversed().compactMap { review in
            guard !supersededIDs.contains(review.fact.id), seen.insert(review.fact.id).inserted, review.decision == .accepted,
                  review.fact.patientID == patientID, !review.fact.matches(context.entries) else { return nil }
            return review.fact
        }.sorted { $0.id < $1.id }
    }

    func accepted(in context: PatientWikiContext) -> [PatientWikiFact] {
        guard patientID == context.patient.patientID else { return [] }
        var seen = Set<String>()
        return records.reversed().compactMap { review in
            guard !supersededIDs.contains(review.fact.id), seen.insert(review.fact.id).inserted, review.decision == .accepted,
                  review.fact.patientID == patientID, review.fact.matches(context.entries) else { return nil }
            return review.fact
        }.sorted { $0.id < $1.id }
    }

    /// Facts available to the single IPS preview. A prior rejection remains a
    /// durable decision and is returned with its original fact so the UI can
    /// show it as excluded and offer a deliberate reconsideration. It is never
    /// selected silently in a later generation. A prior acceptance may be
    /// carried forward only while its exact evidence still matches the source.
    func candidates(for summary: PatientWikiSummary, in context: PatientWikiContext) -> [PatientWikiFact] {
        guard patientID == context.patient.patientID,
              summary.sources.allSatisfy({ source in context.entries.contains { $0.id == source.id && $0.source == source.path } }) else {
            return []
        }
        var factsByID: [String: PatientWikiFact] = [:]
        let priorFacts = records.reversed().compactMap { review -> PatientWikiFact? in
            guard review.fact.patientID == patientID, review.fact.matches(context.entries) else { return nil }
            return review.fact
        }
        for fact in summary.proposals + priorFacts {
            guard !supersededIDs.contains(fact.id), fact.patientID == patientID, fact.matches(context.entries) else { continue }
            factsByID[fact.id] = fact
        }
        return factsByID.values.sorted {
            $0.draft.label.localizedStandardCompare($1.draft.label) == .orderedAscending
                || ($0.draft.label == $1.draft.label && $0.id < $1.id)
        }
    }
}

extension PatientWikiStore {
    func loadReviews(for patient: PatientSummary) throws -> (PatientWikiReviews, Data?) {
        let url = try validatedWikiDirectory(for: patient).appending(path: "review.json")
        guard let data = try readManagedFileIfPresent(url) else {
            return (PatientWikiReviews(patientID: patient.patientID), nil)
        }
        let reviews = try JSONDecoder().decode(PatientWikiReviews.self, from: data)
        guard ["openpep/wiki-reviews@1", "openpep/wiki-reviews@2"].contains(reviews.schema), reviews.patientID == patient.patientID,
              reviews.records.count <= 1_000 else { throw OpenAITextIssue.invalidResponse }
        for record in reviews.records {
            try record.validateIPSFields()
            guard reviews.schema == "openpep/wiki-reviews@2" || !record.requiresIPSSchema else { throw OpenAITextIssue.invalidResponse }
            try record.fact.validate()
            guard record.fact.patientID == patient.patientID, !record.reviewer.isEmpty,
                  record.reviewer.count <= 300, !record.reviewer.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  ISO8601DateFormatter().date(from: record.reviewedAt) != nil else { throw OpenAITextIssue.invalidResponse }
        }
        try reviews.validateReplacementHistory()
        return (reviews, data)
    }

    func saveReview(_ review: PatientWikiReview, for patient: PatientSummary,
                    expectedData: Data?, validateSources: () throws -> Void) throws {
        var (reviews, data) = try loadReviews(for: patient)
        guard data == expectedData, review.fact.patientID == patient.patientID,
              !review.reviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              review.reviewer.count <= 300, !review.reviewer.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              ISO8601DateFormatter().date(from: review.reviewedAt) != nil,
              reviews.records.count < 1_000 else { throw PatientAIIssue.changed }
        try review.fact.validate()
        try review.validateIPSFields()
        if review.requiresIPSSchema { reviews.schema = "openpep/wiki-reviews@2" }
        reviews.records.append(review)
        try reviews.validateReplacementHistory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let candidate = try encoder.encode(reviews)
        guard candidate.count <= 2_097_152 else { throw OpenAITextIssue.responseTooLarge }
        let wiki = try validatedWikiDirectory(for: patient)
        try coordinatedWrite(wiki) { directory in
            try publish(candidate, to: directory.appending(path: "review.json"),
                        expectedData: expectedData, validateCompanion: validateSources)
        }
        PatientClinicalChange.post(for: patient, kind: .reviews)
    }

    /// Persists one deliberate review action for a complete IPS selection.
    /// The records are still individual historical decisions on disk, but the
    /// caller validates and publishes them as one coordinated write so the UI
    /// does not ask the professional to confirm each extraction separately.
    func saveReviews(_ newReviews: [PatientWikiReview], for patient: PatientSummary,
                     expectedData: Data?, validateSources: () throws -> Void) throws {
        guard !newReviews.isEmpty,
              Set(newReviews.map { $0.fact.id }).count == newReviews.count else {
            throw PatientAIIssue.changed
        }
        var (reviews, data) = try loadReviews(for: patient)
        guard data == expectedData,
              reviews.records.count + newReviews.count <= 1_000 else {
            throw PatientAIIssue.changed
        }
        for review in newReviews {
            guard review.fact.patientID == patient.patientID,
                  !review.reviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  review.reviewer.count <= 300,
                  !review.reviewer.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  ISO8601DateFormatter().date(from: review.reviewedAt) != nil else {
                throw PatientAIIssue.changed
            }
            try review.fact.validate()
            try review.validateIPSFields()
        }
        if newReviews.contains(where: \.requiresIPSSchema) { reviews.schema = "openpep/wiki-reviews@2" }
        reviews.records.append(contentsOf: newReviews)
        try reviews.validateReplacementHistory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let candidate = try encoder.encode(reviews)
        guard candidate.count <= 2_097_152 else { throw OpenAITextIssue.responseTooLarge }
        let wiki = try validatedWikiDirectory(for: patient)
        try coordinatedWrite(wiki) { directory in
            try publish(candidate, to: directory.appending(path: "review.json"),
                        expectedData: expectedData, validateCompanion: validateSources)
        }
        PatientClinicalChange.post(for: patient, kind: .reviews)
    }
}
