//
//  SystemAccentColor.swift
//  osaurus
//
//  Resolves the user's system accent color (System Settings > Appearance)
//  for themes that opt in via `CustomTheme.followsSystemAccent`.
//

import AppKit

public enum SystemAccentColor {
    /// The current system accent color as an sRGB `#rrggbb` hex string,
    /// resolved under the appearance the theme targets. `controlAccentColor`
    /// is a dynamic color whose components differ between light and dark
    /// appearances, so the derived palette must be sampled under the right one.
    public static func currentAccentHex(isDark: Bool) -> String? {
        guard let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua) else { return nil }

        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.controlAccentColor.usingColorSpace(.sRGB)
        }
        guard let color = resolved else { return nil }

        let r = Int((color.redComponent * 255).rounded())
        let g = Int((color.greenComponent * 255).rounded())
        let b = Int((color.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
