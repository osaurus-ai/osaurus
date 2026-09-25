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
        let code = try #require(
            N8nPairingCode.make(
                connectionId: " n8n-local ",
                name: "Home n8n",
                secret: "s3cr3t/with+chars=",
                verification: AgentChannelN8nInboundVerification(method: .sharedSecretHeader, headerName: "X-Custom"),
                reachability: N8nPairingCode.Reachability(
                    port: 1337,
                    callerLocation: .remote,
                    exposedToNetwork: true,
                    lanAddress: "192.168.1.20",
                    relayURL: "https://0xabc.agent.osaurus.ai/",
                    agentAddress: "0xABCDEF0123456789abcdef0123456789ABCDEF01"
                )
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
        // Remote carries only the relay URL: a hosted n8n can use nothing else.
        #expect(decoded.urls == ["https://0xabc.agent.osaurus.ai"])
    }

    /// The code carries exactly the URL that can reach this Mac from where
    /// the operator said n8n runs — never a loopback or LAN address that a
    /// remote n8n would burn 15 s probing.
    @Test func urlCandidatesAreScopedToTheCallerLocation() {
        let everything = N8nPairingCode.Reachability(
            port: 1337,
            exposedToNetwork: true,
            lanAddress: "192.168.1.20",
            relayURL: "https://0xabc.agent.osaurus.ai",
            agentAddress: "0xabc"
        )
        func urls(_ location: AgentChannelN8nCallerLocation) -> [String] {
            var reachability = everything
            reachability.callerLocation = location
            return N8nPairingCode.urlCandidates(reachability)
        }
        #expect(urls(.thisMac) == ["http://127.0.0.1:1337"])
        #expect(urls(.dockerDesktop) == ["http://host.docker.internal:1337"])
        #expect(urls(.lan) == ["http://192.168.1.20:1337"])
        #expect(urls(.remote) == ["https://0xabc.agent.osaurus.ai"])
    }

    @Test func readinessNamesTheBlockerInsteadOfIssuingAnUnusableCode() {
        // Remote without a bound agent: nothing can carry Secure Channel.
        let remoteNoAgent = N8nPairingCode.Reachability(
            port: 1337,
            callerLocation: .remote,
            relayURL: "https://0xabc.agent.osaurus.ai"
        )
        #expect(N8nPairingCode.readiness(remoteNoAgent) == .blocked(.needsBoundAgent))

        // Remote with an agent whose relay is not connected yet.
        let remoteNoRelay = N8nPairingCode.Reachability(port: 1337, callerLocation: .remote, agentAddress: "0xabc")
        #expect(N8nPairingCode.readiness(remoteNoRelay) == .blocked(.needsRelay))
        #expect(N8nPairingCode.urlCandidates(remoteNoRelay).isEmpty)
        #expect(
            N8nPairingCode.make(
                connectionId: "n8n-remote",
                name: "Remote",
                secret: "s",
                verification: Self.verification,
                reachability: remoteNoRelay
            ) == nil
        )

        // Remote, agent bound, relay live.
        var remoteReady = remoteNoRelay
        remoteReady.relayURL = "https://0xabc.agent.osaurus.ai"
        #expect(N8nPairingCode.readiness(remoteReady) == .ready)

        // LAN needs the server bound to the network with a real address.
        let lanNotExposed = N8nPairingCode.Reachability(port: 1337, callerLocation: .lan, lanAddress: "10.0.0.5")
        #expect(N8nPairingCode.readiness(lanNotExposed) == .blocked(.needsExposeToNetwork))
        let lanLoopbackOnly = N8nPairingCode.Reachability(
            port: 1337,
            callerLocation: .lan,
            exposedToNetwork: true,
            lanAddress: "127.0.0.1"
        )
        #expect(N8nPairingCode.readiness(lanLoopbackOnly) == .blocked(.needsExposeToNetwork))

        // LAN exposed, no agent, plaintext off: another machine gets 426.
        let lanNoTransport = N8nPairingCode.Reachability(
            port: 1337,
            callerLocation: .lan,
            exposedToNetwork: true,
            lanAddress: "10.0.0.5"
        )
        #expect(N8nPairingCode.readiness(lanNoTransport) == .blocked(.needsPlaintextOrAgent))
        var lanPlaintext = lanNoTransport
        lanPlaintext.plaintextAllowed = true
        #expect(N8nPairingCode.readiness(lanPlaintext) == .ready)
        var lanSecure = lanNoTransport
        lanSecure.agentAddress = "0xabc"
        #expect(N8nPairingCode.readiness(lanSecure) == .ready)

        // Loopback locations are always ready; relay/LAN state is irrelevant.
        #expect(N8nPairingCode.readiness(N8nPairingCode.Reachability(port: 1337, callerLocation: .thisMac)) == .ready)
        #expect(
            N8nPairingCode.readiness(N8nPairingCode.Reachability(port: 1337, callerLocation: .dockerDesktop)) == .ready
        )
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

    @Test func lanCandidateIsEmptyWhenNotExposedOrAddressIsLoopback() {
        let notExposed = N8nPairingCode.urlCandidates(
            N8nPairingCode.Reachability(port: 8080, callerLocation: .lan, exposedToNetwork: false, lanAddress: "10.0.0.5")
        )
        #expect(notExposed.isEmpty)

        let loopbackAddress = N8nPairingCode.urlCandidates(
            N8nPairingCode.Reachability(port: 8080, callerLocation: .lan, exposedToNetwork: true, lanAddress: "127.0.0.1")
        )
        #expect(loopbackAddress.isEmpty)

        let relayTrailingSlash = N8nPairingCode.urlCandidates(
            N8nPairingCode.Reachability(port: 8080, callerLocation: .remote, relayURL: "https://0xabc.agent.osaurus.ai/")
        )
        #expect(relayTrailingSlash == ["https://0xabc.agent.osaurus.ai"])
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
