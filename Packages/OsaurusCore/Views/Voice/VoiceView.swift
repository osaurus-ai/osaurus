//
//  VoiceView.swift
//  osaurus
//
//  Main Voice management view with sub-tabs for setup, voice input settings,
//  VAD mode configuration, and model management.
//

import SwiftUI

// MARK: - Voice Tab Enum

enum VoiceTab: String, CaseIterable, AnimatedTabItem {
    case setup = "Setup"
    case speechToText = "Speech To Text"
    case textToSpeech = "Text To Speech"
    case vadMode = "VAD Mode"
    case models = "Models"

    var title: String {
        switch self {
        case .setup: return L("Setup")
        case .speechToText: return L("Speech To Text")
        case .textToSpeech: return L("Text To Speech")
        case .vadMode: return L("VAD Mode")
        case .models: return L("Models")
        }
    }
}

// MARK: - Voice View

struct VoiceView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    // Deliberately NOT `@ObservedObject` here. SpeechService republishes
    // on every audio-level meter tick + every load-progress chunk,
    // which would force a re-evaluation of the whole VoiceView shell
    // (header, sidebar tab counts, tab content) at high frequency.
    // The two indicators that actually need live SpeechService state
    // live in dedicated `VoiceStatusIndicator` / audio-meter subviews
    // that observe it locally. `microphonePermissionGranted` is read
    // directly off the singleton — it changes rarely (system prompt)
    // and the next published mutation on `modelManager` will pick up
    // any change for the header subtitle.
    private let speechService = SpeechService.shared
    @ObservedObject private var modelManager = SpeechModelManager.shared
    @ObservedObject private var managementState = ManagementStateManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var selectedTab: VoiceTab = .setup
    @State private var hasAppeared = false

    /// Whether setup is complete (permissions granted + model downloaded)
    private var isSetupComplete: Bool {
        speechService.microphonePermissionGranted && modelManager.downloadedModelsCount > 0
            && modelManager.selectedModel != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
                .managerHeaderEntrance(hasAppeared: hasAppeared)

            // Content based on tab
            Group {
                switch selectedTab {
                case .setup:
                    VoiceSetupTab(onComplete: { selectedTab = .speechToText })
                case .speechToText:
                    TranscriptionModeSettingsTab()
                case .vadMode:
                    VADModeSettingsTab()
                case .textToSpeech:
                    TTSModeSettingsTab()
                case .models:
                    VoiceModelsTab()
                }
            }
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            // Honour an explicit cross-view request (e.g. from the chat speaker button).
            if let requested = managementState.voiceSubTabRequest,
                let tab = VoiceTab(rawValue: requested)
            {
                selectedTab = tab
                managementState.voiceSubTabRequest = nil
            } else if isSetupComplete {
                selectedTab = .speechToText
            } else {
                selectedTab = .setup
            }
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
        .onChange(of: managementState.voiceSubTabRequest) { _, newValue in
            guard let requested = newValue, let tab = VoiceTab(rawValue: requested) else { return }
            selectedTab = tab
            managementState.voiceSubTabRequest = nil
        }
    }

    // MARK: - Header View

    private var headerView: some View {
        ManagerHeaderWithTabs(
            title: L("Voice"),
            subtitle: headerSubtitle
        ) {
            VoiceHeaderStatusIndicator(isSetupComplete: isSetupComplete)
        } tabsRow: {
            HeaderTabsRow(
                selection: $selectedTab,
                counts: [
                    .models: modelManager.downloadedModelsCount
                ]
            )
        }
    }

    private var headerSubtitle: String {
        if !isSetupComplete {
            return L("Complete setup to enable voice")
        } else if modelManager.downloadedModelsCount > 0 {
            return L("\(modelManager.downloadedModelsCount) models • \(modelManager.totalDownloadedSizeString)")
        } else {
            return L("Voice transcription ready")
        }
    }

}

// MARK: - Voice Status Indicator

/// Header status pill for the Voice tab. Observes `SpeechService` here
/// (instead of at the `VoiceView` root) so the high-frequency
/// `objectWillChange` publishes that drive the model-load progress and
/// audio-level meter only re-render this small pill, not the entire
/// Voice settings shell. Named `…HeaderStatusIndicator` to avoid the
/// public `VoiceStatusIndicator` in `VoiceComponents.swift`.
private struct VoiceHeaderStatusIndicator: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var speechService = SpeechService.shared

    let isSetupComplete: Bool

    var body: some View {
        if speechService.isLoadingModel {
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.6)
                Text("Loading...", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(theme.tertiaryBackground)
            )
        } else if speechService.isModelLoaded {
            HStack(spacing: 6) {
                Circle()
                    .fill(theme.successColor)
                    .frame(width: 8, height: 8)
                Text("Ready", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.successColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(theme.successColor.opacity(0.1))
            )
        } else if !isSetupComplete {
            HStack(spacing: 6) {
                Circle()
                    .fill(theme.warningColor)
                    .frame(width: 8, height: 8)
                Text("Setup Required", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.warningColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(theme.warningColor.opacity(0.1))
            )
        }
    }
}

// MARK: - Voice Models Tab

