//
//  VoiceSetupTab.swift
//  osaurus
//
//  Guided onboarding wizard for voice features.
//  Walks users through permissions and model setup.
//

import SwiftUI

/// Setup step for voice onboarding
enum VoiceSetupStep: Int, CaseIterable {
    case microphone = 0
    case model = 1
    case test = 2

    var title: String {
        switch self {
        case .microphone: return "Microphone Access"
        case .model: return "Download Model"
        case .test: return "Test Voice"
        }
    }

    var description: String {
        switch self {
        case .microphone: return "Allow Osaurus to use your microphone for voice input"
        case .model: return "Download a Whisper model for speech recognition"
        case .test: return "Try speaking to verify everything works"
        }
    }

    var iconName: String {
        switch self {
        case .microphone: return "mic.fill"
        case .model: return "arrow.down.circle.fill"
        case .test: return "waveform"
        }
    }
}

// MARK: - Voice Setup Tab

struct VoiceSetupTab: View {
    @Environment(\.theme) private var theme
    @StateObject private var whisperService = WhisperKitService.shared
    @StateObject private var modelManager = WhisperModelManager.shared

    /// Called when setup is complete
    var onComplete: (() -> Void)?

    @State private var currentStep: VoiceSetupStep = .microphone
    @State private var testTranscription: String = ""
    @State private var isTestingVoice = false
    @State private var testError: String?
    @State private var hasAppeared = false
    @State private var glowIntensity: CGFloat = 0.6

    /// Whether all setup steps are complete
    private var isSetupComplete: Bool {
        whisperService.microphonePermissionGranted && modelManager.downloadedModelsCount > 0
            && modelManager.selectedModel != nil
    }

