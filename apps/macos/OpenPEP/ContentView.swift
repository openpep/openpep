// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Combine
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

enum AppSelection: Hashable {
    case home
    case agenda
    case patients
    case search
    case settings
    case settingsTopic(SettingsTopic)
    case patient(String)
    case encounter(patientID: String, encounterID: String)
}

private enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "Automática"
        case .light: "Clara"
        case .dark: "Escura"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}



private enum AppointmentFormMode: Identifiable, Equatable {
    case create(Date)
    case edit(String)

    var id: String {
        switch self {
        case let .create(date): "create:\(date.timeIntervalSinceReferenceDate)"
        case let .edit(appointmentID): "edit:\(appointmentID)"
        }
    }

    var isCreate: Bool {
        if case .create = self { return true }
        return false
    }

    var appointmentID: String? {
        if case let .edit(appointmentID) = self { return appointmentID }
        return nil
    }
}

private struct FaceTimeHandoffContext: Identifiable {
    let appointmentID: String
    let patientName: String
    let contacts: [TelemedicineContactOption]

    var id: String { appointmentID }
}

private struct WhatsAppShareContext: Identifiable {
    let appointment: AppointmentSummary
    let patient: PatientSummary
    var consultationOpen = false
    var invitation: String? {
        try? ConsultationInvitation.text(for: appointment.record, consultationOpen: consultationOpen)
    }
    var id: String { appointment.id }
}

private struct ConsultationSummaryContext: Identifiable {
    let patient: PatientSummary
    let encounter: EncounterSummary
    let vaultURL: URL
    var id: String { encounter.metadata.encounterID }
}

private struct EncounterDetailsContext: Identifiable {
    let patient: PatientSummary
    let encounter: EncounterSummary
    let encounterData: Data
    let vaultURL: URL
    let appointment: AppointmentSummary?
    var id: String { encounter.metadata.encounterID }
}

private struct EncounterLinkShareContext: Identifiable {
    let patient: PatientSummary
    let encounter: EncounterSummary
    let vaultURL: URL
    let link: String
    var id: String { encounter.metadata.encounterID }
}

private struct PreparedConsultationDocumentContext: Identifiable {
    let document: PreparedClinicalDocument
    let patientID: String
    let encounterID: String?
    var id: UUID { document.id }
    let vaultURL: URL
    let vaultID: String
    let patientRecord: PatientRecord?
}

private struct AdministrativeUndo: Identifiable {
    enum Action {
        case patient(String, expected: PatientRecord, previous: PatientStatus)
        case appointment(AppointmentSummary, previous: AppointmentStatus)
    }
    let id = UUID()
    let vaultURL: URL
    let vaultID: String
    let message: String
    let action: Action
}

private struct NewPatientContext: Identifiable {
    let patient: PatientSummary
    var id: String { patient.patientID }
}

private struct PatientWikiSheetContext: Identifiable, Equatable {
    let vaultID: String
    let patientID: String?

    var id: String { vaultID + ":" + (patientID ?? "all") }
}

private struct EncounterStartContext: Identifiable {
    let patientID: String
    let appointmentID: String?

    var id: String { appointmentID.map { "appointment:\($0)" } ?? "patient:\(patientID)" }
}

private struct RawAssetGroup: Identifiable {
    let kind: String?
    let assets: [RawAssetSummary]

    var id: String { kind ?? "other" }
}

private struct EncounterListItem: Identifiable {
    let patient: PatientSummary
    let encounter: EncounterSummary

    var id: String { "\(patient.patientID):\(encounter.metadata.encounterID)" }
}

private enum PatientFormMode: Identifiable, Equatable {
    case create
    case edit(String)

    var id: String {
        switch self {
        case .create: "create"
        case let .edit(patientID): "edit:\(patientID)"
        }
    }
}

struct ContentView: View {
    @StateObject private var googleMeetController = GoogleMeetIntegrationController()
    @AppStorage("openpep.appearance") private var appearanceRawValue = AppearancePreference.system.rawValue
    @AppStorage(AppointmentDefaults.durationKey) private var defaultAppointmentDuration = AppointmentDefaults.standardDurationMinutes
    @AppStorage(AppointmentDefaults.dayStartHourKey) private var agendaDayStartHour = AppointmentDefaults.standardDayStartHour
    @AppStorage(AppointmentDefaults.dayEndHourKey) private var agendaDayEndHour = AppointmentDefaults.standardDayEndHour
    @AppStorage(AppointmentDefaults.gridMinutesKey) private var agendaGridMinutes = AppointmentDefaults.standardGridMinutes
    @AppStorage(ConsultationCaptureSettings.sourceKey)
    private var captureSourceRawValue = ConsultationCaptureSettings.defaultSource
    @AppStorage(ConsultationCaptureSettings.transcriptionModeKey)
    private var transcriptionModeRawValue = ConsultationCaptureSettings.defaultTranscriptionMode
    @AppStorage(ConsultationCaptureSettings.summaryIntervalMinutesKey)
    private var summaryIntervalMinutes = ConsultationCaptureSettings.defaultSummaryIntervalMinutes
    @AppStorage(ConsultationCaptureSettings.consentModeKey)
    private var recordingConsentModeRawValue = ConsultationCaptureSettings.defaultConsentMode
    @AppStorage(ConsultationCaptureSettings.telecallApplicationBundleIdentifierKey)
    private var telecallApplicationBundleIdentifier = ""
    @AppStorage(ConsultationCaptureSettings.telecallApplicationNameKey)
    private var telecallApplicationName = ""
    @AppStorage(AITextSettings.consultationSummaryProviderKey)
    private var consultationSummaryProvider = AITextSettings.defaultConsultationSummaryProvider
    @AppStorage(AITextSettings.consultationSummaryEnabledKey)
    private var allowsOpenAIConsultationSummary = false
    @AppStorage(AITextSettings.consultationSummaryModelKey)
    private var consultationSummaryModel = AITextSettings.defaultConsultationSummaryModel
    @AppStorage(AITextSettings.liveTranscriptionEnabledKey)
    private var allowsOpenAILiveTranscription = false
    @State private var assistant = AssistantPanelController()
    @AppStorage(AITextSettings.assistantVoiceEnabledKey) private var assistantVoiceEnabled = false
    @AppStorage(AITextSettings.enabledKey) private var assistantTextEnabled = false
    @AppStorage(AITextSettings.assistantEnabledKey) private var assistantEnabled = false
    @AppStorage(AITextSettings.modelKey) private var assistantModel = AITextSettings.defaultModel
    @State private var summary: VaultSummary?
    @State private var authorizationURL: URL?
    @State private var selection: AppSelection? = .home
    @State private var backHistory: [AppSelection] = []
    @State private var forwardHistory: [AppSelection] = []
    @State private var draftText = ""
    @State private var preparedConsultationDocument: PreparedConsultationDocumentContext?
    @State private var pendingDocumentPreparation: PreparedConsultationDocumentContext?
    @State private var standaloneDocumentPatient: PatientSummary?
    @State private var standaloneDocumentVault: URL?
    @State private var standaloneDocumentVaultID: String?
    @State private var standaloneDocumentInitialBody = ""
    @State private var homePatientAction: HomePatientAction?
    @State private var patientActionAfterCreation: HomePatientAction?
    @State private var deferredHomePatientAction: (() -> Void)?
    @StateObject private var transcriptionSession = EncounterTranscriptionSession()
    @State private var showsEncounterTranscription = false
    @State private var searchEncounterPreview: SearchEncounterPreview?
    @State private var pendingSearchAddendum: AddendumContext?
    @State private var pendingSearchResume: AppSelection?
    @State private var patientHistoryContext: PatientHistoryContext?
    @State private var patientWikiSheet: PatientWikiSheetContext?
    @State private var lastSavedAt: String?
    @State private var errorMessage: String?
    @State private var noticeMessage: String?
    @State private var transcriptionStartIssue: String?
    @AppStorage(FirstRunSetup.completedKey) private var firstRunCompleted = false
    @State private var showsQuickSetup = false
    @State private var encounterActivity = EncounterActivity()
    @State private var isStartingEncounter = false
    @State private var isOpeningConsultationSummary = false
    @State private var didAttemptVaultRestore = false
    @State private var isRestoringVault = false
    @State private var authenticationSession = LocalAuthenticationSession()
    @State private var patientSearch = ""
    @State private var assistantPatientFilter: AssistantPatientFilter?
    @State private var expandedPatientID: String?
    @State private var patientListWidth: CGFloat = 0
    @State private var previewURL: URL?
    @State private var previewAuthorizationURL: URL?
    @State private var showsClinicalAlerts = false
    @State private var showsEncounterVideo = false
    @State private var isGeneratingDemo = false
    @State private var showsEncounterDocuments = false
    @State private var showsEncounterMore = false
    @State private var patientFormMode: PatientFormMode?
    @State private var newlyCreatedPatient: NewPatientContext?
    @State private var pendingCreatedPatient: NewPatientContext?
    @State private var deferredCreatedPatientAction: (() -> Void)?
    @State private var showsArchivedPatients = false
    @State private var patientPendingArchive: String?
    @State private var confirmsArchive = false
    @State private var selectedAgendaDate = Calendar.current.startOfDay(for: Date())
    @State private var agendaViewMode = AgendaViewMode(rawValue: UserDefaults.standard.string(forKey: AppointmentDefaults.initialModeKey) ?? "week") ?? .week
    private var agendaUsesList: Bool { agendaViewMode == .day }
    @AppStorage(AppointmentDefaults.initialModeKey) private var initialAgendaMode = "week"
    @State private var showsPastAppointments = false
    @State private var agendaNow = Date()
    @State private var appointmentSearch = ""
    @State private var appointmentFormMode: AppointmentFormMode?
    @State private var newAppointmentPatientID: String?
    @State private var appointmentActions: AppointmentSummary?
    @State private var deferredAppointmentAction: (() -> Void)?
    @State private var appointmentPendingCancellation: String?
    @State private var confirmsAppointmentCancellation = false
    @State private var faceTimeHandoffContext: FaceTimeHandoffContext?
    @State private var whatsAppShareContext: WhatsAppShareContext?
    @State private var emailShareContext: WhatsAppShareContext?
    @State private var emailSharingService: NSSharingService?
    @State private var pendingInvitation: WhatsAppShareContext?
    @State private var pendingInvitationUsesEmail = false
    @State private var savedAppointmentInForm: AppointmentSummary?
    @State private var showsTranscriptionPreparation = false
    @State private var showsTeleconsultAudioProbe = false
    @State private var telecallApplications: [TeleconsultAudioApplication] = []
    @State private var isLoadingTelecallApplications = false
    @State private var telecallApplicationStatus: String?
    @State private var consultationSummaryContext: ConsultationSummaryContext?
    @State private var progressiveSummaryUndoTokens: [String: ProgressiveSummaryUndoToken] = [:]
    @State private var transcriptionPanelCollapsed = false
    @State private var encounterDetailsContext: EncounterDetailsContext?
    @State private var isOpeningEncounterDetails = false
    @State private var remoteLinkContext: EncounterDetailsContext?
    @State private var encounterWhatsAppContext: EncounterLinkShareContext?
    @State private var encounterEmailContext: EncounterLinkShareContext?
    @State private var pendingModalityContext: EncounterDetailsContext?
    @State private var showsDraftTrash = false
    @State private var showsEncounterInfo = false
    @State private var isChangingModality = false
    @State private var pendingRemoteLinkAction: (EncounterDetailsContext, EncounterRemoteLinkAction)?
    @State private var encounterStartError: String?
    @State private var isSavingDraft = false
    @State private var draftSaveError: String?
    @State private var confirmsDraftReload = false
    @State private var documentImportContext: DocumentImportContext?
    @State private var documentImportError: String?
    @State private var isImportingDocuments = false
    @State private var patientImportReceipts: [String: String] = [:]
    @State private var isDocumentDropTargeted = false
    @State private var confirmsFinalization = false
    @State private var confirmsDraftDeletion = false
    @State private var documentFinalizationSummary = ""
    @State private var isFinalizing = false
    @State private var finalizationError: String?
    @State private var addendumContext: AddendumContext?
    @State private var isSavingAddendum = false
    @State private var addendumError: String?
    @State private var clinicalSearchIndex = ClinicalSearchIndex()
    @State private var clinicalSearchQuery = ""
    @State private var clinicalSearchFilter = ClinicalSearchFilter.all
    @State private var isExportingClinical = false
    @State private var backupActivityMessage: String?
    @State private var backupHistory: VaultBackupHistoryEntry?
    @State private var administrativeUndo: AdministrativeUndo?
    @State private var undoError: String?
    @State private var isUndoing = false

    init() {}

    #if DEBUG
    /// Injects a synthetic vault for hosting tests without restoring personal bookmarks.
    init(previewVault: VaultSummary, previewPatientID: String?, previewExpandedPatientID: String? = nil, previewAssistantFilter: AssistantPatientFilter? = nil) {
        _googleMeetController = StateObject(wrappedValue: GoogleMeetIntegrationController(
            service: GoogleMeetService(credentials: GoogleMeetCredentialAccess(
                read: { _ in nil }, save: { _, _ in }, delete: { _ in }
            ))
        ))
        _summary = State(initialValue: previewVault)
        _authorizationURL = State(initialValue: previewVault.url)
        _selection = State(initialValue: previewExpandedPatientID != nil ? .patients : previewPatientID.map(AppSelection.patient) ?? .home)
        _expandedPatientID = State(initialValue: previewExpandedPatientID ?? previewPatientID)
        if let filter = previewAssistantFilter {
            _assistantPatientFilter = State(initialValue: filter)
            _patientSearch = State(initialValue: filter.query)
            _expandedPatientID = State(initialValue: filter.expandedPatientID)
            _selection = State(initialValue: filter.expandedPatientID.map(AppSelection.patient) ?? .patients)
        }
        _didAttemptVaultRestore = State(initialValue: true)
    }
    init(previewVault: VaultSummary, previewEncounterPatientID: String, previewEncounterID: String) {
        self.init(previewVault: previewVault, previewPatientID: nil)
        _selection = State(initialValue: .encounter(patientID: previewEncounterPatientID, encounterID: previewEncounterID))
        if let encounter = previewVault.patients.first(where: { $0.patientID == previewEncounterPatientID })?
            .encounters.first(where: { $0.metadata.encounterID == previewEncounterID }) {
            _draftText = State(initialValue: encounter.draft.body)
            _lastSavedAt = State(initialValue: encounter.draft.metadata.updatedAt)
        }
    }
    init(previewVault: VaultSummary, previewEncounterPatientID: String, previewEncounterID: String,
         previewTranscriptionSession: EncounterTranscriptionSession, previewDocuments: Bool = false) {
        self.init(previewVault: previewVault, previewEncounterPatientID: previewEncounterPatientID,
                  previewEncounterID: previewEncounterID)
        _transcriptionSession = StateObject(wrappedValue: previewTranscriptionSession)
        _showsEncounterDocuments = State(initialValue: previewDocuments)
    }
    #endif

