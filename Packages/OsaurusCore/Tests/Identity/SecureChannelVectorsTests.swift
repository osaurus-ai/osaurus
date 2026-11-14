//
//  SecureChannelVectorsTests.swift
//  OsaurusCoreTests
//
//  Known-answer vectors for Secure Channel v1. Two implementations exist —
//  this Swift one and the TypeScript client in `n8n-nodes-osaurus` — and the
//  four places they can silently disagree (canonical transcript, domain hash
//  + address recovery, HKDF key schedule, AEAD framing/AAD) are pinned here
//  from fixed keys. The same JSON file is committed in the node repo under
//  `test/vectors/secure-channel-v1-vectors.json`; both CIs check against it.
//
//  Regenerate after an intentional protocol change:
//
//      OSAURUS_WRITE_SC_VECTORS=1 swift test --filter SecureChannelVectorsTests
//
//  then copy the file into the node repo.
//

import CryptoKit
import Foundation
import Testing

@testable import OsaurusCore

struct SecureChannelVectorsTests {
    // MARK: Fixed inputs

    /// Alice's agent key at index 0 — the identity the server signs with.
    private static let agentKey = AgentKey.derive(masterKey: TestKeys.alicePrivateKey, index: 0)
    private static let agentAddress = try! AgentKey.deriveAddress(masterKey: TestKeys.alicePrivateKey, index: 0)

    private static let clientEphemeralPrivate = Data(
        hexEncoded: "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")!
    private static let serverEphemeralPrivate = Data(
        hexEncoded: "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")!
    private static let nonce = Data(hexEncoded: "000102030405060708090a0b0c0d0e0f")!
    private static let sid = Data(hexEncoded: "f0e1d2c3b4a5968778695a4b3c2d1e0f")!
    private static let expiresAt = 1_800_000_000

