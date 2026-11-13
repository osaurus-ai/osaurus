//
//  ThemeStatusInk.swift
//  osaurus
//
//  `status.*.ink`: the status tone drawn straight on the canvas or a card
//  (glyphs, text, progress), and the WCAG contrast math that derives it for
//  themes saved before the role existed.
//

import AppKit
import SwiftUI

enum ThemeContrast {
    /// WCAG relative luminance of a color in sRGB.
    static func luminance(_ color: Color) -> Double {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return 0 }
        func linear(_ c: CGFloat) -> Double {
            let c = Double(c)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
    }

    /// WCAG contrast ratio between two luminances.
    static func ratio(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static func ratio(_ a: Color, _ b: Color) -> Double {
        ratio(luminance(a), luminance(b))
    }
}

extension ThemeColorRoles where Value == Color {
    /// A theme saved before `status.*.ink` takes the shade of each set that
    /// stands out most from the canvas, which is how the library derives the role.
    func fillingStatusInk() -> Self {
        var result = self
        let canvas = ThemeContrast.luminance(surface.canvas)
        for kind in ThemeStatusKind.allCases {
            if kind == .urgentWarning, status.urgentWarning == nil { continue }
            var set = status[kind]
            guard set.ink == nil else { continue }
            set.ink = [set.foreground, set.border, set.background].max { a, b in
                ThemeContrast.ratio(ThemeContrast.luminance(a), canvas) < ThemeContrast.ratio(ThemeContrast.luminance(b), canvas)
            }
            result.status[kind] = set
        }
        return result
    }
}

extension ThemeProtocol {
    /// The `status.*.ink` role for glyphs, text and progress on the canvas or
    /// a card; `foreground` is for text on the status fill.
    func statusInk(_ kind: ThemeStatusKind) -> Color {
        status[kind].ink ?? status[kind].foreground
    }
}
