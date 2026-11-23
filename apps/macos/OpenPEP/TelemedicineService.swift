// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation

enum TelemedicineHandoffMethod: String, Equatable, Sendable {
    case faceTimeContact = "facetime_contact"
    case savedLink = "saved_link"
}

struct TelemedicineContactOption: Equatable, Sendable, Identifiable {
    let type: PatientContactType
    let displayValue: String
    let destination: String

    var id: String { "\(type.rawValue):\(destination)" }

    var typeLabel: String {
        switch type {
        case .phone: "Telefone"
        case .email: "E-mail"
        }
    }
}

enum TelemedicineContactResolver {
    static func options(for patient: PatientSummary) -> [TelemedicineContactOption] {
        guard let record = patient.record, record.status == .active else { return [] }
        return record.contacts.compactMap { contact in
            return option(for: contact)
        }
    }

    static func option(for contact: PatientContact) -> TelemedicineContactOption? {
        let displayValue = contact.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayValue.isEmpty,
              displayValue.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        switch contact.type {
        case .phone:
            let allowed = CharacterSet(charactersIn: "+0123456789().- ")
            guard displayValue.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
            let hasLeadingPlus = displayValue.hasPrefix("+")
            guard displayValue.dropFirst().contains("+") == false else { return nil }
            let digits = displayValue.filter(\.isNumber)
            guard (7...15).contains(digits.count) else { return nil }
            return TelemedicineContactOption(
                type: .phone,
                displayValue: displayValue,
                destination: hasLeadingPlus ? "+\(digits)" : digits
            )
        case .email:
            guard displayValue.count <= 254,
                  displayValue.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) }) else {
                return nil
            }
            let parts = displayValue.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  !parts[0].isEmpty,
                  parts[1].contains("."),
                  !parts[1].hasPrefix("."),
                  !parts[1].hasSuffix(".") else {
                return nil
            }
            return TelemedicineContactOption(
                type: .email,
                displayValue: displayValue,
                destination: displayValue
            )
        }
    }
}

enum TelemedicineURLBuilder {
    static func faceTimeURL(for contact: TelemedicineContactOption) throws -> URL {
        guard !contact.destination.isEmpty,
              contact.destination.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw issue("telemedicine.invalid_contact", "O contato não pode ser usado no FaceTime.")
        }
        var components = URLComponents()
        components.scheme = "facetime"
        components.path = contact.destination
        guard let url = components.url, url.scheme == "facetime" else {
            throw issue("telemedicine.invalid_contact", "O contato não pode ser usado no FaceTime.")
        }
        return url
    }

    static func savedLinkURL(_ value: String?) throws -> URL {
        guard let value else {
            throw issue("telemedicine.missing_link", "O agendamento não possui link remoto salvo.")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              let url = components.url else {
            throw issue("telemedicine.invalid_link", "Use um link HTTPS com endereço válido e sem credenciais.")
        }
        return url
    }

    private static func issue(_ rule: String, _ message: String) -> VaultValidationIssue {
        VaultValidationIssue(rule: rule, path: "/remote_access_url", message: message)
    }
}

struct TelemedicineExternalActions {
    let open: (URL) -> Bool
    let copy: (String) -> Bool

    @MainActor
    static var live: TelemedicineExternalActions {
        TelemedicineExternalActions(
            open: { NSWorkspace.shared.open($0) },
            copy: { value in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                return pasteboard.setString(value, forType: .string)
            }
        )
    }
}

struct TelemedicineHandoffOutcome: Equatable {
    let appointment: AppointmentSummary
    let systemAccepted: Bool
}

struct TelemedicineHandoffCoordinator {
    private let writer: AppointmentWriter
    private let actions: TelemedicineExternalActions

    init(
        writer: AppointmentWriter = AppointmentWriter(),
        actions: TelemedicineExternalActions
    ) {
        self.writer = writer
        self.actions = actions
    }

    @MainActor
    static func live(writer: AppointmentWriter = AppointmentWriter()) -> TelemedicineHandoffCoordinator {
        TelemedicineHandoffCoordinator(writer: writer, actions: .live)
    }

    func openFaceTime(
        for appointment: AppointmentSummary,
        contact: TelemedicineContactOption,
        in vaultURL: URL,
        requestedAt: Date = Date()
    ) throws -> TelemedicineHandoffOutcome {
        let url = try TelemedicineURLBuilder.faceTimeURL(for: contact)
        let recorded = try writer.recordRemoteHandoff(
            appointment,
            method: .faceTimeContact,
            in: vaultURL,
            requestedAt: requestedAt
        )
        return TelemedicineHandoffOutcome(
            appointment: recorded,
            systemAccepted: actions.open(url)
        )
    }

    func openSavedLink(
        for appointment: AppointmentSummary,
        in vaultURL: URL,
        requestedAt: Date = Date()
    ) throws -> TelemedicineHandoffOutcome {
        let url = try TelemedicineURLBuilder.savedLinkURL(appointment.record.remoteAccessURL)
        let recorded = try writer.recordRemoteHandoff(
            appointment,
            method: .savedLink,
            in: vaultURL,
            requestedAt: requestedAt
        )
        return TelemedicineHandoffOutcome(
            appointment: recorded,
            systemAccepted: actions.open(url)
        )
    }

    func copySavedLink(for appointment: AppointmentSummary) throws -> Bool {
        let url = try TelemedicineURLBuilder.savedLinkURL(appointment.record.remoteAccessURL)
        return actions.copy(url.absoluteString)
    }
}
