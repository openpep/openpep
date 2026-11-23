// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import PDFKit

struct CockpitPrescriptionView: View {
    let patient: PatientSummary
    let encounterID: String?
    let authorizationURL: URL?
    let onArchive: (PreparedClinicalDocument) throws -> URL
    let onClose: () -> Void
    var embedded = false
    var onFreeze: () -> Void = {}
    var onReviewError: (String) -> Void = { _ in }
    var onBusy: (Bool) -> Void = { _ in }
    @State private var scopedAccess = false
    @State private var draft: CockpitPrescription
    @State private var renderer = CockpitPDFRenderer()
    @State private var preview: PreparedClinicalDocument?
    @State private var term: PreparedClinicalDocument?
    @State private var signaturePreparation: LocalPDFSignaturePreparation?
    @State private var signingCertificate: Data?
    @State private var signed: PreparedClinicalDocument?
    @State private var reviewedHash: String?
    @State private var reservedNumber: String?
    @State private var storedURLs: [URL] = []
    @State private var identities: [LocalPDFSigner.Identity] = []
    @State private var selectedIdentity = ""
    @State private var choosingMedication: UUID?
    @State private var assistedCatalog: CockpitMedicationCatalog?
    @State private var error: String?
    @State private var busy = false
    @State private var showsNumbers = false
    @State private var showsDelivery = false
    @State private var confirmsSign = false
    @State private var confirmsClose = false
    @State private var recoverable: [SNCRRegistry.Number] = []
    @State private var registry: SNCRRegistryStore?
    @AppStorage(SNCREnvironment.defaultsKey) private var environmentSetting = ""
    private var environment: SNCREnvironment { registry?.environment ?? .current }
    private var issuing: Bool { reservedNumber != nil || signed != nil || !storedURLs.isEmpty }

