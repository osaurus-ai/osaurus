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
                        .animation(theme.motion.standard.delay(0.05), value: hasAppeared)

                    Spacer()
                        .frame(height: 24)

                    // Central voice test area — the hero beat of the two-beat
                    // entrance (house spring; everything else fades in behind it)
                    voiceTestSection
                        .opacity(hasAppeared ? 1 : 0)
                        .scaleEffect(hasAppeared ? 1 : 0.95)
                        .animation(theme.motion.springAnimation, value: hasAppeared)

                    Spacer()
                        .frame(height: 16)

                    // Privacy footer
                    privacyFooter
                        .opacity(hasAppeared ? 1 : 0)
                        .animation(theme.motion.standard.delay(0.05), value: hasAppeared)
                }
                .padding(.horizontal, theme.space.s24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)

                Spacer()
                    .frame(height: 40)

                // Shared audio settings (sensitivity + input device) — full width,
                // matching the other voice settings tabs.
                audioSettingsSection
                    .opacity(hasAppeared ? 1 : 0)
                    .animation(theme.motion.standard.delay(0.05), value: hasAppeared)
                    .padding(.horizontal, theme.space.s24)

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
                .fill(theme.border.subtle)
                .frame(width: 1, height: 20)

            // Model requirement
            modelRequirementItem
        }
        .padding(.horizontal, theme.space.s16)
        .padding(.vertical, theme.space.s12)
        .settingsChrome(.card)
    }

    private var microphoneRequirementItem: some View {
        HStack(spacing: 8) {
            // Status icon
            ZStack {
                if speechService.microphonePermissionGranted {
                    Image(systemName: "checkmark.circle.fill")
                        .glyphSize(16, weight: .medium)
                        .foregroundColor(theme.status.success.foreground)
                } else {
                    Circle()
                        .stroke(theme.border.default, lineWidth: theme.stroke.default)
                        .frame(width: 16, height: 16)
                }
            }
            .frame(width: 20, height: 20)

            Text("Microphone", bundle: .module)
                .font(SettingsFont.rowTitle)
                .foregroundColor(speechService.microphonePermissionGranted ? theme.text.primary : theme.text.secondary)

            if !speechService.microphonePermissionGranted {
                Button(action: requestMicrophonePermission) {
                    Text("Grant", bundle: .module)
                        .font(SettingsFont.smallLabel)
                        .foregroundColor(theme.text.link)
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
            // `voice.stt.model` landing: the checklist item is the fastest
            // route to a working transcription model.
            // Icon with status
            modelStatusIcon
                .frame(width: 20, height: 20)

            // Label
            Text("Speech Model", bundle: .module)
                .font(SettingsFont.rowTitle)
                .foregroundColor(hasModel ? theme.text.primary : theme.text.secondary)

            // Download action or model name
            modelActionView
        }
        .settingsLandingAnchor("voice.stt.model")
    }

    @ViewBuilder
    private var modelStatusIcon: some View {
        if hasModel {
            Image(systemName: "checkmark.circle.fill")
                .glyphSize(16, weight: .medium)
                .foregroundColor(theme.status.success.foreground)
        } else if let progress = downloadProgress {
            ZStack {
                Circle()
                    .stroke(theme.border.default, lineWidth: theme.stroke.focus)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(theme.status.info.foreground, style: StrokeStyle(lineWidth: theme.stroke.focus, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 16, height: 16)
        } else {
            Circle()
                .stroke(theme.border.default, lineWidth: theme.stroke.default)
                .frame(width: 16, height: 16)
        }
    }

    @ViewBuilder
    private var modelActionView: some View {
        if hasModel {
            if let modelName = modelManager.selectedModel?.name {
                Text(modelName)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
            }
        } else if isDownloading {
            if let progress = downloadProgress {
                Text("\(Int(progress * 100))%", bundle: .module)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.link)
            }
        } else if let recommendedModel = modelManager.availableModels.first(where: { $0.isRecommended }) {
            Button(action: { modelManager.downloadModel(recommendedModel) }) {
                Text("Download", bundle: .module)
                    .font(SettingsFont.smallLabel)
                    .foregroundColor(theme.text.link)
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
                        .glyphSize(11)
                    Text(error)
                        .font(SettingsFont.caption)
                }
                .foregroundColor(theme.status.error.foreground)
                .padding(.horizontal, theme.space.s12)
                .padding(.vertical, theme.space.s8)
                .settingsChrome(.status(.error))
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
                    color: theme.action.primary.default.background
                )
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            // Idle ring (when not recording but ready)
            if !isTestingVoice && isSetupComplete {
                Circle()
                    .stroke(theme.border.subtle, lineWidth: theme.stroke.focus)
                    .frame(width: ringSize, height: ringSize)
            }

            // Main button
            Button(action: toggleVoiceTest) {
                ZStack {
                    // Background
                    Circle()
                        .fill(
                            isTestingVoice
                                ? theme.status.error.foreground
                                : (isSetupComplete ? theme.action.primary.default.background : theme.surface.hover)
                        )
                        .frame(width: buttonSize, height: buttonSize)
                        .themeElevation(theme.elevation.overlay)

                    // Icon
                    Image(systemName: isTestingVoice ? "stop.fill" : "mic.fill")
                        .glyphSize(32, weight: .medium)
                        .foregroundColor(
                            isSetupComplete
                                ? (isTestingVoice ? .white : (theme.isDark ? theme.surface.canvas : .white))
                                : theme.text.tertiary
                        )
                }
            }
            .buttonStyle(.plain)
            .disabled(!isSetupComplete)
            .scaleEffect(micButtonScale)
            .animation(theme.motion.springAnimation, value: micButtonScale)
            .onLongPressGesture(minimumDuration: .infinity, maximumDistance: .infinity) {
                // Never triggers
            } onPressingChanged: { pressing in
                if isSetupComplete {
                    micButtonScale = pressing ? 0.92 : 1.0
                }
            }
        }
        .frame(width: ringSize, height: ringSize)
        .animation(theme.motion.springAnimation, value: isTestingVoice)
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
                .textStyle(.bodySmall)
                .foregroundColor(theme.text.tertiary)
                .animation(theme.motion.quick, value: isTestingVoice)
            } else {
                // Transcription with cursor
                HStack(spacing: 0) {
                    Text(testTranscription)
                        .font(SettingsFont.body)
                        .foregroundColor(theme.text.primary)
                        .multilineTextAlignment(.center)

                    if isTestingVoice {
                        BlinkingCursor(color: theme.action.primary.default.background)
                    }
                }
                .padding(.horizontal, theme.space.s16)
                .padding(.vertical, theme.space.s12)
                .settingsChrome(isTestingVoice ? .selected : .control)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .frame(minHeight: 50)
        .animation(theme.motion.springAnimation, value: testTranscription.isEmpty)
    }

    // MARK: - Privacy Footer

    private var privacyFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .glyphSize(10)
                .foregroundColor(theme.text.tertiary)

            Text("All processing happens on your Mac", bundle: .module)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
        }
    }

    // MARK: - Audio Settings Section

    private var audioSettingsSection: some View {
        VStack(spacing: theme.settingsSectionGap) {
            inputDeviceCard
            sensitivitySettingsCard
        }
    }

    private var sensitivitySettingsCard: some View {
        SettingsSection(
            title: "Voice Sensitivity",
            subtitle: "Applies to every voice mode: pause detection, wake word and voice activity.",
            anchorId: "voice.setup.sensitivity"
        ) {
            SettingsPickerRow(
                title: "Sensitivity Level",
                description: sensitivity.description,
                selection: Binding(
                    get: { sensitivity },
                    set: {
                        sensitivity = $0
                        saveSettings()
                    }
                ),
                options: VoiceSensitivity.allCases.map { .init($0, $0.displayName, verbatim: true) }
            )
        }
    }

    private var inputDeviceCard: some View {
        SettingsSection(title: "Audio Input") {
            // System Audio needs a macOS that can capture it; without it the
            // microphone is the only source and there is nothing to choose.
            if systemAudioManager.isAvailable {
                SettingsPickerRow(
                    title: "Input Source",
                    description: inputSourceDescription,
                    selection: Binding(
                        get: { audioInputManager.selectedInputSource },
                        set: { source in
                            withAnimation(theme.motion.quick) {
                                audioInputManager.selectedInputSource = source
                            }
                        }
                    ),
                    options: AudioInputSource.allCases.map { .init($0, $0.displayName, verbatim: true) }
                )
            }

            if audioInputManager.selectedInputSource == .microphone {
                SettingsRow(title: "Select Input Device", description: "System Default follows the input chosen in macOS Sound settings.") {
                    HStack(spacing: theme.settingsControlGap) {
                        SettingsMenuPicker(
                            selection: Binding(
                                get: { audioInputManager.selectedDeviceId },
                                set: { audioInputManager.selectDevice($0) }
                            )
                        ) {
                            Text("System Default", bundle: .module).tag(String?.none)
                            Divider()
                            ForEach(audioInputManager.availableDevices) { device in
                                Group {
                                    if device.isDefault {
                                        Text(verbatim: device.name + " ") + Text("(Default)", bundle: .module)
                                    } else {
                                        Text(verbatim: device.name)
                                    }
                                }
                                .tag(String?.some(device.id))
                            }
                        }
                        .settingsPickerHugging()
                        .accessibilityLabel(Text("Select Input Device", bundle: .module))

                        SettingsIconButton("arrow.clockwise", help: "Refresh available devices", size: .compact) {
                            audioInputManager.refreshDevices()
                        }
                    }
                }
            }
        }
    }

    private var inputSourceDescription: String {
        switch audioInputManager.selectedInputSource {
        case .microphone:
            return L("Your voice, through the input device below.")
        case .systemAudio:
            return systemAudioManager.hasPermission
                ? L("Audio playing on this Mac, except Osaurus's own output.")
                : L("Needs Screen Recording permission.")
        }
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
    @Environment(\.theme) private var theme
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
                    lineWidth: theme.stroke.focus
                )
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Blinking Cursor

private struct BlinkingCursor: View {
    @Environment(\.theme) private var theme
    let color: Color

    @State private var isVisible = true

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 2, height: 16)
            .opacity(isVisible ? 1 : 0)
            .onAppear {
                withAnimation(theme.motion.loop(.easeInOut, duration: 0.5, autoreverses: true)) {
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
