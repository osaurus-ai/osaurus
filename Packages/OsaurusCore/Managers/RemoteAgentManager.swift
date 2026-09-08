//
//  RemoteAgentManager.swift
//  osaurus
//
//  Owns the receiver-side state for agents paired via the share-deeplink
//  flow. Talks to `/pair-invite` over the relay, persists a `RemoteAgent`
//  per accepted invite, and creates the matching `RemoteProvider` so the
//  existing chat / model-picker plumbing can reach it.
//

import Combine
import Foundation

extension Foundation.Notification.Name {
    public static let remoteAgentsChanged = Foundation.Notification.Name("RemoteAgentsChanged")
}

public enum RemoteAgentPairError: LocalizedError {
    case relayURLMissing
    case malformedRelayURL(String)
    case networkFailed(String)
    case rejected(status: Int, message: String)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .relayURLMissing:
            return "The invite is missing a relay URL."
        case .malformedRelayURL(let url):
            return "The invite's relay URL is invalid: \(url)"
        case .networkFailed(let message):
            return "Could not reach the agent's server: \(message)"
        case .rejected(_, let message):
            return message
        case .malformedResponse:
            return "The agent's server returned an unexpected response."
        }
    }
}

@MainActor
public final class RemoteAgentManager: ObservableObject {
    public static let shared = RemoteAgentManager()

    @Published public private(set) var remoteAgents: [RemoteAgent] = []

    private init() {
        refresh()
    }

    public func refresh() {
        remoteAgents = RemoteAgentStore.loadAll()
    }

    public func remoteAgent(for id: UUID) -> RemoteAgent? {
        remoteAgents.first { $0.id == id }
    }

    /// Find an existing remote agent that already pairs with this address, if
    /// any. Used by the incoming-pair sheet to surface a "you're already paired
    /// with this agent — overwrite?" affordance.
    public func remoteAgent(forAddress address: String) -> RemoteAgent? {
        let lower = address.lowercased()
        return remoteAgents.first { $0.agentAddress.lowercased() == lower }
    }

    /// Workspace membership is part of a pairing's identity. nil is a direct
    /// invite, and must never resolve a workspace credential for this address.
    public func remoteAgent(forAddress address: String, workspaceId: String?) -> RemoteAgent? {
        remoteAgents.first { $0.agentAddress.lowercased() == address.lowercased() && $0.workspaceId == workspaceId }
    }

    /// Find the paired remote agent backed by a given `RemoteProvider` id.
    public func remoteAgent(forProviderId providerId: UUID) -> RemoteAgent? {
        remoteAgents.first { $0.providerId == providerId }
    }

    /// Resolve the paired `RemoteAgent` id for a remote provider so chat
    /// surfaces (the toolbar settings gear) can deep-link into
    /// `RemoteAgentDetailView`. Matches on the backing provider id first, then
    /// falls back to the provider's configured remote-agent address so
    /// relay-paired agents (whose provider was minted separately) resolve too.
    /// Returns `nil` for ephemeral Bonjour peers with no stored record.
    public func remoteAgentDetailId(forProviderId providerId: UUID) -> UUID? {
        if let direct = remoteAgent(forProviderId: providerId)?.id { return direct }
        if let provider = RemoteProviderManager.shared.configuration.providers
            .first(where: { $0.id == providerId }),
            let address = provider.remoteAgentAddress, !address.isEmpty
        {
            return remoteAgent(forAddress: address)?.id
        }
        return nil
    }

