//
//  WorkspaceAgentRunClient.swift
//  osaurus
//
//  Headless counterpart of what the chat window does before it can talk to a
//  teammate's shared agent (`ChatView.connectToRelayAgent` +
//  `pinRemoteAgentModelAfterConnect` + `ChatWindowState
//  .repairWorkspacePairingAfterRejection`), for callers with no window:
//  the spawn tools, schedules, watchers and channel routes.
//
//  `prepare` turns a durable `WorkspaceAgentRef` into a connected
//  `RemoteProvider` whose agent has just answered a liveness probe — or a
//  typed refusal. It never registers a run, never touches the composed
//  prompt, and never sets a model (the host owns that).
//

import Foundation

enum WorkspaceAgentRunError: Error, Equatable, Sendable {
    /// Osaurus Router is turned off in Settings.
    case routerDisabled
    /// No local identity (master key) to sign the handshake with.
    case noIdentity
    /// The ref is not on any roster the user belongs to any more.
    case notShared
    /// One of THIS instance's own agents — run it locally instead.
    case ownAgent
    /// The relay has no tunnel for the host.
    case offline(lastSeen: Date?)
    /// The relay itself could not be reached from this Mac.
    case hostUnreachable(String)
    /// The workspace handshake failed (attestation, challenge, HPKE).
    case pairingFailed(String)
    /// The provider could not be connected after the agent answered.
    case connectFailed(String)
    /// The agent answered but refused our key twice (repair did not help).
    case rejected
    /// The agent no longer exists on its owner's Mac.
    case agentMissing
    case other(String)

    /// Human copy shared by the tool result, the Activity row and the audit
    /// trail. `agentName` is the roster/pairing display name.
    func message(agentName: String, now: Date = Date()) -> String {
        switch self {
        case .routerDisabled:
            return L("Osaurus Router is turned off, so \(agentName) (a workspace agent) can't be reached. Turn it on in Settings → Osaurus Router.")
        case .noIdentity:
            return L("This Mac has no Osaurus identity yet, so it can't sign in to the workspace to reach \(agentName).")
        case .notShared:
            return L("\(agentName) is no longer shared with a workspace you belong to.")
        case .ownAgent:
            return L("\(agentName) is one of this Mac's own agents; run it locally instead of through the workspace.")
        case .offline(let lastSeen):
            return WorkspaceAgentLiveness.message(for: .offline, agentName: agentName, lastSeen: lastSeen, now: now)
        case .hostUnreachable(let why):
            return WorkspaceAgentLiveness.message(for: .unreachable(why), agentName: agentName, lastSeen: nil, now: now)
        case .pairingFailed(let why):
            return L("Couldn't connect to \(agentName) through the workspace: \(why)")
        case .connectFailed(let why):
            return L("\(agentName) is online but the connection failed: \(why)")
        case .rejected:
            return WorkspaceAgentLiveness.message(for: .rejected, agentName: agentName, lastSeen: nil, now: now)
        case .agentMissing:
            return WorkspaceAgentLiveness.message(for: .notFound, agentName: agentName, lastSeen: nil, now: now)
        case .other(let why):
            return L("\(agentName) couldn't be reached: \(why)")
        }
    }

    /// Short machine token for audit rows.
    var auditReason: String {
        switch self {
        case .routerDisabled: return "router_disabled"
        case .noIdentity: return "no_identity"
        case .notShared: return "not_shared"
        case .ownAgent: return "own_agent"
        case .offline: return "offline"
        case .hostUnreachable: return "relay_unreachable"
        case .pairingFailed: return "pairing_failed"
        case .connectFailed: return "connect_failed"
        case .rejected: return "rejected"
        case .agentMissing: return "agent_missing"
        case .other: return "error"
        }
    }
}

@MainActor
final class WorkspaceAgentRunClient {
    static let shared = WorkspaceAgentRunClient()

    /// Everything a headless run needs to bind Mode 2 on a `ChatSession`.
    struct Prepared: Sendable, Equatable {
        let ref: WorkspaceAgentRef
        let providerId: UUID
        /// Roster / pairing display name (the sharer's chosen label).
        let displayName: String
        /// The model the host reports it will run, for Insights attribution.
        /// Never sent on the wire.
        let effectiveModel: String?
        let workspaceName: String?
    }

    // MARK: - Seams (tests)

