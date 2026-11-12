//
//  FloatingInputCard.swift
//  osaurus
//
//  Premium floating input card with model chip and smooth animations
//

import AVFoundation
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@preconcurrency import MLXLMCommon

private struct ComposerAllowsWorkflowSelectionKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var composerAllowsWorkflowSelection: Bool {
        get { self[ComposerAllowsWorkflowSelectionKey.self] }
        set { self[ComposerAllowsWorkflowSelectionKey.self] = newValue }
    }
}

struct FloatingInputCard: View {
    @Environment(\.composerAllowsWorkflowSelection) private var allowsWorkflowSelection
    @ObservedObject private var alignmentPreparation = AlignmentPreparationState.shared
    @Binding var text: String
    @Binding var selectedModel: String?
    @Binding var pendingAttachments: [Attachment]
    /// When true, voice input auto-restarts after AI responds (continuous conversation mode)
    @Binding var isContinuousVoiceMode: Bool
    @Binding var voiceInputState: VoiceInputState
    @Binding var showVoiceOverlay: Bool
    let pickerItems: [ModelPickerItem]
    @Binding var activeModelOptions: [String: ModelOptionValue]
    var turnOverrides: Binding<ChatTurnOverrides>? = nil
    let isStreaming: Bool
    /// True while the Privacy Filter redaction review sheet is actually
    /// on screen. In this window we hide the Stop button — its target
    /// task is suspended in the review sheet's continuation, and the
    /// sheet has its own Cancel button. This is driven by the live sheet
    /// presentation (not the broader "before first token" window), so
    /// Stop remains available during model load / prefill — e.g. the
    /// multi-second pause a big model spends loading from disk while the
    /// typing-indicator shimmer is up.
    let isPrivacyReviewSheetVisible: Bool
    let supportsImages: Bool
    /// Current estimated context token count for the session
    let estimatedContextTokens: Int
    /// True when the next local send has an enabled tool surface, so an
    /// untouched toggleable model will use the agent direct-reasoning default.
    let appliesAgentReasoningDefault: Bool
    /// Per-category breakdown of context token usage
    var contextBreakdown: ContextBreakdown = .zero
    /// Total micro-USD spent on the Osaurus Router this session.
    var sessionSpendMicro: Int = 0
    /// "N cached · P%" label for this session's router prompt-cache hits
    /// (see `OsaurusRouter.formatCachedInputLabel`); nil hides the line.
    var sessionCachedInputLabel: String? = nil
    /// True when this session's spend is billed via the Osaurus Router (the
    /// managed cloud provider is the selected model). Drives the credits chip's
    /// low/empty escalation and the wallet panel's session-spend row; the chip
    /// itself is shown in every session where the router is usable.
    var isRouterBilledSession: Bool = false
    /// Workspace name when this tab chats with a teammate's shared agent. The
    /// run is billed to that workspace's pool (relayed by the host), so the
    /// composer shows a dedicated "Workspace pool" spend chip that ticks live
    /// instead of attributing the charge to the personal wallet.
    var workspacePoolLabel: String? = nil
    /// Router id of that workspace, so the chip opens *this* workspace's
    /// detail (its pool lives on Overview) rather than the workspace list.
    var workspacePoolId: String?
    @Binding var imageComposerSettings: ImageComposerSettings
    let onSend: (String?) -> Void
    let onStop: () -> Void
    var placeholderIdeas: [String] = []
    var minimumEditorHeight: CGFloat = 52
    var minimumCardHeight: CGFloat = 104
    @State private var placeholderIdeaIndex = 0
    @Environment(\.accessibilityReduceMotion) private var reducePlaceholderMotion
    /// Trigger to focus the input field (increment to focus)
    var focusTrigger: Int = 0
    /// Current agent ID (used for agent-specific settings)
    var agentId: UUID? = nil
    /// Window ID for targeted VAD notifications
    var windowId: UUID? = nil
    /// Compact mode (sidebar open) - hides secondary chip content
    var isCompact: Bool = false
    /// True when the chat has no visible messages yet (welcome/empty state).
    /// Gates the read-only screen-context chip to the pre-first-send screen,
    /// where "currently focused app" is meaningful — the snapshot freezes on
    /// the first send.
    var isEmptyChat: Bool = false
    /// Callback to clear the current chat session (triggered by /clear command).
    var onClearChat: (() -> Void)? = nil
    /// Fired on every keystroke with the composer's current text. Keystrokes
    /// stay in the card-local model (never in `text`) so the chat does not
    /// re-render per key; this lets the session keep a draft mirror for
    /// stash/restore across chat and agent switches (#2708).
    var onDraftChange: ((String) -> Void)? = nil
    /// Called when the card (re)appears so the owner can surface any unsent
    /// draft into `text` before the card rehydrates from it (#2708).
    var onWillRehydrate: (() -> Void)? = nil
    /// Incremented by the owner whenever it re-bases `text` for a different
    /// chat or agent (`ChatSession.composerGeneration`). The card then
    /// resyncs its local copy from `text` even when the string is equal to
    /// what the binding held before, which `.onChange(of: text)` cannot see.
    /// Delivered through the environment because the card's initializer
    /// call site in `ChatView` is already at the type-checker's limit.
    @Environment(\.composerGeneration) private var composerGeneration
    /// Settings ▸ Chat ▸ Check Spelling While Typing, applied live to the
    /// composer's NSTextView.
    @AppStorage(ComposerSpellCheckSetting.defaultsKey)
    private var spellCheckEnabled: Bool = ComposerSpellCheckSetting.defaultValue
    /// Settings ▸ Conversation ▸ Collapse Long Pastes. When off, pastes of
    /// any size go straight into the composer as text.
    @AppStorage(ComposerPasteCollapseSetting.defaultsKey)
    private var collapseLongPastes: Bool = ComposerPasteCollapseSetting.defaultValue
    /// Set after a manual model change in a non-empty conversation. The
    /// warning is advisory: the user may keep the selected model or start a
    /// clean chat whose first prefix is built for it.
    var modelSwitchContinuityWarning: ModelSwitchContinuityWarning?
    var onDismissModelSwitchContinuityWarning: (() -> Void)?
    /// Callback to capture the current screen as a local chat artifact.
    var onCaptureScreenshot: (() -> Void)?
    /// Callback to generate an AI title for the current chat (triggered by /title command).
    var onGenerateTitle: (() -> Void)? = nil
    /// Callback when the user selects a skill slash command. Passes the skill UUID so the
    /// caller can inject that skill's instructions as one-off context for the next send.
    var onSkillSelected: ((UUID) -> Void)? = nil
    /// Binding to the session's pending one-off skill. Non-nil shows a dismissable skill chip.
    @Binding var pendingSkillId: UUID?
    /// Binding to the session's auto-speak preference. When true, a chip is shown
    /// so the user can disable it without waiting to be re-prompted.
    @Binding var autoSpeakAssistant: Bool
    /// Single-slot queued send that was authored while a run was streaming.
    /// Non-nil renders a chip + flips the Send button into "Send Now"
    /// (interrupt) mode. Nil → ordinary Send / Queue behavior.
    @Binding var queuedSend: QueuedSend?
    /// Cancel + immediately dispatch the queued send. Only invoked when
    /// `queuedSend != nil` (the SendNow button is otherwise hidden).
    var onSendNow: (() -> Void)?
    /// Discard the queued send without sending it. Called by the chip's ×.
    var onCancelQueued: (() -> Void)?
    /// Invoked by the wallet panel's "Add Credits" button (opens the top-up sheet).
    var onAddCredits: (() -> Void)?
    /// Mode 2 (remote agent run): the model is pinned to the remote agent's own
    /// model and the user must not change it. Renders the model chip as a
    /// non-interactive label (no chevron / popover) and disables the `/model`
    /// slash command.
    var isModelPinned: Bool = false
    /// Mode 2: explicit text for the pinned model chip. The caller resolves the
    /// remote agent's effective model (or a neutral "agent name / Default"
    /// fallback while it's still loading) so the chip never implies a specific
    /// device model that isn't the agent's. When nil, falls back to the
    /// selected picker item's display name.
    var pinnedModelLabel: String? = nil
    /// Mode 2: true while the selected remote agent's connect + model pin are
    /// still in flight. Gates `canSend` so the first message can't race the
    /// async connect and fail with a misleading "model not found"; the parent
    /// shows a "connecting" notice for the duration.
    var remoteConnectionPending: Bool = false
    /// Why the composer refuses input right now (workspace team agent offline
    /// / unpaired / connecting, or a host-side read-only copy of a teammate's
    /// conversation). Non-nil makes the text view read-only and disables
    /// send, attachments, voice, and slash commands; the card keeps its
    /// shape so the layout doesn't jump. The parent renders the explanation
    /// and any Retry action above the card.
    var composerLock: ComposerLock? = nil
    /// Typing stays open but nothing sends: another of the user's devices is
    /// replying in this chat. The parent explains above the card.
    var sendBlocked: Bool = false
    /// Mode 2 (remote agent run): the conversation targets a discovered remote
    /// agent that executes its own tool loop, system prompt, and generation
    /// config server-side. Hides the composer's local-only affordances —
    /// sandbox, working folder, screen-context, and the thinking / model-option
    /// chips — because none of them are sent to (or honored by) the remote peer.
    var isRemoteAgentRun: Bool = false
    /// Terminal-style input history (Up/Down arrows recall previously sent
    /// messages). Returns the current conversation's sent inputs, newest
    /// first; nil disables the feature.
    var inputHistoryProvider: (() -> [String])?
    /// Identity of the conversation backing the history. Navigation state
    /// resets when it changes so a recalled index can't leak across chats.
    var inputHistoryKey: UUID?
    /// Session-scoped LLM context-compaction state, rendered as inline
    /// progress / result rows inside the Context Budget popover.
    var compactionState: ContextCompactionUIState = .idle
    /// True when the manual "Compact conversation" action is applicable:
    /// there's an uncovered older span a summary could reclaim (no
    /// utilization gate — the button is available whenever it can do work).
    var canCompactConversation: Bool = false
    /// Invoked by the popover's "Compact conversation" button.
    var onCompactConversation: (() -> Void)? = nil
    /// Warm-up state for the selected local model in this session.
    @ObservedObject var warmupController: ChatWarmupController = ChatWarmupController()
    /// THIS chat session's working-folder state. The folder chip, picker,
    /// refresh/clear actions, and "@" file completion all operate on it, so
    /// they affect only the owning chat — never other windows.
    @ObservedObject var folderState: ChatFolderState

    init(
        text: Binding<String>,
        selectedModel: Binding<String?>,
        pendingAttachments: Binding<[Attachment]>,
        isContinuousVoiceMode: Binding<Bool>,
        voiceInputState: Binding<VoiceInputState>,
        showVoiceOverlay: Binding<Bool>,
        pickerItems: [ModelPickerItem],
        activeModelOptions: Binding<[String: ModelOptionValue]>,
        turnOverrides: Binding<ChatTurnOverrides>? = nil,
        isStreaming: Bool,
        isPrivacyReviewSheetVisible: Bool = false,
        supportsImages: Bool,
        estimatedContextTokens: Int,
        appliesAgentReasoningDefault: Bool = false,
        contextBreakdown: ContextBreakdown = .zero,
        sessionSpendMicro: Int = 0,
        sessionCachedInputLabel: String? = nil,
        isRouterBilledSession: Bool = false,
        workspacePoolLabel: String? = nil,
        workspacePoolId: String? = nil,
        imageComposerSettings: Binding<ImageComposerSettings> = .constant(ImageComposerSettings()),
        onSend: @escaping (String?) -> Void,
        onStop: @escaping () -> Void,
        focusTrigger: Int = 0,
        agentId: UUID? = nil,
        windowId: UUID? = nil,
        isCompact: Bool = false,
        isEmptyChat: Bool = false,
        onClearChat: (() -> Void)? = nil,
        onDraftChange: ((String) -> Void)? = nil,
        onWillRehydrate: (() -> Void)? = nil,
        modelSwitchContinuityWarning: ModelSwitchContinuityWarning? = nil,
        onDismissModelSwitchContinuityWarning: (() -> Void)? = nil,
        onCaptureScreenshot: (() -> Void)? = nil,
        onGenerateTitle: (() -> Void)? = nil,
        onSkillSelected: ((UUID) -> Void)? = nil,
        pendingSkillId: Binding<UUID?> = .constant(nil),
        autoSpeakAssistant: Binding<Bool> = .constant(false),
        queuedSend: Binding<QueuedSend?> = .constant(nil),
        onSendNow: (() -> Void)? = nil,
        onCancelQueued: (() -> Void)? = nil,
        onAddCredits: (() -> Void)? = nil,
        isModelPinned: Bool = false,
        pinnedModelLabel: String? = nil,
        remoteConnectionPending: Bool = false,
        composerLock: ComposerLock? = nil,
        sendBlocked: Bool = false,
        isRemoteAgentRun: Bool = false,
        inputHistoryProvider: (() -> [String])? = nil,
        inputHistoryKey: UUID? = nil,
        compactionState: ContextCompactionUIState = .idle,
        canCompactConversation: Bool = false,
        onCompactConversation: (() -> Void)? = nil,
        warmupController: ChatWarmupController = ChatWarmupController(),
        folderState: ChatFolderState? = nil,
        placeholderIdeas: [String] = [],
        minimumEditorHeight: CGFloat = 52,
        minimumCardHeight: CGFloat = 104
    ) {
        self._text = text
        self.placeholderIdeas = placeholderIdeas
        self.minimumEditorHeight = minimumEditorHeight
        self.minimumCardHeight = minimumCardHeight
        self._selectedModel = selectedModel
        self._pendingAttachments = pendingAttachments
        self._isContinuousVoiceMode = isContinuousVoiceMode
        self._voiceInputState = voiceInputState
        self._showVoiceOverlay = showVoiceOverlay
        self.pickerItems = pickerItems
        self._activeModelOptions = activeModelOptions
        self.turnOverrides = turnOverrides
        self.isStreaming = isStreaming
        self.isPrivacyReviewSheetVisible = isPrivacyReviewSheetVisible
        self.supportsImages = supportsImages
        self.estimatedContextTokens = estimatedContextTokens
        self.appliesAgentReasoningDefault = appliesAgentReasoningDefault
        self.contextBreakdown = contextBreakdown
        self.sessionSpendMicro = sessionSpendMicro
        self.sessionCachedInputLabel = sessionCachedInputLabel
        self.isRouterBilledSession = isRouterBilledSession
        self.workspacePoolLabel = workspacePoolLabel
        self.workspacePoolId = workspacePoolId
        self._imageComposerSettings = imageComposerSettings
        self.onSend = onSend
        self.onStop = onStop
        self.focusTrigger = focusTrigger
        self.agentId = agentId
        self.windowId = windowId
        self.isCompact = isCompact
        self.isEmptyChat = isEmptyChat
        self.onClearChat = onClearChat
        self.onDraftChange = onDraftChange
        self.onWillRehydrate = onWillRehydrate
        self.modelSwitchContinuityWarning = modelSwitchContinuityWarning
        self.onDismissModelSwitchContinuityWarning = onDismissModelSwitchContinuityWarning
        self.onCaptureScreenshot = onCaptureScreenshot
        self.onGenerateTitle = onGenerateTitle
        self.onSkillSelected = onSkillSelected
        self._pendingSkillId = pendingSkillId
        self._autoSpeakAssistant = autoSpeakAssistant
        self._queuedSend = queuedSend
        self.onSendNow = onSendNow
        self.onCancelQueued = onCancelQueued
        self.onAddCredits = onAddCredits
        self.isModelPinned = isModelPinned
        self.pinnedModelLabel = pinnedModelLabel
        self.remoteConnectionPending = remoteConnectionPending
        self.composerLock = composerLock
        self.sendBlocked = sendBlocked
        self.isRemoteAgentRun = isRemoteAgentRun
        self.inputHistoryProvider = inputHistoryProvider
        self.inputHistoryKey = inputHistoryKey
        self.compactionState = compactionState
        self.canCompactConversation = canCompactConversation
        self.onCompactConversation = onCompactConversation
        self._warmupController = ObservedObject(wrappedValue: warmupController)
        self._folderState = ObservedObject(wrappedValue: folderState ?? ChatFolderState())
    }

    // Observe managers for reactive updates
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var harnessRuntimeStore = HarnessRuntimeStore.shared
    @State private var showHarnessFolderWarning = false
    @State private var showSandboxPopover = false
    @State private var pendingHarnessFolderChange: (() -> Void)?
    /// The Default agent's runtime and Claude Code options live in a config
    /// file, not published state, so a change there would not redraw the
    /// chip. Bumped on `.agentUpdated`; the harness lookups read it.
    @State private var harnessConfigRevision = 0
    @State private var reasoningCapabilityRevision = 0
    @ObservedObject private var recentFolders = RecentFoldersStore.shared
    // Deliberately NOT `@ObservedObject`: sandbox provisioning publishes
    // per-progress-tick during runtime downloads and the clipboard service
    // publishes on every copy, and an observing card re-ran its whole body
    // each time. Every body-position read of these two lives inside the
    // selector-row block, which `ChipObservationScope` wraps with its own
    // observation — the closure re-reads this live singleton state when the
    // scope re-renders. Everything else here calls them imperatively.
    private let sandboxState = SandboxManager.State.shared
    private var clipboardService = ClipboardService.shared
    #if OSAURUS_DESIGN_INSPECTOR
    private var inspectorContextMenuPart: Int?
    func inspectorContextMenuOnly(_ part: Int, clipboard: ClipboardService.ClipboardContent = .text("Local menu verification text")) -> Self {
        var copy = self
        copy.inspectorContextMenuPart = part
        copy.clipboardService = .inspectorMenuSample(content: clipboard)
        return copy
    }
    #endif
    @ObservedObject private var appConfig = AppConfiguration.shared
    /// Drives the composer credits chip (balance + low-balance tinting) and the
    /// wallet panel's recent-activity list.
    @ObservedObject private var accountService = OsaurusRouterAccountService.shared
    /// Master-switch mirror for the Osaurus Router; the credits chip shows in
    /// every session while the router is usable (switch on + identity present).
    @ObservedObject private var remoteProviders = RemoteProviderManager.shared
    // Frontmost-app + Accessibility observation for the read-only
    // screen-context row lives inside `ScreenContextIndicator`, and the
    // warm-up progress observation lives inside `ModelWarmupHelp` — both
    // scoped to their own view nodes so their publishes can't re-evaluate
    // this card's whole body.

    // MARK: - Slash Command State

    private var slashRegistry = SlashCommandRegistry.shared
    /// Bumped when off-main bundle evidence lands so media gates re-evaluate.
    @State private var mediaEvidenceGeneration = 0
    @State private var slashSelectedIndex: Int = 0
    @State private var slashMenuHeight: CGFloat = 0
    /// Slash query the user dismissed with Escape. Suppresses the popup for
    /// that exact query so the typed text survives; cleared as soon as the
    /// query changes (typing resumes) so the popup can reappear.
    @State private var dismissedSlashQuery: String?

    // MARK: - "@" File Menu State

    /// Highlighted row in the "@" file completion popup.
    @State private var atSelectedIndex: Int = 0
    /// Filesystem entries for the current "@" query. Populated off the main
    /// actor by `atMenuTask` so directory enumeration never blocks the UI.
    @State private var atMenuItems: [AtFileItem] = []
    /// Outcome of the latest listing; `.denied` drives the recovery affordance.
    @State private var atMenuStatus: AtFileMenuStatus = .ok
    /// Resolved directory for the latest listing; used to label + re-grant a
    /// denied folder.
    @State private var atMenuDirectory: String = ""
    /// True while a listing is in flight for a brand-new query (no prior items
    /// to keep showing). Suppresses an empty-state flash before results arrive.
    @State private var atMenuLoading: Bool = false
    /// In-flight listing task; cancelled and replaced on every query change.
    @State private var atMenuTask: Task<Void, Never>?

    // MARK: - Input History State

    /// Terminal-style history navigation position + stashed draft.
    @State private var inputHistoryState = ChatInputHistoryState()

    /// Non-nil when the cursor is inside a slash command token (e.g. "/tr" or "hello /tr").
    /// The slash must be at the start of text or immediately after whitespace.
    /// Nil once a space or newline follows the slash (command completed or dismissed).
    private var activeSlashQuery: String? {
        // Find the last '/' in the text
        guard let slashRange = localText.range(of: "/", options: .backwards) else { return nil }

        // The slash must be at position 0 or preceded by whitespace
        let before = localText[..<slashRange.lowerBound]
        if !before.isEmpty {
            guard let lastChar = before.last, lastChar.isWhitespace else { return nil }
        }

        // Everything after the slash must have no spaces/newlines (still typing the token)
        let afterSlash = String(localText[slashRange.upperBound...])
        guard !afterSlash.contains(" ") && !afterSlash.contains("\n") else { return nil }

        return afterSlash
    }

    private var slashFilteredCommands: [SlashCommand] {
        guard let query = activeSlashQuery else { return [] }
        return slashRegistry.filtered(query: query, agentId: effectiveAgentId)
    }

    private var showSlashPopup: Bool {
        guard let query = activeSlashQuery else { return false }
        return query != dismissedSlashQuery && !slashFilteredCommands.isEmpty
    }

    /// Non-nil when the cursor is inside an "@" file token (e.g. "@src/ma" or
    /// "look at @src/ma"). The "@" must start the text or follow whitespace.
    /// Unlike the slash token, the query may contain "/" (a path); it ends only
    /// at a space or newline. Returns nil once the token is completed/dismissed.
    private var activeAtQuery: String? {
        guard let atRange = localText.range(of: "@", options: .backwards) else { return nil }

        // The "@" must be at the start of the text or preceded by whitespace,
        // so email-style "name@host" tokens don't trigger the menu.
        let before = localText[..<atRange.lowerBound]
        if let lastChar = before.last, !lastChar.isWhitespace { return nil }

        // Everything after "@" is the path query; a space or newline ends it.
        let afterAt = String(localText[atRange.upperBound...])
        guard !afterAt.contains(" ") && !afterAt.contains("\n") else { return nil }

        return afterAt
    }

    /// Show the "@" menu when a query is active and there's something useful to
    /// display: entries, a denied-folder recovery row, or an empty-folder
    /// notice. Hidden for a not-found path (still being typed) and while the
    /// first results for a new query are loading (avoids an empty flash).
    /// Never shown at the same time as the slash popup.
    private var showAtPopup: Bool {
        guard activeAtQuery != nil, !showSlashPopup else { return false }
        if !atMenuItems.isEmpty { return true }
        switch atMenuStatus {
        case .denied: return true
        case .notFound: return false
        case .ok: return !atMenuLoading  // empty folder / no matches, once loaded
        }
    }

    /// Whether the current "@" query is narrowing by a partial name (vs. listing
    /// a whole directory), used to pick the right empty-state wording.
    private var atMenuIsFiltering: Bool {
        guard let query = activeAtQuery else { return false }
        return !query.isEmpty && !query.hasSuffix("/")
    }

    // The typed text lives in a reference-type model so keystrokes never
    // invalidate the card: `@State` tracks only the reference (never
    // replaced), and mutations publish through the model, re-rendering just
    // the regions that observe it (`ComposerTextObservationScope` around the
    // popups + input card, and `ChipObservationScope` for the live token
    // count). Everything else reads the text imperatively via `localText`.
    @State private var composerText = ComposerTextModel()

    /// Compatibility accessor over `composerText` so the many existing
    /// read/write sites keep their exact shape. Writes route through the
    /// model — they never touch card state.
    private var localText: String {
        get { composerText.text }
        nonmutating set { composerText.text = newValue }
    }

    /// Binding for `EditableTextView`, scoped to the model so per-keystroke
    /// writes bypass the card's state storage entirely.
    private var localTextBinding: Binding<String> {
        let model = composerText
        return Binding(get: { model.text }, set: { model.text = $0 })
    }
    @State private var isFocused: Bool = false
    @State private var isComposing: Bool = false
    /// Keeps focus in the input through the send/queue state cascade.
    /// `syncAndSend` and `sendNowButton` arm `lockFocus(for:)` before
    /// the mutations that would otherwise let AppKit blur the field.
    @StateObject private var textViewFocusController = TextViewFocusController()
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var componentEnabled
    private var composerTheme: any ThemeProtocol {
        theme.catalogFamily(21, enabled: componentEnabled && composerLock == nil)
    }
    private var composerRadius: CGFloat { composerTheme.catalogMetric("radius", fallback: theme.radius.bubble) }
    private var composerOpacity: Double {
        1
    }
    private var composerEditable: Bool {
        componentEnabled && composerLock == nil
    }
    @Environment(\.colorScheme) private var colorScheme
    @State private var isDragOver = false
    @State private var showModelPicker = false
    @State private var showWorkflowPicker = false
    @State private var workflowPickerHeight: CGFloat = 144
    @State private var modelPickerCardSize = CGSize(width: 532, height: 280)
    @State private var showCloudModelBrowser = false
    @ObservedObject private var chatModelFavorites = FavoriteModelsStore.shared
    @State private var showImageSizePicker = false
    /// Width available to the toggle-chip region (the space between the model
    /// chip and the meta cluster). Measured cheaply via `onGeometryChange` and
    /// used to decide whether the chips collapse to icon-only — see
    /// `chipsCompact`. Doing a single width read + one cluster build per frame
    /// is what keeps the sidebar collapse/expand animation smooth; the earlier
    /// `ViewThatFits` rebuilt three candidate clusters every frame instead.
    @State private var chipRegionWidth: CGFloat = 0
    /// Full width of the selector row. Drives `metaCompact` so the right-edge
    /// meta cluster (credits CTA + token readout) also sheds its non-essential
    /// bits when the window is tiled narrow — not just when the sidebar is open.
    @State private var selectorRowWidth: CGFloat = 0
    // Cache picker items to prevent popover refresh during streaming
    @State private var cachedPickerItems: [ModelPickerItem] = []
    /// Models the engine reports as carrying a native MTP head. The depth row
    /// appears for these only: a model with no head has nothing to switch, and
    /// showing the control there would advertise speculation it cannot do.
    /// Sourced from the engine's own per-model status, never from the name.
    @State private var nativeMTPCapableModels: Set<String> = []
    /// Resident models whose bundle metadata explicitly blocks manual MTP.
    /// Kept separate from capability: the head still exists, but presenting
    /// selectable depths would lie because the runtime must stay AR-only.
    @State private var nativeMTPManuallyBlockedModels: Set<String> = []
    /// Mirrors `mtp.mode` / `mtp.draftTokenLimit` so the row renders the value
    /// that is actually saved rather than a local guess.
    @State private var nativeMTPSelection: String = "off"
    /// Bundles the shipped default turns on (Qwen3.8 Flash-Next, `measuredFamilyAutoDepth != nil`). Under
    /// `mtp.mode == .familyDefault` the row shows On only for these, i.e. what the engine will run.
    @State private var nativeMTPFamilyDefaultOnModels: Set<String> = []

    // MARK: - MTP Bundle-Layout Advisory State

    /// Non-nil when the selected LOCAL bundle is a Qwen 3.8 Flash-Next JANG
    /// whose on-disk MTP layout predates the final contract. Advisory only —
    /// never alters loading, sending, or runtime behavior.
    @State private var mtpLayoutAdvisory: MTPLayoutAdvisory?
    /// Selection the advisory was last evaluated for ("" = no selection).
    /// The evaluation reads the bundle directory, so it must not ride the 2s
    /// memory tick raw; this memo makes repeat calls a string compare.
    @State private var mtpAdvisoryEvaluatedForModel: String?
    /// Two-step delete guard: the banner's Re-download button first flips to
    /// an in-banner confirmation (deletion is destructive), and only the
    /// confirm click deletes + re-downloads.
    @State private var mtpAdvisoryConfirmingRedownload = false
    // MARK: - Voice Input State
    // Deliberately NOT `@ObservedObject`: `SpeechService.audioLevel` publishes
    // per audio buffer while recording, and an observing card re-ran its whole
    // body at that rate. Reactive reads live in the extracted children
    // (`FloatingVoiceOverlayHost`, `FloatingVoiceButton`,
    // `VoiceStateSyncObservers`), which observe the services themselves;
    // everything here only calls the services imperatively.
    private let speechService = SpeechService.shared
    private let speechModelManager = SpeechModelManager.shared
    @State private var voiceConfig = SpeechConfiguration.default

    // Pause detection state
    @State private var lastSpeechTime: Date = .distantFuture
    @State private var hasDetectedSpeechThisTurn: Bool = false

    @State private var showMicPermissionAlert: Bool = false

    /// Negative-prompt editor (image models). A button raises a themed alert;
    /// the draft buffers edits so Cancel can discard them.
    @State private var showNegativePromptAlert: Bool = false
    @State private var negativePromptDraft: String = ""

    /// Tracks last voice activity time for silence timeout
    @State private var lastVoiceActivityTime: Date = Date()

    /// Displayed silence timeout duration (updated by timer for smooth UI updates)
    @State private var displayedSilenceTimeoutDuration: Double = 0

    /// Tracks confirmed transcription length to detect actual changes (for silence timeout)
    @State private var lastConfirmedLength: Int = 0

    @State private var pauseTimerCancellable: AnyCancellable? = nil
    @State private var liveVoiceAttachmentId: UUID?
    /// Active pasted-content attachment whose preview sheet is showing.
    /// Set on chip tap; cleared on dismiss.
    @State private var pastedContentPreview: Attachment?
    @State private var pastedContentEdit: Attachment?
    @State private var attachmentPickerPresented = false
    /// Pending image attachment shown full-size when its thumbnail is tapped.
    @State private var imagePreview: PendingImagePreview?
    /// Character threshold above which clipboard text is converted to a
    /// pasted-content attachment instead of being inlined into the input.
    // Compared against `.utf8.count`, not `.count`: grapheme-cluster
    // counting a large clipboard payload (e.g. a multi-MB paste) can block
    // the main thread for seconds (Sentry: "App Hanging" in this closure /
    // `CustomNSTextView.paste`), while `.utf8.count` is effectively free —
    // Swift's native String storage is already UTF8. This is only a
    // rough "is this a big paste" gate, so counting bytes instead of
    // characters doesn't change the decision in practice.
    private static let pastedContentThreshold: Int = 400
    @State private var liveVoicePreencodeTask: Task<Void, Never>?
    @State private var lastLiveVoicePreencodeAt: Date = .distantPast
    @State private var lastLiveVoicePreencodeSampleCount: Int = 0

    // TextEditor should grow up to ~6 lines before scrolling
    private let maxVisibleLines: CGFloat = 6
    private var maxHeight: CGFloat {
        // Small extra padding so the last line isn't cramped
        composerTheme.lineHeight(.body) * maxVisibleLines + 8
    }
    private let maxImageSize: Int = 10 * 1024 * 1024  // 10MB limit

    private var canSend: Bool {
        guard componentEnabled else { return false }
        // While the slash command popup is visible, Enter selects a command — not sends
        guard !showSlashPopup else { return false }

        // Remote-agent (Mode 2) connect + model pin still resolving: block the
        // send so the first message can't race the async connect and fail with
        // a misleading "model not found". The parent shows a connecting notice.
        guard !remoteConnectionPending else { return false }

        // Locked composer (offline team agent, read-only teammate chat):
        // nothing sends until the lock clears.
        guard composerLock == nil else { return false }
        guard !sendBlocked else { return false }

        // Context estimates drive the chip's warning, never send admission.
        // Only the runtime's tokenizer/template can establish that a request
        // exceeds a real limit, including when model metadata is available.

        // Configuration gate: the Default agent needs the configure tool
        // schema to do its job, but a too-small context window (e.g.
        // Foundation at 4K) strips those tools entirely. Block the send and
        // let the inline notice explain, instead of silently degrading to a
        // tool-less chat that can't configure anything.
        guard !configContextTooSmall else { return false }

        let hasText = !localText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasContent = hasText || !pendingAttachments.isEmpty
        // During streaming, "send" enqueues the payload (handled by the
        // parent). The bar swaps Send for SendQueue/SendNow visually but
        // the keyboard path still goes through onSend → enqueueSend.
        return hasContent
    }

    private var showPlaceholder: Bool {
        localText.isEmpty && pendingAttachments.isEmpty && !isComposing
    }

    /// Breakdown augmented with real-time typing tokens
    private var displayContextBreakdown: ContextBreakdown {
        var bd = contextBreakdown
        if !localText.isEmpty {
            let typingTokens = TokenEstimator.estimate(localText)
            bd.setTokens(
                for: "input",
                in: \.messages,
                tokens: (bd.messages.first { $0.id == "input" }?.tokens ?? 0) + typingTokens,
                label: "Input",
                tint: .cyan
            )
        }
        return bd
    }

    // MARK: - Context budget gating

    /// One pass over the context-budget chain.
    ///
    /// Everything here derives from the same two costly inputs: the context
    /// window resolution and the typing-augmented breakdown. These used to be
    /// separate computed properties that called each other, and SwiftUI
    /// re-evaluates a computed property on every single access — so one
    /// render of the context chip resolved the context window six times,
    /// rebuilt the breakdown four times (running the token estimator over the
    /// composer text on each rebuild) and ran the assessment three times,
    /// with a per-agent `effectiveMaxTokens` lookup each time. That fan-out
    /// is what put this chain in the hang reports on every keystroke.
    ///
    /// Callers must bind this to a local once and read fields off it; reading
    /// `contextBudget` repeatedly reintroduces the same fan-out one level up.
    private struct ContextBudgetSnapshot {
        var resolution: AgentLoopBudget.ContextWindowResolution?
        /// Breakdown including what is currently being typed.
        var breakdown: ContextBreakdown
        var assessment: AgentLoopBudget.Assessment

        /// Max context length for the selected model — the SAME resolution
        /// the runtime loop uses (`AgentLoopBudget`), so the chip's
        /// denominator and the trim budget never diverge.
        var maxTokens: Int? { resolution?.tokens }

        /// Context tokens including what is currently being typed.
        var displayTokens: Int { breakdown.total }

        /// The denominator the compactor and warning actually use. The
        /// model maximum remains visible in the popover, but showing it as
        /// the chip denominator made an 85%-budget warning look early and
        /// made the Chat metadata fallback look like a competing cap.
        var usableTokens: Int? {
            maxTokens.map { ContextBudgetManager(contextLength: $0).effectiveBudget }
        }

        /// Estimated fraction of the effective budget the next send occupies
        /// (typing included). nil when the window is unknown.
        var usageRatio: Double? { assessment.usageRatio }

        /// Soft warning threshold: at ≥85% of the effective budget the
        /// context chip turns amber. Sends still go through — mid-run
        /// compaction is the overflow handler — but the user should know
        /// quality may degrade.
        var nearLimit: Bool { assessment.nearLimit }

        /// Hard overflow: the non-compactable prefix alone — everything
        /// EXCEPT the conversation history (system prompt, tools, memory,
        /// input) — plus the response reservation exceeds the effective
        /// budget. History can be compacted mid-run; this can't, so the send
        /// is blocked with a clear signal instead of a guaranteed model
        /// failure.
        var hardOverflow: Bool { assessment.hardOverflow }
    }

    /// Resolve the window, build the breakdown and run the shared UI/runtime
    /// budget math (`AgentLoopBudget.assess`) exactly once. Ratio and
    /// thresholds are computed against the EFFECTIVE budget (window × safety
    /// margin) the runtime trims against, the hard gate excludes compactable
    /// history, and the response reservation is included.
    private var contextBudget: ContextBudgetSnapshot {
        let resolution = selectedModel.map {
            AgentLoopBudget.resolveContextWindowResolutionSync(modelId: $0)
        }
        let breakdown = displayContextBreakdown
        // Real per-agent max_tokens (not the 4096 default) so the chip's
        // hard-overflow gate reserves exactly what the runtime loop will.
        let assessment =
            resolution.map {
                AgentLoopBudget.assess(
                    breakdown: breakdown,
                    contextWindow: $0.tokens,
                    maxResponseTokens: agentManager.effectiveMaxTokens(for: effectiveAgentId)
                )
            } ?? .empty
        return ContextBudgetSnapshot(
            resolution: resolution,
            breakdown: breakdown,
            assessment: assessment
        )
    }

    private var isVoiceConfigured: Bool {
        voiceConfig.voiceInputEnabled
            && speechModelManager.downloadedModelsCount > 0
    }

    /// Whether voice input is ready to actually start recording (model loaded into memory).
    private var isVoiceAvailable: Bool {
        isVoiceConfigured && speechService.isModelLoaded
    }

    /// Whether voice is in a recording/active state
    private var isVoiceActive: Bool {
        voiceInputState != .idle
    }

    /// Current silence duration for pause detection visualization
    private var currentSilenceDuration: Double {
        guard voiceInputState == .recording else { return 0 }
        return Date().timeIntervalSince(lastSpeechTime)
    }

    /// Whether the model / sandbox / clipboard / folder selector row has
    /// anything to show. The screen-context indicator now lives on its own
    /// row above this one, so it is no longer part of this gate.
    ///
    /// In a Mode 2 remote-agent run the context-budget chip is hidden, so the
    /// pinned-model chip (`isModelPinned`) is what keeps the row visible.
    private var showSelectorRow: Bool {
        // Hide the whole selector row (pinned model chip + balance) while a
        // remote agent is still connecting — the chat isn't usable yet — then
        // ease it back in on connect with the resolved pinned-model chip.
        guard !remoteConnectionPending, composerLock == nil else { return false }
        return selectedImagePickerItem != nil || visibleToggleChipCount > 0 || workspacePoolLabel != nil
    }

    /// Whether the credits chip (and its wallet panel) is available at all:
    /// the router master switch is on, a signing identity exists, and the
    /// device is online — the balance is spent on cloud services only, so an
    /// offline composer shows no wallet at all. This gate (without the fetched
    /// balance below) also keys the balance-refresh task in `body`, so the
    /// first fetch can run while the chip is still hidden.
    private var creditsChipAvailable: Bool {
        remoteProviders.isOsaurusRouterEnabled
            && !remoteProviders.isOffline
            && OsaurusIdentity.existsCached()
    }

    /// Visibility gate for the credits chip. On top of availability, a balance
    /// must have actually been fetched: with no server-confirmed balance
    /// (offline at fetch time, router outage, auth failure) the chip's $0 /
    /// "Add Credits" states would be lies, so it stays hidden entirely. Shown
    /// in every session (not just router-billed ones) because credits are the
    /// account-level wallet other routed services will draw from too.
    private var showCreditsChip: Bool {
        creditsChipAvailable && accountService.balance != nil
    }

    private var mainContent: some View {
        VStack(spacing: theme.space.s12) {
            if !showVoiceOverlay {
                mtpLayoutAdvisoryRow
                modelSwitchContinuityRow
            }

            // Read-only screen-context indicator sits on its OWN row above the
            // selector row, right-aligned so it stacks directly over the
            // context-token count, rendered as quiet muted text (not a chip)
            // so it reads as passive status rather than a control.
            if !showVoiceOverlay {
                // The scope owns the sandbox/clipboard observation, so
                // provisioning progress ticks and clipboard arrivals re-render
                // only this row (including its visibility gate) — never the
                // whole card body. The closure re-reads the live singleton
                // state on every scope render.
                ChipObservationScope(textModel: composerText) {
                    if screenContextMayShow || showSelectorRow {
                        VStack(alignment: .trailing, spacing: theme.space.s6) {
                            if screenContextMayShow {
                                ScreenContextIndicator()
                            }
                            if showSelectorRow {
                                selectorRow
                            }
                        }
                        .padding(.top, theme.space.s8)
                        // Same inset as the card below, so the row's first
                        // chip lines up with the card's edge.
                        .padding(.horizontal, theme.space.s12)
                        // Ease the row out while connecting and back in once
                        // connected, so the composer height changes smoothly
                        // instead of snapping.
                        .transition(.opacity)
                    }
                }
            }

            if showVoiceOverlay {
                FloatingVoiceOverlayHost(
                    state: $voiceInputState,
                    pauseDuration: voiceConfig.pauseDuration,
                    confirmationDelay: voiceConfig.confirmationDelay,
                    silenceDuration: currentSilenceDuration,
                    silenceTimeoutDuration: voiceConfig.silenceTimeoutSeconds,
                    silenceTimeoutProgress: displayedSilenceTimeoutDuration,
                    isContinuousMode: isContinuousVoiceMode,
                    isStreaming: isStreaming,
                    transcriptionStopMode: voiceConfig.transcriptionStopMode,
                    onCancel: { cancelVoiceInput() },
                    onSend: { message in sendVoiceMessage(message) },
                    onEdit: { transferToTextInput() }
                )
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.98)),
                        removal: .opacity.combined(with: .scale(scale: 0.98))
                    )
                )
            } else {
                // The scope observes the text model, so keystrokes re-render
                // only this subtree (popups, input area, send gating) — never
                // the whole card body.
                ComposerTextObservationScope(model: composerText) {
                    composerContent
                }
                // Locked: every control inert, text read-only (see
                // `EditableTextView.isEditable`), quietly dimmed. The card
                // keeps its full size so the notice above it doesn't shove
                // the transcript around when the lock toggles.
                .disabled(composerLock != nil)
                .opacity(composerOpacity)
            }
        }
        .animation(theme.motion.springAnimation, value: showVoiceOverlay)
        // Smoothly collapse/reveal the selector row (model chip + balance) as
        // the remote-agent connection resolves, so the composer doesn't snap.
        .animation(theme.motion.springAnimation, value: remoteConnectionPending)
        .animation(theme.motion.springAnimation, value: composerLock == nil)
    }

    private var inputCardWithAnchoredMenus: some View {
        inputCard
        .anchoredCard(isPresented: $showWorkflowPicker, size: CGSize(width: 640, height: workflowPickerHeight),
                      alignment: .leading, constrainToWindow: true, takesFocus: true,
                      shadowPadding: 18, gap: 4,
                      accessibilityLabel: L("Workflows")) {
            WorkflowCommandPicker(
                onSelect: { workflowID in
                    showWorkflowPicker = false
                    WorkflowRunLauncher.openTab(workflowID: workflowID, agentId: effectiveAgentId)
                },
                onOpenWorkflows: {
                    showWorkflowPicker = false
                    ChatWindowManager.shared.showWorkflowsSurface()
                })
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if abs(workflowPickerHeight - height) > 0.5 { workflowPickerHeight = max(1, height) }
                }
        }
        .anchoredCard(isPresented: Binding(get: { showSlashPopup }, set: { presented in
            if !presented { dismissedSlashQuery = activeSlashQuery; syncPopupVisibility() }
        }), size: CGSize(width: 0, height: slashMenuHeight),
            alignment: .leading, constrainToWindow: true, takesFocus: false,
            shadowPadding: 18, gap: 4, accessibilityLabel: L("Commands")) {
            SlashCommandPopup(commands: slashFilteredCommands,
                selectedIndex: $slashSelectedIndex, onSelect: applySlashCommand,
                fitsPresentedHeight: slashMenuHeight > 0,
                onIdealHeightChange: { height in
                    if abs(slashMenuHeight - height) > 0.5 { slashMenuHeight = max(1, height) }
                })
        }
    }

    private var composerContent: some View {
        inputCardWithAnchoredMenus
        // File completion stays in its existing inline overlay. Slash commands
        // use the window-aware presenter above, keeping the input layout fixed.
        .overlay(alignment: .top) {
            composerPopupOverlay
                .alignmentGuide(.top) { dimensions in dimensions.height + 4 }
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.bottom, theme.space.s12)
        .onDrop(of: dropAcceptedTypes, isTargeted: $isDragOver) { providers in
            handleFileDrop(providers)
        }
        .transition(
            .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.98)),
                removal: .opacity.combined(with: .scale(scale: 0.98))
            )
        )
        .onChange(of: composerText.text) { _, newValue in
            onDraftChange?(newValue)
            // Reset popup selection whenever the typed query changes.
            // Attached here (inside the text observation scope) so the
            // change is detected on scope re-renders — the card itself
            // no longer re-renders per keystroke.
            slashSelectedIndex = 0
            atSelectedIndex = 0
            // Typing after an Escape-dismissal re-arms the slash popup
            if dismissedSlashQuery != nil, activeSlashQuery != dismissedSlashQuery {
                dismissedSlashQuery = nil
            }
            // Re-list the "@" menu off the main actor for the new query.
            // (folds in the registry sync so it costs no extra body chain
            // link — the whole chain is at the type-checker's limit.)
            refreshAtMenu()
        }
    }

    @ViewBuilder var body: some View {
        #if OSAURUS_DESIGN_INSPECTOR
        if let part = inspectorContextMenuPart {
            if part == 7 {
                VStack(alignment: .leading) {
                    clipboardToggleChip(compact: false)
                    ComposerTextObservationScope(model: composerText) {
                        Text("Local chip draft: " + (composerText.text.isEmpty ? "empty" : composerText.text))
                    }
                }
            }
            else { folderContextChip(compact: false) }
        } else { normalBody }
        #else
        normalBody
        #endif
    }
    @ViewBuilder private var normalBody: some View {
        let _ = ChatPerfTrace.shared.count("body.FloatingInputCard")
        mainContent
            // Refresh the router balance whenever the wallet becomes available
            // (router on + identity + online). Keyed on availability rather
            // than chip visibility because the chip stays hidden until a
            // balance has been fetched — this task is what performs that
            // first fetch, and it re-fires on the connectivity-recovery edge.
            // Passive chrome: a balance fetched in the last five minutes is
            // kept (the billed-summary frames keep it current between
            // fetches), and every composer mounting at once shares one
            // request.
            .task(id: creditsChipAvailable) {
                if creditsChipAvailable {
                    await accountService.refreshBalance(ifOlderThan: 300)
                }
            }
            // Float the configuration-context error ABOVE the card as an
            // overlay so it never reflows the input/selector layout when it
            // appears or clears. Anchored to the card's top edge and shifted
            // fully above it via the `.top` alignment guide.
            .overlay(alignment: .top) {
                configContextErrorOverlay
            }
            .overlay(alignment: .top) {
                // Cache-only lookup: this is a view body, and the blocking
                // `findInstalledModel(named:)` parks on the cold-cache disk
                // scan for up to ~10s, beachballing the app on launch. A miss
                // just hides the preparation overlay until the scan lands and
                // the next render picks it up.
                if let progress = alignmentPreparation.progress(
                    modelID: selectedModel.flatMap {
                        ModelManager.findInstalledModelFromCache(named: $0)?.id
                    },
                    sessionID: inputHistoryKey
                ) {
                    VStack(alignment: .leading, spacing: theme.space.s8) {
                        Text(L("Preparing this model for efficient loading. This may take a while."))
                            .textStyle(.caption, weight: 600)
                        Text(L("Normally needed once unless model files change."))
                            .textStyle(.micro)
                        Text(verbatim: progress.shard.lastPathComponent).textStyle(.micro)
                        if progress.stage == .verifying {
                            Text(L("Verifying model data before replacement…")).textStyle(.micro)
                        } else {
                            SettingsProgressBar(
                                value: Double(progress.copiedBytes) / Double(max(1, progress.totalBytes))
                            )
                        }
                    }
                    .padding(theme.space.s14)
                    .frame(maxWidth: 340)
                    .background(theme.surface.overlay, in: RoundedRectangle(cornerRadius: theme.radius.large))
                    .overlay(RoundedRectangle(cornerRadius: theme.radius.large).strokeBorder(theme.border.default, lineWidth: theme.stroke.default))
                    .accessibilityIdentifier("alignment-preparation-progress")
                    .alignmentGuide(.top) { $0[.bottom] + 8 }
                }
            }
            .animation(theme.motion.quick, value: configContextTooSmall)
            .modifier(
                MTPLayoutAdvisoryRearmModifier(
                    rearm: rearmMTPLayoutAdvisory
                )
            )
            .onChange(of: selectedModel) { _, _ in
                refreshMTPLayoutAdvisory()
            }
            .onAppear {
                // Execution choices are mutually exclusive in both behavior
                // and presentation. Clear a restored folder if this agent
                // already has Sandbox enabled when the chat appears.
                if isSandboxEnabled, !folderState.isAdoptingHostFolder {
                    folderState.clearFolder()
                }
                refreshMTPLayoutAdvisory()
                let isReappear = !localText.isEmpty || voiceInputState != .idle
                if text.isEmpty { onWillRehydrate?() }
                localText = text
                print("[VoiceDebug] FloatingInputCard onAppear (reappear=\(isReappear))")

                // Focus immediately when view appears
                isFocused = true

                // Load voice config (cached after first load). The speech
                // model itself loads on the first mic tap, not here.
                loadVoiceConfig()

                if speechService.isRecording {
                    if voiceInputState == .idle {
                        voiceInputState = .recording
                        lastVoiceActivityTime = Date()
                        resetPauseDetectionForRecording()
                    }
                    if !showVoiceOverlay {
                        showVoiceOverlay = true
                    }
                }
            }
            .onChange(of: isSandboxEnabled) { _, enabled in
                // The setting is agent-scoped, so this also clears folders in
                // other visible chats when Sandbox is enabled elsewhere. It
                // also flips on an agent switch, while a project or agent
                // default folder is still on its way to turning it off.
                if enabled, !folderState.isAdoptingHostFolder {
                    folderState.clearFolder()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .startVoiceInputInChat)) { notification in
                // Start voice input when triggered by VAD - enable continuous mode
                // Only respond if this notification targets our window
                guard let targetWindowId = notification.object as? UUID,
                    targetWindowId == windowId
                else {
                    return
                }

                if isVoiceAvailable && !showVoiceOverlay && !isStreaming {
                    print(
                        "[FloatingInputCard] Received .startVoiceInputInChat notification for window \(windowId?.uuidString ?? "nil")"
                    )
                    isContinuousVoiceMode = true
                    lastVoiceActivityTime = Date()
                    startVoiceInput()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: LocalVisionEvidence.evidenceReady)) { _ in
                mediaEvidenceGeneration &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: .agentUpdated)) { _ in
                harnessConfigRevision &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: .voiceConfigurationChanged)) { _ in
                // Reload voice config when settings change
                loadVoiceConfig()
            }
            .onChange(of: isStreaming) { wasStreaming, nowStreaming in
                // Safety net: if focus was lost during streaming (e.g.
                // the user clicked elsewhere or dismissed a dialog),
                // re-claim it once the agent finishes so the user can
                // type immediately. The normal send path keeps focus
                // throughout via `TextViewFocusController.lockFocus`.
                if wasStreaming && !nowStreaming {
                    isFocused = true
                }

                // When AI finishes responding and we're in continuous voice mode, restart voice input
                if wasStreaming && !nowStreaming && isContinuousVoiceMode {
                    print("[FloatingInputCard] AI response finished in continuous mode - restarting voice")
                    // Reset silence timeout for the new turn
                    lastVoiceActivityTime = Date()

                    // Small delay to let UI settle
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms
                        if isContinuousVoiceMode && isVoiceAvailable && !showVoiceOverlay {
                            startVoiceInput()
                        }
                    }
                }
            }
            .onDisappear {
                // Stop any active voice recording, but check if we should keep continuous mode
                if isVoiceActive {
                    print("[FloatingInputCard] onDisappear: Stopping active voice recording")
                    // Don't use cancelVoiceInput() here as it forces continuous mode off.
                    // Instead, just stop recording but preserve the mode.
                    cancelLiveVoicePreencodeSession(removeRegistryEntry: true)
                    Task {
                        _ = await speechService.stopStreamingTranscription()
                        speechService.clearTranscription()
                    }
                    voiceInputState = .idle
                    showVoiceOverlay = false
                }
            }
            .onChange(of: text) { _, newValue in
                // Sync from binding when it changes externally (e.g., quick actions)
                if newValue != localText {
                    localText = newValue
                }
            }
            .onChange(of: composerGeneration) { _, _ in
                // The owner switched chat/agent in place: `text` is now the
                // incoming draft (possibly the same string as before), so the
                // previous agent's keystrokes must not linger in the card.
                if text != localText {
                    localText = text
                }
            }
            .onChange(of: showSlashPopup) { _, _ in
                if showSlashPopup { slashMenuHeight = 0 }
                // Keep registry in sync so the global key monitor can suppress
                // Escape from closing the window while either popup is open.
                syncPopupVisibility()
            }
            .onDisappear {
                atMenuTask?.cancel()
                SlashCommandRegistry.shared.isPopupVisible = false
            }
            .onChange(of: focusTrigger) { _, _ in
                isFocused = true
            }
            .modifier(
                VoiceStateSyncObservers(
                    voiceInputState: $voiceInputState,
                    showVoiceOverlay: $showVoiceOverlay,
                    lastVoiceActivityTime: $lastVoiceActivityTime,
                    lastSpeechTime: $lastSpeechTime,
                    hasDetectedSpeechThisTurn: $hasDetectedSpeechThisTurn,
                    resetPauseDetectionForRecording: resetPauseDetectionForRecording
                )
            )
            .onChange(of: voiceInputState) { _, newState in
                if newState == .recording {
                    resetPauseDetectionForRecording()
                }
            }
            .onChange(of: showVoiceOverlay) { _, isShowing in
                if isShowing {
                    pauseTimerCancellable = Timer.publish(every: 0.1, on: .main, in: .common)
                        .autoconnect()
                        .sink { [self] _ in
                            checkForPause()
                            checkForSilenceTimeout()
                            handlePauseCountdown()
                            scheduleLiveVoicePreencodeIfNeeded()
                        }
                } else {
                    pauseTimerCancellable = nil
                }
            }
            .modifier(VoiceDebugObservers())
            .themedAlert(
                "Microphone access is off",
                isPresented: $showMicPermissionAlert,
                message:
                    "Osaurus needs microphone access to transcribe speech. Enable it in System Settings → Privacy & Security → Microphone, then try again.",
                primaryButton: .primary("Open System Settings") {
                    if let url = URL(
                        string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                    ) {
                        // Completion-handler form: the plain `open(_:)` blocks
                        // the main thread on the LaunchServices round-trip.
                        NSWorkspace.shared.open(
                            url,
                            configuration: NSWorkspace.OpenConfiguration(),
                            completionHandler: nil
                        )
                    }
                },
                secondaryButton: .cancel("Cancel")
            )
            .themedAlert(
                L("Change the working folder?"),
                isPresented: $showHarnessFolderWarning,
                message: String(
                    format: L(
                        "%@ restarts in the new folder without its earlier context, because this runtime's arguments don't resume sessions (add --session-id {chat_id}). The Osaurus transcript is kept."
                    ),
                    harnessRuntime?.displayName ?? L("The harness")
                ),
                buttons: [
                    .cancel(L("Cancel")) { pendingHarnessFolderChange = nil },
                    .primary(L("Change Folder")) {
                        let change = pendingHarnessFolderChange
                        pendingHarnessFolderChange = nil
                        change?()
                    },
                ]
            )
            .themedAlert(
                "Negative prompt",
                isPresented: $showNegativePromptAlert,
                message: "Describe what to keep out of the image.",
                accessory: negativePromptAccessory,
                buttons: [
                    .cancel(L("Cancel")),
                    .primary(L("Save")) {
                        imageComposerSettings.negativePrompt = negativePromptDraft
                    },
                ]
            )
            .task {
                // log full voice state once the view has settled (deferred to avoid type-checker load in body)
                // 100ms
                try? await Task.sleep(nanoseconds: 100_000_000)
                logVoiceState(trigger: "onAppear")
            }
    }

    // MARK: - Voice Input Methods

    private func loadVoiceConfig() {
        voiceConfig = SpeechConfigurationStore.load()
    }

    private func logVoiceState(trigger: String) {
        let enabled = voiceConfig.voiceInputEnabled
        let permission = speechService.microphonePermissionGranted
        let downloaded = speechModelManager.downloadedModelsCount
        let loading = speechService.isLoadingModel
        let loaded = speechService.isModelLoaded
        let configured = isVoiceConfigured
        let available = isVoiceAvailable
        print(
            """
            [VoiceDebug] [\(trigger)] \
            enabled=\(enabled) | \
            micPermission=\(permission) | \
            downloadedCount=\(downloaded) | \
            isLoading=\(loading) | \
            isLoaded=\(loaded) | \
            → isVoiceConfigured=\(configured) | \
            → isVoiceAvailable=\(available)
            """
        )
    }

}

// MARK: - Voice Debug Helpers

/// Standalone log helper so VoiceDebugObservers can call it without a card reference.
fileprivate func voiceDebugLog(
    trigger: String,
    enabled: Bool,
    micPermission: Bool,
    downloadedCount: Int,
    isLoading: Bool,
    isLoaded: Bool
) {
    let configured = enabled && micPermission && downloadedCount > 0
    let available = configured && isLoaded
    print(
        """
        [VoiceDebug] [\(trigger)] \
        enabled=\(enabled) | \
        micPermission=\(micPermission) | \
        downloadedCount=\(downloadedCount) | \
        isLoading=\(isLoading) | \
        isLoaded=\(isLoaded) | \
        → isVoiceConfigured=\(configured) | \
        → isVoiceAvailable=\(available)
        """
    )
}

// MARK: - Voice Debug Observers

/// Shared informational-banner silhouette: a rounded rectangle
/// whose bottom edge flows into a downward pointer triangle as one continuous
/// path, so stroking it draws a single unbroken border around banner and
/// pointer alike (no border line across the triangle's flat top).
private struct RAMBannerShape: Shape {
    static let pointerWidth: CGFloat = 18
    static let pointerHeight: CGFloat = 8
    static let cornerRadius: CGFloat = 14

    /// X position of the pointer's tip, in the shape's own coordinates.
    let pointerCenterX: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = Self.cornerRadius
        let halfPointer = Self.pointerWidth / 2
        let bodyBottom = rect.maxY - Self.pointerHeight

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
            radius: r,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: bodyBottom - r))
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: bodyBottom - r),
            radius: r,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: pointerCenterX + halfPointer, y: bodyBottom))
        path.addLine(to: CGPoint(x: pointerCenterX, y: rect.maxY))
        path.addLine(to: CGPoint(x: pointerCenterX - halfPointer, y: bodyBottom))
        path.addLine(to: CGPoint(x: rect.minX + r, y: bodyBottom))
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: bodyBottom - r),
            radius: r,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.minY + r),
            radius: r,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

/// Re-arms the MTP bundle-layout advisory when the local model set changes:
/// a delete and a completed download both post `.localModelsChanged`, so a
/// freshly re-downloaded bundle re-evaluates (and clears the notice) on its
/// own. Delivered on the main run loop — the notification is posted from
/// whatever context finished the filesystem work.
private struct MTPLayoutAdvisoryRearmModifier: ViewModifier {
    let rearm: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(
                NotificationCenter.default.publisher(for: .localModelsChanged)
                    .receive(on: RunLoop.main)
            ) { _ in
                rearm()
            }
    }
}

/// Watches the four properties that feed into isVoiceConfigured / isVoiceAvailable
/// and emits a debug log line whenever any of them change.
private struct VoiceDebugObservers: ViewModifier {
    @ObservedObject private var speechService = SpeechService.shared
    @ObservedObject private var speechModelManager = SpeechModelManager.shared

    func body(content: Content) -> some View {
        content
            .onChange(of: speechService.microphonePermissionGranted) { _, granted in
                print("[VoiceDebug] microphonePermissionGranted → \(granted)")
                voiceDebugLog(
                    trigger: "micPermission",
                    enabled: SpeechConfigurationStore.load().voiceInputEnabled,
                    micPermission: granted,
                    downloadedCount: speechModelManager.downloadedModelsCount,
                    isLoading: speechService.isLoadingModel,
                    isLoaded: speechService.isModelLoaded
                )
            }
            .onChange(of: speechService.isModelLoaded) { _, loaded in
                print("[VoiceDebug] isModelLoaded → \(loaded)")
                voiceDebugLog(
                    trigger: "isModelLoaded",
                    enabled: SpeechConfigurationStore.load().voiceInputEnabled,
                    micPermission: speechService.microphonePermissionGranted,
                    downloadedCount: speechModelManager.downloadedModelsCount,
                    isLoading: speechService.isLoadingModel,
                    isLoaded: loaded
                )
            }
            .onChange(of: speechService.isLoadingModel) { _, loading in
                print("[VoiceDebug] isLoadingModel → \(loading)")
            }
            .onChange(of: speechModelManager.downloadedModelsCount) { _, count in
                print("[VoiceDebug] downloadedModelsCount → \(count)")
                voiceDebugLog(
                    trigger: "downloadedModelsCount",
                    enabled: SpeechConfigurationStore.load().voiceInputEnabled,
                    micPermission: speechService.microphonePermissionGranted,
                    downloadedCount: count,
                    isLoading: speechService.isLoadingModel,
                    isLoaded: speechService.isModelLoaded
                )
            }
    }
}

extension FloatingInputCard {

    fileprivate func startVoiceInput() {
        // Branch on TCC up front:
        //   .denied / .restricted → themed "enable in Settings" alert
        //   .notDetermined        → trigger the system permission prompt
        //                           and prime the model load on grant
        //   .authorized           → fall through to the existing flow
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            showMicPermissionAlert = true
            return
        case .notDetermined:
            Task { @MainActor in
                let granted = await speechService.requestMicrophonePermission()
                if granted, let model = SpeechModelManager.shared.selectedModel,
                    !speechService.isModelLoaded, !speechService.isLoadingModel
                {
                    Task { try? await speechService.loadModel(model.id) }
                }
            }
            return
        case .authorized:
            break
        @unknown default:
            return
        }

        guard isVoiceAvailable else {
            // The model loads on first use: load it, then start recording
            // from this same tap. The mic button shows its loading state
            // meanwhile; a failed load lands in `speechService.lastError`.
            guard isVoiceConfigured, let model = SpeechModelManager.shared.selectedModel,
                !speechService.isLoadingModel
            else { return }
            Task { @MainActor in
                do {
                    try await speechService.loadModel(model.id)
                } catch {
                    return
                }
                if isVoiceAvailable { startVoiceInput() }
            }
            return
        }

        // If continuous mode is active, we should be aggressive about ensuring the UI is shown.
        // If recording is already active (e.g. VAD or zombie state), just attach to it.
        if speechService.isRecording {
            print("[FloatingInputCard] startVoiceInput: Recording already active, ensuring UI is visible")
            showVoiceOverlay = true
            if liveVoiceAttachmentId == nil {
                beginLiveVoicePreencodeSession()
            }
            if voiceInputState == .idle {
                voiceInputState = .recording
                lastVoiceActivityTime = Date()
                resetPauseDetectionForRecording()
            }
            return
        }

        // Don't start if already recording (handled above) or starting
        guard voiceInputState == .idle else { return }

        // Show overlay immediately for visual feedback, but don't set recording state yet.
        // Recording state will be set when speechService.isRecording becomes true.
        showVoiceOverlay = true
        beginLiveVoicePreencodeSession()

        Task {
            do {
                try await speechService.startStreamingTranscription()

                // Wait for isRecording to become true (with timeout)
                let startTime = Date()
                let maxWait: TimeInterval = 3.0  // Max 3 seconds to start

                while !speechService.isRecording {
                    if Date().timeIntervalSince(startTime) > maxWait {
                        print("[FloatingInputCard] Timeout waiting for recording to start")
                        throw SpeechError.transcriptionFailed("Recording failed to start")
                    }
                    try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
                }

                // Recording confirmed - now set the recording state
                // lastVoiceActivityTime is reset in onChange(of: isRecording)

            } catch {
                print("[FloatingInputCard] Failed to start voice input: \(error)")
                await MainActor.run {
                    voiceInputState = .idle
                    showVoiceOverlay = false
                    if case SpeechError.microphonePermissionDenied = error {
                        showMicPermissionAlert = true
                    } else {
                        speechService.lastError = error.localizedDescription
                    }
                }
            }
        }
    }

    private func beginLiveVoicePreencodeSession() {
        if let oldId = liveVoiceAttachmentId {
            LiveVoiceAudioInputRegistry.shared.remove(for: oldId)
        }
        liveVoicePreencodeTask?.cancel()
        liveVoicePreencodeTask = nil
        liveVoiceAttachmentId = UUID()
        lastLiveVoicePreencodeAt = .distantPast
        lastLiveVoicePreencodeSampleCount = 0
    }

    private func cancelLiveVoicePreencodeSession(removeRegistryEntry: Bool) {
        liveVoicePreencodeTask?.cancel()
        liveVoicePreencodeTask = nil
        if removeRegistryEntry, let id = liveVoiceAttachmentId {
            LiveVoiceAudioInputRegistry.shared.remove(for: id)
        }
        liveVoiceAttachmentId = nil
        lastLiveVoicePreencodeAt = .distantPast
        lastLiveVoicePreencodeSampleCount = 0
    }

    @discardableResult
    private func scheduleLiveVoicePreencodeIfNeeded(
        force: Bool = false,
        snapshot providedSnapshot: LiveVoiceAudioSnapshot? = nil,
        attachmentId providedAttachmentId: UUID? = nil
    ) -> Task<Void, Never>? {
        guard mediaCapabilities.supportsAudio,
            let modelName = selectedModel,
            ModelFamilyNames.isNemotronOmniFamily(modelName)
        else {
            return nil
        }

        guard let snapshot = providedSnapshot ?? speechService.currentLiveAudioSnapshot(),
            !snapshot.samples.isEmpty
        else {
            return nil
        }

        let attachmentId: UUID
        if let providedAttachmentId {
            attachmentId = providedAttachmentId
        } else if let existing = liveVoiceAttachmentId {
            attachmentId = existing
        } else {
            let newId = UUID()
            liveVoiceAttachmentId = newId
            attachmentId = newId
        }

        let sampleCount = snapshot.samples.count
        let minSampleDelta = max(4_000, snapshot.sampleRate / 2)
        if !force {
            guard sampleCount >= minSampleDelta else { return nil }
            guard Date().timeIntervalSince(lastLiveVoicePreencodeAt) >= 0.75 else { return nil }
            guard sampleCount - lastLiveVoicePreencodeSampleCount >= minSampleDelta else { return nil }
        }

        lastLiveVoicePreencodeAt = Date()
        lastLiveVoicePreencodeSampleCount = sampleCount

        let samples = snapshot.samples
        let sampleRate = snapshot.sampleRate
        let task = Task.detached(priority: .utility) {
            let result = await ModelRuntime.shared.preencodeLiveVoiceAudioIfResident(
                modelName: modelName,
                attachmentId: attachmentId,
                samples: samples,
                sampleRate: sampleRate
            )
            print(
                "[Osaurus][LiveVoice] preencode_status=\(result.status.rawValue) samples=\(result.sampleCount) sample_rate=\(result.sampleRate) encode_ms=\(result.encodeMs) message=\(result.message ?? "")"
            )
        }
        liveVoicePreencodeTask = task
        return task
    }

    private func cancelVoiceInput() {
        print("[FloatingInputCard] User cancelled voice input - disabling continuous mode")
        hasDetectedSpeechThisTurn = false
        lastConfirmedLength = 0
        isContinuousVoiceMode = false
        cancelLiveVoicePreencodeSession(removeRegistryEntry: true)
        Task {
            _ = await speechService.stopStreamingTranscription()
            speechService.clearTranscription()
        }
        voiceInputState = .idle
        showVoiceOverlay = false
    }

    // MARK: - Pause Detection

    /// Resets pause detection state for a new recording turn.
    /// Handles the case where `isSpeechDetected` is already true (e.g. VAD-triggered start).
    private func resetPauseDetectionForRecording() {
        hasDetectedSpeechThisTurn = false
        lastSpeechTime = .distantFuture
        lastConfirmedLength = 0

        if speechService.isSpeechDetected {
            hasDetectedSpeechThisTurn = true
            lastSpeechTime = Date()
        }
    }

    private func checkForPause() {
        guard voiceInputState == .recording,
            voiceConfig.transcriptionStopMode == .automatic,
            voiceConfig.pauseDuration > 0
        else { return }

        let hasContent =
            TranscriptionTextNormalizer.hasVisibleText(speechService.currentTranscription)
            || TranscriptionTextNormalizer.hasVisibleText(speechService.confirmedTranscription)
        let silenceDuration = Date().timeIntervalSince(lastSpeechTime)

        guard hasContent else {
            if silenceDuration >= voiceConfig.pauseDuration && hasDetectedSpeechThisTurn {
                print(
                    "[FloatingInputCard] Pause threshold reached but no content (silence: \(String(format: "%.1f", silenceDuration))s, current: '\(speechService.currentTranscription)', confirmed: '\(speechService.confirmedTranscription)')"
                )
            }
            return
        }

        if silenceDuration >= voiceConfig.pauseDuration {
            voiceInputState = .paused(remaining: voiceConfig.confirmationDelay)
            print(
                "[FloatingInputCard] Pause detected after \(String(format: "%.1f", silenceDuration))s silence, triggering countdown"
            )
        }
    }

    private func checkForSilenceTimeout() {
        // Only check when overlay is showing and it's user's turn (not streaming)
        guard showVoiceOverlay,
            !isStreaming,
            voiceConfig.silenceTimeoutSeconds > 0,
            voiceInputState == .recording,
            speechService.isRecording
        else {
            // Reset display when conditions aren't met
            if displayedSilenceTimeoutDuration != 0 {
                displayedSilenceTimeoutDuration = 0
            }
            return
        }

        // Reset timer when there's real-time voice activity (not cumulative text)
        let confirmedText = TranscriptionTextNormalizer.visibleText(speechService.confirmedTranscription)
        let currentText = TranscriptionTextNormalizer.visibleText(speechService.currentTranscription)
        let currentConfirmedLen = confirmedText.count
        let hasNewConfirmedText = currentConfirmedLen > lastConfirmedLength
        if hasNewConfirmedText {
            lastConfirmedLength = currentConfirmedLen
        }

        if speechService.isSpeechDetected || hasNewConfirmedText || !currentText.isEmpty {
            lastVoiceActivityTime = Date()
        }

        // Calculate and update displayed silence duration
        let silenceDuration = Date().timeIntervalSince(lastVoiceActivityTime)
        displayedSilenceTimeoutDuration = silenceDuration

        // Check if timeout exceeded
        if silenceDuration >= voiceConfig.silenceTimeoutSeconds {
            let hasContent =
                !currentText.isEmpty
                || !confirmedText.isEmpty

            if hasContent && voiceConfig.transcriptionStopMode == .automatic {
                print("[FloatingInputCard] Silence timeout with content - triggering auto-send")
                voiceInputState = .paused(remaining: voiceConfig.confirmationDelay)
            } else if !hasContent {
                print("[FloatingInputCard] Silence timeout without content - closing voice input")
                stopVoiceInputFromTimeout()
                ToastManager.shared.infoLocalized(
                    "No Speech Detected",
                    message: "Nothing was sent."
                )
            }
        }
    }

    private func handlePauseCountdown() {
        guard case .paused(let remaining) = voiceInputState else { return }

        // Decrement by 0.1s (the timer interval)
        let newRemaining = remaining - 0.1

        if newRemaining <= 0 {
            // Countdown finished, send message
            let transcribedText = TranscriptionTextNormalizer.combined([
                speechService.confirmedTranscription,
                speechService.currentTranscription,
            ])

            if !transcribedText.isEmpty {
                sendVoiceMessage(transcribedText)
            } else {
                stopVoiceInputFromTimeout()
                ToastManager.shared.infoLocalized(
                    "No Speech Detected",
                    message: "Nothing was sent."
                )
            }
        } else {
            // Update remaining time
            voiceInputState = .paused(remaining: newRemaining)
        }
    }

    private func stopVoiceInputFromTimeout() {
        cancelLiveVoicePreencodeSession(removeRegistryEntry: true)
        Task {
            _ = await speechService.stopStreamingTranscription(force: false)
            speechService.clearTranscription()
        }
        voiceInputState = .idle
        showVoiceOverlay = false
    }

    private func sendVoiceMessage(_ message: String) {
        print("[FloatingInputCard] Sending voice message. Continuous mode: \(isContinuousVoiceMode)")
        logVoiceState(trigger: "sendVoiceMessage-start")
        let visibleInputMessage = TranscriptionTextNormalizer.visibleText(message)
        guard !visibleInputMessage.isEmpty else {
            cancelLiveVoicePreencodeSession(removeRegistryEntry: true)
            Task {
                _ = await speechService.stopStreamingTranscription()
                speechService.clearTranscription()
            }
            voiceInputState = .idle
            showVoiceOverlay = false
            ToastManager.shared.infoLocalized(
                "No Speech Detected",
                message: "Nothing was sent."
            )
            return
        }

        let voiceCaptureStart = CFAbsoluteTimeGetCurrent()
        let voiceSnapshot = mediaCapabilities.supportsAudio ? speechService.currentLiveAudioSnapshot() : nil
        let snapshotMs = Int((CFAbsoluteTimeGetCurrent() - voiceCaptureStart) * 1000)
        let wavEncodeStart = CFAbsoluteTimeGetCurrent()
        let voiceAudioData = voiceSnapshot?.wavData()
        let wavEncodeMs = Int((CFAbsoluteTimeGetCurrent() - wavEncodeStart) * 1000)
        let voiceAttachmentId = liveVoiceAttachmentId ?? UUID()
        liveVoiceAttachmentId = voiceAttachmentId
        let finalPreencodeTask = voiceSnapshot.flatMap {
            scheduleLiveVoicePreencodeIfNeeded(
                force: true,
                snapshot: $0,
                attachmentId: voiceAttachmentId
            )
        }
        if mediaCapabilities.supportsAudio {
            let wavBytes = voiceAudioData?.count ?? 0
            let durationMs = Int((voiceSnapshot?.durationSeconds ?? 0) * 1000)
            print(
                "[Osaurus][LiveVoice] snapshot_ms=\(snapshotMs) wav_encode_ms=\(wavEncodeMs) wav_bytes=\(wavBytes) sample_rate=\(voiceSnapshot?.sampleRate ?? 0) duration_ms=\(durationMs)"
            )
        }

        // show sending state first
        voiceInputState = .sending

        Task {
            _ = await speechService.stopStreamingTranscription()
            // clear transcription so next voice input starts fresh
            speechService.clearTranscription()
            logVoiceState(trigger: "sendVoiceMessage-afterStop")

            print("[FloatingInputCard] Invoking cleanup for voice message (\(visibleInputMessage.count) chars)")
            let cleanedMessage =
                SpeechConfigurationStore.load().postProcessTranscription
                ? await TranscriptionCleanupService.shared.clean(visibleInputMessage)
                : visibleInputMessage
            let visibleMessage = TranscriptionTextNormalizer.visibleText(cleanedMessage)
            print("[FloatingInputCard] Cleanup done. Original: \(message) | Cleaned: \(cleanedMessage)")

            guard !visibleMessage.isEmpty else {
                await MainActor.run {
                    voiceInputState = .idle
                    showVoiceOverlay = false
                    cancelLiveVoicePreencodeSession(removeRegistryEntry: true)
                    ToastManager.shared.infoLocalized(
                        "No Speech Detected",
                        message: "Nothing was sent."
                    )
                }
                return
            }

            await finalPreencodeTask?.value

            await MainActor.run {
                voiceInputState = .idle
                showVoiceOverlay = false

                let existing = localText.trimmingCharacters(in: .whitespacesAndNewlines)
                let fullMessage = TranscriptionTextNormalizer.merged(existing: existing, transcript: visibleMessage)

                if let voiceAudioData {
                    let voiceAttachment = Attachment(
                        id: voiceAttachmentId,
                        kind: .audio(
                            voiceAudioData,
                            format: "wav",
                            filename: "voice-input.wav"
                        )
                    )
                    if let voiceSnapshot {
                        LiveVoiceAudioInputRegistry.shared.store(
                            snapshot: voiceSnapshot,
                            for: voiceAttachment.id
                        )
                    }
                    pendingAttachments.append(voiceAttachment)
                }

                // Voice auto-send takes the same admission/acknowledgement
                // path as typed Send, retaining its transcript and audio
                // attachment if a warning needs user acknowledgement.
                localText = fullMessage
                text = fullMessage
                syncAndSend()
                cancelLiveVoicePreencodeSession(removeRegistryEntry: voiceAudioData == nil)
            }
        }
    }

    private func transferToTextInput() {
        print("[FloatingInputCard] Transferring to text input - disabling continuous mode")
        // Transfer transcription to text input and close overlay
        let transcribedText = TranscriptionTextNormalizer.combined([
            speechService.confirmedTranscription,
            speechService.currentTranscription,
        ])

        voiceInputState = .sending
        // exit continuous mode when switching to text
        isContinuousVoiceMode = false

        Task {
            _ = await speechService.stopStreamingTranscription()
            speechService.clearTranscription()

            let cleaned =
                SpeechConfigurationStore.load().postProcessTranscription
                ? await TranscriptionCleanupService.shared.clean(transcribedText)
                : transcribedText
            let visibleText = TranscriptionTextNormalizer.visibleText(cleaned)

            await MainActor.run {
                voiceInputState = .idle
                showVoiceOverlay = false

                guard !visibleText.isEmpty else {
                    ToastManager.shared.infoLocalized(
                        "No Speech Detected",
                        message: "Nothing was inserted."
                    )
                    return
                }

                let existing = localText.trimmingCharacters(in: .whitespacesAndNewlines)
                let fullCombined = TranscriptionTextNormalizer.merged(existing: existing, transcript: visibleText)

                if KeyboardSimulationService.shared.pasteText(visibleText) {
                    isFocused = true
                } else {
                    // Fallback if paste fails
                    localText = fullCombined
                    text = fullCombined
                    isFocused = true
                }
            }
        }
    }

    private func syncAndSend() {
        guard canSend else { return }
        // Sending under a model-switch advisory accepts the new model, so the
        // advisory has nothing left to ask.
        if modelSwitchContinuityWarning != nil {
            withAnimation(theme.motion.quick) {
                onDismissModelSwitchContinuityWarning?()
            }
        }
        // The runtime owns admission and actual load failures. Host swap must
        // never add a second Send/acknowledgment gate.
        commitSend(localText)
    }

    private func commitSend(_ message: String) {
        // Hold first responder through the binding-flush cascade
        // (clearing local + bound text, parent reconcile, optional
        // new run kickoff). 300 ms covers the longest observed
        // cascade with margin. Covers both fresh sends and queueing.
        textViewFocusController.lockFocus(for: 0.3)
        localText = ""
        text = ""
        // Sending resets history navigation; the sent text becomes the
        // newest history entry once its turn lands.
        inputHistoryState = ChatInputHistoryState()
        onSend(message)
    }

    // MARK: - Input History (terminal-style Up/Down recall)

    private func handleHistoryArrowUp() -> Bool {
        guard let provider = inputHistoryProvider, caretIsOnFirstLine else { return false }
        guard
            let result = ChatInputHistory.recall(
                state: inputHistoryState,
                entries: provider(),
                currentDraft: localText
            )
        else { return false }
        inputHistoryState = result.state
        applyHistoryText(result.text)
        return true
    }

    private func handleHistoryArrowDown() -> Bool {
        guard inputHistoryState.index != nil, caretIsOnLastLine else { return false }
        guard
            let result = ChatInputHistory.advance(
                state: inputHistoryState,
                entries: inputHistoryProvider?() ?? []
            )
        else { return false }
        inputHistoryState = result.state
        applyHistoryText(result.text)
        return true
    }

    /// Replace the composer text with a recalled entry and put the caret at
    /// the end, matching terminal behavior.
    private func applyHistoryText(_ newText: String) {
        localText = newText
        text = newText
        DispatchQueue.main.async {
            guard let tv = textViewFocusController.textView else { return }
            let end = (tv.string as NSString).length
            tv.setSelectedRange(NSRange(location: end, length: 0))
            tv.scrollRangeToVisible(NSRange(location: end, length: 0))
        }
    }

    /// True when the caret is a plain insertion point on the first line of
    /// the composer. History recall only triggers there, so Up still moves
    /// the caret inside a multi-line draft.
    private var caretIsOnFirstLine: Bool {
        guard let tv = textViewFocusController.textView else { return false }
        let range = tv.selectedRange()
        guard range.length == 0 else { return false }
        let ns = tv.string as NSString
        return !ns.substring(to: min(range.location, ns.length)).contains("\n")
    }

    /// True when the caret is a plain insertion point on the last line of
    /// the composer. Walking history forward only triggers there.
    private var caretIsOnLastLine: Bool {
        guard let tv = textViewFocusController.textView else { return false }
        let range = tv.selectedRange()
        guard range.length == 0 else { return false }
        let ns = tv.string as NSString
        return !ns.substring(from: min(range.location, ns.length)).contains("\n")
    }

    // MARK: - Slash Commands

    /// Returns the text with the active slash token replaced by `replacement`.
    private func replacingSlashToken(with replacement: String) -> String {
        guard let slashRange = localText.range(of: "/", options: .backwards) else {
            return replacement
        }
        let before = localText[..<slashRange.lowerBound]
        // Strip trailing space added by the button if replacement is empty
        let prefix = replacement.isEmpty ? before.trimmingCharacters(in: .whitespaces) : String(before)
        return prefix + replacement
    }

    private func applySlashCommand(_ command: SlashCommand) {
        switch command.kind {
        case .action:
            let newText = replacingSlashToken(with: "")
            localText = newText
            text = newText
            handleBuiltInSlashAction(command.name)
        case .template:
            let templateText = command.template ?? ""
            let newText = replacingSlashToken(with: templateText)
            localText = newText
            text = newText
            isFocused = true
        case .skill:
            let newText = replacingSlashToken(with: "")
            localText = newText
            text = newText
            isFocused = true
            onSkillSelected?(command.id)
        case .workflow:
            let newText = replacingSlashToken(with: "")
            localText = newText
            text = newText
            WorkflowRunLauncher.openTab(workflowID: command.id, agentId: effectiveAgentId)
        }
    }

    // MARK: - "@" File Menu

    /// Replace the trailing "@…" token with `replacement`, preserving the text
    /// before the "@".
    private func replacingAtToken(with replacement: String) -> String {
        guard let atRange = localText.range(of: "@", options: .backwards) else {
            return replacement
        }
        return String(localText[..<atRange.lowerBound]) + replacement
    }

    /// Apply a selected file/folder to the input. Folders keep the popup open
    /// with a trailing "/" so the user can drill deeper CLI-style; files insert
    /// the path followed by a space, which closes the token.
    private func applyAtItem(_ item: AtFileItem) {
        let inserted = item.isDirectory ? "@\(item.path)/" : "@\(item.path) "
        let newText = replacingAtToken(with: inserted)
        localText = newText
        text = newText
        isFocused = true
    }

    /// Refresh `atMenuItems` for the current "@" query off the main actor.
    /// Cancels any prior listing so fast typing can't pile up work. A nil query
    /// (token dismissed) clears the list synchronously.
    private func refreshAtMenu() {
        atMenuTask?.cancel()
        guard let query = activeAtQuery else {
            atMenuItems = []
            atMenuStatus = .ok
            atMenuLoading = false
            syncPopupVisibility()
            return
        }
        // Only treat this as a blocking "load" when we have nothing to show yet;
        // when refining an existing list we keep the current rows visible.
        atMenuLoading = atMenuItems.isEmpty
        // Snapshot THIS chat's folder root here (main actor); the enumeration
        // itself runs detached so filesystem I/O never blocks the UI.
        let rootPath = folderState.rootPath
        atMenuTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                AtFileMenu.list(query: query, rootPath: rootPath)
            }.value
            if Task.isCancelled { return }
            atMenuItems = result.items
            atMenuStatus = result.status
            atMenuDirectory = result.directory
            atMenuLoading = false
            syncPopupVisibility()
        }
    }

    /// Recover from a denied folder. macOS won't re-prompt after a denial, but
    /// because the app is non-sandboxed, the user explicitly picking the folder
    /// in an open panel re-grants TCC access. On success we re-list so browsing
    /// resumes in place. The panel is a main-actor modal (user interaction);
    /// the listing it triggers stays off the main thread.
    private func grantAtMenuAccess() {
        let directory = atMenuDirectory
        guard !directory.isEmpty else { return }
        Task {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = false
            panel.allowsMultipleSelection = false
            panel.directoryURL = URL(fileURLWithPath: directory)
            panel.prompt = L("Grant Access")
            panel.message = L("Grant osaurus access to this folder")
            guard await panel.beginModal() == .OK else { return }
            isFocused = true
            refreshAtMenu()
        }
    }

    /// Mirror whether either completion popup is showing into the shared
    /// registry so the global key monitor can suppress Escape (which would
    /// otherwise close the window) while a popup is open. Folded into
    /// `refreshAtMenu` and the slash `onChange` so it adds no body chain link.
    private func syncPopupVisibility() {
        SlashCommandRegistry.shared.isPopupVisible = showSlashPopup || showAtPopup
    }

    // MARK: - Input Key Handling

    /// Return/Enter in the text field: apply the highlighted popup entry when a
    /// popup is open, otherwise send the message.
    private func handleInputCommit() {
        if showSlashPopup {
            let cmds = slashFilteredCommands
            if slashSelectedIndex < cmds.count {
                applySlashCommand(cmds[slashSelectedIndex])
            }
        } else if showAtPopup {
            if atSelectedIndex < atMenuItems.count {
                applyAtItem(atMenuItems[atSelectedIndex])
            }
        } else {
            syncAndSend()
        }
    }

    /// Up arrow: move the open popup's selection, else navigate input history.
    private func handleInputArrowUp() -> Bool {
        if showSlashPopup {
            slashSelectedIndex = max(0, slashSelectedIndex - 1)
            return true
        }
        if showAtPopup {
            atSelectedIndex = max(0, atSelectedIndex - 1)
            return true
        }
        return handleHistoryArrowUp()
    }

    /// Down arrow: move the open popup's selection, else navigate input history.
    private func handleInputArrowDown() -> Bool {
        if showSlashPopup {
            slashSelectedIndex = min(slashFilteredCommands.count - 1, slashSelectedIndex + 1)
            return true
        }
        if showAtPopup {
            atSelectedIndex = min(atMenuItems.count - 1, atSelectedIndex + 1)
            return true
        }
        return handleHistoryArrowDown()
    }

    /// Escape while a popup is open: dismiss just the popup. The typed text
    /// (including the slash/"@" token) is left intact; the "@" menu removes
    /// only its token so surrounding text survives.
    private func handlePopupEscape() -> Bool {
        if showSlashPopup {
            dismissedSlashQuery = activeSlashQuery
            return true
        }
        if showAtPopup {
            let newText = replacingAtToken(with: "")
            localText = newText
            text = newText
            return true
        }
        return false
    }

    private func handleBuiltInSlashAction(_ name: String) {
        switch name {
        case "clear":
            if let clearChat = onClearChat {
                clearChat()
            } else {
                ToastManager.shared.infoLocalized("Clear Chat", message: "Pass an onClearChat handler to enable /clear")
            }
        case "model":
            // Ignored in Mode 2: the model is pinned to the remote agent's own
            // model and can't be changed from the client.
            guard !isModelPinned else {
                ToastManager.shared.infoLocalized(
                    "Model Pinned",
                    message: "This chat runs on the remote agent's own model, set by its owner."
                )
                break
            }
            openModelPicker()
        case "agent":
            NotificationCenter.default.post(
                name: .chatToolbarOpenAgentPicker,
                object: nil,
                userInfo: windowId.map { ["windowId": $0] }
            )
        case "screenshot":
            if let capture = onCaptureScreenshot {
                capture()
            } else {
                ToastManager.shared.infoLocalized(
                    "Screenshot Unavailable",
                    message: "Pass an onCaptureScreenshot handler to enable /screenshot"
                )
            }
        case "title":
            if let generateTitle = onGenerateTitle {
                generateTitle()
            } else {
                ToastManager.shared.infoLocalized(
                    "Chat Title",
                    message: "Pass an onGenerateTitle handler to enable /title"
                )
            }
        case "compact":
            if compactionState.isRunning {
                ToastManager.shared.infoLocalized(
                    "Compact Conversation",
                    message: "Compaction is already running."
                )
            } else if isStreaming {
                ToastManager.shared.infoLocalized(
                    "Compact Conversation",
                    message: "Wait for the current response to finish, then run /compact."
                )
            } else if let compact = onCompactConversation, canCompactConversation {
                compact()
            } else {
                ToastManager.shared.infoLocalized(
                    "Compact Conversation",
                    message: "Nothing to compact yet. The recent conversation is already as small as it can get."
                )
            }
        case "help":
            ToastManager.shared.infoLocalized(
                "Slash Commands",
                message: "Type / to open commands. ↑↓ to navigate, ↵ to select, Esc to dismiss."
            )
        default:
            break
        }
    }

    // MARK: - Queued Send Chip

    /// Compact chip preview of the queued message. Text-only payloads
    /// join the active run at the next iteration boundary (mid-run
    /// steering); payloads with attachments or a one-off skill flush when
    /// the run finishes (or dispatch immediately via Send Now).
    /// Visible only when `queuedSend != nil`.
    @ViewBuilder
    private var queuedSendChipView: some View {
        if let queued = queuedSend {
            let preview: String = {
                let trimmed = queued.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    return L("Queued attachment")
                }
                if trimmed.count <= 80 { return trimmed }
                return String(trimmed.prefix(80)) + "\u{2026}"
            }()
            HStack(spacing: theme.space.s4) {
                Image(systemName: "clock.arrow.circlepath")
                    .glyphSize(.footnote, weight: .medium)
                    .foregroundColor(theme.status.info.foreground)
                Text("Queued:", bundle: .module)
                    .textStyle(.footnote, weight: 600)
                    .foregroundColor(theme.status.info.foreground)
                Text(verbatim: preview)
                    .textStyle(.footnote, weight: 500)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                SettingsIconButton("xmark", help: "Cancel queued message", size: .extraExtraSmall) {
                    withAnimation(theme.motion.springAnimation) {
                        if let onCancelQueued {
                            onCancelQueued()
                        } else {
                            queuedSend = nil
                        }
                    }
                }
            }
            .padding(.horizontal, theme.space.s10)
            .padding(.vertical, theme.space.s6)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                    .fill(theme.status.info.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                    .strokeBorder(theme.status.info.border, lineWidth: theme.hairline)
            )
        }
    }

    // MARK: - Pending Skill Chip

    @ViewBuilder
    private var pendingSkillChipView: some View {
        if let skillId = pendingSkillId,
            let skill = SkillManager.shared.skill(for: skillId)
        {
            SharedChipContent(spacing: theme.assignedMetric("component.library.23.gap", fallback: theme.space.s4)) {
                Image(systemName: "wand.and.stars")
                    .glyphSize(.footnote, weight: .medium)
                    .composerChipInk("secondary", fallback: theme.text.secondary)
                Text(skill.name)
                    .composerChipTextStyle(.footnote, weight: 500)
                    .composerChipInk("foreground", fallback: theme.text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    withAnimation(theme.motion.springAnimation) {
                        pendingSkillId = nil
                    }
                } label: {
                    Image(systemName: "xmark")
                        .glyphSize(.tiny, weight: .bold)
                        .composerChipInk("secondary", fallback: theme.text.secondary)
                        .padding(theme.space.s2)
                        .background(Circle().fill(theme.surface.hover))
                }
                .composerChipButtonStyle()
                .pointingHandCursor()
            }
            .composerChipSurface(selected: true)
        }
    }

    // MARK: - Pending Attachments Preview (Inline)

    private var pendingAttachmentRowHeight: CGFloat {
        let documentHeight = max(AttachmentInspectionStyle.documentHeight(theme),
            20 + 2 * AttachmentInspectionStyle.metric("padding", theme.space.s4, theme))
        if !pendingAttachments.contains(where: \.isImage) {
            return documentHeight
        }
        return max(documentHeight, AttachmentInspectionStyle.imageHeight(theme, fallback: 40))
    }

    private var inlinePendingAttachmentsPreview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: AttachmentInspectionStyle.rowGap(theme)) {
                ForEach(pendingAttachments) { attachment in
                    switch attachment.kind {
                    case .image(let data):
                        CachedImageThumbnail(
                            imageData: data,
                            size: 40,
                            onRemove: {
                                withAnimation(theme.motion.springAnimation) {
                                    pendingAttachments.removeAll { $0.id == attachment.id }
                                }
                            },
                            onTap: {
                                imagePreview = PendingImagePreview(id: attachment.id, data: data)
                            }
                        )
                    case .imageRef:
                        // Pending attachments are pre-spillover; refs only
                        // appear after persistence. Defensive-render an
                        // empty thumbnail so we don't crash on a pending
                        // queue that someone re-hydrated from disk.
                        if let data = attachment.loadImageData() {
                            CachedImageThumbnail(
                                imageData: data,
                                size: 40,
                                onRemove: {
                                    withAnimation(theme.motion.springAnimation) {
                                        pendingAttachments.removeAll { $0.id == attachment.id }
                                    }
                                },
                                onTap: {
                                    imagePreview = PendingImagePreview(id: attachment.id, data: data)
                                }
                            )
                        }
                    case .document, .documentRef:
                        DocumentChip(
                            attachment: attachment,
                            onRemove: {
                                withAnimation(theme.motion.springAnimation) {
                                    pendingAttachments.removeAll { $0.id == attachment.id }
                                }
                            },
                            onTap: attachment.isPastedContent
                                ? {
                                    pastedContentPreview = attachment
                                } : nil,
                            onEdit: attachment.isPastedContent
                                ? {
                                    pastedContentEdit = attachment
                                } : nil,
                            onInline: attachment.isPastedContent
                                ? {
                                    inlinePastedContent(attachment)
                                } : nil
                        )
                    case .audio, .audioRef, .video, .videoRef:
                        // Audio/video attachments display as a labeled chip
                        // with a media-type icon. Inline-bytes are kept on
                        // the pending queue (pre-spillover); refs may also
                        // round-trip through chat history. Same on-remove
                        // semantics as image/document chips.
                        DocumentChip(attachment: attachment) {
                            withAnimation(theme.motion.springAnimation) {
                                pendingAttachments.removeAll { $0.id == attachment.id }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
            // Reserve only the remove badges' outward overhang so the
            // horizontal scroll viewport does not clip their top/right edges.
            .padding(.top, theme.space.s4)
            .padding(.trailing, theme.space.s4)
        }
        .frame(height: pendingAttachmentRowHeight + theme.space.s4)
        .sheet(item: $pastedContentPreview) { attachment in
            PastedContentSheet(attachment: attachment) {
                pastedContentPreview = nil
            }
        }
        .sheet(item: $pastedContentEdit) { attachment in
            PastedContentSheet(
                attachment: attachment,
                onDismiss: { pastedContentEdit = nil },
                onSave: { updated in
                    if let idx = pendingAttachments.firstIndex(where: { $0.id == attachment.id }) {
                        pendingAttachments[idx] = .pastedContent(updated)
                    }
                    pastedContentEdit = nil
                }
            )
        }
        .sheet(item: $imagePreview) { preview in
            PendingImagePreviewSheet(imageData: preview.data, imageId: preview.id.uuidString) {
                imagePreview = nil
            }
        }
    }

    private func inlinePastedContent(_ attachment: Attachment) {
        guard let content = attachment.loadDocumentContent(), !content.isEmpty else { return }
        let existing = localText
        let combined: String
        if existing.isEmpty {
            combined = content
        } else if existing.hasSuffix("\n") {
            combined = existing + content
        } else {
            combined = existing + "\n" + content
        }
        withAnimation(theme.motion.springAnimation) {
            pendingAttachments.removeAll { $0.id == attachment.id }
        }
        localText = combined
        text = combined
        isFocused = true
    }

    // MARK: - Selector Row (Model + Tools)

    // MARK: - Native MTP depth (model picker)

    static let nativeMTPOptionID = "nativeMTPDepth"

    /// The picker's model id and the runtime's model name are NOT the same
    /// string: the picker holds `JANGQ-AI/Qwen3.8-27B-JANG_4D` while
    /// `ModelCacheSummary.name` is `qwen3.8-27b-jang_4d` — namespace stripped
    /// and lowercased. Comparing them directly silently matched nothing, so
    /// the depth row never appeared on a model that plainly has an MTP head.
    /// Normalise both sides through one function so they cannot drift apart.
    /// vmlx's status line begins "mtp: <mode>, layers=N, tensors=N" for
    /// EVERY inspected bundle — a headless model reads "mtp: none, layers=0,
    /// tensors=0". Matching the bare "mtp:" prefix therefore admitted every
    /// resident model and the depth row rendered on models with no MTP head
    /// at all. Capability means the status names a REAL head: a mode that
    /// implies weights, and a nonzero tensor count.
    nonisolated static func statusIndicatesNativeMTPHead(_ status: String?) -> Bool {
        guard let status, status.hasPrefix("mtp: ") else { return false }
        let mode = status.dropFirst("mtp: ".count)
            .prefix(while: { $0 != "," })
        switch mode {
        case "none", "unknown", "metadata_only_missing_weights":
            return false
        default:
            break
        }
        if let range = status.range(of: "tensors=") {
            let digits = status[range.upperBound...].prefix(while: \.isNumber)
            if let count = Int(digits) { return count > 0 }
        }
        // A mode that implies a head but no parseable tensor count: trust
        // the mode rather than hiding a control on a capable bundle.
        return true
    }

    static func mtpIdentity(_ model: String) -> String {
        (model.split(separator: "/").last.map(String.init) ?? model)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// Product selection requests adaptive admission; runtime resolution can
    /// remain autoregressive when the bundle is missing verified tuning.
    private func nativeMTPOption(for model: String) -> ModelOptionDefinition? {
        let identity = Self.mtpIdentity(model)
        guard !isRemoteAgentRun,
            nativeMTPCapableModels.contains(identity)
        else { return nil }
        let manuallyBlocked = nativeMTPManuallyBlockedModels.contains(identity)
        return ModelOptionDefinition(
            id: Self.nativeMTPOptionID,
            label: L("Speculative Decoding"),
            icon: "hare",
            kind: .segmented(
                manuallyBlocked
                    ? [ModelOptionSegment(id: "off", label: L("Off (AR)"))]
                    : [
                        ModelOptionSegment(id: "off", label: L("Off (AR)")),
                        ModelOptionSegment(id: "auto", label: L("On (Adaptive)")),
                    ]
            ),
            // Depth controls speculation, not the user's sampling settings.
            help: manuallyBlocked
                ? L(
                    "Speculative decoding is disabled for this bundle because its MTP head is not safe for production use."
                )
                : L(
                    "Off uses ordinary autoregressive decoding. On uses a compatible bundled drafter (DSpark, Uno or DFlash 2), a selected DFlash 2 drafter, or adaptive native MTP when supported. Ineligible requests continue with ordinary decoding; see Speculative Decoding settings for the resolved reason. Sampling stays unchanged."
                )
        )
    }

    /// Current saved value as a segment id.
    private static func nativeMTPSegment(
        _ mtp: VMLXServerMTPSettings
    ) -> String {
        mtp.mode == .off ? "off" : "auto"
    }

    /// Writes through the same path the Settings pane uses, so there is one
    /// persistence route and one enforcement route.
    ///
    /// Depth-only changes apply to the next request; changes that require a
    /// different loaded model graph follow the guarded reload lifecycle.
    private func applyNativeMTPSegment(_ segment: String?) {
        let targetAgentID = effectiveAgentId
        if agentManager.effectiveGenerationSettings(for: targetAgentID)?.speculativeDecoding != nil,
            let mode = NativeMTPSelectionDefault.mode(for: segment)
        {
            agentManager.updateSpeculativeDecoding(
                mode == .familyDefault ? nil : mode != .off, for: targetAgentID)
            return
        }
        Task { @MainActor in
            // Read the latest settings when the task executes; only an
            // explicit control action writes MTP. Selection is read-only.
            var settings = ServerController.runtimeSettingsForConfigureTool().settings
            guard let mode = NativeMTPSelectionDefault.mode(for: segment) else { return }
            settings.mtp.mode = mode
            settings.mtp.draftTokenLimit = nil
            settings.mtp.explicitDepth = nil
            _ = await ServerController.applyRuntimeSettingsFromConfigureTool(
                settings, mtpSelectionIsFamilyDefault: mode == .familyDefault)
            // A rejected save must not leave an optimistic segment displayed.
            nativeMTPSelection = Self.nativeMTPSegment(
                ServerController.runtimeSettingsForConfigureTool().settings.mtp)
        }
    }

    /// Refreshes both the capable-model set and the saved selection.
    private func refreshNativeMTPState() {
        nativeMTPSelection = Self.nativeMTPSegment(
            ServerController.runtimeSettingsForConfigureTool().settings.mtp
        )
        Task { @MainActor in
            let summaries = await ModelRuntime.shared.cachedModelSummaries()
            // UNION, not replace: capability is a property of the bundle, and
            // the summaries only cover RESIDENT models. Replacing meant the
            // depth row vanished the moment Mode=Off unloaded the model — the
            // exact time a user wants the control to switch back on.
            nativeMTPCapableModels.formUnion(
                summaries.filter {
                    Self.statusIndicatesNativeMTPHead($0.nativeMTPStatus)
                }
                .map { Self.mtpIdentity($0.name) }
            )
            // Early, by-WEIGHT capability for models still LOADING, so the
            // depth row appears during warmup instead of minutes later.
            // Weight-based (configs lie: JANG_1L has no `mtp` field; a 27B
            // index omitted its mtp.* tensors) and gated by the engine
            // launch policy, shared with pre-load selection. File-only
            // inspection, run off-main.
            let loadingNames = await ModelRuntime.shared.loadingModelNames()
            if !loadingNames.isEmpty {
                let early: [ModelRuntime.LoadingModelMTPStatus] = await Task.detached {
                    loadingNames.compactMap { name in
                        guard
                            let status = ModelRuntime.inspectLoadingModelMTP(name: name),
                            status.speculationAvailable
                        else { return nil }
                        return status
                    }
                }.value
                nativeMTPCapableModels.formUnion(early.map { Self.mtpIdentity($0.name) })
                nativeMTPFamilyDefaultOnModels.formUnion(
                    early.filter { $0.familyDefaultOn }.map { Self.mtpIdentity($0.name) })
                // A blocked tuning artifact must gate the EARLY window too —
                // the resident-summary blocked set only covers loaded models,
                // so without this the whole warmup would show depth segments
                // the engine will refuse.
                nativeMTPManuallyBlockedModels.formUnion(
                    early.filter(\.speculationBlocked).map { Self.mtpIdentity($0.name) }
                )
            }
            let residentIdentities = Set(summaries.map { Self.mtpIdentity($0.name) })
            nativeMTPManuallyBlockedModels.subtract(residentIdentities)
            nativeMTPManuallyBlockedModels.formUnion(
                summaries.filter {
                    $0.nativeMTPStatus?.contains("manual=blocked") == true
                }
                .map { Self.mtpIdentity($0.name) }
            )
        }
    }

    private var activeProfileOptions: [ModelOptionDefinition] {
        guard let model = selectedModel else { return [] }
        return ModelProfileRegistry.options(for: model)
    }

    /// Catalog-driven reasoning capabilities for the selected model (Codex
    /// live catalog / official OpenAI GPT-5.6 contract). When present, the
    /// effort control renders inline with the model chip instead of the
    /// separate options chip.
    ///
    /// Resolve LIVE through the registry, not only the picker-item snapshot:
    /// `ModelPickerItem.reasoningCapabilities` is populated exclusively for
    /// remote models (Codex metadata, GPT builtin ids), so a LOCAL bundle
    /// with a stamped effort contract (Qwen3.8's
    /// `jang_config.reasoning.default_reasoning_effort = "xhigh"`) reached
    /// the picker popover with nil capabilities. The popover's defaults then
    /// fell back to the static profile (no `reasoningEffort` key) and its
    /// Effort row highlighted the FIRST segment — "None" with a Default pill
    /// — while the model chip, which already resolves through the registry,
    /// truthfully showed "· Extra High". Observed live 2026-09-01 on
    /// Qwen3.8-27B: the two surfaces contradicted each other while the
    /// template correctly rendered xhigh. One resolution source ends the
    /// divergence; the registry consults the remote catalog first, so
    /// remote-model behavior is unchanged.
    private var inlineEffortCapabilities: ModelReasoningCapabilities? {
        if let capabilities = selectedPickerItem?.reasoningCapabilities,
            !capabilities.isEmpty
        {
            return capabilities
        }
        guard let model = selectedModel,
            let declared = ModelProfileRegistry.reasoningCapabilities(for: model),
            !declared.isEmpty
        else { return nil }
        return declared
    }

    /// Presentation uses the actual agent/request precedence without changing model defaults.
    private var effectiveReasoningOptions: [String: ModelOptionValue] {
        guard let model = selectedModel else { return activeModelOptions }
        var controls = ChatTurnGenerationControls.capture(activeModelOptions: activeModelOptions)
        controls.agentSettings = agentManager.effectiveGenerationSettings(for: effectiveAgentId)
        return controls.reasoningOptions(for: model)
    }

    private var hasAgentReasoningOverride: Bool {
        agentManager.effectiveGenerationSettings(for: effectiveAgentId)?.hasReasoningOverride == true
    }

    private var reasoningSelectionNeedsChoice: Bool {
        _ = reasoningCapabilityRevision
        guard let model = selectedModel, !isRemoteAgentRun,
            let settings = agentManager.effectiveGenerationSettings(for: effectiveAgentId),
            settings.hasReasoningOverride
        else { return false }
        let capability: LocalReasoningCapability.Capability
        if isSelectedModelLocal {
            guard let resolved = LocalReasoningCapability.capabilityForPresentation(forModelId: model)
            else { return false }
            capability = resolved
        } else {
            capability = .none
        }
        let choices = AgentGenerationReasoningChoices.resolved(modelID: model,
            localCapability: capability, efforts: inlineEffortCapabilities, options: activeProfileOptions)
        return choices.reasoningIssue(settings: settings) != nil
    }

    private func refreshReasoningSelectionCapability() async {
        guard let model = selectedModel, isSelectedModelLocal, !isRemoteAgentRun,
            hasAgentReasoningOverride else { return }
        _ = await LocalReasoningCapability.resolveForDispatch(modelId: model)
        guard !Task.isCancelled, selectedModel == model else { return }
        // Known non-reasoning models also need a repaint after a cold cache miss.
        reasoningCapabilityRevision &+= 1
    }

    private var reasoningSelectionMessage: String? {
        reasoningSelectionNeedsChoice ? L("Choose a supported reasoning setting.") : nil
    }

    /// The reasoning suffix the model chip should display ("· Extra High",
    /// "· Instruct"): the explicit persisted choice, otherwise the
    /// catalog/profile default (display-only; an unset option sends no
    /// override on the wire). Covers both capability-enriched remote models
    /// and static profiles with a segmented reasoning option.
    private var inlineReasoningSuffix: String? {
        guard let model = selectedModel else { return nil }
        if reasoningSelectionNeedsChoice { return L("Choose reasoning") }
        return ModelProfileRegistry.inlineReasoningSuffixLabel(
            for: model,
            values: effectiveReasoningOptions
        )
    }

    /// Effective thinking state for toggle-only reasoning models, exposed in
    /// the model chip's tooltip and accessibility value. Nil omits this detail
    /// for models with a segmented effort suffix, models without a thinking
    /// toggle, and Mode 2 remote-agent runs — the remote agent owns its generation config
    /// server-side, so a local state readout would mislead.
    private var inlineThinkingEnabled: Bool? {
        guard let model = selectedModel,
            !isRemoteAgentRun,
            !reasoningSelectionNeedsChoice,
            inlineReasoningSuffix == nil,
            let option = ModelProfileRegistry.profile(for: model)?.thinkingOption,
            activeProfileOptions.contains(where: { $0.id == option.id }),
            thinkingPresentationIsReady(for: model)
        else { return nil }
        return effectiveThinkingEnabled(for: model)
    }

    private var inlineThinkingUsesNativeDefault: Bool {
        guard let model = selectedModel, !isRemoteAgentRun else { return false }
        return LocalReasoningCapability.capability(forModelId: model).preservesOmittedThinking
            && ModelProfileRegistry.thinkingEnabled(for: model, values: effectiveReasoningOptions) == nil
    }

    /// Keep the chip and picker on the same policy as dispatch. In a local
    /// tool-capable chat, omitted controls preserve the bundle template default.
    /// Explicit agent choices compose with the inherited model options.
    private func effectiveThinkingEnabled(for model: String) -> Bool {
        AgentReasoningPolicy.effectiveEnableThinkingForPresentation(
            isAgentOrToolRequest: appliesAgentReasoningDefault,
            modelOptions: effectiveReasoningOptions,
            capability: LocalReasoningCapability.capability(forModelId: model)
        )
    }

    private func thinkingPresentationIsReady(for model: String) -> Bool {
        ModelProfileRegistry.thinkingEnabled(for: model, values: effectiveReasoningOptions) != nil
            || LocalReasoningCapability.capabilityForPresentation(forModelId: model) != nil
    }

    private var selectorRow: some View {
        HStack(spacing: theme.space.s6) {
            // Image-generation models have no thinking, sandbox, folder or
            // token-budget semantics — those chips would all be inert. Swap
            // the whole row for the image config controls instead so they sit
            // right beside the model that owns them.
            if isMediaComposerActive && !isHarnessAgent {
                // Scroll the config chips horizontally so a narrow (minimum-size)
                // window can't compress them below their ideal width — that
                // compression is what made the labels wrap character-by-character.
                // The negative prompt rides at the end of the same row: pinned
                // outside, its free-length label squeezed the chips instead.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: theme.space.s6) {
                        imageComposerChips
                        // A compact button that opens a themed editor on tap.
                        if selectedMediaPickerItem?.mediaModel != nil
                            || imageComposerControls.negativePrompt
                        {
                            negativePromptButton
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.vertical, theme.space.s2)
                }
            } else {
                // The interactive toggle chips collapse to icon-only when the
                // chat area is too narrow to show every label (e.g. the sidebar
                // is open) — `chipsCompact`, derived from the measured region
                // width below, drives that. The primary Thinking control and
                // chips carrying live state (folder name, sandbox download %)
                // keep their text regardless; every
                // collapsed chip still names itself on hover via help(). The
                // ScrollView is the no-wrap safety net: it fills the space
                // between the model chip and the meta cluster (so the meta
                // cluster stays right-aligned, just like a Spacer would), and
                // guarantees the labels never wrap character-by-character even
                // at the minimum window width. We measure this region rather
                // than probe layout candidates so the sidebar animation, which
                // changes this width every frame, only triggers one cheap
                // cluster build per frame instead of ViewThatFits's three.
                ScrollView(.horizontal, showsIndicators: false) {
                    toggleChipCluster(compact: chipsCompact)
                        .padding(.vertical, theme.space.s2)
                }
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    chipRegionWidth = width
                }

                // Right-aligned "meta" cluster: balance + token usage.
                metaCluster
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            selectorRowWidth = width
        }
    }

    /// Whether the right-edge meta cluster should shed its non-essential bits
    /// (the credits icon, the "tokens" caption). True when the caller asked for
    /// compact (sidebar open) OR the row itself is narrow — the latter is what
    /// was missing: tiling the window narrow with the sidebar closed left the
    /// meta cluster at full width and crowded the chips off the row.
    private var metaCompact: Bool {
        isCompact || (selectorRowWidth > 0 && selectorRowWidth < 620)
    }

    /// A tighter tier for genuinely tiny rows (e.g. minimum window width *with*
    /// the sidebar open, which leaves the chat pane only ~260pt). Here the meta
    /// cluster gives up its lowest-priority pieces so the toggle chips still fit
    /// without being clipped mid-icon: the token readout is dropped and the
    /// credits CTA shrinks to its glyph (click opens the wallet).
    private var metaUltraCompact: Bool {
        selectorRowWidth > 0 && selectorRowWidth < 430
    }

    /// Whether the toggle chips should collapse to icon-only. True once the
    /// measured `chipRegionWidth` is narrower than the labeled chips would
    /// need. The per-chip width is a deliberate estimate — the ScrollView
    /// safety net absorbs any error, so this only has to be in the ballpark to
    /// flip the row to icons a beat before the labels would otherwise scroll.
    private var chipsCompact: Bool {
        guard chipRegionWidth > 0 else { return false }
        let perLabeledChip: CGFloat = 96
        return chipRegionWidth < CGFloat(visibleToggleChipCount) * perLabeledChip
    }

    /// Count of toggle chips currently in the cluster, mirroring the visibility
    /// conditions in `toggleChipCluster`. Drives the `chipsCompact` width
    /// budget so the collapse point scales with how many chips are actually on
    /// screen (a remote-agent run, for instance, hides most of them).
    private var visibleToggleChipCount: Int {
        var count = 0
        if autoSpeakAssistant { count += 1 }
        if isSandboxLeaseBlocked { count += 1 }
        // Configuration chip, or the folder chip once a folder is active.
        if !isRemoteAgentRun, folderState.hasActiveFolder { count += 1 }
        return count
    }

    /// The interactive toggle chips (auto-speak, sandbox, folder)
    /// as one horizontal group. Thinking is controlled from the model picker
    /// `Model Options` section and reflected as the brain glyph on the model
    /// chip, so changing reasoning mode always goes through the model-scoped
    /// dropdown path. `selectorRow` renders one rendering of this cluster,
    /// choosing `compact` from the measured region width so the row degrades
    /// gracefully as it narrows without re-measuring layout candidates every
    /// frame.
    @ViewBuilder
    private func toggleChipCluster(compact: Bool) -> some View {
        HStack(spacing: theme.space.s6) {
            if autoSpeakAssistant {
                autoSpeakToggleChip(compact: compact)
            }

            if isSandboxLeaseBlocked {
                sandboxToggleChip(compact: compact)
            }

            // Folder selection lives in the + attach menu now, so the chip
            // only appears once a folder is active (it still carries the
            // change/refresh/clear affordances). The Default (configuration)
            // agent keeps its quiet indicator. Hidden in Mode 2.
            if !isRemoteAgentRun {
                if folderState.hasActiveFolder {
                    folderContextChip(compact: compact)
                }
            }

        }
    }

    /// Passive status group for the right edge of the selector row: the Osaurus
    /// Router balance and the context/token indicator, joined by a hairline only
    /// when both are present. Rendered as muted text (the balance chip adds its
    /// own pill only in the low/empty attention states) so it never competes
    /// with the interactive chips on the left.
    @ViewBuilder
    private var metaCluster: some View {
        // Hide the balance/credits chip while a remote agent is connecting —
        // it's not actionable yet and competes with the connect affordance.
        // A remote agent's run (workspace or directly shared) never draws
        // from this Mac's wallet, so the personal balance is noise there.
        // Pool-billed chat — a teammate's agent (billed by its host, relayed
        // live) or one of this Mac's own shared agents with "Bill the
        // workspace pool" on: show that spend explicitly rather than the
        // personal wallet, which this session never draws from.
        if let workspacePoolLabel, !remoteConnectionPending {
            FloatingWorkspacePoolChip(
                workspaceName: workspacePoolLabel,
                workspaceId: workspacePoolId,
                spendMicro: sessionSpendMicro,
                metaCompact: metaCompact,
                metaUltraCompact: metaUltraCompact
            )
        }
    }

    /// Context budget as a circular progress ring in the button bar, left of
    /// the voice button. Mode 2 hides it entirely: a remote agent composes
    /// its own system prompt / tools server-side, so a local token breakdown
    /// doesn't reflect what actually runs and would mislead about the remote
    /// agent's budget.
    @ViewBuilder
    private var contextBudgetRing: some View {
        // Bound once: every field below comes from this single pass, so the
        // chip costs one window resolution and one breakdown per render.
        let budget = contextBudget
        if budget.displayTokens > 0 && !isRemoteAgentRun && !isHarnessAgent {
            FloatingContextChip(
                displayTokens: budget.displayTokens,
                usableTokens: budget.usableTokens,
                modelMaxTokens: budget.maxTokens,
                windowResolution: budget.resolution,
                isStreaming: isStreaming,
                isNearLimit: budget.nearLimit,
                isHardOverflow: budget.hardOverflow,
                usageRatio: budget.usageRatio,
                formatTokenCount: formatTokenCount,
                breakdown: { budget.breakdown },
                compactionState: compactionState,
                canCompact: canCompactConversation && !isStreaming,
                onCompact: onCompactConversation,
                currentSessionKey: inputHistoryKey?.uuidString,
                currentModel: selectedModel
            )
        }
    }

    /// Format token count for compact display (e.g., "1.2k", "15k")
    private func formatTokenCount(_ tokens: Int) -> String {
        if tokens < 1000 {
            return "\(tokens)"
        } else if tokens < 10000 {
            let k = Double(tokens) / 1000.0
            return String(format: "%.1fk", k)
        } else {
            let k = tokens / 1000
            return "\(k)k"
        }
    }

    // MARK: - Model Selector

    private var selectedPickerItem: ModelPickerItem? {
        guard let id = selectedModel else { return nil }
        return pickerItems.first { $0.id == id }
    }

    private var selectedImagePickerItem: ModelPickerItem? {
        guard
            selectedPickerItem?.source.isImageGeneration == true
                || selectedPickerItem?.mediaModel?.kind == .image
        else { return nil }
        return selectedPickerItem
    }

    private var selectedMediaPickerItem: ModelPickerItem? {
        guard selectedPickerItem?.isMediaGeneration == true else { return nil }
        return selectedPickerItem
    }

    private var imageCapabilities: ImageModelCapabilities? {
        selectedImagePickerItem?.imageCapabilities
    }

    private var imageComposerControls: ImageComposerRequestBuilder.Controls {
        ImageComposerRequestBuilder.controls(
            capabilities: imageCapabilities,
            fallbackKind: selectedImagePickerItem?.imageKind,
            hasReferences: pendingAttachments.hasImages
        )
    }

    private var isImageComposerActive: Bool {
        selectedImagePickerItem != nil
    }

    private var isMediaComposerActive: Bool {
        selectedMediaPickerItem != nil
    }

    private var isSelectedModelLocal: Bool {
        guard let id = selectedModel else { return false }
        // Cache-only lookup: this getter runs in view-body context (and on
        // model selection and residency updates), where the
        // blocking `findInstalledModel(named:)` can park on a cold-cache
        // disk scan for seconds and hang the app.
        return ModelManager.findInstalledMLXModelFromCache(named: id) != nil
    }

    nonisolated static func localBundleAdvisoriesApply(
        isSelectedModelLocal: Bool,
        isRemoteAgentRun: Bool
    ) -> Bool {
        isSelectedModelLocal && !isRemoteAgentRun
    }

    private var localBundleAdvisoriesApplyToSelectedModel: Bool {
        Self.localBundleAdvisoriesApply(
            isSelectedModelLocal: isSelectedModelLocal,
            isRemoteAgentRun: isRemoteAgentRun
        )
    }

    private var modelWarmupDotColor: Color {
        if !componentEnabled { return theme.assignedColor("component.library.23.disabledForeground", fallback: theme.text.disabled) }
        // Remote models and remote agent runs execute elsewhere — there is
        // no local load state to report.
        guard isSelectedModelLocal, !isRemoteAgentRun else {
            return theme.status.success.foreground
        }
        // Lazy loading: readiness is residency. Green only while the model is
        // actually loaded — a merely selected model is gray until the first
        // Send loads it, and an idle unload turns it gray again.
        return warmupController.selectedModelResident ? theme.status.success.foreground : theme.text.tertiary
    }

    /// Residency tooltip for the model chip, applied as a modifier so only
    /// the modifier's own view node observes the controller. Send-time load
    /// and prefill progress is the ordinary inference progress UI
    /// (`InferenceProgressManager`); the tooltip states residency only.
    private struct ModelWarmupHelp: ViewModifier {
        /// `isSelectedModelLocal && !isRemoteAgentRun` — a local model whose
        /// load state is knowable.
        let isLocalModelRun: Bool
        let selectedModel: String?
        let modelDetails: String
        /// Replaces the model status when the agent runs on a harness.
        var harnessHelp: String? = nil
        @ObservedObject var warmupController: ChatWarmupController

        func body(content: Content) -> some View {
            content.help(harnessHelp ?? modelHelp)
        }

        private var modelHelp: String {
            [helpText, modelDetails].filter { !$0.isEmpty }.joined(separator: "\n")
        }

        private var helpText: String {
            guard isLocalModelRun else {
                return String(localized: "Model ready", bundle: .module)
            }
            return warmupController.selectedModelResident
                ? String(localized: "Model loaded — ready to respond", bundle: .module)
                : String(
                    localized: "Model not loaded — your next message loads it first",
                    bundle: .module
                )
        }
    }

    @ViewBuilder
    private var modelSelectorChip: some View {
        if isModelPinned {
            pinnedModelChip
        } else {
            interactiveModelSelectorChip
        }
    }

    /// Chip label when the agent runs on an external harness: the runtime,
    /// plus the Claude Code model it launches with.
    private var harnessChipLabel: some View {
        let missing = harnessRuntime == nil
        return SharedChipContent(spacing: theme.assignedMetric("component.library.23.gap", fallback: theme.space.s6)) {
            Text(harnessRuntime?.displayName ?? L("Runtime missing"))
                .composerChipTextStyle(.caption, weight: 500)
                .composerChipInk(missing ? "error" : "foreground", fallback: missing ? theme.status.warning.foreground : theme.text.secondary)
                .lineLimit(1)
            if let model = harnessClaudeModelLabel {
                Text(verbatim: "· \(model)")
                    .composerChipTextStyle(.caption, property: "caption")
                    .composerChipInk("secondary", fallback: theme.text.tertiary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.up.chevron.down")
                .composerChipTextStyle(.caption, property: "caption")
                .composerChipInk("secondary", fallback: theme.text.tertiary)
        }
        .modifier(CappedHuggingWidth(maxWidth: Self.modelChipMaxLabelWidth))
    }

    private var harnessClaudeModelLabel: String? {
        guard let runtime = harnessRuntime, runtime.kind == .claudeCode else { return nil }
        let config = agentManager.effectiveClaudeCodeConfig(for: effectiveAgentId)
        let model = config.resolvedModel
        let label = ClaudeCodeModel(rawValue: model) != nil ? model.capitalized : model
        guard let effort = config.resolvedEffort else { return label }
        return "\(label) · \(effort.displayName)"
    }

    /// Claude Code's Reasoning Effort for the picker's options column. The
    /// same `effort` the agent's Claude Code Options edit, so both stay in
    /// step; the chat's process relaunches with it on the next message.
    private var harnessPickerOptionsControl: ModelPickerOptionsControl? {
        guard let runtime = harnessRuntime, runtime.kind == .claudeCode else { return nil }
        let agentId = effectiveAgentId
        let config = agentManager.effectiveClaudeCodeConfig(for: agentId)
        let optionID = ClaudeCodeEffort.pickerOptionID
        return ModelPickerOptionsControl(
            capabilities: nil,
            options: [ClaudeCodeEffort.pickerOption],
            values: config.resolvedEffort.map { [optionID: .string($0.rawValue)] } ?? [:],
            defaults: [optionID: .string(ModelOptionSegment.defaultID)],
            onChange: { _, newValue in
                // Deferred: the chip anchoring the popover renders the effort,
                // and resizing it during the popover's own update crashes
                // NSPopover.
                DispatchQueue.main.async {
                    var updated = agentManager.effectiveClaudeCodeConfig(for: agentId)
                    let effort = ClaudeCodeEffort.storedValue(forSegment: newValue?.stringValue)
                    guard updated.resolvedEffort?.rawValue != effort else { return }
                    updated.effort = effort
                    agentManager.updateClaudeCodeConfig(updated, for: agentId)
                    harnessConfigRevision &+= 1
                }
            }
        )
    }

    private var harnessChipHelp: String? {
        guard isHarnessAgent else { return nil }
        guard let runtime = harnessRuntime else {
            return L("This agent's runtime was deleted. Pick another runtime or a model.")
        }
        return String(
            format: L("This agent runs on %@, which uses its own tools. Click to switch runtimes or models."),
            runtime.displayName
        )
    }

    /// Runtimes offered as picker columns. A remote agent run is pinned to
    /// the remote agent's own model, so it offers none.
    private var pickerHarnessRuntimes: [HarnessRuntime] {
        guard !isRemoteAgentRun, !isModelPinned else { return [] }
        return harnessRuntimeStore.all()
    }

    private var selectedHarnessPickerID: String? {
        ChatHarnessPickerOption.selectedID(
            runtime: harnessRuntime,
            claudeConfig: agentManager.effectiveClaudeCodeConfig(for: effectiveAgentId)
        )
    }

    /// Per-agent, like a model pick: the agent's runtime changes for this
    /// chat and later ones. Nil moves it back to the built-in loop.
    private func selectHarness(_ option: ChatHarnessPickerOption?) {
        let agentId = effectiveAgentId
        guard let option else {
            agentManager.updateRuntime(.builtIn, for: agentId)
            harnessConfigRevision &+= 1
            return
        }
        if let claudeModel = option.claudeModel {
            var config = agentManager.effectiveClaudeCodeConfig(for: agentId)
            if config.resolvedModel != claudeModel {
                config.model = claudeModel
                agentManager.updateClaudeCodeConfig(config, for: agentId)
            }
        }
        agentManager.updateRuntime(.harness(option.runtimeId), for: agentId)
        harnessConfigRevision &+= 1
    }

    /// Non-interactive model label for Mode 2 (remote agent run). The model is
    /// pinned to the remote agent's own model — no chevron, no popover, just the
    /// model name and a lock glyph. Styled to match the resting `SelectorChip`.
    private var pinnedModelChip: some View {
        SharedChipContent(spacing: theme.assignedMetric("component.library.23.gap", fallback: theme.space.s6)) {
            Image(systemName: "lock.fill")
                .glyphSize(.micro)
                .composerChipInk("secondary", fallback: theme.text.tertiary)
            Text(pinnedModelLabel ?? selectedPickerItem?.displayName ?? L("Default"))
                .composerChipTextStyle(.caption, weight: 500)
                .composerChipInk("foreground", fallback: theme.text.secondary)
                .lineLimit(1)
        }
        .modifier(CappedHuggingWidth(maxWidth: Self.modelChipMaxLabelWidth))
        .modifier(QuietChipSurface(isActive: false, isHovered: false))
        .localizedHelp(
            "This chat runs on the remote agent's own model — chosen by the agent's owner and not changeable here."
        )
    }

    private func openModelPicker() {
        guard !showModelPicker else { return }
        cachedPickerItems = pickerItems
        modelPickerCardSize = ChatModelPickerCard.initialSize(
            providers: chatPickerProviders,
            selectedModel: selectedModel,
            optionsControl: modelPickerOptionsControl,
            selectedHarnessID: selectedHarnessPickerID,
            harnessOptionsControl: harnessPickerOptionsControl
        )
        showModelPicker = true
    }

    /// Keep the pill visually simple while retaining the removed badges'
    /// thinking and input-capability information for hover and VoiceOver.
    private var modelSelectorDetails: String {
        guard !isHarnessAgent else { return "" }
        var details: [String] = []
        if let thinkingOn = inlineThinkingEnabled {
            if inlineThinkingUsesNativeDefault {
                details.append([L("thinking.mode.label"), L("Default")].joined(separator: ": "))
            } else {
                details.append(thinkingOn ? L("Thinking on") : L("Thinking off"))
            }
        }
        if selectedPickerItem?.isVLM == true {
            details.append(L("Vision"))
        }
        if mediaCapabilities.supportsAudio {
            details.append(L("Audio Input"))
        }
        return details.joined(separator: "\n")
    }

    private var interactiveModelSelectorChip: some View {
        SelectorChip(isActive: showModelPicker, quiet: true) {
            if showModelPicker { dismissModelPicker() }
            else { openModelPicker() }
        } content: {
            if isHarnessAgent {
                harnessChipLabel
            } else {
                builtInModelChipLabel
            }
        }
        .task(id: "\(selectedModel ?? "")|\(hasAgentReasoningOverride)") {
            await refreshReasoningSelectionCapability()
        }
        .accessibilityValue(Text(verbatim: modelSelectorDetails))
        // Chip-wide hover target: the 6px dot alone is too small to hover.
        .modifier(
            ModelWarmupHelp(
                isLocalModelRun: isSelectedModelLocal && !isRemoteAgentRun,
                selectedModel: selectedModel,
                modelDetails: modelSelectorDetails,
                harnessHelp: harnessChipHelp,
                warmupController: warmupController
            )
        )
        .anchoredCard(isPresented: $showModelPicker, size: theme.assignedPickerCardSize(modelPickerCardSize),
                      constrainToWindow: true, accessibilityLabel: L("Model picker")) {
            ChatModelPickerCard(
                // `anchoredCard` builds this content on every body pass, open
                // or not, and grouping + sorting every picker item is the
                // expensive part. A closed card shows nothing, so skip it.
                providers: showModelPicker ? chatPickerProviders : [],
                selectedModel: $selectedModel,
                optionsControl: modelPickerOptionsControl,
                selectedHarnessID: selectedHarnessPickerID,
                harnessOptionsControl: harnessPickerOptionsControl,
                runtimeSwitchLocked: isStreaming,
                onSelectHarness: { selectHarness($0) },
                onExploreLocal: {
                    dismissModelPicker()
                    AppDelegate.shared?.showManagementWindow(initialTab: .models)
                },
                onExploreCloud: {
                    dismissModelPicker()
                    DispatchQueue.main.async { showCloudModelBrowser = true }
                },
                onSizeChange: { modelPickerCardSize = $0 }
            )
        }
        .sheet(isPresented: $showCloudModelBrowser) {
            CloudModelBrowserDialog(
                options: cloudPickerItems,
                selectedModel: $selectedModel,
                onDismiss: { showCloudModelBrowser = false },
                onManageCloud: {
                    showCloudModelBrowser = false
                    AppDelegate.shared?.showManagementWindow(initialTab: .credits)
                }
            )
            .environment(\.theme, theme)
        }
        .onChange(of: showModelPicker) { _, isShowing in
            if isShowing {
                // Snapshot options when popover opens to prevent refresh during streaming
                cachedPickerItems = pickerItems
                // Residency and the saved MTP mode both change outside this
                // view; a stale set would hide the depth row on a capable
                // model, which reads as "this model has no MTP".
                refreshNativeMTPState()
                Task {
                    await RemoteProviderManager.shared.refreshConnectedProviders()
                    await ModelPickerItemCache.shared.buildModelPickerItems()
                    // Refresh external availability through the shared catalog;
                    // retained registrations alone do not make a model ready.
                    _ = await Task.detached(priority: .utility) {
                        ExternalModelLocator.pruneMissing()
                    }.value
                }
            }
        }
        .onChange(of: pickerItems) { _, newItems in
            // mirror upstream changes while open so picker triggered refreshes are visible
            if showModelPicker {
                cachedPickerItems = newItems
            }
        }
    }

    private var builtInModelChipLabel: some View {
        SharedChipContent(spacing: theme.assignedMetric("component.library.23.gap", fallback: theme.space.s4)) {
            Text(selectedPickerItem?.displayName ?? L("Select Model"))
                .composerChipTextStyle(.caption)
                .composerChipInk("foreground", fallback: theme.text.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.up.chevron.down")
                .composerChipTextStyle(.caption, property: "caption")
                .composerChipInk("secondary", fallback: theme.text.tertiary)
        }
        .modifier(CappedHuggingWidth(maxWidth: Self.modelChipMaxLabelWidth))
    }

    /// Past this the model name truncates; below it the chip hugs the name.
    static let modelChipMaxLabelWidth: CGFloat = 200

    private var cloudPickerItems: [ModelPickerItem] {
        pickerItems.filter {
            if case .remote(_, let providerID) = $0.source {
                return providerID == RemoteProviderManager.osaurusRouterProviderId
            }
            return false
        }
    }

    private var chatPickerProviders: [ChatModelPickerProvider] {
        let shortlist = Set(cachedPickerItems.filter {
            chatModelFavorites.isFavorite($0.favoriteKey) || $0.id == selectedModel
        }.map(\.id))
        let current = harnessRuntime.map {
            (runtimeId: $0.id, claudeModel: agentManager.effectiveClaudeCodeConfig(for: effectiveAgentId).resolvedModel)
        }
        return ChatModelPickerProvider.groups(
            from: cachedPickerItems,
            cloudModelIDs: shortlist,
            harnesses: ChatModelPickerProvider.harnessProviders(runtimes: pickerHarnessRuntimes, current: current)
        )
    }

    /// Inline "Model Options" section for the model popover: the semantic
    /// Thinking row (when the model has a thinking toggle) plus every other
    /// option the selected model exposes (catalog-driven effort, static
    /// profile segments, toggles). Selecting persists an explicit value;
    /// resetting removes it so the default shows while the backend applies
    /// it naturally (nothing is sent on the wire).
    private var modelPickerOptionsControl: ModelPickerOptionsControl? {
        guard let model = selectedModel else { return nil }
        let capabilities = inlineEffortCapabilities
        let thinkingId = ModelProfileRegistry.profile(for: model)?.thinkingOption?.id
        // The dedicated Thinking row owns the thinking option (semantic
        // on/off, never the raw inverted bool); the generic rows render
        // everything else.
        var options = activeProfileOptions.filter { $0.id != thinkingId }
        // Beside Reasoning Effort, for models that actually have a head.
        if let mtpOption = nativeMTPOption(for: model) {
            options.append(mtpOption)
        }
        let thinking = modelPickerThinkingControl(for: model)
        guard !options.isEmpty || thinking != nil || reasoningSelectionNeedsChoice else { return nil }

        // Display-only defaults: the catalog default for capability-enriched
        // effort, otherwise the static profile's defaults.
        let defaults: [String: ModelOptionValue]
        if let capabilities {
            if let defaultLevel = capabilities.defaultLevelId {
                defaults = ["reasoningEffort": .string(defaultLevel)]
            } else {
                defaults = [:]
            }
        } else {
            defaults = ModelProfileRegistry.defaults(for: model)
        }

        // Agent overrides win over the inherited Server mode, just as on dispatch.
        // Neither source belongs in the per-model option store.
        var values = ModelProfileRegistry.normalizedOptions(for: model, persisted: effectiveReasoningOptions)
        var displayDefaults = defaults
        if options.contains(where: { $0.id == Self.nativeMTPOptionID }) {
            let identity = Self.mtpIdentity(model)
            let mode = ServerController.runtimeSettingsForConfigureTool().settings.mtp.mode
            let familyDefault = nativeMTPFamilyDefaultOnModels.contains(identity) ? "auto" : "off"
            let inherited = mode == .familyDefault ? familyDefault : nativeMTPSelection
            let shown = agentManager.effectiveGenerationSettings(for: effectiveAgentId)?
                .speculativeDecoding.map { $0 ? "auto" : "off" } ?? inherited
            values[Self.nativeMTPOptionID] = .string(
                nativeMTPManuallyBlockedModels.contains(identity) ? "off" : shown
            )
            // Reset removes an agent override; otherwise it restores the bundle policy.
            let hasAgentOverride = agentManager.effectiveGenerationSettings(for: effectiveAgentId)?
                .speculativeDecoding != nil
            displayDefaults[Self.nativeMTPOptionID] = .string(hasAgentOverride ? inherited : familyDefault)
        }

        return ModelPickerOptionsControl(
            capabilities: capabilities,
            thinking: thinking,
            options: options,
            values: values,
            defaults: displayDefaults,
            onChange: { optionId, newValue in
                // Existing agent overrides stay agent-scoped; inheritance retains the Server path.
                // Neither is persisted to ModelOptionsStore.
                if optionId == Self.nativeMTPOptionID {
                    DispatchQueue.main.async {
                        applyNativeMTPSegment(newValue?.stringValue)
                    }
                    return
                }
                // Deferred write for the same reason as the Thinking row's
                // saved options: the popover's anchor (the model chip)
                // renders the effort label from `activeModelOptions`, and
                // resizing the anchor during the popover's own update
                // crashes NSPopover.
                DispatchQueue.main.async {
                    guard selectedModel == model else { return }
                    if optionId == "reasoningEffort", hasAgentReasoningOverride {
                        agentManager.updateReasoning(
                            enableThinking: nil, effort: newValue?.stringValue, for: effectiveAgentId)
                        return
                    }
                    var updated = activeModelOptions
                    if optionId == "reasoningEffort" {
                        updated.removeValue(forKey: "disableThinking")
                    }
                    if let newValue {
                        updated[optionId] = newValue
                    } else {
                        updated.removeValue(forKey: optionId)
                    }
                    activeModelOptions = updated
                    if let model = selectedModel {
                        ModelOptionsStore.shared.saveOptions(updated, for: model)
                    }
                }
            },
            reasoningValidationMessage: reasoningSelectionMessage
        )
    }

    // MARK: - Thinking Control (model picker)

    /// Semantic Thinking control for the picker's Model Options section.
    /// Shows the effective state (explicit persisted choice, else the
    /// model's chat-template default so the row never lies for default-on
    /// models) and writes the profile-specific stored value through
    /// `ModelProfileRegistry.thinkingStoredOption`, so inverted options like
    /// `disableThinking` cannot flip the wrong way. Hidden in Mode 2
    /// remote-agent runs: the remote agent owns its generation config
    /// server-side, so a local toggle wouldn't reach it.
    private func modelPickerThinkingControl(for model: String) -> ModelPickerThinkingControl? {
        guard !isRemoteAgentRun,
            let option = ModelProfileRegistry.profile(for: model)?.thinkingOption,
            activeProfileOptions.contains(where: { $0.id == option.id }),
            thinkingPresentationIsReady(for: model)
        else { return nil }
        let explicitEnabled = ModelProfileRegistry.thinkingEnabled(
            for: model,
            values: effectiveReasoningOptions
        )
        return ModelPickerThinkingControl(
            isEnabled: effectiveThinkingEnabled(for: model),
            isExplicit: explicitEnabled != nil || reasoningSelectionNeedsChoice,
            onSetEnabled: { enabled in
                // Deferred write for the same reason as the generic option
                // rows: the popover's anchor (the model chip) renders the
                // thinking suffix from `activeModelOptions`, and resizing the
                // anchor during the popover's own update crashes NSPopover.
                DispatchQueue.main.async {
                    persistThinkingOverride(enabled, for: model)
                }
            },
            supportsUnspecifiedDefault: LocalReasoningCapability.capability(forModelId: model).preservesOmittedThinking,
            selectionIsValid: !reasoningSelectionNeedsChoice
        )
    }

    /// Single semantic-to-stored write path shared by the footer button and
    /// the picker row. Inverted profiles such as `disableThinking` must never
    /// toggle their raw persisted boolean directly.
    private func persistThinkingOverride(_ enabled: Bool?, for model: String) {
        guard selectedModel == model else { return }
        if hasAgentReasoningOverride {
            agentManager.updateReasoning(enableThinking: enabled, effort: nil, for: effectiveAgentId)
            return
        }
        guard let thinkingOpt = ModelProfileRegistry.profile(for: model)?.thinkingOption else {
            return
        }
        var updated = activeModelOptions
        if let enabled,
            let stored = ModelProfileRegistry.thinkingStoredOption(
                for: model,
                enabled: enabled
            )
        {
            updated[stored.id] = stored.value
        } else {
            // Reset: remove the override so the model's template default
            // applies naturally (nothing on the wire).
            updated.removeValue(forKey: thinkingOpt.id)
        }
        activeModelOptions = updated
        ModelOptionsStore.shared.saveOptions(updated, for: model)
    }

    // MARK: - Thinking Toggle

    // MARK: - Auto-Speak Toggle

    @ViewBuilder
    private func autoSpeakToggleChip(compact: Bool) -> some View {
        SelectorChip(isActive: autoSpeakAssistant) {
            withAnimation(theme.motion.springAnimation) {
                autoSpeakAssistant.toggle()
            }
        } content: {
            SharedChipContent(spacing: theme.assignedMetric("component.library.23.gap", fallback: theme.space.s4)) {
                Image(systemName: autoSpeakAssistant ? "checkmark.square.fill" : "square")
                    .glyphSize(.footnote, weight: .semibold)
                    .composerChipInk(autoSpeakAssistant ? "foreground" : "secondary", fallback: autoSpeakAssistant ? theme.text.primary : theme.text.tertiary)
                    .contentTransition(.symbolEffect(.replace))

                if !compact {
                    Text("Auto-speak", bundle: .module)
                        .composerChipTextStyle(.caption, weight: 500)
                        .composerChipInk(autoSpeakAssistant ? "foreground" : "secondary", fallback: autoSpeakAssistant ? theme.text.secondary : theme.text.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .localizedHelp("Auto-speak every reply in this chat")
    }

    // MARK: - Sandbox Toggle Chip

    private var effectiveAgentId: UUID {
        agentId ?? Agent.defaultId
    }

    /// The built-in Default ("Osaurus") agent is the Orchestrator: it
    /// configures Osaurus and delegates work. It never uses the sandbox, so
    /// the sandbox chip is hidden; it shows a quiet "Orchestrator" indicator
    /// until a working folder is attached (read-only for itself, inherited
    /// by folder-less subagents).
    private var isDefaultConfigAgent: Bool {
        effectiveAgentId == Agent.defaultId
    }

    /// Default agent runs Osaurus configuration, which needs the configure
    /// tool schema. The same resolver the composer uses to strip tools
    /// (`.tiny` window) decides whether configuration can run at all — so
    /// when the selected model's window is too small (e.g. Foundation at
    /// 4K), configuration genuinely can't run and the send is blocked.
    private var configContextTooSmall: Bool {
        guard isDefaultConfigAgent, !isRemoteAgentRun, let model = selectedModel else { return false }
        return ContextSizeResolver.resolve(modelId: model).sizeClass.disablesTools
    }

    private var isSandboxAvailable: Bool {
        sandboxState.availability.isAvailable
    }

    private var isSandboxEnabled: Bool {
        agentManager.effectiveAutonomousExec(for: effectiveAgentId)?.enabled == true
    }

    private var isSandboxLoading: Bool {
        isSandboxEnabled && (sandboxState.status == .starting || sandboxState.isProvisioning)
    }

    /// Active step's progress (0–100) when it reports a real fraction (cold-path
    /// download / unpack); `nil` for indeterminate phases, where the chip
    /// shows a bare spinner.
    private var sandboxProgressPercent: Int? {
        guard isSandboxLoading, let progress = sandboxState.provisioningProgress else { return nil }
        return Int((progress * 100).rounded())
    }

    private var sandboxChipLabel: LocalizedStringKey {
        if isSandboxLeaseBlocked { return "Sandbox unavailable" }
        guard isSandboxLoading, let step = sandboxState.journey?.currentStepID else { return "Sandbox" }
        switch step {
        case .downloadKernel, .downloadInitFS: return "Downloading runtime…"
        case .createContainer: return "Setting up sandbox…"
        default: return "Sandbox"
        }
    }

    private var isSandboxRunning: Bool {
        sandboxState.status.isRunning
    }

    /// Visible failure for the active agent, surfaced by the registrar via
    /// `SandboxManager.State.shared.activeAgentUnavailability`. When set we
    /// paint the chip red and put the reason in the tooltip so the user
    /// has an in-app signal that something went wrong (instead of finding
    /// out only via the model paraphrasing the system-prompt notice).
    private var sandboxFailure: SandboxToolRegistrar.UnavailabilityReason? {
        sandboxState.activeAgentUnavailability
    }

    private var isSandboxFailed: Bool {
        isSandboxEnabled && sandboxFailure != nil
    }

    /// The composer has no sandbox chip; it appears only while another
    /// Osaurus app holds the VM, since only the user can free it. The lease
    /// is per user, so every sandbox chat is blocked, not just the agent the
    /// registrar last published for.
    private var isSandboxLeaseBlocked: Bool {
        !isRemoteAgentRun && !isDefaultConfigAgent && isSandboxEnabled && sandboxFailure?.leaseOwner != nil
    }

    /// True when the sandbox is on but outbound network is turned off for
    /// this agent (its own `sandboxNetworkEnabled`, which the egress proxy
    /// enforces per agent). Surfaced on the chip so a network-less sandbox
    /// is visible up front, instead of the model discovering it only when a
    /// `curl`/`urllib` call fails mid-task.
    private var isSandboxNetworkDisabled: Bool {
        isSandboxEnabled
            && agentManager.effectiveAutonomousExec(for: effectiveAgentId)?
                .sandboxNetworkEnabled == false
    }

    private func retrySandbox() {
        let agentId = effectiveAgentId
        Task {
            SandboxToolRegistrar.shared.resetStartupFailures()
            await SandboxToolRegistrar.shared.registerTools(for: agentId)
        }
    }

    /// Primary tap on the sandbox chip. Off: turn it on. A lease conflict:
    /// the resolver, since only the user can quit the other app. Otherwise
    /// the status popover, so a click never silently turns the sandbox off.
    private func handleSandboxChipTap() {
        guard isSandboxEnabled else {
            toggleSandbox()
            return
        }
        if let owner = sandboxFailure?.leaseOwner {
            SandboxLeaseConflictResolver.present(owner, agentId: effectiveAgentId)
            return
        }
        showSandboxPopover = true
    }

    private func toggleSandbox() {
        let currentConfig = agentManager.effectiveAutonomousExec(for: effectiveAgentId)
        var newConfig = currentConfig ?? .default
        newConfig.enabled.toggle()
        let agentId = effectiveAgentId
        let manager = agentManager
        Task {
            do {
                try await manager.updateAutonomousExec(newConfig, for: agentId)
                // Do not leave two selected-looking execution contexts in the
                // composer. The onChange above applies the same invariant to
                // every other visible chat using this agent.
                if newConfig.enabled {
                    folderState.clearFolder()
                }
            } catch {
                // Don't silently swallow provision failures — log loudly and
                // roll the persisted toggle back so the chip flips back to
                // its previous state. The failure reason still flows to the
                // model via SandboxToolRegistrar's unavailability notice.
                debugLog(
                    "[Sandbox] Toggle failed for agent \(agentId): \(error.localizedDescription)"
                )
                _ = ToastManager.shared.error(
                    newConfig.enabled ? L("Couldn't turn on the sandbox") : L("Couldn't turn off the sandbox"),
                    message: error.localizedDescription
                )
                var rollback = newConfig
                rollback.enabled.toggle()
                try? await manager.updateAutonomousExec(rollback, for: agentId)
            }
        }
    }

    /// Selecting a trusted folder makes native execution authoritative and
    /// disables the VM for this agent. The folder picker is presented as a
    /// sheet on this chat's window so ownership remains unambiguous.
    private func selectFolder() {
        // Defensive: the menu row is disabled for remote runs, but no folder
        // context can reach a host-executed agent, so never open the picker.
        guard !isRemoteAgentRun else { return }
        confirmingHarnessFolderChange { performSelectFolder() }
    }

    private func performSelectFolder() {
        let window = windowId.flatMap { ChatWindowManager.shared.getNSWindow(id: $0) }
        let agentId = effectiveAgentId
        let manager = agentManager
        let usesSandbox = !isHarnessAgent
        Task {
            guard await folderState.selectFolder(from: window) != nil else { return }
            do {
                if usesSandbox { try await manager.disableSandboxForHostFolder(agentId: agentId) }
                // Sticky: the chip is the source of truth for the agent's
                // working folder, so a successful pick is remembered on the
                // agent and seeds every fresh chat / folder-less dispatch.
                persistWorkingFolderToAgent()
            } catch {
                // Fail closed: do not leave a UI state that appears trusted
                // while the VM boundary is still authoritative — and do not
                // leave the agent remembering a folder its chats can't use.
                folderState.clearFolder()
                forgetAgentWorkingFolder()
                debugLog(
                    "[Workspace] Could not disable sandbox after folder selection: "
                        + error.localizedDescription
                )
            }
        }
    }

    /// Recent folders listed under the + menu's rows. `dismiss` closes
    /// the menu before the pick runs, like any row.
    private func recentFoldersList(dismiss: @escaping () -> Void) -> AnyView {
        AnyView(
            RecentFoldersList(
                // Stored string, not a URL: standardizing a file URL can stat
                // the path, and this runs on the main actor during body.
                activePath: folderState.lastKnownPath,
                onPick: { entry in
                    dismiss()
                    applyRecentFolder(entry)
                }
            )
        )
    }

    /// Attach a remembered folder to this chat. Resolves the entry (bookmark
    /// first, plain path second) off the main actor, then runs the exact
    /// post-pick steps `selectFolder` does so the sandbox and the agent's
    /// sticky folder stay consistent with a panel pick. A folder that no
    /// longer resolves is dropped from the list and reported.
    private func applyRecentFolder(_ entry: RecentFoldersStore.Entry) {
        guard !isRemoteAgentRun else { return }
        confirmingHarnessFolderChange { performApplyRecentFolder(entry) }
    }

    private func performApplyRecentFolder(_ entry: RecentFoldersStore.Entry) {
        let agentId = effectiveAgentId
        let manager = agentManager
        let usesSandbox = !isHarnessAgent
        Task {
            guard let url = await RecentFoldersStore.resolveURL(for: entry) else {
                recentFolders.remove(path: entry.path)
                ToastManager.shared.error(
                    L("Folder no longer available"),
                    message: entry.path
                )
                return
            }
            guard await folderState.setFolder(url) != nil else {
                ToastManager.shared.error(L("Failed to grant folder access"))
                return
            }
            do {
                if usesSandbox { try await manager.disableSandboxForHostFolder(agentId: agentId) }
                persistWorkingFolderToAgent()
            } catch {
                folderState.clearFolder()
                forgetAgentWorkingFolder()
                debugLog(
                    "[Workspace] Could not disable sandbox after recent folder pick: "
                        + error.localizedDescription
                )
            }
        }
    }

    /// Whether this composer's folder picks/clears should write through to
    /// the agent's sticky working folder (the Orchestrator's lands in
    /// `DefaultAgentConfiguration`). False for a remote teammate run (the
    /// folder belongs to the remote host's agent, not the local hosting
    /// agent — same rule `ChatSession` applies to model pins).
    private var persistsWorkingFolderToAgent: Bool {
        !isRemoteAgentRun
    }

    /// Write the chip's current folder onto the agent.
    private func persistWorkingFolderToAgent() {
        guard persistsWorkingFolderToAgent else { return }
        agentManager.updateWorkingFolder(
            for: effectiveAgentId,
            bookmark: folderState.persistedBookmark,
            path: folderState.persistedPath
        )
    }

    /// Forget the agent's working folder (chip Clear).
    private func forgetAgentWorkingFolder() {
        guard persistsWorkingFolderToAgent else { return }
        agentManager.clearWorkingFolder(for: effectiveAgentId)
    }

    /// Chip Clear: clear this chat's folder AND stop seeding new chats and
    /// dispatches with it. Only the user's explicit Clear reaches here —
    /// sandbox-on invariants and restores call `folderState.clearFolder()`
    /// directly and leave the agent's remembered folder alone.
    private func clearFolderFromChip() {
        confirmingHarnessFolderChange {
            folderState.clearFolder()
            forgetAgentWorkingFolder()
        }
    }

    // MARK: - Harness Folder Rules

    /// The harness this composer's agent runs on, when it resolves.
    private var harnessRuntime: HarnessRuntime? {
        _ = harnessConfigRevision
        guard !isRemoteAgentRun, case .resolved(let runtime)? = agentManager.effectiveHarness(for: effectiveAgentId)
        else { return nil }
        return runtime
    }

    private var isHarnessAgent: Bool {
        _ = harnessConfigRevision
        return !isRemoteAgentRun && agentManager.effectiveHarness(for: effectiveAgentId) != nil
    }

    /// A harness's working directory is fixed when its process starts, and a
    /// running turn is never interrupted to move it.
    private var folderLockedByHarnessTurn: Bool {
        isHarnessAgent && isStreaming
    }

    /// Run a folder change, first confirming it when the harness would
    /// restart without its earlier context.
    private func confirmingHarnessFolderChange(_ change: @escaping () -> Void) {
        guard !folderLockedByHarnessTurn else { return }
        if let runtime = harnessRuntime, !runtime.resumesSessions, !isEmptyChat {
            pendingHarnessFolderChange = change
            showHarnessFolderWarning = true
        } else {
            change()
        }
    }

    /// Folder chip tooltip makes the active execution boundary explicit.
    private func folderChipHelp(hasFolder: Bool) -> Text {
        // Lead with the full path when a folder is active — the chip label
        // middle-truncates long names, so the tooltip is where the complete
        // name stays readable.
        if hasFolder {
            if let rootPath = folderState.rootPath {
                return Text(verbatim: rootPath.path) + Text(verbatim: "\n")
                    + Text(localized: "Change working folder")
            }
            return Text(localized: "Change working folder")
        }
        return Text(localized: "Select a working folder")
    }

    private var sandboxHelpText: String {
        let base: String
        if isSandboxLeaseBlocked, let owner = sandboxFailure?.leaseOwner {
            return SandboxLeaseConflictResolver.explanation(for: owner) + "\n" + L("Click to fix.")
        } else if let failure = sandboxFailure, isSandboxEnabled {
            return "Sandbox unavailable: \(failure.message)\nClick for details."
        } else if isSandboxLoading {
            // Name the live phase (e.g. "Downloading initfs…") when available.
            if let phase = sandboxState.provisioningPhase, !phase.isEmpty {
                return "\(phase) — click to view progress."
            }
            return "Sandbox is starting up — click to view progress."
        } else if isSandboxEnabled && isSandboxRunning {
            base = "Sandbox is on — click for status and options."
        } else if isSandboxEnabled {
            base = "Sandbox is on — it starts when this agent runs a command."
        } else {
            base = "Enable Sandbox for autonomous code execution"
        }
        // Spell out the egress restriction so the user understands the
        // wifi.slash badge — and why the model can't fetch URLs.
        if isSandboxNetworkDisabled {
            return base + "\nNetwork is off for this agent — change it in the agent's Sandbox settings."
        }
        return base
    }

    /// Foreground tint for the chip's icon + dot. Failure beats running so a
    /// briefly-flapping container that came up but failed to provision still
    /// reads as red.
    private var sandboxChipAccent: Color {
        sandboxChipStatus?.foreground ?? theme.text.tertiary
    }

    /// Status tone for the chip's current state; nil when idle.
    private var sandboxChipStatus: ThemeStatusSet<Color>? {
        if isSandboxFailed { return theme.status.error }
        if isSandboxLoading { return theme.status.warning }
        if isSandboxEnabled && isSandboxRunning { return theme.status.success }
        return nil
    }

    private func sandboxToggleChip(compact: Bool) -> some View {
        // HoverScope owns the hover flag (and the pulse modifier owns the
        // loading pulse), so hover-in/out and pulse ticks re-render only this
        // chip's subtree — not the whole card body.
        HoverScope { isSandboxHovered in
            Button(action: handleSandboxChipTap) {
                SharedChipContent(spacing: theme.space.s4) {
                    if isSandboxFailed {
                        Image(systemName: "exclamationmark.circle.fill")
                            .glyphSize(.tiny, weight: .bold)
                            .foregroundColor(theme.status.error.foreground)
                    } else if isSandboxLoading {
                        SettingsSpinner(size: .mini, tint: theme.status.warning.foreground)
                    } else if isSandboxEnabled && isSandboxRunning {
                        Circle()
                            .fill(theme.status.success.foreground)
                            .frame(width: 6, height: 6)
                    }

                    Image(systemName: isSandboxEnabled ? "shippingbox.fill" : "shippingbox")
                        .glyphSize(.micro, weight: .medium)
                        .foregroundColor(sandboxChipAccent)

                    // Keep the label whenever it's carrying live status the icon
                    // alone can't convey ("Downloading runtime…", a failure), even
                    // in the compact row; otherwise collapse to the box icon.
                    if !compact || isSandboxLoading || isSandboxFailed {
                        Text(sandboxChipLabel, bundle: .module)
                            .textStyle(.caption, weight: 500)
                            .foregroundColor(
                                isSandboxFailed
                                    ? theme.status.error.foreground
                                    : (isSandboxEnabled
                                        ? (isSandboxRunning ? theme.text.primary : theme.text.secondary)
                                        : theme.text.tertiary)
                            )
                            .lineLimit(1)
                            .fixedSize()
                            .modifier(PulsingOpacity(active: isSandboxLoading))
                    }

                    // Inline cold-path download/unpack progress.
                    if let pct = sandboxProgressPercent {
                        Text(verbatim: "\(pct)%")
                            .textStyle(.caption, weight: 500)
                            .foregroundColor(theme.text.secondary)
                            .monospacedDigit()
                    }

                    // Network-off badge: only meaningful once the sandbox is
                    // settled, so suppress it while loading or failed (those
                    // states own the leading indicator + accent color).
                    if isSandboxNetworkDisabled && !isSandboxLoading && !isSandboxFailed {
                        Image(systemName: "wifi.slash")
                            .glyphSize(.tiny, weight: .semibold)
                            .foregroundColor(theme.status.warning.foreground)
                            .accessibilityLabel(Text("Outbound network disabled", bundle: .module))
                    }
                }
                .padding(.horizontal, theme.space.s8)
                .padding(.vertical, theme.space.s4)
                .background(sandboxChipBackground(isSandboxHovered: isSandboxHovered))
                .clipShape(Capsule())
                .overlay(sandboxChipBorder(isSandboxHovered: isSandboxHovered))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            // Intentionally NOT `.disabled(isSandboxLoading)` — the chip
            // stays tappable during provisioning so the user can click
            // through to the Sandbox settings tab and watch the journey
            // unfold. Toggling on/off is intercepted by
            // `handleSandboxChipTap` in that state.
            .help(sandboxHelpText)
            .popover(isPresented: $showSandboxPopover, arrowEdge: .top) {
                SandboxChipPopover(
                    agentId: effectiveAgentId,
                    failure: isSandboxEnabled ? sandboxFailure : nil,
                    onRetry: {
                        showSandboxPopover = false
                        retrySandbox()
                    },
                    onTurnOff: {
                        showSandboxPopover = false
                        if isSandboxEnabled { toggleSandbox() }
                    },
                    onOpenSettings: {
                        showSandboxPopover = false
                        AppDelegate.shared?.showManagementWindow(initialTab: .sandbox)
                    }
                )
                .environment(\.theme, theme)
            }
            .assignedContextMenu {
                if isSandboxFailed {
                    Button {
                        retrySandbox()
                    } label: {
                        Text("Retry Sandbox", bundle: .module)
                    }
                }
                Button {
                    AppDelegate.shared?.showManagementWindow(initialTab: .sandbox)
                } label: {
                    Text("Open Sandbox Settings", bundle: .module)
                }
            }
        }
    }

    private func sandboxChipBackground(isSandboxHovered: Bool) -> some View {
        Capsule().fill(sandboxChipStatus?.background ?? (isSandboxHovered ? theme.surface.hover : theme.surface.subtle))
    }

    private func sandboxChipBorder(isSandboxHovered: Bool) -> some View {
        Capsule().strokeBorder(
            sandboxChipStatus?.border ?? (isSandboxHovered ? theme.border.default : theme.border.subtle),
            lineWidth: theme.stroke.default
        )
    }

    // MARK: - Clipboard Chip

    /// SF Symbol representing the kind of content currently on the clipboard.
    /// The chip pairs this icon with a leading "Paste" label and the source app.
    private var clipboardChipIcon: String {
        guard let content = clipboardService.currentContent else {
            return "paperclip"
        }
        switch content {
        case .text:
            return "text.quote"
        case .image:
            return "photo"
        case .file(let url):
            let kind = Attachment.Kind.document(filename: url.lastPathComponent, content: "", fileSize: 0)
            return Attachment(kind: kind).fileIcon
        }
    }

    @ViewBuilder
    private func clipboardChipLabel(compact: Bool) -> some View {
        SharedChipContent(spacing: theme.assignedMetric("component.library.23.gap", fallback: theme.space.s4)) {
            Image(systemName: clipboardChipIcon)
                .glyphSize(.micro, weight: .medium)
                .composerChipInk("accent", fallback: theme.status.info.foreground)

            // Collapsed, the chip is just its icon (hover names it) so it can't
            // be clipped mid-word in the narrow scroll region. Expanded, lead
            // with the action word so it reads as "Paste" like its row-mates
            // ("Sandbox", "Folder"), with the source app as a quiet suffix.
            if !compact {
                Text("Paste", bundle: .module)
                    .composerChipTextStyle(.caption, weight: 700)
                    .composerChipInk("accent", fallback: theme.status.info.foreground)
                    .lineLimit(1)
                    .fixedSize()

                if let source = clipboardService.lastSourceApp {
                    Text(source)
                        .composerChipTextStyle(.caption, weight: 500)
                        .composerChipInk("secondary", fallback: theme.text.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Image(systemName: "chevron.right")
                    .glyphSize(.tiny, weight: .bold)
                    .composerChipInk("secondary", fallback: theme.text.tertiary)
                    .padding(.leading, theme.space.s2)
            }
        }
    }

    private func clipboardToggleChip(compact: Bool) -> some View {
        // HoverScope owns the hover flag and ClipboardPulseSweep owns the
        // arrival-pulse animation state, so neither re-renders the card body.
        HoverScope { isClipboardHovered in
            Button(action: attachClipboardSnippet) {
                clipboardChipLabel(compact: compact)
                    .composerChipSurface()
                    .modifier(
                        ClipboardPulseSweep(
                            hovered: isClipboardHovered,
                            trigger: clipboardService.hasNewContent
                        )
                    )
            }
            .composerChipButtonStyle()
            .composerChipFocus()
            .pointingHandCursor()
            .help(Text(localized: "Attach snippet from \(clipboardService.lastSourceApp ?? "clipboard")"))
            .assignedContextMenu {
                Button {
                    clipboardService.markAsRead()
                } label: {
                    Text("Dismiss", bundle: .module)
                }
                Divider()
                if let content = clipboardService.currentContent {
                    switch content {
                    case .text(let text):
                        Button {
                            if collapseLongPastes, text.utf8.count >= Self.pastedContentThreshold {
                                withAnimation(theme.motion.springAnimation) {
                                    pendingAttachments.append(.pastedContent(text))
                                }
                            } else {
                                localText += text
                            }
                            clipboardService.markAsRead()
                        } label: {
                            Text("Paste to Input", bundle: .module)
                        }
                    case .file:
                        Button {
                            attachClipboardSnippet()
                        } label: {
                            Text("Attach File", bundle: .module)
                        }
                    case .image:
                        Button {
                            attachClipboardSnippet()
                        } label: {
                            Text("Attach Image", bundle: .module)
                        }
                    }
                }
            }
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        }
    }

    private func attachClipboardSnippet() {
        guard let content = clipboardService.currentContent else { return }

        switch content {
        case .text(let text):
            if collapseLongPastes, text.utf8.count >= Self.pastedContentThreshold {
                // Large paste → convert to a "pasted content" attachment.
                // Lets the user view / remove the snippet without polluting
                // the input field with hundreds of lines of text.
                withAnimation(theme.motion.springAnimation) {
                    pendingAttachments.append(.pastedContent(text))
                    clipboardService.markAsRead()
                    isFocused = true
                }
            } else {
                // Inject directly into the text input area for better UX (editing)
                withAnimation(theme.motion.springAnimation) {
                    if localText.isEmpty {
                        localText = text
                    } else {
                        if !localText.hasSuffix("\n") {
                            localText += "\n"
                        }
                        localText += text
                    }
                    clipboardService.markAsRead()
                    isFocused = true
                }
            }

        case .image(let data):
            withAnimation(theme.motion.springAnimation) {
                pendingAttachments.append(.image(data))
                clipboardService.markAsRead()
            }

        case .file(let url):
            if DocumentParser.isImageFile(url: url) {
                let animation = theme.motion.springAnimation
                Task { @MainActor in
                    // The image decode and PNG re-encode block for seconds
                    // on a large file, so they run off the main actor.
                    let pngData = await Task.detached(priority: .userInitiated) {
                        () -> Data? in
                        guard let data = try? Data(contentsOf: url),
                            let nsImage = NSImage(data: data)
                        else { return nil }
                        return nsImage.pngData()
                    }.value
                    guard let pngData else { return }
                    withAnimation(animation) {
                        pendingAttachments.append(.image(pngData))
                        clipboardService.markAsRead()
                    }
                }
            } else if DocumentParser.canParse(url: url) {
                let animation = theme.motion.springAnimation
                Task.detached(priority: .userInitiated) {
                    do {
                        let attachments = try DocumentParser.parseAll(url: url)
                        await MainActor.run {
                            withAnimation(animation) {
                                self.pendingAttachments.append(contentsOf: attachments)
                                self.clipboardService.markAsRead()
                            }
                        }
                    } catch {
                        _ = await MainActor.run {
                            ToastManager.shared.error(L("Could not attach file"), message: error.localizedDescription)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Orchestrator Indicator Chip

    /// Quiet pill shown for the built-in Orchestrator ("Osaurus") agent in
    /// place of the sandbox/folder chips. It signals that this agent's job
    /// is to configure Osaurus and delegate work — it doesn't execute code
    /// in a sandbox or work against a host folder — so those controls are
    /// absent by design rather than missing. Clicking it opens Settings →
    /// Orchestrator, where its identity and delegation helpers live.
    private func configurationOnlyChip(compact: Bool) -> some View {
        Button {
            AppDelegate.shared?.showManagementWindow(initialTab: .orchestrator)
        } label: {
            SharedChipContent(spacing: theme.assignedMetric("component.library.23.gap", fallback: theme.space.s4)) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .glyphSize(.micro, weight: .semibold)
                    .composerChipInk("accent", fallback: theme.status.info.foreground)

                if !compact {
                    Text("Orchestrator", bundle: .module)
                        .composerChipTextStyle(.caption, weight: 500)
                        .composerChipInk("secondary", fallback: theme.text.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .composerChipSurface(selected: true)
        }
        .composerChipButtonStyle()
        .composerChipFocus()
        .help(
            Text(
                "The Orchestrator configures Osaurus and delegates work to your agents. It doesn't use the sandbox or a working folder. Click to open its settings.",
                bundle: .module
            )
        )
        .accessibilityLabel(Text("Orchestrator", bundle: .module))
    }

    /// Cheap, card-level half of the screen-context gate: opt-in on, empty
    /// chat, not Mode 2. The observed half (Accessibility granted, a known
    /// frontmost app) lives inside `ScreenContextIndicator` so app switches
    /// and the 2s permission refresh don't re-evaluate the whole card body.
    private var screenContextMayShow: Bool {
        // Mode 2 never injects local screen context (the remote agent runs its
        // own context server-side), so don't promise a snapshot we won't send.
        !isRemoteAgentRun
            && agentManager.effectiveCapabilities(for: effectiveAgentId).screenContextEnabled
            && isEmptyChat
    }

    /// Read-only indicator of the app the frozen screen-context snapshot will be
    /// about (the app focused just before Osaurus). Rendered as a quiet,
    /// right-aligned status line above the context-token count — just a
    /// viewfinder glyph plus the app name, in muted text — so it pairs with the
    /// budget readout rather than reading as a control.
    ///
    /// Owns the `FrontmostAppTracker` / `SystemPermissionService` observation
    /// and self-gates (renders nothing until Accessibility is granted and a
    /// non-self app has been seen), so those publishes re-render only this row.
    private struct ScreenContextIndicator: View {
        @Environment(\.theme) private var theme
        @ObservedObject private var frontmostApp = FrontmostAppTracker.shared
        @ObservedObject private var permissionService = SystemPermissionService.shared

        var body: some View {
            let granted = permissionService.permissionStates[.accessibility] ?? false
            if granted, let app = frontmostApp.lastNonSelfAppName {
                HStack(spacing: theme.catalogLayoutMetric("component.library.23.elements.layout.screenContextIndicator.body.horizontalGap", inheriting: theme.assignedMetric("component.library.23.gap", fallback: theme.space.s4))) {
                    Image(systemName: "viewfinder")
                        .symbolRenderingMode(.hierarchical)
                        .glyphSize(.footnote, weight: .medium)
                        .composerChipInk("secondary", fallback: theme.text.secondary)

                    Text(app)
                        .composerChipTextStyle(.footnote, weight: 500)
                        .composerChipInk("secondary", fallback: theme.text.tertiary)
                        .lineLimit(1)
                }.catalogLayoutTarget("component.library.23.elements.layout.screenContextIndicator.body.horizontalGap")
                .help(
                    Text(
                        "A read-only snapshot of \(app) is shared with this chat when you send. Manage it in Computer Use settings.",
                        bundle: .module
                    )
                )
                .accessibilityLabel(Text("Screen context from \(app)", bundle: .module))
            }
        }
    }

    /// Floating wrapper for `configContextErrorBanner`: keeps the toast out of
    /// the layout flow (so it never shifts the card) and lifts it fully above
    /// the card's top edge with a small gap, hung from a zero-height line at
    /// that edge.
    @ViewBuilder
    private var configContextErrorOverlay: some View {
        if configContextTooSmall {
            Color.clear
                .frame(height: 0)
                .overlay(alignment: .bottom) {
                    configContextErrorBanner
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, theme.space.s10)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    /// Fixed banner width so a short model name (e.g. "gpt-5.5") never shrinks
    /// the banner into a cramped container.
    private static let ramBannerWidth: CGFloat = 320

    // MARK: - Model-Switch Continuity Banner

    @ViewBuilder
    private var modelSwitchContinuityRow: some View {
        if let warning = modelSwitchContinuityWarning {
            let previous =
                pickerItems.first { $0.id == warning.previousModelId }?.displayName
                ?? warning.previousModelId
            let next =
                pickerItems.first { $0.id == warning.newModelId }?.displayName
                ?? warning.newModelId
            modelSwitchContinuityBanner(
                previousModelId: warning.previousModelId,
                previous: previous,
                next: next,
                pointerCenterX: 28
            )
                .frame(width: Self.ramBannerWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, theme.space.s20)
                .padding(.top, theme.space.s8)
                .padding(.bottom, -16)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func modelSwitchContinuityBanner(
        previousModelId: String,
        previous: String,
        next: String,
        pointerCenterX: CGFloat
    ) -> some View {
        let tint = theme.status.warning.foreground
        let clampedX = min(
            max(pointerCenterX, 14 + RAMBannerShape.pointerWidth / 2),
            Self.ramBannerWidth - 14 - RAMBannerShape.pointerWidth / 2
        )
        let shape = RAMBannerShape(pointerCenterX: clampedX)

        return VStack(alignment: .leading, spacing: theme.space.s10) {
            (Text(Image(systemName: "arrow.triangle.2.circlepath"))
                .foregroundColor(tint)
                + Text(verbatim: "  ")
                + Text(
                    "You switched from \(previous) to \(next) in this conversation.",
                    bundle: .module
                ).foregroundColor(theme.text.primary))
                .textStyle(.caption, weight: 500)
                .fixedSize(horizontal: false, vertical: true)
            Text(
                "Cached context from the previous model cannot be reused, and the new model may interpret earlier turns differently. Start a new chat for the most consistent results.",
                bundle: .module
            )
            .foregroundColor(theme.text.secondary)
            .textStyle(.caption, weight: 500)
            .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: theme.space.s10) {
                // Switching back clears the advisory in the session's model
                // sink. Dismiss explicitly too, since that sink skips changes
                // made while a model is loading.
                bannerPrimaryButton(String(localized: "Keep Using \(previous)", bundle: .module)) {
                    withAnimation(theme.motion.quick) {
                        selectedModel = previousModelId
                        onDismissModelSwitchContinuityWarning?()
                    }
                }
                bannerTextButton(String(localized: "Start New Chat", bundle: .module)) {
                    onDismissModelSwitchContinuityWarning?()
                    onClearChat?()
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, theme.space.s2)
        }
        .padding(.leading, theme.space.s14)
        .padding(.trailing, theme.space.s14)
        .padding(.top, theme.space.s12)
        .padding(.bottom, 12 + RAMBannerShape.pointerHeight)
        .background(
            ZStack {
                shape.fill(theme.surface.overlay)
                shape.fill(theme.wash(behind: tint))
            }
        )
        .overlay(shape.stroke(theme.rule(around: tint), lineWidth: theme.stroke.default))
        .themeElevation(theme.elevation.raised)
        .accessibilityLabel(
            Text(
                "Model changed from \(previous) to \(next); cached context will be rebuilt",
                bundle: .module
            )
        )
    }

    /// Commit action shared by the remaining informational banners.
    private func bannerPrimaryButton(
        _ title: String,
        role: SettingsButtonRole = .primary,
        action: @escaping () -> Void
    ) -> some View {
        SettingsButton(role, title, size: .compact, verbatim: true, action: action)
            // Keep the button label independent of its containing banner.
            .accessibilityLabel(Text(verbatim: title))
    }

    /// Borderless secondary action for informational banners.
    private func bannerTextButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .textStyle(.footnote, weight: 600)
                .lineLimit(1)
                .fixedSize()
                .foregroundColor(theme.text.secondary)
                .padding(.vertical, theme.space.s2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: title))
    }

    // MARK: - MTP Bundle-Layout Advisory

    /// Re-evaluate the selected local bundle's MTP layout. Memoized per
    /// selection: the actual evaluation reads the bundle directory (a few
    /// file stats + small JSON parses), so it runs once per pick — off the
    /// main actor — not on every 2s memory tick.
    ///
    /// Advisory only: it never
    /// refuses, never caps, never blocks a load. The bundle keeps loading
    /// exactly as before; this just tells the user a re-download exists.
    private func refreshMTPLayoutAdvisory() {
        let selection = selectedModel ?? ""
        guard mtpAdvisoryEvaluatedForModel != selection else { return }

        // Local bundles only: cloud/remote models have no directory to
        // inspect, and remote-agent runs execute elsewhere. Deliberately NOT
        // memoized on this path: with a cold local-scan cache the lookup
        // reports "not local" for a bundle that IS local, so the 2s tick
        // keeps retrying (two memoized dictionary reads) until the scan
        // lands or the selection really is remote.
        guard localBundleAdvisoriesApplyToSelectedModel,
            let model = selectedModel,
            let installed = ModelManager.findInstalledMLXModelFromCache(named: model)
        else {
            if mtpLayoutAdvisory != nil { mtpLayoutAdvisory = nil }
            return
        }

        // A bundle mid-download or paused is INCOMPLETE by definition —
        // its index legitimately names shards that haven't arrived yet.
        // Skip (without memoizing, so the tick re-checks) until the
        // download machinery is done with it.
        switch ModelManager.shared.effectiveDownloadState(for: installed) {
        case .downloading, .paused:
            return
        case .notStarted, .completed, .failed:
            break
        }

        mtpAdvisoryEvaluatedForModel = selection
        mtpAdvisoryConfirmingRedownload = false

        let bundleDir = installed.localDirectory
        Task.detached(priority: .utility) {
            let advisory = MTPLayoutAdvisory.evaluate(bundleDirectory: bundleDir)
            // Selection must expose the controls before Send. This reads only
            // bundle metadata/headers; it neither loads nor warms the model.
            let capability = ModelRuntime.inspectLoadingModelMTP(name: model, directory: bundleDir)
            await MainActor.run {
                // The selection may have moved while we were on disk.
                guard selectedModel == model else { return }
                let identity = Self.mtpIdentity(model)
                if let capability, capability.speculationAvailable {
                    nativeMTPCapableModels.insert(identity)
                    if capability.familyDefaultOn {
                        nativeMTPFamilyDefaultOnModels.insert(identity)
                    } else {
                        nativeMTPFamilyDefaultOnModels.remove(identity)
                    }
                    if capability.speculationBlocked {
                        nativeMTPManuallyBlockedModels.insert(identity)
                    } else {
                        nativeMTPManuallyBlockedModels.remove(identity)
                    }
                } else {
                    nativeMTPCapableModels.remove(identity)
                    nativeMTPManuallyBlockedModels.remove(identity)
                }
                // Shown once per bundle per improper-state fingerprint: a
                // dismissed state stays quiet across relaunches, while a
                // DIFFERENT improper state re-arms the notice.
                if let advisory,
                    MTPLayoutAdvisoryDismissals.isDismissed(advisory.fingerprint)
                {
                    if mtpLayoutAdvisory != nil { mtpLayoutAdvisory = nil }
                    return
                }
                if mtpLayoutAdvisory != advisory { mtpLayoutAdvisory = advisory }
            }
        }
    }

    /// Forget the per-selection memo and re-evaluate — called when the local
    /// model set changes (a delete or a completed download), so a freshly
    /// re-downloaded bundle clears or re-raises the notice on its own.
    private func rearmMTPLayoutAdvisory() {
        mtpAdvisoryEvaluatedForModel = nil
        refreshMTPLayoutAdvisory()
    }

    /// The model-switch notice takes precedence over the bundle-layout advisory.
    @ViewBuilder
    private var mtpLayoutAdvisoryRow: some View {
        if localBundleAdvisoriesApplyToSelectedModel,
            !configContextTooSmall,
            modelSwitchContinuityWarning == nil,
            let advisory = mtpLayoutAdvisory
        {
            mtpLayoutAdvisoryBanner(advisory, pointerCenterX: 28)
                .frame(width: Self.ramBannerWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, theme.space.s20)
                .padding(.top, theme.space.s8)
                .padding(.bottom, -16)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    /// Always orange: both severities are advisories about a
    /// superseded bundle layout, never about a broken session.
    private func mtpLayoutAdvisoryBanner(
        _ advisory: MTPLayoutAdvisory,
        pointerCenterX: CGFloat
    ) -> some View {
        let tint = theme.status.warning.foreground
        let clampedX = min(
            max(pointerCenterX, 14 + RAMBannerShape.pointerWidth / 2),
            Self.ramBannerWidth - 14 - RAMBannerShape.pointerWidth / 2
        )
        let shape = RAMBannerShape(pointerCenterX: clampedX)

        return VStack(alignment: .leading, spacing: theme.space.s10) {
            if mtpAdvisoryConfirmingRedownload {
                (Text(Image(systemName: "trash"))
                    .foregroundColor(tint)
                    + Text(verbatim: "  ")
                    + Text(
                        "Delete this model's local files and download a fresh copy?",
                        bundle: .module
                    ).foregroundColor(theme.text.primary))
                    .textStyle(.caption, weight: 500)
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    "The download starts right after the delete. Until it finishes, this model can't be used.",
                    bundle: .module
                )
                .foregroundColor(theme.text.secondary)
                .textStyle(.caption, weight: 500)
                .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: theme.space.s10) {
                    bannerPrimaryButton(
                        String(localized: "Delete & Re-download", bundle: .module),
                        role: .destructive
                    ) {
                        performMTPAdvisoryRedownload()
                    }
                    bannerTextButton(String(localized: "Cancel", bundle: .module)) {
                        withAnimation(theme.motion.quick) {
                            mtpAdvisoryConfirmingRedownload = false
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, theme.space.s2)
            } else {
                (Text(Image(systemName: "shippingbox.fill"))
                    .foregroundColor(tint)
                    + Text(verbatim: "  ")
                    + Text(verbatim: advisory.warningText)
                    .foregroundColor(theme.text.primary))
                    .textStyle(.caption, weight: 500)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: advisory.reassuranceText)
                    .foregroundColor(theme.text.secondary)
                    .textStyle(.caption, weight: 500)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: theme.space.s10) {
                    bannerPrimaryButton(String(localized: "Re-download", bundle: .module)) {
                        withAnimation(theme.motion.quick) {
                            mtpAdvisoryConfirmingRedownload = true
                        }
                    }
                    bannerTextButton(String(localized: "Skip", bundle: .module)) {
                        MTPLayoutAdvisoryDismissals.recordDismissal(advisory.fingerprint)
                        withAnimation(theme.motion.quick) {
                            mtpLayoutAdvisory = nil
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, theme.space.s2)
            }
        }
        .padding(.leading, theme.space.s14)
        .padding(.trailing, theme.space.s14)
        .padding(.top, theme.space.s12)
        .padding(.bottom, 12 + RAMBannerShape.pointerHeight)
        .background(
            ZStack {
                shape.fill(theme.surface.overlay)
                shape.fill(theme.wash(behind: tint))
            }
        )
        .overlay(shape.stroke(theme.rule(around: tint), lineWidth: theme.stroke.default))
        .themeElevation(theme.elevation.raised)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: advisory.shortLabel))
    }

    /// Deletes the local bundle through the model library's own deletion
    /// path (which quarantines + unloads safely), then kicks off a fresh
    /// download of the SAME model through the existing download machinery.
    /// The model struct is resolved BEFORE the delete so the download never
    /// depends on re-resolving an id whose files are already gone.
    private func performMTPAdvisoryRedownload() {
        guard let model = selectedModel,
            let installed = ModelManager.findInstalledMLXModelFromCache(named: model)
        else {
            withAnimation(theme.motion.quick) {
                mtpAdvisoryConfirmingRedownload = false
                mtpLayoutAdvisory = nil
            }
            return
        }
        withAnimation(theme.motion.quick) {
            mtpAdvisoryConfirmingRedownload = false
            mtpLayoutAdvisory = nil
        }
        Task { @MainActor in
            let manager = ModelManager.shared
            await manager.deleteModel(installed)
            manager.downloadModel(installed)
            // The delete + eventual download completion both post
            // `.localModelsChanged`, which re-arms the evaluation; clearing
            // the memo here just makes the first re-check immediate.
            mtpAdvisoryEvaluatedForModel = nil
        }
    }

    /// Compact, floating toast shown above the card when the Default agent's
    /// selected model is too small to run configuration. Names the model +
    /// window and offers a one-tap jump to the model picker so the fix is
    /// obvious.
    private var configContextErrorBanner: some View {
        // The banner only renders when `configContextTooSmall` is true, which
        // requires a non-nil `selectedModel`, so the empty fallback is
        // unreachable — it just keeps `modelName` non-optional.
        let modelName = selectedPickerItem?.displayName ?? selectedModel ?? ""
        let ctx = selectedModel.flatMap { ContextSizeResolver.resolve(modelId: $0).contextLength }
        let ctxBlurb = ctx.map { " (~\(formatTokenCount($0)) ctx)" } ?? ""
        return HStack(spacing: theme.space.s8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .glyphSize(.caption)
                .foregroundColor(theme.status.warning.foreground)

            Text(
                "\(modelName)\(ctxBlurb) is too small to configure Osaurus.",
                bundle: .module
            )
            .textStyle(.caption, weight: 500)
            .foregroundColor(theme.text.primary)
            .fixedSize(horizontal: false, vertical: true)

            Button {
                openModelPicker()
            } label: {
                Text("Choose model", bundle: .module)
                    .textStyle(.caption, weight: 600)
                    .foregroundColor(theme.text.link)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
        }
        .padding(.horizontal, theme.space.s14)
        .padding(.vertical, theme.space.s8)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous)
                    .fill(theme.surface.overlay)
                RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous)
                    .fill(theme.status.warning.background)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous)
                .strokeBorder(theme.status.warning.border, lineWidth: theme.stroke.default)
        )
        .themeElevation(theme.elevation.raised)
        .frame(maxWidth: 560)
    }

    // MARK: - Folder Context Chip

    private func folderContextChip(compact: Bool) -> some View {
        let hasFolder = folderState.hasActiveFolder

        return HStack(spacing: theme.catalogLayoutMetric("component.library.23.elements.layout.floatingInputCard.folderContextChip.horizontalGap", inheriting: theme.assignedMetric("component.library.23.gap", fallback: theme.space.s4))) {
            Button(action: selectFolder) {
                folderChipContent(hasFolder: hasFolder, canEdit: true, compact: compact)
            }
            .composerChipButtonStyle()
            .composerChipFocus()
            .pointingHandCursor()
            .disabled(folderLockedByHarnessTurn)
            .help(
                folderLockedByHarnessTurn
                    ? Text("The folder can change after this reply finishes.", bundle: .module)
                    : folderChipHelp(hasFolder: hasFolder)
            )
            // The chip is icon-only in the compact state and its text is
            // decorative otherwise, so assistive tech (and the AX-driven
            // harness) saw an unnamed button. Name it and keep the folder
            // name readable through the value.
            .accessibilityLabel(Text("Folder", bundle: .module))
            .accessibilityValue(
                Text(verbatim: hasFolder ? (folderState.rootPath?.lastPathComponent ?? "") : "")
            )
            .accessibilityIdentifier("composer.folderChip")
            .assignedContextMenu {
                if hasFolder {
                    Button {
                        selectFolder()
                    } label: {
                        Label {
                            Text("Change Folder", bundle: .module)
                        } icon: {
                            Image(systemName: "folder.badge.gear")
                        }
                    }
                    Button {
                        Task { await folderState.refreshContext() }
                    } label: {
                        Label {
                            Text("Refresh Context", bundle: .module)
                        } icon: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        clearFolderFromChip()
                    } label: {
                        Label {
                            Text("Clear Folder", bundle: .module)
                        } icon: {
                            Image(systemName: "folder.badge.minus")
                        }
                    }
                }
            }

            if hasFolder {
                Button {
                    clearFolderFromChip()
                } label: {
                    Image(systemName: "xmark")
                        .glyphSize(.tiny, weight: .bold)
                        .composerChipInk("secondary", fallback: theme.text.tertiary)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(theme.surface.subtle))
                        .overlay(Circle().strokeBorder(theme.border.subtle, lineWidth: theme.stroke.default))
                }
                .composerChipButtonStyle()
                .pointingHandCursor()
                .localizedHelp("Clear folder selection")
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }.catalogLayoutTarget("component.library.23.elements.layout.floatingInputCard.folderContextChip.horizontalGap")
        .animation(theme.motion.quick, value: hasFolder)
    }

    @ViewBuilder
    private func folderChipContent(hasFolder: Bool, canEdit: Bool, compact: Bool = false) -> some View {
        SharedChipContent(spacing: theme.assignedMetric("component.library.23.gap", fallback: theme.space.s4)) {
            Image(systemName: hasFolder ? "folder.fill" : "folder.badge.plus")
                .glyphSize(.micro)
                .composerChipInk(hasFolder ? "foreground" : "secondary", fallback: hasFolder ? theme.text.primary : theme.text.tertiary)
                .opacity(canEdit ? 1.0 : 0.7)

            // The selected folder name is live state, so keep it even when
            // compact; only the "Folder" placeholder collapses to the icon.
            if let context = folderState.context {
                Text(context.rootPath.lastPathComponent)
                    .composerChipTextStyle(.caption, weight: 500)
                    .composerChipInk(canEdit ? "foreground" : "secondary", fallback: canEdit ? theme.text.secondary : theme.text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // Cap the name so a long folder can't stretch the chip and
                    // shove the chips after it out of the row. The cluster is
                    // sized at its ideal width inside the horizontal
                    // ScrollView, so shorter names still hug — the cap only
                    // bites (middle-truncating) past this width. The full name
                    // stays available via the chip's help tooltip.
                    .frame(maxWidth: 150)
            } else if canEdit && !compact {
                Text("Folder", bundle: .module)
                    .composerChipTextStyle(.caption, weight: 500)
                    .composerChipInk("secondary", fallback: theme.text.tertiary)
                    .fixedSize()
            }

            // Drop the picker chevron in the compact placeholder state so the
            // chip shrinks to just the folder glyph; keep it whenever a name
            // is shown so the affordance to change folders stays visible.
            if canEdit && (!compact || folderState.context != nil) {
                Image(systemName: "chevron.up.chevron.down")
                    .glyphSize(.tiny, weight: .semibold)
                    .composerChipInk("secondary", fallback: theme.text.tertiary)
            }
        }
        .composerChipSurface(selected: hasFolder)
    }

    private func dismissModelPicker() {
        showModelPicker = false
    }

    // MARK: - Input Card

    private var inputCard: some View {
        let hasChipRow = !pendingAttachments.isEmpty || pendingSkillId != nil || queuedSend != nil
        let attachmentInset = composerTheme.catalogMetric("padding", fallback: composerTheme.space.s12)
        return VStack(alignment: .leading, spacing: theme.space.s0) {
            if hasChipRow {
                HStack(alignment: .center, spacing: theme.space.s6) {
                    queuedSendChipView
                    pendingSkillChipView
                    if !pendingAttachments.isEmpty {
                        inlinePendingAttachmentsPreview
                    }
                }
                .padding(.horizontal, attachmentInset)
                .padding(.top, attachmentInset)
            }

            textInputArea
                .frame(minHeight: minimumEditorHeight, alignment: .topLeading)
                .padding(.horizontal, theme.space.s8)
                .padding(.top, theme.space.s8)
                // Keep the last visible line clear of actions even when the
                // native editor reaches its height cap and starts scrolling.
                .padding(.bottom, max(12, theme.space.s12))

            buttonBar
                .padding(.horizontal, theme.space.s8)
                .padding(.bottom, theme.space.s8)
        }
        .environment(\.isOnComposerInputSurface, true)
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: minimumCardHeight, alignment: .top)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: composerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: composerRadius, style: .continuous)
                .strokeBorder(
                    effectiveBorderStyle,
                    lineWidth: composerTheme.catalogMetric("borderWidth", fallback: (isDragOver || isFocused) ? theme.stroke.focus : theme.stroke.default)
                )
        )
        // The Figma composer has one surface and border, without an extra shadow.
        .animation(theme.motion.quick, value: isFocused)
        .animation(theme.motion.quick, value: isDragOver)
    }

    // MARK: - Voice Input Button

    private func appendAttachment(_ attachment: Attachment) {
        withAnimation(theme.motion.springAnimation) {
            pendingAttachments.append(attachment)
        }
    }

    private func parseAndAttach(url: URL) {
        let filename = url.lastPathComponent
        let animation = theme.motion.springAnimation
        Task.detached(priority: .userInitiated) {
            do {
                let attachments = try DocumentParser.parseAll(url: url)
                await MainActor.run {
                    withAnimation(animation) {
                        self.pendingAttachments.append(contentsOf: attachments)
                    }
                }
            } catch {
                _ = await MainActor.run {
                    ToastManager.shared.error(
                        L("Could not attach \(filename)"),
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    /// Capability-gated UTType allowlist for both the file picker and
    /// the drop zone. Resolves from `selectedModel` plus the session's
    /// already-known image support bit. Text-only models keep document
    /// attach support but reject image/audio/video media.
    ///
    /// See `Models/Configuration/ModelMediaCapabilities.swift` for the
    /// substring/regex matcher; tests pin the boundary at
    /// `ModelMediaCapabilitiesMCDCTests`.
    private var mediaCapabilityDescriptor: ModelMediaCapabilities.Descriptor {
        // The local-model scan runs off-main and records config.json's
        // model_type. Read only its non-blocking snapshot here: this getter is
        // evaluated from SwiftUI body/layout and must never trigger a disk
        // scan or synchronously parse a model bundle.
        let localModel = selectedModel.flatMap {
            ModelManager.findInstalledMLXModelFromCache(named: $0)
        }
        // Audio has to come from the checkpoint, not the name: gemma-4 E2B
        // carries `embed_audio.embedding_projection` while its id says nothing
        // about audio, so the picker advertised "image supported" and greyed
        // out every .wav. `hasAudioTensors` is memoized for exactly this
        // getter's no-disk-IO rule.
        //
        // Bundle evidence comes from the cache-only snapshot; a pending read
        // resolves as text-only until `evidenceReady` bumps the generation
        // below and this getter re-runs. The audio bit comes from the same
        // snapshot so no branch here can fall through to a synchronous read.
        _ = mediaEvidenceGeneration
        let snapshot = localModel?.mediaCapabilitiesSnapshot
        let runtime = harnessRuntime
        return ModelMediaCapabilities.composerDescriptor(
            modelId: runtime?.displayName ?? selectedModel,
            fallbackSupportsImages: supportsImages,
            localModelType: localModel?.modelType,
            localHasAudioTensors: snapshot?.supportsAudio ?? false,
            localCapabilities: snapshot,
            localImageEvidenceReason: localModel.flatMap {
                LocalVisionEvidence.cachedOrWarm($0.localDirectory)?.reason
            },
            harnessKind: runtime?.kind
        )
    }

    private var mediaCapabilities: ModelMediaCapabilities.Capabilities {
        mediaCapabilityDescriptor.capabilities
    }

    /// UTTypes the drop zone advertises. `fileURL` stays enabled for
    /// documents, while image/audio/video are advertised only when the
    /// selected model can consume them.
    private var dropAcceptedTypes: [UTType] {
        var types: [UTType] = [UTType.fileURL]
        let cap = mediaCapabilities
        if cap.supportsImage {
            types.append(.image)
        }
        if cap.supportsAudio {
            types.append(.audio)
            // explicit common audio formats so HEIF-style "any audio"
            // type negotiation doesn't miss specific containers
            types.append(.mp3)
            types.append(.wav)
            types.append(.mpeg4Audio)
        }
        if cap.supportsVideo {
            types.append(.movie)
            types.append(.video)
            types.append(.quickTimeMovie)
            types.append(.mpeg4Movie)
        }
        return types
    }

    /// File-picker `allowedContentTypes`. Same gating as `dropAcceptedTypes`
    /// but flattened (no fileURL parent — picker accepts concrete types
    /// only). Picker shows audio/video formats only when the loaded
    /// model can actually consume them.
    private var pickerAllowedTypes: [UTType] {
        var types: [UTType] = []
        let cap = mediaCapabilities
        if cap.supportsImage {
            types.append(.image)
        }
        types.append(contentsOf: DocumentParser.supportedDocumentTypes)
        if cap.supportsAudio {
            types.append(.audio)
            types.append(.mp3)
            types.append(.wav)
            types.append(.mpeg4Audio)
        }
        if cap.supportsVideo {
            types.append(.movie)
            types.append(.video)
            types.append(.quickTimeMovie)
            types.append(.mpeg4Movie)
        }
        return types
    }

    private func pickAttachment() {
        guard !attachmentPickerPresented else { return }
        let window = windowId.flatMap { ChatWindowManager.shared.getNSWindow(id: $0) }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = pickerAllowedTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message =
            mediaCapabilities.anyMedia
            ? "Select files to attach (\(mediaCapabilities.summary) supported)"
            : "Select files to attach"

        attachmentPickerPresented = true
        Task { @MainActor in
            defer { attachmentPickerPresented = false }
            let response: NSApplication.ModalResponse
            if let window {
                response = await panel.beginSheetModal(for: window)
            } else {
                response = await panel.beginModal()
            }
            guard response == .OK else { return }
            for url in panel.urls {
                attachIfAllowed(url: url)
            }
        }
    }

    /// Routes a file URL to the right attachment kind based on its
    /// extension + the loaded model's capabilities. Drops files that
    /// the current model can't consume rather than silently attaching
    /// them as opaque documents.
    private func attachIfAllowed(url: URL) {
        let ext = url.pathExtension.lowercased()
        let descriptor = mediaCapabilityDescriptor
        let cap = descriptor.capabilities

        // Image fast path — only for image-capable models.
        if DocumentParser.isImageFile(url: url) {
            guard cap.supportsImage else {
                ToastManager.shared.error(
                    L("Cannot attach \(url.lastPathComponent)"),
                    message: descriptor.rejectionMessage(for: .image)
                )
                return
            }
            let sizeLimit = maxImageSize
            let filename = url.lastPathComponent
            Task { @MainActor in
                // The image decode and re-encode block for seconds on a
                // large file, so they run off the main actor and only the
                // finished bytes are attached here.
                let encoded = await Task.detached(priority: .userInitiated) {
                    () -> Data? in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    if data.count <= sizeLimit {
                        guard let nsImage = NSImage(data: data) else { return nil }
                        return nsImage.pngData()
                    }
                    // Over the inline cap: downscale to the wire budget
                    // instead of vanishing without a word — the old
                    // `data.count <= sizeLimit else return nil` silently
                    // dropped a big photo while the picker looked like it
                    // accepted it.
                    return RemoteImagePayloadPolicy.downsizedJPEGData(from: data)
                }.value
                if let encoded {
                    appendAttachment(.image(encoded))
                } else {
                    ToastManager.shared.error(
                        L("Could not attach \(filename)"),
                        message: L("The image could not be read or re-encoded.")
                    )
                }
            }
            return
        }

        // Audio path — only for omni models.
        if audioExtensions.contains(ext) {
            guard cap.supportsAudio else {
                ToastManager.shared.error(
                    L("Cannot attach \(url.lastPathComponent)"),
                    message: descriptor.rejectionMessage(for: .audio)
                )
                return
            }
            attachAudio(url: url, ext: ext)
            return
        }

        // Video path — Qwen-VL family + SmolVLM 2 + Nemotron-Omni.
        if videoExtensions.contains(ext) {
            guard cap.supportsVideo else {
                ToastManager.shared.error(
                    L("Cannot attach \(url.lastPathComponent)"),
                    message: descriptor.rejectionMessage(for: .video)
                )
                return
            }
            attachVideo(url: url)
            return
        }

        // Document fallback — markdown, PDF, etc.
        if DocumentParser.canParse(url: url) {
            parseAndAttach(url: url)
            return
        }

        // Reject otherwise — surface a toast so the user knows why.
        ToastManager.shared.error(
            L("Cannot attach \(url.lastPathComponent)"),
            message:
                cap.anyMedia
                ? L("The current model supports \(cap.summary) only.")
                : L("The current model is text-only.")
        )
    }

    /// Extensions accepted by the generic `UTType.audio` picker must also be
    /// routed here. Otherwise AppKit lets the user select a valid audio file
    /// and the composer silently falls through to the unsupported-document
    /// branch. Keep this internal so the picker/router parity is unit tested.
    static let audioExtensions: Set<String> = [
        "wav", "wave", "mp3", "mpeg", "m4a", "x-m4a", "flac", "ogg", "opus", "aac", "wma",
        "aif", "aiff", "aifc", "caf",
    ]

    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "qt", "webm", "mkv", "avi",
    ]

    private var audioExtensions: Set<String> { Self.audioExtensions }
    private var videoExtensions: Set<String> { Self.videoExtensions }

    /// Attach audio bytes from a file URL. Reads inline; the conversation
    /// store moves large bytes to a blob once the turn is saved. Format
    /// string is the lowercased file extension and flows directly into
    /// `MessageContentPart.audioInput.format`.
    private func attachAudio(url: URL, ext: String) {
        guard let data = try? Data(contentsOf: url) else {
            ToastManager.shared.error(
                L("Could not read \(url.lastPathComponent)"),
                message: L("File may be unreadable or too large to attach.")
            )
            return
        }
        // Cap inline audio at 50 MB — beyond that the user is sending
        // multi-minute clips that should go through a streaming API.
        guard data.count <= 50 * 1024 * 1024 else {
            ToastManager.shared.errorLocalized(
                "Audio file too large",
                message: "Files larger than 50 MB are not supported in chat attachments."
            )
            return
        }
        appendAttachment(.audio(data, format: ext, filename: url.lastPathComponent))
    }

    /// Attach video bytes from a file URL. Same lifecycle as audio,
    /// but with a tighter inline cap (30 MB) since video is bigger
    /// per-second and the runtime extracts only 8 frames anyway.
    private func attachVideo(url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            ToastManager.shared.error(
                L("Could not read \(url.lastPathComponent)"),
                message: L("File may be unreadable or too large to attach.")
            )
            return
        }
        guard data.count <= 100 * 1024 * 1024 else {
            ToastManager.shared.errorLocalized(
                "Video file too large",
                message: "Files larger than 100 MB are not supported. Trim before attaching."
            )
            return
        }
        appendAttachment(.video(data, filename: url.lastPathComponent))
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        let cap = mediaCapabilities

        for provider in providers {
            if cap.supportsImage,
                provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
            {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                    guard let data = data, error == nil else { return }
                    // Decode and re-encode on the provider's background queue;
                    // only the finished bytes hop to the main thread. Oversized
                    // drops downscale to the wire budget instead of silently
                    // vanishing (the old `count <= maxImageSize else return`).
                    let encoded: Data?
                    if data.count <= maxImageSize {
                        encoded = NSImage(data: data)?.pngData()
                    } else {
                        encoded = RemoteImagePayloadPolicy.downsizedJPEGData(from: data)
                    }
                    guard let encoded else { return }
                    DispatchQueue.main.async {
                        appendAttachment(.image(encoded))
                    }
                }
            } else if cap.supportsAudio,
                provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier)
            {
                handled = true
                // Audio path — load via fileURL so we get the extension,
                // not raw data identifier.
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let urlData = item as? Data,
                        let url = URL(dataRepresentation: urlData, relativeTo: nil)
                    else { return }
                    DispatchQueue.main.async {
                        self.attachIfAllowed(url: url)
                    }
                }
            } else if cap.supportsVideo,
                provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
                    || provider.hasItemConformingToTypeIdentifier(UTType.video.identifier)
            {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let urlData = item as? Data,
                        let url = URL(dataRepresentation: urlData, relativeTo: nil)
                    else { return }
                    DispatchQueue.main.async {
                        self.attachIfAllowed(url: url)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                    guard let data = item as? Data,
                        let url = URL(dataRepresentation: data, relativeTo: nil)
                    else { return }
                    DispatchQueue.main.async {
                        // attachIfAllowed handles audio/video/image/doc routing
                        // + capability rejection in one place.
                        self.attachIfAllowed(url: url)
                    }
                }
            }
        }
        return handled
    }

    /// Placeholder text for the input field.
    ///
    /// Evaluated from the composer body on every keystroke, so it must stay
    /// cheap: the keys are a fixed set and go through the memoized `LCached`
    /// (an uncached `L` lookup here was the leaf of main-thread hang
    /// APPLE-MACOS-1E7), and the image check inspects attachment kinds
    /// instead of hydrating spilled image blobs from disk.
    private var placeholderText: String {
        if !placeholderIdeas.isEmpty { return placeholderIdeas[placeholderIdeaIndex % placeholderIdeas.count] }
        if let media = selectedMediaPickerItem?.mediaModel {
            switch media.kind {
            case .image:
                return LCached("Describe the image...")
            case .textToVideo:
                return LCached("Describe the video...")
            case .imageToVideo:
                return pendingAttachments.contains(where: \.isImage)
                    ? LCached("Describe how the image should move...")
                    : LCached("Attach one image, then describe the video...")
            }
        }
        if selectedImagePickerItem != nil {
            return LCached("Describe the image...")
        }
        return LCached("Message or attach files...")
    }

    // MARK: - Image Composer Controls

    private var seedText: Binding<String> {
        Binding(
            get: { imageComposerSettings.seed },
            set: {
                // Remote media keeps its existing digits-only input contract.
                // Local image requests validate the complete string at admission.
                imageComposerSettings.seed = selectedMediaPickerItem?.mediaModel != nil
                    ? $0.filter(\.isNumber) : $0
            }
        )
    }

    /// Inline image config chips that ride in the selector row beside the model
    /// chip (the model owns these settings, and the row's normal chips are inert
    /// for image models).
    private var imageComposerChips: some View {
        Group {
            if let media = selectedMediaPickerItem?.mediaModel {
                catalogMediaComposerChips(media)
            } else {
                HStack(spacing: theme.space.s6) {
                    sizeSelector
                    stepsChip
                    if ImageModelRequestPolicy(canonical: selectedImagePickerItem?.imageCanonicalName).supportsGuidance {
                        cfgChip
                    }
                    seedChip
                    if imageComposerControls.strength {
                        strengthChip
                    }
                    if ImageComposerRequestBuilder.hasUnsupportedEditOverrides(
                        controls: imageComposerControls, settings: imageComposerSettings,
                        canonical: selectedImagePickerItem?.imageCanonicalName
                    ) {
                        Button {
                            if !imageComposerControls.strength {
                                imageComposerSettings.strengthWasExplicitlySet = false
                            }
                            if !imageComposerControls.negativePrompt {
                                imageComposerSettings.negativePrompt = ""
                            }
                        } label: {
                            Text(localized: "Clear unsupported edit settings")
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func catalogMediaComposerChips(_ media: MediaModelInfo) -> some View {
        HStack(spacing: theme.space.s6) {
            if media.kind == .image,
                media.constraints.aspectRatios.isEmpty,
                media.constraints.resolutions.isEmpty
            {
                sizeSelector
            }
            if !media.constraints.aspectRatios.isEmpty {
                mediaChoiceChip(
                    title: L("Aspect"),
                    icon: "aspectratio",
                    options: media.constraints.aspectRatios,
                    selection: Binding(
                        get: { imageComposerSettings.aspectRatio },
                        set: { imageComposerSettings.aspectRatio = $0 }
                    )
                )
            }
            if !media.constraints.resolutions.isEmpty {
                mediaChoiceChip(
                    title: L("Resolution"),
                    icon: "rectangle.inset.filled",
                    options: media.constraints.resolutions,
                    selection: Binding(
                        get: { imageComposerSettings.resolution },
                        set: { imageComposerSettings.resolution = $0 }
                    )
                )
            }
            if !media.constraints.qualities.isEmpty {
                mediaChoiceChip(
                    title: L("Quality"),
                    icon: "sparkles",
                    options: media.constraints.qualities,
                    selection: Binding(
                        get: { imageComposerSettings.quality },
                        set: { imageComposerSettings.quality = $0 }
                    )
                )
            }
            if media.kind.isVideo, !media.constraints.durations.isEmpty {
                mediaChoiceChip(
                    title: L("Duration"),
                    icon: "clock",
                    options: media.constraints.durations,
                    selection: Binding(
                        get: { imageComposerSettings.duration },
                        set: { imageComposerSettings.duration = $0 }
                    )
                )
            }
            if media.kind.isVideo, media.constraints.audioConfigurable {
                Button {
                    imageComposerSettings.audio =
                        !(imageComposerSettings.audio ?? media.constraints.supportsAudio)
                } label: {
                    HStack(spacing: theme.space.s4) {
                        Image(
                            systemName: imageComposerSettings.audio == true
                                ? "speaker.wave.2.fill" : "speaker.slash.fill"
                        )
                        Text(imageComposerSettings.audio == true ? L("Audio") : L("Muted"))
                    }
                    .textStyle(.caption, weight: 500)
                    .foregroundColor(theme.text.secondary)
                    .modifier(ImageOptionChipSurface())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
            if media.kind == .image {
                if media.constraints.defaultSteps != nil || media.constraints.maxSteps != nil {
                    stepsChip
                }
                cfgChip
                seedChip
                mediaChoiceChip(
                    title: L("Format"),
                    icon: "doc",
                    options: ImageOutputFormat.allCases.map(\.rawValue),
                    selection: Binding(
                        get: { Optional(imageComposerSettings.effectiveOutputFormat.rawValue) },
                        set: {
                            imageComposerSettings.outputFormat = $0.flatMap {
                                ImageOutputFormat(rawValue: $0)
                            }
                        }
                    )
                )
                mediaChoiceChip(
                    title: L("Count"),
                    icon: "square.stack.3d.up",
                    options: (1 ... 4).map(String.init),
                    selection: Binding(
                        get: { Optional(String(imageComposerSettings.clampedImageCount)) },
                        set: { imageComposerSettings.imageCount = $0.flatMap { Int($0) } }
                    )
                )
            }
            if let minimum = media.pricing?.minimumUSD {
                Text("From \(OsaurusRouter.formatUSDAsCredits(minimum))", bundle: .module)
                    .textStyle(.caption, weight: 500)
                    .foregroundColor(theme.text.secondary)
                    .modifier(ImageOptionChipSurface())
            }
            if media.kind == .imageToVideo {
                Label("1 source image", systemImage: "photo")
                    .textStyle(.caption, weight: 500)
                    .foregroundColor(
                        pendingAttachments.loadImages().count == 1
                            ? theme.text.secondary : theme.status.warning.foreground
                    )
                    .modifier(ImageOptionChipSurface())
            }
        }
    }

    private func mediaChoiceChip(
        title: String,
        icon: String,
        options: [String],
        selection: Binding<String?>
    ) -> some View {
        SettingsActionMenu(accessibilityLabel: title) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection.wrappedValue = option
                } label: {
                    if selection.wrappedValue == option {
                        Label(option, systemImage: "checkmark")
                    } else {
                        Text(option)
                    }
                }
            }
        } label: {
            HStack(spacing: theme.space.s4) {
                Image(systemName: icon)
                    .foregroundColor(theme.text.tertiary)
                Text(selection.wrappedValue ?? title)
                    .foregroundColor(theme.text.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .glyphSize(.tiny, weight: .semibold)
                    .foregroundColor(theme.text.tertiary)
            }
            .textStyle(.caption, weight: 500)
            .modifier(ImageOptionChipSurface())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(Text(verbatim: title))
    }


    /// A selectable output resolution with a one-line explanation of its
    /// speed / detail trade-off (bare pixel numbers don't tell the user what
    /// they're choosing).
    private struct ImageSizeOption: Identifiable {
        let width: Int
        let height: Int
        let title: String
        let detail: String
        var id: String { "\(width)x\(height)" }
    }

    private var imageSizeOptions: [ImageSizeOption] {
        var options = [
            ImageSizeOption(
                width: 512,
                height: 512,
                title: L("512 × 512"),
                detail: L("Fast drafts. Lowest detail, quickest to render.")
            ),
            ImageSizeOption(
                width: 768,
                height: 768,
                title: L("768 × 768"),
                detail: L("Balanced. Good detail at a moderate speed.")
            ),
            ImageSizeOption(
                width: 1024,
                height: 1024,
                title: L("1024 × 1024"),
                detail: L("Sharpest. The size most models are trained for, but slowest.")
            ),
        ]
        if selectedMediaPickerItem?.mediaModel != nil {
            options.append(
                ImageSizeOption(
                    width: 1280,
                    height: 720,
                    title: L("1280 × 720"),
                    detail: L("Landscape 16:9 for cinematic and banner compositions.")
                )
            )
            options.append(
                ImageSizeOption(
                    width: 720,
                    height: 1280,
                    title: L("720 × 1280"),
                    detail: L("Portrait 9:16 for mobile and vertical compositions.")
                )
            )
        }
        return options
    }

    private var selectedSizeLabel: String {
        if ImageModelRequestPolicy.usesBundleParameters(selectedImagePickerItem?.imageCanonicalName),
            !imageComposerSettings.hasExplicitImageSize
        {
            return pendingAttachments.hasImages ? L("Use source aspect ratio") : "1024px"
        }
        let w = imageComposerSettings.width
        let h = imageComposerSettings.height
        return w == h ? "\(w)px" : "\(w)×\(h)"
    }

    /// Output size as a dropdown chip: the label alone ("768px") is ambiguous,
    /// so the popover spells out what each resolution means.
    private var sizeSelector: some View {
        SelectorChip(isActive: showImageSizePicker) {
            showImageSizePicker.toggle()
        } content: {
            HStack(spacing: theme.space.s4) {
                Image(systemName: "aspectratio")
                    .glyphSize(.micro, weight: .medium)
                    .foregroundColor(theme.text.tertiary)
                Text(selectedSizeLabel)
                    .textStyle(.caption, weight: 500)
                    .foregroundColor(theme.text.secondary)
                    .monospacedDigit()
                Image(systemName: "chevron.up.chevron.down")
                    .glyphSize(.tiny, weight: .semibold)
                    .foregroundColor(theme.text.tertiary)
            }
            .frame(height: ImageOptionChipSurface.contentHeight)
        }
        .assignedPopover(isPresented: $showImageSizePicker, width: 252, accessibilityLabel: L("Output image size"), arrowEdge: .top) {
            imageSizePopover
        }
        .localizedHelp("Output image size")
    }

    private var imageSizePopover: some View {
        VStack(alignment: .leading, spacing: theme.space.s2) {
            Text("Image size", bundle: .module)
                .textStyle(.footnote, weight: 600)
                .foregroundColor(theme.text.tertiary)
                .padding(.horizontal, theme.space.s12)
                .padding(.top, theme.space.s12)
                .padding(.bottom, theme.space.s4)

            if ImageModelRequestPolicy.usesBundleParameters(selectedImagePickerItem?.imageCanonicalName) {
                Button {
                    imageComposerSettings.imageSizeWasExplicitlySet = false
                    showImageSizePicker = false
                } label: {
                    Text(localized: "Default")
                }.buttonStyle(.plain).padding(.horizontal, theme.space.s12).padding(.vertical, theme.space.s8)
            }
            if selectedImagePickerItem?.imageCanonicalName == "flux3-image-klein" {
                HStack {
                    Text(localized: "Width")
                    TextField("", value: $imageComposerSettings.width, format: .number.grouping(.never))
                        .onSubmit { snapFlux3ComposerSize() }
                }
                .settingsLandingAnchor("imageGeneration.width")
                .padding(.horizontal, theme.space.s12)
                HStack {
                    Text(localized: "Height")
                    TextField("", value: $imageComposerSettings.height, format: .number.grouping(.never))
                        .onSubmit { snapFlux3ComposerSize() }
                }
                .settingsLandingAnchor("imageGeneration.height")
                .padding(.horizontal, theme.space.s12)
            }
            ForEach(imageSizeOptions) { option in
                let isSelected =
                    (!ImageModelRequestPolicy.usesBundleParameters(selectedImagePickerItem?.imageCanonicalName)
                        || imageComposerSettings.hasExplicitImageSize)
                    && imageComposerSettings.width == option.width
                    && imageComposerSettings.height == option.height
                Button {
                    imageComposerSettings.width = option.width
                    imageComposerSettings.height = option.height
                    showImageSizePicker = false
                } label: {
                    HStack(alignment: .top, spacing: theme.space.s8) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .glyphSize(.caption, weight: .medium)
                            .foregroundColor(isSelected ? theme.text.primary : theme.text.tertiary)
                            .padding(.top, theme.space.s2)
                        VStack(alignment: .leading, spacing: theme.space.s2) {
                            Text(option.title)
                                .font(
                                    theme.font(
                                        size: theme.pointSize(.caption),
                                        weight: .semibold
                                    )
                                )
                                .foregroundColor(theme.text.primary)
                            Text(option.detail)
                                .textStyle(.micro)
                                .foregroundColor(theme.text.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, theme.space.s10)
                    .padding(.vertical, theme.space.s8)
                    .background(
                        RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                            .fill(isSelected ? theme.surface.selected : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .padding(.horizontal, theme.space.s6)
            }
        }
        .padding(.bottom, theme.space.s8)
        .frame(width: 252)
        .popoverCard()
    }

    private func stepperButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .glyphSize(.micro, weight: .bold)
                .foregroundColor(theme.text.secondary)
                .frame(width: 20, height: ImageOptionChipSurface.contentHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private func snapFlux3ComposerSize() {
        let policy = ImageModelRequestPolicy(canonical: "flux3-image-klein")
        let limits = selectedImagePickerItem?.imageRequestLimits
        imageComposerSettings.width = policy.snappedDimension(imageComposerSettings.width, limits: limits)
        imageComposerSettings.height = policy.snappedDimension(imageComposerSettings.height, limits: limits)
    }

    @ViewBuilder
    private var stepsChip: some View {
        if selectedImagePickerItem?.imageCanonicalName == "qwen-image-2.1-turbo" {
            Text("Fixed schedule", bundle: .module)
                .textStyle(.caption, weight: 600)
                .foregroundColor(theme.text.secondary)
                .modifier(ImageOptionChipSurface())
                .localizedHelp("Turbo uses the fixed sampling schedule from its bundle.")
        } else {
            adjustableStepsChip
        }
    }

    private var adjustableStepsChip: some View {
        HStack(spacing: theme.space.s4) {
            stepperButton("minus") {
                imageComposerSettings.steps = max(1, imageComposerSettings.steps - 1)
            }
            HStack(spacing: theme.space.s2) {
                if selectedImagePickerItem?.imageCanonicalName == "flux3-image-klein" {
                    TextField("", value: $imageComposerSettings.steps, format: .number.grouping(.never))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .frame(width: 36)
                        .accessibilityLabel(Text("Denoising steps", bundle: .module))
                        .textStyle(.caption, weight: 600)
                        .foregroundColor(theme.text.primary)
                        .monospacedDigit()
                } else {
                    Text("\(imageComposerSettings.steps)")
                        .textStyle(.caption, weight: 600)
                        .foregroundColor(theme.text.primary)
                        .monospacedDigit()
                }
                Text("steps", bundle: .module)
                    .fixedSize()
                    .textStyle(.footnote, weight: 500)
                    .foregroundColor(theme.text.tertiary)
            }
            stepperButton("plus") {
                imageComposerSettings.steps = selectedImagePickerItem?.imageCanonicalName == "flux3-image-klein"
                    ? imageComposerSettings.steps + 1 : min(50, imageComposerSettings.steps + 1)
            }
        }
        .modifier(ImageOptionChipSurface())
        .localizedHelp("Denoising steps")
        .settingsLandingAnchor("imageGeneration.steps")
    }

    private var cfgChip: some View {
        HStack(spacing: theme.space.s4) {
            Text("CFG", bundle: .module)
                .textStyle(.footnote, weight: 500)
                .foregroundColor(theme.text.tertiary)
            TextField(
                "",
                value: $imageComposerSettings.guidance,
                format: .number.precision(.fractionLength(1))
            )
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .frame(width: 28)
            .textStyle(.caption, weight: 600)
            .foregroundColor(theme.text.primary)
        }
        .modifier(ImageOptionChipSurface())
        .localizedHelp("Classifier-free guidance")
    }

    private var seedChip: some View {
        HStack(spacing: theme.space.s4) {
            Image(systemName: "number")
                .glyphSize(.footnote, weight: .medium)
                .foregroundColor(theme.text.tertiary)
            TextField("Seed", text: seedText)
                .textFieldStyle(.plain)
                .textStyle(.caption, weight: 500)
                .foregroundColor(theme.text.primary)
                // Hug the content so the chip starts compact and grows as the
                // seed is typed, with a small floor so the placeholder fits.
                .fixedSize()
                .frame(minWidth: 34)
        }
        .modifier(ImageOptionChipSurface())
        .localizedHelp("Optional numeric seed")
    }

    private var strengthChip: some View {
        HStack(spacing: theme.space.s4) {
            Text("Strength", bundle: .module)
                .textStyle(.footnote, weight: 500)
                .foregroundColor(theme.text.tertiary)
            TextField(
                "",
                value: $imageComposerSettings.strength,
                format: .number.precision(.fractionLength(2))
            )
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .frame(width: 32)
            .textStyle(.caption, weight: 600)
            .foregroundColor(theme.text.primary)
        }
        .modifier(ImageOptionChipSurface())
        .localizedHelp("How strongly the prompt changes the source image")
    }

    /// Chip-styled button that opens the negative-prompt editor. Shows the
    /// current value (when set) or a call to add one.
    private var negativePromptButton: some View {
        let value = imageComposerSettings.negativePrompt.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let hasValue = !value.isEmpty
        // The chip row scrolls at its ideal width, so cap the label by length.
        let maxLabelLength = 32
        let label = value.count > maxLabelLength ? String(value.prefix(maxLabelLength - 1)) + "…" : value
        return Button {
            negativePromptDraft = imageComposerSettings.negativePrompt
            showNegativePromptAlert = true
        } label: {
            HStack(spacing: theme.space.s4) {
                Image(systemName: hasValue ? "minus.circle.fill" : "minus.circle")
                    .glyphSize(.footnote, weight: .medium)
                    .foregroundColor(hasValue ? theme.text.primary : theme.text.tertiary)
                Text(hasValue ? label : L("Add a negative prompt"))
                    .font(
                        theme.font(
                            size: theme.pointSize(.caption),
                            weight: hasValue ? .medium : .regular
                        )
                    )
                    .foregroundColor(hasValue ? theme.text.secondary : theme.text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .modifier(ImageOptionChipSurface())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .localizedHelp("Terms to avoid during image generation")
    }

    /// Multiline editor rendered as the negative-prompt alert's accessory.
    /// Wrapped in its own view so it can own a `@FocusState` that resolves in
    /// the alert host's hierarchy (where the accessory actually renders).
    private var negativePromptAccessory: AnyView {
        AnyView(NegativePromptEditor(text: $negativePromptDraft))
    }

    /// Self-contained editor for the negative-prompt alert. Owns its focus so
    /// the field is focused on present, and shows a subtle border that picks up
    /// the accent while focused.
    private struct NegativePromptEditor: View {
        @Environment(\.theme) private var theme
        @Binding var text: String
        @FocusState private var focused: Bool

        var body: some View {
            TextField(
                text: $text,
                prompt: Text("e.g. blurry, low quality, extra fingers", bundle: .module),
                axis: .vertical
            ) {
                Text("Negative prompt", bundle: .module)
            }
            .textFieldStyle(.plain)
            .lineLimit(3, reservesSpace: true)
            .textStyle(.body)
            .foregroundColor(theme.text.primary)
            .focused($focused)
            .padding(theme.space.s10)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                    .fill(theme.surface.subtle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                    .strokeBorder(
                        focused ? theme.border.focus : theme.border.default,
                        lineWidth: focused ? theme.stroke.focus : theme.stroke.default
                    )
            )
            .animation(theme.motion.quick, value: focused)
            .onAppear {
                // Defer so the alert's present animation settles before the
                // field grabs focus (otherwise the focus can be dropped).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    focused = true
                }
            }
        }
    }

    /// The existing "@" file menu, floated over the input card.
    private var composerPopupOverlay: some View {
        VStack(spacing: theme.space.s4) {
            atFileMenuPopupView
        }
    }

    /// The "@" file completion popup, extracted from `composerPopupOverlay` to
    /// keep that view builder within the Swift type-checker's reach.
    @ViewBuilder
    private var atFileMenuPopupView: some View {
        if showAtPopup {
            AtFileMenuPopup(
                items: atMenuItems,
                status: atMenuStatus,
                deniedDirectoryName: (atMenuDirectory as NSString).lastPathComponent,
                emptyMessage: atMenuIsFiltering ? L("No matching files") : L("This folder is empty"),
                selectedIndex: $atSelectedIndex,
                onSelect: applyAtItem,
                onGrantAccess: grantAtMenuAccess
            )
            .transition(
                .asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)),
                    removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom))
                )
            )
        }
    }

    private var composerPlaceholderTopInset: CGFloat {
        let font = composerTheme.assignedNativeFont("component.library.21.text", fallback: theme.nsFont(.body))
        return 2 + ThemeTextMetrics.extraLeading(for: font,
            lineHeight: composerTheme.assignedLineHeight("component.library.21.text", fallback: theme.lineHeight(.body))) / 2
    }

    private var textInputArea: some View {
        EditableTextView(
            text: localTextBinding,
            theme: composerTheme,
            typographyAssignment: "component.library.21.text",
            textColor: composerTheme.text.primary,
            cursorColor: composerCursorColor,
            isFocused: $isFocused,
            isComposing: $isComposing,
            maxHeight: maxHeight,
            focusController: textViewFocusController,
            isEditable: composerEditable,
            spellCheckEnabled: spellCheckEnabled,
            onCommit: { handleInputCommit() },
            onShiftCommit: nil,
            onArrowUp: { handleInputArrowUp() },
            onArrowDown: { handleInputArrowDown() },
            onEscape: (showSlashPopup || showAtPopup) ? { handlePopupEscape() } : nil,
            onPasteText: { pasted in
                // Off in Settings ▸ Conversation ▸ Collapse Long Pastes: return false so
                // the text view inserts the paste as plain text. Dictation tools that
                // paste and then read the field back over Accessibility need this
                // (#3271).
                guard collapseLongPastes, pasted.utf8.count >= Self.pastedContentThreshold else { return false }
                withAnimation(theme.motion.springAnimation) {
                    pendingAttachments.append(.pastedContent(pasted))
                }
                return true
            }
        )
        .frame(maxHeight: maxHeight)
        // A different conversation now backs the composer — drop any
        // in-flight history navigation so its index can't recall entries
        // from the previous chat.
        .onChange(of: inputHistoryKey) { _, _ in
            inputHistoryState = ChatInputHistoryState()
        }
        .overlay(alignment: .topLeading) {
            // Placeholder - uses theme body size
            if showPlaceholder {
                Text(placeholderText)
                    .id(placeholderIdeas.isEmpty ? "chat-placeholder" : placeholderText)
                    .transition(.opacity)
                    .composerPlaceholderTypography(theme: composerTheme)
                    .foregroundColor(composerTheme.assignedColor("component.input.placeholder", fallback: theme.text.placeholder))
                    .modifier(WorkflowPlaceholderGlimmer(
                        phrase: placeholderText,
                        enabled: !placeholderIdeas.isEmpty && !reducePlaceholderMotion,
                        color: composerTheme.text.primary
                    ))
                    .padding(.leading, theme.space.s6)
                    // TextKit sets the whole line-height gap above the first
                    // line; the line box above splits it, so add the other half.
                    .padding(.top, composerPlaceholderTopInset)
                    .allowsHitTesting(false)
            }
        }
        .task(id: showPlaceholder && placeholderIdeas.count > 1 && !reducePlaceholderMotion) {
            guard showPlaceholder, placeholderIdeas.count > 1, !reducePlaceholderMotion else {
                placeholderIdeaIndex = 0
                return
            }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard !Task.isCancelled else { return }
                withAnimation(theme.motion.quick) {
                    placeholderIdeaIndex = (placeholderIdeaIndex + 1) % placeholderIdeas.count
                }
            }
        }
        .background(
            PasteboardImageMonitor(
                pasteTarget: { textViewFocusController.textView },
                supportsImages: mediaCapabilities.supportsImage,
                onImagePaste: { imageData in
                    withAnimation(theme.motion.springAnimation) {
                        pendingAttachments.append(.image(imageData))
                    }
                },
                onUnsupportedImagePaste: {
                    // Same message the file picker / drop path shows; the
                    // paste used to vanish without a word.
                    ToastManager.shared.error(
                        L("Cannot attach image"),
                        message: mediaCapabilityDescriptor.rejectionMessage(for: .image)
                    )
                }
            )
        )
    }

    // MARK: - Button Bar

    private var buttonBar: some View {
        HStack(spacing: theme.catalogLayoutMetric("component.library.22.elements.layout.floatingInputCard.buttonBar.horizontalGap", inheriting: theme.assignedMetric("component.library.22.gap", fallback: theme.space.s8))) {
            HStack(spacing: theme.catalogLayoutMetric("component.library.22.elements.layout.floatingInputCard.buttonBar.horizontalGap2", inheriting: theme.assignedMetric("component.library.22.gap", fallback: theme.space.s6))) {
                mediaButton
                if !pickerItems.isEmpty || isModelPinned || isHarnessAgent || !pickerHarnessRuntimes.isEmpty {
                    modelSelectorChip
                }
            }.catalogLayoutTarget("component.library.22.elements.layout.floatingInputCard.buttonBar.horizontalGap2")

            Spacer()

            HStack(spacing: theme.catalogLayoutMetric("component.library.22.elements.layout.floatingInputCard.buttonBar.horizontalGap3", inheriting: theme.assignedMetric("component.library.22.gap", fallback: theme.space.s8))) {
                contextBudgetRing
                FloatingVoiceButton(
                    voiceInputEnabled: voiceConfig.voiceInputEnabled,
                    isStreaming: isStreaming,
                    startVoiceInput: startVoiceInput
                )
                if isStreaming {
                    if queuedSend != nil {
                        sendNowButton
                    } else if !isPrivacyReviewSheetVisible && canSend {
                        sendQueueButton
                    }
                    // The trailing Send position becomes Stop while working.
                    // Privacy review keeps its existing sheet-owned Cancel action.
                    if !isPrivacyReviewSheetVisible {
                        stopButton
                    }
                } else {
                    sendButton
                }
            }.catalogLayoutTarget("component.library.22.elements.layout.floatingInputCard.buttonBar.horizontalGap3")
        }.catalogLayoutTarget("component.library.22.elements.layout.floatingInputCard.buttonBar.horizontalGap")
    }

    // MARK: - Action Buttons

    private var mediaMenuItems: [InputActionMenuButton.Item] {
        var items: [InputActionMenuButton.Item] = [
                // Mode 2 (remote agent run): the turn executes on the host's
                // machine and no local system prompt or tools are sent, so a
                // folder picked here would never reach the agent. Keep the row
                // visible but disabled so the flow fails loudly instead of
                // silently accepting a folder that is then dropped.
                .init(
                    icon: "folder",
                    title: Text("Add folder", bundle: .module),
                    disabledReason: isRemoteAgentRun
                        ? Text("Shared agents can't use folders on this Mac.", bundle: .module)
                        : folderLockedByHarnessTurn
                            ? Text("The folder can change after this reply finishes.", bundle: .module)
                            : nil
                ) {
                    selectFolder()
                },
                .init(icon: "paperclip", title: Text("Attach files", bundle: .module)) {
                    pickAttachment()
                },
        ]
        if allowsWorkflowSelection {
            items.append(.init(icon: "point.forward.to.point.capsulepath", title: Text("Add Workflow", bundle: .module)) {
                showWorkflowPicker = true
            })
        }
        items.append(.init(icon: "slash.forward", title: Text("Slash commands", bundle: .module)) {
            openSlashCommands()
        })
        return items
    }

    private var mediaButton: some View {
        InputActionMenuButton(
            icon: "plus",
            help: "Add to chat",
            items: mediaMenuItems,
            footer: nil
        )

    }

    private func openSlashCommands() {
        guard !showSlashPopup else { return }
        if localText.isEmpty { localText = "/" }
        else if localText.last?.isWhitespace == true { localText += "/" }
        else { localText += " /" }
        isFocused = true
    }

    private var slashCommandButton: some View {
        SlashCommandTriggerButton(isActive: showSlashPopup, action: openSlashCommands)
    }

    private var stopButton: some View {
        SendButton(canSend: true, isStopping: true, action: onStop)
    }

    private var sendButton: some View {
        SendButton(canSend: canSend, action: syncAndSend)
    }

    /// Streaming + empty queue: pressing Send queues the message. Same
    /// dispatcher as `sendButton` (`syncAndSend → onSend`); the parent
    /// notices `isStreaming == true` and routes to `enqueueSend`.
    private var sendQueueButton: some View {
        SendQueueButton(canSend: canSend, action: syncAndSend)
    }

    /// Streaming + a queued message present: pressing this stops the
    /// current run and dispatches the queued payload immediately.
    private var sendNowButton: some View {
        SendNowButton(action: dispatchQueuedNow)
    }

    private func dispatchQueuedNow() {
        // Stop -> send has a longer focus-lock cascade than an ordinary Send.
        textViewFocusController.lockFocus(for: 0.4)
        onSendNow?()
    }

    // MARK: - Card Styling

    /// Opaque raised surface (color.surface.raised). No component glass and no
    /// accent wash; the window material behind the chat view is the only blur.
    private var composerCursorColor: Color {
        composerTheme.border.focus
    }

    @ViewBuilder private var cardBackground: some View {
        RoundedRectangle(cornerRadius: composerRadius, style: .continuous)
            .fill(composerTheme.surface.raised)
    }

    private var effectiveBorderStyle: AnyShapeStyle {
        if isDragOver {
            return AnyShapeStyle(composerTheme.border.focus)
        }
        return AnyShapeStyle(composerTheme.border.default)
    }

}

// MARK: - Clipboard Animation Shape

/// A custom capsule shape that starts its path at the top center to allow for clockwise border sweeps
/// Owns a hover flag in its own view node so hover-in/out re-renders only the
/// wrapped subtree. Hover state on `FloatingInputCard` itself re-evaluates the
/// card's entire body per mouse transition (Sentry app-hang cluster).
private struct HoverScope<Content: View>: View {
    @Environment(\.theme) private var theme
    var animation: Animation?
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovered = false

    var body: some View {
        content(hovered)
            .onHover { hovering in
                withAnimation(animation ?? theme.motion.quick) {
                    hovered = hovering
                }
            }
    }
}

/// Self-contained 0.4↔1.0 opacity pulse while `active`. The animation state
/// lives here (not on the card), and `.task(id:)` cancels the loop when
/// `active` flips or the view leaves the hierarchy.
private struct PulsingOpacity: ViewModifier {
    @Environment(\.theme) private var theme
    let active: Bool
    @State private var amount: CGFloat = 1.0

    func body(content: Content) -> some View {
        content
            .opacity(active ? amount : 1.0)
            .task(id: active) {
                guard active else {
                    amount = 1.0
                    return
                }
                while !Task.isCancelled {
                    withAnimation(theme.motion.slow) { amount = 0.4 }
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard !Task.isCancelled else { break }
                    withAnimation(theme.motion.slow) { amount = 1.0 }
                    try? await Task.sleep(nanoseconds: 800_000_000)
                }
            }
    }
}

/// The clipboard chip's arrival animation — clockwise border sweep, trailing
/// glow, and the hover/pulse-aware shadow — with the animation state scoped
/// to this modifier so each pulse frame re-renders only the chip.
private struct ClipboardPulseSweep: ViewModifier {
    let hovered: Bool
    /// Rising edge starts a sweep (new clipboard content just arrived).
    let trigger: Bool
    @Environment(\.theme) private var theme
    @State private var amount: CGFloat = 0.0
    @State private var opacity: Double = 0.0

    func body(content: Content) -> some View {
        content
            .overlay(
                // animated clockwise border sweep using custom shape to fix vertical frame issue
                ClipboardSweepShape()
                    .trim(from: 0, to: amount)
                    .stroke(
                        theme.action.primary.default.background,
                        style: StrokeStyle(lineWidth: theme.stroke.default, lineCap: .round)
                    )
                    .opacity(opacity)
            )
            .overlay(
                // accompanying glow that follows the sweep
                ClipboardSweepShape()
                    .trim(from: 0, to: amount)
                    .stroke(theme.border.focus, style: StrokeStyle(lineWidth: theme.stroke.focus * 1.5, lineCap: .round))
                    .opacity(opacity * 0.4)
                    .blur(radius: 3)
            )
            .onAppear {
                if trigger { pulse() }
            }
            .onChange(of: trigger) { _, newValue in
                if newValue { pulse() }
            }
    }

    private func pulse() {
        // reset state immediately and hide animation layers
        amount = 0
        opacity = 0

        // small delay to ensure the window transition is complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            withAnimation(theme.motion.quick) {
                opacity = 1.0
            }

            // animate the stroke clockwise around the capsule
            withAnimation(theme.motion.slow) {
                amount = 1.0
            }

            // fade out after completion
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                withAnimation(theme.motion.slow) {
                    opacity = 0
                }
            }
        }
    }
}

struct ClipboardSweepShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = rect.height / 2

        // Start at top center (12 o'clock)
        path.move(to: CGPoint(x: rect.midX, y: 0))

        // Top right straight line
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: 0))

        // Right semi-circle
        path.addArc(
            center: CGPoint(x: rect.maxX - radius, y: radius),
            radius: radius,
            startAngle: Angle(degrees: -90),
            endAngle: Angle(degrees: 90),
            clockwise: false
        )

        // Bottom straight line
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))

        // Left semi-circle
        path.addArc(
            center: CGPoint(x: rect.minX + radius, y: radius),
            radius: radius,
            startAngle: Angle(degrees: 90),
            endAngle: Angle(degrees: 270),
            clockwise: false
        )

        // Top left straight line back to center
        path.addLine(to: CGPoint(x: rect.midX, y: 0))

        return path
    }
}

// MARK: - Cached Image Thumbnail

/// A thumbnail view that caches the decoded NSImage to prevent expensive re-decoding on every parent re-render
struct CachedImageThumbnail: View {
    let imageData: Data
    let size: CGFloat
    let onRemove: () -> Void
    /// Tapping the thumbnail (not the remove badge) opens a full-size preview.
    var onTap: (() -> Void)? = nil

    @State private var cachedImage: NSImage?
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if let nsImage = cachedImage {
                let imageHeight = max(1, AttachmentInspectionStyle.imageHeight(theme, fallback: size) - 2 * AttachmentInspectionStyle.imageMetric("padding", 0, theme))
                let thumbSize = AttachmentThumbnailLayout.size(for: nsImage, height: imageHeight)
                Image(nsImage: nsImage)
                    .resizable()
                    .renderingMode(.original)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: thumbSize.width, height: thumbSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: AttachmentInspectionStyle.imageMetric("radius", theme.radius.medium, theme), style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AttachmentInspectionStyle.imageMetric("radius", theme.radius.medium, theme), style: .continuous)
                            .strokeBorder(AttachmentInspectionStyle.imageColor("border", theme.border.subtle, theme), lineWidth: AttachmentInspectionStyle.imageMetric("borderWidth", theme.stroke.default, theme))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: AttachmentInspectionStyle.imageMetric("radius", theme.radius.medium, theme), style: .continuous))
                    .modifier(TappableThumbnailModifier(onTap: onTap))
            } else {
                // Square placeholder — aspect is unknown until decode completes.
                RoundedRectangle(cornerRadius: AttachmentInspectionStyle.imageMetric("radius", theme.radius.medium, theme), style: .continuous)
                    .fill(AttachmentInspectionStyle.imageColor("background", theme.surface.subtle, theme))
                    .frame(width: max(1, AttachmentInspectionStyle.imageHeight(theme, fallback: size) - 2 * AttachmentInspectionStyle.imageMetric("padding", 0, theme)),
                        height: max(1, AttachmentInspectionStyle.imageHeight(theme, fallback: size) - 2 * AttachmentInspectionStyle.imageMetric("padding", 0, theme)))
            }

        }
        .overlay(alignment: .topTrailing) {
            SettingsIconButton("xmark", help: "Remove image attachment", size: .extraExtraSmall, role: .secondary, action: onRemove)
                .pointingHandCursor()
                .offset(x: theme.space.s4, y: -theme.space.s4)
        }
        .padding(AttachmentInspectionStyle.imageMetric("padding", 0, theme))
        .modifier(AttachmentImageChrome())
        .task(id: imageData) {
            cachedImage = NSImage(data: imageData)
        }
    }
}

/// A pending image attachment selected for full-size preview. Carries the raw
/// bytes (not a decoded `NSImage`) so it stays `Identifiable` and `Equatable`
/// for `.sheet(item:)`; the sheet decodes lazily.
private struct PendingImagePreview: Identifiable, Equatable {
    let id: UUID
    let data: Data
}

/// Full-size preview for a composer image attachment, reusing the chat's
/// zoom/pan/save viewer. Decoding runs off the main thread via `ChatImageCache`
/// (a full-size image decode/rasterize on the main actor would stall the UI and
/// trip app-hang reports), so the viewer fills in once the image is ready.
private struct PendingImagePreviewSheet: View {
    let imageData: Data
    let imageId: String
    let onDismiss: () -> Void

    @State private var image: NSImage?

    var body: some View {
        ImageFullScreenView(image: image, altText: "", onDismiss: onDismiss)
            .imageFullScreenSheetPresentation()
            .task(id: imageId) {
                if let cached = ChatImageCache.shared.cachedImage(for: imageId) {
                    image = cached
                } else {
                    image = await ChatImageCache.shared.decode(imageData, id: imageId)
                }
            }
    }
}

/// Adds the tap-to-preview gesture and pointing-hand cursor to an image
/// thumbnail only when an `onTap` is supplied, so non-interactive thumbnails
/// keep the default cursor and hit-testing.
private struct TappableThumbnailModifier: ViewModifier {
    let onTap: (() -> Void)?

    func body(content: Content) -> some View {
        if let onTap {
            content
                .onTapGesture { onTap() }
                .pointingHandCursor()
        } else {
            content
        }
    }
}

// MARK: - Pasteboard Image Monitor

/// Monitors for Cmd+V paste events and checks if the pasteboard contains an image
struct PasteboardImageMonitor: NSViewRepresentable {
    let pasteTarget: () -> NSView?
    let supportsImages: Bool
    let onImagePaste: (Data) -> Void
    var onUnsupportedImagePaste: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let view = PasteMonitorView()
        view.pasteTarget = pasteTarget
        view.supportsImages = supportsImages
        view.onImagePaste = onImagePaste
        view.onUnsupportedImagePaste = onUnsupportedImagePaste
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? PasteMonitorView {
            view.pasteTarget = pasteTarget
            view.supportsImages = supportsImages
            view.onImagePaste = onImagePaste
            view.onUnsupportedImagePaste = onUnsupportedImagePaste
        }
    }
}

class PasteMonitorView: NSView {
    /// Image bytes or an image file URL on the pasteboard. Uses the same
    /// direct accessors as the paste path (no type enumeration — Sentry
    /// APPLE-MACOS-43).
    static func pasteboardHasImage(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.data(forType: .png) != nil || pasteboard.data(forType: .tiff) != nil {
            return true
        }
        for type in [NSPasteboard.PasteboardType.fileURL, NSPasteboard.PasteboardType("public.file-url")] {
            guard let raw = pasteboard.string(forType: type), let url = URL(string: raw), url.isFileURL,
                let uti = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier
            else { continue }
            if UTType(uti)?.conforms(to: .image) == true { return true }
        }
        return false
    }

    var pasteTarget: (() -> NSView?)?

    /// Local event monitors see every app window. Only the exact composer
    /// text view that owns keyboard focus may attach an image or reject it.
    func ownsPaste(in eventWindow: NSWindow?) -> Bool {
        guard let window, eventWindow === window, let target = pasteTarget?(),
            target.window === window, window.firstResponder === target
        else { return false }
        return true
    }

    var supportsImages: Bool = false
    var onImagePaste: ((Data) -> Void)?
    var onUnsupportedImagePaste: (() -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self, self.ownsPaste(in: event.window) else { return event }
                // Check for Cmd+V
                if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "v" {
                    if self.handlePasteIfImage() {
                        return nil  // Consume the event
                    }
                }
                return event
            }
        }
    }

    override func removeFromSuperview() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        super.removeFromSuperview()
    }

    private func handlePasteIfImage() -> Bool {
        let pasteboard = NSPasteboard.general

        guard supportsImages else {
            // Not consumed: any text on the pasteboard still pastes normally.
            // An image-only payload used to disappear with no explanation.
            if Self.pasteboardHasImage(pasteboard) { onUnsupportedImagePaste?() }
            return false
        }

        // Avoid pasteboard type enumeration and object-conversion APIs here.
        // Sentry APPLE-MACOS-43 showed AppKit pasteboard conversion can race
        // paste monitoring on Cmd+V.
        if let imageData = pasteboard.data(forType: .png) {
            onImagePaste?(imageData)
            return true
        }

        if let imageData = pasteboard.data(forType: .tiff) {
            // Consume the event now and convert asynchronously: the decode
            // and PNG re-encode of a large pasted image block for seconds,
            // so they run off the main actor.
            Task { @MainActor [weak self] in
                let pngData = await Task.detached(priority: .userInitiated) {
                    () -> Data? in
                    guard let nsImage = NSImage(data: imageData) else { return nil }
                    return nsImage.pngData()
                }.value
                if let pngData {
                    self?.onImagePaste?(pngData)
                }
            }
            return true
        }

        let fileURLTypes: [NSPasteboard.PasteboardType] = [
            .fileURL,
            NSPasteboard.PasteboardType("public.file-url"),
        ]
        for type in fileURLTypes {
            guard let raw = pasteboard.string(forType: type),
                let url = URL(string: raw),
                url.isFileURL
            else { continue }
            if let uti = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier,
                UTType(uti)?.conforms(to: .image) == true
            {
                // Consume the event now and convert asynchronously: reading
                // and re-encoding a large image file blocks for seconds, so
                // it runs off the main actor.
                Task { @MainActor [weak self] in
                    let pngData = await Task.detached(priority: .userInitiated) {
                        () -> Data? in
                        guard let data = try? Data(contentsOf: url),
                            let nsImage = NSImage(data: data)
                        else { return nil }
                        return nsImage.pngData()
                    }.value
                    if let pngData {
                        self?.onImagePaste?(pngData)
                    }
                }
                return true
            }
        }

        return false
    }
}

// MARK: - NSImage PNG Conversion

extension NSImage {
    /// Convert NSImage to PNG data
    func pngData() -> Data? {
        guard let tiffData = self.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}

// MARK: - Popover Card Chrome

/// Shared rounded card chrome for the composer's menu/selector popovers
/// (Context Budget, router balance, model options) so they read as one family.
/// Opaque overlay surface + default border + overlay elevation, all from the
/// semantic theme roles.
struct PopoverCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 10

    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(16, enabled: baseComponentEnabled) }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.catalogMetric("radius", fallback: cornerRadius), style: .continuous)
        content.environment(\.theme, theme)
            .foregroundColor(theme.text.primary)
            .frame(minHeight: theme.catalogMetric("height", fallback: 0))
            .presentationCornerRadius(theme.catalogMetric("radius", fallback: cornerRadius))
            .presentationBackground(theme.surface.overlay)
            .background { shape.fill(theme.surface.overlay) }
            .clipShape(shape)
            .overlay { shape.strokeBorder(theme.border.default, lineWidth: theme.stroke.default) }
            .themeElevation(theme.elevation.overlay)
    }
}

extension View {
    /// Applies the shared composer popover card chrome.
    func popoverCard(cornerRadius: CGFloat = 10) -> some View {
        modifier(PopoverCardModifier(cornerRadius: cornerRadius))
    }
}

// MARK: - Context Breakdown Popover

/// A roll-up of one or more breakdown entries shown as a single legend row.
/// Multi-entry groups (the system prompt's many sections) collapse behind a
/// disclosure so the popover reads as a handful of categories by default and
/// only fans out to per-section detail on demand. Single-entry groups (Tools,
/// Memory, …) render as a plain row.
struct ContextBudgetUtilization: Equatable {
    let usedTokens: Int
    let maxTokens: Int?
    let fraction: Double?
    let percent: Int?
    let remainingTokens: Int?
}

/// Normalizes the popover's window-usage values in one pure, testable place.
/// Invalid/unknown ceilings remain absent rather than implying a false limit.
func computeContextBudgetUtilization(
    usedTokens: Int,
    maxTokens: Int?
) -> ContextBudgetUtilization {
    let used = max(0, usedTokens)
    guard let maxTokens, maxTokens > 0 else {
        return ContextBudgetUtilization(
            usedTokens: used,
            maxTokens: nil,
            fraction: nil,
            percent: nil,
            remainingTokens: nil
        )
    }

    let fraction = min(Double(used) / Double(maxTokens), 1)
    return ContextBudgetUtilization(
        usedTokens: used,
        maxTokens: maxTokens,
        fraction: fraction,
        percent: Int((fraction * 100).rounded()),
        remainingTokens: max(0, maxTokens - used)
    )
}

private struct BudgetGroup: Identifiable {
    let id: String
    let label: String
    let tint: ContextBreakdown.Tint
    let entries: [ContextBreakdown.Entry]

    var tokens: Int { entries.reduce(0) { $0 + $1.tokens } }
    var isExpandable: Bool { entries.count > 1 }
}

/// The composer's context-budget panel, presented in the same arrowless,
/// themed card as the wallet and model picker, aligned to the trailing edge
/// of the context ring.
private struct ContextBreakdownPopover: View {
    let breakdown: ContextBreakdown
    /// Usable conversation budget (model maximum × safety margin).
    let maxTokens: Int?
    /// Raw maximum reported by the model bundle/provider fallback.
    let modelMaxTokens: Int?
    let modelLimitSource: AgentLoopBudget.ContextWindowSource?
    let isStreaming: Bool
    let isNearLimit: Bool
    let isHardOverflow: Bool
    let formatTokenCount: (Int) -> String
    /// Session compaction state — drives the inline progress / result row.
    var compactionState: ContextCompactionUIState = .idle
    /// True when the manual "Compact conversation" button should show
    /// (an uncovered older span exists and no turn is streaming).
    var canCompact: Bool = false
    var onCompact: (() -> Void)? = nil
    /// Live disk-cache usage for the footer readout. nil when the disk cache is
    /// off or no quota is configured, in which case the section is hidden
    /// entirely rather than rendering a meaningless 0 GB.
    var diskCache: DiskCacheUsage? = nil
    /// The chat this chip belongs to; the disk-cache note is shown only when
    /// the cap took this chat's rows.
    var currentSessionKey: String? = nil
    /// Reports the card height to request: the content's natural height,
    /// capped at `maxPopoverHeight`.
    var onHeightChange: (CGFloat) -> Void = { _ in }

    /// Fraction of the configured quota at which the footer starts warning.
    static let diskCacheWarnFraction: Double = 0.75

    @Environment(\.theme) private var theme
    @Environment(\.anchoredCardMetrics) private var cardMetrics

    /// Which multi-entry groups are drilled open. Starts empty so the popover
    /// opens in its compact, grouped form.
    @State private var expandedGroups: Set<String> = []

    /// Cap on the popover height (the model picker's cap); longer breakdowns
    /// scroll past this.
    private let maxPopoverHeight: CGFloat = 480

    private var utilization: ContextBudgetUtilization {
        computeContextBudgetUtilization(
            usedTokens: breakdown.total,
            maxTokens: maxTokens
        )
    }

    private var statusColor: Color {
        if isHardOverflow { return theme.status.error.foreground }
        if isNearLimit { return theme.status.warning.foreground }
        return theme.status.info.foreground
    }

    private var limitLabel: String? {
        if isHardOverflow { return L("Over limit") }
        if isNearLimit { return L("Near limit") }
        return nil
    }

    /// Each row's share of the *current* total, not of the model's full
    /// window — the window is typically so large (e.g. 262k) that share-of-
    /// budget rounds every category to 0%. Share-of-total instead sums to
    /// ~100% and tracks the stacked bar, which fills the whole track.
    private func percent(_ tokens: Int) -> String {
        let total = breakdown.total
        guard total > 0 else { return "0%" }
        let pct = Int((Double(tokens) / Double(total) * 100).rounded())
        return "\(pct)%"
    }

    /// IDs in `breakdown.context` that read as their own category rather than
    /// folding into the "System Prompt" roll-up. Order here is their canonical
    /// display order beneath the system-prompt group.
    private static let standaloneContextIDs = ["memory", "screenContext", "tools"]

    /// `breakdown.context` rolled into display groups: every manifest prompt
    /// section collapses into one "System Prompt" group; Memory, Screen
    /// Context, and Tools stay as their own rows (they're large and the user
    /// reasons about them individually).
    private var contextGroups: [BudgetGroup] {
        let standalone = Set(Self.standaloneContextIDs)
        var groups: [BudgetGroup] = []

        let sections = breakdown.context.filter { !standalone.contains($0.id) }
        if !sections.isEmpty {
            groups.append(
                BudgetGroup(id: "systemPrompt", label: L("System Prompt"), tint: .indigo, entries: sections)
            )
        }
        for id in Self.standaloneContextIDs {
            if let entry = breakdown.context.first(where: { $0.id == id }) {
                groups.append(BudgetGroup(id: entry.id, label: entry.label, tint: entry.tint, entries: [entry]))
            }
        }
        return groups
    }

    /// Stacked-bar segments — one block per individual entry (every prompt
    /// section, Tools, Memory, and each message row) so the bar shows the full
    /// breakdown. The legend collapses these into groups; the bar does not.
    private var barSegments: [(id: String, tint: ContextBreakdown.Tint, tokens: Int)] {
        breakdown.allEntries
            .filter { $0.tokens > 0 }
            .map { (id: $0.id, tint: $0.tint, tokens: $0.tokens) }
    }

    /// One-line italic notice rendered above the entry list when the
    /// composer auto-disabled features for a small-context model.
    /// `nil` collapses the row entirely so normal-sized models render
    /// the same popover they always did.
    private var autoDisableNotice: String? {
        guard let info = breakdown.disable,
            info.disabledTools || info.disabledMemory
        else { return nil }
        let modelLabel =
            info.modelId.flatMap { id in
                id.caseInsensitiveCompare("foundation") == .orderedSame
                    || id.caseInsensitiveCompare("default") == .orderedSame
                    ? "Foundation" : id
            } ?? "this model"
        let ctxBlurb = info.contextLength.map { "(~\(formatTokenCount($0)) ctx)" } ?? ""
        let what: String
        switch (info.disabledTools, info.disabledMemory) {
        case (true, true): what = "Tools and memory"
        case (true, false): what = "Tools"
        case (false, true): what = "Memory"
        case (false, false): return nil
        }
        return "\(what) auto-disabled — \(modelLabel) \(ctxBlurb) is too small."
    }

    private func color(for tint: ContextBreakdown.Tint) -> Color {
        theme.dataInk(tint.dataInk)
    }

    // MARK: - Body

    var body: some View {
        // The card hugs its content up to `maxPopoverHeight`; a long
        // "System Prompt" drill-down scrolls past that.
        ScrollView(.vertical, showsIndicators: false) {
            contentStack
                .padding(PickerCardMetrics.padding)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    ceil(geometry.size.height)
                } action: { height in
                    onHeightChange(min(height, maxPopoverHeight))
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(
            width: cardMetrics?.visibleSize.width ?? PickerCardMetrics.infoCardWidth,
            height: cardMetrics?.visibleSize.height
        )
        .pickerCardSurface()
    }

    /// The popover's content column. Extracted so `body` can wrap it in a
    /// height-bounded `ScrollView`.
    private var contentStack: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            PickerCardHeading(title: L("Context budget")) { statusAccessory }

            VStack(alignment: .leading, spacing: PickerCardMetrics.infoSectionSpacing) {
                hero

                if let notice = autoDisableNotice {
                    autoDisableRow(notice)
                }

                if !contextGroups.isEmpty || !breakdown.messages.isEmpty {
                    breakdownSection
                }

                // `isDisabled` has to pass this gate on its own: a switched-off
                // tier reports maxBytes 0, and an empty cache directory reports
                // usedBytes 0, so the size test alone would hide the "Off" row it
                // exists to show.
                if let diskCache,
                    diskCache.isDisabled || diskCache.usedBytes > 0 || diskCache.maxBytes > 0
                {
                    diskCacheSection(diskCache)
                }

                VStack(alignment: .leading, spacing: theme.space.s0) {
                    if showsCompactionSection {
                        compactionSection
                    }
                    contextWindowCapLink
                }
            }
        }
    }

    /// Status beside the heading. Usage itself lives in the hero, so this
    /// only speaks up for a limit warning or a live turn.
    @ViewBuilder
    private var statusAccessory: some View {
        if let limitLabel {
            Text(verbatim: limitLabel)
                .textStyle(.label)
                .foregroundStyle(statusColor)
        } else if isStreaming {
            HStack(spacing: theme.space.s4) {
                Circle()
                    .fill(theme.status.success.foreground)
                    .frame(width: 6, height: 6)
                Text("Live", bundle: .module)
                    .textStyle(.bodySmall)
                    .foregroundStyle(theme.text.secondary)
            }
        }
    }

    private var contextWindowCapLink: some View {
        PickerCardTextLink(title: L("Open Context Window Cap"), icon: "arrow.up.right") {
            ManagementStateManager.shared.serverSectionRequest = "cache"
            SettingsHighlightCoordinator.shared.request("settings.chat.contextLength")
            AppDelegate.shared?.showManagementWindow(initialTab: .server)
        }
        .localizedHelp("Open Settings… (⌘,) → Server → Settings → Cache → Context Window Cap")
    }

    // MARK: - Disk cache

    /// Footer readout for the on-SSD prompt cache: how much it holds, against
    /// what cap, warning once it nears that cap.
    ///
    /// This exists because the cap used to be a flat 10 GB that could not hold
    /// one full-context conversation of a 27B, and nothing surfaced that. The
    /// cache silently thrashed and the only symptom was decode slowing down as
    /// the conversation grew. Showing the number makes eviction observable
    /// instead of inferred.
    private func diskCacheSection(_ usage: DiskCacheUsage) -> some View {
        let fraction = usage.usedFraction
        // A full cache is an LRU's steady state, not a problem; the tint and
        // the note appear only when the cap took THIS chat's saved progress.
        let warn = usage.pressureAffects(session: currentSessionKey)
        let tint = warn ? theme.status.warning.foreground : theme.status.info.foreground
        return VStack(alignment: .leading, spacing: theme.space.s0) {
            PickerCardSectionTitle(title: L("Disk cache")) {
                Text(verbatim: usage.headlineLabel)
                    .fontWeight(.regular)
                    .monospacedDigit()
                    .foregroundStyle(warn ? tint : theme.text.secondary)
            }
            if usage.maxBytes > 0 {
                usageBar(fraction: fraction, tint: tint, height: 4)
                    .padding(.horizontal, PickerCardMetrics.rowInset)
                    .padding(.top, theme.space.s4)
            }
            if warn, usage.maxBytes > 0 {
                PickerCardFootnote(text: usage.pressureText, color: tint)
                    .padding(.top, theme.space.s6)
            }
        }
    }

    /// Horizontal fill gauge for the hero usage and disk-cache readouts.
    private func usageBar(fraction: Double, tint: Color, height: CGFloat) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.surface.hover)
                Capsule()
                    .fill(tint)
                    // Keep a sliver visible at ~0% so the bar reads as a gauge.
                    .frame(width: max(height, min(1, fraction) * proxy.size.width))
            }
        }
        .frame(height: height)
        .animation(theme.motion.quick, value: fraction)
    }

    // MARK: - Compaction

    /// The compaction row shows whenever there's something to act on or
    /// report: the manual trigger is available, a run is in flight, or a
    /// run just completed/failed.
    private var showsCompactionSection: Bool {
        if canCompact { return true }
        switch compactionState {
        case .idle, .needsModelSelection: return false
        case .running, .completed, .failed: return true
        }
    }

    /// Helper copy naming the model the next compaction run will use:
    /// the configured compaction model, else the chat's current model
    /// (`ContextCompactionService.effectiveModelIdentifier`). Read
    /// per-render from the in-memory config cache — no file I/O.
    private var compactionHelperText: String {
        let configured = ContextCompactionService.configuredModelIdentifier()
        if ContextCompactionService.usesChatModelFallback(configured: configured) {
            return L(
                "Summarizes older messages with the current chat model to free up context. The visible chat is unchanged. Pick a dedicated model in Models → Model Defaults → Compaction Model."
            )
        }
        let name = configured.map(Self.shortModelName) ?? ""
        return L("Summarizes older messages with \(name) to free up context. The visible chat is unchanged.")
    }

    /// `provider/model` → `model`; a bare id stays as is.
    private static func shortModelName(_ identifier: String) -> String {
        identifier.split(separator: "/", maxSplits: 1).last.map(String.init) ?? identifier
    }

    @ViewBuilder
    private var compactionSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s0) {
            switch compactionState {
            case .running(let phase):
                statusRow {
                    SettingsSpinner(size: .mini)
                } text: {
                    Text(verbatim: phase.label)
                }
            case .completed(let savedTokens):
                statusRow {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.status.success.foreground)
                } text: {
                    Text("Compacted — ~\(formatTokenCount(savedTokens)) tokens reclaimed", bundle: .module)
                }
            case .failed(let message):
                statusRow {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.status.warning.foreground)
                } text: {
                    Text(verbatim: message)
                }
                if canCompact { compactLink(label: L("Retry compaction")) }
            case .idle, .needsModelSelection:
                if canCompact {
                    compactLink(label: L("Compact conversation"))
                }
            }
        }
    }

    /// Icon + message row for a compaction state, aligned with legend rows.
    private func statusRow<Icon: View, Label: View>(
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder text: () -> Label
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
            icon()
                .textStyle(.footnote)
                .frame(width: 16)
            text()
                .textStyle(.bodySmall)
                .foregroundStyle(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, theme.space.s4)
        .pickerCardRowChrome(highlighted: false, minHeight: PickerCardMetrics.valueRowHeight)
    }

    private func compactLink(label: String) -> some View {
        PickerCardTextLink(title: label, icon: "arrow.down.right.and.arrow.up.left") {
            onCompact?()
        }
        .help(Text(verbatim: compactionHelperText))
    }

    /// The one place usage is stated: tokens against the usable budget, its
    /// share, a fill bar, and the headroom / model-limit caption.
    private var hero: some View {
        let prefix = isStreaming ? "" : "~"
        return VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(alignment: .firstTextBaseline, spacing: theme.space.s4) {
                Text(verbatim: "\(prefix)\(formatTokenCount(breakdown.total))")
                    .textStyle(.title)
                    .monospacedDigit()
                    .foregroundStyle(isHardOverflow ? theme.status.error.foreground : theme.text.primary)
                    .contentTransition(.numericText())
                Group {
                    if let maxTokens = utilization.maxTokens {
                        Text("/ \(formatTokenCount(maxTokens)) tokens", bundle: .module)
                    } else {
                        Text("tokens", bundle: .module)
                    }
                }
                .textStyle(.bodySmall)
                .foregroundStyle(theme.text.secondary)
                Spacer(minLength: 4)
                if let percent = utilization.percent {
                    Text(verbatim: "\(percent)%")
                        .textStyle(.label)
                        .monospacedDigit()
                        .foregroundStyle(statusColor)
                        .contentTransition(.numericText())
                }
            }

            if let fraction = utilization.fraction {
                usageBar(fraction: fraction, tint: statusColor, height: 6)
            }

            HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
                if let remaining = utilization.remainingTokens {
                    Text("\(formatTokenCount(remaining)) remaining", bundle: .module)
                        .contentTransition(.numericText())
                } else {
                    Text("Model context limit unavailable", bundle: .module)
                }
                Spacer(minLength: 4)
                if let modelMaxTokens {
                    Text(verbatim: "\(modelLimitLabel) \(formatTokenCount(modelMaxTokens))")
                        .lineLimit(1)
                        .help(
                            Text(
                                "The usable budget is \(Int(ContextBudgetManager.safetyMargin * 100))% of the model maximum, leaving room for the reply.",
                                bundle: .module
                            )
                        )
                }
            }
            .textStyle(.caption)
            .foregroundStyle(theme.text.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PickerCardMetrics.rowInset)
    }

    private var modelLimitLabel: String {
        switch modelLimitSource {
        case .foundationFixed:
            return L("Fixed model maximum")
        case .bundleMetadata:
            return L("Bundle model maximum")
        case .providerMetadata:
            return L("Provider model maximum")
        case .metadataFallback:
            return L("Metadata fallback")
        case .userCap:
            // Named so a window smaller than the bundle advertises reads as a
            // setting the user chose, not as the model being mis-detected.
            return L("Your context limit")
        case nil:
            return L("Model maximum")
        }
    }

    private func autoDisableRow(_ notice: String) -> some View {
        statusRow {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.status.warning.foreground)
        } text: {
            Text(verbatim: notice)
        }
    }

    /// What the used tokens are made of: the stacked bar directly above its
    /// legend, prompt sources first, then the conversation's messages.
    private var breakdownSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s0) {
            PickerCardSectionTitle(L("Breakdown"))
            compositionBar
                .padding(.horizontal, PickerCardMetrics.rowInset)
                .padding(.top, theme.space.s2)
                .padding(.bottom, theme.space.s6)
                .help(Text("Share of the tokens used in this chat", bundle: .module))
            if !contextGroups.isEmpty {
                contextGroupList
            }
            if !breakdown.messages.isEmpty {
                PickerCardSectionTitle(L("Messages"))
                entryGroup(breakdown.messages, highlightOutput: true)
            }
        }
    }

    // MARK: - Stacked Bar

    private var compositionBar: some View {
        let segments = barSegments
        // Composition deliberately fills its own track. Actual model-window
        // headroom is represented separately by the hero's usage bar.
        let scale = max(breakdown.total, 1)
        return GeometryReader { geo in
            let gapTotal = CGFloat(max(segments.count - 1, 0))
            let available = max(0, geo.size.width - gapTotal)
            let widths = computeContextBudgetSegmentWidths(
                tokens: segments.map(\.tokens),
                totalTokens: scale,
                available: available,
                fillsTrack: true
            )
            HStack(spacing: theme.space.s2) {
                // Positional identity: segment ids mirror prompt-section ids,
                // which aren't guaranteed unique across the manifest, so keying
                // by id would risk a duplicate-ID ForEach trap.
                ForEach(Array(zip(segments, widths).enumerated()), id: \.offset) { _, pair in
                    let (segment, width) = pair
                    RoundedRectangle(cornerRadius: theme.radius.small)
                        .fill(color(for: segment.tint))
                        .frame(width: width)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: theme.radius.small))
        }
        .frame(height: 6)
        .background(RoundedRectangle(cornerRadius: theme.radius.small).fill(theme.surface.hover))
    }

    // MARK: - Legend

    /// The context legend at group granularity. Expandable groups render a
    /// tappable header that reveals their per-section rows indented beneath.
    private var contextGroupList: some View {
        VStack(alignment: .leading, spacing: PickerCardMetrics.rowSpacing) {
            ForEach(contextGroups) { group in
                if group.isExpandable {
                    let expanded = expandedGroups.contains(group.id)
                    BudgetDisclosureRow(expanded: expanded) {
                        // No withAnimation: the anchored card animates its
                        // own resize from the reported height.
                        if expanded {
                            expandedGroups.remove(group.id)
                        } else {
                            expandedGroups.insert(group.id)
                        }
                    } label: {
                        legendRowContent(
                            tint: group.tint,
                            label: group.label,
                            tokens: group.tokens,
                            disclosure: expanded
                        )
                    }

                    if expanded {
                        // Key by position, not `entry.id`: a prompt section's
                        // id isn't guaranteed unique across the manifest, so
                        // duplicate ForEach IDs would trap. Positional
                        // identity is what we want for a static,
                        // display-only list anyway.
                        ForEach(Array(group.entries.enumerated()), id: \.offset) { _, entry in
                            entryRow(entry, nested: true)
                        }
                    }
                } else if let entry = group.entries.first {
                    entryRow(entry)
                }
            }
        }
    }

    private func entryGroup(_ entries: [ContextBreakdown.Entry], highlightOutput: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: PickerCardMetrics.rowSpacing) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                entryRow(entry, highlighted: highlightOutput && entry.id == "output")
            }
        }
    }

    private func entryRow(
        _ entry: ContextBreakdown.Entry,
        highlighted: Bool = false,
        nested: Bool = false
    ) -> some View {
        legendRowContent(
            tint: entry.tint,
            label: entry.label,
            tokens: entry.tokens,
            highlighted: highlighted,
            nested: nested
        )
        .pickerCardRowChrome(highlighted: false, minHeight: PickerCardMetrics.valueRowHeight)
    }

    /// Swatch, label, token count and share. `disclosure` adds the rotating
    /// chevron used by expandable groups; `nested` indents a drill-down row
    /// under its group and quiets its text.
    private func legendRowContent(
        tint: ContextBreakdown.Tint,
        label: String,
        tokens: Int,
        disclosure: Bool? = nil,
        highlighted: Bool = false,
        nested: Bool = false
    ) -> some View {
        return HStack(spacing: theme.space.s8) {
            Circle()
                .fill(color(for: tint))
                .frame(width: 7, height: 7)
                .frame(width: 16)

            Text(label)
                .textStyle(nested ? .caption : .label, weight: 400)
                .foregroundStyle(nested ? theme.text.secondary : theme.text.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let disclosure {
                Image(systemName: "chevron.right")
                    .glyphSize(.tiny, weight: .semibold)
                    .foregroundStyle(theme.text.tertiary)
                    .rotationEffect(.degrees(disclosure ? 90 : 0))
            }

            Spacer(minLength: 6)

            Text(formatTokenCount(tokens))
                .textStyle(nested ? .caption : .label, weight: 400)
                .monospacedDigit()
                .foregroundStyle(highlighted ? color(for: tint) : theme.text.primary)
                .contentTransition(highlighted ? .numericText() : .identity)

            Text(percent(tokens))
                .textStyle(.footnote)
                .monospacedDigit()
                .foregroundStyle(theme.text.tertiary)
                .frame(width: 32, alignment: .trailing)
        }
        .padding(.leading, nested ? theme.space.s24 : theme.space.s0)
    }
}

/// Expandable legend row ("System Prompt"): the picker's hover fill on an
/// otherwise read-only list, so it reads as the one clickable row.
private struct BudgetDisclosureRow<Label: View>: View {
    let expanded: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            label()
                .pickerCardRowChrome(highlighted: hovered, minHeight: PickerCardMetrics.valueRowHeight)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityValue(expanded ? L("Expanded") : L("Collapsed"))
    }
}

// MARK: - Wallet Popover

/// The composer wallet panel, presented in the same arrowless, themed card
/// as the model picker, aligned to the trailing edge of its credits chip.
/// Opens from the credits chip on click as an interactive
/// panel: balance hero, per-session router spend, recent account activity
/// (model requests + ledger transactions), and Add credits / View all actions.
/// This is the surface agent-initiated credit transactions will land in — new
/// ledger `entry_type`s render here via `WalletActivityProjector` without UI
/// rework.
private struct WalletPopover: View {
    /// This session's router spend; nil outside router-billed sessions.
    let sessionSpend: String?
    /// "N cached · P%" for the session's router prompt-cache hits. Shown under
    /// the spend row so users can see the discount they got; nil hides it.
    let sessionCachedInputLabel: String?
    /// True when a low/empty balance should tint amber (router-billed sessions
    /// only — a $0 wallet doesn't block a local-model chat).
    let isAttention: Bool
    let onAddCredits: () -> Void
    let onViewAll: () -> Void
    let onHeightChange: (CGFloat) -> Void

    @ObservedObject private var accountService = OsaurusRouterAccountService.shared
    @Environment(\.theme) private var theme
    @Environment(\.anchoredCardMetrics) private var cardMetrics

    private var subduedTextColor: Color { theme.isDark ? theme.text.tertiary : theme.text.secondary }

    /// Shared so each row doesn't allocate a formatter; relative labels like
    /// "3h ago" only need minute resolution.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private var rows: [WalletActivityRow] {
        WalletActivityProjector().rows(
            usageItems: accountService.usage,
            transactions: accountService.transactions,
            webUsageItems: accountService.webUsage
        )
    }

    var body: some View {
        ScrollView {
            walletContent
                .padding(PickerCardMetrics.padding)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    ceil(geometry.size.height)
                } action: { height in
                    onHeightChange(height)
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(
            width: cardMetrics?.visibleSize.width ?? PickerCardMetrics.infoCardWidth,
            height: cardMetrics?.visibleSize.height
        )
        .pickerCardSurface()
        .task {
            await accountService.refreshBalance()
            await accountService.refreshUsage(reset: true)
            await accountService.refreshTransactions(reset: true)
            await accountService.refreshWebUsage(reset: true)
            await accountService.refreshWebSettings()
        }
        // A billed turn settled while the popover is open: refetch the
        // activity rows. Only fires while this view is mounted, so a closed
        // wallet costs nothing per turn.
        .onChange(of: accountService.usageRevision) { _, _ in
            Task { await accountService.refreshUsage(reset: true) }
        }
    }

    private var walletContent: some View {
        let searchGrant = accountService.webSettings?.grants?.search
        let showsSearchCredits = (searchGrant?.includedTotal ?? 0) > 0
        return VStack(alignment: .leading, spacing: theme.space.s8) {
            PickerCardHeading(title: L("Credits")) {
                if accountService.isFrozen {
                    Text("Paused", bundle: .module)
                        .textStyle(.label)
                        .foregroundStyle(theme.status.warning.foreground)
                }
            }

            VStack(alignment: .leading, spacing: PickerCardMetrics.infoSectionSpacing) {
                header

                if sessionSpend != nil || showsSearchCredits {
                    VStack(alignment: .leading, spacing: PickerCardMetrics.rowSpacing) {
                        if let sessionSpend {
                            sessionSpendRow(sessionSpend, cachedLabel: sessionCachedInputLabel)
                        }
                        if let searchGrant, showsSearchCredits {
                            webSearchCreditsRow(searchGrant)
                        }
                    }
                }

                if accountService.webSearchNeedsTopUp {
                    webSearchFallbackNotice
                }

                activitySection
                footerActions
            }
        }
    }

    // MARK: Sections

    /// Hero balance at the top of the wallet.
    private var header: some View {
        VStack(alignment: .leading, spacing: theme.space.s2) {
            // Hero figure only; "credits" rides along as a caption so large
            // balances don't truncate the oversized figure.
            HStack(alignment: .firstTextBaseline, spacing: theme.space.s4) {
                Text(verbatim: accountService.formattedBalanceValue)
                    .textStyle(.title)
                    .monospacedDigit()
                    .foregroundStyle(
                        (isAttention || accountService.isFrozen)
                            ? theme.status.warning.foreground : theme.text.primary
                    )
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("credits available", bundle: .module)
                    .textStyle(.bodySmall)
                    .foregroundStyle(theme.text.secondary)
                    .lineLimit(1)
            }

            if accountService.isFrozen {
                Text("Account paused - add credits to resume.", bundle: .module)
                    .textStyle(.footnote)
                    .foregroundStyle(theme.status.warning.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PickerCardMetrics.rowInset)
    }

    /// Read-only label/value row in the picker's row geometry.
    private func valueRow(
        icon: String,
        iconColor: Color? = nil,
        label: LocalizedStringKey,
        value: String,
        valueColor: Color? = nil
    ) -> some View {
        HStack(spacing: theme.space.s8) {
            Image(systemName: icon)
                .glyphSize(.footnote)
                .foregroundStyle(iconColor ?? theme.text.tertiary)
                .frame(width: 16)
            Text(label, bundle: .module)
                .textStyle(.bodySmall)
                .foregroundStyle(theme.text.primary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(verbatim: value)
                .textStyle(.bodySmall)
                .monospacedDigit()
                .foregroundStyle(valueColor ?? theme.text.primary)
                .contentTransition(.numericText())
        }
        .pickerCardRowChrome(highlighted: false, minHeight: PickerCardMetrics.valueRowHeight)
    }

    @ViewBuilder
    private func sessionSpendRow(_ spend: String, cachedLabel: String?) -> some View {
        valueRow(icon: "chart.bar.fill", label: "This session", value: spend)
        // Prompt-cache hits: input the router billed at the cached rate.
        // Only rendered when the router echoed a non-zero split.
        if let cachedLabel {
            valueRow(
                icon: "bolt.fill",
                label: "Prompt cache",
                value: cachedLabel,
                valueColor: theme.text.secondary
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                Text("Prompt cache: \(cachedLabel) input tokens served from cache", bundle: .module)
            )
        }
    }

    /// The account's search credit balance, mirrored from the Credits tab so
    /// the balance the user actually spends on web search is visible where
    /// they check their wallet. Reads like the dollar balance above it — a
    /// single remaining count, amber once spent (searches then bill the
    /// shared balance or fall back to the built-in sources).
    private func webSearchCreditsRow(_ grant: OsaurusRouterWebAllowance) -> some View {
        let exhausted = grant.remainingTotal <= 0
        return valueRow(
            icon: "magnifyingglass",
            iconColor: exhausted ? theme.status.warning.foreground : nil,
            label: "Search credits",
            value: "\(grant.remainingTotal)",
            valueColor: exhausted ? theme.status.warning.foreground : nil
        )
    }

    /// Premium web search ran out of credits and is quietly using the
    /// built-in sources — the graceful-fallback state made visible where the
    /// user checks their wallet, per spec: billing outcomes reach the UI even
    /// when the search itself succeeded via fallback.
    private var webSearchFallbackNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
            Image(systemName: "magnifyingglass")
                .glyphSize(.footnote)
                .foregroundStyle(theme.status.warning.foreground)
                .frame(width: 16)
            Text("Premium search is paused - add credits to resume.", bundle: .module)
                .textStyle(.footnote)
                .foregroundStyle(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PickerCardMetrics.rowInset)
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: theme.space.s0) {
            PickerCardSectionTitle(L("Recent activity"))

            if rows.isEmpty {
                PickerCardFootnote(text: L("No activity yet"), color: subduedTextColor)
                    .padding(.vertical, theme.space.s6)
            } else {
                VStack(alignment: .leading, spacing: PickerCardMetrics.rowSpacing) {
                    ForEach(rows) { row in
                        activityRow(row)
                    }
                }
            }
        }
    }

    private func activityRow(_ row: WalletActivityRow) -> some View {
        HStack(alignment: .center, spacing: theme.space.s8) {
            Image(systemName: iconName(for: row))
                .glyphSize(.footnote, weight: .medium)
                .foregroundStyle(badgeTint(for: row))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: theme.space.s2) {
                // Transaction and web-usage titles are the projector's fixed
                // vocabulary ("Credits added", "Web search", ...) and localize
                // via key lookup. Model-usage titles are model/provider ids
                // and must render verbatim — LocalizedStringKey would treat
                // underscores in ids as markdown emphasis.
                Group {
                    if row.kind == .usage {
                        Text(verbatim: Self.modelName(row.title))
                            .help(Text(verbatim: row.title))
                    } else {
                        Text(LocalizedStringKey(row.title), bundle: .module)
                    }
                }
                .textStyle(.bodySmall)
                .foregroundStyle(theme.text.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                if let timeLabel = timeLabel(for: row) {
                    Text(verbatim: timeLabel)
                        .textStyle(.footnote)
                        .foregroundStyle(subduedTextColor)
                }
            }

            Spacer(minLength: 8)

            Text(verbatim: row.amountLabel)
                .textStyle(.bodySmall)
                .monospacedDigit()
                .foregroundStyle(row.isCredit ? theme.status.success.foreground : theme.text.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.vertical, theme.space.s4)
        .pickerCardRowChrome(highlighted: false)
    }

    /// Two quiet actions side by side: the primary one tinted, the
    /// navigation one neutral.
    private var footerActions: some View {
        HStack(spacing: theme.space.s0) {
            PickerCardTextLink(
                title: L("Add Credits"),
                icon: "plus",
                tint: theme.text.link,
                fillsWidth: false,
                action: onAddCredits
            )
            Spacer(minLength: 8)
            PickerCardTextLink(title: L("View all"), icon: "arrow.forward", fillsWidth: false, action: onViewAll)
                .localizedHelp("Open the Credits tab for full usage and transaction history.")
        }
    }

    /// `provider/model` → `model`; the full id stays in the row's tooltip.
    private static func modelName(_ identifier: String) -> String {
        identifier.split(separator: "/", maxSplits: 1).last.map(String.init) ?? identifier
    }

    // MARK: Row styling

    private func iconName(for row: WalletActivityRow) -> String {
        switch row.kind {
        case .transaction:
            return row.isCredit ? "arrow.down.left" : "arrow.up.right"
        case .usage:
            return "sparkles"
        case .webUsage:
            return "magnifyingglass"
        }
    }

    /// Badge + icon tint. Money-in reads green; spends stay neutral unless the
    /// request itself needs attention (stopped/error states from the ledger).
    /// Hosted web searches render in the premium (accent) family — a touch
    /// stronger when the request used a search credit.
    private func badgeTint(for row: WalletActivityRow) -> Color {
        if row.isCredit { return theme.status.success.foreground }
        switch row.stateKind {
        case .warning: return theme.status.warning.foreground
        case .error: return theme.status.error.foreground
        case .success, .secondary:
            if row.kind == .webUsage {
                return row.isIncludedWebRequest
                    ? theme.status.info.foreground : theme.status.info.foreground
            }
            return theme.text.secondary
        }
    }

    private func timeLabel(for row: WalletActivityRow) -> String? {
        guard let date = row.date else { return nil }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Context Budget Segment Widths

/// Pre-allocates pixel widths for the Context Budget stacked bar so the
/// rendered segments never overflow `available` (the GeometryReader width
/// minus the 1pt gaps between segments) and — when `fillsTrack` is true —
/// fill the track exactly even after rounding/floor adjustments.
///
/// Behavior:
/// - Returns zeros when `available <= 0` or `totalTokens <= 0`.
/// - Initial widths are proportional to `tokens[i] / totalTokens * available`.
/// - Non-zero entries get a 1pt floor so tiny segments stay visible without
///   dominating the bar (the old `3pt` floor caused overflow with 4+ tiny
///   entries plus 1pt inter-item spacing).
/// - If the sum overflows `available`, all widths are scaled by
///   `available / sum` so they fit exactly. This guarantees the bar never
///   spills past the GeometryReader background.
/// - When `fillsTrack` is true (no ceiling case), any remaining slack is
///   redistributed weighted by `tokens[i]` so segments cover the full track.
///   When false (ceiling present), the leftover is the caller's headroom
///   slot, surfaced as a trailing `Spacer`.
func computeContextBudgetSegmentWidths(
    tokens: [Int],
    totalTokens: Int,
    available: CGFloat,
    fillsTrack: Bool
) -> [CGFloat] {
    guard !tokens.isEmpty else { return [] }
    guard available > 0, totalTokens > 0 else {
        return Array(repeating: 0, count: tokens.count)
    }

    let totalDouble = Double(totalTokens)
    let availableDouble = Double(available)

    var widths: [Double] = tokens.map { count in
        guard count > 0 else { return 0 }
        let raw = Double(count) / totalDouble * availableDouble
        return max(raw, 1)
    }

    var sum = widths.reduce(0, +)

    if sum > availableDouble && sum > 0 {
        let scale = availableDouble / sum
        widths = widths.map { $0 * scale }
        sum = widths.reduce(0, +)
    }

    if fillsTrack, sum < availableDouble {
        let slack = availableDouble - sum
        let tokenTotal = tokens.reduce(0, +)
        if tokenTotal > 0 {
            for i in widths.indices where tokens[i] > 0 {
                widths[i] += slack * Double(tokens[i]) / Double(tokenTotal)
            }
        }
    }

    return widths.map { CGFloat($0) }
}

// MARK: - Selector Chip

/// Polished selector chip for model pickers
private struct SelectorChip<Content: View>: View {
    let isActive: Bool
    /// A text-weight selector (the model picker): no surface at rest, a
    /// soft fill on hover and while its card is open.
    var quiet: Bool = false
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    init(isActive: Bool, quiet: Bool = false, action: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.isActive = isActive
        self.quiet = quiet
        self.action = action
        self.content = content
    }

    var body: some View {
        if quiet {
            Button(action: action) {
                content().modifier(QuietChipSurface(isActive: isActive, isHovered: isHovered))
            }
            .composerChipButtonStyle()
            .composerChipFocus()
            .pointingHandCursor()
            .onHover { hovering in
                withAnimation(theme.motion.quick) { isHovered = hovering }
            }
        } else {
            standardChip
        }
    }

    @ViewBuilder
    private var standardChip: some View {
        Button(action: action) { content().composerChipSurface(selected: isActive) }
            .composerChipButtonStyle().composerChipFocus()
    }

    @ViewBuilder
    private var chipBackground: some View {
        ZStack {
            Capsule()
                .fill(theme.surface.subtle)

            if isActive {
                Capsule().fill(theme.surface.selected)
            } else if isHovered {
                Capsule().fill(theme.surface.hover)
            }
        }
    }

    private var chipBorder: some View {
        Capsule()
            .strokeBorder(
                isActive ? theme.border.focus : (isHovered ? theme.border.default : theme.border.subtle),
                lineWidth: theme.stroke.default
            )
    }
}

/// One surface for the media composer's option chips (size, steps, CFG,
/// seed, negative prompt…): the design system's composer chip around a
/// fixed content height, so every chip in the row is as tall as the
/// composer's round buttons whatever it holds — the steps stepper's
/// buttons included.
private struct ImageOptionChipSurface: ViewModifier {
    static let contentHeight: CGFloat = 18
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .frame(height: Self.contentHeight)
            .composerChipSurface()
    }
}

/// The quiet chip's surface: as tall as the composer's round buttons, a
/// tight inset so the label sits close to the + beside it, and a fill only
/// on hover or while active.
private struct QuietChipSurface: ViewModifier {
    let isActive: Bool
    let isHovered: Bool
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
        content
            .padding(.horizontal, theme.space.s8)
            .frame(height: theme.controlSize.compactHeight)
            .background(shape.fill(isActive ? theme.surface.selected : isHovered ? theme.surface.hover : Color.clear))
            .overlay(shape.strokeBorder(isActive ? theme.selectionBorder : .clear, lineWidth: theme.selectionStroke))
            .contentShape(shape)
    }
}

/// Sizes content to its natural width up to `maxWidth`, truncating past it.
/// A plain `.frame(maxWidth:)` grows to the cap whenever the row has room,
/// which left a short model name centred in a wide chip.
private struct CappedHuggingWidth: ViewModifier {
    let maxWidth: CGFloat

    func body(content: Content) -> some View {
        CappedHuggingWidthLayout(maxWidth: maxWidth) { content }
    }
}

private struct CappedHuggingWidthLayout: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let natural = child.sizeThatFits(.unspecified)
        let width = min(natural.width, maxWidth, proposal.width ?? .infinity)
        return child.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

// MARK: - Input Action Button

/// Polished circular action button for input card (media, voice, etc.)
private struct SlashCommandTriggerButton: View {
    let isActive: Bool
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) { Text("/") }
            .assignedSettingsButtonStyle(.tertiary)
            .settingsChrome(isActive ? .selected : nil)
            .localizedHelp("Browse slash commands")
            .accessibilityLabel(Text("Browse slash commands", bundle: .module))
    }
}

private struct InputActionButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) { Image(systemName: icon) }
            .assignedSettingsIconButtonStyle(size: .small, role: .secondary)
            .help(help).accessibilityLabel(help)
    }
}

/// `SlashCommandTriggerButton`'s circular footprint opening a themed popover
/// of action rows — the same idiom as the model picker's sort menu
/// (`ModelPickerView.sortPopoverView` / `SortOptionRow`) — instead of a
/// native NSMenu, so the dropdown matches the app's visual language.
private struct InputActionMenuButton: View {
    struct Item {
        let icon: String
        let title: Text
        /// When non-nil the row is shown dimmed and inert, with a trailing
        /// info icon whose tooltip explains why the action is unavailable.
        let disabledReason: Text?
        let action: () -> Void

        init(
            icon: String,
            title: Text,
            disabledReason: Text? = nil,
            action: @escaping () -> Void
        ) {
            self.icon = icon
            self.title = title
            self.disabledReason = disabledReason
            self.action = action
        }
    }

    let icon: String
    let help: String
    let items: [Item]
    /// Optional content shown under a divider after the rows (recent folder
    /// chips). Receives a closure that closes the menu.
    var footer: ((@escaping () -> Void) -> AnyView)? = nil

    @State private var isHovered = false
    @State private var showPopover = false
    @State private var menuInteraction = ClickMenuInteraction()
    @State private var measuredMenuSize: CGSize = .zero
    @Environment(\.theme) private var theme

    var body: some View {
        menuTrigger

            // Shared anchored presentation; click/keyboard activation takes focus.
            .anchoredCard(isPresented: $menuInteraction.isPresented,
                          size: measuredMenuSize,
                          alignment: .leading, constrainToWindow: true,
                          takesFocus: menuInteraction.takesFocus, shadowPadding: 18,
                          shadowPassesThrough: true, accessibilityLabel: help) {
                menuContent
                    .fixedSize(horizontal: true, vertical: true)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                        if abs(measuredMenuSize.width - size.width) > 0.5 || abs(measuredMenuSize.height - size.height) > 0.5 {
                            measuredMenuSize = CGSize(width: max(1, size.width), height: max(1, size.height))
                        }
                    }

                    .themeElevation(theme.elevation.overlay)
            }
            .onChange(of: menuInteraction.isPresented) { _, shown in
                if !shown {
                    menuInteraction.didDismiss()
                }
            }
            .onDisappear { menuInteraction.didDismiss() }
    }

    @ViewBuilder private var menuTrigger: some View {
        Button {
            menuInteraction.clickTrigger()
        } label: { Image(systemName: icon) }
            .assignedSettingsIconButtonStyle(size: .small, role: .secondary)
            .contentShape(Rectangle())
            .help(help).accessibilityLabel(help)
    }

    @ViewBuilder private var menuContent: some View {
        ChatContextMenu { menuRows }
            .environment(\.theme, theme)
    }

    @ViewBuilder private var menuRows: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            MenuItemRow(icon: item.icon, title: item.title, disabledReason: item.disabledReason) {
                closeMenu()
                item.action()
            }
        }
        if let footer {
            ChatContextMenuDivider()
            footer({ closeMenu() })
        }
    }

    private func closeMenu() {
        menuInteraction.didDismiss()
    }

    /// One popover action row, in the model picker's `SortOptionRow` idiom:
    /// leading icon, 12pt title, hover-highlighted rounded background.
    private struct MenuItemRow: View {
        let icon: String
        let title: Text
        var disabledReason: Text? = nil
        let action: () -> Void
        @Environment(\.theme) private var theme
        @State private var isHovering = false
        @State private var showReason = false

        private var isDisabled: Bool { disabledReason != nil }

        var body: some View {
            Button(action: { if !isDisabled { action() } }) {
                ChatContextMenuLabel(title: title, icon: Group {
                    if icon == "slash.forward" { Text("/") }
                    else { Image(systemName: icon) }
                })
                if isDisabled { Image(systemName: "info.circle") }
            }
            .buttonStyle(ChatContextMenuRowStyle())
            .disabled(isDisabled)
            .help(disabledReason ?? Text(""))
        }
    }
}

// MARK: - Send Button

/// Shared Send/Stop icon button. Stop retains the Send footprint and uses
/// the library primary action; Send retains the saved brand action. Also
/// the submit of `PromptReplyField`.
struct SendButton: View {
    let canSend: Bool
    var isStopping = false
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    private var state: ThemeActionState<Color> {
        guard canSend else { return theme.action.primary.disabled }
        return isHovered ? theme.action.primary.hover : theme.action.primary.default
    }

    var body: some View {
        Button(action: action) { Image(systemName: isStopping ? "stop.fill" : "arrow.up") }
            .assignedSettingsIconButtonStyle(size: .small, role: isStopping ? .primary : .brand)
            .disabled(!canSend)
            .accessibilityLabel(Text(isStopping ? "Stop" : "Send", bundle: .module))
    }
}

// MARK: - Stop Button

/// The Stop of a hosted conversation's notice.
struct StopButton: View {
    let action: () -> Void

    var body: some View {
        SettingsButton(.destructive, "Stop", icon: "stop.fill", size: .compact, action: action)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
}

// MARK: - Send Queue Button

/// Used while a run is streaming and the queue is empty. Pressing it
/// stores the current input as a single-slot pending send (handled by
/// the parent). Shares the exact 32×32 circular footprint of
/// `SendButton`; the only visual delta is a muted gray fill (instead of
/// the accent gradient) plus a hover tooltip that explains the queue
/// semantics. The icon stays `arrow.up` so users still read it as
/// "send".
private struct SendQueueButton: View {
    let canSend: Bool
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) { Image(systemName: "arrow.up") }
            .assignedSettingsIconButtonStyle(size: .small, role: .secondary)
            .disabled(!canSend)
            .localizedHelp("Queue message · sent when current run finishes")
            .accessibilityLabel(Text("Queue message", bundle: .module))
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
}

// MARK: - Send Now Button

/// Accent-tinted variant that stops the active run and dispatches the
/// queued send immediately. Visible only when a queued message exists.
/// Same 32×32 circular footprint as `SendButton`; differentiated by a
/// `bolt.fill` icon (signals "urgent / now") and a hover tooltip.
private struct SendNowButton: View {
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) { Image(systemName: "bolt.fill") }
            .assignedSettingsIconButtonStyle(size: .small, role: .brand)
            .localizedHelp("Send now · interrupts current run")
            .accessibilityLabel(Text("Send now", bundle: .module))
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
}

// MARK: - Resume Button

/// Polished resume button with accent color
// MARK: - Preview

#if DEBUG
    struct FloatingInputCard_Previews: PreviewProvider {
        struct PreviewWrapper: View {
            @State private var text = ""
            @State private var model: String? = "foundation"
            @State private var attachments: [Attachment] = []
            @State private var isContinuousVoiceMode: Bool = false
            @State private var voiceInputState: VoiceInputState = .idle
            @State private var showVoiceOverlay: Bool = false
            @State private var activeModelOpts: [String: ModelOptionValue] = [:]

            var body: some View {
                VStack {
                    Spacer()
                    FloatingInputCard(
                        text: $text,
                        selectedModel: $model,
                        pendingAttachments: $attachments,
                        isContinuousVoiceMode: $isContinuousVoiceMode,
                        voiceInputState: $voiceInputState,
                        showVoiceOverlay: $showVoiceOverlay,
                        pickerItems: [
                            .foundation(),
                            ModelPickerItem(
                                id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
                                displayName: "Llama 3.2 3B Instruct 4bit",
                                source: .local,
                                parameterCount: "3B",
                                quantization: "4-bit",
                                isVLM: false
                            ),
                        ],
                        activeModelOptions: $activeModelOpts,
                        isStreaming: false,
                        supportsImages: true,
                        estimatedContextTokens: 2450,
                        onSend: { _ in },
                        onStop: {}
                    )
                }
                .frame(width: 700, height: 400)
                .background(CustomizableTheme.dark().surface.canvas)
            }
        }

        static var previews: some View {
            PreviewWrapper()
        }
    }
#endif

// MARK: - Meta Cluster Chips

/// Balance indicator shown in every session where the router is usable.
/// Extracted from `FloatingInputCard` so wallet-panel hover/pin state and
/// Pool chip for a chat with a teammate's shared agent. Mirrors the personal
/// credits chip: the number is what the workspace has LEFT to spend (the
/// pool balance from `WorkspacesService.poolBalances`), because a spend
/// figure beside a teammate's agent read as "this workspace has 0 credits".
/// The run is drawn from that pool, not this device's wallet; the host
/// relays each billed step over the run stream, which refreshes the balance
/// so it ticks down live. Session spend stays in the tooltip. Passive
/// status in the meta cluster (same `SelectorChip` chrome as the credits
/// chip); clicking opens Workspaces.
private struct FloatingWorkspacePoolChip: View {
    let workspaceName: String
    /// nil only when the tab's workspace is unknown; the click then falls
    /// back to the workspace list and no balance can be shown.
    let workspaceId: String?
    /// Total micro-USD billed to the pool by this session's turns.
    let spendMicro: Int
    let metaCompact: Bool
    let metaUltraCompact: Bool

    @ObservedObject private var workspaces = WorkspacesService.shared
    @Environment(\.theme) private var theme

    private var balance: OsaurusRouterWorkspacePoolBalance? {
        workspaceId.flatMap { workspaces.poolBalances[$0] }
    }

    /// Balance for the chip; abbreviated when the cluster is squeezed.
    /// nil until the first fetch lands (or when the workspace is unknown),
    /// so the chip never shows a fabricated "0 credits".
    private var balanceDisplay: String? {
        guard let micro = balance?.balanceMicro else { return nil }
        return metaCompact
            ? OsaurusRouter.formatMicroAsCreditsCompact(micro)
            : OsaurusRouter.formatMicroAsCredits(micro)
    }

    private var spendDisplay: String {
        OsaurusRouter.formatMicroAsCredits(String(spendMicro))
    }

    private var isFrozen: Bool { balance?.frozen == true }

    private var balanceColor: Color {
        if isFrozen { return theme.status.warning.foreground }
        guard let micro = balance.flatMap({ Int64($0.balanceMicro) }) else { return theme.text.primary }
        return micro <= 0 ? theme.status.warning.foreground : theme.text.primary
    }

    /// Names the workspace, not a generic "Workspace pool": a bare number
    /// beside a teammate's agent read as *your* balance. The name is the
    /// context that makes the number legible, so it survives compact
    /// (truncated) and only ultra-compact drops it.
    var body: some View {
        SelectorChip(isActive: false) {
            if let workspaceId {
                WorkspacesService.shared.openInSettings(workspaceId: workspaceId, tab: .overview)
            } else {
                AppDelegate.shared?.showManagementWindow(initialTab: .workspaces)
            }
        } content: {
            HStack(spacing: theme.catalogLayoutMetric("component.library.23.elements.layout.floatingWorkspacePoolChip.body.horizontalGap", inheriting: theme.assignedMetric("component.library.23.gap", fallback: theme.space.s4))) {
                Image(systemName: "person.2.fill")
                    .glyphSize(.micro)
                    .composerChipInk("secondary", fallback: theme.text.tertiary)
                if !metaUltraCompact {
                    Text(verbatim: workspaceName)
                        .composerChipTextStyle(.footnote, weight: 500)
                        .composerChipOriginalWeight(.medium)
                        .composerChipInk("foreground", fallback: theme.text.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: metaCompact ? 96 : 160, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if !metaCompact {
                        Text("pool", bundle: .module)
                            .composerChipTextStyle(.footnote, weight: 500)
                            .composerChipOriginalWeight(.medium)
                            .composerChipInk("secondary", fallback: theme.text.tertiary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    if let balanceDisplay {
                        Text(verbatim: "·")
                            .composerChipTextStyle(.footnote)
                            .composerChipInk("secondary", fallback: theme.text.tertiary)
                        Text(verbatim: balanceDisplay)
                            .composerChipTextStyle(.footnote, monospacedDigit: true, weight: 500, family: .code, property: "text")
                            .composerChipOriginalWeight(.medium)
                            .composerChipInk("foreground", fallback: balanceColor)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .contentTransition(.numericText())
                    }
                }
            }.catalogLayoutTarget("component.library.23.elements.layout.floatingWorkspacePoolChip.body.horizontalGap")
        }
        .help(Text(verbatim: helpText))
        .accessibilityLabel(Text(verbatim: accessibilityText))
        .animation(theme.motion.quick, value: balance?.balanceMicro)
        // First paint and every workspace change: read the pool once. Billed
        // steps refresh it through `WorkspacesService.noteWorkspaceBilled`.
        .task(id: workspaceId) {
            guard let workspaceId else { return }
            await workspaces.refreshPoolBalance(workspaceId: workspaceId)
        }
    }

    private var helpText: String {
        let spend = String(
            format: L("%@ spent from this pool this session — billed to the workspace, not your wallet."),
            spendDisplay
        )
        let balanceLine: String
        if isFrozen {
            balanceLine = String(format: L("%@'s pool is frozen."), workspaceName)
        } else if let full = balance.map({ OsaurusRouter.formatMicroAsCredits($0.balanceMicro) }) {
            balanceLine = String(format: L("%@ left in %@'s pool."), full, workspaceName)
        } else {
            balanceLine = String(format: L("%@'s pool balance is still loading."), workspaceName)
        }
        return "\(balanceLine) \(spend) \(String(format: L("Click to open %@."), workspaceName))"
    }

    private var accessibilityText: String {
        if let full = balance.map({ OsaurusRouter.formatMicroAsCredits($0.balanceMicro) }) {
            return String(
                format: L("%@ left in %@'s workspace pool. %@ spent this session."),
                full,
                workspaceName,
                spendDisplay
            )
        }
        return String(format: L("%@'s workspace pool. %@ spent this session."), workspaceName, spendDisplay)
    }
}

/// account-service updates re-render only this chip, never the whole card.
/// Clicking opens the wallet panel so its actions
/// (Add credits → top-up sheet, View all → Credits tab) are reachable.
/// Quiet plain text normally, escalating to an amber pill / "Add Credits"
/// CTA as the balance runs low or hits zero — router-billed sessions only.
private struct FloatingCreditsChip: View {
    let isRouterBilledSession: Bool
    /// Total micro-USD spent on the Osaurus Router this session (popover row).
    let sessionSpendMicro: Int
    /// Session prompt-cache hit label for the popover's spend row; nil hides it.
    let sessionCachedInputLabel: String?
    let metaCompact: Bool
    let metaUltraCompact: Bool
    let onAddCredits: (() -> Void)?

    var inspectionBalance: Int? = nil

    @ObservedObject private var accountService = OsaurusRouterAccountService.shared
    @Environment(\.theme) private var theme

    /// Wallet panel presentation, activated by clicking the chip.
    @State private var showWalletPanel = false
    /// Open panels remain until explicit dismissal, outside-click or an action.
    @State private var walletPanelPinned = false
    /// Measured before the first presentation, then updated as activity loads.
    @State private var walletPanelHeight: CGFloat = 0

    /// Urgency tiers for the balance indicator. Healthy stays quiet (plain muted
    /// text that blends into the meta cluster); low and empty escalate to an
    /// amber pill so a top-up is easy to notice. Empty/frozen reads as an "Add
    /// credits" call to action — deliberately amber, never error-red, so it
    /// invites action instead of looking like a failure. The escalation only
    /// applies to router-billed sessions; see `creditsStyle(for:)`.
    private enum BalanceLevel {
        case healthy
        case low
        case empty
    }

    private var balanceLevel: BalanceLevel {
        if let value = inspectionBalance { return value <= 0 ? .empty : value < 1_000_000 ? .low : .healthy }
        let micro = accountService.balanceMicroValue
        if micro <= 0 || accountService.isFrozen {
            return .empty
        }
        if micro < 1_000_000 {  // < 10,000 credits ($1.00)
            return .low
        }
        return .healthy
    }

    /// Resolved visual tokens for one `BalanceLevel` so the body can render
    /// declaratively instead of re-deriving each property from the level inline.
    private struct CreditsChipStyle {
        let iconName: String
        let iconColor: Color
        let textColor: Color
        let weight: Font.Weight
        /// Pill fill/stroke; `nil` keeps the chip chrome-free (healthy state).
        let pill: (fill: Color, stroke: Color)?
        /// Lifts the chip off the composer to draw the eye to the CTA.
        let raised: Bool
        /// When false, the chip shows the "Add Credits" CTA instead of an amount.
        let showsAmount: Bool
    }

    private func creditsStyle(for level: BalanceLevel) -> CreditsChipStyle {
        let amber = theme.status.warning.foreground
        // Outside router-billed sessions the chip never escalates: the balance
        // doesn't block the current session, so a $0/unknown wallet reads as
        // quiet muted "Add Credits" text instead of an amber call to action.
        guard isRouterBilledSession else {
            return CreditsChipStyle(
                iconName: "cloud",
                iconColor: theme.text.tertiary,
                textColor: theme.text.secondary,
                weight: .medium,
                pill: nil,
                raised: false,
                showsAmount: level != .empty
            )
        }
        switch level {
        case .healthy:
            return CreditsChipStyle(
                iconName: "cloud",
                iconColor: theme.text.tertiary,
                textColor: theme.text.secondary,
                weight: .medium,
                pill: nil,
                raised: false,
                showsAmount: true
            )
        case .low:
            // The chip shows the router balance, so a low balance escalates the
            // chip itself to amber text (no pill) — a gentle nudge that stops
            // short of the empty-state "Add Credits" call to action.
            return CreditsChipStyle(
                iconName: "cloud",
                iconColor: amber,
                textColor: amber,
                weight: .semibold,
                pill: nil,
                raised: false,
                showsAmount: true
            )
        case .empty:
            return CreditsChipStyle(
                iconName: "plus.circle.fill",
                iconColor: amber,
                textColor: amber,
                weight: .semibold,
                pill: (theme.status.warning.background, theme.status.warning.border),
                raised: true,
                showsAmount: false
            )
        }
    }

    /// This session's Router spend, formatted for the wallet panel. The chip
    /// surfaces the account balance; spend is shown only in the popover.
    private var sessionSpendDisplay: String {
        OsaurusRouter.formatMicroAsCredits(String(sessionSpendMicro))
    }

    /// Accessibility text for the credits chip. Describes the router balance the
    /// chip shows and the tap action; session spend lives in the wallet panel.
    private var creditsHelpText: Text {
        if accountService.isFrozen {
            return Text("Account paused - add credits to resume.", bundle: .module)
        }
        return Text("\(accountService.formattedBalance) router balance. Click to open the wallet.", bundle: .module)
    }

    var body: some View {
        let level = balanceLevel
        let style = creditsStyle(for: level)
        let caption = theme.pointSize(.caption)
        // Hide the icon in compact mode to save width, except the empty-state
        // plus glyph, which signals the chip is actionable. In the ultra-compact
        // tier we always keep the icon, since it becomes the whole chip.
        let showIcon = !metaCompact || level == .empty || metaUltraCompact
        // At the tightest width the chip is icon-only (glyph carries the state,
        // click opens the wallet) so the row's toggle chips aren't clipped.
        let showLabel = !metaUltraCompact

        Group {
            if style.pill == nil {
                // Balance states: the same pill chrome as the model selector
                // chip (`SelectorChip`) so the meta cluster's interactive
                // chips read as one family.
                SelectorChip(isActive: showWalletPanel && walletPanelPinned) {
                    handleChipTap(level: level)
                } content: {
                    chipLabel(style: style, caption: caption, showIcon: showIcon, showLabel: showLabel)
                }
            } else {
                // Empty state keeps its own amber "Add Credits" CTA pill.
                Button {
                    handleChipTap(level: level)
                } label: {
                    chipLabel(style: style, caption: caption, showIcon: showIcon, showLabel: showLabel)
                        .composerChipSurface()
                        .themeElevation(style.raised ? theme.elevation.raised : .none)
                        .contentShape(Capsule())
                }
                .composerChipButtonStyle()
                .pointingHandCursor()
            }
        }
        .accessibilityLabel(creditsHelpText)

        .anchoredCard(
            isPresented: $showWalletPanel,
            size: theme.assignedPickerCardSize(CGSize(width: PickerCardMetrics.infoCardWidth, height: walletPanelHeight)),
            alignment: .trailing,
            constrainToWindow: true,
            takesFocus: walletPanelPinned,
            accessibilityLabel: L("Credits")
        ) {
            WalletPopover(
                sessionSpend: isRouterBilledSession ? sessionSpendDisplay : nil,
                sessionCachedInputLabel: isRouterBilledSession ? sessionCachedInputLabel : nil,
                isAttention: isRouterBilledSession && balanceLevel != .healthy,
                onAddCredits: {
                    closeWalletPanel()
                    onAddCredits?()
                },
                onViewAll: {
                    closeWalletPanel()
                    AppDelegate.shared?.showManagementWindow(initialTab: .credits)
                },
                onHeightChange: { walletPanelHeight = $0 }
            )
            .contentShape(Rectangle())

        }
        .onChange(of: showWalletPanel) { _, isShown in
            // Outside-click dismissal resets the next explicit activation.
            if !isShown {
                walletPanelPinned = false
                walletPanelHeight = 0
            }
        }
    }

    private var chipBalanceDisplay: String {
        if let value = inspectionBalance { return OsaurusRouter.formatMicroAsCreditsCompact(String(value)) }
        return accountService.compactFormattedBalance
    }

    /// The chip's icon + amount/CTA line, shared by the `SelectorChip`
    /// (balance states) and the amber CTA pill (empty state).
    @ViewBuilder
    private func chipLabel(
        style: CreditsChipStyle,
        caption: CGFloat,
        showIcon: Bool,
        showLabel: Bool
    ) -> some View {
        HStack(spacing: theme.catalogLayoutMetric("component.library.23.elements.layout.floatingCreditsChip.content.horizontalGap", inheriting: theme.assignedMetric("component.library.23.gap", fallback: theme.space.s4))) {
            if showIcon {
                Image(systemName: style.iconName)
                    .glyphSize(.micro)
                    .composerChipInk("accent", fallback: style.iconColor)
                    .contentTransition(.symbolEffect(.replace))
            }

            if showLabel {
                if style.showsAmount {
                    // Composer shows the overall router balance; this session's
                    // spend is surfaced in the wallet panel. Abbreviated
                    // ("212.1K credits") so six-figure balances don't crowd
                    // the meta cluster.
                    Text(verbatim: chipBalanceDisplay)
                        .composerChipTextStyle(.footnote, monospacedDigit: true, family: .code, property: "text")
                        .composerChipOriginalWeight(style.weight)
                        .composerChipInk("foreground", fallback: style.textColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    Text("Add Credits", bundle: .module)
                        .composerChipTextStyle(.footnote)
                        .composerChipOriginalWeight(style.weight)
                        .composerChipInk("foreground", fallback: style.textColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }.catalogLayoutTarget("component.library.23.elements.layout.floatingCreditsChip.content.horizontalGap")
    }

    private func handleChipTap(level: BalanceLevel) {
        // Empty state: the chip IS the "Add Credits" call to action, so a
        // click opens the top-up sheet directly — routing it through the
        // wallet panel just to click a second "Add Credits" there was an
        // extra hop with no information gain.
        if level == .empty, let onAddCredits {
            showWalletPanel = false
            walletPanelPinned = false
            onAddCredits()
            return
        }
        // Otherwise click pins the wallet panel (rather than jumping straight
        // to the top-up sheet) so its actions stay reachable; a second click
        // while pinned closes it.
        if showWalletPanel && walletPanelPinned {
            showWalletPanel = false
            walletPanelPinned = false
        } else {
            walletPanelPinned = true
            showWalletPanel = true
        }
    }

    private func closeWalletPanel() {
        showWalletPanel = false
        walletPanelPinned = false
    }
}

/// Context/token indicator on the right edge of the selector row. Extracted
/// from `FloatingInputCard` so popover presentation state re-renders only this
/// chip. All budget math stays in the parent (it also gates sending); this
/// view just renders the passed values. `breakdown` is a closure so the
/// panel's content is computed only while it is open.
private struct FloatingContextChip: View {
    /// Read the shared disk-cache gauge. Returns nil when no quota is
    /// configured (disk cache off), so the popover hides the section rather
    /// than showing a meaningless 0 GB.
    nonisolated static func readDiskCacheUsage(model: String?, session: String?) async -> DiskCacheUsage? {
        let settings = ServerRuntimeSettingsStore.snapshot()
        let directory = ModelRuntime.cacheDiskDirectoryOverride(for: settings.cache)
        let dir = ModelRuntime.diskCacheDirectoryForDisplay(for: settings.cache)
        let volume = DiskCacheVolumeSnapshot.read(directory: dir)
        guard directory != nil else {
            return DiskCacheUsage(
                usedBytes: Int(clamping: volume.ownBytes ?? 0), maxBytes: 0,
                evictions: 0, isDisabled: true
            )
        }
        if let snapshot = await ModelRuntime.shared.diskCacheQuotaSnapshots(
            matching: settings.cache, modelName: model, session: session
        ).first {
            return snapshot.usage
        }
        // No resident model: report indexed ownership, not unrelated files in the directory.
        guard let ownBytes = volume.ownBytes else { return nil }
        let resolution = ModelRuntime.diskCacheCap(for: settings.cache, directory: dir)
        return DiskCacheUsage(
            usedBytes: Int(clamping: ownBytes), maxBytes: Int(clamping: resolution.capBytes),
            evictions: 0
        )
    }

    let displayTokens: Int
    let usableTokens: Int?
    let modelMaxTokens: Int?
    let windowResolution: AgentLoopBudget.ContextWindowResolution?
    let isStreaming: Bool
    let isNearLimit: Bool
    let isHardOverflow: Bool
    /// Fraction of the effective budget the next send occupies, driving the
    /// progress ring. nil when the model window is unknown (empty ring).
    let usageRatio: Double?
    let formatTokenCount: (Int) -> String
    let breakdown: () -> ContextBreakdown
    /// LLM compaction state + manual trigger, rendered inside the popover.
    var compactionState: ContextCompactionUIState = .idle
    var canCompact: Bool = false
    var onCompact: (() -> Void)? = nil
    /// The chat this chip belongs to. The disk-cache note is shown only when
    /// the cap had to take THIS chat's saved progress.
    var currentSessionKey: String? = nil
    var currentModel: String? = nil

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var componentEnabled

    @State private var showContextBreakdown = false
    /// A clicked panel stays open until outside-click or another trigger click.
    @State private var contextPanelPinned = false
    /// Measured before the first presentation, then updated as sections
    /// expand or the disk-cache reading lands.
    @State private var contextPanelHeight: CGFloat = 0
    /// Live disk-cache reading, refreshed only while the popover is open so an
    /// idle chat does not poll the cache index on a timer.
    @State private var diskCacheUsage: DiskCacheUsage?
    private var contextWarningColor: Color? {
        return !componentEnabled ? theme.assignedColor("component.library.23.disabledForeground", fallback: theme.text.disabled)
            : isHardOverflow ? theme.assignedColor("component.library.23.error", fallback: theme.status.error.foreground)
            : isNearLimit ? theme.status.warning.foreground : nil
    }
    var body: some View {
        let warningColor = contextWarningColor
        let prefix = isStreaming ? "" : "~"
        let tokenText =
            if let maxCtx = usableTokens {
                "\(prefix)\(formatTokenCount(displayTokens)) / \(formatTokenCount(maxCtx))"
            } else {
                "\(prefix)\(formatTokenCount(displayTokens))"
            }

        Button {
            if showContextBreakdown && contextPanelPinned {
                showContextBreakdown = false
                contextPanelPinned = false
            } else {
                contextPanelPinned = true
                showContextBreakdown = true
            }
        } label: {
            // Circular budget gauge. Ring-state tinting: amber at ≥85% of
            // the window (soft warning — compaction will engage), red when
            // the non-compactable prefix alone can't fit (send is gated).
            ZStack {
                // Track color comes from a TEXT token, not a border token:
                // borders are tuned to be faint against the background in
                // many themes, while text tokens are guaranteed legible in
                // every theme (custom themes must define them too), so the
                // unused portion of the ring stays visible everywhere. The
                // track is as thick as the arc: the chip's border width
                // resolves to zero, which left only a short arc that read
                // as a stray dash beside the mic.
                Circle()
                    .stroke(theme.text.disabled, lineWidth: theme.stroke.focus)
                Circle()
                    .trim(from: 0, to: CGFloat(min(1, max(0, usageRatio ?? 0))))
                    .stroke(
                        warningColor ?? theme.assignedColor("component.library.23.accent", fallback: theme.status.info.foreground),
                        style: StrokeStyle(lineWidth: theme.stroke.focus, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 15, height: 15)
            .frame(width: 24, height: 24)
            .contentShape(Circle())
            .animation(theme.motion.quick, value: usageRatio)
        }
        .composerChipButtonStyle()
        .composerChipFocus()
        .pointingHandCursor()
        .help(
            isHardOverflow
                ? String(
                    localized:
                        "Context is full: the system prompt, tools, and input alone exceed this model's window. Shorten the input, disable tools, or pick a larger-context model.",
                    bundle: .module
                )
                : isNearLimit
                    ? String(
                        localized:
                            "Context is nearly full (≥85% of the model window). Older messages will be compacted; consider starting a fresh chat for best quality.",
                        bundle: .module
                    )
                    : String(localized: "Context used: \(tokenText) tokens", bundle: .module)
        )
        .accessibilityLabel(
            Text("Context budget: \(tokenText) tokens", bundle: .module)
        )

        .anchoredCard(
            isPresented: $showContextBreakdown,
            size: theme.assignedPickerCardSize(CGSize(width: PickerCardMetrics.infoCardWidth, height: contextPanelHeight)),
            alignment: .trailing,
            constrainToWindow: true,
            takesFocus: contextPanelPinned,
            accessibilityLabel: L("Context Budget")
        ) {
            // `anchoredCard` builds its content on every render, so gate it
            // to keep `breakdown()` from running while the panel is closed.
            if showContextBreakdown {
                contextPanel
            }
        }
        .onChange(of: showContextBreakdown) { _, isShown in
            // Outside-click dismissal resets the next explicit activation.
            if !isShown {
                contextPanelPinned = false
                contextPanelHeight = 0
            }
        }
    }

    private var contextPanel: some View {
        ContextBreakdownPopover(
            breakdown: breakdown(),
            maxTokens: usableTokens,
            modelMaxTokens: modelMaxTokens,
            modelLimitSource: windowResolution?.source,
            isStreaming: isStreaming,
            isNearLimit: isNearLimit,
            isHardOverflow: isHardOverflow,
            formatTokenCount: formatTokenCount,
            compactionState: compactionState,
            canCompact: canCompact,
            onCompact: onCompact,
            diskCache: diskCacheUsage,
            currentSessionKey: currentSessionKey,
            onHeightChange: { contextPanelHeight = $0 }
        )
        .task(id: SSDQuotaNoticePollContext(
            model: currentModel,
            session: currentSessionKey.flatMap(UUID.init(uuidString:)),
            eligible: showContextBreakdown
        )) {
            // Poll while open. The cache index is a small SQLite read, but
            // it is still I/O, so it runs off the main actor and stops as
            // soon as the panel closes.
            guard showContextBreakdown else { return }
            while !Task.isCancelled {
                let model = currentModel, session = currentSessionKey
                let reading = await Task.detached(priority: .utility) {
                    await Self.readDiskCacheUsage(model: model, session: session)
                }.value
                guard !Task.isCancelled else { return }
                diskCacheUsage = reading
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .contentShape(Rectangle())

    }

}

// MARK: - Voice Children

/// Hosts `VoiceInputOverlay` and feeds it the live speech fields
/// (`audioLevel` publishes per audio buffer while recording) from its own
/// observation, so those high-frequency updates re-render only the overlay —
/// never the whole card. All non-speech parameters pass through from the
/// parent unchanged.
private struct FloatingVoiceOverlayHost: View {
    @Binding var state: VoiceInputState
    let pauseDuration: Double
    let confirmationDelay: Double
    let silenceDuration: Double
    let silenceTimeoutDuration: Double
    let silenceTimeoutProgress: Double
    let isContinuousMode: Bool
    let isStreaming: Bool
    let transcriptionStopMode: TranscriptionStopMode
    let onCancel: () -> Void
    let onSend: (String) -> Void
    let onEdit: () -> Void

    @ObservedObject private var speechService = SpeechService.shared

    var body: some View {
        VoiceInputOverlay(
            state: $state,
            audioLevel: speechService.audioLevel,
            transcription: speechService.currentTranscription,
            confirmedText: speechService.confirmedTranscription,
            pauseDuration: pauseDuration,
            confirmationDelay: confirmationDelay,
            silenceDuration: silenceDuration,
            silenceTimeoutDuration: silenceTimeoutDuration,
            silenceTimeoutProgress: silenceTimeoutProgress,
            isContinuousMode: isContinuousMode,
            isStreaming: isStreaming,
            transcriptionStopMode: transcriptionStopMode,
            onCancel: onCancel,
            onSend: onSend,
            onEdit: onEdit
        )
    }
}

/// Mic button for the composer button bar. Owns the reactive reads that
/// gate and style it (`downloadedModelsCount`, `isLoadingModel`) so speech
/// service updates re-render only this button. Renders nothing when voice
/// is not configured — the same visibility the parent's inline
/// `if isVoiceConfigured` gate produced.
private struct FloatingVoiceButton: View {
    /// `voiceConfig.voiceInputEnabled` from the parent's loaded configuration.
    let voiceInputEnabled: Bool
    let isStreaming: Bool
    let startVoiceInput: () -> Void

    @ObservedObject private var speechService = SpeechService.shared
    @ObservedObject private var speechModelManager = SpeechModelManager.shared

    private var isVoiceConfigured: Bool {
        voiceInputEnabled && speechModelManager.downloadedModelsCount > 0
    }

    var body: some View {
        if isVoiceConfigured {
            button
                .disabled(isStreaming)
        }
    }

    private var button: some View {
        // Only render the disabled "loading…" state when mic access has
        // actually been granted. For `.notDetermined`/`.denied` the model
        // can't be used yet, and a background autoload (e.g.
        // `SpeechService.autoLoadIfNeeded` at launch) would otherwise
        // freeze the button and swallow the tap that needs to surface
        // either the system mic prompt or the denied alert.
        // Read the service's published mirror rather than
        // `AVCaptureDevice.authorizationStatus` directly: the direct call is
        // a synchronous TCC daemon round-trip, and this getter runs on every
        // body evaluation. The mirror is seeded at launch, re-checked on app
        // activation, and updated by the request path, so it can only lag
        // across an in-Settings toggle while the app stays frontmost — the
        // same staleness every other voice surface already accepts.
        let micAuthorized = speechService.microphonePermissionGranted
        return Group {
            if speechService.isLoadingModel && micAuthorized {
                // Original disabled-spinner state — only when mic is
                // already authorized, since otherwise no model load is
                // running and the tap must remain free to surface either
                // the system prompt or the denied alert.
                InputActionButton(
                    icon: "mic.fill",
                    help: "Loading voice model…",
                    action: {}
                )
                .overlay(
                    SettingsSpinner()
                        .allowsHitTesting(false)
                )
                .disabled(true)
            } else {
                InputActionButton(
                    icon: "mic.fill",
                    help: "Voice input (speak to type)",
                    action: { startVoiceInput() }
                )
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}

/// Syncs the card's voice state with `SpeechService` transitions. Lives in
/// its own modifier node (like `VoiceDebugObservers`) so observing the
/// service — whose `audioLevel` publishes per audio buffer while recording —
/// re-runs only this modifier's lightweight body, not the card's. The
/// side effects write back through bindings, which invalidate the card only
/// when a watched transition actually fires.
private struct VoiceStateSyncObservers: ViewModifier {
    @Binding var voiceInputState: VoiceInputState
    @Binding var showVoiceOverlay: Bool
    @Binding var lastVoiceActivityTime: Date
    @Binding var lastSpeechTime: Date
    @Binding var hasDetectedSpeechThisTurn: Bool
    let resetPauseDetectionForRecording: () -> Void

    @ObservedObject private var speechService = SpeechService.shared

    func body(content: Content) -> some View {
        content
            .onChange(of: speechService.isRecording) { _, isRecording in
                print(
                    "[FloatingInputCard] isRecording changed to: \(isRecording). voiceInputState: \(voiceInputState), showVoiceOverlay: \(showVoiceOverlay)"
                )
                // Sync voice state with service
                if isRecording {
                    if voiceInputState == .idle && showVoiceOverlay {
                        voiceInputState = .recording
                        lastVoiceActivityTime = Date()
                        resetPauseDetectionForRecording()
                        print("[FloatingInputCard] Recording confirmed - voice input ready")
                    } else if voiceInputState == .idle {
                        print("[FloatingInputCard] External recording detected. Overlay: \(showVoiceOverlay)")
                        voiceInputState = .recording
                        lastVoiceActivityTime = Date()
                        resetPauseDetectionForRecording()
                    }
                } else {
                    // If service stopped recording (e.g. via Esc key in ChatView), sync local state.
                    // Preserve `.sending` so the overlay stays up during LLM cleanup.
                    if voiceInputState != .idle && voiceInputState != .sending {
                        voiceInputState = .idle
                        showVoiceOverlay = false
                    }
                }
            }
            .onChange(of: speechService.isSpeechDetected) { _, detected in
                if detected && voiceInputState == .recording {
                    hasDetectedSpeechThisTurn = true
                    lastSpeechTime = Date()
                }
            }
            .onChange(of: speechService.currentTranscription) { _, newValue in
                // When new transcription arrives, user is speaking
                // Only reset silence timer if there is also active audio detection or meaningful level
                if voiceInputState == .recording && TranscriptionTextNormalizer.hasVisibleText(newValue) {
                    if speechService.isSpeechDetected || speechService.audioLevel > 0.05 {
                        hasDetectedSpeechThisTurn = true
                        lastSpeechTime = Date()
                    }
                }
            }
            .onChange(of: speechService.confirmedTranscription) { _, newValue in
                // When confirmed transcription changes, user was speaking
                if voiceInputState == .recording && TranscriptionTextNormalizer.hasVisibleText(newValue) {
                    if speechService.isSpeechDetected || speechService.audioLevel > 0.05 {
                        hasDetectedSpeechThisTurn = true
                        lastSpeechTime = Date()
                    }
                }
            }
    }
}

/// Observation firewall for the selector row. Sandbox provisioning publishes
/// per-progress-tick during runtime downloads and the clipboard service
/// publishes on every copy; hosting those subscriptions here means their
/// updates re-render only this subtree. The wrapped closure captures the
/// card value and re-reads the live singleton state (via the card's derived
/// properties) each time this scope's body runs, so the chips always render
/// current sandbox/clipboard state without the card observing either object.
private struct ChipObservationScope<Content: View>: View {
    @ObservedObject private var sandboxState = SandboxManager.State.shared
    @ObservedObject private var clipboardService = ClipboardService.shared
    /// The card's composer text model: the row's context chip shows a live
    /// token count that includes what's being typed, so the row re-renders
    /// per keystroke here instead of the whole card observing the text.
    @ObservedObject var textModel: ComposerTextModel
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
    }
}

/// Observation firewall for the popups + input card subtree. Keystrokes
/// publish through `ComposerTextModel`, re-rendering only this scope's
/// content — the card holds the model as plain `@State` (the reference never
/// changes) so typing never invalidates the card body. The closure re-reads
/// the model's current text through the card's derived properties on every
/// scope render.
private struct ComposerTextObservationScope<Content: View>: View {
    @ObservedObject var model: ComposerTextModel
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
    }
}

/// Reference-type home for the composer's typed text. See
/// `FloatingInputCard.composerText` for the invalidation contract.
final class ComposerTextModel: ObservableObject {
    @Published var text: String = ""
}

/// A single sweep through the placeholder glyphs when a new idea appears.
/// The view disappears with the placeholder, cancelling its task on typing.
private struct WorkflowPlaceholderGlimmer: ViewModifier {
    @Environment(\.theme) private var theme
    let phrase: String
    let enabled: Bool
    let color: Color
    @State private var progress: CGFloat = 0

    func body(content: Content) -> some View {
        content.overlay {
            if enabled {
                GeometryReader { geometry in
                    let band = max(48, geometry.size.width * 0.3)
                    LinearGradient(colors: [.clear, color.opacity(0.65), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: band)
                        .offset(x: -band + progress * (geometry.size.width + band))
                }
                .mask(content)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .task(id: enabled ? phrase : "") {
            guard enabled else { return }
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { progress = 0 }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(theme.motion.timed(.easeInOut, duration: 1.14)) { progress = 1 }
        }
    }
}

private extension View {
    @ViewBuilder func composerPlaceholderTypography(theme: any ThemeProtocol) -> some View {
        assignedTypography("component.library.21.text", fallback: SettingsFont.rowDescription)
    }
}

#if OSAURUS_DESIGN_INSPECTOR
/// The production mic button's enabled/loading/streaming appearance with local
/// callbacks. Does not alter the service's permission or configured-model gates.
struct InspectorComposerVoiceActionVerification: View {
    @Environment(\.theme) private var theme
    @State private var callbacks = 0
    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack {
                InputActionButton(icon: "mic.fill", help: "Local voice action") { callbacks += 1 }
                InputActionButton(icon: "mic.fill", help: "Voice disabled during streaming") { callbacks += 1 }
                    .disabled(true)
                InputActionButton(icon: "mic.fill", help: "Loading voice model…") { callbacks += 1 }
                    .overlay(SettingsSpinner().allowsHitTesting(false))
                    .disabled(true)
            }
        }
    }
}
#endif

#if OSAURUS_DESIGN_INSPECTOR
/// Existing production chip views with local values. No purchase, permission,
/// provisioning or model actions are used to check their styling.
struct InspectorComposerChipVerification: View {
    @Environment(\.theme) private var theme
    @State private var selected = false
    @State private var callbackCount = 0
    @State private var credits = "Healthy"
    @State private var context = "Normal"
    @State private var compact = "Full"
    @State private var unavailable = false
    private var micro: Int { credits == "Healthy" ? 5_000_000 : credits == "Low" ? 500_000 : 0 }
    private var ratio: Double { context == "Normal" ? 0.42 : context == "Near limit" ? 0.90 : 1.20 }
    var body: some View {
        SettingsSection(title: "Native selector and context variants", layout: .plain, verbatimTitle: true) {
            Picker("Chip density", selection: $compact) {
                ForEach(["Full", "Compact", "Icon only"], id: \.self) { Text(verbatim: $0).tag($0) }
            }
            Toggle("Unavailable selector", isOn: $unavailable)
            SelectorChip(isActive: selected) { selected.toggle(); callbackCount += 1 } content: {
                HStack(spacing: theme.catalogLayoutMetric("component.library.23.elements.layout.inspectorComposerChipVerification.body.horizontalGap", inheriting: theme.assignedMetric("component.library.23.gap", fallback: theme.space.s6))) {
                    Image(systemName: "slider.horizontal.3").composerChipInk("accent", fallback: theme.border.focus)
                    Text(verbatim: "Local selector").composerChipTextStyle(.caption)
                        .composerChipInk("foreground", fallback: theme.text.primary)
                    Text(verbatim: "· Medium").composerChipTextStyle(.caption, property: "caption")
                        .composerChipInk("secondary", fallback: theme.text.secondary)
                }.catalogLayoutTarget("component.library.23.elements.layout.inspectorComposerChipVerification.body.horizontalGap")
            }.disabled(unavailable).accessibilityLabel("Local selector")
            Picker("Local credits state", selection: $credits) {
                ForEach(["Healthy", "Low", "Empty"], id: \.self) { Text(verbatim: $0).tag($0) }
            }
            FloatingCreditsChip(isRouterBilledSession: true, sessionSpendMicro: 125_000,
                sessionCachedInputLabel: nil, metaCompact: compact != "Full", metaUltraCompact: compact == "Icon only",
                onAddCredits: { callbackCount += 1 }, inspectionBalance: micro)
            FloatingWorkspacePoolChip(workspaceName: "Local verification workspace with a long name", workspaceId: nil,
                spendMicro: 125_000, metaCompact: compact != "Full", metaUltraCompact: compact == "Icon only")
            Picker("Local context state", selection: $context) {
                ForEach(["Normal", "Near limit", "Overflow"], id: \.self) { Text(verbatim: $0).tag($0) }
            }
            FloatingContextChip(displayTokens: Int(ratio * 10_000), usableTokens: 10_000, modelMaxTokens: 10_000,
                windowResolution: nil, isStreaming: false, isNearLimit: context == "Near limit", isHardOverflow: context == "Overflow",
                usageRatio: ratio, formatTokenCount: { String($0) }, breakdown: { .zero })
        }
    }
}
#endif

/// Account usage opens on click from either main destination.
/// Outside-click, Escape, the trigger or an action closes the panel.
struct NavigationUsageButton: View {
    @ObservedObject private var account = OsaurusRouterAccountService.shared
    @Environment(\.theme) private var environmentTheme
    private var theme: any ThemeProtocol { environmentTheme }
    @State private var interaction = ClickMenuInteraction()
    @AppStorage("designInspector.previewCreditsData") private var previewCreditsData = true
    private var usesPreviewData: Bool {
        previewCreditsData
    }
    private var balanceTitle: String {
        if usesPreviewData { return "138,376 credits · Preview" }
        return account.balance == nil ? L("Usage unavailable") : account.formattedBalanceValue + " " + L("credits")
    }
    @State private var showTopUp = false

    private var rows: [WalletActivityRow] {
        if usesPreviewData {
            return [
                WalletActivityRow(id: "preview-grant", kind: .transaction, title: "Credits grant", amountLabel: "+100,000 credits", isCredit: true, stateKind: .success, date: nil),
                WalletActivityRow(id: "preview-model-1", kind: .usage, title: "deepseek-v4-1-flash", amountLabel: "−13 credits", isCredit: false, stateKind: .secondary, date: nil),
                WalletActivityRow(id: "preview-added", kind: .transaction, title: "Credits added", amountLabel: "+50,000 credits", isCredit: true, stateKind: .success, date: nil),
                WalletActivityRow(id: "preview-model-2", kind: .usage, title: "Claude Sonnet", amountLabel: "−11,200 credits", isCredit: false, stateKind: .secondary, date: nil),
                WalletActivityRow(id: "preview-web", kind: .webUsage, title: "Web search", amountLabel: "−411 credits", isCredit: false, stateKind: .secondary, date: nil)
            ]
        }
        return WalletActivityProjector().rows(usageItems: account.usage, transactions: account.transactions,
                                      webUsageItems: account.webUsage, limit: 5)
    }

    var body: some View {
        SettingsIconButton("cloud", help: "Usage", size: .regular, isActive: interaction.isPresented, role: .tertiary) {

            interaction.clickTrigger()
        }
        .frame(width: 32, height: 32)

        .anchoredCard(isPresented: $interaction.isPresented, size: CGSize(width: 240, height: 217),
                      alignment: .leading, besideAnchor: true, constrainToWindow: true, takesFocus: interaction.takesFocus,
                      shadowPadding: 18, accessibilityLabel: L("Usage")) {
            VStack(spacing: theme.space.s12) {
                Text(balanceTitle)
                    .textStyle(.body)
                    .foregroundStyle(theme.text.primary)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background(theme.surface.subtle, in: RoundedRectangle(cornerRadius: theme.radius.small))
                if rows.isEmpty {
                    Text(account.balance == nil ? L("Connect to view your usage") : L("No activity yet"))
                        .componentInspectionText(51, role: .caption, fallback: .caption, theme: theme)
                        .foregroundStyle(theme.text.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: theme.space.s8) {
                        ForEach(rows) { row in
                            HStack(spacing: theme.space.s8) {
                                Text(verbatim: row.title).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                Text(verbatim: row.amountLabel.replacingOccurrences(of: " credits", with: ""))
                                    .monospacedDigit().fixedSize()
                                    .foregroundStyle(row.isCredit ? theme.status.success.foreground : theme.text.tertiary)
                            }
                            .textStyle(.caption)
                            .foregroundStyle(row.isCredit ? theme.status.success.foreground : theme.text.secondary)
                        }
                    }.padding(.horizontal, theme.space.s8)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                Rectangle().fill(theme.surface.overlay).frame(height: theme.stroke.default)
                HStack {
                    SettingsButton(.tertiary, "Add Credits", icon: "plus", size: .extraSmall) {
                        interaction.didDismiss(); showTopUp = true
                    }
                    Spacer()
                    Button {
                        interaction.didDismiss()
                        AppDelegate.shared?.showManagementWindow(initialTab: .credits)
                    } label: {
                        HStack(spacing: theme.space.s4) {
                            Text("Manage", bundle: .module)
                            Image(systemName: "arrow.right")
                        }
                    }.buttonStyle(.settings(.tertiary, size: .extraSmall))
                }
            }
            .padding(theme.space.s6 + theme.stroke.default)
            .chatContextMenuSurface()
            .themeElevation(theme.elevation.overlay)

            .task(id: usesPreviewData) {
                guard !usesPreviewData else { return }
                await account.refreshBalance()
                await account.refreshUsage(reset: true)
                await account.refreshTransactions(reset: true)
                await account.refreshWebUsage(reset: true)
            }
        }
        .onChange(of: interaction.isPresented) { _, shown in
            if !shown { interaction.didDismiss() }
        }
        .onDisappear { interaction.didDismiss() }
        .sheet(isPresented: $showTopUp) { CreditsTopUpSheet() }
    }

}