    /// Refresh a paired remote agent's display metadata from its live
    /// `GET /agents/{id}` response (called on connect). The name captured at
    /// pair time can go stale if the owner renames their agent, and avatars
    /// were never captured at all — this keeps the local label/avatar honest.
    /// Empty name/description are ignored so a degraded response can't blank an
    /// existing label; only writes (and posts a change) when something actually
    /// differs. No-ops for addresses we don't have a `RemoteAgent` record for
    /// (e.g. ephemeral Bonjour peers) — the in-window pin still surfaces those.
    public func updateLiveMetadata(
        forAddress address: String,
        name: String?,
        description: String?,
        avatar: String?,
        providerId: UUID? = nil
    ) {
        guard var agent = providerId.flatMap({ remoteAgent(forProviderId: $0) }) ?? (providerId == nil ? remoteAgent(forAddress: address) : nil) else { return }
        var changed = false
        // Workspace pairings are named by the sharer's router display name
        // (what every teammate sees); the host's local agent name must not
        // overwrite it. Direct shares keep following the host's live name.
        if !agent.isWorkspaceManaged,
            let name = name?.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty, name != agent.name
        {
            agent.name = name
            changed = true
        }
        if let description = description?.trimmingCharacters(in: .whitespacesAndNewlines),
            description != agent.description
        {
            agent.description = description
            changed = true
        }
        if avatar != agent.avatar {
            agent.avatar = avatar
            changed = true
        }
        guard changed else { return }
        RemoteAgentStore.save(agent)
        refresh()
        NotificationCenter.default.post(name: .remoteAgentsChanged, object: agent.id)
    }

    // MARK: - Pair via Invite

    /// Decode `relayBaseURL` and POST the invite back. Returns the persisted
    /// `RemoteAgent` on success and updates `remoteAgents`. On failure the
    /// thrown error has a UX-grade message in `errorDescription`.
    @discardableResult
    public func pairAndAdd(
        invite: AgentInvite,
        note: String? = nil
    ) async throws -> RemoteAgent {
        guard !invite.url.isEmpty else { throw RemoteAgentPairError.relayURLMissing }
        guard let baseURL = URL(string: invite.url) else {
            throw RemoteAgentPairError.malformedRelayURL(invite.url)
        }
        let endpoint = baseURL.appendingPathComponent("pair-invite")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        // Ephemeral X25519 key for HPKE: a sealing-capable sender returns the
        // minted credential encrypted to this key so the relay operator (who
        // terminates TLS) can't read it. The invite signature still verifies
        // server-side from the canonical invite fields, which are unchanged.
        let (encPrivateKey, encPub) = PairingKeyEnvelope.generateRecipientKey()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let inviteJSON = try encoder.encode(invite)
        if var bodyObject = try JSONSerialization.jsonObject(with: inviteJSON) as? [String: Any] {
            bodyObject["encPub"] = encPub
            request.httpBody = try JSONSerialization.data(
                withJSONObject: bodyObject,
                options: [.sortedKeys]
            )
        } else {
            request.httpBody = inviteJSON
        }

        let (data, response) = try await postWithBackgroundSession(request)

        guard let http = response as? HTTPURLResponse else {
            throw RemoteAgentPairError.malformedResponse
        }
        guard http.statusCode == 200 else {
            let message = decodeErrorMessage(data) ?? "HTTP \(http.statusCode)"
            throw RemoteAgentPairError.rejected(status: http.statusCode, message: message)
        }

        struct PairInviteResponse: Decodable {
            let agentAddress: String
            let agentName: String
            let agentDescription: String?
            let relayBaseURL: String
            let apiKey: String
            let sealedApiKey: PairingKeyEnvelope.Sealed?
        }
        guard let decoded = try? JSONDecoder().decode(PairInviteResponse.self, from: data) else {
            throw RemoteAgentPairError.malformedResponse
        }

        // Prefer the HPKE-sealed credential. Fall back to plaintext only for
        // senders running an older Osaurus that ignored `encPub` — without a
        // signed channel binding for the receiver we can't reject plaintext
        // outright without breaking cross-version invites.
        let resolvedApiKey: String
        if let sealed = decoded.sealedApiKey {
            guard
                let opened = try? PairingKeyEnvelope.open(
                    sealed,
                    privateKey: encPrivateKey,
                    info: PairingKeyEnvelope.info(
                        agentAddress: decoded.agentAddress,
                        nonce: invite.nonce
                    )
                )
            else {
                throw RemoteAgentPairError.malformedResponse
            }
            resolvedApiKey = opened
        } else {
            resolvedApiKey = decoded.apiKey
        }
        guard !resolvedApiKey.isEmpty else { throw RemoteAgentPairError.malformedResponse }

        return upsertPairedAgent(
            agentAddress: decoded.agentAddress,
            name: decoded.agentName,
            description: decoded.agentDescription ?? "",
            relayBaseURL: decoded.relayBaseURL,
            apiKey: resolvedApiKey,
            note: note
        )
    }

