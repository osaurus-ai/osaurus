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
    @State private var remoteAPIKey: String = ""

    private enum ConnectionTestState: Equatable {
        case idle, testing, success
        case failure(String)
    }
    @State private var connectionTest: ConnectionTestState = .idle
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
        // Keychain reads are blocking XPC; fetch off-main and fill the field
        // when it lands. Skip the update when unchanged so the `.onChange`
        // save/reset handlers don't fire from our own load.
        TTSRemoteAPIKeyStore.load { key in
            let value = key ?? ""
            if value != remoteAPIKey { remoteAPIKey = value }
        }
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
            SettingsPageContent {
                enableCard

                if config.provider == .pocketTTS {
                    modelCard
                }

                if config.enabled && config.provider == .pocketTTS {
                    voiceCard
                }

                if config.enabled && ttsService.isModelReady {
                    previewCard
                }

                // Engine choice + remote server fields are power-user knobs;
                // the on-device default needs none of them.
                if config.enabled {
                    advancedSection
                }

                Spacer()
            }
        }
        .onAppear {
            if !hasLoadedSettings {
                loadSettings()
                hasLoadedSettings = true
            }
            // Probe only: loading compiles a ~700 MB CoreML model, which
            // happens on first speak or from the Load button.
            ttsService.probeModelFiles()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ttsConfigurationChanged)) { _ in
            loadSettings()
        }
    }

    // MARK: - Enable Card

    private var enableCard: some View {
        SettingsSection(title: "Text-to-Speech") {
            SettingsToggle(
                title: "Enable Text-to-Speech",
                description: config.enabled
                    ? "Speaker button appears on assistant messages"
                    : "Enable to read assistant replies aloud",
                isOn: $config.enabled
            )
            .onChange(of: config.enabled) { _, _ in saveSettings() }
        }
    }

    // MARK: - Model Card

    private var modelCard: some View {
        SettingsSection(title: "PocketTTS Model") {
            SettingsRow(title: "PocketTTS", description: modelStatusText, verbatimTitle: true, verbatimDescription: true) {
                Image(systemName: modelIconName)
                    .glyphSize(.medium, weight: .medium)
                    .foregroundColor(modelIconColor)
            } trailing: {
                modelAction
            }

            if case .downloading(let fraction) = ttsService.modelState {
                downloadProgressBar(fraction: fraction)
            }
        }
    }

    @ViewBuilder
    private func downloadProgressBar(fraction: Double?) -> some View {
        if let fraction {
            SettingsProgressBar(value: fraction, tint: theme.action.primary.default.background)
        } else {
            SettingsProgressBar(value: nil, tint: theme.action.primary.default.background)
        }
    }

    private var modelStatusText: String {
        switch ttsService.modelState {
        case .notReady:
            return ttsService.modelFilesOnDisk
                ? L("Downloaded — loads the first time Osaurus speaks")
                : L("Not downloaded — about 700 MB")
        case .downloading(let fraction):
            if let fraction {
                return String(format: "%@ %d%%", L("Downloading"), Int(fraction * 100))
            }
            return L("Preparing…")
        case .ready: return L("Runs on this Mac. English only. Streams audio as it's synthesized.")
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
        case .ready: return theme.status.success.foreground
        case .downloading: return theme.status.info.foreground
        case .failed: return theme.status.error.foreground
        case .notReady: return theme.text.secondary
        }
    }

    @ViewBuilder
    private var modelAction: some View {
        switch ttsService.modelState {
        case .notReady where ttsService.modelFilesOnDisk:
            Button(action: { ttsService.ensureModelLoaded() }) {
                Text("Load Now", bundle: .module)
            }
            .assignedSettingsButtonStyle(.secondary)

        case .notReady, .failed:
            SettingsButton(.primary, "Download", icon: "arrow.down") { ttsService.ensureModelLoaded() }

        case .downloading:
            SettingsSpinner()

        case .ready:
            StatusChip(L("Ready"), tone: .success, showsDot: true)
        }
    }

    // MARK: - Voice Card

    private var voiceCard: some View {
        SettingsSection(title: "Voice", anchorId: "voice.tts.voice") {
            SettingsPickerRow(
                title: "Voice",
                style: .menu,
                selection: $config.voice,
                options: voiceMenuOptions.map { .init($0, displayName(for: $0), verbatim: true) }
            )
            .onChange(of: config.voice) { _, _ in saveSettings() }

            SettingsSlider(
                title: "Temperature",
                valueText: String(format: "%.2f", config.temperature),
                value: $config.temperature,
                range: 0.1 ... 1.2,
                step: 0.05,
                anchorId: "voice.tts.temperature"
            ) { editing in
                if !editing { saveSettings() }
            }
        }
    }

    // MARK: - Advanced (engine + remote server)

    private static let advancedAnchorIds: Set<String> = ["voice.tts.engine", "voice.tts.remote"]

    private var advancedSection: some View {
        SettingsAdvancedDisclosure(anchorIds: Self.advancedAnchorIds) {
            SettingsPickerRow(
                title: "Engine",
                description: config.provider == .openAICompatible
                    ? "Sends text to any server implementing the OpenAI /v1/audio/speech API, such as openai-edge-tts or Kokoro."
                    : "On-device PocketTTS needs no setup. Choose a server to use any OpenAI-compatible speech API.",
                anchorId: "voice.tts.engine",
                style: .menu,
                selection: $config.provider,
                options: [
                    .init(TTSProvider.pocketTTS, L("On-Device (PocketTTS)")),
                    .init(TTSProvider.openAICompatible, L("OpenAI-Compatible Server")),
                ]
            )
            // The server fields only render for the remote engine; until then
            // their search result lands on the picker that reveals them.
            .settingsLandingAnchor(config.provider == .openAICompatible ? nil : "voice.tts.remote")

            if config.provider == .openAICompatible {
                remoteServerCard
            }
        }
        // Outside the picker: its landing anchor changes identity with the
        // provider, which would reset a handler attached to it.
        .onChange(of: config.provider) { _, _ in saveSettings() }
    }

    // MARK: - Remote Server Card

    /// Rows of the Advanced card; a nested section would draw a card inside it.
    @ViewBuilder
    private var remoteServerCard: some View {
        SettingsFieldRow(label: "Endpoint", anchorId: "voice.tts.remote") {
            SettingsTextField(placeholder: TTSConfiguration.defaultRemoteEndpoint, text: $config.remoteEndpoint)
                .onChange(of: config.remoteEndpoint) { _, _ in
                    connectionTest = .idle
                    saveSettings()
                }
        }

        SettingsFieldRow(label: "Model") {
            SettingsTextField(placeholder: TTSConfiguration.defaultRemoteModel, text: $config.remoteModel)
                .onChange(of: config.remoteModel) { _, _ in
                    connectionTest = .idle
                    saveSettings()
                }
        }

        SettingsFieldRow(label: "Voice") {
            SettingsTextField(placeholder: TTSConfiguration.defaultRemoteVoice, text: $config.remoteVoice)
                .onChange(of: config.remoteVoice) { _, _ in
                    connectionTest = .idle
                    saveSettings()
                }
        }

        SettingsFieldRow(label: "API Key") {
            SettingsTextField(placeholder: L("Optional"), text: $remoteAPIKey, isSecure: true)
                .onChange(of: remoteAPIKey) { _, newValue in
                    connectionTest = .idle
                    TTSRemoteAPIKeyStore.save(newValue)
                }
        }

        SettingsSlider(
            title: "Speed",
            valueText: String(format: "%.2fx", config.remoteSpeed),
            value: $config.remoteSpeed,
            range: 0.25 ... 4.0,
            step: 0.05
        ) { editing in
            if !editing { saveSettings() }
        }

        VStack(alignment: .leading, spacing: theme.space.s8) {
            connectionTestRow
            if let error = ttsService.lastRemoteError {
                HStack(alignment: .top, spacing: theme.space.s8) {
                    Image(systemName: "exclamationmark.triangle")
                        .glyphSize(.caption)
                        .foregroundColor(theme.status.error.foreground)
                    Text(error)
                        .font(SettingsFont.caption)
                        .foregroundColor(theme.status.error.foreground)
                }
            }
        }
    }

    private var connectionTestRow: some View {
        HStack(spacing: theme.space.s10) {
            switch connectionTest {
            case .idle, .testing:
                EmptyView()
            case .success:
                HStack(spacing: theme.space.s6) {
                    Image(systemName: "checkmark.circle.fill")
                        .glyphSize(.caption)
                        .foregroundColor(theme.status.success.foreground)
                    Text("Connected", bundle: .module)
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.status.success.foreground)
                }
            case .failure(let message):
                HStack(alignment: .top, spacing: theme.space.s6) {
                    Image(systemName: "xmark.circle.fill")
                        .glyphSize(.caption)
                        .foregroundColor(theme.status.error.foreground)
                    Text(message)
                        .font(SettingsFont.caption)
                        .foregroundColor(theme.status.error.foreground)
                        .lineLimit(3)
                }
            }

            Spacer()

            SettingsButton(
                .secondary,
                "Test Connection",
                isLoading: connectionTest == .testing,
                size: .compact,
                action: runConnectionTest
            )
        }
    }

    private func runConnectionTest() {
        guard connectionTest != .testing else { return }
        connectionTest = .testing
        let trimmedKey = remoteAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = OpenAICompatibleTTSClient(
            endpoint: config.remoteEndpoint,
            model: config.remoteModel,
            voice: config.remoteVoice,
            speed: config.remoteSpeed,
            apiKey: trimmedKey.isEmpty ? nil : trimmedKey
        )
        Task {
            do {
                try await client.verifyConnection()
                connectionTest = .success
            } catch {
                connectionTest = .failure(error.localizedDescription)
            }
        }
    }

    // MARK: - Preview Card

    private var previewCard: some View {
        SettingsSection(title: "Preview") {
            VStack(alignment: .leading, spacing: theme.space.s12) {
                SettingsTextEditor(text: $previewText, minHeight: 60)

                HStack {
                    Spacer()
                    let isPlaying = ttsService.playingMessageId == previewMessageId
                    SettingsButton(.primary, isPlaying ? "Stop" : "Play", icon: isPlaying ? "stop.fill" : "play.fill") {
                        if isPlaying {
                            ttsService.stop()
                        } else {
                            ttsService.toggleSpeak(text: previewText, messageId: previewMessageId)
                        }
                    }
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
