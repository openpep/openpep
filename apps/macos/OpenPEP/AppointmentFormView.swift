// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

struct AppointmentActionsView: View {
    let appointment: AppointmentSummary
    let patient: PatientSummary?
    let hasConsultation: Bool
    let canStart: Bool
    let canEdit: Bool
    let canCancel: Bool
    let error: String?
    let onClose: () -> Void
    let onConsultation: () -> Void
    let onEdit: () -> Void
    let onWhatsApp: (String, WhatsAppDestination) -> Void
    let onCancelAppointment: () -> Void
    let onStatus: (AppointmentStatus) -> Void
    @State private var showsStatus = false
    @State private var confirmsCancel = false
    @State private var contactID = ""
    @State private var status: AppointmentStatus = .scheduled

    private var contacts: [TelemedicineContactOption] {
        patient.map { WhatsAppShare.contacts(for: $0) } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Agendamento").font(.title2.weight(.semibold))
                Spacer()
                Button("Fechar", action: onClose).keyboardShortcut(.cancelAction)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(patient?.displayName ?? "Paciente indisponível").font(.headline)
                Text(appointment.record.startDate.formatted(date: .abbreviated, time: .shortened))
                Label(appointment.record.modality == .telemedicine ? "Teleconsulta" : "Presencial",
                      systemImage: appointment.record.modality == .telemedicine ? "video" : "person.2")
                    .foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            VStack(spacing: 10) {
                Button(action: onConsultation) {
                    Label(hasConsultation ? "Voltar à consulta" : "Iniciar consulta", systemImage: "stethoscope")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent).disabled(!hasConsultation && !canStart)
                Button(action: onEdit) {
                    Label("Editar agendamento", systemImage: "calendar.badge.clock")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                }.disabled(!canEdit)
                Button { onWhatsApp(contactID, .app) } label: {
                    Label("Comunicar-se com a paciente", systemImage: "message")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                }.disabled(contacts.isEmpty)
            }.buttonStyle(.bordered).controlSize(.large)
            if contacts.count > 1 {
                Picker("Telefone da paciente", selection: $contactID) {
                    ForEach(contacts) { Text($0.displayValue).tag($0.id) }
                }
            } else if let contact = contacts.first {
                Text(contact.displayValue).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Cadastre um telefone cadastrado da paciente para abrir o WhatsApp.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !contacts.isEmpty {
                Button("Usar WhatsApp Web") { onWhatsApp(contactID, .web) }.font(.caption)
                Text("Abre a conversa; nenhuma mensagem é enviada automaticamente.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("Cancelar agendamento", role: .destructive) { confirmsCancel = true }
                    .disabled(!canCancel)
                Spacer()
                Button("Alterar status") { showsStatus.toggle() }.disabled(!canEdit)
            }.buttonStyle(.borderless).font(.callout)
            if showsStatus {
                Picker("Status", selection: $status) {
                    ForEach(AppointmentStatus.allCases.filter { $0 != .cancelled }, id: \.self) {
                        Text(appointmentStatusLabel($0)).tag($0)
                    }
                }
                Text("Ajuste manual excepcional. Não inicia nem finaliza a consulta clínica.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Aplicar status") { onStatus(status) }
                    .disabled(status == appointment.record.status)
            }
        }
        .padding(24).frame(width: 460)
        .onAppear { status = appointment.record.status; contactID = contacts.first?.id ?? "" }
        .confirmationDialog("Cancelar este agendamento?", isPresented: $confirmsCancel) {
            Button("Cancelar agendamento", role: .destructive, action: onCancelAppointment)
            Button("Manter agendamento", role: .cancel) { }
        } message: { Text("O registro será preservado no histórico.") }
    }
}
import UniformTypeIdentifiers

struct AppointmentFormView: View {
    @ObservedObject private var googleMeetController: GoogleMeetIntegrationController
    let title: String
    let onCancel: () -> Void
    let onCancelAppointment: (() -> Void)?
    let onSave: (AppointmentInput) -> Void
    let onSaveAndShare: (AppointmentInput, Bool) -> Void
    let onOpenConsultation: (() -> Void)?
    let conflicts: (AppointmentInput) -> [String]
    let onCreatePatient: (PatientRecordInput) throws -> PatientSummary
    let duplicatePatientNames: (PatientRecordInput) -> [String]
    let onImportDocuments: (String, String?, [URL]) throws -> Int

