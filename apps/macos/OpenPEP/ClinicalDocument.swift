// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

struct EncounterMetadata: Equatable, Sendable {
    let encounterID: String
    let patientID: String
    let appointmentID: String?
    let status: String
    let modality: String
    let startedAt: String
    let createdBy: String
    let templateID: String?
    let templateVersion: String?
    let telemedicine: TelemedicineEncounterMetadata?
    let trashedAt: String?
    let remoteAccessURL: String?

    init(
        encounterID: String,
        patientID: String,
        appointmentID: String?,
        status: String,
        modality: String,
        startedAt: String,
        createdBy: String,
        templateID: String?,
        templateVersion: String?,
        telemedicine: TelemedicineEncounterMetadata?,
        trashedAt: String? = nil,
        remoteAccessURL: String? = nil
    ) {
        self.encounterID = encounterID
        self.patientID = patientID
        self.appointmentID = appointmentID
        self.status = status
        self.modality = modality
        self.startedAt = startedAt
        self.createdBy = createdBy
        self.templateID = templateID
        self.templateVersion = templateVersion
        self.telemedicine = telemedicine
        self.trashedAt = trashedAt
        self.remoteAccessURL = remoteAccessURL
    }
}

enum TelemedicineConsent: String, Equatable, Sendable, CaseIterable {
    case confirmed
    case declined
    case notRecorded = "not_recorded"
}

struct TelemedicineEncounterMetadata: Equatable, Sendable {
    let consent: TelemedicineConsent
    let declaredLocation: String?
    let participants: [String]
    let limitations: String?
    let contingency: String?
}

struct ClinicalDraftMetadata: Equatable, Sendable {
    let noteID: String
    let patientID: String
    let encounterID: String
    let status: String
    let noteType: String
    let authorID: String
    let createdAt: String
    let updatedAt: String
    let schema: String
    let sourceIDs: [String]
    let aiAssistance: ClinicalAIAssistance

    init(
        noteID: String,
        patientID: String,
        encounterID: String,
        status: String,
        noteType: String,
        authorID: String,
        createdAt: String,
        updatedAt: String,
        schema: String = "openpep/clinical-note@1",
        sourceIDs: [String] = [],
        aiAssistance: ClinicalAIAssistance = .none
    ) {
        self.noteID = noteID
        self.patientID = patientID
        self.encounterID = encounterID
        self.status = status
        self.noteType = noteType
        self.authorID = authorID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schema = schema
        self.sourceIDs = sourceIDs
        self.aiAssistance = aiAssistance
    }
}

struct ClinicalAIAssistance: Equatable, Sendable {
    let used: Bool
    let generationID: String?
    let reviewedBy: String?
    let provenanceSchema: String?
    let engine: String?
    let promptVersion: String?
    let locale: String?
    let generatedAt: String?
    let sourceSHA256: String?
    let chunkCount: Int?
    let generations: [ClinicalAIGeneration]

    static let none = ClinicalAIAssistance(
        used: false, generationID: nil, reviewedBy: nil, provenanceSchema: nil,
        engine: nil, promptVersion: nil, locale: nil, generatedAt: nil,
        sourceSHA256: nil, chunkCount: nil, generations: []
    )
}

struct ClinicalAIGeneration: Equatable, Sendable {
    let generationID: String
    let acceptedBy: String
    let acceptedAt: String?
    let sourceID: String
    let sourceSHA256: String
    let provenanceSchema: String
    let engine: String
    let model: String?
    let responseID: String?
    let promptVersion: String?
    let locale: String?
    let generatedAt: String?
    let chunkCount: Int?
}

struct ParsedClinicalDraft: Equatable, Sendable {
    let metadata: ClinicalDraftMetadata
    let frontmatter: String
    let body: String
}

enum ClinicalDocumentValidator {
    private static let uuidV7 =
        "[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"

