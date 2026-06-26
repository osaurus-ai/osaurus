//
//  ScheduleNextRunPreviewTests.swift
//  osaurusTests
//
//  Verifies schedule next-run preview semantics.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ScheduleNextRunPreviewTests {
    @Test func recurringPreviewUsesExecutionAnchor() {
        let now = localDate(year: 2026, month: 6, day: 18, hour: 10, minute: 0)
        let triggeredToday = localDate(year: 2026, month: 6, day: 18, hour: 9, minute: 0)
        let expectedTomorrow = localDate(year: 2026, month: 6, day: 19, hour: 9, minute: 0)

        let schedule = Schedule(
            name: "Daily check",
            instructions: "Run check",
            frequency: .daily(hour: 9, minute: 0),
            lastTriggeredAt: triggeredToday
        )

        let preview = schedule.nextRunPreview(asOf: now)
        #expect(preview.state == .scheduled)
        #expect(preview.nextRunAt == expectedTomorrow)
    }

    @Test func missedRecurringPreviewShowsDueNow() {
        let now = localDate(year: 2026, month: 6, day: 18, hour: 10, minute: 0)
        let triggeredYesterday = localDate(year: 2026, month: 6, day: 17, hour: 9, minute: 0)
        let missedRun = localDate(year: 2026, month: 6, day: 18, hour: 9, minute: 0)

        let schedule = Schedule(
            name: "Daily check",
            instructions: "Run check",
            frequency: .daily(hour: 9, minute: 0),
            lastTriggeredAt: triggeredYesterday
        )

        let preview = schedule.nextRunPreview(asOf: now)
        #expect(preview.state == .due)
        #expect(preview.nextRunAt == missedRun)
        #expect(preview.description == "Due now")
    }

    @Test func pausedAndCompletedOneShotHaveExplicitPreviewStates() {
        let now = localDate(year: 2026, month: 6, day: 18, hour: 10, minute: 0)
        let fireDate = localDate(year: 2026, month: 6, day: 18, hour: 9, minute: 0)

        let paused = Schedule(
            name: "Paused daily",
            instructions: "Run check",
            frequency: .daily(hour: 9, minute: 0),
            isEnabled: false
        )
        let oneShot = Schedule(
            name: "One shot",
            instructions: "Run once",
            frequency: .once(date: fireDate),
            lastTriggeredAt: fireDate
        )

        #expect(paused.nextRunPreview(asOf: now).state == .paused)
        #expect(paused.nextRunPreview(asOf: now).nextRunAt == nil)
        #expect(oneShot.nextRunPreview(asOf: now).state == .exhausted)
        #expect(oneShot.nextRunPreview(asOf: now).nextRunAt == nil)
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
