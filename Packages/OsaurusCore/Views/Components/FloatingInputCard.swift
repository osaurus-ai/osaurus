//
//  FloatingInputCard.swift
//  osaurus
//
//  Premium floating input card with model chip and smooth animations
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct FloatingInputCard: View {
    @Binding var text: String
    @Binding var selectedModel: String?
    @Binding var pendingImages: [Data]
    /// When true, voice input auto-restarts after AI responds (continuous conversation mode)
    @Binding var isContinuousVoiceMode: Bool
    @Binding var voiceInputState: VoiceInputState
    @Binding var showVoiceOverlay: Bool
    let modelOptions: [ModelOption]
    let isStreaming: Bool
    let supportsImages: Bool
    /// Current estimated context token count for the session
    let estimatedContextTokens: Int
    let onSend: () -> Void
    let onStop: () -> Void
    /// Trigger to focus the input field (increment to focus)
    var focusTrigger: Int = 0
    /// Current persona ID (used for persona-specific settings)
    var personaId: UUID? = nil
    /// Window ID for targeted VAD notifications
    var windowId: UUID? = nil
    /// Agent input state (nil = chat mode, non-nil = agent mode)
    var agentInputState: AgentInputState? = nil
    /// Queued message waiting to be injected (agent mode)
    var pendingQueuedMessage: String? = nil
    /// Callback to end the current task (agent mode)
    var onEndTask: (() -> Void)? = nil
    /// Callback to resume an in-progress issue (agent mode)
    var onResume: (() -> Void)? = nil
    /// Whether there's an issue that can be resumed (agent mode)
    var canResume: Bool = false
    /// Cumulative token usage for agent mode
    var cumulativeTokens: Int? = nil
    /// Hide context indicator in empty states
    var hideContextIndicator: Bool = false

    // Observe managers for reactive updates
    @ObservedObject private var toolRegistry = ToolRegistry.shared
    @ObservedObject private var skillManager = SkillManager.shared
    @ObservedObject private var personaManager = PersonaManager.shared

    // Local state for text input to prevent parent re-renders on every keystroke
    @State private var localText: String = ""
    @State private var isFocused: Bool = false
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var isDragOver = false
    @State private var showModelPicker = false
    @State private var showCapabilitiesPicker = false
    // Cache model options to prevent popover refresh during streaming
    @State private var cachedModelOptions: [ModelOption] = []

    // MARK: - Voice Input State
    @ObservedObject private var whisperService = WhisperKitService.shared
    @State private var voiceConfig = WhisperConfiguration.default

    // Pause detection state
    @State private var lastSpeechTime: Date = Date()
    @State private var isPauseDetectionActive: Bool = false

    /// Tracks last voice activity time for silence timeout
    @State private var lastVoiceActivityTime: Date = Date()

    /// Displayed silence timeout duration (updated by timer for smooth UI updates)
    @State private var displayedSilenceTimeoutDuration: Double = 0

    /// Threshold for considering audio as "speech" vs "silence"
    private let speechThreshold: Float = 0.05

    /// Timer publisher for pause detection (fires every 100ms)
    private let pauseDetectionPublisher = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

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
        let hasText = !localText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasImages = !pendingImages.isEmpty
        let hasContent = hasText || hasImages

        // In agent mode, allow sending during streaming (will queue)
        // but only if there isn't already a queued message
        if agentInputState != nil && isStreaming {
            return hasContent && pendingQueuedMessage == nil
        }

        return hasContent && !isStreaming
    }

    private var showPlaceholder: Bool {
        localText.isEmpty && pendingImages.isEmpty
    }

    /// Context tokens including what's currently being typed (localText may differ from text binding)
    private var displayContextTokens: Int {
        var total = estimatedContextTokens
        // Add tokens for text being typed (if not already counted via binding)
        // The localText is the real-time typing state
        if !localText.isEmpty {
            total += max(1, localText.count / 4)
        }
        return total
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

    /// Whether voice input is available (enabled + model loaded + permission granted)
    private var isVoiceAvailable: Bool {
        voiceConfig.voiceInputEnabled && whisperService.isModelLoaded
            && whisperService.microphonePermissionGranted
    }

    /// Whether voice is in a recording/active state
    private var isVoiceActive: Bool {
        voiceInputState != .idle
    }

    /// Current silence duration for pause detection visualization
    private var currentSilenceDuration: Double {
        guard case .recording = voiceInputState else { return 0 }
        return Date().timeIntervalSince(lastSpeechTime)
    }

    var body: some View {
        VStack(spacing: 12) {
            // Model and tool selector chips (always visible)
            if (modelOptions.count > 1 || !toolRegistry.listTools().isEmpty || !skillManager.skills.isEmpty
                || displayContextTokens > 0) && !showVoiceOverlay
            {
                selectorRow
                    .padding(.top, 8)
                    .padding(.horizontal, 20)
            }

            // Switch between regular input and voice overlay
            if showVoiceOverlay {
                // Voice input overlay - replaces the input card
                VoiceInputOverlay(
                    state: $voiceInputState,
                    audioLevel: whisperService.audioLevel,
                    transcription: whisperService.currentTranscription,
                    confirmedText: whisperService.confirmedTranscription,
                    pauseDuration: voiceConfig.pauseDuration,
                    confirmationDelay: voiceConfig.confirmationDelay,
                    silenceDuration: currentSilenceDuration,
                    silenceTimeoutDuration: voiceConfig.silenceTimeoutSeconds,
                    silenceTimeoutProgress: displayedSilenceTimeoutDuration,
                    isContinuousMode: isContinuousVoiceMode,
                    isStreaming: isStreaming,
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
                // Main input card (with inline images)
                inputCard
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .onDrop(of: [UTType.image], isTargeted: $isDragOver) { providers in
                        handleImageDrop(providers)
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
        .onAppear {
            localText = text

            // Focus immediately when view appears
            isFocused = true

            // Load voice config (cached after first load)
            loadVoiceConfig()

            // Sync local state with singleton service state on appear
            if whisperService.isRecording {
                if voiceInputState == .idle {
                    voiceInputState = .recording
                    lastSpeechTime = Date()
                    lastVoiceActivityTime = Date()
                    isPauseDetectionActive = voiceConfig.pauseDuration > 0
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
        }
        .onChange(of: isStreaming) { wasStreaming, nowStreaming in
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
                isPauseDetectionActive = false
                Task {
                    _ = await whisperService.stopStreamingTranscription()
                    whisperService.clearTranscription()
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
        .onChange(of: focusTrigger) { _, _ in
            isFocused = true
        }
        .onChange(of: whisperService.isRecording) { _, isRecording in
            print(
                "[FloatingInputCard] isRecording changed to: \(isRecording). voiceInputState: \(voiceInputState), showVoiceOverlay: \(showVoiceOverlay)"
            )
            // Sync voice state with service
            if isRecording {
                // Recording has started - now we can set recording state and reset timers
                // This ensures silence timeout doesn't run during audio engine startup
                if voiceInputState == .idle && showVoiceOverlay {
                    // Started from startVoiceInput() - set recording state now that audio is ready
                    voiceInputState = .recording
                    lastSpeechTime = Date()
                    lastVoiceActivityTime = Date()  // Reset silence timeout NOW when recording actually starts
                    isPauseDetectionActive = voiceConfig.pauseDuration > 0
                    print("[FloatingInputCard] Recording confirmed - voice input ready")
                } else if voiceInputState == .idle {
                    // Started from external trigger (e.g., VAD)
                    // Only transition to recording if we have an indication that this is intended for chat
                    // However, if we don't adopt it, we might be in a zombie state.
                    // Let's log it but not force state unless we're sure.
                    // But VAD notification usually sets showVoiceOverlay=true.
                    // If showVoiceOverlay is false, this might be a phantom recording restart.
                    // Let's adopt it but keep overlay hidden? No, that breaks UI state.
                    // For now, keep existing behavior but log warning if overlay is hidden.
                    print("[FloatingInputCard] External recording detected. Overlay: \(showVoiceOverlay)")
                    voiceInputState = .recording
                    lastSpeechTime = Date()
                    lastVoiceActivityTime = Date()
                    isPauseDetectionActive = voiceConfig.pauseDuration > 0
                }
            } else {
                // If service stopped recording (e.g. via Esc key in ChatView), sync local state
                if voiceInputState != .idle {
                    voiceInputState = .idle
                    showVoiceOverlay = false
                }
                isPauseDetectionActive = false
            }
        }
        .onChange(of: whisperService.audioLevel) { _, level in
            // Track when speech is detected
            if level > speechThreshold && voiceInputState == .recording {
                lastSpeechTime = Date()
            }
        }
        .onChange(of: whisperService.currentTranscription) { _, newValue in
            // When new transcription arrives, user is speaking
            if voiceInputState == .recording && !newValue.isEmpty {
                lastSpeechTime = Date()
            }
        }
        .onChange(of: whisperService.confirmedTranscription) { _, newValue in
            // When confirmed transcription changes, user was speaking
            if voiceInputState == .recording && !newValue.isEmpty {
                lastSpeechTime = Date()
            }
        }
        .onChange(of: voiceInputState) { _, newState in
            print("[FloatingInputCard] voiceInputState changed to: \(newState)")
            // Handle state changes
            if case .recording = newState {
                // Resumed recording, restart detection
                lastSpeechTime = Date()
                isPauseDetectionActive = true
            } else {
                isPauseDetectionActive = false
            }
        }
        .onChange(of: showVoiceOverlay) { _, newValue in
            print("[FloatingInputCard] showVoiceOverlay changed to: \(newValue)")
        }
        .onChange(of: isContinuousVoiceMode) { _, newValue in
            print("[FloatingInputCard] isContinuousVoiceMode changed to: \(newValue)")
        }
        .onReceive(pauseDetectionPublisher) { _ in
            checkForPause()
            checkForSilenceTimeout()
        }
    }

    // MARK: - Voice Input Methods

    private func loadVoiceConfig() {
        voiceConfig = WhisperConfigurationStore.load()
    }

    private func startVoiceInput() {
        guard isVoiceAvailable else { return }

        // If continuous mode is active, we should be aggressive about ensuring the UI is shown.
        // If recording is already active (e.g. VAD or zombie state), just attach to it.
        if whisperService.isRecording {
            print("[FloatingInputCard] startVoiceInput: Recording already active, ensuring UI is visible")
            showVoiceOverlay = true
            if voiceInputState == .idle {
                voiceInputState = .recording
                lastSpeechTime = Date()
                lastVoiceActivityTime = Date()
                isPauseDetectionActive = voiceConfig.pauseDuration > 0
            }
            return
        }

        // Don't start if already recording (handled above) or starting
        guard voiceInputState == .idle else { return }

        // Show overlay immediately for visual feedback, but don't set recording state yet.
        // Recording state will be set when whisperService.isRecording becomes true.
        showVoiceOverlay = true

        Task {
            do {
                try await whisperService.startStreamingTranscription()

                // Wait for isRecording to become true (with timeout)
                let startTime = Date()
                let maxWait: TimeInterval = 3.0  // Max 3 seconds to start

                while !whisperService.isRecording {
                    if Date().timeIntervalSince(startTime) > maxWait {
                        print("[FloatingInputCard] Timeout waiting for recording to start")
                        throw WhisperKitError.transcriptionFailed("Recording failed to start")
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
                    isPauseDetectionActive = false
                }
            }
        }
    }

    private func cancelVoiceInput() {
        print("[FloatingInputCard] User cancelled voice input - disabling continuous mode")
        isPauseDetectionActive = false
        isContinuousVoiceMode = false  // Exit continuous mode on cancel
        Task {
            _ = await whisperService.stopStreamingTranscription()
            whisperService.clearTranscription()
        }
        voiceInputState = .idle
        showVoiceOverlay = false
    }

    // MARK: - Pause Detection

    private func checkForPause() {
        // Only check when detection is active and recording
        guard isPauseDetectionActive,
            case .recording = voiceInputState,
            voiceConfig.pauseDuration > 0
        else { return }

        // Need some transcription before we can auto-send
        let hasContent = !whisperService.currentTranscription.isEmpty || !whisperService.confirmedTranscription.isEmpty
        guard hasContent else { return }

        // Check if silence duration exceeds pause threshold
        let silenceDuration = Date().timeIntervalSince(lastSpeechTime)

        if silenceDuration >= voiceConfig.pauseDuration {
            // Pause detected - trigger countdown
            isPauseDetectionActive = false
            voiceInputState = .paused(remaining: voiceConfig.confirmationDelay)
            print("[FloatingInputCard] Pause detected after \(silenceDuration)s silence, triggering countdown")
        }
    }

    private func checkForSilenceTimeout() {
        // Only check when overlay is showing and it's user's turn (not streaming)
        guard showVoiceOverlay,
            !isStreaming,
            voiceConfig.silenceTimeoutSeconds > 0,
            case .recording = voiceInputState,
            whisperService.isRecording
        else {
            // Reset display when conditions aren't met
            if displayedSilenceTimeoutDuration != 0 {
                displayedSilenceTimeoutDuration = 0
            }
            return
        }

        // Reset timer when there's voice activity
        if whisperService.audioLevel > speechThreshold || !whisperService.currentTranscription.isEmpty
            || !whisperService.confirmedTranscription.isEmpty
        {
            lastVoiceActivityTime = Date()
        }

        // Calculate and update displayed silence duration
        let silenceDuration = Date().timeIntervalSince(lastVoiceActivityTime)
        displayedSilenceTimeoutDuration = silenceDuration

        // Check if timeout exceeded
        if silenceDuration >= voiceConfig.silenceTimeoutSeconds {
            let hasContent =
                !whisperService.currentTranscription.isEmpty || !whisperService.confirmedTranscription.isEmpty

            if hasContent {
                print("[FloatingInputCard] Silence timeout with content - triggering auto-send")
                isPauseDetectionActive = false
                voiceInputState = .paused(remaining: voiceConfig.confirmationDelay)
            } else {
                print("[FloatingInputCard] Silence timeout without content - closing voice input")
                stopVoiceInputFromTimeout()
            }
        }
    }

    private func stopVoiceInputFromTimeout() {
        isPauseDetectionActive = false
        Task {
            _ = await whisperService.stopStreamingTranscription(force: false)
            whisperService.clearTranscription()
        }
        voiceInputState = .idle
        showVoiceOverlay = false
    }

    private func sendVoiceMessage(_ message: String) {
        print("[FloatingInputCard] Sending voice message. Continuous mode: \(isContinuousVoiceMode)")
        Task {
            _ = await whisperService.stopStreamingTranscription()
            // Clear transcription so next voice input starts fresh
            whisperService.clearTranscription()
            await MainActor.run {
                voiceInputState = .idle
                showVoiceOverlay = false
                text = message
                onSend()
            }
        }
    }

    private func transferToTextInput() {
        print("[FloatingInputCard] Transferring to text input - disabling continuous mode")
        // Transfer transcription to text input and close overlay
        let transcribedText = [
            whisperService.confirmedTranscription,
            whisperService.currentTranscription,
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")

        Task {
            _ = await whisperService.stopStreamingTranscription()
            whisperService.clearTranscription()
        }

        voiceInputState = .idle
        showVoiceOverlay = false
        isContinuousVoiceMode = false  // Exit continuous mode when switching to text

        // Set the text input
        localText = transcribedText
        text = transcribedText
        isFocused = true
    }

    private func syncAndSend() {
        guard canSend else { return }
        text = localText
        onSend()
        // Clear local text after send
        localText = ""
    }

    // MARK: - Pending Images Preview (Inline)

    private var inlinePendingImagesPreview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(pendingImages.enumerated()), id: \.offset) { index, imageData in
                    CachedImageThumbnail(
                        imageData: imageData,
                        size: 40,
                        onRemove: {
                            withAnimation(theme.springAnimation()) {
                                _ = pendingImages.remove(at: index)
                            }
                        }
                    )
                }
            }
        }
        .frame(height: 48)
    }

    // MARK: - Selector Row (Model + Tools)

    private var selectorRow: some View {
        HStack(spacing: 10) {
            // Model selector (when multiple models available)
            if modelOptions.count > 1 {
                modelSelectorChip
            }

            // Capabilities selector (tools + skills combined)
            if !toolRegistry.listTools().isEmpty || !skillManager.skills.isEmpty {
                capabilitiesSelectorChip
            }

            // Context size indicator
            if !hideContextIndicator && (displayContextTokens > 0 || (cumulativeTokens ?? 0) > 0) {
                contextIndicatorChip
            }

            Spacer()

            // Keyboard hint
            keyboardHint
        }
    }

    // MARK: - Context Indicator

    @ViewBuilder
    private var contextIndicatorChip: some View {
        // In agent mode, show cumulative usage; in chat mode, show context estimate
        if let cumulative = cumulativeTokens, agentInputState != nil {
            // Agent mode: show cumulative tokens used
            HStack(spacing: 4) {
                Text("\(formatTokenCount(cumulative))")
                    .font(.system(size: CGFloat(theme.captionSize) - 1, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.accentColor)

                Text("used")
                    .font(.system(size: CGFloat(theme.captionSize) - 1, weight: .regular))
                    .foregroundColor(theme.tertiaryText.opacity(0.7))
            }
            .help("Total tokens consumed: \(cumulative) (input + output across all API calls)")
        } else {
            // Chat mode: show context estimate
            HStack(spacing: 4) {
                if let maxCtx = maxContextTokens {
                    Text("~\(formatTokenCount(displayContextTokens)) / \(formatTokenCount(maxCtx))")
                        .font(.system(size: CGFloat(theme.captionSize) - 1, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                } else {
                    Text("~\(formatTokenCount(displayContextTokens))")
                        .font(.system(size: CGFloat(theme.captionSize) - 1, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                }

                Text("tokens")
                    .font(.system(size: CGFloat(theme.captionSize) - 1, weight: .regular))
                    .foregroundColor(theme.tertiaryText.opacity(0.7))
            }
            .help(
                maxContextTokens != nil
                    ? "Estimated context: ~\(displayContextTokens) / \(maxContextTokens!) tokens"
                    : "Estimated context: ~\(displayContextTokens) tokens (messages + tools + input)"
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

    private var selectedModelOption: ModelOption? {
        guard let id = selectedModel else { return nil }
        return modelOptions.first { $0.id == id }
    }

    private var modelSelectorChip: some View {
        Button(action: { showModelPicker.toggle() }) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)

                // Model name with metadata badges
                if let option = selectedModelOption {
                    HStack(spacing: 4) {
                        Text(option.displayName)
                            .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)

                        // Show VLM indicator
                        if option.isVLM {
                            Image(systemName: "eye")
                                .font(theme.font(size: CGFloat(theme.captionSize) - 3))
                                .foregroundColor(theme.accentColor)
                        }

                        // Show parameter count badge
                        if let params = option.parameterCount {
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
                    Text("Select Model")
                        .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }

                Image(systemName: "chevron.up.chevron.down")
                    .font(theme.font(size: CGFloat(theme.captionSize) - 3, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(theme.secondaryBackground.opacity(0.8))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(theme.primaryBorder.opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showModelPicker, arrowEdge: .top) {
            ModelPickerView(
                options: cachedModelOptions,
                selectedModel: $selectedModel,
                personaId: personaId,
                onDismiss: dismissModelPicker
            )
        }
        .onChange(of: showModelPicker) { _, isShowing in
            if isShowing {
                // Snapshot options when popover opens to prevent refresh during streaming
                cachedModelOptions = modelOptions
            }
        }
    }

    // MARK: - Capabilities Selector (Tools + Skills)

    private var effectivePersonaId: UUID {
        personaId ?? Persona.defaultId
    }

    private var toolOverrides: [String: Bool]? {
        personaManager.effectiveToolOverrides(for: effectivePersonaId)
    }

    private var skillOverrides: [String: Bool]? {
        personaManager.effectiveSkillOverrides(for: effectivePersonaId)
    }

    /// Count of enabled tools (with persona overrides applied, excluding agent tools)
    private var enabledToolCount: Int {
        toolRegistry.listUserTools(withOverrides: toolOverrides)
            .filter { $0.enabled }
            .count
    }

    /// Count of enabled skills (with persona overrides applied)
    private var enabledSkillCount: Int {
        skillManager.skills.filter { skill in
            if let overrides = skillOverrides, let value = overrides[skill.name] {
                return value
            }
            return skill.enabled
        }.count
    }

    /// Total enabled capabilities count
    private var totalEnabledCapabilities: Int {
        enabledToolCount + enabledSkillCount
    }

    /// Human-readable description of enabled capabilities
    private var capabilitiesDescription: String {
        let toolText = enabledToolCount == 1 ? "1 tool" : "\(enabledToolCount) tools"
        let skillText = enabledSkillCount == 1 ? "1 skill" : "\(enabledSkillCount) skills"

        if enabledToolCount > 0 && enabledSkillCount > 0 {
            return "\(toolText), \(skillText)"
        } else if enabledToolCount > 0 {
            return toolText
        } else if enabledSkillCount > 0 {
            return skillText
        } else {
            return "Abilities"
        }
    }

    private var capabilitiesSelectorChip: some View {
        Button(action: { showCapabilitiesPicker.toggle() }) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(theme.font(size: CGFloat(theme.captionSize) - 2))
                    .foregroundColor(theme.tertiaryText)

                Text(capabilitiesDescription)
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                    .foregroundColor(theme.secondaryText)

                Image(systemName: "chevron.up.chevron.down")
                    .font(theme.font(size: CGFloat(theme.captionSize) - 3, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(theme.secondaryBackground.opacity(0.8))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(theme.primaryBorder.opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showCapabilitiesPicker, arrowEdge: .top) {
            CapabilitiesSelectorView(personaId: effectivePersonaId)
        }
    }

    private var keyboardHint: some View {
        HStack(spacing: 4) {
            Text("⏎")
                .font(theme.font(size: CGFloat(theme.captionSize) - 2, weight: .medium))
            Text("to send")
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
            // Inline pending images (compact, inside the card)
            if !pendingImages.isEmpty {
                inlinePendingImagesPreview
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }

            // Clean text input area (no overlapping buttons)
            textInputArea
                .padding(.horizontal, 12)
                .padding(.top, pendingImages.isEmpty ? 10 : 6)
                .padding(.bottom, 6)

            // Bottom button bar with all action buttons
            buttonBar
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(effectiveBorderStyle, lineWidth: isDragOver ? 2 : (isFocused ? 1.5 : 0.5))
        )
        .shadow(
            color: shadowColor,
            radius: isFocused ? 24 : 12,
            x: 0,
            y: isFocused ? 8 : 4
        )
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .animation(.easeOut(duration: 0.1), value: isDragOver)
    }

    // MARK: - Voice Input Button

    private var voiceInputButton: some View {
        Button(action: { startVoiceInput() }) {
            Image(systemName: "mic.fill")
                .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                .foregroundColor(theme.secondaryText)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(theme.tertiaryBackground.opacity(0.8))
                )
                .overlay(
                    Circle()
                        .stroke(theme.primaryBorder.opacity(0.2), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help("Voice input (speak to type)")
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .animation(.easeOut(duration: 0.1), value: isVoiceAvailable)
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Select images to attach"

        if panel.runModal() == .OK {
            for url in panel.urls {
                if let data = try? Data(contentsOf: url), data.count <= maxImageSize {
                    // Convert to PNG for consistency
                    if let nsImage = NSImage(data: data),
                        let pngData = nsImage.pngData()
                    {
                        withAnimation(theme.springAnimation()) {
                            pendingImages.append(pngData)
                        }
                    }
                }
            }
        }
    }

    private func handleImageDrop(_ providers: [NSItemProvider]) -> Bool {
        guard supportsImages else { return false }

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                    guard let data = data, error == nil, data.count <= maxImageSize else { return }
                    DispatchQueue.main.async {
                        if let nsImage = NSImage(data: data),
                            let pngData = nsImage.pngData()
                        {
                            withAnimation(theme.springAnimation()) {
                                pendingImages.append(pngData)
                            }
                        }
                    }
                }
            }
        }
        return true
    }

    /// Dynamic placeholder text based on input state
    private var placeholderText: String {
        // Agent mode placeholders
        if let state = agentInputState {
            switch state {
            case .noTask:
                return "What do you want done?"
            case .executing:
                return pendingQueuedMessage != nil
                    ? "Message queued..."
                    : "Add context while it runs..."
            case .idle:
                return "What's next?"
            }
        }
        // Chat mode placeholder
        return supportsImages ? "Message or paste image..." : "Message..."
    }

    private var textInputArea: some View {
        EditableTextView(
            text: $localText,
            fontSize: inputFontSize,
            textColor: theme.primaryText,
            cursorColor: theme.cursorColor,
            isFocused: $isFocused,
            maxHeight: maxHeight,
            onCommit: {
                syncAndSend()
            }
        )
        .frame(maxHeight: maxHeight)
        .overlay(alignment: .topLeading) {
            // Placeholder - uses theme body size
            if showPlaceholder {
                Text(placeholderText)
                    .font(.system(size: inputFontSize))
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
                        pendingImages.append(imageData)
                    }
                }
            )
        )
    }

    // MARK: - Button Bar

    private var buttonBar: some View {
        HStack(spacing: 8) {
            // Left side buttons
            HStack(spacing: 6) {
                // Media attachment button (when model supports images)
                if supportsImages {
                    mediaButton
                }

                // Voice input button (when available and not streaming)
                if isVoiceAvailable && !isStreaming {
                    voiceInputButton
                }
            }

            Spacer()

            // Queued message indicator (agent mode only)
            if pendingQueuedMessage != nil {
                queuedIndicator
            }

            // Right side - Stop/Resume/End button + Send button
            HStack(spacing: 8) {
                if isStreaming {
                    stopButton
                } else if canResume {
                    resumeButton
                    endTaskButton
                } else if agentInputState == .idle {
                    endTaskButton
                }
                sendButton
            }
        }
    }

    // MARK: - Action Buttons

    private var queuedIndicator: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.system(size: 10))
            Text("Queued")
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(theme.accentColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.accentColor.opacity(0.1))
        .clipShape(Capsule())
    }

    private var mediaButton: some View {
        Button(action: pickImage) {
            Image(systemName: "photo.badge.plus")
                .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                .foregroundColor(theme.secondaryText)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(theme.tertiaryBackground.opacity(0.8))
                )
                .overlay(
                    Circle()
                        .stroke(theme.primaryBorder.opacity(0.2), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help("Attach image (or paste/drag)")
        .scaleEffect(1.0)
        .animation(.easeOut(duration: 0.1), value: pendingImages.count)
    }

    private var stopButton: some View {
        Button(action: onStop) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white)
                    .frame(width: 8, height: 8)
                Text("Stop")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.red.opacity(0.9))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    private var resumeButton: some View {
        Button(action: { onResume?() }) {
            HStack(spacing: 4) {
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .bold))
                Text("Resume")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                LinearGradient(
                    colors: [theme.accentColor, theme.accentColor.opacity(0.85)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    private var endTaskButton: some View {
        Button(action: { onEndTask?() }) {
            HStack(spacing: 4) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                Text("End")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(theme.secondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.tertiaryBackground.opacity(0.8))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(theme.primaryBorder.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    private var sendButton: some View {
        Button(action: syncAndSend) {
            Image(systemName: "arrow.up")
                .font(theme.font(size: CGFloat(theme.bodySize), weight: .semibold))
                .foregroundColor(theme.primaryBackground)
                .frame(width: 32, height: 32)
                .background(
                    LinearGradient(
                        colors: [theme.accentColor, theme.accentColor.opacity(0.85)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipShape(Circle())
                .shadow(
                    color: theme.accentColor.opacity(0.4),
                    radius: 6,
                    x: 0,
                    y: 2
                )
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .opacity(canSend ? 1 : 0.5)
        .animation(.easeOut(duration: 0.1), value: canSend)
    }

    // MARK: - Card Styling

    private var cardBackground: some View {
        ZStack {
            // Base blur
            if #available(macOS 13.0, *) {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
            } else {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(theme.primaryBackground.opacity(0.95))
            }

            // Tint overlay - stronger in light mode for contrast
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(theme.primaryBackground.opacity(theme.isDark ? 0.6 : 0.85))
        }
    }

    private var effectiveBorderStyle: AnyShapeStyle {
        if isDragOver && supportsImages {
            return AnyShapeStyle(theme.accentColor)
        }
        return borderGradient
    }

    private var borderGradient: AnyShapeStyle {
        if isFocused {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [theme.accentColor.opacity(0.6), theme.accentColor.opacity(0.2)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        } else {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [theme.glassEdgeLight, theme.glassEdgeLight.opacity(0.3)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }

    private var shadowColor: Color {
        isFocused ? theme.accentColor.opacity(0.15) : Color.black.opacity(0.15)
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
                    .font(.system(size: 16))
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

// MARK: - Preview

#if DEBUG
    struct FloatingInputCard_Previews: PreviewProvider {
        struct PreviewWrapper: View {
            @State private var text = ""
            @State private var model: String? = "foundation"
            @State private var images: [Data] = []
            @State private var isContinuousVoiceMode: Bool = false
            @State private var voiceInputState: VoiceInputState = .idle
            @State private var showVoiceOverlay: Bool = false

            var body: some View {
                VStack {
                    Spacer()
                    FloatingInputCard(
                        text: $text,
                        selectedModel: $model,
                        pendingImages: $images,
                        isContinuousVoiceMode: $isContinuousVoiceMode,
                        voiceInputState: $voiceInputState,
                        showVoiceOverlay: $showVoiceOverlay,
                        modelOptions: [
                            .foundation(),
                            ModelOption(
                                id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
                                displayName: "Llama 3.2 3B Instruct 4bit",
                                source: .local,
                                parameterCount: "3B",
                                quantization: "4-bit",
                                isVLM: false
                            ),
                        ],
                        isStreaming: false,
                        supportsImages: true,
                        estimatedContextTokens: 2450,
                        onSend: {},
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
