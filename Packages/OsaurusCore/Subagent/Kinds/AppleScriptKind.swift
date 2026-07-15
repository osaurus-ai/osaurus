//
//  AppleScriptKind.swift
//  OsaurusCore — Subagent framework
//
//  The AppleScript subagent kind that serves the `applescript` tool. It
//  resolves an INSTALLED on-device AppleScript model (a dedicated bundle, like
//  `image`), drives `AppleScriptLoop` to generate + run AppleScript, and hands
//  back a compact summary on the shared `SubagentSession` host.
//
//  `modelSource = .dedicatedConfigured` and `supportsModelOverride = false`:
//  AppleScript owns its own model system (the curated `AppleScriptModelCatalog`,
//  a per-agent / global `appleScriptModelId`, and a first-installed fallback),
//  so it is NOT a `SubagentModelResolution` client and AgentsView renders its
//  own picker instead of the shared override row — exactly the divergence
//  `image` established.
//
//  Residency: the AppleScript model is ALWAYS a different bundle than the
//  resident chat model, so when a chat model is loaded this kind must unload it
//  for the run (single-GPU residency) and reload after. It forces that handoff
//  independent of the global "Local Orchestrator Handoff" toggle (which exists
//  for the chat-driven kinds), because requiring an unrelated toggle would make
//  the feature unusable. The per-script consent surface is the execution-mode
//  gate inside the loop (confirm-each / auto-run-with-warning), so the host
//  permission is `.allow`.
//

import AppKit
import Foundation

final class AppleScriptKind: SubagentKind, @unchecked Sendable {
    let capability = SubagentCapabilityRegistry.appleScript

    private let task: String
    private let limits: RunLimits
    /// Read-only information `query` (`mac_query`) vs. state-changing `automate`
    /// (`applescript`). Drives the loop's prompt + per-script gate.
    private let mode: AppleScriptRunMode
    /// Out-of-band verbatim content (the `content` string and/or `contents`
    /// map tool args) the subagent can insert by `{{name}}` placeholder instead
    /// of re-typing it. Empty when the caller passed none.
    private let literals: AppleScriptLiterals

    /// Resolved in `resolveModel`, consumed by `run`. Captured once so a mid-run
    /// settings edit can't change the rules under the running loop.
    private var executionMode: AppleScriptExecutionMode = .default
    /// Residency plan resolved up front (reject-before-evict), run by
    /// `makeHandoff()`. `.none` when nothing else is resident.
    private var residencyPlan: ResidencyPlan = .none
    /// Keep-warm policy snapshotted in `resolveModel`, consumed by
    /// `makeHandoff()`. Under keep-warm the chat restore is deferred so a
    /// back-to-back AppleScript call reuses the resident model.
    private var loadPolicy: AppleScriptLoadPolicy = .default
    /// The resolved model id, captured for the warm handoff (which keys the
    /// deferred restore on the model kept resident).
    private var resolvedModelId: String = ""
    /// Read-model split: true when this `mac_query` run generates on the
    /// ALREADY-RESIDENT chat model instead of the dedicated AppleScript model.
    /// Nothing is swapped, so `makeHandoff()` must stay a passthrough (no
    /// residency handoff and no warm hold to schedule).
    private var usingResidentChatModel = false

    /// Idle-wait budget (seconds) for the residency unload to wait for chat to
    /// go idle before giving up. Bounds only the pre-unload wait; the run itself
    /// is step-capped via `RunLimits`.
    private static let residencyIdleWaitSeconds = 120

    init(
        task: String,
        limits: RunLimits,
        mode: AppleScriptRunMode = .automate,
        literals: AppleScriptLiterals = AppleScriptLiterals()
    ) {
        self.task = task
        self.limits = limits
        self.mode = mode
        self.literals = literals
    }

    var feedTitle: String { task }

    // MARK: - Model resolution (reject-before-evict)

