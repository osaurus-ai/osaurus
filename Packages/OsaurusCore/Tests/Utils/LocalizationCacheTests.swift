//
//  LocalizationCacheTests.swift
//  osaurus / Utils Tests
//
//  `LCached` replaces `L` for static labels rendered from SwiftUI body
//  getters (e.g. ConfigurationView.generalSection, production hang
//  APPLE-MACOS-3BN). It must resolve to exactly what `L` returns, and be
//  stable across repeated calls.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("LCached localization memo")
struct LocalizationCacheTests {

    private static let settingsLabels = [
        "General",
        "App behavior, models on this Mac, and notifications",
        "Global Hotkey",
        "Start at Login",
        "Hide Dock Icon",
        "Beta Updates",
        "Use models already on this Mac",
        "Show Notifications",
    ]

    @Test("LCached matches L for settings labels", arguments: settingsLabels)
    func matchesUncachedLookup(key: String) {
        #expect(LCached(key) == L(String.LocalizationValue(key)))
    }

    @Test("LCached is stable across repeated calls", arguments: settingsLabels)
    func stableAcrossCalls(key: String) {
        let first = LCached(key)
        for _ in 0..<10 {
            #expect(LCached(key) == first)
        }
    }

    /// Composer placeholder strings rendered from
    /// `FloatingInputCard.placeholderText` (production hang APPLE-MACOS-1E7).
    private static let composerPlaceholders = [
        "Describe the image...",
        "Describe the video...",
        "Attach one image, then describe the video...",
        "Describe how the image should move...",
        "Message or attach files...",
    ]

    @Test("LCached matches L for composer placeholders", arguments: composerPlaceholders)
    func matchesUncachedLookupForPlaceholders(key: String) {
        #expect(LCached(key) == L(String.LocalizationValue(key)))
    }

    /// Gauge labels and format keys rendered from `SystemStatusBar.body`
    /// on every `SystemMonitorService` publish (production hang APPLE-MACOS-3RN).
    private static let systemStatusBarLabels = [
        "RAM",
        "Storage",
    ]

    @Test("LCached matches L for system status bar labels", arguments: systemStatusBarLabels)
    func matchesUncachedLookupForStatusBar(key: String) {
        #expect(LCached(key) == L(String.LocalizationValue(key)))
    }

    /// The status bar's format keys must come back from `LCached` as usable
    /// format strings, so formatting them with real arguments keeps the values.
    @Test("LCached format keys for the system status bar keep their arguments")
    func statusBarFormatKeysFormatArguments() {
        #expect(String(format: LCached("%.0f GB"), 512.0).contains("512"))
        #expect(String(format: LCached("%.1f TB"), 1.5).contains("1"))
        let detail = String(format: LCached("%@ free / %@"), "12 GB", "64 GB")
        #expect(detail.contains("12 GB"))
        #expect(detail.contains("64 GB"))
    }

    @Test("LCached returns empty key unchanged")
    func emptyKey() {
        #expect(LCached("") == "")
    }
}
