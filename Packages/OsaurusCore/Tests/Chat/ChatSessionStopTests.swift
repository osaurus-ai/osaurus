import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatSessionStopTests {
    private static let asyncTimeout: Duration = .seconds(10)

    private func enableDefaultAgentTools(warmModelsOnLoad: Bool) {
        var chatConfig = ChatConfigurationStore.load()
        chatConfig.disableTools = false
        chatConfig.warmModelsOnLoad = warmModelsOnLoad
        chatConfig.autoGenerateChatTitles = false
        ChatConfigurationStore.save(chatConfig)

        DefaultAgentConfigurationStore.save(
            DefaultAgentConfiguration(
                disableTools: false,
                autonomousExec: nil,
                toolSelectionMode: .manual,
                manualToolNames: ["todo"]
            )
        )
        DefaultAgentConfigurationStore.resetCacheForTests()
        AgentManager.shared.refresh()
    }

    private func beginSuspendedPreSendHandshake(
        session: ChatSession,
        gate: IgnoringCancellationHandshakeGate
    ) async throws {
        try await beginSuspendedPreSendHandshake(
            session: session,
            gate: gate,
            warmupSession: session,
            model: "handshake-test-model"
        )
    }

    private func beginSuspendedPreSendHandshake(
        session: ChatSession,
        gate: IgnoringCancellationHandshakeGate,
        warmupSession: any ChatWarmupSessionContext,
        model: String
    ) async throws {
        session.warmupController.handleModelSelectionChange(
            session: warmupSession,
            to: model,
            performSwitch: { _ in await gate.wait() }
        )
        try await waitUntilAsync(timeout: Self.asyncTimeout) {
            await gate.started
                && session.warmupController.needsPreSendHandshake
        }
    }

    @Test
    func stop_trimsTrailingEmptyAssistantPlaceholder() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.turns = [
                ChatTurn(role: .user, content: "Hello"),
                ChatTurn(role: .assistant, content: ""),
            ]

            session.stop()

            #expect(session.turns.count == 1)
            #expect(session.turns.last?.role == .user)
        }
    }

    @Test
    func trackedTodoContinuationKeepsPrematureResponseVisibleButOutOfModelHistory() {
        let user = ChatTurn(role: .user, content: "research these repositories")
        let progress = ChatTurn(
            role: .assistant,
            content: "Got the Osaurus models. Now let me check the other two orgs."
        )
        ChatSession.excludeAbandonedTrackedTaskResponse(progress)
        let emptyContinuationBuffer = ChatTurn(role: .assistant, content: "")
        let turns = [user, progress, emptyContinuationBuffer]

        var messages = [ChatMessage(role: "user", content: user.content)]
        for (index, turn) in turns.enumerated() where turn.role == .assistant {
            if let message = ChatSession.modelVisibleAssistantMessage(
                turn,
                isLastTurn: index == turns.count - 1
            ) {
                messages.append(message)
            }
        }

        #expect(progress.content == "Got the Osaurus models. Now let me check the other two orgs.")
        #expect(progress.modelContextExcluded)
        #expect(messages.map(\.role) == ["user"])
        #expect(messages.map(\.content) == ["research these repositories"])
        #expect(ChatSession.modelVisibleAssistantMessage(progress, isLastTurn: false) == nil)
    }

    @Test
    func incompleteReasoningRetryKeepsAbandonedTurnVisibleButOutOfToolHistory() throws {
        let session = ChatSession()
        let abandoned = ChatTurn(role: .assistant, content: "")
        abandoned.appendThinking("unfinished private reasoning")
        abandoned.modelContextExcluded = true

        let retry = ChatTurn(role: .assistant, content: "")
        retry.toolCalls = [
            ToolCall(
                id: "retry-call",
                type: "function",
                function: ToolCallFunction(
                    name: "search_and_extract",
                    arguments: #"{"url":"https://example.com"}"#
                )
            )
        ]

        #expect(
            ChatSession.modelVisibleAssistantMessage(abandoned, isLastTurn: false) == nil
        )
        #expect(session.warmupTurnToMessage(abandoned, isLastTurn: false) == nil)
        let retryMessage = try #require(
            ChatSession.modelVisibleAssistantMessage(retry, isLastTurn: false)
        )
        let warmupRetryMessage = try #require(
            session.warmupTurnToMessage(retry, isLastTurn: false)
        )
        #expect(retryMessage.tool_calls?.first?.id == "retry-call")
        #expect(retryMessage.reasoning_content == nil)
        #expect(warmupRetryMessage.role == retryMessage.role)
        #expect(warmupRetryMessage.content == retryMessage.content)
        #expect(warmupRetryMessage.tool_calls?.first?.id == retryMessage.tool_calls?.first?.id)
        #expect(warmupRetryMessage.reasoning_content == retryMessage.reasoning_content)

        let encoded = try JSONEncoder().encode(ChatTurnData(from: abandoned))
        let decoded = try JSONDecoder().decode(ChatTurnData.self, from: encoded)
        let restored = ChatTurn(from: decoded)
        #expect(restored.modelContextExcluded)
        #expect(
            ChatSession.modelVisibleAssistantMessage(restored, isLastTurn: false) == nil
        )
    }

    @Test
    func stop_ignoresLateResultsWhenEngineSetupIgnoresCancellation() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.chatEngineFactory = { _ in IgnoringCancellationChatEngine() }

            session.send("Hello")
            try await Task.sleep(for: .milliseconds(20))
            session.stop()

            #expect(session.isStreaming == false)

            try await Task.sleep(for: .milliseconds(250))

            #expect(session.turns.count == 1)
            #expect(session.turns.first?.role == .user)
            #expect(session.turns.first?.content == "Hello")
        }
    }

    @Test
    func stop_cancelsEngineSetupBeforeStreamIsReturned() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let engine = CancellationObservingChatEngine()
            session.chatEngineFactory = { _ in engine }

            session.send("Hello")
            try await waitUntilAsync(timeout: Self.asyncTimeout) {
                await engine.started
            }

            session.stop()

            try await waitUntilAsync(timeout: Self.asyncTimeout) {
                await engine.cancelled
            }
            #expect(session.isStreaming == false)
            #expect(session.turns.count == 1)
            #expect(session.turns.first?.role == .user)
        }
    }

    @Test
    func explicitModelUnloadPreparationUsesStopLifecycle() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let engine = CancellationObservingChatEngine()
            session.chatEngineFactory = { _ in engine }

            session.send("Keep this partial turn")
            try await waitUntilAsync(timeout: Self.asyncTimeout) {
                await engine.started
            }

            session.prepareForExplicitModelUnload()

            try await waitUntilAsync(timeout: Self.asyncTimeout) {
                await engine.cancelled
            }
            #expect(session.isSendActiveForComposer == false)
            #expect(session.turns.count == 1)
            #expect(session.turns.first?.role == .user)
            #expect(session.turns.first?.content == "Keep this partial turn")
        }
    }

    @Test
    func send_ignoresReentrantSendBeforeStreamingFlagFlips() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.chatEngineFactory = { _ in IgnoringCancellationChatEngine() }

            session.send("first")
            session.send("second")

            let userTurns = session.turns.filter { $0.role == .user }
            #expect(userTurns.map(\.content) == ["first"])

            session.stop()
        }
    }

    @Test
    func stop_invalidatesSuspendedPreSendHandshakeWithoutLaunchingCapturedTurn() async throws {
        try await ChatHistoryTestStorage.run {
            var chatConfig = ChatConfigurationStore.load()
            chatConfig.warmModelsOnLoad = true
            ChatConfigurationStore.save(chatConfig)

            let session = ChatSession()
            let gate = IgnoringCancellationHandshakeGate()
            let engine = PreSendHandshakeRecordingEngine()
            session.chatEngineFactory = { _ in engine }
            let warmupSession = IncomingWarmupSession(engine: engine)
            try await beginSuspendedPreSendHandshake(
                session: session,
                gate: gate,
                warmupSession: warmupSession,
                model: "incoming-warmup-model"
            )

            session.send("keep this stopped turn")
            #expect(session.turns.map(\.content) == ["keep this stopped turn"])

            session.stop()
            await gate.release()
            try await waitUntil(timeout: Self.asyncTimeout) {
                !session.warmupController.needsPreSendHandshake
            }
            // Give the zero-debounce task the stale switch used to schedule a
            // chance to run. Counting only regular requests would miss this
            // hidden post-Stop warm-up.
            try await Task.sleep(for: .milliseconds(250))

            #expect(session.isStreaming == false)
            #expect(session.turns.map(\.content) == ["keep this stopped turn"])
            #expect(await engine.regularRequestCount == 0)
            #expect(await engine.warmupRequestCount == 0)

            session.send("fresh turn after stopped handshake")
            try await waitUntilAsync(timeout: Self.asyncTimeout) {
                await engine.regularRequestCount == 1
            }
            try await waitUntil(timeout: Self.asyncTimeout) {
                session.isSendActiveForComposer == false
            }

            #expect(
                session.turns.filter { $0.role == .user }.map(\.content)
                    == ["keep this stopped turn", "fresh turn after stopped handshake"]
            )
            #expect(await engine.regularRequestCount == 1)
        }
    }

    @Test
    func reset_doesNotResurrectTurnCapturedBySuspendedPreSendHandshake() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let gate = IgnoringCancellationHandshakeGate()
            let engine = PreSendHandshakeRecordingEngine()
            session.chatEngineFactory = { _ in engine }
            try await beginSuspendedPreSendHandshake(session: session, gate: gate)

            session.send("old chat turn")
            #expect(session.turns.map(\.content) == ["old chat turn"])

            session.reset()
            await gate.release()
            try await Task.sleep(for: .milliseconds(250))

            #expect(session.turns.isEmpty)
            #expect(session.sessionId == nil)
            #expect(session.isStreaming == false)
            #expect(await engine.regularRequestCount == 0)
        }
    }

    @Test
    func reset_incomingWarmupSurvivesCancelledPreviousHandshake() async throws {
        try await ChatHistoryTestStorage.run {
            var chatConfig = ChatConfigurationStore.load()
            chatConfig.warmModelsOnLoad = true
            ChatConfigurationStore.save(chatConfig)

            let session = ChatSession()
            let gate = IgnoringCancellationHandshakeGate()
            session.chatEngineFactory = { _ in PreSendHandshakeRecordingEngine() }
            try await beginSuspendedPreSendHandshake(session: session, gate: gate)

            session.send("old chat turn")
            session.reset()

            let incomingEngine = IncomingWarmupRecordingEngine()
            let incomingSession = IncomingWarmupSession(engine: incomingEngine)
            session.warmupController.scheduleWarmup(
                session: incomingSession,
                debounce: .milliseconds(250)
            )

            await gate.release()
            try await waitUntilAsync(timeout: Self.asyncTimeout) {
                await incomingEngine.requestCount == 1
            }

            #expect(session.turns.isEmpty)
            #expect(await incomingEngine.requestCount == 1)
        }
    }

    @Test
    func stoppedPreSendWarmupCannotResurrectWarmStateAfterIgnoringCancellation() async throws {
        try await ChatHistoryTestStorage.run {
            var chatConfig = ChatConfigurationStore.load()
            chatConfig.warmModelsOnLoad = true
            ChatConfigurationStore.save(chatConfig)

            let session = ChatSession()
            let controller = session.warmupController
            controller.projectedLoadFeasibility = { _ in nil }
            let gate = IgnoringCancellationHandshakeGate()
            let engine = CancellationIgnoringWarmupEngine(gate: gate)
            let warmupSession = IncomingWarmupSession(engine: engine)
            let regularEngine = PreSendHandshakeRecordingEngine()
            session.chatEngineFactory = { _ in regularEngine }

            controller.scheduleWarmup(session: warmupSession, debounce: .zero)
            try await waitUntilAsync(timeout: Self.asyncTimeout) {
                let started = await gate.started
                let requestCount = await engine.requestCount
                return started && requestCount == 1
            }
            #expect(controller.needsPreSendHandshake)

            session.send("stop this turn while warm-up streamChat is suspended")
            #expect(session.isSendActiveForComposer)
            session.stop()
            #expect(controller.state == .cold)

            // The engine's streamChat is deliberately suspended on a checked
            // continuation, so cancelling the consumer cannot unwind it. The
            // controller must retain the cancelled task until the engine
            // actually releases its generation lease.
            try await Task.sleep(for: .milliseconds(100))
            #expect(controller.needsPreSendHandshake)
            #expect(await engine.requestCount == 1)
            #expect(await regularEngine.regularRequestCount == 0)

            await gate.release()

            try await waitUntil(timeout: Self.asyncTimeout) {
                !controller.needsPreSendHandshake
            }
            try await Task.sleep(for: .milliseconds(250))

            #expect(controller.state == .cold)
            #expect(await engine.requestCount == 1)
            #expect(await regularEngine.regularRequestCount == 0)
            #expect(session.isSendActiveForComposer == false)
        }
    }

    @Test
    func resetRetainsCancelledWarmupAsDrainBarrierForImmediateFollowUp() async throws {
        try await ChatHistoryTestStorage.run {
            var chatConfig = ChatConfigurationStore.load()
            chatConfig.warmModelsOnLoad = true
            ChatConfigurationStore.save(chatConfig)

            let session = ChatSession()
            let controller = session.warmupController
            controller.projectedLoadFeasibility = { _ in nil }
            let gate = IgnoringCancellationHandshakeGate()
            let warmupEngine = CancellationIgnoringWarmupEngine(gate: gate)
            let warmupSession = IncomingWarmupSession(engine: warmupEngine)
            let regularEngine = PreSendHandshakeRecordingEngine()
            session.chatEngineFactory = { _ in regularEngine }
            session.forceChatEngineRouteForTests = true

            controller.scheduleWarmup(session: warmupSession, debounce: .zero)
            try await waitUntilAsync(timeout: Self.asyncTimeout) {
                let started = await gate.started
                let requestCount = await warmupEngine.requestCount
                return started && requestCount == 1
            }

            session.send("outgoing turn waiting on warm-up")
            #expect(session.isSendActiveForComposer)
            session.stop()
            session.reset()

            // New Chat must not detach the cancelled warm-up from the
            // controller while its engine still owns the generation lease.
            #expect(controller.needsPreSendHandshake)

            session.send("fresh new-chat follow-up")
            #expect(session.isSendActiveForComposer)
            try await Task.sleep(for: .milliseconds(100))

            #expect(await warmupEngine.requestCount == 1)
            #expect(await regularEngine.regularRequestCount == 0)

            await gate.release()

            try await waitUntil(timeout: Self.asyncTimeout) {
                session.isSendActiveForComposer == false
            }

            #expect(!controller.needsPreSendHandshake)
            #expect(
                session.turns.filter { $0.role == .user }.map(\.content)
                    == ["fresh new-chat follow-up"]
            )
            #expect(await warmupEngine.requestCount == 1)
            #expect(await regularEngine.regularRequestCount == 1)
        }
    }

    @Test
    func sessionLoad_doesNotAppendTurnCapturedByPreviousHandshake() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let gate = IgnoringCancellationHandshakeGate()
            let engine = PreSendHandshakeRecordingEngine()
            session.chatEngineFactory = { _ in engine }
            try await beginSuspendedPreSendHandshake(session: session, gate: gate)

            session.send("old chat turn")
            let loaded = ChatSessionData(
                id: UUID(),
                title: "Loaded chat",
                turns: [ChatTurnData(role: .user, content: "loaded turn")]
            )
            session.load(from: loaded)
            await gate.release()
            try await Task.sleep(for: .milliseconds(250))

            #expect(session.sessionId == loaded.id)
            #expect(session.turns.map(\.content) == ["loaded turn"])
            #expect(session.isStreaming == false)
            #expect(await engine.regularRequestCount == 0)
        }
    }

    @Test
    func sessionLoad_dropsQueuedDraftAndOneOffSkillFromPreviousHandshake() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let gate = IgnoringCancellationHandshakeGate()
            let engine = PreSendHandshakeRecordingEngine()
            session.chatEngineFactory = { _ in engine }
            try await beginSuspendedPreSendHandshake(session: session, gate: gate)

            session.send("old chat turn")
            session.pendingOneOffSkillId = UUID()
            session.enqueueSend("old queued draft", attachments: [])
            session.pendingOneOffSkillId = UUID()
            #expect(session.queuedSend?.text == "old queued draft")
            #expect(session.queuedSend?.oneOffSkillId != nil)
            #expect(session.pendingOneOffSkillId != nil)

            let loaded = ChatSessionData(
                id: UUID(),
                title: "Loaded chat",
                turns: [ChatTurnData(role: .user, content: "loaded turn")]
            )
            session.load(from: loaded)

            #expect(session.queuedSend == nil)
            #expect(session.pendingOneOffSkillId == nil)

            await gate.release()
            try await Task.sleep(for: .milliseconds(250))

            #expect(session.sessionId == loaded.id)
            #expect(session.turns.map(\.content) == ["loaded turn"])
            #expect(session.isSendActiveForComposer == false)
            #expect(await engine.regularRequestCount == 0)
        }
    }

    @Test
    func send_ignoresReentrantSendWhilePreSendHandshakeIsSuspended() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let gate = IgnoringCancellationHandshakeGate()
            let engine = PreSendHandshakeRecordingEngine()
            session.chatEngineFactory = { _ in engine }
            try await beginSuspendedPreSendHandshake(session: session, gate: gate)

            session.send("first")
            session.send("second")

            #expect(session.turns.filter { $0.role == .user }.map(\.content) == ["first"])

            session.stop()
            session.warmupController.reset()
            await gate.release()
        }
    }

    @Test
    func sendCurrent_queuesDraftWhilePreSendHandshakeIsSuspended() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let gate = IgnoringCancellationHandshakeGate()
            session.chatEngineFactory = { _ in PreSendHandshakeRecordingEngine() }
            try await beginSuspendedPreSendHandshake(session: session, gate: gate)

            session.send("first")
            #expect(session.isSendActiveForComposer)

            session.input = "second"
            session.sendCurrent()

            #expect(session.turns.filter { $0.role == .user }.map(\.content) == ["first"])
            #expect(session.queuedSend?.text == "second")
            #expect(session.input.isEmpty)

            session.stop()
            #expect(session.isSendActiveForComposer == false)
            session.warmupController.reset()
            await gate.release()
        }
    }

    @Test
    func sendNowInterrupting_replacesSuspendedHandshakeWithQueuedSend() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let gate = IgnoringCancellationHandshakeGate()
            let engine = PreSendHandshakeRecordingEngine()
            session.chatEngineFactory = { _ in engine }
            try await beginSuspendedPreSendHandshake(session: session, gate: gate)

            session.send("first")
            session.enqueueSend("replacement", attachments: [])
            session.sendNowInterrupting()

            #expect(
                session.turns.filter { $0.role == .user }.map(\.content)
                    == ["first", "replacement"]
            )

            await gate.release()
            try await waitUntilAsync(timeout: Self.asyncTimeout) {
                await engine.regularRequestCount == 1
            }
        }
    }

    @Test
    func send_finishesReasoningOnlyLocalStream() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let engine = ReasoningOnlyChatEngine()
            session.chatEngineFactory = { _ in engine }

            session.send("Hello")

            try await waitUntil(timeout: Self.asyncTimeout) {
                session.turns.contains { $0.role == .assistant && !$0.thinkingIsBlank }
            }
            try await waitUntil(timeout: Self.asyncTimeout) {
                session.isStreaming == false
            }

            let assistant = try #require(session.turns.last(where: { $0.role == .assistant }))
            #expect(assistant.contentIsBlank)
            #expect(assistant.thinking.contains("The user is straightforward greeting"))
            #expect(assistant.generationTokenCount == 0)
            #expect(await engine.streamRequestCount == 1)
        }
    }

    @Test
    func send_marksPostToolEmptyExhaustionFailedAndCancelsWarmup() async throws {
        try await ChatHistoryTestStorage.run {
            enableDefaultAgentTools(warmModelsOnLoad: true)

            let session = ChatSession()
            session.selectedModel = "chat-session-tool-loop-test-model"
            session.forceChatEngineRouteForTests = true
            let engine = PostToolEmptyExhaustionChatEngine()
            session.chatEngineFactory = { _ in engine }

            session.send("Research the three repositories and finish every checklist item.")

            try await waitUntilAsync(timeout: Self.asyncTimeout) {
                await engine.isWaitingOnFirstEmptyResponse
            }

            // Queue a real warm-up while the model step is suspended. The
            // `.emptyResponseExhausted` lifecycle must cancel it during cleanup;
            // otherwise it fires after the failed tool run and can own the solo
            // generation lease behind the user's next send.
            let warmupProbe = IncomingWarmupRecordingEngine()
            session.warmupController.scheduleWarmup(
                session: IncomingWarmupSession(engine: warmupProbe),
                debounce: .milliseconds(250)
            )
            await engine.releaseEmptyResponses()

            try await waitUntil(timeout: Self.asyncTimeout) {
                session.isStreaming == false
            }
            try await Task.sleep(for: .milliseconds(400))

            #expect(await engine.regularRequestCount == 4)
            #expect(await engine.exposedToolNames.allSatisfy { $0.contains("todo") })
            #expect(session.lastStreamError == AgentToolLoop.emptyToolTaskFallback)
            #expect(
                session.turns.last(where: { $0.role == .assistant })?.content
                    == AgentToolLoop.emptyToolTaskFallback
            )
            // This is the ChatSession completion/indexing marker. Failed runs
            // must never publish one for auto-speak or downstream completion
            // consumers, and the queued completed-transcript warm-up must not run.
            #expect(session.lastCompletedAssistantTurnId == nil)
            #expect(await warmupProbe.requestCount == 0)
            #expect(session.isSendActiveForComposer == false)
        }
    }

    @Test
    func send_retriesReasoningOnlyAgentStepOnceInFreshExcludedTurn() async throws {
        try await ChatHistoryTestStorage.run {
            enableDefaultAgentTools(warmModelsOnLoad: false)

            let session = ChatSession()
            session.selectedModel = "chat-session-reasoning-retry-test-model"
            session.forceChatEngineRouteForTests = true
            let engine = ReasoningRetryChatEngine()
            session.chatEngineFactory = { _ in engine }

            session.send("Research the repositories with the available tools, then answer.")

            // `send` starts through an async pre-send handshake. Waiting only
            // for `isStreaming == false` can succeed before that handshake has
            // begun, producing a zero-length snapshot array and hiding the
            // behavior under an index crash.
            try await waitUntilAsync(timeout: Self.asyncTimeout) {
                await engine.requestSnapshots.isEmpty == false
            }
            try await waitUntil(timeout: Self.asyncTimeout) {
                session.isStreaming == false && session.isSendActiveForComposer == false
            }

            let snapshots = await engine.requestSnapshots
            let completedSnapshots = try #require(snapshots.count == 3 ? snapshots : nil)
            #expect(completedSnapshots.allSatisfy { $0.toolNames.contains("todo") })
            // Request 1 performs real structured tool work. Request 2 then
            // stops with an unclosed reasoning-only turn, and request 3 is the
            // one bounded replay. That replay receives the exact pre-attempt
            // model-visible history; the abandoned reasoning turn remains
            // UI-visible but is not fed back to the model.
            #expect(completedSnapshots[1].encodedMessages == completedSnapshots[2].encodedMessages)
            #expect(completedSnapshots[1].idempotencyKey != completedSnapshots[2].idempotencyKey)
            #expect(completedSnapshots[1].idempotencyKey?.contains(":r0-") == true)
            #expect(completedSnapshots[2].idempotencyKey?.contains(":r1-") == true)

            let assistantTurns = session.turns.filter { $0.role == .assistant }
            #expect(assistantTurns.count == 3)
            let abandoned = try #require(
                assistantTurns.first(where: { $0.modelContextExcluded })
            )
            let completed = try #require(assistantTurns.last)
            #expect(abandoned.id != completed.id)
            #expect(abandoned.contentIsBlank)
            #expect(abandoned.thinking == "I need to inspect the repositories before answering.")
            #expect(abandoned.modelContextExcluded)
            #expect(completed.content == "The repository review is complete.")
            #expect(completed.thinkingIsBlank)
            #expect(completed.modelContextExcluded == false)
            #expect(session.lastStreamError == nil)
            #expect(session.lastCompletedAssistantTurnId == completed.id)
            #expect(session.isSendActiveForComposer == false)
        }
    }
}

