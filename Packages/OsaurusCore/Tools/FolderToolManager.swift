//
//  FolderToolManager.swift
//  osaurus
//
//  Folder-context tool registration. The folder-tool registry is rebuilt
//  whenever the working folder changes; folder tools live and die with the
//  folder context.
//
//  `share_artifact` lives in `Tools/ShareArtifactTool.swift` and is
//  registered as a global built-in (available in plain chat, folder, and
//  sandbox alike). Agent-loop helpers (`todo` / `complete` / `clarify`)
//  live in `Tools/AgentLoopTools.swift`.
//

import Foundation

// MARK: - Folder Tool Manager

/// Manager for folder-context tool registration.
/// Used by `FolderContextService` to install/remove folder-scoped tools
/// (file_read, search, git, etc.) when the user picks or clears a working folder.
@MainActor
public final class FolderToolManager {
    public static let shared = FolderToolManager()

    /// Folder tools (created dynamically based on folder context)
    private var folderTools: [OsaurusTool] = []

    /// Names of currently registered folder tools
    private var _folderToolNames: [String] = []

    /// Current folder context (if any)
    private var currentFolderContext: FolderContext?

    private init() {}

    /// Returns the names of currently registered folder tools
    public var folderToolNames: [String] { _folderToolNames }

    /// Whether folder tools are currently registered
    public var hasFolderTools: Bool { currentFolderContext != nil }

    /// The context the current registration was built for, if any.
    /// Callers that must temporarily swap the process-wide folder toolset
    /// (the eval harness) snapshot this and re-register it on exit so a
    /// pre-existing registration is never silently torn down.
    public var registeredContext: FolderContext? { currentFolderContext }

    /// Register folder-specific tools for the given context
    /// Called by FolderContextService when folder is selected
    public func registerFolderTools(for context: FolderContext) {
        // Unregister any existing folder tools first
        unregisterFolderTools()

        currentFolderContext = context

        // Bind the undo log's root so `performUndo` can resolve relative
        // paths — without this every undo fails with "No root path
        // configured" even though operations were dutifully logged.
        let root = context.rootPath
        Task { await FileOperationLog.shared.setRootPath(root) }

        // Build core tools (always). `shell_run` lives in the core set so
        // the folder-section prompt can reference it unconditionally.
        folderTools = FolderToolFactory.buildCoreTools(rootPath: context.rootPath)

        // Add git tools if git repo
        if context.isGitRepo {
            folderTools += FolderToolFactory.buildGitTools(rootPath: context.rootPath)
        }

        _folderToolNames = folderTools.map { $0.name }
        for tool in folderTools {
            ToolRegistry.shared.register(tool)
        }
    }

    /// Unregister all folder tools
    /// Called by FolderContextService when folder is cleared
    public func unregisterFolderTools() {
        guard !_folderToolNames.isEmpty else { return }
        ToolRegistry.shared.unregister(names: _folderToolNames)
        folderTools = []
        _folderToolNames = []
        currentFolderContext = nil
        Task { await FileOperationLog.shared.setRootPath(nil) }
    }
}

/// Serializes remote agent runs (`/agents/{id}/run`) that mount a per-agent
/// host workspace folder. Folder tools register process-wide in the single
/// global `ToolRegistry` (one `file_write` bound to one root at a time), and
/// the run uses snapshot/restore around that registration. Without this gate,
/// two concurrent host-folder runs would interleave register/restore and
/// corrupt the registration (e.g. leaving a finished run's tools registered).
/// A run holds the gate for its full duration; this is acceptable for a
/// personal device where simultaneous host-folder remote runs are rare. The
/// run's client-disconnect cancellation + iteration cap bound how long the
/// gate is held.
actor HostFolderRunGate {
    static let shared = HostFolderRunGate()

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            let next = waiters.removeFirst()
            next.resume()
        }
    }
}
