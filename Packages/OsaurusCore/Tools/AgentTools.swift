//
//  AgentTools.swift
//  osaurus
//
//  Agent-specific tools for plan submission and completion reporting.
//

import Foundation

// MARK: - Submit Plan Tool

/// Tool for the agent to submit an execution plan
public struct SubmitPlanTool: OsaurusTool {
    public let name = "submit_plan"
    public let description =
        "Submit an execution plan for the current task. The plan should contain concrete, actionable steps."

    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "steps": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "description": .object([
                            "type": .string("string"),
                            "description": .string("What this step accomplishes"),
                        ]),
                        "tool": .object([
                            "type": .string("string"),
                            "description": .string("The tool to use for this step (optional)"),
                        ]),
                    ]),
                    "required": .array([.string("description")]),
                ]),
                "description": .string("Array of steps in the plan"),
            ]),
            "reasoning": .object([
                "type": .string("string"),
                "description": .string("Brief explanation of the approach"),
            ]),
        ]),
        "required": .array([.string("steps")]),
    ])

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        // Parse the arguments
        guard let data = argumentsJSON.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let steps = json["steps"] as? [[String: Any]]
        else {
            throw NSError(
                domain: "AgentTools",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid plan format"]
            )
        }

        let stepCount = steps.count
        let maxSteps = AgentExecutionEngine.maxToolCallsPerIssue

        if stepCount > maxSteps {
            return """
                Plan has \(stepCount) steps, which exceeds the maximum of \(maxSteps) steps per issue.
                The task will be decomposed into smaller chunks.

                Steps submitted:
                \(steps.enumerated().map { "  \($0.offset + 1). \(($0.element["description"] as? String) ?? "Unknown")" }.joined(separator: "\n"))
                """
        }

        return """
            Plan accepted with \(stepCount) step(s).
            Proceeding with execution.

            Steps:
            \(steps.enumerated().map { "  \($0.offset + 1). \(($0.element["description"] as? String) ?? "Unknown")" }.joined(separator: "\n"))
            """
    }
}

// MARK: - Report Discovery Tool

/// Tool for the agent to report discovered work
public struct ReportDiscoveryTool: OsaurusTool {
    public let name = "report_discovery"
    public let description =
        "Report discovered work such as bugs, TODOs, prerequisites, or follow-up tasks that should be tracked."

    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "type": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("error"),
                    .string("todo"),
                    .string("fixme"),
                    .string("prerequisite"),
                    .string("follow_up"),
                ]),
                "description": .string("Type of discovery"),
            ]),
            "title": .object([
                "type": .string("string"),
                "description": .string("Short title for the discovered issue"),
            ]),
            "description": .object([
                "type": .string("string"),
                "description": .string("Detailed description of the discovery"),
            ]),
            "priority": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("p0"),
                    .string("p1"),
                    .string("p2"),
                    .string("p3"),
                ]),
                "description": .string("Suggested priority (p0=urgent, p3=low)"),
            ]),
        ]),
        "required": .array([.string("type"), .string("title")]),
    ])

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        // Parse the arguments
        guard let data = argumentsJSON.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let typeStr = json["type"] as? String,
            let title = json["title"] as? String
        else {
            throw NSError(
                domain: "AgentTools",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid discovery format"]
            )
        }

        let description = json["description"] as? String
        let priorityStr = json["priority"] as? String ?? "p2"

        // Note: The actual issue creation is handled by DiscoveryDetector or AgentEngine
        // This tool just acknowledges the discovery for now
        return """
            Discovery reported:
            - Type: \(typeStr)
            - Title: \(title)
            - Priority: \(priorityStr.uppercased())
            \(description.map { "- Description: \($0)" } ?? "")

            This will be tracked as a new issue linked to the current task.
            """
    }
}

// MARK: - Complete Task Tool

