//
//  AgentEngine.swift
//  osaurus
//
//  Main coordinator for Osaurus Agents execution flow.
//  Orchestrates IssueManager and ExecutionEngine via reasoning loop.
//

import Foundation

/// Main coordinator for agent execution
public actor AgentEngine {
    /// The execution engine
    private let executionEngine: AgentExecutionEngine

    /// Current execution state
    private var isExecuting = false
    private var currentIssueId: String?

    /// State for issues awaiting clarification
    private var awaitingClarification: AwaitingClarificationState?

    /// Stored execution context for resuming after clarification
    private var pendingExecutionContext: PendingExecutionContext?

    /// Error states by issue ID
    private var errorStates: [String: IssueErrorState] = [:]

    /// Retry configuration
    private var retryConfig = RetryConfiguration.default

    /// Delegate for execution events
    public nonisolated(unsafe) weak var delegate: AgentEngineDelegate?

    public init() {
        self.executionEngine = AgentExecutionEngine()
    }

    /// Sets the retry configuration
    public func setRetryConfiguration(_ config: RetryConfiguration) {
        self.retryConfig = config
    }

    /// Gets the error state for an issue
    public func errorState(for issueId: String) -> IssueErrorState? {
        return errorStates[issueId]
    }

    /// Clears the error state for an issue
    public func clearErrorState(for issueId: String) {
        errorStates.removeValue(forKey: issueId)
    }

    // MARK: - Delegate

    /// Sets the delegate for receiving execution events
    public nonisolated func setDelegate(_ delegate: AgentEngineDelegate?) {
        self.delegate = delegate
    }

    // MARK: - Entry Points

    /// Creates and executes a task from a user query
    /// - Parameters:
    ///   - query: The user's query/request
    ///   - personaId: Optional persona ID
    ///   - model: Model to use for execution
    ///   - systemPrompt: System prompt to use
    ///   - tools: Available tools
    ///   - toolOverrides: Per-session tool overrides
    ///   - skillCatalog: Available skills for capability selection
    /// - Returns: The execution result
    func run(
        query: String,
        personaId: UUID? = nil,
        model: String?,
        systemPrompt: String,
        tools: [Tool],
        toolOverrides: [String: Bool]? = nil,
        skillCatalog: [CapabilityEntry] = []
    ) async throws -> ExecutionResult {
        guard !isExecuting else {
            throw AgentEngineError.alreadyExecuting
        }

        // Create task and initial issue (IssueManager is @MainActor)
        let task = await IssueManager.shared.createTaskSafe(query: query, personaId: personaId)
        guard let task = task else {
            throw AgentEngineError.noIssueCreated
        }

        // Get the initial issue
        let issues = try IssueStore.listIssues(forTask: task.id)

        guard let issue = issues.first else {
            throw AgentEngineError.noIssueCreated
        }

        return try await execute(
            issue: issue,
            model: model,
            systemPrompt: systemPrompt,
            tools: tools,
            toolOverrides: toolOverrides,
            skillCatalog: skillCatalog
        )
    }

    /// Resumes execution of an existing issue from where it left off
    func resume(
        issueId: String,
        model: String?,
        systemPrompt: String,
        tools: [Tool],
        toolOverrides: [String: Bool]? = nil,
        skillCatalog: [CapabilityEntry] = []
    ) async throws -> ExecutionResult {
        guard !isExecuting else {
            throw AgentEngineError.alreadyExecuting
        }

        guard let issue = try IssueStore.getIssue(id: issueId) else {
            throw AgentEngineError.issueNotFound(issueId)
        }

        return try await execute(
            issue: issue,
            model: model,
            systemPrompt: systemPrompt,
            tools: tools,
            toolOverrides: toolOverrides,
            skillCatalog: skillCatalog,
            attemptResume: true
        )
    }

    /// Executes the next ready issue (highest priority, oldest)
    func next(
        taskId: String? = nil,
        model: String?,
        systemPrompt: String,
        tools: [Tool],
        toolOverrides: [String: Bool]? = nil,
        skillCatalog: [CapabilityEntry] = []
    ) async throws -> ExecutionResult? {
        guard !isExecuting else {
            throw AgentEngineError.alreadyExecuting
        }

        let readyIssues = try IssueStore.readyIssues(forTask: taskId)

        guard let issue = readyIssues.first else {
            return nil  // No ready issues
        }

        return try await execute(
            issue: issue,
            model: model,
            systemPrompt: systemPrompt,
            tools: tools,
            toolOverrides: toolOverrides,
            skillCatalog: skillCatalog
        )
    }

    /// Creates an issue without executing it
    public func create(
        taskId: String,
        title: String,
        description: String? = nil,
        priority: IssuePriority = .p2,
        type: IssueType = .task
    ) async throws -> Issue {
        let issue = await IssueManager.shared.createIssueSafe(
            taskId: taskId,
            title: title,
            description: description,
            priority: priority,
            type: type
        )
        guard let issue = issue else {
            throw AgentEngineError.noIssueCreated
        }
        return issue
    }

    /// Manually closes an issue
    public func close(issueId: String, reason: String) async throws {
        let success = await IssueManager.shared.closeIssueSafe(issueId, result: reason)
        if !success {
            throw AgentEngineError.issueNotFound(issueId)
        }
    }

    /// Cancels the current execution
    public func cancel() async {
        isExecuting = false
        currentIssueId = nil
        awaitingClarification = nil
        pendingExecutionContext = nil
    }

    // MARK: - Clarification

    /// Provides a clarification response and resumes execution
    /// - Parameters:
    ///   - issueId: The issue ID that was awaiting clarification
    ///   - response: The user's response to the clarification question
    /// - Returns: The execution result after resuming
    public func provideClarification(
        issueId: String,
        response: String
    ) async throws -> ExecutionResult {
        // Verify we have a pending clarification for this issue
        guard let awaiting = awaitingClarification, awaiting.issueId == issueId else {
            throw AgentEngineError.noPendingClarification
        }

        guard let context = pendingExecutionContext else {
            throw AgentEngineError.noPendingClarification
        }

        // Log the clarification response
        _ = try? IssueStore.createEvent(
            IssueEvent.withPayload(
                issueId: issueId,
                eventType: .clarificationProvided,
                payload: EventPayload.ClarificationProvided(
                    question: awaiting.request.question,
                    response: response
                )
            )
        )

        // Get and update the issue with clarification context
        guard var issue = try IssueStore.getIssue(id: issueId) else {
            throw AgentEngineError.issueNotFound(issueId)
        }

        // Append clarification to issue description for context
        let clarificationContext = """

            [Clarification]
            Q: \(awaiting.request.question)
            A: \(response)
            """
        issue.description = (issue.description ?? "") + clarificationContext
        try IssueStore.updateIssue(issue)

        // Clear awaiting state
        awaitingClarification = nil
        pendingExecutionContext = nil

        // Re-run execution with enriched context
        return try await execute(
            issue: issue,
            model: context.model,
            systemPrompt: context.systemPrompt,
            tools: context.tools,
            toolOverrides: context.toolOverrides,
            skillCatalog: context.skillCatalog
        )
    }

    /// Checks if there's a pending clarification for an issue
    public func hasPendingClarification(for issueId: String) -> Bool {
        awaitingClarification?.issueId == issueId
    }

    /// Gets the pending clarification request for an issue
    public func getPendingClarification(for issueId: String) -> ClarificationRequest? {
        guard let awaiting = awaitingClarification, awaiting.issueId == issueId else {
            return nil
        }
        return awaiting.request
    }

    // MARK: - Main Execution Flow

    /// Executes an issue through the reasoning loop
    /// - Parameter attemptResume: If true, attempts to recover and resume from prior interrupted execution
    private func execute(
        issue: Issue,
        model: String?,
        systemPrompt: String,
        tools: [Tool],
        toolOverrides: [String: Bool]?,
        skillCatalog: [CapabilityEntry] = [],
        attemptResume: Bool = false
    ) async throws -> ExecutionResult {
        isExecuting = true
        currentIssueId = issue.id

        defer {
            isExecuting = false
            currentIssueId = nil
        }

        // Mark issue as in progress
        _ = await IssueManager.shared.startIssueSafe(issue.id)
        await delegate?.agentEngine(self, didStartIssue: issue)

        // Build initial messages
        var messages: [ChatMessage] = []

        // Add prior context if available (skip internal capability selection markers)
        if let context = issue.context, !context.contains("[Selected Capabilities]") {
            messages.append(ChatMessage(role: "user", content: "[Prior Context]:\n\(context)"))
        }

        // Add the user's query
        messages.append(ChatMessage(role: "user", content: issue.description ?? issue.title))

        // Refresh folder context to ensure the file tree and git status are current
        await AgentFolderContextService.shared.refreshContext()
        let folderContext = await MainActor.run { AgentFolderContextService.shared.currentContext }

        // Set up file operation log with root path for undo support
        if let rootPath = folderContext?.rootPath {
            await AgentFileOperationLog.shared.setRootPath(rootPath)
        }

        // Load skill instructions if any skills are selected
        let skillInstructions = await buildSkillInstructions(from: skillCatalog)

        // Build the agent system prompt using the new method
        let agentSystemPrompt = await executionEngine.buildAgentSystemPrompt(
            base: systemPrompt,
            issue: issue,
            tools: tools,
            folderContext: folderContext,
            skillInstructions: skillInstructions
        )

        // Log execution started
        _ = try? IssueStore.createEvent(
            IssueEvent(
                issueId: issue.id,
                eventType: .executionStarted,
                payload: "{\"mode\":\"reasoning_loop\"}"
            )
        )

        // Load agent generation settings from configuration
        let agentCfg = await ChatConfigurationStore.load()

        // Run the reasoning loop
        let loopResult = try await executionEngine.executeLoop(
            issue: issue,
            messages: &messages,
            systemPrompt: agentSystemPrompt,
            model: model,
            tools: tools,
            toolOverrides: toolOverrides,
            temperature: agentCfg.agentTemperature,
            maxTokens: agentCfg.agentMaxTokens,
            topPOverride: agentCfg.agentTopPOverride,
            maxIterations: agentCfg.agentMaxIterations ?? AgentExecutionEngine.defaultMaxIterations,
            onIterationStart: { [weak self] iteration in
                guard let self = self else { return }
                self.delegate?.agentEngine(self, didStartIteration: iteration, forIssue: issue)
            },
            onDelta: { [weak self] delta, iteration in
                guard let self = self else { return }
                self.delegate?.agentEngine(self, didReceiveStreamingDelta: delta, forStep: iteration)
            },
            onToolCall: { [weak self] toolName, args, result in
                guard let self = self else { return }
                // Notify delegate of tool call
                self.delegate?.agentEngine(
                    self,
                    didCallTool: toolName,
                    withArguments: args,
                    result: result,
                    forIssue: issue
                )
            },
            onStatusUpdate: { [weak self] status in
                guard let self = self else { return }
                self.delegate?.agentEngine(self, didUpdateStatus: status, forIssue: issue)
            },
            onArtifact: { [weak self] artifact in
                guard let self = self else { return }
                // Save the artifact and notify delegate
                _ = try? IssueStore.createArtifact(artifact)
                _ = try? IssueStore.createEvent(
                    IssueEvent.withPayload(
                        issueId: issue.id,
                        eventType: .artifactGenerated,
                        payload: EventPayload.ArtifactGenerated(
                            artifactId: artifact.id,
                            filename: artifact.filename,
                            contentType: artifact.contentType.rawValue
                        )
                    )
                )
                self.delegate?.agentEngine(self, didGenerateArtifact: artifact, forIssue: issue)
            },
            onTokensConsumed: { [weak self] inputTokens, outputTokens in
                guard let self = self else { return }
                self.delegate?.agentEngine(self, didConsumeTokens: inputTokens, output: outputTokens, forIssue: issue)
            }
        )

        // Handle the loop result
        switch loopResult {
        case .completed(let summary, let artifact):
            // Close the issue with success
            _ = await IssueManager.shared.closeIssueSafe(issue.id, result: summary)

            // Save artifact if present
            let finalArtifact = artifact
            if let artifact = artifact {
                _ = try? IssueStore.createArtifact(artifact)

                // Log artifact event
                _ = try? IssueStore.createEvent(
                    IssueEvent.withPayload(
                        issueId: issue.id,
                        eventType: .artifactGenerated,
                        payload: EventPayload.ArtifactGenerated(
                            artifactId: artifact.id,
                            filename: artifact.filename,
                            contentType: artifact.contentType.rawValue
                        )
                    )
                )

                await delegate?.agentEngine(self, didGenerateArtifact: artifact, forIssue: issue)
            }

            // Log execution completed
            _ = try? IssueStore.createEvent(
                IssueEvent.withPayload(
                    issueId: issue.id,
                    eventType: .executionCompleted,
                    payload: EventPayload.ExecutionCompleted(
                        success: true,
                        discoveries: 0,
                        summary: summary
                    )
                )
            )

            await delegate?.agentEngine(self, didCompleteIssue: issue, success: true)

            return ExecutionResult(
                issue: issue,
                success: true,
                message: summary,
                artifact: finalArtifact
            )

        case .needsClarification(let request):
            // Store state for resuming after clarification
            awaitingClarification = AwaitingClarificationState(
                issueId: issue.id,
                request: request,
                timestamp: Date()
            )

            // Store execution context for resuming
            pendingExecutionContext = PendingExecutionContext(
                model: model,
                systemPrompt: systemPrompt,
                tools: tools,
                toolOverrides: toolOverrides,
                skillCatalog: skillCatalog
            )

            // Log clarification requested event
            _ = try? IssueStore.createEvent(
                IssueEvent.withPayload(
                    issueId: issue.id,
                    eventType: .clarificationRequested,
                    payload: EventPayload.ClarificationRequested(
                        question: request.question,
                        options: request.options,
                        context: request.context
                    )
                )
            )

            // Notify delegate
            await delegate?.agentEngine(self, needsClarification: request, forIssue: issue)

            return ExecutionResult(
                issue: issue,
                success: false,
                message: "Awaiting clarification",
                awaitingClarification: request
            )

        case .iterationLimitReached(let totalIterations, let totalToolCalls):
            // Generate a summary of what was accomplished
            let summary =
                "Execution paused after \(totalIterations) iterations and \(totalToolCalls) tool calls. Task may require continuation."

            // Close issue as partial success
            _ = await IssueManager.shared.closeIssueSafe(issue.id, result: "Partial: \(summary)")

            // Log execution completed
            _ = try? IssueStore.createEvent(
                IssueEvent.withPayload(
                    issueId: issue.id,
                    eventType: .executionCompleted,
                    payload: EventPayload.ExecutionCompleted(
                        success: true,
                        discoveries: 0,
                        summary: summary
                    )
                )
            )

            await delegate?.agentEngine(self, didCompleteIssue: issue, success: true)

            return ExecutionResult(
                issue: issue,
                success: true,
                message: summary
            )
        }
    }

    /// Builds skill instructions string from the skill catalog
    @MainActor
    private func buildSkillInstructions(from skillCatalog: [CapabilityEntry]) async -> String? {
        guard !skillCatalog.isEmpty else { return nil }

        // Get active skill names
        let skillNames = skillCatalog.map { $0.name }

        // Load full instructions for active skills
        let skillInstructionsMap = SkillManager.shared.loadInstructions(for: skillNames)

        guard !skillInstructionsMap.isEmpty else { return nil }

        var instructions = ""
        for skillName in skillNames {
            if let content = skillInstructionsMap[skillName] {
                instructions += "## \(skillName)\n\n\(content)\n\n---\n\n"
            }
        }

        return instructions.isEmpty ? nil : instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Retry Logic

    /// Executes an issue with automatic retry on transient failures
    func executeWithRetry(
        issueId: String,
        model: String?,
        systemPrompt: String,
        tools: [Tool],
        toolOverrides: [String: Bool]? = nil,
        skillCatalog: [CapabilityEntry] = []
    ) async throws -> ExecutionResult {
        guard let issue = try IssueStore.getIssue(id: issueId) else {
            throw AgentEngineError.issueNotFound(issueId)
        }

        var lastError: Error?

        for attempt in 0 ..< retryConfig.maxAttempts {
            // Check for cancellation (e.g., window closed)
            guard isExecuting || attempt == 0 else {
                throw AgentEngineError.cancelled
            }
            try Task.checkCancellation()

            // Wait before retry (skip delay on first attempt)
            if attempt > 0 {
                let delay = retryConfig.delay(forAttempt: attempt)
                await delegate?.agentEngine(self, willRetryIssue: issue, attempt: attempt + 1, afterDelay: delay)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            do {
                let result = try await execute(
                    issue: issue,
                    model: model,
                    systemPrompt: systemPrompt,
                    tools: tools,
                    toolOverrides: toolOverrides,
                    skillCatalog: skillCatalog
                )

                // Success - clear any error state
                errorStates.removeValue(forKey: issueId)
                return result

            } catch let error as AgentExecutionError where error.isRetriable {
                lastError = error
                // Track error state
                errorStates[issueId] = IssueErrorState(
                    issueId: issueId,
                    error: error,
                    attemptCount: attempt + 1,
                    lastAttempt: Date(),
                    canRetry: attempt + 1 < retryConfig.maxAttempts
                )
                continue

            } catch {
                // Non-retriable error - fail immediately
                errorStates[issueId] = IssueErrorState(
                    issueId: issueId,
                    error: error,
                    attemptCount: attempt + 1,
                    lastAttempt: Date(),
                    canRetry: false
                )
                throw error
            }
        }

        // Max retries exceeded
        let finalError = AgentEngineError.maxRetriesExceeded(
            underlying: lastError ?? AgentExecutionError.unknown("Unknown error"),
            attempts: retryConfig.maxAttempts
        )
        errorStates[issueId] = IssueErrorState(
            issueId: issueId,
            error: finalError,
            attemptCount: retryConfig.maxAttempts,
            lastAttempt: Date(),
            canRetry: false
        )
        throw finalError
    }

    // MARK: - State

    /// Whether the engine is currently executing
    public func isCurrentlyExecuting() -> Bool {
        isExecuting
    }

    /// Gets the ID of the currently executing issue
    public func getCurrentIssueId() -> String? {
        currentIssueId
    }
}

// MARK: - Delegate Protocol

/// Delegate for receiving agent execution events
@MainActor
public protocol AgentEngineDelegate: AnyObject {
    // Issue lifecycle
    func agentEngine(_ engine: AgentEngine, didStartIssue issue: Issue)
    func agentEngine(_ engine: AgentEngine, didCompleteIssue issue: Issue, success: Bool)

    // Reasoning loop events (new)
    func agentEngine(_ engine: AgentEngine, didStartIteration iteration: Int, forIssue issue: Issue)
    func agentEngine(_ engine: AgentEngine, didReceiveStreamingDelta delta: String, forStep stepIndex: Int)
    func agentEngine(
        _ engine: AgentEngine,
        didCallTool toolName: String,
        withArguments args: String,
        result: String,
        forIssue issue: Issue
    )
    func agentEngine(_ engine: AgentEngine, didUpdateStatus status: String, forIssue issue: Issue)

    // Clarification
    func agentEngine(_ engine: AgentEngine, needsClarification request: ClarificationRequest, forIssue issue: Issue)

    // Artifacts
    func agentEngine(_ engine: AgentEngine, didGenerateArtifact artifact: Artifact, forIssue issue: Issue)

    // Token consumption
    func agentEngine(_ engine: AgentEngine, didConsumeTokens input: Int, output: Int, forIssue issue: Issue)

    // Retry
    func agentEngine(_ engine: AgentEngine, willRetryIssue issue: Issue, attempt: Int, afterDelay: TimeInterval)

}

/// Default implementations for optional delegate methods
extension AgentEngineDelegate {
    // Issue lifecycle
    public func agentEngine(_ engine: AgentEngine, didStartIssue issue: Issue) {}
    public func agentEngine(_ engine: AgentEngine, didCompleteIssue issue: Issue, success: Bool) {}

    // Reasoning loop events
    public func agentEngine(_ engine: AgentEngine, didStartIteration iteration: Int, forIssue issue: Issue) {}
    public func agentEngine(_ engine: AgentEngine, didReceiveStreamingDelta delta: String, forStep stepIndex: Int) {}
    public func agentEngine(
        _ engine: AgentEngine,
        didCallTool toolName: String,
        withArguments args: String,
        result: String,
        forIssue issue: Issue
    ) {}
    public func agentEngine(_ engine: AgentEngine, didUpdateStatus status: String, forIssue issue: Issue) {}

    // Clarification
    public func agentEngine(
        _ engine: AgentEngine,
        needsClarification request: ClarificationRequest,
        forIssue issue: Issue
    ) {}

    // Artifacts
    public func agentEngine(_ engine: AgentEngine, didGenerateArtifact artifact: Artifact, forIssue issue: Issue) {}

    // Token consumption
    public func agentEngine(_ engine: AgentEngine, didConsumeTokens input: Int, output: Int, forIssue issue: Issue) {}

    // Retry
    public func agentEngine(_ engine: AgentEngine, willRetryIssue issue: Issue, attempt: Int, afterDelay: TimeInterval)
    {}

}

// MARK: - Pending Execution Context

/// Stores execution parameters for resuming after clarification
struct PendingExecutionContext {
    let model: String?
    let systemPrompt: String
    let tools: [Tool]
    let toolOverrides: [String: Bool]?
    let skillCatalog: [CapabilityEntry]
}

// MARK: - Errors

/// Errors that can occur in the agent engine
public enum AgentEngineError: Error, LocalizedError {
    case alreadyExecuting
    case issueNotFound(String)
    case noIssueCreated
    case taskNotFound(String)
    case maxRetriesExceeded(underlying: Error, attempts: Int)
    case cancelled
    case noPendingClarification

    public var errorDescription: String? {
        switch self {
        case .alreadyExecuting:
            return "Agent is already executing a task"
        case .issueNotFound(let id):
            return "Issue not found: \(id)"
        case .noIssueCreated:
            return "Failed to create initial issue for task"
        case .taskNotFound(let id):
            return "Task not found: \(id)"
        case .maxRetriesExceeded(let underlying, let attempts):
            return "Failed after \(attempts) attempts: \(underlying.localizedDescription)"
        case .cancelled:
            return "Execution was cancelled"
        case .noPendingClarification:
            return "No pending clarification for this issue"
        }
    }

    /// Whether this error is retriable
    public var isRetriable: Bool {
        switch self {
        case .alreadyExecuting, .cancelled, .noPendingClarification:
            return false
        case .issueNotFound, .noIssueCreated, .taskNotFound:
            return false
        case .maxRetriesExceeded:
            return false
        }
    }
}

/// Configuration for retry behavior
public struct RetryConfiguration: Sendable {
    /// Maximum number of retry attempts
    public let maxAttempts: Int
    /// Base delay between retries (seconds)
    public let baseDelay: TimeInterval
    /// Maximum delay between retries (seconds)
    public let maxDelay: TimeInterval
    /// Multiplier for exponential backoff
    public let backoffMultiplier: Double

    public static let `default` = RetryConfiguration(
        maxAttempts: 3,
        baseDelay: 1.0,
        maxDelay: 30.0,
        backoffMultiplier: 2.0
    )

    public static let none = RetryConfiguration(
        maxAttempts: 1,
        baseDelay: 0,
        maxDelay: 0,
        backoffMultiplier: 1.0
    )

    public init(maxAttempts: Int, baseDelay: TimeInterval, maxDelay: TimeInterval, backoffMultiplier: Double) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.backoffMultiplier = backoffMultiplier
    }

    /// Calculates delay for a given attempt number (0-indexed)
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        let delay = baseDelay * pow(backoffMultiplier, Double(attempt - 1))
        return min(delay, maxDelay)
    }
}

/// Tracks error state for an issue
public struct IssueErrorState: Sendable {
    public let issueId: String
    public let error: Error
    public let attemptCount: Int
    public let lastAttempt: Date
    public let canRetry: Bool

    public init(issueId: String, error: Error, attemptCount: Int, lastAttempt: Date, canRetry: Bool) {
        self.issueId = issueId
        self.error = error
        self.attemptCount = attemptCount
        self.lastAttempt = lastAttempt
        self.canRetry = canRetry
    }
}
