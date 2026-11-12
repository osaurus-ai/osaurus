//
//  AnimatedProgressComponents.swift
//  osaurus
//
//  Animated progress components for background tasks including
//  shimmer progress bars, typing indicators, and morphing status icons.
//

import SwiftUI

// MARK: - Indeterminate Shimmer Progress

/// Animated indeterminate progress indicator with flowing gradient
struct IndeterminateShimmerProgress: View {
    @Environment(\.theme) private var theme
    let color: Color
    var height: CGFloat = 4

    // Animate the gradient's start/end points from off-left (-0.7…-0.3)
    // to off-right (1.0…1.4), keeping the sweep block at 40% of the bar width
    // without needing a GeometryReader or pixel math.
    @State private var phase: CGFloat = 0

    private var gradient: LinearGradient {
        LinearGradient(
            colors: [.clear, color.opacity(0.6), color, color.opacity(0.6), .clear],
            startPoint: UnitPoint(x: phase - 0.4, y: 0.5),
            endPoint: UnitPoint(x: phase + 0.4, y: 0.5)
        )
    }

    private var trackColor: Color { theme.emptyTrack(theme.surface.subtle) }

    var body: some View {
        RoundedRectangle(cornerRadius: height / 2)
            .fill(trackColor)
            .frame(height: height)
            .overlay(
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(gradient)
            )
            .onAppear {
                withAnimation(
                    theme.motion.slow
                        .repeatForever(autoreverses: true)
                ) {
                    phase = 1
                }
            }
    }
}

// MARK: - Configurable Typing Indicator

/// Three-dot typing indicator with staggered bounce animation and configurable colors
struct ConfigurableTypingIndicator: View {
    @Environment(\.theme) private var theme
    let color: Color
    var dotSize: CGFloat = 6
    var spacing: CGFloat = 4

    @State private var animatingDots = [false, false, false]

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0 ..< 3, id: \.self) { index in
                Circle()
                    .fill(color)
                    .frame(width: dotSize, height: dotSize)
                    .offset(y: animatingDots[index] ? -4 : 0)
                    .animation(
                        theme.motion.slow
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animatingDots[index]
                    )
            }
        }
        .onAppear {
            // Stagger the animation start
            for i in 0 ..< 3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.1) {
                    animatingDots[i] = true
                }
            }
        }
    }
}

// MARK: - Pulsing Status Dot

/// A status dot with optional pulsing ring animation
struct PulsingStatusDot: View {
    @Environment(\.theme) private var theme

    let color: Color
    let isPulsing: Bool
    var size: CGFloat = 8

    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.8

    var body: some View {
        ZStack {
            // Pulsing ring
            if isPulsing {
                Circle()
                    .stroke(color.opacity(pulseOpacity), lineWidth: theme.stroke.focus)
                    .frame(width: size, height: size)
                    .scaleEffect(pulseScale)
            }

            // Core dot
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
        .frame(width: size * 2.5, height: size * 2.5)
        .onAppear {
            if isPulsing {
                startPulseAnimation()
            }
        }
        .onChange(of: isPulsing) { _, newValue in
            if newValue {
                startPulseAnimation()
            }
        }
    }

    private func startPulseAnimation() {
        withAnimation(
            theme.motion.slow
                .repeatForever(autoreverses: false)
        ) {
            pulseScale = 2.5
            pulseOpacity = 0
        }
    }
}

// MARK: - Status Icon State

/// Represents the visual state of a morphing status icon.
/// Used by `MorphingStatusIcon` to animate between different states.
internal enum StatusIconState {
    case pending
    case active
    case completed
    case failed
}

// MARK: - Morphing Status Icon

/// Icon that morphs between states: empty circle → spinner → checkmark
struct MorphingStatusIcon: View {
    @Environment(\.theme) private var theme

    let state: StatusIconState
    let accentColor: Color
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            switch state {
            case .pending:
                pendingIcon

            case .active:
                ActiveSpinnerIcon(accentColor: accentColor, size: size)

            case .completed:
                CompletedCheckmarkIcon(theme: theme, size: size)

            case .failed:
                failedIcon
            }
        }
        .frame(width: size, height: size)
    }

    // MARK: - State Views

    private var pendingIcon: some View {
        Circle()
            .strokeBorder(theme.border.default, lineWidth: theme.stroke.default)
            .frame(width: size, height: size)
    }

    private var failedIcon: some View {
        ZStack {
            Circle()
                .fill(theme.status.error.foreground)
                .frame(width: size, height: size)

            Image(systemName: "xmark")
                .glyphSize(points: size * 0.5, weight: .bold)
                .foregroundColor(theme.text.onDanger)
        }
    }
}

