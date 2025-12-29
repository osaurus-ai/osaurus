//
//  VoiceComponents.swift
//  osaurus
//
//  Shared voice UI components: waveform visualizations, transcription preview,
//  and status indicators for voice input features.
//

import SwiftUI

// MARK: - Waveform Visualization Style

/// Different visualization styles for audio waveforms
public enum WaveformStyle {
    case bars  // Vertical bars with varying heights
    case wave  // Smooth continuous wave
    case circular  // Circular/radial visualization
    case minimal  // Simple pulsing dot
}

// MARK: - Waveform View

/// Animated audio level visualization
public struct WaveformView: View {
    /// Current audio level (0.0 to 1.0)
    let level: Float

    /// Visualization style
    var style: WaveformStyle = .bars

    /// Number of bars (for .bars style)
    var barCount: Int = 12

    /// Primary color (uses theme accent if nil)
    var primaryColor: Color?

    /// Whether the view is actively recording
    var isActive: Bool = true

    @Environment(\.theme) private var theme

    public init(
        level: Float,
        style: WaveformStyle = .bars,
        barCount: Int = 12,
        primaryColor: Color? = nil,
        isActive: Bool = true
    ) {
        self.level = level
        self.style = style
        self.barCount = barCount
        self.primaryColor = primaryColor
        self.isActive = isActive
    }

    public var body: some View {
        switch style {
        case .bars:
            barsView
        case .wave:
            waveView
        case .circular:
            circularView
        case .minimal:
            minimalView
        }
    }

    // MARK: - Bars Style

    private var barsView: some View {
        HStack(spacing: 3) {
            ForEach(0 ..< barCount, id: \.self) { index in
                WaveformBar(
                    index: index,
                    totalBars: barCount,
                    level: level,
                    color: effectiveColor,
                    isActive: isActive
                )
            }
        }
    }

    // MARK: - Wave Style

    private var waveView: some View {
        WaveformWave(level: level, color: effectiveColor, isActive: isActive)
    }

    // MARK: - Circular Style

    private var circularView: some View {
        WaveformCircular(level: level, color: effectiveColor, isActive: isActive)
    }

    // MARK: - Minimal Style

    private var minimalView: some View {
        WaveformMinimal(level: level, color: effectiveColor, isActive: isActive)
    }

    private var effectiveColor: Color {
        primaryColor ?? theme.accentColor
    }
}

// MARK: - Waveform Bar

private struct WaveformBar: View {
    let index: Int
    let totalBars: Int
    let level: Float
    let color: Color
    let isActive: Bool

    @State private var randomOffset: Double = 0

    var body: some View {
        let normalizedLevel = CGFloat(max(0.15, min(1.0, level)))
        let phaseOffset = Double(index) / Double(totalBars) * .pi * 2
        let animatedHeight =
            isActive
            ? normalizedLevel * (0.5 + 0.5 * sin(Date().timeIntervalSince1970 * 8 + phaseOffset + randomOffset)) : 0.15

        RoundedRectangle(cornerRadius: 2)
            .fill(
                LinearGradient(
                    colors: [color, color.opacity(0.6)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 4, height: 24 * animatedHeight)
            .animation(.easeInOut(duration: 0.1), value: level)
            .onAppear {
                randomOffset = Double.random(in: 0 ... 2)
            }
    }
}

// MARK: - Waveform Wave

private struct WaveformWave: View {
    let level: Float
    let color: Color
    let isActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            WaveformWaveCanvas(
                level: level,
                color: color,
                isActive: isActive,
                timestamp: timeline.date.timeIntervalSinceReferenceDate
            )
        }
        .frame(height: 40)
    }
}

private struct WaveformWaveCanvas: View {
    let level: Float
    let color: Color
    let isActive: Bool
    let timestamp: TimeInterval

    var body: some View {
        Canvas { context, size in
            drawWave(context: context, size: size)
        }
    }

