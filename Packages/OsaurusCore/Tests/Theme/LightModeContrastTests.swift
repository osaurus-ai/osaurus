//
//  LightModeContrastTests.swift
//  OsaurusCoreTests
//
//  Contrast floors for the light theme: the selection hairline, the
//  categorical data inks, and tertiary text must stay readable on every
//  light surface they are drawn on.
//

import AppKit
import SwiftUI
import Testing

@testable import OsaurusCore

@Suite("Light mode contrast")
@MainActor
struct LightModeContrastTests {
    private let light: ThemeProtocol = CustomizableTheme.light()
    private let dark: ThemeProtocol = CustomizableTheme.dark()

    private var lightSurfaces: [(String, Color)] {
        [
            ("canvas", light.surface.canvas),
            ("raised", light.surface.raised),
            ("subtle", light.surface.subtle),
            ("sidebar", light.surface.sidebar),
        ]
    }

    private func ratio(_ a: Color, _ b: Color) -> Double {
        ThemeContrast.ratio(a, b)
    }

    /// `ink` laid over `base` at `opacity`, as a tinted chip wash renders.
    private func wash(_ ink: Color, over base: Color, opacity: Double) -> Color {
        guard let top = NSColor(ink).usingColorSpace(.sRGB),
            let bottom = NSColor(base).usingColorSpace(.sRGB)
        else { return base }
        func mix(_ t: CGFloat, _ b: CGFloat) -> Double { Double(t) * opacity + Double(b) * (1 - opacity) }
        return Color(
            .sRGB,
            red: mix(top.redComponent, bottom.redComponent),
            green: mix(top.greenComponent, bottom.greenComponent),
            blue: mix(top.blueComponent, bottom.blueComponent)
        )
    }

    @Test
    func selectionBorder_meetsNonTextContrast_onLightSurfaces() {
        for (name, surface) in lightSurfaces {
            let value = ratio(light.selectionBorder, surface)
            #expect(value >= 3, "selection hairline is \(value):1 on \(name)")
        }
    }

    @Test
    func selectionHairline_ignoresFamilyScope() {
        let sidebarRow = light.catalogFamily(41, enabled: true)
        let nested = sidebarRow.catalogFamily(42, enabled: true)
        for scoped in [sidebarRow, nested] {
            #expect(scoped.selectionBorder == light.border.strong)
            #expect(abs(scoped.selectionStroke - light.stroke.default) < 0.001)
        }
        #expect(light.selectionStroke > 0)
    }

    @Test
    func darkThemes_drawNoSelectionHairline() {
        #expect(dark.selectionBorder == .clear)
        #expect(dark.emptyTrack(dark.surface.selected) == dark.surface.selected)
        #expect(dark.rowRule == dark.border.subtle)
    }

    /// `top` composited over `base` at its own alpha, as a translucent wash renders.
    private func composite(_ top: Color, over base: Color) -> Color {
        guard let alpha = NSColor(top).usingColorSpace(.sRGB)?.alphaComponent else { return base }
        return wash(top.opacity(1), over: base, opacity: Double(alpha))
    }

    @Test(arguments: [false, true])
    func dataInk_readsAsText_onSurfacesAndWashes(isDark: Bool) {
        let theme = isDark ? dark : light
        let surfaces: [(String, Color)] = [
            ("canvas", theme.surface.canvas), ("raised", theme.surface.raised),
            ("subtle", theme.surface.subtle), ("sidebar", theme.surface.sidebar),
        ]
        for ink in DataInk.allCases where ink.slot != nil {
            let color = theme.dataInk(ink)
            for (name, surface) in surfaces {
                let value = ratio(color, surface)
                #expect(value >= 4.5, "\(ink) ink is \(value):1 on \(name) (dark: \(isDark))")
            }
            let chip = composite(theme.dataWash(ink), over: theme.surface.raised)
            let value = ratio(color, chip)
            #expect(value >= 4.5, "\(ink) ink is \(value):1 on its own wash (dark: \(isDark))")
        }
    }

    @Test
    func tertiaryText_readsOnLightSurfaces() {
        for (name, surface) in lightSurfaces {
            let value = ratio(light.text.tertiary, surface)
            #expect(value >= 4.5, "tertiary text is \(value):1 on \(name)")
        }
    }

    @Test
    func httpMethods_mapToDistinctInks() {
        #expect(DataInk.httpMethod("GET") == .green)
        #expect(DataInk.httpMethod("POST") == .blue)
        #expect(DataInk.httpMethod("PUT") == .orange)
        #expect(DataInk.httpMethod("PATCH") == .orange)
        #expect(DataInk.httpMethod("DELETE") == .red)
        #expect(DataInk.httpMethod("OPTIONS") == nil)
    }
}
