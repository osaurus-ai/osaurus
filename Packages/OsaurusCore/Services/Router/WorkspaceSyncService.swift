import AppKit
import Combine
import Foundation

struct WorkspaceSyncSnapshot: Decodable, Equatable, Sendable {
    struct Entry: Decodable, Equatable, Sendable {
        let workspace: OsaurusRouterWorkspaceSummary
        let detail: OsaurusRouterWorkspaceDetail
        let members: [OsaurusRouterWorkspaceMember]
        let agents: [OsaurusRouterWorkspaceAgent]
        let invites: [OsaurusRouterWorkspaceInvite]
    }
    let workspaces: [Entry]
}

struct WorkspaceSyncFrame: Decodable, Sendable {
    let type: String
    let revision: Int
    let snapshot: WorkspaceSyncSnapshot?
}

/// One subscription for the account, independent of Settings and chat windows.
/// Every reconnect starts with a full authorized snapshot. A heartbeat only
/// renews verification after the server has reconciled current database state.
///
/// The stream is lazy: it only runs for an account known to belong to at
/// least one workspace (`hasKnownMembership`, persisted across launches).
/// The router closes every stream after ~110 s so the client re-signs, which
/// for a user with no workspaces meant ~30 signed reconnects an hour for
/// nothing. A first launch (or a cleared flag) issues one `GET /workspaces`
/// probe through the roster store; a non-empty list starts the stream, an
/// empty snapshot or list stops it again.
@MainActor
final class WorkspaceSyncService: ObservableObject {
    static let shared = WorkspaceSyncService()
    @Published private(set) var isVerified = false
    private var task: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var workers: [String: Task<Void, Never>] = [:]
    private var snapshot: WorkspaceSyncSnapshot?
    private var lastFrameAt = Date.distantPast
    private var connectionStartedAt = Date.distantPast
    private var revision = 0
    private var streamGeneration = UUID()
    private var lastFallback = Date.distantPast
    /// Current fallback / reconnect delay while the stream is not verified.
    /// Doubles from `fallbackInitialDelay` up to `fallbackMaxDelay` and resets
    /// on any frame, so an unreachable router (offline Mac, old router) is
    /// asked a few times a minute at first and then every five minutes.
    private(set) var fallbackDelay: TimeInterval = WorkspaceSyncService.fallbackInitialDelay
    var client: OsaurusRouterAPIClient = .shared
    private let defaults: UserDefaults
    /// Someone asked for the stream this launch (launch bootstrap or a chat
    /// window observing the roster). The stream itself still waits for
    /// known membership.
    private var wanted = false
    /// The one-per-launch membership probe (`GET /workspaces`) already ran
    /// or is running.
    private var probedMembership = false

    nonisolated static let fallbackInitialDelay: TimeInterval = 10
    nonisolated static let fallbackMaxDelay: TimeInterval = 300

    /// Persisted "this account belongs to >= 1 workspace" flag that gates the
    /// stream. Set from any non-empty list or snapshot, cleared by an empty
    /// one, so the next launch can decide without a probe.
    nonisolated static let membershipDefaultsKey = "ai.osaurus.workspaces.hasMembership"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasKnownMembership: Bool {
        defaults.bool(forKey: Self.membershipDefaultsKey)
    }

    /// True while the stream loop is running (not necessarily verified).
    var isStreaming: Bool { task != nil }

    /// Whether the stream's last frame is recent enough to keep trusting it.
    /// The router sends a `verified` heartbeat (or a `snapshot`) every second
    /// for the first 5 s of a stream, then every 15 s ± 20 %. The lease is
    /// shared with `WorkspaceRosterStore.verificationLifetime` so a healthy
    /// stream is never torn down between two steady-state ticks (which is
    /// exactly what a 3 s lease did after the router relaxed its tick).
    nonisolated static let verificationLease: TimeInterval = WorkspaceRosterStore.verificationLifetime

