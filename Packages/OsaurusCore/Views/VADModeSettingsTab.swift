//
//  VADModeSettingsTab.swift
//  osaurus
//
//  VAD (Voice Activity Detection) mode settings.
//  Configure wake-word agent activation.
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
            VStack(spacing: 24) {
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
            .padding(24)
            .frame(maxWidth: .infinity)
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(vadEnabled ? theme.successColor.opacity(0.15) : theme.accentColor.opacity(0.15))

                    if vadEnabled {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [theme.successColor.opacity(0.1), Color.clear],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }

                    Image(systemName: vadEnabled ? "waveform.circle.fill" : "waveform.circle")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(vadEnabled ? theme.successColor : theme.accentColor)
                }
                .frame(width: 48, height: 48)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            (vadEnabled ? theme.successColor : theme.accentColor).opacity(0.2),
                            lineWidth: 1
                        )
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text("VAD Mode")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Text(vadEnabled ? "Always listening for wake words" : "Voice-activated agent switching")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()

                Toggle("", isOn: $vadEnabled)
                    .toggleStyle(SwitchToggleStyle(tint: theme.successColor))
                    .labelsHidden()
                    .disabled(!canEnableVAD)
                    .opacity(canEnableVAD ? 1 : 0.5)
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
            }

            // Status indicator
            if vadEnabled {
                HStack(spacing: 8) {
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
                .padding(14)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.tertiaryBackground.opacity(0.8))
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [theme.successColor.opacity(0.05), Color.clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(theme.successColor.opacity(0.15), lineWidth: 1)
                )
            }

            // Info about VAD mode
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundColor(theme.accentColor)

                Text(
                    "When enabled, Osaurus will continuously listen for agent names. Say a agent's name to automatically open a chat with that agent."
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
            }
            .padding(12)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.accentColor.opacity(0.08))
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.accentColor.opacity(0.12), lineWidth: 1)
                }
            )
        }
        .padding(20)
        .modifier(SettingsCardStyle(accentColor: vadEnabled ? theme.successColor : nil))
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                CardIconBox(icon: "exclamationmark.triangle.fill", color: theme.warningColor)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Setup Required")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Text("Complete these steps to enable VAD mode")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()
            }

            VStack(spacing: 12) {
                RequirementRow(
                    title: "Microphone Access",
                    isComplete: speechService.microphonePermissionGranted,
                    action: {
                        Task {
                            _ = await speechService.requestMicrophonePermission()
                        }
                    }
                )

                RequirementRow(
                    title: "Speech Model Downloaded",
                    isComplete: modelManager.downloadedModelsCount > 0,
                    action: nil
                )

                RequirementRow(
                    title: "Model Selected",
                    isComplete: modelManager.selectedModel != nil,
                    action: nil
                )
            }
        }
        .padding(20)
        .modifier(SettingsCardStyle(accentColor: theme.warningColor))
    }

    // MARK: - Agent Selection Card

    private var agentSelectionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                CardIconBox(icon: "person.2.fill", color: theme.accentColor)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Activated Agents")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Text("Select which agents can be activated by voice")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()
            }

            if enabledAgentIds.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundColor(theme.warningColor)
                    Text("Select at least one agent to enable VAD")
                        .font(.system(size: 12))
                        .foregroundColor(theme.warningColor)
                }
                .padding(12)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(theme.warningColor.opacity(0.08))
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(theme.warningColor.opacity(0.15), lineWidth: 1)
                    }
                )
            }

            // Agent list
            VStack(spacing: 8) {
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
        .padding(20)
        .modifier(SettingsCardStyle(accentColor: nil))
    }

    // MARK: - Wake Word Settings Card

    private var wakeWordSettingsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                CardIconBox(icon: "text.bubble.fill", color: theme.accentColor)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Wake Word Settings")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Text("Configure how wake words are detected")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()
            }

            // Custom wake phrase
            VStack(alignment: .leading, spacing: 8) {
                Text("Custom Wake Phrase (Optional)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                TextField("e.g., Hey Osaurus", text: $customWakePhrase)
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
                    .onChange(of: customWakePhrase) { _, _ in
                        saveSettings()
                    }

                Text("Leave empty to only use agent names as wake words")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }

            // Info about sensitivity
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundColor(theme.accentColor)
                Text("Detection sensitivity is configured in the Audio tab")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
            }
            .padding(12)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.accentColor.opacity(0.08))
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.accentColor.opacity(0.12), lineWidth: 1)
                }
            )
        }
        .padding(20)
        .modifier(SettingsCardStyle(accentColor: nil))
    }

    // MARK: - Behavior Settings Card

    private var behaviorSettingsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                CardIconBox(icon: "gearshape.fill", color: theme.accentColor)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Behavior")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Text("Configure what happens when a wake word is detected")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()
            }

            // Auto-start voice input
            ToggleSettingRow(
                title: "Auto-Start Voice Input",
                description: "Immediately start voice input after agent activation",
                isOn: $autoStartVoiceInput,
                onChange: { saveSettings() }
            )
        }
        .padding(20)
        .modifier(SettingsCardStyle(accentColor: nil))
    }

    // MARK: - Test Area Card

    private var testAreaCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Test Wake Word Detection")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Spacer()

                if isTestingVAD {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(theme.errorColor)
                            .frame(width: 8, height: 8)
                        Text("LISTENING")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(theme.errorColor)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        ZStack {
                            Capsule()
                                .fill(theme.errorColor.opacity(0.1))
                            Capsule()
                                .strokeBorder(theme.errorColor.opacity(0.2), lineWidth: 1)
                        }
                    )
                }
            }

            Text("Speak an agent name to test detection")
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)

            // Waveform
            if isTestingVAD {
                WaveformView(level: speechService.audioLevel, style: .bars, barCount: 20)
                    .frame(height: 48)
            }

            // Transcription
            VStack(alignment: .leading, spacing: 8) {
                Text(testTranscription.isEmpty ? "Waiting for speech..." : testTranscription)
                    .font(.system(size: 15))
                    .foregroundColor(testTranscription.isEmpty ? theme.tertiaryText : theme.primaryText)
                    .italic(testTranscription.isEmpty)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(theme.inputBackground)

                    if isTestingVAD {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [theme.accentColor.opacity(0.05), Color.clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                isTestingVAD ? theme.accentColor.opacity(0.5) : theme.glassEdgeLight.opacity(0.15),
                                isTestingVAD ? theme.accentColor.opacity(0.2) : theme.inputBorder,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: isTestingVAD ? 1.5 : 1
                    )
            )

            // Detection result
            if let detection = testDetection {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(theme.successColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Detected: \(detection.agentName)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.successColor)
                        Text("Confidence: \(Int(detection.confidence * 100))%")
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                    }

                    Spacer()
                }
                .padding(14)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.successColor.opacity(0.1))
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(theme.successColor.opacity(0.2), lineWidth: 1)
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            // Error
            if let error = testError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(theme.errorColor)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(theme.errorColor)
                }
            }

            // Controls
            HStack(spacing: 16) {
                TestButton(
                    isActive: isTestingVAD,
                    action: toggleTest
                )

                if testDetection != nil || !testTranscription.isEmpty {
                    Button(action: clearTest) {
                        Text("Clear")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(theme.tertiaryBackground)
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(theme.primaryBorder.opacity(0.15), lineWidth: 1)
                                }
                            )
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
        }
        .padding(20)
        .modifier(SettingsCardStyle(accentColor: isTestingVAD ? theme.errorColor : nil))
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

