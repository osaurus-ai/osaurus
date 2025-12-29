//
//  VoiceSetupTab.swift
//  osaurus
//
//  Privacy-first voice setup dashboard.
//  Clean, single-page experience for voice configuration.
//

import SwiftUI

// MARK: - Voice Setup Tab

struct VoiceSetupTab: View {
    @Environment(\.theme) private var theme
    @StateObject private var whisperService = WhisperKitService.shared
    @StateObject private var modelManager = WhisperModelManager.shared

    /// Called when setup is complete
    var onComplete: (() -> Void)?

    @State private var testTranscription: String = ""
    @State private var isTestingVoice = false
    @State private var testError: String?
    @State private var hasAppeared = false
    @State private var glowIntensity: CGFloat = 0.6

    /// Whether all requirements are met
    private var isSetupComplete: Bool {
        whisperService.microphonePermissionGranted
            && modelManager.downloadedModelsCount > 0
            && modelManager.selectedModel != nil
    }

    /// Whether a model is currently downloading
    private var isDownloading: Bool {
        modelManager.downloadStates.values.contains { state in
            if case .downloading = state { return true }
            return false
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Hero section with privacy messaging
                heroSection
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : -15)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.05), value: hasAppeared)

                // Requirements cards (side by side)
                requirementsSection
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 10)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.15), value: hasAppeared)

                // Voice test area (enabled when ready)
                voiceTestSection
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 10)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.25), value: hasAppeared)

                Spacer()
            }
            .padding(24)
            .frame(maxWidth: 700)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.3).delay(0.05)) {
                hasAppeared = true
            }
            withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                glowIntensity = 1.0
            }
        }
        .onChange(of: whisperService.currentTranscription) { _, newValue in
            if isTestingVoice {
                testTranscription = newValue
            }
        }
        .onChange(of: whisperService.confirmedTranscription) { _, newValue in
            if isTestingVoice && !newValue.isEmpty {
                testTranscription = newValue
            }
        }
    }

    // MARK: - Hero Section

    private var heroSection: some View {
        VStack(spacing: 20) {
            // Shield icon with glow
            ZStack {
                // Outer glow
                Circle()
                    .fill(theme.accentColor)
                    .frame(width: 72, height: 72)
                    .blur(radius: 20)
                    .opacity(glowIntensity * 0.2)

                // Icon container
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    theme.accentColor.opacity(0.15),
                                    theme.accentColor.opacity(0.05),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 64, height: 64)

                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [theme.accentColor, theme.accentColor.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }

            // Title and description
            VStack(spacing: 10) {
                Text("Local-First Voice Transcription")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(theme.primaryText)

                Text(
                    "Your voice never leaves your Mac. All audio processing happens entirely on-device using Apple's Neural Engine for fast, private transcription."
                )
                .font(.system(size: 14))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            }

            // Privacy badges
            HStack(spacing: 12) {
                PrivacyBadge(icon: "cpu", text: "On-Device Processing")
                PrivacyBadge(icon: "wifi.slash", text: "No Internet Required")
                PrivacyBadge(icon: "eye.slash", text: "100% Private")
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Requirements Section

    private var requirementsSection: some View {
        HStack(spacing: 16) {
            // Microphone card
            RequirementCard(
                icon: whisperService.microphonePermissionGranted ? "mic.fill" : "mic.slash.fill",
                title: "Microphone",
                subtitle: whisperService.microphonePermissionGranted
                    ? "Access granted"
                    : "Required for voice input",
                isComplete: whisperService.microphonePermissionGranted,
                actionTitle: "Grant Access",
                showAction: !whisperService.microphonePermissionGranted,
                action: requestMicrophonePermission
            )

            // Model card
            modelRequirementCard
        }
    }

    private var modelRequirementCard: some View {
        let hasModel = modelManager.downloadedModelsCount > 0 && modelManager.selectedModel != nil

        return VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(hasModel ? theme.successColor.opacity(0.15) : theme.accentColor.opacity(0.15))
                        .frame(width: 48, height: 48)

                    Image(systemName: hasModel ? "waveform" : "arrow.down.circle")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(hasModel ? theme.successColor : theme.accentColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Whisper Model")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(theme.primaryText)

                        if hasModel {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(theme.successColor)
                        }
                    }

                    Text(hasModel ? (modelManager.selectedModel?.name ?? "Ready") : "Required for transcription")
                        .font(.system(size: 12))
                        .foregroundColor(hasModel ? theme.successColor : theme.secondaryText)
                }

                Spacer()
            }

            // Content based on state
            if hasModel {
                // Model is ready
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(theme.successColor)
                    Text("Model ready")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.successColor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.successColor.opacity(0.1))
                )
            } else {
                // Show recommended model for download
                VStack(spacing: 10) {
                    if let recommendedModel = modelManager.availableModels.first(where: { $0.isRecommended }) {
                        CompactModelRow(model: recommendedModel)
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(hasModel ? theme.successColor.opacity(0.3) : theme.cardBorder, lineWidth: 1)
                )
        )
    }

    // MARK: - Voice Test Section

    private var voiceTestSection: some View {
        VStack(spacing: 20) {
            // Section header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Test Your Voice")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(theme.primaryText)

                    Text(
                        isSetupComplete
                            ? "Speak into your microphone to verify everything works"
                            : "Complete the requirements above to test voice input"
                    )
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryText)
                }

                Spacer()

                // Ready indicator
                if isSetupComplete {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(theme.successColor)
                            .frame(width: 8, height: 8)
                        Text("Ready")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.successColor)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(theme.successColor.opacity(0.1))
                    )
                }
            }

            // Test area
            VStack(spacing: 16) {
                // Waveform visualization
                if isTestingVoice {
                    WaveformView(level: whisperService.audioLevel, style: .bars, barCount: 24)
                        .frame(height: 56)
                        .padding(.horizontal, 8)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }

                // Transcription preview
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        testTranscription.isEmpty
                            ? (isTestingVoice ? "Listening..." : "Your words will appear here...")
                            : testTranscription
                    )
                    .font(.system(size: 15))
                    .foregroundColor(testTranscription.isEmpty ? theme.tertiaryText : theme.primaryText)
                    .italic(testTranscription.isEmpty && !isTestingVoice)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 44)
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(
                                    isTestingVoice ? theme.accentColor.opacity(0.5) : theme.inputBorder,
                                    lineWidth: isTestingVoice ? 2 : 1
                                )
                        )
                )

                // Error message
                if let error = testError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                        Text(error)
                            .font(.system(size: 12))
                    }
                    .foregroundColor(theme.errorColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.errorColor.opacity(0.1))
                    )
                }

                // Action buttons
                HStack(spacing: 12) {
                    Button(action: toggleVoiceTest) {
                        HStack(spacing: 8) {
                            Image(systemName: isTestingVoice ? "stop.fill" : "mic.fill")
                                .font(.system(size: 15))
                            Text(isTestingVoice ? "Stop" : "Start Recording")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(isTestingVoice ? theme.errorColor : theme.accentColor)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!isSetupComplete)
                    .opacity(isSetupComplete ? 1 : 0.5)

                    if !testTranscription.isEmpty && !isTestingVoice {
                        Button(action: { testTranscription = "" }) {
                            Text("Clear")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(theme.secondaryText)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(theme.tertiaryBackground)
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    // Continue button when complete
                    if isSetupComplete && !testTranscription.isEmpty {
                        Button(action: { onComplete?() }) {
                            HStack(spacing: 6) {
                                Text("Continue")
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 11)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(theme.successColor)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(theme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(isSetupComplete ? theme.successColor.opacity(0.3) : theme.cardBorder, lineWidth: 1)
                    )
            )

            // Setup complete celebration
            if isSetupComplete && testTranscription.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14))
                        .foregroundColor(theme.successColor)
                    Text("You're all set! Try speaking to test your voice input.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.successColor)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.successColor.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(theme.successColor.opacity(0.2), lineWidth: 1)
                        )
                )
            }
        }
    }

    // MARK: - Actions

    private func requestMicrophonePermission() {
        Task {
            _ = await whisperService.requestMicrophonePermission()
        }
    }

    private func toggleVoiceTest() {
        if isTestingVoice {
            Task {
                _ = await whisperService.stopStreamingTranscription()
                await MainActor.run {
                    isTestingVoice = false
                }
            }
        } else {
            testError = nil
            Task {
                do {
                    try await whisperService.startStreamingTranscription()
                    await MainActor.run {
                        isTestingVoice = true
                    }
                } catch {
                    await MainActor.run {
                        testError = error.localizedDescription
                    }
                }
            }
        }
    }
}

