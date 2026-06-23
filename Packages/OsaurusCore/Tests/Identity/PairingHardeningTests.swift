//
//  PairingHardeningTests.swift
//  OsaurusCoreTests
//
//  Covers the Bonjour + Relay P2P hardening work: server-issued pairing
//  challenges, per-IP rate limiting, HPKE key envelopes, the multi-agent
//  audience validator, and route-level agent scoping.
//

import CryptoKit
import Foundation
import Testing

@testable import OsaurusCore

// MARK: - PairingChallengeStore

struct PairingChallengeStoreTests {
    @Test func issuedNonce_consumesExactlyOnce() {
        let nonce = PairingChallengeStore.shared.issue()
        #expect(!nonce.isEmpty)
        #expect(PairingChallengeStore.shared.consume(nonce))
        // Single-use: a replayed nonce must be rejected.
        #expect(!PairingChallengeStore.shared.consume(nonce))
    }

    @Test func unknownNonce_rejected() {
        #expect(!PairingChallengeStore.shared.consume("never-issued-nonce"))
    }

    @Test func issuedNonces_areUnique() {
        let a = PairingChallengeStore.shared.issue()
        let b = PairingChallengeStore.shared.issue()
        #expect(a != b)
        #expect(PairingChallengeStore.shared.consume(a))
        #expect(PairingChallengeStore.shared.consume(b))
    }
}

// MARK: - PairingRateLimiter

struct PairingRateLimiterTests {
    @Test func allowsBurstThenBlocks() {
        let ip = "test-\(UUID().uuidString)"
        var allowed = 0
        for _ in 0 ..< 20 where PairingRateLimiter.shared.allow(ip: ip) {
            allowed += 1
        }
        // The exact cap is an implementation detail; what matters is that a
        // burst is bounded and further attempts are rejected.
        #expect(allowed > 0)
        #expect(allowed < 20)
        #expect(!PairingRateLimiter.shared.allow(ip: ip))
    }

    @Test func penaltyBlocksImmediately() {
        let ip = "test-\(UUID().uuidString)"
        #expect(PairingRateLimiter.shared.allow(ip: ip))
        PairingRateLimiter.shared.penalize(ip: ip)
        #expect(!PairingRateLimiter.shared.allow(ip: ip))
    }

    @Test func limitsAreIndependentPerIP() {
        let blocked = "test-\(UUID().uuidString)"
        let fresh = "test-\(UUID().uuidString)"
        PairingRateLimiter.shared.penalize(ip: blocked)
        #expect(!PairingRateLimiter.shared.allow(ip: blocked))
        #expect(PairingRateLimiter.shared.allow(ip: fresh))
    }
}

// MARK: - PairingKeyEnvelope (HPKE)

struct PairingKeyEnvelopeTests {
    @Test func sealOpen_roundtrip() throws {
        let (privateKey, pub) = PairingKeyEnvelope.generateRecipientKey()
        let info = PairingKeyEnvelope.info(agentAddress: "0xABCDEF", nonce: "nonce-1")
        let secret = "osk-v1.payload.signature"

        let sealed = try PairingKeyEnvelope.seal(
            secret: secret,
            recipientPublicKeyBase64url: pub,
            info: info
        )
        #expect(sealed.ct != secret)

        let opened = try PairingKeyEnvelope.open(sealed, privateKey: privateKey, info: info)
        #expect(opened == secret)
    }

    @Test func open_withWrongKey_fails() throws {
        let (_, pub) = PairingKeyEnvelope.generateRecipientKey()
        let (otherKey, _) = PairingKeyEnvelope.generateRecipientKey()
        let info = PairingKeyEnvelope.info(agentAddress: "0xABCDEF", nonce: "nonce-2")

        let sealed = try PairingKeyEnvelope.seal(
            secret: "secret",
            recipientPublicKeyBase64url: pub,
            info: info
        )
        #expect(throws: PairingKeyEnvelopeError.self) {
            _ = try PairingKeyEnvelope.open(sealed, privateKey: otherKey, info: info)
        }
    }

    @Test func open_withWrongInfo_fails() throws {
        let (privateKey, pub) = PairingKeyEnvelope.generateRecipientKey()
        let sealed = try PairingKeyEnvelope.seal(
            secret: "secret",
            recipientPublicKeyBase64url: pub,
            info: PairingKeyEnvelope.info(agentAddress: "0xABCDEF", nonce: "nonce-3")
        )
        // A different nonce/agent binding must not decrypt: envelopes can't be
        // transplanted between pairing exchanges.
        #expect(throws: PairingKeyEnvelopeError.self) {
            _ = try PairingKeyEnvelope.open(
                sealed,
                privateKey: privateKey,
                info: PairingKeyEnvelope.info(agentAddress: "0xABCDEF", nonce: "other-nonce")
            )
        }
    }

    @Test func seal_withGarbageRecipientKey_fails() {
        #expect(throws: PairingKeyEnvelopeError.self) {
            _ = try PairingKeyEnvelope.seal(
                secret: "secret",
                recipientPublicKeyBase64url: "!!!not-a-key!!!",
                info: Data()
            )
        }
    }
}

