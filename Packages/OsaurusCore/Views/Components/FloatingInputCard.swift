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
    @Binding var enabledToolOverrides: [String: Bool]
    let modelOptions: [ModelOption]
    let availableTools: [ToolRegistry.ToolEntry]
    /// Persona's tool overrides (if any). Used as base for diffing session overrides.
    let personaToolOverrides: [String: Bool]?
    let isStreaming: Bool
    let supportsImages: Bool
    /// Current estimated context token count for the session
    let estimatedContextTokens: Int
    let onSend: () -> Void
    let onStop: () -> Void
    /// Trigger to focus the input field (increment to focus)
    var focusTrigger: Int = 0
    /// Current persona ID (used for persona-specific default model)
    var personaId: UUID? = nil

    // Local state for text input to prevent parent re-renders on every keystroke
    @State private var localText: String = ""
    @State private var isFocused: Bool = false
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var isDragOver = false
    @State private var keyMonitor: Any?
    @State private var showModelPicker = false
    @State private var showToolPicker = false
    // Cache model options to prevent popover refresh during streaming
    @State private var cachedModelOptions: [ModelOption] = []
    // Cache tool list to prevent popover refresh during streaming
    @State private var cachedTools: [ToolRegistry.ToolEntry] = []

    // MARK: - Voice Input State
    @StateObject private var whisperService = WhisperKitService.shared
    @State private var voiceInputState: VoiceInputState = .idle
    @State private var showVoiceOverlay = false
    @State private var voiceConfig = WhisperConfiguration.default

    // Pause detection state
    @State private var lastSpeechTime: Date = Date()
    @State private var isPauseDetectionActive: Bool = false

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
        return (hasText || hasImages) && !isStreaming
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
        voiceConfig.enabled && voiceConfig.voiceInputEnabled && whisperService.isModelLoaded
            && whisperService.microphonePermissionGranted
    }

    /// Whether voice is in a recording/active state
    private var isVoiceActive: Bool {
        voiceInputState != .idle
    }

    var body: some View {
        VStack(spacing: 12) {
            // Model and tool selector chips (always visible)
            if (modelOptions.count > 1 || !availableTools.isEmpty || displayContextTokens > 0) && !showVoiceOverlay {
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
            // Sync initial value from binding
            localText = text
            setupKeyMonitor()
            loadVoiceConfig()
        }
        .onDisappear {
            cleanupKeyMonitor()
            // Stop any active voice recording
            if isVoiceActive {
                cancelVoiceInput()
            }
        }
        .onChange(of: text) { _, newValue in
            // Sync from binding when it changes externally (e.g., quick actions)
            if newValue != localText {
                localText = newValue
            }
        }
        .onChange(of: focusTrigger) { _, _ in
            // Small delay to ensure window is fully ready for focus
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFocused = true
            }
        }
        .onChange(of: whisperService.isRecording) { _, isRecording in
            // Sync voice state with service
            if isRecording && voiceInputState == .idle {
                voiceInputState = .recording
                lastSpeechTime = Date()
                isPauseDetectionActive = voiceConfig.pauseDuration > 0
            } else if !isRecording {
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
            // Handle state changes
            if case .recording = newState {
                // Resumed recording, restart detection
                lastSpeechTime = Date()
                isPauseDetectionActive = true
            } else {
                isPauseDetectionActive = false
            }
        }
        .onReceive(pauseDetectionPublisher) { _ in
            checkForPause()
        }
    }

    // MARK: - Voice Input Methods

    private func loadVoiceConfig() {
        voiceConfig = WhisperConfigurationStore.load()
    }

    private func startVoiceInput() {
        guard isVoiceAvailable else { return }

        voiceInputState = .recording
        showVoiceOverlay = true
        lastSpeechTime = Date()
        isPauseDetectionActive = voiceConfig.pauseDuration > 0

        Task {
            do {
                try await whisperService.startStreamingTranscription()
            } catch {
                print("[FloatingInputCard] Failed to start voice input: \(error)")
                voiceInputState = .idle
                showVoiceOverlay = false
                isPauseDetectionActive = false
            }
        }
    }

    private func cancelVoiceInput() {
        isPauseDetectionActive = false
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

    private func sendVoiceMessage(_ message: String) {
        Task {
            _ = await whisperService.stopStreamingTranscription()
        }
        voiceInputState = .idle
        showVoiceOverlay = false

        // Send the voice message
        text = message
        onSend()
    }

    private func transferToTextInput() {
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

    private func setupKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            let kVK_Return: UInt16 = 0x24
            let kVK_ANSI_KeypadEnter: UInt16 = 0x4C
            let isReturn = (event.keyCode == kVK_Return || event.keyCode == kVK_ANSI_KeypadEnter)
            if isReturn && isFocused {
                let hasShift = event.modifierFlags.contains(.shift)
                if !hasShift && canSend {
                    syncAndSend()
                    return nil  // consume the event
                }
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

            // Tool selector (when tools available)
            if !availableTools.isEmpty {
                toolSelectorChip
            }

            // Context size indicator (when there's context)
            if displayContextTokens > 0 {
                contextIndicatorChip
            }

            Spacer()

            // Keyboard hint
            keyboardHint
        }
    }

    // MARK: - Context Indicator

    private var contextIndicatorChip: some View {
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

    // MARK: - Tool Selector

    /// Count of enabled tools (with overrides applied)
    private var enabledToolCount: Int {
        availableTools.filter { tool in
            if let override = enabledToolOverrides[tool.name] {
                return override
            }
            return tool.enabled
        }.count
    }

    /// Whether any tools have been modified from global settings
    private var hasToolOverrides: Bool {
        !enabledToolOverrides.isEmpty
    }

    private var toolSelectorChip: some View {
        Button(action: { showToolPicker.toggle() }) {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(theme.font(size: CGFloat(theme.captionSize) - 2))
                    .foregroundColor(hasToolOverrides ? theme.accentColor : theme.tertiaryText)

                Text("\(enabledToolCount) tools")
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                    .foregroundColor(theme.secondaryText)

                // Show modified indicator if overrides exist
                if hasToolOverrides {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 5, height: 5)
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
                    .strokeBorder(
                        hasToolOverrides ? theme.accentColor.opacity(0.5) : theme.primaryBorder.opacity(0.5),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showToolPicker, arrowEdge: .top) {
            ToolSelectorView(
                tools: cachedTools,
                enabledOverrides: $enabledToolOverrides,
                personaToolOverrides: personaToolOverrides,
                onDismiss: { showToolPicker = false }
            )
        }
        .onChange(of: showToolPicker) { _, isShowing in
            if isShowing {
                // Snapshot tools when popover opens to prevent refresh during streaming
                cachedTools = availableTools
            }
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
        VStack(alignment: .leading, spacing: 8) {
            // Inline pending images (compact, inside the card)
            if !pendingImages.isEmpty {
                inlinePendingImagesPreview
            }

            // Input row with text, voice, and action button
            HStack(alignment: .bottom, spacing: 12) {
                textInputArea

                // Voice input button (when available)
                if isVoiceAvailable && !isStreaming {
                    voiceInputButton
                }

                actionButton
            }
        }
        .padding(12)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(effectiveBorderStyle, lineWidth: isDragOver ? 2 : (isFocused ? 1.5 : 0.5))
        )
        .overlay(alignment: .bottomLeading) {
            // Floating image attachment button (only for VLM models)
            if supportsImages {
                imageAttachButton
                    .offset(x: 10, y: -10)
            }
        }
        .shadow(
            color: shadowColor,
            radius: isFocused ? 24 : 12,
            x: 0,
            y: isFocused ? 8 : 4
        )
        .animation(theme.springAnimation(), value: isFocused)
        .animation(theme.animationQuick(), value: isDragOver)
    }

    // MARK: - Voice Input Button

    private var voiceInputButton: some View {
        Button(action: { startVoiceInput() }) {
            ZStack {
                // Microphone icon
                Image(systemName: "mic.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }
            .frame(width: 32, height: 32)
            .background(
                Circle()
                    .fill(theme.tertiaryBackground)
            )
            .overlay(
                Circle()
                    .stroke(theme.primaryBorder.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Voice input (speak to type)")
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Image Attachment Button

    private var imageAttachButton: some View {
        Button(action: pickImage) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(theme.secondaryBackground.opacity(0.8))
                        .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                )
        }
        .buttonStyle(.plain)
        .help("Attach image (or paste/drag)")
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

    private var textInputArea: some View {
        EditableTextView(
            text: $localText,
            fontSize: inputFontSize,
            textColor: theme.primaryText,
            cursorColor: theme.cursorColor,
            isFocused: $isFocused,
            maxHeight: maxHeight
        )
        .frame(minHeight: 60)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 2)
        .overlay(alignment: .topLeading) {
            // Placeholder - uses theme body size
            if showPlaceholder {
                Text(supportsImages ? "Message or paste image..." : "Message...")
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

    // MARK: - Action Button

    private var actionButton: some View {
        Button(action: isStreaming ? onStop : syncAndSend) {
            ZStack {
                // Send icon - uses theme body size
                Image(systemName: "arrow.up")
                    .font(theme.font(size: CGFloat(theme.bodySize), weight: .semibold))
                    .foregroundColor(isStreaming ? .white : theme.primaryBackground)
                    .opacity(isStreaming ? 0 : 1)
                    .scaleEffect(isStreaming ? 0.5 : 1)

                // Stop icon
                RoundedRectangle(cornerRadius: 3)
                    .fill(.white)
                    .frame(width: 10, height: 10)
                    .opacity(isStreaming ? 1 : 0)
                    .scaleEffect(isStreaming ? 1 : 0.5)
            }
            .frame(width: 32, height: 32)
            .background(buttonBackground)
            .clipShape(Circle())
            .shadow(
                color: buttonShadowColor,
                radius: 8,
                x: 0,
                y: 2
            )
        }
        .buttonStyle(.plain)
        .disabled(!canSend && !isStreaming)
        .opacity(!canSend && !isStreaming ? 0.5 : 1)
        .animation(theme.springAnimation(), value: isStreaming)
        .animation(theme.animationQuick(), value: canSend)
    }

    private var buttonBackground: some ShapeStyle {
        if isStreaming {
            return AnyShapeStyle(Color.red)
        } else {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [theme.accentColor, theme.accentColor.opacity(0.85)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    private var buttonShadowColor: Color {
        isStreaming ? Color.red.opacity(0.4) : theme.accentColor.opacity(0.4)
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
                .fill(theme.primaryBackground.opacity(colorScheme == .dark ? 0.6 : 0.85))
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
            @State private var toolOverrides: [String: Bool] = [:]

            var body: some View {
                VStack {
                    Spacer()
                    FloatingInputCard(
                        text: $text,
                        selectedModel: $model,
                        pendingImages: $images,
                        enabledToolOverrides: $toolOverrides,
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
                        availableTools: [
                            ToolRegistry.ToolEntry(
                                name: "browser_screenshot",
                                description: "Take a screenshot",
                                enabled: true,
                                parameters: nil
                            ),
                            ToolRegistry.ToolEntry(
                                name: "browser_click",
                                description: "Click an element",
                                enabled: true,
                                parameters: nil
                            ),
                        ],
                        personaToolOverrides: nil,
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
