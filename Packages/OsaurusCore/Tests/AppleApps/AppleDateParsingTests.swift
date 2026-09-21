//
//  AppleDateParsingTests.swift
//  OsaurusCoreTests — AppleApps
//
//  Pins the lenient date contract every Apple tool parameter repeats:
//  ISO 8601 with/without fractional seconds and offsets, local-time shapes,
//  bare dates (date-only, inclusive end), unix seconds — and the output
//  contract (ISO 8601 with the LOCAL offset, never a fake "Z").
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("AppleDateParsing")
struct AppleDateParsingTests {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }

    @Test("ISO 8601 with offset, Z, and fractional seconds all resolve to the same instant")
    func isoVariants() throws {
        let a = try #require(AppleDateParsing.parse("2026-09-19T14:30:00-07:00"))
        let b = try #require(AppleDateParsing.parse("2026-09-19T21:30:00Z"))
        let c = try #require(AppleDateParsing.parse("2026-09-19T21:30:00.000Z"))
        let d = try #require(AppleDateParsing.parse("2026-09-19T14:30:00-0700"))
        #expect(a.date == b.date)
        #expect(a.date == c.date)
        #expect(a.date == d.date)
        #expect(!a.isDateOnly)
    }

    @Test("local-time shapes without an offset are interpreted in the given calendar's zone")
    func localShapes() throws {
        let expected = calendar.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 14, minute: 30))!
        for raw in ["2026-09-19T14:30", "2026-09-19T14:30:00", "2026-09-19 14:30", "2026-09-19 14:30:00"] {
            let parsed = try #require(AppleDateParsing.parse(raw, calendar: calendar), "failed: \(raw)")
            #expect(parsed.date == expected, "\(raw)")
            #expect(!parsed.isDateOnly)
        }
    }

    @Test("a bare date is local midnight and flagged date-only; the exclusive end is the next day")
    func bareDate() throws {
        let parsed = try #require(AppleDateParsing.parse("2026-09-19", calendar: calendar))
        #expect(parsed.isDateOnly)
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: parsed.date)
        #expect(comps.year == 2026 && comps.month == 9 && comps.day == 19)
        #expect(comps.hour == 0 && comps.minute == 0)
        // `exclusiveRangeEnd` uses Calendar.current; only the delta is asserted.
        let delta = parsed.exclusiveRangeEnd.timeIntervalSince(parsed.date)
        #expect(delta >= 23 * 3600 && delta <= 25 * 3600)
    }

    @Test("unix seconds are accepted; garbage and empty input are not")
    func unixAndGarbage() {
        #expect(AppleDateParsing.parse("1789000000")?.date == Date(timeIntervalSince1970: 1_789_000_000))
        #expect(AppleDateParsing.parse("") == nil)
        #expect(AppleDateParsing.parse("   ") == nil)
        #expect(AppleDateParsing.parse("next tuesday") == nil)
        #expect(AppleDateParsing.parse("2026-13-40") == nil)
        #expect(AppleDateParsing.parse("42") == nil)
    }

    @Test("an invalid day-of-month is rejected instead of rolling into the next month")
    func invalidDayOfMonth() {
        #expect(AppleDateParsing.parse("2026-02-31", calendar: calendar) == nil)
        #expect(AppleDateParsing.parse("2026-02-31 10:00", calendar: calendar) == nil)
        #expect(AppleDateParsing.parse("2026-04-31T09:00", calendar: calendar) == nil)
        #expect(AppleDateParsing.parse("2026-02-29", calendar: calendar) == nil)  // not a leap year
        #expect(AppleDateParsing.parse("2028-02-29", calendar: calendar) != nil)  // leap year
        #expect(AppleDateParsing.parse("2026-01-31", calendar: calendar) != nil)
    }

    @Test("formatters are cached and still produce identical output across zones")
    func formatterCacheIsStable() {
        let date = Date(timeIntervalSince1970: 1_789_000_000)
        let tz = TimeZone(identifier: "Europe/Berlin")!
        let first = AppleDateParsing.format(date, timeZone: tz)
        for _ in 0 ..< 50 { #expect(AppleDateParsing.format(date, timeZone: tz) == first) }
        #expect(first.hasSuffix("+02:00") || first.hasSuffix("+01:00"))
        let tokyo = AppleDateParsing.format(date, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        #expect(tokyo != first)
    }

    @Test("output is ISO 8601 with the local offset, not Z")
    func outputCarriesLocalOffset() {
        let date = Date(timeIntervalSince1970: 1_789_000_000)
        let pacific = AppleDateParsing.format(date, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        #expect(pacific.hasSuffix("-07:00") || pacific.hasSuffix("-08:00"))
        #expect(!pacific.hasSuffix("Z"))
        let tokyo = AppleDateParsing.format(date, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        #expect(tokyo.hasSuffix("+09:00"))
        let utc = AppleDateParsing.format(date, timeZone: TimeZone(identifier: "UTC")!)
        #expect(utc.hasSuffix("+00:00"))
        #expect(!utc.hasSuffix("Z"))
        // Round trip.
        #expect(AppleDateParsing.parse(pacific)?.date == date)
        #expect(AppleDateParsing.parse(tokyo)?.date == date)
        #expect(AppleDateParsing.parse(utc)?.date == date)
    }

    @Test("date-only formatting uses yyyy-MM-dd in the calendar's zone")
    func dateOnlyFormat() {
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5))!
        #expect(AppleDateParsing.formatDateOnly(midnight, calendar: calendar) == "2026-01-05")
    }

    @Test("the contract sentence names every accepted shape")
    func contractDescription() {
        let text = AppleDateParsing.contractDescription
        #expect(text.contains("ISO 8601"))
        #expect(text.contains("local time"))
        #expect(text.contains("inclusive"))
    }
}
