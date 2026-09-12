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

    /// Agent used for this execution. For a workspace target this is the
    /// hosting local agent (`Agent.defaultId`, exactly as a shared-agent chat
    /// tab does) — the local agent's prompt and tools are NOT used, the
    /// remote host runs its own.
    public let agentId: UUID

    /// The teammate's shared agent this context runs, when it is a Mode 2
    /// headless run; nil for every local run.
    public let workspaceTarget: WorkspaceAgentRef?

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
        delegationBudget: DelegatedRunContract? = nil,
        delegationModel: String? = nil
    ) {
        self.id = id
        self.agentId = agentId
        self.workspaceTarget = nil
        self.title = title
        self.folderBookmark = folderBookmark
        self.folderPath = folderPath

        let session = ChatSession()
        session.delegationBudget = delegationBudget
        session.delegationModel = source == .delegation ? delegationModel : nil
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

    /// A headless Mode 2 run of a teammate's shared workspace agent. The
    /// session is stamped exactly like a shared-agent chat tab
    /// (`ChatWindowState.makeBlankTab(.workspace)`): hosted under the Default
    /// agent, `workspaceContext` set so History files it under the team
    /// agent, and the Mode 2 binding installed on the session itself since
    /// there is no window to carry it. `prepared` comes from
    /// `WorkspaceAgentRunClient.prepare`, i.e. the agent just answered a
    /// liveness probe and its provider is connected.
    init(
        id: UUID = UUID(),
        workspace prepared: WorkspaceAgentRunClient.Prepared,
        title: String? = nil,
        source: SessionSource,
        externalSessionKey: String? = nil,
        loadIntent: ModelLoadIntent = .interactive,
        delegationBudget: DelegatedRunContract? = nil
    ) {
        self.id = id
        self.agentId = Agent.defaultId
        self.workspaceTarget = prepared.ref
        self.title = title
        self.folderBookmark = nil
        self.folderPath = nil

        let session = ChatSession()
        session.delegationBudget = delegationBudget
        session.agentId = Agent.defaultId
        session.sessionId = id
        session.source = source
        session.loadIntent = loadIntent
        session.externalSessionKey = externalSessionKey
        session.dispatchTaskId = id
        session.workspaceContext = WorkspaceSessionContext(
            workspaceId: prepared.ref.workspaceId,
            agentAddress: prepared.ref.agentAddress
        )
        session.headlessRemoteAgentBinding = .init(
            providerId: prepared.providerId,
            effectiveModel: prepared.effectiveModel
        )
        session.title = title ?? prepared.displayName
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
    init(
        reattaching existing: ChatSessionData,
        folderBookmark: Data? = nil,
        folderPath: String? = nil,
        workspace prepared: WorkspaceAgentRunClient.Prepared? = nil
    ) {
        self.id = existing.id
        self.agentId = existing.agentId ?? Agent.defaultId
        self.workspaceTarget = prepared?.ref
        self.title = existing.title
        self.folderBookmark = folderBookmark
        self.folderPath = folderPath

        let session = ChatSession()
        session.agentId = existing.agentId
        // Apply identity + history immediately so observers (e.g. the
        // BackgroundTaskState activity feed) see the existing turns from
        // the very first publish.
        session.load(from: existing)
        if let prepared {
            // Reattaching to a shared-agent conversation: re-install the
            // Mode 2 binding (a fresh provider id after a re-pair is fine —
            // the persisted row keys on the workspace ref, not the provider).
            session.workspaceContext = WorkspaceSessionContext(
                workspaceId: prepared.ref.workspaceId,
                agentAddress: prepared.ref.agentAddress
            )
            session.headlessRemoteAgentBinding = .init(
                providerId: prepared.providerId,
                effectiveModel: prepared.effectiveModel
            )
        }
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
        self.workspaceTarget = nil
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
        // for window chats (see the method doc). A workspace target sends
        // no model at all (the host picks its own), so leave the pin alone.
        if workspaceTarget == nil {
            chatSession.applyAgentDefaultModelForDispatch()
        }
    }

    /// Begin execution with the given prompt.
    public func start(prompt: String, toolIntentText: String? = nil) async {
        let folderFailure = await activateFolderContextIfNeeded()
        if let folderFailure {
            // The dispatch NAMED a folder and that folder cannot be read.
            // Proceeding silently produced the live Watcher failure: the run
            // fell back to the agent's sandbox, read `/workspace/agents/<uuid>`,
            // and reported "the monitored folder is empty" over a folder full
            // of files. The run still executes (the result must reach the
            // watcher log/UI), but the model is told the truth up front so it
            // reports the real problem instead of inventing one.
            chatSession.send(
                folderFailure + "\n\n" + prompt, toolIntentText: toolIntentText ?? prompt)
            return
        }
        chatSession.send(prompt, toolIntentText: toolIntentText)
    }

    /// Resolve the stored bookmark onto THIS context's session folder state
    /// before execution. The folder this context was built with (an explicit
    /// dispatch folder, else the agent's working folder — see
    /// `BackgroundTaskManager.resolveDispatchFolder`) is the source of truth
    /// for a headless run: it overrides whatever folder a reattached session
    /// had persisted, and when it resolves to nothing the reattached session's
    /// restored folder is dropped too, so a folder inherited on an earlier run
    /// cannot outlive the setting that granted it (agent folder cleared,
    /// schedule/watcher folder removed). Never touches any other session's
    /// folder or process-wide state.
    /// Returns nil on success (or when no folder was requested). On failure
    /// returns a prompt preamble stating which folder could not be read, so
    /// the run reports the real problem instead of introspecting whatever
    /// directory its fallback execution mode happens to be rooted in.
    /// Internal (not private) so the dispatch-folder contract — folder
    /// restored onto THIS session, `folderContextFromDispatchBookmark` set —
    /// is unit-testable without starting inference.
    func activateFolderContextIfNeeded() async -> String? {
        // A dispatch may carry a picker bookmark (GUI-created Watcher) OR a
        // plain path (orchestrator-created Watcher, whose config tool stores
        // no bookmark). Either must reach the run — a path-only dispatch used
        // to drop the folder entirely because only the bookmark was threaded.
        //
        // No resolved folder is also a decision: drop whatever
        // `ChatSession.load` restored from a prior run so a cleared agent
        // folder (or a schedule/watcher that never had one) cannot keep
        // inheriting a stale session folder across reattach.
        guard folderBookmark != nil || (folderPath?.isEmpty == false) else {
            chatSession.folderState.clearFolder()
            chatSession.folderContextFromDispatchBookmark = false
            return nil
        }
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
                + "the user can restore access by re-picking the folder where it was "
                + "set — the Watcher or Schedule that owns it, or the agent's Working "
                + "Folder (chat folder chip / agent editor)."
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
