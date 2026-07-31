//
//  ExecutionMode.swift
//  osaurus
//
//  First-class execution mode for work sessions.
//

import Foundation

public enum ExecutionMode: Sendable {
    case hostFolder(FolderContext)
    /// VM execution with no host-folder bridge.
    case sandbox
    case none

    /// Compatibility constructor for callers migrating from combined mode.
    /// Associated host values are deliberately ignored.
    public static func sandbox(
        hostRead _: FolderContext?,
        hostWrite _: Bool = false
    ) -> ExecutionMode {
        .sandbox
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
        nil
    }

    /// True when the mode exposes the host read tools
    /// (combined sandbox + host-read mode).
    public var allowsHostReadTools: Bool {
        hostReadContext != nil
    }

    /// True when combined mode may also WRITE the host folder
    /// (`file_write` / `file_edit` only — never shell / git).
    public var allowsHostWriteTools: Bool {
        false
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
