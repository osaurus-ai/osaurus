//
//  SandboxWorkspaceChange.swift
//  osaurus
//
//  Models for tracking net sandbox-workspace file changes per chat session,
//  persisted so a "Changes" list (and undo) survives app relaunch.
//

import Foundation

// MARK: - Workspace roots

/// Which writable root a change lives under. The sandbox exposes the agent
/// home (`/workspace/agents/{name}`) and the shared workspace
/// (`/workspace/shared`); `.hostFolder` covers the user-selected host folder
/// ("Folder" chip) mutated by the folder tools.
///
/// For `.hostFolder` rows the `agentName` field is reused to carry the
/// folder's absolute host path (both are stored as TEXT, so the DB schema and
/// its UNIQUE constraint work unchanged).
public enum SandboxWorkspaceRootKind: String, Codable, Sendable, CaseIterable {
    case agentHome = "home"
    case shared = "shared"
    case hostFolder = "host"

    /// The roots a sandbox checkpoint scans. `.hostFolder` is deliberately
    /// excluded — for a sandbox agent the `agentName` is a Linux agent name,
    /// not a host path, and would resolve to a bogus root.
    public static let sandboxRoots: [SandboxWorkspaceRootKind] = [.agentHome, .shared]

    /// Host-side directory for this root. For `.hostFolder`, `agentName` IS
    /// the folder's absolute path.
    public func hostURL(agentName: String) -> URL {
        switch self {
        case .agentHome: return OsaurusPaths.containerAgentDir(agentName)
        case .shared: return OsaurusPaths.containerSharedDir()
        case .hostFolder: return URL(fileURLWithPath: agentName, isDirectory: true)
        }
    }

    /// Absolute path prefix for display: the in-container path for sandbox
    /// roots, the real host path for a host folder.
    public func containerPrefix(agentName: String) -> String {
        switch self {
        case .agentHome: return OsaurusPaths.inContainerAgentHome(agentName)
        case .shared: return "/workspace/shared"
        case .hostFolder: return agentName
        }
    }
}

// MARK: - Change enums

public enum SandboxChangeEntryType: String, Codable, Sendable {
    case file
    case directory
    case symlink
}

public enum SandboxChangeKind: String, Codable, Sendable {
    case created
    case modified
    case deleted
}

public enum SandboxChangeState: String, Codable, Sendable {
    /// Outstanding and undoable (assuming no active background job).
    case pending
    /// The path was changed again by something outside this chat after the
    /// last tracked mutation; undo refuses to overwrite the newer work.
    case conflicted
}

// MARK: - Change row

/// One net outstanding change to a sandbox workspace path, attributed to a
/// chat session. Repeated edits to the same path coalesce into a single row
/// whose `kind` reflects baseline-vs-current, not the individual operations.
public struct SandboxWorkspaceChange: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    /// Owning chat session id (uuidString).
    public let sessionId: String
    /// Linux sandbox agent name whose workspace was mutated — or, for
    /// `.hostFolder` rows, the absolute path of the selected host folder.
    public let agentName: String
    public let root: SandboxWorkspaceRootKind
    /// Path relative to the root (no leading slash).
    public let relativePath: String
    public var entryType: SandboxChangeEntryType
    public var kind: SandboxChangeKind
    public var state: SandboxChangeState
    /// Content signature of the pre-chat baseline (nil = did not exist).
    public var baselineSignature: String?
    /// Content signature after the last tracked mutation (nil = deleted).
    public var currentSignature: String?
    /// Name of the tool whose checkpoint last touched this path.
    public var sourceTool: String
    public let firstChangedAt: Date
    public var lastChangedAt: Date

    public init(
        id: UUID = UUID(),
        sessionId: String,
        agentName: String,
        root: SandboxWorkspaceRootKind,
        relativePath: String,
        entryType: SandboxChangeEntryType,
        kind: SandboxChangeKind,
        state: SandboxChangeState = .pending,
        baselineSignature: String?,
        currentSignature: String?,
        sourceTool: String,
        firstChangedAt: Date = Date(),
        lastChangedAt: Date = Date()
    ) {
        self.id = id
        self.sessionId = sessionId
        self.agentName = agentName
        self.root = root
        self.relativePath = relativePath
        self.entryType = entryType
        self.kind = kind
        self.state = state
        self.baselineSignature = baselineSignature
        self.currentSignature = currentSignature
        self.sourceTool = sourceTool
        self.firstChangedAt = firstChangedAt
        self.lastChangedAt = lastChangedAt
    }
}

// MARK: - Display helpers

extension SandboxWorkspaceChange {
    /// In-container absolute path (what the user/agent sees in chat).
    public var displayPath: String {
        root.containerPrefix(agentName: agentName) + "/" + relativePath
    }

    /// Last path component for compact rows.
    public var filename: String {
        (relativePath as NSString).lastPathComponent
    }

    /// Host-side URL of the live file this change refers to.
    public var hostURL: URL {
        root.hostURL(agentName: agentName).appendingPathComponent(relativePath)
    }
}

extension SandboxChangeKind {
    public var iconName: String {
        switch self {
        case .created: return "doc.badge.plus"
        case .modified: return "pencil"
        case .deleted: return "trash"
        }
    }
}
