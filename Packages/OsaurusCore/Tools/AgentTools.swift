//
//  AgentTools.swift
//  osaurus
//
//  Agent-specific tools for task completion, issue creation, and artifact generation.
//

import Foundation

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

// MARK: - Create Issue Tool

/// Tool for creating follow-up issues discovered during execution
public struct CreateIssueTool: OsaurusTool {
    public let name = "create_issue"
    public let description =
        "Create a follow-up issue for work that was discovered but is outside the current task scope. Include detailed context about what you learned so the next execution can pick up without starting from scratch."

    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "title": .object([
                "type": .string("string"),
                "description": .string("Short descriptive title for the issue"),
            ]),
            "description": .object([
                "type": .string("string"),
                "description": .string(
                    "Detailed description with full context. Include: what was discovered, why it's needed, relevant file paths, and any preliminary analysis."
                ),
            ]),
            "reason": .object([
                "type": .string("string"),
                "description": .string("Why this work was discovered/needed"),
            ]),
            "learnings": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("Key things learned that are relevant to this work"),
            ]),
            "relevant_files": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("File paths that are relevant to this issue"),
            ]),
            "priority": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("p0"),
                    .string("p1"),
                    .string("p2"),
                    .string("p3"),
                ]),
                "description": .string("Priority level: p0 (urgent), p1 (high), p2 (medium), p3 (low)"),
            ]),
        ]),
        "required": .array([.string("title"), .string("description")]),
    ])

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        // Parse the arguments
        guard let data = argumentsJSON.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let title = json["title"] as? String,
            let description = json["description"] as? String
        else {
            throw NSError(
                domain: "AgentTools",
                code: 5,
                userInfo: [
                    NSLocalizedDescriptionKey: "Invalid issue format. Required: title (string), description (string)"
                ]
            )
        }

        // Parse optional context fields
        let reason = json["reason"] as? String
        let learnings = json["learnings"] as? [String]
        let relevantFiles = json["relevant_files"] as? [String]

        let priorityStr = json["priority"] as? String ?? "p2"
        let priority: IssuePriority
        switch priorityStr.lowercased() {
        case "p0": priority = .p0
        case "p1": priority = .p1
        case "p3": priority = .p3
        default: priority = .p2
        }

        // Get current issue context for linking
        guard let currentIssueId = AgentExecutionContext.currentIssueId else {
            return """
                Issue creation recorded:
                - Title: \(title)
                - Priority: \(priorityStr.uppercased())
                - Description: \(description.prefix(200))...

                Note: No active execution context. Issue will be created when context is available.
                """
        }

        // Build rich handoff context
        let handoffContext = HandoffContext(
            title: title,
            description: description,
            reason: reason,
            learnings: learnings,
            relevantFiles: relevantFiles,
            constraints: nil,
            priority: priority,
            type: .discovery,
            isDiscoveredWork: true
        )

        // Create the issue with full context
        let newIssue = await IssueManager.shared.createIssueWithContextSafe(
            handoffContext,
            sourceIssueId: currentIssueId
        )

        guard let newIssue = newIssue else {
            return "Error: Failed to create issue. Please try again."
        }

        return """
            Successfully created follow-up issue:
            - ID: \(newIssue.id)
            - Title: \(title)
            - Priority: \(priorityStr.uppercased())
            - Status: Open

            The issue has been linked to the current task for tracking.
            Continue with your current task.
            """
    }
}

// MARK: - Request Clarification Tool

/// Tool for requesting clarification from the user when task is ambiguous
public struct RequestClarificationTool: OsaurusTool {
    public let name = "request_clarification"
    public let description =
        "Ask the user a question when the task is critically ambiguous. Only use this for ambiguities that would lead to wrong results if assumed incorrectly. Do NOT use for minor details or preferences."

    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "question": .object([
                "type": .string("string"),
                "description": .string("Clear, specific question to ask the user"),
            ]),
            "options": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("string")
                ]),
                "description": .string("Optional predefined choices for the user to select from"),
            ]),
            "context": .object([
                "type": .string("string"),
                "description": .string("Brief explanation of why this clarification is needed"),
            ]),
        ]),
        "required": .array([.string("question")]),
    ])

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        // Parse the arguments
        guard let data = argumentsJSON.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let question = json["question"] as? String
        else {
            throw NSError(
                domain: "AgentTools",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Invalid clarification format. Required: question (string)"]
            )
        }

        let options = json["options"] as? [String]
        let context = json["context"] as? String

        // Build response that signals clarification is needed
        var response = """
            Clarification requested:
            Question: \(question)
            """

        if let opts = options, !opts.isEmpty {
            response +=
                "\nOptions:\n" + opts.enumerated().map { "  \($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        }

        if let ctx = context, !ctx.isEmpty {
            response += "\nContext: \(ctx)"
        }

        response += "\n\n---CLARIFICATION_NEEDED---"

        return response
    }
}

// MARK: - Tool Registration

/// Manager for agent-specific tool registration
/// Uses reference counting to support multiple concurrent agent sessions
@MainActor
public final class AgentToolManager {
    public static let shared = AgentToolManager()

    /// Cached tool instances (created once, reused)
    /// Note: SubmitPlanTool and ReportDiscoveryTool removed - no longer used with reasoning loop architecture
    private lazy var tools: [OsaurusTool] = [
        CompleteTaskTool(),
        GenerateArtifactTool(),
        CreateIssueTool(),
        RequestClarificationTool(),
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
    }

    /// Unregister all folder tools
    /// Called by AgentFolderContextService when folder is cleared
    public func unregisterFolderTools() {
        guard !_folderToolNames.isEmpty else { return }
        ToolRegistry.shared.unregister(names: _folderToolNames)
        folderTools = []
        _folderToolNames = []
        currentFolderContext = nil
    }
}
