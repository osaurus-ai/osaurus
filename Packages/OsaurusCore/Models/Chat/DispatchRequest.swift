//
//  DispatchRequest.swift
//  osaurus
//
//  Async dispatch trigger for running a chat task.
//  Any trigger (automations, shortcuts, plugins, etc.) creates a
//  DispatchRequest and hands it to `BackgroundTaskManager.dispatchChat`,
//  which submits it to the task scheduler as an agent-turn task.
//

import Foundation

/// The original task supplied by the caller, before the app adds delivery or
/// execution instructions. Host-only provenance: never decoded from model/API
/// output and never substituted for the complete model-visible prompt.
public enum ChatTaskIntent: Sendable, Equatable {
    case userRequest(String)
    /// App-authored context/report delivery with no new user task. The full
    /// message remains model-visible and tools remain available under auto.
    case hostContinuation

    public init(userText: String) {
        self = .userRequest(userText)
    }

    public var userText: String? {
        if case .userRequest(let text) = self { return text }
        return nil
    }
}

// MARK: - Request

/// Describes a task to dispatch as a (possibly headless) chat session.
public struct DispatchRequest: Sendable {
    public let id: UUID
    public let prompt: String
    /// Optional original-task provenance when `prompt` contains app-authored
    /// wrappers. Nil means the prompt itself is the caller's task.
    public let taskIntent: ChatTaskIntent?
    /// Explicit one-run controls; omitted values inherit the selected agent/model.
    public let generationOverrides: ChatTurnOverrides?
    /// Host-only execution provenance; never persisted or supplied by a model
    /// or an HTTP payload. Delegation explicitly carries it across queued work.
    var inferenceSourceOverride: RequestSource? = nil
    /// Who runs this: an agent hosted here, or a teammate's shared workspace
    /// agent (run on their Mac over the relay). nil = anonymous, which every
    /// non-Chat surface refuses (`Agent.rejectBuiltInForExternalSurface`).
    public let target: AgentDispatchTarget?
    /// The local agent id, for the many readers that only understand local
    /// agents. nil for anonymous AND for workspace targets — callers that
    /// must tell those apart read `target`.
    public var agentId: UUID? { target?.localId }
    /// The shared workspace agent this dispatch runs, or nil for local.
    public var workspaceTarget: WorkspaceAgentRef? { target?.workspaceRef }
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
    /// The trigger kind when `source == .automation`, persisted on the
    /// session; nil otherwise.
    public let automationKind: EventSourceKind?
    /// The source bound for the run's gates
    /// (`SessionSource.runtimeSource(automationKind:)`).
    public var runtimeSource: SessionSource { source.runtimeSource(automationKind: automationKind) }
    /// Stable external grouping key (e.g. Telegram chat id, HTTP `X-Session-Id`).
    /// Lets repeated dispatches from the same conversation accrete into one
    /// persisted session row instead of a fresh one per call.
    public let externalSessionKey: String?
    /// When false, `externalSessionKey` only tags the new session (so the
    /// sidebar can group runs by trigger) and never reattaches to an earlier
    /// row. Schedules use this so every run starts a fresh chat.
    public let reattachSession: Bool
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
    /// agent's `spawn_agent` call). Derived from `source` —
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
    /// Exact model resolved and priced by delegated-run admission.
    public let delegationModel: String?

    /// An app-authored trigger fired with no interactive user to answer an
    /// approval card (a schedule or folder automation firing on its own).
    /// Set at the trigger boundary, never derived from `source`: every
    /// automation now records `.automation`, and a webhook firing on its
    /// own is not unattended in this sense. Never honored for an external
    /// surface.
    public let unattended: Bool
    /// The queue the run waits on; nil = Default.
    public let queueId: UUID?
    /// Which door the run came through, for its task record; nil derives it
    /// from `source`.
    public let taskOrigin: TaskOrigin?
    /// The automation that started the run.
    public let subscriptionId: UUID?
    /// Who wrote the prompt when it isn't the person at this Mac (a channel
    /// sender). Stamped on the run's first user turn and bound as
    /// `ChatExecutionContext.currentParticipant` for the run.
    public let author: ParticipantRef?
    /// Runs the agent on this stored session's existing turns instead of a
    /// new prompt. The dispatch is refused when the session can't be loaded
    /// or another run already drives it.
    public let continueSessionId: UUID?
    /// Set by `SyncHostRunner`: the run's tool approvals go to this sync
    /// conversation. Bound as `ChatExecutionContext.syncReviewerScope`.
    let syncReviewerScope: String?
    /// A hosted run's own choices (`HostRunRequest`), from one of the
    /// user's own devices. Set by `SyncHostRunner` only.
    var hostedRun: HostedRunChoices?

    struct HostedRunChoices: Sendable, Equatable {
        /// Picker id the run uses instead of the agent's model.
        var model: String?
        /// Instructions for this run only, appended to the system prompt.
        var instructions: String?
        var voiceCall = false
        var privacy: VoiceCallPrivacy?
        var image: HostRunRequest.ImageSettings?
    }

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

