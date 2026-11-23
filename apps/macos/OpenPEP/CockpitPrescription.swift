// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

struct CockpitPrescription: Codable, Equatable {
    struct Person: Codable, Equatable {
        var nome = "", documento = "", endereco = "", cidade = "", uf = "", nascimento = "", sexo = "", cid = "", telefone = ""
    }
    struct Emitter: Codable, Equatable {
        var endereco = "", cidade = "", uf = "", telefone = "", especialidade = "", cadastro = ""
    }
    struct Medication: Codable, Equatable, Identifiable {
        var id = UUID()
        var catalog: MedicationCatalogMetadata? = nil
        var assistance: CockpitMedicationCatalog.Entry? = nil
        var recipeOverride: String? = nil
        var nome = "", concentracao = "", forma = "", quantidade = "", unidade = "", posologia = "", tempo = "", orientacoes = ""
        mutating func apply(_ plan: CockpitMedicationCatalog.Plan) {
            posologia = plan.text
            if let quantity = plan.quantity { quantidade = String(quantity) }
            if let value = plan.tempo { tempo = value }
        }
        mutating func appendInstruction(_ note: String, recipeType: String) throws {
            let current = recipeType == "NRT" ? orientacoes : posologia
            guard !current.contains(note) else { return }
            let next = [current.trimmingCharacters(in: .whitespacesAndNewlines), note].filter { !$0.isEmpty }.joined(separator: " ")
            guard next.count <= (recipeType == "NRT" ? 300 : 600) else { throw CockpitError.message("A orientação excede o espaço do modelo. Resuma o texto antes de incluir.") }
            if recipeType == "NRT" { orientacoes = next } else { posologia = next }
        }
    }
    struct Prescriber: Codable, Equatable {
        var nome = "", crm = "", uf = "", cpf = ""
        var key: String { SNCRRegistry.hash(Data([cpf, crm, uf].joined(separator: "|").utf8)) }
        var isComplete: Bool {
            !nome.trimmingCharacters(in: .whitespaces).isEmpty && !crm.isEmpty && crm.allSatisfy(\.isNumber)
                && CockpitPrescription.states.contains(uf) && cpf.filter(\.isNumber).count == 11
        }
    }
    static let states = "AC AL AP AM BA CE DF ES GO MA MT MS MG PA PB PR PE PI RJ RN RS RO RR SC SP SE TO".components(separatedBy: " ")
    static let names = ["SIMPLE":"Receita simples", "NRA":"Notificação A", "NRB":"Notificação B", "NRB2":"Notificação B2", "RCE":"Controle especial",
        "RET":"Sujeita a retenção", "NRR":"Retinoides sistêmicos", "NRT":"Talidomida"]
    var id = UUID()
    var tipo = "RCE"
    var paciente = Person()
    var emitente = Emitter()
    var responsavel = Person()
    var prescriber = Prescriber()
    var medications = [Medication()]
    var includesGuardian = false
    var date = Date()
    var multiItem: Bool { ["RCE", "RET"].contains(tipo) }
    var needsBirth: Bool { ["RET", "NRR", "NRT"].contains(tipo) }
    var hash: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return SNCRRegistry.hash((try? encoder.encode(self)) ?? Data())
    }
    mutating func choose(_ entry: CockpitMedicationCatalog.Entry, for medicationID: UUID) throws {
        guard let index = medications.firstIndex(where: { $0.id == medicationID }) else { throw CockpitError.invalidRegistry }
        if medications[index].assistance?.id == entry.id, entry.matches(medications[index]) { return }
        guard medications.count == 1 || entry.recipeType == tipo else {
            throw CockpitError.message("Esta apresentação usa \(Self.names[entry.recipeType] ?? entry.recipeType). Emita em outra receita para preservar os outros medicamentos.")
        }
        if medications.count == 1 { tipo = entry.recipeType }
        let id = medications[index].id
        if medications[index].assistance?.id != entry.id {
            medications[index] = Medication(id: id)
        }
        medications[index].nome = entry.name; medications[index].concentracao = entry.concentration
        medications[index].forma = entry.form; medications[index].unidade = entry.unit
        medications[index].quantidade = entry.quantity.map(String.init) ?? ""
        medications[index].assistance = entry; medications[index].catalog = nil
    }
    func input(number: String? = nil) throws -> [String: Any] {
        let encoder = JSONEncoder()
        func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: encoder.encode(value)) }
        guard prescriber.isComplete, (1...(multiItem ? 3 : 1)).contains(medications.count) else {
            throw CockpitError.message("Confira nome, CPF, CRM/UF do médico e a quantidade de medicamentos para este modelo.")
        }
        for medication in medications {
            if let assistance = medication.assistance {
                guard assistance.matches(medication), (medication.recipeOverride ?? assistance.recipeType) == tipo else {
                    throw CockpitError.message("Confira o tipo de receita e a apresentação de \(medication.nome).")
                }
            }
            guard !medication.posologia.contains("__"), !medication.tempo.contains("__") else {
                throw CockpitError.message("Complete os espaços da posologia de \(medication.nome) antes de revisar.")
            }
        }
        var body: [String: Any] = ["tipo": tipo, "paciente": try object(paciente), "emitente": try object(emitente)]
        if multiItem { body["medicamentos"] = try object(medications) } else { body["medicamento"] = try object(medications[0]) }
        if includesGuardian { body["responsavel"] = try object(responsavel) }
        return ["id": id.uuidString.lowercased(), "body": body, "prescriber": try object(prescriber),
                "date": date.timeIntervalSince1970 * 1000, "number": number as Any? ?? NSNull()]
    }
    init(patient: PatientSummary) {
        paciente.nome = patient.record?.fullName ?? patient.displayName
        paciente.nascimento = patient.record?.birthDate ?? ""
        paciente.documento = patient.record?.identifiers.first(where: { $0.type == .cpf })?.value ?? ""
        paciente.telefone = patient.record?.contacts.first(where: { $0.type == .phone })?.value ?? ""
        if case let .mapping(address) = patient.record?.extensions["x_openpep_registration"] {
            func value(_ key: String) -> String {
                if case let .string(text) = address[key] { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
                return ""
            }
            paciente.endereco = [value("street"), value("number"), value("complement"), value("district"), value("postal_code")]
                .filter { !$0.isEmpty }.joined(separator: ", ")
            paciente.cidade = value("city"); paciente.uf = value("state").uppercased()
        }
        let doctor = DoctorProfileStore.load()
        prescriber.nome = doctor.fullName; prescriber.cpf = doctor.cpf
        let registration = doctor.registration.uppercased().replacingOccurrences(of: "CRM", with: "")
            .split(whereSeparator: { $0 == "/" || $0.isWhitespace }).map(String.init)
        if registration.count == 2, registration[0].allSatisfy(\.isNumber), Self.states.contains(registration[1]) {
            prescriber.crm = registration[0]; prescriber.uf = registration[1]
        }
        emitente.especialidade = doctor.specialty
        if let office = doctor.offices.first(where: { $0.id == doctor.defaultOfficeID }) ?? doctor.offices.first {
            emitente.endereco = [office.street, office.number, office.complement, office.neighborhood].filter { !$0.isEmpty }.joined(separator: ", ")
            emitente.cidade = office.city; emitente.uf = office.state; emitente.telefone = office.phone
        }
    }
}
