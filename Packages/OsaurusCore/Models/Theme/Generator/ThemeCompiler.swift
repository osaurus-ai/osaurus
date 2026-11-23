//
//  ThemeCompiler.swift
//  osaurus
//
//  Compiles a `ThemeDocument` into a design-library snapshot: the bundled
//  library, then the generated layer, then policy-checked overrides, then
//  `resolvingColors()` and `makeSnapshot`. Pure value work, safe off the
//  main actor; results are cached by document and contrast state.
//

import Foundation

/// One contrast pair that falls short of its WCAG target.
public struct ThemeContrastFinding: Equatable, Hashable, Sendable, Identifiable {
    public var mode: String
    public var foreground: String
    public var background: String
    public var ratio: Double
    public var required: Double

    public var id: String { "\(mode)|\(foreground)|\(background)" }

    public var message: String {
        let modeName = mode == "dark" ? L("Dark") : L("Light")
        return L("\(modeName): \(foreground) on \(background) is \(String(format: "%.1f", ratio)):1 (needs \(String(format: "%.1f", required)):1).")
    }
}

struct ThemeCompiledTheme: Sendable {
    let snapshot: DesignThemeSnapshot
    let policyFindings: [ThemePolicyFinding]
    let contrastFindings: [ThemeContrastFinding]
}

enum ThemeCompiler {
    /// The bundled library as stored: primitives and aliases still unresolved.
    static let rawLibrary: DesignWorkingDocument = {
        do {
            return try JSONDecoder().decode(DesignWorkingDocument.self, from: DesignLibraryRuntime.resource("design-library"))
        } catch {
            preconditionFailure("Bundled design library cannot load: \(error)")
        }
    }()

    /// The bundled library with every alias resolved; the reference for
    /// policy checks and generated scalar values.
    static let library: DesignWorkingDocument = {
        do { return try rawLibrary.resolvingColors() } catch {
            preconditionFailure("Bundled design library cannot resolve: \(error)")
        }
    }()

    // MARK: - Compile

    static func compile(_ document: ThemeDocument, highContrast: Bool) throws -> ThemeCompiledTheme {
        let effectiveHigh = highContrast || document.preferences.contrast == .high
        let layer = ThemeGenerator.layer(for: document.preferences, highContrast: effectiveHigh, base: library)
        let (overrides, findings) = ThemeTokenPolicy.sanitize(document.overrides, base: library)

        var doc = rawLibrary
        doc.primitives = (doc.primitives ?? [:]).merging(layer.primitives) { $1 }
        doc.colorAliases = (doc.colorAliases ?? [:]).merging(layer.aliases) { $1 }

        // Color overrides become primitives so `@token` references (bevels,
        // effects) follow them through `resolvingColors()`.
        var scalarOverrides: [String: ThemeTokenOverride] = [:]
        for (key, entry) in overrides.tokens {
            guard ThemeTokenPolicy.rule(for: key) == .color else {
                scalarOverrides[key] = entry
                continue
            }
            let primitive = "theme/\(key)"
            let existing = doc.colorAliases?[key] ?? DesignColorAlias()
            var alias = existing
            var value = DesignPrimitiveColor(light: "#00000000", dark: "#00000000")
            for mode in ThemeGenerator.modes {
                guard let hex = entry[mode]?.designString, let rgb = ThemeColorMath.rgb(hex: hex) else { continue }
                value[mode] = ThemeColorMath.hex(rgb)
                alias[mode] = primitive
            }
            doc.primitives?[primitive] = value
            doc.colorAliases?[key] = alias
        }
        doc = try doc.resolvingColors()

        let baseUI = doc.tokens["font.family.ui"]?.light.designString
        let baseCode = doc.tokens["font.family.code"]?.light.designString
        apply(layer.tokens, to: &doc)
        apply(scalarOverrides, to: &doc)
        retargetRecipeFamilies(in: &doc, from: baseUI, token: "font.family.ui")
        retargetRecipeFamilies(in: &doc, from: baseCode, token: "font.family.code")

        let made = try DesignLibraryDefinition.makeSnapshot(doc)
        var light = made.light, dark = made.dark
        light.codeHighlightTheme = document.codeHighlightTheme
        dark.codeHighlightTheme = document.codeHighlightTheme
        let snapshot = DesignThemeSnapshot(light: light, dark: dark, document: made.document, changedTokens: made.changedTokens)
        return ThemeCompiledTheme(
            snapshot: snapshot, policyFindings: findings,
            contrastFindings: contrastReport(doc, high: effectiveHigh, modes: modes(for: document.appearance))
        )
    }

