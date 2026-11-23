// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

enum HomePatientAction: String, Identifiable {
    case startEncounter
    case issueDocument

    var id: String { rawValue }

    var title: String {
        switch self {
        case .startEncounter: "Iniciar atendimento"
        case .issueDocument: "Emitir documento"
        }
    }

    var instruction: String {
        switch self {
        case .startEncounter: "Escolha o paciente do atendimento."
        case .issueDocument: "Escolha o paciente que receberá o documento."
        }
    }

    var confirmationLabel: String {
        switch self {
        case .startEncounter: "Iniciar atendimento"
        case .issueDocument: "Abrir documentos"
        }
    }
}

struct HomeView: View {
    @Binding var searchText: String
    let canWrite: Bool
    let onStartEncounter: () -> Void
    let onOpenAgenda: () -> Void
    let onIssueDocument: () -> Void
    let onSearch: () -> Void
    var doctorProfile: DoctorProfile = DoctorProfileStore.load()

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Text(greeting)
                    .font(.system(size: 32, weight: .medium, design: .serif))
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 8)

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Pergunte ou peça ao assistente", text: $searchText)
                        .textFieldStyle(.plain)
                        .onSubmit(onSearch)
                    Button("Enviar", systemImage: "arrow.right", action: onSearch)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .help("Pergunte ou peça ao assistente")
                        .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .searchClearButton($searchText)
                .padding(.horizontal, 16)
                .frame(maxWidth: 650, minHeight: 44)
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
                .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .contain)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
                    homeCard("Atender", icon: "stethoscope", enabled: canWrite, action: onStartEncounter)
                    homeCard("Agenda", icon: "calendar", enabled: true, action: onOpenAgenda)
                    homeCard("Emitir documentos", icon: "doc.text", enabled: canWrite, action: onIssueDocument)
                }.frame(maxWidth: 650)

            }
            .frame(maxWidth: 960)
            .padding(.horizontal, 24)
            .padding(.top, 100)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle("Início")
    }
    private var greeting: String {
        let name = doctorProfile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Olá." : "Olá, \(name.trimmingCharacters(in: CharacterSet(charactersIn: ".")))."
    }

    private func homeCard(_ title: String, icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 26, weight: .light)).foregroundStyle(.tint)
                Text(title).font(.callout.weight(.medium)).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity, minHeight: 110).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.6)))
        .disabled(!enabled)
    }

}

private struct HomeActionCard: View {
    let title: String
    let systemImage: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 72, height: 72)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                Text(title)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 160)
            .padding(18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.7)))
        .shadow(color: .black.opacity(0.07), radius: 10, y: 4)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityHint(isEnabled ? "Abre a próxima etapa" : "O prontuário está disponível somente para leitura")
    }
}

struct HomePatientSelectionView: View {
    let action: HomePatientAction
    let patients: [PatientSummary]
    let patientLabel: (PatientSummary) -> String
    let canCreatePatient: Bool
    let onSelect: (PatientSummary) -> Void
    let onCreatePatient: () -> Void
    let onCancel: () -> Void
    @State private var query = ""

    private var filteredPatients: [PatientSummary] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return patients }
        return patients.filter { PatientSearch.matches($0, query: query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(action.title).font(.title2).fontWeight(.semibold)
                    Text(action.instruction).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancelar", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }

            TextField("Buscar paciente", text: $query).searchClearButton($query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Buscar paciente para \(action.title.lowercased())")

            if filteredPatients.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "Nenhum paciente cadastrado" : "Nenhum paciente encontrado",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text(query.isEmpty ? "Cadastre o primeiro paciente para continuar." : "Tente outro nome ou cadastre um paciente.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredPatients, id: \.patientID) { patient in
                    Button {
                        onSelect(patient)
                    } label: {
                        HStack {
                            Label(patientLabel(patient), systemImage: "person.crop.circle")
                            Spacer()
                            Text(action.confirmationLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(action.confirmationLabel)
                }
                .listStyle(.inset)
            }

            HStack {
                Button("Novo paciente", systemImage: "person.badge.plus", action: onCreatePatient)
                    .disabled(!canCreatePatient)
                Spacer()
            }
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 620, minHeight: 420, idealHeight: 540)
    }
}

struct WelcomeView: View {
    let onCreate: () -> Void
    let onOpen: () -> Void
    let onDemo: () -> Void
    let onRestore: () -> Void
    var isGeneratingDemo = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Text("OpenPEP · versão alfa").font(.largeTitle.weight(.semibold))
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) {
                        welcomeCard("Explorar demonstração", icon: "person.3", action: onDemo).frame(width: 250)
                        welcomeCard("Criar prontuário", icon: "folder.badge.plus", action: onCreate).frame(width: 250)
                        welcomeCard("Abrir prontuário", icon: "folder", action: onOpen).frame(width: 250)
                    }
                    VStack(spacing: 16) {
                        welcomeCard("Explorar demonstração", icon: "person.3", action: onDemo)
                        welcomeCard("Criar prontuário", icon: "folder.badge.plus", action: onCreate)
                        welcomeCard("Abrir prontuário", icon: "folder", action: onOpen)
                    }.frame(maxWidth: 480)
                }
                .disabled(isGeneratingDemo)
                if isGeneratingDemo {
                    ProgressView("Preparando os dez pacientes…")
                } else {
                    Text("A demonstração usa apenas pessoas e histórias fictícias.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Restaurar backup…", action: onRestore).buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 24).padding(.top, 56).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private func welcomeCard(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        HomeActionCard(title: title, systemImage: icon, isEnabled: true, action: action)
    }
}

struct NewPatientActionsView: View {
    let patientName: String
    let onStart: () -> Void
    let onSchedule: () -> Void
    let onDocuments: () -> Void
    let onClose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text(patientName).font(.title2.weight(.semibold))
                Spacer()
                Button("Fechar", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly).buttonStyle(.plain).keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 16) {
                HomeActionCard(title: "Iniciar atendimento", systemImage: "stethoscope", isEnabled: true, action: onStart)
                HomeActionCard(title: "Realizar agendamento", systemImage: "calendar", isEnabled: true, action: onSchedule)
                HomeActionCard(title: "Enviar documentos", systemImage: "doc.text", isEnabled: true, action: onDocuments)
            }
        }.padding(28).frame(width: 660)
    }
}
