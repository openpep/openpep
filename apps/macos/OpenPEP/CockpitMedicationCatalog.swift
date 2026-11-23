// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Offline snapshot of the Cockpit RX catalog. Suggestions always require professional review.
struct CockpitMedicationCatalog: Decodable {
    let version: Int
    let entries: [Entry]
    struct Plan: Codable, Equatable, Identifiable {
        var label: String
        var text: String
        var quantity: Int?
        var days: Int?
        var tempo: String?
        var id: String { label + text }
    }
    struct Entry: Codable, Equatable, Identifiable {
        let id: String
        let substanceID: String
        let name: String
        let keys: [String]
        let concentration: String
        let form: String
        let unit: String
        let quantity: Int?
        let recipeType: String
        let category: String
        let sales: Int
        let brands: [String]
        let dose: String
        let device: String
        let plans: [Plan]
        let notes: [String]
        let calculator: Calculator?
        let sources: [String]
        let publication: String
        let origin: String
        var presentation: String {
            [concentration, form, dose, device, brands.first ?? "", quantity.map { "\($0) \(unit)" } ?? unit]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        }
        func matches(_ medication: CockpitPrescription.Medication) -> Bool {
            medication.nome == name && medication.concentracao == concentration && medication.forma == form && medication.unidade == unit
        }
    }
    struct Calculator: Codable, Equatable {
        let mgKgDia: Double
        let mgKgDiaMax: Double?
        let dosesDia: Int
        let mgPorMl: Double?
        let mgPorUnidade: Double?
        let maxMgDia: Double?
        let doseAcumuladaMgKg: [Double]?
        let dias: Int
        let texto: String
        let componente: String?
        var steps: [Double] {
            guard let max = mgKgDiaMax else { return [mgKgDia] }
            return Array(Set([mgKgDia, (mgKgDia + max) / 2, max])).sorted()
        }
        /// Same rounding and bounds as Cockpit RX; no inferred schedule or patient weight.
        func calculate(weight: Double, perKg: Double?, unit: String) throws -> (plan: Plan, explanation: String) {
            func decimal(_ n: Double) -> String { n.formatted(.number.locale(Locale(identifier: "pt_BR")).precision(.fractionLength(0...1))) }
            guard weight.isFinite, mgKgDia > 0, dias > 0, dosesDia > 0 else { throw CockpitError.message("Confira o peso para calcular.") }
            if let capsule = mgPorUnidade {
                let rate = perKg ?? mgKgDia
                guard (20...200).contains(weight), capsule > 0, steps.contains(rate) else { throw CockpitError.message("Informe peso entre 20 e 200 kg e selecione a dose proposta.") }
                let units = max(1, Int((rate * weight / capsule).rounded()))
                let daily = Double(units) * capsule
                var explanation = "\(decimal(weight)) kg × \(decimal(rate)) mg/kg/dia → \(units) de \(decimal(capsule)) mg (\(decimal(daily)) mg/dia)."
                if let range = doseAcumuladaMgKg, range.count == 2 {
                    explanation += " Dose acumulada de \(decimal(range[0])) a \(decimal(range[1])) mg/kg: \(Int((range[0] * weight / daily).rounded())) a \(Int((range[1] * weight / daily).rounded())) dias nesta dose."
                }
                let text = texto.replacingOccurrences(of: "__", with: "\(units) \(units == 1 ? "cápsula" : "cápsulas") (\(decimal(daily)) mg)")
                guard units * dias <= 999 else { throw CockpitError.message("A quantidade calculada excede o limite do modelo.") }
                return (Plan(label: "Usar cálculo", text: text, quantity: units * dias, days: dias), explanation)
            }
            guard (1...150).contains(weight), let concentration = mgPorMl, concentration > 0 else { throw CockpitError.message("Informe peso entre 1 e 150 kg.") }
            let daily = min(mgKgDia * weight, maxMgDia ?? .infinity)
            let mg = (daily / Double(dosesDia)).rounded()
            let ml = (mg / concentration * 10).rounded() / 10
            guard ml > 0 else { throw CockpitError.message("O volume arredondado é zero. Confira a apresentação e a dose manualmente.") }
            var quantity: Int?
            let regex = try NSRegularExpression(pattern: #"(\d+(?:,\d+)?)\s*mL"#)
            let ns = unit as NSString
            if let match = regex.firstMatch(in: unit, range: NSRange(location: 0, length: ns.length)),
               let volume = Double(ns.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: ".")), volume > 0 {
                quantity = Int(ceil(ml * Double(dosesDia * dias) / volume))
            }
            guard quantity.map({ (1...999).contains($0) }) ?? true else { throw CockpitError.message("A quantidade calculada excede o limite do modelo.") }
            let text = texto.replacingOccurrences(of: "__ mL", with: "\(decimal(ml)) mL (\(decimal(mg)) mg\(componente.map { " de " + $0 } ?? ""))")
                .replacingOccurrences(of: "__", with: decimal(ml))
            let cap = daily < mgKgDia * weight ? " (limitado a \(decimal(daily)) mg/dia)" : ""
            return (Plan(label: "Usar cálculo", text: text, quantity: quantity, days: dias),
                    "\(decimal(mgKgDia)) mg/kg/dia\(cap), \(dosesDia) tomada(s): \(decimal(ml)) mL (\(decimal(mg)) mg) por tomada, \(dias) dias." + (quantity.map { " \($0) frasco(s)." } ?? ""))
        }
    }
    static func load() throws -> Self {
        guard let url = Bundle.main.url(forResource: "medication-assistance", withExtension: "json", subdirectory: "CockpitPDF")
                ?? Bundle.main.url(forResource: "medication-assistance", withExtension: "json") else { throw CockpitError.message("Catálogo assistido indisponível nesta instalação.") }
        let catalog = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard catalog.version == 1, Set(catalog.entries.map(\.id)).count == catalog.entries.count else { throw CockpitError.message("Não foi possível conferir o catálogo assistido.") }
        return catalog
    }
    func search(_ query: String, type: String) -> [Entry] {
        let words = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return Array(entries.filter { entry in
            words.isEmpty ? entry.recipeType == type : words.allSatisfy { word in entry.keys.contains { $0.hasPrefix(word) } }
        }.sorted {
            if ($0.recipeType == type) != ($1.recipeType == type) { return $0.recipeType == type }
            if $0.sales != $1.sales { return $0.sales > $1.sales }
            return $0.id < $1.id
        }.prefix(30))
    }
}
