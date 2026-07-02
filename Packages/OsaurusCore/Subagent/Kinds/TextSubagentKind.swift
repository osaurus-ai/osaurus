//
//  TextSubagentKind.swift
//  OsaurusCore — Subagent framework
//
//  The text/coding/analysis subagent kind behind the spawn family. It serves
//  BOTH spawn tools through one bounded text loop:
//
//   • `spawn_agent` → `.agent(name:)`: resolve a user-configured spawnable
//     Agent and run on ITS system prompt + model.
//   • `spawn_model` → `.model(id:)`: run on a bare spawnable model id with NO
//     agent/system prompt attached.
//
//  Either way it runs through the shared host (`SubagentSession`), so the
//  recursion guard, live feed, and the optional residency handoff are shared,
//  and hands back only a compact digest (`AgentSubagentRunner`).
//
//  `modelSource = .agent`: when the resolved run model is local and a
//  DIFFERENT chat model is resident, `makeHandoff()` vends a `ResidencyHandoff`
//  that unloads the orchestrator (single GPU residency) and reloads it after the
//  run. This holds in every direction — local→local evicts, local→remote and
//  remote→anything do not — because the shared `SubagentModelResolution.resolve`
//  runs the live residency decision for both targets. The reject-before-evict
//  policy gates (not spawnable, permission denied, handoff disabled) are resolved
//  up front so nothing is evicted before we know the run can proceed.
//

import Foundation

final class TextSubagentKind: SubagentKind, @unchecked Sendable {
    let capability = SubagentCapabilityRegistry.spawn

    /// What this spawn delegates to. The two tools map onto exactly one case
    /// each — there is no agent+model combination, so the contract stays a single
    /// required target per tool.
    enum Target: Sendable {
        /// `spawn_agent`: a spawnable agent by name (its prompt + model).
        case agent(name: String)
        /// `spawn_model`: a bare spawnable model id (no agent).
        case model(id: String)
    }

    private let target: Target
    private let input: String
    /// Eval seam (nil in production): force the run model and keep residency
    /// passthrough, so a live spawn lane is a real cross-model column in the
    /// local-vs-frontier matrix without depending on GPU residency. In `.agent`
    /// mode the agent still resolves (only its effective model is overridden);
    /// in `.model` mode it forces the run model after the pool gate. The target
    /// must still exist and be spawnable — the allow-list gate runs first.
    private let modelOverride: String?

    /// Cap on the digest handed back to the parent.
    private static let digestMaxChars = 8_000

    /// Curated read-only child toolset (host reads + sandbox reads).
    /// `specs(forTools:)` silently drops whichever aren't registered right
    /// now, so the child only ever sees live tools.
    static let readOnlyChildToolNames = [
        "file_read", "file_search",
        "sandbox_read_file", "sandbox_search_files",
    ]

    /// Tool-call cap applied when the launching agent grants `readOnly`
    /// access but its `maxToolCalls` budget is 0 (the "use default" marker) —
    /// so enabling tool access is never silently inert.
    static let defaultReadOnlyToolCallCap = 8

    // Resolved up front in `resolveModel`, read by permission/handoff/run.
    private var resolvedAgentName: String = ""
    private var resolvedAgentId: UUID?
    private var systemPrompt: String = ""
    private var budgets = SubagentBudgets()
    /// The launching agent's child-tool grant (`none` = text-only).
    private var toolAccess: SpawnToolAccess = .none
    /// The target agent's user-set temperature override (agent mode only;
    /// `nil` keeps the model bundle's own generation defaults).
    private var temperature: Float?
    /// The residency plan resolved at `resolveModel` time (reject-before-evict),
    /// consumed by `makeHandoff()`. `.none` when no swap is needed.
    private var residencyPlan: ResidencyPlan = .none

    /// `spawn_agent` entry point (agent context). The optional `modelOverride`
    /// is the eval seam.
    init(agentName: String, input: String, modelOverride: String? = nil) {
        self.target = .agent(name: agentName)
        self.input = input
        self.modelOverride = modelOverride
    }