/// Tool for the agent to mark the current task as complete
public struct CompleteTaskTool: OsaurusTool {
    public let name = "complete_task"
    public let description =
        "Mark the current task as complete with a detailed artifact summarizing the results. The artifact is required and should be a comprehensive markdown document."

    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "summary": .object([
                "type": .string("string"),
                "description": .string("Brief one-line summary of what was accomplished"),
            ]),
            "success": .object([
                "type": .string("boolean"),
                "description": .string("Whether the task was fully successful"),
            ]),
            "artifact": .object([
                "type": .string("string"),
                "description": .string(
                    "Final artifact in markdown format. Must include: a title, summary of work done, key findings or results, any code snippets or examples, and next steps if applicable. This will be displayed to the user as the final output."
                ),
            ]),
            "remaining_work": .object([
                "type": .string("string"),
                "description": .string("Any remaining work that wasn't completed (optional)"),
            ]),
        ]),
        "required": .array([.string("summary"), .string("success"), .string("artifact")]),
    ])

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        // Parse the arguments
        guard let data = argumentsJSON.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let summary = json["summary"] as? String,
            let success = json["success"] as? Bool,
            let rawArtifact = json["artifact"] as? String
        else {
            throw NSError(
                domain: "AgentTools",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Invalid completion format. Required: summary (string), success (boolean), artifact (string)"
                ]
            )
        }

        // Unescape literal \n and \t sequences that models sometimes send
        let artifact =
            rawArtifact
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")

        let remainingWork = json["remaining_work"] as? String

        // Build result with artifact content encoded for parsing by AgentEngine
        var result = """
            Task completion reported:
            - Status: \(success ? "SUCCESS" : "PARTIAL")
            - Summary: \(summary)
            - Artifact Length: \(artifact.count) characters
            """

        if let remaining = remainingWork, !remaining.isEmpty {
            result += "\n- Remaining work: \(remaining)"
        }

        // Append artifact in a structured format for extraction
        result += "\n\n---ARTIFACT_START---\n\(artifact)\n---ARTIFACT_END---"

        return result
    }
}

// MARK: - Generate Artifact Tool

/// Tool for generating downloadable artifacts during execution
public struct GenerateArtifactTool: OsaurusTool {
    public let name = "generate_artifact"
    public let description =
        "Generate a downloadable artifact file with markdown or text content. Use this to create reports, documentation, code snippets, or any other content the user might want to save."

    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "filename": .object([
                "type": .string("string"),
                "description": .string(
                    "Name for the artifact file with extension (e.g., 'report.md', 'summary.txt', 'analysis.md')"
                ),
            ]),
            "content": .object([
                "type": .string("string"),
                "description": .string("The content of the artifact in markdown or plain text format"),
            ]),
        ]),
        "required": .array([.string("filename"), .string("content")]),
    ])

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        // Parse the arguments
        guard let data = argumentsJSON.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let filename = json["filename"] as? String,
            let rawContent = json["content"] as? String
        else {
            throw NSError(
                domain: "AgentTools",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey: "Invalid artifact format. Required: filename (string), content (string)"
                ]
            )
        }

        // Unescape literal \n and \t sequences that models sometimes send
        let content =
            rawContent
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")

        // Validate filename
        let trimmedFilename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFilename.isEmpty else {
            throw NSError(
                domain: "AgentTools",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Filename cannot be empty"]
            )
        }

        // Determine content type from extension
        let contentType = Artifact.contentType(from: trimmedFilename)

        // Return structured result for extraction by AgentEngine
        return """
            Artifact generated:
            - Filename: \(trimmedFilename)
            - Content Type: \(contentType.rawValue)
            - Size: \(content.count) characters

            ---GENERATED_ARTIFACT_START---
            {"filename": "\(trimmedFilename)", "content_type": "\(contentType.rawValue)"}
            \(content)
            ---GENERATED_ARTIFACT_END---
            """
    }
}

// MARK: - Tool Registration

/// Manager for agent-specific tool registration
/// Uses reference counting to support multiple concurrent agent sessions
@MainActor
public final class AgentToolManager {
    public static let shared = AgentToolManager()

    /// Cached tool instances (created once, reused)
    private lazy var tools: [OsaurusTool] = [
        SubmitPlanTool(),
        ReportDiscoveryTool(),
        CompleteTaskTool(),
        GenerateArtifactTool(),
    ]

    /// Reference count for active agent sessions
    /// Tools stay registered while count > 0
    private var referenceCount = 0

    /// Previous enabled state for each tool (to restore on unregister)
    private var previousEnabledState: [String: Bool] = [:]

    // MARK: - Folder Tools

    /// Folder tools (created dynamically based on folder context)
    private var folderTools: [OsaurusTool] = []

