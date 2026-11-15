//
//  TurnEndingLoopTests.swift
//  OsaurusCoreTests
//
//  `AgentLoopHooks.noteTurnEnding`: the driver reports how an Orchestrator
//  turn ended (an answer, or the step cap) once, and never adds a step for
//  it. Session-state extraction keys off that report.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct TurnEndingLoopTests {
    @MainActor
    final class Surface {
        var steps: [AgentLoopModelStep]
        var cancelled = false
        var cancelDuringFirstStep = false
        var results: [String: AgentLoopToolExecution] = [:]

        var modelSteps = 0
        var executed: [String] = []
        var noted: [TurnEnding] = []

        init(_ steps: [AgentLoopModelStep]) { self.steps = steps }

        func run(maxIterations: Int = 8) async throws -> AgentToolLoop.RunResult {
            var hooks = AgentLoopHooks(
                isCancelled: { self.cancelled },
                buildMessages: { _ in AgentLoopIterationInput(messages: [ChatMessage(role: "user", content: "x")]) },
                modelStep: { _, _ in
                    self.modelSteps += 1
                    if self.cancelDuringFirstStep, self.modelSteps == 1 { self.cancelled = true }
                    return self.steps.isEmpty ? .finalResponse : self.steps.removeFirst()
                },
                executeTool: { invocation, _ in
                    self.executed.append(invocation.toolName)
                    return self.results[invocation.toolName]
                        ?? AgentLoopToolExecution(result: ToolEnvelope.success(tool: invocation.toolName, text: "ok"))
                },
                onBatchComplete: { _ in }
            )
            hooks.noteTurnEnding = { self.noted.append($0) }
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

    @Test func anAnswerIsNotedOnceAndEndsTheRun() async throws {
        let surface = Surface([.toolCalls([Self.call("configurator_handoff")]), .finalResponse])
        let result = try await surface.run()
        #expect(result.exit == .finalResponse)
        #expect(surface.modelSteps == 2, "no step after the answer")
        #expect(surface.executed == ["configurator_handoff"])
        #expect(surface.noted == [.finalText])
    }

    @Test func theStepCapIsNotedBeforeItsWrapUp() async throws {
        let surface = Surface([
            .toolCalls([Self.call("status")]), .toolCalls([Self.call("status", #"{"x":1}"#)]),
        ])
        let result = try await surface.run(maxIterations: 2)
        #expect(result.exit == .iterationCapReached, "the surface still streams its wrap-up")
        #expect(surface.modelSteps == 2)
        #expect(surface.noted == [.iterationCap])
    }

    @Test func aCancelledTurnIsNeverNoted() async throws {
        let surface = Surface([.finalResponse])
        surface.cancelDuringFirstStep = true
        let result = try await surface.run()
        #expect(result.exit == .cancelled)
        #expect(surface.noted.isEmpty)
    }

    @Test func aFinalClarifyIsNeverNoted() async throws {
        let surface = Surface([.toolCalls([Self.call("clarify", #"{"question":"Which one?"}"#)])])
        surface.results["clarify"] = AgentLoopToolExecution(
            result: ToolEnvelope.success(tool: "clarify", text: "asked"), endRun: true)
        let result = try await surface.run()
        #expect(result.exit == .endedBySurface)
        #expect(surface.modelSteps == 1)
        #expect(surface.noted.isEmpty)
    }
}
