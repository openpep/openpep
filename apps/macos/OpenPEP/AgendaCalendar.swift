// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import SwiftUI

enum AgendaViewMode: String, CaseIterable, Identifiable {
    case day
    case week
    case month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: "Dia"
        case .week: "Semana"
        case .month: "Mês"
        }
    }
}

enum AppointmentDefaults {
    static let initialModeKey = "openpep.agendaInitialMode"
    static let durationKey = "openpep.defaultAppointmentDurationMinutes"
    static let dayStartHourKey = "openpep.agendaDayStartHour"
    static let dayEndHourKey = "openpep.agendaDayEndHour"
    static let gridMinutesKey = "openpep.agendaGridMinutes"
    static let standardDurationMinutes = 30
    static let standardDayStartHour = 8
    static let standardDayEndHour = 18
    static let standardGridMinutes = 30
    static let allowedGridMinutes = [5, 10, 15, 30]

    static var durationMinutes: Int {
        let stored = UserDefaults.standard.integer(forKey: durationKey)
        return stored > 0 ? stored : standardDurationMinutes
    }

    static func validGridMinutes(_ value: Int) -> Int {
        allowedGridMinutes.contains(value) ? value : standardGridMinutes
    }
}

enum AppointmentTimeRange {
    static func end(start: Date, durationMinutes: Int) -> Date {
        start.addingTimeInterval(TimeInterval(durationMinutes * 60))
    }
}

enum AgendaCalendarModel {
    static func isPast(_ record: AppointmentRecord, now: Date) -> Bool {
        record.endDate <= now
    }

    static func hidesFromUpcomingList(_ record: AppointmentRecord, now: Date) -> Bool {
        isPast(record, now: now) && record.status != .inProgress && record.status != .arrived
    }

    static func tint(for record: AppointmentRecord, now: Date) -> Color {
        if isPast(record, now: now) { return .gray }
        return record.modality == .telemedicine ? .purple : .blue
    }

    struct TimelineHours: Equatable {
        let start: Int
        let end: Int
    }

    struct AppointmentPlacement: Identifiable {
        let appointment: AppointmentSummary
        let lane: Int
        let laneCount: Int

        var id: String { appointment.id }
    }

