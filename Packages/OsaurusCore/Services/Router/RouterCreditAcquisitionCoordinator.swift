import Foundation

extension Notification.Name {
    /// Posted when a fresh wallet's first-action acquisition flow settles and
    /// normal signed Router traffic may resume.
    static let routerCreditAcquisitionResolved = Notification.Name(
        "RouterCreditAcquisitionResolved"
    )
}

/// Persists and enforces the first-launch choice between a redeem code and the
/// automatic welcome-credit claim.
///
/// The Router decides eligibility, but the client must guarantee that no
/// balance, model-discovery, checkout, or inference request is signed before
/// one of the two acquisition requests. `OsaurusRouterAuthSigner` is the final
/// enforcement point; higher-level services also consult this coordinator to
/// avoid surfacing expected gate failures as provider errors.
@MainActor
final class RouterCreditAcquisitionCoordinator {
    static let shared = RouterCreditAcquisitionCoordinator()

    enum Phase: String, Equatable {
        /// A genuinely fresh install has not chosen a code or the welcome path.
        case awaitingChoice
        /// The user continued without a successful code. Only the welcome claim
        /// may run until it succeeds or receives a terminal refusal.
        case welcomePending
        /// The first-action acquisition flow settled.
        case resolved
        /// Upgrade/migration path for an existing installation. It must retain
        /// the historical automatic welcome-claim behavior without gating.
        case notApplicable
    }

    static let phaseDefaultsKey = "ai.osaurus.router.credit-acquisition.phase"

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private var isPrepared = false

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
    }

    var phase: Phase? {
        defaults.string(forKey: Self.phaseDefaultsKey).flatMap(Phase.init(rawValue:))
    }

    /// Must run before launch-time services can issue signed Router requests.
    /// Existing persisted phases always win so an offline welcome attempt stays
    /// ordered correctly across an onboarding completion or app relaunch.
    func prepareForLaunch(isFreshInstall: Bool) {
        if phase == nil {
            // Migration safety: older builds could grant or terminally hide the
            // welcome offer while onboarding was still incomplete. That wallet
            // has already performed its first signed action and must not be
            // trapped behind a newly introduced choice gate.
            let existingWelcomeResolution = defaults.string(
                forKey: WelcomeCreditService.resolutionDefaultsKey
            )
            if existingWelcomeResolution != nil {
                setPhase(.resolved)
            } else {
                setPhase(isFreshInstall ? .awaitingChoice : .notApplicable)
            }
        }
        isPrepared = true
    }

    var blocksGeneralSignedRequests: Bool {
        guard isPrepared else { return false }
        switch phase {
        case .awaitingChoice, .welcomePending:
            return true
        case .resolved, .notApplicable, nil:
            return false
        }
    }

    /// The signing-layer allowlist while first-action acquisition is pending.
    func allowsSignedRequest(pathAndQuery: String) -> Bool {
        guard blocksGeneralSignedRequests else { return true }
        let path = pathAndQuery.split(separator: "?", maxSplits: 1).first.map(String.init)
        return path == "/credits/redeem" || path == "/credits/welcome/claim"
    }

    /// Whether the automatic welcome service may issue its claim now.
    var shouldAttemptWelcomeClaim: Bool {
        guard isPrepared else { return true }
        switch phase {
        case .welcomePending, .notApplicable:
            return true
        case .awaitingChoice, .resolved, nil:
            return false
        }
    }

    /// Called synchronously before onboarding advances or closes without a
    /// successful code, so identity observers cannot race a redeem decision.
    func selectWelcomeCredit() {
        guard phase == .awaitingChoice else { return }
        setPhase(.welcomePending)
    }

    func resolveAfterWelcomeClaim() {
        guard phase == .welcomePending else { return }
        resolve()
    }

    func resolveAfterCodeRedemption() {
        guard phase == .awaitingChoice || phase == .welcomePending else { return }
        resolve()
    }

    private func resolve() {
        setPhase(.resolved)
        notificationCenter.post(name: .routerCreditAcquisitionResolved, object: nil)
    }

    private func setPhase(_ phase: Phase) {
        defaults.set(phase.rawValue, forKey: Self.phaseDefaultsKey)
    }
}
