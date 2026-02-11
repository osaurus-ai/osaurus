//
//  ExecutionContext.swift
//  osaurus
//
//  Window-free execution primitive that owns ChatSession + AgentSession.
//  Runs tasks headlessly; windows are created lazily only when needed for UI.
//
//  Used by:
//  - TaskDispatcher (chat mode, managed directly)
//  - BackgroundTaskManager (agent mode, via dispatchAgent)
//  - Future webhook handlers (headless, no UI)
//

import Foundation

/// Lightweight execution context that runs Chat or Agent tasks without requiring a window.
@MainActor
public final class ExecutionContext: ObservableObject {

    /// Unique identifier for this execution
    public let id: UUID

    /// Whether running in Chat or Agent mode
    public let mode: ChatMode

    /// Persona used for this execution
    public let personaId: UUID

    /// Display title for the execution
    public let title: String?

    let chatSession: ChatSession
    let folderBookmark: Data?
    public private(set) var agentSession: AgentSession?

    /// Whether execution is currently in progress
    public var isExecuting: Bool {
        switch mode {
        case .chat: chatSession.isStreaming
        case .agent: agentSession?.isExecuting ?? false
        }
    }

    // MARK: - Initialization

    public init(
        id: UUID = UUID(),
        mode: ChatMode,
        personaId: UUID,
        title: String? = nil,
        folderBookmark: Data? = nil
    ) {
        self.id = id
        self.mode = mode
        self.personaId = personaId
        self.title = title
        self.folderBookmark = folderBookmark

        // Configure chat session (no window required)
        let session = ChatSession()
        session.personaId = personaId
        session.applyInitialModelSelection()
        if let title { session.title = title }
        self.chatSession = session

        // Create agent session if needed
        if mode == .agent {
            AgentToolManager.shared.registerTools()
            self.agentSession = AgentSession(personaId: personaId)
        }
    }

    // MARK: - Execution

    /// Load model options. Call before `start(prompt:)`.
    public func prepare() async {
        await chatSession.refreshModelOptions()

        if let agent = agentSession {
            agent.modelOptions = chatSession.modelOptions
            agent.selectedModel = chatSession.selectedModel
        }
    }

    /// Begin execution with the given prompt.
    public func start(prompt: String) async {
        switch mode {
        case .chat:
            chatSession.send(prompt)
        case .agent:
            await activateFolderContextIfNeeded()
            do {
                try await agentSession?.dispatch(query: prompt)
            } catch {
                print("[ExecutionContext] Agent dispatch failed: \(error.localizedDescription)")
            }
        }
    }

    /// Resolve the stored bookmark and set the agent folder context before execution.
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
            await AgentFolderContextService.shared.setFolder(url)
        } catch {
            print("[ExecutionContext] Failed to resolve folder bookmark: \(error)")
        }
    }

    /// Poll until execution completes or the task is cancelled.
    /// Used for chat mode only; agent mode completion is observed by BackgroundTaskManager via Combine.
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
        case .agent: agentSession?.stopExecution()
        }
    }
}
