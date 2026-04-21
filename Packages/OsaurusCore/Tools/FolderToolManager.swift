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

    /// Register folder-specific tools for the given context
    /// Called by FolderContextService when folder is selected
    public func registerFolderTools(for context: FolderContext) {
        // Unregister any existing folder tools first
        unregisterFolderTools()

        currentFolderContext = context

        // Build core tools (always)
        folderTools = FolderToolFactory.buildCoreTools(rootPath: context.rootPath)

        // Add coding tools if known project type
        if context.projectType != .unknown {
            folderTools += FolderToolFactory.buildCodingTools(rootPath: context.rootPath)
        }

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
    }
}
