//
//  ExecutionContext.swift
//  osaurus
//
//  Window-free execution primitive that owns ChatSession + WorkSession.
//  Runs tasks headlessly; windows are created lazily only when needed for UI.
//
//  Used by:
//  - TaskDispatcher (chat mode, managed directly)
//  - BackgroundTaskManager (work mode, via dispatchWork)
//  - Future webhook handlers (headless, no UI)
//

import Foundation

/// Lightweight execution context that runs Chat or Work tasks without requiring a window.
@MainActor
public final class ExecutionContext: ObservableObject {

    /// Unique identifier for this execution
    public let id: UUID

    /// Whether running in Chat or Work mode
    public let mode: ChatMode

    /// Agent used for this execution
    public let agentId: UUID

    /// Display title for the execution
    public let title: String?

    let chatSession: ChatSession
    let folderBookmark: Data?
    public private(set) var workSession: WorkSession?

    /// Whether execution is currently in progress
    public var isExecuting: Bool {
        switch mode {
        case .chat: chatSession.isStreaming
        case .work: workSession?.isExecuting ?? false
        }
    }

    // MARK: - Initialization

    public init(
        id: UUID = UUID(),
        mode: ChatMode,
        agentId: UUID,
        title: String? = nil,
        folderBookmark: Data? = nil
    ) {
        self.id = id
        self.mode = mode
        self.agentId = agentId
        self.title = title
        self.folderBookmark = folderBookmark

        // Configure chat session (no window required)
        let session = ChatSession()
        session.agentId = agentId
        session.applyInitialModelSelection()
        if let title { session.title = title }
        self.chatSession = session

        // Create work session if needed
        if mode == .work {
            WorkToolManager.shared.registerTools()
            self.workSession = WorkSession(agentId: agentId)
        }
    }

    // MARK: - Execution

    /// Load model options. Call before `start(prompt:)`.
    public func prepare() async {
        await chatSession.refreshModelOptions()

        if let work = workSession {
            work.modelOptions = chatSession.modelOptions
            work.selectedModel = chatSession.selectedModel
        }
    }

    /// Begin execution with the given prompt.
    public func start(prompt: String) async {
        switch mode {
        case .chat:
            chatSession.send(prompt)
        case .work:
            await activateFolderContextIfNeeded()
            do {
                try await workSession?.dispatch(query: prompt)
            } catch {
                print("[ExecutionContext] Work dispatch failed: \(error.localizedDescription)")
            }
        }
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
            await WorkFolderContextService.shared.setFolder(url)
        } catch {
            print("[ExecutionContext] Failed to resolve folder bookmark: \(error)")
        }
    }

    /// Poll until execution completes or the task is cancelled.
    /// Used for chat mode only; work mode completion is observed by BackgroundTaskManager via Combine.
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
    public func cancel() {
        switch mode {
        case .chat: chatSession.stop()
        case .work: workSession?.stopExecution()
        }
    }
}
