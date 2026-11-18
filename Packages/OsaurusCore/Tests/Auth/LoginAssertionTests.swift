//
//  LoginAssertionTests.swift
//  OsaurusCoreTests
//
//  The `osl-v1` login assertion: signing, every verification check a
//  website must make, the redirect URLs, and the fixed test vector published
//  in docs/LOGIN_WITH_OSAURUS.md.
//

import Foundation
import Testing

@testable import OsaurusCore

struct LoginAssertionTests {
    static let callback = "https://store.osaurus.ai/auth/osaurus/callback"
    static let nonce = "n0nce-0123456789abcdef"
    static let iat = 1_791_600_000
    static let issuedAt = Date(timeIntervalSince1970: TimeInterval(iat))

    static func request(responseMode: String? = nil, redirect: String = callback) throws -> LoginWithOsaurusRequest {
        var components = URLComponents(string: "osaurus://auth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: "https://store.osaurus.ai"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "state", value: "st_8f2b1c"),
            URLQueryItem(name: "nonce", value: nonce),
        ] + (responseMode.map { [URLQueryItem(name: "response_mode", value: $0)] } ?? [])
        return try LoginWithOsaurusRequest.parse(components.url!, clients: .firstParty).get()
    }

    static func signed(key: Data = TestKeys.alicePrivateKey) throws -> LoginAssertion {
        try LoginAssertion.sign(
            request: request(), privateKey: key, osaurusID: "alice", deviceID: "a1b2c3d4", now: issuedAt,
            jti: "00000000-0000-4000-8000-000000000001")
    }

    static func verify(
        _ token: String, audience: String = "https://store.osaurus.ai", redirect: String = callback,
        nonce: String = nonce, now: Date = issuedAt
    ) throws -> LoginAssertionPayload {
        try LoginAssertion.verify(token, audience: audience, redirectURI: redirect, nonce: nonce, now: now)
    }

    /// Re-signs a hand-built payload (used to forge claims with a real key).
    static func resign(_ payload: LoginAssertionPayload, key: Data) throws -> String {
        try LoginAssertion.sign(payload: payload, privateKey: key).token
    }

    static func payload(
        iss: String = TestKeys.aliceAddress.lowercased(), iat: Int = iat, exp: Int = iat + 300
    ) -> LoginAssertionPayload {
        LoginAssertionPayload(
            typ: "osaurus-login", ver: 1, iss: iss, aud: "https://store.osaurus.ai", redirectURI: callback,
            nonce: nonce, iat: iat, exp: exp, jti: "j", osaurusID: nil, dev: nil)
    }

    // MARK: - Round trip

    @Test func signsAndVerifies() throws {
        let assertion = try Self.signed()
        let payload = try Self.verify(assertion.token)
        #expect(payload == assertion.payload)
        #expect(payload.iss == TestKeys.aliceAddress.lowercased())
        #expect(payload.aud == "https://store.osaurus.ai")
        #expect(payload.redirectURI == Self.callback)
        #expect(payload.nonce == Self.nonce)
        #expect(payload.exp - payload.iat == 300)
        #expect(payload.osaurusID == "alice")
        #expect(payload.dev == "a1b2c3d4")
    }

    @Test func tokenShapeAndRecoveryByte() throws {
        let parts = try Self.signed().token.split(separator: ".")
        #expect(parts.count == 3)
        #expect(parts[0] == "osl-v1")
        #expect(parts[2].hasPrefix("0x"))
        #expect(parts[2].count == 2 + 130)
        #expect(["1b", "1c"].contains(String(parts[2].suffix(2))))
    }

    @Test func signatureIsPlainPersonalSignOverTheMessage() throws {
        let token = try Self.signed().token
        let parts = token.split(separator: ".").map(String.init)
        let signature = try #require(Data(hexEncoded: String(parts[2].dropFirst(2))))
        let recovered = try recoverAddress(
            payload: Data(("osaurus-login-v1." + parts[1]).utf8), signature: signature,
            domainPrefix: "Ethereum Signed Message")
        #expect(recovered.lowercased() == TestKeys.aliceAddress.lowercased())
    }

