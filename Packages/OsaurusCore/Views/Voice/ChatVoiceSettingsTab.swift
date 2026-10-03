//
//  ChatVoiceSettingsTab.swift
//  osaurus
//
//  Voice → Chat Voice: the microphone button inside the chat composer.
//  Deliberately tiny — one switch plus a pointer to the Transcription tab,
//  which owns the shared stop / pause / cleanup behaviour for both chat
//  voice input and system-wide Transcription Mode.
//

import SwiftUI

struct ChatVoiceSettingsTab: View {
    @Environment(\.theme) private var theme

    @State private var voiceInputEnabled: Bool = true
    @State private var hasLoadedSettings = false

    private func loadSettings() {
        voiceInputEnabled = SpeechConfigurationStore.load().voiceInputEnabled
    }

    private func saveSettings() {
        var config = SpeechConfigurationStore.load()
        config.voiceInputEnabled = voiceInputEnabled
        SpeechConfigurationStore.save(config)
        NotificationCenter.default.post(name: .voiceConfigurationChanged, object: nil)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                SettingsSection(title: "Voice Input in Chat", icon: "mic") {
                    SettingsToggle(
                        title: L("Enable Voice Input"),
                        description: voiceInputEnabled
                            ? L("Microphone button enabled in chat input")
                            : L("Enable microphone button in the chat input area"),
                        anchorId: "voice.chat.enable",
                        isOn: $voiceInputEnabled
                    )
                    .onChange(of: voiceInputEnabled) { _, _ in saveSettings() }

                    if voiceInputEnabled {
                        VoiceInfoBox("A microphone button will appear in the chat input when voice is ready")
                    }

                    SettingsLinkRow(
                        title: "Stop Behavior & Cleanup",
                        description:
                            "How Osaurus knows you've finished speaking, and whether it tidies up filler words. Shared with Transcription Mode.",
                        icon: "arrow.right",
                        actionTitle: "Open Transcription"
                    ) {
                        ManagementStateManager.shared.voiceSubTabRequest = VoiceTab.transcription.rawValue
                    }
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
    }
}
