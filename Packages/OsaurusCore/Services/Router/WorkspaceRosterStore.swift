//
//  WorkspaceRosterStore.swift
//  osaurus
//
//  App-wide, chat-facing view of every workspace the user belongs to and the
//  shared agents on each roster, with presence. `WorkspacesService` owns the
//  Settings surface (one selected workspace, members, invites, billing);
//  this store owns the cross-workspace roster the chat sidebar renders, so
//  a teammate's agent can be picked and chatted with — or seen offline —
//  without ever opening Settings.
//
//  The router has no push channel, so the roster (membership, shares, and
//  its relay-derived `online` flag) is polled: on launch, on app activation
//  (throttled), and on a 30 s tick while at least one chat window is open.
//  The relay itself is the live presence source: every Mode 2 request that
//  goes through `*.agent.osaurus.ai` answers `502 agent_offline` when the
//  host has no tunnel, and reaches the host otherwise. Those verdicts
//  (`OsaurusRelayPresenceSignal`) flip presence here immediately — offline
//  on a relay failure, online on any response from the host — so the
//  composer locks/unlocks without waiting on the tick.
//

import AppKit
import Combine
import Foundation

@MainActor
final class WorkspaceRosterStore: ObservableObject {
    static let shared = WorkspaceRosterStore()

    /// One sidebar section per workspace, in the router's order.
    struct WorkspaceRoster: Identifiable, Equatable {
        let workspace: OsaurusRouterWorkspaceSummary
        /// Shared agents on the roster (including the user's own).
        var agents: [OsaurusRouterWorkspaceAgent]
        var id: String { workspace.id }
    }

    enum Presence: Equatable {
        case online
        case offline(lastSeen: Date?)
        /// The relay couldn't be reached for this agent (`online == nil`),
        /// or the roster hasn't loaded yet.
        case unknown

        var isOnline: Bool { self == .online }
        var isOffline: Bool {
            if case .offline = self { return true }
            return false
        }
    }

    @Published private(set) var rosters: [WorkspaceRoster] = []
    /// True while the FIRST roster load is in flight (nothing to show yet).
    /// Later polls refresh in place and don't flip this, so a loaded sidebar
    /// never flickers back to a spinner.
    @Published private(set) var isLoading = false
    /// Why the last refresh couldn't reach the router, or nil. Set only when
    /// the workspace list itself fails; a single roster fetch failing keeps
    /// that workspace's previous agents (see `refresh`). Cleared on success.
    @Published private(set) var lastError: String?
    /// Last successful full refresh; nil until the first roster lands. Not
    /// published: a poll that changes nothing must not re-render observers.
    private(set) var lastRefreshedAt: Date?

    /// Addresses (lowercased) forced offline by a failed connect/send until
    /// the next poll that reports them online.
    @Published private(set) var forcedOffline: [String: Date] = [:]
    /// Address (lowercased) → last roster display name; survives unshare.
    private var verifiedAt: [String: Date] = [:]
    @Published private(set) var hostReachableAt: [String: Date] = [:]
    nonisolated static let verificationLifetime: TimeInterval = 35
    private var lastKnownNames: [String: String] = [:]

    /// Minimum spacing between activation-driven refreshes.
    nonisolated static let activationRefreshInterval: TimeInterval = 60
    /// Presence poll cadence while a chat window is observing.
    nonisolated static let presencePollInterval: TimeInterval = 30
    /// The relay's Redis agent-claim TTL (`AGENT_TTL_SECONDS`): how long the
    /// router can keep reporting a dead tunnel as online. A force-offline
    /// mark outlives router "online" polls for at least this long.
    nonisolated static let relayClaimTTL: TimeInterval = 20

    var client: OsaurusRouterAPIClient = .shared
    /// Injectable clock for tests.
    var now: () -> Date = { Date() }

    private var lastRefreshStarted: Date?
    private var stateGeneration = UUID()
    private var refreshInFlight = false
    private var pollTask: Task<Void, Never>?
    private var observerCount = 0
    private var activationObserver: NSObjectProtocol?
    private var remoteAgentsCancellable: AnyCancellable?
    private var routerEnabledCancellable: AnyCancellable?

