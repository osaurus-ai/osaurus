//
//  AgentToolLoopTests.swift
//
//  Unit tests for the canonical `AgentToolLoop` driver using scripted
//  hooks (a fake model step + fake tool executor). These pin the loop
//  policies the three surfaces share: iteration budgets and the warning
//  notice, dedupe replay, next-step bias staging, rejection policy,
//  surface-directed end, cancellation, and transient-retry accounting.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Scripted harness

/// Builds `AgentLoopHooks` from a script of model steps and a canned
/// tool-result table, recording every hook crossing for assertions.
@MainActor
private final class ScriptedLoopSurface {
    var steps: [AgentLoopModelStep]
    /// Result envelope per tool name; defaults to a generic success.
    var toolResults: [String: AgentLoopToolExecution] = [:]
    var cancelled = false
    /// When true, `buildMessages` reports a hard context overflow.
    var overBudget = false
    /// When non-nil, hooks expose `pendingTodoCount` returning this value
    /// (the chat surface's session-todo plumb).
    var pendingTodos: Int?
    var todoProgress: AgentTodoProgressSnapshot?
    var forceMissingTodoProgressSnapshot = false

    // Recorded crossings
    var builtNotices: [[String]] = []
    var executedCalls: [(name: String, args: String, callId: String)] = []
    var dedupedCalls: [(name: String, callId: String, held: String)] = []
    var willProcessCallIds: [String] = []
    var batchOutcomes: [[AgentLoopToolOutcome]] = []
    var emittedFinalTexts: [String] = []
    var incompleteContinuationPreparations = 0
    var cancelOnIncompleteContinuation = false
    var trackedTaskContinuationPreparations = 0
    var cancelOnTrackedTaskContinuation = false
    var todoProgressSnapshotCalls = 0
    var cancelOnTodoProgressSnapshotCall: Int?

    init(steps: [AgentLoopModelStep]) {
        self.steps = steps
    }

    func makeHooks(
        includeFallbackText: Bool = true,
        includeTrackedTaskContinuation: Bool = false
    ) -> AgentLoopHooks {
        var hooks = AgentLoopHooks(
            isCancelled: { self.cancelled },
            buildMessages: { notices in
                self.builtNotices.append(notices)
                return AgentLoopIterationInput(
                    messages: [ChatMessage(role: "user", content: "task")],
                    overBudget: self.overBudget
                )
            },
            modelStep: { _, _ in
                guard !self.steps.isEmpty else { return .finalResponse }
                return self.steps.removeFirst()
            },
            prepareIncompleteReasoningContinuation: {
                self.incompleteContinuationPreparations += 1
                if self.cancelOnIncompleteContinuation {
                    self.cancelled = true
                }
            },
            prepareTrackedTaskContinuation: includeTrackedTaskContinuation
                ? {
                    self.trackedTaskContinuationPreparations += 1
                    if self.cancelOnTrackedTaskContinuation {
                        self.cancelled = true
                    }
                }
                : nil,
            willProcessCall: { _, callId in
                self.willProcessCallIds.append(callId)
            },
            onDedupedResult: { inv, callId, held in
                self.dedupedCalls.append((inv.toolName, callId, held))
            },
            executeTool: { inv, callId in
                self.executedCalls.append((inv.toolName, inv.jsonArguments, callId))
                return self.toolResults[inv.toolName]
                    ?? AgentLoopToolExecution(result: ToolEnvelope.success(tool: inv.toolName, text: "ok"))
            },
            onBatchComplete: { outcomes in
                self.batchOutcomes.append(outcomes)
                self.recordTodoProgress(from: outcomes)
            },
            pendingTodoCount: pendingTodos == nil ? nil : { self.pendingTodos ?? 0 },
            todoProgressSnapshot: includeTrackedTaskContinuation
                ? {
                    self.todoProgressSnapshotCalls += 1
                    if self.cancelOnTodoProgressSnapshotCall
                        == self.todoProgressSnapshotCalls
                    {
                        self.cancelled = true
                    }
                    return self.forceMissingTodoProgressSnapshot ? nil : self.todoProgress
                }
                : nil
        )
        if includeFallbackText {
            hooks.emitFallbackText = { text in
                self.emittedFinalTexts.append(text)
            }
        }
        return hooks
    }

    private func recordTodoProgress(from outcomes: [AgentLoopToolOutcome]) {
        for outcome in outcomes where outcome.invocation.toolName == "todo" {
            guard !outcome.wasError, ToolEnvelope.isSuccess(outcome.result),
                let data = outcome.invocation.jsonArguments.data(using: .utf8),
                let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let markdown = dict["markdown"] as? String
            else { continue }
            let todo = AgentTodo.parse(markdown)
            let snapshot = AgentTodoProgressSnapshot(
                done: todo.doneCount,
                total: todo.totalCount
            )
            todoProgress = snapshot
            pendingTodos = snapshot.pending
        }
    }
}

private func inv(_ name: String, _ args: String = "{}", callId: String? = nil) -> ServiceToolInvocation {
    ServiceToolInvocation(toolName: name, jsonArguments: args, toolCallId: callId)
}

private func loopTestTool(_ name: String) -> Tool {
    Tool(
        type: "function",
        function: ToolFunction(
            name: name,
            description: "Loop test tool \(name)",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ])
        )
    )
}

private func chatPolicy(maxIterations: Int = 15) -> AgentLoopPolicy {
    AgentLoopPolicy(
        maxIterations: maxIterations,
        stopOnToolRejection: true,
        dedupeNoticeEnabled: true
    )
}

private func headlessPolicy(maxIterations: Int = 30) -> AgentLoopPolicy {
    AgentLoopPolicy(
        maxIterations: maxIterations,
        stopOnToolRejection: false,
        dedupeNoticeEnabled: false
    )
}

private func taskTrackingChatPolicy(
    maxIterations: Int = 15,
    threshold: Int = 3
) -> AgentLoopPolicy {
    AgentLoopPolicy(
        maxIterations: maxIterations,
        stopOnToolRejection: true,
        dedupeNoticeEnabled: true,
        todoRequiredBeforeToolCallCount: threshold
    )
}

// MARK: - Tests

@MainActor
struct AgentToolLoopTests {
    @Test func chatTodoPreconditionIsDisabledForEveryModelFamily() {
        for modelType in [
            "gemma4_moe", "qwen3_5", "qwen3_5_moe", "glm4_moe",
            "laguna_s21", "lfm2", "deepseek_v4", nil,
        ] {
            #expect(
                AgentToolLoop.chatTodoPreconditionThreshold(
                    hasTodoTool: true,
                    isLocalModel: true,
                    modelType: modelType
                ) == 0
            )
        }

