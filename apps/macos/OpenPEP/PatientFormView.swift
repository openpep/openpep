// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

private enum PhoneCountry: String, CaseIterable, Identifiable {
    case brazil
    case other

    var id: String { rawValue }
    var label: String { self == .brazil ? "Brasil" : "Outro país" }
}

private struct ContactDraft: Identifiable {
    let id = UUID()
    var type: PatientContactType
    var country: PhoneCountry
    var value: String
    var authorizedForCare: Bool
    let originalType: PatientContactType?
    let originalCountry: PhoneCountry?
    let originalDisplayValue: String?
    let originalStorageValue: String?

    init(contact: PatientContact) {
        type = contact.type
        authorizedForCare = contact.authorizedForCare
        originalType = contact.type
        originalStorageValue = contact.value
        if contact.type == .phone,
           let brazilianNumber = PatientPhoneText.brazilianNumber(fromStorage: contact.value) {
            country = .brazil
            value = brazilianNumber
        } else {
            country = contact.type == .phone ? .other : .brazil
            value = contact.value
        }
        originalCountry = country
        originalDisplayValue = value
    }

    init(type: PatientContactType, value: String, authorizedForCare: Bool) {
        self.type = type
        country = .brazil
        self.value = value
        self.authorizedForCare = authorizedForCare
        originalType = nil
        originalCountry = nil
        originalDisplayValue = nil
        originalStorageValue = nil
    }

    var storageValue: String {
        if type == originalType,
           country == originalCountry,
           value == originalDisplayValue,
           let originalStorageValue {
            return originalStorageValue
        }
        guard type == .phone, country == .brazil else { return value }
        return PatientPhoneText.storageValue(fromBrazilianNumber: value)
    }
}

private struct IdentifierDraft: Identifiable {
    let id = UUID()
    var type: PatientIdentifierType
    var value: String
    let originalType: PatientIdentifierType?
    let originalDisplayValue: String?
    let originalStorageValue: String?

    init(identifier: PatientIdentifier) {
        type = identifier.type
        value = identifier.type == .cpf ? PatientInputText.cpf(identifier.value) : identifier.value
        originalType = identifier.type
        originalDisplayValue = value
        originalStorageValue = identifier.value
    }

    init(type: PatientIdentifierType, value: String) {
        self.type = type
        self.value = value
        originalType = nil
        originalDisplayValue = nil
        originalStorageValue = nil
    }

    var storageValue: String {
        if type == originalType,
           value == originalDisplayValue,
           let originalStorageValue {
            return originalStorageValue
        }
        return value
    }
}

private struct AlertDraft: Identifiable {
    let id = UUID()
    var type: PatientAlertType
    var description: String
    var source: String
    var recordedAt: String
}

struct PatientFormView: View {
    let title: String
    let clinicalAlertsOnly: Bool
    let onCancel: () -> Void
    let onSave: (PatientRecordInput) -> Void
    let duplicateNames: (PatientRecordInput) -> [String]
    private let initialInput: PatientRecordInput

    @State private var registration: [String: YAMLValue]
    @State private var postalLookupMessage: String?
    @State private var lastLookupCEP: String
    @State private var postalLookupAttempt = 0
    @State private var automaticAddress: [String: String] = [:]
    @State private var fullName: String
    @State private var preferredName: String
    @State private var birthDate: String
    @State private var contacts: [ContactDraft]
    @State private var identifiers: [IdentifierDraft]
    @State private var alerts: [AlertDraft]
    @State private var duplicateWarning: String?
    @State private var confirmsCancel = false
    @State private var birthDateWasBlurred = false
    @State private var blurredCPFIDs: Set<UUID> = []

