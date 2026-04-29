//
//  HPKEEncryptionTests.swift
//  osaurusTests
//
//  Round-trip and tamper-resistance tests for the HPKE relay-encryption
//  layer. Exercises the same client/server APIs that
//  RemoteProviderService and HTTPHandler use in production.
//

import CryptoKit
import Foundation
import Testing

@testable import OsaurusCore

// Tests share `HPKEKeyStore.shared` and `warmUp_isDeterministicAcrossCalls`
// rotates that singleton's keypair, so parallel execution would race
// against the round-trip tests. Run serially.
@Suite(.serialized)
struct HPKEEncryptionTests {

    // MARK: - Helpers

    /// Run the full server-side decode path against a wire-shaped header
    /// dictionary and base64-encoded body. Mirrors what `HTTPHandler`
    /// does at the top of `channelRead.end` for an inbound request.
    private func decodeOnServer(
        headers: [String: String],
        method: String,
        path: String,
        rawBody: Data,
        replayWindow: TimeInterval = 60
    ) throws -> (HPKEServerContext, Data)? {
        let lookup: (String) -> String? = { name in
            headers.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value
        }
        guard let res = try HPKEServerDecoder.decodeIfNeeded(
            headerLookup: lookup,
            method: method,
            path: path,
            rawBody: rawBody,
            replayWindow: replayWindow
        ) else { return nil }
        return (res.context, res.plaintextBody)
    }

    // MARK: - Tests

    @Test func requestRoundTrip_recoversPlaintext() throws {
        let recipientPub = HPKEKeyStore.shared.publicKeyBytes
        let body = Data("""
            {"model":"foo","messages":[{"role":"user","content":"ping"}]}
            """.utf8)

        let client = try HPKEClientContext(
            recipientPublicKey: recipientPub,
            method: "POST",
            path: "/v1/chat/completions"
        )
        let sealed = try client.sealRequestBody(body)
        let wireBody = Data(sealed.base64urlEncoded.utf8)

        let result = try decodeOnServer(
            headers: client.requestHeaders,
            method: client.method,
            path: client.path,
            rawBody: wireBody
        )
        let unwrapped = try #require(result)
        #expect(unwrapped.1 == body)
    }

