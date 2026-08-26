//
//  SubagentBackgroundDispatchTests.swift
//  osaurusTests
//
//  Pins the `background: true` spawn contract: the tool call returns an
//  acknowledgment immediately while the prepared run continues detached;
//  the pre-registered feed drives the notch mirror; a local-model helper
//  defers its start behind the injectable gate; Stop reaches the detached
//  run through the interrupt center; and the terminal digest is delivered
//  to the launching session as a follow-up turn once that session is idle
//  (never mid-stream, never into a pending clarify).
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Scripted kind

/// A scripted `SubagentKind` so the detached host control flow runs without
/// a model. Mirrors the `SubagentSessionTests` double.
private final class ScriptedKind: SubagentKind, @unchecked Sendable {
    let capability: SubagentCapability

    var resolve: @Sendable (SubagentScope) async throws -> ResolvedModel
    var body:
        @Sendable (SubagentScope, ResolvedModel, SubagentFeed, InterruptToken) async throws ->
            SubagentResult

    init(
        id: String = "bg-scripted",
        isLocal: Bool = false,
        body:
            @escaping @Sendable (SubagentScope, ResolvedModel, SubagentFeed, InterruptToken)
                async throws -> SubagentResult = { _, _, feed, _ in
                    feed.emitPhase("running")
                    return SubagentResult(payload: ["summary": "done"], summary: "done")
                }
    ) {
        self.capability = SubagentCapability(id: id, toolNames: [id], gate: .sandboxExec)
        self.resolve = { _ in
            ResolvedModel(name: "scripted-model", id: "scripted-model", isLocal: isLocal)
        }
        self.body = body
    }

    func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel {
        try await resolve(scope)
    }

    func permission(_ scope: SubagentScope, _ resolved: ResolvedModel) async -> SubagentDecision {
        .allow
    }

    func run(
        _ scope: SubagentScope,
        _ resolved: ResolvedModel,
        feed: SubagentFeed,
        interrupt: InterruptToken
    ) async throws -> SubagentResult {
        try await body(scope, resolved, feed, interrupt)
    }
}

// MARK: - Helpers

/// Thread-safe latch the scripted bodies and gates block on.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

private func decode(_ envelope: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(envelope.utf8))) as? [String: Any] ?? [:]
}

private func waitUntil(
    timeout: Duration = .seconds(5),
    _ predicate: @MainActor @escaping () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw NSError(domain: "SubagentBackgroundDispatchTests", code: 1)
}

@MainActor
private func makeSession() -> (session: ChatSession, context: ExecutionContext) {
    let context = ExecutionContext(id: UUID(), agentId: Agent.defaultId)
    context.chatSession.chatEngineFactory = { _ in MockChatEngine() }
    return (context.chatSession, context)
}

// MARK: - Tests

@Suite(.serialized)
@MainActor
struct SubagentBackgroundDispatchTests {

    @Test("background dispatch acks immediately while the feed keeps running")
    func ackReturnsWhileRunContinues() async throws {
        let toolCallId = "bg-dispatch-\(UUID().uuidString)"
        let release = Flag()
        let kind = ScriptedKind(body: { _, _, feed, _ in
            feed.emitPhase("running")
            while !release.isSet {
                try await Task.sleep(for: .milliseconds(10))
            }
            return SubagentResult(payload: ["summary": "digest-done"], summary: "digest-done")
        })

        let envelope = await ChatExecutionContext.$currentToolCallId.withValue(toolCallId) {
            await SubagentSession.dispatchInBackground(kind, tool: "bg_test")
        }

        // The ack is a success envelope with the report-back contract; the
        // run has NOT finished (the body is still gated).
        #expect(ToolEnvelope.isSuccess(envelope))
        let payload = ToolEnvelope.successPayload(envelope) as? [String: Any]
        #expect(payload?["dispatched"] as? Bool == true)
        #expect(payload?["background"] as? Bool == true)
        #expect((payload?["note"] as? String)?.contains("follow-up message") == true)

        let feed = try #require(SubagentFeedRegistry.shared.feed(for: toolCallId))
        #expect(feed.currentStatus() == .running)

        release.set()
        try await waitUntil {
            feed.currentStatus() == .finished(success: true, summary: "digest-done")
        }
        SubagentFeedRegistry.shared.removeNow(toolCallId: toolCallId)
    }

    @Test("a preparation failure returns the failure envelope synchronously")
    func prepareFailureStaysSynchronous() async throws {
        let toolCallId = "bg-dispatch-\(UUID().uuidString)"
        let kind = ScriptedKind()
        kind.resolve = { _ in throw SubagentError.unavailable("no model") }

        let envelope = await ChatExecutionContext.$currentToolCallId.withValue(toolCallId) {
            await SubagentSession.dispatchInBackground(kind, tool: "bg_test")
        }

        #expect(ToolEnvelope.isError(envelope))
        // The pre-registered feed finished as a failure so the notch row
        // can't spin forever behind a dead dispatch.
        if let feed = SubagentFeedRegistry.shared.feed(for: toolCallId) {
            #expect(feed.currentStatus() != .running)
        }
        SubagentFeedRegistry.shared.removeNow(toolCallId: toolCallId)
    }