    init(
        title: String,
        record: PatientRecord?,
        onCancel: @escaping () -> Void,
        onSave: @escaping (PatientRecordInput) -> Void,
        duplicateNames: @escaping (PatientRecordInput) -> [String],
        clinicalAlertsOnly: Bool = false
    ) {
        self.title = title
        self.clinicalAlertsOnly = clinicalAlertsOnly
        self.onCancel = onCancel
        self.onSave = onSave
        self.duplicateNames = duplicateNames
        let registration: [String: YAMLValue]
        if case let .mapping(value) = record?.extensions["x_openpep_registration"] {
            registration = value
        } else { registration = [:] }
        _registration = State(initialValue: registration)
        if case let .string(cep) = registration["postal_code"],
           ["street", "city", "state"].allSatisfy({ key in
               if case let .string(value) = registration[key] { return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }; return false
           }) {
            _lastLookupCEP = State(initialValue: PatientInputText.asciiDigits(cep))
        } else { _lastLookupCEP = State(initialValue: "") }
        self.initialInput = PatientRecordInput(
            fullName: record?.fullName ?? "",
            preferredName: record?.preferredName,
            birthDate: record?.birthDate,
            contacts: record?.contacts ?? [],
            identifiers: record?.identifiers ?? [],
            alerts: record?.alerts ?? [],
            registration: registration
        ).normalized()
        _fullName = State(initialValue: record?.fullName ?? "")
        _preferredName = State(initialValue: record?.preferredName ?? "")
        _birthDate = State(initialValue: PatientDateText.displayValue(fromStorage: record?.birthDate))
        var contactDrafts = record?.contacts.map { ContactDraft(contact: $0) } ?? []
        for type in [PatientContactType.phone, .email] where !contactDrafts.contains(where: { $0.type == type }) {
            contactDrafts.append(ContactDraft(type: type, value: "", authorizedForCare: false))
        }
        _contacts = State(initialValue: contactDrafts)
        var identifierDrafts = record?.identifiers.map { IdentifierDraft(identifier: $0) } ?? []
        if !identifierDrafts.contains(where: { $0.type == .cpf }) {
            identifierDrafts.insert(IdentifierDraft(type: .cpf, value: ""), at: 0)
        }
        _identifiers = State(initialValue: identifierDrafts)
        _alerts = State(initialValue: record?.alerts.map {
            AlertDraft(type: $0.type, description: $0.description, source: $0.source, recordedAt: $0.recordedAt)
        } ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.title2.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if clinicalAlertsOnly {
                        alertsSection
                    } else {
                        identificationSection
                        contactsSection
                        identifiersSection
                        addressSection
                        DisclosureGroup("Observações") { notesSection }
                    }

                    if let duplicateWarning {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(duplicateWarning, systemImage: "person.2.badge.gearshape")
                                Text("Confira o cadastro. Se for outra pessoa, salve novamente para continuar.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        } label: {
                            Text("Possível duplicidade")
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancelar") {
                    if input.normalized() == initialInput {
                        onCancel()
                    } else {
                        confirmsCancel = true
                    }
                }
                .keyboardShortcut(.cancelAction)

                Button(duplicateWarning == nil ? "Salvar" : "Salvar mesmo assim") {
                    let names = duplicateNames(input)
                    let warning = names.isEmpty
                        ? nil
                        : "Cadastro com nome, nascimento ou CPF equivalente encontrado em: \(names.joined(separator: ", "))."
                    if warning == nil || duplicateWarning == warning {
                        onSave(input)
                    } else {
                        duplicateWarning = warning
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!birthDateIsValid || !cpfsAreValid)
            }
            .padding(18)
        }
        .controlSize(.large)
        .frame(minWidth: 560, idealWidth: 720, minHeight: 600)
        .task(id: "\(registrationText("postal_code").wrappedValue)-\(postalLookupAttempt)") { await lookupPostalCode() }
        .confirmationDialog(
            "Descartar alterações do cadastro?",
            isPresented: $confirmsCancel,
            titleVisibility: .visible
        ) {
            Button("Descartar alterações", role: .destructive, action: onCancel)
            Button("Continuar editando", role: .cancel) {}
        }
    }

    private var identificationSection: some View {
        formSection(title: "Identificação") {
            inputField(title: "Nome completo", prompt: "Nome para documentos e busca", text: $fullName)
            HStack(alignment: .top, spacing: 18) {
                inputField(title: "Nome preferido", prompt: "Como prefere ser chamado", text: $preferredName)
                VStack(alignment: .leading, spacing: 6) {
                Text("Data de nascimento")
                    .font(.callout.weight(.medium))
                AssistedTextField(
                    placeholder: "dd/mm/aaaa",
                    text: $birthDate,
                    accessibilityLabel: "Data de nascimento",
                    accessibilityHint: "Use dia, mês e ano com barras",
                    formatter: PatientInputText.date,
                    onFocusChange: { focused in
                        birthDateWasBlurred = !focused
                    }
                )
                    .frame(maxWidth: 220, alignment: .leading)
                if let age = derivedAge {
                    Label(PatientAge.label(for: age), systemImage: "birthday.cake")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Idade: \(PatientAge.label(for: age))")
                }
                if birthDateErrorIsVisible {
                    Label("Use uma data válida no formato dd/mm/aaaa.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Erro: use uma data válida no formato dia, mês e ano")
                }
                }.frame(width: 190, alignment: .leading)
            }
        }
    }

    private var contactsSection: some View {
        formSection(title: "Contatos") {
            ForEach($contacts) { $contact in
                let contactID = contact.id
                VStack(alignment: .leading, spacing: 10) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .bottom, spacing: 12) {
                            contactFields(contact: $contact)
                            removeContactButton(contactID)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            contactFields(contact: $contact)
                            removeContactButton(contactID)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            addButton("Adicionar contato", systemImage: "plus") {
                contacts.append(ContactDraft(type: .phone, value: "", authorizedForCare: false))
            }
        }
    }

    @ViewBuilder
    private func contactFields(contact: Binding<ContactDraft>) -> some View {
        Picker("Contato", selection: contactTypeBinding(contact)) {
            Text("Telefone").tag(PatientContactType.phone)
            Text("E-mail").tag(PatientContactType.email)
        }
        .labelsHidden()
        .frame(width: 110)
        if contact.wrappedValue.type == .phone {
            Picker("País", selection: countryBinding(contact)) {
                Text("🇧🇷 +55").tag(PhoneCountry.brazil)
                Text("Outro país").tag(PhoneCountry.other)
            }
            .labelsHidden()
            .frame(width: 120)
            if contact.wrappedValue.country == .brazil {
                AssistedTextField(
                    placeholder: "(00) 00000-0000", text: contact.value,
                    accessibilityLabel: "Telefone", accessibilityHint: "Inclua o DDD",
                    formatter: PatientInputText.brazilianPhone
                )
                .frame(minWidth: 150)
            } else {
                TextField("+código e número", text: contact.value)
                    .textFieldStyle(.roundedBorder)
            }
        } else {
            TextField("nome@exemplo.com", text: contact.value)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("E-mail")
        }
    }

    private func removeContactButton(_ contactID: UUID) -> some View {
        Button(role: .destructive) {
            contacts.removeAll { $0.id == contactID }
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Remover contato")
    }

    private func contactTypeBinding(_ contact: Binding<ContactDraft>) -> Binding<PatientContactType> {
        Binding(
            get: { contact.wrappedValue.type },
            set: { newType in
                guard newType != contact.wrappedValue.type else { return }
                contact.wrappedValue.type = newType
                contact.wrappedValue.value = ""
                contact.wrappedValue.country = .brazil
            }
        )
    }

    private func countryBinding(_ contact: Binding<ContactDraft>) -> Binding<PhoneCountry> {
        Binding(
            get: { contact.wrappedValue.country },
            set: { newCountry in
                guard newCountry != contact.wrappedValue.country else { return }
                contact.wrappedValue.country = newCountry
                contact.wrappedValue.value = ""
            }
        )
    }

    private var identifiersSection: some View {
        formSection(title: "CPF e documentos") {
            ForEach($identifiers) { $identifier in
                let identifierID = identifier.id
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .bottom, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("Tipo", selection: identifierTypeBinding($identifier)) {
                                Text("CPF").tag(PatientIdentifierType.cpf)
                                Text("Outro").tag(PatientIdentifierType.other)
                            }
                            .labelsHidden()
                            .frame(width: 110, alignment: .leading)
                            .accessibilityLabel("Tipo de identificador")
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            if identifier.type == .cpf {
                                AssistedTextField(
                                    placeholder: "000.000.000-00",
                                    text: $identifier.value,
                                    accessibilityLabel: "CPF",
                                    accessibilityHint: "Onze dígitos; a validação confirma apenas a estrutura",
                                    formatter: PatientInputText.cpf,
                                    onFocusChange: { focused in
                                        if focused {
                                            blurredCPFIDs.remove(identifierID)
                                        } else {
                                            blurredCPFIDs.insert(identifierID)
                                        }
                                    }
                                )
                                .frame(minWidth: 220)
                            } else {
                                TextField("Valor", text: $identifier.value)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(minWidth: 220)
                            }
                        }
                        Button(role: .destructive) {
                            identifiers.removeAll { $0.id == identifierID }
                            blurredCPFIDs.remove(identifierID)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remover identificador")
                    }
                    if cpfErrorIsVisible(identifier) {
                        Label(cpfErrorMessage(identifier.value), systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityLabel("Erro no CPF: \(cpfErrorMessage(identifier.value))")
                    }
                }
                .padding(.vertical, 4)
            }

            addButton("Adicionar identificador", systemImage: "plus") {
                identifiers.append(IdentifierDraft(type: .other, value: ""))
            }
        }
    }

    private func registrationText(_ key: String) -> Binding<String> {
        Binding(get: {
            if case let .string(value) = registration[key] { return value }
            return ""
        }, set: { value in
            if value.isEmpty { registration.removeValue(forKey: key) }
            else { registration[key] = .string(value) }
        })
    }

    private var addressSection: some View {
        formSection(title: "Endereço") {
            HStack(alignment: .top, spacing: 16) {
                inputField(title: "CEP", prompt: "00000-000", text: registrationText("postal_code"))
                    .frame(width: 140)
                inputField(title: "Logradouro", prompt: "Rua, avenida…", text: registrationText("street"))
            }
            Button("Buscar endereço pelo CEP") { lastLookupCEP = ""; postalLookupAttempt += 1 }
                .disabled(PatientInputText.asciiDigits(registrationText("postal_code").wrappedValue).count != 8)
            if let postalLookupMessage {
                Text(postalLookupMessage).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                inputField(title: "Número", prompt: "Número", text: registrationText("number")).frame(width: 140)
                inputField(title: "Complemento", prompt: "Apartamento, bloco…", text: registrationText("complement"))
            }
            HStack(spacing: 16) {
                inputField(title: "Bairro", prompt: "Bairro", text: registrationText("district"))
                inputField(title: "Cidade", prompt: "Cidade", text: registrationText("city"))
                inputField(title: "UF", prompt: "UF", text: registrationText("state"))
                    .frame(width: 80)
            }
        }
    }

    private var notesSection: some View {
        formSection(title: "") {
            TextField("Quem indicou, preferências de contato…", text: registrationText("notes"), axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Observações do cadastro")
        }
    }

    @MainActor
    private func lookupPostalCode() async {
        guard !clinicalAlertsOnly else { return }
        let cep = PatientInputText.asciiDigits(registrationText("postal_code").wrappedValue)
        guard cep.count == 8 else { postalLookupMessage = nil; return }
        guard cep != lastLookupCEP else { return }
        let before = registration
        do {
            try await Task.sleep(for: .milliseconds(450))
            postalLookupMessage = "Buscando endereço…"
            let fields = try await PostalCodeLookup.fetch(cep)
            try Task.checkCancellation()
            for (key, value) in fields where registration[key] == before[key] {
                if PostalCodeLookup.mayAutofill(current: registration[key], original: before[key], lastAutomatic: automaticAddress[key]) {
                    registration[key] = .string(value)
                    automaticAddress[key] = value
                }
            }
            lastLookupCEP = cep
            postalLookupMessage = "Endereço consultado. Campos já preenchidos manualmente foram preservados."
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled else { return }
            postalLookupMessage = "Endereço não encontrado. Preencha os campos manualmente."
        }
    }

    private var alertsSection: some View {
        formSection(title: "Alergias e alertas") {
            ForEach($alerts) { $alert in
                let alertID = alert.id
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .bottom, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Tipo").font(.caption.weight(.medium))
                            Picker("Tipo", selection: $alert.type) {
                                Text("Alergia").tag(PatientAlertType.allergy)
                                Text("Crítico").tag(PatientAlertType.critical)
                            }
                            .labelsHidden()
                            .frame(width: 150, alignment: .leading)
                        }
                        inputField(title: "Descrição", prompt: "O que deve ser destacado", text: $alert.description)
                        Button(role: .destructive) {
                            alerts.removeAll { $0.id == alertID }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remover alerta")
                    }
                    inputField(title: "Origem", prompt: "Por exemplo: relato da pessoa", text: $alert.source)
                }
                .padding(.vertical, 4)
            }

            addButton("Adicionar alerta", systemImage: "plus") {
                alerts.append(AlertDraft(
                    type: .allergy,
                    description: "",
                    source: "",
                    recordedAt: currentTimestamp()
                ))
            }
        }
    }

    private func formSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !title.isEmpty {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.5)))
    }

    private func inputField(
        title: String,
        prompt: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.callout.weight(.medium))
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func addButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }.buttonStyle(.borderless).font(.callout)
    }

    private var input: PatientRecordInput {
        PatientRecordInput(
            fullName: fullName,
            preferredName: preferredName,
            birthDate: PatientDateText.storageValue(fromDisplay: birthDate),
            contacts: contacts.map {
                PatientContact(type: $0.type, value: $0.storageValue, authorizedForCare: $0.authorizedForCare)
            },
            identifiers: identifiers.map {
                PatientIdentifier(type: $0.type, value: $0.storageValue)
            },
            alerts: alerts.map {
                PatientAlert(
                    type: $0.type,
                    description: $0.description,
                    source: $0.source,
                    recordedAt: $0.recordedAt
                )
            },
            registration: registration
        )
    }

    private var birthDateIsValid: Bool {
        PatientDateText.isValidDisplayValue(birthDate)
    }

    private var birthDateErrorIsVisible: Bool {
        guard !birthDateIsValid else { return false }
        return birthDateWasBlurred || PatientInputText.asciiDigits(birthDate).count == 8
    }

    private var derivedAge: Int? {
        PatientAge.years(fromStorage: PatientDateText.storageValue(fromDisplay: birthDate))
    }

    private var cpfsAreValid: Bool {
        identifiers.allSatisfy { identifier in
            guard identifier.type == .cpf else { return true }
            return identifier.value.isEmpty || PatientCPF.isStructurallyValid(identifier.value)
        }
    }

    private func cpfErrorIsVisible(_ identifier: IdentifierDraft) -> Bool {
        guard identifier.type == .cpf, !identifier.value.isEmpty,
              !PatientCPF.isStructurallyValid(identifier.value) else {
            return false
        }
        return blurredCPFIDs.contains(identifier.id)
            || PatientInputText.asciiDigits(identifier.value).count == 11
    }

    private func cpfErrorMessage(_ value: String) -> String {
        PatientInputText.asciiDigits(value).count == 11
            ? "CPF inválido. Confira os dígitos verificadores."
            : "O CPF precisa ter 11 dígitos."
    }

    private func identifierTypeBinding(
        _ identifier: Binding<IdentifierDraft>
    ) -> Binding<PatientIdentifierType> {
        Binding(
            get: { identifier.wrappedValue.type },
            set: { newType in
                guard newType != identifier.wrappedValue.type else { return }
                identifier.wrappedValue.type = newType
                identifier.wrappedValue.value = ""
                blurredCPFIDs.remove(identifier.wrappedValue.id)
            }
        )
    }

    private func currentTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date())
    }
}

