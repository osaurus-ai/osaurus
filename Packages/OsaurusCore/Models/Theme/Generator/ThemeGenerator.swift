//
//  ThemeGenerator.swift
//  osaurus
//
//  Turns `ThemePreferences` into design-library primitives, aliases and
//  scalar tokens. Every choice the editor offers produces a complete,
//  contrast-safe theme: tones are hand-tuned ramps, accents are solved for
//  contrast in OKLCH, and readability recipes keep the type hierarchy.
//

import Foundation

/// What the generator contributes to a compile.
struct ThemeGeneratedLayer: Sendable {
    /// Replaces same-named primitives (`neutral/*`, `alpha/contrast-*`,
    /// `accent/*`, `highlight/*`).
    var primitives: [String: DesignPrimitiveColor] = [:]
    /// Re-points color roles; applied before `resolvingColors()`.
    var aliases: [String: DesignColorAlias] = [:]
    /// Complete scalar and typography values; applied after resolving.
    var tokens: [String: ThemeTokenOverride] = [:]
}

enum ThemeGenerator {
    static let modes = ["light", "dark"]

    /// Minimum WCAG ratios the solver aims for, with a small margin so
    /// rounding to 8-bit hex never lands under the line.
    struct Targets {
        var text: Double
        var nonText: Double
        static let standard = Targets(text: 4.5, nonText: 3)
        static let high = Targets(text: 7, nonText: 4.5)
        static let margin = 0.25
    }

    /// Accent chroma never exceeds these, so no choice reads as neon.
    static let maxAccentChroma = (light: 0.14, dark: 0.13)
    static let maxHighlightChroma = 0.12

    // MARK: - Entry point

    static func layer(
        for preferences: ThemePreferences, highContrast: Bool, base: DesignWorkingDocument
    ) -> ThemeGeneratedLayer {
        var layer = ThemeGeneratedLayer()
        let tone = preferences.tone.primitives
        layer.primitives.merge(tone) { $1 }
        layer.primitives.merge(accentPrimitives(preferences.accent, tone: preferences.tone, highContrast: highContrast)) { $1 }
        if highContrast { layer.aliases = highContrastAliases }
        layer.tokens = scalarTokens(for: preferences, highContrast: highContrast, base: base)
        return layer
    }

    // MARK: - Accent

    /// Seeds for the swatches the solver tunes per mode. Teal and Graphite
    /// are hand-tuned and fixed.
    private static func seed(_ swatch: ThemeAccentSwatch) -> (accent: String, highlightHueShift: Double)? {
        switch swatch {
        case .teal, .graphite: return nil
        case .blue: return ("#2F6BD8", -18)  // + Sky
        case .violet: return ("#7348D6", 12)  // + Lilac
        case .rose: return ("#D23C68", 14)  // + Blush
        case .amber: return ("#C77712", 8)  // + Sand
        case .green: return ("#2E8B4A", -22)  // + Mint
        }
    }

    static func accentPrimitives(
        _ choice: ThemeAccentChoice, tone: ThemeTone, highContrast: Bool
    ) -> [String: DesignPrimitiveColor] {
        let targets = highContrast ? Targets.high : Targets.standard
        switch choice {
        case .swatch(.teal) where !highContrast:
            return ThemeFixedAccent.teal.primitives.merging(ThemeFixedHighlight.lime.primitives) { $1 }
        case .swatch(.graphite) where !highContrast:
            return ThemeFixedAccent.graphite.primitives.merging(ThemeFixedHighlight.silver.primitives) { $1 }
        case .swatch(let swatch):
            if let seed = seed(swatch), let rgb = ThemeColorMath.rgb(hex: seed.accent) {
                return solved(seed: rgb, highlightHueShift: seed.highlightHueShift, tone: tone, targets: targets)
            }
            // Fixed swatches under High keep their hue and are re-solved.
            let fixed = swatch == .teal ? ThemeFixedAccent.teal.primitives : ThemeFixedAccent.graphite.primitives
            let highlight = swatch == .teal ? ThemeFixedHighlight.lime.primitives : ThemeFixedHighlight.silver.primitives
            let seedHex = fixed["accent/background"]?.light ?? "#065456"
            var result = solved(
                seed: ThemeColorMath.rgb(hex: seedHex) ?? ThemeRGB(r: 0, g: 0.3, b: 0.3),
                highlightHueShift: 0, tone: tone, targets: targets
            )
            result.merge(highlight) { $1 }
            return result
        case .custom(let hex):
            guard let rgb = ThemeColorMath.rgb(hex: hex) else {
                return accentPrimitives(.swatch(.teal), tone: tone, highContrast: highContrast)
            }
            return solved(seed: rgb, highlightHueShift: 0, tone: tone, targets: targets)
        }
    }

