//
//  OnboardingLocalDownloadView.swift
//  osaurus
//
//  Local model selection and download view with shimmer progress bar.
//

import SwiftUI

struct OnboardingLocalDownloadView: View {
    let onComplete: () -> Void
    let onSkip: () -> Void
    let onBack: () -> Void

    @Environment(\.theme) private var theme
    @ObservedObject private var modelManager = ModelManager.shared

    @State private var hasAppeared = false
    @State private var downloadViewAppeared = false
    @State private var selectedModel: MLXModel? = nil
    @State private var hasStartedDownload = false
    @State private var showError = false
    @State private var errorMessage = ""

    /// Top suggested models to display for selection
    private var topSuggestedModels: [MLXModel] {
        modelManager.suggestedModels.filter { $0.isTopSuggestion }
    }

    private var downloadProgress: Double {
        guard let model = selectedModel else { return 0 }
        if case .downloading(let progress) = modelManager.downloadStates[model.id] {
            return progress
        }
        return 0
    }

    private var downloadState: DownloadState {
        guard let model = selectedModel else { return .notStarted }
        return modelManager.downloadStates[model.id] ?? .notStarted
    }

    private var isDownloading: Bool {
        if case .downloading = downloadState {
            return true
        }
        return false
    }

    private var isCompleted: Bool {
        if case .completed = downloadState {
            return true
        }
        return false
    }

    private var isFailed: Bool {
        if case .failed = downloadState {
            return true
        }
        return false
    }

    private var failedError: String? {
        if case .failed(let error) = downloadState {
            return error
        }
        return nil
    }

    private var progressText: String {
        guard let model = selectedModel else { return "" }

        if let metrics = modelManager.downloadMetrics[model.id] {
            var parts: [String] = []

            if let received = metrics.bytesReceived, let total = metrics.totalBytes {
                parts.append("\(formatBytes(received)) / \(formatBytes(total))")
            }

            if let speed = metrics.bytesPerSecond {
                parts.append("\(formatBytes(Int64(speed)))/s")
            }

            if let eta = metrics.etaSeconds, eta > 0 && eta < 3600 {
                let minutes = Int(eta) / 60
                let seconds = Int(eta) % 60
                if minutes > 0 {
                    parts.append(L("\(minutes)m \(seconds)s remaining"))
                } else {
                    parts.append(L("\(seconds)s remaining"))
                }
            }

            return parts.joined(separator: " · ")
        }

        return L("Preparing download...")
    }

    var body: some View {
        ZStack {
            if hasStartedDownload {
                downloadView
                    .transition(nestedTransition)
            } else {
                selectionView
                    .transition(nestedTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(theme.springAnimation(responseMultiplier: 0.8), value: hasStartedDownload)
        .onAppear {
            // Pre-select the first top suggestion if available
            if selectedModel == nil, let first = topSuggestedModels.first {
                selectedModel = first
            }
        }
        .onAppearAfter(OnboardingMetrics.appearDelay) {
            withAnimation { hasAppeared = true }
        }
        .onChange(of: isCompleted) { _, completed in
            // Only auto-complete if we're in the download phase - go directly to "You're all set"
            if completed && hasStartedDownload {
                onComplete()
            }
        }
        .onChange(of: isFailed) { _, failed in
            if failed, let error = failedError {
                errorMessage = error
                showError = true
            }
        }
        .alert(Text("Download Failed", bundle: .module), isPresented: $showError) {
            Button {
                startDownload()
            } label: {
                Text("Try Again", bundle: .module)
            }
            Button {
                onSkip()
            } label: {
                Text("Skip", bundle: .module)
            }
        } message: {
            Text(errorMessage)
        }
    }

    /// Nested screen transition (consistent with main onboarding)
    private var nestedTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .offset(x: 30))
                .combined(with: .scale(scale: 0.98)),
            removal: .opacity
                .combined(with: .offset(x: -30))
                .combined(with: .scale(scale: 0.98))
        )
    }

