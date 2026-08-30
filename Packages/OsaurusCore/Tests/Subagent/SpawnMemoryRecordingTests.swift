//
//  SpawnMemoryRecordingTests.swift
//  OsaurusCoreTests
//
//  Pins two spawn-run contracts extracted from `TextSubagentKind.run`:
//
//  1. `childSpawnToolAccess` — the launcher's generic read-only file-tool
//     grant applies ONLY to bare-model spawns. Agent targets carry exactly
//     their own enabled surface, so the grant is dropped to `.none`.
//  2. `recordCleanRun` — a clean agent run records exactly one (input,
//     digest) turn under the TARGET agent's id via the injected recorder;
//     bare-model spawns (no memory owner) and memory-disabled targets
//     record nothing. Failed/cancelled exits throw out of the result switch
//     before the recorder is reached (shape-pinned below).
//

import Foundation
import Testing

@testable import OsaurusCore

/// Thread-safe probe standing in for the production delegated-buffer
/// recorder.
private final class RecorderProbe: @unchecked Sendable {
    struct Recorded: Equatable {
        let userMessage: String
        let assistantMessage: String
        let agentId: String
        let conversationId: String
    }

    private let lock = NSLock()
    private var recorded: [Recorded] = []

    func record(
        _ userMessage: String,
        _ assistantMessage: String,
        _ agentId: String,
        _ conversationId: String
    ) {
        lock.lock()
        recorded.append(
            Recorded(
                userMessage: userMessage,
                assistantMessage: assistantMessage,
                agentId: agentId,
                conversationId: conversationId
            )
        )
        lock.unlock()
    }

    func snapshot() -> [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

@Suite
struct SpawnChildToolAccessTests {

    @Test("agent target drops the launcher grant to .none")
    func agentTargetDropsGrant() {
        #expect(
            TextSubagentKind.childSpawnToolAccess(
                resolvedAgentId: UUID(),
                granted: .readOnly
            ) == SpawnToolAccess.none
        )
        #expect(
            TextSubagentKind.childSpawnToolAccess(
                resolvedAgentId: UUID(),
                granted: SpawnToolAccess.none
            ) == SpawnToolAccess.none
        )
    }

    @Test("bare-model target passes the launcher grant through")
    func modelTargetPassesGrantThrough() {
        #expect(
            TextSubagentKind.childSpawnToolAccess(
                resolvedAgentId: nil,
                granted: .readOnly
            ) == .readOnly
        )
        #expect(
            TextSubagentKind.childSpawnToolAccess(
                resolvedAgentId: nil,
                granted: SpawnToolAccess.none
            ) == SpawnToolAccess.none
        )
    }
}

@Suite
struct SpawnMemoryRecordingTests {

    @Test("clean agent run records exactly one turn under the target id")
    func cleanAgentRunRecordsOnce() async {
        let probe = RecorderProbe()
        let targetId = UUID()

        await TextSubagentKind.recordCleanRun(
            targetMemoryEnabled: true,
            resolvedAgentId: targetId,
            input: "summarize the release notes",
            digest: "Three changes: A, B, C.",
            sessionId: "spawn-session-1",
            recorder: { user, assistant, agent, conversation in
                probe.record(user, assistant, agent, conversation)
            }
        )

        let recorded = probe.snapshot()
        #expect(recorded.count == 1)
        #expect(recorded.first?.userMessage == "summarize the release notes")
        #expect(recorded.first?.assistantMessage == "Three changes: A, B, C.")
        #expect(recorded.first?.agentId == targetId.uuidString)
        #expect(recorded.first?.conversationId == "spawn-session-1")
    }

    @Test("bare-model spawn records nothing (no memory owner)")
    func bareModelSpawnRecordsNothing() async {
        let probe = RecorderProbe()

        await TextSubagentKind.recordCleanRun(
            targetMemoryEnabled: false,
            resolvedAgentId: nil,
            input: "x",
            digest: "y",
            sessionId: "spawn-session-2",
            recorder: { user, assistant, agent, conversation in
                probe.record(user, assistant, agent, conversation)
            }
        )

        #expect(probe.snapshot().isEmpty)
    }

    @Test("memory-disabled target records nothing")
    func memoryDisabledTargetRecordsNothing() async {
        let probe = RecorderProbe()

        await TextSubagentKind.recordCleanRun(
            targetMemoryEnabled: false,
            resolvedAgentId: UUID(),
            input: "x",
            digest: "y",
            sessionId: "spawn-session-3",
            recorder: { user, assistant, agent, conversation in
                probe.record(user, assistant, agent, conversation)
            }
        )

        #expect(probe.snapshot().isEmpty)
    }

    /// Shape pin: the recorder call rides INSIDE the clean-exit branch of
    /// the result switch — after `.finalResponse`/`.endedBySurface` mapping,
    /// before the `.cancelled` case throws. Failed/cancelled runs must never
    /// buffer a turn into the target agent's memory.
    @Test("recorder call sits in the clean-exit branch, before the throwing cases")
    func recorderRidesTheCleanBranchOnly() throws {
        let here = URL(fileURLWithPath: #filePath)
        let source =
            here
            .deletingLastPathComponent()  // Subagent/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // OsaurusCore/
            .appendingPathComponent("Subagent/Kinds/TextSubagentKind.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        let cleanCase = try #require(text.range(of: "case .finalResponse, .endedBySurface:"))
        let recorderCall = try #require(text.range(of: "await Self.recordCleanRun("))
        let cancelledCase = try #require(text.range(of: "case .cancelled:"))

        #expect(cleanCase.lowerBound < recorderCall.lowerBound)
        #expect(recorderCall.upperBound < cancelledCase.lowerBound)
        // Production default routes through the delegated buffer entry point
        // (never bufferTurn, which would re-point activeConversation).
        #expect(text.contains("MemoryService.shared.bufferDelegatedTurn("))
    }
}