        #expect(
                AgentToolLoop.chatTodoPreconditionThreshold(
                    hasTodoTool: true,
                    isLocalModel: false,
                    modelType: "gemma4_moe"
                ) == 0
        )
        #expect(
            AgentToolLoop.chatTodoPreconditionThreshold(
                hasTodoTool: false,
                isLocalModel: true,
                modelType: "qwen3_5_moe"
            ) == 0
        )
    }

    @Test func ordinaryActionsNeverRequireModelAuthoredTodo() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("web_search", #"{"query":"one"}"#)]),
            .toolCalls([inv("web_search", #"{"query":"two"}"#)]),
            .toolCalls([inv("web_search", #"{"query":"three"}"#)]),
            .finalResponse,
        ])
        var executedBatches: [[String]] = []
        var hooks = surface.makeHooks(includeTrackedTaskContinuation: true)
        hooks.executeBatch = { calls in
            executedBatches.append(calls.map { $0.invocation.toolName })
            return calls.map { call in
                if call.invocation.toolName == "web_search" {
                    // Correctable tool failures still describe attempted
                    // multi-step work and therefore count toward the gate.
                    return AgentLoopToolExecution(
                        result: ToolEnvelope.failure(
                            kind: .executionError,
                            message: "provider unavailable",
                            tool: call.invocation.toolName,
                            retryable: true
                        )
                    )
                }
                return AgentLoopToolExecution(
                    result: ToolEnvelope.success(tool: call.invocation.toolName, text: "ok")
                )
            }
        }

        let result = try await AgentToolLoop.run(
            policy: taskTrackingChatPolicy(),
            state: AgentTaskState(),
            hooks: hooks
        )

        #expect(result == AgentToolLoop.RunResult(exit: .finalResponse, iterations: 4))
        #expect(executedBatches == [
            ["web_search"], ["web_search"], ["web_search"],
        ])
        #expect(surface.batchOutcomes.count == 3)
        #expect(!surface.batchOutcomes.flatMap { $0 }.contains(where: {
            AgentToolLoop.isTaskTrackingRequiredResult($0.result)
        }))
    }

    @Test func parseableTodoInThirdBatchUnlocksSiblingAction() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("tool_one")]),
            .toolCalls([inv("tool_two")]),
            .toolCalls([
                inv("todo", #"{"markdown":"- [x] finish the task"}"#),
                inv("tool_three"),
            ]),
            .finalResponse,
        ])
        var executedBatches: [[String]] = []
        var hooks = surface.makeHooks(includeTrackedTaskContinuation: true)
        hooks.executeBatch = { calls in
            executedBatches.append(calls.map { $0.invocation.toolName })
            return calls.map {
                AgentLoopToolExecution(
                    result: ToolEnvelope.success(tool: $0.invocation.toolName, text: "ok")
                )
            }
        }

        let result = try await AgentToolLoop.run(
            policy: taskTrackingChatPolicy(),
            state: AgentTaskState(),
            hooks: hooks
        )

        #expect(result == AgentToolLoop.RunResult(exit: .finalResponse, iterations: 4))
        #expect(executedBatches == [
            ["tool_one"], ["tool_two"], ["todo", "tool_three"],
        ])
        #expect(!surface.batchOutcomes.flatMap { $0 }.contains(where: {
            AgentToolLoop.isTaskTrackingRequiredResult($0.result)
        }))
    }

    @Test func explicitCompleteRemainsAuthoritativeWithStaleTodo() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("todo", #"{"markdown":"- [ ] inspect\n- [ ] report"}"#)]),
            .toolCalls([inv("file_read", #"{"path":"report.txt"}"#)]),
            .toolCalls([
                inv(
                    "complete",
                    #"{"summary":"Read the available report, but the second required source is unavailable."}"#
                )
            ]),
        ])
        var executedBatches: [[String]] = []
        var hooks = surface.makeHooks(includeTrackedTaskContinuation: true)
        hooks.executeBatch = { calls in
            executedBatches.append(calls.map { $0.invocation.toolName })
            return calls.map { call in
                AgentLoopToolExecution(
                    result: ToolEnvelope.success(tool: call.invocation.toolName, text: "ok"),
                    endRun: call.invocation.toolName == "complete"
                )
            }
        }

        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: hooks
        )

        #expect(result == AgentToolLoop.RunResult(exit: .endedBySurface, iterations: 3))
        #expect(executedBatches == [["todo"], ["file_read"], ["complete"]])
        #expect(!surface.batchOutcomes.flatMap { $0 }.contains(where: {
            AgentToolLoop.isTodoProgressUpdateRequiredResult($0.result)
        }))
        #expect(surface.todoProgress == AgentTodoProgressSnapshot(done: 0, total: 2))
    }

    @Test func precedingTodoInSameBatchCanRefreshBeforeBlockedComplete() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("todo", #"{"markdown":"- [ ] inspect\n- [ ] report"}"#)]),
            .toolCalls([inv("file_read", #"{"path":"report.txt"}"#)]),
            .toolCalls([
                inv("todo", #"{"markdown":"- [x] inspect\n- [ ] report"}"#),
                inv(
                    "complete",
                    #"{"summary":"Read and verified the available report; the final report remains blocked on the missing source."}"#
                ),
            ]),
        ])
        var executedBatches: [[String]] = []
        var hooks = surface.makeHooks(includeTrackedTaskContinuation: true)
        hooks.executeBatch = { calls in
            executedBatches.append(calls.map { $0.invocation.toolName })
            return calls.map { call in
                AgentLoopToolExecution(
                    result: ToolEnvelope.success(tool: call.invocation.toolName, text: "ok"),
                    endRun: call.invocation.toolName == "complete"
                )
            }
        }

        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: hooks
        )

        #expect(result == AgentToolLoop.RunResult(exit: .endedBySurface, iterations: 3))
        #expect(executedBatches == [["todo"], ["file_read"], ["todo", "complete"]])
        #expect(!surface.batchOutcomes.flatMap { $0 }.contains(where: {
            AgentToolLoop.isTodoProgressUpdateRequiredResult($0.result)
        }))
        #expect(surface.todoProgress == AgentTodoProgressSnapshot(done: 1, total: 2))
    }

    @Test func repeatedSemanticTodoRemainsModelOwnedState() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("todo", #"{"markdown":"- [ ] inspect\n- [ ] answer"}"#)]),
            // Presentation changes do not turn an unchanged 0/2 checklist
            // into progress.
            .toolCalls([inv("todo", #"{"markdown":"Plan\n* [ ] inspect\n* [ ] answer"}"#)]),
            .toolCalls([inv("todo", #"{"markdown":"- [x] inspect\n- [ ] answer"}"#)]),
            .toolCalls([inv("todo", #"{"markdown":"- [x] inspect\n- [x] answer"}"#)]),
            .finalResponse,
        ])

        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks(includeTrackedTaskContinuation: true)
        )

        #expect(result == AgentToolLoop.RunResult(exit: .finalResponse, iterations: 5))
        #expect(surface.executedCalls.map(\.name) == ["todo", "todo", "todo", "todo"])
        #expect(!surface.batchOutcomes.flatMap { $0 }.contains(where: {
            AgentToolLoop.isTodoNoProgressResult($0.result)
        }))
        #expect(surface.todoProgress == AgentTodoProgressSnapshot(done: 2, total: 2))
    }

    @Test func batchExecutorAlsoAllowsRepeatedSemanticTodo() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("todo", #"{"markdown":"- [ ] inspect\n- [ ] answer"}"#)]),
            .toolCalls([inv("todo", #"{"markdown":"- [ ] inspect\n- [ ] answer"}"#)]),
            .toolCalls([inv("todo", #"{"markdown":"- [x] inspect\n- [x] answer"}"#)]),
            .finalResponse,
        ])
        var executedBatches: [[String]] = []
        var hooks = surface.makeHooks(includeTrackedTaskContinuation: true)
        hooks.executeBatch = { calls in
            executedBatches.append(calls.map { $0.invocation.toolName })
            return calls.map {
                AgentLoopToolExecution(
                    result: ToolEnvelope.success(tool: $0.invocation.toolName, text: "ok")
                )
            }
        }

        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: hooks
        )

        #expect(result == AgentToolLoop.RunResult(exit: .finalResponse, iterations: 4))
        #expect(executedBatches == [["todo"], ["todo"], ["todo"]])
        #expect(!surface.batchOutcomes.flatMap { $0 }.contains(where: {
            AgentToolLoop.isTodoNoProgressResult($0.result)
        }))
        #expect(surface.todoProgress == AgentTodoProgressSnapshot(done: 2, total: 2))
    }

    @Test func unchangedTodoAfterUnproductiveWorkAllowsHonestBlockedComplete() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("todo", #"{"markdown":"- [ ] fetch source\n- [ ] report"}"#)]),
            .toolCalls([inv("web_fetch", #"{"url":"https://blocked.example"}"#)]),
            .toolCalls([inv("todo", #"{"markdown":"- [ ] fetch source\n- [ ] report"}"#)]),
            .toolCalls([
                inv(
                    "complete",
                    #"{"summary":"The source fetch failed and no claims could be verified, so both tracked items remain honestly blocked."}"#
                )
            ]),
        ])
        surface.toolResults["web_fetch"] = AgentLoopToolExecution(
            result: ToolEnvelope.success(
                tool: "web_fetch",
                text: "The provider returned no extractable source content."
            )
        )
        surface.toolResults["complete"] = AgentLoopToolExecution(
            result: ToolEnvelope.success(tool: "complete", text: "closed blocked"),
            endRun: true
        )

        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks(includeTrackedTaskContinuation: true)
        )

        #expect(result == AgentToolLoop.RunResult(exit: .endedBySurface, iterations: 4))
        #expect(surface.executedCalls.map(\.name) == ["todo", "web_fetch", "todo", "complete"])
        #expect(!surface.batchOutcomes.flatMap { $0 }.contains(where: {
            AgentToolLoop.isTodoNoProgressResult($0.result)
        }))
        #expect(!surface.batchOutcomes.flatMap { $0 }.contains(where: {
            AgentToolLoop.isTodoProgressUpdateRequiredResult($0.result)
        }))
        #expect(surface.todoProgress == AgentTodoProgressSnapshot(done: 0, total: 2))
    }

    @Test func staleSessionTodoNeverCreatesAnActionGate() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("tool_one")]),
            .toolCalls([inv("tool_two")]),
            .toolCalls([inv("tool_three")]),
            .finalResponse,
        ])
        // Simulate a completed Todo left by an older user turn. Only a Todo
        // successfully emitted during this logical run may unlock actions.
        surface.pendingTodos = 0
        surface.todoProgress = AgentTodoProgressSnapshot(done: 2, total: 2)
        var executedBatches: [[String]] = []
        var hooks = surface.makeHooks(includeTrackedTaskContinuation: true)
        hooks.executeBatch = { calls in
            executedBatches.append(calls.map { $0.invocation.toolName })
            return calls.map {
                AgentLoopToolExecution(
                    result: ToolEnvelope.success(tool: $0.invocation.toolName, text: "ok")
                )
            }
        }

        let result = try await AgentToolLoop.run(
            policy: taskTrackingChatPolicy(),
            state: AgentTaskState(),
            hooks: hooks
        )

        #expect(result == AgentToolLoop.RunResult(exit: .finalResponse, iterations: 4))
        #expect(executedBatches == [["tool_one"], ["tool_two"], ["tool_three"]])
        #expect(!surface.batchOutcomes.flatMap { $0 }.contains(where: {
            AgentToolLoop.isTaskTrackingRequiredResult($0.result)
        }))
    }

    @Test func headlessPolicyDoesNotImposeChatTodoPrecondition() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("tool_one")]),
            .toolCalls([inv("tool_two")]),
            .toolCalls([inv("tool_three")]),
            .finalResponse,
        ])

        let result = try await AgentToolLoop.run(
            policy: headlessPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )

        #expect(result == AgentToolLoop.RunResult(exit: .finalResponse, iterations: 4))
        #expect(surface.executedCalls.map(\.name) == ["tool_one", "tool_two", "tool_three"])
        #expect(!surface.batchOutcomes.flatMap { $0 }.contains(where: {
            AgentToolLoop.isTaskTrackingRequiredResult($0.result)
        }))
    }

    @Test func finalResponseOnFirstStepEndsRun() async throws {
        let surface = ScriptedLoopSurface(steps: [.finalResponse])
        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(result == AgentToolLoop.RunResult(exit: .finalResponse, iterations: 1))
        #expect(surface.executedCalls.isEmpty)
        #expect(surface.builtNotices == [[]])
    }

    @Test func reasoningOnlyLengthIsNotClassifiedAsFinalResponse() {
        let step = AgentLoopModelStep.classifyTerminal(
            contentIsBlank: true,
            thinkingIsBlank: false,
            stopReason: "length",
            requiresVisibleFinalResponse: true
        )
        guard case .lengthExhausted = step else {
            Issue.record("reasoning-only stop=length must be lengthExhausted")
            return
        }
    }

    @Test func reasoningOnlyNaturalStopRequiresVisibleAnswer() {
        let step = AgentLoopModelStep.classifyTerminal(
            contentIsBlank: true,
            thinkingIsBlank: false,
            stopReason: "stop",
            requiresVisibleFinalResponse: true
        )
        guard case .incompleteReasoning = step else {
            Issue.record("reasoning-only natural stop must not masquerade as a final answer")
            return
        }
    }

    @Test func intentionalReasoningOnlyDirectChatRemainsFinal() {
        let step = AgentLoopModelStep.classifyTerminal(
            contentIsBlank: true,
            thinkingIsBlank: false,
            stopReason: "stop",
            requiresVisibleFinalResponse: false
        )
        guard case .finalResponse = step else {
            Issue.record("a no-tool reasoning-only direct chat must remain a valid final response")
            return
        }
    }

    @Test func intentionalUnclosedReasoningOnlyDirectChatRemainsFinal() {
        let step = AgentLoopModelStep.classifyTerminal(
            contentIsBlank: true,
            thinkingIsBlank: false,
            stopReason: "stop",
            unclosedReasoning: true,
            requiresVisibleFinalResponse: false
        )
        guard case .finalResponse = step else {
            Issue.record("a no-tool reasoning-only direct chat preserves its current product contract")
            return
        }
    }

    @Test func visibleResponsePolicyDoesNotConfuseAvailableSchemasWithToolWork() {
        #expect(
            !AgentLoopVisibleResponsePolicy.requiresVisibleFinalResponse(
                hasStructuredToolWork: false,
                isRemoteAgentTarget: false
            )
        )
        #expect(
            AgentLoopVisibleResponsePolicy.requiresVisibleFinalResponse(
                hasStructuredToolWork: true,
                isRemoteAgentTarget: false
            )
        )
        #expect(
            AgentLoopVisibleResponsePolicy.requiresVisibleFinalResponse(
                hasStructuredToolWork: false,
                isRemoteAgentTarget: true
            )
        )
    }

    @Test func unclosedReasoningWithContentEndsWithoutTransparentReplay() {
        let step = AgentLoopModelStep.classifyTerminal(
            contentIsBlank: false,
            thinkingIsBlank: false,
            stopReason: "stop",
            unclosedReasoning: true,
            requiresVisibleFinalResponse: true
        )
        guard case .incompleteVisibleResponse = step else {
            Issue.record("visible partial content must not be concatenated with a transparent replay")
            return
        }
    }

    @Test func recoveryIdempotencyOrdinalDistinguishesLogicalReplayOnly() {
        let messages = [ChatMessage(role: "user", content: "Do the task.")]
        let first = AgentToolLoop.recoveryAwareIdempotencySuffix(
            messages: messages,
            incompleteReasoningRetryOrdinal: 0
        )
        let transportRetry = AgentToolLoop.recoveryAwareIdempotencySuffix(
            messages: messages,
            incompleteReasoningRetryOrdinal: 0
        )
        let reasoningRetry = AgentToolLoop.recoveryAwareIdempotencySuffix(
            messages: messages,
            incompleteReasoningRetryOrdinal: 1
        )

        #expect(first == transportRetry)
        #expect(first != reasoningRetry)
        #expect(first.hasPrefix("r0-"))
        #expect(reasoningRetry.hasPrefix("r1-"))
    }

    @Test func visibleIncompleteResponseEndsWithoutRetryOrGenericFallback() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .incompleteVisibleResponse,
            .finalResponse,
        ])
        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )

        #expect(
            result
                == AgentToolLoop.RunResult(
                    exit: .incompleteReasoningExhausted,
                    iterations: 1
                )
        )
        #expect(surface.steps.count == 1, "visible content makes transparent replay unsafe")
        #expect(surface.incompleteContinuationPreparations == 0)
        #expect(surface.emittedFinalTexts.isEmpty)
    }

    @Test func reasoningOnlyTurnGetsOneBoundedContinuation() async throws {
        let surface = ScriptedLoopSurface(steps: [.incompleteReasoning, .finalResponse])
        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )

        #expect(result == AgentToolLoop.RunResult(exit: .finalResponse, iterations: 1))
        #expect(surface.builtNotices == [[], []])
        #expect(surface.incompleteContinuationPreparations == 1)
        #expect(surface.emittedFinalTexts.isEmpty)
    }

    @Test func repeatedReasoningOnlyTurnEndsHonestlyWithoutLooping() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .incompleteReasoning,
            .incompleteReasoning,
            .finalResponse,
        ])
        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )

        #expect(
            result
                == AgentToolLoop.RunResult(
                    exit: .incompleteReasoningExhausted,
                    iterations: 1
                )
        )
        #expect(surface.steps.count == 1, "the third generation must not start")
        #expect(surface.incompleteContinuationPreparations == 1)
        #expect(surface.emittedFinalTexts.isEmpty)
    }

    @Test func continuationBudgetIsRunWideAcrossInterleavedToolWork() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .incompleteReasoning,
            .toolCalls([inv("file_read", #"{"path":"notes.md"}"#)]),
            .incompleteReasoning,
            .finalResponse,
        ])
        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )

        #expect(
            result
                == AgentToolLoop.RunResult(
                    exit: .incompleteReasoningExhausted,
                    iterations: 2
                )
        )
        #expect(surface.incompleteContinuationPreparations == 1)
        #expect(surface.executedCalls.map(\.name) == ["file_read"])
        #expect(surface.steps.count == 1, "a second reasoning-only step must end the run")
        #expect(surface.emittedFinalTexts.isEmpty)
    }

    @Test func cancellationWinsAfterIncompleteContinuationBoundary() async throws {
        let surface = ScriptedLoopSurface(steps: [.incompleteReasoning, .finalResponse])
        surface.cancelOnIncompleteContinuation = true

        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )

        #expect(result == AgentToolLoop.RunResult(exit: .cancelled, iterations: 0))
        #expect(surface.incompleteContinuationPreparations == 1)
        #expect(surface.steps.count == 1, "cancellation must prevent the continuation generation")
        #expect(surface.emittedFinalTexts.isEmpty)
    }

    @Test func cancellationDuringModelStepSkipsIncompleteContinuation() async throws {
        let surface = ScriptedLoopSurface(steps: [])
        var hooks = surface.makeHooks()
        hooks.modelStep = { _, _ in
            surface.cancelled = true
            return .incompleteReasoning
        }

        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: hooks
        )

        #expect(result == AgentToolLoop.RunResult(exit: .cancelled, iterations: 0))
        #expect(surface.incompleteContinuationPreparations == 0)
        #expect(surface.emittedFinalTexts.isEmpty)
    }

    @Test func visibleLengthResponseIsIncompleteButPreservedForFallback() {
        let step = AgentLoopModelStep.classifyTerminal(
            contentIsBlank: false,
            thinkingIsBlank: false,
            stopReason: "length",
            requiresVisibleFinalResponse: true
        )
        guard case .lengthExhausted = step else {
            Issue.record("authoritative stop=length must remain incomplete")
            return
        }

        let rendered = AgentLoopModelStep.contentWithLengthFallback(
            "Visible partial answer.\n\n\n",
            fallback: AgentToolLoop.lengthExhaustedFallback
        )
        #expect(rendered.hasPrefix("Visible partial answer.\n\n"))
        #expect(rendered.hasSuffix(AgentToolLoop.lengthExhaustedFallback))
        #expect(!rendered.contains("\n\n\n"))
    }

    @Test func whitespaceOnlyLengthResponseCollapsesToFallback() {
        let rendered = AgentLoopModelStep.contentWithLengthFallback(
            String(repeating: "\n", count: 1_776),
            fallback: AgentToolLoop.lengthExhaustedFallback
        )
        #expect(rendered == AgentToolLoop.lengthExhaustedFallback)
    }

    @Test func lengthExhaustionSurfacesIncompleteStateWithoutRetry() async throws {
        let surface = ScriptedLoopSurface(steps: [.lengthExhausted, .finalResponse])
        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )

        #expect(result == AgentToolLoop.RunResult(exit: .lengthExhausted, iterations: 1))
        #expect(surface.emittedFinalTexts == [AgentToolLoop.lengthExhaustedFallback])
        #expect(surface.steps.count == 1, "length exhaustion must not silently launch a second generation")
        #expect(surface.executedCalls.isEmpty)
    }

    @Test func oversizedToolCallGetsOneUnchargedChunkingRetry() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .oversizedToolCall(toolName: "file_write", argumentCharacters: 16_500),
            .toolCalls([inv("file_write", #"{"path":"index.html","content":"part"}"#)]),
            .finalResponse,
        ])
        let result = try await AgentToolLoop.run(
            policy: chatPolicy(maxIterations: 2),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )

        #expect(result == AgentToolLoop.RunResult(exit: .finalResponse, iterations: 2))
        #expect(surface.executedCalls.map(\.name) == ["file_write"])
        #expect(surface.builtNotices.count == 3)
        #expect(surface.builtNotices[1].joined().contains("mode: \"append\""))
    }

    @Test func truncatedToolCallGetsOneUnchargedChunkingRetry() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .truncatedToolCall(toolName: "file_write", argumentCharacters: 9_100),
            .toolCalls([inv("file_write", #"{"path":"index.html","content":"part"}"#)]),
            .finalResponse,
        ])
        let result = try await AgentToolLoop.run(
            policy: chatPolicy(maxIterations: 2),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )

        #expect(result == AgentToolLoop.RunResult(exit: .finalResponse, iterations: 2))
        #expect(surface.executedCalls.map(\.name) == ["file_write"])
        #expect(surface.builtNotices[1].joined().contains("reached the model output limit"))
        #expect(surface.builtNotices[1].joined().contains("mode: \"append\""))
    }

    @Test func streamingArgumentLimitFitsWorstCaseEscapedWriteChunk() throws {
        let content = String(
            repeating: #"\"#,
            count: WorkspaceToolContract.maxWriteContentCharacters
        )
        let data = try JSONSerialization.data(withJSONObject: [
            "path": "escaped.txt",
            "content": content,
        ])
        #expect(data.count < AgentToolLoop.maxStreamingToolArgumentCharacters)
    }

    @Test func repeatedOversizedToolCallStopsWithoutAnotherDecodeLoop() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .oversizedToolCall(toolName: "file_write", argumentCharacters: 16_500),
            .oversizedToolCall(toolName: "file_write", argumentCharacters: 16_600),
            .finalResponse,
        ])
        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )

        #expect(
            result
                == AgentToolLoop.RunResult(exit: .oversizedToolCallExhausted, iterations: 1)
        )
        #expect(surface.emittedFinalTexts == [AgentToolLoop.oversizedToolCallFallback])
        #expect(surface.steps.count == 1)
    }

    @Test func repeatedTruncatedToolCallStopsWithoutAnotherDecodeLoop() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .truncatedToolCall(toolName: "file_write", argumentCharacters: 9_100),
            .truncatedToolCall(toolName: "file_write", argumentCharacters: 9_200),
            .finalResponse,
        ])
        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )

        #expect(
            result
                == AgentToolLoop.RunResult(exit: .truncatedToolCallExhausted, iterations: 1)
        )
        #expect(surface.emittedFinalTexts == [AgentToolLoop.truncatedToolCallFallback])
        #expect(surface.steps.count == 1)
    }

    @Test func toolCallsExecuteThenFinish() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("file_search", #"{"query":"x"}"#), inv("shell_run", #"{"cmd":"ls"}"#)]),
            .finalResponse,
        ])
        let state = AgentTaskState()
        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: state,
            hooks: surface.makeHooks()
        )
        #expect(result.exit == .finalResponse)
        #expect(result.iterations == 2)
        #expect(surface.executedCalls.map(\.name) == ["file_search", "shell_run"])
        // Both tools were recorded into the state machine.
        #expect(state.lastResultEnvelope != nil)
        // One completed batch with both outcomes, in model order.
        #expect(surface.batchOutcomes.count == 1)
        #expect(surface.batchOutcomes[0].map { $0.invocation.toolName } == ["file_search", "shell_run"])
        #expect(surface.batchOutcomes[0].allSatisfy { !$0.wasDeduped && !$0.wasError })
    }

    @Test func stalePreEditRewriteIsRejectedBeforeToolExecution() async throws {
        let before = "const cells = board;"
        let after = "const cells = board.children;"
        let state = AgentTaskState()
        state.record(
            name: "file_edit",
            argsJSON: #"{"path":"index.html"}"#,
            result: ToolEnvelope.success(
                tool: "file_edit",
                result: [
                    "before_content_sha256": WorkspaceWriteSafety.contentSHA256(before),
                    "content_sha256": WorkspaceWriteSafety.contentSHA256(after),
                ]
            )
        )
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([
                inv("file_write", #"{"path":"index.html","content":"const cells = board;"}"#)
            ]),
            .finalResponse,
        ])

        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: state,
            hooks: surface.makeHooks()
        )

        #expect(result == AgentToolLoop.RunResult(exit: .toolRejected, iterations: 1))
        #expect(surface.executedCalls.isEmpty)
        let guarded = try #require(surface.batchOutcomes.first?.first)
        #expect(guarded.wasError)
        #expect(guarded.result.contains("stale_pre_edit_rewrite"))
    }

    @Test func permissionLeaseIsSharedWithinRunAndClearedAtTerminal() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("shell_run", #"{"command":"true"}"#)]),
            .toolCalls([inv("shell_run", #"{"command":"true"}"#)]),
            .finalResponse,
        ])
        var observedApproval: [Bool] = []
        var hooks = surface.makeHooks()
        hooks.executeBatch = { calls in
            let scope = ChatExecutionContext.toolPermissionRunScope
            observedApproval.append(scope?.allows("shell_run") == true)
            scope?.allow("shell_run")
            return calls.map {
                AgentLoopToolExecution(
                    result: ToolEnvelope.success(tool: $0.invocation.toolName, text: "ok")
                )
            }
        }

        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: hooks
        )

        #expect(result.exit == .finalResponse)
        #expect(observedApproval == [false, true])
        #expect(ChatExecutionContext.toolPermissionRunScope == nil)
    }

    @Test func fifthRephrasedWebSearchReturnsTransitionWithoutExecutingProvider() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("web_search", #"{"query":"source 1"}"#)]),
            .toolCalls([inv("web_search", #"{"query":"source 2"}"#)]),
            .toolCalls([inv("web_search", #"{"query":"source 3"}"#)]),
            .toolCalls([inv("web_search", #"{"query":"source 4"}"#)]),
            .toolCalls([inv("web_search", #"{"query":"source 5"}"#)]),
            .finalResponse,
        ])
        surface.toolResults["web_search"] = AgentLoopToolExecution(
            result: ToolEnvelope.success(tool: "web_search", text: "ranked snippets")
        )

        let result = try await AgentToolLoop.run(
            policy: chatPolicy(maxIterations: 6),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )

        #expect(result.exit == .finalResponse)
        #expect(surface.executedCalls.count == 4)
        let guarded = try #require(surface.batchOutcomes.last?.first)
        #expect(guarded.result.contains("transition_required"))
        #expect(!guarded.wasDeduped)
        #expect(!guarded.wasError)
    }

    @Test func capabilitiesLoadKeepsToolSchemaFrozenAndCallableSameTurn() async throws {
        // KV-prefix stability: the surface advertises the SAME <tools> set on
        // every iteration, even after `capabilities_load`. The loaded tool is
        // callable by name the same turn (registry dispatch is name-based) and
        // its schema rides in the tool result — the rendered prefix never
        // changes mid-run, so the paged-KV cache survives.
        let frozenTools = [loopTestTool("capabilities_load")]
        var schemaNamesSeen: [[String]] = []

        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("capabilities_load", #"{"ids":["tool/miyo_search"]}"#)]),
            .toolCalls([inv("miyo_search", #"{"query":"water"}"#)]),
            .finalResponse,
        ])
        var hooks = surface.makeHooks()
        hooks.buildMessages = { notices in
            surface.builtNotices.append(notices)
            schemaNamesSeen.append(frozenTools.map { $0.function.name })
            return AgentLoopIterationInput(messages: [ChatMessage(role: "user", content: "task")])
        }
        hooks.executeTool = { inv, callId in
            surface.executedCalls.append((inv.toolName, inv.jsonArguments, callId))
            return AgentLoopToolExecution(result: ToolEnvelope.success(tool: inv.toolName, text: "ran"))
        }

        let result = try await AgentToolLoop.run(
            policy: chatPolicy(maxIterations: 4),
            state: AgentTaskState(),
            hooks: hooks
        )

        #expect(result.exit == .finalResponse)
        // Loaded, then called the SAME turn without the prefix changing.
        #expect(surface.executedCalls.map(\.name) == ["capabilities_load", "miyo_search"])
        #expect(schemaNamesSeen.count >= 2)
        #expect(schemaNamesSeen.allSatisfy { $0 == ["capabilities_load"] })
    }

    @Test func preservesModelSuppliedCallIds() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("a_tool", "{}", callId: "call_preserved123")]),
            .finalResponse,
        ])
        _ = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(surface.executedCalls.first?.callId == "call_preserved123")
        // Generated ids follow the OpenAI shape.
        let minted = AgentToolLoop.callId(for: inv("b_tool"))
        #expect(minted.hasPrefix("call_"))
        #expect(minted.count == "call_".count + 24)
    }

    @Test func iterationCapReachedWhenToolsNeverStop() async throws {
        let max = 5
        let surface = ScriptedLoopSurface(
            steps: (0 ..< max).map { i in .toolCalls([inv("tool_\(i)")]) }
        )
        let result = try await AgentToolLoop.run(
            policy: chatPolicy(maxIterations: max),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(result == AgentToolLoop.RunResult(exit: .iterationCapReached, iterations: max))
        #expect(surface.executedCalls.count == max)
    }

    @Test func nearLimitNoticeAddsDelegationNudgeOnlyWhenSpawnVisible() {
        let plain = AgentToolLoop.contextNearLimitNotice(spawnAvailable: false)
        #expect(plain.contains("Context is nearly full"))
        #expect(!plain.contains("spawn"))

        let nudged = AgentToolLoop.contextNearLimitNotice(spawnAvailable: true)
        #expect(nudged.contains("Context is nearly full"))
        #expect(nudged.contains("spawn tool"))
        #expect(nudged.contains("self-contained input"))
    }

    @Test func budgetWarningStagedAtThreshold() async throws {
        // maxIterations 5, threshold 3: after iteration 2 remaining == 3,
        // so iterations 3, 4, 5 must each see the warning notice.
        let max = 5
        let surface = ScriptedLoopSurface(
            steps: (0 ..< max).map { i in .toolCalls([inv("tool_\(i)")]) }
        )
        _ = try await AgentToolLoop.run(
            policy: chatPolicy(maxIterations: max),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(surface.builtNotices.count == max)
        #expect(surface.builtNotices[0].isEmpty)
        #expect(surface.builtNotices[1].isEmpty)
        for i in 2 ..< max {
            let remaining = max - i
            #expect(
                surface.builtNotices[i] == [
                    AgentToolLoop.budgetWarningNotice(remaining: remaining, maxIterations: max)
                ]
            )
        }
    }

    @Test func dedupeReplaysHeldResultWithoutReexecuting() async throws {
        // A successful file_read becomes a fresh read; the identical
        // re-issue on the next iteration must replay the held envelope.
        let args = #"{"path":"notes.txt"}"#
        let envelope = ToolEnvelope.success(
            tool: "file_read",
            result: ["kind": "file", "path": "notes.txt", "content": "hello"]
        )
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("file_read", args)]),
            .toolCalls([inv("file_read", args)]),
            .finalResponse,
        ])
        surface.toolResults["file_read"] = AgentLoopToolExecution(result: envelope)

        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(result.exit == .finalResponse)
        #expect(surface.executedCalls.count == 1)
        #expect(surface.dedupedCalls.count == 1)
        #expect(surface.dedupedCalls.first?.held == envelope)
        // willProcessCall fires for BOTH (the surface materialises its
        // tool-call row before the dedupe check).
        #expect(surface.willProcessCallIds.count == 2)
        // The dedupe notice reaches the next model step (chat policy).
        #expect(surface.builtNotices[2] == [AgentToolLoop.dedupeNotice])
        // The deduped outcome is flagged in its batch.
        #expect(surface.batchOutcomes[1].first?.wasDeduped == true)
    }

    /// Issue #2098: a `file_read` whose rendered output was cut by the
    /// character cap carries `next_start_line`/`next_end_line`; the loop
    /// must stage a continuation notice for the NEXT model step naming the
    /// exact path and resume range, so the model reads the rest instead of
    /// reviewing the visible prefix as the whole file.
    @Test func partialFileReadStagesContinuationNoticeForNextStep() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("file_read", #"{"path":"BeatStrip.ino"}"#)]),
            .finalResponse,
        ])
        surface.toolResults["file_read"] = AgentLoopToolExecution(
            result: ToolEnvelope.success(
                tool: "file_read",
                result: [
                    "kind": "file",
                    "text": "Lines 1-426 of 499:\n...",
                    "path": "BeatStrip.ino",
                    "truncated": true,
                    "next_start_line": 427,
                    "next_end_line": 499,
                ]
            )
        )

        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(result.exit == .finalResponse)
        #expect(surface.builtNotices.count == 2)
        let notice = try #require(surface.builtNotices[1].first)
        #expect(notice.hasPrefix("[System Notice] "))
        #expect(notice.contains("BeatStrip.ino"))
        #expect(notice.contains(#""start_line": 427"#))
        #expect(notice.contains(#""end_line": 499"#))
    }

    /// A COMPLETE file read must not stage any continuation notice — the
    /// steer is reserved for reads observed truncated by the output cap.
    @Test func completeFileReadStagesNoContinuationNotice() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("file_read", #"{"path":"small.txt"}"#)]),
            .finalResponse,
        ])
        surface.toolResults["file_read"] = AgentLoopToolExecution(
            result: ToolEnvelope.success(
                tool: "file_read",
                result: [
                    "kind": "file",
                    "text": "     1|hello\n",
                    "path": "small.txt",
                    "truncated": false,
                ]
            )
        )

        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(result.exit == .finalResponse)
        #expect(surface.builtNotices == [[], []])
    }

    @Test func dedupeNoticeSuppressedForHeadlessPolicy() async throws {
        let args = #"{"path":"notes.txt"}"#
        let envelope = ToolEnvelope.success(
            tool: "file_read",
            result: ["kind": "file", "path": "notes.txt", "content": "hello"]
        )
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("file_read", args)]),
            .toolCalls([inv("file_read", args)]),
            .finalResponse,
        ])
        surface.toolResults["file_read"] = AgentLoopToolExecution(result: envelope)

        _ = try await AgentToolLoop.run(
            policy: headlessPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(surface.dedupedCalls.count == 1)
        #expect(surface.builtNotices[2].isEmpty)
    }

    @Test func rejectionStopsRunUnderChatPolicy() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("bad_tool"), inv("never_runs")])
        ])
        surface.toolResults["bad_tool"] = AgentLoopToolExecution(
            result: ToolEnvelope.failure(kind: .userDenied, message: "no", tool: "bad_tool"),
            isError: true
        )
        let state = AgentTaskState()
        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: state,
            hooks: surface.makeHooks()
        )
        #expect(result == AgentToolLoop.RunResult(exit: .toolRejected, iterations: 1))
        // The rest of the batch is skipped, and the rejection WAS recorded
        // into the state machine (mirrors the historical chat path).
        #expect(surface.executedCalls.map(\.name) == ["bad_tool"])
        #expect(state.lastResultClass == .error)
        // No batch-complete callback on early stop.
        #expect(surface.batchOutcomes.isEmpty)
    }

    @Test func rejectionContinuesUnderHeadlessPolicy() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("bad_tool"), inv("good_tool")]),
            .finalResponse,
        ])
        surface.toolResults["bad_tool"] = AgentLoopToolExecution(
            result: ToolEnvelope.failure(kind: .executionError, message: "boom", tool: "bad_tool"),
            isError: true
        )
        let result = try await AgentToolLoop.run(
            policy: headlessPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(result.exit == .finalResponse)
        #expect(surface.executedCalls.map(\.name) == ["bad_tool", "good_tool"])
        #expect(surface.batchOutcomes.count == 1)
        #expect(surface.batchOutcomes[0].map(\.wasError) == [true, false])
    }

    @Test func retryableExecutionFailureContinuesUnderChatPolicy() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("shell_run")]),
            .finalResponse,
        ])
        surface.toolResults["shell_run"] = AgentLoopToolExecution(
            result: ToolEnvelope.failure(
                kind: .executionError,
                message: "command failed; correct and retry",
                tool: "shell_run",
                retryable: true
            )
        )
        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(result.exit == .finalResponse)
        #expect(surface.builtNotices.count == 2)
    }

    @Test func identicalRepeatedFailureIsTerminal() {
        let result = ToolEnvelope.failure(
            kind: .invalidArgs,
            message: "missing path",
            tool: "file_read",
            retryable: true
        )
        let outcome = AgentLoopToolOutcome(
            invocation: inv("file_read"),
            callId: "repeat",
            result: result,
            wasDeduped: true,
            wasError: true
        )
        #expect(AgentToolLoop.shouldStopAfterToolOutcome(outcome))
    }

    @Test func terminalComputerUseEnvelopeStopsChatWithoutParentFollowUp() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("computer_use")]),
            .toolCalls([inv("computer_use")]),
        ])
        surface.toolResults["computer_use"] = AgentLoopToolExecution(
            result: ToolEnvelope.failure(
                kind: .executionError,
                message: "The model could not produce a valid action.",
                tool: "computer_use",
                retryable: false
            ),
            isError: false
        )

        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )

        #expect(result == AgentToolLoop.RunResult(exit: .toolRejected, iterations: 1))
        #expect(surface.executedCalls.map(\.name) == ["computer_use"])
    }

    @Test func terminalMacQueryEnvelopeStopsChatBeforeHallucinatedAnswer() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("mac_query")]),
            .finalResponse,
        ])
        surface.toolResults["mac_query"] = AgentLoopToolExecution(
            result: ToolEnvelope.failure(
                kind: .executionError,
                message: "The query failed.",
                tool: "mac_query",
                retryable: false
            ),
            isError: false
        )

        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )

        #expect(result == AgentToolLoop.RunResult(exit: .toolRejected, iterations: 1))
        #expect(surface.builtNotices.count == 1, "No second model iteration may fabricate a value")
    }

    @Test func batchExecutorMarksReturnedTerminalDesktopFailureAsRejection() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("mac_query")]),
            .finalResponse,
        ])
        var hooks = surface.makeHooks()
        hooks.executeBatch = { calls in
            calls.map { call in
                AgentLoopToolExecution(
                    result: ToolEnvelope.failure(
                        kind: .executionError,
                        message: "The query failed.",
                        tool: call.invocation.toolName,
                        retryable: false
                    ),
                    // Mirrors ToolRegistry-returned envelopes in ChatView:
                    // the tool body returned JSON instead of throwing.
                    isError: false
                )
            }
        }

        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: hooks
        )

        #expect(result == AgentToolLoop.RunResult(exit: .toolRejected, iterations: 1))
        #expect(surface.batchOutcomes.count == 1)
        #expect(surface.batchOutcomes[0].map(\.wasError) == [true])
        #expect(surface.builtNotices.count == 1, "The real Chat batch path must not run the parent again")
    }

    @Test func correctableDesktopSubagentFailuresStillReachParentForPivot() async throws {
        for kind in [ToolEnvelope.Kind.invalidArgs, .notFound] {
            let surface = ScriptedLoopSurface(steps: [
                .toolCalls([inv("mac_query")]),
                .finalResponse,
            ])
            surface.toolResults["mac_query"] = AgentLoopToolExecution(
                result: ToolEnvelope.failure(
                    kind: kind,
                    message: "correct this call",
                    tool: "mac_query",
                    retryable: false
                ),
                isError: false
            )

            let result = try await AgentToolLoop.run(
                policy: chatPolicy(),
                state: AgentTaskState(),
                hooks: surface.makeHooks()
            )

            #expect(result.exit == .finalResponse, "kind=\(kind.rawValue)")
            #expect(surface.builtNotices.count == 2, "kind=\(kind.rawValue)")
        }
    }

    @Test func malformedAppleScriptRepeatAfterSuccessFinishesFromRealSummary() async throws {
        let malformed = #"{"_error":"invalid_tool_arguments","_tool":"applescript","_field":"task","_message":"missing required argument: task","_expected":"required parameter"}"#
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("applescript", #"{"task":"Open TextEdit"}"#)]),
            .toolCalls([inv("applescript", malformed)]),
            .toolCalls([inv("never_runs")]),
        ])
        surface.toolResults["applescript"] = AgentLoopToolExecution(
            result: ToolEnvelope.success(
                tool: "applescript",
                result: [
                    "kind": "applescript",
                    "status": "succeeded",
                    "scripts_run": 1,
                    "summary": "Ran 1 script(s) successfully.",
                ]
            )
        )

        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )

        #expect(result == AgentToolLoop.RunResult(exit: .finalResponse, iterations: 2))
        #expect(surface.executedCalls.map(\.name) == ["applescript"])
        #expect(surface.willProcessCallIds.count == 1)
        #expect(surface.emittedFinalTexts == ["Ran 1 script(s) successfully."])
        #expect(surface.steps.count == 1)
    }

    @Test func malformedDesktopCallWithoutMatchingSuccessStillExecutes() async throws {
        let malformed = #"{"_error":"invalid_tool_arguments","_tool":"applescript","_field":"task","_message":"missing required argument: task"}"#
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("file_read", #"{"path":"notes.txt"}"#)]),
            .toolCalls([inv("applescript", malformed)]),
        ])
        surface.toolResults["applescript"] = AgentLoopToolExecution(
            result: ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "missing required argument: task",
                tool: "applescript"
            )
        )

        _ = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )

        #expect(surface.executedCalls.map(\.name) == ["file_read", "applescript"])
        #expect(surface.emittedFinalTexts.isEmpty)
    }

    @Test func malformedDesktopRepeatRecoveryRejectsNearMisses() {
        let state = AgentTaskState()
        state.record(
            name: "applescript",
            argsJSON: #"{"task":"Open TextEdit"}"#,
            result: ToolEnvelope.success(
                tool: "applescript",
                result: ["summary": "Ran 1 script(s) successfully."]
            )
        )

        let wrongField = inv(
            "applescript",
            #"{"_error":"invalid_tool_arguments","_tool":"applescript","_field":"content"}"#
        )
        let wrongToolEnvelope = inv(
            "applescript",
            #"{"_error":"invalid_tool_arguments","_tool":"computer_use","_field":"task"}"#
        )
        let unrelatedTool = inv(
            "file_read",
            #"{"_error":"invalid_tool_arguments","_tool":"file_read","_field":"path"}"#
        )

        #expect(
            AgentToolLoop.completedDesktopSummaryBeforeMalformedRepeat(
                invocation: wrongField,
                state: state
            ) == nil
        )
        #expect(
            AgentToolLoop.completedDesktopSummaryBeforeMalformedRepeat(
                invocation: wrongToolEnvelope,
                state: state
            ) == nil
        )
        #expect(
            AgentToolLoop.completedDesktopSummaryBeforeMalformedRepeat(
                invocation: unrelatedTool,
                state: state
            ) == nil
        )

        let emptySummaryState = AgentTaskState()
        emptySummaryState.record(
            name: "applescript",
            argsJSON: #"{"task":"Open TextEdit"}"#,
            result: ToolEnvelope.success(tool: "applescript", result: ["summary": "  "])
        )
        let exactMalformed = inv(
            "applescript",
            #"{"_error":"invalid_tool_arguments","_tool":"applescript","_field":"task"}"#
        )
        #expect(
            AgentToolLoop.completedDesktopSummaryBeforeMalformedRepeat(
                invocation: exactMalformed,
                state: emptySummaryState
            ) == nil
        )
    }

    @Test func malformedAppleScriptRepeatStillExecutesOnHeadlessSurface() async throws {
        let malformed = #"{"_error":"invalid_tool_arguments","_tool":"applescript","_field":"task"}"#
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("applescript", #"{"task":"Open TextEdit"}"#)]),
            .toolCalls([inv("applescript", malformed)]),
            .finalResponse,
        ])
        surface.toolResults["applescript"] = AgentLoopToolExecution(
            result: ToolEnvelope.success(
                tool: "applescript",
                result: ["summary": "Ran 1 script(s) successfully."]
            )
        )

        let result = try await AgentToolLoop.run(
            policy: headlessPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks(includeFallbackText: false)
        )

        #expect(result == AgentToolLoop.RunResult(exit: .finalResponse, iterations: 3))
        #expect(surface.executedCalls.map(\.name) == ["applescript", "applescript"])
        #expect(surface.emittedFinalTexts.isEmpty)
    }

    @Test func unrelatedNonretryableExecutionFailureKeepsExistingPivotBehavior() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("file_read")]),
            .finalResponse,
        ])
        surface.toolResults["file_read"] = AgentLoopToolExecution(
            result: ToolEnvelope.failure(
                kind: .executionError,
                message: "read failed",
                tool: "file_read",
                retryable: false
            ),
            isError: false
        )

        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )

        #expect(result.exit == .finalResponse)
        #expect(surface.builtNotices.count == 2)
    }

    @Test func surfaceInterceptEndsRunWithoutRecording() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("complete", #"{"summary":"done the work"}"#), inv("never_runs")])
        ])
        surface.toolResults["complete"] = AgentLoopToolExecution(
            result: ToolEnvelope.success(tool: "complete", text: "done the work"),
            endRun: true
        )
        let state = AgentTaskState()
        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: state,
            hooks: surface.makeHooks()
        )
        #expect(result == AgentToolLoop.RunResult(exit: .endedBySurface, iterations: 1))
        #expect(surface.executedCalls.map(\.name) == ["complete"])
        // Intercepts end the run BEFORE the call is recorded.
        #expect(state.lastResultEnvelope == nil)
    }

    @Test func cancellationStopsBetweenToolCalls() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("first_tool"), inv("second_tool")])
        ])
        surface.toolResults["first_tool"] = AgentLoopToolExecution(
            result: ToolEnvelope.success(tool: "first_tool", text: "ok")
        )
        let hooks = surface.makeHooks()
        var mutatedHooks = hooks
        mutatedHooks.executeTool = { inv, callId in
            let execution = await hooks.executeTool(inv, callId)
            surface.cancelled = true  // user hits Stop mid-execution
            return execution
        }
        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: mutatedHooks
        )
        #expect(result == AgentToolLoop.RunResult(exit: .cancelled, iterations: 1))
        #expect(surface.executedCalls.map(\.name) == ["first_tool"])
    }

    @Test func cancellationBeforeFirstIteration() async throws {
        let surface = ScriptedLoopSurface(steps: [.finalResponse])
        surface.cancelled = true
        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(result == AgentToolLoop.RunResult(exit: .cancelled, iterations: 0))
        #expect(surface.builtNotices.isEmpty)
    }

    @Test func transientRetryDoesNotChargeBudget() async throws {
        // 3 iterations of budget; retries interleaved. The run must still
        // complete because retries are not charged.
        let surface = ScriptedLoopSurface(steps: [
            .retryWithoutCharge,
            .toolCalls([inv("tool_a")]),
            .retryWithoutCharge,
            .toolCalls([inv("tool_b")]),
            .finalResponse,
        ])
        let result = try await AgentToolLoop.run(
            policy: chatPolicy(maxIterations: 3),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(result.exit == .finalResponse)
        #expect(result.iterations == 3)
        #expect(surface.executedCalls.map(\.name) == ["tool_a", "tool_b"])
        // buildMessages ran 5 times (every attempt), but only 3 charged.
        #expect(surface.builtNotices.count == 5)
    }

    @Test func nextStepBiasStagedAfterWandering() async throws {
        // Two consecutive listings without a read trip the reactive
        // listing nudge; the third model step must receive it.
        let listing = ToolEnvelope.listing(
            tool: "file_search",
            path: ".",
            entries: [["name": "a.txt", "path": "a.txt", "type": "file"]],
            truncated: false
        )
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("file_search", #"{"path":"."}"#)]),
            .toolCalls([inv("file_search", #"{"path":"sub"}"#)]),
            .finalResponse,
        ])
        surface.toolResults["file_search"] = AgentLoopToolExecution(result: listing)

        _ = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(surface.builtNotices[0].isEmpty)
        #expect(surface.builtNotices[1].isEmpty)
        #expect(surface.builtNotices[2].count == 1)
        #expect(surface.builtNotices[2][0].hasPrefix("[System Notice] "))
        #expect(surface.builtNotices[2][0].contains("result.entries"))
    }

    @Test func batchExecutorSlotsDedupesAndPreservesOrder() async throws {
        // Slotting mode (HTTP semantics): the dedupe pass fills held slots
        // first, the batch executor runs the rest, and outcomes come back
        // in original model order with deduped entries interleaved.
        let readArgs = #"{"path":"a.txt"}"#
        let readEnvelope = ToolEnvelope.success(
            tool: "file_read",
            result: ["kind": "file", "path": "a.txt", "content": "hi"]
        )
        let state = AgentTaskState()
        state.record(name: "file_read", argsJSON: readArgs, result: readEnvelope)

        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([
                inv("tool_one"),
                inv("file_read", readArgs),  // held → deduped slot
                inv("tool_two"),
            ]),
            .finalResponse,
        ])
        var batchCalls: [[String]] = []
        var hooks = surface.makeHooks()
        hooks.executeBatch = { calls in
            batchCalls.append(calls.map { $0.invocation.toolName })
            // Return results in input order, as the contract requires.
            return calls.map {
                AgentLoopToolExecution(
                    result: ToolEnvelope.success(tool: $0.invocation.toolName, text: "ran")
                )
            }
        }

        let result = try await AgentToolLoop.run(
            policy: headlessPolicy(),
            state: state,
            hooks: hooks
        )
        #expect(result.exit == .finalResponse)
        // Only the non-held calls reached the batch executor.
        #expect(batchCalls == [["tool_one", "tool_two"]])
        // The serial executeTool hook was bypassed.
        #expect(surface.executedCalls.isEmpty)
        // Outcomes preserve model order with the dedupe interleaved.
        #expect(surface.batchOutcomes.count == 1)
        #expect(
            surface.batchOutcomes[0].map { $0.invocation.toolName } == [
                "tool_one", "file_read", "tool_two",
            ]
        )
        #expect(surface.batchOutcomes[0].map(\.wasDeduped) == [false, true, false])
        // willProcessCall fired for every slot, dedupe included.
        #expect(surface.willProcessCallIds.count == 3)
        // Held replay surfaced through the dedupe hook.
        #expect(surface.dedupedCalls.map(\.name) == ["file_read"])
    }

    @Test func batchExecutorEndRunInterceptsInModelOrder() async throws {
        // A surface intercept (chat `complete`) riding through the batch
        // path must end the run without recording the intercepted call;
        // earlier outcomes in the batch stay recorded.
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("file_read", #"{"path":"a"}"#), inv("complete", #"{"summary":"done"}"#)])
        ])
        let state = AgentTaskState()
        var hooks = surface.makeHooks()
        hooks.executeBatch = { calls in
            calls.map { call in
                AgentLoopToolExecution(
                    result: ToolEnvelope.success(tool: call.invocation.toolName, text: "ok"),
                    endRun: call.invocation.toolName == "complete"
                )
            }
        }
        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: state,
            hooks: hooks
        )
        #expect(result == AgentToolLoop.RunResult(exit: .endedBySurface, iterations: 1))
        // The earlier call WAS recorded; the intercept was not (the last
        // recorded envelope belongs to file_read).
        #expect(state.lastResultEnvelope?.contains("file_read") == true)
        // Batch-complete still fires on the intercept exit so per-batch
        // surfaces (HTTP) keep the executed rows; the intercept slot is
        // excluded (it wrote its own history).
        #expect(surface.batchOutcomes.count == 1)
        #expect(surface.batchOutcomes[0].map { $0.invocation.toolName } == ["file_read"])
    }

    @Test func batchExecutorRejectionStopsRunUnderChatPolicy() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("good_tool"), inv("denied_tool")])
        ])
        var hooks = surface.makeHooks()
        hooks.executeBatch = { calls in
            calls.map { call in
                if call.invocation.toolName == "denied_tool" {
                    return AgentLoopToolExecution(
                        result: ToolEnvelope.failure(kind: .userDenied, message: "no", tool: "denied_tool"),
                        isError: true
                    )
                }
                return AgentLoopToolExecution(
                    result: ToolEnvelope.success(tool: call.invocation.toolName, text: "ok")
                )
            }
        }
        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: hooks
        )
        #expect(result == AgentToolLoop.RunResult(exit: .toolRejected, iterations: 1))
        // Batch-complete still fires so per-batch surfaces (HTTP) keep the
        // executed rows even on the rejection exit.
        #expect(surface.batchOutcomes.count == 1)
        #expect(surface.batchOutcomes[0].map(\.wasError) == [false, true])
    }

    @Test func batchExecutorDedupesDuplicateReadSiblingsWithinOneBatch() async throws {
        // Two identical reads in ONE model step: serial mode executes the
        // first and replays the second from the freshly recorded state.
        // Batch mode must match — the duplicate sibling is deferred past
        // the parallel wave and replayed in the in-order pass.
        let args = #"{"path":"a.txt"}"#
        let envelope = ToolEnvelope.success(
            tool: "file_read",
            result: ["kind": "file", "path": "a.txt", "content": "hi"]
        )
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("file_read", args), inv("other_tool"), inv("file_read", args)]),
            .finalResponse,
        ])
        var batchCalls: [[String]] = []
        var hooks = surface.makeHooks()
        hooks.executeBatch = { calls in
            batchCalls.append(calls.map { $0.invocation.toolName })
            return calls.map { call in
                AgentLoopToolExecution(
                    result: call.invocation.toolName == "file_read"
                        ? envelope
                        : ToolEnvelope.success(tool: call.invocation.toolName, text: "ok")
                )
            }
        }
        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: hooks
        )
        #expect(result.exit == .finalResponse)
        // Only ONE file_read reached the executor; the duplicate replayed.
        #expect(batchCalls == [["file_read", "other_tool"]])
        #expect(surface.dedupedCalls.map(\.name) == ["file_read"])
        #expect(surface.dedupedCalls.first?.held == envelope)
        // Outcomes preserve model order with the replay in its slot.
        #expect(
            surface.batchOutcomes[0].map { $0.invocation.toolName } == [
                "file_read", "other_tool", "file_read",
            ]
        )
        #expect(surface.batchOutcomes[0].map(\.wasDeduped) == [false, false, true])
    }

    @Test func batchExecutorBoundsIdenticalTransientExtractionRetries() async throws {
        let args = #"{"url":"https://example.com/slow"}"#
        let transient = SearchAndExtractTool.extractionEnvelope(
            payload: [
                "mode": "direct_url",
                "provider": "direct_url",
                "results": [
                    [
                        "url": "https://example.com/slow",
                        "extracted": false,
                        "extract_status": "timeout",
                    ],
                ],
            ]
        )
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([
                inv("search_and_extract", args),
                inv("search_and_extract", args),
                inv("search_and_extract", args),
            ]),
            .finalResponse,
        ])
        var executed = 0
        var hooks = surface.makeHooks()
        hooks.executeBatch = { calls in
            executed += calls.count
            return calls.map { _ in AgentLoopToolExecution(result: transient) }
        }

        let result = try await AgentToolLoop.run(
            policy: headlessPolicy(),
            state: AgentTaskState(),
            hooks: hooks
        )

        #expect(result.exit == .finalResponse)
        #expect(executed == 2, "initial fetch plus one retry; third call must replay")
        #expect(surface.batchOutcomes[0].map(\.wasDeduped) == [false, false, true])
        #expect(surface.batchOutcomes[0][2].result.contains(#""retry_exhausted":true"#))
    }

    @Test func batchExecutorDuplicateSiblingReplaysHeldNotFoundError() async throws {
        // Serial parity with held-error replay: a `not_found` from
        // `file_read` is DETERMINISTIC (nothing wrote between the two
        // calls), so the identical sibling replays the held error instead
        // of re-executing — the duplicate cannot succeed where the first
        // call just failed.
        let args = #"{"path":"missing.txt"}"#
        let failure = ToolEnvelope.failure(kind: .notFound, message: "gone", tool: "file_read")
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("file_read", args), inv("file_read", args)]),
            .finalResponse,
        ])
        var batchCalls: [[String]] = []
        var hooks = surface.makeHooks()
        hooks.executeBatch = { calls in
            batchCalls.append(calls.map { $0.invocation.toolName })
            return calls.map { _ in AgentLoopToolExecution(result: failure, isError: false) }
        }
        let result = try await AgentToolLoop.run(
            policy: headlessPolicy(),
            state: AgentTaskState(),
            hooks: hooks
        )
        #expect(result.exit == .finalResponse)
        // Wave 1 ran the first; the deferred duplicate resolved against the
        // live state in the in-order pass and replayed the held error.
        #expect(batchCalls == [["file_read"]])
        #expect(surface.dedupedCalls.map(\.name) == ["file_read"])
        #expect(surface.dedupedCalls.first?.held == failure)
        #expect(surface.batchOutcomes[0].map(\.wasDeduped) == [false, true])
    }

    @Test func batchExecutorNonReadDuplicatesAllExecute() async throws {
        // Identical write/exec calls re-execute by design (they may
        // legitimately differ); only read-like tools dedupe in-batch.
        let args = #"{"cmd":"date"}"#
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("shell_run", args), inv("shell_run", args)]),
            .finalResponse,
        ])
        var batchCalls: [[String]] = []
        var hooks = surface.makeHooks()
        hooks.executeBatch = { calls in
            batchCalls.append(calls.map { $0.invocation.toolName })
            return calls.map {
                AgentLoopToolExecution(result: ToolEnvelope.success(tool: $0.invocation.toolName, text: "ok"))
            }
        }
        let result = try await AgentToolLoop.run(
            policy: headlessPolicy(),
            state: AgentTaskState(),
            hooks: hooks
        )
        #expect(result.exit == .finalResponse)
        #expect(batchCalls == [["shell_run", "shell_run"]])
        #expect(surface.dedupedCalls.isEmpty)
    }

    @Test func batchExecutorSuppressesExactDuplicateAppendSibling() async throws {
        let args = #"{"path":"notes.txt","content":"SECOND\n","mode":"append"}"#
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("file_write", args), inv("file_write", args)]),
            .finalResponse,
        ])
        var batchCalls: [[String]] = []
        var hooks = surface.makeHooks()
        hooks.executeBatch = { calls in
            batchCalls.append(calls.map { $0.invocation.toolName })
            return calls.map {
                AgentLoopToolExecution(
                    result: ToolEnvelope.success(
                        tool: $0.invocation.toolName,
                        result: [
                            "action": "update",
                            "applied": true,
                            "path": "notes.txt",
                            "mode": "append",
                        ] as [String: Any]
                    )
                )
            }
        }

        let result = try await AgentToolLoop.run(
            policy: headlessPolicy(),
            state: AgentTaskState(),
            hooks: hooks
        )

        #expect(result.exit == .finalResponse)
        #expect(batchCalls == [["file_write"]])
        #expect(surface.dedupedCalls.map(\.name) == ["file_write"])
        #expect(surface.batchOutcomes[0].map(\.wasDeduped) == [false, true])
    }

    @Test func batchExecutorShortReturnTreatsMissingSlotsAsNeverExecuted() async throws {
        // The executor may return FEWER results than calls (chat stops
        // executing the rest of a batch after an intercept). Missing slots
        // must be excluded from outcomes/recording, not crash the zip.
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("complete", #"{"summary":"done"}"#), inv("never_ran")])
        ])
        let state = AgentTaskState()
        var hooks = surface.makeHooks()
        hooks.executeBatch = { _ in
            // Only the first call executed (it intercepted).
            [
                AgentLoopToolExecution(
                    result: ToolEnvelope.success(tool: "complete", text: "done"),
                    endRun: true
                )
            ]
        }
        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: state,
            hooks: hooks
        )
        #expect(result == AgentToolLoop.RunResult(exit: .endedBySurface, iterations: 1))
        // Nothing recorded: the intercept is never recorded, and the
        // missing slot never executed.
        #expect(state.lastResultEnvelope == nil)
        // Batch-complete fired with no completed outcomes.
        #expect(surface.batchOutcomes.count == 1)
        #expect(surface.batchOutcomes[0].isEmpty)
    }

    @Test func batchExecutorRecordsBeforeHonoringCancellation() async throws {
        // Cancellation lands mid-batch: the executed outcomes are already
        // in surface history, so they must be recorded into the state
        // machine before the run exits `.cancelled`.
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("tool_a")])
        ])
        let state = AgentTaskState()
        var hooks = surface.makeHooks()
        hooks.executeBatch = { calls in
            surface.cancelled = true  // user hits Stop mid-execution
            return calls.map {
                AgentLoopToolExecution(result: ToolEnvelope.success(tool: $0.invocation.toolName, text: "ok"))
            }
        }
        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: state,
            hooks: hooks
        )
        #expect(result == AgentToolLoop.RunResult(exit: .cancelled, iterations: 1))
        #expect(state.lastResultEnvelope != nil)
        // Batch-complete fired so per-batch surfaces keep the row.
        #expect(surface.batchOutcomes.count == 1)
    }

    @Test func serialModeRecordsBeforeHonoringCancellation() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("tool_a"), inv("tool_b")])
        ])
        let state = AgentTaskState()
        let hooks = surface.makeHooks()
        var mutatedHooks = hooks
        mutatedHooks.executeTool = { inv, callId in
            let execution = await hooks.executeTool(inv, callId)
            surface.cancelled = true
            return execution
        }
        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: state,
            hooks: mutatedHooks
        )
        #expect(result == AgentToolLoop.RunResult(exit: .cancelled, iterations: 1))
        // The executed call WAS recorded before the cancelled exit.
        #expect(state.lastResultEnvelope != nil)
        #expect(surface.executedCalls.map(\.name) == ["tool_a"])
    }

    @Test func modelStepErrorsPropagateToCaller() async {
        struct FakeProviderError: Error {}
        let surface = ScriptedLoopSurface(steps: [])
        var hooks = surface.makeHooks()
        hooks.modelStep = { _, _ in throw FakeProviderError() }
        await #expect(throws: FakeProviderError.self) {
            _ = try await AgentToolLoop.run(
                policy: chatPolicy(),
                state: AgentTaskState(),
                hooks: hooks
            )
        }
    }
}

