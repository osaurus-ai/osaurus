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

    /// Callbacks
    var onCancel: (() -> Void)?
    var onSend: ((String) -> Void)?
    var onEdit: (() -> Void)?

    @Environment(\.theme) private var theme
    @State private var countdownRemaining: Double = 0
    @State private var countdownTimer: Timer?
    @State private var showEditHint = false

    public init(
        state: Binding<VoiceInputState>,
        audioLevel: Float,
        transcription: String,
        confirmedText: String,
        pauseDuration: Double = 1.5,
        confirmationDelay: Double = 2.0,
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
            // Main content card - designed to seamlessly replace input area
            VStack(spacing: 12) {
                // Header with waveform and cancel
                HStack(alignment: .center, spacing: 16) {
                    // Status indicator
                    VoiceStatusIndicator(
                        state: voiceStatusFromState,
                        showLabel: true,
                        compact: false
                    )

                    // Waveform visualization (when recording)
                    if case .recording = state {
                        WaveformView(level: audioLevel, style: .bars, barCount: 16)
                            .frame(height: 32)
                            .frame(maxWidth: .infinity)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    } else {
                        Spacer()
                    }

                    // Cancel button
                    Button(action: { cancelRecording() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(theme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel voice input")
                }

                // Live transcription area - main focus
                transcriptionArea
                    .frame(minHeight: 60)

                // Action area (countdown or buttons)
                actionArea
            }
            .padding(16)
            .frame(minHeight: 160)
            .background(overlayBackground)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(borderColor, lineWidth: 2)
            )
            .shadow(color: shadowColor, radius: 20, x: 0, y: 6)
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
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.tertiaryBackground)
                    )
                }
                .buttonStyle(.plain)
                .opacity(fullText.isEmpty ? 0.5 : 1)
                .disabled(fullText.isEmpty)

                Spacer()

                // Speak hint
                HStack(spacing: 5) {
                    Image(systemName: "waveform")
                        .font(.system(size: 11))
                    Text("Pause to send")
                        .font(.system(size: 11))
                }
                .foregroundColor(theme.tertiaryText)
            }

        case .paused(let remaining):
            // Countdown to send
            CountdownTimerView(
                duration: confirmationDelay,
                remaining: remaining,
                label: "Sending message...",
                onComplete: { sendMessage() },
                onCancel: { resumeRecording() }
            )
            .transition(.opacity.combined(with: .scale(scale: 0.95)))

        case .sending:
            // Sending indicator
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Sending...")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Styling

    private var overlayBackground: some View {
        ZStack {
            // Frosted glass effect
            if #available(macOS 13.0, *) {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
            } else {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(theme.cardBackground.opacity(0.95))
            }

            // Tint overlay
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(theme.cardBackground.opacity(0.7))
        }
    }

    private var borderColor: Color {
        switch state {
        case .recording: return theme.accentColor.opacity(0.5)
        case .paused: return theme.warningColor.opacity(0.5)
        case .sending: return theme.successColor.opacity(0.5)
        default: return theme.cardBorder
        }
    }

    private var shadowColor: Color {
        switch state {
        case .recording: return theme.accentColor.opacity(0.2)
        case .paused: return theme.warningColor.opacity(0.2)
        default: return Color.black.opacity(0.15)
        }
    }

    // MARK: - Actions

    private func handleStateChange(_ newState: VoiceInputState) {
        switch newState {
        case .paused(let remaining):
            startCountdown(from: remaining)
        case .recording, .idle:
            stopCountdown()
        case .sending:
            stopCountdown()
        }
    }

    private func startCountdown(from duration: Double) {
        countdownRemaining = duration
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            DispatchQueue.main.async {
                countdownRemaining -= 0.1
                if countdownRemaining <= 0 {
                    sendMessage()
                }
            }
        }
    }

    private func stopCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    private func cancelRecording() {
        stopCountdown()
        state = .idle
        onCancel?()
    }

    private func resumeRecording() {
        stopCountdown()
        state = .recording
    }

    private func sendMessage() {
        stopCountdown()
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
        struct PreviewWrapper: View {
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
                            onCancel: { print("Cancelled") },
                            onSend: { text in print("Send: \(text)") },
                            onEdit: { print("Edit") }
                        )
                    }
                }
                .frame(width: 500, height: 400)
            }
        }

        static var previews: some View {
            PreviewWrapper()
        }
    }
#endif
