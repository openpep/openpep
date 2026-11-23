// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import OpenPEP

struct LayoutAdjustmentsTests {
    @Test func officeSelectionUsesThePersistedWhitespaceConvention() {
        #expect(AppointmentClock.location("Consultório\nRua A, 12\nCidade · SP") == "Consultório Rua A, 12 Cidade · SP")
    }

    @Test func quarterHoursCarryAcrossHourAndDay() throws {
        let formatter = ISO8601DateFormatter()
        for (input, expected) in [
            ("2026-09-08T19:07:00Z", "2026-09-08T19:00:00Z"),
            ("2026-09-08T19:08:00Z", "2026-09-08T19:15:00Z"),
            ("2026-09-08T19:31:00Z", "2026-09-08T19:30:00Z"),
            ("2026-09-08T23:59:00Z", "2026-09-09T00:00:00Z")
        ] {
            #expect(formatter.string(from: AppointmentClock.nearestQuarter(try #require(formatter.date(from: input)))) == expected)
        }
    }

    @Test func professionalFieldsValidateStructureWithoutAssertingIdentity() {
        #expect(DoctorProfileInput.crm("123456/sp") == "CRM 123456 / SP")
        #expect(DoctorProfileInput.crmIssue("123456/SP") == nil)
        #expect(DoctorProfileInput.crmIssue("123456/XX") != nil)
        #expect(DoctorProfileInput.cpfIssue("529.982.247-25") == nil)
        #expect(DoctorProfileInput.cpfIssue("111.111.111-11") != nil)
        #expect(DoctorProfileInput.phone("11987654321") == "(11) 98765-4321")
        #expect(DoctorProfileInput.phoneIssue("(11) 98765-4321") == nil)
        #expect(DoctorProfileInput.phoneIssue("123") != nil)
        #expect(DoctorProfileInput.cep("01001000") == "01001-000")
        #expect(DoctorProfileInput.emailIssue("medico@example.invalid") == nil)
        for value in ["a@b", "a..b@example.invalid", "a@example.invalid?bcc=other", "a\n@example.invalid"] {
            #expect(DoctorProfileInput.emailIssue(value) != nil)
        }
    }
}
