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
                    parts.append("\(minutes)m \(seconds)s remaining")
                } else {
                    parts.append("\(seconds)s remaining")
                }
            }

            return parts.joined(separator: " · ")
        }

        return "Preparing download..."
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasStartedDownload {
                downloadView
            } else {
                selectionView
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation {
                    hasAppeared = true
                }
            }
            // Pre-select the first top suggestion if available
            if selectedModel == nil, let first = topSuggestedModels.first {
                selectedModel = first
            }
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
        .alert("Download Failed", isPresented: $showError) {
            Button("Try Again") {
                startDownload()
            }
            Button("Skip") {
                onSkip()
            }
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - Selection View

    private var selectionView: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 30)

            // Back button
            backButton
                .padding(.horizontal, 15)
                .opacity(hasAppeared ? 1 : 0)
                .animation(.easeOut(duration: 0.5).delay(0.05), value: hasAppeared)

            Spacer().frame(height: 20)

            // Headline
            Text("Choose a local model")
                .font(theme.font(size: 22, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 20)
                .animation(.easeOut(duration: 0.5).delay(0.1), value: hasAppeared)

            Spacer().frame(height: 24)

            // Model cards
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(topSuggestedModels) { model in
                        ModelSelectionCard(
                            model: model,
                            isSelected: selectedModel?.id == model.id
                        ) {
                            withAnimation(.easeOut(duration: 0.2)) {
                                selectedModel = model
                            }
                        }
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 15)
                        .animation(
                            .easeOut(duration: 0.5).delay(
                                0.15 + Double(topSuggestedModels.firstIndex(where: { $0.id == model.id }) ?? 0) * 0.07
                            ),
                            value: hasAppeared
                        )
                    }
                }
                .padding(.horizontal, 15)
            }
            .frame(maxHeight: 260)

            Spacer().frame(height: 16)

            // Info text
            Text("Runs entirely on your Mac. No data leaves your computer.")
                .font(theme.font(size: 14))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 30)
                .opacity(hasAppeared ? 1 : 0)
                .animation(.easeOut(duration: 0.5).delay(0.35), value: hasAppeared)

            Spacer()

            // Action button
            OnboardingShimmerButton(
                title: selectedModel?.isDownloaded == true ? "Continue" : "Start Download",
                action: {
                    if selectedModel?.isDownloaded == true {
                        // Model already downloaded, skip to completion
                        onComplete()
                    } else {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            hasStartedDownload = true
                        }
                        startDownload()
                    }
                },
                isEnabled: selectedModel != nil
            )
            .frame(width: 200)
            .opacity(hasAppeared ? 1 : 0)
            .animation(.easeOut(duration: 0.5).delay(0.4), value: hasAppeared)

            Spacer().frame(height: 40)
        }
    }

    // MARK: - Download View

    private var downloadView: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 60)

            // Headline
            Text("Almost ready...")
                .font(theme.font(size: 24, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(downloadViewAppeared ? 1 : 0)
                .offset(y: downloadViewAppeared ? 0 : 20)

            Spacer().frame(height: 40)

            // Progress section
            VStack(spacing: 24) {
                // Shimmer progress bar
                OnboardingShimmerBar(progress: downloadProgress, color: theme.accentColor, height: 8)
                    .padding(.horizontal, 60)

                // Progress text
                Text(progressText)
                    .font(theme.font(size: 13))
                    .foregroundColor(theme.tertiaryText)
                    .animation(.easeInOut(duration: 0.2), value: progressText)
            }
            .frame(height: 100)
            .opacity(downloadViewAppeared ? 1 : 0)

            Spacer().frame(height: 36)

            // Info text
            Text(
                "Once this finishes, you'll have an AI running entirely on your Mac — no account, no cloud, no data leaving your machine."
            )
            .font(theme.font(size: 13))
            .foregroundColor(theme.secondaryText)
            .multilineTextAlignment(.center)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 40)
            .opacity(downloadViewAppeared ? 1 : 0)

            Spacer()

            // Action button
            OnboardingTextButton(title: isDownloading ? "Continue" : "Download later") {
                onSkip()
            }
            .opacity(downloadViewAppeared ? 1 : 0)

            Spacer().frame(height: 50)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(.easeOut(duration: 0.4)) {
                    downloadViewAppeared = true
                }
            }
        }
    }

    // MARK: - Back Button

    private var backButton: some View {
        HStack {
            Button {
                onBack()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Back")
                        .font(theme.font(size: 13, weight: .medium))
                }
                .foregroundColor(theme.secondaryText)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.leading, -12)
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

// MARK: - Model Selection Card

private struct ModelSelectionCard: View {
    let model: MLXModel
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            OnboardingGlassCard(isSelected: isSelected) {
                HStack(spacing: 14) {
                    // Icon with model type indicator
                    ZStack {
                        if isSelected {
                            Circle()
                                .fill(theme.accentColor)
                                .blur(radius: 8)
                                .frame(width: 36, height: 36)
                        }

                        Circle()
                            .fill(isSelected ? theme.accentColor : theme.cardBackground)
                            .frame(width: 44, height: 44)

                        Image(systemName: model.modelType == .vlm ? "eye" : "cpu")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(isSelected ? .white : theme.secondaryText)
                    }

                    // Text content
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(model.name)
                                .font(theme.font(size: 14, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                                .lineLimit(1)

                            // Badges
                            HStack(spacing: 4) {
                                if model.isDownloaded {
                                    DownloadedBadgeView()
                                } else if let size = model.formattedDownloadSize {
                                    BadgeView(text: size)
                                }
                                BadgeView(text: model.modelType.rawValue)
                            }
                        }

                        Text(model.description)
                            .font(theme.font(size: 12))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(2)
                            .lineSpacing(1)
                    }

                    Spacer(minLength: 8)

                    // Selection indicator
                    ZStack {
                        Circle()
                            .strokeBorder(
                                isSelected ? theme.accentColor : theme.primaryBorder,
                                lineWidth: isSelected ? 6 : 1.5
                            )
                            .frame(width: 20, height: 20)

                        if isSelected {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 7, height: 7)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Badge View

private struct BadgeView: View {
    let text: String

    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(theme.font(size: 10, weight: .medium))
            .foregroundColor(theme.tertiaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(theme.secondaryBackground)
            )
    }
}

// MARK: - Downloaded Badge View

private struct DownloadedBadgeView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 9, weight: .medium))
            Text("Downloaded")
                .font(theme.font(size: 10, weight: .medium))
        }
        .foregroundColor(.green)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.green.opacity(0.15))
        )
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
            .frame(width: OnboardingLayout.windowWidth, height: OnboardingLayout.windowHeight)
        }
    }
#endif
