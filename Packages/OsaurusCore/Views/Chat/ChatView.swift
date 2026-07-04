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

/// Lifecycle of the generative greeting for a single chat session. Drives
/// the empty-state UI: `.idle` and `.failed` render the static greeting +
/// the agent's configured quick actions, `.loading` renders an animated
/// skeleton, and `.ready` renders the freshly produced AI payload with a
/// shimmer fade-in. A separate `.failed` (vs `.idle`) lets the UI know the
/// loader actually completed without a result so it doesn't re-trigger
/// from a stale state.
enum GenerativeGreetingState: Equatable {
    case idle
    case loading
    case ready(GenerativeGreeting)
    case failed
}

/// Lifts the empty-state's "kick off a generative greeting" wiring out of
/// `ChatView.body` so the closure stays small enough for the type checker.
/// Re-runs `loadGenerativeGreetingIfNeeded` whenever the selected model or
/// active agent changes; the session-level cache key absorbs idempotent
/// re-fires (re-appearing the empty state, scrolling, etc.).
private struct GenerativeGreetingTrigger: ViewModifier {
    @ObservedObject var session: ChatSession
    @ObservedObject var windowState: ChatWindowState

    func body(content: Content) -> some View {
        content
            .onAppear { trigger() }
            .onChange(of: session.selectedModel) { _, _ in trigger() }
            .onChange(of: windowState.agentId) { _, _ in trigger() }
    }

