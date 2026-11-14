//
//  RunFailedEventSourceTests.swift
//  osaurusTests
//
//  The "Run failed" automation: which workflow and automation failures
//  start it, the loop guard, test and nested runs, the payload, and the
//  path from EventManager.finalize.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct RunFailedEventSourceTests {
    private func handler(
        _ manager: EventManager, workflows: [UUID] = [], includeAutomationRuns: Bool = false, enabled: Bool = true
    ) -> OsaurusEvent {
        var event = OsaurusEvent(
            name: "On failure",
            source: .runFailed(RunFailedSourceConfig(workflowIDs: workflows, includeAutomationRuns: includeAutomationRuns)),
            action: EventPipelineFixtures.agentAction())
        event.isEnabled = enabled
        return manager.create(event)
    }

    private func source(_ manager: EventManager) throws -> RunFailedEventSource {
        try #require(manager.adapter(for: .runFailed) as? RunFailedEventSource)
    }

    private func failedRun(
        workflowID: UUID = UUID(), caller: WorkflowCaller = WorkflowCaller(kind: .user), status: WorkflowRunStatus = .failed
    ) -> WorkflowRun {
        var run = WorkflowRun(
            workflowID: workflowID, workflowName: "Digest", templateID: UUID(), templateVersion: 1, caller: caller,
            input: .object([:]), nodeIDs: ["fetch"])
        run.status = status
        run.error = WorkflowRunError(nodeID: "fetch", reason: "HTTP 500 from the API")
        run.finishedAt = Date()
        return run
    }

    @Test func aFailedWorkflowRunStartsEveryMatchingHandler() async throws {
        let (manager, runner) = try EventPipelineFixtures.manager()
        let any = handler(manager)
        let run = failedRun()
        try source(manager).workflowRunFinished(run)
        await runner.waitForFires(1)
        let occurrence = try #require(runner.fired.first)
        #expect(occurrence.eventId == any.id)
        #expect(occurrence.dedupeKey == "failure:" + run.id.uuidString)
        #expect(!occurrence.isExternal)
        let payload = occurrence.payload
        #expect(payload.value(atPath: "failure.kind")?.stringValue == "workflow_run")
        #expect(payload.value(atPath: "failure.error")?.stringValue == "HTTP 500 from the API")
        #expect(payload.value(atPath: "failure.workflow.name")?.stringValue == "Digest")
        #expect(payload.value(atPath: "failure.workflow.id")?.stringValue == run.workflowID.uuidString)
        #expect(payload.value(atPath: "failure.failed_step.id")?.stringValue == "fetch")
        #expect(payload.value(atPath: "failure.run_id")?.stringValue == run.id.uuidString)
        #expect(payload.value(atPath: "failure.caller")?.stringValue == "user")
        #expect(payload.value(atPath: "text")?.stringValue == "HTTP 500 from the API")
    }

    @Test func successesTestsAndOffHandlersDoNothing() async throws {
        let (manager, runner) = try EventPipelineFixtures.manager()
        _ = handler(manager, enabled: false)
        let source = try source(manager)
        source.workflowRunFinished(failedRun())
        _ = handler(manager)
        source.workflowRunFinished(failedRun(status: .completed))
        source.workflowRunFinished(failedRun(caller: WorkflowCaller(kind: .test)))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(runner.fired.isEmpty)
    }

    @Test func workflowFilterAndNestedRuns() async throws {
        let (manager, runner) = try EventPipelineFixtures.manager()
        let picked = UUID()
        let named = handler(manager, workflows: [picked])
        let any = handler(manager)
        let source = try source(manager)

        source.workflowRunFinished(failedRun(workflowID: UUID()))
        await runner.waitForFires(1)
        #expect(runner.fired.map(\.eventId) == [any.id], "a filtered handler skips other workflows")

        let nested = WorkflowCaller(kind: .user).nested(parentRunID: UUID(), parentWorkflowID: UUID())
        source.workflowRunFinished(failedRun(workflowID: picked, caller: nested))
        await runner.waitForFires(2)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(
            runner.fired.map(\.eventId) == [any.id, named.id],
            "a nested run reaches only the handler that names its workflow")
    }

    @Test func runsAHandlerStartedNeverStartAHandler() async throws {
        let (manager, runner) = try EventPipelineFixtures.manager()
        let handler = handler(manager)
        let caller = WorkflowCaller(kind: .event, eventID: handler.id, eventName: handler.name)
        try source(manager).workflowRunFinished(failedRun(caller: caller))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(runner.fired.isEmpty)
    }

    @Test func automationFailuresOnlyWhenAsked() async throws {
        let (manager, runner) = try EventPipelineFixtures.manager()
        let plain = handler(manager)
        let wide = handler(manager, includeAutomationRuns: true)
        let automation = manager.create(
            OsaurusEvent(name: "Nightly", source: .schedule(ScheduleSourceConfig(frequency: .hourly(minute: 0))),
                action: EventPipelineFixtures.agentAction()))
        var run = EventRun(
            eventId: automation.id, eventName: automation.name, sourceKind: .schedule, actionKind: .agent, firedAt: Date())
        run.status = .failed
        run.error = "The agent stopped."
        let source = try source(manager)

        source.automationRunFailed(run, event: automation)
        await runner.waitForFires(1)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(runner.fired.map(\.eventId) == [wide.id])
        #expect(!runner.fired.map(\.eventId).contains(plain.id))
        let payload = try #require(runner.fired.first?.payload)
        #expect(payload.value(atPath: "failure.kind")?.stringValue == "automation_run")
        #expect(payload.value(atPath: "failure.automation.name")?.stringValue == "Nightly")
        #expect(payload.value(atPath: "failure.error")?.stringValue == "The agent stopped.")

        var throughWorkflow = run
        throughWorkflow.workflowRunId = UUID()
        source.automationRunFailed(throughWorkflow, event: automation)
        source.automationRunFailed(run, event: wide)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(runner.fired.count == 1, "workflow failures and a handler's own failures are not reported here")
    }

    @Test func finalizeReportsAFailedAgentAutomationOnce() async throws {
        let (manager, runner) = try EventPipelineFixtures.manager()
        runner.install(on: manager, status: .failed)
        let wide = handler(manager, includeAutomationRuns: true)
        let automation = manager.create(
            OsaurusEvent(
                name: "Webhook job", source: .webhook(WebhookSourceConfig(verification: .none)),
                action: EventPipelineFixtures.agentAction()))
        let result = await manager.fireNow(automation.id)
        #expect(result.accepted)
        await runner.waitForFires(2)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(runner.fired.map(\.eventId) == [automation.id, wide.id], "the handler's own failure fires nothing")
    }

    @Test func configDedupesWorkflows() {
        let id = UUID()
        #expect(RunFailedSourceConfig(workflowIDs: [id, id]).workflowIDs == [id])
    }
}
