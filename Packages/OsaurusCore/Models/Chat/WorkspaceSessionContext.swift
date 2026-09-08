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
//    "for Alice · Workspace" and the row is treated as read-only.
//

import Foundation

public struct WorkspaceSessionContext: Codable, Equatable, Sendable, Hashable {
    /// Router workspace id (`workspace_id` on the wire).
    public var workspaceId: String
    /// Lowercased checksummed address of the shared agent.
    public var agentAddress: String
    /// Teammate who drove the conversation — only set on the host side.
    public var callerWallet: String?
    /// Teammate display name at write time — only set on the host side.
    public var callerName: String?

    public init(
        workspaceId: String,
        agentAddress: String,
        callerWallet: String? = nil,
        callerName: String? = nil
    ) {
        self.workspaceId = workspaceId
        self.agentAddress = agentAddress.lowercased()
        self.callerWallet = callerWallet?.lowercased()
        self.callerName = callerName
    }

    /// True when the session was served by this instance for a teammate
    /// (host side); false for the teammate's own chats with a shared agent.
    public var isServedForTeammate: Bool { callerWallet != nil }

    /// True for an agent shared through an invite link rather than a
    /// workspace: the sidebar and host rows stamp an empty workspace id for
    /// those (see `ChatSessionSidebar`'s "Shared with you" section).
    public var isDirectShare: Bool { workspaceId.isEmpty }

    /// Human label for the caller ("Alice", or a shortened wallet).
    public var callerLabel: String? {
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
