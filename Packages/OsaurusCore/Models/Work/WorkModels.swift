//
//  WorkModels.swift
//  osaurus
//
//  Data models for Osaurus Agents issue tracking system.
//  Defines Issue, Dependency, Event, and Task structures.
//

import Foundation

// MARK: - Issue Status

/// Status of an issue in the work workflow
public enum IssueStatus: String, Codable, Sendable, CaseIterable {
    /// Issue is ready to be worked on
    case open
    /// Issue is currently being executed
    case inProgress = "in_progress"
    /// Issue is waiting on other issues to complete
    case blocked
    /// Issue has been completed
    case closed

    public var displayName: String {
        switch self {
        case .open: return "Open"
        case .inProgress: return "In Progress"
        case .blocked: return "Blocked"
        case .closed: return "Closed"
        }
    }
}

// MARK: - Issue Priority

/// Priority levels for issues (P0 = most urgent)
public enum IssuePriority: Int, Codable, Sendable, CaseIterable, Comparable {
    case p0 = 0  // Urgent
    case p1 = 1  // High
    case p2 = 2  // Medium (default)
    case p3 = 3  // Low

    public var displayName: String {
        switch self {
        case .p0: return "P0 - Urgent"
        case .p1: return "P1 - High"
        case .p2: return "P2 - Medium"
        case .p3: return "P3 - Low"
        }
    }

    public var shortName: String {
        switch self {
        case .p0: return "P0"
        case .p1: return "P1"
        case .p2: return "P2"
        case .p3: return "P3"
        }
    }

    public static func < (lhs: IssuePriority, rhs: IssuePriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Issue Type

/// Type of issue
public enum IssueType: String, Codable, Sendable, CaseIterable {
    /// Standard work item
    case task
    /// Bug or error to fix
    case bug
    /// Work discovered during execution
    case discovery

    public var displayName: String {
        switch self {
        case .task: return "Task"
        case .bug: return "Bug"
        case .discovery: return "Discovery"
        }
    }
}

// MARK: - Dependency Type

/// Type of relationship between issues
public enum DependencyType: String, Codable, Sendable {
    /// The "from" issue blocks the "to" issue
    /// "to" issue cannot start until "from" is closed
    case blocks
    /// Parent-child relationship (decomposition)
    case parentChild = "parent_child"
    /// Issue was discovered while working on another
    case discoveredFrom = "discovered_from"
}

// MARK: - Issue

/// The fundamental unit of work in Osaurus Agents
public struct Issue: Identifiable, Codable, Sendable, Equatable {
    /// Unique ID (hash-based, e.g., "os-a1b2c3d4")
    public let id: String
    /// ID of the task this issue belongs to
    public let taskId: String
    /// Short title describing the issue
    public var title: String
    /// Detailed description of the work
    public var description: String?
    /// Conversation context from prior interactions
    public var context: String?
    /// Current status
    public var status: IssueStatus
    /// Priority level
    public var priority: IssuePriority
    /// Type of issue
    public var type: IssueType
    /// Result/summary when closed
    public var result: String?
    /// When the issue was created
    public let createdAt: Date
    /// When the issue was last updated
    public var updatedAt: Date

    public init(
        id: String = Issue.generateId(),
        taskId: String,
        title: String,
        description: String? = nil,
        context: String? = nil,
        status: IssueStatus = .open,
        priority: IssuePriority = .p2,
        type: IssueType = .task,
        result: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.taskId = taskId
        self.title = title
        self.description = description
        self.context = context
        self.status = status
        self.priority = priority
        self.type = type
        self.result = result
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Generates a unique issue ID in the format "os-xxxxxxxx"
    public static func generateId() -> String {
        let uuid = UUID().uuidString.lowercased()
        let hash = String(uuid.replacingOccurrences(of: "-", with: "").prefix(8))
        return "os-\(hash)"
    }

    /// Whether this issue can be worked on (open with no blockers)
    /// Note: Actual blocker check requires dependency lookup
    public var isOpen: Bool {
        status == .open
    }

    /// Whether this issue is currently being worked on
    public var isInProgress: Bool {
        status == .inProgress
    }

    /// Whether this issue is complete
    public var isClosed: Bool {
        status == .closed
    }
}

// MARK: - Issue Dependency

/// A relationship between two issues
public struct IssueDependency: Identifiable, Codable, Sendable, Equatable {
    /// Unique ID for this dependency
    public let id: String
    /// The issue that affects another (e.g., the blocker)
    public let fromIssueId: String
    /// The issue being affected (e.g., the blocked issue)
    public let toIssueId: String
    /// Type of dependency relationship
    public let type: DependencyType
    /// When the dependency was created
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        fromIssueId: String,
        toIssueId: String,
        type: DependencyType,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.fromIssueId = fromIssueId
        self.toIssueId = toIssueId
        self.type = type
        self.createdAt = createdAt
    }
}

// MARK: - Issue Event

/// Event types for the audit log
public enum IssueEventType: String, Codable, Sendable {
    case created
    case statusChanged = "status_changed"
    case priorityChanged = "priority_changed"
    case descriptionUpdated = "description_updated"
    case dependencyAdded = "dependency_added"
    case dependencyRemoved = "dependency_removed"
    case executionStarted = "execution_started"
    case executionCompleted = "execution_completed"
    case toolCallExecuted = "tool_call_executed"  // Legacy, no longer created
    case planCreated = "plan_created"  // Legacy, no longer created
    case artifactGenerated = "artifact_generated"
    case clarificationRequested = "clarification_requested"
    case clarificationProvided = "clarification_provided"
    case decomposed
    case discovered
    case closed
    // Reasoning loop events
    case loopIteration = "loop_iteration"
    case toolCallCompleted = "tool_call_completed"
    case noteSaved = "note_saved"
}

/// An event in the issue's history (append-only audit log)
public struct IssueEvent: Identifiable, Codable, Sendable {
    /// Unique ID for this event
    public let id: String
    /// The issue this event belongs to
    public let issueId: String
    /// Type of event
    public let eventType: IssueEventType
    /// Additional event data as JSON
    public var payload: String?
    /// When the event occurred
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        issueId: String,
        eventType: IssueEventType,
        payload: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.issueId = issueId
        self.eventType = eventType
        self.payload = payload
        self.createdAt = createdAt
    }

    /// Creates an event with a Codable payload
    public static func withPayload<T: Encodable>(
        issueId: String,
        eventType: IssueEventType,
        payload: T
    ) -> IssueEvent {
        let encoder = JSONEncoder()
        let payloadString = (try? encoder.encode(payload)).flatMap { String(data: $0, encoding: .utf8) }
        return IssueEvent(issueId: issueId, eventType: eventType, payload: payloadString)
    }
}

// MARK: - Event Payloads

/// Payload types for event logging (enables type-safe JSON encoding)
public enum EventPayload {
    public struct ExecutionCompleted: Codable {
        public let success: Bool
        public let discoveries: Int
        public let summary: String?
        public init(success: Bool, discoveries: Int, summary: String? = nil) {
            self.success = success
            self.discoveries = discoveries
            self.summary = summary
        }
    }

