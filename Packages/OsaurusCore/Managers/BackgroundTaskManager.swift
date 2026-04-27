//
//  BackgroundTaskManager.swift
//  osaurus
//
//  Single owner of all backgrounded work — dispatched chat tasks (from
//  schedules, shortcuts, plugins, HTTP, watchers). Drives NotchView,
//  provides completion signaling, and handles lazy window creation.
//

import Combine
import Foundation

// MARK: - Background Task Manager

/// Single owner of all backgrounded chat tasks (dispatched).
@MainActor
public final class BackgroundTaskManager: ObservableObject {
    public static let shared = BackgroundTaskManager()

    // MARK: - Published State

    /// All background tasks keyed by task ID
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

    /// Tasks whose dispatch() hasn't returned to the plugin yet; events are
    /// buffered in `heldTaskEvents` until `releaseEventsForDispatch` flushes them.
    private var dispatchHoldTasks: Set<UUID> = []
    private var heldTaskEvents: [UUID: [(type: TaskEventType, json: String)]] = [:]

    /// Tasks for which `ChatSession.isStreaming` has flipped to `true` at
    /// least once. Guards `markCompleted` against the synchronous initial
    /// `(false, nil)` tuple that `Publishers.CombineLatest` emits the instant
    /// `observeChatTask` subscribes (well before `ChatSession.send`'s async
    /// Task body runs). See `handleChatStreamingChange`.
    private var streamingObserved: Set<UUID> = []

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
            state.status = .cancelled
            emitPluginEvent(
                state,
                type: .cancelled,
                json: PluginHostContext.serializeCancelledEvent(taskTitle: state.taskTitle)
            )
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
        streamingObserved.remove(backgroundId)

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

