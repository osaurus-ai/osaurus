//
//  TranscriptionModeSettingsTab.swift
//  osaurus
//
//  Settings UI for Transcription Mode.
//  Configure hotkey, pause duration, and test the transcription feature.
//

import SwiftUI

// MARK: - Transcription Mode Settings Tab

struct TranscriptionModeSettingsTab: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var speechService = SpeechService.shared
    @ObservedObject private var modelManager = SpeechModelManager.shared
    @ObservedObject private var keyboardService = KeyboardSimulationService.shared
    @ObservedObject private var transcriptionService = TranscriptionModeService.shared

    // Configuration state
    @State private var transcriptionEnabled: Bool = false
    @State private var hotkey: Hotkey?
    @State private var hasLoadedSettings = false

    private func loadSettings() {
        let config = TranscriptionConfigurationStore.load()
        transcriptionEnabled = config.transcriptionModeEnabled
        hotkey = config.hotkey
    }

    private func saveSettings() {
        let config = TranscriptionConfiguration(
            transcriptionModeEnabled: transcriptionEnabled,
            hotkey: hotkey
        )
        TranscriptionConfigurationStore.save(config)
    }

    /// Whether all requirements are met
    private var canEnableTranscription: Bool {
        keyboardService.hasAccessibilityPermission
            && speechService.microphonePermissionGranted
            && modelManager.downloadedModelsCount > 0
            && modelManager.selectedModel != nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Transcription Mode Toggle Card
                transcriptionToggleCard

                // Requirements Card (if not met)
                if !canEnableTranscription {
                    requirementsCard
                }

                // Hotkey Settings Card
                if canEnableTranscription {
                    hotkeySettingsCard
                }

                // Test Area Card
                if canEnableTranscription && transcriptionEnabled {
                    testAreaCard
                }

                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            if !hasLoadedSettings {
                loadSettings()
                hasLoadedSettings = true
            }
            // Refresh accessibility permission status
            keyboardService.checkAccessibilityPermission()
        }
        .onReceive(NotificationCenter.default.publisher(for: .transcriptionConfigurationChanged)) { _ in
            loadSettings()
        }
    }

    // MARK: - Transcription Toggle Card

    private var transcriptionToggleCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            transcriptionEnabled
                                ? theme.successColor.opacity(0.15) : theme.accentColor.opacity(0.15)
                        )
                    Image(systemName: transcriptionEnabled ? "keyboard.fill" : "keyboard")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(transcriptionEnabled ? theme.successColor : theme.accentColor)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Transcription Mode")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Text(
                        transcriptionEnabled
                            ? "Type with your voice into any text field"
                            : "Voice-to-text input for any application"
                    )
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                }

                Spacer()

                Toggle("", isOn: $transcriptionEnabled)
                    .toggleStyle(SwitchToggleStyle(tint: theme.successColor))
                    .labelsHidden()
                    .disabled(!canEnableTranscription)
                    .opacity(canEnableTranscription ? 1 : 0.5)
                    .onChange(of: transcriptionEnabled) { _, _ in
                        saveSettings()
                    }
            }

            // Info about transcription mode
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundColor(theme.accentColor)

                Text(
                    "When enabled, press the hotkey to start transcribing. Your voice will be typed directly into the focused text field in any application."
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.accentColor.opacity(0.1))
            )
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            transcriptionEnabled ? theme.successColor.opacity(0.3) : theme.cardBorder,
                            lineWidth: 1
                        )
                )
        )
    }

    // MARK: - Requirements Card

    private var requirementsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(theme.warningColor.opacity(0.15))
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(theme.warningColor)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Setup Required")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Text("Complete these steps to enable Transcription Mode")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()
            }

            VStack(spacing: 12) {
                RequirementRowView(
                    title: "Accessibility Permission",
                    description: "Required to type into other applications",
                    isComplete: keyboardService.hasAccessibilityPermission,
                    action: {
                        keyboardService.requestAccessibilityPermission()
                    }
                )

                RequirementRowView(
                    title: "Microphone Access",
                    description: "Required for voice input",
                    isComplete: speechService.microphonePermissionGranted,
                    action: {
                        Task {
                            _ = await speechService.requestMicrophonePermission()
                        }
                    }
                )

                RequirementRowView(
                    title: "Speech Model Downloaded",
                    description: "Required for transcription",
                    isComplete: modelManager.downloadedModelsCount > 0,
                    action: nil
                )

                RequirementRowView(
                    title: "Model Selected",
                    description: "Select a default model in the Models tab",
                    isComplete: modelManager.selectedModel != nil,
                    action: nil
                )
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(theme.warningColor.opacity(0.3), lineWidth: 1)
                )
        )
    }

    // MARK: - Hotkey Settings Card

    private var hotkeySettingsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(theme.accentColor.opacity(0.15))
                    Image(systemName: "command")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Activation Hotkey")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Text("Press this shortcut to start/stop transcription")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Global Hotkey")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                HotkeyRecorder(value: $hotkey)
                    .onChange(of: hotkey) { _, _ in
                        saveSettings()
                    }

                if hotkey == nil {
                    Text("Set a hotkey to enable transcription mode")
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

    // MARK: - Test Area Card

    private var testAreaCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Test Transcription")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Spacer()

                if transcriptionService.state == .transcribing {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(theme.errorColor)
                            .frame(width: 8, height: 8)
                            .modifier(PulsingIndicatorModifier())
                        Text("TRANSCRIBING")
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

            Text("Test transcription mode here. Text will be typed into the field below.")
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)

            // Test text field
            TextField("Transcribed text will appear here...", text: .constant(""))
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(theme.primaryText)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )

            // Error display
            if case .error(let message) = transcriptionService.state {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(theme.errorColor)
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundColor(theme.errorColor)
                }
            }

            // Controls
            HStack(spacing: 16) {
                Button(action: {
                    transcriptionService.toggle()
                }) {
                    HStack(spacing: 8) {
                        Image(
                            systemName: transcriptionService.state == .transcribing ? "stop.fill" : "mic.fill"
                        )
                        .font(.system(size: 14))
                        Text(transcriptionService.state == .transcribing ? "Stop" : "Start Test")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundColor(
                        transcriptionService.state == .transcribing
                            ? Color.white
                            : (theme.isDark ? theme.primaryBackground : Color.white)
                    )
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(
                                transcriptionService.state == .transcribing
                                    ? theme.errorColor : theme.accentColor
                            )
                    )
                }
                .buttonStyle(.plain)
                .disabled(!speechService.isModelLoaded || transcriptionService.state == .starting)

                if let hk = hotkey {
                    Text("or press \(hk.displayString)")
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }

                Spacer()
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
}

// MARK: - Requirement Row View

private struct RequirementRowView: View {
    @Environment(\.theme) private var theme

    let title: String
    let description: String
    let isComplete: Bool
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundColor(isComplete ? theme.successColor : theme.tertiaryText)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundColor(theme.primaryText)

                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }

            Spacer()

            if !isComplete, let action = action {
                Button(action: action) {
                    Text("Fix")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.accentColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(theme.accentColor, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isComplete ? theme.successColor.opacity(0.05) : theme.tertiaryBackground)
        )
    }
}

// MARK: - Pulsing Indicator Modifier

private struct PulsingIndicatorModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.4 : 1.0)
            .animation(
                .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear {
                isPulsing = true
            }
    }
}

// MARK: - Preview

#if DEBUG
    struct TranscriptionModeSettingsTab_Previews: PreviewProvider {
        static var previews: some View {
            TranscriptionModeSettingsTab()
                .frame(width: 700, height: 800)
                .themedBackground()
        }
    }
#endif
