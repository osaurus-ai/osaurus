//
//  ThemeJSONEditorCodecTests.swift
//  osaurusTests
//
//  Focused coverage for the raw JSON theme editor codec.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Theme JSON editor codec")
struct ThemeJSONEditorCodecTests {
    @Test("encodes pretty sorted JSON and round trips")
    func encodeRoundTripsTheme() throws {
        var theme = CustomTheme.darkDefault
        theme.metadata.name = "Raw JSON Theme"
        theme.metadata.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        theme.metadata.updatedAt = Date(timeIntervalSince1970: 1_700_000_001)
        theme.colors.buttonBackground = "#123456"

        let json = try ThemeJSONEditorCodec.encode(theme)
        let decoded = try ThemeJSONEditorCodec.decode(json)

        #expect(json.contains("\n"))
        #expect(json.contains("\"buttonBackground\" : \"#123456\""))
        #expect(decoded == theme)
    }

    @Test("rejects empty and malformed JSON")
    func rejectsInvalidJSON() {
        #expect(throws: ThemeJSONEditorError.empty) {
            _ = try ThemeJSONEditorCodec.decode("   \n")
        }

        #expect(throws: ThemeJSONEditorError.self) {
            _ = try ThemeJSONEditorCodec.decode(#"{"metadata": true}"#)
        }
    }

    @Test("preserves editor identity fields when applying raw JSON")
    func preservingEditorIdentityKeepsSaveTargetStable() throws {
        var current = CustomTheme.darkDefault
        current.metadata.name = "Current"
        current.isBuiltIn = true

        var pasted = CustomTheme.lightDefault
        pasted.metadata.name = "Pasted"
        pasted.metadata.id = UUID()
        pasted.metadata.createdAt = Date(timeIntervalSince1970: 0)
        pasted.isBuiltIn = false
        pasted.colors.accentColor = "#abcdef"

        let applied = try ThemeJSONEditorCodec.decodePreservingEditorIdentity(
            ThemeJSONEditorCodec.encode(pasted),
            currentTheme: current
        )

        #expect(applied.metadata.id == current.metadata.id)
        #expect(applied.metadata.createdAt == current.metadata.createdAt)
        #expect(applied.isBuiltIn == current.isBuiltIn)
        #expect(applied.metadata.name == "Pasted")
        #expect(applied.colors.accentColor == "#abcdef")
    }

    @Test("editor encoding replaces background image payload with a placeholder")
    func editorEncodingRedactsImageData() throws {
        var theme = CustomTheme.darkDefault
        theme.background.type = .image
        theme.background.imageData = String(repeating: "A", count: 100_000)

        let json = try ThemeJSONEditorCodec.encodeForEditor(theme)

        #expect(!json.contains(String(repeating: "A", count: 100)))
        #expect(json.contains(ThemeJSONEditorCodec.imageDataPlaceholderPrefix))
        #expect(json.utf8.count < 10_000)
    }

    @Test("editor encoding leaves themes without an image untouched")
    func editorEncodingWithoutImageMatchesPlainEncoding() throws {
        var theme = CustomTheme.darkDefault
        theme.background.imageData = nil

        #expect(try ThemeJSONEditorCodec.encodeForEditor(theme) == ThemeJSONEditorCodec.encode(theme))
    }

    @Test("applying JSON with an untouched placeholder restores the real image")
    func applyingPlaceholderRestoresImageData() throws {
        var current = CustomTheme.darkDefault
        current.background.type = .image
        current.background.imageData = String(repeating: "B", count: 50_000)

        var edited = try ThemeJSONEditorCodec.decodePreservingEditorIdentity(
            ThemeJSONEditorCodec.encodeForEditor(current),
            currentTheme: current
        )
        #expect(edited.background.imageData == current.background.imageData)

        // A hand-replaced payload wins over the splice-back.
        var pasted = current
        pasted.background.imageData = "cGFzdGVk"
        edited = try ThemeJSONEditorCodec.decodePreservingEditorIdentity(
            ThemeJSONEditorCodec.encode(pasted),
            currentTheme: current
        )
        #expect(edited.background.imageData == "cGFzdGVk")
    }
}
