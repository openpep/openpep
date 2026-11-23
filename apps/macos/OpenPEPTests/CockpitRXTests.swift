// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import PDFKit
import Security
import SwiftUI
import Testing
@testable import OpenPEP

struct CockpitRXTests {
    func vault() throws -> (URL, VaultSummary, SNCRRegistryStore) {
        let root = FileManager.default.temporaryDirectory.appending(path: "openpep-cockpit-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let summary = try VaultCreator().create(in: root, identity: .init(vaultID: "vlt_0198f5c0-7f36-7b65-9f31-11a0d536a21f", deviceID: "dev_0198f5c1-0d8f-7f8f-82a2-0e4390d41a22"), createdAt: Date())
        return (root, summary, SNCRRegistryStore(vaultURL: summary.url, vaultID: summary.manifest.vaultID, environment: .homologation))
    }
    let prescriber = String(repeating: "a", count: 64)
    let digest = String(repeating: "b", count: 64)
    let number = "2610.1-00.0000001"
    @Test func registryReserveReopenBackupAndTamper() throws {
        let (root, vault, store) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        let requestID = UUID(), documentID = UUID()
        try store.update { registry in
            registry.requests.append(.init(id: requestID, prescriber: prescriber, type: "NRB", quantity: 1, state: "received"))
            registry.numbers.append(.init(id: number, requestID: requestID, prescriber: prescriber, type: "NRB"))
        }
        #expect(try store.update { try $0.reserve(prescriber: prescriber, type: "NRB", documentID: documentID, contentHash: digest) } == number)
        #expect(try store.update { try $0.reserve(prescriber: prescriber, type: "NRB", documentID: documentID, contentHash: digest) } == number)
        #expect(throws: (any Error).self) { try store.update { try $0.reserve(prescriber: prescriber, type: "NRB", documentID: UUID(), contentHash: digest) } }
        #expect(throws: (any Error).self) { try store.update { try $0.reserve(prescriber: prescriber, type: "NRB", documentID: documentID, contentHash: prescriber) } }
        #expect(try VaultReader().open(vault.url).writingAllowed)
        #expect(throws: (any Error).self) { try store.update { $0.numbers[0].contentHash = String(repeating: "z", count: 64) } }
        #expect(throws: (any Error).self) { try store.update {
            var duplicate = $0.numbers[0]; duplicate.id = "2610.1-00.0000002"; $0.numbers.append(duplicate)
        } }
        let backup = root.appending(path: "backup"), restored = root.appending(path: "restored")
        _ = try VaultBackupService().create(from: vault.url, to: backup)
        _ = try VaultBackupService().restore(from: backup, to: restored)
        #expect(try SNCRRegistryStore(vaultURL: restored, vaultID: vault.manifest.vaultID, environment: .homologation).read().numbers.first?.state == "reserved")
        try store.update { try $0.confirm(documentID: documentID, contentHash: digest, pdfHash: prescriber) }
        #expect(throws: (any Error).self) { try store.update { try $0.reserve(prescriber: prescriber, type: "NRB", documentID: documentID, contentHash: digest) } }
        // A damaged registry blocks numbered prescribing only; the vault itself stays open.
        try Data("{}".utf8).write(to: vault.url.appending(path: SNCREnvironment.homologation.registryFilename))
        #expect(throws: (any Error).self) { try store.read() }
        #expect(try VaultReader().open(vault.url).writingAllowed)
    }
    @Test func environmentsNeverShareNumbers() throws {
        let (root, vault, store) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        let production = SNCRRegistryStore(vaultURL: vault.url, vaultID: vault.manifest.vaultID, environment: .production)
        let requestID = UUID()
        try store.update { registry in
            registry.requests.append(.init(id: requestID, prescriber: prescriber, type: "NRB", quantity: 1, state: "received"))
            registry.numbers.append(.init(id: number, requestID: requestID, prescriber: prescriber, type: "NRB"))
        }
        #expect(try production.read().numbers.isEmpty)
        try production.update { _ in }
        let homologationURL = vault.url.appending(path: SNCREnvironment.homologation.registryFilename)
        let productionURL = vault.url.appending(path: SNCREnvironment.production.registryFilename)
        #expect(try JSONDecoder().decode(SNCRRegistry.self, from: Data(contentsOf: productionURL)).environment == .production)
        #expect(try JSONDecoder().decode(SNCRRegistry.self, from: Data(contentsOf: homologationURL)).environment == nil)
        // Homologation numbers copied under the production name are refused, and so is the reverse.
        let productionBytes = try Data(contentsOf: productionURL)
        try Data(contentsOf: homologationURL).write(to: productionURL)
        #expect(throws: (any Error).self) { try production.read() }
        try productionBytes.write(to: homologationURL)
        #expect(throws: (any Error).self) { try store.read() }
        #expect(SNCREnvironment.homologation.gateway.host == "api-gateway.hmg.apps.anvisa.gov.br")
        #expect(SNCREnvironment.production.gateway.host == "api-gateway.prd.apps.anvisa.gov.br")
        let intent = SNCRClient.Intent(environment: .production, id: UUID(), state: "synthetic-state", createdAt: Date(),
            callback: URL(string: "https://synthetic.invalid.br/")!, type: "NRB", quantity: 1, registration: "000000", uf: "SP", cnpj: "")
        #expect(intent.loginURL.host == "api-gateway.prd.apps.anvisa.gov.br")
    }
    @Test func callbackAndResponsesFailClosed() throws {
        for environment in SNCREnvironment.allCases { #expect(SNCRClient.allowsAuthorization(environment.gateway)) }
        #expect(SNCRClient.allowsAuthorization(URL(string: "https://sso.staging.acesso.gov.br/")!))
        #expect(!SNCRClient.allowsAuthorization(URL(string: "https://acesso.gov.br.synthetic.invalid/")!))
        #expect(!SNCRClient.allowsAuthorization(URL(string: "http://acesso.gov.br/")!))
        let now = Date(), callback = URL(string: "https://synthetic.invalid.br/")!
        let intent = SNCRClient.Intent(id: UUID(), state: "synthetic-state", createdAt: now, callback: callback,
            type: "NRB", quantity: 2, registration: "000001", uf: "SP", cnpj: "")
        #expect(try intent.session(from: URL(string: "https://synthetic.invalid.br/?state=synthetic-state&session_id=SYNTHETIC")!, now: now) == "SYNTHETIC")
        for suffix in ["state=wrong&session_id=SYNTHETIC", "state=synthetic-state&session_id=X&session_id=Y", "state=synthetic-state&state=synthetic-state&session_id=X"] {
            #expect(throws: (any Error).self) { try intent.session(from: URL(string: "https://synthetic.invalid.br/?" + suffix)!, now: now) }
        }
        #expect(throws: (any Error).self) { try intent.session(from: callback, now: now.addingTimeInterval(301)) }
        #expect(try SNCRClient.numbers(["numeroReceita": [number]], type: "NRB", quantity: 2) == [number])
        #expect(throws: (any Error).self) { try SNCRClient.numbers(["numeroReceita": [number, number]], type: "NRB", quantity: 2) }
        #expect(throws: (any Error).self) { try SNCRClient.numbers(["inicio":number, "fim":"2610.1-01.0001000", "quantidade":1000], type:"RCE", quantity:1000) }
        #expect(try SNCRClient.numbers(["inicio":number, "fim":"2610.1-00.0001000", "quantidade":1000], type:"RCE", quantity:1000).count == 1000)
    }
    @Test func requestsAreSingleUseAndSecretsNeverReachDisk() async throws {
        for status in [200, 204, 500, 302] {
            let (root, _, store) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
            let intent = SNCRClient.Intent(id: UUID(), state: "synthetic-state", createdAt: Date(), callback: URL(string:"https://synthetic.invalid.br/")!,
                type:"NRB", quantity:1, registration:"000001", uf:"SP", cnpj:"")
            try store.update { $0.requests.append(.init(id:intent.id, prescriber:prescriber, type:"NRB", quantity:1)) }
            let calls = Counter()
            let client = SNCRClient(send: { request in
                calls.add()
                let token = request.url!.path.hasSuffix("token")
                let body: [String:Any] = token ? ["token_type":"Bearer","access_token":"SYNTHETIC_SECRET"] : ["numeroReceita":[number]]
                if !token { #expect(request.httpMethod == "POST"); #expect(request.value(forHTTPHeaderField:"Authorization") == "Bearer SYNTHETIC_SECRET") }
                return (try JSONSerialization.data(withJSONObject:body), HTTPURLResponse(url:request.url!, statusCode:token ? 200 : status,
                    httpVersion:nil, headerFields:["Content-Type":"application/json"])!)
            })
            let callback = URL(string:"https://synthetic.invalid.br/?state=synthetic-state&session_id=SYNTHETIC_SESSION")!
            try await client.execute(intent, returnedURL:callback, store:store)
            do { try await client.execute(intent, returnedURL:callback, store:store); Issue.record("Duplicate callback accepted") } catch {}
            #expect(calls.value == 2)
            let row = try store.read()
            #expect(row.requests[0].state == [200:"received",204:"refused",500:"uncertain",302:"uncertain"][status])
            let saved = try String(contentsOf:store.vaultURL.appending(path:SNCREnvironment.homologation.registryFilename), encoding:.utf8)
            #expect(!saved.contains("SYNTHETIC_SECRET") && !saved.contains("SYNTHETIC_SESSION"))
        }
    }
    @Test func simultaneousReservationsCannotShareANumber() async throws {
        let (root, _, store) = try vault(); defer { try? FileManager.default.removeItem(at:root) }
        let request = UUID()
        try store.update {
            $0.requests.append(.init(id:request, prescriber:prescriber, type:"NRB", quantity:1,state:"received"))
            $0.numbers.append(.init(id:number,requestID:request,prescriber:prescriber,type:"NRB"))
        }
        let successes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<12 { group.addTask { (try? store.update { try $0.reserve(prescriber:prescriber,type:"NRB",documentID:UUID(),contentHash:digest) }) != nil } }
            var count=0; for await value in group { if value { count += 1 } }; return count
        }
        #expect(successes == 1)
        #expect(try store.read().numbers[0].state == "reserved")
    }
    @MainActor @Test func nativeRendererLoadsOfflineAndSignatureSurvivesReopen() async throws {
        let patient = PatientSummary(patientID:"pt_0198f5c2-0000-7000-8000-000000000001",url:URL(fileURLWithPath:"/synthetic"),record:nil,rawAssets:[],encounters:[])
        var draft = CockpitPrescription(patient:patient)
        draft.tipo = "NRB"
        draft.prescriber = .init(nome:"Médico Sintético",crm:"000001",uf:"SP",cpf:"52998224725")
        draft.paciente = .init(nome:"Paciente Sintético",documento:"52998224725",endereco:"Rua Sintética, 100",cidade:"São Paulo",uf:"SP")
        draft.emitente = .init(endereco:"Rua Sintética, 200",cidade:"São Paulo",uf:"SP")
        draft.medications = [.init(nome:"Medicamento de ensaio",concentracao:"10 mg",forma:"comprimido",quantidade:"30",unidade:"comprimidos",posologia:"Texto de ensaio sem orientação clínica.")]
        let renderer = CockpitPDFRenderer()
        let result: (pdf: Data, term: Data?, source: String)
        do { result = try await renderer.render(draft.input()) } catch { throw CockpitError.message("render: " + String(describing: error)) }
        let pdf = try #require(PDFDocument(data:result.pdf))
        #expect(pdf.pageCount == 1)
        #expect(pdf.string?.contains("Paciente Sintético") == true)
        #expect(pdf.string?.contains("ENSAIO SINTÉTICO") == true)
        #expect(result.source.contains("\"ambiente\":\"homologation\""))
        // Only the explicit production environment renders without the trial marks.
        var productionInput = try draft.input(); productionInput["environment"] = SNCREnvironment.production.rawValue
        let production = try await renderer.render(productionInput)
        #expect(PDFDocument(data: production.pdf)?.string?.contains("ENSAIO SINTÉTICO") == false)
        #expect(production.source.contains("\"ambiente\":\"production\""))
        let prepared: LocalPDFSignaturePreparation
        do { prepared = try await renderer.prepareSignature(result.pdf) } catch { throw CockpitError.message("prepare: " + String(describing: error)) }
        let root = FileManager.default.temporaryDirectory.appending(path:"openpep-synthetic-key-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:root) }
        func openssl(_ arguments:[String]) throws {
            let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/openssl");process.arguments=arguments;process.currentDirectoryURL=root
            process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
            try process.run();process.waitUntilExit();#expect(process.terminationStatus == 0)
        }
        try openssl(["req","-x509","-newkey","rsa:2048","-nodes","-keyout","key.pem","-out","cert.pem","-days","1","-subj","/CN=OpenPEP Synthetic Certificate"])
        try openssl(["pkcs12","-export","-inkey","key.pem","-in","cert.pem","-out","synthetic.p12","-passout","pass:synthetic-test-only"])
        var items:CFArray?
        #expect(SecPKCS12Import(try Data(contentsOf:root.appending(path:"synthetic.p12")) as CFData,
            [kSecImportExportPassphrase:"synthetic-test-only",kSecImportToMemoryOnly:true] as CFDictionary,&items) == errSecSuccess)
        let imported = try #require((items as? [[String:Any]])?.first)
        let identity = try #require(imported[kSecImportItemIdentity as String]) as! SecIdentity
        var certificate:SecCertificate?;#expect(SecIdentityCopyCertificate(identity,&certificate) == errSecSuccess)
        let der=SecCertificateCopyData(try #require(certificate)) as Data
        let signed: Data
        do { signed=try LocalPDFSigner.sign(prepared,with:.init(reference:identity,certificate:der,name:"Synthetic")) } catch { throw CockpitError.message("sign: " + String(describing: error)) }
        do { try LocalPDFSigner.verifyPDF(signed,certificate:der) } catch { throw CockpitError.message("verify: " + String(describing: error)) }
        try signed.write(to:root.appending(path:"signed.pdf"))
        #expect(try Data(contentsOf:root.appending(path:"signed.pdf")) == signed)
        #expect(PDFDocument(data:signed)?.pageCount == 1)
        var changed=signed;changed[20] ^= 1
        #expect(throws:(any Error).self) { try LocalPDFSigner.verifyPDF(changed,certificate:der) }
        #expect(throws:(any Error).self) { try LocalPDFSigner.verifyPDF(signed + Data("extra revision".utf8),certificate:der) }
        #expect(throws:(any Error).self) {
            try LocalPDFSigner.verifyPDF(Data("%PDF-1.7 /ByteRange [0 9223372036854775807 1 2]".utf8), certificate: der)
        }
        // Independently verify the detached CMS with OpenSSL, without asserting certificate trust.
        let range=prepared.byteRange
        let hex=String(data:signed[(range[1]+1)..<(range[2]-1)],encoding:.ascii)!
        var cms=Data();var index=hex.startIndex
        while index < hex.endIndex { let end=hex.index(index,offsetBy:2);cms.append(UInt8(hex[index..<end],radix:16)!);index=end }
        try cms.write(to:root.appending(path:"signature.der"));try prepared.content.write(to:root.appending(path:"content.bin"))
        try openssl(["cms","-verify","-binary","-inform","DER","-in","signature.der","-content","content.bin","-noverify","-out","verified.bin"])
        #expect(try Data(contentsOf:root.appending(path:"verified.bin")) == prepared.content)
        // A crash between signature and archival can be resumed without another key operation.
        let (registryRoot, clinicalVault, store) = try vault()
        defer { try? FileManager.default.removeItem(at: registryRoot) }
        let registered = try PatientCreator().createRegistered(in: clinicalVault.url,
            identity: .init(patientID: "pt_0198f5c2-0000-7000-8000-000000000001"),
            input: .init(fullName: "Paciente Sintético", preferredName: nil, birthDate: nil, contacts: [], identifiers: [], alerts: []), createdAt: Date())
        let document = try PreparedClinicalDocument(title: "Receita sintética", data: signed, sourceText: result.source)
        let requestID = UUID()
        try store.update { registry in
            registry.requests.append(.init(id: requestID, prescriber: draft.prescriber.key, type: draft.tipo, quantity: 1, state: "received"))
            registry.numbers.append(.init(id: number, requestID: requestID, prescriber: draft.prescriber.key, type: draft.tipo))
            _ = try registry.reserve(prescriber: draft.prescriber.key, type: draft.tipo, documentID: draft.id, contentHash: draft.hash)
            registry.numbers[0].draft = draft; registry.numbers[0].patientID = registered.patientID
            registry.numbers[0].pendingCertificate = der; registry.numbers[0].pendingDocuments = [document]
        }
        let pending = try #require(store.read().numbers[0].pendingDocuments?.first)
        #expect(pending.id == document.id && pending.pdfIdentity == document.pdfIdentity && pending.sourceIdentity == document.sourceIdentity)
        try LocalPDFSigner.verifyPDF(pending.data, certificate: der)
        let archived = try ClinicalDocumentArchiver().archive(pending, patient: registered, encounterID: nil,
            deviceID: clinicalVault.manifest.deviceID, expectedVaultID: clinicalVault.manifest.vaultID)
        #expect(try Data(contentsOf: archived.pdf.originalURL) == signed)
        let attachments = try DocumentDeliveryView.attachmentItems(files: [archived.pdf.originalURL], message: "Ensaio sintético")
        #expect(attachments.count == 2 && attachments[1] as? URL == archived.pdf.originalURL)
        #expect(try Data(contentsOf: #require(attachments[1] as? URL)) == signed)
        #expect(throws: (any Error).self) { try DocumentDeliveryView.attachmentItems(files: [URL(string: "https://synthetic.invalid/document.pdf")!], message: "") }
        let retry = try ClinicalDocumentArchiver().archive(pending, patient: registered, encounterID: nil,
            deviceID: clinicalVault.manifest.deviceID, expectedVaultID: clinicalVault.manifest.vaultID)
        #expect(retry.pdf.assetID == archived.pdf.assetID)
        try store.update { try $0.confirm(documentID: draft.id, contentHash: draft.hash, pdfHash: SNCRRegistry.hash(signed)) }
        #expect(try store.read().numbers[0].pendingDocuments?.count == nil)
    }
    @Test func registryFixturesAndLegacyAbsence() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = repository.appending(path: "fixtures/sncr-registry-v1")
        try JSONDecoder().decode(SNCRRegistry.self, from: Data(contentsOf: fixtures.appending(path: "valid/empty.json"))).validate()
        let unsupported = try JSONDecoder().decode(SNCRRegistry.self, from: Data(contentsOf: fixtures.appending(path: "invalid/unsupported-version.json")))
        #expect(throws: (any Error).self) { try unsupported.validate() }
        let (root, vault, store) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(try store.read().numbers.isEmpty)
        #expect(try VaultReader().open(vault.url).writingAllowed)
        #expect(!FileManager.default.fileExists(atPath: vault.url.appending(path: SNCREnvironment.homologation.registryFilename).path))
    }
    @MainActor @Test func cockpitLayoutsUseOnlySyntheticData() async throws {
        let (base, vault, _) = try vault(); defer { try? FileManager.default.removeItem(at: base) }
        let patient = try PatientCreator().createRegistered(in: vault.url,
            identity: .init(patientID: "pt_0198f5c2-0000-7000-8000-000000000001"),
            input: .init(fullName: "Paciente Sintético", preferredName: nil, birthDate: nil, contacts: [], identifiers: [], alerts: []), createdAt: Date())
        var draft = CockpitPrescription(patient: patient)
        draft.prescriber = .init(nome: "Médico Sintético", crm: "000001", uf: "SP", cpf: "52998224725")
        draft.emitente = .init(endereco: "Rua de Ensaio, 100", cidade: "São Paulo", uf: "SP")
        draft.paciente = .init(nome: "Paciente Sintético", documento: "52998224725", endereco: "Rua de Ensaio, 200", cidade: "São Paulo", uf: "SP")
        for (width, scheme) in [(680.0, ColorScheme.light), (1040.0, ColorScheme.dark)] {
            let root = CockpitPrescriptionView(patient: patient, initialDraft: draft, onArchive: { _ in URL(fileURLWithPath: "/synthetic.pdf") }, onClose: {})
                .frame(width: width, height: 850).environment(\.colorScheme, scheme)
            let view = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 850), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = view; window.makeKeyAndOrderFront(nil); view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(400)); window.displayIfNeeded()
            #expect(view.fittingSize.width <= width)
            if let path = ProcessInfo.processInfo.environment["OPENPEP_UI_SNAPSHOT_DIR"] {
                let directory = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appending(path: "cockpit-\(Int(width)).png"))
            }
            window.orderOut(nil)
        }
    }
    final class Counter: @unchecked Sendable {
        private let lock=NSLock();private var stored=0
        func add(){lock.lock();stored += 1;lock.unlock()}
        var value:Int{lock.lock();defer{lock.unlock()};return stored}
    }
}
