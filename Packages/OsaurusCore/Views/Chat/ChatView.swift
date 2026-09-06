//
//  ChatView.swift
//  osaurus
//
//  Created by Terence on 10/26/25.
//

import AppKit
import Combine
import LocalAuthentication
@preconcurrency import MLXLMCommon
import SwiftUI

/// Holds the derived, streaming-mutated `[ContentBlock]` list for the chat
/// thread. Kept as a separate `ObservableObject` so that per-token visibleBlocks
/// updates don't fire `ChatSession.objectWillChange` — that would force
/// `ChatView`'s entire body (and every sibling, notably `FloatingInputCard`
/// with its expensive glass/gradient chrome) to re-evaluate several times per
/// second during streaming. Only the message-thread subtree observes this
/// store, so streaming re-renders stay localized to the table.
@MainActor
final class VisibleBlocksStore: ObservableObject {
    @Published var blocks: [ContentBlock] = []
    @Published var groupHeaderMap: [UUID: UUID] = [:]
}

/// Snapshot of a pending user message that was authored while the agent
/// was still streaming. Captured at enqueue time so attachments and the
/// active one-off skill travel with the right turn. The view shows a chip
/// for this; `ChatSession` consumes it either via auto-flush on natural
/// completion or via `sendNowInterrupting()` when the user explicitly
/// interrupts.
struct QueuedSend: Equatable {
    var text: String
    var attachments: [Attachment]
    var oneOffSkillId: UUID?
}

/// A manual model change made after a conversation already has content.
/// Prefix/KV caches are model-scoped, so the new model must rebuild context;
/// it may also interpret the existing transcript differently. Kept as IDs so
/// the composer resolves the freshest user-facing display names.
struct ModelSwitchContinuityWarning: Equatable, Sendable {
    let previousModelId: String
    let newModelId: String
}

/// Equatable wrapper around `ChatEmptyState` so it only re-renders when one of
/// its actual inputs changes. `ChatView` observes the whole `ChatSession`
/// object, so its body re-evaluates on any `@Published` mutation — including
/// ones the empty state doesn't care about (a thinking-chip toggle republishes
/// `activeModelOptions`). Applying `.equatable()` to this view lets SwiftUI
/// compare the value inputs and skip the subtree when they're unchanged.
///
/// The closures are intentionally excluded from `==`: they're recreated on
/// every parent body pass but capture stable references (`ChatSession`,
/// `ChatWindowState`, `AppDelegate.shared`), so an older instance behaves
/// identically to a freshly built one. Comparing them would defeat the
/// isolation, since two structurally identical closures are never `==`.
private struct EmptyStateContent: View, Equatable {
    let selectedModel: String?
    let agents: [Agent]
    let activeAgentId: UUID
    let quickActions: [AgentQuickAction]
    let pendingLocalModelId: String?
    let temporaryCloudModelName: String?
    let activeDiscoveredAgent: DiscoveredAgent?
    let activeRelayAgent: PairedRelayAgent?
    let remoteAgentAvatar: String?
    let remoteAgentDescription: String?
    let remoteAgentQuickActions: [AgentQuickAction]?
    let isConnecting: Bool

    let onOpenModelManager: () -> Void
    let onUseFoundation: (() -> Void)?
    let onQuickAction: (String) -> Void
    let onUseHostedWhilePending: (() async -> Bool)?

    // `nonisolated` because Equatable's `==` is a non-isolated requirement but
    // this view type is main-actor-isolated. Every compared field is a Sendable
    // value type, so reading them off the main actor is race-free.
    nonisolated static func == (lhs: EmptyStateContent, rhs: EmptyStateContent) -> Bool {
        lhs.selectedModel == rhs.selectedModel
            && lhs.agents == rhs.agents
            && lhs.activeAgentId == rhs.activeAgentId
            && lhs.quickActions == rhs.quickActions
            && lhs.pendingLocalModelId == rhs.pendingLocalModelId
            && lhs.temporaryCloudModelName == rhs.temporaryCloudModelName
            && lhs.activeDiscoveredAgent == rhs.activeDiscoveredAgent
            && lhs.activeRelayAgent == rhs.activeRelayAgent
            && lhs.remoteAgentAvatar == rhs.remoteAgentAvatar
            && lhs.remoteAgentDescription == rhs.remoteAgentDescription
            && lhs.remoteAgentQuickActions == rhs.remoteAgentQuickActions
            && lhs.isConnecting == rhs.isConnecting
    }

    var body: some View {
        ChatEmptyState(
            hasModels: true,
            selectedModel: selectedModel,
            agents: agents,
            activeAgentId: activeAgentId,
            quickActions: quickActions,
            onOpenModelManager: onOpenModelManager,
            onUseFoundation: onUseFoundation,
            onQuickAction: onQuickAction,
            onOpenOnboarding: nil,
            pendingLocalModelId: pendingLocalModelId,
            temporaryCloudModelName: temporaryCloudModelName,
            onUseHostedWhilePending: onUseHostedWhilePending,
            activeDiscoveredAgent: activeDiscoveredAgent,
            activeRelayAgent: activeRelayAgent,
            remoteAgentAvatar: remoteAgentAvatar,
            remoteAgentDescription: remoteAgentDescription,
            remoteAgentQuickActions: remoteAgentQuickActions,
            isConnecting: isConnecting
        )
    }
}

#if DEBUG
    /// Debug-only switch for the canned tool-call timeline used to test the
    /// tool-call rail animation. With `forceEnabled = true`, every send streams
    /// the mock instead of calling the model — flip it back to `false` (or set
    /// env `OSAURUS_MOCK_STREAM=1` to enable without editing code) when done.
    enum MockToolStream {
        static let forceEnabled = false
        static var enabled: Bool {
            forceEnabled || ProcessInfo.processInfo.environment["OSAURUS_MOCK_STREAM"] == "1"
        }
    }
#endif

@MainActor
final class ChatSession: ObservableObject {
    /// Notifications whose source data can rewrite the composed system/tool
    /// prompt. Kept as one testable inventory so a new settings surface
    /// cannot refresh only its display cache while leaving warm-up state on
    /// the previous rendered bytes.
    ///
    /// The model-availability signals are here because spawn-target
    /// runnability is live execution truth (`SpawnDescriptors`): a remote
    /// provider connecting/disconnecting or a local model install/delete can
    /// rewrite the spawn tool enums without any settings edit. The pipeline is
    /// equality-guarded (`recomputePreviewContext` compares composed bytes),
    /// so these fire a required rewarm only when the rendered prompt or tool
    /// schema actually changed.
    static let promptShapeNotificationNames: [Notification.Name] = [
        .agentUpdated,
        .activeAgentChanged,
        .toolsListChanged,
        .appConfigurationChanged,
        .agentChannelConfigurationChanged,
        .remoteProviderModelsChanged,
        .localModelsChanged,
    ]

    @Published var turns: [ChatTurn] = []

    /// The model's OUTPUT for the in-flight run is complete (vmlx emitted its
    /// terminal info) even though the RUN has not ended: the adapter keeps the
    /// stream open through vmlx's post-generation cache store (9.5–15 s on a
    /// 96 GB bundle, measured 2026-09-04) to preserve allocator ordering. The
    /// streaming cursor keys on this so it stops at the last letter; the send
    /// gate keys on `isStreaming`, which still waits for the real end.
    @Published var outputComplete: Bool = false

    @Published var isStreaming: Bool = false {
        didSet {
            guard isStreaming != oldValue else { return }
            if isStreaming {
                outputComplete = false
                ChatPerfTrace.shared.begin("stream-\(Int(Date().timeIntervalSince1970))")
                beginRunProgressMonitor()
            } else {
                ChatPerfTrace.shared.end()
                endRunProgressMonitor()
            }
        }
    }

    // MARK: - Run progress (slow / stalled surfacing)

    /// Coarse liveness of the in-flight run, derived from time since the last
    /// observed progress event (stream delta, tool event, image-generation
    /// event). Drives a visible notice above the composer so a wedged
    /// provider/model/tool reads as "stalled — Stop is right there" instead of
    /// an indefinite shimmer the user can only interpret as a hang.
    enum RunProgressState {
        case active
        /// No progress for `runSlowThreshold` — worth telling the user we're
        /// still alive but waiting (long prefill, slow provider, big tool).
        case slow
        /// No progress for `runStalledThreshold` — likely wedged; surface
        /// Stop as the recovery action. The run is NOT auto-killed: a huge
        /// model load can legitimately take minutes, so the user decides.
        case stalled
    }

    @Published private(set) var runProgressState: RunProgressState = .active

    private var lastRunProgressAt = Date()
    private var runProgressMonitorTask: Task<Void, Never>?
    private static let runSlowThreshold: TimeInterval = 30
    private static let runStalledThreshold: TimeInterval = 120

    /// Record run liveness. Called from every streaming/tool/image event
    /// loop; must stay cheap (a Date store; the published state only changes
    /// on an actual transition).
    func noteRunProgress() {
        lastRunProgressAt = Date()
        if runProgressState != .active {
            runProgressState = .active
        }
    }

    private func beginRunProgressMonitor() {
        lastRunProgressAt = Date()
        runProgressState = .active
        runProgressMonitorTask?.cancel()
        runProgressMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled else { return }
                let idle = Date().timeIntervalSince(self.lastRunProgressAt)
                let newState: RunProgressState =
                    idle >= Self.runStalledThreshold
                    ? .stalled
                    : idle >= Self.runSlowThreshold ? .slow : .active
                if newState != self.runProgressState {
                    self.runProgressState = newState
                    if newState == .stalled {
                        CrashReportingService.recordBreadcrumb(
                            category: "chat.run",
                            message: "run stalled: no progress for \(Int(idle))s"
                        )
                    }
                }
            }
        }
    }

    private func endRunProgressMonitor() {
        runProgressMonitorTask?.cancel()
        runProgressMonitorTask = nil
        runProgressState = .active
    }

    @Published var lastStreamError: String?

    /// Set when an Osaurus Router send fails because the account is out of
    /// credits (HTTP 402 INSUFFICIENT_FUNDS). Drives the "out of credits"
    /// themed modal in ChatView. Cleared when the user dismisses it or tops up.
    @Published var insufficientFundsAlert = false

    /// The assistant turn that was blocked by an insufficient-funds failure,
    /// remembered so a post-top-up retry can regenerate exactly that turn.
    /// Nil when there's nothing to retry.
    var insufficientFundsTurnId: UUID?

    /// Balance (micro-USD) captured at the moment of an insufficient-funds
    /// failure. The post-top-up watcher offers a retry only once the balance
    /// rises above this baseline, so a stale/no-op refresh doesn't prompt.
    var balanceMicroAtInsufficientFunds: Int64?

    /// Set when the balance is restored after an insufficient-funds failure
    /// while the blocked turn is still last. Drives the "Credits added" retry
    /// modal in ChatView.
    @Published var topUpRetryAlert = false

    /// Last typed draft preserved when a send is cancelled
    /// (Cancel-send button in review sheet, or Task cancel during
    /// review). The chat view re-reads this in the cancel branch and
    /// puts the text back in the input field so the user can edit and
    /// resend without retyping. Cleared on the next successful send.
    var savedDraftOnCancel: (text: String, attachments: [Attachment])? = nil

    /// Single-slot FIFO queue for in-chat prompt overlays (secrets,
    /// clarify, …). Both prompt types share the same on-screen real
    /// estate (bottom-pinned card above the input bar), so they MUST be
    /// mutually exclusive — the queue ensures arrival order is honored
    /// without two cards stacking. See `PromptQueue.swift`.
    @Published var promptQueue: PromptQueue = PromptQueue()

    /// Set by the agent-loop `clarify` intercept when the chat is paused
    /// for a clarify question. Cleared by `send(...)` before the next
    /// user turn so the loop can resume cleanly. Observed by
    /// `BackgroundTaskManager.observeChatTask` to flip the task status to
    /// `.waitingForInput`, emit the type-3 CLARIFICATION event with
    /// the parsed payload to the source plugin, and suppress the spurious
    /// COMPLETED that would otherwise fire when `isStreaming` goes false
    /// on the intercept.
    @Published var awaitingClarify: ClarifyPayload?

    /// This chat's working-folder state (context, security-scoped access,
    /// persistable bookmark). Owned per session so picking/refreshing/
    /// clearing a folder affects ONLY this chat — never other windows or
    /// concurrent headless runs. Persisted through `ChatSessionData`.
    let folderState = ChatFolderState()

    /// Bridges `ChatFolderState.objectWillChange` up to the session so the
    /// folder chip / previews re-render when this chat's folder changes.
    nonisolated(unsafe) private var folderStateCancellable: AnyCancellable?

    /// Tracks expand/collapse state for tool calls, thinking blocks, etc.
    /// Lives on the session so state survives NSTableView cell reuse.
    let expandedBlocksStore = ExpandedBlocksStore()

    /// Thinking-block ids already auto-expanded once for a completed
    /// reasoning-only turn. Seeding the shared `expandedBlocksStore` (rather
    /// than force-expanding in the cell) lets the user collapse the block
    /// afterward; this set stops us re-expanding it on the next rebuild.
    private var autoExpandedReasoningBlockIds: Set<String> = []

    /// Thinking-block ids auto-expanded while their turn was actively
    /// streaming reasoning (opt-in "Expand Thinking While Streaming"
    /// setting). Each id is expanded at most once so a manual collapse
    /// mid-stream sticks, and collapsed exactly once when the thinking
    /// phase ends.
    private var streamingAutoExpandedThinkingBlockIds: Set<String> = []
    @Published var input: String = ""
    @Published var pendingAttachments: [Attachment] = []
    @Published var selectedModel: String? = nil
    @Published var modelSwitchContinuityWarning: ModelSwitchContinuityWarning?
    /// Proactive model + KV-cache warm-up for faster first-token latency.
    let warmupController = ChatWarmupController()
    @Published var pickerItems: [ModelPickerItem] = []
    @Published var activeModelOptions: [String: ModelOptionValue] = [:]
    @Published var imageComposerSettings = ImageComposerSettings()
    @Published var hasAnyModel: Bool = false
    @Published var isDiscoveringModels: Bool = true
    /// When true, voice input auto-restarts after AI responds (continuous conversation mode)
    @Published var isContinuousVoiceMode: Bool = false
    /// Active state of the voice input overlay
    @Published var voiceInputState: VoiceInputState = .idle
    /// Whether the voice input overlay is currently visible
    @Published var showVoiceOverlay: Bool = false
    /// The agent this session belongs to
    @Published var agentId: UUID?

    /// Skill ID to inject as one-off context for the next outgoing message.
    /// Set when the user selects a skill from the slash command popup; cleared after send.
    @Published var pendingOneOffSkillId: UUID?

    /// Single-slot queued send. Non-nil when the user has pressed Send while
    /// `isStreaming` is true. The chip in `FloatingInputCard` shows a preview
    /// and a × to cancel. Auto-flushed by `completeRunCleanup` when the run
    /// ends naturally; explicitly flushed by `sendNowInterrupting()` which
    /// stops the current run and dispatches the queued payload as a new
    /// user turn.
    @Published var queuedSend: QueuedSend?

    // MARK: - Persistence Properties
    @Published var sessionId: UUID?
    @Published var title: String = "New Chat"
    /// One-shot latch for the AI-generated title. Set when a generation is
    /// kicked off for the current session so later runs in the same chat
    /// never re-title it; reset whenever the session identity changes
    /// (`startNewChat`, `load(from:)`, transient-session rollback).
    private var autoTitleGenerationStarted = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// Origin of this session — populated by `ExecutionContext` for headless
    /// (plugin / HTTP / scheduler / watcher) runs, defaults to `.chat` for
    /// user-driven UI sessions.
    var source: SessionSource = .chat
    /// True when this session's folder was restored from a bookmark that a
    /// background DISPATCH supplied (a Watcher's watched folder, a scheduled
    /// task's folder, or a plugin's `folder_bookmark`), as opposed to a
    /// folder the user picked interactively in the chat UI. Set by
    /// `ExecutionContext.activateFolderContextIfNeeded`. A dispatched folder
    /// is an explicit target with no interactive sandbox toggle, so it wins
    /// over the agent's default sandbox in `prepareChatExecutionMode`
    /// (`preferHostFolder`); an interactive folder keeps the historical
    /// sandbox-priority contract, where the user toggles sandbox off instead.
    var folderContextFromDispatchBookmark: Bool = false
    /// Whether this session's model loads may evict a model someone else is using.
    ///
    /// Set from `DispatchRequest.loadIntent` at the trigger boundary. Headless
    /// autonomous runs (cron fire, watcher, agent self-wake) arrive `.background`
    /// and will decline rather than take the GPU from an active chat; everything
    /// a human is waiting on -- including the "Run Now" buttons that share those
    /// same code paths -- stays `.interactive`.
    ///
    /// This exists because the engine's own `RequestSource` has only four cases
    /// (chatUI / httpAPI / plugin / p2p) and every headless session was being
    /// flattened into `.chatUI` on its way to the model, losing the distinction
    /// entirely.
    var loadIntent: ModelLoadIntent = .interactive
    /// Enforced delegation budget for `.delegation`-dispatched sessions:
    /// (per-generation response-token cap, assistant tool-loop turn cap).
    /// Set once by `ExecutionContext` from the `DispatchRequest`; nil for
    /// every ordinary chat. Consumed at the two loop-limit sites below —
    /// RAM admission prices delegated children from exactly these values.
    var delegationBudget: DelegatedRunContract?
    var sourcePluginId: String?
    var externalSessionKey: String?
    var dispatchTaskId: UUID?
    /// Mirrors `ChatSessionData.archived`. Required here so `toSessionData()`
    /// round-trips the flag instead of stamping `false` on every save.
    var archived: Bool = false
    /// Mirrors `ChatSessionData.pinned`, for the same round-trip reason as
    /// `archived`.
    var pinned: Bool = false
    /// Mirrors `ChatSessionData.projectId`, for the same round-trip reason
    /// as `archived`. Published because the toolbar's back-to-project
    /// button shows/hides with it across chat switches.
    @Published var projectId: UUID?

    /// Tracks if session has unsaved content changes
    private var isDirty: Bool = false
    /// Session id whose first persisted turn belongs to the active send.
    /// Used to undo transient rows on privacy-review cancels, including
    /// pre-minted empty session ids.
    private var transientSessionIdForCurrentRun: UUID?
    /// Whether this run appended a new user turn. Regeneration sends reuse
    /// historical user turns and must not pop one during privacy-cancel rollback.
    private var appendedUserTurnForCurrentRun = false
    /// True while a send is parked on the pre-send warm-up handshake (the
    /// in-flight warm-up generation may still be loading the model). Drives a
    /// placeholder typing-indicator row so the wait shows "Loading Model..."
    /// instead of a silent gap under the user's message. Not `@Published`
    /// (composer reads it through `isSendActiveForComposer`), so the sidebar
    /// activity bridge hooks its transitions here.
    private var awaitingPreSendHandshake = false {
        didSet {
            guard awaitingPreSendHandshake != oldValue else { return }
            publishActivityState(
                sessionId: sessionId,
                working: isStreaming || awaitingPreSendHandshake,
                waiting: promptQueue.current != nil || awaitingClarify != nil
            )
        }
    }
    /// Composer-facing activity includes the outer warm-up handshake, before
    /// `isStreaming` flips. This keeps Stop/queue behavior available during a
    /// long model switch instead of presenting a second ordinary Send button.
    var isSendActiveForComposer: Bool {
        isStreaming || awaitingPreSendHandshake
    }

    /// Session id whose activity was last pushed to `SessionActivityMonitor`,
    /// so a session switch/reset clears the stale entry. `nonisolated(unsafe)`
    /// so `deinit` can read it for the final cleanup hop.
    nonisolated(unsafe) private var lastReportedActivitySessionId: UUID?

    /// Push this session's live activity into the shared monitor keyed by
    /// persisted session id. Waiting (a mounted clarify/secret card or a
    /// pending clarify answer) outranks working; neither means the entry is
    /// removed. Called with the NEW values from the Combine bridge in `init`
    /// (publishers emit on willSet) and from `awaitingPreSendHandshake.didSet`.
    private func publishActivityState(sessionId: UUID?, working: Bool, waiting: Bool) {
        let status: SessionActivityMonitor.Status? =
            waiting ? .waitingForInput : (working ? .working : nil)
        if let previous = lastReportedActivitySessionId, previous != sessionId {
            SessionActivityMonitor.shared.reportSession(previous, status: nil)
        }
        if let sessionId {
            SessionActivityMonitor.shared.reportSession(sessionId, status: status)
        }
        lastReportedActivitySessionId = sessionId
    }
    /// Stable placeholder assistant turn rendered (never persisted, never in
    /// `turns`) while `awaitingPreSendHandshake` is true. Stable identity so
    /// the typing-indicator block id doesn't churn across rebuilds.
    private let preSendHandshakePlaceholderTurn = ChatTurn(role: .assistant, content: "")
    /// Full transcript snapshot to restore when privacy review cancels a
    /// regeneration/edit-regeneration before the request leaves the device.
    private var turnsRollbackOnCancel: [ChatTurn]?
    /// Privacy review cancel restores the draft instead of committing the run;
    /// it must not auto-dispatch a queued follow-up during cleanup.
    private var suppressQueuedSendFlushForCurrentRun = false

    // MARK: - Memoization Cache
    private let blockMemoizer = BlockMemoizer()
    private var cachedContext: ComposedContext?

    /// Frozen screen-context snapshot for this session (opt-in Computer Use
    /// feature). Captured once on the first send and reused unchanged for the
    /// rest of the session, so it reflects what the user was doing when the
    /// conversation started. Holds the rendered `[Screen Context]` block (or
    /// nil when the feature is off or nothing was captured). Cleared on
    /// `reset()` / `load(from:)`. Not persisted.
    private var frozenScreenContext: String?

    /// Estimated token cost of `frozenScreenContext`, surfaced as a dedicated
    /// "Screen Context" line in the Context Budget popover (mirrors
    /// `cachedMemoryTokens`). Kept in sync by `refreshScreenContextPreview`
    /// pre-send and locked alongside the snapshot on the first send so the
    /// line persists for the rest of the session instead of being dropped.
    private var cachedScreenContextTokens: Int = 0

    /// True once the first send has locked `frozenScreenContext` for this
    /// session. Until then the welcome-screen preview may re-capture as the
    /// user switches foreground apps; afterwards the snapshot is fixed.
    private var isScreenContextFrozen: Bool = false

    /// Cached welcome/pre-send preview `ComposedContext`, used by
    /// `estimatedContextBreakdown` when no real send context exists yet.
    /// Recomputed by `refreshContextEstimates()` whenever a budget-relevant
    /// input changes (agent config / feature toggle, sandbox state, tool
    /// registration, folder, model). Kept separate from `cachedContext`
    /// (the authoritative send-time context) so typing only re-derives the
    /// cheap conversation/input/output overlay instead of recomposing the
    /// whole system prompt on every keystroke. Cleared wherever
    /// `cachedContext` is reset so a new agent/session recomposes fresh.
    private var cachedPreviewContext: ComposedContext?

    /// Estimated memory-section token cost for the next send. Populated by
    /// `refreshMemoryTokens` and surfaced through `estimatedContextBreakdown`
    /// so the Context Budget popover shows a "Memory" line even before the
    /// first send (when `cachedContext` is still nil).
    private var cachedMemoryTokens: Int = 0
    private let budgetTracker = ContextBudgetTracker()

    /// Session-scoped sticky compaction state: once history trimming
    /// summarizes or drops a message, that decision persists so the trimmed
    /// transcript (and the paged-KV token prefix) stays byte-stable across
    /// loop iterations and turns. Resets itself if history is rewritten
    /// (regeneration/edit) via identity validation.
    private let compactionWatermark = CompactionWatermark()

    // MARK: - LLM Context Compaction State

    /// Non-destructive LLM compaction result: the covered oldest turns are
    /// replaced by this summary in the OUTBOUND message array only (the
    /// visible transcript is untouched). Persisted with the session;
    /// invalidated when covered turns are edited/regenerated away (see
    /// `validateConversationSummary`).
    @Published var conversationSummary: ConversationSummary?

    /// Live compaction progress, rendered by the Context Budget popover
    /// (inline) and the compaction dialog.
    @Published var compactionState: ContextCompactionUIState = .idle

    /// Presents `CompactionDialogView`: the first-run model picker, or the
    /// live-progress sheet for auto-triggered runs.
    @Published var showCompactionDialog = false

    /// True when the in-flight/pending compaction was auto-triggered by a
    /// send; the stashed send resumes once compaction settles (success,
    /// failure, or the user dismissing the first-run dialog).
    private var resumeSendAfterCompaction = false

    /// One-shot latch so the resumed send doesn't immediately re-enter the
    /// auto-compaction gate.
    private var skipAutoCompactionForNextSend = false

    /// In-flight compaction run, if any. Kept so `reset()` can cancel it
    /// (compaction never overlaps a streaming run — manual is gated on
    /// `!isStreaming` and the auto-trigger fires pre-send — so `stop()`
    /// has nothing to cancel; a run that outlives its transcript is
    /// dropped by the `summaryIsValid` check before it can apply).
    private var compactionTask: Task<Void, Never>?

    /// Per-session always-loaded + capabilities_load tool kit lives in the
    /// process-wide `SessionToolStateStore` so chat sessions and the
    /// HTTP/plugin path share one cache. Keyed by `sessionId.uuidString`.
    private var sessionStateKey: (UUID) -> String { { $0.uuidString } }

    /// Prompt/scope agreement tripwire (advisory, never a block): the
    /// Orchestrator addendum tells the model to ALWAYS call `osaurus_help` /
    /// `osaurus_inspect` / `osaurus_config`; if this turn's schema does not
    /// expose one of them the scope refuses it with `tool_not_found` and the
    /// model has been set up to loop (seen live after an agent-chip switch
    /// before the agent joined the session fingerprint). Logged so a live
    /// proof can see the disagreement. Only the Default agent carries the
    /// addendum, so other agents are skipped.
    static func logOrchestratorScopeDisagreement(agentId: UUID, scope: ToolExecutionScope) {
        guard agentId == Agent.defaultId else { return }
        let missing = DefaultAgentSystemPromptBuilder.missingRequiredToolNames(
            exposed: scope.authorizedNames
        )
        guard !missing.isEmpty else { return }
        let names = missing.sorted().joined(separator: ", ")
        debugLog("[Tools] orchestrator addendum requires tools the scope refuses: \(names)")
    }

    // MARK: - Agent Loop State (Chat-as-Agent)

    /// The agent's current todo for this chat, mirrored from
    /// `AgentTodoStore` via `.agentTodoChanged`. Read-only from the UI's
    /// perspective — only the `todo` tool writes to it.
    @Published var currentTodo: AgentTodo?

    /// Last `complete(summary)` payload from the agent. Populated when
    /// the engine intercepts `complete` and breaks the loop. The chat
    /// view renders it as a "Completed" banner inline.
    @Published var lastCompletionSummary: String?
    /// True when the completion tool closed an honestly blocked tracked task
    /// with unchecked Todo items. Kept separate from the summary so legacy
    /// session persistence remains unchanged while the live banner is honest.
    @Published var lastCompletionWasBlocked = false

    /// Per-task state machine the harness holds so the (small) model doesn't
    /// have to. Session-scoped here so a listing produced by one user message
    /// ("what's on my desktop") survives into the next ("read the file");
    /// `beginMessage()` resets only the within-message dedupe/bias tracking.
    let taskState = AgentTaskState()

    /// Notification observer for AgentTodoStore updates. Removed in deinit.
    nonisolated(unsafe) private var agentTodoObserver: NSObjectProtocol?

    /// Bridges `PromptQueue.objectWillChange` (a nested `ObservableObject`)
    /// up to `ChatSession.objectWillChange`. SwiftUI's `@ObservedObject`
    /// only re-renders on the outer object's emissions, so without this
    /// forward the prompt overlay wouldn't appear/disappear when the
    /// inner queue mutates `current`.
    nonisolated(unsafe) private var promptQueueCancellable: AnyCancellable?

    /// Bridges this session's live activity (streaming / awaiting input) into
    /// `SessionActivityMonitor` keyed by session id, for the History sidebar.
    nonisolated(unsafe) private var activityMonitorCancellable: AnyCancellable?

    /// Callback when session needs to be saved (called after streaming completes)
    var onSessionChanged: (() -> Void)?

    /// When true, every assistant turn that finishes streaming in this session
    /// is auto-spoken via TTS. Per-session only — resets for new chats.
    @Published var autoSpeakAssistant: Bool = false
    /// Whether we've already shown the first-tap auto-speak prompt in this session.
    @Published var hasAskedAutoSpeak: Bool = false
    /// Set to the assistant turn id when a streaming run finalizes successfully.
    /// `ChatView` observes this to drive auto-speak. Not set on stop/error.
    @Published var lastCompletedAssistantTurnId: UUID?

    /// AI-suggested follow-up questions for the most recent completed turn,
    /// rendered as clickable rows beneath the assistant response when the
    /// `generateFollowUpSuggestions` setting is on. Transient (not persisted):
    /// they're a live nicety for the current turn, cleared as soon as the user
    /// sends again or the run is cancelled/errors. `followUpTurnId` pins them
    /// to the turn they belong to so a stale set never renders under a newer
    /// message.
    @Published var followUpSuggestions: [String] = []
    @Published var followUpTurnId: UUID?
    /// Latches per completed turn so a re-entrant cleanup can't fire a second
    /// generation for the same turn. A failed attempt clears it (see
    /// `maybeGenerateFollowUps`) so the next clean completion may retry.
    private var followUpGenerationStarted = false

    /// Weak back-reference to the owning window state (set by ChatWindowState).
    /// Single-slot by design, last-writer-wins: when two windows attach the
    /// same registry-shared session, the most recent attach owns
    /// busy-alert/sidebar routing; the earlier window still renders live via
    /// the published transcript. Known, accepted limitation.
    weak var windowState: ChatWindowState?

    /// True when this window is pointed at a paired/discovered remote Osaurus
    /// *agent* (Mode 2 — "talk to the agent"). The signal is the selected
    /// relay/discovered agent provider, which is set only by
    /// `connectToRelayAgent` / `connectToDiscoveredAgent` and cleared by
    /// `adoptAgent`. Plain model picks (Mode 1 — "use the device" for
    /// inference) never set it, so an `.osaurus` device model chosen on a local
    /// agent stays in Mode 1. Drives bare-request composition and `/run`
    /// routing in `send(...)`.
    var isRemoteAgentTarget: Bool {
        windowState?.selectedDiscoveredAgentProviderId != nil
    }

    private var currentTask: Task<Void, Never>?
    private var activeRunId: UUID?
    private var activeRunContext: RunContext?
    /// Outer task that parks a send behind an in-flight model-switch/warm-up
    /// handshake. Retaining it is required for lifecycle cancellation: a
    /// fire-and-forget task can otherwise resume after Stop, reset, or a
    /// session load and dispatch the user turn captured from the old chat.
    private var preSendHandshakeTask: Task<Void, Never>?
    /// Monotonic chat/session generation for pre-send handshakes. Every
    /// lifecycle invalidation bumps this value; the suspended task and
    /// `dispatchSend` both re-check their captured epoch before touching the
    /// transcript or starting inference.
    private var preSendHandshakeEpoch: UInt64 = 0
    /// Set to true at the start of `stop()` so `completeRunCleanup` knows the
    /// run was cancelled by the user (or by `sendNowInterrupting`) and must
    /// not auto-flush a queued send. Reset to false at the top of `send(...)`.
    private var stopRequested: Bool = false
    /// Takes the session's own inference provenance. It used to hardcode
    /// `.chatUI` and ignore `source` entirely, so every headless run -- cron
    /// schedule, file watcher, agent self-wake -- reached the model claiming to
    /// be the user typing in the chat window.
    var chatEngineFactory: @MainActor (InferenceSource) -> ChatEngineProtocol = {
        ChatEngine(source: $0)
    }
    #if DEBUG
        /// Keeps ChatSession lifecycle tests independent of whichever local
        /// image bundle the developer machine happens to expose through the
        /// shared picker cache. Those tests inject a chat engine and must not
        /// be silently diverted into a machine-local image generation path.
        var forceChatEngineRouteForTests = false
    #endif
    // nonisolated(unsafe) allows deinit to access these for cleanup
    nonisolated(unsafe) private var remoteModelsObserver: NSObjectProtocol?
    nonisolated(unsafe) private var modelSelectionCancellable: AnyCancellable?
    nonisolated(unsafe) private var modelOptionsCancellable: AnyCancellable?
    nonisolated(unsafe) private var agentAutoSpeakCancellable: AnyCancellable?
    /// Direct subscription to the shared model-picker cache. The
    /// `.remoteProviderModelsChanged` notification bridge above only
    /// *triggers* a rebuild; this makes the session's `pickerItems`
    /// follow the cache's atomic `items` assignment so a newly connected
    /// remote provider shows up in the picker live, without reopening the
    /// window (mirrors `AgentsView`'s `$items` subscription).
    nonisolated(unsafe) private var modelCacheCancellable: AnyCancellable?
    /// Runtime residency changes can originate outside this window (HTTP,
    /// plugins, subagents, other chats). Observe them so a model evicted behind
    /// the window's back cannot keep a stale green warm indicator.
    nonisolated(unsafe) private var runtimeResidencyObserver: NSObjectProtocol?
    /// Flag to prevent auto-persist during initial load or programmatic resets
    private var isLoadingModel: Bool = false
    /// The model the user last picked by hand this session. Picker-list
    /// rebuilds (`applyPickerItems`) fire whenever runtime state changes —
    /// including the load the pick itself triggered — and previously let the
    /// agent's saved default snap the selection back (stale chip: pick HY3,
    /// chip reverts to Qwen, and the follow-up warm-up loads the WRONG model
    /// over the user's in-flight load). A manual pick outranks the agent
    /// default for as long as it remains a valid option.
    private var lastManualModelSelection: String?

    nonisolated(unsafe) private var localModelsObserver: NSObjectProtocol?
    /// Observer for `.privacyFilterRedactionsApproved`. Folds every
    /// approved (original, placeholder) pair into this window's
    /// `sessionRedactions` dict so user + assistant bubbles can
    /// inline-highlight the matching spans on rebuild. Filtered by
    /// this session's `sessionId.uuidString` to avoid cross-window
    /// leakage when multiple chats are open.
    nonisolated(unsafe) private var privacyRedactionsObserver: NSObjectProtocol?
    nonisolated(unsafe) private var activityRollupObserver: NSObjectProtocol?
    /// Observer for `StorageMutationGate.didFinishMutating`. The preview
    /// composition reads the agent DB, which is deferred while a storage-key
    /// rotation is in flight (so the main thread never parks on the gate's
    /// run-loop spin). This retries the estimate once storage settles.
    nonisolated(unsafe) private var storageMutationObserver: NSObjectProtocol?

    /// Accumulated original -> placeholder map for THIS window's
    /// session, populated by the privacy filter notification. Drives
    /// inline highlighting in the chat bubbles via
    /// `CellRenderingContext.sessionRedactions`. FIFO-capped (see
    /// `Self.maxSessionRedactions`) so a long-running window doesn't
    /// grow this dict unbounded; oldest entries evict first because
    /// the most recently-redacted spans are the ones the user is
    /// looking at right now in the transcript.
    @Published private(set) var sessionRedactions: [String: String] = [:]
    /// Insertion-order log for `sessionRedactions`. Append-only;
    /// eviction is by `removeFirst` when the count exceeds the cap.
    private var sessionRedactionOrder: [String] = []
    static let maxSessionRedactions: Int = 256

    /// Single debounced pipeline that recomputes the context-budget preview
    /// whenever any budget-relevant input changes: agent config / feature
    /// toggles (`.agentUpdated`), active-agent switches
    /// (`.activeAgentChanged`), plugin/MCP/sandbox tool registration
    /// (`.toolsListChanged`), folder mount/unmount (`FolderContextService`),
    /// and the selected model (`$selectedModel`). These are global singletons
    /// the session does not otherwise observe, so without this the
    /// welcome-screen estimate would only refresh on incidental re-renders
    /// and go stale after a toggle. Debounced to coalesce the burst of
    /// signals a single sandbox toggle emits. See the pipeline in `init()`
    /// for why memory and `SandboxManager.State` are deliberately excluded.
    nonisolated(unsafe) private var contextEstimateCancellable: AnyCancellable?

    /// Separate from `contextEstimateCancellable` because a screen-context
    /// refresh runs an Accessibility walk — too heavy for the cheap per-signal
    /// budget pipeline. Re-captures the pre-send preview when the feature is
    /// toggled or the foreground app changes, until the first send locks it.
    nonisolated(unsafe) private var screenContextCancellable: AnyCancellable?

    #if DEBUG
        /// Task-scoped test seam for chat lifecycle suites whose mock engines
        /// intentionally exercise plain generation without the built-in tool
        /// loop. This is not persisted, user-configurable, or process-global;
        /// child Tasks created by `send()` inherit the enclosing test value.
        @TaskLocal static var toolsDisabledForTesting = false

        /// Lets the few lifecycle tests that intentionally exercise AgentLoop
        /// opt back in while their enclosing storage fixture stays plain-chat.
        var toolsDisabledForTestingOverride: Bool?

        /// Set only by `isolatePromptShapeReconcilerForTests()`: silences the
        /// lifecycle `refreshContextEstimates()` tasks so a test can pin the
        /// pre-send reconcile as the sole prompt-shape change consumer.
        private var suppressLifecycleContextRefreshForTests = false

        /// Detach this session from the SHARED `ModelPickerItemCache.$items`
        /// subscription so a test can install its own picker items without
        /// the process-global cache snapshot clobbering them. Isolation
        /// seam only — production sessions must keep tracking the cache.
        func detachPickerCacheForTesting() {
            modelCacheCancellable = nil
        }
    #endif

    init() {
        // Warm the agent-secret account memo off the main thread before the
        // first preview compose reads it synchronously — the Keychain
        // enumeration it performs has otherwise hung the UI on chat open.
        AgentSecretsKeychain.prewarmAccounts()

        let cache = ModelPickerItemCache.shared
        if cache.isLoaded {
            pickerItems = cache.items
            hasAnyModel = !cache.items.isEmpty
            isDiscoveringModels = false
        } else {
            pickerItems = []
            hasAnyModel = false
        }

        // Forward nested PromptQueue changes up so SwiftUI re-renders
        // when the queue mounts or advances. See the property comment
        // for why the explicit bridge is needed.
        promptQueueCancellable = promptQueue.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }

        // Mirror live activity into the shared sidebar monitor. `@Published`
        // publishers emit the NEW value on willSet, so the closure computes
        // from the emitted values (the properties themselves are still stale
        // at this point); `awaitingPreSendHandshake` isn't published and
        // reports through its own `didSet` instead.
        activityMonitorCancellable = Publishers.CombineLatest4(
            $isStreaming,
            $sessionId,
            $awaitingClarify,
            promptQueue.$current
        )
        .sink { [weak self] isStreaming, sessionId, clarify, promptItem in
            guard let self else { return }
            self.publishActivityState(
                sessionId: sessionId,
                working: isStreaming || self.awaitingPreSendHandshake,
                waiting: promptItem != nil || clarify != nil
            )
        }

        // Same bridge for the per-session folder state: the folder chip and
        // context previews render from `folderState`, whose mutations must
        // surface through the session object SwiftUI actually observes.
        folderStateCancellable = folderState.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }

        // Persist user folder mutations promptly: without this, a folder
        // picked (or cleared) mid-conversation only reaches disk on the next
        // turn/teardown save and is lost on a crash or force-quit. Fires only
        // for user-initiated select/change/clear — never persistence restores
        // — and only once the session has content to persist (`save()` skips
        // empty sessions; a brand-new chat's folder is saved with its first
        // turn). Folder mutations are rare click-driven events, so a direct
        // save (already async via `saveAsync`) needs no debounce.
        folderState.onFolderMutated = { [weak self] in
            guard let self, !self.turns.isEmpty else { return }
            self.isDirty = true
            self.save()
        }

        remoteModelsObserver = NotificationCenter.default.addObserver(
            forName: .remoteProviderModelsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshPickerItems() }
        }

        localModelsObserver = NotificationCenter.default.addObserver(
            forName: .localModelsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshPickerItems() }
        }

        storageMutationObserver = NotificationCenter.default.addObserver(
            forName: StorageMutationGate.didFinishMutatingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshContextEstimates() }
        }

        // Follow the shared cache reactively. `ModelPickerItemCache`
        // already observes the same notifications and rebuilds `items`
        // atomically; subscribing here guarantees the session's picker
        // tracks that rebuild even when the notification-driven refresh
        // above races the connect that produced it. Fires immediately
        // with the current snapshot, which `applyPickerItems` no-ops when
        // unchanged.
        modelCacheCancellable = ModelPickerItemCache.shared.$items
            .sink { [weak self] items in
                Task { @MainActor in self?.applyPickerItems(items) }
            }

        runtimeResidencyObserver = NotificationCenter.default.addObserver(
            forName: .modelRuntimeResidencyChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let snapshot = note.object as? ModelRuntimeResidencySnapshot else { return }
            Task { @MainActor in
                guard let self else { return }
                let isSessionActive =
                    self.windowState.map {
                    ChatWindowManager.shared.isChatWindowActive(id: $0.windowId)
                } ?? false
                self.warmupController.handleRuntimeResidencyChanged(
                    session: self,
                    snapshot: snapshot,
                    isSessionActive: isSessionActive
                )
            }
        }
        // Seed the residency-backed model dot before any runtime change
        // fires — a freshly opened chat must show whether the selected
        // model is already loaded, not a hardcoded default.
        warmupController.seedRuntimeResidency(session: self)

        // Re-derive visible blocks when the activity-rollup toggle flips in
        // Chat settings; the memoizer's display pass re-reads the flag, so a
        // plain rebuild is enough to group / ungroup open transcripts live.
        activityRollupObserver = NotificationCenter.default.addObserver(
            forName: ContentBlock.activityRollupSettingChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildVisibleBlocks() }
        }

        // Mirror AgentTodoStore -> currentTodo so the inline UI block
        // updates whenever the agent calls `todo`. Filter by this window's
        // current sessionId so cross-window writes don't leak across.
        agentTodoObserver = NotificationCenter.default.addObserver(
            forName: .agentTodoChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let sid = note.userInfo?["sessionId"] as? String else { return }
            Task { @MainActor in
                guard let self, sid == self.expectedTodoSessionId else { return }
                self.currentTodo = await AgentTodoStore.shared.todo(for: sid)
            }
        }

        // Fold the (original, placeholder) pairs from this approved
        // send into `sessionRedactions` so subsequent chat-block
        // rebuilds can inline-highlight any matching spans in user
        // and assistant bubbles. We match by sessionId so opening
        // two chat windows and sending from one doesn't leak
        // placeholder metadata into the other window's transcript.
        privacyRedactionsObserver = NotificationCenter.default.addObserver(
            forName: .privacyFilterRedactionsApproved,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let sid = note.userInfo?["sessionId"] as? String,
                let pairs = note.userInfo?["redactions"] as? [[String: String]],
                !pairs.isEmpty
            else { return }
            Task { @MainActor in
                guard let self else { return }
                guard self.sessionId?.uuidString == sid else { return }
                var didChange = false
                for pair in pairs {
                    guard
                        let original = pair["original"],
                        let placeholder = pair["placeholder"],
                        !original.isEmpty
                    else { continue }
                    if self.sessionRedactions[original] == placeholder { continue }
                    if self.sessionRedactions[original] == nil {
                        self.sessionRedactionOrder.append(original)
                    }
                    self.sessionRedactions[original] = placeholder
                    didChange = true
                }
                // FIFO cap: drop oldest originals so the dict can't
                // grow unbounded in a long-running window.
                while self.sessionRedactionOrder.count > Self.maxSessionRedactions {
                    let oldest = self.sessionRedactionOrder.removeFirst()
                    self.sessionRedactions.removeValue(forKey: oldest)
                    didChange = true
                }
                if didChange {
                    self.rebuildVisibleBlocks()
                }
            }
        }

        // when the active agent opts into auto-speak, force the per-session
        // toggle on and suppress the first-tap prompt. agents that haven't
        // opted in leave the per-chat toggle alone.
        agentAutoSpeakCancellable =
            $agentId
            .sink { [weak self] newAgentId in
                guard let self else { return }
                let id = newAgentId ?? Agent.defaultId
                let agent = AgentManager.shared.agent(for: id)
                if agent?.autoSpeak == true {
                    self.autoSpeakAssistant = true
                    self.hasAskedAutoSpeak = true
                }
            }

        // Auto-persist model selection and unload unused models on switch
        modelSelectionCancellable =
            $selectedModel
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newModel in
                guard let self = self, !self.isLoadingModel else { return }
                guard let model = newModel else { return }
                let previousModel = self.selectedModel
                if Self.shouldWarnAboutModelSwitch(
                    previousModel: previousModel,
                    newModel: model,
                    hasConversation: self.hasVisibleThreadMessages
                ), let previousModel
                {
                    self.modelSwitchContinuityWarning = ModelSwitchContinuityWarning(
                        previousModelId: previousModel,
                        newModelId: model
                    )
                } else if previousModel == nil || !self.hasVisibleThreadMessages {
                    self.modelSwitchContinuityWarning = nil
                }
                self.lastManualModelSelection = model
                let pid = self.agentId ?? Agent.defaultId
                // Mode 2 (remote agent run): the model is pinned to the remote
                // agent's own model. Don't write that pin into the LOCAL agent's
                // saved default — otherwise selecting a remote agent would
                // silently overwrite the local agent's preferred model. Mode 1
                // (plain model picks on a local agent) still persists normally.
                if self.windowState?.selectedDiscoveredAgentProviderId == nil {
                    AgentManager.shared.updateDefaultModel(for: pid, model: model)
                }

                self.loadActiveModelOptions(for: model)
                self.applyImageModelDefaults(for: model)

                // Clear pending image attachments when switching to a non-VLM
                // model. Computed against the NEW model id, since `@Published`
                // emits before `selectedModel` updates.
                if !Self.modelSupportsImages(modelId: model, pickerItems: self.pickerItems) {
                    self.pendingAttachments = []
                }

                self.warmupController.handleModelSelectionChange(
                    session: self,
                    to: model,
                    performSwitch: { [weak self] evictOthers in
                        await self?.performModelResidencySwitch(evictOthers: evictOthers)
                    }
                )
            }

        // Model-option toggles (Thinking, reasoning effort) change both the
        // rendered prompt tokens and the runtime's cache-scope salt, so a
        // previously warmed prefix no longer matches — re-warm under the new
        // options. Debounced so a quick toggle-and-back doesn't run two
        // warm-up generations.
        modelOptionsCancellable =
            $activeModelOptions
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, !self.isStreaming else { return }
                self.invalidateWarmupAfterContextShapeChange()
            }

        // Keep the welcome-screen context-budget estimate in sync with the
        // global singletons it reads but doesn't otherwise observe. Every
        // signal collapses (debounced) into a single cheap preview recompute,
        // guarded on the composed shape (`recomputePreviewContext`) so
        // identical re-emissions don't churn the view. `$selectedModel`
        // replays its current value on subscribe, priming the preview cache
        // and re-pricing model-family-dependent sections on a model switch.
        //
        // Scope is deliberately narrow (see #1324):
        //   • The handler is `refreshPreviewEstimate()`, never
        //     `refreshContextEstimates()` — the latter's `MemoryContextAssembler`
        //     DB read doesn't depend on these signals, and fanning it out
        //     per-signal across open chat windows saturated the cooperative
        //     pool. Memory refreshes only at the lifecycle sites below.
        //   • `SandboxManager.State` is not observed: the preview derives from
        //     the agent snapshot + registered tools + folder + model, never
        //     sandbox status. A sandbox toggle still re-prices via
        //     .agentUpdated (autonomous flag) + .toolsListChanged (tools).
        // The map closure must be @Sendable: several of these notifications
        // (.localModelsChanged from the models scan queue,
        // .remoteProviderModelsChanged from provider connects) post from
        // background threads, and a closure that inherited this init's
        // MainActor isolation would trap the runtime's isolation check when
        // Combine invokes it synchronously on the posting thread. The
        // debounce below hops to RunLoop.main before any isolated work runs.
        let voidNotification: (Notification.Name) -> AnyPublisher<Void, Never> = {
            NotificationCenter.default.publisher(for: $0)
                .map { @Sendable _ in () }.eraseToAnyPublisher()
        }
        // Channel destination edits rewrite a dynamic prompt section;
        // Default-agent and global chat settings rewrite system/tool policy.
        // All are equality-guarded by `recomputePreviewContext`, so unrelated
        // settings notifications remain no-ops after recomposition.
        let budgetSignals: [AnyPublisher<Void, Never>] =
            Self.promptShapeNotificationNames.map(voidNotification) + [
            folderState.objectWillChange
                .map { _ in () }.eraseToAnyPublisher(),
            $selectedModel.map { _ in () }.eraseToAnyPublisher(),
        ]
        contextEstimateCancellable = Publishers.MergeMany(budgetSignals)
            .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshPreviewEstimate() }
            }

        // Screen-context preview: re-capture when the agent's per-agent
        // screen-context option changes (`.agentUpdated`), the active agent
        // switches (`.activeAgentChanged`), or the user switches foreground
        // apps, so the "Screen Context" budget line and the composer chip stay
        // exact before the first send locks the snapshot. Kept off the pipeline
        // above because the capture is an Accessibility walk; debounced harder
        // to coalesce rapid app switches.
        let screenContextSignals: [AnyPublisher<Void, Never>] = [
            voidNotification(.agentUpdated),
            voidNotification(.activeAgentChanged),
            FrontmostAppTracker.shared.$lastNonSelfAppName
                .map { _ in () }.eraseToAnyPublisher(),
        ]
        screenContextCancellable = Publishers.MergeMany(screenContextSignals)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.isStreaming, !self.isScreenContextFrozen
                    else { return }
                    if await self.refreshScreenContextPreview() {
                        self.objectWillChange.send()
                    }
                }
            }

        // Always reconcile on init: the cache may already be loaded with a
        // snapshot taken before remote providers finished connecting (or
        // before this window's notification observer was registered, in
        // which case we'd otherwise miss the .remoteProviderModelsChanged
        // notification entirely). `refreshPickerItems` short-circuits when
        // nothing changed, so this is cheap on the happy path.
        Task { [weak self] in
            await self?.refreshPickerItems()
        }

        if MockChatData.isEnabled {
            rebuildVisibleBlocks()
        }
    }

    nonisolated static func shouldWarnAboutModelSwitch(
        previousModel: String?,
        newModel: String,
        hasConversation: Bool
    ) -> Bool {
        guard hasConversation, let previousModel else { return false }
        return previousModel.caseInsensitiveCompare(newModel) != .orderedSame
    }

    deinit {
        print("[ChatSession] deinit")
        preSendHandshakeEpoch &+= 1
        preSendHandshakeTask?.cancel()
        currentTask?.cancel()
        if let observer = remoteModelsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = localModelsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = agentTodoObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = privacyRedactionsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = activityRollupObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = storageMutationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = runtimeResidencyObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        modelSelectionCancellable = nil
        modelOptionsCancellable = nil
        agentAutoSpeakCancellable = nil
        promptQueueCancellable = nil
        activityMonitorCancellable = nil
        contextEstimateCancellable = nil
        modelCacheCancellable = nil
        screenContextCancellable = nil
        // Belt-and-suspenders: a session shouldn't dealloc while marked
        // active, but a stale sidebar indicator with no live session to
        // clear it would be permanent, so drop the entry on the way out.
        if let staleId = lastReportedActivitySessionId {
            Task { @MainActor in
                SessionActivityMonitor.shared.reportSession(staleId, status: nil)
            }
        }
    }

    private func loadActiveModelOptions(for model: String?) {
        guard let model else {
            activeModelOptions = [:]
            return
        }

        // Load persisted options through the active profile so stale
        // per-model toggles do not leak into families whose option surface
        // changed. This runs for both user-picked and programmatic model
        // selection paths.
        activeModelOptions = ModelProfileRegistry.normalizedOptions(
            for: model,
            persisted: ModelOptionsStore.shared.loadOptions(for: model)
        )
    }

    /// Stable session id used as the AgentTodoStore key. Falls back to a
    /// per-window sentinel when no session has been created yet so brand-new
    /// chats still have a place to write their todo.
    var expectedTodoSessionId: String {
        sessionId?.uuidString ?? "chatwindow-\(ObjectIdentifier(self).hashValue)"
    }

    /// Pull `summary` out of a `complete(...)` tool call's JSON body.
    /// Returns nil when the JSON is malformed; the caller falls back to
    /// the raw tool result string. Delegates to `CompleteTool.parseSummary`
    /// so chat and the eval harness parse completion text identically.
    static func parseCompleteSummary(from json: String) -> String? {
        CompleteTool.parseSummary(from: json)
    }

    /// Parse a `clarify(...)` tool call into a structured payload
    /// (question + optional options + allowMultiple). Delegated to
    /// `ClarifyTool.parse` so the schema lives in one place.
    static func parseClarifyPayload(from json: String) -> ClarifyPayload? {
        ClarifyTool.parse(argumentsJSON: json)
    }

    /// Apply initial model selection after agentId is set (for cached picker items)
    func applyInitialModelSelection() {
        guard selectedModel == nil, !pickerItems.isEmpty else { return }
        applyEffectiveModel(for: agentId)
        Task { [weak self] in await self?.refreshContextEstimates() }
    }

    /// For headless dispatched runs (channel / schedule / HTTP / plugin /
    /// watcher), make the agent's CURRENT default model win over whatever
    /// the session had persisted. Reattached conversations (e.g. one
    /// session per Slack room) otherwise pin the model that was selected
    /// when the session was first created, so changing an agent's default
    /// model never took effect on ongoing channel conversations — and a
    /// cold-start fallback pick became permanent. The persisted model stays
    /// as the fallback when the agent's default isn't available yet (remote
    /// catalog still loading, model uninstalled). Never touches window
    /// chats (`source == .chat`), where a manual pick must survive.
    func applyAgentDefaultModelForDispatch() {
        guard source != .chat else { return }
        guard
            let configured = AgentManager.shared.effectiveModel(for: agentId ?? Agent.defaultId),
            let model = Self.resolvePickerModelId(configured, in: pickerItems),
            selectedModel != model
        else { return }
        isLoadingModel = true
        selectedModel = model
        loadActiveModelOptions(for: model)
        applyImageModelDefaults(for: model)
        isLoadingModel = false
    }

    /// Pick the picker item that best matches the agent's preferred model
    /// (falling back to the first chat-capable item). Wrapped in
    /// `isLoadingModel = true` so the auto-persist sink in `init()` does
    /// not write the selection back to the agent's settings as if the
    /// user had manually changed it.
    private func applyEffectiveModel(for agentId: UUID?) {
        isLoadingModel = true
        let effectiveModel = AgentManager.shared.effectiveModel(for: agentId ?? Agent.defaultId)
        if let configured = effectiveModel,
            let model = Self.resolvePickerModelId(configured, in: pickerItems)
        {
            selectedModel = model
        } else if Self.pendingLocalDefaultModelId(for: agentId, in: pickerItems.map(\.id)) != nil {
            // First-run local setup includes temporary Osaurus Cloud access:
            // select the lower-cost capable Router model while the pinned
            // private model downloads. This is session-only — the agent's
            // durable default remains local, so the next picker rebuild
            // switches over as soon as that bundle lands.
            selectedModel = Self.osaurusRouterValueCandidate(in: pickerItems)?.id
        } else {
            selectedModel = pickerItems.firstChatCapable?.id
        }
        loadActiveModelOptions(for: selectedModel)
        applyImageModelDefaults(for: selectedModel)
        isLoadingModel = false
        notifySessionBecameActive()
    }

    /// Resolve an agent-configured model string to a picker item id.
    ///
    /// Agent configs written through the server API or JSON can name a local
    /// model by its short installed alias (e.g. "my-model-4bit") rather than
    /// the canonical "Org/Repo" id picker items carry. The engine and the
    /// subagent resolution path both accept those aliases via
    /// `ModelManager.findInstalledModel(named:)`, so selection must too —
    /// otherwise a dispatched (channel / schedule / delegation) session
    /// silently falls back to the first chat-capable model instead of the
    /// agent's configured one. `aliasResolver` is injectable for tests; the
    /// default consults the non-blocking installed-model cache.
    static func resolvePickerModelId(
        _ configured: String,
        in items: [ModelPickerItem],
        aliasResolver: (String) -> String? = {
            ModelManager.findInstalledModelFromCache(named: $0)?.id
        }
    ) -> String? {
        if items.contains(where: { $0.id == configured }) { return configured }
        guard
            let resolved = aliasResolver(configured),
            items.contains(where: { $0.id == resolved })
        else { return nil }
        return resolved
    }

    /// The agent's pinned default model when it's a local model that isn't
    /// usable yet — absent from the picker with its download in flight,
    /// paused, or failed. nil once the model lands (or was never in that
    /// setup window).
    static func pendingLocalDefaultModelId(for agentId: UUID?, in optionIds: [String]) -> String? {
        guard
            let model = AgentManager.shared.effectiveModel(for: agentId ?? Agent.defaultId),
            !optionIds.contains(model)
        else { return nil }
        switch ModelManager.shared.downloadStates[model] {
        case .downloading, .paused, .failed:
            return model
        case .completed, .notStarted, nil:
            return nil
        }
    }

    /// The pinned-but-still-downloading local default for this session. Stays
    /// non-nil while the temporary Cloud model is selected so the chat empty
    /// state can keep showing local download progress; becomes nil once the
    /// local bundle lands.
    var pendingLocalSetupModelId: String? {
        Self.pendingLocalDefaultModelId(for: agentId, in: pickerItems.map(\.id))
    }

    /// The temporary first-run Cloud model used while a pinned local model is
    /// downloading. DeepSeek V4 Flash is the product-selected experience;
    /// Foundation, local, and BYOK models never qualify.
    ///
    /// "Lower-cost but capable" is catalog-driven rather than a hardcoded model
    /// allowlist: prefer chat models that explicitly support tools, offer at
    /// least 32K context, and publish pricing; then minimize the sum of input
    /// and output rates. If the Router's older metadata lacks one of those
    /// fields, progressively relax the metadata requirements while staying
    /// Router-only and chat-capable.
    static func osaurusRouterValueCandidate(in items: [ModelPickerItem]) -> ModelPickerItem? {
        let routerItems = items.filter { item in
            if case .remote(_, let providerId) = item.source {
                return providerId == RemoteProviderManager.osaurusRouterProviderId
                    && item.isLikelyChatCapable
            }
            return false
        }
        guard !routerItems.isEmpty else { return nil }
        if let deepSeek = routerItems.first(where: {
            RemoteProviderManager.isFirstRunOsaurusModelId($0.id)
        }) {
            return deepSeek
        }

        func pricedMinimum(in candidates: [ModelPickerItem]) -> ModelPickerItem? {
            candidates
                .filter {
                    $0.inputPriceMicroPerMTok != nil && $0.outputPriceMicroPerMTok != nil
                }
                .min { lhs, rhs in
                    let lhsCost =
                        Double(lhs.inputPriceMicroPerMTok ?? 0)
                        + Double(lhs.outputPriceMicroPerMTok ?? 0)
                    let rhsCost =
                        Double(rhs.inputPriceMicroPerMTok ?? 0)
                        + Double(rhs.outputPriceMicroPerMTok ?? 0)
                    if lhsCost != rhsCost { return lhsCost < rhsCost }
                    // More context wins an exact price tie.
                    let lhsContext = lhs.contextLength ?? 0
                    let rhsContext = rhs.contextLength ?? 0
                    if lhsContext != rhsContext { return lhsContext > rhsContext }
                    return lhs.displayName < rhs.displayName
                }
        }

        let capable = routerItems.filter {
            $0.supportsToolCalling == true && ($0.contextLength ?? 0) >= 32_768
        }
        return pricedMinimum(in: capable)
            ?? pricedMinimum(in: routerItems.filter { $0.supportsToolCalling == true })
            ?? pricedMinimum(in: routerItems)
            ?? routerItems.first
    }

    /// Session-scoped switch to an Osaurus Router model while the agent's
    /// pinned local default is still downloading. First-run invokes this
    /// automatically; the recovery UI can invoke it again after a connection
    /// failure. Connects the Router on demand when its catalog isn't populated
    /// yet, then selects *only* a Router model —
    /// never Foundation, another local model, or a BYOK provider.
    ///
    /// Deliberately not persisted as the agent default and not recorded as a
    /// manual pick: the moment the local download lands, the next picker
    /// rebuild snaps the selection back to the model the user actually chose.
    ///
    /// Returns false when no Router model could be reached, leaving the
    /// selection empty so the caller can surface a retry instead of silently
    /// routing prompts elsewhere.
    @discardableResult
    func adoptOsaurusRouterModelWhileLocalSetupPending(
        maxConnectAttempts: Int = 20,
        connectIfNeeded: Bool = true
    ) async -> Bool {
        guard pendingLocalSetupModelId != nil else { return false }
        if isOsaurusRouterSession { return true }
        if selectOsaurusRouterBridgeModel() { return true }
        guard connectIfNeeded else { return false }

        // Router catalog not in the picker yet — (re-)enable and connect on
        // demand. First-run setup explicitly includes temporary Cloud access.
        let manager = RemoteProviderManager.shared
        manager.setOsaurusRouterEnabled(true)
        // Bounded poll (~10s at the default attempts): identity setup / the
        // enable-task connect may still be in flight, and
        // `connectOsaurusRouterIfPossible()` is a cheap no-op while connected
        // or connecting.
        let attempts = max(1, maxConnectAttempts)
        for attempt in 1 ... attempts {
            await manager.connectOsaurusRouterIfPossible()
            if manager.firstRunOsaurusRouterModelId() != nil {
                await refreshPickerItems()
                // If the local download landed while we waited, normal picker
                // reconciliation has completed the handoff. Otherwise only a
                // Router selection counts as a successful bridge.
                if pendingLocalSetupModelId == nil { return selectedModel != nil }
                return isOsaurusRouterSession || selectOsaurusRouterBridgeModel()
            }
            if attempt < attempts {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        return false
    }

    /// Select the Router bridge candidate from the current picker items, if
    /// one exists. Wrapped in `isLoadingModel` so the auto-persist sink does
    /// not write it back as the agent default.
    private func selectOsaurusRouterBridgeModel() -> Bool {
        guard let item = Self.osaurusRouterValueCandidate(in: pickerItems) else { return false }
        isLoadingModel = true
        selectedModel = item.id
        loadActiveModelOptions(for: item.id)
        applyImageModelDefaults(for: item.id)
        isLoadingModel = false
        return true
    }

    func refreshPickerItems() async {
        let newOptions = await ModelPickerItemCache.shared.buildModelPickerItems()
        applyPickerItems(newOptions)
    }

    /// Reconcile the session against a fresh picker list. Shared by the
    /// explicit `refreshPickerItems()` (which first triggers a rebuild) and
    /// the `$items` subscription (which receives the cache's already-rebuilt
    /// list). Idempotent: a no-op when nothing (ids or metadata) changed.
    func applyPickerItems(_ newOptions: [ModelPickerItem]) {
        let newOptionIds = newOptions.map { $0.id }
        let optionsChanged = pickerItems.map({ $0.id }) != newOptionIds
        let previousSelectedFamily = selectedModel.map { modelId in
            ModelFamilyGuidance.family(
                for: modelId,
                modelType: pickerItems.first(where: { $0.id == modelId })?.modelType
            )
        }

        isDiscoveringModels = false

        guard optionsChanged else {
            // Same model set, but the item metadata may have changed — e.g. a
            // Codex catalog refetch that updates reasoning capabilities or
            // default effort labels while ids stay identical. Republish the
            // items and re-normalize the active options against the refreshed
            // dynamic capability set so a stale effort level (Terra `ultra`
            // after a catalog narrowing) is dropped instead of hitting the
            // wire, without disturbing the model selection.
            if pickerItems != newOptions {
                pickerItems = newOptions
                loadActiveModelOptions(for: selectedModel)

                // A local scanner can enrich an already-listed bundle with
                // its authoritative config.json `model_type` without changing
                // the model id. Family guidance is part of the static prompt
                // prefix, so a family change must drop the old preview/send
                // context and warm claim. Otherwise the UI can remain green
                // for a prefix composed under generic guidance while the next
                // real send correctly switches to Qwen/Gemma guidance and
                // cold-prefills. This is metadata-driven invalidation only;
                // it does not alter model output, sampling, or template state.
                let refreshedSelectedFamily = selectedModel.map { modelId in
                    ModelFamilyGuidance.family(
                        for: modelId,
                        modelType: newOptions.first(where: { $0.id == modelId })?.modelType
                    )
                }
                if previousSelectedFamily != refreshedSelectedFamily {
                    cachedPreviewContext = nil
                    cachedContext = nil
                    warmupController.invalidateWarmState()
                    warmupController.scheduleWarmup(session: self)
                    objectWillChange.send()
                }
            }
            return
        }

        // Options changed (e.g., remote models loaded) - re-check agent's preferred model.
        // This corrects the initial fallback to "foundation" when remote models weren't yet available.
        // A model the user picked by hand outranks the agent's saved default:
        // rebuilds fire on runtime state changes (including the load that the
        // pick itself started), and letting the default win here snapped the
        // chip back to the old model and warm-loaded it over the user's pick.
        let effectiveModel = AgentManager.shared.effectiveModel(for: agentId ?? Agent.defaultId)
        let newSelected: String?

        if let manual = lastManualModelSelection, selectedModel == manual,
            newOptionIds.contains(manual)
        {
            newSelected = manual
        } else if let model = effectiveModel, newOptionIds.contains(model) {
            newSelected = model
        } else if let prev = selectedModel, newOptionIds.contains(prev) {
            newSelected = prev
        } else if Self.pendingLocalDefaultModelId(for: agentId, in: newOptionIds) != nil {
            // Pinned local default still downloading: first-run includes
            // temporary Osaurus Cloud access, so adopt the catalog-driven
            // lower-cost capable Router model as soon as it appears.
            newSelected = Self.osaurusRouterValueCandidate(in: newOptions)?.id
        } else {
            newSelected = newOptions.firstChatCapable?.id
        }

        pickerItems = newOptions
        isLoadingModel = true
        selectedModel = newSelected
        loadActiveModelOptions(for: selectedModel)
        applyImageModelDefaults(for: selectedModel)
        isLoadingModel = false
        hasAnyModel = !newOptions.isEmpty
    }

    /// Check if the currently selected model supports images (VLM)
    var selectedModelSupportsImages: Bool {
        guard let model = selectedModel else { return false }
        return Self.modelSupportsImages(modelId: model, pickerItems: pickerItems)
    }

    /// Whether `modelId` can accept image input. Local models are gated on
    /// detected VLM capability; remote provider models are trusted to accept
    /// images. A plain remote provider exposes a flat model list with no
    /// capability metadata, so a remote item's `isVLM` is false even for
    /// genuinely vision-capable models (e.g. current GPT / Claude / Gemini
    /// releases). Gating on it silently dropped attached images from the
    /// outbound request while the UI still displayed them in the bubble —
    /// far worse than the alternative failure, where a text-only remote
    /// model rejects the image part with a visible provider error.
    static func modelSupportsImages(modelId: String, pickerItems: [ModelPickerItem]) -> Bool {
        if modelId.lowercased() == "foundation" { return false }
        if ModelMediaCapabilities.from(modelId: modelId).supportsImage { return true }
        guard let option = pickerItems.first(where: { $0.id == modelId }) else { return false }
        // Image-edit models accept image input (osaurus image-edit feature).
        if option.imageCapabilities?.imageEdit == true { return true }
        if option.mediaModel?.kind == .imageToVideo { return true }
        if option.isVLM { return true }
        if case .remote = option.source { return !option.isEmbedding }
        return false
    }

    var selectedModelSupportsAudio: Bool {
        selectedModelSendCapabilities.supportsAudio
    }

    var selectedModelSupportsVideo: Bool {
        selectedModelSendCapabilities.supportsVideo
    }

    /// Media capabilities the SEND path gates on. Must resolve exactly like
    /// the composer's attach gate (`FloatingInputCard.mediaCapabilityDescriptor`)
    /// — the name-only matcher requires a "-vl" suffix that community bundles
    /// like "Qwen3.6-35B-A3B-6bit" don't carry, so gating the send on it
    /// silently dropped a video the composer had happily accepted: the model
    /// then answers "I don't see any video". Same failure class as the remote
    /// image drop documented on `modelSupportsImages`.
    /// The SEND gate, and it is a second site: the picker deciding a modality
    /// is allowed does not make `buildUserChatMessage` include it. This getter
    /// used to omit the checkpoint audio fact, so on gemma-4 E2B — a bundle
    /// that carries `embed_audio.embedding_projection` — the picker accepted a
    /// `.wav`, the chip appeared, and then `supportsAudio` was false here, so
    /// the audio was dropped and the plain (partless) initializer ran.
    /// Instrumented live: the user message reached the engine with
    /// `parts= images=0 audios=0` while an image turn in the same session
    /// reached it with `images=1`.
    private var selectedModelSendCapabilities: ModelMediaCapabilities.Capabilities {
        guard let model = selectedModel else { return .textOnly }
        let localModel = ModelManager.findInstalledMLXModelFromCache(named: model)
        return ModelMediaCapabilities.composerCapabilities(
            modelId: model,
            fallbackSupportsImages: selectedModelSupportsImages,
            localModelType: localModel?.modelType,
            localHasAudioTensors: localModel?.hasAudioTensors ?? false
        )
    }

    /// Get the currently selected ModelPickerItem
    var selectedPickerItem: ModelPickerItem? {
        guard let model = selectedModel else { return nil }
        return pickerItems.first { $0.id == model }
    }

    var selectedImagePickerItem: ModelPickerItem? {
        guard let model = selectedModel else { return nil }
        return pickerItems.first {
            $0.id == model
                && ($0.source.isImageGeneration || $0.mediaModel?.kind == .image)
        }
    }

    var selectedVideoPickerItem: ModelPickerItem? {
        guard let model = selectedModel else { return nil }
        return pickerItems.first {
            $0.id == model && $0.mediaModel?.kind.isVideo == true
        }
    }

    private func applyImageModelDefaults(for model: String?) {
        guard let model,
            let item = pickerItems.first(where: { $0.id == model && $0.isMediaGeneration })
        else { return }
        var settings = imageComposerSettings
        if let media = item.mediaModel {
            settings.applyMediaDefaults(media.constraints)
        } else {
        settings.applyModelDefaults(steps: item.imageDefaultSteps, guidance: item.imageDefaultGuidance)
        }
        imageComposerSettings = settings
    }

    /// True when the selected model is served by the managed Osaurus Router
    /// (the billed, identity-signed cloud provider). Drives the per-session
    /// spend indicator in the composer.
    var isOsaurusRouterSession: Bool {
        if case .remote(_, let providerId)? = selectedPickerItem?.source {
            return providerId == RemoteProviderManager.osaurusRouterProviderId
        }
        return false
    }

    /// Friendly name for the temporary first-run Cloud status shown alongside
    /// local download progress. Router ids are slug-like; preserve the product
    /// spelling for DeepSeek V4 Flash.
    var temporaryCloudModelDisplayName: String? {
        guard isOsaurusRouterSession, let item = selectedPickerItem else { return nil }
        if RemoteProviderManager.isFirstRunOsaurusModelId(item.id) {
            return "DeepSeek V4 Flash"
        }
        return item.displayName
    }

    /// Total micro-USD billed by the Osaurus Router across this session's turns.
    /// Summed from each turn's persisted `routerBilling`, so it reflects both the
    /// live run and a reloaded session. The on-device ledger remains the exact
    /// source of truth if a single turn ever carried more than one charge.
    var sessionRouterSpendMicro: Int {
        turns.reduce(0) { sum, turn in
            guard let raw = turn.routerBilling?.costMicro else { return sum }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return sum + (Int(trimmed) ?? 0)
        }
    }

    /// True when the selected model is a local model — the kind that runs on
    /// the device's shared inference context. Covers both osaurus-downloaded
    /// models and externally-discovered ones (LM Studio, Hugging Face cache),
    /// since `findInstalledModel` resolves the merged local catalog. Foundation
    /// (Apple on-device) and remote provider models run on separate engines and
    /// don't contend. Resolved against the catalog so it doesn't depend on
    /// `pickerItems` being populated.
    var selectedModelIsLocal: Bool {
        guard let model = selectedModel else { return false }
        // Cache-only: this getter runs in main-actor/view contexts where the
        // blocking lookup can park on the cold-cache disk scan for seconds.
        return ModelManager.findInstalledModelFromCache(named: model) != nil
    }

    /// True while this session is streaming a reply from a local model.
    var isStreamingLocalModel: Bool {
        isStreaming && selectedModelIsLocal
    }

    /// A local generation would collide with one already running in another
    /// window. The shared inference context runs a single generation at a time,
    /// and loading this model could evict (and cancel) the active one — so the
    /// caller surfaces an alert and refuses the send instead.
    var localModelBusyInOtherWindow: Bool {
        selectedModelIsLocal
            && ChatWindowManager.shared.isOtherWindowStreamingLocalModel(
                excluding: windowState?.windowId
            )
    }

    /// Whether `send` must refuse because of `localModelBusyInOtherWindow`.
    ///
    /// Delegated child sessions are exempt. Their orchestrating parent is
    /// itself a chat run whose `isStreaming` stays true for the whole turn —
    /// including the spawn tool call that is parked awaiting THIS child — so
    /// the cross-window busy guard would always count the parent and
    /// silently no-op the delegated send (leaving the child task running
    /// until its wall-clock deadline). The parent's generation is idle while
    /// it awaits the child, and local-model arbitration for delegations
    /// already happened reject-before-evict in the spawn pipeline
    /// (`SubagentAdmission` + `SubagentResidency` coexistence/handoff), so
    /// this user-facing refusal must not apply.
    var refusesLocalBusySend: Bool {
        Self.refusesLocalBusySend(
            source: source,
            localModelBusyInOtherWindow: localModelBusyInOtherWindow
        )
    }

    /// Pure contract for `refusesLocalBusySend` (unit-testable without live
    /// window/registry state).
    static func refusesLocalBusySend(
        source: SessionSource,
        localModelBusyInOtherWindow: Bool
    ) -> Bool {
        source != .delegation && localModelBusyInOtherWindow
    }

    /// Backing store for the streaming-mutated `visibleBlocks` / group-header map.
    /// Deliberately NOT `@Published` — mutations go through the store's own
    /// `objectWillChange`, not the session's, so ChatView's body + every sibling
    /// view stay static during streaming. The message thread subtree observes
    /// this store directly.
    let visibleBlocksStore = VisibleBlocksStore()

    /// Suppresses `rebuildVisibleBlocks()` while a session switch is in flight.
    /// `load(from:)` calls `stop()` first, whose `completeRunCleanup` would
    /// rebuild blocks for the OUTGOING session — a full re-render cascade that
    /// is immediately discarded when `load` swaps in the new session and
    /// rebuilds. Skipping it removes one of two rebuilds per switch.
    private var suppressVisibleBlockRebuild = false

    /// Mode 2 override for the per-turn header name baked into `visibleBlocks`.
    /// When non-nil (a remote agent owns the chat), thread headers show the
    /// remote agent's name instead of the local agent's — without it, blocks
    /// always baked the local name and the thread read "Osaurus". `ChatView`
    /// keeps this in sync with `ChatWindowState.effectiveChatIdentity`; nil
    /// restores the local-agent name.
    var threadAgentDisplayName: String?

    /// Flattened content blocks for NSTableView rendering.
    /// Read-through to `visibleBlocksStore.blocks` so existing call sites
    /// (helpers, checks that don't need to drive re-renders) keep working.
    var visibleBlocks: [ContentBlock] { visibleBlocksStore.blocks }

    /// Precomputed group header map. Read-through to the store.
    var visibleBlocksGroupHeaderMap: [UUID: UUID] { visibleBlocksStore.groupHeaderMap }

    /// Whether the message thread has content (includes USE_MOCK_CHAT_DATA stress data).
    var hasVisibleThreadMessages: Bool {
        if MockChatData.isEnabled {
            return !visibleBlocks.isEmpty
        }
        return !turns.isEmpty
    }

    /// Last assistant turn for hover/regen chrome; respects mock thread when enabled.
    var lastAssistantTurnIdForThread: UUID? {
        if MockChatData.isEnabled {
            return visibleBlocks.last { $0.role == .assistant }?.turnId
        }
        return turns.last { $0.role == .assistant }?.id
    }

    /// Rebuild `visibleBlocks` and `visibleBlocksGroupHeaderMap` from current turns.
    /// Cheap to call repeatedly — BlockMemoizer fast-paths when nothing changed.
    func rebuildVisibleBlocks() {
        // Skipped mid-session-switch; `load(from:)` rebuilds once for the
        // incoming session. See `suppressVisibleBlockRebuild`.
        if suppressVisibleBlockRebuild { return }
        ChatPerfTrace.shared.count("rebuildVisibleBlocks")
        ChatPerfTrace.shared.time("rebuildVisibleBlocks.total") {
            rebuildVisibleBlocksImpl()
        }
    }

    private func rebuildVisibleBlocksImpl() {
        let agent = AgentManager.shared.agent(for: agentId ?? Agent.defaultId)
        let localName = agent?.displayName ?? L("Osaurus")
        // In Mode 2 the remote agent owns the conversation, so its name heads
        // the thread; otherwise fall back to the local agent's name.
        let displayName = threadAgentDisplayName ?? localName
        var streamingTurnId = (isStreaming && !outputComplete) ? turns.last?.id : nil

        // While a send waits on the pre-send warm-up handshake there is no
        // assistant turn yet; render a placeholder typing-indicator group so
        // the model-load/prefill wait is visible. The placeholder never
        // enters `turns` — it exists only in this rebuild's block input.
        var effectiveTurns = turns
        if awaitingPreSendHandshake, !isStreaming, !turns.isEmpty {
            effectiveTurns.append(preSendHandshakePlaceholderTurn)
            streamingTurnId = preSendHandshakePlaceholderTurn.id
        }

        if MockChatData.isEnabled {
            let mockTurns = MockChatData.mockTurnsForPerformanceTest()
            let newBlocks = blockMemoizer.blocks(
                from: mockTurns,
                streamingTurnId: nil,
                agentName: displayName
            )
            let newHeaderMap = blockMemoizer.groupHeaderMap
            withAnimation(.none) {
                visibleBlocksStore.blocks = newBlocks
                visibleBlocksStore.groupHeaderMap = newHeaderMap
            }
            return
        }

        seedAutoExpandedReasoningBlocks(streamingTurnId: streamingTurnId)

        // Display-time only, like coalescing/rollup: the LLM compaction
        // divider never enters the memoizer cache, so per-turn incremental
        // regeneration keeps its stable ids.
        let newBlocks = insertFollowUpSuggestionsIfNeeded(
            into: insertCompactionMarkerIfNeeded(
                into: blockMemoizer.blocks(
                    from: effectiveTurns,
                    streamingTurnId: streamingTurnId,
                    agentName: displayName
                )
            )
        )
        let newHeaderMap = blockMemoizer.groupHeaderMap

        // After block generation so the fresh array is scanned for the
        // activity rollup enclosing the live thinking block (the rollup is
        // display-time only — it never exists in the turn model).
        updateStreamingThinkingExpansion(streamingTurnId: streamingTurnId, in: newBlocks)

        // use withAnimation(.none) to suppress the warning about publishing during view updates
        // this wraps the changes in a proper SwiftUI transaction
        withAnimation(.none) {
            visibleBlocksStore.blocks = newBlocks
            visibleBlocksStore.groupHeaderMap = newHeaderMap
        }
    }

    /// Inject the compaction-boundary divider right after the last block of
    /// the last summary-covered turn. No-ops when there's no (valid) summary
    /// or the covered span was windowed out by the display cap.
    private func insertCompactionMarkerIfNeeded(into blocks: [ContentBlock]) -> [ContentBlock] {
        guard let summary = conversationSummary,
            ContextCompactionService.summaryIsValid(summary, for: turns),
            let lastCoveredId = summary.coveredTurnIds.last
        else { return blocks }
        let covered = Set(summary.coveredTurnIds)
        guard let lastIndex = blocks.lastIndex(where: { covered.contains($0.turnId) }) else {
            return blocks
        }
        var result = blocks
        result.insert(
            .compactionMarker(summary: summary, afterTurnId: lastCoveredId),
            at: lastIndex + 1
        )
        return result
    }

    /// Inject the follow-up suggestions row right after the last block of the
    /// turn the suggestions belong to (its `assistantActions` footer), so they
    /// read as the tail of that assistant message and scroll with it. Display-
    /// time only, like the compaction marker — never enters the block cache.
    private func insertFollowUpSuggestionsIfNeeded(into blocks: [ContentBlock]) -> [ContentBlock] {
        guard !followUpSuggestions.isEmpty, let turnId = followUpTurnId,
            let lastIndex = blocks.lastIndex(where: { $0.turnId == turnId })
        else { return blocks }
        var result = blocks
        result.insert(
            .followUpSuggestions(turnId: turnId, suggestions: followUpSuggestions),
            at: lastIndex + 1
        )
        return result
    }

    /// Auto-expand the thinking block of a completed reasoning-only turn so the
    /// reasoning the user was (often) billed for is visible instead of a
    /// collapsed "Thought for Xs" they have to click. Seeds the shared
    /// expansion store once per block (covers freshly finished and reloaded
    /// turns); the user can collapse it afterward.
    private func seedAutoExpandedReasoningBlocks(streamingTurnId: UUID?) {
        for turn in turns where turn.role == .assistant {
            guard turn.id != streamingTurnId,
                turn.hasRenderableThinking,
                turn.contentIsBlank,
                (turn.toolCalls ?? []).isEmpty
            else { continue }
            let blockId = ContentBlock.thinkingBlockId(turnId: turn.id)
            guard !autoExpandedReasoningBlockIds.contains(blockId) else { continue }
            autoExpandedReasoningBlockIds.insert(blockId)
            expandedBlocksStore.expand(blockId)
        }
    }

    /// While the streaming turn is in its reasoning-only phase (no answer
    /// content or tool calls yet), keep its thinking block expanded so the
    /// user can watch the reasoning live; once the phase ends, collapse it
    /// again to keep the thread clean. Opt-in via the Chat settings toggle
    /// (`chatExpandThinkingWhileStreamingEnabled`, default off). Runs on
    /// every visible-blocks rebuild, which fires per streaming delta and
    /// once more from `completeRunCleanup`, so the collapse also lands when
    /// a run ends or is cancelled mid-thought.
    private func updateStreamingThinkingExpansion(streamingTurnId: UUID?, in blocks: [ContentBlock]) {
        let activeThinkingBlockId: String? = {
            guard
                UserDefaults.standard.bool(forKey: "chatExpandThinkingWhileStreamingEnabled"),
                let streamingTurnId,
                let turn = turns.last, turn.id == streamingTurnId,
                turn.role == .assistant,
                turn.hasRenderableThinking,
                turn.contentIsBlank,
                (turn.toolCalls ?? []).isEmpty
            else { return nil }
            return ContentBlock.thinkingBlockId(turnId: streamingTurnId)
        }()

        // When the activity rollup has grouped the live thinking block with
        // earlier tool activity (agent loops), open the enclosing group too —
        // the reasoning streams inside the opened rollup, and both fold back
        // when the phase ends, preserving this toggle's observable behavior.
        var activeIds: Set<String> = []
        if let activeThinkingBlockId {
            activeIds.insert(activeThinkingBlockId)
            if let groupId = ContentBlock.enclosingActivityGroupId(
                forChildId: activeThinkingBlockId,
                in: blocks
            ) {
                activeIds.insert(groupId)
            }
        }

        // Collapse blocks whose thinking phase has ended — unless the
        // completed-reasoning-only seeding above wants them expanded.
        for blockId in streamingAutoExpandedThinkingBlockIds where !activeIds.contains(blockId) {
            streamingAutoExpandedThinkingBlockIds.remove(blockId)
            if !autoExpandedReasoningBlockIds.contains(blockId) {
                expandedBlocksStore.collapse(blockId)
            }
        }

        // Expand at most once per block so a manual collapse mid-stream
        // isn't fought on the next delta.
        for blockId in activeIds where !streamingAutoExpandedThinkingBlockIds.contains(blockId) {
            streamingAutoExpandedThinkingBlockIds.insert(blockId)
            expandedBlocksStore.expand(blockId)
        }
    }

    /// Estimated token count for current session context (~4 chars per token).
    /// Throttled to at most once per 500ms during streaming.
    var estimatedContextTokens: Int {
        estimatedContextBreakdown.total
    }

    /// Per-category breakdown of estimated context tokens.
    /// During streaming, returns the active snapshot with live output tokens.
    /// Otherwise derives from the cached `ComposedContext` or a preview manifest.
    var estimatedContextBreakdown: ContextBreakdown {
        // Traced: computed inside ChatView body evaluation, so the report's
        // call count reveals per-render recomputation (production app hangs
        // have landed inside this path).
        ChatPerfTrace.shared.time("chat.estimatedContextBreakdown") {
            estimatedContextBreakdownImpl
        }
    }

    private var estimatedContextBreakdownImpl: ContextBreakdown {
        if let active = budgetTracker.activeBreakdown(
            isActive: isStreaming,
            outputTurn: turns.last
        ) {
            return active
        }

        // With an LLM compaction summary, the model sees the summary message
        // instead of the covered turns — price the next send accordingly and
        // surface the summary's own cost as a dedicated row.
        let coveredIds = summaryCoveredTurnIds
        let modelVisibleTurns =
            coveredIds.isEmpty ? turns : turns.filter { !coveredIds.contains($0.id) }
        let summaryTokens =
            conversationSummary.map {
                ContextBudgetManager.estimateTokens(for: $0.contextMessageText)
            } ?? 0

        let outputTokens = ContextBudgetManager.estimateOutputTokens(for: modelVisibleTurns)
        let conversationTokens =
            ContextBudgetManager.estimateTokens(for: modelVisibleTurns) - outputTokens
        var inputTokens = 0
        if !input.isEmpty { inputTokens += ContextBudgetManager.estimateTokens(for: input) }
        for attachment in pendingAttachments { inputTokens += attachment.estimatedTokens }

        func addingSummaryRow(_ breakdown: ContextBreakdown) -> ContextBreakdown {
            guard summaryTokens > 0 else { return breakdown }
            var bd = breakdown
            bd.setTokens(
                for: "summary",
                in: \.messages,
                tokens: summaryTokens,
                label: L("Summary"),
                tint: .teal
            )
            return bd
        }

        if let ctx = cachedContext {
            return addingSummaryRow(
                .from(
                    context: ctx,
                    screenContextTokens: cachedScreenContextTokens,
                    conversationTokens: conversationTokens,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens
                )
            )
        }

        // Mirror what `composeChatContext` will emit on the next send so
        // the welcome-screen popover lists the same sections (Agent Loop,
        // Capability Discovery, Skills, model family, …) instead of the
        // base+sandbox-only stub. Under Design C the schema is a fixed hot
        // set and the manifest is query-independent, so the preview prices
        // the static prefix exactly.
        //
        // The preview is cached (recomputed only when a budget input
        // changes — see `refreshContextEstimates`) so typing only
        // re-derives the cheap conversation/input/output overlay below.
        // First render before any refresh has run lazily composes + fills
        // the cache so the popover is never empty.
        guard let preview = previewContext() else {
            // Preview not composed yet (first render, or a storage-key rotation
            // is in flight and we won't park the main thread to open the DB).
            // Surface the cheap conversation/input/output overlay now; the
            // system-prefix rows fill in once `refreshContextEstimates` runs.
            return addingSummaryRow(
                .from(
                    manifest: .empty,
                    memoryTokens: cachedMemoryTokens,
                    screenContextTokens: cachedScreenContextTokens,
                    conversationTokens: conversationTokens,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens
                )
            )
        }
        return addingSummaryRow(
            .from(
                manifest: preview.manifest,
                toolTokens: preview.toolTokens,
                memoryTokens: cachedMemoryTokens,
                screenContextTokens: cachedScreenContextTokens,
                conversationTokens: conversationTokens,
                inputTokens: inputTokens,
                outputTokens: outputTokens
            )
        )
    }

    /// Return the cached welcome/pre-send preview context, lazily composing
    /// and caching it on the first read. Pure read otherwise — does not emit
    /// `objectWillChange`, so it's safe to call from within a view-body
    /// evaluation.
    private func previewContext() -> ComposedContext? {
        if let cached = cachedPreviewContext { return cached }
        // Composing reads the agent DB. `*Database.open()` parks on
        // `StorageMutationGate.blockingAwaitNotMutating()`, which spins the
        // main run loop while a storage-key rotation is in flight — that
        // surfaced as a multi-second app hang when this lazily composed inside
        // the view-body evaluation. Defer instead of parking the UI; the
        // rotation-finished observer retries via `refreshContextEstimates`.
        if StorageMutationGate.isRotationInFlight { return nil }
        let preview = composePreview()
        cachedPreviewContext = preview
        return preview
    }

    /// Whether the next local UI send exposes at least one tool and will
    /// therefore carry the same agent/tool marker consumed by
    /// `ChatEngine.prepareDispatch`. The composer uses this exact preview
    /// surface to present the untouched Thinking default truthfully.
    var appliesAgentReasoningDefault: Bool {
        guard !isRemoteAgentTarget else { return false }
        return previewContext()?.tools.isEmpty == false
    }

    /// Compose a fresh welcome/pre-send preview from the current agent /
    /// sandbox / tool / folder / model state. Pure — no caching, no
    /// `objectWillChange`. Single source of truth for the lazy read
    /// (`previewContext`) and the budget-input recompute
    /// (`recomputePreviewContext`).
    private func composePreview() -> ComposedContext {
        let effectiveId = agentId ?? Agent.defaultId
        // Price the popover under this session's source, exactly as the send
        // binds it. Source-scoped gates (channel publish tool + Channel
        // Destinations section) read the task-local; previewing with it unset
        // showed a smaller context than the send then composed, which read as
        // "dynamic tools appeared" when the send's manifest replaced the
        // estimate.
        return ChatExecutionContext.$currentSessionSource.withValue(source) {
            SystemPromptComposer.composePreviewContext(
                agentId: effectiveId,
                executionMode: estimatedChatExecutionMode(agentId: effectiveId),
                model: selectedModel,
                modelType: selectedPickerItem?.modelType
            )
        }
    }

    /// Builds the full user message text, prepending any attached document contents wrapped in XML tags.
    ///
    /// Filenames are reduced to their basename and both the name and the body are
    /// XML-entity-escaped so that a hostile document cannot forge a closing
    /// `</attached_document>` tag or inject bracketed pseudo-tool markers that
    /// would otherwise reach the model as control text.
    static func buildUserMessageText(content: String, attachments: [Attachment]) -> String {
        let docs = attachments.filter(\.isDocument)
        guard !docs.isEmpty else { return content }

        var parts: [String] = []
        for doc in docs {
            if let name = doc.filename, let text = doc.documentContent {
                let attributes = attachedDocumentAttributes(for: doc, rawName: name)
                let safeText = xmlEscape(text)
                parts.append("<attached_document \(attributes)>\n\(safeText)\n</attached_document>")
            }
        }

        if !content.isEmpty {
            parts.append(content)
        }

        return parts.joined(separator: "\n\n")
    }

    static func buildUserChatMessage(
        content: String,
        attachments: [Attachment],
        supportsImages: Bool,
        supportsAudio: Bool,
        supportsVideo: Bool
    ) -> ChatMessage {
        let messageText = buildUserMessageText(content: content, attachments: attachments)
        let imageData = supportsImages ? attachments.loadImages() : []
        let audioPayloads =
            supportsAudio
            ? attachments.compactMap(audioPayload)
            : []
        let audios = audioPayloads.map { (data: $0.data, format: $0.format) }
        let localAudioSamples = audioPayloads.map(\.localSamples)
        let videos: [(data: Data, mimeSubtype: String)] =
            supportsVideo
            ? attachments.compactMap(videoPayload)
            : []

        if !imageData.isEmpty || !audios.isEmpty || !videos.isEmpty {
            return ChatMessage(
                role: "user",
                text: messageText,
                imageData: imageData,
                audios: audios,
                localAudioSamples: localAudioSamples,
                videos: videos
            )
        }

        return ChatMessage(role: "user", content: messageText)
    }

    /// Render one assistant transcript turn into model-visible history.
    /// A trailing empty turn is the live streaming buffer and must stay out of
    /// the next request; a preserved progress turn immediately before it must
    /// appear exactly once. Kept as a pure helper so continuation history is
    /// testable without launching a model.
    static func modelVisibleAssistantMessage(
        _ turn: ChatTurn,
        isLastTurn: Bool,
        excludedFromRequest: Bool = false
    ) -> ChatMessage? {
        if excludedFromRequest || turn.modelContextExcluded { return nil }
        if isLastTurn,
            turn.contentIsBlank,
            turn.thinkingIsBlank,
            turn.toolCalls == nil
        {
            return nil
        }
        if turn.contentIsBlank,
            turn.thinkingIsBlank,
            (turn.toolCalls == nil || turn.toolCalls!.isEmpty)
        {
            return nil
        }

        return ChatMessage(
            role: "assistant",
            content: turn.contentIsBlank ? nil : turn.content,
            tool_calls: turn.toolCalls,
            tool_call_id: nil,
            reasoning_content: turn.thinkingIsBlank ? nil : turn.thinking,
            reasoning_item_id: turn.reasoningItemId,
            reasoning_encrypted: turn.reasoningEncrypted,
            responses_output_items: turn.responsesOutputItems.isEmpty
                ? nil : turn.responsesOutputItems
        )
    }

    /// Mark a model-authored terminal response as an abandoned protocol
    /// attempt when structured Todo work from this run remains unchecked.
    /// The response stays in the visible transcript, but feeding it back before
    /// a fresh assistant tool call creates two adjacent assistant messages.
    /// Qwen-family templates render that malformed history differently and a
    /// hybrid disk restore can then resume unrelated state. This is the same
    /// persistence-backed exclusion contract used for incomplete reasoning;
    /// no model text, tags, sampling, or stop behavior is synthesized.
    static func excludeAbandonedTrackedTaskResponse(_ turn: ChatTurn) {
        turn.modelContextExcluded = true
    }

    /// Prepend a user turn's frozen memory / screen-context prefix to its
    /// rendered message. The prefix already carries its trailing separator
    /// (`SystemPromptComposer.composeInjectedUserPrefix`), so this is a pure
    /// byte concatenation — `prefix + content` reproduces exactly what the
    /// legacy per-iteration injectors used to send. Multimodal messages are
    /// returned unchanged, matching the injectors' `contentParts` guard.
    static func applyingFrozenInjectedPrefix(
        _ prefix: String?,
        to message: ChatMessage
    ) -> ChatMessage {
        guard let prefix, !prefix.isEmpty, message.contentParts == nil else { return message }
        return ChatMessage(
            role: message.role,
            content: prefix + (message.content ?? ""),
            tool_calls: message.tool_calls,
            tool_call_id: message.tool_call_id
        )
    }

    private static func audioPayload(from attachment: Attachment) -> (
        data: Data,
        format: String,
        localSamples: LocalAudioSamples?
    )? {
        guard attachment.isAudio, let data = attachment.loadAudioData() else { return nil }
        let format = attachment.audioFormat?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return (
            data,
            (format?.isEmpty == false) ? format! : "wav",
            LiveVoiceAudioInputRegistry.shared.samples(for: attachment.id)
        )
    }

    private static func videoPayload(from attachment: Attachment) -> (data: Data, mimeSubtype: String)? {
        guard attachment.isVideo, let data = attachment.loadVideoData() else { return nil }
        return (data, videoMimeSubtype(for: attachment.filename))
    }

    private static func videoMimeSubtype(for filename: String?) -> String {
        let ext = ((filename ?? "") as NSString).pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch ext {
        case "mov", "qt", "quicktime":
            return "quicktime"
        case "m4v":
            return "mp4"
        case "":
            return "mp4"
        default:
            return ext
        }
    }

    private static func escapeAttachmentName(_ raw: String) -> String {
        xmlEscape(normalizedAttachmentName(raw))
    }

    private static func normalizedAttachmentName(_ raw: String) -> String {
        let basename = (raw as NSString).lastPathComponent
        let trimmed = basename.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "attachment" : trimmed
    }

    private static func attachedDocumentAttributes(for attachment: Attachment, rawName: String) -> String {
        var attributes: [(name: String, value: String)] = [
            ("name", normalizedAttachmentName(rawName))
        ]
        if attachment.structuredDocumentMetadata != nil {
            if let summary = attachment.businessDocumentSummary {
                attributes.append(contentsOf: summary.contextAttributes)
            }
        }
        return
            attributes
            .map { "\($0.name)=\"\(xmlEscape($0.value))\"" }
            .joined(separator: " ")
    }

    private static func xmlEscape(_ s: String) -> String {
        s
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Format token count for display (e.g., "1.2K", "15K")
    static func formatTokenCount(_ tokens: Int) -> String {
        if tokens < 1000 {
            return "\(tokens)"
        } else if tokens < 10000 {
            let k = Double(tokens) / 1000.0
            return String(format: "%.1fK", k)
        } else {
            let k = tokens / 1000
            return "\(k)K"
        }
    }

    func sendCurrent() {
        // A normal UI send can arrive before SwiftUI has redrawn the composer
        // into its queue/Stop state. Preserve that draft in the existing
        // single-slot queue instead of clearing it and dropping it behind the
        // retained handshake task.
        if preSendHandshakeTask != nil {
            enqueueSend(input, attachments: pendingAttachments)
            return
        }
        guard !isStreaming else { return }
        // One local generation at a time across all windows: the shared
        // inference context can't run two, and loading a second would evict and
        // cancel the active one. Surface the alert and keep the draft intact.
        if localModelBusyInOtherWindow {
            windowState?.showLocalModelBusyAlert = true
            return
        }
        // Auto LLM compaction: when the estimated next send crosses the
        // near-limit threshold and there's an uncovered older span, compact
        // FIRST (dialog shows live progress; first run asks for a model),
        // then resume this send. The draft stays in `input` untouched.
        let hasSendableContent =
            !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !pendingAttachments.isEmpty
        if hasSendableContent, shouldAutoCompactBeforeSend {
            beginCompaction(resumeSend: true, showDialogWhileRunning: true)
            return
        }
        skipAutoCompactionForNextSend = false
        let text = input
        let attachments = pendingAttachments
        input = ""
        pendingAttachments = []
        send(text, attachments: attachments)
    }

    /// Pre-send warm-up handshake: wait for an in-flight model switch
    /// (stale warm-up unwind + eviction) to settle, then wait for any
    /// in-flight warm-up generation to finish so its prefilled KV prefix is
    /// stored and the real request can prefix-hit. Does NOT start new
    /// warm-up work.
    private static func prepareForSendWarmup(
        using warmupController: ChatWarmupController
    ) async -> Bool {
        await warmupController.awaitRetiringWork()
        guard !Task.isCancelled else { return false }
        await warmupController.awaitActiveModelSwitch()
        // Stop/reset/session-load may cancel this outer handshake while the
        // model switch is suspended. The controller is reused by the incoming
        // chat, so a stale task must not cancel that chat's newly scheduled
        // warm-up after the old switch finally unwinds.
        guard !Task.isCancelled else { return false }
        // The switch task's last step schedules a fresh warm-up; this send
        // owns the next generation, so drop that scheduled warm-up before it
        // starts (a warm-up that already reached generation is covered by
        // the await below and only pre-warms this send's own prefix).
        warmupController.cancelScheduledWarmup()
        await warmupController.awaitRequiredContextWarmup()
        guard !Task.isCancelled else { return false }
        await warmupController.awaitInFlightWarmup()
        return !Task.isCancelled
    }

    /// `preservesCancelledMarker` distinguishes the user's Stop button (the
    /// transcript must record that a run was cancelled — see the trim guard)
    /// from internal lifecycle stops (explicit model unload) where the run
    /// dying is a side effect the user never chose; those keep the historical
    /// clean trim so no ghost "cancelled" row appears in the transcript.
    func stop(preservesCancelledMarker: Bool = true) {
        stopPreservesCancelledMarker = preservesCancelledMarker
        // Capture BEFORE any cancellation: whether a send was in flight when
        // the user hit Stop. The marker decision below must not depend on
        // state the cleanup path is about to reset.
        let hadActiveSend =
            isSendActiveForComposer || isStreaming || activeRunId != nil
            || currentTask != nil || awaitingPreSendHandshake
        let wasAwaitingPreSendHandshake = awaitingPreSendHandshake
        invalidatePreSendHandshake()
        if wasAwaitingPreSendHandshake {
            warmupController.cancelPendingWorkForUserStop()
        }
        // Resolve every mounted/queued prompt (secret, clarify) BEFORE
        // cancelling the run: a tool call parked on a prompt continuation
        // does not observe task cancellation, so without this drain Stop
        // would leave that continuation suspended forever, the overlay
        // mounted, and the input bar hit-test disabled.
        promptQueue.drainAll()
        stopRequested = true
        let task = currentTask
        task?.cancel()
        if let runId = activeRunId {
            finalizeRun(runId: runId, persistConversationArtifacts: false)
        } else {
            completeRunCleanup()
        }
        // A user Stop that cancels the send before the run task appended its
        // assistant turn (the pre-send handshake window, or simply a Stop
        // that wins the race to the first append — CI machines hit the
        // latter on a plain send) leaves the transcript ending on the user
        // row with no record that a run happened. Append the cancelled
        // marker AFTER cleanup so it cannot be trimmed and so the
        // stamped-placeholder path (finalizeRun stamped an existing turn,
        // which the trim keeps) never produces a second marker.
        if preservesCancelledMarker, hadActiveSend,
            let last = turns.last, last.role == .user
        {
            let cancelledTurn = ChatTurn(role: .assistant, content: "")
            cancelledTurn.terminalStopReason = "cancelled"
            turns.append(cancelledTurn)
            isDirty = true
            rebuildVisibleBlocks()
        }
    }

    /// Put this session on the same cancellation path as its visible Stop
    /// control before an explicit model-cache unload tears down the runtime.
    /// Cancelling only the runtime producer ends its stream without telling
    /// the chat lifecycle that the run was stopped; cleanup can then classify
    /// the partial response as successful and immediately warm-load the model
    /// the user just unloaded.
    func prepareForExplicitModelUnload() {
        warmupController.cancelPendingWorkForExplicitModelUnload()
        if isSendActiveForComposer {
            // Lifecycle stop: the user chose to unload a model, not to cancel
            // a chat turn — suppress the cancelled marker so the transcript
            // keeps the historical clean trim.
            stop(preservesCancelledMarker: false)
        }
    }

    /// Cancel a send that is still waiting on the pre-send warm-up handshake
    /// and invalidate its captured chat identity. Cancellation alone is not a
    /// sufficient guard because the model-switch/warm-up operation being
    /// awaited may finish normally (or ignore cooperative cancellation).
    private func invalidatePreSendHandshake() {
        preSendHandshakeEpoch &+= 1
        preSendHandshakeTask?.cancel()
        preSendHandshakeTask = nil
        guard awaitingPreSendHandshake else { return }
        awaitingPreSendHandshake = false
        rebuildVisibleBlocks()
    }

    // MARK: - Queued Send (Cursor-style interrupt UX)

    /// Capture the current `input` + `pendingAttachments` + `pendingOneOffSkillId`
    /// into a single-slot pending send and clear the input. No-op if the
    /// payload is empty. Replacing semantics: a second call while a queue
    /// is already pending overwrites it. The transcript is NOT touched at
    /// enqueue time — a text-only payload is injected as a `user` turn at
    /// the next loop iteration boundary (`injectQueuedSteerIfEligible`),
    /// while payloads carrying attachments or a one-off skill materialize
    /// when the run finishes (auto-flush) or via `sendNowInterrupting()`.
    func enqueueSend(_ text: String, attachments: [Attachment]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContent = !trimmed.isEmpty || !attachments.isEmpty
        guard hasContent else { return }
        queuedSend = QueuedSend(
            text: trimmed,
            attachments: attachments,
            oneOffSkillId: pendingOneOffSkillId
        )
        input = ""
        pendingAttachments = []
        pendingOneOffSkillId = nil
    }

    /// Drop the queued send without dispatching it.
    func cancelQueuedSend() {
        queuedSend = nil
    }

    /// Mid-run steering: dequeue an eligible queued send and append it as a
    /// persisted `user` turn so the NEXT loop iteration's request carries it
    /// — no Stop required. Called by the agent loop's `buildMessages` hook
    /// at each iteration boundary.
    ///
    /// Only text-only payloads are eligible: attachments and one-off skills
    /// need the full `send(...)` path (media gating, skill compose), so they
    /// stay queued for the run-end flush / Send Now. The injected text rides
    /// the normal outbound request pipeline, so the privacy filter scrubs it
    /// exactly like any other user message.
    @discardableResult
    func injectQueuedSteerIfEligible() -> Bool {
        guard let pending = queuedSend,
            pending.attachments.isEmpty,
            pending.oneOffSkillId == nil,
            !pending.text.isEmpty
        else { return false }
        queuedSend = nil
        let turn = ChatTurn(role: .user, content: pending.text)
        appendMidRunUserTurn(turn)
        isDirty = true
        rebuildVisibleBlocks()
        // A new user message resets the within-message dedupe/bias tracking,
        // mirroring what `send(...)` does at the top of a run.
        taskState.beginMessage()
        return true
    }

    /// Append the queued steer's user turn at an iteration boundary. The tool
    /// loop appends the NEXT iteration's
    /// empty assistant placeholder right after each tool result — before the
    /// driver's `buildMessages` hook injects the steer — so a plain
    /// `turns.append` lands the user turn after that placeholder. The model
    /// then fills the placeholder with its call and the call's result is
    /// appended after the steer, persisting `[assistant(call), user(steer),
    /// tool(result)]` for the rest of the session: the user's instruction
    /// reads as arriving after the model's own call, with the result after
    /// it, on every later iteration and turn. Insert before a trailing empty
    /// placeholder instead; the placeholder object keeps its identity so the
    /// stream still lands in it. Only the iteration-boundary steer uses this:
    /// there the trailing placeholder is guaranteed fresh (no delta has
    /// streamed into it yet). `appendInterruptMessage` stops the run right
    /// after appending and keeps its own shape.
    func appendMidRunUserTurn(_ turn: ChatTurn) {
        if let last = turns.last, Self.isEmptyAssistantPlaceholder(last) {
            turns.insert(turn, at: turns.count - 1)
        } else {
            turns.append(turn)
        }
    }

    static func isEmptyAssistantPlaceholder(_ turn: ChatTurn) -> Bool {
        turn.role == .assistant
            && turn.contentIsEmpty
            && turn.thinkingIsEmpty
            && (turn.toolCalls ?? []).isEmpty
    }

    /// Stop the currently streaming run and immediately dispatch the queued
    /// send as a fresh user turn. No-op if nothing is queued. The active
    /// run is finalized synchronously (`stop()` runs through
    /// `finalizeRun → completeRunCleanup`, flipping `isStreaming` to false)
    /// so the follow-up `send(...)` passes the `!isStreaming` guard. The
    /// stored `oneOffSkillId` is re-applied to `pendingOneOffSkillId` so
    /// the skill context attaches to the new turn.
    func sendNowInterrupting() {
        guard let pending = queuedSend else { return }
        queuedSend = nil
        if isStreaming || activeRunId != nil || preSendHandshakeTask != nil {
            stop()
        }
        if let skillId = pending.oneOffSkillId {
            pendingOneOffSkillId = skillId
        }
        send(pending.text, attachments: pending.attachments)
    }

    /// Appends a `user`-role turn carrying a plugin-supplied interrupt
    /// message. Called by `BackgroundTaskManager.interruptTask` when a
    /// plugin invokes `dispatch_interrupt(taskId, message)` with a
    /// non-empty `message`. The turn lands in the persisted transcript
    /// so the model picks it up on the next completion round.
    func appendInterruptMessage(_ message: String) {
        let turn = ChatTurn(role: .user, content: message)
        turns.append(turn)
        isDirty = true
        rebuildVisibleBlocks()
    }

    /// Append the clarify question as a visible assistant turn when the
    /// user dismisses the prompt card without answering. The card was
    /// the only readable surface for the question (the recorded tool
    /// envelope renders as collapsed chrome), so without this the
    /// question vanishes and the user is left with a silently paused
    /// agent. With the trace in the transcript they can answer from the
    /// main composer whenever they're ready.
    func appendClarifyQuestionTrace(_ payload: ClarifyPayload) {
        var text = payload.question
        if !payload.options.isEmpty {
            let bullets = payload.options.map { "- \($0)" }.joined(separator: "\n")
            text += "\n\n\(bullets)"
        }
        let turn = ChatTurn(role: .assistant, content: text)
        turns.append(turn)
        isDirty = true
        rebuildVisibleBlocks()
    }

    /// Capture a screenshot from the local `/screenshot` slash command and
    /// append it through the existing artifact-card renderer. This is a
    /// user-initiated UI action, not a model-callable tool surface.
    @MainActor
    func captureScreenshotFromSlashCommand() {
        guard !isStreaming else {
            ToastManager.shared.infoLocalized(
                "Screenshot Deferred",
                message: "Stop the current response before capturing a screenshot."
            )
            return
        }

        if sessionId == nil {
            sessionId = UUID()
            createdAt = Date()
            isDirty = true
        }
        guard let contextId = sessionId?.uuidString else {
            ToastManager.shared.errorLocalized(
                "Screenshot Failed",
                message: "No active chat session is available for storing the screenshot."
            )
            return
        }

        Task { [weak self] in
            do {
                let captured = try await ScreenshotCaptureService.shared.capture(
                    options: ScreenshotCaptureOptions(
                        contextId: contextId,
                        description: "Screenshot captured from chat"
                    )
                )
                await MainActor.run {
                    self?.appendCapturedScreenshotArtifact(captured)
                    ToastManager.shared.successLocalized(
                        "Screenshot Captured",
                        message: "Added the screenshot to this chat."
                    )
                }
            } catch let error as ScreenshotCaptureError {
                await MainActor.run {
                    self?.showScreenshotCaptureError(error)
                }
            } catch {
                await MainActor.run {
                    _ = ToastManager.shared.errorLocalized(
                        "Screenshot Failed",
                        message: "Screenshot capture failed."
                    )
                }
            }
        }
    }

    @MainActor
    private func appendCapturedScreenshotArtifact(_ captured: CapturedScreenshotArtifact) {
        let turn = ChatTurn(
            role: .assistant,
            content: "",
            sharedArtifacts: [captured.artifact]
        )
        turns.append(turn)
        isDirty = true
        rebuildVisibleBlocks()
        save()
    }

    @MainActor
    private func showScreenshotCaptureError(_ error: ScreenshotCaptureError) {
        switch error {
        case .missingScreenRecordingPermission:
            ToastManager.shared.errorLocalized(
                "Screen Recording Required",
                message: "Grant Screen Recording in macOS Privacy & Security, then retry /screenshot."
            )
        case .missingSession:
            ToastManager.shared.errorLocalized(
                "Screenshot Failed",
                message: "No active chat session is available for storing the screenshot."
            )
        case .noDisplay:
            ToastManager.shared.errorLocalized(
                "Screenshot Failed",
                message: "No capturable display is available."
            )
        case .pngEncodingFailed:
            ToastManager.shared.errorLocalized(
                "Screenshot Failed",
                message: "PNG encoding failed."
            )
        case .writeFailed:
            ToastManager.shared.errorLocalized(
                "Screenshot Failed",
                message: "The screenshot was captured but could not be written."
            )
        }
    }

    /// Clear the Privacy Filter `RedactionMap` for this conversation
    /// (and the chat-side highlight accumulator) without otherwise
    /// affecting the turn history, draft, or attachments. Useful when
    /// the user wants to "forget" a redaction without resetting the
    /// chat — the next outbound send will mint fresh placeholders
    /// for any PII it detects.
    ///
    /// Surfacing this in the UI is a future UX task; the method is
    /// public so a menu item, command-palette action, or settings
    /// shortcut can wire it up without touching the privacy
    /// internals.
    func forgetRedactionsInThisConversation() {
        sessionRedactions.removeAll()
        sessionRedactionOrder.removeAll()
        if let sid = sessionId {
            Task { await SessionRedactionStore.shared.invalidate(sid.uuidString) }
        }
    }

    func reset() {
        stop()
        turns.removeAll()
        input = ""
        pendingAttachments = []
        pendingOneOffSkillId = nil
        queuedSend = nil
        modelSwitchContinuityWarning = nil
        voiceInputState = .idle
        showVoiceOverlay = false
        transientSessionIdForCurrentRun = nil
        appendedUserTurnForCurrentRun = false
        awaitingPreSendHandshake = false
        turnsRollbackOnCancel = nil
        suppressQueuedSendFlushForCurrentRun = false
        // Clear session identity for new chat
        if let prev = sessionId {
            let key = sessionStateKey(prev)
            Task { await SessionToolStateStore.shared.invalidate(key) }
            // Drop the privacy-filter RedactionMap interned for this
            // chat so a fresh conversation starts with a clean slate.
            Task { await SessionRedactionStore.shared.invalidate(prev.uuidString) }
        }
        sessionId = nil
        title = "New Chat"
        autoTitleGenerationStarted = false
        clearFollowUpSuggestions()
        createdAt = Date()
        updatedAt = Date()
        source = .chat
        sourcePluginId = nil
        externalSessionKey = nil
        dispatchTaskId = nil
        archived = false
        pinned = false
        // Cleared like the other per-session flags; the sidebar's New Chat
        // path re-stamps the active project right after startNewChat().
        projectId = nil
        isDirty = false
        // A new chat starts folder-less; the outgoing session's folder stays
        // persisted on its own row and does not leak into the fresh one.
        folderState.clearFolder()

        // Reset agent-loop UI state.
        currentTodo = nil
        lastCompletionSummary = nil
        lastCompletionWasBlocked = false
        // A fresh chat starts uncompacted.
        compactionTask?.cancel()
        compactionTask = nil
        conversationSummary = nil
        compactionState = .idle
        showCompactionDialog = false
        resumeSendAfterCompaction = false
        skipAutoCompactionForNextSend = false
        promptQueue.drainAll()
        let oldSid = expectedTodoSessionId
        Task { await AgentTodoStore.shared.clear(for: oldSid) }
        // Keep current agentId - don't reset when creating new chat within same agent

        // Clear caches
        blockMemoizer.clear()
        cachedContext = nil
        cachedPreviewContext = nil
        // A new conversation re-freezes its screen context on the next send.
        frozenScreenContext = nil
        cachedScreenContextTokens = 0
        isScreenContextFrozen = false
        visibleBlocksStore.blocks = []
        visibleBlocksStore.groupHeaderMap = [:]

        warmupController.reset()

        applyEffectiveModel(for: agentId)
        rebuildVisibleBlocks()
    }

    /// Reset for a specific agent
    func reset(for newAgentId: UUID?) {
        // Reset under the OLD agentId so any save() triggered inside
        // stop() → completeRunCleanup() preserves the current session's
        // identity instead of stamping the new agent on it. See #1005.
        reset()
        agentId = newAgentId
        // reset() picked a model for the OLD agent; re-resolve for the
        // new one now that turns/sessionId are cleared.
        applyEffectiveModel(for: newAgentId)
        Task { [weak self] in await self?.refreshContextEstimates() }
    }

    // MARK: - LLM Context Compaction

    /// Turn IDs the active summary replaces in the outbound context.
    /// Empty when there is no summary.
    var summaryCoveredTurnIds: Set<UUID> {
        guard let summary = conversationSummary else { return [] }
        return Set(summary.coveredTurnIds)
    }

    /// Drop the summary when it no longer lines up with the live
    /// transcript (covered turns edited, regenerated, or deleted). Called
    /// on session load and at the top of every send.
    func validateConversationSummary() {
        guard let summary = conversationSummary else { return }
        if !ContextCompactionService.summaryIsValid(summary, for: turns) {
            conversationSummary = nil
        }
    }

    /// Whether the conversation currently has a span a (new) summary could
    /// cover. Gates the popover button and the auto-trigger.
    var hasCompactableConversation: Bool {
        ContextCompactionService.compactionCutIndex(
            turns: turns,
            existingSummary: conversationSummary
        ) != nil
    }

    /// Estimated fraction of the usable (effective) budget the next send
    /// occupies — the same denominator the runtime trims against.
    private var contextUsageFractionEstimate: Double? {
        guard let model = selectedModel else { return nil }
        let window = AgentLoopBudget.resolveContextWindowSync(modelId: model)
        let effective = ContextBudgetManager(contextLength: window).effectiveBudget
        guard effective > 0 else { return nil }
        let total = estimatedContextBreakdown.total
        guard total > 0 else { return nil }
        return Double(total) / Double(effective)
    }

    /// Popover-button gate: utilization crossed the manual threshold (~70%)
    /// and there's an uncovered older span a summary could reclaim.
    var canManuallyCompactConversation: Bool {
        guard hasCompactableConversation,
            let fraction = contextUsageFractionEstimate
        else { return false }
        return fraction >= ContextCompactionService.manualTriggerThreshold
    }

    /// One-shot suppression after the user dismisses the first-run dialog
    /// without picking a model: stop auto-prompting for the rest of this
    /// session (the manual popover button remains available).
    private var compactionDeclinedForSession = false

    /// Auto-trigger gate, checked at send time: the estimated next send is
    /// at ≥85% of the usable budget (the same near-limit signal that turns
    /// the context chip amber) and there is an uncovered span to summarize.
    private var shouldAutoCompactBeforeSend: Bool {
        guard !skipAutoCompactionForNextSend,
            !compactionDeclinedForSession,
            compactionState == .idle,
            hasCompactableConversation,
            let fraction = contextUsageFractionEstimate
        else { return false }
        return fraction >= 0.85
    }

    /// Manual entry point (Context Budget popover). Runs inline — progress
    /// shows in the popover — unless no model is configured yet, in which
    /// case the first-run dialog opens.
    func requestManualCompaction() {
        guard !isStreaming, !compactionState.isRunning else { return }
        beginCompaction(resumeSend: false, showDialogWhileRunning: false)
    }

    /// First-run dialog: persist the chosen model, then run.
    func chooseCompactionModelAndRun(_ identifier: String) {
        ContextCompactionService.saveConfiguredModel(identifier: identifier)
        runCompaction()
    }

    /// Retry button in the dialog / popover after a failure.
    func retryCompaction() {
        guard !compactionState.isRunning else { return }
        runCompaction()
    }

    /// Dialog dismissed. If a run is in flight it keeps going (state stays
    /// visible in the popover); a declined first-run model pick resumes any
    /// stashed send without compaction (deterministic trimming remains the
    /// safety net).
    func cancelCompactionDialog() {
        showCompactionDialog = false
        guard !compactionState.isRunning else { return }
        if case .needsModelSelection = compactionState {
            compactionState = .idle
            compactionDeclinedForSession = true
        }
        if case .failed = compactionState { compactionState = .idle }
        if resumeSendAfterCompaction {
            resumeSendAfterCompaction = false
            skipAutoCompactionForNextSend = true
            sendCurrent()
        }
    }

    private func beginCompaction(resumeSend: Bool, showDialogWhileRunning: Bool) {
        validateConversationSummary()
        resumeSendAfterCompaction = resumeSend
        guard ContextCompactionService.configuredModelIdentifier() != nil else {
            // First run: no model configured. Open the explainer dialog and
            // let the user pick one (or decline).
            compactionState = .needsModelSelection
            showCompactionDialog = true
            return
        }
        if showDialogWhileRunning { showCompactionDialog = true }
        runCompaction()
    }

    private func runCompaction() {
        guard !compactionState.isRunning else { return }
        compactionTask?.cancel()
        let turnsSnapshot = turns
        let existing = conversationSummary
        let sid = sessionId
        compactionState = .running(.preparing)
        compactionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let summary = try await ContextCompactionService.shared.summarize(
                    turns: turnsSnapshot,
                    existingSummary: existing,
                    sessionId: sid,
                    onPhase: { [weak self] phase in
                        self?.compactionState = .running(phase)
                    }
                )
                guard !Task.isCancelled else {
                    self.compactionState = .idle
                    return
                }
                // The transcript may have changed while the summarizer ran
                // (covered turn edited/regenerated/deleted). A summary that
                // no longer lines up would be dropped at the next send
                // anyway; discard it now so the budget breakdown never
                // prices a stale summary row.
                guard ContextCompactionService.summaryIsValid(summary, for: self.turns) else {
                    self.compactionState = .idle
                    return
                }
                self.conversationSummary = summary
                self.save()
                // The outbound message shape changed (covered turns replaced
                // by the summary), so the watermark's recorded decisions no
                // longer line up — its identity validation resets it on the
                // next trim, effectively rebasing at the summary boundary.
                self.rebuildVisibleBlocks()
                // Rewarm the post-compaction shape (system + summary + recent
                // turns) as required-context work: the prefill it stores (KV +
                // disk L2) is an exact prefix of the next send, which awaits
                // it in the pre-send handshake and prefix-hits instead of
                // cold-re-prefilling past the static system prefix. The warm
                // fingerprint folds in the summary identity, so the stale
                // pre-compaction warm claim can't coalesce this away.
                self.invalidateWarmupAfterContextShapeChange()
                self.compactionState = .completed(savedTokens: summary.savedTokensEstimate)
                self.finishCompaction(success: true)
            } catch let compactionError as ContextCompactionError
                where compactionError == .needsModelSelection
            {
                self.compactionState = .needsModelSelection
                self.showCompactionDialog = true
            } catch is CancellationError {
                self.compactionState = .idle
            } catch {
                guard !Task.isCancelled else {
                    self.compactionState = .idle
                    return
                }
                self.compactionState = .failed(message: error.localizedDescription)
                self.finishCompaction(success: false)
            }
        }
    }

    /// Post-run bookkeeping: resume a stashed auto-triggered send, and let
    /// transient states (completed badge) settle back to idle.
    private func finishCompaction(success: Bool) {
        let shouldResume = resumeSendAfterCompaction
        resumeSendAfterCompaction = false
        if shouldResume {
            Task { @MainActor [weak self] in
                // Let the user read the "done" state briefly before the
                // dialog closes and the send proceeds. Failures resume
                // immediately — the deterministic trimmer still protects
                // the request, and the failed state stays visible in the
                // budget popover.
                if success {
                    try? await Task.sleep(nanoseconds: 900_000_000)
                }
                guard let self else { return }
                self.showCompactionDialog = false
                self.skipAutoCompactionForNextSend = true
                self.sendCurrent()
            }
        }
        // Settle transient completed/failed badges back to idle so the
        // popover button doesn't stay stuck on an old outcome.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self else { return }
            switch self.compactionState {
            case .completed, .failed: self.compactionState = .idle
            default: break
            }
        }
    }

    /// Invalidate send-time token accounting (called when tools/skills or
    /// agent configuration change).
    ///
    /// Prompt-shape notifications need the previous preview bytes as their
    /// comparison baseline. When a settings observer clears that baseline,
    /// SwiftUI can lazily compose the new preview during the intervening
    /// redraw; the later equality detector then compares new-to-new and
    /// leaves a stale warm-prefix claim green. Observer-driven source changes
    /// therefore preserve the preview until `recomputePreviewContext()` has
    /// compared it with the newly composed bytes.
    func invalidateTokenCache(preservingPromptShapeBaseline: Bool = false) {
        cachedContext = nil
        if !preservingPromptShapeBaseline {
            cachedPreviewContext = nil
        }
        budgetTracker.clear()
        objectWillChange.send()
    }

    #if DEBUG
        /// Test seam: seed the authoritative send-time budget context,
        /// standing in for a completed send. Pairs with
        /// `resyncBudgetEstimateForTests()` to exercise the post-send
        /// invalidation path (`.agentUpdated` etc.) without running a real
        /// generation.
        func seedSendContextForTests(_ ctx: ComposedContext) {
            cachedContext = ctx
        }

        /// Test seam: stand in for the debounced budget-input signal handler
        /// (`.agentUpdated` / `.toolsListChanged` / model / folder) the running
        /// app drives via Combine. Recomposes the preview and returns whether
        /// the displayed budget shape changed.
        @discardableResult
        func resyncBudgetEstimateForTests() -> Bool {
            recomputePreviewContext()
        }

        /// Test seam for the authoritative pre-send prompt reconciliation.
        /// Unlike the 80 ms UI-estimate debounce, this runs synchronously and
        /// therefore covers a Settings Save -> immediate Send sequence.
        @discardableResult
        func reconcilePromptShapeBeforeSendForTests() -> Bool {
            reconcilePromptShapeBeforeSend()
        }

        /// Test seam: make the pre-send reconcile the ONLY consumer of a
        /// prompt-shape change by detaching the debounced budget-input
        /// pipeline and suppressing the lifecycle `refreshContextEstimates`
        /// tasks (session init/picker refresh) that are already enqueued on
        /// the main actor when the test gets control. In the running app all
        /// three consumers uphold the same contract (recompose + warm-up
        /// invalidation on a shape change); a test that pins the pre-send
        /// path must silence the other two to stay deterministic under a
        /// busy main run loop.
        func isolatePromptShapeReconcilerForTests() {
            contextEstimateCancellable = nil
            suppressLifecycleContextRefreshForTests = true
        }
    #endif

    // MARK: - Persistence Methods

    /// Convert current state to persistable data
    func toSessionData() -> ChatSessionData {
        let turnData = turns.map { ChatTurnData(from: $0) }
        return ChatSessionData(
            id: sessionId ?? UUID(),
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            selectedModel: selectedModel,
            turns: turnData,
            agentId: agentId,
            source: source,
            sourcePluginId: sourcePluginId,
            externalSessionKey: externalSessionKey,
            dispatchTaskId: dispatchTaskId,
            archived: archived,
            pinned: pinned,
            capabilities: SessionCapability.derive(from: turnData),
            folderBookmark: folderState.persistedBookmark,
            folderPath: folderState.persistedPath,
            conversationSummary: conversationSummary,
            projectId: projectId
        )
    }

    /// Save current session state
    func save() {
        // Only save if there are turns
        guard !turns.isEmpty else { return }

        // Create session ID if this is a new session
        if sessionId == nil {
            sessionId = UUID()
            createdAt = Date()
            isDirty = true
        }

        // Only update timestamp if content actually changed
        if isDirty {
            updatedAt = Date()
            isDirty = false
        }

        // Auto-generate title from first user message if still default
        if title == "New Chat" {
            let turnData = turns.map { ChatTurnData(from: $0) }
            title = ChatSessionData.generateTitle(from: turnData)
        }

        let data = toSessionData()
        // Persist off the main actor: serializing a long conversation and
        // running the DB transaction synchronously here (this runs on the main
        // actor, and `completeRunCleanup`/`stop` call it during run teardown)
        // can block the main thread past the 3s app-hang watchdog. The
        // in-memory session list is still updated synchronously inside
        // `saveAsync`, so the UI stays consistent.
        ChatSessionsManager.shared.saveAsync(data)
        onSessionChanged?()
    }

    /// Load session from persisted data
    func load(from data: ChatSessionData) {
        // Switching sessions discards the current thread's UI, so suppress the
        // outgoing-session block rebuild that `stop()` would trigger. Cleared
        // before the single rebuild for the incoming session below.
        suppressVisibleBlockRebuild = true
        stop()
        sessionId = data.id
        title = data.title
        // A session that already completed an exchange has a settled title
        // (generated or preview); only a still-empty session stays eligible.
        autoTitleGenerationStarted = data.turns.contains { $0.role == .assistant }
        // Follow-ups are transient and per-turn; a loaded session starts with
        // none (they'd re-generate only on the next clean completion).
        clearFollowUpSuggestions()
        createdAt = data.createdAt
        updatedAt = data.updatedAt
        agentId = data.agentId
        source = data.source
        sourcePluginId = data.sourcePluginId
        externalSessionKey = data.externalSessionKey
        dispatchTaskId = data.dispatchTaskId
        archived = data.archived
        pinned = data.pinned
        projectId = data.projectId

        // Restore THIS session's persisted folder (fire-and-forget: the
        // bookmark resolve + context build happen off the main actor and
        // apply when done). Sessions without a folder simply clear it.
        folderState.restore(bookmark: data.folderBookmark, path: data.folderPath)

        // Restore the persisted model when it's still valid; otherwise
        // fall back to the agent's preferred model. `isLoadingModel`
        // suppresses the auto-persist sink so a load doesn't look like
        // the user just picked a model.
        if let savedModel = data.selectedModel,
            pickerItems.contains(where: { $0.id == savedModel })
        {
            isLoadingModel = true
            selectedModel = savedModel
            loadActiveModelOptions(for: selectedModel)
            isLoadingModel = false
        } else {
            applyEffectiveModel(for: data.agentId)
        }

        turns = data.turns.map { ChatTurn(from: $0) }
        // Restore the LLM compaction summary and drop it immediately when it
        // no longer lines up with the restored transcript.
        conversationSummary = data.conversationSummary
        validateConversationSummary()
        compactionState = .idle
        showCompactionDialog = false
        resumeSendAfterCompaction = false
        skipAutoCompactionForNextSend = false
        voiceInputState = .idle
        showVoiceOverlay = false
        input = ""
        pendingAttachments = []
        pendingOneOffSkillId = nil
        queuedSend = nil
        transientSessionIdForCurrentRun = nil
        appendedUserTurnForCurrentRun = false
        awaitingPreSendHandshake = false
        turnsRollbackOnCancel = nil
        suppressQueuedSendFlushForCurrentRun = false
        isDirty = false  // Fresh load, not dirty
        // Clear caches to force a clean block rebuild for the new session
        blockMemoizer.clear()
        cachedContext = nil
        cachedPreviewContext = nil
        // A loaded conversation re-freezes its screen context on its next send.
        frozenScreenContext = nil
        cachedScreenContextTokens = 0
        isScreenContextFrozen = false
        suppressVisibleBlockRebuild = false
        rebuildVisibleBlocks()
        warmupController.reset()

        Task { [weak self] in
            await self?.refreshContextEstimates()
            self?.notifySessionBecameActive()
        }
    }

    /// Recompute the cached memory-section token estimate. Returns `true`
    /// when the value changed. Does NOT emit `objectWillChange` — the
    /// caller (`refreshContextEstimates`) coalesces preview + memory into a
    /// single notification so a budget refresh is at most one re-render.
    private func refreshMemoryTokens() async -> Bool {
        let effectiveAgentId = agentId ?? Agent.defaultId
        guard !AgentManager.shared.effectiveMemoryDisabled(for: effectiveAgentId) else {
            guard cachedMemoryTokens != 0 else { return false }
            cachedMemoryTokens = 0
            return true
        }
        let context = await MemoryContextAssembler.assembleContext(
            agentId: effectiveAgentId.uuidString,
            config: MemoryConfigurationStore.load()
        )
        let newTokens = ContextBudgetManager.estimateTokens(for: context)
        guard newTokens != cachedMemoryTokens else { return false }
        cachedMemoryTokens = newTokens
        return true
    }

    /// Recompute the cached screen-context token estimate (and, pre-send,
    /// (re)capture the frozen snapshot) so the Context Budget popover shows a
    /// "Screen Context" line that matches what the next send will inject.
    /// Returns `true` when the value changed. Mirrors `refreshMemoryTokens`:
    /// does NOT emit `objectWillChange` — the caller coalesces the refresh.
    ///
    /// Off (or nothing on screen / no Accessibility, which `captureForChat`
    /// reports as an empty render) ⇒ nothing is injected, so the estimate is
    /// zeroed and the unlocked preview block is dropped. Once the first send
    /// has locked the snapshot (`isScreenContextFrozen`), the block is kept and
    /// only its token count is reconciled.
    private func refreshScreenContextPreview() async -> Bool {
        let screenContextEnabled = AgentManager.shared
            .effectiveCapabilities(for: agentId ?? Agent.defaultId).screenContextEnabled
        guard screenContextEnabled else {
            let changed =
                cachedScreenContextTokens != 0
                || (!isScreenContextFrozen && frozenScreenContext != nil)
            cachedScreenContextTokens = 0
            if !isScreenContextFrozen { frozenScreenContext = nil }
            return changed
        }

        if isScreenContextFrozen {
            let tokens =
                frozenScreenContext.map {
                    ContextBudgetManager.estimateTokens(for: $0)
                } ?? 0
            guard tokens != cachedScreenContextTokens else { return false }
            cachedScreenContextTokens = tokens
            return true
        }

        // Pre-send: capture the current foreground snapshot. `captureForChat`
        // returns an empty render when Accessibility is missing or nothing
        // useful is on screen, which collapses to no budget line.
        let rendered = await ScreenContextDistiller.captureForChat().render()
        let block: String? = rendered.isEmpty ? nil : rendered
        let tokens = block.map { ContextBudgetManager.estimateTokens(for: $0) } ?? 0
        guard block != frozenScreenContext || tokens != cachedScreenContextTokens
        else { return false }
        frozenScreenContext = block
        cachedScreenContextTokens = tokens
        return true
    }

    /// Recompose the welcome/pre-send preview from the current agent /
    /// sandbox / tool / folder / model state, store it in
    /// `cachedPreviewContext`, and report whether the displayed budget shape
    /// changed. The shape is compared via `cacheHint` (the static-prefix hash
    /// that folds prompt sections + tool schemas) plus `toolTokens` plus the
    /// full rendered prompt bytes — the last one catches edits that only
    /// rewrite a DYNAMIC section (e.g. a channel-destination mode change),
    /// which leave `cacheHint` untouched but must still invalidate the
    /// warm-up so the send doesn't diverge against a stale warmed prefix.
    /// Consecutive previews of unchanged state are byte-identical, so a
    /// burst of redundant signals (e.g. a sandbox toggle firing both
    /// `.agentUpdated` and `.toolsListChanged`) still collapses to no
    /// re-render.
    ///
    /// The preview is recomposed even while a real send context is cached so
    /// consecutive previews stay a reliable config-change detector. That send
    /// context normally stays authoritative for the popover (see
    /// `estimatedContextBreakdown`), but once a budget input is edited — agent
    /// config / feature toggle (incl. autonomous-exec) / model / folder — it
    /// is stale for the *next* send, so we drop it and let the fresh preview
    /// drive the budget instead of pinning to the last send.
    ///
    /// No-op while streaming: `estimatedContextBreakdown` short-circuits to
    /// the live budget tracker, so leave both caches untouched (and skip the
    /// recompose) until the turn settles.
    @discardableResult
    private func recomputePreviewContext() -> Bool {
        guard !isStreaming else { return false }

        // Don't park the main thread opening the agent DB while a storage-key
        // rotation is running; the rotation-finished observer reruns this once
        // storage settles. See `previewContext()`.
        guard !StorageMutationGate.isRotationInFlight else { return false }

        let previous = cachedPreviewContext
        let preview = composePreview()
        cachedPreviewContext = preview
        let shapeChanged =
            previous?.cacheHint != preview.cacheHint
            || previous?.toolTokens != preview.toolTokens
            || previous?.prompt != preview.prompt

        // No send context yet → the preview drives the popover directly.
        guard cachedContext != nil else { return shapeChanged }

        // A real send context is authoritative until a budget input is edited.
        // Only a change between consecutive previews proves that; a nil
        // `previous` can't, so keep the send context.
        guard previous != nil, shapeChanged else { return false }
        cachedContext = nil
        return true
    }

    /// Cheap, synchronous preview-only resync: recompute the composed
    /// preview shape and emit a single `objectWillChange` when it changed.
    /// This is what the debounced budget-input pipeline drives. It must NOT
    /// touch the memory DB — memory tokens don't depend on the agent / tool /
    /// folder / model signals that feed the pipeline, and doing the
    /// `MemoryContextAssembler` read here once per signal, multiplied across
    /// open chat windows, saturated the cooperative pool (see #1324).
    @discardableResult
    private func reconcilePromptShapeBeforeSend() -> Bool {
        let hadPromptShapeBaseline = cachedPreviewContext != nil
        guard recomputePreviewContext() else { return false }

        // Nil -> first preview is initialization, not evidence that a warmed
        // prompt became stale. Treating it as a required shape rewarm moves an
        // immediate first send into an unnecessary async handshake (and delays
        // its crash-safe persistence). A real Settings/agent/tool change has
        // an established old preview — preserved by the source observers —
        // and still takes the required-rewarm path below.
        guard hadPromptShapeBaseline else {
            objectWillChange.send()
            return false
        }

        invalidateWarmupAfterContextShapeChange()
        objectWillChange.send()
        return true
    }

    private func refreshPreviewEstimate() {
        reconcilePromptShapeBeforeSend()
    }

    /// Re-resolve every input the welcome-screen preview estimate needs —
    /// including the async memory-section estimate — and emit a single
    /// `objectWillChange` when anything actually changed. Driven only by the
    /// lifecycle trigger sites (agent change, session reset, session load),
    /// where it runs at most once per transition. The high-frequency
    /// budget-input pipeline uses `refreshPreviewEstimate()` instead so it
    /// never fans the memory DB read out across every signal.
    private func refreshContextEstimates() async {
        #if DEBUG
            if suppressLifecycleContextRefreshForTests { return }
        #endif
        // Same stale-warm-claim contract as `reconcilePromptShapeBeforeSend`:
        // when this lifecycle refresh consumes an established preview baseline
        // and observes a real shape change (e.g. a Settings save that landed
        // while a storage-key rotation deferred the recompose), the previously
        // warmed prefix is stale and must be invalidated here — the pre-send
        // reconcile afterwards truthfully sees "no change" because this call
        // already advanced the baseline. Session reset/load are unaffected:
        // they clear the baseline (nil → no invalidation) and reset the
        // warmup controller themselves.
        let hadPromptShapeBaseline = cachedPreviewContext != nil
        let previewChanged = recomputePreviewContext()
        if previewChanged, hadPromptShapeBaseline {
            invalidateWarmupAfterContextShapeChange()
        }
        let memoryChanged = await refreshMemoryTokens()
        let screenChanged = await refreshScreenContextPreview()
        if previewChanged || memoryChanged || screenChanged {
            objectWillChange.send()
        }
    }

    /// Edit a user message and regenerate from that point
    func editAndRegenerate(turnId: UUID, newContent: String) {
        guard let index = turns.firstIndex(where: { $0.id == turnId }) else { return }
        guard turns[index].role == .user else { return }

        turnsRollbackOnCancel = snapshotTurnsForCancelRollback()

        // Update the content
        turns[index].content = newContent

        // Remove all turns after this one
        turns = Array(turns.prefix(index + 1))

        // Mark as dirty and save
        isDirty = true
        rebuildVisibleBlocks()
        save()
        send("")  // Empty send to trigger regeneration with existing history
    }

    /// Delete a turn and all subsequent turns
    func deleteTurn(id: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns = Array(turns.prefix(index))
        isDirty = true
        rebuildVisibleBlocks()
        save()
    }

    /// Remove a single assistant turn (and the tool turns that belong to it)
    /// while keeping every other turn in the conversation intact.
    ///
    /// Unlike `deleteTurn(id:)`, which truncates from the given turn onward,
    /// this excises just one response. When the assistant turn issued tool
    /// calls, the following `.tool` turns carrying their results are orphaned
    /// the moment the assistant message goes away — a `tool` message with no
    /// preceding `tool_calls` is an invalid request shape that providers
    /// reject — so we drop those paired result turns together. Dropping the
    /// turn from `turns` is enough for both model requests and the context
    /// token estimate to stop counting it, since both derive from `turns`.
    func removeTurn(id: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        let turn = turns[index]

        var indicesToRemove = IndexSet(integer: index)

        // Assistant turns that made tool calls own the `.tool` result turns that
        // immediately follow them; those results reference the call ids and must
        // leave with the assistant message so the remaining sequence stays valid.
        if turn.role == .assistant, let calls = turn.toolCalls, !calls.isEmpty {
            let callIds = Set(calls.map { $0.id })
            var cursor = index + 1
            while cursor < turns.count, turns[cursor].role == .tool {
                if let toolCallId = turns[cursor].toolCallId, callIds.contains(toolCallId) {
                    indicesToRemove.insert(cursor)
                }
                cursor += 1
            }
        }

        turns.remove(atOffsets: indicesToRemove)
        isDirty = true
        rebuildVisibleBlocks()
        save()
    }

    /// Remove the whole exchange an assistant turn belongs to: the user turn
    /// that prompted it plus every assistant/tool turn that answered that
    /// prompt. Deleting an assistant reply on its own strands the user message
    /// (the next request would show an unanswered question the model just
    /// re-answers), so this is the coherent "drop this Q&A and keep the rest"
    /// operation. The exchange is the contiguous run from the nearest preceding
    /// `user` turn up to (but not including) the next `user` turn, which keeps
    /// tool-call/result pairings inside the block intact.
    func removeExchange(anchoredAt id: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }

        // Walk back to the user turn that opened this exchange. If there's no
        // preceding user turn (e.g. an unprompted opening assistant message),
        // anchor the block at the turn itself.
        var start = index
        var back = index
        while back >= 0 {
            if turns[back].role == .user {
                start = back
                break
            }
            back -= 1
        }

        // Walk forward to just before the next user turn; everything in between
        // is part of answering the same prompt.
        var end = turns.count - 1
        var forward = index + 1
        while forward < turns.count {
            if turns[forward].role == .user {
                end = forward - 1
                break
            }
            forward += 1
        }

        turns.removeSubrange(start...end)
        isDirty = true
        rebuildVisibleBlocks()
        save()
    }

    /// Regenerate an assistant response (removes it and regenerates)
    func regenerate(turnId: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == turnId }) else { return }
        guard turns[index].role == .assistant else { return }

        turnsRollbackOnCancel = snapshotTurnsForCancelRollback()

        // Remove this turn and all subsequent turns
        turns = Array(turns.prefix(index))
        isDirty = true
        rebuildVisibleBlocks()

        // Regenerate
        send("")
    }

    // MARK: - Share Artifact Processing

    /// Process share_artifact tool results in chat context.
    /// Uses the shared processing pipeline to copy files, persist to DB,
    /// and enrich the result metadata for ContentBlock display.
    ///
    /// `toolResult` is the new `ToolEnvelope.success` shape whose
    /// `result.text` carries the marker-delimited artifact blob. We
    /// extract the text, run the marker pipeline, and re-wrap the
    /// enriched marker block back into a success envelope. When marker
    /// parsing or file resolution fails we surface a structured
    /// `ToolEnvelope.failure(...)` so the model is told the truth instead
    /// of seeing a bogus "success" envelope.
    private func processShareArtifactResult(
        toolResult: String,
        executionMode: ExecutionMode
    ) async -> String {
        guard let sessionId else { return toolResult }
        let agentName = SandboxAgentProvisioner.linuxName(
            for: (agentId ?? Agent.defaultId).uuidString
        )

        // Extract the marker block from the envelope. Older shapes (raw
        // marker-only string from before the envelope migration) are
        // accepted too so plugin authors who emit raw markers keep working.
        let markerText: String
        if let payload = ToolEnvelope.successPayload(toolResult) as? [String: Any],
            let text = payload["text"] as? String
        {
            markerText = text
        } else {
            markerText = toolResult
        }

        // `processToolResultDetailed` performs a `FileManager.copyItem` that can
        // recurse a large artifact directory tree and block for seconds, so resolve
        // and copy off the main actor; only the cheap envelope build runs on main.
        let contextId = sessionId.uuidString
        let outcome = await Task.detached(priority: .userInitiated) {
            SharedArtifact.processToolResultDetailed(
                markerText,
                contextId: contextId,
                contextType: .chat,
                executionMode: executionMode,
                sandboxAgentName: agentName
            )
        }.value
        switch outcome {
        case .success(let processed):
            return ToolEnvelope.success(tool: "share_artifact", text: processed.enrichedToolResult)

        case .failure(let reason):
            // Surface a model-readable error per failure mode. Without
            // this differentiation the model just retries the same path
            // (the previous "could not resolve or copy" string was the
            // same envelope for "path rejected", "file missing", and
            // "copy failed" — three very different fixes).
            return Self.shareArtifactFailureEnvelope(
                reason: reason,
                executionMode: executionMode
            )
        }
    }

    /// Drain worker-shared artifacts deposited for this session by spawned
    /// helpers (`SpawnArtifactCollector`) and attach them to the assistant
    /// turn that owns `callId` (or the latest assistant turn when the call
    /// row is unknown — the background report-back path). Runs after every
    /// spawn tool return — failure/cancel envelopes included, so artifacts a
    /// worker shared before failing still reach the user — and renders
    /// through the same `turn.sharedArtifacts` surface as generated media.
    func promoteWorkerSharedArtifacts(callId: String? = nil) async {
        guard let sid = sessionId else { return }
        // Resolve the owning turn BEFORE draining: with no assistant turn to
        // attach to (yet), the artifacts must stay in the collector for the
        // next drain point instead of being silently dropped with their
        // store files orphaned on disk.
        let callOwner = callId.flatMap { id in
            turns.last(where: { turn in
                turn.role == .assistant
                    && (turn.toolCalls?.contains { $0.id == id } ?? false)
            })
        }
        guard let owner = callOwner ?? turns.last(where: { $0.role == .assistant }) else {
            return
        }
        let artifacts = SpawnArtifactCollector.drain(sessionId: sid.uuidString)
        guard !artifacts.isEmpty else { return }
        owner.sharedArtifacts.append(contentsOf: artifacts)
        for artifact in artifacts {
            await PluginManager.shared.notifyArtifactHandlers(artifact: artifact)
        }
        isDirty = true
        rebuildVisibleBlocks()
    }

    /// Convert a successful native image tool result into the same enriched
    /// artifact envelope that `share_artifact` uses, so generated/edited images
    /// render as first-class chat cards.
    private func processNativeImageToolResult(
        toolName: String,
        toolResult: String
    ) async -> String {
        guard let sessionId else { return toolResult }
        let contextId = sessionId.uuidString
        let outcome = await Task.detached(priority: .userInitiated) {
            GeneratedMediaToolArtifactBridge.processFirstMediaArtifact(
                toolName: toolName,
                toolResult: toolResult,
                contextId: contextId,
                contextType: .chat
            )
        }.value

        guard let outcome else { return toolResult }
        switch outcome {
        case .success(let processed):
            return ToolEnvelope.success(tool: toolName, text: processed.enrichedToolResult)
        case .failure(let reason):
            NSLog(
                "[NativeImageToolArtifactBridge] artifact promotion failed for %@: %@",
                toolName,
                String(describing: reason)
            )
            return toolResult
        }
    }

    /// Translate a `SharedArtifact.ResolutionFailure` into a model-readable
    /// failure envelope. The mapping lives on `SharedArtifact` so the
    /// spawned-worker intercept (`SpawnArtifactCollector`) shares it.
    private static func shareArtifactFailureEnvelope(
        reason: SharedArtifact.ResolutionFailure,
        executionMode: ExecutionMode
    ) -> String {
        SharedArtifact.failureEnvelope(reason: reason, executionMode: executionMode)
    }

    private struct RunContext {
        let hasContent: Bool
        let userContent: String
        let memoryAgentId: String
        let memoryConversationId: String
        /// Project membership captured at send time, so memory records the
        /// project the turn actually happened in — a later session reset or
        /// agent switch can't retroactively change it.
        let memoryProjectId: UUID?
    }

    private func isRunActive(_ runId: UUID) -> Bool {
        activeRunId == runId && !Task.isCancelled
    }

    /// Push the rolling-rate's current value onto the live `ChatTurn` field
    /// at ~5Hz so the UI tok/s display ramps smoothly during streaming.
    /// Throttled because text streams can produce 100+ deltas/sec — every
    /// SwiftUI re-render of the stats cell costs an animation tick, and at
    /// full rate that swamps the MainActor on smaller responses. The
    /// chosen 0.18s cadence (~5.5Hz) matches the existing tool-arg rebuild
    /// throttle (line ~1199) for visual consistency. Skips the update when
    /// the rolling rate is still in warm-up (`currentRate` returns nil) so
    /// the cell shows nothing until the steady-state read is meaningful —
    /// avoids the prior "shows 12 tok/s for the first half-second then
    /// jumps to 60 tok/s" jitter users complained about.
    private func refreshLiveRate(
        rolling: inout RollingTokenRate,
        lastRefreshAt: inout Date,
        now: Date,
        turn: ChatTurn
    ) {
        guard now.timeIntervalSince(lastRefreshAt) >= 0.18 else { return }
        guard let rate = rolling.currentRate(at: now) else { return }
        lastRefreshAt = now
        turn.generationTokensPerSecond = rate
        // Don't bump generationTokenCount here — vmlx's authoritative count
        // arrives in the StreamingStatsHint sentinel and would be overwritten
        // by an estimate. Final stamp uses rolling.totalTokens only as a
        // last-resort fallback when the sentinel never fires.
    }

    /// Stamp an Osaurus Router billing event onto an assistant turn. Adopts the
    /// server-authoritative output-token count so the turn carries accurate
    /// stats and is preserved through run cleanup, and writes a durable,
    /// metadata-only ledger row the instant the charge lands (outcome is
    /// finalized at `completeRunCleanup`). Two-phase write = correct on crash.
    private func recordRouterBilling(_ billing: RouterBillingSummary, on turn: ChatTurn) {
        // Publish so the composer's per-session spend chip reflects this charge
        // right away, even mid-run: an agentic turn can bill several times before
        // streaming ends, and `isStreaming` flipping would otherwise be the only
        // thing that re-renders the aggregate (it sums each turn's `routerBilling`,
        // which is a plain, non-published field on ChatTurn).
        objectWillChange.send()
        turn.routerBilling = billing
        if billing.outputTokens > 0 {
            turn.generationTokenCount = billing.outputTokens
        }
        if let entryId = RouterBillingLedger.shared.record(
            summary: billing,
            sessionId: sessionId,
            turnId: turn.id,
            model: selectedModel,
            outcome: .pending
        ) {
            turn.billingEntryIds.insert(entryId)
        }
    }

    /// Classify how a completed assistant turn ultimately rendered. The same
    /// classification drives both the chat UI (keep + notice vs. trim) and the
    /// ledger's finalized outcome, so support sees exactly what the user saw.
    private func classifyBillingOutcome(for turn: ChatTurn) -> RouterBillingOutcome {
        RouterBillingOutcome.classify(
            hasVisibleText: !turn.visibleContent
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            hasToolCalls: !(turn.toolCalls?.isEmpty ?? true),
            hasReasoning: turn.hasRenderableThinking,
            wasCancelled: stopRequested,
            hadError: lastStreamError != nil
        )
    }

    /// Backfill the rendered outcome onto each billed turn's ledger rows. Called
    /// once per run at cleanup. Idempotent; reloaded turns have no transient
    /// entry ids and are skipped since their rows were finalized live.
    private func finalizeRouterBillingOutcomes() {
        for turn in turns where turn.role == .assistant {
            for entryId in turn.billingEntryIds {
                RouterBillingLedger.shared.finalizeOutcome(
                    entryId: entryId,
                    outcome: classifyBillingOutcome(for: turn)
                )
            }
        }
    }

    // MARK: - Insufficient funds + post-top-up retry

    /// When a send fails because the router account is out of credits, surface
    /// the "out of credits" modal and remember the blocked turn so a post-top-up
    /// retry can resume seamlessly. No-op for non-router sessions or unrelated
    /// errors. The bubble text is already set to the friendly copy by the caller
    /// via `ChatErrorMessages.assistantMessage`.
    private func noteInsufficientFundsIfNeeded(error: Error, blockedTurn: ChatTurn) {
        guard isOsaurusRouterSession,
            OsaurusRouter.isInsufficientFundsError(error.localizedDescription)
        else { return }
        insufficientFundsAlert = true
        insufficientFundsTurnId = blockedTurn.id
        // Establish the retry baseline from the authoritative balance: refresh
        // (no charge happened, so this reflects the true shortfall), then record
        // it so only a later top-up that raises the balance above this baseline
        // triggers the retry prompt. Left nil until the refresh lands so the
        // refresh's own balance change doesn't read as a top-up.
        balanceMicroAtInsufficientFunds = nil
        Task {
            await OsaurusRouterAccountService.shared.refreshBalance()
            self.balanceMicroAtInsufficientFunds =
                OsaurusRouterAccountService.shared.balanceMicroValue
        }
    }

    /// Offer a one-tap retry once the balance is restored after an
    /// insufficient-funds failure. Called by ChatView when the account balance
    /// changes (it auto-refreshes on app activation when returning from Stripe).
    /// Only fires while the blocked turn is still the last turn, because
    /// `regenerate` truncates everything from that turn onward and must not
    /// delete newer messages.
    func handleBalanceChangeForRetry() {
        guard let blockedId = insufficientFundsTurnId,
            let baseline = balanceMicroAtInsufficientFunds
        else { return }
        guard turns.last?.id == blockedId else {
            // The user has moved on; nothing safe to retry.
            clearInsufficientFundsRetryState()
            return
        }
        let currentMicro = OsaurusRouterAccountService.shared.balanceMicroValue
        guard currentMicro > baseline, currentMicro > 0 else { return }
        topUpRetryAlert = true
    }

    /// Retry the message that was blocked by insufficient funds by regenerating
    /// the blocked turn (a fresh run that re-bills by design). Safe-guards the
    /// truncation: only retries while the blocked turn is still last.
    func retryInsufficientFundsTurn() {
        defer { clearInsufficientFundsRetryState() }
        guard let blockedId = insufficientFundsTurnId, turns.last?.id == blockedId else { return }
        regenerate(turnId: blockedId)
    }

    /// Clear all pending insufficient-funds / retry state.
    func clearInsufficientFundsRetryState() {
        insufficientFundsTurnId = nil
        balanceMicroAtInsufficientFunds = nil
        topUpRetryAlert = false
    }

    private func trimTrailingEmptyAssistantTurn() {
        if let lastTurn = turns.last,
            lastTurn.role == .assistant,
            lastTurn.contentIsBlank,
            lastTurn.toolCalls == nil,
            !lastTurn.hasRenderableThinking,
            lastTurn.generationTokenCount == nil,
            lastTurn.generationTokensPerSecond == nil,
            // Never drop a turn the router billed — even a zero-output charge
            // must stay so the user sees the "you were charged" notice instead
            // of a silent gap.
            lastTurn.routerBilling == nil,
            // Never drop a turn that carries a terminal stop reason. A Stop
            // that lands before the first delta leaves the turn blank AND
            // stat-less, but `finalizeRun` has already stamped it
            // `cancelled` — trimming it here erased the only record that a
            // run happened at all, so the persisted session ended on the
            // user row with no assistant row (fast models hit this
            // consistently; slower ones persisted a truncated row instead,
            // purely by timing). Lifecycle stops (`stop(preservesCancelledMarker:
            // false)`) opt back into the clean trim: the user did not cancel
            // anything, so no marker row belongs in the transcript.
            lastTurn.terminalStopReason == nil || !stopPreservesCancelledMarker
        {
            turns.removeLast()
        }
        stopPreservesCancelledMarker = true
    }

    /// Whether the in-flight stop should leave a persisted `cancelled` marker
    /// when the assistant turn is otherwise empty. Set by `stop(...)`, reset
    /// after the trailing trim so a later non-stop cleanup path never
    /// inherits a lifecycle stop's suppression.
    private var stopPreservesCancelledMarker = true

    private func consolidateAssistantTurns() {
        for turn in turns where turn.role == .assistant {
            turn.consolidateContent()
        }
    }

    private func beginRun(_ runId: UUID, context: RunContext) {
        activeRunId = runId
        activeRunContext = context
    }

    /// Best-effort estimate of the execution mode the next send will use.
    /// Prefers the registry's actual registered state (matches what
    /// `prepareChatExecutionMode` would resolve) so the token-budget preview
    /// doesn't disagree with the prompt that's actually sent. Falls back to
    /// the autonomous flag when sandbox tools have not yet been registered
    /// (first send of a session before any tool call has provisioned the
    /// container). When the user has a host folder mounted but sandbox is
    /// off, that wins — folder tools must enter the schema or
    /// `excludedToolNames(.none)` will hide them entirely.
    /// Folder context to thread into an agent's execution mode. The Default
    /// (configuration) agent never works against a host folder, so it resolves
    /// to nil even when a folder is globally active — keeping the budget
    /// preview and the sent prompt folder-less and consistent.
    private func activeFolderContext(for agentId: UUID) -> FolderContext? {
        agentId == Agent.defaultId ? nil : folderState.context
    }

    /// Per-run options for the Claude Code subprocess backend.
    ///
    /// The working directory starts Claude Code in the folder the user picked
    /// for this chat. It is not an Osaurus sandbox; enabled Claude Code tools
    /// retain the macOS user's normal filesystem access. `agentId` travels
    /// with the run because the
    /// subprocess is out of process: the `@TaskLocal` chat identity cannot
    /// follow it, so the MCP bridge mints a grant naming this agent instead.
    private func claudeCodeRunOptions(for agentId: UUID) -> ClaudeCodeRunOptions {
        let config = AgentManager.shared.effectiveClaudeCodeConfig(for: agentId)
        let root = activeFolderContext(for: agentId)?.rootPath
        return ClaudeCodeRunOptions(
            mode: config.mode,
            allowWrites: config.allowWrites,
            allowShell: config.allowShell,
            allowOsaurusTools: config.allowOsaurusTools,
            allowOsaurusConfigWrites: config.allowOsaurusConfigWrites,
            osaurusCLIPath: ClaudeCodeConfiguration.embeddedCLIPath(),
            workingDirectory: root,
            agentId: agentId
        )
    }

    private func estimatedChatExecutionMode(agentId: UUID) -> ExecutionMode {
        let folder = activeFolderContext(for: agentId)
        let config = AgentManager.shared.effectiveAutonomousExec(for: agentId)
        let autonomous = config?.enabled == true
        let hostWrites = config?.allowHostFolderWrites == true
        let resolved = ToolRegistry.shared.resolveExecutionMode(
            folderContext: folder,
            autonomousEnabled: autonomous,
            allowHostFolderWrites: hostWrites
        )
        // Optimistic estimate: when autonomous is on but sandbox tools haven't
        // registered yet, report `.sandbox` so the budget preview matches what
        // the next send will most likely produce after `registerTools` runs.
        // A selected host folder is suspended while sandbox is enabled.
        if autonomous && resolved.usesSandboxTools == false {
            return .sandbox(hostRead: nil, hostWrite: false)
        }
        return resolved
    }

    private func completeRunCleanup() {
        currentTask = nil
        isStreaming = false
        // Successful run finished — drop the saved draft so a later
        // unrelated cancel doesn't accidentally repopulate the input
        // with a turn the user already sent.
        savedDraftOnCancel = nil
        transientSessionIdForCurrentRun = nil
        appendedUserTurnForCurrentRun = false
        turnsRollbackOnCancel = nil
        budgetTracker.clear()
        ServerController.signalGenerationEnd()
        // Finalize ledger outcomes before trimming so the classification sees
        // the run's turns intact (the trim guard already preserves billed ones).
        finalizeRouterBillingOutcomes()
        trimTrailingEmptyAssistantTurn()
        consolidateAssistantTurns()
        markUnfinishedToolCallsInterrupted()
        rebuildVisibleBlocks()
        save()
        maybeGenerateAutoTitle()
        maybeGenerateFollowUps()
        if !suppressQueuedSendFlushForCurrentRun {
            flushQueuedSendIfEligible()
        }
        suppressQueuedSendFlushForCurrentRun = false
        handleWarmupAfterRunCompleted(
            wasCancelled: stopRequested,
            hadError: lastStreamError != nil
        )
    }

    /// Outcome of the auto-title eligibility check for one clean run
    /// completion. Split from the side effects so the guard logic is
    /// testable without a live `ChatSession`.
    enum AutoTitleDecision: Equatable {
        /// Not eligible this time, but a later run completion may be
        /// (setting off, dirty run, no completed exchange yet).
        case skip
        /// The user renamed the chat — latch so no future run re-titles it.
        case latchAndSkip
        /// Fire a generation from the first exchange. `previewTitle` is the
        /// automatic title the generated one may replace, re-checked at
        /// apply time in case the user renames mid-generation.
        case generate(userText: String, assistantText: String, previewTitle: String)
    }

    /// Pure eligibility check for `maybeGenerateAutoTitle`. A title is only
    /// ever generated for an interactive chat's clean run completion, while
    /// the title is still automatic (the first-message preview or the
    /// untouched default — matching those is how we know the user hasn't
    /// renamed), and only once a non-empty assistant response exists.
    nonisolated static func autoTitleDecision(
        alreadyStarted: Bool,
        settingEnabled: Bool,
        runCompletedCleanly: Bool,
        isChatSource: Bool,
        currentTitle: String,
        turns: [ChatTurnData]
    ) -> AutoTitleDecision {
        guard !alreadyStarted, settingEnabled, runCompletedCleanly, isChatSource else {
            return .skip
        }
        let previewTitle = ChatSessionData.generateTitle(from: turns)
        guard currentTitle == previewTitle || currentTitle == "New Chat" else {
            return .latchAndSkip
        }
        guard
            let userTurn = turns.first(where: { $0.role == .user }),
            let assistantTurn = turns.first(where: {
                $0.role == .assistant
                    && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
        else { return .skip }
        return .generate(
            userText: userTurn.content,
            assistantText: assistantTurn.content,
            previewTitle: previewTitle
        )
    }

    /// Kick off a background AI title generation after the chat's first
    /// completed exchange, when the setting is on and the user hasn't renamed
    /// the chat. Fire-and-forget: the awaits suspend rather than block the
    /// main actor, and every failure silently keeps the preview title that
    /// `save()` already applied. `autoTitleGenerationStarted` latches per
    /// attempt — but a failed generation re-arms it, so a transient miss
    /// (timeout, background-load refusal while another model is resident,
    /// open breaker) gets one fresh attempt on each later clean completion.
    private func maybeGenerateAutoTitle() {
        guard let sid = sessionId else { return }
        let decision = Self.autoTitleDecision(
            alreadyStarted: autoTitleGenerationStarted,
            settingEnabled: AppConfiguration.shared.chatConfig.autoGenerateChatTitles,
            // A cancelled or errored run isn't a representative exchange;
            // wait for the next clean completion.
            runCompletedCleanly: !stopRequested && lastStreamError == nil,
            isChatSource: source == .chat,
            currentTitle: title,
            turns: turns.map { ChatTurnData(from: $0) }
        )
        switch decision {
        case .skip:
            return
        case .latchAndSkip:
            autoTitleGenerationStarted = true
        case .generate(let userText, let assistantText, let previewTitle):
            autoTitleGenerationStarted = true
            let fallbackModel = selectedModel
            Task { [weak self] in
                guard
                    let generated = await ChatTitleService.shared.generateTitle(
                        userMessage: userText,
                        assistantResponse: assistantText,
                        fallbackModel: fallbackModel
                    )
                else {
                    // Transient failure — re-arm for the next clean run
                    // completion, but only while this ChatSession still
                    // shows the same session; after a switch the flag
                    // belongs to the newly loaded session.
                    if let self, self.sessionId == sid {
                        self.autoTitleGenerationStarted = false
                    }
                    return
                }
                self?.applyGeneratedTitle(generated, to: sid, ifStillTitled: previewTitle)
            }
        }
    }

    /// Land a generated title, re-checking against the store first: the user
    /// may have renamed (or deleted) the chat while the model was thinking,
    /// and a manual title always wins. `renameQuietly` persists off the main
    /// thread and leaves `updatedAt` alone so the sidebar doesn't reorder.
    private func applyGeneratedTitle(_ newTitle: String, to sid: UUID, ifStillTitled expected: String) {
        guard let stored = ChatSessionsManager.shared.session(for: sid) else { return }
        guard stored.title == expected || stored.title == "New Chat" else { return }
        ChatSessionsManager.shared.renameQuietly(id: sid, title: newTitle)
        // Update the open chat's header only if it still shows this session.
        if sessionId == sid { title = newTitle }
    }

    // MARK: - Follow-Up Suggestions

    /// Clear any rendered follow-up suggestions and reset the per-turn latch.
    /// Called when a new send supersedes the previous turn and whenever the
    /// current turn is cancelled/errors before we'd want to suggest anything.
    private func clearFollowUpSuggestions() {
        followUpGenerationStarted = false
        followUpTurnId = nil
        let hadSuggestions = !followUpSuggestions.isEmpty
        if hadSuggestions { followUpSuggestions = [] }
        // Drop the injected row from the thread. Guarded by
        // `rebuildVisibleBlocks`'s own suppression during session switches.
        if hadSuggestions { rebuildVisibleBlocks() }
    }

    /// Kick off a background follow-up suggestion generation after a clean run
    /// completion, when the setting is on. Fire-and-forget: the awaits suspend
    /// rather than block the main actor, and any failure leaves no suggestions
    /// rendered. Latches per turn; a failed attempt re-arms so a later clean
    /// completion of the *same* turn (e.g. after a regeneration) may retry.
    /// Mirrors `maybeGenerateAutoTitle`'s eligibility and re-arm contract.
    private func maybeGenerateFollowUps() {
        // Follow-ups are enabled by the GLOBAL switch; each agent then shapes
        // them via its own `AgentFollowUpConfig` (prompt / rules / model).
        guard
            !followUpGenerationStarted,
            AppConfiguration.shared.chatConfig.generateFollowUpSuggestions,
            source == .chat,
            // A cancelled or errored run isn't a representative exchange.
            !stopRequested,
            lastStreamError == nil,
            let sid = sessionId
        else { return }

        // Suggest from the last user message and the assistant reply it
        // produced — the same "last exchange" the reference design keys on.
        let turnData = turns.map { ChatTurnData(from: $0) }
        guard
            let assistantTurn = turnData.last(where: {
                $0.role == .assistant
                    && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }),
            let userTurn = turnData.last(where: { $0.role == .user }),
            let liveAssistantId = turns.last(where: {
                $0.role == .assistant
                    && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })?.id
        else { return }

        followUpGenerationStarted = true
        let userText = userTurn.content
        let assistantText = assistantTurn.content
        let fallbackModel = selectedModel
        // Per-agent model override (the only follow-up config). The Default
        // agent carries none, so it falls back to `.empty` → shared core model.
        let followUpModelOverride =
            agentId.flatMap { AgentManager.shared.agent(for: $0)?.settings.followUp.modelIdentifier }
        Task { [weak self] in
            let suggestions = await FollowUpSuggestionService.shared.generateSuggestions(
                userMessage: userText,
                assistantResponse: assistantText,
                fallbackModel: fallbackModel,
                modelOverride: followUpModelOverride
            )
            guard let self, self.sessionId == sid else { return }
            guard !suggestions.isEmpty else {
                // Transient miss (no resident model, timeout, open breaker):
                // re-arm for the next clean completion of this session.
                self.followUpGenerationStarted = false
                return
            }
            // Drop the result if the conversation moved on while the model
            // was thinking — the user sent again, or the turn we keyed on is
            // no longer the last assistant message.
            let stillCurrent = self.turns.last(where: {
                $0.role == .assistant
                    && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })?.id == liveAssistantId
            guard stillCurrent else { return }
            self.followUpTurnId = liveAssistantId
            self.followUpSuggestions = suggestions
            // Inject the row into the thread (display-time), so it scrolls with
            // the assistant message rather than floating above the composer.
            self.rebuildVisibleBlocks()
        }
    }

    /// Submit a tapped follow-up suggestion as the next user turn. Clears the
    /// suggestion rows first (via `send`) so they don't linger under the older
    /// message while the new response streams.
    func sendFollowUp(_ suggestion: String) {
        let trimmed = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming, activeRunId == nil else { return }
        send(trimmed)
    }

    /// Generate an AI title on demand from the `/title` slash command. Unlike
    /// the automatic path this ignores the auto-title setting and any earlier
    /// manual rename — the user explicitly asked for a new name — and it
    /// surfaces failures as a toast instead of staying silent, because the
    /// user is waiting on the result.
    func generateTitleFromSlashCommand() {
        let turnData = turns.map { ChatTurnData(from: $0) }
        guard
            let sid = sessionId,
            let userTurn = turnData.first(where: {
                $0.role == .user
                    && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
        else {
            ToastManager.shared.infoLocalized(
                "Chat Title",
                message: "Send a message first, then use /title to name the chat."
            )
            return
        }
        let assistantText =
            turnData.first(where: {
                $0.role == .assistant
                    && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })?.content ?? ""
        // Latch so a later clean run completion doesn't auto-title over the
        // name the user just asked for.
        autoTitleGenerationStarted = true
        let fallbackModel = selectedModel
        // Loading toast while the model thinks (up to the service's 8s
        // timeout), updated in place to the success/error outcome.
        let toastId = ToastManager.shared.loadingLocalized("Generating Title…")
        Task { [weak self] in
            guard
                let generated = await ChatTitleService.shared.generateTitle(
                    userMessage: userTurn.content,
                    assistantResponse: assistantText,
                    fallbackModel: fallbackModel
                )
            else {
                ToastManager.shared.update(
                    id: toastId,
                    type: .error,
                    title: L("Chat Title"),
                    message: L("Couldn't generate a title. Check that a model is available and try again.")
                )
                return
            }
            guard let self else {
                ToastManager.shared.dismiss(id: toastId)
                return
            }
            ChatSessionsManager.shared.renameQuietly(id: sid, title: generated)
            if self.sessionId == sid { self.title = generated }
            ToastManager.shared.update(
                id: toastId,
                type: .success,
                title: L("Chat Renamed"),
                message: generated
            )
        }
    }

    /// A stopped (or errored) run can leave an assistant tool call that never
    /// received a result. Record a synthetic error result so the UI renders it
    /// as failed — red node, shimmer stopped — via the normal error path, rather
    /// than leaving it perpetually "running"; this also persists correctly so a
    /// reloaded chat shows the interrupted call as failed. No-op on a clean
    /// finish, where every issued call already has a result.
    private func markUnfinishedToolCallsInterrupted() {
        guard stopRequested || lastStreamError != nil else { return }
        for turn in turns where turn.role == .assistant {
            guard let calls = turn.toolCalls, !calls.isEmpty else { continue }
            for call in calls where turn.toolResults[call.id] == nil {
                // `setToolResult` also records the elapsed-until-stop duration.
                turn.setToolResult(
                    ToolEnvelope.failure(
                        kind: .executionError,
                        message: "Stopped before completing.",
                        tool: call.function.name
                    ),
                    for: call.id
                )
            }
        }
    }

    /// Dispatch any queued send when the run ended naturally (no `stop()`
    /// in-flight, no streaming error). Cancelled or errored runs leave the
    /// queue in place so the user can re-decide via the chip or Send Now.
    /// Called from `completeRunCleanup` after state has been finalized.
    private func flushQueuedSendIfEligible() {
        guard !stopRequested, lastStreamError == nil else { return }
        guard let pending = queuedSend else { return }
        queuedSend = nil
        if let skillId = pending.oneOffSkillId {
            pendingOneOffSkillId = skillId
        }
        send(pending.text, attachments: pending.attachments)
    }

    /// Reused across runs so we don't pay the ICU date-symbol allocation that a
    /// fresh `ISO8601DateFormatter` (or the `ISO8601DateFormatter.string` static)
    /// triggers on every finalize. The time zone is reapplied per use.
    private static let sessionDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        return formatter
    }()

    private func finalizeRun(runId: UUID?, persistConversationArtifacts: Bool) {
        guard let runId, activeRunId == runId else {
            if activeRunId == nil, isStreaming {
                completeRunCleanup()
            }
            return
        }

        let context = activeRunContext
        let runCompletedCleanly = !stopRequested && lastStreamError == nil

        // A user Stop leaves the engine reporting its own natural `stop`, so the
        // persisted turn was indistinguishable from one that finished on its own
        // — same `terminal_stop_reason`, just fewer tokens. Anything that reads
        // that field to decide "the model finished" (cache warm-ups, completed
        // transcript indexing, agent-task announcements, eval scoring) then
        // treats a cancelled turn as a complete answer. Stamp the truth on the
        // turn we already know was stopped; `runCompletedCleanly` above already
        // keeps it out of memory/indexing, this makes the record agree.
        if stopRequested, let lastAssistant = turns.lastIndex(where: { $0.role == .assistant }) {
            if turns[lastAssistant].terminalStopReason == nil
                || turns[lastAssistant].terminalStopReason == "stop"
            {
                turns[lastAssistant].terminalStopReason = "cancelled"
            }
        }

        activeRunId = nil
        activeRunContext = nil
        completeRunCleanup()

        guard persistConversationArtifacts, let context else { return }

        if runCompletedCleanly,
            let lastAssistant = turns.last(where: { $0.role == .assistant }),
            !lastAssistant.contentIsBlank || lastAssistant.hasRenderableThinking
        {
            lastCompletedAssistantTurnId = lastAssistant.id
        }

        // Keep an honest incomplete/failure fallback visible in the chat, but
        // never index it as a completed assistant answer or feed it into
        // long-term memory. The next clean turn can establish completion.
        let assistantContent =
            runCompletedCleanly
            ? turns.last(where: { $0.role == .assistant })?.content
            : nil

        let agentUUID = UUID(uuidString: context.memoryAgentId) ?? Agent.defaultId
        let memoryOff = AgentManager.shared.effectiveMemoryDisabled(for: agentUUID)
        // Every chat in a project participates in the project's shared
        // memory, even when the agent's own memory is off — memory is the
        // whole point of projects, so it's never optional (there's no
        // per-project switch, just the global memory switch, which
        // `bufferTurn` enforces). The distill path routes these turns to the
        // project namespace ONLY; transcripts below stay agent-gated, and a
        // memory-off agent never builds its own personal memory.
        let bufferForMemory = !memoryOff || context.memoryProjectId != nil

        if !memoryOff, context.hasContent, let sid = sessionId {
            let convId = sid.uuidString
            let aid = context.memoryAgentId
            let chunkIdx = turns.count
            let userChunkIndex = chunkIdx - 1
            let conversationTitle = title
            let userContent = context.userContent
            let userTokenCount = TokenEstimator.estimate(userContent)

            // Move the SQL insert + Vectura indexing off the main
            // actor. Previously `db.insertTranscriptTurn` was called
            // synchronously here (against the database's serial
            // queue), which blocked the chat view's main-thread
            // post-stream cleanup. The companion Vectura calls were
            // already detached.
            Task.detached {
                let db = MemoryDatabase.shared
                do {
                    try db.insertTranscriptTurn(
                        agentId: aid,
                        conversationId: convId,
                        chunkIndex: userChunkIndex,
                        role: "user",
                        content: userContent,
                        tokenCount: userTokenCount,
                        title: conversationTitle
                    )
                } catch {
                    MemoryLogger.database.warning("Failed to insert user transcript turn: \(error)")
                }
                let userTurn = TranscriptTurn(
                    conversationId: convId,
                    chunkIndex: userChunkIndex,
                    role: "user",
                    content: userContent,
                    tokenCount: userTokenCount,
                    agentId: aid
                )
                await MemorySearchService.shared.indexTranscriptTurn(userTurn)
            }

            if let assistantContent, !assistantContent.isEmpty {
                let assistantTokenCount = TokenEstimator.estimate(assistantContent)
                Task.detached {
                    let db = MemoryDatabase.shared
                    do {
                        try db.insertTranscriptTurn(
                            agentId: aid,
                            conversationId: convId,
                            chunkIndex: chunkIdx,
                            role: "assistant",
                            content: assistantContent,
                            tokenCount: assistantTokenCount,
                            title: conversationTitle
                        )
                    } catch {
                        MemoryLogger.database.warning("Failed to insert assistant transcript turn: \(error)")
                    }
                    let assistantTurn = TranscriptTurn(
                        conversationId: convId,
                        chunkIndex: chunkIdx,
                        role: "assistant",
                        content: assistantContent,
                        tokenCount: assistantTokenCount,
                        agentId: aid
                    )
                    await MemorySearchService.shared.indexTranscriptTurn(assistantTurn)
                }
            }
        }

        // Immediate project memory (write half): index this turn's raw
        // transcript into the project namespace right away so a fact stated
        // here is recallable across the project without waiting on the
        // background distillation. Runs for any project chat, even when the
        // agent's own memory is off — projects always share. The MemoryService
        // method stays under the global memory switch.
        if let projectId = context.memoryProjectId, context.hasContent, let sid = sessionId {
            let convId = sid.uuidString
            let chunkIdx = turns.count
            let userChunkIndex = chunkIdx - 1
            let conversationTitle = title
            let userContent = context.userContent
            let userTokenCount = TokenEstimator.estimate(userContent)
            Task.detached {
                await MemoryService.shared.mirrorTranscriptToProject(
                    projectId: projectId,
                    conversationId: convId,
                    chunkIndex: userChunkIndex,
                    role: "user",
                    content: userContent,
                    tokenCount: userTokenCount,
                    title: conversationTitle
                )
            }
            if let assistantContent, !assistantContent.isEmpty {
                let assistantTokenCount = TokenEstimator.estimate(assistantContent)
                Task.detached {
                    await MemoryService.shared.mirrorTranscriptToProject(
                        projectId: projectId,
                        conversationId: convId,
                        chunkIndex: chunkIdx,
                        role: "assistant",
                        content: assistantContent,
                        tokenCount: assistantTokenCount,
                        title: conversationTitle
                    )
                }
            }
        }

        if bufferForMemory, context.hasContent {
            let formatter = Self.sessionDateFormatter
            formatter.timeZone = .current
            let today = formatter.string(from: Date())
            Task.detached {
                await MemoryService.shared.bufferTurn(
                    userMessage: context.userContent,
                    assistantMessage: assistantContent,
                    agentId: context.memoryAgentId,
                    conversationId: context.memoryConversationId,
                    sessionDate: today,
                    projectId: context.memoryProjectId
                )
            }
        }
    }

    /// Resolve the execution mode for the next send. When sandbox is on we
    /// `await registerTools` so the registry reflects the post-provision
    /// state before `resolveExecutionMode` reads it. The single resolver on
    /// `ToolRegistry` then applies the priority rule (sandbox > folder >
    /// none) and decides whether sandbox tools actually came online.
    func prepareChatExecutionMode(agentId: UUID) async -> ExecutionMode {
        let config = AgentManager.shared.effectiveAutonomousExec(for: agentId)
        let autonomous = config?.enabled == true
        if autonomous {
            await SandboxToolRegistrar.shared.registerTools(for: agentId)
        }
        return resolveExecutionModeForSend(
            agentId: agentId,
            autonomousEnabled: autonomous,
            allowHostFolderWrites: config?.allowHostFolderWrites == true
        )
    }

    /// The pure resolution step of `prepareChatExecutionMode` (no sandbox
    /// provisioning side effects), so the dispatch-folder contract is
    /// unit-testable. A folder that a background dispatch supplied (Watcher
    /// / schedule / plugin folder_bookmark) is an explicit target with no
    /// interactive sandbox toggle, so it wins over the agent's default
    /// sandbox — otherwise the pure-VM agent can't see its own target files.
    /// Interactive folders keep sandbox priority.
    func resolveExecutionModeForSend(
        agentId: UUID,
        autonomousEnabled: Bool,
        allowHostFolderWrites: Bool = false
    ) -> ExecutionMode {
        ToolRegistry.shared.resolveExecutionMode(
            folderContext: activeFolderContext(for: agentId),
            autonomousEnabled: autonomousEnabled,
            allowHostFolderWrites: allowHostFolderWrites,
            preferHostFolder: folderContextFromDispatchBookmark
        )
    }

    /// The folder root bound as `ChatExecutionContext.currentFolderRoot` for
    /// one turn. A selected folder is suspended while VM execution is
    /// enabled — EXCEPT when a background dispatch supplied it: that folder
    /// wins over the sandbox, exactly as it does in
    /// `resolveExecutionModeForSend` (`preferHostFolder`). Without the
    /// exception the two disagree: the execution mode exposes the host file
    /// tools, but the root binding stays nil, so every folder tool returns
    /// "no working folder is selected" (the Voice Memo Watcher failure).
    /// Pure so the contract is unit-testable.
    static func turnFolderRoot(
        sandboxEnabled: Bool,
        folderFromDispatch: Bool,
        folderRoot: URL?
    ) -> URL? {
        let suspendFolderForSandbox = sandboxEnabled && !folderFromDispatch
        return suspendFolderForSandbox ? nil : folderRoot
    }

    // MARK: - Private Helpers

    /// Processes the streaming delta loop from the chat engine, updating the given
    /// assistant turn and UI state. Returns any parsed tool invocations and the
    /// final updated assistant turn.
    /// Clears the transient `pendingToolName` placeholder seeded by the
    /// tool-call-progress branch when — and only when — it is still the
    /// sentinel at stream end (i.e. no committed tool name ever overwrote it).
    /// A real tool name replaces the sentinel at `\u{FFFE}tool:`, so this is a
    /// no-op for genuine pending tool calls; it only prevents a "Preparing tool
    /// call" card from surviving on a cancelled or reclassified turn.
    private static func clearPendingToolCallProgressPlaceholder(on turn: ChatTurn) {
        if turn.pendingToolName == ToolDisplayName.pendingToolSentinel {
            turn.pendingToolName = nil
        }
    }

    private func processStreamDeltas(
        stream: AsyncThrowingStream<String, Error>,
        assistantTurn: ChatTurn,
        runId: UUID,
        streamStartTime: Date,
        ttftTrace: TTFTTrace?,
        selectedModel: String?
    ) async throws -> (invocations: [ServiceToolInvocation], finalTurn: ChatTurn) {
        var currentTurn = assistantTurn
        // A stream that arrives for an already-finalized run (Stop landed
        // while engine setup ignored cooperative cancellation) must not
        // write anything: the run's cleanup already finished, so every
        // mutation here would ghost into the transcript — starting with the
        // reset below erasing the `cancelled` stamp finalizeRun recorded.
        guard activeRunId == runId else { throw CancellationError() }
        // A continuation or transient retry may reuse this stream processor
        // after the prior assistant step set terminal metadata. Each model
        // generation owns fresh terminal state; carrying `stop` or an
        // unclosed-reasoning flag forward can falsely reclassify a valid
        // continuation as incomplete.
        currentTurn.terminalStopReason = nil
        currentTurn.unclosedReasoning = false
        currentTurn.completedAt = nil
        currentTurn.lastOutputAt = nil
        // Output-complete relay: the adapter announces the instant vmlx's
        // terminal info arrives (before the cache-store tail it withholds the
        // stream end for). Stop the cursor and stamp completion right then.
        // On every exit — clean end, cancel, tool-invocation throw, or a
        // mid-stream error — drop a tool-call-progress placeholder if it never
        // resolved to a committed tool name, so the "Preparing tool call" card
        // can't persist on the finalized turn. No-op for real pending calls
        // (the committed `\u{FFFE}tool:` name overwrites the sentinel first).
        defer { Self.clearPendingToolCallProgressPlaceholder(on: currentTurn) }
        var uiDeltaCount = 0
        var uiReasoningDeltaCount = 0
        var uiToolSentinelCount = 0
        var uiReasoningItemCount = 0
        var uiStatsHintCount = 0
        var uiBillingHintCount = 0
        var uiPrefillHintCount = 0
        var firstDeltaTime: Date?
        // Throttle key for streaming tool-call argument rebuilds.
        var lastToolArgRebuildAt: Date = .distantPast
        // Throttle key to ensure the MainActor runloop gets a turn
        // to render SwiftUI updates even if the AsyncStream buffer
        // is saturated by a fast producer.
        var lastRunloopYieldAt: Date = .distantPast

        // Rolling tok/s estimator. Replaces the previous "single-final-
        // average" pattern that produced two visible artefacts:
        //
        //   1. Short responses appeared slow because the average included
        //      first-token latency + reasoning-parser stamp resolution
        //      (model warmup costs amortised over only ~100 tokens).
        //   2. Reasoning ON vs reasoning OFF on the same model showed
        //      noticeably different numbers — same decode rate, but the
        //      reasoning preamble's higher token count diluted setup costs
        //      so the AVERAGE looked higher with thinking on.
        //
        // The rolling rate skips a brief warm-up window then reports the
        // sliding-window decode rate (steady-state). It counts content,
        // reasoning, and tool-arg tokens uniformly so the visible value is
        // invariant across {thinking on/off, tools yes/no, local/remote}.
        // See `RollingTokenRate` doc for the window-choice rationale.
        var rollingRate = RollingTokenRate()
        // The engine's own decode rate: generated tokens over the real decode
        // wall-clock, measured from the end of prefill. Used when the rolling
        // window never converges (short replies) — see the final stamp below.
        var engineTokensPerSecond: Double? = nil
        // Throttle UI updates of the live rolling rate. The stream may
        // produce 100+ deltas/sec; clamping rate refreshes to ~5Hz keeps
        // SwiftUI repaints cheap without losing visible smoothness.
        var lastRateRefreshAt: Date = .distantPast

        // Reasoning text arrives as `StreamingReasoningHint` sentinel deltas
        // emitted by `GenerationEventMapper` (local MLX) or
        // `RemoteProviderService` (remote providers). The processor's
        // `receiveReasoning` routes it into the Think panel.
        var processor = StreamingDeltaProcessor(turn: currentTurn) { [weak self] in
            self?.rebuildVisibleBlocks()
        }
        // The relay fires when the ENGINE is done; the last deltas may still
        // be in flight to this loop and the smooth-streaming pacer may still be
        // painting them (live: "…247 248 249 2" shown as complete for the
        // whole tail — the "50" was in the pacing buffer). So completion is
        // settled, not stamped: wait for a quiet window with no new delta,
        // drain the processor so every character is painted, THEN stop the
        // cursor and stamp. No engine output can follow `.info`, so the quiet
        // window only ever waits on delivery, never on generation.
        var lastDeltaAt = Date()
        let outputCompleteSub = GenerationOutputRelay.shared.$lastCompletion
            .compactMap { $0 }
            .filter { $0.at >= streamStartTime }
            .first()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak currentTurn] completion in
                guard let self else { return }
                Task { @MainActor [weak self, weak currentTurn] in
                    let quiet: TimeInterval = 0.15
                    var waited: TimeInterval = 0
                    while Date().timeIntervalSince(lastDeltaAt) < quiet, waited < 3 {
                        try? await Task.sleep(nanoseconds: 50_000_000); waited += 0.05
                    }
                    await processor.finalize()
                    guard let self, self.activeRunId == runId else { return }
                    let at = Date()
                    if let turn = currentTurn {
                        if turn.completedAt == nil { turn.completedAt = at }
                        if turn.lastOutputAt == nil { turn.lastOutputAt = at }
                    }
                    self.outputComplete = true
                    self.rebuildVisibleBlocks()
                    print("[Osaurus][UI] output complete at \(String(format: "%.2f", at.timeIntervalSince(streamStartTime)))s (engine done at \(String(format: "%.2f", completion.at.timeIntervalSince(streamStartTime)))s; run end pending on the engine tail)")
                }
            }
        defer { outputCompleteSub.cancel() }

        // The engine surfaces parsed tool calls by *throwing* a
        // `ServiceToolInvocation` (or `ServiceToolInvocations`) at end-of-
        // stream. Catch them so this function can return them as data —
        // letting the throw escape would surface as an "Error: …
        // ServiceToolInvocation error 1" string in the UI.
        var capturedInvocations: [ServiceToolInvocation] = []

        debugLog("send: got stream, entering delta loop")
        do {
            for try await delta in stream {
                noteRunProgress()
                if !isRunActive(runId) {
                    await processor.finalize()
                    // Cancelled mid-run: don't leave a remote tool chip
                    // shimmering forever — settle any still-running rows.
                    currentTurn.finalizeRemoteToolActivity()
                    return ([], currentTurn)
                }
                // Mode 2 (remote agent run): the remote device executes the
                // tools and streams back only a sanitized trace (name + phase +
                // error state — never raw args/results). Accumulate it into a
                // persistent per-turn tool-call group so the observer keeps a
                // visible record of every tool the remote agent ran
                // (running → done/failed), instead of a chip that vanished the
                // instant the tool finished. The activity is display-only and is
                // never re-sent as history (see `ChatTurn.remoteToolActivity`).
                if let trace = StreamingAgentToolHint.decode(delta) {
                    let callKey =
                        (trace.callId?.isEmpty == false) ? trace.callId! : trace.name
                    switch trace.phase {
                    case "started":
                        currentTurn.noteRemoteToolStarted(callId: callKey, name: trace.name)
                    default:
                        // "completed" (or anything terminal) stamps the result.
                        currentTurn.noteRemoteToolFinished(
                            callId: callKey,
                            name: trace.name,
                            isError: trace.isError
                        )
                    }
                    if trace.endRun {
                        currentTurn.finalizeRemoteToolActivity()
                    }
                    RemoteAgentRunLog.client(
                        "tool trace phase=\(trace.phase) "
                            + "name=\(trace.name.isEmpty ? "<unknown>" : trace.name) "
                            + "isError=\(trace.isError) endRun=\(trace.endRun)"
                    )
                    rebuildVisibleBlocks()
                    continue
                }
                // Server-side tool call complete: add the call card + result turn to the chat log
                if let done = StreamingToolHint.decodeDone(delta) {
                    uiToolSentinelCount += 1
                    await processor.finalize()
                    let call = ToolCall(
                        id: done.callId,
                        type: "function",
                        function: ToolCallFunction(name: done.name, arguments: done.arguments)
                    )
                    currentTurn.pendingToolName = nil
                    currentTurn.clearPendingToolArgs()
                    if currentTurn.toolCalls == nil { currentTurn.toolCalls = [] }
                    currentTurn.toolCalls!.append(call)
                    // Duration spans the pending-detect phase here (call + result
                    // arrive together), so the timer started when `pendingToolName` set.
                    currentTurn.markToolCallStarted(done.callId)
                    currentTurn.setToolResult(done.result, for: done.callId)
                    let toolTurn = ChatTurn(role: .tool, content: done.result)
                    toolTurn.toolCallId = done.callId
                    let newAssistantTurn = ChatTurn(role: .assistant, content: "")
                    turns.append(contentsOf: [toolTurn, newAssistantTurn])
                    currentTurn = newAssistantTurn
                    processor = StreamingDeltaProcessor(
                        turn: newAssistantTurn
                    ) { [weak self] in self?.rebuildVisibleBlocks() }
                    rebuildVisibleBlocks()
                    continue
                }
                if let toolName = StreamingToolHint.decode(delta) {
                    uiToolSentinelCount += 1
                    // Local models stream the raw envelope as args fragments
                    // BEFORE the parsed call's name hint. When the hint lands
                    // the runtime re-sends the full canonical argsJSON, so
                    // drop the envelope accumulation — the canonical args
                    // rebuild the preview without envelope wrapper noise.
                    // Remote providers send the hint before any fragment
                    // (size 0), so this is a no-op there.
                    if currentTurn.pendingToolArgSize > 0 {
                        currentTurn.clearPendingToolArgs()
                    }
                    let newName = toolName.isEmpty ? nil : toolName
                    // Only rebuild when the name actually changed. On the
                    // envelope-first flow the name was already derived
                    // mid-stream — rebuilding here (right after the args
                    // clear, right before the canonical args re-send) would
                    // blank the live diff preview for one frame.
                    let nameChanged = currentTurn.pendingToolName != newName
                    currentTurn.pendingToolName = newName
                    if nameChanged {
                        rebuildVisibleBlocks()
                    }
                    continue
                }
                // A tool call is still being generated: the model is emitting the
                // raw envelope (e.g. a large `write_file` argument) but it hasn't
                // closed yet, so the parsed name/args aren't available. Local MLX
                // buffers the whole envelope, so without this the assistant turn
                // has no visible content and no `pendingToolName`, leaving only the
                // frozen typing indicator for the entire (multi-second) write.
                // Seed a neutral in-progress tool card so the view flips from the
                // static dots to the shimmering pending-tool row; the committed
                // `StreamingToolHint.decode` above overwrites the placeholder with
                // the real tool name once the envelope closes. The raw envelope
                // text itself is intentionally NOT rendered (it isn't parsed args
                // and could be any format), so it never leaks as message text.
                if let envelopeDelta = StreamingToolCallProgressHint.decode(delta) {
                    uiToolSentinelCount += 1
                    // Also accumulate the raw envelope: the live diff preview
                    // extracts path/content from it mid-stream, and the tool
                    // NAME usually completes within the first fragments —
                    // upgrading the neutral placeholder card to the real
                    // "Writing file…" chip + growing diff card. The committed
                    // name hint clears this buffer and re-sends canonical args.
                    currentTurn.appendToolArgFragment(envelopeDelta)
                    if currentTurn.pendingToolName == nil
                        || currentTurn.pendingToolName == ToolDisplayName.pendingToolSentinel,
                        let full = currentTurn.pendingToolArgFull,
                        let name = FileDiff.partialToolName(inArgs: full)
                    {
                        currentTurn.pendingToolName = name
                    }
                    if currentTurn.pendingToolName == nil {
                        currentTurn.pendingToolName = ToolDisplayName.pendingToolSentinel
                    }
                    if currentTurn.pendingToolArgSize
                        > AgentToolLoop.maxStreamingToolArgumentCharacters
                    {
                        throw OversizedStreamingToolCall(
                            toolName: currentTurn.pendingToolName,
                            argumentCharacters: currentTurn.pendingToolArgSize
                        )
                    }
                    let count = currentTurn.pendingToolArgFragmentCount
                    let now = Date()
                    if count <= 3 || now.timeIntervalSince(lastToolArgRebuildAt) >= 0.08 {
                        lastToolArgRebuildAt = now
                        rebuildVisibleBlocks()
                    }
                    continue
                }
                // Preserve the complete provider-authored Responses output Item
                // for exact stateless replay (phase, ids, reasoning, and future
                // fields), independently of the flattened visible transcript.
                if let responseItem = StreamingResponsesOutputItemHint.decode(delta) {
                    currentTurn.responsesOutputItems.append(responseItem)
                    continue
                }
                // Captured OpenAI Responses reasoning item (id + encrypted blob).
                // Not visible text — stash it on the turn so the next request
                // re-emits it before this turn's function_call(s).
                if let reasoningItem = StreamingReasoningItemHint.decode(delta) {
                    uiReasoningItemCount += 1
                    currentTurn.reasoningItemId = reasoningItem.id
                    currentTurn.reasoningEncrypted = reasoningItem.encryptedContent
                    continue
                }
                if let argFragment = StreamingToolHint.decodeArgs(delta) {
                    uiToolSentinelCount += 1
                    currentTurn.appendToolArgFragment(argFragment)
                    // Envelope-first flow (local models): the tool name rides
                    // inside the streamed envelope, no name hint yet. Derive
                    // it as soon as the "name" field completes so the pending
                    // chip / live diff preview appear mid-generation.
                    if currentTurn.pendingToolName == nil,
                        let full = currentTurn.pendingToolArgFull,
                        let name = FileDiff.partialToolName(inArgs: full)
                    {
                        currentTurn.pendingToolName = name
                    }
                    if currentTurn.pendingToolArgSize
                        > AgentToolLoop.maxStreamingToolArgumentCharacters
                    {
                        throw OversizedStreamingToolCall(
                            toolName: currentTurn.pendingToolName,
                            argumentCharacters: currentTurn.pendingToolArgSize
                        )
                    }
                    // Always rebuild for the first few fragments so the chip
                    // appears immediately; afterwards cap at ~12 rebuilds/sec
                    // so the table stays responsive during long arg streams
                    // without hiding chunky provider deltas.
                    let count = currentTurn.pendingToolArgFragmentCount
                    let now = Date()
                    if count <= 3 || now.timeIntervalSince(lastToolArgRebuildAt) >= 0.08 {
                        lastToolArgRebuildAt = now
                        rebuildVisibleBlocks()
                    }
                } else if let stats = StreamingStatsHint.decode(delta) {
                    uiStatsHintCount += 1
                    // Final stats from vmlx — captured for the post-loop stamp.
                    // We do NOT overwrite the live rolling rate here: while the
                    // window has converged it is the better steady-state read.
                    // But we no longer THROW THIS AWAY either. It is a real
                    // measurement (tokens over the decode wall-clock, timed from
                    // the end of prefill), and it is the only honest number
                    // available for replies too short for the window to converge
                    // — the case that used to be filled in with an average over
                    // the delivery burst and render as `2397.3 tok/s • 7 tokens`.
                    if stats.tokensPerSecond.isFinite, stats.tokensPerSecond > 0 {
                        engineTokensPerSecond = stats.tokensPerSecond
                    }
                    currentTurn.generationTokenCount = stats.tokenCount
                    currentTurn.terminalStopReason = stats.stopReason
                    currentTurn.inputTokenCount = stats.inputTokenCount
                    currentTurn.cachedInputTokenCount = stats.cachedInputTokenCount
                    // Vmlx tells us the model never closed `</think>` before
                    // EOS / max_tokens. Persist on the turn so the bubble
                    // renderer can surface a one-line banner suggesting
                    // the user toggle Disable Thinking for this prompt class.
                    currentTurn.unclosedReasoning = stats.unclosedReasoning
                } else if let billing = StreamingBillingHint.decode(delta) {
                    uiBillingHintCount += 1
                    // Osaurus Router billed this turn. Stamp it so the run can't
                    // silently drop a billed-but-empty turn (see
                    // `trimTrailingEmptyAssistantTurn`) and so the bubble can
                    // explain the charge. Adopt the server-authoritative output
                    // token count over our rolling estimate.
                    recordRouterBilling(billing, on: currentTurn)
                } else if let progress = StreamingPrefillProgressHint.decode(delta) {
                    uiPrefillHintCount += 1
                    InferenceProgressManager.shared.prefillDidUpdateAsync(progress)
                } else if let reasoning = StreamingReasoningHint.decode(delta) {
                    uiReasoningDeltaCount += 1
                    let now = Date()
                    if firstDeltaTime == nil {
                        firstDeltaTime = now
                        ttftTrace?.set("first_chunk_ms", Int(now.timeIntervalSince(streamStartTime) * 1000))
                        ttftTrace?.mark("first_text_delta")
                        ttftTrace?.set("model", selectedModel ?? "unknown")
                        ttftTrace?.emit()
                    }
                    // Reasoning tokens count toward the rolling rate so
                    // thinking-ON and thinking-OFF show the same decode
                    // rate at steady state. See RollingTokenRate doc.
                    let tokens = ContextBudgetManager.estimateTokens(for: reasoning)
                    rollingRate.observe(tokens: tokens, at: now)
                    refreshLiveRate(
                        rolling: &rollingRate,
                        lastRefreshAt: &lastRateRefreshAt,
                        now: now,
                        turn: currentTurn
                    )
                    currentTurn.lastOutputAt = now
                    processor.receiveReasoning(reasoning)
                } else if !delta.isEmpty {
                    let now = Date()
                    if firstDeltaTime == nil {
                        firstDeltaTime = now
                        ttftTrace?.set("first_chunk_ms", Int(now.timeIntervalSince(streamStartTime) * 1000))
                        ttftTrace?.mark("first_text_delta")
                        ttftTrace?.set("model", selectedModel ?? "unknown")
                        ttftTrace?.emit()
                    }
                    uiDeltaCount += 1
                    lastDeltaAt = now
                    // Content delta — counted uniformly with reasoning.
                    let tokens = ContextBudgetManager.estimateTokens(for: delta)
                    rollingRate.observe(tokens: tokens, at: now)
                    refreshLiveRate(
                        rolling: &rollingRate,
                        lastRefreshAt: &lastRateRefreshAt,
                        now: now,
                        turn: currentTurn
                    )
                    currentTurn.lastOutputAt = now
                    processor.receiveDelta(delta)

                    // The model has collapsed into a phrase-repetition loop.
                    // Leaving the stream running spends the entire output
                    // budget on one repeated sentence and floods the
                    // transcript with it (osaurus#2439, turn 144: ~200 copies
                    // of "Let me continue:"). Stop consuming — the normal
                    // end-of-stream path below finalises whatever was already
                    // revealed, and the turn is classified as a loop so the
                    // driver can nudge instead of presenting it as an answer.
                    if processor.hasDetectedRepetitionLoop {
                        currentTurn.repetitionLoopPhrase =
                            processor.repeatedPhrase ?? ""
                        break
                    }
                }

                // Hand the main run loop a turn so SwiftUI can actually paint
                // any @Published mutations we just performed. Without this,
                // when many deltas land back-to-back (e.g. Venice tool args or
                // fast text streams) the consumer task monopolises the MainActor
                // and the render pass never fires — the UI appears to stall
                // mid-stream until the loop finishes. Gated to ~12 yields/sec
                // to avoid slowing down the stream with excessive 1ms sleeps.
                let now = Date()
                if now.timeIntervalSince(lastRunloopYieldAt) >= 0.08 {
                    lastRunloopYieldAt = now
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
            }
        } catch let invs as ServiceToolInvocations {
            capturedInvocations = invs.invocations
        } catch let inv as ServiceToolInvocation {
            capturedInvocations = [inv]
        }

        // Flush any remaining buffered content (including partial tags).
        // In smooth-streaming mode this awaits until the pacing tail
        // finishes typing out — keeping the processor alive past
        // `send()`'s return so the residual buffer is rendered, not
        // dropped on dealloc.
        await processor.finalize()

        // Mode 2 safety net: if the stream ended without an explicit
        // `endRun` trace (clean end, network cutoff, or a peer that doesn't
        // send one), settle any remote tool rows still marked "running" so
        // none shimmer indefinitely. No-op for non-remote turns.
        currentTurn.finalizeRemoteToolActivity()
        if currentTurn.hasRemoteToolActivity {
            RemoteAgentRunLog.client(
                "stream end remoteTools=\(currentTurn.remoteToolActivity.count) "
                    + "contentDeltas=\(uiDeltaCount) reasoningDeltas=\(uiReasoningDeltaCount) "
                    + "finalContentLen=\(currentTurn.contentLength)"
            )
        }

        if let first = firstDeltaTime {
            // Split cold model load out of TTFT.
            //
            // `streamStartTime` is stamped immediately before `streamChat`, and
            // no delta can arrive until the weights are resident — so a cold
            // container load lands inside this window and used to be reported
            // as time-to-first-token. A 64 GB M3 Max showed "TTFT 215.61s" on a
            // ~1.8k-token prompt: no machine prefills 1.8k tokens in 215s, so
            // the number was measuring a 27 GB load and reading as an engine
            // fault. Both halves are kept; neither is hidden.
            //
            // `modelLoadSeconds` is clamped to the window by the manager, so
            // the subtraction cannot go negative and cannot turn an honest
            // slow turn into a reassuring fast one.
            let wallClock = first.timeIntervalSince(streamStartTime)
            let loadSeconds = InferenceProgressManager.shared.modelLoadSeconds(
                from: streamStartTime, to: first)
            currentTurn.modelLoadSeconds = loadSeconds > 0 ? loadSeconds : nil
            currentTurn.timeToFirstToken = max(0, wallClock - loadSeconds)
            // Stamp the steady-state tok/s. Single source of truth across
            // local-MLX, remote-API, with-tools, and thinking-on/off paths.
            //
            // Order matters, and every rung is a real measurement:
            //   1. the converged rolling window — best steady-state read, and
            //      immune to first-token amortisation;
            //   2. the engine's decode rate — a true tokens-over-decode-wall
            //      figure for replies too short for the window to converge;
            //   3. nothing.
            //
            // Rung 3 is the point. There is no fourth rung that guesses. The old
            // fallback divided the token count by the span between the first and
            // last *arrival*, which for a short reply delivered in one coalesced
            // burst is a few milliseconds — hence the impossible thousands of
            // tok/s on a 7-token answer. A blank cell is honest; that number was
            // not.
            currentTurn.generationTokensPerSecond =
                rollingRate.finalRate() ?? engineTokensPerSecond
            // Token count: prefer vmlx's authoritative count (already
            // assigned in the stats sentinel branch above) — only fall back
            // to our chars/4 estimate if the stats sentinel never fired
            // (remote provider paths that don't surface vmlx stats).
            if currentTurn.generationTokenCount == nil, rollingRate.totalTokens > 0 {
                currentTurn.generationTokenCount = rollingRate.totalTokens
            }
        }
        // Stamp stream-end wall-clock for opt-in export timing. Set
        // unconditionally so cancelled and zero-token streams still get
        // a timestamp — the token count tells the consumer how much was
        // actually generated.
        let streamEndedAt = Date()
        currentTurn.completedAt = streamEndedAt

        let totalTime = streamEndedAt.timeIntervalSince(streamStartTime)
        // Last visible delta → stream termination. For local models this is
        // vmlx's post-generation cache store (the adapter holds the terminal
        // stats until the upstream drains): measured 4.3 s AR / 10–13 s
        // native-MTP on a 930-token JANG_4M answer. A tok/s derived from
        // `completedAt` silently absorbs it; this makes it visible per turn.
        let visibleTailMs =
            currentTurn.lastOutputAt.map {
                Int(max(0, streamEndedAt.timeIntervalSince($0)) * 1000)
            } ?? -1
        let uiSentinelOnlyCount =
            uiToolSentinelCount + uiReasoningItemCount + uiStatsHintCount
            + uiBillingHintCount + uiPrefillHintCount
        let uiStreamClassification =
            uiDeltaCount == 0 && uiReasoningDeltaCount == 0 && capturedInvocations.isEmpty
            ? (uiSentinelOnlyCount > 0 ? "sentinel-only" : "empty")
            : "non-empty"
        print(
            "[Osaurus][UI] Stream consumption completed: contentDeltas=\(uiDeltaCount) reasoningDeltas=\(uiReasoningDeltaCount) classification=\(uiStreamClassification) in \(String(format: "%.2f", totalTime))s, lastOutput→completion tailMs=\(visibleTailMs), final contentLen=\(currentTurn.contentLength), toolSentinels=\(uiToolSentinelCount), reasoningItems=\(uiReasoningItemCount), stats=\(uiStatsHintCount), billing=\(uiBillingHintCount), prefill=\(uiPrefillHintCount), capturedTools=\(capturedInvocations.count)"
        )

        return (capturedInvocations, currentTurn)
    }

    #if DEBUG
        /// Streams a fixed sequence of tool calls (no model) so the tool-call
        /// timeline + rail draw-in animation can be tested by just pressing enter.
        /// Each step appends a single-call assistant turn (mirroring the real
        /// agent loop's one-call-per-turn shape); consecutive turns coalesce into
        /// one timeline group, and each new call triggers the connector animation.
        @MainActor
        private func streamMockToolTimeline(runId: UUID, firstTurn: ChatTurn) async {
            func pause(_ seconds: Double) async {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }

            // Tools that render as plain timeline nodes (avoid render_chart /
            // share_artifact / agent-loop tools, which become specialised blocks).
            let steps: [(name: String, args: String, result: String)] = [
                (
                    "db_insert",
                    #"{"table":"food_log","row":{"name":"Oatmeal","calories":320}}"#,
                    #"{"ok":true,"id":1}"#
                ),
                (
                    "db_insert",
                    #"{"table":"food_log","row":{"name":"Black coffee","calories":5}}"#,
                    #"{"ok":true,"id":2}"#
                ),
                (
                    "db_query",
                    #"{"sql":"SELECT SUM(calories) AS total FROM food_log"}"#,
                    #"{"total":325}"#
                ),
                ("file_read", #"{"path":"notes/diet.md"}"#, #"{"bytes":1840}"#),
                ("search_memory", #"{"query":"calorie target"}"#, #"{"hits":2}"#),
            ]

            // Longer thinking pass (lorem ipsum) so the thinking block can be
            // exercised at a realistic length.
            let mockThinking = """
                Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod \
                tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, \
                quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo \
                consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse \
                cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non \
                proident, sunt in culpa qui officia deserunt mollit anim id est laborum.
                """
            for ch in mockThinking {
                guard isRunActive(runId) else { return }
                firstTurn.appendThinkingAndNotify(String(ch))
                rebuildVisibleBlocks()
                await pause(0.006)
            }
            await pause(0.3)

            for (i, step) in steps.enumerated() {
                guard isRunActive(runId) else { return }
                // First call reuses the leading assistant turn; the rest get their own.
                let turn = i == 0 ? firstTurn : ChatTurn(role: .assistant, content: "")
                if i != 0 { turns.append(turn) }

                let callId = "mock-\(runId.uuidString.prefix(6))-\(i)"
                turn.toolCalls = [
                    ToolCall(
                        id: callId,
                        type: "function",
                        function: ToolCallFunction(name: step.name, arguments: step.args)
                    )
                ]
                turn.markToolCallStarted(callId)
                rebuildVisibleBlocks()  // running (shimmer) + connector draws in for calls 2+
                await pause(0.9)

                // `isRunActive` is false once stopped (it checks Task.isCancelled),
                // so the in-flight call is left without a result — completeRunCleanup()
                // then marks it interrupted (red node, shimmer stopped).
                guard isRunActive(runId) else { return }
                turn.setToolResult(step.result, for: callId)
                turn.notifyContentChanged()
                rebuildVisibleBlocks()  // node completes → past-tense title
                await pause(0.5)
            }

            // Final assistant text turn, with stats so the footer appears once.
            guard isRunActive(runId) else { return }
            let finalTurn = ChatTurn(role: .assistant, content: "")
            turns.append(finalTurn)
            for ch in "Logged 2 items — your total so far is 325 calories." {
                guard isRunActive(runId) else { return }
                finalTurn.appendContentAndNotify(String(ch))
                rebuildVisibleBlocks()
                await pause(0.015)
            }
            finalTurn.completedAt = Date()
            finalTurn.timeToFirstToken = 0.12
            finalTurn.generationTokensPerSecond = 92
            finalTurn.generationTokenCount = 64
            rebuildVisibleBlocks()
        }
    #endif

    /// True when `id` names an on-device image-generation model in the picker
    /// catalog. Drives the image-vs-LLM branch in `send`.
    func isImageGenerationModel(_ id: String?) -> Bool {
        #if DEBUG
            if forceChatEngineRouteForTests { return false }
        #endif
        guard let id, !id.isEmpty else { return false }
        return ModelPickerItemCache.shared.items.contains {
            $0.id == id && ($0.source.isImageGeneration || $0.mediaModel?.kind == .image)
        }
    }

    func isVideoGenerationModel(_ id: String?) -> Bool {
        #if DEBUG
            if forceChatEngineRouteForTests { return false }
        #endif
        guard let id, !id.isEmpty else { return false }
        return ModelPickerItemCache.shared.items.contains {
            $0.id == id && $0.mediaModel?.kind.isVideo == true
        }
    }

    /// Run a text→image generation for the active image model, streaming
    /// progress into `turn` and rendering the final PNG as a markdown image
    /// (the existing assistant markdown renderer displays `file://` images).
    /// Honors the run lifecycle: cancelling `currentTask` cancels the consume
    /// loop, which soft-cancels the underlying job.
    func runImageGeneration(
        prompt: String,
        attachments: [Attachment],
        settings: ImageComposerSettings,
        into turn: ChatTurn,
        runId: UUID
    ) async {
        guard let model = selectedModel, !model.isEmpty else {
            turn.content = L("Image generation failed: no model selected")
            rebuildVisibleBlocks()
            return
        }
        guard !prompt.isEmpty else {
            turn.content = L("Enter a prompt to generate an image.")
            rebuildVisibleBlocks()
            return
        }
        guard let imageItem = selectedImagePickerItem else {
            turn.content = L("Image generation failed: selected model is not an image model.")
            rebuildVisibleBlocks()
            return
        }
        if let mediaModel = imageItem.mediaModel {
            await runRemoteImageGeneration(
                prompt: prompt,
                attachments: attachments,
                settings: settings,
                model: mediaModel,
                into: turn,
                runId: runId
            )
            return
        }

        turn.content = L("Generating image…")
        rebuildVisibleBlocks()

        var lastRebuild = Date.distantPast
        func refresh(force: Bool = false) {
            let now = Date()
            if force || now.timeIntervalSince(lastRebuild) >= 0.1 {
                lastRebuild = now
                rebuildVisibleBlocks()
            }
        }

        var reachedTerminal = false
        let sourceImages = attachments.loadImages()
        let stream: AsyncThrowingStream<ImageGenerationEvent, Error>
        if imageItem.imageCapabilities?.imageEdit == true || imageItem.imageKind == "imageEdit" {
            guard !sourceImages.isEmpty else {
                turn.content = L("Attach one source image to edit with this model.")
                rebuildVisibleBlocks()
                return
            }
            let params = ImageEditParameters(
                model: model,
                prompt: prompt,
                sourceImages: sourceImages,
                negativePrompt: settings.normalizedNegativePrompt,
                strength: settings.clampedStrength,
                width: settings.clampedWidth,
                height: settings.clampedHeight,
                steps: settings.clampedSteps,
                guidance: settings.clampedGuidance,
                seed: settings.normalizedSeed
            )
            stream = await ImageGenerationService.shared.edit(params, jobID: runId.uuidString)
        } else {
            guard sourceImages.isEmpty else {
                turn.content = L("Selected image model does not accept source images.")
                rebuildVisibleBlocks()
                return
            }
            let params = ImageGenerationParameters(
                model: model,
                prompt: prompt,
                negativePrompt: settings.normalizedNegativePrompt,
                width: settings.clampedWidth,
                height: settings.clampedHeight,
                steps: settings.clampedSteps,
                guidance: settings.clampedGuidance,
                seed: settings.normalizedSeed,
                numImages: 1,
                outputFormat: .png
            )
            stream = await ImageGenerationService.shared.generate(params, jobID: runId.uuidString)
        }
        do {
            for try await event in stream {
                noteRunProgress()
                guard isRunActive(runId) else { break }
                switch event {
                case .loadingModel:
                    turn.content = L("Loading image model…")
                    refresh()
                case .step(let step, let total, _):
                    turn.content = "\(L("Generating image…")) \(step)/\(total)"
                    refresh()
                case .preview:
                    break
                case .completed(let images):
                    reachedTerminal = true
                    if images.isEmpty {
                        turn.content = L("Image generation produced no image.")
                    } else {
                        turn.content =
                            images
                            .map { "![\(prompt)](\($0.url.absoluteString))" }
                            .joined(separator: "\n\n")
                    }
                    refresh(force: true)
                case .failed(let message, _):
                    reachedTerminal = true
                    turn.content = "\(L("Image generation failed:")) \(message)"
                    refresh(force: true)
                case .cancelled:
                    if !reachedTerminal {
                        reachedTerminal = true
                        turn.content = L("Image generation cancelled.")
                    }
                    refresh(force: true)
                }
            }
        } catch {
            if !reachedTerminal {
                turn.content = "\(L("Image generation failed:")) \(error)"
                refresh(force: true)
            }
        }
        isDirty = true
    }

    private func runRemoteImageGeneration(
        prompt: String,
        attachments: [Attachment],
        settings: ImageComposerSettings,
        model: MediaModelInfo,
        into turn: ChatTurn,
        runId: UUID
    ) async {
        guard attachments.loadImages().isEmpty else {
            turn.content = L("Remote image editing is not supported yet. Remove the source image.")
            rebuildVisibleBlocks()
            return
        }
        if let limit = model.constraints.promptCharacterLimit, prompt.count > limit {
            turn.content = String(format: L("The image prompt exceeds this model's %d character limit."), limit)
            rebuildVisibleBlocks()
            return
        }

        turn.content = L("Generating image…")
        rebuildVisibleBlocks()
        let usesCatalogSize =
            !model.constraints.aspectRatios.isEmpty || !model.constraints.resolutions.isEmpty
        let request = MediaImageGenerationRequest(
            target: model.target,
            prompt: prompt,
            negativePrompt: settings.normalizedNegativePrompt,
            width: usesCatalogSize ? nil : settings.clampedWidth,
            height: usesCatalogSize ? nil : settings.clampedHeight,
            aspectRatio: settings.aspectRatio,
            resolution: settings.resolution,
            quality: settings.quality,
            steps: model.constraints.defaultSteps == nil ? nil : settings.clampedSteps,
            guidance: Double(settings.clampedGuidance),
            seed: settings.normalizedSeed.flatMap(Int.init(exactly:)),
            count: settings.clampedImageCount,
            format: settings.effectiveOutputFormat
        )
        do {
            var approvalValues: [String: Any] = [
                "prompt": prompt,
                "resolved_model": model.displayName,
                "backend": Self.mediaBackendDescription(model),
                "billing_notice": "Approving starts a billable remote image generation.",
            ]
            if let privacy = model.privacy {
                approvalValues["privacy"] = privacy
            }
            if let minimum = model.pricing?.minimumUSD {
                approvalValues["estimated_minimum_usd"] = minimum
            }
            approvalValues["aspect_ratio"] = settings.aspectRatio
            approvalValues["resolution"] = settings.resolution
            approvalValues["quality"] = settings.quality
            let approved = await ToolPermissionPromptService.requestApproval(
                toolName: "image",
                description:
                    "Generate a billable remote image. Review the provider, privacy policy, "
                    + "estimated minimum price, and selected options.",
                argumentsJSON: SubagentApprovalArguments.enrichedJSON(
                    from: "{}",
                    values: approvalValues
                )
            )
            guard approved else {
                turn.content = L("Remote image generation cancelled before billing.")
                rebuildVisibleBlocks()
                return
            }
            let generated = try await MediaGenerationCoordinator.shared.generateImage(request)
            guard !generated.isEmpty else {
                throw MediaGenerationError.invalidResponse
            }
            guard isRunActive(runId) else { return }
            for media in generated {
                attachGeneratedMedia(media, prompt: prompt, to: turn)
            }
            if generated.count > 1 {
                let cost = generated.compactMap(\.settledCostUSD).first
                turn.content = "\(L("Generated images")): \(generated.count)"
                if let cost {
                    turn.content += " · \(OsaurusRouter.formatUSDAsCredits(cost))"
                }
            }
        } catch is CancellationError {
            turn.content = L("Image generation cancelled.")
        } catch {
            debugLog(
                "[MediaGeneration] image generation failed "
                    + "backend=\(model.target.backend) model=\(model.target.modelID) "
                    + "error=\(String(reflecting: error))"
            )
            turn.content = "\(L("Image generation failed:")) \(error.localizedDescription)"
        }
        isDirty = true
        rebuildVisibleBlocks()
    }

    private static func mediaBackendDescription(_ model: MediaModelInfo) -> String {
        switch model.target.backend {
        case .local:
            return "Local"
        case .remoteProvider:
            return model.providerName
        case .osaurusCloud:
            return "Osaurus Cloud"
        }
    }

    func runVideoGeneration(
        prompt: String,
        attachments: [Attachment],
        settings: ImageComposerSettings,
        into turn: ChatTurn,
        runId: UUID
    ) async {
        guard let model = selectedVideoPickerItem?.mediaModel else {
            turn.content = L("Video generation failed: selected model is unavailable.")
            rebuildVisibleBlocks()
            return
        }
        let sourceImages = attachments.loadImages()
        switch model.kind {
        case .imageToVideo:
            guard sourceImages.count == 1, sourceImages.count == attachments.count else {
                turn.content = L("Attach exactly one source image for image-to-video generation.")
                rebuildVisibleBlocks()
                return
            }
        case .textToVideo:
            guard attachments.isEmpty else {
                turn.content = L("This text-to-video model does not accept attachments.")
                rebuildVisibleBlocks()
                return
            }
        case .image:
            turn.content = L("The selected model is not a video model.")
            rebuildVisibleBlocks()
            return
        }
        guard let duration = settings.duration ?? model.constraints.durations.first else {
            turn.content = L("The selected video model does not advertise a duration.")
            rebuildVisibleBlocks()
            return
        }
        if let limit = model.constraints.promptCharacterLimit, prompt.count > limit {
            turn.content = String(format: L("The video prompt exceeds this model's %d character limit."), limit)
            rebuildVisibleBlocks()
            return
        }

        let request = MediaVideoGenerationRequest(
            target: model.target,
            prompt: prompt,
            negativePrompt: settings.normalizedNegativePrompt,
            sourceImage: sourceImages.first,
            sourceImageMIMEType: sourceImages.isEmpty ? nil : "image/png",
            duration: duration,
            aspectRatio: settings.aspectRatio,
            resolution: settings.resolution,
            audio: model.constraints.audioConfigurable ? settings.audio : nil
        )

        do {
            turn.content = L("Getting video quote…")
            rebuildVisibleBlocks()
            let quote = try await MediaGenerationCoordinator.shared.quoteVideo(request)
            var approvalValues: [String: Any] = [
                "prompt": prompt,
                "resolved_model": model.displayName,
                "duration": duration,
                "quote_usd": quote.usd,
                "billing_notice": "Approving queues a billable remote job that cannot be cancelled upstream.",
            ]
            approvalValues["resolution"] = settings.resolution
            approvalValues["aspect_ratio"] = settings.aspectRatio
            approvalValues["audio"] = settings.audio
            let approvalJSON = SubagentApprovalArguments.enrichedJSON(
                from: "{}",
                values: approvalValues
            )
            let approved = await ToolPermissionPromptService.requestApproval(
                toolName: "video",
                description: VideoTool.toolDescription,
                argumentsJSON: approvalJSON
            )
            guard approved else {
                turn.content = L("Video generation cancelled before queueing.")
                rebuildVisibleBlocks()
                return
            }

            turn.content = String(
                format: L("Queueing video (quoted %@)…"),
                OsaurusRouter.formatUSDAsCredits(quote.usd)
            )
            rebuildVisibleBlocks()
            let turnID = turn.id
            let media = try await MediaGenerationCoordinator.shared.generateVideo(
                request,
                approvedQuote: quote
            ) { [weak self] event in
                Task { @MainActor in
                    guard
                        let self,
                        let turn = self.turns.first(where: { $0.id == turnID }),
                        self.isRunActive(runId)
                    else { return }
                    switch event {
                    case .queued(let jobID):
                        turn.content = jobID.map { "Video queued (\($0))…" } ?? L("Video queued…")
                    case .running(let progress, let eta):
                        let percent = progress.map { " \(Int($0 * 100))%" } ?? ""
                        let estimate = eta.map { " · ~\(Int($0))s remaining" } ?? ""
                        turn.content = "Generating video…\(percent)\(estimate)"
                    case .completed:
                        break
                    case .failed(let message):
                        turn.content = "\(L("Video generation failed:")) \(message)"
                    case .cancelled:
                        turn.content = L("Video generation cancelled.")
                    }
                    self.rebuildVisibleBlocks()
                }
            }
            guard isRunActive(runId) else { return }
            attachGeneratedMedia(media, prompt: prompt, to: turn)
        } catch let error as MediaGenerationError {
            turn.content =
                error.errorDescription
                ?? L("Video generation failed.")
        } catch is CancellationError {
            turn.content = L("Video generation cancelled.")
        } catch {
            turn.content = "\(L("Video generation failed:")) \(error.localizedDescription)"
        }
        isDirty = true
        rebuildVisibleBlocks()
    }

    private func attachGeneratedMedia(_ media: GeneratedMedia, prompt: String, to turn: ChatTurn) {
        guard let contextID = sessionId?.uuidString else {
            turn.content = media.url.absoluteString
            return
        }
        switch SharedArtifact.processTrustedLocalFileResult(
            fileURL: media.url,
            filename: media.url.lastPathComponent,
            mimeType: media.mimeType,
            description: prompt,
            contextId: contextID,
            contextType: .chat
        ) {
        case .success(let processed):
            turn.sharedArtifacts.append(processed.artifact)
            let label = media.kind.isVideo ? L("Generated video") : L("Generated image")
            if let cost = media.settledCostUSD {
                turn.content = "\(label) · \(OsaurusRouter.formatUSDAsCredits(cost))"
            } else {
                turn.content = label
            }
        case .failure(let failure):
            turn.content = "\(L("Generated media could not be displayed:")) \(failure)"
        }
    }

    /// Freeze this run's memory + screen-context blocks onto the latest user
    /// turn, once, at send time. From then on `turnToMessage` replays the
    /// prefix verbatim on every request, so the turn's wire bytes are
    /// byte-identical across loop iterations AND across later turns — the
    /// paged KV cache reuses the whole prior exchange instead of
    /// re-prefilling it (the prefix used to vanish from history the moment
    /// the next turn became "latest"). Mirrors how `frozenManifest` /
    /// `frozenSoul` freeze the static prompt side.
    private func freezeInjectedContextOntoLatestUserTurn(
        memorySection: String?,
        screenContext: String?,
        automationContext: String?
    ) {
        guard let turn = turns.last(where: { $0.role == .user }) else { return }
        // Regeneration re-runs an already-sent turn: keep the original
        // bytes. The KV prefix through this turn is still valid, and the
        // model already read the original memory block — fresher recall is
        // not worth rewriting sent history.
        guard turn.injectedContextPrefix == nil else { return }
        // Parity with the legacy injector guard: a turn that renders as a
        // multimodal parts message never carries an injected prefix.
        if !turn.attachments.isEmpty {
            let rendered = Self.buildUserChatMessage(
                content: turn.content,
                attachments: turn.attachments,
                supportsImages: selectedModelSupportsImages,
                supportsAudio: selectedModelSupportsAudio,
                supportsVideo: selectedModelSupportsVideo
            )
            if rendered.contentParts != nil { return }
        }
        guard
            let prefix = SystemPromptComposer.composeInjectedUserPrefix(
                memorySection: memorySection,
                screenContext: screenContext,
                automationContext: automationContext,
                timeContext: SystemPromptTemplates.timeContext(now: Date(), timeZone: .current)
            )
        else { return }
        turn.injectedContextPrefix = prefix
        isDirty = true
    }

    func send(_ text: String, attachments: [Attachment] = []) {
        // The user's clock starts here, not when generation does. Everything
        // below — the warm-up handshake especially, which can wait out a whole
        // container load — happens before there is a trace to record it, so the
        // reported TTFT excluded it and the wait was unattributable. See #2347.
        let sendRequestedAt = Date()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContent = !trimmed.isEmpty || !attachments.isEmpty
        let isRegeneration = !hasContent && !turns.isEmpty
        guard hasContent || isRegeneration else { return }
        // `isStreaming` does not flip until the pre-send handshake finishes.
        // Treat the retained handshake as an active send so a second Send
        // cannot queue another captured turn into the same lifecycle gap.
        guard preSendHandshakeTask == nil else {
            restoreTurnsRollbackAfterAbortedRegeneration()
            return
        }
        guard activeRunId == nil, !isStreaming else {
            restoreTurnsRollbackAfterAbortedRegeneration()
            return
        }

        // Authoritative guard for every send path (interactive, regeneration,
        // queued, VAD, programmatic): never start a local generation while
        // another window is already running one. `sendCurrent` checks this
        // first so the draft survives; this backstops the rest. Delegated
        // child sessions are exempt (see `refusesLocalBusySend`).
        if refusesLocalBusySend {
            windowState?.showLocalModelBusyAlert = true
            restoreTurnsRollbackAfterAbortedRegeneration()
            return
        }

        // A new send supersedes the previous turn's follow-up suggestions:
        // clear them so stale rows never linger beneath an older message while
        // the next response streams in.
        clearFollowUpSuggestions()

        // The LLM compaction summary must line up with the transcript this
        // send will build from; regenerations/edits that rewrote covered
        // turns invalidate it here (mirrors `CompactionWatermark.validate`).
        validateConversationSummary()

        // Settings notifications intentionally debounce preview work by 80 ms
        // to coalesce UI churn. A user can still click Send inside that
        // window. Recompose from the authoritative stores *before* deciding
        // whether a warm-up handshake is needed; if the rendered bytes
        // changed, this synchronously invalidates the stale green claim and
        // creates required rewarm work that the send below must await.
        //
        // This is an equality-guarded source reconciliation, not a blind
        // delay. The later debounced notification observes the same bytes and
        // becomes a no-op.
        reconcilePromptShapeBeforeSend()

        // DSV4 must not use the first visible response as its MLX/JIT warm-up.
        // Promote a missing family warm-up to required handshake work before
        // the generic scheduled-warm-up cancellation below.  The required
        // task survives that cancellation and is awaited by the normal send
        // lifecycle; every other model keeps the existing fast path.
        warmupController.requireDSV4PreSendWarmupIfNeeded(session: self)

        // A scheduled-but-not-started warm-up must not fire mid-run.
        warmupController.cancelScheduledWarmup()

        // Common case: nothing pending — dispatch synchronously so the user
        // turn is appended inside send() (callers and tests rely on this).
        // Only a model switch still settling or an in-flight warm-up
        // generation requires the async handshake first.
        guard warmupController.needsPreSendHandshake else {
            dispatchSend(
                trimmed: trimmed,
                attachments: attachments,
                hasContent: hasContent,
                sendRequestedAt: sendRequestedAt
            )
            return
        }

        // The handshake can wait out an entire model load (the in-flight
        // warm-up generation loads the container first), so the user's
        // message must appear NOW — not when the model finishes loading.
        // Append the turn eagerly; dispatchSend skips the append, and the
        // post-handshake guards roll it back if the dispatch aborts.
        var preAppendedUserTurn: ChatTurn?
        var preAppendIntroducedFirstTurn = false
        if hasContent {
            preAppendIntroducedFirstTurn = turns.isEmpty
            let turn = ChatTurn(role: .user, content: trimmed, attachments: attachments)
            turns.append(turn)
            preAppendedUserTurn = turn
        }
        // Show the typing-indicator row (which surfaces "Loading Model..." /
        // prefill progress) while the send waits on the warm-up, so the wait
        // isn't a silent gap between the user's message and the run starting.
        awaitingPreSendHandshake = true
        rebuildVisibleBlocks()

        let handshakeEpoch = preSendHandshakeEpoch
        let controller = warmupController
        preSendHandshakeTask = Task { @MainActor [weak self] in
            // Capture the controller rather than `self` across the await so
            // this retained task cannot keep a torn-down ChatSession alive.
            let warmupHandshakeCompleted = await Self.prepareForSendWarmup(using: controller)
            guard
                warmupHandshakeCompleted,
                let self,
                !Task.isCancelled,
                self.preSendHandshakeEpoch == handshakeEpoch
            else { return }

            self.preSendHandshakeTask = nil
            self.awaitingPreSendHandshake = false
            self.dispatchSend(
                trimmed: trimmed,
                attachments: attachments,
                hasContent: hasContent,
                preAppendedUserTurn: preAppendedUserTurn,
                preAppendIntroducedFirstTurn: preAppendIntroducedFirstTurn,
                expectedPreSendHandshakeEpoch: handshakeEpoch,
                sendRequestedAt: sendRequestedAt,
                awaitedPreSendHandshake: true
            )
        }
    }

    /// Continuation of `send(_:attachments:)` after the pre-send warm-up
    /// handshake. Re-checks the run/busy guards because the handshake
    /// yielded the MainActor.
    private func dispatchSend(
        trimmed: String,
        attachments: [Attachment],
        hasContent: Bool,
        preAppendedUserTurn: ChatTurn? = nil,
        preAppendIntroducedFirstTurn: Bool = false,
        expectedPreSendHandshakeEpoch: UInt64? = nil,
        sendRequestedAt: Date = Date(),
        awaitedPreSendHandshake: Bool = false
    ) {
        // The pre-send task already checks this after its await. Keep the same
        // guard at the dispatch boundary so future refactors cannot restore
        // the old behavior where a reset transcript caused the captured turn
        // to be re-appended and launched in the new chat.
        if let expectedPreSendHandshakeEpoch,
            expectedPreSendHandshakeEpoch != preSendHandshakeEpoch
        {
            return
        }
        guard activeRunId == nil, !isStreaming else {
            rollbackPreAppendedUserTurn(
                preAppendedUserTurn,
                restoringDraft: (trimmed, attachments)
            )
            restoreTurnsRollbackAfterAbortedRegeneration()
            return
        }
        if refusesLocalBusySend {
            windowState?.showLocalModelBusyAlert = true
            // `sendCurrent` already cleared the composer, and the warm-up
            // await above widened the window in which another window can
            // grab the runtime. Put the draft back instead of dropping it.
            rollbackPreAppendedUserTurn(preAppendedUserTurn, restoringDraft: nil)
            if hasContent, input.isEmpty, pendingAttachments.isEmpty {
                input = trimmed
                pendingAttachments = attachments
            }
            restoreTurnsRollbackAfterAbortedRegeneration()
            return
        }
        if hasContent {
            turnsRollbackOnCancel = nil
        }

        // Fresh run: a previous stop() may have left the flag true. The
        // auto-flush in completeRunCleanup keys off this, so clear it
        // before the new run can finalize.
        stopRequested = false
        transientSessionIdForCurrentRun = nil
        appendedUserTurnForCurrentRun = false
        suppressQueuedSendFlushForCurrentRun = false

        // Any new user input clears a prior completion banner — we're
        // moving on to a follow-up. Clarify prompts (when active) live
        // in the bottom-pinned overlay with their own embedded input;
        // the main input bar is dimmed while a prompt is mounted, so
        // the user can't normally reach this path with a clarify
        // pending. The `drainAll()` here is defensive: if a prompt is
        // somehow still queued, dismiss it before sending so the new
        // turn doesn't race a stale overlay resolution.
        lastCompletionSummary = nil
        lastCompletionWasBlocked = false
        if promptQueue.current != nil {
            promptQueue.drainAll()
        }
        // Resume from any prior clarify pause BEFORE the new run starts so
        // the BTM streaming-state sink sees `.waitingForInput`
        // cleared and the next streaming tick transitions the task back
        // to `.running` cleanly. Redundant nil → nil writes are
        // collapsed downstream by `removeDuplicates`.
        awaitingClarify = nil

        if hasContent {
            // The pre-appended turn normally still sits in `turns`; it only
            // disappears if the transcript was reset during the handshake
            // (new chat / session load), in which case re-appending here
            // restores the old dispatch-time-append behavior.
            let preAppendedTurnPresent = preAppendedUserTurn.map { pre in
                turns.contains { $0.id == pre.id }
            }
            let sendIntroducesFirstTurn =
                preAppendedTurnPresent == true ? preAppendIntroducedFirstTurn : turns.isEmpty
            // One-shot activation signal — the install's first ever chat-UI
            // message. Inside the `hasContent` branch so a contentless
            // regeneration doesn't count as "used".
            FeatureTelemetry.firstTimeChatUsed()

            if let pre = preAppendedUserTurn {
                if preAppendedTurnPresent == false { turns.append(pre) }
            } else {
                turns.append(ChatTurn(role: .user, content: trimmed, attachments: attachments))
            }
            appendedUserTurnForCurrentRun = true
            // Stash the draft so we can put it back if the user cancels
            // out of the privacy review sheet. The text and attachments
            // arrive cleared (the input bar wipes them as part of its
            // own send animation) so we have to capture them here at
            // the only point where we still know what they were.
            savedDraftOnCancel = (text: trimmed, attachments: attachments)
            isDirty = true
            rebuildVisibleBlocks()

            // Persist the user turn before inference starts. Final cleanup will
            // save the assistant turn, but the user's text/attachments must
            // survive a crash, quit, or long-running stream too.
            save()
            if sendIntroducesFirstTurn {
                transientSessionIdForCurrentRun = sessionId
            }
        }

        // One stable identity for every Todo tool execution and TodoStore read
        // in this logical run. A reset/new-chat action must not make an
        // in-flight call write one session while terminal checks read another.
        let todoSessionIdForRun = expectedTodoSessionId

        let memoryAgentId = (agentId ?? Agent.defaultId).uuidString
        let memoryConversationId = (sessionId ?? UUID()).uuidString

        let runId = UUID()
        beginRun(
            runId,
            context: RunContext(
                hasContent: hasContent,
                userContent: trimmed,
                memoryAgentId: memoryAgentId,
                memoryConversationId: memoryConversationId,
                memoryProjectId: projectId
            )
        )

        // Capture the agent binding for the whole turn so every async
        // step inside this Task — model resolution, system prompt
        // composition, streaming, tool execution, post-stream
        // memory writes — sees a single non-shifting `currentAgentId`.
        // Historically the binding only wrapped the inline tool exec
        // block below, which meant configure tools dispatched off the
        // streaming pipeline (e.g. from a sandbox plugin running on a
        // detached task) couldn't tell what agent they belonged to.
        let turnAgentId = agentId ?? Agent.defaultId
        let turnModelId = selectedModel
        let turnModelType = selectedPickerItem?.modelType
        let turnSupportsImages = selectedModelSupportsImages
        let turnSupportsAudio = selectedModelSupportsAudio
        let turnSupportsVideo = selectedModelSupportsVideo
        let imageSettings = imageComposerSettings
        let turnModelOptions = activeModelOptions
        let storedTurnModelOptions = turnModelId.flatMap {
            ModelOptionsStore.shared.storedExplicitOptions(for: $0)
        }

        currentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.isRunActive(runId) else { return }
            // Freeze prompt-affecting controls only after recovering a saved
            // explicit Thinking choice that launch-time cold-cache
            // normalization may have provisionally hidden. No default is
            // synthesized: absent choices still defer to the bundle.
            let turnGenerationControls = await ChatTurnGenerationControls.captureForSend(
                modelId: turnModelId,
                activeModelOptions: turnModelOptions,
                storedExplicitOptions: storedTurnModelOptions
            ) { modelId in
                _ = await LocalReasoningCapability.resolveForDispatch(modelId: modelId)
            }
            guard self.isRunActive(runId) else { return }
            if self.selectedModel == turnModelId,
                self.activeModelOptions.isEmpty,
                let recovered = turnGenerationControls.modelOptions
            {
                self.activeModelOptions = recovered
            }
            // A send issued right after a session switch / app launch can
            // race the fire-and-forget bookmark restore; wait for it so this
            // turn composes WITH the folder instead of silently folder-less.
            // Instant when no restore is pending. Default agent skips — it
            // is folder-less by policy and must not wait on a restore.
            if turnAgentId != Agent.defaultId {
                _ = await self.folderState.contextWaitingForRestore()
            }
            guard self.isRunActive(runId) else { return }
            // Bind THIS session's trusted root for the whole turn. A selected
            // folder is intentionally suspended while VM execution is enabled,
            // so sandbox tools cannot inherit a host path even if the user
            // switches modes in another window midway through the run.
            let sandboxEnabled =
                AgentManager.shared.effectiveAutonomousExec(for: turnAgentId)?.enabled == true
            // A folder that a background dispatch supplied (Watcher / schedule
            // / plugin) wins over the sandbox suspension here, exactly as it
            // does in `prepareChatExecutionMode` (`preferHostFolder`). Without
            // this the two disagree: the execution mode exposes the host file
            // tools, but this root binding stays nil, so every folder tool
            // returns "no working folder is selected" (the Voice Memo Watcher
            // failure after the user turns sandbox off). Interactive sessions
            // keep the suspension — the user toggles sandbox off to use a
            // folder there.
            let turnFolderRoot = Self.turnFolderRoot(
                sandboxEnabled: sandboxEnabled,
                folderFromDispatch: self.folderContextFromDispatchBookmark,
                folderRoot: self.activeFolderContext(for: turnAgentId)?.rootPath
            )
            // A dispatched folder is the run's ONLY filesystem: mark it so the
            // file tools never answer a `/workspace/...` path from the VM
            // (the autonomous agent's sandbox stays registered process-wide,
            // so the bridge would otherwise still be bound in host-folder
            // mode). Interactive chats never set this.
            let folderIsDispatchTarget =
                self.folderContextFromDispatchBookmark && turnFolderRoot != nil
            await ChatExecutionContext.$currentFolderRoot.withValue(turnFolderRoot) { [self] in
            await ChatExecutionContext.$hostFolderIsDispatchTarget.withValue(folderIsDispatchTarget) { [self] in
            // Typed run provenance for the whole turn. The session's own
            // persisted `source` is authoritative here (a dispatched
            // schedule/watcher/self-schedule run re-binds the same value the
            // dispatcher already bound; a UI chat turn binds `.chat`).
            // Source-scoped capabilities (proactive channel publishing) read
            // this instead of inferring provenance from surface flags.
            await ChatExecutionContext.$currentSessionSource.withValue(source) { [self] in
            // Weak handle to THIS session for the whole turn, so a
            // `background: true` spawn dispatch can deliver its report-back
            // digest to the exact launching conversation later.
            await ChatExecutionContext.$currentChatSessionBox.withValue(WeakChatSessionBox(self)) { [self] in
            await ChatExecutionContext.$currentAgentId.withValue(turnAgentId) { [self] in
            await ChatExecutionContext.$currentProjectId.withValue(self.projectId) { [self] in
            await ChatExecutionContext.$currentUserRequest.withValue(
                trimmed.isEmpty ? nil : trimmed
            ) { [self] in
            await ChatExecutionContext.$currentModelName.withValue(
                turnModelId
            ) { [self] in
            await ChatExecutionContext.$currentEnableThinking.withValue(
                turnGenerationControls.enableThinking
            ) { [self] in
                debugLog("send: task started runId=\(runId) model=\(turnModelId ?? "nil")")
                // A Stop can land between beginRun (synchronous in send) and
                // this task's first line: stop() has then already finalized
                // this runId, and the deferred finalizeRun below would no-op
                // as a duplicate — so everything appended here would survive
                // as a ghost (an empty assistant bubble and a resurrected
                // isStreaming) with no cleanup left to remove it.
                guard self.activeRunId == runId else {
                    debugLog("send: run \(runId) finalized before its task started — skipping")
                    return
                }
                lastStreamError = nil
                isStreaming = true
                ServerController.signalGenerationStart()
                var shouldPersistConversationArtifacts = true
                defer {
                    finalizeRun(
                        runId: runId,
                        persistConversationArtifacts: shouldPersistConversationArtifacts
                    )
                }

                var assistantTurn = ChatTurn(role: .assistant, content: "")
                turns.append(assistantTurn)
                // Must refresh block memoizer before first delta — otherwise visibleBlocks stays
                // user-only while isStreaming is true and the table early-returns without assistant rows.
                rebuildVisibleBlocks()

                // Image-generation models route through ImageGenerationService
                // (a second MLX graph, gated exclusive to LLM eval) instead of
                // the chat engine. The same run lifecycle (defer finalizeRun,
                // currentTask cancellation) applies.
                                    if self.isVideoGenerationModel(turnModelId) {
                                        await self.runVideoGeneration(
                                            prompt: trimmed,
                                            attachments: attachments,
                                            settings: imageSettings,
                                            into: assistantTurn,
                                            runId: runId
                                        )
                                        return
                                    }
                if self.isImageGenerationModel(turnModelId) {
                    await self.runImageGeneration(
                        prompt: trimmed,
                        attachments: attachments,
                        settings: imageSettings,
                        into: assistantTurn,
                        runId: runId
                    )
                    return
                }

                #if DEBUG
                    // Dev aid: stream a canned tool-call timeline instead of the real
                    // model so the tool-call rail animation can be exercised on demand.
                    // Toggle via `MockToolStream.forceEnabled` (or env OSAURUS_MOCK_STREAM=1).
                    if MockToolStream.enabled {
                        await streamMockToolTimeline(runId: runId, firstTurn: assistantTurn)
                        return  // `defer { finalizeRun(...) }` handles cleanup
                    }
                #endif

                // Backdate to the send so the first phase covers the wait the
                // user sat through, then close that phase immediately — every
                // later mark stays relative and comparable to previous traces.
                let ttftTrace: TTFTTrace? = TTFTTrace.makeIfEnabled(
                    start: sendRequestedAt.timeIntervalSinceReferenceDate
                )
                ttftTrace?.mark("pre_send_wait")
                ttftTrace?.set("awaited_pre_send_handshake", awaitedPreSendHandshake)
                do {
                    let engine = chatEngineFactory(source.inferenceSource)
                    let chatCfg = ChatConfigurationStore.load()

                    // MARK: - Capability Setup
                    // The outer ChatExecutionContext.$currentAgentId binding
                    // (lifted to wrap the whole Task) already pinned this
                    // turn's agent id; we just alias it locally for the calls
                    // below that want a plain UUID.
                    let effectiveAgentId = turnAgentId
                    // Per-agent screen context (a child of Computer Use). Read
                    // once here so the freeze gate below and the inject gate in
                    // `loopHooks.buildMessages` agree on a single value for the
                    // whole turn.
                    let screenContextEnabled = AgentManager.shared
                        .effectiveCapabilities(for: effectiveAgentId).screenContextEnabled
                    ttftTrace?.mark("prepare_exec_mode_start")
                    let executionMode = await prepareChatExecutionMode(agentId: effectiveAgentId)
                    ttftTrace?.mark("prepare_exec_mode_done")
                    guard isRunActive(runId) else { return }

                    let priorUserMessages: [ChatMessage] = turns.compactMap { t in
                        guard t.role == .user, !t.contentIsEmpty else { return nil }
                        return ChatMessage(role: "user", content: t.content)
                    }

                    // Reuse the per-session always-loaded + capabilities_load
                    // union on subsequent sends so the schema stays stable.
                    // First, ask the store to drop the cache if the
                    // (executionMode, toolMode) fingerprint flipped since the
                    // last turn — otherwise stale dynamically-loaded tools
                    // would leak into the new mode's schema.
                                        let liveToolMode = AgentManager.shared.effectiveToolSelectionMode(
                                            for: effectiveAgentId
                                        )
                    // The agent id is part of the fingerprint: the baseline
                    // schema is per-agent, so switching the agent chip must
                    // re-freeze the always-loaded snapshot for the new agent
                    // (otherwise the Orchestrator inherits a custom agent's
                    // frozen list without `osaurus_help` / `osaurus_config`).
                    let liveFingerprint = SessionToolState.fingerprint(
                        executionMode: executionMode,
                        toolMode: liveToolMode,
                        agentId: effectiveAgentId
                    )
                    let cachedSession: SessionToolState?
                    if let sid = sessionId {
                        let key = sessionStateKey(sid)
                        // MCP/plugin tools loaded via `capabilities` are
                        // mode-independent; carry them across a mode flip so
                        // the model doesn't have to reload them every turn.
                        // (Manual mode never persists loads, so the carried
                        // set is empty there by construction.)
                        let modeIndependentDynamicNames = Set(
                            ToolRegistry.shared.listDynamicTools().map(\.name)
                        )
                        await SessionToolStateStore.shared.invalidateIfFingerprintChanged(
                            key,
                            liveFingerprint: liveFingerprint,
                            preservingLoadedToolNames: modeIndependentDynamicNames
                        )
                        cachedSession = await SessionToolStateStore.shared.get(key)
                    } else {
                        cachedSession = nil
                    }

                    // Opt-in screen context: freeze a distilled snapshot of
                    // what the user is doing, once per session on the first
                    // send, so the assistant has ambient awareness of their
                    // current task. Reused unchanged for the rest of the
                    // session and injected onto the latest user message — so it
                    // flows through the Privacy Filter — in
                    // `loopHooks.buildMessages` below.
                    if !isRemoteAgentTarget,
                        screenContextEnabled,
                        !self.isScreenContextFrozen
                    {
                        // A welcome-screen preview may have already captured the
                        // snapshot (reused as-is to avoid a second Accessibility
                        // walk); otherwise capture it now.
                        if self.frozenScreenContext == nil {
                            let snapshot = await ScreenContextDistiller.captureForChat()
                            let rendered = snapshot.render()
                            self.frozenScreenContext = rendered.isEmpty ? nil : rendered
                            guard isRunActive(runId) else { return }
                        }
                        self.cachedScreenContextTokens =
                            self.frozenScreenContext.map {
                                ContextBudgetManager.estimateTokens(for: $0)
                            } ?? 0
                        self.isScreenContextFrozen = true
                    }

                    // Keep the first real send byte-identical to warmup and
                    // restart restore: plugin tools/skills are part of the
                    // static prompt and must come from a completed catalog
                    // snapshot, not launch-task timing.
                    if !isRemoteAgentTarget {
                        await PluginManager.shared.ensurePromptCatalogReady()
                        guard isRunActive(runId) else { return }
                    }

                    // Resolve the pending one-off skill BEFORE composing.
                    // Skill instructions routinely name the exact tools they
                    // expect the model to call (MCP / plugin tools), but those
                    // tools only enter the schema via `capabilities_load` —
                    // injecting the instructions after the tool schema and
                    // execution scope were frozen left every such call refused
                    // as tool_not_found (#2145). Scan the instructions for
                    // agent-granted dynamic tools and ride them in through
                    // `additionalToolNames`, the same channel a prior-turn
                    // `capabilities_load` would use. Consume the pending id
                    // either way, but never inject in Mode 2 (the request
                    // must stay bare).
                    var oneOffSkillSection: (name: String, body: String)?
                    var skillReferencedTools: LoadedTools = []
                    if let skillId = pendingOneOffSkillId {
                        pendingOneOffSkillId = nil
                                            if !isRemoteAgentTarget, let skill = SkillManager.shared.skill(for: skillId)
                                            {
                            let body = await SkillManager.shared.buildFullInstructions(for: skill)
                            oneOffSkillSection = (skill.name, body)
                            let granted = AgentManager.shared
                                .effectiveEnabledToolNames(for: effectiveAgentId)
                                .map(Set.init)
                            let dynamicNames = Set(
                                ToolRegistry.shared.listDynamicTools().map(\.name)
                            ).filter { granted?.contains($0) ?? true }
                            skillReferencedTools = LoadedTools(
                                SkillManager.toolNames(referencedIn: body, from: dynamicNames)
                            )
                        }
                    }

                    #if DEBUG
                        let requestToolsDisabled =
                            toolsDisabledForTestingOverride ?? Self.toolsDisabledForTesting
                    #else
                        let requestToolsDisabled = false
                    #endif
                    let context = await SystemPromptComposer.composeChatContext(
                        ComposeRequest(
                            agentId: effectiveAgentId,
                            executionMode: executionMode,
                            model: turnModelId,
                            modelType: turnModelType,
                            query: trimmed,
                            messages: priorUserMessages,
                            // Tool availability belongs to the active agent.
                            // Folding in the hidden legacy chat-wide bit made
                            // every custom agent schema-less.
                            toolsDisabled: requestToolsDisabled,
                            additionalToolNames: (cachedSession?.loadedToolNames ?? [])
                                .union(skillReferencedTools),
                            frozenAlwaysLoadedNames: cachedSession?.initialAlwaysLoadedNames,
                            frozenToolSpecs: cachedSession?.initialToolSpecs,
                            frozenManifest: cachedSession?.frozenManifest,
                            frozenSoul: cachedSession?.frozenSoul,
                            trace: ttftTrace,
                            projectId: projectId
                        )
                    )
                    guard isRunActive(runId) else { return }

                    // Mode 2 (remote agent run): send NO local system prompt.
                    // The remote agent composes its own persona/memory/tools on
                    // the bare conversation server-side, so anything we'd inject
                    // here (local agent prompt, plugin instructions, one-off
                    // skill) would leak the caller's context onto the agent.
                    var sys = isRemoteAgentTarget ? "" : context.prompt

                    // Plugin-dispatched tasks (host->dispatch) carry their
                    // source plugin id on the session. Append that plugin's
                    // instructions so the dispatched chat sees the same
                    // contract the plugin would have published via
                    // host->complete. Mirrors `PluginHostAPI.prepareInference`
                    // through the shared `PluginInstructionsResolver`. Without
                    // this, plugin manifest `instructions` are silently
                    // dropped on the dispatch path, leaving the model
                    // unaware of plugin-specific contracts (e.g. Telegram's
                    // `[reply_token …]` / `reply` / `reply_typing` flow).
                    if !isRemoteAgentTarget,
                        let pid = sourcePluginId,
                        let pluginInstructions = PluginInstructionsResolver.instructions(
                            pluginId: pid,
                            agentId: agentId
                        )
                    {
                        sys = sys.isEmpty ? pluginInstructions : sys + "\n\n" + pluginInstructions
                    }

                    // Shared project context: a chat that belongs to a
                    // project carries the project's instructions on every
                    // turn. Constant per session (like plugin instructions),
                    // so the KV prefix stays stable across turns.
                    if !isRemoteAgentTarget, let pid = projectId,
                        let project = ProjectManager.shared.project(for: pid)
                    {
                        let instructions = project.instructions
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !instructions.isEmpty {
                            sys += "\n\n## Project: \(project.name)\n\n\(instructions)"
                        }
                    }

                    // Inject the one-off skill the user selected via slash
                    // command (resolved above, before compose, so the tools it
                    // references made it into the schema).
                    if let oneOff = oneOffSkillSection {
                        sys += "\n\n" + SkillManager.activeSkillPromptSection(
                            name: oneOff.name,
                            body: oneOff.body
                        )
                    }

                    // Initial request schema. `ToolExecutionScope` appends tools
                    // loaded through `capabilities` for the NEXT model iteration;
                    // constrained decoders cannot emit a tool name absent from
                    // the request schema, even when its schema rides in the tool
                    // result. In Mode 2 we send no tools: the remote agent
                    // advertises and executes its own tools server-side.
                    let toolSpecs = isRemoteAgentTarget ? [] : context.tools
                    let isManualTools = liveToolMode == .manual
                    cachedContext = context

                    // What this run may EXECUTE, seeded from what it actually EXPOSED.
                    //
                    // The model can name a tool it was never shown (the parser records any name
                    // once a schema exists) and the registry used to run it. One object for the
                    // whole run: `capabilities_load` legitimately GROWS this set mid-run while
                    // `toolSpecs` stays frozen, so an immutable snapshot would kill that feature.
                    let toolScope = ToolExecutionScope(exposed: toolSpecs)
                    if !isRemoteAgentTarget {
                        Self.logOrchestratorScopeDisagreement(agentId: effectiveAgentId, scope: toolScope)
                    }

                    // Persist the always-loaded snapshot back onto the session
                    // so the next send freezes the schema against tools that
                    // register mid-session. Preserves any capabilities_load
                    // names already accumulated this session. Stamp the live
                    // fingerprint so the invalidation rule above can detect
                    // a flip on the next turn.
                    if let sid = sessionId {
                        await SessionToolStateStore.shared.setInitial(
                            sessionStateKey(sid),
                            alwaysLoadedNames: context.alwaysLoadedNames,
                            toolSpecs: context.initialToolSpecs,
                            fingerprint: liveFingerprint,
                            manifest: context.enabledManifest,
                            soul: context.soul
                        )
                    }

                    // Skill-referenced tools joined this turn's schema above;
                    // persist them into the session's loaded-tool union (auto
                    // mode only, mirroring the capabilities_load drain path)
                    // so the next turn's frozen schema still contains them.
                    if !skillReferencedTools.isEmpty, !isManualTools, let sid = sessionId {
                        await SessionToolStateStore.shared.appendLoadedTools(
                            sessionStateKey(sid),
                            names: Array(skillReferencedTools),
                            fallbackAlwaysLoadedNames: context.alwaysLoadedNames
                        )
                    }

                    budgetTracker.snapshot(context: context)
                    budgetTracker.updateScreenContext(tokens: cachedScreenContextTokens)

                    // Freeze this turn's memory + screen/automation-context prefix into
                    // the turn history BEFORE any messages are rendered: the
                    // injected bytes become part of the turn's permanent
                    // rendering, so turn N+1 replays turn N byte-identically
                    // and the paged KV cache reuses the whole previous
                    // exchange. (Previously the prefix was re-injected onto
                    // whichever user message was latest and vanished from
                    // history on the next turn, re-prefilling the last
                    // exchange every turn.) Skipped in Mode 2: requests stay
                    // bare and the remote agent applies its own context.
                    let appleScriptWorkingContext =
                        !isRemoteAgentTarget
                        && toolSpecs.contains(where: {
                            $0.function.name == AppleScriptTool.toolName
                        })
                        ? SystemPromptComposer.appleScriptWorkingAppContext(
                            appName: FrontmostAppTracker.shared.lastNonSelfAppName
                        )
                        : nil
                    if !isRemoteAgentTarget {
                        freezeInjectedContextOntoLatestUserTurn(
                            memorySection: context.memorySection,
                            screenContext: screenContextEnabled ? frozenScreenContext : nil,
                            automationContext: appleScriptWorkingContext
                        )
                    }

                                        var effectiveMaxTokensForAgent = AgentManager.shared.effectiveMaxTokens(
                                            for: effectiveAgentId
                                        )
                    if let delegationBudget = self.delegationBudget {
                        // Delegated child: the contract's per-generation
                        // response ceiling is ENFORCED here (admission
                        // priced it). Tighten-only.
                        effectiveMaxTokensForAgent = delegationBudget
                            .clampedResponseTokens(agentConfigured: effectiveMaxTokensForAgent)
                    }

                    // KV-cache-aware history compaction: shared window
                    // resolution + reservations via `AgentLoopBudget` (parity
                    // with the plugin host's budget manager). Trimming only
                    // activates once the conversation outgrows the history
                    // budget; the system prefix is never rewritten so paged-KV
                    // reuse survives compaction.
                    let loopBudgetManager: ContextBudgetManager = await {
                        var contextWindow = await AgentLoopBudget.resolveContextWindow(
                            modelId: turnModelId ?? "default"
                        )
                        if let delegationBudget = self.delegationBudget {
                            // Delegated child: the contract's position
                            // ceiling is ENFORCED here — the budget manager
                            // trims history to this window on every request,
                            // so the ceiling holds even when tool results
                            // grow the transcript. Admission priced exactly
                            // this number.
                            contextWindow = delegationBudget
                                .clampedContextWindow(resolved: contextWindow)
                        }
                        return AgentLoopBudget.makeBudgetManager(
                            contextWindow: contextWindow,
                            systemPromptChars: sys.count,
                            toolTokens: context.toolTokens,
                            maxResponseTokens: effectiveMaxTokensForAgent
                        )
                    }()

                    // Incomplete reasoning attempts remain visible in the
                    // transcript but must not be fed back into the retry.
                    // Bundle templates do not share a continuation contract:
                    // Gemma drops tool-free reasoning history while Ornith
                    // closes and rewrites it. Excluding only these captured
                    // attempt ids makes the bounded retry an exact replay of
                    // the pre-attempt model-visible history.
                    var incompleteReasoningRetryOrdinal = 0
                    // Set only after this logical run emits a parsed tool call.
                    // Tool schemas being available is not itself agent work and
                    // must not force an intentional reasoning-only direct answer
                    // through the post-tool recovery path.
                    var hasStructuredToolWorkThisRun = false

                    /// Convert a single turn to a ChatMessage (returns nil if should be skipped)
                    @MainActor
                    func turnToMessage(_ t: ChatTurn, isLastTurn: Bool) -> ChatMessage? {
                        switch t.role {
                        case .assistant:
                            return Self.modelVisibleAssistantMessage(
                                t,
                                isLastTurn: isLastTurn
                            )
                        case .tool:
                            return ChatMessage(
                                role: "tool",
                                content: t.content,
                                tool_calls: nil,
                                tool_call_id: t.toolCallId
                            )
                        case .user:
                            let base = Self.buildUserChatMessage(
                                content: t.content,
                                attachments: t.attachments,
                                supportsImages: turnSupportsImages,
                                supportsAudio: turnSupportsAudio,
                                supportsVideo: turnSupportsVideo
                            )
                            // Replay the frozen memory / screen-context block
                            // this turn was originally sent with, so its wire
                            // bytes never change once it has been part of a
                            // token stream (paged-KV prefix reuse across
                            // turns). Mode 2 requests stay bare — the local
                            // agent's memory must not ride to a remote agent.
                            if isRemoteAgentTarget { return base }
                            return Self.applyingFrozenInjectedPrefix(
                                t.injectedContextPrefix,
                                to: base
                            )
                        default:
                            return ChatMessage(role: t.role.rawValue, content: t.content)
                        }
                    }

                    @MainActor
                    func buildMessages() -> [ChatMessage] {
                        var msgs: [ChatMessage] = []
                        if !sys.isEmpty { msgs.append(ChatMessage(role: "system", content: sys)) }

                        // Non-destructive LLM compaction: turns covered by the
                        // session's ConversationSummary are replaced by ONE
                        // byte-stable summary message in the outbound array —
                        // the visible transcript keeps every turn. When a new
                        // summary lands between runs, the built shape changes
                        // and `CompactionWatermark.validate` resets its sticky
                        // decisions (an implicit rebase at the boundary); the
                        // deterministic trimmer still runs on the remainder.
                        let summary = self.conversationSummary
                        let coveredIds = summary.map { Set($0.coveredTurnIds) } ?? []
                        var summaryInjected = false

                        for (index, t) in turns.enumerated() {
                            if let summary, coveredIds.contains(t.id) {
                                if !summaryInjected {
                                    msgs.append(
                                        ChatMessage(
                                            role: "user",
                                            content: summary.contextMessageText
                                        )
                                    )
                                    summaryInjected = true
                                }
                                continue
                            }
                            let isLastTurn = index == turns.count - 1
                            if let msg = turnToMessage(t, isLastTurn: isLastTurn) {
                                msgs.append(msg)
                            }
                        }

                        return msgs
                    }

                    var maxAttempts = max(chatCfg.maxToolAttempts ?? 15, 1)
                    if let delegationBudget = self.delegationBudget {
                        // Delegated child: the contract's turn ceiling is
                        // ENFORCED here (admission priced it). Tighten-only.
                        maxAttempts = delegationBudget
                            .clampedToolAttempts(surfaceConfigured: maxAttempts)
                    }
                    // Reset within-message dedupe/bias tracking for this user
                    // turn (lastListing intentionally persists across messages).
                    taskState.beginMessage()
                    // Refresh the dynamic-tool classifier per message: MCP /
                    // plugin tools can (dis)connect between sends, and the
                    // snapshot keeps the MainActor-bound registry out of the
                    // loop's isolation (see `dynamicToolClassifier`).
                    let dynamicToolNames = ToolRegistry.shared.dynamicToolNameSnapshot()
                    taskState.dynamicToolClassifier = { dynamicToolNames.contains($0) }
                    // Transient stream errors (e.g. provider closes connection
                    // mid-tool-args, see `RemoteProviderService` truncation
                    // detection) shouldn't immediately surface to the user — they
                    // tend to retry cleanly. The modelStep hook retries the same
                    // iteration up to `maxTransientRetries` times (via the
                    // driver's `.retryWithoutCharge`) before giving up. The
                    // counter is reset whenever a stream finishes naturally so
                    // unrelated future failures get a fresh budget.
                    let maxTransientRetries = 2
                    var transientRetries = 0
                                        let effectiveTemp = AgentManager.shared.effectiveTemperature(
                                            for: effectiveAgentId
                                        )

                    ttftTrace?.mark("pre_ttft_done")

                    // Per-call presentation override: the model keeps a compact
                    // result while the card retains the full chart/image payload.
                    // This prevents a large display artifact from being re-prefilled
                    // through the model on the next agent-loop iteration.
                    var toolCardOverrides: [String: String] = [:]

                    // Build the matching tool-result turn for a call. Every
                    // assistant `tool_use` MUST be paired with a tool turn
                    // before the loop yields control — Anthropic's Messages
                    // API rejects subsequent sends otherwise ("tool_use ids
                    // were found without tool_result blocks immediately
                    // after"). Shared by the agent-loop intercepts (`complete`,
                    // `clarify`), the dedupe replay, and the normal
                    // post-execution path so there's only one place that gets
                    // the pairing right.
                    @MainActor
                    @discardableResult
                    func recordToolTurn(_ result: String, callId: String) -> ChatTurn {
                        // Attach the result to the turn that owns this call's
                        // row. On the serial path that's always the current
                        // `assistantTurn`; on the parallel batch path every
                        // row was materialised on the turn that was current
                        // when the batch started, while `assistantTurn`
                        // advances as each result lands.
                        let owner =
                            self.turns.last(where: { turn in
                                turn.role == .assistant
                                    && (turn.toolCalls?.contains { $0.id == callId } ?? false)
                            }) ?? assistantTurn
                        // Card uses the override when present (native image);
                        // every other tool falls back to the model-facing result.
                        owner.setToolResult(toolCardOverrides[callId] ?? result, for: callId)
                        let toolTurn = ChatTurn(role: .tool, content: result)
                        toolTurn.toolCallId = callId
                        return toolTurn
                    }

                    // Everything that happens to a tool result AFTER the
                    // registry returned it: the agent-loop intercepts
                    // (`complete`/`clarify`), hot-loading capability tools,
                    // artifact enrichment, the secret prompt, and recording
                    // the hidden tool turn. Shared by the serial single-call
                    // path and the parallel batch path (which runs registry
                    // dispatch concurrently, then post-processes results
                    // here on the MainActor in model order).
                    @MainActor
                    func postProcessToolResult(
                        _ inv: ServiceToolInvocation,
                        callId: String,
                        resultText rawResult: String
                    ) async -> AgentLoopToolExecution {
                        var resultText = rawResult
                        if !self.isRunActive(runId) {
                            // Cancelled mid-execution — the driver's
                            // post-call probe ends the run before this
                            // result is recorded into history or state.
                            return AgentLoopToolExecution(result: resultText)
                        }

                        // Agent-loop intercepts: `complete` and `clarify`
                        // end the iteration loop. `todo` already wrote
                        // into AgentTodoStore via TaskLocal; the session
                        // observer mirrors it into the inline UI block.
                        //
                        // CRITICAL: gate the inline UI on whether the
                        // tool result is a success envelope. The previous
                        // implementation pulled `summary` straight from
                        // the JSON arguments and surfaced it regardless
                        // of whether `CompleteTool.execute` rejected it
                        // for being a placeholder ("done", "looks good").
                        // That let the inline completion banner show a
                        // rejected summary as if the loop had ended
                        // cleanly. We now only intercept when the result
                        // is a success envelope; on rejection the loop
                        // continues so the model sees the failure and
                        // retries with a real summary.
                        if inv.toolName == "complete" {
                            if !ToolEnvelope.isError(resultText) {
                                if let todo = await AgentTodoStore.shared.todo(
                                    for: todoSessionIdForRun
                                ) {
                                    self.lastCompletionWasBlocked =
                                        todo.doneCount < todo.totalCount
                                } else {
                                    self.lastCompletionWasBlocked = false
                                }
                                self.lastCompletionSummary =
                                    Self.parseCompleteSummary(from: inv.jsonArguments) ?? resultText
                                // Drain any pending prompts so a stale
                                // clarify card doesn't sit on top of the
                                // completion banner.
                                self.promptQueue.drainAll()
                                self.turns.append(recordToolTurn(resultText, callId: callId))
                                self.rebuildVisibleBlocks()
                                return AgentLoopToolExecution(result: resultText, endRun: true)
                            }
                            // Fall through — let the model see the
                            // failure envelope and try again with a
                            // proper summary.
                        }
                        if inv.toolName == "clarify" {
                            if !ToolEnvelope.isError(resultText),
                                let payload = Self.parseClarifyPayload(from: inv.jsonArguments)
                            {
                                // Build a ClarifyPromptState bound to
                                // `self.send(...)` so the user's answer
                                // dispatches as the next user turn
                                // through the existing chat send path.
                                // The agent loop ends here; the model
                                // resumes on the next send with the
                                // answer in history.
                                self.turns.append(recordToolTurn(resultText, callId: callId))
                                self.rebuildVisibleBlocks()
                                // Surface the parsed payload on the
                                // session BEFORE breaking the loop so
                                // the BackgroundTaskManager observer
                                // sees the clarify state ahead of the
                                // streaming-end tick — that ordering
                                // is what gates the COMPLETED-suppression
                                // path for plugin-dispatched runs.
                                self.awaitingClarify = payload
                                let clarifyState = ClarifyPromptState(
                                    question: payload.question,
                                    options: payload.options,
                                    allowMultiple: payload.allowMultiple,
                                    onSubmit: { [weak self] answer in
                                        self?.send(answer)
                                    },
                                    onUserCancel: { [weak self] in
                                        self?.appendClarifyQuestionTrace(payload)
                                    }
                                )
                                self.promptQueue.enqueue(.clarify(clarifyState))
                                self.lastCompletionSummary = nil
                                return AgentLoopToolExecution(result: resultText, endRun: true)
                            }
                            // Fall through on failure (empty question,
                            // etc.) so the model sees the rejection.
                        }

                        // Tools loaded via capabilities, first-use sandbox
                        // provisioning, or sandbox_plugin_register.
                        // Add their schemas to the next model iteration as well as
                        // the execution scope. Returning a schema only in tool
                        // result text is insufficient for constrained decoders:
                        // they substitute a hot schema tool when the intended
                        // loaded name is absent from the request's `tools` array.
                        if CapabilityLoadBuffer.shouldActivate(after: inv.toolName) {
                            // Always drain so a buffered spec can't leak into an
                            // unrelated run; persist only in auto mode (manual
                            // mode keeps the user's explicit tool set fixed).
                            let newTools = await CapabilityLoadBuffer.shared.drain()
                            // Authorize and publish them for the rest of this run.
                            toolScope.activate(newTools)
                            if !newTools.isEmpty, !isManualTools, let sid = self.sessionId {
                                let names = newTools.map { $0.function.name }
                                let snapshot = context.alwaysLoadedNames
                                await SessionToolStateStore.shared.appendLoadedTools(
                                    self.sessionStateKey(sid),
                                    names: names,
                                    fallbackAlwaysLoadedNames: snapshot
                                )
                            }
                        }

                        if inv.toolName == "render_chart",
                            let compactResult = RenderChartTool.compactModelResult(from: resultText)
                        {
                            // The full marker renders the chart card, while the
                            // model gets a compact confirmation instead of
                            // re-prefilling every category/value and inventing
                            // a second artifact-sharing step.
                            toolCardOverrides[callId] = resultText
                            resultText = compactResult
                        } else if inv.toolName == "share_artifact" {
                            resultText = await self.processShareArtifactResult(
                                toolResult: resultText,
                                executionMode: executionMode
                            )
                            if let artifact = SharedArtifact.fromEnrichedToolResult(resultText) {
                                                    await PluginManager.shared.notifyArtifactHandlers(
                                                        artifact: artifact
                                                    )
                            }
                                            } else if GeneratedMediaToolArtifactBridge.isGeneratedMediaTool(
                                                inv.toolName
                                            ) {
                            // Enrich for the artifact card only; the model keeps
                            // the compact `toolPayload` in `resultText`. The bridge
                            // returns its input unchanged on failure, so a changed
                            // string means success — route it to the card.
                            let enriched = await self.processNativeImageToolResult(
                                toolName: inv.toolName,
                                toolResult: resultText
                            )
                            if enriched != resultText {
                                toolCardOverrides[callId] = enriched
                                if let artifact = SharedArtifact.fromEnrichedToolResult(enriched) {
                                                        await PluginManager.shared.notifyArtifactHandlers(
                                                            artifact: artifact
                                                        )
                                }
                            }
                        }
                        // Worker-shared artifacts: a spawned helper's
                        // `share_artifact` was processed at worker time into
                        // the PARENT session's artifact store and deposited in
                        // `SpawnArtifactCollector` (the spawn payload carries
                        // only an `artifacts_shared` count). Drain after EVERY
                        // spawn return and attach to the owning assistant turn.
                        if SubagentCapabilityRegistry.spawn.toolNames.contains(inv.toolName) {
                            await self.promoteWorkerSharedArtifacts(callId: callId)
                        }

                        if let fileCard = WorkspaceFileReference.cardResult(
                            toolResult: resultText,
                            toolName: inv.toolName
                        ) {
                            // Keep the compact typed reference in model history,
                            // but make its Open/Reveal or Export path explicit
                            // on the user-facing tool card.
                            toolCardOverrides[callId] = fileCard
                        }

                        if inv.toolName == "sandbox_secret_set",
                            let prompt = SecretPromptParser.parse(resultText)
                        {
                            let stored: Bool = await withCheckedContinuation { continuation in
                                let promptState = SecretPromptState(
                                    key: prompt.key,
                                    description: prompt.description,
                                    instructions: prompt.instructions,
                                    agentId: prompt.agentId
                                ) { value in
                                    continuation.resume(returning: value != nil)
                                }
                                // Route through the shared queue so
                                // a clarify can't pop on top of a
                                // pending secret (and vice versa).
                                self.promptQueue.enqueue(.secret(promptState))
                            }
                            // The overlay's dismiss closure already
                            // called `promptQueue.advance()` once
                            // the user resolved; nothing to clean
                            // up here.
                            resultText =
                                stored
                                ? SecretToolResult.stored(key: prompt.key)
                                : SecretToolResult.cancelled(key: prompt.key)
                        }

                        // Log tool success (truncated result)
                        let truncatedResult = resultText.prefix(500)
                        print(
                            "[Osaurus][Tool] Success: \(inv.toolName) returned \(resultText.count) chars: \(truncatedResult)\(resultText.count > 500 ? "..." : "")"
                        )

                        // Turn persistence intentionally does NOT happen here.
                        // Non-intercept results are appended by the
                        // `onBatchComplete` hook in the driver's slot (model)
                        // order — mid-batch appends were the source of
                        // out-of-order transcripts (denials and deferred
                        // dedupe replays landing around executed siblings).
                        return AgentLoopToolExecution(result: resultText)
                    }

                    // Enforces a forced `tool_choice` at the execution
                    // boundary — chat templates that ignore the
                    // `tool_choice_name` hint leave decoding unconstrained,
                    // so a mismatched call must be refused here, not run.
                    // Armed per iteration in `modelStep`.
                    let forcedToolGate = ForcedToolChoiceGate()

                    // The historical single-call path: registry dispatch
                    // (permission gate included) followed by post-processing.
                    // Thrown errors become rejection envelopes flagged
                    // `isError`, which under the chat policy
                    // (`stopOnToolRejection`) ends the batch and the run.
                    @MainActor
                    func executeSingleToolCall(
                        _ inv: ServiceToolInvocation,
                        callId: String
                    ) async -> AgentLoopToolExecution {
                        if let violation = forcedToolGate.violationEnvelope(calledTool: inv.toolName) {
                            return AgentLoopToolExecution(result: violation)
                        }
                        let toolStartedAt = Date()
                        do {
                            // Never print a direct secret-set value to the
                            // process log. Execution below still receives the
                            // original arguments.
                            let recordedArgs = SecretArgumentScrubber.recordedArguments(
                                toolName: inv.toolName,
                                argumentsJSON: inv.jsonArguments
                            )
                            let truncatedArgs = recordedArgs.prefix(200)
                            print(
                                "[Osaurus][Tool] Executing: \(inv.toolName) with args: \(truncatedArgs)\(recordedArgs.count > 200 ? "..." : "")"
                            )

                            if executionMode.usesSandboxTools {
                                                    await SandboxToolRegistrar.shared.registerTools(
                                                        for: effectiveAgentId
                                                    )
                                if !self.isRunActive(runId) {
                                    // Run was cancelled before execution; the
                                    // driver's post-call cancellation probe
                                    // ends the run before this placeholder is
                                    // recorded anywhere.
                                    return AgentLoopToolExecution(result: "")
                                }
                            }

                            // Bind the session id so the unified Chat agent
                            // tools (`todo`, etc.) can address per-session
                            // state in their stores. Falls back to a stable
                            // string when no session has been created yet so
                            // brand-new chats still get a todo store entry.
                            // `currentAgentId` is already pinned by the
                            // outer turn-level binding; we only need to
                            // layer per-tool-call session/turn/call ids.
                            let resultText = try await ChatExecutionContext.$toolExecutionScope
                                .withValue(toolScope) {
                                    try await ChatExecutionContext.$currentSessionId.withValue(
                                        todoSessionIdForRun
                                    ) {
                                        try await ChatExecutionContext.$currentAssistantTurnId
                                            .withValue(assistantTurn.id) {
                                                try await ChatExecutionContext.$currentToolCallId
                                                    .withValue(callId) {
                                                        // The combined-mode host-read scope +
                                                        // secret-read policy are bound centrally
                                                        // inside ToolRegistry.execute, so every
                                                        // entrypoint inherits them uniformly.
                                                        try await ToolRegistry.shared.execute(
                                                            name: inv.toolName,
                                                            argumentsJSON: inv.jsonArguments
                                                        )
                                                    }
                                            }
                                    }
                                }
                                                // Wall time of the execution itself, so a tool that
                                                // returns late (a blocked page trickling bytes for
                                                // minutes) is visible in the run log.
                                                print(
                                                    "[Osaurus][Tool] Elapsed: \(inv.toolName) \(Int(Date().timeIntervalSince(toolStartedAt) * 1000)) ms"
                                                )
                                                return await postProcessToolResult(
                                                    inv,
                                                    callId: callId,
                                                    resultText: resultText
                                                )
                        } catch {
                            // Store rejection/error as the result so UI shows "Rejected" instead of hanging.
                            // The structured envelope replaces the legacy `[REJECTED] …` string so
                            // local models read a clear `{ok, kind, message, retryable}` rather than
                            // a marker they misinterpret as a sticky policy refusal. `fromError`
                            // maps FolderToolError + registry permission codes to the right `kind`
                            // so user denials, missing files, and bad arguments don't all get the
                            // same opaque `executionError` treatment. The driver records the
                            // envelope into the task state and, under the chat policy, stops the
                            // run (remaining calls in the batch are skipped). Turn persistence
                            // happens in `onBatchComplete`, in slot order.
                            let rejectionMessage = ToolEnvelope.fromError(error, tool: inv.toolName)
                            let failedAfterMs = Int(Date().timeIntervalSince(toolStartedAt) * 1000)
                            let failureKind: String = (error is CancellationError) ? "cancelled" : String(describing: type(of: error))
                            print("[Osaurus][Tool] Elapsed: \(inv.toolName) \(failedAfterMs) ms (threw: \(failureKind))")
                            // A spawn that threw (failed/cancelled/over-budget)
                            // may still have deposited artifacts its worker
                            // shared before dying — surface them anyway.
                            if SubagentCapabilityRegistry.spawn.toolNames.contains(inv.toolName) {
                                await self.promoteWorkerSharedArtifacts(callId: callId)
                            }
                            return AgentLoopToolExecution(result: rejectionMessage, isError: true)
                        }
                    }

                    // Approval-aware parallel batch execution (chat
                    // semantics): approvals resolve FIRST, serially and in
                    // model order, so permission prompts never stack or
                    // race; the approved set then executes concurrently
                    // (registry dispatch only); results post-process on the
                    // MainActor in model order. On a denial the remaining
                    // unstarted calls are skipped with a paired envelope —
                    // the chat policy (`stopOnToolRejection`) stops the
                    // loop after the batch — while nothing was yet running.
                    @MainActor
                    func executeToolBatch(
                        _ calls: [(invocation: ServiceToolInvocation, callId: String)]
                    ) async -> [AgentLoopToolExecution] {
                        // Cancelled before any execution: return NO results.
                        // The driver treats missing slots as never-executed
                        // (no turn appended, no `state.record`) — matching
                        // the serial cancel semantics instead of recording
                        // empty placeholder envelopes.
                        guard self.isRunActive(runId) else { return [] }

                        // Serial fallback for batches of one — identical to
                        // the historical single-call path.
                        if calls.count == 1, let only = calls.first {
                                                let execution = await executeSingleToolCall(
                                                    only.invocation,
                                                    callId: only.callId
                                                )
                            // Cancelled before execution produced anything:
                            // report "never ran" rather than an empty
                            // envelope the driver would record.
                                                if execution.result.isEmpty, !execution.isError,
                                                    !self.isRunActive(runId)
                                                {
                                return []
                            }
                            return [execution]
                        }

                        // Todo replaces one session-scoped checklist wholesale.
                        // Concurrent Todo calls would make the final store value
                        // depend on completion order instead of model order.
                        // Keep the batch framing, but execute every call in the
                        // batch serially when it contains Todo; onBatchComplete
                        // still persists all result turns in slot order.
                        if calls.contains(where: { $0.invocation.toolName == "todo" }),
                            !AgentToolLoop.containsIntercept(calls)
                        {
                            var serialExecutions: [AgentLoopToolExecution] = []
                            for call in calls {
                                guard self.isRunActive(runId) else { break }
                                let execution = await executeSingleToolCall(
                                    call.invocation,
                                    callId: call.callId
                                )
                                if execution.result.isEmpty,
                                    !execution.isError,
                                    !self.isRunActive(runId)
                                {
                                    break
                                }
                                serialExecutions.append(execution)
                            }
                            return serialExecutions
                        }

                        // Serial fallback when the batch carries a loop-ending
                        // intercept (`complete`/`clarify`): execute in model
                        // order and stop at the first `endRun`; the driver
                        // treats the missing trailing results as
                        // never-executed slots. Turns for non-intercept calls
                        // are appended inline here (serial execution order IS
                        // model order); `onBatchComplete` skips call ids that
                        // already have a tool turn.
                        if AgentToolLoop.containsIntercept(calls) {
                            var serialExecutions: [AgentLoopToolExecution] = []
                            for call in calls {
                                guard self.isRunActive(runId) else { break }
                                let execution = await executeSingleToolCall(
                                    call.invocation,
                                    callId: call.callId
                                )
                                                    if execution.result.isEmpty, !execution.isError,
                                                        !self.isRunActive(runId)
                                                    {
                                    break
                                }
                                serialExecutions.append(execution)
                                if execution.endRun { break }
                                // Historical serial shape: tool turn followed
                                // by a fresh assistant turn for subsequent
                                // content.
                                let toolTurn = recordToolTurn(execution.result, callId: call.callId)
                                let newAssistantTurn = ChatTurn(role: .assistant, content: "")
                                self.turns.append(contentsOf: [toolTurn, newAssistantTurn])
                                assistantTurn = newAssistantTurn
                            }
                            self.rebuildVisibleBlocks()
                            return serialExecutions
                        }

                                            var executions = [AgentLoopToolExecution?](
                                                repeating: nil,
                                                count: calls.count
                                            )

                        if executionMode.usesSandboxTools {
                            await SandboxToolRegistrar.shared.registerTools(for: effectiveAgentId)
                        }
                        guard self.isRunActive(runId) else { return [] }

                        // Phase 1 — approvals, serially in model order. No
                        // turns are appended here: denial/skip envelopes ride
                        // back to the driver as slotted executions and are
                        // persisted by `onBatchComplete` in slot order, so
                        // the transcript can never interleave a denial ahead
                        // of an earlier approved call's result.
                                            var approved:
                                                [(slot: Int, invocation: ServiceToolInvocation, callId: String)] = []
                        var denied = false
                        for (slot, call) in calls.enumerated() {
                            if denied {
                                // A previous call in this batch was denied:
                                // skip without executing, but pair the call
                                // with a result envelope so the assistant
                                // `tool_use` never dangles.
                                let envelope = ToolEnvelope.failure(
                                    kind: .rejected,
                                    message:
                                        "Skipped: an earlier tool call in this batch was rejected, so this call did not run.",
                                    tool: call.invocation.toolName
                                )
                                                    executions[slot] = AgentLoopToolExecution(
                                                        result: envelope,
                                                        isError: false
                                                    )
                                continue
                            }
                            do {
                                try await ToolRegistry.shared.resolvePermissionGate(
                                    name: call.invocation.toolName,
                                    argumentsJSON: call.invocation.jsonArguments
                                )
                                approved.append((slot, call.invocation, call.callId))
                            } catch {
                                                    let envelope = ToolEnvelope.fromError(
                                                        error,
                                                        tool: call.invocation.toolName
                                                    )
                                                    executions[slot] = AgentLoopToolExecution(
                                                        result: envelope,
                                                        isError: true
                                                    )
                                denied = true
                            }
                        }

                        // Phase 2 — approved calls execute in parallel.
                        // Captures are value-typed (the TaskGroup executor
                        // is @Sendable); the registry runs tool bodies off
                        // the MainActor so the calls genuinely overlap.
                        if !approved.isEmpty {
                            print(
                                "[Osaurus][Tool] Executing batch of \(approved.count) in parallel: \(approved.map { $0.invocation.toolName }.joined(separator: ", "))"
                            )
                            let turnIdForTools = assistantTurn.id
                            let results = await AgentToolLoop.runBatchInParallel(
                                approved.map { ($0.invocation, $0.callId) }
                            ) { inv, callId in
                                                    try await ChatExecutionContext.$toolExecutionScope.withValue(
                                                        toolScope
                                                    ) {
                                    try await ChatExecutionContext.$currentSessionId.withValue(
                                        todoSessionIdForRun
                                    ) {
                                                            try await ChatExecutionContext.$currentAssistantTurnId
                                                                .withValue(turnIdForTools) {
                                                                    try await ChatExecutionContext.$currentToolCallId
                                                                        .withValue(callId) {
                                                try await ToolRegistry.shared.execute(
                                                    name: inv.toolName,
                                                    argumentsJSON: inv.jsonArguments,
                                                    permissionGateResolved: true
                                                )
                                            }
                                        }
                                    }
                                }
                            }

                            // Phase 3 — post-process on the MainActor, in
                            // model order: hot-loaded tools, artifacts,
                            // secret prompts. Turn recording is deferred to
                            // `onBatchComplete` (slot order).
                            for (entry, execution) in zip(approved, results) {
                                if execution.isError {
                                    // Registry threw — surfaced exactly like
                                    // the serial catch path.
                                    executions[entry.slot] = execution
                                } else {
                                    executions[entry.slot] = await postProcessToolResult(
                                        entry.invocation,
                                        callId: entry.callId,
                                        resultText: execution.result
                                    )
                                }
                            }
                        }

                        return executions.map { $0 ?? AgentLoopToolExecution(result: "") }
                    }

                    // One-shot mid-run token notice, mirroring the iteration-
                    // budget warning: fired the first time the conversation
                    // estimate crosses 90% of the history budget so the model
                    // wraps up instead of relying on compaction forever.
                    var tokenBudgetNoticeFired = false

                    // The canonical loop skeleton — iteration budget + warning
                    // notice, consecutive-identical dedupe replay, task-state
                    // recording, next-step bias staging, rejection policy —
                    // lives in `AgentToolLoop`. These hooks carry everything
                    // the chat surface owns: turn history, streaming UI,
                    // TaskLocal scoping, and the agent-loop intercepts.
                    var loopHooks = AgentLoopHooks(
                        isCancelled: { !self.isRunActive(runId) },
                        buildMessages: { notices in
                            // Mid-run steering: a text-only message queued
                            // during the run joins the conversation at this
                            // iteration boundary instead of waiting for the
                            // run to finish (or requiring Stop).
                            // A steer that lands here starts a new user
                            // message: the state notices the driver staged for
                            // the previous message no longer describe this one.
                            let notices = self.injectQueuedSteerIfEligible()
                                ? AgentToolLoop.noticesSurvivingNewUserMessage(notices)
                                : notices

                            ttftTrace?.mark("build_messages_start")
                            var msgs = buildMessages()
                            ttftTrace?.mark("build_messages_done")

                            // Compact history that outgrew the window: middle
                            // tool results summarize first, oldest middle
                            // messages drop second; first user message + the
                            // recent pairs stay intact, and the system prefix
                            // is untouched. No-op while within budget.
                            let preTrimTokens = ContextBudgetManager.estimateTokens(for: msgs)
                                                let trimResult =
                                                    AgentLoopBudget.trimPreservingSystemPrefixReportingOverflow(
                                msgs,
                                with: loopBudgetManager,
                                watermark: self.compactionWatermark
                            )
                            msgs = trimResult.messages
                            let postTrimTokens = ContextBudgetManager.estimateTokens(for: msgs)
                            let savedTokens = preTrimTokens - postTrimTokens
                            if savedTokens > 0 {
                                self.budgetTracker.updateCompaction(savedTokens: savedTokens)
                            }
                            if let summary = self.conversationSummary {
                                self.budgetTracker.updateSummary(
                                    tokens: ContextBudgetManager.estimateTokens(
                                        for: summary.contextMessageText
                                    )
                                )
                            }

                            // Driver-staged `[System Notice]` lines (budget
                            // warning first, then dedupe/bias nudge) ride as
                            // transient messages — never persisted into
                            // `turns`, so they don't pollute later prompts. The
                            // shared helper keeps them KV-stable (see
                            // `AgentLoopBudget.appendingTransientNotices`).
                            msgs = AgentLoopBudget.appendingTransientNotices(notices, to: msgs)

                            // Mid-run near-limit notice: once the (post-trim)
                            // conversation estimate crosses 90% of the history
                            // budget, tell the model to wrap up — compaction
                            // remains the actual overflow handler, this is the
                            // early signal. Fired at most once per run, like
                            // the iteration-budget warning, and only when the
                            // history actually ends in an in-progress tool
                            // exchange: "wrap up the current work" is incoherent
                            // on a fresh user question (observed live — the
                            // notice landed as the trailing user-role message
                            // right after the real question and the model
                            // reasoned about the notice instead), and skipping
                            // it on non-tool tails also keeps reasoning-retry
                            // rebuilds byte-identical to the pre-attempt
                            // history. The tool tail is additionally the only
                            // placement where `appendingTransientNotices` is
                            // KV-stable. The system prefix is excluded — its
                            // tokens are reserved separately and the history
                            // budget already accounts for them.
                            let midRunToolTail = msgs.last?.role == "tool"
                            let historyBudget = loopBudgetManager.historyBudget
                            let historyTokens = ContextBudgetManager.estimateTokens(
                                for: msgs.filter { $0.role != "system" }
                            )
                            if !tokenBudgetNoticeFired,
                                midRunToolTail,
                                historyBudget > 0,
                                historyTokens >= Int(Double(historyBudget) * 0.9)
                            {
                                tokenBudgetNoticeFired = true
                                // Delegation nudge rides along when a spawn tool
                                // is actually in this run's frozen schema: a
                                // tight window is exactly when offloading bulk
                                // reading to a worker pays for itself.
                                let spawnVisible = toolSpecs.contains {
                                                        $0.function.name
                                                            == SubagentCapabilityRegistry.spawnAgentToolName
                                        || $0.function.name
                                            == SubagentCapabilityRegistry.spawnModelToolName
                                }
                                msgs = AgentLoopBudget.appendingTransientNotices(
                                    [
                                        AgentToolLoop.contextNearLimitNotice(
                                            spawnAvailable: spawnVisible
                                        )
                                    ],
                                    to: msgs
                                )
                            }

                            // Memory + screen context ride the latest user
                            // message as a FROZEN turn prefix (see
                            // `freezeInjectedContextOntoLatestUserTurn`), so
                            // `buildMessages()` already rendered them and the
                            // trimmer/watermark above saw the final bytes.
                            // The current turn's injected block is attributed
                            // to its own budget rows (Memory / Screen
                            // Context), so subtract it from the Conversation
                            // total; PAST turns' frozen prefixes are genuine
                            // history bytes and stay counted here.
                            let currentInjectedTokens =
                                self.turns.last(where: { $0.role == .user })?
                                .injectedContextPrefix
                                .map { ContextBudgetManager.estimateTokens(for: $0) } ?? 0
                            // The dedicated AppleScript app-name hint is part of
                            // the conversation, not the opt-in Screen Context
                            // budget row. Add its tokens back after excluding
                            // the memory/screen prefix from Conversation.
                            let automationContextTokens =
                                appleScriptWorkingContext.map {
                                    ContextBudgetManager.estimateTokens(for: $0)
                                } ?? 0
                            // The LLM compaction summary message rides inside
                            // `msgs` but has its own budget row (set above), so
                            // exclude it from the Conversation total.
                            let summaryMessageTokens =
                                self.conversationSummary.map {
                                    ContextBudgetManager.estimateTokens(for: $0.contextMessageText)
                                } ?? 0
                            let convTokens =
                                msgs
                                .filter { $0.role != "system" }
                                                    .reduce(0) {
                                                        $0 + ContextBudgetManager.estimateTokens(for: $1.content)
                                                    }
                                - max(0, currentInjectedTokens - automationContextTokens)
                                - summaryMessageTokens
                            self.budgetTracker.updateConversation(
                                tokens: max(0, convTokens),
                                finishedOutputTurn: assistantTurn
                            )

                            // `overBudget` (protected first message + tail
                            // alone exceed the budget after every compaction
                            // lever) ends the run with a distinct exit
                            // instead of sending a doomed request.
                            return AgentLoopIterationInput(
                                messages: msgs,
                                overBudget: trimResult.overBudget
                            )
                        },
                        modelStep: { msgs, attempt in
                            let iterationToolSpecs = toolScope.modelVisibleSpecs
                            ttftTrace?.set("messageCount", msgs.count)
                            ttftTrace?.set("conversationTurns", self.turns.count)

                            #if DEBUG
                                // Dump full prompt to debug log for TTFT analysis
                                if attempt == 1 {
                                    var promptDump = "═══ FULL PROMPT DUMP ═══\n"
                                    for (i, m) in msgs.enumerated() {
                                                            promptDump +=
                                                                "── [\(i)] role=\(m.role) chars=\(m.content?.count ?? 0) ──\n"
                                        promptDump += (m.content ?? "(nil)") + "\n"
                                    }
                                    if let tools =
                                        iterationToolSpecs.isEmpty ? nil : iterationToolSpecs
                                    {
                                        promptDump += "── TOOLS (\(tools.count)) ──\n"
                                        for t in tools {
                                                                promptDump +=
                                                                    "  - \(t.function.name): \(t.function.description ?? "")\n"
                                        }
                                    }
                                    promptDump += "═══ END PROMPT DUMP ═══"
                                    debugLog(promptDump)
                                }
                            #endif
                            let requestedToolChoice = ChatToolChoicePolicy.resolve(
                                tools: iterationToolSpecs,
                                userText: trimmed,
                                attempt: attempt
                            )
                            forcedToolGate.arm(requestedToolChoice)
                            var req = ChatCompletionRequest(
                                // Mode 2: the wire omits the model and routing is
                                // by provider id, so don't pass the local
                                // `selectedModel` — it can lag the async agent pin
                                // and would only leak a stale prefix internally.
                                model: self.isRemoteAgentTarget
                                    ? "default" : (turnModelId ?? "default"),
                                messages: msgs,
                                temperature: effectiveTemp,
                                max_tokens: effectiveMaxTokensForAgent,
                                stream: true,
                                top_p: chatCfg.topPOverride,
                                frequency_penalty: nil,
                                presence_penalty: nil,
                                stop: nil,
                                n: nil,
                                tools: iterationToolSpecs.isEmpty ? nil : iterationToolSpecs,
                                tool_choice: requestedToolChoice,
                                session_id: self.sessionId?.uuidString
                            )
                            req.samplingParametersAreImplicit = true
                            req.claudeCodeOptions = self.claudeCodeRunOptions(for: turnAgentId)
                            // Mode 2 routing signal: tells `RemoteProviderService`
                            // to target the peer's `/agents/{address}/run`
                            // endpoint (remote agent runs fully server-side). The
                            // local `model` placeholder above is dropped from the
                            // wire entirely (`RemoteChatRequest.encode`), so the
                            // peer resolves its own live effective model. False =
                            // Mode 1 (plain remote inference via
                            // `/chat/completions`).
                            req.runAsRemoteAgent = self.isRemoteAgentTarget
                            req.cacheStableSystemPrefix =
                                self.isRemoteAgentTarget ? nil : context.staticPrefix
                            // Mode 2 routing: target the selected agent's
                            // provider directly (by id), so a stale
                            // `selectedModel` can never redirect the run to a
                            // different local provider. `ChatEngine` resolves
                            // the service from this id and ignores the model
                            // string for agent runs.
                            req.remoteAgentProviderId =
                                self.isRemoteAgentTarget
                                ? self.windowState?.selectedDiscoveredAgentProviderId : nil
                            // Insights fidelity: in Mode 2 the wire omits the
                            // model, so log the agent's live effective model
                            // instead of the local prefixed fallback.
                            req.remoteAgentLogModel =
                                self.isRemoteAgentTarget
                                ? self.windowState?.pinnedRemoteAgentEffectiveModel : nil
                            // Freeze agent semantics for the whole logical run.
                            // Tool schemas stay present on ordinary iterations,
                            // but the cap finalizer below intentionally removes
                            // them; the explicit marker keeps both paths on the
                            // same reasoning policy.
                            req.isAgentRequest =
                                !iterationToolSpecs.isEmpty || self.isRemoteAgentTarget
                            turnGenerationControls.apply(to: &req)
                            req.backgroundModelLoad = (self.loadIntent == .background)
                            req.ttftTrace = ttftTrace
                            // Correlate the Insights log this send produces back to the
                            // assistant turn, so the per-message "Insights" button can
                            // open this exact response.
                            req.turnId = assistantTurn.id
                            // Stable per-logical-step idempotency token. The
                            // agent loop holds `attempt` constant across
                            // transient retries (it decrements then re-increments
                            // on retryWithoutCharge), so a re-POST reuses this key
                            // and the router dedupes the charge; a genuinely new
                            // step gets a fresh key and bills normally. A user
                            // Retry starts a new run (new runId) and re-bills by
                            // design. `attempt` alone is not collision-safe:
                            // budget-refunded iterations (data-movement relief,
                            // empty-turn nudges) also reuse the counter but with
                            // a CHANGED body, which the router 409s as
                            // IDEMPOTENCY_CONFLICT — the body fingerprint suffix
                            // keys those as distinct requests while identical
                            // retryWithoutCharge re-POSTs still dedupe.
                            req.idempotencyKey =
                                "\(runId.uuidString):\(attempt):"
                                + AgentToolLoop.recoveryAwareIdempotencySuffix(
                                    messages: msgs,
                                    incompleteReasoningRetryOrdinal:
                                        incompleteReasoningRetryOrdinal
                                )
                            debugLog(
                                "send: attempt=\(attempt) model=\(req.model) tools=\(req.tools?.count ?? 0) sessionId=\(req.session_id ?? "nil")"
                            )
                            // Cache-fingerprint diagnostic: one `[Cache]` log line +
                            // matching TTFT fields per send so we can audit KV reuse
                            // without instrumenting MLX. Helper lives on the store
                            // so the turn counter + previous-hint comparison sit
                            // next to the state they describe. Passing the outbound
                            // messages adds the conversation-level line — reused vs
                            // re-prefilled history tokens per send — which is the
                            // tripwire for cross-turn byte divergence (frozen turn
                            // prefixes keep it near-total reuse).
                            if let sid = self.sessionId {
                                await SessionToolStateStore.shared.recordSend(
                                    sessionId: self.sessionStateKey(sid),
                                    cacheHint: context.cacheHint,
                                    trace: ttftTrace,
                                    conversation: msgs
                                )
                            }
                            do {
                                let streamStartTime = Date()
                                let (invocations, finalTurn) = try await self.processStreamDeltas(
                                    stream: try await engine.streamChat(request: req),
                                    assistantTurn: assistantTurn,
                                    runId: runId,
                                    streamStartTime: streamStartTime,
                                    ttftTrace: ttftTrace,
                                    selectedModel: turnModelId
                                )
                                assistantTurn = finalTurn
                                // Stream finished naturally without a tool call — reset
                                // the transient-retry budget so a future, unrelated
                                // failure later in the conversation gets a fresh
                                // allowance.
                                if invocations.isEmpty {
                                    transientRetries = 0
                                    if assistantTurn.terminalStopReason == "length",
                                        assistantTurn.pendingToolArgSize > 0
                                    {
                                        let pendingName =
                                            assistantTurn.pendingToolName
                                            == ToolDisplayName.pendingToolSentinel
                                            ? nil : assistantTurn.pendingToolName
                                        let argumentCharacters = assistantTurn.pendingToolArgSize
                                        assistantTurn.pendingToolName = nil
                                        assistantTurn.clearPendingToolArgs()
                                        self.rebuildVisibleBlocks()
                                        return .truncatedToolCall(
                                            toolName: pendingName,
                                            argumentCharacters: argumentCharacters
                                        )
                                    }
                                    return AgentLoopModelStep.classifyTerminal(
                                        contentIsBlank: assistantTurn.contentIsBlank,
                                        thinkingIsBlank: assistantTurn.thinkingIsBlank,
                                        stopReason: assistantTurn.terminalStopReason,
                                        unclosedReasoning: assistantTurn.unclosedReasoning,
                                        requiresVisibleFinalResponse:
                                            AgentLoopVisibleResponsePolicy
                                            .requiresVisibleFinalResponse(
                                                hasStructuredToolWork:
                                                    hasStructuredToolWorkThisRun,
                                                isRemoteAgentTarget:
                                                    self.isRemoteAgentTarget
                                            ),
                                        // On the first turn no tool has run yet,
                                        // so `requiresVisibleFinalResponse` is
                                        // false and a reasoning-only stop would
                                        // otherwise count as a finished answer.
                                        toolsWereOffered: !iterationToolSpecs.isEmpty,
                                        // Lets the classifier tell a real
                                        // answer from a bare "Let me write
                                        // the first batch:" preamble whose
                                        // tool call never arrived.
                                        content: assistantTurn.contentIsBlank
                                            ? nil : assistantTurn.content,
                                        // Set only when the stream consumer
                                        // cut the turn on a repetition loop.
                                        repetitionLoopPhrase:
                                            assistantTurn.repetitionLoopPhrase
                                    )
                                }
                                hasStructuredToolWorkThisRun = true
                                return .toolCalls(invocations)
                            } catch let oversized as OversizedStreamingToolCall {
                                print(
                                    "[Osaurus] Oversized streamed tool call "
                                        + "tool=\(oversized.toolName ?? "unknown") "
                                        + "chars=\(oversized.argumentCharacters); retrying with chunking notice"
                                )
                                assistantTurn.pendingToolName = nil
                                assistantTurn.clearPendingToolArgs()
                                self.rebuildVisibleBlocks()
                                return .oversizedToolCall(
                                    toolName: oversized.toolName,
                                    argumentCharacters: oversized.argumentCharacters
                                )
                            } catch let error as RemoteProviderServiceError {
                                // Transient provider-side stream errors — most commonly
                                // mid-tool-args truncation flagged by
                                // `RemoteProviderService.makeToolInvocation`'s
                                // `wasRepaired` guard. Silently retry the same
                                // iteration up to `maxTransientRetries` times before
                                // surfacing to the user; the model can't see what it
                                // actually streamed last time so it would just retry
                                // with the same broken args.
                                if error.isTransientStreamRetryable,
                                    transientRetries < maxTransientRetries
                                {
                                    transientRetries += 1
                                    print(
                                        "[Osaurus] Transient stream error (retry \(transientRetries)/\(maxTransientRetries)): \(error.localizedDescription)"
                                    )
                                    // Roll back any partial UI state from the failed
                                    // attempt so the retry starts clean.
                                    assistantTurn.pendingToolName = nil
                                    assistantTurn.clearPendingToolArgs()
                                    self.rebuildVisibleBlocks()
                                    // Not charged against the tool-iteration budget.
                                    return .retryWithoutCharge
                                }
                                throw error
                            }
                        },
                        prepareIncompleteReasoningContinuation: {
                            // Keep the model's real reasoning-only attempt in
                            // the UI transcript but permanently exclude that
                            // abandoned protocol attempt from model history.
                            // Stream the one natural retry into a fresh turn so
                            // a retry tool call and its result remain a valid,
                            // uncontaminated assistant/tool pair. No prompt,
                            // tags, or decode controls are injected here.
                            debugLog(
                                "send: reasoning-only agent step ended without visible answer; "
                                    + "retrying exact pre-attempt history "
                                    + "stop=\(assistantTurn.terminalStopReason ?? "nil") "
                                    + "unclosed=\(assistantTurn.unclosedReasoning) "
                                    + "reasoningChars=\(assistantTurn.thinkingLength)"
                            )
                            assistantTurn.modelContextExcluded = true
                            let retryTurn = ChatTurn(role: .assistant, content: "")
                            self.turns.append(retryTurn)
                            assistantTurn = retryTurn
                            incompleteReasoningRetryOrdinal += 1
                            self.rebuildVisibleBlocks()
                        },
                        prepareTrackedTaskContinuation: {
                            // The driver observed a successful current-run Todo
                            // with structured pending items at an ordinary final.
                            // Keep the real response visible, but exclude that
                            // abandoned terminal attempt from model history
                            // before giving the bounded loop a fresh assistant
                            // buffer. Otherwise the next persisted tool call is
                            // adjacent to an assistant final after the transient
                            // Todo notice disappears. No prose classifier,
                            // reasoning marker, sampler, or decode setting is
                            // involved.
                            debugLog(
                                "send: current-run todo still has unchecked work at model stop; "
                                    + "excluding abandoned final and continuing within the "
                                    + "configured tool-attempt budget"
                            )
                            Self.excludeAbandonedTrackedTaskResponse(assistantTurn)
                            let nextAssistantTurn = ChatTurn(role: .assistant, content: "")
                            self.turns.append(nextAssistantTurn)
                            assistantTurn = nextAssistantTurn
                            self.rebuildVisibleBlocks()
                        },
                        willProcessCall: { inv, callId in
                            // Recorded history uses the secret-safe view;
                            // execution still receives the original `inv`.
                            let call = SecretArgumentScrubber.recordedToolCall(
                                id: callId,
                                invocation: inv
                            )
                            assistantTurn.pendingToolName = nil
                            assistantTurn.clearPendingToolArgs()
                            if assistantTurn.toolCalls == nil { assistantTurn.toolCalls = [] }
                            assistantTurn.toolCalls!.append(call)
                            // Start the duration timer now; the call renders running
                            // until `recordToolTurn` lands the result after execution.
                            assistantTurn.markToolCallStarted(callId)

                            // Materialise the tool-call row BEFORE we await
                            // execute(...). Without this the chat skips
                            // straight from `pendingToolCall` (args still
                            // streaming) to `toolCallGroup` with the result
                            // already attached — `NativeToolCallRowView`
                            // never gets a chance to render with
                            // `item.result == nil`, so its inline live-
                            // streaming pane (TerminalDisplayView) never mounts
                            // for sandbox_exec / shell_run. Rebuilding here
                            // emits the row with a nil result; the row
                            // subscribes to LiveExecRegistry and starts
                            // streaming the moment the tool body registers
                            // its sink.
                            self.rebuildVisibleBlocks()
                        },
                        onDedupedResult: { _, _, _ in
                            // Consecutive-identical dedupe: the driver replayed
                            // the EXACT envelope the model already received —
                            // never a collapsed/summarized form — so the
                            // short-circuit is neutral and never hands back
                            // less than it had. The replayed outcome rides the
                            // driver's slotted outcomes, so `onBatchComplete`
                            // persists its turn in slot (model) order — an
                            // inline append here would land deferred replays
                            // AFTER their executed siblings.
                        },

                        executeTool: { inv, callId in
                            // Serial single-call path (used when no batch
                            // executor is installed; kept for parity).
                            await executeSingleToolCall(inv, callId: callId)
                        },
                        executeBatch: { calls in
                            // Approval-aware parallel batches: approvals
                            // serial in model order, execution concurrent,
                            // post-processing back in model order.
                            await executeToolBatch(calls)
                        },
                        onBatchComplete: { outcomes in
                            guard !outcomes.isEmpty else { return }
                            // Slot-order turn persistence (mirrors HTTP): the
                            // driver hands outcomes in the model's call order
                            // — executed results, denials, and dedupe replays
                            // alike — so the transcript and session save
                            // always match the order the model asked for.
                            // Intercept slots are excluded by the driver
                            // (they wrote their own history); the intercept
                            // serial fallback appends inline, so skip call
                            // ids that already have a tool turn.
                            var appendedAny = false
                            for outcome in outcomes {
                                let exists = self.turns.contains {
                                    $0.role == .tool && $0.toolCallId == outcome.callId
                                }
                                guard !exists else { continue }
                                self.turns.append(
                                    recordToolTurn(outcome.result, callId: outcome.callId)
                                )
                                appendedAny = true
                            }
                            if appendedAny {
                                // One fresh assistant turn for subsequent
                                // content so tool calls and following prose
                                // render sequentially (previously created
                                // per-call by the post-processor).
                                let newAssistantTurn = ChatTurn(role: .assistant, content: "")
                                self.turns.append(newAssistantTurn)
                                assistantTurn = newAssistantTurn
                            }
                            self.rebuildVisibleBlocks()
                        },
                        pendingTodoCount: {
                            // Feeds the driver's staleness nudge — todo is
                            // session-scoped, so only chat provides this.
                                                guard
                                                    let todo = await AgentTodoStore.shared.todo(
                                for: todoSessionIdForRun
                            )
                            else { return 0 }
                            return todo.totalCount - todo.doneCount
                        },
                        todoProgressSnapshot: {
                                                guard
                                                    let todo = await AgentTodoStore.shared.todo(
                                for: todoSessionIdForRun
                                                    )
                                                else { return nil }
                            return AgentTodoProgressSnapshot(
                                done: todo.doneCount,
                                total: todo.totalCount
                            )
                        },
                        emitFallbackText: { text in
                            // Empty-turn recovery exhausted: render a visible
                            // message into the assistant turn so the user never
                            // sees a silent "No visible text was produced".
                            // The same hook finalises the narrowly recovered
                            // post-success desktop-tool repeat. Clear any
                            // committed pending preview first so a suppressed
                            // malformed call cannot leave a tool card spinning.
                            assistantTurn.pendingToolName = nil
                            assistantTurn.clearPendingToolArgs()
                            if text == AgentToolLoop.lengthExhaustedFallback {
                                assistantTurn.content =
                                    AgentLoopModelStep.contentWithLengthFallback(
                                        assistantTurn.content,
                                        fallback: text
                                    )
                            } else {
                                assistantTurn.appendContentAndNotify(text)
                            }
                            self.rebuildVisibleBlocks()
                        },
                        emitToolRejectionText: { message in
                            // Chat intentionally stops after an interactive
                            // denial or terminal tool failure so the model
                            // cannot retry a side effect or hallucinate its
                            // result. Close that stopped turn visibly with the
                            // canonical envelope message instead of leaving a
                            // blank assistant bubble / eternal-looking task.
                            assistantTurn.pendingToolName = nil
                            assistantTurn.clearPendingToolArgs()
                            let prefix = L("The requested action was not completed.")
                            let visible = message.isEmpty ? prefix : prefix + " " + message
                            let separator = assistantTurn.contentIsEmpty ? "" : "\n\n"
                            assistantTurn.appendContentAndNotify(separator + visible)
                            self.rebuildVisibleBlocks()
                        },
                        finalVisibleText: {
                            // Grounded-claim check scope: only runs where the
                            // configure surface is actually offered, so agents
                            // without `osaurus_config` are never second-guessed
                            // about changes made through their own tools.
                            guard
                                toolScope.modelVisibleSpecs.contains(where: {
                                    $0.function.name == GroundedConfigClaimCheck.configToolName
                                })
                            else { return nil }
                            return assistantTurn.content
                        },
                        prepareGroundedClaimRetry: {
                            // Same persistence-backed boundary as the tracked-
                            // task continuation: the ungrounded final stays
                            // visible in the transcript (the user sees the
                            // model correct itself), but it is excluded from
                            // the next model request so the retry's history
                            // stays a valid assistant/tool sequence. No model
                            // text is edited or synthesized here.
                            debugLog(
                                "send: grounded-claim guard staged a corrective notice; "
                                    + "excluding ungrounded final and retrying"
                            )
                            assistantTurn.modelContextExcluded = true
                            let retryTurn = ChatTurn(role: .assistant, content: "")
                            self.turns.append(retryTurn)
                            assistantTurn = retryTurn
                            self.rebuildVisibleBlocks()
                        },
                        assistantVisibleText: {
                            // Ungated sibling of `finalVisibleText` for the
                            // file side-effect advisory: read BEFORE
                            // `onBatchComplete` swaps in a fresh buffer, so a
                            // tool-calling message's narration is what the
                            // loop sees, not the empty next turn.
                            assistantTurn.content
                        }
                    )
                    // What this run may execute, read live: the driver folds
                    // `osaurus_help!!` onto `osaurus_help` only when the
                    // canonical name is in scope, and lists these names in the
                    // `tool_not_found` notice. Assigned after construction so
                    // the hooks literal above stays type-checkable.
                    loopHooks.authorizedToolNames = { toolScope.authorizedNames }
                    // The announce-only nudge classifies the rest of the
                    // registry against the same live scope: callable now,
                    // one load away, or blocked until a folder is attached.
                    loopHooks.announcedToolCallRecovery = {
                        ToolRegistry.shared.announcedToolCallRecovery(
                            exposed: toolScope.authorizedNames,
                            agentId: effectiveAgentId,
                            loaderPermitted: { toolScope.permits($0) }
                        )
                    }

                    let loopStartedAt = Date()
                    let runResult = try await AgentToolLoop.run(
                        policy: AgentLoopPolicy(
                            maxIterations: maxAttempts,
                            budgetWarningThreshold: 0,
                            stopOnToolRejection: true,
                            dedupeNoticeEnabled: false,
                            todoStalenessThreshold: .max,
                            maxDataMovementSteps: min(16, maxAttempts),
                            todoRequiredBeforeToolCallCount: 0
                        ),
                        state: taskState,
                        hooks: loopHooks
                    )

                    print(
                        "[Osaurus][Loop] exit=\(runResult.exit) iterations=\(runResult.iterations) "
                            + "elapsedMs=\(Int(Date().timeIntervalSince(loopStartedAt) * 1000))"
                    )
                    if runResult.exit == .toolRejected {
                        // A rejected/failed tool row is already recorded in
                        // history for the user and for the model-visible
                        // transcript. Classify the run as errored for
                        // lifecycle cleanup so `completeRunCleanup` does not
                        // schedule a hidden completed-transcript warm-up over
                        // the failed intermediate state. That warm-up can own
                        // the solo lease and rebuild a different cache
                        // fingerprint immediately after a tool failure,
                        // making the next send look like a cold prefill.
                        lastStreamError = "Tool call failed."
                        // The turn that closed on the rejection is terminal:
                        // stamp it so the persisted row can be told apart
                        // from an in-flight step (an Ornith research run
                        // that ended this way left NULL, indistinguishable
                        // from a run still working). Never "cancelled" — the
                        // stop path keeps its own marker for that.
                        // `assistantTurn` may already be the fresh, empty
                        // placeholder the batch path swaps in after a tool
                        // result (run 070139 stamped a blank row); stamp the
                        // turn that actually closed on the rejection — the
                        // last assistant turn with content or a call.
                        if let closing = turns.last(where: {
                            $0.role == .assistant && !Self.isEmptyAssistantPlaceholder($0)
                        }), closing.terminalStopReason == nil {
                            closing.terminalStopReason = "tool_rejected"
                        }
                    }

                    if runResult.exit == .overBudget {
                        // Even fully-compacted history can't fit the model
                        // window — the driver ended the run before sending a
                        // doomed request. Surface the distinct failure on the
                        // assistant bubble instead of a generic stream error.
                        // Name the user's cap when that is the ceiling, so the
                        // advice points at the setting that decided the number
                        // rather than at a model window that had room.
                        var overBudgetWindowSource: AgentLoopBudget.ContextWindowSource?
                        if let overBudgetModel = turnModelId {
                            overBudgetWindowSource = AgentLoopBudget
                                .resolveContextWindowResolutionSync(modelId: overBudgetModel)
                                .source
                        }
                        let overBudgetText = AgentToolLoop.overBudgetMessage(
                            windowSource: overBudgetWindowSource)
                        assistantTurn.content = overBudgetText
                        lastStreamError = overBudgetText
                        rebuildVisibleBlocks()
                    }

                    if runResult.exit == .lengthExhausted {
                        // The driver already appended a visible, truthful
                        // incomplete-state message. Mark lifecycle cleanup as
                        // failed so this capped reasoning-only turn cannot be
                        // announced or warmed as a completed agent task.
                        lastStreamError = AgentToolLoop.lengthExhaustedFallback
                    }

                    if runResult.exit == .emptyResponseExhausted {
                        // The driver already emitted a visible, honest message
                        // after repeated empty post-tool completions. Do not
                        // warm or index that incomplete tool run as success.
                        lastStreamError = AgentToolLoop.emptyToolTaskFallback
                    }

                    if runResult.exit == .incompleteReasoningExhausted {
                        // The typed exit owns no cross-surface text. Append the
                        // honest chat-native fallback here after the one
                        // bounded retry failed (or visible partial content made
                        // replay unsafe), then keep cleanup from warming or
                        // announcing this as a completed task.
                        assistantTurn.content =
                            AgentLoopModelStep.contentWithLengthFallback(
                                assistantTurn.content,
                                fallback: AgentToolLoop.incompleteReasoningFallback
                            )
                        rebuildVisibleBlocks()
                        lastStreamError = AgentToolLoop.incompleteReasoningFallback
                    }

                    if runResult.exit == .iterationCapReached && isRunActive(runId) {
                        if let pending = runResult.unfinishedTodoCount, pending > 0 {
                            // A current-run Todo hit the hard step cap. Do not
                            // launch the generic tool-free wrap-up stream: it
                            // can only guess at unfinished work, and treating
                            // it as clean would warm/index a partial task. The
                            // driver provides the typed pending count instead.
                            let message = AgentToolLoop.unfinishedTodoCapFallback(
                                pending: pending
                            )
                            assistantTurn.content = message
                            lastStreamError = message
                            rebuildVisibleBlocks()
                        } else {
                            do {
                                let trimmedFinalMessages =
                                    AgentLoopBudget.trimPreservingSystemPrefix(
                                        buildMessages(),
                                        with: loopBudgetManager,
                                        watermark: compactionWatermark
                                    )
                                // The final request intentionally has no tool
                                // schema. Make that boundary visible to the
                                // model as transient tool-role feedback (when
                                // the transcript ends in a tool result), so it
                                // reports unfinished work instead of imitating
                                // a tool/result envelope. Appending after trim
                                // preserves the same stable-prefix contract as
                                // ordinary loop notices.
                                let finalMessages =
                                    AgentLoopBudget.appendingTransientNotices(
                                        [AgentToolLoop.iterationCapWrapUpNotice],
                                        to: trimmedFinalMessages
                                    )
                                var finalReq = ChatCompletionRequest(
                                    model: turnModelId ?? "default",
                                    // Same watermark-trimmed view of history the
                                    // loop iterations used — the raw array can
                                    // exceed the window precisely when the cap
                                    // hits after heavy tool traffic.
                                    messages: finalMessages,
                                    temperature: effectiveTemp,
                                    max_tokens: effectiveMaxTokensForAgent,
                                    stream: true,
                                    top_p: chatCfg.topPOverride,
                                    frequency_penalty: nil,
                                    presence_penalty: nil,
                                    stop: nil,
                                    n: nil,
                                    tools: nil,
                                    tool_choice: nil,
                                    session_id: sessionId?.uuidString
                                )
                                finalReq.samplingParametersAreImplicit = true
                                finalReq.claudeCodeOptions = claudeCodeRunOptions(for: turnAgentId)
                                finalReq.runAsRemoteAgent = isRemoteAgentTarget
                                finalReq.cacheStableSystemPrefix =
                                    isRemoteAgentTarget ? nil : context.staticPrefix
                                // Carry the agent provider id on this path too so
                                // the route-by-provider invariant holds for *every*
                                // Mode 2 request — a `runAsRemoteAgent` send with no
                                // provider id would fall back to model-string
                                // routing (the exact mis-route this fix removes).
                                finalReq.remoteAgentProviderId =
                                    isRemoteAgentTarget
                                    ? windowState?.selectedDiscoveredAgentProviderId : nil
                                finalReq.remoteAgentLogModel =
                                    isRemoteAgentTarget
                                    ? windowState?.pinnedRemoteAgentEffectiveModel : nil
                                finalReq.isAgentRequest = !toolSpecs.isEmpty || isRemoteAgentTarget
                                turnGenerationControls.apply(to: &finalReq)
                                finalReq.backgroundModelLoad = (loadIntent == .background)
                                finalReq.turnId = assistantTurn.id
                                // Distinct logical step (the post-cap summarizing
                                // call) so it bills once and dedupes on its own
                                // connect-phase retry without colliding with the
                                // loop's per-iteration keys.
                                finalReq.idempotencyKey = "\(runId.uuidString):final"

                                // Route the capped-run wrap-up through the exact
                                // same typed sentinel decoder as every ordinary
                                // chat step. Feeding this stream directly into a
                                // StreamingDeltaProcessor leaked U+FFFE prefill and
                                // stats envelopes into ChatTurn.content (and then
                                // transcript exports) whenever the agent reached
                                // its iteration cap.
                                let (_, finalTurn) = try await processStreamDeltas(
                                    stream: try await engine.streamChat(request: finalReq),
                                    assistantTurn: assistantTurn,
                                    runId: runId,
                                    streamStartTime: Date(),
                                    ttftTrace: ttftTrace,
                                    selectedModel: turnModelId
                                )
                                assistantTurn = finalTurn
                                // A wrap-up that streamed only thinking (or
                                // nothing) leaves an empty bubble at the end
                                // of a capped run (seen live: 31 inspect
                                // calls, then a 23-token think-only final
                                // with `stop`). Show the honest status the
                                // notice asked for instead of nothing.
                                if finalTurn.contentIsBlank {
                                    finalTurn.content = AgentToolLoop.iterationCapEmptyWrapUpText
                                    rebuildVisibleBlocks()
                                }
                            } catch {
                                let message =
                                    "The agent reached the configured step limit, and its final wrap-up failed: "
                                    + error.localizedDescription
                                                    debugLog(
                                                        "send: final wrap-up call failed: \(error.localizedDescription)"
                                                    )
                                assistantTurn.content = message
                                lastStreamError = message
                                rebuildVisibleBlocks()
                            }
                        }
                    }
                } catch is CancellationError {
                    // Two distinct cancel sources land here and they need
                    // OPPOSITE turn-history outcomes:
                    //
                    //  1. User dismissed the privacy review sheet
                    //     (RemoteProviderService maps `reviewCanceled` →
                    //     `CancellationError`). The send never left the
                    //     device — drop the just-appended user + empty
                    //     assistant turns and restore the original draft
                    //     so the user can edit and resend without
                    //     retyping. Detected by `!stopRequested`: only
                    //     `stop()` flips that flag, and the review-cancel
                    //     path doesn't go through `stop()`.
                    //
                    //  2. User clicked Stop AFTER the engine started but
                    //     before the first delta (e.g. mid-engine-setup,
                    //     mid-prepare, network in-flight). The user turn
                    //     was deliberately sent — it MUST stay in the
                    //     transcript. `completeRunCleanup()` (called via
                    //     `finalizeRun` from `stop()`) will trim the
                    //     empty assistant placeholder; we just clear the
                    //     error here.
                    //
                    // Pre-PR behavior for case 2 was to let the
                    // CancellationError fall into the generic `catch`
                    // and surface "Error: cancelled" on the assistant
                    // bubble, which was its own bug. This branch fixes
                    // both cases.
                    lastStreamError = nil
                    if stopRequested {
                        debugLog("send: stop() cancelled mid-prepare — keeping user turn")
                    } else {
                        debugLog("send: cancelled before any delta — restoring draft")
                        shouldPersistConversationArtifacts = false
                        suppressQueuedSendFlushForCurrentRun = true
                        handleCancelledBeforeFirstDelta()
                    }
                } catch let pfError as PrivacyFilterPipelineError {
                    // Privacy filter blocked the send because it couldn't
                    // safely scrub (engine unavailable, substitution no-op,
                    // etc.). Distinct from `reviewCanceled` which is the
                    // user's deliberate Cancel and is mapped to
                    // `CancellationError` upstream. The user turn stays
                    // visible so they have the failed message in context;
                    // the assistant bubble surfaces the localized
                    // explanation (e.g. "Open Settings → Privacy to re-
                    // download…") instead of a generic "Error:" prefix.
                    debugLog("send: privacy filter blocked send — \(pfError.localizedDescription)")
                    assistantTurn.content = pfError.localizedDescription
                    lastStreamError = pfError.localizedDescription
                } catch {
                    let errorMessage = ChatErrorMessages.assistantMessage(for: error)
                    // Preserve any text the model already streamed before the
                    // failure (common when a remote agent disconnects
                    // mid-stream): append the error as a trailing notice
                    // instead of replacing the partial answer. Only overwrite
                    // when nothing was streamed yet so an empty bubble still
                    // shows the actionable error on its own.
                    let streamedSoFar = assistantTurn.content.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    if streamedSoFar.isEmpty {
                        assistantTurn.content = errorMessage
                    } else {
                        assistantTurn.content += "\n\n\(errorMessage)"
                    }
                    lastStreamError = error.localizedDescription
                    noteInsufficientFundsIfNeeded(error: error, blockedTurn: assistantTurn)
                }
            }  // ChatExecutionContext.$currentEnableThinking.withValue
            }  // ChatExecutionContext.$currentModelName.withValue
            }  // ChatExecutionContext.$currentUserRequest.withValue
            }  // ChatExecutionContext.$currentProjectId.withValue
            }  // ChatExecutionContext.$currentAgentId.withValue
            }  // ChatExecutionContext.$currentChatSessionBox.withValue
            }  // ChatExecutionContext.$currentSessionSource.withValue
            }  // ChatExecutionContext.$hostFolderIsDispatchTarget.withValue
            }  // ChatExecutionContext.$currentFolderRoot.withValue
        }
    }

    /// Drop the just-appended user + (empty) assistant turns when a
    /// send is cancelled before the network produced any data, and
    /// hand the original draft back to the input field. Called from
    /// the streaming Task's `catch is CancellationError` branch
    /// ONLY when the cancellation came from a privacy review
    /// dismissal (the `!stopRequested` branch). User-driven
    /// `stop()` keeps the user turn; see the catch handler's
    /// comments for the two-case rationale. User-visible result:
    /// privacy review cancel ⇒ text reappears in the composer, no
    /// error bubble.
    private func handleCancelledBeforeFirstDelta() {
        // Remove the trailing empty assistant turn (we always append
        // one before entering the stream — see `send(_:attachments:)`).
        if let last = turns.last, last.role == .assistant, last.contentIsEmpty {
            turns.removeLast()
        }
        if let rollback = turnsRollbackOnCancel {
            turns = rollback
            turnsRollbackOnCancel = nil
            appendedUserTurnForCurrentRun = false
            rebuildVisibleBlocks()
            savedDraftOnCancel = nil
            persistAfterCancelledBeforeFirstDelta()
            return
        }
        // Remove the user turn this run was attached to, if it's the
        // current trailing turn. Don't blindly drop the last turn —
        // queued sends or auxiliary turns might have landed between
        // the append and the cancel.
        if appendedUserTurnForCurrentRun, let last = turns.last, last.role == .user {
            turns.removeLast()
        }
        appendedUserTurnForCurrentRun = false
        rebuildVisibleBlocks()
        // Restore the typed draft. Concatenating onto whatever the
        // user has half-typed since hitting Send would be surprising,
        // so we just overwrite — in practice the input box is empty
        // (the composer wipes it on Send) and overwriting is exactly
        // the "put my text back" outcome the user expects.
        if let draft = savedDraftOnCancel {
            input = draft.text
            pendingAttachments = draft.attachments
        }
        savedDraftOnCancel = nil
        persistAfterCancelledBeforeFirstDelta()
    }

    private func snapshotTurnsForCancelRollback() -> [ChatTurn] {
        turns.map { ChatTurn(from: ChatTurnData(from: $0)) }
    }

    /// Undo the eager user-turn append from `send()`'s pre-send-handshake
    /// path when the post-handshake dispatch aborts (a run started or
    /// another window grabbed the local runtime while we waited). Restores
    /// the draft when asked so the user's text isn't silently dropped.
    private func rollbackPreAppendedUserTurn(
        _ turn: ChatTurn?,
        restoringDraft draft: (text: String, attachments: [Attachment])?
    ) {
        guard let turn else { return }
        if let index = turns.lastIndex(where: { $0.id == turn.id }) {
            turns.remove(at: index)
            rebuildVisibleBlocks()
        }
        if let draft, input.isEmpty, pendingAttachments.isEmpty {
            input = draft.text
            pendingAttachments = draft.attachments
        }
    }

    private func restoreTurnsRollbackAfterAbortedRegeneration() {
        guard let rollback = turnsRollbackOnCancel else { return }
        turns = rollback
        turnsRollbackOnCancel = nil
        appendedUserTurnForCurrentRun = false
        transientSessionIdForCurrentRun = nil
        rebuildVisibleBlocks()
        isDirty = false
        save()
    }

    private func persistAfterCancelledBeforeFirstDelta() {
        let transientId = transientSessionIdForCurrentRun
        transientSessionIdForCurrentRun = nil

        if turns.isEmpty, let id = transientId, sessionId == id {
            sessionId = nil
            title = "New Chat"
            autoTitleGenerationStarted = false
            clearFollowUpSuggestions()
            createdAt = Date()
            updatedAt = createdAt
            isDirty = false
            ChatSessionsManager.shared.delete(id: id)
            let key = sessionStateKey(id)
            Task { await SessionToolStateStore.shared.invalidate(key) }
            Task { await SessionRedactionStore.shared.invalidate(id.uuidString) }
            onSessionChanged?()
            return
        }

        guard !turns.isEmpty else { return }
        save()
    }
}

/// Backs the "also delete your message" checkbox in the delete-response
/// confirmation. Held as a `@StateObject` by `ChatView` and reset before each
/// prompt; observing it (rather than a plain `@State` binding) guarantees the
/// checkbox re-renders live inside the global themed-alert host.
@MainActor
final class DeleteMessageOptions: ObservableObject {
    @Published var alsoDeleteUserMessage: Bool = false
}

/// Checkbox rendered as the delete-response confirmation accessory. Ticking it
/// escalates the delete from "just this response" to the whole exchange.
private struct DeleteAlsoUserMessageToggle: View {
    @Environment(\.theme) private var theme
    @ObservedObject var options: DeleteMessageOptions

    var body: some View {
        Toggle(isOn: $options.alsoDeleteUserMessage) {
            Text("Also delete my message", bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
        }
        .toggleStyle(.checkbox)
    }
}

// MARK: - ChatView

struct ChatView: View {
    // MARK: - Window State

    /// Per-window state container (isolates this window from shared singletons)
    @ObservedObject private var windowState: ChatWindowState

    // MARK: - Environment & State

    @Environment(\.colorScheme) private var colorScheme

    @State private var focusTrigger: Int = 0
    @State private var isPinnedToBottom: Bool = true
    /// User-adjustable width of the History sidebar, persisted across launches
    /// so a chosen width sticks. Clamped to `sidebarWidthRange` on read so a
    /// stale out-of-bounds value can never wedge the layout.
    @AppStorage("chatSidebarWidth") private var storedSidebarWidth: Double = 240
    /// Transient width while an edge drag is in flight. Kept in view state so
    /// the resize tracks the cursor at 60fps without hitting UserDefaults on
    /// every frame; the final value is committed to `storedSidebarWidth` on
    /// drag end. `nil` means no drag is active.
    @State private var liveSidebarWidth: Double?
    /// Width captured at the start of a drag. `translation` is cumulative from
    /// the gesture start, so the live width is always `anchor + translation`
    /// (adding to the running live value would double-count the delta).
    @State private var sidebarDragAnchor: Double?
    /// Project whose detail page is shown in the content area (opened from
    /// the sidebar's Projects tab). nil shows the normal chat surface.
    /// Observed so project renames/edits re-render the open detail page.
    @ObservedObject private var projectManager = ProjectManager.shared
    @State private var scrollToBottomTrigger: Int = 0
    @State private var keyMonitor: Any?
    // Inline editing state
    @State private var editingTurnId: UUID?
    @State private var editText: String = ""
    @State private var userImagePreview: NSImage?
    /// Pasted-content attachment whose read-only preview sheet is showing.
    /// Set when the user taps a pasted-content chip in a sent message;
    /// cleared on dismiss.
    @State private var pastedContentPreview: Attachment?
    // Bonjour agent connection
    @State private var pendingDiscoveredAgent: DiscoveredAgent? = nil
    // Minimap
    @State private var activeMinimapTurnId: UUID?
    @State private var scrollToTurnId: UUID?
    @State private var scrollToTurnTrigger: Int = 0
    // In-conversation find (Cmd+F). Visibility lives on `windowState` so the
    // window-level key monitor can toggle it; query/matches are view state.
    @State private var findQuery: String = ""
    /// `findQuery` as of the last settled debounce. Everything downstream —
    /// match recompute, cell highlighting, the first-match jump — keys off
    /// this so nothing churns (or scrolls) on every keystroke.
    @State private var debouncedFindQuery: String = ""
    @State private var findDebounceTask: Task<Void, Never>?
    /// Arms the spinner: fires if a recompute is still pending (user typing
    /// continuously) beyond a grace period, so the field shows progress
    /// instead of jumping on stale results.
    @State private var findSpinnerTask: Task<Void, Never>?
    @State private var isFindSearchPending: Bool = false
    /// Off-main match scan in flight; superseded scans are cancelled.
    @State private var findComputeTask: Task<Void, Never>?
    /// Every `debouncedFindQuery` occurrence in the conversation, in order.
    @State private var findMatches: [ChatFindMatch] = []
    @State private var findMatchIndex: Int = 0
    /// Occurrence (within the turn) the last find jump targeted; nil when the
    /// pending scroll request came from the minimap instead of the find bar.
    @State private var scrollToFindOccurrence: Int?
    // What's New modal
    @State private var pendingWhatsNew: WhatsNewRelease? = nil
    @State private var showAutoSpeakPrompt: Bool = false
    /// Drives the confirmation before deleting an assistant response. The
    /// pending turn id is captured so the confirm button knows what to excise;
    /// `deleteMessageOptions.alsoDeleteUserMessage` is the dialog checkbox that
    /// decides whether the prompting user turn goes too. The warning gains an
    /// extra line when the response made tool calls or is folded into a
    /// compaction summary.
    @State private var showDeleteAssistantMessagePrompt: Bool = false
    @State private var pendingDeleteAssistantTurnId: UUID?
    @State private var deleteAssistantMessageWarning: String = ""
    @StateObject private var deleteMessageOptions = DeleteMessageOptions()
    /// Presents the credits top-up sheet, opened from the out-of-credits modal
    /// or the composer's credits chip.
    @State private var showTopUpSheet: Bool = false
    /// Observed so the post-top-up retry watcher reacts to balance changes; the
    /// balance auto-refreshes on app activation when returning from Stripe.
    @ObservedObject private var accountService = OsaurusRouterAccountService.shared
    /// Privacy-filter review sheet payload. Set by the
    /// `PrivacyReviewService` presenter registration in `.onAppear`;
    /// presented via `.sheet(item:)` below. Identifiable so SwiftUI
    /// re-presents the sheet on subsequent reviews in the same
    /// window without us having to manually clear it first.
    @State private var pendingRedactionReview: RedactionReviewState? = nil
    /// Opaque handle for this window's presenter registration with
    /// `PrivacyReviewService`. Kept in `@State` because the service is
    /// global and we must hand the same token back at teardown to
    /// avoid clobbering another window's registration (the previous
    /// implementation just called `unregisterPresenter()` with no
    /// arg, which silently disabled review for any other open window).
    @State private var privacyPresenterToken: PresenterToken? = nil

    /// Convenience accessor for the window's theme
    private var theme: ThemeProtocol { windowState.theme }

    /// Balance-aware copy for the out-of-credits modal.
    /// The run blocking this send, when it is a detached background task rather
    /// than another open window. `nil` means a visible window owns the slot and
    /// the original "wait for that reply" wording is accurate.
    private var blockingDetachedTaskId: UUID? {
        BackgroundTaskManager.shared.detachedTaskStreamingLocalModel(
            excludingSession: session)
    }

    /// The sibling TAB in this window whose local-model run holds the slot,
    /// if that is the blocker. Tabs share the single inference slot exactly
    /// like windows do, but the fix is one click away: jump to that tab.
    private var blockingSiblingTab: ChatTab? {
        windowState.tabs.first { $0.session !== session && $0.session.isStreamingLocalModel }
    }

    /// Telling someone to "wait for that reply to finish" is only true while a
    /// window still shows the reply. When the owning window was closed the run
    /// detaches and keeps the single local-model slot, so that sentence sends
    /// the user to look for something that does not exist — reported in #2343,
    /// where the only way out was restarting the app.
    private var localModelBusyMessage: String {
        if blockingDetachedTaskId != nil {
            return L(
                "Only one local model can run at a time. A reply is still running in the background from a chat window you closed. Reopen it to watch it finish, stop it to free the model, or switch this chat to a remote model."
            )
        }
        if blockingSiblingTab != nil {
            return L(
                "Only one local model can run at a time, and another tab in this window is using it right now. Wait for that reply to finish, stop it, or switch this chat to a remote model."
            )
        }
        return L(
            "Only one local model can run at a time, and another chat window is using it right now. Wait for that reply to finish, or switch this chat to a remote model."
        )
    }

    /// The cancel capability already existed (`BackgroundTaskManager.cancelTask`)
    /// and so did the reattach path (`openTaskWindow`); neither was reachable
    /// from the point where the user is actually blocked. Offer both here, and
    /// only here — this deliberately does not change whether a backgrounded run
    /// keeps the lock, which is a product decision left open in #2343.
    private var localModelBusyButtons: [AlertButtonConfig] {
        guard let taskId = blockingDetachedTaskId else {
            if let tab = blockingSiblingTab {
                return [
                    .destructive(L("Stop it")) { tab.session.stop() },
                    .primary(L("Go to that tab")) { windowState.selectTab(id: tab.id) },
                    .cancel(L("Not now")),
                ]
            }
            return [.cancel(L("OK"))]
        }
        return [
            .destructive(L("Stop it")) {
                BackgroundTaskManager.shared.cancelTask(taskId)
            },
            .primary(L("Reopen it")) {
                BackgroundTaskManager.shared.openTaskWindow(taskId)
            },
            .cancel(L("Not now")),
        ]
    }

    private var insufficientFundsMessage: String {
        String(
            localized:
                "Your balance is \(accountService.formattedBalance). Add credits to keep chatting.",
            bundle: .module,
            comment:
                "Message in the out-of-credits modal shown in chat; the placeholder is the current balance."
        )
    }

    /// Balance-aware copy for the post-top-up retry modal.
    private var creditsAddedRetryMessage: String {
        String(
            localized:
                "Your balance is now \(accountService.formattedBalance). Retry your last message to continue.",
            bundle: .module,
            comment:
                "Message in the credits-added retry modal shown in chat after a top-up; the placeholder is the new balance."
        )
    }

    /// Convenience accessor for the window ID
    private var windowId: UUID { windowState.windowId }

    /// True while any prompt overlay (secret, clarify) is mounted.
    /// Drives hit-testing on the message thread + main input bar so the
    /// active card owns the interaction. Single source of truth is
    /// `session.promptQueue.current`.
    private var isPromptOverlayActive: Bool {
        session.promptQueue.current != nil
    }

    /// Secret prompts intentionally obscure the thread; clarify prompts
    /// do not, because the user often needs the previous assistant text
    /// to understand why they are being asked to choose an option.
    private var promptOverlayObscuresConversation: Bool {
        session.promptQueue.current?.obscuresConversation == true
    }

    /// Picker items filtered to the active Bonjour provider's models when a
    /// remote agent is selected, or ALL models (local + user-configured
    /// remote providers) when no remote agent is active.
    ///
    /// Prior to this fix, the no-agent branch hid every `.remote` model
    /// from the picker — which was correct for keeping Bonjour-discovered
    /// models from leaking into the local-only view, but also suppressed
    /// manually-configured remote providers (Ollama, custom OpenAI
    /// endpoints, etc.). Since user-configured providers are always
    /// intentional, they should be visible regardless of Bonjour state.
    private var filteredPickerItems: [ModelPickerItem] {
        guard let providerId = windowState.selectedDiscoveredAgentProviderId else {
            // No remote agent selected (Mode 1 / local): show everything —
            // local, foundation, and user-configured remote providers, including
            // the device's own models so they can be picked for remote inference.
            return session.pickerItems
        }
        // Mode 2 (remote agent run): the model is pinned to the agent's own
        // model — surface ONLY the selected item so the picker can't switch it.
        // While the pin is still resolving (or the effective model isn't in the
        // device catalog), fall back to the provider's chat-capable models so
        // the chip still shows the right device instead of going blank.
        if let selected = session.selectedModel,
            let item = session.pickerItems.first(where: { $0.id == selected }),
            Self.isProviderItem(item, providerId: providerId)
        {
            return [item]
        }
        return session.pickerItems.filter { Self.isProviderItem($0, providerId: providerId) }
    }

    /// True when `item` is a remote model served by `providerId`.
    private static func isProviderItem(_ item: ModelPickerItem, providerId: UUID) -> Bool {
        if case .remote(_, let id) = item.source { return id == providerId }
        return false
    }

    /// The model id with its single provider-name prefix segment removed, e.g.
    /// `coco/mlx-community/Qwen3-4B` -> `mlx-community/Qwen3-4B`. Mirrors the
    /// `"<slug>/<modelId>"` prefixing done by `RemoteProviderManager`, so it
    /// recovers the device-side model id to compare against `effective_model`.
    private static func unprefixedModelTail(_ id: String) -> String {
        guard let slash = id.firstIndex(of: "/") else { return id }
        return String(id[id.index(after: slash)...])
    }

    /// Text for the pinned model chip (Mode 2). Resolves to the remote agent's
    /// live effective model when known — cleaned via the matching catalog item,
    /// else the raw id. While the effective model is still loading (or isn't in
    /// the device catalog), falls back to the remote agent's name, then
    /// "Default", so the chip never implies a specific device model that isn't
    /// the agent's. Returns nil when no remote agent is selected (the chip is
    /// interactive then and resolves its own label).
    private var pinnedModelChipLabel: String? {
        guard let providerId = windowState.selectedDiscoveredAgentProviderId else { return nil }
        if let effective = windowState.pinnedRemoteAgentEffectiveModel, !effective.isEmpty {
            if let item = session.pickerItems.first(where: {
                Self.isProviderItem($0, providerId: providerId)
                    && Self.unprefixedModelTail($0.id) == effective
            }) {
                return item.displayName
            }
            return effective
        }
        return windowState.selectedDiscoveredAgent?.name
            ?? windowState.selectedRelayAgent?.name
            ?? L("Default")
    }

    /// Compact Mode 2 connection status shown above the composer: an actionable
    /// error with Retry on failure. The connecting affordance lives in the
    /// empty-state security badge (which morphs "Securing connection…" -> lock),
    /// so this row only surfaces on `.failed`; it's empty otherwise and when
    /// not in remote-agent mode.
    @ViewBuilder
    private var remoteAgentConnectionNotice: some View {
        if windowState.selectedDiscoveredAgentProviderId != nil {
            switch windowState.remoteAgentConnectionPhase {
            case .failed(let message):
                connectionFailedNotice(message)
            case .idle, .connected, .connecting:
                // The connecting affordance now lives in the empty-state
                // security badge (it morphs "Securing connection…" -> lock),
                // so there's no separate connecting chip above the composer.
                EmptyView()
            }
        }
    }

    /// Run-liveness chip shown above the composer while a run has produced no
    /// stream/tool/image progress for a while. `slow` reassures ("still
    /// working"); `stalled` names the likely wedge and points at Stop — the
    /// recovery action — without auto-killing a run that may legitimately be
    /// deep in a long model load or tool call.
    @ViewBuilder
    private var runProgressNotice: some View {
        if observedSession.isStreaming {
            switch observedSession.runProgressState {
            case .active:
                EmptyView()
            case .slow:
                remoteAgentNoticeRow(tint: theme.accentColor) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L("Still working — waiting on the model or a tool…"))
                        .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                        .foregroundColor(theme.primaryText)
                }
            case .stalled:
                remoteAgentNoticeRow(tint: theme.warningColor) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: CGFloat(theme.captionSize), weight: .semibold))
                        .foregroundColor(theme.warningColor)
                    Text(L("No response for a while — this run may be stuck."))
                        .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: { observedSession.stop() }) {
                        Text(L("Stop"))
                            .font(theme.font(size: CGFloat(theme.captionSize), weight: .semibold))
                            .foregroundColor(theme.warningColor)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Connection-failure chip: the error message plus a Retry that re-runs the
    /// connect + model-pin flow.
    private func connectionFailedNotice(_ message: String) -> some View {
        remoteAgentNoticeRow(tint: theme.warningColor) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: CGFloat(theme.captionSize), weight: .semibold))
                .foregroundColor(theme.warningColor)
            Text(message)
                .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                .foregroundColor(theme.primaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: { retryRemoteAgentConnection() }) {
                Text(L("Retry"))
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .semibold))
                    .foregroundColor(theme.accentColor)
            }
            .buttonStyle(.plain)
        }
    }

    /// Shared chip chrome for the Mode 2 status rows (connecting / error): a
    /// content-hugging, centered rounded chip with a subtle tinted fill and
    /// hairline border, matching the empty-state security badge and the rest
    /// of the app's chrome. The `tint` conveys intent (accent while
    /// connecting, warning on failure) so the two phases differ only in their
    /// content and color, not their shape.
    @ViewBuilder
    private func remoteAgentNoticeRow<Content: View>(
        tint: Color,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.opacity(theme.isDark ? 0.14 : 0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(tint.opacity(0.22), lineWidth: 1)
            )
            .padding(.bottom, 8)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    /// Re-run the connect + model-pin flow after a failure (Retry button).
    private func retryRemoteAgentConnection() {
        guard let providerId = windowState.selectedDiscoveredAgentProviderId else { return }
        pinRemoteAgentModelAfterConnect(providerId: providerId)
    }

    /// Resolve and apply the pinned model for a selected remote agent (Mode 2).
    /// Prefers the agent's live effective model (`pinnedRemoteAgentEffectiveModel`,
    /// matched against the provider's prefixed picker ids); otherwise keeps an
    /// already-correct provider selection or falls back to the provider's first
    /// chat-capable model. Routing only needs the provider to be right — Mode 2
    /// sends `model: "default"` on the wire, so the agent's live model is always
    /// what actually runs.
    @MainActor
    private func applyRemoteAgentModelPin(providerId: UUID) {
        let items = session.pickerItems
        if let effective = windowState.pinnedRemoteAgentEffectiveModel,
            let item = items.first(where: {
                Self.isProviderItem($0, providerId: providerId)
                    && Self.unprefixedModelTail($0.id) == effective
            })
        {
            if session.selectedModel != item.id { session.selectedModel = item.id }
            return
        }
        let currentIsFromProvider =
            items.first(where: { $0.id == session.selectedModel })
            .map { Self.isProviderItem($0, providerId: providerId) } ?? false
        if !currentIsFromProvider,
            let first = items.filter({ Self.isProviderItem($0, providerId: providerId) }).firstChatCapable
        {
            session.selectedModel = first.id
        }
    }

    /// Observed session - needed to properly propagate @Published changes from ChatSession
    @ObservedObject private var observedSession: ChatSession

    /// Convenience accessor for the session (uses observedSession for proper SwiftUI updates)
    private var session: ChatSession { observedSession }

    // MARK: - Initializers

    /// Multi-window initializer with window state
    init(windowState: ChatWindowState) {
        _windowState = ObservedObject(wrappedValue: windowState)
        _observedSession = ObservedObject(wrappedValue: windowState.session)
    }

    /// Convenience initializer with window ID and optional initial state
    init(
        windowId: UUID,
        initialAgentId: UUID? = nil,
        initialSessionData: ChatSessionData? = nil
    ) {
        let agentId = initialSessionData?.agentId ?? initialAgentId ?? Agent.defaultId
        let state = ChatWindowState(
            windowId: windowId,
            agentId: agentId,
            sessionData: initialSessionData
        )
        _windowState = ObservedObject(wrappedValue: state)
        _observedSession = ObservedObject(wrappedValue: state.session)
    }

    var body: some View {
        let _ = ChatPerfTrace.shared.count("body.ChatView")
        chatModeContent
            .themedAlert(
                L("Do you want Osaurus to auto speak every reply in this chat?"),
                isPresented: $showAutoSpeakPrompt,
                message: L("This only applies to this chat."),
                primaryButton: .primary(L("Yes")) { session.autoSpeakAssistant = true },
                secondaryButton: .cancel(L("No"))
            )
            .themedAlert(
                L("Delete this response?"),
                isPresented: $showDeleteAssistantMessagePrompt,
                message: deleteAssistantMessageWarning.isEmpty ? nil : deleteAssistantMessageWarning,
                accessory: AnyView(DeleteAlsoUserMessageToggle(options: deleteMessageOptions)),
                buttons: [
                    .cancel(L("Cancel")),
                    .destructive(L("Delete")) { performDeleteAssistantMessage() },
                ]
            )
            .themedAlert(
                L("A local model is already running"),
                isPresented: $windowState.showLocalModelBusyAlert,
                message: localModelBusyMessage,
                buttons: localModelBusyButtons
            )
            .themedAlert(
                L("You're out of credits"),
                isPresented: $observedSession.insufficientFundsAlert,
                message: insufficientFundsMessage,
                primaryButton: .primary(L("Add credits")) { showTopUpSheet = true },
                secondaryButton: .cancel(L("Not now"))
            )
            .themedAlert(
                L("Credits added"),
                isPresented: $observedSession.topUpRetryAlert,
                message: creditsAddedRetryMessage,
                primaryButton: .primary(L("Retry")) { session.retryInsufficientFundsTurn() },
                secondaryButton: .cancel(L("Later")) { session.clearInsufficientFundsRetryState() }
            )
            .themedAlertScope(.chat(windowState.windowId))
            .overlay(ThemedAlertHost(scope: .chat(windowState.windowId)))
            .overlay { promptOverlayLayer }
            // Computer Use gated-action confirmations. Process-wide queue so
            // the in-tool loop (which has no ChatSession handle) can park a
            // request the user resolves; rendered above the input bar like the
            // other prompt cards.
            .overlay { ComputerUseConfirmOverlay() }
            // osaurus_config plan-review approvals: the dedicated diff card
            // every apply awaits. Same process-wide queue pattern as the
            // Computer Use card.
            .overlay { ConfigPlanApprovalCard() }
            .sheet(isPresented: $showTopUpSheet) {
                CreditsTopUpSheet()
                    .environment(\.theme, theme)
            }
            // First-run / progress dialog for LLM context compaction. The
            // sheet's dismissal (Esc, outside interaction) routes through the
            // session so a declined first run resumes the stashed send.
            .sheet(
                isPresented: Binding(
                    get: { observedSession.showCompactionDialog },
                    set: { isShown in
                        if !isShown, observedSession.showCompactionDialog {
                            observedSession.cancelCompactionDialog()
                        }
                    }
                )
            ) {
                CompactionDialogView(session: observedSession)
                    .environment(\.theme, theme)
            }
            .onChange(of: accountService.balance) { _, _ in
                session.handleBalanceChangeForRetry()
            }
            .onChange(of: session.promptQueue.current?.id) { _, newValue in
                // Hand keyboard focus back to the composer once the last
                // prompt resolves — it was hit-test disabled while the
                // overlay was up and nothing else refocuses it.
                if newValue == nil {
                    focusTrigger &+= 1
                }
            }
            .onChange(of: session.lastCompletedAssistantTurnId) { _, newValue in
                handleAssistantTurnCompleted(turnId: newValue)
            }
    }

    /// Shared overlay layer for in-chat prompts (secrets + clarify).
    /// Renders a subtle backdrop scrim behind the prompt card and
    /// switches between concrete overlays based on the current item in
    /// `session.promptQueue`. Keyed off `current?.id` so consecutive
    /// prompts crossfade in place rather than the new card snapping in.
    /// The scrim is intentionally non-dismissive (these are deliberate
    /// pauses, not modals); ESC still cancels via the card.
    @ViewBuilder
    private var promptOverlayLayer: some View {
        let current = session.promptQueue.current
        ZStack {
            if current != nil {
                Color.black
                    .opacity(
                        current?.obscuresConversation == true
                            ? (theme.isDark ? 0.28 : 0.18)
                            : (theme.isDark ? 0.10 : 0.06)
                    )
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .allowsHitTesting(true)
            }

            Group {
                switch current {
                case .secret(let s):
                    SecretPromptOverlay(state: s) {
                        session.promptQueue.advance()
                    }
                case .clarify(let c):
                    ClarifyPromptOverlay(state: c) {
                        session.promptQueue.advance()
                    }
                case .none:
                    EmptyView()
                }
            }
            .id(current?.id)
            .transition(.opacity)
        }
        .animation(theme.springAnimation(), value: current?.id)
    }

    /// Allowed range for the resizable sidebar. The floor keeps the header
    /// controls usable; the ceiling stops the sidebar from crowding out the
    /// chat on narrow windows.
    private static let sidebarWidthRange: ClosedRange<Double> = 260...460

    /// Clamp a raw width to the allowed range.
    private func clampSidebarWidth(_ raw: Double) -> Double {
        min(max(raw, Self.sidebarWidthRange.lowerBound), Self.sidebarWidthRange.upperBound)
    }

    /// Effective sidebar width: the live drag value while resizing, otherwise
    /// the persisted width. Always clamped.
    private var clampedSidebarWidth: CGFloat {
        CGFloat(clampSidebarWidth(liveSidebarWidth ?? storedSidebarWidth))
    }

    /// Draggable divider on the sidebar's trailing edge. A thin visible seam
    /// with a wider invisible hit area; dragging resizes the sidebar and the
    /// two-headed resize cursor telegraphs that it's grabbable.
    private var sidebarResizeHandle: some View {
        // An 11pt-wide interactive strip straddling the trailing edge (offset
        // pushes half of it past the border) so the seam is grabbable right at
        // the boundary. The visible seam is a 1pt line at the strip's center;
        // the AppKit cursor area fills the strip.
        Color.clear
            .frame(width: 11)
            .frame(maxHeight: .infinity)
            .overlay {
                Rectangle()
                    .fill(theme.secondaryText.opacity(liveSidebarWidth != nil ? 0.55 : 0.12))
                    .frame(width: 1)
            }
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .offset(x: 5)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        // Anchor to the width at gesture start so the rail
                        // tracks the cursor 1:1 without accumulating drift.
                        let anchor = sidebarDragAnchor ?? Double(clampedSidebarWidth)
                        if sidebarDragAnchor == nil {
                            sidebarDragAnchor = anchor
                        }
                        liveSidebarWidth = clampSidebarWidth(anchor + Double(value.translation.width))
                    }
                    .onEnded { _ in
                        if let final = liveSidebarWidth {
                            storedSidebarWidth = clampSidebarWidth(final)
                        }
                        liveSidebarWidth = nil
                        sidebarDragAnchor = nil
                    }
            )
    }

    /// Chat mode content - the original ChatView implementation
    @ViewBuilder
    private var chatModeContent: some View {
        GeometryReader { proxy in
            let sidebarWidth: CGFloat = windowState.showSidebar ? clampedSidebarWidth : 0
            let chatWidth = proxy.size.width - sidebarWidth
            let effectiveContentWidth = min(chatWidth, 1100)

            HStack(alignment: .top, spacing: 0) {
                // Sidebar
                VStack(alignment: .leading, spacing: 0) {
                    if windowState.showSidebar {
                        ChatSessionSidebar(
                            sessions: windowState.filteredSessions,
                            agentId: windowState.agentId,
                            currentSessionId: session.sessionId,
                            width: sidebarWidth,
                            onSelect: { data in
                                windowState.openProjectId = nil
                                windowState.enteredChatFromProjectPage = false
                                windowState.loadSession(data)
                                isPinnedToBottom = true
                            },
                            onNewChat: { projectId in
                                // The sidebar's own New Chat button passes nil:
                                // it is the explicit way to start a chat outside
                                // any project (⌘N stays in the current one).
                                if let project = projectManager.project(for: projectId) {
                                    windowState.startNewChat(in: project)
                                } else {
                                    windowState.openProjectId = nil
                                    windowState.enteredChatFromProjectPage = false
                                    windowState.startNewChat()
                                }
                            },
                            onDelete: { id in
                                // Deleting a chat is an explicit destructive
                                // action: cancel any registry-owned run still
                                // driving it so a background completion can't
                                // resurrect the deleted row on save.
                                if let liveTask = BackgroundTaskManager.shared.liveTask(forSessionId: id) {
                                    BackgroundTaskManager.shared.cancelTask(liveTask.id)
                                }
                                // Detach this window first (registry-shared
                                // instances are released, never reset in
                                // place) before the row is deleted.
                                windowState.prepareForSessionDeletion(id: id)
                                ChatSessionsManager.shared.delete(id: id)
                                windowState.refreshSessions()
                            },
                            onRename: { id, title in
                                ChatSessionsManager.shared.rename(id: id, title: title)
                                // Keep the open view-model in sync so the
                                // next auto-save doesn't clobber the rename.
                                if session.sessionId == id {
                                    session.title = title
                                }
                                windowState.refreshSessions()
                            },
                            onSetArchived: { id, archived in
                                ChatSessionsManager.shared.setArchived(id: id, archived: archived)
                                // Keep the open view-model in sync so the
                                // next auto-save doesn't clobber the flag.
                                if session.sessionId == id {
                                    session.archived = archived
                                }
                                windowState.refreshSessions()
                            },
                            onSetPinned: { id, pinned in
                                ChatSessionsManager.shared.setPinned(id: id, pinned: pinned)
                                // Keep the open view-model in sync so the
                                // next auto-save doesn't clobber the flag.
                                if session.sessionId == id {
                                    session.pinned = pinned
                                }
                                windowState.refreshSessions()
                            },
                            onSetProject: { id, projectId in
                                ChatSessionsManager.shared.setProject(id: id, projectId: projectId)
                                // Keep the open view-model in sync so the
                                // next auto-save doesn't clobber the move.
                                if session.sessionId == id {
                                    session.projectId = projectId
                                }
                                windowState.refreshSessions()
                            },
                            onDeleteProject: { id in
                                ChatSessionsManager.shared.deleteProject(id: id)
                                // The open chat may have been a member; its
                                // next auto-save must not resurrect the id.
                                if session.projectId == id {
                                    session.projectId = nil
                                }
                                if windowState.openProjectId == id {
                                    windowState.openProjectId = nil
                                }
                                windowState.refreshSessions()
                            },
                            onOpenProject: { project in
                                windowState.openProjectId = project.id
                            },
                            onExport: { metadata, format in
                                ChatSessionExportCoordinator.run(
                                    metadataSession: metadata,
                                    format: format,
                                    scope: .chat(windowState.windowId)
                                )
                            },
                            onStop: { id in
                                // This window's own run stops directly (the
                                // hosting surface may not be registered with
                                // ChatWindowManager); anything else routes
                                // through the monitor, which prefers the
                                // registry task so a detached run is also
                                // marked cancelled.
                                if session.sessionId == id {
                                    session.stop()
                                } else {
                                    SessionActivityMonitor.shared.stop(sessionId: id)
                                }
                            },
                            onOpenInNewWindow: { sessionData in
                                // Open session in a new window via ChatWindowManager
                                ChatWindowManager.shared.createWindow(
                                    agentId: sessionData.agentId,
                                    sessionData: sessionData
                                )
                            },
                            onOpenInNewTab: { sessionData in
                                windowState.openProjectId = nil
                                windowState.enteredChatFromProjectPage = false
                                windowState.openSessionInNewTab(sessionData)
                            },
                            onSelectAgent: { newAgentId in
                                windowState.switchAgent(to: newAgentId)
                            }
                        )
                    }
                }
                .frame(width: sidebarWidth, alignment: .top)
                .frame(maxHeight: .infinity, alignment: .top)
                .clipped()
                .overlay(alignment: .trailing) {
                    if windowState.showSidebar {
                        sidebarResizeHandle
                    }
                }
                .zIndex(1)

                // Main chat area
                ZStack {
                    // Background
                    chatBackground

                    // Main content — centered with a max readable width
                    VStack(spacing: 0) {
                        // Header
                        chatHeader

                        // Content area (show immediately, model discovery is async)
                        if session.hasAnyModel || session.isDiscoveringModels {
                            if !session.hasVisibleThreadMessages {
                                emptyStateView
                            } else {
                                // Message thread. While a prompt
                                // overlay is mounted, blur the thread
                                // and stop hit-testing so the prompt
                                // visibly takes the foreground without
                                // letting taps leak through.
                                messageThread(effectiveContentWidth)
                                    .blur(radius: promptOverlayObscuresConversation ? 1.5 : 0)
                                    .allowsHitTesting(!isPromptOverlayActive)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                                    .animation(theme.springAnimation(), value: promptOverlayObscuresConversation)
                            }

                            // Mode 2 connection status (connecting / error +
                            // Retry) shown directly above the composer so the
                            // gated send has a visible explanation.
                            remoteAgentConnectionNotice
                                .frame(maxWidth: 1100)
                                .frame(maxWidth: .infinity)
                                .animation(theme.springAnimation(), value: windowState.remoteAgentConnectionPhase)

                            // Run-liveness notice (slow / stalled) so a run
                            // with no visible progress reads as a knowable
                            // state with a recovery action, not a hang.
                            runProgressNotice
                                .frame(maxWidth: 1100)
                                .frame(maxWidth: .infinity)
                                .animation(
                                    theme.springAnimation(),
                                    value: observedSession.runProgressState
                                )

                            // Follow-up suggestions render as a thread row
                            // beneath the assistant message (see
                            // `insertFollowUpSuggestionsIfNeeded`), not here.

                            // Floating input card. Dimmed and
                            // hit-test-disabled while a prompt overlay
                            // is mounted so the prompt's embedded
                            // input is the obvious place to type, and
                            // accidental sends here can't race the
                            // prompt resolution.
                            FloatingInputCard(
                                text: $observedSession.input,
                                selectedModel: $observedSession.selectedModel,
                                pendingAttachments: $observedSession.pendingAttachments,
                                isContinuousVoiceMode: $observedSession.isContinuousVoiceMode,
                                voiceInputState: $observedSession.voiceInputState,
                                showVoiceOverlay: $observedSession.showVoiceOverlay,
                                pickerItems: filteredPickerItems,
                                activeModelOptions: $observedSession.activeModelOptions,
                                isStreaming: observedSession.isSendActiveForComposer,
                                // Hide Stop ONLY while the redaction review
                                // sheet is actually on screen (the sheet owns
                                // its own Cancel and the streaming Task is
                                // suspended in its continuation). Crucially
                                // this is NOT gated on the broader
                                // "before first token" window, so Stop stays
                                // available during model load / prefill — the
                                // long pause a big model spends loading from
                                // disk while the typing-indicator shimmer is up.
                                isPrivacyReviewSheetVisible: pendingRedactionReview != nil,
                                supportsImages: observedSession.selectedModelSupportsImages,
                                estimatedContextTokens: observedSession.estimatedContextTokens,
                                appliesAgentReasoningDefault: observedSession.appliesAgentReasoningDefault,
                                contextBreakdown: observedSession.estimatedContextBreakdown,
                                sessionSpendMicro: observedSession.sessionRouterSpendMicro,
                                isRouterBilledSession: observedSession.isOsaurusRouterSession,
                                imageComposerSettings: $observedSession.imageComposerSettings,
                                onSend: { manualText in
                                    if let manualText = manualText {
                                        observedSession.input = manualText
                                    }
                                    if observedSession.isSendActiveForComposer {
                                        observedSession.enqueueSend(
                                            observedSession.input,
                                            attachments: observedSession.pendingAttachments
                                        )
                                    } else {
                                        observedSession.sendCurrent()
                                    }
                                },
                                onStop: { observedSession.stop() },
                                focusTrigger: focusTrigger,
                                agentId: windowState.agentId,
                                windowId: windowState.windowId,
                                isCompact: windowState.showSidebar,
                                isEmptyChat: !observedSession.hasVisibleThreadMessages,
                                onClearChat: { observedSession.reset() },
                                modelSwitchContinuityWarning:
                                    observedSession.modelSwitchContinuityWarning,
                                onDismissModelSwitchContinuityWarning: {
                                    observedSession.modelSwitchContinuityWarning = nil
                                },
                                onCaptureScreenshot: { observedSession.captureScreenshotFromSlashCommand() },
                                onGenerateTitle: { observedSession.generateTitleFromSlashCommand() },
                                onSkillSelected: { skillId in
                                    observedSession.pendingOneOffSkillId = skillId
                                },
                                pendingSkillId: $observedSession.pendingOneOffSkillId,
                                autoSpeakAssistant: $observedSession.autoSpeakAssistant,
                                queuedSend: $observedSession.queuedSend,
                                onSendNow: { observedSession.sendNowInterrupting() },
                                onCancelQueued: { observedSession.cancelQueuedSend() },
                                onAddCredits: { showTopUpSheet = true },
                                isModelPinned: windowState.selectedDiscoveredAgentProviderId != nil,
                                pinnedModelLabel: pinnedModelChipLabel,
                                remoteConnectionPending: windowState.remoteAgentConnectionPhase
                                    == .connecting,
                                isRemoteAgentRun: windowState.selectedDiscoveredAgentProviderId
                                    != nil,
                                inputHistoryProvider: { [weak observedSession] in
                                    guard let observedSession else { return [] }
                                    return ChatInputHistory.entries(from: observedSession.turns)
                                },
                                inputHistoryKey: observedSession.sessionId,
                                warmModelsOnLoadEnabled: ChatConfigurationStore.load().warmModelsOnLoad,
                                compactionState: observedSession.compactionState,
                                canCompactConversation: observedSession
                                    .canManuallyCompactConversation,
                                onCompactConversation: {
                                    observedSession.requestManualCompaction()
                                },
                                warmupController: observedSession.warmupController,
                                folderState: observedSession.folderState
                            )
                            .frame(maxWidth: 1100)
                            .frame(maxWidth: .infinity)
                            .opacity(isPromptOverlayActive ? 0.55 : 1.0)
                            .allowsHitTesting(!isPromptOverlayActive)
                            .animation(theme.springAnimation(), value: isPromptOverlayActive)
                        } else {
                            // No models empty state
                            ChatEmptyState(
                                hasModels: false,
                                selectedModel: nil,
                                agents: windowState.agents,
                                activeAgentId: windowState.agentId,
                                quickActions: emptyStateQuickActions,
                                onOpenModelManager: {
                                    AppDelegate.shared?.showManagementWindow(initialTab: .models)
                                },
                                onUseFoundation: windowState.foundationModelAvailable
                                    ? {
                                        session.selectedModel = session.pickerItems.firstChatCapable?.id ?? "foundation"
                                    } : nil,
                                onQuickAction: { _ in },
                                onOpenOnboarding: {
                                    // If onboarding was already completed, just refresh models
                                    // Don't reset onboarding - the user just finished it
                                    if !OnboardingService.shared.shouldShowOnboarding {
                                        Task { @MainActor in
                                            await session.refreshPickerItems()
                                        }
                                        return
                                    }
                                    // Only reset for users who never completed onboarding
                                    OnboardingService.shared.resetOnboarding()
                                    // Close this window so user can focus on onboarding
                                    ChatWindowManager.shared.closeWindow(id: windowState.windowId)
                                    // Show onboarding window
                                    AppDelegate.shared?.showOnboardingWindow()
                                },
                                onRetryConnection: {
                                    // Reconnect the managed Osaurus Router and any
                                    // enabled providers, then re-resolve the picker.
                                    await RemoteProviderManager.shared.connectEnabledProviders()
                                    await session.refreshPickerItems()
                                },
                                onOpenProviders: {
                                    AppDelegate.shared?.showManagementWindow(initialTab: .providers)
                                },
                            )
                        }
                    }
                    .animation(theme.springAnimation(responseMultiplier: 0.9), value: session.hasVisibleThreadMessages)

                    // Project detail page, shown over the chat surface while
                    // a project is open from the sidebar's Projects tab.
                    // Opaque and full-size so the chat beneath neither shows
                    // nor receives events.
                    if let project = projectManager.project(for: windowState.openProjectId) {
                        ProjectDetailView(
                            project: project,
                            currentAgentId: windowState.agentId,
                            onOpenSession: { data in
                                windowState.openProjectId = nil
                                windowState.enteredChatFromProjectPage = true
                                windowState.loadSession(data)
                                isPinnedToBottom = true
                            },
                            onNewChat: { windowState.startNewChat(in: project) },
                            onDelete: {
                                ChatSessionsManager.shared.deleteProject(id: project.id)
                                if session.projectId == project.id {
                                    session.projectId = nil
                                }
                                windowState.openProjectId = nil
                                windowState.refreshSessions()
                            }
                        )
                        .transition(.opacity)
                        .zIndex(2)
                    }
                }
                .animation(theme.animationQuick(), value: windowState.openProjectId)
            }
        }
        // Allow the window to narrow down to 680pt so it tiles beside other
        // windows. With the sidebar open by default (260pt) plus the tab strip,
        // anything narrower squished the chat column; the content is responsive
        // (chips collapse to icons, tabs fold into an overflow menu), so a narrow
        // width reflows the same UI rather than clipping it.
        .frame(
            minWidth: 680,
            idealWidth: 950,
            maxWidth: .infinity,
            minHeight: 575,
            idealHeight: 610,
            maxHeight: .infinity
        )
        // Matches the window's rounded corners; in full screen the window is
        // square, so rounding would cut visible notches into the content.
        .clipShape(
            RoundedRectangle(
                cornerRadius: windowState.isFullScreen ? 0 : 24,
                style: .continuous
            )
        )
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: .chatToolbarBackToProject)) { notification in
            guard let targetWindowId = notification.userInfo?["windowId"] as? UUID,
                targetWindowId == windowState.windowId
            else { return }
            windowState.openProjectId = session.projectId
        }
        // Keep the live session's membership in sync with sidebar/other-window
        // moves: compose reads `session.projectId` every turn, so a stale copy
        // keeps injecting the old project's instructions and knowledge.
        .onReceive(NotificationCenter.default.publisher(for: .chatSessionProjectDidChange)) { notification in
            if let clearedProjectId = notification.userInfo?["clearedProjectId"] as? UUID {
                if session.projectId == clearedProjectId { session.projectId = nil }
                return
            }
            guard let sessionId = notification.userInfo?["sessionId"] as? UUID,
                sessionId == session.sessionId
            else { return }
            session.projectId = notification.userInfo?["projectId"] as? UUID
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatOverlayActivated)) { _ in
            // Lightweight state updates only - refreshAll() removed to prevent excessive re-renders
            focusTrigger &+= 1
            isPinnedToBottom = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatToolbarSelectDiscoveredAgent)) { notification in
            guard let targetWindowId = notification.userInfo?["windowId"] as? UUID,
                targetWindowId == windowState.windowId,
                let agent = notification.object as? DiscoveredAgent
            else { return }
            selectDiscoveredAgent(agent)
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatToolbarSelectRelayAgent)) { notification in
            guard let targetWindowId = notification.userInfo?["windowId"] as? UUID,
                targetWindowId == windowState.windowId,
                let relay = notification.object as? PairedRelayAgent
            else { return }
            connectToRelayAgent(relay)
        }
        .onReceive(NotificationCenter.default.publisher(for: .vadStartNewSession)) { notification in
            // VAD requested a new session for a specific agent
            // Only handle if this is the targeted window
            if let agentId = notification.object as? UUID {
                // Only switch if this window's agent matches the VAD request
                if agentId == windowState.agentId {
                    windowState.startNewChat()
                }
            }
        }
        .onAppear {
            setupKeyMonitor()
            observedSession.notifySessionBecameActive()

            // Register close callback with ChatWindowManager
            ChatWindowManager.shared.setCloseCallback(for: windowState.windowId) { [weak windowState] in
                windowState?.cleanup()
                windowState?.session.save()
            }

            // Compute the conditional flags so we don't surface the
            // "restart sandbox" / "review paired devices" pages to users
            // who would have nothing to do on them.
            let hasSandbox: Bool = {
                #if os(macOS)
                    if #available(macOS 26, *) {
                        return SandboxConfigurationStore.load().setupComplete
                    }
                #endif
                return false
            }()
            let knownAgentAddrs = Set(
                AgentManager.shared.agents.compactMap { $0.agentAddress }
            )
            let hasLegacyPairedKeys = !APIKeyManager.shared
                .legacyMasterScopedKeys(knownAgentAddresses: knownAgentAddrs)
                .isEmpty
            pendingWhatsNew = WhatsNewGate.pendingAutoShowRelease(
                hasSandbox: hasSandbox,
                hasLegacyPairedKeys: hasLegacyPairedKeys
            )
        }
        .onDisappear {
            cleanupKeyMonitor()
        }
        .onChange(of: observedSession.pickerItems) { _, _ in
            // Remote agent active: (re)apply the pinned model when the device's
            // models arrive after the async connect. No agent → leave the user's
            // selection alone.
            guard let providerId = windowState.selectedDiscoveredAgentProviderId else { return }
            applyRemoteAgentModelPin(providerId: providerId)
        }
        .onChange(of: windowState.selectedDiscoveredAgentProviderId) { _, providerId in
            guard providerId == nil else { return }
            // Remote agent deselected — drop the pin and restore the local
            // agent's preferred model.
            windowState.pinnedRemoteAgentEffectiveModel = nil
            let agentModel = AgentManager.shared.effectiveModel(for: windowState.agentId)
            if let model = agentModel, session.pickerItems.contains(where: { $0.id == model }) {
                session.selectedModel = model
            } else {
                session.selectedModel = session.pickerItems.firstChatCapable?.id
            }
        }
        .onChange(of: windowState.effectiveChatIdentity, initial: true) { _, identity in
            // Keep the thread's baked header name in sync with whoever owns the
            // chat: the remote agent in Mode 2, else the local agent (nil =
            // local default). Rebuild so already-rendered turns pick up the
            // change immediately (e.g. a remote agent renamed mid-session).
            let override = identity.isRemote ? identity.name : nil
            if session.threadAgentDisplayName != override {
                session.threadAgentDisplayName = override
                session.rebuildVisibleBlocks()
            }
        }
        .environment(\.theme, windowState.theme)
        .tint(theme.accentColor)
        .sheet(item: $pendingWhatsNew) { release in
            WhatsNewModal(
                release: release,
                onClose: {
                    WhatsNewGate.markShown(version: release.version)
                    pendingWhatsNew = nil
                },
                onAction: { action in
                    // Only perform the deep link here. The modal owns
                    // dismissal — it stays open on non-final pages and calls
                    // `onClose` (which marks the release seen) when the CTA is
                    // on the last page, so a mid-carousel CTA doesn't skip the
                    // remaining notes.
                    switch action {
                    case .openSandboxSettings:
                        AppDelegate.shared?.showManagementWindow(initialTab: .sandbox)
                    case .openAPIKeysSettings:
                        AppDelegate.shared?.showManagementWindow(initialTab: .server)
                    case .openSecurityDoc(let url):
                        NSWorkspace.shared.open(url)
                    case .openStorageSettings, .exportPlaintextBackup:
                        // Both actions land on the storage-encryption panel,
                        // which lives on the Privacy tab now that the
                        // standalone Storage tab is gone.
                        // `exportPlaintextBackup` doesn't auto-open
                        // the file picker — the user clicks
                        // "Export plaintext backup…" once they're
                        // there, which is the safer flow because it
                        // forces them to pick a destination.
                        AppDelegate.shared?.showManagementWindow(initialTab: .privacy)
                    case .openPrivacySettings:
                        AppDelegate.shared?.showManagementWindow(initialTab: .privacy)
                    case .openComputerUseSettings:
                        AppDelegate.shared?.showManagementWindow(initialTab: .computerUse)
                    case .openCredits:
                        AppDelegate.shared?.showManagementWindow(initialTab: .credits)
                    case .openImageGeneration:
                        AppDelegate.shared?.showManagementWindow(initialTab: .imageGeneration)
                    case .openSearchSettings:
                        AppDelegate.shared?.showManagementWindow(initialTab: .search)
                    case .openKnowledgeSettings:
                        AppDelegate.shared?.showManagementWindow(initialTab: .knowledge)
                    case .openBrowserSettings:
                        AppDelegate.shared?.showManagementWindow(initialTab: .browser)
                    case .openChannelsSettings:
                        AppDelegate.shared?.showManagementWindow(initialTab: .agentChannels)
                    case .openProjects:
                        // Projects live in this window's sidebar; open the
                        // sidebar (it may be collapsed) and flip its lens to
                        // Projects rather than opening the management window.
                        withAnimation(windowState.theme.animationQuick()) {
                            windowState.showSidebar = true
                        }
                        ProjectManager.shared.pendingRevealProjectsTab = true
                    case .openOrchestratorSettings:
                        AppDelegate.shared?.showManagementWindow(initialTab: .orchestrator)
                    case .openModelDownloads(let modelId):
                        // Ride the one-shot pending request (mirrors
                        // `pendingRemoteAgentDetailId`) so the detail sheet
                        // opens for both a fresh and a reused Models window.
                        if let modelId {
                            ManagementStateManager.shared.pendingModelDetailId = modelId
                        }
                        AppDelegate.shared?.showManagementWindow(initialTab: .models)
                    case .openSubagentSettings:
                        // Land on the first custom (non-built-in) agent's
                        // Subagents tab (per-agent spawn / image config). With
                        // no custom agent yet, just open the Agents grid so the
                        // user can create one.
                        if let subagentAgentId = AgentManager.shared.agents
                            .first(where: { !$0.isBuiltIn })?.id
                        {
                            AppDelegate.shared?.showAgentDetail(
                                agentId: subagentAgentId,
                                tab: "subagents"
                            )
                        } else {
                            AppDelegate.shared?.showManagementWindow(initialTab: .agents)
                        }
                    }
                }
            )
            .environment(\.theme, windowState.theme)
        }
        // Session-scoped sandbox Changes list + undo, opened from the
        // toolbar's Changes button.
        .sheet(isPresented: $windowState.isChangesSheetPresented) {
            if let sid = session.sessionId {
                ChatChangesView(
                    sessionId: sid,
                    onClose: { windowState.isChangesSheetPresented = false }
                )
                .environment(\.theme, windowState.theme)
            }
        }
        .sheet(item: $pendingDiscoveredAgent) { agent in
            if agent.isUnverifiableSecureChannelPeer {
                // Claims encryption (osc=1) but advertised no address to pin —
                // an inconsistent advertisement (spoof, or a peer that needs to
                // upgrade / assign an identity). Refuse rather than connect
                // without any identity verification.
                UnverifiablePeerSheet(agentName: agent.name) {
                    pendingDiscoveredAgent = nil
                }
                .environment(\.theme, windowState.theme)
            } else if agent.address != nil {
                PairingSheet(agent: agent) { apiKey, isPermanent in
                    connectToDiscoveredAgent(agent, token: apiKey, isEphemeral: !isPermanent)
                    pendingDiscoveredAgent = nil
                } onCancel: {
                    pendingDiscoveredAgent = nil
                }
                .environment(\.theme, windowState.theme)
            } else {
                BonjourTokenSheet(agentName: agent.name) { token in
                    connectToDiscoveredAgent(agent, token: token)
                    pendingDiscoveredAgent = nil
                } onCancel: {
                    pendingDiscoveredAgent = nil
                }
                .environment(\.theme, windowState.theme)
            }
        }
        // Privacy-filter redaction review. The presenter closure is
        // registered in `.task` below; when the pipeline detects PII
        // it suspends on a continuation in `RedactionReviewState`,
        // which we surface here via SwiftUI's standard sheet machinery.
        // The state's `onResolve` continuation is finished by the
        // sheet's Approve / Cancel actions (or `sheetDismissed()` if
        // the user dismisses with Escape).
        .sheet(item: $pendingRedactionReview) { state in
            // The sheet's `onDisappear` calls `state.sheetDismissed()`
            // which resolves the continuation as `.canceled` unless an
            // explicit Approve / Cancel button already resolved it.
            // We just need to clear our local payload so the next
            // review can present.
            RedactionReviewSheet(state: state)
                .environment(\.theme, windowState.theme)
                .onDisappear { pendingRedactionReview = nil }
        }
        .task {
            // Register this window as the presenter for redaction
            // reviews. The service keeps every registration alive but
            // only routes through the most-recent one, so multiple
            // open windows still behave as last-write-wins; the token
            // is how we drop *this* window's registration at teardown
            // without disturbing whichever window is currently active.
            let token = PrivacyReviewService.shared.registerPresenter { state in
                pendingRedactionReview = state
            }
            privacyPresenterToken = token

            // Presenter for the redaction tools' PII-model download gate,
            // rendered on this window's ThemedAlertHost overlay so it
            // matches every other app dialog. Value-captured scope (no
            // windowState retain); last-write-wins across windows, same
            // pragmatic behavior as other global presenters.
            let downloadScope = ThemedAlertScope.chat(windowState.windowId)
            await PIIModelDownloadGate.shared.registerPresenter {
                await PIIModelDownloadAlertFlow.run(scope: downloadScope)
            }
        }
        .onDisappear {
            // Drop only this window's registration — by passing the
            // token, other windows that registered after us stay
            // intact. Fixes the original bug where a stale onDisappear
            // would silently disable review for the focused window.
            if let token = privacyPresenterToken {
                PrivacyReviewService.shared.unregisterPresenter(token)
                privacyPresenterToken = nil
            }
        }
    }

    /// Called when the user picks a discovered agent from the menu.
    /// If a persistent (non-ephemeral) paired provider already exists for this agent,
    /// connect directly without showing the pairing sheet.
    private func selectDiscoveredAgent(_ agent: DiscoveredAgent) {
        let manager = RemoteProviderManager.shared
        let hasPersistentProvider = manager.configuration.providers.contains(where: {
            $0.providerType == .osaurus
                && $0.remoteAgentId == agent.id
                && !manager.isEphemeral(id: $0.id)
        })
        if hasPersistentProvider {
            connectToDiscoveredAgent(agent, token: "", isEphemeral: false)
        } else {
            pendingDiscoveredAgent = agent
        }
    }

    private func connectToDiscoveredAgent(_ agent: DiscoveredAgent, token: String, isEphemeral: Bool = true) {
        // Prefer the stable `.local` hostname, falling back to the resolved IP
        // when it's missing (some networks block multicast `.local`
        // resolution). Strip the trailing dot from mDNS hostnames
        // (e.g. "device.local." -> "device.local").
        let rawHost = agent.connectHost ?? "localhost"
        let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
        let manager = RemoteProviderManager.shared

        let providerId: UUID
        // Reuse an existing Osaurus provider that already targets the same agent
        if let existing = manager.configuration.providers.first(where: {
            $0.providerType == .osaurus && $0.remoteAgentId == agent.id
        }) {
            providerId = existing.id
            var updated = existing
            updated.host = host
            updated.providerProtocol = .http
            updated.port = agent.port
            updated.enabled = true
            if let address = agent.address { updated.remoteAgentAddress = address }
            if !token.isEmpty {
                updated.authType = .apiKey
                manager.updateProvider(updated, apiKey: token)
            } else {
                manager.updateProvider(updated, apiKey: nil)
            }
            // The connect is owned by `pinRemoteAgentModelAfterConnect` below so
            // the first model refresh / effective-model pin runs *after* the
            // provider is connected (otherwise the picker stays empty until the
            // window is reopened).
        } else {
            // Use basePath="" so URLs are constructed directly as /agents/{id}/run
            let provider = RemoteProvider(
                name: agent.name,
                host: host,
                providerProtocol: .http,
                port: agent.port,
                basePath: "",
                authType: token.isEmpty ? .none : .apiKey,
                providerType: .osaurus,
                enabled: true,
                autoConnect: true,
                remoteAgentId: agent.id,
                remoteAgentAddress: agent.address
            )
            providerId = provider.id
            manager.addProvider(provider, apiKey: token.isEmpty ? nil : token, isEphemeral: isEphemeral)
        }

        windowState.selectedRelayAgent = nil
        windowState.selectedDiscoveredAgent = agent
        windowState.selectedDiscoveredAgentProviderId = providerId
        windowState.pinnedRemoteAgentEffectiveModel = nil
        windowState.pinnedRemoteAgentAvatar = nil
        windowState.pinnedRemoteAgentQuickActions = nil
        windowState.refreshPairedRelayAgents()
        session.reset()
        pinRemoteAgentModelAfterConnect(providerId: providerId)
    }

    /// After selecting a remote agent (Mode 2), refresh the picker, resolve the
    /// agent's live effective model, and pin the chip to it. Survives the async
    /// connect race: the effective-model fetch runs independently of model
    /// discovery, and `applyRemoteAgentModelPin` re-runs from `onChange` when
    /// the device's models arrive.
    private func pinRemoteAgentModelAfterConnect(providerId: UUID) {
        let provider = RemoteProviderManager.shared.configuration.providers.first {
            $0.id == providerId
        }
        windowState.remoteAgentConnectionPhase = .connecting
        Task {
            // Ensure the provider is connected before refreshing models /
            // resolving the pin, so the first refresh sees the connected
            // provider's model list rather than an empty one. `connect` is
            // idempotent and tolerates the auto-connect that
            // add/updateProvider may also kick off. A secure-channel handshake
            // failure now throws (see `fetchOsaurusModels`) so connect failure
            // surfaces here instead of leaving a phantom "connected" pill.
            do {
                try await RemoteProviderManager.shared.connect(providerId: providerId)
            } catch {
                guard windowState.selectedDiscoveredAgentProviderId == providerId else { return }
                windowState.remoteAgentConnectionPhase = .failed(
                    ChatErrorMessages.remoteConnectFailure(error)
                )
                return
            }
            guard windowState.selectedDiscoveredAgentProviderId == providerId else { return }
            await session.refreshPickerItems()
            if let provider {
                // One metadata fetch resolves the live model + avatar + name so
                // Mode 2 can both pin the model chip and surface the remote
                // agent's own identity (avatar/name) in chat.
                let metadata = await RemoteProviderService.fetchOsaurusAgentMetadata(
                    from: provider
                )
                guard windowState.selectedDiscoveredAgentProviderId == providerId else { return }
                windowState.pinnedRemoteAgentEffectiveModel = metadata?.effectiveModel
                windowState.pinnedRemoteAgentAvatar = metadata?.avatar
                windowState.pinnedRemoteAgentQuickActions = metadata?.quickActions
                // Keep the persisted paired-agent label/avatar honest (no-op for
                // ephemeral Bonjour peers without a RemoteAgent record).
                if let address = provider.remoteAgentAddress, !address.isEmpty {
                    RemoteAgentManager.shared.updateLiveMetadata(
                        forAddress: address,
                        name: metadata?.name,
                        description: metadata?.description,
                        avatar: metadata?.avatar
                    )
                }
            }
            guard windowState.selectedDiscoveredAgentProviderId == providerId else { return }
            applyRemoteAgentModelPin(providerId: providerId)
            windowState.remoteAgentConnectionPhase = .connected
        }
    }

    private func connectToRelayAgent(_ relay: PairedRelayAgent) {
        let relayHost = "\(relay.remoteAgentAddress).agent.osaurus.ai"
        let manager = RemoteProviderManager.shared

        guard let existing = manager.configuration.providers.first(where: { $0.id == relay.providerId }) else {
            return
        }

        var updated = existing
        updated.host = relayHost
        updated.providerProtocol = .https
        updated.port = nil
        updated.enabled = true
        manager.updateProvider(updated, apiKey: nil)
        // Connect is owned by `pinRemoteAgentModelAfterConnect` (see note there).

        windowState.selectedDiscoveredAgent = nil
        windowState.selectedRelayAgent = relay
        windowState.selectedDiscoveredAgentProviderId = relay.providerId
        windowState.pinnedRemoteAgentEffectiveModel = nil
        windowState.pinnedRemoteAgentAvatar = nil
        windowState.pinnedRemoteAgentQuickActions = nil
        session.reset()
        pinRemoteAgentModelAfterConnect(providerId: relay.providerId)
    }

    // MARK: - Empty State

    /// The chat empty-state surface, lifted into its own `@ViewBuilder`
    /// helper so the cumulative type-checker work in `body` stays under
    /// the budget — adding modifiers to the inline `ChatEmptyState(...)`
    /// here previously tipped the surrounding ZStack expression past the
    /// "unable to type-check in reasonable time" threshold.
    /// Quick actions for the empty chat state: the active agent's own actions
    /// if defined, else the built-in defaults (configure-oriented for the
    /// default Osaurus agent, chat-oriented for everything else).
    private var emptyStateQuickActions: [AgentQuickAction] {
        windowState.activeAgent.chatQuickActions
            ?? (windowState.agentId == Agent.defaultId
                ? AgentQuickAction.defaultConfigurationQuickActions
                : AgentQuickAction.defaultChatQuickActions)
    }

    /// Description shown beneath the remote agent's name in the empty state.
    /// Prefers the Bonjour-advertised description, then the persisted paired
    /// record's (refreshed from live metadata on connect). nil → neutral default.
    private var remoteAgentDescriptionForEmptyState: String? {
        if let discovered = windowState.selectedDiscoveredAgent {
            let d = discovered.agentDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if !d.isEmpty { return d }
        }
        if let providerId = windowState.selectedDiscoveredAgentProviderId,
            let remote = RemoteAgentManager.shared.remoteAgent(forProviderId: providerId)
        {
            let d = remote.description.trimmingCharacters(in: .whitespacesAndNewlines)
            if !d.isEmpty { return d }
        }
        return nil
    }

    @ViewBuilder
    private var emptyStateView: some View {
        // Wrapped in an Equatable view so a `ChatSession` mutation that doesn't
        // touch any empty-state input (e.g. toggling thinking, which republishes
        // `activeModelOptions`) can't re-render the greeting. `ChatView` observes
        // the whole session object, so its body re-evaluates on every published
        // change; `.equatable()` lets SwiftUI skip this subtree when the inputs
        // below are unchanged.
        EmptyStateContent(
            selectedModel: session.selectedModel,
            agents: windowState.agents,
            activeAgentId: windowState.agentId,
            quickActions: emptyStateQuickActions,
            pendingLocalModelId: session.pendingLocalSetupModelId,
            temporaryCloudModelName: session.temporaryCloudModelDisplayName,
            activeDiscoveredAgent: windowState.selectedDiscoveredAgent,
            activeRelayAgent: windowState.selectedRelayAgent,
            remoteAgentAvatar: windowState.pinnedRemoteAgentAvatar,
            remoteAgentDescription: remoteAgentDescriptionForEmptyState,
            remoteAgentQuickActions: windowState.pinnedRemoteAgentQuickActions,
            isConnecting: windowState.remoteAgentConnectionPhase == .connecting,
            onOpenModelManager: {
                AppDelegate.shared?.showManagementWindow(initialTab: .models)
            },
            onUseFoundation: windowState.foundationModelAvailable
                ? {
                    session.selectedModel =
                        session.pickerItems.firstChatCapable?.id
                        ?? "foundation"
                } : nil,
            onQuickAction: { prompt in
                session.input = prompt
            },
            // Automatic while local setup is pending: connects the Router on
            // demand, with recovery UI if it cannot be reached.
            onUseHostedWhilePending: { await session.adoptOsaurusRouterModelWhileLocalSetupPending() }
        )
        .equatable()
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    // MARK: - Background

    private var chatBackground: some View {
        ZStack {
            ThemedBackgroundLayer(
                cachedBackgroundImage: windowState.cachedBackgroundImage,
                showSidebar: windowState.showSidebar,
                isFullScreen: windowState.isFullScreen
            )

            if theme.glassEnabled {
                ThemedGlassSurface(
                    cornerRadius: windowState.isFullScreen ? 0 : 24,
                    topLeadingRadius: windowState.showSidebar ? 0 : nil,
                    bottomLeadingRadius: windowState.showSidebar ? 0 : nil
                )
                .allowsHitTesting(false)

                let baseBacking = theme.windowBackingOpacity
                let backingOpacity = baseBacking * (0.4 + theme.glassOpacityPrimary * 0.6)

                LinearGradient(
                    colors: [
                        theme.primaryBackground.opacity(backingOpacity + theme.glassOpacityPrimary * 0.3),
                        theme.primaryBackground.opacity(backingOpacity + theme.glassOpacitySecondary * 0.2),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: (windowState.showSidebar || windowState.isFullScreen) ? 0 : 24,
                        bottomLeadingRadius: (windowState.showSidebar || windowState.isFullScreen) ? 0 : 24,
                        bottomTrailingRadius: windowState.isFullScreen ? 0 : 24,
                        topTrailingRadius: windowState.isFullScreen ? 0 : 24,
                        style: .continuous
                    )
                )
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Header

    private var chatHeader: some View {
        // Team layout: no agent identity in the chat header — the sidebar's
        // Agents list (open by default) carries the selection; project
        // membership shows as a folder glyph on the session tab.
        Color.clear
            .frame(height: 52)
            .allowsHitTesting(false)
    }

    // MARK: - Message Thread

    /// Isolated message thread view to prevent cascading re-renders
    private func messageThread(_ width: CGFloat) -> some View {
        ChatPerfTrace.shared.count("body.messageThread")
        // do not read `session.visibleBlocks` here as that would
        // subscribe this enclosing body to per-sync changes (via ChatSession's
        // objectWillChange, if visibleBlocks were @Published) and/or delay the
        // reactivity needed by the table. `IsolatedThreadView` observes the
        // store directly, so only *its* body re-runs on per-token updates
        // Use the effective chat identity so a Mode 2 remote conversation is
        // headed by the *remote* agent's name + mascot, not the local agent
        // (which always rendered "Osaurus" with the local avatar).
        let identity = windowState.effectiveChatIdentity
        let displayName = identity.name
        let lastAssistantTurnId = session.lastAssistantTurnIdForThread
        let blocks = session.visibleBlocks
        let minimapMarkers = buildMinimapMarkers(from: blocks)

        let inlineInsetHeight = agentInlineInsetHeight

        return ZStack {
            // Thread reserves a small top inset matching the *collapsed*
            // pill stack height so the topmost message stays visible
            // above the floating chrome. Expanded cards float over
            // content (semi-transparent material lets the conversation
            // read through). The inset animates with the same spring
            // as the pill mount/unmount so the thread visibly slides
            // when the agent emits a todo or completes.
            IsolatedThreadView(
                store: session.visibleBlocksStore,
                width: width,
                agentName: displayName,
                agentAvatar: identity.mascotId,
                agentCustomAvatarPath: identity.customAvatarPath,
                isStreaming: session.isStreaming,
                lastAssistantTurnId: lastAssistantTurnId,
                expandedBlocksStore: session.expandedBlocksStore,
                scrollToBottomTrigger: scrollToBottomTrigger,
                onScrolledToBottom: { isPinnedToBottom = true },
                onScrolledAwayFromBottom: { isPinnedToBottom = false },
                onCopy: copyTurnContent,
                onRegenerate: regenerateTurn,
                onEdit: beginEditingTurn,
                onDelete: deleteTurn,
                onSpeak: speakTurnContent,
                onFollowUpTap: { session.sendFollowUp($0) },
                onDeleteMessage: confirmDeleteAssistantMessage,
                editingTurnId: editingTurnId,
                editText: $editText,
                onConfirmEdit: confirmEditAndRegenerate,
                onCancelEdit: cancelEditing,
                onUserImagePreview: openUserAttachmentPreview(attachmentId:),
                onImagePreviewImage: { userImagePreview = $0 },
                onDocumentPreview: { pastedContentPreview = $0 },
                onVisibleTopUserTurnChanged: { turnId in
                    activeMinimapTurnId = turnId
                },
                scrollToTurnId: scrollToTurnId,
                scrollToTurnTrigger: scrollToTurnTrigger,
                sessionRedactions: session.sessionRedactions,
                searchHighlightQuery: windowState.isFindBarVisible
                    ? debouncedFindQuery.trimmingCharacters(in: .whitespacesAndNewlines) : "",
                searchCurrentTurnId: currentFindMatch?.turnId,
                searchCurrentOccurrence: currentFindMatch?.occurrence ?? 0,
                scrollToFindOccurrence: scrollToFindOccurrence
            )
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear
                    .frame(height: inlineInsetHeight)
                    .animation(theme.springAnimation(), value: inlineInsetHeight)
            }

            // Floating agent-loop chrome (Todo / Done) — top-anchored
            // overlay. Lives in the ZStack as a sibling to the thread
            // so it doesn't consume vertical space; pills compact, cards
            // expand on hover/pin (see `AgentInlineBlocks.swift`).
            VStack(spacing: AgentInlineBlockMetrics.stackSpacing) {
                agentInlineBlocks
            }
            // Match the thread's centered content width so the blocks align
            // with the message column instead of stretching across the full
            // chat area on wide windows.
            .frame(maxWidth: CenteredMessageScrollView.defaultMaxContentWidth)
            .padding(.top, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(session.lastCompletionSummary != nil || session.currentTodo != nil)

            // Find bar overlay (Cmd+F) — top-trailing, above the thread.
            if windowState.isFindBarVisible {
                VStack {
                    HStack {
                        Spacer()
                        ChatFindBar(
                            query: $findQuery,
                            focusTrigger: windowState.findBarFocusRequestID,
                            isSearching: isFindSearchPending,
                            matchIndex: findMatchIndex,
                            matchCount: findMatches.count,
                            onPrevious: { advanceFindMatch(by: -1) },
                            onNext: { advanceFindMatch(by: 1) },
                            onClose: { windowState.isFindBarVisible = false }
                        )
                        .padding(.trailing, 16)
                        .padding(.top, inlineInsetHeight + 8)
                    }
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .onChange(of: findQuery) { _, query in
                    scheduleFindRecompute(query: query)
                }
                .onChange(of: session.turns.count) { _, _ in
                    recomputeFindMatches(query: debouncedFindQuery, jumpToFirst: false)
                }
                .onAppear {
                    debouncedFindQuery = findQuery
                    recomputeFindMatches(query: findQuery, jumpToFirst: false)
                }
                .onDisappear {
                    findDebounceTask?.cancel()
                    findDebounceTask = nil
                    findSpinnerTask?.cancel()
                    findSpinnerTask = nil
                    findComputeTask?.cancel()
                    findComputeTask = nil
                    isFindSearchPending = false
                }
            }

            // Minimap overlay — sits at vertical center, right edge
            if minimapMarkers.count >= 2 {
                HStack {
                    Spacer()
                    ChatMinimap(
                        markers: minimapMarkers,
                        activeMarkerId: activeMinimapTurnId,
                        onSelect: { turnId in
                            scrollToTurnId = turnId
                            scrollToFindOccurrence = nil
                            scrollToTurnTrigger &+= 1
                        }
                    )
                    .padding(.trailing, 22)
                }
                .allowsHitTesting(true)
            }

            // Scroll button overlay - isolated from content
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    ScrollToBottomButton(
                        isPinnedToBottom: isPinnedToBottom,
                        hasTurns: session.hasVisibleThreadMessages,
                        onTap: {
                            isPinnedToBottom = true
                            scrollToBottomTrigger += 1
                        }
                    )
                }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { userImagePreview != nil },
                set: { if !$0 { userImagePreview = nil } }
            )
        ) {
            if let img = userImagePreview {
                ImageFullScreenView(image: img, altText: "")
                    .imageFullScreenSheetPresentation()
            }
        }
        .sheet(item: $pastedContentPreview) { attachment in
            PastedContentSheet(attachment: attachment) {
                pastedContentPreview = nil
            }
        }
        // re-pin to bottom when any in-chat prompt overlay opens. previously
        // wired on the MessageThreadView itself. hoisted here after the store
        // isolation so only ChatView's @State pin toggles, not the thread's
        // per-sync data path
        .onReceive(NotificationCenter.default.publisher(for: .chatOverlayActivated)) { _ in
            isPinnedToBottom = true
        }
    }

    /// Floating agent-loop chrome rendered as a top-anchored overlay
    /// over the message thread (see `messageThread(_:)`). Each block
    /// is gated on the corresponding `@Published` state on
    /// `ChatSession`; nothing renders when the state is nil/empty.
    ///
    /// Order: Todo at the top (compact, persistent state); the Done
    /// banner sits below the Todo as a translucent overlay. The thread
    /// inset only reserves space for the Todo pill — the Done banner
    /// floats over conversation content until the user dismisses it.
    ///
    /// `clarify` used to live here too but has been promoted to a
    /// bottom-pinned overlay (see `promptOverlayLayer`) so the question
    /// stays anchored above the input bar instead of floating above the
    /// thread.
    @ViewBuilder
    private var agentInlineBlocks: some View {
        if let todo = session.currentTodo {
            InlineTodoBlock(todo: todo)
                .transition(
                    .opacity
                        .combined(with: .move(edge: .top))
                        .combined(with: .scale(scale: 0.96, anchor: .top))
                )
        }
        if let summary = session.lastCompletionSummary {
            InlineCompleteBlock(
                summary: summary,
                isBlocked: session.lastCompletionWasBlocked,
                onDismiss: { [weak session] in
                    session?.lastCompletionSummary = nil
                    session?.lastCompletionWasBlocked = false
                }
            )
            // Asymmetric transition: appear with a soft slide+scale so
            // arrival reads as "new event"; dismiss with pure opacity
            // so it cleanly fades away when the user clicks ×.
            .transition(
                .asymmetric(
                    insertion: .opacity
                        .combined(with: .move(edge: .top))
                        .combined(with: .scale(scale: 0.96, anchor: .top)),
                    removal: .opacity
                )
            )
        }
    }

    /// Top safe-area inset reserved for the floating Todo pill so the
    /// topmost message stays visible underneath it. The Done banner
    /// (when present) intentionally overlays content beneath the Todo
    /// — it's a transient notification the user dismisses, not a
    /// persistent layout fixture, so reserving space for it would just
    /// chop the visible chat. Returns 0 when no Todo is active.
    private var agentInlineInsetHeight: CGFloat {
        guard session.currentTodo != nil else { return 0 }
        let topPadding: CGFloat = 4
        let bottomBuffer: CGFloat = 6
        return topPadding + AgentInlineBlockMetrics.collapsedPillHeight + bottomBuffer
    }

}

/// Isolates the streaming-driven `visibleBlocks` observation from `ChatView`'s
/// body. This view is the only place `VisibleBlocksStore.objectWillChange`
/// propagates into SwiftUI; ChatView and its other children (FloatingInputCard,
/// toolbar, sidebar) stay outside the subscription and do not re-evaluate on
/// every streaming sync.
private struct IsolatedThreadView: View {
    @ObservedObject var store: VisibleBlocksStore
    let width: CGFloat
    let agentName: String
    let agentAvatar: String?
    let agentCustomAvatarPath: String?
    let isStreaming: Bool
    let lastAssistantTurnId: UUID?
    let expandedBlocksStore: ExpandedBlocksStore
    let scrollToBottomTrigger: Int
    let onScrolledToBottom: () -> Void
    let onScrolledAwayFromBottom: () -> Void
    let onCopy: (UUID) -> Void
    let onRegenerate: ((UUID) -> Void)?
    let onEdit: ((UUID) -> Void)?
    let onDelete: ((UUID) -> Void)?
    let onSpeak: ((UUID) -> Void)?
    let onFollowUpTap: ((String) -> Void)?
    let onDeleteMessage: ((UUID) -> Void)?
    let editingTurnId: UUID?
    let editText: Binding<String>?
    let onConfirmEdit: (() -> Void)?
    let onCancelEdit: (() -> Void)?
    let onUserImagePreview: ((String) -> Void)?
    var onImagePreviewImage: ((NSImage) -> Void)? = nil
    var onDocumentPreview: ((Attachment) -> Void)? = nil
    var onVisibleTopUserTurnChanged: ((UUID?) -> Void)? = nil
    var scrollToTurnId: UUID? = nil
    var scrollToTurnTrigger: Int = 0
    /// Window-local original -> placeholder map populated by the
    /// Privacy Filter notification. Forwarded into MessageThreadView
    /// for inline highlighting in chat bubbles. Placed after the
    /// scroll controls so existing call sites stay backward-
    /// compatible (it's a defaulted property with an empty map).
    var sessionRedactions: [String: String] = [:]
    /// Active in-conversation find query (Cmd+F); empty when the bar is closed.
    var searchHighlightQuery: String = ""
    /// Turn owning the find bar's current match, nil when none is current.
    var searchCurrentTurnId: UUID? = nil
    /// Occurrence index of the current match within its turn's content.
    var searchCurrentOccurrence: Int = 0
    /// Occurrence the pending `scrollToTurnId` request targets; nil for
    /// turn-level scrolls (minimap).
    var scrollToFindOccurrence: Int? = nil

    var body: some View {
        let _ = ChatPerfTrace.shared.count("body.IsolatedThreadView")
        MessageThreadView(
            blocks: store.blocks,
            groupHeaderMap: store.groupHeaderMap,
            width: width,
            agentName: agentName,
            agentAvatar: agentAvatar,
            agentCustomAvatarPath: agentCustomAvatarPath,
            isStreaming: isStreaming,
            lastAssistantTurnId: lastAssistantTurnId,
            expandedBlocksStore: expandedBlocksStore,
            scrollToBottomTrigger: scrollToBottomTrigger,
            onScrolledToBottom: onScrolledToBottom,
            onScrolledAwayFromBottom: onScrolledAwayFromBottom,
            onCopy: onCopy,
            onRegenerate: onRegenerate,
            onEdit: onEdit,
            onDelete: onDelete,
            onSpeak: onSpeak,
            onFollowUpTap: onFollowUpTap,
            onDeleteMessage: onDeleteMessage,
            editingTurnId: editingTurnId,
            editText: editText,
            onConfirmEdit: onConfirmEdit,
            onCancelEdit: onCancelEdit,
            onUserImagePreview: onUserImagePreview,
            onImagePreviewImage: onImagePreviewImage,
            onDocumentPreview: onDocumentPreview,
            onVisibleTopUserTurnChanged: onVisibleTopUserTurnChanged,
            scrollToTurnId: scrollToTurnId,
            scrollToTurnTrigger: scrollToTurnTrigger,
            sessionRedactions: sessionRedactions,
            searchHighlightQuery: searchHighlightQuery,
            searchCurrentTurnId: searchCurrentTurnId,
            searchCurrentOccurrence: searchCurrentOccurrence,
            scrollToFindOccurrence: scrollToFindOccurrence
        )
    }
}

// Reopen ChatView's declaration for the remaining methods (threadCore was
// inlined into `messageThread` via `IsolatedThreadView` above)
extension ChatView {

    private func openUserAttachmentPreview(attachmentId: String) {
        if let img = ChatImageCache.shared.cachedImage(for: attachmentId) {
            userImagePreview = img
            return
        }
        for turn in session.turns {
            for att in turn.attachments where att.id.uuidString == attachmentId {
                if let data = att.imageData, let img = NSImage(data: data) {
                    userImagePreview = img
                    return
                }
            }
        }
        if let url = sharedArtifactImageURL(artifactId: attachmentId),
            let data = try? Data(contentsOf: url),
            let img = NSImage(data: data)
        {
            userImagePreview = img
        }
    }

    private func sharedArtifactImageURL(artifactId: String) -> URL? {
        for block in session.visibleBlocks {
            guard case let .sharedArtifact(art) = block.kind else { continue }
            guard art.id == artifactId, art.isImage, !art.hostPath.isEmpty else { continue }
            return URL(fileURLWithPath: art.hostPath)
        }
        return nil
    }

    /// Build minimap markers from the current block stream (one per user message)
    private func buildMinimapMarkers(from blocks: [ContentBlock]) -> [ChatMinimap.Marker] {
        var markers: [ChatMinimap.Marker] = []
        markers.reserveCapacity(8)
        for block in blocks {
            if case let .userMessage(text, _, _, _) = block.kind {
                markers.append(ChatMinimap.Marker(id: block.turnId, preview: text))
            }
        }
        return markers
    }

    /// Copy a turn's thinking + content to the clipboard
    private func copyTurnContent(turnId: UUID) {
        guard let turn = session.turns.first(where: { $0.id == turnId }) else { return }

        // Image-generation replies are just the rendered image — copy the actual
        // image to the clipboard instead of the raw `![](file://…)` markdown.
        if !turn.contentIsBlank, !turn.hasRenderableThinking,
            ContentBlock.isImageOnlyContent(turn.visibleContent),
            let imageURL = Self.firstLocalImageURL(in: turn.visibleContent)
        {
            // Reads the file and writes to the pasteboard off the main thread.
            ImageActions.copyImageFileToClipboard(at: imageURL)
            return
        }

        var textToCopy = ""
        if turn.hasRenderableThinking {
            textToCopy += turn.thinking
        }
        if !turn.contentIsBlank {
            if !textToCopy.isEmpty { textToCopy += "\n\n" }
            textToCopy += turn.visibleContent
        }
        guard !textToCopy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textToCopy, forType: .string)
    }

    /// Extracts the first local file URL from a standalone `![](…)` image line.
    private static func firstLocalImageURL(in content: String) -> URL? {
        guard
            let regex = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\(([^)]+)\)"#)
        else { return nil }
        let range = NSRange(content.startIndex ..< content.endIndex, in: content)
        guard let match = regex.firstMatch(in: content, range: range),
            match.numberOfRanges > 1,
            let urlRange = Range(match.range(at: 1), in: content)
        else { return nil }
        let urlString = content[urlRange].trimmingCharacters(in: .whitespaces)
        let url = URL(string: urlString)
        if url?.isFileURL == true { return url }
        return nil
    }

    /// Stable callback for regenerate action - prevents closure recreation
    private func regenerateTurn(turnId: UUID) {
        session.regenerate(turnId: turnId)
    }

    /// Read the assistant turn aloud via PocketTTS. If the model isn't downloaded,
    /// TTSService posts a notification that opens the TTS settings tab.
    private func speakTurnContent(turnId: UUID) {
        guard let turn = session.turns.first(where: { $0.id == turnId }) else { return }
        guard !turn.contentIsBlank else { return }
        let isStartingPlayback = TTSService.shared.playingMessageId != turnId
        if isStartingPlayback && !session.hasAskedAutoSpeak {
            session.hasAskedAutoSpeak = true
            showAutoSpeakPrompt = true
        }
        TTSService.shared.toggleSpeak(
            text: turn.visibleContent,
            messageId: turnId,
            voiceOverride: agentTTSVoiceOverride()
        )
    }

    /// Auto-speak the just-finished assistant turn when the per-session
    /// preference is on. Skips if TTS is disabled, the model isn't loaded,
    /// or another message is already playing (don't interrupt).
    private func handleAssistantTurnCompleted(turnId: UUID?) {
        guard let turnId else { return }
        guard session.autoSpeakAssistant else { return }
        guard TTSConfigurationStore.load().enabled else { return }
        guard TTSService.shared.isModelReady else { return }
        guard TTSService.shared.playingMessageId == nil else { return }
        guard let turn = session.turns.first(where: { $0.id == turnId }),
            !turn.contentIsBlank
        else { return }
        TTSService.shared.toggleSpeak(
            text: turn.visibleContent,
            messageId: turnId,
            voiceOverride: agentTTSVoiceOverride()
        )
    }

    /// active agent's voice override, or nil to use the global voice.
    private func agentTTSVoiceOverride() -> String? {
        let id = session.agentId ?? Agent.defaultId
        return AgentManager.shared.agent(for: id)?.ttsVoice
    }

    /// Stop any active generation and remove the turn (plus all subsequent turns)
    private func deleteTurn(turnId: UUID) {
        if session.isStreaming { session.stop() }
        session.deleteTurn(id: turnId)
        discardSessionIfEmptied()
    }

    /// Ask before deleting an assistant response. Deleting mid-thread can change
    /// what later turns were answering, so we always confirm. The dialog offers
    /// an "also delete my message" checkbox that escalates the delete to the
    /// whole exchange. The wording gains a line when the turn carries tool calls
    /// (its tool results leave with it) or is covered by a compaction summary
    /// (the summary still references it until the next compaction).
    private func confirmDeleteAssistantMessage(turnId: UUID) {
        guard let turn = session.turns.first(where: { $0.id == turnId }),
            turn.role == .assistant
        else { return }

        let hasToolCalls = !(turn.toolCalls?.isEmpty ?? true)
        let isSummarized = session.conversationSummary?.coveredTurnIds.contains(turnId) ?? false

        // Primary line: local models reuse the KV cache on the longest common
        // token prefix, so deleting from the middle of the conversation forces
        // the turns after the deletion point to be re-processed on the next send
        // — surface that heads-up. Remote models manage their own caching, so
        // they get the plain description instead of a bare dialog.
        var lines: [String] = []
        if session.selectedModelIsLocal {
            lines.append(
                L("Deleting from the middle of the conversation may make the next reply take a little longer to start, since everything after this point has to be reprocessed.")
            )
        } else {
            lines.append(
                L("This removes this response from the conversation. It won't be sent to the model on later turns.")
            )
        }
        if hasToolCalls {
            lines.append(
                L("Any tool calls in this response and their results will be removed together.")
            )
        }
        if isSummarized {
            lines.append(
                L("This response is part of a conversation summary, so deleting it may affect the meaning of later turns.")
            )
        }
        deleteAssistantMessageWarning = lines.joined(separator: "\n\n")
        deleteMessageOptions.alsoDeleteUserMessage = false
        pendingDeleteAssistantTurnId = turnId
        showDeleteAssistantMessagePrompt = true
    }

    private func performDeleteAssistantMessage() {
        guard let turnId = pendingDeleteAssistantTurnId else { return }
        pendingDeleteAssistantTurnId = nil
        if session.isStreaming { session.stop() }
        if deleteMessageOptions.alsoDeleteUserMessage {
            session.removeExchange(anchoredAt: turnId)
        } else {
            session.removeTurn(id: turnId)
        }
        discardSessionIfEmptied()
    }

    /// A delete can empty the conversation (e.g. removing the only exchange).
    /// `save()` skips empty conversations, so the stale rows would otherwise
    /// survive and reappear on reopen. Mirror the sidebar's delete of the
    /// current session: cancel any live run, reset the window to a fresh chat,
    /// drop the persisted row, and refresh the history list.
    private func discardSessionIfEmptied() {
        guard session.turns.isEmpty, let id = session.sessionId else { return }
        if let liveTask = BackgroundTaskManager.shared.liveTask(forSessionId: id) {
            BackgroundTaskManager.shared.cancelTask(liveTask.id)
        }
        session.reset()
        ChatSessionsManager.shared.delete(id: id)
        windowState.refreshSessions()
    }

    // MARK: - Inline Editing

    /// Begin inline editing of a user message
    private func beginEditingTurn(turnId: UUID) {
        guard let turn = session.turns.first(where: { $0.id == turnId }),
            turn.role == .user
        else { return }
        editText = turn.content
        editingTurnId = turnId
        // Register the Esc fallback for the window-level key monitor —
        // it can't see this view's @State, and the first-responder
        // check alone misses the "clicked away mid-edit" case.
        windowState.cancelInlineEdit = { cancelEditing() }
    }

    /// Confirm the edit and regenerate the assistant response
    private func confirmEditAndRegenerate() {
        guard let turnId = editingTurnId else { return }
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.editAndRegenerate(turnId: turnId, newContent: trimmed)
        editingTurnId = nil
        editText = ""
        windowState.cancelInlineEdit = nil
    }

    /// Dismiss the inline editor without changes
    private func cancelEditing() {
        editingTurnId = nil
        editText = ""
        windowState.cancelInlineEdit = nil
    }

    // MARK: - In-Conversation Find (Cmd+F)

    /// Recompute the ordered turn-id match list for `query` over the visible
    /// conversation. `jumpToFirst` scrolls to the first match (used while
    /// typing); otherwise the current match is preserved when it survives the
    /// recompute (used when streaming appends turns). Logic lives in
    /// `ChatFindMatcher` so the invariants are unit-tested.
    /// Debounce find-query changes: recompute (and the first-match jump,
    /// cell repaints, and scrolling that follow) runs only after a typing
    /// pause, never per keystroke. If the user types continuously past a
    /// grace period, a small spinner appears in the find field instead of
    /// the view jumping around on stale results.
    private func scheduleFindRecompute(query: String) {
        findDebounceTask?.cancel()
        findDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            debouncedFindQuery = query
            // Spinner state clears when the (off-main) scan delivers, not
            // here — a slow scan should keep showing progress.
            recomputeFindMatches(query: query, jumpToFirst: true)
            findDebounceTask = nil
        }
        // Arm the spinner once per typing burst; it fires only when the
        // debounce hasn't settled within the grace period.
        if findSpinnerTask == nil {
            findSpinnerTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                isFindSearchPending = true
            }
        }
    }

    private func recomputeFindMatches(query: String, jumpToFirst: Bool) {
        findComputeTask?.cancel()
        // Snapshot on the main thread (O(turn count) — strings are CoW),
        // scan off it: the scan is O(total conversation text) and must
        // never block the main thread (Sentry app-hang).
        let snapshot = session.turns.map {
            ChatFindTurnSnapshot(id: $0.id, role: $0.role, content: $0.content)
        }
        let previous = ChatFindState(matches: findMatches, matchIndex: findMatchIndex)
        findComputeTask = Task { @MainActor in
            let (state, jumpTo) = await ChatFindMatcher.recomputeDetached(
                query: query,
                turns: snapshot,
                previous: previous,
                preserveCurrentMatch: !jumpToFirst
            )
            guard !Task.isCancelled else { return }
            findMatches = state.matches
            findMatchIndex = state.matchIndex
            findSpinnerTask?.cancel()
            findSpinnerTask = nil
            isFindSearchPending = false
            findComputeTask = nil
            if let jumpTo {
                scrollToFindMatch(jumpTo)
            }
        }
    }

    /// Step to the next/previous occurrence, wrapping at both ends. A
    /// pending debounce is flushed first — Enter or an arrow key mid-typing
    /// should search for what's in the field now, not navigate stale
    /// matches from the previous query.
    private func advanceFindMatch(by delta: Int) {
        if findDebounceTask != nil {
            findDebounceTask?.cancel()
            findDebounceTask = nil
            findSpinnerTask?.cancel()
            findSpinnerTask = nil
            isFindSearchPending = false
            debouncedFindQuery = findQuery
            recomputeFindMatches(query: findQuery, jumpToFirst: true)
            return
        }
        let (state, jumpTo) = ChatFindMatcher.advance(
            ChatFindState(matches: findMatches, matchIndex: findMatchIndex),
            by: delta
        )
        findMatches = state.matches
        findMatchIndex = state.matchIndex
        if let jumpTo {
            scrollToFindMatch(jumpTo)
        }
    }

    /// The occurrence the find bar currently points at; nil when the bar is
    /// closed or there are no matches. Threaded into the thread view so the
    /// current occurrence gets distinct highlighting.
    private var currentFindMatch: ChatFindMatch? {
        guard windowState.isFindBarVisible, findMatches.indices.contains(findMatchIndex)
        else { return nil }
        return findMatches[findMatchIndex]
    }

    private func scrollToFindMatch(_ match: ChatFindMatch) {
        scrollToTurnId = match.turnId
        scrollToFindOccurrence = match.occurrence
        scrollToTurnTrigger &+= 1
    }

    // Key monitor for Esc. Dismisses transient UI in priority order
    // before falling through to closing the window. The monitor owns the
    // key event before SwiftUI's `.keyboardShortcut(.cancelAction)` /
    // `.onExitCommand` machinery, so every state that should win over
    // "close window" must either be handled here or explicitly passed
    // through to the responder chain.
    private func setupKeyMonitor() {
        if keyMonitor != nil { return }

        let capturedWindowId = windowState.windowId
        let session = windowState.session
        let windowState = self.windowState

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak session, weak windowState] event in
            // Cmd+C copies an active cross-block selection (a drag spanning
            // multiple message blocks, see ChatCrossSelection). Individual
            // NSTextViews only know their own slice, so the controller owns
            // the concatenated copy.
            if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                event.charactersIgnoringModifiers?.lowercased() == "c",
                ChatCrossSelection.shared.copyIfActive(window: event.window)
            {
                return nil
            }

            // Cmd+F opens the in-conversation find bar.
            if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                event.charactersIgnoringModifiers?.lowercased() == "f"
            {
                guard let ourWindow = ChatWindowManager.shared.getNSWindow(id: capturedWindowId),
                    event.window === ourWindow,
                    let windowState
                else { return event }
                windowState.isFindBarVisible = true
                // Also fires when the bar is already open so Cmd+F always
                // returns keyboard focus to the search field.
                windowState.findBarFocusRequestID &+= 1
                return nil
            }

            // Esc key code is 53
            if event.keyCode == 53 {
                // Only handle Esc if this event is for our specific window
                // This prevents closed windows' monitors from handling events for other windows
                guard let ourWindow = ChatWindowManager.shared.getNSWindow(id: capturedWindowId),
                    event.window === ourWindow
                else {
                    return event
                }

                // Session deallocated means the window is gone — pass through
                guard let session else { return event }

                // Stage 0: Slash command popup is open — let the text view delegate handle it
                if SlashCommandRegistry.shared.isPopupVisible {
                    return event
                }

                // Stage 0.5: Find bar is open — close it before any other
                // transient UI so Esc can't fall through to window close
                // while the user is mid-search.
                if let windowState, windowState.isFindBarVisible {
                    windowState.isFindBarVisible = false
                    return nil
                }

                // Stage 1: A transient popover (model picker, model
                // options, context breakdown, agent picker…) is anchored
                // to this window. The popover never becomes key here, so
                // its Esc events land on the chat window and would fall
                // through to window close. Popover windows attach as
                // child windows, and the NSPopover sits in the content
                // view controller's responder chain — performClose keeps
                // SwiftUI's isPresented binding in sync via the delegate.
                for child in ourWindow.childWindows ?? [] {
                    if let popover = child.contentViewController?.nextResponder as? NSPopover {
                        popover.performClose(nil)
                        return nil
                    }
                }

                // Stage 2: Themed alert is up (e.g. "Keep this chat
                // running?"). Cancel it instead of re-entering the
                // close path, which would just re-arm the same alert.
                // Handled even when the alert has no cancel button so
                // Esc can't close the window underneath a modal.
                if ThemedAlertCenter.shared.cancelActive(scope: .chat(capturedWindowId)) {
                    return nil
                }

                // Stage 3: Voice overlay is visible.
                if session.showVoiceOverlay {
                    if SpeechService.shared.isRecording {
                        // Cancel voice input; the overlay hides via the
                        // `isRecording` onChange in FloatingInputCard.
                        print("[ChatView] Esc pressed: Cancelling voice input")
                        Task {
                            _ = await SpeechService.shared.stopStreamingTranscription()
                            SpeechService.shared.clearTranscription()
                        }
                    }
                    // Not recording means a transient overlay state
                    // (e.g. `.sending` during cleanup) — swallow so Esc
                    // can't close the window mid-handoff.
                    return nil
                }

                // Stage 4: In-chat prompt overlay (clarify / secret).
                // Cancel just the prompt, not the window. User-initiated
                // so clarify keeps its question in the transcript.
                if let currentPrompt = session.promptQueue.current {
                    currentPrompt.cancelByUser()
                    session.promptQueue.advance()
                    return nil
                }

                // Stage 5: A text view that opted into local Esc
                // handling (inline message editor) has focus — pass the
                // event through so its `cancelOperation(_:)` cancels the
                // edit instead of the window closing.
                if let focused = ourWindow.firstResponder as? CustomNSTextView,
                    focused.handlesEscapeLocally
                {
                    return event
                }

                // Stage 6: Inline edit is active but its text view lost
                // focus (user clicked the thread background mid-edit) —
                // cancel the edit via the imperative hook ChatView
                // registers in `beginEditingTurn`.
                if let cancelEdit = windowState?.cancelInlineEdit {
                    cancelEdit()
                    return nil
                }

                // Stage 7: Completion banner — dismiss it; the next Esc
                // closes the window.
                if session.lastCompletionSummary != nil {
                    session.lastCompletionSummary = nil
                    session.lastCompletionWasBlocked = false
                    return nil
                }

                // Stage 8: Close chat window
                print("[ChatView] Esc pressed: Closing chat window")

                // Also ensure we cleanup any zombie recording if it exists (hidden but recording)
                if SpeechService.shared.isRecording {
                    print("[ChatView] Cleaning up zombie voice recording on window close")
                    Task {
                        _ = await SpeechService.shared.stopStreamingTranscription()
                        SpeechService.shared.clearTranscription()
                    }
                }

                Task { @MainActor in
                    ChatWindowManager.shared.closeWindow(id: capturedWindowId)
                }
                return nil  // Swallow event
            }
            return event
        }
    }

    private func cleanupKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}

// MARK: - Unverifiable Peer Sheet

/// Shown when a discovered peer claims Secure Channel support (`osc=1`) but
/// advertised no crypto address to pin. We refuse the connection rather than
/// proceed without any identity verification: a genuine, current Osaurus peer
/// always advertises its address alongside `osc=1`, so this combination means
/// either a spoofed advertisement or a peer that must upgrade / assign an
/// identity. Refusal-only — there is no "connect anyway".
private struct UnverifiablePeerSheet: View {
    let agentName: String
    let onClose: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(theme.font(size: 16, weight: .semibold))
                        .foregroundColor(theme.warningColor)
                    Text("Can't verify \(agentName)", bundle: .module)
                        .font(theme.font(size: 16, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                }

                Text(
                    "This agent advertised that it supports encryption but didn't include a verifiable identity, so it can't be paired securely. It may be impersonating another device, or the other device may need to update Osaurus.",
                    bundle: .module
                )
                .font(theme.font(size: 13))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button {
                    onClose()
                } label: {
                    Text("Close", bundle: .module)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

// MARK: - Bonjour Token Sheet

/// Sheet shown when the user selects a Bonjour-discovered remote agent.
/// Prompts for an optional server token before connecting.
private struct BonjourTokenSheet: View {
    let agentName: String
    let onConnect: (String) -> Void
    let onCancel: () -> Void

    @State private var token: String = ""
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect to \(agentName)", bundle: .module)
                    .font(theme.font(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text("Enter the server token for this agent, or leave blank if none is required.", bundle: .module)
                    .font(theme.font(size: 13))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SecureField(L("Server token (optional)"), text: $token)
                .textFieldStyle(.roundedBorder)
                .font(theme.font(size: 13))

            HStack {
                Button {
                    onCancel()
                } label: {
                    Text("Cancel", bundle: .module)
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    onConnect(token)
                } label: {
                    Text("Connect", bundle: .module)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

// MARK: - Pairing Sheet

/// Sheet shown when the user selects a Bonjour-discovered agent that has a crypto address.
/// Performs cryptographic pairing instead of prompting for a manual server token.
private struct PairingSheet: View {
    let agent: DiscoveredAgent
    let onSuccess: (String, Bool) -> Void  // (apiKey, isPermanent)
    let onCancel: () -> Void

    @State private var isPairing = false
    @State private var errorMessage: String? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pair with \(agent.name)", bundle: .module)
                    .font(theme.font(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text(
                    "This will cryptographically verify both devices. The remote device will show an approval prompt.",
                    bundle: .module
                )
                .font(theme.font(size: 13))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }

            // Surface the cryptographic identity that pairing will pin and
            // verify, so the user confirms *who* they're connecting to rather
            // than trusting only the (unauthenticated) advertised display name.
            if let fingerprint = agent.addressFingerprint {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(theme.font(size: 13))
                        .foregroundColor(theme.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Verifying identity", bundle: .module)
                            .font(theme.font(size: 11))
                            .foregroundColor(theme.secondaryText)
                        Text(fingerprint)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                            .textSelection(.enabled)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.accentColor.opacity(0.08))
                )
            }

            if let error = errorMessage {
                Text(error)
                    .font(theme.font(size: 12))
                    .foregroundColor(theme.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button {
                    onCancel()
                } label: {
                    Text("Cancel", bundle: .module)
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isPairing)
                Spacer()
                if isPairing {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 4)
                } else {
                    Button {
                        Task { await performPairing() }
                    } label: {
                        Text("Pair", bundle: .module)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func performPairing() async {
        isPairing = true
        errorMessage = nil
        defer { isPairing = false }

        do {
            let (apiKey, isPermanent) = try await PairingClient.pair(with: agent)
            onSuccess(apiKey, isPermanent)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Pairing Client

private enum PairingClient {
    struct PairRequestBody: Codable {
        let connectorAddress: String
        let agentId: String
        let nonce: String
        let signature: String
        let encPub: String?
    }

    struct PairResponseBody: Codable {
        let agentAddress: String
        let apiKey: String
        let isPermanent: Bool
        let serverSignature: String?
        let sealedApiKey: PairingKeyEnvelope.Sealed?
    }

    struct ChallengeResponseBody: Codable {
        let nonce: String
    }

    enum PairingError: LocalizedError {
        case missingHost
        case signFailed
        case networkError(Int)
        case decodingFailed
        case denied
        case challengeFailed
        case identityMismatch
        case unverifiablePeer

        var errorDescription: String? {
            switch self {
            case .missingHost: return "Could not resolve the agent's network address."
            case .signFailed: return "Failed to sign the pairing request."
            case .networkError(let code): return "Pairing request failed (HTTP \(code))."
            case .decodingFailed: return "Unexpected response from the remote device."
            case .denied: return "Pairing was denied by the remote device."
            case .challengeFailed: return "Could not obtain a pairing challenge from the remote device."
            case .identityMismatch:
                return "The remote device could not prove it owns the discovered agent identity."
            case .unverifiablePeer:
                return
                    "This agent claims to support encryption but didn't advertise a verifiable identity, so pairing was refused."
            }
        }
    }

    static func pair(with agent: DiscoveredAgent) async throws -> (apiKey: String, isPermanent: Bool) {
        // Defense-in-depth: refuse a peer claiming Secure Channel support
        // (osc=1) that advertised no address to pin. The address-gated
        // verification below would otherwise be skipped entirely, leaving the
        // server unauthenticated. (The sheet routing already diverts these to
        // a refusal view; this guard fails closed if pair() is ever reached.)
        guard !agent.isUnverifiableSecureChannelPeer else {
            throw PairingError.unverifiablePeer
        }

        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 300

        var masterKey = try MasterKey.getPrivateKey(context: context)
        defer {
            masterKey.withUnsafeMutableBytes { ptr in
                if let base = ptr.baseAddress { memset(base, 0, ptr.count) }
            }
        }

        let connectorAddress = try PairingKey.deriveAddress(masterKey: masterKey)

        // Prefer the `.local` hostname; fall back to the resolved IP when the
        // peer advertised no hostname (or it can't be resolved on this network).
        let rawHost = agent.connectHost ?? ""
        guard !rawHost.isEmpty else { throw PairingError.missingHost }
        let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost

        // 1. Fetch a server-issued single-use challenge nonce. Signing this
        //    (instead of a self-chosen nonce) is what makes a sniffed `/pair`
        //    body non-replayable.
        let nonce = try await fetchChallenge(host: host, port: agent.port)

        // 2. Ephemeral X25519 key for HPKE: the minted credential comes back
        //    sealed to this key, so it never crosses the cleartext LAN hop in
        //    plaintext. Signing "<nonce>:<encPub>" binds the key to us — a
        //    MITM can't swap in their own without changing the connector
        //    address shown in the approval prompt.
        let (encPrivateKey, encPub) = PairingKeyEnvelope.generateRecipientKey()

        let signature = try PairingKey.sign(
            payload: Data("\(nonce):\(encPub)".utf8),
            masterKey: masterKey
        )
        let hexSig = "0x" + signature.hexEncodedString

        let urlString = "http://\(host):\(agent.port)/pair"
        guard let url = URL(string: urlString) else { throw PairingError.missingHost }

        let body = PairRequestBody(
            connectorAddress: connectorAddress,
            agentId: agent.id.uuidString,
            nonce: nonce,
            signature: hexSig,
            encPub: encPub
        )
        let bodyData = try JSONEncoder().encode(body)

        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (responseData, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        if statusCode == 403 { throw PairingError.denied }
        guard statusCode == 200 else { throw PairingError.networkError(statusCode) }

        guard let decoded = try? JSONDecoder().decode(PairResponseBody.self, from: responseData) else {
            throw PairingError.decodingFailed
        }

        // 3. Verify the responder controls the agent address we discovered over
        //    Bonjour. If the TXT record advertised a crypto address, the server
        //    MUST prove control of it by signing our challenge with the agent
        //    key; otherwise a spoofed advertiser / MITM could hand us a key.
        if let expectedAddress = agent.address, !expectedAddress.isEmpty {
            try verifyServerIdentity(
                decoded: decoded,
                expectedAddress: expectedAddress,
                nonce: nonce
            )
        }

        // 4. We sent `encPub`, so the credential MUST come back sealed. Fail
        //    closed on a plaintext (or missing) key so a downgrade-stripping
        //    MITM can't force the key onto the cleartext hop.
        guard let sealed = decoded.sealedApiKey else { throw PairingError.decodingFailed }
        let apiKey = try PairingKeyEnvelope.open(
            sealed,
            privateKey: encPrivateKey,
            info: PairingKeyEnvelope.info(agentAddress: decoded.agentAddress, nonce: nonce)
        )

        return (apiKey: apiKey, isPermanent: decoded.isPermanent)
    }

    private static func fetchChallenge(host: String, port: Int) async throws -> String {
        guard let url = URL(string: "http://\(host):\(port)/pair/challenge") else {
            throw PairingError.missingHost
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard statusCode == 200,
            let decoded = try? JSONDecoder().decode(ChallengeResponseBody.self, from: data),
            !decoded.nonce.isEmpty
        else {
            throw PairingError.challengeFailed
        }
        return decoded.nonce
    }

    private static func verifyServerIdentity(
        decoded: PairResponseBody,
        expectedAddress: String,
        nonce: String
    ) throws {
        // The server must return the agent address we expect and a signature
        // over the challenge that recovers to that same address.
        guard decoded.agentAddress.lowercased() == expectedAddress.lowercased(),
            let serverSignature = decoded.serverSignature
        else {
            throw PairingError.identityMismatch
        }
        let hex =
            serverSignature.hasPrefix("0x") ? String(serverSignature.dropFirst(2)) : serverSignature
        guard let sigBytes = Data(hexEncoded: hex),
            let recovered = try? recoverAddress(
                payload: pairingServerSigningPayload(agentAddress: decoded.agentAddress, nonce: nonce),
                signature: sigBytes,
                domainPrefix: "Osaurus Signed Pairing Server"
            ),
            recovered.lowercased() == expectedAddress.lowercased()
        else {
            throw PairingError.identityMismatch
        }
    }
}

// MARK: - Shared Header Components
// HeaderActionButton, SettingsButton, CloseButton, PinButton are now in SharedHeaderComponents.swift
