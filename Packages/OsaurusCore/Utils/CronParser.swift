//
//  CronParser.swift
//  osaurus
//
//  A simple, dependency-free cron expression parser for Osaurus.
//  Supports: * , - / and standard 5-field format.
//

import Foundation

public struct CronParser: Sendable {
    private let minute: Set<Int>
    private let hour: Set<Int>
    private let dayOfMonth: Set<Int>
    private let month: Set<Int>
    private let dayOfWeek: Set<Int>

    // whether dayOfMonth or dayOfWeek are restricted (not '*')
    private let domRestricted: Bool
    private let dowRestricted: Bool

    /// initialize with a standard 5-field cron expression
    /// format: minute hour day-of-month month day-of-week
    public init?(_ expression: String) {
        let components = expression.split(separator: " ").map(String.init)
        guard components.count == 5 else { return nil }

        guard let m = Self.parseField(components[0], min: 0, max: 59),
            let h = Self.parseField(components[1], min: 0, max: 23),
            let dom = Self.parseField(components[2], min: 1, max: 31),
            let mon = Self.parseField(components[3], min: 1, max: 12),
            let dow = Self.parseField(components[4], min: 0, max: 6)
        else {  // 0=Sunday, 6=Saturday
            return nil
        }

        self.minute = m
        self.hour = h
        self.dayOfMonth = dom
        self.month = mon
        self.dayOfWeek = dow

        self.domRestricted = components[2] != "*"
        self.dowRestricted = components[4] != "*"
    }

    /// calculate the next matching date after the reference date
    public func nextDate(after referenceDate: Date) -> Date? {
        nextDate(after: referenceDate, calendar: .current)
    }

    func nextDate(after referenceDate: Date, calendar: Calendar) -> Date? {

        // start checking from the next minute
        guard let start = calendar.date(byAdding: .minute, value: 1, to: referenceDate) else { return nil }

        // Keep the actual occurrence of a repeated hour. Rebuilding its local
        // components can choose the first occurrence and move before the reference.
        guard var current = calendar.dateInterval(of: .minute, for: start)?.start else { return nil }

        // limit search to 5 years to prevent infinite loops
        let limit = calendar.date(byAdding: .year, value: 5, to: current)!

        while current < limit {
            let comps = calendar.dateComponents([.month, .day, .hour, .minute, .weekday], from: current)

            // 1. check Month
            guard let m = comps.month, month.contains(m) else {
                guard let next = calendar.date(byAdding: .month, value: 1, to: current) else { return nil }
                current = firstOfNextMonth(next, calendar: calendar)
                continue
            }

            // 2. check Day (standard cron logic: if both DOM and DOW are restricted, it's an OR)
            let d = comps.day!
            // calendar weekday is 1-7 (sun-sat), cron is 0-6
            let w = comps.weekday! - 1

            let domMatch = dayOfMonth.contains(d)
            let dowMatch = dayOfWeek.contains(w)

            let dayMatch: Bool
            if domRestricted && dowRestricted {
                dayMatch = domMatch || dowMatch
            } else {
                dayMatch = domMatch && dowMatch
            }

            if !dayMatch {
                guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { return nil }
                current = firstOfNextDay(next, calendar: calendar)
                continue
            }

            // 3. check Hour
            guard let h = comps.hour, hour.contains(h) else {
                guard let next = calendar.date(byAdding: .hour, value: 1, to: current) else { return nil }
                current = firstOfNextHour(next, calendar: calendar)
                continue
            }

            // 4. check Minute
            guard let minVal = comps.minute, minute.contains(minVal) else {
                guard let next = calendar.date(byAdding: .minute, value: 1, to: current) else { return nil }
                current = next
                continue
            }

            return current
        }

        return nil
    }

    // MARK: - Helper Methods for Jumping

    private func firstOfNextMonth(_ date: Date, calendar: Calendar) -> Date {
        var comps = calendar.dateComponents([.year, .month], from: date)
        comps.day = 1
        comps.hour = 0
        comps.minute = 0
        comps.second = 0
        return calendar.date(from: comps)!
    }

    private func firstOfNextDay(_ date: Date, calendar: Calendar) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day], from: date)
        comps.hour = 0
        comps.minute = 0
        comps.second = 0
        return calendar.date(from: comps)!
    }

    private func firstOfNextHour(_ date: Date, calendar: Calendar) -> Date {
        // Reconstructing the second repeated hour as local components can
        // return the first occurrence, making the search loop forever at a DST fold.
        calendar.dateInterval(of: .hour, for: date)!.start
    }

    // MARK: - Parser Logic

    private static func parseField(_ field: String, min: Int, max: Int) -> Set<Int>? {
        var result = Set<Int>()
        let parts = field.split(separator: ",")

        for part in parts {
            let partStr = String(part)
            if partStr == "*" {
                for i in min ... max { result.insert(i) }
            } else if partStr.contains("/") {
                let stepParts = partStr.split(separator: "/")
                guard stepParts.count == 2 else { return nil }
                let rangeStr = String(stepParts[0])
                guard let step = Int(stepParts[1]) else { return nil }

                let range: ClosedRange<Int>
                if rangeStr == "*" {
                    range = min ... max
                } else {
                    guard let r = parseRange(rangeStr, min: min, max: max) else { return nil }
                    range = r
                }

                var i = range.lowerBound
                while i <= range.upperBound {
                    result.insert(i)
                    i += step
                }
            } else if let range = parseRange(partStr, min: min, max: max) {
                for i in range { result.insert(i) }
            } else {
                return nil
            }
        }

        return result.isEmpty ? nil : result
    }

    private static func parseRange(_ rangeStr: String, min: Int, max: Int) -> ClosedRange<Int>? {
        let parts = rangeStr.split(separator: "-")
        if parts.count == 1 {
            guard let val = Int(parts[0]), val >= min, val <= max else { return nil }
            return val ... val
        } else if parts.count == 2 {
            guard let start = Int(parts[0]), let end = Int(parts[1]),
                start >= min, end <= max, start <= end
            else { return nil }
            return start ... end
        }
        return nil
    }
}
