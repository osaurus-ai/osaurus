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

    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(45, enabled: inspectionEnabled, authoritative: true) }

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
        Group {

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
    
        }.environment(\.theme, theme)
}

    // MARK: - Bars Style

    private var barsView: some View {
        WaveformBars(
            level: level,
            barCount: barCount,
            color: effectiveColor,
            isActive: isActive
        )
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
        primaryColor ?? theme.action.primary.default.background
    }
}

// MARK: - Waveform Bars

/// Waveform visualization with smooth 60fps animation
private struct WaveformBars: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(45, enabled: inspectionEnabled, authoritative: true) }

    let level: Float
    let barCount: Int
    let color: Color
    let isActive: Bool

    @State private var phaseOffsets: [Double] = []

    private let maxBarHeight: CGFloat = 20
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 2

    var body: some View {
        Group {

        // 30fps is visually indistinguishable for a sine-driven waveform and
        // halves the per-frame body evaluations, which showed up in app-hang
        // sampling on memory-starved machines.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let timestamp = timeline.date.timeIntervalSinceReferenceDate

            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(0 ..< barCount, id: \.self) { index in
                    singleBar(index: index, timestamp: timestamp)
                }
            }
        }
        .onAppear {
            if phaseOffsets.isEmpty {
                phaseOffsets = (0 ..< barCount).map { _ in Double.random(in: 0 ... .pi * 2) }
            }
        }
    
        }.environment(\.theme, theme)
}

    @ViewBuilder
    private func singleBar(index: Int, timestamp: TimeInterval) -> some View {
        // Before `onAppear` seeds random offsets, fall back to a per-index phase
        // so bars start desynced. A shared 0 offset would render every bar at the
        // same height on the first frame — a full-height flash before they settle.
        let phaseOffset =
            phaseOffsets.indices.contains(index) ? phaseOffsets[index] : Double(index) * 0.7

        // use the raw level for animation intensity
        let effectiveLevel = CGFloat(max(0.0, min(1.0, level)))

        // animation wave - faster for more life but only visible when level > 0
        let wave = sin(timestamp * 10 + phaseOffset)

        // high sensitivity to voice so it's very responsive
        let voiceSensitivity: CGFloat = 4.0

        // the multiplier is now strictly tied to the audio level.
        // if level is 0, heightMultiplier will be 0 (when active) or 0.2 (when inactive/static)
        let heightMultiplier: CGFloat =
            isActive
            ? (effectiveLevel * voiceSensitivity) * (0.5 + 0.5 * CGFloat(wave + 1) / 2)
            : 0.2

        // the 4px floor is the absolute minimum height.
        // we only add dynamic height if there is actual audio level.
        let dynamicRange = maxBarHeight - 4
        let barHeight: CGFloat = 4 + dynamicRange * min(1.0, heightMultiplier)

        RoundedRectangle(cornerRadius: barWidth / 2)
            .fill(color.opacity(0.8 + 0.2 * Double(min(1.0, heightMultiplier))))
            .frame(width: barWidth, height: barHeight)
    }
}

// MARK: - Waveform Wave

private struct WaveformWave: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(45, enabled: inspectionEnabled, authoritative: true) }

    let level: Float
    let color: Color
    let isActive: Bool

    var body: some View {
        Group {

        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            WaveformWaveCanvas(
                level: level,
                color: color,
                isActive: isActive,
                timestamp: timeline.date.timeIntervalSinceReferenceDate
            )
        }
        .frame(height: 40)
    
        }.environment(\.theme, theme)
}
}