    private static func modes(for appearance: ThemeAppearance) -> [String] {
        switch appearance {
        case .both: return ThemeGenerator.modes
        case .light: return ["light"]
        case .dark: return ["dark"]
        }
    }

    /// Typography values may be partial recipes; every other value replaces.
    private static func apply(_ tokens: [String: ThemeTokenOverride], to doc: inout DesignWorkingDocument) {
        for (key, entry) in tokens {
            guard var token = doc.tokens[key] else { continue }
            for mode in ThemeGenerator.modes {
                guard let value = entry[mode] else { continue }
                if key.hasPrefix("type."), case .object(let patch) = value, case .object(var recipe) = token[mode] {
                    for (field, v) in patch { recipe[field] = v }
                    token[mode] = .object(recipe)
                } else {
                    token[mode] = value
                }
            }
            doc.tokens[key] = token
        }
    }

    /// Recipes name their family directly; a changed shared family follows
    /// into every recipe that used the old one.
    private static func retargetRecipeFamilies(in doc: inout DesignWorkingDocument, from old: String?, token: String) {
        guard let old else { return }
        for mode in ThemeGenerator.modes {
            guard let new = doc.tokens[token]?[mode].designString, new != old else { continue }
            for (key, value) in doc.tokens where key.hasPrefix("type.") {
                guard case .object(var recipe) = value[mode], recipe["family"]?.designString == old else { continue }
                recipe["family"] = .string(new)
                doc.tokens[key]?[mode] = .object(recipe)
            }
        }
    }

    // MARK: - Contrast report

    static let textRoles = ["color.text.primary", "color.text.secondary", "color.text.tertiary", "color.text.link"]
    static let surfaceRoles = [
        "color.surface.canvas", "color.surface.raised", "color.surface.subtle", "color.surface.sidebar",
        "color.surface.overlay",
    ]

    /// Every text/surface and control/surface pair below its target.
    static func contrastReport(_ doc: DesignWorkingDocument, high: Bool, modes: [String] = ThemeGenerator.modes) -> [ThemeContrastFinding] {
        let text = high ? ThemeGenerator.Targets.high.text : ThemeGenerator.Targets.standard.text
        let nonText = high ? ThemeGenerator.Targets.high.nonText : ThemeGenerator.Targets.standard.nonText
        var pairs: [(String, String, Double)] = []
        for fg in textRoles { for bg in surfaceRoles { pairs.append((fg, bg, text)) } }
        pairs += [
            ("color.text.primary", "color.chat.user.background", text),
            ("color.text.primary", "color.chat.assistant.background", text),
            ("color.action.primary.default.foreground", "color.action.primary.default.background", 4.5),
            ("color.action.primary.hover.foreground", "color.action.primary.hover.background", 4.5),
            ("color.action.brand.default.foreground", "color.action.brand.default.background", 4.5),
            ("color.action.secondary.default.foreground", "color.action.secondary.default.background", text),
            ("color.border.focus", "color.surface.canvas", 3),
            ("color.border.control", "color.surface.canvas", nonText),
        ]
        var findings: [ThemeContrastFinding] = []
        for mode in modes {
            func rgb(_ role: String) -> ThemeRGB? {
                doc.tokens[role]?[mode].designString.flatMap(ThemeColorMath.rgb(hex:))
            }
            let canvas = rgb("color.surface.canvas") ?? ThemeRGB(r: 1, g: 1, b: 1)
            for (fg, bg, required) in pairs {
                guard let f = rgb(fg), let b = rgb(bg) else { continue }
                let ratio = ThemeColorMath.contrast(f, b, backdrop: canvas)
                if ratio + 0.005 < required {
                    findings.append(ThemeContrastFinding(mode: mode, foreground: fg, background: bg, ratio: ratio, required: required))
                }
            }
        }
        return findings
    }

    // MARK: - Cache

    private struct CacheKey: Hashable {
        let document: ThemeDocument
        let highContrast: Bool
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [CacheKey: ThemeCompiledTheme] = [:]
    private static let cacheLimit = 12

    /// Compiles once per (document, contrast); drafts and saved themes share
    /// the cache, which keeps the most recent entries.
    static func cached(_ document: ThemeDocument, highContrast: Bool) throws -> ThemeCompiledTheme {
        let key = CacheKey(document: document, highContrast: highContrast)
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let compiled = try compile(document, highContrast: highContrast)
        lock.lock()
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = compiled
        lock.unlock()
        return compiled
    }

    /// Compiles off the calling actor.
    static func compileDetached(_ document: ThemeDocument, highContrast: Bool) async throws -> ThemeCompiledTheme {
        try await Task.detached(priority: .userInitiated) {
            try cached(document, highContrast: highContrast)
        }.value
    }
}
