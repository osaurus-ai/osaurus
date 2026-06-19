//
//  ThemeLibraryManagementServiceTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Theme library management")
struct ThemeLibraryManagementServiceTests {
    @Test("validates malformed colors, images, and ranges")
    func validationFindsThemeProblems() {
        var theme = CustomTheme.darkDefault
        theme.metadata.id = UUID()
        theme.metadata.name = "Broken"
        theme.isBuiltIn = false
        theme.colors.accentColor = "not-a-color"
        theme.background = ThemeBackground(type: .image, imageData: "not-base64")
        theme.glass.opacityPrimary = 1.4

        let report = ThemeLibraryManagementService.validate(theme)

        #expect(report.errorCount >= 3)
        #expect(report.issues.contains { $0.field == "colors.accentColor" })
        #expect(report.issues.contains { $0.field == "background.imageData" })
        #expect(report.issues.contains { $0.field == "glass.opacityPrimary" })
    }

    @Test("detects visual duplicates while ignoring local metadata")
    func duplicateDetectionIgnoresIdentityMetadata() {
        var first = CustomTheme.darkDefault
        first.metadata.id = UUID()
        first.metadata.name = "First Copy"
        first.metadata.createdAt = Date(timeIntervalSince1970: 1)
        first.isBuiltIn = false

        var second = first
        second.metadata.id = UUID()
        second.metadata.name = "Second Copy"
        second.metadata.createdAt = Date(timeIntervalSince1970: 2)
        second.library = ThemeLibraryInfo(source: .imported, importedAt: Date())

        var different = first
        different.metadata.id = UUID()
        different.metadata.name = "Different"
        different.colors.accentColor = "#abcdef"

        let groups = ThemeLibraryManagementService.duplicateGroups(in: [first, second, different])

        #expect(groups.count == 1)
        #expect(groups[0].members.map(\.id).contains(first.metadata.id))
        #expect(groups[0].members.map(\.id).contains(second.metadata.id))
        #expect(!groups[0].members.map(\.id).contains(different.metadata.id))
    }

    @Test("import diagnostics parses supported IDs and finds installed shared themes")
    func importDiagnosticsParseAndMatch() {
        let hash = String(repeating: "a", count: 64)
        var installed = CustomTheme.darkDefault
        installed.metadata.id = UUID()
        installed.metadata.name = "Installed Shared"
        installed.isBuiltIn = false
        installed.library = ThemeLibraryInfo(source: .shared, remoteHash: hash)

        let raw = ThemeLibraryManagementService.diagnoseImportInput(hash.uppercased(), installedThemes: [installed])
        #expect(raw.kind == .rawHash)
        #expect(raw.normalizedHash == hash)
        #expect(raw.installedMatches.map(\.name) == ["Installed Shared"])

        let deepLink = ThemeShareService.deepLink(for: hash).absoluteString
        let linked = ThemeLibraryManagementService.diagnoseImportInput(deepLink, installedThemes: [])
        #expect(linked.kind == .deepLink)
        #expect(linked.normalizedHash == hash)

        let web = ThemeLibraryManagementService.diagnoseImportInput(
            "https://themes.osaurus.ai/themes/\(hash)",
            installedThemes: []
        )
        #expect(web.kind == .webURL)
        #expect(web.normalizedHash == hash)
    }

    @Test("file import, duplicate, share marker, and rollback persist provenance")
    func provenancePersistsThroughStoreOperations() async throws {
        try await StoragePathsTestLock.shared.run {
            try await MainActor.run {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "osaurus-theme-library-\(UUID().uuidString)",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let previousRoot = OsaurusPaths.overrideRoot
                OsaurusPaths.overrideRoot = root
                defer {
                    OsaurusPaths.overrideRoot = previousRoot
                    try? FileManager.default.removeItem(at: root)
                }

                var source = CustomTheme.darkDefault
                source.metadata.id = UUID()
                source.metadata.name = "Import Source"
                source.isBuiltIn = false

                let sourceURL = root.appendingPathComponent("source.osaurus-theme")
                let json = try ThemeJSONEditorCodec.encode(source)
                let data = try #require(json.data(using: .utf8))
                try data.write(to: sourceURL, options: .atomic)

                let imported = try ThemeConfigurationStore.importTheme(from: sourceURL)
                #expect(imported.library?.source == .imported)
                #expect(imported.library?.sourceDetail == "source.osaurus-theme")
                #expect(ThemeConfigurationStore.loadTheme(id: imported.metadata.id)?.library?.source == .imported)

                let duplicated = ThemeConfigurationStore.duplicateTheme(imported, newName: "Local Copy")
                #expect(duplicated.library?.source == .local)
                #expect(duplicated.library?.remoteHash == nil)

                let hash = String(repeating: "b", count: 64)
                let shared = ThemeConfigurationStore.markThemeShared(
                    id: imported.metadata.id,
                    hash: hash,
                    serverURL: URL(string: "https://themes.osaurus.ai/themes/\(hash)")!
                )
                #expect(shared?.library?.source == .shared)
                #expect(shared?.library?.remoteHash == hash)

                ThemeConfigurationStore.saveActiveThemeId(imported.metadata.id)
                let previous = ThemeConfigurationStore.rollbackActiveThemeToDefault()
                #expect(previous == imported.metadata.id)
                #expect(ThemeConfigurationStore.loadActiveThemeId() == nil)
            }
        }
    }
}
