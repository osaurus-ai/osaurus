//
//  ThemeHexColorRoundTripTests.swift
//  osaurusTests
//
//  Coverage for the Color <-> hex round trip used by the theme editor's
//  color picker. The picker writes colors with toHex(includeAlpha:) and
//  reads them back with Color(themeHex:), so the two must agree on byte
//  order or every semi-transparent pick lands on a different color.
//

import AppKit
import SwiftUI
import Testing

@testable import OsaurusCore

@Suite("Theme hex color round trip")
struct ThemeHexColorRoundTripTests {
    private func components(_ color: Color) -> (r: Int, g: Int, b: Int, a: Int) {
        let ns = NSColor(color).usingColorSpace(.sRGB)!
        return (
            Int((ns.redComponent * 255).rounded()),
            Int((ns.greenComponent * 255).rounded()),
            Int((ns.blueComponent * 255).rounded()),
            Int((ns.alphaComponent * 255).rounded())
        )
    }

    @Test("opaque colors emit six digits and round trip")
    func opaqueRoundTrip() {
        let hex = Color(themeHex: "#3B82F6").toHex(includeAlpha: true)
        #expect(hex == "#3B82F6")
        let back = components(Color(themeHex: hex))
        #expect(back.r == 0x3B && back.g == 0x82 && back.b == 0xF6 && back.a == 255)
    }

    @Test("semi-transparent colors emit trailing alpha (RRGGBBAA)")
    func alphaByteOrderMatchesParser() {
        let hex = Color(themeHex: "#3B82F680").toHex(includeAlpha: true)
        #expect(hex == "#3B82F680")
    }

    @Test("semi-transparent colors survive repeated round trips unchanged")
    func alphaRoundTripIsStable() {
        // Simulates the picker feedback loop: emit hex, parse, emit again.
        var hex = "#3B82F680"
        for _ in 0 ..< 5 {
            hex = Color(themeHex: hex).toHex(includeAlpha: true)
        }
        let back = components(Color(themeHex: hex))
        #expect(back.r == 0x3B && back.g == 0x82 && back.b == 0xF6 && back.a == 0x80)
    }
}

@Suite("Theme gradient angle")
struct ThemeGradientAngleTests {
    private func points(_ angle: Double?) -> (start: UnitPoint, end: UnitPoint) {
        ThemeBackground(type: .gradient, gradientAngle: angle).gradientUnitPoints
    }

    private func near(_ a: UnitPoint, _ b: UnitPoint) -> Bool {
        abs(a.x - b.x) < 0.001 && abs(a.y - b.y) < 0.001
    }

    @Test("unset angle keeps the legacy top-to-bottom direction")
    func unsetAngleIsTopToBottom() {
        let p = points(nil)
        #expect(near(p.start, .top) && near(p.end, .bottom))
    }

    @Test("0 degrees runs bottom to top, 90 runs left to right")
    func cssAngleConvention() {
        let up = points(0)
        #expect(near(up.start, .bottom) && near(up.end, .top))
        let right = points(90)
        #expect(near(right.start, .leading) && near(right.end, .trailing))
    }
}
