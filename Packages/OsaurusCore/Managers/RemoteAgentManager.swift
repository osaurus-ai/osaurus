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

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(invite)

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
        }
        guard let decoded = try? JSONDecoder().decode(PairInviteResponse.self, from: data) else {
            throw RemoteAgentPairError.malformedResponse
        }

        // If we already have a remote agent for this address, replace it
        // (deleting the old provider so its keychain entry is wiped).
        if let existing = remoteAgent(forAddress: decoded.agentAddress) {
            destroy(existing)
        }

        // Create a matching RemoteProvider so chat / model picker can reach it.
        let providerHost =
            relayHost(forAddress: decoded.agentAddress)
            ?? URL(string: decoded.relayBaseURL)?.host
            ?? decoded.relayBaseURL
        let provider = RemoteProvider(
            id: UUID(),
            name: decoded.agentName,
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
            remoteAgentAddress: decoded.agentAddress
        )
        RemoteProviderManager.shared.addProvider(provider, apiKey: decoded.apiKey)

        let remote = RemoteAgent(
            agentAddress: decoded.agentAddress,
            name: decoded.agentName,
            description: decoded.agentDescription ?? "",
            relayBaseURL: decoded.relayBaseURL,
            providerId: provider.id,
            note: note
        )
        RemoteAgentStore.save(remote)
        refresh()
        NotificationCenter.default.post(name: .remoteAgentsChanged, object: remote.id)
        return remote
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
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        do {
            return try await session.data(for: request)
        } catch {
            throw RemoteAgentPairError.networkFailed(error.localizedDescription)
        }
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
