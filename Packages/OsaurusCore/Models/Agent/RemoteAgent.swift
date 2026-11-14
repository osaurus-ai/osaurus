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

    /// Mascot avatar id (e.g. "green") refreshed from the remote agent's live
    /// metadata on connect, so the receiver can render the agent's own avatar.
    /// nil = no mascot (fall back to the name's initial monogram). Custom
    /// uploaded images are never transferred. Optional for back-compat decode.
    public var avatar: String?

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
    /// The model the agent runs on its owner's Mac, as reported by the host
    /// during the Workspaces handshake (e.g. `anthropic/claude-sonnet-4-5`
    /// or a local bundle id). Informational; refreshed with the access key.
    /// Absent for pairings made through other paths or older hosts.
    public var model: String?
    /// The workspace this pairing was minted through, when the agent reached
    /// us via a Workspaces roster rather than a direct share link. Lets the
    /// sidebar, Agents tab, and Remove flow know the pairing is workspace-
    /// managed without waiting for a roster fetch. nil = shared directly.
    /// Backfilled from the roster for pairings that predate this field.
    public var workspaceId: String?
    /// Set when the owner's Osaurus refused this pairing's access key (the
    /// guest link was revoked). Cleared by the next successful connect.
    /// Only meaningful for direct shares; workspace pairings re-pair.
    public var accessRevokedAt: Date?

    public init(
        id: UUID = UUID(),
        agentAddress: String,
        name: String,
        description: String,
        avatar: String? = nil,
        relayBaseURL: String,
        providerId: UUID,
        pairedAt: Date = Date(),
        lastUsedAt: Date? = nil,
        note: String? = nil,
        model: String? = nil,
        workspaceId: String? = nil
    ) {
        self.id = id
        self.agentAddress = agentAddress
        self.name = name
        self.description = description
        self.avatar = avatar
        self.relayBaseURL = relayBaseURL
        self.providerId = providerId
        self.pairedAt = pairedAt
        self.lastUsedAt = lastUsedAt
        self.note = note
        self.model = model
        self.workspaceId = workspaceId
    }

    /// True when this pairing is managed by a workspace roster (auto-connect
    /// re-pairs it while the agent stays shared), false for direct shares.
    public var isWorkspaceManaged: Bool {
        guard let workspaceId else { return false }
        return !workspaceId.isEmpty
    }
}

// MARK: - Display Helpers

extension RemoteAgent {
    /// Short model label for badges: the last path component of a
    /// `provider/model` id, so `anthropic/claude-sonnet-4-5` reads as
    /// `claude-sonnet-4-5` and a bare local id passes through.
    public static func shortModelLabel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slash = trimmed.lastIndex(of: "/"), slash < trimmed.index(before: trimmed.endIndex)
        else { return trimmed }
        return String(trimmed[trimmed.index(after: slash)...])
    }

    /// Truncated address for compact UI: `0xABCD…F291`.
    public var shortAddress: String {
        let raw = agentAddress
        guard raw.count > 12 else { return raw }
        let prefix = raw.prefix(6)
        let suffix = raw.suffix(4)
        return "\(prefix)…\(suffix)"
    }
}

// MARK: - PairedRelayAgent

/// A remote Osaurus agent that is persistently paired and reachable via the relay tunnel.
public struct PairedRelayAgent: Identifiable, Equatable, Sendable {
    /// The UUID of the agent on the remote Osaurus server.
    public let id: UUID
    /// Display name of the remote agent.
    public let name: String
    /// The crypto address (e.g. "0x...") used to construct the relay tunnel URL.
    public let remoteAgentAddress: String
    /// The local provider ID used to connect to this agent.
    public let providerId: UUID
    /// Mascot avatar id (e.g. "green") from the persisted `RemoteAgent` record
    /// (refreshed from the agent's live metadata on connect), so the picker can
    /// render the agent's own avatar instead of a generic glyph. nil = monogram
    /// fallback on the name (e.g. a paired agent that hasn't connected yet).
    public let avatar: String?

    public init(
        id: UUID,
        name: String,
        remoteAgentAddress: String,
        providerId: UUID,
        avatar: String? = nil
    ) {
        self.id = id
        self.name = name
        self.remoteAgentAddress = remoteAgentAddress
        self.providerId = providerId
        self.avatar = avatar
    }
}
