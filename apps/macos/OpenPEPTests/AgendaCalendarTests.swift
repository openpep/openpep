// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
import SwiftUI
@testable import OpenPEP

struct AgendaCalendarTests {
    @Test("every elapsed appointment is gray while ongoing items remain available in the list")
    func pastAppearance() {
        let start = date(2026, 9, 5, 10)
        let end = date(2026, 9, 5, 11)
        let regular = appointment(id: "synthetic", start: start, end: end)
        #expect(!AgendaCalendarModel.isPast(regular.record, now: end.addingTimeInterval(-1)))
        #expect(AgendaCalendarModel.isPast(regular.record, now: end))
        #expect(AgendaCalendarModel.tint(for: regular.record, now: start) == Color.blue)
        #expect(AgendaCalendarModel.tint(for: regular.record, now: end) == Color.gray)
        for status in AppointmentStatus.allCases {
            let active = appointment(id: "synthetic", start: start, end: end, status: status)
            #expect(AgendaCalendarModel.isPast(active.record, now: end.addingTimeInterval(3600)))
            #expect(AgendaCalendarModel.tint(for: active.record, now: end) == Color.gray)
            #expect(AgendaCalendarModel.hidesFromUpcomingList(active.record, now: end)
                == (status != .inProgress && status != .arrived))
        }
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "pt_BR")
        calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        calendar.firstWeekday = 2
        return calendar
    }

    @Test("day, week and month keep the selected date inside their interval")
    func intervalsContainSelection() {
        let selected = date(2026, 9, 3, 14, 15)
        for mode in AgendaViewMode.allCases {
            let interval = AgendaCalendarModel.interval(
                containing: selected,
                mode: mode,
                calendar: calendar
            )
            #expect(interval.contains(selected))
        }

        let week = AgendaCalendarModel.interval(containing: selected, mode: .week, calendar: calendar)
        #expect(calendar.component(.weekday, from: week.start) == 2)
        #expect(AgendaCalendarModel.days(containing: selected, mode: .week, calendar: calendar).count == 7)
    }

    @Test("navigation moves by the visible calendar unit")
    func movesByVisibleUnit() {
        let selected = date(2026, 9, 3, 9, 0)
        let nextDay = AgendaCalendarModel.moving(selected, by: 1, mode: .day, calendar: calendar)
        let nextWeek = AgendaCalendarModel.moving(selected, by: 1, mode: .week, calendar: calendar)
        let nextMonth = AgendaCalendarModel.moving(selected, by: 1, mode: .month, calendar: calendar)

        #expect(calendar.dateComponents([.day], from: selected, to: nextDay).day == 1)
        #expect(calendar.dateComponents([.day], from: selected, to: nextWeek).day == 7)
        #expect(calendar.component(.month, from: nextMonth) == 10)
        #expect(calendar.component(.day, from: nextMonth) == 3)
    }

    @Test("timeline uses the configured grid interval")
    func buildsTimelineSlots() throws {
        let slots = AgendaCalendarModel.slots(on: date(2026, 9, 3), calendar: calendar)
        #expect(slots.count == 20)
        let first = try #require(slots.first)
        let last = try #require(slots.last)
        #expect(calendar.component(.hour, from: first) == 8)
        #expect(calendar.component(.minute, from: first) == 0)
        #expect(calendar.component(.hour, from: last) == 17)
        #expect(calendar.component(.minute, from: last) == 30)

        let fiveMinuteSlots = AgendaCalendarModel.slots(
            on: date(2026, 9, 3),
            fromHour: 9,
            toHour: 10,
            intervalMinutes: 5,
            calendar: calendar
        )
        #expect(fiveMinuteSlots.count == 12)
        #expect(calendar.component(.minute, from: try #require(fiveMinuteSlots.last)) == 55)
    }

    @Test("duration calculates the exact persisted end")
    func calculatesEndFromDuration() {
        let start = date(2026, 9, 3, 9, 15)
        let end = AppointmentTimeRange.end(start: start, durationMinutes: 45)
        #expect(end == date(2026, 9, 3, 10, 0))
    }

    @Test("month grid contains complete weeks around the selected month")
    func buildsCompleteMonthGrid() throws {
        let days = AgendaCalendarModel.monthGridDays(
            containing: date(2026, 9, 3),
            calendar: calendar
        )
        #expect(!days.isEmpty)
        #expect(days.count.isMultiple(of: 7))
        #expect(calendar.component(.weekday, from: try #require(days.first)) == calendar.firstWeekday)
        #expect(days.contains { calendar.component(.month, from: $0) == 9 })
    }

    @Test("appointment filtering includes starts in the visible interval and slot")
    func filtersAppointmentsByIntervalAndSlot() {
        let first = appointment(
            id: "appt_0198f6c0-0000-7000-8000-000000000001",
            start: date(2026, 9, 3, 9, 10),
            end: date(2026, 9, 3, 9, 40)
        )
        let second = appointment(
            id: "appt_0198f6c0-0000-7000-8000-000000000002",
            start: date(2026, 9, 4, 9, 10),
            end: date(2026, 9, 4, 9, 40)
        )
        let day = AgendaCalendarModel.interval(
            containing: date(2026, 9, 3),
            mode: .day,
            calendar: calendar
        )
        let slot = date(2026, 9, 3, 9, 0)

        #expect(AgendaCalendarModel.appointments([second, first], in: day).map(\.id) == [first.id])
        #expect(AgendaCalendarModel.appointments([second, first], inSlotStarting: slot, calendar: calendar).map(\.id) == [first.id])
    }

    @Test("cancelled appointments stay persisted but disappear from active agenda views")
    func filtersCancelledAppointments() {
        let active = appointment(
            id: "appt_0198f6c0-0000-7000-8000-000000000001",
            start: date(2026, 9, 3, 9, 0),
            end: date(2026, 9, 3, 9, 30)
        )
        let cancelled = appointment(
            id: "appt_0198f6c0-0000-7000-8000-000000000002",
            start: date(2026, 9, 3, 10, 0),
            end: date(2026, 9, 3, 10, 30),
            status: .cancelled
        )
        let day = AgendaCalendarModel.interval(
            containing: date(2026, 9, 3),
            mode: .day,
            calendar: calendar
        )

        #expect(AgendaCalendarModel.appointments([cancelled, active], in: day).map(\.id) == [active.id])
    }

    @Test("overlapping appointments receive side-by-side lanes without shifting time")
    func laysOutOverlaps() throws {
        let first = appointment(
            id: "appt_0198f6c0-0000-7000-8000-000000000001",
            start: date(2026, 9, 3, 9, 0),
            end: date(2026, 9, 3, 10, 0)
        )
        let second = appointment(
            id: "appt_0198f6c0-0000-7000-8000-000000000002",
            start: date(2026, 9, 3, 9, 30),
            end: date(2026, 9, 3, 10, 30)
        )
        let later = appointment(
            id: "appt_0198f6c0-0000-7000-8000-000000000003",
            start: date(2026, 9, 3, 11, 0),
            end: date(2026, 9, 3, 11, 30)
        )

        let placements = AgendaCalendarModel.placements([second, later, first], on: date(2026, 9, 3), calendar: calendar)
        let firstPlacement = try #require(placements.first { $0.id == first.id })
        let secondPlacement = try #require(placements.first { $0.id == second.id })
        let laterPlacement = try #require(placements.first { $0.id == later.id })
        #expect(firstPlacement.lane == 0)
        #expect(secondPlacement.lane == 1)
        #expect(firstPlacement.laneCount == 2)
        #expect(secondPlacement.laneCount == 2)
        #expect(laterPlacement.lane == 0)
        #expect(laterPlacement.laneCount == 1)
    }

    @Test("timeline honors configured hours and expands for real appointments")
    func expandsTimelineHours() {
        let early = appointment(
            id: "appt_0198f6c0-0000-7000-8000-000000000001",
            start: date(2026, 9, 3, 7, 30),
            end: date(2026, 9, 3, 8, 0)
        )
        let late = appointment(
            id: "appt_0198f6c0-0000-7000-8000-000000000002",
            start: date(2026, 9, 3, 17, 45),
            end: date(2026, 9, 3, 19, 10)
        )

        let hours = AgendaCalendarModel.timelineHours(
            for: [date(2026, 9, 3)],
            appointments: [late, early],
            configuredStartHour: 8,
            configuredEndHour: 18,
            calendar: calendar
        )
        #expect(hours == .init(start: 7, end: 20))
    }

    private func appointment(
        id: String,
        start: Date,
        end: Date,
        status: AppointmentStatus = .scheduled
    ) -> AppointmentSummary {
        AppointmentSummary(
            record: AppointmentRecord(
                schema: "openpep/appointment@1",
                appointmentID: id,
                patientID: "pt_0198f5c2-0000-7000-8000-000000000001",
                startsAt: timestamp(start),
                endsAt: timestamp(end),
                timeZone: "America/Sao_Paulo",
                modality: .inPerson,
                status: status,
                location: nil,
                remoteAccessURL: nil,
                administrativeNote: nil,
                encounterID: nil,
                createdAt: timestamp(start),
                updatedAt: timestamp(start),
                extensions: [:]
            ),
            url: URL(fileURLWithPath: "/tmp/\(id).yaml")
        )
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0,
        _ minute: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
