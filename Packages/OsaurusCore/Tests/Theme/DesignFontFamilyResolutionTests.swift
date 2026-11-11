//
//  DesignFontFamilyResolutionTests.swift
//  OsaurusCoreTests
//
//  The design library names its families the way Figma does ("SF Pro",
//  "SF Mono"). Those must render as the system faces: `Font.custom` with a
//  name that is not installed falls back to Helvetica, whose metrics set
//  every button and menu label high in its control.
//

import AppKit
import SwiftUI
import Testing

@testable import OsaurusCore

@Suite("Design font family resolution")
struct DesignFontFamilyResolutionTests {
    @Test("SF Pro and the system sentinel resolve to the system font", arguments: ["SF Pro", "system", ""])
    func systemFamilies(_ family: String) {
        #expect(ThemeFontNameClassifier.kind(of: family) == .system)
        #expect(
            ThemeFontNameClassifier.font(family: family, size: 13, weight: .medium)
                == .system(size: 13, weight: .medium))
        let native = ThemeFontNameClassifier.nsFont(family: family, size: 13, weight: .regular)
        #expect(native.fontName == NSFont.systemFont(ofSize: 13).fontName)
    }

    @Test("SF Mono and the monospaced sentinel resolve to the monospaced system font", arguments: ["SF Mono", "systemMonospaced"])
    func monospacedFamilies(_ family: String) {
        #expect(ThemeFontNameClassifier.kind(of: family) == .monospaced)
        #expect(
            ThemeFontNameClassifier.font(family: family, size: 12, weight: .regular)
                == .system(size: 12, weight: .regular, design: .monospaced))
        let native = ThemeFontNameClassifier.nsFont(family: family, size: 12, weight: .regular)
        #expect(native.fontName == NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).fontName)
    }

    @Test("a family that is not installed uses the system font, not Helvetica")
    func missingFamilyFallsBackToSystem() {
        let family = "Osaurus Missing Family"
        #expect(ThemeFontNameClassifier.kind(of: family) == .system)
        let native = ThemeFontNameClassifier.nsFont(family: family, size: 13, weight: .regular)
        #expect(!native.fontName.localizedCaseInsensitiveContains("helvetica"))
        #expect(native.fontName == NSFont.systemFont(ofSize: 13).fontName)
    }

    @Test("an installed non-system family is used by name")
    func installedFamilyIsKept() {
        #expect(ThemeFontNameClassifier.kind(of: "Menlo") == .named("Menlo"))
    }

    @Test("the native path keeps medium weight")
    func nativeKeepsMediumWeight() {
        let native = ThemeFontNameClassifier.nsFont(family: "SF Pro", size: 13, weight: .medium)
        #expect(native == NSFont.systemFont(ofSize: 13, weight: .medium))
    }

    @Test("every family in the bundled design library renders as a system face")
    func bundledLibraryFamiliesAreSystemFaces() throws {
        let tokens = try #require(DesignLibraryRuntime.bundledSnapshot()).document.tokens
        var families: Set<String> = []
        for (name, token) in tokens where name.hasPrefix("type.") {
            for value in [token.light, token.dark] {
                if case .object(let recipe) = value, let family = recipe["family"]?.designString {
                    families.insert(family)
                }
            }
        }
        #expect(!families.isEmpty)
        for family in families.sorted() {
            let kind = ThemeFontNameClassifier.kind(of: family)
            #expect(kind == .system || kind == .monospaced, "\(family) resolves to \(kind)")
        }
    }
}
