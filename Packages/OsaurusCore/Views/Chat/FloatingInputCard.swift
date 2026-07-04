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

struct FloatingInputCard: View {
    @Binding var text: String
    @Binding var selectedModel: String?
    @Binding var pendingAttachments: [Attachment]
    /// When true, voice input auto-restarts after AI responds (continuous conversation mode)
    @Binding var isContinuousVoiceMode: Bool
    @Binding var voiceInputState: VoiceInputState
    @Binding var showVoiceOverlay: Bool
    let pickerItems: [ModelPickerItem]
    @Binding var activeModelOptions: [String: ModelOptionValue]
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
    /// Per-category breakdown of context token usage
    var contextBreakdown: ContextBreakdown = .zero
    /// Total micro-USD spent on the Osaurus Router this session.
    var sessionSpendMicro: Int = 0
    /// Whether to show the session spend chip (true only for Osaurus Router sessions).
    var showSessionSpend: Bool = false
    @Binding var imageComposerSettings: ImageComposerSettings
    let onSend: (String?) -> Void
    let onStop: () -> Void
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
    /// Callback to capture the current screen as a local chat artifact.
    var onCaptureScreenshot: (() -> Void)?
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
    /// Invoked when the user taps the credits chip (opens the top-up sheet).
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
    /// Mode 2 (remote agent run): the conversation targets a discovered remote
    /// agent that executes its own tool loop, system prompt, and generation
    /// config server-side. Hides the composer's local-only affordances —
    /// sandbox, working folder, screen-context, and the thinking / model-option
    /// chips — because none of them are sent to (or honored by) the remote peer.
    var isRemoteAgentRun: Bool = false

    init(
        text: Binding<String>,
        selectedModel: Binding<String?>,
        pendingAttachments: Binding<[Attachment]>,
        isContinuousVoiceMode: Binding<Bool>,
        voiceInputState: Binding<VoiceInputState>,
        showVoiceOverlay: Binding<Bool>,
        pickerItems: [ModelPickerItem],
        activeModelOptions: Binding<[String: ModelOptionValue]>,
        isStreaming: Bool,
        isPrivacyReviewSheetVisible: Bool = false,
        supportsImages: Bool,
        estimatedContextTokens: Int,
        contextBreakdown: ContextBreakdown = .zero,
        sessionSpendMicro: Int = 0,
        showSessionSpend: Bool = false,
        imageComposerSettings: Binding<ImageComposerSettings> = .constant(ImageComposerSettings()),
        onSend: @escaping (String?) -> Void,
        onStop: @escaping () -> Void,
        focusTrigger: Int = 0,
        agentId: UUID? = nil,
        windowId: UUID? = nil,
        isCompact: Bool = false,
        isEmptyChat: Bool = false,
        onClearChat: (() -> Void)? = nil,
        onCaptureScreenshot: (() -> Void)? = nil,
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
        isRemoteAgentRun: Bool = false
    ) {
        self._text = text
        self._selectedModel = selectedModel
        self._pendingAttachments = pendingAttachments
        self._isContinuousVoiceMode = isContinuousVoiceMode
        self._voiceInputState = voiceInputState
        self._showVoiceOverlay = showVoiceOverlay
        self.pickerItems = pickerItems
        self._activeModelOptions = activeModelOptions
        self.isStreaming = isStreaming
        self.isPrivacyReviewSheetVisible = isPrivacyReviewSheetVisible
        self.supportsImages = supportsImages
        self.estimatedContextTokens = estimatedContextTokens
        self.contextBreakdown = contextBreakdown
        self.sessionSpendMicro = sessionSpendMicro
        self.showSessionSpend = showSessionSpend
        self._imageComposerSettings = imageComposerSettings
        self.onSend = onSend
        self.onStop = onStop
        self.focusTrigger = focusTrigger
        self.agentId = agentId
        self.windowId = windowId
        self.isCompact = isCompact
        self.isEmptyChat = isEmptyChat
        self.onClearChat = onClearChat
        self.onCaptureScreenshot = onCaptureScreenshot
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
        self.isRemoteAgentRun = isRemoteAgentRun
    }

    // Observe managers for reactive updates
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var folderContextService = FolderContextService.shared
    @ObservedObject private var sandboxState = SandboxManager.State.shared
    @ObservedObject private var clipboardService = ClipboardService.shared
    @ObservedObject private var appConfig = AppConfiguration.shared
    /// Drives the composer credits chip (balance + low-balance tinting) for
    /// Osaurus Router sessions.
    @ObservedObject private var accountService = OsaurusRouterAccountService.shared
    /// Frontmost-app source + Accessibility status for the read-only
    /// screen-context chip (shown only on the empty/welcome screen). The opt-in
    /// gate is now per-agent (a child of Computer Use), read via `agentManager`.
    @ObservedObject private var frontmostApp = FrontmostAppTracker.shared
    @ObservedObject private var permissionService = SystemPermissionService.shared

    // MARK: - Slash Command State

