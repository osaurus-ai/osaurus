import Foundation
import Testing

@testable import OsaurusCore

/// Deterministic lifecycle gate for the live regression where an already
/// selected chat retained a stale green warm claim after the runtime evicted
/// its model. This belongs in the eval package as a release preflight, but is
/// intentionally not a CacheProof JSON case: that runner owns request/session
/// cache telemetry and has no window-focus or ChatSession activation surface.
@Suite("Selected-chat idle-eviction warmup lifecycle")
@MainActor
struct SelectedChatWarmupLifecycleTests {
    @Test("eviction while activation debounce is held performs a replacement warmup")
    func reactivationRearmsAfterDebouncedEviction() async {
        let engine = EvalWarmupRecordingEngine()
        let session = EvalWarmupSession()
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "org/test-model",
            messages: [ChatMessage(role: "system", content: "stable shared prefix")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "org/test-model|debounce-eviction"
        )

        let controller = ChatWarmupController()
        controller.projectedLoadFeasibility = { _ in nil }
        controller.hasResidentModelOther = { _ in false }
        controller.scheduleWarmup(session: session, debounce: .zero)
        await controller.scheduledWarmupTaskForTests?.value
        await controller.awaitInFlightWarmup()
        #expect(engine.requestCount == 1)
        #expect(controller.state == .warm)

        let snapshots = EvalResidentSnapshotSequence([
            evalResidencySnapshot(names: ["test-model"], revision: 1),
            evalResidencySnapshot(
                names: [],
                revision: 2,
                reason: .idlePolicy,
                idleDecisionID: 41
            ),
        ])
        let debounce = EvalWarmupDebounceGate()
        controller.chatActivationResidencySnapshot = { _ in
            ModelRuntimeChatActivationResidencySnapshot(
                residency: await snapshots.next(),
                recoverableIdleDecisionID: nil
            )
        }
        controller.runtimeResidencySnapshot = { await snapshots.next() }
        controller.scheduleDebounceSleep = { _ in await debounce.wait() }

        controller.handleSessionBecameActive(session: session, debounce: .seconds(30))
        await controller.awaitSessionActivation()
        await debounce.waitUntilBlocked()
        #expect(await snapshots.callCount() == 1)

        await debounce.release()
        await controller.scheduledWarmupTaskForTests?.value
        await controller.awaitInFlightWarmup()

        #expect(await snapshots.callCount() == 2)
        #expect(engine.requestCount == 2)
        #expect(engine.lastRequest?.backgroundModelLoad == true)
        #expect(controller.state == .warm)
    }

