import Foundation
import Testing

@testable import OsaurusCore

@Suite("Responses visual lifecycle", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct ResponsesVisualLifecycleTests {
    private actor Engine: ChatEngineProtocol {
        private var continuation: AsyncThrowingStream<ResponsesGenerationEvent, Error>.Continuation?
        private(set) var requestCount = 0
        private(set) var requests: [ResponsesInferenceRequest] = []
        func streamResponses(request: ResponsesInferenceRequest) async throws
            -> AsyncThrowingStream<ResponsesGenerationEvent, Error>
        {
            requestCount += 1
            requests.append(request)
            let pair = AsyncThrowingStream<ResponsesGenerationEvent, Error>.makeStream()
            continuation = pair.continuation
            return pair.stream
        }
        func emit(_ event: ResponsesGenerationEvent) { continuation?.yield(event) }
        func end() { continuation?.finish(); continuation = nil }
        func streamChat(request _: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
            throw NSError(domain: "unexpected-legacy-stream", code: 1)
        }
        func completeChat(request _: ChatCompletionRequest) async throws -> ChatCompletionResponse {
            throw NSError(domain: "unexpected-legacy-completion", code: 1)
        }
    }

    private func configure() {
        var config = ChatConfigurationStore.load()
        config.warmModelsOnLoad = false
        config.autoGenerateChatTitles = false
        ChatConfigurationStore.save(config)
        DefaultAgentConfigurationStore.save(DefaultAgentConfiguration(
            autonomousExec: nil, toolSelectionMode: .manual, manualToolNames: ["todo"]
        ))
        DefaultAgentConfigurationStore.resetCacheForTests()
        AgentManager.shared.refresh()
        UserDefaults.standard.set(false, forKey: "chatSmoothStreamingEnabled")
    }
    private func session(_ engine: Engine) -> ChatSession {
        let session = ChatSession()
        session.toolsDisabledForTestingOverride = true
        session.forceChatEngineRouteForTests = true
        session.selectedModel = "responses-visual-fixture"
        session.chatEngineFactory = { _ in engine }
        return session
    }
    private func wait(_ condition: @MainActor () async -> Bool) async throws {
        let until = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < until {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "ResponsesVisualLifecycleTests.timeout", code: 1)
    }
    private func completion() -> ResponsesGenerationEvent {
        .responseCompleted(.init(responseID: "resp_ui_fixture", status: .completed,
            functionCalls: [], tokenCount: 7, tokensPerSecond: 40.123,
            unclosedReasoning: false, stopReason: "stop", promptTokensPerSecond: nil, mtp: nil))
    }

    @Test(arguments: ["id", "encrypted", "items", "signed"])
    func providerOnlyTurnSurvivesRealCleanupAndTheNextCanonicalSend(_ carrier: String) async throws {
        try await ChatHistoryTestStorage.run {
            let smooth = UserDefaults.standard.object(forKey: "chatSmoothStreamingEnabled")
            defer {
                if let smooth { UserDefaults.standard.set(smooth, forKey: "chatSmoothStreamingEnabled") }
                else { UserDefaults.standard.removeObject(forKey: "chatSmoothStreamingEnabled") }
            }
            configure()
            let engine = Engine()
            let session = self.session(engine)
            let owner = ChatTurn(role: .assistant, content: "")
            switch carrier {
            case "id": owner.reasoningItemId = "rs_actual_fixture"
            case "encrypted": owner.reasoningEncrypted = "actual-opaque-provider-bytes"
            case "items": owner.responsesOutputItems = [.object([
                "type": .string("reasoning"), "id": .string("rs_raw_fixture"),
                "encrypted_content": .string("actual-raw-provider-bytes"),
            ])]
            default: owner.anthropicThinkingBlocks = [.object([
                "type": .string("thinking"), "thinking": .string("Native signed state"),
                "signature": .string("actual-provider-signature"),
            ])]
            }
            session.turns = [ChatTurn(role: .user, content: "Earlier actual user turn"), owner]
            #expect(ChatSession.modelVisibleAssistantMessage(owner, isLastTurn: true) != nil)
            // Real lifecycle cleanup exercises the trim, without manufacturing
            // a completed/charged/cancelled marker to keep the carrier alive.
            session.stop(preservesCancelledMarker: false)
            #expect(session.turns.contains { $0.id == owner.id })
            #expect(owner.contentIsBlank && owner.thinkingIsBlank && owner.generationTokenCount == nil)
            session.send("Continue from the provider's earlier state.")
            try await wait { await engine.requestCount == 1 }
            let request = try #require(await engine.requests.first)
            let replay = try #require(request.input.first { $0.role == "assistant" })
            #expect(replay.reasoning_item_id == owner.reasoningItemId)
            #expect(replay.reasoning_encrypted == owner.reasoningEncrypted)
            #expect((replay.responses_output_items ?? []) == owner.responsesOutputItems)
            #expect((replay.anthropic_thinking_blocks ?? []) == owner.anthropicThinkingBlocks)
            await engine.emit(.outputTextDelta("Continued actual fixture answer."))
            await engine.emit(completion())
            await engine.emit(.drained)
            await engine.end()
            try await wait { !session.isSendActiveForComposer }
            #expect(session.lastStreamError == nil)
        }
    }

    @Test func emptyProviderPlaceholdersDoNotPreventCleanup() async throws {
        try await ChatHistoryTestStorage.run {
            let owner = ChatTurn(role: .assistant, content: "")
            owner.reasoningItemId = ""
            owner.reasoningEncrypted = ""
            let session = ChatSession()
            session.turns = [ChatTurn(role: .user, content: "User turn"), owner]
            #expect(ChatSession.modelVisibleAssistantMessage(owner, isLastTurn: false) == nil)
            session.stop(preservesCancelledMarker: false)
            #expect(!session.turns.contains { $0.id == owner.id })
        }
    }

    @Test func progressIsOwnedByItsTurnAndInvalidatesTheBlockCache() throws {
        let first = ChatTurn(role: .assistant, content: "")
        let second = ChatTurn(role: .assistant, content: "")
        let memoizer = BlockMemoizer()
        let before = memoizer.blocks(from: [first], streamingTurnId: first.id,
            activeTurnId: first.id, agentName: "Assistant")
        #expect(before.allSatisfy { $0.prefillProgress == nil })
        for stage in [PrefillProgressStage.cacheRestore, .prefill] {
            first.prefillProgress = .init(stage: stage, completedUnitCount: 512, totalUnitCount: 1024, detail: nil)
            let changed = memoizer.blocks(from: [first], streamingTurnId: first.id,
                activeTurnId: first.id, agentName: "Assistant")
            let row = try #require(changed.first { if case .typingIndicator = $0.kind { return true }; return false })
            #expect(row.prefillProgress == first.prefillProgress)
            #expect(row.prefillProgress?.percentCompleted == 50)
            #expect(row.withPosition(.only).prefillProgress == first.prefillProgress)
        }
        let switched = memoizer.blocks(from: [second], streamingTurnId: second.id,
            activeTurnId: second.id, agentName: "Assistant")
        #expect(switched.allSatisfy { $0.prefillProgress == nil })
        let finishing = ContentBlock.typingIndicator(turnId: first.id, phase: .finishing,
            prefillProgress: first.prefillProgress, position: .only)
        #expect(finishing.prefillProgress == nil)
    }

    @Test func reasoningCanResumeAfterConfirmedContentOrToolBoundary() throws {
        let turn = ChatTurn(role: .assistant, content: "Visible commentary")
        let start = Date(timeIntervalSince1970: 1000)
        turn.appendThinking("First reasoning.", at: start)
        turn.finalizeThinkingDuration(at: start.addingTimeInterval(2))
        let memoizer = BlockMemoizer()
        let stopped = memoizer.blocks(from: [turn], streamingTurnId: turn.id,
            activeTurnId: turn.id, agentName: "Assistant")
        #expect(stopped.contains { if case let .thinking(_, _, active, _) = $0.kind { return !active }; return false })
        turn.appendThinking(" Resumed reasoning.", at: start.addingTimeInterval(20))
        let resumed = memoizer.blocks(from: [turn], streamingTurnId: turn.id,
            activeTurnId: turn.id, agentName: "Assistant")
        #expect(resumed.contains { if case let .thinking(_, _, active, _) = $0.kind { return active }; return false })
        turn.finalizeThinkingDuration(at: start.addingTimeInterval(21))
        #expect(turn.thinkingDuration == 3, "intervening tool/queue time is not active reasoning")
        #expect(turn.thinking == "First reasoning. Resumed reasoning.")
        #expect(turn.content == "Visible commentary")
    }

    @Test func interruptedRevealDrainsReceivedTextAndStopsItsTimers() async {
        let key = "chatSmoothStreamingEnabled"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(true, forKey: key)
        let turn = ChatTurn(role: .assistant, content: "")
        let processor = StreamingDeltaProcessor(turn: turn)
        let text = String(repeating: "Received text. ", count: 100)
        processor.receiveDelta(text)
        var returned = false
        let finalizer = Task { @MainActor in await processor.finalize(); returned = true }
        await Task.yield()
        processor.finishImmediately()
        await finalizer.value
        #expect(returned)
        #expect(turn.content == text)
        #expect(processor.pacingTimer == nil)
        processor.receiveReasoning("New actual reasoning.")
        #expect(turn.isReasoningActive)
    }

    @Test func typedProgressAndFirstOutputIgnoreForeignGlobalWork() async throws {
        try await ChatHistoryTestStorage.run {
            let smooth = UserDefaults.standard.object(forKey: "chatSmoothStreamingEnabled")
            defer {
                if let smooth { UserDefaults.standard.set(smooth, forKey: "chatSmoothStreamingEnabled") }
                else { UserDefaults.standard.removeObject(forKey: "chatSmoothStreamingEnabled") }
            }
            configure()
            let engine = Engine()
            let session = self.session(engine)
            session.send("Inspect the attached fixture.")
            try await wait { await engine.requestCount == 1 }
            let manager = InferenceProgressManager.shared
            manager._testBeginModelLoad(at: Date().addingTimeInterval(-1))
            manager.prefillDidUpdate(.init(stage: .prefill, completedUnitCount: 1, totalUnitCount: 9999, detail: nil))
            defer { manager._testEndModelLoad(at: Date()); manager.prefillDidFinish() }
            await engine.emit(.inputTokenCount(1024))
            await engine.emit(.prefillProgress(.init(stage: .cacheRestore, completedUnitCount: 512, totalUnitCount: 1024, detail: nil)))
            try await wait { session.turns.last?.prefillProgress?.completedUnitCount == 512 }
            let turn = try #require(session.turns.last)
            #expect(turn.timeToFirstToken == nil)
            #expect(turn.contentIsEmpty && turn.thinkingIsEmpty)
            #expect(session.visibleBlocks.contains { $0.prefillProgress?.totalUnitCount == 1024 })
            #expect(!session.visibleBlocks.contains { $0.prefillProgress?.totalUnitCount == 9999 })
            try await Task.sleep(for: .milliseconds(80))
            await engine.emit(.outputTextDelta("The fixture is visible."))
            await engine.emit(completion())
            try await wait { session.outputComplete }
            #expect(turn.prefillProgress == nil)
            #expect(session.isSendActiveForComposer, "producer drain still owns the active run")
            await engine.emit(.drained)
            await engine.end()
            try await wait { !session.isSendActiveForComposer }
            #expect((turn.timeToFirstToken ?? 0) >= 0.06)
            #expect(turn.modelLoadSeconds == nil, "uncorrelated background load is not subtracted")
            #expect(turn.generationTokensPerSecond == 40.123)
            #expect(turn.content == "The fixture is visible.")
        }
    }

    @Test(arguments: ["missing", "duplicate", "post-completion", "premature-drain"])
    func invalidTypedLifecycleCannotAppearAsCleanVisualCompletion(_ shape: String) async throws {
        try await ChatHistoryTestStorage.run {
            let smooth = UserDefaults.standard.object(forKey: "chatSmoothStreamingEnabled")
            defer {
                if let smooth { UserDefaults.standard.set(smooth, forKey: "chatSmoothStreamingEnabled") }
                else { UserDefaults.standard.removeObject(forKey: "chatSmoothStreamingEnabled") }
            }
            configure()
            let engine = Engine()
            let session = self.session(engine)
            session.send("fixture")
            try await wait { await engine.requestCount == 1 }
            if shape == "premature-drain" { await engine.emit(.drained) }
            else {
                await engine.emit(.outputTextDelta("Received partial answer."))
                if shape != "missing" { await engine.emit(completion()) }
                if shape == "duplicate" { await engine.emit(completion()) }
                if shape == "post-completion" { await engine.emit(.reasoningDelta("late")) }
            }
            await engine.end()
            try await wait { !session.isSendActiveForComposer }
            #expect(session.lastStreamError != nil)
            #expect(session.turns.last?.prefillProgress == nil)
            #expect(!session.visibleBlocks.contains { if case .typingIndicator = $0.kind { return true }; return false })
        }
    }
}