    nonisolated static func verificationIsFresh(lastFrameAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastFrameAt) < verificationLease
    }

    /// How long a fresh connection may go without its first frame. The router
    /// sends the snapshot immediately on connect, so this stays short: a
    /// stalled connect falls back to polling quickly instead of waiting out
    /// the (much longer) steady-state lease.
    nonisolated static let firstFrameDeadline: TimeInterval = 10

    nonisolated static func connectionIsPending(startedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(startedAt) < firstFrameDeadline
    }

    /// Next fallback delay after a fruitless pass: exponential, capped.
    nonisolated static func nextFallbackDelay(after current: TimeInterval) -> TimeInterval {
        min(fallbackMaxDelay, max(fallbackInitialDelay, current * 2))
    }

    /// Ask for the stream. Starts it right away for an account with known
    /// membership; otherwise runs one membership probe this launch and lets
    /// `noteMembership` start it if the list is non-empty. Idempotent.
    func start() {
        guard !RuntimeEnvironment.isUnderTests else { return }
        wanted = true
        reconcileStream()
    }

    /// Stop the stream and forget the request. The roster store's observers
    /// calling `start()` again re-arm it (membership permitting).
    func stop() {
        wanted = false
        stopStream()
    }

    /// Record whether the account belongs to any workspace. Called with every
    /// authoritative list (`WorkspaceRosterStore.refresh`,
    /// `WorkspacesService.refreshWorkspaces`) and snapshot, so the stream
    /// starts the moment a first workspace appears and stops once the last
    /// one is gone.
    func noteMembership(hasWorkspaces: Bool) {
        if hasKnownMembership != hasWorkspaces {
            defaults.set(hasWorkspaces, forKey: Self.membershipDefaultsKey)
        }
        guard !RuntimeEnvironment.isUnderTests else { return }
        reconcileStream()
    }

    /// What the stream should do given the current gates. Pure so the lazy
    /// start/stop/probe policy is unit-testable without a connection.
    enum StreamDecision: Equatable, Sendable {
        /// Run (or keep running) the `/workspaces/sync` stream.
        case stream
        /// Tear the stream down (or keep it down) and do nothing else.
        case stop
        /// Stream down; issue the one-per-launch `GET /workspaces` probe.
        case probe
    }

    nonisolated static func streamDecision(
        wanted: Bool,
        routerEnabled: Bool,
        hasKnownMembership: Bool,
        alreadyProbed: Bool,
        hasIdentity: Bool
    ) -> StreamDecision {
        guard wanted, routerEnabled else { return .stop }
        if hasKnownMembership { return .stream }
        return (!alreadyProbed && hasIdentity) ? .probe : .stop
    }

    private func reconcileStream() {
        switch Self.streamDecision(
            wanted: wanted,
            routerEnabled: OsaurusRouter.isEnabled,
            hasKnownMembership: hasKnownMembership,
            alreadyProbed: probedMembership,
            hasIdentity: MasterKey.existsCached()
        ) {
        case .stream:
            startStream()
        case .stop:
            stopStream()
        case .probe:
            stopStream()
            probedMembership = true
            // One `GET /workspaces` through the roster store (which also
            // seeds the sidebar); its `apply` reports membership back here.
            Task { await WorkspaceRosterStore.shared.refresh(reason: .launch) }
        }
    }

    private func startStream() {
        guard task == nil else { return }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                WorkspaceRosterStore.shared.expireVerification()
                let alive =
                    self.isVerified
                    ? Self.verificationIsFresh(lastFrameAt: self.lastFrameAt)
                    : Self.connectionIsPending(startedAt: self.connectionStartedAt)
                if !alive || !OsaurusRouter.isEnabled {
                    self.invalidateVerification()
                    self.connectionTask?.cancel()
                }
            }
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                var delay: TimeInterval = 1
                if OsaurusRouter.isEnabled, MasterKey.existsCached() {
                    self.revision = 0
                    self.snapshot = nil
                    let generation = UUID()
                    self.streamGeneration = generation
                    self.connectionStartedAt = Date()
                    let client = self.client
                    let connection = Task { [weak self] in
                        do {
                            try await client.observeWorkspaceSync { [weak self] frame in
                                await self?.receive(frame, generation: generation)
                            }
                        } catch { /* state below explains the unavailable connection */  }
                    }
                    self.connectionTask = connection
                    await connection.value
                    self.connectionTask = nil
                    // Routine signed-subscription renewal must not cancel a
                    // healthy run. Only a received frame renews the lease;
                    // failed reconnect attempts cannot extend it.
                    if !Self.verificationIsFresh(lastFrameAt: self.lastFrameAt) {
                        self.invalidateVerification()
                    }
                    // Older routers and connection failures retain
                    // discoverability with bounded, backing-off polling that
                    // never masquerades as a live feed. The reconnect itself
                    // backs off the same way: a connection that produced no
                    // frame is not retried every second.
                    if !self.isVerified {
                        if Date().timeIntervalSince(self.lastFallback) >= self.fallbackDelay {
                            self.lastFallback = Date()
                            await WorkspaceRosterStore.shared.refresh(reason: .manual)
                            await WorkspacesService.shared.refreshSelectedWorkspace()
                            self.fallbackDelay = Self.nextFallbackDelay(after: self.fallbackDelay)
                        }
                        if self.connectionProducedNoFrame(since: self.connectionStartedAt) {
                            delay = self.fallbackDelay
                        }
                    }
                } else {
                    self.invalidateVerification()
                }
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func connectionProducedNoFrame(since startedAt: Date) -> Bool {
        lastFrameAt < startedAt
    }

    private func stopStream() {
        guard task != nil || watchdog != nil else { return }
        watchdog?.cancel()
        watchdog = nil
        connectionTask?.cancel()
        connectionTask = nil
        task?.cancel()
        task = nil
        invalidateVerification()
        fallbackDelay = Self.fallbackInitialDelay
    }

    private func receive(_ frame: WorkspaceSyncFrame, generation: UUID) async {
        guard !Task.isCancelled, generation == streamGeneration, OsaurusRouter.isEnabled else { return }
        if frame.type == "snapshot", let snapshot = frame.snapshot, frame.revision > revision {
            revision = frame.revision
            self.snapshot = snapshot
            WorkspaceAgentConnectService.shared.reconcileMembership(snapshot)
            WorkspacesService.shared.applySyncSnapshot(snapshot)
            WorkspaceRosterStore.shared.apply(
                rosters: snapshot.workspaces.map {
                    .init(workspace: $0.workspace, agents: $0.agents)
                }
            )
            await WorkspaceAgentAccessHost.shared.reconcile(snapshot: snapshot)
            guard !Task.isCancelled, generation == streamGeneration, OsaurusRouter.isEnabled else { return }
            for remote in RemoteAgentManager.shared.remoteAgents {
                guard let id = remote.workspaceId else { continue }
                if snapshot.workspaces.first(where: { $0.workspace.id == id })?.agents.contains(where: {
                    $0.agentAddress.lowercased() == remote.agentAddress.lowercased()
                }) != true {
                    _ = RemoteAgentManager.shared.remove(id: remote.id)
                }
            }
            // The last workspace is gone: `apply` above cleared the
            // membership flag and `noteMembership` stopped this stream. Do
            // not renew a lease on a stream that is being torn down.
            guard task != nil else { return }
        } else if frame.type != "verified" || frame.revision != revision || snapshot == nil {
            return
        }
        lastFrameAt = Date()
        isVerified = true
        fallbackDelay = Self.fallbackInitialDelay
        WorkspaceRosterStore.shared.renewVerification()
        for entry in snapshot?.workspaces ?? [] where workers[entry.workspace.id] == nil {
            let id = entry.workspace.id
            workers[id] = Task { [weak self] in
                await WorkspaceAgentConnectService.shared.autoConnect(workspaceId: id, agents: entry.agents)
                self?.workers[id] = nil
            }
        }
    }

    private func invalidateVerification() {
        guard isVerified else { return }
        isVerified = false
        WorkspaceRosterStore.shared.invalidateVerification()
        InboundSharedRunBridge.shared.stopWorkspaceRuns()
    }
}