private struct RequirementRow: View {
    @Environment(\.theme) private var theme

    let title: String
    let isComplete: Bool
    var action: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundColor(isComplete ? theme.successColor : theme.tertiaryText)
                .animation(.easeOut(duration: 0.2), value: isComplete)

            Text(title)
                .font(.system(size: 14))
                .foregroundColor(theme.primaryText)

            Spacer()

            if !isComplete, let action = action {
                Button(action: action) {
                    Text("Fix")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(isHovered ? .white : theme.accentColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            ZStack {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isHovered ? theme.accentColor : Color.clear)
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(theme.accentColor, lineWidth: 1)
                            }
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.15)) {
                        isHovered = hovering
                    }
                }
            }
        }
        .padding(14)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isComplete ? theme.successColor.opacity(0.06) : theme.tertiaryBackground.opacity(0.7))

                if isComplete {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [theme.successColor.opacity(0.05), Color.clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isComplete ? theme.successColor.opacity(0.2) : theme.primaryBorder.opacity(0.08),
                    lineWidth: 1
                )
        )
    }
}

private struct AgentToggleRow: View {
    @Environment(\.theme) private var theme

    let agent: Agent
    let isEnabled: Bool
    let onToggle: (Bool) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            // Agent icon
            ZStack {
                Circle()
                    .fill(isEnabled ? theme.accentColor.opacity(0.15) : theme.tertiaryBackground)

                if isEnabled {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [theme.accentColor.opacity(0.1), Color.clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                Text(String(agent.name.prefix(1)).uppercased())
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isEnabled ? theme.accentColor : theme.tertiaryText)
            }
            .frame(width: 36, height: 36)
            .overlay(
                Circle()
                    .strokeBorder(
                        isEnabled ? theme.accentColor.opacity(0.25) : theme.primaryBorder.opacity(0.1),
                        lineWidth: 1
                    )
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.primaryText)

                if !agent.description.isEmpty {
                    Text(agent.description)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
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
            .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
            .labelsHidden()
        }
        .padding(14)
        .background(rowBackground)
        .overlay(rowBorder)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    private var rowBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    isEnabled
                        ? theme.accentColor.opacity(0.06) : theme.tertiaryBackground.opacity(isHovered ? 0.9 : 0.7)
                )

