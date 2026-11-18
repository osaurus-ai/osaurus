//
//  OnboardingUpgradeGateTests.swift
//  OsaurusCoreTests
//
//  An in-place update keeps the UserDefaults domain, so someone who
//  finished onboarding on 0.25.x must not see it again, and must not be
//  treated as a fresh install (which seeds starter teammates and workflows).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Onboarding gate across updates")
struct OnboardingUpgradeGateTests {
    private func defaults(completed: Bool?, version: Int?) throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: "onboarding-gate-\(UUID().uuidString)"))
        if let completed { defaults.set(completed, forKey: OnboardingService.hasCompletedOnboardingKey) }
        if let version { defaults.set(version, forKey: OnboardingService.onboardingVersionKey) }
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
}
