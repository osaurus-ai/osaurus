//
//  WorkspacesIntroCampaign.swift
//  osaurus
//
//  One-time "Founding Workspaces" introduction (September 2026). Decides
//  whether the announcement dialog may be shown: existing users only,
//  never twice. Mirrors ImportHistoryPromptGate: this type owns only the
//  persisted seen flag, the fresh-install exclusion, and the in-memory
//  duplicate-presentation guard so it is trivially unit-testable with an
//  injected defaults suite. Presentation and deferral (onboarding, other
//  modals, active agent work) live in
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
    private let isFreshInstall: @MainActor () -> Bool

    /// DESIGN-TIME ONLY: while the dialog is still being iterated on, show
    /// it on every launch and activation instead of once. The seen flag is
    /// neither read nor written in this mode. Flip to `false` (or delete)
    /// before release so the one-shot contract below takes over.
    nonisolated static let showsEveryTimeWhileDesigning = true

    private let showsEveryTime: Bool

    /// True while the dialog is on screen. In-memory only: repeated
    /// activation notifications during a presentation must not stack a
    /// second copy, but a check that never presented must not consume
    /// eligibility either.
    private(set) var isPresenting = false

    /// `shared` uses the standard defaults and the real onboarding state;
    /// tests inject an isolated suite and a fixed answer.
    init(
        defaults: UserDefaults = .standard,
        isFreshInstall: @escaping @MainActor () -> Bool = { OnboardingService.shared.isFreshInstall },
        showsEveryTime: Bool = WorkspacesIntroCampaign.showsEveryTimeWhileDesigning
    ) {
        self.defaults = defaults
        self.isFreshInstall = isFreshInstall
        self.showsEveryTime = showsEveryTime
    }

    /// Whether the user has already been shown the dialog (any dismissal
    /// path) or was silently excluded as a fresh install. Persisted, so it
    /// survives restarts and app updates.
    var hasSeen: Bool {
        defaults.bool(forKey: Self.seenDefaultsKey)
    }

    /// Whether the dialog may be presented right now. Purely the campaign's
    /// own gates: the caller layers UI-coordination deferrals on top.
    ///
    /// The offer is addressed to people who were already using Osaurus
    /// before Workspaces shipped ("you got here early"). A fresh install
    /// that has not completed onboarding yet is not one of them, so the
    /// first check on such an install records the campaign as seen without
    /// presenting, exactly like `WhatsNewGate` does for a first launch. A
    /// blocked check on an existing install consumes nothing.
    var isEligible: Bool {
        guard !isPresenting else { return false }
        // Design-time: ignore seen and fresh-install state entirely, but
        // still refuse to stack a second copy while one is on screen.
        if showsEveryTime { return true }
        guard !hasSeen else { return false }
        if isFreshInstall() {
            markSeen()
            return false
        }
        return true
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
        // Design-time: leave defaults untouched so flipping the switch off
        // later yields a clean one-shot for everyone, reviewers included.
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