    static func validateEncounter(data: Data, source: String) throws -> EncounterMetadata {
        let document = try VaultManifestValidator.parseMarkdownDocument(data: data, source: source)
        guard document.body.isEmpty else {
            throw issue(
                "clinical_document.encounter_body",
                "/body",
                "O encontro deste perfil não contém corpo Markdown."
            )
        }
        let root = try mapping(document.metadata)
        let requiredFields = [
            "schema", "encounter_id", "patient_id", "appointment_id", "status",
            "modality", "started_at", "ended_at", "created_by", "x_actor_assurance",
        ]
        try validateFields(
            root,
            required: requiredFields,
            allowed: Set(requiredFields + ["template_id", "template_version", "telemedicine"])
        )

        let schema = try string(root, "schema")
        let encounterID = try string(root, "encounter_id")
        let patientID = try string(root, "patient_id")
        let status = try string(root, "status")
        let modality = try string(root, "modality")
        let startedAt = try string(root, "started_at")
        let createdBy = try string(root, "created_by")
        let appointmentID = try optionalIdentifier(root["appointment_id"], prefix: "appt_", path: "/appointment_id")
        try require(root["ended_at"] == .null, rule: "schema.type", path: "/ended_at")
        try require(schema == "openpep/encounter@1", rule: "schema.const", path: "/schema")
        try require(matches(encounterID, "^enc_\(uuidV7)$"), rule: "schema.pattern", path: "/encounter_id")
        try require(matches(patientID, "^pt_\(uuidV7)$"), rule: "schema.pattern", path: "/patient_id")
        try require(status == "in_progress", rule: "schema.const", path: "/status")
        try require(["in_person", "telemedicine"].contains(modality), rule: "schema.enum", path: "/modality")
        try require(isUTCDate(startedAt), rule: "schema.format", path: "/started_at")
        try require(matches(createdBy, "^usr_\(uuidV7)$"), rule: "schema.pattern", path: "/created_by")
        try require(
            try string(root, "x_actor_assurance") == "synthetic_unauthenticated",
            rule: "schema.const",
            path: "/x_actor_assurance"
        )
        let templateID = try optionalString(root["template_id"], path: "/template_id", maximum: 240)
        let templateVersion = try optionalString(root["template_version"], path: "/template_version", maximum: 71)
        try require(
            (templateID == nil) == (templateVersion == nil),
            rule: "clinical_document.template_pair",
            path: "/template_id"
        )
        if let templateVersion {
            try require(
                matches(templateVersion, #"^sha256:[0-9a-f]{64}$"#),
                rule: "schema.pattern",
                path: "/template_version"
            )
        }
        if modality == "telemedicine" {
            try require(
                templateID != nil && templateVersion != nil,
                rule: "schema.required",
                path: "/template_id"
            )
        }
        let telemedicine = try validateTelemedicine(root["telemedicine"], modality: modality)
        let trashedAt = try root["x_openpep_trashed_at"].map { value in
            guard case let .string(text) = value, !text.isEmpty, text.count <= 40 else {
                throw issue("schema.type", "/x_openpep_trashed_at", "O marcador da lixeira deve ser uma data UTC.")
            }
            return text
        }
        if let trashedAt {
            try require(isUTCDate(trashedAt), rule: "schema.format", path: "/x_openpep_trashed_at")
        }
        let remoteAccessURL = try root["x_openpep_remote_access_url"].map { value in
            guard case let .string(text) = value, !text.isEmpty, text.count <= 2_048 else {
                throw issue("schema.type", "/x_openpep_remote_access_url", "O link remoto deve ser texto HTTPS.")
            }
            return text
        }
        if let remoteAccessURL {
            _ = try TelemedicineURLBuilder.savedLinkURL(remoteAccessURL)
        }
        return EncounterMetadata(
            encounterID: encounterID,
            patientID: patientID,
            appointmentID: appointmentID,
            status: status,
            modality: modality,
            startedAt: startedAt,
            createdBy: createdBy,
            templateID: templateID,
            templateVersion: templateVersion,
            telemedicine: telemedicine,
            trashedAt: trashedAt,
            remoteAccessURL: remoteAccessURL
        )
    }

    static func validateDraft(data: Data, source: String) throws -> ParsedClinicalDraft {
        let document = try VaultManifestValidator.parseMarkdownDocument(data: data, source: source)
        guard document.body.hasPrefix("\n"), document.body.hasSuffix("\n") else {
            throw issue(
                "clinical_document.draft_body",
                "/body",
                "O rascunho exige uma linha vazia após o frontmatter e LF final."
            )
        }
        let root = try mapping(document.metadata)
        let fields = [
            "schema", "note_id", "patient_id", "encounter_id", "status", "note_type",
            "author_id", "created_at", "updated_at", "source_ids", "ai_assistance",
            "finalization", "x_actor_assurance",
        ]
        try validateFields(root, required: fields, allowed: Set(fields))

        let schema = try string(root, "schema")
        let noteID = try string(root, "note_id")
        let patientID = try string(root, "patient_id")
        let encounterID = try string(root, "encounter_id")
        let status = try string(root, "status")
        let noteType = try string(root, "note_type")
        let authorID = try string(root, "author_id")
        let createdAt = try string(root, "created_at")
        let updatedAt = try string(root, "updated_at")

        try require(
            ["openpep/clinical-note@1", "openpep/clinical-note@2", "openpep/clinical-note@3", "openpep/clinical-note@4"].contains(schema),
            rule: "schema.const",
            path: "/schema"
        )
        try require(matches(noteID, "^note_\(uuidV7)$"), rule: "schema.pattern", path: "/note_id")
        try require(matches(patientID, "^pt_\(uuidV7)$"), rule: "schema.pattern", path: "/patient_id")
        try require(matches(encounterID, "^enc_\(uuidV7)$"), rule: "schema.pattern", path: "/encounter_id")
        try require(status == "draft", rule: "schema.const", path: "/status")
        try require(noteType == "progress", rule: "schema.const", path: "/note_type")
        try require(matches(authorID, "^usr_\(uuidV7)$"), rule: "schema.pattern", path: "/author_id")
        try require(isUTCDate(createdAt), rule: "schema.format", path: "/created_at")
        try require(isUTCDate(updatedAt), rule: "schema.format", path: "/updated_at")
        let sourceIDs = try validateSources(root["source_ids"], schema: schema)
        let aiAssistance = try validateAIAssistance(root["ai_assistance"], schema: schema)
        if schema == "openpep/clinical-note@3" || schema == "openpep/clinical-note@4" {
            try require(
                aiAssistance.generations.map(\.sourceID) == sourceIDs,
                rule: "clinical_document.ai_source_set_mismatch",
                path: "/source_ids"
            )
        }
        try require(root["finalization"] == .null, rule: "schema.type", path: "/finalization")
        try require(
            try string(root, "x_actor_assurance") == "synthetic_unauthenticated",
            rule: "schema.const",
            path: "/x_actor_assurance"
        )

        return ParsedClinicalDraft(
            metadata: ClinicalDraftMetadata(
                noteID: noteID,
                patientID: patientID,
                encounterID: encounterID,
                status: status,
                noteType: noteType,
                authorID: authorID,
                createdAt: createdAt,
                updatedAt: updatedAt,
                schema: schema,
                sourceIDs: sourceIDs,
                aiAssistance: aiAssistance
            ),
            frontmatter: document.frontmatter,
            body: String(document.body.dropFirst())
        )
    }

    static func bind(
        encounter: EncounterMetadata,
        draft: ClinicalDraftMetadata,
        expectedPatientID: String
    ) throws {
        try require(encounter.patientID == expectedPatientID, rule: "clinical_document.patient_mismatch", path: "/patient_id")
        try require(draft.patientID == encounter.patientID, rule: "clinical_document.patient_mismatch", path: "/patient_id")
        try require(draft.encounterID == encounter.encounterID, rule: "clinical_document.encounter_mismatch", path: "/encounter_id")
        try require(draft.authorID == encounter.createdBy, rule: "clinical_document.author_mismatch", path: "/author_id")
        if draft.schema == "openpep/clinical-note@2" {
            try require(
                draft.aiAssistance.reviewedBy == draft.authorID,
                rule: "clinical_document.reviewer_mismatch",
                path: "/ai_assistance/reviewed_by"
            )
        }
        if draft.schema == "openpep/clinical-note@3" || draft.schema == "openpep/clinical-note@4" {
            for (index, generation) in draft.aiAssistance.generations.enumerated() {
                try require(
                    generation.acceptedBy == draft.authorID,
                    rule: "clinical_document.reviewer_mismatch",
                    path: "/ai_assistance/generations/\(index)/accepted_by"
                )
            }
        }
    }

    static func bindAISource(
        draft: ClinicalDraftMetadata,
        encounterID: String,
        assets: [RawAssetSummary]
    ) throws {
        if draft.schema == "openpep/clinical-note@3" || draft.schema == "openpep/clinical-note@4" {
            for (index, generation) in draft.aiAssistance.generations.enumerated() {
                guard let source = assets.first(where: { $0.assetID == generation.sourceID }) else {
                    throw issue(
                        "clinical_document.ai_source_missing",
                        "/ai_assistance/generations/\(index)/source_id",
                        "A fonte local declarada pelo rascunho assistido não foi encontrada."
                    )
                }
                try require(
                    source.encounterID == encounterID,
                    rule: "clinical_document.ai_source_encounter_mismatch",
                    path: "/ai_assistance/generations/\(index)/source_id"
                )
                try require(
                    source.mediaType == "text/plain" && source.fileExtension == "txt",
                    rule: "clinical_document.ai_source_type_mismatch",
                    path: "/ai_assistance/generations/\(index)/source_id"
                )
                try require(
                    source.sha256 == generation.sourceSHA256,
                    rule: "clinical_document.ai_source_hash_mismatch",
                    path: "/ai_assistance/generations/\(index)/source_sha256"
                )
            }
            return
        }
        guard draft.schema == "openpep/clinical-note@2" else { return }
        guard let sourceID = draft.sourceIDs.first,
              draft.sourceIDs.count == 1,
              let expectedSHA256 = draft.aiAssistance.sourceSHA256,
              let source = assets.first(where: { $0.assetID == sourceID }) else {
            throw issue(
                "clinical_document.ai_source_missing",
                "/source_ids/0",
                "A fonte local declarada pelo rascunho assistido não foi encontrada."
            )
        }
        try require(
            source.encounterID == encounterID,
            rule: "clinical_document.ai_source_encounter_mismatch",
            path: "/source_ids/0"
        )
        try require(
            source.mediaType == "text/plain" && source.fileExtension == "txt",
            rule: "clinical_document.ai_source_type_mismatch",
            path: "/source_ids/0"
        )
        try require(
            source.sha256 == expectedSHA256,
            rule: "clinical_document.ai_source_hash_mismatch",
            path: "/ai_assistance/source_sha256"
        )
    }

    private static func mapping(_ value: YAMLValue) throws -> [String: YAMLValue] {
        guard case let .mapping(root) = value else {
            throw issue("schema.type", "/", "O frontmatter deve ser um mapa.")
        }
        return root
    }

    private static func validateFields(
        _ root: [String: YAMLValue],
        required: [String],
        allowed: Set<String>
    ) throws {
        for key in root.keys.sorted() where !allowed.contains(key) && !key.hasPrefix("x_") {
            throw issue("schema.additionalProperties", "/\(key)", "O campo não é permitido.")
        }
        for field in required where root[field] == nil {
            throw issue("schema.required", "/\(field)", "O campo obrigatório está ausente.")
        }
    }

    private static func validateTelemedicine(
        _ value: YAMLValue?,
        modality: String
    ) throws -> TelemedicineEncounterMetadata? {
        if modality == "in_person" {
            try require(value == nil || value == .null, rule: "schema.type", path: "/telemedicine")
            return nil
        }
        guard case let .mapping(root)? = value else {
            throw issue("schema.required", "/telemedicine", "A teleconsulta exige os fatos declarados do encontro.")
        }
        let fields = ["consent", "declared_location", "participants", "limitations", "contingency"]
        try validateNestedFields(root, fields: fields, path: "/telemedicine")
        guard let consent = TelemedicineConsent(rawValue: try string(root, "consent")) else {
            throw issue("schema.enum", "/telemedicine/consent", "O estado do consentimento não é permitido.")
        }
        let participants = try stringSequence(root["participants"], path: "/telemedicine/participants", maximum: 10)
        try require(Set(participants).count == participants.count, rule: "schema.uniqueItems", path: "/telemedicine/participants")
        return TelemedicineEncounterMetadata(
            consent: consent,
            declaredLocation: try optionalString(root["declared_location"], path: "/telemedicine/declared_location", maximum: 200),
            participants: participants,
            limitations: try optionalString(root["limitations"], path: "/telemedicine/limitations", maximum: 1_000),
            contingency: try optionalString(root["contingency"], path: "/telemedicine/contingency", maximum: 1_000)
        )
    }

    private static func optionalIdentifier(
        _ value: YAMLValue?,
        prefix: String,
        path: String
    ) throws -> String? {
        if value == .null { return nil }
        guard case let .string(identifier)? = value,
              matches(identifier, "^\(prefix)\(uuidV7)$") else {
            throw issue("schema.pattern", path, "O identificador não é válido.")
        }
        return identifier
    }

    private static func optionalString(
        _ value: YAMLValue?,
        path: String,
        maximum: Int
    ) throws -> String? {
        if value == nil || value == .null { return nil }
        guard case let .string(text)? = value, !text.isEmpty, text.count <= maximum else {
            throw issue("schema.length", path, "O texto possui tamanho inválido.")
        }
        return text
    }

    private static func stringSequence(
        _ value: YAMLValue?,
        path: String,
        maximum: Int
    ) throws -> [String] {
        guard case let .sequence(values)? = value, values.count <= maximum else {
            throw issue("schema.type", path, "O campo deve ser uma lista curta.")
        }
        return try values.enumerated().map { index, value in
            guard case let .string(text) = value, !text.isEmpty, text.count <= 200 else {
                throw issue("schema.length", "\(path)/\(index)", "O participante possui tamanho inválido.")
            }
            return text
        }
    }

    private static func validateSources(_ value: YAMLValue?, schema: String) throws -> [String] {
        guard case let .sequence(values)? = value else {
            throw issue("schema.type", "/source_ids", "source_ids deve ser uma lista.")
        }
        if schema == "openpep/clinical-note@1" {
            guard values.isEmpty else {
                throw issue(
                    "schema.maxItems",
                    "/source_ids",
                    "O perfil MAC-003A.2 ainda não vincula fontes ao rascunho."
                )
            }
            return []
        }
        let maximum = ["openpep/clinical-note@3", "openpep/clinical-note@4"].contains(schema) ? 100 : 1
        guard !values.isEmpty, values.count <= maximum else {
            throw issue(
                "schema.items",
                "/source_ids",
                "O rascunho assistido exige fontes locais válidas."
            )
        }
        let assetIDs = try values.enumerated().map { index, value in
            guard case let .string(assetID) = value,
                  matches(assetID, "^asset_\(uuidV7)$") else {
                throw issue("schema.items", "/source_ids/\(index)", "O identificador da fonte não é válido.")
            }
            return assetID
        }
        try require(Set(assetIDs).count == assetIDs.count, rule: "schema.uniqueItems", path: "/source_ids")
        return assetIDs
    }

    private static func validateAIAssistance(_ value: YAMLValue?, schema: String) throws -> ClinicalAIAssistance {
        guard case let .mapping(ai)? = value else {
            throw issue("schema.type", "/ai_assistance", "ai_assistance deve ser um mapa.")
        }
        if schema == "openpep/clinical-note@1" {
            try validateNestedFields(
                ai,
                fields: ["used", "generation_id", "reviewed_by"],
                path: "/ai_assistance"
            )
            try require(ai["used"] == .boolean(false), rule: "schema.const", path: "/ai_assistance/used")
            try require(ai["generation_id"] == .null, rule: "schema.type", path: "/ai_assistance/generation_id")
            try require(ai["reviewed_by"] == .null, rule: "schema.type", path: "/ai_assistance/reviewed_by")
            return .none
        }
        if schema == "openpep/clinical-note@3" || schema == "openpep/clinical-note@4" {
            return try validateAIGenerations(ai, schema: schema)
        }
        let fields = [
            "used", "generation_id", "reviewed_by", "provenance_schema", "engine",
            "prompt_version", "locale", "generated_at", "source_sha256", "chunk_count",
        ]
        try validateNestedFields(
            ai,
            fields: fields,
            path: "/ai_assistance"
        )
        try require(ai["used"] == .boolean(true), rule: "schema.const", path: "/ai_assistance/used")
        let generationID = try string(ai, "generation_id")
        let reviewedBy = try string(ai, "reviewed_by")
        let generatedAt = try string(ai, "generated_at")
        let sourceSHA256 = try string(ai, "source_sha256")
        guard case let .integer(chunkCount)? = ai["chunk_count"] else {
            throw issue("schema.type", "/ai_assistance/chunk_count", "chunk_count deve ser inteiro.")
        }
        try require(matches(generationID, "^gen_\(uuidV7)$"), rule: "schema.pattern", path: "/ai_assistance/generation_id")
        try require(matches(reviewedBy, "^usr_\(uuidV7)$"), rule: "schema.pattern", path: "/ai_assistance/reviewed_by")
        try require(try string(ai, "provenance_schema") == ConsultationSummaryProvenance.schema, rule: "schema.const", path: "/ai_assistance/provenance_schema")
        try require(try string(ai, "engine") == ConsultationSummaryProvenance.engine, rule: "schema.const", path: "/ai_assistance/engine")
        try require(try string(ai, "prompt_version") == ConsultationSummaryProvenance.promptVersion, rule: "schema.const", path: "/ai_assistance/prompt_version")
        try require(try string(ai, "locale") == "pt-BR", rule: "schema.const", path: "/ai_assistance/locale")
        try require(isUTCDate(generatedAt), rule: "schema.format", path: "/ai_assistance/generated_at")
        try require(matches(sourceSHA256, "^[0-9a-f]{64}$"), rule: "schema.pattern", path: "/ai_assistance/source_sha256")
        try require((1...9999).contains(chunkCount), rule: "schema.maximum", path: "/ai_assistance/chunk_count")
        return ClinicalAIAssistance(
            used: true,
            generationID: generationID,
            reviewedBy: reviewedBy,
            provenanceSchema: ConsultationSummaryProvenance.schema,
            engine: ConsultationSummaryProvenance.engine,
            promptVersion: ConsultationSummaryProvenance.promptVersion,
            locale: "pt-BR",
            generatedAt: generatedAt,
            sourceSHA256: sourceSHA256,
            chunkCount: chunkCount,
            generations: []
        )
    }

    private static func validateAIGenerations(
        _ ai: [String: YAMLValue],
        schema: String
    ) throws -> ClinicalAIAssistance {
        try validateNestedFields(ai, fields: ["used", "generations"], path: "/ai_assistance")
        try require(ai["used"] == .boolean(true), rule: "schema.const", path: "/ai_assistance/used")
        guard case let .sequence(values)? = ai["generations"],
              (1...100).contains(values.count) else {
            throw issue("schema.items", "/ai_assistance/generations", "O rascunho exige de uma a 100 gerações aceitas.")
        }
        let fields = [
            "generation_id", "accepted_by", "accepted_at", "source_id", "source_sha256",
            "provenance_schema", "engine", "model", "response_id", "prompt_version", "locale",
            "generated_at", "chunk_count",
        ]
        let generations = try values.enumerated().map { index, value in
            let path = "/ai_assistance/generations/\(index)"
            guard case let .mapping(root) = value else {
                throw issue("schema.type", path, "A geração aceita deve ser um mapa.")
            }
            try validateNestedFields(root, fields: fields, path: path)
            let generationID = try requiredString(root["generation_id"], path: "\(path)/generation_id", maximum: 41)
            let acceptedBy = try requiredString(root["accepted_by"], path: "\(path)/accepted_by", maximum: 40)
            let acceptedAt = try nullableString(root["accepted_at"], path: "\(path)/accepted_at", maximum: 40)
            let sourceID = try requiredString(root["source_id"], path: "\(path)/source_id", maximum: 42)
            let sourceSHA256 = try requiredString(root["source_sha256"], path: "\(path)/source_sha256", maximum: 64)
            let provenance = try requiredString(root["provenance_schema"], path: "\(path)/provenance_schema", maximum: 80)
            let engine = try requiredString(root["engine"], path: "\(path)/engine", maximum: 256)
            try require(matches(generationID, "^gen_\(uuidV7)$"), rule: "schema.pattern", path: "\(path)/generation_id")
            try require(matches(acceptedBy, "^usr_\(uuidV7)$"), rule: "schema.pattern", path: "\(path)/accepted_by")
            if let acceptedAt {
                try require(isUTCDate(acceptedAt), rule: "schema.format", path: "\(path)/accepted_at")
            } else {
                try require(schema == "openpep/clinical-note@3" && engine == ConsultationSummaryProvenance.engine,
                            rule: "schema.type", path: "\(path)/accepted_at")
            }
            try require(matches(sourceID, "^asset_\(uuidV7)$"), rule: "schema.pattern", path: "\(path)/source_id")
            try require(matches(sourceSHA256, "^[0-9a-f]{64}$"), rule: "schema.pattern", path: "\(path)/source_sha256")
            let allowedProvenance = [
                ConsultationSummaryProvenance.schema,
                "openpep/patient-ai-provenance@1",
            ] + (schema == "openpep/clinical-note@4" ? ["openpep/progressive-summary-provenance@1"] : [])
            try require(allowedProvenance.contains(provenance), rule: "schema.enum", path: "\(path)/provenance_schema")
            let model = try nullableString(root["model"], path: "\(path)/model", maximum: 256)
            let responseID = try nullableString(root["response_id"], path: "\(path)/response_id", maximum: 256)
            let promptVersion = try nullableString(root["prompt_version"], path: "\(path)/prompt_version", maximum: 256)
            let locale = try nullableString(root["locale"], path: "\(path)/locale", maximum: 64)
            let generatedAt = try nullableString(root["generated_at"], path: "\(path)/generated_at", maximum: 40)
            if let generatedAt {
                try require(isUTCDate(generatedAt), rule: "schema.format", path: "\(path)/generated_at")
            }
            let chunkCount = try nullableInteger(root["chunk_count"], path: "\(path)/chunk_count")
            if let chunkCount {
                try require((1...9999).contains(chunkCount), rule: "schema.maximum", path: "\(path)/chunk_count")
            }
            if schema == "openpep/clinical-note@4" && provenance == "openpep/progressive-summary-provenance@1" {
                let progressivePromptVersions = [
                    "openpep/progressive-consultation-summary-pt-BR@1",
                    "openpep/progressive-consultation-summary-pt-BR@2",
                    "openpep/progressive-consultation-summary-pt-BR@3",
                    "openpep/progressive-consultation-summary-pt-BR@4",
                    "openpep/progressive-consultation-summary-pt-BR@5",
                ]
                let finalApplePrompt = AIPromptCatalog.finalConsultationSummaryApple.id
                try require(
                    acceptedAt != nil &&
                    (promptVersion.map(progressivePromptVersions.contains) == true ||
                     (promptVersion == finalApplePrompt && engine == ConsultationSummaryProvenance.engine)) &&
                    locale == "pt-BR" && generatedAt != nil && chunkCount != nil &&
                    ((engine == ConsultationSummaryProvenance.engine && model == nil && responseID == nil) ||
                     (engine == "openai/responses" && model != nil && responseID != nil)),
                    rule: "clinical_document.ai_provenance_profile", path: path
                )
            } else if provenance == "openpep/patient-ai-provenance@1" {
                try require(engine == "openai/responses" && acceptedAt != nil && model != nil && responseID != nil,
                            rule: "clinical_document.ai_provenance_profile", path: path)
            } else {
                try require(engine == ConsultationSummaryProvenance.engine &&
                            model == nil && responseID == nil &&
                            promptVersion == ConsultationSummaryProvenance.promptVersion &&
                            locale == "pt-BR" && generatedAt != nil && chunkCount != nil,
                            rule: "clinical_document.ai_provenance_profile", path: path)
            }
            return ClinicalAIGeneration(
                generationID: generationID,
                acceptedBy: acceptedBy,
                acceptedAt: acceptedAt,
                sourceID: sourceID,
                sourceSHA256: sourceSHA256,
                provenanceSchema: provenance,
                engine: engine,
                model: model,
                responseID: responseID,
                promptVersion: promptVersion,
                locale: locale,
                generatedAt: generatedAt,
                chunkCount: chunkCount
            )
        }
        let generationIDs = generations.map(\.generationID)
        try require(Set(generationIDs).count == generationIDs.count, rule: "clinical_document.duplicate_generation", path: "/ai_assistance/generations")
        let sourceIDs = generations.map(\.sourceID)
        try require(Set(sourceIDs).count == sourceIDs.count, rule: "clinical_document.ai_source_set_mismatch", path: "/source_ids")
        return ClinicalAIAssistance(
            used: true, generationID: nil, reviewedBy: nil, provenanceSchema: nil,
            engine: nil, promptVersion: nil, locale: nil, generatedAt: nil,
            sourceSHA256: nil, chunkCount: nil, generations: generations
        )
    }

    private static func requiredString(_ value: YAMLValue?, path: String, maximum: Int) throws -> String {
        guard case let .string(text)? = value, !text.isEmpty, text.count <= maximum else {
            throw issue("schema.type", path, "O campo deve ser texto não vazio.")
        }
        return text
    }

    private static func nullableString(_ value: YAMLValue?, path: String, maximum: Int) throws -> String? {
        if value == .null { return nil }
        return try requiredString(value, path: path, maximum: maximum)
    }

    private static func nullableInteger(_ value: YAMLValue?, path: String) throws -> Int? {
        if value == .null { return nil }
        guard case let .integer(number)? = value else {
            throw issue("schema.type", path, "O campo deve ser inteiro ou null.")
        }
        return number
    }

    private static func validateNestedFields(
        _ root: [String: YAMLValue],
        fields: [String],
        path: String
    ) throws {
        let allowed = Set(fields)
        for key in root.keys.sorted() where !allowed.contains(key) && !key.hasPrefix("x_") {
            throw issue("schema.additionalProperties", "\(path)/\(key)", "O campo não é permitido.")
        }
        for field in fields where root[field] == nil {
            throw issue("schema.required", "\(path)/\(field)", "O campo obrigatório está ausente.")
        }
    }

    private static func string(_ root: [String: YAMLValue], _ key: String) throws -> String {
        guard case let .string(value)? = root[key] else {
            throw issue("schema.type", "/\(key)", "O campo deve ser texto.")
        }
        return value
    }

    private static func require(_ condition: Bool, rule: String, path: String) throws {
        guard condition else { throw issue(rule, path, "O valor não atende ao perfil MAC-003A.2.") }
    }

    private static func isUTCDate(_ value: String) -> Bool {
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?Z$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: value,
                  range: NSRange(value.startIndex..., in: value)
              ), match.range.length == value.utf16.count else {
            return false
        }
        func integer(_ index: Int) -> Int? {
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return Int(value[range])
        }
        guard let year = integer(1), let month = integer(2), let day = integer(3),
              let hour = integer(4), let minute = integer(5), let second = integer(6),
              year >= 1, (1...12).contains(month), hour <= 23, minute <= 59,
              second <= 59 else {
            return false
        }
        let leap = year.isMultiple(of: 400) || (year.isMultiple(of: 4) && !year.isMultiple(of: 100))
        let maximumDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return day >= 1 && day <= maximumDays[month - 1]
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func issue(_ rule: String, _ path: String, _ message: String) -> VaultValidationIssue {
        VaultValidationIssue(rule: rule, path: path, message: message)
    }
}
