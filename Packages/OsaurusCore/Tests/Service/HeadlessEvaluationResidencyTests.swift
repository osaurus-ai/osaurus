import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite("Headless evaluation residency provenance", .serialized, .timeLimit(.minutes(1)))
struct HeadlessEvaluationResidencyTests {
    private actor Capture {
        var parameters: [GenerationParameters] = []
        func record(_ value: GenerationParameters) { parameters.append(value) }
    }

    private struct Service: ResponsesGenerationService {
        let capture: Capture
        var id: String { "evaluation-residency-fixture" }
        func isAvailable() -> Bool { true }
        func handles(requestedModel: String?) -> Bool { requestedModel == id }
        func generateOneShot(messages: [ChatMessage], parameters: GenerationParameters, requestedModel: String?) async throws -> String {
            throw NSError(domain: "unexpected-legacy", code: 1)
        }
        func streamDeltas(messages: [ChatMessage], parameters: GenerationParameters, requestedModel: String?, stopSequences: [String]) async throws -> AsyncThrowingStream<String, Error> {
            throw NSError(domain: "unexpected-legacy", code: 2)
        }
        func streamResponses(messages: [ChatMessage], parameters: GenerationParameters, stopSequences: [String], tools: [OsaurusCore.Tool], toolChoice: ToolChoiceOption?, requestedModel: String?) async throws -> AsyncThrowingStream<ResponsesGenerationEvent, Error> {
            await capture.record(parameters)
            return AsyncThrowingStream { continuation in
                continuation.yield(.outputTextDelta("ok"))
                continuation.yield(.responseCompleted(.init(
                    responseID: "resp_evaluation_fixture", status: .completed, functionCalls: [],
                    tokenCount: 1, tokensPerSecond: 20, unclosedReasoning: false,
                    stopReason: "stop", promptTokensPerSecond: nil, mtp: nil)))
                continuation.yield(.drained)
                continuation.finish()
            }
        }
    }

