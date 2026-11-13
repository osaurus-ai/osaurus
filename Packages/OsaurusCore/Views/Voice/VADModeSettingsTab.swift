//
//  VADModeSettingsTab.swift
//  osaurus
//
//  Voice → Wake Word: always-on listening that opens a chat with an agent
//  when you say its name. (Internally "VAD mode"; the tab raw value and
//  service names keep that spelling.)
//

import SwiftUI

// MARK: - VAD Mode Settings Tab

struct VADModeSettingsTab: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var vadService = VADService.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var speechService = SpeechService.shared
    @ObservedObject private var modelManager = SpeechModelManager.shared

    // Configuration state
    @State private var vadEnabled: Bool = false
    @State private var enabledAgentIds: [UUID] = []
    @State private var autoStartVoiceInput: Bool = true
    @State private var customWakePhrase: String = ""
    @State private var hasLoadedSettings = false

    // Test state
    @State private var isTestingVAD = false
    @State private var testTranscription: String = ""
    @State private var testDetection: VADDetectionResult?
    @State private var testError: String?

    private func loadSettings() {
        let config = VADConfigurationStore.load()
        vadEnabled = config.vadModeEnabled
        enabledAgentIds = config.enabledAgentIds
        autoStartVoiceInput = config.autoStartVoiceInput
        customWakePhrase = config.customWakePhrase
    }

    private func saveSettings() {
        let config = VADConfiguration(
            vadModeEnabled: vadEnabled,
            enabledAgentIds: enabledAgentIds,
            autoStartVoiceInput: autoStartVoiceInput,
            customWakePhrase: customWakePhrase
        )
        VADConfigurationStore.save(config)
        vadService.loadConfiguration()
    }

    /// Whether VAD can be enabled (requirements met)
    private var canEnableVAD: Bool {
        speechService.microphonePermissionGranted && modelManager.downloadedModelsCount > 0
            && modelManager.selectedModel != nil
    }

    var body: some View {
        ScrollView {
            SettingsPageContent {
                // VAD Mode Toggle Card
                vadToggleCard

                // Requirements Card (if not met)
                if !canEnableVAD {
                    requirementsCard
                }

                // Agent Selection Card
                if canEnableVAD {
                    agentSelectionCard
                }

                // Wake Word Settings Card
                if canEnableVAD {
                    wakeWordSettingsCard
                }

                // Behavior Settings Card
                if canEnableVAD {
                    behaviorSettingsCard
                }

                // Test Area Card
                if canEnableVAD && vadEnabled {
                    testAreaCard
                }

                Spacer()
            }
        }
        .onAppear {
            if !hasLoadedSettings {
                loadSettings()
                hasLoadedSettings = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .voiceConfigurationChanged)) { _ in
            loadSettings()
        }
        .onDisappear {
            // Clean up test if running when navigating away
            if isTestingVAD {
                isTestingVAD = false
                Task {
                    // Resume VAD if it should be running
                    if vadEnabled {
                        try? await vadService.start()
                    } else {
                        _ = await speechService.stopStreamingTranscription()
                    }
                }
            }
        }
    }

    // MARK: - VAD Toggle Card

    private var vadToggleCard: some View {
        SettingsSection(title: "Wake Word", anchorId: "voice.stt.vad") {
            SettingsToggle(
                title: "Enable Wake Word",
                description: vadEnabled
                    ? "Always listening for agent names"
                    : "Say an agent's name to open a chat with it",
                isOn: $vadEnabled
            )
            .disabled(!canEnableVAD)
            .opacity(canEnableVAD ? 1 : 0.6)
            .onChange(of: vadEnabled) { _, newValue in
                saveSettings()
                Task {
                    if newValue {
                        try? await vadService.start()
                    } else {
                        await vadService.stop()
                    }
                }
            }

            // Status indicator
            if vadEnabled {
                HStack(spacing: theme.space.s8) {
                    VoiceStatusIndicator(
                        state: vadServiceState,
                        showLabel: true,
                        compact: false
                    )

                    Spacer()

                    if vadService.state == .listening {
                        WaveformView(level: vadService.audioLevel, style: .minimal)
                            .frame(width: 36, height: 36)
                    }
                }
                .padding(theme.space.s12)
                .settingsChrome(.inset)
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                        .strokeBorder(theme.status.success.border, lineWidth: theme.stroke.default)
                )
            }

            VoiceInfoBox(
                "When enabled, Osaurus will continuously listen for agent names. Say an agent's name to automatically open a chat with that agent."
            )
        }
    }

    private var vadServiceState: VoiceState {
        switch vadService.state {
        case .idle: return .idle
        case .starting: return .processing
        case .listening: return .listening
        case .error(let msg): return .error(msg)
        }
    }

    // MARK: - Requirements Card

    private var requirementsCard: some View {
        SettingsSection(title: "Setup Required") {
            Text("Complete these steps to enable Wake Word", bundle: .module)
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.secondary)

            VoiceRequirementRow(
                title: L("Microphone Access"),
                isComplete: speechService.microphonePermissionGranted,
                action: {
                    Task {
                        _ = await speechService.requestMicrophonePermission()
                    }
                }
            )

            VoiceRequirementRow(
                title: L("Speech Model Downloaded"),
                isComplete: modelManager.downloadedModelsCount > 0,
                action: nil
            )

            VoiceRequirementRow(
                title: L("Model Selected"),
                isComplete: modelManager.selectedModel != nil,
                action: nil
            )
        }
    }

    // MARK: - Agent Selection Card

    private var agentSelectionCard: some View {
        SettingsSection(title: "Activated Agents") {
            VStack(alignment: .leading, spacing: theme.space.s12) {
                Text("Select which agents can be activated by voice", bundle: .module)
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.secondary)

                if enabledAgentIds.isEmpty {
                    HStack(spacing: theme.space.s8) {
                        Image(systemName: "info.circle")
                            .glyphSize(.caption)
                            .foregroundColor(theme.status.warning.foreground)
                        Text("Select at least one agent to enable Wake Word", bundle: .module)
                            .font(SettingsFont.caption)
                            .foregroundColor(theme.status.warning.foreground)
                    }
                    .padding(theme.space.s12)
                    .settingsChrome(.status(.warning))
                }

                // Agent list
                VStack(spacing: theme.space.s8) {
                    ForEach(agentManager.agents) { agent in
                        AgentToggleRow(
                            agent: agent,
                            isEnabled: enabledAgentIds.contains(agent.id),
                            onToggle: { enabled in
                                if enabled {
                                    if !enabledAgentIds.contains(agent.id) {
                                        enabledAgentIds.append(agent.id)
                                    }
                                } else {
                                    enabledAgentIds.removeAll { $0 == agent.id }
                                }
                                saveSettings()
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Wake Word Settings Card

    private var wakeWordSettingsCard: some View {
        SettingsSection(title: "Custom Phrase") {
            SettingsTextFieldRow(
                label: "Custom Wake Phrase (Optional)",
                text: $customWakePhrase,
                placeholder: "e.g., Hey Osaurus",
                help: "Leave empty to only use agent names as wake words"
            )
            .onChange(of: customWakePhrase) { _, _ in
                saveSettings()
            }

            SettingsLinkRow(
                title: "Detection Sensitivity",
                description: "Configured once in Setup and shared by every voice mode.",
                icon: "arrow.right",
                actionTitle: "Open Setup"
            ) {
                SettingsHighlightCoordinator.shared.request("voice.setup.sensitivity")
                ManagementStateManager.shared.voiceSubTabRequest = VoiceTab.setup.rawValue
            }
        }
    }

    // MARK: - Behavior Settings Card

    private var behaviorSettingsCard: some View {
        SettingsSection(title: "Behavior") {
            SettingsToggle(
                title: "Auto-Start Voice Input",
                description: "Immediately start voice input after agent activation",
                isOn: $autoStartVoiceInput
            )
            .onChange(of: autoStartVoiceInput) { _, _ in
                saveSettings()
            }
        }
    }

    // MARK: - Test Area Card

    private var testAreaCard: some View {
        SettingsSection(title: "Test Wake Word Detection") {
            VStack(alignment: .leading, spacing: theme.space.s16) {
                HStack {
                    Text("Speak an agent name to test detection", bundle: .module)
                        .font(SettingsFont.caption)
                        .foregroundColor(theme.text.secondary)

                    Spacer()

                    if isTestingVAD {
                        StatusChip(L("Listening"), tone: .error, showsDot: true)
                    }
                }

                // Waveform
                if isTestingVAD {
                    WaveformView(level: speechService.audioLevel, style: .bars, barCount: 20)
                        .frame(height: 48)
                }

                // Transcription
                VStack(alignment: .leading, spacing: theme.space.s8) {
                    Text(testTranscription.isEmpty ? "Waiting for speech..." : testTranscription)
                        .font(SettingsFont.body)
                        .foregroundColor(testTranscription.isEmpty ? theme.text.tertiary : theme.text.primary)
                        .italic(testTranscription.isEmpty)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(theme.space.s16)
                .settingsChrome(.inset)

                // Detection result
                if let detection = testDetection {
                    HStack(spacing: theme.space.s12) {
                        Image(systemName: "checkmark.circle.fill")
                            .glyphSize(.xxlarge)
                            .foregroundColor(theme.status.success.foreground)

                        VStack(alignment: .leading, spacing: theme.space.s2) {
                            Text("Detected: \(detection.agentName)", bundle: .module)
                                .font(SettingsFont.cardTitle)
                                .foregroundColor(theme.status.success.foreground)
                            Text("Confidence: \(Int(detection.confidence * 100))%", bundle: .module)
                                .font(SettingsFont.caption)
                                .foregroundColor(theme.text.secondary)
                        }

                        Spacer()
                    }
                    .padding(theme.space.s12)
                    .settingsChrome(.status(.success))
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }

                // Error
                if let error = testError {
                    HStack(spacing: theme.space.s8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(theme.status.error.foreground)
                        Text(error)
                            .font(SettingsFont.caption)
                            .foregroundColor(theme.status.error.foreground)
                    }
                }

                // Controls
                HStack(spacing: theme.space.s16) {
                    TestButton(
                        isActive: isTestingVAD,
                        action: toggleTest
                    )

                    if testDetection != nil || !testTranscription.isEmpty {
                        Button(action: clearTest) {
                            Text("Clear", bundle: .module)
                        }
                        .assignedSettingsButtonStyle(.secondary)
                    }

                    Spacer()
                }
            }
        }
        .onChange(of: speechService.currentTranscription) { _, newValue in
            if isTestingVAD {
                testTranscription = newValue
                checkForDetection(in: newValue)
            }
        }
        .onChange(of: speechService.confirmedTranscription) { _, newValue in
            if isTestingVAD && !newValue.isEmpty {
                testTranscription = newValue
                checkForDetection(in: newValue)
            }
        }
    }

    private func toggleTest() {
        if isTestingVAD {
            // Stop testing
            isTestingVAD = false
            Task {
                // If VAD was enabled before test, resume it
                if vadEnabled {
                    try? await vadService.start()
                } else {
                    _ = await speechService.stopStreamingTranscription()
                }
            }
        } else {
            // Start testing - pause VAD if running
            testError = nil
            testDetection = nil
            testTranscription = ""
            Task {
                // Pause VAD if it's running (it uses the same transcription)
                if vadService.state == .listening {
                    await vadService.pause()
                }

                do {
                    // Start fresh transcription for testing
                    try await speechService.startStreamingTranscription()
                    isTestingVAD = true
                } catch {
                    testError = error.localizedDescription
                    // Resume VAD if it was paused
                    if vadEnabled {
                        try? await vadService.start()
                    }
                }
            }
        }
    }

    private func clearTest() {
        testTranscription = ""
        testDetection = nil
        testError = nil
        speechService.clearTranscription()
    }

    private func checkForDetection(in text: String) {
        let detector = AgentNameDetector(
            enabledAgentIds: enabledAgentIds,
            customWakePhrase: customWakePhrase
        )
        if let detection = detector.detect(in: text) {
            testDetection = detection

            // Auto-reset after showing the match for 2 seconds
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                // Only reset if still testing and same detection
                if isTestingVAD {
                    testTranscription = ""
                    testDetection = nil
                    speechService.clearTranscription()
                }
            }
        }
    }
}

// MARK: - Helper Views

private struct AgentToggleRow: View {
    @Environment(\.theme) private var theme

    let agent: Agent
    let isEnabled: Bool
    let onToggle: (Bool) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: theme.space.s12) {
            // Agent icon
            ZStack {
                Circle()
                    .fill(isEnabled ? theme.surface.selected : theme.surface.hover)

                if isEnabled {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [theme.surface.hover, Color.clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                Text(String(agent.name.prefix(1)).uppercased())
                    .font(SettingsFont.cardTitle)
                    .foregroundColor(isEnabled ? theme.text.link : theme.text.tertiary)
            }
            .frame(width: 36, height: 36)
            .overlay(
                Circle()
                    .strokeBorder(
                        isEnabled ? theme.border.strong : theme.border.subtle,
                        lineWidth: theme.stroke.default
                    )
            )

            SettingsRowText {
                Text(agent.name)
            } description: {
                if !agent.routingDescription.isEmpty {
                    Text(agent.routingDescription)
                        .lineLimit(1)
                }
            }

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { isEnabled },
                    set: { onToggle($0) }
                )
            )
            .settingsSwitch()
        }
        .padding(theme.space.s12)
        .background(rowBackground)
        .overlay(rowBorder)
        .onHover { hovering in
            withAnimation(theme.motion.quick) {
                isHovered = hovering
            }
        }
    }

    private var rowBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                .fill(
                    isEnabled
                        ? theme.surface.selected : (isHovered ? theme.surface.hover : theme.surface.subtle)
                )

            if isEnabled || isHovered {
                RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                    .fill(
                        isEnabled ? theme.selection.background : theme.surface.hover
                    )
            }
        }
    }

    private var rowBorder: some View {
        RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
            .strokeBorder(
                isEnabled ? theme.border.focus : (isHovered ? theme.border.default : theme.border.subtle),
                lineWidth: theme.stroke.default
            )
    }
}

// MARK: - Test Button

private struct TestButton: View {
    @Environment(\.theme) private var theme
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.space.s8) {
                Image(systemName: isActive ? "stop.fill" : "mic.fill")
                Text(isActive ? L("Stop Test") : L("Start Test"))
            }
        }
        .assignedSettingsButtonStyle(isActive ? .destructive : .primary)
    }
}

// MARK: - Preview

#if DEBUG
    struct VADModeSettingsTab_Previews: PreviewProvider {
        static var previews: some View {
            VADModeSettingsTab()
                .frame(width: 700, height: 800)
                .themedBackground()
        }
    }
#endif
