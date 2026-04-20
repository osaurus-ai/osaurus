//
//  FolderToolManager.swift
//  osaurus
//
//  Folder-context tool registration + the chat-side `share_artifact` tool.
//  Agent loop helpers (todo / complete / clarify) live in
//  `AgentLoopTools.swift` and are dispatched as engine intercepts.
//

import Foundation

// MARK: - Share Artifact Tool

/// Unified tool for sharing files or inline content with the user.
/// Supports any file type, directories, and inline text content.
public struct ShareArtifactTool: OsaurusTool {
    public let name = "share_artifact"
    public let description =
        "Surface an artifact to the user in the chat thread. The chat does NOT show files you wrote to disk or "
        + "to the sandbox unless you also call this tool — it is the only path that creates an artifact card the "
        + "user can click. Use for generated images, charts, websites, reports, code blobs, and any deliverable. "
        + "Pass `path` to share an existing file (folder/sandbox path), or `content` + `filename` to share inline "
        + "text/markdown without writing to disk first."

    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string(
                    "Relative path to a file or directory to share. Resolved relative to your working directory."
                ),
            ]),
            "content": .object([
                "type": .string("string"),
                "description": .string(
                    "Inline text or markdown content to share directly. Use this when you want to share generated text without writing to a file first."
                ),
            ]),
            "filename": .object([
                "type": .string("string"),
                "description": .string(
                    "Filename for the artifact. Required when using 'content'. Optional with 'path' (defaults to the file/directory name)."
                ),
            ]),
            "description": .object([
                "type": .string("string"),
                "description": .string("Brief human-readable description of what this artifact is."),
            ]),
        ]),
        "required": .array([]),
    ])

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw NSError(
                domain: "FolderTools",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Invalid arguments. Provide at least one of: path (string), content (string)"
                ]
            )
        }

        let path = json["path"] as? String
        let rawContent = json["content"] as? String
        let filename = json["filename"] as? String
        let description = json["description"] as? String

        guard path != nil || rawContent != nil else {
            throw NSError(
                domain: "FolderTools",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "At least one of 'path' or 'content' must be provided."
                ]
            )
        }

        if rawContent != nil {
            guard let fn = filename, !fn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NSError(
                    domain: "FolderTools",
                    code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "'filename' is required when using 'content' mode."
                    ]
                )
            }
        }

        let content = rawContent?
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")

        let resolvedFilename: String
        if let filename, !filename.isEmpty {
            resolvedFilename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let path {
            resolvedFilename = (path as NSString).lastPathComponent
        } else {
            resolvedFilename = "artifact.txt"
        }

        let mimeType = SharedArtifact.mimeType(from: resolvedFilename)

        var metadataDict: [String: Any] = [
            "filename": resolvedFilename,
            "mime_type": mimeType,
        ]
        if let path { metadataDict["path"] = path }
        if content != nil { metadataDict["has_content"] = true }
        if let description { metadataDict["description"] = description }

        let metadataJSON: String
        if let jsonData = try? JSONSerialization.data(withJSONObject: metadataDict),
            let jsonStr = String(data: jsonData, encoding: .utf8)
        {
            metadataJSON = jsonStr
        } else {
            metadataJSON = "{}"
        }

        var result = """
            Artifact shared:
            - Filename: \(resolvedFilename)
            - Type: \(mimeType)
            """
        if let description {
            result += "\n- Description: \(description)"
        }

        result += "\n\n---SHARED_ARTIFACT_START---\n"
        result += metadataJSON + "\n"
        if let content {
            result += content + "\n"
        }
        result += "---SHARED_ARTIFACT_END---"

        return result
    }
}

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
