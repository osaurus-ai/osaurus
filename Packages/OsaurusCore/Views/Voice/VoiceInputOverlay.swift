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

    @Environment(\.theme) private var theme
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
        VStack(alignment: .leading, spacing: 10) {
            header

            // live transcription area is hidden during .sending since the
            // bottom "Processing..." indicator is the sole state signal
            if state != .sending {
                transcriptionArea
                    .frame(minHeight: 48, alignment: .topLeading)
            }

            actionArea
        }
        .padding(PickerCardMetrics.padding)
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
        .pickerCardSurface(elevated: true)
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }

    // MARK: - Header

    /// Status as the card heading, the live waveform beside it, and a quiet
    /// close control — the same heading row the composer's other cards use.
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            // Hidden while sending: the centred "Processing..." row is then
            // the sole state signal.
            if state != .sending {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(voiceStatusFromState.label)
                        .font(theme.font(size: CGFloat(theme.smallBodySize) + 2))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                }
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

            VoiceOverlayCloseButton(action: cancelRecording)
                .localizedHelp("Cancel voice input")
        }
    }

    private var statusColor: Color {
        if case .recording = state { return theme.accentColor }
        return theme.tertiaryText
    }

    private var voiceStatusFromState: VoiceState {
        switch state {
        case .idle: return .idle
        case .recording: return .listening
        case .paused: return .processing
        case .sending: return .processing
        }
    }

    // MARK: - Transcription Area

    /// The transcript sits on the card itself, inset like the other cards'
    /// row content; a bordered box here read as an editable text field.
    private var transcriptionArea: some View {
        let font = theme.font(size: CGFloat(theme.bodySize) + 1)
        return HStack(alignment: .firstTextBaseline, spacing: 2) {
            // hide live transcription jitter while recording
            if state == .recording || visibleFullText.isEmpty {
                Text("Speak now…", bundle: .module)
                    .font(font)
                    .foregroundStyle(theme.tertiaryText)
            } else {
                Text(visibleFullText)
                    .font(font)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if case .recording = state {
                Rectangle()
                    .fill(theme.accentColor)
                    .frame(width: 2, height: 17)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                    .modifier(BlinkingCursor())
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PickerCardMetrics.rowInset)
        .padding(.top, 4)
    }

    // MARK: - Action Area

    @ViewBuilder
    private var actionArea: some View {
        switch state {
        case .idle:
            EmptyView()

        case .recording:
            // Recording controls
            HStack(spacing: 10) {
                // Edit transfers the transcript to the text input.
                PickerCardTextLink(title: L("Edit"), icon: "pencil", fillsWidth: false) { onEdit?() }
                    .opacity(visibleFullText.isEmpty ? 0.5 : 1)
                    .disabled(visibleFullText.isEmpty)

                Spacer()

                if transcriptionStopMode == .manual {
                    Button(action: { sendMessage() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text("Stop", bundle: .module)
                                .font(theme.font(size: theme.pickerCardBodySize, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background(Capsule().fill(theme.errorColor))
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
                    .animation(.easeOut(duration: 0.2), value: silenceDuration > 0.2)
                }
            }

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
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Processing...", bundle: .module)
                    .font(theme.font(size: theme.pickerCardBodySize))
                    .foregroundStyle(theme.secondaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
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

/// Quiet × for the card heading: no chrome at rest, a soft circle on hover.
private struct VoiceOverlayCloseButton: View {
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovered ? theme.primaryText : theme.tertiaryText)
                .frame(width: 24, height: 24)
                .background(Circle().fill(hovered ? theme.tertiaryBackground : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Blinking Cursor Modifier

private struct BlinkingCursor: ViewModifier {
    @State private var visible = true

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: visible)
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
                    Color(hex: "0f0f10")
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
                    Color(hex: "0f0f10")
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
