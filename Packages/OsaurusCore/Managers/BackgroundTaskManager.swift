//
//  BackgroundTaskManager.swift
//  osaurus
//
//  Single owner of all backgrounded work: dispatched tasks (from schedules,
//  shortcuts, etc.) and detached tasks (window closed while agent is running).
//  Drives BackgroundTaskToastView, provides completion signaling, and handles
//  lazy window creation. Supports both chat and agent modes.
//

import Combine
import Foundation

// MARK: - Background Task Manager

/// Single owner of all backgrounded work (dispatched and detached)
@MainActor
public final class BackgroundTaskManager: ObservableObject {
    public static let shared = BackgroundTaskManager()

    // MARK: - Published State

    /// All background tasks keyed by task ID (window ID for detached, context ID for dispatched)
    @Published public private(set) var backgroundTasks: [UUID: BackgroundTaskState] = [:]

    // MARK: - Private State

    /// Combined cancellables for each task (session + state observers)
    private var taskObservers: [UUID: Set<AnyCancellable>] = [:]

    /// Continuations for callers awaiting task completion (e.g. ScheduleManager)
    private var completionContinuations: [UUID: CheckedContinuation<DispatchResult, Never>] = [:]

    /// Tracks the number of turns already processed per chat task so we only log new tool calls.
    private var chatTurnCounts: [UUID: Int] = [:]

    /// Subject for batching view updates with throttling
    private let viewUpdateSubject = PassthroughSubject<Void, Never>()
    private var viewUpdateCancellable: AnyCancellable?

    // MARK: - Initialization

    private init() {
        viewUpdateCancellable =
            viewUpdateSubject
            .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
    }

    // MARK: - Public API

    /// Detach a window's agent session to run in background
    @discardableResult
    func detachWindow(
        _ windowId: UUID,
        session: AgentSession,
        windowState: ChatWindowState
    ) -> BackgroundTaskState? {
        guard backgroundTasks[windowId] == nil else {
            return backgroundTasks[windowId]
        }

        guard let currentTask = session.currentTask else { return nil }

        let state = BackgroundTaskState(
            id: windowId,
            taskId: currentTask.id,
            taskTitle: currentTask.title,
            personaId: windowState.personaId,
            session: session,
            windowState: windowState,
            status: session.hasPendingClarification ? .awaitingClarification : .running,
            progress: calculateProgress(session: session),
            currentStep: getCurrentStep(session: session),
            pendingClarification: session.pendingClarification
        )

        state.issues = session.issues
        state.activeIssueId = session.activeIssue?.id
        state.loopState = session.loopState

        backgroundTasks[windowId] = state
        observeAgentTask(state, session: session)
        state.appendActivity(kind: .info, title: "Running in background")

        print("[BackgroundTaskManager] Detached window \(windowId) with task '\(currentTask.title)'")
        return state
    }

    /// Check if a task ID corresponds to a background task
    public func isBackgroundTask(_ id: UUID) -> Bool {
        backgroundTasks[id] != nil
    }

    /// Get background task state by ID
    public func taskState(for id: UUID) -> BackgroundTaskState? {
        backgroundTasks[id]
    }

    /// Open a window for a background task
    public func openTaskWindow(_ backgroundId: UUID) {
        guard let state = backgroundTasks[backgroundId] else { return }

        if let context = state.executionContext {
            ChatWindowManager.shared.createWindowForContext(context, showImmediately: true)
        } else if let windowState = state.windowState, let session = state.session {
            ChatWindowManager.shared.createWindowForBackgroundTask(
                backgroundId: backgroundId,
                session: session,
                windowState: windowState
            )
        }

        finalizeTask(backgroundId)
    }

    /// Finalize a background task (remove from background management)
    public func finalizeTask(_ backgroundId: UUID) {
        guard backgroundTasks[backgroundId] != nil else { return }

        resumeCompletion(for: backgroundId, result: .cancelled)

        taskObservers[backgroundId]?.forEach { $0.cancel() }
        taskObservers.removeValue(forKey: backgroundId)
        chatTurnCounts.removeValue(forKey: backgroundId)

        backgroundTasks.removeValue(forKey: backgroundId)
    }