    @Test(arguments: RequestSource.allCases, [false, true])
    func configuredIdlePolicyAndClosedUIStayDistinct(source: RequestSource, referenced: Bool) {
        let actual = ModelRuntime.resolvedIdleResidencyPolicy(
            configured: .afterSeconds(900), source: source,
            referencedByChat: referenced, hasHandoffOwner: false)
        #expect(actual == (source == .chatUI && !referenced ? .immediately : .afterSeconds(900)))
        for configured in [ModelIdleResidencyPolicy.immediately, .never] {
            #expect(ModelRuntime.resolvedIdleResidencyPolicy(
                configured: configured, source: source,
                referencedByChat: referenced, hasHandoffOwner: false) == configured)
        }
        #expect(ModelRuntime.resolvedIdleResidencyPolicy(
            configured: .afterSeconds(900), source: source,
            referencedByChat: referenced, hasHandoffOwner: true) == .never)
    }

    @Test func originIsScopedAndProtectedSourcesAreNotReclassified() {
        #expect(AgentLoopEvaluator.inferenceSource == .evaluation)
        #expect(ChatExecutionContext.inferenceSourceOverride == nil)
        ChatExecutionContext.$inferenceSourceOverride.withValue(.evaluation) {
            #expect(SessionSource.chat.inferenceSource == .evaluation)
            #expect(SessionSource.delegation.inferenceSource == .evaluation)
            #expect(SessionSource.imported.inferenceSource == .evaluation)
            #expect(SessionSource.http.inferenceSource == .httpAPI)
            #expect(SessionSource.plugin.inferenceSource == .plugin)
            #expect(SessionSource.schedule.inferenceSource == .schedule)
            #expect(SessionSource.watcher.inferenceSource == .watcher)
            #expect(SessionSource.selfSchedule.inferenceSource == .selfSchedule)
        }
        #expect(SessionSource.chat.inferenceSource == .chatUI)
        #expect(SessionSource.delegation.inferenceSource == .chatUI)
        #expect(ChatExecutionContext.inferenceSourceOverride == nil)
        #expect(ModelRuntime.isChatOwnedResidencySource(.evaluation))
        for protected in [RequestSource.httpAPI, .plugin, .p2p, .scheduled, .schedule, .watcher, .selfSchedule] {
            #expect(!ModelRuntime.isChatOwnedResidencySource(protected))
            #expect(ModelRuntime.resolvedResidencySource(
                existing: protected, incoming: .evaluation, preserveExisting: true) == protected)
        }
        #expect(FeatureTelemetry.sourceToken(.evaluation) == "evaluation")
        #expect(FeatureTelemetry.sourceToken(.chatUI) == "chat_ui")
        #expect(RequestSource.evaluation.rawValue == "Evaluation")
        #expect(ChatEngine.shouldLogInferenceToInsights(source: .evaluation, warmupPrefill: false))
        #expect(!ChatEngine.shouldLogInferenceToInsights(source: .evaluation, warmupPrefill: true))
    }

    private func prepared(source: RequestSource, explicit: Bool) async throws -> GenerationParameters {
        let capture = Capture()
        let engine = ChatEngine(
            services: [Service(capture: capture)], installedModelsProvider: { [] },
            remoteServicesProvider: { [] },
            agentModelOptionsProvider: { _ in ["originFixture": .string("unchanged")] },
            source: source)
        var request = ResponsesInferenceRequest(
            model: "evaluation-residency-fixture", input: [.init(role: "user", content: "Reply ok.")])
        request.context.isAgentRequest = true
        request.context.samplingParametersAreImplicit = !explicit
        request.sessionID = "evaluation-parameter-parity"
        if explicit {
            request.generation.temperature = 0.7
            request.generation.topP = 0.83
            request.generation.topK = 17
            request.generation.minP = 0.02
            request.generation.maxOutputTokens = 123
            request.generation.frequencyPenalty = 0.2
            request.generation.presencePenalty = 0.3
            request.generation.seed = 42
        }
        for try await _ in try await engine.streamResponses(request: request) {}
        let values = await capture.parameters
        #expect(values.count == 1)
        return try #require(values.first)
    }

    @Test(arguments: [false, true])
    func nativePreparationPreservesUIParametersExceptProvenance(explicit: Bool) async throws {
        let ui = try await prepared(source: .chatUI, explicit: explicit)
        let evaluation = try await prepared(source: AgentLoopEvaluator.inferenceSource, explicit: explicit)
        #expect(ui.requestSource == .chatUI)
        #expect(evaluation.requestSource == .evaluation)
        #expect(evaluation.activitySource == .evaluation)
        #expect(ui.modelOptions["originFixture"]?.stringValue == "unchanged")
        #expect(evaluation.modelOptions == ui.modelOptions)
        #expect(evaluation.temperature == ui.temperature)
        #expect(evaluation.topPOverride == ui.topPOverride)
        #expect(evaluation.topKOverride == ui.topKOverride)
        #expect(evaluation.minPOverride == ui.minPOverride)
        #expect(evaluation.maxTokens == ui.maxTokens)
        #expect(evaluation.maxTokensExplicit == ui.maxTokensExplicit)
        #expect(evaluation.frequencyPenalty == ui.frequencyPenalty)
        #expect(evaluation.presencePenalty == ui.presencePenalty)
        #expect(evaluation.repetitionPenalty == ui.repetitionPenalty)
        #expect(evaluation.seed == ui.seed)
        #expect(evaluation.samplingParametersAreImplicit == ui.samplingParametersAreImplicit)
        #expect(evaluation.sessionId == ui.sessionId)
        #expect(evaluation.loadIntent == ui.loadIntent)
        #expect(evaluation.collectCompleteToolResponse == ui.collectCompleteToolResponse)
        #expect(evaluation.preserveExistingResidencyOwner == ui.preserveExistingResidencyOwner)
        #expect(evaluation.admissionPositionLimit == ui.admissionPositionLimit)
        if !explicit {
            #expect(evaluation.temperature == nil)
            #expect(evaluation.topPOverride == nil)
            #expect(evaluation.topKOverride == nil)
            #expect(!evaluation.maxTokensExplicit)
        }
        // A worker engine created before dispatch still receives the current
        // evaluation owner, without overwriting persisted delegation origin.
        let inherited = try await ChatExecutionContext.$inferenceSourceOverride.withValue(.evaluation) {
            try await prepared(source: .chatUI, explicit: explicit)
        }
        #expect(inherited.requestSource == .evaluation)
        #expect(inherited.modelOptions == evaluation.modelOptions)
    }

    @Test(arguments: [RequestSource.httpAPI, .plugin, .scheduled, .schedule, .watcher, .agent])
    func evaluationOriginCannotStealProtectedDispatchOrUIOptions(source: RequestSource) async throws {
        let parameters = try await ChatExecutionContext.$inferenceSourceOverride.withValue(.evaluation) {
            try await prepared(source: source, explicit: false)
        }
        #expect(parameters.requestSource == source)
        #expect(parameters.activitySource == source)
        #expect(parameters.modelOptions["originFixture"] == nil)
        #expect(parameters.temperature == nil)
        #expect(parameters.topPOverride == nil)
        #expect(parameters.topKOverride == nil)
    }

    @Test func sameAndDifferentModelHandoffsRetainEvaluationOwnership() throws {
        try ChatExecutionContext.$inferenceSourceOverride.withValue(.evaluation) {
            let source = SessionSource.chat.inferenceSource
            let lease = ChatResidencyLease(
                unloadedModelNames: ["parent"], restoreModelNames: ["parent"], parentSource: source)
            #expect(lease.parentSource == .evaluation)
            #expect(ModelRuntime.isChatOwnedResidencySource(lease.parentSource))
            let same = try SubagentResidency.decidePlan(
                isLocal: true, modelName: "parent", residentChatModels: ["parent"],
                handoffEnabled: true, ramSafetyEnabled: true, requiredBytes: 100,
                idleWaitSeconds: 60, deniedMessage: "unused", invokingParentModelName: "parent")
            #expect(!same.shouldUnload)
            #expect(same.ramSafetyEnabled)
            let different = try SubagentResidency.decidePlan(
                isLocal: true, modelName: "child", residentChatModels: ["parent"],
                handoffEnabled: true, ramSafetyEnabled: true, requiredBytes: 100,
                idleWaitSeconds: 60, deniedMessage: "unused", invokingParentModelName: "parent")
            #expect(different.shouldUnload)
            // Same-model child completion and parent restoration both keep
            // the actual evaluation source, with no extra ModelLease held.
            let childSource = SessionSource.delegation.inferenceSource
            let afterChild = ModelRuntime.resolvedResidencySource(
                existing: source, incoming: childSource, preserveExisting: false)
            #expect(afterChild == .evaluation)
            #expect(ModelRuntime.resolvedIdleResidencyPolicy(
                configured: .afterSeconds(900), source: afterChild,
                referencedByChat: false, hasHandoffOwner: false) == .afterSeconds(900))
        }
    }

    @Test func realDispatchedSendAndQueuedContinuationCarryOnlyTheirOwnOrigin() async throws {
        try await ChatHistoryTestStorage.run {
            var config = ChatConfigurationStore.load()
            config.warmModelsOnLoad = false
            config.autoGenerateChatTitles = false
            config.generateFollowUpSuggestions = false
            ChatConfigurationStore.save(config)
            DefaultAgentConfigurationStore.save(.init(
                autonomousExec: nil, toolSelectionMode: .manual, manualToolNames: []))
            DefaultAgentConfigurationStore.resetCacheForTests()
            AgentManager.shared.refresh()
            let capture = Capture()
            let context = ExecutionContext(agentId: Agent.defaultId, source: .delegation)
            let session = context.chatSession
            session.selectedModel = "evaluation-residency-fixture"
            session.forceChatEngineRouteForTests = true
            session.chatEngineFactory = { source in
                ChatEngine(services: [Service(capture: capture)], installedModelsProvider: { [] },
                    remoteServicesProvider: { [] }, source: source)
            }
            var request = DispatchRequest(prompt: "Reply ok.", source: .delegation)
            request.inferenceSourceOverride = .evaluation
            await ChatExecutionContext.$inferenceSourceOverride.withValue(request.inferenceSourceOverride) {
                await context.start(prompt: request.prompt)
            }
            let sendTask1 = try #require(session.currentSendTaskForTesting)
            await sendTask1.value
            var values = await capture.parameters
            #expect(values.count == 1)
            #expect(values.first?.requestSource == .evaluation)
            #expect(session.source == .delegation)
            #expect(!session.isStreaming)
            session.queuedSend = .init(text: "Reply ok again.", attachments: [], oneOffSkillId: nil,
                inferenceSourceOverride: .evaluation)
            session.sendNowInterrupting()
            let sendTask2 = try #require(session.currentSendTaskForTesting)
            await sendTask2.value
            values = await capture.parameters
            #expect(values.count == 2)
            #expect(values.last?.requestSource == .evaluation)
            #expect(session.lastStreamError == nil)
            #expect(!session.isStreaming)
            // A later ordinary UI continuation is not stuck with the old
            // evaluation origin merely because its session once carried it.
            session.send("Reply ok once more.")
            let sendTask3 = try #require(session.currentSendTaskForTesting)
            await sendTask3.value
            values = await capture.parameters
            #expect(values.count == 3)
            #expect(values.last?.requestSource == .chatUI)
            #expect(session.lastStreamError == nil)
        }
    }
}