    private var slashRegistry = SlashCommandRegistry.shared
    @State private var slashSelectedIndex: Int = 0

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
        return slashRegistry.filtered(query: query)
    }

    private var showSlashPopup: Bool {
        activeSlashQuery != nil && !slashFilteredCommands.isEmpty
    }

    // Local state for text input to prevent parent re-renders on every keystroke
    @State private var localText: String = ""
    @State private var isFocused: Bool = false
    @State private var isComposing: Bool = false
    /// Keeps focus in the input through the send/queue state cascade.
    /// `syncAndSend` and `sendNowButton` arm `lockFocus(for:)` before
    /// the mutations that would otherwise let AppKit blur the field.
    @StateObject private var textViewFocusController = TextViewFocusController()
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var isDragOver = false
    @State private var showModelPicker = false
    @State private var showModelOptionsPicker = false
    @State private var showImageSizePicker = false
    @State private var showContextBreakdown = false
    @State private var contextHoverTask: Task<Void, Never>?
    /// Delayed dismiss for the context popover. Gives the cursor a grace
    /// period to travel from the trigger into the popover (which lives in its
    /// own window, so hovering it doesn't keep the trigger "hovered").
    @State private var contextDismissTask: Task<Void, Never>?
    @State private var showBalanceBreakdown = false
    @State private var balanceHoverTask: Task<Void, Never>?
    @State private var isSandboxHovered = false
    @State private var sandboxPulseAmount: CGFloat = 1.0
    @State private var sandboxPulseTask: Task<Void, Never>? = nil
    @State private var isClipboardHovered = false
    @State private var clipboardPulseAmount: CGFloat = 0.0
    @State private var clipboardPulseOpacity: Double = 0.0
    // Cache picker items to prevent popover refresh during streaming
    @State private var cachedPickerItems: [ModelPickerItem] = []
    // MARK: - Voice Input State
    @ObservedObject private var speechService = SpeechService.shared
    @ObservedObject private var speechModelManager = SpeechModelManager.shared
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
    private var inputFontSize: CGFloat { CGFloat(theme.bodySize) }
    private let maxVisibleLines: CGFloat = 6
    private var maxHeight: CGFloat {
        // Approximate line height from font metrics (ascender/descender/leading)
        let lineHeight = Self.lineHeight(forFontSize: inputFontSize)
        // Small extra padding so the last line isn't cramped
        return lineHeight * maxVisibleLines + 8
    }

    // `NSFont.systemFont(ofSize:)` plus the ascender/descender/leading reads run
    // on the main thread inside `body`/`sizeThatFits` on every layout pass, and
    // the underlying font-descriptor/dynamic-type lookups have shown up as app
    // hangs during layout. Line height is a pure function of the point size, so
    // memoize it and serve the memo thereafter.
    private static let lineHeightCacheLock = NSLock()
    private nonisolated(unsafe) static var lineHeightCache: [CGFloat: CGFloat] = [:]
    private static func lineHeight(forFontSize size: CGFloat) -> CGFloat {
        lineHeightCacheLock.lock()
        defer { lineHeightCacheLock.unlock() }
        if let cached = lineHeightCache[size] { return cached }
        let font = NSFont.systemFont(ofSize: size)
        let lineHeight = font.ascender - font.descender + font.leading
        lineHeightCache[size] = lineHeight
        return lineHeight
    }
    private let maxImageSize: Int = 10 * 1024 * 1024  // 10MB limit

    private var canSend: Bool {
        // While the slash command popup is visible, Enter selects a command — not sends
        guard !showSlashPopup else { return false }

        // Remote-agent (Mode 2) connect + model pin still resolving: block the
        // send so the first message can't race the async connect and fail with
        // a misleading "model not found". The parent shows a connecting notice.
        guard !remoteConnectionPending else { return false }

        // Hard token gate: when the NON-compactable prefix alone (system
        // prompt + tools + memory + input + response reservation) can't
        // fit the model window, the request would fail no matter how much
        // history compaction trims. Block the send and let the context
        // chip explain, instead of letting the model error mid-stream.
        // History-driven growth is deliberately NOT gated — compaction
        // handles that.
        guard !isContextHardOverflow else { return false }

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

    /// Context tokens including what's currently being typed (localText may differ from text binding)
    private var displayContextTokens: Int {
        displayContextBreakdown.total
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

    /// Max context length for the selected model — the SAME resolution the
    /// runtime loop uses (`AgentLoopBudget`), so the chip's denominator and
    /// the trim budget never diverge.
    private var maxContextTokens: Int? {
        guard let model = selectedModel else { return nil }
        return AgentLoopBudget.resolveContextWindowSync(modelId: model)
    }

    // MARK: - Context budget gating

    /// Shared UI/runtime budget math (`AgentLoopBudget.assess`): ratio and
    /// thresholds are computed against the EFFECTIVE budget (window ×
    /// safety margin) the runtime trims against, the hard gate excludes
    /// compactable history, and the response reservation is included.
    private var budgetAssessment: AgentLoopBudget.Assessment {
        guard let maxCtx = maxContextTokens else { return .empty }
        // Real per-agent max_tokens (not the 4096 default) so the chip's
        // hard-overflow gate reserves exactly what the runtime loop will.
        return AgentLoopBudget.assess(
            breakdown: displayContextBreakdown,
            contextWindow: maxCtx,
            maxResponseTokens: agentManager.effectiveMaxTokens(for: effectiveAgentId)
        )
    }

    /// Estimated fraction of the effective budget the next send occupies
    /// (typing included). nil when the window is unknown.
    private var contextUsageRatio: Double? {
        budgetAssessment.usageRatio
    }

    /// Soft warning threshold: at ≥85% of the effective budget the context
    /// chip turns amber. Sends still go through — mid-run compaction is the
    /// overflow handler — but the user should know quality may degrade.
    private var isContextNearLimit: Bool {
        budgetAssessment.nearLimit
    }

    /// Hard overflow: the non-compactable prefix alone — everything
    /// EXCEPT the conversation history (system prompt, tools, memory,
    /// input) — plus the response reservation exceeds the effective
    /// budget. History can be compacted mid-run; this can't, so the send
    /// is blocked with a clear signal instead of a guaranteed model failure.
    private var isContextHardOverflow: Bool {
        budgetAssessment.hardOverflow
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
        guard !remoteConnectionPending else { return false }
        return pickerItems.count > 1
            || isModelPinned
            || (displayContextTokens > 0 && !isRemoteAgentRun)
            || isSandboxAvailable
            || isDefaultConfigAgent
            || (appConfig.chatConfig.enableClipboardMonitoring && clipboardService.hasNewContent)
            || showSessionSpend
    }

    private var mainContent: some View {
        VStack(spacing: 12) {
            // Read-only screen-context indicator sits on its OWN row above the
            // selector row, right-aligned so it stacks directly over the
            // context-token count, rendered as quiet muted text (not a chip)
            // so it reads as passive status rather than a control.
            if !showVoiceOverlay && (showScreenContextIndicator || showSelectorRow) {
                VStack(alignment: .trailing, spacing: 7) {
                    if showScreenContextIndicator {
                        screenContextIndicator
                    }
                    if showSelectorRow {
                        selectorRow
                    }
                }
                .padding(.top, 8)
                .padding(.horizontal, 20)
                // Ease the row out while connecting and back in once connected,
                // so the composer height changes smoothly instead of snapping.
                .transition(.opacity)
            }

            if showVoiceOverlay {
                VoiceInputOverlay(
                    state: $voiceInputState,
                    audioLevel: speechService.audioLevel,
                    transcription: speechService.currentTranscription,
                    confirmedText: speechService.confirmedTranscription,
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
                VStack(spacing: 4) {
                    // Slash command popup — appears above the input card
                    if showSlashPopup {
                        SlashCommandPopup(
                            commands: slashFilteredCommands,
                            selectedIndex: $slashSelectedIndex,
                            onSelect: applySlashCommand
                        )
                        .padding(.horizontal, 20)
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)),
                                removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom))
                            )
                        )
                    }

                    inputCard
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                        .onDrop(of: dropAcceptedTypes, isTargeted: $isDragOver) { providers in
                            handleFileDrop(providers)
                        }
                }
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.98)),
                        removal: .opacity.combined(with: .scale(scale: 0.98))
                    )
                )
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: showVoiceOverlay)
        // Smoothly collapse/reveal the selector row (model chip + balance) as
        // the remote-agent connection resolves, so the composer doesn't snap.
        .animation(theme.springAnimation(), value: remoteConnectionPending)
    }

    var body: some View {
        let _ = ChatPerfTrace.shared.count("body.FloatingInputCard")
        mainContent
            // Float the configuration-context error ABOVE the card as an
            // overlay so it never reflows the input/selector layout when it
            // appears or clears. Anchored to the card's top edge and shifted
            // fully above it via the `.top` alignment guide.
            .overlay(alignment: .top) {
                configContextErrorOverlay
            }
            .animation(.easeOut(duration: 0.2), value: configContextTooSmall)
            .onAppear {
                let isReappear = !localText.isEmpty || voiceInputState != .idle
                localText = text
                print("[VoiceDebug] FloatingInputCard onAppear (reappear=\(isReappear))")

                // Focus immediately when view appears
                isFocused = true

                // Load voice config (cached after first load)
                loadVoiceConfig()

                if voiceConfig.voiceInputEnabled && !speechService.isModelLoaded
                    && !speechService.isLoadingModel
                    && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                {
                    if let model = SpeechModelManager.shared.selectedModel {
                        print("[VoiceDebug] Kicking off model load for: \(model.id)")
                        Task {
                            try? await speechService.loadModel(model.id)
                        }
                    } else {
                        print("[VoiceDebug] No selected model — cannot load")
                    }
                }

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
            .onReceive(NotificationCenter.default.publisher(for: .voiceConfigurationChanged)) { _ in
                // Reload voice config when settings change
                loadVoiceConfig()

                if voiceConfig.voiceInputEnabled && !speechService.isModelLoaded
                    && !speechService.isLoadingModel
                    && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                {
                    if let model = SpeechModelManager.shared.selectedModel {
                        Task { try? await speechService.loadModel(model.id) }
                    }
                }
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
            .onChange(of: localText) { _, _ in
                // Reset popup selection whenever the typed query changes
                slashSelectedIndex = 0
            }
            .onChange(of: showSlashPopup) { _, isVisible in
                // Keep registry in sync so the global key monitor can suppress
                // Escape from closing the window while the popup is open.
                SlashCommandRegistry.shared.isPopupVisible = isVisible
            }
            .onDisappear {
                SlashCommandRegistry.shared.isPopupVisible = false
            }
            .onChange(of: focusTrigger) { _, _ in
                isFocused = true
            }
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
                        NSWorkspace.shared.open(url)
                    }
                },
                secondaryButton: .cancel("Cancel")
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
            print(
                "[VoiceDebug] startVoiceInput called but isVoiceAvailable=false — triggering emergency load if possible"
            )
            if let model = SpeechModelManager.shared.selectedModel, !speechService.isLoadingModel {
                Task { try? await speechService.loadModel(model.id) }
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

        let hasContent = TranscriptionTextNormalizer.hasVisibleText(speechService.currentTranscription)
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

                // try to paste. if it fails (permissions), we fall back to direct text setting
                if KeyboardSimulationService.shared.pasteText(visibleMessage) {
                    // success: clear UI state immediately
                    localText = ""
                    text = ""
                    // small delay before sending to let UI breathe before model starts streaming
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        localText = ""
                        text = ""
                        onSend(fullMessage)
                    }
                } else {
                    // failed (no permission): set text and clear local buffer before sending
                    localText = ""
                    text = ""
                    onSend(fullMessage)
                }
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
        let message = localText
        // Hold first responder through the binding-flush cascade
        // (clearing local + bound text, parent reconcile, optional
        // new run kickoff). 300 ms covers the longest observed
        // cascade with margin. Covers both fresh sends and queueing.
        textViewFocusController.lockFocus(for: 0.3)
        localText = ""
        text = ""
        onSend(message)
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
        }
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
            showModelPicker = true
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
            HStack(spacing: 5) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.accentColor)
                Text("Queued:", bundle: .module)
                    .font(theme.font(size: 11, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                Text(verbatim: preview)
                    .font(theme.font(size: 11, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Button {
                    withAnimation(theme.springAnimation()) {
                        if let onCancelQueued {
                            onCancelQueued()
                        } else {
                            queuedSend = nil
                        }
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(theme.secondaryText)
                        .padding(3)
                        .background(Circle().fill(theme.tertiaryBackground))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .localizedHelp("Cancel queued message")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.accentColor.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.accentColor.opacity(0.3), lineWidth: 0.5)
            )
        }
    }

    // MARK: - Pending Skill Chip

    @ViewBuilder
    private var pendingSkillChipView: some View {
        if let skillId = pendingSkillId,
            let skill = SkillManager.shared.skill(for: skillId)
        {
            HStack(spacing: 5) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.accentColor)
                Text(skill.name)
                    .font(theme.font(size: 11, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    withAnimation(theme.springAnimation()) {
                        pendingSkillId = nil
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(theme.secondaryText)
                        .padding(3)
                        .background(Circle().fill(theme.tertiaryBackground))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.accentColor.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.accentColor.opacity(0.25), lineWidth: 0.5)
            )
        }
    }

    // MARK: - Pending Attachments Preview (Inline)

    private var inlinePendingAttachmentsPreview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(pendingAttachments) { attachment in
                    switch attachment.kind {
                    case .image(let data):
                        CachedImageThumbnail(
                            imageData: data,
                            size: 40,
                            onRemove: {
                                withAnimation(theme.springAnimation()) {
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
                                    withAnimation(theme.springAnimation()) {
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
                                withAnimation(theme.springAnimation()) {
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
                            withAnimation(theme.springAnimation()) {
                                pendingAttachments.removeAll { $0.id == attachment.id }
                            }
                        }
                    }
                }
            }
        }
        .frame(height: 48)
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
        withAnimation(theme.springAnimation()) {
            pendingAttachments.removeAll { $0.id == attachment.id }
        }
        localText = combined
        text = combined
        isFocused = true
    }

    // MARK: - Selector Row (Model + Tools)

    private var activeProfileOptions: [ModelOptionDefinition] {
        guard let model = selectedModel else { return [] }
        return ModelProfileRegistry.options(for: model)
    }

    private var hasNonThinkingOptions: Bool {
        let thinkingId = selectedModel.flatMap { ModelProfileRegistry.profile(for: $0)?.thinkingOption?.id }
        return activeProfileOptions.contains { $0.id != thinkingId }
    }

    private var selectorRow: some View {
        HStack(spacing: 6) {
            if !pickerItems.isEmpty || isModelPinned {
                modelSelectorChip
            }

            // Image-generation models have no thinking, sandbox, folder or
            // token-budget semantics — those chips would all be inert. Swap
            // the whole row for the image config controls instead so they sit
            // right beside the model that owns them.
            if isImageComposerActive {
                // Scroll the config chips horizontally so a narrow (minimum-size)
                // window can't compress them below their ideal width — that
                // compression is what made the labels wrap character-by-character.
                // The ScrollView fills the free space, leaving the negative-prompt
                // button pinned to the right where the token meter normally sits.
                ScrollView(.horizontal, showsIndicators: false) {
                    imageComposerChips
                        .padding(.vertical, 1)
                }
                // The negative prompt sits where the token meter normally would,
                // as a compact button that opens a themed editor on tap.
                if imageCapabilities?.negativePrompt == true {
                    negativePromptButton
                }
            } else {
                // Mode 2 owns its own generation config (thinking + sampler
                // options) server-side; the local toggles wouldn't reach the
                // remote agent, so hide them rather than imply they apply.
                if !isRemoteAgentRun {
                    thinkingToggleChip
                }

                if autoSpeakAssistant {
                    autoSpeakToggleChip
                }

                if hasNonThinkingOptions, !isRemoteAgentRun {
                    modelOptionsSelectorChip
                }

                // Sandbox toggle: visible whenever the sandbox is available on
                // this system. Hidden for the Default agent (configuration-only).
                // Hidden in Mode 2: the remote agent runs its own tools server-side.
                if !isRemoteAgentRun, !isDefaultConfigAgent, isSandboxAvailable {
                    sandboxToggleChip
                }

                // Folder context selector: the Default (configuration) agent shows
                // a quiet "Configuration" indicator instead. Hidden in Mode 2.
                if !isRemoteAgentRun {
                    if isDefaultConfigAgent {
                        configurationOnlyChip
                    } else {
                        folderContextChip
                    }
                }

                // Clipboard / paste chip — last in the left cluster.
                if AppConfiguration.shared.chatConfig.enableClipboardMonitoring && clipboardService.hasNewContent {
                    clipboardToggleChip
                }

                Spacer()

                // Right-aligned "meta" cluster: balance + token usage.
                metaCluster
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
        let showCredits = showSessionSpend && !remoteConnectionPending
        // Mode 2 hides the context-budget chip + popover entirely: a remote
        // agent composes its own system prompt / tools server-side, so a local
        // token breakdown (system prompt, tools, history) doesn't reflect what
        // actually runs and would mislead about the remote agent's budget.
        let showTokens = displayContextTokens > 0 && !isRemoteAgentRun
        if showCredits || showTokens {
            HStack(alignment: .center, spacing: 8) {
                if showCredits {
                    creditsChip
                }
                if showCredits && showTokens {
                    Rectangle()
                        .fill(theme.primaryBorder.opacity(0.25))
                        .frame(width: 1, height: 12)
                }
                if showTokens {
                    contextIndicatorChip
                }
            }
        }
    }

    // MARK: - Credits Indicator

    /// Urgency tiers for the balance indicator. Healthy stays quiet (plain muted
    /// text that blends into the meta cluster); low and empty escalate to an
    /// amber pill so a top-up is easy to notice. Empty/frozen reads as an "Add
    /// credits" call to action — deliberately amber, never error-red, so it
    /// invites action instead of looking like a failure.
    private enum BalanceLevel {
        case healthy
        case low
        case empty
    }

    private var balanceLevel: BalanceLevel {
        let micro = accountService.balanceMicroValue
        if micro <= 0 || accountService.isFrozen {
            return .empty
        }
        if micro < 1_000_000 {  // < $1.00
            return .low
        }
        return .healthy
    }

    /// Resolved visual tokens for one `BalanceLevel` so `creditsChip` can render
    /// declaratively instead of re-deriving each property from the level inline.
    private struct CreditsChipStyle {
        let iconName: String
        let iconColor: Color
        let textColor: Color
        let weight: Font.Weight
        /// Pill fill/stroke; `nil` keeps the chip chrome-free (healthy state).
        let pill: (fill: Color, stroke: Color)?
        let glow: Color
        /// When false, the chip shows the "Add credits" CTA instead of an amount.
        let showsAmount: Bool
    }

    private func creditsStyle(for level: BalanceLevel) -> CreditsChipStyle {
        let amber = theme.warningColor
        switch level {
        case .healthy:
            return CreditsChipStyle(
                iconName: "creditcard",
                iconColor: theme.tertiaryText,
                textColor: theme.secondaryText,
                weight: .medium,
                pill: nil,
                glow: .clear,
                showsAmount: true
            )
        case .low:
            // The chip shows the router balance, so a low balance escalates the
            // chip itself to amber text (no pill) — a gentle nudge that stops
            // short of the empty-state "Add credits" call to action.
            return CreditsChipStyle(
                iconName: "creditcard",
                iconColor: amber,
                textColor: amber,
                weight: .semibold,
                pill: nil,
                glow: .clear,
                showsAmount: true
            )
        case .empty:
            return CreditsChipStyle(
                iconName: "plus.circle.fill",
                iconColor: amber,
                textColor: amber,
                weight: .semibold,
                pill: (amber.opacity(0.22), amber.opacity(0.5)),
                glow: amber.opacity(0.25),
                showsAmount: false
            )
        }
    }

    /// This session's Router spend, formatted for the hover popover. The chip
    /// surfaces the account balance; spend is shown only in the popover.
    private var sessionSpendDisplay: String {
        OsaurusRouter.formatMicroUSDPrecise(String(sessionSpendMicro))
    }

    /// Accessibility text for the credits chip. Describes the router balance the
    /// chip shows and the tap action; session spend lives in the popover.
    private var creditsHelpText: Text {
        if accountService.isFrozen {
            return Text("Account paused - add credits to resume.", bundle: .module)
        }
        return Text("\(accountService.formattedBalance) router balance. Click to add credits.", bundle: .module)
    }

    /// Balance indicator for Osaurus Router sessions. Tapping opens the top-up
    /// sheet; the balance best-effort refreshes on appear so it isn't blank.
    /// Quiet plain text when funded, escalating to an amber pill / "Add credits"
    /// CTA as the balance runs low or hits zero (see `BalanceLevel`).
    @ViewBuilder
    private var creditsChip: some View {
        let level = balanceLevel
        let style = creditsStyle(for: level)
        let caption = CGFloat(theme.captionSize)
        // Hide the icon in compact mode to save width, except the empty-state
        // plus glyph, which signals the chip is actionable.
        let showIcon = !isCompact || level == .empty

        Button {
            onAddCredits?()
        } label: {
            HStack(spacing: 4) {
                if showIcon {
                    Image(systemName: style.iconName)
                        .font(.system(size: caption - 2))
                        .foregroundColor(style.iconColor)
                        .contentTransition(.symbolEffect(.replace))
                }

                if style.showsAmount {
                    // Composer shows the overall router balance; this session's
                    // spend is surfaced only in the hover popover.
                    Text(verbatim: accountService.formattedBalance)
                        .font(.system(size: caption - 1, weight: style.weight, design: .monospaced))
                        .foregroundColor(style.textColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    Text("Add credits", bundle: .module)
                        .font(theme.font(size: caption - 1, weight: style.weight))
                        .foregroundColor(style.textColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            // Chrome only appears in the low/empty attention states; the healthy
            // chip stays plain text to match the token indicator's weight.
            .padding(.horizontal, style.pill == nil ? 0 : 10)
            .padding(.vertical, style.pill == nil ? 0 : 4)
            .background {
                if let pill = style.pill {
                    Capsule()
                        .fill(pill.fill)
                        .overlay(Capsule().strokeBorder(pill.stroke, lineWidth: 1))
                }
            }
            // Soft glow on the empty CTA draws the eye without a repeating animation.
            .shadow(color: style.glow, radius: 5, x: 0, y: 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .accessibilityLabel(creditsHelpText)
        .onHover { hovering in
            balanceHoverTask?.cancel()
            if hovering {
                balanceHoverTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    showBalanceBreakdown = true
                }
            } else {
                showBalanceBreakdown = false
            }
        }
        .popover(isPresented: $showBalanceBreakdown, arrowEdge: .top) {
            BalanceBreakdownPopover(
                sessionSpend: sessionSpendDisplay,
                balance: accountService.formattedBalance,
                isAttention: level != .healthy,
                isFrozen: accountService.isFrozen
            )
        }
        .task(id: showSessionSpend) {
            if showSessionSpend {
                await accountService.refreshBalance()
            }
        }
    }

    // MARK: - Context Indicator

    @ViewBuilder
    private var contextIndicatorChip: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            // Budget-state tinting: amber at ≥85% of the window (soft
            // warning — compaction will engage), red when the
            // non-compactable prefix alone can't fit (send is gated).
            let warningColor: Color? =
                isContextHardOverflow ? .red : (isContextNearLimit ? .orange : nil)

            if let warningColor {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: CGFloat(theme.captionSize) - 2))
                    .foregroundColor(warningColor)
                    .localizedHelp(
                        isContextHardOverflow
                            ? "Context is full: the system prompt, tools, and input alone exceed this model's window. Shorten the input, disable tools, or pick a larger-context model."
                            : "Context is nearly full (≥85% of the model window). Older messages will be compacted; consider starting a fresh chat for best quality."
                    )
            }

            let prefix = isStreaming ? "" : "~"
            let tokenText =
                if let maxCtx = maxContextTokens {
                    "\(prefix)\(formatTokenCount(displayContextTokens)) / \(formatTokenCount(maxCtx))"
                } else {
                    "\(prefix)\(formatTokenCount(displayContextTokens))"
                }
            Text(tokenText)
                .font(.system(size: CGFloat(theme.captionSize) - 1, weight: .medium, design: .monospaced))
                .foregroundColor(
                    warningColor ?? (isStreaming ? theme.secondaryText : theme.tertiaryText)
                )
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            if !isCompact {
                Text("tokens", bundle: .module)
                    .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .regular))
                    .foregroundColor(theme.tertiaryText.opacity(0.7))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .pointingHandCursor()
        .onHover { hovering in
            if hovering {
                openContextBreakdown()
            } else {
                scheduleContextDismiss()
            }
        }
        .popover(isPresented: $showContextBreakdown, arrowEdge: .top) {
            ContextBreakdownPopover(
                breakdown: displayContextBreakdown,
                maxTokens: maxContextTokens,
                isStreaming: isStreaming,
                formatTokenCount: formatTokenCount
            )
            // Keep the popover alive while the cursor is over it, so the user
            // can travel from the trigger and click the disclosure headers.
            .onHover { hovering in
                if hovering {
                    contextDismissTask?.cancel()
                } else {
                    scheduleContextDismiss()
                }
            }
        }
    }

    /// Open the context popover after a short hover dwell, cancelling any
    /// pending dismiss so a quick re-entry doesn't flicker it closed.
    private func openContextBreakdown() {
        contextDismissTask?.cancel()
        contextHoverTask?.cancel()
        contextHoverTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            showContextBreakdown = true
        }
    }

    /// Dismiss the context popover after a grace period, giving the cursor
    /// time to cross the gap into the popover window.
    private func scheduleContextDismiss() {
        contextHoverTask?.cancel()
        contextDismissTask?.cancel()
        contextDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            showContextBreakdown = false
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
        guard selectedPickerItem?.source.isImageGeneration == true else { return nil }
        return selectedPickerItem
    }

    private var imageCapabilities: ImageModelCapabilities? {
        selectedImagePickerItem?.imageCapabilities
    }

    private var isImageComposerActive: Bool {
        selectedImagePickerItem != nil
    }

    private var isSelectedModelDeprecated: Bool {
        guard let id = selectedModel else { return false }
        return ModelManager.replacementForDeprecatedModel(id) != nil
    }

    @ViewBuilder
    private var modelSelectorChip: some View {
        if isModelPinned {
            pinnedModelChip
        } else {
            interactiveModelSelectorChip
        }
    }

    /// Non-interactive model label for Mode 2 (remote agent run). The model is
    /// pinned to the remote agent's own model — no chevron, no popover, just the
    /// model name and a lock glyph. Styled to match the resting `SelectorChip`.
    private var pinnedModelChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .font(theme.font(size: CGFloat(theme.captionSize) - 2))
                .foregroundColor(theme.tertiaryText)
            Text(pinnedModelLabel ?? selectedPickerItem?.displayName ?? "Default")
                .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(theme.secondaryBackground.opacity(0.8)))
        .overlay(Capsule().strokeBorder(theme.primaryBorder.opacity(0.12), lineWidth: 1))
        .clipShape(Capsule())
        .localizedHelp(
            "This chat runs on the remote agent's own model — chosen by the agent's owner and not changeable here."
        )
    }

    private var interactiveModelSelectorChip: some View {
        SelectorChip(isActive: showModelPicker) {
            showModelPicker.toggle()
        } content: {
            HStack(spacing: 6) {
                if isSelectedModelDeprecated {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(theme.font(size: CGFloat(theme.captionSize) - 2))
                        .foregroundColor(.orange)
                        .localizedHelp("This model is outdated. Click to switch to a newer version.")
                } else {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                        .localizedHelp("Model ready")
                }

                // Model name with metadata badges
                if let option = selectedPickerItem {
                    HStack(spacing: 4) {
                        Text(option.displayName)
                            .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                            .foregroundColor(isSelectedModelDeprecated ? .orange : theme.secondaryText)
                            .lineLimit(1)

                        // Show VLM indicator
                        if option.isVLM {
                            Image(systemName: "eye")
                                .font(theme.font(size: CGFloat(theme.captionSize) - 3))
                                .foregroundColor(theme.accentColor)
                        }

                        if !isCompact, let params = option.parameterCount {
                            Text(params)
                                .font(theme.font(size: CGFloat(theme.captionSize) - 3, weight: .medium))
                                .foregroundColor(.blue.opacity(0.8))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(Color.blue.opacity(0.12))
                                )
                        }
                    }
                } else {
                    Text("Select Model", bundle: .module)
                        .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }

                Image(systemName: "chevron.up.chevron.down")
                    .font(theme.font(size: CGFloat(theme.captionSize) - 3, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
            }
        }
        .popover(isPresented: $showModelPicker, arrowEdge: .top) {
            ModelPickerView(
                options: cachedPickerItems,
                selectedModel: $selectedModel,
                agentId: agentId,
                onDismiss: dismissModelPicker
            )
        }
        .onChange(of: showModelPicker) { _, isShowing in
            if isShowing {
                // Snapshot options when popover opens to prevent refresh during streaming
                cachedPickerItems = pickerItems
            }
        }
        .onChange(of: pickerItems) { _, newItems in
            // mirror upstream changes while open so picker triggered refreshes are visible
            if showModelPicker {
                cachedPickerItems = newItems
            }
        }
    }

    // MARK: - Thinking Toggle

    @ViewBuilder
    private var thinkingToggleChip: some View {
        if let model = selectedModel,
            let thinkingOpt = ModelProfileRegistry.profile(for: model)?.thinkingOption
        {
            let isEnabled =
                ModelProfileRegistry.thinkingEnabled(for: model, values: activeModelOptions)
                ?? false

            SelectorChip(isActive: isEnabled) {
                toggleThinking(id: thinkingOpt.id)
            } content: {
                HStack(spacing: 5) {
                    Image(systemName: isEnabled ? "checkmark.square.fill" : "square")
                        .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .semibold))
                        .foregroundColor(isEnabled ? theme.accentColor : theme.tertiaryText)
                        .contentTransition(.symbolEffect(.replace))

                    Text("Thinking", bundle: .module)
                        .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                        .foregroundColor(isEnabled ? theme.secondaryText : theme.tertiaryText)
                }
            }
            .localizedHelp("Toggle model reasoning mode")
        }
    }

    // MARK: - Auto-Speak Toggle

    @ViewBuilder
    private var autoSpeakToggleChip: some View {
        SelectorChip(isActive: autoSpeakAssistant) {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                autoSpeakAssistant.toggle()
            }
        } content: {
            HStack(spacing: 5) {
                Image(systemName: autoSpeakAssistant ? "checkmark.square.fill" : "square")
                    .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .semibold))
                    .foregroundColor(autoSpeakAssistant ? theme.accentColor : theme.tertiaryText)
                    .contentTransition(.symbolEffect(.replace))

                Text("Auto-speak", bundle: .module)
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                    .foregroundColor(autoSpeakAssistant ? theme.secondaryText : theme.tertiaryText)
            }
        }
        .localizedHelp("Auto-speak every reply in this chat")
    }

    private func toggleThinking(id: String) {
        let thinkingOpt = selectedModel.flatMap { ModelProfileRegistry.profile(for: $0)?.thinkingOption }
        let currentEnabled =
            selectedModel.flatMap {
                ModelProfileRegistry.thinkingEnabled(for: $0, values: activeModelOptions)
            } ?? false
        let newEnabled = !currentEnabled
        let newVal = thinkingOpt?.inverted == true ? !newEnabled : newEnabled

        withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
            activeModelOptions[id] = .bool(newVal)
        }

        if let model = selectedModel {
            ModelOptionsStore.shared.saveOptions(activeModelOptions, for: model)
        }
    }

    // MARK: - Model Options Chip

    private var modelOptionsSummary: String {
        guard let model = selectedModel,
            ModelProfileRegistry.profile(for: model) != nil
        else { return "" }
        let nonDefault = activeProfileOptions.compactMap { option -> String? in
            guard let current = activeModelOptions[option.id] else { return nil }
            if case .segmented(let segments) = option.kind {
                return segments.first(where: { $0.id == current.stringValue })?.label
            }
            if case .bool(let v) = current { return v ? option.label : nil }
            return nil
        }
        if nonDefault.isEmpty { return "Default" }
        return nonDefault.joined(separator: ", ")
    }

    private var modelOptionsSelectorChip: some View {
        SelectorChip(isActive: showModelOptionsPicker) {
            showModelOptionsPicker.toggle()
        } content: {
            HStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3")
                    .font(theme.font(size: CGFloat(theme.captionSize) - 2, weight: .medium))
                    .foregroundColor(theme.tertiaryText)

                Text(modelOptionsSummary)
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)

                Image(systemName: "chevron.up.chevron.down")
                    .font(theme.font(size: CGFloat(theme.captionSize) - 3, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
            }
        }
        .popover(isPresented: $showModelOptionsPicker, arrowEdge: .top) {
            ModelOptionsSelectorView(
                options: activeProfileOptions,
                values: modelOptionsBinding,
                profileName: selectedModel.flatMap { ModelProfileRegistry.profile(for: $0)?.displayName } ?? "",
                thinkingOptionId: selectedModel.flatMap { ModelProfileRegistry.profile(for: $0)?.thinkingOption?.id }
            )
        }
    }

    private var modelOptionsBinding: Binding<[String: ModelOptionValue]> {
        Binding(
            get: { activeModelOptions },
            set: { newValues in
                // Defer the write off the popover's synchronous update. The
                // selector popover is anchored to a chip whose label reads
                // `activeModelOptions` (`modelOptionsSummary`); mutating it
                // inline resizes/replaces that anchor while the popover is
                // presenting, which makes NSPopover dereference a freed
                // positioning view (EXC_BAD_ACCESS). Hopping to the next
                // runloop tick lets the current update finish first.
                DispatchQueue.main.async {
                    activeModelOptions = newValues
                    if let model = selectedModel {
                        ModelOptionsStore.shared.saveOptions(newValues, for: model)
                    }
                }
            }
        )
    }

    // MARK: - Sandbox Toggle Chip

    private var effectiveAgentId: UUID {
        agentId ?? Agent.defaultId
    }

    /// The built-in Default ("Osaurus") agent is a configuration-only
    /// surface: it configures Osaurus and never uses the sandbox or a
    /// working folder, so we hide those chips and show a quiet
    /// "Configuration" indicator instead.
    private var isDefaultConfigAgent: Bool {
        effectiveAgentId == Agent.defaultId
    }

    /// Default agent runs Osaurus configuration, which needs the configure
    /// tool schema. The same resolver the composer uses to strip tools
    /// (`.tiny` window) decides whether configuration can run at all — so
    /// when the selected model's window is too small (e.g. Foundation at
    /// 4K), configuration genuinely can't run and the send is blocked.
    private var configContextTooSmall: Bool {
        guard isDefaultConfigAgent, let model = selectedModel else { return false }
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

    /// True during the cold-path runtime fetch (kernel/initfs download + image
    /// pull/unpack); warm boots skip these steps.
    private var isSandboxDownloadingRuntime: Bool {
        guard isSandboxLoading, let step = sandboxState.journey?.currentStepID else { return false }
        switch step {
        case .downloadKernel, .downloadInitFS, .createContainer:
            return true
        default:
            return false
        }
    }

    private var sandboxChipLabel: LocalizedStringKey {
        isSandboxDownloadingRuntime ? "Downloading runtime…" : "Sandbox"
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

    /// True when the sandbox is on but outbound network is turned off for
    /// this agent. Egress is the per-agent `sandboxNetworkEnabled` toggle,
    /// reconciled onto the VM at boot — so this reflects what the sandbox
    /// will actually permit. Surfaced on the chip so a network-less sandbox
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

    /// Primary tap on the sandbox chip. While the sandbox is starting
    /// up — or has failed — we route the click into the Settings →
    /// Sandbox tab so the user can see the real-time provisioning
    /// journey (step list, byte progress, ETA, retry button) instead
    /// of staring at an opaque pulsing pill. Toggling on/off only
    /// makes sense once the sandbox is in a settled state.
    private func handleSandboxChipTap() {
        if isSandboxLoading || isSandboxFailed {
            AppDelegate.shared?.showManagementWindow(initialTab: .sandbox)
            return
        }
        toggleSandbox()
    }

    private func toggleSandbox() {
        let currentConfig = agentManager.effectiveAutonomousExec(for: effectiveAgentId)
        var newConfig = currentConfig ?? .default
        newConfig.enabled.toggle()
        let agentId = effectiveAgentId
        let manager = agentManager
        Task {
            // Sandbox and folder backends now compose: enabling sandbox
            // while a folder is selected yields combined mode (read-only
            // host workspace + sandbox exec), so we keep the folder
            // instead of clearing it. On a provision failure we roll the
            // sandbox flag back below.
            do {
                try await manager.updateAutonomousExec(newConfig, for: agentId)
            } catch {
                // Don't silently swallow provision failures — log loudly and
                // roll the persisted toggle back so the chip flips back to
                // its previous state. The failure reason still flows to the
                // model via SandboxToolRegistrar's unavailability notice.
                debugLog(
                    "[Sandbox] Toggle failed for agent \(agentId): \(error.localizedDescription)"
                )
                var rollback = newConfig
                rollback.enabled.toggle()
                try? await manager.updateAutonomousExec(rollback, for: agentId)
            }
        }
    }

    /// Open the system folder picker. Sandbox and folder now compose
    /// (combined mode), so selecting a folder no longer disables the
    /// sandbox — picking a folder while sandbox is on yields a read-only
    /// host workspace alongside sandbox exec.
    private func selectFolder() {
        Task {
            _ = await folderContextService.selectFolder()
        }
    }

    /// True when sandbox is on AND a folder is selected — combined mode,
    /// where the host workspace is read-only and exec runs in the VM.
    private var isCombinedMode: Bool {
        isSandboxEnabled && folderContextService.hasActiveFolder
    }

    /// Folder chip tooltip. In combined mode it spells out the read-only
    /// contract so users don't expect in-place edits.
    private func folderChipHelp(hasFolder: Bool) -> Text {
        if hasFolder && isSandboxEnabled {
            return Text(
                localized: "Working folder is read-only in sandbox mode — code runs in the sandbox"
            )
        }
        return hasFolder
            ? Text(localized: "Change working folder")
            : Text(localized: "Select a working folder")
    }

    private var sandboxHelpText: String {
        let base: String
        if let failure = sandboxFailure, isSandboxEnabled {
            return "Sandbox unavailable: \(failure.message)\nClick to open Sandbox settings."
        } else if isSandboxLoading {
            // Name the live phase (e.g. "Downloading initfs…") when available.
            if let phase = sandboxState.provisioningPhase, !phase.isEmpty {
                return "\(phase) — click to view progress."
            }
            return "Sandbox is starting up — click to view progress."
        } else if isCombinedMode {
            base =
                "Combined mode: the selected folder is read-only and all code runs in the sandbox. Click to disable."
        } else if isSandboxEnabled && isSandboxRunning {
            base = "Sandbox is active — click to disable. Right-click for settings."
        } else if isSandboxEnabled {
            base = "Sandbox enabled — container not running"
        } else {
            base = "Enable Sandbox for autonomous code execution"
        }
        // Spell out the egress restriction so the user understands the
        // wifi.slash badge — and why the model can't fetch URLs. Takes
        // effect on the next sandbox start.
        if isSandboxNetworkDisabled {
            return base
                + "\nOutbound network is off — enable it in Sandbox settings (applies on next sandbox start)."
        }
        return base
    }

    /// Foreground tint for the chip's icon + dot. Failure beats running so a
    /// briefly-flapping container that came up but failed to provision still
    /// reads as red.
    private var sandboxChipAccent: Color {
        if isSandboxFailed { return .red }
        if isSandboxLoading { return .orange }
        if isSandboxEnabled && isSandboxRunning { return .green }
        return theme.tertiaryText
    }

    private var sandboxToggleChip: some View {
        Button(action: handleSandboxChipTap) {
            HStack(spacing: 5) {
                if isSandboxFailed {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.red)
                } else if isSandboxLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.6)
                        .frame(width: 8, height: 8)
                        .tint(Color.orange)
                } else if isSandboxEnabled && isSandboxRunning {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                }

                Image(systemName: isSandboxEnabled ? "shippingbox.fill" : "shippingbox")
                    .font(.system(size: CGFloat(theme.captionSize) - 2, weight: .medium))
                    .foregroundColor(sandboxChipAccent)

                Text(sandboxChipLabel, bundle: .module)
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                    .foregroundColor(
                        isSandboxFailed
                            ? .red
                            : (isSandboxEnabled
                                ? (isSandboxRunning ? theme.primaryText : theme.secondaryText)
                                : theme.tertiaryText)
                    )
                    .lineLimit(1)
                    .opacity(isSandboxLoading ? sandboxPulseAmount : 1.0)

                // Inline cold-path download/unpack progress.
                if let pct = sandboxProgressPercent {
                    Text(verbatim: "\(pct)%")
                        .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .monospacedDigit()
                }

                // Network-off badge: only meaningful once the sandbox is
                // settled, so suppress it while loading or failed (those
                // states own the leading indicator + accent color).
                if isSandboxNetworkDisabled && !isSandboxLoading && !isSandboxFailed {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: CGFloat(theme.captionSize) - 3, weight: .semibold))
                        .foregroundColor(.orange)
                        .accessibilityLabel(Text("Outbound network disabled", bundle: .module))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(sandboxChipBackground)
            .clipShape(Capsule())
            .overlay(sandboxChipBorder)
            .shadow(
                color: isSandboxFailed
                    ? Color.red.opacity(0.15)
                    : (isSandboxEnabled && isSandboxRunning
                        ? Color.green.opacity(0.12)
                        : (isSandboxHovered ? theme.accentColor.opacity(0.1) : .clear)),
                radius: 4,
                x: 0,
                y: 1
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        // Intentionally NOT `.disabled(isSandboxLoading)` — the chip
        // stays tappable during provisioning so the user can click
        // through to the Sandbox settings tab and watch the journey
        // unfold. Toggling on/off is intercepted by
        // `handleSandboxChipTap` in that state.
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isSandboxHovered = hovering
            }
        }
        .help(sandboxHelpText)
        .contextMenu {
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
        .task(id: isSandboxLoading) {
            sandboxPulseTask?.cancel()
            guard isSandboxLoading else {
                sandboxPulseAmount = 1.0
                return
            }
            sandboxPulseTask = Task {
                while !Task.isCancelled {
                    withAnimation(.easeInOut(duration: 0.8)) {
                        sandboxPulseAmount = 0.4
                    }
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard !Task.isCancelled else { break }
                    withAnimation(.easeInOut(duration: 0.8)) {
                        sandboxPulseAmount = 1.0
                    }
                    try? await Task.sleep(nanoseconds: 800_000_000)
                }
            }
        }
    }

    @ViewBuilder
    private var sandboxChipBackground: some View {
        ZStack {
            Capsule()
                .fill(theme.secondaryBackground.opacity(isSandboxHovered || isSandboxEnabled ? 0.95 : 0.8))

            if isSandboxFailed {
                Capsule()
                    .fill(Color.red.opacity(isSandboxHovered ? 0.16 : 0.10))
            } else if isSandboxEnabled && isSandboxRunning {
                Capsule()
                    .fill(Color.green.opacity(isSandboxHovered ? 0.14 : 0.08))
            } else if isSandboxLoading {
                Capsule()
                    .fill(Color.orange.opacity(0.06))
            } else if isSandboxHovered {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [theme.accentColor.opacity(0.06), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
    }

    @ViewBuilder
    private var sandboxChipBorder: some View {
        if isSandboxFailed {
            Capsule()
                .strokeBorder(Color.red.opacity(isSandboxHovered ? 0.45 : 0.30), lineWidth: 1)
        } else if isSandboxEnabled && isSandboxRunning {
            Capsule()
                .strokeBorder(Color.green.opacity(isSandboxHovered ? 0.4 : 0.25), lineWidth: 1)
        } else if isSandboxLoading {
            Capsule()
                .strokeBorder(Color.orange.opacity(isSandboxHovered ? 0.35 : 0.2), lineWidth: 1)
        } else {
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            theme.glassEdgeLight.opacity(isSandboxHovered ? 0.25 : 0.15),
                            theme.primaryBorder.opacity(isSandboxHovered ? 0.2 : 0.12),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
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

    private var clipboardChipLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: clipboardChipIcon)
                .font(.system(size: CGFloat(theme.captionSize) - 2, weight: .medium))
                .foregroundColor(theme.accentColor)

            // Lead with the action word so the chip reads as "Paste" like its
            // row-mates ("Sandbox", "Folder"); the source app trails as a quiet
            // suffix so the "from which app" signal isn't lost.
            Text("Paste", bundle: .module)
                .font(theme.font(size: CGFloat(theme.captionSize), weight: .bold))
                .foregroundColor(theme.accentColor)
                .lineLimit(1)

            if let source = clipboardService.lastSourceApp {
                Text(source)
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Image(systemName: "chevron.right")
                .font(theme.font(size: CGFloat(theme.captionSize) - 4, weight: .bold))
                .foregroundColor(theme.tertiaryText.opacity(0.7))
                .padding(.leading, 2)
        }
    }

    private var clipboardToggleChip: some View {
        Button(action: attachClipboardSnippet) {
            clipboardChipLabel
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(theme.secondaryBackground.opacity(isClipboardHovered ? 0.95 : 0.8))
                )
                .clipShape(Capsule())
                .overlay(
                    // main static border
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    theme.glassEdgeLight.opacity(isClipboardHovered ? 0.25 : 0.15),
                                    theme.accentColor.opacity(isClipboardHovered ? 0.6 : 0.15),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .overlay(
                    // animated clockwise border sweep using custom shape to fix vertical frame issue
                    ClipboardSweepShape()
                        .trim(from: 0, to: clipboardPulseAmount)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    theme.glassEdgeLight.opacity(0.8),
                                    theme.accentColor,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                        )
                        .opacity(clipboardPulseOpacity)
                )
                .overlay(
                    // accompanying glow that follows the sweep
                    ClipboardSweepShape()
                        .trim(from: 0, to: clipboardPulseAmount)
                        .stroke(theme.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .opacity(clipboardPulseOpacity * 0.4)
                        .blur(radius: 3)
                )
                .shadow(
                    color: theme.accentColor.opacity(isClipboardHovered ? 0.35 : (0.05 + clipboardPulseOpacity * 0.2)),
                    radius: isClipboardHovered ? 6 : (4 + clipboardPulseOpacity * 4),
                    x: 0,
                    y: 1
                )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isClipboardHovered = hovering
            }
        }
        .help(Text(localized: "Attach snippet from \(clipboardService.lastSourceApp ?? "clipboard")"))
        .contextMenu {
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
                        if text.utf8.count >= Self.pastedContentThreshold {
                            withAnimation(theme.springAnimation()) {
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
        .onAppear {
            if clipboardService.hasNewContent {
                triggerPulse()
            }
        }
        .onChange(of: clipboardService.hasNewContent) { _, newValue in
            if newValue {
                triggerPulse()
            }
        }
    }

    private func triggerPulse() {
        // reset state immediately and hide animation layers
        clipboardPulseAmount = 0
        clipboardPulseOpacity = 0

        // small delay to ensure the window transition is complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            withAnimation(.easeIn(duration: 0.1)) {
                clipboardPulseOpacity = 1.0
            }

            // animate the stroke clockwise around the capsule
            withAnimation(.easeInOut(duration: 0.8)) {
                clipboardPulseAmount = 1.0
            }

            // fade out after completion
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                withAnimation(.easeOut(duration: 0.4)) {
                    clipboardPulseOpacity = 0
                }
            }
        }
    }

    private func attachClipboardSnippet() {
        guard let content = clipboardService.currentContent else { return }

        switch content {
        case .text(let text):
            if text.utf8.count >= Self.pastedContentThreshold {
                // Large paste → convert to a "pasted content" attachment.
                // Lets the user view / remove the snippet without polluting
                // the input field with hundreds of lines of text.
                withAnimation(theme.springAnimation()) {
                    pendingAttachments.append(.pastedContent(text))
                    clipboardService.markAsRead()
                    isFocused = true
                }
            } else {
                // Inject directly into the text input area for better UX (editing)
                withAnimation(theme.springAnimation()) {
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
            withAnimation(theme.springAnimation()) {
                pendingAttachments.append(.image(data))
                clipboardService.markAsRead()
            }

        case .file(let url):
            if DocumentParser.isImageFile(url: url) {
                let animation = theme.springAnimation()
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
                let animation = theme.springAnimation()
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

    // MARK: - Configuration Indicator Chip

    /// Quiet, non-interactive pill shown for the Default ("Osaurus")
    /// agent in place of the sandbox/folder chips. It signals that this
    /// agent's job is to configure Osaurus — it doesn't execute code in a
    /// sandbox or work against a host folder — so the controls are absent
    /// by design rather than missing.
    private var configurationOnlyChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "gearshape.fill")
                .font(theme.font(size: CGFloat(theme.captionSize) - 2))
                .foregroundColor(theme.accentColor)

            Text("Configuration", bundle: .module)
                .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(theme.secondaryBackground.opacity(0.6))
        )
        .overlay(
            Capsule()
                .strokeBorder(theme.primaryBorder.opacity(0.4), lineWidth: 0.5)
        )
        .help(
            Text(
                "The Osaurus agent helps you configure Osaurus. It doesn't use the sandbox or a working folder.",
                bundle: .module
            )
        )
        .accessibilityLabel(Text("Configuration assistant", bundle: .module))
    }

    /// Accessibility permission, the gate for a useful screen-context capture.
    private var isAccessibilityGranted: Bool {
        permissionService.permissionStates[.accessibility] ?? false
    }

    /// The read-only screen-context indicator is shown only on the welcome/empty
    /// screen, while the opt-in is on, Accessibility is granted, and we know
    /// which app the user was just in (the snapshot freezes on the first send,
    /// so "currently focused" only reads true pre-send).
    private var showScreenContextIndicator: Bool {
        // Mode 2 never injects local screen context (the remote agent runs its
        // own context server-side), so don't promise a snapshot we won't send.
        !isRemoteAgentRun
            && agentManager.effectiveCapabilities(for: effectiveAgentId).screenContextEnabled
            && isEmptyChat
            && isAccessibilityGranted
            && frontmostApp.lastNonSelfAppName != nil
    }

    /// Read-only indicator of the app the frozen screen-context snapshot will be
    /// about (the app focused just before Osaurus). Rendered as a quiet,
    /// right-aligned status line above the context-token count — just a
    /// viewfinder glyph plus the app name, in muted text — so it pairs with the
    /// budget readout rather than reading as a control.
    private var screenContextIndicator: some View {
        let app = frontmostApp.lastNonSelfAppName ?? "the focused app"
        return HStack(spacing: 5) {
            Image(systemName: "viewfinder")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                .foregroundColor(theme.accentColor.opacity(0.85))

            Text(app)
                .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                .foregroundColor(theme.tertiaryText)
                .lineLimit(1)
        }
        .help(
            Text(
                "A read-only snapshot of \(app) is shared with this chat when you send. Manage it in Computer Use settings.",
                bundle: .module
            )
        )
        .accessibilityLabel(Text("Screen context from \(app)", bundle: .module))
    }

    /// Floating wrapper for `configContextErrorBanner`: keeps the toast out of
    /// the layout flow (so it never shifts the card) and lifts it fully above
    /// the card's top edge with a small gap via the `.top` alignment guide.
    @ViewBuilder
    private var configContextErrorOverlay: some View {
        if configContextTooSmall {
            configContextErrorBanner
                .alignmentGuide(.top) { dimensions in dimensions.height + 10 }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
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
        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: CGFloat(theme.captionSize)))
                .foregroundColor(.orange)

            Text(
                "\(modelName)\(ctxBlurb) is too small to configure Osaurus.",
                bundle: .module
            )
            .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
            .foregroundColor(theme.primaryText)
            .fixedSize(horizontal: false, vertical: true)

            Button {
                showModelPicker = true
            } label: {
                Text("Choose model", bundle: .module)
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .semibold))
                    .foregroundColor(theme.accentColor)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.orange.opacity(0.12))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 3)
        .frame(maxWidth: 560)
    }

    // MARK: - Folder Context Chip

    private var folderContextChip: some View {
        let hasFolder = folderContextService.hasActiveFolder

        return HStack(spacing: 4) {
            Button(action: selectFolder) {
                folderChipContent(hasFolder: hasFolder, canEdit: true)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(folderChipHelp(hasFolder: hasFolder))
            .contextMenu {
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
                        Task { await folderContextService.refreshContext() }
                    } label: {
                        Label {
                            Text("Refresh Context", bundle: .module)
                        } icon: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        folderContextService.clearFolder()
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
                    folderContextService.clearFolder()
                } label: {
                    Image(systemName: "xmark")
                        .font(theme.font(size: CGFloat(theme.captionSize) - 4, weight: .bold))
                        .foregroundColor(theme.tertiaryText)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(theme.secondaryBackground.opacity(0.8)))
                        .overlay(Circle().strokeBorder(theme.primaryBorder.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .localizedHelp("Clear folder selection")
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: hasFolder)
    }

    @ViewBuilder
    private func folderChipContent(hasFolder: Bool, canEdit: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: hasFolder ? "folder.fill" : "folder.badge.plus")
                .font(theme.font(size: CGFloat(theme.captionSize) - 2))
                .foregroundColor(hasFolder ? theme.accentColor : theme.tertiaryText)
                .opacity(canEdit ? 1.0 : 0.7)

            if let context = folderContextService.currentContext {
                Text(context.rootPath.lastPathComponent)
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                    .foregroundColor(canEdit ? theme.secondaryText : theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if canEdit {
                Text("Folder", bundle: .module)
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                    .foregroundColor(theme.tertiaryText)
            }

            if canEdit {
                Image(systemName: "chevron.up.chevron.down")
                    .font(theme.font(size: CGFloat(theme.captionSize) - 3, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(theme.secondaryBackground.opacity(canEdit ? 0.6 : 0.4))
        )
        .overlay(
            Capsule()
                .strokeBorder(theme.primaryBorder.opacity(canEdit ? 0.4 : 0.2), lineWidth: 0.5)
        )
    }

    private var keyboardHint: some View {
        HStack(spacing: 4) {
            Text("⏎")
                .font(theme.font(size: CGFloat(theme.captionSize) - 2, weight: .medium))
            Text("to send", bundle: .module)
                .font(theme.font(size: CGFloat(theme.captionSize) - 1))
        }
        .foregroundColor(theme.tertiaryText.opacity(0.7))
    }

    private func dismissModelPicker() {
        showModelPicker = false
    }

    // MARK: - Input Card

    private var inputCard: some View {
        let hasChipRow = !pendingAttachments.isEmpty || pendingSkillId != nil || queuedSend != nil
        return VStack(alignment: .leading, spacing: 0) {
            if hasChipRow {
                HStack(alignment: .center, spacing: 6) {
                    queuedSendChipView
                    pendingSkillChipView
                    if !pendingAttachments.isEmpty {
                        inlinePendingAttachmentsPreview
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
            }

            textInputArea
                .padding(.horizontal, 12)
                .padding(.top, hasChipRow ? 6 : 10)
                .padding(.bottom, 6)

            buttonBar
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(effectiveBorderStyle, lineWidth: isDragOver ? 2 : (isFocused ? 1.5 : 0.5))
        )
        /*
        .shadow(
            color: shadowColor,
            radius: isFocused ? 12 : 6,
            x: 0,
            y: isFocused ? 4 : 2
        )
        */
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .animation(.easeOut(duration: 0.1), value: isDragOver)
    }

    // MARK: - Voice Input Button

    private var voiceInputButton: some View {
        // Only render the disabled "loading…" state when mic access has
        // actually been granted. For `.notDetermined`/`.denied` the model
        // can't be used yet, and a background autoload (e.g.
        // `SpeechService.autoLoadIfNeeded` at launch) would otherwise
        // freeze the button and swallow the tap that needs to surface
        // either the system mic prompt or the denied alert.
        let micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
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
                    ProgressView()
                        .scaleEffect(0.5)
                        .allowsHitTesting(false)
                )
                .disabled(true)
                .opacity(0.5)
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

    private func appendAttachment(_ attachment: Attachment) {
        withAnimation(theme.springAnimation()) {
            pendingAttachments.append(attachment)
        }
    }

    private func parseAndAttach(url: URL) {
        let filename = url.lastPathComponent
        let animation = theme.springAnimation()
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
        ModelMediaCapabilities.composerDescriptor(
            modelId: selectedModel,
            fallbackSupportsImages: supportsImages
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
        let panel = NSOpenPanel()
        panel.allowedContentTypes = pickerAllowedTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message =
            mediaCapabilities.anyMedia
            ? "Select files to attach (\(mediaCapabilities.summary) supported)"
            : "Select files to attach"

        Task { @MainActor in
            guard await panel.beginModal() == .OK else { return }
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
            Task { @MainActor in
                // The image decode and PNG re-encode block for seconds on a
                // large file, so they run off the main actor and only the
                // finished bytes are attached here.
                let pngData = await Task.detached(priority: .userInitiated) {
                    () -> Data? in
                    guard let data = try? Data(contentsOf: url), data.count <= sizeLimit,
                        let nsImage = NSImage(data: data)
                    else { return nil }
                    return nsImage.pngData()
                }.value
                if let pngData {
                    appendAttachment(.image(pngData))
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

    private static let audioExtensions: Set<String> = [
        "wav", "mp3", "m4a", "flac", "ogg", "opus", "aac", "wma",
    ]

    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "qt", "webm", "mkv", "avi",
    ]

    private var audioExtensions: Set<String> { Self.audioExtensions }
    private var videoExtensions: Set<String> { Self.videoExtensions }

    /// Attach audio bytes from a file URL. Reads inline; spillover to
    /// the encrypted blob store is handled later in the chat-history
    /// persistence layer (`AttachmentBlobStore.spillIfNeeded`) when
    /// the turn is committed. Format string is the lowercased file
    /// extension and flows directly into
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
                    guard let data = data, error == nil, data.count <= maxImageSize else { return }
                    // Decode and re-encode on the provider's background queue;
                    // only the finished bytes hop to the main thread.
                    guard let nsImage = NSImage(data: data),
                        let pngData = nsImage.pngData()
                    else { return }
                    DispatchQueue.main.async {
                        appendAttachment(.image(pngData))
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
    private var placeholderText: String {
        if selectedImagePickerItem != nil {
            return L("Describe the image...")
        }
        return L("Message or attach files...")
    }

    // MARK: - Image Composer Controls

    private var seedText: Binding<String> {
        Binding(
            get: { imageComposerSettings.seed },
            set: { imageComposerSettings.seed = $0.filter(\.isNumber) }
        )
    }

    /// Inline image config chips that ride in the selector row beside the model
    /// chip (the model owns these settings, and the row's normal chips are inert
    /// for image models).
    private var imageComposerChips: some View {
        HStack(spacing: 6) {
            sizeSelector
            stepsChip
            cfgChip
            seedChip
            if imageCapabilities?.imageEdit == true {
                strengthChip
            }
        }
    }

    /// Shared pill backing so every composer control reads as one family of
    /// chips instead of clashing system `.roundedBorder` / `.segmented` chrome.
    private var chipBackground: some View {
        Capsule()
            .fill(theme.secondaryBackground.opacity(0.6))
            .overlay(Capsule().strokeBorder(theme.primaryBorder.opacity(0.4), lineWidth: 0.5))
    }

    /// A selectable output resolution with a one-line explanation of its
    /// speed / detail trade-off (bare pixel numbers don't tell the user what
    /// they're choosing).
    private struct ImageSizeOption: Identifiable {
        let dimension: Int
        let title: String
        let detail: String
        var id: Int { dimension }
    }

    private var imageSizeOptions: [ImageSizeOption] {
        [
            ImageSizeOption(
                dimension: 512,
                title: L("512 × 512"),
                detail: L("Fast drafts. Lowest detail, quickest to render.")
            ),
            ImageSizeOption(
                dimension: 768,
                title: L("768 × 768"),
                detail: L("Balanced. Good detail at a moderate speed.")
            ),
            ImageSizeOption(
                dimension: 1024,
                title: L("1024 × 1024"),
                detail: L("Sharpest. The size most models are trained for, but slowest.")
            ),
        ]
    }

    private var selectedSizeLabel: String {
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
            HStack(spacing: 5) {
                Image(systemName: "aspectratio")
                    .font(theme.font(size: CGFloat(theme.captionSize) - 2, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                Text(selectedSizeLabel)
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .monospacedDigit()
                Image(systemName: "chevron.up.chevron.down")
                    .font(theme.font(size: CGFloat(theme.captionSize) - 3, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
            }
        }
        .popover(isPresented: $showImageSizePicker, arrowEdge: .top) {
            imageSizePopover
        }
        .localizedHelp("Output image size")
    }

    private var imageSizePopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Image size", bundle: .module)
                .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 4)

            ForEach(imageSizeOptions) { option in
                let isSelected =
                    imageComposerSettings.width == option.dimension
                    && imageComposerSettings.height == option.dimension
                Button {
                    imageComposerSettings.width = option.dimension
                    imageComposerSettings.height = option.dimension
                    showImageSizePicker = false
                } label: {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                            .foregroundColor(isSelected ? theme.accentColor : theme.tertiaryText)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title)
                                .font(
                                    theme.font(
                                        size: CGFloat(theme.captionSize),
                                        weight: .semibold
                                    )
                                )
                                .foregroundColor(theme.primaryText)
                            Text(option.detail)
                                .font(theme.font(size: CGFloat(theme.captionSize) - 2))
                                .foregroundColor(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? theme.accentColor.opacity(0.08) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .padding(.horizontal, 6)
            }
        }
        .padding(.bottom, 8)
        .frame(width: 252)
        .popoverCard()
    }

    private func stepperButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(theme.font(size: CGFloat(theme.captionSize) - 2, weight: .bold))
                .foregroundColor(theme.secondaryText)
                .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private var stepsChip: some View {
        HStack(spacing: 6) {
            stepperButton("minus") {
                imageComposerSettings.steps = max(1, imageComposerSettings.steps - 1)
            }
            HStack(spacing: 3) {
                Text("\(imageComposerSettings.steps)")
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .monospacedDigit()
                Text("steps", bundle: .module)
                    .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
            }
            stepperButton("plus") {
                imageComposerSettings.steps = min(50, imageComposerSettings.steps + 1)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(chipBackground)
        .localizedHelp("Denoising steps")
    }

    private var cfgChip: some View {
        HStack(spacing: 5) {
            Text("CFG", bundle: .module)
                .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                .foregroundColor(theme.tertiaryText)
            TextField(
                "",
                value: $imageComposerSettings.guidance,
                format: .number.precision(.fractionLength(1))
            )
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .frame(width: 28)
            .font(theme.font(size: CGFloat(theme.captionSize), weight: .semibold))
            .foregroundColor(theme.primaryText)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(chipBackground)
        .localizedHelp("Classifier-free guidance")
    }

    private var seedChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "number")
                .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                .foregroundColor(theme.tertiaryText)
            TextField("Seed", text: seedText)
                .textFieldStyle(.plain)
                .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                .foregroundColor(theme.primaryText)
                // Hug the content so the chip starts compact and grows as the
                // seed is typed, with a small floor so the placeholder fits.
                .fixedSize()
                .frame(minWidth: 34)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(chipBackground)
        .localizedHelp("Optional numeric seed")
    }

    private var strengthChip: some View {
        HStack(spacing: 5) {
            Text("Strength", bundle: .module)
                .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                .foregroundColor(theme.tertiaryText)
            TextField(
                "",
                value: $imageComposerSettings.strength,
                format: .number.precision(.fractionLength(2))
            )
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .frame(width: 32)
            .font(theme.font(size: CGFloat(theme.captionSize), weight: .semibold))
            .foregroundColor(theme.primaryText)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(chipBackground)
        .localizedHelp("How strongly the prompt changes the source image")
    }

    /// Chip-styled button that opens the negative-prompt editor. Shows the
    /// current value (when set) or a call to add one.
    private var negativePromptButton: some View {
        let value = imageComposerSettings.negativePrompt.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let hasValue = !value.isEmpty
        return Button {
            negativePromptDraft = imageComposerSettings.negativePrompt
            showNegativePromptAlert = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: hasValue ? "minus.circle.fill" : "minus.circle")
                    .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                    .foregroundColor(hasValue ? theme.accentColor : theme.tertiaryText)
                Text(hasValue ? value : L("Add a negative prompt"))
                    .font(
                        theme.font(
                            size: CGFloat(theme.captionSize),
                            weight: hasValue ? .medium : .regular
                        )
                    )
                    .foregroundColor(hasValue ? theme.secondaryText : theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(chipBackground)
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
            .font(theme.font(size: CGFloat(theme.bodySize)))
            .foregroundColor(theme.primaryText)
            .focused($focused)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.secondaryBackground.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        focused ? theme.accentColor.opacity(0.8) : theme.primaryBorder.opacity(0.6),
                        lineWidth: focused ? 1.5 : 1
                    )
            )
            .animation(.easeOut(duration: 0.15), value: focused)
            .onAppear {
                // Defer so the alert's present animation settles before the
                // field grabs focus (otherwise the focus can be dropped).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    focused = true
                }
            }
        }
    }

    private var textInputArea: some View {
        EditableTextView(
            text: $localText,
            fontSize: inputFontSize,
            textColor: theme.primaryText,
            cursorColor: theme.cursorColor,
            isFocused: $isFocused,
            isComposing: $isComposing,
            maxHeight: maxHeight,
            focusController: textViewFocusController,
            onCommit: {
                if showSlashPopup {
                    let cmds = slashFilteredCommands
                    if slashSelectedIndex < cmds.count {
                        applySlashCommand(cmds[slashSelectedIndex])
                    }
                } else {
                    syncAndSend()
                }
            },
            onShiftCommit: nil,
            onArrowUp: showSlashPopup
                ? {
                    slashSelectedIndex = max(0, slashSelectedIndex - 1)
                    return true
                } : nil,
            onArrowDown: showSlashPopup
                ? {
                    let maxIndex = slashFilteredCommands.count - 1
                    slashSelectedIndex = min(maxIndex, slashSelectedIndex + 1)
                    return true
                } : nil,
            onEscape: showSlashPopup
                ? {
                    // Dismiss popup by clearing the slash prefix
                    localText = ""
                    text = ""
                    return true
                } : nil,
            onPasteText: { pasted in
                guard pasted.utf8.count >= Self.pastedContentThreshold else { return false }
                withAnimation(theme.springAnimation()) {
                    pendingAttachments.append(.pastedContent(pasted))
                }
                return true
            }
        )
        .frame(maxHeight: maxHeight)
        .overlay(alignment: .topLeading) {
            // Placeholder - uses theme body size
            if showPlaceholder {
                Text(placeholderText)
                    .font(theme.font(size: inputFontSize, weight: .regular))
                    .foregroundColor(theme.placeholderText)
                    .padding(.leading, 6)
                    .padding(.top, 2)
                    .allowsHitTesting(false)
            }
        }
        .background(
            PasteboardImageMonitor(
                supportsImages: mediaCapabilities.supportsImage,
                onImagePaste: { imageData in
                    withAnimation(theme.springAnimation()) {
                        pendingAttachments.append(.image(imageData))
                    }
                }
            )
        )
    }

    // MARK: - Button Bar

    private var buttonBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                mediaButton
                slashCommandButton
                if isVoiceConfigured {
                    voiceInputButton
                        .disabled(isStreaming)
                        .opacity(isStreaming ? 0.4 : 1.0)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                keyboardHint
                if isStreaming {
                    // While the Privacy Filter review sheet is on screen,
                    // suppress Stop — the sheet owns the cancel UX. The
                    // streaming Task is suspended inside
                    // `PrivacyReviewService.review`'s continuation; the
                    // sheet's Cancel button resolves it cleanly. Outside
                    // that sheet (including model load / prefill before the
                    // first token), Stop stays available so the user can
                    // cancel a long-running load.
                    if !isPrivacyReviewSheetVisible {
                        stopButton
                    }
                    if queuedSend != nil {
                        sendNowButton
                    } else {
                        // No queue-during-review: the user hasn't even
                        // committed the in-flight message yet.
                        if !isPrivacyReviewSheetVisible {
                            sendQueueButton
                        }
                    }
                } else {
                    sendButton
                }
            }
        }
    }

    // MARK: - Action Buttons

    private var mediaButton: some View {
        InputActionButton(
            icon: "paperclip",
            help: "Attach file (image, PDF, text, etc.)",
            action: pickAttachment
        )
    }

    private var slashCommandButton: some View {
        SlashCommandTriggerButton(isActive: showSlashPopup) {
            guard !showSlashPopup else { return }
            if localText.isEmpty {
                localText = "/"
            } else if localText.last?.isWhitespace == true {
                localText += "/"
            } else {
                localText += " /"
            }
            isFocused = true
        }
    }

    private var stopButton: some View {
        StopButton(action: onStop)
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
        SendNowButton {
            // Stop -> send cascade fans out across more runloop turns
            // than syncAndSend, hence the longer lock.
            textViewFocusController.lockFocus(for: 0.4)
            onSendNow?()
        }
    }

    // MARK: - Card Styling

    private var cardBackground: some View {
        ZStack {
            // NSVisualEffectView-backed glass behind everything, only when
            // the prompt card's own glass toggle is on. The fill above is
            // already semi-transparent so the material shows through.
            if theme.glassInputEnabled {
                ThemedGlassSurface(cornerRadius: 20)
            }

            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(theme.primaryBackground.opacity(theme.isDark ? 0.82 : 0.94))

            // subtle accent gradient at top (enhanced when focused)
            LinearGradient(
                colors: [
                    theme.accentColor.opacity(isFocused ? 0.08 : (theme.isDark ? 0.04 : 0.025)),
                    Color.clear,
                ],
                startPoint: .top,
                endPoint: .center
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private var effectiveBorderStyle: AnyShapeStyle {
        if isDragOver {
            return AnyShapeStyle(theme.accentColor)
        }
        return borderGradient
    }

    private var borderGradient: AnyShapeStyle {
        if isFocused {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        theme.accentColor.opacity(0.5),
                        theme.accentColor.opacity(0.2),
                        theme.glassEdgeLight.opacity(0.15),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        } else {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        theme.glassEdgeLight.opacity(theme.isDark ? 0.2 : 0.3),
                        theme.primaryBorder.opacity(0.12),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }

    private var shadowColor: Color {
        isFocused ? theme.accentColor.opacity(0.18) : theme.shadowColor.opacity(0.12)
    }
}

// MARK: - Clipboard Animation Shape

/// A custom capsule shape that starts its path at the top center to allow for clockwise border sweeps
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
        ZStack(alignment: .topTrailing) {
            if let nsImage = cachedImage {
                let thumbSize = AttachmentThumbnailLayout.size(for: nsImage, longAxis: size)
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: thumbSize.width, height: thumbSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(theme.primaryBorder.opacity(0.3), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .modifier(TappableThumbnailModifier(onTap: onTap))
            } else {
                // Square placeholder — aspect is unknown until decode completes.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.secondaryBackground)
                    .frame(width: size, height: size)
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(theme.font(size: 16, weight: .regular))
                    .foregroundColor(.white)
                    .background(
                        Circle()
                            .fill(Color.black.opacity(0.6))
                            .frame(width: 18, height: 18)
                    )
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .offset(x: 4, y: -4)
        }
        .padding(.top, 4)
        .padding(.trailing, 4)
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
    let supportsImages: Bool
    let onImagePaste: (Data) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = PasteMonitorView()
        view.supportsImages = supportsImages
        view.onImagePaste = onImagePaste
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? PasteMonitorView {
            view.supportsImages = supportsImages
            view.onImagePaste = onImagePaste
        }
    }
}

class PasteMonitorView: NSView {
    var supportsImages: Bool = false
    var onImagePaste: ((Data) -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self else { return event }
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
        guard supportsImages else { return false }

        let pasteboard = NSPasteboard.general

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

/// Shared rounded glass card chrome for the composer's hover/selector popovers
/// (Context Budget, router balance, model options) so they read as one family.
/// Defaults match the lightweight hover cards; the model-options panel passes
/// larger values for its heavier look.
private struct PopoverCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 10
    var accentOpacity: (dark: Double, light: Double) = (0.04, 0.03)
    var borderOpacity: Double = 0.12
    var shadowOpacity: Double = 0.2
    var shadowRadius: CGFloat = 16
    var shadowOffsetY: CGFloat = 8

    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    if theme.glassEnabled {
                        shape.fill(.ultraThinMaterial)
                    }
                    shape.fill(theme.primaryBackground.opacity(theme.isDark ? 0.85 : 0.92))
                    LinearGradient(
                        colors: [
                            theme.accentColor.opacity(
                                theme.isDark ? accentOpacity.dark : accentOpacity.light
                            ),
                            .clear,
                        ],
                        startPoint: .top,
                        endPoint: .center
                    )
                    .clipShape(shape)
                }
            }
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            theme.glassEdgeLight.opacity(0.2),
                            theme.primaryBorder.opacity(borderOpacity),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            )
            .shadow(
                color: theme.shadowColor.opacity(shadowOpacity),
                radius: shadowRadius,
                x: 0,
                y: shadowOffsetY
            )
    }
}

private extension View {
    /// Applies the shared composer popover card chrome (glass fill, gradient
    /// border, soft shadow). Tunable for the heavier model-options panel.
    func popoverCard(
        cornerRadius: CGFloat = 10,
        accentOpacity: (dark: Double, light: Double) = (0.04, 0.03),
        borderOpacity: Double = 0.12,
        shadowOpacity: Double = 0.2,
        shadowRadius: CGFloat = 16,
        shadowOffsetY: CGFloat = 8
    ) -> some View {
        modifier(
            PopoverCardModifier(
                cornerRadius: cornerRadius,
                accentOpacity: accentOpacity,
                borderOpacity: borderOpacity,
                shadowOpacity: shadowOpacity,
                shadowRadius: shadowRadius,
                shadowOffsetY: shadowOffsetY
            )
        )
    }
}

// MARK: - Context Breakdown Popover

/// A roll-up of one or more breakdown entries shown as a single legend row.
/// Multi-entry groups (the system prompt's many sections) collapse behind a
/// disclosure so the popover reads as a handful of categories by default and
/// only fans out to per-section detail on demand. Single-entry groups (Tools,
/// Memory, …) render as a plain row.
private struct BudgetGroup: Identifiable {
    let id: String
    let label: String
    let tint: ContextBreakdown.Tint
    let entries: [ContextBreakdown.Entry]

    var tokens: Int { entries.reduce(0) { $0 + $1.tokens } }
    var isExpandable: Bool { entries.count > 1 }
}

/// Reports the natural height of the context-budget popover content so it
/// can size its scroll container to fit (see `resolvedHeight`).
private struct ContextPopoverHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ContextBreakdownPopover: View {
    let breakdown: ContextBreakdown
    let maxTokens: Int?
    let isStreaming: Bool
    let formatTokenCount: (Int) -> String

    @Environment(\.theme) private var theme

    /// Which multi-entry groups are drilled open. Starts empty so the popover
    /// opens in its compact, grouped form.
    @State private var expandedGroups: Set<String> = []

    /// Measured natural height of the popover content, fed back via a
    /// preference to size the scroll container (see `resolvedHeight`).
    @State private var measuredContentHeight: CGFloat = 0

    /// Cap on the popover height; longer breakdowns scroll past this.
    private let maxPopoverHeight: CGFloat = 420

    /// Scroll-container height: nil until measured (use the content's
    /// natural size), then clamped to `maxPopoverHeight`.
    private var resolvedHeight: CGFloat? {
        guard measuredContentHeight > 0 else { return nil }
        return min(measuredContentHeight, maxPopoverHeight)
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
        switch tint {
        case .purple: return theme.isDark ? Color(red: 0.68, green: 0.52, blue: 1.0) : .purple
        case .blue: return theme.isDark ? Color(red: 0.45, green: 0.68, blue: 1.0) : .blue
        case .orange: return theme.isDark ? Color(red: 1.0, green: 0.68, blue: 0.35) : .orange
        case .green: return theme.isDark ? Color(red: 0.45, green: 0.85, blue: 0.55) : .green
        case .gray: return theme.isDark ? Color(red: 0.58, green: 0.62, blue: 0.68) : Color(white: 0.55)
        case .cyan: return theme.isDark ? Color(red: 0.35, green: 0.82, blue: 0.9) : .cyan
        case .teal: return theme.isDark ? Color(red: 0.3, green: 0.75, blue: 0.75) : .teal
        case .indigo: return theme.isDark ? Color(red: 0.55, green: 0.48, blue: 0.95) : .indigo
        case .pink: return theme.isDark ? Color(red: 1.0, green: 0.55, blue: 0.78) : .pink
        }
    }

    // MARK: - Body

    var body: some View {
        // A height-capped ScrollView, not a free-growing column: the popover
        // hugs its content, but a long "System Prompt" drill-down scrolls
        // instead of resizing the NSPopover window — an animated/oversized
        // popover resize crashes AppKit (EXC_BAD_ACCESS).
        ScrollView(.vertical, showsIndicators: false) {
            contentStack
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ContextPopoverHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                )
        }
        .frame(width: 240, height: resolvedHeight)
        .onPreferenceChange(ContextPopoverHeightKey.self) { measuredContentHeight = $0 }
        .popoverCard()
    }

    /// The popover's content column. Extracted so `body` can wrap it in a
    /// height-bounded `ScrollView` (see `resolvedHeight`).
    private var contentStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Context Budget", bundle: .module)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                if isStreaming {
                    Circle()
                        .fill(color(for: .green))
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            barChart
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            if let notice = autoDisableNotice {
                Text(notice)
                    .font(.system(size: 10).italic())
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }

            if !contextGroups.isEmpty {
                divider
                contextGroupList.padding(.horizontal, 12).padding(.vertical, 8)
            }

            if !breakdown.messages.isEmpty {
                divider
                entryGroup(breakdown.messages, highlightOutput: true).padding(.horizontal, 12).padding(.vertical, 8)
            }

            divider
            totalRow.padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    // MARK: - Stacked Bar

    private var barChart: some View {
        let segments = barSegments
        // The bar shows composition: every segment's share of the current
        // total, always filling the track. Share-of-budget would render the
        // whole breakdown as a near-invisible sliver against a huge window;
        // headroom is conveyed by the "~2.1k / 262k" total row instead.
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
            HStack(spacing: 1) {
                // Positional identity: segment ids mirror prompt-section ids,
                // which aren't guaranteed unique across the manifest, so keying
                // by id would risk a duplicate-ID ForEach trap.
                ForEach(Array(zip(segments, widths).enumerated()), id: \.offset) { _, pair in
                    let (segment, width) = pair
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(for: segment.tint).opacity(0.85))
                        .frame(width: width)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .frame(height: 6)
        .background(RoundedRectangle(cornerRadius: 4).fill(theme.tertiaryBackground.opacity(0.4)))
    }

    // MARK: - Legend

    /// The context legend at group granularity. Expandable groups render a
    /// tappable header that reveals their per-section rows indented beneath.
    private var contextGroupList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(contextGroups) { group in
                if group.isExpandable {
                    let expanded = expandedGroups.contains(group.id)
                    Button {
                        // No withAnimation: animating the popover resize
                        // crashes AppKit (see `body`). Snap the size instead.
                        if expanded {
                            expandedGroups.remove(group.id)
                        } else {
                            expandedGroups.insert(group.id)
                        }
                    } label: {
                        groupHeader(group, expanded: expanded)
                    }
                    .buttonStyle(.plain)

                    if expanded {
                        VStack(alignment: .leading, spacing: 4) {
                            // Key by position, not `entry.id`: a prompt section's
                            // id isn't guaranteed unique across the manifest, so
                            // duplicate ForEach IDs would trap. Positional
                            // identity is what we want for a static,
                            // display-only list anyway.
                            ForEach(Array(group.entries.enumerated()), id: \.offset) { _, entry in
                                entryRow(entry).padding(.leading, 11)
                            }
                        }
                    }
                } else if let entry = group.entries.first {
                    entryRow(entry)
                }
            }
        }
    }

    private func entryGroup(_ entries: [ContextBreakdown.Entry], highlightOutput: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                entryRow(entry, highlighted: highlightOutput && entry.id == "output")
            }
        }
    }

    /// Disclosure header for a multi-entry group: swatch, label, rotating
    /// chevron, summed tokens, and the group's share of the budget.
    private func groupHeader(_ group: BudgetGroup, expanded: Bool) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color(for: group.tint).opacity(0.85))
                .frame(width: 3, height: 12)
                .padding(.trailing, 8)

            Text(group.label)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)

            Image(systemName: "chevron.right")
                .font(.system(size: 7, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .padding(.leading, 4)

            Spacer()

            Text(formatTokenCount(group.tokens))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(theme.primaryText)

            Text(percent(group.tokens))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 32, alignment: .trailing)
        }
        .contentShape(Rectangle())
    }

    private func entryRow(_ entry: ContextBreakdown.Entry, highlighted: Bool = false) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color(for: entry.tint).opacity(0.85))
                .frame(width: 3, height: 12)
                .padding(.trailing, 8)

            Text(entry.label)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)

            Spacer()

            Text(formatTokenCount(entry.tokens))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(highlighted ? color(for: entry.tint) : theme.primaryText)
                .contentTransition(highlighted ? .numericText() : .identity)

            Text(percent(entry.tokens))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 32, alignment: .trailing)
        }
    }

    // MARK: - Total

    private var totalRow: some View {
        let prefix = isStreaming ? "" : "~"
        return HStack(spacing: 4) {
            Text("Total", bundle: .module)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
            Spacer()
            Text("\(prefix)\(formatTokenCount(breakdown.total))", bundle: .module)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .contentTransition(.numericText())
            if let max = maxTokens {
                Text("/ \(formatTokenCount(max))", bundle: .module)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
            }
        }
    }

    // MARK: - Chrome

    private var divider: some View {
        Divider().overlay(theme.primaryBorder.opacity(0.15))
    }

}