private actor IgnoringCancellationChatEngine: ChatEngineProtocol {
    func streamChat(request _: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        try? await Task.sleep(for: .milliseconds(150))
        return AsyncThrowingStream { continuation in
            continuation.yield("late result")
            continuation.finish()
        }
    }

    func completeChat(request _: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw NSError(domain: "ChatSessionStopTests", code: 1)
    }
}

private actor CancellationObservingChatEngine: ChatEngineProtocol {
    private(set) var started = false
    private(set) var cancelled = false

    func streamChat(request _: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        started = true
        do {
            try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
            cancelled = true
            throw CancellationError()
        }
        return AsyncThrowingStream { continuation in
            continuation.yield("unexpected")
            continuation.finish()
        }
    }

    func completeChat(request _: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw NSError(domain: "ChatSessionStopTests", code: 4)
    }
}

private actor ReasoningOnlyChatEngine: ChatEngineProtocol {
    private(set) var streamRequestCount = 0

    func streamChat(request _: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        streamRequestCount += 1
        return AsyncThrowingStream { continuation in
            continuation.yield(StreamingReasoningHint.encode("The user is straightforward greeting"))
            continuation.yield(StreamingStatsHint.encode(tokenCount: 0, tokensPerSecond: 0, unclosedReasoning: true))
            continuation.finish()
        }
    }

    func completeChat(request _: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw NSError(domain: "ChatSessionStopTests", code: 2)
    }
}