    func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel {
        let config = SubagentConfigurationStore.snapshot()
        let isDefault = scope.agentId == Agent.defaultId
        let settings = await MainActor.run {
            AgentManager.shared.agent(for: scope.agentId)?.settings
        }

        // Per-agent enable (no global master switch): Default / main chat → its
        // own AppleScript switch; a custom agent → its own `appleScriptEnabled`.
        let available = SubagentToolVisibility.appleScriptAvailable(
            isDefault: isDefault,
            config: config,
            perAgentEnabled: settings?.appleScriptEnabled ?? false
        )
        guard available else {
            throw SubagentError.denied("AppleScript is not enabled for this agent.")
        }

        // Dedicated model: the configured per-agent / global id, else the first
        // installed catalog model. `nil` → none installed → fail cleanly.
        let preferred = SubagentToolVisibility.effectiveAppleScriptModel(
            isDefault: isDefault,
            config: config,
            settings: settings
        )
        guard let modelId = AppleScriptModelCatalog.resolveInstalledModelId(preferred: preferred)
        else {
            throw SubagentError.unavailable(
                "No AppleScript model is installed. Download one in Settings → Computer Use → Models."
            )
        }

        self.executionMode = SubagentToolVisibility.effectiveAppleScriptExecutionMode(
            isDefault: isDefault,
            config: config,
            settings: settings
        )
        self.loadPolicy = config.appleScriptLoadPolicy
        self.resolvedModelId = modelId

        // Read-model split: a `mac_query` READ is simpler than automation, so
        // when a tool-capable local chat model is ALREADY resident, run the
        // query on it and skip the multi-GB dedicated-model handoff entirely —
        // the most common path costs no swap at all. `applescript` automation
        // always uses the dedicated model, and a query still prefers the
        // dedicated model whenever IT is the resident one (a keep-warm hold).
        // The query gate blocks any mutation regardless of which model writes
        // the script, so this trades only read-script quality for latency.
        if mode == .query, config.appleScriptQueryPrefersResidentModel,
            let resident = await Self.residentQueryModel(dedicatedModelId: modelId)
        {
            self.resolvedModelId = resident
            self.usingResidentChatModel = true
            self.residencyPlan = .none
            return ResolvedModel(name: resident, id: resident, isLocal: true)
        }

        // Single-GPU residency: the AppleScript bundle differs from any resident
        // chat model, so force the handoff (independent of the global toggle).
        let decision = try await SubagentResidency.resolve(
            modelName: modelId,
            config: config,
            idleWaitSeconds: Self.residencyIdleWaitSeconds,
            deniedMessage:
                "AppleScript needs to load its own model, which requires unloading the chat model to "
                + "make room.",
            handoffEnabledOverride: true
        )
        self.residencyPlan = decision.plan
        return ResolvedModel(name: modelId, id: modelId, isLocal: decision.isLocal)
    }

    func makeHandoff() -> SubagentHandoff {
        // Read path on the resident chat model: nothing was swapped and the
        // model must stay exactly where it is — plain passthrough, and the
        // warm coordinator must NOT adopt or schedule anything.
        if usingResidentChatModel {
            return SubagentResidency.handoff(for: residencyPlan)
        }
        // Keep-warm: route the chat restore through the warm coordinator so a
        // back-to-back AppleScript call reuses the resident model. A run whose
        // model is already resident (a warm hold from the previous run) resolves
        // to `.none`, but the warm handoff still adopts + re-arms the hold, so
        // route through it whenever keep-warm is on and this is a local run.
        let keepWarmSeconds = loadPolicy.keepWarmSeconds
        if keepWarmSeconds > 0, !resolvedModelId.isEmpty {
            return AppleScriptWarmResidencyHandoff.production(
                plan: residencyPlan,
                model: resolvedModelId,
                keepWarmSeconds: keepWarmSeconds
            )
        }
        return SubagentResidency.handoff(for: residencyPlan)
    }

    func admissionClass(_ resolved: ResolvedModel) -> SubagentAdmissionClass {
        // An AppleScript model is always a local MLX graph, so its run always
        // generates on the GPU and must own it exclusively — including a
        // keep-warm run whose model is ALREADY resident (residency plan `.none`),
        // which the plan-based mapping would otherwise treat as a shareable
        // in-place run. Exclusive admission keeps a concurrent subagent from
        // loading a second graph alongside the warm AppleScript model.
        if resolved.isLocal { return .localExclusive }
        return SubagentResidency.admissionClass(isLocal: resolved.isLocal, plan: residencyPlan)
    }

