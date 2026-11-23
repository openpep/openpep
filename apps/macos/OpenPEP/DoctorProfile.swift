// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import ImageIO
import UniformTypeIdentifiers

struct DoctorOffice: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    var postalCode = ""
    var street = ""
    var number = ""
    var complement = ""
    var neighborhood = ""
    var city = ""
    var state = ""
    var phone = ""

    var address: String {
        [name, [street, number, complement].filter { !$0.isEmpty }.joined(separator: ", "),
         [neighborhood, city, state, postalCode].filter { !$0.isEmpty }.joined(separator: " · ")]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

struct DoctorDocumentIdentity: Codable, Equatable {
    var signatureText: String
    var contactText: String
    var signaturePNG: Data?
}

struct DoctorProfile: Codable, Equatable {
    var fullName = ""
    var preferredName = ""
    var specialty = ""
    var registration = ""
    var rqe = ""
    var cpf = ""
    var phone = ""
    var email = ""
    var offices: [DoctorOffice] = []
    var defaultOfficeID: UUID?
    var signaturePNG: Data?
    var appliesSignatureImage = false
    var printsCPF = false

    var displayName: String { preferredName.isEmpty ? fullName : preferredName }
    var documentIdentity: DoctorDocumentIdentity {
        let office = offices.first { $0.id == defaultOfficeID } ?? offices.first
        let identification = [fullName, registration, specialty, rqe.isEmpty ? "" : "RQE \(rqe)"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        let contact = [office?.address ?? "", office?.phone.isEmpty == false ? office!.phone : phone,
                       email, printsCPF && !cpf.isEmpty ? "CPF \(cpf)" : ""]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        return DoctorDocumentIdentity(signatureText: identification, contactText: contact,
            signaturePNG: appliesSignatureImage ? signaturePNG : nil)
    }
}

enum DoctorProfileStore {
    static let key = "openpep.doctor-profile.v1"
    static func load(defaults: UserDefaults = .standard) -> DoctorProfile {
        if let data = defaults.data(forKey: key), let profile = try? JSONDecoder().decode(DoctorProfile.self, from: data) {
            return profile
        }
        var profile = DoctorProfile()
        profile.fullName = defaults.string(forKey: DocumentProfessionalSettings.nameKey) ?? ""
        profile.registration = defaults.string(forKey: DocumentProfessionalSettings.registrationKey) ?? ""
        return profile
    }

    static func save(_ profile: DoctorProfile, defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(profile), forKey: key)
    }

    static func normalizedSignature(_ data: Data) throws -> Data {
        guard data.count <= 5_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { throw DoctorProfileIssue.invalidImage }
        let result = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil) else {
            throw DoctorProfileIssue.invalidImage
        }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output), result.length <= 5_000_000 else { throw DoctorProfileIssue.invalidImage }
        return result as Data
    }
}

enum DoctorProfileIssue: LocalizedError {
    case invalidImage
    var errorDescription: String? { "Escolha uma imagem PNG ou JPEG de até 5 MB para a assinatura." }
}
