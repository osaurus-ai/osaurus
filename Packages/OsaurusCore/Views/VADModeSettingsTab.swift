//
//  VADModeSettingsTab.swift
//  osaurus
//
//  VAD (Voice Activity Detection) mode settings.
//  Configure wake-word persona activation.
//

import SwiftUI

// MARK: - VAD Mode Settings Tab

struct VADModeSettingsTab: View {
    @Environment(\.theme) private var theme
    @StateObject private var vadService = VADService.shared
    @StateObject private var personaManager = PersonaManager.shared
    @StateObject private var whisperService = WhisperKitService.shared
    @StateObject private var modelManager = WhisperModelManager.shared

    // Configuration state
    @State private var vadEnabled: Bool = false
    @State private var enabledPersonaIds: [UUID] = []
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
        enabledPersonaIds = config.enabledPersonaIds
        autoStartVoiceInput = config.autoStartVoiceInput
        customWakePhrase = config.customWakePhrase
    }

    private func saveSettings() {
        let config = VADConfiguration(
            vadModeEnabled: vadEnabled,
            enabledPersonaIds: enabledPersonaIds,
            autoStartVoiceInput: autoStartVoiceInput,
            customWakePhrase: customWakePhrase
        )
        VADConfigurationStore.save(config)
        vadService.loadConfiguration()
    }

    /// Whether VAD can be enabled (requirements met)
    private var canEnableVAD: Bool {
        whisperService.microphonePermissionGranted && modelManager.downloadedModelsCount > 0
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

                // Persona Selection Card
                if canEnableVAD {
                    personaSelectionCard
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
            .frame(maxWidth: 700)
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
                        _ = await whisperService.stopStreamingTranscription()
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
                    RoundedRectangle(cornerRadius: 12)
                        .fill(vadEnabled ? theme.successColor.opacity(0.15) : theme.accentColor.opacity(0.15))
                    Image(systemName: vadEnabled ? "waveform.circle.fill" : "waveform.circle")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(vadEnabled ? theme.successColor : theme.accentColor)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text("VAD Mode")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Text(vadEnabled ? "Always listening for wake words" : "Voice-activated persona switching")
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
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.tertiaryBackground)
                )
            }

            // Info about VAD mode
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundColor(theme.accentColor)

                Text(
                    "When enabled, Osaurus will continuously listen for persona names. Say a persona's name to automatically open a chat with that persona."
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
                        .stroke(vadEnabled ? theme.successColor.opacity(0.3) : theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private var vadServiceState: VoiceState {
        switch vadService.state {
        case .idle: return .idle
        case .starting: return .processing
        case .listening: return .listening
        case .processing: return .processing
        case .error(let msg): return .error(msg)
        }
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

                    Text("Complete these steps to enable VAD mode")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()
            }

            VStack(spacing: 12) {
                RequirementRow(
                    title: "Microphone Access",
                    isComplete: whisperService.microphonePermissionGranted,
                    action: {
                        Task {
                            _ = await whisperService.requestMicrophonePermission()
                        }
                    }
                )

                RequirementRow(
                    title: "Whisper Model Downloaded",
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
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(theme.warningColor.opacity(0.3), lineWidth: 1)
                )
        )
    }

    // MARK: - Persona Selection Card

    private var personaSelectionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(theme.accentColor.opacity(0.15))
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Activated Personas")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Text("Select which personas can be activated by voice")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()
            }

            if enabledPersonaIds.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundColor(theme.warningColor)
                    Text("Select at least one persona to enable VAD")
                        .font(.system(size: 12))
                        .foregroundColor(theme.warningColor)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.warningColor.opacity(0.1))
                )
            }

            // Persona list
            VStack(spacing: 8) {
                ForEach(personaManager.personas) { persona in
                    PersonaToggleRow(
                        persona: persona,
                        isEnabled: enabledPersonaIds.contains(persona.id),
                        onToggle: { enabled in
                            if enabled {
                                if !enabledPersonaIds.contains(persona.id) {
                                    enabledPersonaIds.append(persona.id)
                                }
                            } else {
                                enabledPersonaIds.removeAll { $0 == persona.id }
                            }
                            saveSettings()
                        }
                    )
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

    // MARK: - Wake Word Settings Card

    private var wakeWordSettingsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(theme.accentColor.opacity(0.15))
                    Image(systemName: "text.bubble.fill")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
                .frame(width: 48, height: 48)

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

                Text("Leave empty to only use persona names as wake words")
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
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    // MARK: - Behavior Settings Card

    private var behaviorSettingsCard: some View {
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
                description: "Immediately start voice input after persona activation",
                isOn: $autoStartVoiceInput,
                onChange: { saveSettings() }
            )
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
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(theme.errorColor.opacity(0.1))
                    )
                }
            }

            Text("Speak a persona name to test detection")
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)

            // Waveform
            if isTestingVAD {
                WaveformView(level: whisperService.audioLevel, style: .bars, barCount: 20)
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
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                isTestingVAD ? theme.accentColor.opacity(0.5) : theme.inputBorder,
                                lineWidth: isTestingVAD ? 2 : 1
                            )
                    )
            )

            // Detection result
            if let detection = testDetection {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(theme.successColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Detected: \(detection.personaName)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.successColor)
                        Text("Confidence: \(Int(detection.confidence * 100))%")
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                    }

                    Spacer()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.successColor.opacity(0.1))
                )
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
                Button(action: toggleTest) {
                    HStack(spacing: 8) {
                        Image(systemName: isTestingVAD ? "stop.fill" : "mic.fill")
                            .font(.system(size: 14))
                        Text(isTestingVAD ? "Stop Test" : "Start Test")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(isTestingVAD ? theme.errorColor : theme.accentColor)
                    )
                }
                .buttonStyle(.plain)

                if testDetection != nil || !testTranscription.isEmpty {
                    Button(action: clearTest) {
                        Text("Clear")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.tertiaryBackground)
                            )
                    }
                    .buttonStyle(.plain)
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
        .onChange(of: whisperService.currentTranscription) { _, newValue in
            if isTestingVAD {
                testTranscription = newValue
                checkForDetection(in: newValue)
            }
        }
        .onChange(of: whisperService.confirmedTranscription) { _, newValue in
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
                    _ = await whisperService.stopStreamingTranscription()
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
                    try await whisperService.startStreamingTranscription()
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
        whisperService.clearTranscription()
    }

    private func checkForDetection(in text: String) {
        let detector = PersonaNameDetector(
            enabledPersonaIds: enabledPersonaIds,
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
                    whisperService.clearTranscription()
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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundColor(isComplete ? theme.successColor : theme.tertiaryText)

            Text(title)
                .font(.system(size: 14))
                .foregroundColor(theme.primaryText)

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

private struct PersonaToggleRow: View {
    @Environment(\.theme) private var theme

    let persona: Persona
    let isEnabled: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Persona icon
            ZStack {
                Circle()
                    .fill(isEnabled ? theme.accentColor.opacity(0.15) : theme.tertiaryBackground)
                    .frame(width: 36, height: 36)

                Text(String(persona.name.prefix(1)).uppercased())
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isEnabled ? theme.accentColor : theme.tertiaryText)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(persona.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.primaryText)

                if !persona.description.isEmpty {
                    Text(persona.description)
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
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isEnabled ? theme.accentColor.opacity(0.05) : theme.tertiaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isEnabled ? theme.accentColor.opacity(0.2) : .clear, lineWidth: 1)
                )
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

// MARK: - Preview

#if DEBUG
    struct VADModeSettingsTab_Previews: PreviewProvider {
        static var previews: some View {
            VADModeSettingsTab()
                .frame(width: 700, height: 800)
                .background(Color(hex: "1a1a1a"))
        }
    }
#endif
