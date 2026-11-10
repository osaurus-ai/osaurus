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

    /// Section labels from `SystemPromptComposer`, resolved on the main actor
    /// during every preview compose (production hang APPLE-MACOS-3K2).
    private static let promptSectionLabels = [
        "Platform",
        "Persona",
        "Working Directory",
        "Agent Loop",
        "Where It Can Post",
        "Host Workspace",
        "Host Workspace (read-only)",
    ]

    @Test("LCached matches L for prompt section labels", arguments: promptSectionLabels)
    func matchesUncachedLookupForPromptLabels(key: String) {
        #expect(LCached(key) == L(String.LocalizationValue(key)))
    }

    @Test("appendBasePrompt labels match uncached lookup")
    func basePromptLabels() {
        var composer = SystemPromptComposer()
        composer.appendBasePrompt(systemPrompt: "You are a test persona.")
        let labels = composer.manifest().sections.map(\.label)
        #expect(labels.contains(L("Platform")))
        #expect(labels.contains(L("Persona")))
    }
}