    /// `spawn_model` entry point (bare model, no agent). The optional
    /// `modelOverride` is the eval seam (forces the run model + residency
    /// passthrough); production passes nil so the real residency decision runs.
    init(model: String, input: String, modelOverride: String? = nil) {
        self.target = .model(id: model)
        self.input = input
        self.modelOverride = modelOverride
    }

    /// Human label of the spawn target for error/result copy: the resolved
    /// agent name (or the requested name pre-resolve) in agent mode, the model
    /// id in model mode.
    private var targetLabel: String {
        switch target {
        case .agent(let name): return resolvedAgentName.isEmpty ? name : resolvedAgentName
        case .model(let id): return id
        }
    }

    var feedTitle: String {
        switch target {
        case .agent(let name): return "spawn → \(name)"
        case .model(let id): return "spawn → \(id)"
        }
    }

    func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel {
        let config = SubagentConfigurationStore.snapshot()
        // Per-agent allow-lists: the Default / main chat uses its own pools
        // (edited in the main chat's Subagents tab); a custom agent uses its own
        // lists (its Subagents tab), resolved from the launching agent (`scope`).
        // There is no global master switch.
        let isDefault = scope.agentId == Agent.defaultId
        // One launching-agent lookup feeds the per-agent spawn allow-lists,
        // permission, and budgets (Default / main chat → global config).
        let settings = await MainActor.run {
            AgentManager.shared.agent(for: scope.agentId)?.settings
        }

        // Permission gate is shared across both tools (one `spawn` capability).
        if SubagentToolVisibility.effectivePermission(
            capabilityId: capability.id,
            isDefault: isDefault,
            config: config,
            settings: settings
        ) == .deny {
            throw SubagentError.denied(
                "Spawning is denied by this agent's permission settings."
            )
        }

        self.budgets = SubagentToolVisibility.effectiveBudgets(
            isDefault: isDefault,
            config: config,
            settings: settings
        )
        self.toolAccess = SubagentToolVisibility.effectiveSpawnToolAccess(
            isDefault: isDefault,
            config: config,
            settings: settings
        )

        switch target {
        case .agent(let agentName):
            return try await resolveAgentTarget(
                agentName,
                scope: scope,
                isDefault: isDefault,
                config: config,
                settings: settings
            )
        case .model(let modelId):
            return try await resolveModelTarget(
                modelId,
                scope: scope,
                isDefault: isDefault,
                config: config,
                settings: settings
            )
        }
    }

    /// `spawn_agent`: gate the agent allow-list, resolve the agent (its
    /// system prompt becomes the seed system message), and resolve its model
    /// through the shared precedence (eval seam → per-agent override → the
    /// target agent's own model) + live residency decision.
    private func resolveAgentTarget(
        _ agentName: String,
        scope: SubagentScope,
        isDefault: Bool,
        config: SubagentConfiguration,
        settings: AgentSettings?
    ) async throws -> ResolvedModel {
        let perAgentTargets = settings?.spawnableAgentNames ?? []
        guard
            SubagentToolVisibility.spawnTargetAllowed(
                agentName,
                isDefault: isDefault,
                config: config,
                perAgentTargets: perAgentTargets
            )
        else {
            throw SubagentError.denied(
                Self.notSpawnableMessage(kind: "Agent", name: agentName, isDefault: isDefault)
            )
        }

        let agent = await MainActor.run {
            AgentManager.shared.agents.first {
                $0.name.caseInsensitiveCompare(agentName) == .orderedSame
            }
        }
        guard let agent else {
            throw SubagentError.unavailable("Agent '\(agentName)' not found.")
        }

        self.resolvedAgentName = agent.name
        self.resolvedAgentId = agent.id
        self.systemPrompt = agent.systemPrompt
        // The target agent's own sampling override rides along (a user-set
        // value, consistent with "defaults come from the model bundle unless
        // the user explicitly overrides").
        self.temperature = await MainActor.run {
            AgentManager.shared.effectiveTemperature(for: agent.id)
        }

        // One shared path for precedence (eval seam → per-agent `spawn` override
        // → the target agent's own model), the availability fallback, and the live
        // residency decision (reject-before-evict). The override is read from the
        // LAUNCHING agent (`scope.agentId`); the default is the target agent's model.
        let targetAgentId = agent.id
        let resolved = try await SubagentModelResolution.resolve(
            capabilityId: capability.id,
            agentId: scope.agentId,
            evalModel: modelOverride,
            idleWaitSeconds: self.budgets.maxElapsedSeconds,
            deniedMessage:
                "Spawning a different local agent requires \"Local Orchestrator Handoff\" enabled "
                + "in Settings → Subagents (so the chat model can unload to make room).",
            unavailableMessage: "Agent '\(agentName)' has no model configured.",
            defaultModel: { AgentManager.shared.effectiveModel(for: targetAgentId) }
        )
        self.residencyPlan = resolved.decision.plan
        return ResolvedModel(name: resolved.model, id: nil, isLocal: resolved.decision.isLocal)
    }

