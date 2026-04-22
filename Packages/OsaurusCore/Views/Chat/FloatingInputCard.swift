//
//  FloatingInputCard.swift
//  osaurus
//
//  Premium floating input card with model chip and smooth animations
//

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
    let supportsImages: Bool
    /// Current estimated context token count for the session
    let estimatedContextTokens: Int
    /// Per-category breakdown of context token usage
    var contextBreakdown: ContextBreakdown = .zero
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
    /// Callback to clear the current chat session (triggered by /clear command).
    var onClearChat: (() -> Void)? = nil
    /// Callback when the user selects a skill slash command. Passes the skill UUID so the
    /// caller can inject that skill's instructions as one-off context for the next send.
    var onSkillSelected: ((UUID) -> Void)? = nil
    /// Binding to the session's pending one-off skill. Non-nil shows a dismissable skill chip.
    @Binding var pendingSkillId: UUID?

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
        supportsImages: Bool,
        estimatedContextTokens: Int,
        contextBreakdown: ContextBreakdown = .zero,
        onSend: @escaping (String?) -> Void,
        onStop: @escaping () -> Void,
        focusTrigger: Int = 0,
        agentId: UUID? = nil,
        windowId: UUID? = nil,
        isCompact: Bool = false,
        onClearChat: (() -> Void)? = nil,
        onSkillSelected: ((UUID) -> Void)? = nil,
        pendingSkillId: Binding<UUID?> = .constant(nil)
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
        self.supportsImages = supportsImages
        self.estimatedContextTokens = estimatedContextTokens
        self.contextBreakdown = contextBreakdown
        self.onSend = onSend
        self.onStop = onStop
        self.focusTrigger = focusTrigger
        self.agentId = agentId
        self.windowId = windowId
        self.isCompact = isCompact
        self.onClearChat = onClearChat
        self.onSkillSelected = onSkillSelected
        self._pendingSkillId = pendingSkillId
    }

    // Observe managers for reactive updates
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var folderContextService = FolderContextService.shared
    @ObservedObject private var sandboxState = SandboxManager.State.shared
    @ObservedObject private var clipboardService = ClipboardService.shared
    @ObservedObject private var appConfig = AppConfiguration.shared

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
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var isDragOver = false
    @State private var showModelPicker = false
    @State private var showModelOptionsPicker = false
    @State private var showContextBreakdown = false
    @State private var contextHoverTask: Task<Void, Never>?
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

    /// Tracks last voice activity time for silence timeout
    @State private var lastVoiceActivityTime: Date = Date()

    /// Displayed silence timeout duration (updated by timer for smooth UI updates)
    @State private var displayedSilenceTimeoutDuration: Double = 0

    /// Tracks confirmed transcription length to detect actual changes (for silence timeout)
    @State private var lastConfirmedLength: Int = 0

    @State private var pauseTimerCancellable: AnyCancellable? = nil

    // TextEditor should grow up to ~6 lines before scrolling
    private var inputFontSize: CGFloat { CGFloat(theme.bodySize) }
    private let maxVisibleLines: CGFloat = 6
    private var maxHeight: CGFloat {
        // Approximate line height from font metrics (ascender/descender/leading)
        let font = NSFont.systemFont(ofSize: inputFontSize)
        let lineHeight = font.ascender - font.descender + font.leading
        // Small extra padding so the last line isn't cramped
        return lineHeight * maxVisibleLines + 8
    }
    private let maxImageSize: Int = 10 * 1024 * 1024  // 10MB limit

    private var canSend: Bool {
        // While the slash command popup is visible, Enter selects a command — not sends
        guard !showSlashPopup else { return false }

        let hasText = !localText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasContent = hasText || !pendingAttachments.isEmpty
        return hasContent && !isStreaming
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
            let typingTokens = max(1, localText.count / 4)
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

    /// Max context length for the selected model
    private var maxContextTokens: Int? {
        guard let model = selectedModel else { return nil }
        // Foundation model has ~4096 token context
        if model == "foundation" || model == "default" {
            return 4096
        }
        if let info = ModelInfo.load(modelId: model),
            let ctx = info.model.contextLength
        {
            return ctx
        }
        return nil
    }

    /// Whether voice button should be visible: voice is enabled + mic permission granted + a model is downloaded.
    /// Does NOT require the model to be loaded into memory yet — loading happens on demand.
    private var isVoiceConfigured: Bool {
        voiceConfig.voiceInputEnabled
            && speechService.microphonePermissionGranted
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

    private var mainContent: some View {
        VStack(spacing: 12) {
            if (pickerItems.count > 1
                || displayContextTokens > 0
                || isSandboxAvailable
                || (appConfig.chatConfig.enableClipboardMonitoring && clipboardService.hasNewContent))
                && !showVoiceOverlay
            {
                selectorRow
                    .padding(.top, 8)
                    .padding(.horizontal, 20)
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
                        .onDrop(of: [UTType.image, UTType.fileURL], isTargeted: $isDragOver) { providers in
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
    }

    var body: some View {
        let _ = ChatPerfTrace.shared.count("body.FloatingInputCard")
        mainContent
            .onAppear {
                let isReappear = !localText.isEmpty || voiceInputState != .idle
                localText = text
                print("[VoiceDebug] FloatingInputCard onAppear (reappear=\(isReappear))")

                // Focus immediately when view appears
                isFocused = true

                // Load voice config (cached after first load)
                loadVoiceConfig()

                // Ensure voice model is loaded if enabled and not already loaded
                if voiceConfig.voiceInputEnabled && !speechService.isModelLoaded && !speechService.isLoadingModel {
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

                // If voice was just enabled, ensure model is loaded
                if voiceConfig.voiceInputEnabled && !speechService.isModelLoaded && !speechService.isLoadingModel {
                    if let model = SpeechModelManager.shared.selectedModel {
                        Task { try? await speechService.loadModel(model.id) }
                    }
                }
            }
            .onChange(of: isStreaming) { wasStreaming, nowStreaming in
                // re-focus the input when streaming ends so the user can type immediately.
                // focus is cleared on send to stop the NSTextView cursor-blink display link
                // during streaming; restore it once the response is complete.
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
                if voiceInputState == .recording && !newValue.isEmpty {
                    if speechService.isSpeechDetected || speechService.audioLevel > 0.05 {
                        hasDetectedSpeechThisTurn = true
                        lastSpeechTime = Date()
                    }
                }
            }
            .onChange(of: speechService.confirmedTranscription) { _, newValue in
                // When confirmed transcription changes, user was speaking
                if voiceInputState == .recording && !newValue.isEmpty {
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
                        }
                } else {
                    pauseTimerCancellable = nil
                }
            }
            .modifier(VoiceDebugObservers())
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
        guard isVoiceAvailable else {
            print(
                "[VoiceDebug] startVoiceInput called but isVoiceAvailable=false — triggering emergency load if possible"
            )
            // Model may not be loaded yet — kick off load and bail; once loaded the button will become tappable.
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
                }
            }
        }
    }

    private func cancelVoiceInput() {
        print("[FloatingInputCard] User cancelled voice input - disabling continuous mode")
        hasDetectedSpeechThisTurn = false
        lastConfirmedLength = 0
        isContinuousVoiceMode = false
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

        let hasContent = !speechService.currentTranscription.isEmpty || !speechService.confirmedTranscription.isEmpty
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
        let currentConfirmedLen = speechService.confirmedTranscription.count
        let hasNewConfirmedText = currentConfirmedLen > lastConfirmedLength
        if hasNewConfirmedText {
            lastConfirmedLength = currentConfirmedLen
        }

        if speechService.isSpeechDetected || hasNewConfirmedText || !speechService.currentTranscription.isEmpty {
            lastVoiceActivityTime = Date()
        }

        // Calculate and update displayed silence duration
        let silenceDuration = Date().timeIntervalSince(lastVoiceActivityTime)
        displayedSilenceTimeoutDuration = silenceDuration

        // Check if timeout exceeded
        if silenceDuration >= voiceConfig.silenceTimeoutSeconds {
            let hasContent =
                !speechService.currentTranscription.isEmpty || !speechService.confirmedTranscription.isEmpty

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
            let transcribedText = [
                speechService.confirmedTranscription,
                speechService.currentTranscription,
            ]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

            if !transcribedText.isEmpty {
                sendVoiceMessage(transcribedText)
            } else {
                stopVoiceInputFromTimeout()
            }
        } else {
            // Update remaining time
            voiceInputState = .paused(remaining: newRemaining)
        }
    }

    private func stopVoiceInputFromTimeout() {
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

        // show sending state first
        voiceInputState = .sending

        Task {
            _ = await speechService.stopStreamingTranscription()
            // clear transcription so next voice input starts fresh
            speechService.clearTranscription()
            logVoiceState(trigger: "sendVoiceMessage-afterStop")

            print("[FloatingInputCard] Invoking cleanup for voice message (\(message.count) chars)")
            let cleanedMessage = await TranscriptionCleanupService.shared.clean(message)
            print("[FloatingInputCard] Cleanup done. Original: \(message) | Cleaned: \(cleanedMessage)")

            await MainActor.run {
                voiceInputState = .idle
                showVoiceOverlay = false

                let existing = localText.trimmingCharacters(in: .whitespacesAndNewlines)
                let fullMessage = existing.isEmpty ? cleanedMessage : "\(existing) \(cleanedMessage)"

                // try to paste. if it fails (permissions), we fall back to direct text setting
                if KeyboardSimulationService.shared.pasteText(cleanedMessage) {
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
            }
        }
    }

    private func transferToTextInput() {
        print("[FloatingInputCard] Transferring to text input - disabling continuous mode")
        // Transfer transcription to text input and close overlay
        let transcribedText = [
            speechService.confirmedTranscription,
            speechService.currentTranscription,
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")

        voiceInputState = .sending
        // exit continuous mode when switching to text
        isContinuousVoiceMode = false

        Task {
            _ = await speechService.stopStreamingTranscription()
            speechService.clearTranscription()

            let cleaned = await TranscriptionCleanupService.shared.clean(transcribedText)

            await MainActor.run {
                voiceInputState = .idle
                showVoiceOverlay = false

                let existing = localText.trimmingCharacters(in: .whitespacesAndNewlines)
                let fullCombined = existing.isEmpty ? cleaned : "\(existing) \(cleaned)"

                if KeyboardSimulationService.shared.pasteText(cleaned) {
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
        localText = ""
        text = ""
        // resign first responder so the NSTextView cursor-blink display link stops driving
        // the window compositor at 60fps through the streaming response
        isFocused = false
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
                ToastManager.shared.info("Clear Chat", message: "Pass an onClearChat handler to enable /clear")
            }
        case "model":
            showModelPicker = true
        case "help":
            ToastManager.shared.info(
                "Slash Commands",
                message: "Type / to open commands. ↑↓ to navigate, ↵ to select, Esc to dismiss."
            )
        default:
            break
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
                ForEach(Array(pendingAttachments.enumerated()), id: \.element.id) { index, attachment in
                    switch attachment.kind {
                    case .image(let data):
                        CachedImageThumbnail(
                            imageData: data,
                            size: 40,
                            onRemove: {
                                withAnimation(theme.springAnimation()) {
                                    _ = pendingAttachments.remove(at: index)
                                }
                            }
                        )
                    case .document:
                        DocumentChip(attachment: attachment) {
                            withAnimation(theme.springAnimation()) {
                                _ = pendingAttachments.remove(at: index)
                            }
                        }
                    }
                }
            }
        }
        .frame(height: 48)
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
            if !pickerItems.isEmpty {
                modelSelectorChip
            }

            thinkingToggleChip

            if hasNonThinkingOptions {
                modelOptionsSelectorChip
            }

            // Sandbox toggle: visible whenever the sandbox is available on
            // this system. Mutual exclusion with the folder backend is
            // enforced inside `toggleSandbox()` (it clears the active
            // folder before enabling sandbox), not by hiding the chip —
            // that way the user can always see and switch backends.
            if isSandboxAvailable {
                sandboxToggleChip
            }

            // Clipboard chip (visible when there's something new on the clipboard and monitoring is enabled)
            if AppConfiguration.shared.chatConfig.enableClipboardMonitoring && clipboardService.hasNewContent {
                clipboardToggleChip
            }

            // Folder context selector: always available so the user can
            // point any chat at a working directory. Mutual exclusion with
            // sandbox is enforced inside the selection handlers (they
            // disable autonomous exec before opening the picker).
            folderContextChip

            Spacer()

            // Context size indicator (right-aligned)
            if displayContextTokens > 0 {
                contextIndicatorChip
            }
        }
    }

    // MARK: - Context Indicator

    @ViewBuilder
    private var contextIndicatorChip: some View {
        HStack(spacing: 4) {
            let prefix = isStreaming ? "" : "~"
            let tokenText =
                if let maxCtx = maxContextTokens {
                    "\(prefix)\(formatTokenCount(displayContextTokens)) / \(formatTokenCount(maxCtx))"
                } else {
                    "\(prefix)\(formatTokenCount(displayContextTokens))"
                }
            Text(tokenText)
                .font(.system(size: CGFloat(theme.captionSize) - 1, weight: .medium, design: .monospaced))
                .foregroundColor(isStreaming ? theme.secondaryText : theme.tertiaryText)

            if !isCompact {
                Text("tokens", bundle: .module)
                    .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .regular))
                    .foregroundColor(theme.tertiaryText.opacity(0.7))
            }
        }
        .onHover { hovering in
            contextHoverTask?.cancel()
            if hovering {
                contextHoverTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    showContextBreakdown = true
                }
            } else {
                showContextBreakdown = false
            }
        }
        .popover(isPresented: $showContextBreakdown, arrowEdge: .top) {
            ContextBreakdownPopover(
                breakdown: displayContextBreakdown,
                maxTokens: maxContextTokens,
                isStreaming: isStreaming,
                formatTokenCount: formatTokenCount
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

    private var isSelectedModelDeprecated: Bool {
        guard let id = selectedModel else { return false }
        return ModelManager.replacementForDeprecatedModel(id) != nil
    }

    private var modelSelectorChip: some View {
        SelectorChip(isActive: showModelPicker) {
            showModelPicker.toggle()
        } content: {
            HStack(spacing: 6) {
                if isSelectedModelDeprecated {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(theme.font(size: CGFloat(theme.captionSize) - 2))
                        .foregroundColor(.orange)
                        .help(Text("This model is outdated. Click to switch to a newer version.", bundle: .module))
                } else {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                        .help(Text("Model ready", bundle: .module))
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
    }

    // MARK: - Thinking Toggle

    @ViewBuilder
    private var thinkingToggleChip: some View {
        if let model = selectedModel,
            let thinkingOpt = ModelProfileRegistry.profile(for: model)?.thinkingOption
        {
            let isCurrentlyEnabled = activeModelOptions[thinkingOpt.id]?.boolValue ?? false
            let isEnabled = thinkingOpt.inverted ? !isCurrentlyEnabled : isCurrentlyEnabled

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
            .help(Text("Toggle model reasoning mode", bundle: .module))
        }
    }

    private func toggleThinking(id: String) {
        let current = activeModelOptions[id]?.boolValue ?? false
        let newVal = !current

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
            let profile = ModelProfileRegistry.profile(for: model)
        else { return "" }
        let defaults = profile.defaults
        let nonDefault = activeProfileOptions.compactMap { option -> String? in
            guard let current = activeModelOptions[option.id],
                current != defaults[option.id]
            else { return nil }
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
                values: $activeModelOptions,
                defaults: selectedModel.flatMap { ModelProfileRegistry.profile(for: $0)?.defaults } ?? [:],
                profileName: selectedModel.flatMap { ModelProfileRegistry.profile(for: $0)?.displayName } ?? "",
                thinkingOptionId: selectedModel.flatMap { ModelProfileRegistry.profile(for: $0)?.thinkingOption?.id }
            )
        }
    }

    // MARK: - Sandbox Toggle Chip

    private var effectiveAgentId: UUID {
        agentId ?? Agent.defaultId
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

    private func retrySandbox() {
        let agentId = effectiveAgentId
        Task {
            SandboxToolRegistrar.shared.resetStartupFailures()
            await SandboxToolRegistrar.shared.registerTools(for: agentId)
        }
    }

    private func toggleSandbox() {
        let currentConfig = agentManager.effectiveAutonomousExec(for: effectiveAgentId)
        var newConfig = currentConfig ?? .default
        newConfig.enabled.toggle()
        let agentId = effectiveAgentId
        let manager = agentManager
        let willEnable = newConfig.enabled
        let folderService = folderContextService
        Task {
            // Sandbox and folder backends are mutually exclusive — clear the
            // folder context BEFORE provisioning sandbox so we don't briefly
            // leave both backends "live". On a provision failure we roll the
            // sandbox flag back but leave the folder cleared (the user can
            // re-pick it); avoiding a partial-state mess is worth the extra
            // tap.
            if willEnable && folderService.hasActiveFolder {
                folderService.clearFolder()
            }
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

    /// Disable autonomous execution (sandbox) if currently enabled. Used by
    /// folder selection paths to enforce sandbox/folder mutual exclusion at
    /// the tap site instead of by hiding chips.
    private func disableSandboxIfEnabled() async {
        guard isSandboxEnabled else { return }
        var config = agentManager.effectiveAutonomousExec(for: effectiveAgentId) ?? .default
        config.enabled = false
        do {
            try await agentManager.updateAutonomousExec(config, for: effectiveAgentId)
        } catch {
            debugLog(
                "[Sandbox] Failed to disable sandbox for folder backend switch: \(error.localizedDescription)"
            )
        }
    }

    /// Disable sandbox (if enabled) then open the system folder picker.
    /// Drives both the chip's main tap and the context-menu "Change Folder"
    /// item so they share one mutual-exclusion path.
    private func selectFolderWithSandboxOff() {
        Task {
            await disableSandboxIfEnabled()
            _ = await folderContextService.selectFolder()
        }
    }

    private var sandboxHelpText: String {
        if let failure = sandboxFailure, isSandboxEnabled {
            return "Sandbox unavailable: \(failure.message)\nRight-click for Retry."
        } else if isSandboxLoading {
            return "Sandbox is starting up…"
        } else if isSandboxEnabled && isSandboxRunning {
            return "Sandbox is active — click to disable. Right-click for settings."
        } else if isSandboxEnabled {
            return "Sandbox enabled — container not running"
        } else {
            return "Enable Sandbox for autonomous code execution"
        }
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
        Button(action: toggleSandbox) {
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

                Text("Sandbox", bundle: .module)
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
        .disabled(isSandboxLoading)
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

    private var clipboardChipInfo: (icon: String, label: String) {
        guard let content = clipboardService.currentContent else {
            return ("paperclip", "Clipboard")
        }
        switch content {
        case .text:
            return ("text.quote", "Content")
        case .image:
            return ("photo", "Image")
        case .file(let url):
            let kind = Attachment.Kind.document(filename: url.lastPathComponent, content: "", fileSize: 0)
            let icon = Attachment(kind: kind).fileIcon
            return (icon, url.lastPathComponent)
        }
    }

    private var clipboardChipLabel: some View {
        let info = clipboardChipInfo
        return HStack(spacing: 5) {
            Image(systemName: info.icon)
                .font(.system(size: CGFloat(theme.captionSize) - 2, weight: .medium))
                .foregroundColor(theme.accentColor)

            HStack(spacing: 4) {
                Text("Paste \(info.label) From", bundle: .module)
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                    .foregroundColor(theme.secondaryText)

                Text(clipboardService.lastSourceApp ?? "Clipboard")
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .bold))
                    .foregroundColor(theme.accentColor)
            }
            .lineLimit(1)

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
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isClipboardHovered = hovering
            }
        }
        .help(Text("Attach snippet from \(clipboardService.lastSourceApp ?? "clipboard")", bundle: .module))
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
                        localText += text
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

        case .image(let data):
            withAnimation(theme.springAnimation()) {
                pendingAttachments.append(.image(data))
                clipboardService.markAsRead()
            }

        case .file(let url):
            if DocumentParser.isImageFile(url: url) {
                if let data = try? Data(contentsOf: url),
                    let nsImage = NSImage(data: data),
                    let pngData = nsImage.pngData()
                {
                    withAnimation(theme.springAnimation()) {
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
                        await MainActor.run {
                            ToastManager.shared.error("Could not attach file", message: error.localizedDescription)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Folder Context Chip

    private var folderContextChip: some View {
        let hasFolder = folderContextService.hasActiveFolder

        return HStack(spacing: 4) {
            Button(action: selectFolderWithSandboxOff) {
                folderChipContent(hasFolder: hasFolder, canEdit: true)
            }
            .buttonStyle(.plain)
            .help(hasFolder ? "Change working folder" : "Select a working folder")
            .contextMenu {
                if hasFolder {
                    Button {
                        selectFolderWithSandboxOff()
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
                .help(Text("Clear folder selection", bundle: .module))
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
        VStack(alignment: .leading, spacing: 0) {
            if !pendingAttachments.isEmpty || pendingSkillId != nil {
                HStack(alignment: .center, spacing: 6) {
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
                .padding(.top, (pendingAttachments.isEmpty && pendingSkillId == nil) ? 10 : 6)
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
        Group {
            if speechService.isLoadingModel {
                // model is loading — show a small spinner in place of the mic icon
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
                await MainActor.run {
                    ToastManager.shared.error(
                        "Could not attach \(filename)",
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private func pickAttachment() {
        let panel = NSOpenPanel()
        var allowedTypes: [UTType] = [UTType.image]
        allowedTypes.append(contentsOf: DocumentParser.supportedDocumentTypes)
        panel.allowedContentTypes = allowedTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Select files to attach"

        if panel.runModal() == .OK {
            for url in panel.urls {
                if DocumentParser.isImageFile(url: url) {
                    if let data = try? Data(contentsOf: url), data.count <= maxImageSize,
                        let nsImage = NSImage(data: data),
                        let pngData = nsImage.pngData()
                    {
                        appendAttachment(.image(pngData))
                    }
                } else if DocumentParser.canParse(url: url) {
                    parseAndAttach(url: url)
                }
            }
        }
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                    guard let data = data, error == nil, data.count <= maxImageSize else { return }
                    DispatchQueue.main.async {
                        if let nsImage = NSImage(data: data),
                            let pngData = nsImage.pngData()
                        {
                            appendAttachment(.image(pngData))
                        }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                    guard let data = item as? Data,
                        let url = URL(dataRepresentation: data, relativeTo: nil),
                        DocumentParser.canParse(url: url)
                    else { return }
                    DispatchQueue.main.async {
                        self.parseAndAttach(url: url)
                    }
                }
            }
        }
        return handled
    }

    /// Placeholder text for the input field.
    private var placeholderText: String { "Message or attach files..." }

    private var textInputArea: some View {
        EditableTextView(
            text: $localText,
            fontSize: inputFontSize,
            textColor: theme.primaryText,
            cursorColor: theme.cursorColor,
            isFocused: $isFocused,
            isComposing: $isComposing,
            maxHeight: maxHeight,
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
                } : nil
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
                supportsImages: supportsImages,
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
                    stopButton
                }
                sendButton
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

    // MARK: - Card Styling

    private var cardBackground: some View {
        ZStack {
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

    @State private var cachedImage: NSImage?
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let nsImage = cachedImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(theme.primaryBorder.opacity(0.3), lineWidth: 1)
                    )
            } else {
                // Placeholder while loading
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.secondaryBackground)
                    .frame(width: size, height: size)
            }

            // Remove button
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
            .offset(x: 4, y: -4)
        }
        .padding(.top, 4)
        .padding(.trailing, 4)
        .task(id: imageData) {
            // Decode image only once when data changes
            cachedImage = NSImage(data: imageData)
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

        // Check if pasteboard contains an image
        guard let types = pasteboard.types,
            types.contains(where: { $0 == .png || $0 == .tiff || $0 == .fileURL })
        else {
            return false
        }

        // Try to get image data directly
        if let imageData = pasteboard.data(forType: .png) {
            onImagePaste?(imageData)
            return true
        }

        if let imageData = pasteboard.data(forType: .tiff),
            let nsImage = NSImage(data: imageData),
            let pngData = nsImage.pngData()
        {
            onImagePaste?(pngData)
            return true
        }

        // Try file URL (for copied files)
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                if let uti = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier,
                    UTType(uti)?.conforms(to: .image) == true,
                    let data = try? Data(contentsOf: url),
                    let nsImage = NSImage(data: data),
                    let pngData = nsImage.pngData()
                {
                    onImagePaste?(pngData)
                    return true
                }
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

// MARK: - Context Breakdown Popover

private struct ContextBreakdownPopover: View {
    let breakdown: ContextBreakdown
    let maxTokens: Int?
    let isStreaming: Bool
    let formatTokenCount: (Int) -> String

    @Environment(\.theme) private var theme

    private var budgetCap: Int { maxTokens ?? breakdown.total }

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
        }
    }

    // MARK: - Body

    var body: some View {
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

            if !breakdown.context.isEmpty {
                divider
                entryGroup(breakdown.context).padding(.horizontal, 12).padding(.vertical, 8)
            }

            if !breakdown.messages.isEmpty {
                divider
                entryGroup(breakdown.messages, highlightOutput: true).padding(.horizontal, 12).padding(.vertical, 8)
            }

            divider
            totalRow.padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 240)
        .background(popoverBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(popoverBorder)
        .shadow(color: theme.shadowColor.opacity(0.2), radius: 16, x: 0, y: 8)
    }

    // MARK: - Stacked Bar

    private var barChart: some View {
        let scale = budgetCap > 0 ? budgetCap : 1
        let entries = breakdown.allEntries.filter { $0.tokens > 0 }
        return GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(entries) { entry in
                    let fraction = CGFloat(entry.tokens) / CGFloat(scale)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(for: entry.tint).opacity(0.85))
                        .frame(width: max(fraction * geo.size.width, fraction > 0 ? 3 : 0))
                }
                if maxTokens != nil { Spacer(minLength: 0) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .frame(height: 6)
        .background(RoundedRectangle(cornerRadius: 4).fill(theme.tertiaryBackground.opacity(0.4)))
    }

    // MARK: - Legend

    private func entryGroup(_ entries: [ContextBreakdown.Entry], highlightOutput: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(entries) { entry in
                entryRow(entry, highlighted: highlightOutput && entry.id == "output")
            }
        }
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

            Text(budgetCap > 0 ? "\(entry.tokens * 100 / budgetCap)%" : "0%")
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

    private var popoverBackground: some View {
        ZStack {
            if theme.glassEnabled {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.primaryBackground.opacity(theme.isDark ? 0.85 : 0.92))
            LinearGradient(
                colors: [theme.accentColor.opacity(theme.isDark ? 0.04 : 0.03), .clear],
                startPoint: .top,
                endPoint: .center
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var popoverBorder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [theme.glassEdgeLight.opacity(0.2), theme.primaryBorder.opacity(0.12)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }
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
    let defaults: [String: ModelOptionValue]
    let profileName: String
    let thinkingOptionId: String?

    @Environment(\.theme) private var theme

    private var hasNonDefaults: Bool {
        options.contains { option in
            guard let current = values[option.id] else { return false }
            return current != defaults[option.id]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(theme.primaryBorder.opacity(0.3))
            optionRows
        }
        .frame(width: 300)
        .background(popoverBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(popoverBorder)
        .shadow(color: theme.shadowColor.opacity(0.25), radius: 20, x: 0, y: 10)
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

            if hasNonDefaults {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        values = defaults
                    }
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
        let isNonDefault = values[option.id] != defaults[option.id]

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let icon = option.icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isNonDefault ? theme.accentColor : theme.tertiaryText)
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
                    withAnimation(.easeOut(duration: 0.15)) {
                        values[optionId] = .string(segment.id)
                    }
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
            }
        }
    }

    private func toggleRow(option: ModelOptionDefinition, defaultValue: Bool) -> some View {
        let isOn = values[option.id]?.boolValue ?? defaultValue
        let isNonDefault = values[option.id] != defaults[option.id]

        return HStack(spacing: 6) {
            if let icon = option.icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isNonDefault ? theme.accentColor : theme.tertiaryText)
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

    // MARK: - Background & Border

    private var popoverBackground: some View {
        ZStack {
            if theme.glassEnabled {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.primaryBackground.opacity(theme.isDark ? 0.85 : 0.92))
            LinearGradient(
                colors: [
                    theme.accentColor.opacity(theme.isDark ? 0.06 : 0.04),
                    Color.clear,
                ],
                startPoint: .top,
                endPoint: .center
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var popoverBorder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        theme.glassEdgeLight.opacity(0.2),
                        theme.primaryBorder.opacity(0.15),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
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
        .help(Text("Browse slash commands", bundle: .module))
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
