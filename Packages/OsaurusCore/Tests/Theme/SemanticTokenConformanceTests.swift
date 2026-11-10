//
//  SemanticTokenConformanceTests.swift
//  OsaurusCoreTests
//
//  "Keep values synchronized" check from design/HANDOFF.md: the shipped
//  Dark/Light presets must match every token in the design handoff
//  (`semantic-tokens.json`, copied into Tests/Theme/ThemeFixtures).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Semantic token conformance")
struct SemanticTokenConformanceTests {
    // MARK: - Fixture

    private struct Token: Decodable {
        let type: String
        let light: JSONValue?
        let dark: JSONValue?
    }

    private struct Fixture: Decodable {
        let semanticTokens: [String: Token]
    }

    private static let fixture: Fixture = {
        let url = Bundle.module.url(
            forResource: "semantic-tokens",
            withExtension: "json",
            subdirectory: "ThemeFixtures"
        )!
        let data = try! Data(contentsOf: url)
        return try! JSONDecoder().decode(Fixture.self, from: data)
    }()

    enum Mode: String, CaseIterable {
        case light, dark

        var preset: CustomTheme {
            switch self {
            case .light: return .lightDefault
            case .dark: return .darkDefault
            }
        }
    }

    private func value(_ name: String, _ mode: Mode) throws -> JSONValue {
        let token = try #require(Self.fixture.semanticTokens[name], "missing token \(name)")
        return try #require(mode == .light ? token.light : token.dark, "token \(name) has no \(mode) value")
    }

    private func hex(_ name: String, _ mode: Mode) throws -> String {
        try #require(try value(name, mode).string, "\(name) is not a string").lowercased()
    }

    private func number(_ name: String, _ mode: Mode) throws -> Double {
        try #require(try value(name, mode).number, "\(name) is not a number")
    }

    // MARK: - Colors

    @Test("every color token matches the preset role", arguments: Mode.allCases)
    func colorTokensMatch(mode: Mode) throws {
        let preset = mode.preset
        let roleByName = Dictionary(uniqueKeysWithValues: preset.colors.entries.map { ($0.name, $0.value) })
        // `material.window.tint` / `.fallback` are color-typed but live in the
        // window-material group; they are asserted in `windowMaterialMatches`.
        let colorTokens = Self.fixture.semanticTokens.filter {
            $0.value.type == "color" && $0.key.hasPrefix("color.")
        }

        #expect(colorTokens.count == 79)
        #expect(roleByName.count == colorTokens.count, "role catalog must have one Swift property per color token")

        for name in colorTokens.keys.sorted() {
            let expected = try hex(name, mode)
            let actual = try #require(roleByName[name], "no Swift role for \(name)")
            #expect(actual.lowercased() == expected, "\(name) (\(mode))")
        }
        for name in roleByName.keys where colorTokens[name] == nil {
            Issue.record("Swift role \(name) is not in the handoff catalog")
        }
    }

    // MARK: - Typography

    @Test("font families match", arguments: Mode.allCases)
    func fontFamiliesMatch(mode: Mode) throws {
        let preset = mode.preset
        #expect(preset.typography.families.ui == (try value("font.family.ui", mode).string))
        #expect(preset.typography.families.code == (try value("font.family.code", mode).string))
    }