    private static let innerRequestJSON =
        #"{"method":"GET","path":"/channels/n8n/n8n-local/ping","accept":"application/json","headers":{"X-Osaurus-Channel-Signature":"sha256=b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad"}}"#
    private static let innerResponseJSON =
        #"{"status":200,"contentType":"application/json; charset=utf-8","body":"eyJzdGF0dXMiOiJvayJ9"}"#
    private static let streamChunks = ["data: {\"n\":1}\n\n", "data: {\"n\":2}\n\n"]

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/secure-channel-v1-vectors.json")
    }

    // MARK: Vector construction

    private struct Vectors {
        var json: [String: Any]
    }

    private static func build() throws -> Vectors {
        let clientKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: clientEphemeralPrivate)
        let serverKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: serverEphemeralPrivate)

        let hello = SecureChannel.ClientHello(
            v: SecureChannel.version,
            agentAddress: agentAddress.lowercased(),
            encPub: clientKey.publicKey.rawRepresentation.base64urlEncoded,
            nonce: nonce.base64urlEncoded
        )
        let unsigned = SecureChannel.ServerHello(
            v: SecureChannel.version,
            sid: sid.base64urlEncoded,
            encPub: serverKey.publicKey.rawRepresentation.base64urlEncoded,
            expiresAt: expiresAt,
            signature: ""
        )
        let transcript = SecureChannel.transcriptPayload(hello: hello, serverHello: unsigned)
        let signature = try signSecureChannelPayload(transcript, privateKey: agentKey)
        let serverHello = SecureChannel.ServerHello(
            v: unsigned.v,
            sid: unsigned.sid,
            encPub: unsigned.encPub,
            expiresAt: unsigned.expiresAt,
            signature: "0x" + signature.hexEncodedString
        )

        let domainHeader = Data("\u{19}Osaurus Secure Channel:\n\(transcript.count)".utf8)
        let domainHash = Keccak256.hash(data: domainHeader + transcript)

        let shared = try clientKey.sharedSecretFromKeyAgreement(with: serverKey.publicKey)
        let sharedBytes = shared.withUnsafeBytes { Data($0) }
        let (c2s, s2c) = SecureChannel.deriveKeys(sharedSecret: shared, transcript: transcript)

        // Client seals request seq 1.
        let client = SecureChannelSession(
            role: .client,
            sid: serverHello.sid,
            sendKey: c2s,
            receiveKey: s2c,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(expiresAt))
        )
        let (call, requestSeq) = try client.sealCall(innerRequest: Data(innerRequestJSON.utf8))

        // Server seals a buffered response (single fin frame) …
        let server = SecureChannelSession(
            role: .server,
            sid: serverHello.sid,
            sendKey: s2c,
            receiveKey: c2s,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(expiresAt))
        )
        let bufferedSealer = server.makeResponseSealer(requestSeq: requestSeq)
        let bufferedFrame = try bufferedSealer.seal(Data(innerResponseJSON.utf8), fin: true)

        // … and, for request seq 2, an SSE stream: two data frames + empty fin.
        let (streamCall, streamSeq) = try client.sealCall(innerRequest: Data(innerRequestJSON.utf8))
        let streamSealer = server.makeResponseSealer(requestSeq: streamSeq)
        var streamFrames: [[String: Any]] = []
        for chunk in streamChunks {
            let frame = try streamSealer.seal(Data(chunk.utf8), fin: false)
            streamFrames.append([
                "seq": frame.seq, "plaintext": chunk, "fin": false,
                "aad": String(
                    decoding: SecureChannel.responseAAD(
                        sid: serverHello.sid, requestSeq: streamSeq, seq: frame.seq, fin: false), as: UTF8.self),
                "ct": frame.ct,
            ])
        }
        let finFrame = try streamSealer.seal(Data(), fin: true)
        streamFrames.append([
            "seq": finFrame.seq, "plaintext": "", "fin": true,
            "aad": String(
                decoding: SecureChannel.responseAAD(
                    sid: serverHello.sid, requestSeq: streamSeq, seq: finFrame.seq, fin: true), as: UTF8.self),
            "ct": finFrame.ct,
        ])

        let responseKey = SecureChannel.responseKey(base: s2c, requestSeq: requestSeq)
        let streamResponseKey = SecureChannel.responseKey(base: s2c, requestSeq: streamSeq)

        let json: [String: Any] = [
            "version": SecureChannel.version,
            "domain": "osaurus-sc1",
            "signingDomainPrefix": "Osaurus Secure Channel",
            "agent": [
                "privateKeyHex": agentKey.hexEncodedString,
                "address": agentAddress,
            ],
            "handshake": [
                "clientEphemeralPrivateHex": clientEphemeralPrivate.hexEncodedString,
                "serverEphemeralPrivateHex": serverEphemeralPrivate.hexEncodedString,
                "clientHello": [
                    "v": hello.v, "agentAddress": hello.agentAddress, "encPub": hello.encPub, "nonce": hello.nonce,
                ],
                "serverHello": [
                    "v": serverHello.v, "sid": serverHello.sid, "encPub": serverHello.encPub,
                    "expiresAt": serverHello.expiresAt, "signature": serverHello.signature,
                ],
                "transcript": String(decoding: transcript, as: UTF8.self),
                "domainHashHex": domainHash.hexEncodedString,
                "sharedSecretHex": sharedBytes.hexEncodedString,
                "clientToServerKeyHex": keyHex(c2s),
                "serverToClientKeyHex": keyHex(s2c),
            ],
            "call": [
                "requestSeq": requestSeq,
                "innerRequest": innerRequestJSON,
                "nonceHex": nonceHex(requestSeq),
                "aad": String(decoding: SecureChannel.requestAAD(sid: serverHello.sid, seq: requestSeq), as: UTF8.self),
                "ct": call.ct,
                "body": ["v": call.v, "sid": call.sid, "seq": call.seq, "ct": call.ct],
            ],
            "bufferedResponse": [
                "requestSeq": requestSeq,
                "responseKeyHex": keyHex(responseKey),
                "frame": [
                    "seq": bufferedFrame.seq, "fin": true, "ct": bufferedFrame.ct,
                    "aad": String(
                        decoding: SecureChannel.responseAAD(
                            sid: serverHello.sid, requestSeq: requestSeq, seq: bufferedFrame.seq, fin: true),
                        as: UTF8.self),
                    "plaintext": innerResponseJSON,
                ],
            ],
            "streamResponse": [
                "requestSeq": streamSeq,
                "callCt": streamCall.ct,
                "responseKeyHex": keyHex(streamResponseKey),
                "frames": streamFrames,
            ],
        ]
        return Vectors(json: json)
    }

    private static func keyHex(_ key: SymmetricKey) -> String {
        key.withUnsafeBytes { Data($0) }.hexEncodedString
    }

    private static func nonceHex(_ seq: UInt64) -> String {
        var bytes = Data(repeating: 0, count: 4)
        withUnsafeBytes(of: seq.bigEndian) { bytes.append(contentsOf: $0) }
        return bytes.hexEncodedString
    }

    private static func serialize(_ vectors: Vectors) throws -> Data {
        try JSONSerialization.data(withJSONObject: vectors.json, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: Tests

    @Test func fixtureMatchesTheLiveImplementation() throws {
        let built = try Self.build()
        let builtData = try Self.serialize(built)

        if ProcessInfo.processInfo.environment["OSAURUS_WRITE_SC_VECTORS"] == "1" {
            try FileManager.default.createDirectory(
                at: Self.fixtureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (builtData + Data("\n".utf8)).write(to: Self.fixtureURL)
        }

        let onDisk = try Data(contentsOf: Self.fixtureURL)
        let expected = try #require(try JSONSerialization.jsonObject(with: onDisk) as? [String: Any])
        let actual = try #require(try JSONSerialization.jsonObject(with: builtData) as? [String: Any])
        #expect(
            NSDictionary(dictionary: expected) == NSDictionary(dictionary: actual),
            "Secure Channel vectors drifted from the committed fixture. If the protocol change is intentional, regenerate with OSAURUS_WRITE_SC_VECTORS=1 and copy the file into n8n-nodes-osaurus."
        )
    }

    /// The fixture's server hello must be accepted by the real client-side
    /// verifier (signature recovers to the pinned address, keys match).
    @Test func fixtureHandshakeVerifiesAndOpensFrames() throws {
        let onDisk = try Data(contentsOf: Self.fixtureURL)
        let root = try #require(try JSONSerialization.jsonObject(with: onDisk) as? [String: Any])
        let handshake = try #require(root["handshake"] as? [String: Any])
        let helloJSON = try #require(handshake["clientHello"] as? [String: Any])
        let serverJSON = try #require(handshake["serverHello"] as? [String: Any])
        let agent = try #require(root["agent"] as? [String: Any])

        let hello = SecureChannel.ClientHello(
            v: helloJSON["v"] as! Int,
            agentAddress: helloJSON["agentAddress"] as! String,
            encPub: helloJSON["encPub"] as! String,
            nonce: helloJSON["nonce"] as! String
        )
        let serverHello = SecureChannel.ServerHello(
            v: serverJSON["v"] as! Int,
            sid: serverJSON["sid"] as! String,
            encPub: serverJSON["encPub"] as! String,
            expiresAt: serverJSON["expiresAt"] as! Int,
            signature: serverJSON["signature"] as! String
        )
        let clientKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data(hexEncoded: handshake["clientEphemeralPrivateHex"] as! String)!)

        let session = try SecureChannel.establishClientSession(
            hello: hello,
            ephemeralKey: clientKey,
            serverHello: serverHello,
            expectedAgentAddress: agent["address"] as! String
        )
        #expect(session.sid == serverHello.sid)

        // Open the buffered response frame with the fixture's per-call key path.
        let buffered = try #require(root["bufferedResponse"] as? [String: Any])
        let frameJSON = try #require(buffered["frame"] as? [String: Any])
        let requestSeq = UInt64(buffered["requestSeq"] as! Int)
        let opener = session.makeResponseOpener(requestSeq: requestSeq)
        let (plaintext, fin) = try opener.open(
            SecureChannel.Frame(
                seq: UInt64(frameJSON["seq"] as! Int),
                ct: frameJSON["ct"] as! String,
                fin: frameJSON["fin"] as? Bool
            )
        )
        #expect(fin)
        #expect(String(decoding: plaintext, as: UTF8.self) == frameJSON["plaintext"] as! String)

        // A wrong pinned address must be rejected.
        #expect(throws: SecureChannelError.identityMismatch) {
            _ = try SecureChannel.establishClientSession(
                hello: hello,
                ephemeralKey: clientKey,
                serverHello: serverHello,
                expectedAgentAddress: TestKeys.bobAddress
            )
        }
    }
}
