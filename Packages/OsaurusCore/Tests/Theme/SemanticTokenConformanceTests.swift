//
//  SemanticTokenConformanceTests.swift
//  OsaurusCoreTests
//
//  The Swift seeds (`CustomTheme.lightDefault/darkDefault`) are the shape the
//  bundled design library resolves onto. Every value they carry must equal
//  the library, so nothing paints a stale color before or without the
//  overlay. Regenerate with `scripts/design-handoff/sync-theme-seeds.py`.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Theme seeds match the design library")
struct SemanticTokenConformanceTests {
    private static let tokens: [String: DesignToken] = DesignLibraryRuntime.bundledSnapshot()!.document.tokens

    enum Mode: String, CaseIterable {
        case light, dark

        var preset: CustomTheme {
            switch self {
            case .light: return .lightDefault
            case .dark: return .darkDefault
            }
        }
    }

    private static func typedPath(_ name: String) -> [String]? {
        // Seeds carry no effect layers; effects only paint from the library.
        if ThemeEffectRole(token: name) != nil { return nil }
        if name.hasPrefix("type.") { return ["typography", "styles", String(name.dropFirst(5))] }
        return DesignLibraryDefinition.path(for: name)
    }

    /// Library values are Float-precision Figma exports with named system families.
    private static func same(_ seed: JSONValue, _ library: JSONValue) -> Bool {
        switch (seed, library) {
        case (.number(let a), .number(let b)): return abs(a - b) < 0.0001
        case (.string(let a), .string(let b)):
            let families = ["SF Pro": "system", "SF Mono": "systemMonospaced"]
            func normal(_ s: String) -> String {
                let value = families[s] ?? s
                return (value.hasPrefix("#") && value.count == 7 ? value + "FF" : value).lowercased()
            }
            return normal(a) == normal(b)
        case (.object(let a), .object(let b)):
            return a.allSatisfy { key, value in b[key].map { same(value, $0) } ?? true }
        case (.array(let a), .array(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { same($0, $1) }
        default: return seed == library
        }
    }

    @Test("every seed value equals its library token", arguments: Mode.allCases)
    func seedsEqualLibrary(mode: Mode) throws {
        let seed = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(mode.preset))
        var compared = 0
        for name in Self.tokens.keys.sorted() {
            guard let path = Self.typedPath(name), let actual = seed.walk(path) else { continue }
            compared += 1
            let expected = Self.tokens[name]![mode.rawValue]
            if name.hasPrefix("type.") {
                // One seed serves both modes; a mode-split style can match only one.
                if Self.modeSplitTypography.contains(name) { continue }
                for key in ["size", "weight", "lineHeight", "tracking"] {
                    #expect(actual.field(key) == expected.field(key), "\(name).\(key) (\(mode))")
                }
            } else {
                #expect(Self.same(actual, expected), "\(name) (\(mode)): seed \(actual) ≠ library \(expected)")
            }
        }
        #expect(compared >= 130, "only \(compared) seed values were compared")
    }

    /// Library type styles whose light and dark recipes differ. Typography is
    /// meant to be mode-independent, so this list may only shrink.
    private static let modeSplitTypography: Set<String> = ["type.labelEmphasis"]

    @Test func typographyIsModeIndependent() {
        let split = Self.tokens.filter { name, token in
            name.hasPrefix("type.") && ["size", "weight", "lineHeight", "tracking"].contains { token.light.field($0) != token.dark.field($0) }
        }
        #expect(Set(split.keys) == Self.modeSplitTypography)
    }

    @Test("every seed color role is a library token", arguments: Mode.allCases)
    func seedRolesExistInLibrary(mode: Mode) {
        for (name, _) in mode.preset.colors.entries {
            #expect(Self.tokens[name] != nil, "seed role \(name) is not in the design library")
        }
    }
}
