//
//  ThemeDocument.swift
//  osaurus
//
//  A custom theme as the user edits it: a few preferences that
//  `ThemeGenerator` turns into a complete, contrast-safe token set, plus
//  optional expert overrides validated by `ThemeTokenPolicy`. This is the
//  JSON stored under `themes/library/<uuid>.json` and documented in
//  docs/THEMES.md.
//

import Foundation

// MARK: - Preferences

/// The neutral ramp every surface, text and border role draws from.
public enum ThemeTone: String, Codable, Sendable, CaseIterable, Identifiable {
    /// The brand cream ramp.
    case warm
    /// The Graphite ramp: the monochrome look 1.0 shipped with.
    case neutral
    /// A slate ramp on the same lightness steps.
    case cool

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .warm: return L("Warm")
        case .neutral: return L("Neutral")
        case .cool: return L("Cool")
        }
    }
}

/// Curated accent pairs: a primary for actions, links and focus, and a
/// highlight for brand buttons and badges. Each is tuned per mode.
public enum ThemeAccentSwatch: String, Codable, Sendable, CaseIterable, Identifiable {
    case teal
    case blue
    case violet
    case rose
    case amber
    case green
    case graphite

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .teal: return L("Teal")
        case .blue: return L("Blue")
        case .violet: return L("Violet")
        case .rose: return L("Rose")
        case .amber: return L("Amber")
        case .green: return L("Green")
        case .graphite: return L("Graphite")
        }
    }
}

/// `{ "swatch": "teal" }` or `{ "custom": "#3A7BD5" }`.
public enum ThemeAccentChoice: Codable, Equatable, Hashable, Sendable {
    case swatch(ThemeAccentSwatch)
    /// A user color. Its hue is kept; chroma and lightness are adjusted per
    /// mode so the result stays tasteful and readable.
    case custom(String)

    private enum CodingKeys: String, CodingKey { case swatch, custom }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let swatch = try c.decodeIfPresent(ThemeAccentSwatch.self, forKey: .swatch) {
            self = .swatch(swatch)
        } else if let hex = try c.decodeIfPresent(String.self, forKey: .custom) {
            guard ThemeColorMath.rgb(hex: hex) != nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .custom, in: c, debugDescription: "custom accent must be a #RRGGBB color"
                )
            }
            self = .custom(hex)
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: c.codingPath, debugDescription: "accent needs \"swatch\" or \"custom\"")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .swatch(let swatch): try c.encode(swatch, forKey: .swatch)
        case .custom(let hex): try c.encode(hex, forKey: .custom)
        }
    }
}

public enum ThemeContrastLevel: String, Codable, Sendable, CaseIterable, Identifiable {
    case standard
    /// Stronger text and borders, thicker outlines and an opaque window.
    /// Also forced on while macOS Increase Contrast is on.
    case high

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .standard: return L("Standard")
        case .high: return L("High")
        }
    }
}

public enum ThemeCorners: String, Codable, Sendable, CaseIterable, Identifiable {
    case rounded
    case subtle

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .rounded: return L("Rounded")
        case .subtle: return L("Subtle")
        }
    }
}

/// Which modes the theme supports. A single-mode theme overrides the
/// app's Appearance setting while it is active.
public enum ThemeAppearance: String, Codable, Sendable, CaseIterable, Identifiable {
    case both
    case light
    case dark

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .both: return L("Both")
        case .light: return L("Light")
        case .dark: return L("Dark")
        }
    }
}

public enum ThemeReadingSize: String, Codable, Sendable, CaseIterable, Identifiable {
    case `default`
    /// +2 pt to body, chat and code.
    case large
    /// +4 pt to body, chat and code.
    case larger

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .default: return L("Default")
        case .large: return L("Large")
        case .larger: return L("Larger")
        }
    }
}

public enum ThemeLineSpacing: String, Codable, Sendable, CaseIterable, Identifiable {
    case `default`
    /// Line heights ×1.15.
    case relaxed

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .default: return L("Default")
        case .relaxed: return L("Relaxed")
        }
    }
}

public struct ThemeReadability: Codable, Equatable, Hashable, Sendable {
    /// `"system"` or an installed family name.
    public var uiFont: String
    /// `"system"` or an installed monospaced family name.
    public var codeFont: String
    public var readingSize: ThemeReadingSize
    public var lineSpacing: ThemeLineSpacing
    public var strongerOutlines: Bool
    public var largerControls: Bool

    public static let systemFont = "system"

    public init(
        uiFont: String = ThemeReadability.systemFont,
        codeFont: String = ThemeReadability.systemFont,
        readingSize: ThemeReadingSize = .default,
        lineSpacing: ThemeLineSpacing = .default,
        strongerOutlines: Bool = false,
        largerControls: Bool = false
    ) {
        self.uiFont = uiFont
        self.codeFont = codeFont
        self.readingSize = readingSize
        self.lineSpacing = lineSpacing
        self.strongerOutlines = strongerOutlines
        self.largerControls = largerControls
    }

    private enum CodingKeys: String, CodingKey {
        case uiFont, codeFont, readingSize, lineSpacing, strongerOutlines, largerControls
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uiFont = try c.decodeIfPresent(String.self, forKey: .uiFont) ?? Self.systemFont
        codeFont = try c.decodeIfPresent(String.self, forKey: .codeFont) ?? Self.systemFont
        readingSize = try c.decodeIfPresent(ThemeReadingSize.self, forKey: .readingSize) ?? .default
        lineSpacing = try c.decodeIfPresent(ThemeLineSpacing.self, forKey: .lineSpacing) ?? .default
        strongerOutlines = try c.decodeIfPresent(Bool.self, forKey: .strongerOutlines) ?? false
        largerControls = try c.decodeIfPresent(Bool.self, forKey: .largerControls) ?? false
    }

