import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct DelegatedTaskIntentTests {
    private actor Capture {
        struct Entry: Sendable {
            let messages: [ChatMessage]
            let choice: ToolChoiceOption?
            let tools: [OsaurusCore.Tool]
        }
        private(set) var entries: [Entry] = []
        func record(_ entry: Entry) { entries.append(entry) }
    }

    private struct Service: ResponsesGenerationService {
        let capture: Capture
        var id: String { "task-intent-fixture" }
        func isAvailable() -> Bool { true }
        func handles(requestedModel: String?) -> Bool { requestedModel == id }
        func generateOneShot(messages: [ChatMessage], parameters: GenerationParameters, requestedModel: String?) async throws -> String {
            throw NSError(domain: "unexpected-legacy", code: 1)
        }
        func streamDeltas(messages: [ChatMessage], parameters: GenerationParameters, requestedModel: String?, stopSequences: [String]) async throws -> AsyncThrowingStream<String, Error> {
            throw NSError(domain: "unexpected-legacy", code: 2)
        }
        func streamResponses(messages: [ChatMessage], parameters: GenerationParameters, stopSequences: [String], tools: [OsaurusCore.Tool], toolChoice: ToolChoiceOption?, requestedModel: String?) async throws -> AsyncThrowingStream<ResponsesGenerationEvent, Error> {
            await capture.record(.init(messages: messages, choice: toolChoice, tools: tools))
            return AsyncThrowingStream { continuation in
                continuation.yield(.outputTextDelta("BG_TOKEN_9"))
                continuation.yield(.responseCompleted(.init(
                    responseID: "resp_task_intent", status: .completed, functionCalls: [],
                    tokenCount: 7, tokensPerSecond: 20, unclosedReasoning: false,
                    stopReason: "stop", promptTokensPerSecond: nil, mtp: nil)))
                continuation.yield(.drained)
                continuation.finish()
            }
        }
    }

    private func tool(_ name: String) -> OsaurusCore.Tool {
        OsaurusCore.Tool(type: "function", function: .init(name: name, description: nil, parameters: nil))
    }

    @Test(arguments: [false, true], [false, true])
    func taskProvenanceSurvivesFreshAndContinuedDeliveryContracts(remote: Bool, resuming: Bool) throws {
        let input = " \nReturn exactly BG_TOKEN_9.\t "
        let intent = ChatTaskIntent(userText: input)
        let prompt = AgentDelegationDispatcher.delegatedPrompt(input: input, remote: remote, resuming: resuming)
        let request = DispatchRequest(prompt: prompt, source: .delegation, taskIntent: intent)
        #expect(request.prompt == prompt)
        #expect(request.taskIntent?.userText == input)
        #expect(prompt.hasPrefix(input))
        let tools = [tool("share_artifact"), tool("file_write"), tool("complete")]
        #expect(isAuto(ChatToolChoicePolicy.resolve(tools: tools, taskIntent: intent, attempt: 1)))
        // An actual request to invoke share_artifact remains required. No
        // stripping of tool-name strings or relaxation of tool-choice policy.
        #expect(isRequired(ChatToolChoicePolicy.resolve(
            tools: tools, taskIntent: .init(userText: " \nCall share_artifact with the result.\t"), attempt: 1)))
        #expect(isAuto(ChatToolChoicePolicy.resolve(
            tools: tools, taskIntent: .init(userText: "Call share_artifact."), attempt: 2)))
    }

    @Test func actualExecutionContextKeepsPromptAndResolvesOnlyThisTurnsTask() async throws {
        try await ChatHistoryTestStorage.run {
            var config = ChatConfigurationStore.load()
            config.warmModelsOnLoad = false
            config.autoGenerateChatTitles = false
            ChatConfigurationStore.save(config)
            // The Default agent is the orchestrator and intentionally excludes
            // share_artifact. The observed failure was a persisted worker.
            let worker = Agent(name: "Task intent worker \(UUID())",
                systemPrompt: "Return the requested result.", defaultModel: "task-intent-fixture",
                autonomousExec: .init(enabled: false), toolSelectionMode: .manual,
                manualToolNames: ["share_artifact"], toolsEnabled: true, memoryEnabled: false)
            AgentStore.save(worker)
            AgentManager.shared.refresh()
            defer { AgentStore.delete(id: worker.id); AgentManager.shared.refresh() }

            let capture = Capture()
            let engine = ChatEngine(services: [Service(capture: capture)],
                installedModelsProvider: { [] }, remoteServicesProvider: { [] })
            let context = ExecutionContext(agentId: worker.id, source: .delegation)
            let session = context.chatSession
            session.selectedModel = "task-intent-fixture"
            session.forceChatEngineRouteForTests = true
            // The shared storage fixture disables tools for ordinary lifecycle
            // tests. This regression intentionally needs the real callable
            // share_artifact schema to exercise the production choice policy.
            session.toolsDisabledForTestingOverride = false
            session.chatEngineFactory = { _ in engine }
            let input = " \nReturn exactly BG_TOKEN_9.\t "
            let prompt = AgentDelegationDispatcher.delegatedPrompt(input: input)
            let workerContext = await ChatExecutionContext.$currentSessionSource.withValue(.delegation) {
                await SystemPromptComposer.composeChatContext(agentId: worker.id, executionMode: .none,
                    model: "task-intent-fixture", query: prompt,
                    messages: [.init(role: "user", content: prompt)])
            }
            // Establish the actual callable schema before dispatch, rather
            // than allowing an empty toolset to make the choice assertions vacuous.
            try #require(workerContext.tools.contains { $0.function.name == "share_artifact" })
            #expect(isRequired(ChatToolChoicePolicy.resolve(tools: workerContext.tools,
                userText: prompt, attempt: 1)), "The app-added wrapper would cause the original false requirement")
            await context.start(prompt: prompt, taskIntent: .init(userText: input))
            let sendTask1 = try #require(session.currentSendTaskForTesting)
            await sendTask1.value
            var entries = await capture.entries
            #expect(entries.count == 1)
            let first = try #require(entries.first)
            #expect(first.tools.contains { $0.function.name == "share_artifact" })
            #expect(isAuto(first.choice))
            #expect(first.messages.last(where: { $0.role == "user" })?.content?.contains(prompt.trimmingCharacters(in: .whitespacesAndNewlines)) == true)
            #expect(session.lastStreamError == nil)
            #expect(session.turns.last?.content == "BG_TOKEN_9")

            // A delayed wrapped send must retain its own original task;
            // losing the queue carrier would infer required from the wrapper.
            let queuedPrompt = AgentDelegationDispatcher.delegatedPrompt(input: "Return exactly BG_TOKEN_9.", resuming: true)
            session.queuedSend = .init(text: queuedPrompt, attachments: [], oneOffSkillId: nil,
                taskIntent: .init(userText: "Return exactly BG_TOKEN_9."))
            session.sendNowInterrupting()
            let sendTask2 = try #require(session.currentSendTaskForTesting)
            await sendTask2.value
            entries = await capture.entries
            #expect(entries.count == 2)
            let queuedEntry = try #require(entries.last)
            #expect(isAuto(queuedEntry.choice))
            #expect(session.lastStreamError == nil)
            #expect(entries.last?.messages.last(where: { $0.role == "user" })?.content?.contains(queuedPrompt) == true)

            // A follow-up does not inherit the previous original task. The
            // real canonical required-completion validator must reject this
            // service's plain answer to a genuine explicit tool request.
            session.send("Call share_artifact with the result.")
            let sendTask3 = try #require(session.currentSendTaskForTesting)
            await sendTask3.value
            entries = await capture.entries
            #expect(entries.count == 3)
            let explicit = try #require(entries.last)
            #expect(isRequired(explicit.choice))
            #expect(explicit.messages.contains { $0.role == "assistant" && $0.content == "BG_TOKEN_9" })
            #expect(session.lastStreamError?.contains("required tool call") == true)
            #expect(!session.isStreaming)
        }
    }

    private func isAuto(_ choice: ToolChoiceOption?) -> Bool {
        if case .auto = choice { return true }
        return false
    }
    private func isRequired(_ choice: ToolChoiceOption?) -> Bool {
        if case .required = choice { return true }
        return false
    }
}
