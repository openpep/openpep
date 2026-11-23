// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Read-only prompts for professional assessment; never clinical events or accepted IPS facts.
enum PatientIPSPrevention {
    static let source = URL(string: "https://www.gov.br/saude/pt-br/vacinacao/arquivos/calendario-nacional-de-vacinacao-idoso")!
    static let version = "PNI 2026 · pessoas com 60 anos ou mais"

    struct Reminder: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let detail: String
        let referenceDate: String?
    }

    static func reminders(birthDate: String?, accepted: [PatientWikiFact], on date: Date = Date()) -> [Reminder] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let age = PatientAge.years(fromStorage: birthDate, on: date, calendar: calendar), age >= 60 else { return [] }
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: date)
        func latest(_ names: Set<String>) -> String? {
            accepted.filter {
                $0.draft.kind == .immunization && $0.draft.ips?.eventStatus == "completed"
                && names.contains(PatientSearch.normalize($0.draft.label))
                && PatientWikiFact.validDate($0.draft.date) && $0.draft.date <= today
            }.map(\.draft.date).max()
        }
        let influenza = latest(["influenza", "vacina influenza", "influenza trivalente"])
        let covid = latest(["covid-19", "covid 19", "vacina covid-19", "vacina covid 19"])
        let reference = covid.flatMap(formatter.date(from:)).flatMap { calendar.date(byAdding: .month, value: 6, to: $0) }.map(formatter.string(from:))
        return [
            Reminder(id: "influenza-60", title: "Influenza · conferir temporada",
                detail: "Periodicidade anual. " + (influenza.map { "Última data revisada: " + PatientWikiFact.ipsDate($0) + "." } ?? "Histórico não confirmado."), referenceDate: nil),
            Reminder(id: "covid-60", title: "Covid-19 · conferir intervalo",
                detail: "Periodicidade semestral. " + (covid.map { "Última data revisada: " + PatientWikiFact.ipsDate($0) + "." } ?? "Histórico não confirmado."), referenceDate: reference)
        ]
    }
}
