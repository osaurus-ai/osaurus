//
//  WorkflowRunningStepTimeoutTests.swift
//  osaurusTests
//
//  A chat waiting on a workflow run it started gives the run as long as
//  its running step may take before the composer calls the run stuck.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct WorkflowRunningStepTimeoutTests {

    actor Latch {
        private var open = false
        func release() { open = true }
        func wait() async {
            while !open { try? await Task.sleep(for: .milliseconds(10)) }
        }
    }

    @Test func aChatsTestRunReportsItsRunningStepsTimeoutUntilItEnds() async throws {
        let latch = Latch()
        let session = "session-\(UUID().uuidString)"
        let definition = WorkflowDefinition(
            inputSchema: WF.object([:]), outputSchema: WF.object([:]),
            nodes: [
                WorkflowNode(
                    id: "research", name: "Research",
                    kind: .code(CodeSpec(source: "async function run(input, ctx) { return {} }")), timeout: 300)
            ],
            edges: [], output: .object([:]))
        try await WorkflowExecutorOverride.with({
            ClosureExecutor { _, _ in
                await latch.wait()
                return WorkflowNodeOutcome(output: .object([:]))
            }
        }) {
            let service = WorkflowRunService.shared
            let runID = service.startTest(
                draftID: UUID(), template: WF.template(definition), bindings: InstallBindings(), input: .object([:]),
                sessionID: session)

            var timeout: TimeInterval?
            for _ in 0 ..< 500 where timeout == nil {
                timeout = service.runningStepTimeout(sessionID: session)
                if timeout == nil { try await Task.sleep(for: .milliseconds(10)) }
            }
            #expect(timeout == 300)
            #expect(service.runningStepTimeout(sessionID: "another-chat") == nil)
            #expect(RunProgressLoadingPhase.current(agentId: nil, sessionId: session) == .workflowRun(stepTimeout: 300))

            await latch.release()
            _ = await service.result(of: runID)
            #expect(service.runningStepTimeout(sessionID: session) == nil)
        }
    }

    @Test func aChatsRunWaitingOnAPersonReportsWaiting_untilTheyAnswer() async throws {
        let latch = Latch()
        let session = "session-\(UUID().uuidString)"
        let definition = WorkflowDefinition(
            inputSchema: WF.object([:]), outputSchema: WF.object([:]),
            nodes: [
                WorkflowNode(
                    id: "ask", name: "Ask",
                    kind: .dialog(DialogSpec(title: "Role", fields: [DialogField(key: "jd", label: "JD")])),
                    timeout: 120)
            ],
            edges: [], output: .object([:]))
        try await WorkflowExecutorOverride.with({
            ClosureExecutor { _, awaiting in
                await awaiting(true)
                await latch.wait()
                await awaiting(false)
                return WorkflowNodeOutcome(output: .object([:]))
            }
        }) {
            let service = WorkflowRunService.shared
            let runID = service.startTest(
                draftID: UUID(), template: WF.template(definition), bindings: InstallBindings(), input: .object([:]),
                sessionID: session)

            var waiting = false
            for _ in 0 ..< 500 where !waiting {
                waiting = service.isAwaitingPerson(sessionID: session)
                if !waiting { try await Task.sleep(for: .milliseconds(10)) }
            }
            #expect(waiting)
            #expect(!service.isAwaitingPerson(sessionID: "another-chat"))
            #expect(RunProgressLoadingPhase.current(agentId: nil, sessionId: session) == .workflowAwaitingPerson)

            await latch.release()
            _ = await service.result(of: runID)
            #expect(!service.isAwaitingPerson(sessionID: session))
        }
    }
}
