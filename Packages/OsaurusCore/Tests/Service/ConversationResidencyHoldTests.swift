import Foundation
import Testing

@testable import OsaurusCore

/// A conversation loop keeps the models it generates with resident from its first generation until it exits
/// (`ConversationResidencyHold`): a tool wait longer than the idle setting (default 30 s) must not unload a 95 GB
/// model between two steps of one turn (MiniMax-M3.1: 13.6-14.4 s per reload on an M5 Max). The idle timer then
/// counts from the loop's end.
@Suite("Conversation residency hold", .serialized)
@MainActor
struct ConversationResidencyHoldTests {
    private func call(_ name: String) -> ServiceToolInvocation {
        ServiceToolInvocation(toolName: name, jsonArguments: "{}", toolCallId: nil)
    }

    private func hooks(
        model: String,
        steps: [AgentLoopModelStep],
        record: @escaping (_ phase: String, _ hold: ConversationResidencyHold?, _ held: Bool) -> Void,
        failAtStep: Int? = nil
    ) -> AgentLoopHooks {
        var remaining = steps
        var step = 0
        return AgentLoopHooks(
            buildMessages: { _ in
                AgentLoopIterationInput(messages: [ChatMessage(role: "user", content: "task")], overBudget: false)
            },
            modelStep: { _, _ in
                step += 1
                // What `ModelRuntime.generateEventStream` does at every generation start.
                let hold = await ModelRuntime.shared.registerConversationGeneration(modelName: model)
                record("step\(step)", hold, await ModelRuntime.shared.isHeldByConversation(model))
                if step == failAtStep { throw CancellationError() }
                return remaining.isEmpty ? .finalResponse : remaining.removeFirst()
            },
            executeTool: { invocation, _ in
                // The tool is running (a slow tool, a permission prompt): the model must still be held.
                record("tool", ConversationResidencyHoldContext.current,
                       await ModelRuntime.shared.isHeldByConversation(model))
                return AgentLoopToolExecution(result: ToolEnvelope.success(tool: invocation.toolName, text: "ok"))
            }
        )
    }

    private func policy() -> AgentLoopPolicy {
        AgentLoopPolicy(maxIterations: 6, stopOnToolRejection: true, dedupeNoticeEnabled: false)
    }

    @Test("the loop holds its model from the first step through the tool wait to the last step, then releases it")
    func holdSpansTheWholeLoop() async throws {
        let model = "conversation-hold-test-\(UUID().uuidString)"
        var seen: [(String, ConversationResidencyHold?, Bool)] = []
        let result = try await AgentToolLoop.run(
            policy: policy(),
            state: AgentTaskState(),
            hooks: hooks(
                model: model,
                steps: [.toolCalls([call("slow_tool")]), .finalResponse],
                record: { seen.append(($0, $1, $2)) })
        )
        #expect(result.exit == .finalResponse)
        #expect(seen.map(\.0) == ["step1", "tool", "step2"])
        let holds = seen.compactMap(\.1)
        #expect(holds.count == 3, "every step and the tool ran inside the loop's hold")
        #expect(Set(holds.map(\.id)).count == 1, "one hold for the whole loop")
        #expect(seen.allSatisfy { $0.2 }, "held at every step and while the tool ran: \(seen.map { ($0.0, $0.2) })")
        // After the loop: released (its idle timer may start now) and never re-registerable.
        #expect(await ModelRuntime.shared.isHeldByConversation(model) == false)
        #expect(holds.first?.isActive == false)
        #expect(await ModelRuntime.shared.registerConversationGeneration(modelName: model) == nil)
    }

