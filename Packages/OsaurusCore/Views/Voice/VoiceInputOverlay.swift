//
//  VoiceInputOverlay.swift
//  osaurus
//
//  Floating overlay that appears when recording voice input in ChatView.
//  Shows waveform visualization, live transcription, and auto-send countdown.
//

import SwiftUI

/// State of the voice input overlay
public enum VoiceInputState: Equatable {
    case idle
    case recording
    case paused(remaining: Double)  // Pause detected, showing countdown
    case sending
}

/// Voice input overlay that appears above the chat input
public struct VoiceInputOverlay: View {
    /// Current recording state
    @Binding var state: VoiceInputState

    /// Current audio level (0.0 to 1.0)
    let audioLevel: Float

    /// Live transcription text
    let transcription: String

    /// Confirmed/final transcription
    let confirmedText: String

    /// Configuration for pause detection and confirmation delay
    let pauseDuration: Double
    let confirmationDelay: Double

    /// Current silence duration (for pause detection ring)
    var silenceDuration: Double = 0

    /// Silence timeout for VAD continuous mode (0 = disabled)
    var silenceTimeoutDuration: Double = 0

    /// Current silence timeout progress (for silence timeout indicator)
    var silenceTimeoutProgress: Double = 0

    /// Whether in continuous voice mode (VAD)
    var isContinuousMode: Bool = false

    /// Whether AI is currently streaming a response
    var isStreaming: Bool = false

    /// How to stop voice recording (automatic silence detection or manual)
    let transcriptionStopMode: TranscriptionStopMode

