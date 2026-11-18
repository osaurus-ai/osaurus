//
//  BundleOnboardingPreferences.swift
//  osaurus
//
//  What installed bundles asked of first-run onboarding: skip the intro,
//  leave out starter teammates. Kept per bundle in `import/onboarding.json`
//  (shared with the CLI so `remove --bundle` knows there is something to
//  take back) and read when onboarding opens and when it seeds the team.
//  A Mac that already finished onboarding keeps everything it has; the
//  import says so instead.
//

import Foundation
import OsaurusRepository
import os

private let log = Logger(subsystem: "ai.osaurus", category: "Import")

@MainActor
enum BundleOnboardingPreferences {

    /// Every bundle's asks combined, counting imports still queued.
    static var effective: BundleOnboarding { ImportQueue.effectiveOnboarding() }

    /// Records or forgets what `request` asks of onboarding. Returns the
    /// warnings for the import result: on a Mac past onboarding, the asks
    /// cannot take effect and existing teammates stay.
    static func apply(
        _ request: ImportRequest,
        alreadyOnboarded: Bool = !OnboardingService.shared.isFreshInstall || TeamSeeder.hasSeeded(),
        agents: [Agent] = AgentManager.shared.agents
    ) -> [String] {
        var bundles = ImportQueue.loadOnboarding()
        if request.forgetsOnboarding == true {
            guard bundles.removeValue(forKey: request.bundleId) != nil else { return [] }
            save(bundles)
            return []
        }
        guard let onboarding = request.onboarding, !onboarding.isEmpty else { return [] }
        bundles[request.bundleId] = onboarding
        save(bundles)

        guard alreadyOnboarded else { return [] }
        var warnings: [String] = []
        if onboarding.skip {
            warnings.append("Onboarding already finished on this Mac, so skipping it has no effect.")
        }
        for agent in agents {
            guard let teammate = agent.teammate, onboarding.excludeTeammates.excludes(teammate.rawValue) else {
                continue
            }
            warnings.append("\(agent.name) already exists on this Mac; the bundle does not remove it.")
        }
        return warnings
    }

    private static func save(_ bundles: [String: BundleOnboarding]) {
        do {
            try ImportQueue.saveOnboarding(bundles)
        } catch {
            log.error("Could not save bundle onboarding preferences: \(error.localizedDescription, privacy: .public)")
        }
    }
}
