import Combine
import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct CreditsAttentionStateTests {
    private static let healthy: Int64 = 5_000_000

    private func snap(_ micro: Int64, frozen: Bool = false, web: Bool = false) -> CreditsAttentionSnapshot {
        CreditsAttentionSnapshot(balanceMicro: micro, frozen: frozen, webSearchNeedsTopUp: web)
    }

    @Test func firstObservationIsSilentEvenWhenEmpty() {
        #expect(CreditsAttentionState(first: snap(0)).indicator == .none)
        #expect(CreditsAttentionState(first: snap(Self.healthy)).indicator == .none)
    }

    @Test func increasePingsNewCreditsUntilAcknowledged() {
        var state = CreditsAttentionState(first: snap(Self.healthy))
        state.observe(snap(Self.healthy + 100))
        #expect(state.indicator == .newCredits)
        state.acknowledge()
        #expect(state.indicator == .none)
        state.observe(snap(Self.healthy + 100))
        #expect(state.indicator == .none)
    }

    @Test func spendingAloneNeverPings() {
        var state = CreditsAttentionState(first: snap(Self.healthy))
        state.observe(snap(Self.healthy - 1_000))
        state.observe(snap(Self.healthy - 2_000))
        #expect(state.indicator == .none)
    }

    @Test func grantAfterSpendingPingsEvenBelowStartingBalance() {
        var state = CreditsAttentionState(first: snap(Self.healthy))
        state.observe(snap(Self.healthy - 500_000))
        state.observe(snap(Self.healthy - 300_000))
        #expect(state.indicator == .newCredits)
    }

    @Test func newCreditsSurviveLaterSpending() {
        var state = CreditsAttentionState(first: snap(Self.healthy))
        state.observe(snap(Self.healthy + 1_000_000))
        state.observe(snap(Self.healthy))
        #expect(state.indicator == .newCredits)
    }

    @Test func droppingIntoLowPingsOnceThenStaysQuiet() {
        var state = CreditsAttentionState(first: snap(Self.healthy))
        state.observe(snap(900_000))
        #expect(state.indicator == .attention(.lowBalance))
        state.acknowledge()
        state.observe(snap(800_000))
        #expect(state.indicator == .none)
    }

    @Test func escalationPastAcknowledgedLevelPingsAgain() {
        var state = CreditsAttentionState(first: snap(900_000))
        state.observe(snap(0))
        #expect(state.indicator == .attention(.outOfCredits))
        state.acknowledge()
        state.observe(snap(0, web: true))
        #expect(state.indicator == .attention(.webSearchNeedsTopUp))
        state.acknowledge()
        state.observe(snap(0, frozen: true))
        #expect(state.indicator == .none)
    }

    @Test func frozenIsReportedAsFrozen() {
        var state = CreditsAttentionState(first: snap(Self.healthy))
        state.observe(snap(Self.healthy, frozen: true))
        #expect(state.indicator == .attention(.frozen))
    }

    @Test func recoveryRearmsTheAttentionPing() {
        var state = CreditsAttentionState(first: snap(900_000))
        state.observe(snap(Self.healthy))
        #expect(state.indicator == .newCredits)
        state.acknowledge()
        state.observe(snap(900_000))
        #expect(state.indicator == .attention(.lowBalance))
    }

    @Test func attentionTakesPrecedenceOverNewCredits() {
        var state = CreditsAttentionState(first: snap(Self.healthy))
        state.observe(snap(Self.healthy + 100))
        state.observe(snap(Self.healthy + 100, web: true))
        #expect(state.indicator == .attention(.webSearchNeedsTopUp))
    }

    @Test func roundTripsThroughCodable() throws {
        var state = CreditsAttentionState(first: snap(Self.healthy))
        state.observe(snap(Self.healthy + 100))
        let decoded = try JSONDecoder().decode(
            CreditsAttentionState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
        #expect(decoded.indicator == .newCredits)
    }
}

@MainActor
@Suite
struct CreditsAttentionTrackerTests {
    private final class Harness {
        let snapshots = PassthroughSubject<CreditsAttentionSnapshot?, Never>()
        let identity = PassthroughSubject<Void, Never>()
        let defaults: UserDefaults

        init() {
            let suite = "CreditsAttentionTrackerTests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
        }

        @MainActor func tracker() -> CreditsAttentionTracker {
            CreditsAttentionTracker(
                snapshots: snapshots.eraseToAnyPublisher(),
                identityChanges: identity.eraseToAnyPublisher(),
                defaults: defaults
            )
        }
    }

    private func drainMain() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func snap(_ micro: Int64) -> CreditsAttentionSnapshot {
        CreditsAttentionSnapshot(balanceMicro: micro, frozen: false, webSearchNeedsTopUp: false)
    }

    @Test func pingPersistsAcrossRelaunchAndClearsOnAcknowledge() async {
        let harness = Harness()
        var tracker: CreditsAttentionTracker? = harness.tracker()
        harness.snapshots.send(snap(5_000_000))
        harness.snapshots.send(snap(6_000_000))
        await drainMain()
        #expect(tracker?.indicator == .newCredits)

        tracker = harness.tracker()
        harness.snapshots.send(snap(6_000_000))
        await drainMain()
        #expect(tracker?.indicator == .newCredits)

        tracker?.acknowledge()
        #expect(tracker?.indicator == CreditsAttentionIndicator.none)
        tracker = harness.tracker()
        harness.snapshots.send(snap(6_000_000))
        await drainMain()
        #expect(tracker?.indicator == CreditsAttentionIndicator.none)
    }

    @Test func noWalletHidesThePing() async {
        let harness = Harness()
        let tracker = harness.tracker()
        harness.snapshots.send(snap(5_000_000))
        harness.snapshots.send(snap(6_000_000))
        harness.snapshots.send(nil)
        await drainMain()
        #expect(tracker.indicator == .none)
    }

    @Test func identityChangeStartsSilently() async {
        let harness = Harness()
        let tracker = harness.tracker()
        harness.snapshots.send(snap(5_000_000))
        await drainMain()
        harness.identity.send(())
        harness.snapshots.send(snap(9_000_000))
        await drainMain()
        #expect(tracker.indicator == .none)
        #expect(harness.defaults.data(forKey: CreditsAttentionTracker.defaultsKey) != nil)
    }

    /// Regression for APPLE-MACOS-3WQ: `OsaurusIdentity.setup()` posts the
    /// identity notification from a background thread, and the upstream
    /// transform must not assert main-actor isolation.
    @Test func identityNotificationPostedOffMainResetsWithoutTrapping() async {
        let harness = Harness()
        let center = NotificationCenter()
        let tracker = CreditsAttentionTracker(
            snapshots: harness.snapshots.eraseToAnyPublisher(),
            identityChanges: CreditsAttentionTracker.identityChangePublisher(center: center),
            defaults: harness.defaults
        )
        harness.snapshots.send(snap(5_000_000))
        await drainMain()
        #expect(harness.defaults.data(forKey: CreditsAttentionTracker.defaultsKey) != nil)

        // Task.detached runs on the cooperative pool, never the main thread,
        // matching where OsaurusIdentity.setup() posts this notification.
        await Task.detached {
            center.post(name: .osaurusIdentityChanged, object: nil)
        }.value
        await drainMain()
        #expect(tracker.indicator == .none)
        #expect(harness.defaults.data(forKey: CreditsAttentionTracker.defaultsKey) == nil)
    }
}