            if isEnabled || isHovered {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                (isEnabled ? theme.accentColor : theme.glassEdgeLight).opacity(isEnabled ? 0.06 : 0.04),
                                Color.clear,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
    }

    private var rowBorder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        isEnabled
                            ? theme.accentColor.opacity(0.25) : theme.glassEdgeLight.opacity(isHovered ? 0.15 : 0.08),
                        isEnabled
                            ? theme.accentColor.opacity(0.1) : theme.primaryBorder.opacity(isHovered ? 0.1 : 0.05),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }
}

private struct ToggleSettingRow: View {
    @Environment(\.theme) private var theme

    let title: String
    let description: String
    @Binding var isOn: Bool
    var onChange: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.primaryText)

                Text(description)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                .labelsHidden()
                .onChange(of: isOn) { _, _ in
                    onChange?()
                }
        }
    }
}

// MARK: - Card Icon Box

private struct CardIconBox: View {
    let icon: String
    let color: Color

    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color.opacity(0.15))

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.1), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(color)
        }
        .frame(width: 48, height: 48)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(color.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Test Button

private struct TestButton: View {
    let isActive: Bool
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isActive ? "stop.fill" : "mic.fill")
                    .font(.system(size: 14))
                Text(isActive ? "Stop Test" : "Start Test")
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(buttonBackground)
            .overlay(buttonBorder)
            .shadow(
                color: (isActive ? theme.errorColor : theme.accentColor).opacity(isHovered ? 0.4 : 0.25),
                radius: isHovered ? 10 : 6,
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
    }

    private var buttonBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive ? theme.errorColor : theme.accentColor)

            if isHovered {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.1))
            }
        }
    }

    private var buttonBorder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(isHovered ? 0.3 : 0.2),
                        (isActive ? theme.errorColor : theme.accentColor).opacity(0.3),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }
}

// MARK: - Settings Card Style

private struct SettingsCardStyle: ViewModifier {
    var accentColor: Color?

    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(cardBorder)
            .shadow(color: theme.shadowColor.opacity(0.08), radius: 8, x: 0, y: 4)
    }

    private var cardBackground: some View {
        ZStack {
            // Layer 1: Glass material
            if theme.glassEnabled {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
            }

            // Layer 2: Card background
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.cardBackground.opacity(theme.isDark ? 0.85 : 0.92))

            // Layer 3: Subtle accent gradient at top
            if let accent = accentColor {
                LinearGradient(
                    colors: [accent.opacity(theme.isDark ? 0.08 : 0.05), Color.clear],
                    startPoint: .top,
                    endPoint: .center
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                LinearGradient(
                    colors: [theme.accentColor.opacity(theme.isDark ? 0.04 : 0.02), Color.clear],
                    startPoint: .top,
                    endPoint: .center
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        accentColor?.opacity(0.25) ?? theme.glassEdgeLight.opacity(0.15),
                        accentColor?.opacity(0.1) ?? theme.cardBorder.opacity(0.8),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
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
