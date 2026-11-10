import Foundation
import Testing

@testable import OsaurusCore

struct CronParserCalendarTransitionTests {
    struct Case: Sendable {
        let zone: String
        let expression: String
        let reference: String
        let expected: String
    }

    static let cases: [Case] = [
        .init(zone: "UTC", expression: "0 9 * * *", reference: "2026-11-01T08:30:00Z", expected: "2026-11-01T09:00:00Z"),
        .init(zone: "America/Los_Angeles", expression: "0 9 * * *", reference: "2026-11-01T08:30:00Z", expected: "2026-11-01T17:00:00Z"),
        .init(zone: "America/Los_Angeles", expression: "0 9 * * *", reference: "2026-10-31T16:00:00Z", expected: "2026-11-01T17:00:00Z"),
        .init(zone: "America/Los_Angeles", expression: "0 9 * * *", reference: "2026-11-10T08:30:00Z", expected: "2026-11-10T17:00:00Z"),
        .init(zone: "America/Los_Angeles", expression: "* * * * *", reference: "2026-11-01T09:30:20Z", expected: "2026-11-01T09:31:00Z"),
        .init(zone: "America/Los_Angeles", expression: "* * * * *", reference: "2026-11-01T08:59:50Z", expected: "2026-11-01T09:00:00Z"),
        .init(zone: "America/New_York", expression: "* * * * *", reference: "2026-11-01T06:30:20Z", expected: "2026-11-01T06:31:00Z"),
        .init(zone: "Europe/Berlin", expression: "* * * * *", reference: "2026-10-25T01:30:20Z", expected: "2026-10-25T01:31:00Z"),
        .init(zone: "Australia/Lord_Howe", expression: "* * * * *", reference: "2026-04-04T15:15:20Z", expected: "2026-04-04T15:16:00Z"),
        .init(zone: "America/Havana", expression: "* * * * *", reference: "2026-11-01T05:30:20Z", expected: "2026-11-01T05:31:00Z"),
        .init(zone: "Pacific/Chatham", expression: "* * * * *", reference: "2026-04-04T14:15:20Z", expected: "2026-04-04T14:16:00Z"),
        .init(zone: "America/Los_Angeles", expression: "30 1 * * *", reference: "2026-11-01T08:30:00Z", expected: "2026-11-01T09:30:00Z"),
        .init(zone: "America/Los_Angeles", expression: "30 1 * * *", reference: "2026-11-01T09:30:00Z", expected: "2026-11-02T09:30:00Z"),
        .init(zone: "America/Los_Angeles", expression: "* * * * *", reference: "2026-03-08T09:59:50Z", expected: "2026-03-08T10:00:00Z"),
        .init(zone: "America/Los_Angeles", expression: "30 2 * * *", reference: "2026-03-08T09:59:50Z", expected: "2026-03-09T09:30:00Z"),
        .init(zone: "Asia/Kathmandu", expression: "0 9 * * *", reference: "2026-11-01T00:00:00Z", expected: "2026-11-01T03:15:00Z"),
        .init(zone: "UTC", expression: "0 9 1 * 1", reference: "2026-11-10T00:00:00Z", expected: "2026-11-16T09:00:00Z"),
        .init(zone: "UTC", expression: "0 9 * 11 *", reference: "2026-10-31T16:00:00Z", expected: "2026-11-01T09:00:00Z"),
        .init(zone: "UTC", expression: "0 9 29 2 *", reference: "2027-03-01T00:00:00Z", expected: "2028-02-29T09:00:00Z"),
    ]

    @Test(arguments: cases)
    func nextMinuteAndHourKeepTheActualCalendarOccurrence(_ row: Case) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: row.zone))
        let formatter = ISO8601DateFormatter()
        let reference = try #require(formatter.date(from: row.reference))
        let expected = try #require(formatter.date(from: row.expected))
        let parser = try #require(CronParser(row.expression))
        let actual = try #require(parser.nextDate(after: reference, calendar: calendar))
        #expect(actual == expected)
        #expect(actual > reference)
        #expect(calendar.component(.second, from: actual) == 0)
    }

    @Test func impossibleCalendarDateStillReturnsNil() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let reference = try #require(ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z"))
        let parser = try #require(CronParser("0 9 30 2 *"))
        #expect(parser.nextDate(after: reference, calendar: calendar) == nil)
    }

    @Test func publicEntryPointUsesTheCurrentCalendar() throws {
        let reference = try #require(ISO8601DateFormatter().date(from: "2026-11-10T00:00:20Z"))
        let parser = try #require(CronParser("* * * * *"))
        #expect(parser.nextDate(after: reference) == parser.nextDate(after: reference, calendar: .current))
    }
}