    @Test("matching idle-decision removal after activation performs one replacement warmup")
    func reactivationRearmsAfterPostCoalesceRemoval() async {
        let engine = EvalWarmupRecordingEngine()
        let session = EvalWarmupSession()
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "org/test-model",
            messages: [ChatMessage(role: "system", content: "stable shared prefix")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "org/test-model|selected-chat-reactivation"
        )

        let controller = ChatWarmupController()
        controller.projectedLoadFeasibility = { _ in nil }
        controller.hasResidentModelOther = { _ in false }
        controller.scheduleWarmup(session: session, debounce: .zero)

        for _ in 0 ..< 100 {
            if controller.state == .warm { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        await controller.awaitInFlightWarmup()
        #expect(engine.requestCount == 1)
        #expect(engine.lastRequest?.backgroundModelLoad == true)

        // Match ChatWindowManager.windowDidBecomeKey -> ChatSession activation.
        // Both residency snapshots still contain the selected model, so the
        // activation legitimately coalesces. The runtime publishes removal
        // only afterwards — the final TOCTOU a second snapshot cannot close.
        let snapshots = EvalResidentSnapshotSequence([
            evalResidencySnapshot(names: ["test-model"], revision: 10),
            evalResidencySnapshot(names: ["test-model"], revision: 10),
            evalResidencySnapshot(
                names: [],
                revision: 11,
                reason: .idlePolicy,
                idleDecisionID: 71
            ),
        ])
        let debounce = EvalWarmupDebounceGate()
        controller.chatActivationResidencySnapshot = { _ in
            ModelRuntimeChatActivationResidencySnapshot(
                residency: await snapshots.next(),
                recoverableIdleDecisionID: 71
            )
        }
        controller.runtimeResidencySnapshot = { await snapshots.next() }
        controller.scheduleDebounceSleep = { _ in await debounce.wait() }

        controller.handleSessionBecameActive(session: session, debounce: .seconds(30))
        await controller.awaitSessionActivation()
        await debounce.waitUntilBlocked()
        #expect(await snapshots.callCount() == 1)

        await debounce.release()
        await controller.scheduledWarmupTaskForTests?.value
        await controller.awaitInFlightWarmup()

        #expect(await snapshots.callCount() == 2)
        #expect(engine.requestCount == 1)
        #expect(controller.state == .warm)

        controller.scheduleDebounceSleep = { _ in }
        controller.handleRuntimeResidencyChanged(
            session: session,
            snapshot: evalResidencySnapshot(
                names: [],
                revision: 11,
                reason: .idlePolicy,
                idleDecisionID: 71
            ),
            isSessionActive: true
        )
        await controller.scheduledWarmupTaskForTests?.value
        await controller.awaitInFlightWarmup()

        #expect(await snapshots.callCount() == 3)
        #expect(engine.requestCount == 2)
        #expect(engine.lastRequest?.backgroundModelLoad == true)
        #expect(controller.state == .warm)
    }

    @Test("matching idle removal cannot cancel a yellow activation warmup")
    func idleRemovalPreservesWarmingActivation() async {
        let engine = EvalWarmupRecordingEngine()
        let session = EvalWarmupSession()
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "org/test-model",
            messages: [ChatMessage(role: "system", content: "stable shared prefix")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "org/test-model|warming-idle-removal"
        )

        let controller = ChatWarmupController()
        controller.projectedLoadFeasibility = { _ in nil }
        controller.hasResidentModelOther = { _ in false }
        let debounce = EvalWarmupDebounceGate()
        controller.chatActivationResidencySnapshot = { _ in
            ModelRuntimeChatActivationResidencySnapshot(
                residency: evalResidencySnapshot(names: ["test-model"], revision: 10),
                recoverableIdleDecisionID: 71
            )
        }
        controller.runtimeResidencySnapshot = {
            evalResidencySnapshot(
                names: [],
                revision: 11,
                reason: .idlePolicy,
                idleDecisionID: 71
            )
        }
        controller.scheduleDebounceSleep = { _ in await debounce.wait() }

        controller.handleSessionBecameActive(session: session, debounce: .seconds(30))
        await controller.awaitSessionActivation()
        await debounce.waitUntilBlocked()
        #expect(controller.state == .warming)

        controller.handleRuntimeResidencyChanged(
            session: session,
            snapshot: evalResidencySnapshot(
                names: [],
                revision: 11,
                reason: .idlePolicy,
                idleDecisionID: 71
            ),
            isSessionActive: true
        )
        #expect(controller.state == .warming)

        await debounce.release()
        await controller.scheduledWarmupTaskForTests?.value
        await controller.awaitInFlightWarmup()

        #expect(engine.requestCount == 1)
        #expect(engine.lastRequest?.backgroundModelLoad == true)
        #expect(controller.state == .warm)
    }
}

private func evalResidencySnapshot(
    names: [String],
    revision: UInt64,
    reason: ModelRuntimeResidencyChangeReason = .load,
    idleDecisionID: UInt64? = nil
) -> ModelRuntimeResidencySnapshot {
    ModelRuntimeResidencySnapshot(
        names: names,
        revision: revision,
        reason: reason,
        idleDecisionID: idleDecisionID
    )
}

private actor EvalResidentSnapshotSequence {
    private var snapshots: [ModelRuntimeResidencySnapshot]
    private var calls = 0

    init(_ snapshots: [ModelRuntimeResidencySnapshot]) {
        self.snapshots = snapshots
    }

    func next() -> ModelRuntimeResidencySnapshot {
        calls += 1
        precondition(!snapshots.isEmpty, "unexpected residency snapshot request")
        return snapshots.removeFirst()
    }

    func callCount() -> Int { calls }
}

private actor EvalWarmupDebounceGate {
    private var blocked = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        blocked = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilBlocked() async {
        while !blocked {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class EvalWarmupSession: ChatWarmupSessionContext {
    var selectedModel: String? = "org/test-model"
    var selectedModelIsLocal = true
    var isRemoteAgentTarget = false
    var isStreaming = false
    var payload: ChatWarmupPayload?
    var engine: ChatEngineProtocol = EvalWarmupRecordingEngine()

    func isImageGenerationModel(_ id: String?) -> Bool { false }
    func makeWarmupPayload() async -> ChatWarmupPayload? { payload }
    func makeWarmupEngine() -> ChatEngineProtocol { engine }
}

private final class EvalWarmupRecordingEngine: ChatEngineProtocol, @unchecked Sendable {
    var lastRequest: ChatCompletionRequest?
    var requestCount = 0

    func streamChat(
        request: ChatCompletionRequest
    ) async throws -> AsyncThrowingStream<String, Error> {
        lastRequest = request
        requestCount += 1
        return AsyncThrowingStream { $0.finish() }
    }

    func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        lastRequest = request
        return ChatCompletionResponse(
            id: "eval-warmup",
            object: "chat.completion",
            created: 0,
            model: request.model,
            choices: [],
            usage: Usage(prompt_tokens: 0, completion_tokens: 0, total_tokens: 0)
        )
    }
}
