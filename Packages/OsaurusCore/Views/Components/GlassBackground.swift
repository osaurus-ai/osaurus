//
//  GlassBackground.swift
//  osaurus
//
//  Multi-layer glass effect with enhanced blur and edge lighting
//  Extended with theme-configurable material, tint, and opacity
//

import AppKit
import SwiftUI

// Container view that holds references to subviews for updates
final class GlassContainerView: NSView {
    let baseGlassView: NSVisualEffectView
    let edgeLightingView: NSView
    let tintOverlayView: NSView

    // Corner radii for mask - when set, uses mask layer instead of cornerRadius
    var cornerRadius: CGFloat = 28
    var topLeadingRadius: CGFloat?
    var bottomLeadingRadius: CGFloat?
    var topTrailingRadius: CGFloat?
    var bottomTrailingRadius: CGFloat?

    var hasCustomCorners: Bool {
        topLeadingRadius != nil || bottomLeadingRadius != nil || topTrailingRadius != nil
            || bottomTrailingRadius != nil
    }

    init(baseGlassView: NSVisualEffectView, edgeLightingView: NSView, tintOverlayView: NSView) {
        self.baseGlassView = baseGlassView
        self.edgeLightingView = edgeLightingView
        self.tintOverlayView = tintOverlayView
        super.init(frame: .zero)
        self.wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        updateMaskIfNeeded()
    }

    func updateMaskIfNeeded() {
        guard hasCustomCorners else {
            // Use native cornerRadius
            baseGlassView.layer?.mask = nil
            edgeLightingView.layer?.mask = nil
            tintOverlayView.layer?.mask = nil
            baseGlassView.layer?.cornerRadius = cornerRadius
            baseGlassView.layer?.masksToBounds = true
            edgeLightingView.layer?.cornerRadius = cornerRadius
            edgeLightingView.layer?.masksToBounds = true
            tintOverlayView.layer?.cornerRadius = cornerRadius
            tintOverlayView.layer?.masksToBounds = true
            return
        }

        // Use mask for custom corners
        baseGlassView.layer?.cornerRadius = 0
        baseGlassView.layer?.masksToBounds = false
        edgeLightingView.layer?.cornerRadius = 0
        edgeLightingView.layer?.masksToBounds = false
        tintOverlayView.layer?.cornerRadius = 0
        tintOverlayView.layer?.masksToBounds = false

        guard bounds.width > 0 && bounds.height > 0 else { return }

        baseGlassView.layer?.mask = createMaskLayer(for: bounds)
        edgeLightingView.layer?.mask = createMaskLayer(for: bounds)
        tintOverlayView.layer?.mask = createMaskLayer(for: bounds)
    }

    private func effectiveRadius(for corner: CGFloat?) -> CGFloat {
        corner ?? cornerRadius
    }

    private func createMaskLayer(for bounds: CGRect) -> CAShapeLayer {
        let tl = effectiveRadius(for: topLeadingRadius)
        let tr = effectiveRadius(for: topTrailingRadius)
        let bl = effectiveRadius(for: bottomLeadingRadius)
        let br = effectiveRadius(for: bottomTrailingRadius)

        let path = CGMutablePath()
        path.move(to: CGPoint(x: bounds.minX + tl, y: bounds.maxY))
        path.addLine(to: CGPoint(x: bounds.maxX - tr, y: bounds.maxY))
        if tr > 0 {
            path.addArc(
                center: CGPoint(x: bounds.maxX - tr, y: bounds.maxY - tr),
                radius: tr,
                startAngle: .pi / 2,
                endAngle: 0,
                clockwise: true
            )
        }
        path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.minY + br))
        if br > 0 {
            path.addArc(
                center: CGPoint(x: bounds.maxX - br, y: bounds.minY + br),
                radius: br,
                startAngle: 0,
                endAngle: -.pi / 2,
                clockwise: true
            )
        }
        path.addLine(to: CGPoint(x: bounds.minX + bl, y: bounds.minY))
        if bl > 0 {
            path.addArc(
                center: CGPoint(x: bounds.minX + bl, y: bounds.minY + bl),
                radius: bl,
                startAngle: -.pi / 2,
                endAngle: .pi,
                clockwise: true
            )
        }
        path.addLine(to: CGPoint(x: bounds.minX, y: bounds.maxY - tl))
        if tl > 0 {
            path.addArc(
                center: CGPoint(x: bounds.minX + tl, y: bounds.maxY - tl),
                radius: tl,
                startAngle: .pi,
                endAngle: .pi / 2,
                clockwise: true
            )
        }
        path.closeSubpath()

        let maskLayer = CAShapeLayer()
        maskLayer.path = path
        return maskLayer
    }
}

