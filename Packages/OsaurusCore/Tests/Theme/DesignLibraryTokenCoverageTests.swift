//
//  DesignLibraryTokenCoverageTests.swift
//  OsaurusCoreTests
//
//  Every token in the bundled design library (`design-library.json`) must
//  land on a typed theme property with the library's value, in both
//  appearances. A token that resolves nowhere is silently dropped at
//  runtime, so it has to be listed (with a reason) in `untyped` below.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Design library token coverage")
struct DesignLibraryTokenCoverageTests {
    /// Library tokens deliberately not carried by `CustomTheme`.
    static let untyped: [String: String] = [
        "color.border.control": "control boundary read by name through component assignments",
        "color.border.controlHover": "control boundary read by name through component assignments",
        "color.border.controlCheck": "checkbox boundary read by name through component assignments",
        "color.control.offIndicator": "switch thumb read by name through component assignments",
    ]

    private static let snapshot: DesignThemeSnapshot = DesignLibraryRuntime.bundledSnapshot()!

    enum Mode: String, CaseIterable { case light, dark }

    private func resolvedJSON(_ mode: Mode) throws -> JSONValue {
        let theme = mode == .light ? Self.snapshot.light : Self.snapshot.dark
        return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(theme))
    }

    private static func typedPath(_ name: String) -> [String]? {
        if name.hasPrefix("type.") { return ["typography", "styles", String(name.dropFirst(5))] }
        return DesignLibraryDefinition.path(for: name)
    }

    @Test("every library token resolves onto a typed theme property", arguments: Mode.allCases)
    func everyTokenIsTyped(mode: Mode) throws {
        let resolved = try resolvedJSON(mode)
        let tokens = Self.snapshot.document.tokens
        #expect(!tokens.isEmpty)

        for name in tokens.keys.sorted() where Self.untyped[name] == nil {
            guard let path = Self.typedPath(name) else {
                Issue.record("\(name) has no typed theme path")
                continue
            }
            guard let actual = resolved.walk(path) else {
                Issue.record("\(name) → \(path.joined(separator: ".")) is not stored on CustomTheme (\(mode))")
                continue
            }
            let expected = tokens[name]![mode.rawValue]
            if name.hasPrefix("type.") {
                for key in ["size", "weight", "lineHeight", "tracking"] {
                    #expect(actual.field(key) == expected.field(key), "\(name).\(key) (\(mode))")
                }
            } else {
                #expect(actual.matches(expected), "\(name) (\(mode)): \(actual) ≠ \(expected)")
            }
        }
        for name in Self.untyped.keys where tokens[name] == nil {
            Issue.record("allowlisted \(name) is no longer in the library; remove it")
        }
    }

    @Test("library extensions surface on the resolved runtime roles", arguments: Mode.allCases)
    func extensionsSurface(mode: Mode) throws {
        let theme = mode == .light ? Self.snapshot.light : Self.snapshot.dark
        let colors = theme.colors
        #expect(colors.surface.inverse != nil)
        #expect(colors.surface.none?.lowercased() == "#00000000")
        #expect(colors.border.none?.lowercased() == "#00000000")
        #expect(colors.action.brand != nil)
        #expect(colors.action.primary.default.border != nil)
        #expect(colors.action.destructive.hover.border != nil)
        #expect(theme.radius.pill == .capsule)
        #expect(theme.stroke.hairlineRule.width(forBackingScale: 2) == 0.5)
        for role in ThemeEffectRole.allCases {
            #expect(ThemeEffectRole(token: role.token) == role)
            #expect(Self.snapshot.document.tokens[role.token] != nil, "\(role.token) missing from library")
        }
        #expect(!theme.effects.elevation2.layers.isEmpty)
    }

    @Test("seeds without the library extensions still decode")
    func legacyThemeDecodes() throws {
        var json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(CustomTheme.darkDefault))
        json.remove(["effects"])
        json.remove(["radius", "pill"])
        json.remove(["stroke", "hairline"])
        for style in ["chatBody", "bodyEmphasis", "subheading", "labelEmphasis"] {
            json.remove(["typography", "styles", style])
        }
        let theme = try JSONDecoder().decode(CustomTheme.self, from: JSONEncoder().encode(json))
        #expect(theme.effects == .none)
        #expect(theme.radius.pill == .capsule)
        #expect(theme.stroke.hairlineRule == ThemeHairlineRule())
        #expect(theme.typography.styles.chatBody == ThemeTextStyles.default.chatBody)
        #expect(theme.colors.surface.inverse == nil)
        #expect(theme.colors.action.brand == nil)
    }
}

private extension JSONValue {
    func walk(_ path: [String]) -> JSONValue? {
        guard let head = path.first else { return self }
        guard case .object(let object) = self, let child = object[head] else { return nil }
        return child.walk(Array(path.dropFirst()))
    }

    func field(_ key: String) -> JSONValue? { walk([key]) }

    mutating func remove(_ path: [String]) {
        guard case .object(var object) = self, let head = path.first else { return }
        if path.count == 1 {
            object[head] = nil
        } else if var child = object[head] {
            child.remove(Array(path.dropFirst()))
            object[head] = child
        }
        self = .object(object)
    }

    /// The typed value equals the token, comparing hex case-insensitively and
    /// only the keys the typed model stores (library recipes carry extra
    /// export metadata such as `unit`).
    func matches(_ token: JSONValue) -> Bool {
        switch (self, token) {
        case (.string(let a), .string(let b)): return a.lowercased() == b.lowercased()
        case (.object(let typed), .object(let library)):
            return typed.allSatisfy { key, value in library[key].map { value.matches($0) } ?? true }
        case (.array(let a), .array(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.matches($1) }
        default: return self == token
        }
    }
}
