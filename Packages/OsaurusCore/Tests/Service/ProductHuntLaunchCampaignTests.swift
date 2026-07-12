//
//  ProductHuntLaunchCampaignTests.swift
//  osaurusTests
//
//  Locks the one-time Product Hunt launch dialog's eligibility contract:
//  the absolute UTC window (half-open, timezone-independent), the
//  persisted once-per-user seen flag, the in-memory duplicate-presentation
//  guard, and — critically — that a blocked/deferred check never consumes
//  eligibility. Uses an injected clock + isolated UserDefaults suite so
//  every case is deterministic with no network time.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ProductHuntLaunchCampaignTests {

    /// A campaign pinned to a fixed instant and an isolated defaults suite.
    private func makeCampaign(
        now: Date
    ) -> (campaign: ProductHuntLaunchCampaign, defaults: UserDefaults, cleanup: () -> Void) {
        let suiteName = "ph-launch-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let campaign = ProductHuntLaunchCampaign(defaults: defaults, now: { now })
        return (campaign, defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private var open: Date { ProductHuntLaunchCampaign.windowOpensAt }
    private var close: Date { ProductHuntLaunchCampaign.windowClosesAt }

    // MARK: - Window definition

    /// The hardcoded epoch instants must equal the spec's ISO-8601 UTC
    /// bounds exactly — this is what makes the gate timezone-independent
    /// (absolute instants, never the user's local calendar date).
    @Test func windowBounds_match_spec_utc_instants() {
        let iso = ISO8601DateFormatter()
        #expect(iso.date(from: "2026-07-13T07:01:00Z") == open)
        #expect(iso.date(from: "2026-07-15T07:01:00Z") == close)
        // 48-hour window.
        #expect(close.timeIntervalSince(open) == 48 * 3600)
    }

    // MARK: - Time boundaries (half-open interval)

    @Test func notEligible_one_second_before_open() {
        let (campaign, _, cleanup) = makeCampaign(now: open.addingTimeInterval(-1))
        defer { cleanup() }
        #expect(!campaign.isWithinWindow)
        #expect(!campaign.isEligible)
    }

    @Test func eligible_at_exact_open_instant() {
        let (campaign, _, cleanup) = makeCampaign(now: open)
        defer { cleanup() }
        #expect(campaign.isWithinWindow)
        #expect(campaign.isEligible)
    }

    @Test func eligible_one_second_before_close() {
        let (campaign, _, cleanup) = makeCampaign(now: close.addingTimeInterval(-1))
        defer { cleanup() }
        #expect(campaign.isEligible)
    }

    /// The interval is half-open: the closing instant itself is out. Users
    /// who update the app after the window closes must never see the dialog.
    @Test func notEligible_at_exact_close_instant_or_after() {
        for instant in [close, close.addingTimeInterval(1), close.addingTimeInterval(400 * 86400)] {
            let (campaign, _, cleanup) = makeCampaign(now: instant)
            defer { cleanup() }
            #expect(!campaign.isEligible)
        }
    }

    // MARK: - Seen flag

    /// Fresh install (no stored flag) inside the window is eligible.
    @Test func freshInstall_inside_window_is_eligible() {
        let (campaign, defaults, cleanup) = makeCampaign(now: open.addingTimeInterval(3600))
        defer { cleanup() }
        #expect(defaults.object(forKey: ProductHuntLaunchCampaign.seenDefaultsKey) == nil)
        #expect(campaign.isEligible)
    }

    @Test func seen_flag_blocks_eligibility_inside_window() {
        let (campaign, _, cleanup) = makeCampaign(now: open.addingTimeInterval(3600))
        defer { cleanup() }
        campaign.markSeen()
        #expect(!campaign.isEligible)
    }

    /// `markSeen` is idempotent; every dismissal path may call it safely.
    @Test func markSeen_is_idempotent() {
        let (campaign, _, cleanup) = makeCampaign(now: open)
        defer { cleanup() }
        campaign.markSeen()
        campaign.markSeen()
        #expect(campaign.hasSeen)
        #expect(!campaign.isEligible)
    }

    /// The dismissal must survive a restart: a NEW coordinator instance
    /// backed by the same defaults suite stays ineligible.
    @Test func dismissal_persists_across_campaign_instances() {
        let suiteName = "ph-launch-restart-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = open.addingTimeInterval(3600)

        let first = ProductHuntLaunchCampaign(defaults: defaults, now: { now })
        #expect(first.isEligible)
        first.willPresent()
        first.didDismiss()

        let second = ProductHuntLaunchCampaign(defaults: defaults, now: { now })
        #expect(second.hasSeen)
        #expect(!second.isEligible)
    }

    // MARK: - Presentation lifecycle

    /// `willPresent` persists seen IMMEDIATELY (crash-during-presentation
    /// can't resurrect the dialog) and guards duplicate activations while
    /// the dialog is on screen.
    @Test func willPresent_marks_seen_and_blocks_duplicate_activation() {
        let (campaign, defaults, cleanup) = makeCampaign(now: open.addingTimeInterval(60))
        defer { cleanup() }

        #expect(campaign.isEligible)
        campaign.willPresent()

        #expect(campaign.isPresenting)
        #expect(defaults.bool(forKey: ProductHuntLaunchCampaign.seenDefaultsKey))
        // A foreground activation arriving mid-presentation must not stack.
        #expect(!campaign.isEligible)

        campaign.didDismiss()
        #expect(!campaign.isPresenting)
        // Still seen — never shows a second time.
        #expect(!campaign.isEligible)
    }

    // MARK: - Deferral does not consume eligibility

    /// A blocked check (onboarding, modal, active work — the caller simply
    /// never presents) must leave both the persisted flag and eligibility
    /// untouched, so the next activation inside the window still shows it.
    @Test func blocked_check_leaves_eligibility_and_persistence_untouched() {
        let (campaign, defaults, cleanup) = makeCampaign(now: open.addingTimeInterval(60))
        defer { cleanup() }

        // The caller reads `isEligible` any number of times without
        // presenting; nothing is written and eligibility stays intact.
        for _ in 0..<5 {
            #expect(campaign.isEligible)
        }
        #expect(defaults.object(forKey: ProductHuntLaunchCampaign.seenDefaultsKey) == nil)
        #expect(!campaign.hasSeen)
        #expect(campaign.isEligible)
    }

    // MARK: - DEBUG date-window bypass

    #if DEBUG
        /// The dock-menu test hook bypasses only the UTC window — outside
        /// the window it becomes eligible, but the seen flag is still
        /// honored so a dismissed dialog stays dismissed in the same run.
        @Test func debugBypass_ignores_window_but_honors_seen_flag() {
            let afterWindow = close.addingTimeInterval(86400)
            let (campaign, _, cleanup) = makeCampaign(now: afterWindow)
            defer { cleanup() }

            #expect(!campaign.isEligible)

            campaign.resetForDebugTesting()
            #expect(campaign.isEligible)

            // Present + dismiss: seen wins over the bypass.
            campaign.willPresent()
            campaign.didDismiss()
            #expect(!campaign.isEligible)

            // Explicit re-reset arms another test pass.
            campaign.resetForDebugTesting()
            #expect(campaign.isEligible)
        }
    #endif
}
