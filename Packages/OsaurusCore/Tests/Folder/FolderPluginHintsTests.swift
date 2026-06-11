//
//  FolderPluginHintsTests.swift
//  osaurus
//
//  Pin the extension→plugin lookup contract behind `FolderPluginHints`.
//  The pure overload is what production code reaches for through
//  `suggestedPluginIds(for:)` once `PluginManager.shared.plugins` has
//  been collapsed into a Set, so testing the pure form is enough to
//  cover the table semantics + bias-only filter.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct FolderPluginHintsTests {

    // MARK: - Table contents

    @Test func tableMapsKnownExtensions() {
        // The onboarding picker (`OnboardingChoosePluginsView`) ships
        // `osaurus.xlsx` default-on and `osaurus.pptx` opt-in; the hint
        // table must agree on those exact ids or the bias becomes a no-op.
        // `.csv` shares the xlsx plugin (csv → xlsx conversions / pivots).
        #expect(FolderPluginHints.extensionToPluginId["xlsx"] == "osaurus.xlsx")
        #expect(FolderPluginHints.extensionToPluginId["pptx"] == "osaurus.pptx")
        #expect(FolderPluginHints.extensionToPluginId["csv"] == "osaurus.xlsx")
    }

    @Test func watchedExtensionsCoversTableKeys() {
        // The folder scanner asks `watchedExtensions` what to look for —
        // any drift between table keys and watched extensions would mean
        // the scanner skips files the table can resolve.
        #expect(FolderPluginHints.watchedExtensions == Set(FolderPluginHints.extensionToPluginId.keys))
    }

    // MARK: - Pure suggestion logic

    @Test func emptyExtensionSetReturnsEmpty() {
        let result = FolderPluginHints.suggestedPluginIds(
            extensions: [],
            installedPluginIds: ["osaurus.xlsx"]
        )
        #expect(result.isEmpty)
    }

    @Test func unknownExtensionReturnsEmpty() {
        // An extension not in the table contributes nothing — the table
        // is the single source of truth, no implicit substring matching.
        let result = FolderPluginHints.suggestedPluginIds(
            extensions: ["json", "swift"],
            installedPluginIds: ["osaurus.xlsx", "osaurus.pptx"]
        )
        #expect(result.isEmpty)
    }

    @Test func missingPluginIsDroppedSilently() {
        // Bias-only contract: a detected `.xlsx` whose plugin isn't
        // installed produces no effect (the user picked `bias_only`,
        // not `auto_install`).
        let result = FolderPluginHints.suggestedPluginIds(
            extensions: ["xlsx"],
            installedPluginIds: []
        )
        #expect(result.isEmpty)
    }

    @Test func partialMatchReturnsOnlyInstalledPlugin() {
        // Folder has both `.xlsx` and `.pptx` but only the xlsx plugin is
        // installed. Result must include xlsx and silently omit pptx —
        // not throw, not warn, not surface a placeholder.
        let result = FolderPluginHints.suggestedPluginIds(
            extensions: ["xlsx", "pptx"],
            installedPluginIds: ["osaurus.xlsx"]
        )
        #expect(result == ["osaurus.xlsx"])
    }

    @Test func bothMatchReturnsBothInDeterministicOrder() {
        // Sorted alphabetically so the resulting prompt + tool block is
        // byte-stable across turns. Two equal-priority hits would
        // otherwise alternate based on Set iteration order and tank the
        // KV-cache reuse.
        let result = FolderPluginHints.suggestedPluginIds(
            extensions: ["xlsx", "pptx"],
            installedPluginIds: ["osaurus.pptx", "osaurus.xlsx"]
        )
        #expect(result == ["osaurus.pptx", "osaurus.xlsx"])
    }

    @Test func extraInstalledPluginsAreIgnored() {
        // Installed-plugins set may contain plugins unrelated to the
        // detected extensions; those must not leak into the result.
        let result = FolderPluginHints.suggestedPluginIds(
            extensions: ["xlsx"],
            installedPluginIds: ["osaurus.xlsx", "osaurus.browser", "osaurus.calendar"]
        )
        #expect(result == ["osaurus.xlsx"])
    }

    @Test func multipleExtensionsCollapseToSamePluginOnce() {
        // `.csv` and `.xlsx` both resolve to `osaurus.xlsx`. The result
        // must dedupe so the same plugin isn't listed twice — otherwise
        // the catalog filter downstream walks the same group twice.
        let result = FolderPluginHints.suggestedPluginIds(
            extensions: ["csv", "xlsx"],
            installedPluginIds: ["osaurus.xlsx"]
        )
        #expect(result == ["osaurus.xlsx"])
    }

    @Test func csvAloneSelectsXLSXPlugin() {
        // A folder with `.csv` files but no `.xlsx` still resolves to
        // the xlsx plugin — that's the "convert this csv" entry point.
        let result = FolderPluginHints.suggestedPluginIds(
            extensions: ["csv"],
            installedPluginIds: ["osaurus.xlsx"]
        )
        #expect(result == ["osaurus.xlsx"])
    }

    @Test func folderContextDetectsOnlyPluginHintedDocumentExtensions() async throws {
        let root = try Self.tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["report.XLSX", "slides.pptx", "raw.csv", "brief.pdf"] {
            try Data(name.utf8).write(to: root.appendingPathComponent(name))
        }

        let detectedExtensions = FolderContextService.scanForKnownExtensions(
            root,
            ignorePatterns: ProjectType.unknown.ignorePatterns
        )

        #expect(detectedExtensions == Set(["xlsx", "pptx", "csv"]))
        #expect(detectedExtensions.contains("pdf") == false)
    }

    private static func tmpRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-folder-plugin-hints-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
