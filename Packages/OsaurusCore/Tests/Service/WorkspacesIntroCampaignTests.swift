//
//  WorkspacesIntroCampaignTests.swift
//  osaurusTests
//
//  Locks the one-time Founding Workspaces introduction's eligibility
//  contract: existing installs only (a fresh install is consumed silently
//  and never sees it, even after onboarding completes), the persisted
//  once-per-user seen flag, the in-memory duplicate-presentation guard,
//  and that a blocked/deferred check on an existing install never
//  consumes eligibility. Uses an isolated UserDefaults suite and an
//  injected fresh-install answer so every case is deterministic.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct WorkspacesIntroCampaignTests {

    /// A campaign with an isolated defaults suite and a mutable
    /// fresh-install answer the test can flip mid-scenario.
    @MainActor
    private final class Fixture {
        let suiteName = "workspaces-intro-\(UUID().uuidString)"
        let defaults: UserDefaults
        var isFreshInstall = false
        private(set) var sut: WorkspacesIntroCampaign!

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            sut = WorkspacesIntroCampaign(defaults: defaults) { [unowned self] in self.isFreshInstall }
        }

        deinit {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    // MARK: - Existing install

    @Test func existingInstall_isEligible_untilSeen() {
        let fixture = Fixture()
        #expect(fixture.sut.isEligible)
        #expect(!fixture.sut.hasSeen)
    }

    /// A deferred check (onboarding, other modal, streaming turn) must not
    /// burn the one shot: the caller never called `willPresent`.
    @Test func blockedCheck_doesNotConsumeEligibility() {
        let fixture = Fixture()
        for _ in 0 ..< 5 {
            #expect(fixture.sut.isEligible)
        }
        #expect(!fixture.sut.hasSeen)
    }

    @Test func willPresent_persistsSeen_andGuardsDuplicates() {
        let fixture = Fixture()
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
        fixture.sut.willPresent()
        fixture.sut.didDismiss()
        let relaunched = WorkspacesIntroCampaign(defaults: fixture.defaults, isFreshInstall: { false })
        #expect(relaunched.hasSeen)
        #expect(!relaunched.isEligible)
    }

    @Test func markSeen_isIdempotent() {
        let fixture = Fixture()
        fixture.sut.markSeen()
        fixture.sut.markSeen()
        #expect(fixture.sut.hasSeen)
        #expect(!fixture.sut.isEligible)
    }

    // MARK: - Fresh install exclusion

    /// The offer is for people who were here before Workspaces shipped. A
    /// fresh install is recorded as seen on its first check and stays
    /// excluded even once onboarding completes and the install is no
    /// longer "fresh".
    @Test func freshInstall_isConsumedSilently_andStaysExcluded() {
        let fixture = Fixture()
        fixture.isFreshInstall = true
        #expect(!fixture.sut.isEligible)
        #expect(fixture.sut.hasSeen)

        fixture.isFreshInstall = false
        #expect(!fixture.sut.isEligible)
    }

    #if DEBUG
        @Test func resetForDebugTesting_clearsSeen_andPresenting() {
            let fixture = Fixture()
            fixture.sut.willPresent()
            #expect(!fixture.sut.isEligible)
            fixture.sut.resetForDebugTesting()
            #expect(!fixture.sut.hasSeen)
            #expect(fixture.sut.isEligible)
        }
    #endif

    // MARK: - Key hygiene

    /// Namespaced and versioned so a later Workspaces announcement can ship
    /// its own key without colliding with this one.
    @Test func seenKey_isNamespaced() {
        #expect(WorkspacesIntroCampaign.seenDefaultsKey == "ai.osaurus.campaign.workspaces-intro-2026-09.seen")
        #expect(WorkspacesIntroCampaign.seenDefaultsKey != ProductHuntLaunchCampaign.seenDefaultsKey)
        #expect(WorkspacesIntroCampaign.seenDefaultsKey != ImportHistoryPromptGate.seenDefaultsKey)
    }
}
