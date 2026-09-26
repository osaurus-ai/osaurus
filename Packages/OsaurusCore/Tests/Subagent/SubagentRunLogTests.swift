//
//  SubagentRunLogTests.swift
//  osaurus / Subagent Tests
//
//  A finished Computer Use / AppleScript run keeps its step log. Before,
//  the live feed was the only copy: the registry dropped it five seconds
//  after the run and the row fell back to a one-line summary, so the log
//  vanished on success and on failure. The log is saved with the turn
//  (beside the tool result, never sent to the model) and restored on load.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Subagent run log persistence")
struct SubagentRunLogTests {

    private static func finishedFeed(
        kindId: String = SubagentCapabilityRegistry.computerUse.id,
        success: Bool = false,
        eventCount: Int = 3
    ) -> SubagentFeed {
        let feed = SubagentFeed(
            toolCallId: "call-\(UUID().uuidString)",
            kindId: kindId,
            title: "Organize Downloads"
        )
        for step in 1 ... eventCount {
            feed.emit(SubagentActivityEvent(step: step, kind: .act, title: "Step \(step)", success: true))
        }
        feed.finish(success: success, summary: "Failed: privacy review timed out")
        return feed
    }

    @Test func finishedRunLog_capturesOutcomeAndEvents() throws {
        let feed = Self.finishedFeed()
        let log = try #require(feed.finishedRunLog())
        #expect(log.kindId == SubagentCapabilityRegistry.computerUse.id)
        #expect(log.success == false)
        #expect(log.summary == "Failed: privacy review timed out")
        #expect(log.events.map(\.title) == ["Step 1", "Step 2", "Step 3"])
        #expect(log.truncatedEventCount == 0)
    }

    @Test func finishedRunLog_nilWhileRunningOrForOtherKinds() {
        let running = SubagentFeed(
            toolCallId: "c", kindId: SubagentCapabilityRegistry.appleScript.id, title: "t")
        #expect(running.finishedRunLog() == nil)
        let spawn = Self.finishedFeed(kindId: SubagentCapabilityRegistry.spawn.id)
        #expect(spawn.finishedRunLog() == nil)
    }

    @Test func finishedRunLog_keepsTailAndTrimsLongDetail() throws {
        let feed = SubagentFeed(toolCallId: "c", kindId: SubagentCapabilityRegistry.computerUse.id, title: "t")
        let total = SubagentRunLog.maxPersistedEvents + 25
        for step in 1 ... total {
            feed.emit(SubagentActivityEvent(step: step, kind: .perceive, title: "\(step)"))
        }
        feed.emit(
            SubagentActivityEvent(
                kind: .reasoning, title: "long",
                detail: String(repeating: "x", count: SubagentRunLog.maxPersistedDetailCharacters + 500)))
        feed.finish(success: true, summary: "done")

        let log = try #require(feed.finishedRunLog())
        #expect(log.events.count == SubagentRunLog.maxPersistedEvents)
        #expect(log.truncatedEventCount == total + 1 - SubagentRunLog.maxPersistedEvents)
        #expect(log.events.last?.detail?.count == SubagentRunLog.maxPersistedDetailCharacters)
    }

    @Test func restoredFeed_isFinishedWithSameEvents() throws {
        let original = Self.finishedFeed()
        let log = try #require(original.finishedRunLog())
        let restored = SubagentFeed.restored(toolCallId: original.toolCallId, log: log)
        #expect(restored.currentEvents() == log.events)
        #expect(restored.currentStatus() == .finished(success: false, summary: log.summary))
        #expect(restored.startedAt == log.startedAt)
    }

    @Test func turnData_codableRoundTripKeepsLogs() throws {
        let log = try #require(Self.finishedFeed().finishedRunLog())
        let turn = ChatTurnData(role: .assistant, content: "", toolCallLogs: ["call_1": log])
        let decoded = try JSONDecoder().decode(ChatTurnData.self, from: JSONEncoder().encode(turn))
        #expect(decoded.toolCallLogs == ["call_1": log])
    }

    @Test func database_persistsToolCallLogs() throws {
        let db = ChatHistoryDatabase()
        try db.openInMemory()
        defer { db.close() }
        #expect(ChatHistoryDatabase.latestSchemaVersion == 19)

        let log = try #require(Self.finishedFeed().finishedRunLog())
        let session = ChatSessionData(
            id: UUID(),
            title: "Computer use",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            selectedModel: "m",
            turns: [
                ChatTurnData(role: .user, content: "organize my downloads"),
                ChatTurnData(role: .assistant, content: "", toolCallLogs: ["call_cu": log]),
            ],
            agentId: nil,
            source: .chat,
            sourcePluginId: nil,
            externalSessionKey: nil,
            dispatchTaskId: nil
        )
        try db.saveSession(session)
        let loaded = try #require(db.loadSession(id: session.id))
        #expect(loaded.turns.last?.toolCallLogs == ["call_cu": log])
        #expect(loaded.turns.first?.toolCallLogs.isEmpty == true)
    }

    @MainActor
    @Test func loadingTurn_restoresLogIntoArchive() throws {
        let log = try #require(Self.finishedFeed().finishedRunLog())
        let callId = "call-archive-\(UUID().uuidString)"
        _ = ChatTurn(from: ChatTurnData(role: .assistant, content: "", toolCallLogs: [callId: log]))
        let feed = try #require(SubagentRunLogArchive.shared.feed(for: callId))
        #expect(feed.currentEvents() == log.events)
    }
}
