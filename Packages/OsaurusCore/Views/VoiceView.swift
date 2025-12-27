//
//  VoiceView.swift
//  osaurus
//
//  Main Voice management view with sub-tabs for testing and model management.
//

import SwiftUI

// MARK: - Voice Tab Enum

enum VoiceTab: String, CaseIterable, AnimatedTabItem {
    case main = "Voice"
    case models = "Models"

    var title: String { rawValue }
}

// MARK: - Voice View

struct VoiceView: View {
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var whisperService = WhisperKitService.shared
    @StateObject private var modelManager = WhisperModelManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var selectedTab: VoiceTab = .main
    @State private var hasAppeared = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            // Content based on tab
            Group {
                switch selectedTab {
                case .main:
                    VoiceMainTab()
                case .models:
                    VoiceModelsTab()
                }
            }
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
    }

    // MARK: - Header View

    private var headerView: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Voice")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(theme.primaryText)

                    Text("\(modelManager.downloadedModelsCount) models • \(modelManager.totalDownloadedSizeString)")
                        .font(.system(size: 14))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()

                // Status indicator
                if whisperService.isModelLoaded {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(theme.successColor)
                            .frame(width: 8, height: 8)
                        Text("Ready")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.successColor)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(theme.successColor.opacity(0.1))
                    )
                }
            }

            // Tab selector
            HStack {
                AnimatedTabSelector(
                    selection: $selectedTab,
                    counts: [
                        .models: modelManager.downloadedModelsCount
                    ]
                )

                Spacer()
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .background(theme.secondaryBackground)
    }
}

// MARK: - Voice Main Tab

private struct VoiceMainTab: View {
    @Environment(\.theme) private var theme
    @StateObject private var whisperService = WhisperKitService.shared
    @StateObject private var modelManager = WhisperModelManager.shared
    @StateObject private var audioInputManager = AudioInputManager.shared

    @State private var transcriptionText: String = ""
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Microphone Permission Card
                microphonePermissionCard

                // Model Selection Card
                modelSelectionCard

                // Input Device Selection Card
                inputDeviceCard

                // Recording Test Card
                recordingTestCard

