import SwiftUI

// MARK: - Animated Orb

/// A mesmerizing animated orb with liquid-like motion, particles, and glow effects.
/// Inspired by metasidd/Orb, rebuilt for macOS compatibility.
///
/// Usage:
/// ```swift
/// AnimatedOrb(color: .blue, size: .medium)
/// AnimatedOrb(color: .purple, size: .small, seed: "MyAgent")
/// AnimatedOrb(color: .green, size: .custom(48), showGlow: false)
/// ```
struct AnimatedOrb: View {
    /// The primary color of the orb
    let color: Color

    /// Size preset for the orb
    let size: Size

    /// Optional seed string for deterministic visual variation
    var seed: String = ""

    /// Whether to show the outer glow effect
    var showGlow: Bool = true

    /// Whether to show the floating animation
    var showFloat: Bool = true

    /// Whether to respond to hover
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

    @State private var floatOffset: CGFloat = 0
    @State private var glowPulse: CGFloat = 1.0
    @State private var isHovered = false

    // MARK: - Configuration

    private var config: OrbConfig {
        OrbConfig(seed: seed)
    }

    // MARK: - Body

    var body: some View {
        let orbSize = size.value

        ZStack {
            if showGlow {
                outerGlow(size: orbSize)
            }
            orbContent(size: orbSize)
        }
        .shadow(color: color.opacity(shadowOpacity), radius: shadowRadius)
        .offset(y: showFloat ? floatOffset : 0)
        .contentShape(Circle().scale(1.3))
        .onHover { hovering in
            guard isInteractive else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                isHovered = hovering
            }
        }
        .onAppear(perform: startAnimations)
    }

    // MARK: - Computed Properties

    private var shadowOpacity: Double {
        isInteractive && isHovered ? 0.4 : 0.3
    }

    private var shadowRadius: CGFloat {
        isInteractive && isHovered ? 10 : 8
    }

    private var glowScale: CGFloat {
        isInteractive && isHovered ? 1.5 : 1.4
    }

    private var contentScale: CGFloat {
        isInteractive && isHovered ? 1.05 : 1.0
    }

    // MARK: - View Components

    @ViewBuilder
    private func outerGlow(size: CGFloat) -> some View {
        let opacity = (isInteractive && isHovered ? 0.22 : 0.15) * glowPulse
        Circle()
            .fill(color.opacity(opacity))
            .frame(width: size * glowScale, height: size * glowScale)
            .blur(radius: isInteractive && isHovered ? 14 : 12)
    }

    @ViewBuilder
    private func orbContent(size: CGFloat) -> some View {
        let speed = 60.0 * config.speedVariation

        ZStack {
            backgroundGradient
            rotatingGlows(size: size, speed: speed)
            wavyBlobs(size: size, speed: speed)
            coreGlows(size: size, speed: speed)
            OrbParticlesView(config: config.particleConfig, size: size)
                .blendMode(.plusLighter)
        }
        .overlay { innerRimGlows }
        .clipShape(Circle())
        .drawingGroup()  // Rasterize before scaling to avoid clip artifacts
        .frame(width: size, height: size)
        .scaleEffect(contentScale)
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [color, color.opacity(0.7), color.opacity(0.5)],
            startPoint: config.gradientStart,
            endPoint: config.gradientEnd
        )
    }

    @ViewBuilder
    private func rotatingGlows(size: CGFloat, speed: Double) -> some View {
        OrbRotatingGlowView(color: color, speed: speed * 0.75, clockwise: !config.primaryClockwise)
            .padding(size * 0.03)
            .blur(radius: size * 0.06)
            .rotationEffect(.degrees(180 + config.blobRotationOffset))
            .blendMode(.destinationOver)

        OrbRotatingGlowView(color: color.opacity(0.5), speed: speed * 0.25, clockwise: config.primaryClockwise)
            .frame(width: size * 0.94, height: size * 0.94)
            .rotationEffect(.degrees(180 + config.blobRotationOffset * 0.5))
            .blur(radius: size * 0.032)
    }

    @ViewBuilder
    private func wavyBlobs(size: CGFloat, speed: Double) -> some View {
        OrbRotatingGlowView(color: .white.opacity(0.75), speed: speed * 1.5, clockwise: config.primaryClockwise)
            .mask {
                OrbWavyBlobView(config: config.blobConfig1)
                    .frame(width: size * 1.875, height: size * 1.875)
                    .offset(y: size * config.blob1Offset)
            }
            .blur(radius: 1)
            .blendMode(.plusLighter)

        OrbRotatingGlowView(color: .white, speed: speed * 0.75, clockwise: !config.primaryClockwise)
            .mask {
                OrbWavyBlobView(config: config.blobConfig2)
                    .frame(width: size * 1.25, height: size * 1.25)
                    .rotationEffect(.degrees(90 + config.blobRotationOffset))
                    .offset(y: -size * config.blob2Offset)
            }
            .opacity(0.5)
            .blur(radius: 1)
            .blendMode(.plusLighter)
    }

    @ViewBuilder
    private func coreGlows(size: CGFloat, speed: Double) -> some View {
        OrbRotatingGlowView(color: .white, speed: speed * 3, clockwise: config.primaryClockwise)
            .blur(radius: size * 0.08)
            .padding(size * 0.08)

        OrbRotatingGlowView(color: .white, speed: speed * 2.3, clockwise: config.primaryClockwise)
            .blur(radius: size * 0.06)
            .opacity(0.8)
            .blendMode(.plusLighter)
            .padding(size * 0.08)
    }

    private var innerRimGlows: some View {
        let gradient = LinearGradient(colors: [.white, .clear], startPoint: .bottom, endPoint: .top)
        return Circle()
            .stroke(gradient, lineWidth: 3)
            .blur(radius: 8)
            .blendMode(.plusLighter)
            .padding(1)
    }

    // MARK: - Animations

    private func startAnimations() {
        if showFloat {
            withAnimation(.easeInOut(duration: config.floatDuration).repeatForever(autoreverses: true)) {
                floatOffset = -3
            }
        }
        if showGlow {
            withAnimation(.easeInOut(duration: config.pulseDuration).repeatForever(autoreverses: true)) {
                glowPulse = 1.2
            }
        }
    }
}

