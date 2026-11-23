// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Testing
@testable import OpenPEP

struct CockpitMedicationAssistanceTests {
    func draft() -> CockpitPrescription {
        let patient = PatientSummary(patientID: "pt_0198f5c2-0000-7000-8000-000000000001", url: URL(fileURLWithPath: "/synthetic"), record: nil, rawAssets: [], encounters: [])
        var value = CockpitPrescription(patient: patient)
        value.prescriber = .init(nome: "Médico Sintético", crm: "000001", uf: "SP", cpf: "52998224725")
        return value
    }
    @Test func catalogSearchAndClassificationFollowPresentation() throws {
        let catalog = try CockpitMedicationCatalog.load()
        #expect(catalog.entries.count == 768)
        let byBrand = catalog.search("rivo", type: "RCE")
        #expect(!byBrand.isEmpty && byBrand.allSatisfy { $0.keys.contains("rivotril") })
        let clone = try #require(byBrand.first)
        var value = draft()
        try value.choose(clone, for: value.medications[0].id)
        #expect(value.tipo == "NRB" && value.medications[0].concentracao == clone.concentration)
        #expect(value.medications[0].unidade == clone.unit && value.medications[0].posologia.isEmpty)
        let tramadol = try #require(catalog.entries.first { $0.keys.contains("tramadol") && $0.concentration == "50 mg" })
        try value.choose(tramadol, for: value.medications[0].id)
        #expect(value.tipo == "RCE")
        let injection = try #require(catalog.entries.first { $0.form.contains("injetável") && $0.device.isEmpty })
        try value.choose(injection, for: value.medications[0].id)
        #expect(value.medications[0].quantidade.isEmpty)
        #expect(catalog.search("zzzsinteticoausente", type: "RCE").isEmpty)
    }
    @Test func incompatibleItemDoesNotMutateDraftAndReviewFailsOnWrongType() throws {
        let catalog = try CockpitMedicationCatalog.load()
        let entry = try #require(catalog.search("clonazepam", type: "RCE").first)
        var value = draft(); value.medications.append(.init())
        let before = value
        #expect(throws: (any Error).self) { try value.choose(entry, for: value.medications[1].id) }
        #expect(value == before)
        value.medications.removeLast()
        try value.choose(entry, for: value.medications[0].id)
        value.medications[0].posologia = "Texto sintético para teste."
        _ = try value.input()
        value.tipo = "NRA"
        #expect(throws: (any Error).self) { try value.input() }
        value.tipo = "NRB"; value.medications[0].concentracao = "alterada manualmente"
        #expect(throws: (any Error).self) { try value.input() }
        value.medications[0].assistance = nil
        _ = try value.input() // Explicit manual entry remains possible, without inferred classification.
    }
    @Test func plansRemainExplicitEditableAndBlankDosageCannotBeReviewed() throws {
        let catalog = try CockpitMedicationCatalog.load()
        let entry = try #require(catalog.entries.first { $0.keys.contains("clonazepam") && $0.form == "comprimido" })
        var value = draft()
        try value.choose(entry, for: value.medications[0].id)
        let before = value.hash
        value.medications[0].apply(try #require(entry.plans.first))
        #expect(value.hash != before)
        #expect(!value.medications[0].posologia.isEmpty && value.medications[0].quantidade == "30")
        value.medications[0].posologia = "Texto ajustado pelo profissional."
        let saved = value.medications[0]
        try value.choose(entry, for: saved.id)
        #expect(value.medications[0] == saved)
        try value.medications[0].appendInstruction("Orientação sintética.", recipeType: value.tipo)
        let once = value.medications[0].posologia
        try value.medications[0].appendInstruction("Orientação sintética.", recipeType: value.tipo)
        #expect(value.medications[0].posologia == once)
        #expect(throws: (any Error).self) { try value.medications[0].appendInstruction(String(repeating: "x", count: 601), recipeType: value.tipo) }
        let drops = try #require(catalog.entries.first { $0.keys.contains("clonazepam") && $0.form == "solução oral" })
        try value.choose(drops, for: saved.id)
        #expect(value.medications[0].posologia.isEmpty) // UI confirms replacement before calling choose.
        value.medications[0].apply(try #require(drops.plans.first))
        #expect(throws: (any Error).self) { try value.input() }
    }
    @Test func calculatorsMatchCockpitRoundingBoundsAndCaps() throws {
        let catalog = try CockpitMedicationCatalog.load()
        let capsule = try #require(catalog.entries.first { $0.keys.contains("isotretinoina") && $0.concentration == "20 mg" })
        let calc = try #require(capsule.calculator)
        let result = try calc.calculate(weight: 80, perKg: 0.5, unit: capsule.unit)
        #expect(result.plan.quantity == 60 && result.plan.text.contains("2 cápsulas (40 mg)"))
        #expect(throws: (any Error).self) { try calc.calculate(weight: 19, perKg: 0.5, unit: capsule.unit) }
        #expect(throws: (any Error).self) { try calc.calculate(weight: .nan, perKg: 0.5, unit: capsule.unit) }
        #expect(throws: (any Error).self) { try calc.calculate(weight: 80, perKg: 99, unit: capsule.unit) }
        let suspension = try #require(catalog.entries.first { $0.calculator?.mgPorMl == 80 && $0.keys.contains("amoxicilina") })
        let liquid = try #require(suspension.calculator)
        let dose = try liquid.calculate(weight: 20, perKg: nil, unit: suspension.unit)
        let expectedMg = (min(liquid.mgKgDia * 20, liquid.maxMgDia ?? .infinity) / Double(liquid.dosesDia)).rounded()
        #expect(dose.plan.text.contains("\(Int(expectedMg)) mg") && !dose.plan.text.contains("__"))
        #expect(throws: (any Error).self) { try liquid.calculate(weight: 0, perKg: nil, unit: suspension.unit) }
        #expect(throws: (any Error).self) { try liquid.calculate(weight: 151, perKg: nil, unit: suspension.unit) }
    }
    @Test func selectedCatalogSurvivesReopenAndLegacyDraftDecodes() throws {
        var value = draft()
        let legacy = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(CockpitPrescription.self, from: legacy).medications[0].assistance == nil)
        let catalog = try CockpitMedicationCatalog.load()
        try value.choose(try #require(catalog.search("semaglutida", type: "RET").first), for: value.medications[0].id)
        value.medications[0].posologia = "Texto de ensaio."
        let bytes = try JSONEncoder().encode(value)
        let reopened = try JSONDecoder().decode(CockpitPrescription.self, from: bytes)
        #expect(reopened == value && reopened.hash == value.hash)
        #expect(reopened.tipo == "RET" && reopened.medications[0].assistance?.origin == "19d91103d6e2140bb2ee84a1324dfc4a5bef5f83")
    }
}
