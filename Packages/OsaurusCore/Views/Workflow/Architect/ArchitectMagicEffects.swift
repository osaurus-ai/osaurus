//
//  ArchitectMagicEffects.swift
//  osaurus
//
//  The few motions that make a workflow feel like it is being made in
//  front of you: a light tracing the edge of what the Architect is building,
//  a glow where it just changed something, and a short burst when a
//  workflow is added. Every one is still under Reduce Motion.
//

import SwiftUI

extension View {
    /// A thin light tracing the view's rounded edge (`radius`, a
    /// `theme.radius` value) while `isActive`. Only the outline moves, so
    /// what is being built stays still and readable.
    func architectTracing(isActive: Bool, radius: CGFloat? = nil) -> some View {
        modifier(ArchitectTracing(isActive: isActive, radius: radius))
    }

    /// A ring that lights up and fades each time `trigger` changes.
    func architectGlowIn<T: Equatable>(trigger: T, radius: CGFloat? = nil) -> some View {
        modifier(ArchitectGlowIn(trigger: trigger, radius: radius))
    }
}

private struct ArchitectTracing: ViewModifier {
    let isActive: Bool
    let radius: CGFloat?

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.inspectorForceReducedMotion) private var forceReducedMotion

    /// Seconds for the light to go once around.
    private static let lap: TimeInterval = 3.6

    private var animates: Bool { isActive && !reduceMotion && !forceReducedMotion }

    func body(content: Content) -> some View {
        content
            .overlay {
                if animates {
                    TimelineView(.animation) { timeline in
                        let turn = timeline.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: Self.lap) / Self.lap
                        let shape = RoundedRectangle(cornerRadius: radius ?? theme.radius.medium, style: .continuous)
                        let comet = AngularGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .clear, location: 0.72),
                                .init(color: theme.statusInk(.info), location: 0.97),
                                .init(color: .clear, location: 1),
                            ],
                            center: .center, angle: .degrees(turn * 360))
                        ZStack {
                            shape.strokeBorder(comet, lineWidth: theme.stroke.focus)
                                .blur(radius: theme.space.s4)
                                .opacity(0.5)
                            shape.strokeBorder(comet, lineWidth: theme.stroke.default)
                                .opacity(0.8)
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity)
                }
            }
            .animation(theme.motion.standard, value: animates)
    }
}

private struct ArchitectGlowIn<T: Equatable>: ViewModifier {
    let trigger: T
    let radius: CGFloat?

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lit = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: radius ?? theme.radius.medium, style: .continuous)
                    .strokeBorder(theme.statusInk(.info), lineWidth: theme.stroke.focus)
                    .opacity(lit ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onChange(of: trigger) { _, _ in
                guard !reduceMotion else { return }
                lit = true
                withAnimation(theme.motion.timed(.easeOut, duration: 1.4)) { lit = false }
            }
    }
}

/// A short, quiet burst of dots from the middle, once, when `trigger`
/// becomes true. Nothing under Reduce Motion.
struct ArchitectCelebrationBurst: View {
    let trigger: Bool

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt: Date?

    private static let duration: TimeInterval = 1.3
    private static let count = 22

    var body: some View {
        Group {
            if let startedAt, !reduceMotion {
                TimelineView(.animation) { timeline in
                    let t = min(1, timeline.date.timeIntervalSince(startedAt) / Self.duration)
                    Canvas { context, size in
                        draw(in: &context, size: size, progress: t)
                    }
                    .opacity(t >= 1 ? 0 : 1)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { if trigger { start() } }
        .onChange(of: trigger) { _, on in if on { start() } }
    }

    private func start() {
        guard !reduceMotion else { return }
        startedAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration) { startedAt = nil }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, progress t: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let reach = min(size.width, size.height) * 0.5
        let colors = [theme.statusInk(.success), theme.statusInk(.info), theme.action.primary.default.background]
        let eased = 1 - pow(1 - t, 3)
        for i in 0..<Self.count {
            let angle = Double(i) / Double(Self.count) * 2 * .pi + Double(i % 3) * 0.17
            let distance = reach * (0.35 + 0.65 * eased) * (i.isMultiple(of: 2) ? 1 : 0.72)
            let point = CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
            let dot = theme.space.s4 * (1 - t * 0.6)
            context.opacity = 1 - t
            context.fill(
                Path(ellipseIn: CGRect(x: point.x - dot / 2, y: point.y - dot / 2, width: dot, height: dot)),
                with: .color(colors[i % colors.count]))
        }
    }
}