    public static var `default`: ThemeReadability { ThemeReadability() }
}

public struct ThemePreferences: Codable, Equatable, Hashable, Sendable {
    public var accent: ThemeAccentChoice
    public var tone: ThemeTone
    public var contrast: ThemeContrastLevel
    public var corners: ThemeCorners
    public var readability: ThemeReadability

    public init(
        accent: ThemeAccentChoice = .swatch(.teal),
        tone: ThemeTone = .warm,
        contrast: ThemeContrastLevel = .standard,
        corners: ThemeCorners = .rounded,
        readability: ThemeReadability = .default
    ) {
        self.accent = accent
        self.tone = tone
        self.contrast = contrast
        self.corners = corners
        self.readability = readability
    }

    private enum CodingKeys: String, CodingKey { case accent, tone, contrast, corners, readability }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accent = try c.decodeIfPresent(ThemeAccentChoice.self, forKey: .accent) ?? .swatch(.teal)
        tone = try c.decodeIfPresent(ThemeTone.self, forKey: .tone) ?? .warm
        contrast = try c.decodeIfPresent(ThemeContrastLevel.self, forKey: .contrast) ?? .standard
        corners = try c.decodeIfPresent(ThemeCorners.self, forKey: .corners) ?? .rounded
        readability = try c.decodeIfPresent(ThemeReadability.self, forKey: .readability) ?? .default
    }

    public static var `default`: ThemePreferences { ThemePreferences() }
}

// MARK: - Overrides

/// One expert token override. A mode left out keeps the generated value.
/// Typography values may be partial recipes (`{ "size": 18 }`).
public struct ThemeTokenOverride: Codable, Equatable, Hashable, Sendable {
    public var light: JSONValue?
    public var dark: JSONValue?

    public init(light: JSONValue? = nil, dark: JSONValue? = nil) {
        self.light = light
        self.dark = dark
    }

    public subscript(_ mode: String) -> JSONValue? {
        get { mode == "dark" ? dark : light }
        set { if mode == "dark" { dark = newValue } else { light = newValue } }
    }

    /// The same value in both modes.
    public static func both(_ value: JSONValue) -> ThemeTokenOverride {
        ThemeTokenOverride(light: value, dark: value)
    }
}

public struct ThemeOverrides: Codable, Equatable, Hashable, Sendable {
    public var tokens: [String: ThemeTokenOverride]

    public init(tokens: [String: ThemeTokenOverride] = [:]) {
        self.tokens = tokens
    }

    public var isEmpty: Bool { tokens.isEmpty }
}

// MARK: - Document

public struct ThemeDocument: Codable, Equatable, Hashable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var author: String
    public var createdAt: Date
    public var updatedAt: Date
    public var appearance: ThemeAppearance
    public var preferences: ThemePreferences
    public var overrides: ThemeOverrides?
    /// Highlightr theme name for code blocks; nil follows the mode.
    public var codeHighlightTheme: String?
    /// Chat avatar and agent-name visibility.
    public var messages: ThemeMessagePreferences?

    public init(
        id: UUID = UUID(),
        name: String,
        author: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        appearance: ThemeAppearance = .both,
        preferences: ThemePreferences = .default,
        overrides: ThemeOverrides? = nil,
        codeHighlightTheme: String? = nil,
        messages: ThemeMessagePreferences? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.name = name
        self.author = author
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.appearance = appearance
        self.preferences = preferences
        self.overrides = overrides
        self.codeHighlightTheme = codeHighlightTheme
        self.messages = messages
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, author, createdAt, updatedAt, appearance, preferences, overrides
        case codeHighlightTheme, messages
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        guard schemaVersion <= Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion, in: c,
                debugDescription: "schemaVersion \(schemaVersion) is newer than this Osaurus supports"
            )
        }
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? L("Untitled Theme")
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        appearance = try c.decodeIfPresent(ThemeAppearance.self, forKey: .appearance) ?? .both
        preferences = try c.decodeIfPresent(ThemePreferences.self, forKey: .preferences) ?? .default
        overrides = try c.decodeIfPresent(ThemeOverrides.self, forKey: .overrides)
        codeHighlightTheme = try c.decodeIfPresent(String.self, forKey: .codeHighlightTheme)
        messages = try c.decodeIfPresent(ThemeMessagePreferences.self, forKey: .messages)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(author, forKey: .author)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(preferences, forKey: .preferences)
        if let overrides, !overrides.isEmpty { try c.encode(overrides, forKey: .overrides) }
        try c.encodeIfPresent(codeHighlightTheme, forKey: .codeHighlightTheme)
        try c.encodeIfPresent(messages, forKey: .messages)
    }

    public var hasOverrides: Bool { !(overrides?.isEmpty ?? true) }

    /// The appearance mode this theme forces, if any.
    public var lockedAppearance: AppearanceMode? {
        switch appearance {
        case .both: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Codec

public enum ThemeDocumentCodec {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encode(_ document: ThemeDocument) throws -> Data {
        try encoder().encode(document)
    }

    public static func encodeString(_ document: ThemeDocument) -> String {
        (try? encode(document)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
