//
//  ScheduleRunHistoryStoreTests.swift
//  osaurusTests
//
//  Verifies schedule persistence records run-history transitions.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct ScheduleRunHistoryStoreTests {
    @Test func storeRecordsStartAndCompletionTransitions() async throws {
        try await Self.withIsolatedRoot(label: "store-transitions") {
            let scheduleId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
            let agentId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
            let sessionId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
            let start = Self.localDate(year: 2026, month: 6, day: 18, hour: 9, minute: 0)
            let end = start.addingTimeInterval(45)

            let base = Schedule(
                id: scheduleId,
                name: "Daily summary",
                instructions: "Summarize the workspace",
                agentId: agentId,
                frequency: .daily(hour: 9, minute: 0),
                createdAt: Self.localDate(year: 2026, month: 6, day: 1, hour: 8, minute: 0),
                updatedAt: Self.localDate(year: 2026, month: 6, day: 1, hour: 8, minute: 0)
            )
            ScheduleStore.save(base)
            #expect(ScheduleStore.load(id: scheduleId)?.runHistory.isEmpty == true)

            var triggered = base
            triggered.lastTriggeredAt = start
            ScheduleStore.save(triggered)

            let afterStart = try #require(ScheduleStore.load(id: scheduleId))
            #expect(afterStart.runHistory.count == 1)
            #expect(afterStart.runHistory[0].status == .running)
            #expect(afterStart.runHistory[0].startedAt == start)

            var completed = triggered
            completed.lastRunAt = end
            completed.lastChatSessionId = sessionId
            ScheduleStore.save(completed)

            let afterCompletion = try #require(ScheduleStore.load(id: scheduleId))
            #expect(afterCompletion.runHistory.count == 1)
            #expect(afterCompletion.runHistory[0].status == .succeeded)
            #expect(afterCompletion.runHistory[0].startedAt == start)
            #expect(afterCompletion.runHistory[0].endedAt == end)
            #expect(afterCompletion.runHistory[0].chatSessionId == sessionId)
            #expect(afterCompletion.runHistory[0].durationSeconds == 45)

            var edited = afterCompletion
            edited.name = "Daily summary edited"
            ScheduleStore.save(edited)

            let afterEdit = try #require(ScheduleStore.load(id: scheduleId))
            #expect(afterEdit.runHistory.count == 1)
            #expect(afterEdit.name == "Daily summary edited")
        }
    }

    @Test func runHistoryIsBoundedNewestFirst() async throws {
        try await Self.withIsolatedRoot(label: "store-bounds") {
            var schedule = Schedule(
                id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                name: "Frequent check",
                instructions: "Check state",
                frequency: .everyNMinutes(minutes: 5)
            )

            for offset in 0 ..< 60 {
                let start = Date(timeIntervalSince1970: TimeInterval(1_800_000_000 + offset * 60))
                schedule.lastTriggeredAt = start
                schedule.lastRunAt = start.addingTimeInterval(5)
                ScheduleStore.save(schedule)
                schedule = try #require(ScheduleStore.load(id: schedule.id))
            }

            let loaded = try #require(ScheduleStore.load(id: schedule.id))
            #expect(loaded.runHistory.count == Schedule.maxRunHistoryEntries)
            #expect(loaded.runHistory.first?.startedAt == Date(timeIntervalSince1970: 1_800_000_000 + 59 * 60))
            #expect(loaded.runHistory.last?.startedAt == Date(timeIntervalSince1970: 1_800_000_000 + 10 * 60))
        }
    }

    private static func withIsolatedRoot<T: Sendable>(
        label: String,
        _ body: @Sendable () throws -> T
    ) async throws -> T {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-schedule-history-\(label)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                try? FileManager.default.removeItem(at: root)
            }
            return try body()
        }
    }

    private static func localDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
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