private actor PostToolEmptyExhaustionChatEngine: ChatEngineProtocol {
    private(set) var regularRequestCount = 0
    private(set) var exposedToolNames: [[String]] = []
    private(set) var isWaitingOnFirstEmptyResponse = false
    private var emptyResponseContinuation: CheckedContinuation<Void, Never>?

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        if request.warmupPrefill == true {
            return AsyncThrowingStream { $0.finish() }
        }

        regularRequestCount += 1
        exposedToolNames.append(request.tools?.map(\.function.name) ?? [])

        if regularRequestCount == 1 {
            return AsyncThrowingStream { continuation in
                continuation.finish(
                    throwing: ServiceToolInvocation(
                        toolName: "todo",
                        jsonArguments:
                            #"{"markdown":"- [ ] Inspect OsaurusAI\n- [ ] Inspect JANGQ-AI"}"#,
                        toolCallId: "call_todo"
                    )
                )
            }
        }

        if regularRequestCount == 2 {
            isWaitingOnFirstEmptyResponse = true
            await withCheckedContinuation { emptyResponseContinuation = $0 }
            isWaitingOnFirstEmptyResponse = false
        }
        return AsyncThrowingStream { $0.finish() }
    }

    func releaseEmptyResponses() {
        emptyResponseContinuation?.resume()
        emptyResponseContinuation = nil
    }

    func completeChat(request _: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw NSError(domain: "ChatSessionStopTests", code: 8)
    }
}