    @Test("text styles match", arguments: Mode.allCases)
    func textStylesMatch(mode: Mode) throws {
        let preset = mode.preset
        // Library-only styles (chatBody, …) are covered by DesignLibraryTokenCoverageTests.
        for role in ThemeTextStyleRole.allCases where Self.fixture.semanticTokens["type.\(role.rawValue)"] != nil {
            let recipe = try #require(try value("type.\(role.rawValue)", mode).object)
            let style = preset.typography.styles[role]
            #expect(style.size == recipe["size"]?.number, "type.\(role.rawValue).size")
            #expect(Double(style.weight) == recipe["weight"]?.number, "type.\(role.rawValue).weight")
            #expect(style.lineHeight == recipe["lineHeight"]?.number, "type.\(role.rawValue).lineHeight")
            #expect(style.tracking == recipe["tracking"]?.number, "type.\(role.rawValue).tracking")
            let family = recipe["family"]?.string
            #expect(
                (style.family == .code ? ThemeFontFamilies.systemMonospaced : ThemeFontFamilies.systemUI) == family,
                "type.\(role.rawValue).family"
            )
        }
    }

    // MARK: - Geometry

    @Test("radius, stroke, focus, spacing, and control sizes match", arguments: Mode.allCases)
    func geometryMatches(mode: Mode) throws {
        let p = mode.preset
        #expect(p.radius.none == (try number("radius.none", mode)))
        #expect(p.radius.small == (try number("radius.small", mode)))
        #expect(p.radius.medium == (try number("radius.medium", mode)))
        #expect(p.radius.large == (try number("radius.large", mode)))
        #expect(p.radius.xlarge == (try number("radius.xlarge", mode)))
        #expect(p.radius.bubble == (try number("radius.bubble", mode)))
        #expect(try value("radius.pill", mode).string == "capsule")

        #expect(p.stroke.none == (try number("stroke.none", mode)))
        #expect(p.stroke.default == (try number("stroke.default", mode)))
        #expect(p.stroke.focus == (try number("stroke.focus", mode)))
        let hairline = try #require(try value("stroke.hairline", mode).object)
        #expect(hairline["formula"]?.string == "1 / backingScaleFactor")
        #expect(ThemeStrokes.hairline(forBackingScale: 2) == 0.5)
        #expect(p.focusOffset == (try number("focus.offset", mode)))

        let space = p.space
        let expectedSpace: [(String, Double)] = [
            ("space.0", space.s0), ("space.2", space.s2), ("space.4", space.s4), ("space.6", space.s6),
            ("space.8", space.s8), ("space.12", space.s12), ("space.16", space.s16), ("space.24", space.s24),
            ("space.32", space.s32), ("space.40", space.s40), ("space.48", space.s48), ("space.64", space.s64),
        ]
        for (name, actual) in expectedSpace {
            #expect(actual == (try number(name, mode)), Comment(rawValue: name))
        }

        #expect(p.controlSize.compactHeight == (try number("size.control.compactHeight", mode)))
        #expect(p.controlSize.defaultHeight == (try number("size.control.defaultHeight", mode)))
        #expect(p.controlSize.rowMinimumHeight == (try number("size.row.minimumHeight", mode)))
        #expect(p.controlSize.chatAvatar == (try number("size.chat.avatar", mode)))
    }

    // MARK: - Motion

    @Test("motion tokens match", arguments: Mode.allCases)
    func motionMatches(mode: Mode) throws {
        let m = mode.preset.motion
        #expect(m.durationQuick == (try number("motion.duration.quick", mode)))
        #expect(m.durationStandard == (try number("motion.duration.standard", mode)))
        #expect(m.durationSlow == (try number("motion.duration.slow", mode)))
        let spring = try #require(try value("motion.spring", mode).object)
        #expect(m.spring.response == spring["response"]?.number)
        #expect(m.spring.dampingFraction == spring["dampingFraction"]?.number)
        #expect(m.easing.rawValue == (try value("motion.easing", mode).string))
    }

    // MARK: - Elevation

    @Test("elevation recipes match", arguments: Mode.allCases)
    func elevationMatches(mode: Mode) throws {
        let e = mode.preset.elevation
        for (name, recipe) in [("none", e.none), ("raised", e.raised), ("overlay", e.overlay)] {
            let expected = try #require(try value("elevation.\(name)", mode).object)
            #expect(recipe.x == expected["x"]?.number, "elevation.\(name).x")
            #expect(recipe.y == expected["y"]?.number, "elevation.\(name).y")
            #expect(recipe.blur == expected["blur"]?.number, "elevation.\(name).blur")
            #expect(recipe.opacity == expected["opacity"]?.number, "elevation.\(name).opacity")
            #expect(recipe.color.lowercased() == expected["color"]?.string?.lowercased(), "elevation.\(name).color")
        }
    }

    // MARK: - Window material

    @Test("window material matches", arguments: Mode.allCases)
    func windowMaterialMatches(mode: Mode) throws {
        let w = mode.preset.windowMaterial
        #expect(w.tintOpacity == (try number("material.window.tintOpacity", mode)))
        #expect(w.nativeMaterial.rawValue == (try value("material.window.nativeMaterial", mode).string))
        #expect(w.blending.rawValue == (try value("material.window.blending", mode).string))
        #expect(w.tint.lowercased() == (try hex("material.window.tint", mode)))
        #expect(w.fallback.lowercased() == (try hex("material.window.fallback", mode)))
        // Per the handoff the tint and fallback are the canvas color.
        #expect(w.fallback.lowercased() == (try hex("color.surface.canvas", mode)))
    }

    // MARK: - Catalog completeness

    @Test("fixture has 132 tokens and every one is covered by a test above")
    func fixtureCoverage() {
        let tokens = Self.fixture.semanticTokens
        #expect(tokens.count == 132)
        let covered: Set<String> = Set(
            CustomTheme.lightDefault.colors.entries.map(\.name)
                + ["font.family.ui", "font.family.code"]
                + ThemeTextStyleRole.allCases.map { "type.\($0.rawValue)" }
                + ["radius.none", "radius.small", "radius.medium", "radius.large", "radius.xlarge", "radius.bubble", "radius.pill"]
                + ["stroke.none", "stroke.default", "stroke.focus", "stroke.hairline", "focus.offset"]
                + [0, 2, 4, 6, 8, 12, 16, 24, 32, 40, 48, 64].map { "space.\($0)" }
                + ["size.control.compactHeight", "size.control.defaultHeight", "size.row.minimumHeight", "size.chat.avatar"]
                + ["motion.duration.quick", "motion.duration.standard", "motion.duration.slow", "motion.spring", "motion.easing"]
                + ["elevation.none", "elevation.raised", "elevation.overlay"]
                + [
                    "material.window.tintOpacity", "material.window.nativeMaterial", "material.window.blending",
                    "material.window.tint", "material.window.fallback",
                ]
        )
        for name in tokens.keys where !covered.contains(name) {
            Issue.record("token \(name) is not asserted by the conformance suite")
        }
    }
}

// MARK: - Minimal JSON value

private enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
        }
    }

    var string: String? { if case .string(let s) = self { return s } else { return nil } }
    var number: Double? { if case .number(let n) = self { return n } else { return nil } }
    var object: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }
}