// MARK: - Default parallel batch executor

/// Records completion order across concurrent tasks.
private actor CompletionRecorder {
    private(set) var order: [String] = []
    private struct Waiter {
        var id: UUID
        var names: Set<String>
        var continuation: CheckedContinuation<Bool, Never>
    }
    private var waiters: [Waiter] = []

    func record(_ name: String) {
        order.append(name)
        resumeSatisfiedWaiters()
    }

    func waitForCompletions(_ names: Set<String>, timeoutNanoseconds: UInt64) async -> Bool {
        let completed = Set(order)
        if names.isSubset(of: completed) { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiters.append(Waiter(id: id, names: names, continuation: continuation))
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                await self.resumeWaiter(id: id, value: false)
            }
        }
    }

    private func resumeSatisfiedWaiters() {
        let completed = Set(order)
        var pending: [Waiter] = []
        for waiter in waiters {
            if waiter.names.isSubset(of: completed) {
                waiter.continuation.resume(returning: true)
            } else {
                pending.append(waiter)
            }
        }
        waiters = pending
    }

    private func resumeWaiter(id: UUID, value: Bool) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: value)
    }
}

/// Lets tests measure overlap without relying on task-start jitter.
private actor BatchStartBarrier {
    private let expectedCount: Int
    private var started: Set<String> = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(expectedCount: Int) {
        self.expectedCount = expectedCount
    }

    func waitForAllStarted(_ name: String) async {
        started.insert(name)
        if started.count >= expectedCount {
            releaseWaiters()
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            if started.count >= expectedCount {
                releaseWaiters()
            }
        }
    }

    private func releaseWaiters() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

/// Releases batch calls in a deterministic completion order once all tasks are parked.
private actor BatchCompletionController {
    private let expectedNames: Set<String>
    private var started: Set<String> = []
    private var released: Set<String> = []
    private var completed: [String] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var completionWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(expectedNames: Set<String>) {
        self.expectedNames = expectedNames
    }

    var completionOrder: [String] { completed }

    func markStarted(_ name: String) {
        started.insert(name)
        if expectedNames.isSubset(of: started) {
            releaseStartWaiters()
        }
    }

    func waitForAllStarted() async {
        if expectedNames.isSubset(of: started) {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
            if expectedNames.isSubset(of: started) {
                releaseStartWaiters()
            }
        }
    }

    func waitForRelease(_ name: String) async {
        if released.contains(name) {
            return
        }
        await withCheckedContinuation { continuation in
            releaseWaiters[name, default: []].append(continuation)
            if released.contains(name) {
                releaseWaiters.removeValue(forKey: name)?.forEach { $0.resume() }
            }
        }
    }

    func release(_ name: String) {
        released.insert(name)
        releaseWaiters.removeValue(forKey: name)?.forEach { $0.resume() }
    }

    func markCompleted(_ name: String) {
        completed.append(name)
        releaseCompletionWaiters()
    }

    func waitForCompletedCount(_ count: Int) async {
        if completed.count >= count {
            return
        }
        await withCheckedContinuation { continuation in
            completionWaiters.append((count, continuation))
            releaseCompletionWaiters()
        }
    }

    private func releaseStartWaiters() {
        let pending = startWaiters
        startWaiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    private func releaseCompletionWaiters() {
        let ready = completionWaiters.filter { completed.count >= $0.0 }
        completionWaiters.removeAll { completed.count >= $0.0 }
        for waiter in ready {
            waiter.1.resume()
        }
    }
}

struct AgentToolLoopParallelBatchTests {

    @Test func resultsComeBackInInputOrderUnderRandomCompletion() async {
        // slow finishes LAST but is FIRST in the input; the executor must
        // re-sort by input index, not completion order.
        let calls: [(invocation: ServiceToolInvocation, callId: String)] = [
            (ServiceToolInvocation(toolName: "slow", jsonArguments: "{}", toolCallId: nil), "call_slow"),
            (ServiceToolInvocation(toolName: "fast", jsonArguments: "{}", toolCallId: nil), "call_fast"),
            (ServiceToolInvocation(toolName: "medium", jsonArguments: "{}", toolCallId: nil), "call_med"),
        ]
        let controller = BatchCompletionController(expectedNames: Set(calls.map { $0.invocation.toolName }))
        let batchTask = Task {
            await AgentToolLoop.runBatchInParallel(calls) { invocation, _ in
                await controller.markStarted(invocation.toolName)
                await controller.waitForRelease(invocation.toolName)
                await controller.markCompleted(invocation.toolName)
                return "ran:\(invocation.toolName)"
            }
        }

        await controller.waitForAllStarted()
        await controller.release("fast")
        await controller.waitForCompletedCount(1)
        await controller.release("medium")
        await controller.waitForCompletedCount(2)
        await controller.release("slow")
        let executions = await batchTask.value

        #expect(executions.map(\.result) == ["ran:slow", "ran:fast", "ran:medium"])
        #expect(executions.allSatisfy { !$0.isError })
        // The calls actually overlapped: fast completed before slow.
        #expect(await controller.completionOrder == ["fast", "medium", "slow"])
    }

    @Test func throwingCallBecomesErrorEnvelopeWithoutAbortingBatch() async {
        struct BatchToolError: Error {}
        let calls: [(invocation: ServiceToolInvocation, callId: String)] = [
            (ServiceToolInvocation(toolName: "good_a", jsonArguments: "{}", toolCallId: nil), "c1"),
            (ServiceToolInvocation(toolName: "explodes", jsonArguments: "{}", toolCallId: nil), "c2"),
            (ServiceToolInvocation(toolName: "good_b", jsonArguments: "{}", toolCallId: nil), "c3"),
        ]
        let executions = await AgentToolLoop.runBatchInParallel(calls) { invocation, _ in
            if invocation.toolName == "explodes" { throw BatchToolError() }
            return "ok:\(invocation.toolName)"
        }

        #expect(executions.count == 3)
        #expect(executions.map(\.isError) == [false, true, false])
        #expect(executions[0].result == "ok:good_a")
        #expect(executions[2].result == "ok:good_b")
        #expect(ToolEnvelope.isError(executions[1].result))
    }

    @Test func singleCallExecutesSeriallyInline() async {
        let calls: [(invocation: ServiceToolInvocation, callId: String)] = [
            (ServiceToolInvocation(toolName: "only", jsonArguments: "{}", toolCallId: nil), "call_only")
        ]
        let executions = await AgentToolLoop.runBatchInParallel(calls) { invocation, callId in
            "ran:\(invocation.toolName):\(callId)"
        }
        #expect(executions.count == 1)
        #expect(executions[0].result == "ran:only:call_only")
        #expect(!executions[0].isError)
    }

    @Test func emptyBatchReturnsEmpty() async {
        let executions = await AgentToolLoop.runBatchInParallel([]) { _, _ in "unreachable" }
        #expect(executions.isEmpty)
    }

    @Test func samePathMutationsSerializeInModelOrder() async {
        // Two writes to the SAME path must not overlap (lost-update guard):
        // the first is slow, the second fast — serialized execution means
        // the slow one still completes first. The distinct-path write keeps
        // running in parallel (it completes before the slow same-path one).
        let recorder = CompletionRecorder()
        let calls: [(invocation: ServiceToolInvocation, callId: String)] = [
            (
                ServiceToolInvocation(
                    toolName: "file_write",
                    jsonArguments: #"{"path":"src/app.py","content":"slow"}"#,
                    toolCallId: nil
                ), "c1"
            ),
            (
                ServiceToolInvocation(
                    toolName: "file_edit",
                    jsonArguments: #"{"path":"./src/app.py","old_string":"a","new_string":"b"}"#,
                    toolCallId: nil
                ), "c2"
            ),
            (
                ServiceToolInvocation(
                    toolName: "file_write",
                    jsonArguments: #"{"path":"other.py","content":"x"}"#,
                    toolCallId: nil
                ), "c3"
            ),
        ]
        let executions = await AgentToolLoop.runBatchInParallel(calls) { invocation, callId in
            if callId == "c1" {
                try? await Task.sleep(nanoseconds: 100 * 1_000_000)
            }
            await recorder.record(callId)
            return "ran:\(callId)"
        }

        #expect(executions.map(\.result) == ["ran:c1", "ran:c2", "ran:c3"])
        let completion = await recorder.order
        // Same-path serialization: c2 only ran after c1 finished, even
        // though c1 was slow. The unrelated path (c3) overlapped freely.
        #expect(completion.firstIndex(of: "c1")! < completion.firstIndex(of: "c2")!)
        #expect(completion.first == "c3")
    }

    @Test func pathSerializationKeyNormalizesEquivalentPaths() {
        let write = ServiceToolInvocation(
            toolName: "file_write",
            jsonArguments: #"{"path":"src/app.py"}"#,
            toolCallId: nil
        )
        let edit = ServiceToolInvocation(
            toolName: "file_edit",
            jsonArguments: #"{"path":"./src/app.py"}"#,
            toolCallId: nil
        )
        let read = ServiceToolInvocation(
            toolName: "file_read",
            jsonArguments: #"{"path":"src/app.py"}"#,
            toolCallId: nil
        )
        #expect(AgentToolLoop.pathSerializationKey(for: write) != nil)
        #expect(
            AgentToolLoop.pathSerializationKey(for: write)
                == AgentToolLoop.pathSerializationKey(for: edit)
        )
        // Reads never serialize.
        #expect(AgentToolLoop.pathSerializationKey(for: read) == nil)
    }

    @Test func cancelledTaskSkipsUnstartedBatchCalls() async {
        // Cooperative cancellation: children check `Task.isCancelled`
        // before dispatching, so a Stop / disconnect that cancels the
        // surrounding task yields paired "cancelled" envelopes instead of
        // firing the tools.
        actor RunCounter {
            private(set) var count = 0
            func bump() { count += 1 }
        }
        let counter = RunCounter()
        let calls: [(invocation: ServiceToolInvocation, callId: String)] = [
            (ServiceToolInvocation(toolName: "a", jsonArguments: "{}", toolCallId: nil), "c1"),
            (ServiceToolInvocation(toolName: "b", jsonArguments: "{}", toolCallId: nil), "c2"),
        ]
        let task = Task { () -> [AgentLoopToolExecution] in
            // Wait until the cancel below has landed, then run the batch
            // inside the (now-cancelled) task.
            while !Task.isCancelled { await Task.yield() }
            return await AgentToolLoop.runBatchInParallel(calls) { _, _ in
                await counter.bump()
                return "ran"
            }
        }
        task.cancel()
        let executions = await task.value

        #expect(executions.count == 2)
        #expect(executions.allSatisfy { ToolEnvelope.isError($0.result) })
        #expect(executions.allSatisfy { $0.result.contains("cancelled before") })
        let ran = await counter.count
        #expect(ran == 0)
    }

    @Test func batchBindsSharedBatchIdForUndoGrouping() async {
        // Multi-call batches bind one `ChatExecutionContext.currentBatchId`
        // for the whole wave so the file-operation log can group them.
        actor BatchIds {
            private(set) var ids: [UUID?] = []
            func record(_ id: UUID?) { ids.append(id) }
        }
        let batchIds = BatchIds()
        let calls: [(invocation: ServiceToolInvocation, callId: String)] = [
            (ServiceToolInvocation(toolName: "a", jsonArguments: "{}", toolCallId: nil), "c1"),
            (ServiceToolInvocation(toolName: "b", jsonArguments: "{}", toolCallId: nil), "c2"),
        ]
        _ = await AgentToolLoop.runBatchInParallel(calls) { _, _ in
            await batchIds.record(ChatExecutionContext.currentBatchId)
            return "ok"
        }
        let ids = await batchIds.ids
        #expect(ids.count == 2)
        #expect(ids[0] != nil)
        #expect(ids[0] == ids[1])
    }
}

// MARK: - overBudget exit + budget parity

@MainActor
struct AgentLoopOverBudgetTests {

    @Test func overBudgetEndsRunBeforeModelStep() async throws {
        // `buildMessages` reporting a hard overflow must end the run with
        // the distinct `.overBudget` exit WITHOUT a model step or any
        // tool execution — the request is doomed, don't send it.
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("never_runs")])
        ])
        surface.overBudget = true

        let result = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )

        #expect(result.exit == .overBudget)
        #expect(result.iterations == 0)
        #expect(surface.executedCalls.isEmpty)
        // The scripted model step was never consumed.
        #expect(surface.steps.count == 1)
    }

    @Test func composeIterationMessagesReportsHardOverflow() {
        // A transcript whose protected first message + tail alone exceed
        // the history budget must come back flagged `overBudget`.
        let manager = ContextBudgetManager(contextLength: 100)
        let huge = String(repeating: "x", count: 20_000)
        let messages = [
            ChatMessage(role: "system", content: "sys"),
            ChatMessage(role: "user", content: huge),
            ChatMessage(role: "assistant", content: huge),
            ChatMessage(role: "user", content: huge),
        ]
        let input = AgentLoopBudget.composeIterationMessages(
            messages,
            notices: [],
            manager: manager
        )
        #expect(input.overBudget)
        #expect(input.messages.first?.role == "system")
    }

    @Test func makeBudgetManagerCapsResponseReservationLikeAssess() {
        // The runtime trim budget and the UI hard gate must reserve the
        // SAME response amount: `max_tokens` capped at a quarter of the
        // effective budget (small-window models would otherwise be
        // permanently gated).
        let window = 4_096
        let effective = ContextBudgetManager(contextLength: window).effectiveBudget
        let expectedReservation = AgentLoopBudget.cappedResponseReservation(
            100_000,
            effectiveBudget: effective
        )
        #expect(expectedReservation == effective / 4)

        // A manager built with an oversized max_tokens must end up with
        // the same history budget as one reserving the capped amount
        // directly — i.e. the cap was applied, not the raw 100K.
        let capped = AgentLoopBudget.makeBudgetManager(
            contextWindow: window,
            systemPromptChars: 0,
            toolTokens: 0,
            maxResponseTokens: 100_000
        )
        var reference = ContextBudgetManager(contextLength: window)
        reference.reserveByCharCount(.systemPrompt, characters: 0)
        reference.reserve(.tools, tokens: 0)
        reference.reserve(.response, tokens: expectedReservation)
        #expect(capped.historyBudget == reference.historyBudget)
        // And it is strictly larger than what the old uncapped
        // reservation would have left (zero for a 4K window).
        #expect(capped.historyBudget > 0)
    }
}