    /// `spawn_model`: gate the model allow-list, then run with NO agent (empty
    /// system prompt). The requested id is the explicit run model — it ranks
    /// above any per-agent override and still flows through the live residency
    /// decision (local target evicts, remote does not).
    private func resolveModelTarget(
        _ modelId: String,
        scope: SubagentScope,
        isDefault: Bool,
        config: SubagentConfiguration,
        settings: AgentSettings?
    ) async throws -> ResolvedModel {
        let perAgentModelTargets = settings?.spawnableModelNames ?? []
        guard
            SubagentToolVisibility.spawnModelAllowed(
                modelId,
                isDefault: isDefault,
                config: config,
                perAgentModelTargets: perAgentModelTargets
            )
        else {
            throw SubagentError.denied(
                Self.notSpawnableMessage(kind: "Model", name: modelId, isDefault: isDefault)
            )
        }

        // No agent: the bare model runs the task with just the user input.
        self.systemPrompt = ""

        // Production: `modelOverride` is nil, so `requestedModel` is the explicit
        // target and the live residency decision runs (local evicts, remote does
        // not). Eval seam: `modelOverride` forces the run model with residency
        // passthrough — the pool gate above still applies either way.
        let resolved = try await SubagentModelResolution.resolve(
            capabilityId: capability.id,
            agentId: scope.agentId,
            evalModel: modelOverride,
            requestedModel: modelId,
            idleWaitSeconds: self.budgets.maxElapsedSeconds,
            deniedMessage:
                "Spawning a local model requires \"Local Orchestrator Handoff\" enabled in "
                + "Settings → Subagents (so the chat model can unload to make room).",
            unavailableMessage: "Model '\(modelId)' is not available.",
            defaultModel: { nil }
        )
        self.residencyPlan = resolved.decision.plan
        return ResolvedModel(name: resolved.model, id: nil, isLocal: resolved.decision.isLocal)
    }

    func permission(_ scope: SubagentScope, _ resolved: ResolvedModel) async -> SubagentDecision {
        // All policy gates are resolved up front in `resolveModel`
        // (reject-before-evict); spawn has no interactive prompt.
        .allow
    }

    func makeHandoff() -> SubagentHandoff {
        SubagentResidency.handoff(for: residencyPlan)
    }

    func admissionClass(_ resolved: ResolvedModel) -> SubagentAdmissionClass {
        SubagentResidency.admissionClass(isLocal: resolved.isLocal, plan: residencyPlan)
    }