    @Test func omitsAbsentOptionalClaims() throws {
        let token = try Self.resign(Self.payload(), key: TestKeys.alicePrivateKey)
        let json = try #require(Data(base64urlEncoded: String(token.split(separator: ".")[1])))
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(object["osaurus_id"] == nil)
        #expect(object["dev"] == nil)
        #expect(object["redirect_uri"] as? String == Self.callback)
    }

    // MARK: - Claim checks

    @Test func rejectsOtherAudience() throws {
        #expect(throws: LoginAssertion.VerificationError.audienceMismatch) {
            try Self.verify(try Self.signed().token, audience: "https://osaurus.ai")
        }
    }

    @Test func rejectsOtherRedirect() throws {
        #expect(throws: LoginAssertion.VerificationError.redirectURIMismatch) {
            try Self.verify(try Self.signed().token, redirect: "https://store.osaurus.ai/elsewhere")
        }
    }

    @Test func rejectsOtherNonce() throws {
        #expect(throws: LoginAssertion.VerificationError.nonceMismatch) {
            try Self.verify(try Self.signed().token, nonce: "another-nonce-0123456789")
        }
    }

    @Test func rejectsExpiredBeyondSkew() throws {
        let token = try Self.signed().token
        #expect(throws: LoginAssertion.VerificationError.expired) {
            try Self.verify(token, now: Self.issuedAt.addingTimeInterval(300 + 61))
        }
        #expect(throws: Never.self) { try Self.verify(token, now: Self.issuedAt.addingTimeInterval(300 + 30)) }
    }

    @Test func rejectsIssuedInTheFutureBeyondSkew() throws {
        let token = try Self.signed().token
        #expect(throws: LoginAssertion.VerificationError.issuedInFuture) {
            try Self.verify(token, now: Self.issuedAt.addingTimeInterval(-61))
        }
        #expect(throws: Never.self) { try Self.verify(token, now: Self.issuedAt.addingTimeInterval(-30)) }
    }

    @Test func rejectsLongLifetime() throws {
        let token = try Self.resign(Self.payload(exp: Self.iat + 3600), key: TestKeys.alicePrivateKey)
        #expect(throws: LoginAssertion.VerificationError.lifetimeTooLong) { try Self.verify(token) }
    }

    // MARK: - Forgery

    @Test func anotherKeyCannotClaimAlice() throws {
        let forged = try Self.resign(Self.payload(), key: TestKeys.bobPrivateKey)
        #expect(throws: LoginAssertion.VerificationError.issuerMismatch) { try Self.verify(forged) }
    }

    @Test func swappedPayloadFailsTheSignature() throws {
        let original = try Self.signed().token.split(separator: ".").map(String.init)
        let other = try Self.resign(Self.payload(), key: TestKeys.alicePrivateKey).split(separator: ".").map(String.init)
        let spliced = [original[0], other[1], original[2]].joined(separator: ".")
        #expect(throws: LoginAssertion.VerificationError.self) { try Self.verify(spliced) }
        #expect((try? Self.verify(spliced)) == nil)
    }

    @Test func flippedSignatureByteFails() throws {
        var token = try Self.signed().token
        let index = token.index(token.endIndex, offsetBy: -10)
        token.replaceSubrange(index ... index, with: token[index] == "0" ? "1" : "0")
        #expect((try? Self.verify(token)) == nil)
    }

    @Test(arguments: [
        "", "osl-v1", "osl-v1..", "osl-v2.e30.0x00", "osl-v1.!!!.0x" + String(repeating: "00", count: 65),
        "osl-v1.e30." + String(repeating: "00", count: 65), "osl-v1.e30.0x" + String(repeating: "00", count: 64),
    ])
    func malformedTokensAreRejected(token: String) {
        #expect(throws: LoginAssertion.VerificationError.self) { try Self.verify(token) }
    }

    @Test func outOfRangeRecoveryByteIsRejectedNotCrashing() throws {
        var token = try Self.signed().token
        token.removeLast(2)
        token += "ff"
        #expect(throws: LoginAssertion.VerificationError.badSignature) { try Self.verify(token) }
    }

    // MARK: - Redirects

    @Test func successURLUsesTheFragmentByDefault() throws {
        let request = try Self.request()
        let assertion = try Self.signed()
        let url = try #require(LoginWithOsaurusResponse.successURL(for: request, assertion: assertion))
        #expect(url.absoluteString == "\(Self.callback)#assertion=\(assertion.token)&state=st_8f2b1c")
        #expect(url.query == nil)
    }

    @Test func successURLInQueryModeKeepsTheExistingQuery() throws {
        let request = try Self.request(responseMode: "query", redirect: Self.callback + "?next=%2Fme")
        let assertion = try Self.signed()
        let url = try #require(LoginWithOsaurusResponse.successURL(for: request, assertion: assertion))
        #expect(url.query == "next=%2Fme&assertion=\(assertion.token)&state=st_8f2b1c")
        #expect(url.fragment == nil)
    }

    @Test func errorURLEncodesTheDescription() throws {
        let url = try #require(
            LoginWithOsaurusResponse.errorURL(target: try Self.request().replyTarget, error: .accessDenied))
        #expect(
            url.absoluteString
                == "\(Self.callback)#error=access_denied&error_description=The%20user%20declined%20the%20sign-in.&state=st_8f2b1c"
        )
    }

    @Test func errorURLOmitsMissingState() throws {
        let target = LoginWithOsaurusReplyTarget(
            redirectURI: URL(string: Self.callback)!, state: nil, responseMode: .fragment)
        let url = try #require(
            LoginWithOsaurusResponse.errorURL(target: target, error: .invalidRequest("bad state")))
        #expect(url.fragment == "error=invalid_request&error_description=bad%20state")
    }

    // MARK: - Published vector

    /// Must match the "Test vector" section of docs/LOGIN_WITH_OSAURUS.md and
    /// docs/examples/login-with-osaurus/vector.json. Signing is RFC 6979
    /// deterministic, so the token never changes for these inputs.
    static let publishedVector =
        "osl-v1.eyJhdWQiOiJodHRwczovL3N0b3JlLm9zYXVydXMuYWkiLCJkZXYiOiJhMWIyYzNkNCIsImV4cCI6MTc5MTYwMDMwMCwiaWF0IjoxNzkxNjAwMDAwLCJpc3MiOiIweGYzOWZkNmU1MWFhZDg4ZjZmNGNlNmFiODgyNzI3OWNmZmZiOTIyNjYiLCJqdGkiOiIwMDAwMDAwMC0wMDAwLTQwMDAtODAwMC0wMDAwMDAwMDAwMDEiLCJub25jZSI6Im4wbmNlLTAxMjM0NTY3ODlhYmNkZWYiLCJvc2F1cnVzX2lkIjoiYWxpY2UiLCJyZWRpcmVjdF91cmkiOiJodHRwczovL3N0b3JlLm9zYXVydXMuYWkvYXV0aC9vc2F1cnVzL2NhbGxiYWNrIiwidHlwIjoib3NhdXJ1cy1sb2dpbiIsInZlciI6MX0.0x88f363e07abe047263f0fed7555f9ba48b8e74a0533d18a21dfb3c083dc0d1df4369368a71b0713ae7adf4dc6edfd77611facd102331cdb2ed1e3db589d62fc11c"

    @Test func publishedVectorIsStable() throws {
        let token = try Self.signed().token
        #expect(token == Self.publishedVector)
        #expect(try Self.verify(Self.publishedVector).iss == "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266")
    }
}
