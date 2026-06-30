//
//  ComputerUseTool.swift
//  OsaurusCore — Computer Use
//
//  The single model-facing entry point for the Computer Use feature. The
//  parent agent calls `computer_use(goal:)` once; this thin tool parses the
//  arguments and hands a `ComputerUseKind` to the shared `SubagentSession`
//  host, which runs the nested perceive→decide→gate→act→verify loop and
//  returns a single summary. The inner agent_action steps never leak into the
//  parent transcript — they surface only through the shared `SubagentFeed`
//  rendered in the chat row.
//
//  Gating: registered as a built-in so the runtime can execute it and
//  ChatView can intercept its feed, but the system prompt composer strips
//  it authoritatively unless the agent set `computerUseEnabled` (custom
//  agents only). Conforms to `PermissionedTool` so execution preflights
//  Accessibility before the loop runs and fails cleanly otherwise.
//

import Foundation

/// `computer_use` — drive a macOS app to accomplish a natural-language goal.
final class ComputerUseTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    static let toolName = "computer_use"

    let name = ComputerUseTool.toolName

    let description =
        "Operate a macOS app on the user's behalf to accomplish a goal, working primarily from the "
        + "on-screen accessibility tree and falling back to a screenshot only when an element can't be "
        + "resolved. Describe the WHOLE task in `goal` as one instruction — "
        + "this runs a self-contained subagent that perceives the screen, clicks, types, and "
        + "verifies each step on its own, then returns a summary. Reads and navigation happen "
        + "automatically; edits and anything consequential pause for the user to approve. Use this "
        + "for desktop UI automation (filling a form, navigating an app, extracting on-screen text), "
        + "NOT for shell, files, or web requests — those have dedicated tools."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "goal": .object([
                "type": .string("string"),
                "description": .string(
                    "The complete task to accomplish, in plain language, naming the app when it matters. "
                        + "Example: \"In System Settings, turn on Night Shift from sunset to sunrise.\""
                ),
            ]),
            "max_steps": .object([
                "type": .string("integer"),
                "description": .string(
                    "Optional safety cap on the number of perceive→act cycles (default 24). Raise only for "
                        + "genuinely long tasks."
                ),
            ]),
        ]),
        "required": .array([.string("goal")]),
    ])

    // Accessibility is the floor for the PR1 ax-mode loop. Screen Recording is
    // only needed once SOM/Vision capture tiers ship (PR3); it is surfaced in
    // the Computer Use settings panel but not required to start an ax run.
    let requirements: [String] = [SystemPermission.accessibility.rawValue]

    // `.auto`: the per-action gate (HardwiredGate + confirm overlay) is the
    // real consent surface, so we don't stack a per-call approval card on top.
    // The permission gate still preflights Accessibility and fails cleanly
    // (kind `.unavailable`) when it's missing.
    let defaultPermissionPolicy: ToolPermissionPolicy = .auto

    // The loop drives a real app over many model turns; like `shell_run` it has
    // no usable wall-clock budget, so it opts out of the registry's 120s race
    // and relies on its own `RunLimits` + the user's stop control instead.
    var bypassRegistryTimeout: Bool { true }

    init() {}

    /// Whether the active model can accept image input — gates whether the loop
    /// may ever escalate to attaching a screenshot. Local bundles are checked via
    /// the media-capability heuristic + VLM bundle detection; remote models trust
    /// the router's advertised vision capability.
    @MainActor
    static func modelAcceptsImages(_ modelId: String) -> Bool {
        let id = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty || id.caseInsensitiveCompare("foundation") == .orderedSame { return false }
        if ModelMediaCapabilities.from(modelId: id).supportsImage { return true }
        if ModelManager.findInstalledModel(named: id) != nil {
            return VLMDetection.isVLM(modelId: id)
        }
        let unprefixed = id.split(separator: "/").dropFirst().joined(separator: "/")
        if let meta = RemoteProviderManager.shared.osaurusRouterMetadata(for: unprefixed) {
            return meta.supportsVision
        }
        return false
    }

    /// A short, model-facing description of the active autonomy stance, injected
    /// into the loop's system prompt so the model can anticipate what auto-runs
    /// vs. confirms vs. blocks instead of discovering it by trial and error.
    static func policySummary(policy: AutonomyPolicy, ceiling: AutonomyCeiling?) -> String {
        var parts: [String] = ["\(policy.globalPreset.displayLabel) — \(policy.globalPreset.detail)"]
        if let allowlist = policy.allowlist, !allowlist.isEmpty {
            parts.append("Only these apps may be used: \(allowlist.joined(separator: ", ")).")
        }
        if let ceiling, !ceiling.isEmpty, let preset = ceiling.matchingPreset {
            parts.append("This agent is capped at \(preset.displayLabel).")
        }
        return parts.joined(separator: " ")
    }

    /// Stable, low-cardinality token for the run outcome (telemetry only).
    static func outcomeToken(_ outcome: RunOutcome) -> String {
        switch outcome {
        case .done: return "done"
        case .gaveUp: return "gave_up"
        case .deadEnd: return "dead_end"
        case .stepCapReached: return "step_cap"
        case .interrupted: return "interrupted"
        case .failed: return "failed"
        }
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let goalReq = requireString(
            args,
            "goal",
            expected: "the complete task to accomplish, in plain language",
            tool: name
        )
        guard case .value(let rawGoal) = goalReq else { return goalReq.failureEnvelope ?? "" }
        let goal = rawGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`goal` must be a non-empty instruction.",
                field: "goal",
                expected: "non-empty task description",
                tool: name
            )
        }

        // Limits: honour an explicit `max_steps`, clamped to a sane range.
        var limits = RunLimits()
        if let raw = args["max_steps"], !(raw is NSNull) {
            if let n = coerceInt(raw) {
                limits = RunLimits(maxSteps: min(max(n, 1), 100))
            } else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "`max_steps` must be an integer.",
                    field: "max_steps",
                    expected: "integer step cap",
                    tool: name
                )
            }
        }

        // Model resolution, the per-action gate + confirm overlay, the live
        // feed, the interrupt token, and the compact result all run through the
        // shared `SubagentSession` host via `ComputerUseKind`.
        return await SubagentSession.run(
            ComputerUseKind(goal: goal, limits: limits),
            tool: name
        )
    }
}
