//
//  OnboardingUpgradeGateTests.swift
//  OsaurusCoreTests
//
//  An in-place update keeps the UserDefaults domain, so someone who
//  finished onboarding on 0.25.x must not see it again, and must not be
//  treated as a fresh install (which seeds starter teammates and workflows).
//  Instead the window opens once on the Classic upgrade screen.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Onboarding gate across updates")
struct OnboardingUpgradeGateTests {
    private func defaults(
        completed: Bool?, version: Int?, seeded: Bool = false, choice: String? = nil
    ) throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: "onboarding-gate-\(UUID().uuidString)"))
        if let completed { defaults.set(completed, forKey: OnboardingService.hasCompletedOnboardingKey) }
        if let version { defaults.set(version, forKey: OnboardingService.onboardingVersionKey) }
        if seeded { defaults.set(true, forKey: TeamSeeder.seededDefaultsKey) }
        if let choice { defaults.set(choice, forKey: OnboardingService.classicUpgradeChoiceKey) }
        return defaults
    }

    @Test
    func versionStaysAtWhatShippedBuildsWrite() {
        #expect(OnboardingService.currentOnboardingVersion == 3)
    }

    @Test
    func finishedOnAnEarlierBuild_skipsOnboarding_andIsNotFresh() throws {
        let defaults = try defaults(completed: true, version: 3)
        #expect(!OnboardingService.shouldShowOnboarding(in: defaults))
        #expect(!OnboardingService.isFreshInstall(in: defaults))
    }

    @Test
    func freshInstall_showsOnboarding() throws {
        let defaults = try defaults(completed: nil, version: nil)
        #expect(OnboardingService.shouldShowOnboarding(in: defaults))
        #expect(OnboardingService.isFreshInstall(in: defaults))
    }

    @Test
    func finishedOnAPreVersionedBuild_seesOnboarding_butIsNotFresh() throws {
        let defaults = try defaults(completed: true, version: 2)
        #expect(OnboardingService.shouldShowOnboarding(in: defaults))
        #expect(!OnboardingService.isFreshInstall(in: defaults))
    }

    // MARK: Classic upgrade screen

    @Test
    func classicInstall_withNoTeam_isOfferedTheUpgradeScreen() throws {
        #expect(OnboardingService.shouldOfferClassicUpgrade(in: try defaults(completed: true, version: 3), hasTeammates: false))
        #expect(OnboardingService.shouldOfferClassicUpgrade(in: try defaults(completed: true, version: 2), hasTeammates: false))
    }

    @Test
    func freshInstall_getsTheNormalOnboarding_notTheUpgradeScreen() throws {
        #expect(!OnboardingService.shouldOfferClassicUpgrade(in: try defaults(completed: nil, version: nil), hasTeammates: false))
    }

    @Test
    func aSeededInstall_isNotOffered() throws {
        let defaults = try defaults(completed: true, version: 3, seeded: true)
        #expect(!OnboardingService.shouldOfferClassicUpgrade(in: defaults, hasTeammates: false))
    }

    @Test
    func teammatesMadeOnPurpose_meanNoOffer() throws {
        let defaults = try defaults(completed: true, version: 3)
        #expect(!OnboardingService.shouldOfferClassicUpgrade(in: defaults, hasTeammates: true))
    }

    @Test
    func aRecordedChoice_endsTheOffer() throws {
        for choice in ["installed", "kept"] {
            let defaults = try defaults(completed: true, version: 3, choice: choice)
            #expect(!OnboardingService.shouldOfferClassicUpgrade(in: defaults, hasTeammates: false), "\(choice)")
        }
    }

    @Test @MainActor
    func recordingAChoice_marksOnboardingCurrent() throws {
        let defaults = try defaults(completed: true, version: 2)
        OnboardingService.shared.recordClassicUpgradeChoice(.kept, defaults: defaults)
        #expect(defaults.string(forKey: OnboardingService.classicUpgradeChoiceKey) == "kept")
        #expect(!OnboardingService.shouldShowOnboarding(in: defaults))
        #expect(!OnboardingService.shouldOfferClassicUpgrade(in: defaults, hasTeammates: false))
        #expect(!OnboardingService.isFreshInstall(in: defaults))
    }
}