    /// Callbacks
    var onCancel: (() -> Void)?
    var onSend: ((String) -> Void)?
    var onEdit: (() -> Void)?

    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(45, enabled: inspectionEnabled) }
    @State private var showEditHint = false

    public init(
        state: Binding<VoiceInputState>,
        audioLevel: Float,
        transcription: String,
        confirmedText: String,
        pauseDuration: Double = 1.5,
        confirmationDelay: Double = 2.0,
        silenceDuration: Double = 0,
        silenceTimeoutDuration: Double = 0,
        silenceTimeoutProgress: Double = 0,
        isContinuousMode: Bool = false,
        isStreaming: Bool = false,
        transcriptionStopMode: TranscriptionStopMode = .automatic,
        onCancel: (() -> Void)? = nil,
        onSend: ((String) -> Void)? = nil,
        onEdit: (() -> Void)? = nil
    ) {
        self._state = state
        self.audioLevel = audioLevel
        self.transcription = transcription
        self.confirmedText = confirmedText
        self.pauseDuration = pauseDuration
        self.confirmationDelay = confirmationDelay
        self.silenceDuration = silenceDuration
        self.silenceTimeoutDuration = silenceTimeoutDuration
        self.silenceTimeoutProgress = silenceTimeoutProgress
        self.isContinuousMode = isContinuousMode
        self.isStreaming = isStreaming
        self.transcriptionStopMode = transcriptionStopMode
        self.onCancel = onCancel
        self.onSend = onSend
        self.onEdit = onEdit
    }

    /// Combined text from confirmed and current transcription
    private var fullText: String {
        if confirmedText.isEmpty {
            return transcription
        } else if transcription.isEmpty {
            return confirmedText
        } else {
            return confirmedText + " " + transcription
        }
    }

    private var visibleFullText: String {
        TranscriptionTextNormalizer.visibleText(fullText)
    }

    public var body: some View {
        Group {

        VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.45.elements.layout.voiceInputOverlay.body.verticalGap", inheriting: NativeComponentInspectionStyle.metric(45, "gap", theme.space.s10, theme))) {
            header

            // live transcription area is hidden during .sending since the
            // bottom "Processing..." indicator is the sole state signal
            if state != .sending {
                transcriptionArea
                    .frame(minHeight: 48, alignment: .topLeading)
            }

            actionArea
        }.catalogLayoutTarget("component.library.45.elements.layout.voiceInputOverlay.body.verticalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.45.elements.layout.voiceInputOverlay.body.padding.horizontal", inheriting: NativeComponentInspectionStyle.metric(45, "padding", PickerCardMetrics.padding, theme))).padding(.vertical, theme.catalogLayoutMetric("component.library.45.elements.layout.voiceInputOverlay.body.padding.vertical", inheriting: NativeComponentInspectionStyle.metric(45, "padding", PickerCardMetrics.padding, theme))).catalogLayoutTarget("component.library.45.elements.layout.voiceInputOverlay.body.padding.horizontal").catalogLayoutTarget("component.library.45.elements.layout.voiceInputOverlay.body.padding.vertical")
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
        .pickerCardSurface(elevated: true, assignmentFamily: 45)
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.45.elements.layout.voiceInputOverlay.body.paddingX", inheriting: NativeComponentInspectionStyle.metric(45, "padding", theme.space.s20, theme))).catalogLayoutTarget("component.library.45.elements.layout.voiceInputOverlay.body.paddingX")
        .padding(.bottom, theme.space.s20)
    
        }.environment(\.theme, theme)
}

    // MARK: - Header

    /// Status as the card heading, the live waveform beside it, and a quiet
    /// close control — the same heading row the composer's other cards use.
    private var header: some View {
        HStack(alignment: .center, spacing: theme.catalogLayoutMetric("component.library.45.elements.layout.voiceInputOverlay.header.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(45, "gap", theme.space.s10, theme))) {
            // Hidden while sending: the centred "Processing..." row is then
            // the sole state signal.
            if state != .sending {
                HStack(spacing: theme.catalogLayoutMetric("component.library.45.elements.layout.voiceInputOverlay.header.horizontalGap2", inheriting: NativeComponentInspectionStyle.metric(45, "gap", theme.space.s8, theme))) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(voiceStatusLabel)
                        .componentInspectionText(45, role: .body, fallback: .body, theme: theme)
                        .foregroundStyle(theme.text.secondary)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                }.catalogLayoutTarget("component.library.45.elements.layout.voiceInputOverlay.header.horizontalGap2")
            }

            if case .recording = state {
                WaveformView(level: audioLevel, style: .bars, barCount: 16)
                    .frame(height: 24)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            } else {
                Spacer(minLength: 0)
            }

            // Silence timeout hint (all voice input modes, but only when it's user's turn)
            if silenceTimeoutDuration > 0 && !isStreaming {
                SilenceTimeoutIndicator(
                    silenceDuration: silenceTimeoutProgress,
                    timeoutDuration: silenceTimeoutDuration
                )
            }

            VoiceOverlayIconButton(icon: "xmark", label: "Cancel voice input", action: cancelRecording)
        }.catalogLayoutTarget("component.library.45.elements.layout.voiceInputOverlay.header.horizontalGap")
    }

    private var statusColor: Color {
        if case .recording = state { return theme.status.info.foreground }
        return theme.text.tertiary
    }

    private var voiceStatusLabel: String {
        switch state {
        case .idle: return VoiceState.idle.label
        case .recording: return VoiceState.listening.label
        case .paused: return L("Ready to send")
        case .sending: return VoiceState.processing.label
        }
    }

    // MARK: - Transcription Area

    /// The transcript sits on the card itself, inset like the other cards'
    /// row content; a bordered box here read as an editable text field.
    private var transcriptionArea: some View {
        return HStack(alignment: .firstTextBaseline, spacing: theme.catalogLayoutMetric("component.library.45.elements.layout.voiceInputOverlay.transcriptionArea.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(45, "gap", theme.space.s2, theme))) {
            // hide live transcription jitter while recording
            if state == .recording || visibleFullText.isEmpty {
                Text("Speak now…", bundle: .module)
                    .componentInspectionText(45, role: .body, fallback: .body, theme: theme)
                    .foregroundStyle(theme.text.tertiary)
            } else {
                Text(visibleFullText)
                    .componentInspectionText(45, role: .body, fallback: .body, theme: theme)
                    .foregroundStyle(theme.text.primary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if case .recording = state {
                Rectangle()
                    .fill(theme.action.primary.default.background)
                    .frame(width: 2, height: 17)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                    .modifier(BlinkingCursor())
            }

            Spacer(minLength: 0)
        }.catalogLayoutTarget("component.library.45.elements.layout.voiceInputOverlay.transcriptionArea.horizontalGap")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.45.elements.layout.voiceInputOverlay.transcriptionArea.paddingX", inheriting: NativeComponentInspectionStyle.metric(45, "padding", PickerCardMetrics.rowInset, theme))).catalogLayoutTarget("component.library.45.elements.layout.voiceInputOverlay.transcriptionArea.paddingX")
        .padding(.top, theme.space.s4)
    }

    // MARK: - Action Area

    @ViewBuilder
    private var actionArea: some View {
        switch state {
        case .idle:
            EmptyView()

        case .recording:
            // Recording controls
            HStack(spacing: theme.catalogLayoutMetric("component.library.45.elements.layout.voiceInputOverlay.actionArea.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(45, "gap", theme.space.s10, theme))) {
                // Edit transfers the transcript to the text input.
                PickerCardTextLink(title: L("Edit"), icon: "pencil", fillsWidth: false) { onEdit?() }
                    .opacity(visibleFullText.isEmpty ? 0.5 : 1)
                    .disabled(visibleFullText.isEmpty)

                Spacer()

                if transcriptionStopMode == .manual {
                    Button(action: { sendMessage() }) {
                        StatusChip(L("Stop"), tone: .error, icon: "stop.fill")
                        .frame(height: 28)
                    }
                    .buttonStyle(.plain)
                    .opacity(visibleFullText.isEmpty ? 0.5 : 1)
                    .disabled(visibleFullText.isEmpty)
                } else {
                    // wrap only the ring in an animated container so its
                    // appearance/disappearance transition is scoped. also prevents
                    // implicit animation cross-talk onto the Edit/Stop buttons.
                    ZStack {
                        if pauseDuration > 0 && silenceDuration > 0.2 {
                            PauseDetectionRing(
                                silenceDuration: silenceDuration,
                                pauseThreshold: pauseDuration,
                                audioLevel: audioLevel
                            )
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        }
                    }
                    .animation(theme.motion.quick, value: silenceDuration > 0.2)
                }
            }.catalogLayoutTarget("component.library.45.elements.layout.voiceInputOverlay.actionArea.horizontalGap")

        case .paused(let remaining):
            // Clean countdown card - use state remaining value
            CountdownRingButton(
                duration: confirmationDelay,
                remaining: remaining,
                onTap: { resumeRecording() }
            )
            .transition(.opacity)

        case .sending:
            // processing indicator (LLM cleanup runs here)
            HStack(spacing: theme.catalogLayoutMetric("component.library.45.elements.layout.voiceInputOverlay.actionArea.horizontalGap2", inheriting: NativeComponentInspectionStyle.metric(45, "gap", theme.space.s8, theme))) {
                SettingsSpinner()
                Text("Processing...", bundle: .module)
                    .componentInspectionText(45, role: .body, fallback: .bodySmall, theme: theme)
                    .foregroundStyle(theme.text.secondary)
            }.catalogLayoutTarget("component.library.45.elements.layout.voiceInputOverlay.actionArea.horizontalGap2")
            .frame(maxWidth: .infinity)
            .padding(.vertical, theme.catalogLayoutMetric("component.library.45.elements.layout.voiceInputOverlay.actionArea.paddingY", inheriting: NativeComponentInspectionStyle.metric(45, "padding", theme.space.s10, theme))).catalogLayoutTarget("component.library.45.elements.layout.voiceInputOverlay.actionArea.paddingY")
        }
    }

    // MARK: - Actions

    private func cancelRecording() {
        state = .idle
        onCancel?()
    }

    private func resumeRecording() {
        state = .recording
    }

    private func sendMessage() {
        let message = visibleFullText
        guard !message.isEmpty else { return }
        state = .sending
        onSend?(message)
        // FloatingInputCard.sendVoiceMessage owns the rest of the
        // lifecycle. It runs cleanup, then resets state/dismisses the overlay.
        // We intentionally do not auto reset here as doing so caused a visible
        // flicker between .sending and dismissal while cleanup was in flight
    }
}

/// Shared icon action for the voice input and Transcription Mode overlays.
struct VoiceOverlayIconButton: View {
    let icon: String
    let label: LocalizedStringKey
    let action: () -> Void
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(45, enabled: inspectionEnabled) }
    @State private var hovered = false

    var body: some View {
        let size = NativeComponentInspectionStyle.metric(45, "height", 24, theme)
        Button(action: action) {
            Image(systemName: icon)
                .glyphSize(.footnote, weight: .semibold)
                .foregroundStyle(hovered ? theme.text.primary : theme.text.tertiary)
                .frame(width: size, height: size)
                .componentInspectionSurface(45, background: hovered ? theme.surface.hover : .clear, radius: 12)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(Text(label, bundle: .module))
        .localizedHelp(label)
        .environment(\.theme, theme)
    }
}

// MARK: - Blinking Cursor Modifier

private struct BlinkingCursor: ViewModifier {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(45, enabled: inspectionEnabled) }
    @State private var visible = true

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .animation(theme.motion.loop(.easeInOut, duration: 0.5, autoreverses: true), value: visible)
            .onAppear {
                visible = true
            }
    }
}

// MARK: - Preview

#if DEBUG
    struct VoiceInputOverlay_Previews: PreviewProvider {
        struct RecordingPreview: View {
            @State private var state: VoiceInputState = .recording

            var body: some View {
                ZStack(alignment: .bottom) {
                    CustomizableTheme.dark().surface.canvas
                        .ignoresSafeArea()

                    VStack {
                        Spacer()

                        VoiceInputOverlay(
                            state: $state,
                            audioLevel: 0.5,
                            transcription: "Hello, how can I help you",
                            confirmedText: "",
                            pauseDuration: 1.5,
                            confirmationDelay: 2.0,
                            silenceDuration: 0.8,
                            silenceTimeoutDuration: 30.0,
                            isContinuousMode: true,
                            transcriptionStopMode: .automatic,
                            onCancel: { print("Cancelled") },
                            onSend: { text in print("Send: \(text)") },
                            onEdit: { print("Edit") }
                        )
                    }
                }
                .frame(width: 500, height: 450)
            }
        }

        struct CountdownPreview: View {
            @State private var state: VoiceInputState = .paused(remaining: 1.8)

            var body: some View {
                ZStack(alignment: .bottom) {
                    CustomizableTheme.dark().surface.canvas
                        .ignoresSafeArea()

                    VStack {
                        Spacer()

                        VoiceInputOverlay(
                            state: $state,
                            audioLevel: 0.0,
                            transcription: "",
                            confirmedText: "What's the weather like today?",
                            pauseDuration: 1.5,
                            confirmationDelay: 2.0,
                            silenceDuration: 1.5,
                            transcriptionStopMode: .automatic,
                            onCancel: { print("Cancelled") },
                            onSend: { text in print("Send: \(text)") },
                            onEdit: { print("Edit") }
                        )
                    }
                }
                .frame(width: 500, height: 450)
            }
        }

        static var previews: some View {
            Group {
                RecordingPreview()
                    .previewDisplayName("Recording")

                CountdownPreview()
                    .previewDisplayName("Countdown")
            }
        }
    }
#endif
