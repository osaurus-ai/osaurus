//
//  OnboardingLocalDownloadView.swift
//  osaurus
//
//  Local model download view with shimmer progress bar and ambient background.
//

import SwiftUI

struct OnboardingLocalDownloadView: View {
    let onComplete: () -> Void
    let onSkip: () -> Void

    @Environment(\.theme) private var theme
    @ObservedObject private var modelManager = ModelManager.shared

    @State private var hasAppeared = false
    @State private var downloadStarted = false
    @State private var showError = false
    @State private var errorMessage = ""

    /// Default recommended model for onboarding
    private var defaultModel: MLXModel? {
        modelManager.suggestedModels.first(where: { $0.isTopSuggestion })
            ?? modelManager.suggestedModels.first
    }

    private var downloadProgress: Double {
        guard let model = defaultModel else { return 0 }
        if case .downloading(let progress) = modelManager.downloadStates[model.id] {
            return progress
        }
        return 0
    }

    private var downloadState: DownloadState {
        guard let model = defaultModel else { return .notStarted }
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
        guard let model = defaultModel else { return "" }

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
            Spacer().frame(height: 60)

            // Headline
            Text(isCompleted ? "Download complete" : "Downloading your local model...")
                .font(theme.font(size: 26, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 20)
                .animation(theme.springAnimation().delay(0.1), value: hasAppeared)

            Spacer().frame(height: 16)

            // Model name
            if let model = defaultModel {
                Text(model.name)
                    .font(theme.font(size: 15, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .opacity(hasAppeared ? 1 : 0)
                    .animation(theme.springAnimation().delay(0.15), value: hasAppeared)
            }

            Spacer().frame(height: 40)

            // Progress section
            VStack(spacing: 24) {
                if isCompleted {
                    // Completion indicator with glow
                    ZStack {
                        Circle()
                            .fill(theme.successColor)
                            .blur(radius: 20)
                            .frame(width: 60, height: 60)
                            .opacity(0.5)

                        Circle()
                            .fill(theme.successColor)
                            .frame(width: 80, height: 80)

                        Image(systemName: "checkmark")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .transition(.scale.combined(with: .opacity))
                } else {
                    // Shimmer progress bar
                    OnboardingShimmerBar(progress: downloadProgress, color: theme.accentColor, height: 8)
                        .padding(.horizontal, 60)

                    // Progress text
                    Text(progressText)
                        .font(theme.font(size: 13))
                        .foregroundColor(theme.tertiaryText)
                        .animation(.easeInOut(duration: 0.2), value: progressText)
                }
            }
            .frame(height: 100)
            .opacity(hasAppeared ? 1 : 0)
            .animation(theme.springAnimation().delay(0.2), value: hasAppeared)

            Spacer().frame(height: 36)

            // Info text
            VStack(spacing: 16) {
                Text("This runs on your Mac's chip. No data leaves your computer.")
                    .font(theme.font(size: 15))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if isDownloading {
                    Text(
                        "Osaurus can also control your Calendar, Messages, Notes, and more — all with your permission."
                    )
                    .font(theme.font(size: 14))
                    .foregroundColor(theme.tertiaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)
                }
            }
            .padding(.horizontal, 50)
            .opacity(hasAppeared ? 1 : 0)
            .animation(theme.springAnimation().delay(0.3), value: hasAppeared)

            Spacer()

            // Action buttons
            VStack(spacing: 12) {
                if isCompleted {
                    OnboardingPrimaryButton(title: "Continue", action: onComplete)
                        .frame(width: 200)
                } else if isDownloading {
                    OnboardingTextButton(title: "Skip for now") {
                        onSkip()
                    }
                }
            }
            .opacity(hasAppeared ? 1 : 0)
            .animation(theme.springAnimation().delay(0.4), value: hasAppeared)

            Spacer().frame(height: 50)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation {
                    hasAppeared = true
                }
            }
            startDownload()
        }
        .onChange(of: isCompleted) { _, completed in
            if completed {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    onComplete()
                }
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

    private func startDownload() {
        guard !downloadStarted, let model = defaultModel else { return }
        downloadStarted = true
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
                onSkip: {}
            )
            .frame(width: 580, height: 680)
        }
    }
#endif