    private func drawWave(context: GraphicsContext, size: CGSize) {
        let midY: CGFloat = size.height / 2
        let levelCG: CGFloat = CGFloat(level)
        let amplitude: CGFloat = levelCG * size.height * 0.4
        let wavelength: CGFloat = size.width / 2
        let currentPhase: CGFloat = isActive ? CGFloat(timestamp * 4) : 0

        var path = Path()
        path.move(to: CGPoint(x: 0, y: midY))

        var x: CGFloat = 0
        while x <= size.width {
            let relativeX: CGFloat = x / wavelength
            let angle: CGFloat = relativeX * CGFloat.pi * 2 + currentPhase
            let sine: CGFloat = sin(angle)
            let y: CGFloat = midY + sine * amplitude
            path.addLine(to: CGPoint(x: x, y: y))
            x += 2
        }

        let gradient = Gradient(colors: [color, color.opacity(0.5)])
        let startPt = CGPoint(x: 0, y: size.height / 2)
        let endPt = CGPoint(x: size.width, y: size.height / 2)
        context.stroke(
            path,
            with: .linearGradient(gradient, startPoint: startPt, endPoint: endPt),
            lineWidth: 3
        )
    }
}

// MARK: - Waveform Circular

private struct WaveformCircular: View {
    let level: Float
    let color: Color
    let isActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let phase = isActive ? timeline.date.timeIntervalSinceReferenceDate * 2 : 0

            ZStack {
                // Outer pulsing ring
                Circle()
                    .stroke(color.opacity(0.2), lineWidth: 2)
                    .frame(width: 50, height: 50)
                    .scaleEffect(1 + CGFloat(level) * 0.3 * CGFloat(sin(phase * 3)))

                // Middle ring
                Circle()
                    .stroke(color.opacity(0.4), lineWidth: 2)
                    .frame(width: 35, height: 35)
                    .scaleEffect(1 + CGFloat(level) * 0.2 * CGFloat(sin(phase * 4 + 1)))

                // Inner filled circle
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [color, color.opacity(0.6)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 12
                        )
                    )
                    .frame(width: 20, height: 20)
                    .scaleEffect(0.8 + CGFloat(level) * 0.4)
            }
        }
        .frame(width: 60, height: 60)
    }
}

// MARK: - Waveform Minimal

private struct WaveformMinimal: View {
    let level: Float
    let color: Color
    let isActive: Bool

    @State private var isPulsing = false

    var body: some View {
        ZStack {
            // Pulse ring
            Circle()
                .stroke(color.opacity(0.3), lineWidth: 2)
                .frame(width: 24, height: 24)
                .scaleEffect(isPulsing ? 1.5 : 1.0)
                .opacity(isPulsing ? 0 : 1)

            // Center dot
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .scaleEffect(0.7 + CGFloat(level) * 0.6)
        }
        .frame(width: 36, height: 36)
        .onAppear {
            guard isActive else { return }
            withAnimation(.easeOut(duration: 1.0).repeatForever(autoreverses: false)) {
                isPulsing = true
            }
        }
        .onChange(of: isActive) { _, active in
            if active {
                withAnimation(.easeOut(duration: 1.0).repeatForever(autoreverses: false)) {
                    isPulsing = true
                }
            } else {
                isPulsing = false
            }
        }
    }
}

// MARK: - Transcription Preview View

/// Shows live transcription with a typing effect
public struct TranscriptionPreviewView: View {
    /// The transcription text to display
    let text: String

    /// Whether transcription is in progress (shows cursor)
    var isTranscribing: Bool = false

    /// Placeholder text when empty
    var placeholder: String = "Listening..."

    @Environment(\.theme) private var theme
    @State private var cursorVisible = true

    public init(
        text: String,
        isTranscribing: Bool = false,
        placeholder: String = "Listening..."
    ) {
        self.text = text
        self.isTranscribing = isTranscribing
        self.placeholder = placeholder
    }

    public var body: some View {
        HStack(spacing: 0) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 15))
                    .foregroundColor(theme.tertiaryText)
                    .italic()
            } else {
                Text(text)
                    .font(.system(size: 15))
                    .foregroundColor(theme.primaryText)
            }

            // Blinking cursor
            if isTranscribing {
                Rectangle()
                    .fill(theme.accentColor)
                    .frame(width: 2, height: 18)
                    .opacity(cursorVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: cursorVisible)
                    .onAppear {
                        cursorVisible = true
                    }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            isTranscribing ? theme.accentColor.opacity(0.5) : theme.inputBorder,
                            lineWidth: isTranscribing ? 2 : 1
                        )
                )
        )
    }
}

// MARK: - Voice Status Indicator

/// Voice state for status indicator
public enum VoiceState: Equatable {
    case idle
    case listening
    case processing
    case ready
    case error(String)

    var iconName: String {
        switch self {
        case .idle: return "mic"
        case .listening: return "waveform"
        case .processing: return "ellipsis"
        case .ready: return "checkmark"
        case .error: return "exclamationmark.triangle"
        }
    }

