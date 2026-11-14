//
//  OwnerDeviceAccessHostTests.swift
//  OsaurusCoreTests
//
//  Host-side owner redeem: a device holding the SAME master as this host
//  proves it by signing the host's nonce with the master key and gets an
//  agent-scoped osk-v1 key — no router, roster, or invite. These tests pin
//  the state machine and every rejection gate without a socket. The mint
//  itself needs a real Keychain; under `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS`
//  a fully valid redeem stops at `.mintFailed`, which proves every gate
//  before it passed.
//

import CryptoKit
import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Wire shapes

@Suite("Owner redeem wire shapes")
struct OwnerRedeemWireShapeTests {
    @Test func stepOneEnvelope_decodesSnakeCase() throws {
        let json = """
            {"owner_redeem":{"v":1,"agent_address":"0xABC","device_id":"c3d4e5f6","device_name":"iPhone"}}
            """
        let envelope = try JSONDecoder().decode(OwnerPairRedeemEnvelope.self, from: Data(json.utf8))
        #expect(envelope.ownerRedeem.v == 1)
        #expect(envelope.ownerRedeem.agentAddress == "0xABC")
        #expect(envelope.ownerRedeem.deviceId == "c3d4e5f6")
        #expect(envelope.ownerRedeem.deviceName == "iPhone")
        #expect(envelope.ownerRedeem.nonce == nil)
        #expect(envelope.ownerRedeem.walletSignature == nil)
        #expect(envelope.ownerRedeem.encPub == nil)
    }

    @Test func stepTwoEnvelope_decodesSignatureAndEncPub() throws {
        let json = """
            {"owner_redeem":{"v":1,"agent_address":"0xABC","device_id":"c3d4e5f6","nonce":"n1","wallet_signature":"0xdead","encPub":"pk"}}
            """
        let envelope = try JSONDecoder().decode(OwnerPairRedeemEnvelope.self, from: Data(json.utf8))
        #expect(envelope.ownerRedeem.nonce == "n1")
        #expect(envelope.ownerRedeem.walletSignature == "0xdead")
        #expect(envelope.ownerRedeem.encPub == "pk")
        #expect(envelope.ownerRedeem.deviceName == nil)
    }

    @Test func ownerEnvelope_doesNotDecodeAsWorkspaceEnvelope_andViceVersa() {
        let owner = Data(#"{"owner_redeem":{"v":1,"agent_address":"0xABC","device_id":"d"}}"#.utf8)
        let team = Data(#"{"team_redeem":{"v":1,"agent_address":"0xABC","attestation":"t"}}"#.utf8)
        #expect((try? JSONDecoder().decode(WorkspacePairRedeemEnvelope.self, from: owner)) == nil)
        #expect((try? JSONDecoder().decode(OwnerPairRedeemEnvelope.self, from: team)) == nil)
        #expect((try? JSONDecoder().decode(OwnerPairRedeemEnvelope.self, from: owner)) != nil)
    }

    @Test func challengeResponse_encodesOwnerChallengeKey() throws {
        let response = OwnerPairChallengeResponse(ownerChallenge: .init(nonce: "abc", expiresIn: 120))
        let data = try JSONEncoder.osaurusCanonical().encode(response)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let challenge = object?["owner_challenge"] as? [String: Any]
        #expect(challenge?["nonce"] as? String == "abc")
        #expect(challenge?["expires_in"] as? Int == 120)
    }

    @Test func redeemMessage_layoutAndLowercasedAddress() {
        #expect(
            OwnerDeviceAccess.redeemMessage(agentAddress: "0xABCdef", nonce: "N")
                == "osaurus-owner:redeem:0xabcdef:N"
        )
    }

    @Test func requestLogRedaction_hidesDeviceIdAndSignature() {
        let body = Data(
            #"{"owner_redeem":{"v":1,"agent_address":"0xABC","device_id":"c3d4e5f6","nonce":"n","wallet_signature":"0xsig","encPub":"pk"}}"#
                .utf8
        )
        let redacted = HTTPHandler.redactedPairInviteRequestBody(body)
        #expect(!redacted.contains("c3d4e5f6"))
        #expect(!redacted.contains("0xsig"))
        #expect(!redacted.contains("\"pk\""))
        #expect(redacted.contains("0xABC"))
    }
}

// MARK: - Host state machine

@Suite("Owner device access host", .serialized)
struct OwnerDeviceAccessHostTests {
    private let hostedAddress = "0x00000000000000000000000000000000a11ce0a1"
    private let deviceId = "c3d4e5f6"
    /// A well-formed ephemeral recipient key: step two is refused without one.
    private let encPub = PairingKeyEnvelope.generateRecipientKey().publicKeyBase64url

