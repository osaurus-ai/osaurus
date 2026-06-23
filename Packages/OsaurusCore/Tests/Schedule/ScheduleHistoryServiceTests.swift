//
//  ScheduleHistoryServiceTests.swift
//  osaurusTests
//
//  Verifies schedule history summaries and exports.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ScheduleHistoryServiceTests {
    @MainActor
    @Test func summaryOffMainLoadsProviderAwayFromMainThread() async {
        let schedule = Schedule(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Daily summary",
            instructions: "Summarize",
            agentId: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            frequency: .daily(hour: 9, minute: 0)
        )
        let provider = ThreadCheckingAgentRunProvider()
        let service = ScheduleHistoryService(agentRunProvider: provider)

        let summary = await service.summaryOffMain(for: schedule, runLimit: 8)

        #expect(summary.scheduleId == schedule.id)
        #expect(provider.didRunOnMainThread == false)
    }

    @MainActor
    @Test func summariesOffMainLoadsProviderAwayFromMainThread() async {
        let schedule = Schedule(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            name: "Weekly report",
            instructions: "Report",
            agentId: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            frequency: .weekly(dayOfWeek: 2, hour: 9, minute: 0)
        )
        let provider = ThreadCheckingAgentRunProvider()
        let service = ScheduleHistoryService(agentRunProvider: provider)

        let summaries = await service.summariesOffMain(for: [schedule], runLimit: 8)

        #expect(summaries[schedule.id]?.scheduleId == schedule.id)
        #expect(provider.didRunOnMainThread == false)
    }

    @Test func summaryMergesAgentRunErrorsWithLocalHistory() {
        let scheduleId = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let agentId = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let sessionId = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let endedAt = startedAt.addingTimeInterval(12)

        let localRun = ScheduleRunHistoryEntry(
            scheduleId: scheduleId,
            agentId: agentId,
            status: .running,
            startedAt: startedAt,
            chatSessionId: sessionId,
            instructionsPreview: "Summarize"
        )
        let schedule = Schedule(
            id: scheduleId,
            name: "Daily summary",
            instructions: "Summarize",
            agentId: agentId,
            frequency: .daily(hour: 9, minute: 0),
            runHistory: [localRun]
        )

        let run = AgentRunRecord(
            id: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
            agentId: agentId,
            triggerKind: .recurringSchedule,
            triggerPayload: #"{"source":"schedule","external_session_key":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}"#,
            instructions: "Summarize",
            startedAt: startedAt.addingTimeInterval(0.5),
            endedAt: endedAt,
            status: .error,
            tokensIn: 10,
            tokensOut: 0,
            costUSD: nil,
            error: "Model unavailable"
        )
        let unrelated = AgentRunRecord(
            id: UUID(),
            agentId: agentId,
            triggerKind: .recurringSchedule,
            triggerPayload: #"{"source":"schedule","external_session_key":"eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"}"#,
            instructions: "Other",
            startedAt: startedAt,
            status: .success
        )

        let service = ScheduleHistoryService(agentRunProvider: FakeAgentRunProvider(records: [run, unrelated]))
        let summary = service.summary(for: schedule, runLimit: 10, asOf: endedAt)

        #expect(summary.runs.count == 1)
        #expect(summary.runs[0].status == .failed)
        #expect(summary.runs[0].chatSessionId == sessionId)
        #expect(summary.runs[0].tokensIn == 10)
        #expect(summary.lastError?.message == "Model unavailable")
        #expect(summary.lastError?.runId == run.id)
    }

    @Test func markdownExportIncludesNextRunAndRecentRuns() {
        let scheduleId = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let runId = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let schedule = Schedule(
            id: scheduleId,
            name: "Weekly | Report",
            instructions: "Write report",
            frequency: .weekly(dayOfWeek: 2, hour: 9, minute: 0)
        )
        let summary = ScheduleAutomationSummary(
            scheduleId: scheduleId,
            generatedAt: generatedAt,
            nextRun: ScheduleNextRunPreview(
                state: .scheduled,
                nextRunAt: generatedAt.addingTimeInterval(3600),
                generatedAt: generatedAt,
                description: "Today at 10:00 AM"
            ),
            runs: [
                ScheduleRunHistoryEntry(
                    id: runId,
                    scheduleId: scheduleId,
                    agentId: nil,
                    status: .failed,
                    startedAt: generatedAt,
                    endedAt: generatedAt.addingTimeInterval(2),
                    errorMessage: "Tool | failed"
                )
            ],
            lastError: ScheduleLastErrorDiagnostic(
                runId: runId,
                occurredAt: generatedAt.addingTimeInterval(2),
                message: "Tool | failed",
                status: .failed
            )
        )

        let service = ScheduleHistoryService(agentRunProvider: FakeAgentRunProvider(records: []))
        let markdown = service.markdownSummary(for: schedule, summary: summary)

        #expect(markdown.contains("# Schedule Run Summary: Weekly | Report"))
        #expect(markdown.contains("- Next run: Today at 10:00 AM"))
        #expect(markdown.contains("## Last Error"))
        #expect(markdown.contains("Tool \\| failed"))
        #expect(markdown.contains("| Started | Status | Duration | Session | Error |"))
    }

    private struct FakeAgentRunProvider: ScheduleAgentRunProviding {
        let records: [AgentRunRecord]

        func runs(agentId: UUID, limit: Int) throws -> [AgentRunRecord] {
            Array(records.filter { $0.agentId == agentId }.prefix(limit))
        }
    }

    private final class ThreadCheckingAgentRunProvider: ScheduleAgentRunProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var observedMainThread: Bool?

        var didRunOnMainThread: Bool? {
            lock.lock()
            defer { lock.unlock() }
            return observedMainThread
        }

        func runs(agentId: UUID, limit: Int) throws -> [AgentRunRecord] {
            lock.lock()
            observedMainThread = Thread.isMainThread
            lock.unlock()
            return []
        }
    }
}
