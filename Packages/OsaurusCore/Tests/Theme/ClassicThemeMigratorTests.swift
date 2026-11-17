//
//  ClassicThemeMigratorTests.swift
//  osaurus
//
//  Classic users who leaned on custom themes (often for larger text) must
//  keep their look after upgrading.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Classic theme migration")
struct ClassicThemeMigratorTests {
    private static let userID = UUID(uuidString: "7D3B1E2A-0C4F-4A57-9B1D-3E6F2A8C9D01")!
    private static let lightUserID = UUID(uuidString: "7D3B1E2A-0C4F-4A57-9B1D-3E6F2A8C9D02")!
    private static let classicNordID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    private static let classicDarkID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// A Classic user theme: cool dark background, the violet swatch's own
    /// dark accent, bigger body text, Atkinson font, square-ish cards, no avatars.
    private static func userTheme(id: UUID = userID, isDark: Bool = true) -> String {
        let violet = ThemeGenerator.previewAccent(.swatch(.violet), tone: .cool).dark
        return """
        {
          "metadata": { "id": "\(id.uuidString)", "name": "Big Text", "author": "Classic User", "version": "1.0" },
          "isBuiltIn": false,
          "isDark": \(isDark),
          "colors": { "primaryBackground": "\(isDark ? "#1B2330" : "#F6F1E6")", "accentColor": "\(violet)" },
          "typography": { "primaryFont": "Atkinson Hyperlegible", "monoFont": "SF Mono", "bodySize": 18, "captionSize": 12 },
          "borders": { "cardCornerRadius": 6, "defaultWidth": 1 },
          "messages": { "showInlineAvatar": false, "showAgentName": true },
          "codeHighlightTheme": "github-dark"
        }
        """
    }

    private static func builtInTheme(id: UUID) -> String {
        #"{ "metadata": { "id": "\#(id.uuidString)", "name": "Built-in" }, "isBuiltIn": true, "isDark": true }"#
    }

    private func makeDirectories() throws -> (legacy: URL, library: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("classic-\(UUID().uuidString)")
        let legacy = root.appendingPathComponent("Themes", isDirectory: true)
        let library = root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        return (legacy, library)
    }

    private func write(_ json: String, id: UUID, in directory: URL) throws {
        try Data(json.utf8).write(to: directory.appendingPathComponent("\(id.uuidString).json"))
    }

    @Test func convertsAUserThemeKeepingItsLook() throws {
        let classic = try #require(ClassicThemeMigrator.decode(Data(Self.userTheme().utf8)))
        let document = try #require(ClassicThemeMigrator.convert(classic))
        #expect(document.id == Self.userID)
        #expect(document.name == "Big Text")
        #expect(document.author == "Classic User")
        #expect(document.appearance == .dark)
        #expect(document.preferences.tone == .cool)
        #expect(document.preferences.accent == .swatch(.violet))
        #expect(document.preferences.corners == .subtle)
        #expect(document.preferences.readability.uiFont == "Atkinson Hyperlegible")
        #expect(document.preferences.readability.codeFont == ThemeReadability.systemFont)
        #expect(document.codeHighlightTheme == "github-dark")
        #expect(document.messages?.showInlineAvatar == false)

        let tokens = try #require(document.overrides?.tokens)
        #expect(tokens["type.chatBody"]?.light?.designObject?["size"]?.designNumber == 18)
        #expect(tokens["type.body"] != nil)
        // Unchanged Classic defaults don't become overrides.
        #expect(tokens["type.caption"] == nil)
        #expect(tokens["stroke.default"] == nil)
    }

    @Test func convertedThemesCompileWithoutContrastFindings() throws {
        for isDark in [true, false] {
            let classic = try #require(ClassicThemeMigrator.decode(Data(Self.userTheme(isDark: isDark).utf8)))
            let document = try #require(ClassicThemeMigrator.convert(classic))
            let compiled = try ThemeCompiler.compile(document, highContrast: false)
            #expect(compiled.contrastFindings.isEmpty, "\(compiled.contrastFindings.map(\.message))")
        }
    }

    @Test func offPaletteAccentsKeepTheirColor() {
        #expect(ClassicThemeMigrator.nearestAccent("#FF00FF", tone: .neutral, isDark: true) == .custom("#FF00FF"))
        #expect(ClassicThemeMigrator.nearestAccent("#7348D6", tone: .cool, isDark: true) == .custom("#7348D6"))
    }

