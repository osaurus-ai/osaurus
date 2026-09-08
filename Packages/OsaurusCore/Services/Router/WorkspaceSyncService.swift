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
    var client: OsaurusRouterAPIClient = .shared

    nonisolated static func verificationIsFresh(lastFrameAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastFrameAt) < 3
    }

    func start() {
        guard task == nil, !RuntimeEnvironment.isUnderTests else { return }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                WorkspaceRosterStore.shared.expireVerification()
                let deadlineBase = self.isVerified ? self.lastFrameAt : self.connectionStartedAt
                if !Self.verificationIsFresh(lastFrameAt: deadlineBase) || !OsaurusRouter.isEnabled {
                    self.invalidateVerification()
                    self.connectionTask?.cancel()
                }
            }
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
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
                    // Older routers and connection failures retain discoverability
                    // with bounded polling. They never masquerade as a live feed.
                    if !self.isVerified, Date().timeIntervalSince(self.lastFallback) >= 10 {
                        self.lastFallback = Date()
                        await WorkspaceRosterStore.shared.refresh(reason: .manual)
                        await WorkspacesService.shared.refreshWorkspaces()
                        await WorkspacesService.shared.refreshSelectedWorkspace()
                    }
                } else {
                    self.invalidateVerification()
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
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
        } else if frame.type != "verified" || frame.revision != revision || snapshot == nil {
            return
        }
        lastFrameAt = Date()
        isVerified = true
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