// MARK: - Active Spinner Icon

private struct ActiveSpinnerIcon: View {
    @Environment(\.theme) private var theme
    let accentColor: Color
    let size: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let progress = spinProgress(for: timeline.date)

            ZStack {
                // Subtle pulsing background
                Circle()
                    .fill(theme.wash(behind: accentColor))
                    .frame(width: size, height: size)
                    .scaleEffect(1.0 + sin(progress * .pi * 2) * 0.08)

                // Smooth spinning arc
                SmallSpinnerShape(progress: progress)
                    .stroke(accentColor, style: StrokeStyle(lineWidth: theme.stroke.default, lineCap: .round))
                    .frame(width: size - 4, height: size - 4)
            }
        }
    }

    private func spinProgress(for date: Date) -> Double {
        let seconds = date.timeIntervalSinceReferenceDate
        return (seconds * 1.5).truncatingRemainder(dividingBy: 1.0)
    }
}

private struct SmallSpinnerShape: Shape {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let startAngle = Angle(degrees: progress * 360 - 90)
        let endAngle = Angle(degrees: progress * 360 + 200)

        var path = Path()
        path.addArc(
            center: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: false
        )
        return path
    }
}

// MARK: - Completed Checkmark Icon

/// SF Symbol checkmark with a spring pop-in. The symbol centers itself via
/// font metrics — the previous hand-drawn trim-animated path sat visibly
/// off-center inside the circle at small sizes — and matches the `xmark`
/// symbol the failed state uses.
private struct CompletedCheckmarkIcon: View {
    let theme: ThemeProtocol
    let size: CGFloat

    @State private var revealed = false

    var body: some View {
        ZStack {
            Circle()
                .fill(theme.status.success.foreground)
                .frame(width: size, height: size)
                .scaleEffect(revealed ? 1 : 0.5)

            Image(systemName: "checkmark")
                .glyphSize(points: size * 0.5, weight: .bold)
                .foregroundColor(FixedPalette.onMedia)
                .scaleEffect(revealed ? 1 : 0.4)
                .opacity(revealed ? 1 : 0)
        }
        .onAppear {
            withAnimation(theme.motion.springAnimation) {
                revealed = true
            }
        }
    }
}

// MARK: - Animated Step Counter

/// Animated counter that smoothly transitions between numbers
struct AnimatedStepCounter: View {
    @Environment(\.theme) private var theme

    let current: Int
    let total: Int
    let color: Color

    var body: some View {
        HStack(spacing: theme.space.s2) {
            Text("\(current)", bundle: .module)
                .contentTransition(.numericText())
                .animation(theme.motion.springAnimation, value: current)

            Text("/")

            Text("\(total)", bundle: .module)
        }
        .textStyle(.footnote, weight: 500, family: .code)
        .foregroundColor(color)
    }
}

// MARK: - Preview

#if DEBUG
    struct AnimatedProgressComponents_Previews: PreviewProvider {
        @MainActor private static var theme: any ThemeProtocol { ThemeManager.shared.currentTheme }

        static var previews: some View {
            VStack(spacing: theme.space.s24) {
                // Indeterminate Progress
                VStack(alignment: .leading, spacing: theme.space.s8) {
                    Text("Indeterminate Progress", bundle: .module)
                        .textStyle(.micro)
                    IndeterminateShimmerProgress(color: ThemeManager.shared.currentTheme.text.link)
                }

                // Typing Indicator
                VStack(alignment: .leading, spacing: theme.space.s8) {
                    Text("Typing Indicator", bundle: .module)
                        .textStyle(.micro)
                    ConfigurableTypingIndicator(color: ThemeManager.shared.currentTheme.text.link)
                }

                // Morphing Icons
                HStack(spacing: theme.space.s20) {
                    VStack {
                        MorphingStatusIcon(state: .pending, accentColor: .blue)
                        Text("Pending", bundle: .module).textStyle(.micro)
                    }
                    VStack {
                        MorphingStatusIcon(state: .active, accentColor: .blue)
                        Text("Active", bundle: .module).textStyle(.micro)
                    }
                    VStack {
                        MorphingStatusIcon(state: .completed, accentColor: .green)
                        Text("Done", bundle: .module).textStyle(.micro)
                    }
                    VStack {
                        MorphingStatusIcon(state: .failed, accentColor: .red)
                        Text("Failed", bundle: .module).textStyle(.micro)
                    }
                }
            }
            .padding()
            .frame(width: 300)
            .background(CustomizableTheme.dark().surface.canvas)
        }
    }
#endif
