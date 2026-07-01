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
        SubagentResidency.handoff(for: residencyPlan)
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

        let environment = await Self.desktopContext()
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
            environmentContext: environment,
            literals: literals
        )
        return try Self.mapOutcome(result, model: resolved.name, mode: mode)
    }

    /// A compact snapshot of the desktop (frontmost + running apps) injected
    /// into the subagent prompt so it scripts apps that are actually open
    /// (cutting a class of "the app wasn't running" failures). Best-effort:
    /// returns `nil` on any failure so the loop simply omits it.
    private static func desktopContext() async -> String? {
        await MainActor.run {
            let workspace = NSWorkspace.shared
            let running =
                workspace.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { $0.localizedName }
            guard !running.isEmpty else { return nil }
            let unique = NSOrderedSet(array: running).array.compactMap { $0 as? String }
            var lines: [String] = []
            if let frontmost = workspace.frontmostApplication?.localizedName {
                lines.append("Frontmost app: \(frontmost)")
            }
            lines.append("Running apps: \(unique.prefix(40).joined(separator: ", "))")
            return lines.joined(separator: "\n")
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
