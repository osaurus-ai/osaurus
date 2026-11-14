//
//  FileChangeModels.swift
//  osaurus
//
//  Git-like per-session file history. Every mutating tool call becomes one
//  `FileChangeSet` (a "commit") holding a `FileChangeEntry` per touched path
//  with exact before/after content signatures. Content bytes live in the
//  content-addressed `FileObjectStore`, so any set can be diffed or reverted
//  long after later edits.
//

import Foundation

// MARK: - Notifications

extension Notification.Name {
    /// Posted on main whenever a session's file history changes (a set was
    /// recorded, reverted, or purged). `userInfo["sessionId"]` carries the
    /// session uuid string; absent for bulk changes (retention GC).
    public static let fileChangesDidChange = Notification.Name("fileChangesDidChange")
    /// Ask the chat window showing `userInfo["sessionId"]` to open its File
    /// Changes inspector, revealing `userInfo["setId"]` (a UUID) when set.
    public static let fileChangesOpenPanel = Notification.Name("fileChangesOpenPanel")
}

// MARK: - Enums

public enum FileChangeOrigin: String, Codable, Sendable {
    /// A tool call made by the agent.
    case agent
    /// A revert the user (or `file_undo`) performed; itself revertible.
    case userRevert = "user_revert"
    /// Mutations a background job made after its launching call returned.
    case externalJob = "external_job"
    /// Rows carried over from the pre-journal net-change tracker.
    case imported
}

public enum FileChangeSetStatus: String, Codable, Sendable {
    case applied
    case reverted
    case partiallyReverted = "partially_reverted"
    /// The call ran without a restorable snapshot (user approved it).
    case untracked
}

public enum FileChangeEntryKind: String, Codable, Sendable {
    case created
    case modified
    case deleted
}

public enum FileChangeEntryState: String, Codable, Sendable {
    case applied
    case reverted
    /// A revert skipped this entry because the live path moved on.
    case conflicted
}

// MARK: - Path state

/// Snapshot of one path: type, content signature, and POSIX mode.
///
/// Signatures: `sha256:<hex>` (bytes held in the object store), `dir`,
/// `link:<target>`, or `big:<size>:<mtimeNs>` for a file too large to keep
/// (not restorable).
public struct FilePathState: Codable, Sendable, Equatable {
    public var type: SandboxChangeEntryType
    public var signature: String
    public var mode: Int?
    public var size: Int64

    public init(type: SandboxChangeEntryType, signature: String, mode: Int? = nil, size: Int64 = 0) {
        self.type = type
        self.signature = signature
        self.mode = mode
        self.size = size
    }

    /// Object-store key when the bytes were captured.
    public var objectHash: String? {
        signature.hasPrefix("sha256:") ? String(signature.dropFirst(7)) : nil
    }

    /// Whether this state can be recreated exactly from history.
    public var isRestorable: Bool {
        switch type {
        case .directory, .symlink: return true
        case .file: return objectHash != nil
        }
    }
}

// MARK: - Entry

public struct FileChangeEntry: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let setId: UUID
    public let sessionId: String
    public let rootKind: SandboxWorkspaceRootKind
    /// Sandbox agent name, or the host folder's absolute path.
    public let rootId: String
    /// Root-relative path (no leading slash).
    public let path: String
    /// For a create that carries the exact bytes a delete in the same set
    /// removed: the old path (display-only "Renamed from").
    public var fromPath: String?
    public let kind: FileChangeEntryKind
    public let before: FilePathState?
    public let after: FilePathState?
    public var state: FileChangeEntryState
    /// Position within the set (stable ordering across reloads).
    public let ordinal: Int

    public init(
        id: UUID = UUID(),
        setId: UUID,
        sessionId: String,
        rootKind: SandboxWorkspaceRootKind,
        rootId: String,
        path: String,
        fromPath: String? = nil,
        kind: FileChangeEntryKind,
        before: FilePathState?,
        after: FilePathState?,
        state: FileChangeEntryState = .applied,
        ordinal: Int
    ) {
        self.id = id
        self.setId = setId
        self.sessionId = sessionId
        self.rootKind = rootKind
        self.rootId = rootId
        self.path = path
        self.fromPath = fromPath
        self.kind = kind
        self.before = before
        self.after = after
        self.state = state
        self.ordinal = ordinal
    }

    public var entryType: SandboxChangeEntryType {
        after?.type ?? before?.type ?? .file
    }

    public var filename: String { (path as NSString).lastPathComponent }

    /// Absolute path shown to the user (in-container for sandbox roots).
    public var displayPath: String {
        let prefix = rootKind.containerPrefix(agentName: rootId)
        return prefix.hasSuffix("/") ? prefix + path : prefix + "/" + path
    }

    public var hostURL: URL {
        rootKind.hostURL(agentName: rootId).appendingPathComponent(path)
    }

    /// Identity of the path across sets.
    public var pathKey: FilePathKey {
        FilePathKey(rootKind: rootKind, rootId: rootId, path: path)
    }
}

public struct FilePathKey: Hashable, Sendable, Codable {
    public let rootKind: SandboxWorkspaceRootKind
    public let rootId: String
    public let path: String

    public init(rootKind: SandboxWorkspaceRootKind, rootId: String, path: String) {
        self.rootKind = rootKind
        self.rootId = rootId
        self.path = path
    }

    public var hostURL: URL {
        rootKind.hostURL(agentName: rootId).appendingPathComponent(path)
    }

    public var displayPath: String {
        let prefix = rootKind.containerPrefix(agentName: rootId)
        return prefix.hasSuffix("/") ? prefix + path : prefix + "/" + path
    }