// MARK: - Multi-Agent Audience Validator

struct MultiAgentValidatorTests {
    /// Production shape: the server validator is built with EVERY agent's
    /// address, so a key minted by `/pair` for agent 1 must validate even
    /// though the validator wasn't built "for" agent 1 specifically.
    @Test func pairedAgentKey_validatesAgainstMultiAgentValidator() throws {
        let agent0 = try AgentKey.deriveAddress(masterKey: TestKeys.alicePrivateKey, index: 0)
        let agent1 = try AgentKey.deriveAddress(masterKey: TestKeys.alicePrivateKey, index: 1)
        let agent1Key = AgentKey.derive(masterKey: TestKeys.alicePrivateKey, index: 1)

        let validator = APIKeyValidator(
            agentAddresses: [agent0, agent1],
            masterAddress: TestKeys.aliceAddress,
            effectiveWhitelist: [
                TestKeys.aliceAddress.lowercased(), agent0.lowercased(), agent1.lowercased(),
            ],
            revocationSnapshot: RevocationSnapshot(revokedKeys: [], counterThresholds: [:]),
            hasKeys: true
        )

        let token = try TokenBuilder.build(
            privateKey: agent1Key,
            iss: agent1,
            aud: agent1
        )

        let result = validator.validate(rawKey: token)
        guard case .valid(let issuer, let audience, _) = result else {
            Issue.record("Agent-scoped paired key should validate, got \(result)")
            return
        }
        #expect(issuer.lowercased() == agent1.lowercased())
        #expect(audience.lowercased() == agent1.lowercased())
        #expect(!validator.isMasterScoped(audience: audience))
        #expect(validator.isMasterScoped(audience: TestKeys.aliceAddress))
    }

    @Test func unknownAgentAudience_stillRejected() throws {
        let agent0 = try AgentKey.deriveAddress(masterKey: TestKeys.alicePrivateKey, index: 0)
        let agent9 = try AgentKey.deriveAddress(masterKey: TestKeys.alicePrivateKey, index: 9)
        let agent9Key = AgentKey.derive(masterKey: TestKeys.alicePrivateKey, index: 9)

        let validator = APIKeyValidator(
            agentAddresses: [agent0],
            masterAddress: TestKeys.aliceAddress,
            effectiveWhitelist: [TestKeys.aliceAddress.lowercased(), agent9.lowercased()],
            revocationSnapshot: RevocationSnapshot(revokedKeys: [], counterThresholds: [:]),
            hasKeys: true
        )

        let token = try TokenBuilder.build(privateKey: agent9Key, iss: agent9, aud: agent9)
        guard case .invalid(let reason) = validator.validate(rawKey: token) else {
            Issue.record("Audience outside the accepted set must be rejected")
            return
        }
        #expect(reason.contains("Audience"))
    }
}

// MARK: - Route-Level Agent Scoping

struct AgentScopeRejectionTests {
    /// All cases in one test: `AgentIdentityRegistry` is a process-global
    /// singleton, so the scenarios run sequentially against one snapshot.
    /// The HTTP-server test lease serializes this against the server tests
    /// (including the `/agents/{address}/run` E2E) that read the same
    /// registry, so a parallel suite can't swap the snapshot mid-assertion.
    @Test func scopeEnforcement() async {
        let lease = await HTTPServerTestLock.shared.acquire()
        defer { Task { await lease.release() } }

        let agentA = UUID()
        let agentB = UUID()
        let addrA = "0xaaaa000000000000000000000000000000000001"
        let addrB = "0xbbbb000000000000000000000000000000000002"
        AgentIdentityRegistry.shared.update(
            addresses: [addrA, addrB],
            indices: [0, 1],
            addressByAgentId: [agentA: addrA, agentB: addrB]
        )

        // Reverse lookup (address → agent UUID) is what lets
        // `/agents/{address}/run` accept the crypto address a paired peer
        // knows; it must round-trip case-insensitively and fail closed on a
        // mapping it has never seen.
        #expect(AgentIdentityRegistry.shared.agentId(forAddress: addrA) == agentA)
        #expect(AgentIdentityRegistry.shared.agentId(forAddress: addrA.uppercased()) == agentA)
        #expect(AgentIdentityRegistry.shared.agentId(forAddress: addrB) == agentB)
        #expect(
            AgentIdentityRegistry.shared.agentId(
                forAddress: "0xcccc000000000000000000000000000000000003"
            ) == nil
        )

