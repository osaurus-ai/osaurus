//
//  TranscriptionSettingsTab.swift
//  osaurus
//
//  Voice → Transcription: system-wide Transcription Mode (type with your
//  voice into any app) plus the stop / pause / cleanup behaviour that is
//  shared with chat voice input. Sections, top to bottom: the master
//  switch, the setup checklist (only while something is missing), the
//  activation hotkey, the behaviour card, and a live test area.
//

import AppKit
import SwiftUI

struct TranscriptionSettingsTab: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var speechService = SpeechService.shared
    @ObservedObject private var modelManager = SpeechModelManager.shared
    @ObservedObject private var keyboardService = KeyboardSimulationService.shared
    @ObservedObject private var transcriptionService = TranscriptionModeService.shared

    // Transcription Mode configuration
    @State private var transcriptionEnabled: Bool = false
    @State private var hotkey: Hotkey?
    @State private var hasLoadedSettings = false

    // Shared speech behaviour (drives both chat voice input and Transcription Mode)
    @State private var transcriptionStopMode: TranscriptionStopMode = .automatic
    @State private var pauseDuration: Double = 1.5
    @State private var confirmationDelay: Double = 2.0
    @State private var silenceTimeoutSeconds: Double = 30.0
    @State private var postProcessTranscription: Bool = true

    /// Polls accessibility permission while the tab is visible, since
    /// `AXIsProcessTrusted()` won't notify us when the user grants it externally.
    @State private var permissionRefreshTimer: Timer?

    // MARK: - Persistence

    private func loadSettings() {
        let config = TranscriptionConfigurationStore.load()
        transcriptionEnabled = config.transcriptionModeEnabled
        hotkey = config.hotkey
    }

    private func saveSettings() {
        TranscriptionConfigurationStore.save(
            TranscriptionConfiguration(transcriptionModeEnabled: transcriptionEnabled, hotkey: hotkey)
        )
    }

    private func loadVoiceSettings() {
        let config = SpeechConfigurationStore.load()
        transcriptionStopMode = config.transcriptionStopMode
        pauseDuration = config.pauseDuration
        confirmationDelay = config.confirmationDelay
        silenceTimeoutSeconds = config.silenceTimeoutSeconds
        postProcessTranscription = config.postProcessTranscription
    }

    private func saveVoiceSettings() {
        var config = SpeechConfigurationStore.load()
        config.transcriptionStopMode = transcriptionStopMode
        config.pauseDuration = pauseDuration
        config.confirmationDelay = confirmationDelay
        config.silenceTimeoutSeconds = silenceTimeoutSeconds
        config.postProcessTranscription = postProcessTranscription
        SpeechConfigurationStore.save(config)
        NotificationCenter.default.post(name: .voiceConfigurationChanged, object: nil)
    }

    // MARK: - Derived

    /// Whether every requirement for Transcription Mode is met.
    private var canEnableTranscription: Bool {
        keyboardService.hasAccessibilityPermission
            && speechService.microphonePermissionGranted
            && modelManager.downloadedModelsCount > 0
            && modelManager.selectedModel != nil
    }

    private var silenceTimeoutFormatted: String {
        if silenceTimeoutSeconds >= 60 {
            let minutes = Int(silenceTimeoutSeconds) / 60
            let seconds = Int(silenceTimeoutSeconds) % 60
            return seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
        }
        return "\(Int(silenceTimeoutSeconds))s"
    }

    /// Deep-links to the Core Model picker in Models → Model Defaults.
    private func navigateToCoreModelSetting() {
        SettingsHighlightCoordinator.shared.request("settings.general.coreModel")
        ManagementStateManager.shared.selectedTab = .modelDefaults
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            SettingsPageContent {
                transcriptionToggleCard

                if !canEnableTranscription {
                    requirementsCard
                }

                if canEnableTranscription {
                    hotkeySettingsCard
                }

                behaviorCard

                if canEnableTranscription && transcriptionEnabled {
                    testAreaCard
                }

                Spacer()
            }
        }
        .onAppear {
            if !hasLoadedSettings {
                loadSettings()
                loadVoiceSettings()
                hasLoadedSettings = true
            }
            keyboardService.checkAccessibilityPermission()
            startPermissionRefresh()
        }
        .onDisappear { stopPermissionRefresh() }
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
        permissionRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in
                keyboardService.checkAccessibilityPermission()
            }
        }
    }

    private func stopPermissionRefresh() {
        permissionRefreshTimer?.invalidate()
        permissionRefreshTimer = nil
    }

    // MARK: - Master Switch

    private var transcriptionToggleCard: some View {
        SettingsSection(title: "Transcription Mode") {
            SettingsToggle(
                title: "Enable Transcription Mode",
                description: transcriptionEnabled
                    ? "Type with your voice into any text field"
                    : "Voice-to-text input for any application",
                anchorId: "voice.transcription.enable",
                isOn: $transcriptionEnabled
            )
            .disabled(!canEnableTranscription)
            .opacity(canEnableTranscription ? 1 : 0.6)
            .onChange(of: transcriptionEnabled) { _, _ in saveSettings() }

            VoiceInfoBox(
                "When enabled, press the hotkey to start transcribing. Your voice will be typed directly into the focused text field in any application."
            )
        }
    }

    // MARK: - Requirements

    private var requirementsCard: some View {
        SettingsSection(title: "Setup Required") {
            Text("Complete these steps to enable Transcription Mode", bundle: .module)
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.secondary)

            VoiceRequirementRow(
                title: L("Accessibility Permission"),
                description: L("Required to type into other applications"),
                isComplete: keyboardService.hasAccessibilityPermission,
                action: { keyboardService.requestAccessibilityPermission() }
            )

            VoiceRequirementRow(
                title: L("Microphone Access"),
                description: L("Required for voice input"),
                isComplete: speechService.microphonePermissionGranted,
                action: {
                    Task { _ = await speechService.requestMicrophonePermission() }
                }
            )

            VoiceRequirementRow(
                title: L("Speech Model Downloaded"),
                description: L("Required for transcription"),
                isComplete: modelManager.downloadedModelsCount > 0,
                action: nil
            )

            VoiceRequirementRow(
                title: L("Model Selected"),
                description: L("Select a default model in the Models tab"),
                isComplete: modelManager.selectedModel != nil,
                action: nil
            )
        }
    }

    // MARK: - Hotkey

    private var hotkeySettingsCard: some View {
        SettingsSection(title: "Activation Hotkey", anchorId: "voice.stt.hotkey") {
            SettingsFieldRow(
                label: "Global Hotkey",
                hint: "Press this shortcut to start/stop transcription"
            ) {
                VStack(alignment: .leading, spacing: theme.space.s8) {
                    HotkeyRecorder(value: $hotkey)
                        .onChange(of: hotkey) { _, _ in saveSettings() }

                    if hotkey == nil {
                        Text("Set a hotkey to enable transcription mode", bundle: .module)
                            .font(SettingsFont.rowDescription)
                            .foregroundColor(theme.status.warning.foreground)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Behavior (shared with chat voice input)

    private var behaviorCard: some View {
        SettingsSection(title: "Stop Behavior & Cleanup") {
            Text("Applies to both chat voice input and Transcription Mode", bundle: .module)
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.secondary)

            SettingsToggle(
                title: "Clean Up Transcription",
                description: postProcessTranscription
                    ? "The Core Model removes filler words like \"uh\" and \"mm\""
                    : "Keep the natural transcription, including filler words",
                anchorId: "voice.stt.cleanup",
                isOn: $postProcessTranscription
            )
            .onChange(of: postProcessTranscription) { _, _ in saveVoiceSettings() }

            if postProcessTranscription {
                SettingsLinkRow(
                    title: "Core Model",
                    description: "Cleanup runs on the Core Model set under General.",
                    icon: "arrow.right",
                    actionTitle: "Change"
                ) {
                    navigateToCoreModelSetting()
                }
            }

            SettingsPickerRow(
                title: "Stop Mode",
                description: transcriptionStopMode.description,
                anchorId: "voice.stt.stopMode",
                selection: $transcriptionStopMode,
                options: TranscriptionStopMode.allCases.map { .init($0, $0.displayName) }
            )
            .onChange(of: transcriptionStopMode) { _, _ in saveVoiceSettings() }

            pauseDurationSlider
                .settingsLandingAnchor("voice.stt.pause")

            confirmationDelaySlider
                .settingsLandingAnchor("voice.stt.confirmation")

            silenceTimeoutSlider
                .settingsLandingAnchor("voice.stt.silence")
        }
    }

    private var pauseDurationSlider: some View {
        SettingsSlider(
            title: "Pause Detection",
            valueText: transcriptionStopMode == .manual || pauseDuration == 0
                ? L("Disabled") : String(format: "%.1fs", pauseDuration),
            description: pauseDurationDescription,
            value: $pauseDuration,
            range: 0 ... 5,
            step: 0.5
        )
        .disabled(transcriptionStopMode == .manual)
        .onChange(of: pauseDuration) { _, _ in saveVoiceSettings() }
    }

    private var pauseDurationDescription: LocalizedStringKey {
        if transcriptionStopMode == .manual { return "Auto-stop is disabled in manual stop mode." }
        if pauseDuration == 0 { return "Auto-stop disabled. You must stop transcription manually." }
        return "Stops after \(String(format: "%.1f", pauseDuration)) seconds of silence"
    }

    private var confirmationDelaySlider: some View {
        SettingsSlider(
            title: "Confirmation Delay",
            valueText: String(format: "%.1fs", confirmationDelay),
            description: "Time to cancel before a chat message is automatically sent",
            value: $confirmationDelay,
            range: 1 ... 5,
            step: 0.5
        )
        .disabled(transcriptionStopMode == .manual || pauseDuration == 0)
        .onChange(of: confirmationDelay) { _, _ in saveVoiceSettings() }
    }

    private var silenceTimeoutSlider: some View {
        SettingsSlider(
            title: "Silence Timeout",
            valueText: silenceTimeoutFormatted,
            description: "Auto-stop or close voice input after this duration of silence",
            value: $silenceTimeoutSeconds,
            range: 10 ... 120,
            step: 5
        )
        .onChange(of: silenceTimeoutSeconds) { _, _ in saveVoiceSettings() }
    }

    // MARK: - Test Area

    private var testAreaCard: some View {
        SettingsSection(title: "Test Transcription") {
            VStack(alignment: .leading, spacing: theme.space.s16) {
                HStack {
                    Text(
                        "Test transcription mode here. Text will be typed into the field below.",
                        bundle: .module
                    )
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.secondary)

                    Spacer()

                    if transcriptionService.state == .transcribing {
                        StatusChip(L("TRANSCRIBING"), tone: .error, showsDot: true)
                    }
                }

                SettingsTextField(placeholder: L("Transcribed text will appear here..."), text: .constant(""))

                if case .error(let message) = transcriptionService.state {
                    HStack(spacing: theme.space.s8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(theme.status.error.foreground)
                        Text(message)
                            .font(SettingsFont.caption)
                            .foregroundColor(theme.status.error.foreground)
                    }
                }

                HStack(spacing: theme.space.s16) {
                    Button(action: { transcriptionService.toggle() }) {
                        HStack(spacing: theme.space.s8) {
                            Image(
                                systemName: transcriptionService.state == .transcribing ? "stop.fill" : "mic.fill"
                            )
                            .textStyle(.bodySmall)
                            Text(transcriptionService.state == .transcribing ? L("Stop") : L("Start Test"))
                                .font(SettingsFont.rowTitle)
                        }
                    }
                    .assignedSettingsButtonStyle(transcriptionService.state == .transcribing ? .destructive : .primary)
                    .disabled(!speechService.isModelLoaded || transcriptionService.state == .starting)

                    if let hk = hotkey {
                        Text("or press \(hk.displayString)", bundle: .module)
                            .font(SettingsFont.caption)
                            .foregroundColor(theme.text.tertiary)
                    }

                    Spacer()
                }
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct TranscriptionSettingsTab_Previews: PreviewProvider {
        static var previews: some View {
            TranscriptionSettingsTab()
                .frame(width: 700, height: 800)
                .themedBackground()
        }
    }
#endif
