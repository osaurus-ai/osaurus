//
//  CatalogResolvedThemeCostTests.swift
//  osaurusTests
//
//  Scoped theme reads run inside every view body; they must stay cheap and
//  agree with a direct resolution of the installed design snapshot.
//

import SwiftUI
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct CatalogResolvedThemeCostTests {
    @Test func scopedReadsStayCheap() {
        let root = ThemeManager.shared.currentTheme
        let scoped = root.catalogFamily(5).catalogFamily(36, authoritative: true)
        _ = scoped.colors
        let rounds = 2_000
        let start = Date()
        var sink = 0
        for _ in 0 ..< rounds {
            sink &+= scoped.colors.text.primary.hashValue
            sink &+= Int(scoped.typography.styles.body.size)
            sink &+= Int(scoped.radius.medium)
        }
        let perRead = Date().timeIntervalSince(start) / Double(rounds) * 1_000_000
        withExtendedLifetime(sink) {}
        #expect(perRead < 150, "scoped theme reads cost \(perRead)µs")
    }

    @Test func readsFollowTheInstalledSnapshot() throws {
        let overlay = DesignThemeOverlay.shared
        let original = try #require(overlay.current())
        defer { overlay.install(original) }
        let scoped = ThemeManager.shared.currentTheme.catalogFamily(5)
        let key = CatalogElementAssignments.routed("component.library.5.foreground", mappings: original.document.mappings)
        let role = try #require(original.document.mappings[key])
        func red() -> CGFloat { NSColor(scoped.colors.text.primary).usingColorSpace(.sRGB)?.redComponent ?? -1 }
        let before = red()

        var edited = original.document
        edited.tokens[role]?.light = .string("#FF0000FF")
        edited.tokens[role]?.dark = .string("#FF0000FF")
        overlay.install(try DesignLibraryDefinition.makeSnapshot(edited, baseline: original.document))
        #expect(red() == 1, "an edited token reaches scoped reads")

        overlay.install(original)
        #expect(red() == before, "restoring the snapshot restores scoped reads")
    }
}
