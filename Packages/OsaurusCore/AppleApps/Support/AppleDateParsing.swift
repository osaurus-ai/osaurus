//
//  AppleDateParsing.swift
//  osaurus
//
//  One lenient date contract for every Apple app tool. Models emit dates in
//  a handful of shapes — full ISO8601 (with or without fractional seconds or
//  an offset), `yyyy-MM-dd HH:mm[:ss]`, or a bare `yyyy-MM-dd`. All are
//  accepted; when the timezone is omitted local time is assumed; a bare date
//  means local midnight and reports `isDateOnly` so callers can treat an
//  end date as inclusive (start of the following day).
//
//  Output is ALWAYS ISO8601 with the local offset (`2026-09-19T20:15:00-07:00`)
//  so the model never sees a "Z" suffix on a local wall-clock time — the bug
//  the osaurus-tools Mail/Reminders plugins shipped with.
//

import Foundation

/// A parsed date plus whether the source carried a time component.
struct AppleParsedDate: Equatable, Sendable {
    let date: Date
    let isDateOnly: Bool

    /// For an end-of-range argument: a date-only end is inclusive, so the
    /// exclusive upper bound is the start of the next local day.
    var exclusiveRangeEnd: Date {
        guard isDateOnly else { return date }
        return Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date
    }
}

enum AppleDateParsing {
    /// The sentence every date parameter description repeats.
    static let contractDescription =
        "ISO 8601 (e.g. 2026-09-19T14:30:00-07:00 or 2026-09-19T14:30), \"2026-09-19 14:30\", or a bare date \"2026-09-19\". If the timezone is omitted local time is assumed; a bare date means local midnight (an end date is inclusive)."

    /// Parse a lenient date string. `nil` when nothing matches.
    static func parse(_ raw: String, calendar: Calendar = .current) -> AppleParsedDate? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // Bare date: yyyy-MM-dd
        if let dateOnly = matchDateOnly(s, calendar: calendar) {
            return AppleParsedDate(date: dateOnly, isDateOnly: true)
        }

        // Full ISO8601 with offset / Z (with or without fractional seconds).
        if let d = isoFractional.date(from: s) { return AppleParsedDate(date: d, isDateOnly: false) }
        if let d = isoPlain.date(from: s) { return AppleParsedDate(date: d, isDateOnly: false) }

        // Local-time shapes without an offset.
        let localFormats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
        ]
        for pattern in localFormats {
            // Non-lenient: `2026-02-31 10:00` is rejected instead of rolling
            // over into March.
            if let d = formatter(pattern, calendar: calendar).date(from: s) {
                return AppleParsedDate(date: d, isDateOnly: false)
            }
        }

        // Offset without colon (`2026-09-19T14:30:00-0700`) or short offsets.
        let offsetFormats = [
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mmZ",
            "yyyy-MM-dd HH:mm:ssZ",
            "yyyy-MM-dd HH:mmZ",
        ]
        for pattern in offsetFormats {
            if let d = formatter(pattern, calendar: calendar).date(from: s) {
                return AppleParsedDate(date: d, isDateOnly: false)
            }
        }

        // Unix seconds (a number) — some models fall back to epochs.
        if let seconds = Double(s), seconds > 1_000_000_000, seconds < 10_000_000_000 {
            return AppleParsedDate(date: Date(timeIntervalSince1970: seconds), isDateOnly: false)
        }
        return nil
    }

    private static func matchDateOnly(_ s: String, calendar: Calendar) -> Date? {
        guard s.count == 10, s[s.index(s.startIndex, offsetBy: 4)] == "-",
            s[s.index(s.startIndex, offsetBy: 7)] == "-"
        else { return nil }
        let parts = s.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
            (1 ... 12).contains(m), (1 ... 31).contains(d)
        else { return nil }
        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = d
        comps.hour = 0
        comps.minute = 0
        comps.second = 0
        // `Calendar.date(from:)` rolls an invalid day over into the next
        // month (`2026-02-31` → Mar 3). Reject instead: a model that asked for
        // the 31st of February should hear `invalid_args`, not get a silent
        // date in March.
        guard let date = calendar.date(from: comps) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == y, back.month == m, back.day == d else { return nil }
        return date
    }

    // MARK: - Formatter cache

    /// `DateFormatter` construction is expensive (ICU tables) and the Apple
    /// tools format hundreds of dates per listing. Formatters are immutable
    /// after creation and safe to share across threads, so they are cached
    /// per (pattern, calendar, time zone).
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var formatterCache: [String: DateFormatter] = [:]

    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso
    }()

    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso
    }()

    private static func formatter(_ pattern: String, calendar: Calendar, timeZone: TimeZone? = nil) -> DateFormatter {
        let tz = timeZone ?? calendar.timeZone
        let key = "\(pattern)|\(calendar.identifier)|\(tz.identifier)"
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = formatterCache[key] { return cached }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = tz
        f.isLenient = false
        f.dateFormat = pattern
        formatterCache[key] = f
        return f
    }

    // MARK: - Formatting

    /// ISO8601 with the local offset, seconds precision. Always a numeric
    /// offset (`+00:00` on UTC). Both `ISO8601DateFormatter` and
    /// `DateFormatter`'s `XXXXX` emit `Z` when the offset is zero, which
    /// the contract forbids — so the offset is written by hand.
    static func format(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = formatter("yyyy-MM-dd'T'HH:mm:ss", calendar: Calendar(identifier: .gregorian), timeZone: timeZone)
        let body = f.string(from: date)
        let seconds = timeZone.secondsFromGMT(for: date)
        let sign = seconds >= 0 ? "+" : "-"
        let absSeconds = abs(seconds)
        let hours = absSeconds / 3600
        let minutes = (absSeconds % 3600) / 60
        return String(format: "%@%@%02d:%02d", body, sign, hours, minutes)
    }

    /// `yyyy-MM-dd` in the local calendar (for all-day events / due dates).
    static func formatDateOnly(_ date: Date, calendar: Calendar = .current) -> String {
        formatter("yyyy-MM-dd", calendar: calendar).string(from: date)
    }

    /// Optional-friendly formatter.
    static func format(_ date: Date?) -> String? {
        date.map { format($0) }
    }

    /// Convert `DateComponents` (EventKit due dates) to a Date in the local
    /// calendar, if enough fields are present.
    static func date(from components: DateComponents?, calendar: Calendar = .current) -> Date? {
        guard let components else { return nil }
        if let date = components.date { return date }
        var comps = components
        if comps.calendar == nil { comps.calendar = calendar }
        if comps.timeZone == nil { comps.timeZone = calendar.timeZone }
        return calendar.date(from: comps)
    }
}