// MARK: - Privacy Badge

private struct PrivacyBadge: View {
    @Environment(\.theme) private var theme

    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.accentColor)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(theme.tertiaryBackground)
        )
    }
}

// MARK: - Requirement Card

private struct RequirementCard: View {
    @Environment(\.theme) private var theme

    let icon: String
    let title: String
    let subtitle: String
    let isComplete: Bool
    let actionTitle: String
    let showAction: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isComplete ? theme.successColor.opacity(0.15) : theme.accentColor.opacity(0.15))
                        .frame(width: 48, height: 48)

                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(isComplete ? theme.successColor : theme.accentColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(theme.primaryText)

                        if isComplete {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(theme.successColor)
                        }
                    }

                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(isComplete ? theme.successColor : theme.secondaryText)
                }

                Spacer()
            }

            // Action or status
            if showAction {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.accentColor)
                        )
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(theme.successColor)
                    Text("Ready")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.successColor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.successColor.opacity(0.1))
                )
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(isComplete ? theme.successColor.opacity(0.3) : theme.cardBorder, lineWidth: 1)
                )
        )
    }
}

// MARK: - Compact Model Row

private struct CompactModelRow: View {
    @Environment(\.theme) private var theme
    @StateObject private var modelManager = WhisperModelManager.shared

    let model: WhisperModel

    private var downloadState: WhisperDownloadState {
        modelManager.effectiveDownloadState(for: model)
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Text("Recommended")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(theme.accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(theme.accentColor.opacity(0.1)))
                }

                Text(model.size)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }

            Spacer()

            // Download button or progress
            switch downloadState {
            case .notStarted, .failed:
                Button(action: { modelManager.downloadModel(model) }) {
                    Text("Download")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(theme.accentColor)
                        )
                }
                .buttonStyle(.plain)

            case .downloading(let progress):
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .stroke(theme.tertiaryBackground, lineWidth: 2.5)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(theme.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 22, height: 22)

                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                }

            case .completed:
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(theme.successColor)
                    Text("Ready")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.successColor)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.tertiaryBackground)
        )
    }
}

// MARK: - Preview

#if DEBUG
    struct VoiceSetupTab_Previews: PreviewProvider {
        static var previews: some View {
            VoiceSetupTab()
                .frame(width: 700, height: 700)
                .background(Color(hex: "1a1a1a"))
        }
    }
#endif
