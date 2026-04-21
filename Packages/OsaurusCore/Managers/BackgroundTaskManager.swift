//
//  BackgroundTaskManager.swift
//  osaurus
//
//  Single owner of all backgrounded work: dispatched tasks (from schedules,
//  shortcuts, etc.) and detached tasks (window closed while work is running).
//  Drives NotchView (background task indicator), provides completion signaling, and handles
//  lazy window creation. Supports both chat and work modes.
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

    /// Scheduled auto-finalize timers for completed/cancelled tasks
    private var autoFinalizeTasks: [UUID: Task<Void, Never>] = [:]

    /// Throttle timestamps for progress events (max 1 per 500ms per task).
    private var lastProgressEmit: [UUID: Date] = [:]
    private static let progressThrottleInterval: TimeInterval = 0.5

    /// Tasks whose dispatch() hasn't returned to the plugin yet; events are
    /// buffered in `heldTaskEvents` until `releaseEventsForDispatch` flushes them.
    private var dispatchHoldTasks: Set<UUID> = []
    private var heldTaskEvents: [UUID: [(type: TaskEventType, json: String)]] = [:]

    /// Tracks work tasks that have actually started executing at least once.
    /// Prevents premature completion when Combine publishers fire initial values
    /// before `context.start()` runs.
    private var hasStartedExecution: Set<UUID> = []

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

    /// Detach a window's work session to run in background
    @discardableResult
    func detachWindow(
        _ windowId: UUID,
        session: WorkSession,
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
            agentId: windowState.agentId,
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

        hasStartedExecution.insert(windowId)
        registerTask(state)
        observeWorkTask(state, session: session)

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

        if !state.status.isActive {
            finalizeTask(backgroundId)
        }
    }

    /// Remove a background task from management, cancelling all observers and timers.
    public func finalizeTask(_ backgroundId: UUID) {
        guard let state = backgroundTasks[backgroundId] else { return }

        // Ensure plugins always receive a terminal event before cleanup.
        if state.status.isActive, state.sourcePluginId != nil {
            let issues = state.session?.issues ?? []
            let allClosed = !issues.isEmpty && issues.allSatisfy { $0.status == .closed }

            if allClosed {
                let summary = buildCompletionSummary(from: issues)
                state.status = .completed(success: true, summary: summary)
                emitPluginEvent(
                    state,
                    type: .completed,
                    json: PluginHostContext.serializeCompletedEvent(
                        success: true,
                        summary: summary,
                        sessionId: state.executionContext?.id,
                        taskTitle: state.taskTitle
                    )
                )
            } else {
                state.status = .cancelled
                emitPluginEvent(
                    state,
                    type: .cancelled,
                    json: PluginHostContext.serializeCancelledEvent(taskTitle: state.taskTitle)
                )
            }
        }

        dispatchHoldTasks.remove(backgroundId)
        if let events = heldTaskEvents.removeValue(forKey: backgroundId) {
            for event in events {
                emitPluginEvent(state, type: event.type, json: event.json)
            }
        }

        resumeCompletion(for: backgroundId, result: resultFromState(state))
        cancelAutoFinalize(backgroundId)

        taskObservers[backgroundId]?.forEach { $0.cancel() }
        taskObservers.removeValue(forKey: backgroundId)
        chatTurnCounts.removeValue(forKey: backgroundId)
        lastProgressEmit.removeValue(forKey: backgroundId)
        hasStartedExecution.remove(backgroundId)

        state.releaseReferences()

        backgroundTasks.removeValue(forKey: backgroundId)
    }

    /// Cancel all active background tasks. Called during app termination.
    public func cancelAllTasks() {
        for id in backgroundTasks.keys {
            cancelTask(id)
        }
    }

    /// Cancel a background task
    public func cancelTask(_ backgroundId: UUID) {
        guard let state = backgroundTasks[backgroundId] else { return }

        switch state.mode {
        case .work: state.session?.cancelExecution()
        case .chat: state.chatSession?.stop()
        }

        state.status = .cancelled
        resumeCompletion(for: backgroundId, result: .cancelled)
        emitPluginEvent(
            state,
            type: .cancelled,
            json: PluginHostContext.serializeCancelledEvent(taskTitle: state.taskTitle)
        )
        lastProgressEmit.removeValue(forKey: backgroundId)
        scheduleAutoFinalize(backgroundId)
    }

    /// Submit a clarification response (work mode only)
    public func submitClarification(_ backgroundId: UUID, response: String) {
        guard let state = backgroundTasks[backgroundId], let session = state.session else { return }
        Task { await session.submitClarification(response) }
    }

    /// Soft-stop a running task. If message is provided, interrupts and re-enters
    /// with the message injected (work mode redirect). If nil, just sets interrupt flag.
    public func interruptTask(_ backgroundId: UUID, message: String?) {
        guard let state = backgroundTasks[backgroundId], state.status.isActive else { return }

        switch state.mode {
        case .work:
            if let message {
                state.session?.redirectExecution(message: message)
            } else {
                state.session?.stopExecution()
            }
        case .chat:
            state.chatSession?.stop()
        }
    }

    /// Emit a draft event to the originating plugin.
    func emitDraftEvent(_ state: BackgroundTaskState, draftJSON: String) {
        emitPluginEvent(
            state,
            type: .draft,
            json: PluginHostContext.serializeDraftEvent(draftJSON: draftJSON, taskTitle: state.taskTitle)
        )
    }

    // MARK: - Dispatch

    /// Dispatch an work task for background execution.
    public func dispatchWork(_ request: DispatchRequest) async -> DispatchHandle? {
        guard canDispatchNewTask(agentId: request.agentId) else { return nil }

        let context = createContext(for: request)
        await context.prepare()

        guard let workSession = context.workSession else { return nil }

        // Register placeholder state before starting so awaitCompletion always finds the task.
        // taskId and taskTitle are updated once the work session creates its task.
        let state = BackgroundTaskState(
            id: context.id,
            taskId: "",
            taskTitle: request.title ?? "Work",
            agentId: context.agentId,
            session: workSession,
            executionContext: context,
            status: .running,
            progress: -1,
            currentStep: "Starting..."
        )

        state.sourcePluginId = request.sourcePluginId
        registerTask(state)
        observeWorkTask(state, session: workSession)

        await context.start(prompt: request.prompt)

        // Update with real task info now that the work session has created its task
        if let currentTask = workSession.currentTask {
            state.taskId = currentTask.id
            state.taskTitle = currentTask.title
        }
        state.issues = workSession.issues
        state.activeIssueId = workSession.activeIssue?.id
        state.loopState = workSession.loopState
        state.progress = calculateProgress(session: workSession)
        state.currentStep = getCurrentStep(session: workSession)
        if workSession.hasPendingClarification {
            state.status = .awaitingClarification
            state.pendingClarification = workSession.pendingClarification
        }

        print("[BackgroundTaskManager] Dispatched work task: \(request.title ?? "untitled")")
        return DispatchHandle(id: request.id, request: request)
    }

    /// Dispatch a chat task for background execution.
    public func dispatchChat(_ request: DispatchRequest) async -> DispatchHandle? {
        guard canDispatchNewTask(agentId: request.agentId) else { return nil }

        let context = createContext(for: request)
        await context.prepare()

        // Register state before starting so awaitCompletion always finds the task
        let state = BackgroundTaskState(
            id: context.id,
            taskTitle: context.title ?? "Chat",
            agentId: context.agentId,
            chatSession: context.chatSession,
            executionContext: context,
            status: .running,
            currentStep: "Running..."
        )

        state.sourcePluginId = request.sourcePluginId
        registerTask(state)
        observeChatTask(state, session: context.chatSession)

        await context.start(prompt: request.prompt)

        print("[BackgroundTaskManager] Dispatched chat task: \(request.title ?? "untitled")")
        return DispatchHandle(id: request.id, request: request)
    }

    // MARK: - Completion Signaling

    /// Await completion of a background task. Suspends until the task completes, is cancelled, finalized, or times out.
    /// A 30-minute timeout prevents indefinite hangs if a task never reaches a terminal state.
    public func awaitCompletion(_ id: UUID, timeoutSeconds: UInt64 = 1800) async -> DispatchResult {
        if let state = backgroundTasks[id], !state.status.isActive {
            return resultFromState(state)
        }
        guard backgroundTasks[id] != nil else {
            return .failed("Background task not found")
        }

        // Start a watchdog that will resume the continuation with a timeout error
        // if the task doesn't complete within the deadline.
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            completionContinuations.removeValue(forKey: id)?.resume(returning: .failed("Background task timed out"))
        }

        let result = await withCheckedContinuation { continuation in
            completionContinuations[id] = continuation
        }

        timeoutTask.cancel()
        return result
    }

    // MARK: - Private: Dispatch Helpers

    private static let maxTasksPerAgent = 5

    /// Check whether a new task can be dispatched without exceeding the global
    /// limit or the per-agent limit. The global limit is user-configurable via
    /// settings; the per-agent limit prevents a single agent from monopolizing
    /// all slots in multi-agent scenarios.
    private func canDispatchNewTask(agentId: UUID?) -> Bool {
        let globalLimit = ToastConfigurationStore.load().maxConcurrentTasks
        let activeTasks = backgroundTasks.values.filter { $0.status.isActive }

        guard activeTasks.count < globalLimit else {
            print("[BackgroundTaskManager] Global task limit reached (\(globalLimit)), rejecting dispatch")
            return false
        }

        if let agentId {
            let agentCount = activeTasks.filter { $0.agentId == agentId }.count
            guard agentCount < Self.maxTasksPerAgent else {
                print(
                    "[BackgroundTaskManager] Per-agent task limit reached (\(Self.maxTasksPerAgent)) for agent \(agentId), rejecting dispatch"
                )
                return false
            }
        }

        return true
    }

    /// Register a new task state and log an initial activity entry.
    private func registerTask(_ state: BackgroundTaskState) {
        backgroundTasks[state.id] = state
        state.appendActivity(kind: .info, title: "Running in background")
        emitPluginEvent(state, type: .started, json: PluginHostContext.serializeStartedEvent(state: state))
    }

    private func createContext(for request: DispatchRequest) -> ExecutionContext {
        ExecutionContext(
            id: request.id,
            mode: request.mode,
            agentId: request.agentId ?? Agent.defaultId,
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

    /// Mark a task as completed and signal callers.
    /// The toast persists until the user views it or dismisses manually.
    private func markCompleted(_ state: BackgroundTaskState, success: Bool, summary: String) {
        state.status = .completed(success: success, summary: summary)
        state.currentStep = nil
        state.executionContext?.chatSession.save()
        resumeCompletion(for: state.id, result: resultFromState(state))

        let eventType: TaskEventType = success ? .completed : .failed
        let artifacts = state.executionContext?.workSession?.sharedArtifacts ?? []
        let outputText = state.session?.streamingContent
        let json = PluginHostContext.serializeCompletedEvent(
            success: success,
            summary: summary,
            sessionId: state.executionContext?.id,
            taskTitle: state.taskTitle,
            artifacts: artifacts,
            outputText: outputText
        )
        emitPluginEvent(state, type: eventType, json: json)
        lastProgressEmit.removeValue(forKey: state.id)
    }

    // MARK: - Private: Plugin Event Emission

    /// Emit a unified task lifecycle event to the originating plugin.
    /// If the task's dispatch() call hasn't returned yet, the event is
    /// buffered and will be flushed by `releaseEventsForDispatch`.
    private func emitPluginEvent(_ state: BackgroundTaskState, type: TaskEventType, json: String) {
        guard let pluginId = state.sourcePluginId else { return }

        if dispatchHoldTasks.contains(state.id) {
            heldTaskEvents[state.id, default: []].append((type: type, json: json))
            return
        }

        if let loaded = PluginManager.shared.loadedPlugin(for: pluginId),
            loaded.plugin.hasTaskEventHandler
        {
            loaded.plugin.notifyTaskEvent(
                taskId: state.id.uuidString,
                eventType: type,
                eventJSON: json,
                agentId: state.agentId
            )
        }
    }

    // MARK: - Dispatch Event Gating

    /// Begin holding task events for a dispatch in flight. Call on the main
    /// actor *before* `TaskDispatcher.dispatch` so the hold is in place before
    /// `registerTask` emits the `.started` event.
    func holdEventsForDispatch(taskId: UUID) {
        dispatchHoldTasks.insert(taskId)
    }

    /// Release held events after the dispatch() C call has returned to the
    /// plugin. Flushes all buffered events in order via `emitPluginEvent`.
    func releaseEventsForDispatch(taskId: UUID) {
        dispatchHoldTasks.remove(taskId)
        if let events = heldTaskEvents.removeValue(forKey: taskId),
            let state = backgroundTasks[taskId]
        {
            for event in events {
                emitPluginEvent(state, type: event.type, json: event.json)
            }
        }
    }

    // MARK: - Private: Auto-Finalize

    /// Schedule automatic toast removal after 15 seconds.
    /// Called when a task completes or is cancelled. If the user opens the
    /// task window before the timer fires, `finalizeTask` cancels it.
    private func scheduleAutoFinalize(_ taskId: UUID) {
        cancelAutoFinalize(taskId)
        autoFinalizeTasks[taskId] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            guard let state = backgroundTasks[taskId], !state.status.isActive else { return }
            guard !dispatchHoldTasks.contains(taskId) else { return }
            finalizeTask(taskId)
        }
    }

    private func cancelAutoFinalize(_ taskId: UUID) {
        autoFinalizeTasks[taskId]?.cancel()
        autoFinalizeTasks.removeValue(forKey: taskId)
    }

    // MARK: - Private: Work Observation

    private func observeWorkTask(_ state: BackgroundTaskState, session: WorkSession) {
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
            .sink { [weak self] issue in
                self?.backgroundTasks[taskId]?.activeIssueId = issue?.id
            }
            .store(in: &cancellables)

        // Activity events for the toast mini-log
        session.activityPublisher
            .sink { [weak self] event in
                guard let self, let state = self.backgroundTasks[taskId],
                    state.status.isActive
                else { return }
                self.recordActivityEvent(event, into: state)
            }
            .store(in: &cancellables)

        // Stream agent output to plugins (throttled to 1 event per second)
        session.streamingOutputSubject
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] text in
                guard let self, let state = self.backgroundTasks[taskId],
                    state.status.isActive, state.sourcePluginId != nil
                else { return }
                self.emitPluginEvent(
                    state,
                    type: .output,
                    json: PluginHostContext.serializeOutputEvent(text: text, taskTitle: state.taskTitle)
                )
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

        // Streaming state + error drive running/completed/failed transitions.
        Publishers.CombineLatest(
            session.$isStreaming,
            session.$lastStreamError
        )
        .sink { [weak self] isStreaming, lastError in
            self?.handleChatStreamingChange(taskId: taskId, isStreaming: isStreaming, lastError: lastError)
        }
        .store(in: &cancellables)

        // Observe turn count changes for tool call activity.
        // Map to count + removeDuplicates avoids processing when only content within
        // existing turns changes (e.g. streaming text into an assistant turn).
        session.$turns
            .map(\.count)
            .removeDuplicates()
            .sink { [weak self] newCount in
                self?.handleChatTurnCountChange(taskId: taskId, newCount: newCount, session: session)
            }
            .store(in: &cancellables)

        taskObservers[taskId] = cancellables
    }

    private func handleChatStreamingChange(taskId: UUID, isStreaming: Bool, lastError: String?) {
        guard let state = backgroundTasks[taskId] else { return }

        if isStreaming {
            state.status = .running
            state.currentStep = "Running..."
        } else if state.status == .running {
            if let lastError {
                markCompleted(state, success: false, summary: lastError)
            } else {
                markCompleted(state, success: true, summary: "Chat completed")
            }
        }
    }

    /// Scan newly added turns for tool calls and record them as activity.
    ///
    /// Tool calls are appended to an existing assistant turn *before* the tool-result
    /// and next-assistant turns are added. By the time the turn count changes, the
    /// assistant turn we previously scanned (empty at the time) now has `toolCalls`.
    /// To catch them, we also re-check the turn immediately before the new range.
    private func handleChatTurnCountChange(taskId: UUID, newCount: Int, session: ChatSession) {
        guard let state = backgroundTasks[taskId] else { return }

        let previousCount = chatTurnCounts[taskId] ?? 0
        guard newCount > previousCount else { return }

        let turns = session.turns
        let scanStart = max(0, previousCount - 1)
        for turn in turns[scanStart ..< min(newCount, turns.count)] {
            if let toolCalls = turn.toolCalls {
                for call in toolCalls {
                    state.appendActivity(kind: .tool, title: "Tool", detail: call.function.name)
                    emitPluginEvent(
                        state,
                        type: .activity,
                        json: PluginHostContext.serializeActivityEvent(
                            kind: .tool,
                            title: "Tool",
                            detail: call.function.name
                        )
                    )
                }
            }
        }

        chatTurnCounts[taskId] = newCount
    }

    // MARK: - Private: Work Activity Event Mapping

    private func recordActivityEvent(_ event: WorkActivityEvent, into state: BackgroundTaskState) {
        // Append-only: no plugin event for clarification requests
        if case .needsClarification = event {
            state.appendActivity(kind: .warning, title: "Needs input")
            return
        }

        typealias Activity = (
            kind: BackgroundTaskActivityItem.Kind, title: String,
            detail: String?, metadata: [String: Any]?
        )

        let activity: Activity? =
            switch event {
            case .startedIssue(let title):
                (.info, "Task", title, nil)
            case .toolExecuted(let name):
                (.toolCall, "Tool", name, ["tool_name": name])
            case .retrying(let attempt, let waitSeconds):
                (.warning, "Retrying", "Attempt \(attempt), wait \(waitSeconds)s", nil)
            case .sharedArtifact(let filename, let isFinal):
                (.info, isFinal ? "Final artifact" : "Shared artifact", filename, ["filename": filename])
            case .completedIssue(let success):
                (success ? .success : .error, success ? "Task completed" : "Task failed", nil, nil)
            case .optimizedMemory:
                (.info, "Memory", "Freed up space from older results", nil)
            case .savingProgress:
                (.thinking, "Progress", "Saving key findings before summarizing", nil)
            case .summarizingWork:
                (.thinking, "Context", "Condensing conversation history", nil)
            case .resumedWithSummary:
                (.success, "Context", "Earlier work summarized", nil)
            case .willExecuteStep, .completedStep, .needsClarification:
                nil
            }

        guard let activity else { return }
        state.appendActivity(kind: activity.kind, title: activity.title, detail: activity.detail)
        emitPluginEvent(
            state,
            type: .activity,
            json: PluginHostContext.serializeActivityEvent(
                kind: activity.kind,
                title: activity.title,
                detail: activity.detail,
                metadata: activity.metadata
            )
        )
    }

    // MARK: - Private: Work State Handlers

    private func handleExecutionChange(
        taskId: UUID,
        isExecuting: Bool,
        clarification: ClarificationRequest?,
        task: WorkTask?,
        session: WorkSession
    ) {
        guard let state = backgroundTasks[taskId] else { return }
        guard state.status.isActive else { return }

        let wasClarifying = state.status == .awaitingClarification
        state.pendingClarification = clarification

        if task?.status == .cancelled, state.status != .cancelled {
            state.status = .cancelled
            resumeCompletion(for: taskId, result: .cancelled)
            emitPluginEvent(
                state,
                type: .cancelled,
                json: PluginHostContext.serializeCancelledEvent(taskTitle: state.taskTitle)
            )
            lastProgressEmit.removeValue(forKey: taskId)
        } else if let clarification {
            state.status = .awaitingClarification
            if !wasClarifying {
                emitPluginEvent(
                    state,
                    type: .clarification,
                    json: PluginHostContext.serializeClarificationEvent(clarification: clarification)
                )
            }
        } else if isExecuting {
            hasStartedExecution.insert(taskId)
            state.status = .running
            if state.currentStep == nil { state.currentStep = "Working..." }
        } else {
            checkWorkCompletion(state: state, session: session)
        }
    }

    private func handleProgressChange(
        taskId: UUID,
        issues: [Issue],
        loopState: LoopState?,
        session: WorkSession
    ) {
        guard let state = backgroundTasks[taskId] else { return }
        guard state.status.isActive else { return }

        state.issues = issues
        state.loopState = loopState

        let newProgress = calculateProgress(
            issues: issues,
            loopState: loopState,
            isExecuting: session.isExecuting
        )

        let progressChanged =
            abs(state.progress - newProgress) > 0.01
            || (state.progress < 0) != (newProgress < 0)
        if progressChanged {
            state.progress = newProgress
        }

        let newStep = getCurrentStep(
            loopState: loopState,
            issues: issues,
            isExecuting: session.isExecuting
        )
        let stepChanged = state.currentStep != newStep
        state.currentStep = newStep

        if (progressChanged || stepChanged) && state.sourcePluginId != nil {
            let now = Date()
            let lastEmit = lastProgressEmit[taskId]
            if lastEmit == nil || now.timeIntervalSince(lastEmit!) >= Self.progressThrottleInterval {
                lastProgressEmit[taskId] = now
                emitPluginEvent(
                    state,
                    type: .progress,
                    json: PluginHostContext.serializeProgressEvent(
                        progress: state.progress,
                        currentStep: state.currentStep,
                        taskTitle: state.taskTitle
                    )
                )
            }
        }

        // Retry completion check — isExecuting may fire before issues update
        if !session.isExecuting && state.status.isActive {
            checkWorkCompletion(state: state, session: session)
        }
    }

    // MARK: - Private: Progress Calculation

    private func calculateProgress(session: WorkSession) -> Double {
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

    private func getCurrentStep(session: WorkSession) -> String? {
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

    // MARK: - Private: Work Completion Check

    private func checkWorkCompletion(state: BackgroundTaskState, session: WorkSession) {
        guard !session.hasPendingClarification else { return }
        guard hasStartedExecution.contains(state.id) else { return }

        let issues = session.issues
        let allIssuesClosed = !issues.isEmpty && issues.allSatisfy { $0.status == .closed }
        let taskCompleted = session.currentTask?.status == .completed

        if allIssuesClosed || taskCompleted {
            state.progress = 1.0
            markCompleted(state, success: true, summary: buildCompletionSummary(from: issues))
        } else if session.currentTask == nil {
            let closedCount = issues.filter { $0.status == .closed }.count
            let success = !issues.isEmpty && closedCount == issues.count
            let summary =
                !issues.isEmpty
                ? buildCompletionSummary(from: issues)
                : "Task ended"
            markCompleted(state, success: success, summary: summary)
        } else if !session.isExecuting && session.pausedIssueId == nil {
            let summary = session.errorMessage ?? "Task failed"
            markCompleted(state, success: false, summary: summary)
        }
    }

    private func buildCompletionSummary(from issues: [Issue]) -> String {
        let results =
            issues
            .filter { $0.status == .closed }
            .compactMap { $0.result }
            .filter { !$0.isEmpty }
        if results.count == 1 { return results[0] }
        if results.count > 1 { return results.joined(separator: "\n\n") }
        return "Task completed successfully"
    }
}
