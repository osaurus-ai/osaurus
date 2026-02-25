//
//  VoiceInputSettingsTab.swift
//  osaurus
//
//  Voice input settings for ChatView integration.
//  Configures pause detection, confirmation delay, and live testing.
//

import SwiftUI

// MARK: - Voice Input Settings Tab

struct VoiceInputSettingsTab: View {
    @Environment(\.theme) private var theme

    // Settings state
    @State private var voiceInputEnabled: Bool = true
    @State private var pauseDuration: Double = 1.5
    @State private var confirmationDelay: Double = 2.0
    @State private var silenceTimeoutSeconds: Double = 30.0
    @State private var hasLoadedSettings = false

    private func loadSettings() {
        let config = SpeechConfigurationStore.load()
        voiceInputEnabled = config.voiceInputEnabled
        pauseDuration = config.pauseDuration
        confirmationDelay = config.confirmationDelay
        silenceTimeoutSeconds = config.silenceTimeoutSeconds
    }

    private func saveSettings() {
        var config = SpeechConfigurationStore.load()
        config.voiceInputEnabled = voiceInputEnabled
        config.pauseDuration = pauseDuration
        config.confirmationDelay = confirmationDelay
        config.silenceTimeoutSeconds = silenceTimeoutSeconds
        SpeechConfigurationStore.save(config)

        // Notify other views of the configuration change
        NotificationCenter.default.post(name: .voiceConfigurationChanged, object: nil)
    }

    /// Formatted display for silence timeout
    private var silenceTimeoutFormatted: String {
        if silenceTimeoutSeconds >= 60 {
            let minutes = Int(silenceTimeoutSeconds) / 60
            let seconds = Int(silenceTimeoutSeconds) % 60
            if seconds == 0 {
                return "\(minutes)m"
            } else {
                return "\(minutes)m \(seconds)s"
            }
        } else {
            return "\(Int(silenceTimeoutSeconds))s"
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Voice Input Toggle Card
                voiceInputToggleCard

                // Auto-Send Settings Card
                autoSendSettingsCard

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
                    Text("Voice Input in Chat")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Text(
                        voiceInputEnabled
                            ? "Microphone button enabled in chat input"
                            : "Enable microphone button in the chat input area"
                    )
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                }

                Spacer()

                Toggle("", isOn: $voiceInputEnabled)
                    .toggleStyle(SwitchToggleStyle(tint: theme.successColor))
                    .labelsHidden()
                    .onChange(of: voiceInputEnabled) { _, _ in
                        saveSettings()
                    }
            }

            if voiceInputEnabled {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundColor(theme.accentColor)
                    Text("A microphone button will appear in the chat input when voice is ready")
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

    // MARK: - Auto-Send Settings Card

    private var autoSendSettingsCard: some View {
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
                    Text("Auto-Send Settings")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Text("Configure how voice messages are sent")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()
            }

            // Pause Duration Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Pause Detection")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)

                    Spacer()

                    Text(pauseDuration == 0 ? "Disabled" : String(format: "%.1fs", pauseDuration))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.accentColor)
                }

                Slider(value: $pauseDuration, in: 0 ... 5, step: 0.5)
                    .tint(theme.accentColor)
                    .onChange(of: pauseDuration) { _, _ in
                        saveSettings()
                    }

                Text(
                    pauseDuration == 0
                        ? "Auto-send disabled. You must manually send voice messages."
                        : "Message will prepare to send after \(String(format: "%.1f", pauseDuration)) seconds of silence"
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            }
            .padding(.top, 8)

            Divider()
                .background(theme.cardBorder)

            // Confirmation Delay Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Confirmation Delay")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)

                    Spacer()

                    Text(String(format: "%.1fs", confirmationDelay))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.accentColor)
                }

                Slider(value: $confirmationDelay, in: 1 ... 5, step: 0.5)
                    .tint(theme.accentColor)
                    .disabled(pauseDuration == 0)
                    .opacity(pauseDuration == 0 ? 0.5 : 1)
                    .onChange(of: confirmationDelay) { _, _ in
                        saveSettings()
                    }

                Text("Time to cancel before message is automatically sent")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }

            Divider()
                .background(theme.cardBorder)

            // Silence Timeout Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Silence Timeout")
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
                        saveSettings()
                    }

                Text("Auto-send or close voice input after this duration of silence")
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

// MARK: - Preview

#if DEBUG
    struct VoiceInputSettingsTab_Previews: PreviewProvider {
        static var previews: some View {
            VoiceInputSettingsTab()
                .frame(width: 700, height: 800)
                .themedBackground()
        }
    }
#endif