// MARK: - Configuration

/// Pre-computed configuration based on seed string hash.
private struct OrbConfig {
    let hash1: Double
    let hash2: Double
    let primaryClockwise: Bool
    let speedVariation: Double
    let blobRotationOffset: Double
    let gradientStart: UnitPoint
    let gradientEnd: UnitPoint
    let blob1Offset: Double
    let blob2Offset: Double
    let floatDuration: Double
    let pulseDuration: Double
    let blobConfig1: OrbWavyBlobConfig
    let blobConfig2: OrbWavyBlobConfig
    let particleConfig: OrbParticleConfig

    init(seed: String) {
        if seed.isEmpty {
            hash1 = 0.5
            hash2 = 0.5
        } else {
            let h1 = seed.utf8.reduce(0) { ($0 &+ Int($1) &* 31) }
            let h2 = seed.utf8.reduce(0) { ($0 &+ Int($1) &* 17) }
            hash1 = Double(abs(h1) % 1000) / 1000.0
            hash2 = Double(abs(h2) % 1000) / 1000.0
        }

        primaryClockwise = hash1 > 0.5
        speedVariation = 0.8 + hash1 * 0.4
        blobRotationOffset = hash2 * 180

        gradientStart = hash1 > 0.5 ? .bottom : .bottomLeading
        gradientEnd = hash1 > 0.5 ? .top : .topTrailing

        blob1Offset = 0.25 + hash2 * 0.12
        blob2Offset = 0.25 + hash1 * 0.12

        floatDuration = 2.3 + hash1 * 0.4
        pulseDuration = 3.5 + hash2 * 1.0

        blobConfig1 = OrbWavyBlobConfig(loopDuration: 1.5 + hash1 * 0.5, seed: hash1)
        blobConfig2 = OrbWavyBlobConfig(loopDuration: 2.0 + hash2 * 0.5, seed: hash2)
        particleConfig = OrbParticleConfig(seed: hash1)
    }
}

// MARK: - Rotating Glow View (Crescent shape that rotates)

private struct OrbRotatingGlowView: View {
    let color: Color
    let speed: Double
    let clockwise: Bool

    @State private var rotation: Double = 0

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)

            Circle()
                .fill(color)
                .mask {
                    ZStack {
                        Circle()
                            .frame(width: size, height: size)
                            .blur(radius: size * 0.16)

                        Circle()
                            .frame(width: size * 1.31, height: size * 1.31)
                            .offset(y: size * 0.31)
                            .blur(radius: size * 0.16)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                }
                .drawingGroup()
                .rotationEffect(.degrees(rotation))
                .onAppear {
                    withAnimation(.linear(duration: 360 / speed).repeatForever(autoreverses: false)) {
                        rotation = clockwise ? 360 : -360
                    }
                }
        }
    }
}

// MARK: - Wavy Blob Configuration

private struct OrbWavyBlobConfig {
    let loopDuration: Double
    let pointCount: Int
    let waveAmplitude: Double
    let handleLengthFactor: Double
    let phaseMultiplier: Double
    let basePoints: [CGPoint]