private struct WaveformWaveCanvas: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(45, enabled: inspectionEnabled, authoritative: true) }
    let level: Float
    let color: Color
    let isActive: Bool
    let timestamp: TimeInterval

    var body: some View {
        Group {

        Canvas { context, size in
            drawWave(context: context, size: size)
        }
    
        }.environment(\.theme, theme)
}

    private func drawWave(context: GraphicsContext, size: CGSize) {
        let midY: CGFloat = size.height / 2
        let levelCG: CGFloat = CGFloat(level)

        // amplitude is now strictly tied to the audio level.
        // no base amplitude unless the user is actually speaking.
        let amplitude: CGFloat = levelCG * size.height * 0.8

        let wavelength: CGFloat = size.width / 1.5
        let currentPhase: CGFloat = isActive ? CGFloat(timestamp * 8) : 0

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

        let gradient = Gradient(colors: [color, color.opacity(0.6)])
        let startPt = CGPoint(x: 0, y: size.height / 2)
        let endPt = CGPoint(x: size.width, y: size.height / 2)
        context.stroke(
            path,
            with: .linearGradient(gradient, startPoint: startPt, endPoint: endPt),
            lineWidth: theme.stroke.focus * 1.5
        )
    }
}

// MARK: - Waveform Circular

private struct WaveformCircular: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(45, enabled: inspectionEnabled, authoritative: true) }
    let level: Float
    let color: Color
    let isActive: Bool

    var body: some View {
        Group {

        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let phase = isActive ? timeline.date.timeIntervalSinceReferenceDate * 4 : 0
            let levelCG = CGFloat(level)

            ZStack {
                // Outer pulsing ring - intensity tied to level
                Circle()
                    .stroke(color.opacity(0.2), lineWidth: theme.stroke.focus)
                    .frame(width: 50, height: 50)
                    .scaleEffect(1 + levelCG * 0.5 * CGFloat(sin(phase * 2.5)))

                // Middle ring - intensity tied to level
                Circle()
                    .stroke(color.opacity(0.4), lineWidth: theme.stroke.focus)
                    .frame(width: 35, height: 35)
                    .scaleEffect(1 + levelCG * 0.4 * CGFloat(sin(phase * 3.5 + 1)))

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
                    .scaleEffect(0.8 + levelCG * 0.8)
            }
        }
        .frame(width: 60, height: 60)
    
        }.environment(\.theme, theme)
}
}
// MARK: - Waveform Minimal

