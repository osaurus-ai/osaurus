//
//  VoiceView.swift
//  osaurus
//
//  Main Voice management view with sub-tabs for setup, voice input settings,
//  VAD mode configuration, and model management.
//

import SwiftUI

// MARK: - Voice Tab Enum

enum VoiceTab: String, CaseIterable, AnimatedTabItem {
    case setup = "Setup"
    case voiceInput = "Voice Input"
    case vadMode = "VAD Mode"
    case models = "Models"

    var title: String { rawValue }
}

// MARK: - Supported Languages

/// Languages supported by Whisper for transcription/translation
enum SupportedLanguage: CaseIterable {
    case english
    case spanish
    case french
    case german
    case italian
    case portuguese
    case dutch
    case russian
    case chinese
    case japanese
    case korean
    case arabic
    case hindi
    case polish
    case turkish
    case vietnamese
    case thai
    case indonesian
    case ukrainian
    case swedish

    var code: String {
        switch self {
        case .english: return "en"
        case .spanish: return "es"
        case .french: return "fr"
        case .german: return "de"
        case .italian: return "it"
        case .portuguese: return "pt"
        case .dutch: return "nl"
        case .russian: return "ru"
        case .chinese: return "zh"
        case .japanese: return "ja"
        case .korean: return "ko"
        case .arabic: return "ar"
        case .hindi: return "hi"
        case .polish: return "pl"
        case .turkish: return "tr"
        case .vietnamese: return "vi"
        case .thai: return "th"
        case .indonesian: return "id"
        case .ukrainian: return "uk"
        case .swedish: return "sv"
        }
    }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        case .dutch: return "Dutch"
        case .russian: return "Russian"
        case .chinese: return "Chinese"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .arabic: return "Arabic"
        case .hindi: return "Hindi"
        case .polish: return "Polish"
        case .turkish: return "Turkish"
        case .vietnamese: return "Vietnamese"
        case .thai: return "Thai"
        case .indonesian: return "Indonesian"
        case .ukrainian: return "Ukrainian"
        case .swedish: return "Swedish"
        }
    }
}

// MARK: - Voice View

struct VoiceView: View {
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var whisperService = WhisperKitService.shared
    @StateObject private var modelManager = WhisperModelManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var selectedTab: VoiceTab = .setup
    @State private var hasAppeared = false

    /// Whether setup is complete (permissions granted + model downloaded)
    private var isSetupComplete: Bool {
        whisperService.microphonePermissionGranted && modelManager.downloadedModelsCount > 0
            && modelManager.selectedModel != nil
    }

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
                case .setup:
                    VoiceSetupTab(onComplete: { selectedTab = .voiceInput })
                case .voiceInput:
                    VoiceInputSettingsTab()
                case .vadMode:
                    VADModeSettingsTab()
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
            // Auto-select appropriate tab based on setup state
            if isSetupComplete {
                selectedTab = .voiceInput
            } else {
                selectedTab = .setup
            }
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

                    Text(headerSubtitle)
                        .font(.system(size: 14))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()

                // Status indicator
                statusIndicator
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

    private var headerSubtitle: String {
        if !isSetupComplete {
            return "Complete setup to enable voice"
        } else if modelManager.downloadedModelsCount > 0 {
            return "\(modelManager.downloadedModelsCount) models • \(modelManager.totalDownloadedSizeString)"
        } else {
            return "Voice transcription ready"
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if whisperService.isLoadingModel {
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.6)
                Text("Loading...")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(theme.tertiaryBackground)
            )
        } else if whisperService.isModelLoaded {
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
        } else if !isSetupComplete {
            HStack(spacing: 6) {
                Circle()
                    .fill(theme.warningColor)
                    .frame(width: 8, height: 8)
                Text("Setup Required")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.warningColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(theme.warningColor.opacity(0.1))
            )
        }
    }
}

// MARK: - Voice Main Tab

private struct VoiceMainTab: View {
    @Environment(\.theme) private var theme
    @StateObject private var whisperService = WhisperKitService.shared
    @StateObject private var modelManager = WhisperModelManager.shared
    @StateObject private var audioInputManager = AudioInputManager.shared
    @StateObject private var systemAudioManager = SystemAudioCaptureManager.shared

    @State private var transcriptionText: String = ""
    @State private var errorMessage: String?
    @State private var isStartingRecording: Bool = false

    // Voice settings state
    @State private var languageHint: String = ""
    @State private var sensitivity: VoiceSensitivity = .medium
    @State private var hasLoadedSettings = false