    // Legacy payload types (ToolCall, StepCount, PlanCreated) removed -- waterfall pipeline no longer exists

    public struct ChildCount: Codable {
        public let childCount: Int
        public init(childCount: Int) {
            self.childCount = childCount
        }
    }

    /// Payload for artifact generation events
    public struct ArtifactGenerated: Codable {
        public let artifactId: String
        public let filename: String
        public let contentType: String
        public init(artifactId: String, filename: String, contentType: String) {
            self.artifactId = artifactId
            self.filename = filename
            self.contentType = contentType
        }
    }

    /// Payload for clarification requested events
    public struct ClarificationRequested: Codable {
        public let question: String
        public let options: [String]?
        public let context: String?
        public init(question: String, options: [String]?, context: String?) {
            self.question = question
            self.options = options
            self.context = context
        }
    }

    /// Payload for clarification provided events
    public struct ClarificationProvided: Codable {
        public let question: String
        public let response: String
        public init(question: String, response: String) {
            self.question = question
            self.response = response
        }
    }

    /// Payload for loop iteration events (reasoning loop)
    public struct LoopIteration: Codable {
        public let iteration: Int
        public let toolCallCount: Int
        public let statusMessage: String?
        public init(iteration: Int, toolCallCount: Int, statusMessage: String? = nil) {
            self.iteration = iteration
            self.toolCallCount = toolCallCount
            self.statusMessage = statusMessage
        }
    }

    /// Payload for agent scratchpad notes
    public struct NoteSaved: Codable {
        public let content: String
        public init(content: String) {
            self.content = content
        }
    }