private struct WaveformMinimal: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(45, enabled: inspectionEnabled, authoritative: true) }
    let level: Float
    let color: Color
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        Group {

        ZStack {
            // Pulse ring
            Circle()
                .stroke(color.opacity(0.3), lineWidth: theme.stroke.focus)
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
            // Continuous decorative pulse: keep the static ring under Reduce Motion.
            guard isActive, !reduceMotion else { return }
            withAnimation(theme.motion.loop(.easeOut, duration: 1.0)) {
                isPulsing = true
            }
        }
        .onChange(of: isActive) { _, active in
            if active, !reduceMotion {
                withAnimation(theme.motion.loop(.easeOut, duration: 1.0)) {
                    isPulsing = true
                }
            } else {
                isPulsing = false
            }
        }
    
        }.environment(\.theme, theme)
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

    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(45, enabled: inspectionEnabled, authoritative: true) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        Group {

        HStack(spacing: 0) {
            if text.isEmpty {
                Text(placeholder)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.body)
                    .foregroundColor(theme.text.tertiary)
                    .italic()
            } else {
                Text(text)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.body)
                    .foregroundColor(theme.text.primary)
            }

            // Blinking cursor (static under Reduce Motion)
            if isTranscribing {
                Rectangle()
                    .fill(theme.action.primary.default.background)
                    .frame(width: 2, height: 18)
                    .opacity(cursorVisible ? 1 : 0)
                    .animation(
                        reduceMotion
                            ? nil
                            : theme.motion.loop(.easeInOut, duration: 0.5, autoreverses: true),
                        value: cursorVisible
                    )
                    .onAppear {
                        cursorVisible = true
                    }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.45.elements.layout.transcriptionPreviewView.body.paddingX", inheriting: NativeComponentInspectionStyle.metric(45, "padding", 16, theme))).catalogLayoutTarget("component.library.45.elements.layout.transcriptionPreviewView.body.paddingX")
        .padding(.vertical, theme.catalogLayoutMetric("component.library.45.elements.layout.transcriptionPreviewView.body.paddingY", inheriting: NativeComponentInspectionStyle.metric(45, "padding", 14, theme))).catalogLayoutTarget("component.library.45.elements.layout.transcriptionPreviewView.body.paddingY")
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous)
                    .fill(theme.surface.raised)

                if isTranscribing {
                    RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [theme.surface.hover, Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous)
                .strokeBorder(
                    isTranscribing ? theme.border.focus : theme.border.strong,
                    lineWidth: isTranscribing ? 1.5 : 1
                )
        )
    
        }.environment(\.theme, theme)
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
        case .idle: return L("Ready")
        case .listening: return L("Listening")
        case .processing: return L("Processing")
        case .ready: return L("Done")
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

    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(45, enabled: inspectionEnabled, authoritative: true) }

    public init(state: VoiceState, showLabel: Bool = true, compact: Bool = false) {
        self.state = state
        self.showLabel = showLabel
        self.compact = compact
    }

    public var body: some View {
        Group {

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
                    .glyphSize(compact ? 14 : 12, weight: .medium)
                    .foregroundColor(stateColor)
                    .symbolEffect(.pulse, isActive: state == .processing)
            }
            .frame(width: 20, height: 20)

            if showLabel && !compact {
                Text(state.label)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.smallLabel)
                    .foregroundColor(stateColor)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, compact ? 8 : 12)
        .padding(.vertical, compact ? 6 : 7)
        .background(
            ZStack {
                Capsule()
                    .fill(stateColor.opacity(0.1))

                // Subtle gradient for active states
                if state == .listening || state == .processing {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [stateColor.opacity(0.08), Color.clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            stateColor.opacity(0.4),
                            stateColor.opacity(0.2),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: theme.stroke.default
                )
        )
        .animation(theme.motion.quick, value: state)
    
        }.environment(\.theme, theme)
}

    private var stateColor: Color {
        switch state {
        case .idle: return theme.text.secondary
        case .listening: return theme.action.primary.default.background
        case .processing: return theme.status.warning.foreground
        case .ready: return theme.status.success.foreground
        case .error: return theme.status.error.foreground
        }
    }
}

// MARK: - Pulse Modifier

private struct PulseModifier: ViewModifier {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(45, enabled: inspectionEnabled, authoritative: true) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? 1.3 : 1.0)
            .opacity(isPulsing ? 0.5 : 1.0)
            .animation(
                theme.motion.loop(.easeInOut, duration: 0.8, autoreverses: true),
                value: isPulsing
            )
            .onAppear {
                // Continuous decorative pulse: hold the steady state under
                // Reduce Motion.
                if !reduceMotion {
                    isPulsing = true
                }
            }
    }
}

// MARK: - Countdown Ring Button

/// Clean, minimal countdown indicator with progress ring
public struct CountdownRingButton: View {
    /// Total duration in seconds
    let duration: Double

    /// Time remaining in seconds
    let remaining: Double

