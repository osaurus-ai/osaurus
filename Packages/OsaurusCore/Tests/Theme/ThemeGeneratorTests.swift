//
//  ThemeGeneratorTests.swift
//  osaurusTests
//
//  Every preference combination the editor can produce compiles to a theme
//  that meets contrast, and custom accents are tamed.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ThemeGeneratorTests {
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    @Test
    func everySwatchToneAndContrastMeetsTargets() throws {
        for swatch in ThemeAccentSwatch.allCases {
            for tone in ThemeTone.allCases {
                for contrast in ThemeContrastLevel.allCases {
                    let document = ThemeDocument(
                        name: "probe",
                        preferences: ThemePreferences(accent: .swatch(swatch), tone: tone, contrast: contrast)
                    )
                    let compiled = try ThemeCompiler.compile(document, highContrast: false)
                    #expect(
                        compiled.contrastFindings.isEmpty,
                        "\(swatch) \(tone) \(contrast): \(compiled.contrastFindings.map(\.message))"
                    )
                }
            }
        }
    }

    @Test
    func randomCustomAccentsAreSolvedAndTamed() {
        var rng = SeededGenerator(state: 0x5EED)
        for _ in 0 ..< 200 {
            let hex = String(format: "#%06X", Int.random(in: 0 ... 0xFFFFFF, using: &rng))
            for tone in ThemeTone.allCases {
                for high in [false, true] {
                    let primitives = ThemeGenerator.accentPrimitives(.custom(hex), tone: tone, highContrast: high)
                    assertAccentContract(primitives, tone: tone, high: high, label: "\(hex) \(tone) high=\(high)")
                }
            }
        }
    }

    @Test
    func garishMagentaIsTamed() throws {
        let primitives = ThemeGenerator.accentPrimitives(.custom("#FF00FF"), tone: .warm, highContrast: false)
        for mode in ["light", "dark"] {
            let hex = try #require(primitives["accent/background"]?[mode])
            let color = try #require(ThemeColorMath.rgb(hex: hex))
            let lch = ThemeColorMath.oklch(color)
            #expect(lch.c <= ThemeGenerator.maxAccentChroma.light + 0.005)
            // Hue is kept: still a magenta.
            #expect(abs(lch.h - ThemeColorMath.oklch(ThemeColorMath.rgb(hex: "#FF00FF")!).h) < 6)
        }
    }

    private func assertAccentContract(
        _ primitives: [String: DesignPrimitiveColor], tone: ThemeTone, high: Bool, label: String
    ) {
        let ramp = tone.primitives
        let text = high ? 7.0 : 4.5
        func rgb(_ map: [String: DesignPrimitiveColor], _ key: String, _ mode: String) -> ThemeRGB? {
            map[key].flatMap { ThemeColorMath.rgb(hex: $0[mode]) }
        }
        for mode in ["light", "dark"] {
            guard let bg = rgb(primitives, "accent/background", mode), let on = rgb(primitives, "accent/foreground", mode),
                let hover = rgb(primitives, "accent/backgroundHover", mode), let link = rgb(primitives, "accent/link", mode),
                let canvas = rgb(ramp, "neutral/0", mode), let hl = rgb(primitives, "highlight/background", mode),
                let hlOn = rgb(primitives, "highlight/foreground", mode)
            else {
                Issue.record("missing primitive for \(label) \(mode)")
                continue
            }
            #expect(ThemeColorMath.contrast(on, bg) >= text, "\(label) \(mode) on-accent")
            #expect(ThemeColorMath.contrast(on, hover) >= text, "\(label) \(mode) on-accent hover")
            #expect(ThemeColorMath.contrast(bg, canvas) >= 3, "\(label) \(mode) accent vs canvas")
            #expect(ThemeColorMath.contrast(link, canvas) >= text, "\(label) \(mode) link")
            #expect(ThemeColorMath.contrast(hlOn, hl) >= text, "\(label) \(mode) highlight")
            let limit = mode == "dark" ? ThemeGenerator.maxAccentChroma.dark : ThemeGenerator.maxAccentChroma.light
            #expect(ThemeColorMath.oklch(bg).c <= limit + 0.005, "\(label) \(mode) chroma")
        }
    }

    @Test
    func osaurusPresetMatchesBundledLibrary() throws {
        let compiled = try ThemeCompiler.compile(ThemePresets.osaurus, highContrast: false)
        let bundled = try #require(DesignLibraryRuntime.bundledSnapshot())
        for (key, token) in bundled.document.tokens where key.hasPrefix("color.") {
            for mode in ["light", "dark"] {
                #expect(
                    compiled.snapshot.document.tokens[key]?[mode].designString?.uppercased()
                        == token[mode].designString?.uppercased(),
                    "\(key) \(mode)"
                )
            }
        }
        #expect(compiled.snapshot.light.colors.surface.canvas == bundled.light.colors.surface.canvas)
    }

    @Test
    func toneAndAccentReachTheResolvedTheme() throws {
        let document = ThemeDocument(
            name: "Nordish", preferences: ThemePreferences(accent: .swatch(.blue), tone: .cool)
        )
        let compiled = try ThemeCompiler.compile(document, highContrast: false)
        let cool = ThemeTone.cool.primitives
        #expect(compiled.snapshot.light.colors.surface.canvas.uppercased() == cool["neutral/0"]?.light.uppercased())
        #expect(compiled.snapshot.dark.colors.surface.canvas.uppercased() == cool["neutral/0"]?.dark.uppercased())
        let accent = ThemeGenerator.accentPrimitives(.swatch(.blue), tone: .cool, highContrast: false)
        #expect(
            compiled.snapshot.light.colors.action.primary.default.background.uppercased()
                == accent["accent/background"]?.light.uppercased()
        )
    }

    @Test
    func readabilityStacksWithFontScale() throws {
        var preferences = ThemePreferences()
        preferences.readability.readingSize = .larger
        preferences.readability.lineSpacing = .relaxed
        preferences.readability.largerControls = true
        preferences.readability.strongerOutlines = true
        let compiled = try ThemeCompiler.compile(ThemeDocument(name: "Big", preferences: preferences), highContrast: false)
        let base = try #require(DesignLibraryRuntime.bundledSnapshot()).light
        let light = compiled.snapshot.light
        #expect(light.typography.styles.chatBody.size == base.typography.styles.chatBody.size + 4)
        #expect(light.typography.styles.code.size == base.typography.styles.code.size + 4)
        #expect(light.typography.styles.heading.size == base.typography.styles.heading.size + 2)
        #expect(light.typography.styles.caption.size >= 13)
        #expect(light.typography.styles.chatBody.lineHeight > base.typography.styles.chatBody.lineHeight)
        #expect(light.controlSize.defaultHeight == 38)
        #expect(light.controlSize.rowMinimumHeight == 42)
        #expect(light.controlSize.chatAvatar == 28)
        #expect(light.stroke.default == 1.5)
        #expect(light.stroke.focus == 3)

        let theme = CustomizableTheme(resolved: light, fontScale: 1.6)
        #expect(abs(theme.scaledTextStyle(.chatBody).size - (base.typography.styles.chatBody.size + 4) * 1.6) < 0.001)
    }

    @Test
    func subtleCornersAndHighContrastScalars() throws {
        let document = ThemeDocument(
            name: "Crisp", preferences: ThemePreferences(contrast: .high, corners: .subtle)
        )
        let compiled = try ThemeCompiler.compile(document, highContrast: false)
        let light = compiled.snapshot.light
        #expect(light.radius.medium == 5)
        #expect(light.radius.bubble == 12)
        #expect(light.windowMaterial.tintOpacity == 1)
        #expect(light.stroke.focus == 3)
        #expect(compiled.contrastFindings.isEmpty)
    }

    @Test
    func transparencySetsTheWindowTint() throws {
        func tint(_ transparency: ThemeTransparency) throws -> (light: Double, dark: Double) {
            let document = ThemeDocument(name: "Pane", preferences: ThemePreferences(transparency: transparency))
            let snapshot = try ThemeCompiler.compile(document, highContrast: false).snapshot
            return (snapshot.light.windowMaterial.tintOpacity, snapshot.dark.windowMaterial.tintOpacity)
        }
        let bundled = ThemeWindowMaterial.lightDefaults.tintOpacity
        #expect(try tint(.frosted).light == bundled)
        #expect(try tint(.frosted).dark == ThemeWindowMaterial.darkDefaults.tintOpacity)
        #expect(try tint(.glass).light < bundled)
        #expect(try tint(.glass).dark < ThemeWindowMaterial.darkDefaults.tintOpacity)
        let solid = try tint(.solid)
        #expect(solid.light == 1 && solid.dark == 1)
    }

    @Test
    func systemIncreaseContrastForcesHighRecipe() throws {
        let standard = try ThemeCompiler.compile(ThemePresets.osaurus, highContrast: false)
        let forced = try ThemeCompiler.compile(ThemePresets.osaurus, highContrast: true)
        #expect(standard.snapshot.light.colors.text.secondary != forced.snapshot.light.colors.text.secondary)
        #expect(forced.snapshot.light.windowMaterial.tintOpacity == 1)
    }

    @Test
    func customFontsRetargetEveryRecipe() throws {
        var preferences = ThemePreferences()
        preferences.readability.uiFont = "Atkinson Hyperlegible"
        preferences.readability.codeFont = "Menlo"
        let compiled = try ThemeCompiler.compile(ThemeDocument(name: "Fonts", preferences: preferences), highContrast: false)
        let tokens = compiled.snapshot.document.tokens
        #expect(compiled.snapshot.light.typography.families.ui == "Atkinson Hyperlegible")
        #expect(compiled.snapshot.light.typography.families.code == "Menlo")
        #expect(tokens["type.body"]?.light.designObject?["family"]?.designString == "Atkinson Hyperlegible")
        #expect(tokens["type.code"]?.light.designObject?["family"]?.designString == "Menlo")
    }

    @Test
    func colorOverridesFollowThroughAliases() throws {
        let document = ThemeDocument(
            name: "Override",
            overrides: ThemeOverrides(tokens: [
                "color.surface.canvas": ThemeTokenOverride(light: .string("#F4F1EA"), dark: .string("#14130F")),
                "type.chatBody": .both(.object(["size": .number(18)])),
            ])
        )
        let compiled = try ThemeCompiler.compile(document, highContrast: false)
        #expect(compiled.snapshot.light.colors.surface.canvas.uppercased().hasPrefix("#F4F1EA"))
        #expect(compiled.snapshot.dark.colors.surface.canvas.uppercased().hasPrefix("#14130F"))
        #expect(compiled.snapshot.light.typography.styles.chatBody.size == 18)
        // Line height follows the new size proportionally.
        #expect(compiled.snapshot.light.typography.styles.chatBody.lineHeight > 22)
    }

    @Test
    func lowContrastOverrideIsReported() throws {
        let document = ThemeDocument(
            name: "Faint",
            overrides: ThemeOverrides(tokens: ["color.text.primary": .both(.string("#CCCCCC"))])
        )
        let compiled = try ThemeCompiler.compile(document, highContrast: false)
        #expect(compiled.contrastFindings.contains { $0.foreground == "color.text.primary" && $0.mode == "light" })
    }
}
