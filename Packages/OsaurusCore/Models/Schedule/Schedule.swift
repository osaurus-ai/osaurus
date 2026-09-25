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
    /// Run every N minutes, aligned to the top of the hour (minimum 5)
    case everyNMinutes(minutes: Int)
    /// Run every hour at a specific minute offset (0-59)
    case hourly(minute: Int)
    /// Run daily at a specific time
    case daily(hour: Int, minute: Int)
    /// Run weekly on a specific day at a specific time (1 = Sunday, 7 = Saturday)
    case weekly(dayOfWeek: Int, hour: Int, minute: Int)
    /// Run monthly on a specific day at a specific time
    case monthly(dayOfMonth: Int, hour: Int, minute: Int)
    /// Run yearly on a specific month and day at a specific time
    case yearly(month: Int, day: Int, hour: Int, minute: Int)
    /// Run based on a cron expression (e.g., "15 0,7 * * 1-5")
    case cron(expression: String)

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

        case .everyNMinutes(let minutes):
            return "Every \(minutes) minutes"

        case .hourly(let minute):
            return "Hourly at :\(String(format: "%02d", minute))"

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

        case .cron(let expression):
            return "Cron: \(expression)"
        }
    }

    /// Short description for compact display
    public var shortDescription: String {
        switch self {
        case .once:
            return "Once"
        case .everyNMinutes(let minutes):
            return "Every \(minutes)m"
        case .hourly:
            return "Hourly"
        case .daily:
            return "Daily"
        case .weekly:
            return "Weekly"
        case .monthly:
            return "Monthly"
        case .yearly:
            return "Yearly"
        case .cron:
            return "Cron"
        }
    }

    /// The frequency type for UI selection
    public var frequencyType: ScheduleFrequencyType {
        switch self {
        case .once: return .once
        case .everyNMinutes: return .everyNMinutes
        case .hourly: return .hourly
        case .daily: return .daily
        case .weekly: return .weekly
        case .monthly: return .monthly
        case .yearly: return .yearly
        case .cron: return .cron
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

        case .everyNMinutes(let minutes):
            let clamped = max(minutes, 5)
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: referenceDate)
            let currentMinute = components.minute ?? 0
            let nextSlot = ((currentMinute / clamped) + 1) * clamped
            if nextSlot >= 60 {
                components.minute = nextSlot % 60
                components.second = 0
                guard let base = calendar.date(from: components) else { return nil }
                return calendar.date(byAdding: .hour, value: 1, to: base)
            } else {
                components.minute = nextSlot
                components.second = 0
                return calendar.date(from: components)
            }

        case .hourly(let minute):
            var components = calendar.dateComponents([.year, .month, .day, .hour], from: referenceDate)
            components.minute = minute
            components.second = 0

            guard let candidate = calendar.date(from: components) else { return nil }

            if candidate <= referenceDate {
                return calendar.date(byAdding: .hour, value: 1, to: candidate)
            }
            return candidate

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

        case .cron(let expression):
            return CronParser(expression)?.nextDate(after: referenceDate)
        }
    }

    // MARK: - Slot Alignment

    /// Snap window for treating an early wall-clock stamp as a consumed slot.
    /// `min(60, interval / 2)` so a 1-minute cadence cannot consume the next
    /// minute on a slightly late fire. Compare with strict `<`, not `<=`.
    public static func slotSnapTolerance(interval: TimeInterval) -> TimeInterval {
        min(60, max(interval, 0) / 2)
    }

    /// Whether `next` should be treated as already consumed by `raw`.
    public static func shouldConsumeNextSlot(
        raw: Date,
        next: Date,
        interval: TimeInterval
    ) -> Bool {
        next.timeIntervalSince(raw) < slotSnapTolerance(interval: interval)
    }

    /// Nominal snap interval. For `everyNMinutes` this is the stored N
    /// (not the 5-minute `nextRunDate` clamp) so a 1-minute cadence stays
    /// at a 30s window even if slot generation still clamps to 5.
    ///
    /// Cron uses the gap *after* `reference` from two successive
    /// `nextRunDate` results. That is not "the real period" for irregular
    /// expressions (`0 9,17 * * *` varies by time of day). Harmless here:
    /// any gap ≥ 2 minutes still caps at 60. The 60s fallback is only
    /// unsafe for a sub-2-minute cron whose next two dates fail to
    /// compute, which should not happen.
    public func slotSnapIntervalSeconds(around reference: Date) -> TimeInterval {
        switch self {
        case .once:
            return 120
        case .everyNMinutes(let minutes):
            return TimeInterval(max(minutes, 1) * 60)
        case .hourly:
            return 3600
        case .daily:
            return 86_400
        case .weekly:
            return 7 * 86_400
        case .monthly:
            return 30 * 86_400
        case .yearly:
            return 365 * 86_400
        case .cron:
            guard let next = nextRunDate(after: reference),
                let following = nextRunDate(after: next)
            else {
                return 120
            }
            let gap = following.timeIntervalSince(next)
            return gap > 0 ? gap : 120
        }
    }

    public func slotSnapToleranceSeconds(around reference: Date) -> TimeInterval {
        Self.slotSnapTolerance(interval: slotSnapIntervalSeconds(around: reference))
    }

    /// If `raw` is within the snap window before the next slot, treat that
    /// slot as already consumed and return the slot instant.
    public func alignedAnchor(from raw: Date) -> Date {
        if case .once = self { return raw }
        guard let next = nextRunDate(after: raw) else { return raw }
        if Self.shouldConsumeNextSlot(
            raw: raw,
            next: next,
            interval: slotSnapIntervalSeconds(around: raw)
        ) {
            return next
        }
        return raw
    }

    /// Result of walking to the most recent slot that is `<= now`.
    public struct LatestDueSlotWalk: Sendable, Equatable {
        public var slot: Date?
        public var steps: Int

        public init(slot: Date?, steps: Int) {
            self.slot = slot
            self.steps = steps
        }
    }

    /// Most recent slot `<= now` after `rawAnchor`. Returns `nil` when the
    /// first candidate is already `> now` (empty case: the timer owns that
    /// slot, not the missed-replay path), even if it is inside
    /// `shouldRunNow`'s 60s forward window.
    ///
    /// Walk start: `everyNMinutes` / `hourly` / `daily` begin at
    /// `max(anchor, now - 2 * interval)` so a months-old 5-minute schedule
    /// does not step tens of thousands of times at launch. Two intervals
    /// (not one) so a DST shift or the strict `>` boundary cannot skip
    /// the slot we want. Weekly / monthly / yearly walk from the aligned
    /// anchor — their gaps can exceed the nominal period (monthly on the
    /// 31st: Jan 31 → Mar 31 is 59 days). Cron uses the observed next gap
    /// only as a walk bound, not as "the real period."
    ///
    /// If that fast start returns `nil` but `nextRunDate(after: aligned)`
    /// is already `<= now`, the start skipped a real miss (irregular cron
    /// or DST). Walk again from the aligned anchor. Hitting the iteration
    /// cap returns `nil` so the timer path can catch up from a live slot
    /// rather than stamping a mid-walk leftover.
    public func latestDueSlot(
        after rawAnchor: Date,
        asOf now: Date,
        maxIterations: Int = 512
    ) -> LatestDueSlotWalk {
        let aligned = alignedAnchor(from: rawAnchor)
        let cap = max(1, maxIterations)
        let fast = walkDueSlots(
            from: walkStart(alignedAnchor: aligned, asOf: now),
            asOf: now,
            maxIterations: cap
        )
        if fast.slot != nil {
            return fast
        }
        if let first = nextRunDate(after: aligned), first <= now {
            return walkDueSlots(from: aligned, asOf: now, maxIterations: cap)
        }
        return LatestDueSlotWalk(slot: nil, steps: fast.steps)
    }

    private func walkDueSlots(
        from start: Date,
        asOf now: Date,
        maxIterations: Int
    ) -> LatestDueSlotWalk {
        var cursor = start
        var lastDue: Date?
        var steps = 0
        while steps < maxIterations {
            guard let next = nextRunDate(after: cursor) else {
                return LatestDueSlotWalk(slot: lastDue, steps: steps)
            }
            if next > now {
                return LatestDueSlotWalk(slot: lastDue, steps: steps)
            }
            lastDue = next
            cursor = next
            steps += 1
        }
        return LatestDueSlotWalk(slot: nil, steps: steps)
    }

    /// Actual slot spacing used to bound the latest-due walk.
    /// `everyNMinutes` matches `nextRunDate`'s 5-minute clamp so
    /// `now - 2 * interval` cannot land after the real latest slot.
    private func walkIntervalSeconds(around reference: Date) -> TimeInterval? {
        switch self {
        case .everyNMinutes(let minutes):
            return TimeInterval(max(minutes, 5) * 60)
        case .hourly:
            return 3600
        case .daily:
            return 86_400
        case .cron:
            guard let next = nextRunDate(after: reference),
                let following = nextRunDate(after: next)
            else {
                return nil
            }
            let gap = following.timeIntervalSince(next)
            return gap > 0 ? gap : nil
        case .once, .weekly, .monthly, .yearly:
            return nil
        }
    }

    private func walkStart(alignedAnchor: Date, asOf now: Date) -> Date {
        guard let interval = walkIntervalSeconds(around: alignedAnchor) else {
            return alignedAnchor
        }
        return max(alignedAnchor, now.addingTimeInterval(-2 * interval))
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
    case everyNMinutes = "Minutes"
    case hourly = "Hourly"
    case daily = "Daily"
    case weekly = "Weekly"
    case monthly = "Monthly"
    case yearly = "Yearly"
    case cron = "Cron Expression"

    public var displayName: String {
        switch self {
        case .once: return L("Once")
        case .everyNMinutes: return L("Minutes")
        case .hourly: return L("Hourly")
        case .daily: return L("Daily")
        case .weekly: return L("Weekly")
        case .monthly: return L("Monthly")
        case .yearly: return L("Yearly")
        case .cron: return L("Cron Expression")
        }
    }

    public var icon: String {
        switch self {
        case .once: return "1.circle"
        case .everyNMinutes: return "timer"
        case .hourly: return "clock.arrow.2.circlepath"
        case .daily: return "sun.max"
        case .weekly: return "calendar.badge.clock"
        case .monthly: return "calendar"
        case .yearly: return "calendar.badge.exclamationmark"
        case .cron: return "terminal"
        }
    }
}

