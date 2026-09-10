//
//  WorkspacesIntroCampaign.swift
//  osaurus
//
//  One-time "Founding Workspaces" introduction (September 2026). Decides
//  whether the announcement dialog may be shown: once per user, existing
//  installs and fresh ones alike (a fresh install sees it right after
//  onboarding). Mirrors ImportHistoryPromptGate: this type owns only the
//  persisted seen flag and the in-memory duplicate-presentation guard so it
//  is trivially unit-testable with an injected defaults suite. Presentation
//  and deferral (onboarding, other modals, active agent work) live in
//  `AppDelegate.presentWorkspacesIntroDialogIfEligible()`.
//

import Foundation

@MainActor
public final class WorkspacesIntroCampaign {
    public static let shared = WorkspacesIntroCampaign()

    /// Versioned/namespaced so a later Workspaces announcement can ship its
    /// own key without colliding with this one.
    nonisolated static let seenDefaultsKey = "ai.osaurus.campaign.workspaces-intro-2026-09.seen"

    private let defaults: UserDefaults

    /// Testing hook: show the dialog on every check and never write the seen
    /// flag. Off in the app; the Dock menu's "Reset & Test Workspaces Intro"
    /// is the way to see the dialog again in a debug build.
    nonisolated static let showsEveryTimeWhileDesigning = false

    private let showsEveryTime: Bool

    /// True while the dialog is on screen. In-memory only: repeated
    /// activation notifications during a presentation must not stack a
    /// second copy, but a check that never presented must not consume
    /// eligibility either.
    private(set) var isPresenting = false

    /// `shared` uses the standard defaults; tests inject an isolated suite.
    init(
        defaults: UserDefaults = .standard,
        showsEveryTime: Bool = WorkspacesIntroCampaign.showsEveryTimeWhileDesigning
    ) {
        self.defaults = defaults
        self.showsEveryTime = showsEveryTime
    }

    /// Whether the user has already been shown the dialog (any dismissal
    /// path). Persisted, so it survives restarts and app updates.
    var hasSeen: Bool {
        defaults.bool(forKey: Self.seenDefaultsKey)
    }

    /// Whether the dialog may be presented right now. Purely the campaign's
    /// own gates: the caller layers UI-coordination deferrals on top, and a
    /// blocked check consumes nothing.
    var isEligible: Bool {
        guard !isPresenting else { return false }
        // Test hook: ignore the seen flag, but still refuse to stack a
        // second copy while one is on screen.
        if showsEveryTime { return true }
        return !hasSeen
    }

    /// Call at the moment of presentation. Marks the campaign seen
    /// immediately so the dialog can never appear a second time, even if
    /// the app quits mid-presentation, and guards duplicate activations
    /// while it is on screen.
    func willPresent() {
        isPresenting = true
        markSeen()
    }

    /// Call from the dialog's dismiss path (either button, Escape, outside
    /// click, or host teardown all funnel through it).
    func didDismiss() {
        isPresenting = false
    }

    /// Idempotent; safe to call from every dismissal path.
    func markSeen() {
        // Test hook: leave defaults untouched so the one-shot stays clean.
        guard !showsEveryTime else { return }
        defaults.set(true, forKey: Self.seenDefaultsKey)
    }

    #if DEBUG
        /// Dock-menu "Reset & Test Workspaces Intro": clear only this
        /// campaign's seen flag so the normal eligibility/presentation path
        /// can run again.
        func resetForDebugTesting() {
            defaults.removeObject(forKey: Self.seenDefaultsKey)
            isPresenting = false
        }
    #endif
}
