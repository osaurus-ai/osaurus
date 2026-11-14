//
//  SubworkflowNodeExecutor.swift
//  osaurus
//
//  Workflow steps: run another installed workflow as one step. The
//  step's bound input is the other workflow's input; its output is the
//  step's output. The nested run is a run of its own (visible in that
//  workflow's history) whose caller is this run, so a form it shows is
//  attributed to the same person or agent. A workflow may not call
//  itself, directly or through others, and nesting is bounded.
//

import Foundation

enum SubworkflowNodeExecutor {

    /// The pieces the executor talks to, injectable for tests.
    struct Runtime: Sendable {
        /// Finds an installed workflow by name or `workflow_<slug>` tool
        /// name, with its setup state.
        var resolve: @Sendable (_ name: String) async -> Resolved?
        /// Starts a run and waits for it to end, reporting through
        /// `awaitingUser` while it is parked on a form.
        var run:
            @Sendable (
                _ workflow: InstalledWorkflow, _ input: JSONValue, _ caller: WorkflowCaller,
                _ awaitingUser: WorkflowAwaitingUserHandler
            ) async -> WorkflowRun?

        static let live = Runtime(
            resolve: { name in
                // The node runs as the parent's caller (`WorkflowExecutionContext`),
                // and the child runs as it too, so its keys are checked for that agent.
                let agentId = ChatExecutionContext.usesSharedKeysOnly ? nil : ChatExecutionContext.currentAgentId
                return await MainActor.run {
                    guard let workflow = InstalledWorkflowStore.shared.workflow(named: name) else { return nil }
                    let report = SetupChecker.check(workflow, secrets: .caller(agentId))
                    return Resolved(
                        workflow: workflow,
                        setupProblems: report.blocking.map { "\($0.title): \($0.detail)" })
                }
            },
            run: { workflow, input, caller, awaitingUser in
                let runID = await MainActor.run {
                    WorkflowRunService.shared.start(workflow, input: input, caller: caller)
                }
                return await withTaskCancellationHandler {
                    // While the nested run waits on a form, so does this step.
                    var run = await WorkflowRunService.shared.settledOrParked(runID)
                    if run?.status == .awaitingUser {
                        await awaitingUser(true)
                        run = await WorkflowRunService.shared.result(of: runID)
                        await awaitingUser(false)
                    }
                    return run
                } onCancel: {
                    Task { @MainActor in WorkflowRunService.shared.cancel(runID) }
                }
            }
        )
    }

    struct Resolved: Sendable {
        var workflow: InstalledWorkflow
        var setupProblems: [String]
    }

    static func run(spec: SubworkflowSpec, context: WorkflowNodeContext, awaitingUser: WorkflowAwaitingUserHandler)
        async throws -> WorkflowNodeOutcome
    {
        try await run(spec: spec, context: context, awaitingUser: awaitingUser, runtime: .live)
    }

    static func run(
        spec: SubworkflowSpec, context: WorkflowNodeContext, awaitingUser: WorkflowAwaitingUserHandler,
        runtime: Runtime
    ) async throws -> WorkflowNodeOutcome {
        let name = spec.workflow.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolved = await runtime.resolve(name) else {
            throw WorkflowNodeError.unsupported(
                L("No installed workflow is named \"\(name)\". Install it, or check the name."))
        }
        let target = resolved.workflow
        let chain = context.caller.ancestors + [context.workflowID]
        if chain.contains(target.id) {
            throw WorkflowNodeError.unsupported(
                L("\(target.name) is already running up this chain; a workflow cannot call itself."))
        }
        if chain.count >= SubworkflowSpec.maximumDepth {
            throw WorkflowNodeError.unsupported(
                L("Workflows nest at most \(SubworkflowSpec.maximumDepth) deep; this call would go deeper."))
        }
        guard resolved.setupProblems.isEmpty else {
            throw WorkflowNodeError.toolFailed(
                tool: target.toolName, kind: "needs_setup",
                message: L("\(target.name) needs setup: \(resolved.setupProblems.joined(separator: "; "))"),
                retryable: false)
        }
        let input = context.input
        let issues = JSONSchemaValidator.validate(input, against: target.definition.inputSchema)
        if !issues.isEmpty {
            throw WorkflowNodeError.toolFailed(
                tool: target.toolName, kind: "invalid_args",
                message: L("Input does not match what \(target.name) takes: ")
                    + issues.map(\.description).joined(separator: "; "),
                retryable: false)
        }
        let caller = context.caller.nested(parentRunID: context.runID, parentWorkflowID: context.workflowID)
        guard let run = await runtime.run(target, input, caller, awaitingUser) else {
            throw WorkflowNodeError.toolFailed(
                tool: target.toolName, kind: "execution_error", message: L("The run of \(target.name) was lost."),
                retryable: true)
        }
        var logs = [L("Ran \(target.name) (run \(run.id.uuidString.lowercased().prefix(8))).")]
        switch run.status {
        case .completed:
            logs += run.nodes.filter { $0.status == .failed }.map {
                L("\(target.name) step \($0.nodeID) failed and was continued: \($0.error ?? "")")
            }
            return WorkflowNodeOutcome(
                output: run.output ?? .object([:]), logs: logs,
                toolCalls: run.nodes.flatMap(\.toolCalls),
                inputTokens: Self.sum(run.nodes.map(\.inputTokens)),
                outputTokens: Self.sum(run.nodes.map(\.outputTokens)),
                artifacts: run.artifacts)
        case .failed:
            let reason = run.error.map { e in e.nodeID.map { "[\($0)] \(e.reason)" } ?? e.reason } ?? L("The run failed.")
            throw WorkflowNodeError.toolFailed(
                tool: target.toolName, kind: "workflow_failed", message: L("\(target.name) failed: \(reason)"),
                retryable: false)
        case .cancelled:
            throw CancellationError()
        case .needsSetup:
            throw WorkflowNodeError.toolFailed(
                tool: target.toolName, kind: "needs_setup", message: L("\(target.name) needs setup."), retryable: false)
        case .running, .awaitingUser:
            throw WorkflowNodeError.toolFailed(
                tool: target.toolName, kind: "execution_error",
                message: L("\(target.name) did not finish."), retryable: true)
        }
    }

    private static func sum(_ values: [Int?]) -> Int? {
        let present = values.compactMap { $0 }
        return present.isEmpty ? nil : present.reduce(0, +)
    }
}