    /// The color the picker shows for a choice: the adjusted primary action
    /// background in each mode.
    static func previewAccent(_ choice: ThemeAccentChoice, tone: ThemeTone = .warm) -> (light: String, dark: String) {
        let primitives = accentPrimitives(choice, tone: tone, highContrast: false)
        let bg = primitives["accent/background"]
        return (bg?.light ?? "#065456FF", bg?.dark ?? "#0DB1B5FF")
    }

    private static func solved(
        seed: ThemeRGB, highlightHueShift: Double, tone: ThemeTone, targets: Targets
    ) -> [String: DesignPrimitiveColor] {
        let ramp = tone.primitives
        func ink(_ step: String, _ mode: String) -> ThemeRGB {
            ThemeColorMath.rgb(hex: ramp["neutral/\(step)"]?[mode] ?? "#FFFFFF") ?? ThemeRGB(r: 1, g: 1, b: 1)
        }
        let source = ThemeColorMath.oklch(seed)
        let hue = source.h
        // Achromatic seeds stay achromatic; everything else keeps a floor of
        // color so the accent still reads as the user's pick.
        let isGray = source.c < 0.02
        var result: [String: DesignPrimitiveColor] = [:]
        func set(_ key: String, light: ThemeRGB, dark: ThemeRGB) {
            result[key] = DesignPrimitiveColor(light: ThemeColorMath.hex(light), dark: ThemeColorMath.hex(dark))
        }

        // Light: deep accent with canvas-colored text.
        let lightOn = ink("0", "light")
        let lightChroma = isGray ? source.c : min(max(source.c, 0.06), maxAccentChroma.light)
        let lightL = solveLightness(
            hue: hue, chroma: lightChroma, from: 0.62, step: -0.005,
            meets: { ThemeColorMath.contrast(lightOn, $0) >= targets.text + Targets.margin }
        )
        let lightBG = ThemeColorMath.rgb(ThemeOKLCH(l: lightL, c: lightChroma, h: hue))
        let lightHover = ThemeColorMath.rgb(ThemeOKLCH(l: lightL - 0.07, c: lightChroma, h: hue))
        let lighterPressed = ThemeColorMath.rgb(ThemeOKLCH(l: lightL + 0.04, c: lightChroma, h: hue))
        let lightPressed =
            ThemeColorMath.contrast(lightOn, lighterPressed) >= targets.text
            ? lighterPressed : ThemeColorMath.rgb(ThemeOKLCH(l: lightL - 0.035, c: lightChroma, h: hue))
        // Links sit on the darkest light surface the app uses for content.
        let lightSurfaces = ["0", "50", "100"].map { ink($0, "light") }
        let lightLinkL = solveLightness(
            hue: hue, chroma: lightChroma, from: 0.62, step: -0.005,
            meets: { c in lightSurfaces.allSatisfy { ThemeColorMath.contrast(c, $0) >= targets.text + Targets.margin } }
        )
        let lightLink = ThemeColorMath.rgb(ThemeOKLCH(l: lightLinkL, c: lightChroma, h: hue))
        let lightLinkHover = ThemeColorMath.rgb(ThemeOKLCH(l: lightLinkL - 0.06, c: lightChroma, h: hue))

        // Dark: bright accent with canvas-colored text.
        let darkOn = ink("0", "dark")
        let darkChroma = isGray ? source.c : min(max(source.c, 0.06), maxAccentChroma.dark)
        let darkL = solveLightness(
            hue: hue, chroma: darkChroma, from: 0.66, step: 0.005,
            meets: { ThemeColorMath.contrast(darkOn, $0) >= targets.text + Targets.margin }
        )
        let darkBG = ThemeColorMath.rgb(ThemeOKLCH(l: darkL, c: darkChroma, h: hue))
        let darkHover = ThemeColorMath.rgb(ThemeOKLCH(l: darkL + 0.05, c: darkChroma, h: hue))
        let darkerPressed = ThemeColorMath.rgb(ThemeOKLCH(l: darkL - 0.04, c: darkChroma, h: hue))
        let darkPressed =
            ThemeColorMath.contrast(darkOn, darkerPressed) >= targets.text
            ? darkerPressed : ThemeColorMath.rgb(ThemeOKLCH(l: darkL + 0.025, c: darkChroma, h: hue))
        let darkSurfaces = ["0", "50", "100", "200"].map { ink($0, "dark") }
        let darkLinkL = solveLightness(
            hue: hue, chroma: darkChroma, from: 0.62, step: 0.005,
            meets: { c in darkSurfaces.allSatisfy { ThemeColorMath.contrast(c, $0) >= targets.text + Targets.margin } }
        )
        let darkLink = ThemeColorMath.rgb(ThemeOKLCH(l: darkLinkL, c: darkChroma, h: hue))
        let darkLinkHover = ThemeColorMath.rgb(ThemeOKLCH(l: darkLinkL + 0.06, c: darkChroma, h: hue))

        let white = ThemeRGB(r: 1, g: 1, b: 1)
        set("accent/background", light: lightBG, dark: darkBG)
        set("accent/backgroundHover", light: lightHover, dark: darkHover)
        set("accent/backgroundPressed", light: lightPressed, dark: darkPressed)
        set("accent/foreground", light: lightOn, dark: darkOn)
        set("accent/border", light: lightHover, dark: white)
        set("accent/link", light: lightLink, dark: darkLink)
        set("accent/linkHover", light: lightLinkHover, dark: darkLinkHover)
        set("accent/focus", light: lightLink, dark: darkLink)

        // Highlight: same hue family, lighter and calmer.
        let hHue = (hue + highlightHueShift + 360).truncatingRemainder(dividingBy: 360)
        let hChroma = isGray ? source.c : min(max(source.c * 0.75, 0.05), maxHighlightChroma)
        func hl(_ l: Double) -> ThemeRGB { ThemeColorMath.rgb(ThemeOKLCH(l: l, c: hChroma, h: hHue)) }
        let lightInk = ink("900", "light")
        let lightHL = solveLightness(
            hue: hHue, chroma: hChroma, from: 0.9, step: 0.005,
            meets: { ThemeColorMath.contrast(lightInk, $0) >= targets.text + Targets.margin }
        )
        let darkHL = solveLightness(
            hue: hHue, chroma: hChroma, from: 0.86, step: 0.005,
            meets: { ThemeColorMath.contrast(darkOn, $0) >= targets.text + Targets.margin }
        )
        set("highlight/background", light: hl(lightHL), dark: hl(darkHL))
        set("highlight/backgroundHover", light: hl(lightHL - 0.03), dark: hl(darkHL + 0.03))
        set("highlight/backgroundPressed", light: hl(lightHL - 0.06), dark: hl(darkHL - 0.03))
        set("highlight/foreground", light: lightInk, dark: darkOn)
        set("highlight/foregroundHover", light: lightInk, dark: darkOn)
        set("highlight/border", light: hl(0.7), dark: white)
        set("highlight/borderHover", light: hl(0.64), dark: white)
        set("highlight/borderPressed", light: hl(lightHL - 0.06), dark: white)

        // Hover/pressed steps can lose a little contrast; text keeps the
        // target on every state.
        for (key, onKey) in [
            ("accent/backgroundHover", "accent/foreground"), ("highlight/backgroundHover", "highlight/foreground"),
            ("highlight/backgroundPressed", "highlight/foreground"),
        ] {
            for mode in modes {
                guard let bg = result[key]?[mode], let on = result[onKey]?[mode],
                    let bgRGB = ThemeColorMath.rgb(hex: bg), let onRGB = ThemeColorMath.rgb(hex: on),
                    ThemeColorMath.contrast(onRGB, bgRGB) < targets.text
                else { continue }
                let restingKey = key.replacingOccurrences(of: "Hover", with: "").replacingOccurrences(of: "Pressed", with: "")
                let resting = result[restingKey]?[mode] ?? bg
                result[key]?[mode] = resting
            }
        }
        return result
    }