    @Test func toneFollowsTheBackground() {
        #expect(ClassicThemeMigrator.nearestTone(background: "#808080") == .neutral)
        #expect(ClassicThemeMigrator.nearestTone(background: "#F6F1E6") == .warm)
        #expect(ClassicThemeMigrator.nearestTone(background: "#1B2330") == .cool)
        #expect(ClassicThemeMigrator.nearestTone(background: nil) == .warm)
    }

    @Test func builtInsAreSkippedAndMapToPresets() throws {
        let (legacy, library) = try makeDirectories()
        try write(Self.builtInTheme(id: Self.classicNordID), id: Self.classicNordID, in: legacy)
        try write(Self.builtInTheme(id: Self.classicDarkID), id: Self.classicDarkID, in: legacy)

        let nord = ClassicThemeMigrator.migrate(legacyDirectory: legacy, libraryDirectory: library, activeID: Self.classicNordID)
        #expect(nord.converted.isEmpty)
        #expect(nord.activation == .theme(ThemePresets.nordID))

        let dark = ClassicThemeMigrator.migrate(legacyDirectory: legacy, libraryDirectory: library, activeID: Self.classicDarkID)
        #expect(dark.activation == .defaultTheme(.dark))
        #expect(ThemeLibraryFiles.list(in: library).isEmpty)
    }

    @Test func activeUserThemeConvertsAndActivates() throws {
        let (legacy, library) = try makeDirectories()
        try write(Self.userTheme(), id: Self.userID, in: legacy)
        try write(Self.userTheme(id: Self.lightUserID, isDark: false), id: Self.lightUserID, in: legacy)

        let first = ClassicThemeMigrator.migrate(
            legacyDirectory: legacy, libraryDirectory: library, activeID: Self.userID, only: Self.userID
        )
        #expect(first.converted == [Self.userID])
        #expect(first.activation == .theme(Self.userID))
        #expect(ThemeLibraryFiles.list(in: library).map(\.id) == [Self.userID])

        let rest = ClassicThemeMigrator.migrate(legacyDirectory: legacy, libraryDirectory: library, activeID: nil)
        #expect(rest.converted == [Self.lightUserID])
        #expect(Set(ThemeLibraryFiles.list(in: library).map(\.id)) == [Self.userID, Self.lightUserID])
    }

    @Test func migrationIsIdempotent() throws {
        let (legacy, library) = try makeDirectories()
        try write(Self.userTheme(), id: Self.userID, in: legacy)
        _ = ClassicThemeMigrator.migrate(legacyDirectory: legacy, libraryDirectory: library, activeID: nil)

        var edited = try #require(ThemeLibraryFiles.list(in: library).first)
        edited.name = "Renamed After Upgrade"
        try ThemeLibraryFiles.write(edited, in: library)

        let again = ClassicThemeMigrator.migrate(legacyDirectory: legacy, libraryDirectory: library, activeID: Self.userID)
        #expect(again.converted.isEmpty)
        #expect(again.activation == .theme(Self.userID))
        #expect(ThemeLibraryFiles.list(in: library).first?.name == "Renamed After Upgrade")
        #expect(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("\(Self.userID.uuidString).json").path))
    }

    @Test func completionIsRecordedInTheLibraryItDescribes() throws {
        let (_, library) = try makeDirectories()
        let other = library.deletingLastPathComponent().appendingPathComponent("other-root", isDirectory: true)
        #expect(!ClassicThemeMigrator.isCompleted(libraryDirectory: library))
        ClassicThemeMigrator.markCompleted(libraryDirectory: library)
        #expect(ClassicThemeMigrator.isCompleted(libraryDirectory: library))
        #expect(!ClassicThemeMigrator.isCompleted(libraryDirectory: other))
        #expect(ThemeLibraryFiles.list(in: library).isEmpty)
    }

    @Test func unreadableFilesAreIgnored() throws {
        let (legacy, library) = try makeDirectories()
        try Data("not json".utf8).write(to: legacy.appendingPathComponent("\(UUID().uuidString).json"))
        try Data("{}".utf8).write(to: legacy.appendingPathComponent("notes.json"))
        let result = ClassicThemeMigrator.migrate(legacyDirectory: legacy, libraryDirectory: library, activeID: nil)
        #expect(result.converted.isEmpty)
    }
}
