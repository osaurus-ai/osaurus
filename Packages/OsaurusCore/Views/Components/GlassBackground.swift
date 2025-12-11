//
//  GlassBackground.swift
//  osaurus
//
//  Multi-layer glass effect with enhanced blur and edge lighting
//

import AppKit
import SwiftUI

// Container view that holds references to subviews for updates
final class GlassContainerView: NSView {
    let baseGlassView: NSVisualEffectView
    let edgeLightingView: NSView

    // Corner radii for mask - when set, uses mask layer instead of cornerRadius
    var cornerRadius: CGFloat = 28
    var topLeadingRadius: CGFloat?
    var bottomLeadingRadius: CGFloat?
    var topTrailingRadius: CGFloat?
    var bottomTrailingRadius: CGFloat?

    var hasCustomCorners: Bool {
        topLeadingRadius != nil || bottomLeadingRadius != nil || topTrailingRadius != nil || bottomTrailingRadius != nil
    }

    init(baseGlassView: NSVisualEffectView, edgeLightingView: NSView) {
        self.baseGlassView = baseGlassView
        self.edgeLightingView = edgeLightingView
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
            baseGlassView.layer?.cornerRadius = cornerRadius
            baseGlassView.layer?.masksToBounds = true
            edgeLightingView.layer?.cornerRadius = cornerRadius
            edgeLightingView.layer?.masksToBounds = true
            return
        }

        // Use mask for custom corners
        baseGlassView.layer?.cornerRadius = 0
        baseGlassView.layer?.masksToBounds = false
        edgeLightingView.layer?.cornerRadius = 0
        edgeLightingView.layer?.masksToBounds = false

        guard bounds.width > 0 && bounds.height > 0 else { return }

        baseGlassView.layer?.mask = createMaskLayer(for: bounds)
        edgeLightingView.layer?.mask = createMaskLayer(for: bounds)
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

        let containerView = GlassContainerView(
            baseGlassView: baseGlassView,
            edgeLightingView: edgeLightingView
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

        // Setup constraints
        baseGlassView.translatesAutoresizingMaskIntoConstraints = false
        edgeLightingView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            baseGlassView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            baseGlassView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            baseGlassView.topAnchor.constraint(equalTo: containerView.topAnchor),
            baseGlassView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),

            edgeLightingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            edgeLightingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            edgeLightingView.topAnchor.constraint(equalTo: containerView.topAnchor),
            edgeLightingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])

        return containerView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let container = nsView as? GlassContainerView else { return }

        // Update material
        if container.baseGlassView.material != material {
            container.baseGlassView.material = material
        }

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
        topLeadingRadius != nil || bottomLeadingRadius != nil || topTrailingRadius != nil || bottomTrailingRadius != nil
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