    private var shellView: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 820, minHeight: 560)
        .background {
            MouseHistoryNavigation(
                canGoBack: !backHistory.isEmpty,
                canGoForward: !forwardHistory.isEmpty,
                onBack: requestBack,
                onForward: requestForward
            )
            .frame(width: 0, height: 0)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let pending = administrativeUndo, pending.vaultURL == summary?.url,
                   pending.vaultID == summary?.manifest.vaultID {
                    VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(pending.message)
                        Spacer()
                        Button("Desfazer") { undoAdministrativeAction(pending) }
                            .disabled(isUndoing || isSavingDraft || isFinalizing)
                        Button { administrativeUndo = nil; undoError = nil } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dispensar opção de desfazer")
                        .disabled(isUndoing)
                    }
                    if let undoError { Text(undoError).foregroundStyle(.red).textSelection(.enabled) }
                }
                    .padding(12)
                    .background(.bar)
                }

            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if !progressiveWorkMatchesSelectedEncounter && transcriptionSession.isBusy {
                    ConsultationRecordingFooter(session: transcriptionSession, onReturn: returnToRecordingEncounter)
                }
            Text("Alfa 0.1.0 · somente dados sintéticos · uso clínico não liberado")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(6)
                .background(.bar)
            }
        }
        .disabled(isExportingClinical || backupActivityMessage != nil || isImportingDocuments)
        .overlay {
            if isImportingDocuments {
                ProgressView("Importando documentos para o destino escolhido…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else if isExportingClinical {
                ProgressView("Exportando o conteúdo verificado…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else if let backupActivityMessage {
                ProgressView(backupActivityMessage)
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .background(AssistantWindowAnchor(controller: assistant).frame(width: 0, height: 0))
        .focusedSceneValue(\.openPEPAssistant, showAssistant)
        .onChange(of: assistantTextEnabled) { assistant.close(restoreFocus: false) }
        .onChange(of: assistantVoiceEnabled) { assistant.close(restoreFocus: false) }
        .onChange(of: transcriptionSession.isRecording) { _, recording in
            if recording { AssistantVoiceSession.suspendForClinicalCapture() }
        }
        .onChange(of: transcriptionSession.isStartingRecording) { _, starting in
            if starting { AssistantVoiceSession.suspendForClinicalCapture() }
        }
        .onChange(of: assistantEnabled) { assistant.close(restoreFocus: false) }
        .onChange(of: assistantModel) { assistant.close(restoreFocus: false) }
        .preferredColorScheme(appearancePreference.colorScheme)
        .focusedSceneValue(\.openPEPSettings) {
            requestNavigation(to: .settings)
        }
        .onChange(of: summary, initial: true) { oldSummary, newSummary in
            if oldSummary?.url != newSummary?.url || oldSummary?.manifest.vaultID != newSummary?.manifest.vaultID {
                assistant.close(restoreFocus: false)
                assistantPatientFilter = nil
                transcriptionSession.shutdown()
                patientImportReceipts = [:]
                clinicalSearchQuery = ""
                clinicalSearchFilter = .all
            }
            if pendingDocumentPreparation?.vaultURL != newSummary?.url ||
                pendingDocumentPreparation?.vaultID != newSummary?.manifest.vaultID {
                pendingDocumentPreparation = nil
            }
            if administrativeUndo?.vaultURL != newSummary?.url ||
                administrativeUndo?.vaultID != newSummary?.manifest.vaultID {
                administrativeUndo = nil
                undoError = nil
            }
            if oldSummary?.url != newSummary?.url || oldSummary?.manifest.vaultID != newSummary?.manifest.vaultID {
                patientWikiSheet = nil
            }
            clinicalSearchIndex = ClinicalSearchIndex(patients: newSummary?.patients ?? [])
            backupHistory = newSummary.flatMap { VaultBackupHistoryStore().entry(for: $0.manifest.vaultID) }
        }
        .onChange(of: patientSearch) { _, query in
            if let filter = assistantPatientFilter, query != filter.query { assistantPatientFilter = nil }
        }
        .onChange(of: selection) { _, newSelection in
            assistant.close(restoreFocus: false)
            loadDraft(for: newSelection)
            prepareProgressiveSessionForSelection()
        }
        .task {
            AssistantVoiceSession.observeClinical(transcriptionSession)
            restoreLastVaultIfNeeded()
        }
        .toolbar {
            ToolbarItemGroup {
                Button { showWiki(patientID: assistantContextPatientID) } label: {
                    Label("Wiki", systemImage: "book.closed")
                }
                .labelStyle(.titleAndIcon)
                .help("Wiki do paciente · ⌘⇧J")
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .disabled(summary == nil)
                Button(action: showAssistant) {
                    Label("Assistente", systemImage: "sparkles")
                }.help("Assistente · ⌘J")
                Button(action: requestBack) {
                    Label("Voltar", systemImage: "chevron.left")
                }
                .disabled(backHistory.isEmpty)
                .help("Voltar")

                Button(action: requestForward) {
                    Label("Avançar", systemImage: "chevron.right")
                }
                .disabled(forwardHistory.isEmpty)
                .help("Avançar")

                Button(action: requestToday) {
                    Label("Hoje", systemImage: "calendar")
                }
                .disabled(summary == nil || isSavingDraft || isFinalizing)
                .help("Abrir a agenda de hoje em lista")
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.sessionDidResignActiveNotification
        )) { _ in
            assistant.close(restoreFocus: false)
            authenticationSession.clear()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.willSleepNotification
        )) { _ in
            assistant.close(restoreFocus: false)
            authenticationSession.clear()
        }
        .quickLookPreview($previewURL)
        .onChange(of: previewURL) { _, newValue in
            if newValue == nil {
                releasePreviewAccess()
            }
        }
        .onDisappear {
            assistant.close(restoreFocus: false)
            releasePreviewAccess()
            transcriptionSession.shutdown()
        }
        .sheet(isPresented: $showsClinicalAlerts) {
            if let patient = selectedPatient, let record = patient.record {
                PatientFormView(title: "Alergias e alertas", record: record,
                    onCancel: { showsClinicalAlerts = false },
                    onSave: { input in
                        guard let vault = summary, let authorizationURL, vault.writingAllowed else { return }
                        withSecurityScopedAccess(to: authorizationURL) {
                            _ = try PatientEditor().update(patient: patient, input: input)
                            self.summary = try VaultReader().open(vault.url)
                            showsClinicalAlerts = false
                        }
                    }, duplicateNames: { _ in [] }, clinicalAlertsOnly: true)
            }
        }
    }

    private var transcriptionStartPresentation: some View {
        shellView
        .sheet(isPresented: $showsQuickSetup) { FirstRunSetupView(onFinish: { showsQuickSetup = false }, onCancel: { showsQuickSetup = false }).frame(width: 680, height: 650) }
        .alert("Não foi possível iniciar a transcrição", isPresented: Binding(
            get: { transcriptionStartIssue != nil },
            set: { if !$0 { transcriptionStartIssue = nil } }
        )) {
            Button("Abrir configurações") {
                transcriptionStartIssue = nil
                requestNavigation(to: .settings)
            }
            Button("OK", role: .cancel) { transcriptionStartIssue = nil }
        } message: {
            Text(transcriptionStartIssue ?? "")
        }
    }

    private var patientAndAgendaPresentation: some View {
        transcriptionStartPresentation
        .sheet(item: $patientFormMode, onDismiss: { newlyCreatedPatient = pendingCreatedPatient; pendingCreatedPatient = nil }) { mode in
            PatientFormView(
                title: mode == .create ? "Novo paciente" : "Editar dados do paciente",
                record: record(for: mode),
                onCancel: {
                    patientFormMode = nil
                    patientActionAfterCreation = nil
                },
                onSave: { savePatient($0, mode: mode) },
                duplicateNames: { duplicateNames(for: $0, mode: mode) }
            )
        }
        .sheet(item: $newlyCreatedPatient, onDismiss: {
            let action = deferredCreatedPatientAction
            deferredCreatedPatientAction = nil
            action?()
        }) { context in
            let patient = context.patient
            NewPatientActionsView(patientName: patient.displayName,
                onStart: {
                    deferredCreatedPatientAction = { performHomePatientAction(.startEncounter, patient: patient) }
                    newlyCreatedPatient = nil
                }, onSchedule: {
                    deferredCreatedPatientAction = {
                        newAppointmentPatientID = patient.patientID
                        appointmentFormMode = .create(defaultAppointmentStart)
                    }
                    newlyCreatedPatient = nil
                }, onDocuments: {
                    deferredCreatedPatientAction = { performHomePatientAction(.issueDocument, patient: patient) }
                    newlyCreatedPatient = nil
                }, onClose: { newlyCreatedPatient = nil })
        }
        .sheet(item: $homePatientAction, onDismiss: {
            let action = deferredHomePatientAction
            deferredHomePatientAction = nil
            action?()
        }) { action in
            HomePatientSelectionView(
                action: action,
                patients: activeRegisteredPatients,
                patientLabel: patientNameAndAge,
                canCreatePatient: summary?.writingAllowed == true,
                onSelect: { patient in
                    deferredHomePatientAction = {
                        performHomePatientAction(action, patient: patient)
                    }
                    homePatientAction = nil
                },
                onCreatePatient: {
                    patientActionAfterCreation = action
                    deferredHomePatientAction = { patientFormMode = .create }
                    homePatientAction = nil
                },
                onCancel: { homePatientAction = nil }
            )
        }
        .sheet(item: $appointmentActions, onDismiss: {
            let action = deferredAppointmentAction
            deferredAppointmentAction = nil
            action?()
        }) { selected in
            appointmentActionsSheet(selected)
        }
        .sheet(item: $appointmentFormMode, onDismiss: {
            pendingInvitation = nil
            savedAppointmentInForm = nil
            newAppointmentPatientID = nil
        }) { [newAppointmentPatientID] mode in
            let editorMode = savedAppointmentInForm.map { AppointmentFormMode.edit($0.id) } ?? mode
            VStack(alignment: .leading, spacing: 0) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).padding().fixedSize(horizontal: false, vertical: true)
            }
            if let context = pendingInvitation {
                VStack(alignment: .leading, spacing: 0) {
                    Label("Agendamento salvo. Cancelar o envio não o exclui.", systemImage: "checkmark.circle")
                        .font(.headline).padding()
                    if pendingInvitationUsesEmail {
                        EmailInvitationView(patient: context.patient, message: context.invitation ?? "",
                            onCancel: { pendingInvitation = nil },
                            onCompose: { contactID, recipient in
                                composeEmailInvitation(context, contactID: contactID, recipient: recipient)
                            }, cancelLabel: "Voltar ao agendamento")
                    } else {
                        WhatsAppShareView(patient: context.patient, link: context.appointment.record.remoteAccessURL,
                            invitation: context.invitation,
                            onCancel: { pendingInvitation = nil },
                            onConfirm: { contactID, destination, proposal in
                                shareRemoteLink(context, contactID: contactID, destination: destination, proposal: proposal)
                            })
                    }
                }
            } else {
            AppointmentFormView(
                title: editorMode.isCreate ? "Novo agendamento" : "Editar agendamento salvo",
                patients: activeRegisteredPatients,
                appointment: savedAppointmentInForm ?? appointment(for: editorMode),
                defaultDate: appointmentStart(for: editorMode),
                initialPatientID: editorMode.isCreate ? newAppointmentPatientID : nil,
                googleMeetController: googleMeetController,
                onCancel: { appointmentFormMode = nil },
                onCancelAppointment: editorMode.appointmentID.flatMap { appointmentID -> (() -> Void)? in
                    guard let appointment = savedAppointmentInForm ?? appointment(for: editorMode),
                          canCancelAppointment(appointment) else { return nil }
                    return {
                        appointmentFormMode = nil
                        cancelAppointment(appointmentID)
                    }
                },
                onSave: { saveAppointment($0, mode: editorMode) },
                onSaveAndShare: { input, email in saveAppointment(input, mode: editorMode, shareByEmail: email) },
                onOpenConsultation: openConsultationAction(for: savedAppointmentInForm ?? appointment(for: editorMode)),
                conflicts: { conflictLabels(for: $0, mode: editorMode) },
                onCreatePatient: createPatientForAppointment,
                duplicatePatientNames: { duplicateNames(for: $0, mode: .create) },
                onImportDocuments: importDocumentsForAppointment
            )
            .id(editorMode.id)
            }
            }
        }
        .sheet(item: $faceTimeHandoffContext) { context in
            FaceTimeHandoffView(
                patientName: context.patientName,
                contacts: context.contacts,
                onCancel: { faceTimeHandoffContext = nil },
                onConfirm: { contact in
                    requestFaceTime(
                        appointmentID: context.appointmentID,
                        contact: contact
                    )
                }
            )
        }
        .sheet(isPresented: $showsTranscriptionPreparation) {
            TranscriptionPreparationView(onClose: { showsTranscriptionPreparation = false })
        }
        .sheet(isPresented: $showsTeleconsultAudioProbe) {
            TeleconsultAudioProbeView(onClose: { showsTeleconsultAudioProbe = false })
        }
        .sheet(item: $preparedConsultationDocument) { context in
            PreparedDocumentView(document: context.document, isArchived: true,
                onClose: { preparedConsultationDocument = nil })
        }
        .sheet(isPresented: Binding(get: { standaloneDocumentPatient != nil }, set: { if !$0 { standaloneDocumentPatient = nil; standaloneDocumentInitialBody = "" } })) {
            if let patient = standaloneDocumentPatient, let vaultURL = standaloneDocumentVault,
               let vaultID = standaloneDocumentVaultID {
                StandaloneDocumentView(patientName: patient.record?.fullName ?? patient.displayName, patient: patient,
                    initialBodyText: standaloneDocumentInitialBody,
                    initialDocumentSection: standaloneDocumentInitialBody.isEmpty ? .guidance : .custom,
                    onArchive: { document in
                        try archivePreparedDocument(document, patientID: patient.patientID, encounterID: nil,
                            expectedVault: vaultURL, expectedVaultID: vaultID, expectedPatientRecord: patient.record)
                    }, onClose: { standaloneDocumentPatient = nil; standaloneDocumentInitialBody = "" },
                    vaultAuthorizationURL: authorizationURL)
            }
        }
        .sheet(item: $searchEncounterPreview, onDismiss: {
            if let context = pendingSearchAddendum {
                pendingSearchAddendum = nil
                addendumError = nil
                addendumContext = context
            }
            if let destination = pendingSearchResume {
                pendingSearchResume = nil
                requestNavigation(to: destination)
            }
        }) { preview in
            SearchEncounterPreviewView(preview: preview, canWrite: summary?.writingAllowed == true,
                onClose: { searchEncounterPreview = nil },
                onAddendum: {
                    pendingSearchAddendum = AddendumContext(patientID: preview.patientID, encounterID: preview.id)
                    searchEncounterPreview = nil
                }, onResume: {
                    pendingSearchResume = .encounter(patientID: preview.patientID, encounterID: preview.id)
                    searchEncounterPreview = nil
                })
        }
        .sheet(item: $patientWikiSheet) { context in
            if let summary, let authorizationURL, summary.manifest.vaultID == context.vaultID {
                PatientWikiBrowser(vault: summary, authorizationURL: authorizationURL,
                    initialPatientID: context.patientID, onClose: { patientWikiSheet = nil })
            } else {
                EmptyView()
            }
        }
        .sheet(item: $patientHistoryContext) { context in
            VStack(spacing: 0) {
                if transcriptionSession.isBusy, let binding = transcriptionSession.binding {
                    HStack {
                        Label(binding.patientName + " · " + transcriptionSession.status, systemImage: "mic.fill")
                            .font(.callout)
                        Spacer()
                        if transcriptionSession.isRecording {
                            Button("Parar gravação") { transcriptionSession.stop() }
                        }
                    }.padding(10).background(.bar)
                }
                PatientHistoryView(context: context, onOpen: { entry in
                    patientHistoryContext = nil
                    openPatientHistoryEntry(entry, context: context)
                }, onClose: { patientHistoryContext = nil }, onAccept: { answer, text in
                    try acceptPatientAIAnswer(answer, text: text, context: context)
                }, onExportEncounter: { encounterID in
                    patientHistoryContext = nil
                    exportHistoryEncounter(encounterID, context: context)
                })
            }
        }
        .sheet(isPresented: $showsEncounterTranscription) {
            EncounterTranscriptionView(session: transcriptionSession,
                onClose: { showsEncounterTranscription = false })
        }
        .sheet(item: $consultationSummaryContext) { context in
            VStack(spacing: 0) {
                HStack {
                    Text("Consulta de \(context.patient.displayName)").font(.headline)
                    Spacer()
                    Button("Fechar") { consultationSummaryContext = nil }
                        .keyboardShortcut(.cancelAction)
                }.padding()
                Divider()
                ConsultationSummaryView { proposal in
                    try insertConsultationSummary(proposal, context: context)
                }
            }
            .frame(minWidth: 640, idealWidth: 840, minHeight: 640)
        }
        .sheet(item: $whatsAppShareContext) { context in
            WhatsAppShareView(
                patient: context.patient, link: context.appointment.record.remoteAccessURL,
                invitation: context.invitation,
                onCancel: { whatsAppShareContext = nil },
                onConfirm: { contactID, destination, proposal in
                    shareRemoteLink(context, contactID: contactID, destination: destination, proposal: proposal)
                }
            )
        }
        .sheet(item: $emailShareContext) { context in
            EmailInvitationView(
                patient: context.patient, message: context.invitation ?? "",
                onCancel: { emailShareContext = nil },
                onCompose: { contactID, recipient in
                    composeEmailInvitation(context, contactID: contactID, recipient: recipient)
                }
            )
        }
    }

    private var encounterPresentation: some View {
        patientAndAgendaPresentation
        .sheet(item: $encounterDetailsContext) { context in
            EncounterDetailsView(
                patientName: context.patient.displayName,
                encounter: context.encounter.metadata,
                onCancel: { encounterDetailsContext = nil },
                onSave: { input in try saveEncounterDetails(input, context: context) }
            )
        }
        .sheet(item: $remoteLinkContext, onDismiss: completeRemoteLinkAction) { context in
            EncounterRemoteLinkView(patientName: context.patient.displayName,
                initialLink: context.appointment?.record.remoteAccessURL ?? context.encounter.metadata.remoteAccessURL,
                appointmentLabel: context.appointment.map { "Agendada · " +  $0.record.startDate.formatted(date: .abbreviated, time: .shortened) },
                preparationIssue: context.appointment?.record.modality == .inPerson
                    ? "Este agendamento é presencial. O vínculo da agenda preserva essa modalidade." : nil,
                controller: googleMeetController, onCancel: { remoteLinkContext = nil },
                onSave: { try saveEncounterRemoteLink($0, context: context) },
                onPerform: { link, action in try performRemoteLinkAction(link, action: action, context: context) })
                .interactiveDismissDisabled(googleMeetController.state == .creating)
        }
        .sheet(item: $encounterWhatsAppContext) { context in
            WhatsAppShareView(patient: context.patient, link: context.link,
                onCancel: { encounterWhatsAppContext = nil },
                onConfirm: { contactID, destination, proposal in
                    shareEncounterWhatsApp(context, contactID: contactID, destination: destination, proposal: proposal)
                })
        }
        .sheet(item: $encounterEmailContext) { context in
            EmailInvitationView(patient: context.patient, message: "Olá, segue o link para nossa consulta: \(context.link)",
                onCancel: { encounterEmailContext = nil },
                onCompose: { contactID, recipient in composeEncounterEmail(context, contactID: contactID, recipient: recipient) })
        }
        .sheet(isPresented: $showsDraftTrash) {
            DraftTrashView(patients: summary?.patients ?? [], onClose: { showsDraftTrash = false }, onRestore: restoreDraft)
        }
        .alert("Excluir rascunho?", isPresented: $confirmsDraftDeletion) {
            Button("Cancelar", role: .cancel) {}
            Button("Excluir rascunho", role: .destructive, action: discardSelectedDraft)
        } message: {
            Text("O rascunho de \(selectedPatient?.displayName ?? "este paciente") será enviado à Lixeira se tiver conteúdo.")
        }
        .confirmationDialog("Retirar os fatos de telemedicina?", isPresented: Binding(get: { pendingModalityContext != nil }, set: { if !$0 { pendingModalityContext = nil } }), titleVisibility: .visible) {
            Button("Mudar para presencial", role: .destructive) {
                guard let context = pendingModalityContext else { return }
                pendingModalityContext = nil
                do { try saveEncounterDetails(detailsInput(context.encounter.metadata, modality: .inPerson), context: context) }
                catch { errorMessage = error.localizedDescription }
            }
            Button("Cancelar", role: .cancel) { pendingModalityContext = nil }
        } message: {
            Text("O consentimento e os demais fatos registrados serão retirados. O texto da consulta e o link salvo serão conservados.")
        }
    }

    var body: some View {
        encounterPresentation
        .sheet(item: $documentImportContext) { context in
            DocumentImportView(
                context: context,
                errorMessage: documentImportError,
                isImporting: isImportingDocuments,
                onCancel: {
                    documentImportContext = nil
                    documentImportError = nil
                },
                onImport: { encounterID in
                    importDocuments(context: context, encounterID: encounterID)
                }
            )
        }
        .sheet(item: $addendumContext) { context in
            if let patient = summary?.patients.first(where: { $0.patientID == context.patientID }) {
                AddendumView(
                    patientName: patient.displayName,
                    isSaving: isSavingAddendum,
                    errorMessage: addendumError,
                    requiresAuthentication: !authenticationSession.isActive(),
                    authenticationMessage: authenticationSessionMessage,
                    onCancel: {
                        addendumContext = nil
                        addendumError = nil
                    },
                    onSave: { reason, body in
                        createAddendum(context: context, reason: reason, body: body)
                    }
                )
            }
        }
        .confirmationDialog(
            "Arquivar paciente?",
            isPresented: $confirmsArchive,
            titleVisibility: .visible
        ) {
            Button("Arquivar", role: .destructive) {
                if let patientID = patientPendingArchive {
                    setPatientStatus(patientID, status: .archived)
                }
                patientPendingArchive = nil
            }
            Button("Cancelar", role: .cancel) { patientPendingArchive = nil }
        } message: {
            Text("O cadastro sairá da lista principal. Nenhum arquivo do paciente será removido.")
        }
        .confirmationDialog(
            "Cancelar agendamento?",
            isPresented: $confirmsAppointmentCancellation,
            titleVisibility: .visible
        ) {
            Button("Cancelar agendamento", role: .destructive) {
                if let appointmentID = appointmentPendingCancellation {
                    cancelAppointment(appointmentID)
                }
                appointmentPendingCancellation = nil
            }
            Button("Manter agendamento", role: .cancel) {
                appointmentPendingCancellation = nil
            }
        } message: {
            Text("O agendamento será preservado com o estado Cancelado.")
        }
        .confirmationDialog(
            "Recarregar a versão salva?",
            isPresented: $confirmsDraftReload,
            titleVisibility: .visible
        ) {
            Button("Recarregar a versão salva", role: .destructive, action: reloadDraftFromVault)
            Button("Continuar editando", role: .cancel) {}
        } message: {
            Text("As alterações ainda não salvas no editor serão descartadas.")
        }
        .confirmationDialog(
            "Finalizar esta consulta?",
            isPresented: $confirmsFinalization,
            titleVisibility: .visible
        ) {
            Button(
                authenticationSession.isActive() ? "Finalizar consulta" : "Autenticar e finalizar",
                role: .destructive,
                action: finalizeSelectedEncounter
            )
            Button("Criar ou revisar documentos") { showsEncounterDocuments = true }
            Button("Continuar editando", role: .cancel) {}
        } message: {
            Text(documentFinalizationSummary + "\n\nUma cópia final será criada e não poderá ser editada pelo OpenPEP. Correções posteriores exigirão um adendo.")
        }

    }

    private var sidebar: some View {
        List(selection: selectionBinding) {
            Section {
                NavigationLink(value: AppSelection.home) {
                    Label("Início", systemImage: "house")
                }
                NavigationLink(value: AppSelection.agenda) {
                    Label("Agenda", systemImage: "calendar")
                }
                NavigationLink(value: AppSelection.patients) {
                    Label("Pacientes", systemImage: "person.2")
                }
                NavigationLink(value: AppSelection.search) {
                    Label("Busca", systemImage: "magnifyingglass")
                }
            }

            if let activeEncounterItem {
                Section("Em atendimento") {
                    NavigationLink(value: activeEncounterSelection(activeEncounterItem)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(
                                patientNameAndAge(activeEncounterItem.patient),
                                systemImage: "stethoscope"
                            )
                            .lineLimit(2)
                            Label(
                                activeEncounterSavePresentation.label,
                                systemImage: activeEncounterSavePresentation.systemImage
                            )
                            .font(.caption)
                            .foregroundStyle(
                                activeEncounterSavePresentation == .failed
                                    ? Color.red
                                    : Color.secondary
                            )
                        }
                    }
                    .accessibilityLabel(
                        "Em atendimento. \(patientNameAndAge(activeEncounterItem.patient)). Estado: \(activeEncounterSavePresentation.label)"
                    )
                    .accessibilityHint("Retoma o rascunho da consulta ativa")
                    .contextMenu {
                        Button("Retomar consulta") { requestNavigation(to: activeEncounterSelection(activeEncounterItem)) }
                        Button("Gravar rascunho") { activeDraftAction(activeEncounterItem, action: "save") }
                            .disabled(draftActionsBlocked)
                        Button("Finalizar consulta…") { activeDraftAction(activeEncounterItem, action: "finalize") }
                            .disabled(draftActionsBlocked)
                        Menu("Enviar mensagem") {
                            ForEach(activeEncounterItem.patient.record?.contacts ?? []) { contact in
                                Button(contact.value) { openPatientContact(activeEncounterItem.patient, contact: contact) }
                            }
                        }
                        Button("Ver histórico") { openPatientHistory(activeEncounterItem.patient) }
                        Divider()
                        Button("Excluir rascunho…", role: .destructive) { activeDraftAction(activeEncounterItem, action: "delete") }
                            .disabled(draftActionsBlocked)
                    }
                }
            }

        }
        .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 8) {
                    Image("OpenPEPMark").resizable().scaledToFit().frame(width: 28, height: 28)
                        .opacity(0.5).accessibilityHidden(true)
                    Text("OpenPEP v0.1").font(.caption)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 12)
        }
        .navigationTitle("OpenPEP")
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                Button {
                    requestNavigation(to: .settings)
                } label: {
                    Label("Configurações", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(isSettingsSelection ? Color.accentColor.opacity(0.18) : Color.clear)
                .accessibilityHint("Abre as configurações do OpenPEP")

            }
            .padding(.bottom, 28)
            .background(.bar)
        }
    }

    private var isSettingsSelection: Bool {
        switch selection {
        case .settings, .settingsTopic: true
        default: false
        }
    }

    @ViewBuilder
    private var detail: some View {
        if summary == nil && !isSettingsSelection {
            welcomeView
        } else {
            switch selection ?? .home {
        case .home:
            HomeView(
                searchText: $clinicalSearchQuery,
                canWrite: summary?.writingAllowed == true,
                onStartEncounter: { homePatientAction = .startEncounter },
                onOpenAgenda: { requestNavigation(to: .agenda) },
                onIssueDocument: { homePatientAction = .issueDocument },
                onSearch: requestHomeSearch
            )
        case .agenda:
            agendaView
        case .patients:
            patientsView
        case .search:
            ClinicalSearchView(
                index: clinicalSearchIndex,
                unavailableCount: unavailableSearchCount,
                errorMessage: errorMessage,
                noticeMessage: noticeMessage,
                onRebuild: rebuildClinicalSearch,
                onOpen: openClinicalSearchResult,
                query: $clinicalSearchQuery,
                filter: $clinicalSearchFilter
            )
            .id(summary?.manifest.vaultID)
        case .settings:
            settingsView
        case let .settingsTopic(topic):
            settingsTopicView(topic)
        case .patient:
            patientsView
        case let .encounter(patientID, encounterID):
            if let patient = summary?.patients.first(where: { $0.patientID == patientID }),
               let encounter = patient.encounters.first(where: {
                   $0.metadata.encounterID == encounterID
               }) {
                encounterView(patient: patient, encounter: encounter)
            } else {
                emptyPatientView
            }
        }
        }
    }

    private var patientsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Spacer()
                    if summary?.writingAllowed == true {
                        Button(action: createPatient) {
                            Label("Novo paciente", systemImage: "person.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                HStack {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                        TextField("Buscar pacientes", text: $patientSearch).searchClearButton($patientSearch)
                            .textFieldStyle(.plain)
                            .font(.title3)
                            .accessibilityLabel("Buscar pacientes")
                            .help("Buscar por nome, identificador ou contexto")
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 50)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.7), lineWidth: 1))
                    .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
                    Toggle("Mostrar arquivados", isOn: $showsArchivedPatients)
                        .toggleStyle(.checkbox)
                        .fixedSize()
                }

                if let filter = assistantPatientFilter, patientSearch == filter.query {
                    HStack {
                        Text(filter.opensHistory ? "Escolha o paciente para ver o histórico" : (filter.approximate ? "Nomes parecidos · escolha o paciente" : "Resultados do assistente"))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Limpar busca") { assistantPatientFilter = nil; patientSearch = "" }
                            .buttonStyle(.link)
                    }
                }

                if filteredPatients.isEmpty {
                    ContentUnavailableView {
                        Label(
                            patientSearch.isEmpty ? "Nenhum paciente cadastrado" : "Nenhum resultado",
                            systemImage: patientSearch.isEmpty ? "person.crop.circle.badge.plus" : "magnifyingglass"
                        )
                    } description: {
                        Text(patientSearch.isEmpty ? "Crie o primeiro cadastro quando quiser." : "Tente outro termo de busca.")
                    } actions: {
                        if summary?.writingAllowed == true {
                            Button("Novo paciente", action: createPatient)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    VStack(spacing: 10) {
                        ForEach(filteredPatients, id: \.patientID) { patient in
                            patientListRow(patient)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { patientListWidth = $0 }
                }

                if let unavailable = summary?.unavailablePatients, !unavailable.isEmpty {
                    GroupBox("Cadastros que precisam de revisão") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(unavailable, id: \.relativePath) { patient in
                                Label(
                                    "\(patient.patientID ?? "Entrada indisponível") · \(patient.rule)",
                                    systemImage: "exclamationmark.triangle"
                                )
                                .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                }

                messages
            }
            .padding(24)
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Pacientes")
    }

    private func patientListRow(_ patient: PatientSummary) -> some View {
        let profile = summary?.demoCatalog?.profile(for: patient.patientID)
        let isExpanded = expandedPatientID == patient.patientID
        let toggleExpansion = {
            withAnimation(.easeInOut(duration: 0.18)) {
                expandedPatientID = isExpanded ? nil : patient.patientID
            }
        }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 18) {
                Button(action: toggleExpansion) {
                    VStack(alignment: .leading, spacing: 8) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) { patientRowHeading(patient) }
                            VStack(alignment: .leading, spacing: 5) { patientRowHeading(patient) }
                        }
                        PatientWikiExcerptView(
                            patient: patient,
                            authorizationURL: authorizationURL,
                            fallback: profile?.summary
                        )
                        if patient.isArchived {
                            Text("Arquivado").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(patientAccessibilityLabel(patient, profile: profile))
                .accessibilityValue(isExpanded ? "Expandido" : "Recolhido")
                .accessibilityHint(isExpanded ? "Recolhe os dados e ações" : "Expande os dados e ações sem iniciar atendimento")
                if let filter = assistantPatientFilter, filter.opensHistory,
                   patientSearch == filter.query, filter.includes(patient) {
                    Button("Ver histórico") { openPatientHistory(patient, fromAssistant: true) }
                        .buttonStyle(.bordered)
                }
                Button(action: toggleExpansion) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Recolher paciente" : "Expandir paciente")
            }
            .padding(16)

            if isExpanded {
                Divider().padding(.horizontal, 16)
                Group {
                    if patientListWidth >= 900 {
                        HStack(alignment: .top, spacing: 24) {
                            patientDemographics(patient)
                                .frame(width: 310, alignment: .leading)
                            patientExpandedActions(patient)
                                .frame(minWidth: 480)
                                .padding(.leading, 24)
                                .overlay(alignment: .leading) { Rectangle().fill(.separator).frame(width: 1) }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 20) {
                            patientDemographics(patient)
                            Divider()
                            patientExpandedActions(patient)
                        }
                    }
                }
                .padding(16)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.3)))
        .shadow(color: .black.opacity(isExpanded ? 0.07 : 0.04), radius: 9, y: 3)
        .modifier(patientFileDrop(for: patient))
    }

    private func patientFileDrop(for patient: PatientSummary, encounterID: String? = nil) -> PatientFileDropModifier {
        let vaultURL = summary?.url
        let vaultID = summary?.manifest.vaultID
        return PatientFileDropModifier(
            isEnabled: summary?.writingAllowed == true && !patient.isArchived && !isImportingDocuments,
            patientName: patient.displayName,
            onFiles: { urls in
                guard summary?.url == vaultURL, summary?.manifest.vaultID == vaultID else {
                    errorMessage = "O prontuário mudou. Solte os arquivos novamente no paciente desejado."
                    return
                }
                _ = prepareDocumentImport(urls: urls, for: patient, preferredEncounterID: encounterID)
            })
    }

    @ViewBuilder
    private func patientRowHeading(_ patient: PatientSummary) -> some View {
        Text(patient.displayName).font(.title3.weight(.semibold))
        if let age = patient.age() {
            Text(PatientAge.label(for: age)).font(.callout).foregroundStyle(.secondary)
        }
        if let passage = patientLastPassage(patient) {
            Text("Último atendimento: \(passage)").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func patientDemographics(_ patient: PatientSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Dados do paciente").font(.headline)
                if summary?.writingAllowed == true, patient.record != nil {
                    Button { patientFormMode = .edit(patient.patientID) } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Editar cadastro")
                    .accessibilityLabel("Editar cadastro")
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
                GridRow {
                    Text("CPF").foregroundStyle(.secondary)
                    Text(patient.record?.identifiers.first(where: { $0.type == .cpf })?.value ?? "Não informado")
                }
                GridRow {
                    Text("Nascimento").foregroundStyle(.secondary)
                    Text(patientBirthDate(patient))
                }

            }

        }
    }

    private func patientExpandedActions(_ patient: PatientSummary) -> some View {
        return VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { patientActionButtons(patient) }
                VStack(alignment: .leading, spacing: 10) { patientActionButtons(patient) }
            }
            .buttonStyle(PatientCardActionStyle())
            .tint(.accentColor)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                ForEach(patient.record?.contacts ?? []) { contact in
                    GridRow {
                        Text(contact.type == .phone ? "Telefone" : "E-mail").foregroundStyle(.secondary)
                        Button { openPatientContact(patient, contact: contact) } label: {
                            Label(contact.value, systemImage: contact.type == .phone ? "message" : "envelope")
                                .lineLimit(1).truncationMode(.middle)
                                .help(contact.value)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .help("Abrir contato; nenhuma mensagem será enviada")
                    }
                }
                if patient.record?.contacts.isEmpty != false {
                    GridRow {
                        Text("Contato").foregroundStyle(.secondary)
                        Text("Não informado")
                    }
                }
            }
            if let receipt = patientImportReceipts[patient.patientID] {
                Label(receipt, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder
    private func patientActionButtons(_ patient: PatientSummary) -> some View {
        Button("Atender", systemImage: "stethoscope") {
            requestEncounterStart(.init(patientID: patient.patientID, appointmentID: nil))
        }.disabled(summary?.writingAllowed != true || patient.isArchived)
        Button("Wiki", systemImage: "book.closed") { showWiki(patientID: patient.patientID) }
        Button("Agendar", systemImage: "calendar.badge.plus") {
            newAppointmentPatientID = patient.patientID
            appointmentFormMode = .create(defaultAppointmentStart)
        }.disabled(summary?.writingAllowed != true || patient.isArchived)
        Button("Emitir documentos", systemImage: "doc.badge.plus") {
            standaloneDocumentVault = summary?.url
            standaloneDocumentVaultID = summary?.manifest.vaultID
            standaloneDocumentPatient = patient
        }.disabled(summary?.writingAllowed != true || patient.isArchived)
        Button { chooseDocuments(for: patient) } label: {
            Image(systemName: "doc.badge.plus")
        }
        .help("Inserir documentos")
        .accessibilityLabel("Inserir documentos em \(patient.displayName)")
        .disabled(summary?.writingAllowed != true || patient.isArchived || isImportingDocuments)
        Menu {
            Button("Importar e escolher vínculo…") { chooseDocuments(for: patient, chooseBinding: true) }
                .disabled(summary?.writingAllowed != true || patient.isArchived || isImportingDocuments)
            Button("Ver histórico", systemImage: "clock.arrow.circlepath") { openPatientHistory(patient) }
            if summary?.writingAllowed == true, !patient.isArchived {
                Button("Arquivar paciente…", role: .destructive) {
                    patientPendingArchive = patient.patientID
                    confirmsArchive = true
                }
            } else if summary?.writingAllowed == true, patient.isArchived {
                Button("Reativar paciente") {
                    setPatientStatus(patient.patientID, status: .active)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("Mais ações para \(patient.displayName)")
    }

    private var agendaView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) {
                        agendaPeriodControls
                        Spacer(minLength: 12)
                        agendaModeControls
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        agendaPeriodControls
                        agendaModeControls
                    }
                }

                if agendaUsesList {
                    HStack {
                        TextField("Buscar paciente neste período", text: $appointmentSearch).searchClearButton($appointmentSearch)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 320)
                            .accessibilityLabel("Buscar paciente na agenda")
                        if !appointmentSearch.isEmpty {
                            Button("Limpar") { appointmentSearch = "" }
                                .buttonStyle(.link)
                        }
                        Spacer()
                        Toggle("Mostrar passados", isOn: $showsPastAppointments)
                            .toggleStyle(.button)
                    }
                    agendaListView
                } else {
                    AgendaCalendarView(
                        mode: agendaViewMode,
                        selectedDate: selectedAgendaDate,
                        appointments: summary?.appointments ?? [],
                        patients: summary?.patients ?? [],
                        now: agendaNow,
                        dayStartHour: agendaDayStartHour,
                        dayEndHour: agendaDayEndHour,
                        gridMinutes: agendaGridMinutes,
                        onSelectDate: { date in
                            selectedAgendaDate = Calendar.current.startOfDay(for: date)
                            if agendaViewMode == .month {
                                agendaViewMode = .day
                            }
                        },
                        onSelectSlot: { date in
                            selectedAgendaDate = Calendar.current.startOfDay(for: date)
                            if summary?.writingAllowed == true, !activeRegisteredPatients.isEmpty {
                                appointmentFormMode = .create(date)
                            }
                        },
                        onEditAppointment: { appointmentID in
                            selectCalendarAppointment(appointmentID)
                        }
                    )
                    HStack(spacing: 16) {
                        Label("Presencial", systemImage: "person.2").foregroundStyle(.blue)
                        Label("Teleconsulta", systemImage: "video").foregroundStyle(.purple)
                        Label("Horário passado", systemImage: "clock.arrow.circlepath").foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }

                if let unavailable = summary?.unavailableAppointments, !unavailable.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(unavailable) { appointment in
                                Label(
                                    "Item indisponível · \(appointment.rule)",
                                    systemImage: "exclamationmark.triangle"
                                )
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Agendamento indisponível. \(appointment.rule)")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    } label: {
                        Text("Itens que precisam de revisão")
                    }
                }

                if activeRegisteredPatients.isEmpty {
                    Label(
                        "Cadastre um paciente ativo antes de criar um agendamento.",
                        systemImage: "person.crop.circle.badge.exclamationmark"
                    )
                    .foregroundStyle(.secondary)
                }
                messages
            }
            .padding(24)
            .frame(maxWidth: agendaUsesList ? 900 : 1400, alignment: .leading)
        }
        .navigationTitle(agendaHeading)
        .onAppear { agendaNow = Date() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { agendaNow = $0 }
    }

    private var agendaPeriodControls: some View {
        HStack(spacing: 10) {
            Text(agendaPeriodHeading)
                .font(.title3.weight(.medium))
            Button { moveAgendaPeriod(by: -1) } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("Período anterior")
            Button { moveAgendaPeriod(by: 1) } label: {
                Image(systemName: "chevron.right")
            }
            .accessibilityLabel("Próximo período")
            Button("Hoje") { selectedAgendaDate = Calendar.current.startOfDay(for: Date()) }
        }
        .buttonStyle(.bordered)
    }

    private var agendaModeControls: some View {
        HStack(spacing: 16) {
            Picker("Visualização", selection: $agendaViewMode) {
                ForEach(AgendaViewMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 230)
            if summary?.writingAllowed == true {
                Button {
                    appointmentFormMode = .create(defaultAppointmentStart)
                } label: {
                    Label("Novo agendamento", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(activeRegisteredPatients.isEmpty)
                .keyboardShortcut("n", modifiers: [.command, .option])
            }
        }
    }

    @ViewBuilder
    private var agendaListView: some View {
        if filteredAppointmentsInVisiblePeriod.isEmpty {
                    ContentUnavailableView {
                        Label(
                            appointmentSearch.isEmpty ? "Período livre" : "Nenhum resultado",
                            systemImage: appointmentSearch.isEmpty ? "calendar.badge.checkmark" : "magnifyingglass"
                        )
                    } description: {
                        Text(
                            appointmentSearch.isEmpty
                                ? (showsPastAppointments ? "Nenhum agendamento neste período." : "Nenhum agendamento futuro neste período. Use Mostrar passados para consultar os anteriores.")
                                : "Tente outro nome ou limpe a busca."
                        )
                    } actions: {
                        if summary?.writingAllowed == true, !activeRegisteredPatients.isEmpty {
                            Button("Novo agendamento") { appointmentFormMode = .create(defaultAppointmentStart) }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredAppointmentsInVisiblePeriod) { appointment in
                            appointmentRow(appointment)
                        }
                    }
                }
    }

    private func appointmentRow(_ appointment: AppointmentSummary) -> some View {
        let vaultURL = summary?.url
        let vaultID = summary?.manifest.vaultID
        let record = appointment.record
        let patient = summary?.patients.first { $0.patientID == record.patientID }
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .trailing, spacing: 3) {
                Text(record.startDate.formatted(.dateTime.hour().minute().locale(Locale(identifier: "pt_BR"))))
                    .font(.title3.monospacedDigit().weight(.semibold))
                Text("\(Int(record.endDate.timeIntervalSince(record.startDate) / 60)) min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 72, alignment: .trailing)

            Rectangle()
                .fill(AgendaCalendarModel.tint(for: record, now: agendaNow))
                .frame(width: 3)
                .clipShape(.capsule)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Button(patient.map(patientNameAndAge) ?? record.patientID) {
                        selectCalendarAppointment(appointment.id)
                    }.buttonStyle(.plain)
                        .font(.headline)
                }
                Label(
                    record.modality == .inPerson ? "Presencial" : "Teleconsulta",
                    systemImage: record.modality == .inPerson ? "person.2" : "video"
                )
                .foregroundStyle(.secondary)
                if let detail = record.modality == .inPerson ? record.location : nil {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 8) {
                Label(appointmentStatusLabel(record.status), systemImage: appointmentStatusIcon(record.status))
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    if let patient,
                       let encounter = encounterForAppointment(appointment, patient: patient) {
                        Button(record.encounterID == nil ? "Recuperar consulta" : (encounter.finalizationStatus == .draft ? "Retomar" : "Abrir consulta")) {
                            if record.encounterID == nil {
                                recoverAppointmentLink(appointment, patient: patient)
                            } else {
                                requestNavigation(to: .encounter(
                                    patientID: patient.patientID,
                                    encounterID: encounter.metadata.encounterID
                                ))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    } else if let patient,
                              summary?.writingAllowed == true,
                              supportsEncounterStart(record.status) {
                        Button("Atender") {
                            requestEncounterStart(EncounterStartContext(
                                patientID: patient.patientID,
                                appointmentID: appointment.id
                            ))
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Menu("Mais", systemImage: "ellipsis") {
                    if record.modality == .telemedicine, supportsRemoteHandoff(record.status) {
                        telemedicineActions(for: appointment, patient: patient)
                        Divider()
                    }
                    if let patient {
                        Button("Histórico", systemImage: "text.book.closed") { openPatientHistory(patient) }
                    if summary?.writingAllowed == true, !patient.isArchived {
                        Button("Novo documento…", systemImage: "doc.badge.plus") {
                            standaloneDocumentVault = summary?.url
                            standaloneDocumentVaultID = summary?.manifest.vaultID
                            standaloneDocumentPatient = patient
                        }
                    }
                        Button("Abrir paciente") {
                            requestNavigation(to: .patient(patient.patientID))
                        }
                        .buttonStyle(.link)
                    }
                    if canEditAppointment(appointment) {
                        Button("Editar") {
                            appointmentFormMode = .edit(record.appointmentID)
                        }
                        .buttonStyle(.link)
                        Button("Cancelar agendamento…", role: .destructive) {
                            appointmentPendingCancellation = record.appointmentID
                            confirmsAppointmentCancellation = true
                        }
                        .buttonStyle(.link)
                        .disabled(!canCancelAppointment(appointment))
                    }
                    }.fixedSize()
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.separator.opacity(0.6), lineWidth: 1)
        }
        .modifier(PatientFileDropModifier(
            isEnabled: patient != nil && summary?.writingAllowed == true && patient?.isArchived == false && !isImportingDocuments,
            patientName: patient?.displayName ?? record.patientID,
            onFiles: { urls in
                guard let patient, summary?.url == vaultURL, summary?.manifest.vaultID == vaultID else { return }
                _ = prepareDocumentImport(urls: urls, for: patient, preferredEncounterID: record.encounterID)
            }))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func telemedicineActions(
        for appointment: AppointmentSummary,
        patient: PatientSummary?,
        consultationOpen: Bool = false
    ) -> some View {
        let contacts = patient.map(TelemedicineContactResolver.options(for:)) ?? []
        VStack(alignment: .leading, spacing: 10) {
            if appointment.record.remoteAccessURL != nil {
                ViewThatFits(in: .horizontal) {
                    HStack { remoteLinkButtons(appointment, patient: patient, consultationOpen: consultationOpen) }
                    VStack(alignment: .leading) { remoteLinkButtons(appointment, patient: patient, consultationOpen: consultationOpen) }
                }
            } else if contacts.isEmpty {
                Label("Contato assistencial ausente", systemImage: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.secondary)
                if let patient {
                    Button("Configurar") {
                        requestNavigation(to: .patient(patient.patientID))
                    }
                    .buttonStyle(.link)
                }
            } else {
                Button {
                    faceTimeHandoffContext = FaceTimeHandoffContext(
                        appointmentID: appointment.id,
                        patientName: patient?.displayName ?? appointment.record.patientID,
                        contacts: contacts
                    )
                } label: {
                    Label("Abrir FaceTime…", systemImage: "video")
                }
                .buttonStyle(.borderedProminent)
                .disabled(summary?.writingAllowed != true)
                .accessibilityHint("Confirma o contato antes de pedir ao macOS que abra o FaceTime")
            }

            if appointment.record.remoteAccessURL == nil, summary?.writingAllowed == true {
                Menu("Adicionar link existente") {
                    Button("Colar link no agendamento…") {
                        appointmentFormMode = .edit(appointment.id)
                    }
                    Button("Como criar um link no FaceTime…") {
                        let alert = NSAlert()
                        alert.messageText = "Criar link no FaceTime"
                        alert.informativeText = "Abra o FaceTime e escolha Criar Link. Copie o link e volte ao OpenPEP: Adicionar link existente → Colar link no agendamento. Depois de salvar, use Link salvo → Compartilhar pelo WhatsApp.\n\nO link é criado pela Apple, não pelo OpenPEP. Entre na chamada no FaceTime e admita os participantes. Registre consentimento, localização e contingência ao iniciar a consulta. Esta versão é somente para ensaios sintéticos."
                        alert.addButton(withTitle: "Entendi")
                        alert.runModal()
                    }
                }
            }
        }
        .controlSize(.small)
        .font(.caption)
    }

    @ViewBuilder
    private func remoteLinkButtons(_ appointment: AppointmentSummary, patient: PatientSummary?, consultationOpen: Bool) -> some View {
        Button("Entrar na videochamada", systemImage: "video") { openSavedRemoteLink(appointment.id) }
            .buttonStyle(.borderedProminent)
            .disabled(summary?.writingAllowed != true)
        if let patient {
            Button("WhatsApp…", systemImage: "message") {
                whatsAppShareContext = WhatsAppShareContext(appointment: appointment, patient: patient, consultationOpen: consultationOpen)
            }
            Button("E-mail…", systemImage: "envelope") {
                emailShareContext = WhatsAppShareContext(appointment: appointment, patient: patient, consultationOpen: consultationOpen)
            }
        }
        Button("Copiar link", systemImage: "doc.on.doc") { copySavedRemoteLink(appointment.id) }
    }

    private var welcomeView: some View {
        Group {
            if isRestoringVault {
                ProgressView("Abrindo o último prontuário…")
                    .controlSize(.large)
            } else if !firstRunCompleted {
                FirstRunSetupView(onFinish: { firstRunCompleted = true })
            } else {
                VStack(spacing: 0) {
                    WelcomeView(onCreate: createVault, onOpen: openVault,
                        onDemo: createDemoVault,
                        onRestore: { requestBackupAction(.restore) },
                        isGeneratingDemo: isGeneratingDemo)
                    messages.padding(.horizontal, 24)
                }

            }
        }
        .navigationTitle("OpenPEP")
    }

    private var settingsView: some View {
        SettingsIndexView { topic in
            if topic == .quickSetup { showsQuickSetup = true }
            else if topic == .trash { openDraftTrash() }
            else { requestNavigation(to: .settingsTopic(topic)) }
        }
    }

    private func settingsTopicView(_ topic: SettingsTopic) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(topic.title)
                        .font(.largeTitle)
                    Text(topic.summary)
                        .foregroundStyle(.secondary)
                }

                switch topic {
                case .quickSetup:
                    FirstRunSetupView(onFinish: { requestNavigation(to: .settings) })
                case .documents:
                    DoctorProfileSettingsView()
                case .appearance:
                    appearanceSettings
                case .agenda:
                    agendaSettings
                case .videoCall:
                    GoogleMeetSettingsView(controller: googleMeetController)
                case .transcription:
                    transcriptionSettings
                case .recordings:
                    recordingSettings
                case .aiAssistance:
                    OpenAIConnectionSettingsView()
                case .storage:
                    storageSettings
                case .backup:
                    VaultBackupSettingsView(
                        hasVault: summary != nil,
                        history: backupHistory,
                        onAction: requestBackupAction
                    )
                case .trash:
                    trashSettings
                }

                messages
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .navigationTitle(topic.title)
    }

    private var appearanceSettings: some View {
        GroupBox("Tema") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Tema", selection: $appearanceRawValue) {
                    ForEach(AppearancePreference.allCases) { preference in
                        Text(preference.label).tag(preference.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                Text("Automática acompanha a aparência definida no macOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var agendaSettings: some View {
        GroupBox("Horários") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Abrir agenda em", selection: $initialAgendaMode) {
                    ForEach(AgendaViewMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .frame(maxWidth: 280, alignment: .leading)

                Picker("Duração padrão", selection: $defaultAppointmentDuration) {
                    Text("15 minutos").tag(15)
                    Text("30 minutos").tag(30)
                    Text("45 minutos").tag(45)
                    Text("60 minutos").tag(60)
                }
                .frame(maxWidth: 280, alignment: .leading)
                Text("Usada ao criar um agendamento; cada consulta pode ter uma duração diferente.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) { agendaRangePickers }
                    VStack(alignment: .leading, spacing: 10) { agendaRangePickers }
                }
                Text("A grade usa esses limites e se expande quando houver um agendamento fora deles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .onChange(of: agendaDayStartHour) { _, newValue in
            if newValue >= agendaDayEndHour {
                agendaDayEndHour = min(24, newValue + 1)
            }
        }
        .onChange(of: agendaDayEndHour) { _, newValue in
            if newValue <= agendaDayStartHour {
                agendaDayStartHour = max(0, newValue - 1)
            }
        }
    }

    @ViewBuilder
    private var agendaRangePickers: some View {
        Picker("Início do dia", selection: $agendaDayStartHour) {
            ForEach(0..<24, id: \.self) { hour in
                Text(String(format: "%02d:00", hour)).tag(hour)
            }
        }
        Picker("Fim do dia", selection: $agendaDayEndHour) {
            ForEach(1...24, id: \.self) { hour in
                Text(String(format: "%02d:00", hour)).tag(hour)
            }
        }
        Picker("Intervalo da grade", selection: $agendaGridMinutes) {
            ForEach(AppointmentDefaults.allowedGridMinutes, id: \.self) { minutes in
                Text("\(minutes) minutos").tag(minutes)
            }
        }
    }

    private var transcriptionSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Durante a consulta") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Transcrição", selection: $transcriptionModeRawValue) {
                        Text("Apple ao vivo neste Mac").tag(ConsultationTranscriptionMode.appleLive.rawValue)
                        Text("OpenAI ao vivo").tag(ConsultationTranscriptionMode.openAILive.rawValue)
                        Text("Apple após encerrar").tag(ConsultationTranscriptionMode.appleAfterRecording.rawValue)
                    }
                    .pickerStyle(.radioGroup)

                    if configuredTranscriptionMode == .openAILive {
                        Toggle("Permitir enviar áudio da consulta à OpenAI",
                               isOn: $allowsOpenAILiveTranscription)
                        LabeledContent("Modelo", value: AITextSettings.defaultLiveTranscriptionModel)
                    } else {
                        Text("A transcrição usa os recursos da Apple neste Mac; o áudio não é enviado à OpenAI.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Divider()

                    Picker("Resumo", selection: $consultationSummaryProvider) {
                        ForEach(ProgressiveSummaryProvider.allCases) { provider in
                            Text(provider.label).tag(provider.rawValue)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    if configuredSummaryProvider == .openAI {
                        Toggle("Permitir enviar texto estabilizado para resumo na OpenAI",
                               isOn: $allowsOpenAIConsultationSummary)
                        TextField("Modelo do resumo", text: $consultationSummaryModel)
                            .disabled(!allowsOpenAIConsultationSummary)
                        Picker("Atualizar resumo a cada", selection: $summaryIntervalMinutes) {
                            Text("1 minuto").tag(1)
                            Text("3 minutos").tag(3)
                            Text("4 minutos").tag(4)
                            Text("5 minutos").tag(5)
                        }
                        .frame(maxWidth: 280, alignment: .leading)
                        Text("Somente o texto estabilizado usado no bloco é enviado; caminhos locais e identificadores internos ficam fora da solicitação.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("O resumo é produzido neste Mac ao encerrar a gravação. O texto não é enviado à OpenAI.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Text("Áudio e texto são autorizações independentes. Mudar uma preferência não altera uma captura já iniciada.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            GroupBox("Ensaio com arquivo") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Teste áudio sintético importado no motor local, sem iniciar uma consulta.")
                        .font(.callout)
                    Button("Abrir laboratório de transcrição…") { showsTranscriptionPreparation = true }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
        }
    }

    private var recordingSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Captura e arquivos") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Capturar", selection: $captureSourceRawValue) {
                        Text("Somente o microfone").tag(ConsultationCaptureSourcePreference.microphone.rawValue)
                        Text("Microfone e áudio dos aplicativos").tag(ConsultationCaptureSourcePreference.telecall.rawValue)
                    }
                    Text("A captura de outros aplicativos também exige a permissão de gravação de áudio do sistema no macOS.")
                        .font(.callout).foregroundStyle(.secondary)
                    Divider()
                    LabeledContent("Pasta dos áudios") {
                        Text(summary.map { $0.url.appendingPathComponent("recordings").path } ?? "Escolha ou crie um prontuário para definir o destino.")
                            .lineLimit(3).textSelection(.enabled)
                    }
                    Text("Os áudios ficam dentro do prontuário aberto, na subpasta recordings. Arquivos de pastas usadas anteriormente permanecem onde estavam.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Cada gravação recebe um nome único. O OpenPEP nunca substitui um áudio existente.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            GroupBox("Consentimento para gravação") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Tratamento", selection: $recordingConsentModeRawValue) {
                        ForEach(ConsultationRecordingConsentMode.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    Text(recordingConsentMode.guidance)
                        .font(.caption).foregroundStyle(.secondary)
                    Text("O microfone inicia imediatamente, sem confirmação adicional. Esta preferência não registra nem comprova o consentimento dos participantes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            GroupBox("Diagnóstico") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Confira os níveis do microfone e do aplicativo da chamada separadamente. O teste não salva áudio nem executa transcrição.")
                        .font(.callout)
                    Button("Testar áudio da teleconsulta…") { showsTeleconsultAudioProbe = true }
                        .disabled(transcriptionSession.isBusy)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
        }
    }

    private var storageSettings: some View {
        GroupBox("Prontuário local") {
            VStack(alignment: .leading, spacing: 8) {
                if let summary {
                    Text("Pasta")
                        .font(.callout.weight(.medium))
                    Text(summary.url.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                    LabeledContent(
                        "Acesso",
                        value: summary.writingAllowed ? "Leitura e escrita" : "Somente leitura"
                    )
                    Text(summary.statusMessage)
                        .foregroundStyle(summary.writingAllowed ? Color.primary : Color.orange)
                    if !summary.unmanagedPaths.isEmpty {
                        LabeledContent("Não gerenciados", value: "\(summary.unmanagedPaths.count) preservado(s)")
                    }
                    if !summary.unavailablePatients.isEmpty {
                        LabeledContent("Indisponíveis", value: "\(summary.unavailablePatients.count) paciente(s)")
                    }
                    if !summary.unavailableAppointments.isEmpty {
                        LabeledContent("Agenda indisponível", value: "\(summary.unavailableAppointments.count) item(ns)")
                    }
                    DisclosureGroup("Detalhes técnicos") {
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent("Identificador", value: summary.manifest.vaultID)
                            LabeledContent("Protocolo", value: summary.manifest.protocolVersion)
                        }
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(.top, 4)
                    }
                    Divider()
                    Button("Escolher outro prontuário…", action: openVault)
                        .accessibilityHint("Abre outra pasta de prontuário local")
                } else {
                    Text("Nenhum prontuário aberto.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var trashSettings: some View {
        GroupBox("Rascunhos excluídos") {
            HStack {
                Text("Recupere rascunhos excluídos com conteúdo.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Abrir lixeira…", systemImage: "trash", action: openDraftTrash)
                    .disabled(summary == nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private func encounterView(patient: PatientSummary, encounter: EncounterSummary) -> some View {
        let profile = summary?.demoCatalog?.profile(for: patient.patientID)


        return Group {
            if showsEncounterDocuments {
                GeometryReader { geometry in
                VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Button("Voltar à consulta", systemImage: "chevron.left") { showsEncounterDocuments = false }
                        Spacer()
                        Text("Documentos").font(.title2.weight(.semibold))
                    }
                    Text(patientNameAndAge(patient)).foregroundStyle(.secondary)
                    ScrollView {
                        ConsultationFieldsEditor(
                            bodyText: $draftText, onPrepare: prepareConsultationDocument,
                            includesConsultation: false,
                            patientName: patient.record?.fullName ?? patient.displayName,
                            previousPatient: patient,
                            consultationDate: ISO8601DateFormatter().date(from: encounter.metadata.startedAt) ?? Date(),
                            onDelivered: { showsEncounterDocuments = false; confirmsFinalization = true },
                            onApprove: approveConsultationDocuments,
                            onFinish: { showsEncounterDocuments = false },
                            cockpitAuthorizationURL: authorizationURL,
                            cockpitEncounterID: encounter.metadata.encounterID,
                            onCockpitArchive: { document in
                                guard let vault = summary else { throw ConsultationFieldsError.ambiguous }
                                return try archivePreparedDocument(document, patientID: patient.patientID,
                                    encounterID: encounter.metadata.encounterID, expectedVault: vault.url,
                                    expectedVaultID: vault.manifest.vaultID, expectedPatientRecord: patient.record,
                                    expectedEncounter: encounter)
                            })
                            .disabled(summary?.writingAllowed != true || isFinalizing || encounter.finalizationStatus != .draft)
                    }
                }.padding(24)

                    if progressiveWorkMatchesSelectedEncounter {
                        ConsultationRecordingFooter(session: transcriptionSession) { showsEncounterDocuments = false }
                    }
                }.padding(.bottom, max(24, geometry.safeAreaInsets.bottom))
                }
            } else {
                GeometryReader { geometry in
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            ScrollViewReader { scroll in
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 16) {
                                        ViewThatFits(in: .horizontal) {
                                            HStack(alignment: .firstTextBaseline) {
                                                Text(patientNameAndAge(patient)).font(.title2.weight(.semibold))
                                                Spacer()
                                                Label(displayClinicalDate(encounter.metadata.startedAt), systemImage: "calendar")
                                                    .foregroundStyle(.secondary)
                                            }
                                            VStack(alignment: .leading, spacing: 6) {
                                                Text(patientNameAndAge(patient)).font(.title2.weight(.semibold))
                                                Label(displayClinicalDate(encounter.metadata.startedAt), systemImage: "calendar")
                                                    .font(.callout).foregroundStyle(.secondary)
                                            }
                                        }
                                        PatientWikiExcerptView(patient: patient, authorizationURL: authorizationURL, fallback: nil)
                                        if let record = patient.record, !record.alerts.isEmpty {
                                            Button {
                                                showsClinicalAlerts = true
                                            } label: {
                                                Label(
                                                    record.alerts.map(\.description).joined(separator: " · "),
                                                    systemImage: "exclamationmark.circle"
                                                )
                                                .font(.callout).foregroundStyle(.orange)
                                            }.buttonStyle(.plain)
                                        }
                                        if encounter.finalizationStatus != .draft {
                                            encounterStatusLabel(encounter.finalizationStatus)
                                        }
                                        if encounter.finalizationStatus == .draft {
                                            HStack {
                                                Spacer()
                                                Button { confirmsDraftDeletion = true } label: { Image(systemName: "xmark") }
                                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                                                    .help("Excluir rascunho")
                                                    .accessibilityLabel("Excluir rascunho")
                                                    .disabled(draftActionsBlocked)
                                            }
                                        }
                                        encounterDocument(encounter)
                                        messages
                                    }
                                    .padding(24)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }

                            }
                            if !progressiveWorkMatchesSelectedEncounter, encounter.finalizationStatus == .draft {
                                encounterIdleFooter
                            }
                            if progressiveWorkMatchesSelectedEncounter, encounter.finalizationStatus == .draft {
                                VStack(spacing: 0) {
                                    progressiveSummaryPanel
                                        .frame(
                                            height: transcriptionPanelCollapsed
                                                ? (geometry.size.width < 820 ? 112 : 68)
                                                : min(480, max(280, geometry.size.height * 0.52)))
                                    HStack {
                                        Spacer(); encounterFinalizationButton
                                    }
                                    .padding(.horizontal, 16).padding(.vertical, 10)
                                    .background(.bar)
                                }
                            }
                        }
                        VStack(spacing: 28) {
                            encounterRailButton("Videochamada", icon: "video", linked: encounterRemoteLink(encounter) != nil) { openConfiguredVideoCall() }
                                .disabled(isOpeningEncounterDetails || googleMeetController.state == .creating)
                            encounterRailButton("Wiki", icon: "book.closed") { showWiki(patientID: patient.patientID) }
                            encounterRailButton("Histórico", icon: "clock.arrow.circlepath") { openPatientHistory(patient) }
                            encounterRailButton("Documentos", icon: "doc") { showsEncounterDocuments = true }
                            encounterRailButton("Mais", icon: "ellipsis.circle") { showsEncounterMore = true }
                                .popover(isPresented: $showsEncounterMore) {
                                    VStack(alignment: .leading, spacing: 16) {
                                        documentImportActions(for: patient, encounterID: encounter.metadata.encounterID)
                                        Button("Alergias e alertas", systemImage: "exclamationmark.circle") {
                                            showsEncounterMore = false
                                            showsClinicalAlerts = true
                                        }.disabled(summary?.writingAllowed != true || patient.record == nil)
                                        if encounter.finalizationStatus == .draft {
                                            Button("Salvar rascunho") {
                                                Task { await saveDraft(announcingSuccess: true) }
                                            }.disabled(!hasUnsavedDraft || isSavingDraft || summary?.writingAllowed != true)
                                            Button("Resumir transcrição com Apple Intelligence…", systemImage: "sparkles") {
                                                showsEncounterMore = false
                                                openConsultationSummary()
                                            }.disabled(
                                                summary?.writingAllowed != true || isSavingDraft || isFinalizing || isOpeningConsultationSummary
                                                    || progressiveWorkMatchesSelectedEncounter
                                                    || encounter.draft.metadata.schema != "openpep/clinical-note@1")
                                        }
                                        Button("Detalhes do atendimento", systemImage: "info.circle") { showsEncounterInfo = true }
                                            .popover(isPresented: $showsEncounterInfo) {
                                                VStack(alignment: .leading, spacing: 12) {
                                                    Text("Detalhes do atendimento").font(.headline)
                                                    Text(encounterSafetyMessage(encounter.finalizationStatus))
                                                        .font(.callout).foregroundStyle(.secondary)
                                                    if let facts = encounter.metadata.telemedicine {
                                                        TelemedicineFactsView(facts: facts)
                                                        if encounter.finalizationStatus == .draft {
                                                            Button("Editar fatos…") {
                                                                showsEncounterInfo = false
                                                                openEncounterDetails()
                                                            }
                                                            .disabled(
                                                                summary?.writingAllowed != true || isSavingDraft || isFinalizing
                                                                    || isOpeningEncounterDetails || isChangingModality)
                                                        }
                                                    }
                                                    LabeledContent("Encontro", value: encounter.metadata.encounterID)
                                                        .font(.caption.monospaced()).textSelection(.enabled)
                                                }.padding(20).frame(width: 420)
                                            }
                                        if encounter.finalizationStatus == .draft {
                                            Button("Excluir rascunho", systemImage: "trash", role: .destructive, action: { confirmsDraftDeletion = true })
                                                .font(.callout)
                                                .disabled(
                                                    summary?.writingAllowed != true || isSavingDraft || isFinalizing || isOpeningEncounterDetails
                                                        || isChangingModality || transcriptionBlocksSelectedEncounter)
                                        }
                                    }.padding(20).frame(width: 360)
                                }
                            Spacer(minLength: 0)
                        }
                        .padding(.top, 100).padding(.horizontal, 8)
                        .frame(width: 96)
                        .frame(maxHeight: .infinity)
                        .background(.bar)
                        .overlay(alignment: .leading) { Rectangle().fill(.separator).frame(width: 1) }
                    }
                    .padding(.bottom, max(24, geometry.safeAreaInsets.bottom))
                }
            }
        }
        .modifier(patientFileDrop(for: patient, encounterID: encounter.metadata.encounterID))
        .navigationTitle(showsEncounterDocuments ? "Documentos" : (profile?.displayName ?? "Rascunho"))
        .task(id: draftText) {
            guard hasUnsavedDraft, summary?.writingAllowed == true else { return }
            do {
                try await Task.sleep(for: .milliseconds(700))
                // A previous background save may still be completing. Keep the
                // newest buffer scheduled instead of dropping this autosave.
                while isSavingDraft { try await Task.sleep(for: .milliseconds(100)) }
                try Task.checkCancellation()
                await saveDraft(announcingSuccess: false)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func encounterRailButton(_ title: String, icon: String, linked: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 21, weight: .regular))
                    .overlay(alignment: .bottomTrailing) {
                        if linked {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 11))
                                .foregroundStyle(Color.accentColor).background(.background, in: Circle()).offset(x: 6, y: 4)
                        }
                    }
                Text(title).font(.caption).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private func encounterStatusLabel(_ status: EncounterFinalizationStatus) -> some View {
        switch status {
        case .draft:
            Label("Rascunho", systemImage: "pencil.line")
                .font(.headline)
                .accessibilityLabel("Estado: Rascunho")
        case .verified:
            Label("Final íntegro", systemImage: "checkmark.shield")
                .font(.headline)
                .accessibilityLabel("Estado: Nota final íntegra")
        case .altered:
            Label("Alteração detectada", systemImage: "exclamationmark.shield")
                .font(.headline)
                .foregroundStyle(.red)
                .accessibilityLabel("Estado: Alteração externa detectada")
        }
    }

    private func encounterSafetyMessage(_ status: EncounterFinalizationStatus) -> String {
        switch status {
        case .draft:
            "Este rascunho ainda pode ser editado e salvo automaticamente."
        case .verified:
            "Nota final somente leitura, verificada por SHA-256. A autenticação local não equivale a assinatura ICP-Brasil."
        case .altered:
            "O OpenPEP detectou divergência nos artefatos desta consulta. Revise os arquivos antes de continuar."
        }
    }

    @ViewBuilder
    private func encounterTelemedicineActions(_ encounter: EncounterSummary, patient: PatientSummary) -> some View {
        if encounter.metadata.modality == "telemedicine" || encounterRemoteLink(encounter) != nil {
            VStack(alignment: .leading, spacing: 8) {
                if encounter.finalizationStatus == .draft {
                    Button(encounterRemoteLink(encounter) == nil ? "Gerar ou adicionar link…" : "Alterar link…",
                           systemImage: "link", action: openEncounterRemoteLink)
                        .disabled(summary?.writingAllowed != true || isSavingDraft || isFinalizing || isOpeningEncounterDetails || isChangingModality)
                }
                if let appointment = summary?.appointments.first(where: { $0.id == encounter.metadata.appointmentID }),
                   supportsRemoteHandoff(appointment.record.status) {
                    telemedicineActions(for: appointment, patient: patient, consultationOpen: true)
                } else if encounter.metadata.appointmentID == nil, let link = encounter.metadata.remoteAccessURL,
                          let vaultURL = summary?.url {
                    let context = EncounterLinkShareContext(patient: patient, encounter: encounter, vaultURL: vaultURL, link: link)
                    ViewThatFits(in: .horizontal) {
                        HStack { encounterRemoteButtons(context) }
                        VStack(alignment: .leading) { encounterRemoteButtons(context) }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                .disabled(isChangingModality)
        }
    }

    @ViewBuilder
    private func encounterDocument(_ encounter: EncounterSummary) -> some View {
        switch encounter.finalizationStatus {
        case .draft:
            draftEditor()
        case let .verified(finalization):
            finalizedNoteView(finalization)
        case let .altered(message):
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Não foi possível confirmar a integridade desta consulta.", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                        .foregroundStyle(.red)
                    Text(message)
                        .textSelection(.enabled)
                    Text("O rascunho e os demais pacientes permanecem disponíveis. Nenhum arquivo foi corrigido automaticamente.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            } label: {
                Label("Verificação necessária", systemImage: "lock.trianglebadge.exclamationmark")
            }
        }
    }

    private func finalizedNoteView(_ finalization: EncounterFinalizationSummary) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Somente leitura", systemImage: "lock.fill")
                        .font(.callout.weight(.semibold))
                    Spacer()
                }

                ClinicalFormattedText(text: finalization.finalNote.body.isEmpty ? "Nota final sem texto." : finalization.finalNote.body)
                    .font(.body)
                    .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
                    .padding(10)
                .background(.background)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                // Keep the selectable text's native accessibility label. Overriding it
                // can recurse through SwiftUI/AppKit accessibility on macOS 27.

                HStack {
                    Label(
                        "Finalizada em \(displayClinicalDate(finalization.finalNote.metadata.finalizedAt))",
                        systemImage: "calendar.badge.checkmark"
                    )
                    Spacer()
                    Button {
                        if let patient = selectedPatient, let encounter = selectedEncounter {
                            addendumError = nil
                            addendumContext = AddendumContext(
                                patientID: patient.patientID,
                                encounterID: encounter.metadata.encounterID
                            )
                        }
                    } label: {
                        Label("Criar adendo…", systemImage: "text.badge.plus")
                    }
                    .disabled(summary?.writingAllowed != true || isSavingAddendum)
                    .accessibilityHint("Cria um novo artefato sem alterar a nota final")
                }

                if !finalization.addenda.isEmpty {
                    Divider()
                    Text("Adendos")
                        .font(.headline)
                    ForEach(finalization.addenda, id: \.metadata.addendumID) { addendum in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(
                                displayClinicalDate(addendum.metadata.createdAt),
                                systemImage: "text.badge.checkmark"
                            )
                            .font(.callout.weight(.semibold))
                            Text("Motivo: \(addendum.metadata.reason)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text(addendum.body)
                                .textSelection(.enabled)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        } label: {
            Label("Nota final", systemImage: "checkmark.shield")
                .font(.headline)
        }
    }

    private var progressiveWorkMatchesSelectedEncounter: Bool {
        guard transcriptionSession.progressiveWork != nil,
              let binding = transcriptionSession.binding else { return false }
        return binding.vaultURL == summary?.url
            && binding.vaultID == summary?.manifest.vaultID
            && binding.patientID == selectedPatient?.patientID
            && binding.encounterID == selectedEncounter?.metadata.encounterID
    }

    private var progressiveSummaryPanel: some View {
        ConsultationLivePanel(
            session: transcriptionSession,
            onAccept: { block in
                do { try acceptProgressiveSummaryBlock(block) }
                catch { errorMessage = error.localizedDescription }
            },
            onUndo: { block in
                do { try undoProgressiveSummaryBlock(block) }
                catch { errorMessage = error.localizedDescription }
            },
            canUndo: { progressiveSummaryUndoTokens[$0.id] != nil },
            isCollapsed: $transcriptionPanelCollapsed,
            onResume: { openEncounterTranscription() }
        )
    }

    private var encounterIdleFooter: some View {
        ZStack {
                        HStack {
                            Spacer()
                            Button(action: openEncounterTranscription) {
                                VStack(spacing: 6) {
                                    Image(systemName: "mic.fill").font(.system(size: 28))
                                        .foregroundStyle(.white).frame(width: 56, height: 56)
                                        .background(.blue, in: Circle())
                                    Text("Transcrição").font(.caption).foregroundStyle(.blue)
                                }.padding(8).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Spacer()
                        }
                        .disabled(isSavingDraft || isFinalizing || isOpeningConsultationSummary)
                        .accessibilityHint("Inicia a transcrição diretamente com as preferências salvas")
                .disabled(summary?.writingAllowed != true)
            HStack {
                Spacer()
                encounterFinalizationButton.buttonStyle(.borderedProminent)
            }.padding(.horizontal, 20)
        }
        .frame(minHeight: 100)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func draftEditor() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                ConsultationFieldsEditor(bodyText: $draftText, onPrepare: prepareConsultationDocument,
                    patientName: selectedPatient?.record?.fullName ?? selectedPatient?.displayName ?? "", includesDocuments: false, previousPatient: selectedPatient,
                    consultationMinimumHeight: progressiveWorkMatchesSelectedEncounter && !transcriptionPanelCollapsed ? 160 : 420)
                    .id(selectedEncounter?.metadata.encounterID)
                    .disabled(summary?.writingAllowed != true || isFinalizing)

                HStack {
                    Spacer()
                    Button {
                        Task { await saveDraft(announcingSuccess: false) }
                    } label: {
                        Text(draftSaveError != nil ? "Falha ao salvar · tentar novamente" :
                             (isSavingDraft || hasUnsavedDraft ? "Salvamento automático" : "Salvo"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).keyboardShortcut("s")
                    .disabled((!hasUnsavedDraft && draftSaveError == nil) || isSavingDraft ||
                              summary?.writingAllowed != true || isFinalizing)
                }
                .frame(height: 24)

                if summary?.writingAllowed == true {
                    if transcriptionBlocksSelectedEncounter {
                        Text("Pare a gravação e guarde a transcrição antes de finalizar ou excluir esta consulta.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if selectedEncounter?.draft.metadata.schema == "openpep/clinical-note@2" {
                        Label("Resumo revisado inserido. A transcrição-fonte está no histórico; o rascunho continua editável.", systemImage: "checkmark.seal")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }

                if isFinalizing {
                    ProgressView(authenticationSession.isActive() ? "Finalizando…" : "Autenticando e finalizando…")
                        .controlSize(.small)
                }
                if let finalizationError {
                    Text("Não foi possível finalizar: \(finalizationError)")
                        .foregroundStyle(.red)
                }
                if let draftSaveError {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Não foi possível salvar: \(draftSaveError)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                        Button("Recarregar versão salva…") {
                            confirmsDraftReload = true
                        }
                    }
                    .font(.callout)
                }
                if summary?.writingAllowed != true {
                    Label(
                        "Somente leitura. O rascunho não pode ser alterado neste estado do prontuário.",
                        systemImage: "lock"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    @ViewBuilder
    private var encounterFinalizationButton: some View {
        if summary?.writingAllowed == true, selectedEncounter?.finalizationStatus == .draft {
            Button("Finalizar consulta…") {
                finalizationError = nil
                documentFinalizationSummary = documentReviewSummary()
                confirmsFinalization = true
            }
            .disabled(isSavingDraft || isFinalizing || transcriptionBlocksSelectedEncounter)
            .accessibilityHint("Salva as alterações pendentes. Exige confirmação e autenticação local; a nota final não poderá ser editada")
        }
    }

    private func encounterContextPanel(
        patient: PatientSummary,
        context: EncounterContext?
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if let context {
                    Text("Problemas acompanhados")
                        .font(.headline)
                    ForEach(context.activeProblems, id: \.self) { problem in
                        Label(problem, systemImage: "heart.text.square")
                    }

                    Divider()
                    Text("Exames recentes")
                        .font(.headline)
                    ForEach(context.exams, id: \.assetID) { exam in
                        VStack(alignment: .leading, spacing: 5) {
                            Label(
                                rawAssetKindLabel(exam.kind),
                                systemImage: rawAssetIcon(exam.kind)
                            )
                            .font(.body.weight(.medium))
                            Text(exam.originalName)
                                .font(.caption)
                            Text(displayClinicalDate(exam.importedAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button {
                                previewDocument(
                                    patientID: patient.patientID,
                                    assetID: exam.assetID
                                )
                            } label: {
                                Label("Visualizar PDF", systemImage: "eye")
                            }
                            .accessibilityHint("Abre o exame validado no Quick Look")
                        }
                        .accessibilityElement(children: .contain)
                    }

                    Divider()
                    Text("Consulta anterior")
                        .font(.headline)
                    if let previous = context.previousConsultation {
                        Label(
                            displayClinicalDate(previous.date),
                            systemImage: "clock.arrow.circlepath"
                        )
                        Text("Rascunho não finalizado")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Nenhuma consulta anterior a este atendimento.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Este prontuário não possui contexto longitudinal para o atendimento.")
                        .foregroundStyle(.secondary)
                }

                Divider()
                Text("Contexto somente leitura. Nada desta área é copiado automaticamente para o rascunho.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        } label: {
            Label("Contexto do paciente", systemImage: "sidebar.right")
                .font(.headline)
        }
    }

    private var emptyPatientView: some View {
        ContentUnavailableView(
            "Selecione um paciente",
            systemImage: "person.text.rectangle",
            description: Text("Abra o módulo Pacientes e escolha um cadastro.")
        )
    }

    @ViewBuilder
    private var messages: some View {
        if let errorMessage {
            Text("Erro: \(errorMessage)")
                .foregroundStyle(.red)
        }
        if let noticeMessage {
            HStack(alignment: .top) {
                Text(noticeMessage).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                Button("Dispensar aviso", systemImage: "xmark") { self.noticeMessage = nil }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
        }
    }

    private var selectedPatient: PatientSummary? {
        guard let selection else { return nil }
        let patientID: String
        switch selection {
        case .home, .agenda, .patients, .search, .settings, .settingsTopic: return nil
        case let .patient(identifier): patientID = identifier
        case let .encounter(identifier, _): patientID = identifier
        }
        return summary?.patients.first { $0.patientID == patientID }
    }

    private var selectedEncounter: EncounterSummary? {
        guard case let .encounter(patientID, encounterID) = selection,
              let patient = summary?.patients.first(where: { $0.patientID == patientID }) else {
            return nil
        }
        return patient.encounters.first { $0.metadata.encounterID == encounterID }
    }

    private var activeEncounterItem: EncounterListItem? {
        guard let active = encounterActivity.active,
              let patient = summary?.patients.first(where: { $0.patientID == active.patientID }),
              let encounter = patient.encounters.first(where: {
                  $0.metadata.encounterID == active.encounterID
              }),
              encounter.finalizationStatus == .draft else {
            return nil
        }
        return EncounterListItem(patient: patient, encounter: encounter)
    }

    private var activeEncounterSavePresentation: EncounterSavePresentation {
        guard let active = encounterActivity.active else { return .saved }
        let isEditingActive = selection == activeEncounterSelection(active)
        return EncounterSavePresentation.resolve(
            isSaving: isEditingActive && isSavingDraft,
            hasUnsavedChanges: isEditingActive && hasUnsavedDraft,
            errorMessage: isEditingActive ? draftSaveError : nil
        )
    }

    private func activeEncounterSelection(_ reference: ActiveEncounterReference) -> AppSelection {
        .encounter(patientID: reference.patientID, encounterID: reference.encounterID)
    }

    private func activeEncounterSelection(_ item: EncounterListItem) -> AppSelection {
        .encounter(
            patientID: item.patient.patientID,
            encounterID: item.encounter.metadata.encounterID
        )
    }

    private var selectionBinding: Binding<AppSelection?> {
        Binding(
            get: {
                switch selection {
                case .patient: .patients
                case .encounter:
                    selection == encounterActivity.active.map(activeEncounterSelection)
                        ? selection
                        : .search
                default: selection
                }
            },
            set: { requested in
                guard let requested else { return }
                requestNavigation(to: requested)
            }
        )
    }

    private var appearancePreference: AppearancePreference {
        AppearancePreference(rawValue: appearanceRawValue) ?? .system
    }

    private var configuredCaptureSource: ConsultationCaptureSourcePreference {
        ConsultationCaptureSourcePreference(rawValue: captureSourceRawValue) ?? .microphone
    }

    private var configuredTranscriptionMode: ConsultationTranscriptionMode {
        ConsultationTranscriptionMode(rawValue: transcriptionModeRawValue) ?? .appleLive
    }

    private var configuredSummaryProvider: ProgressiveSummaryProvider {
        ProgressiveSummaryProvider(rawValue: consultationSummaryProvider) ?? .openAI
    }

    private var recordingConsentMode: ConsultationRecordingConsentMode {
        ConsultationRecordingConsentMode(rawValue: recordingConsentModeRawValue) ?? .confirmVerbal
    }

    private func configuredRecordingFolder() throws -> URL {
        guard let vault = summary, vault.writingAllowed, let authorizationURL else {
            throw ConsultationCaptureSettingsIssue.recordingFolderMissing
        }
        let granted = authorizationURL.startAccessingSecurityScopedResource()
        defer { if granted { authorizationURL.stopAccessingSecurityScopedResource() } }
        return try ConsultationCaptureSettings.recordingFolder(in: vault.url)
    }

    private func loadTelecallApplications() {
        guard !isLoadingTelecallApplications, !transcriptionSession.isBusy else { return }
        isLoadingTelecallApplications = true
        telecallApplicationStatus = "Procurando aplicativos abertos…"
        Task { @MainActor in
            defer { isLoadingTelecallApplications = false }
            do {
                let applications = try await transcriptionSession.availableTelecallApplications()
                telecallApplications = applications
                telecallApplicationStatus = applications.isEmpty
                    ? "Abra o aplicativo da chamada e atualize a lista."
                    : "Escolha o aplicativo usado nas telechamadas."
            } catch {
                telecallApplications = []
                telecallApplicationStatus = error.localizedDescription
            }
        }
    }

    private var allEncounterItems: [EncounterListItem] {
        (summary?.patients ?? [])
            .flatMap { patient in
                patient.encounters.map { EncounterListItem(patient: patient, encounter: $0) }
            }
            .sorted { $0.encounter.metadata.startedAt > $1.encounter.metadata.startedAt }
    }

    private var unavailableSearchCount: Int {
        (summary?.unavailablePatients.count ?? 0) + allEncounterItems.filter {
            if case .altered = $0.encounter.finalizationStatus { return true }
            return false
        }.count
    }

    @MainActor
    private func rebuildClinicalSearch() {
        guard let summary, let authorizationURL else { return }
        withSecurityScopedAccess(to: authorizationURL) {
            let refreshed = try VaultReader().open(summary.url)
            self.summary = refreshed
            clinicalSearchIndex = ClinicalSearchIndex(patients: refreshed.patients)
            noticeMessage = "Busca atualizada a partir dos arquivos salvos."
        }
    }

    @MainActor
    private func openClinicalSearchResult(_ result: ClinicalSearchResult) {
        guard let summary, let authorizationURL else { return }
        withSecurityScopedAccess(to: authorizationURL) {
            let refreshed = try VaultReader().open(summary.url)
            self.summary = refreshed
            guard let patient = refreshed.patients.first(where: { $0.patientID == result.patientID }) else {
                throw VaultValidationIssue(rule: "search.patient_unavailable", path: result.patientID,
                                           message: "O paciente não está mais disponível. Atualize a busca.")
            }
            switch result.target {
            case .patient:
                requestNavigation(to: .patient(patient.patientID))
            case let .encounter(encounterID):
                guard let encounter = patient.encounters.first(where: { $0.metadata.encounterID == encounterID }) else {
                    throw VaultValidationIssue(rule: "search.encounter_unavailable", path: encounterID,
                        message: "A consulta não está mais disponível. Atualize a busca.")
                }
                searchEncounterPreview = SearchEncounterPreview(patientID: patient.patientID,
                    patientName: patient.displayName, encounter: encounter)
            case let .document(assetID):
                previewDocument(patientID: patient.patientID, assetID: assetID)
            }
        }
    }

    @MainActor
    private func exportHistoryEncounter(_ encounterID: String, context: PatientHistoryContext) {
        guard summary?.url == context.vaultURL else { return }
        requestClinicalExport(.encounter(patientID: context.patientID, encounterID: encounterID))
    }

    private func requestClinicalExport(_ scope: ClinicalExportScope) {
        guard !isExportingClinical, backupActivityMessage == nil else { return }
        isExportingClinical = true
        Task { @MainActor in
            defer { isExportingClinical = false }
            guard await saveDraftBeforeNavigation(), let summary, let authorizationURL else { return }
            let patientID: String
            let scopeLabel: String
            switch scope {
            case let .patient(id):
                patientID = id
                scopeLabel = "Prontuário do paciente"
            case let .encounter(id, _):
                patientID = id
                scopeLabel = "Consulta e documentos vinculados"
            }
            let sourceGranted = authorizationURL.startAccessingSecurityScopedResource()
            defer { if sourceGranted { authorizationURL.stopAccessingSecurityScopedResource() } }
            errorMessage = nil
            noticeMessage = nil
            do {
                let refreshed = try VaultReader().open(summary.url)
                self.summary = refreshed
                guard let patient = refreshed.patients.first(where: { $0.patientID == patientID }) else {
                    throw VaultValidationIssue(rule: "export.patient_unavailable", path: patientID,
                                               message: "O paciente não está disponível para exportação.")
                }
                let panel = NSOpenPanel()
                panel.title = "Escolher destino da exportação"
                panel.message = "\(scopeLabel) de \(patient.displayName). Escolha a pasta que receberá uma nova pasta de exportação."
                panel.prompt = "Escolher destino"
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let parent = panel.url else { return }
                let destination = parent.appending(path: "export-\(patientID)-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
                let confirmation = NSAlert()
                confirmation.messageText = "Exportar este conteúdo?"
                confirmation.informativeText = "Paciente: \(patient.displayName)\nIdentificador: \(patientID)\nConteúdo: \(scopeLabel)\nDestino: \(destination.path)\n\nInclui rascunhos salvos, quando presentes. A exportação abre fora do OpenPEP e não substitui um backup restaurável."
                confirmation.addButton(withTitle: "Exportar")
                confirmation.addButton(withTitle: "Cancelar")
                guard confirmation.runModal() == .alertFirstButtonReturn else { return }
                let destinationGranted = parent.startAccessingSecurityScopedResource()
                defer { if destinationGranted { parent.stopAccessingSecurityScopedResource() } }
                let vaultURL = summary.url
                let result = try await Task.detached(priority: .userInitiated) {
                    try ClinicalExportService().export(scope: scope, from: vaultURL, to: destination)
                }.value
                noticeMessage = "Exportação concluída: \(result.encounterCount) consulta(s) e \(result.documentCount) documento(s). Pasta: \(result.directoryURL.path)"
                NSWorkspace.shared.activateFileViewerSelecting([result.directoryURL])
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func requestBackupAction(_ action: VaultBackupAction) {
        guard backupActivityMessage == nil, !isExportingClinical,
              !isSavingDraft, !isFinalizing, !isSavingAddendum, !isImportingDocuments else { return }
        backupActivityMessage = "Preparando backup e recuperação…"
        Task { @MainActor in
            defer { backupActivityMessage = nil }
            // Complete an existing edit before holding the window read-only for the copy.
            guard await saveDraftBeforeNavigation() else { return }
            let sourceAuthorization = authorizationURL
            let granted = sourceAuthorization?.startAccessingSecurityScopedResource() ?? false
            defer { if granted { sourceAuthorization?.stopAccessingSecurityScopedResource() } }
            errorMessage = nil
            noticeMessage = nil
            backupActivityMessage = switch action {
            case .create: "Criando e verificando o backup…"
            case .verify: "Verificando o backup…"
            case .restore: "Verificando e restaurando o backup…"
            case .rehearse: "Ensaiando backup e restauração…"
            }
            do {
                guard let result = try await VaultBackupWorkflow().run(action, currentVaultURL: summary?.url) else { return }
                if result.didRestore {
                    try VaultBackupHistoryStore().recordRestoration(result.backup)
                } else {
                    try VaultBackupHistoryStore().recordVerification(result.backup)
                }
                backupHistory = summary.flatMap { VaultBackupHistoryStore().entry(for: $0.manifest.vaultID) }
                noticeMessage = result.message
                if let revealURL = result.revealURL {
                    NSWorkspace.shared.activateFileViewerSelecting([revealURL])
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var authenticationSessionMessage: String {
        guard let expiration = authenticationSession.expirationDate() else {
            return "A próxima ação protegida pedirá a autenticação do Mac."
        }
        let time = expiration.formatted(
            .dateTime.hour().minute().locale(Locale(identifier: "pt_BR"))
        )
        return "Sessão autenticada até \(time)."
    }

    private var hasUnsavedDraft: Bool {
        guard let encounter = selectedEncounter else { return false }
        return !ClinicalDraftSaver.matchesPersistedBody(draftText, encounter.draft.body)
    }

    private var filteredPatients: [PatientSummary] {
        guard let summary else { return [] }
        return summary.patients.filter { patient in
            if let filter = assistantPatientFilter, patientSearch == filter.query {
                return filter.includes(patient)
            }
            guard showsArchivedPatients || !patient.isArchived else { return false }
            if PatientSearch.matches(patient, query: patientSearch) { return true }
            guard let profile = summary.demoCatalog?.profile(for: patient.patientID) else {
                return false
            }
            let query = normalizedSearch(patientSearch)
            let searchable = ([profile.displayName, profile.primaryProblem, profile.summary]
                + profile.activeProblems).joined(separator: " ")
            return normalizedSearch(searchable).contains(query)
        }
    }

    private func patientBirthDate(_ patient: PatientSummary) -> String {
        let value = PatientDateText.displayValue(fromStorage: patient.record?.birthDate)
        return value.isEmpty ? "Não informado" : value
    }

    private func patientLastPassage(_ patient: PatientSummary) -> String? {
        patient.encounters
            .max(by: { $0.metadata.startedAt < $1.metadata.startedAt })
            .map { displayClinicalDate($0.metadata.startedAt) }
    }

    private func openPatientContact(_ patient: PatientSummary, contact: PatientContact) {
        do {
            let url: URL
            switch contact.type {
            case .phone:
                url = try WhatsAppShare.conversationURL(
                    patient: patient,
                    contactID: contact.id,
                    destination: .app
                )
            case .email:
                var components = URLComponents()
                components.scheme = "mailto"
                components.path = contact.value
                guard let emailURL = components.url else { return }
                url = emailURL
            }
            NSWorkspace.shared.open(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func encounterStatusIcon(_ status: EncounterFinalizationStatus) -> String {
        switch status {
        case .draft: "square.and.pencil"
        case .verified: "checkmark.shield"
        case .altered: "exclamationmark.shield"
        }
    }

    private var draftActionsBlocked: Bool {
        summary?.writingAllowed != true || isSavingDraft || isFinalizing || isOpeningEncounterDetails
            || isChangingModality || transcriptionSession.isBusy
    }

    private func activeDraftAction(_ item: EncounterListItem, action: String) {
        let destination = activeEncounterSelection(item)
        let vaultURL = summary?.url
        Task { @MainActor in
            guard !draftActionsBlocked, await saveDraftBeforeNavigation(), summary?.url == vaultURL else { return }
            if selection != destination {
                navigate(to: destination)
                loadDraft(for: destination)
            }
            guard selection == destination, selectedEncounter?.finalizationStatus == .draft else { return }
            switch action {
            case "save": _ = await saveDraft(announcingSuccess: true)
            case "finalize":
                finalizationError = nil
                documentFinalizationSummary = documentReviewSummary()
                confirmsFinalization = true
            case "delete": confirmsDraftDeletion = true
            default: break
            }
        }
    }

    private var assistantContextPatientID: String? {
        Self.wikiPatientID(for: selection,
            selectedPatientID: selectedPatient?.patientID,
            expandedPatientID: summary?.patients.first { $0.patientID == expandedPatientID }?.patientID)
    }

    static func wikiPatientID(for selection: AppSelection?, selectedPatientID: String?, expandedPatientID: String?) -> String? {
        switch selection {
        case let .patient(patientID): return patientID
        case .encounter: return selectedPatientID
        case .patients: return expandedPatientID
        default: return nil
        }
    }

    private func showWiki(patientID: String?) {
        assistant.close(restoreFocus: true)
        guard let vaultID = summary?.manifest.vaultID else { return }
        patientWikiSheet = PatientWikiSheetContext(vaultID: vaultID, patientID: patientID)
    }

    private func showAssistant() { showAssistant(initialPrompt: "", autoSubmit: false) }

    private func showAssistant(initialPrompt: String, autoSubmit: Bool) {
        let vaultURL = summary?.url
        let vaultID = summary?.manifest.vaultID
        let initialSelection = selection
        let initialModel = assistantModel
        let contextPatientID = assistantContextPatientID
        let reload: @MainActor () async throws -> VaultSummary = {
            try Task.checkCancellation()
            guard self.summary?.url == vaultURL, self.summary?.manifest.vaultID == vaultID,
                  self.selection == initialSelection, self.assistantContextPatientID == contextPatientID,
                  let vaultURL, let authorizationURL else {
                throw AssistantIssue.changed
            }
            let loaded = try await Task.detached {
                let granted = authorizationURL.startAccessingSecurityScopedResource()
                defer { if granted { authorizationURL.stopAccessingSecurityScopedResource() } }
                return try VaultReader().open(vaultURL)
            }.value
            try Task.checkCancellation()
            guard self.summary?.url == vaultURL, self.selection == initialSelection,
                  self.assistantContextPatientID == contextPatientID, loaded.manifest.vaultID == vaultID else { throw AssistantIssue.changed }
            return loaded
        }
        let resolve: AssistantSession.Resolve = { query in
            if query.isEmpty && contextPatientID == nil { throw AssistantIssue.missingPatient }
            let patients = try await reload().patients
            return query.isEmpty
                ? try AssistantPatientMatches.contextual(patientID: contextPatientID, in: patients)
                : AssistantPatientMatches.resolve(query, in: patients)
        }
        let answer: AssistantSession.Answer = { question, patient in
            let current = try await reload()
            guard assistantEnabled, assistantTextEnabled, assistantModel == initialModel,
                  let fresh = current.patients.first(where: { $0.patientID == patient.patientID }),
                  fresh.record == patient.record, !fresh.isArchived, let authorizationURL else { throw AssistantIssue.changed }
            let context = PatientHistoryContext(patientID: fresh.patientID, patientName: fresh.displayName,
                vaultURL: current.url, authorizationURL: authorizationURL, insertionEncounter: nil)
            let result = try await PatientQuestionService().answer(question: question, context: context)
            let latest = try await reload()
            guard assistantEnabled, assistantTextEnabled, assistantModel == initialModel,
                  let stillCurrent = latest.patients.first(where: { $0.patientID == patient.patientID }),
                  !stillCurrent.isArchived, stillCurrent.record == patient.record else { throw AssistantIssue.changed }
            try Task.checkCancellation()
            try result.wikiReadingSnapshot?.revalidate(context: context)
            return result
        }
        let open: AssistantSession.Navigate = { intent, matches in
            let query = intent.query
            try Task.checkCancellation()
            guard assistant.canNavigate else { throw AssistantIssue.formOpen }
            guard assistantEnabled, assistantTextEnabled, assistantModel == initialModel,
                  self.selection == initialSelection, self.summary?.url == vaultURL,
                  self.summary?.manifest.vaultID == vaultID else { throw AssistantIssue.changed }
            guard await saveDraftBeforeNavigation() else { throw AssistantIssue.saveFailed }
            try Task.checkCancellation()
            let current = try await reload()
            let refreshedMatches = query.isEmpty
                ? try AssistantPatientMatches.contextual(patientID: contextPatientID, in: current.patients)
                : AssistantPatientMatches.resolve(query, in: current.patients)
            guard !matches.patients.isEmpty,
                  Set(refreshedMatches.patients.map(\.patientID)) == Set(matches.patients.map(\.patientID)),
                  matches.patients.allSatisfy({ candidate in
                      refreshedMatches.patients.contains { $0.patientID == candidate.patientID && $0.record == candidate.record }
                  }), assistant.canNavigate, assistantEnabled, assistantTextEnabled,
                  assistantModel == initialModel, !hasUnsavedDraft else { throw AssistantIssue.changed }
            if let encounter = selectedEncounter {
                guard current.patients.first(where: { $0.patientID == encounter.metadata.patientID })?
                    .encounters.first(where: { $0.metadata.encounterID == encounter.metadata.encounterID })?
                    .draft.persistedData == encounter.draft.persistedData else { throw AssistantIssue.changed }
            }
            self.summary = current
            assistant.close(restoreFocus: false)
            if intent.opensHistory, let patient = refreshedMatches.unambiguousPatient, let authorizationURL {
                patientHistoryContext = PatientHistoryContext(patientID: patient.patientID,
                    patientName: patient.displayName, vaultURL: current.url, authorizationURL: authorizationURL,
                    insertionEncounter: selectedPatient?.patientID == patient.patientID && selectedEncounter?.finalizationStatus == .draft ? selectedEncounter : nil)
                return
            }
            let filter = AssistantPatientFilter(query: query, matches: refreshedMatches, opensHistory: intent.opensHistory)
            navigate(to: filter.expandedPatientID.map(AppSelection.patient) ?? .patients)
            assistantPatientFilter = filter
            patientSearch = query
            showsArchivedPatients = false
            expandedPatientID = filter.expandedPatientID
            assistant.owner?.makeKeyAndOrderFront(nil)
        }
        let prepare: AssistantSession.Prepare = { draft, patient in
            guard assistant.canNavigate else { throw AssistantIssue.formOpen }
            let body = try draft.composerBody()
            let current = try await reload()
            try Task.checkCancellation()
            guard assistantEnabled, assistantTextEnabled, assistantModel == initialModel,
                  assistant.canNavigate,
                  let fresh = current.patients.first(where: { $0.patientID == patient.patientID }),
                  !fresh.isArchived, fresh.record == patient.record else { throw AssistantIssue.changed }
            // The consultation stays mounted, with its text and undo manager untouched.
            standaloneDocumentVault = current.url
            standaloneDocumentVaultID = current.manifest.vaultID
            standaloneDocumentInitialBody = body
            assistant.close(restoreFocus: false)
            standaloneDocumentPatient = fresh
            assistant.owner?.makeKeyAndOrderFront(nil)
        }
        var readWiki: AssistantSession.ReadWiki?
        if let patientID = contextPatientID {
            readWiki = {
                let current = try await reload()
                guard let patient = current.patients.first(where: { $0.patientID == patientID }),
                      !patient.isArchived, let authorizationURL else { throw AssistantIssue.changed }
                let context = PatientHistoryContext(patientID: patientID, patientName: patient.displayName,
                    vaultURL: current.url, authorizationURL: authorizationURL, insertionEncounter: nil)
                let reading = try await Task.detached { try PatientWikiReadingSnapshot.load(context: context) }.value
                _ = try await reload()
                try await Task.detached { try reading.revalidate(context: context) }.value
                try Task.checkCancellation()
                _ = try await reload()
                return reading
            }
        }
        let ordinaryNavigation: (AppSelection) -> Void = { destination in
            guard assistant.canNavigate else {
                assistant.session.showMessage(AssistantIssue.formOpen.localizedDescription)
                return
            }
            assistant.close()
            requestNavigation(to: destination)
        }
        assistant.show(contextLabel: summary?.patients.first(where: { $0.patientID == contextPatientID })?.displayName, initialPrompt: initialPrompt, autoSubmit: autoSubmit, submit: {
            guard assistantEnabled, assistantTextEnabled else {
                assistant.session.showMessage(AssistantIssue.unavailable.localizedDescription)
                return
            }
            guard vaultURL != nil else {
                assistant.session.showMessage("Abra um prontuário antes de procurar pacientes.")
                return
            }
            assistant.session.submit(interpret: AssistantSession.interpretConfigured,
                                     resolve: resolve, navigate: open, answer: answer, prepare: prepare)
        }, settings: { ordinaryNavigation(.settingsTopic(.aiAssistance)) }, readWiki: readWiki, voicePermitted: {
            assistantEnabled && assistantTextEnabled && assistantVoiceEnabled &&
                !AssistantVoiceSession.clinicalCaptureActive && self.summary?.url == vaultURL &&
                self.selection == initialSelection
        })
    }

    private func requestNavigation(to destination: AppSelection) {
        guard destination != selection else { return }
        Task { @MainActor in
            guard await saveDraftBeforeNavigation() else { return }
            navigate(to: destination)
        }
    }

    private func requestHomeSearch() {
        guard !clinicalSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        showAssistant(initialPrompt: clinicalSearchQuery, autoSubmit: true)
    }

    private func performHomePatientAction(
        _ action: HomePatientAction,
        patient: PatientSummary
    ) {
        switch action {
        case .startEncounter:
            requestEncounterStart(EncounterStartContext(
                patientID: patient.patientID,
                appointmentID: nil
            ))
        case .issueDocument:
            standaloneDocumentVault = summary?.url
            standaloneDocumentVaultID = summary?.manifest.vaultID
            standaloneDocumentPatient = patient
        }
    }

    private func navigate(to destination: AppSelection) {
        prepareNavigation(destination)
        if let current = selection, current != destination {
            backHistory.append(current)
        }
        forwardHistory.removeAll()
        selection = destination
    }

    private func requestBack() {
        guard !backHistory.isEmpty else { return }
        Task { @MainActor in
            guard await saveDraftBeforeNavigation() else { return }
            goBack()
        }
    }

    private func requestForward() {
        guard !forwardHistory.isEmpty else { return }
        Task { @MainActor in
            guard await saveDraftBeforeNavigation() else { return }
            goForward()
        }
    }

    private func goBack() {
        guard let destination = backHistory.popLast() else { return }
        prepareNavigation(destination)
        if let current = selection { forwardHistory.append(current) }
        selection = destination
    }

    private func goForward() {
        guard let destination = forwardHistory.popLast() else { return }
        prepareNavigation(destination)
        if let current = selection { backHistory.append(current) }
        selection = destination
    }

    @MainActor
    private func saveDraftBeforeNavigation() async -> Bool {
        let source = selection, vaultURL = summary?.url
        do {
            while isSavingDraft { try await Task.sleep(for: .milliseconds(100)) }
            try Task.checkCancellation()
        } catch { return false }
        guard selection == source, summary?.url == vaultURL else { return false }
        guard hasUnsavedDraft else { return true }
        return await saveDraft(announcingSuccess: false)
    }

    private func prepareNavigation(_ destination: AppSelection) {
        assistantPatientFilter = nil
        if case let .patient(patientID) = destination {
            expandedPatientID = patientID
            patientSearch = ""
            if summary?.patients.first(where: { $0.patientID == patientID })?.isArchived == true {
                showsArchivedPatients = true
            }
        }
        guard case let .encounter(patientID, encounterID) = destination,
              let patient = summary?.patients.first(where: { $0.patientID == patientID }),
              let encounter = patient.encounters.first(where: {
                  $0.metadata.encounterID == encounterID
              }),
              encounter.finalizationStatus == .draft else {
            return
        }
        encounterActivity.activate(patientID: patientID, encounterID: encounterID)
    }

    private func resetNavigation(to destination: AppSelection = .home) {
        backHistory.removeAll()
        forwardHistory.removeAll()
        encounterActivity.clear()
        resetAgendaToToday()
        clinicalSearchQuery = ""
        clinicalSearchFilter = .all
        selection = destination
    }

    @MainActor
    private func requestSearch(filter: ClinicalSearchFilter) {
        guard let summary else { return }
        let capturedSelection = selection
        Task { @MainActor in
            guard await saveDraftBeforeNavigation() else { return }
            guard self.summary?.url == summary.url,
                  self.summary?.manifest.vaultID == summary.manifest.vaultID,
                  selection == capturedSelection, !hasUnsavedDraft else { return }
            clinicalSearchQuery = ""
            clinicalSearchFilter = filter
            navigate(to: .search)
        }
    }

    private var agendaHeading: String {
        agendaViewMode == .day && Calendar.current.isDate(selectedAgendaDate, inSameDayAs: agendaNow)
            ? "Hoje" : "Agenda"
    }

    private func resetAgendaToToday() {
        agendaNow = Date()
        selectedAgendaDate = Calendar.current.startOfDay(for: agendaNow)
        agendaViewMode = .day
        appointmentSearch = ""
        showsPastAppointments = false
    }

    @MainActor
    private func requestToday() {
        guard let summary, !isSavingDraft, !isFinalizing else { return }
        let capturedSelection = selection
        Task { @MainActor in
            guard await saveDraftBeforeNavigation() else { return }
            guard self.summary?.url == summary.url,
                  self.summary?.manifest.vaultID == summary.manifest.vaultID,
                  selection == capturedSelection, !hasUnsavedDraft else { return }
            resetAgendaToToday()
            navigate(to: .agenda)
        }
    }

    @MainActor
    private func openVault() {
        let panel = NSOpenPanel()
        panel.title = "Abrir prontuário"
        panel.prompt = "Abrir"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        withSecurityScopedAccess(to: url, clearVaultOnError: true) {
            let opened = try VaultReader().open(url)
            summary = opened
            authorizationURL = url
            authenticationSession.clear()
            resetNavigation()
            try VaultBookmarkStore().save(authorizationURL: url, vaultURL: opened.url)
            loadDraft(for: selection)
            noticeMessage = "Prontuário aberto."
        }
    }

    @MainActor
    private func createDemoVault() {
        guard !isGeneratingDemo else { return }
        let panel = NSOpenPanel()
        panel.title = "Onde guardar a demonstração?"
        panel.prompt = "Criar e abrir"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        isGeneratingDemo = true
        Task { @MainActor in
            let granted = parent.startAccessingSecurityScopedResource()
            defer {
                if granted { parent.stopAccessingSecurityScopedResource() }
                isGeneratingDemo = false
            }
            do {
                let created = try await Task.detached(priority: .userInitiated) {
                    try SyntheticReleaseSeeder().seed(in: parent, at: Date())
                }.value
                try VaultBookmarkStore().save(authorizationURL: parent, vaultURL: created.url)
                summary = created
                authorizationURL = parent
                authenticationSession.clear()
                resetNavigation()
                loadDraft(for: selection)
                noticeMessage = nil
            } catch { errorMessage = "Não foi possível abrir a demonstração: \(error.localizedDescription)" }
        }
    }

    @MainActor
    private func createVault() {
        let panel = NSOpenPanel()
        panel.title = "Onde guardar o prontuário?"
        panel.message = "O OpenPEP criará uma pasta local legível por você."
        panel.prompt = "Criar aqui"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let parentURL = panel.url else { return }
        withSecurityScopedAccess(to: parentURL, clearVaultOnError: true) {
            let now = Date()
            let identity = try VaultCreationIdentity.generate(at: now)
            let created = try VaultCreator().create(in: parentURL, identity: identity, createdAt: now)
            summary = created
            authorizationURL = parentURL
            authenticationSession.clear()
            resetNavigation()
            try VaultBookmarkStore().save(authorizationURL: parentURL, vaultURL: created.url)
            noticeMessage = "Prontuário criado e pronto para uso."
        }
    }

    @MainActor
    private func restoreLastVaultIfNeeded() {
        guard !didAttemptVaultRestore else { return }
        didAttemptVaultRestore = true
        isRestoringVault = true
        defer { isRestoringVault = false }

        do {
            guard let reference = try VaultBookmarkStore().resolve() else { return }
            let granted = reference.authorizationURL.startAccessingSecurityScopedResource()
            defer { if granted { reference.authorizationURL.stopAccessingSecurityScopedResource() } }
            let opened = try VaultReader().open(reference.vaultURL)
            summary = opened
            authorizationURL = reference.authorizationURL
            resetNavigation()
        } catch {
            VaultBookmarkStore().clear()
            summary = nil
            authorizationURL = nil
            resetNavigation()
            errorMessage = "Não foi possível reabrir o último prontuário. Escolha a pasta novamente. \(error.localizedDescription)"
        }
    }

    @MainActor
    private func createPatient() {
        guard summary?.writingAllowed == true else { return }
        patientFormMode = .create
    }

    private func record(for mode: PatientFormMode) -> PatientRecord? {
        guard case let .edit(patientID) = mode else { return nil }
        return summary?.patients.first(where: { $0.patientID == patientID })?.record
    }

    @MainActor
    private func savePatient(
        _ input: PatientRecordInput,
        mode: PatientFormMode
    ) {
        guard let summary, let authorizationURL, summary.writingAllowed else { return }
        withSecurityScopedAccess(to: authorizationURL) {
            let patientID: String
            switch mode {
            case .create:
                let identity = try PatientCreationIdentity.generate()
                patientID = identity.patientID
                _ = try PatientCreator().createRegistered(
                    in: summary.url,
                    identity: identity,
                    input: input
                )
            case let .edit(identifier):
                let patient = try requiredPatient(identifier, in: summary)
                _ = try PatientEditor().update(patient: patient, input: input)
                patientID = identifier
            }
            self.summary = try VaultReader().open(summary.url)
            patientFormMode = nil
            let action = mode == .create ? patientActionAfterCreation : nil
            patientActionAfterCreation = nil
            if let action,
               let patient = self.summary?.patients.first(where: { $0.patientID == patientID }) {
                performHomePatientAction(action, patient: patient)
            } else if mode == .create {
                pendingCreatedPatient = self.summary?.patients.first { $0.patientID == patientID }.map { NewPatientContext(patient: $0) }
                navigate(to: .patients)
            } else {
                navigate(to: .patient(patientID))
            }
            noticeMessage = mode == .create
                ? "Paciente cadastrado."
                : "Dados do paciente atualizados."
        }
    }

    @MainActor
    private func createPatientForAppointment(_ input: PatientRecordInput) throws -> PatientSummary {
        guard let summary, let authorizationURL, summary.writingAllowed else {
            throw VaultValidationIssue(
                rule: "vault.read_only",
                path: "patients",
                message: "O prontuário não permite cadastrar pacientes agora."
            )
        }
        let granted = authorizationURL.startAccessingSecurityScopedResource()
        defer { if granted { authorizationURL.stopAccessingSecurityScopedResource() } }
        let created = try PatientCreator().createRegistered(
            in: summary.url,
            identity: try PatientCreationIdentity.generate(),
            input: input
        )
        self.summary = try VaultReader().open(summary.url)
        noticeMessage = "Paciente cadastrado e selecionado no agendamento."
        return self.summary?.patients.first { $0.patientID == created.patientID } ?? created
    }

    @MainActor
    private func importDocumentsForAppointment(
        patientID: String,
        encounterID: String?,
        urls: [URL]
    ) throws -> Int {
        guard let summary, let authorizationURL, summary.writingAllowed else {
            throw VaultValidationIssue(
                rule: "vault.read_only",
                path: "patients/\(patientID)/raw",
                message: "O prontuário não permite importar documentos agora."
            )
        }
        let patient = try requiredPatient(patientID, in: summary)
        let unique = Array(Dictionary(
            urls.map { ($0.standardizedFileURL, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values).sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !unique.isEmpty, unique.count <= DocumentImportDescriptor.maximumBatchCount else {
            throw VaultValidationIssue(
                rule: "raw.batch_size",
                path: patientID,
                message: "Escolha entre 1 e 20 documentos por operação."
            )
        }
        if let encounterID {
            guard OpenPEPIdentifier.isEncounter(encounterID),
                  patient.encounters.contains(where: { $0.metadata.encounterID == encounterID }) else {
                throw VaultValidationIssue(
                    rule: "raw.encounter_not_found",
                    path: encounterID,
                    message: "A consulta vinculada não está disponível para este paciente."
                )
            }
        }

        let vaultGranted = authorizationURL.startAccessingSecurityScopedResource()
        defer {
            if vaultGranted { authorizationURL.stopAccessingSecurityScopedResource() }
            self.summary = try? VaultReader().open(summary.url)
        }
        for sourceURL in unique {
            let sourceGranted = sourceURL.startAccessingSecurityScopedResource()
            defer { if sourceGranted { sourceURL.stopAccessingSecurityScopedResource() } }
            let now = Date()
            _ = try GeneralDocumentImporter().importDocument(
                from: sourceURL,
                into: patient,
                encounterID: encounterID,
                deviceID: summary.manifest.deviceID,
                identity: try RawAssetCreationIdentity.generate(at: now),
                importedAt: now
            )
        }
        noticeMessage = unique.count == 1
            ? "Documento importado e verificado."
            : "\(unique.count) documentos importados e verificados."
        return unique.count
    }

    private func duplicateNames(
        for input: PatientRecordInput,
        mode: PatientFormMode
    ) -> [String] {
        guard let summary else { return [] }
        let excludedID: String?
        switch mode {
        case .create: excludedID = nil
        case let .edit(patientID): excludedID = patientID
        }
        return PatientDuplicateDetector.candidates(
            for: input,
            among: summary.patients,
            excluding: excludedID
        ).map(\.displayName)
    }

    private var activeRegisteredPatients: [PatientSummary] {
        (summary?.patients ?? [])
            .filter { $0.record?.status == .active }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var filteredAppointmentsInVisiblePeriod: [AppointmentSummary] {
        guard let summary else { return [] }
        let interval = AgendaCalendarModel.interval(
            containing: selectedAgendaDate,
            mode: agendaViewMode
        )
        let query = PatientSearch.normalize(appointmentSearch)
        return AgendaCalendarModel.appointments(summary.appointments, in: interval).filter { appointment in
            guard showsPastAppointments || !AgendaCalendarModel.hidesFromUpcomingList(appointment.record, now: agendaNow) else { return false }
            guard !query.isEmpty else { return true }
            let patient = summary.patients.first { $0.patientID == appointment.record.patientID }
            return patient.map { PatientSearch.matches($0, query: appointmentSearch) }
                ?? PatientSearch.normalize(appointment.record.patientID).contains(query)
        }
    }

    private var agendaPeriodHeading: String {
        let locale = Locale(identifier: "pt_BR")
        switch agendaViewMode {
        case .day:
            return displayDayHeading(selectedAgendaDate)
        case .week:
            let interval = AgendaCalendarModel.interval(containing: selectedAgendaDate, mode: .week)
            let lastDay = Calendar.current.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
            return "\(interval.start.formatted(.dateTime.day().month(.abbreviated).locale(locale))) a \(lastDay.formatted(.dateTime.day().month(.abbreviated).year().locale(locale)))"
        case .month:
            return selectedAgendaDate.formatted(.dateTime.month(.wide).year().locale(locale))
        }
    }

    private var defaultAppointmentStart: Date {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: selectedAgendaDate)
        if calendar.isDateInToday(day) {
            let now = Date()
            let minute = calendar.component(.minute, from: now)
            let interval = AppointmentDefaults.validGridMinutes(agendaGridMinutes)
            let rounded = calendar.date(
                byAdding: .minute,
                value: interval - (minute % interval),
                to: now
            ) ?? now
            return calendar.date(bySetting: .second, value: 0, of: rounded) ?? rounded
        }
        return calendar.date(
            bySettingHour: min(max(agendaDayStartHour, 0), 23),
            minute: 0,
            second: 0,
            of: day
        ) ?? day
    }

    private func moveAgendaPeriod(by value: Int) {
        selectedAgendaDate = AgendaCalendarModel.moving(
            selectedAgendaDate,
            by: value,
            mode: agendaViewMode
        )
    }

    private func appointmentStart(for mode: AppointmentFormMode) -> Date {
        if case let .create(date) = mode { return date }
        return defaultAppointmentStart
    }

    private func appointment(for mode: AppointmentFormMode) -> AppointmentSummary? {
        guard case let .edit(appointmentID) = mode else { return nil }
        return summary?.appointments.first { $0.record.appointmentID == appointmentID }
    }

    private func conflictLabels(
        for input: AppointmentInput,
        mode: AppointmentFormMode
    ) -> [String] {
        guard let appointments = summary?.appointments else { return [] }
        let excludedID: String?
        switch mode {
        case .create: excludedID = nil
        case let .edit(appointmentID): excludedID = appointmentID
        }
        return AppointmentConflictDetector.conflicts(
            for: input,
            among: appointments,
            excluding: excludedID
        ).map { appointment in
            appointment.record.startDate.formatted(
                .dateTime.hour().minute().locale(Locale(identifier: "pt_BR"))
            )
        }
    }

    @MainActor
    private func saveAppointment(_ input: AppointmentInput, mode: AppointmentFormMode, shareByEmail: Bool? = nil) {
        guard let summary, let authorizationURL, summary.writingAllowed else { return }
        withSecurityScopedAccess(to: authorizationURL) {
            let writer = AppointmentWriter()
            let saved: AppointmentSummary
            switch mode {
            case .create:
                let patient = try requiredPatient(input.patientID, in: summary)
                saved = try writer.create(
                    in: summary.url,
                    patient: patient,
                    identity: AppointmentCreationIdentity.generate(),
                    input: input
                )
            case let .edit(appointmentID):
                guard let appointment = (savedAppointmentInForm?.id == appointmentID ? savedAppointmentInForm : nil) ?? summary.appointments.first(where: {
                    $0.record.appointmentID == appointmentID
                }) else {
                    throw VaultValidationIssue(
                        rule: "appointment.not_found",
                        path: appointmentID,
                        message: "O agendamento não foi encontrado."
                    )
                }
                saved = try writer.update(
                    appointment,
                    in: summary.url,
                    patients: summary.patients,
                    input: input
                )
            }
            // Keep the published identity even if the subsequent vault reread fails.
            // A retry must update this item, never create a duplicate appointment.
            savedAppointmentInForm = saved
            self.summary = try VaultReader().open(summary.url)
            if let shareByEmail,
               let current = self.summary?.appointments.first(where: { $0.id == saved.id }),
               let patient = self.summary?.patients.first(where: { $0.patientID == current.record.patientID }) {
                pendingInvitation = WhatsAppShareContext(appointment: current, patient: patient)
                pendingInvitationUsesEmail = shareByEmail
            }
            selectedAgendaDate = Calendar.current.startOfDay(for: input.startsAt)
            appointmentSearch = ""
            if AgendaCalendarModel.isPast(saved.record, now: Date()) { showsPastAppointments = true }
            navigate(to: .agenda)
            if shareByEmail == nil { appointmentFormMode = nil }
            noticeMessage = mode.isCreate
                ? "Agendamento salvo."
                : "Agendamento atualizado."
        }
    }

    @MainActor
    private func cancelAppointment(_ appointmentID: String) {
        guard let summary, let authorizationURL, summary.writingAllowed,
              let appointment = summary.appointments.first(where: {
                  $0.record.appointmentID == appointmentID
              }) else { return }
        withSecurityScopedAccess(to: authorizationURL) {
            let cancelled = try AppointmentWriter().cancel(
                appointment,
                in: summary.url,
                patients: summary.patients
            )
            if appointment.record.status != .cancelled {
                administrativeUndo = AdministrativeUndo(
                    vaultURL: summary.url,
                    vaultID: summary.manifest.vaultID,
                    message: "Agendamento de \(summary.patients.first { $0.patientID == appointment.record.patientID }?.displayName ?? "paciente") cancelado.",
                    action: .appointment(cancelled, previous: appointment.record.status)
                )
                undoError = nil
            }
            self.summary = try VaultReader().open(summary.url)
            navigate(to: .agenda)
            noticeMessage = "Agendamento cancelado sem remover o arquivo."
        }
    }

    private func appointmentStatusIcon(_ status: AppointmentStatus) -> String {
        switch status {
        case .scheduled: "clock"
        case .arrived: "person.crop.circle.badge.checkmark"
        case .inProgress: "stethoscope"
        case .completed: "checkmark.circle"
        case .cancelled: "xmark.circle"
        case .noShow: "person.crop.circle.badge.xmark"
        }
    }

    private func appointmentAccent(_ status: AppointmentStatus) -> Color {
        switch status {
        case .scheduled: .accentColor
        case .arrived, .inProgress: .orange
        case .completed: .green
        case .cancelled, .noShow: .secondary
        }
    }

    private func supportsRemoteHandoff(_ status: AppointmentStatus) -> Bool {
        switch status {
        case .scheduled, .arrived, .inProgress: true
        case .completed, .cancelled, .noShow: false
        }
    }

    private func canEditAppointment(_ appointment: AppointmentSummary) -> Bool {
        guard summary?.writingAllowed == true,
              appointment.record.status != .cancelled else {
            return false
        }
        guard let patient = summary?.patients.first(where: {
            $0.patientID == appointment.record.patientID
        }) else {
            return true
        }
        return !patient.isArchived && (appointment.record.encounterID != nil || encounterForAppointment(appointment, patient: patient) == nil)
    }

    private func canCancelAppointment(_ appointment: AppointmentSummary) -> Bool {
        guard appointment.record.encounterID == nil else { return false }
        let patient = summary?.patients.first { $0.patientID == appointment.record.patientID }
        return patient.map { encounterForAppointment(appointment, patient: $0) == nil } ?? true
    }

    private func openConsultationAction(for appointment: AppointmentSummary?) -> (() -> Void)? {
        guard let appointment,
              let patient = summary?.patients.first(where: { $0.patientID == appointment.record.patientID }),
              let encounter = encounterForAppointment(appointment, patient: patient) else { return nil }
        return {
            appointmentFormMode = nil
            requestNavigation(to: .encounter(patientID: patient.patientID, encounterID: encounter.metadata.encounterID))
        }
    }

    private func selectCalendarAppointment(_ appointmentID: String) {
        guard let appointment = summary?.appointments.first(where: { $0.id == appointmentID }) else {
            errorMessage = "O agendamento não está disponível. Atualize o prontuário."
            return
        }
        errorMessage = nil
        appointmentActions = appointment
    }

    private func afterAppointmentActions(_ action: @escaping () -> Void) {
        deferredAppointmentAction = action
        appointmentActions = nil
    }

    private func appointmentActionsSheet(_ selected: AppointmentSummary) -> some View {
        let appointment = summary?.appointments.first { $0.id == selected.id } ?? selected
        let patient = summary?.patients.first { $0.patientID == appointment.record.patientID }
        let consultation = openConsultationAction(for: appointment)
        return AppointmentActionsView(
            appointment: appointment, patient: patient, hasConsultation: consultation != nil,
            canStart: summary?.writingAllowed == true && patient?.record?.status == .active
                && supportsEncounterStart(appointment.record.status),
            canEdit: canEditAppointment(appointment),
            canCancel: canEditAppointment(appointment) && canCancelAppointment(appointment),
            error: errorMessage,
            onClose: { appointmentActions = nil },
            onConsultation: {
                afterAppointmentActions {
                    if let consultation { consultation() }
                    else { requestEncounterStart(EncounterStartContext(
                        patientID: appointment.record.patientID, appointmentID: appointment.id)) }
                }
            },
            onEdit: { afterAppointmentActions { appointmentFormMode = .edit(appointment.id) } },
            onWhatsApp: { contactID, destination in
                openPatientWhatsApp(appointment: appointment, contactID: contactID, destination: destination)
            },
            onCancelAppointment: {
                cancelAppointment(appointment.id)
                if errorMessage == nil { appointmentActions = nil }
            },
            onStatus: { status in
                let record = appointment.record
                saveAppointment(AppointmentInput(
                    patientID: record.patientID, startsAt: record.startDate, endsAt: record.endDate,
                    timeZone: record.timeZone, modality: record.modality, status: status,
                    location: record.location, remoteAccessURL: record.remoteAccessURL,
                    administrativeNote: record.administrativeNote,
                    telemedicineConsentConfirmed: record.telemedicineConsentConfirmed
                ), mode: .edit(appointment.id))
                savedAppointmentInForm = nil
                if errorMessage == nil { appointmentActions = nil }
            }
        )
    }

    private func openPatientWhatsApp(appointment: AppointmentSummary, contactID: String,
                                     destination: WhatsAppDestination) {
        guard let summary, let authorizationURL,
              let patient = summary.patients.first(where: { $0.patientID == appointment.record.patientID }),
              let expectedURL = try? WhatsAppShare.conversationURL(patient: patient, contactID: contactID, destination: destination)
        else { return }
        withSecurityScopedAccess(to: authorizationURL) {
            let current = try VaultReader().open(summary.url)
            guard let currentAppointment = current.appointments.first(where: { $0.id == appointment.id }),
                  currentAppointment.record.patientID == patient.patientID,
                  let currentPatient = current.patients.first(where: { $0.patientID == patient.patientID }),
                  try WhatsAppShare.conversationURL(patient: currentPatient, contactID: contactID, destination: destination) == expectedURL
            else { throw VaultValidationIssue(rule: "whatsapp.changed", path: appointment.id,
                message: "O contato mudou. Feche e atualize a agenda antes de continuar.") }
            guard NSWorkspace.shared.open(expectedURL) else {
                throw VaultValidationIssue(rule: "whatsapp.unavailable", path: appointment.id,
                    message: "Não foi possível abrir o WhatsApp. Tente Usar WhatsApp Web.")
            }
        }
    }

    private func supportsEncounterStart(_ status: AppointmentStatus) -> Bool {
        [.scheduled, .arrived, .inProgress].contains(status)
    }

    private func encounterForAppointment(
        _ appointment: AppointmentSummary,
        patient: PatientSummary
    ) -> EncounterSummary? {
        if let encounterID = appointment.record.encounterID {
            return patient.encounters.first { $0.metadata.encounterID == encounterID }
        }
        return patient.encounters.first { $0.metadata.appointmentID == appointment.id }
    }

    @MainActor
    private func requestFaceTime(
        appointmentID: String,
        contact: TelemedicineContactOption
    ) {
        guard let summary, let authorizationURL, summary.writingAllowed,
              let appointment = summary.appointments.first(where: { $0.id == appointmentID }) else {
            return
        }
        faceTimeHandoffContext = nil
        withSecurityScopedAccess(to: authorizationURL) {
            let outcome = try TelemedicineHandoffCoordinator.live().openFaceTime(
                for: appointment,
                contact: contact,
                in: summary.url
            )
            self.summary = try VaultReader().open(summary.url)
            if outcome.systemAccepted {
                noticeMessage = "FaceTime solicitado ao macOS. Confirme a chamada no FaceTime."
            } else {
                errorMessage = "O pedido foi registrado, mas o macOS não abriu o FaceTime. Confira se o aplicativo está disponível e tente novamente."
            }
        }
    }

    @MainActor
    private func openSavedRemoteLink(_ appointmentID: String) {
        guard let summary, let authorizationURL, summary.writingAllowed,
              let appointment = summary.appointments.first(where: { $0.id == appointmentID }) else {
            return
        }
        withSecurityScopedAccess(to: authorizationURL) {
            let outcome = try TelemedicineHandoffCoordinator.live().openSavedLink(
                for: appointment,
                in: summary.url
            )
            self.summary = try VaultReader().open(summary.url)
            if outcome.systemAccepted {
                noticeMessage = "Link salvo solicitado ao macOS. O OpenPEP não confirma entrada na chamada."
            } else {
                errorMessage = "O pedido foi registrado, mas o macOS não abriu o link. Verifique o navegador e tente novamente."
            }
        }
    }

    @MainActor
    private func shareRemoteLink(
        _ context: WhatsAppShareContext, contactID: String,
        destination: WhatsAppDestination, proposal: WhatsAppShare
    ) {
        guard let summary, let authorizationURL else { return }
        whatsAppShareContext = nil
        withSecurityScopedAccess(to: authorizationURL) {
            // Re-read before disclosing data; a stale preview must never share changed values.
            let current = try VaultReader().open(summary.url)
            let appointment = current.appointments.first(where: { $0.id == context.id })
            let patient = current.patients.first(where: { $0.patientID == appointment?.record.patientID })
            guard appointment?.record == context.appointment.record else {
                throw VaultValidationIssue(rule: "invitation.changed", path: context.id,
                    message: "O agendamento mudou. Reabra o convite antes de compartilhar.")
            }
            if try WhatsAppShare.openIfUnchanged(
                appointment: appointment, patient: patient,
                expectedPatientID: context.patient.patientID, expectedPatientName: context.patient.displayName,
                contactID: contactID, destination: destination, proposal: proposal,
                invitation: context.invitation,
                open: { NSWorkspace.shared.open($0) }
            ) {
                noticeMessage = "Composição solicitada ao WhatsApp. Revise e envie por lá; entrega não confirmada."
            } else {
                errorMessage = "O macOS não abriu o WhatsApp. Tente a opção WhatsApp Web ou copie o link salvo. Nenhum envio foi confirmado."
            }
            pendingInvitation = nil
        }
    }

    @MainActor
    private func composeEmailInvitation(_ context: WhatsAppShareContext, contactID: String, recipient: String) {
        guard let summary, let authorizationURL else { return }
        withSecurityScopedAccess(to: authorizationURL) {
            let current = try VaultReader().open(summary.url)
            let appointment = current.appointments.first { $0.id == context.id }
            let patient = current.patients.first { $0.patientID == context.patient.patientID }
            try ConsultationInvitation.validate(expected: context.appointment, current: appointment,
                patient: patient, contactID: contactID, expectedRecipient: recipient)
            let message = try ConsultationInvitation.text(for: context.appointment.record, consultationOpen: context.consultationOpen)
            let link = try TelemedicineURLBuilder.savedLinkURL(context.appointment.record.remoteAccessURL)
            let body = ConsultationInvitation.attributedBody(message, link: link)
            guard let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: [body]) else {
                throw VaultValidationIssue(rule: "invitation.mail_unavailable", path: context.id,
                    message: "Configure uma conta no Mail para abrir o convite formatado. Você também pode usar WhatsApp ou copiar o link.")
            }
            service.recipients = [recipient]
            service.subject = context.consultationOpen ? "Link para nossa consulta" : "Agendamento de teleconsulta"
            emailSharingService = service
            service.perform(withItems: [body])
            emailShareContext = nil
            pendingInvitation = nil
            noticeMessage = "Composição de e-mail solicitada. Confira o destinatário e envie no Mail; entrega não confirmada."
        }
    }

    @MainActor
    private func copySavedRemoteLink(_ appointmentID: String) {
        guard let appointment = summary?.appointments.first(where: { $0.id == appointmentID }) else {
            return
        }
        errorMessage = nil
        noticeMessage = nil
        do {
            if try TelemedicineHandoffCoordinator.live().copySavedLink(for: appointment) {
                noticeMessage = "Link salvo copiado. O OpenPEP não o gerou nem o enviou ao paciente."
            } else {
                errorMessage = "Não foi possível copiar o link salvo. Tente novamente."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func setPatientStatus(_ patientID: String, status: PatientStatus) {
        guard let summary, let authorizationURL, summary.writingAllowed else { return }
        withSecurityScopedAccess(to: authorizationURL) {
            let patient = try requiredPatient(patientID, in: summary)
            guard let record = patient.record else {
                throw VaultValidationIssue(
                    rule: "patient.registration_required",
                    path: patientID,
                    message: "O paciente opaco não possui cadastro editável."
                )
            }
            let input = PatientRecordInput(
                fullName: record.fullName ?? "",
                preferredName: record.preferredName,
                birthDate: record.birthDate,
                contacts: record.contacts,
                identifiers: record.identifiers,
                alerts: record.alerts
            )
            let updated = try PatientEditor().update(patient: patient, input: input, status: status)
            if status == .archived, record.status == .active {
                administrativeUndo = AdministrativeUndo(
                    vaultURL: summary.url,
                    vaultID: summary.manifest.vaultID,
                    message: "\(patient.displayName): cadastro arquivado.",
                    action: .patient(patientID, expected: updated, previous: record.status)
                )
                undoError = nil
            }
            self.summary = try VaultReader().open(summary.url)
            navigate(to: .patient(patientID))
            noticeMessage = status == .archived
                ? "Paciente arquivado sem remover seus arquivos."
                : "Paciente reativado."
        }
    }

    @MainActor
    private func undoAdministrativeAction(_ pending: AdministrativeUndo) {
        guard !isUndoing, pending.id == administrativeUndo?.id,
              summary?.url == pending.vaultURL, summary?.manifest.vaultID == pending.vaultID,
              let authorizationURL else { return }
        isUndoing = true
        undoError = nil
        Task { @MainActor in
            defer { isUndoing = false }
            let originalSelection = selection
            guard await saveDraftBeforeNavigation() else {
                undoError = draftSaveError ?? "Salve a edição pendente e tente desfazer novamente."
                return
            }
            guard pending.id == administrativeUndo?.id, summary?.url == pending.vaultURL,
                  summary?.manifest.vaultID == pending.vaultID,
                  selection == originalSelection, !hasUnsavedDraft else { return }
            let granted = authorizationURL.startAccessingSecurityScopedResource()
            defer { if granted { authorizationURL.stopAccessingSecurityScopedResource() } }
            do {
                let current = try VaultReader().open(pending.vaultURL)
                guard current.manifest.vaultID == pending.vaultID else {
                    throw VaultValidationIssue(rule: "vault.identity_changed", path: pending.vaultURL.path,
                        message: "O prontuário neste local mudou. Reabra-o antes de continuar.")
                }
                guard current.writingAllowed else {
                    throw VaultValidationIssue(rule: "vault.read_only", path: pending.vaultURL.path,
                        message: "O prontuário não permite escrita. Tente novamente quando estiver disponível.")
                }
                switch pending.action {
                case let .patient(patientID, expected, previous):
                    let patient = try requiredPatient(patientID, in: current)
                    _ = try PatientEditor().restoreStatus(patient: patient,
                        expectedCurrentRecord: expected, previousStatus: previous)
                case let .appointment(expected, previous):
                    guard let appointment = current.appointments.first(where: { $0.id == expected.id }) else {
                        throw VaultValidationIssue(rule: "appointment.not_found", path: expected.id,
                            message: "O agendamento não está mais disponível. Reabra a agenda.")
                    }
                    _ = try AppointmentWriter().restoreCancelled(appointment,
                        expectedCurrentRecord: expected.record, previousStatus: previous,
                        in: current.url, patients: current.patients)
                }
                administrativeUndo = nil
                self.summary = try VaultReader().open(current.url)
                noticeMessage = "Ação desfeita."
            } catch {
                undoError = error.localizedDescription
                errorMessage = error.localizedDescription
            }
        }
    }

    private func requiredPatient(_ patientID: String, in summary: VaultSummary) throws -> PatientSummary {
        guard let patient = summary.patients.first(where: { $0.patientID == patientID }) else {
            throw VaultValidationIssue(
                rule: "patient.not_found",
                path: patientID,
                message: "O paciente não foi encontrado no prontuário aberto."
            )
        }
        return patient
    }

    @MainActor
    private func chooseDocuments(for patient: PatientSummary, encounterID: String? = nil, chooseBinding: Bool = false) {
        let panel = NSOpenPanel()
        panel.title = "Importar documentos"
        panel.message = "Destino: \(patient.displayName). Arquivos de qualquer formato; até 25 MiB por arquivo."
        panel.prompt = chooseBinding ? "Escolher vínculo" : "Importar"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        _ = prepareDocumentImport(urls: panel.urls, for: patient,
            preferredEncounterID: encounterID, chooseBinding: chooseBinding)
    }

    private func documentImportActions(for patient: PatientSummary, encounterID: String? = nil) -> some View {
        HStack(spacing: 6) {
            Button("Importar documentos…", systemImage: "square.and.arrow.down") {
                chooseDocuments(for: patient, encounterID: encounterID)
            }
            Menu {
                Button("Importar e escolher vínculo…") {
                    chooseDocuments(for: patient, encounterID: encounterID, chooseBinding: true)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Opções de importação")
        }
        .disabled(summary?.writingAllowed != true || patient.isArchived || isImportingDocuments)
    }

    @discardableResult
    private func prepareDocumentImport(
        urls: [URL],
        for patient: PatientSummary,
        preferredEncounterID: String?,
        chooseBinding: Bool = false
    ) -> Bool {
        guard let summary, summary.writingAllowed, !patient.isArchived,
              !isImportingDocuments, documentImportContext == nil else { return false }
        let unique = Array(Dictionary(
            urls.map { ($0.standardizedFileURL, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values).sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !unique.isEmpty, unique.count <= DocumentImportDescriptor.maximumBatchCount else {
            errorMessage = "Escolha entre 1 e 20 documentos por operação."
            return false
        }
        do {
            let context = DocumentImportContext(
                patientID: patient.patientID,
                patientName: patient.displayName,
                vaultURL: summary.url,
                vaultID: summary.manifest.vaultID,
                patientRecord: patient.record,
                items: try unique.map { DocumentImportBatchItem(sourceURL: $0, identity: try .generate()) },
                encounters: patient.encounters.sorted { $0.metadata.startedAt > $1.metadata.startedAt },
                preferredEncounterID: preferredEncounterID,
                allowsChangingEncounter: chooseBinding
            )
            documentImportError = nil
            if chooseBinding { documentImportContext = context }
            else { importDocuments(context: context, encounterID: preferredEncounterID) }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @MainActor
    private func importDocuments(context: DocumentImportContext, encounterID: String?) {
        guard !isImportingDocuments, let authorizationURL else { return }
        isImportingDocuments = true
        patientImportReceipts[context.patientID] = nil
        documentImportError = nil
        errorMessage = nil
        let capturedSelection = selection
        Task { @MainActor in
            defer { isImportingDocuments = false }
            do {
                guard await saveDraftBeforeNavigation() else {
                    throw VaultValidationIssue(rule: "document_import.pending_edit", path: context.patientID,
                        message: draftSaveError ?? "Salve a edição pendente antes de importar.")
                }
                guard summary?.url == context.vaultURL, summary?.manifest.vaultID == context.vaultID,
                      selection == capturedSelection, !hasUnsavedDraft else {
                    throw VaultValidationIssue(rule: "document_import.context_changed", path: context.patientID,
                        message: "O destino mudou. Volte ao paciente desejado antes de importar.")
                }
                let granted = authorizationURL.startAccessingSecurityScopedResource()
                defer { if granted { authorizationURL.stopAccessingSecurityScopedResource() } }
                let current = try VaultReader().open(context.vaultURL)
                guard current.writingAllowed, current.manifest.vaultID == context.vaultID,
                      let patient = current.patients.first(where: { $0.patientID == context.patientID }),
                      patient.record == context.patientRecord, !patient.isArchived,
                      encounterID == nil || patient.encounters.contains(where: { $0.metadata.encounterID == encounterID }) else {
                    throw VaultValidationIssue(rule: "document_import.destination_changed", path: context.patientID,
                        message: "O paciente ou a consulta mudou. Confira o destino antes de importar.")
                }
                let result = await Task.detached {
                    DocumentImportBatch().run(items: context.items, in: context.vaultURL,
                        expectedVaultID: context.vaultID, patientID: context.patientID,
                        encounterID: encounterID, importedAt: Date())
                }.value
                // Copying stays bound to the captured destination; never navigate to another patient.
                if summary?.url == context.vaultURL, summary?.manifest.vaultID == context.vaultID {
                    do {
                        let reopened = try VaultReader().open(context.vaultURL)
                        guard reopened.manifest.vaultID == context.vaultID else {
                            throw VaultValidationIssue(rule: "document_import.vault_changed", path: context.vaultURL.path,
                                message: "O prontuário neste local mudou. Reabra-o antes de continuar.")
                        }
                        self.summary = reopened
                    } catch {
                        errorMessage = "Não foi possível atualizar a lista de documentos. \(error.localizedDescription)"
                    }
                } else {
                    errorMessage = "A importação ficou vinculada a \(context.patientName) no prontuário anterior. Reabra esse destino para conferir os arquivos."
                }
                if let failure = result.failure {
                    documentImportContext = DocumentImportContext(
                        patientID: context.patientID, patientName: context.patientName,
                        vaultURL: context.vaultURL, vaultID: context.vaultID,
                        patientRecord: context.patientRecord, items: result.pending,
                        encounters: context.encounters, preferredEncounterID: encounterID,
                        allowsChangingEncounter: false)
                    let completedMessage = result.completed.count == 1
                        ? "1 documento concluído nesta tentativa."
                        : "\(result.completed.count) documentos concluídos nesta tentativa."
                    documentImportError = "\(completedMessage) \(failure.localizedDescription) Os itens concluídos não serão repetidos."
                } else {
                    documentImportContext = nil
                    noticeMessage = result.completed.count == 1
                        ? "Documento importado e verificado em \(context.patientName)."
                        : "\(result.completed.count) documentos importados e verificados em \(context.patientName)."
                    if summary?.url == context.vaultURL, summary?.manifest.vaultID == context.vaultID {
                        let names = result.completed.map { $0.item.sourceURL.lastPathComponent }.joined(separator: ", ")
                        patientImportReceipts[context.patientID] = "\(noticeMessage ?? "Importação concluída.")\n\(names)"
                    }
                }
            } catch {
                documentImportContext = context
                documentImportError = error.localizedDescription
            }
        }
    }

    private func requestEncounterStart(_ context: EncounterStartContext) {
        guard !isStartingEncounter, !isFinalizing else { return }
        encounterStartError = nil
        beginRequestedEncounter(context)
    }

    private func beginRequestedEncounter(_ context: EncounterStartContext) {
        guard let appointmentID = context.appointmentID else {
            startEncounter(context: context, input: EncounterStartInput(
                modality: .inPerson, template: .blank, telemedicine: nil
            ))
            return
        }
        guard let appointment = summary?.appointments.first(where: { $0.id == appointmentID }),
              appointment.record.patientID == context.patientID else {
            errorMessage = "O agendamento não está disponível. Atualize a agenda e tente novamente."
            return
        }
        if let existing = openConsultationAction(for: appointment) {
            existing()
            return
        }
        startEncounter(context: context, input: .scheduled(appointment.record))
    }

    @MainActor
    private func startEncounter(
        context: EncounterStartContext,
        input: EncounterStartInput
    ) {
        guard !isStartingEncounter, !isFinalizing, let vaultURL = summary?.url else { return }
        let sourceSelection = selection
        isStartingEncounter = true
        Task { @MainActor in
            defer { isStartingEncounter = false }
            guard summary?.url == vaultURL, selection == sourceSelection else { return }
            guard await saveDraft(announcingSuccess: false) else {
                encounterStartError = draftSaveError ?? "Não foi possível salvar. Tente novamente antes de iniciar outra consulta."
                errorMessage = encounterStartError
                return
            }
            guard summary?.url == vaultURL, selection == sourceSelection,
                  refreshVaultBeforeEncounterAction() else { return }
            createEncounter(context: context, input: input)
        }
    }

    @MainActor
    private func createEncounter(
        context: EncounterStartContext,
        input: EncounterStartInput
    ) {
        guard let summary,
              let patient = summary.patients.first(where: { $0.patientID == context.patientID }),
              let authorizationURL,
              summary.writingAllowed else {
            encounterStartError = "O paciente ou o prontuário não está disponível para iniciar a consulta. Reabra o prontuário e tente novamente."
            errorMessage = encounterStartError
            return
        }
        let appointment = context.appointmentID.flatMap { appointmentID in
            summary.appointments.first { $0.id == appointmentID }
        }
        guard context.appointmentID == nil || (appointment != nil && appointment?.record.patientID == context.patientID) else {
            encounterStartError = "O agendamento não está mais disponível para este paciente. Atualize a agenda e tente novamente."
            errorMessage = encounterStartError
            return
        }
        withSecurityScopedAccess(to: authorizationURL) {
            do {
                encounterStartError = nil
                let now = Date()
                let result = try EncounterStartService().start(
                    in: summary,
                    patient: patient,
                    appointment: appointment,
                    identity: try ClinicalDraftCreationIdentity.generate(at: now),
                    input: appointment.map { .scheduled($0.record) } ?? input,
                    startedAt: now
                )
                self.summary = try VaultReader().open(summary.url)
                encounterActivity.activate(
                    patientID: patient.patientID,
                    encounterID: result.encounter.metadata.encounterID
                )
                navigate(to: .encounter(
                    patientID: patient.patientID,
                    encounterID: result.encounter.metadata.encounterID
                ))
                loadDraft(for: selection)
                noticeMessage = result.recoveredPendingLink
                    ? "Consulta recuperada e vínculo da agenda confirmado."
                    : "Consulta criada em estado Rascunho."
            } catch {
                self.summary = try? VaultReader().open(summary.url)
                encounterStartError = error.localizedDescription
                throw error
            }
        }
    }

    @MainActor
    private func recoverAppointmentLink(
        _ appointment: AppointmentSummary,
        patient: PatientSummary
    ) {
        let input = EncounterStartInput(
            modality: appointment.record.modality,
            template: .blank,
            telemedicine: appointment.record.modality == .telemedicine
                ? TelemedicineEncounterInput(
                    consent: .notRecorded,
                    declaredLocation: nil,
                    participants: [],
                    limitations: nil,
                    contingency: nil
                )
                : nil
        )
        startEncounter(
            context: EncounterStartContext(
                patientID: patient.patientID,
                appointmentID: appointment.id
            ),
            input: input
        )
    }

    @discardableResult
    @MainActor
    private func saveDraft(announcingSuccess: Bool) async -> Bool {
        guard hasUnsavedDraft else { return true }
        guard let summary, let patient = selectedPatient, let encounter = selectedEncounter,
              let authorizationURL, summary.writingAllowed, !isSavingDraft else { return false }
        errorMessage = nil
        if announcingSuccess { noticeMessage = nil }
        isSavingDraft = true
        let granted = authorizationURL.startAccessingSecurityScopedResource()
        defer {
            if granted { authorizationURL.stopAccessingSecurityScopedResource() }
            isSavingDraft = false
        }
        await Task.yield()
        guard !Task.isCancelled,
              self.summary?.url == summary.url,
              selectedPatient?.patientID == patient.patientID,
              selectedEncounter?.metadata.encounterID == encounter.metadata.encounterID,
              selectedEncounter?.draft.persistedData == encounter.draft.persistedData else { return false }
        do {
            let body = draftText
            let (saved, reopened) = try await Task.detached {
                let granted = authorizationURL.startAccessingSecurityScopedResource()
                defer { if granted { authorizationURL.stopAccessingSecurityScopedResource() } }
                let saved = try ClinicalDraftSaver().save(
                    encounter: encounter, patientID: patient.patientID, body: body, updatedAt: Date()
                )
                return (saved, try VaultReader().open(summary.url))
            }.value
            // A cancelled debounce task may have already written successfully.
            // Reconcile that save, but never replace another context or the buffer.
            guard self.summary?.url == summary.url,
                  selectedPatient?.patientID == patient.patientID,
                  selectedEncounter?.metadata.encounterID == encounter.metadata.encounterID else { return false }
            self.summary = reopened
            // Persistence normalizes NFC/LF and the final newline. Never feed
            // that representation back into the active editor during a save.
            lastSavedAt = saved.metadata.updatedAt
            draftSaveError = nil
            if announcingSuccess {
                noticeMessage = "Rascunho salvo e relido."
            }
            return true
        } catch {
            draftSaveError = error.localizedDescription
            return false
        }
    }

    /// The continuation must use current disk state even when there was nothing to save.
    @MainActor
    private func refreshVaultBeforeEncounterAction() -> Bool {
        guard let summary, let authorizationURL else { return false }
        let granted = authorizationURL.startAccessingSecurityScopedResource()
        defer { if granted { authorizationURL.stopAccessingSecurityScopedResource() } }
        do {
            let reopened = try VaultReader().open(summary.url)
            if let encounter = selectedEncounter {
                let refreshedEncounter = reopened.patients
                    .first { $0.patientID == encounter.metadata.patientID }?.encounters
                    .first { $0.metadata.encounterID == encounter.metadata.encounterID }
                guard refreshedEncounter == encounter else {
                    throw VaultValidationIssue(
                        rule: "clinical_document.revision_conflict", path: encounter.metadata.encounterID,
                        message: "A consulta mudou no prontuário. Reabra o prontuário antes de continuar."
                    )
                }
            }
            self.summary = reopened
            return true
        } catch {
            errorMessage = error.localizedDescription
            // Saving has already succeeded. Block further edits until disk state can be reopened.
            self.summary = nil
            encounterStartError = error.localizedDescription
            return false
        }
    }

    @MainActor
    private func prepareEncounterDetailsContext(refreshVault: Bool = true) async -> EncounterDetailsContext? {
        guard let vaultURL = summary?.url, let encounter = selectedEncounter,
              encounter.finalizationStatus == .draft, summary?.writingAllowed == true,
              !isSavingDraft, !isFinalizing, !isOpeningEncounterDetails else { return nil }
        let sourceSelection = selection
        isOpeningEncounterDetails = true
        defer { isOpeningEncounterDetails = false }
        guard await saveDraft(announcingSuccess: false) else { return nil }
        guard summary?.url == vaultURL, selection == sourceSelection, (!refreshVault || refreshVaultBeforeEncounterAction()),
              let current = selectedEncounter, current.finalizationStatus == .draft,
              current.metadata.encounterID == encounter.metadata.encounterID,
              let patient = selectedPatient, summary?.writingAllowed == true,
              !hasUnsavedDraft, !isFinalizing, let authorizationURL else { return nil }
        let granted = authorizationURL.startAccessingSecurityScopedResource()
        defer { if granted { authorizationURL.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: current.url)
            guard try ClinicalDocumentValidator.validateEncounter(data: data, source: current.url.path) == current.metadata else {
                throw VaultValidationIssue(rule: "encounter_details.revision_conflict", path: current.url.path,
                                           message: "A consulta mudou. Reabra o prontuário antes de continuar.")
            }
            return EncounterDetailsContext(patient: patient, encounter: current, encounterData: data, vaultURL: vaultURL,
                appointment: summary?.appointments.first { $0.id == current.metadata.appointmentID })
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    @MainActor
    private func openEncounterDetails() {
        let sourceSelection = selection, sourceVault = summary?.url
        Task {
            guard selection == sourceSelection, summary?.url == sourceVault else { return }
            encounterDetailsContext = await prepareEncounterDetailsContext()
        }
    }

    @MainActor
    private func openConfiguredVideoCall() {
        openEncounterRemoteLink()
    }

    @MainActor
    private func openEncounterRemoteLink() {
        let sourceSelection = selection, sourceVault = summary?.url
        Task {
            guard selection == sourceSelection, summary?.url == sourceVault else { return }
            remoteLinkContext = await prepareEncounterDetailsContext()
        }
    }

    private func requestModalityChange(_ modality: AppointmentModality) {
        guard let encounter = selectedEncounter, modality.rawValue != encounter.metadata.modality else { return }
        let facts = encounter.metadata.telemedicine
        if modality == .inPerson, let facts,
           facts.consent != .notRecorded || facts.declaredLocation != nil || !facts.participants.isEmpty
            || facts.limitations != nil || facts.contingency != nil {
            let sourceSelection = selection, sourceVault = summary?.url
            Task { @MainActor in
                guard selection == sourceSelection, summary?.url == sourceVault else { return }
                pendingModalityContext = await prepareEncounterDetailsContext()
            }
        } else { changeEncounterModality(modality) }
    }

    @MainActor
    private func changeEncounterModality(_ modality: AppointmentModality) {
        guard !isChangingModality else { return }
        let sourceSelection = selection, sourceVault = summary?.url
        isChangingModality = true
        Task {
            defer { isChangingModality = false }
            await Task.yield()
            guard selection == sourceSelection, summary?.url == sourceVault else { return }
            // The writer revalidates the whole vault and exact snapshot under coordination.
            // Keep its authoritative read and the post-write read; avoid a third full scan here.
            guard let context = await prepareEncounterDetailsContext(refreshVault: false) else { return }
            do { try saveEncounterDetails(detailsInput(context.encounter.metadata, modality: modality), context: context) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func detailsInput(_ metadata: EncounterMetadata, modality: AppointmentModality? = nil) -> EncounterDetailsInput {
        let selected = modality ?? AppointmentModality(rawValue: metadata.modality) ?? .inPerson
        let facts = metadata.telemedicine
        return EncounterDetailsInput(modality: selected, telemedicine: selected == .telemedicine
            ? TelemedicineEncounterInput(consent: facts?.consent ?? .notRecorded,
                declaredLocation: facts?.declaredLocation, participants: facts?.participants ?? [],
                limitations: facts?.limitations, contingency: facts?.contingency) : nil)
    }

    @MainActor
    private func saveEncounterDetails(_ input: EncounterDetailsInput, context: EncounterDetailsContext) throws {
        guard let summary, summary.url == context.vaultURL, summary.writingAllowed,
              let authorizationURL, selectedPatient?.patientID == context.patient.patientID,
              selectedEncounter == context.encounter, !hasUnsavedDraft,
              !isSavingDraft, !isFinalizing else {
            throw VaultValidationIssue(rule: "encounter_details.context", path: context.encounter.url.path,
                                       message: "A consulta mudou. Cancele e reabra os detalhes antes de salvar.")
        }
        let granted = authorizationURL.startAccessingSecurityScopedResource()
        defer { if granted { authorizationURL.stopAccessingSecurityScopedResource() } }
        _ = try EncounterDetailsWriter().save(in: summary, patient: context.patient,
                                              encounter: context.encounter, expectedData: context.encounterData, input: input)
        do {
            self.summary = try VaultReader().open(summary.url)
            loadDraft(for: selection)
            encounterDetailsContext = nil
            noticeMessage = "Detalhes do atendimento salvos."
        } catch {
            // Details were written, but further edits need a fresh verified snapshot.
            self.summary = nil
            throw VaultValidationIssue(rule: "encounter_details.reopen", path: summary.url.path,
                                       message: "Os detalhes foram gravados, mas o prontuário não pôde ser relido. Cancele e reabra o prontuário.")
        }
    }

    private func encounterRemoteLink(_ encounter: EncounterSummary) -> String? {
        if let appointmentID = encounter.metadata.appointmentID {
            return summary?.appointments.first { $0.id == appointmentID }?.record.remoteAccessURL
        }
        return encounter.metadata.remoteAccessURL
    }

    @MainActor
    private func saveEncounterRemoteLink(_ link: String, context: EncounterDetailsContext) throws {
        guard let summary, summary.url == context.vaultURL, summary.writingAllowed,
              selectedEncounter == context.encounter, !hasUnsavedDraft,
              !isFinalizing, let authorizationURL else {
            throw VaultValidationIssue(rule: "encounter_link.context", path: context.id,
                message: "A consulta mudou. Copie o link gerado e reabra o formulário para salvá-lo.")
        }
        let granted = authorizationURL.startAccessingSecurityScopedResource()
        defer { if granted { authorizationURL.stopAccessingSecurityScopedResource() } }
        let validated = try TelemedicineURLBuilder.savedLinkURL(link).absoluteString
        if let saved = encounterRemoteLink(context.encounter) {
            guard saved == validated else {
                throw VaultValidationIssue(rule: "encounter_link.fixed", path: context.id,
                    message: "Esta consulta já tem um link vinculado.")
            }
            return
        }
        if let appointment = context.appointment {
            let current = try VaultReader().open(summary.url)
            guard current.writingAllowed,
                  let patient = current.patients.first(where: { $0.patientID == context.patient.patientID }),
                  patient.encounters.contains(context.encounter),
                  try Data(contentsOf: context.encounter.url) == context.encounterData,
                  current.appointments.first(where: { $0.id == appointment.id })?.record == appointment.record,
                  appointment.record.encounterID == context.id else {
                throw VaultValidationIssue(rule: "encounter_link.changed", path: context.id,
                    message: "O agendamento ou a consulta mudou. Copie o link e reabra o formulário.")
            }
            let record = appointment.record
            _ = try AppointmentWriter().update(appointment, in: summary.url, patients: current.patients,
                input: AppointmentInput(patientID: record.patientID, startsAt: record.startDate, endsAt: record.endDate,
                    timeZone: record.timeZone, modality: record.modality, status: record.status,
                    location: record.location, remoteAccessURL: validated, administrativeNote: record.administrativeNote,
                    telemedicineConsentConfirmed: record.telemedicineConsentConfirmed))
        } else {
            guard context.encounter.metadata.appointmentID == nil else {
                throw VaultValidationIssue(rule: "encounter_link.appointment", path: context.id,
                    message: "O agendamento não está disponível. Copie o link e reabra a consulta.")
            }
            _ = try EncounterDetailsWriter().save(in: summary, patient: context.patient, encounter: context.encounter,
                expectedData: context.encounterData, input: detailsInput(context.encounter.metadata, modality: .telemedicine), remoteAccessURL: validated)
        }
        do {
            self.summary = try VaultReader().open(summary.url)
            loadDraft(for: selection)
        } catch {
            self.summary = nil
            throw VaultValidationIssue(rule: "encounter_link.reopen", path: context.id,
                message: "O link foi gravado, mas não foi possível reler o prontuário. Copie o link e reabra o prontuário.")
        }
    }

    @MainActor
    private func performRemoteLinkAction(_ link: String, action: EncounterRemoteLinkAction,
                                         context: EncounterDetailsContext) throws {
        if context.encounter.metadata.appointmentID != nil {
            guard let appointment = context.appointment,
                  appointment.record.patientID == context.patient.patientID,
                  appointment.record.encounterID == context.id,
                  appointment.record.modality == .telemedicine,
                  supportsRemoteHandoff(appointment.record.status) else {
                throw VaultValidationIssue(rule: "encounter_link.appointment_unavailable", path: context.id,
                    message: "O estado ou vínculo do agendamento não permite entrar ou enviar o link. Confira a agenda.")
            }
        }
        guard let current = selectedEncounter, current.metadata.encounterID == context.id,
              summary?.url == context.vaultURL, encounterRemoteLink(current) == link else {
            throw VaultValidationIssue(rule: "encounter_link.changed", path: context.id,
                message: "O vínculo da consulta mudou. Reabra a videochamada.")
        }
        pendingRemoteLinkAction = (context, action)
        remoteLinkContext = nil
    }

    @MainActor
    private func completeRemoteLinkAction() {
        guard let (context, action) = pendingRemoteLinkAction else { return }
        pendingRemoteLinkAction = nil
        guard let current = summary, current.url == context.vaultURL,
              selectedEncounter?.metadata.encounterID == context.id,
              let patient = current.patients.first(where: { $0.patientID == context.patient.patientID }),
              let encounter = patient.encounters.first(where: { $0.metadata.encounterID == context.id }) else { return }
        if let appointmentID = encounter.metadata.appointmentID {
            guard let appointment = current.appointments.first(where: { $0.id == appointmentID }),
                  appointment.record.patientID == patient.patientID,
                  appointment.record.encounterID == encounter.metadata.encounterID,
                  appointment.record.modality == .telemedicine,
                  supportsRemoteHandoff(appointment.record.status) else {
                errorMessage = "O estado ou vínculo do agendamento mudou. Confira a agenda antes de entrar ou enviar o link."
                return
            }
            let share = WhatsAppShareContext(appointment: appointment, patient: patient, consultationOpen: true)
            switch action {
            case .enter: openSavedRemoteLink(appointmentID)
            case .whatsApp: whatsAppShareContext = share
            case .email: emailShareContext = share
            }
        } else if let savedLink = encounter.metadata.remoteAccessURL {
            let share = EncounterLinkShareContext(patient: patient, encounter: encounter,
                                                   vaultURL: current.url, link: savedLink)
            switch action {
            case .enter:
                withCurrentEncounterLink(share) { _, url in
                    guard NSWorkspace.shared.open(url) else {
                        throw VaultValidationIssue(rule: "encounter_link.open", path: context.id,
                            message: "O macOS não abriu o link. Copie e abra no navegador.")
                    }
                }
            case .whatsApp: encounterWhatsAppContext = share
            case .email: encounterEmailContext = share
            }
        }
    }

    @ViewBuilder
    private func encounterRemoteButtons(_ context: EncounterLinkShareContext) -> some View {
        Button("Entrar", systemImage: "video") {
            withCurrentEncounterLink(context) { _, link in
                guard NSWorkspace.shared.open(link) else {
                    throw VaultValidationIssue(rule: "encounter_link.open", path: context.id,
                        message: "O macOS não abriu o link. Copie e abra no navegador.")
                }
            }
        }.buttonStyle(.borderedProminent)
        Menu("Enviar", systemImage: "paperplane") {
            Button("WhatsApp…") { encounterWhatsAppContext = context }
            Button("E-mail…") { encounterEmailContext = context }
        }
        Button("Copiar link", systemImage: "doc.on.doc") {
            withCurrentEncounterLink(context) { _, link in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.absoluteString, forType: .string)
            }
        }
    }

    @MainActor
    private func withCurrentEncounterLink(_ context: EncounterLinkShareContext,
                                          action: (PatientSummary, URL) throws -> Void) {
        guard let summary, summary.url == context.vaultURL, let authorizationURL else { return }
        withSecurityScopedAccess(to: authorizationURL) {
            let current = try VaultReader().open(context.vaultURL)
            guard current.writingAllowed,
                  let patient = current.patients.first(where: { $0.patientID == context.patient.patientID }),
                  patient.displayName == context.patient.displayName,
                  let encounter = patient.encounters.first(where: { $0.metadata.encounterID == context.id }),
                  encounter.metadata == context.encounter.metadata,
                  encounter.metadata.modality == "telemedicine",
                  encounter.metadata.remoteAccessURL == context.link else {
                throw VaultValidationIssue(rule: "encounter_link.changed", path: context.id,
                    message: "A consulta, o contato ou o link mudou. Reabra e confira antes de continuar.")
            }
            if case .altered = encounter.finalizationStatus {
                throw VaultValidationIssue(rule: "encounter_link.altered", path: context.id,
                    message: "A consulta apresenta uma divergência. Reabra o prontuário antes de continuar.")
            }
            try action(patient, TelemedicineURLBuilder.savedLinkURL(context.link))
        }
    }

    @MainActor
    private func shareEncounterWhatsApp(_ context: EncounterLinkShareContext, contactID: String,
                                        destination: WhatsAppDestination, proposal: WhatsAppShare) {
        withCurrentEncounterLink(context) { patient, link in
            let current = try WhatsAppShare(patient: patient, contactID: contactID,
                                            link: link.absoluteString, destination: destination)
            guard current == proposal else {
                throw VaultValidationIssue(rule: "whatsapp.changed", path: context.id,
                    message: "O contato mudou. Reabra o compartilhamento antes de continuar.")
            }
            guard NSWorkspace.shared.open(current.url) else {
                throw VaultValidationIssue(rule: "whatsapp.unavailable", path: context.id,
                    message: "O macOS não abriu o WhatsApp. Tente WhatsApp Web ou copie o link.")
            }
            encounterWhatsAppContext = nil
            noticeMessage = "Revise e envie a mensagem no WhatsApp."
        }
    }

    @MainActor
    private func composeEncounterEmail(_ context: EncounterLinkShareContext, contactID: String, recipient: String) {
        withCurrentEncounterLink(context) { patient, link in
            guard ConsultationInvitation.emailContacts(for: patient).contains(where: {
                $0.id == contactID && $0.destination == recipient
            }) else {
                throw VaultValidationIssue(rule: "invitation.changed", path: context.id,
                    message: "O contato mudou. Reabra o convite antes de continuar.")
            }
            let body = ConsultationInvitation.attributedBody("Olá, segue o link para nossa consulta: \(link.absoluteString)", link: link)
            guard let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: [body]) else {
                throw VaultValidationIssue(rule: "invitation.mail_unavailable", path: context.id,
                    message: "Configure o Mail ou use WhatsApp ou Copiar link.")
            }
            service.recipients = [recipient]
            service.subject = "Link para nossa consulta"
            emailSharingService = service
            service.perform(withItems: [body])
            encounterEmailContext = nil
            noticeMessage = "Revise e envie o convite no Mail."
        }
    }

    @MainActor
    private func discardSelectedDraft() {
        guard !transcriptionBlocksSelectedEncounter else { return }
        let sourceSelection = selection, sourceVault = summary?.url
        Task {
            guard selection == sourceSelection, summary?.url == sourceVault else { return }
            guard let context = await prepareEncounterDetailsContext(), let summary,
                  let authorizationURL else { return }
            let granted = authorizationURL.startAccessingSecurityScopedResource()
            defer { if granted { authorizationURL.stopAccessingSecurityScopedResource() } }
            do {
                let trashed = try DraftTrashService().discard(in: summary, patient: context.patient,
                    encounter: context.encounter, expectedData: context.encounterData, at: Date())
                self.summary = try VaultReader().open(summary.url)
                encounterActivity.finish(patientID: context.patient.patientID, encounterID: context.id)
                navigate(to: .patient(context.patient.patientID))
                // A discarded encounter must not remain reachable with Back/Forward.
                backHistory.removeAll { $0 == sourceSelection }
                forwardHistory.removeAll { $0 == sourceSelection }
                loadDraft(for: selection)
                noticeMessage = trashed ? "Rascunho enviado à Lixeira. Você pode restaurar a consulta e seus documentos em Configurações → Lixeira."
                    : "Rascunho vazio excluído."
            } catch {
                errorMessage = error.localizedDescription
                // Save succeeded before discard; refresh any safely completed unlink/rollback.
                self.summary = try? VaultReader().open(summary.url)
            }
        }
    }

    @MainActor
    private func openDraftTrash() {
        guard let vaultURL = summary?.url else { return }
        Task {
            guard await saveDraftBeforeNavigation(), summary?.url == vaultURL,
                  let authorizationURL else { return }
            withSecurityScopedAccess(to: authorizationURL) {
                self.summary = try VaultReader().open(vaultURL)
                showsDraftTrash = true
            }
        }
    }

    @MainActor
    private func restoreDraft(_ patient: PatientSummary, _ encounter: EncounterSummary) throws {
        guard let summary, let authorizationURL else { return }
        let granted = authorizationURL.startAccessingSecurityScopedResource()
        defer { if granted { authorizationURL.stopAccessingSecurityScopedResource() } }
        do {
            try DraftTrashService().restore(in: summary, patient: patient, encounter: encounter,
                                           expectedData: Data(contentsOf: encounter.url))
            self.summary = try VaultReader().open(summary.url)
            noticeMessage = "Rascunho restaurado no paciente."
        } catch {
            self.summary = try? VaultReader().open(summary.url)
            throw error
        }
    }

    @MainActor
    private func openEncounterTranscription() {
        guard let patient = selectedPatient, let encounter = selectedEncounter,
            let vault = summary, vault.writingAllowed, encounter.finalizationStatus == .draft,
            !isSavingDraft, !isFinalizing, !isOpeningConsultationSummary
        else { return }
        let sourceSelection = selection
        isOpeningConsultationSummary = true
        Task { @MainActor in
            defer { isOpeningConsultationSummary = false }
            guard summary?.url == vault.url, selection == sourceSelection,
                await saveDraft(announcingSuccess: false),
                summary?.url == vault.url, selection == sourceSelection,
                refreshVaultBeforeEncounterAction(),
                let currentPatient = selectedPatient, currentPatient.patientID == patient.patientID,
                let current = selectedEncounter, current.metadata.encounterID == encounter.metadata.encounterID,
                current.finalizationStatus == .draft
            else { return }
            let binding = EncounterTranscriptionBinding(
                vaultURL: vault.url,
                vaultID: vault.manifest.vaultID, patientID: currentPatient.patientID,
                encounterID: current.metadata.encounterID, patientName: currentPatient.displayName)
            guard prepareTranscriptionSession(binding: binding) else {
                noticeMessage = transcriptionSession.status
                transcriptionStartIssue = transcriptionSession.status
                return
            }
            do {
                _ = try configuredRecordingFolder()
                if configuredTranscriptionMode == .openAILive && !allowsOpenAILiveTranscription {
                    throw AITextSettingsIssue.transcriptionDisabled
                }
                if configuredSummaryProvider == .openAI && !allowsOpenAIConsultationSummary {
                    throw AITextSettingsIssue.summaryDisabled
                }
                await startConfiguredTranscription(binding: binding)
            } catch {
                noticeMessage = error.localizedDescription
                transcriptionStartIssue = error.localizedDescription
            }
        }
    }

    @MainActor
    private func startConfiguredTranscription(binding: EncounterTranscriptionBinding) async {
        guard transcriptionSession.binding == binding, !transcriptionSession.isBusy,
              selectedEncounter?.metadata.encounterID == binding.encounterID,
              selectedEncounter?.finalizationStatus == .draft else { return }
        // The clinician's click starts this bound session. It does not create a consent document.
        do {
            let folder = try configuredRecordingFolder()
            let usesWAV = configuredCaptureSource == .telecall || configuredTranscriptionMode.isLive
            let destination = ConsultationCaptureSettings.newRecordingURL(
                in: folder,
                usesWAV: usesWAV
            )
            let source: ConsultationCaptureSource = configuredCaptureSource == .microphone ? .microphone : .telecall
            transcriptionSession.configureProgressive(
                .init(
                    source: source,
                    transcriptionMode: configuredTranscriptionMode,
                    summaryIntervalSeconds: summaryIntervalMinutes * 60,
                    summaryProvider: configuredSummaryProvider,
                    summaryModel: configuredSummaryProvider == .openAI ? consultationSummaryModel : nil
                ))

            if source == .microphone {
                await transcriptionSession.startRecording(at: destination, consent: true, authorizationURL: authorizationURL)
            } else {
                await transcriptionSession.startTelecallRecording(
                    at: destination, application: .allSystemAudio, consent: true, authorizationURL: authorizationURL)
            }
            if transcriptionSession.progressiveWork != nil {
                transcriptionPanelCollapsed = false
            }
            noticeMessage = transcriptionSession.status
        } catch {
            noticeMessage = error.localizedDescription
            transcriptionStartIssue = error.localizedDescription
        }
    }

    private var transcriptionBlocksSelectedEncounter: Bool {
        guard let binding = transcriptionSession.binding else { return false }
        return binding.vaultURL == summary?.url && binding.vaultID == summary?.manifest.vaultID
            && binding.patientID == selectedPatient?.patientID
            && binding.encounterID == selectedEncounter?.metadata.encounterID
            && (transcriptionSession.isBusy || transcriptionSession.hasUnsavedText)
    }

    @MainActor
    private func prepareTranscriptionSession(binding: EncounterTranscriptionBinding) -> Bool {
        guard let authorizationURL else { return false }
        return transcriptionSession.prepare(
            binding: binding,
            onPersist: { input, identity, savedAt in
                try persistEncounterTranscript(input, identity: identity, savedAt: savedAt, binding: binding)
            },
            onLoadWork: {
                let granted = authorizationURL.startAccessingSecurityScopedResource()
                defer { if granted { authorizationURL.stopAccessingSecurityScopedResource() } }
                let store = ProgressiveConsultationWorkStore()
                guard let document = try store.load(binding: binding),
                      let data = try store.data(binding: binding) else { return nil }
                return (document, data)
            },
            onPersistWork: { document, expectedData in
                let granted = authorizationURL.startAccessingSecurityScopedResource()
                defer { if granted { authorizationURL.stopAccessingSecurityScopedResource() } }
                return try ProgressiveConsultationWorkStore().save(
                    document,
                    binding: binding,
                    expectedData: expectedData
                )
            },
            onValidateCapture: {
                let granted = authorizationURL.startAccessingSecurityScopedResource()
                defer { if granted { authorizationURL.stopAccessingSecurityScopedResource() } }
                let vault = try VaultReader().open(binding.vaultURL)
                guard vault.writingAllowed, vault.manifest.vaultID == binding.vaultID,
                      let patient = vault.patients.first(where: { $0.patientID == binding.patientID }),
                      let encounter = patient.encounters.first(where: { $0.metadata.encounterID == binding.encounterID }),
                      encounter.finalizationStatus == .draft else {
                    throw VaultValidationIssue(rule: "transcription.encounter_closed", path: binding.encounterID,
                        message: "Esta consulta não permite gravação. Para complementar uma consulta finalizada, crie um adendo.")
                }
            }
        )
    }

    @MainActor
    private func prepareProgressiveSessionForSelection() {
        guard let vault = summary, vault.writingAllowed,
              let patient = selectedPatient, let encounter = selectedEncounter,
              encounter.finalizationStatus == .draft else { return }
        let binding = EncounterTranscriptionBinding(
            vaultURL: vault.url,
            vaultID: vault.manifest.vaultID,
            patientID: patient.patientID,
            encounterID: encounter.metadata.encounterID,
            patientName: patient.displayName
        )
        if let current = transcriptionSession.binding, current != binding { return }
        _ = prepareTranscriptionSession(binding: binding)
    }

    private func returnToRecordingEncounter() {
        guard let binding = transcriptionSession.binding,
              binding.vaultURL == summary?.url, binding.vaultID == summary?.manifest.vaultID else { return }
        Task { @MainActor in
            guard await saveDraftBeforeNavigation(), binding.vaultURL == summary?.url,
                  binding.vaultID == summary?.manifest.vaultID else { return }
            navigate(to: .encounter(patientID: binding.patientID, encounterID: binding.encounterID))
        }
    }

    private func showProgressiveSummary() {
        transcriptionPanelCollapsed = false
        returnToRecordingEncounter()
    }

    @MainActor
    private func persistEncounterTranscript(_ input: EncounterTranscriptInput, identity: RawAssetCreationIdentity,
                                           savedAt: Date, binding: EncounterTranscriptionBinding) throws {
        guard let summary, summary.writingAllowed, let authorizationURL,
              summary.url == binding.vaultURL,
              summary.manifest.vaultID == binding.vaultID else { throw PatientAIIssue.changed }
        let granted = authorizationURL.startAccessingSecurityScopedResource()
        defer { if granted { authorizationURL.stopAccessingSecurityScopedResource() } }
        _ = try EncounterTranscriptStore().saveToCurrentEncounter(in: binding.vaultURL,
            vaultID: binding.vaultID, patientID: binding.patientID, encounterID: binding.encounterID,
            input: input, identity: identity, deviceID: summary.manifest.deviceID, savedAt: savedAt)
        self.summary = try VaultReader().open(summary.url)
    }

    @MainActor
    private func openConsultationSummary() {
        guard let vaultURL = summary?.url, let patient = selectedPatient,
              let encounter = selectedEncounter, summary?.writingAllowed == true,
              encounter.finalizationStatus == .draft,
              encounter.draft.metadata.schema == "openpep/clinical-note@1",
              !isSavingDraft, !isFinalizing, !isOpeningConsultationSummary else { return }
        let sourceSelection = selection
        isOpeningConsultationSummary = true
        Task { @MainActor in
            defer { isOpeningConsultationSummary = false }
            guard summary?.url == vaultURL, selection == sourceSelection else { return }
            guard await saveDraft(announcingSuccess: false) else { return }
            guard summary?.url == vaultURL, selection == sourceSelection,
                  refreshVaultBeforeEncounterAction() else { return }
            guard let current = summary, current.url == vaultURL, current.writingAllowed,
                  selection == sourceSelection,
                  let currentPatient = selectedPatient, currentPatient.patientID == patient.patientID,
                  let currentEncounter = selectedEncounter,
                  currentEncounter.metadata.encounterID == encounter.metadata.encounterID,
                  currentEncounter.finalizationStatus == .draft,
                  currentEncounter.draft.metadata.schema == "openpep/clinical-note@1",
                  !hasUnsavedDraft, !isFinalizing else { return }
            consultationSummaryContext = ConsultationSummaryContext(
                patient: currentPatient, encounter: currentEncounter, vaultURL: current.url
            )
        }
    }

    @MainActor
    private func openPatientHistoryEntry(_ entry: PatientHistoryEntry, context: PatientHistoryContext) {
        guard summary?.url == context.vaultURL else { return }
        if let assetID = entry.assetID {
            previewDocument(patientID: context.patientID, assetID: assetID)
        } else if let patient = summary?.patients.first(where: { $0.patientID == context.patientID }),
                  let encounter = patient.encounters.first(where: { encounter in
                      if encounter.metadata.encounterID == entry.id { return true }
                      if case let .verified(finalization) = encounter.finalizationStatus {
                          return finalization.addenda.contains { $0.metadata.addendumID == entry.id }
                      }
                      return false
                  }) {
            requestNavigation(to: .encounter(patientID: context.patientID, encounterID: encounter.metadata.encounterID))
        }
    }

    @MainActor
    private func openPatientHistory(_ patient: PatientSummary, fromAssistant: Bool = false) {
        guard let vaultURL = summary?.url, let authorizationURL else { return }
        let sourceSelection = selection
        Task { @MainActor in
            guard summary?.url == vaultURL, selection == sourceSelection,
                  await saveDraft(announcingSuccess: false),
                  summary?.url == vaultURL, selection == sourceSelection,
                  refreshVaultBeforeEncounterAction(),
                  let currentPatient = summary?.patients.first(where: { $0.patientID == patient.patientID }) else { return }
            guard !fromAssistant || (!currentPatient.isArchived && currentPatient.record == patient.record) else {
                errorMessage = AssistantIssue.changed.localizedDescription
                return
            }
            patientHistoryContext = PatientHistoryContext(patientID: currentPatient.patientID,
                patientName: currentPatient.displayName, vaultURL: vaultURL, authorizationURL: authorizationURL,
                insertionEncounter: selectedPatient?.patientID == patient.patientID && selectedEncounter?.finalizationStatus == .draft ? selectedEncounter : nil)
        }
    }

    @MainActor
    private func acceptPatientAIAnswer(_ answer: PatientAIAnswer, text: String, context: PatientHistoryContext) throws {
        guard let summary, summary.writingAllowed, let encounter = context.insertionEncounter,
              summary.url == context.vaultURL, selectedPatient?.patientID == context.patientID,
              selectedEncounter?.metadata.encounterID == encounter.metadata.encounterID,
              selectedEncounter?.draft.persistedData == encounter.draft.persistedData,
              ClinicalDraftSaver.matchesPersistedBody(draftText, encounter.draft.body), !isSavingDraft, !isFinalizing else {
            throw PatientAIIssue.changed
        }
        let granted = context.authorizationURL.startAccessingSecurityScopedResource()
        defer { if granted { context.authorizationURL.stopAccessingSecurityScopedResource() } }
        let current = try PatientAIContext.load(context: context, corrections: answer.corrections, includeDrafts: true)
        let wiki = try PatientWikiStore().load(for: current.patient)
        guard current.writingAllowed, current.fingerprint == answer.sourceFingerprint, wiki.correctionsIssue == nil,
              (wiki.corrections?.markdown ?? "") == answer.corrections else { throw PatientAIIssue.changed }
        try answer.wikiReadingSnapshot?.revalidate(context: context)
        let draft = try PatientAIInsertionService().insert(result: answer.result, sourceText: answer.sourceText,
            acceptedText: text, generationID: answer.generationID, promptVersion: answer.promptVersion,
            into: encounter,
            patient: current.patient, deviceID: summary.manifest.deviceID, updatedAt: Date())
        self.summary = try VaultReader().open(summary.url)
        draftText = draft.body
        lastSavedAt = draft.metadata.updatedAt
        draftSaveError = nil
        patientHistoryContext = nil
        noticeMessage = "Proposta aceita no rascunho, com fonte e modelo preservados."
    }

    @MainActor
    private func documentReviewSummary() -> String {
        guard let patient = selectedPatient, let encounter = selectedEncounter,
              let page = try? LinearConsultationPage(body: draftText) else { return "" }
        let granted = authorizationURL?.startAccessingSecurityScopedResource() ?? false
        defer { if granted { authorizationURL?.stopAccessingSecurityScopedResource() } }
        let record = DocumentReviewRecord.read(patient: patient, encounterID: encounter.metadata.encounterID)
        let identity = DoctorProfileStore.load().documentIdentity
        let lines = ConsultationTextSection.documentSections.compactMap { section -> String? in
            guard let kind = section.kind, let text = page.text(for: kind),
                  DocumentPages.split(text).contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
            let title = section == .custom && !page.customTitle.isEmpty ? page.customTitle : kind.documentTitle
            let fingerprint = DocumentReviewRecord.fingerprint(section: section, text: title + "\n" + text,
                patientName: patient.record?.fullName ?? patient.displayName, identity: identity)
            if section == .prescription, text.contains(UnifiedPrescription.marker) { return "Receita: confira os documentos na aba Receita" }
            return section.label + (record.fingerprints[section.rawValue] == fingerprint ? ": aprovado" : ": revisão pendente")
        }
        return lines.isEmpty ? "Nenhum documento criado. Deseja gerar algum antes de finalizar?" : lines.joined(separator: "\n")
    }

    @MainActor
    private func approveConsultationDocuments(_ documents: [ConsultationDocumentPreview]) async throws -> [URL] {
        guard let patient = selectedPatient, let encounter = selectedEncounter, let vault = summary,
              vault.writingAllowed, encounter.finalizationStatus == .draft else { throw ConsultationFieldsError.ambiguous }
        let body = draftText
        guard await saveDraft(announcingSuccess: false), draftText == body,
              summary?.url == vault.url, selectedPatient?.record == patient.record,
              selectedPatient?.patientID == patient.patientID,
              selectedEncounter?.metadata.encounterID == encounter.metadata.encounterID,
              selectedEncounter?.finalizationStatus == .draft else { throw ConsultationFieldsError.ambiguous }
        let current = try ConsultationDocumentPreview.make(bodyText: body,
            patientName: patient.record?.fullName ?? patient.displayName,
            professional: DocumentProfessionalSettings.signature, doctorIdentity: DoctorProfileStore.load().documentIdentity)
        guard !documents.isEmpty, DocumentReviewSelection.matches(documents, current: current) else {
            throw VaultValidationIssue(rule: "document_review.changed", path: "", message: "O conteúdo ou os dados do médico mudaram. Abra a revisão novamente.")
        }
        var urls: [URL] = []
        for document in documents {
            let url = try archivePreparedDocument(document.prepared, patientID: patient.patientID,
                encounterID: encounter.metadata.encounterID, expectedVault: vault.url,
                expectedVaultID: vault.manifest.vaultID, expectedPatientRecord: patient.record,
                expectedEncounter: selectedEncounter)
            urls.append(url)
        }
        let granted = authorizationURL?.startAccessingSecurityScopedResource() ?? false
        defer { if granted { authorizationURL?.stopAccessingSecurityScopedResource() } }
        var record = DocumentReviewRecord.read(patient: patient, encounterID: encounter.metadata.encounterID)
        for document in documents { record.fingerprints[document.section.rawValue] = document.fingerprint }
        try record.save(patient: patient, encounterID: encounter.metadata.encounterID)
        return urls
    }

    private func prepareConsultationDocument(title: String, body: String) async throws {
        guard let patient = selectedPatient, let encounter = selectedEncounter, let summary,
              encounter.finalizationStatus == .draft else {
            throw VaultValidationIssue(rule: "consultation_document.context_changed", path: "",
                message: "Abra a consulta em rascunho antes de preparar o documento.")
        }
        let vaultURL = summary.url, vaultID = summary.manifest.vaultID
        let capturedText = draftText
        guard await saveDraft(announcingSuccess: false),
              self.summary?.url == vaultURL, self.summary?.manifest.vaultID == vaultID,
              selectedPatient?.patientID == patient.patientID,
              selectedPatient?.record == patient.record,
              selectedEncounter?.metadata.encounterID == encounter.metadata.encounterID,
              selectedEncounter?.finalizationStatus == .draft,
              draftText == capturedText, !hasUnsavedDraft else {
            throw VaultValidationIssue(rule: "consultation_document.save", path: encounter.metadata.encounterID,
                message: draftSaveError ?? "Aguarde o salvamento e tente imprimir novamente.")
        }
        let cached = pendingDocumentPreparation
        if cached?.vaultURL != vaultURL || cached?.vaultID != vaultID ||
            cached?.patientID != patient.patientID || cached?.patientRecord != patient.record ||
            cached?.encounterID != encounter.metadata.encounterID ||
            cached?.document.title != title || cached?.document.sourceText != body ||
            cached?.document.doctorIdentity != DoctorProfileStore.load().documentIdentity {
            let now = Date()
            let data = try ClinicalDocumentPDF.make(title: title,
                patientName: patient.record?.fullName ?? patient.displayName, professional: DocumentProfessionalSettings.signature, body: body, doctorIdentity: DoctorProfileStore.load().documentIdentity, date: now)
            pendingDocumentPreparation = PreparedConsultationDocumentContext(
                document: try PreparedClinicalDocument(title: title, data: data, sourceText: body, professional: DocumentProfessionalSettings.signature, doctorIdentity: DoctorProfileStore.load().documentIdentity, createdAt: now),
                patientID: patient.patientID, encounterID: encounter.metadata.encounterID,
                vaultURL: vaultURL, vaultID: vaultID, patientRecord: patient.record)
        }
        guard let pending = pendingDocumentPreparation else { return }
        try archivePreparedDocument(pending.document, patientID: patient.patientID,
            encounterID: encounter.metadata.encounterID, expectedVault: vaultURL, expectedVaultID: vaultID,
            expectedPatientRecord: patient.record, expectedEncounter: selectedEncounter)
        preparedConsultationDocument = pending
    }

    @MainActor
    @discardableResult
    private func archivePreparedDocument(_ document: PreparedClinicalDocument, patientID: String, encounterID: String?,
        expectedVault: URL, expectedVaultID: String, expectedPatientRecord: PatientRecord?,
        expectedEncounter: EncounterSummary? = nil) throws -> URL {
        guard let summary, let authorizationURL, summary.writingAllowed,
              summary.manifest.vaultID == expectedVaultID,
              summary.url.standardizedFileURL == expectedVault.standardizedFileURL else {
            throw VaultValidationIssue(rule: "consultation_fields.read_only", path: patientID, message: "O prontuário está somente para leitura.")
        }
        let granted = authorizationURL.startAccessingSecurityScopedResource()
        defer { if granted { authorizationURL.stopAccessingSecurityScopedResource() } }
        let current = try VaultReader().open(summary.url)
        guard current.writingAllowed, current.manifest.vaultID == expectedVaultID,
              let patient = current.patients.first(where: { $0.patientID == patientID }),
              !patient.isArchived, patient.record == expectedPatientRecord else {
            throw VaultValidationIssue(rule: "consultation_fields.patient_unavailable", path: patientID, message: "O paciente não está disponível para guardar o PDF.")
        }
        if let encounterID {
            guard let encounter = patient.encounters.first(where: { $0.metadata.encounterID == encounterID }),
                  encounter.finalizationStatus == .draft, encounter == expectedEncounter else {
                throw VaultValidationIssue(rule: "consultation_document.context_changed", path: encounterID,
                    message: "A consulta mudou. Confira a edição antes de preparar o documento novamente.")
            }
        }
        let archived = try ClinicalDocumentArchiver().archive(document, patient: patient, encounterID: encounterID,
            deviceID: current.manifest.deviceID, expectedVaultID: expectedVaultID)
        self.summary = try VaultReader().open(current.url)
        return archived.pdf.originalURL
    }

    @MainActor
    private func reloadDraftFromVault() {
        guard let summary, let authorizationURL else { return }
        withSecurityScopedAccess(to: authorizationURL) {
            self.summary = try VaultReader().open(summary.url)
            loadDraft(for: selection)
            draftSaveError = nil
            noticeMessage = "Versão persistida recarregada."
        }
    }

    @MainActor
    private func insertConsultationSummary(
        _ proposal: ConsultationSummaryProposal,
        context: ConsultationSummaryContext
    ) throws {
        guard let summary, let authorizationURL, summary.writingAllowed,
              summary.url.standardizedFileURL == context.vaultURL.standardizedFileURL,
              selectedPatient?.patientID == context.patient.patientID,
              selectedEncounter?.metadata.encounterID == context.encounter.metadata.encounterID,
              selectedEncounter?.draft.persistedData == context.encounter.draft.persistedData,
              ClinicalDraftSaver.matchesPersistedBody(draftText, context.encounter.draft.body),
              !isSavingDraft, !isFinalizing else {
            throw VaultValidationIssue(
                rule: "ai_summary.context_changed", path: context.encounter.metadata.encounterID,
                message: "A consulta ou o rascunho mudou. Feche a proposta e reabra a consulta antes de inserir."
            )
        }
        let granted = authorizationURL.startAccessingSecurityScopedResource()
        defer { if granted { authorizationURL.stopAccessingSecurityScopedResource() } }
        let result = try ConsultationSummaryInsertionService().insert(
            proposal,
            into: context.encounter,
            patient: context.patient,
            deviceID: summary.manifest.deviceID,
            reviewedBy: context.encounter.draft.metadata.authorID,
            sourceIdentity: try RawAssetCreationIdentity.generate(at: proposal.provenance.generatedAt),
            updatedAt: Date()
        )
        self.summary = try VaultReader().open(summary.url)
        draftText = result.draft.body
        lastSavedAt = result.draft.metadata.updatedAt
        draftSaveError = nil
        consultationSummaryContext = nil
        noticeMessage = "Resumo aceito e acrescentado ao rascunho. A transcrição-fonte foi preservada como documento da consulta."
    }

    @MainActor
    private func acceptProgressiveSummaryBlock(_ block: ConsultationSummaryBlock) throws {
        guard let summary, let authorizationURL, summary.writingAllowed,
              let patient = selectedPatient, let encounter = selectedEncounter,
              encounter.finalizationStatus == .draft,
              transcriptionSession.binding?.vaultID == summary.manifest.vaultID,
              transcriptionSession.binding?.patientID == patient.patientID,
              transcriptionSession.binding?.encounterID == encounter.metadata.encounterID,
              encounter.draft.persistedData == selectedEncounter?.draft.persistedData,
              ClinicalDraftSaver.matchesPersistedBody(draftText, encounter.draft.body),
              !isSavingDraft, !isFinalizing else {
            throw ProgressiveSummaryInsertionIssue.revisionConflict
        }
        let granted = authorizationURL.startAccessingSecurityScopedResource()
        defer { if granted { authorizationURL.stopAccessingSecurityScopedResource() } }
        let acceptedAt = Date()
        let result = try ProgressiveSummaryInsertionService().insert(
            block,
            into: encounter,
            patient: patient,
            deviceID: summary.manifest.deviceID,
            acceptedBy: encounter.draft.metadata.authorID,
            sourceIdentity: try RawAssetCreationIdentity.generate(at: acceptedAt),
            acceptedAt: acceptedAt
        )
        let acceptance = ConsultationSummaryAcceptance(
            acceptanceID: "acceptance_\(UUID().uuidString.lowercased())",
            acceptedBy: encounter.draft.metadata.authorID,
            acceptedAt: acceptedAt,
            acceptedText: block.editedText,
            sourceAssetID: result.source.assetID
        )
        do {
            try transcriptionSession.markProgressiveSummaryAccepted(acceptance)
        } catch {
            _ = try? ProgressiveSummaryInsertionService().undo(result.undoToken)
            throw error
        }
        progressiveSummaryUndoTokens[block.id] = result.undoToken
        self.summary = try VaultReader().open(summary.url)
        draftText = result.draft.body
        lastSavedAt = result.draft.metadata.updatedAt
        draftSaveError = nil
        noticeMessage = "Resumo acrescentado ao prontuário de \(patient.displayName)."
    }

    @MainActor
    private func undoProgressiveSummaryBlock(_ block: ConsultationSummaryBlock) throws {
        guard let summary, let authorizationURL,
              transcriptionSession.binding?.vaultID == summary.manifest.vaultID,
              let token = progressiveSummaryUndoTokens[block.id] else {
            throw ProgressiveSummaryInsertionIssue.undoUnavailable
        }
        let granted = authorizationURL.startAccessingSecurityScopedResource()
        defer { if granted { authorizationURL.stopAccessingSecurityScopedResource() } }
        let acceptance = block.acceptance
        try transcriptionSession.markProgressiveSummaryUndone()
        let restored: ClinicalDraftSummary
        do {
            restored = try ProgressiveSummaryInsertionService().undo(token)
        } catch {
            if let acceptance {
                try? transcriptionSession.markProgressiveSummaryAccepted(acceptance)
            }
            throw error
        }
        progressiveSummaryUndoTokens[block.id] = nil
        self.summary = try VaultReader().open(summary.url)
        draftText = restored.body
        lastSavedAt = restored.metadata.updatedAt
        draftSaveError = nil
        noticeMessage = "Adição desfeita. A fonte preservada continua nos documentos da consulta."
    }

    private func insertOptionalTemplate() {
        draftText = OptionalClinicalDraftTemplate.inserting(into: draftText)
        noticeMessage = nil
    }

    @MainActor
    private func finalizeSelectedEncounter() {
        guard !transcriptionBlocksSelectedEncounter else { return }
        guard let summary, let patient = selectedPatient, let encounter = selectedEncounter,
              let authorizationURL, summary.writingAllowed, !isSavingDraft, !isFinalizing,
              encounter.finalizationStatus == .draft else { return }
        isFinalizing = true
        finalizationError = nil
        noticeMessage = nil
        let granted = authorizationURL.startAccessingSecurityScopedResource()
        Task { @MainActor in
            defer {
                if granted { authorizationURL.stopAccessingSecurityScopedResource() }
                isFinalizing = false
            }
            guard await saveDraft(announcingSuccess: false) else {
                finalizationError = draftSaveError ?? "Não foi possível salvar. O texto permanece no editor; tente salvar novamente."
                return
            }
            guard self.summary?.url == summary.url,
                  let currentPatient = selectedPatient, currentPatient.patientID == patient.patientID,
                  let currentEncounter = selectedEncounter,
                  currentEncounter.metadata.encounterID == encounter.metadata.encounterID,
                  currentEncounter.finalizationStatus == .draft, !hasUnsavedDraft else {
                finalizationError = "A consulta mudou. Reabra a consulta desejada antes de finalizar."
                return
            }
            do {
                try await ensureAuthenticated(
                    reason: "Finalizar a nota clínica no OpenPEP"
                )
                guard self.summary?.url == summary.url,
                      selectedPatient?.patientID == currentPatient.patientID,
                      selectedEncounter?.metadata.encounterID == currentEncounter.metadata.encounterID,
                      selectedEncounter?.draft.persistedData == currentEncounter.draft.persistedData,
                      ClinicalDraftSaver.matchesPersistedBody(draftText, currentEncounter.draft.body) else {
                    finalizationError = "A consulta mudou durante a autenticação. Confira o texto e tente finalizar novamente."
                    return
                }
                _ = try ClinicalFinalizer().finalize(
                    patient: currentPatient,
                    encounter: currentEncounter,
                    identity: try FinalizationIdentity.generate(),
                    finalizedAt: Date()
                )
                self.summary = try VaultReader().open(summary.url)
                encounterActivity.finish(
                    patientID: patient.patientID,
                    encounterID: encounter.metadata.encounterID
                )
                loadDraft(for: selection)
                finalizationError = nil
                noticeMessage = "Nota final criada, registrada e relida."
            } catch {
                finalizationError = error.localizedDescription
                self.summary = try? VaultReader().open(summary.url)
            }
        }
    }

    @MainActor
    private func createAddendum(context: AddendumContext, reason: String, body: String) {
        guard let summary, let patient = summary.patients.first(where: { $0.patientID == context.patientID }),
              let encounter = patient.encounters.first(where: { $0.metadata.encounterID == context.encounterID }),
              let authorizationURL, summary.writingAllowed, !isSavingAddendum else { return }
        isSavingAddendum = true
        addendumError = nil
        let granted = authorizationURL.startAccessingSecurityScopedResource()
        Task { @MainActor in
            defer {
                if granted { authorizationURL.stopAccessingSecurityScopedResource() }
                isSavingAddendum = false
            }
            do {
                try await ensureAuthenticated(
                    reason: "Criar um adendo à nota final no OpenPEP"
                )
                _ = try ClinicalAddendumWriter().add(
                    patient: patient,
                    encounter: encounter,
                    identity: try AddendumIdentity.generate(),
                    reason: reason,
                    body: body,
                    createdAt: Date()
                )
                self.summary = try VaultReader().open(summary.url)
                addendumContext = nil
                addendumError = nil
                noticeMessage = "Adendo criado, registrado e relido."
            } catch {
                addendumError = error.localizedDescription
                self.summary = try? VaultReader().open(summary.url)
            }
        }
    }

    @MainActor
    private func ensureAuthenticated(reason: String) async throws {
        guard !authenticationSession.isActive() else { return }
        _ = try await SystemLocalAuthenticator().authenticate(reason: reason)
        authenticationSession.registerSuccessfulAuthentication()
    }

    private func normalizedSearch(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
    }

    private func sexLabel(_ value: String) -> String {
        switch value {
        case "female": "sexo administrativo feminino"
        case "male": "sexo administrativo masculino"
        default: "sexo administrativo não informado"
        }
    }

    private func displayAppointment(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else { return value }
        return displayDate(date, includesTime: true)
    }

    private func displayClinicalDate(_ value: String) -> String {
        let timestampParser = ISO8601DateFormatter()
        let dateOnlyParser = ISO8601DateFormatter()
        dateOnlyParser.formatOptions = [.withFullDate]
        guard let date = timestampParser.date(from: value) ?? dateOnlyParser.date(from: value) else {
            return value
        }
        return displayDate(date, includesTime: false)
    }

    private func displayClinicalTimestamp(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else { return value }
        return displayDate(date, includesTime: true)
    }

    private func displayDate(_ date: Date, includesTime: Bool) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.timeZone = .current
        formatter.dateFormat = includesTime ? "dd/MM/yyyy HH:mm" : "dd/MM/yyyy"
        return formatter.string(from: date)
    }

    private func displayDayHeading(_ date: Date) -> String {
        let weekday = date.formatted(
            .dateTime.weekday(.wide).locale(Locale(identifier: "pt_BR"))
        )
        return "\(weekday.capitalized) · \(displayDate(date, includesTime: false))"
    }

    private func modalityLabel(_ value: String) -> String {
        switch value {
        case "in_person": "Presencial"
        case "telehealth": "Teleatendimento"
        default: value
        }
    }

    private func patientAccessibilityLabel(
        _ patient: PatientSummary,
        profile: DemoPatientProfile?
    ) -> String {
        guard let profile else { return "Paciente \(patientNameAndAge(patient))" }
        if let appointment = profile.nextAppointment {
            return "\(patientNameAndAge(patient)), \(profile.primaryProblem), agendado para \(displayAppointment(appointment.startsAt))"
        }
        return "\(patientNameAndAge(patient)), \(profile.primaryProblem)"
    }

    private func patientNameAndAge(_ patient: PatientSummary) -> String {
        let profile = summary?.demoCatalog?.profile(for: patient.patientID)
        let birthDate = patient.record?.birthDate ?? profile?.birthDate
        guard let age = PatientAge.years(fromStorage: birthDate) else {
            return patientDisplayName(patient)
        }
        return "\(patientDisplayName(patient)) · \(PatientAge.label(for: age))"
    }

    private func patientDisplayName(_ patient: PatientSummary) -> String {
        guard patient.record == nil else { return patient.displayName }
        return summary?.demoCatalog?.profile(for: patient.patientID)?.displayName ?? patient.displayName
    }

    private func rawAssetKindLabel(_ kind: String?) -> String {
        switch kind {
        case "laboratory": "Resultado laboratorial"
        case "imaging": "Laudo de imagem"
        case "transcript": "Transcrição da consulta"
        default: "Documento"
        }
    }

    private func rawAssetIcon(_ kind: String?) -> String {
        switch kind {
        case "laboratory": "testtube.2"
        case "imaging": "doc.text.magnifyingglass"
        case "transcript": "text.bubble"
        default: "doc"
        }
    }

    private func rawAssetGroups(
        patient: PatientSummary,
        profile: DemoPatientProfile?
    ) -> [RawAssetGroup] {
        let kindsByAsset = Dictionary(
            uniqueKeysWithValues: (profile?.rawAssets ?? []).map { ($0.assetID, $0.kind) }
        )
        let grouped = Dictionary(grouping: patient.rawAssets) { kindsByAsset[$0.assetID] }
        let preferredOrder: [String?] = ["laboratory", "imaging", "transcript", nil]
        return preferredOrder.compactMap { kind in
            guard let assets = grouped[kind] else { return nil }
            return RawAssetGroup(
                kind: kind,
                assets: assets.sorted { $0.importedAt > $1.importedAt }
            )
        }
    }

    @MainActor
    private func previewDocument(patientID: String, assetID: String) {
        guard let summary, let authorizationURL else { return }
        previewURL = nil
        releasePreviewAccess()
        errorMessage = nil
        noticeMessage = nil

        let granted = authorizationURL.startAccessingSecurityScopedResource()
        do {
            let resolvedURL = try RawAssetDocumentResolver().resolvePreview(
                patientID: patientID,
                assetID: assetID,
                in: summary.url
            )
            if granted {
                previewAuthorizationURL = authorizationURL
            }
            previewURL = resolvedURL
        } catch {
            if granted {
                authorizationURL.stopAccessingSecurityScopedResource()
            }
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func showDocumentInFinder(patientID: String, assetID: String) {
        guard let summary, let authorizationURL else { return }
        withSecurityScopedAccess(to: authorizationURL) {
            let asset = try RawAssetDocumentResolver().resolve(
                patientID: patientID,
                assetID: assetID,
                in: summary.url
            )
            NSWorkspace.shared.activateFileViewerSelecting([asset.originalURL])
        }
    }

    @MainActor
    private func exportDocumentCopy(patientID: String, assetID: String) {
        guard let summary, let authorizationURL else { return }
        withSecurityScopedAccess(to: authorizationURL) {
            let asset = try RawAssetDocumentResolver().resolve(
                patientID: patientID,
                assetID: assetID,
                in: summary.url
            )
            let panel = NSSavePanel()
            panel.title = "Exportar cópia verificada"
            panel.prompt = "Exportar"
            panel.nameFieldStringValue = asset.originalName
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            let destinationGranted = destination.startAccessingSecurityScopedResource()
            defer { if destinationGranted { destination.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: asset.originalURL, options: [.mappedIfSafe])
            try data.write(to: destination, options: [.atomic])
            noticeMessage = "Cópia exportada a partir do documento verificado."
        }
    }

    @MainActor
    private func releasePreviewAccess() {
        previewAuthorizationURL?.stopAccessingSecurityScopedResource()
        previewAuthorizationURL = nil
    }

    private func loadDraft(for selection: AppSelection?) {
        guard case let .encounter(patientID, encounterID) = selection,
              let patient = summary?.patients.first(where: { $0.patientID == patientID }),
              let encounter = patient.encounters.first(where: {
                  $0.metadata.encounterID == encounterID
              }) else {
            draftText = ""
            lastSavedAt = nil
            draftSaveError = nil
            return
        }
        draftText = encounter.draft.body
        if encounter.finalizationStatus == .draft, summary?.writingAllowed == true {
            draftText = (try? ConsultationDiagnoses.carryingChronic(into: draftText, patient: patient, encounterID: encounterID)) ?? draftText
        }
        lastSavedAt = encounter.draft.metadata.updatedAt
        draftSaveError = nil
    }

    @MainActor
    private func withSecurityScopedAccess(
        to url: URL,
        clearVaultOnError: Bool = false,
        operation: () throws -> Void
    ) {
        errorMessage = nil
        noticeMessage = nil
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            try operation()
        } catch {
            if clearVaultOnError {
                summary = nil
                authorizationURL = nil
                authenticationSession.clear()
                resetNavigation()
                draftText = ""
                lastSavedAt = nil
            }
            errorMessage = error.localizedDescription
        }
    }
}

private struct PatientCardActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.7)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