    init(patient: PatientSummary, encounterID: String? = nil, authorizationURL: URL? = nil, initialDraft: CockpitPrescription? = nil, onArchive: @escaping (PreparedClinicalDocument) throws -> URL, onClose: @escaping () -> Void, embedded: Bool = false, onFreeze: @escaping () -> Void = {}, onReviewError: @escaping (String) -> Void = { _ in }, onBusy: @escaping (Bool) -> Void = { _ in }) {
        self.patient = patient; self.encounterID = encounterID; self.authorizationURL = authorizationURL; self.onArchive = onArchive; self.onClose = onClose
        self.embedded = embedded; self.onFreeze = onFreeze; self.onReviewError = onReviewError; self.onBusy = onBusy
        _draft = State(initialValue: initialDraft ?? CockpitPrescription(patient: patient))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Receituário").font(.title2.weight(.semibold))
                    Text(patient.displayName).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Meus números") { showsNumbers = true }.disabled(registry == nil || busy)
                if !embedded { Button("Fechar") { confirmsClose = true }.keyboardShortcut(.cancelAction).disabled(busy) }
            }
            Label(environment == .production ? "Produção · numeração real do SNCR" : "Homologação · documentos sintéticos",
                  systemImage: environment == .production ? "checkmark.seal" : "testtube.2").font(.callout).foregroundStyle(.secondary)
            if !embedded, preview == nil, !recoverable.isEmpty {
                Menu("Retomar emissão pendente") {
                    ForEach(recoverable) { pending in
                        Button("\(pending.type) · \(pending.id)") { recover(pending) }
                    }
                }
            }
            if let preview {
                ClinicalPDFPreview(data: signed?.data ?? signaturePreparation?.pdf ?? preview.data)
                    .id(SNCRRegistry.hash(signed?.data ?? signaturePreparation?.pdf ?? preview.data))
                    .frame(minHeight: 420)
                if let term {
                    DisclosureGroup("Termo que acompanha esta notificação") {
                        ClinicalPDFPreview(data: term.data).frame(height: 380)
                        Text("O termo acompanha a receita e exige as assinaturas indicadas no próprio documento.").font(.callout)
                    }
                }
                if signed == nil, reservedNumber != nil || draft.tipo == "SIMPLE" {
                    HStack {
                        Picker("Certificado", selection: $selectedIdentity) {
                            Text("Selecione o certificado do VIDaaS").tag("")
                            ForEach(identities) { Text($0.name).tag($0.id) }
                        }
                        Button("Atualizar certificados") { loadIdentities() }.disabled(busy)
                    }
                }
                HStack {
                    if reservedNumber == nil && signed == nil && storedURLs.isEmpty && !embedded {
                        Button("Voltar e editar") { self.preview = nil; term = nil; reviewedHash = nil }
                    }
                    Spacer()
                    if !storedURLs.isEmpty {
                        Button("Enviar PDF…") { showsDelivery = true }.buttonStyle(.borderedProminent)
                        ShareLink(items: storedURLs) { Label("Compartilhar PDFs", systemImage: "square.and.arrow.up") }
                        Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting(storedURLs) }
                    } else if signed != nil {
                        Button("Guardar PDF assinado") { archive() }.buttonStyle(.borderedProminent).disabled(busy)
                    } else if draft.tipo == "SIMPLE" {
                        Button("Guardar PDF") { archiveSimple() }.disabled(busy)
                        Button("Assinar com certificado local…") { confirmsSign = true }
                            .buttonStyle(.borderedProminent).disabled(selectedIdentity.isEmpty || signaturePreparation == nil || busy)
                    } else if reservedNumber != nil {
                        Button("Assinar com certificado local…") { confirmsSign = true }
                            .buttonStyle(.borderedProminent).disabled(selectedIdentity.isEmpty || signaturePreparation == nil || busy)
                    } else {
                        Button("Reservar número e revisar") { reserveAndReview() }.buttonStyle(.borderedProminent).disabled(busy || registry == nil)
                    }
                }
            } else if !embedded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Picker("Tipo de receita", selection: $draft.tipo) {
                            ForEach(SNCRRegistry.types, id: \.self) { Text(CockpitPrescription.names[$0] ?? $0).tag($0) }
                        }.disabled(draft.medications.count > 1)
                        patientFields
                        medicationFields
                        emitterFields
                    }.padding(4)
                }
                HStack {
                    Spacer()
                    Button("Revisar receita") { render() }.buttonStyle(.borderedProminent).disabled(busy)
                }
            }
            if busy { ProgressView("Preparando…").controlSize(.small) }
            if let error { Text("Erro: " + error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(embedded ? 0 : 24).frame(minWidth: embedded ? 0 : 640, minHeight: embedded ? 480 : 650)
        .interactiveDismissDisabled()
        .task {
            if !scopedAccess { scopedAccess = authorizationURL?.startAccessingSecurityScopedResource() ?? false }
            prepareRegistry()
            do { assistedCatalog = try CockpitMedicationCatalog.load() }
            catch { self.error = error.localizedDescription }
            if embedded {
                if let pending = recoverable.first(where: { $0.documentID == draft.id }) {
                    if pending.contentHash == draft.hash { onFreeze(); recover(pending) }
                    else { error = "Esta receita já tem uma reserva com outro conteúdo. Retome a emissão pendente antes de alterar." }
                } else { render() }
            }
        }
        .onChange(of: busy) { _, value in onBusy(value) }
        .onDisappear { if scopedAccess { authorizationURL?.stopAccessingSecurityScopedResource(); scopedAccess = false } }
        .sheet(isPresented: $showsNumbers) {
            if let registry { SNCRNumbersView(store: registry, prescriber: draft.prescriber, allowsEnvironmentChange: !issuing, onClose: { showsNumbers = false }) }
        }
        .onChange(of: environmentSetting) {
            // A document already tied to a number keeps the environment it started in.
            guard !issuing, registry?.environment != .current else { return }
            prepareRegistry()
            if preview != nil { render() }
        }
        .sheet(isPresented: $showsDelivery) {
            DocumentDeliveryView(files: storedURLs, patient: patient, onClose: { showsDelivery = false }, onCompleted: { showsDelivery = false })
        }
        .confirmationDialog(environment == .production ? "Assinar esta receita com o certificado selecionado?" : "Assinar este PDF de ensaio com o certificado selecionado?",
                            isPresented: $confirmsSign, titleVisibility: .visible) {
            Button("Confirmar assinatura") { sign() }
        } message: { Text("Confira o documento e o titular do certificado. O VIDaaS pode solicitar autorização. "
            + (environment == .production ? "O app confere a integridade da assinatura, não a política ICP-Brasil." : "O arquivo continua sendo um ensaio sem validade clínica.")) }
        .confirmationDialog("Fechar o receituário?", isPresented: $confirmsClose, titleVisibility: .visible) {
            Button("Fechar", role: .destructive, action: onClose)
        } message: {
            Text(reservedNumber == nil ? "O texto ainda não guardado será descartado. PDFs já arquivados permanecem no prontuário." : "A reserva e a emissão pendente ficam no registro local para retomada. Não haverá nova assinatura automática.")
        }
    }
    private var patientFields: some View {
        GroupBox("Paciente") {
            VStack(alignment: .leading, spacing: 12) {
                field("Nome", $draft.paciente.nome)
                field("CPF ou passaporte", $draft.paciente.documento)
                field("Endereço completo", $draft.paciente.endereco)
                HStack { field("Cidade", $draft.paciente.cidade); statePicker($draft.paciente.uf) }
                if draft.needsBirth {
                    HStack {
                        field("Nascimento (AAAA-MM-DD)", $draft.paciente.nascimento)
                        Picker("Sexo", selection: $draft.paciente.sexo) { Text("Selecionar").tag(""); Text("Feminino").tag("F"); Text("Masculino").tag("M") }
                    }
                }
                if draft.tipo == "NRT" {
                    HStack { field("CID", $draft.paciente.cid); field("Telefone (opcional)", $draft.paciente.telefone) }
                    Toggle("Incluir responsável", isOn: $draft.includesGuardian)
                    if draft.includesGuardian {
                        field("Nome do responsável", $draft.responsavel.nome)
                        field("CPF ou passaporte do responsável", $draft.responsavel.documento)
                        field("Endereço do responsável", $draft.responsavel.endereco)
                        field("Telefone do responsável (opcional)", $draft.responsavel.telefone)
                    }
                }
            }.padding(8)
        }
    }
    private var medicationFields: some View {
        GroupBox("Medicamentos") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach($draft.medications) { $medication in
                    VStack(alignment: .leading, spacing: 10) {
                        if let assistedCatalog {
                            CockpitMedicationAssistanceView(medication: $medication, catalog: assistedCatalog, recipeType: draft.tipo) { entry in
                                do { try draft.choose(entry, for: medication.id); error = nil }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                        HStack {
                            field("Medicamento ou substância", $medication.nome)
                            Button("CMED…") { choosingMedication = medication.id }
                                .popover(isPresented: Binding(get: { choosingMedication == medication.id }, set: { if !$0 { choosingMedication = nil } })) {
                                    CockpitMedicationSearch { entry in
                                        medication.nome = entry.name
                                        medication.catalog = entry.metadata
                                        medication.assistance = nil
                                        choosingMedication = nil
                                    }
                                }
                            if draft.medications.count > 1 {
                                Button("Remover", role: .destructive) { draft.medications.removeAll { $0.id == medication.id } }
                            }
                        }
                        HStack { field("Concentração", $medication.concentracao); field("Forma farmacêutica", $medication.forma) }
                        HStack { field("Quantidade", $medication.quantidade); field("Unidade", $medication.unidade) }
                        field("Posologia", $medication.posologia, lines: 3)
                        if draft.tipo == "NRT" {
                            field("Tempo de tratamento", $medication.tempo)
                            field("Outras orientações (opcional)", $medication.orientacoes, lines: 2)
                        }
                    }
                    Divider()
                }
                if draft.multiItem, draft.medications.count < 3 {
                    Button("Adicionar medicamento", systemImage: "plus") { draft.medications.append(.init()) }
                }
            }.padding(8)
        }
    }
    private var emitterFields: some View {
        GroupBox("Emitente") {
            VStack(alignment: .leading, spacing: 12) {
                field("Nome do médico", $draft.prescriber.nome)
                HStack { field("CPF do médico", $draft.prescriber.cpf); field("CRM", $draft.prescriber.crm); statePicker($draft.prescriber.uf) }
                field("Endereço do consultório", $draft.emitente.endereco)
                HStack { field("Cidade", $draft.emitente.cidade); statePicker($draft.emitente.uf) }
                field("Telefone do consultório (opcional)", $draft.emitente.telefone)
                if draft.tipo == "NRT" {
                    field("Especialidade", $draft.emitente.especialidade)
                    field("Cadastro do prescritor de talidomida", $draft.emitente.cadastro)
                }
            }.padding(8)
        }
    }
    private func field(_ label: String, _ value: Binding<String>, lines: Int = 1) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            TextField(label, text: value, axis: .vertical).textFieldStyle(.roundedBorder)
                .lineLimit(lines...max(lines, 4)).accessibilityLabel(label)
        }
    }
    private func statePicker(_ value: Binding<String>) -> some View {
        Picker("UF", selection: value) {
            Text("Selecionar").tag("")
            ForEach(CockpitPrescription.states, id: \.self) { Text($0).tag($0) }
        }.frame(width: 130)
    }
    private func prepareRegistry() {
        do {
            let root = patient.url.deletingLastPathComponent().deletingLastPathComponent()
            let vault = try VaultReader().open(root)
            guard vault.writingAllowed else { throw CockpitError.invalidRegistry }
            registry = SNCRRegistryStore(vaultURL: root, vaultID: vault.manifest.vaultID)
            recoverable = try registry!.read().numbers.filter { $0.patientID == patient.patientID && $0.encounterID == encounterID && $0.state == "reserved" && $0.draft != nil }
        } catch { self.error = error.localizedDescription }
    }
    private func render() {
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                if draft.tipo == "SIMPLE" {
                    let identity = DoctorProfileStore.load().documentIdentity
                    let body = (environment == .production ? "" : "ENSAIO SINTÉTICO — SEM VALIDADE CLÍNICA\n\n") + UnifiedPrescription.medicationText(draft.medications)
                    let data = try ClinicalDocumentPDF.make(title: "Receita simples", patientName: draft.paciente.nome,
                        professional: draft.prescriber.nome, body: body, doctorIdentity: identity, date: draft.date)
                    let source = String(data: try JSONEncoder().encode(draft), encoding: .utf8) ?? body
                    preview = try PreparedClinicalDocument(title: "Receita simples", data: data, sourceText: source,
                        professional: draft.prescriber.nome, doctorIdentity: identity, createdAt: draft.date)
                    reviewedHash = draft.hash
                    signaturePreparation = try await renderer.prepareSignature(data)
                    // Certificates are optional for the simple preview; load only on demand.
                    return
                }
                var input = try draft.input(number: reservedNumber)
                input["environment"] = environment.rawValue
                let result = try await renderer.render(input)
                let identity = DoctorProfileStore.load().documentIdentity
                preview = try PreparedClinicalDocument(title: CockpitPrescription.names[draft.tipo] ?? draft.tipo, data: result.pdf,
                    sourceText: result.source, professional: draft.prescriber.nome, doctorIdentity: identity, createdAt: draft.date)
                term = try result.term.map { try PreparedClinicalDocument(title: "Termo · " + (CockpitPrescription.names[draft.tipo] ?? draft.tipo),
                    data: $0, sourceText: result.source, professional: draft.prescriber.nome, doctorIdentity: identity, createdAt: draft.date) }
                reviewedHash = draft.hash
                if reservedNumber != nil { signaturePreparation = try await renderer.prepareSignature(result.pdf); loadIdentities() }
            } catch { self.error = error.localizedDescription; onReviewError(error.localizedDescription) }
        }
    }
    private func reserveAndReview() {
        do {
            guard reviewedHash == draft.hash, let registry else { throw CockpitError.invalidRegistry }
            reservedNumber = try registry.update { ledger in
                let number = try ledger.reserve(prescriber: draft.prescriber.key, type: draft.tipo, documentID: draft.id, contentHash: draft.hash)
                guard let index = ledger.numbers.firstIndex(where: { $0.id == number }) else { throw CockpitError.invalidRegistry }
                ledger.numbers[index].patientID = patient.patientID; ledger.numbers[index].encounterID = encounterID
                ledger.numbers[index].draft = draft
                return number
            }
            onFreeze(); render()
        } catch { self.error = error.localizedDescription }
    }
    private func loadIdentities() {
        do { identities = try LocalPDFSigner.identities(); if identities.isEmpty { error = "Nenhum certificado disponível. Abra o VIDaaS Connect e atualize a lista." } }
        catch { self.error = error.localizedDescription }
    }
    private func sign() {
        guard let prepared = signaturePreparation, let identity = identities.first(where: { $0.id == selectedIdentity }),
              let preview, reviewedHash == draft.hash else { return }
        busy = true; error = nil
        // A single operation after explicit confirmation. No automatic replay on cancellation/failure.
        Task { @MainActor in
            defer { busy = false }
            do {
                let bytes = try await Task.detached(priority: .userInitiated) { try LocalPDFSigner.sign(prepared, with: identity) }.value
                signingCertificate = identity.certificate
                signed = try PreparedClinicalDocument(title: preview.title, data: bytes, sourceText: preview.sourceText,
                    professional: preview.professional, doctorIdentity: preview.doctorIdentity, createdAt: preview.createdAt)
                if draft.tipo == "SIMPLE" { onFreeze(); archiveSimple(); return }
                guard let registry, let signed else { throw CockpitError.invalidRegistry }
                try registry.update { ledger in
                    guard let index = ledger.numbers.firstIndex(where: { $0.documentID == draft.id }), ledger.numbers[index].state == "reserved" else { throw CockpitError.invalidRegistry }
                    ledger.numbers[index].pendingCertificate = identity.certificate
                    ledger.numbers[index].pendingDocuments = [signed] + (term.map { [$0] } ?? [])
                }
                archive()
            } catch { self.error = error.localizedDescription }
        }
    }
    private func recover(_ pending: SNCRRegistry.Number) {
        guard let saved = pending.draft, pending.patientID == patient.patientID, pending.encounterID == encounterID else { return }
        draft = saved; reservedNumber = pending.id; reviewedHash = saved.hash; error = nil
        if let documents = pending.pendingDocuments, let document = documents.first {
            preview = document; signed = document; signingCertificate = pending.pendingCertificate; term = documents.count > 1 ? documents[1] : nil
        } else { render() }
    }
    private func archiveSimple() {
        do {
            guard reviewedHash == draft.hash, let document = signed ?? preview else { throw CockpitError.invalidRegistry }
            if signed != nil {
                guard let signingCertificate else { throw CockpitError.invalidRegistry }
                try LocalPDFSigner.verifyPDF(document.data, certificate: signingCertificate)
            }
            onFreeze()
            storedURLs = [try onArchive(document)]
        } catch { self.error = error.localizedDescription }
    }
    private func archive() {
        if draft.tipo == "SIMPLE" { archiveSimple(); return }
        do {
            guard let signed, let registry, let signingCertificate, reviewedHash == draft.hash else { throw CockpitError.invalidRegistry }
            try LocalPDFSigner.verifyPDF(signed.data, certificate: signingCertificate)
            try registry.update { ledger in
                guard let i = ledger.numbers.firstIndex(where: { $0.documentID == draft.id }), ledger.numbers[i].state == "reserved" else { throw CockpitError.invalidRegistry }
                ledger.numbers[i].pendingCertificate = signingCertificate
                ledger.numbers[i].pendingDocuments = [signed] + (term.map { [$0] } ?? [])
            }
            var urls = [try onArchive(signed)]
            if let term { urls.append(try onArchive(term)) }
            try registry.update { try $0.confirm(documentID: draft.id, contentHash: draft.hash, pdfHash: SNCRRegistry.hash(signed.data)) }
            storedURLs = urls
        } catch { self.error = "O PDF permanece nesta janela para nova tentativa de guarda. " + error.localizedDescription }
    }
}