    @Test("a loop that throws still releases its hold")
    func holdIsReleasedOnThrow() async {
        let model = "conversation-hold-throw-\(UUID().uuidString)"
        var seen: [(String, ConversationResidencyHold?, Bool)] = []
        await #expect(throws: CancellationError.self) {
            _ = try await AgentToolLoop.run(
                policy: policy(),
                state: AgentTaskState(),
                hooks: hooks(
                    model: model, steps: [.toolCalls([call("slow_tool")])],
                    record: { seen.append(($0, $1, $2)) }, failAtStep: 2))
        }
        #expect(seen.map(\.0) == ["step1", "tool", "step2"])
        #expect(seen.allSatisfy { $0.2 })
        #expect(await ModelRuntime.shared.isHeldByConversation(model) == false)
        #expect(seen.first?.1?.isActive == false)
    }

    @Test("outside a loop nothing is held (a plain API request keeps the configured policy)")
    func noLoopNoHold() async {
        let model = "conversation-hold-none-\(UUID().uuidString)"
        #expect(ConversationResidencyHoldContext.current == nil)
        #expect(await ModelRuntime.shared.registerConversationGeneration(modelName: model) == nil)
        #expect(await ModelRuntime.shared.isHeldByConversation(model) == false)
    }

    /// Live finding (Qwen3-VL-8B, idle setting 30 s): a follow-up sent 13 s after the previous turn released its hold
    /// spent 20 s in preflight before its first generation, and the previous turn's timer unloaded the model under it
    /// (reload, then a full re-prefill). The turn's own hold now covers that window.
    @Test("a chat turn holds its local model from its first line, across its loop, until the turn ends")
    func turnHoldCoversPreflight() async throws {
        try await ChatHistoryTestStorage.run {
            try await withCatalog([
                MLXModel(
                    id: "turn-hold-fixture/Turn-Hold-Model-4bit", name: "Turn Hold", description: "fixture",
                    downloadURL: "https://example.invalid/turn-hold")
            ]) {
                let model = "turn-hold-model-4bit"
                let turn = try #require(
                    await ModelRuntime.shared.beginTurnResidencyHold(modelName: "Turn-Hold-Model-4bit"))
                #expect(await ModelRuntime.shared.isHeldByConversation(model), "held before any generation")

                var seen: [(String, ConversationResidencyHold?, Bool)] = []
                _ = try await AgentToolLoop.run(
                    policy: policy(), state: AgentTaskState(),
                    hooks: hooks(model: model, steps: [.finalResponse], record: { seen.append(($0, $1, $2)) }))
                #expect(seen.first?.1?.id != turn.id, "the loop takes its own hold inside the turn's")
                #expect(await ModelRuntime.shared.isHeldByConversation(model), "the loop's exit does not free the turn")

                await ModelRuntime.shared.releaseConversationResidencyHold(turn)
                #expect(await ModelRuntime.shared.isHeldByConversation(model) == false)
                #expect(turn.isActive == false)
            }
        }
    }

    @Test("a model that is neither resident nor installed gets no turn hold")
    func remoteModelGetsNoTurnHold() async throws {
        try await ChatHistoryTestStorage.run {
            try await withCatalog([]) {
                let hold = await ModelRuntime.shared.beginTurnResidencyHold(modelName: "provider/remote-only-model")
                #expect(hold == nil)
                #expect(await ModelRuntime.shared.isHeldByConversation("remote-only-model") == false)
            }
        }
    }

    /// A deterministic installed-model catalog for `body` (same override `LocalModelDetectionTests` uses). Runs
    /// inside `ChatHistoryTestStorage.run`, which holds the lock the scan overrides are mutated under.
    private func withCatalog(_ models: [MLXModel], _ body: () async throws -> Void) async throws {
        let prevScan = ModelManager.scanLocalModelsOverrideForTests
        let prevWait = ModelManager.localModelsScanWaitLimitOverrideForTests
        let prevExternal = ExternalModelLocator.testRootsOverride
        ExternalModelLocator.testRootsOverride = []
        ExternalModelLocator.invalidateInMemory()
        _ = ExternalModelLocator.rescan()
        ModelManager.localModelsScanWaitLimitOverrideForTests = 2.0
        ModelManager.scanLocalModelsOverrideForTests = { _ in models }
        ModelManager.invalidateLocalModelsCache()
        defer {
            ModelManager.scanLocalModelsOverrideForTests = prevScan
            ModelManager.localModelsScanWaitLimitOverrideForTests = prevWait
            ExternalModelLocator.testRootsOverride = prevExternal
            ExternalModelLocator.invalidateInMemory()
            ModelManager.invalidateLocalModelsCache()
        }
        _ = ModelManager.localModelsSnapshotNonBlocking()
        let deadline = ContinuousClock.now + .seconds(10)
        while !ModelManager.isLocalModelsCacheWarm, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(ModelManager.isLocalModelsCacheWarm, "Fixture scan did not publish its catalog")
        try await body()
    }

    @Test("bookkeeping: overlapping loops free a model only when the last one ends; a released hold never re-registers")
    func bookkeeping() {
        var holds = ConversationResidencyHolds()
        let a = ConversationResidencyHold()
        let b = ConversationResidencyHold()
        let registered = [
            holds.register(a, model: "m"), holds.register(b, model: "m"), holds.register(a, model: "other"),
        ]
        #expect(registered == [true, true, true])
        #expect(holds.holdCount(for: "m") == 2)
        let freedA = holds.release(a)
        #expect(freedA == ["other"])
        #expect(holds.holds("m"))
        let reRegistered = holds.register(a, model: "m")
        #expect(!reRegistered, "a released hold must not re-register")
        let freedB = holds.release(b)
        #expect(freedB == ["m"])
        #expect(!holds.holds("m"))
        let freedAgain = holds.release(b)
        #expect(freedAgain.isEmpty)
    }

    @Test("a held model gets no idle deadline under any configured policy; unheld keeps the configured one")
    func heldModelHasNoIdleDeadline() async {
        for configured in [ModelIdleResidencyPolicy.immediately, .defaultWarm, .afterSeconds(300), .never] {
            for source in [RequestSource.chatUI, .httpAPI] as [RequestSource?] {
                let held = ModelRuntime.resolvedIdleResidencyPolicy(
                    configured: configured, source: source, referencedByChat: true,
                    hasHandoffOwner: false, heldByConversation: true)
                #expect(held == .never, "\(configured) \(String(describing: source))")
                let unheld = ModelRuntime.resolvedIdleResidencyPolicy(
                    configured: configured, source: source, referencedByChat: true,
                    hasHandoffOwner: false, heldByConversation: false)
                #expect(unheld == configured, "control: \(configured)")
            }
        }
        // The runtime's sequence through the real timer: held -> no deadline; released at t1 -> the configured
        // deadline counts from t1 (the loop's end), not from the end of the first generation.
        let manager = ModelResidencyManager(sleep: { _ in try? await Task.sleep(nanoseconds: 60_000_000_000) })
        let t0 = Date(timeIntervalSince1970: 1_000)
        await manager.scheduleIdleUnload(
            modelName: "m", policy: .never, now: t0, unload: { _ in Issue.record("held model unloaded") },
            leaseCount: { _ in 0 }, isResident: { _ in true })
        #expect(await manager.snapshots().first?.unloadAt == nil)
        let t1 = t0.addingTimeInterval(95)  // a 95 s tool wait
        await manager.scheduleIdleUnload(
            modelName: "m", policy: .defaultWarm, now: t1, unload: { _ in },
            leaseCount: { _ in 0 }, isResident: { _ in true })
        #expect(await manager.snapshots().first?.unloadAt == t1.addingTimeInterval(30))
        await manager.cancelAll()
    }
}
