//
//  BuiltInWorkerRunner.swift
//  osaurus
//
//  Runs a built-in worker for the one step of its wrapper workflow. The
//  research, files, and code workers run on `HiddenAgentHandoffRunner`
//  (fixed persona and tools, fresh context, the run's feed); the browser
//  worker is `browser_use` itself, on its own per-agent browser session.
//  Like the Configurator, a worker skips only the spawn-pool permission:
//  every tool it calls keeps its own ask/allow policy and approval cards.
//  The code worker runs as its own standing sandbox member (`worker-code`)
//  under a fixed policy, so it works with no custom agent configured.
//

import Foundation

enum BuiltInWorkerRunner {

    static func run(_ worker: BuiltInWorker, task: String, context: WorkflowNodeContext) async throws
        -> AgentNodeExecutor.Delegated
    {
        if worker == .code {
            do {
                try await SandboxToolRegistrar.shared.prepareCodeWorker()
            } catch {
                throw WorkflowNodeError.toolFailed(
                    tool: "agent", kind: "unavailable",
                    message: L("The Code worker's sandbox could not start: \(error.localizedDescription)"),
                    retryable: true)
            }
        }
        let feedID = "workflow-agent-\(context.runID.uuidString)-\(context.node.id)-\(context.attempt)"
        let sessionID = context.caller.sessionID ?? context.runID.uuidString
        let envelope = await ChatExecutionContext.$currentToolCallId.withValue(feedID) {
            await ChatExecutionContext.$currentSessionId.withValue(sessionID) {
                await ChatExecutionContext.$currentFolderRoot.withValue(context.folderRoot) {
                    await ChatExecutionContext.$toolExecutionScope.withValue(nil) {
                        await SubagentSession.$activeKindId.withValue(nil) {
                            worker == .browser
                                ? await browse(task)
                                : await HiddenAgentHandoffRunner.run(
                                    HiddenAgentHandoffKind(
                                        target: await target(for: worker, timeout: context.timeout),
                                        seedUserContent: task),
                                    tool: "agent")
                        }
                    }
                }
            }
        }
        return try delegated(from: envelope, worker: worker)
    }

    /// `browser_use` under the browser worker's own id, granted the way a
    /// workflow step grants a tool.
    private static func browse(_ task: String) async -> String {
        let args = JSONValue.object(["goal": .string(task)]).compactJSONString
        return await ChatExecutionContext.$currentAgentId.withValue(BuiltInWorker.browser.agentId) {
            await ChatExecutionContext.$workflowGrantedToolNames.withValue([BrowserUseTool.toolName]) {
                do {
                    return try await BrowserUseTool().execute(argumentsJSON: args)
                } catch {
                    return ToolEnvelope.fromError(error, tool: BrowserUseTool.toolName)
                }
            }
        }
    }

    /// The worker's target. Steps and time follow the Orchestrator's
    /// delegation budgets, capped by the step's remaining time.
    @MainActor
    static func target(for worker: BuiltInWorker, timeout: TimeInterval) -> HiddenAgentTarget {
        let budgets = SpawnFanOutPolicy.effectiveBudgets(
            scope: SubagentScope(sessionId: "", toolCallId: "", agentId: Agent.defaultId))
        return HiddenAgentTarget(
            agentId: worker.agentId,
            capability: SubagentCapabilityRegistry.worker(worker),
            feedTitle: worker.displayName,
            maxSteps: max(1, budgets.maxDelegateTurns),
            wallClockSeconds: min(TimeInterval(max(1, budgets.maxElapsedSeconds)), max(1, timeout)),
            systemPrompt: { worker.persona },
            toolNames: { worker.toolNames },
            configuredModel: { nil },
            temperature: { nil },
            classify: { _, digest, _ in .answer(digest) })
    }

    /// The worker's reply as an agent step's result, or the step's failure.
    static func delegated(from envelope: String, worker: BuiltInWorker) throws -> AgentNodeExecutor.Delegated {
        guard ToolEnvelope.isSuccess(envelope), let payload = ToolEnvelope.successPayload(envelope) as? [String: Any]
        else {
            let object = JSONValue.parse(envelope)?.objectValue
            let message =
                object?["message"]?.stringValue ?? object?["reason"]?.stringValue
                ?? L("The \(worker.displayName) worker did not finish.")
            throw WorkflowNodeError.toolFailed(
                tool: "agent", kind: object?["kind"]?.stringValue ?? "execution_error", message: message,
                retryable: false)
        }
        let text =
            (payload["text"] as? String) ?? (payload["summary"] as? String) ?? (payload["result"] as? String) ?? ""
        let usage = payload["usage"] as? [String: Any]
        return AgentNodeExecutor.Delegated(
            sessionID: UUID(), text: text, needsInput: false,
            completionTokens: usage?["completion_tokens"] as? Int, artifacts: [])
    }
}
