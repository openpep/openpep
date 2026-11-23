// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct ConsultationSummaryView: View {
    let onInsertReviewedProposal: @MainActor (ConsultationSummaryProposal) async throws -> Void
    let service: ConsultationSummaryService

    @State private var transcript = ""
    @State private var proposal: ConsultationSummaryProposal?
    @State private var reviewedText = ""
    @State private var status = "Cole uma transcrição para gerar uma proposta local."
    @State private var task: Task<Void, Never>?

    init(
        service: ConsultationSummaryService = ConsultationSummaryService(),
        onInsertReviewedProposal: @escaping @MainActor (ConsultationSummaryProposal) async throws -> Void
    ) {
        self.service = service
        self.onInsertReviewedProposal = onInsertReviewedProposal
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Resumo local da consulta").font(.title2)
                Label("Proposta gerada por IA no Mac", systemImage: "sparkles")
                    .font(.headline)
                Text("O modelo pode omitir ou alterar informações. Confira fatos, negações, nomes, números, medicamentos e condutas antes de inserir.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                GroupBox("Transcrição-fonte") {
                    TextEditor(text: $transcript)
                        .font(.body.monospaced())
                        .frame(minHeight: 180)
                        .accessibilityLabel("Transcrição para resumir")
                        .disabled(task != nil || proposal != nil)
                }

                HStack {
                    Button("Gerar proposta local", systemImage: "sparkles", action: generate)
                        .disabled(task != nil || proposal != nil || transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if task != nil {
                        ProgressView().controlSize(.small)
                        Button("Cancelar") { task?.cancel() }
                    }
                }
                Text(status).font(.callout).foregroundStyle(.secondary)
                    .accessibilityLabel("Estado do resumo: \(status)")

                if proposal != nil {
                    GroupBox("Proposta para revisão") {
                        TextEditor(text: $reviewedText)
                            .frame(minHeight: 220)
                            .accessibilityLabel("Proposta de resumo editável")
                            .disabled(task != nil)
                    }
                    HStack {
                        Button("Descartar proposta", role: .cancel, action: discardProposal)
                            .disabled(task != nil)
                        Spacer()
                        Button("Aceitar e inserir no rascunho", systemImage: "text.badge.plus", action: insert)
                            .buttonStyle(.borderedProminent)
                            .disabled(task != nil || reviewedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 880, alignment: .leading)
        }
        .onDisappear { task?.cancel() }
    }

    @MainActor
    private func generate() {
        guard task == nil, proposal == nil else { return }
        proposal = nil
        reviewedText = ""
        status = "Verificando disponibilidade e gerando no dispositivo…"
        let source = transcript
        task = Task { @MainActor in
            defer { task = nil }
            do {
                let result = try await service.propose(from: source)
                try Task.checkCancellation()
                proposal = result
                reviewedText = result.text
                status = result.provenance.chunkCount == 1
                    ? "Proposta pronta. Revise antes de inserir."
                    : "Proposta pronta em \(result.provenance.chunkCount) trechos, sem descartar o restante da entrada. Revise antes de inserir."
            } catch is CancellationError {
                status = "Geração cancelada. Nenhuma proposta foi inserida."
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func discardProposal() {
        proposal = nil
        reviewedText = ""
        status = "Proposta descartada. A transcrição permanece disponível para edição."
    }

    private func insert() {
        guard task == nil, let proposal else { return }
        let reviewed = reviewedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reviewed.isEmpty else { return }
        status = "Salvando a fonte e inserindo no rascunho…"
        task = Task { @MainActor in
            defer { task = nil }
            do {
                try await onInsertReviewedProposal(proposal.replacingText(with: reviewed))
                discardProposal()
                status = "Proposta aceita, inserida e relida no rascunho."
            } catch is CancellationError {
                status = "Inserção cancelada. Confira o rascunho antes de tentar novamente."
            } catch {
                status = error.localizedDescription
            }
        }
    }
}
