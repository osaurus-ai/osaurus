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

    var title: String { rawValue }
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
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

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
            return "\(modelManager.downloadedModelsCount) models • \(modelManager.totalDownloadedSizeString)"
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
    @Environment(\.theme) private var theme
    @ObservedObject private var modelManager = SpeechModelManager.shared

    @State private var searchText: String = ""

    /// Single-pass output of the filter + partition step. Used to
    /// be three independent computed properties (`filteredModels`,
    /// `recommendedModels`, `otherModels`) that each walked
    /// `availableModels` per body render. With download progress
    /// republishing `modelManager.objectWillChange` at high frequency
    /// during model setup, that meant 3 full-list passes per progress
    /// chunk on top of the per-keystroke search work.
    @State private var partitioned: PartitionedModels = PartitionedModels(
        recommended: [],
        other: []
    )

    private struct PartitionedModels {
        var recommended: [SpeechModel]
        var other: [SpeechModel]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Legacy WhisperKit cleanup banner
                if modelManager.legacyWhisperModelsExist {
                    LegacyWhisperBanner()
                        .padding(.horizontal, 24)
                }

                // Search
                SearchField(text: $searchText, placeholder: "Search models")
                    .padding(.horizontal, 24)

                // Recommended section
                if !partitioned.recommended.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("RECOMMENDED", bundle: .module)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(theme.secondaryText)
                            .tracking(0.5)
                            .padding(.horizontal, 24)

                        VStack(spacing: 12) {
                            ForEach(partitioned.recommended) { model in
                                SpeechModelRow(model: model)
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                }

                // Other models section
                if !partitioned.other.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("ALL MODELS", bundle: .module)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(theme.secondaryText)
                            .tracking(0.5)
                            .padding(.horizontal, 24)

                        VStack(spacing: 12) {
                            ForEach(partitioned.other) { model in
                                SpeechModelRow(model: model)
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                }

                Spacer(minLength: 24)
            }
            .padding(.top, 16)
        }
        .onAppear { refreshPartition() }
        .task(id: searchText) {
            // Debounce search input so partition doesn't run on every
            // keystroke. 150 ms matches the equivalent debounce in
            // ModelDownloadView and keeps the UI feeling live.
            try? await Task.sleep(for: .milliseconds(150))
            if !Task.isCancelled { refreshPartition() }
        }
        .onReceive(modelManager.objectWillChange) { _ in
            // SpeechModelManager publishes per download progress chunk.
            // Refresh on every publish — the single-pass walk is cheap
            // (small fixed list); the win is collapsing three full
            // passes per body into one.
            refreshPartition()
        }
    }

    private func refreshPartition() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var recommended: [SpeechModel] = []
        var other: [SpeechModel] = []
        recommended.reserveCapacity(modelManager.availableModels.count)
        other.reserveCapacity(modelManager.availableModels.count)
        for model in modelManager.availableModels {
            if !trimmed.isEmpty {
                let match =
                    SearchService.matches(query: trimmed, in: model.name)
                    || SearchService.matches(query: trimmed, in: model.description)
                if !match { continue }
            }
            if model.isRecommended {
                recommended.append(model)
            } else {
                other.append(model)
            }
        }
        partitioned = PartitionedModels(recommended: recommended, other: other)
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

private struct SpeechModelRow: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var modelManager = SpeechModelManager.shared

    let model: SpeechModel

    @State private var isHovering = false

    private var downloadState: SpeechDownloadState {
        modelManager.effectiveDownloadState(for: model)
    }

    private var isSelected: Bool {
        modelManager.selectedModelId == model.id
    }

    var body: some View {
        HStack(spacing: 16) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(iconBackground)
                Image(systemName: iconName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(iconColor)
            }
            .frame(width: 48, height: 48)

            // Info
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    if model.isEnglishOnly {
                        Text("EN", bundle: .module)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(theme.secondaryText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.tertiaryBackground))
                    }

                    if isSelected {
                        Text("Default", bundle: .module)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(theme.successColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.successColor.opacity(0.1)))
                    }
                }

                Text(model.description)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)

                Text(model.size)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }

            Spacer()

            // Actions
            actionButton
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(
                            isSelected ? theme.successColor.opacity(0.3) : theme.cardBorder,
                            lineWidth: 1
                        )
                )
        )
        .scaleEffect(isHovering ? 1.005 : 1)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var iconName: String {
        switch downloadState {
        case .completed: return "waveform"
        case .downloading: return "arrow.down.circle"
        case .failed: return "exclamationmark.triangle"
        default: return "waveform.circle"
        }
    }

    private var iconColor: Color {
        switch downloadState {
        case .completed: return theme.successColor
        case .downloading: return theme.accentColor
        case .failed: return theme.errorColor
        default: return theme.secondaryText
        }
    }

    private var iconBackground: Color {
        switch downloadState {
        case .completed: return theme.successColor.opacity(0.15)
        case .downloading: return theme.accentColor.opacity(0.15)
        case .failed: return theme.errorColor.opacity(0.15)
        default: return theme.tertiaryBackground
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch downloadState {
        case .notStarted, .failed:
            Button(action: { modelManager.downloadModel(model) }) {
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

        case .downloading(let progress):
            HStack(spacing: 12) {
                // Progress indicator
                ZStack {
                    Circle()
                        .stroke(theme.tertiaryBackground, lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(theme.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.3), value: progress)
                }
                .frame(width: 28, height: 28)

                Text("\(Int(progress * 100))%", bundle: .module)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 40)

                Button(action: { modelManager.cancelDownload(model.id) }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(PlainButtonStyle())
            }

        case .completed:
            HStack(spacing: 8) {
                if !isSelected {
                    Button(action: { modelManager.setDefaultModel(model.id) }) {
                        Text("Set Default", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.accentColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(theme.accentColor, lineWidth: 1)
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                Button(action: { Task { await modelManager.deleteModel(model) } }) {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundColor(theme.tertiaryText)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.tertiaryBackground)
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }
}

// MARK: - Preview

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        VoiceView()
    }
#endif