    init(client: OsaurusRouterAPIClient = .shared, observeAppActivation: Bool = true) {
        self.client = client
        if observeAppActivation {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.refresh(reason: .activation)
                }
            }
            // Turning Osaurus Router on/off in Settings should show or clear
            // the team sections right away, not on the next tick.
            routerEnabledCancellable = RemoteProviderManager.shared.$isOsaurusRouterEnabled
                .dropFirst()
                .removeDuplicates()
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in
                        await self?.refresh(reason: .manual)
                    }
                }
        }
    }

    // MARK: - Derived state

    /// True when there is anything for the chat sidebar to show.
    var hasWorkspaces: Bool { !rosters.isEmpty }

    /// Every shared agent across all workspaces, de-duplicated by address
    /// (an agent shared into two workspaces appears once, under the first).
    var allAgents: [OsaurusRouterWorkspaceAgent] {
        var seen = Set<String>()
        var out: [OsaurusRouterWorkspaceAgent] = []
        for roster in rosters {
            for agent in roster.agents where seen.insert(agent.agentAddress.lowercased()).inserted {
                out.append(agent)
            }
        }
        return out
    }

    func agent(forAddress address: String) -> OsaurusRouterWorkspaceAgent? {
        let lowered = address.lowercased()
        for roster in rosters {
            if let hit = roster.agents.first(where: { $0.agentAddress.lowercased() == lowered }) {
                return hit
            }
        }
        return nil
    }

    /// The roster entry for an agent within ONE workspace — the same agent
    /// can be shared into several under different display names.
    func agent(forAddress address: String, workspaceId: String) -> OsaurusRouterWorkspaceAgent? {
        let lowered = address.lowercased()
        return rosters.first { $0.workspace.id == workspaceId }?
            .agents.first { $0.agentAddress.lowercased() == lowered }
    }

    /// The workspace an agent (by address) is shared into; the first match
    /// when it's shared into several.
    func workspace(forAgentAddress address: String) -> OsaurusRouterWorkspaceSummary? {
        let lowered = address.lowercased()
        return rosters.first { roster in
            roster.agents.contains { $0.agentAddress.lowercased() == lowered }
        }?.workspace
    }

    /// Workspaces one of the user's own agents (by address) is shared into.
    func workspacesSharing(agentAddress address: String) -> [OsaurusRouterWorkspaceSummary] {
        let lowered = address.lowercased()
        return rosters.filter { roster in
            roster.agents.contains { $0.agentAddress.lowercased() == lowered }
        }.map(\.workspace)
    }

    /// Presence for a shared agent, folding in the local force-offline
    /// override from a failed connect/send.
    func presence(forAddress address: String, workspaceId: String? = nil) -> Presence {
        let lowered = address.lowercased()
        let scope = workspaceId ?? workspace(forAgentAddress: lowered)?.id
        guard let scope, let verified = verifiedAt[scope],
            now().timeIntervalSince(verified) < Self.verificationLifetime,
            let agent = agent(forAddress: lowered, workspaceId: scope) else { return .unknown }
        if forcedOffline[lowered] != nil {
            return .offline(lastSeen: Self.parseLastSeen(agent.lastSeen))
        }
        if let reached = hostReachableAt[lowered], now().timeIntervalSince(reached) < Self.verificationLifetime {
            return .online
        }
        return Self.presence(for: agent)
    }

    /// Whether `address` is one of THIS instance's agents (shared by the
    /// user), by matching the local agent's identity address.
    nonisolated static func isOwnAgent(address: String, localAgents: [Agent]) -> Bool {
        let lowered = address.lowercased()
        return localAgents.contains { $0.agentAddress?.lowercased() == lowered }
    }

    func isOwnAgent(address: String) -> Bool {
        Self.isOwnAgent(address: address, localAgents: AgentManager.shared.agents)
    }

    // MARK: - Pure presence mapping

    nonisolated static func presence(for agent: OsaurusRouterWorkspaceAgent) -> Presence {
        switch agent.online {
        case .some(true): return .online
        case .some(false): return .offline(lastSeen: parseLastSeen(agent.lastSeen))
        case .none: return .unknown
        }
    }

    nonisolated static func parseLastSeen(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    // MARK: - Force-offline override

    /// Mark an agent offline right now because its host didn't answer.
    /// Cleared by the next poll that reports it online.
    func noteHostUnreachable(agentAddress: String) {
        hostReachableAt.removeValue(forKey: agentAddress.lowercased())
        forcedOffline[agentAddress.lowercased()] = now()
    }

    /// Clear a force-offline mark (e.g. a successful send).
    func noteHostReachable(agentAddress: String) {
        forcedOffline.removeValue(forKey: agentAddress.lowercased())
        hostReachableAt[agentAddress.lowercased()] = now()
    }

    /// Whether a connect/send error means the sharer's Osaurus is not
    /// reachable through the relay (as opposed to an auth/roster verdict).
    nonisolated static func indicatesHostUnreachable(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                .notConnectedToInternet, .dnsLookupFailed, .secureConnectionFailed:
                return true
            default:
                return false
            }
        }
        let text = error.localizedDescription.lowercased()
        return text.contains("502") || text.contains("503") || text.contains("504")
            || text.contains("bad gateway") || text.contains("agent offline")
            || text.contains("not connected") || text.contains("tunnel")
            || text.contains("unreachable") || text.contains("timed out")
    }

    // MARK: - Refresh

    enum RefreshReason { case launch, activation, poll, manual }

    /// Reload every workspace roster. Throttled for `.activation`; every
    /// other reason runs unless a refresh is already in flight.
    func refresh(reason: RefreshReason = .manual) async {
        guard OsaurusRouter.isEnabled, MasterKey.existsCached() else {
            if !rosters.isEmpty { rosters = [] }
            if lastError != nil { lastError = nil }
            return
        }
        guard !refreshInFlight else { return }
        if reason == .activation, let last = lastRefreshStarted,
            now().timeIntervalSince(last) < Self.activationRefreshInterval
        {
            return
        }
        let generation = stateGeneration
        refreshInFlight = true
        if rosters.isEmpty, lastRefreshedAt == nil { isLoading = true }
        defer {
            refreshInFlight = false
            isLoading = false
        }
        lastRefreshStarted = now()

        let workspaces: [OsaurusRouterWorkspaceSummary]
        do {
            workspaces = try await client.listWorkspaces()
        } catch {
            // Keep whatever we had; the sidebar shows the error with Retry
            // instead of pretending the user has no workspaces.
            verifiedAt.removeAll()
            objectWillChange.send()
            lastError = Self.refreshFailureMessage(for: error)
            return
        }
        let previous = rosters
        var verified = Set<String>()
        let next = await Self.buildRosters(workspaces: workspaces, previous: previous) { [client] id in
            let agents = try await client.workspaceAgents(id: id)
            verified.insert(id)
            return agents
        }
        guard generation == stateGeneration else { return }
        if lastError != nil { lastError = nil }
        apply(rosters: next, verifiedWorkspaceIds: verified)

        // Keep the pairing side in step: any teammate agent not yet paired
        // gets the background handshake, so a row that just appeared is
        // chat-ready by the time the user clicks it.
        for roster in next {
            await WorkspaceAgentConnectService.shared.autoConnect(
                workspaceId: roster.workspace.id, agents: roster.agents
            )
        }
    }

    /// Fetch every workspace's agent list. A transient per-workspace fetch
    /// failure must not read as "no shared agents yet": the workspace keeps
    /// its last known list (empty only if we never had one). Static with an
    /// injected fetch so the rule is unit-testable without the Router gate.
    static func buildRosters(
        workspaces: [OsaurusRouterWorkspaceSummary],
        previous: [WorkspaceRoster],
        fetch: (String) async throws -> [OsaurusRouterWorkspaceAgent]
    ) async -> [WorkspaceRoster] {
        var next: [WorkspaceRoster] = []
        for workspace in workspaces {
            let kept = previous.first { $0.id == workspace.id }?.agents
            let agents: [OsaurusRouterWorkspaceAgent]
            if let fetched = try? await fetch(workspace.id) {
                agents = fetched
            } else {
                agents = kept ?? []
            }
            next.append(WorkspaceRoster(workspace: workspace, agents: agents))
        }
        return next
    }

    /// Short, user-facing reason a roster refresh failed.
    nonisolated static func refreshFailureMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut,
                .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return L("Couldn't reach Osaurus Router. Check your connection.")
            default: break
            }
        }
        if case OsaurusRouterAPIError.server(_, let message, _) = error, !message.isEmpty {
            return message
        }
        return L("Couldn't load your workspaces.")
    }

    /// Install a freshly fetched roster set, clearing force-offline marks for
    /// agents the router now reports online.
    func apply(rosters next: [WorkspaceRoster], verifiedWorkspaceIds: Set<String>? = nil) {
        stateGeneration = UUID()
        hostReachableAt.removeAll()
        let verified = verifiedWorkspaceIds ?? Set(next.map(\.id))
        verifiedAt = Dictionary(uniqueKeysWithValues: verified.map { ($0, now()) })
        objectWillChange.send()
        let current = now()
        let connectService = WorkspaceAgentConnectService.shared
        var listed = Set<String>()
        for roster in next {
            for agent in roster.agents {
                let address = agent.agentAddress.lowercased()
                listed.insert(address)
                // Offline is the truer state than a stale handshake failure.
                if agent.online == false { connectService.clearFailure(for: address, workspaceId: roster.id) }
                // The router's `online` is derived from the relay's Redis
                // claim (TTL `relayClaimTTL`), so it can report a just-dead
                // host as online for up to that long. A relay verdict we saw
                // ourselves (502 agent_offline) is fresher; keep it until
                // the router's view can have caught up, or until a request
                // through the relay actually succeeds (`noteHostReachable`).
                if agent.online == true, let markedAt = forcedOffline[address],
                    (current.timeIntervalSince(markedAt) >= Self.relayClaimTTL
                        || self.agent(forAddress: address, workspaceId: roster.id)?.online == false)
                {
                    forcedOffline.removeValue(forKey: address)
                }
                if let name = agent.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !name.isEmpty
                {
                    lastKnownNames[agent.agentAddress.lowercased()] = name
                }
            }
        }
        // Failures for agents no longer on any roster (unshared, or the user
        // left) describe something that can't be retried; drop them.
        connectService.pruneFailures(keeping: listed)
        if next != rosters { rosters = next }
        lastRefreshedAt = now()
    }

    func renewVerification() {
        // The server has just verified its current snapshot; it supersedes
        // a successful response observed before this frame.
        hostReachableAt.removeAll()
        verifiedAt = Dictionary(uniqueKeysWithValues: rosters.map { ($0.id, now()) })
        objectWillChange.send()
    }

    func expireVerification() {
        let fresh = verifiedAt.filter { now().timeIntervalSince($0.value) < Self.verificationLifetime }
        if fresh.count != verifiedAt.count {
            verifiedAt = fresh
            objectWillChange.send()
        }
    }

    func invalidateVerification() {
        verifiedAt.removeAll()
        objectWillChange.send()
    }

    /// Display name last seen on any roster for an address, so a tab whose
    /// agent was since unshared can still be named in notices and history.
    func lastKnownName(forAddress address: String) -> String? {
        lastKnownNames[address.lowercased()]
    }

    /// Replace one workspace's agent list from a fetch another surface just
    /// made (Settings ▸ Workspaces share / unshare / detail load), so the
    /// chat sidebar reflects the change immediately instead of on the next
    /// poll. Unknown workspace ids are ignored — `refresh` picks those up.
    func update(workspaceId: String, agents: [OsaurusRouterWorkspaceAgent]) {
        guard let index = rosters.firstIndex(where: { $0.id == workspaceId }) else { return }
        let previousVerification = verifiedAt
        var next = rosters
        next[index].agents = agents
        apply(rosters: next, verifiedWorkspaceIds: [workspaceId])
        for (id, time) in previousVerification where id != workspaceId { verifiedAt[id] = time }
    }

    /// Back to the never-loaded state (rosters empty, no `lastRefreshedAt`,
    /// no force-offline marks). Tests only.
    func resetForTesting() {
        rosters = []
        verifiedAt = [:]
        hostReachableAt = [:]
        forcedOffline = [:]
        lastKnownNames = [:]
        lastRefreshedAt = nil
        lastRefreshStarted = nil
        lastError = nil
        isLoading = false
    }

    // MARK: - Presence polling

    /// Chat windows hold this lease for their lifetime (`ChatWindowState`
    /// init → `cleanup`). The poll runs while at least one observer is
    /// registered.
    func beginObserving() {
        observerCount += 1
        WorkspaceSyncService.shared.start()
    }

    func endObserving() {
        observerCount = max(0, observerCount - 1)
        if observerCount == 0 { stopPolling() }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.refresh(reason: .launch)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.presencePollInterval))
                guard !Task.isCancelled else { return }
                await self?.refresh(reason: .poll)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