    /// Walks lightness from `from` by `step` until `meets` holds, keeping
    /// hue and chroma (chroma shrinks only to stay in gamut).
    private static func solveLightness(
        hue: Double, chroma: Double, from: Double, step: Double, meets: (ThemeRGB) -> Bool
    ) -> Double {
        var l = from
        while l > 0.05 && l < 0.99 {
            if meets(ThemeColorMath.rgb(ThemeOKLCH(l: l, c: chroma, h: hue))) { return l }
            l += step
        }
        return step < 0 ? 0.05 : 0.99
    }

    // MARK: - High contrast

    /// Text one step stronger; borders and controls at least 4.5:1.
    static let highContrastAliases: [String: DesignColorAlias] = [
        "color.text.primary": .init(light: "neutral/900", dark: "neutral/900"),
        "color.text.secondary": .init(light: "neutral/800", dark: "neutral/800"),
        "color.text.tertiary": .init(light: "neutral/700", dark: "neutral/700"),
        "color.text.placeholder": .init(light: "neutral/700", dark: "neutral/700"),
        "color.border.default": .init(light: "neutral/600", dark: "neutral/600"),
        "color.border.strong": .init(light: "neutral/700", dark: "neutral/700"),
        "color.border.subtle": .init(light: "neutral/500", dark: "neutral/500"),
        "color.border.control": .init(light: "neutral/600", dark: "neutral/600"),
        "color.border.controlCheck": .init(light: "neutral/600", dark: "neutral/600"),
        "color.border.controlHover": .init(light: "neutral/700", dark: "neutral/700"),
        "color.action.secondary.default.foreground": .init(light: "neutral/900", dark: "neutral/900"),
        "color.action.tertiary.default.foreground": .init(light: "neutral/900", dark: "neutral/900"),
    ]

