import AppKit
import SwiftUI

// MARK: - Animated Orb

/// A mesmerizing animated orb with liquid-like motion, particles, and glow effects.
/// Uses a Metal shader (`OrbShader.metal` in the App target) for GPU-accelerated rendering.
///
/// Usage:
/// ```swift
/// AnimatedOrb(color: .blue, size: .medium)
/// AnimatedOrb(color: .purple, size: .small, seed: "MyAgent")
/// AnimatedOrb(color: .green, size: .custom(48), showGlow: false)
/// ```
struct AnimatedOrb: View {
    let color: Color
    let size: Size
    var seed: String = ""
    var showGlow: Bool = true
    var showFloat: Bool = true
    var isInteractive: Bool = true

    // MARK: - Size Presets

    enum Size {
        case tiny  // 24pt - for inline indicators
        case small  // 40pt - for toasts, compact UI
        case medium  // 64pt - default, for hero sections
        case large  // 96pt - for splash screens
        case custom(CGFloat)

        var value: CGFloat {
            switch self {
            case .tiny: return 24
            case .small: return 40
            case .medium: return 64
            case .large: return 96
            case .custom(let size): return size
            }
        }
    }

    // MARK: - State

    @State private var isHovered = false
    @State private var isAppActive = true

    // MARK: - Seed Hashing

    private var seedHash: Float {
        guard !seed.isEmpty else { return 0.5 }
        let h = seed.utf8.reduce(0) { ($0 &+ Int($1) &* 31) }
        return Float(abs(h) % 1000) / 1000.0
    }

    // MARK: - Body

    var body: some View {
        let orbSize = size.value

        ZStack {
            if showGlow {
                outerGlow(size: orbSize)
            }
            OrbShaderContent(color: color, seedHash: seedHash)
                .clipShape(Circle())
                .frame(width: orbSize, height: orbSize)
                .scaleEffect(contentScale)
        }
        // Dropped two per-vsync compositor costs:
        //   1. `.shadow(color:radius:)` — SwiftUI's shadow modifier has no
        //      `shadowPath` hook, so every re-composite rasterizes it offscreen.
        //      The outer-glow radial gradient already provides the halo.
        //   2. `.offset(y: floatOffset)` with a `repeatForever` animation —
        //      kept the entire orb subtree (shader + shadow) in CoreAnimation's
        //      active list every frame, composited at full display refresh rate
        //      regardless of the TimelineView's 6Hz shader tick.
        .contentShape(Circle().scale(1.3))
        .onHover { hovering in
            guard isInteractive else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                isHovered = hovering
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)
        ) { _ in
            isAppActive = false
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            isAppActive = true
        }
    }

    // MARK: - Computed Properties

    private var glowScale: CGFloat {
        isInteractive && isHovered ? 1.5 : 1.4
    }

    private var contentScale: CGFloat {
        isInteractive && isHovered ? 1.05 : 1.0
    }

    // MARK: - View Components

    @ViewBuilder
    private func outerGlow(size: CGFloat) -> some View {
        let opacity = isInteractive && isHovered ? 0.22 : 0.15
        Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(colors: [
                        color.opacity(opacity),
                        color.opacity(opacity * 0.6),
                        color.opacity(0),
                    ]),
                    center: .center,
                    startRadius: 0,
                    endRadius: (size * glowScale) / 2
                )
            )
            .frame(width: size * glowScale, height: size * glowScale)
    }
}

// MARK: - Orb Shader Content

private struct OrbShaderContent: View {
    let color: Color
    let seedHash: Float

    @State private var startTime = Date.now
    /// time value frozen at the moment the app resigned active
    @State private var frozenTime: Float = 0
    @State private var isAppActive = true

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            if size.width > 0 && size.height > 0 {
                // .animation(minimumInterval:, paused:) is display-link driven and actually stops
                // the display link when paused — .periodic fires at the given interval regardless
                // of app state, still submitting CA draw calls that keep the compositor busy.
                // paused: !isAppActive ensures zero CA updates when the app is not in the foreground.
                //
                TimelineView(.animation(minimumInterval: 1.0 / 6.0, paused: !isAppActive)) { timeline in
                    let elapsed = Float(timeline.date.timeIntervalSince(startTime))
                    // when paused, timeline.date stops advancing, but on resume it jumps to wall-clock
                    // time; use frozenTime to preserve the shader's animation phase across pause/resume.
                    let time = isAppActive ? elapsed : frozenTime

                    ZStack {
                        Rectangle()
                            .fill(color)
                            .colorEffect(
                                ShaderLibrary.orbEffect(
                                    .float(time),
                                    .float(seedHash),
                                    .boundingRect
                                )
                            )

                        particleCanvas(time: time)
                    }
                }
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)
        ) { _ in
            frozenTime = Float(Date.now.timeIntervalSince(startTime))
            isAppActive = false
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            // shift startTime forward so the shader resumes from exactly the frozen phase
            startTime = Date.now - TimeInterval(frozenTime)
            isAppActive = true
        }
    }

    private func particleCanvas(time: Float) -> some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2

            for i in 0 ..< 10 {
                let base = Double(i) * 0.1
                let phase = fmod(Double(time) / (2.5 + base * 0.5) + base, 1.0)
                let angle = base * .pi * 2 + Double(seedHash) * .pi * 2 + phase * 0.6
                let dist = r * (0.85 + phase * 0.15)
                let alpha = (1.0 - phase) * 0.45
                let d = 1.2 * (1.0 - phase * 0.4)

                context.fill(
                    Path(
                        ellipseIn: CGRect(
                            x: center.x + cos(angle) * dist - d / 2,
                            y: center.y + sin(angle) * dist - d / 2,
                            width: d,
                            height: d
                        )
                    ),
                    with: .color(.white.opacity(alpha))
                )
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Preview

#if DEBUG
    struct AnimatedOrb_Previews: PreviewProvider {
        static var previews: some View {
            VStack(spacing: 40) {
                HStack(spacing: 30) {
                    VStack {
                        AnimatedOrb(color: .blue, size: .tiny)
                        Text("Tiny", bundle: .module).font(.caption)
                    }
                    VStack {
                        AnimatedOrb(color: .purple, size: .small, seed: "Toast")
                        Text("Small", bundle: .module).font(.caption)
                    }
                    VStack {
                        AnimatedOrb(color: .orange, size: .medium, seed: "Default")
                        Text("Medium", bundle: .module).font(.caption)
                    }
                    VStack {
                        AnimatedOrb(color: .green, size: .large, seed: "Hero")
                        Text("Large", bundle: .module).font(.caption)
                    }
                }

                HStack(spacing: 30) {
                    AnimatedOrb(color: .red, size: .medium, seed: "Agent A")
                    AnimatedOrb(color: .red, size: .medium, seed: "Agent B")
                    AnimatedOrb(color: .red, size: .medium, seed: "Agent C")
                }

                AnimatedOrb(color: .cyan, size: .small, showGlow: false, showFloat: false, isInteractive: false)
            }
            .padding(40)
            .background(Color(white: 0.1))
        }
    }
#endif
