//
//  WorkExecutionEngineTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct WorkExecutionEngineTests {

    @Test func truncateToolResult_shortResult_unchanged() async {
        let engine = WorkExecutionEngine()
        let short = String(repeating: "a", count: 100)
        let result = await engine.truncateToolResult(short)
        #expect(result == short)
    }

    @Test func truncateToolResult_exactLimit_unchanged() async {
        let engine = WorkExecutionEngine()
        let exact = String(repeating: "b", count: 8000)
        let result = await engine.truncateToolResult(exact)
        #expect(result == exact)
    }

    @Test func truncateToolResult_longResult_truncatedWithMarker() async {
        let engine = WorkExecutionEngine()
        let long = String(repeating: "c", count: 20000)
        let result = await engine.truncateToolResult(long)
        #expect(result.count < 20000)
        #expect(result.contains(WorkExecutionEngine.truncationOmissionMarker))
        #expect(result.hasPrefix(String(repeating: "c", count: 6000)))
        #expect(result.hasSuffix(String(repeating: "c", count: 2000)))
    }

    @Test func truncateToolResult_structuredExecPayload_preservesJsonShape() async throws {
        let engine = WorkExecutionEngine()
        let payload = try JSONSerialization.data(
            withJSONObject: [
                "stdout": String(repeating: "a", count: 12000),
                "stderr": String(repeating: "b", count: 12000),
                "exit_code": 1,
            ]
        )
        let long = try #require(String(data: payload, encoding: .utf8))

        let result = await engine.truncateToolResult(long)
        let decoded = try #require(try parseEngineJSON(result))

        #expect(decoded["exit_code"] as? Int == 1)
        #expect(decoded["stdout_truncated"] as? Bool == true)
        #expect(decoded["stderr_truncated"] as? Bool == true)
        #expect((decoded["stdout"] as? String)?.contains(WorkExecutionEngine.truncationOmissionMarker) == true)
        #expect((decoded["stderr"] as? String)?.contains(WorkExecutionEngine.truncationOmissionMarker) == true)
    }

    @Test func buildAgentSystemPrompt_sandboxIncludesWorkflowGuidance() async {
        let (prompt, _) = SystemPromptComposer.composeWorkPrompt(
            base: "Base prompt",
            executionMode: .sandbox
        )

        #expect(prompt.contains(SystemPromptTemplates.sandboxScaffoldGuidance))
        #expect(prompt.contains(SystemPromptTemplates.sandboxVerifyGuidance))
        #expect(prompt.contains("call `complete_task`"))
        #expect(prompt.contains(SystemPromptTemplates.sandboxReadFileHint))
    }

    @Test @MainActor
    func executeLoop_emitsBudgetWarningsBeforeCompletion() async throws {
        let registry = ToolRegistry.shared
        registry.register(NoopTestTool())
        registry.setEnabled(true, for: "noop_test")
        defer { registry.unregister(names: ["noop_test"]) }
        let tools = [
            Tool(
                type: "function",
                function: ToolFunction(
                    name: "noop_test",
                    description: "No-op test tool.",
                    parameters: .object(["type": .string("object")])
                )
            ),
            Tool(
                type: "function",
                function: ToolFunction(
                    name: "complete_task",
                    description: "Complete task",
                    parameters: .object(["type": .string("object")])
                )
            ),
        ]

        let engine = WorkExecutionEngine(
            chatEngine: SequencedWorkChatEngine(
                steps: (Array(repeating: .tool("noop_test", "{}"), count: 10)
                    + [.tool("complete_task", #"{"summary":"done","success":true}"#)])
            )
        )
        let issue = Issue(taskId: "task-2", title: "Long task")
        var messages: [ChatMessage] = []
        var statuses: [String] = []

        let result = try await engine.executeLoop(
            issue: issue,
            messages: &messages,
            systemPrompt: "Base",
            model: "mock",
            tools: tools,
            maxIterations: 15,
            onIterationStart: { _ in },
            onDelta: { _, _ in },
            onToolHint: { _ in },
            onToolArgHint: { _ in },
            onToolCall: { _, _, _ in },
            onStatusUpdate: { statuses.append($0) },
            onArtifact: { _ in },
            onTokensConsumed: { _, _ in }
        )

        guard case .completed(let summary, _) = result else {
            Issue.record("Expected loop completion")
            return
        }
        #expect(summary == "done")
        #expect(statuses.contains(SystemPromptTemplates.budgetRemainingStatus(remaining: 5, total: 15)))
        #expect(statuses.contains(SystemPromptTemplates.budgetWarningStatus(remaining: 5)))
    }

    @Test @MainActor
    func executeLoop_returnsInterruptedWithAccumulatedMessages() async throws {
        let registry = ToolRegistry.shared
        registry.register(NoopTestTool())
        registry.setEnabled(true, for: "noop_test")
        defer { registry.unregister(names: ["noop_test"]) }

        let tools = [noopToolSpec()]
        let engine = WorkExecutionEngine(
            chatEngine: SequencedWorkChatEngine(steps: [.tool("noop_test", "{}")])
        )
        let issue = Issue(taskId: "task-3", title: "Interrupt me")
        var messages: [ChatMessage] = []
        let interruptCounter = InterruptCounter()

        let result = try await engine.executeLoop(
            issue: issue,
            messages: &messages,
            systemPrompt: "Base",
            model: "mock",
            tools: tools,
            maxIterations: 5,
            shouldInterrupt: {
                await interruptCounter.nextShouldInterrupt()
            },
            onIterationStart: { _ in },
            onDelta: { _, _ in },
            onToolHint: { _ in },
            onToolArgHint: { _ in },
            onToolCall: { _, _, _ in },
            onStatusUpdate: { _ in },
            onArtifact: { _ in },
            onTokensConsumed: { _, _ in }
        )

        guard case .interrupted(let preservedMessages, let iteration, let toolCalls) = result else {
            Issue.record("Expected interruption result")
            return
        }

        #expect(iteration == 1)
        #expect(toolCalls == 1)
        #expect(preservedMessages.contains(where: { $0.role == "tool" && $0.content == "{}" }))
    }

    @Test @MainActor
    func executeLoop_clarificationResultCarriesMessages() async throws {
        let engine = WorkExecutionEngine(
            chatEngine: SequencedWorkChatEngine(
                steps: [.tool("request_clarification", #"{"question":"Database?","options":["SQLite","Postgres"]}"#)]
            )
        )
        let issue = Issue(taskId: "task-4", title: "Need clarification")
        var messages = [ChatMessage(role: "user", content: "Build it")]

        let result = try await engine.executeLoop(
            issue: issue,
            messages: &messages,
            systemPrompt: "Base",
            model: "mock",
            tools: [clarificationToolSpec()],
            maxIterations: 2,
            onIterationStart: { _ in },
            onDelta: { _, _ in },
            onToolHint: { _ in },
            onToolArgHint: { _ in },
            onToolCall: { _, _, _ in },
            onStatusUpdate: { _ in },
            onArtifact: { _ in },
            onTokensConsumed: { _, _ in }
        )

        guard case .needsClarification(let clarification, let preservedMessages, let iteration, let toolCalls) = result
        else {
            Issue.record("Expected clarification result")
            return
        }

        #expect(clarification.question == "Database?")
        #expect(iteration == 1)
        #expect(toolCalls == 1)
        #expect(preservedMessages.first?.content == "Build it")
    }
}

private func parseEngineJSON(_ string: String) throws -> [String: Any]? {
    guard let data = string.data(using: .utf8) else { return nil }
    return try JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private struct NoopTestTool: OsaurusTool {
    let name = "noop_test"
    let description = "No-op test tool."
    let parameters: JSONValue? = .object(["type": .string("object")])

    func execute(argumentsJSON _: String) async throws -> String {
        "{}"
    }
}

private func noopToolSpec() -> Tool {
    Tool(
        type: "function",
        function: ToolFunction(
            name: "noop_test",
            description: "No-op test tool.",
            parameters: .object(["type": .string("object")])
        )
    )
}

private func clarificationToolSpec() -> Tool {
    Tool(
        type: "function",
        function: ToolFunction(
            name: "request_clarification",
            description: "Clarify the task",
            parameters: .object(["type": .string("object")])
        )
    )
}

private actor SequencedWorkChatEngine: ChatEngineProtocol {
    enum Step {
        case tool(String, String)
    }

    private var steps: [Step]
    private var index = 0

    init(steps: [Step]) {
        self.steps = steps
    }

    func streamChat(request _: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        guard index < steps.count else {
            return AsyncThrowingStream { continuation in continuation.finish() }
        }
        let step = steps[index]
        index += 1

        switch step {
        case .tool(let name, let args):
            throw ServiceToolInvocation(toolName: name, jsonArguments: args)
        }
    }

    func completeChat(request _: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw NSError(domain: "WorkExecutionEngineTests", code: 1)
    }
}

private actor InterruptCounter {
    private var count = 0

    func nextShouldInterrupt() -> Bool {
        count += 1
        return count > 1
    }
}