private struct VoiceModelsTab: View {
    @ObservedObject private var modelManager = SpeechModelManager.shared

    /// Curated speech models, recommended first so the default stays on top.
    /// Recomputed off `objectWillChange` (not per body render) so the
    /// high-frequency download-progress publishes don't re-walk it each frame.
    @State private var orderedModels: [SpeechModel] = []

    private func isInstalled(_ model: SpeechModel) -> Bool {
        modelManager.effectiveDownloadState(for: model) == .completed
    }

    private var installed: [SpeechModel] { orderedModels.filter(isInstalled) }
    private var available: [SpeechModel] { orderedModels.filter { !isInstalled($0) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Legacy WhisperKit cleanup banner
                if modelManager.legacyWhisperModelsExist {
                    LegacyWhisperBanner()
                }

                if !installed.isEmpty {
                    SettingsSection(title: "Installed", icon: "checkmark.seal.fill") {
                        VStack(spacing: 8) {
                            ForEach(installed) { SpeechModelListRow(model: $0) }
                        }
                    }
                }

                if !available.isEmpty {
                    SettingsSection(title: "Available", icon: "square.and.arrow.down") {
                        VStack(spacing: 8) {
                            ForEach(available) { SpeechModelListRow(model: $0) }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .onAppear { refreshModels() }
        .onReceive(modelManager.objectWillChange) { _ in
            // SpeechModelManager publishes per download progress chunk; the
            // single ordering pass over the small list is cheap.
            refreshModels()
        }
    }

    private func refreshModels() {
        let all = modelManager.availableModels
        orderedModels = all.filter { $0.isRecommended } + all.filter { !$0.isRecommended }
    }
}

// MARK: - Legacy WhisperKit Cleanup Banner

private struct LegacyWhisperBanner: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var modelManager = SpeechModelManager.shared
    @State private var isDeleting = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundColor(theme.warningColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Legacy WhisperKit models found", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text(
                    "These models are no longer used. Delete to free up \(modelManager.legacyWhisperModelsSizeString ?? "disk space").",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
            }

            Spacer()

            Button(action: {
                isDeleting = true
                modelManager.deleteLegacyWhisperModels()
                isDeleting = false
            }) {
                if isDeleting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Delete", bundle: .module)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.errorColor)
                        )
                }
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isDeleting)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.warningColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.warningColor.opacity(0.25), lineWidth: 1)
                )
        )
    }
}

// MARK: - Speech Model Row

/// Adapts a Parakeet `SpeechModel` onto the shared `ModelListRow`: maps the
/// speech-specific download state into the row's status, surfaces the EN /
/// Default badges, and wires Download / Retry / Set as Default / Delete.
private struct SpeechModelListRow: View {
    @ObservedObject private var modelManager = SpeechModelManager.shared
    @Environment(\.theme) private var theme

    let model: SpeechModel

    private var downloadState: SpeechDownloadState {
        modelManager.effectiveDownloadState(for: model)
    }

    private var isCompleted: Bool { downloadState == .completed }
    private var isSelected: Bool { modelManager.selectedModelId == model.id }

    var body: some View {
        ModelListRow(
            title: model.name,
            subtitle: "\(model.description) · \(model.size)",
            leading: leading,
            badges: model.isEnglishOnly ? [ModelBadge.Item(text: L("EN"), style: .neutral)] : [],
            isDefault: isSelected && isCompleted,
            status: status,
            primary: primaryAction,
            menuItems: menuItems,
            onCancel: { modelManager.cancelDownload(model.id) }
        )
    }

    private var leading: ModelListRow.Leading {
        switch downloadState {
        case .completed: return .init(icon: "waveform", tint: theme.successColor)
        case .downloading: return .init(icon: "arrow.down.circle", tint: theme.accentColor)
        case .failed: return .init(icon: "exclamationmark.triangle", tint: theme.errorColor)
        case .notStarted: return .init(icon: "waveform.circle", tint: theme.secondaryText)
        }
    }

    private var status: ModelListRow.Status {
        switch downloadState {
        case .notStarted: return .idle
        case .downloading(let progress): return .inProgress(progress: progress, detail: nil)
        case .completed: return .ready
        case .failed(let error): return .failed(error)
        }
    }

    private var primaryAction: ModelListRow.Action? {
        switch downloadState {
        case .notStarted:
            return ModelListRow.Action(title: "Download", icon: "arrow.down.circle") {
                modelManager.downloadModel(model)
            }
        case .failed:
            return ModelListRow.Action(title: "Retry", icon: "arrow.clockwise") {
                modelManager.downloadModel(model)
            }
        case .completed:
            return isSelected
                ? nil
                : ModelListRow.Action(title: "Set as Default", icon: "checkmark.circle") {
                    modelManager.setDefaultModel(model.id)
                }
        case .downloading:
            return nil
        }
    }

    private var menuItems: [ModelListRow.Action] {
        guard isCompleted else { return [] }
        return [
            ModelListRow.Action(title: "Delete", icon: "trash", role: .destructive) {
                modelManager.deleteModel(model)
            }
        ]
    }
}

// MARK: - Preview

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        VoiceView()
    }
#endif
