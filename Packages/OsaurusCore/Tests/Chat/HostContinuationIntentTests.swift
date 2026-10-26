import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct HostContinuationIntentTests {
    private nonisolated static let modelID = "fixture/report-parent"

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
        var calls: [ResponsesFunctionCall] = []
        var id: String { HostContinuationIntentTests.modelID }
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
                continuation.yield(.outputTextDelta("The helper finished: BG_TOKEN_9."))
                continuation.yield(.responseCompleted(.init(responseID: "resp_report_" + UUID().uuidString,
                    status: .completed, functionCalls: calls, tokenCount: 9, tokensPerSecond: 20,
                    unclosedReasoning: false, stopReason: calls.isEmpty ? "stop" : "tool_calls", promptTokensPerSecond: nil, mtp: nil)))
                continuation.yield(.drained)
                continuation.finish()
            }
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

    @Test func hostContinuationHasNoSyntheticUserTextAndKeepsToolsAutomatic() {
        let tool = OsaurusCore.Tool(type: "function", function: .init(name: "spawn_agent", description: nil, parameters: nil))
        #expect(ChatTaskIntent.hostContinuation.userText == nil)
        #expect(isAuto(ChatToolChoicePolicy.resolve(tools: [tool], taskIntent: .hostContinuation, attempt: 1)))
        #expect(ChatToolChoicePolicy.resolve(tools: [], taskIntent: .hostContinuation, attempt: 1) == nil)
        #expect(isRequired(ChatToolChoicePolicy.resolve(tools: [tool],
            taskIntent: .init(userText: "Call spawn_agent with the task."), attempt: 1)))
    }

    @Test func hostContinuationStillAllowsAnActualModelToolBatch() async throws {
        let capture = Capture()
        let tool = OsaurusCore.Tool(type: "function", function: .init(name: "lookup", description: nil, parameters: nil))
        let call = ResponsesFunctionCall(id: "fc_lookup", callID: "call_lookup", name: "lookup", arguments: "{}")
        let engine = ChatEngine(services: [Service(capture: capture, calls: [call])],
            installedModelsProvider: { [] }, remoteServicesProvider: { [] })
        var request = ResponsesInferenceRequest(model: Self.modelID,
            input: [.init(role: "user", content: "[Helper report] lookup finished.")])
        request.tools = [tool]
        request.toolChoice = ChatToolChoicePolicy.resolve(tools: [tool], taskIntent: .hostContinuation, attempt: 1)
        let result = try await engine.completeResponse(request: request)
        #expect(result.completion.functionCalls.map(\.callID) == ["call_lookup"])
        #expect(result.completion.dispatchableFunctionCalls.map(\.name) == ["lookup"])
        let entries = await capture.entries
        #expect(entries.count == 1)
        #expect(isAuto(entries.first?.choice))
    }

    @Test func actualReportBackCallbackAndQueuedReportDoNotBecomeUserToolRequests() async throws {
        try await ChatHistoryTestStorage.run {
            try await DynamicCatalogTestLock.shared.run {
                let lease = await acquireSubagentStoreSandbox("host-report-intent")
                defer { lease.release() }
                let previousScan = ModelManager.scanLocalModelsOverrideForTests
                let previousExternal = ExternalModelLocator.testRootsOverride
                ExternalModelLocator.testRootsOverride = []
                ExternalModelLocator.invalidateInMemory()
                _ = ExternalModelLocator.rescan()
                // Only model-availability metadata is supplied. The real
                // canonical engine below invokes the typed service, not MLX.
                ModelManager.scanLocalModelsOverrideForTests = { _ in [
                    MLXModel(id: Self.modelID, name: "Report parent fixture", description: "Runnable metadata fixture",
                        downloadURL: "https://example.invalid/report-parent")
                ] }
                ModelManager.invalidateLocalModelsCache()
                _ = await ModelManager.discoverLocalModelsOffMain()
                defer {
                    ModelManager.scanLocalModelsOverrideForTests = previousScan
                    ExternalModelLocator.testRootsOverride = previousExternal
                    ExternalModelLocator.invalidateInMemory()
                    ModelManager.invalidateLocalModelsCache()
                }
                let worker = Agent(name: "Report worker \(UUID())", description: "Returns a bounded validation token.",
                    defaultModel: Self.modelID, autonomousExec: .init(enabled: false), memoryEnabled: false)
                AgentStore.save(worker)
                AgentManager.shared.refresh()
                defer { AgentStore.delete(id: worker.id); AgentManager.shared.refresh() }
                SubagentConfigurationStore.save(.init(spawnableAgentIDs: [worker.id]))
                var config = ChatConfigurationStore.load()
                config.warmModelsOnLoad = false
                config.autoGenerateChatTitles = false
                ChatConfigurationStore.save(config)
                DefaultAgentConfigurationStore.save(.init(defaultModel: Self.modelID,
                    autonomousExec: .init(enabled: false), toolSelectionMode: .auto))
                DefaultAgentConfigurationStore.resetCacheForTests()
                AgentManager.shared.refresh()

                let capture = Capture()
                let engine = ChatEngine(services: [Service(capture: capture)],
                    installedModelsProvider: { [] }, remoteServicesProvider: { [] })
                let session = ChatSession()
                session.selectedModel = Self.modelID
                session.forceChatEngineRouteForTests = true
                session.toolsDisabledForTestingOverride = false
                session.chatEngineFactory = { _ in engine }
                let workerSessionID = UUID()
                let completed = ToolEnvelope.success(tool: "spawn_agent", result: [
                    "kind": "spawn_result", "session_id": workerSessionID.uuidString, "summary": "BG_TOKEN_9"])
                let report = SubagentReportBack.message(title: "Delegated to Responses Proof Worker", success: true,
                    summary: "BG_TOKEN_9", completedEnvelope: completed)
                let composed = await SystemPromptComposer.composeChatContext(agentId: Agent.defaultId,
                    executionMode: .none, model: Self.modelID, query: report)
                try #require(composed.tools.contains { $0.function.name == "spawn_agent" },
                    "The real parent must offer the tool named in the host report")
                #expect(isRequired(ChatToolChoicePolicy.resolve(tools: composed.tools,
                    userText: report, attempt: 1)), "Control: treating this host report as a user request reproduces the false requirement")
                let originalTask = "Delegate a bounded task and acknowledge the running worker."
                session.turns = [ChatTurn(role: .user, content: originalTask),
                    ChatTurn(role: .assistant, content: "The worker is running under session_id \(workerSessionID).")]
                await SubagentReportBack.deliver(title: "Delegated to Responses Proof Worker", success: true,
                    summary: "BG_TOKEN_9", completedEnvelope: completed, to: WeakChatSessionBox(session))
                if let task = session.currentSendTaskForTesting { await task.value }
                var entries = await capture.entries
                try #require(entries.count == 1)
                #expect(entries[0].tools.contains { $0.function.name == "spawn_agent" })
                #expect(isAuto(entries[0].choice))
                #expect(entries[0].messages.last(where: { $0.role == "user" })?.content?.hasSuffix(report) == true)
                #expect(entries[0].messages.contains { $0.role == "user" && $0.content == originalTask })
                #expect(session.lastStreamError == nil)
                #expect(session.turns.last?.content == "The helper finished: BG_TOKEN_9.")

                // A held/queued callback must retain its explicit origin when
                // the regular send path resumes it later.
                session.queuedSend = .init(text: report, attachments: [], oneOffSkillId: nil,
                    taskIntent: .hostContinuation)
                session.sendNowInterrupting()
                if let task = session.currentSendTaskForTesting { await task.value }
                entries = await capture.entries
                try #require(entries.count == 2)
                #expect(isAuto(entries[1].choice))
                #expect(entries[1].messages.last(where: { $0.role == "user" })?.content?.hasSuffix(report) == true)
                #expect(session.lastStreamError == nil)

                // Host provenance cannot stick to a later genuine user task.
                // This same real engine must still reject a plain answer to
                // an explicitly required tool call.
                session.send("Call spawn_agent with another bounded task.")
                if let task = session.currentSendTaskForTesting { await task.value }
                entries = await capture.entries
                try #require(entries.count == 3)
                #expect(isRequired(entries[2].choice))
                #expect(session.lastStreamError?.contains("required tool call") == true)
                #expect(!session.isStreaming)
            }
        }
    }
}