    /// Called when tapped (to cancel/resume)
    var onTap: (() -> Void)?

    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(45, enabled: inspectionEnabled, authoritative: true) }

    public init(
        duration: Double,
        remaining: Double,
        size: CGFloat = 80,
        onTap: (() -> Void)? = nil
    ) {
        self.duration = duration
        self.remaining = remaining
        self.onTap = onTap
    }

    /// Progress from 0 (just started) to 1 (complete)
    private var progress: Double {
        guard duration > 0 else { return 0 }
        return 1.0 - (remaining / duration)
    }

    /// Current second for display
    private var currentSecond: Int {
        Int(ceil(remaining))
    }

    public var body: some View {
        Group {

        Button(action: { onTap?() }) {
            HStack(spacing: theme.catalogLayoutMetric("component.library.45.elements.layout.countdownRingButton.body.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(45, "gap", 14, theme))) {
                // Circular progress
                ZStack {
                    // Track
                    Circle()
                        .stroke(theme.border.default, lineWidth: theme.stroke.focus * 1.5)
                        .frame(width: 36, height: 36)

                    // Progress (depletes)
                    Circle()
                        .trim(from: 0, to: 1.0 - progress)
                        .stroke(
                            theme.action.primary.default.background,
                            style: StrokeStyle(lineWidth: theme.stroke.focus * 1.5, lineCap: .round)
                        )
                        .frame(width: 36, height: 36)
                        .rotationEffect(.degrees(-90))
                        .animation(theme.motion.quick, value: progress)

                    // Number
                    Text("\(currentSecond)", bundle: .module)
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.mono)
                        .foregroundColor(theme.text.primary)
                        .contentTransition(.numericText())
                }

                // Label
                VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.45.elements.layout.countdownRingButton.body.verticalGap", inheriting: NativeComponentInspectionStyle.metric(45, "gap", 2, theme))) {
                    Text("Sending...", bundle: .module)
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowTitle)
                        .foregroundColor(theme.text.primary)
                    Text("Tap to cancel", bundle: .module)
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                }.catalogLayoutTarget("component.library.45.elements.layout.countdownRingButton.body.verticalGap")

                Spacer()

                // Cancel icon
                Image(systemName: "xmark")
                    .glyphSize(12, weight: .medium)
                    .foregroundColor(theme.text.tertiary)
                    .padding(.horizontal, theme.catalogLayoutMetric("component.library.45.elements.layout.countdownRingButton.body.padding.horizontal", inheriting: NativeComponentInspectionStyle.metric(45, "padding", 8, theme))).padding(.vertical, theme.catalogLayoutMetric("component.library.45.elements.layout.countdownRingButton.body.padding.vertical", inheriting: NativeComponentInspectionStyle.metric(45, "padding", 8, theme))).catalogLayoutTarget("component.library.45.elements.layout.countdownRingButton.body.padding.horizontal").catalogLayoutTarget("component.library.45.elements.layout.countdownRingButton.body.padding.vertical")
                    .background(
                        ZStack {
                            Circle()
                                .fill(theme.surface.hover)
                            Circle()
                                .strokeBorder(theme.border.subtle, lineWidth: theme.stroke.default)
                        }
                    )
            }.catalogLayoutTarget("component.library.45.elements.layout.countdownRingButton.body.horizontalGap")
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.45.elements.layout.countdownRingButton.body.padding2.horizontal", inheriting: NativeComponentInspectionStyle.metric(45, "padding", 14, theme))).padding(.vertical, theme.catalogLayoutMetric("component.library.45.elements.layout.countdownRingButton.body.padding2.vertical", inheriting: NativeComponentInspectionStyle.metric(45, "padding", 14, theme))).catalogLayoutTarget("component.library.45.elements.layout.countdownRingButton.body.padding2.horizontal").catalogLayoutTarget("component.library.45.elements.layout.countdownRingButton.body.padding2.vertical")
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous)
                        .fill(theme.surface.raised)

                    LinearGradient(
                        colors: [theme.surface.hover, Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                theme.border.strong,
                                theme.border.default,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: theme.stroke.default
                    )
            )
        }
        .buttonStyle(.plain)
    
        }.environment(\.theme, theme)
}
}

// MARK: - Pause Detection Ring

/// Subtle inline progress bar showing silence accumulation
public struct PauseDetectionRing: View {
    /// Current silence duration in seconds
    let silenceDuration: Double

    /// Pause threshold (silence required to trigger countdown)
    let pauseThreshold: Double

    /// Current audio level (0.0 to 1.0)
    let audioLevel: Float