    /// Persist a paired agent + its backing `RemoteProvider`, replacing any
    /// existing pairing for the same address. Shared by the invite-deeplink
    /// flow above and the Workspaces shared-agent connect flow — both end with the
    /// same artifact: a relay-reachable provider holding a minted access key.
    @discardableResult
    public func upsertPairedAgent(
        agentAddress: String,
        name: String,
        description: String,
        relayBaseURL: String,
        apiKey: String,
        note: String?,
        model: String? = nil,
        workspaceId: String? = nil
    ) -> RemoteAgent {
        // If we already have a remote agent for this address, replace it
        // (deleting the old provider so its keychain entry is wiped). Keep
        // the user's note and the last live avatar/workspace attribution so a
        // silent re-pair doesn't visibly reset the row.
        if var existing = remoteAgent(forAddress: agentAddress, workspaceId: workspaceId),
            updateAPIKey(apiKey, forAddress: agentAddress, workspaceId: workspaceId)
        {
            existing.name = name
            existing.description = description
            existing.relayBaseURL = relayBaseURL
            existing.model = model ?? existing.model
            if let note { existing.note = note }
            RemoteAgentStore.save(existing)
            refresh()
            NotificationCenter.default.post(name: .remoteAgentsChanged, object: existing.id)
            return existing
        }
        var carriedAvatar: String?
        var carriedNote = note
        let carriedWorkspaceId = workspaceId
        if let existing = remoteAgent(forAddress: agentAddress, workspaceId: workspaceId) {
            carriedAvatar = existing.avatar
            if carriedNote == nil { carriedNote = existing.note }
            destroy(existing)
        }

        // Also collapse any other provider already pointing at this agent's
        // crypto address (e.g. created by the LAN Bonjour pairing flow, which
        // mints its own provider with a different synthetic `remoteAgentId`).
        // Deduping on the address — the agent's stable identity — keeps one
        // provider per agent regardless of which pairing path created it.
        let addressLower = agentAddress.lowercased()
        let pairedProviderIds = Set(remoteAgents.map(\.providerId))
        let duplicateProviders = RemoteProviderManager.shared.configuration.providers.filter {
            workspaceId == nil && $0.remoteAgentAddress?.lowercased() == addressLower
                && !pairedProviderIds.contains($0.id)
        }
        for duplicate in duplicateProviders {
            RemoteProviderManager.shared.removeProvider(id: duplicate.id)
        }

        // Create a matching RemoteProvider so chat / model picker can reach it.
        let providerHost =
            relayHost(forAddress: agentAddress)
            ?? URL(string: relayBaseURL)?.host
            ?? relayBaseURL
        let provider = RemoteProvider(
            id: UUID(),
            name: name,
            host: providerHost,
            providerProtocol: .https,
            port: nil,
            basePath: "/v1",
            customHeaders: [:],
            authType: .apiKey,
            providerType: .osaurus,
            enabled: true,
            autoConnect: true,
            timeout: 60,
            secretHeaderKeys: [],
            // We don't know the source agent's UUID — the deeplink only
            // carries the crypto address. PairedRelayAgent uses its own
            // local UUID so this stays consistent across reloads.
            remoteAgentId: UUID(),
            remoteAgentAddress: agentAddress
        )
        RemoteProviderManager.shared.addProvider(provider, apiKey: apiKey)

        let remote = RemoteAgent(
            agentAddress: agentAddress,
            name: name,
            description: description,
            avatar: carriedAvatar,
            relayBaseURL: relayBaseURL,
            providerId: provider.id,
            note: carriedNote,
            model: model,
            workspaceId: carriedWorkspaceId
        )
        RemoteAgentStore.save(remote)
        refresh()
        NotificationCenter.default.post(name: .remoteAgentsChanged, object: remote.id)
        return remote
    }