    private func makeHost(wallet: String? = TestKeys.aliceAddress) async -> OwnerDeviceAccessHost {
        let host = OwnerDeviceAccessHost()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("owner-redeem-\(UUID().uuidString)", isDirectory: true)
        await host.setSeams(
            resolveHostWallet: { wallet },
            keyRecordsFileURL: { dir.appendingPathComponent("owner-devices.json") }
        )
        return host
    }

    private func stepOne(
        _ host: OwnerDeviceAccessHost,
        address: String? = nil,
        device: String? = nil
    ) async throws -> String {
        let outcome = await host.handle(
            .init(
                v: 1,
                agentAddress: address ?? hostedAddress,
                deviceId: device ?? deviceId,
                deviceName: "iPhone",
                nonce: nil,
                walletSignature: nil,
                encPub: nil
            )
        )
        guard case .challenge(let nonce, let expiresIn) = outcome else {
            throw TestFailure("expected challenge, got \(outcome)")
        }
        #expect(expiresIn == 120)
        return nonce
    }

    private func sign(_ address: String, nonce: String, with key: Data) throws -> String {
        "0x"
            + (try signEIP191Message(
                OwnerDeviceAccess.redeemMessage(agentAddress: address, nonce: nonce),
                privateKey: key
            )).hexEncodedString
    }

    @MainActor
    private func withHostedAgent<T>(
        _ body: (Agent) async throws -> T
    ) async throws -> T {
        let agent = Agent(
            id: UUID(),
            name: "Alice's writer",
            isBuiltIn: false,
            agentIndex: 0,
            agentAddress: hostedAddress,
            autonomousExec: AutonomousExecConfig(enabled: false)
        )
        AgentManager.shared.add(agent)
        defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }
        return try await body(agent)
    }

    // MARK: step one

    @Test func stepOne_issuesChallenge_withoutRevealingAgentExistence() async throws {
        let host = await makeHost()
        // No such agent locally, still a challenge: existence is only
        // revealed after the owner proof.
        let nonce = try await stepOne(host, address: "0x00000000000000000000000000000000deadbeef")
        #expect(!nonce.isEmpty)
    }

    @Test func stepOne_rejectsMalformedRequests() async {
        let host = await makeHost()
        let badVersion = await host.handle(
            .init(
                v: 2,
                agentAddress: hostedAddress,
                deviceId: deviceId,
                deviceName: nil,
                nonce: nil,
                walletSignature: nil,
                encPub: nil
            )
        )
        guard case .rejected(.malformedRequest) = badVersion else {
            Issue.record("expected malformedRequest for v2, got \(badVersion)"); return
        }
        let badAddress = await host.handle(
            .init(
                v: 1,
                agentAddress: "not-an-address",
                deviceId: deviceId,
                deviceName: nil,
                nonce: nil,
                walletSignature: nil,
                encPub: nil
            )
        )
        guard case .rejected(.malformedRequest) = badAddress else {
            Issue.record("expected malformedRequest for address, got \(badAddress)"); return
        }
        let badDevice = await host.handle(
            .init(
                v: 1,
                agentAddress: hostedAddress,
                deviceId: "has spaces/and/slashes",
                deviceName: nil,
                nonce: nil,
                walletSignature: nil,
                encPub: nil
            )
        )
        guard case .rejected(.malformedRequest) = badDevice else {
            Issue.record("expected malformedRequest for device id, got \(badDevice)"); return
        }
        let longName = await host.handle(
            .init(
                v: 1,
                agentAddress: hostedAddress,
                deviceId: deviceId,
                deviceName: String(repeating: "x", count: 81),
                nonce: nil,
                walletSignature: nil,
                encPub: nil
            )
        )
        guard case .rejected(.malformedRequest) = longName else {
            Issue.record("expected malformedRequest for device name, got \(longName)"); return
        }
    }

