//
//  SecureChannelTests.swift
//  OsaurusCoreTests
//
//  Unit tests for the Osaurus Secure Channel v1 handshake, key schedule,
//  and AEAD framing (replay / reorder / truncation / tamper resistance).
//

import CryptoKit
import Foundation
import Testing

@testable import OsaurusCore

private func makeSessionPair(
    agentKey: Data,
    expectedAddress: String
) throws -> (client: SecureChannelSession, server: SecureChannelSession) {
    let (clientKey, hello) = SecureChannel.makeClientHello(agentAddress: expectedAddress)
    let (serverSession, serverHello) = try SecureChannel.establishServerSession(hello: hello) {
        try signSecureChannelPayload($0, privateKey: agentKey)
    }
    let clientSession = try SecureChannel.establishClientSession(
        hello: hello,
        ephemeralKey: clientKey,
        serverHello: serverHello,
        expectedAgentAddress: expectedAddress
    )
    return (clientSession, serverSession)
}

struct SecureChannelHandshakeTests {
    private var agentKey: Data { AgentKey.derive(masterKey: TestKeys.alicePrivateKey, index: 0) }
    private var agentAddress: String {
        try! AgentKey.deriveAddress(masterKey: TestKeys.alicePrivateKey, index: 0)
    }

    @Test func handshake_roundtrip_establishesMatchingKeys() throws {
        let (client, server) = try makeSessionPair(agentKey: agentKey, expectedAddress: agentAddress)
        #expect(client.sid == server.sid)

        let inner = Data("hello over the channel".utf8)
        let (call, requestSeq) = try client.sealCall(innerRequest: inner)
        let (opened, serverSeq) = try server.openCall(call)
        #expect(opened == inner)
        #expect(serverSeq == requestSeq)

        // Response direction.
        let sealer = server.makeResponseSealer(requestSeq: requestSeq)
        let opener = client.makeResponseOpener(requestSeq: requestSeq)
        let frame = try sealer.seal(Data("response".utf8), fin: true)
        let (plaintext, fin) = try opener.open(frame)
        #expect(plaintext == Data("response".utf8))
        #expect(fin)
        #expect(opener.finished)
    }

    @Test func handshake_wrongIdentity_rejected() throws {
        let (clientKey, hello) = SecureChannel.makeClientHello(agentAddress: agentAddress)
        // Server signs with Bob's key, but the client pinned Alice's agent.
        let (_, serverHello) = try SecureChannel.establishServerSession(hello: hello) {
            try signSecureChannelPayload($0, privateKey: TestKeys.bobPrivateKey)
        }
        #expect(throws: SecureChannelError.identityMismatch) {
            _ = try SecureChannel.establishClientSession(
                hello: hello,
                ephemeralKey: clientKey,
                serverHello: serverHello,
                expectedAgentAddress: agentAddress
            )
        }
    }

    @Test func handshake_tamperedTranscript_rejected() throws {
        let (clientKey, hello) = SecureChannel.makeClientHello(agentAddress: agentAddress)
        let (_, serverHello) = try SecureChannel.establishServerSession(hello: hello) {
            try signSecureChannelPayload($0, privateKey: agentKey)
        }
        // A MITM swaps in its own ephemeral key: the signature no longer
        // covers what the client sees.
        let mitmKey = Curve25519.KeyAgreement.PrivateKey()
        let tampered = SecureChannel.ServerHello(
            v: serverHello.v,
            sid: serverHello.sid,
            encPub: mitmKey.publicKey.rawRepresentation.base64urlEncoded,
            expiresAt: serverHello.expiresAt,
            signature: serverHello.signature
        )
        #expect(throws: SecureChannelError.identityMismatch) {
            _ = try SecureChannel.establishClientSession(
                hello: hello,
                ephemeralKey: clientKey,
                serverHello: tampered,
                expectedAgentAddress: agentAddress
            )
        }
    }

    @Test func handshake_unsupportedVersion_rejected() throws {
        let (_, hello) = SecureChannel.makeClientHello(agentAddress: agentAddress)
        let badHello = SecureChannel.ClientHello(
            v: 99,
            agentAddress: hello.agentAddress,
            encPub: hello.encPub,
            nonce: hello.nonce
        )
        #expect(throws: SecureChannelError.unsupportedVersion) {
            _ = try SecureChannel.establishServerSession(hello: badHello) {
                try signSecureChannelPayload($0, privateKey: agentKey)
            }
        }
    }

    @Test func handshake_garbageClientKey_rejected() throws {
        let hello = SecureChannel.ClientHello(v: 1, agentAddress: "0xabc", encPub: "!!!", nonce: "abc")
        #expect(throws: SecureChannelError.malformedHandshake) {
            _ = try SecureChannel.establishServerSession(hello: hello) {
                try signSecureChannelPayload($0, privateKey: agentKey)
            }
        }
    }
}

