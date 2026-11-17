//
//  ClassicThemeMigrator.swift
//  osaurus
//
//  Converts Osaurus Classic themes (`themes/<uuid>.json`) into theme
//  documents. The user's accent, light/dark choice, tone, fonts and text
//  sizes are kept; raw palette colors map to the closest tasteful
//  preferences instead of being copied. Classic files are never modified,
//  and each theme keeps its UUID so re-runs never duplicate.
//

import Foundation

enum ClassicThemeMigrator {
    /// Written into the library once every Classic theme has converted, so
    /// a conversion the user deletes is not recreated. It lives with the
    /// data it describes because every Osaurus data root shares one set of
    /// UserDefaults.
    static let completedMarker = ".classic-migration-1"

    static func isCompleted(libraryDirectory: URL) -> Bool {
        FileManager.default.fileExists(atPath: libraryDirectory.appendingPathComponent(completedMarker).path)
    }

    static func markCompleted(libraryDirectory: URL) {
        try? FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: libraryDirectory.appendingPathComponent(completedMarker).path, contents: Data())
    }

    /// Classic's built-in ids.
    static let classicDarkID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let classicLightID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let classicNeonID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    static let classicNordID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    static let classicPaperID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
    static let classicTerminalID = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
    static let classicOsaurusDarkID = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
    static let classicOsaurusLightID = UUID(uuidString: "00000000-0000-0000-0000-000000000008")!

    /// What a Classic active theme becomes.
    enum Activation: Equatable {
        /// Keep the default theme; optionally pin the appearance.
        case defaultTheme(AppearanceMode?)
        case theme(UUID)
    }

    /// The activation for a Classic built-in, or nil for a user theme.
    static func builtInActivation(_ id: UUID) -> Activation? {
        switch id {
        case classicDarkID, classicOsaurusDarkID, classicNeonID: return .defaultTheme(.dark)
        case classicLightID, classicOsaurusLightID: return .defaultTheme(.light)
        case classicNordID: return .theme(ThemePresets.nordID)
        case classicPaperID: return .theme(ThemePresets.paperID)
        case classicTerminalID: return .theme(ThemePresets.terminalID)
        default: return nil
        }
    }

    // MARK: - Classic schema (minimal mirror)

    struct ClassicTheme: Decodable {
        struct Metadata: Decodable {
            var id: UUID
            var name: String?
            var author: String?
        }
        struct Colors: Decodable {
            var primaryBackground: String?
            var accentColor: String?
        }
        struct Typography: Decodable {
            var primaryFont: String?
            var monoFont: String?
            var titleSize: Double?
            var headingSize: Double?
            var bodySize: Double?
            var smallBodySize: Double?
            var captionSize: Double?
            var codeSize: Double?
        }
        struct Animation: Decodable {
            var durationQuick: Double?
            var durationMedium: Double?
            var durationSlow: Double?
            var springResponse: Double?
            var springDamping: Double?
        }
        struct Messages: Decodable {
            var bubbleCornerRadius: Double?
            var showInlineAvatar: Bool?
            var inlineAvatarSize: Double?
            var showAgentName: Bool?
        }
        struct Borders: Decodable {
            var defaultWidth: Double?
            var cardCornerRadius: Double?
        }

        var metadata: Metadata
        var colors: Colors?
        var typography: Typography?
        var animationConfig: Animation?
        var messages: Messages?
        var borders: Borders?
        var codeHighlightTheme: String?
        var isBuiltIn: Bool?
        var isDark: Bool?
    }

    /// Classic's own defaults; only values a user changed carry over as overrides.
    private enum ClassicDefault {
        static let title = 28.0, heading = 18.0, body = 14.0, smallBody = 14.0, caption = 12.0, code = 13.0
        static let quick = 0.2, medium = 0.3, slow = 0.4, springResponse = 0.4, springDamping = 0.8
        static let strokeWidth = 1.0, avatar = 24.0
    }

    // MARK: - Convert

    static func decode(_ data: Data) -> ClassicTheme? {
        try? JSONDecoder().decode(ClassicTheme.self, from: data)
    }

    /// The theme document for a Classic user theme; nil for built-ins.
    static func convert(_ classic: ClassicTheme, now: Date = Date()) -> ThemeDocument? {
        guard classic.isBuiltIn != true, builtInActivation(classic.metadata.id) == nil else { return nil }
        let isDark = classic.isDark ?? true
        let tone = nearestTone(background: classic.colors?.primaryBackground)
        var preferences = ThemePreferences(
            accent: nearestAccent(classic.colors?.accentColor, tone: tone, isDark: isDark),
            tone: tone
        )
        if let card = classic.borders?.cardCornerRadius, card <= 8 { preferences.corners = .subtle }
        if let font = classic.typography?.primaryFont, !isSystemFont(font, system: "sf pro") {
            preferences.readability.uiFont = font
        }
        if let font = classic.typography?.monoFont, !isSystemFont(font, system: "sf mono") {
            preferences.readability.codeFont = font
        }
        let overrides = readabilityOverrides(classic)
        let base = ThemeCompiler.library
        let (clean, _) = ThemeTokenPolicy.sanitize(overrides, base: base)

        var messages: ThemeMessagePreferences?
        if let m = classic.messages, m.showInlineAvatar == false || m.showAgentName == false {
            messages = ThemeMessagePreferences(
                showInlineAvatar: m.showInlineAvatar ?? true, showAgentName: m.showAgentName ?? true
            )
        }
        let name = classic.metadata.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ThemeDocument(
            id: classic.metadata.id,
            name: (name?.isEmpty == false ? name! : L("Classic Theme")),
            author: classic.metadata.author ?? "",
            createdAt: now,
            updatedAt: now,
            appearance: isDark ? .dark : .light,
            preferences: preferences,
            overrides: clean.isEmpty ? nil : clean,
            codeHighlightTheme: classic.codeHighlightTheme,
            messages: messages
        )
    }

    private static func isSystemFont(_ name: String, system: String) -> Bool {
        let lower = name.trimmingCharacters(in: .whitespaces).lowercased()
        return lower.isEmpty || lower == "system" || lower == "systemmonospaced" || lower.contains(system)
    }

    /// Text sizes, stroke, avatar and motion the user changed, as overrides.
    /// Each Classic size sets its 1.0 counterpart exactly; siblings move by
    /// the same amount so the hierarchy holds.
    static func readabilityOverrides(_ classic: ClassicTheme) -> ThemeOverrides {
        var tokens: [String: ThemeTokenOverride] = [:]
        let base = ThemeCompiler.library
        func size(_ style: String) -> Double? { base.tokens["type.\(style)"]?.light.designObject?["size"]?.designNumber }
        func setSize(_ style: String, _ value: Double) {
            tokens["type.\(style)"] = .both(.object(["size": .number(value)]))
        }
        func carry(_ value: Double?, classicDefault: Double, exact: [String], shifted: [String]) {
            guard let value, value.isFinite, value != classicDefault else { return }
            for style in exact { setSize(style, value) }
            let delta = value - classicDefault
            for style in shifted { if let s = size(style) { setSize(style, s + delta) } }
        }
        let t = classic.typography
        carry(t?.titleSize, classicDefault: ClassicDefault.title, exact: ["title"], shifted: ["display"])
        carry(t?.headingSize, classicDefault: ClassicDefault.heading, exact: ["heading"], shifted: ["subheading", "lead"])
        carry(t?.bodySize, classicDefault: ClassicDefault.body, exact: ["chatBody"], shifted: ["body", "bodyEmphasis"])
        carry(t?.smallBodySize, classicDefault: ClassicDefault.smallBody, exact: [], shifted: ["bodySmall"])
        carry(t?.captionSize, classicDefault: ClassicDefault.caption, exact: ["caption"], shifted: ["footnote", "micro"])
        carry(t?.codeSize, classicDefault: ClassicDefault.code, exact: ["code"], shifted: [])

        if let width = classic.borders?.defaultWidth, width != ClassicDefault.strokeWidth {
            tokens["stroke.default"] = .both(.number(width))
        }
        if let avatar = classic.messages?.inlineAvatarSize, avatar != ClassicDefault.avatar {
            tokens["size.chat.avatar"] = .both(.number(avatar))
        }
        let a = classic.animationConfig
        if let v = a?.durationQuick, v != ClassicDefault.quick { tokens["motion.duration.quick"] = .both(.number(v)) }
        if let v = a?.durationMedium, v != ClassicDefault.medium { tokens["motion.duration.standard"] = .both(.number(v)) }
        if let v = a?.durationSlow, v != ClassicDefault.slow { tokens["motion.duration.slow"] = .both(.number(v)) }
        var spring: [String: JSONValue] = [:]
        if let v = a?.springResponse, v != ClassicDefault.springResponse { spring["response"] = .number(v) }
        if let v = a?.springDamping, v != ClassicDefault.springDamping { spring["dampingFraction"] = .number(v) }
        if !spring.isEmpty { tokens["motion.spring"] = .both(.object(spring)) }
        return ThemeOverrides(tokens: tokens)
    }

    /// Warm and cool by background hue; low-chroma backgrounds are neutral.
    static func nearestTone(background: String?) -> ThemeTone {
        guard let hex = background, let rgb = ThemeColorMath.rgb(hex: hex) else { return .warm }
        let c = ThemeColorMath.oklch(rgb)
        if c.c < 0.012 { return .neutral }
        switch c.h {
        case 20 ..< 120: return .warm
        case 180 ..< 300: return .cool
        default: return .neutral
        }
    }

    /// The nearest swatch within ΔE 6 of the accent in its own mode, else a
    /// custom accent the generator will tame.
    static func nearestAccent(_ accent: String?, tone: ThemeTone, isDark: Bool) -> ThemeAccentChoice {
        guard let hex = accent, let rgb = ThemeColorMath.rgb(hex: hex) else { return .swatch(.teal) }
        var best: (ThemeAccentSwatch, Double)?
        for swatch in ThemeAccentSwatch.allCases {
            let preview = ThemeGenerator.previewAccent(.swatch(swatch), tone: tone)
            let candidates = [isDark ? preview.dark : preview.light, isDark ? preview.light : preview.dark]
            for candidate in candidates {
                guard let c = ThemeColorMath.rgb(hex: candidate) else { continue }
                let d = ThemeColorMath.deltaE(rgb, c)
                if d < (best?.1 ?? .infinity) { best = (swatch, d) }
            }
        }
        if let best, best.1 <= 6 { return .swatch(best.0) }
        let opaque = ThemeRGB(r: rgb.r, g: rgb.g, b: rgb.b)
        return .custom(String(ThemeColorMath.hex(opaque).prefix(7)))
    }

    // MARK: - Run

    struct Result: Equatable {
        var converted: [UUID] = []
        var activation: Activation?
    }

    /// Converts every Classic user theme in `legacyDirectory` into
    /// `libraryDirectory`, skipping ones already converted. When
    /// `activeID` is set (a direct Classic upgrade), reports what to activate.
    /// `only` limits the pass to one theme, so the active one can convert
    /// at launch while the rest (which may hold large images) wait.
    static func migrate(legacyDirectory: URL, libraryDirectory: URL, activeID: UUID?, only: UUID? = nil) -> Result {
        var result = Result()
        if let activeID { result.activation = builtInActivation(activeID) }
        let urls = (try? FileManager.default.contentsOfDirectory(at: legacyDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "json" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            if let only, id != only { continue }
            let target = ThemeLibraryFiles.url(for: id, in: libraryDirectory)
            let alreadyConverted = FileManager.default.fileExists(atPath: target.path)
            if !alreadyConverted {
                guard let data = try? Data(contentsOf: url), let classic = decode(data),
                    let document = convert(classic)
                else { continue }
                do {
                    try ThemeLibraryFiles.write(document, in: libraryDirectory)
                    result.converted.append(document.id)
                } catch {
                    continue
                }
            }
            if id == activeID, result.activation == nil { result.activation = .theme(id) }
        }
        return result
    }
}
