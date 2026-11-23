// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

enum CertificateWording {
    static func make(patientName: String, days: String, starting: Date, code: String, authorized: Bool) throws -> String {
        guard let count = Int(days), (1...3650).contains(count) else {
            throw VaultValidationIssue(rule: "certificate.days", path: "days", message: "Informe de 1 a 3.650 dias para gerar a redação.")
        }
        let cid = BundledDiagnosisCatalog.normalizedCode(code)
        guard cid.isEmpty || (authorized && BundledDiagnosisCatalog.codes.contains(cid)) else {
            throw VaultValidationIssue(rule: "certificate.cid", path: "code", message: "Selecione um CID válido e confirme a autorização do paciente, ou deixe o CID em branco.")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "dd/MM/yyyy"
        let name = patientName.isEmpty ? "o(a) paciente identificado(a) neste documento" : patientName
        var text = "Atesto, para os devidos fins, que \(name) necessita de afastamento de suas atividades por \(count) \(count == 1 ? "dia" : "dias"), a partir de \(formatter.string(from: starting))."
        if !cid.isEmpty {
            let formatted = cid.count == 4 ? String(cid.prefix(3)) + "." + String(cid.suffix(1)) : cid
            text += "\n\nCID-10: \(formatted). Diagnóstico incluído por solicitação e com autorização expressa do(a) paciente ou de seu representante legal."
        }
        return text
    }
}

struct CertificateWordingEditor: View {
    let patientName: String
    let diagnoses: [ConsultationFieldItem]
    var consultationDate: Date = Date()
    let onGenerate: (String) -> Void
    @State private var days = ""
    @State private var code = ""
    @State private var authorized = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Afastamento")
                TextField("Dias", text: $days).textFieldStyle(.roundedBorder).frame(width: 72)
                    .accessibilityLabel("Dias de afastamento")
                Text("dias").foregroundStyle(.secondary)
                Spacer()
            }
            HStack {
                TextField("CID opcional", text: $code).textFieldStyle(.roundedBorder).frame(width: 160)
                if !diagnoses.isEmpty {
                    Menu("Usar CID da consulta") {
                        ForEach(Array(diagnoses.enumerated()), id: \.offset) { _, item in
                            Button(item[.code] + " · " + item[.title]) { code = item[.code] }
                        }
                    }.fixedSize()
                }
                Spacer()
            }
            if !code.trimmingCharacters(in: .whitespaces).isEmpty {
                Toggle("Paciente autorizou expressamente a inclusão do CID", isOn: $authorized)
                    .toggleStyle(.checkbox)
            }
            HStack {
                Button("Gerar redação") {
                    do {
                        onGenerate(try CertificateWording.make(patientName: patientName, days: days,
                            starting: consultationDate, code: code, authorized: authorized))
                        error = nil
                    } catch { self.error = error.localizedDescription }
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
        }
    }
}