    /// Cancel a background task
    public func cancelTask(_ backgroundId: UUID) {
        guard let state = backgroundTasks[backgroundId] else { return }

        switch state.mode {
        case .agent: state.session?.stopExecution()
        case .chat: state.chatSession?.stop()
        }

        state.status = .cancelled
        chatTurnCounts.removeValue(forKey: backgroundId)
        resumeCompletion(for: backgroundId, result: .cancelled)
    }

    /// Submit a clarification response (agent mode only)
    public func submitClarification(_ backgroundId: UUID, response: String) {
        guard let state = backgroundTasks[backgroundId], let session = state.session else { return }
        Task { await session.submitClarification(response) }
    }

    // MARK: - Dispatch

    /// Dispatch an agent task for background execution.
    public func dispatchAgent(_ request: DispatchRequest) async -> DispatchHandle? {
        let context = createContext(for: request)
        await context.prepare()
        await context.start(prompt: request.prompt)

        guard let agentSession = context.agentSession,
            let currentTask = agentSession.currentTask
        else { return nil }

        let state = BackgroundTaskState(
            id: context.id,
            taskId: currentTask.id,
            taskTitle: currentTask.title,
            personaId: context.personaId,
            session: agentSession,
            executionContext: context,
            status: agentSession.hasPendingClarification ? .awaitingClarification : .running,
            progress: calculateProgress(session: agentSession),
            currentStep: getCurrentStep(session: agentSession),
            pendingClarification: agentSession.pendingClarification
        )

        state.issues = agentSession.issues
        state.activeIssueId = agentSession.activeIssue?.id
        state.loopState = agentSession.loopState

        backgroundTasks[context.id] = state
        observeAgentTask(state, session: agentSession)
        state.appendActivity(kind: .info, title: "Running in background")

        print("[BackgroundTaskManager] Dispatched agent task: \(request.title ?? "untitled")")
        return DispatchHandle(id: request.id, request: request)
    }

    /// Dispatch a chat task for background execution.
    public func dispatchChat(_ request: DispatchRequest) async -> DispatchHandle? {
        let context = createContext(for: request)
        await context.prepare()
        await context.start(prompt: request.prompt)

        let state = BackgroundTaskState(
            id: context.id,
            taskTitle: context.title ?? "Chat",
            personaId: context.personaId,
            chatSession: context.chatSession,
            executionContext: context,
            status: .running,
            currentStep: "Running..."
        )

        backgroundTasks[context.id] = state
        observeChatTask(state, session: context.chatSession)
        state.appendActivity(kind: .info, title: "Running in background")

        print("[BackgroundTaskManager] Dispatched chat task: \(request.title ?? "untitled")")
        return DispatchHandle(id: request.id, request: request)
    }

    // MARK: - Completion Signaling

    /// Await completion of a background task. Suspends until the task completes, is cancelled, or is finalized.
    public func awaitCompletion(_ id: UUID) async -> DispatchResult {
        if let state = backgroundTasks[id], !state.status.isActive {
            return resultFromState(state)
        }
        guard backgroundTasks[id] != nil else {
            return .failed("Background task not found")
        }
        return await withCheckedContinuation { continuation in
            completionContinuations[id] = continuation
        }
    }

    // MARK: - Private: Context Factory

    private func createContext(for request: DispatchRequest) -> ExecutionContext {
        ExecutionContext(
            id: request.id,
            mode: request.mode,
            personaId: request.personaId ?? Persona.defaultId,
            title: request.title,
            folderBookmark: request.folderBookmark
        )
    }

    // MARK: - Private: Completion Helpers

    private func resultFromState(_ state: BackgroundTaskState) -> DispatchResult {
        switch state.status {
        case .completed:
            return .completed(sessionId: state.executionContext?.chatSession.sessionId)
        case .cancelled:
            return .cancelled
        default:
            return .failed("Task ended unexpectedly")
        }
    }

    private func resumeCompletion(for id: UUID, result: DispatchResult) {
        completionContinuations.removeValue(forKey: id)?.resume(returning: result)
    }

    // MARK: - Private: Agent Observation

    private func observeAgentTask(_ state: BackgroundTaskState, session: AgentSession) {
        var cancellables = Set<AnyCancellable>()
        let taskId = state.id

        // Forward state changes with throttling
        state.objectWillChange
            .sink { [weak self] _ in self?.viewUpdateSubject.send() }
            .store(in: &cancellables)

        // Batch execution-related publishers
        Publishers.CombineLatest3(
            session.$isExecuting,
            session.$pendingClarification,
            session.$currentTask
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] isExecuting, clarification, task in
            self?.handleExecutionChange(
                taskId: taskId,
                isExecuting: isExecuting,
                clarification: clarification,
                task: task,
                session: session
            )
        }
        .store(in: &cancellables)