    func run(
        _ scope: SubagentScope,
        _ resolved: ResolvedModel,
        feed: SubagentFeed,
        interrupt: InterruptToken
    ) async throws -> SubagentResult {
        feed.emitPhase("running", detail: resolved.name)
        let budgets = self.budgets.normalized
        let deadline = Date().addingTimeInterval(TimeInterval(budgets.maxElapsedSeconds))
        let started = Date()
        let seed = seedMessages(systemPrompt: systemPrompt, input: input)
        let sessionId = "spawn-\((resolvedAgentId ?? UUID()).uuidString)-\(UUID().uuidString)"
        let toolset = await Self.makeToolset(
            access: toolAccess,
            maxToolCalls: budgets.maxToolCalls,
            feed: feed
        )

        let result = try await AgentSubagentRunner.run(
            modelName: resolved.name,
            seedMessages: seed,
            maxTokens: budgets.maxDelegateTokens,
            maxIterations: budgets.maxDelegateTurns,
            deadline: deadline,
            sessionId: sessionId,
            temperature: temperature,
            isInterrupted: { interrupt.isInterrupted },
            toolset: toolset,
            onProgress: { [feed] tokens, tokensPerSecond in
                // Live "generating" row: coalesced in place by the feed, so
                // long generations show advancing tokens + tok/s.
                var detail = "\(tokens) tokens"
                if let tokensPerSecond {
                    detail += String(format: " · %.1f tok/s", tokensPerSecond)
                }
                feed.emitProgress("generating", step: tokens, detail: detail)
            }
        )
        let elapsed = Date().timeIntervalSince(started)

        switch result.exit {
        case .finalResponse, .endedBySurface:
            let digest = (result.digest ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !digest.isEmpty else {
                throw SubagentError.executionFailed(
                    message: "Subagent '\(targetLabel)' finished without producing a result.",
                    retryable: true
                )
            }
            let capped =
                digest.count > Self.digestMaxChars
                ? String(digest.prefix(Self.digestMaxChars)) + "\n[digest truncated]"
                : digest
            // `agent` is only meaningful in agent mode; model-only spawns omit
            // it so the parent's envelope isn't littered with an empty field.
            var payload: [String: Any] = [
                "kind": "spawn_result",
                "model": resolved.name,
                "summary": capped,
                "iterations": result.iterations,
                "elapsed_seconds": elapsed,
                "handoff": residencyPlan.shouldUnload,
            ]
            if case .agent = target { payload["agent"] = resolvedAgentName }

            // Usage + context-saved accounting: what the worker consumed vs
            // what the digest costs the parent — the measurable "context
            // saved" per delegation.
            let usage = result.usage
            var usageDict: [String: Any] = [
                "prompt_tokens": usage.promptTokens,
                "completion_tokens": usage.completionTokens,
                "total_tokens": usage.promptTokens + usage.completionTokens,
            ]
            if let tps = usage.tokensPerSecond {
                usageDict["tokens_per_second"] = (tps * 10).rounded() / 10
            }
            payload["usage"] = usageDict
            let workerTokens = usage.promptTokens + usage.completionTokens
            let digestTokens = TokenEstimator.estimate(capped)
            payload["context"] = [
                "worker_tokens": workerTokens,
                "digest_tokens": digestTokens,
                "context_saved_tokens": max(0, workerTokens - digestTokens),
            ]
            return SubagentResult(payload: payload, summary: capped)
        case .cancelled:
            throw Self.cancelError(
                cause: result.cancelCause,
                label: targetLabel,
                maxElapsedSeconds: budgets.maxElapsedSeconds
            )
        case .iterationCapReached:
            throw SubagentError.iterationCap(
                "Subagent '\(targetLabel)' used all \(budgets.maxDelegateTurns) turns without a result."
            )
        case .toolRejected:
            throw SubagentError.toolRejected(
                "Subagent '\(targetLabel)' attempted unavailable child tool use."
            )
        case .overBudget:
            throw SubagentError.overBudget(
                "Subagent '\(targetLabel)' exceeded its context budget. Pass shorter input."
            )
        case .emptyResponseExhausted:
            throw SubagentError.emptyExhausted(
                "Subagent '\(targetLabel)' returned empty output after tool execution; the task may be incomplete."
            )
        }
    }

    /// Honest exit mapping for a `.cancelled` runner exit: the three cancel
    /// causes get DISTINCT copy (a user stop is not a "time budget" failure).
    /// Pure — unit-testable without a live runner.
    static func cancelError(
        cause: SubagentCancelCause?,
        label: String,
        maxElapsedSeconds: Int
    ) -> SubagentError {
        switch cause {
        case .userInterrupt:
            return .userDenied("Subagent '\(label)' was stopped by the user.")
        case .parentTask:
            return .executionFailed(
                message: "Subagent '\(label)' was cancelled with the parent run.",
                retryable: false
            )
        case .deadline, .none:
            return .timedOut(
                "Subagent '\(label)' hit its \(maxElapsedSeconds)s time budget."
            )
        }
    }

    /// Build the child's curated read-only toolset when the launching agent
    /// granted access; `nil` keeps the run text-only. The closure enforces the
    /// allowlist and the per-run tool-call cap, dispatches through the shared
    /// `ToolRegistry` (its permission gate + schema preflight included), and
    /// narrates each call to the live feed.
    ///
    /// `specs` / `dispatch` are injection seams for unit tests (production
    /// passes nil → live registry lookup + registry dispatch).
    static func makeToolset(
        access: SpawnToolAccess,
        maxToolCalls: Int,
        feed: SubagentFeed?,
        specs specsOverride: [Tool]? = nil,
        dispatch: (@Sendable (ServiceToolInvocation) async -> String)? = nil
    ) async -> AgentSubagentToolset? {
        guard access == .readOnly else { return nil }
        let specs: [Tool]
        if let specsOverride {
            specs = specsOverride
        } else {
            specs = await MainActor.run {
                ToolRegistry.shared.specs(forTools: readOnlyChildToolNames)
            }
        }
        guard !specs.isEmpty else { return nil }
        let allowed = Set(specs.map { $0.function.name })
        let cap = maxToolCalls > 0 ? maxToolCalls : defaultReadOnlyToolCallCap
        let counter = ToolCallCounter()
        let dispatchCall: @Sendable (ServiceToolInvocation) async -> String =
            dispatch
            ?? { invocation in
                do {
                    return try await ToolRegistry.shared.execute(
                        name: invocation.toolName,
                        argumentsJSON: invocation.jsonArguments
                    )
                } catch {
                    return ToolEnvelope.fromError(error, tool: invocation.toolName)
                }
            }
        return AgentSubagentToolset(
            specs: specs,
            execute: { [weak feed] invocation in
                guard allowed.contains(invocation.toolName) else {
                    return ToolEnvelope.failure(
                        kind: .rejected,
                        message:
                            "Tool '\(invocation.toolName)' is not available inside this subagent. "
                            + "Available: \(allowed.sorted().joined(separator: ", ")).",
                        tool: invocation.toolName,
                        retryable: false
                    )
                }
                let used = counter.increment()
                guard used <= cap else {
                    return ToolEnvelope.failure(
                        kind: .rejected,
                        message:
                            "Tool-call budget (\(cap)) exhausted for this subagent run. "
                            + "Produce your final answer from what you already have.",
                        tool: invocation.toolName,
                        retryable: false
                    )
                }
                feed?.emit(
                    SubagentActivityEvent(
                        step: used,
                        kind: .act,
                        title: invocation.toolName,
                        detail: Self.toolCallDetail(invocation)
                    )
                )
                return await dispatchCall(invocation)
            }
        )
    }

    /// Compact one-line feed detail for a child tool call: the `path` /
    /// `query` argument when present, else nothing (never the raw JSON).
    private static func toolCallDetail(_ invocation: ServiceToolInvocation) -> String? {
        guard let data = invocation.jsonArguments.data(using: .utf8),
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let value = (obj["path"] ?? obj["query"] ?? obj["pattern"]) as? String
        guard let value, !value.isEmpty else { return nil }
        return value.count > 80 ? String(value.prefix(80)) + "…" : value
    }

    /// Shared "not spawnable" denial copy for both targets, so the agent and
    /// model messages can't drift. `kind` is the capitalized noun ("Agent" /
    /// "Model"); the tab pointer differs for the main chat vs a custom agent.
    private static func notSpawnableMessage(kind: String, name: String, isDefault: Bool) -> String {
        isDefault
            ? "\(kind) '\(name)' is not spawnable. Add it in the main chat's Subagents tab."
            : "\(kind) '\(name)' is not spawnable from this agent. Add it in the agent's Subagents tab."
    }

    private func seedMessages(systemPrompt: String, input: String) -> [ChatMessage] {
        var msgs: [ChatMessage] = []
        let sys = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sys.isEmpty { msgs.append(ChatMessage(role: "system", content: sys)) }
        msgs.append(ChatMessage(role: "user", content: input))
        return msgs
    }
}

/// Thread-safe per-run tool-call counter for the child toolset closure
/// (parallel batches may execute two child calls concurrently).
private final class ToolCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// Increment and return the new total.
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}
