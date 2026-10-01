//
//  ThemeTypographyTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Theme typography")
struct ThemeTypographyTests {
    @Test("legacy theme JSON defaults Small Body without changing authored values")
    func legacyThemePreservesExistingTypography() throws {
        var expected = authoredTheme()
        let data = try encodedTheme(expected)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var typography = try #require(json["typography"] as? [String: Any])
        typography.removeValue(forKey: "smallBodySize")
        json["typography"] = typography

        let legacyData = try JSONSerialization.data(withJSONObject: json)
        let decoded = try decodedTheme(legacyData)
        expected.typography.smallBodySize = 14

        #expect(decoded == expected)
    }

    @Test("existing typography fields remain required in theme JSON")
    func existingTypographyFieldsRemainRequired() throws {
        let data = try encodedTheme(authoredTheme())
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var typography = try #require(json["typography"] as? [String: Any])
        typography.removeValue(forKey: "bodySize")
        json["typography"] = typography
        let incompleteData = try JSONSerialization.data(withJSONObject: json)

        #expect(throws: DecodingError.self) {
            try decodedTheme(incompleteData)
        }
    }

    @Test("theme JSON persists a customized Small Body size")
    func customSmallBodyRoundTrips() throws {
        let expected = authoredTheme()
        let data = try encodedTheme(expected)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let typography = try #require(json["typography"] as? [String: Any])

        #expect(typography["smallBodySize"] as? Double == 16.5)
        #expect(try decodedTheme(data) == expected)
    }

    @Test("Small Body follows global font scaling without changing stored typography")
    func smallBodyUsesFontScale() {
        let config = authoredTheme()
        let theme: any ThemeProtocol = CustomizableTheme(config: config, fontScale: 1.5)

        #expect(theme.smallBodySize == 24.75)
        #expect(theme.bodySize == 25.5)
        #expect(theme.customThemeConfig?.typography == config.typography)
    }

    @Test("Small Body defaults to 14 in new and built-in themes")
    func smallBodyDefaults() {
        #expect(ThemeTypography.default.smallBodySize == 14)
        #expect(CustomTheme.allBuiltInPresets.allSatisfy { $0.typography.smallBodySize == 14 })
        #expect(LightTheme().smallBodySize == 14)
        #expect(DarkTheme().smallBodySize == 14)
    }

    @Test("validation rejects invalid Small Body sizes", arguments: [7.0, 37.0, Double.nan, Double.infinity])
    func validationRejectsInvalidSmallBody(_ size: Double) {
        var theme = authoredTheme()
        theme.typography.smallBodySize = size

        let report = ThemeLibraryManagementService.validate(theme)

        #expect(!report.isValid)
        #expect(report.issues.contains { $0.field == "typography.smallBodySize" && $0.severity == .error })
    }

    @Test("validation accepts Small Body sizes within the supported range", arguments: [8.0, 14.0, 36.0])
    func validationAcceptsSupportedSmallBody(_ size: Double) {
        var theme = authoredTheme()
        theme.typography.smallBodySize = size

        let report = ThemeLibraryManagementService.validate(theme)

        #expect(!report.issues.contains { $0.field == "typography.smallBodySize" })
    }

    private func authoredTheme() -> CustomTheme {
        var theme = CustomTheme.darkDefault
        theme.metadata.createdAt = Date(timeIntervalSince1970: 1)
        theme.metadata.updatedAt = Date(timeIntervalSince1970: 2)
        theme.followsSystemAccent = false
        theme.typography = ThemeTypography(
            primaryFont: "Georgia",
            monoFont: "Courier New",
            titleSize: 30,
            headingSize: 21,
            bodySize: 17,
            smallBodySize: 16.5,
            captionSize: 11,
            codeSize: 15
        )
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