// MARK: - Schedule Model

/// A scheduled task that runs an AI chat at specified intervals.
public struct Schedule: Codable, Identifiable, Sendable, Equatable {
    /// Unique identifier for the schedule
    public let id: UUID
    /// Display name of the schedule
    public var name: String
    /// Instructions to send to the AI when the schedule runs
    public var instructions: String
    /// Who runs the schedule: an agent hosted here or a teammate's shared
    /// workspace agent. nil = no agent (refused at execution time).
    public var target: AgentDispatchTarget?
    /// The local agent, for readers that only understand local agents.
    /// nil for workspace targets; setting it replaces `target` with `.local`.
    public var agentId: UUID? {
        get { target?.localId }
        set { target = newValue.map(AgentDispatchTarget.local) }
    }
    /// The shared workspace agent this schedule runs, or nil for local.
    public var workspaceTarget: WorkspaceAgentRef? { target?.workspaceRef }
    /// Extra parameters for future extensibility
    public var parameters: [String: String]
    /// Working directory path (for display)
    public var folderPath: String?
    /// Security-scoped bookmark for the working directory
    public var folderBookmark: Data?
    /// When and how often to run
    public var frequency: ScheduleFrequency
    /// Whether the schedule is active
    public var isEnabled: Bool
    /// When the schedule last ran
    public var lastRunAt: Date?
    /// When the schedule was last selected for execution
    public var lastTriggeredAt: Date?
    /// The chat session ID from the last run (for viewing results)
    public var lastChatSessionId: UUID?
    /// Bounded local execution history inferred from schedule persistence transitions
    public var runHistory: [ScheduleRunHistoryEntry]
    /// When the schedule was created
    public let createdAt: Date
    /// When the schedule was last modified
    public var updatedAt: Date