    /// Payload for tool call completed events (reasoning loop)
    public struct ToolCallCompleted: Codable {
        public let toolName: String
        public let iteration: Int
        public let arguments: String?
        public let result: String?
        public let success: Bool
        public init(
            toolName: String,
            iteration: Int,
            arguments: String? = nil,
            result: String? = nil,
            success: Bool = true
        ) {
            self.toolName = toolName
            self.iteration = iteration
            self.arguments = arguments
            self.result = result
            self.success = success
        }
    }
}

// MARK: - Work Task

/// Task status
public enum WorkTaskStatus: String, Codable, Sendable {
    /// Task is currently active
    case active
    /// All issues in task are complete
    case completed
    /// Task was cancelled
    case cancelled
}

/// A task groups issues by the original user query
public struct WorkTask: Identifiable, Codable, Sendable, Equatable {
    /// Unique ID for this task
    public let id: String
    /// Display title (generated from query)
    public var title: String
    /// Original user query that created this task
    public let query: String
    /// Agent this task belongs to (nil = default)
    public var agentId: UUID?
    /// Current status
    public var status: WorkTaskStatus
    /// When the task was created
    public let createdAt: Date
    /// When the task was last updated
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        title: String,
        query: String,
        agentId: UUID? = nil,
        status: WorkTaskStatus = .active,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.query = query
        self.agentId = agentId
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Generates a title from the query
    public static func generateTitle(from query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "New Task" }

        let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
        if firstLine.count <= 50 {
            return firstLine
        }
        return String(firstLine.prefix(47)) + "..."
    }
}

// MARK: - Clarification

/// A clarification request from the AI when the task is ambiguous
public struct ClarificationRequest: Codable, Sendable, Equatable {
    /// The question to ask the user
    public let question: String
    /// Optional predefined options for the user to choose from
    public let options: [String]?
    /// Context explaining why clarification is needed
    public let context: String?

    public init(question: String, options: [String]? = nil, context: String? = nil) {
        self.question = question
        self.options = options
        self.context = context
    }
}

/// State for tracking issues awaiting clarification
public struct AwaitingClarificationState: Codable, Sendable {
    /// The issue ID awaiting clarification
    public let issueId: String
    /// The clarification request
    public let request: ClarificationRequest
    /// When the clarification was requested
    public let timestamp: Date

    public init(issueId: String, request: ClarificationRequest, timestamp: Date = Date()) {
        self.issueId = issueId
        self.request = request
        self.timestamp = timestamp
    }
}

/// Persistent execution state that survives across multiple reasoning-loop runs.
struct WorkExecutionSession: Codable, Sendable {
    let issueId: String
    var messages: [ChatMessage]
    var totalIterations: Int
    var totalToolCalls: Int
    let startedAt: Date
    var lastExitReason: SessionExitReason?

    init(
        issueId: String,
        messages: [ChatMessage],
        totalIterations: Int = 0,
        totalToolCalls: Int = 0,
        startedAt: Date = Date(),
        lastExitReason: SessionExitReason? = nil
    ) {
        self.issueId = issueId
        self.messages = messages
        self.totalIterations = totalIterations
        self.totalToolCalls = totalToolCalls
        self.startedAt = startedAt
        self.lastExitReason = lastExitReason
    }
}

enum SessionExitReason: Codable, Sendable, Equatable {
    case interrupted(userMessage: String?)
    case clarificationRequested(ClarificationRequest)
    case iterationLimitReached
    case completed
    case error(String)
}

enum PersistedExecutionMode: String, Codable, Sendable {
    case hostFolder
    case sandbox
    case none
}

struct PersistedPendingExecutionContext: Codable, Sendable {
    let model: String?
    let systemPrompt: String
    let tools: [Tool]
    let executionMode: PersistedExecutionMode
    let hostFolderRootPath: String?
}

struct PersistedWorkExecutionState: Codable, Sendable {
    let session: WorkExecutionSession
    let pendingContext: PersistedPendingExecutionContext?
    let awaitingClarification: AwaitingClarificationState?
}

// MARK: - Reasoning Loop

