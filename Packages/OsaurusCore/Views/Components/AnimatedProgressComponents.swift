//
//  AnimatedProgressComponents.swift
//  osaurus
//
//  Animated progress components for background tasks including
//  shimmer progress bars, typing indicators, and morphing status icons.
//

import SwiftUI

// MARK: - Shimmer Progress Bar

/// Animated progress bar with gradient shimmer effect
struct ShimmerProgressBar: View {
    @Environment(\.theme) private var theme

    let progress: Double
    let color: Color
    var height: CGFloat = 4
    var showGlow: Bool = true

    @State private var shimmerOffset: CGFloat = -1

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(color.opacity(0.15))
                    .frame(height: height)

                // Progress fill with gradient
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(
                        LinearGradient(
                            colors: [
                                color.opacity(0.8),
                                color,
                                color.opacity(0.8),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, geometry.size.width * progress), height: height)
                    .overlay(shimmerOverlay(width: geometry.size.width * progress))
                    .clipShape(RoundedRectangle(cornerRadius: height / 2))
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: progress)

                // Glow effect at the leading edge
                if showGlow && progress > 0 && progress < 1 {
                    Circle()
                        .fill(color)
                        .frame(width: height * 2, height: height * 2)
                        .blur(radius: 4)
                        .opacity(0.6)
                        .offset(x: max(0, geometry.size.width * progress - height))
                        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: progress)
                }
            }
        }
        .frame(height: height)
        .onAppear {
            startShimmerAnimation()
        }
    }

    private func shimmerOverlay(width: CGFloat) -> some View {
        GeometryReader { _ in
            LinearGradient(
                colors: [
                    Color.white.opacity(0),
                    Color.white.opacity(0.4),
                    Color.white.opacity(0),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 40)
            .offset(x: shimmerOffset * width)
            .opacity(progress > 0 ? 1 : 0)
        }
        .clipped()
    }

    private func startShimmerAnimation() {
        withAnimation(
            .easeInOut(duration: 1.5)
                .repeatForever(autoreverses: false)
        ) {
            shimmerOffset = 2
        }
    }
}

// MARK: - Indeterminate Shimmer Progress

/// Animated indeterminate progress indicator with flowing gradient
struct IndeterminateShimmerProgress: View {
    @Environment(\.theme) private var theme

    let color: Color
    var height: CGFloat = 4

    @State private var animationOffset: CGFloat = -0.3

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(color.opacity(0.15))
                    .frame(height: height)

                // Animated flowing bar
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(
                        LinearGradient(
                            colors: [
                                color.opacity(0),
                                color,
                                color,
                                color.opacity(0),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geometry.size.width * 0.4, height: height)
                    .offset(x: animationOffset * geometry.size.width)
            }
        }
        .frame(height: height)
        .onAppear {
            withAnimation(
                .easeInOut(duration: 1.2)
                    .repeatForever(autoreverses: true)
            ) {
                animationOffset = 0.9
            }
        }
    }
}

// MARK: - Configurable Typing Indicator

/// Three-dot typing indicator with staggered bounce animation and configurable colors
struct ConfigurableTypingIndicator: View {
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
                        .easeInOut(duration: 0.4)
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
                    .stroke(color.opacity(pulseOpacity), lineWidth: 2)
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
            .easeOut(duration: 1.2)
                .repeatForever(autoreverses: false)
        ) {
            pulseScale = 2.5
            pulseOpacity = 0
        }
    }
}

// MARK: - Status Icon State

/// State enum for morphing status icon
enum StatusIconState {
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
            .strokeBorder(theme.tertiaryText.opacity(0.4), lineWidth: 1.5)
            .frame(width: size, height: size)
    }

    private var failedIcon: some View {
        ZStack {
            Circle()
                .fill(theme.errorColor)
                .frame(width: size, height: size)

            Image(systemName: "xmark")
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundColor(.white)
        }
    }
}

// MARK: - Active Spinner Icon

private struct ActiveSpinnerIcon: View {
    let accentColor: Color
    let size: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let progress = spinProgress(for: timeline.date)

            ZStack {
                // Subtle pulsing background
                Circle()
                    .fill(accentColor.opacity(0.1))
                    .frame(width: size, height: size)
                    .scaleEffect(1.0 + sin(progress * .pi * 2) * 0.08)

                // Smooth spinning arc
                SmallSpinnerShape(progress: progress)
                    .stroke(accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
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

private struct CompletedCheckmarkIcon: View {
    let theme: ThemeProtocol
    let size: CGFloat

    @State private var checkmarkProgress: CGFloat = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(theme.successColor)
                .frame(width: size, height: size)
                .scaleEffect(checkmarkProgress > 0 ? 1 : 0.5)

            // Checkmark path
            CheckmarkShape()
                .trim(from: 0, to: checkmarkProgress)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.5, height: size * 0.5)
        }
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                checkmarkProgress = 1
            }
        }
    }
}

// MARK: - Checkmark Shape

/// Custom shape for animated checkmark drawing
struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()

        let width = rect.width
        let height = rect.height

        // Start at left point
        path.move(to: CGPoint(x: width * 0.1, y: height * 0.5))

        // Line to bottom point
        path.addLine(to: CGPoint(x: width * 0.4, y: height * 0.85))

        // Line to top-right point
        path.addLine(to: CGPoint(x: width * 0.95, y: height * 0.15))

        return path
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
        HStack(spacing: 2) {
            Text("\(current)")
                .contentTransition(.numericText())
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: current)

            Text("/")

            Text("\(total)")
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundColor(color)
    }
}

// MARK: - Glow Effect Modifier

/// Adds a soft glow effect around a view
struct GlowModifier: ViewModifier {
    let color: Color
    let radius: CGFloat
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .shadow(color: isActive ? color.opacity(0.5) : .clear, radius: radius)
            .shadow(color: isActive ? color.opacity(0.3) : .clear, radius: radius * 2)
    }
}

extension View {
    func glow(color: Color, radius: CGFloat = 8, isActive: Bool = true) -> some View {
        modifier(GlowModifier(color: color, radius: radius, isActive: isActive))
    }
}

// MARK: - Preview

#if DEBUG
    struct AnimatedProgressComponents_Previews: PreviewProvider {
        static var previews: some View {
            VStack(spacing: 24) {
                // Shimmer Progress
                VStack(alignment: .leading, spacing: 8) {
                    Text("Shimmer Progress Bar")
                        .font(.caption)
                    ShimmerProgressBar(progress: 0.6, color: .blue)
                }

                // Indeterminate Progress
                VStack(alignment: .leading, spacing: 8) {
                    Text("Indeterminate Progress")
                        .font(.caption)
                    IndeterminateShimmerProgress(color: .blue)
                }

                // Typing Indicator
                VStack(alignment: .leading, spacing: 8) {
                    Text("Typing Indicator")
                        .font(.caption)
                    ConfigurableTypingIndicator(color: .blue)
                }

                // Morphing Icons
                HStack(spacing: 20) {
                    VStack {
                        MorphingStatusIcon(state: .pending, accentColor: .blue)
                        Text("Pending").font(.caption2)
                    }
                    VStack {
                        MorphingStatusIcon(state: .active, accentColor: .blue)
                        Text("Active").font(.caption2)
                    }
                    VStack {
                        MorphingStatusIcon(state: .completed, accentColor: .green)
                        Text("Done").font(.caption2)
                    }
                    VStack {
                        MorphingStatusIcon(state: .failed, accentColor: .red)
                        Text("Failed").font(.caption2)
                    }
                }
            }
            .padding()
            .frame(width: 300)
            .background(Color.black.opacity(0.8))
        }
    }
#endif
