// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation

struct DemoAppointment: Codable, Equatable, Sendable {
    let startsAt: String
    let timeZone: String
    let modality: String
    let synthetic: Bool

    enum CodingKeys: String, CodingKey {
        case startsAt = "starts_at"
        case timeZone = "time_zone"
        case modality
        case synthetic
    }
}

struct DemoConsultation: Codable, Equatable, Sendable {
    let date: String
    let encounterID: String
    let noteID: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case date
        case encounterID = "encounter_id"
        case noteID = "note_id"
        case status
    }
}

struct DemoRawAsset: Codable, Equatable, Sendable {
    let assetID: String
    let kind: String
    let originalName: String
    let importedAt: String

    enum CodingKeys: String, CodingKey {
        case assetID = "asset_id"
        case kind
        case originalName = "original_name"
        case importedAt = "imported_at"
    }
}

struct DemoPatientProfile: Codable, Equatable, Identifiable, Sendable {
    let patientID: String
    let displayName: String
    let birthDate: String
    let age: Int
    let administrativeSex: String
    let primaryProblem: String
    let summary: String
    let activeProblems: [String]
    let nextAppointment: DemoAppointment?
    let consultations: [DemoConsultation]
    let rawAssets: [DemoRawAsset]

    var id: String { patientID }

    enum CodingKeys: String, CodingKey {
        case patientID = "patient_id"
        case displayName = "display_name"
        case birthDate = "birth_date"
        case age
        case administrativeSex = "administrative_sex"
        case primaryProblem = "primary_problem"
        case summary
        case activeProblems = "active_problems"
        case nextAppointment = "next_appointment"
        case consultations
        case rawAssets = "raw_assets"
    }
}

struct DemoCatalog: Codable, Equatable, Sendable {
    let schema: String
    let synthetic: Bool
    let disclaimer: String
    let generatedAt: String
    let vaultID: String
    let patients: [DemoPatientProfile]

    enum CodingKeys: String, CodingKey {
        case schema
        case synthetic
        case disclaimer
        case generatedAt = "generated_at"
        case vaultID = "vault_id"
        case patients
    }

    func profile(for patientID: String) -> DemoPatientProfile? {
        patients.first { $0.patientID == patientID }
    }
}

enum DemoCatalogReader {
    static let relativePath = "indexes/openpep-demo-cardiology.json"
    static let directoryMarkerName = ".openpep-demo-directory"
    static let directoryMarkerData = Data("OPENPEP_SYNTHETIC_DEMO_DIRECTORY_V1\n".utf8)
    static let expectedFixtureDigest =
        "191654e8613b2a8e3fa306b2c82af717d501646bb0cda837b5fcf843738fcb4c"
    static let disclaimer =
        "DADOS FICTICIOS DE DEMONSTRACAO. NAO USAR PARA CUIDADO, DECISAO OU ORIENTACAO MEDICA."

    static func readIfPresent(
        vaultURL: URL,
        expectedVaultID: String,
        fileManager: FileManager = .default
    ) throws -> DemoCatalog? {
        let url = vaultURL.appending(path: relativePath, directoryHint: .notDirectory)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size <= 1024 * 1024 else {
            throw demoIssue("demo_catalog.file", url.path, "O catálogo demonstrativo não é um arquivo regular permitido.")
        }

        let catalog: DemoCatalog
        do {
            catalog = try JSONDecoder().decode(DemoCatalog.self, from: Data(contentsOf: url))
        } catch {
            throw demoIssue("demo_catalog.json", url.path, "O catálogo demonstrativo não contém JSON reconhecido.")
        }
        guard catalog.schema == "openpep/demo-cardiology-index@1",
              catalog.synthetic,
              catalog.disclaimer == disclaimer,
              catalog.vaultID == expectedVaultID,
              catalog.patients.count == 20 else {
            throw demoIssue("demo_catalog.contract", url.path, "O catálogo não corresponde ao perfil cardiológico sintético.")
        }
        try validateKnownFixtureBytes(vaultURL: vaultURL, fileManager: fileManager)

        var patientIDs = Set<String>()
        for profile in catalog.patients {
            guard OpenPEPIdentifier.isPatient(profile.patientID),
                  patientIDs.insert(profile.patientID).inserted,
                  !profile.displayName.isEmpty,
                  !profile.primaryProblem.isEmpty,
                  (2...5).contains(profile.consultations.count),
                  profile.rawAssets.count == 3,
                  fileManager.fileExists(atPath: vaultURL.appending(path: "patients/\(profile.patientID)").path),
                  profile.consultations.allSatisfy({
                      OpenPEPIdentifier.isEncounter($0.encounterID)
                          && OpenPEPIdentifier.isNote($0.noteID)
                          && $0.status == "draft"
                  }),
                  profile.rawAssets.allSatisfy({ OpenPEPIdentifier.isAsset($0.assetID) }) else {
                throw demoIssue("demo_catalog.patient", profile.patientID, "Um paciente demonstrativo está incompleto ou divergente.")
            }
            if let appointment = profile.nextAppointment {
                guard appointment.synthetic,
                      appointment.timeZone == "America/Sao_Paulo",
                      ISO8601DateFormatter().date(from: appointment.startsAt) != nil else {
                    throw demoIssue("demo_catalog.appointment", profile.patientID, "A agenda demonstrativa é inválida.")
                }
            }
        }
        guard catalog.patients.filter({ $0.nextAppointment != nil }).count >= 10 else {
            throw demoIssue("demo_catalog.appointments", url.path, "A demonstração exige ao menos dez pacientes agendados.")
        }
        return catalog
    }

