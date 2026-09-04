//
//  ExecutionContext.swift
//  osaurus
//
//  Window-free execution primitive that owns a ChatSession and runs it
//  headlessly. Windows are created lazily only when needed for UI.
//
//  Used by:
//  - TaskDispatcher (scheduler / HTTP / plugin / watcher dispatch)
//  - BackgroundTaskManager.dispatchChat
//  - Future webhook handlers (headless, no UI)
//

import Foundation

/// Lightweight execution context that runs a chat task without requiring a window.
@MainActor
public final class ExecutionContext: ObservableObject {

    /// Unique identifier for this execution
    public let id: UUID

    /// Agent used for this execution
    public let agentId: UUID

    /// Display title for the execution
    public let title: String?

    let chatSession: ChatSession
    let folderBookmark: Data?
    /// Plain folder path for a dispatch whose folder has no picker bookmark
    /// (e.g. an orchestrator-created Watcher). Restored directly when no
    /// bookmark is present so the run still reaches its target folder.
    let folderPath: String?

    /// Whether execution is currently in progress
    public var isExecuting: Bool { chatSession.isStreaming }

    // MARK: - Initialization

    public init(
        id: UUID = UUID(),
        agentId: UUID,
        title: String? = nil,
        folderBookmark: Data? = nil,
        folderPath: String? = nil,
        source: SessionSource = .chat,
        sourcePluginId: String? = nil,
        externalSessionKey: String? = nil,
        loadIntent: ModelLoadIntent = .interactive,
        delegationBudget: DelegatedRunContract? = nil
    ) {
        self.id = id
        self.agentId = agentId
        self.title = title
        self.folderBookmark = folderBookmark
        self.folderPath = folderPath

        let session = ChatSession()
        session.delegationBudget = delegationBudget
        session.agentId = agentId
        // Align persisted session id with the dispatch task id so plugins
        // and HTTP pollers can deep-link to the same row, and so
        // `serializeCompletedEvent`'s `session_id` field references the
        // actual saved session.
        session.sessionId = id
        session.source = source
        session.loadIntent = loadIntent
        session.sourcePluginId = sourcePluginId
        session.externalSessionKey = externalSessionKey
        session.dispatchTaskId = id
        session.applyInitialModelSelection()
        if let title { session.title = title }
        self.chatSession = session
    }

    /// Reattach to a previously-persisted session so a new dispatch appends
    /// turns to the same conversation row instead of starting fresh. Used by
    /// `BackgroundTaskManager.dispatchChat` when the request carries an
    /// `external_session_key` that maps to an existing session.
    ///
    /// `existing.id` is reused as the dispatch task id, so callers polling
    /// the original `task_id` continue to find a live entry. The persisted
    /// model is re-applied in `prepare()` once picker items load.
    public init(
        reattaching existing: ChatSessionData,
        folderBookmark: Data? = nil,
        folderPath: String? = nil
    ) {
        self.id = existing.id
        self.agentId = existing.agentId ?? Agent.defaultId
        self.title = existing.title
        self.folderBookmark = folderBookmark
        self.folderPath = folderPath

        let session = ChatSession()
        session.agentId = existing.agentId
        // Apply identity + history immediately so observers (e.g. the
        // BackgroundTaskState activity feed) see the existing turns from
        // the very first publish.
        session.load(from: existing)
        // `load(from:)` may have failed to restore the model if picker
        // items aren't loaded yet; `prepare()` re-applies after refresh.
        self.chatSession = session
        self.pendingReattachSession = existing
    }

    /// Set when this context was built via `init(reattaching:)`. Lets
    /// `prepare()` re-apply the persisted model once picker items load.
    private var pendingReattachSession: ChatSessionData?

    /// Wrap a live `ChatSession` that's already streaming in a UI window so
    /// `BackgroundTaskManager.detachChatWindow` can keep the in-flight
    /// stream alive after the user closes the window. Reuses the existing
    /// instance verbatim — no new session, no disk hydration — so all
    /// existing publishers (`isStreaming`, `turns`, `awaitingClarify`, …)
    /// keep firing uninterrupted.
    init(adopting session: ChatSession, folderBookmark: Data? = nil, folderPath: String? = nil) {
        self.id = session.sessionId ?? UUID()
        self.agentId = session.agentId ?? Agent.defaultId
        self.title = session.title
        self.folderBookmark = folderBookmark
        self.folderPath = folderPath
        self.chatSession = session
    }