struct GlassBackground: NSViewRepresentable {
    var cornerRadius: CGFloat = 28
    var topLeadingRadius: CGFloat?
    var bottomLeadingRadius: CGFloat?
    var topTrailingRadius: CGFloat?
    var bottomTrailingRadius: CGFloat?
    var material: NSVisualEffectView.Material = .hudWindow
    var tintColor: NSColor?
    var tintOpacity: CGFloat = 0

    func makeNSView(context: Context) -> NSView {
        // Base glass layer with strong blur
        let baseGlassView = NSVisualEffectView()
        baseGlassView.material = material
        baseGlassView.blendingMode = .behindWindow
        baseGlassView.state = .active
        baseGlassView.wantsLayer = true

        // Edge lighting layer (disabled - using single clean edge)
        let edgeLightingView = NSView()
        edgeLightingView.wantsLayer = true
        edgeLightingView.layer?.borderWidth = 0
        edgeLightingView.layer?.borderColor = nil

        // Tint overlay layer
        let tintOverlayView = NSView()
        tintOverlayView.wantsLayer = true
        tintOverlayView.layer?.backgroundColor = tintColor?.withAlphaComponent(tintOpacity).cgColor

        let containerView = GlassContainerView(
            baseGlassView: baseGlassView,
            edgeLightingView: edgeLightingView,
            tintOverlayView: tintOverlayView
        )

        // Set corner radii
        containerView.cornerRadius = cornerRadius
        containerView.topLeadingRadius = topLeadingRadius
        containerView.bottomLeadingRadius = bottomLeadingRadius
        containerView.topTrailingRadius = topTrailingRadius
        containerView.bottomTrailingRadius = bottomTrailingRadius

        // Add subviews
        containerView.addSubview(baseGlassView)
        containerView.addSubview(edgeLightingView)
        containerView.addSubview(tintOverlayView)

        // Setup constraints
        baseGlassView.translatesAutoresizingMaskIntoConstraints = false
        edgeLightingView.translatesAutoresizingMaskIntoConstraints = false
        tintOverlayView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            baseGlassView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            baseGlassView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            baseGlassView.topAnchor.constraint(equalTo: containerView.topAnchor),
            baseGlassView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),

            edgeLightingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            edgeLightingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            edgeLightingView.topAnchor.constraint(equalTo: containerView.topAnchor),
            edgeLightingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),

            tintOverlayView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            tintOverlayView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            tintOverlayView.topAnchor.constraint(equalTo: containerView.topAnchor),
            tintOverlayView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])

        return containerView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let container = nsView as? GlassContainerView else { return }

        // Update material
        if container.baseGlassView.material != material {
            container.baseGlassView.material = material
        }

        // Update tint overlay
        container.tintOverlayView.layer?.backgroundColor = tintColor?.withAlphaComponent(tintOpacity).cgColor

        // Update corner radii - container's layout() will handle mask updates
        container.cornerRadius = cornerRadius
        container.topLeadingRadius = topLeadingRadius
        container.bottomLeadingRadius = bottomLeadingRadius
        container.topTrailingRadius = topTrailingRadius
        container.bottomTrailingRadius = bottomTrailingRadius
        container.updateMaskIfNeeded()

        // Edge lighting disabled for clean look
        container.edgeLightingView.layer?.borderWidth = 0
    }
}

