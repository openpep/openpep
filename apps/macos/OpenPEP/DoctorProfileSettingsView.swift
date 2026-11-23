// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

struct DoctorProfileSettingsView: View {
    private let defaults: UserDefaults
    @State private var profile: DoctorProfile
    @State private var savedProfile: DoctorProfile
    @State private var error: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let profile = DoctorProfileStore.load(defaults: defaults)
        _profile = State(initialValue: profile)
        _savedProfile = State(initialValue: profile)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Identificação").font(.headline)
                    HStack(alignment: .top, spacing: 16) {
                        DoctorProfileField("Nome completo", text: $profile.fullName)
                        DoctorProfileField("Nome preferido", text: $profile.preferredName, prompt: "Como deseja aparecer no início")
                    }
                    HStack(alignment: .top, spacing: 16) {
                        DoctorProfileField("Especialidade", text: $profile.specialty)
                        DoctorProfileField("CRM / UF", text: $profile.registration, prompt: "CRM 123456 / RS",
                            formatter: DoctorProfileInput.crm, issue: DoctorProfileInput.crmIssue(profile.registration))
                        DoctorProfileField("RQE", text: $profile.rqe, formatter: { String(PatientInputText.asciiDigits($0).prefix(8)) })
                    }
                    HStack(alignment: .top, spacing: 16) {
                        DoctorProfileField("CPF", text: $profile.cpf, prompt: "000.000.000-00",
                            formatter: PatientInputText.cpf, issue: DoctorProfileInput.cpfIssue(profile.cpf))
                        DoctorProfileField("Telefone", text: $profile.phone, prompt: "(00) 00000-0000",
                            formatter: DoctorProfileInput.phone, issue: DoctorProfileInput.phoneIssue(profile.phone))
                        DoctorProfileField("E-mail", text: $profile.email, prompt: "nome@exemplo.com",
                            issue: DoctorProfileInput.emailIssue(profile.email))
                    }
                    Toggle("Incluir CPF nos documentos", isOn: $profile.printsCPF)
                }.padding(12)
            }
            VStack(alignment: .leading, spacing: 14) {
                Text("Consultórios").font(.headline)
                ForEach($profile.offices) { $office in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Text(office.name.isEmpty ? "Consultório" : office.name).font(.headline)
                                Spacer()
                                Button("Remover", systemImage: "minus.circle") {
                                    profile.offices.removeAll { $0.id == office.id }
                                    if profile.defaultOfficeID == office.id { profile.defaultOfficeID = profile.offices.first?.id }
                                }.labelStyle(.iconOnly).buttonStyle(.borderless)
                            }
                            DoctorOfficeFields(office: $office)
                            let isDefault = profile.defaultOfficeID == office.id || (profile.defaultOfficeID == nil && profile.offices.first?.id == office.id)
                            Button(isDefault ? "Consultório padrão" : "Usar como padrão",
                                systemImage: isDefault ? "checkmark.circle.fill" : "circle") {
                                profile.defaultOfficeID = office.id
                            }.buttonStyle(.borderless)
                        }.padding(12)
                    }
                }
                Button("Adicionar consultório", systemImage: "plus") { profile.offices.append(DoctorOffice()) }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Assinatura").font(.headline)
                    if let data = profile.signaturePNG, let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 280, maxHeight: 90)
                            .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("Imagem da assinatura cadastrada")
                    }
                    HStack {
                        Button(profile.signaturePNG == nil ? "Adicionar imagem…" : "Trocar imagem…", action: chooseSignature)
                        if profile.signaturePNG != nil {
                            Button("Remover imagem") { profile.signaturePNG = nil; profile.appliesSignatureImage = false }
                        }
                    }
                    Toggle("Aplicar imagem da assinatura nos documentos", isOn: $profile.appliesSignatureImage)
                        .disabled(profile.signaturePNG == nil)
                    Text("A imagem reproduz sua assinatura manuscrita. Não é uma assinatura digital com certificado.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Text(profile == savedProfile ? "Dados salvos" : "Alterações não salvas")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Salvar dados") {
                    do {
                        try DoctorProfileStore.save(profile, defaults: defaults)
                        savedProfile = profile
                        error = nil
                    } catch { self.error = "Não foi possível salvar os dados do médico." }
                }.buttonStyle(.borderedProminent)
                    .disabled(profile == savedProfile || !DoctorProfileInput.issues(profile).isEmpty)
            }
        }.frame(maxWidth: 1000, alignment: .leading)
    }
    private func chooseSignature() {
        let panel = NSOpenPanel()
        panel.title = "Imagem da assinatura"
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 5_000_000 else { throw DoctorProfileIssue.invalidImage }
            profile.signaturePNG = try DoctorProfileStore.normalizedSignature(Data(contentsOf: url))
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

private struct DoctorProfileField: View {
    let title: String
    @Binding var text: String
    var prompt = ""
    var formatter: (String) -> String = { $0 }
    var issue: String? = nil

    init(_ title: String, text: Binding<String>, prompt: String = "", formatter: @escaping (String) -> String = { $0 }, issue: String? = nil) {
        self.title = title; _text = text; self.prompt = prompt; self.formatter = formatter; self.issue = issue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.medium))
            TextField(prompt, text: Binding(get: { text }, set: { text = formatter($0) }))
                .textFieldStyle(.roundedBorder).accessibilityLabel(title)
            if let issue { Text(issue).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DoctorOfficeFields: View {
    @Binding var office: DoctorOffice
    @State private var lookupMessage: String?
    @State private var requestedCEP = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DoctorProfileField("Nome do consultório", text: $office.name)
            HStack(alignment: .top, spacing: 16) {
                DoctorProfileField("CEP", text: Binding(get: { office.postalCode }, set: { office.postalCode = $0; requestedCEP = PatientInputText.asciiDigits($0) }), prompt: "00000-000", formatter: DoctorProfileInput.cep,
                    issue: DoctorProfileInput.cepIssue(office.postalCode)).frame(maxWidth: 150)
                DoctorProfileField("Logradouro", text: $office.street)
                DoctorProfileField("Número", text: $office.number).frame(maxWidth: 100)
            }
            if let lookupMessage { Text(lookupMessage).font(.caption).foregroundStyle(.secondary) }
            HStack(alignment: .top, spacing: 16) {
                DoctorProfileField("Complemento", text: $office.complement)
                DoctorProfileField("Bairro", text: $office.neighborhood)
            }
            HStack(alignment: .top, spacing: 16) {
                DoctorProfileField("Cidade", text: $office.city)
                DoctorProfileField("UF", text: $office.state, formatter: { String($0.uppercased().prefix(2)) },
                    issue: office.state.isEmpty || DoctorProfileInput.states.contains(office.state) ? nil : "UF inválida").frame(maxWidth: 80)
                DoctorProfileField("Telefone", text: $office.phone, formatter: DoctorProfileInput.phone,
                    issue: DoctorProfileInput.phoneIssue(office.phone))
            }
        }
        .task(id: requestedCEP) {
            let cep = requestedCEP
            guard cep.count == 8 else { lookupMessage = nil; return }
            let before = office
            do {
                try await Task.sleep(for: .milliseconds(500))
                lookupMessage = "Buscando endereço…"
                let address = try await PostalCodeLookup.fetch(cep)
                try Task.checkCancellation()
                guard PatientInputText.asciiDigits(office.postalCode) == cep else { return }
                if office.street == before.street { office.street = address["street"] ?? "" }
                if office.neighborhood == before.neighborhood { office.neighborhood = address["district"] ?? "" }
                if office.city == before.city { office.city = address["city"] ?? "" }
                if office.state == before.state { office.state = address["state"] ?? "" }
                lookupMessage = nil
            } catch {
                if !Task.isCancelled { lookupMessage = "CEP não encontrado. Preencha o endereço manualmente." }
            }
        }
    }
}

