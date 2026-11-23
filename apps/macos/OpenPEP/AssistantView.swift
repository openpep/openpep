// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Combine
import SwiftUI

private struct OpenPEPAssistantActionKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    var openPEPAssistant: (() -> Void)? {
        get { self[OpenPEPAssistantActionKey.self] }
        set { self[OpenPEPAssistantActionKey.self] = newValue }
    }
}

struct AssistantView: View {
    @Bindable var session: AssistantSession
    @Bindable var voice: AssistantVoiceSession
    let contextLabel: String?
    let startVoice: () -> Void
    let submit: () -> Void
    let close: () -> Void
    let settings: () -> Void
    var readWiki: AssistantSession.ReadWiki? = nil
    @AppStorage(AITextSettings.enabledKey) private var allowsText = false
    @AppStorage(AITextSettings.assistantEnabledKey) private var allowsAssistant = false

    @AppStorage(AITextSettings.assistantVoiceEnabledKey) private var allowsVoice = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Assistente", systemImage: "sparkles").font(.headline)
                Spacer()
                Button(action: settings) { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).frame(width: 24, height: 24)
                    .accessibilityLabel("Configurar assistente").help("Assistência de IA")
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).frame(width: 24, height: 24)
                    .accessibilityLabel("Fechar assistente").help("Fechar · Esc")
            }
            ZStack(alignment: .topLeading) {
                AssistantPromptEditor(text: Binding(
                    get: { voice.isActive ? voice.preview : session.prompt },
                    set: { if !voice.isActive { session.prompt = $0 } }),
                    submit: { if !voice.isActive { submit() } }, close: close)
                    .disabled(voice.isActive)
                    .frame(height: 80)
                if session.prompt.isEmpty && !voice.isActive {
                    Text("Busque o paciente Ana Fictícia")
                        .font(.title3).foregroundStyle(.secondary)
                        .padding(.leading, 5).allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .searchClearButton(Binding(get: { session.prompt }, set: { voice.cancel(); session.prompt = $0 }))
            if let contextLabel {
                HStack {
                    Text("Paciente da tela: \(contextLabel)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let readWiki {
                        Button("Wiki e IPS", systemImage: "book") { session.readWiki(using: readWiki) }
                            .disabled(session.isBusy || voice.isActive)
                            .help("Consultar os arquivos atuais no Mac")
                    }
                }
            }
            Divider()
            if !allowsText || !allowsAssistant {
                Text("Ative o assistente nas configurações.")
                    .foregroundStyle(.secondary)
                Button("Abrir configurações", action: settings)
            }
            if let message = voice.message {
                Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if voice.isActive {
                Text(voice.state == .listening ? "Ouvindo o comando… pausas não executam ações." :
                     (voice.state == .finishing ? "Concluindo o reconhecimento…" : "Preparando a voz…"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = session.message {
                Text(message).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let patient = session.documentPatient {
                Text(patient.displayName).font(.headline)
                TextField("Finalidade ou título", text: $session.documentTitle)
                    .accessibilityLabel("Finalidade ou título do documento")
                TextEditor(text: $session.documentText).frame(height: 160)
                    .accessibilityLabel("Texto do documento informado pelo profissional")
                Text("Informe o conteúdo para revisão profissional. Preparar não emite, assina ou envia o documento.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Abrir compositor") { session.openDocumentComposer() }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.isBusy || !session.canOpenDocumentComposer)
            }
            if !session.candidates.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(session.candidates, id: \.patientID) { patient in
                            Button(patient.displayName + " · " + (patient.record?.birthDate ?? "Nascimento não informado")) { session.choose(patient) }
                                .disabled(session.isBusy)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 160)
            }
            if let reading = session.localReading {
                AssistantWikiReadingView(snapshot: reading, source: $session.source)
            }
            if let answer = session.answer {
                if let name = session.answerPatientName { Text(name).font(.headline) }
                if session.source != nil {
                    Button("Voltar à resposta", systemImage: "chevron.left") { session.source = nil }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let source = session.source {
                            Text(source.title).font(.headline)
                            Text(source.displayDate + " · " + source.status).font(.caption).foregroundStyle(.secondary)
                            ClinicalFormattedText(text: source.text).textSelection(.enabled)
                        } else {
                            Text("Proposta para revisão").font(.caption).foregroundStyle(.secondary)
                            ClinicalFormattedText(text: AssistantAnswerPresentation.plainText(answer.result.text)).textSelection(.enabled)
                            Text("Rascunhos e documentos sem texto disponível não foram consultados.")
                                .font(.caption).foregroundStyle(.secondary)
                            if !answer.citedSourceNumbers.isEmpty {
                                Text("Fontes da resposta").font(.headline)
                                ForEach(Array(answer.entries.enumerated()).filter { answer.citedSourceNumbers.contains($0.offset + 1) }, id: \.offset) { index, entry in
                                    Button("[F\(index + 1)] \(entry.title) · \(entry.displayDate)") { session.source = entry }.buttonStyle(.link)
                                }
                            }
                            if answer.citedSourceNumbers.count < answer.entries.count {
                                DisclosureGroup("Outras fontes consultadas") {
                                    ForEach(Array(answer.entries.enumerated()).filter { !answer.citedSourceNumbers.contains($0.offset + 1) }, id: \.offset) { index, entry in
                                        Button("[F\(index + 1)] \(entry.title) · \(entry.displayDate)") { session.source = entry }.buttonStyle(.link)
                                    }
                                }
                            }
                            if !answer.corrections.isEmpty {
                                DisclosureGroup("Correções humanas consideradas") { Text(answer.corrections).textSelection(.enabled) }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
                }.frame(height: 300).id(session.source?.id ?? "answer")
            }
            HStack {
                Spacer()
                if voice.isActive {
                    Button("Cancelar") { voice.cancel() }
                    if voice.state == .listening {
                        Button("Concluir e enviar") { voice.finish(interpret: true) }
                            .buttonStyle(.borderedProminent)
                    } else { ProgressView().controlSize(.small) }
                } else if session.isBusy {
                    ProgressView().controlSize(.small).accessibilityLabel("Interpretando pedido")
                    Button("Cancelar") { session.cancel() }
                } else if session.documentPatient != nil {
                    Button("Cancelar preparação") { session.reset() }
                } else {
                    if allowsVoice {
                        Button(action: startVoice) { Label("Falar", systemImage: "mic") }
                            .disabled(!allowsText || !allowsAssistant)
                    }
                    Button("Enviar", action: submit)
                        .buttonStyle(.borderedProminent)
                        .disabled(!allowsText || !allowsAssistant || session.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(20).frame(width: 520)
        .onExitCommand(perform: close)
        .onReceive(NotificationCenter.default.publisher(for: PatientClinicalChange.notification).receive(on: RunLoop.main)) { notification in
            if session.isReadingWiki {
                // No patient snapshot is published yet. Conservatively cancel
                // the pending local read rather than publish a late projection.
                session.invalidateLocalReading()
            } else if let reading = session.localReading,
                      PatientClinicalChange.matches(notification, patientURL: reading.patient.url) {
                session.invalidateLocalReading()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            session.invalidateLocalReading()
        }
    }
}

/// AppKit panel keeps the clinical view and its native undo manager mounted.
/// It also works above a sheet; the owning view still decides if navigation is allowed.
@MainActor
final class AssistantPanelController: NSObject, NSWindowDelegate {
    let session = AssistantSession()
    let voice = AssistantVoiceSession()
    weak var owner: NSWindow?
    private var panel: NSPanel?
    private weak var previousResponder: NSResponder?
    private weak var previousWindow: NSWindow?
    var isPresented: Bool { panel?.isVisible == true }
    var canNavigate: Bool { panel?.isKeyWindow == true && owner?.attachedSheet == nil }

    func show(contextLabel: String? = nil, initialPrompt: String = "", autoSubmit: Bool = false, submit: @escaping () -> Void,
              settings: @escaping () -> Void,
              readWiki: AssistantSession.ReadWiki? = nil,
              voicePermitted: @escaping () -> Bool = { !AssistantVoiceSession.clinicalCaptureActive }) {
        guard let owner else { return }
        if let panel, panel.isVisible { panel.makeKeyAndOrderFront(nil); return }
        session.reset()
        session.prompt = initialPrompt
        let parent = owner.attachedSheet ?? owner
        previousWindow = parent; previousResponder = parent.firstResponder
        let panel = AssistantPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
                            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Assistente"
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true; panel.becomesKeyOnlyIfNeeded = false
        panel.worksWhenModal = true; panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.contentView = NSHostingView(rootView: AssistantView(session: session, voice: voice, contextLabel: contextLabel, startVoice: { [weak self] in
            guard let self else { return }
            self.session.cancel(); self.session.showMessage(nil)
            self.voice.start(basePrompt: self.session.prompt, permitted: voicePermitted) { [weak self] text, interpret in
                guard let self, self.isPresented else { return }
                self.session.prompt = text
                if interpret { submit() }
            }
        },
            submit: submit, close: { [weak self] in self?.close() }, settings: settings, readWiki: readWiki))
        panel.setFrameOrigin(NSPoint(x: owner.frame.midX - panel.frame.width / 2,
                                     y: owner.frame.maxY - panel.frame.height - 100))
        self.panel = panel
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        if autoSubmit { submit() }
    }

    func close(restoreFocus: Bool = true) {
        voice.cancel()
        session.reset()
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.contentView = nil
        if restoreFocus, let window = previousWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            if let previousResponder { window.makeFirstResponder(previousResponder) }
        }
        previousResponder = nil; previousWindow = nil
    }

    private final class AssistantPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    func windowDidResignKey(_ notification: Notification) { close(restoreFocus: false) }
    func windowWillClose(_ notification: Notification) { close(restoreFocus: false) }
}

struct AssistantWindowAnchor: NSViewRepresentable {
    let controller: AssistantPanelController
    func makeNSView(context: Context) -> Anchor { Anchor(controller: controller) }
    func updateNSView(_ nsView: Anchor, context: Context) {}
    final class Anchor: NSView {
        let controller: AssistantPanelController
        init(controller: AssistantPanelController) { self.controller = controller; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); controller.owner = window }
    }
}

/// This text view belongs exclusively to the assistant prompt.
private struct AssistantPromptEditor: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var text: String
    let submit: () -> Void
    let close: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let editor = PromptTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 80))
        editor.isRichText = false; editor.allowsUndo = true; editor.drawsBackground = false
        editor.font = .preferredFont(forTextStyle: .title3)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = context.coordinator
        editor.string = text
        editor.setAccessibilityLabel("Pedido ao assistente")
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let editor = scroll.documentView as? NSTextView {
            editor.isEditable = isEnabled
            if editor.string != text { editor.string = text }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AssistantPromptEditor
        init(parent: AssistantPromptEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.submit(); return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.close(); return true
            }
            return false
        }
    }
    final class PromptTextView: NSTextView {
        override func keyDown(with event: NSEvent) {
            if [36, 76].contains(event.keyCode), event.modifierFlags.contains(.shift), !hasMarkedText() {
                insertNewlineIgnoringFieldEditor(nil)
                return
            }
            super.keyDown(with: event)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let target = window else { return }
            DispatchQueue.main.async { [weak self, weak target] in
                guard let self, let target, self.window === target else { return }
                target.makeFirstResponder(self)
            }
        }
    }
}
