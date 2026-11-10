//
//  ForcedStateStepTests.swift
//  OsaurusCoreTests
//
//  The Orchestrator's forced `state` step: one extra step offering only
//  `state`, on a turn that must record state and is ending without a write.
//  It never runs after Stop, after `clarify`, on a parked `awaiting_user`
//  handoff, or once a write landed.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ForcedStateStepPolicyTests {
    static func tool(_ name: String) -> Tool {
        Tool(type: "function", function: ToolFunction(name: name, description: nil, parameters: nil))
    }

    static let tools = [tool("status"), tool(StateTool.toolName), tool("configurator_handoff")]

    static func force(
        qualifying: Bool = true, interrupted: Bool = false, ending: StateStepEnding = .finalText,
        stateWritten: Bool = false, tools: [Tool] = tools
    ) -> (tools: [Tool], choice: ToolChoiceOption)? {
        ChatToolChoicePolicy.forceStateIfMissing(
            qualifying: qualifying, interrupted: interrupted, lastStepEndedOn: ending, stateWritten: stateWritten,
            tools: tools)
    }

    @Test func aQualifyingTurnEndingInTextGetsOnlyStateForced() throws {
        let forced = try #require(Self.force())
        #expect(forced.tools.map(\.function.name) == [StateTool.toolName])
        guard case .function(let target) = forced.choice else {
            Issue.record("expected a forced function, got \(forced.choice)")
            return
        }
        #expect(target.function.name == StateTool.toolName)
        #expect(Self.force(ending: .iterationCap) != nil, "the step cap gets the same step before its wrap-up")
    }

    @Test func itNeverFiresWhereTheTurnHasNothingToRecord() {
        #expect(Self.force(interrupted: true) == nil, "after Stop")
        #expect(Self.force(ending: .clarify) == nil, "after clarify")
        #expect(Self.force(ending: .awaitingUser) == nil, "on a parked awaiting_user result")
        #expect(Self.force(stateWritten: true) == nil, "after a state write landed")
        #expect(Self.force(qualifying: false) == nil, "on an ordinary turn")
        #expect(Self.force(tools: [Self.tool("status")]) == nil, "when state is not offered")
    }
}

/// The loop, driven like chat: the hook decides with the same inputs
/// `ChatView` passes, and the model step offers what the hook armed.
@MainActor
@Suite(.serialized)
struct ForcedStateStepLoopTests {
    @MainActor
    final class Surface {
        var steps: [AgentLoopModelStep]
        var presenting = true
        var interrupted = false
        var cancelled = false
        var cancelDuringFirstStep = false
        var lastHandoff: HandoffResult?
        var stateWritten = false
        var forced: (tools: [Tool], choice: ToolChoiceOption)?
        var results: [String: AgentLoopToolExecution] = [:]

        var offered: [[String]] = []
        var choices: [ToolChoiceOption?] = []
        var executed: [String] = []
        var asked: [StateStepEnding] = []

        init(_ steps: [AgentLoopModelStep]) { self.steps = steps }

        func run(maxIterations: Int = 8) async throws -> AgentToolLoop.RunResult {
            var hooks = AgentLoopHooks(
                isCancelled: { self.cancelled },
                buildMessages: { _ in AgentLoopIterationInput(messages: [ChatMessage(role: "user", content: "x")]) },
                modelStep: { _, _ in
                    self.offered.append(
                        self.forced?.tools.map(\.function.name) ?? ForcedStateStepPolicyTests.tools.map(\.function.name))
                    self.choices.append(self.forced?.choice)
                    if self.cancelDuringFirstStep, self.offered.count == 1 {
                        self.interrupted = true
                        self.cancelled = true
                    }
                    return self.steps.isEmpty ? .finalResponse : self.steps.removeFirst()
                },
                executeTool: { invocation, _ in
                    self.executed.append(invocation.toolName)
                    let result =
                        self.results[invocation.toolName]
                        ?? AgentLoopToolExecution(result: ToolEnvelope.success(tool: invocation.toolName, text: "ok"))
                    if invocation.toolName == StateTool.toolName { self.stateWritten = true }
                    if let handoff = HandoffResult.parse(envelope: result.result) { self.lastHandoff = handoff }
                    return result
                },
                onBatchComplete: { _ in }
            )
            hooks.armForcedStateStep = { ending in
                self.asked.append(ending)
                var lastStep = ending
                if ending == .finalText, case .awaitingUser? = self.lastHandoff { lastStep = .awaitingUser }
                self.forced = ChatToolChoicePolicy.forceStateIfMissing(
                    qualifying: self.presenting || self.lastHandoff != nil, interrupted: self.interrupted,
                    lastStepEndedOn: lastStep, stateWritten: self.stateWritten, tools: ForcedStateStepPolicyTests.tools)
                return self.forced != nil
            }
            return try await AgentToolLoop.run(
                policy: AgentLoopPolicy(
                    maxIterations: maxIterations, stopOnToolRejection: true, dedupeNoticeEnabled: false,
                    wrapsUpIncompleteWork: true),
                state: AgentTaskState(), hooks: hooks)
        }
    }

