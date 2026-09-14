//
//  ScheduleExecutionAnchorTests.swift
//  osaurusTests
//
//  Verifies scheduled runs anchor on trigger time, not only completion time.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ScheduleExecutionAnchorTests {
    @Test func codableRoundTripPreservesLastTriggeredAt() throws {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let sessionId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let lastRunAt = localDate(year: 2026, month: 5, day: 16, hour: 9, minute: 0)
        let lastTriggeredAt = localDate(year: 2026, month: 5, day: 17, hour: 9, minute: 0)
        let createdAt = localDate(year: 2026, month: 5, day: 1, hour: 8, minute: 0)
        let updatedAt = localDate(year: 2026, month: 5, day: 17, hour: 9, minute: 1)

        let schedule = Schedule(
            id: id,
            name: "Daily check",
            instructions: "Summarize the workspace",
            parameters: ["pluginId": "plugin.example"],
            frequency: .daily(hour: 9, minute: 0),
            lastRunAt: lastRunAt,
            lastTriggeredAt: lastTriggeredAt,
            lastChatSessionId: sessionId,
            createdAt: createdAt,
            updatedAt: updatedAt
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(schedule)
        let json = String(decoding: data, as: UTF8.self)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Schedule.self, from: data)

        #expect(json.contains("lastTriggeredAt"))
        #expect(decoded.lastRunAt == lastRunAt)
        #expect(decoded.lastTriggeredAt == lastTriggeredAt)
        #expect(decoded.executionAnchor == lastTriggeredAt)
        #expect(decoded.lastChatSessionId == sessionId)
    }

    @Test func recurringDueCheckUsesLastTriggeredAtBeforeLastRunAt() {
        let lastRunAt = localDate(year: 2026, month: 5, day: 16, hour: 9, minute: 0)
        let lastTriggeredAt = localDate(year: 2026, month: 5, day: 17, hour: 9, minute: 0)
        let now = localDate(year: 2026, month: 5, day: 17, hour: 9, minute: 30)

        let anchored = Schedule(
            name: "Daily check",
            instructions: "Run the daily check",
            frequency: .daily(hour: 9, minute: 0),
            lastRunAt: lastRunAt,
            lastTriggeredAt: lastTriggeredAt
        )
        let completionOnly = Schedule(
            name: "Daily check",
            instructions: "Run the daily check",
            frequency: .daily(hour: 9, minute: 0),
            lastRunAt: lastRunAt
        )

        #expect(!anchored.shouldRunNow(asOf: now, toleranceSeconds: 0))
        #expect(completionOnly.shouldRunNow(asOf: now, toleranceSeconds: 0))
        let tomorrowAtNine = localDate(year: 2026, month: 5, day: 18, hour: 9, minute: 0)
        #expect(anchored.nextRunDateAfterExecutionAnchor(asOf: now) == tomorrowAtNine)
    }

    @Test func oneShotDoesNotReplayAfterBeingTriggered() {
        let fireDate = localDate(year: 2026, month: 5, day: 17, hour: 9, minute: 0)
        let now = localDate(year: 2026, month: 5, day: 17, hour: 10, minute: 0)
        let triggeredAt = localDate(year: 2026, month: 5, day: 17, hour: 9, minute: 1)

        let pending = Schedule(
            name: "One shot",
            instructions: "Run once",
            frequency: .once(date: fireDate)
        )
        let alreadyTriggered = Schedule(
            name: "One shot",
            instructions: "Run once",
            frequency: .once(date: fireDate),
            lastTriggeredAt: triggeredAt
        )
        let selectedForDispatch = Schedule(
            name: "One shot",
            instructions: "Run once",
            frequency: .once(date: fireDate),
            lastTriggeredAt: fireDate.addingTimeInterval(-10)
        )

        #expect(pending.shouldRunNow(asOf: now, toleranceSeconds: 0))
        #expect(!alreadyTriggered.shouldRunNow(asOf: now, toleranceSeconds: 0))
        #expect(alreadyTriggered.nextRunDateAfterExecutionAnchor(asOf: now) == nil)
        #expect(!selectedForDispatch.shouldRunNow(asOf: now, toleranceSeconds: 0))
        #expect(selectedForDispatch.nextRunDateAfterExecutionAnchor(asOf: now) == nil)
    }

    @Test func nextRunDateAfterSlotMinusOneSecondIsStillTodaysSlot() {
        let slot = localDate(year: 2026, month: 9, day: 13, hour: 5, minute: 0)
        let early = slot.addingTimeInterval(-1)
        let frequency = ScheduleFrequency.daily(hour: 5, minute: 0)
        #expect(frequency.nextRunDate(after: early) == slot)
    }

    @Test func earlyWallClockStampDoesNotReplayDailySlot() {
        let slot = localDate(year: 2026, month: 9, day: 13, hour: 5, minute: 0)
        let lastRunAt = localDate(year: 2026, month: 9, day: 13, hour: 5, minute: 3)
        let now = localDate(year: 2026, month: 9, day: 13, hour: 19, minute: 42)
        let tomorrow = localDate(year: 2026, month: 9, day: 14, hour: 5, minute: 0)

        let schedule = Schedule(
            name: "Daily check",
            instructions: "Run the daily check",
            frequency: .daily(hour: 5, minute: 0),
            lastRunAt: lastRunAt,
            lastTriggeredAt: slot.addingTimeInterval(-1)
        )

        #expect(schedule.consumedExecutionAnchor == slot)
        #expect(!schedule.shouldRunNow(asOf: now, toleranceSeconds: 60))
        #expect(schedule.nextRunDateAfterExecutionAnchor(asOf: now) == tomorrow)
        #expect(!schedule.hasMissedRecurringRun(asOf: now))
        #expect(schedule.latestDueSlot(asOf: now) == nil)
    }

    @Test func missedPredicateIsFalseOneSecondBeforeTodaysSlot() {
        let yesterday = localDate(year: 2026, month: 9, day: 12, hour: 5, minute: 0)
        let today = localDate(year: 2026, month: 9, day: 13, hour: 5, minute: 0)
        let now = today.addingTimeInterval(-1)

        let schedule = Schedule(
            name: "Daily check",
            instructions: "Run the daily check",
            frequency: .daily(hour: 5, minute: 0),
            lastTriggeredAt: yesterday
        )

        #expect(schedule.latestDueSlot(asOf: now) == nil)
        #expect(!schedule.hasMissedRecurringRun(asOf: now))
        #expect(schedule.shouldRunNow(asOf: now, toleranceSeconds: 60))
        #expect(schedule.nextRunDateAfterExecutionAnchor(asOf: now) == today)
    }

    @Test func missedPredicateIsTrueAfterTodaysSlotWhenAnchorIsYesterday() {
        let yesterday = localDate(year: 2026, month: 9, day: 12, hour: 5, minute: 0)
        let today = localDate(year: 2026, month: 9, day: 13, hour: 5, minute: 0)
        let now = localDate(year: 2026, month: 9, day: 13, hour: 19, minute: 42)

        let schedule = Schedule(
            name: "Daily check",
            instructions: "Run the daily check",
            frequency: .daily(hour: 5, minute: 0),
            lastTriggeredAt: yesterday
        )

        #expect(schedule.latestDueSlot(asOf: now) == today)
        #expect(schedule.hasMissedRecurringRun(asOf: now))
    }

    @Test func latestDueSlotCatchesUpToMostRecentDayNotFirstMissedDay() {
        let threeDaysAgo = localDate(year: 2026, month: 9, day: 10, hour: 5, minute: 0)
        let today = localDate(year: 2026, month: 9, day: 13, hour: 5, minute: 0)
        let now = localDate(year: 2026, month: 9, day: 13, hour: 19, minute: 42)
        let tomorrow = localDate(year: 2026, month: 9, day: 14, hour: 5, minute: 0)

        let schedule = Schedule(
            name: "Daily check",
            instructions: "Run the daily check",
            frequency: .daily(hour: 5, minute: 0),
            lastTriggeredAt: threeDaysAgo
        )

        #expect(schedule.latestDueSlot(asOf: now) == today)
        #expect(schedule.hasMissedRecurringRun(asOf: now))

        var consumed = schedule
        consumed.lastTriggeredAt = today
        #expect(!consumed.hasMissedRecurringRun(asOf: now))
        #expect(consumed.nextRunDateAfterExecutionAnchor(asOf: now) == tomorrow)
    }

    @Test func staleEveryFiveMinutesWalkDoesNotStepFromMonthsOldAnchor() throws {
        let now = localDate(year: 2026, month: 9, day: 13, hour: 19, minute: 42)
        let stale = localDate(year: 2026, month: 3, day: 1, hour: 8, minute: 0)
        let frequency = ScheduleFrequency.everyNMinutes(minutes: 5)

        let walk = frequency.latestDueSlot(after: stale, asOf: now)
        #expect(walk.steps <= 8)
        let slot = try #require(walk.slot)
        #expect(slot <= now)
        #expect(frequency.nextRunDate(after: slot)! > now)

        var schedule = Schedule(
            name: "Five minute check",
            instructions: "Check",
            frequency: frequency,
            lastTriggeredAt: stale
        )
        #expect(schedule.latestDueSlot(asOf: now) == slot)

        schedule.lastTriggeredAt = slot
        #expect(!schedule.hasMissedRecurringRun(asOf: now))
        #expect(schedule.nextRunDateAfterExecutionAnchor(asOf: now) == frequency.nextRunDate(after: slot))
    }

    @Test func oneMinuteSnapToleranceDoesNotConsumeTheFollowingMinute() {
        let slot = localDate(year: 2026, month: 9, day: 13, hour: 10, minute: 0)
        let interval: TimeInterval = 60
        let next = slot.addingTimeInterval(interval)

        #expect(ScheduleFrequency.slotSnapTolerance(interval: interval) == 30)
        #expect(
            ScheduleFrequency.shouldConsumeNextSlot(
                raw: slot.addingTimeInterval(-1),
                next: slot,
                interval: interval
            )
        )
        #expect(
            !ScheduleFrequency.shouldConsumeNextSlot(
                raw: slot,
                next: next,
                interval: interval
            )
        )
        #expect(
            !ScheduleFrequency.shouldConsumeNextSlot(
                raw: slot.addingTimeInterval(1),
                next: next,
                interval: interval
            )
        )

        let frequency = ScheduleFrequency.everyNMinutes(minutes: 1)
        #expect(frequency.slotSnapToleranceSeconds(around: slot) == 30)
        #expect(frequency.alignedAnchor(from: slot.addingTimeInterval(-1)) == slot)
        #expect(frequency.alignedAnchor(from: slot) == slot)
        #expect(frequency.alignedAnchor(from: slot.addingTimeInterval(1)) == slot.addingTimeInterval(1))
    }

    @Test func timerStampUsesEachSchedulesOwnSlotNotTheSharedWake() {
        let now = localDate(year: 2026, month: 9, day: 13, hour: 5, minute: 0)
        let yesterdayOdd = localDate(year: 2026, month: 9, day: 13, hour: 4, minute: 59)

        let daily = Schedule(
            name: "Daily at 5",
            instructions: "Daily",
            frequency: .daily(hour: 5, minute: 0),
            lastTriggeredAt: localDate(year: 2026, month: 9, day: 12, hour: 5, minute: 0)
        )
        let oddMinuteCron = Schedule(
            name: "Odd minutes",
            instructions: "Cron",
            frequency: .cron(expression: "1-59/2 * * * *"),
            lastTriggeredAt: yesterdayOdd
        )

        #expect(daily.shouldRunNow(asOf: now, toleranceSeconds: 60))
        #expect(oddMinuteCron.shouldRunNow(asOf: now, toleranceSeconds: 60))
        #expect(daily.scheduledFireTime(asOf: now) == now)
        #expect(oddMinuteCron.scheduledFireTime(asOf: now) == now.addingTimeInterval(60))
        #expect(oddMinuteCron.scheduledFireTime(asOf: now) != now)
    }

    @Test func staleAnchorTimerStampJumpsToLatestDueSlot() {
        let threeDaysAgo = localDate(year: 2026, month: 9, day: 10, hour: 5, minute: 0)
        let today = localDate(year: 2026, month: 9, day: 13, hour: 5, minute: 0)
        let now = localDate(year: 2026, month: 9, day: 13, hour: 19, minute: 42)
        let tomorrow = localDate(year: 2026, month: 9, day: 14, hour: 5, minute: 0)

        let schedule = Schedule(
            name: "Daily check",
            instructions: "Run",
            frequency: .daily(hour: 5, minute: 0),
            lastTriggeredAt: threeDaysAgo
        )

        #expect(schedule.scheduledFireTime(asOf: now) == today)
        #expect(schedule.nextRunDateAfterExecutionAnchor(asOf: now) == localDate(year: 2026, month: 9, day: 11, hour: 5, minute: 0))

        var consumed = schedule
        consumed.lastTriggeredAt = today
        #expect(consumed.scheduledFireTime(asOf: now) == tomorrow)
    }

    @Test func cronFastWalkDoesNotSkipAMissedLaterSlot() {
        let yesterdayNine = localDate(year: 2026, month: 9, day: 12, hour: 9, minute: 0)
        let yesterdayTen = localDate(year: 2026, month: 9, day: 12, hour: 10, minute: 0)
        let now = localDate(year: 2026, month: 9, day: 13, hour: 8, minute: 30)
        let todayNine = localDate(year: 2026, month: 9, day: 13, hour: 9, minute: 0)

        let schedule = Schedule(
            name: "Nine and ten",
            instructions: "Cron",
            frequency: .cron(expression: "0 9,10 * * *"),
            lastTriggeredAt: yesterdayNine
        )

        #expect(schedule.latestDueSlot(asOf: now) == yesterdayTen)
        #expect(schedule.hasMissedRecurringRun(asOf: now))
        #expect(schedule.scheduledFireTime(asOf: now) == yesterdayTen)

        var consumed = schedule
        consumed.lastTriggeredAt = yesterdayTen
        #expect(!consumed.hasMissedRecurringRun(asOf: now))
        #expect(consumed.nextRunDateAfterExecutionAnchor(asOf: now) == todayNine)
    }

    @Test func latestDueSlotCapReturnsNilInsteadOfAStaleMidWalkStamp() {
        let stale = localDate(year: 2026, month: 3, day: 1, hour: 8, minute: 0)
        let now = localDate(year: 2026, month: 9, day: 13, hour: 19, minute: 42)
        let frequency = ScheduleFrequency.weekly(dayOfWeek: 1, hour: 8, minute: 0)

        let capped = frequency.latestDueSlot(after: stale, asOf: now, maxIterations: 1)
        #expect(capped.slot == nil)
        #expect(capped.steps == 1)

        let full = frequency.latestDueSlot(after: stale, asOf: now)
        #expect(full.slot != nil)
        #expect(full.slot! <= now)
    }

    @Test func succeededHistoryClampsEndedAtToStartedAt() {
        let slot = localDate(year: 2026, month: 9, day: 13, hour: 5, minute: 0)
        var schedule = Schedule(
            name: "Daily check",
            instructions: "Run the daily check",
            frequency: .daily(hour: 5, minute: 0),
            lastTriggeredAt: slot
        )
        schedule.recordRunStarted(at: slot)
        schedule.recordRunSucceeded(endedAt: slot.addingTimeInterval(-0.5), chatSessionId: nil)

        #expect(schedule.runHistory.count == 1)
        #expect(schedule.runHistory[0].startedAt == slot)
        #expect(schedule.runHistory[0].endedAt == slot)
        #expect(schedule.runHistory[0].endedAt! >= schedule.runHistory[0].startedAt)
    }

    private func localDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.calendar = Calendar.current
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        return components.date!
    }
}
