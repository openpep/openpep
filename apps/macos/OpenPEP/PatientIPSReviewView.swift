// SPDX-License-Identifier: AGPL-3.0-or-later

import Combine
import SwiftUI

struct PatientWikiReviewView: View {
    let summary: PatientWikiSummary
    let sourceContext: PatientWikiContext
    let historyContext: PatientHistoryContext
    let canWrite: Bool
    var onEditingChange: (Bool) -> Void = { _ in }
    @State private var reviews: PatientWikiReviews?
    @State private var expectedData: Data?
    @State private var issue: String?
    @State private var showingExport = false
    @State private var onlyPending = false
    @State private var saving = false
    @State private var revision = 0
    @State private var editing: PatientIPSEditTarget?
    @State private var completed = false
    @State private var expandedSections: Set<PatientIPSSection> = [.problems]

    private var reviewer: String { PatientWikiProfessionalIdentity.displayName }
    private var canReview: Bool {
        canWrite && !saving && reviews != nil && !reviewer.isEmpty && sourceContext.writingAllowed
        && !sourceContext.patient.isArchived && summary.sourceFingerprint == sourceContext.fingerprint
    }
    private var facts: [PatientWikiFact] {
        let current = reviews?.candidates(for: summary, in: sourceContext) ?? summary.proposals
        let outdated = reviews?.outdatedAccepted(in: sourceContext) ?? []
        var seen = Set<String>()
        return (current + outdated).filter { seen.insert($0.id).inserted }
    }
    private func isPending(_ fact: PatientWikiFact) -> Bool {
        !fact.matches(sourceContext.entries) || reviews?.decision(for: fact) == nil || reviews?.decision(for: fact) == .pending
    }
    private var pendingCount: Int { facts.filter(isPending).count }
    private var reloadID: String { sourceContext.patient.patientID + sourceContext.fingerprint + PatientAIContext.digest(summary.persistedData) + String(revision) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("IPS").font(.title2.bold())
                    Text("Confirme ou ajuste cada informação.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Concluir revisão") { completed = true }
                    .disabled(reviews == nil || saving || facts.isEmpty)
                Menu {
                    Button("Preparar exportação…") { showingExport = true }
                        .disabled(!canReview)
                } label: { Image(systemName: "square.and.arrow.up") }
                .help("Exportar IPS")
            }
            HStack {
                Text(facts.isEmpty ? "Nenhum item disponível para revisão" : pendingCount == 0 ? "Sem propostas pendentes" : "\(pendingCount) itens a revisar")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Picker("Exibir", selection: $onlyPending) {
                    Text("Tudo").tag(false)
                    Text("A revisar").tag(true)
                }.pickerStyle(.segmented).frame(maxWidth: 210)
            }
            if reviewer.isEmpty {
                Text("Configure seu nome profissional nos ajustes do Solo para confirmar informações.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if summary.omittedFactCount > 0 {
                Text("Dados não incluídos no IPS: \(summary.omittedFactCount). Confira os documentos.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: 12) {
                ForEach(PatientIPSSection.allCases) { section in sectionView(section) }
            }
            if saving { ProgressView("Salvando revisão…").controlSize(.small) }
            if let issue { Text(issue).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .task(id: reloadID) { await load() }
        .onChange(of: editing != nil) { _, value in onEditingChange(value) }
        .onReceive(NotificationCenter.default.publisher(for: PatientClinicalChange.notification).receive(on: RunLoop.main)) { change in
            if PatientClinicalChange.matches(change, patientURL: sourceContext.patient.url), PatientClinicalChange.isReview(change) {
                revision += 1
            }
        }
        .sheet(item: $editing) { target in
            PatientIPSFactEditor(target: target, context: sourceContext,
                initialNote: target.fact.flatMap { reviews?.latestReview(for: $0)?.note } ?? "",
                canSave: canReview, saving: saving, issue: issue,
                onCancel: { editing = nil },
                onSave: { draft, note, decision in persist(target: target, draft: draft, note: note, decision: decision) })
        }
        .sheet(isPresented: $showingExport, onDismiss: { revision += 1 }) {
            PatientWikiExportView(summary: summary, context: sourceContext, historyContext: historyContext,
                reviews: reviews ?? .init(patientID: sourceContext.patient.patientID), expectedReviews: expectedData,
                reviewer: reviewer, proposals: reviews?.candidates(for: summary, in: sourceContext) ?? [], canWrite: canReview)
        }
        .alert(pendingCount == 0 ? "Revisão concluída" : "Ainda há itens a revisar", isPresented: $completed) {
            Button("Voltar ao IPS", role: .cancel) { }
        } message: {
            Text(pendingCount == 0
                ? "As decisões estão salvas. Indicações revisadas continuam sendo indicações, não registros de realização."
                : "\(pendingCount) itens continuam pendentes. As decisões já registradas foram preservadas.")
        }
    }

    private func sectionView(_ section: PatientIPSSection) -> some View {
        let all = facts.filter { section.contains($0.draft.kind) }
        let visible = all.filter { !onlyPending || isPending($0) }
            .sorted { !$0.isPlanned && $1.isPlanned }
        let expanded = expandedSections.contains(section)
        let pending = all.filter(isPending).count
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    if expanded { expandedSections.remove(section) }
                    else { expandedSections.insert(section) }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold)).frame(width: 12, height: 24)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Label(section.title, systemImage: section.symbol).font(.headline)
                                Spacer(minLength: 12)
                                Text(pending > 0 ? "\(pending) a revisar" : all.isEmpty ? "Não informado" : "Sem pendências")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if !expanded {
                                Text(sectionSummary(visible, section: section, hasFacts: !all.isEmpty))
                                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                    }.frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("\(expanded ? "Recolher" : "Expandir") \(section.title)")
                    .accessibilityValue("\(expanded ? "Expandido" : "Recolhido"), \(pending) itens a revisar")
                Button { issue = nil; editing = .init(section: section, fact: nil) } label: {
                    Image(systemName: "plus").frame(width: 24, height: 24)
                }.buttonStyle(.borderless).disabled(!canReview)
                    .accessibilityLabel("Adicionar em \(section.title)")
            }
            if expanded {
                Divider()
                if visible.isEmpty {
                    Text(all.isEmpty ? "Não informado" : "Nenhum item a revisar")
                        .foregroundStyle(.secondary).font(.callout).padding(.vertical, 8)
                }
                let groups = PatientIPSFactGroup.make(all, reviews: reviews).filter { group in
                    !onlyPending || ([group.primary] + group.alternatives).contains(where: isPending)
                }
                ForEach(groups) { group in
                    if group.id != groups.first?.id { Divider() }
                    factRow(group.primary)
                    if !group.alternatives.isEmpty {
                        DisclosureGroup("Outras redações da mesma fonte · \(group.alternatives.filter(isPending).count) a revisar") {
                            Text("A versão confirmada foi preservada. Confirmar outra redação substitui a anterior.")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(group.alternatives) { fact in factRow(fact).padding(.top, 8) }
                        }.font(.callout)
                    }
                }
                if section == .allergies && all.isEmpty {
                    Text("Sem registro não significa ausência de alergias.").font(.caption).foregroundStyle(.secondary)
                }
                if section == .results { PatientWikiCharts(facts: visible) }
                if section == .immunizations {
                    let reminders = PatientIPSPrevention.reminders(birthDate: sourceContext.patient.record?.birthDate,
                        accepted: reviews?.accepted(in: sourceContext) ?? [])
                    if !reminders.isEmpty {
                        DisclosureGroup("Conferir prevenção por idade") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(reminders) { reminder in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(reminder.title).font(.callout.weight(.medium))
                                        Text(reminder.detail).font(.caption)
                                        if let next = reminder.referenceDate {
                                            Text("Referência para avaliação: " + PatientWikiFact.ipsDate(next)).font(.caption)
                                        }
                                    }
                                }
                                Text("Confira carteira, contraindicações e condições especiais. Estes lembretes não confirmam indicação ou atraso e não entram no IPS exportado.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Link(PatientIPSPrevention.version, destination: PatientIPSPrevention.source).font(.caption)
                            }.padding(.top, 6)
                        }
                    }
                }
                if section == .results || section == .immunizations {
                    Text(section == .results
                         ? "Rastreamentos: confira histórico, idade e fatores de risco."
                         : "Confira a carteira e as indicações conforme idade e perfil.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !expanded && section == .allergies && all.isEmpty {
                Text("Sem registro não significa ausência de alergias.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }

    private func sectionSummary(_ visible: [PatientWikiFact], section: PatientIPSSection, hasFacts: Bool) -> String {
        guard !visible.isEmpty else { return hasFacts ? "Nenhum item a revisar" : "Sem informações registradas" }
        let included = PatientIPSFactGroup.make(visible, reviews: reviews).map(\.primary)
            .filter { reviews?.decision(for: $0) != .rejected }
        guard !included.isEmpty else { return "Itens retirados · expanda para reconsiderar" }
        let preview = included.prefix(3).map { fact in
            if section == .socialHistory {
                return fact.draft.label + ": " + fact.draft.text.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            }
            if section == .medications { return fact.draft.label + " · " + fact.ipsDetail }
            return fact.draft.label + (fact.isPlanned ? " (indicação)" : "")
        }.joined(separator: "; ")
        return preview + (included.count > 3 ? " · +\(included.count - 3) itens" : "")
    }

    private func factRow(_ fact: PatientWikiFact) -> some View {
        let decision = reviews?.decision(for: fact)
        let current = fact.matches(sourceContext.entries)
        let accepted = decision == .accepted && current
        return HStack(alignment: .top, spacing: 10) {
            Button { issue = nil; editing = .init(section: fact.ipsSection, fact: fact) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(fact.draft.label).font(.body.weight(.semibold))
                            .strikethrough(decision == .rejected)
                        if fact.draft.kind == .problem {
                            Text((fact.draft.ips ?? .init()).courseText).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(fact.ipsDetail).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    if [.procedure, .result, .screening, .immunization].contains(fact.draft.kind) {
                        Text((fact.draft.ips ?? .init()).eventText).font(.caption.weight(.medium))
                    }
                    Text(!current ? "Fonte alterada · revisão pendente" : accepted ? "Confirmado"
                        : decision == .rejected ? "Retirado · clique para reconsiderar" : "A revisar")
                        .font(.caption).foregroundStyle(accepted ? Color.accentColor : .secondary)
                    if let note = reviews?.latestReview(for: fact)?.note, !note.isEmpty {
                        Label(note, systemImage: "text.bubble").font(.callout).lineLimit(2)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Revisar \(fact.draft.label)")
            Button {
                if fact.isPlanned || decision == .rejected {
                    issue = nil; editing = .init(section: fact.ipsSection, fact: fact)
                } else {
                    persist(target: .init(section: fact.ipsSection, fact: fact), draft: fact.draft,
                        note: reviews?.latestReview(for: fact)?.note ?? "", decision: accepted ? .pending : .accepted)
                }
            } label: {
                Image(systemName: accepted ? "checkmark.circle.fill" : fact.isPlanned ? "ellipsis.circle" : "checkmark.circle")
                    .font(.title3).frame(minWidth: 32, minHeight: 32)
            }.buttonStyle(.borderless).disabled(!canReview || !current)
                .accessibilityLabel(accepted ? "Rever \(fact.draft.label)" : "Confirmar \(fact.draft.label)")
                .help(fact.isPlanned ? "Avaliar indicação" : accepted ? "Voltar para revisão" : "Confirmar informação")
        }
    }

    private func persist(target: PatientIPSEditTarget, draft: PatientWikiFactDraft, note: String,
                         decision: PatientWikiReview.Decision) {
        guard canReview else { return }
        saving = true; issue = nil
        let expected = expectedData, author = reviewer
        Task { @MainActor in
            do {
                try await Task.detached {
                    let access = historyContext.authorizationURL.startAccessingSecurityScopedResource()
                    defer { if access { historyContext.authorizationURL.stopAccessingSecurityScopedResource() } }
                    if let original = target.fact {
                        var edited = original; edited.draft = draft
                        try PatientIPSReviewService.save(original: original, edited: edited, decision: decision, note: note,
                            summary: summary, context: sourceContext, historyContext: historyContext,
                            expectedReviews: expected, reviewer: author)
                    } else {
                        try PatientIPSReviewService.add(draft: draft, decision: decision, note: note,
                            summary: summary, context: sourceContext, historyContext: historyContext,
                            expectedReviews: expected, reviewer: author)
                    }
                }.value
                editing = nil; revision += 1
            } catch {
                issue = (error as? PatientAIIssue) == .changed
                    ? "O IPS ou as fontes mudaram enquanto você revisava. Feche esta edição e confira o item atualizado. O que já estava salvo foi preservado."
                    : error.localizedDescription
                // Refresh the compare-and-swap token after an external review write.
                await load()
            }
            saving = false
        }
    }

    @MainActor private func load() async {
        do {
            let patient = sourceContext.patient, authorization = historyContext.authorizationURL
            let result = try await Task.detached {
                let access = authorization.startAccessingSecurityScopedResource()
                defer { if access { authorization.stopAccessingSecurityScopedResource() } }
                return try PatientWikiStore().loadReviews(for: patient)
            }.value
            try Task.checkCancellation()
            (reviews, expectedData) = result
        } catch is CancellationError { }
        catch { reviews = nil; issue = "As revisões não puderam ser lidas. " + error.localizedDescription }
    }
}

struct PatientIPSEditTarget: Identifiable, Sendable {
    let id = UUID()
    let section: PatientIPSSection
    let fact: PatientWikiFact?
}

struct PatientIPSFactEditor: View {
    let target: PatientIPSEditTarget
    let context: PatientWikiContext
    let canSave: Bool
    let saving: Bool
    let issue: String?
    let onCancel: () -> Void
    let onSave: (PatientWikiFactDraft, String, PatientWikiReview.Decision) -> Void
    @State private var draft: PatientWikiFactDraft
    @State private var details: PatientIPSDetails
    @State private var note: String

    init(target: PatientIPSEditTarget, context: PatientWikiContext, initialNote: String,
         canSave: Bool, saving: Bool, issue: String?, onCancel: @escaping () -> Void,
         onSave: @escaping (PatientWikiFactDraft, String, PatientWikiReview.Decision) -> Void) {
        self.target = target; self.context = context; self.canSave = canSave; self.saving = saving
        self.issue = issue; self.onCancel = onCancel; self.onSave = onSave
        let kinds: [PatientIPSSection: PatientWikiFactKind] = [.problems: .problem, .medications: .medication,
            .procedures: .procedure, .allergies: .allergy, .results: .result, .immunizations: .immunization, .socialHistory: .socialHistory]
        let value = target.fact?.draft ?? .init(kind: kinds[target.section]!, label: "", text: "", source: "F1", quote: "")
        _draft = State(initialValue: value); _details = State(initialValue: value.ips ?? .init())
        _note = State(initialValue: initialNote)
        if target.section == .socialHistory && value.ips == nil {
            _details = State(initialValue: .init(socialDomain: "tobacco"))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(target.fact == nil ? "Adicionar informação" : "Revisar informação").font(.title2.bold())
            Text(target.section.title).foregroundStyle(.secondary)
            ScrollView {
                Form {
                    if target.fact == nil && target.section == .results {
                        Picker("Tipo", selection: $draft.kind) {
                            Text("Exame / resultado").tag(PatientWikiFactKind.result)
                            Text("Rastreamento").tag(PatientWikiFactKind.screening)
                        }.onChange(of: draft.kind) { _, kind in
                            if kind != .screening { details.nextDate = "" }
                        }
                    }
                    TextField("Informação", text: $draft.label)
                    TextField("Detalhes", text: $draft.text, axis: .vertical).lineLimit(2...4)
                    if draft.kind == .socialHistory {
                        Picker("Domínio", selection: Binding(get: { details.socialDomain ?? "tobacco" }, set: { details.socialDomain = $0 })) {
                            ForEach(PatientIPSSocialDomain.allCases) { domain in Text(domain.title).tag(domain.rawValue) }
                        }
                    }
                    if draft.kind == .problem {
                        Picker("Evolução", selection: $details.course) {
                            Text("Não informada").tag("unknown")
                            Text("Crônico").tag("chronic"); Text("Recorrente").tag("recurrent"); Text("Atual").tag("current")
                        }
                    }
                    if draft.kind == .medication {
                        TextField("Dose", text: $draft.dosage)
                        TextField("Frequência", text: $details.frequency)
                        TextField("Via", text: $details.route)
                        Picker("Uso", selection: $draft.medicationUse) {
                            Text("Não confirmado").tag("unknown"); Text("Uso relatado").tag("reported"); Text("Prescrito").tag("prescribed")
                        }
                    }
                    if [.procedure, .result, .screening, .immunization].contains(draft.kind) {
                        Picker("Situação", selection: $details.eventStatus) {
                            Text("Não informada").tag("unknown"); Text("Realizado").tag("completed"); Text("A avaliar / indicado").tag("planned")
                        }
                    }
                    TextField("Data clínica (aaaa-mm-dd)", text: $draft.date)
                    if draft.kind == .screening || draft.kind == .immunization {
                        TextField("Próxima data (aaaa-mm-dd)", text: $details.nextDate)
                    }
                    if draft.kind == .measurement {
                        TextField("Valor", text: $draft.value)
                        Text("Unidade: \(draft.unit)").foregroundStyle(.secondary)
                    }
                    TextField("Observação do médico", text: $note, axis: .vertical).lineLimit(3...6)
                    if target.fact == nil || editedDraft != target.fact?.draft {
                        Text(target.fact == nil ? "Obrigatória: explique por que está incluindo esta informação."
                             : "Obrigatória após alterar a informação: descreva o ajuste realizado.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if target.fact == nil {
                        Picker("Documento de origem", selection: $draft.source) {
                            ForEach(Array(context.entries.enumerated()), id: \.offset) { index, entry in
                                Text(entry.title + " · " + entry.displayDate).tag("F\(index + 1)")
                            }
                        }
                        if let index = Int(draft.source.dropFirst()), context.entries.indices.contains(index - 1) {
                            DisclosureGroup("Consultar documento selecionado") {
                                Text(context.entries[index - 1].text).textSelection(.enabled)
                                    .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        TextField("Trecho literal do documento", text: $draft.quote, axis: .vertical).lineLimit(3...6)
                        Text("Escolha uma fonte e copie o trecho que sustenta a informação. Para nova informação clínica, registre-a na consulta.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        DisclosureGroup("Conferir origem") {
                            Text(draft.quote).textSelection(.enabled)
                            if let source = target.fact?.source,
                               let entry = context.entries.first(where: { $0.id == source.id && $0.source == source.path }) {
                                Text(entry.title + " · " + entry.displayDate).font(.caption).foregroundStyle(.secondary)
                            }
                            if let terminology = target.fact?.terminology {
                                Text("Termo associado: " + terminology.display).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.formStyle(.grouped)
            }
            Text("Explique alterações clínicas na observação. A fonte original é preservada.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = validationMessage {
                Label(message, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            } else if let issue { Text(issue).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                if target.fact != nil {
                    Button("Retirar proposta", role: .destructive) { onSave(target.fact!.draft, note, .rejected) }
                        .disabled(!canSave || saving)
                }
                Spacer()
                Button("Cancelar", action: onCancel).keyboardShortcut(.cancelAction).disabled(saving)
                Button("Salvar ajuste") { submit(.pending) }.disabled(!canSave || saving || validationMessage != nil)
                Button(details.eventStatus == "planned" ? "Confirmar avaliação" : "Confirmar") { submit(.accepted) }
                    .buttonStyle(.borderedProminent).disabled(!canSave || saving || validationMessage != nil)
            }
        }.padding(24).frame(minWidth: 600, idealWidth: 650, minHeight: 620)
    }

    private var editedDraft: PatientWikiFactDraft {
        var edited = draft
        if target.fact?.draft.ips == nil, details == PatientIPSDetails(), target.fact != nil {
            edited.ips = nil
        } else { edited.ips = details }
        return edited
    }

    private var validationMessage: String? {
        PatientIPSFormValidation.message(draft: editedDraft, original: target.fact, note: note, context: context)
    }

    private func submit(_ decision: PatientWikiReview.Decision) {
        guard validationMessage == nil else { return }
        onSave(editedDraft, note, decision)
    }
}
