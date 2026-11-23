// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Reads the existing wiki without changing the originating screen or its draft.
struct PatientWikiBrowser: View {
    let vaultURL: URL
    let authorizationURL: URL
    let initialPatientID: String?
    let onClose: () -> Void
    @State private var vault: VaultSummary?
    @State private var patientID: String?
    @State private var query = ""
    @State private var issue: String?

    init(vault: VaultSummary, authorizationURL: URL, initialPatientID: String?, onClose: @escaping () -> Void) {
        self.vaultURL = vault.url
        self.authorizationURL = authorizationURL
        self.initialPatientID = initialPatientID
        self.onClose = onClose
        _patientID = State(initialValue: initialPatientID)
    }

    init(context: PatientHistoryContext, onClose: @escaping () -> Void) {
        vaultURL = context.vaultURL
        authorizationURL = context.authorizationURL
        initialPatientID = context.patientID
        self.onClose = onClose
        _patientID = State(initialValue: context.patientID)
    }

    private var patient: PatientSummary? { vault?.patients.first { $0.patientID == patientID } }
    private var loadIdentity: String {
        vaultURL.standardizedFileURL.path + "\n" + (initialPatientID ?? "")
    }
    private var matches: [PatientSummary] {
        (vault?.patients ?? []).filter {
            query.isEmpty || $0.displayName.localizedStandardContains(query)
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Wiki", systemImage: "book.closed").font(.title2.bold())
                    Text(patient?.displayName ?? "Escolha um paciente").font(.headline)
                }
                Spacer()
                if initialPatientID == nil, patientID != nil {
                    Button("Voltar aos pacientes") { patientID = nil }
                }
                Button("Fechar", action: onClose).keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            if let issue {
                ContentUnavailableView("Não foi possível abrir a wiki", systemImage: "exclamationmark.triangle",
                    description: Text(issue))
            } else if let patient, let vault {
                ScrollView {
                    PatientWikiView(patient: patient,
                        context: PatientHistoryContext(patientID: patient.patientID, patientName: patient.displayName,
                            vaultURL: vaultURL, authorizationURL: authorizationURL),
                        canWrite: vault.writingAllowed && !patient.isArchived, automaticallyUpdates: true)
                        .id(patient.patientID)
                        .padding(20)
                }
            } else if vault == nil {
                ProgressView("Abrindo wiki…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if patientID != nil {
                ContentUnavailableView("Paciente indisponível", systemImage: "person.crop.circle.badge.questionmark")
            } else {
                TextField("Buscar paciente", text: $query).searchClearButton($query)
                    .textFieldStyle(.roundedBorder).padding(20)
                List(matches, id: \.patientID) { patient in
                    Button { patientID = patient.patientID } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(patient.displayName).font(.headline)
                                if let birthDate = patient.record?.birthDate { Text(birthDate).font(.caption).foregroundStyle(.secondary) }
                                if patient.isArchived { Text("Arquivado").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                        }.padding(.vertical, 6).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Abrir wiki de \(patient.displayName)")
                }
                if matches.isEmpty { Text("Nenhum paciente encontrado").foregroundStyle(.secondary).padding() }
            }
        }
        .frame(minWidth: 700, idealWidth: 900, minHeight: 600, idealHeight: 800)
        .task(id: loadIdentity) {
            patientID = initialPatientID
            query = ""
            vault = nil
            issue = nil
            do {
                let url = vaultURL, access = authorizationURL
                let loaded = try await Task.detached {
                    let granted = access.startAccessingSecurityScopedResource()
                    defer { if granted { access.stopAccessingSecurityScopedResource() } }
                    return try VaultReader().open(url)
                }.value
                try Task.checkCancellation()
                vault = loaded
            } catch is CancellationError { }
            catch { issue = error.localizedDescription }
        }
    }
}
