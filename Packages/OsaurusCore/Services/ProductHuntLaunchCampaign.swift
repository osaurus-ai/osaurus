//
//  ProductHuntLaunchCampaign.swift
//  osaurus
//
//  Two-phase Product Hunt launch announcement for Raptor (September 2026).
//  Decides which dialog — if any — may be shown right now:
//
//  - `teaser`: any time before the launch window opens (i.e. as soon as
//    the build that ships it is installed). "We're launching in N hours,
//    come support us."
//  - `launch`: inside the absolute 24-hour UTC launch window. "We're live."
//
//  Each phase has its own persisted seen flag, so a user who dismissed the
//  teaser still gets the launch-day reminder, and neither ever shows twice.
//  Presentation and deferral (onboarding, other modals, active agent work)
//  live in `AppDelegate.presentProductHuntLaunchDialogIfEligible()`; this
//  type only owns the time gates and the persisted flags so both are
//  trivially unit-testable with an injected clock and defaults suite.
//

import Foundation

@MainActor
public final class ProductHuntLaunchCampaign {
    public static let shared = ProductHuntLaunchCampaign()

    /// Which announcement a check resolved to. Raw values double as the
    /// telemetry `phase` token and the seen-key suffix.
    public enum Phase: String, CaseIterable, Sendable {
        /// Pre-launch heads-up, eligible for any instant before `launchOpensAt`.
        case teaser
        /// Launch-day dialog, eligible for `launchOpensAt <= now < launchClosesAt`.
        case launch
    }

    /// 2026-09-23T07:01:00Z — 12:01am Pacific on launch day (PDT = UTC-7).
    /// Stored as an absolute epoch instant so a user in Tokyo and a user in
    /// LA become eligible at the same real-world moment regardless of their
    /// local calendar date. Verified against ISO-8601 parses in tests.
    nonisolated public static let launchOpensAt = Date(timeIntervalSince1970: 1_790_146_860)

    /// 2026-09-24T07:01:00Z — exactly 24 hours after open (Product Hunt
    /// launches run for one day). The interval is half-open
    /// (`open <= now < close`), so this instant itself is closed.
    nonisolated public static let launchClosesAt = Date(timeIntervalSince1970: 1_790_233_260)

    /// Single short link used by both dialogs. Points at the Product Hunt
    /// "coming soon" page before launch and is repointed to the live
    /// launch page at open.
    nonisolated public static let launchURL = URL(string: "https://links.osaurus.ai/ph-raptor")!

    /// Telemetry token distinguishing this campaign from the July 2026 one
    /// (which shared the same event names).
    nonisolated public static let campaignId = "raptor-2026-09"

    /// Versioned/namespaced per campaign AND per phase, so the July 2026
    /// key (`ai.osaurus.campaign.ph-launch-2026-07.seen`) has no effect
    /// here and a future launch can ship its own keys without colliding.
    nonisolated static func seenDefaultsKey(for phase: Phase) -> String {
        "ai.osaurus.campaign.ph-raptor-2026-09.\(phase.rawValue).seen"
    }

    private let defaults: UserDefaults
    private let now: () -> Date

    /// True while a dialog is on screen. In-memory only: repeated
    /// activation notifications during a presentation must not stack a
    /// second copy, but a check that never presented must not consume
    /// eligibility either.
    private(set) var isPresenting = false

    #if DEBUG
        /// Dock-menu testing hook: force this phase regardless of the UTC
        /// clock. The phase's persisted seen flag is still honored, so
        /// dismissing the dialog in a debug run keeps it dismissed until
        /// the next explicit reset.
        var bypassPhaseForDebug: Phase?
    #endif

    /// `shared` uses the standard defaults and wall clock; tests inject an
    /// isolated suite and a fixed instant.
    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    /// Whether the user has already been shown this phase's dialog (any
    /// dismissal path). Persisted, so it survives restarts and app updates.
    func hasSeen(_ phase: Phase) -> Bool {
        defaults.bool(forKey: Self.seenDefaultsKey(for: phase))
    }

    /// The phase whose time window contains the injected clock's instant,
    /// ignoring seen flags and presentation state. `nil` after the launch
    /// window closes.
    var currentWindowPhase: Phase? {
        let instant = now()
        if instant < Self.launchOpensAt { return .teaser }
        if instant < Self.launchClosesAt { return .launch }
        return nil
    }

    /// The dialog that may be presented right now, or `nil`. Purely the
    /// campaign's own gates — the caller layers UI-coordination deferrals
    /// on top. A phase whose window has passed can never become eligible
    /// again, and a seen phase stays hidden even inside its window.
    var eligiblePhase: Phase? {
        guard !isPresenting else { return nil }
        #if DEBUG
            if let forced = bypassPhaseForDebug {
                return hasSeen(forced) ? nil : forced
            }
        #endif
        guard let phase = currentWindowPhase, !hasSeen(phase) else { return nil }
        return phase
    }

    /// Call at the moment of presentation. Marks the phase seen
    /// immediately so its dialog can never appear a second time — even if
    /// the app quits mid-presentation — and guards duplicate activations
    /// while it is on screen.
    func willPresent(_ phase: Phase) {
        isPresenting = true
        markSeen(phase)
    }

    /// Call from the dialog's dismiss path (either button, Escape,
    /// outside click, or host teardown all funnel through it).
    func didDismiss() {
        isPresenting = false
    }

    /// Idempotent; safe to call from every dismissal path.
    func markSeen(_ phase: Phase) {
        defaults.set(true, forKey: Self.seenDefaultsKey(for: phase))
    }

    // MARK: - Countdown

    /// Human-readable time remaining until `launchOpensAt`, interpolated
    /// into the teaser copy ("launching on Product Hunt in \(countdown)").
    /// Coarse on purpose — the dialog is a one-shot snapshot, not a live
    /// timer. Clamps to "a moment" at or after open so a teaser forced via
    /// the debug bypass never reads "in -3 hours".
    nonisolated static func countdownDescription(from now: Date) -> String {
        let remaining = launchOpensAt.timeIntervalSince(now)
        let minute: TimeInterval = 60
        let hour: TimeInterval = 3600

        if remaining >= 36 * hour {
            let days = Int((remaining / (24 * hour)).rounded())
            return days == 1 ? "1 day" : "\(days) days"
        }
        if remaining >= 90 * minute {
            let hours = Int((remaining / hour).rounded())
            return "about \(hours) hours"
        }
        if remaining >= minute {
            let minutes = Int((remaining / minute).rounded(.down))
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        return "a moment"
    }

    #if DEBUG
        /// Dock-menu "Reset & Test …": clear only this phase's seen flag
        /// and force the phase so the normal eligibility/presentation path
        /// can run outside its real window. The other phase's flag is
        /// untouched, so teaser → launch-day handoff can be exercised.
        func resetForDebugTesting(phase: Phase) {
            defaults.removeObject(forKey: Self.seenDefaultsKey(for: phase))
            bypassPhaseForDebug = phase
            isPresenting = false
        }
    #endif
}
