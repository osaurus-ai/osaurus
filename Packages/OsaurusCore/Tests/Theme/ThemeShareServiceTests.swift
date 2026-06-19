//
//  ThemeShareServiceTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Theme share service")
struct ThemeShareServiceTests {
    @Test("deep links and public URLs round trip to normalized hashes")
    func parseHashAcceptsSupportedInputs() {
        let hash = "ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789"
        let normalized = hash.lowercased()

        #expect(ThemeShareService.parseHash(from: hash) == normalized)
        #expect(
            ThemeShareService.parseHash(from: ThemeShareService.deepLink(for: normalized).absoluteString) == normalized
        )
        #expect(ThemeShareService.parseHash(from: "https://themes.osaurus.ai/themes/\(hash)") == normalized)
        #expect(ThemeShareService.parseHash(from: "not-a-theme-id") == nil)
    }

    @Test("canonical share encoding ignores local import identity")
    func canonicalEncodeIgnoresLocalIdentity() throws {
        var first = CustomTheme.darkDefault
        first.metadata.id = UUID()
        first.metadata.name = "Shared Look"
        first.metadata.createdAt = Date(timeIntervalSince1970: 100)
        first.metadata.updatedAt = Date(timeIntervalSince1970: 200)
        first.isBuiltIn = false
        first.library = ThemeLibraryInfo(source: .imported, importedAt: Date())

        var second = first
        second.metadata.id = UUID()
        second.metadata.createdAt = Date(timeIntervalSince1970: 300)
        second.metadata.updatedAt = Date(timeIntervalSince1970: 400)
        second.isBuiltIn = true
        second.library = ThemeLibraryInfo(source: .shared, remoteHash: String(repeating: "c", count: 64))

        let firstData = try ThemeShareService.canonicalEncode(first)
        let secondData = try ThemeShareService.canonicalEncode(second)

        #expect(firstData == secondData)
    }
}