    /// The resident local chat model a `mac_query` read can reuse, or `nil` to
    /// fall back to the dedicated-model path. `nil` when nothing is resident,
    /// when the DEDICATED AppleScript model is itself resident (a keep-warm
    /// hold — that path is then already swap-free and better tuned), or when
    /// no resident model is tool-capable (the loop needs a real
    /// `run_applescript` tool call; a model that can't emit one would burn the
    /// step budget producing nothing).
    private static func residentQueryModel(dedicatedModelId: String) async -> String? {
        let summaries = await ModelRuntime.shared.cachedModelSummaries()
        guard !summaries.isEmpty else { return nil }
        // Compare on canonical installed-bundle names, same as
        // `SubagentResidency.resolve` (runtime records canonical names; the
        // catalog id is a full repo id).
        let dedicatedCanonical =
            ModelManager.findInstalledModel(named: dedicatedModelId)?.name ?? dedicatedModelId
        let residentCanonical = summaries.map { summary in
            ModelManager.findInstalledModel(named: summary.name)?.name ?? summary.name
        }
        if residentCanonical.contains(where: {
            $0.caseInsensitiveCompare(dedicatedCanonical) == .orderedSame
        }) {
            return nil
        }
        // Prefer the CURRENT model (the one chat actively uses) over other
        // residents under a flexible multi-model policy.
        let ordered = summaries.sorted { $0.isCurrent && !$1.isCurrent }
        for summary in ordered {
            guard let found = ModelManager.findInstalledModel(named: summary.name) else {
                continue
            }
            guard
                MLXService.supportsLocalToolCalling(modelName: found.name, modelId: found.id)
            else { continue }
            return found.name
        }
        return nil
    }

    /// `.allow` at the host level: the consent surface is the per-script
    /// execution-mode gate inside `run` (confirm-each / auto-run-with-warning),
    /// not a per-call approval card.
    func permission(_ scope: SubagentScope, _ resolved: ResolvedModel) async -> SubagentDecision {
        .allow
    }

    func run(
        _ scope: SubagentScope,
        _ resolved: ResolvedModel,
        feed: SubagentFeed,
        interrupt: InterruptToken
    ) async throws -> SubagentResult {
        let toolCallId = scope.toolCallId
        // The confirm overlay drains off `ComputerUsePromptQueue` (shared with
        // Computer Use); clear any pending prompt for this run when it ends.
        defer {
            Task { @MainActor in
                ComputerUsePromptQueue.shared.cancelAll(forToolCallId: toolCallId)
            }
        }

        let desktop = await Self.desktopSnapshot()
        // App knowledge for the app(s) the task targets: the distilled
        // scripting dictionary (sdef) + curated idiom tips. Composed off the
        // main actor (disk/XML work); the loop injects it harness-gated.
        let targetApps = AppleScriptAppKnowledge.detectTargetApps(
            task: task,
            frontmost: desktop.frontmost,
            runningAppNames: desktop.running.map(\.name)
        )
        let knowledge = AppleScriptAppKnowledge.compose(
            apps: targetApps,
            runningApps: desktop.running
        )
        let result = await AppleScriptLoop.run(
            task: task,
            modelId: resolved.name,
            feed: feed,
            interrupt: interrupt,
            executionMode: executionMode,
            confirm: { preview in
                await ComputerUsePromptQueue.shared.requestConfirmation(
                    preview,
                    toolCallId: toolCallId
                )
            },
            limits: limits,
            sessionId: scope.sessionId,
            mode: mode,
            environmentContext: desktop.contextText,
            dictionaryContext: knowledge.dictionary,
            recipeContext: knowledge.recipes,
            literals: literals
        )
        return try Self.mapOutcome(result, model: resolved.name, mode: mode)
    }

    /// A compact snapshot of the desktop: the prompt text (frontmost + running
    /// apps, cutting a class of "the app wasn't running" failures) plus the
    /// structured app list (with bundle URLs) the dictionary lookup uses.
    /// Best-effort: empty on any failure so the loop simply omits it.
    private static func desktopSnapshot() async -> (
        contextText: String?, frontmost: String?, running: [AppleScriptAppKnowledge.RunningApp]
    ) {
        await MainActor.run {
            let workspace = NSWorkspace.shared
            let running =
                workspace.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { app -> AppleScriptAppKnowledge.RunningApp? in
                    guard let name = app.localizedName, !name.isEmpty else { return nil }
                    return AppleScriptAppKnowledge.RunningApp(
                        name: name,
                        bundleURL: app.bundleURL
                    )
                }
            guard !running.isEmpty else { return (nil, nil, []) }
            var unique: [AppleScriptAppKnowledge.RunningApp] = []
            var seen = Set<String>()
            for app in running where seen.insert(app.name.lowercased()).inserted {
                unique.append(app)
            }
            let frontmost = workspace.frontmostApplication?.localizedName
            var lines: [String] = []
            if let frontmost { lines.append("Frontmost app: \(frontmost)") }
            lines.append(
                "Running apps: \(unique.prefix(40).map(\.name).joined(separator: ", "))"
            )
            return (lines.joined(separator: "\n"), frontmost, unique)
        }
    }

