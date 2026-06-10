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

    // Recorded crossings
    var builtNotices: [[String]] = []
    var executedCalls: [(name: String, args: String, callId: String)] = []
    var dedupedCalls: [(name: String, callId: String, held: String)] = []
    var willProcessCallIds: [String] = []
    var batchOutcomes: [[AgentLoopToolOutcome]] = []

    init(steps: [AgentLoopModelStep]) {
        self.steps = steps
    }

    func makeHooks() -> AgentLoopHooks {
        AgentLoopHooks(
            isCancelled: { self.cancelled },
            buildMessages: { notices in
                self.builtNotices.append(notices)
                return [ChatMessage(role: "user", content: "task")]
            },
            modelStep: { _, _ in
                guard !self.steps.isEmpty else { return .finalResponse }
                return self.steps.removeFirst()
            },
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
            }
        )
    }
}

private func inv(_ name: String, _ args: String = "{}", callId: String? = nil) -> ServiceToolInvocation {
    ServiceToolInvocation(toolName: name, jsonArguments: args, toolCallId: callId)
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

// MARK: - Tests

@MainActor
struct AgentToolLoopTests {

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

    @Test func batchExecutorDuplicateSiblingExecutesWhenFirstReadFails() async throws {
        // Serial parity: if the first read FAILS, no fresh read is recorded,
        // so the identical sibling re-executes instead of replaying.
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
        // Wave 1 ran the first; the deferred duplicate executed in the
        // in-order pass as a single-call batch.
        #expect(batchCalls == [["file_read"], ["file_read"]])
        #expect(surface.dedupedCalls.isEmpty)
        #expect(surface.batchOutcomes[0].map(\.wasDeduped) == [false, false])
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
    func record(_ name: String) { order.append(name) }
}

struct AgentToolLoopParallelBatchTests {

    @Test func resultsComeBackInInputOrderUnderRandomCompletion() async {
        // slow finishes LAST but is FIRST in the input — the executor must
        // re-sort by input index, not completion order.
        let recorder = CompletionRecorder()
        let calls: [(invocation: ServiceToolInvocation, callId: String)] = [
            (ServiceToolInvocation(toolName: "slow", jsonArguments: "{}", toolCallId: nil), "call_slow"),
            (ServiceToolInvocation(toolName: "fast", jsonArguments: "{}", toolCallId: nil), "call_fast"),
            (ServiceToolInvocation(toolName: "medium", jsonArguments: "{}", toolCallId: nil), "call_med"),
        ]
        let executions = await AgentToolLoop.runBatchInParallel(calls) { invocation, _ in
            let delayMs: UInt64 = invocation.toolName == "slow" ? 120 : invocation.toolName == "medium" ? 60 : 0
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            await recorder.record(invocation.toolName)
            return "ran:\(invocation.toolName)"
        }

        #expect(executions.map(\.result) == ["ran:slow", "ran:fast", "ran:medium"])
        #expect(executions.allSatisfy { !$0.isError })
        // The calls actually overlapped: fast completed before slow.
        let completion = await recorder.order
        #expect(completion.first == "fast")
        #expect(completion.last == "slow")
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
}
