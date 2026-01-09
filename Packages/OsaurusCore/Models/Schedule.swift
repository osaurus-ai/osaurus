//
//  Schedule.swift
//  osaurus
//
//  Defines a scheduled task that runs AI chat interactions at specified intervals.
//

import Foundation

// MARK: - Schedule Frequency

/// Defines when a scheduled task should run
public enum ScheduleFrequency: Codable, Sendable, Equatable, Hashable {
    /// Run once at a specific date and time
    case once(date: Date)
    /// Run daily at a specific time
    case daily(hour: Int, minute: Int)
    /// Run weekly on a specific day at a specific time (1 = Sunday, 7 = Saturday)
    case weekly(dayOfWeek: Int, hour: Int, minute: Int)
    /// Run monthly on a specific day at a specific time
    case monthly(dayOfMonth: Int, hour: Int, minute: Int)
    /// Run yearly on a specific month and day at a specific time
    case yearly(month: Int, day: Int, hour: Int, minute: Int)

    // MARK: - Display Helpers

    /// Human-readable description of the frequency
    public var displayDescription: String {
        let calendar = Calendar.current

        switch self {
        case .once(let date):
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return "Once on \(formatter.string(from: date))"

        case .daily(let hour, let minute):
            return "Daily at \(timeString(hour: hour, minute: minute))"

        case .weekly(let dayOfWeek, let hour, let minute):
            let dayName = calendar.weekdaySymbols[dayOfWeek - 1]
            return "Every \(dayName) at \(timeString(hour: hour, minute: minute))"

        case .monthly(let dayOfMonth, let hour, let minute):
            let suffix = daySuffix(dayOfMonth)
            return "Monthly on the \(dayOfMonth)\(suffix) at \(timeString(hour: hour, minute: minute))"

        case .yearly(let month, let day, let hour, let minute):
            let monthName = calendar.monthSymbols[month - 1]
            let suffix = daySuffix(day)
            return "Yearly on \(monthName) \(day)\(suffix) at \(timeString(hour: hour, minute: minute))"
        }
    }

    /// Short description for compact display
    public var shortDescription: String {
        switch self {
        case .once:
            return "Once"
        case .daily:
            return "Daily"
        case .weekly:
            return "Weekly"
        case .monthly:
            return "Monthly"
        case .yearly:
            return "Yearly"
        }
    }

    /// The frequency type for UI selection
    public var frequencyType: ScheduleFrequencyType {
        switch self {
        case .once: return .once
        case .daily: return .daily
        case .weekly: return .weekly
        case .monthly: return .monthly
        case .yearly: return .yearly
        }
    }

    // MARK: - Next Run Calculation

    /// Calculate the next run date from a given reference date
    /// Returns nil if the schedule should not run again (e.g., past once schedule)
    public func nextRunDate(after referenceDate: Date = Date()) -> Date? {
        let calendar = Calendar.current

        switch self {
        case .once(let date):
            // Only return if the date is in the future
            return date > referenceDate ? date : nil

        case .daily(let hour, let minute):
            var components = calendar.dateComponents([.year, .month, .day], from: referenceDate)
            components.hour = hour
            components.minute = minute
            components.second = 0

            guard let candidate = calendar.date(from: components) else { return nil }

            // If today's time has passed, schedule for tomorrow
            if candidate <= referenceDate {
                return calendar.date(byAdding: .day, value: 1, to: candidate)
            }
            return candidate

        case .weekly(let dayOfWeek, let hour, let minute):
            var components = calendar.dateComponents([.year, .month, .day, .weekday], from: referenceDate)
            components.hour = hour
            components.minute = minute
            components.second = 0

            // Calculate days until target weekday
            let currentWeekday = components.weekday ?? 1
            var daysUntil = dayOfWeek - currentWeekday
            if daysUntil < 0 {
                daysUntil += 7
            }

            guard let candidate = calendar.date(byAdding: .day, value: daysUntil, to: referenceDate) else { return nil }

            var candidateComponents = calendar.dateComponents([.year, .month, .day], from: candidate)
            candidateComponents.hour = hour
            candidateComponents.minute = minute
            candidateComponents.second = 0

            guard let finalCandidate = calendar.date(from: candidateComponents) else { return nil }

            // If this week's time has passed, schedule for next week
            if finalCandidate <= referenceDate {
                return calendar.date(byAdding: .weekOfYear, value: 1, to: finalCandidate)
            }
            return finalCandidate

        case .monthly(let dayOfMonth, let hour, let minute):
            var components = calendar.dateComponents([.year, .month], from: referenceDate)
            components.day = min(dayOfMonth, daysInMonth(year: components.year!, month: components.month!))
            components.hour = hour
            components.minute = minute
            components.second = 0

            guard let candidate = calendar.date(from: components) else { return nil }

            // If this month's time has passed, schedule for next month
            if candidate <= referenceDate {
                guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: candidate) else { return nil }
                let nextComponents = calendar.dateComponents([.year, .month], from: nextMonth)
                var finalComponents = nextComponents
                finalComponents.day = min(
                    dayOfMonth,
                    daysInMonth(year: nextComponents.year!, month: nextComponents.month!)
                )
                finalComponents.hour = hour
                finalComponents.minute = minute
                finalComponents.second = 0
                return calendar.date(from: finalComponents)
            }
            return candidate

        case .yearly(let month, let day, let hour, let minute):
            var components = calendar.dateComponents([.year], from: referenceDate)
            components.month = month
            components.day = min(day, daysInMonth(year: components.year!, month: month))
            components.hour = hour
            components.minute = minute
            components.second = 0

            guard let candidate = calendar.date(from: components) else { return nil }

            // If this year's time has passed, schedule for next year
            if candidate <= referenceDate {
                components.year! += 1
                components.day = min(day, daysInMonth(year: components.year!, month: month))
                return calendar.date(from: components)
            }
            return candidate
        }
    }

    // MARK: - Private Helpers

    private func timeString(hour: Int, minute: Int) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none

        var components = DateComponents()
        components.hour = hour
        components.minute = minute

        let calendar = Calendar.current
        if let date = calendar.date(from: components) {
            return formatter.string(from: date)
        }

        // Fallback
        return String(format: "%d:%02d", hour, minute)
    }

    private func daySuffix(_ day: Int) -> String {
        switch day {
        case 1, 21, 31: return "st"
        case 2, 22: return "nd"
        case 3, 23: return "rd"
        default: return "th"
        }
    }

    private func daysInMonth(year: Int, month: Int) -> Int {
        let calendar = Calendar.current
        var components = DateComponents()
        components.year = year
        components.month = month
        guard let date = calendar.date(from: components),
            let range = calendar.range(of: .day, in: .month, for: date)
        else {
            return 28  // Safe fallback
        }
        return range.count
    }
}