    static func call(_ name: String, _ args: String = "{}") -> ServiceToolInvocation {
        ServiceToolInvocation(toolName: name, jsonArguments: args, toolCallId: "call_\(name)_\(UUID().uuidString.prefix(4))")
    }

    @Test func thePresentingTurnWithoutAWriteTakesExactlyOneForcedStep() async throws {
        let surface = Surface([.finalResponse, .toolCalls([Self.call(StateTool.toolName)])])
        let result = try await surface.run()
        #expect(result.exit == .finalResponse)
        #expect(surface.offered.count == 2)
        #expect(surface.offered.last == [StateTool.toolName])
        if case .function(let target)?? = surface.choices.last {
            #expect(target.function.name == StateTool.toolName)
        } else {
            Issue.record("the extra step did not force state: \(surface.choices)")
        }
        #expect(surface.executed == [StateTool.toolName])
        #expect(surface.asked == [.finalText], "asked once")
    }

    @Test func aStateWriteThatAlreadyLandedTakesNoExtraStep() async throws {
        let surface = Surface([.toolCalls([Self.call(StateTool.toolName)]), .finalResponse])
        let result = try await surface.run()
        #expect(result.exit == .finalResponse)
        #expect(surface.offered.count == 2)
        #expect(surface.executed == [StateTool.toolName])
    }

    @Test func aCancelDuringThePresentingTurnTakesNoExtraStep() async throws {
        let surface = Surface([.finalResponse])
        surface.cancelDuringFirstStep = true
        let result = try await surface.run()
        #expect(result.exit == .cancelled)
        #expect(surface.offered.count == 1)
        #expect(surface.asked.isEmpty)

        // Stopped after the answer landed: the hook sees the interruption.
        let late = Surface([.finalResponse])
        late.interrupted = true
        _ = try await late.run()
        #expect(late.offered.count == 1)
    }

    @Test func aFinalClarifyTakesNoExtraStep() async throws {
        let surface = Surface([.toolCalls([Self.call("clarify", #"{"question":"Which one?"}"#)])])
        surface.results["clarify"] = AgentLoopToolExecution(
            result: ToolEnvelope.success(tool: "clarify", text: "asked"), endRun: true)
        let result = try await surface.run()
        #expect(result.exit == .endedBySurface)
        #expect(surface.offered.count == 1)
        #expect(surface.asked.isEmpty)
    }

    @Test func aParkedAwaitingUserHandoffTakesNoExtraStep() async throws {
        let surface = Surface([.toolCalls([Self.call("configurator_handoff")]), .finalResponse])
        surface.presenting = false
        surface.results["configurator_handoff"] = AgentLoopToolExecution(
            result: HandoffResult.awaitingUser(
                RunRef(runId: "r1", workflow: "Digest", status: "awaiting_user"), question: "Which day?"
            ).envelope(tool: "configurator_handoff"))
        let result = try await surface.run()
        #expect(result.exit == .finalResponse)
        #expect(surface.offered.count == 2)
        #expect(surface.asked == [.finalText])
        #expect(surface.forced == nil)
    }

    @Test func aHandoffResultQualifiesATurnThatWasNotRouted() async throws {
        let surface = Surface([
            .toolCalls([Self.call("configurator_handoff")]), .finalResponse, .toolCalls([Self.call(StateTool.toolName)]),
        ])
        surface.presenting = false
        surface.results["configurator_handoff"] = AgentLoopToolExecution(
            result: HandoffResult.applied("Done.").envelope(tool: "configurator_handoff"))
        _ = try await surface.run()
        #expect(surface.offered.count == 3)
        #expect(surface.executed == ["configurator_handoff", StateTool.toolName])
    }

    @Test func anOrdinaryTurnIsLeftAlone() async throws {
        let surface = Surface([.finalResponse])
        surface.presenting = false
        _ = try await surface.run()
        #expect(surface.offered.count == 1)
    }

    @Test func theStepCapGetsTheForcedStepBeforeItsWrapUp() async throws {
        let surface = Surface([
            .toolCalls([Self.call("status")]), .toolCalls([Self.call("status", #"{"x":1}"#)]),
            .toolCalls([Self.call(StateTool.toolName)]),
        ])
        let result = try await surface.run(maxIterations: 2)
        #expect(result.exit == .iterationCapReached, "the surface still streams its wrap-up")
        #expect(surface.offered.count == 3)
        #expect(surface.offered.last == [StateTool.toolName])
        #expect(surface.asked == [.iterationCap])
    }

    @Test func aModelThatIgnoresTheForcedChoiceGetsNoSecondTry() async throws {
        let surface = Surface([.finalResponse, .finalResponse, .finalResponse])
        let result = try await surface.run()
        #expect(result.exit == .finalResponse)
        #expect(surface.offered.count == 2)
    }
}
