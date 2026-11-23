// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

enum SettingsTopic: String, CaseIterable, Hashable, Identifiable {
    case quickSetup
    case appearance
    case documents
    case agenda
    case videoCall
    case transcription
    case recordings
    case aiAssistance
    case storage
    case backup
    case trash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quickSetup: "Configuração rápida de IA e microfone"
        case .documents: "Dados do médico"
        case .appearance: "Aparência"
        case .agenda: "Agenda"
        case .videoCall: "Videochamada"
        case .transcription: "Transcrição"
        case .recordings: "Gravações"
        case .aiAssistance: "Assistência de IA"
        case .storage: "Armazenamento"
        case .backup: "Backup e restauração"
        case .trash: "Lixeira"
        }
    }

    var summary: String {
        switch self {
        case .quickSetup: "Teste a chave da OpenAI e prepare o microfone"
        case .documents: "Identificação, consultórios e assinatura"
        case .appearance: "Tema usado pelo aplicativo"
        case .agenda: "Duração e grade de horários"
        case .videoCall: "Conta e criação de salas"
        case .transcription: "Provedores de transcrição e resumo"
        case .recordings: "Fonte, pasta dos áudios e consentimento"
        case .aiAssistance: "Chave e recursos gerais da OpenAI"
        case .storage: "Pasta e estado do prontuário local"
        case .backup: "Cópias, verificação e recuperação"
        case .trash: "Rascunhos excluídos que podem ser restaurados"
        }
    }

    var systemImage: String {
        switch self {
        case .quickSetup: "wand.and.stars"
        case .documents: "doc.text"
        case .appearance: "circle.lefthalf.filled"
        case .agenda: "calendar"
        case .videoCall: "video"
        case .transcription: "text.bubble"
        case .recordings: "waveform"
        case .aiAssistance: "sparkles"
        case .storage: "internaldrive"
        case .backup: "externaldrive.badge.timemachine"
        case .trash: "trash"
        }
    }

    var searchTerms: String {
        switch self {
        case .quickSetup: "primeiro uso iniciar onboarding chave API OpenAI áudio transcrição permissão microfone"
        case .documents: "médico nome preferido especialidade CRM CPF RQE endereço consultório telefone assinatura documentos impressão A4"
        case .appearance: "tema automática claro clara escuro escura macOS"
        case .agenda: "modo inicial duração padrão grade início fim dia semana mês rotina"
        case .videoCall: "Google Meet conta sala chamada OAuth"
        case .transcription: "Apple OpenAI provedor modelo resumo intervalo áudio ao vivo local"
        case .recordings: "microfone teleconsulta aplicativo chamada permissão pasta salvar áudio termo consentimento"
        case .aiAssistance: "OpenAI Apple Intelligence provedor chave modelo resumo perguntas"
        case .storage: "prontuário cofre vault pasta leitura escrita acesso somente leitura"
        case .backup: "cópia verificar restaurar recuperação histórico ensaio"
        case .trash: "rascunho excluído recuperar restaurar consulta"
        }
    }

    func matches(_ query: String) -> Bool {
        let normalizedQuery = query.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "pt_BR")
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return true }
        let searchable = "\(title) \(summary) \(searchTerms)".folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "pt_BR")
        )
        return searchable.contains(normalizedQuery)
    }
}

private struct SettingsTopicGroup: Identifiable {
    let title: String
    let topics: [SettingsTopic]
    var id: String { title }
}

struct SettingsIndexView: View {
    let onOpen: (SettingsTopic) -> Void
    @State private var query = ""

    private let groups = [
        SettingsTopicGroup(title: "Preferências", topics: [.quickSetup, .appearance, .agenda]),
        SettingsTopicGroup(title: "Consulta", topics: [.documents, .videoCall, .transcription, .recordings, .aiAssistance]),
        SettingsTopicGroup(title: "Arquivos", topics: [.storage, .backup, .trash])
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Configurações")
                        .font(.largeTitle)
                }

                TextField("Buscar configurações", text: $query).searchClearButton($query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityHint("Busca tópicos e nomes de configurações somente nesta tela")

                if visibleGroups.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ForEach(visibleGroups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            ForEach(group.topics) { topic in
                                Button {
                                    onOpen(topic)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: topic.systemImage)
                                            .font(.title3)
                                            .frame(width: 28)
                                            .foregroundStyle(.tint)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(topic.title)
                                                .font(.headline)
                                                .foregroundStyle(.primary)
                                            Text(topic.summary)
                                                .font(.callout)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 12)
                                        Image(systemName: "chevron.right")
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                                .accessibilityElement(children: .combine)
                                .accessibilityHint("Abre este tópico de configurações")
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .navigationTitle("Configurações")
    }

    private var visibleGroups: [SettingsTopicGroup] {
        groups.compactMap { group in
            let topics = group.topics.filter { $0.matches(query) }
            return topics.isEmpty ? nil : SettingsTopicGroup(title: group.title, topics: topics)
        }
    }
}