    static func interval(
        containing date: Date,
        mode: AgendaViewMode,
        calendar: Calendar = .current
    ) -> DateInterval {
        switch mode {
        case .day:
            let start = calendar.startOfDay(for: date)
            return DateInterval(
                start: start,
                end: calendar.date(byAdding: .day, value: 1, to: start) ?? start
            )
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: date)
                ?? interval(containing: date, mode: .day, calendar: calendar)
        case .month:
            return calendar.dateInterval(of: .month, for: date)
                ?? interval(containing: date, mode: .day, calendar: calendar)
        }
    }

    static func moving(
        _ date: Date,
        by value: Int,
        mode: AgendaViewMode,
        calendar: Calendar = .current
    ) -> Date {
        let component: Calendar.Component
        switch mode {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        }
        return calendar.date(byAdding: component, value: value, to: date) ?? date
    }

    static func days(
        containing date: Date,
        mode: AgendaViewMode,
        calendar: Calendar = .current
    ) -> [Date] {
        let interval = interval(containing: date, mode: mode, calendar: calendar)
        var days: [Date] = []
        var candidate = interval.start
        while candidate < interval.end {
            days.append(candidate)
            guard let next = calendar.date(byAdding: .day, value: 1, to: candidate) else { break }
            candidate = next
        }
        return days
    }

    static func monthGridDays(
        containing date: Date,
        calendar: Calendar = .current
    ) -> [Date] {
        let month = interval(containing: date, mode: .month, calendar: calendar)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: month.start)?.start ?? month.start
        let lastMonthDay = calendar.date(byAdding: .day, value: -1, to: month.end) ?? month.end
        let lastWeekEnd = calendar.dateInterval(of: .weekOfYear, for: lastMonthDay)?.end ?? month.end
        var days: [Date] = []
        var candidate = weekStart
        while candidate < lastWeekEnd {
            days.append(candidate)
            guard let next = calendar.date(byAdding: .day, value: 1, to: candidate) else { break }
            candidate = next
        }
        return days
    }

    static func slots(
        on day: Date,
        fromHour: Int = AppointmentDefaults.standardDayStartHour,
        toHour: Int = AppointmentDefaults.standardDayEndHour,
        intervalMinutes: Int = AppointmentDefaults.standardGridMinutes,
        calendar: Calendar = .current
    ) -> [Date] {
        guard fromHour >= 0, toHour <= 24, fromHour < toHour else { return [] }
        let intervalMinutes = AppointmentDefaults.validGridMinutes(intervalMinutes)
        let startOfDay = calendar.startOfDay(for: day)
        guard let first = calendar.date(byAdding: .hour, value: fromHour, to: startOfDay),
              let end = calendar.date(byAdding: .hour, value: toHour, to: startOfDay) else {
            return []
        }
        var result: [Date] = []
        var candidate = first
        while candidate < end {
            result.append(candidate)
            guard let next = calendar.date(byAdding: .minute, value: intervalMinutes, to: candidate) else { break }
            candidate = next
        }
        return result
    }

    static func appointments(
        _ candidates: [AppointmentSummary],
        in interval: DateInterval
    ) -> [AppointmentSummary] {
        candidates
            .filter {
                $0.record.status != .cancelled
                    && interval.contains($0.record.startDate)
            }
            .sorted { $0.record.startDate < $1.record.startDate }
    }

    static func appointments(
        _ candidates: [AppointmentSummary],
        inSlotStarting slot: Date,
        intervalMinutes: Int = AppointmentDefaults.standardGridMinutes,
        calendar: Calendar = .current
    ) -> [AppointmentSummary] {
        let end = calendar.date(
            byAdding: .minute,
            value: AppointmentDefaults.validGridMinutes(intervalMinutes),
            to: slot
        ) ?? slot
        return appointments(candidates, in: DateInterval(start: slot, end: end))
    }

    static func timelineHours(
        for days: [Date],
        appointments candidates: [AppointmentSummary],
        configuredStartHour: Int,
        configuredEndHour: Int,
        calendar: Calendar = .current
    ) -> TimelineHours {
        let configuredStart = min(max(configuredStartHour, 0), 23)
        let configuredEnd = min(max(configuredEndHour, configuredStart + 1), 24)
        guard let firstDay = days.first, let lastDay = days.last else {
            return TimelineHours(start: configuredStart, end: configuredEnd)
        }
        let intervalEnd = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay
        let visible = appointments(
            candidates,
            in: DateInterval(start: calendar.startOfDay(for: firstDay), end: intervalEnd)
        )
        let earliest = visible.map { calendar.component(.hour, from: $0.record.startDate) }.min()
        let latest = visible.map { appointment in
            if calendar.startOfDay(for: appointment.record.endDate)
                > calendar.startOfDay(for: appointment.record.startDate) {
                return 24
            }
            let components = calendar.dateComponents([.hour, .minute], from: appointment.record.endDate)
            return min(24, (components.hour ?? 0) + ((components.minute ?? 0) > 0 ? 1 : 0))
        }.max()
        return TimelineHours(
            start: min(configuredStart, earliest ?? configuredStart),
            end: max(configuredEnd, latest ?? configuredEnd)
        )
    }

    static func placements(
        _ candidates: [AppointmentSummary],
        on day: Date,
        calendar: Calendar = .current
    ) -> [AppointmentPlacement] {
        let dayInterval = interval(containing: day, mode: .day, calendar: calendar)
        let sorted = appointments(candidates, in: dayInterval)
        var result: [AppointmentPlacement] = []
        var group: [AppointmentSummary] = []
        var groupEnd: Date?

        func appendGroup(_ appointments: [AppointmentSummary]) {
            guard !appointments.isEmpty else { return }
            var laneEnds: [Date] = []
            var assignments: [(AppointmentSummary, Int)] = []
            for appointment in appointments {
                let lane = laneEnds.firstIndex { $0 <= appointment.record.startDate }
                    ?? laneEnds.count
                if lane == laneEnds.count {
                    laneEnds.append(appointment.record.endDate)
                } else {
                    laneEnds[lane] = appointment.record.endDate
                }
                assignments.append((appointment, lane))
            }
            let laneCount = max(1, laneEnds.count)
            result.append(contentsOf: assignments.map {
                AppointmentPlacement(appointment: $0.0, lane: $0.1, laneCount: laneCount)
            })
        }

        for appointment in sorted {
            if let end = groupEnd, appointment.record.startDate >= end {
                appendGroup(group)
                group = []
                groupEnd = nil
            }
            group.append(appointment)
            groupEnd = max(groupEnd ?? appointment.record.endDate, appointment.record.endDate)
        }
        appendGroup(group)
        return result
    }
}