// MARK: - Balance Breakdown Popover

/// Hover card for the composer balance chip, styled to match
/// `ContextBreakdownPopover` (rounded glass card, 11pt header, hairline
/// dividers, monospaced values). Replaces the plain OS tooltip so the router
/// balance reads like the Context Budget breakdown beside it. The balance is
/// the hero figure (paralleling the budget bar) and tints amber when low/empty.
private struct BalanceBreakdownPopover: View {
    let sessionSpend: String
    let balance: String
    let isAttention: Bool
    let isFrozen: Bool

    @Environment(\.theme) private var theme

    private var accent: Color { theme.accentColor }

    private var footerText: Text {
        isFrozen
            ? Text("Account paused - add credits to resume.", bundle: .module)
            : Text("Click to add credits", bundle: .module)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                Text("This Session", bundle: .module)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(accent.opacity(0.85))
                    .frame(width: 3, height: 16)
                Text(verbatim: sessionSpend)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            divider
            HStack(spacing: 0) {
                Text("Router balance", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                Spacer()
                Text(verbatim: balance)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(isAttention ? theme.warningColor : theme.primaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            divider
            footerText
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(width: 200)
        .popoverCard()
    }

    private var divider: some View {
        Divider().overlay(theme.primaryBorder.opacity(0.15))
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
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(chipBackground)
                .clipShape(Capsule())
                .overlay(chipBorder)
                .shadow(
                    color: isHovered || isActive ? theme.accentColor.opacity(0.1) : .clear,
                    radius: 4,
                    x: 0,
                    y: 1
                )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    @ViewBuilder
    private var chipBackground: some View {
        ZStack {
            Capsule()
                .fill(theme.secondaryBackground.opacity(isHovered || isActive ? 0.95 : 0.8))

            if isHovered || isActive {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.accentColor.opacity(0.06),
                                Color.clear,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
    }

    private var chipBorder: some View {
        Capsule()
            .strokeBorder(
                LinearGradient(
                    colors: [
                        theme.glassEdgeLight.opacity(isHovered || isActive ? 0.25 : 0.15),
                        (isActive ? theme.accentColor : theme.primaryBorder).opacity(
                            isHovered || isActive ? 0.2 : 0.12
                        ),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }
}

// MARK: - Model Options Selector View

/// Popover that groups all model-specific options into a single panel.
private struct ModelOptionsSelectorView: View {
    let options: [ModelOptionDefinition]
    @Binding var values: [String: ModelOptionValue]
    let profileName: String
    let thinkingOptionId: String?

    @Environment(\.theme) private var theme

    private var hasExplicitOptions: Bool { !values.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(theme.primaryBorder.opacity(0.3))
            optionRows
        }
        .frame(width: 300)
        .popoverCard(
            cornerRadius: 12,
            accentOpacity: (0.06, 0.04),
            borderOpacity: 0.15,
            shadowOpacity: 0.25,
            shadowRadius: 20,
            shadowOffsetY: 10
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.secondaryText)

            Text(profileName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)

            Spacer()

            if hasExplicitOptions {
                Button {
                    values = [:]
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 9))
                        Text("Reset", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(theme.secondaryBackground.opacity(0.8))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(theme.primaryBorder.opacity(0.12), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Option Rows

    private var optionRows: some View {
        let filteredOptions = options.filter { $0.id != thinkingOptionId }

        return VStack(spacing: 0) {
            ForEach(Array(filteredOptions.enumerated()), id: \.element.id) { index, option in
                if index > 0 {
                    Divider().background(theme.primaryBorder.opacity(0.15)).padding(.horizontal, 14)
                }
                switch option.kind {
                case .segmented(let segments):
                    segmentedRow(option: option, segments: segments)
                case .toggle(let defaultValue):
                    toggleRow(option: option, defaultValue: defaultValue)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func segmentedRow(option: ModelOptionDefinition, segments: [ModelOptionSegment]) -> some View {
        let currentId = values[option.id]?.stringValue ?? segments.first?.id ?? ""
        let isExplicit = values[option.id] != nil

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let icon = option.icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isExplicit ? theme.accentColor : theme.tertiaryText)
                }
                Text(option.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
            }

            wrappedSegments(segments: segments, currentId: currentId, optionId: option.id)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func wrappedSegments(segments: [ModelOptionSegment], currentId: String, optionId: String) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(segments) { segment in
                let isSelected = segment.id == currentId
                Button {
                    values[optionId] = .string(segment.id)
                } label: {
                    Text(segment.label)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(
                                    isSelected
                                        ? theme.accentColor.opacity(theme.isDark ? 0.15 : 0.1)
                                        : theme.secondaryBackground.opacity(0.6)
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(
                                    isSelected
                                        ? theme.accentColor.opacity(0.3)
                                        : theme.primaryBorder.opacity(0.12),
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
    }

    private func toggleRow(option: ModelOptionDefinition, defaultValue: Bool) -> some View {
        let isOn = values[option.id]?.boolValue ?? defaultValue
        let isExplicit = values[option.id] != nil

        return HStack(spacing: 6) {
            if let icon = option.icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isExplicit ? theme.accentColor : theme.tertiaryText)
            }
            Text(option.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { isOn },
                    set: { values[option.id] = .bool($0) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(theme.tertiaryBackground.opacity(isHovered ? 0.95 : 0.8))

                if isHovered {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [theme.accentColor.opacity(0.1), Color.clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                Text("/")
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundColor(
                        isActive ? theme.accentColor : (isHovered ? theme.accentColor : theme.secondaryText)
                    )
            }
            .frame(width: 32, height: 32)
            .overlay(
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                theme.glassEdgeLight.opacity(isHovered ? 0.25 : 0.15),
                                theme.primaryBorder.opacity(isHovered ? 0.2 : 0.1),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .localizedHelp("Browse slash commands")
        .onHover { isHovered = $0 }
    }
}

private struct InputActionButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(theme.tertiaryBackground.opacity(isHovered ? 0.95 : 0.8))

                if isHovered {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    theme.accentColor.opacity(0.1),
                                    Color.clear,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                Image(systemName: icon)
                    .font(theme.font(size: CGFloat(theme.bodySize), weight: .medium))
                    .foregroundColor(isHovered ? theme.accentColor : theme.secondaryText)
            }
            .frame(width: 32, height: 32)
            .overlay(
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                theme.glassEdgeLight.opacity(isHovered ? 0.25 : 0.15),
                                theme.primaryBorder.opacity(isHovered ? 0.2 : 0.1),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isHovered ? theme.accentColor.opacity(0.15) : .clear,
                radius: 6,
                x: 0,
                y: 2
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(help)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Send Button

/// Polished send button with hover glow effect
private struct SendButton: View {
    let canSend: Bool
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            ZStack {
                // Background gradient
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.accentColor,
                                theme.accentColor.opacity(0.85),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                // Brighter overlay on hover
                if isHovered && canSend {
                    Circle()
                        .fill(Color.white.opacity(0.15))
                }

                Image(systemName: "arrow.up")
                    .font(theme.font(size: CGFloat(theme.bodySize) + 1, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 32, height: 32)
            .overlay(
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isHovered ? 0.35 : 0.2),
                                theme.accentColor.opacity(0.3),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: theme.accentColor.opacity(isHovered && canSend ? 0.5 : 0.35),
                radius: isHovered && canSend ? 10 : 6,
                x: 0,
                y: isHovered && canSend ? 4 : 2
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .disabled(!canSend)
        .opacity(canSend ? 1 : 0.5)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .animation(.easeOut(duration: 0.1), value: canSend)
    }
}

// MARK: - Stop Button

/// Polished stop button with red accent
private struct StopButton: View {
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white)
                    .frame(width: 8, height: 8)
                Text("Stop", bundle: .module)
                    .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                ZStack {
                    Capsule()
                        .fill(Color.red.opacity(isHovered ? 1.0 : 0.9))

                    if isHovered {
                        Capsule()
                            .fill(Color.white.opacity(0.1))
                    }
                }
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(isHovered ? 0.3 : 0.15), lineWidth: 1)
            )
            .shadow(
                color: Color.red.opacity(isHovered ? 0.4 : 0.25),
                radius: isHovered ? 8 : 4,
                x: 0,
                y: 2
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
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
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(theme.tertiaryBackground.opacity(canSend ? 0.95 : 0.7))

                if isHovered && canSend {
                    Circle()
                        .fill(theme.accentColor.opacity(0.12))
                }

                Image(systemName: "arrow.up")
                    .font(theme.font(size: CGFloat(theme.bodySize) + 1, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
            }
            .frame(width: 32, height: 32)
            .overlay(
                Circle()
                    .strokeBorder(theme.secondaryText.opacity(isHovered ? 0.35 : 0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .disabled(!canSend)
        .opacity(canSend ? 1 : 0.5)
        .localizedHelp("Queue message · sent when current run finishes")
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .animation(.easeOut(duration: 0.1), value: canSend)
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
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.accentColor,
                                theme.accentColor.opacity(0.85),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                if isHovered {
                    Circle()
                        .fill(Color.white.opacity(0.15))
                }

                Image(systemName: "bolt.fill")
                    .font(theme.font(size: CGFloat(theme.bodySize) + 1, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 32, height: 32)
            .overlay(
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isHovered ? 0.35 : 0.2),
                                theme.accentColor.opacity(0.3),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: theme.accentColor.opacity(isHovered ? 0.5 : 0.35),
                radius: isHovered ? 10 : 6,
                x: 0,
                y: isHovered ? 4 : 2
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .localizedHelp("Send now · interrupts current run")
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
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
                .background(Color(hex: "0f0f10"))
            }
        }

        static var previews: some View {
            PreviewWrapper()
        }
    }
#endif
