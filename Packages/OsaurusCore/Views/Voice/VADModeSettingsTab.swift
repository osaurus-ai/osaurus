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
        SettingsSection(title: "VAD Mode", icon: "waveform.circle") {
            VStack(alignment: .leading, spacing: 12) {
                SettingsToggle(
                    title: L("Enable VAD Mode"),
                    description: vadEnabled
                        ? L("Always listening for wake words")
                        : L("Voice-activated agent switching"),
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
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.tertiaryBackground.opacity(0.8))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(theme.successColor.opacity(0.15), lineWidth: 1)
                    )
                }

                infoBox(
                    "When enabled, Osaurus will continuously listen for agent names. Say a agent's name to automatically open a chat with that agent."
                )
            }
        }
    }

    /// Accent-tinted informational callout shared by this tab's sections.
    private func infoBox(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundColor(theme.accentColor)

            Text(LocalizedStringKey(text), bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
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
        SettingsSection(title: "Setup Required", icon: "exclamationmark.triangle.fill") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Complete these steps to enable VAD mode", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)

                VStack(spacing: 12) {
                    RequirementRow(
                        title: L("Microphone Access"),
                        isComplete: speechService.microphonePermissionGranted,
                        action: {
                            Task {
                                _ = await speechService.requestMicrophonePermission()
                            }
                        }
                    )

                    RequirementRow(
                        title: L("Speech Model Downloaded"),
                        isComplete: modelManager.downloadedModelsCount > 0,
                        action: nil
                    )

                    RequirementRow(
                        title: L("Model Selected"),
                        isComplete: modelManager.selectedModel != nil,
                        action: nil
                    )
                }
            }
        }
    }

    // MARK: - Agent Selection Card

    private var agentSelectionCard: some View {
        SettingsSection(title: "Activated Agents", icon: "person.2") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Select which agents can be activated by voice", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)

                if enabledAgentIds.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundColor(theme.warningColor)
                        Text("Select at least one agent to enable VAD", bundle: .module)
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
        }
    }

    // MARK: - Wake Word Settings Card

    private var wakeWordSettingsCard: some View {
        SettingsSection(title: "Wake Word", icon: "text.bubble") {
            VStack(alignment: .leading, spacing: 12) {
                StyledSettingsTextField(
                    label: "Custom Wake Phrase (Optional)",
                    text: $customWakePhrase,
                    placeholder: "e.g., Hey Osaurus",
                    help: "Leave empty to only use agent names as wake words"
                )
                .onChange(of: customWakePhrase) { _, _ in
                    saveSettings()
                }

                infoBox("Detection sensitivity is configured in the Setup tab")
            }
        }
    }

    // MARK: - Behavior Settings Card

    private var behaviorSettingsCard: some View {
        SettingsSection(title: "Behavior", icon: "gearshape") {
            SettingsToggle(
                title: L("Auto-Start Voice Input"),
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
        SettingsSection(title: "Test Wake Word Detection", icon: "mic") {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Speak an agent name to test detection", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)

                    Spacer()

                    if isTestingVAD {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(theme.errorColor)
                                .frame(width: 8, height: 8)
                            Text("LISTENING", bundle: .module)
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
                                    isTestingVAD
                                        ? theme.accentColor.opacity(0.5) : theme.glassEdgeLight.opacity(0.15),
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
                            Text("Detected: \(detection.agentName)", bundle: .module)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(theme.successColor)
                            Text("Confidence: \(Int(detection.confidence * 100))%", bundle: .module)
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
                            Text("Clear", bundle: .module)
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
                    Text("Fix", bundle: .module)
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
                Text(isActive ? L("Stop Test") : L("Start Test"))
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(buttonBackground)
            .overlay(buttonBorder)
            .shadow(
                // Fixed radius: animating shadow radius re-renders the blur
                // every frame; opacity alone reads the same on hover.
                color: (isActive ? theme.errorColor : theme.accentColor).opacity(isHovered ? 0.4 : 0.25),
                radius: 8,
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
