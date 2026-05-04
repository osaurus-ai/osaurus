//
//  ChatSessionResetForAgentTests.swift
//  osaurusTests
//
//  Pin the contract for `ChatSession.reset(for:)` introduced to fix
//  https://github.com/osaurus-ai/osaurus/issues/1005 — namely that
//  resetting a session to a NEW agent must not silently re-tag the
//  previously-loaded conversation under the new agent.
//
//  The pre-fix bug: `reset(for:)` set `agentId = newAgentId` BEFORE
//  calling `reset()`. Inside `reset()` → `stop()` → `completeRunCleanup()`
//  → `save()`, the still-populated `sessionId` + `turns` got persisted
//  but with the just-overwritten `agentId`, silently re-tagging the
//  conversation on disk.
//
//  We verify the contract by intercepting `onSessionChanged` (which
//  fires from inside `save()` after `toSessionData()` was already
//  encoded and handed to the persistence layer) and reading
//  `session.agentId` at that moment. The fix re-orders `reset(for:)`
//  so the save in `stop()` runs under the OLD agent, then the agent
//  swap happens.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatSessionResetForAgentTests {
    /// Primary regression pin for #1005. Constructs a session in the same
    /// shape `ChatWindowState.loadSession` leaves it in (existing
    /// `sessionId`, populated `turns`, agent X), then calls
    /// `reset(for: differentAgent)` and asserts that any save emitted
    /// during the reset chain still targets the ORIGINAL agent. A
    /// regression here would re-introduce the silent re-tagging
    /// observed when users click "New Chat" after navigating to a
    /// conversation from a different agent.
    @Test("reset(for:) does not retag previous session via stop() side-effect save")
    func resetForAgent_savesPreviousSessionUnderOldAgent() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let originalAgentId = UUID()
            let originalSessionId = UUID()
            let newAgentId = UUID()

            // Mimic a freshly-loaded conversation: existing sessionId + turns
            // under an existing agent, just like `ChatSession.load(from:)`
            // leaves things after `ChatWindowState.loadSession`.
            session.agentId = originalAgentId
            session.sessionId = originalSessionId
            session.turns = [
                ChatTurn(role: .user, content: "Hello"),
                ChatTurn(role: .assistant, content: "Hi"),
            ]
            session.title = "Existing conversation"

            // Capture session state at the moment a save fires.
            // `onSessionChanged` is called inside `save()` AFTER
            // `toSessionData()` has been encoded and passed to
            // `ChatSessionsManager.shared.save`, so the captured snapshot
            // reflects what was actually persisted (or attempted to be).
            var capturedAgentIdAtSave: UUID?
            var capturedSessionIdAtSave: UUID?
            var capturedTurnCountAtSave: Int?
            session.onSessionChanged = {
                capturedAgentIdAtSave = session.agentId
                capturedSessionIdAtSave = session.sessionId
                capturedTurnCountAtSave = session.turns.count
            }

            session.reset(for: newAgentId)

            // If a save fired during the reset chain, it MUST have targeted
            // the original session id under the original agent. Pre-fix this
            // would have captured `newAgentId` because `agentId` was
            // overwritten before `reset()` ran.
            if let capturedAgentId = capturedAgentIdAtSave {
                #expect(
                    capturedSessionIdAtSave == originalSessionId,
                    "save during reset(for:) should target the original session id"
                )
                #expect(
                    capturedAgentId == originalAgentId,
                    "reset(for:) re-tagged session \(originalSessionId) to agent \(capturedAgentId) instead of preserving \(originalAgentId) (#1005)"
                )
                #expect(
                    (capturedTurnCountAtSave ?? 0) > 0,
                    "save during reset(for:) should still see the original turns"
                )
            }

            // Final state: new agent applied, session cleared.
            #expect(session.agentId == newAgentId)
            #expect(session.sessionId == nil)
            #expect(session.turns.isEmpty)
        }
    }

    /// Same shape as the regression test above, but also asserts that
    /// `toSessionData()` snapshots taken during the save chain encode
    /// the OLD agent. Catches a regression where someone "fixes" the
    /// onSessionChanged firing order without fixing the underlying
    /// `toSessionData()` payload.
    @Test("save() during reset(for:) encodes old agentId in ChatSessionData")
    func resetForAgent_toSessionDataInsideSavePreservesOldAgent() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let originalAgentId = UUID()
            let originalSessionId = UUID()
            let newAgentId = UUID()

            session.agentId = originalAgentId
            session.sessionId = originalSessionId
            session.turns = [ChatTurn(role: .user, content: "single turn")]
            session.title = "Loaded chat"

            var snapshot: ChatSessionData?
            session.onSessionChanged = {
                // Re-derive the persisted shape from the same source
                // `save()` used. If the agent had already been swapped at
                // this point, the snapshot would carry `newAgentId`.
                snapshot = session.toSessionData()
            }

            session.reset(for: newAgentId)

            if let snapshot {
                #expect(snapshot.id == originalSessionId)
                #expect(
                    snapshot.agentId == originalAgentId,
                    "ChatSessionData built during reset(for:) carries wrong agent id (#1005)"
                )
            }
        }
    }

    /// `reset(for:)` is supposed to swap the agent AND re-resolve the
    /// model selection for that new agent. The fix re-orders the
    /// internals (`reset()` first under old agent, then swap), so we
    /// pin that the agent swap still actually happens at the end.
    @Test("reset(for:) ends with session.agentId == newAgentId")
    func resetForAgent_endsOnNewAgent() async {
        let session = ChatSession()
        session.agentId = UUID()

        let newAgentId = UUID()
        session.reset(for: newAgentId)

        #expect(session.agentId == newAgentId)
        #expect(session.sessionId == nil)
        #expect(session.turns.isEmpty)
    }
}