    /// Attribute (or re-attribute) a pairing to a workspace. Used to backfill
    /// pairings made before `workspaceId` was recorded, from the roster that
    /// lists the address. No-op when unchanged or no pairing exists.
    public func updateWorkspaceId(_ workspaceId: String?, forAddress address: String) {
        guard var agent = remoteAgent(forAddress: address), agent.workspaceId != workspaceId else {
            return
        }
        agent.workspaceId = workspaceId
        RemoteAgentStore.save(agent)
        refresh()
        NotificationCenter.default.post(name: .remoteAgentsChanged, object: agent.id)
    }

    /// Record the model the host reported for a paired agent (Workspaces
    /// handshake/refresh). No-op when unchanged or no pairing exists.
    public func updateModel(_ model: String?, forAddress address: String, workspaceId: String? = nil) {
        guard var agent = remoteAgent(forAddress: address, workspaceId: workspaceId), agent.model != model else { return }
        agent.model = model
        RemoteAgentStore.save(agent)
        refresh()
        NotificationCenter.default.post(name: .remoteAgentsChanged, object: agent.id)
    }

    /// Rotate the access key of an existing pairing in place (Workspaces
    /// attestation refresh re-mints the key every few minutes; recreating the
    /// provider each time would churn its id under live chat sessions).
    /// Returns false when no pairing exists for the address.
    @discardableResult
    public func updateAPIKey(_ apiKey: String, forAddress address: String, workspaceId: String? = nil) -> Bool {
        guard let agent = remoteAgent(forAddress: address, workspaceId: workspaceId),
            let provider = RemoteProviderManager.shared.configuration.providers
                .first(where: { $0.id == agent.providerId })
        else { return false }
        RemoteProviderManager.shared.updateProvider(provider, apiKey: apiKey)
        return true
    }

    // MARK: - Mutate

    public func updateNote(_ note: String?, for id: UUID) {
        guard var agent = remoteAgent(for: id) else { return }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        agent.note = (trimmed?.isEmpty == false) ? trimmed : nil
        RemoteAgentStore.save(agent)
        refresh()
        NotificationCenter.default.post(name: .remoteAgentsChanged, object: id)
    }

    @discardableResult
    public func remove(id: UUID) -> Bool {
        guard let agent = remoteAgent(for: id) else { return false }
        // A workspace pairing has a live key-refresh loop; end it with the
        // pairing rather than letting it wake up against a deleted record.
        WorkspaceAgentConnectService.shared.stopRefreshing(agentAddress: agent.agentAddress,
            workspaceId: agent.workspaceId
        )
        destroy(agent)
        NotificationCenter.default.post(name: .remoteAgentsChanged, object: id)
        return true
    }

    /// Tear down a paired remote agent: kill its `RemoteProvider` (which also
    /// wipes the keychain entry), delete the local JSON, and refresh the
    /// in-memory list. Internal so callers don't accidentally skip one half.
    private func destroy(_ agent: RemoteAgent) {
        RemoteProviderManager.shared.removeProvider(id: agent.providerId)
        _ = RemoteAgentStore.delete(id: agent.id)
        refresh()
    }

    // MARK: - Networking helpers

    /// Use an ephemeral URLSession so the deeplink path never races shared
    /// connection state (cookies, persistent connections from other features).
    private func postWithBackgroundSession(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let session = Self.makePairInviteSession()
        defer { session.finishTasksAndInvalidate() }
        do {
            return try await session.data(for: request)
        } catch {
            throw RemoteAgentPairError.networkFailed(error.localizedDescription)
        }
    }

    nonisolated static func makePairInviteSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        return GlobalProxySettings.makeSession(base: cfg)
    }

    private func decodeErrorMessage(_ data: Data) -> String? {
        struct Err: Decodable { let error: String? }
        return (try? JSONDecoder().decode(Err.self, from: data))?.error
    }

    /// Build the relay-tunnel hostname that matches the chat path's expectation.
    private func relayHost(forAddress address: String) -> String? {
        guard !address.isEmpty else { return nil }
        return "\(address).agent.osaurus.ai"
    }
}