    var label: String {
        switch self {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .processing: return "Processing"
        case .ready: return "Done"
        case .error(let message): return message
        }
    }
}

/// Compact status pill showing current voice state
public struct VoiceStatusIndicator: View {
    let state: VoiceState

    /// Whether to show the label text
    var showLabel: Bool = true

    /// Compact mode (icon only)
    var compact: Bool = false

    @Environment(\.theme) private var theme

    public init(state: VoiceState, showLabel: Bool = true, compact: Bool = false) {
        self.state = state
        self.showLabel = showLabel
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: compact ? 0 : 6) {
            // Animated icon
            ZStack {
                if state == .listening {
                    // Pulsing background for listening state
                    Circle()
                        .fill(stateColor.opacity(0.3))
                        .frame(width: 20, height: 20)
                        .modifier(PulseModifier())
                }

                Image(systemName: state.iconName)
                    .font(.system(size: compact ? 14 : 12, weight: .medium))
                    .foregroundColor(stateColor)
                    .symbolEffect(.pulse, isActive: state == .processing)
            }
            .frame(width: 20, height: 20)

            if showLabel && !compact {
                Text(state.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(stateColor)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, compact ? 8 : 12)
        .padding(.vertical, compact ? 6 : 6)
        .background(
            Capsule()
                .fill(stateColor.opacity(0.1))
        )
        .overlay(
            Capsule()
                .stroke(stateColor.opacity(0.3), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.2), value: state)
    }

    private var stateColor: Color {
        switch state {
        case .idle: return theme.secondaryText
        case .listening: return theme.accentColor
        case .processing: return theme.warningColor
        case .ready: return theme.successColor
        case .error: return theme.errorColor
        }
    }
}

// MARK: - Pulse Modifier

private struct PulseModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? 1.3 : 1.0)
            .opacity(isPulsing ? 0.5 : 1.0)
            .animation(
                .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear {
                isPulsing = true
            }
    }
}

// MARK: - Countdown Timer View

/// Shows a countdown with circular progress for auto-send confirmation
public struct CountdownTimerView: View {
    /// Total duration in seconds
    let duration: Double

    /// Time remaining in seconds
    let remaining: Double

    /// Label to show (e.g., "Sending...")
    var label: String = "Sending..."

    /// Called when countdown completes
    var onComplete: (() -> Void)?

    /// Called when cancelled
    var onCancel: (() -> Void)?

    @Environment(\.theme) private var theme

    public init(
        duration: Double,
        remaining: Double,
        label: String = "Sending...",
        onComplete: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.duration = duration
        self.remaining = remaining
        self.label = label
        self.onComplete = onComplete
        self.onCancel = onCancel
    }

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return 1.0 - (remaining / duration)
    }

    public var body: some View {
        HStack(spacing: 12) {
            // Circular progress
            ZStack {
                Circle()
                    .stroke(theme.tertiaryBackground, lineWidth: 3)
                    .frame(width: 32, height: 32)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(theme.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 32, height: 32)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.1), value: progress)

                Text("\(Int(ceil(remaining)))")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.primaryText)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)

                Text("Tap to cancel")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }

            Spacer()

            // Cancel button
            Button(action: { onCancel?() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(theme.tertiaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(theme.accentColor.opacity(0.3), lineWidth: 2)
                )
        )
    }
}

// MARK: - Preview

#if DEBUG
    struct VoiceComponents_Previews: PreviewProvider {
        static var previews: some View {
            VStack(spacing: 24) {
                // Waveform styles
                HStack(spacing: 20) {
                    WaveformView(level: 0.6, style: .bars)
                    WaveformView(level: 0.6, style: .wave)
                    WaveformView(level: 0.6, style: .circular)
                    WaveformView(level: 0.6, style: .minimal)
                }
                .frame(height: 60)

                // Transcription preview
                TranscriptionPreviewView(
                    text: "Hello, how can I help you today?",
                    isTranscribing: true
                )

                // Status indicators
                HStack(spacing: 12) {
                    VoiceStatusIndicator(state: .idle)
                    VoiceStatusIndicator(state: .listening)
                    VoiceStatusIndicator(state: .processing)
                    VoiceStatusIndicator(state: .ready)
                }

                // Countdown timer
                CountdownTimerView(
                    duration: 3.0,
                    remaining: 2.0,
                    label: "Sending message..."
                )
            }
            .padding()
            .frame(width: 500)
            .background(Color(hex: "1a1a1a"))
        }
    }
#endif