    /// Whether current step is completed
    private func isStepComplete(_ step: VoiceSetupStep) -> Bool {
        switch step {
        case .microphone:
            return whisperService.microphonePermissionGranted
        case .model:
            return modelManager.downloadedModelsCount > 0 && modelManager.selectedModel != nil
        case .test:
            return !testTranscription.isEmpty
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // Progress indicator
                setupProgressIndicator
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : -10)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1), value: hasAppeared)

                // Current step content
                VStack(spacing: 24) {
                    switch currentStep {
                    case .microphone:
                        microphoneStepContent
                    case .model:
                        modelStepContent
                    case .test:
                        testStepContent
                    }
                }
                .frame(maxWidth: 600)

                Spacer(minLength: 40)
            }
            .padding(32)
        }
        .onAppear {
            updateCurrentStep()
            withAnimation(.easeOut(duration: 0.3).delay(0.05)) {
                hasAppeared = true
            }
            // Start glow animation
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                glowIntensity = 1.0
            }
        }
        .onChange(of: whisperService.microphonePermissionGranted) { _, _ in
            updateCurrentStep()
        }
        .onChange(of: modelManager.downloadedModelsCount) { _, _ in
            updateCurrentStep()
        }
    }

    private func updateCurrentStep() {
        if !whisperService.microphonePermissionGranted {
            currentStep = .microphone
        } else if modelManager.downloadedModelsCount == 0 || modelManager.selectedModel == nil {
            currentStep = .model
        } else {
            currentStep = .test
        }
    }

    // MARK: - Progress Indicator

    private var setupProgressIndicator: some View {
        HStack(spacing: 0) {
            ForEach(VoiceSetupStep.allCases, id: \.rawValue) { step in
                let isActive = step == currentStep
                let isCompleted = isStepComplete(step)

                HStack(spacing: 0) {
                    // Step circle with glow for active step
                    ZStack {
                        // Glow effect for active step
                        if isActive {
                            Circle()
                                .fill(theme.accentColor)
                                .frame(width: 36, height: 36)
                                .blur(radius: 10)
                                .opacity(glowIntensity * 0.4)
                        }

                        Circle()
                            .fill(
                                isCompleted
                                    ? AnyShapeStyle(theme.successColor)
                                    : (isActive
                                        ? AnyShapeStyle(
                                            LinearGradient(
                                                colors: [theme.accentColor, theme.accentColor.opacity(0.8)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        : AnyShapeStyle(theme.tertiaryBackground))
                            )
                            .frame(width: 36, height: 36)

                        if isCompleted {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                        } else {
                            Text("\(step.rawValue + 1)")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(isActive ? .white : theme.tertiaryText)
                        }
                    }

                    // Connector line
                    if step != .test {
                        Rectangle()
                            .fill(isStepComplete(step) ? theme.successColor : theme.tertiaryBackground)
                            .frame(height: 2)
                    }
                }
            }
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Microphone Step

    private var microphoneStepContent: some View {
        let iconColor = whisperService.microphonePermissionGranted ? theme.successColor : theme.accentColor

        return VStack(spacing: 24) {
            // Glowing icon
            ZStack {
                // Outer glow
                Circle()
                    .fill(iconColor)
                    .frame(width: 88, height: 88)
                    .blur(radius: 25)
                    .opacity(glowIntensity * 0.25)

                // Inner glow
                Circle()
                    .fill(iconColor)
                    .frame(width: 88, height: 88)
                    .blur(radius: 12)
                    .opacity(glowIntensity * 0.15)

                // Base circle with gradient
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                iconColor.opacity(0.15),
                                iconColor.opacity(0.05),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 88, height: 88)

                // Icon
                Image(systemName: whisperService.microphonePermissionGranted ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [iconColor, iconColor.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .opacity(hasAppeared ? 1 : 0)
            .scaleEffect(hasAppeared ? 1 : 0.8)
            .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.15), value: hasAppeared)

            // Title and description
            VStack(spacing: 8) {
                Text("Microphone Access")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(theme.primaryText)

                Text("Osaurus needs microphone access to transcribe your voice into text.")
                    .font(.system(size: 14))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 15)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2), value: hasAppeared)

            // Status or action
            Group {
                if whisperService.microphonePermissionGranted {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(theme.successColor)
                        Text("Microphone access granted")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(theme.successColor)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(theme.successColor.opacity(0.1))
                    )

                    // Continue button
                    Button(action: { currentStep = .model }) {
                        Text("Continue")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(theme.accentColor)
                            )
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: requestMicrophonePermission) {
                        Text("Grant Microphone Access")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(theme.accentColor)
                            )
                    }
                    .buttonStyle(.plain)

                    Text("Click the button and allow access when prompted")
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
            }
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 10)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.3), value: hasAppeared)
        }
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
        .opacity(hasAppeared ? 1 : 0)
        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1), value: hasAppeared)
    }

    private func requestMicrophonePermission() {
        Task {
            _ = await whisperService.requestMicrophonePermission()
        }
    }

    // MARK: - Model Step

    private var modelStepContent: some View {
        let iconColor = modelManager.downloadedModelsCount > 0 ? theme.successColor : theme.accentColor

        return VStack(spacing: 24) {
            // Glowing icon
            ZStack {
                // Outer glow
                Circle()
                    .fill(iconColor)
                    .frame(width: 88, height: 88)
                    .blur(radius: 25)
                    .opacity(glowIntensity * 0.25)

                // Inner glow
                Circle()
                    .fill(iconColor)
                    .frame(width: 88, height: 88)
                    .blur(radius: 12)
                    .opacity(glowIntensity * 0.15)

                // Base circle with gradient
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                iconColor.opacity(0.15),
                                iconColor.opacity(0.05),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 88, height: 88)

                // Icon
                Image(
                    systemName: modelManager.downloadedModelsCount > 0
                        ? "checkmark.circle.fill" : "arrow.down.circle.fill"
                )
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(
                    LinearGradient(
                        colors: [iconColor, iconColor.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
            .opacity(hasAppeared ? 1 : 0)
            .scaleEffect(hasAppeared ? 1 : 0.8)
            .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.15), value: hasAppeared)

            // Title and description
            VStack(spacing: 8) {
                Text("Download Whisper Model")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(theme.primaryText)

                Text(
                    "A Whisper model is required for speech-to-text. We recommend starting with a smaller model for faster performance."
                )
                .font(.system(size: 14))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            }
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 15)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2), value: hasAppeared)

            // Model options
            Group {
                if modelManager.downloadedModelsCount > 0 && modelManager.selectedModel != nil {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(theme.successColor)
                        Text("Model ready: \(modelManager.selectedModel?.name ?? "")")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(theme.successColor)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(theme.successColor.opacity(0.1))
                    )

                    Button(action: { currentStep = .test }) {
                        Text("Continue")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(theme.accentColor)
                            )
                    }
                    .buttonStyle(.plain)
                } else {
                    // Recommended models
                    VStack(spacing: 12) {
                        ForEach(modelManager.availableModels.filter { $0.isRecommended }.prefix(2)) { model in
                            RecommendedModelRow(model: model)
                        }
                    }
                    .padding(.horizontal)

                    if modelManager.downloadStates.values.contains(where: {
                        if case .downloading = $0 { return true } else { return false }
                    }) {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Downloading...")
                                .font(.system(size: 14))
                                .foregroundColor(theme.secondaryText)
                        }
                    }
                }
            }
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 10)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.3), value: hasAppeared)
        }
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
        .opacity(hasAppeared ? 1 : 0)
        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1), value: hasAppeared)
    }

    // MARK: - Test Step

    private var testStepContent: some View {
        let iconColor = theme.accentColor

        return VStack(spacing: 24) {
            // Glowing icon
            ZStack {
                // Outer glow
                Circle()
                    .fill(iconColor)
                    .frame(width: 88, height: 88)
                    .blur(radius: 25)
                    .opacity(glowIntensity * 0.25)

                // Inner glow
                Circle()
                    .fill(iconColor)
                    .frame(width: 88, height: 88)
                    .blur(radius: 12)
                    .opacity(glowIntensity * 0.15)

                // Base circle with gradient
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                iconColor.opacity(0.15),
                                iconColor.opacity(0.05),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 88, height: 88)

                // Icon
                Image(systemName: "waveform")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [iconColor, iconColor.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .opacity(hasAppeared ? 1 : 0)
            .scaleEffect(hasAppeared ? 1 : 0.8)
            .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.15), value: hasAppeared)

            // Title and description
            VStack(spacing: 8) {
                Text("Test Your Voice")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(theme.primaryText)

                Text("Speak into your microphone to verify voice recognition is working correctly.")
                    .font(.system(size: 14))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 15)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2), value: hasAppeared)

            // Waveform visualization
            if isTestingVoice {
                WaveformView(level: whisperService.audioLevel, style: .bars, barCount: 16)
                    .frame(height: 48)
            }

            // Transcription preview
            VStack(alignment: .leading, spacing: 8) {
                Text(testTranscription.isEmpty ? "Your words will appear here..." : testTranscription)
                    .font(.system(size: 15))
                    .foregroundColor(testTranscription.isEmpty ? theme.tertiaryText : theme.primaryText)
                    .italic(testTranscription.isEmpty)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 10)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.25), value: hasAppeared)

            // Error message
            if let error = testError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(theme.errorColor)
            }

            // Action buttons
            HStack(spacing: 16) {
                Button(action: toggleVoiceTest) {
                    HStack(spacing: 8) {
                        Image(systemName: isTestingVoice ? "stop.fill" : "mic.fill")
                            .font(.system(size: 16))
                        Text(isTestingVoice ? "Stop" : "Start Test")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(isTestingVoice ? theme.errorColor : theme.accentColor)
                    )
                }
                .buttonStyle(.plain)

                if !testTranscription.isEmpty {
                    Button(action: { onComplete?() }) {
                        HStack(spacing: 8) {
                            Text("Complete Setup")
                            Image(systemName: "arrow.right")
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(theme.successColor)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 10)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.3), value: hasAppeared)

            // Skip button
            Button(action: { onComplete?() }) {
                Text("Skip test and continue")
                    .font(.system(size: 13))
                    .foregroundColor(theme.tertiaryText)
            }
            .buttonStyle(.plain)
            .opacity(hasAppeared ? 1 : 0)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.35), value: hasAppeared)
        }
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
        .opacity(hasAppeared ? 1 : 0)
        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1), value: hasAppeared)
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

    private func toggleVoiceTest() {
        if isTestingVoice {
            // Stop
            Task {
                _ = await whisperService.stopStreamingTranscription()
                isTestingVoice = false
            }
        } else {
            // Start
            testError = nil
            Task {
                do {
                    try await whisperService.startStreamingTranscription()
                    isTestingVoice = true
                } catch {
                    testError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Recommended Model Row

private struct RecommendedModelRow: View {
    @Environment(\.theme) private var theme
    @StateObject private var modelManager = WhisperModelManager.shared

    let model: WhisperModel

    private var downloadState: WhisperDownloadState {
        modelManager.effectiveDownloadState(for: model)
    }

    var body: some View {
        HStack(spacing: 16) {
            // Model info
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    if model.isRecommended {
                        Text("Recommended")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(theme.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.accentColor.opacity(0.1)))
                    }
                }

                Text(model.size)
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)
            }

            Spacer()

            // Download button or progress
            switch downloadState {
            case .notStarted, .failed:
                Button(action: { modelManager.downloadModel(model) }) {
                    Text("Download")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.accentColor)
                        )
                }
                .buttonStyle(.plain)

            case .downloading(let progress):
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                }

            case .completed:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(theme.successColor)
                    Text("Ready")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.successColor)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.tertiaryBackground)
        )
    }
}

// MARK: - Preview

#if DEBUG
    struct VoiceSetupTab_Previews: PreviewProvider {
        static var previews: some View {
            VoiceSetupTab()
                .frame(width: 700, height: 600)
                .background(Color(hex: "1a1a1a"))
        }
    }
#endif
