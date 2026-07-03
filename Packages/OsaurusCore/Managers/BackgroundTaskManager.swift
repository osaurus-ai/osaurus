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

    /// Render-ready ordering of toast-visible tasks (`showToast == true`),
    /// sorted by status priority then recency. Recomputed only when the
    /// task set or a task's observable state changes, so SwiftUI body
    /// evaluations read a ready array instead of re-running filter+sort on
    /// every access (a single `NotchView` body reads the ordering dozens of
    /// times). Refreshes piggyback on the manager's `objectWillChange`, so
    /// this stays a plain stored property rather than `@Published`.
    public private(set) var sortedToastTasks: [BackgroundTaskState] = []

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

    /// Background-task id keyed by the chat window currently bound to it.
    /// Populated by `detachChatWindow` and by `openTaskWindow`; consulted
    /// by `ChatWindowManager` in `windowWillClose` to decide whether to
    /// skip `cleanup()` (which would otherwise call `session.stop()` and
    /// kill the in-flight stream).
    private var taskIdByWindow: [UUID: UUID] = [:]

    /// Subject for batching view updates with throttling
    private let viewUpdateSubject = PassthroughSubject<Void, Never>()
    private var viewUpdateCancellable: AnyCancellable?

    // MARK: - Initialization

    private init() {
        viewUpdateCancellable =
            viewUpdateSubject
            .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in
                guard let self else { return }
                // A task's own state (status / createdAt-relative ordering)
                // may have changed, so refresh the cached ordering before
                // driving the throttled view update.
                self.recomputeSortedToastTasks()
                self.objectWillChange.send()
            }
    }

    // MARK: - Toast Ordering

    /// Status ordering for the notch: awaiting input first, then running,
    /// then terminal states. Lower sorts earlier.
    private static func statusSortPriority(_ status: BackgroundTaskStatus) -> Int {
        switch status {
        case .awaitingClarification: return 0
        case .running: return 1
        case .completed: return 2
        case .cancelled: return 3
        }
    }

    /// Rebuild `sortedToastTasks` from the current task set. Cheap (the set
    /// is capped at a handful of tasks) but kept off the per-render path by
    /// only running when the set or a task's state actually changes.
    private func recomputeSortedToastTasks() {
        sortedToastTasks =
            backgroundTasks.values
            // Headless dispatchers (e.g. webhook responders) opt out of the
            // notch by setting `showToast = false`. The task is still tracked
            // for completion signaling — it just doesn't render.
            .filter { $0.showToast }
            .sorted { a, b in
                let ap = Self.statusSortPriority(a.status), bp = Self.statusSortPriority(b.status)
                if ap != bp { return ap < bp }
                return a.createdAt > b.createdAt
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

    /// Background-task id (if any) the given window is bound to. Returns
    /// nil for plain chat windows that were never detached.
    public func taskId(forWindowId windowId: UUID) -> UUID? {
        taskIdByWindow[windowId]
    }

    /// Whether this window is bound to a still-tracked background task.
    /// False if the window was never detached or its task already finalized.
    public func isWindowDetachedToBackground(windowId: UUID) -> Bool {
        guard let id = taskIdByWindow[windowId] else { return false }
        return backgroundTasks[id] != nil
    }

    /// Detach a streaming chat window's session into a background task so
    /// the user can close the window without killing the in-flight stream.
    /// The detached task surfaces in `NotchView` and can be re-opened via
    /// `openTaskWindow(_:)`.
    ///
    /// No-op if the window doesn't exist, isn't streaming, or was already
    /// detached.
    public func detachChatWindow(windowId: UUID) {
        guard taskIdByWindow[windowId] == nil,
            let session = ChatWindowManager.shared.windowState(id: windowId)?.session,
            session.isStreaming
        else { return }

        // Persist before adopting so the sidebar and `openTaskWindow` reload
        // path both see a real saved row for this session.
        session.save()

        let context = ExecutionContext(adopting: session)
        let state = BackgroundTaskState(
            id: context.id,
            taskTitle: session.title,
            agentId: context.agentId,
            chatSession: session,
            executionContext: context,
            status: .running,
            currentStep: "Running...",
            source: .chat,
            sourcePluginId: nil,
            externalSessionKey: nil,
            showToast: true
        )
        registerTask(state)
        observeChatTask(state, session: session)
        taskIdByWindow[windowId] = state.id
        print("[BackgroundTaskManager] Detached chat window \(windowId) as task \(state.id)")
    }

    /// Open a window for a background task
    public func openTaskWindow(_ backgroundId: UUID) {
        guard let state = backgroundTasks[backgroundId] else { return }

        if let context = state.executionContext {
            let windowId = ChatWindowManager.shared.createWindowForContext(context, showImmediately: true)
            // Bind window→task so closing this window doesn't kill the
            // still-running task — gated in `ChatWindowManager.windowWillClose`.
            taskIdByWindow[windowId] = backgroundId
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
            if let runId = state.agentRunId {
                do {
                    try SchedulerDatabase.shared.recordRunEnd(runId: runId, status: .cancelled)
                } catch {
                    print("[BackgroundTaskManager] recordRunEnd (finalize/cancel) failed for run \(runId): \(error)")
                }
                state.agentRunId = nil
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
        streamingObserved.remove(backgroundId)
        // Drop any window→task bindings pointing here so a still-open
        // window's close path stops thinking the task is alive.
        taskIdByWindow = taskIdByWindow.filter { $0.value != backgroundId }

        state.releaseReferences()

        backgroundTasks.removeValue(forKey: backgroundId)
        recomputeSortedToastTasks()
    }

    /// Cancel all active background tasks. Called during app termination.
    public func cancelAllTasks() {
        for id in backgroundTasks.keys {
            cancelTask(id)
        }
    }

    /// Update a task's running token / cost counters and cancel the
    /// task when either dimension crosses its configured ceiling (spec
    /// §11.3). Safe to call from any actor — we hop to MainActor
    /// internally because `BackgroundTaskState` is `@MainActor`.
    ///
    /// Streaming engines call this after each provider chunk. When the
    /// per-chunk USD cost isn't known, callers may pass nil and rely
    /// on token counts alone.
    public func recordUsage(
        backgroundId: UUID,
        tokensInDelta: Int = 0,
        tokensOutDelta: Int = 0,
        costUSDDelta: Double = 0
    ) {
        guard let state = backgroundTasks[backgroundId] else { return }
        state.tokensIn += max(0, tokensInDelta)
        state.tokensOut += max(0, tokensOutDelta)
        state.costUSD += max(0, costUSDDelta)
        if let reason = state.budgetExceededReason() {
            state.budgetExhaustedReason = reason
            print("[BackgroundTaskManager] budget exhausted (\(reason)) — cancelling \(backgroundId)")
            cancelTask(backgroundId)
        }
    }

    /// Cancel a background task
    public func cancelTask(_ backgroundId: UUID) {
        guard let state = backgroundTasks[backgroundId] else { return }

        state.chatSession?.stop()
        state.status = .cancelled
        // Mirror the markCompleted finalisation for the agent_runs row
        // so cancelled runs don't sit in `running` forever in the
        // Activity tab.
        if let runId = state.agentRunId {
            let cancelError = state.budgetExhaustedReason.map { "Budget exhausted: \($0)" }
            Self.writeRunTrace(
                runId: runId,
                state: state,
                status: .cancelled,
                endedAt: Date(),
                errorMessage: cancelError
            )
            do {
                try SchedulerDatabase.shared.recordRunEnd(
                    runId: runId,
                    status: .cancelled,
                    tokensIn: state.tokensIn > 0 ? state.tokensIn : nil,
                    tokensOut: state.tokensOut > 0 ? state.tokensOut : nil,
                    costUSD: state.costUSD > 0 ? state.costUSD : nil,
                    error: cancelError
                )
            } catch {
                print("[BackgroundTaskManager] recordRunEnd (cancel) failed for run \(runId): \(error)")
            }
            state.agentRunId = nil
        }
        resumeCompletion(for: backgroundId, result: .cancelled)
        emitPluginEvent(
            state,
            type: .cancelled,
            json: PluginHostContext.serializeCancelledEvent(taskTitle: state.taskTitle)
        )
        scheduleAutoFinalize(backgroundId)
    }

    /// Soft-stop a running task by cancelling its current stream.
    ///
    /// When `message` is non-empty, the trimmed content is appended to the
    /// session as a `user`-role turn before the stream is cancelled. The
    /// model picks the message up on the next user turn — i.e. when the
    /// user opens the chat window, when the plugin dispatches a follow-up,
    /// or when the session is otherwise resumed. This is the documented
    /// behavior of `dispatch_interrupt` on the v3 surface.
    ///
    /// Empty / whitespace-only messages just cancel the stream, matching
    /// the original soft-stop semantics. The chat task can always be
    /// resumed by the user opening its window and sending a follow-up.
    public func interruptTask(_ backgroundId: UUID, message: String?) {
        guard let state = backgroundTasks[backgroundId], state.status.isActive else { return }
        if let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            // Inject as a user-role turn so the next user-driven completion
            // round (which the user or another dispatch will trigger) sees
            // it as part of the conversation history.
            state.chatSession?.appendInterruptMessage(trimmed)
        }
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

    /// External-surface flag bound around the dispatched run. Widen-only:
    /// a request marked external (non-loopback HTTP dispatch) or a dispatch
    /// issued from an already-external execution context runs external; a
    /// trusted loopback/plugin/schedule request never clears an inherited
    /// external context.
    nonisolated static func resolvedExternalSurface(for request: DispatchRequest) -> Bool {
        request.externalSurface || ChatExecutionContext.isExternalSurface
    }

    /// Dispatch a chat task for background execution.
    public func dispatchChat(_ request: DispatchRequest) async -> DispatchHandle? {
        // Background dispatch is an external surface (HTTP / plugins /
        // schedules). Built-in agents (the Default agent) are only
        // reachable from the in-app Chat — refuse to route any non-Chat
        // traffic to them, and refuse to silently default to the built-in
        // agent when an anonymous request comes in.
        if Agent.rejectBuiltInForExternalSurface(
            request.agentId,
            source: "background/dispatchChat"
        ) != nil {
            return nil
        }

        guard canDispatchNewTask(source: request.source, agentId: request.agentId) else { return nil }

        // KPI: an agent run accepted via background dispatch (HTTP dispatch
        // endpoint, plugin, or schedule).
        FeatureTelemetry.agentRun(source: "dispatch")

        // The reattach lookup below opens the chat-history DB, which needs the
        // storage key. On a cold-start race the launch prewarm may not have
        // landed yet, and `db.open()` would run the keychain read synchronously
        // on the main actor and hang the UI. Warm it off the cooperative
        // executor first so the open hits the in-memory cache. Idempotent.
        try? await StorageKeyManager.shared.prewarmCurrentKeyOffCooperativeExecutor()

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

        // Plugin-supplied tool whitelist (already host-validated in
        // `planDispatch`) lands in the same `additionalToolNames`
        // channel `capabilities_load` uses, so the dispatched
        // `ChatSession.send -> composeChatContext` picks it up on
        // turn 1. Reattach reuses `existing.id` as `context.id`, so
        // successive dispatches into the same conversation accumulate
        // via the store's underlying `Set`.
        if !request.requestedToolNames.isEmpty {
            await SessionToolStateStore.shared.appendLoadedTools(
                context.id.uuidString,
                names: request.requestedToolNames,
                fallbackAlwaysLoadedNames: nil
            )
        }

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

        // Agent DB run logging (spec §1.4 + §8). Only DB-enabled agents
        // get an `agent_runs` row + a bound `currentRunId`; for the
        // default agent and any user-created agent that hasn't opted
        // in, this is a no-op so the existing dispatch surface keeps
        // the same behavior and the same overhead.
        let agentMgr = AgentManager.shared
        let dbEnabled = agentMgr.effectiveDBEnabled(for: context.agentId)
        // Pre-seed the per-run budget caps from `Agent.settings.limits`
        // (spec §11.3). `tokensIn/Out` and `costUSD` start at 0 and are
        // updated mid-stream by `recordUsage(...)`; the dispatcher
        // cancels the task once either threshold is crossed.
        if let agent = agentMgr.agent(for: context.agentId) {
            state.runTokensLimit = agent.settings.limits.runTokensLimit
            state.runCostUSDLimit = agent.settings.limits.runCostUSDLimit
        }
        var boundRunId: UUID? = nil
        var boundActor: String = "user"
        if dbEnabled {
            let triggerKind = Self.triggerKind(for: request.source)
            // `triggerPayload` is intentionally minimal: persisting the
            // full prompt here would duplicate ChatHistoryDatabase data
            // and inflate the scheduler DB. We surface the dispatch
            // source + external key so the Activity tab can tag the
            // row with what woke it.
            let triggerPayload = Self.triggerPayload(for: request)
            do {
                try SchedulerDatabase.shared.open()
                let runId = try SchedulerDatabase.shared.recordRunStart(
                    agentId: context.agentId,
                    triggerKind: triggerKind,
                    triggerPayload: triggerPayload,
                    instructions: request.prompt
                )
                boundRunId = runId
                state.agentRunId = runId
                boundActor = "agent"
            } catch {
                print(
                    "[BackgroundTaskManager] recordRunStart failed for agent "
                        + "\(context.agentId): \(error)"
                )
            }
        }

        // Bind the run-id + actor + background-task id for the entire
        // chat task. `chatSession.send` creates an unstructured
        // `Task { @MainActor in ... }` inside `ExecutionContext.start`
        // — unstructured Tasks inherit task locals captured at the
        // moment of creation, so any `db_*` tool call or streaming
        // producer dispatched from the inference loop picks these up
        // without needing per-call wiring. `currentBackgroundId` is
        // the same `BackgroundTaskState.id` we just registered, so
        // streaming layers can call `recordUsage(backgroundId:)` for
        // mid-stream budget enforcement (spec §11.3).
        //
        // `isExternalSurface` is rebound here from request metadata so the
        // externally-denied tool policy holds at the dispatcher layer even if
        // an upstream task-local binding (e.g. the HTTP handler's wrapper)
        // were lost across the dispatch pipeline. External-ness can only be
        // widened, never narrowed: an inherited external context stays
        // external for loopback/plugin/schedule requests too.
        let externalSurface = Self.resolvedExternalSurface(for: request)
        await ChatExecutionContext.$isExternalSurface.withValue(externalSurface) {
            await ChatExecutionContext.$currentRunId.withValue(boundRunId) {
                await ChatExecutionContext.$currentRunActor.withValue(boundActor) {
                    await ChatExecutionContext.$currentBackgroundId.withValue(context.id) {
                        await context.start(prompt: request.prompt)
                    }
                }
            }
        }

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

        let globalLimit = ToastManager.shared.configuration.maxConcurrentTasks
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
        recomputeSortedToastTasks()
        state.appendActivity(kind: .info, title: "Running in background")
        emitPluginEvent(state, type: .started, json: PluginHostContext.serializeStartedEvent(state: state))
    }

    #if DEBUG
        /// Test-only: insert a pre-built `BackgroundTaskState` directly so
        /// regression tests can exercise `observeChatTask` without spinning up
        /// a real `ExecutionContext` + MLX-backed engine.
        func registerTaskForTesting(_ state: BackgroundTaskState) {
            backgroundTasks[state.id] = state
            recomputeSortedToastTasks()
        }
    #endif

    private func createContext(for request: DispatchRequest) -> ExecutionContext {
        // `dispatchChat` rejects requests with `agentId == nil || ==
        // Agent.defaultId` before reaching here (see the
        // `rejectBuiltInForExternalSurface` guard at the top of
        // `dispatchChat`). The historical `?? Agent.defaultId` fallback
        // would silently route anonymous traffic to the built-in Default
        // agent — we keep the precondition explicit instead of restoring
        // the fallback.
        precondition(
            request.agentId != nil && request.agentId != Agent.defaultId,
            "BackgroundTaskManager.createContext invoked with nil or default agentId; dispatchChat should have rejected the request."
        )
        return ExecutionContext(
            id: request.id,
            agentId: request.agentId!,
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

    /// Map a dispatch source to the audit-trail trigger kind we persist
    /// in `agent_runs`. Spec §16 leaves room for finer breakdowns; this
    /// is the minimal mapping that's stable for Phase 1.
    private static func triggerKind(for source: SessionSource) -> AgentRunTriggerKind {
        switch source {
        case .chat, .plugin, .http: return .user
        case .schedule: return .recurringSchedule
        case .watcher: return .watcher
        case .selfSchedule: return .schedule
        }
    }

    /// Compact JSON describing what dispatched this run. Skips the
    /// prompt itself (already in ChatHistoryDatabase) and the plugin
    /// secrets — just the source + grouping key the Activity tab
    /// surfaces.
    private static func triggerPayload(for request: DispatchRequest) -> String? {
        var fields: [String: String] = ["source": request.source.rawValue]
        if let pluginId = request.sourcePluginId, !pluginId.isEmpty {
            fields["plugin_id"] = pluginId
        }
        if let key = request.externalSessionKey, !key.isEmpty {
            fields["external_session_key"] = key
        }
        guard let data = try? JSONEncoder().encode(fields),
            let json = String(data: data, encoding: .utf8)
        else { return nil }
        return json
    }

    /// Mark a task as completed and signal callers.
    /// The toast persists until the user views it or dismisses manually.
    private func markCompleted(_ state: BackgroundTaskState, success: Bool, summary: String) {
        state.status = .completed(success: success, summary: summary)
        state.currentStep = nil
        state.executionContext?.chatSession.save()
        // Close out the scheduler `agent_runs` row, if one was opened
        // for this task. `recordRunEnd` is a single UPDATE so the cost
        // is negligible; failure to write only forfeits the audit
        // trail entry, never the task's completion signal.
        if let runId = state.agentRunId {
            let endStatus: AgentRunStatus = success ? .success : .error
            let errorMessage: String? = success ? nil : summary
            // Persist the per-run JSON trace BEFORE we null out
            // `agentRunId` so subsequent retries/observers can't
            // accidentally write it twice (spec §1.8).
            Self.writeRunTrace(
                runId: runId,
                state: state,
                status: endStatus,
                endedAt: Date(),
                errorMessage: errorMessage
            )
            do {
                try SchedulerDatabase.shared.recordRunEnd(
                    runId: runId,
                    status: endStatus,
                    tokensIn: state.tokensIn > 0 ? state.tokensIn : nil,
                    tokensOut: state.tokensOut > 0 ? state.tokensOut : nil,
                    costUSD: state.costUSD > 0 ? state.costUSD : nil,
                    error: errorMessage
                )
            } catch {
                print("[BackgroundTaskManager] recordRunEnd failed for run \(runId): \(error)")
            }
            state.agentRunId = nil
        }
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

    // MARK: - Private: Run-Trace Persistence

    /// Capture the terminal state of a chat task as a `RunTrace` and
    /// write it to disk under `~/.osaurus/agents/<id>/runs/<run_id>.json`
    /// (spec §1.8). Static + MainActor so the call site doesn't need
    /// to hop actors; the actual file write is synchronous but
    /// best-effort — failures are logged and swallowed.
    private static func writeRunTrace(
        runId: UUID,
        state: BackgroundTaskState,
        status: AgentRunStatus,
        endedAt: Date,
        errorMessage: String?
    ) {
        let turns: [RunTrace.Turn] = (state.chatSession?.turns ?? []).map { turn in
            let callSnapshots: [RunTrace.ToolCallSnapshot]? = turn.toolCalls.flatMap {
                $0.isEmpty
                    ? nil
                    : $0.map {
                        RunTrace.ToolCallSnapshot(
                            id: $0.id,
                            name: $0.function.name,
                            arguments: $0.function.arguments
                        )
                    }
            }
            return RunTrace.Turn(
                id: turn.id,
                role: turn.role.rawValue,
                content: turn.content,
                thinking: turn.thinkingIsEmpty ? nil : turn.thinking,
                toolCalls: callSnapshots,
                toolCallId: turn.toolCallId,
                toolResults: turn.toolResults.isEmpty ? nil : turn.toolResults
            )
        }
        let trace = RunTrace(
            runId: runId,
            agentId: state.agentId,
            sessionId: state.id.uuidString,
            triggerSource: state.source.rawValue,
            status: status.rawValue,
            startedAt: state.createdAt,
            endedAt: endedAt,
            tokensIn: state.tokensIn > 0 ? state.tokensIn : nil,
            tokensOut: state.tokensOut > 0 ? state.tokensOut : nil,
            costUSD: state.costUSD > 0 ? state.costUSD : nil,
            errorMessage: errorMessage,
            turns: turns
        )
        RunTraceWriter.write(trace)
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

        // Observe clarify pause state. Both the chat-layer intercept
        // (which sets `awaitingClarify`) and the resume path in
        // `ChatSession.send(...)` (which clears it) run on the main
        // actor before `isStreaming` flips, so the clarify update
        // always reaches `handleChatClarifyChange` ahead of the
        // streaming-end tick — that ordering gates the COMPLETED
        // suppression in `handleChatStreamingChange`.
        session.$awaitingClarify
            .removeDuplicates()
            .sink { [weak self] payload in
                self?.handleChatClarifyChange(taskId: taskId, payload: payload)
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
            // Belt-and-suspenders: if the streaming-end tick somehow
            // races ahead of the clarify sink, inspect the live session
            // before tripping the terminal branch. The `.running` guard
            // above already excludes the normal post-bridge case.
            if state.chatSession?.awaitingClarify != nil { return }
            if let lastError {
                markCompleted(state, success: false, summary: lastError)
            } else {
                markCompleted(state, success: true, summary: "Chat completed")
            }
        }
    }

    /// Bridge `ChatSession.awaitingClarify` into the per-task plugin event
    /// surface. Setting a payload transitions the task to
    /// `.awaitingClarification` and emits `OSR_TASK_EVENT_CLARIFICATION`.
    /// Clearing it is a no-op here — the next streaming tick is the
    /// single writer for the `.running` transition.
    private func handleChatClarifyChange(taskId: UUID, payload: ClarifyPayload?) {
        guard let state = backgroundTasks[taskId], let payload else { return }
        state.status = .awaitingClarification
        state.currentStep = "Waiting for clarification"
        emitPluginEvent(
            state,
            type: .clarification,
            json: PluginHostContext.serializeClarificationEvent(payload: payload)
        )
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
