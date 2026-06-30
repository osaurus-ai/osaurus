//
//  Gate.swift
//  OsaurusCore — Computer Use
//
//  The gate seam. The loop never decides autonomy itself — it asks a
//  `ComputerUseGating` for a `GateDecision` and obeys it. PR1 ships the
//  `HardwiredGate` (anything past `navigate` must be confirmed, nothing
//  consequential auto-runs). PR2 adds the real policy-driven
//  `ComputerUseGate` (allowlist + presets + per-app overrides + per-agent
//  ceiling) conforming to the same protocol, so the loop is unchanged.
//

import Foundation

/// A human-readable description of a pending action, shown in the confirm
/// surface and the activity feed.
public struct ActionPreview: Sendable, Equatable {
    public let appName: String?
    public let actionLabel: String
    public let targetLabel: String?
    public let effect: EffectClass
    public let note: String?
    /// The full text payload for type/set actions, shown expandably on the
    /// confirm card so a long string isn't hidden behind the feed's 40-char
    /// truncation. `nil` for actions that type nothing.
    public let typedText: String?
    /// The full AppleScript body for an `applescript` subagent confirmation,
    /// rendered monospaced (and scrollable) on the confirm card so the user
    /// sees exactly what will run before approving. `nil` for Computer Use
    /// actions, which carry no script.
    public let scriptBody: String?

    public init(
        appName: String?,
        actionLabel: String,
        targetLabel: String?,
        effect: EffectClass,
        note: String?,
        typedText: String? = nil,
        scriptBody: String? = nil
    ) {
        self.appName = appName
        self.actionLabel = actionLabel
        self.targetLabel = targetLabel
        self.effect = effect
        self.note = note
        self.typedText = typedText
        self.scriptBody = scriptBody
    }

    /// One-line summary for the feed / prompt.
    public var summary: String {
        var s = actionLabel
        if let targetLabel, !targetLabel.isEmpty { s += " — \(targetLabel)" }
        if let appName, !appName.isEmpty { s += " in \(appName)" }
        return s
    }
}

/// What the gate decided for one proposed action.
public enum GateDecision: Sendable, Equatable {
    /// Auto-run with no prompt.
    case run
    /// Pause and ask the user; carries the preview to show.
    case confirm(ActionPreview)
    /// Refuse outright (e.g. app not allowlisted). `reason` is fed to the model.
    case reject(reason: String)
}

/// The autonomy decision seam.
public protocol ComputerUseGating: Sendable {
    func evaluate(
        action: AgentAction,
        effect: EffectClass,
        appName: String?,
        targetLabel: String?
    ) async -> GateDecision
}

/// PR1 gate: read + navigate run freely; everything past navigate (edit,
/// consequential) is confirmed. Nothing consequential can auto-run before
/// the PR2 policy gate exists.
public struct HardwiredGate: ComputerUseGating {
    public init() {}

    public func evaluate(
        action: AgentAction,
        effect: EffectClass,
        appName: String?,
        targetLabel: String?
    ) async -> GateDecision {
        if effect <= .navigate { return .run }
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
    }
}