    // MARK: challenge table bounds

    @Test func stepOne_repeatForSamePair_replacesEarlierNonce() async throws {
        let host = await makeHost()
        let first = try await stepOne(host)
        let second = try await stepOne(host)
        #expect(first != second)
        // Re-asking never grows the table for the same (agent, device).
        #expect(await host.pendingChallengeCount == 1)

        // The earlier nonce is gone even with a correct owner signature.
        let staleSignature = try sign(hostedAddress, nonce: first, with: TestKeys.alicePrivateKey)
        let stale = await host.handle(
            .init(
                v: 1,
                agentAddress: hostedAddress,
                deviceId: deviceId,
                deviceName: nil,
                nonce: first,
                walletSignature: staleSignature,
                encPub: encPub
            )
        )
        guard case .rejected(.unknownChallenge) = stale else {
            Issue.record("expected the replaced nonce to be unknown, got \(stale)"); return
        }
        // The current one is still live (consumed here; stops at agentNotFound).
        let liveSignature = try sign(hostedAddress, nonce: second, with: TestKeys.alicePrivateKey)
        let live = await host.handle(
            .init(
                v: 1,
                agentAddress: hostedAddress,
                deviceId: deviceId,
                deviceName: nil,
                nonce: second,
                walletSignature: liveSignature,
                encPub: encPub
            )
        )
        guard case .rejected(.agentNotFound) = live else {
            Issue.record("expected the current nonce to pass the challenge gate, got \(live)"); return
        }
        #expect(await host.pendingChallengeCount == 0)
    }

    @Test func stepOne_distinctPairs_eachKeepOneChallenge() async throws {
        let host = await makeHost()
        _ = try await stepOne(host, device: "phone")
        _ = try await stepOne(host, device: "studio")
        _ = try await stepOne(host, address: "0x00000000000000000000000000000000deadbeef", device: "phone")
        _ = try await stepOne(host, device: "phone")  // replaces the first
        #expect(await host.pendingChallengeCount == 3)
    }

    @Test func stepOne_tableIsHardCapped_evictingOldest() async throws {
        let host = await makeHost()
        let cap = OwnerDeviceAccessHost.maxPendingChallenges
        let firstNonce = try await stepOne(host, device: "flood-0")
        for i in 1 ..< (cap + 8) {
            _ = try await stepOne(host, device: "flood-\(i)")
        }
        // A flood of distinct device ids from an unauthenticated caller
        // cannot grow the table past the cap …
        #expect(await host.pendingChallengeCount == cap)
        // … and the oldest entry is the one that went.
        let signature = try sign(hostedAddress, nonce: firstNonce, with: TestKeys.alicePrivateKey)
        let evicted = await host.handle(
            .init(
                v: 1,
                agentAddress: hostedAddress,
                deviceId: "flood-0",
                deviceName: nil,
                nonce: firstNonce,
                walletSignature: signature,
                encPub: encPub
            )
        )
        guard case .rejected(.unknownChallenge) = evicted else {
            Issue.record("expected the evicted nonce to be unknown, got \(evicted)"); return
        }
    }

    // MARK: step two gates

    @Test func encPubValidation_acceptsOnlyRawX25519Keys() {
        #expect(OwnerDeviceAccessHost.isValidEncPub(encPub))
        #expect(!OwnerDeviceAccessHost.isValidEncPub(""))
        #expect(!OwnerDeviceAccessHost.isValidEncPub("not base64url!"))
        // Valid base64url, wrong length.
        #expect(!OwnerDeviceAccessHost.isValidEncPub(Data(repeating: 1, count: 31).base64urlEncoded))
        #expect(!OwnerDeviceAccessHost.isValidEncPub(Data(repeating: 1, count: 33).base64urlEncoded))
    }

