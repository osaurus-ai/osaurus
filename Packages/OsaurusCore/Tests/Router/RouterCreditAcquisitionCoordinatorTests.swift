import Foundation
import Testing

@testable import OsaurusCore

@Suite("Router credit acquisition coordinator", .serialized)
@MainActor
struct RouterCreditAcquisitionCoordinatorTests {
    private func withCoordinator(
        _ body: (RouterCreditAcquisitionCoordinator, UserDefaults) throws -> Void
    ) rethrows {
        let suite = "router-credit-acquisition-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(
            RouterCreditAcquisitionCoordinator(
                defaults: defaults,
                notificationCenter: NotificationCenter()
            ),
            defaults
        )
    }

    @Test func freshInstallAllowsOnlyAcquisitionRequests() {
        withCoordinator { coordinator, _ in
            coordinator.prepareForLaunch(isFreshInstall: true)

            #expect(coordinator.phase == .awaitingChoice)
            #expect(coordinator.blocksGeneralSignedRequests)
            #expect(coordinator.allowsSignedRequest(pathAndQuery: "/credits/redeem"))
            #expect(coordinator.allowsSignedRequest(pathAndQuery: "/credits/redeem?source=link"))
            #expect(coordinator.allowsSignedRequest(pathAndQuery: "/credits/welcome/claim"))
            #expect(!coordinator.allowsSignedRequest(pathAndQuery: "/credits/balance"))
            #expect(!coordinator.allowsSignedRequest(pathAndQuery: "/models"))
            #expect(!coordinator.shouldAttemptWelcomeClaim)
        }
    }

    /// Reporting a problem must work before the welcome choice is made: the
    /// router does not count `/support/*` as the account's first action, so
    /// letting it through cannot cost the user a first-time code.
    @Test func freshInstallAllowsHelpRequestsBeforeTheWelcomeChoice() {
        withCoordinator { coordinator, _ in
            coordinator.prepareForLaunch(isFreshInstall: true)
            #expect(coordinator.blocksGeneralSignedRequests)

            for path in [
                "/support/threads",
                "/support/threads?limit=20",
                "/support/threads/7d0f0c2e-0000-4000-8000-000000000001",
                "/support/threads/7d0f0c2e-0000-4000-8000-000000000001/messages",
                "/support/threads/7d0f0c2e-0000-4000-8000-000000000001/read",
            ] {
                #expect(coordinator.allowsSignedRequest(pathAndQuery: path), "blocked: \(path)")
            }

            // Only the `/support` segment, not anything that starts with it
            // or merely mentions it.
            #expect(!coordinator.allowsSignedRequest(pathAndQuery: "/supporters"))
            #expect(!coordinator.allowsSignedRequest(pathAndQuery: "/support-export/threads"))
            #expect(!coordinator.allowsSignedRequest(pathAndQuery: "/credits/balance?next=/support/threads"))
            #expect(!coordinator.allowsSignedRequest(pathAndQuery: "/credits/support/threads"))
        }
    }

    @Test func supportPathMatchesTheSegmentOnly() {
        #expect(RouterCreditAcquisitionCoordinator.isSupportPath("/support"))
        #expect(RouterCreditAcquisitionCoordinator.isSupportPath("/support/threads"))
        #expect(!RouterCreditAcquisitionCoordinator.isSupportPath("/supportx"))
        #expect(!RouterCreditAcquisitionCoordinator.isSupportPath("support/threads"))
        #expect(!RouterCreditAcquisitionCoordinator.isSupportPath("/admin/support/threads"))
    }

    @Test func welcomeSelectionKeepsGeneralTrafficBlockedUntilSettlement() {
        withCoordinator { coordinator, _ in
            coordinator.prepareForLaunch(isFreshInstall: true)
            coordinator.selectWelcomeCredit()

            #expect(coordinator.phase == .welcomePending)
            #expect(coordinator.shouldAttemptWelcomeClaim)
            #expect(!coordinator.allowsSignedRequest(pathAndQuery: "/models"))

            coordinator.resolveAfterWelcomeClaim()
            #expect(coordinator.phase == .resolved)
            #expect(!coordinator.blocksGeneralSignedRequests)
            #expect(coordinator.allowsSignedRequest(pathAndQuery: "/models"))
        }
    }

    @Test func successfulRedemptionReleasesGateAndPersistsAcrossRelaunch() {
        withCoordinator { coordinator, defaults in
            coordinator.prepareForLaunch(isFreshInstall: true)
            coordinator.resolveAfterCodeRedemption()
            #expect(coordinator.phase == .resolved)

            let relaunched = RouterCreditAcquisitionCoordinator(
                defaults: defaults,
                notificationCenter: NotificationCenter()
            )
            relaunched.prepareForLaunch(isFreshInstall: true)
            #expect(relaunched.phase == .resolved)
            #expect(relaunched.allowsSignedRequest(pathAndQuery: "/credits/balance"))
        }
    }

    @Test func existingInstallRetainsUngatedWelcomeBehavior() {
        withCoordinator { coordinator, _ in
            coordinator.prepareForLaunch(isFreshInstall: false)

            #expect(coordinator.phase == .notApplicable)
            #expect(!coordinator.blocksGeneralSignedRequests)
            #expect(coordinator.shouldAttemptWelcomeClaim)
            #expect(coordinator.allowsSignedRequest(pathAndQuery: "/models"))
        }
    }

    @Test func preexistingWelcomeResolutionMigratesIncompleteOnboardingToResolved() {
        withCoordinator { coordinator, defaults in
            defaults.set(
                WelcomeCreditService.Resolution.granted.rawValue,
                forKey: WelcomeCreditService.resolutionDefaultsKey
            )

            coordinator.prepareForLaunch(isFreshInstall: true)

            #expect(coordinator.phase == .resolved)
            #expect(!coordinator.blocksGeneralSignedRequests)
            #expect(coordinator.allowsSignedRequest(pathAndQuery: "/models"))
        }
    }
}
