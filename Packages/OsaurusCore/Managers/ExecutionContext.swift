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

    /// Whether execution is currently in progress
    public var isExecuting: Bool { chatSession.isStreaming }

    // MARK: - Initialization

    public init(
        id: UUID = UUID(),
        agentId: UUID,
        title: String? = nil,
        folderBookmark: Data? = nil,
        source: SessionSource = .chat,
        sourcePluginId: String? = nil,
        externalSessionKey: String? = nil
    ) {
        self.id = id
        self.agentId = agentId
        self.title = title
        self.folderBookmark = folderBookmark

        let session = ChatSession()
        session.agentId = agentId
        // Align persisted session id with the dispatch task id so plugins
        // and HTTP pollers can deep-link to the same row, and so
        // `serializeCompletedEvent`'s `session_id` field references the
        // actual saved session.
        session.sessionId = id
        session.source = source
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
        folderBookmark: Data? = nil
    ) {
        self.id = existing.id
        self.agentId = existing.agentId ?? Agent.defaultId
        self.title = existing.title
        self.folderBookmark = folderBookmark

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
    }

    /// Begin execution with the given prompt.
    public func start(prompt: String) async {
        await activateFolderContextIfNeeded()
        chatSession.send(prompt)
    }

    /// Resolve the stored bookmark and set the work folder context before execution.
    private func activateFolderContextIfNeeded() async {
        guard let bookmark = folderBookmark else { return }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard !isStale else {
                print("[ExecutionContext] Folder bookmark is stale, skipping")
                return
            }
            await FolderContextService.shared.setFolder(url)
        } catch {
            print("[ExecutionContext] Failed to resolve folder bookmark: \(error)")
        }
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