    private static func validateKnownFixtureBytes(
        vaultURL: URL,
        fileManager: FileManager
    ) throws {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw demoIssue("demo_catalog.fixture_tree", vaultURL.path, "A árvore da fixture não pôde ser enumerada.")
        }

        let rootPath = vaultURL.standardizedFileURL.path + "/"
        var rows: [String] = []
        for case let itemURL as URL in enumerator {
            let values = try itemURL.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else {
                throw demoIssue("demo_catalog.fixture_tree", itemURL.path, "A fixture não aceita links simbólicos.")
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true, let size = values.fileSize else {
                throw demoIssue("demo_catalog.fixture_tree", itemURL.path, "A fixture contém um item não regular.")
            }
            if itemURL.lastPathComponent == ".DS_Store" { continue }
            let itemPath = itemURL.standardizedFileURL.path
            guard itemPath.hasPrefix(rootPath) else {
                throw demoIssue("demo_catalog.fixture_tree", itemPath, "Um item saiu da raiz da fixture.")
            }
            let relative = String(itemPath.dropFirst(rootPath.count))
            let digest = SHA256.hash(data: try Data(contentsOf: itemURL, options: [.mappedIfSafe]))
                .map { String(format: "%02x", $0) }
                .joined()
            rows.append("\(relative)\t\(size)\t\(digest)\n")
        }

        let manifest = rows.sorted().joined()
        let actual = SHA256.hash(data: Data(manifest.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        guard actual == expectedFixtureDigest else {
            throw demoIssue(
                "demo_catalog.fixture_digest",
                vaultURL.path,
                "Os bytes não correspondem à fixture cardiológica distribuída com este app."
            )
        }
    }

    static func validateBindings(_ catalog: DemoCatalog, patients: [PatientSummary]) throws {
        guard Set(catalog.patients.map(\.patientID)) == Set(patients.map(\.patientID)) else {
            throw demoIssue(
                "demo_catalog.patient_binding",
                relativePath,
                "Os pacientes do catálogo não correspondem aos diretórios validados."
            )
        }

        for patient in patients {
            guard let profile = catalog.profile(for: patient.patientID) else {
                throw demoIssue("demo_catalog.patient_binding", patient.patientID, "O paciente não está no catálogo.")
            }
            let catalogConsultations = profile.consultations.map {
                "\($0.encounterID)|\($0.noteID)|\($0.date)|\($0.status)"
            }.sorted()
            let clinicalConsultations = patient.encounters.map {
                "\($0.metadata.encounterID)|\($0.draft.metadata.noteID)|\($0.metadata.startedAt.prefix(10))|\($0.draft.metadata.status)"
            }.sorted()
            guard catalogConsultations == clinicalConsultations else {
                throw demoIssue(
                    "demo_catalog.consultation_binding",
                    patient.patientID,
                    "As consultas do catálogo divergem dos documentos clínicos validados."
                )
            }

            let catalogAssets = profile.rawAssets.map {
                "\($0.assetID)|\($0.originalName)|\($0.importedAt)"
            }.sorted()
            let rawAssets = patient.rawAssets.map {
                "\($0.assetID)|\($0.originalName)|\($0.importedAt)"
            }.sorted()
            guard catalogAssets == rawAssets else {
                throw demoIssue(
                    "demo_catalog.raw_binding",
                    patient.patientID,
                    "Os arquivos do catálogo divergem dos originais e sidecars validados."
                )
            }

            let catalogKinds = profile.rawAssets.map { "\($0.assetID)|\($0.kind)" }.sorted()
            let validatedKinds = patient.rawAssets.map { "\($0.assetID)|\(demoKind(for: $0))" }.sorted()
            guard catalogKinds == validatedKinds,
                  Set(profile.rawAssets.map(\.kind)) == ["laboratory", "imaging", "transcript"] else {
                throw demoIssue(
                    "demo_catalog.raw_kind",
                    patient.patientID,
                    "Os tipos do catálogo divergem dos originais e sidecars validados."
                )
            }
        }
    }

    private static func demoKind(for asset: RawAssetSummary) -> String {
        let name = asset.originalName.lowercased()
        switch (asset.mediaType, asset.originalURL.pathExtension.lowercased()) {
        case ("application/pdf", "pdf") where name.hasPrefix("laboratorio-") && name.hasSuffix(".pdf"):
            return "laboratory"
        case ("application/pdf", "pdf") where name.hasPrefix("laudo-") && name.hasSuffix(".pdf"):
            return "imaging"
        case ("text/plain", "txt") where name == "transcricao-consulta-sintetica.txt":
            return "transcript"
        default:
            return "unsupported"
        }
    }
}

private func demoIssue(_ rule: String, _ path: String, _ message: String) -> VaultValidationIssue {
    VaultValidationIssue(rule: rule, path: path, message: message)
}