    private func trigger() {
        // AI greetings are a per-agent opt-in; the agent's own flag is
        // the sole control.
        session.loadGenerativeGreetingIfNeeded(agent: windowState.activeAgent)
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
    @Published var turns: [ChatTurn] = []
    @Published var isStreaming: Bool = false {
        didSet {
            guard isStreaming != oldValue else { return }
            if isStreaming {
                ChatPerfTrace.shared.begin("stream-\(Int(Date().timeIntervalSince1970))")
            } else {
                ChatPerfTrace.shared.end()
            }
        }
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
    /// `.awaitingClarification`, emit the type-3 CLARIFICATION event with
    /// the parsed payload to the source plugin, and suppress the spurious
    /// COMPLETED that would otherwise fire when `isStreaming` goes false
    /// on the intercept.
    @Published var awaitingClarify: ClarifyPayload?

    /// Tracks expand/collapse state for tool calls, thinking blocks, etc.
    /// Lives on the session so state survives NSTableView cell reuse.
    let expandedBlocksStore = ExpandedBlocksStore()

    /// Thinking-block ids already auto-expanded once for a completed
    /// reasoning-only turn. Seeding the shared `expandedBlocksStore` (rather
    /// than force-expanding in the cell) lets the user collapse the block
    /// afterward; this set stops us re-expanding it on the next rebuild.
    private var autoExpandedReasoningBlockIds: Set<String> = []
    @Published var input: String = ""
    @Published var pendingAttachments: [Attachment] = []
    @Published var selectedModel: String? = nil
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
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// Origin of this session — populated by `ExecutionContext` for headless
    /// (plugin / HTTP / scheduler / watcher) runs, defaults to `.chat` for
    /// user-driven UI sessions.
    var source: SessionSource = .chat
    var sourcePluginId: String?
    var externalSessionKey: String?
    var dispatchTaskId: UUID?
    /// Mirrors `ChatSessionData.archived`. Required here so `toSessionData()`
    /// round-trips the flag instead of stamping `false` on every save.
    var archived: Bool = false

    /// Tracks if session has unsaved content changes
    private var isDirty: Bool = false
    /// Session id whose first persisted turn belongs to the active send.
    /// Used to undo transient rows on privacy-review cancels, including
    /// pre-minted empty session ids.
    private var transientSessionIdForCurrentRun: UUID?
    /// Whether this run appended a new user turn. Regeneration sends reuse
    /// historical user turns and must not pop one during privacy-cancel rollback.
    private var appendedUserTurnForCurrentRun = false
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

    private var thinkingEnabledForCurrentModel: Bool {
        guard let selectedModel else {
            return activeModelOptions["disableThinking"]?.boolValue == false
        }
        return ModelProfileRegistry.thinkingEnabled(
            for: selectedModel,
            values: activeModelOptions
        ) ?? false
    }
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

    /// Per-session always-loaded + capabilities_load tool kit lives in the
    /// process-wide `SessionToolStateStore` so chat sessions and the
    /// HTTP/plugin path share one cache. Keyed by `sessionId.uuidString`.
    private var sessionStateKey: (UUID) -> String { { $0.uuidString } }

    // MARK: - Agent Loop State (Chat-as-Agent)

    /// The agent's current todo for this chat, mirrored from
    /// `AgentTodoStore` via `.agentTodoChanged`. Read-only from the UI's
    /// perspective — only the `todo` tool writes to it.
    @Published var currentTodo: AgentTodo?

    /// Last `complete(summary)` payload from the agent. Populated when
    /// the engine intercepts `complete` and breaks the loop. The chat
    /// view renders it as a "Completed" banner inline.
    @Published var lastCompletionSummary: String?

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

    /// Lifecycle of the generative greeting for the current empty state.
    /// Drives skeleton vs static vs AI-produced rendering — see
    /// `GenerativeGreetingState`. Populated by
    /// `loadGenerativeGreetingIfNeeded(...)`, reset on `reset()`.
    @Published var generativeGreetingState: GenerativeGreetingState = .idle

    /// In-flight generation, retained so we can cancel it on reset / send /
    /// teardown. The state machine on `generativeGreetingState` is what the
    /// UI observes; the task is kept here purely for cooperative cancel.
    private var generativeGreetingTask: Task<Void, Never>?

    /// Cache key for the most recently kicked-off generation. Encodes
    /// session id, agent id, and model so the call only re-runs when one
    /// of those actually changed (re-appearing the empty state for the
    /// same context is a no-op).
    private var generativeGreetingKey: String?

    /// Weak back-reference to the owning window state (set by ChatWindowState).
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
    /// Set to true at the start of `stop()` so `completeRunCleanup` knows the
    /// run was cancelled by the user (or by `sendNowInterrupting`) and must
    /// not auto-flush a queued send. Reset to false at the top of `send(...)`.
    private var stopRequested: Bool = false
    var chatEngineFactory: @MainActor () -> ChatEngineProtocol = {
        ChatEngine(source: .chatUI)
    }
    // nonisolated(unsafe) allows deinit to access these for cleanup
    nonisolated(unsafe) private var remoteModelsObserver: NSObjectProtocol?
    nonisolated(unsafe) private var modelSelectionCancellable: AnyCancellable?
    nonisolated(unsafe) private var agentAutoSpeakCancellable: AnyCancellable?
    /// Direct subscription to the shared model-picker cache. The
    /// `.remoteProviderModelsChanged` notification bridge above only
    /// *triggers* a rebuild; this makes the session's `pickerItems`
    /// follow the cache's atomic `items` assignment so a newly connected
    /// remote provider shows up in the picker live, without reopening the
    /// window (mirrors `AgentsView`'s `$items` subscription).
    nonisolated(unsafe) private var modelCacheCancellable: AnyCancellable?
    /// Flag to prevent auto-persist during initial load or programmatic resets
    private var isLoadingModel: Bool = false

    nonisolated(unsafe) private var localModelsObserver: NSObjectProtocol?
    /// Observer for `.privacyFilterRedactionsApproved`. Folds every
    /// approved (original, placeholder) pair into this window's
    /// `sessionRedactions` dict so user + assistant bubbles can
    /// inline-highlight the matching spans on rebuild. Filtered by
    /// this session's `sessionId.uuidString` to avoid cross-window
    /// leakage when multiple chats are open.
    nonisolated(unsafe) private var privacyRedactionsObserver: NSObjectProtocol?
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
                guard let self = self, !self.isLoadingModel, let model = newModel else { return }
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

                Task { @MainActor in
                    let active = ChatWindowManager.shared.activeLocalModelNames()
                    await ModelRuntime.shared.unloadModelsNotIn(active)
                }
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
        let voidNotification: (Notification.Name) -> AnyPublisher<Void, Never> = {
            NotificationCenter.default.publisher(for: $0)
                .map { _ in () }.eraseToAnyPublisher()
        }
        let budgetSignals: [AnyPublisher<Void, Never>] = [
            voidNotification(.agentUpdated),
            voidNotification(.activeAgentChanged),
            voidNotification(.toolsListChanged),
            FolderContextService.shared.objectWillChange
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

    deinit {
        print("[ChatSession] deinit")
        currentTask?.cancel()
        generativeGreetingTask?.cancel()
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
        if let observer = storageMutationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        modelSelectionCancellable = nil
        agentAutoSpeakCancellable = nil
        promptQueueCancellable = nil
        contextEstimateCancellable = nil
        modelCacheCancellable = nil
        screenContextCancellable = nil
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

    /// Pick the picker item that best matches the agent's preferred model
    /// (falling back to the first chat-capable item). Wrapped in
    /// `isLoadingModel = true` so the auto-persist sink in `init()` does
    /// not write the selection back to the agent's settings as if the
    /// user had manually changed it.
    private func applyEffectiveModel(for agentId: UUID?) {
        isLoadingModel = true
        let effectiveModel = AgentManager.shared.effectiveModel(for: agentId ?? Agent.defaultId)
        if let model = effectiveModel, pickerItems.contains(where: { $0.id == model }) {
            selectedModel = model
        } else {
            selectedModel = pickerItems.firstChatCapable?.id
        }
        loadActiveModelOptions(for: selectedModel)
        applyImageModelDefaults(for: selectedModel)
        isLoadingModel = false
    }

    func refreshPickerItems() async {
        let newOptions = await ModelPickerItemCache.shared.buildModelPickerItems()
        applyPickerItems(newOptions)
    }

    /// Reconcile the session against a fresh picker list. Shared by the
    /// explicit `refreshPickerItems()` (which first triggers a rebuild) and
    /// the `$items` subscription (which receives the cache's already-rebuilt
    /// list). Idempotent: a no-op when the option ids are unchanged.
    func applyPickerItems(_ newOptions: [ModelPickerItem]) {
        let newOptionIds = newOptions.map { $0.id }
        let optionsChanged = pickerItems.map({ $0.id }) != newOptionIds

        isDiscoveringModels = false

        guard optionsChanged else { return }

        // Options changed (e.g., remote models loaded) - re-check agent's preferred model.
        // This corrects the initial fallback to "foundation" when remote models weren't yet available.
        let effectiveModel = AgentManager.shared.effectiveModel(for: agentId ?? Agent.defaultId)
        let newSelected: String?

        if let model = effectiveModel, newOptionIds.contains(model) {
            newSelected = model
        } else if let prev = selectedModel, newOptionIds.contains(prev) {
            newSelected = prev
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

    /// Whether `modelId` can accept image input. Remote models are NOT assumed
    /// vision-capable: a plain remote provider (incl. a Mode 1 `.osaurus`
    /// device) exposes a flat model list with no capability metadata, so a
    /// remote item's `isVLM` is false unless the id-based heuristic matched or
    /// router metadata set it — sending images to a non-VLM remote model just
    /// gets rejected upstream.
    static func modelSupportsImages(modelId: String, pickerItems: [ModelPickerItem]) -> Bool {
        if modelId.lowercased() == "foundation" { return false }
        if ModelMediaCapabilities.from(modelId: modelId).supportsImage { return true }
        guard let option = pickerItems.first(where: { $0.id == modelId }) else { return false }
        // Image-edit models accept image input (osaurus image-edit feature).
        if option.imageCapabilities?.imageEdit == true { return true }
        return option.isVLM
    }

    var selectedModelSupportsAudio: Bool {
        guard let model = selectedModel else { return false }
        return ModelMediaCapabilities.from(modelId: model).supportsAudio
    }

    var selectedModelSupportsVideo: Bool {
        guard let model = selectedModel else { return false }
        return ModelMediaCapabilities.from(modelId: model).supportsVideo
    }

    /// Get the currently selected ModelPickerItem
    var selectedPickerItem: ModelPickerItem? {
        guard let model = selectedModel else { return nil }
        return pickerItems.first { $0.id == model }
    }

    var selectedImagePickerItem: ModelPickerItem? {
        guard let model = selectedModel else { return nil }
        return pickerItems.first { $0.id == model && $0.source.isImageGeneration }
    }

    private func applyImageModelDefaults(for model: String?) {
        guard let model,
            let item = pickerItems.first(where: { $0.id == model && $0.source.isImageGeneration })
        else { return }
        var settings = imageComposerSettings
        settings.applyModelDefaults(steps: item.imageDefaultSteps, guidance: item.imageDefaultGuidance)
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
        return ModelManager.findInstalledModel(named: model) != nil
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
        let localName = agent?.isBuiltIn == true ? L("Osaurus") : (agent?.name ?? L("Osaurus"))
        // In Mode 2 the remote agent owns the conversation, so its name heads
        // the thread; otherwise fall back to the local agent's name.
        let displayName = threadAgentDisplayName ?? localName
        let streamingTurnId = isStreaming ? turns.last?.id : nil

        if MockChatData.isEnabled {
            let mockTurns = MockChatData.mockTurnsForPerformanceTest()
            let newBlocks = blockMemoizer.blocks(
                from: mockTurns,
                streamingTurnId: nil,
                agentName: displayName,
                thinkingEnabled: thinkingEnabledForCurrentModel
            )
            let newHeaderMap = blockMemoizer.groupHeaderMap
            withAnimation(.none) {
                visibleBlocksStore.blocks = newBlocks
                visibleBlocksStore.groupHeaderMap = newHeaderMap
            }
            return
        }

        seedAutoExpandedReasoningBlocks(streamingTurnId: streamingTurnId)

        let newBlocks = blockMemoizer.blocks(
            from: turns,
            streamingTurnId: streamingTurnId,
            agentName: displayName,
            thinkingEnabled: thinkingEnabledForCurrentModel
        )
        let newHeaderMap = blockMemoizer.groupHeaderMap

        // use withAnimation(.none) to suppress the warning about publishing during view updates
        // this wraps the changes in a proper SwiftUI transaction
        withAnimation(.none) {
            visibleBlocksStore.blocks = newBlocks
            visibleBlocksStore.groupHeaderMap = newHeaderMap
        }
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

    /// Estimated token count for current session context (~4 chars per token).
    /// Throttled to at most once per 500ms during streaming.
    var estimatedContextTokens: Int {
        estimatedContextBreakdown.total
    }

    /// Per-category breakdown of estimated context tokens.
    /// During streaming, returns the active snapshot with live output tokens.
    /// Otherwise derives from the cached `ComposedContext` or a preview manifest.
    var estimatedContextBreakdown: ContextBreakdown {
        if let active = budgetTracker.activeBreakdown(
            isActive: isStreaming,
            outputTurn: turns.last
        ) {
            return active
        }

        let outputTokens = ContextBudgetManager.estimateOutputTokens(for: turns)
        let conversationTokens = ContextBudgetManager.estimateTokens(for: turns) - outputTokens
        var inputTokens = 0
        if !input.isEmpty { inputTokens += ContextBudgetManager.estimateTokens(for: input) }
        for attachment in pendingAttachments { inputTokens += attachment.estimatedTokens }

        if let ctx = cachedContext {
            return .from(
                context: ctx,
                screenContextTokens: cachedScreenContextTokens,
                conversationTokens: conversationTokens,
                inputTokens: inputTokens,
                outputTokens: outputTokens
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
            return .from(
                manifest: .empty,
                memoryTokens: cachedMemoryTokens,
                screenContextTokens: cachedScreenContextTokens,
                conversationTokens: conversationTokens,
                inputTokens: inputTokens,
                outputTokens: outputTokens
            )
        }
        return .from(
            manifest: preview.manifest,
            toolTokens: preview.toolTokens,
            memoryTokens: cachedMemoryTokens,
            screenContextTokens: cachedScreenContextTokens,
            conversationTokens: conversationTokens,
            inputTokens: inputTokens,
            outputTokens: outputTokens
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

    /// Compose a fresh welcome/pre-send preview from the current agent /
    /// sandbox / tool / folder / model state. Pure — no caching, no
    /// `objectWillChange`. Single source of truth for the lazy read
    /// (`previewContext`) and the budget-input recompute
    /// (`recomputePreviewContext`).
    private func composePreview() -> ComposedContext {
        let effectiveId = agentId ?? Agent.defaultId
        return SystemPromptComposer.composePreviewContext(
            agentId: effectiveId,
            executionMode: estimatedChatExecutionMode(agentId: effectiveId),
            model: selectedModel
        )
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
        guard !isStreaming else { return }
        // One local generation at a time across all windows: the shared
        // inference context can't run two, and loading a second would evict and
        // cancel the active one. Surface the alert and keep the draft intact.
        if localModelBusyInOtherWindow {
            windowState?.showLocalModelBusyAlert = true
            return
        }
        let text = input
        let attachments = pendingAttachments
        input = ""
        pendingAttachments = []
        send(text, attachments: attachments)
    }

    func stop() {
        stopRequested = true
        let task = currentTask
        task?.cancel()
        if let runId = activeRunId {
            finalizeRun(runId: runId, persistConversationArtifacts: false)
        } else {
            completeRunCleanup()
        }
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
        turns.append(turn)
        isDirty = true
        rebuildVisibleBlocks()
        // A new user message resets the within-message dedupe/bias tracking,
        // mirroring what `send(...)` does at the top of a run.
        taskState.beginMessage()
        return true
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
        if isStreaming || activeRunId != nil {
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
        voiceInputState = .idle
        showVoiceOverlay = false
        transientSessionIdForCurrentRun = nil
        appendedUserTurnForCurrentRun = false
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
        createdAt = Date()
        updatedAt = Date()
        source = .chat
        sourcePluginId = nil
        externalSessionKey = nil
        dispatchTaskId = nil
        archived = false
        isDirty = false

        // Reset agent-loop UI state.
        currentTodo = nil
        lastCompletionSummary = nil
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

        resetGenerativeGreeting()

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

    // MARK: - Generative Greeting

    /// Asynchronously fetch (and cache) a delightful greeting + four quick
    /// actions for the current empty state. Idempotent for a given
    /// `(session, agent, model)` combination — re-appearing the empty
    /// state, scrolling, or theme changes won't re-fire the inference.
    ///
    /// State machine: `idle` (feature off / no model) → `loading` (task in
    /// flight) → `ready(payload)` on success, `failed` on any throw or
    /// cancellation. The UI uses `loading` to render a skeleton, and both
    /// `idle` and `failed` to render the static fallback.
    func loadGenerativeGreetingIfNeeded(agent: Agent) {
        // No local greeting generation when the feature is off, or for a
        // remote-agent chat (Mode 2) — the latter would load a local model
        // purely for empty-state flavor text and stamp the local persona onto a
        // remote conversation. The empty state shows the remote agent's
        // name/avatar and the static greeting instead.
        guard !isRemoteAgentTarget, agent.shouldUseGenerativeGreetings else {
            resetGenerativeGreeting()
            return
        }

        guard hasAnyModel else { return }
        guard let model = selectedModel, !model.isEmpty else { return }

        let sessionPart = sessionId?.uuidString ?? "draft"
        let key = "\(sessionPart):\(agent.id.uuidString):\(model)"
        if key == generativeGreetingKey { return }

        generativeGreetingKey = key
        generativeGreetingTask?.cancel()

        let snapshot = agent
        generativeGreetingTask = Task { [weak self] in
            // Tell the pool which (agent, model) the user is looking
            // at so its periodic ticker has a refill target even when
            // no popFresh / warmUp call is in flight.
            await GenerativeGreetingPool.shared.setActive(
                agent: snapshot,
                model: model
            )

            // Hot path: a pre-generated greeting is already waiting.
            // Skip the loading skeleton entirely and ride straight to
            // `.ready`, then fire a background warmUp to top the pool
            // back up to target.
            if let cached = await GenerativeGreetingPool.shared.popFresh(
                for: snapshot,
                model: model
            ) {
                // Commit to the UI atomically: only assign `.ready` if
                // the task hasn't been cancelled and the cache key
                // still matches. If it doesn't match (rapid hide/show,
                // agent switch landed mid-pop), push the cached entry
                // BACK into the pool — it cost us a model call to
                // produce, throwing it away on every fast switch is
                // wasteful. Returning a `Bool` from `MainActor.run`
                // lets us keep the commit guard atomic without
                // splitting it across two hops.
                let didCommit = await MainActor.run { () -> Bool in
                    guard let self = self else { return false }
                    guard !Task.isCancelled,
                        self.generativeGreetingKey == key
                    else { return false }
                    self.generativeGreetingState = .ready(cached)
                    return true
                }
                if !didCommit {
                    await GenerativeGreetingPool.shared.seed(
                        cached,
                        for: snapshot,
                        model: model
                    )
                    return
                }
                await GenerativeGreetingPool.shared.warmUp(
                    for: snapshot,
                    model: model
                )
                return
            }

            // Don't start a local greeting generation while another window is
            // already running a local model. The shared inference context runs
            // one generation at a time, so a greeting load here would stall behind
            // the active user stream (and on the strict-eviction path could
            // disturb it). Fall back to the static greeting; the pool refills
            // once inference goes idle. Remote/foundation greetings don't
            // contend, so they're unaffected.
            // Resolve whether the greeting model is local off the main thread.
            // `findInstalledModel` funnels into `discoverLocalModels`, which
            // blocks on a condition wait (up to the scan wait-limit) while the
            // background disk scan runs. This closure inherits the main actor
            // from its enclosing method, so the wait was freezing the app while
            // an empty-state greeting loaded.
            let greetingModelIsLocal = await Task.detached(priority: .userInitiated) {
                ModelManager.findInstalledModel(named: model) != nil
            }.value
            let localStreamBusy = await MainActor.run {
                ChatWindowManager.shared.isAnyWindowStreamingLocalModel
            }
            if greetingModelIsLocal, localStreamBusy {
                await MainActor.run {
                    guard let self = self else { return }
                    guard self.generativeGreetingKey == key else { return }
                    self.generativeGreetingState = .failed
                }
                return
            }

            // Cold path: pool was empty (first session of the run, or
            // an invalidation just landed). Flip to `.loading` so the
            // empty state renders the skeleton, then generate inline
            // and seed the pool with the result so the *next* session
            // open is hot.
            await MainActor.run {
                guard let self = self else { return }
                guard self.generativeGreetingKey == key else { return }
                self.generativeGreetingState = .loading
            }
            do {
                let result = try await GenerativeGreetingService.shared.generate(
                    agent: snapshot,
                    fallbackModel: model
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self = self else { return }
                    guard self.generativeGreetingKey == key else { return }
                    self.generativeGreetingState = .ready(result)
                }
                await GenerativeGreetingPool.shared.warmUp(
                    for: snapshot,
                    model: model
                )
            } catch {
                guard !Task.isCancelled else { return }
                // Silent fallback — `.failed` flips the empty state back
                // to the static greeting + the agent's configured quick
                // actions. `.idle` is reserved for "feature is off" so
                // the UI can distinguish the two.
                await MainActor.run {
                    guard let self = self else { return }
                    guard self.generativeGreetingKey == key else { return }
                    self.generativeGreetingState = .failed
                }
            }
        }
    }

    /// Cancel any in-flight greeting generation and clear cached output.
    /// Called from `reset()`, `deinit`, and `ChatWindowManager.hideWindow`
    /// — the latter so re-opening the window pops a fresh entry from the
    /// pool instead of briefly flashing the previous session's greeting.
    func resetGenerativeGreeting() {
        generativeGreetingTask?.cancel()
        generativeGreetingTask = nil
        generativeGreetingKey = nil
        generativeGreetingState = .idle
    }

    /// Invalidate the token cache (called when tools/skills change)
    func invalidateTokenCache() {
        cachedContext = nil
        cachedPreviewContext = nil
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
            capabilities: SessionCapability.derive(from: turnData)
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
        ChatSessionsManager.shared.save(data)
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
        createdAt = data.createdAt
        updatedAt = data.updatedAt
        agentId = data.agentId
        source = data.source
        sourcePluginId = data.sourcePluginId
        externalSessionKey = data.externalSessionKey
        dispatchTaskId = data.dispatchTaskId
        archived = data.archived

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
        voiceInputState = .idle
        showVoiceOverlay = false
        input = ""
        pendingAttachments = []
        transientSessionIdForCurrentRun = nil
        appendedUserTurnForCurrentRun = false
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

        Task { [weak self] in await self?.refreshContextEstimates() }
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
    /// that folds prompt sections + tool schemas) plus `toolTokens`, so a
    /// burst of redundant signals (e.g. a sandbox toggle firing both
    /// `.agentUpdated` and `.toolsListChanged`) collapses to no re-render.
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
    private func refreshPreviewEstimate() {
        if recomputePreviewContext() {
            objectWillChange.send()
        }
    }

    /// Re-resolve every input the welcome-screen preview estimate needs —
    /// including the async memory-section estimate — and emit a single
    /// `objectWillChange` when anything actually changed. Driven only by the
    /// lifecycle trigger sites (agent change, session reset, session load),
    /// where it runs at most once per transition. The high-frequency
    /// budget-input pipeline uses `refreshPreviewEstimate()` instead so it
    /// never fans the memory DB read out across every signal.
    private func refreshContextEstimates() async {
        let previewChanged = recomputePreviewContext()
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
            NativeImageToolArtifactBridge.processFirstImageArtifact(
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

    /// Translate a `SharedArtifact.ResolutionFailure` into a
    /// `ToolEnvelope.failure` whose `message` tells the model exactly
    /// what went wrong AND what to try next. The "next" hint is keyed on
    /// `executionMode` so sandbox agents get a `sandbox_search_files`
    /// suggestion while folder agents get `file_read`/`file_search`.
    private static func shareArtifactFailureEnvelope(
        reason: SharedArtifact.ResolutionFailure,
        executionMode: ExecutionMode
    ) -> String {
        let toolName = "share_artifact"
        let listingHint: String
        switch executionMode {
        case .sandbox:
            listingHint =
                "Verify the file with `sandbox_search_files(target=\"files\", pattern=\"<name>\")`, "
                + "or pass `content`+`filename` for inline data."
        case .hostFolder:
            listingHint =
                "Verify the file with `file_read`/`file_search`, or pass `content`+`filename` "
                + "for inline data."
        case .none:
            listingHint =
                "Pass `content`+`filename` for inline data, or attach a working folder/sandbox first."
        }

        // Local helpers prefix every message with `share_artifact failed: `
        // and fill in the always-the-same `tool` / `retryable` fields, so
        // the per-case branches read at the level of the actual diagnostic.
        func fail(
            _ kind: ToolEnvelope.Kind,
            _ message: String,
            field: String? = nil,
            expected: String? = nil
        ) -> String {
            ToolEnvelope.failure(
                kind: kind,
                message: "share_artifact failed: \(message)",
                field: field,
                expected: expected,
                tool: toolName,
                retryable: true
            )
        }

        switch reason {
        case .markersMissing:
            return fail(
                .executionError,
                "marker block missing from tool result. This is a tool-runtime bug — "
                    + "retry once; if it persists, share the content inline."
            )
        case .noContentOrPath:
            return fail(
                .invalidArgs,
                "neither `path` nor `content` was provided. Pass an existing file path, "
                    + "or `content`+`filename` for inline text."
            )
        case .destinationRejected(let filename):
            return fail(
                .invalidArgs,
                "filename `\(filename)` was rejected (would escape the artifacts directory). "
                    + "Pass a plain basename like `report.md`.",
                field: "filename",
                expected: "single-segment filename without `..` or absolute path"
            )
        case .pathRejected(let path):
            return fail(
                .invalidArgs,
                "path `\(path)` was rejected (escapes the trusted root, is an unrelated absolute "
                    + "path, or contains traversal). \(listingHint)",
                field: "path",
                expected: "path under the agent home / working folder"
            )
        case .fileNotFound(let path, let searchedLocations):
            let searchedSummary =
                searchedLocations.isEmpty
                ? "(no candidates resolved)"
                : searchedLocations.joined(separator: ", ")
            return fail(
                .executionError,
                "file not found for `\(path)`. Searched: \(searchedSummary). \(listingHint)"
            )
        case .copyFailed(let source, let detail):
            return fail(
                .executionError,
                "copy from `\(source)` to artifacts dir threw: \(detail). "
                    + "Retry once; if it persists, share the content inline."
            )
        }
    }

    private struct RunContext {
        let hasContent: Bool
        let userContent: String
        let memoryAgentId: String
        let memoryConversationId: String
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
            lastTurn.routerBilling == nil
        {
            turns.removeLast()
        }
    }

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
        agentId == Agent.defaultId ? nil : FolderContextService.shared.currentContext
    }

    private func estimatedChatExecutionMode(agentId: UUID) -> ExecutionMode {
        let folder = activeFolderContext(for: agentId)
        let autonomous = AgentManager.shared.effectiveAutonomousExec(for: agentId)?.enabled == true
        let resolved = ToolRegistry.shared.resolveExecutionMode(
            folderContext: folder,
            autonomousEnabled: autonomous
        )
        // Optimistic estimate: when autonomous is on but sandbox tools haven't
        // registered yet, report `.sandbox` so the budget preview matches what
        // the next send will most likely produce after `registerTools` runs.
        // Thread the folder through so the combined sandbox + host-read mode
        // is estimated correctly when a folder is also mounted.
        if autonomous && resolved.usesSandboxTools == false {
            return .sandbox(hostRead: folder)
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
        if !suppressQueuedSendFlushForCurrentRun {
            flushQueuedSendIfEligible()
        }
        suppressQueuedSendFlushForCurrentRun = false
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
        activeRunId = nil
        activeRunContext = nil
        completeRunCleanup()

        guard persistConversationArtifacts, let context else { return }

        if let lastAssistant = turns.last(where: { $0.role == .assistant }),
            !lastAssistant.contentIsBlank || lastAssistant.hasRenderableThinking
        {
            lastCompletedAssistantTurnId = lastAssistant.id
        }

        let assistantContent = turns.last(where: { $0.role == .assistant })?.content

        let agentUUID = UUID(uuidString: context.memoryAgentId) ?? Agent.defaultId
        let memoryOff = AgentManager.shared.effectiveMemoryDisabled(for: agentUUID)

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

        if !memoryOff, context.hasContent {
            let formatter = Self.sessionDateFormatter
            formatter.timeZone = .current
            let today = formatter.string(from: Date())
            Task.detached {
                await MemoryService.shared.bufferTurn(
                    userMessage: context.userContent,
                    assistantMessage: assistantContent,
                    agentId: context.memoryAgentId,
                    conversationId: context.memoryConversationId,
                    sessionDate: today
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
        let autonomous = AgentManager.shared.effectiveAutonomousExec(for: agentId)?.enabled == true
        if autonomous {
            await SandboxToolRegistrar.shared.registerTools(for: agentId)
        }
        return ToolRegistry.shared.resolveExecutionMode(
            folderContext: activeFolderContext(for: agentId),
            autonomousEnabled: autonomous
        )
    }

    // MARK: - Private Helpers

    /// Processes the streaming delta loop from the chat engine, updating the given
    /// assistant turn and UI state. Returns any parsed tool invocations and the
    /// final updated assistant turn.
    private func processStreamDeltas(
        stream: AsyncThrowingStream<String, Error>,
        assistantTurn: ChatTurn,
        runId: UUID,
        streamStartTime: Date,
        ttftTrace: TTFTTrace?,
        selectedModel: String?
    ) async throws -> (invocations: [ServiceToolInvocation], finalTurn: ChatTurn) {
        var currentTurn = assistantTurn
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

        // The engine surfaces parsed tool calls by *throwing* a
        // `ServiceToolInvocation` (or `ServiceToolInvocations`) at end-of-
        // stream. Catch them so this function can return them as data —
        // letting the throw escape would surface as an "Error: …
        // ServiceToolInvocation error 1" string in the UI.
        var capturedInvocations: [ServiceToolInvocation] = []

        debugLog("send: got stream, entering delta loop")
        do {
            for try await delta in stream {
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
                    currentTurn.pendingToolName = toolName.isEmpty ? nil : toolName
                    rebuildVisibleBlocks()
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
                    // Final stats from vmlx — captured for the post-loop
                    // stamp. We DELIBERATELY do NOT overwrite the rolling
                    // rate here: vmlx's `tokensPerSecond` is the full-
                    // generation average, which has the same first-token-
                    // amortisation problem the rolling rate was added to
                    // fix. The rolling rate's steady-state value is used
                    // for the visible bubble after the stream ends; vmlx's
                    // tokenCount is preserved as the authoritative count.
                    currentTurn.generationTokenCount = stats.tokenCount
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
                    // Content delta — counted uniformly with reasoning.
                    let tokens = ContextBudgetManager.estimateTokens(for: delta)
                    rollingRate.observe(tokens: tokens, at: now)
                    refreshLiveRate(
                        rolling: &rollingRate,
                        lastRefreshAt: &lastRateRefreshAt,
                        now: now,
                        turn: currentTurn
                    )
                    processor.receiveDelta(delta)
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
            currentTurn.timeToFirstToken = first.timeIntervalSince(streamStartTime)
            // Stamp the steady-state tok/s. Single source of truth across
            // local-MLX, remote-API, with-tools, and thinking-on/off paths
            // — the rolling rate observed every text-bearing delta during
            // the loop above. Falls back to full-generation average if the
            // response was too short for the warm-up to elapse (see
            // `RollingTokenRate.finalRate`).
            currentTurn.generationTokensPerSecond = rollingRate.finalRate()
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
        currentTurn.completedAt = Date()

        let totalTime = Date().timeIntervalSince(streamStartTime)
        let uiSentinelOnlyCount =
            uiToolSentinelCount + uiReasoningItemCount + uiStatsHintCount
            + uiBillingHintCount + uiPrefillHintCount
        let uiStreamClassification =
            uiDeltaCount == 0 && uiReasoningDeltaCount == 0 && capturedInvocations.isEmpty
            ? (uiSentinelOnlyCount > 0 ? "sentinel-only" : "empty")
            : "non-empty"
        print(
            "[Osaurus][UI] Stream consumption completed: contentDeltas=\(uiDeltaCount) reasoningDeltas=\(uiReasoningDeltaCount) classification=\(uiStreamClassification) in \(String(format: "%.2f", totalTime))s, final contentLen=\(currentTurn.contentLength), toolSentinels=\(uiToolSentinelCount), reasoningItems=\(uiReasoningItemCount), stats=\(uiStatsHintCount), billing=\(uiBillingHintCount), prefill=\(uiPrefillHintCount), capturedTools=\(capturedInvocations.count)"
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
        guard let id, !id.isEmpty else { return false }
        return ModelPickerItemCache.shared.items.contains {
            $0.id == id && $0.source.isImageGeneration
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
        screenContext: String?
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
                screenContext: screenContext
            )
        else { return }
        turn.injectedContextPrefix = prefix
        isDirty = true
    }

    func send(_ text: String, attachments: [Attachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContent = !trimmed.isEmpty || !attachments.isEmpty
        let isRegeneration = !hasContent && !turns.isEmpty
        guard hasContent || isRegeneration else { return }
        guard activeRunId == nil, !isStreaming else {
            restoreTurnsRollbackAfterAbortedRegeneration()
            return
        }

        // Authoritative guard for every send path (interactive, regeneration,
        // queued, VAD, programmatic): never start a local generation while
        // another window is already running one. `sendCurrent` checks this
        // first so the draft survives; this backstops the rest.
        if localModelBusyInOtherWindow {
            windowState?.showLocalModelBusyAlert = true
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
        if promptQueue.current != nil {
            promptQueue.drainAll()
        }
        // Resume from any prior clarify pause BEFORE the new run starts so
        // the BTM streaming-state sink sees `.awaitingClarification`
        // cleared and the next streaming tick transitions the task back
        // to `.running` cleanly. Redundant nil → nil writes are
        // collapsed downstream by `removeDuplicates`.
        awaitingClarify = nil

        if hasContent {
            let sendIntroducesFirstTurn = turns.isEmpty
            // One-shot activation signal — the install's first ever chat-UI
            // message. Inside the `hasContent` branch so a contentless
            // regeneration doesn't count as "used".
            FeatureTelemetry.firstTimeChatUsed()

            turns.append(ChatTurn(role: .user, content: trimmed, attachments: attachments))
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

        let memoryAgentId = (agentId ?? Agent.defaultId).uuidString
        let memoryConversationId = (sessionId ?? UUID()).uuidString

        let runId = UUID()
        beginRun(
            runId,
            context: RunContext(
                hasContent: hasContent,
                userContent: trimmed,
                memoryAgentId: memoryAgentId,
                memoryConversationId: memoryConversationId
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
        let imageSettings = imageComposerSettings

        currentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.isRunActive(runId) else { return }
            await ChatExecutionContext.$currentAgentId.withValue(turnAgentId) { [self] in
                debugLog("send: task started runId=\(runId) model=\(self.selectedModel ?? "nil")")
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
                if self.isImageGenerationModel(self.selectedModel) {
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

                #if DEBUG
                    let ttftTrace: TTFTTrace? = TTFTTrace()
                #else
                    let ttftTrace: TTFTTrace? = nil
                #endif
                do {
                    let engine = chatEngineFactory()
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
                    let liveToolMode = AgentManager.shared.effectiveToolSelectionMode(for: effectiveAgentId)
                    let liveFingerprint = SessionToolState.fingerprint(
                        executionMode: executionMode,
                        toolMode: liveToolMode
                    )
                    let cachedSession: SessionToolState?
                    if let sid = sessionId {
                        let key = sessionStateKey(sid)
                        await SessionToolStateStore.shared.invalidateIfFingerprintChanged(
                            key,
                            liveFingerprint: liveFingerprint
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

                    let context = await SystemPromptComposer.composeChatContext(
                        agentId: effectiveAgentId,
                        executionMode: executionMode,
                        model: selectedModel,
                        query: trimmed,
                        messages: priorUserMessages,
                        toolsDisabled: chatCfg.disableTools,
                        additionalToolNames: cachedSession?.loadedToolNames ?? [],
                        frozenAlwaysLoadedNames: cachedSession?.initialAlwaysLoadedNames,
                        frozenManifest: cachedSession?.frozenManifest,
                        frozenSoul: cachedSession?.frozenSoul,
                        trace: ttftTrace
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

                    // Inject one-off skill if the user selected one via slash command.
                    // Consume the pending id either way, but never append in Mode 2
                    // (the request must stay bare).
                    if let skillId = pendingOneOffSkillId {
                        pendingOneOffSkillId = nil
                        if !isRemoteAgentTarget, let skill = SkillManager.shared.skill(for: skillId) {
                            let section = await SkillManager.shared.buildFullInstructions(for: skill)
                            sys += "\n\n## Active Skill: \(skill.name)\n\n\(section)"
                        }
                    }

                    // FROZEN for the whole run (deferred-schema / KV-prefix
                    // stability): the rendered `<tools>` block never changes
                    // mid-run, even after `capabilities_load`. Loaded tools are
                    // callable immediately by name and their schemas ride in the
                    // tool result (see `CapabilitiesLoadTool.loadedSchemaBlock`);
                    // they fold into `<tools>` on the next user turn. In Mode 2
                    // we send no tools: the remote agent advertises and executes
                    // its own tools server-side and only streams text back.
                    let toolSpecs = isRemoteAgentTarget ? [] : context.tools
                    let isManualTools = liveToolMode == .manual
                    cachedContext = context

                    // Persist the always-loaded snapshot back onto the session
                    // so the next send freezes the schema against tools that
                    // register mid-session. Preserves any capabilities_load
                    // names already accumulated this session. Stamp the live
                    // fingerprint so the invalidation rule above can detect
                    // a flip on the next turn.
                    if let sid = sessionId, cachedSession == nil {
                        await SessionToolStateStore.shared.setInitial(
                            sessionStateKey(sid),
                            alwaysLoadedNames: context.alwaysLoadedNames,
                            fingerprint: liveFingerprint,
                            manifest: context.enabledManifest,
                            soul: context.soul
                        )
                    }

                    budgetTracker.snapshot(context: context)
                    budgetTracker.updateScreenContext(tokens: cachedScreenContextTokens)

                    // Freeze this turn's memory + screen-context prefix into
                    // the turn history BEFORE any messages are rendered: the
                    // injected bytes become part of the turn's permanent
                    // rendering, so turn N+1 replays turn N byte-identically
                    // and the paged KV cache reuses the whole previous
                    // exchange. (Previously the prefix was re-injected onto
                    // whichever user message was latest and vanished from
                    // history on the next turn, re-prefilling the last
                    // exchange every turn.) Skipped in Mode 2: requests stay
                    // bare and the remote agent applies its own context.
                    if !isRemoteAgentTarget {
                        freezeInjectedContextOntoLatestUserTurn(
                            memorySection: context.memorySection,
                            screenContext: screenContextEnabled ? frozenScreenContext : nil
                        )
                    }

                    let effectiveMaxTokensForAgent = AgentManager.shared.effectiveMaxTokens(for: effectiveAgentId)

                    // KV-cache-aware history compaction: shared window
                    // resolution + reservations via `AgentLoopBudget` (parity
                    // with the plugin host's budget manager). Trimming only
                    // activates once the conversation outgrows the history
                    // budget; the system prefix is never rewritten so paged-KV
                    // reuse survives compaction.
                    let loopBudgetManager: ContextBudgetManager = await {
                        let contextWindow = await AgentLoopBudget.resolveContextWindow(
                            modelId: selectedModel ?? "default"
                        )
                        return AgentLoopBudget.makeBudgetManager(
                            contextWindow: contextWindow,
                            systemPromptChars: sys.count,
                            toolTokens: context.toolTokens,
                            maxResponseTokens: effectiveMaxTokensForAgent
                        )
                    }()

                    /// Convert a single turn to a ChatMessage (returns nil if should be skipped)
                    @MainActor
                    func turnToMessage(_ t: ChatTurn, isLastTurn: Bool) -> ChatMessage? {
                        switch t.role {
                        case .assistant:
                            // Skip the last assistant turn if it's empty (it's the streaming placeholder)
                            if isLastTurn && t.contentIsBlank && t.thinkingIsBlank && t.toolCalls == nil {
                                return nil
                            }

                            if t.contentIsBlank && t.thinkingIsBlank && (t.toolCalls == nil || t.toolCalls!.isEmpty) {
                                return nil
                            }

                            let content: String? = t.contentIsBlank ? nil : t.content
                            // DeepSeek's thinking mode requires echoing the
                            // previous `reasoning_content` on follow-ups
                            // (issue #959). `RemoteProviderService` strips it
                            // again for providers that don't need it.
                            let reasoning: String? = t.thinkingIsBlank ? nil : t.thinking

                            return ChatMessage(
                                role: "assistant",
                                content: content,
                                tool_calls: t.toolCalls,
                                tool_call_id: nil,
                                reasoning_content: reasoning,
                                reasoning_item_id: t.reasoningItemId,
                                reasoning_encrypted: t.reasoningEncrypted
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
                                supportsImages: selectedModelSupportsImages,
                                supportsAudio: selectedModelSupportsAudio,
                                supportsVideo: selectedModelSupportsVideo
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

                        for (index, t) in turns.enumerated() {
                            let isLastTurn = index == turns.count - 1
                            if let msg = turnToMessage(t, isLastTurn: isLastTurn) {
                                msgs.append(msg)
                            }
                        }

                        return msgs
                    }

                    let maxAttempts = max(chatCfg.maxToolAttempts ?? 15, 1)
                    // Reset within-message dedupe/bias tracking for this user
                    // turn (lastListing intentionally persists across messages).
                    taskState.beginMessage()
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
                    let effectiveTemp = AgentManager.shared.effectiveTemperature(for: effectiveAgentId)

                    ttftTrace?.mark("pre_ttft_done")

                    // Per-call card override for native image results: the model
                    // keeps the compact `toolPayload` (a small quantized model
                    // parrots the enriched metadata JSON as its answer), while the
                    // artifact card needs the enriched SHARED_ARTIFACT block.
                    var nativeImageCardOverrides: [String: String] = [:]

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
                        owner.setToolResult(nativeImageCardOverrides[callId] ?? result, for: callId)
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

                        // Tools loaded via capabilities_load / sandbox_plugin_register.
                        // Deferred-schema policy (KV-prefix stability): the loaded
                        // tools are callable IMMEDIATELY — the registry dispatches
                        // by name and their schemas ride in the tool result (see
                        // `CapabilitiesLoadTool.loadedSchemaBlock`) — but
                        // `toolSpecs` stays FROZEN for the rest of this run.
                        // Rewriting the rendered `<tools>` block mid-run busts the
                        // paged-KV prefix for the whole conversation. The loaded
                        // names persist into the session's tool union so the NEXT
                        // user turn composes their full schemas into `<tools>`.
                        if inv.toolName == "capabilities_load"
                            || inv.toolName == "sandbox_plugin_register"
                        {
                            // Always drain so a buffered spec can't leak into an
                            // unrelated run; persist only in auto mode (manual
                            // mode keeps the user's explicit tool set fixed).
                            let newTools = await CapabilityLoadBuffer.shared.drain()
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

                        if inv.toolName == "share_artifact" {
                            resultText = await self.processShareArtifactResult(
                                toolResult: resultText,
                                executionMode: executionMode
                            )
                            if let artifact = SharedArtifact.fromEnrichedToolResult(resultText) {
                                await PluginManager.shared.notifyArtifactHandlers(artifact: artifact)
                            }
                        } else if NativeImageToolArtifactBridge.isNativeImageTool(inv.toolName) {
                            // Enrich for the artifact card only; the model keeps
                            // the compact `toolPayload` in `resultText`. The bridge
                            // returns its input unchanged on failure, so a changed
                            // string means success — route it to the card.
                            let enriched = await self.processNativeImageToolResult(
                                toolName: inv.toolName,
                                toolResult: resultText
                            )
                            if enriched != resultText {
                                nativeImageCardOverrides[callId] = enriched
                                if let artifact = SharedArtifact.fromEnrichedToolResult(enriched) {
                                    await PluginManager.shared.notifyArtifactHandlers(artifact: artifact)
                                }
                            }
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
                        do {
                            // Log tool execution start
                            let truncatedArgs = inv.jsonArguments.prefix(200)
                            print(
                                "[Osaurus][Tool] Executing: \(inv.toolName) with args: \(truncatedArgs)\(inv.jsonArguments.count > 200 ? "..." : "")"
                            )

                            if executionMode.usesSandboxTools {
                                await SandboxToolRegistrar.shared.registerTools(for: effectiveAgentId)
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
                            let sessionIdForTools =
                                self.sessionId?.uuidString ?? "chatwindow-\(ObjectIdentifier(self).hashValue)"
                            // `currentAgentId` is already pinned by the
                            // outer turn-level binding; we only need to
                            // layer per-tool-call session/turn/call ids.
                            let resultText = try await ChatExecutionContext.$currentSessionId.withValue(
                                sessionIdForTools
                            ) {
                                try await ChatExecutionContext.$currentAssistantTurnId.withValue(assistantTurn.id) {
                                    try await ChatExecutionContext.$currentToolCallId.withValue(callId) {
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
                            return await postProcessToolResult(inv, callId: callId, resultText: resultText)
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
                            let execution = await executeSingleToolCall(only.invocation, callId: only.callId)
                            // Cancelled before execution produced anything:
                            // report "never ran" rather than an empty
                            // envelope the driver would record.
                            if execution.result.isEmpty, !execution.isError, !self.isRunActive(runId) {
                                return []
                            }
                            return [execution]
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
                                if execution.result.isEmpty, !execution.isError, !self.isRunActive(runId) {
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

                        var executions = [AgentLoopToolExecution?](repeating: nil, count: calls.count)

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
                        var approved: [(slot: Int, invocation: ServiceToolInvocation, callId: String)] = []
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
                                executions[slot] = AgentLoopToolExecution(result: envelope, isError: false)
                                continue
                            }
                            do {
                                try await ToolRegistry.shared.resolvePermissionGate(
                                    name: call.invocation.toolName,
                                    argumentsJSON: call.invocation.jsonArguments
                                )
                                approved.append((slot, call.invocation, call.callId))
                            } catch {
                                let envelope = ToolEnvelope.fromError(error, tool: call.invocation.toolName)
                                executions[slot] = AgentLoopToolExecution(result: envelope, isError: true)
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
                            let sessionIdForTools =
                                self.sessionId?.uuidString ?? "chatwindow-\(ObjectIdentifier(self).hashValue)"
                            let turnIdForTools = assistantTurn.id
                            let results = await AgentToolLoop.runBatchInParallel(
                                approved.map { ($0.invocation, $0.callId) }
                            ) { inv, callId in
                                try await ChatExecutionContext.$currentSessionId.withValue(sessionIdForTools) {
                                    try await ChatExecutionContext.$currentAssistantTurnId.withValue(turnIdForTools) {
                                        try await ChatExecutionContext.$currentToolCallId.withValue(callId) {
                                            try await ToolRegistry.shared.execute(
                                                name: inv.toolName,
                                                argumentsJSON: inv.jsonArguments,
                                                permissionGateResolved: true
                                            )
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
                    let loopHooks = AgentLoopHooks(
                        isCancelled: { !self.isRunActive(runId) },
                        buildMessages: { notices in
                            // Mid-run steering: a text-only message queued
                            // during the run joins the conversation at this
                            // iteration boundary instead of waiting for the
                            // run to finish (or requiring Stop).
                            self.injectQueuedSteerIfEligible()

                            ttftTrace?.mark("build_messages_start")
                            var msgs = buildMessages()
                            ttftTrace?.mark("build_messages_done")

                            // Compact history that outgrew the window: middle
                            // tool results summarize first, oldest middle
                            // messages drop second; first user message + the
                            // recent pairs stay intact, and the system prefix
                            // is untouched. No-op while within budget.
                            let preTrimTokens = ContextBudgetManager.estimateTokens(for: msgs)
                            let trimResult = AgentLoopBudget.trimPreservingSystemPrefixReportingOverflow(
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
                            // the iteration-budget warning. The system prefix
                            // is excluded — its tokens are reserved separately
                            // and the history budget already accounts for them.
                            let historyBudget = loopBudgetManager.historyBudget
                            let historyTokens = ContextBudgetManager.estimateTokens(
                                for: msgs.filter { $0.role != "system" }
                            )
                            if !tokenBudgetNoticeFired,
                                historyBudget > 0,
                                historyTokens >= Int(Double(historyBudget) * 0.9)
                            {
                                tokenBudgetNoticeFired = true
                                // Delegation nudge rides along when a spawn tool
                                // is actually in this run's frozen schema: a
                                // tight window is exactly when offloading bulk
                                // reading to a worker pays for itself.
                                let spawnVisible = toolSpecs.contains {
                                    $0.function.name == SubagentCapabilityRegistry.spawnAgentToolName
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
                            let convTokens =
                                msgs
                                .filter { $0.role != "system" }
                                .reduce(0) { $0 + ContextBudgetManager.estimateTokens(for: $1.content) }
                                - currentInjectedTokens
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
                            ttftTrace?.set("messageCount", msgs.count)
                            ttftTrace?.set("conversationTurns", self.turns.count)

                            #if DEBUG
                                // Dump full prompt to debug log for TTFT analysis
                                if attempt == 1 {
                                    var promptDump = "═══ FULL PROMPT DUMP ═══\n"
                                    for (i, m) in msgs.enumerated() {
                                        promptDump += "── [\(i)] role=\(m.role) chars=\(m.content?.count ?? 0) ──\n"
                                        promptDump += (m.content ?? "(nil)") + "\n"
                                    }
                                    if let tools = toolSpecs.isEmpty ? nil : toolSpecs {
                                        promptDump += "── TOOLS (\(tools.count)) ──\n"
                                        for t in tools {
                                            promptDump += "  - \(t.function.name): \(t.function.description ?? "")\n"
                                        }
                                    }
                                    promptDump += "═══ END PROMPT DUMP ═══"
                                    debugLog(promptDump)
                                }
                            #endif
                            let requestedToolChoice = ChatToolChoicePolicy.resolve(
                                tools: toolSpecs,
                                userText: trimmed,
                                attempt: attempt
                            )
                            var req = ChatCompletionRequest(
                                // Mode 2: the wire omits the model and routing is
                                // by provider id, so don't pass the local
                                // `selectedModel` — it can lag the async agent pin
                                // and would only leak a stale prefix internally.
                                model: self.isRemoteAgentTarget
                                    ? "default" : (self.selectedModel ?? "default"),
                                messages: msgs,
                                temperature: effectiveTemp,
                                max_tokens: effectiveMaxTokensForAgent,
                                stream: true,
                                top_p: chatCfg.topPOverride,
                                frequency_penalty: nil,
                                presence_penalty: nil,
                                stop: nil,
                                n: nil,
                                tools: toolSpecs.isEmpty ? nil : toolSpecs,
                                tool_choice: requestedToolChoice,
                                session_id: self.sessionId?.uuidString
                            )
                            req.samplingParametersAreImplicit = true
                            // Mode 2 routing signal: tells `RemoteProviderService`
                            // to target the peer's `/agents/{address}/run`
                            // endpoint (remote agent runs fully server-side). The
                            // local `model` placeholder above is dropped from the
                            // wire entirely (`RemoteChatRequest.encode`), so the
                            // peer resolves its own live effective model. False =
                            // Mode 1 (plain remote inference via
                            // `/chat/completions`).
                            req.runAsRemoteAgent = self.isRemoteAgentTarget
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
                            req.modelOptions =
                                self.activeModelOptions.isEmpty ? nil : self.activeModelOptions
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
                            // design.
                            req.idempotencyKey = "\(runId.uuidString):\(attempt)"
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
                                    selectedModel: self.selectedModel
                                )
                                assistantTurn = finalTurn

                                // Stream finished naturally without a tool call — reset
                                // the transient-retry budget so a future, unrelated
                                // failure later in the conversation gets a fresh
                                // allowance.
                                if invocations.isEmpty {
                                    transientRetries = 0
                                    // An empty turn (0-token / EOS-first, no tool
                                    // call) must not silently end the run as "No
                                    // visible text was produced": let the driver
                                    // nudge-and-retry, then fall back to a message.
                                    // A reasoning-only turn (visible content blank
                                    // but thinking present) is NOT empty — it's the
                                    // model's intended answer in the reasoning
                                    // channel — so require thinking blank too, matching
                                    // the "No visible text was produced" condition.
                                    return
                                        (assistantTurn.contentIsBlank
                                        && assistantTurn.thinkingIsBlank)
                                        ? .emptyResponse : .finalResponse
                                }
                                return .toolCalls(invocations)
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
                        willProcessCall: { inv, callId in
                            // The RECORDED copy of the args is scrubbed
                            // (sandbox_secret_set `value` → [REDACTED]);
                            // execution still sees the original `inv`.
                            let call = ToolCall(
                                id: callId,
                                type: "function",
                                function: ToolCallFunction(
                                    name: inv.toolName,
                                    arguments: SecretArgumentScrubber.scrubForPersistence(
                                        toolName: inv.toolName,
                                        argumentsJSON: inv.jsonArguments
                                    )
                                ),
                                geminiThoughtSignature: inv.geminiThoughtSignature
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
                            let key = self.expectedTodoSessionId
                            guard let todo = await AgentTodoStore.shared.todo(for: key)
                            else { return 0 }
                            return todo.totalCount - todo.doneCount
                        },
                        emitFallbackText: { text in
                            // Empty-turn recovery exhausted: render a visible
                            // message into the assistant turn so the user never
                            // sees a silent "No visible text was produced".
                            assistantTurn.appendContentAndNotify(text)
                            self.rebuildVisibleBlocks()
                        }
                    )

                    let runResult = try await AgentToolLoop.run(
                        policy: AgentLoopPolicy(
                            maxIterations: maxAttempts,
                            stopOnToolRejection: true,
                            dedupeNoticeEnabled: true,
                            maxDataMovementSteps: min(16, maxAttempts)
                        ),
                        state: taskState,
                        hooks: loopHooks
                    )

                    if runResult.exit == .overBudget {
                        // Even fully-compacted history can't fit the model
                        // window — the driver ended the run before sending a
                        // doomed request. Surface the distinct failure on the
                        // assistant bubble instead of a generic stream error.
                        assistantTurn.content = AgentToolLoop.overBudgetMessage
                        lastStreamError = AgentToolLoop.overBudgetMessage
                        rebuildVisibleBlocks()
                    }

                    if runResult.exit == .iterationCapReached && isRunActive(runId) {
                        do {
                            var finalReq = ChatCompletionRequest(
                                model: selectedModel ?? "default",
                                // Same watermark-trimmed view of history the
                                // loop iterations used — the raw array can
                                // exceed the window precisely when the cap
                                // hits after heavy tool traffic.
                                messages: AgentLoopBudget.trimPreservingSystemPrefix(
                                    buildMessages(),
                                    with: loopBudgetManager,
                                    watermark: compactionWatermark
                                ),
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
                            finalReq.runAsRemoteAgent = isRemoteAgentTarget
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
                            finalReq.modelOptions = activeModelOptions.isEmpty ? nil : activeModelOptions
                            finalReq.turnId = assistantTurn.id
                            // Distinct logical step (the post-cap summarizing
                            // call) so it bills once and dedupes on its own
                            // connect-phase retry without colliding with the
                            // loop's per-iteration keys.
                            finalReq.idempotencyKey = "\(runId.uuidString):final"

                            let processor = StreamingDeltaProcessor(
                                turn: assistantTurn
                            ) { [weak self] in
                                self?.rebuildVisibleBlocks()
                            }

                            let stream = try await engine.streamChat(request: finalReq)
                            for try await delta in stream {
                                if !isRunActive(runId) { break }
                                if !delta.isEmpty { processor.receiveDelta(delta) }
                            }
                            await processor.finalize()
                        } catch {
                            debugLog("send: final wrap-up call failed: \(error.localizedDescription)")
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
            }  // ChatExecutionContext.$currentAgentId.withValue
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

// MARK: - ChatView

struct ChatView: View {
    // MARK: - Window State

    /// Per-window state container (isolates this window from shared singletons)
    @ObservedObject private var windowState: ChatWindowState

    // MARK: - Environment & State

    @Environment(\.colorScheme) private var colorScheme

    @State private var focusTrigger: Int = 0
    @State private var isPinnedToBottom: Bool = true
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
    // What's New modal
    @State private var pendingWhatsNew: WhatsNewRelease? = nil
    @State private var showAutoSpeakPrompt: Bool = false
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
    /// Drives the dim/blur on the message thread + main input bar so
    /// the prompt visibly takes the foreground. Single source of truth
    /// is `session.promptQueue.current`.
    private var isPromptOverlayActive: Bool {
        session.promptQueue.current != nil
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
                L("Keep this chat running?"),
                isPresented: $windowState.showCloseConfirmation,
                message:
                    L(
                        "The model is still generating a reply. Continue in the background and track progress in the menu-bar notch, or stop now."
                    ),
                buttons: [
                    .primary(L("Continue in Background")) { windowState.confirmCloseInBackground() },
                    .destructive(L("Stop and Close")) { windowState.confirmCloseAndStop() },
                    .cancel(L("Cancel")),
                ]
            )
            .themedAlert(
                L("A local model is already running"),
                isPresented: $windowState.showLocalModelBusyAlert,
                message:
                    L(
                        "Only one local model can run at a time, and another chat window is using it right now. Wait for that reply to finish, or switch this chat to a remote model."
                    ),
                buttons: [
                    .cancel(L("OK"))
                ]
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
            .sheet(isPresented: $showTopUpSheet) {
                CreditsTopUpSheet()
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
                    .opacity(theme.isDark ? 0.28 : 0.18)
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

    /// Chat mode content - the original ChatView implementation
    @ViewBuilder
    private var chatModeContent: some View {
        GeometryReader { proxy in
            let sidebarWidth: CGFloat = windowState.showSidebar ? 240 : 0
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
                            onSelect: { data in
                                windowState.loadSession(data)
                                isPinnedToBottom = true
                            },
                            onNewChat: {
                                windowState.startNewChat()
                            },
                            onDelete: { id in
                                if session.sessionId == id {
                                    session.reset()
                                }
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
                            onExport: { metadata, format in
                                ChatSessionExportCoordinator.run(
                                    metadataSession: metadata,
                                    format: format,
                                    scope: .chat(windowState.windowId)
                                )
                            },
                            onOpenInNewWindow: { sessionData in
                                // Open session in a new window via ChatWindowManager
                                ChatWindowManager.shared.createWindow(
                                    agentId: sessionData.agentId,
                                    sessionData: sessionData
                                )
                            }
                        )
                    }
                }
                .frame(width: sidebarWidth, alignment: .top)
                .frame(maxHeight: .infinity, alignment: .top)
                .clipped()
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
                                    .blur(radius: isPromptOverlayActive ? 1.5 : 0)
                                    .allowsHitTesting(!isPromptOverlayActive)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                                    .animation(theme.springAnimation(), value: isPromptOverlayActive)
                            }

                            // Mode 2 connection status (connecting / error +
                            // Retry) shown directly above the composer so the
                            // gated send has a visible explanation.
                            remoteAgentConnectionNotice
                                .frame(maxWidth: 1100)
                                .frame(maxWidth: .infinity)
                                .animation(theme.springAnimation(), value: windowState.remoteAgentConnectionPhase)

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
                                isStreaming: observedSession.isStreaming,
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
                                contextBreakdown: observedSession.estimatedContextBreakdown,
                                sessionSpendMicro: observedSession.sessionRouterSpendMicro,
                                showSessionSpend: observedSession.isOsaurusRouterSession,
                                imageComposerSettings: $observedSession.imageComposerSettings,
                                onSend: { manualText in
                                    if let manualText = manualText {
                                        observedSession.input = manualText
                                    }
                                    if observedSession.isStreaming {
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
                                onCaptureScreenshot: { observedSession.captureScreenshotFromSlashCommand() },
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
                                    != nil
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
                            )
                        }
                    }
                    .animation(theme.springAnimation(responseMultiplier: 0.9), value: session.hasVisibleThreadMessages)
                }
            }
        }
        .frame(
            minWidth: 800,
            idealWidth: 950,
            maxWidth: .infinity,
            minHeight: 575,
            idealHeight: 610,
            maxHeight: .infinity
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .ignoresSafeArea()
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
                        // Both actions land on the Storage panel.
                        // `exportPlaintextBackup` doesn't auto-open
                        // the file picker — the user clicks
                        // "Export plaintext backup…" once they're
                        // there, which is the safer flow because it
                        // forces them to pick a destination.
                        AppDelegate.shared?.showManagementWindow(initialTab: .storage)
                    case .openPrivacySettings:
                        AppDelegate.shared?.showManagementWindow(initialTab: .privacy)
                    case .openComputerUseSettings:
                        AppDelegate.shared?.showManagementWindow(initialTab: .computerUse)
                    case .openCredits:
                        AppDelegate.shared?.showManagementWindow(initialTab: .credits)
                    case .openImageGeneration:
                        AppDelegate.shared?.showManagementWindow(initialTab: .imageGeneration)
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
        ChatEmptyState(
            hasModels: true,
            selectedModel: session.selectedModel,
            agents: windowState.agents,
            activeAgentId: windowState.agentId,
            quickActions: emptyStateQuickActions,
            generativeGreetingState: session.generativeGreetingState,
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
            onOpenOnboarding: nil,
            activeDiscoveredAgent: windowState.selectedDiscoveredAgent,
            activeRelayAgent: windowState.selectedRelayAgent,
            remoteAgentAvatar: windowState.pinnedRemoteAgentAvatar,
            remoteAgentDescription: remoteAgentDescriptionForEmptyState,
            remoteAgentQuickActions: windowState.pinnedRemoteAgentQuickActions,
            isConnecting: windowState.remoteAgentConnectionPhase == .connecting
        )
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
        .modifier(
            GenerativeGreetingTrigger(
                session: session,
                windowState: windowState
            )
        )
    }

    // MARK: - Background

    private var chatBackground: some View {
        ZStack {
            ThemedBackgroundLayer(
                cachedBackgroundImage: windowState.cachedBackgroundImage,
                showSidebar: windowState.showSidebar
            )

            if theme.glassEnabled {
                ThemedGlassSurface(
                    cornerRadius: 24,
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
                        topLeadingRadius: windowState.showSidebar ? 0 : 24,
                        bottomLeadingRadius: windowState.showSidebar ? 0 : 24,
                        bottomTrailingRadius: 24,
                        topTrailingRadius: 24,
                        style: .continuous
                    )
                )
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Header

    private var chatHeader: some View {
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
                editingTurnId: editingTurnId,
                editText: $editText,
                onConfirmEdit: confirmEditAndRegenerate,
                onCancelEdit: cancelEditing,
                onUserImagePreview: openUserAttachmentPreview(attachmentId:),
                onDocumentPreview: { pastedContentPreview = $0 },
                onVisibleTopUserTurnChanged: { turnId in
                    activeMinimapTurnId = turnId
                },
                scrollToTurnId: scrollToTurnId,
                scrollToTurnTrigger: scrollToTurnTrigger,
                sessionRedactions: session.sessionRedactions
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
            .padding(.top, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(session.lastCompletionSummary != nil || session.currentTodo != nil)

            // Minimap overlay — sits at vertical center, right edge
            if minimapMarkers.count >= 2 {
                HStack {
                    Spacer()
                    ChatMinimap(
                        markers: minimapMarkers,
                        activeMarkerId: activeMinimapTurnId,
                        onSelect: { turnId in
                            scrollToTurnId = turnId
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
                onDismiss: { [weak session] in
                    session?.lastCompletionSummary = nil
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
    let editingTurnId: UUID?
    let editText: Binding<String>?
    let onConfirmEdit: (() -> Void)?
    let onCancelEdit: (() -> Void)?
    let onUserImagePreview: ((String) -> Void)?
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
            editingTurnId: editingTurnId,
            editText: editText,
            onConfirmEdit: onConfirmEdit,
            onCancelEdit: onCancelEdit,
            onUserImagePreview: onUserImagePreview,
            onDocumentPreview: onDocumentPreview,
            onVisibleTopUserTurnChanged: onVisibleTopUserTurnChanged,
            scrollToTurnId: scrollToTurnId,
            scrollToTurnTrigger: scrollToTurnTrigger,
            sessionRedactions: sessionRedactions
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
            if case let .userMessage(text, _) = block.kind {
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
