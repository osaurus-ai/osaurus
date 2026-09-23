//
//  ProductHuntLaunchCampaignTests.swift
//  osaurusTests
//
//  Locks the two-phase Raptor Product Hunt campaign's eligibility
//  contract: the absolute UTC launch window (Monday 2026-09-28, half-open,
//  timezone-independent) that splits time into teaser / launch / closed,
//  the per-phase persisted seen flags (dismissing the teaser must NOT
//  hide the launch-day dialog), the in-memory duplicate-presentation
//  guard, that a blocked/deferred check never consumes eligibility, and
//  the countdown copy helper. Uses an injected clock + isolated
//  UserDefaults suite so every case is deterministic with no network time.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ProductHuntLaunchCampaignTests {

    typealias Phase = ProductHuntLaunchCampaign.Phase

    /// A campaign pinned to a fixed instant and an isolated defaults suite.
    private func makeCampaign(
        now: Date
    ) -> (campaign: ProductHuntLaunchCampaign, defaults: UserDefaults, cleanup: () -> Void) {
        let suiteName = "ph-raptor-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let campaign = ProductHuntLaunchCampaign(defaults: defaults, now: { now })
        return (campaign, defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private var open: Date { ProductHuntLaunchCampaign.launchOpensAt }
    private var close: Date { ProductHuntLaunchCampaign.launchClosesAt }

    // MARK: - Window definition

    /// The hardcoded epoch instants must equal the spec's ISO-8601 UTC
    /// bounds exactly — this is what makes the gate timezone-independent
    /// (absolute instants, never the user's local calendar date).
    @Test func windowBounds_match_spec_utc_instants() {
        let iso = ISO8601DateFormatter()
        // Monday 2026-09-28 at 12:01am Pacific (PDT = UTC-7).
        #expect(iso.date(from: "2026-09-28T07:01:00Z") == open)
        #expect(iso.date(from: "2026-09-29T07:01:00Z") == close)
        // 24-hour window — Product Hunt launches run for one day.
        #expect(close.timeIntervalSince(open) == 24 * 3600)
    }

    @Test func campaign_constants() {
        #expect(ProductHuntLaunchCampaign.campaignId == "raptor-2026-09")
        #expect(ProductHuntLaunchCampaign.launchURL.absoluteString == "https://links.osaurus.ai/ph-raptor")
        #expect(
            ProductHuntLaunchCampaign.seenDefaultsKey(for: .teaser)
                == "ai.osaurus.campaign.ph-raptor-2026-09.teaser.seen"
        )
        #expect(
            ProductHuntLaunchCampaign.seenDefaultsKey(for: .launch)
                == "ai.osaurus.campaign.ph-raptor-2026-09.launch.seen"
        )
    }

    // MARK: - Phase boundaries (half-open launch interval)

    /// Everything before open is the teaser — including a fresh install
    /// weeks earlier and the second right before launch.
    @Test func teaser_for_any_instant_before_open() {
        for instant in [
            open.addingTimeInterval(-30 * 86400), open.addingTimeInterval(-3600), open.addingTimeInterval(-1),
        ] {
            let (campaign, _, cleanup) = makeCampaign(now: instant)
            defer { cleanup() }
            #expect(campaign.currentWindowPhase == .teaser)
            #expect(campaign.eligiblePhase == .teaser)
        }
    }

    @Test func launch_at_exact_open_instant() {
        let (campaign, _, cleanup) = makeCampaign(now: open)
        defer { cleanup() }
        #expect(campaign.currentWindowPhase == .launch)
        #expect(campaign.eligiblePhase == .launch)
    }

    @Test func launch_one_second_before_close() {
        let (campaign, _, cleanup) = makeCampaign(now: close.addingTimeInterval(-1))
        defer { cleanup() }
        #expect(campaign.eligiblePhase == .launch)
    }

    /// The interval is half-open: the closing instant itself is out. Users
    /// who update the app after the window closes must never see either
    /// dialog.
    @Test func nothing_at_exact_close_instant_or_after() {
        for instant in [close, close.addingTimeInterval(1), close.addingTimeInterval(400 * 86400)] {
            let (campaign, _, cleanup) = makeCampaign(now: instant)
            defer { cleanup() }
            #expect(campaign.currentWindowPhase == nil)
            #expect(campaign.eligiblePhase == nil)
        }
    }

    // MARK: - Seen flags

    /// Fresh install (no stored flags) is eligible for the current phase.
    @Test func freshInstall_has_no_flags_and_is_eligible() {
        let (campaign, defaults, cleanup) = makeCampaign(now: open.addingTimeInterval(3600))
        defer { cleanup() }
        for phase in Phase.allCases {
            #expect(defaults.object(forKey: ProductHuntLaunchCampaign.seenDefaultsKey(for: phase)) == nil)
            #expect(!campaign.hasSeen(phase))
        }
        #expect(campaign.eligiblePhase == .launch)
    }

    @Test func seen_flag_blocks_its_own_phase() {
        let (teaser, _, cleanupT) = makeCampaign(now: open.addingTimeInterval(-3600))
        defer { cleanupT() }
        teaser.markSeen(.teaser)
        #expect(teaser.eligiblePhase == nil)

        let (launch, _, cleanupL) = makeCampaign(now: open.addingTimeInterval(3600))
        defer { cleanupL() }
        launch.markSeen(.launch)
        #expect(launch.eligiblePhase == nil)
    }

    /// The whole point of two flags: dismissing the teaser must not hide
    /// the launch-day reminder once the window opens.
    @Test func teaser_seen_does_not_block_launch_day() {
        let suiteName = "ph-raptor-handoff-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Day before: teaser shows and is dismissed.
        let before = ProductHuntLaunchCampaign(defaults: defaults, now: { open.addingTimeInterval(-6 * 3600) })
        #expect(before.eligiblePhase == .teaser)
        before.willPresent(.teaser)
        before.didDismiss()
        #expect(before.eligiblePhase == nil)

        // Launch day (fresh instance, same defaults = same user after a
        // relaunch): the launch dialog is still owed.
        let launchDay = ProductHuntLaunchCampaign(defaults: defaults, now: { open.addingTimeInterval(60) })
        #expect(launchDay.hasSeen(.teaser))
        #expect(!launchDay.hasSeen(.launch))
        #expect(launchDay.eligiblePhase == .launch)
    }

    /// And the reverse: a launch-day dismissal never resurrects the teaser
    /// (its window is over anyway, but the flag logic must not cross-talk).
    @Test func launch_seen_does_not_affect_teaser_flag() {
        let (campaign, _, cleanup) = makeCampaign(now: open.addingTimeInterval(60))
        defer { cleanup() }
        campaign.markSeen(.launch)
        #expect(!campaign.hasSeen(.teaser))
        #expect(campaign.hasSeen(.launch))
        #expect(campaign.eligiblePhase == nil)
    }

    /// Users who dismissed the July 2026 launch dialog carry its key; it
    /// must have no bearing on this campaign.
    @Test func july2026_seen_key_is_ignored() {
        let (campaign, defaults, cleanup) = makeCampaign(now: open.addingTimeInterval(-3600))
        defer { cleanup() }
        defaults.set(true, forKey: "ai.osaurus.campaign.ph-launch-2026-07.seen")
        #expect(campaign.eligiblePhase == .teaser)
    }

    /// `markSeen` is idempotent; every dismissal path may call it safely.
    @Test func markSeen_is_idempotent() {
        let (campaign, _, cleanup) = makeCampaign(now: open)
        defer { cleanup() }
        campaign.markSeen(.launch)
        campaign.markSeen(.launch)
        #expect(campaign.hasSeen(.launch))
        #expect(campaign.eligiblePhase == nil)
    }

    /// The dismissal must survive a restart: a NEW coordinator instance
    /// backed by the same defaults suite stays ineligible.
    @Test func dismissal_persists_across_campaign_instances() {
        let suiteName = "ph-raptor-restart-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = open.addingTimeInterval(3600)

        let first = ProductHuntLaunchCampaign(defaults: defaults, now: { now })
        #expect(first.eligiblePhase == .launch)
        first.willPresent(.launch)
        first.didDismiss()

        let second = ProductHuntLaunchCampaign(defaults: defaults, now: { now })
        #expect(second.hasSeen(.launch))
        #expect(second.eligiblePhase == nil)
    }

    // MARK: - Presentation lifecycle

    /// `willPresent` persists seen IMMEDIATELY (crash-during-presentation
    /// can't resurrect the dialog) for THAT phase only, and guards
    /// duplicate activations while the dialog is on screen.
    @Test func willPresent_marks_phase_seen_and_blocks_duplicate_activation() {
        let (campaign, defaults, cleanup) = makeCampaign(now: open.addingTimeInterval(-60))
        defer { cleanup() }

        #expect(campaign.eligiblePhase == .teaser)
        campaign.willPresent(.teaser)

        #expect(campaign.isPresenting)
        #expect(defaults.bool(forKey: ProductHuntLaunchCampaign.seenDefaultsKey(for: .teaser)))
        #expect(defaults.object(forKey: ProductHuntLaunchCampaign.seenDefaultsKey(for: .launch)) == nil)
        // A foreground activation arriving mid-presentation must not stack.
        #expect(campaign.eligiblePhase == nil)

        campaign.didDismiss()
        #expect(!campaign.isPresenting)
        // Still seen — never shows a second time.
        #expect(campaign.eligiblePhase == nil)
    }

    /// `isPresenting` is a global guard: while the teaser is on screen,
    /// even a clock that has just crossed into the launch window must not
    /// stack the launch dialog on top of it.
    @Test func isPresenting_blocks_every_phase() {
        var now = open.addingTimeInterval(-1)
        let suiteName = "ph-raptor-presenting-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let campaign = ProductHuntLaunchCampaign(defaults: defaults, now: { now })

        campaign.willPresent(.teaser)
        now = open.addingTimeInterval(1)
        #expect(campaign.currentWindowPhase == .launch)
        #expect(campaign.eligiblePhase == nil)

        campaign.didDismiss()
        #expect(campaign.eligiblePhase == .launch)
    }

    // MARK: - Deferral does not consume eligibility

    /// A blocked check (onboarding, modal, active work — the caller simply
    /// never presents) must leave both the persisted flags and eligibility
    /// untouched, so the next activation inside the window still shows it.
    @Test func blocked_check_leaves_eligibility_and_persistence_untouched() {
        let (campaign, defaults, cleanup) = makeCampaign(now: open.addingTimeInterval(60))
        defer { cleanup() }

        for _ in 0 ..< 5 {
            #expect(campaign.eligiblePhase == .launch)
        }
        for phase in Phase.allCases {
            #expect(defaults.object(forKey: ProductHuntLaunchCampaign.seenDefaultsKey(for: phase)) == nil)
            #expect(!campaign.hasSeen(phase))
        }
        #expect(campaign.eligiblePhase == .launch)
    }

    // MARK: - Countdown copy

    @Test func countdown_buckets() {
        let describe = { (secondsBefore: TimeInterval) in
            ProductHuntLaunchCampaign.countdownDescription(from: open.addingTimeInterval(-secondsBefore))
        }
        // >= 36h → whole days, rounded.
        #expect(describe(5 * 86400) == "5 days")
        #expect(describe(40 * 3600) == "2 days")
        #expect(describe(36 * 3600) == "2 days")
        // 90 min ..< 36h → about N hours, rounded.
        #expect(describe(35 * 3600) == "about 35 hours")
        #expect(describe(18 * 3600 + 20 * 60) == "about 18 hours")
        #expect(describe(2 * 3600 + 45 * 60) == "about 3 hours")
        #expect(describe(90 * 60) == "about 2 hours")
        // 1 min ..< 90 min → minutes, floored.
        #expect(describe(89 * 60 + 59) == "89 minutes")
        #expect(describe(60) == "1 minute")
        // < 1 min (and any clock at/after open, e.g. the debug bypass) → "a moment".
        #expect(describe(59) == "a moment")
        #expect(describe(0) == "a moment")
        #expect(describe(-3600) == "a moment")
    }

    // MARK: - DEBUG phase bypass

    #if DEBUG
        /// The dock-menu hook forces a phase regardless of the clock — but
        /// only clears THAT phase's flag and still honors it afterwards, so
        /// a dismissed dialog stays dismissed in the same run and the other
        /// phase's flag is untouched.
        @Test func debugBypass_forces_phase_but_honors_its_seen_flag() {
            let afterWindow = close.addingTimeInterval(86400)
            let (campaign, _, cleanup) = makeCampaign(now: afterWindow)
            defer { cleanup() }

            #expect(campaign.eligiblePhase == nil)

            campaign.markSeen(.launch)
            campaign.resetForDebugTesting(phase: .teaser)
            #expect(campaign.eligiblePhase == .teaser)
            // Launch flag untouched by the teaser reset.
            #expect(campaign.hasSeen(.launch))

            // Present + dismiss: seen wins over the bypass.
            campaign.willPresent(.teaser)
            campaign.didDismiss()
            #expect(campaign.eligiblePhase == nil)

            // Switching to the launch phase clears only its flag.
            campaign.resetForDebugTesting(phase: .launch)
            #expect(campaign.eligiblePhase == .launch)
            #expect(campaign.hasSeen(.teaser))
        }
    #endif
}