    /// Size (unused, kept for API compatibility)
    var size: CGFloat = 60

    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(45, enabled: inspectionEnabled, authoritative: true) }

    public init(
        silenceDuration: Double,
        pauseThreshold: Double,
        audioLevel: Float,
        size: CGFloat = 60
    ) {
        self.silenceDuration = silenceDuration
        self.pauseThreshold = pauseThreshold
        self.audioLevel = audioLevel
        self.size = size
    }

    /// Progress from 0 to 1
    private var progress: Double {
        guard pauseThreshold > 0 else { return 0 }
        return min(1.0, silenceDuration / pauseThreshold)
    }

    /// Whether voice is currently detected
    private var isSpeaking: Bool {
        audioLevel > 0.05
    }

    public var body: some View {
        Group {

        HStack(spacing: theme.catalogLayoutMetric("component.library.45.elements.layout.pauseDetectionRing.body.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(45, "gap", 8, theme))) {
            // Progress bar (only show when there's silence building)
            if progress > 0.1 && !isSpeaking {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // Track
                        RoundedRectangle(cornerRadius: theme.radius.small)
                            .fill(theme.surface.hover)
                            .frame(height: 3)

                        // Progress
                        RoundedRectangle(cornerRadius: theme.radius.small)
                            .fill(progress > 0.7 ? theme.status.warning.foreground : theme.status.info.foreground)
                            .frame(width: geo.size.width * progress, height: 3)
                            .animation(theme.motion.quick, value: progress)
                    }
                }
                .frame(width: 40, height: 3)
            }

            if !isSpeaking {
                Text("Pause to send", bundle: .module)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
            }
        }.catalogLayoutTarget("component.library.45.elements.layout.pauseDetectionRing.body.horizontalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.45.elements.layout.pauseDetectionRing.body.paddingX", inheriting: NativeComponentInspectionStyle.metric(45, "padding", 12, theme))).catalogLayoutTarget("component.library.45.elements.layout.pauseDetectionRing.body.paddingX")
        .padding(.vertical, theme.catalogLayoutMetric("component.library.45.elements.layout.pauseDetectionRing.body.paddingY", inheriting: NativeComponentInspectionStyle.metric(45, "padding", 7, theme))).catalogLayoutTarget("component.library.45.elements.layout.pauseDetectionRing.body.paddingY")
        .background(
            ZStack {
                Capsule()
                    .fill(theme.surface.hover)

                if isSpeaking {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [theme.surface.hover, Color.clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                }
            }
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    isSpeaking ? theme.border.strong : theme.border.subtle,
                    lineWidth: theme.stroke.default
                )
        )
    
        }.environment(\.theme, theme)
}
}

// MARK: - Silence Timeout Indicator

/// Subtle timeout hint shown when silence is detected in VAD mode
public struct SilenceTimeoutIndicator: View {
    /// Current silence duration in seconds
    let silenceDuration: Double

    /// Total timeout duration in seconds
    let timeoutDuration: Double

    /// Size (unused, kept for API compatibility)
    var size: CGFloat = 120

    /// Whether to show countdown
    var showCountdown: Bool = true

    @Environment(\.theme) private var theme

    public init(
        silenceDuration: Double,
        timeoutDuration: Double,
        size: CGFloat = 120,
        showCountdown: Bool = true
    ) {
        self.silenceDuration = silenceDuration
        self.timeoutDuration = timeoutDuration
        self.size = size
        self.showCountdown = showCountdown
    }

    /// Remaining time in seconds
    private var remainingTime: Double {
        max(0, timeoutDuration - silenceDuration)
    }

    /// Only show when silence is significant
    private var shouldShow: Bool {
        silenceDuration > 5.0 && remainingTime < 20
    }

    private var tone: StatusChip.Tone {
        if remainingTime < 5 { return .error }
        if remainingTime < 10 { return .warning }
        return .neutral
    }