    @Test func tamperedAAD_failsToOpen() throws {
        let recipientPub = HPKEKeyStore.shared.publicKeyBytes
        let body = Data("hello".utf8)

        let client = try HPKEClientContext(
            recipientPublicKey: recipientPub,
            method: "POST",
            path: "/v1/chat/completions"
        )
        let sealed = try client.sealRequestBody(body)
        let wireBody = Data(sealed.base64urlEncoded.utf8)

        // Server sees a different path than the client signed for.
        #expect(throws: HPKEError.self) {
            try self.decodeOnServer(
                headers: client.requestHeaders,
                method: client.method,
                path: "/some/other/path",
                rawBody: wireBody
            )
        }
    }

    @Test func staleTimestamp_isRejected() throws {
        let recipientPub = HPKEKeyStore.shared.publicKeyBytes

        let client = try HPKEClientContext(
            recipientPublicKey: recipientPub,
            method: "POST",
            path: "/x"
        )
        var headers = client.requestHeaders
        // Set timestamp far enough in the past to fall outside the window.
        headers[HPKEHeader.timestamp] = String(Int(Date().timeIntervalSince1970) - 300)

        let sealed = try client.sealRequestBody(Data("body".utf8))
        let wireBody = Data(sealed.base64urlEncoded.utf8)

        let thrown = #expect(throws: HPKEError.self) {
            try self.decodeOnServer(
                headers: headers,
                method: client.method,
                path: client.path,
                rawBody: wireBody,
                replayWindow: 60
            )
        }
        if case .timestampOutOfWindow = thrown { } else {
            Issue.record("expected timestampOutOfWindow, got \(String(describing: thrown))")
        }
    }

    @Test func nonStreamingResponse_roundTrips() throws {
        let recipientPub = HPKEKeyStore.shared.publicKeyBytes
        let client = try HPKEClientContext(
            recipientPublicKey: recipientPub,
            method: "POST",
            path: "/v1/chat/completions"
        )
        let reqBody = Data("ping".utf8)
        let sealed = try client.sealRequestBody(reqBody)
        let wireBody = Data(sealed.base64urlEncoded.utf8)

        let unwrapped = try #require(try decodeOnServer(
            headers: client.requestHeaders,
            method: client.method,
            path: client.path,
            rawBody: wireBody
        ))
        let serverCtx = unwrapped.0

        // Server-side response sealing
        let respPlain = Data("""
            {"choices":[{"message":{"role":"assistant","content":"pong"}}]}
            """.utf8)
        let sealedResp = try serverCtx.sealNonStreaming(respPlain)

        // Client opens
        let opened = try client.openResponseBody(sealedResp)
        #expect(opened == respPlain)
    }

    @Test func streamChunks_preserveOrderAndDecryptIndependently() throws {
        let recipientPub = HPKEKeyStore.shared.publicKeyBytes
        let client = try HPKEClientContext(
            recipientPublicKey: recipientPub,
            method: "POST",
            path: "/v1/chat/completions"
        )
        let sealed = try client.sealRequestBody(Data("req".utf8))
        let wireBody = Data(sealed.base64urlEncoded.utf8)

        let unwrapped = try #require(try decodeOnServer(
            headers: client.requestHeaders,
            method: client.method,
            path: client.path,
            rawBody: wireBody
        ))
        let serverCtx = unwrapped.0

        // Several SSE events sealed in order.
        let events: [Data] = [
            Data("data: {\"delta\":\"a\"}\n\n".utf8),
            Data("data: {\"delta\":\"bc\"}\n\n".utf8),
            Data("event: foo\ndata: {\"x\":1}\n\n".utf8),
            Data("data: [DONE]\n\n".utf8),
        ]
        var encoded: [(UInt64, String)] = []
        for e in events {
            encoded.append(try serverCtx.sealStreamChunk(e))
        }

        // Counters are monotonic.
        #expect(encoded.map { $0.0 } == [0, 1, 2, 3])

        // Client opens each one independently and gets the original bytes back.
        for (i, (counter, b64)) in encoded.enumerated() {
            let opened = try client.openStreamChunk("\(counter):\(b64)")
            #expect(opened.counter == UInt64(i))
            #expect(opened.plaintext == events[i])
        }
    }

    @Test func warmUp_isDeterministicAcrossCalls() throws {
        let store = HPKEKeyStore.shared
        // Reset so we don't read a leftover key from another test.
        store.reset()

        // Two distinct 32-byte master-key candidates.
        var ms1 = Data(count: 32)
        var ms2 = Data(count: 32)
        _ = ms1.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 32, ptr.baseAddress!)
        }
        _ = ms2.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 32, ptr.baseAddress!)
        }

        store.warmUp(masterKey: ms1)
        let pub1 = store.publicKeyBytes

        // Re-warming with the same master key reproduces the same public key.
        store.warmUp(masterKey: ms1)
        let pub1again = store.publicKeyBytes
        #expect(pub1 == pub1again)

        // Different master key → different public key.
        store.warmUp(masterKey: ms2)
        let pub2 = store.publicKeyBytes
        #expect(pub1 != pub2)

        // Reset returns the store to ephemeral mode.
        store.reset()
    }

    @Test func keyMismatch_failsToOpen() throws {
        // Client uses a randomly-chosen recipient pub key that doesn't
        // match any server's private key.
        let foreign = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let client = try HPKEClientContext(
            recipientPublicKey: foreign,
            method: "POST",
            path: "/x"
        )
        let sealed = try client.sealRequestBody(Data("hi".utf8))
        let wireBody = Data(sealed.base64urlEncoded.utf8)

        // The shared HPKEKeyStore has its own keypair; encapsulation
        // built for `foreign` will not yield a context that can open.
        let thrown = #expect(throws: HPKEError.self) {
            try self.decodeOnServer(
                headers: client.requestHeaders,
                method: client.method,
                path: client.path,
                rawBody: wireBody
            )
        }
        if case .openFailed = thrown { } else {
            Issue.record("expected openFailed, got \(String(describing: thrown))")
        }
    }
}
