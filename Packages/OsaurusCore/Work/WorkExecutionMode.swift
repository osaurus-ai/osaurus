//
//  WorkExecutionMode.swift
//  osaurus
//
//  First-class execution mode for work sessions.
//

import Foundation

public enum WorkExecutionMode: Sendable {
    case hostFolder(WorkFolderContext)
    case sandbox
    case none

    public var folderContext: WorkFolderContext? {
        guard case .hostFolder(let context) = self else { return nil }
        return context
    }

    public var usesHostFolderTools: Bool {
        if case .hostFolder = self {
            return true
        }
        return false
    }

    public var usesSandboxTools: Bool {
        if case .sandbox = self {
            return true
        }
        return false
    }
}

/// Origin mode for a memory write. Persisted alongside entries so reads can
/// filter out tool-using contributions when the current request has no tools.
/// NULL on pre-v4 rows is treated as chat-compatible (shown everywhere).
public enum MemorySourceMode: String, Codable, Sendable {
    case chat
    case chatSandbox = "chat_sandbox"
    case workHost = "work_host"
    case workSandbox = "work_sandbox"

    /// True when the turn was recorded in a mode that had agentic tools.
    public var hasTools: Bool { self != .chat }
}

public extension WorkExecutionMode {
    /// Derive the memory source mode from the execution mode.
    /// Callers in pure-chat contexts without sandbox should pass `.chat` directly;
    /// `.none` here maps to `.chat` as a safe default.
    var memorySourceMode: MemorySourceMode {
        switch self {
        case .none: return .chat
        case .hostFolder: return .workHost
        case .sandbox: return .workSandbox
        }
    }
}
