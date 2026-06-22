//
//  ComputerUseContextPreflight.swift
//  OsaurusCore -- Computer Use
//
//  Run-start contextual-integrity checks. These happen after the local driver
//  has identified the frontmost app, but before the rendered AX view is added
//  to the inner model transcript. That gap matters: action-level gates protect
//  clicks and typing, while this preflight protects the starting context itself.
//

import Foundation

public enum ComputerUseContextPreflightDecision: Sendable, Equatable {
    case allow
    case confirm(ActionPreview, reason: String)
    case reject(reason: String)
}

public struct ComputerUseContextPreflight: Sendable, Equatable {
    public var policy: AutonomyPolicy
    public var ceiling: AutonomyCeiling?
    public var modelIsLocal: Bool
    public var enabled: Bool

    public init(
        policy: AutonomyPolicy = .defaultPolicy,
        ceiling: AutonomyCeiling? = nil,
        modelIsLocal: Bool = true,
        enabled: Bool = true
    ) {
        self.policy = policy
        self.ceiling = ceiling
        self.modelIsLocal = modelIsLocal
        self.enabled = enabled
    }

    public static let disabled = ComputerUseContextPreflight(enabled: false)

    public func evaluate(
        goal: String,
        appName: String?,
        focusedWindow: String?
    ) -> ComputerUseContextPreflightDecision {
        guard enabled else { return .allow }
        guard let appName = clean(appName) else { return .allow }

        if hasActiveAllowlist, !policy.isAppAllowed(appName) {
            return .reject(
                reason:
                    "\(appName) is not on the Computer Use allowlist. Switch to an allowed app or add it "
                    + "in Settings before starting, so the starting window is not exposed to the "
                    + "computer-use model."
            )
        }

        if policy.requiresForcedConfirm(app: appName) {
            return .confirm(
                preview(appName: appName, focusedWindow: focusedWindow),
                reason:
                    "Computer Use is starting in \(appName), which can expose secrets, run code, or "
                    + "change system state. Confirm that this is the intended context before the inner "
                    + "model receives the current view."
            )
        }

        if !modelIsLocal, Self.isPrivacySensitiveContext(appName) {
            return .confirm(
                preview(appName: appName, focusedWindow: focusedWindow),
                reason:
                    "Computer Use is starting in \(appName) while the selected model is not local. "
                    + "The accessibility view can include private on-screen text, so confirm before "
                    + "that context leaves this Mac."
            )
        }

        _ = goal  // Reserved for future task/app intent matching without widening call sites.
        return .allow
    }

    public static func isPrivacySensitiveContext(_ appName: String?) -> Bool {
        guard let appName = clean(appName) else { return false }
        let normalized = AutonomyPolicy.normalize(appName)
        return privacySensitiveAppNeedles.contains { normalized.contains($0) }
    }

    private var hasActiveAllowlist: Bool {
        guard let allowlist = policy.allowlist else { return false }
        return !allowlist.isEmpty
    }

    private func preview(appName: String, focusedWindow: String?) -> ActionPreview {
        ActionPreview(
            appName: appName,
            actionLabel: "Start Computer Use",
            targetLabel: clean(focusedWindow),
            effect: .read,
            note: nil
        )
    }

    private static let privacySensitiveAppNeedles: Set<String> = [
        "mail", "com.apple.mail",
        "messages", "com.apple.messages", "com.apple.imservice", "com.apple.ichat",
        "safari", "com.apple.safari",
        "chrome", "google chrome", "com.google.chrome",
        "firefox", "org.mozilla.firefox",
        "edge", "microsoft edge", "com.microsoft.edgemac",
        "brave", "com.brave.browser",
        "arc", "company.thebrowser.browser",
        "calendar", "com.apple.ical",
        "contacts", "com.apple.addressbook",
        "slack", "discord", "teams", "zoom",
    ]
}

private func clean(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
