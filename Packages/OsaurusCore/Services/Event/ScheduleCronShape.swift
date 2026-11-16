//
//  ScheduleCronShape.swift
//  osaurus
//
//  The cron expressions the Workflows screens write for schedules that
//  `ScheduleFrequency` has no case for, read back as plain words. Only the
//  exact shapes written here are recognized; any other expression is a
//  custom schedule.
//

import Foundation

enum ScheduleCronShape: Equatable, Sendable {
    /// Monday to Friday at `hour:minute`: `M H * * 1-5`.
    case weekdays(hour: Int, minute: Int)

    var expression: String {
        switch self {
        case .weekdays(let hour, let minute): return "\(minute) \(hour) * * 1-5"
        }
    }

    var frequency: ScheduleFrequency { .cron(expression: expression) }

    static func recognize(_ frequency: ScheduleFrequency) -> ScheduleCronShape? {
        guard case .cron(let expression) = frequency else { return nil }
        return recognize(expression)
    }

    static func recognize(_ expression: String) -> ScheduleCronShape? {
        let fields = expression.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count == 5, fields[2] == "*", fields[3] == "*", fields[4] == "1-5",
            let minute = plainNumber(fields[0]), (0...59).contains(minute),
            let hour = plainNumber(fields[1]), (0...23).contains(hour)
        else { return nil }
        return .weekdays(hour: hour, minute: minute)
    }

    private static func plainNumber(_ field: String) -> Int? {
        guard !field.isEmpty, field.count <= 2, field.allSatisfy(\.isASCIIDigit) else { return nil }
        return Int(field)
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
