//
//  ImportHistoryPromptGate.swift
//  osaurus
//
//  One-time post-onboarding "import your chat history" suggestion for
//  brand-new users. Mirrors ProductHuntLaunchCampaign minus the date
//  window: this type only owns the persisted seen flag and the
//  in-memory duplicate-presentation guard so it is trivially
//  unit-testable with an injected defaults suite. Presentation and
//  deferral (chat window up, no other modals) live in
//  `AppDelegate.presentImportHistoryPromptIfEligible()`.
//

import Foundation

@MainActor
public final class ImportHistoryPromptGate {
    public static let shared = ImportHistoryPromptGate()

    /// Namespaced so future one-time prompts can ship their own keys
    /// without colliding with this one.
    nonisolated static let seenDefaultsKey = "ai.osaurus.import-history-prompt.seen"

    private let defaults: UserDefaults

    /// True while the dialog is on screen. In-memory only: repeated
    /// checks during a presentation must not stack a second copy.
    private(set) var isPresenting = false

    /// `shared` uses the standard defaults; tests inject an isolated suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the user has already been shown the prompt (any dismissal
    /// path). Persisted, so it survives restarts and app updates.
    var hasSeen: Bool {
        defaults.bool(forKey: Self.seenDefaultsKey)
    }

    /// Whether the prompt may be presented right now. Purely the gate's
    /// own conditions — the caller layers UI-coordination deferrals
    /// (fresh install, no other modals) on top.
    var isEligible: Bool {
        !isPresenting && !hasSeen
    }

    /// Call at the moment of presentation. Marks the prompt seen
    /// immediately so it can never appear a second time — even if the
    /// app quits mid-presentation — and guards duplicate activations
    /// while it is on screen.
    func willPresent() {
        isPresenting = true
        markSeen()
    }

    /// Call from the dialog's dismiss path (Skip, Escape, outside click,
    /// Choose File, or host teardown all funnel through it).
    func didDismiss() {
        isPresenting = false
    }

    /// Idempotent; safe to call from every dismissal path.
    func markSeen() {
        defaults.set(true, forKey: Self.seenDefaultsKey)
    }

    #if DEBUG
        /// Testing hook: clear the seen flag so the normal
        /// eligibility/presentation path can run again.
        func resetForDebugTesting() {
            defaults.removeObject(forKey: Self.seenDefaultsKey)
            isPresenting = false
        }
    #endif
}