    /// The relay terminates TLS and is untrusted by design: a step two that
    /// names no recipient key is refused with 400 before the nonce is
    /// consumed, before the signature is checked, and before anything is
    /// minted — there is no plaintext path.
    @Test func stepTwo_withoutEncPub_is400_beforeNonceIsConsumed() async throws {
        let host = await makeHost()
        let nonce = try await stepOne(host)
        let signature = try sign(hostedAddress, nonce: nonce, with: TestKeys.alicePrivateKey)

        for missing in [nil, "", "not-a-key"] {
            let outcome = await host.handle(
                .init(
                    v: 1,
                    agentAddress: hostedAddress,
                    deviceId: deviceId,
                    deviceName: nil,
                    nonce: nonce,
                    walletSignature: signature,
                    encPub: missing
                )
            )
            guard case .rejected(.malformedRequest(let detail)) = outcome else {
                Issue.record("expected malformedRequest for encPub \(String(describing: missing)), got \(outcome)")
                return
            }
            #expect(detail.contains("encPub"))
            #expect(OwnerRedeemRejection.malformedRequest(detail).httpStatus == 400)
        }
        // Nothing was consumed: the same nonce still clears the challenge gate.
        #expect(await host.pendingChallengeCount == 1)
        let retry = await host.handle(
            .init(
                v: 1,
                agentAddress: hostedAddress,
                deviceId: deviceId,
                deviceName: nil,
                nonce: nonce,
                walletSignature: signature,
                encPub: encPub
            )
        )
        guard case .rejected(.agentNotFound) = retry else {
            Issue.record("expected the nonce to survive a malformed attempt, got \(retry)"); return
        }
        #expect(await host.keyRecordsSnapshot().isEmpty)
    }

    @Test func stepTwo_unknownNonce_isRejected() async {
        let host = await makeHost()
        let outcome = await host.handle(
            .init(
                v: 1,
                agentAddress: hostedAddress,
                deviceId: deviceId,
                deviceName: nil,
                nonce: "never-issued",
                walletSignature: "0x" + String(repeating: "1", count: 130),
                encPub: encPub
            )
        )
        guard case .rejected(.unknownChallenge) = outcome else {
            Issue.record("expected unknownChallenge, got \(outcome)"); return
        }
    }

    @Test func stepTwo_nonceIsBoundToAgentAndDevice() async throws {
        let host = await makeHost()
        let nonce = try await stepOne(host)
        let signature = try sign(hostedAddress, nonce: nonce, with: TestKeys.alicePrivateKey)
        // Same nonce, different device → not the challenge that was issued.
        let wrongDevice = await host.handle(
            .init(
                v: 1,
                agentAddress: hostedAddress,
                deviceId: "other-device",
                deviceName: nil,
                nonce: nonce,
                walletSignature: signature,
                encPub: encPub
            )
        )
        guard case .rejected(.unknownChallenge) = wrongDevice else {
            Issue.record("expected unknownChallenge for other device, got \(wrongDevice)"); return
        }
    }

    @Test func stepTwo_wrongWallet_isNotOwner() async throws {
        let host = await makeHost()  // host wallet = Alice
        let nonce = try await stepOne(host)
        let bobSignature = try sign(hostedAddress, nonce: nonce, with: TestKeys.bobPrivateKey)
        let outcome = await host.handle(
            .init(
                v: 1,
                agentAddress: hostedAddress,
                deviceId: deviceId,
                deviceName: nil,
                nonce: nonce,
                walletSignature: bobSignature,
                encPub: encPub
            )
        )
        guard case .rejected(.notOwner) = outcome else {
            Issue.record("expected notOwner, got \(outcome)"); return
        }
        #expect(OwnerRedeemRejection.notOwner.httpStatus == 401)
    }

    @Test func stepTwo_signatureOverWrongMessage_isNotOwner() async throws {
        // Right key, wrong domain: a workspace-redeem signature must not be
        // replayable as an owner proof.
        let host = await makeHost()
        let nonce = try await stepOne(host)
        let crossed =
            "0x"
            + (try signEIP191Message(
                WorkspaceAgentAccess.redeemMessage(agentAddress: hostedAddress, nonce: nonce),
                privateKey: TestKeys.alicePrivateKey
            )).hexEncodedString
        let outcome = await host.handle(
            .init(
                v: 1,
                agentAddress: hostedAddress,
                deviceId: deviceId,
                deviceName: nil,
                nonce: nonce,
                walletSignature: crossed,
                encPub: encPub
            )
        )
        guard case .rejected(.notOwner) = outcome else {
            Issue.record("expected notOwner, got \(outcome)"); return
        }
    }

