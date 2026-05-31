//
//  ExecutionMode.swift
//  osaurus
//
//  First-class execution mode for work sessions.
//

import Foundation

public enum ExecutionMode: Sendable {
    case hostFolder(FolderContext)
    /// Sandbox execution, optionally combined with a read-only host
    /// workspace. When `hostRead` is non-nil the agent gets the host
    /// read tools (`file_read` / `file_search`, scoped to the folder
    /// root, read-only; `file_read` also lists directories) in addition
    /// to the sandbox exec tools — but exec still runs in the VM, which
    /// has no mount of the host workspace.
    case sandbox(hostRead: FolderContext?)
    case none

    /// The host folder available for *read-write* host-native exec.
    /// Non-nil only in `.hostFolder` — the combined-mode read-only
    /// folder is exposed via `hostReadContext` instead so callers that
    /// drive host writes / git never see the read-only folder.
    public var folderContext: FolderContext? {
        guard case .hostFolder(let context) = self else { return nil }
        return context
    }

    /// The read-only host folder available in combined sandbox mode.
    /// Non-nil only for `.sandbox(hostRead: ctx)` with a non-nil ctx.
    public var hostReadContext: FolderContext? {
        guard case .sandbox(let hostRead) = self else { return nil }
        return hostRead
    }

    /// True when the mode exposes the read-only host read tools
    /// (combined sandbox + host-read mode).
    public var allowsHostReadTools: Bool {
        hostReadContext != nil
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