        // Batch progress-related publishers
        Publishers.CombineLatest(
            session.$issues,
            session.$loopState
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] issues, loopState in
            self?.handleProgressChange(
                taskId: taskId,
                issues: issues,
                loopState: loopState,
                session: session
            )
        }
        .store(in: &cancellables)

        session.$activeIssue
            .receive(on: DispatchQueue.main)
            .sink { [weak self] issue in
                self?.backgroundTasks[taskId]?.activeIssueId = issue?.id
            }
            .store(in: &cancellables)

        // Activity events for the toast mini-log
        session.activityPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self, let state = self.backgroundTasks[taskId] else { return }
                self.recordActivityEvent(event, into: state)
            }
            .store(in: &cancellables)

        taskObservers[taskId] = cancellables
    }

    // MARK: - Private: Chat Observation

    private func observeChatTask(_ state: BackgroundTaskState, session: ChatSession) {
        var cancellables = Set<AnyCancellable>()
        let taskId = state.id

        // Snapshot current turn count so we don't replay history
        chatTurnCounts[taskId] = session.turns.count

        // Forward state changes with throttling
        state.objectWillChange
            .sink { [weak self] _ in self?.viewUpdateSubject.send() }
            .store(in: &cancellables)

        // Streaming state drives running/completed transitions
        session.$isStreaming
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isStreaming in
                self?.handleChatStreamingChange(taskId: taskId, isStreaming: isStreaming)
            }
            .store(in: &cancellables)

        // Observe turn count changes for tool call activity.
        // Map to count + removeDuplicates avoids processing when only content within
        // existing turns changes (e.g. streaming text into an assistant turn).
        session.$turns
            .map(\.count)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newCount in
                self?.handleChatTurnCountChange(taskId: taskId, newCount: newCount, session: session)
            }
            .store(in: &cancellables)

        taskObservers[taskId] = cancellables
    }

    private func handleChatStreamingChange(taskId: UUID, isStreaming: Bool) {
        guard let state = backgroundTasks[taskId] else { return }

        if isStreaming {
            state.status = .running
            state.currentStep = "Running..."
        } else if state.status == .running {
            state.status = .completed(success: true, summary: "Chat completed")
            state.currentStep = nil
            state.chatSession?.save()
            chatTurnCounts.removeValue(forKey: taskId)
            resumeCompletion(for: taskId, result: resultFromState(state))
        }
    }

    /// Scan newly added turns for tool calls and record them as activity.
    private func handleChatTurnCountChange(taskId: UUID, newCount: Int, session: ChatSession) {
        guard let state = backgroundTasks[taskId] else { return }

        let previousCount = chatTurnCounts[taskId] ?? 0
        guard newCount > previousCount else { return }

        let turns = session.turns
        for turn in turns[previousCount ..< min(newCount, turns.count)] {
            if let toolCalls = turn.toolCalls {
                for call in toolCalls {
                    state.appendActivity(kind: .tool, title: "Tool", detail: call.function.name)
                }
            }
        }

        chatTurnCounts[taskId] = newCount
    }

    // MARK: - Private: Agent Activity Event Mapping

    private func recordActivityEvent(_ event: AgentActivityEvent, into state: BackgroundTaskState) {
        switch event {
        case .startedIssue(let title):
            state.appendActivity(kind: .info, title: "Issue", detail: title)
        case .willExecuteStep, .completedStep:
            break  // Reflected via progress bar; skip mini-log entry
        case .toolExecuted(let name):
            state.appendActivity(kind: .tool, title: "Tool", detail: name)
        case .needsClarification:
            state.appendActivity(kind: .warning, title: "Needs input")
        case .retrying(let attempt, let waitSeconds):
            state.appendActivity(kind: .warning, title: "Retrying", detail: "Attempt \(attempt), wait \(waitSeconds)s")
        case .generatedArtifact(let filename, let isFinal):
            state.appendActivity(kind: .info, title: isFinal ? "Final artifact" : "Artifact", detail: filename)
        case .completedIssue(let success):
            state.appendActivity(kind: success ? .success : .error, title: success ? "Issue completed" : "Issue failed")
        }
    }

    // MARK: - Private: Agent State Handlers

    private func handleExecutionChange(
        taskId: UUID,
        isExecuting: Bool,
        clarification: ClarificationRequest?,
        task: AgentTask?,
        session: AgentSession
    ) {
        guard let state = backgroundTasks[taskId] else { return }

        state.pendingClarification = clarification

        if task?.status == .cancelled {
            state.status = .cancelled
        } else if clarification != nil {
            state.status = .awaitingClarification
        } else if isExecuting {
            state.status = .running
            if state.currentStep == nil { state.currentStep = "Working..." }
        } else {
            checkAgentCompletion(state: state, session: session)
        }
    }

    private func handleProgressChange(
        taskId: UUID,
        issues: [Issue],
        loopState: LoopState?,
        session: AgentSession
    ) {
        guard let state = backgroundTasks[taskId] else { return }

        state.issues = issues
        state.loopState = loopState

        let newProgress = calculateProgress(
            issues: issues,
            loopState: loopState,
            isExecuting: session.isExecuting
        )

        // Only update if progress changed significantly (reduces re-renders)
        if abs(state.progress - newProgress) > 0.01 || (state.progress < 0) != (newProgress < 0) {
            state.progress = newProgress
        }

        state.currentStep = getCurrentStep(
            loopState: loopState,
            issues: issues,
            isExecuting: session.isExecuting
        )
    }

    // MARK: - Private: Progress Calculation

    private func calculateProgress(session: AgentSession) -> Double {
        calculateProgress(
            issues: session.issues,
            loopState: session.loopState,
            isExecuting: session.isExecuting
        )
    }

    private func calculateProgress(
        issues: [Issue],
        loopState: LoopState?,
        isExecuting: Bool
    ) -> Double {
        let totalIssues = issues.count

        if totalIssues > 0 {
            let closedIssues = issues.filter { $0.status == .closed }.count
            var progress = Double(closedIssues) / Double(totalIssues)

            if let ls = loopState, ls.maxIterations > 0 {
                progress += ls.progress / Double(totalIssues)
            }

            return progress
        } else if let ls = loopState, ls.maxIterations > 0, ls.iteration > 0 {
            return ls.progress
        } else if isExecuting {
            return -1  // Indeterminate
        }

        return 0
    }

    private func getCurrentStep(session: AgentSession) -> String? {
        getCurrentStep(
            loopState: session.loopState,
            issues: session.issues,
            isExecuting: session.isExecuting
        )
    }

    private func getCurrentStep(
        loopState: LoopState?,
        issues: [Issue],
        isExecuting: Bool
    ) -> String? {
        if let ls = loopState {
            if let msg = ls.statusMessage, !msg.isEmpty { return msg }
            if ls.iteration > 0 {
                let toolCount = ls.toolCallCount
                return toolCount > 0
                    ? "Iteration \(ls.iteration) \u{00B7} \(toolCount) tool call\(toolCount == 1 ? "" : "s")"
                    : "Iteration \(ls.iteration)"
            }
            if isExecuting { return "Starting..." }
        } else if isExecuting {
            return "Working..."
        }
        return nil
    }

    // MARK: - Private: Agent Completion Check

    private func checkAgentCompletion(state: BackgroundTaskState, session: AgentSession) {
        guard !session.hasPendingClarification else { return }

        let issues = session.issues
        let allIssuesClosed = !issues.isEmpty && issues.allSatisfy { $0.status == .closed }
        let taskCompleted = session.currentTask?.status == .completed

        if allIssuesClosed || taskCompleted {
            state.status = .completed(success: true, summary: "Task completed successfully")
            state.progress = 1.0
            state.currentStep = nil
            state.executionContext?.chatSession.save()
            resumeCompletion(for: state.id, result: resultFromState(state))
        } else if session.currentTask == nil {
            let closedCount = issues.filter { $0.status == .closed }.count
            let summary =
                !issues.isEmpty
                ? "Completed \(closedCount)/\(issues.count) issues"
                : "Task ended"
            state.status = .completed(success: closedCount == issues.count, summary: summary)
            resumeCompletion(for: state.id, result: resultFromState(state))
        }
    }
}