                Spacer()
            }
            .padding(24)
            .frame(maxWidth: 700)
        }
    }

    // MARK: - Microphone Permission Card

    private var microphonePermissionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            whisperService.microphonePermissionGranted
                                ? theme.successColor.opacity(0.15)
                                : theme.warningColor.opacity(0.15)
                        )
                    Image(systemName: whisperService.microphonePermissionGranted ? "mic.fill" : "mic.slash.fill")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(
                            whisperService.microphonePermissionGranted
                                ? theme.successColor
                                : theme.warningColor
                        )
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Microphone Access")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(theme.primaryText)

                        if whisperService.microphonePermissionGranted {
                            Text("Granted")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(theme.successColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(theme.successColor.opacity(0.1)))
                        }
                    }

                    Text(
                        whisperService.microphonePermissionGranted
                            ? "Voice input is ready to use"
                            : "Required for voice transcription"
                    )
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                }

                Spacer()

                if !whisperService.microphonePermissionGranted {
                    Button(action: requestMicrophonePermission) {
                        Text("Grant Access")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.accentColor)
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    // MARK: - Model Selection Card

    private var modelSelectionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(theme.accentColor.opacity(0.15))
                    Image(systemName: "waveform")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Whisper Model")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    if let model = modelManager.selectedModel {
                        Text(model.name)
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                    } else {
                        Text("No model selected")
                            .font(.system(size: 12))
                            .foregroundColor(theme.warningColor)
                    }
                }

                Spacer()

                if modelManager.downloadedModelsCount == 0 {
                    Button(action: { /* Navigate to models tab handled by parent */  }) {
                        Text("Download Model")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.accentColor)
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                } else if whisperService.isModelLoaded {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(theme.successColor)
                            .frame(width: 6, height: 6)
                        Text("Loaded")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.successColor)
                    }
                } else if whisperService.isLoadingModel {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Loading...")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                    }
                } else {
                    Button(action: loadModel) {
                        Text("Load Model")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.accentColor)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(theme.accentColor, lineWidth: 1)
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }

            if let error = errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(theme.errorColor)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(theme.errorColor)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.errorColor.opacity(0.1))
                )
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    // MARK: - Input Device Card

    private var inputDeviceCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(theme.accentColor.opacity(0.15))
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Audio Input")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Text(
                        audioInputManager.selectedDevice?.name ?? "System Default"
                    )
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                }

                Spacer()

                // Refresh button
                Button(action: { audioInputManager.refreshDevices() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.tertiaryBackground)
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .help("Refresh available devices")
            }

            // Device picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Select Input Device")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                AudioInputDevicePicker(
                    selection: Binding(
                        get: { audioInputManager.selectedDeviceId },
                        set: { audioInputManager.selectDevice($0) }
                    ),
                    devices: audioInputManager.availableDevices
                )
            }

            if audioInputManager.availableDevices.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundColor(theme.warningColor)
                    Text("No audio input devices found. Check your system preferences.")
                        .font(.system(size: 11))
                        .foregroundColor(theme.warningColor)
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    // MARK: - Recording Test Card

    private var recordingTestCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Real-time Transcription")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Spacer()

                if whisperService.isRecording {
                    // Live recording indicator
                    HStack(spacing: 6) {
                        Circle()
                            .fill(theme.errorColor)
                            .frame(width: 8, height: 8)
                            .modifier(PulseAnimation())
                        Text("LIVE")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(theme.errorColor)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(theme.errorColor.opacity(0.1))
                    )
                }
            }

            Text("Speak and see your words transcribed in real-time")
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)

            // Audio level visualization
            if whisperService.isRecording {
                AudioLevelView(level: whisperService.audioLevel)
                    .frame(height: 40)
            }

            // Live transcription display
            VStack(alignment: .leading, spacing: 8) {
                if whisperService.isRecording || !whisperService.currentTranscription.isEmpty {
                    Text(
                        whisperService.currentTranscription.isEmpty
                            ? "Listening..." : whisperService.currentTranscription
                    )
                    .font(.system(size: 15))
                    .foregroundColor(
                        whisperService.currentTranscription.isEmpty ? theme.tertiaryText : theme.primaryText
                    )
                    .italic(whisperService.currentTranscription.isEmpty)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(theme.inputBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(
                                        whisperService.isRecording ? theme.accentColor.opacity(0.5) : theme.inputBorder,
                                        lineWidth: whisperService.isRecording ? 2 : 1
                                    )
                            )
                    )
                    .animation(.easeOut(duration: 0.2), value: whisperService.currentTranscription)
                }
            }

            HStack(spacing: 16) {
                // Record button
                Button(action: toggleRecording) {
                    HStack(spacing: 8) {
                        Image(systemName: whisperService.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 16, weight: .medium))
                        Text(whisperService.isRecording ? "Stop" : "Start Recording")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(whisperService.isRecording ? theme.errorColor : theme.accentColor)
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(!whisperService.microphonePermissionGranted || !whisperService.isModelLoaded)
                .opacity(
                    (!whisperService.microphonePermissionGranted || !whisperService.isModelLoaded)
                        ? 0.5 : 1
                )

                if !whisperService.currentTranscription.isEmpty && !whisperService.isRecording {
                    Button(action: {
                        whisperService.clearTranscription()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                            Text("Clear")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.tertiaryBackground)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                Spacer()
            }

            if !whisperService.isModelLoaded && modelManager.downloadedModelsCount > 0 {
                Text("Load a model to enable voice input")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            } else if modelManager.downloadedModelsCount == 0 {
                Text("Download a Whisper model from the Models tab to get started")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    // MARK: - Actions

    private func requestMicrophonePermission() {
        Task {
            _ = await whisperService.requestMicrophonePermission()
        }
    }

    private func loadModel() {
        guard let model = modelManager.selectedModel else {
            print("[VoiceView] No model selected, cannot load")
            errorMessage = "No model selected. Please select a model from the Models tab."
            return
        }
        print("[VoiceView] Loading model: \(model.id)")
        errorMessage = nil
        Task {
            do {
                try await whisperService.loadModel(model.id)
                print("[VoiceView] Model loaded successfully")
            } catch {
                print("[VoiceView] Failed to load model: \(error)")
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func toggleRecording() {
        if whisperService.isRecording {
            // Stop streaming transcription
            Task {
                let finalText = await whisperService.stopStreamingTranscription()
                await MainActor.run {
                    transcriptionText = finalText
                }
            }
        } else {
            // Start streaming transcription
            transcriptionText = ""
            errorMessage = nil
            Task {
                do {
                    try await whisperService.startStreamingTranscription()
                } catch {
                    await MainActor.run {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }
}

// MARK: - Audio Level View

private struct AudioLevelView: View {
    let level: Float
    @Environment(\.theme) private var theme

    private let barCount = 20

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0 ..< barCount, id: \.self) { index in
                let threshold = Float(index) / Float(barCount)
                let isActive = level > threshold

                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor(for: index, isActive: isActive))
                    .frame(width: 8)
                    .scaleEffect(y: isActive ? 1.0 : 0.3, anchor: .bottom)
                    .animation(.spring(response: 0.15, dampingFraction: 0.6), value: isActive)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.inputBackground)
        )
    }

    private func barColor(for index: Int, isActive: Bool) -> Color {
        if !isActive {
            return theme.tertiaryBackground
        }
        let ratio = Float(index) / Float(barCount)
        if ratio < 0.5 {
            return theme.successColor
        } else if ratio < 0.8 {
            return theme.warningColor
        } else {
            return theme.errorColor
        }
    }
}

// MARK: - Audio Input Device Picker

private struct AudioInputDevicePicker: View {
    @Environment(\.theme) private var theme
    @Binding var selection: String?
    let devices: [AudioInputDevice]

    @State private var isHovered = false

    private var displayName: String {
        if let selectedId = selection,
            let device = devices.first(where: { $0.id == selectedId })
        {
            return device.name
        }
        return "System Default"
    }

    var body: some View {
        Menu {
            // System Default option
            Button(action: { selection = nil }) {
                HStack {
                    Text("System Default")
                    if selection == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            // Available devices
            ForEach(devices) { device in
                Button(action: { selection = device.id }) {
                    HStack {
                        Text(device.name)
                        if device.isDefault {
                            Text("(Default)")
                                .foregroundColor(.secondary)
                        }
                        if selection == device.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.accentColor)

                Text(displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Spacer()

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                isHovered
                                    ? theme.accentColor.opacity(0.5)
                                    : theme.inputBorder,
                                lineWidth: isHovered ? 1.5 : 1
                            )
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Pulse Animation

private struct PulseAnimation: ViewModifier {
    @State private var isAnimating = false

    func body(content: Content) -> some View {
        content
            .opacity(isAnimating ? 0.4 : 1.0)
            .animation(
                Animation.easeInOut(duration: 0.8)
                    .repeatForever(autoreverses: true),
                value: isAnimating
            )
            .onAppear {
                isAnimating = true
            }
    }
}

// MARK: - Voice Models Tab

private struct VoiceModelsTab: View {
    @Environment(\.theme) private var theme
    @StateObject private var modelManager = WhisperModelManager.shared

    @State private var searchText: String = ""

    private var filteredModels: [WhisperModel] {
        if searchText.isEmpty {
            return modelManager.availableModels
        }
        let query = searchText.lowercased()
        return modelManager.availableModels.filter {
            $0.name.lowercased().contains(query) || $0.description.lowercased().contains(query)
        }
    }

    private var recommendedModels: [WhisperModel] {
        filteredModels.filter { $0.isRecommended }
    }

    private var otherModels: [WhisperModel] {
        filteredModels.filter { !$0.isRecommended }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Search
                SearchField(text: $searchText, placeholder: "Search models")
                    .padding(.horizontal, 24)

                // Recommended section
                if !recommendedModels.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("RECOMMENDED")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(theme.secondaryText)
                            .tracking(0.5)
                            .padding(.horizontal, 24)

                        VStack(spacing: 12) {
                            ForEach(recommendedModels) { model in
                                WhisperModelRow(model: model)
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                }

                // Other models section
                if !otherModels.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("ALL MODELS")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(theme.secondaryText)
                            .tracking(0.5)
                            .padding(.horizontal, 24)

                        VStack(spacing: 12) {
                            ForEach(otherModels) { model in
                                WhisperModelRow(model: model)
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                }

                Spacer(minLength: 24)
            }
            .padding(.top, 16)
        }
    }
}

// MARK: - Whisper Model Row

private struct WhisperModelRow: View {
    @Environment(\.theme) private var theme
    @StateObject private var modelManager = WhisperModelManager.shared

    let model: WhisperModel

    @State private var isHovering = false

    private var downloadState: WhisperDownloadState {
        modelManager.effectiveDownloadState(for: model)
    }

    private var isSelected: Bool {
        modelManager.selectedModelId == model.id
    }

    var body: some View {
        HStack(spacing: 16) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(iconBackground)
                Image(systemName: iconName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(iconColor)
            }
            .frame(width: 48, height: 48)

            // Info
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    if model.isEnglishOnly {
                        Text("EN")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(theme.secondaryText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.tertiaryBackground))
                    }

                    if model.isQuantized {
                        Text("4-bit")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(theme.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.accentColor.opacity(0.1)))
                    }

                    if isSelected {
                        Text("Default")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(theme.successColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.successColor.opacity(0.1)))
                    }
                }

                Text(model.description)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)

                Text(model.size)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }

            Spacer()

            // Actions
            actionButton
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(
                            isSelected ? theme.successColor.opacity(0.3) : theme.cardBorder,
                            lineWidth: 1
                        )
                )
        )
        .scaleEffect(isHovering ? 1.005 : 1)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var iconName: String {
        switch downloadState {
        case .completed: return "waveform"
        case .downloading: return "arrow.down.circle"
        case .failed: return "exclamationmark.triangle"
        default: return "waveform.circle"
        }
    }

    private var iconColor: Color {
        switch downloadState {
        case .completed: return theme.successColor
        case .downloading: return theme.accentColor
        case .failed: return theme.errorColor
        default: return theme.secondaryText
        }
    }

    private var iconBackground: Color {
        switch downloadState {
        case .completed: return theme.successColor.opacity(0.15)
        case .downloading: return theme.accentColor.opacity(0.15)
        case .failed: return theme.errorColor.opacity(0.15)
        default: return theme.tertiaryBackground
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch downloadState {
        case .notStarted, .failed:
            Button(action: { modelManager.downloadModel(model) }) {
                Text("Download")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.accentColor)
                    )
            }
            .buttonStyle(PlainButtonStyle())

        case .downloading(let progress):
            HStack(spacing: 12) {
                // Progress indicator
                ZStack {
                    Circle()
                        .stroke(theme.tertiaryBackground, lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(theme.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.3), value: progress)
                }
                .frame(width: 28, height: 28)

                Text("\(Int(progress * 100))%")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 40)

                Button(action: { modelManager.cancelDownload(model.id) }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(PlainButtonStyle())
            }

        case .completed:
            HStack(spacing: 8) {
                if !isSelected {
                    Button(action: { modelManager.setDefaultModel(model.id) }) {
                        Text("Set Default")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.accentColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(theme.accentColor, lineWidth: 1)
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                Button(action: { modelManager.deleteModel(model) }) {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundColor(theme.tertiaryText)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.tertiaryBackground)
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }
}

// MARK: - Preview

#Preview {
    VoiceView()
}
