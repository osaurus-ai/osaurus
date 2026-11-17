//
//  ThemePresets.swift
//  osaurus
//
//  Bundled, read-only themes. Each is a preference set run through the same
//  generator as user themes. Osaurus is the default (`activeThemeId == nil`).
//

import Foundation

public enum ThemePresets {
    public static let osaurusID = UUID(uuidString: "6F5A0001-0000-4000-8000-000000000001")!
    public static let graphiteID = UUID(uuidString: "6F5A0001-0000-4000-8000-000000000002")!
    public static let nordID = UUID(uuidString: "6F5A0001-0000-4000-8000-000000000003")!
    public static let paperID = UUID(uuidString: "6F5A0001-0000-4000-8000-000000000004")!
    public static let terminalID = UUID(uuidString: "6F5A0001-0000-4000-8000-000000000005")!

    private static let shipped = Date(timeIntervalSince1970: 1_793_000_000)

    private static func preset(
        _ id: UUID, _ name: String, appearance: ThemeAppearance = .both, preferences: ThemePreferences
    ) -> ThemeDocument {
        ThemeDocument(
            id: id, name: name, author: "Osaurus", createdAt: shipped, updatedAt: shipped,
            appearance: appearance, preferences: preferences
        )
    }

    public static let osaurus = preset(osaurusID, "Osaurus", preferences: .default)

    /// The monochrome look Osaurus 1.0 shipped with.
    public static let graphite = preset(
        graphiteID, "Graphite", preferences: ThemePreferences(accent: .swatch(.graphite), tone: .neutral)
    )

    public static let nord = preset(nordID, "Nord", preferences: ThemePreferences(accent: .swatch(.blue), tone: .cool))

    public static let paper = preset(
        paperID, "Paper", appearance: .light,
        preferences: ThemePreferences(accent: .swatch(.amber), tone: .warm, corners: .subtle, transparency: .solid)
    )

    public static let terminal = preset(
        terminalID, "Terminal", appearance: .dark,
        preferences: ThemePreferences(
            accent: .swatch(.green), tone: .neutral,
            readability: ThemeReadability(uiFont: "SF Mono")
        )
    )

    public static let all: [ThemeDocument] = [osaurus, graphite, nord, paper, terminal]

    public static func preset(id: UUID) -> ThemeDocument? {
        all.first { $0.id == id }
    }

    public static func isPreset(_ id: UUID) -> Bool {
        all.contains { $0.id == id }
    }
}
