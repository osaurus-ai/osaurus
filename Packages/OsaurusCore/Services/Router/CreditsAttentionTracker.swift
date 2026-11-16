import Combine
import Foundation

/// How urgently the wallet needs the user, worst last.
enum CreditsAttentionLevel: Int, Codable, Comparable, Sendable {
    case healthy
    case low
    case empty
    /// Frozen account, or hosted web search stopped for lack of funds.
    case blocked

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What the navigation usage button shows.
enum CreditsAttentionIndicator: Equatable, Sendable {
    case none
    case newCredits
    case attention(CreditsAttentionReason)
}

enum CreditsAttentionReason: Equatable, Sendable {
    case lowBalance
    case outOfCredits
    case frozen
    case webSearchNeedsTopUp
}

/// One server-confirmed view of the wallet.
struct CreditsAttentionSnapshot: Equatable, Sendable {
    let balanceMicro: Int64
    let frozen: Bool
    let webSearchNeedsTopUp: Bool

    var level: CreditsAttentionLevel {
        if frozen || webSearchNeedsTopUp { return .blocked }
        if balanceMicro <= 0 { return .empty }
        if balanceMicro < CreditsAttentionState.lowBalanceMicro { return .low }
        return .healthy
    }

    var reason: CreditsAttentionReason? {
        if frozen { return .frozen }
        if webSearchNeedsTopUp { return .webSearchNeedsTopUp }
        switch level {
        case .empty: return .outOfCredits
        case .low: return .lowBalance
        case .healthy, .blocked: return nil
        }
    }
}

/// Edge-triggered wallet attention. A ping fires when credits land or the
/// wallet gets worse than the user last saw, and clears on `acknowledge()`;
/// a steady state never re-pings, so a zero balance on a local-only setup
/// stays quiet.
struct CreditsAttentionState: Codable, Equatable, Sendable {
    /// Below this the balance is low (10,000 credits, $1.00).
    static let lowBalanceMicro: Int64 = 1_000_000

    /// Lowest balance seen since the last acknowledgement. Spending lowers
    /// it, so credits that land after spending still read as an increase.
    private(set) var baselineMicro: Int64
    private(set) var acknowledgedLevel: CreditsAttentionLevel
    private(set) var hasNewCredits: Bool
    private(set) var latest: Latest

    struct Latest: Codable, Equatable, Sendable {
        var balanceMicro: Int64
        var frozen: Bool
        var webSearchNeedsTopUp: Bool
    }

    /// The first observation for an account records it without pinging.
    init(first snapshot: CreditsAttentionSnapshot) {
        baselineMicro = snapshot.balanceMicro
        acknowledgedLevel = snapshot.level
        hasNewCredits = false
        latest = Latest(snapshot)
    }

    mutating func observe(_ snapshot: CreditsAttentionSnapshot) {
        if snapshot.balanceMicro > baselineMicro {
            hasNewCredits = true
        } else {
            baselineMicro = snapshot.balanceMicro
        }
        acknowledgedLevel = min(acknowledgedLevel, snapshot.level)
        latest = Latest(snapshot)
    }

    mutating func acknowledge() {
        baselineMicro = latest.balanceMicro
        acknowledgedLevel = latest.snapshot.level
        hasNewCredits = false
    }

    var indicator: CreditsAttentionIndicator {
        let current = latest.snapshot
        if current.level > acknowledgedLevel, let reason = current.reason {
            return .attention(reason)
        }
        return hasNewCredits ? .newCredits : .none
    }
}

extension CreditsAttentionState.Latest {
    init(_ snapshot: CreditsAttentionSnapshot) {
        self.init(
            balanceMicro: snapshot.balanceMicro,
            frozen: snapshot.frozen,
            webSearchNeedsTopUp: snapshot.webSearchNeedsTopUp
        )
    }

    var snapshot: CreditsAttentionSnapshot {
        CreditsAttentionSnapshot(
            balanceMicro: balanceMicro, frozen: frozen, webSearchNeedsTopUp: webSearchNeedsTopUp)
    }
}

/// Drives the navigation usage button's ping from server-fetched balances and
/// persists what the user has seen, so a relaunch neither repeats nor loses
/// a ping.
@MainActor
final class CreditsAttentionTracker: ObservableObject {
    static let shared = CreditsAttentionTracker()

    static let defaultsKey = "routerCreditsAttention.v1"

    @Published private(set) var indicator: CreditsAttentionIndicator = .none

    private var state: CreditsAttentionState?
    /// False while there is no confirmed wallet (router off, signed out), so
    /// stale stored state never pings.
    private var hasSnapshot = false
    private let defaults: UserDefaults
    private var cancellables: Set<AnyCancellable> = []

    convenience init() {
        let account = OsaurusRouterAccountService.shared
        let snapshots = account.$lastFetchedBalance
            .combineLatest(account.$webSearchNeedsTopUp)
            .map(Self.snapshot(from:))
            .eraseToAnyPublisher()
        self.init(
            snapshots: snapshots,
            identityChanges: Self.identityChangePublisher()
        )
    }

    /// Upstream operators run on whichever thread emits, before the
    /// `receive(on:)` hop in `init`. Closures written inline in this
    /// `@MainActor` class are inferred main-actor-isolated and trap at
    /// runtime when run elsewhere — `.osaurusIdentityChanged` is posted from
    /// `OsaurusIdentity.setup()` on a cooperative-pool thread. Keep these
    /// transforms `nonisolated` so they are safe on any thread.
    nonisolated static func identityChangePublisher(
        center: NotificationCenter = .default
    ) -> AnyPublisher<Void, Never> {
        center.publisher(for: .osaurusIdentityChanged)
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    nonisolated static func snapshot(
        from input: (balance: OsaurusRouterBalanceResponse?, needsTopUp: Bool)
    ) -> CreditsAttentionSnapshot? {
        let (balance, needsTopUp) = input
        guard let balance else { return nil }
        return CreditsAttentionSnapshot(
            balanceMicro: Int64(balance.balanceMicro) ?? 0,
            frozen: balance.frozen,
            webSearchNeedsTopUp: needsTopUp
        )
    }

    init(
        snapshots: AnyPublisher<CreditsAttentionSnapshot?, Never>,
        identityChanges: AnyPublisher<Void, Never>,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey) {
            state = try? JSONDecoder().decode(CreditsAttentionState.self, from: data)
        }
        snapshots
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.observe($0) }
            .store(in: &cancellables)
        identityChanges
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.resetForNewIdentity() }
            .store(in: &cancellables)
    }

    /// The user opened the usage card.
    func acknowledge() {
        guard hasSnapshot, var next = state else { return }
        next.acknowledge()
        commit(next)
    }

    private func observe(_ snapshot: CreditsAttentionSnapshot?) {
        guard let snapshot else {
            hasSnapshot = false
            indicator = .none
            return
        }
        hasSnapshot = true
        var next = state ?? CreditsAttentionState(first: snapshot)
        if state != nil { next.observe(snapshot) }
        commit(next)
    }

    private func resetForNewIdentity() {
        state = nil
        hasSnapshot = false
        indicator = .none
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    private func commit(_ next: CreditsAttentionState) {
        if next != state {
            state = next
            if let data = try? JSONEncoder().encode(next) {
                defaults.set(data, forKey: Self.defaultsKey)
            }
        }
        let shown = hasSnapshot ? next.indicator : .none
        if indicator != shown { indicator = shown }
    }
}