    init(loopDuration: Double, seed: Double) {
        self.loopDuration = loopDuration
        self.waveAmplitude = 0.12 + seed * 0.08
        self.handleLengthFactor = 0.3 + seed * 0.1
        self.phaseMultiplier = 1 + seed * 0.3

        // Compute pointCount as local variable first to avoid closure capture issue
        let count = 5 + Int(seed * 3)
        self.pointCount = count

        self.basePoints = (0 ..< count).map { index in
            let angle = (Double(index) / Double(count)) * 2 * Double.pi
            let radiusVariation = 0.85 + seed * 0.1 + (Double(index % 2) * seed * 0.1)
            return CGPoint(
                x: 0.5 + cos(angle) * radiusVariation,
                y: 0.5 + sin(angle) * radiusVariation
            )
        }
    }
}

// MARK: - Wavy Blob View

private struct OrbWavyBlobView: View {
    let config: OrbWavyBlobConfig

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 15.0)) { timeline in
            Canvas { context, size in
                let timeNow = timeline.date.timeIntervalSinceReferenceDate
                let angle = (timeNow.remainder(dividingBy: config.loopDuration) / config.loopDuration) * 2 * Double.pi

                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) * 0.45
                let handleLength = radius * config.handleLengthFactor

                let adjustedPoints = config.basePoints.enumerated().map { index, point in
                    let phaseOffset = Double(index) * Double.pi / Double(config.pointCount) * 2
                    let xOffset = sin(angle + phaseOffset) * config.waveAmplitude
                    let yOffset = cos(angle + phaseOffset * config.phaseMultiplier) * config.waveAmplitude
                    return CGPoint(
                        x: (point.x - 0.5 + xOffset) * radius + center.x,
                        y: (point.y - 0.5 + yOffset) * radius + center.y
                    )
                }

                var path = Path()
                path.move(to: adjustedPoints[0])

                for i in 0 ..< adjustedPoints.count {
                    let next = (i + 1) % adjustedPoints.count
                    let currentAngle = Double(atan2(adjustedPoints[i].y - center.y, adjustedPoints[i].x - center.x))
                    let nextAngle = Double(atan2(adjustedPoints[next].y - center.y, adjustedPoints[next].x - center.x))
                    let halfPi = Double.pi / 2

                    let control1 = CGPoint(
                        x: adjustedPoints[i].x + cos(currentAngle + halfPi) * handleLength,
                        y: adjustedPoints[i].y + sin(currentAngle + halfPi) * handleLength
                    )
                    let control2 = CGPoint(
                        x: adjustedPoints[next].x + cos(nextAngle - halfPi) * handleLength,
                        y: adjustedPoints[next].y + sin(nextAngle - halfPi) * handleLength
                    )

                    path.addCurve(to: adjustedPoints[next], control1: control1, control2: control2)
                }

                context.fill(path, with: .color(.white))
            }
        }
    }
}

// MARK: - Particle Configuration

private struct OrbParticleConfig {
    let orbitingCount: Int
    let swirlingCount: Int
    let sparkleCount: Int
    let speedMult: Double
    let directionMult: Double
    let seedMultiplier1: Double
    let seedMultiplier2: Double
    let seedMultiplier3: Double
    let orbitSpeedBase: Double
    let radiusOscSpeed: Double
    let twinkleSpeed: Double
    let xFreq: Double
    let yFreq: Double
    let yScale: Double
    let sparkleAngleBase: Double
    let radiusPulseSpeed: Double
    let twinklePower: Double

    init(seed: Double) {
        orbitingCount = 6 + Int(seed * 3)
        swirlingCount = 4 + Int(seed * 2)
        sparkleCount = 7 + Int(seed * 3)
        speedMult = 0.85 + seed * 0.3
        directionMult = seed > 0.5 ? 1.0 : -1.0
        seedMultiplier1 = 1.2 + seed * 0.3
        seedMultiplier2 = 1.9 + seed * 0.4
        seedMultiplier3 = 1.6 + seed * 0.3
        orbitSpeedBase = 0.4 + seed * 0.2
        radiusOscSpeed = 0.7 + seed * 0.3
        twinkleSpeed = 1.8 + seed * 0.5
        xFreq = 0.6 + seed * 0.3
        yFreq = 1.0 + seed * 0.4
        yScale = 0.7 + seed * 0.2
        sparkleAngleBase = 0.5 + seed * 0.2
        radiusPulseSpeed = 1.0 + seed * 0.4
        twinklePower = 1.5 + seed
    }
}

// MARK: - Particles View

private struct OrbParticlesView: View {
    let config: OrbParticleConfig
    let size: CGFloat

