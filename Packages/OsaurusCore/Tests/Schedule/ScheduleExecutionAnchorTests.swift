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