    // MARK: - Scalars

    static let bodyStyles: Set<String> = ["body", "bodyEmphasis", "bodySmall", "chatBody", "code", "label", "labelEmphasis"]
    static let headingStyles: Set<String> = ["display", "title", "heading", "subheading", "lead", "hero"]
    static let smallStyles: Set<String> = ["caption", "footnote", "micro"]
    /// Single-line chrome styles keep their line height under Relaxed.
    static let fixedLineStyles: Set<String> = ["label", "labelEmphasis", "micro"]

    static let subtleRadii: [String: Double] = [
        "radius.small": 3, "radius.medium": 5, "radius.large": 8, "radius.xlarge": 10, "radius.bubble": 12,
    ]

    static func scalarTokens(
        for preferences: ThemePreferences, highContrast: Bool, base: DesignWorkingDocument
    ) -> [String: ThemeTokenOverride] {
        var tokens: [String: ThemeTokenOverride] = [:]
        let readability = preferences.readability

        if preferences.corners == .subtle {
            for (key, value) in subtleRadii { tokens[key] = .both(.number(value)) }
        }
        if readability.strongerOutlines || highContrast {
            tokens["stroke.default"] = .both(.number(1.5))
            tokens["stroke.focus"] = .both(.number(3))
        }
        if highContrast {
            tokens["material.window.tintOpacity"] = .both(.number(1))
        }
        if readability.largerControls {
            tokens["size.control.defaultHeight"] = .both(.number(38))
            tokens["size.control.compactHeight"] = .both(.number(32))
            tokens["size.row.minimumHeight"] = .both(.number(42))
            tokens["size.chat.avatar"] = .both(.number(28))
        }
        if readability.uiFont != ThemeReadability.systemFont, !readability.uiFont.isEmpty {
            tokens["font.family.ui"] = .both(.string(readability.uiFont))
        }
        if readability.codeFont != ThemeReadability.systemFont, !readability.codeFont.isEmpty {
            tokens["font.family.code"] = .both(.string(readability.codeFont))
        }

        let delta: Double
        switch readability.readingSize {
        case .default: delta = 0
        case .large: delta = 2
        case .larger: delta = 4
        }
        let relaxed = readability.lineSpacing == .relaxed
        guard delta > 0 || relaxed else { return tokens }
        for (key, token) in base.tokens where key.hasPrefix("type.") {
            let style = String(key.dropFirst(5))
            var patch = ThemeTokenOverride()
            for mode in modes {
                guard let size = token[mode].designObject?["size"]?.designNumber,
                    let line = token[mode].designObject?["lineHeight"]?.designNumber, size > 0
                else { continue }
                var newSize = size
                if delta > 0 {
                    if bodyStyles.contains(style) {
                        newSize = size + delta
                    } else if headingStyles.contains(style) {
                        newSize = size + delta / 2
                    } else if smallStyles.contains(style) {
                        newSize = max(size + delta / 2, delta > 2 ? 13 : 12)
                    }
                }
                var newLine = (line * newSize / size).rounded()
                if relaxed, !headingStyles.contains(style), !fixedLineStyles.contains(style) {
                    newLine = (newLine * 1.15).rounded()
                }
                guard newSize != size || newLine != line else { continue }
                patch[mode] = .object(["size": .number(newSize), "lineHeight": .number(newLine)])
            }
            if patch.light != nil || patch.dark != nil { tokens[key] = patch }
        }
        return tokens
    }
}