    private let particleColor: Color = .white

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 15.0)) { timeline in
            Canvas { context, canvasSize in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                let maxRadius = size * 0.42

                drawOrbitingParticles(context: &context, time: time, center: center, maxRadius: maxRadius)
                drawSwirlingParticles(context: &context, time: time, center: center, maxRadius: maxRadius)
                drawSparkles(context: &context, time: time, center: center, maxRadius: maxRadius)
            }
        }
        .frame(width: size, height: size)
    }

    private func drawOrbitingParticles(context: inout GraphicsContext, time: Double, center: CGPoint, maxRadius: Double)
    {
        for i in 0 ..< config.orbitingCount {
            let seed = Double(i) * config.seedMultiplier1
            let particleTime = time * 0.35 * config.speedMult + seed

            let orbitSpeed = config.orbitSpeedBase + Double(i % 4) * 0.15
            let angle = particleTime * orbitSpeed * config.directionMult + seed

            let radiusOsc =
                sin(particleTime * config.radiusOscSpeed + seed) * 0.2 + cos(particleTime * 0.5 + seed * 2) * 0.1
            let radiusFactor = 0.3 + Double(i % 5) * 0.13 + radiusOsc
            let radius = maxRadius * radiusFactor

            let x = center.x + cos(angle) * radius
            let y = center.y + sin(angle) * radius

            let twinkle = sin(particleTime * config.twinkleSpeed + seed * 3) * 0.5 + 0.5
            let particleSize = 0.8 + twinkle * 1.0

            let rect = CGRect(
                x: x - particleSize,
                y: y - particleSize,
                width: particleSize * 2,
                height: particleSize * 2
            )
            context.fill(Path(ellipseIn: rect), with: .color(particleColor.opacity(twinkle * 0.6)))
        }
    }

    private func drawSwirlingParticles(context: inout GraphicsContext, time: Double, center: CGPoint, maxRadius: Double)
    {
        for i in 0 ..< config.swirlingCount {
            let seed = Double(i) * config.seedMultiplier2
            let particleTime = time * 0.4 * config.speedMult + seed

            let xAngle = particleTime * config.xFreq * config.directionMult + seed
            let yAngle = particleTime * config.yFreq + seed * 0.5
            let radiusFactor = 0.5 + sin(particleTime * 0.3 + seed) * 0.2

            let x = center.x + cos(xAngle) * maxRadius * radiusFactor
            let y = center.y + sin(yAngle) * maxRadius * radiusFactor * config.yScale

            let twinkle = sin(particleTime * 2.5 + seed * 2) * 0.5 + 0.5
            let particleSize = 0.6 + twinkle * 0.8

            let rect = CGRect(
                x: x - particleSize,
                y: y - particleSize,
                width: particleSize * 2,
                height: particleSize * 2
            )
            context.fill(Path(ellipseIn: rect), with: .color(particleColor.opacity(twinkle * 0.5)))
        }
    }

    private func drawSparkles(context: inout GraphicsContext, time: Double, center: CGPoint, maxRadius: Double) {
        for i in 0 ..< config.sparkleCount {
            let seed = Double(i) * config.seedMultiplier3
            let particleTime = time * 0.5 * config.speedMult + seed

            let angleSpeed = config.sparkleAngleBase + Double(i % 3) * 0.25
            let angle = particleTime * angleSpeed * config.directionMult + seed * 2

            let radiusPulse = sin(particleTime * config.radiusPulseSpeed + seed) * 0.25
            let radiusFactor = (sin(particleTime * 0.8 + seed) * 0.5 + 0.5) * 0.75 + 0.2 + radiusPulse
            let radius = maxRadius * radiusFactor

            let x = center.x + cos(angle) * radius
            let y = center.y + sin(angle) * radius

            let twinkle = pow(max(0, sin(particleTime * 3.0 + seed * 2)), config.twinklePower)

            if twinkle > 0.0625 {
                let particleSize = 0.5 + twinkle * 1.3
                let rect = CGRect(
                    x: x - particleSize,
                    y: y - particleSize,
                    width: particleSize * 2,
                    height: particleSize * 2
                )
                context.fill(Path(ellipseIn: rect), with: .color(particleColor.opacity(twinkle * 0.8)))
            }
        }
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
                        Text("Tiny").font(.caption)
                    }
                    VStack {
                        AnimatedOrb(color: .purple, size: .small, seed: "Toast")
                        Text("Small").font(.caption)
                    }
                    VStack {
                        AnimatedOrb(color: .orange, size: .medium, seed: "Default")
                        Text("Medium").font(.caption)
                    }
                    VStack {
                        AnimatedOrb(color: .green, size: .large, seed: "Hero")
                        Text("Large").font(.caption)
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
