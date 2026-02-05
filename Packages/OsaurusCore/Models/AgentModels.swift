//
//  AgentModels.swift
//  osaurus
//
//  Data models for Osaurus Agents issue tracking system.
//  Defines Issue, Dependency, Event, and Task structures.
//

import Foundation

// MARK: - Issue Status

/// Status of an issue in the agent workflow
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
    case toolCallExecuted = "tool_call_executed"
    case planCreated = "plan_created"
    case artifactGenerated = "artifact_generated"
    case clarificationRequested = "clarification_requested"
    case clarificationProvided = "clarification_provided"
    case decomposed
    case discovered
    case closed
    // Reasoning loop events
    case loopIteration = "loop_iteration"
    case toolCallCompleted = "tool_call_completed"
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

    /// Enhanced tool call payload with arguments and result
    public struct ToolCall: Codable {
        public let tool: String
        public let step: Int
        public let arguments: String?
        public let result: String?
        public init(tool: String, step: Int, arguments: String? = nil, result: String? = nil) {
            self.tool = tool
            self.step = step
            self.arguments = arguments
            self.result = result
        }
    }

    /// Legacy step count (for backward compatibility)
    public struct StepCount: Codable {
        public let stepCount: Int
        public init(stepCount: Int) {
            self.stepCount = stepCount
        }
    }

    /// Enhanced plan payload with full step details
    public struct PlanCreated: Codable {
        public let steps: [PlanStepData]
        public init(steps: [PlanStepData]) {
            self.steps = steps
        }

        public struct PlanStepData: Codable {
            public let stepNumber: Int
            public let description: String
            public let toolName: String?
            public init(stepNumber: Int, description: String, toolName: String?) {
                self.stepNumber = stepNumber
                self.description = description
                self.toolName = toolName
            }
        }
    }

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

// MARK: - Agent Task

/// Task status
public enum AgentTaskStatus: String, Codable, Sendable {
    /// Task is currently active
    case active
    /// All issues in task are complete
    case completed
    /// Task was cancelled
    case cancelled
}

/// A task groups issues by the original user query
public struct AgentTask: Identifiable, Codable, Sendable, Equatable {
    /// Unique ID for this task
    public let id: String
    /// Display title (generated from query)
    public var title: String
    /// Original user query that created this task
    public let query: String
    /// Persona this task belongs to (nil = default)
    public var personaId: UUID?
    /// Current status
    public var status: AgentTaskStatus
    /// When the task was created
    public let createdAt: Date
    /// When the task was last updated
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        title: String,
        query: String,
        personaId: UUID? = nil,
        status: AgentTaskStatus = .active,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.query = query
        self.personaId = personaId
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

// MARK: - Execution Plan (DEPRECATED)

/// A step in an execution plan
/// - Note: DEPRECATED - Waterfall pipeline removed. Kept for backward compatibility.
@available(*, deprecated, message: "Waterfall pipeline removed. Use reasoning loop instead.")
public struct PlanStep: Codable, Sendable, Equatable {
    /// Step number (1-based)
    public let stepNumber: Int
    /// Description of what this step does
    public let description: String
    /// Tool to use (if any)
    public var toolName: String?
    /// Whether this step is complete
    public var isComplete: Bool

    public init(
        stepNumber: Int,
        description: String,
        toolName: String? = nil,
        isComplete: Bool = false
    ) {
        self.stepNumber = stepNumber
        self.description = description
        self.toolName = toolName
        self.isComplete = isComplete
    }
}

/// An execution plan for an issue
/// - Note: DEPRECATED - Waterfall pipeline removed. Kept for backward compatibility.
@available(*, deprecated, message: "Waterfall pipeline removed. Use reasoning loop instead.")
public struct ExecutionPlan: Codable, Sendable {
    /// The issue this plan is for
    public let issueId: String
    /// Steps to execute
    public var steps: [PlanStep]
    /// Maximum allowed tool calls
    public let maxToolCalls: Int
    /// Current tool call count
    public var toolCallCount: Int
    /// Selected tools for this task (from capability selection)
    public let selectedTools: [String]
    /// Selected skills for this task (from capability selection)
    public let selectedSkills: [String]

    /// Default maximum tool calls per issue execution
    public static let defaultMaxToolCalls = 10

    public init(
        issueId: String,
        steps: [PlanStep] = [],
        maxToolCalls: Int = ExecutionPlan.defaultMaxToolCalls,
        toolCallCount: Int = 0,
        selectedTools: [String] = [],
        selectedSkills: [String] = []
    ) {
        self.issueId = issueId
        self.steps = steps
        self.maxToolCalls = maxToolCalls
        self.toolCallCount = toolCallCount
        self.selectedTools = selectedTools
        self.selectedSkills = selectedSkills
    }

    /// Whether the plan exceeds the tool call limit
    public var exceedsLimit: Bool {
        steps.count > maxToolCalls
    }

    /// Whether we've reached the tool call limit
    public var isAtLimit: Bool {
        toolCallCount >= maxToolCalls
    }

    /// Number of completed steps
    public var completedSteps: Int {
        steps.filter { $0.isComplete }.count
    }