    private func loadSettings() {
        let config = WhisperConfigurationStore.load()
        languageHint = config.languageHint ?? ""
        sensitivity = config.sensitivity
        print(
            "[VoiceView] Loaded settings - language=\(languageHint.isEmpty ? "auto" : languageHint), sensitivity=\(sensitivity)"
        )
    }

    private func saveSettings() {
        var config = WhisperConfigurationStore.load()
        config.languageHint = languageHint.isEmpty ? nil : languageHint
        config.sensitivity = sensitivity
        WhisperConfigurationStore.save(config)
        print(
            "[VoiceView] Saved settings - language=\(languageHint.isEmpty ? "auto" : languageHint), sensitivity=\(sensitivity)"
        )
    }

    /// Display name for the currently selected language
    private var selectedLanguageDisplayName: String {
        if languageHint.isEmpty {
            return "Auto-detect"
        }
        if let lang = SupportedLanguage.allCases.first(where: { $0.code == languageHint }) {
            return lang.displayName
        }
        return languageHint.uppercased()
    }

    /// Whether recording can be started
    private var canStartRecording: Bool {
        // Can record if we have mic permission and either a model is loaded or can be loaded
        guard whisperService.microphonePermissionGranted else { return false }
        guard !isStartingRecording && !whisperService.isLoadingModel else { return false }

        // Need at least one downloaded model with a default selected
        guard modelManager.downloadedModelsCount > 0 else { return false }
        guard modelManager.selectedModel != nil else { return false }

        return true
    }

