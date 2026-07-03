//
//  AppleScriptAccessibility.swift
//  OsaurusCore — AppleScript Computer Use
//
//  System Events UI scripting (keystroke / click / menus / UI elements) is the
//  fallback path for apps with no usable scripting dictionary, and it requires
//  the user's ACCESSIBILITY permission (TCC) for this process — a different
//  grant from the Automation/Apple Events consent that plain `tell application`
//  scripting triggers. This helper is the loop's lightweight preflight +
//  recovery seam:
//   • `requiresAccessibility` — pure signal detection over the script text, so
//     the loop can catch a doomed script BEFORE asking the user to approve it.
//   • `isGranted` / `promptForGrant` — the real AX trust check and the OS grant
//     dialog (attributed to Osaurus, mirroring `SystemPermissionService`).
//   • `isAccessibilityDenial` — maps the runtime "assistive access" errors so a
//     denial that slips past the preflight still reports as a PERMISSION
//     failure with the right recovery, not a generic runtime error.
//
//  Per the model-runtime non-negotiables this never fakes an outcome: a missing
//  grant is reported as exactly that, the OS dialog is the recovery, and the
//  script is simply not run until the user decides.
//

@preconcurrency import ApplicationServices
import Foundation

enum AppleScriptAccessibility {

    // MARK: - Detection (pure)

    /// UI-interaction forms that need Accessibility. Deliberately precise:
    /// process-level READS via System Events (`name of first process whose
    /// frontmost is true`) work with Automation permission alone, so a bare
    /// "System Events" mention must not trip the preflight — only actual UI
    /// scripting (keystrokes, clicks, menus, UI elements, `tell process` /
    /// window access on a process) does. A missed signal is still caught at
    /// runtime by `isAccessibilityDenial`, so precision beats recall here.
    private static let uiScriptingSignals: [String] = [
        "keystroke", "key code", "click", "menu bar", "menu item",
        "ui element", "tell process", "text field", "pop up button",
        "radio button", "checkbox", "window of process", "windows of process",
    ]

    /// Pure: whether `script` drives System Events UI scripting and therefore
    /// needs the user's Accessibility grant to run.
    static func requiresAccessibility(_ script: String) -> Bool {
        let lower = script.lowercased()
        guard lower.contains("system events") else { return false }
        return uiScriptingSignals.contains { lower.contains($0) }
    }

    // MARK: - Runtime denial mapping (pure)

    /// Error numbers System Events raises for a missing Accessibility grant:
    /// `-25211` (`kAXErrorAPIDisabled`, "not allowed assistive access") and
    /// `1002` ("not allowed to send keystrokes").
    private static let denialErrorNumbers: Set<Int> = [-25211, 1002]

    /// Whether a runtime error is an Accessibility (assistive access) denial —
    /// as opposed to the `-1743` Automation denial, which has its own recovery.
    static func isAccessibilityDenial(errorNumber: Int?, errorMessage: String?) -> Bool {
        if let errorNumber, denialErrorNumbers.contains(errorNumber) { return true }
        guard let message = errorMessage?.lowercased() else { return false }
        return message.contains("assistive access")
            || message.contains("not allowed to send keystrokes")
    }

    // MARK: - Live check + recovery

    /// Whether this process is currently trusted for Accessibility.
    static func isGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Fire the OS "Osaurus would like to control this computer" grant dialog
    /// (no-op if already trusted / already declined — the dialog shows at most
    /// once per TCC state; afterwards the user must toggle System Settings →
    /// Privacy & Security → Accessibility). Main-actor so the TCC prompt
    /// attaches to the app correctly, mirroring `SystemPermissionService`.
    @MainActor
    static func promptForGrant() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }
}