    @Test func stepTwo_hostWithoutIdentity_isNoIdentity() async throws {
        let host = await makeHost(wallet: nil)
        let nonce = try await stepOne(host)
        let signature = try sign(hostedAddress, nonce: nonce, with: TestKeys.alicePrivateKey)
        let outcome = await host.handle(
            .init(
                v: 1,
                agentAddress: hostedAddress,
                deviceId: deviceId,
                deviceName: nil,
                nonce: nonce,
                walletSignature: signature,
                encPub: encPub
            )
        )
        guard case .rejected(.noIdentity) = outcome else {
            Issue.record("expected noIdentity, got \(outcome)"); return
        }
        #expect(OwnerRedeemRejection.noIdentity.httpStatus == 503)
    }

    @Test func stepTwo_nonceIsSingleUse() async throws {
        let host = await makeHost()
        let nonce = try await stepOne(host)
        let signature = try sign(hostedAddress, nonce: nonce, with: TestKeys.alicePrivateKey)
        func redeem() async -> OwnerDeviceAccessHost.Outcome {
            await host.handle(
                .init(
                    v: 1,
                    agentAddress: hostedAddress,
                    deviceId: deviceId,
                    deviceName: nil,
                    nonce: nonce,
                    walletSignature: signature,
                    encPub: encPub
                )
            )
        }
        _ = await redeem()  // consumes (stops at agentNotFound in this process)
        let replay = await redeem()
        guard case .rejected(.unknownChallenge) = replay else {
            Issue.record("expected replay to hit unknownChallenge, got \(replay)"); return
        }
    }

    @Test func stepTwo_ownerProofForUnknownAgent_is404() async throws {
        let host = await makeHost()
        let unknown = "0x00000000000000000000000000000000deadbeef"
        let nonce = try await stepOne(host, address: unknown)
        let signature = try sign(unknown, nonce: nonce, with: TestKeys.alicePrivateKey)
        let outcome = await host.handle(
            .init(
                v: 1,
                agentAddress: unknown,
                deviceId: deviceId,
                deviceName: nil,
                nonce: nonce,
                walletSignature: signature,
                encPub: encPub
            )
        )
        guard case .rejected(.agentNotFound) = outcome else {
            Issue.record("expected agentNotFound, got \(outcome)"); return
        }
        #expect(OwnerRedeemRejection.agentNotFound.httpStatus == 404)
    }

    @Test func stepTwo_builtInAgent_is403EvenForOwner() async throws {
        // `AgentManager` never lets the built-in carry an address, so the
        // lookup seam plays a host where it somehow does; the gate must
        // still refuse — the owner proof is not a bypass.
        let address = "0x00000000000000000000000000000000b0110001"
        let host = await makeHost()
        await host.setSeams(resolveAgent: { lower in
            guard lower == address.lowercased() else { return nil }
            return .init(
                id: Agent.defaultId,
                keyPath: .legacy(index: 0),
                address: address,
                name: "Default",
                description: "",
                model: nil,
                isBuiltIn: true
            )
        })
        let nonce = try await stepOne(host, address: address)
        let signature = try sign(address, nonce: nonce, with: TestKeys.alicePrivateKey)
        let outcome = await host.handle(
            .init(
                v: 1,
                agentAddress: address,
                deviceId: deviceId,
                deviceName: nil,
                nonce: nonce,
                walletSignature: signature,
                encPub: encPub
            )
        )
        guard case .rejected(.builtInAgent) = outcome else {
            Issue.record("expected builtInAgent, got \(outcome)"); return
        }
        #expect(OwnerRedeemRejection.builtInAgent.httpStatus == 403)
    }

    // MARK: the happy path

