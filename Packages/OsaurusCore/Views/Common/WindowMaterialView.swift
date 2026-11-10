//
//  WindowMaterialView.swift
//  osaurus
//
//  The single translucent layer in the app. Per design/HANDOFF.md the window
//  itself carries one `NSVisualEffectView` (`behindWindow` blending, the
//  theme's native material, default `.underWindowBackground`) with the
//  theme's canvas color laid over it at `windowMaterial.tintOpacity`
//  (default 0.75). Every component above this layer is opaque and painted
//  with semantic surface roles; there is no per-component glass.
//
//  Accessibility: when "Reduce transparency" is on, the blur is dropped and
//  the view paints the theme's opaque `windowMaterial.fallback` color.
//
//  Only the chat and Management windows host it. The menu-bar status panel
//  sits in an `NSPopover` (system popover material), the voice overlay is a
//  `pickerCardSurface` inside the chat window, and onboarding paints opaque
//  surface roles; an opaque canvas is always a valid base.
//

import AppKit
import SwiftUI

// MARK: - SwiftUI entry point

/// Theme-driven base window material. Place once at the root of a window's
/// content; everything else should be an opaque semantic surface.
struct WindowMaterialView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        WindowMaterialRepresentable(
            material: theme.windowMaterial.nativeMaterial.nsMaterial,
            blending: theme.windowMaterial.blending.nsBlendingMode,
            tint: NSColor(Color(themeHex: theme.windowMaterial.tint)),
            tintOpacity: theme.windowMaterial.tintOpacity,
            fallback: NSColor(Color(themeHex: theme.windowMaterial.fallback)),
            isDark: theme.isDark
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - AppKit backing

struct WindowMaterialRepresentable: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blending: NSVisualEffectView.BlendingMode
    let tint: NSColor
    let tintOpacity: Double
    let fallback: NSColor
    let isDark: Bool

    func makeNSView(context: Context) -> WindowMaterialContainerView {
        let view = WindowMaterialContainerView()
        view.apply(self)
        return view
    }

    func updateNSView(_ nsView: WindowMaterialContainerView, context: Context) {
        nsView.apply(self)
    }
}

/// Hosts the effect view and the tint layer, and swaps to the opaque fallback
/// when the user enables Reduce Transparency.
final class WindowMaterialContainerView: NSView {
    private let effectView = NSVisualEffectView()
    private let tintView = NSView()
    /// Accessibility-options observer token. `nonisolated(unsafe)` so the
    /// nonisolated deinit can remove it; it is only written from init.
    nonisolated(unsafe) private var observer: NSObjectProtocol?
    private var current: WindowMaterialRepresentable?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        effectView.autoresizingMask = [.width, .height]
        effectView.state = .active
        effectView.isEmphasized = false
        addSubview(effectView)

        tintView.wantsLayer = true
        tintView.autoresizingMask = [.width, .height]
        addSubview(tintView)

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let current = self.current else { return }
                self.apply(current)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    override func layout() {
        super.layout()
        effectView.frame = bounds
        tintView.frame = bounds
    }

    /// Whether the material should be replaced by the opaque fallback.
    static var reduceTransparencyEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    func apply(_ spec: WindowMaterialRepresentable) {
        current = spec
        appearance = NSAppearance(named: spec.isDark ? .darkAqua : .aqua)

        if Self.reduceTransparencyEnabled {
            effectView.isHidden = true
            tintView.layer?.backgroundColor = spec.fallback.cgColor
            return
        }

        effectView.isHidden = false
        effectView.material = spec.material
        effectView.blendingMode = spec.blending
        effectView.appearance = appearance
        let alpha = CGFloat(min(max(spec.tintOpacity, 0), 1))
        tintView.layer?.backgroundColor = spec.tint.withAlphaComponent(alpha).cgColor
    }
}
