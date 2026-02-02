//
//  OnboardingService.swift
//  osaurus
//
//  Service managing onboarding state and first-launch detection.
//

import Foundation

/// Service managing onboarding state and first-launch detection
@MainActor
public final class OnboardingService: ObservableObject {
    public static let shared = OnboardingService()

    private let hasCompletedOnboardingKey = "hasCompletedOnboarding"
    private let onboardingVersionKey = "onboardingVersion"

    /// Current onboarding version - increment to force re-onboarding after major updates
    private let currentOnboardingVersion = 1

    /// Whether onboarding should be shown (first launch or version mismatch)
    public var shouldShowOnboarding: Bool {
        let completed = UserDefaults.standard.bool(forKey: hasCompletedOnboardingKey)
        let version = UserDefaults.standard.integer(forKey: onboardingVersionKey)
        return !completed || version < currentOnboardingVersion
    }

    /// Whether this is a completely fresh install (never completed onboarding)
    public var isFreshInstall: Bool {
        !UserDefaults.standard.bool(forKey: hasCompletedOnboardingKey)
    }

    private init() {}

    /// Mark onboarding as completed
    public func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: hasCompletedOnboardingKey)
        UserDefaults.standard.set(currentOnboardingVersion, forKey: onboardingVersionKey)
    }

    /// Reset onboarding state (for re-running via help button)
    public func resetOnboarding() {
        UserDefaults.standard.set(false, forKey: hasCompletedOnboardingKey)
        UserDefaults.standard.set(0, forKey: onboardingVersionKey)
    }
}