    /// Map a finished `AppleScriptLoop` run onto the shared subagent result
    /// contract. `done` → the rich success payload. `interrupted` → a
    /// `user_denied` envelope. A `stepCapReached` / `failed` run that ACTUALLY
    /// RAN scripts still returns the rich payload (with an honest
    /// `failed`/`partial` status + the transcript) so the parent can
    /// troubleshoot — only a run where nothing executed is a hard tool failure.
    static func mapOutcome(
        _ result: AppleScriptRunResult,
        model: String,
        mode: AppleScriptRunMode
    ) throws -> SubagentResult {
        switch result.outcome {
        case .done(let summary):
            return successResult(result, model: model, mode: mode, summary: summary)
        case .interrupted:
            throw SubagentError.userDenied("AppleScript was stopped by the user.")
        case .stepCapReached, .failed:
            guard result.scriptsExecuted > 0 else {
                throw SubagentError.executionFailed(
                    message: result.outcome.summary,
                    retryable: false
                )
            }
            return successResult(result, model: model, mode: mode, summary: result.outcome.summary)
        }
    }

    /// Assemble the parent-facing payload: the headline `values`, an honest
    /// aggregate `status` (`succeeded` / `partial` / `failed`), and a capped
    /// per-step transcript plus convenience `errors` / `permission_needed`. The
    /// top-level envelope `ok` means "the tool ran"; the task outcome lives in
    /// `status`, so the two never collide.
    private static func successResult(
        _ result: AppleScriptRunResult,
        model: String,
        mode: AppleScriptRunMode,
        summary: String
    ) -> SubagentResult {
        var payload: [String: Any] = [
            "kind": "applescript",
            "mode": mode.rawValue,
            "model": model,
            "status": aggregateStatus(result),
            "summary": summary,
            "scripts_run": result.scriptsExecuted,
            "succeeded": result.succeeded,
            "failed": result.failed,
        ]
        // Runtime-proof telemetry (AGENTS.md: every generation row records
        // token/s). `tokens_per_second` is generation throughput over the time
        // spent in model steps only; omitted (never fabricated) when the run
        // generated nothing.
        if result.elapsedSeconds > 0 {
            payload["elapsed_seconds"] = round(result.elapsedSeconds * 100) / 100
        }
        payload["model_tokens"] = result.modelTokens
        if let tps = result.tokensPerSecond {
            payload["tokens_per_second"] = round(tps * 10) / 10
        }
        if let values = result.lastOutput, !values.isEmpty {
            payload["values"] = cap(values, 2_000)
        }
        if !result.steps.isEmpty {
            payload["steps"] = result.steps.map(stepDict)
        }
        let errors = result.steps.filter { failureStatuses.contains($0.status) }
        if !errors.isEmpty {
            payload["errors"] = errors.map(stepDict)
        }
        let permissions =
            result.steps
            .filter { $0.status == "permission_required" }
            .compactMap { $0.error }
        if !permissions.isEmpty {
            payload["permission_needed"] = Array(Set(permissions))
        }
        return SubagentResult(payload: payload, summary: summary)
    }

    private static let failureStatuses: Set<String> = [
        "compile_error", "runtime_error", "permission_required", "timed_out",
    ]

    /// Honest task outcome: `failed` when every executed script errored,
    /// `partial` when some did (or the run stopped early), else `succeeded`.
    private static func aggregateStatus(_ result: AppleScriptRunResult) -> String {
        if result.scriptsExecuted == 0 { return result.outcome.isSuccess ? "succeeded" : "failed" }
        if result.failed == 0 { return result.outcome.isSuccess ? "succeeded" : "partial" }
        if result.succeeded == 0 { return "failed" }
        return "partial"
    }

    private static func stepDict(_ step: AppleScriptStepRecord) -> [String: Any] {
        var dict: [String: Any] = [
            "n": step.n,
            "intent": step.intent,
            "status": step.status,
        ]
        if let output = step.output, !output.isEmpty { dict["output"] = cap(output, 1_000) }
        if let error = step.error, !error.isEmpty { dict["error"] = cap(error, 600) }
        if let number = step.errorNumber { dict["error_number"] = number }
        if let preview = step.scriptPreview, !preview.isEmpty { dict["script"] = preview }
        return dict
    }

    private static func cap(_ text: String, _ maxChars: Int) -> String {
        text.count > maxChars ? String(text.prefix(maxChars)) + "…" : text
    }
}
