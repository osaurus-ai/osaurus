//
//  ThemeTypographyTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Theme typography")
struct ThemeTypographyTests {
    @Test("theme JSON persists customized text styles")
    func customTextStylesRoundTrip() throws {
        let expected = authoredTheme()
        let data = try encodedTheme(expected)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let typography = try #require(json["typography"] as? [String: Any])
        let styles = try #require(typography["styles"] as? [String: Any])
        let bodySmall = try #require(styles["bodySmall"] as? [String: Any])

        #expect(bodySmall["size"] as? Double == 16.5)
        #expect(try decodedTheme(data) == expected)
    }

    @Test("text style fields remain required in schema 7 JSON")
    func textStyleFieldsRemainRequired() throws {
        let data = try encodedTheme(authoredTheme())
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var typography = try #require(json["typography"] as? [String: Any])
        var styles = try #require(typography["styles"] as? [String: Any])
        styles.removeValue(forKey: "body")
        typography["styles"] = styles
        json["typography"] = typography
        let incompleteData = try JSONSerialization.data(withJSONObject: json)

        #expect(throws: DecodingError.self) {
            try decodedTheme(incompleteData)
        }
    }

    @Test("themes saved before footnote and micro derive them from their caption")
    func missingDenseStylesDeriveFromCaption() throws {
        var theme = authoredTheme()
        theme.typography.styles.caption = ThemeTextStyle(size: 14, weight: 400, lineHeight: 19)
        let data = try encodedTheme(theme)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var typography = try #require(json["typography"] as? [String: Any])
        var styles = try #require(typography["styles"] as? [String: Any])
        styles.removeValue(forKey: "footnote")
        styles.removeValue(forKey: "micro")
        typography["styles"] = styles
        json["typography"] = typography

        let decoded = try decodedTheme(try JSONSerialization.data(withJSONObject: json))

        #expect(decoded.typography.styles.footnote.size == 13 && decoded.typography.styles.footnote.lineHeight == 17)
        #expect(decoded.typography.styles.micro.size == 12 && decoded.typography.styles.micro.lineHeight == 16)
    }

    @Test("text styles follow global font scaling without changing stored typography")
    func textStylesUseFontScale() {
        let unscaled: any ThemeProtocol = CustomizableTheme(config: .darkDefault, fontScale: 1.0)
        let theme: any ThemeProtocol = CustomizableTheme(config: .darkDefault, fontScale: 1.5)

        #expect(theme.scaledTextStyle(.bodySmall).size == unscaled.scaledTextStyle(.bodySmall).size * 1.5)
        #expect(theme.scaledTextStyle(.body).size == unscaled.scaledTextStyle(.body).size * 1.5)
        #expect(theme.customThemeConfig?.typography == unscaled.customThemeConfig?.typography)
    }

    @Test("handoff text recipes are the defaults for new and built-in themes")
    func textStyleDefaults() {
        let styles = ThemeTextStyles.default
        #expect(styles.display.size == 40 && styles.display.weight == 700 && styles.display.lineHeight == 48)
        #expect(styles.title.size == 26 && styles.title.weight == 600 && styles.title.lineHeight == 32)
        #expect(styles.heading.size == 18 && styles.heading.weight == 600 && styles.heading.lineHeight == 24)
        #expect(styles.body.size == 15 && styles.body.weight == 400 && styles.body.lineHeight == 22)
        #expect(styles.bodySmall.size == 14 && styles.bodySmall.lineHeight == 20)
        #expect(styles.label.size == 13 && styles.label.weight == 400 && styles.label.lineHeight == 13)
        #expect(styles.caption.size == 12 && styles.caption.lineHeight == 16)
        #expect(styles.footnote.size == 11 && styles.footnote.weight == 400 && styles.footnote.lineHeight == 14)
        #expect(styles.micro.size == 10 && styles.micro.weight == 400 && styles.micro.lineHeight == 13)
        #expect(styles.code.size == 13 && styles.code.family == .code && styles.code.lineHeight == 20)

        #expect(CustomTheme.darkDefault.typography.styles == styles)
        #expect(CustomTheme.lightDefault.typography.styles == styles)
        #expect(CustomizableTheme.light().scaledTextStyle(.bodySmall).size == 14)
        #expect(CustomizableTheme.dark().scaledTextStyle(.bodySmall).size == 14)
    }

    private func authoredTheme() -> CustomTheme {
        var theme = CustomTheme.darkDefault
        theme.metadata.createdAt = Date(timeIntervalSince1970: 1)
        theme.metadata.updatedAt = Date(timeIntervalSince1970: 2)
        theme.typography.families = ThemeFontFamilies(ui: "Georgia", code: "Courier New")
        theme.typography.styles.body.size = 17
        theme.typography.styles.body.lineHeight = 24
        theme.typography.styles.bodySmall.size = 16.5
        theme.typography.styles.bodySmall.lineHeight = 23
        return theme
    }

    private func encodedTheme(_ theme: CustomTheme) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(theme)
    }

    private func decodedTheme(_ data: Data) throws -> CustomTheme {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CustomTheme.self, from: data)
    }
}
