//
//  LocalTextDelegateTool.swift
//  osaurus
//
//  Configurable local text delegate for cloud-to-local helper jobs. This is a
//  sibling of `sandbox_reduce`: a parent model launches a bounded,
//  context-isolated child loop and receives only a compact result envelope.
//

import Foundation

enum LocalTextDelegateContext {
    @TaskLocal static var isActive: Bool = false
}

struct LocalTextDelegateModelRef: Sendable, Equatable {
    var name: String
    var id: String
}

enum LocalTextDelegateModelResolver {
    static func resolve(requested: String?, configured: String?) -> LocalTextDelegateModelRef? {
        for candidate in [requested, configured] {
            guard let normalized = normalized(candidate) else { continue }
            if let found = ModelManager.findInstalledModel(named: normalized) {
                return LocalTextDelegateModelRef(name: found.name, id: found.id)
            }
        }
        return nil
    }

    static func requestedModelDescription(requested: String?, configured: String?) -> String {
        normalized(requested) ?? normalized(configured) ?? "auto"
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public final class LocalTextDelegateTool: OsaurusTool, @unchecked Sendable {
    public let name = "local_delegate"
    public let description =
        "Delegate a bounded text, coding, or analysis subtask to the user's configured local chat "
        + "model. Use this to save cloud/API tokens when the user enabled local delegation. The "
        + "result returns a compact local summary only; local transcript details are not replayed."

    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "task": .object([
                "type": .string("string"),
                "description": .string("Concise local helper task for the delegate model."),
            ]),
            "mode": .object([
                "type": .string("string"),
                "enum": .array([.string("coding"), .string("analysis"), .string("summarize"), .string("other")]),
                "description": .string("Optional task kind. Defaults to other."),
            ]),
            "context": .object([
                "type": .string("string"),
                "description": .string("Optional compact context needed for the local task."),
            ]),
            "model": .object([
                "type": .string("string"),
                "description": .string("Optional installed local chat model id. Omit to use the configured default."),
            ]),
            "max_tokens": .object([
                "type": .string("integer"),
                "description": .string("Optional output-token cap, clamped by Agent Delegation settings."),
            ]),
        ]),
        "required": .array([.string("task")]),
    ])

    public var bypassRegistryTimeout: Bool { true }

    private static let digestMaxChars = 8_000

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        if LocalTextDelegateContext.isActive {
            return ToolEnvelope.failure(
                kind: .rejected,
                message: "local_delegate cannot be called from inside a local delegate job.",
                tool: name,
                retryable: false
            )
        }

        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let taskReq = requireString(args, "task", expected: "a concise local delegate task", tool: name)
        guard case .value(let task) = taskReq else { return taskReq.failureEnvelope ?? "" }

        let config = AgentDelegationConfigurationStore.snapshot()
        guard config.textDelegationToolAvailable else {
            return ToolEnvelope.failure(
                kind: .rejected,
                message: "Local text delegation is disabled in Agent Delegation settings.",
                tool: name,
                retryable: false
            )
        }
        let requestedModel = optionalStringValue(args["model"])
        guard let model = LocalTextDelegateModelResolver.resolve(
            requested: requestedModel,
            configured: config.defaultLocalTextDelegateModelId
        ) else {
            let missing = LocalTextDelegateModelResolver.requestedModelDescription(
                requested: requestedModel,
                configured: config.defaultLocalTextDelegateModelId
            )
            return ToolEnvelope.failure(
                kind: .unavailable,
                message:
                    "Local delegate model '\(missing)' is not installed. Choose a downloaded local "
                    + "chat model in Agent Delegation settings.",
                tool: name,
                retryable: false
            )
        }
        let approvalJSON = AgentDelegationApprovalArguments.enrichedJSON(
            from: argumentsJSON,
            values: [
                "resolved_model": model.name,
                "resolved_model_id": model.id,
                "text_delegate_load_policy": config.textDelegateLoadPolicy.rawValue,
            ]
        )
        if let denied = await permissionDenialIfNeeded(config: config, argumentsJSON: approvalJSON) {
            return denied
        }

        // Local orchestrator handoff: when the parent chat model is itself local,
        // run the delegate under a single-residency handoff — unload the
        // orchestrator now, run the delegate, then reload the orchestrator (below).
        // Off by default (avoids double local residency); opt in via settings.
        var residencyLease = ChatResidencyLease.empty
        if await parentUsesLocalModel() {
            guard config.localOrchestratorTextHandoffActive else {
                return ToolEnvelope.failure(
                    kind: .rejected,
                    message:
                        "Local-to-local text delegation is off. Enable \"Local orchestrator handoff\" "
                        + "in Agent Delegation settings to let the local chat model unload, run the "
                        + "delegate, and reload — or switch the parent chat to a cloud/API provider.",
                    tool: name,
                    retryable: false
                )
            }
            do {
                // RAM-safety preflight: refuse before evicting the orchestrator if
                // the delegate model would not fit once it is freed.
                try await ChatResidencyHandoff.memoryPreflight(
                    requiredBytes: ChatResidencyHandoff.estimatedChatModelBytes(named: model.name),
                    enabled: config.ramSafetyPreflightEnabled)
                residencyLease = try await ChatResidencyHandoff.unloadResidentChatModels(
                    maxElapsedSeconds: config.budgets.maxElapsedSeconds)
            } catch {
                return ToolEnvelope.failure(
                    kind: .executionError,
                    message: "Subagent memory handoff failed: \(error.localizedDescription)",
                    tool: name,
                    retryable: true
                )
            }
        }

        let budgets = config.budgets.normalized
        let requestedMaxTokens = optionalIntValue(args["max_tokens"])
        let maxTokens = min(max(requestedMaxTokens ?? budgets.maxDelegateTokens, 256), budgets.maxDelegateTokens)
        let maxIterations = budgets.maxDelegateTurns
        let deadline = Date().addingTimeInterval(TimeInterval(budgets.maxElapsedSeconds))
        let mode = optionalStringValue(args["mode"]) ?? "other"
        let context = optionalStringValue(args["context"])
        let childSessionId = "local-delegate-\(UUID().uuidString)"

        let wasResident = await ModelRuntime.shared.isResident(name: model.name)
        let started = Date()
        var messages = Self.seedMessages(task: task, mode: mode, context: context, maxTokens: maxTokens)
        var finalDigest: String?

        let contextWindow = await AgentLoopBudget.resolveContextWindow(modelId: model.name)
        let budgetManager = AgentLoopBudget.makeBudgetManager(
            contextWindow: contextWindow,
            systemPromptChars: messages.first?.content?.count ?? 0,
            toolTokens: 0,
            maxResponseTokens: maxTokens
        )
        let watermark = CompactionWatermark()
        let engine = ChatEngine(source: .chatUI)

        let hooks = AgentLoopHooks(
            isCancelled: {
                Task.isCancelled || Date() >= deadline
            },
            buildMessages: { notices in
                for notice in notices {
                    messages.append(ChatMessage(role: "user", content: notice))
                }
                return AgentLoopBudget.composeIterationMessages(
                    messages,
                    notices: [],
                    manager: budgetManager,
                    watermark: watermark
                )
            },
            modelStep: { effective, _ in
                var request = ChatCompletionRequest(
                    model: model.name,
                    messages: effective,
                    temperature: nil,
                    max_tokens: maxTokens,
                    stream: false,
                    top_p: nil,
                    frequency_penalty: nil,
                    presence_penalty: nil,
                    stop: nil,
                    n: nil,
                    tools: nil,
                    tool_choice: nil,
                    session_id: childSessionId
                )
                request.samplingParametersAreImplicit = true
                request.isAgentRequest = true
                let response = try await LocalTextDelegateContext.$isActive.withValue(true) {
                    try await engine.completeChat(request: request)
                }
                guard let choice = response.choices.first else {
                    return .emptyResponse
                }
                if let calls = choice.message.tool_calls, !calls.isEmpty {
                    messages.append(choice.message)
                    return .toolCalls(
                        calls.map {
                            ServiceToolInvocation(
                                toolName: $0.function.name,
                                jsonArguments: $0.function.arguments,
                                toolCallId: $0.id
                            )
                        }
                    )
                }
                finalDigest = choice.message.content
                return .finalResponse
            },
            executeTool: { invocation, callId in
                let envelope = ToolEnvelope.failure(
                    kind: .rejected,
                    message:
                        "Tool '\(invocation.toolName)' is not available inside local_delegate. "
                        + "This delegate job is text-only because local delegate tool use is not "
                        + "enabled by Agent Delegation settings.",
                    tool: invocation.toolName,
                    retryable: false
                )
                messages.append(ChatMessage(role: "tool", content: envelope, tool_calls: nil, tool_call_id: callId))
                return AgentLoopToolExecution(result: envelope, isError: true)
            }
        )

        let runResult: AgentToolLoop.RunResult
        do {
            runResult = try await AgentToolLoop.run(
                policy: AgentLoopPolicy(
                    maxIterations: maxIterations,
                    stopOnToolRejection: true,
                    dedupeNoticeEnabled: false
                ),
                state: AgentTaskState(),
                hooks: hooks
            )
        } catch {
            _ = await unloadDelegateIfNeeded(model: model.name, config: config)
            await ChatResidencyHandoff.restoreBestEffort(residencyLease)
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Local delegate failed: \(error.localizedDescription)",
                tool: name,
                retryable: true
            )
        }

        let unloadedAfterJob = await unloadDelegateIfNeeded(model: model.name, config: config)
        // Reload the orchestrator chat model unloaded for this job (no-op for a
        // cloud orchestrator, where the lease is empty).
        // Best-effort (logs on failure) rather than a bare `try?` so a reload
        // failure on the success path can't silently strand the chat model
        // unloaded with no diagnostic.
        _ = await ChatResidencyHandoff.restoreBestEffort(residencyLease)
        let elapsed = Date().timeIntervalSince(started)

        switch runResult.exit {
        case .finalResponse, .endedBySurface:
            let digest = (finalDigest ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !digest.isEmpty else {
                return ToolEnvelope.failure(
                    kind: .executionError,
                    message: "Local delegate finished without producing a result.",
                    tool: name,
                    retryable: true
                )
            }
            let capped =
                digest.count > Self.digestMaxChars
                ? String(digest.prefix(Self.digestMaxChars)) + "\n[digest truncated]"
                : digest
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "kind": "local_text_delegate_result",
                    "model": model.name,
                    "model_id": model.id,
                    "mode": mode,
                    "summary": capped,
                    "iterations": runResult.iterations,
                    "elapsed_seconds": elapsed,
                    "was_resident": wasResident,
                    "unloaded_after_job": unloadedAfterJob,
                    "sharing_policy": config.sharingPolicy.rawValue,
                ] as [String: Any]
            )
        case .cancelled:
            if Date() >= deadline {
                return ToolEnvelope.failure(
                    kind: .timeout,
                    message: "Local delegate hit its \(budgets.maxElapsedSeconds)s elapsed-time budget.",
                    tool: name,
                    retryable: true
                )
            }
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Local delegate was cancelled.",
                tool: name,
                retryable: false
            )
        case .iterationCapReached:
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Local delegate used all \(maxIterations) turns without producing a compact result.",
                tool: name,
                retryable: true
            )
        case .toolRejected:
            return ToolEnvelope.failure(
                kind: .rejected,
                message: "Local delegate attempted unavailable child tool use.",
                tool: name,
                retryable: false
            )
        case .overBudget:
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Local delegate exceeded its context budget. Pass shorter context.",
                tool: name,
                retryable: true
            )
        case .emptyResponseExhausted:
            return ToolEnvelope.failure(
                kind: .executionError,
                message:
                    "Local delegate returned empty output after tool execution; the task may be incomplete.",
                tool: name,
                retryable: true
            )
        }
    }

    private static func seedMessages(task: String, mode: String, context: String?, maxTokens: Int) -> [ChatMessage] {
        let system =
            "You are a local helper model running inside Osaurus. Complete the delegated task using "
            + "only the task text and compact context provided here. Return a concise, factual result "
            + "for the parent model. Do not invent missing facts; name assumptions or missing inputs. "
            + "Do not include hidden transcripts or unrelated reasoning. Keep the result under "
            + "\(maxTokens) tokens."
        var user = "Mode: \(mode)\nTask: \(task)"
        if let context, !context.isEmpty {
            user += "\n\nContext:\n\(context)"
        }
        return [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: user),
        ]
    }

    private func permissionDenialIfNeeded(
        config: AgentDelegationConfiguration,
        argumentsJSON: String
    ) async -> String? {
        switch config.permissionDefaults.localTextDelegate {
        case .deny:
            return ToolEnvelope.failure(
                kind: .rejected,
                message: "Local text delegation is denied by Agent Delegation settings.",
                tool: name,
                retryable: false
            )
        case .alwaysAllow:
            return nil
        case .ask:
            if ChatExecutionContext.autoApproveToolPrompts {
                return nil
            }
            let approved = await ToolPermissionPromptService.requestApproval(
                toolName: name,
                description: description,
                argumentsJSON: argumentsJSON
            )
            if approved { return nil }
            return ToolEnvelope.failure(
                kind: .userDenied,
                message: "User denied local text delegation.",
                tool: name,
                retryable: false
            )
        }
    }

    private func parentUsesLocalModel() async -> Bool {
        guard let agentId = ChatExecutionContext.currentAgentId else { return false }
        let parentModel = await MainActor.run {
            AgentManager.shared.effectiveModel(for: agentId) ?? ChatConfigurationStore.load().defaultModel
        }
        guard let parentModel else { return false }
        return ModelManager.findInstalledModel(named: parentModel) != nil
    }

    private func unloadDelegateIfNeeded(
        model: String,
        config: AgentDelegationConfiguration
    ) async -> Bool {
        switch config.textDelegateLoadPolicy {
        case .keepWarmWhenSafe:
            return false
        case .unloadAfterJob, .strictSingleJobResidency:
            await ModelRuntime.shared.unload(name: model)
            return true
        }
    }

    private func optionalStringValue(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func optionalIntValue(_ raw: Any?) -> Int? {
        ArgumentCoercion.int(raw)
    }
}
