//
//  RemoteAgent.swift
//  osaurus
//
//  Persistent record of an agent that lives on someone ELSE's Osaurus
//  instance, paired to this device via a `osaurus://...?pair=...` deeplink.
//
//  The matching `osk-v1` access key is held by `RemoteProviderKeychain`
//  alongside the auto-created `RemoteProvider` entry — see
//  `RemoteAgentManager.add(...)`.
//

import Foundation

public struct RemoteAgent: Codable, Identifiable, Sendable, Equatable {
    /// Local identifier — distinct from the source agent's UUID, which we
    /// don't reliably know (the deeplink only carries the crypto address).
    public let id: UUID

    /// Source agent's checksummed address (the `0x...` from the deeplink).
    public var agentAddress: String

    /// Display name at pairing time. The remote owner may rename their agent
    /// later; we don't try to track that — local label sticks until the user
    /// rebuilds the pairing.
    public var name: String

    /// Optional description from the invite at pairing time.
    public var description: String

    /// Relay tunnel base URL the receiver uses to reach the agent.
    /// E.g. `https://0xabc....agent.osaurus.ai`.
    public var relayBaseURL: String

    /// Matching `RemoteProvider` ID — the access key + connection live there.
    /// Always non-nil once persisted; callers can join with
    /// `RemoteProviderConfiguration.provider(id:)`.
    public var providerId: UUID

    public var pairedAt: Date
    public var lastUsedAt: Date?
    /// User-supplied note (e.g. "Alice's research agent"). Optional.
    public var note: String?

    public init(
        id: UUID = UUID(),
        agentAddress: String,
        name: String,
        description: String,
        relayBaseURL: String,
        providerId: UUID,
        pairedAt: Date = Date(),
        lastUsedAt: Date? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.agentAddress = agentAddress
        self.name = name
        self.description = description
        self.relayBaseURL = relayBaseURL
        self.providerId = providerId
        self.pairedAt = pairedAt
        self.lastUsedAt = lastUsedAt
        self.note = note
    }
}

// MARK: - Display Helpers

extension RemoteAgent {
    /// Truncated address for compact UI: `0xABCD…F291`.
    public var shortAddress: String {
        let raw = agentAddress
        guard raw.count > 12 else { return raw }
        let prefix = raw.prefix(6)
        let suffix = raw.suffix(4)
        return "\(prefix)…\(suffix)"
    }
}