private struct AssistedTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let accessibilityLabel: String
    let accessibilityHint: String
    let formatter: (String) -> String
    var onFocusChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: formatter(text))
        field.placeholderString = placeholder
        field.isBordered = false
        field.isBezeled = true
        field.controlSize = .large
        field.isEditable = true
        field.isSelectable = true
        field.bezelStyle = .roundedBezel
        field.lineBreakMode = .byClipping
        field.delegate = context.coordinator
        field.setAccessibilityLabel(accessibilityLabel)
        field.setAccessibilityHelp(accessibilityHint)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        field.setAccessibilityLabel(accessibilityLabel)
        field.setAccessibilityHelp(accessibilityHint)
        let formatted = formatter(text)
        if field.currentEditor() == nil, field.stringValue != formatted {
            field.stringValue = formatted
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AssistedTextField
        private var isFormatting = false

        init(parent: AssistedTextField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.onFocusChange(true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onFocusChange(false)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard !isFormatting,
                  let field = notification.object as? NSTextField,
                  let editor = field.currentEditor() as? NSTextView else {
                return
            }
            let raw = editor.string
            let selection = editor.selectedRange()
            let prefix = (raw as NSString).substring(to: min(selection.location, (raw as NSString).length))
            let digitOffset = PatientInputText.asciiDigits(prefix).count
            let formatted = parent.formatter(raw)

            if formatted != raw {
                isFormatting = true
                editor.string = formatted
                editor.setSelectedRange(NSRange(
                    location: caretPosition(in: formatted, afterDigitCount: digitOffset),
                    length: 0
                ))
                isFormatting = false
            }
            if parent.text != formatted {
                parent.text = formatted
            }
        }

        private func caretPosition(in value: String, afterDigitCount target: Int) -> Int {
            guard target > 0 else { return 0 }
            let characters = Array(value)
            var digitCount = 0
            var utf16Offset = 0
            for (index, character) in characters.enumerated() {
                utf16Offset += String(character).utf16.count
                if PatientInputText.asciiDigits(String(character)).count == 1 {
                    digitCount += 1
                }
                guard digitCount == target else { continue }
                var next = index + 1
                while next < characters.count,
                      PatientInputText.asciiDigits(String(characters[next])).isEmpty {
                    utf16Offset += String(characters[next]).utf16.count
                    next += 1
                }
                return utf16Offset
            }
            return (value as NSString).length
        }
    }
}
