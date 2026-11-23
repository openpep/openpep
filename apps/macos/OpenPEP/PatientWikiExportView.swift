// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

/// Implements the one deliberate review action used by the IPS preview.
/// The UI chooses the destination before calling this operation, so cancelling
/// that panel cannot write a review. Every selected fact is recorded in one
/// coordinated batch and the source/summary snapshot is checked again before
/// publication.
struct PatientWikiApproval {
    typealias ReloadContext = () throws -> PatientWikiContext

    static func candidates(reviews: PatientWikiReviews, summary: PatientWikiSummary,
                           context: PatientWikiContext, proposals: [PatientWikiFact]) -> [PatientWikiFact] {
        var byID: [String: PatientWikiFact] = [:]
        for fact in reviews.candidates(for: summary, in: context) + proposals
            where fact.matches(context.entries) && !reviews.supersededIDs.contains(fact.id) {
            byID[fact.id] = fact
        }
        return byID.values.sorted {
            $0.draft.label.localizedStandardCompare($1.draft.label) == .orderedAscending
                || ($0.draft.label == $1.draft.label && $0.id < $1.id)
        }
    }

    static func approve(summary: PatientWikiSummary, context: PatientWikiContext,
                        historyContext: PatientHistoryContext, reviews: PatientWikiReviews,
                        expectedReviews: Data?, proposals: [PatientWikiFact], selectedIDs: Set<String>,
                        reviewer: String, reviewedAt: String? = nil,
                        reloadContext: ReloadContext? = nil) throws -> (reviews: PatientWikiReviews, data: Data?) {
        guard summary.sourceFingerprint == context.fingerprint,
              !reviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PatientAIIssue.changed
        }
        let store = PatientWikiStore()
        let (_, currentData) = try store.loadReviews(for: context.patient)
        guard currentData == expectedReviews else { throw PatientAIIssue.changed }
        let available = candidates(reviews: reviews, summary: summary, context: context, proposals: proposals)
        let availableIDs = Set(available.map(\.id))
        guard selectedIDs.isSubset(of: availableIDs) else { throw PatientAIIssue.changed }
        let selected = available.filter { selectedIDs.contains($0.id) }
        guard selected.allSatisfy({ $0.matches(context.entries) }) else { throw PatientAIIssue.changed }
        let saved = try store.load(for: context.patient)
        guard saved.summary?.persistedData == summary.persistedData else { throw PatientAIIssue.changed }

        let stamp = reviewedAt ?? ISO8601DateFormatter().string(from: Date())
        let newReviews = selected.map { fact in
            PatientWikiReview(fact: fact, decision: .accepted, reviewer: reviewer, reviewedAt: stamp,
                note: reviews.latestReview(for: fact)?.note)
        }
        if !newReviews.isEmpty {
            try store.saveReviews(newReviews, for: context.patient, expectedData: currentData) {
                let latest: PatientWikiContext
                if let reloadContext {
                    latest = try reloadContext()
                } else {
                    let latestSaved = try store.load(for: context.patient)
                    latest = try PatientWikiContext.load(context: historyContext,
                        corrections: latestSaved.corrections?.markdown ?? "")
                }
                let latestSaved = try store.load(for: context.patient)
                guard latestSaved.summary?.persistedData == summary.persistedData,
                      latest.writingAllowed, latest.fingerprint == context.fingerprint,
                      selected.allSatisfy({ $0.matches(latest.entries) }) else {
                    throw PatientAIIssue.changed
                }
            }
        }
        return try store.loadReviews(for: context.patient)
    }
}

struct PatientWikiExportView: View {
    let summary: PatientWikiSummary
    let context: PatientWikiContext
    let historyContext: PatientHistoryContext
    let reviews: PatientWikiReviews
    let expectedReviews: Data?
    let reviewer: String
    let proposals: [PatientWikiFact]
    let canWrite: Bool
    @State private var issue: String?
    @State private var selectedIDs = Set<String>()
    @State private var approvalInProgress = false
    @State private var currentExpectedReviews: Data?
    @Environment(\.dismiss) private var dismiss
    @FocusedValue(\.openPEPSettings) private var openSettings