/// Result of the reasoning loop execution
enum LoopResult: Sendable {
    /// Task completed successfully
    case completed(summary: String, artifact: SharedArtifact?)
    /// Execution was interrupted between iterations and can resume later.
    case interrupted(messages: [ChatMessage], iteration: Int, totalToolCalls: Int)
    /// Model needs clarification from user
    case needsClarification(
        ClarificationRequest,
        messages: [ChatMessage],
        iteration: Int,
        totalToolCalls: Int
    )
    /// Hit the iteration limit
    case iterationLimitReached(
        messages: [ChatMessage],
        totalIterations: Int,
        totalToolCalls: Int,
        lastResponseContent: String
    )
}

/// Tracks the state of an active reasoning loop (for UI updates)
public struct LoopState: Sendable {
    /// Current iteration number (0-based)
    public var iteration: Int
    /// Total tool calls made so far
    public var toolCallCount: Int
    /// Max iterations allowed
    public let maxIterations: Int
    /// Names of tools called so far (for progress display)
    public var toolsUsed: [String]
    /// Whether the model is currently generating
    public var isGenerating: Bool
    /// Last status message
    public var statusMessage: String?

    public init(
        iteration: Int = 0,
        toolCallCount: Int = 0,
        maxIterations: Int = WorkExecutionEngine.defaultMaxIterations,
        toolsUsed: [String] = [],
        isGenerating: Bool = false,
        statusMessage: String? = nil
    ) {
        self.iteration = iteration
        self.toolCallCount = toolCallCount
        self.maxIterations = maxIterations
        self.toolsUsed = toolsUsed
        self.isGenerating = isGenerating
        self.statusMessage = statusMessage
    }

    /// Progress as a fraction (0.0 to 1.0), capped at 1.0
    public var progress: Double {
        guard maxIterations > 0 else { return 0 }
        return min(1.0, Double(iteration) / Double(maxIterations))
    }
}

// MARK: - Execution Result

/// Result of executing an issue
public struct ExecutionResult: Sendable {
    public enum PauseReason: Sendable, Equatable {
        case interrupted
        case clarificationNeeded(ClarificationRequest)
        case budgetExhausted
    }

    /// The executed issue
    public let issue: Issue
    /// Whether execution was successful
    public let success: Bool
    /// Result message/summary
    public let message: String
    /// Child issues created during execution
    public let childIssues: [Issue]
    /// Final artifact generated by complete_task
    public let artifact: SharedArtifact?
    /// Pending clarification request (execution paused)
    public let awaitingClarification: ClarificationRequest?
    /// Whether execution is paused and can be resumed.
    public let isPaused: Bool
    /// Pause reason when execution is resumable.
    public let pauseReason: PauseReason?

    /// Whether execution is paused awaiting user input
    public var isAwaitingInput: Bool {
        awaitingClarification != nil
    }

    public var canContinue: Bool {
        isPaused
    }

    public init(
        issue: Issue,
        success: Bool,
        message: String,
        childIssues: [Issue] = [],
        artifact: SharedArtifact? = nil,
        awaitingClarification: ClarificationRequest? = nil,
        isPaused: Bool = false,
        pauseReason: PauseReason? = nil
    ) {
        self.issue = issue
        self.success = success
        self.message = message
        self.childIssues = childIssues
        self.artifact = artifact
        self.awaitingClarification = awaitingClarification
        self.isPaused = isPaused
        self.pauseReason = pauseReason
    }
}

// MARK: - Shared Artifact

/// Context type for shared artifacts — either a work task or a chat session.
public enum ArtifactContextType: String, Codable, Sendable {
    case work
    case chat
}

