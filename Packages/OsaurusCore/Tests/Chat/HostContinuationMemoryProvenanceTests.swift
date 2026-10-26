import Foundation
import Testing

@testable import OsaurusCore

/// A helper report delivered as `.hostContinuation` is host text, not user
/// words. In the bb10 native replay the report's own words recalled a stale
/// pinned fact (a completed task's instruction stored verbatim), froze it onto
/// the report as a fresh `[Memory]` block, and the parent re-ran that task
/// instead of summarizing the helper's result. Every earlier report had also
/// been buffered as a `userMessage`, which is how the distiller kept minting
/// "facts" about the delegation itself.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct HostContinuationMemoryProvenanceTests {
    private nonisolated static let modelID = "fixture/report-memory-parent"

    /// Exact pinned facts from the replay's memory DB (agent 0…01).
    private static let staleInstruction =
        "Use file_read to read probe.json in the working folder. Return its current value without modifying any file."
    private static let staleDelegationFact =
        "Delegate sent to Responses Proof Worker with specific instructions and BG_TOKEN_9 returned."

    private actor Capture {
        private(set) var messages: [[ChatMessage]] = []
        func record(_ batch: [ChatMessage]) { messages.append(batch) }
    }
    private struct Service: ResponsesGenerationService {
        let capture: Capture
        var id: String { HostContinuationMemoryProvenanceTests.modelID }
        func isAvailable() -> Bool { true }
        func handles(requestedModel: String?) -> Bool { requestedModel == id }
        func generateOneShot(messages: [ChatMessage], parameters: GenerationParameters, requestedModel: String?) async throws -> String {
            throw NSError(domain: "unexpected-legacy", code: 1)
        }
        func streamDeltas(messages: [ChatMessage], parameters: GenerationParameters, requestedModel: String?, stopSequences: [String]) async throws -> AsyncThrowingStream<String, Error> {
            throw NSError(domain: "unexpected-legacy", code: 2)
        }
        func streamResponses(messages: [ChatMessage], parameters: GenerationParameters, stopSequences: [String], tools: [OsaurusCore.Tool], toolChoice: ToolChoiceOption?, requestedModel: String?) async throws -> AsyncThrowingStream<ResponsesGenerationEvent, Error> {
            await capture.record(messages)
            return AsyncThrowingStream { continuation in
                continuation.yield(.outputTextDelta("The helper finished: BG_TOKEN_9."))
                continuation.yield(.responseCompleted(.init(responseID: "resp_report_memory_" + UUID().uuidString,
                    status: .completed, functionCalls: [], tokenCount: 9, tokensPerSecond: 20,
                    unclosedReasoning: false, stopReason: "stop", promptTokensPerSecond: nil, mtp: nil)))
                continuation.yield(.drained)
                continuation.finish()
            }
        }
    }

    private func seedStaleMemory() throws {
        MemoryConfigurationStore.invalidateCache()
        MemoryDatabase.shared.close()
        try MemoryDatabase.shared.openInMemory()
        var config = MemoryConfiguration.default
        config.enabled = true
        config.relevanceGateMode = .heuristic
        MemoryConfigurationStore.save(config)
        let agentKey = Agent.defaultId.uuidString
        try MemoryDatabase.shared.insertPinnedFact(
            PinnedFact(agentId: agentKey, content: Self.staleDelegationFact, salience: 0.8))
        try MemoryDatabase.shared.insertPinnedFact(
            PinnedFact(agentId: agentKey, content: Self.staleInstruction, salience: 0.8))
    }

    private func helperReport(workerSessionID: UUID) -> String {
        let completed = ToolEnvelope.success(tool: "spawn_agent", result: [
            "kind": "spawn_result", "session_id": workerSessionID.uuidString, "summary": "BG_TOKEN_9"])
        return SubagentReportBack.message(title: "Delegated to Responses Proof Worker", success: true,
            summary: "BG_TOKEN_9", completedEnvelope: completed)
    }

    /// Bounded wait. In a full-suite process an earlier warm-up can route a
    /// send through the async pre-send handshake, and run cleanup can trail
    /// the awaited run task, so neither "send returned" nor "task finished"
    /// means the session is idle.
    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0 ..< 400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    @Test func composerSkipsRecallOnlyWhenTheTurnIsHostAuthored() async throws {
        try await ChatHistoryTestStorage.run {
            try seedStaleMemory()
            defer {
                MemoryDatabase.shared.close()
                MemoryConfigurationStore.invalidateCache()
            }
            await MemoryContextAssembler.shared.invalidateCache()
            let report = helperReport(workerSessionID: UUID())

            // Control: recall keyed on the report's words reproduces the
            // replay's block, stale instruction included.
            let keyedOnReport = await SystemPromptComposer.composeChatContext(ComposeRequest(
                agentId: Agent.defaultId, executionMode: .none, model: Self.modelID,
                query: report, toolsDisabled: true))
            try #require(keyedOnReport.memorySection?.contains(Self.staleInstruction) == true,
                "Control: the fixture must recall the stale instruction from the report's own words")

            let hostAuthored = await SystemPromptComposer.composeChatContext(ComposeRequest(
                agentId: Agent.defaultId, executionMode: .none, model: Self.modelID,
                query: report, toolsDisabled: true, recallsMemory: false))
            #expect(hostAuthored.memorySection == nil)
        }
    }

    @Test func helperReportIsNeitherRecalledAgainstNorRecordedAsTheUser() async throws {
        try await ChatHistoryTestStorage.run {
            try await DynamicCatalogTestLock.shared.run {
                let lease = await acquireSubagentStoreSandbox("host-report-memory")
                defer { lease.release() }
                let previousScan = ModelManager.scanLocalModelsOverrideForTests
                let previousExternal = ExternalModelLocator.testRootsOverride
                ExternalModelLocator.testRootsOverride = []
                ExternalModelLocator.invalidateInMemory()
                _ = ExternalModelLocator.rescan()
                ModelManager.scanLocalModelsOverrideForTests = { _ in [
                    MLXModel(id: Self.modelID, name: "Report memory fixture", description: "Runnable metadata fixture",
                        downloadURL: "https://example.invalid/report-memory-parent")
                ] }
                ModelManager.invalidateLocalModelsCache()
                _ = await ModelManager.discoverLocalModelsOffMain()
                defer {
                    ModelManager.scanLocalModelsOverrideForTests = previousScan
                    ExternalModelLocator.testRootsOverride = previousExternal
                    ExternalModelLocator.invalidateInMemory()
                    ModelManager.invalidateLocalModelsCache()
                }
                DefaultAgentConfigurationStore.save(.init(defaultModel: Self.modelID,
                    autonomousExec: .init(enabled: false), toolSelectionMode: .auto))
                DefaultAgentConfigurationStore.resetCacheForTests()
                AgentManager.shared.refresh()

                try seedStaleMemory()
                defer {
                    MemoryDatabase.shared.close()
                    MemoryConfigurationStore.invalidateCache()
                }
                await MemoryContextAssembler.shared.invalidateCache()
                try #require(!AgentManager.shared.effectiveMemoryDisabled(for: Agent.defaultId))

                let capture = Capture()
                let engine = ChatEngine(services: [Service(capture: capture)],
                    installedModelsProvider: { [] }, remoteServicesProvider: { [] })
                let session = ChatSession()
                session.selectedModel = Self.modelID
                session.forceChatEngineRouteForTests = true
                session.toolsDisabledForTestingOverride = false
                session.chatEngineFactory = { _ in engine }
                session.turns = [ChatTurn(role: .user, content: "Delegate a bounded task in the background."),
                    ChatTurn(role: .assistant, content: "The worker is running.")]

                let workerSessionID = UUID()
                let report = helperReport(workerSessionID: workerSessionID)
                await SubagentReportBack.deliver(title: "Delegated to Responses Proof Worker", success: true,
                    summary: "BG_TOKEN_9",
                    completedEnvelope: ToolEnvelope.success(tool: "spawn_agent", result: [
                        "kind": "spawn_result", "session_id": workerSessionID.uuidString, "summary": "BG_TOKEN_9"]),
                    to: WeakChatSessionBox(session))
                try await waitUntil { await capture.messages.count >= 1 && !session.isStreaming }
                if let task = session.currentSendTaskForTesting { await task.value }

                var batches = await capture.messages
                try #require(batches.count == 1)
                let reportMessage = try #require(batches[0].last(where: { $0.role == "user" })?.content)
                #expect(reportMessage.hasSuffix(report))
                #expect(!reportMessage.contains("[Memory]"))
                #expect(!batches[0].contains { $0.content?.contains(Self.staleInstruction) == true })

                // Host provenance must not stick: the next genuine user turn
                // still recalls memory keyed on what the user typed.
                let followUp = "What did the Responses Proof Worker return?"
                try await waitUntil { !session.isStreaming }
                // In a full-suite process a picker refresh driven by another
                // suite's catalog work can renormalize the selection to the
                // always-present Foundation model between sends (observed:
                // "Model 'foundation' is not installed"). Pin the fixture.
                session.selectedModel = Self.modelID
                session.send(followUp)
                try await waitUntil { await capture.messages.count >= 2 && !session.isStreaming }
                if let task = session.currentSendTaskForTesting { await task.value }
                batches = await capture.messages
                try #require(batches.count == 2,
                    "follow-up never reached the engine: streaming=\(session.isStreaming) error=\(session.lastStreamError ?? "nil")")
                let followUpMessage = try #require(batches[1].last(where: { $0.role == "user" })?.content)
                #expect(followUpMessage.hasSuffix(followUp))
                #expect(followUpMessage.contains("[Memory]"))
                #expect(followUpMessage.contains(Self.staleDelegationFact))

                // Write side. The follow-up's records are the positive control
                // that this session's memory writes ran; the report turn,
                // written earlier, must contribute no user-attributed record.
                let conversationId = try #require(session.sessionId).uuidString
                var signals: [PendingSignal] = []
                var transcript: [TranscriptTurn] = []
                for _ in 0 ..< 200 {
                    signals = try MemoryDatabase.shared.loadPendingSignals(conversationId: conversationId)
                    transcript = try MemoryDatabase.shared.loadTranscriptForConversation(conversationId: conversationId)
                    let followUpWritten = signals.contains { $0.userMessage == followUp }
                        && transcript.contains { $0.role == "user" && $0.content == followUp }
                    let bothRepliesIndexed = transcript.filter { $0.role == "assistant" }.count == 2
                    if followUpWritten && bothRepliesIndexed { break }
                    try await Task.sleep(for: .milliseconds(25))
                }
                try #require(signals.contains { $0.userMessage == followUp },
                    "Control: the genuine follow-up must be buffered for distillation")
                try #require(transcript.filter { $0.role == "assistant" }.count == 2,
                    "Control: the assistant's reply to the report is still indexed")
                #expect(!signals.contains { $0.userMessage.contains("[Helper report]") })
                #expect(transcript.filter { $0.role == "user" }.map(\.content) == [followUp])
                #expect(session.lastStreamError == nil)
            }
        }
    }
}