    public var body: some View {
        if shouldShow {
            StatusChip(L("Closing in \(Int(remainingTime))s"), tone: tone, icon: "clock")
                .monospacedDigit()
                .contentTransition(.numericText())
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .animation(theme.motion.quick, value: shouldShow)
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

    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(45, enabled: inspectionEnabled, authoritative: true) }

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
        Group {

        HStack(spacing: theme.catalogLayoutMetric("component.library.45.elements.layout.countdownTimerView.body.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(45, "gap", 12, theme))) {
            // Circular progress
            ZStack {
                Circle()
                    .stroke(theme.border.default, lineWidth: theme.stroke.focus * 1.5)
                    .frame(width: 32, height: 32)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(theme.status.info.foreground, style: StrokeStyle(lineWidth: theme.stroke.focus * 1.5, lineCap: .round))
                    .frame(width: 32, height: 32)
                    .rotationEffect(.degrees(-90))
                    .animation(theme.motion.quick, value: progress)

                Text("\(Int(ceil(remaining)))", bundle: .module)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.monoSmall)
                    .foregroundColor(theme.text.primary)
                    .contentTransition(.numericText())
            }

            VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.45.elements.layout.countdownTimerView.body.verticalGap", inheriting: NativeComponentInspectionStyle.metric(45, "gap", 2, theme))) {
                Text(label)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowTitle)
                    .foregroundColor(theme.text.primary)

                Text("Tap to cancel", bundle: .module)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
            }.catalogLayoutTarget("component.library.45.elements.layout.countdownTimerView.body.verticalGap")

            Spacer()

            // Cancel button
            Button(action: { onCancel?() }) {
                Image(systemName: "xmark.circle.fill")
                    .glyphSize(24)
                    .foregroundColor(theme.text.tertiary)
            }
            .buttonStyle(.plain)
        }.catalogLayoutTarget("component.library.45.elements.layout.countdownTimerView.body.horizontalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.45.elements.layout.countdownTimerView.body.padding.horizontal", inheriting: NativeComponentInspectionStyle.metric(45, "padding", 16, theme))).padding(.vertical, theme.catalogLayoutMetric("component.library.45.elements.layout.countdownTimerView.body.padding.vertical", inheriting: NativeComponentInspectionStyle.metric(45, "padding", 16, theme))).catalogLayoutTarget("component.library.45.elements.layout.countdownTimerView.body.padding.horizontal").catalogLayoutTarget("component.library.45.elements.layout.countdownTimerView.body.padding.vertical")
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: theme.radius.xlarge, style: .continuous)
                    .fill(theme.surface.raised)

                LinearGradient(
                    colors: [theme.surface.hover, Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .clipShape(RoundedRectangle(cornerRadius: theme.radius.xlarge, style: .continuous))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.xlarge, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            theme.border.strong,
                            theme.border.default,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: theme.stroke.default
                )
        )
    
        }.environment(\.theme, theme)
}
}

// MARK: - Preview

#if DEBUG
    struct VoiceComponents_Previews: PreviewProvider {
        static var previews: some View {
            VStack(spacing: 20) {
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

                Divider()

                // Pause detection indicator
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pause Detection", bundle: .module)
                        .font(SettingsFont.smallLabel)
                        .foregroundColor(CustomizableTheme.dark().text.tertiary)

                    HStack(spacing: 16) {
                        PauseDetectionRing(
                            silenceDuration: 0.3,
                            pauseThreshold: 1.5,
                            audioLevel: 0.4
                        )

                        PauseDetectionRing(
                            silenceDuration: 1.2,
                            pauseThreshold: 1.5,
                            audioLevel: 0.0
                        )
                    }
                }

                // Countdown button
                VStack(alignment: .leading, spacing: 8) {
                    Text("Countdown", bundle: .module)
                        .font(SettingsFont.smallLabel)
                        .foregroundColor(CustomizableTheme.dark().text.tertiary)

                    CountdownRingButton(
                        duration: 3.0,
                        remaining: 1.8
                    )
                }

                // Silence timeout
                VStack(alignment: .leading, spacing: 8) {
                    Text("Silence Timeout", bundle: .module)
                        .font(SettingsFont.smallLabel)
                        .foregroundColor(CustomizableTheme.dark().text.tertiary)

                    SilenceTimeoutIndicator(
                        silenceDuration: 18,
                        timeoutDuration: 30
                    )
                }
            }
            .padding(24)
            .frame(width: 400)
            .background(CustomizableTheme.dark().surface.canvas)
        }
    }
#endif
