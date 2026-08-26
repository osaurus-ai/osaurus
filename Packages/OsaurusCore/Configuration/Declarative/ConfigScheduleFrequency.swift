//
//  ConfigScheduleFrequency.swift
//  osaurus
//
//  Bidirectional mapping between the document's flat
//  `(frequency, frequency_value, frequency_time_of_day)` triple and
//  `ScheduleFrequency`. The parse direction preserves the lenient
//  weekday handling of the old `osaurus_schedule` tool ("Monday",
//  "MON", "Mondays" all resolve).
//

import Foundation

public enum ConfigScheduleFrequency {
    public static let validNames = [
        "once", "every_n_minutes", "hourly", "daily", "weekly", "monthly", "yearly", "cron",
    ]

    /// Parse the triple into a `ScheduleFrequency`, or a self-contained
    /// error message on failure.
    static func parse(
        frequency: String,
        value: String?,
        timeOfDay: String?
    ) -> Result<ScheduleFrequency, ConfigFrequencyError> {
        func parseTime(_ s: String?) -> (Int, Int)? {
            guard let s, let i = s.firstIndex(of: ":") else { return nil }
            guard let h = Int(s[..<i]), let m = Int(s[s.index(after: i)...]),
                (0 ..< 24).contains(h), (0 ..< 60).contains(m)
            else { return nil }
            return (h, m)
        }

        switch frequency.lowercased() {
        case "once":
            guard let v = value, let date = ISO8601DateFormatter().date(from: v) else {
                return .failure(.init("frequency `once` requires frequency_value = ISO8601 datetime."))
            }
            return .success(.once(date: date))
        case "every_n_minutes":
            guard let v = value, let n = Int(v), n >= 5 else {
                return .failure(.init("frequency `every_n_minutes` requires frequency_value >= 5."))
            }
            return .success(.everyNMinutes(minutes: n))
        case "hourly":
            return .success(.hourly(minute: Int(value ?? "") ?? 0))
        case "daily":
            guard let t = parseTime(timeOfDay) else {
                return .failure(.init("frequency `daily` requires frequency_time_of_day = `HH:mm`."))
            }
            return .success(.daily(hour: t.0, minute: t.1))
        case "weekly":
            let weekdays = ["SUN": 1, "MON": 2, "TUE": 3, "WED": 4, "THU": 5, "FRI": 6, "SAT": 7]
            let normalized = value.map { String($0.uppercased().prefix(3)) }
            guard let key = normalized, let day = weekdays[key], let t = parseTime(timeOfDay) else {
                return .failure(
                    .init(
                        "frequency `weekly` requires frequency_value = a weekday (MON..SUN or a "
                            + "full name like Monday) and frequency_time_of_day = `HH:mm`."
                    )
                )
            }
            return .success(.weekly(dayOfWeek: day, hour: t.0, minute: t.1))
        case "monthly":
            guard let v = value, let d = Int(v), (1 ... 28).contains(d), let t = parseTime(timeOfDay)
            else {
                return .failure(
                    .init(
                        "frequency `monthly` requires frequency_value in 1..28 (day of month) and "
                            + "frequency_time_of_day = `HH:mm`."
                    )
                )
            }
            return .success(.monthly(dayOfMonth: d, hour: t.0, minute: t.1))
        case "yearly":
            guard let v = value, let dash = v.firstIndex(of: "-"),
                let m = Int(v[..<dash]), let d = Int(v[v.index(after: dash)...]),
                (1 ... 12).contains(m), (1 ... 31).contains(d),
                let t = parseTime(timeOfDay)
            else {
                return .failure(
                    .init(
                        "frequency `yearly` requires frequency_value = `MM-DD` and "
                            + "frequency_time_of_day = `HH:mm`."
                    )
                )
            }
            return .success(.yearly(month: m, day: d, hour: t.0, minute: t.1))
        case "cron":
            guard let v = value, !v.isEmpty else {
                return .failure(.init("frequency `cron` requires frequency_value = cron expression."))
            }
            return .success(.cron(expression: v))
        default:
            return .failure(
                .init("frequency must be one of: \(validNames.joined(separator: ", ")).")
            )
        }
    }

    /// Render a `ScheduleFrequency` back into the document triple.
    static func components(
        of frequency: ScheduleFrequency
    ) -> (frequency: String, value: String?, timeOfDay: String?) {
        func time(_ hour: Int, _ minute: Int) -> String {
            String(format: "%02d:%02d", hour, minute)
        }
        switch frequency {
        case .once(let date):
            return ("once", ISO8601DateFormatter().string(from: date), nil)
        case .everyNMinutes(let minutes):
            return ("every_n_minutes", String(minutes), nil)
        case .hourly(let minute):
            return ("hourly", minute == 0 ? nil : String(minute), nil)
        case .daily(let hour, let minute):
            return ("daily", nil, time(hour, minute))
        case .weekly(let dayOfWeek, let hour, let minute):
            let names = [1: "SUN", 2: "MON", 3: "TUE", 4: "WED", 5: "THU", 6: "FRI", 7: "SAT"]
            return ("weekly", names[dayOfWeek] ?? "MON", time(hour, minute))
        case .monthly(let dayOfMonth, let hour, let minute):
            return ("monthly", String(dayOfMonth), time(hour, minute))
        case .yearly(let month, let day, let hour, let minute):
            return ("yearly", String(format: "%02d-%02d", month, day), time(hour, minute))
        case .cron(let expression):
            return ("cron", expression, nil)
        }
    }
}

public struct ConfigFrequencyError: Error, Equatable, Sendable {
    public let message: String
    init(_ message: String) { self.message = message }
}
