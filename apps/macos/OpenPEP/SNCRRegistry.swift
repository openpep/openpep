// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import CryptoKit

/// Homologation unless the professional explicitly activated production on this Mac.
/// Each environment has its own gateway and its own registry file: numbers are never shared.
enum SNCREnvironment: String, Codable, CaseIterable, Sendable {
    case homologation, production
    static let defaultsKey = "openpep.sncr.environment"
    static var current: SNCREnvironment {
        SNCREnvironment(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .homologation
    }
    var gateway: URL {
        URL(string: self == .production ? "https://api-gateway.prd.apps.anvisa.gov.br/api-sncr/api/v1/"
            : "https://api-gateway.hmg.apps.anvisa.gov.br/api-sncr/api/v1/")!
    }
    var registryFilename: String { self == .production ? "prescribing-production.json" : "prescribing-homologation.json" }
    var label: String { self == .production ? "produção" : "homologação" }
}

// Optional local registry; old vaults are unchanged until the first explicit request.
// A number never becomes available again after reservation, including interrupted signing.
struct SNCRRegistry: Codable {
    var format = "openpep-sncr-registry-v1"
    var vaultID: String
    /// Absent in homologation registries, which keeps files written before production existed valid.
    var environment: SNCREnvironment?
    var requests: [Request] = []
    var numbers: [Number] = []
    struct Request: Codable, Identifiable {
        var id: UUID
        var prescriber: String
        var type: String
        var quantity: Int
        var state: String = "prepared"
        var http: Int?
        var createdAt: Date = Date()
    }
    struct Number: Codable, Identifiable {
        var id: String
        var requestID: UUID
        var prescriber: String
        var type: String
        var state = "available"
        var documentID: UUID?
        var contentHash: String?
        var pdfHash: String?
        var patientID: String?
        var encounterID: String?
        var draft: CockpitPrescription?
        var pendingCertificate: Data?
        var pendingDocuments: [PreparedClinicalDocument]?
    }
    static let types = ["NRA", "NRB", "NRB2", "RCE", "RET", "NRR", "NRT"]
    static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    static func validNumber(_ value: String) -> Bool { value.range(of: #"^\d{4}\.\d-\d{2}\.\d{7}$"#, options: .regularExpression) != nil }
    private static func validHash(_ value: String?) -> Bool { value?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }
    func validate() throws {
        guard format == "openpep-sncr-registry-v1", vaultID.range(of: "^vlt_[a-f0-9-]{36}$", options: .regularExpression) != nil,
              requests.count <= 10_000, numbers.count <= 100_000,
              Set(requests.map(\.id)).count == requests.count,
              Set(numbers.map(\.id)).count == numbers.count,
              Set(numbers.compactMap(\.documentID)).count == numbers.compactMap(\.documentID).count else { throw CockpitError.invalidRegistry }
        let requestsByID = Dictionary(uniqueKeysWithValues: requests.map { ($0.id, $0) })
        let states = ["prepared", "sending", "received", "refused", "uncertain", "quarantine", "cancelled"]
        for request in requests {
            guard Self.types.contains(request.type), (1...1000).contains(request.quantity),
                  states.contains(request.state), Self.validHash(request.prescriber) else { throw CockpitError.invalidRegistry }
        }
        for number in numbers {
            guard Self.validNumber(number.id), let request = requestsByID[number.requestID],
                  request.state == "received", request.type == number.type, request.prescriber == number.prescriber,
                  ["available","reserved","used"].contains(number.state) else { throw CockpitError.invalidRegistry }
            if let draft = number.draft {
                guard draft.id == number.documentID, draft.hash == number.contentHash,
                      draft.prescriber.key == number.prescriber, draft.tipo == number.type,
                      number.patientID.map(OpenPEPIdentifier.isPatient) == true,
                      number.encounterID.map(OpenPEPIdentifier.isEncounter) ?? true else { throw CockpitError.invalidRegistry }
            }
            if let documents = number.pendingDocuments {
                guard number.state == "reserved", number.draft != nil, number.pendingCertificate != nil, (1...2).contains(documents.count),
                      documents.allSatisfy({ $0.data.starts(with: Data("%PDF-".utf8)) && $0.data.count <= 25 * 1024 * 1024
                        && OpenPEPIdentifier.isAsset($0.pdfIdentity.assetID) && OpenPEPIdentifier.isAsset($0.sourceIdentity.assetID) }) else { throw CockpitError.invalidRegistry }
            }
            if number.state == "available" {
                guard number.documentID == nil, number.contentHash == nil, number.pdfHash == nil,
                      number.draft == nil, number.patientID == nil, number.encounterID == nil,
                      number.pendingCertificate == nil, number.pendingDocuments == nil else { throw CockpitError.invalidRegistry }
            } else {
                guard number.documentID != nil, Self.validHash(number.contentHash) else { throw CockpitError.invalidRegistry }
                if number.state == "used" {
                    guard Self.validHash(number.pdfHash), number.draft == nil, number.pendingDocuments == nil,
                          number.pendingCertificate == nil else { throw CockpitError.invalidRegistry }
                } else if number.pdfHash != nil { throw CockpitError.invalidRegistry }
            }
        }
    }
    mutating func reserve(prescriber: String, type: String, documentID: UUID, contentHash: String) throws -> String {
        if let existing = numbers.first(where: { $0.documentID == documentID }) {
            guard existing.prescriber == prescriber, existing.type == type, existing.contentHash == contentHash,
                  existing.state == "reserved" else { throw CockpitError.invalidRegistry }
            return existing.id
        }
        guard let index = numbers.firstIndex(where: { $0.prescriber == prescriber && $0.type == type && $0.state == "available" }) else {
            throw CockpitError.message("Não há números disponíveis para este tipo de receita e prescritor.")
        }
        numbers[index].state = "reserved"; numbers[index].documentID = documentID; numbers[index].contentHash = contentHash
        return numbers[index].id
    }
    mutating func confirm(documentID: UUID, contentHash: String, pdfHash: String) throws {
        guard let index = numbers.firstIndex(where: { $0.documentID == documentID }),
              numbers[index].state == "reserved", numbers[index].contentHash == contentHash,
              pdfHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw CockpitError.invalidRegistry }
        numbers[index].state = "used"; numbers[index].pdfHash = pdfHash
        numbers[index].pendingDocuments = nil; numbers[index].pendingCertificate = nil; numbers[index].draft = nil
    }
}

struct SNCRRegistryStore {
    private static let lock = NSLock()
    let vaultURL: URL
    let vaultID: String
    var environment: SNCREnvironment = .current
    func read() throws -> SNCRRegistry {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try readUncoordinated()
    }
    private func readUncoordinated() throws -> SNCRRegistry {
        let url = vaultURL.appending(path: environment.registryFilename)
        var component = url
        while component.path != "/" {
            if (try? component.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw CockpitError.invalidRegistry }
            if component.standardizedFileURL == vaultURL.standardizedFileURL { break }
            component.deleteLastPathComponent()
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return SNCRRegistry(vaultID: vaultID, environment: environment == .production ? .production : nil)
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 32 * 1024 * 1024 else { throw CockpitError.invalidRegistry }
        let registry = try JSONDecoder().decode(SNCRRegistry.self, from: Data(contentsOf: url))
        guard registry.vaultID == vaultID, (registry.environment ?? .homologation) == environment else { throw CockpitError.invalidRegistry }
        try registry.validate()
        return registry
    }
    @discardableResult func update<T>(_ body: (inout SNCRRegistry) throws -> T) throws -> T {
        var result: Result<T, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: vaultURL, options: .forMerging, error: &coordinationError) { _ in
            result = Result {
                let current = try VaultReader().readWithinCoordinatedAccess(vaultURL)
                guard current.writingAllowed, current.manifest.vaultID == vaultID else { throw CockpitError.invalidRegistry }
                Self.lock.lock(); defer { Self.lock.unlock() }
                let manifest = try VaultManifestValidator.validate(data: Data(contentsOf: vaultURL.appending(path: "vault.yaml")))
                guard manifest.vaultID == vaultID else { throw CockpitError.invalidRegistry }
                var registry = try readUncoordinated()
                let value = try body(&registry)
                try registry.validate()
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
                let bytes = try encoder.encode(registry)
                guard bytes.count <= 32 * 1024 * 1024 else { throw CockpitError.invalidRegistry }
                let url = vaultURL.appending(path: environment.registryFilename)
                try bytes.write(to: url, options: .atomic)
                guard try Data(contentsOf: url) == bytes else { throw CockpitError.invalidRegistry }
                return value
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CockpitError.invalidRegistry }
        return try result.get()
    }
}