private struct ChatRequestSnapshot: Sendable, Equatable {
    let encodedMessages: Data
    let toolNames: [String]
    let idempotencyKey: String?
}

private actor ReasoningRetryChatEngine: ChatEngineProtocol {
    private(set) var requestSnapshots: [ChatRequestSnapshot] = []

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        let messageEncoder = JSONEncoder()
        messageEncoder.outputFormatting = [.sortedKeys]
        requestSnapshots.append(
            ChatRequestSnapshot(
                encodedMessages: (try? messageEncoder.encode(request.messages)) ?? Data(),
                toolNames: request.tools?.map(\.function.name) ?? [],
                idempotencyKey: request.idempotencyKey
            )
        )
        let requestNumber = requestSnapshots.count
        if requestNumber == 1 {
            return AsyncThrowingStream { continuation in
                continuation.finish(
                    throwing: ServiceToolInvocation(
                        toolName: "todo",
                        jsonArguments:
                            #"{"markdown":"- [x] Inspect the available repository metadata"}"#,
                        toolCallId: "call_completed_todo"
                    )
                )
            }
        }
        return AsyncThrowingStream { continuation in
            if requestNumber == 2 {
                continuation.yield(
                    StreamingReasoningHint.encode(
                        "I need to inspect the repositories before answering."
                    )
                )
                continuation.yield(
                    StreamingStatsHint.encode(
                        tokenCount: 12,
                        tokensPerSecond: 10,
                        unclosedReasoning: true,
                        stopReason: "stop"
                    )
                )
            } else {
                continuation.yield("The repository review is complete.")
                continuation.yield(
                    StreamingStatsHint.encode(
                        tokenCount: 6,
                        tokensPerSecond: 10,
                        stopReason: "stop"
                    )
                )
            }
            continuation.finish()
        }
    }

    func completeChat(request _: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw NSError(domain: "ChatSessionStopTests", code: 9)
    }
}

