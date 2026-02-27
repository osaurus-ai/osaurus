//
//  CryptoHelpersTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct CryptoHelpersTests {

    // MARK: - Keccak-256 Known-Answer Tests

    @Test func keccak256_emptyInput() {
        let hash = Keccak256.hash(data: Data())
        #expect(hash.hexEncodedString == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
    }

    @Test func keccak256_hello() {
        let hash = Keccak256.hash(data: Data("hello".utf8))
        #expect(hash.hexEncodedString == "1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8")
    }

    @Test func keccak256_singleByte() {
        let hash = Keccak256.hash(bytes: [0x00])
        #expect(hash.count == 32)
    }

    @Test func keccak256_deterministic() {
        let input = Data("osaurus identity".utf8)
        let h1 = Keccak256.hash(data: input)
        let h2 = Keccak256.hash(data: input)
        #expect(h1 == h2)
    }

    @Test func keccak256_differentInputs_differentOutputs() {
        let a = Keccak256.hash(data: Data("a".utf8))
        let b = Keccak256.hash(data: Data("b".utf8))
        #expect(a != b)
    }

    @Test func keccak256_outputIs32Bytes() {
        let hash = Keccak256.hash(data: Data(repeating: 0xff, count: 256))
        #expect(hash.count == 32)
    }

    // MARK: - Signing & Recovery Roundtrip

    @Test func signPayload_recoverAddress_roundtrip() throws {
        let privateKey = TestKeys.alicePrivateKey
        let expectedAddress = TestKeys.aliceAddress
        let payload = Data("test payload".utf8)

        let signature = try signPayload(payload, privateKey: privateKey)
        #expect(signature.count == 65)

        let recovered = try recoverAddress(
            payload: payload,
            signature: signature,
            domainPrefix: "Osaurus Signed Message"
        )
        #expect(recovered.lowercased() == expectedAddress.lowercased())
    }

    @Test func signAccessPayload_recoverAddress_roundtrip() throws {
        let privateKey = TestKeys.bobPrivateKey
        let expectedAddress = TestKeys.bobAddress
        let payload = Data("access payload".utf8)

        let signature = try signAccessPayload(payload, privateKey: privateKey)
        #expect(signature.count == 65)

        let recovered = try recoverAddress(
            payload: payload,
            signature: signature,
            domainPrefix: "Osaurus Signed Access"
        )
        #expect(recovered.lowercased() == expectedAddress.lowercased())
    }

    // MARK: - Domain Separation

    @Test func domainSeparation_differentPrefixes_differentSignatures() throws {
        let privateKey = TestKeys.alicePrivateKey
        let payload = Data("same payload".utf8)

        let msgSig = try signPayload(payload, privateKey: privateKey)
        let accessSig = try signAccessPayload(payload, privateKey: privateKey)
        #expect(msgSig != accessSig)
    }

    @Test func domainSeparation_wrongPrefix_recoversWrongAddress() throws {
        let privateKey = TestKeys.alicePrivateKey
        let expectedAddress = TestKeys.aliceAddress
        let payload = Data("domain test".utf8)

        let signature = try signPayload(payload, privateKey: privateKey)

        let recoveredWithWrongPrefix = try recoverAddress(
            payload: payload,
            signature: signature,
            domainPrefix: "Osaurus Signed Access"
        )
        #expect(recoveredWithWrongPrefix.lowercased() != expectedAddress.lowercased())
    }

    // MARK: - Signature Validation Edge Cases

    @Test func recoverAddress_invalidSignatureLength_throws() {
        let payload = Data("test".utf8)
        let shortSig = Data(repeating: 0x00, count: 64)

        #expect(throws: OsaurusIdentityError.self) {
            _ = try recoverAddress(payload: payload, signature: shortSig, domainPrefix: "Osaurus Signed Access")
        }
    }

    @Test func signPayload_differentPayloads_differentSignatures() throws {
        let privateKey = TestKeys.alicePrivateKey
        let sig1 = try signPayload(Data("payload A".utf8), privateKey: privateKey)
        let sig2 = try signPayload(Data("payload B".utf8), privateKey: privateKey)
        #expect(sig1 != sig2)
    }

    @Test func signPayload_differentKeys_differentSignatures() throws {
        let payload = Data("same payload".utf8)
        let sig1 = try signPayload(payload, privateKey: TestKeys.alicePrivateKey)
        let sig2 = try signPayload(payload, privateKey: TestKeys.bobPrivateKey)
        #expect(sig1 != sig2)
    }

    // MARK: - Address Derivation

    @Test func deriveOsaurusId_deterministic() throws {
        let addr1 = try deriveOsaurusId(from: TestKeys.alicePrivateKey)
        let addr2 = try deriveOsaurusId(from: TestKeys.alicePrivateKey)
        #expect(addr1 == addr2)
    }

    @Test func deriveOsaurusId_differentKeys_differentAddresses() throws {
        let alice = try deriveOsaurusId(from: TestKeys.alicePrivateKey)
        let bob = try deriveOsaurusId(from: TestKeys.bobPrivateKey)
        let carol = try deriveOsaurusId(from: TestKeys.carolPrivateKey)
        #expect(alice != bob)
        #expect(bob != carol)
        #expect(alice != carol)
    }

    @Test func deriveOsaurusId_checksumFormat() throws {
        let addr = try deriveOsaurusId(from: TestKeys.alicePrivateKey)
        #expect(addr.hasPrefix("0x"))
        #expect(addr.count == 42)
    }

    @Test func checksumEncode_roundtrip_preserves() {
        let raw = "d8da6bf26964af9d7eed9e03e53415d37aa96045"
        let checksummed = checksumEncode(raw: raw)
        #expect(checksummed.hasPrefix("0x"))
        #expect(checksummed.count == 42)
        #expect(checksummed.dropFirst(2).lowercased() == raw)
    }

    @Test func checksumEncode_mixedCase_vitalik() {
        // Vitalik's address (EIP-55 reference vector)
        let raw = "d8da6bf26964af9d7eed9e03e53415d37aa96045"
        let checksummed = checksumEncode(raw: raw)
        #expect(checksummed.dropFirst(2).lowercased() == raw)
        let hasUpperAndLower =
            checksummed.dropFirst(2).contains(where: { $0.isUppercase })
            && checksummed.dropFirst(2).contains(where: { $0.isLowercase })
        #expect(hasUpperAndLower)
    }

    // MARK: - Base64url Encoding

    @Test func base64url_roundtrip() {
        let original = Data("Hello, Osaurus!".utf8)
        let encoded = original.base64urlEncoded
        let decoded = Data(base64urlEncoded: encoded)
        #expect(decoded == original)
    }

    @Test func base64url_noPadding() {
        let data = Data([0x01, 0x02, 0x03])
        let encoded = data.base64urlEncoded
        #expect(!encoded.contains("="))
    }

    @Test func base64url_noStandardCharacters() {
        let data = Data(repeating: 0xff, count: 64)
        let encoded = data.base64urlEncoded
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
    }

    @Test func base64url_emptyData() {
        let data = Data()
        let encoded = data.base64urlEncoded
        let decoded = Data(base64urlEncoded: encoded)
        #expect(decoded == data)
    }

    @Test func base64url_invalidString_returnsNil() {
        let decoded = Data(base64urlEncoded: "!!!not-valid!!!")
        #expect(decoded == nil)
    }

    // MARK: - Hex Encoding

    @Test func hex_roundtrip() {
        let original = Data([0xde, 0xad, 0xbe, 0xef])
        let hex = original.hexEncodedString
        #expect(hex == "deadbeef")
        let decoded = Data(hexEncoded: hex)
        #expect(decoded == original)
    }

    @Test func hex_emptyData() {
        let data = Data()
        #expect(data.hexEncodedString == "")
        #expect(Data(hexEncoded: "") == Data())
    }

    @Test func hex_oddLength_returnsNil() {
        #expect(Data(hexEncoded: "abc") == nil)
    }

    @Test func hex_invalidChars_returnsNil() {
        #expect(Data(hexEncoded: "zzzz") == nil)
        #expect(Data(hexEncoded: "ghij") == nil)
    }

    @Test func hex_uppercase_accepted() {
        let decoded = Data(hexEncoded: "DEADBEEF")
        #expect(decoded == Data([0xde, 0xad, 0xbe, 0xef]))
    }
}
