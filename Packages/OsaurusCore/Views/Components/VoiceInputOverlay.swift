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

    public var body: some View {
        VStack(spacing: 0) {
            // Main content card
            VStack(spacing: 12) {
                // Header with status and controls
                HStack(alignment: .center, spacing: 12) {
                    // Status indicator
                    VoiceStatusIndicator(
                        state: voiceStatusFromState,
                        showLabel: true,
                        compact: false
                    )

                    // Waveform visualization (when recording)
                    if case .recording = state {
                        WaveformView(level: audioLevel, style: .bars, barCount: 16)
                            .frame(height: 28)
                            .frame(maxWidth: .infinity)
                            .transition(.opacity)
                    } else {
                        Spacer()
                    }

                    // Silence timeout hint (all voice input modes, but only when it's user's turn)
                    if silenceTimeoutDuration > 0 && !isStreaming {
                        SilenceTimeoutIndicator(
                            silenceDuration: silenceTimeoutProgress,
                            timeoutDuration: silenceTimeoutDuration
                        )
                    }

                    // Cancel button
                    Button(action: { cancelRecording() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.tertiaryText)
                            .padding(8)
                            .background(
                                ZStack {
                                    Circle()
                                        .fill(theme.tertiaryBackground)
                                    Circle()
                                        .strokeBorder(theme.primaryBorder.opacity(0.15), lineWidth: 1)
                                }
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Cancel voice input")
                }

                // Live transcription area
                transcriptionArea
                    .frame(minHeight: 60)

                // Action area (countdown or buttons)
                actionArea
            }
            .padding(16)
            .frame(minHeight: 160)
            .background(overlayBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .shadow(color: shadowColor, radius: 16, x: 0, y: 6)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .onChange(of: state) { _, newState in
            handleStateChange(newState)
        }
    }

    private var voiceStatusFromState: VoiceState {
        switch state {
        case .idle: return .idle
        case .recording: return .listening
        case .paused: return .processing
        case .sending: return .ready
        }
    }

    // MARK: - Transcription Area

    private var transcriptionArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Combined transcription display
            HStack(alignment: .top, spacing: 2) {
                // Full text with styling
                if fullText.isEmpty {
                    Text("Listening...")
                        .font(.system(size: 15))
                        .foregroundColor(theme.tertiaryText)
                        .italic()
                } else {
                    Text(fullText)
                        .font(.system(size: 15))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Blinking cursor when recording
                if case .recording = state {
                    Rectangle()
                        .fill(theme.accentColor)
                        .frame(width: 2, height: 18)
                        .modifier(BlinkingCursor())
                }

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.inputBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    state == .recording ? theme.accentColor.opacity(0.4) : theme.inputBorder,
                    lineWidth: state == .recording ? 1.5 : 1
                )
        )
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
                // Edit button (transfers to text input)
                Button(action: { onEdit?() }) {
                    HStack(spacing: 5) {
                        Image(systemName: "pencil")
                            .font(.system(size: 12, weight: .medium))
                        Text("Edit")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(theme.tertiaryBackground)
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(theme.primaryBorder.opacity(0.15), lineWidth: 1)
                        }
                    )
                }
                .buttonStyle(.plain)
                .opacity(fullText.isEmpty ? 0.5 : 1)
                .disabled(fullText.isEmpty)

                Spacer()

                // Pause hint with subtle progress
                if pauseDuration > 0 {
                    PauseDetectionRing(
                        silenceDuration: silenceDuration,
                        pauseThreshold: pauseDuration,
                        audioLevel: audioLevel
                    )
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
            // Sending indicator
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Sending...")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Styling

    private var overlayBackground: some View {
        ZStack {
            // Layer 1: Glass material
            if theme.glassEnabled {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
            }

            // Layer 2: Semi-transparent card background
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.cardBackground.opacity(theme.isDark ? 0.85 : 0.92))

            // Layer 3: State-based accent gradient
            LinearGradient(
                colors: [stateAccentColor.opacity(theme.isDark ? 0.08 : 0.05), Color.clear],
                startPoint: .top,
                endPoint: .center
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var stateAccentColor: Color {
        switch state {
        case .recording: return theme.accentColor
        case .paused: return theme.accentColor
        case .sending: return theme.successColor
        default: return theme.accentColor
        }
    }

    private var borderColor: LinearGradient {
        let primaryColor: Color
        let secondaryColor: Color

        switch state {
        case .recording:
            primaryColor = theme.glassEdgeLight.opacity(0.2)
            secondaryColor = theme.cardBorder
        case .paused:
            primaryColor = theme.accentColor.opacity(0.4)
            secondaryColor = theme.accentColor.opacity(0.15)
        case .sending:
            primaryColor = theme.successColor.opacity(0.4)
            secondaryColor = theme.successColor.opacity(0.15)
        default:
            primaryColor = theme.glassEdgeLight.opacity(0.15)
            secondaryColor = theme.cardBorder
        }

        return LinearGradient(
            colors: [primaryColor, secondaryColor],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var shadowColor: Color {
        switch state {
        case .paused: return theme.accentColor.opacity(0.15)
        case .sending: return theme.successColor.opacity(0.15)
        default: return theme.shadowColor.opacity(0.12)
        }
    }

    // MARK: - Actions

    private func handleStateChange(_ newState: VoiceInputState) {
        // Obsolete, countdown handled by parent component now
    }

    private func cancelRecording() {
        state = .idle
        onCancel?()
    }

    private func resumeRecording() {
        state = .recording
    }

    private func sendMessage() {
        state = .sending
        let message = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty {
            onSend?(message)
        }
        // Reset after sending
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            state = .idle
        }
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