// MARK: - Todo staleness notice

@MainActor
struct AgentLoopTodoStalenessTests {

    /// With pending todo items and no `todo` call, the driver stages the
    /// staleness nudge after `todoStalenessThreshold` iterations — it
    /// rides the notice channel of the FOLLOWING iteration's build.
    @Test func stalenessNoticeFiresAfterThresholdIterations() async throws {
        let surface = ScriptedLoopSurface(
            steps: (0 ..< 6).map { i in .toolCalls([inv("tool_\(i)")]) } + [.finalResponse]
        )
        surface.pendingTodos = 2
        _ = try await AgentToolLoop.run(
            policy: chatPolicy(),  // threshold defaults to 4
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        // Iterations 1-4 carry no todo call → the notice is staged after
        // iteration 4 and shows up in iteration 5's build. Firing re-arms
        // the window, so iterations 6-7 stay quiet.
        let expected = AgentToolLoop.todoStalenessNotice(pending: 2)
        #expect(surface.builtNotices[4].contains(expected))
        for (index, notices) in surface.builtNotices.enumerated() where index != 4 {
            #expect(!notices.contains(expected), "unexpected staleness notice at build \(index)")
        }
    }

    /// A `todo` call resets the staleness window.
    @Test func todoCallResetsStalenessWindow() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("tool_a")]),
            .toolCalls([inv("tool_b")]),
            .toolCalls([inv("todo", #"{"markdown":"- [x] a\n- [ ] b"}"#)]),
            .toolCalls([inv("tool_c")]),
            .toolCalls([inv("tool_d")]),
            .finalResponse,
        ])
        surface.pendingTodos = 1
        _ = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        let needle = "[System Notice] Your todo list"
        for notices in surface.builtNotices {
            #expect(!notices.contains(where: { $0.hasPrefix(needle) }))
        }
    }

    /// No pending items (or no hook at all) → never nags.
    @Test func noNoticeWithoutPendingItems() async throws {
        let surface = ScriptedLoopSurface(
            steps: (0 ..< 6).map { i in .toolCalls([inv("tool_\(i)")]) } + [.finalResponse]
        )
        surface.pendingTodos = 0
        _ = try await AgentToolLoop.run(
            policy: chatPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        let needle = "[System Notice] Your todo list"
        for notices in surface.builtNotices {
            #expect(!notices.contains(where: { $0.hasPrefix(needle) }))
        }
    }
}

