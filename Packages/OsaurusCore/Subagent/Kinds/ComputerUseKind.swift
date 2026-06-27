//
//  ComputerUseKind.swift
//  OsaurusCore — Subagent framework
//
//  The desktop-automation sub-agent kind that serves `computer_use`. It runs
//  the unchanged `ComputerUseLoop` (perceive → decide → gate → act → verify)
//  on the shared `SubagentSession` host so the recursion guard, the live
//  `SubagentFeed`, the interrupt token, and the compact-result contract are
//  shared with spawn / image / sandbox_reduce.
//
//  What stays computer-use specific (NOT generalized):
//    - The per-action `ComputerUseGate` + the `ComputerUsePromptQueue` confirm
//      / cloud-vision consent overlay. The host permission is `.allow` — the
//      real consent surface is the gate inside `run`, exactly as before.
//    - `modelSource = .inheritsParent`: the loop drives the SAME model as the
//      parent chat (no residency eviction; `makeHandoff()` stays passthrough).
//

import Foundation

/// Eval-only dependency injection for `ComputerUseKind`. Production callers
/// (`ComputerUseTool`) never set this; the OsaurusEvals `subagent` /
/// `computer_use` lane does. Bundling it lets `resolveModel` short-circuit the
/// MainActor agent/policy/vision lookups (there is no live agent in a headless
/// eval) and lets `run` drive the real `ComputerUseLoop` against a scripted,
/// in-memory `MacDriver` + a permissive gate. The host wrapper
/// (`SubagentSession` recursion guard, live feed, envelope mapping, compact
/// result) and the loop itself are exercised end to end, deterministically —
/// the desktop is never touched.
public struct ComputerUseEvalHarness: @unchecked Sendable {
    /// The model the loop drives (the eval run model, so the lane varies
    /// across the local-vs-frontier matrix even though the production kind
    /// inherits the parent agent's model).
    public let modelId: String
    /// The in-memory driver (e.g. `ScriptedCUDriver`) the loop perceives/acts on.
    public let driver: MacDriver
    /// The autonomy gate (typically a permissive `autonomous` preset).
    public let gate: ComputerUseGating
    /// Vision posture; `.none` keeps the loop on AX text only.
    public let vision: VisionContext
    /// Raw `agent_action` arguments-JSON strings that drive the loop with NO
    /// model call (the deterministic, CI-safe path). `nil` → the live `modelId`
    /// drives the loop (the model-planning lane).
    public let scriptedActions: [String]?

    public init(
        modelId: String,
        driver: MacDriver,
        gate: ComputerUseGating,
        vision: VisionContext = .none,
        scriptedActions: [String]? = nil
    ) {
        self.modelId = modelId
        self.driver = driver
        self.gate = gate
        self.vision = vision
        self.scriptedActions = scriptedActions
    }
}

final class ComputerUseKind: SubagentKind, @unchecked Sendable {
    let capability = SubagentCapabilityRegistry.computerUse

    private let goal: String
    private let limits: RunLimits
    /// Eval seam (nil in production). When set, `resolveModel`/`run` use the
    /// injected model + scripted driver/gate instead of the live desktop.
    private let evalHarness: ComputerUseEvalHarness?

    /// Snapshot resolved on the main actor in `resolveModel`, consumed by
    /// `run`. Captured once so a mid-run settings edit can't change the rules
    /// under the running loop.
    private struct RunConfig {
        let ceiling: AutonomyCeiling?
        let policy: AutonomyPolicy
        let vision: VisionContext
        let policySummary: String
    }
    private var config: RunConfig?

    init(goal: String, limits: RunLimits, evalHarness: ComputerUseEvalHarness? = nil) {
        self.goal = goal
        self.limits = limits
        self.evalHarness = evalHarness
    }

    var feedTitle: String { goal }

    func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel {
        // Eval seam: the harness supplies the model directly, so the headless
        // run never depends on a live agent / policy store. Same-model kind, so
        // `isLocal` is irrelevant (no residency handoff).
        if let evalHarness {
            return ResolvedModel(name: evalHarness.modelId, id: nil, isLocal: false)
        }
        let agentId = scope.agentId
        // Resolve everything that lives on the main actor in one hop: the model,
        // the agent's autonomy ceiling, a snapshot of the user policy, and the
        // vision context (image support + local-vs-cloud posture + cloud-vision
        // consent).
        let snapshot = await MainActor.run {
            () -> (model: String?, ceiling: AutonomyCeiling?, policy: AutonomyPolicy, vision: VisionContext) in
            let model = AgentManager.shared.effectiveModel(for: agentId)
            let ceiling = AgentManager.shared.agent(for: agentId)?.settings.computerUseCeiling
            let policy = ComputerUsePolicyStore.load()
            let vision: VisionContext
            if let model, !model.isEmpty {
                vision = VisionContext(
                    modelAcceptsImages: ComputerUseTool.modelAcceptsImages(model),
                    modelIsLocal: ModelManager.findInstalledModel(named: model) != nil,
                    cloudConsent: CloudVisionConsent.shared.isGranted,
                    cloudScrubMode: CloudVisionConsent.shared.scrubMode
                )
            } else {
                vision = .none
            }
            return (model, ceiling, policy, vision)
        }
        guard let modelId = snapshot.model, !modelId.isEmpty else {
            throw SubagentError.unavailable(
                "No model is selected for this agent, so Computer Use can't run. Pick a model first."
            )
        }
        self.config = RunConfig(
            ceiling: snapshot.ceiling,
            policy: snapshot.policy,
            vision: snapshot.vision,
            policySummary: ComputerUseTool.policySummary(
                policy: snapshot.policy,
                ceiling: snapshot.ceiling
            )
        )
        // Same-model kind: residency is irrelevant (no handoff), so `isLocal`
        // is not consulted.
        return ResolvedModel(name: modelId, id: nil, isLocal: false)
    }

