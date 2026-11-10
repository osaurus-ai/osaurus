//
//  SettingsSearchHighlight.swift
//  osaurus
//
//  The soft accent glow a settings-search landing target breathes once.
//

import SwiftUI

extension View {
    /// Wraps a control in a soft accent glow while it's the active search-result
    /// landing target — no border, just a halo that hugs the control's shape. A
    /// no-op when `active` is false. Driven by `settingsLandingAnchor`.
    func settingsSearchHighlight(_ active: Bool) -> some View {
        modifier(SettingsSearchHighlightModifier(active: active))
    }
}

private struct SettingsSearchHighlightModifier: ViewModifier {
    let active: Bool
    @ObservedObject private var themeManager = ThemeManager.shared

    /// 0 at rest, eased up to 1 and gently back to 0 once when the control
    /// becomes a match — a single soft breath layered over a faint persistent
    /// glow, so the matched control stays gently lit without any border.
    @State private var glow: CGFloat = 0

    /// Half the breath: rise over `breathDuration`, fall over `breathDuration`.
    private static let breathDuration: Double = 0.9

    private var glowOpacity: Double { active ? 0.22 + 0.5 * Double(glow) : 0 }
    private var glowRadius: CGFloat { active ? 6 + 14 * glow : 0 }

    func body(content: Content) -> some View {
        let theme = themeManager.currentTheme
        content
            // Rasterize the (possibly whole-card) content once per frame so the
            // animated glow blurs a single flattened layer, not every subview.
            .compositingGroup()
            .shadow(color: theme.border.focus.opacity(glowOpacity), radius: glowRadius)
            .animation(theme.motion.standard, value: active)
            .onAppear { if active { firePulse() } }
            .onChange(of: active) { _, isActive in
                if isActive { firePulse() } else { glow = 0 }
            }
    }

    /// One smooth breath: ease the glow up, then — on completion — ease it back
    /// down to the resting glow. The completion handler (rather than a
    /// repeating animation) keeps the model value honest, so the glow can't
    /// snap or get stuck bright when it finishes.
    private func firePulse() {
        glow = 0
        let breath = themeManager.currentTheme.motion.timed(.easeInOut, duration: Self.breathDuration)
        withAnimation(breath) {
            glow = 1
        } completion: {
            withAnimation(breath) {
                glow = 0
            }
        }
    }
}