// Reusable surface wrapper that composes the glass background and overlays
struct GlassSurface: View {
    var cornerRadius: CGFloat = 28
    var topLeadingRadius: CGFloat?
    var bottomLeadingRadius: CGFloat?
    var topTrailingRadius: CGFloat?
    var bottomTrailingRadius: CGFloat?
    var material: NSVisualEffectView.Material = .hudWindow
    @Environment(\.colorScheme) private var colorScheme

    private var hasCustomCorners: Bool {
        topLeadingRadius != nil || bottomLeadingRadius != nil || topTrailingRadius != nil
            || bottomTrailingRadius != nil
    }

    var body: some View {
        ZStack {
            // Base AppKit-backed glass layer (includes edge lighting)
            GlassBackground(
                cornerRadius: cornerRadius,
                topLeadingRadius: topLeadingRadius,
                bottomLeadingRadius: bottomLeadingRadius,
                topTrailingRadius: topTrailingRadius,
                bottomTrailingRadius: bottomTrailingRadius,
                material: material
            )

            // Gradient overlay for brightness/contrast - stronger in light mode for text readability
            if hasCustomCorners {
                UnevenRoundedRectangle(
                    topLeadingRadius: topLeadingRadius ?? cornerRadius,
                    bottomLeadingRadius: bottomLeadingRadius ?? cornerRadius,
                    bottomTrailingRadius: bottomTrailingRadius ?? cornerRadius,
                    topTrailingRadius: topTrailingRadius ?? cornerRadius,
                    style: .continuous
                )
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.08 : 0.5),
                            Color.white.opacity(colorScheme == .dark ? 0.03 : 0.35),
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.08 : 0.5),
                                Color.white.opacity(colorScheme == .dark ? 0.03 : 0.35),
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Themed Glass Surface

/// A glass surface that automatically uses theme-configured glass properties
struct ThemedGlassSurface: View {
    var cornerRadius: CGFloat = 28
    var topLeadingRadius: CGFloat?
    var bottomLeadingRadius: CGFloat?
    var topTrailingRadius: CGFloat?
    var bottomTrailingRadius: CGFloat?

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var hasCustomCorners: Bool {
        topLeadingRadius != nil || bottomLeadingRadius != nil || topTrailingRadius != nil
            || bottomTrailingRadius != nil
    }

    var body: some View {
        ZStack {
            // Base AppKit-backed glass layer with theme material and tint
            GlassBackground(
                cornerRadius: cornerRadius,
                topLeadingRadius: topLeadingRadius,
                bottomLeadingRadius: bottomLeadingRadius,
                topTrailingRadius: topTrailingRadius,
                bottomTrailingRadius: bottomTrailingRadius,
                material: theme.glassMaterial,
                tintColor: theme.glassTintColor.map { NSColor($0) },
                tintOpacity: CGFloat(theme.glassTintOpacity)
            )

            // Gradient overlay for brightness/contrast
            gradientOverlay
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var gradientOverlay: some View {
        let gradientColors = [
            Color.white.opacity(colorScheme == .dark ? theme.glassOpacityPrimary : 0.5),
            Color.white.opacity(colorScheme == .dark ? theme.glassOpacitySecondary : 0.35),
        ]

        if hasCustomCorners {
            UnevenRoundedRectangle(
                topLeadingRadius: topLeadingRadius ?? cornerRadius,
                bottomLeadingRadius: bottomLeadingRadius ?? cornerRadius,
                bottomTrailingRadius: bottomTrailingRadius ?? cornerRadius,
                topTrailingRadius: topTrailingRadius ?? cornerRadius,
                style: .continuous
            )
            .fill(
                LinearGradient(
                    gradient: Gradient(colors: gradientColors),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: gradientColors),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }
}

// MARK: - Theme Background Image View

/// View that renders a theme's background image with proper scaling and overlay
struct ThemeBackgroundImage: View {
    @Environment(\.theme) private var theme

    var body: some View {
        if let backgroundImage = theme.backgroundImage {
            ZStack {
                Image(nsImage: backgroundImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(theme.backgroundImageOpacity)

                // Overlay if configured
                if let overlayColor = theme.backgroundOverlayColor {
                    overlayColor.opacity(theme.backgroundOverlayOpacity)
                }
            }
        }
    }
}