    /// `<folder name>/<relative path>` for people: the same shape whether the
    /// root is a chosen folder or a sandbox home. The full path goes in a
    /// tooltip (`hostURL.path`).
    public var shortDisplayPath: String {
        let root: String
        switch rootKind {
        case .hostFolder: root = (rootId as NSString).lastPathComponent
        case .agentHome: root = rootId
        case .shared: root = "shared"
        }
        return root.isEmpty ? path : root + "/" + path
    }

    public var filename: String { (path as NSString).lastPathComponent }
}

// MARK: - Change set

public struct FileChangeSet: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let sessionId: String
    public let toolName: String
    public let toolCallId: String?
    public let turnId: UUID?
    public let origin: FileChangeOrigin
    public var status: FileChangeSetStatus
    /// For `userRevert` sets: the set (or first set of a rollback) undone.
    public let revertsSetId: UUID?
    /// Short human description (revert summaries, untracked reason).
    public var note: String?
    public let createdAt: Date
    public var entries: [FileChangeEntry]

    public init(
        id: UUID = UUID(),
        sessionId: String,
        toolName: String,
        toolCallId: String? = nil,
        turnId: UUID? = nil,
        origin: FileChangeOrigin,
        status: FileChangeSetStatus = .applied,
        revertsSetId: UUID? = nil,
        note: String? = nil,
        createdAt: Date = Date(),
        entries: [FileChangeEntry] = []
    ) {
        self.id = id
        self.sessionId = sessionId
        self.toolName = toolName
        self.toolCallId = toolCallId
        self.turnId = turnId
        self.origin = origin
        self.status = status
        self.revertsSetId = revertsSetId
        self.note = note
        self.createdAt = createdAt
        self.entries = entries
    }

    public var isRevertible: Bool {
        status != .untracked && entries.contains { $0.state != .reverted }
    }

    /// Human title for timelines and cards ("Edit file", "Shell command").
    public var displayTitle: String {
        switch origin {
        case .userRevert: return note ?? L("Revert")
        case .imported: return L("Earlier changes")
        case .externalJob: return L("Background job")
        case .agent: return Self.displayName(forTool: toolName)
        }
    }

    public static func displayName(forTool tool: String) -> String {
        switch tool {
        case "file_write", "sandbox_write_file": return L("Write file")
        case "file_edit", "sandbox_edit_file": return L("Edit file")
        case "file_copy": return L("Copy file")
        case "redact_file": return L("Redact file")
        case "shell_run": return L("Shell command")
        case "sandbox_exec", "sandbox_exec_background": return L("Sandbox command")
        case "revert": return L("Revert")
        default:
            let words = tool.split(separator: "_").map(String.init)
            guard let first = words.first else { return tool }
            return ([first.capitalized] + words.dropFirst()).joined(separator: " ")
        }
    }
}

// MARK: - Net file view

/// Net state of one path across the whole session: its state before the
/// session first touched it vs. its latest recorded state.
public struct FileNetChange: Sendable, Identifiable, Equatable {
    public var id: FilePathKey { key }
    public let key: FilePathKey
    public let original: FilePathState?
    public let latest: FilePathState?
    public let setIds: [UUID]
    public let lastChangedAt: Date
    public let lastTool: String

    public var kind: FileChangeEntryKind {
        original == nil ? .created : (latest == nil ? .deleted : .modified)
    }

    public var entryType: SandboxChangeEntryType {
        latest?.type ?? original?.type ?? .file
    }
}

// MARK: - Revert results

public enum FileRevertItemOutcome: Sendable, Equatable {
    case restored
    /// Live path diverged from the last recorded state; left untouched.
    case conflicted
    case failed(String)
}

public struct FileRevertPreviewItem: Sendable, Identifiable, Equatable {
    public var id: FilePathKey { key }
    public let key: FilePathKey
    /// What the path returns to (nil = removed).
    public let target: FilePathState?
    /// What history expects to be live right now.
    public let expected: FilePathState?
    public let isConflict: Bool
    /// Target bytes aren't in history (file was too large to keep).
    public let isUnrestorable: Bool
    /// Retention trimmed this path's earliest sets: the target is the
    /// earliest change still kept, not the state before the chat.
    public var isTruncated: Bool = false
}

public struct FileRevertPreview: Sendable, Equatable {
    public let items: [FileRevertPreviewItem]
    public var conflictCount: Int { items.filter(\.isConflict).count }
    public var unrestorableCount: Int { items.filter(\.isUnrestorable).count }
    public var isEmpty: Bool { items.isEmpty }
}

public struct FileRevertSummary: Sendable, Equatable {
    public var restored: Int = 0
    public var conflicted: Int = 0
    public var failed: Int = 0
    public var failures: [String] = []
    /// Paths actually returned to their target state (in plan order).
    public var restoredPaths: [FilePathKey] = []
    /// The `userRevert` set recording this revert (undo it to redo).
    public var revertSetId: UUID?
    /// Refused wholesale (e.g. a background job is still running).
    public var blockedReason: String?

    public var isClean: Bool { conflicted == 0 && failed == 0 && blockedReason == nil }
}

/// One assistant turn's footprint, for the transcript's end-of-turn row.
public struct FileChangeTurnSummary: Sendable, Equatable {
    public let sessionId: String
    public let firstSetId: UUID
    public let fileCount: Int
    public let setCount: Int
    public let allReverted: Bool
}

// MARK: - Session summary (sidebar)

public struct FileChangeSessionSummary: Sendable, Equatable {
    /// Paths whose net state differs from before the session.
    public let outstandingFiles: Int
    public let setCount: Int
}
