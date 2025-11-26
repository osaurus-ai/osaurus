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

    init(baseGlassView: NSVisualEffectView, edgeLightingView: NSView) {
        self.baseGlassView = baseGlassView
        self.edgeLightingView = edgeLightingView
        super.init(frame: .zero)
        self.wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

struct GlassBackground: NSViewRepresentable {
    var cornerRadius: CGFloat = 28
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSView {
        // Base glass layer with strong blur
        let baseGlassView = NSVisualEffectView()
        baseGlassView.material = material
        baseGlassView.blendingMode = .behindWindow
        baseGlassView.state = .active
        baseGlassView.wantsLayer = true
        baseGlassView.layer?.cornerRadius = cornerRadius
        baseGlassView.layer?.masksToBounds = true

        // Edge lighting layer (disabled - using single clean edge)
        let edgeLightingView = NSView()
        edgeLightingView.wantsLayer = true
        edgeLightingView.layer?.cornerRadius = cornerRadius
        edgeLightingView.layer?.masksToBounds = true
        edgeLightingView.layer?.borderWidth = 0
        edgeLightingView.layer?.borderColor = nil

        let containerView = GlassContainerView(
            baseGlassView: baseGlassView,
            edgeLightingView: edgeLightingView
        )

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
        // Update material and corner radius on changes
        if container.baseGlassView.material != material {
            container.baseGlassView.material = material
        }
        if container.baseGlassView.layer?.cornerRadius != cornerRadius {
            container.baseGlassView.layer?.cornerRadius = cornerRadius
            container.baseGlassView.layer?.masksToBounds = true
        }
        if container.edgeLightingView.layer?.cornerRadius != cornerRadius {
            container.edgeLightingView.layer?.cornerRadius = cornerRadius
            container.edgeLightingView.layer?.masksToBounds = true
        }
        // Edge lighting disabled for clean look
        container.edgeLightingView.layer?.borderWidth = 0
    }
}

// Reusable surface wrapper that composes the glass background and overlays
struct GlassSurface: View {
    var cornerRadius: CGFloat = 28
    var material: NSVisualEffectView.Material = .hudWindow
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // Base AppKit-backed glass layer (includes edge lighting)
            GlassBackground(cornerRadius: cornerRadius, material: material)

            // Subtle gradient overlay to tune perceived brightness/contrast
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.08 : 0.15),
                            Color.white.opacity(colorScheme == .dark ? 0.03 : 0.08),
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .allowsHitTesting(false)
    }
}
