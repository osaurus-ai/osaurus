//
//  OnboardingBackdrop.swift
//  osaurus
//
//  The landscape behind the onboarding window. It pulls focus back when the
//  setup surface takes the stage, and follows the pointer with a soft light
//  and a few points of parallax.
//  The blurred plate is rendered once off the main thread and crossfaded,
//  so focus changes never run a live blur.
//

import AppKit
import CoreImage
import SwiftUI

/// How much attention the landscape takes.
enum OnboardingBackdropFocus: Equatable {
    /// Sharp: the landscape is the subject.
    case clear
    /// Blurred and dimmed behind the setup surface.
    case pulled
}

struct OnboardingBackdrop: View {
    let scene: OnboardingScene
    let focus: OnboardingBackdropFocus
    /// The pointer in this view's coordinates, or nil when it is outside.
    let pointer: CGPoint?

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var blurred: NSImage?

    /// The furthest the landscape drifts toward the pointer, in points.
    static let parallaxTravel: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                if let sharp = OnboardingBackdropPlates.sharp(scene) {
                    plate(Image(nsImage: sharp), size: size)
                }
                if let blurred {
                    plate(Image(nsImage: blurred), size: size)
                        .opacity(focus == .clear ? 0 : 1)
                }
                Rectangle()
                    .fill(theme.scrim)
                    .opacity(dim)
                if !reduceMotion, let pointer {
                    RadialGradient(
                        colors: [OnboardingPalette.pointerLight, OnboardingPalette.pointerLight.opacity(0)],
                        center: UnitPoint(x: pointer.x / max(size.width, 1), y: pointer.y / max(size.height, 1)),
                        startRadius: 0,
                        endRadius: size.width * 0.35
                    )
                    .blendMode(.plusLighter)
                    .opacity(focus == .pulled ? 0.05 : 0.12)
                    .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: scene) {
            blurred = await OnboardingBackdropPlates.blurred(scene)
        }
        .onAppear { OnboardingBackdropPlates.viewerAppeared() }
        .onDisappear { OnboardingBackdropPlates.viewerDisappeared() }
    }

    private func plate(_ image: Image, size: CGSize) -> some View {
        image
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: size.width, height: size.height)
            .scaleEffect(1.02)
            .offset(parallax(in: size))
    }

    private func parallax(in size: CGSize) -> CGSize {
        guard !reduceMotion, let pointer, size.width > 0, size.height > 0 else { return .zero }
        let dx = (pointer.x / size.width - 0.5) * 2
        let dy = (pointer.y / size.height - 0.5) * 2
        return CGSize(width: -dx * Self.parallaxTravel, height: -dy * Self.parallaxTravel)
    }

    /// Dark themes sit the landscape further back so glass and text read.
    private var dim: Double {
        let base = theme.isDark ? 0.28 : 0.06
        switch focus {
        case .clear: return base
        case .pulled: return base + 0.22
        }
    }
}

/// The landscape plates, loaded once per scene while onboarding is on
/// screen. They ship as plain HEIC resources: asset catalogs drop HEIF
/// renditions at runtime.
@MainActor
enum OnboardingBackdropPlates {
    private static var sharpCache: [OnboardingScene: NSImage] = [:]
    private static var blurredCache: [OnboardingScene: NSImage] = [:]
    private static var viewers = 0
    private static var releaseTask: Task<Void, Never>?

    static func viewerAppeared() {
        viewers += 1
        releaseTask?.cancel()
        releaseTask = nil
    }

    /// Stage transitions swap backdrop views, so the release waits long
    /// enough that a replacement view reuses the decoded plates.
    static func viewerDisappeared() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        releaseTask?.cancel()
        releaseTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, viewers == 0 else { return }
            releaseAll()
        }
    }

    static func releaseAll() {
        sharpCache.removeAll()
        blurredCache.removeAll()
    }

    static var hasCachedPlates: Bool { !sharpCache.isEmpty || !blurredCache.isEmpty }

    static func url(for scene: OnboardingScene) -> URL? {
        Bundle.module.url(forResource: scene.imageName, withExtension: "heic")
    }

    static func sharp(_ scene: OnboardingScene) -> NSImage? {
        if let cached = sharpCache[scene] { return cached }
        guard let url = url(for: scene), let image = NSImage(contentsOf: url) else { return nil }
        sharpCache[scene] = image
        return image
    }

    static func blurred(_ scene: OnboardingScene) async -> NSImage? {
        if let cached = blurredCache[scene] { return cached }
        guard let source = sharp(scene),
            let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let rendered = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            Self.blur(cgImage, width: 640, radius: 14)
        }.value
        guard let rendered else { return nil }
        let image = NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height))
        blurredCache[scene] = image
        return image
    }

    /// Downscaled first: the blur hides the detail and costs a fraction.
    nonisolated static func blur(_ image: CGImage, width: CGFloat, radius: Double) -> CGImage? {
        let input = CIImage(cgImage: image)
        let scale = width / input.extent.width
        let scaled = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blurred = scaled.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: scaled.extent)
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(blurred, from: scaled.extent)
    }
}