    /// Names of currently registered folder tools
    private var _folderToolNames: [String] = []

    /// Current folder context (if any)
    private var currentFolderContext: AgentFolderContext?

    private init() {}

    /// Whether agent tools are currently registered
    public var isRegistered: Bool {
        referenceCount > 0
    }

    /// Returns the names of all agent tools (excluding folder tools)
    public var toolNames: [String] {
        tools.map { $0.name }
    }

    /// Returns the names of currently registered folder tools
    public var folderToolNames: [String] {
        _folderToolNames
    }

    /// Whether folder tools are currently registered
    public var hasFolderTools: Bool {
        currentFolderContext != nil
    }

    /// Registers agent-specific tools with the tool registry and enables them
    /// Uses reference counting - safe to call multiple times from different sessions
    /// Call this when entering Agent Mode
    public func registerTools() {
        referenceCount += 1

        // Only register on first reference
        guard referenceCount == 1 else { return }

        // Save previous enabled state and register tools
        for tool in tools {
            // Save current state (might be nil/false, that's fine)
            previousEnabledState[tool.name] = ToolRegistry.shared.isGlobalEnabled(tool.name)

            // Register and enable
            ToolRegistry.shared.register(tool)
            ToolRegistry.shared.setEnabled(true, for: tool.name)
        }
    }

    /// Unregisters agent-specific tools from the tool registry
    /// Uses reference counting - only unregisters when last session leaves
    /// Call this when leaving Agent Mode
    public func unregisterTools() {
        guard referenceCount > 0 else { return }

        referenceCount -= 1

        // Only unregister when no more references
        guard referenceCount == 0 else { return }

        // Restore previous enabled state and unregister
        for tool in tools {
            // Restore previous state (or disable if wasn't set)
            let wasEnabled = previousEnabledState[tool.name] ?? false
            ToolRegistry.shared.setEnabled(wasEnabled, for: tool.name)
        }

        // Clear saved state
        previousEnabledState.removeAll()

        // Unregister the tools
        ToolRegistry.shared.unregister(names: toolNames)

        // Also unregister folder tools if any
        unregisterFolderTools()
    }

    /// Force unregisters all agent tools regardless of reference count
    /// Use for cleanup during app termination
    public func forceUnregisterAll() {
        guard referenceCount > 0 else { return }

        // Restore previous enabled state
        for tool in tools {
            let wasEnabled = previousEnabledState[tool.name] ?? false
            ToolRegistry.shared.setEnabled(wasEnabled, for: tool.name)
        }

        previousEnabledState.removeAll()
        ToolRegistry.shared.unregister(names: toolNames)
        referenceCount = 0

        // Also unregister folder tools
        unregisterFolderTools()
    }

    // MARK: - Folder Tool Registration

    /// Register folder-specific tools for the given context
    /// Called by AgentFolderContextService when folder is selected
    public func registerFolderTools(for context: AgentFolderContext) {
        // Unregister any existing folder tools first
        unregisterFolderTools()

        currentFolderContext = context

        // Build core tools (always)
        folderTools = AgentFolderToolFactory.buildCoreTools(rootPath: context.rootPath)

        // Add coding tools if known project type
        if context.projectType != .unknown {
            folderTools += AgentFolderToolFactory.buildCodingTools(rootPath: context.rootPath)
        }

        // Add git tools if git repo
        if context.isGitRepo {
            folderTools += AgentFolderToolFactory.buildGitTools(rootPath: context.rootPath)
        }

        // Register and enable all folder tools
        _folderToolNames = folderTools.map { $0.name }
        for tool in folderTools {
            ToolRegistry.shared.register(tool)
            ToolRegistry.shared.setEnabled(true, for: tool.name)
        }

        print("[AgentToolManager] Registered \(folderTools.count) folder tools for \(context.rootPath.lastPathComponent)")
    }

    /// Unregister all folder tools
    /// Called by AgentFolderContextService when folder is cleared
    public func unregisterFolderTools() {
        guard !_folderToolNames.isEmpty else { return }

        print("[AgentToolManager] Unregistering \(_folderToolNames.count) folder tools")

        ToolRegistry.shared.unregister(names: _folderToolNames)
        folderTools = []
        _folderToolNames = []
        currentFolderContext = nil
    }
}