        state.chatSession?.stop()
        state.status = .cancelled
        resumeCompletion(for: backgroundId, result: .cancelled)
        emitPluginEvent(
            state,
            type: .cancelled,
            json: PluginHostContext.serializeCancelledEvent(taskTitle: state.taskTitle)
        )
        scheduleAutoFinalize(backgroundId)
    }

    /// Soft-stop a running task by cancelling its current stream. The chat
    /// task can be resumed by the user opening its window and sending a
    /// follow-up message.
    public func interruptTask(_ backgroundId: UUID, message: String?) {
        guard let state = backgroundTasks[backgroundId], state.status.isActive else { return }
        // `message` is ignored for chat tasks — ChatSession has no
        // mid-stream redirect API. The user can open the window and send
        // a follow-up message after the soft stop.
        _ = message
        state.chatSession?.stop()
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

    /// Dispatch a chat task for background execution.
    public func dispatchChat(_ request: DispatchRequest) async -> DispatchHandle? {
        guard canDispatchNewTask(source: request.source, agentId: request.agentId) else { return nil }

        // Opt-in conversation grouping: when `external_session_key` is set
        // and a non-active matching session exists, reattach to it so the
        // new prompt becomes the next turn instead of starting a fresh row.
        let reattach = lookupReattachableSession(for: request)
        let context: ExecutionContext
        if let existing = reattach {
            context = ExecutionContext(
                reattaching: existing,
                folderBookmark: request.folderBookmark
            )
        } else {
            context = createContext(for: request)
        }
        await context.prepare()

        // Register state before starting so awaitCompletion always finds the task
        let state = BackgroundTaskState(
            id: context.id,
            taskTitle: context.title ?? "Chat",
            agentId: context.agentId,
            chatSession: context.chatSession,
            executionContext: context,
            status: .running,
            currentStep: "Running...",
            source: request.source,
            sourcePluginId: request.sourcePluginId,
            externalSessionKey: request.externalSessionKey,
            showToast: request.showToast
        )

        // Plugin-originated dispatches buffer their `.started` event until
        // the trampoline returns, so the plugin's `on_task_event` callback
        // doesn't fire before its `dispatch()` C call has unwound. Hold here
        // (now that we know the real task id, which may differ from
        // `request.id` after a reattach) and let the trampoline release.
        if request.sourcePluginId != nil {
            holdEventsForDispatch(taskId: context.id)
        }
        registerTask(state)
        observeChatTask(state, session: context.chatSession)

        await context.start(prompt: request.prompt)

        let reattachNote = reattach == nil ? "" : " (reattached to session \(context.id))"
        print("[BackgroundTaskManager] Dispatched chat task: \(request.title ?? "untitled")\(reattachNote)")
        // Return the resolved task id (may differ from request.id after a
        // reattach) so callers awaiting completion poll the actual live task.
        return DispatchHandle(id: context.id, request: request)
    }

    /// Returns an existing persisted session for this dispatch when the
    /// request opts into grouping via `external_session_key`. Skips reattach
    /// if a live in-memory task is already driving that session, to avoid
    /// double-stream into the same `ChatSession`.
    private func lookupReattachableSession(for request: DispatchRequest) -> ChatSessionData? {
        guard let key = request.externalSessionKey,
            !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        let agentId = request.agentId

        let liveDuplicate = backgroundTasks.values.contains { state in
            guard state.status.isActive,
                state.externalSessionKey == key,
                state.source == request.source
            else { return false }
            // For plugin-sourced dispatches also require the same plugin id
            // so two plugins that happen to use the same key don't collide.
            if request.source == .plugin {
                return state.sourcePluginId == request.sourcePluginId
            }
            return true
        }
        if liveDuplicate { return nil }

        let db = ChatHistoryDatabase.shared
        // ChatHistoryDatabase.findSession opens lazily via shared singleton;
        // ensure it's initialised so the lookup doesn't no-op on cold start.
        do { try db.open() } catch {
            print("[BackgroundTaskManager] Failed to open chat history db for reattach: \(error)")
            return nil
        }

        // Plugin source has a guaranteed sourcePluginId; HTTP / scheduler /
        // watcher dispatches don't, so fall back to the source-based index.
        let metadata: ChatSessionData?
        if request.source == .plugin, let pluginId = request.sourcePluginId {
            metadata = db.findSession(pluginId: pluginId, externalKey: key, agentId: agentId)
        } else {
            metadata = db.findSession(source: request.source, externalKey: key, agentId: agentId)
        }
        guard let metadata else { return nil }
        // findSession returns metadata only; hydrate turns for ChatSession.load.
        return db.loadSession(id: metadata.id)
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
    private func canDispatchNewTask(source: SessionSource, agentId: UUID?) -> Bool {
        // Plugin / sandbox callers must supply an agentId. Without one, the
        // per-agent cap below would be silently skipped — letting a single
        // sandboxed plugin saturate every slot. The bridge always provides
        // an id post-fix, so a nil here is a programmer error.
        if source == .plugin, agentId == nil {
            print("[BackgroundTaskManager] Refusing plugin dispatch without agentId")
            return false
        }

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

    #if DEBUG
        /// Test-only: insert a pre-built `BackgroundTaskState` directly so
        /// regression tests can exercise `observeChatTask` without spinning up
        /// a real `ExecutionContext` + MLX-backed engine.
        func registerTaskForTesting(_ state: BackgroundTaskState) {
            backgroundTasks[state.id] = state
        }
    #endif

    private func createContext(for request: DispatchRequest) -> ExecutionContext {
        ExecutionContext(
            id: request.id,
            agentId: request.agentId ?? Agent.defaultId,
            title: request.title,
            folderBookmark: request.folderBookmark,
            source: request.source,
            sourcePluginId: request.sourcePluginId,
            externalSessionKey: request.externalSessionKey
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
        let outputText = state.chatSession?.turns.last?.content
        let json = PluginHostContext.serializeCompletedEvent(
            success: success,
            summary: summary,
            sessionId: state.executionContext?.id,
            taskTitle: state.taskTitle,
            outputText: outputText
        )
        emitPluginEvent(state, type: eventType, json: json)
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

    // MARK: - Private: Chat Observation

    /// Internal (rather than private) so regression tests can drive the
    /// streaming observer directly. Production callers go through `dispatchChat`.
    func observeChatTask(_ state: BackgroundTaskState, session: ChatSession) {
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
            streamingObserved.insert(taskId)
            state.status = .running
            state.currentStep = "Running..."
        } else if state.status == .running, streamingObserved.contains(taskId) {
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
}
