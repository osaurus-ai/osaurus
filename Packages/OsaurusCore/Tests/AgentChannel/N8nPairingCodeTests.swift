//
//  N8nPairingCodeTests.swift
//  osaurus
//
//  The pairing code is the one artifact the n8n node consumes. These tests
//  pin its wire shape (prefix, base64url JSON, field names) because the TS
//  decoder in `n8n-nodes-osaurus` reads exactly these bytes.
//

import Foundation
import Testing

@testable import OsaurusCore

struct N8nPairingCodeTests {
    private static let verification = AgentChannelN8nInboundVerification(method: .hmacSHA256)

    @Test func encodeDecodeRoundTrip() throws {
        let code = N8nPairingCode.make(
            connectionId: " n8n-local ",
            name: "Home n8n",
            secret: "s3cr3t/with+chars=",
            verification: AgentChannelN8nInboundVerification(method: .sharedSecretHeader, headerName: "X-Custom"),
            reachability: N8nPairingCode.Reachability(
                port: 1337,
                exposedToNetwork: true,
                lanAddress: "192.168.1.20",
                relayURL: "https://0xabc.agent.osaurus.ai/",
                agentAddress: "0xABCDEF0123456789abcdef0123456789ABCDEF01"
            )
        )
        let encoded = code.encoded()
        #expect(encoded.hasPrefix("osrs-n8n-1."))
        #expect(!encoded.contains("="))
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))

        let decoded = try N8nPairingCode.decode(encoded)
        #expect(decoded == code)
        #expect(decoded.cid == "n8n-local")
        #expect(decoded.vfy == "shared_secret_header")
        #expect(decoded.hdr == "X-Custom")
        #expect(decoded.addr == "0xabcdef0123456789abcdef0123456789abcdef01")
        #expect(decoded.name == "Home n8n")
        #expect(decoded.isEndToEndEncrypted)
        #expect(
            decoded.urls == [
                "http://127.0.0.1:1337",
                "http://host.docker.internal:1337",
                "http://192.168.1.20:1337",
                "https://0xabc.agent.osaurus.ai",
            ])
    }

    @Test func payloadIsCompactSortedJSONWithOptionalFieldsOmitted() throws {
        let code = N8nPairingCode(
            urls: ["http://127.0.0.1:1337"],
            cid: "n8n-local",
            secret: "abc",
            vfy: .hmacSHA256
        )
        let encoded = code.encoded()
        let payload = String(encoded.dropFirst(N8nPairingCode.prefix.count))
        let data = try #require(Data(base64urlEncoded: payload))
        let json = String(decoding: data, as: UTF8.self)
        #expect(
            json
                == #"{"cid":"n8n-local","secret":"abc","urls":["http://127.0.0.1:1337"],"v":1,"vfy":"hmac_sha256"}"#
        )
        #expect(!code.isEndToEndEncrypted)
    }

    @Test func urlCandidatesSkipLANWhenNotExposedAndRelayWhenAbsent() {
        let urls = N8nPairingCode.urlCandidates(
            N8nPairingCode.Reachability(port: 8080, exposedToNetwork: false, lanAddress: "10.0.0.5")
        )
        #expect(urls == ["http://127.0.0.1:8080", "http://host.docker.internal:8080"])

        let loopbackOnly = N8nPairingCode.urlCandidates(
            N8nPairingCode.Reachability(port: 8080, exposedToNetwork: true, lanAddress: "127.0.0.1")
        )
        #expect(loopbackOnly.count == 2)
    }

    @Test func noneVerificationIsCoercedToHMAC() {
        let code = N8nPairingCode(urls: ["http://127.0.0.1:1337"], cid: "x", secret: "y", vfy: .none)
        #expect(code.vfy == "hmac_sha256")
        #expect(code.verificationMethod == .hmacSHA256)
    }

    @Test func decodeRejectsBadInput() {
        #expect(throws: N8nPairingCodeError.missingPrefix) {
            _ = try N8nPairingCode.decode("eyJ2IjoxfQ")
        }
        #expect(throws: N8nPairingCodeError.unsupportedVersion(2)) {
            _ = try N8nPairingCode.decode("osrs-n8n-2.eyJ2IjoyfQ")
        }
        #expect(throws: N8nPairingCodeError.malformedPayload) {
            _ = try N8nPairingCode.decode("osrs-n8n-1.!!!")
        }
        let missingSecret = N8nPairingCode.prefix
            + Data(#"{"v":1,"cid":"c","secret":"","urls":["http://127.0.0.1:1"],"vfy":"hmac_sha256"}"#.utf8)
            .base64urlEncoded
        #expect(throws: N8nPairingCodeError.missingField("secret")) {
            _ = try N8nPairingCode.decode(missingSecret)
        }
    }

    @Test func decodeToleratesSurroundingWhitespace() throws {
        let code = N8nPairingCode(urls: ["http://127.0.0.1:1337"], cid: "c", secret: "s", vfy: .hmacSHA256)
        let decoded = try N8nPairingCode.decode("  \(code.encoded())\n")
        #expect(decoded == code)
    }
}