    /// `.allow` at the host level: the consent surface is the per-action gate
    /// (`ComputerUseGate` + confirm overlay) wired inside `run`, not a per-call
    /// approval card. Accessibility preflight stays on the tool's
    /// `PermissionedTool` gate before the host is even reached.
    func permission(_ scope: SubagentScope, _ resolved: ResolvedModel) async -> SubagentDecision {
        .allow
    }

    func run(
        _ scope: SubagentScope,
        _ resolved: ResolvedModel,
        feed: SubagentFeed,
        interrupt: InterruptToken
    ) async throws -> SubagentResult {
        // Eval seam: drive the real loop against the injected scripted driver +
        // gate. No prompt queue (auto-approve), no telemetry, no desktop — the
        // host wrapper + loop + result contract are still exercised in full.
        if let evalHarness {
            let result = await ComputerUseLoop.run(
                goal: goal,
                modelId: resolved.name,
                driver: evalHarness.driver,
                gate: evalHarness.gate,
                feed: feed,
                interrupt: interrupt,
                confirm: { _ in true },
                limits: limits,
                policySummary: "",
                vision: evalHarness.vision,
                sessionId: scope.sessionId,
                nextAction: evalHarness.scriptedActions.map {
                    ComputerUseLoop.scriptedProvider(rawArguments: $0)
                }
            )
            return try Self.mapOutcome(result, model: resolved.name)
        }

        guard let config else {
            throw SubagentError.unavailable("Computer Use could not resolve its run configuration.")
        }
        let toolCallId = scope.toolCallId
        // The confirm/consent overlay drains off `ComputerUsePromptQueue`; clear
        // any pending prompts for this run when it ends (mirrors the old tool's
        // defer). The host only unregisters the feed + interrupt.
        defer {
            Task { @MainActor in
                ComputerUsePromptQueue.shared.cancelAll(forToolCallId: toolCallId)
            }
        }

        let result = await ComputerUseLoop.run(
            goal: goal,
            modelId: resolved.name,
            driver: NativeMacDriver(),
            gate: ComputerUseGate(policy: config.policy, ceiling: config.ceiling),
            feed: feed,
            interrupt: interrupt,
            confirm: { preview in
                await ComputerUsePromptQueue.shared.requestConfirmation(
                    preview,
                    toolCallId: toolCallId
                )
            },
            requestCloudVisionConsent: {
                await ComputerUsePromptQueue.shared.requestCloudVisionConsent(toolCallId: toolCallId)
            },
            limits: limits,
            policySummary: config.policySummary,
            vision: config.vision,
            sessionId: scope.sessionId
        )

        await MainActor.run {
            FeatureTelemetry.computerUseRun(
                result.metrics,
                outcome: ComputerUseTool.outcomeToken(result.outcome)
            )
        }
        return try Self.mapOutcome(result, model: resolved.name)
    }

    /// Map a finished `ComputerUseLoop` run onto the shared sub-agent result
    /// contract: `done` → a compact success payload; `interrupted` → a
    /// `user_denied` envelope; every other non-completion → a non-retryable
    /// `execution_error` carrying the loop's own reason so the parent can
    /// pivot without a blind retry. Shared by the production and eval paths so
    /// the envelope mapping the `subagent` eval lane asserts is the real one.
    private static func mapOutcome(
        _ result: ComputerUseRunResult,
        model: String
    ) throws -> SubagentResult {
        switch result.outcome {
        case .done(let summary):
            return SubagentResult(
                payload: [
                    "kind": "computer_use",
                    "model": model,
                    "summary": summary,
                    "steps": result.metrics.steps,
                ] as [String: Any],
                summary: summary
            )
        case .interrupted:
            throw SubagentError.userDenied("Computer Use was stopped by the user.")
        case .gaveUp, .deadEnd, .stepCapReached, .failed:
            throw SubagentError.executionFailed(message: result.outcome.summary, retryable: false)
        }
    }
}