        // No recorded audience (loopback / public route): unrestricted.
        #expect(
            HTTPHandler.agentScopeRejection(
                forAgentId: agentA,
                authedAudience: nil,
                authedScopeIsMaster: false
            ) == nil
        )

        // Master-scoped key: unrestricted.
        #expect(
            HTTPHandler.agentScopeRejection(
                forAgentId: agentA,
                authedAudience: "0xmaster",
                authedScopeIsMaster: true
            ) == nil
        )

        // Agent-scoped key reaching its own agent: allowed.
        #expect(
            HTTPHandler.agentScopeRejection(
                forAgentId: agentA,
                authedAudience: addrA,
                authedScopeIsMaster: false
            ) == nil
        )

        // Agent-scoped key reaching a DIFFERENT agent: rejected.
        let cross = HTTPHandler.agentScopeRejection(
            forAgentId: agentB,
            authedAudience: addrA,
            authedScopeIsMaster: false
        )
        #expect(cross?.code == "agent_scope_denied")

        // Unknown agent mapping: fail closed.
        let unknown = HTTPHandler.agentScopeRejection(
            forAgentId: UUID(),
            authedAudience: addrA,
            authedScopeIsMaster: false
        )
        #expect(unknown?.code == "agent_scope_denied")
    }
}

// MARK: - Relay Stream UTF-8 Chunking

struct RelayStreamChunkingTests {
    @Test func takeUTF8Prefix_passesPlainASCII() {
        var data = Data("data: {\"x\":1}\n\n".utf8)
        let chunk = RelayTunnelManager.takeUTF8Prefix(&data)
        #expect(chunk == "data: {\"x\":1}\n\n")
        #expect(data.isEmpty)
    }

    @Test func takeUTF8Prefix_holdsBackSplitMultibyteChar() {
        // "é" is 0xC3 0xA9. Split it across two flushes.
        let full = Data("ab\u{00E9}".utf8)  // 61 62 C3 A9
        var firstHalf = full.prefix(3)  // 61 62 C3 — dangling lead byte

        var buffer = Data(firstHalf)
        let chunk = RelayTunnelManager.takeUTF8Prefix(&buffer)
        #expect(chunk == "ab")
        #expect(buffer == Data([0xC3]))

        // The remainder arrives; combined bytes decode cleanly.
        buffer.append(full.suffix(1))
        let rest = RelayTunnelManager.takeUTF8Prefix(&buffer)
        #expect(rest == "\u{00E9}")
        #expect(buffer.isEmpty)
        firstHalf.removeAll()
    }

    @Test func takeUTF8Prefix_multiLineSSEEventSurvivesVerbatim() {
        // The old `bytes.lines` implementation destroyed multi-line events.
        let event = "event: ping\ndata: line1\ndata: line2\n\n"
        var data = Data(event.utf8)
        #expect(RelayTunnelManager.takeUTF8Prefix(&data) == event)
    }
}

// MARK: - Advertiser Name Limits

@MainActor
struct BonjourAdvertiserNameTests {
    @Test func instanceName_fitsDNSSDLimit_andKeepsUUID() {
        let agent = Agent(name: String(repeating: "🦖", count: 40))
        let name = BonjourAdvertiser.instanceName(for: agent)
        #expect(name.utf8.count <= BonjourAdvertiser.maxInstanceNameBytes)
        #expect(name.hasSuffix("@\(agent.id.uuidString)"))
    }

    @Test func instanceName_shortNameUnchanged() {
        let agent = Agent(name: "Osaurus")
        let name = BonjourAdvertiser.instanceName(for: agent)
        #expect(name == "Osaurus@\(agent.id.uuidString)")
    }

    @Test func truncateUTF8_neverSplitsCharacters() {
        // Each 🦖 is 4 bytes; a 6-byte budget must keep exactly one.
        let truncated = BonjourAdvertiser.truncateUTF8("🦖🦖🦖", maxBytes: 6)
        #expect(truncated == "🦖")
        #expect(BonjourAdvertiser.truncateUTF8("abc", maxBytes: 10) == "abc")
        #expect(BonjourAdvertiser.truncateUTF8("abc", maxBytes: 0) == "")
    }
}
