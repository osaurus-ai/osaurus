//
//  WorkspacesIntroCampaignTests.swift
//  osaurusTests
//
//  Locks the one-time Founding Workspaces introduction's eligibility
//  contract: the persisted once-per-user seen flag (fresh installs
//  included), the in-memory duplicate-presentation guard, and that a
//  blocked/deferred check never consumes eligibility. Uses an isolated
//  UserDefaults suite so every case is deterministic.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct WorkspacesIntroCampaignTests {

    /// A campaign with an isolated defaults suite.
    @MainActor
    private final class Fixture {
        let suiteName = "workspaces-intro-\(UUID().uuidString)"
        let defaults: UserDefaults
        private(set) var sut: WorkspacesIntroCampaign!

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            // The one-shot contract is tested with the test hook
            // ("show every time") off, whatever its current default.
            sut = WorkspacesIntroCampaign(
                defaults: defaults,
                showsEveryTime: false
            )
        }

        /// Explicit (not `deinit`): a main-actor class cannot touch its
        /// non-Sendable `UserDefaults` from a nonisolated deinit in Swift 6.
        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    // MARK: - Eligibility

    @Test func isEligible_untilSeen() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        #expect(fixture.sut.isEligible)
        #expect(!fixture.sut.hasSeen)
    }

    /// A deferred check (onboarding, other modal, streaming turn) must not
    /// burn the one shot: the caller never called `willPresent`.
    @Test func blockedCheck_doesNotConsumeEligibility() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        for _ in 0 ..< 5 {
            #expect(fixture.sut.isEligible)
        }
        #expect(!fixture.sut.hasSeen)
    }

    @Test func willPresent_persistsSeen_andGuardsDuplicates() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.sut.willPresent()
        #expect(fixture.sut.hasSeen)
        #expect(fixture.defaults.bool(forKey: WorkspacesIntroCampaign.seenDefaultsKey))
        // On screen: a second activation must not stack a copy.
        #expect(!fixture.sut.isEligible)
        fixture.sut.didDismiss()
        // Dismissed: still seen, so never again.
        #expect(!fixture.sut.isEligible)
    }

    /// The seen flag lives in defaults, so a brand-new campaign instance
    /// (a relaunch) over the same suite stays dismissed.
    @Test func seen_survivesRelaunch() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.sut.willPresent()
        fixture.sut.didDismiss()
        let relaunched = WorkspacesIntroCampaign(
            defaults: fixture.defaults, showsEveryTime: false)
        #expect(relaunched.hasSeen)
        #expect(!relaunched.isEligible)
    }

    @Test func markSeen_isIdempotent() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.sut.markSeen()
        fixture.sut.markSeen()
        #expect(fixture.sut.hasSeen)
        #expect(!fixture.sut.isEligible)
    }

    #if DEBUG
        @Test func resetForDebugTesting_clearsSeen_andPresenting() {
            let fixture = Fixture()
            defer { fixture.cleanup() }
            fixture.sut.willPresent()
            #expect(!fixture.sut.isEligible)
            fixture.sut.resetForDebugTesting()
            #expect(!fixture.sut.hasSeen)
            #expect(fixture.sut.isEligible)
        }
    #endif

    // MARK: - Test hook

    /// With the test hook on it shows on every check, ignores
    /// the seen flag, never writes it, and still
    /// refuses to stack a copy while one is on screen.
    @Test func showsEveryTime_ignoresSeen_andNeverPersists() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let designTime = WorkspacesIntroCampaign(
            defaults: fixture.defaults, showsEveryTime: true)
        #expect(designTime.isEligible)
        designTime.willPresent()
        #expect(!designTime.isEligible)
        #expect(!designTime.hasSeen)
        designTime.didDismiss()
        #expect(designTime.isEligible)
        #expect(!fixture.sut.hasSeen)
    }

    // MARK: - Dialog sizing

    /// A normal display keeps the designed size; a window too small for it
    /// shrinks the dialog uniformly, and the floor keeps it legible.
    @Test func dialogScale_fitsSmallWindows_andCapsAtDesignSize() {
        // Roomy: full size.
        #expect(WorkspacesIntroModal.scale(fitting: CGSize(width: 1440, height: 900)) == 1)
        #expect(WorkspacesIntroModal.dialogWidth(scale: 1) == 960)

        // Width-bound: an 800pt-wide window leaves 704pt for the canvas.
        let narrow = WorkspacesIntroModal.scale(fitting: CGSize(width: 800, height: 900))
        #expect(abs(narrow - 704.0 / 912.0) < 0.001)
        #expect(WorkspacesIntroModal.dialogWidth(scale: narrow) <= 800 - 48)

        // Height-bound: a short window is limited by the canvas height.
        let short = WorkspacesIntroModal.scale(fitting: CGSize(width: 1440, height: 500))
        #expect(short < 1)
        #expect(abs(short - (500.0 - 48 - 250) / 312.0) < 0.001)

        // Tiny: floored, never zero or negative.
        #expect(WorkspacesIntroModal.scale(fitting: CGSize(width: 300, height: 200)) == WorkspacesIntroModal.minimumScale)
    }

    // MARK: - Key hygiene

    /// Namespaced and versioned so a later Workspaces announcement can ship
    /// its own key without colliding with this one.
    @Test func seenKey_isNamespaced() {
        #expect(WorkspacesIntroCampaign.seenDefaultsKey == "ai.osaurus.campaign.workspaces-intro-2026-09.seen")
        #expect(WorkspacesIntroCampaign.seenDefaultsKey != ProductHuntLaunchCampaign.seenDefaultsKey)
        #expect(WorkspacesIntroCampaign.seenDefaultsKey != ImportHistoryPromptGate.seenDefaultsKey)
    }
}
