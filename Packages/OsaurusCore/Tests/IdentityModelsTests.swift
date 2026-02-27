//
//  IdentityModelsTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct IdentityModelsTests {

    // MARK: - AccessKeyExpiration

    @Test func expiration_days30_addsDays() {
        let now = Date()
        let exp = AccessKeyExpiration.days30.expirationDate(from: now)
        let expected = Calendar.current.date(byAdding: .day, value: 30, to: now)
        #expect(exp == expected)
    }

    @Test func expiration_days90_addsDays() {
        let now = Date()
        let exp = AccessKeyExpiration.days90.expirationDate(from: now)
        let expected = Calendar.current.date(byAdding: .day, value: 90, to: now)
        #expect(exp == expected)
    }

    @Test func expiration_year1_addsYear() {
        let now = Date()
        let exp = AccessKeyExpiration.year1.expirationDate(from: now)
        let expected = Calendar.current.date(byAdding: .year, value: 1, to: now)
        #expect(exp == expected)
    }

    @Test func expiration_never_returnsNil() {
        #expect(AccessKeyExpiration.never.expirationDate(from: Date()) == nil)
    }

    @Test func expiration_displayNames() {
        #expect(AccessKeyExpiration.days30.displayName == "30 days")
        #expect(AccessKeyExpiration.days90.displayName == "90 days")
        #expect(AccessKeyExpiration.year1.displayName == "1 year")
        #expect(AccessKeyExpiration.never.displayName == "Never")
    }

    @Test func expiration_codable_roundtrip() throws {
        for exp in AccessKeyExpiration.allCases {
            let data = try JSONEncoder().encode(exp)
            let decoded = try JSONDecoder().decode(AccessKeyExpiration.self, from: data)
            #expect(decoded == exp)
        }
    }

    // MARK: - AccessKeyPayload

    @Test func payload_codable_roundtrip() throws {
        let payload = AccessKeyPayload(
            aud: "0xABC",
            cnt: 42,
            exp: 9999999,
            iat: 1000000,
            iss: "0xDEF",
            lbl: "test",
            nonce: "abc123"
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(AccessKeyPayload.self, from: data)

        #expect(decoded.aud == payload.aud)
        #expect(decoded.cnt == payload.cnt)
        #expect(decoded.exp == payload.exp)
        #expect(decoded.iat == payload.iat)
        #expect(decoded.iss == payload.iss)
        #expect(decoded.lbl == payload.lbl)
        #expect(decoded.nonce == payload.nonce)
    }

    @Test func payload_sortedKeys_alphabetical() throws {
        let payload = AccessKeyPayload(
            aud: "0xABC",
            cnt: 1,
            exp: nil,
            iat: 100,
            iss: "0xDEF",
            lbl: nil,
            nonce: "n"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        let json = String(data: data, encoding: .utf8)!

        let keys = ["\"aud\"", "\"cnt\"", "\"iat\"", "\"iss\"", "\"nonce\""]
        var lastIndex = json.startIndex
        for key in keys {
            guard let range = json.range(of: key, range: lastIndex ..< json.endIndex) else {
                Issue.record("Key \(key) not found in JSON after \(lastIndex)")
                return
            }
            lastIndex = range.upperBound
        }
    }

    @Test func payload_nilExpAndLabel_omittedInJSON() throws {
        let payload = AccessKeyPayload(
            aud: "0x1",
            cnt: 1,
            exp: nil,
            iat: 100,
            iss: "0x2",
            lbl: nil,
            nonce: "n"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        let json = String(data: data, encoding: .utf8)!

        let decoded = try JSONDecoder().decode(AccessKeyPayload.self, from: data)
        #expect(decoded.exp == nil)
        #expect(decoded.lbl == nil)
        #expect(!json.contains("\"exp\"") || json.contains("null"))
    }

    // MARK: - AccessKeyInfo

    @Test func info_isExpired_futureDate() {
        let info = makeInfo(expiresAt: Date().addingTimeInterval(3600))
        #expect(info.isExpired == false)
    }

    @Test func info_isExpired_pastDate() {
        let info = makeInfo(expiresAt: Date().addingTimeInterval(-3600))
        #expect(info.isExpired == true)
    }

    @Test func info_isExpired_nilDate() {
        let info = makeInfo(expiresAt: nil)
        #expect(info.isExpired == false)
    }

    @Test func info_isActive_notRevokedNotExpired() {
        let info = makeInfo(expiresAt: Date().addingTimeInterval(3600), revoked: false)
        #expect(info.isActive == true)
    }

    @Test func info_isActive_falseWhenRevoked() {
        let info = makeInfo(expiresAt: Date().addingTimeInterval(3600), revoked: true)
        #expect(info.isActive == false)
    }

    @Test func info_isActive_falseWhenExpired() {
        let info = makeInfo(expiresAt: Date().addingTimeInterval(-3600), revoked: false)
        #expect(info.isActive == false)
    }

    @Test func info_withRevoked_setsFlag() {
        let info = makeInfo(revoked: false)
        #expect(info.revoked == false)
        let revoked = info.withRevoked()
        #expect(revoked.revoked == true)
        #expect(revoked.id == info.id)
        #expect(revoked.nonce == info.nonce)
        #expect(revoked.label == info.label)
    }

    @Test func info_codable_roundtrip() throws {
        let info = makeInfo()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(info)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AccessKeyInfo.self, from: data)

        #expect(decoded.id == info.id)
        #expect(decoded.nonce == info.nonce)
        #expect(decoded.cnt == info.cnt)
        #expect(decoded.iss == info.iss)
        #expect(decoded.aud == info.aud)
        #expect(decoded.revoked == info.revoked)
    }

    // MARK: - RevocationSnapshot

    @Test func revocation_individualRevoke_detected() {
        let snapshot = RevocationSnapshot(
            revokedKeys: [RevocationSnapshot.revocationKey(address: "0xABC", nonce: "n1")],
            counterThresholds: [:]
        )
        #expect(snapshot.isRevoked(address: "0xABC", nonce: "n1", cnt: 1) == true)
        #expect(snapshot.isRevoked(address: "0xABC", nonce: "n2", cnt: 1) == false)
    }

    @Test func revocation_bulkRevoke_belowThreshold() {
        let snapshot = RevocationSnapshot(
            revokedKeys: [],
            counterThresholds: ["0xabc": 10]
        )
        #expect(snapshot.isRevoked(address: "0xABC", nonce: "any", cnt: 5) == true)
        #expect(snapshot.isRevoked(address: "0xABC", nonce: "any", cnt: 10) == true)
    }

    @Test func revocation_bulkRevoke_aboveThreshold_notRevoked() {
        let snapshot = RevocationSnapshot(
            revokedKeys: [],
            counterThresholds: ["0xabc": 10]
        )
        #expect(snapshot.isRevoked(address: "0xABC", nonce: "any", cnt: 11) == false)
    }

    @Test func revocation_caseInsensitive() {
        let snapshot = RevocationSnapshot(
            revokedKeys: [RevocationSnapshot.revocationKey(address: "0xABC", nonce: "n1")],
            counterThresholds: ["0xdef": 5]
        )
        #expect(snapshot.isRevoked(address: "0xabc", nonce: "n1", cnt: 99) == true)
        #expect(snapshot.isRevoked(address: "0xDEF", nonce: "x", cnt: 3) == true)
    }

    @Test func revocation_emptySnapshot_nothingRevoked() {
        let snapshot = RevocationSnapshot(revokedKeys: [], counterThresholds: [:])
        #expect(snapshot.isRevoked(address: "0xABC", nonce: "n1", cnt: 1) == false)
    }

    @Test func revocationKey_format() {
        let key = RevocationSnapshot.revocationKey(address: "0xABC", nonce: "myNonce")
        #expect(key == "0xabc:myNonce")
    }

    // MARK: - AgentInfo

    @Test func agentInfo_identifiable_usesIndex() {
        let info = AgentInfo(index: 7, address: "0xABC", label: "Agent 7")
        #expect(info.id == 7)
    }

    // MARK: - Helpers

    private func makeInfo(
        expiresAt: Date? = Date().addingTimeInterval(3600),
        revoked: Bool = false
    ) -> AccessKeyInfo {
        AccessKeyInfo(
            id: UUID(),
            label: "test key",
            prefix: "osk-v1.eyJhdWQiOiIw",
            nonce: "abcdef1234567890abcdef1234567890",
            cnt: 1,
            iss: "0xABC",
            aud: "0xABC",
            createdAt: Date(),
            expiration: .days90,
            expiresAt: expiresAt,
            revoked: revoked
        )
    }
}
