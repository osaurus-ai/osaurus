//
//  VoiceSetupTab.swift
//  osaurus
//
//  Minimal voice setup experience.
//  Clean, focused onboarding with elegant voice testing.
//

import SwiftUI

// MARK: - Voice Setup Tab

struct VoiceSetupTab: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var speechService = SpeechService.shared
    @ObservedObject private var modelManager = SpeechModelManager.shared
    @ObservedObject private var audioInputManager = AudioInputManager.shared
    @ObservedObject private var systemAudioManager = SystemAudioCaptureManager.shared

    /// Called when setup is complete
    var onComplete: (() -> Void)?

    @State private var testTranscription: String = ""
    @State private var isTestingVoice = false
    @State private var testError: String?
    @State private var hasAppeared = false
    @State private var micButtonScale: CGFloat = 1.0
    @State private var isPressed = false

    // Shared audio settings (apply to all voice modes)
    @State private var sensitivity: VoiceSensitivity = .medium
    @State private var hasLoadedSettings = false

    private func loadSettings() {
        sensitivity = SpeechConfigurationStore.load().sensitivity
    }

    private func saveSettings() {
        var config = SpeechConfigurationStore.load()
        config.sensitivity = sensitivity
        SpeechConfigurationStore.save(config)
        NotificationCenter.default.post(name: .voiceConfigurationChanged, object: nil)
    }

    /// Whether all requirements are met
    private var isSetupComplete: Bool {
        speechService.microphonePermissionGranted
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

    /// Current download progress (0-1) if downloading
    private var downloadProgress: Double? {
        for state in modelManager.downloadStates.values {
            if case .downloading(let progress) = state {
                return progress
            }
        }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Onboarding hero — kept in a narrow, centered column
                VStack(spacing: 0) {
                    Spacer()
                        .frame(height: 40)

                    // Requirements checklist (compact)
                    requirementsSection
                        .opacity(hasAppeared ? 1 : 0)
                        .animation(.easeOut(duration: 0.25).delay(0.05), value: hasAppeared)

                    Spacer()
                        .frame(height: 24)

                    // Central voice test area — the hero beat of the two-beat
                    // entrance (house spring; everything else fades in behind it)
                    voiceTestSection
                        .opacity(hasAppeared ? 1 : 0)
                        .scaleEffect(hasAppeared ? 1 : 0.95)
                        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

                    Spacer()
                        .frame(height: 16)

                    // Privacy footer
                    privacyFooter
                        .opacity(hasAppeared ? 1 : 0)
                        .animation(.easeOut(duration: 0.25).delay(0.05), value: hasAppeared)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)

                Spacer()
                    .frame(height: 40)

                // Shared audio settings (sensitivity + input device) — full width,
                // matching the other voice settings tabs.
                audioSettingsSection
                    .opacity(hasAppeared ? 1 : 0)
                    .animation(.easeOut(duration: 0.25).delay(0.05), value: hasAppeared)
                    .padding(.horizontal, 24)

                Spacer()
            }
        }
        .onAppear {
            if !hasLoadedSettings {
                loadSettings()
                hasLoadedSettings = true
            }
            withAnimation {
                hasAppeared = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .voiceConfigurationChanged)) { _ in
            if !isTestingVoice {
                loadSettings()
            }
        }
        .onChange(of: speechService.currentTranscription) { _, newValue in
            if isTestingVoice {
                testTranscription = newValue
            }
        }
        .onChange(of: speechService.confirmedTranscription) { _, newValue in
            if isTestingVoice && !newValue.isEmpty {
                testTranscription = newValue
            }
        }
    }

    // MARK: - Requirements Section

    private var requirementsSection: some View {
        HStack(spacing: 24) {
            // Microphone requirement
            microphoneRequirementItem

            // Separator
            Rectangle()
                .fill(theme.primaryBorder)
                .frame(width: 1, height: 20)

            // Model requirement
            modelRequirementItem
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private var microphoneRequirementItem: some View {
        HStack(spacing: 8) {
            // Status icon
            ZStack {
                if speechService.microphonePermissionGranted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(theme.successColor)
                } else {
                    Circle()
                        .stroke(theme.tertiaryText.opacity(0.5), lineWidth: 1.5)
                        .frame(width: 16, height: 16)
                }
            }
            .frame(width: 20, height: 20)

            Text("Microphone", bundle: .module)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(speechService.microphonePermissionGranted ? theme.primaryText : theme.secondaryText)

            if !speechService.microphonePermissionGranted {
                Button(action: requestMicrophonePermission) {
                    Text("Grant", bundle: .module)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var hasModel: Bool {
        modelManager.downloadedModelsCount > 0 && modelManager.selectedModel != nil
    }

    private var modelRequirementItem: some View {
        HStack(spacing: 8) {
            // Icon with status
            modelStatusIcon
                .frame(width: 20, height: 20)

            // Label
            Text("Speech Model", bundle: .module)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(hasModel ? theme.primaryText : theme.secondaryText)

            // Download action or model name
            modelActionView
        }
    }

    @ViewBuilder
    private var modelStatusIcon: some View {
        if hasModel {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(theme.successColor)
        } else if let progress = downloadProgress {
            ZStack {
                Circle()
                    .stroke(theme.tertiaryBackground, lineWidth: 2)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(theme.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 16, height: 16)
        } else {
            Circle()
                .stroke(theme.tertiaryText.opacity(0.5), lineWidth: 1.5)
                .frame(width: 16, height: 16)
        }
    }

    @ViewBuilder
    private var modelActionView: some View {
        if hasModel {
            if let modelName = modelManager.selectedModel?.name {
                Text(modelName)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
        } else if isDownloading {
            if let progress = downloadProgress {
                Text("\(Int(progress * 100))%", bundle: .module)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.accentColor)
            }
        } else if let recommendedModel = modelManager.availableModels.first(where: { $0.isRecommended }) {
            Button(action: { modelManager.downloadModel(recommendedModel) }) {
                Text("Download", bundle: .module)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.accentColor)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Voice Test Section

    private var voiceTestSection: some View {
        VStack(spacing: 12) {
            // Mic button with waveform ring
            micButton

            // Hint text or transcription
            transcriptionArea

            // Error message
            if let error = testError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
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
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
    }

    private var micButton: some View {
        let buttonSize: CGFloat = 100
        let ringSize: CGFloat = 130

        return ZStack {
            // Outer waveform ring (only when recording)
            if isTestingVoice {
                WaveformRing(
                    level: speechService.audioLevel,
                    size: ringSize,
                    color: theme.accentColor
                )
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            // Idle ring (when not recording but ready)
            if !isTestingVoice && isSetupComplete {
                Circle()
                    .stroke(theme.primaryBorder, lineWidth: 2)
                    .frame(width: ringSize, height: ringSize)
            }

            // Main button
            Button(action: toggleVoiceTest) {
                ZStack {
                    // Background
                    Circle()
                        .fill(
                            isTestingVoice
                                ? theme.errorColor
                                : (isSetupComplete ? theme.accentColor : theme.tertiaryBackground)
                        )
                        .frame(width: buttonSize, height: buttonSize)
                        .shadow(
                            color: isTestingVoice ? theme.errorColor.opacity(0.3) : theme.shadowColor.opacity(0.15),
                            radius: isTestingVoice ? 20 : 10,
                            y: 4
                        )

                    // Icon
                    Image(systemName: isTestingVoice ? "stop.fill" : "mic.fill")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundColor(
                            isSetupComplete
                                ? (isTestingVoice ? .white : (theme.isDark ? theme.primaryBackground : .white))
                                : theme.tertiaryText
                        )
                }
            }
            .buttonStyle(.plain)
            .disabled(!isSetupComplete)
            .scaleEffect(micButtonScale)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: micButtonScale)
            .onLongPressGesture(minimumDuration: .infinity, maximumDistance: .infinity) {
                // Never triggers
            } onPressingChanged: { pressing in
                if isSetupComplete {
                    micButtonScale = pressing ? 0.92 : 1.0
                }
            }
        }
        .frame(width: ringSize, height: ringSize)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: isTestingVoice)
    }

    private var transcriptionArea: some View {
        VStack(spacing: 8) {
            if testTranscription.isEmpty {
                // Hint text
                Text(
                    isTestingVoice
                        ? L("Listening...")
                        : (isSetupComplete ? L("Tap to test your voice") : L("Complete setup to begin"))
                )
                .font(.system(size: 14))
                .foregroundColor(theme.tertiaryText)
                .animation(.easeInOut(duration: 0.2), value: isTestingVoice)
            } else {
                // Transcription with cursor
                HStack(spacing: 0) {
                    Text(testTranscription)
                        .font(.system(size: 15))
                        .foregroundColor(theme.primaryText)
                        .multilineTextAlignment(.center)

                    if isTestingVoice {
                        BlinkingCursor(color: theme.accentColor)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(
                                    isTestingVoice ? theme.accentColor.opacity(0.4) : theme.inputBorder,
                                    lineWidth: 1
                                )
                        )
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .frame(minHeight: 50)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: testTranscription.isEmpty)
    }

    // MARK: - Privacy Footer

    private var privacyFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)

            Text("All processing happens on your Mac", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
        }
    }

    // MARK: - Audio Settings Section

    private var audioSettingsSection: some View {
        VStack(spacing: 16) {
            inputDeviceCard
            sensitivitySettingsCard
        }
    }

    private var sensitivitySettingsCard: some View {
        SettingsSection(title: "Voice Sensitivity", icon: "waveform") {
            VStack(alignment: .leading, spacing: 16) {
                Text("Adjust how sensitive voice detection is", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)

                // Sensitivity Picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sensitivity Level", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    HStack(spacing: 0) {
                        ForEach(VoiceSensitivity.allCases, id: \.self) { level in
                            Button(action: {
                                sensitivity = level
                                saveSettings()
                            }) {
                                Text(level.displayName)
                                    .font(.system(size: 13, weight: sensitivity == level ? .semibold : .medium))
                                    .foregroundColor(
                                        sensitivity == level
                                            ? (theme.isDark ? theme.primaryBackground : .white)
                                            : theme.primaryText
                                    )
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(sensitivity == level ? theme.accentColor : Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                        }
                    }
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(theme.tertiaryBackground)
                    )

                    Text(sensitivity.description)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }

                // Additional info
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundColor(theme.accentColor)
                    Text(
                        "Applies to all voice modes: pause detection, wake word, and voice activity",
                        bundle: .module
                    )
                    .font(.system(size: 11))
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

    private var inputDeviceCard: some View {
        SettingsSection(title: "Audio Input", icon: "mic") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Text(inputSourceDescription)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)

                    Spacer()

                    Button(action: { audioInputManager.refreshDevices() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.tertiaryBackground)
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .localizedHelp("Refresh available devices")
                }

                // Input Source Picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("Input Source", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    HStack(spacing: 8) {
                        ForEach(AudioInputSource.allCases, id: \.self) { source in
                            let isSelected = audioInputManager.selectedInputSource == source
                            let isDisabled = source == .systemAudio && !systemAudioManager.isAvailable

                            Button(action: {
                                if !isDisabled {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        audioInputManager.selectedInputSource = source
                                    }
                                }
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: source.iconName)
                                        .font(.system(size: 12, weight: .medium))
                                    Text(source.displayName)
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .foregroundColor(
                                    isDisabled
                                        ? theme.tertiaryText
                                        : (isSelected
                                            ? (theme.isDark ? theme.primaryBackground : .white) : theme.primaryText)
                                )
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(isSelected ? theme.accentColor : theme.tertiaryBackground)
                                )
                            }
                            .buttonStyle(PlainButtonStyle())
                            .disabled(isDisabled)
                        }

                        Spacer()
                    }
                }

                // Device picker (microphone mode only)
                if audioInputManager.selectedInputSource == .microphone {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Select Input Device", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.secondaryText)

                        Menu {
                            Button(action: { audioInputManager.selectDevice(nil) }) {
                                HStack {
                                    Text("System Default", bundle: .module)
                                    if audioInputManager.selectedDeviceId == nil {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }

                            Divider()

                            ForEach(audioInputManager.availableDevices) { device in
                                Button(action: { audioInputManager.selectDevice(device.id) }) {
                                    HStack {
                                        Text(device.name)
                                        if device.isDefault {
                                            Text("(Default)", bundle: .module)
                                                .foregroundColor(.secondary)
                                        }
                                        if audioInputManager.selectedDeviceId == device.id {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "mic.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(theme.accentColor)

                                Text(selectedDeviceName)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(theme.primaryText)
                                    .lineLimit(1)

                                Spacer()

                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(theme.tertiaryText)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(theme.inputBackground)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(theme.inputBorder, lineWidth: 1)
                                    )
                            )
                        }
                        .menuStyle(.borderlessButton)
                    }
                }
            }
        }
    }

    private var inputSourceDescription: String {
        switch audioInputManager.selectedInputSource {
        case .microphone:
            return audioInputManager.selectedDevice?.name ?? L("System Default")
        case .systemAudio:
            return systemAudioManager.hasPermission
                ? L("Computer audio")
                : L("Permission required")
        }
    }

    private var selectedDeviceName: String {
        if let selectedId = audioInputManager.selectedDeviceId,
            let device = audioInputManager.availableDevices.first(where: { $0.id == selectedId })
        {
            return device.name
        }
        return L("System Default")
    }

    // MARK: - Actions

    private func requestMicrophonePermission() {
        Task {
            _ = await speechService.requestMicrophonePermission()
        }
    }

    private func toggleVoiceTest() {
        if isTestingVoice {
            Task {
                _ = await speechService.stopStreamingTranscription()
                await MainActor.run {
                    isTestingVoice = false
                }
            }
        } else {
            testError = nil
            testTranscription = ""  // Clear previous transcription
            Task {
                do {
                    try await speechService.startStreamingTranscription()
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

// MARK: - Waveform Ring

private struct WaveformRing: View {
    let level: Float
    let size: CGFloat
    let color: Color

    @State private var phase: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let timestamp = timeline.date.timeIntervalSinceReferenceDate

            Canvas { context, canvasSize in
                let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                let baseRadius = size / 2 - 8
                let normalizedLevel = CGFloat(max(0.1, min(1.0, level)))

                // Draw wavy ring
                var path = Path()
                let segments = 60

                for i in 0 ... segments {
                    let angle = (Double(i) / Double(segments)) * .pi * 2
                    let wave1 = sin(angle * 4 + timestamp * 3) * 4 * normalizedLevel
                    let wave2 = sin(angle * 6 + timestamp * 2) * 2 * normalizedLevel
                    let radius = baseRadius + wave1 + wave2

                    let x = center.x + cos(angle) * radius
                    let y = center.y + sin(angle) * radius

                    if i == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                path.closeSubpath()

                context.stroke(
                    path,
                    with: .color(color.opacity(0.6 + Double(normalizedLevel) * 0.4)),
                    lineWidth: 2.5
                )
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Blinking Cursor

private struct BlinkingCursor: View {
    let color: Color

    @State private var isVisible = true

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 2, height: 16)
            .opacity(isVisible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    isVisible = false
                }
            }
    }
}

// MARK: - Preview

#if DEBUG
    struct VoiceSetupTab_Previews: PreviewProvider {
        static var previews: some View {
            VoiceSetupTab()
                .frame(width: 700, height: 600)
                .themedBackground()
        }
    }
#endif