/// A shared artifact handed off by the agent to the user.
/// Supports files (images, HTML, audio, etc.), directories, and inline text content.
public struct SharedArtifact: Identifiable, Codable, Sendable, Equatable {
    /// Unique ID for this artifact
    public let id: String
    /// The owning context — a task ID or chat session ID
    public let contextId: String
    /// Whether this artifact belongs to a work task or chat session
    public let contextType: ArtifactContextType
    /// Display filename (e.g. "result.png", "my-website")
    public let filename: String
    /// MIME type (e.g. "image/png", "text/html", "inode/directory")
    public let mimeType: String
    /// Total size in bytes (sum of all files if directory)
    public let fileSize: Int
    /// Absolute path on the host filesystem (~/.osaurus/artifacts/{contextId}/{filename})
    public let hostPath: String
    /// Whether this artifact is a directory
    public let isDirectory: Bool
    /// Inline text content (stored in DB). Nil for binary files and directories.
    public let content: String?
    /// Human-readable description provided by the agent
    public let description: String?
    /// Whether this is the final result artifact from complete_task
    public let isFinalResult: Bool
    /// When the artifact was created
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        contextId: String,
        contextType: ArtifactContextType,
        filename: String,
        mimeType: String,
        fileSize: Int,
        hostPath: String,
        isDirectory: Bool = false,
        content: String? = nil,
        description: String? = nil,
        isFinalResult: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.contextId = contextId
        self.contextType = contextType
        self.filename = filename
        self.mimeType = mimeType
        self.fileSize = fileSize
        self.hostPath = hostPath
        self.isDirectory = isDirectory
        self.content = content
        self.description = description
        self.isFinalResult = isFinalResult
        self.createdAt = createdAt
    }

    /// Detects MIME type from a filename extension.
    public static func mimeType(from filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js": return "application/javascript"
        case "json": return "application/json"
        case "md", "markdown": return "text/markdown"
        case "txt": return "text/plain"
        case "csv": return "text/csv"
        case "pdf": return "application/pdf"
        case "zip": return "application/zip"
        case "tar": return "application/x-tar"
        case "gz": return "application/gzip"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        case "ogg": return "audio/ogg"
        case "mp4": return "video/mp4"
        case "webm": return "video/webm"
        case "py": return "text/x-python"
        case "swift": return "text/x-swift"
        case "rs": return "text/x-rust"
        case "go": return "text/x-go"
        case "java": return "text/x-java"
        case "c", "h": return "text/x-c"
        case "cpp", "hpp", "cc": return "text/x-c++"
        case "ts": return "text/typescript"
        case "xml": return "application/xml"
        case "yaml", "yml": return "application/x-yaml"
        default: return "application/octet-stream"
        }
    }

    /// Whether this artifact's MIME type indicates an image.
    public var isImage: Bool {
        mimeType.hasPrefix("image/")
    }

    /// Whether this artifact's MIME type indicates audio.
    public var isAudio: Bool {
        mimeType.hasPrefix("audio/")
    }

    /// Whether this artifact's MIME type indicates a text-based format.
    public var isText: Bool {
        mimeType.hasPrefix("text/") || mimeType == "application/json" || mimeType == "application/xml"
            || mimeType == "application/x-yaml"
    }

    /// Whether this artifact is an HTML file or directory containing index.html.
    public var isHTML: Bool {
        mimeType == "text/html"
    }

    /// Whether this artifact's MIME type indicates video.
    public var isVideo: Bool {
        mimeType.hasPrefix("video/")
    }

    /// Whether this artifact is a PDF document.
    public var isPDF: Bool {
        mimeType == "application/pdf"
    }

    /// Human-readable content category label.
    public var categoryLabel: String {
        if isDirectory { return "Directory" }
        if isImage { return "Image" }
        if isPDF { return "PDF" }
        if isAudio { return "Audio" }
        if isVideo { return "Video" }
        if isHTML { return "Web Page" }
        if mimeType == "text/markdown" { return "Markdown" }
        if isText { return "Text" }
        return "File"
    }
}

// MARK: - SharedArtifact Tool Result Processing

extension SharedArtifact {

    static let startMarker = "---SHARED_ARTIFACT_START---\n"
    static let endMarker = "\n---SHARED_ARTIFACT_END---"

    /// Raw parsed content extracted from the marker-delimited region.
    struct ParsedMarkers {
        var metadata: [String: Any]
        let filename: String
        let contentLines: [String]
        let startRange: Range<String.Index>
        let endRange: Range<String.Index>
    }

    /// Result of fully processing a share_artifact tool result.
    struct ProcessingResult {
        let artifact: SharedArtifact
        let enrichedToolResult: String
    }

    /// Extracts marker-delimited metadata and content lines from a tool result string.
    static func parseMarkers(from toolResult: String) -> ParsedMarkers? {
        guard let startRange = toolResult.range(of: startMarker),
            let endRange = toolResult.range(of: endMarker)
        else { return nil }

        let inner = String(toolResult[startRange.upperBound ..< endRange.lowerBound])
        let lines = inner.components(separatedBy: "\n")
        guard let metadataLine = lines.first,
            let data = metadataLine.data(using: .utf8),
            let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let filename = metadata["filename"] as? String
        else { return nil }

        return ParsedMarkers(
            metadata: metadata,
            filename: filename,
            contentLines: Array(lines.dropFirst()),
            startRange: startRange,
            endRange: endRange
        )
    }