    /// Text for the record button
    private var recordButtonText: String {
        if whisperService.isRecording {
            return "Stop"
        } else if isStartingRecording || whisperService.isLoadingModel {
            return "Loading..."
        } else {
            return "Start Recording"
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Microphone Permission Card
                microphonePermissionCard

                // Model Selection Card
                modelSelectionCard

                // Input Device Selection Card
                inputDeviceCard

                // Voice Settings Card
                voiceSettingsCard

                // Recording Test Card
                recordingTestCard

                Spacer()
            }
            .padding(24)
            .frame(maxWidth: 700)
        }
        .onAppear {
            if !hasLoadedSettings {
                loadSettings()
                hasLoadedSettings = true
            }
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
            // Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(theme.accentColor.opacity(0.15))
                    Image(systemName: audioInputManager.selectedInputSource.iconName)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Audio Input")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Text(inputSourceDescription)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()

                // Refresh button (only for microphone mode)
                if audioInputManager.selectedInputSource == .microphone {
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
            }

            // Input Source Picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Input Source")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                AudioInputSourcePicker(
                    selection: $audioInputManager.selectedInputSource,
                    isSystemAudioAvailable: systemAudioManager.isAvailable
                )
            }

            // Conditional content based on source type
            if audioInputManager.selectedInputSource == .microphone {
                // Microphone device picker
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
            } else {
                // System Audio content
                systemAudioContent
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

    /// Description text for the current input source
    private var inputSourceDescription: String {
        switch audioInputManager.selectedInputSource {
        case .microphone:
            return audioInputManager.selectedDevice?.name ?? "System Default"
        case .systemAudio:
            if !systemAudioManager.isAvailable {
                return "Requires macOS 12.3+"
            } else if !systemAudioManager.hasPermission {
                return "Permission required"
            } else {
                return "Computer audio"
            }
        }
    }

    /// System audio specific content (permission UI, info)
    @ViewBuilder
    private var systemAudioContent: some View {
        if !systemAudioManager.isAvailable {
            // Not available on this macOS version
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(theme.warningColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("System audio requires macOS 12.3 or later")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    Text("Your current macOS version does not support system audio capture.")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.warningColor.opacity(0.1))
            )
        } else if !systemAudioManager.hasPermission {
            // Permission needed
            HStack(spacing: 12) {
                Image(systemName: "rectangle.inset.filled.and.person.filled")
                    .font(.system(size: 20))
                    .foregroundColor(theme.warningColor)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Screen Recording Permission Required")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    Text("System audio capture requires screen recording permission in System Settings.")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button(action: {
                    systemAudioManager.requestPermission()
                }) {
                    Text("Grant Access")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.accentColor)
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.warningColor.opacity(0.1))
            )
        } else {
            // Permission granted - show info
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(theme.successColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("System audio capture ready")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    Text("Audio from apps, browsers, and other sources will be transcribed.")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.successColor.opacity(0.1))
            )
        }
    }

    // MARK: - Voice Settings Card

    private var voiceSettingsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(theme.accentColor.opacity(0.15))
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Voice Settings")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Text("Configure transcription behavior")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()
            }

            // Language Picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Speaking Language")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                Menu {
                    Button(action: {
                        languageHint = ""; saveSettings()
                    }) {
                        HStack {
                            Text("Auto-detect")
                            if languageHint.isEmpty {
                                Image(systemName: "checkmark")
                            }
                        }
                    }

                    Divider()

                    ForEach(SupportedLanguage.allCases, id: \.code) { lang in
                        Button(action: {
                            languageHint = lang.code; saveSettings()
                        }) {
                            HStack {
                                Text(lang.displayName)
                                if languageHint == lang.code {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "globe")
                            .font(.system(size: 14))
                            .foregroundColor(theme.accentColor)

                        Text(selectedLanguageDisplayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.primaryText)

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
                                    .stroke(theme.inputBorder, lineWidth: 1)
                            )
                    )
                }
                .menuStyle(.borderlessButton)
                .disabled(whisperService.isRecording)
                .opacity(whisperService.isRecording ? 0.5 : 1)

                Text("Audio will be transcribed in this language")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }

            // Sensitivity Picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Sensitivity")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                Picker("", selection: $sensitivity) {
                    ForEach(VoiceSensitivity.allCases, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(whisperService.isRecording)
                .opacity(whisperService.isRecording ? 0.5 : 1)
                .onChange(of: sensitivity) { _, _ in
                    saveSettings()
                }

                Text(whisperService.isRecording ? "Stop recording to change sensitivity" : sensitivity.description)
                    .font(.system(size: 11))
                    .foregroundColor(whisperService.isRecording ? theme.warningColor : theme.tertiaryText)
            }

            // Warning for English-only model with non-English settings
            if let warning = modelCompatibilityWarning {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(theme.warningColor)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(warning.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                        Text(warning.message)
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.warningColor.opacity(0.1))
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

    /// Warning message if model doesn't support current settings
    private var modelCompatibilityWarning: (title: String, message: String)? {
        guard let selectedModel = modelManager.selectedModel else { return nil }

        // Check if using English-only model with non-English language
        if selectedModel.isEnglishOnly {
            if !languageHint.isEmpty && languageHint != "en" {
                return (
                    title: "English-only model selected",
                    message:
                        "The model \"\(selectedModel.name)\" can only transcribe English. Select a multilingual model (without '.en') to transcribe \(selectedLanguageDisplayName)."
                )
            }
        }

        return nil
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
                        if isStartingRecording || whisperService.isLoadingModel {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: whisperService.isRecording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 16, weight: .medium))
                        }
                        Text(recordButtonText)
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
                .disabled(!canStartRecording)
                .opacity(!canStartRecording ? 0.5 : 1)

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

            if modelManager.downloadedModelsCount == 0 {
                Text("Download a Whisper model from the Models tab to get started")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            } else if modelManager.selectedModel == nil {
                Text("Select a default model from the Models tab")
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
            // Start streaming transcription (model will auto-load if needed)
            transcriptionText = ""
            errorMessage = nil
            isStartingRecording = true
            Task {
                do {
                    try await whisperService.startStreamingTranscription()
                    await MainActor.run {
                        isStartingRecording = false
                    }
                } catch {
                    await MainActor.run {
                        isStartingRecording = false
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

// MARK: - Audio Input Source Picker

private struct AudioInputSourcePicker: View {
    @Environment(\.theme) private var theme
    @Binding var selection: AudioInputSource
    let isSystemAudioAvailable: Bool

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AudioInputSource.allCases, id: \.self) { source in
                let isSelected = selection == source
                let isDisabled = source == .systemAudio && !isSystemAudioAvailable

                Button(action: {
                    if !isDisabled {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selection = source
                        }
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: source.iconName)
                            .font(.system(size: 12, weight: .medium))
                        Text(source.displayName)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(
                        isDisabled ? theme.tertiaryText : (isSelected ? .white : theme.primaryText)
                    )
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(
                                isSelected
                                    ? theme.accentColor
                                    : (isDisabled ? theme.tertiaryBackground.opacity(0.5) : theme.tertiaryBackground)
                            )
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isDisabled)
                .help(
                    isDisabled ? "Requires macOS 12.3+" : source.displayName
                )
            }

            Spacer()
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
