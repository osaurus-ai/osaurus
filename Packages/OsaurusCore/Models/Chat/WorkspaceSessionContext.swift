//
//  WorkspaceSessionContext.swift
//  osaurus
//
//  Workspace identity stamped on a persisted chat session so history can be
//  keyed by the *team agent* a conversation is with, independent of the
//  local agent that hosted the tab.
//
//  Two sides write it:
//  - Teammate (client): a chat with a shared agent records
//    `{workspaceId, agentAddress}`; the sidebar lists these sessions under
//    the team agent's row instead of the local agent's.
//  - Host (sharer): a `/agents/{id}/run` served for a teammate records the
//    same plus `callerWallet` / `callerName`, so the host's History reads
//    "for @alice · Workspace" and the row is treated as read-only.
//

import Foundation

public struct WorkspaceSessionContext: Codable, Equatable, Sendable, Hashable {
    /// Router workspace id (`workspace_id` on the wire).
    public var workspaceId: String
    /// Lowercased checksummed address of the shared agent.
    public var agentAddress: String
    /// Stable grouping key for the caller — only set on the host side. The
    /// teammate's wallet for workspace callers; the access key's nonce for
    /// invite-link peers (see `callerAddress` for their verified wallet).
    public var callerWallet: String?
    /// Teammate display name at write time — only set on the host side.
    /// Decoration; `callerHandle` / the wallet identify.
    public var callerName: String?
    /// The caller's claimed Osaurus ID handle (no `@`) at write time.
    public var callerHandle: String?
    /// The caller's verified wallet when `callerWallet` is not one (invite
    /// peers: recorded from the redeem signature).
    public var callerAddress: String?
    /// Explicit caller kind when it is not implied by the workspace id
    /// (a remote agent, or the owner's own device).
    public var callerKind: ParticipantKind?
    /// For a remote-agent caller: its name, address, and owner's handle.
    public var callerAgentName: String?
    public var callerAgentAddress: String?
    public var callerAgentOwnerHandle: String?
    /// True when the remote agent's name or owner came from an unsigned
    /// (v1) declaration rather than the roster or a v2 signature.
    public var callerAgentIdentityUnverified: Bool?

    public init(
        workspaceId: String,
        agentAddress: String,
        callerWallet: String? = nil,
        callerName: String? = nil,
        callerHandle: String? = nil,
        callerAddress: String? = nil,
        callerKind: ParticipantKind? = nil,
        callerAgentName: String? = nil,
        callerAgentAddress: String? = nil,
        callerAgentOwnerHandle: String? = nil
    ) {
        self.workspaceId = workspaceId
        self.agentAddress = agentAddress.lowercased()
        self.callerWallet = callerWallet?.lowercased()
        self.callerName = callerName
        self.callerHandle = Participant.normalizedHandle(callerHandle)
        self.callerAddress = callerAddress?.lowercased()
        self.callerKind = callerKind
        self.callerAgentName = callerAgentName
        self.callerAgentAddress = callerAgentAddress?.lowercased()
        self.callerAgentOwnerHandle = Participant.normalizedHandle(callerAgentOwnerHandle)
    }

    /// True when the session was served by this instance for a teammate
    /// (host side); false for the teammate's own chats with a shared agent.
    public var isServedForTeammate: Bool { callerWallet != nil }

    /// True for an agent shared through an invite link rather than a
    /// workspace: the sidebar and host rows stamp an empty workspace id for
    /// those (see `ChatSessionSidebar`'s "Shared with you" section).
    public var isDirectShare: Bool { workspaceId.isEmpty }

    /// The caller's wallet when one is verified: the attestation wallet for
    /// workspace callers, the redeem-signature wallet for invite peers. Nil
    /// when only an access-key nonce is known.
    public var callerVerifiedWallet: String? {
        if let callerAddress { return callerAddress }
        guard !isDirectShare, let callerWallet, callerWallet.hasPrefix("0x") else { return nil }
        return callerWallet
    }

    /// The caller as a participant (handle, wallet, kind).
    public var caller: Participant? {
        guard isServedForTeammate else { return nil }
        return Participant.caller(from: self)
    }

    /// Compact label for the caller: `@alice`, else a short wallet. The
    /// display name is used only for legacy rows that recorded neither.
    public var callerLabel: String? {
        if let callerHandle { return "@" + callerHandle }
        if let wallet = callerVerifiedWallet { return ParticipantFormatter.shortAddress(wallet) }
        if let callerName, !callerName.isEmpty { return callerName }
        guard let callerWallet, callerWallet.count > 12 else { return callerWallet }
        return "\(callerWallet.prefix(6))…\(callerWallet.suffix(4))"
    }

    // MARK: - JSON column codec

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public func encodedJSON() -> String? {
        guard let data = try? Self.encoder.encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(json: String?) -> WorkspaceSessionContext? {
        guard let json, !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WorkspaceSessionContext.self, from: data)
    }
}
