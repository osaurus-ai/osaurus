//
//  AudioSettingsTab.swift
//  osaurus
//
//  Shared audio settings for all voice modes (Voice Input, VAD, Transcription).
//  Configures sensitivity and audio input device.
//

import SwiftUI

// MARK: - Audio Settings Tab

struct AudioSettingsTab: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var speechService = SpeechService.shared
    @ObservedObject private var modelManager = SpeechModelManager.shared
    @ObservedObject private var audioInputManager = AudioInputManager.shared
    @ObservedObject private var systemAudioManager = SystemAudioCaptureManager.shared

    // Settings state
    @State private var sensitivity: VoiceSensitivity = .medium
    @State private var hasLoadedSettings = false

    // Test state
    @State private var isTestingVoice = false
    @State private var testError: String?

    private func loadSettings() {
        let config = SpeechConfigurationStore.load()
        sensitivity = config.sensitivity
    }

    private func saveSettings() {
        var config = SpeechConfigurationStore.load()
        config.sensitivity = sensitivity
        SpeechConfigurationStore.save(config)

        NotificationCenter.default.post(name: .voiceConfigurationChanged, object: nil)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Info Card
                infoCard

                // Sensitivity Settings Card
                sensitivitySettingsCard

                // Input Device Card
                inputDeviceCard

                // Live Test Card
                liveTestCard

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
            // Reload if changed externally
            if !isTestingVoice {
                loadSettings()
            }
        }
    }

    // MARK: - Info Card

    private var infoCard: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundColor(theme.accentColor)

            Text("These settings apply to all voice modes: Voice Input, Transcription, and VAD Mode.")
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.accentColor.opacity(0.1))
        )
    }

    // MARK: - Sensitivity Settings Card

    private var sensitivitySettingsCard: some View {
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
                    Text("Voice Sensitivity")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Text("Adjust how sensitive voice detection is")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()
            }

            // Sensitivity Picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Sensitivity Level")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                HStack(spacing: 0) {
                    ForEach(VoiceSensitivity.allCases, id: \.self) { level in
                        Button(action: {
                            sensitivity = level
                            saveSettings()
                        }) {
                            Text(level.displayName)
                                .font(.system(size: 13, weight: sensitivity == level ? .semibold : .medium))
                                .foregroundColor(
                                    sensitivity == level
                                        ? (theme.isDark ? theme.primaryBackground : .white)
                                        : theme.primaryText
                                )
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(sensitivity == level ? theme.accentColor : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    }
                }
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.tertiaryBackground)
                )

                Text(sensitivity.description)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }

            // Additional info
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundColor(theme.accentColor)
                Text("Affects pause detection, wake word detection, and voice activity thresholds")
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

    // MARK: - Input Device Card

    private var inputDeviceCard: some View {
        VStack(alignment: .leading, spacing: 16) {
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

            // Input Source Picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Input Source")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                HStack(spacing: 8) {
                    ForEach(AudioInputSource.allCases, id: \.self) { source in
                        let isSelected = audioInputManager.selectedInputSource == source
                        let isDisabled = source == .systemAudio && !systemAudioManager.isAvailable

                        Button(action: {
                            if !isDisabled {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    audioInputManager.selectedInputSource = source
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
                                isDisabled
                                    ? theme.tertiaryText
                                    : (isSelected
                                        ? (theme.isDark ? theme.primaryBackground : .white) : theme.primaryText)
                            )
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isSelected ? theme.accentColor : theme.tertiaryBackground)
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(isDisabled)
                    }

                    Spacer()
                }
            }

            // Device picker (microphone mode only)
            if audioInputManager.selectedInputSource == .microphone {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select Input Device")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    Menu {
                        Button(action: { audioInputManager.selectDevice(nil) }) {
                            HStack {
                                Text("System Default")
                                if audioInputManager.selectedDeviceId == nil {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }

                        Divider()

                        ForEach(audioInputManager.availableDevices) { device in
                            Button(action: { audioInputManager.selectDevice(device.id) }) {
                                HStack {
                                    Text(device.name)
                                    if device.isDefault {
                                        Text("(Default)")
                                            .foregroundColor(.secondary)
                                    }
                                    if audioInputManager.selectedDeviceId == device.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 14))
                                .foregroundColor(theme.accentColor)

                            Text(selectedDeviceName)
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
                                        .stroke(theme.inputBorder, lineWidth: 1)
                                )
                        )
                    }
                    .menuStyle(.borderlessButton)
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

    private var inputSourceDescription: String {
        switch audioInputManager.selectedInputSource {
        case .microphone:
            return audioInputManager.selectedDevice?.name ?? "System Default"
        case .systemAudio:
            return systemAudioManager.hasPermission ? "Computer audio" : "Permission required"
        }
    }

    private var selectedDeviceName: String {
        if let selectedId = audioInputManager.selectedDeviceId,
            let device = audioInputManager.availableDevices.first(where: { $0.id == selectedId })
        {
            return device.name
        }
        return "System Default"
    }

    // MARK: - Live Test Card

    private var liveTestCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Live Test")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Spacer()

                if isTestingVoice {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(theme.errorColor)
                            .frame(width: 8, height: 8)
                            .modifier(AudioSettingsPulseModifier())
                        Text("RECORDING")
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

            Text("Test your audio settings with live voice transcription")
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)

            // Waveform
            if isTestingVoice {
                WaveformView(level: speechService.audioLevel, style: .bars, barCount: 24)
                    .frame(height: 48)
            }

            // Transcription display
            VStack(alignment: .leading, spacing: 8) {
                let displayText: String = {
                    guard isTestingVoice else { return "" }
                    return speechService.confirmedTranscription.isEmpty
                        ? speechService.currentTranscription
                        : speechService.confirmedTranscription + " " + speechService.currentTranscription
                }()

                Text(displayText.isEmpty ? "Speak and see your words here..." : displayText)
                    .font(.system(size: 15))
                    .foregroundColor(displayText.isEmpty ? theme.tertiaryText : theme.primaryText)
                    .italic(displayText.isEmpty)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                isTestingVoice ? theme.accentColor.opacity(0.5) : theme.inputBorder,
                                lineWidth: isTestingVoice ? 2 : 1
                            )
                    )
            )

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
                        Image(systemName: isTestingVoice ? "stop.fill" : "mic.fill")
                            .font(.system(size: 14))
                        Text(isTestingVoice ? "Stop" : "Start Test")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundColor(
                        isTestingVoice
                            ? Color.white
                            : (theme.isDark ? theme.primaryBackground : Color.white)
                    )
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(isTestingVoice ? theme.errorColor : theme.accentColor)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!speechService.isModelLoaded || speechService.isLoadingModel)
                .opacity(speechService.isModelLoaded ? 1 : 0.5)

                if !speechService.confirmedTranscription.isEmpty || !speechService.currentTranscription.isEmpty {
                    Button(action: { speechService.clearTranscription() }) {
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
    }

    private func toggleTest() {
        if isTestingVoice {
            Task {
                _ = await speechService.stopStreamingTranscription()
                isTestingVoice = false
            }
        } else {
            testError = nil
            Task {
                do {
                    try await speechService.startStreamingTranscription()
                    isTestingVoice = true
                } catch {
                    testError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Pulse Animation Modifier

private struct AudioSettingsPulseModifier: ViewModifier {
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
    struct AudioSettingsTab_Previews: PreviewProvider {
        static var previews: some View {
            AudioSettingsTab()
                .frame(width: 700, height: 900)
                .themedBackground()
        }
    }
#endif
