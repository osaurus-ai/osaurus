//
//  ComputerUseGate.swift
//  OsaurusCore — Computer Use
//
//  The real, policy-driven gate (PR2). Replaces PR1's `HardwiredGate` while
//  conforming to the same `ComputerUseGating` protocol, so the loop is
//  unchanged — it still just asks for a `GateDecision` and obeys it.
//
//  Decision order (allowlist-first, per the spec):
//    1. If an allowlist is active and this app isn't on it → reject.
//    2. Otherwise resolve the strictest-wins disposition (global preset +
//       per-app override + per-agent ceiling) for the classified effect and
//       map it: allow → run, confirm → confirm(preview), deny → reject.
//

import Foundation

/// Policy-backed autonomy gate. Built once per run from a snapshot of the
/// user's `AutonomyPolicy` plus the calling agent's `AutonomyCeiling`, so a
/// mid-run settings edit can't change the rules under a running loop.
public struct ComputerUseGate: ComputerUseGating {
    public let policy: AutonomyPolicy
    public let ceiling: AutonomyCeiling?

    public init(policy: AutonomyPolicy, ceiling: AutonomyCeiling? = nil) {
        self.policy = policy
        self.ceiling = ceiling
    }

    public func evaluate(
        action: AgentAction,
        effect: EffectClass,
        appName: String?,
        targetLabel: String?
    ) async -> GateDecision {
        // 1) Allowlist is checked first, before any disposition.
        if !policy.isAppAllowed(appName) {
            let appLabel = appName ?? "this app"
            return .reject(
                reason:
                    "\(appLabel) is not on the Computer Use allowlist. Ask the user to add it in "
                    + "Settings → Computer Use, or work in an allowed app."
            )
        }

        // 2) Strictest-wins disposition for the classified effect, then a
        //    dangerous-app guardrail: driving a sensitive app (Terminal, System
        //    Settings, Keychain, a password manager, …) always confirms at least
        //    once, regardless of preset/override/ceiling and independent of the
        //    (often-empty) allowlist. Reads never reach here, so this only ever
        //    affects navigate/edit/consequential actions.
        var disposition = policy.disposition(for: effect, app: appName, ceiling: ceiling)
        if effect >= .navigate, policy.requiresForcedConfirm(app: appName) {
            disposition = AutonomyDisposition.strictest(disposition, .confirm)
        }
        switch disposition {
        case .allow:
            return .run
        case .confirm:
            return .confirm(
                ActionPreview(
                    appName: appName,
                    actionLabel: action.feedLabel,
                    targetLabel: targetLabel,
                    effect: effect,
                    note: action.note,
                    typedText: action.typedTextForPreview
                )
            )
        case .deny:
            return .reject(
                reason:
                    "The current autonomy policy blocks \(effect.displayLabel.lowercased()) actions"
                    + (appName.map { " in \($0)" } ?? "")
                    + ". Raise the policy in Settings → Computer Use to allow it, or take a different action."
            )
        }
    }
}
