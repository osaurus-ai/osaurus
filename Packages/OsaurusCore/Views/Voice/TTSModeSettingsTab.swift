//
//  TTSModeSettingsTab.swift
//  osaurus
//
//  Settings UI for text-to-speech (PocketTTS).
//  Toggle TTS, pick voice/temperature, download model, preview.
//

import SwiftUI

struct TTSModeSettingsTab: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var ttsService = TTSService.shared

    @State private var config: TTSConfiguration = .default
    @State private var hasLoadedSettings = false
    @State private var previewText: String = "Hello from Osaurus. Text to speech is now ready."
    @State private var previewMessageId = UUID()

    private func displayName(for voice: String) -> String {
        PocketTTSVoiceCatalog.displayName(for: voice)
    }

    private var voiceMenuOptions: [String] {
        let builtIn = PocketTTSVoiceCatalog.availableVoices
        let current = config.voice.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty && !builtIn.contains(current) {
            return [current] + builtIn
        }
        return builtIn
    }

    private func loadSettings() {
        config = TTSConfigurationStore.load()
    }

    private func saveSettings() {
        TTSConfigurationStore.save(config)
    }

    private var canPreview: Bool {
        config.enabled && ttsService.isModelReady
            && !previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                enableCard

                modelCard

                if config.enabled {
                    voiceCard
                }

                if config.enabled && ttsService.isModelReady {
                    previewCard
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
            ttsService.refreshModelState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ttsConfigurationChanged)) { _ in
            loadSettings()
        }
    }

    // MARK: - Enable Card

    private var enableCard: some View {
        SettingsSection(title: "Text-to-Speech", icon: "speaker.wave.2") {
            VStack(alignment: .leading, spacing: 12) {
                SettingsToggle(
                    title: L("Enable Text-to-Speech"),
                    description: config.enabled
                        ? "Speaker button appears on assistant messages"
                        : "Enable to read assistant replies aloud",
                    isOn: $config.enabled
                )
                .onChange(of: config.enabled) { _, _ in saveSettings() }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundColor(theme.accentColor)

                    Text(
                        "Powered by FluidAudio PocketTTS. English only. Streams audio as it's synthesized.",
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
        }
    }

    // MARK: - Model Card

    private var modelCard: some View {
        SettingsSection(title: "PocketTTS Model", icon: "waveform.circle") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: modelIconName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(modelIconColor)

                    Text(modelStatusText)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)

                    Spacer()

                    modelAction
                }

                if case .downloading(let fraction) = ttsService.modelState {
                    downloadProgressBar(fraction: fraction)
                }
            }
        }
    }

    @ViewBuilder
    private func downloadProgressBar(fraction: Double?) -> some View {
        if let fraction {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(theme.accentColor)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .tint(theme.accentColor)
        }
    }

    private var modelStatusText: String {
        switch ttsService.modelState {
        case .notReady: return L("Not downloaded — about 700 MB")
        case .downloading(let fraction):
            if let fraction {
                return String(format: "%@ %d%%", L("Downloading"), Int(fraction * 100))
            }
            return L("Preparing…")
        case .ready: return L("Ready")
        case .failed(let msg): return msg
        }
    }

    private var modelIconName: String {
        switch ttsService.modelState {
        case .ready: return "waveform"
        case .downloading: return "arrow.down.circle"
        case .failed: return "exclamationmark.triangle"
        case .notReady: return "waveform.circle"
        }
    }

    private var modelIconColor: Color {
        switch ttsService.modelState {
        case .ready: return theme.successColor
        case .downloading: return theme.accentColor
        case .failed: return theme.errorColor
        case .notReady: return theme.secondaryText
        }
    }

    private var modelIconBackground: Color {
        switch ttsService.modelState {
        case .ready: return theme.successColor.opacity(0.15)
        case .downloading: return theme.accentColor.opacity(0.15)
        case .failed: return theme.errorColor.opacity(0.15)
        case .notReady: return theme.tertiaryBackground
        }
    }

    @ViewBuilder
    private var modelAction: some View {
        switch ttsService.modelState {
        case .notReady, .failed:
            Button(action: { ttsService.ensureModelLoaded() }) {
                Text("Download", bundle: .module)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.isDark ? theme.primaryBackground : .white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.accentColor)
                    )
            }
            .buttonStyle(PlainButtonStyle())

        case .downloading:
            ProgressView()
                .controlSize(.small)

        case .ready:
            HStack(spacing: 6) {
                Circle()
                    .fill(theme.successColor)
                    .frame(width: 8, height: 8)
                Text("Ready", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.successColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(theme.successColor.opacity(0.1))
            )
        }
    }

    // MARK: - Voice Card

    private var voiceCard: some View {
        SettingsSection(title: "Voice", icon: "person.wave.2", anchorId: "voice.tts.voice") {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Voice", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                    Spacer()
                    Picker("", selection: $config.voice) {
                        ForEach(voiceMenuOptions, id: \.self) { voice in
                            Text(displayName(for: voice)).tag(voice)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(MenuPickerStyle())
                    .frame(maxWidth: 180)
                    .onChange(of: config.voice) { _, _ in saveSettings() }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Temperature", bundle: .module)
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                        Spacer()
                        Text(String(format: "%.2f", config.temperature))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(theme.secondaryText)
                    }
                    Slider(value: $config.temperature, in: 0.1 ... 1.2, step: 0.05) { editing in
                        if !editing { saveSettings() }
                    }
                }
                .settingsLandingAnchor("voice.tts.temperature")
            }
        }
    }

    // MARK: - Preview Card

    private var previewCard: some View {
        SettingsSection(title: "Preview", icon: "play.circle") {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $previewText)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 60)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.tertiaryBackground)
                    )

                HStack {
                    Spacer()
                    Button(action: {
                        if ttsService.playingMessageId == previewMessageId {
                            ttsService.stop()
                        } else {
                            ttsService.toggleSpeak(text: previewText, messageId: previewMessageId)
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(
                                systemName: ttsService.playingMessageId == previewMessageId
                                    ? "stop.fill" : "play.fill"
                            )
                            Text(
                                ttsService.playingMessageId == previewMessageId ? "Stop" : "Play",
                                bundle: .module
                            )
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.isDark ? theme.primaryBackground : .white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(canPreview ? theme.accentColor : theme.tertiaryBackground)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(!canPreview)
                }
            }
        }
    }
}

#if DEBUG
    struct TTSModeSettingsTab_Previews: PreviewProvider {
        static var previews: some View {
            TTSModeSettingsTab()
                .frame(width: 720, height: 640)
        }
    }
#endif
