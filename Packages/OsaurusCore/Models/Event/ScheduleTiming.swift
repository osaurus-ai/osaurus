//
//  ScheduleTiming.swift
//  osaurus
//
//  When a calendar-driven trigger is due. Shared by schedule events and the
//  legacy `Schedule` record so the anchor, missed-slot and early-fire rules
//  have exactly one implementation.
//

import Foundation

public struct ScheduleTiming: Sendable, Equatable {
    public var frequency: ScheduleFrequency
    public var isEnabled: Bool
    /// When the trigger was last selected for execution.
    public var lastTriggeredAt: Date?
    /// When the last run completed.
    public var lastRunAt: Date?

    public init(frequency: ScheduleFrequency, isEnabled: Bool, lastTriggeredAt: Date?, lastRunAt: Date?) {
        self.frequency = frequency
        self.isEnabled = isEnabled
        self.lastTriggeredAt = lastTriggeredAt
        self.lastRunAt = lastRunAt
    }

    /// Most recent execution anchor. Trigger time wins over completion time so
    /// failed or in-flight runs do not replay the same missed slot.
    public var executionAnchor: Date? {
        lastTriggeredAt ?? lastRunAt
    }

    /// Execution anchor snapped to the consumed slot when the raw stamp
    /// landed inside the interval-aware early-fire window (e.g. 04:59:59
    /// for a 05:00 daily). One-shot anchors are never snapped.
    public var consumedExecutionAnchor: Date? {
        guard let raw = executionAnchor else { return nil }
        if case .once = frequency { return raw }
        return frequency.alignedAnchor(from: raw)
    }

    /// The next run date from the consumed execution anchor.
    public func nextRunDateAfterExecutionAnchor(asOf now: Date = Date()) -> Date? {
        guard isEnabled else { return nil }
        if case .once = frequency, executionAnchor != nil { return nil }
        return frequency.nextRunDate(after: consumedExecutionAnchor ?? now)
    }

    /// Most recent slot that is already `<= now`. `nil` when nothing is
    /// overdue — including when the next slot is in the 60s `shouldRunNow`
    /// window but still in the future.
    ///
    /// With no execution anchor (never run), walk from
    /// `now - initialLookbackSeconds` so a late first fire stamps today's
    /// slot instead of `nextRunDate(after: now)` (tomorrow). The missed
    /// path still requires an anchor and will not use this lookback.
    public func latestDueSlot(
        asOf now: Date = Date(),
        initialLookbackSeconds: TimeInterval = 3600
    ) -> Date? {
        guard isEnabled else { return nil }
        if case .once(let date) = frequency {
            return date <= now && executionAnchor == nil ? date : nil
        }
        let raw = executionAnchor ?? now.addingTimeInterval(-initialLookbackSeconds)
        return frequency.latestDueSlot(after: raw, asOf: now).slot
    }

    /// Recurring catch-up: a prior trigger exists and a later slot is
    /// already past. One-shots and never-run triggers are not missed
    /// replays — the timer / one-shot path owns those.
    public func hasMissedRecurringRun(asOf now: Date = Date()) -> Bool {
        guard isEnabled else { return false }
        if case .once = frequency { return false }
        guard executionAnchor != nil else { return false }
        return latestDueSlot(asOf: now) != nil
    }

    /// Slot to stamp when the timer selects this trigger. Prefer the most
    /// recent overdue slot so a stale anchor does not cascade one skipped
    /// fire at a time; otherwise the upcoming slot (`shouldRunNow` may be
    /// true up to 60s early).
    public func scheduledFireTime(asOf now: Date = Date()) -> Date? {
        latestDueSlot(asOf: now) ?? nextRunDateAfterExecutionAnchor(asOf: now)
    }

    /// Whether the trigger should run now (or was missed).
    public func shouldRunNow(
        asOf now: Date = Date(),
        toleranceSeconds: TimeInterval = 60,
        initialLookbackSeconds: TimeInterval = 3600
    ) -> Bool {
        guard isEnabled else { return false }

        let latestAllowedFireDate = now.addingTimeInterval(toleranceSeconds)

        // A one-shot never replays once it has been selected for dispatch.
        if case .once(let date) = frequency {
            guard executionAnchor == nil else { return false }
            return date <= latestAllowedFireDate
        }

        let checkFrom = consumedExecutionAnchor ?? now.addingTimeInterval(-initialLookbackSeconds)
        guard let nextRun = frequency.nextRunDate(after: checkFrom) else { return false }
        return nextRun <= latestAllowedFireDate
    }

    /// "Today at 9:00 AM", "Tomorrow at …", "Monday at …", or a full date.
    public static func describe(_ date: Date, relativeTo now: Date = Date()) -> String {
        let calendar = Calendar.current
        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short

        if calendar.isDate(date, inSameDayAs: now) {
            return "Today at \(timeFormatter.string(from: date))"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
            calendar.isDate(date, inSameDayAs: tomorrow)
        {
            return "Tomorrow at \(timeFormatter.string(from: date))"
        }
        let daysDiff = calendar.dateComponents([.day], from: now, to: date).day ?? 0
        if daysDiff < 7 {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE 'at' h:mm a"
            return formatter.string(from: date)
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
