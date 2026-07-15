//
//  DispatchRequest.swift
//  osaurus
//
//  Async dispatch trigger for running a chat task.
//  Any trigger (schedules, webhooks, shortcuts, plugins, etc.) creates a
//  DispatchRequest and hands it to TaskDispatcher.
//

import Foundation

// MARK: - Request

/// Describes a task to dispatch as a (possibly headless) chat session.
public struct DispatchRequest: Sendable {
    public let id: UUID
    public let prompt: String
    public let agentId: UUID?
    public let title: String?
    public let parameters: [String: String]
    public let folderPath: String?
    public let folderBookmark: Data?
    /// Set to `false` for headless execution (e.g. webhooks).
    public let showToast: Bool
    /// Plugin that originated this dispatch (for on_task_event callback routing).
    public let sourcePluginId: String?
    /// Where this dispatch came from. Drives the persisted `SessionSource`
    /// so the sidebar / DB can distinguish plugin / HTTP / scheduler runs
    /// from user-initiated chats.
    public let source: SessionSource
    /// Stable external grouping key (e.g. Telegram chat id, HTTP `X-Session-Id`).
    /// Lets repeated dispatches from the same conversation accrete into one
    /// persisted session row instead of a fresh one per call.
    public let externalSessionKey: String?
    /// Tool names the dispatcher wants exposed to the model on top of the
    /// agent's normal selection (auto-mode preflight or manual list).
    /// Plugin-sourced dispatches populate this from the validated `tools`
    /// array on the dispatch JSON; the host has already filtered names to
    /// the calling plugin's own manifest tools plus host built-in
    /// always-loaded names. Empty for non-plugin sources today; safe to
    /// feed straight into `SessionToolStateStore.appendLoadedTools` since
    /// the names are pre-validated.
    public let requestedToolNames: [String]
    /// True when the dispatch originated from an EXTERNAL surface (for
    /// example a non-loopback HTTP `/agents/{id}/dispatch` call). The
    /// dispatcher rebinds `ChatExecutionContext.isExternalSurface` from this
    /// flag at run start, so externally-denied tools stay denied even if the
    /// task-local binding at the HTTP layer were lost across the dispatch
    /// pipeline. Never used to relax an inherited external-surface context.
    public let externalSurface: Bool
    /// Whether this run's model load may evict a model someone else is using.
    ///
    /// Deliberately NOT derived from `source`. `source` records *where* a run
    /// came from; this records whether anyone is *waiting on it*, and the two
    /// genuinely differ: a cron-fired schedule and the user pressing "Run Now"
    /// on that same schedule both arrive as `.schedule`, but only one of them
    /// has a human watching a spinner. Inferring intent from `source` would
    /// make the button refuse to load its own model.
    ///
    /// So it is set at the trigger boundary — the one place that knows. Timer
    /// fires, watcher fires and agent self-wakes pass `.background`; every
    /// hand-pressed button and every waiting API client keeps the default.
    public let loadIntent: ModelLoadIntent

    public init(
        id: UUID = UUID(),
        prompt: String,
        agentId: UUID? = nil,
        title: String? = nil,
        parameters: [String: String] = [:],
        folderPath: String? = nil,
        folderBookmark: Data? = nil,
        showToast: Bool = true,
        sourcePluginId: String? = nil,
        source: SessionSource = .chat,
        externalSessionKey: String? = nil,
        requestedToolNames: [String] = [],
        externalSurface: Bool = false,
        loadIntent: ModelLoadIntent = .interactive
    ) {
        self.id = id
        self.prompt = prompt
        self.agentId = agentId
        self.title = title
        self.parameters = parameters
        self.folderPath = folderPath
        self.folderBookmark = folderBookmark
        self.showToast = showToast
        self.sourcePluginId = sourcePluginId
        self.source = source
        self.externalSessionKey = externalSessionKey
        self.requestedToolNames = requestedToolNames
        self.externalSurface = externalSurface
        self.loadIntent = loadIntent
    }
}

// MARK: - Handle

/// Returned after dispatch; used for observation and cancellation
public struct DispatchHandle: Sendable {
    public let id: UUID
    public let request: DispatchRequest
}

// MARK: - Result

/// Outcome of a dispatched task
public enum DispatchResult: Sendable {
    case completed(sessionId: UUID?)
    case cancelled
    case failed(String)
}