    // MARK: - Execution

    /// Load picker items. Call before `start(prompt:)`.
    public func prepare() async {
        await chatSession.refreshPickerItems()
        // For reattached sessions, re-apply the persisted model now that
        // picker items are populated — the load() call in init may have
        // fallen back to the agent default because the picker was empty.
        if let pending = pendingReattachSession {
            chatSession.load(from: pending)
            pendingReattachSession = nil
        }
        // Headless dispatches follow the agent's current default model on
        // every turn; the persisted session model is only a fallback. No-op
        // for window chats (see the method doc).
        chatSession.applyAgentDefaultModelForDispatch()
    }

    /// Begin execution with the given prompt.
    public func start(prompt: String) async {
        let folderFailure = await activateFolderContextIfNeeded()
        if let folderFailure {
            // The dispatch NAMED a folder and that folder cannot be read.
            // Proceeding silently produced the live Watcher failure: the run
            // fell back to the agent's sandbox, read `/workspace/agents/<uuid>`,
            // and reported "the monitored folder is empty" over a folder full
            // of files. The run still executes (the result must reach the
            // watcher log/UI), but the model is told the truth up front so it
            // reports the real problem instead of inventing one.
            chatSession.send(folderFailure + "\n\n" + prompt)
            return
        }
        chatSession.send(prompt)
    }

    /// Resolve the stored bookmark onto THIS context's session folder state
    /// before execution. An explicit dispatch bookmark overrides whatever
    /// folder the session had persisted (the dispatch asked for that folder);
    /// without one, a reattached session keeps its own restored folder. Never
    /// touches any other session's folder or process-wide state.
    /// Returns nil on success (or when no folder was requested). On failure
    /// returns a prompt preamble stating which folder could not be read, so
    /// the run reports the real problem instead of introspecting whatever
    /// directory its fallback execution mode happens to be rooted in.
    private func activateFolderContextIfNeeded() async -> String? {
        // A dispatch may carry a picker bookmark (GUI-created Watcher) OR a
        // plain path (orchestrator-created Watcher, whose config tool stores
        // no bookmark). Either must reach the run — a path-only dispatch used
        // to drop the folder entirely because only the bookmark was threaded.
        guard folderBookmark != nil || (folderPath?.isEmpty == false) else { return nil }
        let restored = await chatSession.folderState.restoreAndWait(
            bookmark: folderBookmark,
            path: folderPath
        )
        if restored == nil {
            let path = folderPath ?? "(bookmark-only)"
            print(
                "[ExecutionContext] Dispatch folder could not be restored: \(path) — run proceeds with an explicit folder-unreadable preamble"
            )
            return
                "IMPORTANT — the configured folder for this task, '\(path)', could not "
                + "be read (it is missing, not a directory, or macOS denied access). "
                + "Do NOT inspect other directories in its place and do NOT report the "
                + "folder as empty. Report this access problem as the outcome and stop; "
                + "the user can restore access by re-picking the folder in Settings → "
                + "Watchers."
        }
        // This folder came from a background dispatch (Watcher / schedule /
        // plugin), not an interactive UI pick. Mark it so
        // `prepareChatExecutionMode` honors it over the agent's default
        // sandbox — the dispatched agent must be able to see its target
        // folder (the Voice Memo Watcher "empty folder" bug).
        await MainActor.run { chatSession.folderContextFromDispatchBookmark = true }
        return nil
    }

    /// Poll until execution completes or the task is cancelled.
    public func awaitCompletion() async -> DispatchResult {
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms startup grace

        while isExecuting && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 250_000_000)  // 250ms poll
        }

        if Task.isCancelled { return .cancelled }

        // Persist so the "View" toast action can reload from disk
        chatSession.save()

        return .completed(sessionId: chatSession.sessionId)
    }

    /// Stop the running execution.
    public func cancel() { chatSession.stop() }
}