    var routerEnabled: () -> Bool = { OsaurusRouter.isEnabled }
    var identityExists: () -> Bool = { MasterKey.existsCached() }
    var pairedAgent: (WorkspaceAgentRef) -> RemoteAgent? = { ref in
        RemoteAgentManager.shared.remoteAgent(forAddress: ref.agentAddress, workspaceId: ref.workspaceId)
    }
    var pair: (WorkspaceAgentRef, String?) async -> RemoteAgent? = { ref, name in
        await WorkspaceAgentConnectService.shared.connect(
            workspaceId: ref.workspaceId,
            agentAddress: ref.agentAddress,
            displayName: name,
            silent: true
        )
    }
    var pairFailure: (WorkspaceAgentRef) -> String? = { ref in
        WorkspaceAgentConnectService.shared.connectFailure(for: ref.agentAddress, workspaceId: ref.workspaceId)
    }
    var provider: (UUID) -> RemoteProvider? = { id in
        RemoteProviderManager.shared.configuration.provider(id: id)
    }
    var isProviderConnected: (UUID) -> Bool = { id in
        RemoteProviderManager.shared.providerStates[id]?.isConnected == true
    }
    var connectProvider: (UUID) async throws -> Void = { id in
        try await RemoteProviderManager.shared.connect(providerId: id)
    }
    var probe: @Sendable (RemoteProvider) async -> WorkspaceAgentLiveness.Verdict = { provider in
        await WorkspaceAgentLivenessCoalescer.shared.probe(provider: provider)
    }
    var rosterKnows: (WorkspaceAgentRef) -> Bool = { ref in
        WorkspaceRosterStore.shared.agent(forAddress: ref.agentAddress, workspaceId: ref.workspaceId) != nil
    }
    var isOwnAgent: (WorkspaceAgentRef) -> Bool = { ref in
        WorkspaceRosterStore.shared.isOwnAgent(address: ref.agentAddress)
    }
    var lastSeen: (WorkspaceAgentRef) -> Date? = { ref in
        WorkspaceRosterStore.shared.agent(forAddress: ref.agentAddress, workspaceId: ref.workspaceId)?.lastSeen
            .flatMap(WorkspaceRosterStore.parseLastSeen)
    }

    // MARK: - Prepare

    /// Resolve, pair if needed, probe liveness, connect the provider. Order
    /// matters: the probe runs BEFORE `RemoteProviderManager.connect` so an
    /// offline host is refused without churning provider state, and the
    /// probe's `.rejected` verdict gets exactly one pairing repair.
    func prepare(_ ref: WorkspaceAgentRef) async throws -> Prepared {
        guard routerEnabled() else { throw WorkspaceAgentRunError.routerDisabled }
        guard identityExists() else { throw WorkspaceAgentRunError.noIdentity }
        guard !isOwnAgent(ref) else { throw WorkspaceAgentRunError.ownAgent }

        let displayName = AgentTargetResolver.displayName(for: ref)
        let workspaceName = AgentTargetResolver.workspaceName(for: ref)

        // A pairing we already hold proves the agent WAS shared with us; the
        // roster is the fresher word when it has loaded. Refuse only when
        // neither knows the agent.
        var remote = pairedAgent(ref)
        if remote == nil {
            guard rosterKnows(ref) else { throw WorkspaceAgentRunError.notShared }
            remote = await pair(ref, displayName)
            guard remote != nil else {
                throw WorkspaceAgentRunError.pairingFailed(
                    pairFailure(ref) ?? L("the workspace handshake did not complete")
                )
            }
        }
        guard var paired = remote, var providerRecord = provider(paired.providerId) else {
            throw WorkspaceAgentRunError.other(L("the pairing has no provider record"))
        }

        var verdict = await probe(providerRecord)
        if verdict == .rejected {
            // A lapsed attestation is the common cause; one re-handshake
            // mints a fresh key (and possibly a fresh provider). Then ask
            // again — a second refusal is final.
            guard let repaired = await pair(ref, displayName),
                let repairedProvider = provider(repaired.providerId)
            else {
                throw WorkspaceAgentRunError.pairingFailed(
                    pairFailure(ref) ?? L("the workspace key was refused and could not be renewed")
                )
            }
            paired = repaired
            providerRecord = repairedProvider
            verdict = await probe(providerRecord)
        }

        let metadata: RemoteProviderService.RemoteAgentMetadata?
        switch verdict {
        case .live(let meta):
            metadata = meta
        case .offline:
            throw WorkspaceAgentRunError.offline(lastSeen: lastSeen(ref))
        case .unreachable(let why):
            throw WorkspaceAgentRunError.hostUnreachable(why)
        case .rejected:
            throw WorkspaceAgentRunError.rejected
        case .notFound:
            throw WorkspaceAgentRunError.agentMissing
        case .failed(let why):
            throw WorkspaceAgentRunError.other(why)
        }

        if !isProviderConnected(paired.providerId) {
            do {
                try await connectProvider(paired.providerId)
            } catch {
                throw WorkspaceAgentRunError.connectFailed(ChatErrorMessages.remoteConnectFailure(error))
            }
        }

        if let name = metadata?.name ?? metadata?.description, !name.isEmpty {
            RemoteAgentManager.shared.updateLiveMetadata(
                forAddress: ref.agentAddress,
                name: metadata?.name,
                description: metadata?.description,
                avatar: metadata?.avatar,
                providerId: paired.providerId
            )
        }
        if let model = metadata?.effectiveModel, !model.isEmpty, model != paired.model {
            RemoteAgentManager.shared.updateModel(model, forAddress: ref.agentAddress, workspaceId: ref.workspaceId)
        }

        return Prepared(
            ref: ref,
            providerId: paired.providerId,
            displayName: paired.name.isEmpty ? displayName : paired.name,
            effectiveModel: metadata?.effectiveModel ?? paired.model,
            workspaceName: workspaceName
        )
    }

    /// Map any thrown error (typed or not) to a user/model-facing sentence.
    static func message(for error: Error, agentName: String) -> String {
        if let typed = error as? WorkspaceAgentRunError {
            return typed.message(agentName: agentName)
        }
        return L("\(agentName) couldn't be reached: \(error.localizedDescription)")
    }
}