enum DoctorProfileInput {
    static let states = Set("AC AL AP AM BA CE DF ES GO MA MT MS MG PA PB PR PE PI RJ RN RS RO RR SC SP SE TO".split(separator: " ").map(String.init))
    static func cep(_ value: String) -> String {
        let digits = String(PatientInputText.asciiDigits(value).prefix(8))
        return digits.count > 5 ? String(digits.prefix(5)) + "-" + digits.dropFirst(5) : digits
    }
    static func phone(_ value: String) -> String {
        if value.hasPrefix("+"), !value.hasPrefix("+55") { return value }
        let digits = value.hasPrefix("+55") ? String(PatientInputText.asciiDigits(value).dropFirst(2)) : value
        return PatientInputText.brazilianPhone(digits)
    }
    static func crm(_ value: String) -> String {
        let upper = value.uppercased()
        let parts = upper.replacingOccurrences(of: "CRM", with: "").split(whereSeparator: { $0 == "/" || $0.isWhitespace }).map(String.init)
        guard parts.count == 2, parts[0].allSatisfy(\.isNumber), states.contains(parts[1]) else { return upper }
        return "CRM \(parts[0]) / \(parts[1])"
    }
    static func cpfIssue(_ value: String) -> String? {
        value.isEmpty || PatientCPF.isStructurallyValid(value) ? nil : "Confira os 11 dígitos do CPF."
    }
    static func crmIssue(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        let parts = crm(value).replacingOccurrences(of: "CRM", with: "").split(whereSeparator: { $0 == "/" || $0.isWhitespace }).map(String.init)
        return parts.count == 2 && (1...8).contains(parts[0].count) && parts[0].allSatisfy({ $0.isASCII && $0.isNumber }) && states.contains(parts[1]) ? nil : "Use CRM 123456 / UF."
    }
    static func phoneIssue(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        let digits = PatientInputText.asciiDigits(value)
        let validCount = value.hasPrefix("+") ? (8...15).contains(digits.count) : (10...11).contains(digits.count)
        return validCount && TelemedicineContactResolver.option(for: .init(type: .phone, value: value, authorizedForCare: false)) != nil ? nil : "Confira o telefone e o DDD."
    }
    static func emailIssue(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        let valid = value.range(of: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$"#, options: .regularExpression) != nil
        return valid && !value.contains("..") && !value.hasPrefix(".") && !value.contains(".@") ? nil : "Informe um e-mail válido."
    }
    static func cepIssue(_ value: String) -> String? {
        value.isEmpty || PatientInputText.asciiDigits(value).count == 8 ? nil : "O CEP deve ter 8 dígitos."
    }
    static func issues(_ profile: DoctorProfile) -> [String] {
        [cpfIssue(profile.cpf), crmIssue(profile.registration), phoneIssue(profile.phone), emailIssue(profile.email)].compactMap { $0 }
        + profile.offices.flatMap { office in
            [cepIssue(office.postalCode), phoneIssue(office.phone), office.state.isEmpty || states.contains(office.state) ? nil : "UF inválida"].compactMap { $0 }
        }
    }
}