    init(summary: PatientWikiSummary, context: PatientWikiContext,
         historyContext: PatientHistoryContext, reviews: PatientWikiReviews,
         expectedReviews: Data?, reviewer: String,
         proposals: [PatientWikiFact] = [], canWrite: Bool = true) {
        self.summary = summary
        self.context = context
        self.historyContext = historyContext
        self.reviews = reviews
        self.expectedReviews = expectedReviews
        self.reviewer = reviewer
        self.proposals = proposals
        self.canWrite = canWrite
        _currentExpectedReviews = State(initialValue: expectedReviews)
    }

    private var candidateFacts: [PatientWikiFact] {
        PatientWikiApproval.candidates(reviews: reviews, summary: summary, context: context, proposals: proposals)
    }

    private var reviewerIsConfigured: Bool {
        !reviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canApprove: Bool {
        canWrite && context.writingAllowed && !context.patient.isArchived
            && summary.sourceFingerprint == context.fingerprint
            && reviewerIsConfigured && !approvalInProgress
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Prévia do IPS").font(.title2)
            Text("Confira o recorte completo antes de uma única aprovação. Os dados ainda são propostas da IA até essa ação.")
            if summary.omittedFactCount > 0 {
                Text("Dados não incluídos no IPS: \(summary.omittedFactCount). Confira as fontes.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if reviewerIsConfigured {
                Label("Profissional do Solo: \(reviewer)", systemImage: "person.crop.circle")
                    .font(.callout)
            } else {
                Label("Perfil do Solo não configurado", systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.callout)
                Text("O IPS precisa da identidade do profissional configurada no Solo; não há campo para digitar outro nome.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Abrir Configurações…", systemImage: "gearshape") { openSettings?() }
                    .disabled(openSettings == nil)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(context.patient.displayName).font(.headline)
                    Text(context.patient.record?.birthDate.map { "Nascimento: " + $0 } ?? "Nascimento não informado")
                    if candidateFacts.isEmpty { Text("Nenhum dado elegível nesta geração.") }
                    ForEach(candidateFacts) { fact in
                        let previousDecision = reviews.decision(for: fact)
                        Toggle(isOn: selectionBinding(for: fact)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(PatientWikiExport.factDescription(fact, note: reviews.latestReview(for: fact)?.note)).textSelection(.enabled)
                                if previousDecision == .rejected {
                                    Text("Rejeitada anteriormente · marque para reconsiderar explicitamente")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else if previousDecision == .accepted {
                                    Text("Decisão anterior preservada").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text("Proposta nova").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(!fact.matches(context.entries) || !canWrite || approvalInProgress)
                        .accessibilityLabel("Incluir \(fact.draft.label) no recorte do IPS")
                        DisclosureGroup("Ver trecho original") {
                            Text(fact.draft.quote).textSelection(.enabled)
                            Text(fact.source.path).font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("A aprovação registra o conjunto escolhido para o IPS. A assinatura digital ICP-Brasil ainda não está disponível nesta versão.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Créditos de terminologia") {
                Text("This material contains content from LOINC (http://loinc.org). LOINC is copyright © Regenstrief Institute, Inc. and the Logical Observation Identifiers Names and Codes (LOINC) Committee and is available at no cost under the license at http://loinc.org/license. LOINC® is a registered United States trademark of Regenstrief Institute, Inc.")
                Link("Licença LOINC", destination: URL(string: "https://loinc.org/license")!)
                Link("UCUM — copyright ©1999–2024 Regenstrief Institute, Inc.; licença e ausência de garantias", destination: URL(string: "https://ucum.org/license")!)
            }.font(.caption).foregroundStyle(.secondary)
            HStack {
                if approvalInProgress { ProgressView().controlSize(.small) }
                Button("Aprovar e exportar IPS…", systemImage: "checkmark.seal") { export(ips: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canApprove)
                Button("Exportar wiki OKF…") { export(ips: false) }
                    .disabled(summary.sourceFingerprint != context.fingerprint || approvalInProgress)
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let issue { Text(issue).foregroundStyle(.secondary).textSelection(.enabled) }
        }.padding(24).frame(minWidth: 700, minHeight: 560)
            .onAppear {
                selectedIDs = Set(candidateFacts.filter { reviews.decision(for: $0) != .rejected }.map(\.id))
            }
    }

    private func selectionBinding(for fact: PatientWikiFact) -> Binding<Bool> {
        Binding(get: { selectedIDs.contains(fact.id) }, set: { selected in
            if selected { selectedIDs.insert(fact.id) }
            else { selectedIDs.remove(fact.id) }
        })
    }

    private func export(ips: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Escolher destino"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        guard !approvalInProgress else { return }
        approvalInProgress = true
        let parentAccess = parent.startAccessingSecurityScopedResource()
        let vaultAccess = historyContext.authorizationURL.startAccessingSecurityScopedResource()
        var approvalSaved = false
        defer {
            if parentAccess { parent.stopAccessingSecurityScopedResource() }
            if vaultAccess { historyContext.authorizationURL.stopAccessingSecurityScopedResource() }
            approvalInProgress = false
        }
        do {
            let vaultPath = historyContext.vaultURL.resolvingSymlinksInPath().standardizedFileURL.path
            let parentPath = parent.resolvingSymlinksInPath().standardizedFileURL.path
            guard parentPath != vaultPath, !parentPath.hasPrefix(vaultPath + "/") else {
                throw VaultValidationIssue(rule: "wiki.export_destination", path: parent.path,
                    message: "Escolha uma pasta fora do cofre clínico para exportar.")
            }
            let approved: (reviews: PatientWikiReviews, data: Data?)
            if ips {
                approved = try approveSelection()
                approvalSaved = !selectedIDs.isEmpty
                currentExpectedReviews = approved.data
            } else { approved = (reviews, currentExpectedReviews) }
            let files: [String: Data]
            if ips {
                let ipsData = try PatientWikiExport.ips(
                    context: context, reviews: approved.reviews,
                    author: reviewer, selectedIDs: selectedIDs,
                    omittedFactCount: summary.omittedFactCount)
                var readme = "FHIR R4 4.0.1 / IPS 2.0.1. Recorte revisado de problemas, medicamentos, procedimentos, alergias, exames, imunizações e estilo de vida.\n"
                if summary.omittedFactCount > 0 {
                    readme += "Dados não incluídos no IPS: \(summary.omittedFactCount). As fontes permanecem separadas deste recorte.\n"
                }
                readme += "Dados ausentes não são negativos clínicos. Textos sem códigos permanecem textuais.\n"
                readme += "Não constitui integração validada com RNDS ou outro receptor.\n"
                readme += "Assinatura digital ICP-Brasil não está disponível nesta versão.\n"
                files = ["ips.json": ipsData, "LEIA-ME.txt": Data(readme.utf8)]
            } else { files = try PatientWikiExport.okf(summary: summary, context: context) }
            let destination = parent.appending(path: "OpenPEP-\(ips ? "IPS" : "Wiki-OKF")-" + UUID().uuidString)
            try PatientWikiExport.write(files, to: destination) {
                let store = PatientWikiStore()
                let saved = try store.load(for: context.patient)
                let latest = try PatientWikiContext.load(context: historyContext, corrections: saved.corrections?.markdown ?? "")
                let (_, reviewsData) = try store.loadReviews(for: context.patient)
                guard latest.fingerprint == context.fingerprint,
                      saved.summary?.persistedData == summary.persistedData,
                      reviewsData == approved.data else { throw PatientAIIssue.changed }
            }
            NSWorkspace.shared.activateFileViewerSelecting([destination])
            issue = ips ? "IPS aprovado e exportado." : "Wiki exportada."
        } catch {
            if approvalSaved && ips {
                issue = "Revisão salva; a exportação não foi concluída. " + error.localizedDescription
            } else {
                issue = error.localizedDescription
            }
        }
    }

    private func approveSelection() throws -> (reviews: PatientWikiReviews, data: Data?) {
        let store = PatientWikiStore()
        return try PatientWikiApproval.approve(summary: summary, context: context,
            historyContext: historyContext, reviews: reviews,
            expectedReviews: currentExpectedReviews, proposals: proposals,
            selectedIDs: selectedIDs, reviewer: reviewer) {
                let latestSaved = try store.load(for: context.patient)
                return try PatientWikiContext.load(context: historyContext,
                    corrections: latestSaved.corrections?.markdown ?? "")
            }
    }
}
