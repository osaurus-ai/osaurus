//
//  WorkEngine.swift
//  osaurus
//
//  Main coordinator for Osaurus Agents execution flow.
//  Orchestrates IssueManager and ExecutionEngine via reasoning loop.
//

import Foundation

/// Main coordinator for work execution
public actor WorkEngine {
    static let freshBudgetContinuation = "Continue with the task. You have a fresh iteration budget."

    /// The execution engine
    private let executionEngine: WorkExecutionEngine

    /// Current execution state
    private var isExecuting = false
    private var activeSession: WorkExecutionSession?
    private var interruptRequested = false

    /// State for issues awaiting clarification
    private var awaitingClarification: AwaitingClarificationState?

    /// Stored execution context for resuming after clarification
    private var pendingExecutionContext: PendingExecutionContext?

    /// Error states by issue ID
    private var errorStates: [String: IssueErrorState] = [:]

    /// Retry configuration
    private var retryConfig = RetryConfiguration.default

    /// Sandbox agent name for path resolution in share_artifact processing.
    /// Set by WorkSession before execution when running in sandbox mode.
    public nonisolated(unsafe) var sandboxAgentName: String?

    /// Agent UUID for execution context binding. Set by WorkSession.
    public nonisolated(unsafe) var agentId: UUID?

    /// Delegate for execution events
    public nonisolated(unsafe) weak var delegate: WorkEngineDelegate?

    public init() {
        self.executionEngine = WorkExecutionEngine()
    }

    init(executionEngine: WorkExecutionEngine) {
        self.executionEngine = executionEngine
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
    public nonisolated func setDelegate(_ delegate: WorkEngineDelegate?) {
        self.delegate = delegate
    }

    // MARK: - Entry Points

    /// Creates and executes a task from a user query
    /// - Parameters:
    ///   - query: The user's query/request
    ///   - agentId: Optional agent ID
    ///   - model: Model to use for execution
    ///   - systemPrompt: System prompt to use
    ///   - tools: Available tools
    /// - Returns: The execution result
    func run(
        query: String,
        agentId: UUID? = nil,
        model: String?,
        systemPrompt: String,
        tools: [Tool],
        executionMode: WorkExecutionMode
    ) async throws -> ExecutionResult {
        guard !isExecuting else {
            throw WorkEngineError.alreadyExecuting
        }

        // Create task and initial issue (IssueManager is @MainActor)
        let task = await IssueManager.shared.createTaskSafe(query: query, agentId: agentId)
        guard let task = task else {
            throw WorkEngineError.noIssueCreated
        }

        // Get the initial issue
        let issues = try IssueStore.listIssues(forTask: task.id)

        guard let issue = issues.first else {
            throw WorkEngineError.noIssueCreated
        }

        return try await execute(
            issue: issue,
            model: model,
            systemPrompt: systemPrompt,
            tools: tools,
            executionMode: executionMode
        )
    }

    /// Resumes execution of an existing issue from where it left off
    func resume(
        issueId: String,
        model: String?,
        systemPrompt: String,
        tools: [Tool],
        executionMode: WorkExecutionMode,
        cacheHint: String? = nil,
        staticPrefix: String? = nil
    ) async throws -> ExecutionResult {
        guard !isExecuting else {
            throw WorkEngineError.alreadyExecuting
        }

        guard let issue = try IssueStore.getIssue(id: issueId) else {
            throw WorkEngineError.issueNotFound(issueId)
        }

        return try await execute(
            issue: issue,
            model: model,
            systemPrompt: systemPrompt,
            tools: tools,
            executionMode: executionMode,
            attemptResume: true,
            cacheHint: cacheHint,
            staticPrefix: staticPrefix
        )
    }

    /// Executes the next ready issue (highest priority, oldest)
    func next(
        taskId: String? = nil,
        model: String?,
        systemPrompt: String,
        tools: [Tool],
        executionMode: WorkExecutionMode
    ) async throws -> ExecutionResult? {
        guard !isExecuting else {
            throw WorkEngineError.alreadyExecuting
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
            executionMode: executionMode
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
            throw WorkEngineError.noIssueCreated
        }
        return issue
    }

    /// Manually closes an issue
    public func close(issueId: String, reason: String) async throws {
        let success = await IssueManager.shared.closeIssueSafe(issueId, result: reason)
        if !success {
            throw WorkEngineError.issueNotFound(issueId)
        }
    }

    /// Cancels the current execution
    public func cancel() async {
        let issueId = activeSession?.issueId
        isExecuting = false
        interruptRequested = false
        activeSession = nil
        awaitingClarification = nil
        pendingExecutionContext = nil
        clearPersistedExecutionState(issueId: issueId)
    }

    /// Interrupts the current execution, preserving session state.
    public func interrupt() async {
        guard activeSession != nil else { return }
        interruptRequested = true
    }

    public func continueExecution(message: String? = nil) async throws -> ExecutionResult {
        guard var session = activeSession else {
            throw WorkEngineError.noActiveSession
        }

        injectSavedNotesIfNeeded(into: &session)

        if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendUserMessage(
                to: &session,
                content: "[User guidance]: \(message)\n\nContinue with the task."
            )
            session.lastExitReason = .interrupted(userMessage: message)
        } else {
            appendUserMessage(
                to: &session,
                content: Self.freshBudgetContinuation
            )
        }
        activeSession = session
        persistExecutionStateIfPossible()
        return try await resumeActiveSession()
    }

    public func redirect(message: String) async throws -> ExecutionResult {
        if isExecuting && !interruptRequested {
            interruptRequested = true
            while isExecuting {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }

        guard var session = activeSession else {
            throw WorkEngineError.noActiveSession
        }

        appendUserMessage(to: &session, content: "[User redirect]: \(message)")
        session.lastExitReason = .interrupted(userMessage: message)
        activeSession = session
        persistExecutionStateIfPossible()
        return try await resumeActiveSession()
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
        if awaitingClarification?.issueId != issueId || pendingExecutionContext == nil {
            _ = await restorePersistedSessionIfNeeded(for: issueId)
        }
        guard let awaiting = awaitingClarification, awaiting.issueId == issueId else {
            throw WorkEngineError.noPendingClarification
        }
        guard var session = activeSession, session.issueId == issueId else {
            throw WorkEngineError.noActiveSession
        }

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

        injectSavedNotesIfNeeded(into: &session)

        session.messages.append(
            ChatMessage(
                role: "user",
                content: """
                    [Clarification response]
                    Q: \(awaiting.request.question)
                    A: \(response)

                    Continue with the task using this information.
                    """
            )
        )
        activeSession = session

        awaitingClarification = nil
        persistExecutionStateIfPossible()
        return try await resumeActiveSession()
    }

    /// Checks if there's a pending clarification for an issue
    public func hasPendingClarification(for issueId: String) -> Bool {
        loadPersistedClarificationIfNeeded(for: issueId)
        return awaitingClarification?.issueId == issueId
    }

    /// Gets the pending clarification request for an issue
    public func getPendingClarification(for issueId: String) -> ClarificationRequest? {
        loadPersistedClarificationIfNeeded(for: issueId)
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
        executionMode: WorkExecutionMode,
        images: [Data] = [],
        attemptResume: Bool = false,
        cacheHint: String? = nil,
        staticPrefix: String? = nil
    ) async throws -> ExecutionResult {
        isExecuting = true
        interruptRequested = false

        defer {
            isExecuting = false
            interruptRequested = false
        }

        // Mark issue as in progress
        _ = await IssueManager.shared.startIssueSafe(issue.id)
        await delegate?.workEngine(self, didStartIssue: issue)

        let resolvedExecutionMode: WorkExecutionMode
        switch executionMode {
        case .hostFolder:
            await WorkFolderContextService.shared.refreshContext()
            let refreshedContext = await MainActor.run { WorkFolderContextService.shared.currentContext }
            resolvedExecutionMode = refreshedContext.map(WorkExecutionMode.hostFolder) ?? .none
        case .sandbox, .none:
            resolvedExecutionMode = executionMode
        }

        // Set up file operation log with root path for undo support in host-folder mode.
        if let rootPath = resolvedExecutionMode.folderContext?.rootPath {
            await WorkFileOperationLog.shared.setRootPath(rootPath)
        }

        let initialMessages =
            if attemptResume,
                let existing = activeSession,
                existing.issueId == issue.id
            {
                existing.messages
            } else {
                buildInitialMessages(issue: issue, images: images, executionMode: resolvedExecutionMode)
            }
        activeSession =
            if attemptResume,
                let existing = activeSession,
                existing.issueId == issue.id
            {
                existing
            } else {
                WorkExecutionSession(issueId: issue.id, messages: initialMessages)
            }

        let agentSystemPrompt = systemPrompt
        let agentCacheHint = cacheHint
        let agentStaticPrefix = staticPrefix

        // Log execution started
        _ = try? IssueStore.createEvent(
            IssueEvent(
                issueId: issue.id,
                eventType: .executionStarted,
                payload: "{\"mode\":\"reasoning_loop\"}"
            )
        )

        // Load work generation settings from configuration
        let agentCfg = await ChatConfigurationStore.load()

        // Resolve model context length for budget management.
        // Priority: local model config > user chat config > default (128k).
        let resolvedContextLength: Int
        if let m = model, let info = ModelInfo.load(modelId: m),
            let ctx = info.model.contextLength
        {
            resolvedContextLength = ctx
        } else {
            resolvedContextLength = agentCfg.contextLength ?? 128_000
        }

        // Estimate token overhead for tool definitions
        let toolTokenEstimate = await ToolRegistry.shared.totalEstimatedTokens(for: tools)

        pendingExecutionContext = PendingExecutionContext(
            model: model,
            systemPrompt: systemPrompt,
            tools: tools,
            executionMode: resolvedExecutionMode
        )

        var messages = activeSession?.messages ?? initialMessages

        // Run the reasoning loop
        let loopResult: LoopResult
        do {
            loopResult = try await executionEngine.executeLoop(
                issue: issue,
                messages: &messages,
                systemPrompt: agentSystemPrompt,
                model: model,
                tools: tools,
                temperature: agentCfg.workTemperature,
                maxTokens: agentCfg.workMaxTokens,
                topPOverride: agentCfg.workTopPOverride,
                contextLength: resolvedContextLength,
                toolTokenEstimate: toolTokenEstimate,
                maxIterations: agentCfg.workMaxIterations ?? WorkExecutionEngine.defaultMaxIterations,
                executionMode: resolvedExecutionMode,
                sandboxAgentName: sandboxAgentName,
                agentId: agentId,
                cacheHint: agentCacheHint,
                staticPrefix: agentStaticPrefix,
                shouldInterrupt: { await self.shouldInterruptExecution(for: issue.id) },
                onIterationStart: { [weak self] iteration in
                    guard let self = self else { return }
                    self.delegate?.workEngine(self, didStartIteration: iteration, forIssue: issue)
                },
                onDelta: { [weak self] delta, iteration in
                    guard let self = self else { return }
                    self.delegate?.workEngine(self, didReceiveStreamingDelta: delta, forStep: iteration)
                },
                onToolHint: { [weak self] toolName in
                    guard let self = self else { return }
                    self.delegate?.workEngine(self, didDetectPendingTool: toolName, forIssue: issue)
                },
                onToolArgHint: { [weak self] argFragment in
                    guard let self = self else { return }
                    self.delegate?.workEngine(self, didReceiveToolArgFragment: argFragment, forIssue: issue)
                },
                onToolCall: { [weak self] toolName, args, result in
                    guard let self = self else { return }
                    self.delegate?.workEngine(
                        self,
                        didCallTool: toolName,
                        withArguments: args,
                        result: result,
                        forIssue: issue
                    )
                },
                onStatusUpdate: { [weak self] status in
                    guard let self = self else { return }
                    self.delegate?.workEngine(self, didUpdateStatus: status, forIssue: issue)
                },
                onArtifact: { [weak self] artifact in
                    guard let self = self else { return }
                    _ = try? IssueStore.createEvent(
                        IssueEvent.withPayload(
                            issueId: issue.id,
                            eventType: .artifactGenerated,
                            payload: EventPayload.ArtifactGenerated(
                                artifactId: artifact.id,
                                filename: artifact.filename,
                                contentType: artifact.mimeType
                            )
                        )
                    )
                    self.delegate?.workEngine(self, didShareArtifact: artifact, forIssue: issue)
                },
                onTokensConsumed: { [weak self] inputTokens, outputTokens in
                    guard let self = self else { return }
                    self.delegate?.workEngine(
                        self,
                        didConsumeTokens: inputTokens,
                        output: outputTokens,
                        forIssue: issue
                    )
                },
                onSecretPrompt: { [weak self] prompt in
                    guard let self = self else { return nil }
                    return await self.delegate?.workEngine(self, needsSecret: prompt)
                }
            )
        } catch {
            if activeSession?.issueId == issue.id {
                activeSession?.messages = messages
                activeSession?.lastExitReason = .error(error.localizedDescription)
                persistExecutionStateIfPossible()
            }
            throw error
        }

        // Handle the loop result
        switch loopResult {
        case .completed(let summary, let artifact, let status):
            activeSession?.messages = messages
            activeSession?.lastExitReason = .completed
            let isSuccessfulCompletion = status.isSuccessfulCompletion

            switch status {
            case .verified:
                _ = await IssueManager.shared.closeIssueSafe(issue.id, result: summary)
            case .partial:
                _ = await IssueManager.shared.updateIssueStatusSafe(issue.id, to: .open)
            case .blocked:
                _ = await IssueManager.shared.updateIssueStatusSafe(issue.id, to: .blocked)
            }

            let finalIssue = (try? IssueStore.getIssue(id: issue.id)) ?? issue

            let finalArtifact = artifact
            if let artifact = artifact {
                _ = try? IssueStore.createEvent(
                    IssueEvent.withPayload(
                        issueId: issue.id,
                        eventType: .artifactGenerated,
                        payload: EventPayload.ArtifactGenerated(
                            artifactId: artifact.id,
                            filename: artifact.filename,
                            contentType: artifact.mimeType
                        )
                    )
                )

                await delegate?.workEngine(self, didShareArtifact: artifact, forIssue: issue)
            }

            // Log execution completed
            _ = try? IssueStore.createEvent(
                IssueEvent.withPayload(
                    issueId: issue.id,
                    eventType: .executionCompleted,
                    payload: EventPayload.ExecutionCompleted(
                        success: isSuccessfulCompletion,
                        discoveries: 0,
                        summary: summary
                    )
                )
            )

            await delegate?.workEngine(
                self,
                didCompleteIssue: finalIssue,
                success: isSuccessfulCompletion
            )
            clearPersistedExecutionState(issueId: issue.id)

            activeSession = nil
            awaitingClarification = nil
            pendingExecutionContext = nil

            return ExecutionResult(
                issue: finalIssue,
                success: isSuccessfulCompletion,
                message: summary,
                artifact: finalArtifact,
                completionStatus: status
            )

        case .interrupted(let resumedMessages, let iteration, let totalToolCalls):
            updateActiveSession(
                issueId: issue.id,
                messages: resumedMessages,
                iteration: iteration,
                toolCalls: totalToolCalls,
                exitReason: .interrupted(userMessage: nil)
            )
            awaitingClarification = nil
            persistExecutionStateIfPossible()
            await delegate?.workEngine(self, didInterruptIssue: issue)
            return ExecutionResult(
                issue: issue,
                success: false,
                message: "Execution paused",
                isPaused: true,
                pauseReason: .interrupted
            )

        case .needsClarification(let request, let resumedMessages, let iteration, let totalToolCalls):
            updateActiveSession(
                issueId: issue.id,
                messages: resumedMessages,
                iteration: iteration,
                toolCalls: totalToolCalls,
                exitReason: .clarificationRequested(request)
            )
            awaitingClarification = AwaitingClarificationState(
                issueId: issue.id,
                request: request,
                timestamp: Date()
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
            await delegate?.workEngine(self, needsClarification: request, forIssue: issue)
            persistExecutionStateIfPossible()

            return ExecutionResult(
                issue: issue,
                success: false,
                message: "Awaiting clarification",
                awaitingClarification: request,
                isPaused: true,
                pauseReason: .clarificationNeeded(request)
            )

        case .iterationLimitReached(let resumedMessages, let totalIterations, let totalToolCalls, _):
            updateActiveSession(
                issueId: issue.id,
                messages: resumedMessages,
                iteration: totalIterations,
                toolCalls: totalToolCalls,
                exitReason: .iterationLimitReached
            )
            let summary =
                "Budget exhausted after \(totalIterations) iterations and \(totalToolCalls) tool calls."
            persistExecutionStateIfPossible()
            await delegate?.workEngine(self, didExhaustBudget: issue, summary: summary)

            return ExecutionResult(
                issue: issue,
                success: false,
                message: summary,
                isPaused: true,
                pauseReason: .budgetExhausted
            )
        }
    }

    private func buildInitialMessages(issue: Issue, images: [Data], executionMode: WorkExecutionMode) -> [ChatMessage] {
        var messages: [ChatMessage] = []

        var firstMessageContent = ""

        switch executionMode {
        case .hostFolder(let ctx):
            firstMessageContent += WorkExecutionEngine.buildFolderContextSection(from: ctx)
        default:
            break
        }

        if let context = issue.context {
            firstMessageContent += "\n[Prior Context]:\n\(context)\n"
        }

        firstMessageContent += "\n**Goal:** \(issue.title)\n"
        if let desc = issue.description {
            firstMessageContent += "\(desc)\n"
        }

        if images.isEmpty {
            messages.append(
                ChatMessage(role: "user", content: firstMessageContent.trimmingCharacters(in: .whitespacesAndNewlines))
            )
        } else {
            messages.append(
                ChatMessage(
                    role: "user",
                    text: firstMessageContent.trimmingCharacters(in: .whitespacesAndNewlines),
                    imageData: images
                )
            )
        }

        return messages
    }

    private func shouldInterruptExecution(for issueId: String) -> Bool {
        interruptRequested && activeSession?.issueId == issueId
    }

    func restorePersistedSessionIfNeeded(for issueId: String?) async -> ExecutionResult.PauseReason? {
        guard let issueId else { return nil }
        if activeSession?.issueId == issueId {
            return currentPauseReason()
        }

        do {
            guard let state = try IssueStore.loadExecutionState(issueId: issueId) else { return nil }
            await restorePersistedState(state)
            return currentPauseReason()
        } catch {
            return nil
        }
    }

    private func restorePersistedClarification(for issueId: String) throws -> Bool {
        guard let state = try IssueStore.loadExecutionState(issueId: issueId),
            let clarification = state.awaitingClarification
        else {
            return false
        }

        restorePersistedState(state, pendingContext: nil)
        awaitingClarification = clarification
        pendingExecutionContext = nil
        return true
    }

    private func restorePersistedState(
        _ state: PersistedWorkExecutionState,
        pendingContext: PendingExecutionContext? = nil
    ) {
        activeSession = state.session
        awaitingClarification = state.awaitingClarification
        pendingExecutionContext = pendingContext
    }

    private func restorePersistedState(_ state: PersistedWorkExecutionState) async {
        let pendingContext: PendingExecutionContext? =
            if let persistedContext = state.pendingContext {
                await PendingExecutionContext.fromPersisted(persistedContext)
            } else {
                nil
            }
        restorePersistedState(state, pendingContext: pendingContext)
    }

    private func loadPersistedClarificationIfNeeded(for issueId: String) {
        guard awaitingClarification?.issueId != issueId else { return }
        _ = try? restorePersistedClarification(for: issueId)
    }

    private func currentPauseReason() -> ExecutionResult.PauseReason? {
        if let awaitingClarification {
            return .clarificationNeeded(awaitingClarification.request)
        }

        guard let exitReason = activeSession?.lastExitReason else { return nil }
        switch exitReason {
        case .interrupted:
            return .interrupted
        case .clarificationRequested(let request):
            return .clarificationNeeded(request)
        case .iterationLimitReached:
            return .budgetExhausted
        case .completed, .error:
            return nil
        }
    }

    private func updateActiveSession(
        issueId: String,
        messages: [ChatMessage],
        iteration: Int,
        toolCalls: Int,
        exitReason: SessionExitReason
    ) {
        guard var session = activeSession, session.issueId == issueId else {
            activeSession = WorkExecutionSession(
                issueId: issueId,
                messages: messages,
                totalIterations: iteration,
                totalToolCalls: toolCalls,
                lastExitReason: exitReason
            )
            return
        }

        session.messages = messages
        session.totalIterations += iteration
        session.totalToolCalls += toolCalls
        session.lastExitReason = exitReason
        activeSession = session
    }

    private func persistExecutionStateIfPossible() {
        guard let activeSession else { return }

        let state = PersistedWorkExecutionState(
            session: activeSession,
            pendingContext: pendingExecutionContext?.persistedRepresentation,
            awaitingClarification: awaitingClarification
        )
        try? IssueStore.saveExecutionState(state)
    }

    private func clearPersistedExecutionState(issueId: String?) {
        guard let issueId else { return }
        try? IssueStore.deleteExecutionState(issueId: issueId)
    }

    private func appendUserMessage(to session: inout WorkExecutionSession, content: String) {
        session.messages.append(ChatMessage(role: "user", content: content))
    }

    /// Prepends any previously saved scratchpad notes so the agent has them on resume.
    private func injectSavedNotesIfNeeded(into session: inout WorkExecutionSession) {
        let notes = ReadNotesTool.loadNotes(issueId: session.issueId)
        guard !notes.isEmpty, !notes.hasPrefix("No notes") else { return }
        session.messages.append(
            ChatMessage(
                role: "user",
                content: "[Previously saved notes for this task]:\n\(notes)"
            )
        )
    }

    private func resumeActiveSession() async throws -> ExecutionResult {
        guard let session = activeSession else {
            throw WorkEngineError.noActiveSession
        }
        guard let context = pendingExecutionContext else {
            throw WorkEngineError.noActiveSession
        }
        guard let issue = try IssueStore.getIssue(id: session.issueId) else {
            throw WorkEngineError.issueNotFound(session.issueId)
        }

        return try await execute(
            issue: issue,
            model: context.model,
            systemPrompt: context.systemPrompt,
            tools: context.tools,
            executionMode: context.executionMode,
            attemptResume: true
        )
    }

    // MARK: - Retry Logic

    /// Executes an issue with automatic retry on transient failures
    func executeWithRetry(
        issueId: String,
        model: String?,
        systemPrompt: String,
        tools: [Tool],
        executionMode: WorkExecutionMode,
        images: [Data] = [],
        cacheHint: String? = nil,
        staticPrefix: String? = nil
    ) async throws -> ExecutionResult {
        guard let issue = try IssueStore.getIssue(id: issueId) else {
            throw WorkEngineError.issueNotFound(issueId)
        }

        var lastError: Error?

        for attempt in 0 ..< retryConfig.maxAttempts {
            // Check for cancellation (e.g., window closed)
            guard isExecuting || attempt == 0 else {
                throw WorkEngineError.cancelled
            }
            try Task.checkCancellation()

            // Wait before retry (skip delay on first attempt)
            if attempt > 0 {
                let delay = retryConfig.delay(forAttempt: attempt)
                await delegate?.workEngine(self, willRetryIssue: issue, attempt: attempt + 1, afterDelay: delay)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            do {
                let result = try await execute(
                    issue: issue,
                    model: model,
                    systemPrompt: systemPrompt,
                    tools: tools,
                    executionMode: executionMode,
                    images: images,
                    attemptResume: attempt > 0,
                    cacheHint: cacheHint,
                    staticPrefix: staticPrefix
                )

                // Success - clear any error state
                errorStates.removeValue(forKey: issueId)
                return result

            } catch let error as WorkExecutionError where error.isRetriable {
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
        let finalError = WorkEngineError.maxRetriesExceeded(
            underlying: lastError ?? WorkExecutionError.unknown("Unknown error"),
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

    public func hasResumableSession(for issueId: String) -> Bool {
        if activeSession?.issueId == issueId {
            return true
        }
        return (try? IssueStore.loadExecutionState(issueId: issueId)) != nil
    }

    /// Gets the ID of the currently executing issue
    public func getCurrentIssueId() -> String? {
        activeSession?.issueId
    }
}

// MARK: - Delegate Protocol

/// Delegate for receiving work execution events
@MainActor
public protocol WorkEngineDelegate: AnyObject, Sendable {
    // Issue lifecycle
    func workEngine(_ engine: WorkEngine, didStartIssue issue: Issue)
    func workEngine(_ engine: WorkEngine, didCompleteIssue issue: Issue, success: Bool)

    // Reasoning loop events (new)
    func workEngine(_ engine: WorkEngine, didStartIteration iteration: Int, forIssue issue: Issue)
    func workEngine(_ engine: WorkEngine, didReceiveStreamingDelta delta: String, forStep stepIndex: Int)
    func workEngine(_ engine: WorkEngine, didDetectPendingTool toolName: String, forIssue issue: Issue)
    func workEngine(_ engine: WorkEngine, didReceiveToolArgFragment fragment: String, forIssue issue: Issue)
    func workEngine(
        _ engine: WorkEngine,
        didCallTool toolName: String,
        withArguments args: String,
        result: String,
        forIssue issue: Issue
    )
    func workEngine(_ engine: WorkEngine, didUpdateStatus status: String, forIssue issue: Issue)

    // Clarification
    func workEngine(_ engine: WorkEngine, needsClarification request: ClarificationRequest, forIssue issue: Issue)
    func workEngine(_ engine: WorkEngine, didInterruptIssue issue: Issue)
    func workEngine(_ engine: WorkEngine, didExhaustBudget issue: Issue, summary: String)

    // Artifacts
    func workEngine(_ engine: WorkEngine, didShareArtifact artifact: SharedArtifact, forIssue issue: Issue)

    // Token consumption
    func workEngine(_ engine: WorkEngine, didConsumeTokens input: Int, output: Int, forIssue issue: Issue)

    // Retry
    func workEngine(_ engine: WorkEngine, willRetryIssue issue: Issue, attempt: Int, afterDelay: TimeInterval)

    // Secret prompt — present a secure input overlay, return the value or nil if cancelled/unavailable
    func workEngine(_ engine: WorkEngine, needsSecret prompt: SecretPromptParser.Prompt) async -> String?
}

/// Default implementations for optional delegate methods
extension WorkEngineDelegate {
    // Issue lifecycle
    public func workEngine(_ engine: WorkEngine, didStartIssue issue: Issue) {}
    public func workEngine(_ engine: WorkEngine, didCompleteIssue issue: Issue, success: Bool) {}

    // Reasoning loop events
    public func workEngine(_ engine: WorkEngine, didStartIteration iteration: Int, forIssue issue: Issue) {}
    public func workEngine(_ engine: WorkEngine, didReceiveStreamingDelta delta: String, forStep stepIndex: Int) {}
    public func workEngine(_ engine: WorkEngine, didDetectPendingTool toolName: String, forIssue issue: Issue) {}
    public func workEngine(_ engine: WorkEngine, didReceiveToolArgFragment fragment: String, forIssue issue: Issue) {}
    public func workEngine(
        _ engine: WorkEngine,
        didCallTool toolName: String,
        withArguments args: String,
        result: String,
        forIssue issue: Issue
    ) {}
    public func workEngine(_ engine: WorkEngine, didUpdateStatus status: String, forIssue issue: Issue) {}

    // Clarification
    public func workEngine(
        _ engine: WorkEngine,
        needsClarification request: ClarificationRequest,
        forIssue issue: Issue
    ) {}
    public func workEngine(_ engine: WorkEngine, didInterruptIssue issue: Issue) {}
    public func workEngine(_ engine: WorkEngine, didExhaustBudget issue: Issue, summary: String) {}

    // Artifacts
    public func workEngine(_ engine: WorkEngine, didShareArtifact artifact: SharedArtifact, forIssue issue: Issue) {}

    // Token consumption
    public func workEngine(_ engine: WorkEngine, didConsumeTokens input: Int, output: Int, forIssue issue: Issue) {}

    // Retry
    public func workEngine(_ engine: WorkEngine, willRetryIssue issue: Issue, attempt: Int, afterDelay: TimeInterval) {}

    // Secret prompt — default returns nil (no UI available)
    public func workEngine(_ engine: WorkEngine, needsSecret prompt: SecretPromptParser.Prompt) async -> String? { nil }
}

// MARK: - Pending Execution Context

/// Stores execution parameters for resuming after clarification
struct PendingExecutionContext {
    let model: String?
    let systemPrompt: String
    let tools: [Tool]
    let executionMode: WorkExecutionMode
}

extension PendingExecutionContext {
    var persistedRepresentation: PersistedPendingExecutionContext {
        let executionModeSnapshot: PersistedExecutionMode
        let hostFolderRootPath: String?

        switch self.executionMode {
        case .hostFolder(let context):
            executionModeSnapshot = .hostFolder
            hostFolderRootPath = context.rootPath.path
        case .sandbox:
            executionModeSnapshot = .sandbox
            hostFolderRootPath = nil
        case .none:
            executionModeSnapshot = .none
            hostFolderRootPath = nil
        }

        return PersistedPendingExecutionContext(
            model: model,
            systemPrompt: systemPrompt,
            tools: tools,
            executionMode: executionModeSnapshot,
            hostFolderRootPath: hostFolderRootPath
        )
    }

    static func fromPersisted(_ persisted: PersistedPendingExecutionContext) async -> PendingExecutionContext {
        let executionMode = await MainActor.run { () -> WorkExecutionMode in
            switch persisted.executionMode {
            case .sandbox:
                return .sandbox
            case .none:
                return .none
            case .hostFolder:
                guard let context = WorkFolderContextService.shared.currentContext else {
                    return .none
                }
                if let rootPath = persisted.hostFolderRootPath, context.rootPath.path != rootPath {
                    return .none
                }
                return .hostFolder(context)
            }
        }

        return PendingExecutionContext(
            model: persisted.model,
            systemPrompt: persisted.systemPrompt,
            tools: persisted.tools,
            executionMode: executionMode
        )
    }
}

// MARK: - Errors

/// Errors that can occur in the work engine
public enum WorkEngineError: Error, LocalizedError {
    case alreadyExecuting
    case issueNotFound(String)
    case noIssueCreated
    case taskNotFound(String)
    case maxRetriesExceeded(underlying: Error, attempts: Int)
    case cancelled
    case noPendingClarification
    case noActiveSession

    public var errorDescription: String? {
        switch self {
        case .alreadyExecuting:
            return "Work is already executing a task"
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
        case .noActiveSession:
            return "No active work session to continue"
        }
    }

    /// Whether this error is retriable
    public var isRetriable: Bool {
        switch self {
        case .alreadyExecuting, .cancelled, .noPendingClarification, .noActiveSession:
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
