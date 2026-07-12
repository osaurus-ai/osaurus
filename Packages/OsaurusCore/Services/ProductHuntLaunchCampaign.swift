//
//  ProductHuntLaunchCampaign.swift
//  osaurus
//
//  One-time Product Hunt launch announcement (July 2026). Decides whether
//  the thank-you dialog may be shown: inside the absolute UTC launch
//  window, never before, never after, and never twice. Presentation and
//  deferral (onboarding, other modals, active agent work) live in
//  `AppDelegate.presentProductHuntLaunchDialogIfEligible()`; this type only
//  owns the time gate and the persisted seen flag so both are trivially
//  unit-testable with an injected clock and defaults suite.
//

import Foundation

@MainActor
public final class ProductHuntLaunchCampaign {
    public static let shared = ProductHuntLaunchCampaign()

    /// 2026-07-13T07:01:00Z — 12:01am Pacific on launch day (PDT = UTC-7).
    /// Stored as an absolute epoch instant so a user in Tokyo and a user in
    /// LA become eligible at the same real-world moment regardless of their
    /// local calendar date. Verified against ISO-8601 parses in tests.
    nonisolated public static let windowOpensAt = Date(timeIntervalSince1970: 1_783_926_060)

    /// 2026-07-15T07:01:00Z — exactly 48 hours after open. The interval is
    /// half-open (`open <= now < close`), so this instant itself is closed.
    nonisolated public static let windowClosesAt = Date(timeIntervalSince1970: 1_784_098_860)

    /// Product Hunt launch page, opened by the dialog's primary button.
    nonisolated public static let launchURL = URL(string: "https://links.osaurus.ai/ph")!

    /// Versioned/namespaced so a future launch dialog can ship its own key
    /// without colliding with this one.
    nonisolated static let seenDefaultsKey = "ai.osaurus.campaign.ph-launch-2026-07.seen"

    private let defaults: UserDefaults
    private let now: () -> Date

    /// True while the dialog is on screen. In-memory only: repeated
    /// activation notifications during a presentation must not stack a
    /// second copy, but a check that never presented must not consume
    /// eligibility either.
    private(set) var isPresenting = false

    #if DEBUG
        /// Dock-menu testing hook: bypass the UTC date window only. The
        /// persisted seen flag is still honored, so dismissing the dialog in
        /// a debug run keeps it dismissed until the next explicit reset.
        var bypassesDateWindowForDebug = false
    #endif

    /// `shared` uses the standard defaults and wall clock; tests inject an
    /// isolated suite and a fixed instant.
    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    /// Whether the user has already been shown the dialog (any dismissal
    /// path). Persisted, so it survives restarts and app updates.
    var hasSeen: Bool {
        defaults.bool(forKey: Self.seenDefaultsKey)
    }

    /// Half-open UTC window comparison against the injected clock.
    var isWithinWindow: Bool {
        let instant = now()
        return instant >= Self.windowOpensAt && instant < Self.windowClosesAt
    }

    /// Whether the dialog may be presented right now. Purely the campaign's
    /// own gates — the caller layers UI-coordination deferrals on top.
    var isEligible: Bool {
        guard !isPresenting, !hasSeen else { return false }
        #if DEBUG
            if bypassesDateWindowForDebug { return true }
        #endif
        return isWithinWindow
    }

    /// Call at the moment of presentation. Marks the campaign seen
    /// immediately so the dialog can never appear a second time — even if
    /// the app quits mid-presentation — and guards duplicate activations
    /// while it is on screen.
    func willPresent() {
        isPresenting = true
        markSeen()
    }

    /// Call from the dialog's dismiss path (either button, Escape,
    /// outside click, or host teardown all funnel through it).
    func didDismiss() {
        isPresenting = false
    }

    /// Idempotent; safe to call from every dismissal path.
    func markSeen() {
        defaults.set(true, forKey: Self.seenDefaultsKey)
    }

    #if DEBUG
        /// Dock-menu "Reset & Test Product Hunt Launch": clear only this
        /// campaign's seen flag and arm the date-window bypass so the normal
        /// eligibility/presentation path can run outside the real window.
        func resetForDebugTesting() {
            defaults.removeObject(forKey: Self.seenDefaultsKey)
            bypassesDateWindowForDebug = true
            isPresenting = false
        }
    #endif
}
