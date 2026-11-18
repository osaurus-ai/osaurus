//
//  ThemeLibraryStoreTests.swift
//  osaurus
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite("Theme library store")
struct ThemeLibraryStoreTests {
    private let directory: URL
    private let store: ThemeLibraryStore

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-store-\(UUID().uuidString)", isDirectory: true)
        store = ThemeLibraryStore(directory: directory, trashesDeletedThemes: false)
    }

    @Test func listsPresetsFirstThenSavedThemes() throws {
        #expect(store.all == ThemePresets.all)
        let saved = try store.save(ThemeDocument(name: "Mine"))
        #expect(store.all.map(\.id) == ThemePresets.all.map(\.id) + [saved.id])
        #expect(FileManager.default.fileExists(atPath: store.fileURL(for: saved.id).path))
    }

    @Test func savedThemesSurviveANewStore() throws {
        let saved = try store.save(ThemeDocument(name: "Persisted", preferences: ThemePreferences(tone: .cool)))
        let reopened = ThemeLibraryStore(directory: directory, trashesDeletedThemes: false)
        #expect(reopened.document(id: saved.id)?.preferences.tone == .cool)
    }

    @Test func presetsAreReadOnly() {
        #expect(throws: ThemeLibraryError.self) { try store.save(ThemePresets.nord) }
        #expect(throws: ThemeLibraryError.self) { try store.delete(id: ThemePresets.nordID) }
    }

    @Test func nilAndUnknownIdsResolve() {
        #expect(store.document(id: nil) == ThemePresets.osaurus)
        #expect(store.document(id: UUID()) == nil)
    }

    @Test func duplicateMakesAnEditableUniquelyNamedCopy() throws {
        let first = try store.duplicate(id: ThemePresets.nordID)
        let second = try store.duplicate(id: ThemePresets.nordID)
        #expect(!store.isPreset(first.id))
        #expect(first.preferences == ThemePresets.nord.preferences)
        #expect(first.name != second.name)
        #expect(Set(store.all.map(\.name)).count == store.all.count)
    }

    @Test func saveClampsOverrides() throws {
        var document = ThemeDocument(name: "Big")
        document.overrides = ThemeOverrides(tokens: ["type.chatBody": .both(.object(["size": .number(80)]))])
        let saved = try store.save(document)
        #expect(saved.overrides?.tokens["type.chatBody"]?.light?.designObject?["size"]?.designNumber == 32)
    }

    @Test func saveRejectsInvalidOverrides() {
        var document = ThemeDocument(name: "Bad")
        document.overrides = ThemeOverrides(tokens: ["color.text.link": .both(.string("nope"))])
        #expect(throws: ThemeLibraryError.self) { try store.save(document) }
        #expect(store.themes.isEmpty)
    }

    @Test func deleteRemovesTheFile() throws {
        let saved = try store.save(ThemeDocument(name: "Gone"))
        try store.delete(id: saved.id)
        #expect(store.themes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: saved.id).path))
    }

    @Test func importGivesConflictingIdsANewOne() throws {
        let original = try store.save(ThemeDocument(name: "Shared"))
        let imported = try store.importJSON(ThemeDocumentCodec.encodeString(original))
        #expect(imported.id != original.id)
        #expect(imported.name != original.name)
        let presetCopy = try store.importJSON(ThemeDocumentCodec.encodeString(ThemePresets.paper))
        #expect(!store.isPreset(presetCopy.id))
    }

    @Test func importRejectsInvalidJSON() {
        #expect(throws: ThemeLibraryError.self) { try store.importJSON("{ \"name\": ") }
    }

    @Test func updateJSONSavesOnlyWithoutErrors() throws {
        let saved = try store.save(ThemeDocument(name: "Edit Me"))
        var edited = saved
        edited.preferences.accent = .swatch(.rose)
        let ok = store.updateJSON(id: saved.id, text: ThemeDocumentCodec.encodeString(edited))
        #expect(!ok.hasErrors)
        #expect(store.document(id: saved.id)?.preferences.accent == .swatch(.rose))

        let bad = store.updateJSON(id: saved.id, text: "{ \"colour\": 1 }")
        #expect(bad.hasErrors)
        #expect(store.document(id: saved.id)?.preferences.accent == .swatch(.rose))
    }

    @Test func exportWritesADecodableFile() throws {
        let url = directory.appendingPathComponent("export.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try store.export(id: ThemePresets.terminalID, to: url)
        let decoded = try ThemeDocumentCodec.decoder().decode(ThemeDocument.self, from: Data(contentsOf: url))
        #expect(decoded == ThemePresets.terminal)
    }

    @Test func externalEditsAppearOnReload() throws {
        let saved = try store.save(ThemeDocument(name: "Outside"))
        var edited = saved
        edited.name = "Edited Elsewhere"
        try ThemeDocumentCodec.encode(edited).write(to: store.fileURL(for: saved.id))
        store.reload()
        #expect(store.document(id: saved.id)?.name == "Edited Elsewhere")
    }
}