    /// Full processing pipeline: parse markers, resolve files, copy to artifacts dir,
    /// persist to DB, and return both the artifact and an enriched tool result string.
    static func processToolResult(
        _ toolResult: String,
        contextId: String,
        contextType: ArtifactContextType,
        executionMode: WorkExecutionMode,
        sandboxAgentName: String? = nil
    ) -> ProcessingResult? {
        guard var parsed = parseMarkers(from: toolResult) else {
            NSLog("[SharedArtifact] parseMarkers failed – markers not found in tool result")
            return nil
        }

        let mimeType = parsed.metadata["mime_type"] as? String ?? "application/octet-stream"
        let description = parsed.metadata["description"] as? String
        let hasContent = parsed.metadata["has_content"] as? Bool ?? false
        let path = parsed.metadata["path"] as? String

        let contextDir = OsaurusPaths.contextArtifactsDir(contextId: contextId)
        OsaurusPaths.ensureExistsSilent(contextDir)
        let destPath = contextDir.appendingPathComponent(parsed.filename)

        // Branch: inline content vs. file-path-based artifact
        let artifact: SharedArtifact
        let contentLines: [String]

        if hasContent {
            let textContent = parsed.contentLines.joined(separator: "\n")
            try? textContent.write(to: destPath, atomically: true, encoding: .utf8)

            artifact = SharedArtifact(
                contextId: contextId,
                contextType: contextType,
                filename: parsed.filename,
                mimeType: mimeType,
                fileSize: textContent.utf8.count,
                hostPath: destPath.path,
                content: textContent,
                description: description,
                isFinalResult: false
            )
            contentLines = parsed.contentLines

        } else if let path {
            guard
                let source = resolveSourcePath(
                    path,
                    executionMode: executionMode,
                    sandboxAgentName: sandboxAgentName
                )
            else {
                NSLog(
                    "[SharedArtifact] Could not resolve '%@' (mode=%@, agent=%@)",
                    path,
                    String(describing: executionMode),
                    sandboxAgentName ?? "nil"
                )
                return nil
            }

            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else {
                NSLog("[SharedArtifact] File not found: %@", source.path)
                return nil
            }
            let isDirectory = isDir.boolValue

            if fm.fileExists(atPath: destPath.path) { try? fm.removeItem(at: destPath) }
            do { try fm.copyItem(at: source, to: destPath) } catch {
                NSLog(
                    "[SharedArtifact] Copy failed %@ → %@: %@",
                    source.path,
                    destPath.path,
                    error.localizedDescription
                )
                return nil
            }

            let fileSize =
                isDirectory
                ? OsaurusPaths.directorySize(at: destPath)
                : (try? fm.attributesOfItem(atPath: destPath.path)[.size] as? Int) ?? 0
            let resolvedMime = isDirectory ? "inode/directory" : mimeType

            artifact = SharedArtifact(
                contextId: contextId,
                contextType: contextType,
                filename: parsed.filename,
                mimeType: resolvedMime,
                fileSize: fileSize,
                hostPath: destPath.path,
                isDirectory: isDirectory,
                description: description,
                isFinalResult: false
            )
            if isDirectory { parsed.metadata["is_directory"] = true; parsed.metadata["mime_type"] = resolvedMime }
            contentLines = []

        } else {
            NSLog("[SharedArtifact] No content and no path in metadata for '\(parsed.filename)'")
            return nil
        }

        // Persist and enrich
        _ = try? IssueStore.createSharedArtifact(artifact)
        parsed.metadata["host_path"] = artifact.hostPath
        parsed.metadata["context_id"] = contextId
        parsed.metadata["context_type"] = contextType.rawValue
        parsed.metadata["file_size"] = artifact.fileSize
        let enriched = rebuildToolResult(toolResult, parsed: parsed, contentLines: contentLines)
        return ProcessingResult(artifact: artifact, enrichedToolResult: enriched)
    }

