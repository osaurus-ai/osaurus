//
//  TranscriptionModeSettingsTab.swift
//  osaurus
//
//  Settings UI for Transcription Mode.
//  Configure hotkey, pause duration, and test the transcription feature.
//

import AppKit
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

    // Shared voice settings (drive both chat voice input and Transcription Mode)
    @State private var voiceInputEnabled: Bool = true
    @State private var transcriptionStopMode: TranscriptionStopMode = .automatic
    @State private var pauseDuration: Double = 1.5
    @State private var confirmationDelay: Double = 2.0
    @State private var silenceTimeoutSeconds: Double = 30.0

    /// Polls accessibility permission while the tab is visible, since
    /// `AXIsProcessTrusted()` won't notify us when the user grants it externally.
    @State private var permissionRefreshTimer: Timer?

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

    private func loadVoiceSettings() {
        let config = SpeechConfigurationStore.load()
        voiceInputEnabled = config.voiceInputEnabled
        transcriptionStopMode = config.transcriptionStopMode
        pauseDuration = config.pauseDuration
        confirmationDelay = config.confirmationDelay
        silenceTimeoutSeconds = config.silenceTimeoutSeconds
    }

    private func saveVoiceSettings() {
        var config = SpeechConfigurationStore.load()
        config.voiceInputEnabled = voiceInputEnabled
        config.transcriptionStopMode = transcriptionStopMode
        config.pauseDuration = pauseDuration
        config.confirmationDelay = confirmationDelay
        config.silenceTimeoutSeconds = silenceTimeoutSeconds
        SpeechConfigurationStore.save(config)

        NotificationCenter.default.post(name: .voiceConfigurationChanged, object: nil)
    }

    /// Formatted display for silence timeout
    private var silenceTimeoutFormatted: String {
        if silenceTimeoutSeconds >= 60 {
            let minutes = Int(silenceTimeoutSeconds) / 60
            let seconds = Int(silenceTimeoutSeconds) % 60
            return seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
        } else {
            return "\(Int(silenceTimeoutSeconds))s"
        }
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
                // Voice Input in Chat toggle
                voiceInputToggleCard

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

                // Shared transcription stop behavior (chat + Transcription Mode)
                transcriptionBehaviorCard

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
                loadVoiceSettings()
                hasLoadedSettings = true
            }
            // Refresh accessibility permission status and keep it in sync while visible
            keyboardService.checkAccessibilityPermission()
            startPermissionRefresh()
        }
        .onDisappear {
            stopPermissionRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // User may have just returned from System Settings after granting permission
            keyboardService.checkAccessibilityPermission()
        }
        .onReceive(NotificationCenter.default.publisher(for: .transcriptionConfigurationChanged)) { _ in
            loadSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .voiceConfigurationChanged)) { _ in
            loadVoiceSettings()
        }
    }

    // MARK: - Permission Refresh

    private func startPermissionRefresh() {
        stopPermissionRefresh()
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in
                keyboardService.checkAccessibilityPermission()
            }
        }
        permissionRefreshTimer = timer
    }

    private func stopPermissionRefresh() {
        permissionRefreshTimer?.invalidate()
        permissionRefreshTimer = nil
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
                    Text("Transcription Mode", bundle: .module)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Text(
                        transcriptionEnabled
                            ? L("Type with your voice into any text field")
                            : L("Voice-to-text input for any application")
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
                    "When enabled, press the hotkey to start transcribing. Your voice will be typed directly into the focused text field in any application.",
                    bundle: .module
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
                    Text("Setup Required", bundle: .module)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Text("Complete these steps to enable Transcription Mode", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()
            }

            VStack(spacing: 12) {
                RequirementRowView(
                    title: L("Accessibility Permission"),
                    description: L("Required to type into other applications"),
                    isComplete: keyboardService.hasAccessibilityPermission,
                    action: {
                        keyboardService.requestAccessibilityPermission()
                    }
                )

                RequirementRowView(
                    title: L("Microphone Access"),
                    description: L("Required for voice input"),
                    isComplete: speechService.microphonePermissionGranted,
                    action: {
                        Task {
                            _ = await speechService.requestMicrophonePermission()
                        }
                    }
                )

                RequirementRowView(
                    title: L("Speech Model Downloaded"),
                    description: L("Required for transcription"),
                    isComplete: modelManager.downloadedModelsCount > 0,
                    action: nil
                )

                RequirementRowView(
                    title: L("Model Selected"),
                    description: L("Select a default model in the Models tab"),
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
                    Text("Activation Hotkey", bundle: .module)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Text("Press this shortcut to start/stop transcription", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Global Hotkey", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                HotkeyRecorder(value: $hotkey)
                    .onChange(of: hotkey) { _, _ in
                        saveSettings()
                    }

                if hotkey == nil {
                    Text("Set a hotkey to enable transcription mode", bundle: .module)
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
                Text("Test Transcription", bundle: .module)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Spacer()

                if transcriptionService.state == .transcribing {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(theme.errorColor)
                            .frame(width: 8, height: 8)
                            .modifier(PulsingIndicatorModifier())
                        Text("TRANSCRIBING", bundle: .module)
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

            Text("Test transcription mode here. Text will be typed into the field below.", bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)

            // Test text field
            TextField(text: .constant(""), prompt: Text("Transcribed text will appear here...", bundle: .module)) {
                Text("Transcribed text will appear here...", bundle: .module)
            }
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
                        Text(transcriptionService.state == .transcribing ? L("Stop") : L("Start Test"))
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
                    Text("or press \(hk.displayString)", bundle: .module)
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

    // MARK: - Voice Input Toggle Card

    private var voiceInputToggleCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            voiceInputEnabled
                                ? theme.successColor.opacity(0.15) : theme.accentColor.opacity(0.15)
                        )
                    Image(systemName: voiceInputEnabled ? "mic.fill" : "mic")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(voiceInputEnabled ? theme.successColor : theme.accentColor)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Voice Input in Chat", bundle: .module)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Text(
                        voiceInputEnabled
                            ? L("Microphone button enabled in chat input")
                            : L("Enable microphone button in the chat input area")
                    )
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                }

                Spacer()

                Toggle("", isOn: $voiceInputEnabled)
                    .toggleStyle(SwitchToggleStyle(tint: theme.successColor))
                    .labelsHidden()
                    .onChange(of: voiceInputEnabled) { _, _ in
                        saveVoiceSettings()
                    }
            }

            if voiceInputEnabled {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundColor(theme.accentColor)
                    Text("A microphone button will appear in the chat input when voice is ready", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.accentColor.opacity(0.1))
                )
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            voiceInputEnabled ? theme.successColor.opacity(0.3) : theme.cardBorder,
                            lineWidth: 1
                        )
                )
        )
    }

    // MARK: - Transcription Behavior Card

    /// Stop mode / pause / confirmation / silence. These settings govern both
    /// chat voice input and the Transcription Mode overlay.
    private var transcriptionBehaviorCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(theme.accentColor.opacity(0.15))
                    Image(systemName: "timer")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Transcription Behavior", bundle: .module)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Text("Applies to both chat voice input and Transcription Mode", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()
            }

            // Voice Stop Mode Picker
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stop Mode", bundle: .module)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)

                    Text("Choose how the app knows when you've finished speaking.", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }

                ThemedTabPicker(
                    selection: $transcriptionStopMode,
                    tabs: TranscriptionStopMode.allCases.map { ($0, $0.displayName) }
                )
                .frame(maxWidth: .infinity)
                .onChange(of: transcriptionStopMode) { _, _ in
                    saveVoiceSettings()
                }

                Text(transcriptionStopMode.description)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(.top, 4)

            Divider()
                .background(theme.cardBorder)

            // Pause Duration Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Pause Detection", bundle: .module)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)

                    Spacer()

                    Text(
                        transcriptionStopMode == .manual || pauseDuration == 0
                            ? "Disabled" : String(format: "%.1fs", pauseDuration)
                    )
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.accentColor)
                }

                Slider(value: $pauseDuration, in: 0 ... 5, step: 0.5)
                    .tint(theme.accentColor)
                    .disabled(transcriptionStopMode == .manual)
                    .opacity(transcriptionStopMode == .manual ? 0.5 : 1)
                    .onChange(of: pauseDuration) { _, _ in
                        saveVoiceSettings()
                    }

                if transcriptionStopMode == .manual {
                    Text("Auto-stop is disabled in manual stop mode.", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                } else {
                    Text(
                        pauseDuration == 0
                            ? "Auto-stop disabled. You must stop transcription manually."
                            : "Stops after \(String(format: "%.1f", pauseDuration)) seconds of silence"
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                }
            }

            Divider()
                .background(theme.cardBorder)

            // Confirmation Delay Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Confirmation Delay", bundle: .module)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)

                    Spacer()

                    Text(String(format: "%.1fs", confirmationDelay))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.accentColor)
                }

                Slider(value: $confirmationDelay, in: 1 ... 5, step: 0.5)
                    .tint(theme.accentColor)
                    .disabled(transcriptionStopMode == .manual || pauseDuration == 0)
                    .opacity(transcriptionStopMode == .manual || pauseDuration == 0 ? 0.5 : 1)
                    .onChange(of: confirmationDelay) { _, _ in
                        saveVoiceSettings()
                    }

                Text("Time to cancel before a chat message is automatically sent", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }

            Divider()
                .background(theme.cardBorder)

            // Silence Timeout Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Silence Timeout", bundle: .module)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)

                    Spacer()

                    Text(silenceTimeoutFormatted)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.accentColor)
                }

                Slider(value: $silenceTimeoutSeconds, in: 10 ... 120, step: 5)
                    .tint(theme.accentColor)
                    .onChange(of: silenceTimeoutSeconds) { _, _ in
                        saveVoiceSettings()
                    }

                Text("Auto-stop or close voice input after this duration of silence", bundle: .module)
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
                    Text("Fix", bundle: .module)
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
