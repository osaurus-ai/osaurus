//
//  ThemeDocumentCodecTests.swift
//  osaurus
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Theme document codec")
struct ThemeDocumentCodecTests {
    private func roundTrip(_ document: ThemeDocument) throws -> ThemeDocument {
        try ThemeDocumentCodec.decoder().decode(ThemeDocument.self, from: ThemeDocumentCodec.encode(document))
    }

    @Test func presetsRoundTrip() throws {
        for preset in ThemePresets.all {
            #expect(try roundTrip(preset) == preset)
        }
    }

    @Test func everythingRoundTrips() throws {
        let document = ThemeDocument(
            name: "Everything",
            author: "Tester",
            appearance: .dark,
            preferences: ThemePreferences(
                accent: .custom("#E0457B"),
                tone: .cool,
                contrast: .high,
                corners: .subtle,
                readability: ThemeReadability(
                    uiFont: "Atkinson Hyperlegible", codeFont: "Menlo", readingSize: .larger,
                    lineSpacing: .relaxed, strongerOutlines: true, largerControls: true
                )
            ),
            overrides: ThemeOverrides(tokens: ["color.text.link": ThemeTokenOverride(light: .string("#0B5F8A"))]),
            codeHighlightTheme: "github-dark",
            messages: ThemeMessagePreferences(showInlineAvatar: false, showAgentName: true)
        )
        let decoded = try roundTrip(document)
        #expect(decoded.preferences == document.preferences)
        #expect(decoded.overrides == document.overrides)
        #expect(decoded.codeHighlightTheme == "github-dark")
        #expect(decoded.messages == document.messages)
        #expect(decoded.lockedAppearance == .dark)
    }

    @Test func accentEncodesAsATaggedObject() throws {
        let swatch = String(decoding: try JSONEncoder().encode(ThemeAccentChoice.swatch(.violet)), as: UTF8.self)
        let custom = String(decoding: try JSONEncoder().encode(ThemeAccentChoice.custom("#123456")), as: UTF8.self)
        #expect(swatch == #"{"swatch":"violet"}"#)
        #expect(custom == ##"{"custom":"#123456"}"##)
    }

    @Test func malformedCustomAccentIsRejected() {
        let data = Data(#"{"custom":"not a color"}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ThemeAccentChoice.self, from: data) }
    }

    @Test func readabilityDecodesLeniently() throws {
        let readability = try JSONDecoder().decode(ThemeReadability.self, from: Data(#"{"readingSize":"large"}"#.utf8))
        #expect(readability.readingSize == .large)
        #expect(readability.uiFont == ThemeReadability.systemFont)
        #expect(readability.lineSpacing == .default)
        #expect(!readability.largerControls)
    }

    @Test func newerSchemaVersionFailsToDecode() throws {
        var object = try JSONSerialization.jsonObject(with: ThemeDocumentCodec.encode(ThemePresets.osaurus)) as! [String: Any]
        object["schemaVersion"] = ThemeDocument.currentSchemaVersion + 1
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try ThemeDocumentCodec.decoder().decode(ThemeDocument.self, from: data) }
    }

    @Test func lockedAppearanceFollowsTheDocument() {
        #expect(ThemePresets.osaurus.lockedAppearance == nil)
        #expect(ThemePresets.paper.lockedAppearance == .light)
        #expect(ThemePresets.terminal.lockedAppearance == .dark)
    }

    @Test func presetIdsAreStableAndDistinct() {
        #expect(Set(ThemePresets.all.map(\.id)).count == ThemePresets.all.count)
        #expect(ThemePresets.preset(id: ThemePresets.osaurusID) == ThemePresets.osaurus)
        #expect(ThemePresets.all.allSatisfy { ThemePresets.isPreset($0.id) })
        #expect(!ThemePresets.isPreset(UUID()))
    }
}
