// SPDX-License-Identifier: AGPL-3.0-or-later

import Charts
import SwiftUI

struct PatientWikiCharts: View {
    let facts: [PatientWikiFact]

    private var series: [(key: String, values: [PatientWikiFact])] {
        let conflicts = PatientWikiFact.conflictingIDs(in: facts)
        let measurements = facts.filter { $0.draft.kind == .measurement && !conflicts.contains($0.id) }
        return Dictionary(grouping: measurements) { fact in
            let method = fact.draft.method.isEmpty ? (fact.draft.measurement == "weight" ? "Método não registrado" : fact.source.id) : fact.draft.method
            return "\(fact.draft.measurement == "weight" ? "Peso" : "HbA1c") · \(fact.draft.unit) · \(method)"
        }.map { (key: $0.key, values: $0.value.sorted { $0.draft.date < $1.draft.date }) }
            .sorted { $0.key < $1.key }
    }

    var body: some View {
        if facts.contains(where: { $0.draft.kind == .measurement && PatientWikiFact.conflictingIDs(in: facts).contains($0.id) }) {
            Text("Medidas com a mesma data e valores divergentes ficaram fora dos gráficos. Confira os trechos antes de comparar.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if !series.isEmpty {
            DisclosureGroup("Medidas encontradas") {
                Text("Visualização preliminar dos pontos documentados, sem interpolação. Resultados sem método informado permanecem separados por fonte.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(series, id: \.key) { series in
                    let first = series.values[0].draft
                    Text("\(first.measurement == "weight" ? "Peso" : "HbA1c") · \(first.unit) · \(first.method.isEmpty ? "Método não informado" : first.method)")
                        .font(.headline)
                    Chart(series.values) { fact in
                        if let value = fact.value, let date = ISO8601DateFormatter().date(from: fact.draft.date + "T00:00:00Z") {
                            PointMark(x: .value("Data", date), y: .value("Valor", value))
                                .accessibilityLabel("\(fact.draft.date): \(fact.draft.value) \(fact.draft.unit)")
                        }
                    }.frame(height: 180).chartYScale(domain: .automatic(includesZero: true))
                        .chartXAxis {
                            AxisMarks(values: .automatic(desiredCount: 4)) {
                                AxisGridLine()
                                AxisValueLabel(format: Date.FormatStyle(date: .numeric, time: .omitted,
                                    locale: Locale(identifier: "pt_BR"), timeZone: TimeZone(secondsFromGMT: 0)!))
                            }
                        }
                    ForEach(series.values) { fact in
                        DisclosureGroup("\(fact.draft.date) · \(fact.draft.value) \(fact.draft.unit)") {
                            Text(fact.draft.quote).textSelection(.enabled)
                            Text(fact.source.path).font(.caption)
                        }
                    }
                }
            }
        }
    }
}