/// Suspends a model-selection switch and deliberately ignores task
/// cancellation until the test releases it. This reproduces the production
/// race where a pre-send handshake can outlive Stop/reset/session load.
private actor IgnoringCancellationHandshakeGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor PreSendHandshakeRecordingEngine: ChatEngineProtocol {
    private(set) var regularRequestCount = 0
    private(set) var warmupRequestCount = 0

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        if request.warmupPrefill == true {
            warmupRequestCount += 1
        } else {
            regularRequestCount += 1
        }
        return AsyncThrowingStream { continuation in
            continuation.yield("unexpected stale dispatch")
            continuation.finish()
        }
    }

    func completeChat(request _: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw NSError(domain: "ChatSessionStopTests", code: 5)
    }
}

@MainActor
private final class IncomingWarmupSession: ChatWarmupSessionContext {
    let selectedModel: String? = "incoming-warmup-model"
    let selectedModelIsLocal = true
    let isRemoteAgentTarget = false
    let isStreaming = false
    private let engine: any ChatEngineProtocol

    init(engine: any ChatEngineProtocol) {
        self.engine = engine
    }

    func isImageGenerationModel(_: String?) -> Bool { false }

    func makeWarmupPayload() async -> ChatWarmupPayload? {
        ChatWarmupPayload(
            model: "incoming-warmup-model",
            messages: [ChatMessage(role: "system", content: "incoming chat prefix")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "incoming-warmup-model|incoming-chat-prefix"
        )
    }

    func makeWarmupEngine() -> ChatEngineProtocol { engine }
}

private actor CancellationIgnoringWarmupEngine: ChatEngineProtocol {
    private let gate: IgnoringCancellationHandshakeGate
    private(set) var requestCount = 0

    init(gate: IgnoringCancellationHandshakeGate) {
        self.gate = gate
    }

    func streamChat(request _: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        requestCount += 1
        // `withCheckedContinuation` does not unwind merely because the caller
        // task is cancelled. This models an engine setup / stream-drain boundary
        // that holds its generation lease until the runtime itself returns.
        await gate.wait()
        return AsyncThrowingStream { $0.finish() }
    }

    func completeChat(request _: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw NSError(domain: "ChatSessionStopTests", code: 7)
    }
}

private actor IncomingWarmupRecordingEngine: ChatEngineProtocol {
    private(set) var requestCount = 0

    func streamChat(request _: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        requestCount += 1
        return AsyncThrowingStream { $0.finish() }
    }

    func completeChat(request _: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw NSError(domain: "ChatSessionStopTests", code: 6)
    }
}

private func waitUntil(
    timeout: Duration,
    _ predicate: @MainActor @escaping () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw NSError(domain: "ChatSessionStopTests", code: 3)
}

@MainActor
private func waitUntilAsync(
    timeout: Duration,
    _ predicate: @MainActor @escaping () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw NSError(domain: "ChatSessionStopTests", code: 5)
}
