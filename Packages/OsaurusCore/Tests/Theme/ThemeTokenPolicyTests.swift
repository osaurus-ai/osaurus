//
//  ThemeTokenPolicyTests.swift
//  osaurus
//
//  Theme JSON is the advanced path: anything a user types must either land
//  within the safe ranges or be reported with a line, never silently
//  break the app.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Theme token policy")
struct ThemeTokenPolicyTests {
    private let base = ThemeCompiler.library

    private func sanitize(_ tokens: [String: ThemeTokenOverride]) -> (ThemeOverrides, [ThemePolicyFinding]) {
        let result = ThemeTokenPolicy.sanitize(ThemeOverrides(tokens: tokens), base: base)
        return (result.overrides, result.findings)
    }

    @Test func colorOverridesPassThrough() {
        let (clean, findings) = sanitize(["color.text.link": ThemeTokenOverride(light: .string("#0B5F8A"), dark: .string("#6CC4F0"))])
        #expect(findings.isEmpty)
        #expect(clean.tokens["color.text.link"]?.light?.designString?.uppercased().hasPrefix("#0B5F8A") == true)
    }

    @Test func malformedColorIsAnErrorAndDropped() {
        let (clean, findings) = sanitize(["color.text.link": .both(.string("teal-ish"))])
        #expect(findings.contains { $0.severity == .error && $0.key == "color.text.link" })
        #expect(clean.tokens["color.text.link"] == nil)
    }

    @Test func unknownAndProtectedTokensAreErrors() {
        let (clean, findings) = sanitize([
            "color.nonsense.role": .both(.string("#FFFFFF")),
            "color.status.error": .both(.string("#FF0000")),
        ])
        #expect(clean.isEmpty)
        #expect(findings.filter { $0.severity == .error }.count == 2)
    }

    @Test func typographyIsClampedWithAWarning() {
        let (clean, findings) = sanitize(["type.chatBody": .both(.object(["size": .number(60)]))])
        #expect(findings.contains { $0.severity == .warning && $0.key == "type.chatBody" })
        let size = clean.tokens["type.chatBody"]?.light?.designObject?["size"]?.designNumber
        #expect(size == 32)
    }

    @Test func bodyTextCannotGoBelowTwelve() {
        let (clean, _) = sanitize(["type.body": .both(.object(["size": .number(8)]))])
        let size = clean.tokens["type.body"]?.light?.designObject?["size"]?.designNumber
        #expect(size == 12)
    }

    @Test func typographyRejectsUnknownFields() {
        let (_, findings) = sanitize(["type.body": .both(.object(["family": .string("Comic Sans")]))])
        #expect(findings.contains { $0.severity == .error })
    }

    @Test func scalarRangesClamp() {
        let (clean, findings) = sanitize([
            "stroke.default": .both(.number(12)),
            "size.control.defaultHeight": .both(.number(4)),
            "motion.duration.quick": .both(.number(3)),
        ])
        #expect(clean.tokens["stroke.default"]?.light?.designNumber == 4)
        #expect(clean.tokens["size.control.defaultHeight"]?.light?.designNumber == 24)
        #expect(clean.tokens["motion.duration.quick"]?.light?.designNumber == 0.6)
        #expect(findings.allSatisfy { $0.severity == .warning })
    }

    @Test func everyOverridableKeyExistsInTheLibrary() {
        let keys = ThemeTokenPolicy.overridableKeys(in: base)
        #expect(!keys.isEmpty)
        #expect(keys.allSatisfy { base.tokens[$0] != nil })
        #expect(!keys.contains { $0.hasPrefix("color.status.") })
    }

    // MARK: JSON

    private func json(_ document: ThemeDocument) -> String { ThemeDocumentCodec.encodeString(document) }

    @Test func validDocumentValidates() {
        let validation = ThemeTokenPolicy.validateJSON(json(ThemePresets.nord), base: base)
        #expect(!validation.hasErrors)
        #expect(validation.document?.preferences == ThemePresets.nord.preferences)
    }

    @Test func syntaxErrorsReportALine() {
        let text = "{\n  \"name\": \"Broken\",\n  \"appearance\": \n}"
        let validation = ThemeTokenPolicy.validateJSON(text, base: base)
        #expect(validation.hasErrors)
        #expect(validation.document == nil)
        #expect(validation.findings.first?.line != nil)
    }

    @Test func unknownKeysAreRejectedWithTheirLine() {
        var text = json(ThemePresets.osaurus)
        text = text.replacingOccurrences(of: "\"appearance\"", with: "\"colour\" : {},\n  \"appearance\"")
        let validation = ThemeTokenPolicy.validateJSON(text, base: base)
        let finding = validation.findings.first { $0.key == "colour" }
        #expect(finding?.severity == .error)
        #expect(finding?.line != nil)
        #expect(validation.document == nil)
    }

    @Test func clampedOverridesStillProduceADocument() {
        var document = ThemePresets.osaurus
        document.id = UUID()
        document.overrides = ThemeOverrides(tokens: ["type.chatBody": .both(.object(["size": .number(40)]))])
        let validation = ThemeTokenPolicy.validateJSON(json(document), base: base)
        #expect(!validation.hasErrors)
        #expect(validation.findings.contains { $0.severity == .warning && $0.line != nil })
        #expect(validation.document?.overrides?.tokens["type.chatBody"]?.light?.designObject?["size"]?.designNumber == 32)
    }

    @Test func newerSchemaIsRefused() {
        let text = json(ThemePresets.osaurus).replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 99")
        #expect(text.contains("99"))
        let validation = ThemeTokenPolicy.validateJSON(text, base: base)
        #expect(validation.hasErrors)
    }
}