    private let initialInput: AppointmentInput
    private let linkedEncounterID: String?
    @State private var availablePatients: [PatientSummary]
    @State private var patientID: String
    @State private var patientSearch = ""
    @FocusState private var timeFocused: Bool
    @State private var startsAt: Date
    @State private var showsCustomDuration = false
    @State private var durationMinutes: Int
    @State private var timeZoneID: String
    @State private var modality: AppointmentModality
    @State private var status: AppointmentStatus
    @State private var location: String
    @State private var remoteAccessURL: String
    @State private var administrativeNote: String
    @State private var telemedicineConsentConfirmed: Bool
    @State private var conflictWarning: String?
    @State private var patientCreationError: String?
    @State private var documentImportMessage: String?
    @State private var documentImportError: String?
    @State private var confirmsCancel = false
    @State private var confirmsAppointmentCancellation = false
    @State private var createsPatient = false
    @State private var isImportingDocuments = false

    init(
        title: String,
        patients: [PatientSummary],
        appointment: AppointmentSummary?,
        defaultDate: Date,
        initialPatientID: String? = nil,
        googleMeetController: GoogleMeetIntegrationController,
        onCancel: @escaping () -> Void,
        onCancelAppointment: (() -> Void)?,
        onSave: @escaping (AppointmentInput) -> Void,
        onSaveAndShare: @escaping (AppointmentInput, Bool) -> Void,
        onOpenConsultation: (() -> Void)?,
        conflicts: @escaping (AppointmentInput) -> [String],
        onCreatePatient: @escaping (PatientRecordInput) throws -> PatientSummary,
        duplicatePatientNames: @escaping (PatientRecordInput) -> [String],
        onImportDocuments: @escaping (String, String?, [URL]) throws -> Int
    ) {
        self.title = title
        self.googleMeetController = googleMeetController
        self.onCancel = onCancel
        self.onCancelAppointment = onCancelAppointment
        self.onSave = onSave
        self.onSaveAndShare = onSaveAndShare
        self.onOpenConsultation = onOpenConsultation
        self.conflicts = conflicts
        self.onCreatePatient = onCreatePatient
        self.duplicatePatientNames = duplicatePatientNames
        self.onImportDocuments = onImportDocuments
        linkedEncounterID = appointment?.record.encounterID

        let start = appointment?.record.startDate ?? AppointmentClock.nearestQuarter(defaultDate)
        let duration = appointment.map {
            max(1, Int($0.record.endDate.timeIntervalSince($0.record.startDate) / 60))
        } ?? AppointmentDefaults.durationMinutes
        let input = AppointmentInput(
            patientID: appointment?.record.patientID ?? initialPatientID ?? "",
            startsAt: start,
            endsAt: AppointmentTimeRange.end(start: start, durationMinutes: duration),
            timeZone: appointment?.record.timeZone ?? TimeZone.current.identifier,
            modality: appointment?.record.modality ?? .inPerson,
            status: appointment?.record.status ?? .scheduled,
            location: appointment?.record.location ?? (appointment == nil ? DoctorProfileStore.load().offices.first(where: { $0.id == DoctorProfileStore.load().defaultOfficeID })?.address ?? DoctorProfileStore.load().offices.first?.address : nil),
            remoteAccessURL: appointment?.record.remoteAccessURL,
            administrativeNote: appointment?.record.administrativeNote,
            telemedicineConsentConfirmed: appointment?.record.telemedicineConsentConfirmed ?? false
        ).normalized()
        initialInput = input
        _availablePatients = State(initialValue: patients)
        _patientID = State(initialValue: input.patientID)
        _startsAt = State(initialValue: input.startsAt)
        _durationMinutes = State(initialValue: duration)
        _timeZoneID = State(initialValue: input.timeZone)
        _modality = State(initialValue: input.modality)
        _status = State(initialValue: input.status)
        _location = State(initialValue: input.location ?? "")
        _remoteAccessURL = State(initialValue: input.remoteAccessURL ?? "")
        _administrativeNote = State(initialValue: input.administrativeNote ?? "")
        _telemedicineConsentConfirmed = State(initialValue: input.telemedicineConsentConfirmed)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                }
                Spacer()
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    patientSection
                    scheduleSection
                    careSection
                    DisclosureGroup("Observações e arquivos") {
                        administrativeNoteSection
                        documentsSection
                    }
                    conflictSection
                }
                .padding(24)
                .frame(maxWidth: 720, alignment: .leading)
            }

            Divider()
            HStack {
                if let onOpenConsultation {
                    Button("Abrir consulta", systemImage: "stethoscope", action: onOpenConsultation)
                        .disabled(input != initialInput)
                        .help("Salve as alterações do agendamento antes de abrir a consulta")
                }
                if onCancelAppointment != nil {
                    Button("Cancelar agendamento…", role: .destructive) {
                        confirmsAppointmentCancellation = true
                    }
                }
                Spacer()
                Button("Cancelar") {
                    if input == initialInput {
                        onCancel()
                    } else {
                        confirmsCancel = true
                    }
                }
                .keyboardShortcut(.cancelAction)
                Button(conflictWarning == nil ? "Salvar" : "Salvar mesmo assim") {
                    let matches = conflicts(input)
                    let warning = matches.isEmpty
                        ? nil
                        : "Sobreposição com \(matches.joined(separator: ", "))."
                    if warning == nil || warning == conflictWarning {
                        onSave(input)
                    } else {
                        conflictWarning = warning
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(patientID.isEmpty || !durationIsValid || !remoteURLIsValid)
                if modality == .telemedicine, !remoteAccessURL.isEmpty {
                    Menu("Salvar e enviar link") {
                        Button("WhatsApp…") { saveAndShare(email: false) }
                        Button("E-mail…") { saveAndShare(email: true) }
                    }
                    .disabled(patientID.isEmpty || !durationIsValid || !remoteURLIsValid)
                }
            }
            .padding()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 700, idealWidth: 760, minHeight: 680)
        .disabled(googleMeetController.state == .creating)
        .interactiveDismissDisabled(googleMeetController.state == .creating || input != initialInput)
        .onChange(of: startsAt) { _, _ in conflictWarning = nil }
        .onChange(of: durationMinutes) { _, _ in conflictWarning = nil }
        .onChange(of: patientID) { _, _ in
            conflictWarning = nil
            telemedicineConsentConfirmed = false
            remoteAccessURL = ""
        }
        .onChange(of: modality) { _, newValue in
            if newValue == .inPerson {
                remoteAccessURL = ""
                telemedicineConsentConfirmed = false
            } else {
                location = ""
            }
        }
        .confirmationDialog(
            "Descartar alterações do agendamento?",
            isPresented: $confirmsCancel,
            titleVisibility: .visible
        ) {
            Button("Descartar alterações", role: .destructive, action: onCancel)
            Button("Continuar editando", role: .cancel) {}
        }
        .confirmationDialog(
            "Cancelar agendamento?",
            isPresented: $confirmsAppointmentCancellation,
            titleVisibility: .visible
        ) {
            Button("Cancelar agendamento", role: .destructive) {
                onCancelAppointment?()
            }
            Button("Manter agendamento", role: .cancel) {}
        } message: {
            Text("O item sairá da agenda, mas seu arquivo será preservado com o estado Cancelado.")
        }
        .sheet(isPresented: $createsPatient) {
            PatientFormView(
                title: "Novo paciente",
                record: nil,
                onCancel: { createsPatient = false },
                onSave: createPatient,
                duplicateNames: duplicatePatientNames
            )
        }
    }

    private var patientSection: some View {
        appointmentSection("Paciente") {
            VStack(alignment: .leading, spacing: 10) {
                if !patientID.isEmpty {
                    HStack {
                        if let selectedPatient {
                            Label(selectedPatient.displayName, systemImage: "person.crop.circle.fill.badge.checkmark")
                                .font(.headline)
                                .accessibilityLabel("Paciente selecionado: \(selectedPatient.displayName)")
                        } else {
                            Label(patientID, systemImage: "person.crop.circle.badge.questionmark")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            patientID = ""
                            patientSearch = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Trocar paciente")
                        .help("Trocar paciente")
                        .disabled(linkedEncounterID != nil)
                    }
                } else {
                    TextField("Buscar por nome, nome preferido, CPF ou identificador", text: $patientSearch).searchClearButton($patientSearch)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Buscar paciente para o agendamento")

                    if !patientSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if patientResults.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Nenhum paciente encontrado.", systemImage: "magnifyingglass")
                                    .font(.callout)
                                Text("Revise a busca ou cadastre um novo paciente.")
                                    .font(.caption)
                            }
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                        } else {
                            VStack(spacing: 4) {
                                ForEach(patientResults.prefix(8), id: \.patientID) { patient in
                                    Button {
                                        patientID = patient.patientID
                                        patientSearch = ""
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(patient.displayName)
                                                if let fullName = patient.record?.fullName,
                                                   fullName != patient.displayName {
                                                    Text(fullName)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                            Spacer()
                                            Text(patient.patientID)
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(7)
                                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityHint("Seleciona este paciente")
                                }
                            }
                        }
                    } else {
                        Text("Digite para localizar um paciente ativo. A busca não fica armazenada.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        patientCreationError = nil
                        createsPatient = true
                    } label: {
                        Label("Novo paciente…", systemImage: "person.badge.plus")
                    }
                }
                if let message = patientCreationError {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .accessibilityLabel("Erro: \(message)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var documentsSection: some View {
        appointmentSection("Documentos") {
            VStack(alignment: .leading, spacing: 10) {
                Button(action: chooseDocuments) {
                    Label("Importar documento…", systemImage: "doc.badge.plus")
                }
                .disabled(patientID.isEmpty || isImportingDocuments)
                .accessibilityHint("Copia documentos para a pasta do paciente selecionado")
                if patientID.isEmpty {
                    Text("Selecione um paciente para importar documentos.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isImportingDocuments {
                    ProgressView("Copiando e verificando…")
                        .controlSize(.small)
                }
                if let documentImportMessage {
                    Label(documentImportMessage, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let documentImportError {
                    Label(documentImportError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .accessibilityLabel("Erro: \(documentImportError)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private func appointmentSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.5)))
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Data e horário").font(.headline)
            HStack(alignment: .top, spacing: 28) {
                DatePicker("Data", selection: $startsAt, displayedComponents: .date)
                    .datePickerStyle(.graphical).labelsHidden().controlSize(.large)
                    .scaleEffect(1.35)
                    .environment(\.locale, Locale(identifier: "pt_BR"))
                    .frame(width: 260, height: 230)
                VStack(alignment: .leading, spacing: 18) {
                    timeFields
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Duração").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach([15, 30, 45, 60], id: \.self) { minutes in
                                Button { durationMinutes = minutes; showsCustomDuration = false } label: {
                                    Text("\(minutes) min").frame(maxWidth: .infinity).padding(.vertical, 8)
                                        .background(durationMinutes == minutes ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(durationMinutes == minutes ? Color.accentColor : .clear))
                                }.buttonStyle(.plain)
                                .accessibilityAddTraits(durationMinutes == minutes ? .isSelected : [])
                            }
                        }
                        if showsCustomDuration || ![15, 30, 45, 60].contains(durationMinutes) {
                        HStack {
                            Text("Outra").foregroundStyle(.secondary)
                            TextField("Minutos", value: $durationMinutes, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 60)
                                .accessibilityLabel("Duração em minutos")
                            Text("min").foregroundStyle(.secondary)
                        }.font(.callout)
                        } else {
                            Button("Outra duração…") { showsCustomDuration = true }.buttonStyle(.borderless)
                        }
                        if !durationIsValid {
                            Text("Use de 5 a 480 minutos.").font(.caption).foregroundStyle(.red)
                        }
                    }
                    Label("Até " + endsAt.formatted(.dateTime.hour().minute().locale(Locale(identifier: "pt_BR"))), systemImage: "clock")
                        .font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.6)))
        .help("Fuso: " + timeZoneID)
    }

    private var careSection: some View {
        appointmentSection("Atendimento") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Modalidade").font(.callout.weight(.medium))
                    Picker("Modalidade", selection: $modality) {
                        Label("Presencial", systemImage: "person.2").tag(AppointmentModality.inPerson)
                        Label("Teleconsulta", systemImage: "video").tag(AppointmentModality.telemedicine)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(linkedEncounterID != nil)
                    .frame(maxWidth: 360, alignment: .leading)
                    if linkedEncounterID != nil {
                        Text("A consulta já foi iniciada. A modalidade registrada não pode ser alterada neste agendamento.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if modality == .inPerson {
                    let offices = DoctorProfileStore.load().offices.filter { !$0.address.isEmpty }
                    if !offices.isEmpty {
                        Picker("Local", selection: $location) {
                            Text("Outro local…").tag("")
                            ForEach(offices) { office in
                                Text(office.name.isEmpty ? office.address : office.name).tag(AppointmentClock.location(office.address))
                            }
                            if !location.isEmpty && !offices.contains(where: { AppointmentClock.location($0.address) == location }) {
                                Text(location).tag(location)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !offices.contains(where: { AppointmentClock.location($0.address) == location }) {
                        textField("Local", prompt: "Consultório ou endereço", text: $location)
                    }
                } else {
                    if linkedEncounterID != nil, let saved = initialInput.remoteAccessURL {
                        Label("Link vinculado à consulta", systemImage: "checkmark.circle")
                        Text(saved).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    } else {
                    textField("Link remoto", prompt: "https://meet.google.com/...", text: $remoteAccessURL)
                    Text("Cole um link existente ou crie uma sala do Google Meet. Depois salve o agendamento para vincular o link.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    GoogleMeetCreationView(controller: googleMeetController) { url in
                        remoteAccessURL = url.absoluteString
                    }
                    }
                    Toggle("Paciente concordou com a teleconsulta", isOn: $telemedicineConsentConfirmed)
                        .disabled(linkedEncounterID != nil)
                    Text("Marque somente após obter a concordância. Não autoriza gravação. Salve para registrar.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !remoteURLIsValid {
                        Label("Use um link HTTPS válido.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var administrativeNoteSection: some View {
        appointmentSection("Observação administrativa") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Informação operacional", text: $administrativeNote, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                Text("Evite texto clínico sensível desnecessário nesta área.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    @ViewBuilder
    private var conflictSection: some View {
        if let conflictWarning {
            appointmentSection("Conflito de horário") {
                VStack(alignment: .leading, spacing: 8) {
                    Label(conflictWarning, systemImage: "calendar.badge.exclamationmark")
                    Text("Confira os horários. Se a sobreposição for intencional, salve novamente.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
        }
    }

    private var input: AppointmentInput {
        AppointmentInput(
            patientID: patientID,
            startsAt: startsAt,
            endsAt: endsAt,
            timeZone: timeZoneID,
            modality: modality,
            status: status,
            location: location,
            remoteAccessURL: remoteAccessURL,
            administrativeNote: administrativeNote,
            telemedicineConsentConfirmed: telemedicineConsentConfirmed
        ).normalized()
    }

    private var selectedPatient: PatientSummary? {
        availablePatients.first { $0.patientID == patientID }
    }

    private func saveAndShare(email: Bool) {
        let matches = conflicts(input)
        let warning = matches.isEmpty ? nil : "Sobreposição com \(matches.joined(separator: ", "))."
        if warning == nil || warning == conflictWarning {
            onSaveAndShare(input, email)
        } else {
            conflictWarning = warning
        }
    }

    private var patientResults: [PatientSummary] {
        availablePatients.filter { PatientSearch.matches($0, query: patientSearch) }
    }

    private var endsAt: Date {
        AppointmentTimeRange.end(start: startsAt, durationMinutes: durationMinutes)
    }

    private var durationIsValid: Bool {
        (5...480).contains(durationMinutes)
    }

    private var remoteURLIsValid: Bool {
        let value = remoteAccessURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard modality == .telemedicine, !value.isEmpty else { return true }
        return (try? TelemedicineURLBuilder.savedLinkURL(value)) != nil
    }

    private var timeFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Horário").font(.callout.weight(.medium)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                TextField("HH:mm", value: Binding(get: { startsAt }, set: { value in
                    let calendar = Calendar.current
                    setStartTime(hour: calendar.component(.hour, from: value), minute: calendar.component(.minute, from: value))
                }), format: .dateTime.hour().minute().locale(Locale(identifier: "pt_BR")))
                .textFieldStyle(.roundedBorder).font(.title3.monospacedDigit())
                .frame(width: 100).focused($timeFocused)
                .onSubmit { startsAt = AppointmentClock.nearestQuarter(startsAt) }
                .accessibilityLabel("Horário inicial em horas e minutos")
                VStack(spacing: 4) {
                    Button { startsAt = AppointmentClock.nearestQuarter(startsAt).addingTimeInterval(900) } label: {
                        Image(systemName: "chevron.up").frame(width: 32, height: 24)
                    }.accessibilityLabel("Avançar 15 minutos")
                    Button { startsAt = AppointmentClock.nearestQuarter(startsAt).addingTimeInterval(-900) } label: {
                        Image(systemName: "chevron.down").frame(width: 32, height: 24)
                    }.accessibilityLabel("Recuar 15 minutos")
                }.buttonStyle(.bordered)
            }
            .onChange(of: timeFocused) { _, focused in
                if !focused { startsAt = AppointmentClock.nearestQuarter(startsAt) }
            }
        }
    }

    private func setStartTime(hour: Int, minute: Int) {
        startsAt = Calendar.current.date(
            bySettingHour: min(max(hour, 0), 23),
            minute: min(max(minute, 0), 59),
            second: 0,
            of: startsAt
        ) ?? startsAt
    }

    private func textField(_ title: String, prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.callout.weight(.medium))
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func createPatient(_ input: PatientRecordInput) {
        do {
            let patient = try onCreatePatient(input)
            availablePatients.append(patient)
            availablePatients.sort {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            patientID = patient.patientID
            patientSearch = ""
            patientCreationError = nil
            createsPatient = false
        } catch {
            patientCreationError = error.localizedDescription
            createsPatient = false
        }
    }

    private func chooseDocuments() {
        guard !patientID.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Importar documentos para o paciente selecionado"
        panel.message = "PDF, PNG, JPEG ou texto UTF-8; até 25 MiB por arquivo."
        panel.prompt = "Importar"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf, .png, .jpeg, .plainText]
        guard panel.runModal() == .OK else { return }

        isImportingDocuments = true
        documentImportError = nil
        documentImportMessage = nil
        defer { isImportingDocuments = false }
        do {
            let count = try onImportDocuments(patientID, linkedEncounterID, panel.urls)
            documentImportMessage = count == 1
                ? "Documento importado para o paciente."
                : "\(count) documentos importados para o paciente."
        } catch {
            documentImportError = error.localizedDescription
        }
    }
}

func appointmentStatusLabel(_ status: AppointmentStatus) -> String {
    switch status {
    case .scheduled: "Agendado"
    case .arrived: "Chegou"
    case .inProgress: "Em atendimento"
    case .completed: "Concluído"
    case .cancelled: "Cancelado"
    case .noShow: "Não compareceu"
    }
}

/// Quarter-hour alignment also carries across hour and day boundaries.
enum AppointmentClock {
    static func location(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func nearestQuarter(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 900).rounded() * 900)
    }
}
