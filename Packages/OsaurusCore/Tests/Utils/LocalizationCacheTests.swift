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

    @Test("LCached returns empty key unchanged")
    func emptyKey() {
        #expect(LCached("") == "")
    }
}