    @Test("the digest lands in the launching session as a follow-up turn")
    func reportBackDeliversToIdleSession() async throws {
        try await ChatHistoryTestStorage.run {
            let (session, context) = makeSession()
            _ = context
            let box = WeakChatSessionBox(session)
            let toolCallId = "bg-dispatch-\(UUID().uuidString)"
            let kind = ScriptedKind(body: { _, _, _, _ in
                SubagentResult(payload: ["summary": "digest-report-123"], summary: "digest-report-123")
            })

            let envelope = await ChatExecutionContext.$currentToolCallId.withValue(toolCallId) {
                await ChatExecutionContext.$currentChatSessionBox.withValue(box) {
                    await SubagentSession.dispatchInBackground(kind, tool: "bg_test")
                }
            }
            #expect(ToolEnvelope.isSuccess(envelope))

            try await waitUntil {
                session.turns.contains {
                    $0.role == .user
                        && $0.content.contains("[Helper report]")
                        && $0.content.contains("finished")
                        && $0.content.contains("digest-report-123")
                }
            }
            SubagentFeedRegistry.shared.removeNow(toolCallId: toolCallId)
        }
    }

    @Test("delivery waits out a streaming session and a pending clarify")
    func reportBackDefersWhileSessionIsBusy() async throws {
        try await ChatHistoryTestStorage.run {
            let (session, context) = makeSession()
            _ = context
            let box = WeakChatSessionBox(session)

            session.isStreaming = true
            let delivery = Task {
                await SubagentReportBack.deliver(
                    title: "spawn → Helper",
                    success: true,
                    summary: "deferred-digest",
                    to: box
                )
            }
            try await Task.sleep(for: .milliseconds(400))
            #expect(!session.turns.contains { $0.content.contains("deferred-digest") })

            // Stream ends but a clarify pause takes over — still deferred.
            session.awaitingClarify = ClarifyPayload(
                question: "Which one?", options: [], allowMultiple: false
            )
            session.isStreaming = false
            try await Task.sleep(for: .milliseconds(400))
            #expect(!session.turns.contains { $0.content.contains("deferred-digest") })

            // Fully idle: the report goes through as the next user turn.
            session.awaitingClarify = nil
            try await waitUntil {
                session.turns.contains {
                    $0.role == .user && $0.content.contains("deferred-digest")
                }
            }
            await delivery.value
        }
    }

    @Test("a deallocated launching session drops the report cleanly")
    func reportBackDropsWhenSessionIsGone() async throws {
        var context: ExecutionContext? = ExecutionContext(id: UUID(), agentId: Agent.defaultId)
        let box = WeakChatSessionBox(context!.chatSession)
        context = nil
        #expect(box.session == nil)

        // Returns instead of spinning; nothing to assert beyond completion.
        await SubagentReportBack.deliver(
            title: "spawn → Helper", success: false, summary: "gone", to: box
        )
    }

    @Test("a local-model helper starts only after the gate opens")
    func localHelperWaitsForStartGate() async throws {
        let toolCallId = "bg-dispatch-\(UUID().uuidString)"
        let gateOpen = Flag()
        let bodyEntered = Flag()
        let kind = ScriptedKind(isLocal: true, body: { _, _, _, _ in
            bodyEntered.set()
            return SubagentResult(payload: ["summary": "local-done"], summary: "local-done")
        })

        let envelope = await ChatExecutionContext.$currentToolCallId.withValue(toolCallId) {
            await SubagentSession.dispatchInBackground(
                kind,
                tool: "bg_test",
                localStartGate: {
                    while !gateOpen.isSet {
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                }
            )
        }
        #expect(ToolEnvelope.isSuccess(envelope))

        try await Task.sleep(for: .milliseconds(300))
        #expect(!bodyEntered.isSet)

        gateOpen.set()
        try await waitUntil { bodyEntered.isSet }
        try await waitUntil {
            SubagentFeedRegistry.shared.feed(for: toolCallId)?.currentStatus()
                == .finished(success: true, summary: "local-done")
        }
        SubagentFeedRegistry.shared.removeNow(toolCallId: toolCallId)
    }

    @Test("notch Stop aborts a detached helper through its mirror row")
    func notchCancelAbortsDetachedRun() async throws {
        let manager = BackgroundTaskManager.makeForTesting()
        let bridge = SubagentBackgroundTaskBridge(
            manager: manager,
            registry: SubagentFeedRegistry.shared
        )
        bridge.start()

        let toolCallId = "bg-dispatch-\(UUID().uuidString)"
        // kind id "spawn" so the bridge adopts the feed into a mirror row.
        let kind = ScriptedKind(id: SubagentCapabilityRegistry.spawn.id, body: {
            _, _, feed, interrupt in
            feed.emitPhase("running")
            while !interrupt.isInterrupted {
                try await Task.sleep(for: .milliseconds(10))
            }
            throw CancellationError()
        })

        let envelope = await ChatExecutionContext.$currentToolCallId.withValue(toolCallId) {
            await SubagentSession.dispatchInBackground(kind, tool: "bg_test")
        }
        #expect(ToolEnvelope.isSuccess(envelope))

        try await waitUntil {
            manager.backgroundTasks.values.contains {
                $0.subagentToolCallId == toolCallId && $0.status == .running
            }
        }
        let mirror = try #require(
            manager.backgroundTasks.values.first { $0.subagentToolCallId == toolCallId }
        )

        manager.cancelTask(mirror.id)
        #expect(mirror.status == .cancelled)

        // The interrupt reached the detached body: the run ends as a
        // user-stop failure on the feed.
        try await waitUntil {
            if case .finished(let success, _)? =
                SubagentFeedRegistry.shared.feed(for: toolCallId)?.currentStatus()
            {
                return !success
            }
            return false
        }

        manager.finalizeTask(mirror.id)
        SubagentFeedRegistry.shared.removeNow(toolCallId: toolCallId)
    }
}