    /// Owner proof for a hosted custom agent clears every gate. Under the
    /// disabled Keychain the mint fails (`mintFailed`); with a real Keychain
    /// it is `granted`. Either way, nothing before the mint refuses.
    @MainActor
    @Test func stepTwo_ownWallet_hostedAgent_clearsEveryGateBeforeMint() async throws {
        try await withHostedAgent { agent in
            let host = await makeHost()
            let nonce = try await stepOne(host)
            let signature = try sign(hostedAddress, nonce: nonce, with: TestKeys.alicePrivateKey)
            let recipient = PairingKeyEnvelope.generateRecipientKey()
            let outcome = await host.handle(
                .init(
                    v: 1,
                    agentAddress: hostedAddress,
                    deviceId: deviceId,
                    deviceName: "iPhone",
                    nonce: nonce,
                    walletSignature: signature,
                    encPub: recipient.publicKeyBase64url
                )
            )
            switch outcome {
            case .granted(let grant):
                #expect(grant.agentAddress.lowercased() == hostedAddress.lowercased())
                #expect(grant.agentName == agent.name)
                // The grant carries only the sealed envelope.
                let opened = try PairingKeyEnvelope.open(
                    grant.sealedApiKey,
                    privateKey: recipient.privateKey,
                    info: PairingKeyEnvelope.info(agentAddress: hostedAddress, nonce: nonce)
                )
                #expect(opened.hasPrefix("osk-v1"))
                let records = await host.keyRecordsSnapshot()
                #expect(records.count == 1)
                #expect(records.first?.deviceId == deviceId)
                #expect(records.first?.deviceName == "iPhone")
                #expect(records.first?.agentAddressLower == hostedAddress.lowercased())
            case .rejected(.mintFailed):
                // Keychain-disabled test process: every gate passed.
                break
            case .rejected(let other):
                Issue.record("owner redeem must not be refused before the mint, got \(other)")
            case .challenge:
                Issue.record("step two must not re-issue a challenge")
            }
        }
    }

    /// With a hosted agent and a real owner proof, an unusable encPub still
    /// never reaches the mint: it is a 400 before the nonce is consumed.
    @MainActor
    @Test func stepTwo_invalidEncPub_isRefusedBeforeMint() async throws {
        try await withHostedAgent { _ in
            let host = await makeHost()
            let nonce = try await stepOne(host)
            let signature = try sign(hostedAddress, nonce: nonce, with: TestKeys.alicePrivateKey)
            let outcome = await host.handle(
                .init(
                    v: 1,
                    agentAddress: hostedAddress,
                    deviceId: deviceId,
                    deviceName: nil,
                    nonce: nonce,
                    walletSignature: signature,
                    encPub: "not-a-key"
                )
            )
            guard case .rejected(.malformedRequest) = outcome else {
                Issue.record("expected malformedRequest, got \(outcome)"); return
            }
            #expect(await host.keyRecordsSnapshot().isEmpty)
            #expect(await host.pendingChallengeCount == 1)
        }
    }

    // MARK: records

    @Test func keyRecords_persistAndRevokeByDevice() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("owner-redeem-records-\(UUID().uuidString)", isDirectory: true)
        let file = dir.appendingPathComponent("owner-devices.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Seed a records file the way the host writes it.
        let records: [String: OwnerDeviceAccessHost.OwnerDeviceKeyRecord] = [
            "nonce-1": .init(
                keyId: UUID(),
                deviceId: "phone",
                deviceName: "iPhone",
                agentAddressLower: hostedAddress.lowercased(),
                issuedAt: Date()
            ),
            "nonce-2": .init(
                keyId: UUID(),
                deviceId: "studio",
                deviceName: "Studio",
                agentAddressLower: hostedAddress.lowercased(),
                issuedAt: Date()
            ),
        ]
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(records).write(to: file)

        let host = OwnerDeviceAccessHost()
        await host.setSeams(resolveHostWallet: { TestKeys.aliceAddress }, keyRecordsFileURL: { file })
        #expect(await host.keyRecordsSnapshot().count == 2)

        #expect(await host.revokeKeys(deviceId: "phone") == 1)
        let remaining = await host.keyRecordsSnapshot()
        #expect(remaining.map(\.deviceId) == ["studio"])

        // Persisted: a fresh host over the same file sees the revocation.
        let reloaded = OwnerDeviceAccessHost()
        await reloaded.setSeams(keyRecordsFileURL: { file })
        #expect(await reloaded.keyRecordsSnapshot().map(\.deviceId) == ["studio"])

        await reloaded.forgetRecords(agentAddress: hostedAddress.uppercased())
        #expect(await reloaded.keyRecordsSnapshot().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