    /// Progress as a fraction (0.0 to 1.0)
    public var progress: Double {
        guard !steps.isEmpty else { return 0 }
        return Double(completedSteps) / Double(steps.count)
    }
}

// MARK: - Capability Selection Context (DEPRECATED)

/// Context for storing selected capabilities in child issues
/// When a task is decomposed, child issues inherit the parent's capability selection
/// - Note: DEPRECATED - Waterfall pipeline removed. Kept for backward compatibility.
@available(*, deprecated, message: "Waterfall pipeline removed. Use reasoning loop instead.")
public struct SelectedCapabilitiesContext: Codable, Sendable {
    /// Selected tools for this task
    public let selectedTools: [String]
    /// Selected skills for this task
    public let selectedSkills: [String]

    public init(selectedTools: [String] = [], selectedSkills: [String] = []) {
        self.selectedTools = selectedTools
        self.selectedSkills = selectedSkills
    }

    /// Parse capability context from an issue's context string (JSON)
    public static func parse(from context: String?) -> SelectedCapabilitiesContext? {
        guard let context = context,
            let data = context.data(using: .utf8)
        else {
            return nil
        }
        return try? JSONDecoder().decode(SelectedCapabilitiesContext.self, from: data)
    }
}

// MARK: - Clarification

/// A clarification request from the agent when the task is ambiguous
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
public struct AwaitingClarificationState: Sendable {
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

// MARK: - Reasoning Loop

/// Result of the reasoning loop execution
public enum LoopResult: Sendable {
    /// Task completed successfully
    case completed(summary: String, artifact: Artifact?)
    /// Model needs clarification from user
    case needsClarification(ClarificationRequest)
    /// Hit the iteration limit
    case iterationLimitReached(totalIterations: Int, totalToolCalls: Int)
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
        maxIterations: Int = 30,
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

// MARK: - Discovery (DEPRECATED)

/// A discovered piece of work
/// - Note: DEPRECATED - Waterfall pipeline removed. Use create_issue tool instead.
@available(*, deprecated, message: "Waterfall pipeline removed. Use create_issue tool instead.")
public struct Discovery: Codable, Sendable {
    /// Type of discovery
    public enum DiscoveryType: String, Codable, Sendable {
        case error
        case todo
        case fixme
        case prerequisite
        case followUp = "follow_up"
    }

    /// Type of discovery
    public let type: DiscoveryType
    /// Title for the discovered issue
    public let title: String
    /// Description of the discovery
    public let description: String?
    /// Source context (e.g., file path, tool output)
    public let source: String?
    /// Suggested priority
    public let suggestedPriority: IssuePriority

    public init(
        type: DiscoveryType,
        title: String,
        description: String? = nil,
        source: String? = nil,
        suggestedPriority: IssuePriority = .p2
    ) {
        self.type = type
        self.title = title
        self.description = description
        self.source = source
        self.suggestedPriority = suggestedPriority
    }
}

// MARK: - Execution Result

/// Result of executing an issue
public struct ExecutionResult: Sendable {
    /// The executed issue
    public let issue: Issue
    /// Whether execution was successful
    public let success: Bool
    /// Result message/summary
    public let message: String
    /// Discoveries made during execution
    public let discoveries: [Discovery]
    /// Child issues created (from decomposition)
    public let childIssues: [Issue]
    /// Final artifact generated by complete_task
    public let artifact: Artifact?
    /// Pending clarification request (execution paused)
    public let awaitingClarification: ClarificationRequest?

    /// Whether execution is paused awaiting user input
    public var isAwaitingInput: Bool {
        awaitingClarification != nil
    }

    public init(
        issue: Issue,
        success: Bool,
        message: String,
        discoveries: [Discovery] = [],
        childIssues: [Issue] = [],
        artifact: Artifact? = nil,
        awaitingClarification: ClarificationRequest? = nil
    ) {
        self.issue = issue
        self.success = success
        self.message = message
        self.discoveries = discoveries
        self.childIssues = childIssues
        self.artifact = artifact
        self.awaitingClarification = awaitingClarification
    }
}

// MARK: - Artifact

/// Content type for artifacts
public enum ArtifactContentType: String, Codable, Sendable {
    case markdown
    case text
}

/// An artifact generated by the agent (final result or downloadable file)
public struct Artifact: Identifiable, Codable, Sendable, Equatable {
    /// Unique ID for this artifact
    public let id: String
    /// The task this artifact belongs to
    public let taskId: String
    /// Filename for the artifact (e.g., "result.md", "summary.txt")
    public let filename: String
    /// The content of the artifact
    public let content: String
    /// Content type (markdown or text)
    public let contentType: ArtifactContentType
    /// Whether this is the final completion artifact
    public let isFinalResult: Bool
    /// When the artifact was created
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        taskId: String,
        filename: String,
        content: String,
        contentType: ArtifactContentType = .markdown,
        isFinalResult: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.taskId = taskId
        self.filename = filename
        self.content = content
        self.contentType = contentType
        self.isFinalResult = isFinalResult
        self.createdAt = createdAt
    }

    /// Determines content type from filename extension
    public static func contentType(from filename: String) -> ArtifactContentType {
        if filename.lowercased().hasSuffix(".md") || filename.lowercased().hasSuffix(".markdown") {
            return .markdown
        }
        return .text
    }
}
