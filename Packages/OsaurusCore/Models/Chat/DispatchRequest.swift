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

    /// True when this dispatch is a TRUE agent delegation (an orchestrating
    /// agent's `spawn_agent` / `spawn_batch` call). Derived from `source` —
    /// delegation always dispatches with `source: .delegation` — so there is
    /// exactly one source of truth. The dispatcher binds the source as
    /// `ChatExecutionContext.currentSessionSource` for the run (and
    /// `ChatSession.send` rebinds it from the persisted session on every
    /// turn), which the chat context composer uses to strip `spawn_*` tools
    /// from the delegated child so a helper can never fan out recursively.
    public var isDelegatedRun: Bool { source == .delegation }

    /// Enforced delegation budget for `.delegation` dispatches: the child
    /// run's per-generation response-token cap and assistant tool-loop turn
    /// cap, from the launcher's `SubagentBudgets`. nil (every other source)
    /// leaves the chat surface's normal limits untouched. RAM admission
    /// prices delegated children from EXACTLY these values, so they must be
    /// enforced — a priced-but-unenforced bound would be fail-open.
    public let delegationResponseTokenCap: Int?
    public let delegationAssistantTurnCap: Int?
    public let delegationContextPositionCap: Int?

    /// The enforced delegation contract carried by this request, or nil.
    /// All three caps must be present to form a contract — a partial
    /// contract is no contract (nothing is clamped, and admission priced
    /// nothing bounded). This is THE conversion `BackgroundTaskManager`
    /// uses when building the dispatched `ExecutionContext`.
    public var delegationContract: DelegatedRunContract? {
        guard
            let tokens = delegationResponseTokenCap,
            let turns = delegationAssistantTurnCap,
            let positions = delegationContextPositionCap
        else { return nil }
        return DelegatedRunContract(
            responseTokens: tokens,
            assistantTurns: turns,
            contextPositions: positions
        )
    }

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
        loadIntent: ModelLoadIntent = .interactive,
        delegationResponseTokenCap: Int? = nil,
        delegationContextPositionCap: Int? = nil,
        delegationAssistantTurnCap: Int? = nil
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
        self.delegationResponseTokenCap = delegationResponseTokenCap
        self.delegationContextPositionCap = delegationContextPositionCap
        self.delegationAssistantTurnCap = delegationAssistantTurnCap
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
