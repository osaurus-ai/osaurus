//
//  VoiceView.swift
//  osaurus
//
//  Capabilities → Voice. The overview holds the everyday switch (voice input
//  in chat) and drill-in rows for Setup, Transcription, Text to Speech and
//  Wake Word. Speech models download from Local Models → Speech; the default
//  speech model is chosen in Model Defaults.
//

import SwiftUI

// MARK: - Voice Tab Enum

/// Voice items. Raw values are stable deep-link ids (`voiceSubTabRequest`,
/// settings-search `subTab`) and are deliberately not renamed when the
/// visible title changes; use `resolved(from:)` to accept older spellings.
/// `speechToText` (the retired Chat Voice tab) lands on the overview, where
/// its switch now lives; `models` opens Local Models → Speech.
enum VoiceTab: String, CaseIterable, SettingsDrillInItem {
    case setup = "Setup"
    case speechToText = "Speech To Text"
    case transcription = "Transcription"
    case textToSpeech = "Text To Speech"
    case vadMode = "VAD Mode"
    case models = "Models"

    var id: String { rawValue }

    /// Items listed as drill-in rows on the overview.
    static let drillInItems: [VoiceTab] = [.setup, .transcription, .textToSpeech, .vadMode]

    var title: String {
        switch self {
        case .setup: return L("Setup")
        case .speechToText: return L("Voice Input in Chat")
        case .transcription: return L("Transcription")
        case .textToSpeech: return L("Text to Speech")
        case .vadMode: return L("Wake Word")
        case .models: return L("Speech Models")
        }
    }

    var icon: String {
        switch self {
        case .setup: return "checklist"
        case .speechToText: return "mic.fill"
        case .transcription: return "text.cursor"
        case .textToSpeech: return "speaker.wave.2.fill"
        case .vadMode: return "ear.fill"
        case .models: return "waveform"
        }
    }

    var subtitle: String {
        switch self {
        case .setup: return L("Microphone, speech model, input device and sensitivity. Test your voice here.")
        case .speechToText: return ""
        case .transcription: return L("Dictate into any app with a hotkey; how Osaurus knows you've finished.")
        case .textToSpeech: return L("Read replies aloud: voice, engine and preview.")
        case .vadMode: return L("Start a chat by saying an agent's wake phrase.")
        case .models: return L("Download and manage on-device speech models.")
        }
    }

    /// Resolves a deep-link raw value, accepting the visible titles and the
    /// legacy names so older settings links and guide paths keep working.
    static func resolved(from rawValue: String) -> VoiceTab? {
        if let tab = VoiceTab(rawValue: rawValue) { return tab }
        switch rawValue.lowercased() {
        case "chat voice", "chat", "speech to text", "stt", "voice input in chat": return .speechToText
        case "transcription mode", "dictation": return .transcription
        case "wake word", "vad", "vad mode": return .vadMode
        case "tts", "text to speech": return .textToSpeech
        case "speech models", "models": return .models
        default: return nil
        }
    }
}

// MARK: - Voice View

