//
//  NewAgentHighlightStore.swift
//  osaurus
//
//  "This agent is new" state for the chat sidebar. An agent that appears
//  after the app (well, this store) first saw the agent list — created in
//  Settings or onboarding, applied from a config, imported from a bundle,
//  restored from a backup, shared by a teammate onto a workspace roster,
//  or paired through an invite link — is highlighted in the sidebar until
//  the user opens it once. Nothing is persisted: on the next launch every
//  agent is simply an existing agent again.
//
//  Detection is diff-based rather than hooked into each creation path so a
//  new path (or a path that skips `.agentAdded`) can't forget to flag.
//

import Combine
import Foundation

/// Pure "what appeared since the baseline" bookkeeping, shared by the
/// three agent sources. The first observation establishes the baseline
/// (those keys are not new); every key that shows up later is new until
/// marked seen.
struct NewItemTracker<Key: Hashable> {
    private(set) var known: Set<Key>?
    private(set) var newKeys: Set<Key> = []

    /// Fold in the current full key set.
    ///
    /// - Parameter treatAllAsNew: when the baseline is not yet established,
    ///   `true` means an earlier (unobserved) load already happened, so
    ///   this emission is a change on top of an empty baseline rather than
    ///   the baseline itself.
    mutating func observe(_ keys: Set<Key>, treatAllAsNew: Bool = false) {
        guard let baseline = known else {
            known = treatAllAsNew ? [] : keys
            if treatAllAsNew { newKeys = keys }
            return
        }
        let appeared = keys.subtracting(baseline)
        newKeys.formUnion(appeared)
        // Something removed can't be new any more; if it comes back with
        // the same key it is a reappearance, not a creation.
        newKeys.formIntersection(keys)
        known = baseline.union(keys)
    }

    mutating func markSeen(_ key: Key) {
        newKeys.remove(key)
    }
}

@MainActor
final class NewAgentHighlightStore: ObservableObject {
    static let shared = NewAgentHighlightStore()

    /// Local agents (`AgentManager.agents`) that appeared after baseline.
    @Published private(set) var newLocalAgentIds: Set<UUID> = []
    /// Shared agents by lowercased address: teammates' agents that appeared
    /// on a workspace roster, plus directly shared (invite-link) pairings.
    @Published private(set) var newSharedAgentAddresses: Set<String> = []

    private var localTracker = NewItemTracker<UUID>()
    private var rosterTracker = NewItemTracker<String>()
    private var remoteTracker = NewItemTracker<String>()
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        // `$agents` replays the current list on subscription: that first
        // value is the baseline.
        AgentManager.shared.$agents
            .sink { [weak self] agents in
                self?.observeLocalAgents(Set(agents.map(\.id)))
            }
            .store(in: &cancellables)

        // `$remoteAgents` is loaded synchronously in the manager's init, so
        // its replayed first value is a complete baseline too. Only direct
        // (invite-link) shares count here: workspace-managed pairings are
        // created by roster auto-connect, possibly long after the agent
        // itself appeared on the roster, and the roster tracker owns those.
        RemoteAgentManager.shared.$remoteAgents
            .sink { [weak self] remotes in
                self?.observeRemoteAgents(
                    Set(remotes.filter { !$0.isWorkspaceManaged }.map { $0.agentAddress.lowercased() })
                )
            }
            .store(in: &cancellables)

        // Rosters load asynchronously. The replayed first value is the
        // pre-load `[]`, so skip it; the next emission is the first real
        // roster. `@Published` emits before assignment, so on that first
        // load `lastRefreshedAt` is still nil. When it is already set the
        // first load happened without an emission (an empty roster),
        // meaning this emission is a change, not the baseline.
        let rosterStore = WorkspaceRosterStore.shared
        rosterStore.$rosters
            .dropFirst()
            .sink { [weak self, weak rosterStore] rosters in
                let addresses = Set(
                    rosters.flatMap { $0.agents.map { $0.agentAddress.lowercased() } }
                )
                self?.observeRosterAgents(
                    addresses,
                    firstLoadAlreadyHappened: rosterStore?.lastRefreshedAt != nil
                )
            }
            .store(in: &cancellables)
    }

    /// Test seam: a store with no live subscriptions.
    init(detached: Void) {}

    // MARK: - Observation (also the test seams)

    func observeLocalAgents(_ ids: Set<UUID>) {
        localTracker.observe(ids)
        publishLocal()
    }

    func observeRemoteAgents(_ addresses: Set<String>) {
        remoteTracker.observe(addresses)
        publishShared()
    }

    func observeRosterAgents(_ addresses: Set<String>, firstLoadAlreadyHappened: Bool) {
        rosterTracker.observe(addresses, treatAllAsNew: firstLoadAlreadyHappened)
        publishShared()
    }

    // MARK: - Queries

    func isNew(localAgentId id: UUID) -> Bool {
        newLocalAgentIds.contains(id)
    }

    func isNew(sharedAgentAddress address: String) -> Bool {
        newSharedAgentAddresses.contains(address.lowercased())
    }

    // MARK: - Seen

    func markSeen(localAgentId id: UUID) {
        guard newLocalAgentIds.contains(id) else { return }
        localTracker.markSeen(id)
        publishLocal()
    }

    func markSeen(sharedAgentAddress address: String) {
        let key = address.lowercased()
        guard newSharedAgentAddresses.contains(key) else { return }
        rosterTracker.markSeen(key)
        remoteTracker.markSeen(key)
        publishShared()
    }

    // MARK: - Publish

    private func publishLocal() {
        let next = localTracker.newKeys
        if next != newLocalAgentIds { newLocalAgentIds = next }
    }

    private func publishShared() {
        let next = rosterTracker.newKeys.union(remoteTracker.newKeys)
        if next != newSharedAgentAddresses { newSharedAgentAddresses = next }
    }
}
