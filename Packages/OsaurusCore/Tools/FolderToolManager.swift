//
//  FolderToolManager.swift
//  osaurus
//
//  Folder-context tool registration. The folder tool surface is registered
//  once per process (lazily, on the first folder mount anywhere); tool
//  bodies resolve the EXECUTING chat's folder root from the TaskLocal
//  execution scope (`ChatExecutionContext.currentFolderRoot`), so two chats
//  with different folders share one registration without cross-routing.
//  Per-request visibility (no folder -> hidden, non-git folder -> git tools
//  hidden) is schema filtering in `ToolRegistry`, not register/unregister.
//
//  `share_artifact` lives in `Tools/ShareArtifactTool.swift` and is
//  registered as a global built-in (available in plain chat, folder, and
//  sandbox alike). Agent-loop helpers (`todo` / `complete` / `clarify`)
//  live in `Tools/AgentLoopTools.swift`.
//

import Foundation

// MARK: - Folder Tool Manager

/// Manager for the canonical, process-wide folder tool registration.
@MainActor
public final class FolderToolManager {
    public static let shared = FolderToolManager()

    /// Names of the registered folder tools (core + git), empty until the
    /// first folder mount triggers registration.
    private var registeredNames: [String] = []

    private init() {}

    /// Returns the names of the registered folder tools.
    public var folderToolNames: [String] { registeredNames }

    /// Idempotent: register the canonical folder tool surface (core + git)
    /// once per process. Called whenever any chat mounts or restores a
    /// folder. The instances carry no fixed root — each execution resolves
    /// the owning chat's folder from its TaskLocal scope — so registration
    /// never needs to be torn down or swapped when folders change.
    public func ensureFolderToolsRegistered() {
        guard registeredNames.isEmpty else { return }
        let tools = FolderToolFactory.buildCoreTools() + FolderToolFactory.buildGitTools()
        registeredNames = tools.map { $0.name }
        for tool in tools {
            ToolRegistry.shared.register(tool)
        }
    }

    /// Test seam: tear the canonical registration down so a suite can prove
    /// registration behavior from a clean slate. Production code never
    /// unregisters folder tools.
    public func _unregisterAllForTesting() {
        guard !registeredNames.isEmpty else { return }
        ToolRegistry.shared.unregister(names: registeredNames)
        registeredNames = []
    }
}
