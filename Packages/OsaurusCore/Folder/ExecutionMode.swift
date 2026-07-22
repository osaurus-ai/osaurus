//
//  ExecutionMode.swift
//  osaurus
//
//  First-class execution mode for work sessions.
//

import Foundation

public enum ExecutionMode: Sendable {
    case hostFolder(FolderContext)
    /// Sandbox execution, optionally combined with a host workspace.
    /// When `hostRead` is non-nil the agent gets the host read tools
    /// (`file_read` / `file_search`, scoped to the folder root;
    /// `file_read` also lists directories) in addition to the sandbox
    /// exec tools — but exec still runs in the VM, which has no mount of
    /// the host workspace. When `hostWrite` is additionally true (the
    /// agent's `allowHostFolderWrites` opt-in), `file_write` /
    /// `file_edit` join the schema and may mutate the folder — writes
    /// are change-tracked and undoable; exec and shell stay
    /// sandbox-only.
    case sandbox(hostRead: FolderContext?, hostWrite: Bool)
    case none

    /// Read-only combined mode shorthand — the overwhelmingly common
    /// construction (plain sandbox, previews, evaluator). The write grant
    /// is only threaded through `ToolRegistry.resolveExecutionMode`.
    public static func sandbox(hostRead: FolderContext?) -> ExecutionMode {
        .sandbox(hostRead: hostRead, hostWrite: false)
    }

    /// The host folder available for *read-write* host-native exec.
    /// Non-nil only in `.hostFolder` — the combined-mode folder is
    /// exposed via `hostReadContext` instead so callers that drive host
    /// shell / git never see it.
    public var folderContext: FolderContext? {
        guard case .hostFolder(let context) = self else { return nil }
        return context
    }

    /// The host folder available in combined sandbox mode.
    /// Non-nil only for `.sandbox(hostRead: ctx, ...)` with a non-nil ctx.
    public var hostReadContext: FolderContext? {
        guard case .sandbox(let hostRead, _) = self else { return nil }
        return hostRead
    }

    /// True when the mode exposes the host read tools
    /// (combined sandbox + host-read mode).
    public var allowsHostReadTools: Bool {
        hostReadContext != nil
    }

    /// True when combined mode may also WRITE the host folder
    /// (`file_write` / `file_edit` only — never shell / git).
    public var allowsHostWriteTools: Bool {
        guard case .sandbox(let hostRead, let hostWrite) = self else { return false }
        return hostRead != nil && hostWrite
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