    /// `agentId` and `target` are two spellings of the same field; `target`
    /// wins when both are given.
    public init(
        id: UUID = UUID(),
        name: String,
        instructions: String,
        agentId: UUID? = nil,
        target: AgentDispatchTarget? = nil,
        parameters: [String: String] = [:],
        folderPath: String? = nil,
        folderBookmark: Data? = nil,
        frequency: ScheduleFrequency,
        isEnabled: Bool = true,
        lastRunAt: Date? = nil,
        lastTriggeredAt: Date? = nil,
        lastChatSessionId: UUID? = nil,
        runHistory: [ScheduleRunHistoryEntry] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.target = target ?? agentId.map(AgentDispatchTarget.local)
        self.parameters = parameters
        self.folderPath = folderPath
        self.folderBookmark = folderBookmark
        self.frequency = frequency
        self.isEnabled = isEnabled
        self.lastRunAt = lastRunAt
        self.lastTriggeredAt = lastTriggeredAt
        self.lastChatSessionId = lastChatSessionId
        self.runHistory = runHistory
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Backward-Compatible Decoding

    private enum CodingKeys: String, CodingKey {
        case id, name, instructions, agentId, parameters
        case target
        case personaId  // legacy key for migration
        case mode  // legacy key (chat / work) — ignored on decode
        case folderPath, folderBookmark
        case frequency, isEnabled, lastRunAt, lastTriggeredAt, lastChatSessionId
        case runHistory
        case createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        instructions = try container.decode(String.self, forKey: .instructions)
        // `target` (new) → `agentId` → `personaId` (oldest); every stored
        // schedule written before workspace targets decodes as `.local`.
        target = try container.decodeAgentTarget(
            targetKey: .target,
            legacyAgentIdKey: .agentId,
            legacyPersonaIdKey: .personaId
        )
        // Legacy `mode` field (chat / work) is silently dropped — every
        // scheduled run is now a chat dispatch.
        _ = try container.decodeIfPresent(String.self, forKey: .mode)
        parameters = try container.decodeIfPresent([String: String].self, forKey: .parameters) ?? [:]
        folderPath = try container.decodeIfPresent(String.self, forKey: .folderPath)
        folderBookmark = try container.decodeIfPresent(Data.self, forKey: .folderBookmark)
        frequency = try container.decode(ScheduleFrequency.self, forKey: .frequency)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        lastRunAt = try container.decodeIfPresent(Date.self, forKey: .lastRunAt)
        lastTriggeredAt = try container.decodeIfPresent(Date.self, forKey: .lastTriggeredAt)
        lastChatSessionId = try container.decodeIfPresent(UUID.self, forKey: .lastChatSessionId)
        runHistory = try container.decodeIfPresent([ScheduleRunHistoryEntry].self, forKey: .runHistory) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(instructions, forKey: .instructions)
        // Writes `target` AND (for local) the legacy `agentId` so older
        // builds keep reading the UUID they expect.
        try container.encodeAgentTarget(target, targetKey: .target, legacyAgentIdKey: .agentId)
        try container.encode(parameters, forKey: .parameters)
        try container.encodeIfPresent(folderPath, forKey: .folderPath)
        try container.encodeIfPresent(folderBookmark, forKey: .folderBookmark)
        try container.encode(frequency, forKey: .frequency)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(lastRunAt, forKey: .lastRunAt)
        try container.encodeIfPresent(lastTriggeredAt, forKey: .lastTriggeredAt)
        try container.encodeIfPresent(lastChatSessionId, forKey: .lastChatSessionId)
        if !runHistory.isEmpty {
            try container.encode(runHistory, forKey: .runHistory)
        }
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    // MARK: - Computed Properties

    /// Calculate the next run date for this schedule
    public var nextRunDate: Date? {
        guard isEnabled else { return nil }
        return frequency.nextRunDate()
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

    /// Calculate the next run date from the consumed execution anchor.
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
    /// already past. One-shots and never-run schedules are not missed
    /// replays — the timer / one-shot path owns those.
    public func hasMissedRecurringRun(asOf now: Date = Date()) -> Bool {
        guard isEnabled else { return false }
        if case .once = frequency { return false }
        guard executionAnchor != nil else { return false }
        return latestDueSlot(asOf: now) != nil
    }

    /// Slot to stamp when the timer selects this schedule. Prefer the most
    /// recent overdue slot so a stale anchor does not cascade one skipped
    /// fire at a time; otherwise the upcoming slot (`shouldRunNow` may be
    /// true up to 60s early).
    public func scheduledFireTime(asOf now: Date = Date()) -> Date? {
        latestDueSlot(asOf: now) ?? nextRunDateAfterExecutionAnchor(asOf: now)
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
    public func shouldRunNow(
        asOf now: Date = Date(),
        toleranceSeconds: TimeInterval = 60,
        initialLookbackSeconds: TimeInterval = 3600
    ) -> Bool {
        guard isEnabled else { return false }

        let latestAllowedFireDate = now.addingTimeInterval(toleranceSeconds)

        // A one-shot should never replay once it has been selected for dispatch.
        if case .once(let date) = frequency {
            guard executionAnchor == nil else { return false }
            return date <= latestAllowedFireDate
        }

        let checkFrom = consumedExecutionAnchor ?? now.addingTimeInterval(-initialLookbackSeconds)
        guard let nextRun = frequency.nextRunDate(after: checkFrom) else { return false }
        return nextRun <= latestAllowedFireDate
    }
}

// MARK: - Schedule Run Info

/// Information about a currently running schedule task
public struct ScheduleRunInfo: Identifiable, Sendable {
    public let id: UUID
    public let scheduleId: UUID
    public let scheduleName: String
    public let agentId: UUID?
    public var chatSessionId: UUID
    public let startedAt: Date

    public init(
        id: UUID = UUID(),
        scheduleId: UUID,
        scheduleName: String,
        agentId: UUID?,
        chatSessionId: UUID,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.scheduleId = scheduleId
        self.scheduleName = scheduleName
        self.agentId = agentId
        self.chatSessionId = chatSessionId
        self.startedAt = startedAt
    }
}
