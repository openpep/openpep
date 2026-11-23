// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import PDFKit
import SwiftUI
import Testing
@testable import OpenPEP

@MainActor
struct DoctorProfileTests {
    private func sample() -> DoctorProfile {
        var profile = DoctorProfile()
        profile.fullName = "Marina Oliveira"
        profile.preferredName = "Dra. Marina"
        profile.specialty = "Clínica médica"
        profile.registration = "CRM XX 000000"
        profile.rqe = "00000"
        profile.cpf = "000.000.000-00"
        profile.phone = "+1 202-555-0121"
        profile.email = "consultorio@example.invalid"
        var office = DoctorOffice()
        office.name = "Consultório Centro"
        office.street = "Rua das Acácias"
        office.number = "120"
        office.city = "Cidade Exemplo"
        office.state = "XX"
        office.postalCode = "00000-000"
        profile.offices = [office]
        profile.defaultOfficeID = office.id
        return profile
    }

    @Test("preserves legacy identification and excludes CPF and preferred name from printed identity")
    func persistenceAndPrinting() throws {
        let key = "openpep-doctor-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        defaults.set("Nome anterior", forKey: DocumentProfessionalSettings.nameKey)
        defaults.set("CRM XX 000001", forKey: DocumentProfessionalSettings.registrationKey)
        #expect(DoctorProfileStore.load(defaults: defaults).fullName == "Nome anterior")
        var profile = sample()
        try DoctorProfileStore.save(profile, defaults: defaults)
        #expect(DoctorProfileStore.load(defaults: defaults) == profile)
        #expect(!profile.documentIdentity.contactText.contains(profile.cpf))
        #expect(!profile.documentIdentity.signatureText.contains(profile.preferredName))
        var second = DoctorOffice()
        second.name = "Consultório Parque"
        profile.offices.append(second)
        profile.defaultOfficeID = second.id
        #expect(profile.documentIdentity.contactText.contains("Consultório Parque"))
        #expect(!profile.documentIdentity.contactText.contains("Rua das Acácias"))
        profile.printsCPF = true
        #expect(profile.documentIdentity.contactText.contains(profile.cpf))
    }

    @Test("signature image is normalized and requires explicit application")
    func signatureAndPDF() throws {
        var profile = sample()
        let image = NSImage(size: NSSize(width: 280, height: 70))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 280, height: 70).fill()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 20, y: 20)); path.curve(to: NSPoint(x: 250, y: 35), controlPoint1: NSPoint(x: 80, y: 90), controlPoint2: NSPoint(x: 130, y: -10))
        NSColor.black.setStroke(); path.lineWidth = 2; path.stroke()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        profile.signaturePNG = try DoctorProfileStore.normalizedSignature(tiff)
        #expect(profile.documentIdentity.signaturePNG == nil)
        profile.appliesSignatureImage = true
        let identity = profile.documentIdentity
        let bytes = try ClinicalDocumentPDF.make(title: "Orientações", patientName: "Helena Ramos",
            professional: identity.signatureText, body: "Retornar com o diário de sintomas na próxima consulta.", doctorIdentity: identity)
        let pdf = try #require(PDFDocument(data: bytes))
        #expect(pdf.pageCount == 1)
        #expect(pdf.string?.contains(profile.fullName) == true)
        #expect(pdf.string?.contains("Rua das Acácias") == true)
        #expect(pdf.string?.contains(profile.cpf) == false)
        #expect(pdf.string?.contains("RQE 00000") == true)
        #expect(throws: DoctorProfileIssue.self) { try DoctorProfileStore.normalizedSignature(Data("not an image".utf8)) }
        if let directory = ProcessInfo.processInfo.environment["OPENPEP_UI_SNAPSHOT_DIR"] {
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try bytes.write(to: url.appending(path: "perfil-medico.pdf"))
            let page = try #require(pdf.page(at: 0))
            let thumbnail = page.thumbnail(of: NSSize(width: 595, height: 842), for: .mediaBox)
            let data = try #require(thumbnail.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            try bitmap.representation(using: .png, properties: [:])?.write(to: url.appending(path: "perfil-medico.png"))
        }
    }

    @Test("welcome cards and doctor settings fit narrow and wide windows")
    func layouts() async throws {
        let key = "openpep-doctor-layout-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        try DoctorProfileStore.save(sample(), defaults: defaults)
        for width in [560.0, 1100.0] {
            try await render(WelcomeView(onCreate: {}, onOpen: {}, onDemo: {}, onRestore: {}), width: width, name: "welcome-\(Int(width))")
        }
        try await render(DoctorProfileSettingsView(defaults: defaults), width: 760, name: "doctor-settings")
    }

    private func render(_ content: some View, width: Double, name: String) async throws {
        let root = content.frame(width: width, height: 1000).background(Color(nsColor: .windowBackgroundColor))
        let view = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        #expect(view.fittingSize.width <= width)
        if let directory = ProcessInfo.processInfo.environment["OPENPEP_UI_SNAPSHOT_DIR"] {
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: url.appending(path: name + ".png"))
        }
        window.orderOut(nil)
    }
}