    /// `agentId` and `target` are two spellings of the same field: pass one.
    /// `target` wins when both are given.
    public init(
        id: UUID = UUID(),
        prompt: String,
        agentId: UUID? = nil,
        target: AgentDispatchTarget? = nil,
        title: String? = nil,
        parameters: [String: String] = [:],
        folderPath: String? = nil,
        folderBookmark: Data? = nil,
        showToast: Bool = true,
        sourcePluginId: String? = nil,
        source: SessionSource = .chat,
        automationKind: EventSourceKind? = nil,
        externalSessionKey: String? = nil,
        reattachSession: Bool = true,
        requestedToolNames: [String] = [],
        externalSurface: Bool = false,
        loadIntent: ModelLoadIntent = .interactive,
        delegationResponseTokenCap: Int? = nil,
        delegationContextPositionCap: Int? = nil,
        delegationAssistantTurnCap: Int? = nil,
        delegationModel: String? = nil,
        unattended: Bool = false,
        queueId: UUID? = nil,
        taskOrigin: TaskOrigin? = nil,
        subscriptionId: UUID? = nil,
        author: ParticipantRef? = nil,
        continueSessionId: UUID? = nil,
        taskIntent: ChatTaskIntent? = nil,
        generationOverrides: ChatTurnOverrides? = nil
    ) {
        self.init(
            id: id, prompt: prompt, agentId: agentId, target: target, title: title, parameters: parameters,
            folderPath: folderPath, folderBookmark: folderBookmark, showToast: showToast,
            sourcePluginId: sourcePluginId, source: source, automationKind: automationKind,
            externalSessionKey: externalSessionKey, reattachSession: reattachSession,
            requestedToolNames: requestedToolNames, externalSurface: externalSurface, loadIntent: loadIntent,
            delegationResponseTokenCap: delegationResponseTokenCap,
            delegationContextPositionCap: delegationContextPositionCap,
            delegationAssistantTurnCap: delegationAssistantTurnCap, delegationModel: delegationModel,
            unattended: unattended, queueId: queueId, taskOrigin: taskOrigin, subscriptionId: subscriptionId,
            author: author, continueSessionId: continueSessionId, taskIntent: taskIntent,
            generationOverrides: generationOverrides, syncReviewerScope: nil
        )
    }

    init(
        id: UUID = UUID(),
        prompt: String,
        agentId: UUID? = nil,
        target: AgentDispatchTarget? = nil,
        title: String? = nil,
        parameters: [String: String] = [:],
        folderPath: String? = nil,
        folderBookmark: Data? = nil,
        showToast: Bool = true,
        sourcePluginId: String? = nil,
        source: SessionSource = .chat,
        automationKind: EventSourceKind? = nil,
        externalSessionKey: String? = nil,
        reattachSession: Bool = true,
        requestedToolNames: [String] = [],
        externalSurface: Bool = false,
        loadIntent: ModelLoadIntent = .interactive,
        delegationResponseTokenCap: Int? = nil,
        delegationContextPositionCap: Int? = nil,
        delegationAssistantTurnCap: Int? = nil,
        delegationModel: String? = nil,
        unattended: Bool = false,
        queueId: UUID? = nil,
        taskOrigin: TaskOrigin? = nil,
        subscriptionId: UUID? = nil,
        author: ParticipantRef? = nil,
        continueSessionId: UUID? = nil,
        taskIntent: ChatTaskIntent? = nil,
        generationOverrides: ChatTurnOverrides? = nil,
        syncReviewerScope: String?
    ) {
        self.continueSessionId = continueSessionId
        self.syncReviewerScope = syncReviewerScope
        self.author = author
        self.unattended = unattended
        self.queueId = queueId
        self.taskOrigin = taskOrigin
        self.subscriptionId = subscriptionId
        self.id = id
        self.prompt = prompt
        self.taskIntent = taskIntent
        self.generationOverrides = generationOverrides
        self.target = target ?? agentId.map(AgentDispatchTarget.local)
        self.title = title
        self.parameters = parameters
        self.folderPath = folderPath
        self.folderBookmark = folderBookmark
        self.showToast = showToast
        self.sourcePluginId = sourcePluginId
        self.source = source
        self.automationKind = source == .automation ? automationKind : nil
        self.externalSessionKey = externalSessionKey
        self.reattachSession = reattachSession
        self.requestedToolNames = requestedToolNames
        self.externalSurface = externalSurface
        self.loadIntent = loadIntent
        self.delegationResponseTokenCap = delegationResponseTokenCap
        self.delegationContextPositionCap = delegationContextPositionCap
        self.delegationAssistantTurnCap = delegationAssistantTurnCap
        self.delegationModel = source == .delegation ? delegationModel : nil
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