struct SecureChannelFramingTests {
    private var agentKey: Data { AgentKey.derive(masterKey: TestKeys.alicePrivateKey, index: 0) }
    private var agentAddress: String {
        try! AgentKey.deriveAddress(masterKey: TestKeys.alicePrivateKey, index: 0)
    }

    @Test func replayedCall_rejected() throws {
        let (client, server) = try makeSessionPair(agentKey: agentKey, expectedAddress: agentAddress)
        let (call, _) = try client.sealCall(innerRequest: Data("once".utf8))
        _ = try server.openCall(call)
        // Same captured call again: replay window must reject it.
        #expect(throws: SecureChannelError.replayedFrame) {
            _ = try server.openCall(call)
        }
    }

    @Test func outOfOrderCalls_withinWindow_accepted() throws {
        let (client, server) = try makeSessionPair(agentKey: agentKey, expectedAddress: agentAddress)
        let (first, _) = try client.sealCall(innerRequest: Data("a".utf8))
        let (second, _) = try client.sealCall(innerRequest: Data("b".utf8))
        // Concurrent calls may arrive reordered; both must be accepted once.
        _ = try server.openCall(second)
        _ = try server.openCall(first)
        #expect(throws: SecureChannelError.replayedFrame) {
            _ = try server.openCall(first)
        }
    }

    @Test func tamperedCallCiphertext_rejected() throws {
        let (client, server) = try makeSessionPair(agentKey: agentKey, expectedAddress: agentAddress)
        let (call, _) = try client.sealCall(innerRequest: Data("payload".utf8))
        var raw = Data(base64urlEncoded: call.ct)!
        raw[raw.startIndex] ^= 0xFF
        let tampered = SecureChannel.CallRequest(
            v: call.v,
            sid: call.sid,
            seq: call.seq,
            ct: raw.base64urlEncoded
        )
        #expect(throws: SecureChannelError.openFailed) {
            _ = try server.openCall(tampered)
        }
    }

    @Test func callFromDifferentSession_rejected() throws {
        let (clientA, _) = try makeSessionPair(agentKey: agentKey, expectedAddress: agentAddress)
        let (_, serverB) = try makeSessionPair(agentKey: agentKey, expectedAddress: agentAddress)
        let (call, _) = try clientA.sealCall(innerRequest: Data("cross".utf8))
        // Different session keys: must not decrypt.
        #expect(throws: SecureChannelError.openFailed) {
            _ = try serverB.openCall(call)
        }
    }

    @Test func responseFrames_strictOrder_finAuthenticated() throws {
        let (client, server) = try makeSessionPair(agentKey: agentKey, expectedAddress: agentAddress)
        let (call, requestSeq) = try client.sealCall(innerRequest: Data("req".utf8))
        _ = try server.openCall(call)

        let sealer = server.makeResponseSealer(requestSeq: requestSeq)
        let f0 = try sealer.seal(Data("one".utf8))
        let f1 = try sealer.seal(Data("two".utf8))
        let f2 = try sealer.seal(Data("end".utf8), fin: true)

        // Reordered delivery rejected.
        let reorderedOpener = client.makeResponseOpener(requestSeq: requestSeq)
        #expect(throws: SecureChannelError.outOfOrderFrame) {
            _ = try reorderedOpener.open(f1)
        }

        // In-order delivery succeeds and surfaces fin.
        let opener = client.makeResponseOpener(requestSeq: requestSeq)
        #expect(try opener.open(f0).plaintext == Data("one".utf8))
        #expect(try opener.open(f1).plaintext == Data("two".utf8))
        let (last, fin) = try opener.open(f2)
        #expect(last == Data("end".utf8))
        #expect(fin)

        // Frames after fin rejected (no smuggling past end-of-stream).
        #expect(throws: SecureChannelError.outOfOrderFrame) {
            _ = try opener.open(f2)
        }
    }

    @Test func responseFrame_finBitStripped_failsAuth() throws {
        let (client, server) = try makeSessionPair(agentKey: agentKey, expectedAddress: agentAddress)
        let (call, requestSeq) = try client.sealCall(innerRequest: Data("req".utf8))
        _ = try server.openCall(call)

        let sealer = server.makeResponseSealer(requestSeq: requestSeq)
        let finFrame = try sealer.seal(Data("end".utf8), fin: true)
        // Strip the fin marker: AAD no longer matches, so the frame fails
        // authentication instead of silently becoming a non-final frame.
        let stripped = SecureChannel.Frame(seq: finFrame.seq, ct: finFrame.ct, fin: nil)
        let opener = client.makeResponseOpener(requestSeq: requestSeq)
        #expect(throws: SecureChannelError.openFailed) {
            _ = try opener.open(stripped)
        }
    }

    @Test func responseFrames_crossCallReplay_rejected() throws {
        let (client, server) = try makeSessionPair(agentKey: agentKey, expectedAddress: agentAddress)
        let (callA, seqA) = try client.sealCall(innerRequest: Data("a".utf8))
        let (callB, seqB) = try client.sealCall(innerRequest: Data("b".utf8))
        _ = try server.openCall(callA)
        _ = try server.openCall(callB)

        // Frame 0 of call A replayed into call B's stream: per-call derived
        // keys make it undecryptable.
        let frameA = try server.makeResponseSealer(requestSeq: seqA).seal(Data("for A".utf8), fin: true)
        let openerB = client.makeResponseOpener(requestSeq: seqB)
        #expect(throws: SecureChannelError.openFailed) {
            _ = try openerB.open(frameA)
        }
    }

    @Test func sealerRefusesFramesAfterFin() throws {
        let (client, server) = try makeSessionPair(agentKey: agentKey, expectedAddress: agentAddress)
        let (call, requestSeq) = try client.sealCall(innerRequest: Data("req".utf8))
        _ = try server.openCall(call)
        let sealer = server.makeResponseSealer(requestSeq: requestSeq)
        _ = try sealer.seal(Data("end".utf8), fin: true)
        #expect(throws: SecureChannelError.sealFailed) {
            _ = try sealer.seal(Data("extra".utf8))
        }
    }

    @Test func innerRequestRoundtrip() throws {
        let (client, server) = try makeSessionPair(agentKey: agentKey, expectedAddress: agentAddress)
        let inner = SecureChannel.InnerRequest(
            method: "POST",
            path: "/agents/00000000-0000-0000-0000-000000000000/run",
            authorization: "Bearer osk-v1.payload.sig",
            accept: "text/event-stream",
            contentType: "application/json",
            body: Data(#"{"messages":[]}"#.utf8).base64urlEncoded
        )
        let encoded = try JSONEncoder().encode(inner)
        let (call, _) = try client.sealCall(innerRequest: encoded)
        let (plaintext, _) = try server.openCall(call)
        let decoded = try JSONDecoder().decode(SecureChannel.InnerRequest.self, from: plaintext)
        #expect(decoded == inner)
    }
}