// MARK: - Frequency Type (for UI)

/// Simple enum for frequency type selection in UI
public enum ScheduleFrequencyType: String, CaseIterable, Sendable {
    case once = "Once"
    case daily = "Daily"
    case weekly = "Weekly"
    case monthly = "Monthly"
    case yearly = "Yearly"

    public var icon: String {
        switch self {
        case .once: return "1.circle"
        case .daily: return "sun.max"
        case .weekly: return "calendar.badge.clock"
        case .monthly: return "calendar"
        case .yearly: return "calendar.badge.exclamationmark"
        }
    }
}

// MARK: - Schedule Model

/// A scheduled task that runs AI chat interactions at specified intervals
public struct Schedule: Codable, Identifiable, Sendable, Equatable {
    /// Unique identifier for the schedule
    public let id: UUID
    /// Display name of the schedule
    public var name: String
    /// Instructions to send to the AI when the schedule runs
    public var instructions: String
    /// The persona to use for the chat (nil = default persona)
    public var personaId: UUID?
    /// When and how often to run
    public var frequency: ScheduleFrequency
    /// Whether the schedule is active
    public var isEnabled: Bool
    /// When the schedule last ran
    public var lastRunAt: Date?
    /// The chat session ID from the last run (for viewing results)
    public var lastChatSessionId: UUID?
    /// When the schedule was created
    public let createdAt: Date
    /// When the schedule was last modified
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        instructions: String,
        personaId: UUID? = nil,
        frequency: ScheduleFrequency,
        isEnabled: Bool = true,
        lastRunAt: Date? = nil,
        lastChatSessionId: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.personaId = personaId
        self.frequency = frequency
        self.isEnabled = isEnabled
        self.lastRunAt = lastRunAt
        self.lastChatSessionId = lastChatSessionId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Computed Properties

    /// Calculate the next run date for this schedule
    public var nextRunDate: Date? {
        guard isEnabled else { return nil }
        return frequency.nextRunDate()
    }

    /// Human-readable description of when this will next run
    public var nextRunDescription: String? {
        guard let nextRun = nextRunDate else { return nil }

        let now = Date()
        let calendar = Calendar.current

        // Check if it's today
        if calendar.isDateInToday(nextRun) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return "Today at \(formatter.string(from: nextRun))"
        }

        // Check if it's tomorrow
        if calendar.isDateInTomorrow(nextRun) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return "Tomorrow at \(formatter.string(from: nextRun))"
        }

        // Check if it's within a week
        let daysDiff = calendar.dateComponents([.day], from: now, to: nextRun).day ?? 0
        if daysDiff < 7 {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE 'at' h:mm a"
            return formatter.string(from: nextRun)
        }

        // Otherwise show full date
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: nextRun)
    }

    /// Whether this schedule should run now (or was missed)
    public func shouldRunNow(toleranceSeconds: TimeInterval = 60) -> Bool {
        guard isEnabled else { return false }

        // For once schedules, check if we're within tolerance of the target time
        if case .once(let date) = frequency {
            let now = Date()
            return abs(now.timeIntervalSince(date)) <= toleranceSeconds
        }

        // For recurring schedules, check if nextRunDate is in the past or within tolerance
        guard let nextRun = frequency.nextRunDate() else { return false }
        let now = Date()
        return now >= nextRun.addingTimeInterval(-toleranceSeconds)
    }
}

// MARK: - Schedule Run Info

/// Information about a currently running schedule task
public struct ScheduleRunInfo: Identifiable, Sendable {
    public let id: UUID
    public let scheduleId: UUID
    public let scheduleName: String
    public let personaId: UUID?
    public var chatSessionId: UUID
    public let startedAt: Date
    public var toastId: UUID?

    public init(
        id: UUID = UUID(),
        scheduleId: UUID,
        scheduleName: String,
        personaId: UUID?,
        chatSessionId: UUID,
        startedAt: Date = Date(),
        toastId: UUID? = nil
    ) {
        self.id = id
        self.scheduleId = scheduleId
        self.scheduleName = scheduleName
        self.personaId = personaId
        self.chatSessionId = chatSessionId
        self.startedAt = startedAt
        self.toastId = toastId
    }
}