private struct CockpitMedicationSearch: View {
    let onChoose: (MedicationCatalog.Entry) -> Void
    @State private var query = ""
    @State private var catalog: MedicationCatalog?
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Nome, princípio ativo ou apresentação", text: $query).textFieldStyle(.roundedBorder)
            if loading { ProgressView("Carregando catálogo local…") }
            if let error { Text(error).foregroundStyle(.red) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(catalog?.search(query, includesHospital: false) ?? []) { entry in
                        Button { onChoose(entry) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.name).font(.headline)
                                Text(entry.presentation).font(.callout)
                                Text(entry.laboratory).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Divider()
                    }
                }
            }.frame(height: 280)
            Text(catalog?.publication ?? "CMED · Anvisa").font(.caption).foregroundStyle(.secondary)
            Text("Confira concentração e forma farmacêutica no formulário. A seleção não preenche posologia nem escolhe o tipo de receita.").font(.callout)
            Button("Atualizar catálogo") { load(refresh: true) }.disabled(loading)
        }.padding(16).frame(width: 430).task { load() }
    }
    private func load(refresh: Bool = false) {
        loading = true; error = nil
        Task { @MainActor in
            defer { loading = false }
            do { catalog = try await Task.detached { try await MedicationCatalog.load(refresh: refresh) }.value }
            catch { self.error = error.localizedDescription }
        }
    }
}
