//
//  WhatsNewGateFilterTests.swift
//  OsaurusCoreTests
//
//  Verifies that `WhatsNewGate.filterPages` correctly hides pages whose ids
//  are tagged with runtime gating suffixes (`:sandbox`, `:legacy-keys`).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("WhatsNewGate.filterPages")
struct WhatsNewGateFilterTests {

    private func sample(version: String = "1.2.3") -> WhatsNewRelease {
        WhatsNewRelease(
            version: version,
            pages: [
                WhatsNewPage(id: "x:summary", title: "Summary", description: "Always present"),
                WhatsNewPage(
                    id: "x:sandbox",
                    title: "Sandbox",
                    description: "Only if sandbox is provisioned",
                    actionLabel: "Restart sandbox",
                    action: .openSandboxSettings
                ),
                WhatsNewPage(
                    id: "x:legacy-keys",
                    title: "Legacy keys",
                    description: "Only if legacy keys exist",
                    actionLabel: "Review",
                    action: .openAPIKeysSettings
                ),
                WhatsNewPage(id: "x:limits", title: "Limits", description: "Always present"),
            ]
        )
    }

    @Test
    func bothFlagsTrue_keepsAllPages() {
        let filtered = WhatsNewGate.filterPages(
            sample(),
            hasSandbox: true,
            hasLegacyPairedKeys: true
        )
        #expect(filtered.pages.count == 4)
    }

    @Test
    func noSandbox_dropsSandboxPage() {
        let filtered = WhatsNewGate.filterPages(
            sample(),
            hasSandbox: false,
            hasLegacyPairedKeys: true
        )
        #expect(filtered.pages.map(\.id) == ["x:summary", "x:legacy-keys", "x:limits"])
    }

    @Test
    func noLegacyKeys_dropsLegacyKeysPage() {
        let filtered = WhatsNewGate.filterPages(
            sample(),
            hasSandbox: true,
            hasLegacyPairedKeys: false
        )
        #expect(filtered.pages.map(\.id) == ["x:summary", "x:sandbox", "x:limits"])
    }

    @Test
    func bothFlagsFalse_keepsOnlyUngatedPages() {
        let filtered = WhatsNewGate.filterPages(
            sample(),
            hasSandbox: false,
            hasLegacyPairedKeys: false
        )
        #expect(filtered.pages.map(\.id) == ["x:summary", "x:limits"])
    }

    @Test
    func versionPropagatesUnchanged() {
        let filtered = WhatsNewGate.filterPages(
            sample(version: "9.9.9"),
            hasSandbox: false,
            hasLegacyPairedKeys: false
        )
        #expect(filtered.version == "9.9.9")
    }
}