struct AgendaCalendarView: View {
    let mode: AgendaViewMode
    let selectedDate: Date
    let appointments: [AppointmentSummary]
    let patients: [PatientSummary]
    let now: Date
    let dayStartHour: Int
    let dayEndHour: Int
    let gridMinutes: Int
    let onSelectDate: (Date) -> Void
    let onSelectSlot: (Date) -> Void
    let onEditAppointment: (String) -> Void

    @State private var hoveredSlot: Date?

    private let calendar = Calendar.current
    private let locale = Locale(identifier: "pt_BR")

    private var validGridMinutes: Int {
        AppointmentDefaults.validGridMinutes(gridMinutes)
    }

    private var slotHeight: CGFloat {
        max(12, CGFloat(validGridMinutes) * 1.2)
    }

    private var pointsPerMinute: CGFloat {
        slotHeight / CGFloat(validGridMinutes)
    }

    private var dayWidth: CGFloat {
        mode == .day ? 420 : 132
    }

    var body: some View {
        Group {
            switch mode {
            case .day:
                timeline(days: [calendar.startOfDay(for: selectedDate)])
            case .week:
                timeline(days: AgendaCalendarModel.days(containing: selectedDate, mode: .week))
            case .month:
                monthGrid
            }
        }
    }

    private func timeline(days: [Date]) -> some View {
        let hours = AgendaCalendarModel.timelineHours(
            for: days,
            appointments: appointments,
            configuredStartHour: dayStartHour,
            configuredEndHour: dayEndHour
        )
        return ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Color.clear.frame(width: 54, height: 34)
                    ForEach(days, id: \.self) { day in
                        Button {
                            onSelectDate(day)
                        } label: {
                            VStack(spacing: 2) {
                                Text(day.formatted(.dateTime.weekday(.abbreviated).locale(locale)))
                                    .font(.caption)
                                Text(day.formatted(.dateTime.day().month(.abbreviated).locale(locale)))
                                    .font(.callout.weight(calendar.isDateInToday(day) ? .semibold : .regular))
                            }
                            .frame(width: dayWidth)
                            .frame(minHeight: 34)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(locale)))
                    }
                }

                HStack(alignment: .top, spacing: 4) {
                    timeGutter(hours: hours)
                    ForEach(days, id: \.self) { day in
                        timelineDay(day, hours: hours)
                    }
                }
            }
            .padding(4)
        }
        .frame(minHeight: 360, maxHeight: 620)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
    }

    private func timeGutter(hours: AgendaCalendarModel.TimelineHours) -> some View {
        ZStack(alignment: .topTrailing) {
            ForEach(Array(hours.start...hours.end), id: \.self) { hour in
                Text(String(format: "%02d:00", hour))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .trailing)
                    .offset(y: max(0, CGFloat(hour - hours.start) * 60 * pointsPerMinute - 7))
            }
        }
        .frame(width: 54, height: timelineHeight(hours), alignment: .topTrailing)
    }

    private func timelineDay(
        _ day: Date,
        hours: AgendaCalendarModel.TimelineHours
    ) -> some View {
        let slots = AgendaCalendarModel.slots(
            on: day,
            fromHour: hours.start,
            toHour: hours.end,
            intervalMinutes: validGridMinutes
        )
        let placements = AgendaCalendarModel.placements(appointments, on: day)
        let visibleStart = calendar.date(
            byAdding: .hour,
            value: hours.start,
            to: calendar.startOfDay(for: day)
        ) ?? day

        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(slots, id: \.self) { slot in
                    Button {
                        onSelectSlot(slot)
                    } label: {
                        Color.clear
                            .frame(width: dayWidth, height: slotHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(gridLineColor(slot))
                            .frame(height: calendar.component(.minute, from: slot) == 0 ? 1 : 0.5)
                    }
                    .onHover { inside in
                        if inside { hoveredSlot = slot }
                        else if hoveredSlot == slot { hoveredSlot = nil }
                    }
                    .accessibilityLabel("Novo agendamento, \(slotAccessibilityLabel(slot))")
                }
            }

            if let slot = hoveredSlot, calendar.isDate(slot, inSameDayAs: day) {
                let offset = CGFloat(slot.timeIntervalSince(visibleStart) / 60) * pointsPerMinute
                let height = min(CGFloat(AppointmentDefaults.durationMinutes) * pointsPerMinute,
                                 max(0, timelineHeight(hours) - offset))
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.08))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.accentColor.opacity(0.65), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    .overlay(alignment: .topLeading) {
                        Text("\(timeLabel(slot))–\(timeLabel(AppointmentTimeRange.end(start: slot, durationMinutes: AppointmentDefaults.durationMinutes)))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Color.accentColor)
                            .padding(5)
                    }
                    .frame(width: dayWidth, height: height)
                    .offset(y: offset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            GeometryReader { geometry in
                ForEach(placements) { placement in
                    let startMinutes = placement.appointment.record.startDate
                        .timeIntervalSince(visibleStart) / 60
                    let durationMinutes = placement.appointment.record.endDate
                        .timeIntervalSince(placement.appointment.record.startDate) / 60
                    let laneWidth = geometry.size.width / CGFloat(placement.laneCount)
                    appointmentCard(placement.appointment)
                        .frame(
                            width: max(1, laneWidth - 3),
                            height: max(8, CGFloat(durationMinutes) * pointsPerMinute - 2),
                            alignment: .topLeading
                        )
                        .clipped()
                        .contentShape(Rectangle())
                        .offset(
                            x: CGFloat(placement.lane) * laneWidth + 1.5,
                            y: max(0, CGFloat(startMinutes) * pointsPerMinute + 1)
                        )
                }
            }
        }
        .frame(width: dayWidth, height: timelineHeight(hours), alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(Rectangle().stroke(.separator.opacity(0.55)))
    }

    private func timelineHeight(_ hours: AgendaCalendarModel.TimelineHours) -> CGFloat {
        CGFloat((hours.end - hours.start) * 60) * pointsPerMinute
    }

    private func gridLineColor(_ slot: Date) -> Color {
        calendar.component(.minute, from: slot) == 0
            ? Color(nsColor: .separatorColor)
            : Color(nsColor: .separatorColor).opacity(0.45)
    }

    @ViewBuilder
    private func appointmentCard(_ appointment: AppointmentSummary) -> some View {
            Button {
                onEditAppointment(appointment.id)
            } label: {
                appointmentCardContent(appointment)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(appointmentAccessibilityLabel(appointment))
            .accessibilityHint("Abre as ações do agendamento")
    }

    private func appointmentCardContent(_ appointment: AppointmentSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(patientName(for: appointment), systemImage: appointment.record.modality == .telemedicine ? "video" : "person.2")
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Text("\(timeLabel(appointment.record.startDate)) · \(durationLabel(appointment))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(6)
        .foregroundStyle(.primary)
        .background(AgendaCalendarModel.tint(for: appointment.record, now: now).opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(AgendaCalendarModel.tint(for: appointment.record, now: now))
                .frame(width: 3).allowsHitTesting(false)
        }
        .contentShape(Rectangle())
    }

    private var monthGrid: some View {
        let days = AgendaCalendarModel.monthGridDays(containing: selectedDate)
        let month = calendar.component(.month, from: selectedDate)
        let columns = Array(repeating: GridItem(.flexible(minimum: 72), spacing: 6), count: 7)
        return VStack(spacing: 6) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(rotatedWeekdaySymbols.enumerated()), id: \.offset) { _, weekday in
                    Text(weekday)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                ForEach(days, id: \.self) { day in
                    let count = appointmentsForDay(day).count
                    Button {
                        onSelectDate(day)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(day.formatted(.dateTime.day()))
                                .font(.callout.weight(calendar.isDate(day, inSameDayAs: selectedDate) ? .semibold : .regular))
                            if count > 0 {
                                Label(count == 1 ? "1 consulta" : "\(count) consultas", systemImage: "calendar")
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(calendar.component(.month, from: day) == month ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
                        .padding(7)
                        .background(
                            calendar.isDate(day, inSameDayAs: selectedDate)
                                ? Color.accentColor.opacity(0.16)
                                : Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    }
                    .buttonStyle(.plain)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.55)))
                    .accessibilityLabel(monthDayAccessibilityLabel(day, count: count))
                    .accessibilityHint("Abre este dia na agenda")
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
    }

    private var rotatedWeekdaySymbols: [String] {
        let symbols = ["Dom", "Seg", "Ter", "Qua", "Qui", "Sex", "Sáb"]
        let offset = max(0, calendar.firstWeekday - 1)
        return Array(symbols[offset...] + symbols[..<offset])
    }

    private func appointmentsForDay(_ day: Date) -> [AppointmentSummary] {
        let interval = AgendaCalendarModel.interval(containing: day, mode: .day)
        return AgendaCalendarModel.appointments(appointments, in: interval)
    }

    private func patientName(for appointment: AppointmentSummary) -> String {
        patients.first { $0.patientID == appointment.record.patientID }?.displayName
            ?? appointment.record.patientID
    }

    private func timeLabel(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(locale))
    }

    private func durationLabel(_ appointment: AppointmentSummary) -> String {
        "\(Int(appointment.record.endDate.timeIntervalSince(appointment.record.startDate) / 60)) min"
    }

    private func slotAccessibilityLabel(_ slot: Date) -> String {
        slot.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute().locale(locale))
    }

    private func appointmentAccessibilityLabel(_ appointment: AppointmentSummary) -> String {
        "\(patientName(for: appointment)), \(slotAccessibilityLabel(appointment.record.startDate)), \(durationLabel(appointment)), \(appointmentStatusLabel(appointment.record.status)), \(appointment.record.modality == .telemedicine ? "Teleconsulta" : "Presencial")\(AgendaCalendarModel.isPast(appointment.record, now: now) ? ", horário passado" : "")"
    }

    private func monthDayAccessibilityLabel(_ day: Date, count: Int) -> String {
        let date = day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(locale))
        let schedule = count == 0 ? "sem consultas" : (count == 1 ? "1 consulta" : "\(count) consultas")
        return "\(date), \(schedule)"
    }

    private func statusIcon(_ status: AppointmentStatus) -> String {
        switch status {
        case .scheduled: "clock"
        case .arrived: "person.crop.circle.badge.checkmark"
        case .inProgress: "stethoscope"
        case .completed: "checkmark.circle"
        case .cancelled: "xmark.circle"
        case .noShow: "person.crop.circle.badge.xmark"
        }
    }
}