    // MARK: - Selection View

    private var selectionView: some View {
        OnboardingScaffold(
            title: "Choose a local model",
            footer: "Runs entirely on your Mac. No data leaves your computer.",
            onBack: onBack,
            content: {
                VStack(spacing: OnboardingMetrics.cardSpacing) {
                    ForEach(Array(topSuggestedModels.enumerated()), id: \.element.id) { index, model in
                        OnboardingRowCard(
                            icon: .symbol(model.isVLM ? "eye" : "cpu"),
                            title: model.name,
                            subtitle: model.description,
                            badges: badges(for: model),
                            accessory: .radio(isSelected: selectedModel?.id == model.id),
                            isSelected: selectedModel?.id == model.id
                        ) {
                            withAnimation(theme.animationQuick()) {
                                selectedModel = model
                            }
                        }
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 15)
                        .animation(
                            theme.springAnimation().delay(0.15 + Double(index) * 0.06),
                            value: hasAppeared
                        )
                    }
                }
            },
            cta: {
                OnboardingShimmerButton(
                    title: selectedModel?.isDownloaded == true ? "Continue" : "Start Download",
                    action: startDownloadOrContinue,
                    isEnabled: selectedModel != nil
                )
                .frame(width: OnboardingMetrics.ctaWidth)
                .opacity(hasAppeared ? 1 : 0)
                .animation(theme.springAnimation().delay(0.4), value: hasAppeared)
            }
        )
    }

    private func badges(for model: MLXModel) -> [OnboardingRowBadge] {
        var result: [OnboardingRowBadge] = []
        if model.isDownloaded {
            result.append(OnboardingRowBadge(L("Downloaded"), style: .success))
        } else if let size = model.formattedDownloadSize {
            result.append(OnboardingRowBadge(size))
        }
        result.append(OnboardingRowBadge(model.isVLM ? "VLM" : "LLM"))
        return result
    }

    private func startDownloadOrContinue() {
        if selectedModel?.isDownloaded == true {
            onComplete()
        } else {
            withAnimation(theme.springAnimation(responseMultiplier: 0.8)) {
                hasStartedDownload = true
            }
            startDownload()
        }
    }

    // MARK: - Download View

    private var downloadView: some View {
        OnboardingScaffold(
            title: "Almost ready...",
            subtitle:
                "Once this finishes, you'll have an AI running entirely on your Mac — no account, no cloud, no data leaving your machine.",
            content: {
                VStack(spacing: 18) {
                    OnboardingShimmerBar(
                        progress: downloadProgress,
                        color: theme.accentColor,
                        height: 8
                    )
                    .padding(.horizontal, 32)

                    Text(progressText)
                        .font(theme.font(size: 13))
                        .foregroundColor(theme.tertiaryText)
                        .animation(theme.animationQuick(), value: progressText)
                }
                .opacity(downloadViewAppeared ? 1 : 0)
                .animation(theme.springAnimation().delay(0.1), value: downloadViewAppeared)
            },
            cta: {
                OnboardingTextButton(title: isDownloading ? "Continue" : "Download later") {
                    onSkip()
                }
                .opacity(downloadViewAppeared ? 1 : 0)
                .animation(theme.springAnimation().delay(0.2), value: downloadViewAppeared)
            }
        )
        .onAppearAfter(OnboardingMetrics.appearDelay) {
            withAnimation(theme.springAnimation()) { downloadViewAppeared = true }
        }
    }

    // MARK: - Private Methods

    private func startDownload() {
        guard let model = selectedModel else { return }
        modelManager.downloadModel(model)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.includesUnit = true
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Preview

#if DEBUG
    struct OnboardingLocalDownloadView_Previews: PreviewProvider {
        static var previews: some View {
            OnboardingLocalDownloadView(
                onComplete: {},
                onSkip: {},
                onBack: {}
            )
            .frame(width: OnboardingMetrics.windowWidth, height: 720)
        }
    }
#endif