    /// Reconstructs a SharedArtifact from an enriched tool result string (for display).
    /// Only succeeds when the result has been enriched with host_path, context_id, etc.
    static func fromEnrichedToolResult(_ result: String) -> SharedArtifact? {
        guard let parsed = parseMarkers(from: result) else { return nil }

        let filename = parsed.filename
        let mimeType = parsed.metadata["mime_type"] as? String ?? "application/octet-stream"
        let description = parsed.metadata["description"] as? String
        let hostPath = parsed.metadata["host_path"] as? String ?? ""
        let contextId = parsed.metadata["context_id"] as? String ?? ""
        let contextTypeRaw = parsed.metadata["context_type"] as? String
        let contextType = contextTypeRaw.flatMap(ArtifactContextType.init(rawValue:)) ?? .work
        let fileSize = parsed.metadata["file_size"] as? Int ?? 0
        let isDirectory = parsed.metadata["is_directory"] as? Bool ?? false
        let hasContent = parsed.metadata["has_content"] as? Bool ?? false
        let textContent = hasContent ? parsed.contentLines.joined(separator: "\n") : nil

        return SharedArtifact(
            contextId: contextId,
            contextType: contextType,
            filename: filename,
            mimeType: mimeType,
            fileSize: fileSize > 0 ? fileSize : (textContent?.utf8.count ?? 0),
            hostPath: hostPath,
            isDirectory: isDirectory,
            content: textContent,
            description: description
        )
    }

    /// Best-effort artifact construction from a raw (non-enriched) tool result.
    /// Used as a fallback when `processToolResult` fails (e.g. file can't be copied
    /// from sandbox), so artifact handler plugins still receive metadata.
    static func fromToolResultFallback(
        _ toolResult: String,
        contextId: String,
        contextType: ArtifactContextType
    ) -> SharedArtifact? {
        guard let parsed = parseMarkers(from: toolResult) else { return nil }

        let mimeType = parsed.metadata["mime_type"] as? String ?? "application/octet-stream"
        let description = parsed.metadata["description"] as? String
        let hasContent = parsed.metadata["has_content"] as? Bool ?? false
        let textContent = hasContent ? parsed.contentLines.joined(separator: "\n") : nil

        return SharedArtifact(
            contextId: contextId,
            contextType: contextType,
            filename: parsed.filename,
            mimeType: mimeType,
            fileSize: textContent?.utf8.count ?? 0,
            hostPath: "",
            content: textContent,
            description: description
        )
    }

    // MARK: - Private Helpers

    /// Maps an agent-provided path to the host-side URL, normalizing absolute
    /// in-container paths, `./` prefixes, and falling back to a basename search.
    private static func resolveSourcePath(
        _ path: String,
        executionMode: WorkExecutionMode,
        sandboxAgentName: String?
    ) -> URL? {
        switch executionMode {
        case .sandbox:
            let agent = sandboxAgentName ?? "default"
            let agentDir = OsaurusPaths.containerAgentDir(agent)
            let containerHome = OsaurusPaths.inContainerAgentHome(agent)
            let fm = FileManager.default

            var relativePath = path
            if relativePath.hasPrefix(containerHome + "/") {
                relativePath = String(relativePath.dropFirst(containerHome.count + 1))
            } else if relativePath.hasPrefix("/workspace/") {
                let stripped = String(relativePath.dropFirst("/workspace/".count))
                let candidate = OsaurusPaths.containerWorkspace().appendingPathComponent(stripped)
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
            if relativePath.hasPrefix("./") {
                relativePath = String(relativePath.dropFirst(2))
            }

            let primary = agentDir.appendingPathComponent(relativePath)
            if fm.fileExists(atPath: primary.path) { return primary }

            // Basename fallback in common output subdirectories
            let basename = (path as NSString).lastPathComponent
            for sub in ["output", "out", "build", "dist"] {
                let attempt = agentDir.appendingPathComponent(sub).appendingPathComponent(basename)
                if fm.fileExists(atPath: attempt.path) { return attempt }
            }
            return nil

        case .hostFolder(let ctx):
            return ctx.rootPath.appendingPathComponent(path)

        case .none:
            return nil
        }
    }

    private static func rebuildToolResult(
        _ original: String,
        parsed: ParsedMarkers,
        contentLines: [String]
    ) -> String {
        let prefix = String(original[..<parsed.startRange.upperBound])
        let suffix = String(original[parsed.endRange.lowerBound...])

        var inner = ""
        if let jsonData = try? JSONSerialization.data(withJSONObject: parsed.metadata),
            let jsonStr = String(data: jsonData, encoding: .utf8)
        {
            inner = jsonStr
        }
        if !contentLines.isEmpty {
            inner += "\n" + contentLines.joined(separator: "\n")
        }

        return prefix + inner + suffix
    }
}