// MARK: - Current-run todo terminal completion


@MainActor
struct AgentLoopAdvisoryTodoCompletionTests {
    @Test func staleSessionTodoCompleteRejectionRecoversToOrdinaryFinal() async throws {
        let sessionId = UUID().uuidString
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([
                inv(
                    "complete",
                    #"{"summary":"STALE_TODO_FOLLOWUP_OK - verified as the requested exact follow-up."}"#
                )
            ]),
            .finalResponse,
        ])

        let result = try await ChatExecutionContext.$currentSessionId.withValue(sessionId) {
            // Persist an unchecked checklist from the prior user turn.
            _ = try await TodoTool().execute(
                argumentsJSON: #"{"markdown":"- [x] report result\n- [ ] optional review"}"#
            )

            var hooks = surface.makeHooks()
            hooks.executeTool = { invocation, callId in
                surface.executedCalls.append(
                    (invocation.toolName, invocation.jsonArguments, callId)
                )
                let result =
                    (try? await CompleteTool().execute(
                        argumentsJSON: invocation.jsonArguments
                    ))
                    ?? ToolEnvelope.failure(
                        kind: .executionError,
                        message: "unexpected complete tool throw",
                        tool: invocation.toolName
                    )
                return AgentLoopToolExecution(result: result)
            }
            return try await AgentToolLoop.run(
                policy: chatPolicy(),
                state: AgentTaskState(),
                hooks: hooks
            )
        }
        await AgentTodoStore.shared.clear(for: sessionId)

        #expect(result == AgentToolLoop.RunResult(exit: .finalResponse, iterations: 2))
        #expect(surface.executedCalls.map(\.name) == ["complete"])
        let completeResult = try #require(surface.batchOutcomes.first?.first?.result)
        #expect(ToolEnvelope.isError(completeResult))
        #expect(AgentToolLoop.isStaleSessionTodoCompleteResult(completeResult))
        #expect(surface.steps.isEmpty)
    }

    @Test func pendingTodoDoesNotOverrideOrdinaryFinal() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("todo", #"{"markdown":"- [ ] inspect\n- [ ] answer"}"#)]),
            .finalResponse,
            .toolCalls([inv("share_artifact", #"{"filename":"unrequested.md"}"#)]),
        ])

        let result = try await AgentToolLoop.run(
            policy: taskTrackingChatPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks(includeTrackedTaskContinuation: true)
        )

        #expect(result == AgentToolLoop.RunResult(exit: .finalResponse, iterations: 2))
        #expect(surface.executedCalls.map(\.name) == ["todo"])
        #expect(surface.trackedTaskContinuationPreparations == 0)
        #expect(surface.todoProgress == AgentTodoProgressSnapshot(done: 0, total: 2))
        #expect(surface.steps.count == 1)
    }

    @Test func reminderSuccessStopsBeforeTodoRewriteAndRepeatedSummaries() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("todo", #"{"markdown":"- [ ] Create reminder"}"#)]),
            .toolCalls([
                inv(
                    "create_reminder",
                    #"{"title":"Send email to Jace","dueDate":"2026-07-27T08:10:00-07:00"}"#
                ),
            ]),
            .finalResponse,
            .toolCalls([inv("todo", #"{"markdown":"- [x] Create reminder\n- [ ] Verify"}"#)]),
            .toolCalls([inv("share_artifact", #"{"filename":"reminder-confirmation.md"}"#)]),
            .finalResponse,
        ])

        let result = try await AgentToolLoop.run(
            policy: taskTrackingChatPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks(includeTrackedTaskContinuation: true)
        )

        #expect(result == AgentToolLoop.RunResult(exit: .finalResponse, iterations: 3))
        #expect(surface.executedCalls.map(\.name) == ["todo", "create_reminder"])
        #expect(surface.trackedTaskContinuationPreparations == 0)
        #expect(surface.steps.count == 3)
    }

    @Test func repeatedTodoCallsAreNotTurnedIntoRetryableErrors() async throws {
        let surface = ScriptedLoopSurface(steps: [
            .toolCalls([inv("todo", #"{"markdown":"- [ ] inspect"}"#)]),
            .toolCalls([inv("todo", #"{"markdown":"- [ ] inspect"}"#)]),
            .finalResponse,
        ])

        let result = try await AgentToolLoop.run(
            policy: taskTrackingChatPolicy(),
            state: AgentTaskState(),
            hooks: surface.makeHooks(includeTrackedTaskContinuation: true)
        )

        #expect(result == AgentToolLoop.RunResult(exit: .finalResponse, iterations: 3))
        #expect(surface.executedCalls.map(\.name) == ["todo", "todo"])
        #expect(!surface.batchOutcomes.flatMap { $0 }.contains(where: {
            AgentToolLoop.isTodoNoProgressResult($0.result)
        }))
    }
}

// MARK: - Watermark identity

struct CompactionWatermarkIdentityTests {

    @Test func sameLengthEditInvalidatesDecisions() {
        // Identity is a CONTENT hash, not a length: a regeneration that
        // happens to produce equal-size text must reset stale decisions
        // instead of replaying them against rewritten content.
        let watermark = CompactionWatermark()
        let original = ChatMessage(role: "user", content: "aaaa")
        watermark.recordDrop(at: 0, original: original)
        #expect(watermark.droppedCount == 1)

        let sameLengthEdit = [ChatMessage(role: "user", content: "bbbb")]
        watermark.validate(against: sameLengthEdit)
        #expect(watermark.droppedCount == 0)
    }

    @Test func identicalContentKeepsDecisions() {
        let watermark = CompactionWatermark()
        let original = ChatMessage(role: "user", content: "stable")
        watermark.recordDrop(at: 0, original: original)

        watermark.validate(against: [ChatMessage(role: "user", content: "stable")])
        #expect(watermark.droppedCount == 1)
    }
}