struct VoiceView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    // Deliberately NOT `@ObservedObject`: SpeechService republishes on every
    // audio-level meter tick, which would re-render the whole page. The live
    // status pill observes it locally.
    private let speechService = SpeechService.shared
    @ObservedObject private var modelManager = SpeechModelManager.shared
    @ObservedObject private var managementState = ManagementStateManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var selection: VoiceTab?
    @State private var voiceInputEnabled = SpeechConfigurationStore.load().voiceInputEnabled

    private var isSetupComplete: Bool {
        speechService.microphonePermissionGranted && modelManager.downloadedModelsCount > 0
            && modelManager.selectedModel != nil
    }

    var body: some View {
        SettingsDrillInHost(rootTitle: L("Voice"), selection: $selection) {
            overview
        } detail: { item in
            detail(item)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.canvas)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            if let requested = managementState.voiceSubTabRequest {
                apply(requested)
            } else if !isSetupComplete {
                selection = .setup
            }
        }
        .onChange(of: managementState.voiceSubTabRequest) { _, newValue in
            if let newValue { apply(newValue) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .voiceConfigurationChanged)) { _ in
            voiceInputEnabled = SpeechConfigurationStore.load().voiceInputEnabled
        }
    }

    private func apply(_ requested: String) {
        managementState.voiceSubTabRequest = nil
        switch VoiceTab.resolved(from: requested) {
        case .speechToText: selection = nil
        case .models: managementState.openLocalModels(kind: .speech)
        case let tab?: selection = tab
        case nil: break
        }
    }

    // MARK: Overview

    private var overview: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "Voice",
                subtitle: headerSubtitle,
                status: { VoiceHeaderStatusIndicator(isSetupComplete: isSetupComplete) }
            )
        } content: {
            SettingsGroup {
                SettingsToggle(
                    title: "Voice Input in Chat",
                    description: voiceInputEnabled
                        ? "A microphone button appears in the chat input when voice is ready."
                        : "Show a microphone button in the chat input area.",
                    anchorId: "voice.chat.enable",
                    isOn: $voiceInputEnabled
                )
                .onChange(of: voiceInputEnabled) { _, newValue in
                    var config = SpeechConfigurationStore.load()
                    guard config.voiceInputEnabled != newValue else { return }
                    config.voiceInputEnabled = newValue
                    SpeechConfigurationStore.save(config)
                    NotificationCenter.default.post(name: .voiceConfigurationChanged, object: nil)
                }
            }

            SettingsDrillInList(items: VoiceTab.drillInItems) { selection = $0 }

            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionHeader(title: "Models")
                SettingsGroup {
                    SettingsNavigationRow(
                        icon: VoiceTab.models.icon,
                        title: VoiceTab.models.title,
                        subtitle: VoiceTab.models.subtitle,
                        badge: modelManager.downloadedModelsCount,
                        anchorId: "voice.models"
                    ) {
                        managementState.openLocalModels(kind: .speech)
                    }
                    SettingsNavigationRow(
                        icon: ManagementTab.modelDefaults.icon,
                        title: "Default Speech Model",
                        subtitle: modelManager.selectedModel?.name ?? L("Not chosen yet")
                    ) {
                        managementState.selectedTab = .modelDefaults
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func detail(_ item: VoiceTab) -> some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                SettingsPageHeader(title: item.title, subtitle: item.subtitle)
                switch item {
                case .setup, .speechToText, .models:
                    VoiceSetupTab(onComplete: { selection = nil })
                case .transcription:
                    TranscriptionSettingsTab()
                case .vadMode:
                    VADModeSettingsTab()
                case .textToSpeech:
                    TTSModeSettingsTab()
                }
            }
            .settingsLandingScroll(proxy)
        }
    }

    private var headerSubtitle: String {
        if !isSetupComplete {
            return L("Complete setup to enable voice")
        } else if modelManager.downloadedModelsCount > 0 {
            let count = modelManager.downloadedModelsCount
            return count == 1
                ? L("1 model • \(modelManager.totalDownloadedSizeString)")
                : L("\(count) models • \(modelManager.totalDownloadedSizeString)")
        } else {
            return L("Voice transcription ready")
        }
    }
}

// MARK: - Voice Status Indicator

/// Header status pill for the Voice page. Observes `SpeechService` here
/// (instead of at the `VoiceView` root) so the high-frequency publishes only
/// re-render this small pill.
private struct VoiceHeaderStatusIndicator: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var speechService = SpeechService.shared

    let isSetupComplete: Bool

    var body: some View {
        if !isSetupComplete {
            StatusChip(L("Setup Required"), tone: .warning, showsDot: true)
        } else if speechService.isLoadingModel {
            StatusChip(L("Loading..."), icon: "hourglass")
        } else if speechService.isModelLoaded {
            StatusChip(L("Ready"), tone: .success, showsDot: true)
        }
    }

}

// MARK: - Preview

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        VoiceView()
    }
#endif
