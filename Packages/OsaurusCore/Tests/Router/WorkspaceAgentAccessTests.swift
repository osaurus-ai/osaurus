//
//  WorkspaceAgentAccessTests.swift
//  osaurus
//
//  Membership attestations (verify vectors), the redeem handshake wire
//  shapes, the host-side challenge/redeem state machine, the viewer role's
//  least-privilege contract, and caller attribution encoding/decoding.
//

import CryptoKit
import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Attestation factory

/// Mints router-style attestation tokens with a throwaway Ed25519 key so
/// tests control every field and can corrupt any stage independently.
private struct AttestationFactory {
    let signingKey = Curve25519.Signing.PrivateKey()

    var publicKeyBase64URL: String {
        signingKey.publicKey.rawRepresentation.base64urlEncoded
    }

    func token(
        v: Int = 1,
        workspaceId: String = "team-1",
        accountId: String = "acct-1",
        wallet: String,
        role: String = "member",
        expiresIn: TimeInterval = 600,
        signWith key: Curve25519.Signing.PrivateKey? = nil,
        workspaceIdClaim: String = "workspace_id"
    ) throws -> String {
        let now = Int(Date().timeIntervalSince1970)
        // The router still emits `dino_id` (null unless claimed on the web);
        // the app ignores it, so keep it in the fixture to prove that.
        let payload: [String: Any] = [
            "v": v,
            workspaceIdClaim: workspaceId,
            "account_id": accountId,
            "wallet": wallet.lowercased(),
            "dino_id": NSNull(),
            "role": role,
            "iat": now,
            "exp": now + Int(expiresIn),
        ]
        let payloadData = try JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys]
        )
        let signature = try (key ?? signingKey).signature(for: payloadData)
        return payloadData.base64urlEncoded + "." + signature.base64urlEncoded
    }
}

// MARK: - Token verification

@Suite("Workspace membership attestation")
struct WorkspaceMembershipAttestationTests {
    private let factory = AttestationFactory()
    private let wallet = TestKeys.aliceAddress

    @Test func verify_acceptsValidToken() throws {
        let token = try factory.token(wallet: wallet, role: "viewer")
        let attestation = try WorkspaceMembershipAttestation.verify(
            token: token, publicKeyBase64URL: factory.publicKeyBase64URL
        )
        #expect(attestation.payload.workspaceId == "team-1")
        #expect(attestation.payload.wallet == wallet.lowercased())
        #expect(attestation.payload.accountId == "acct-1")
        #expect(attestation.payload.typedRole == .viewer)
        #expect(attestation.token == token)
        #expect(attestation.expiresAt > Date())
    }

    @Test func verify_rejectsExpiredToken() throws {
        let token = try factory.token(wallet: wallet, expiresIn: -30)
        #expect(throws: WorkspaceAttestationError.expired) {
            try WorkspaceMembershipAttestation.verify(
                token: token, publicKeyBase64URL: factory.publicKeyBase64URL
            )
        }
    }

    @Test func verify_rejectsWrongSigner() throws {
        // Signed by a different key than the published one.
        let rogue = Curve25519.Signing.PrivateKey()
        let token = try factory.token(wallet: wallet, signWith: rogue)
        #expect(throws: WorkspaceAttestationError.badSignature) {
            try WorkspaceMembershipAttestation.verify(
                token: token, publicKeyBase64URL: factory.publicKeyBase64URL
            )
        }
    }

    @Test func verify_rejectsTamperedPayload() throws {
        let token = try factory.token(wallet: wallet)
        let segments = token.split(separator: ".")
        // Re-encode a modified payload under the original signature.
        var payloadData = Data(base64urlEncoded: String(segments[0]))!
        var object =
            try JSONSerialization.jsonObject(with: payloadData) as! [String: Any]
        object["role"] = "owner"
        payloadData = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys]
        )
        let tampered = payloadData.base64urlEncoded + "." + String(segments[1])
        #expect(throws: WorkspaceAttestationError.badSignature) {
            try WorkspaceMembershipAttestation.verify(
                token: tampered, publicKeyBase64URL: factory.publicKeyBase64URL
            )
        }
    }

    @Test func verify_rejectsUnsupportedVersion() throws {
        let token = try factory.token(v: 2, wallet: wallet)
        #expect(throws: WorkspaceAttestationError.unsupportedVersion) {
            try WorkspaceMembershipAttestation.verify(
                token: token, publicKeyBase64URL: factory.publicKeyBase64URL
            )
        }
    }

    @Test func verify_rejectsMalformedTokenAndKey() throws {
        #expect(throws: WorkspaceAttestationError.malformedToken) {
            try WorkspaceMembershipAttestation.verify(
                token: "not-a-token", publicKeyBase64URL: factory.publicKeyBase64URL
            )
        }
        let token = try factory.token(wallet: wallet)
        #expect(throws: WorkspaceAttestationError.malformedPublicKey) {
            try WorkspaceMembershipAttestation.verify(
                token: token, publicKeyBase64URL: "AAAA"
            )
        }
    }

    @Test func unverifiedPayload_parsesWithoutKey() throws {
        let token = try factory.token(wallet: wallet, expiresIn: 600)
        let payload = try #require(WorkspaceMembershipAttestation.unverifiedPayload(token: token))
        #expect(payload.workspaceId == "team-1")
        #expect(TimeInterval(payload.exp) > Date().timeIntervalSince1970)
        #expect(WorkspaceMembershipAttestation.unverifiedPayload(token: "garbage") == nil)
    }

    @Test func legacyTeamIdClaim_stillVerifies() throws {
        // Tokens minted just before the router rename carry `team_id`; they
        // expire within 10 minutes but must not fail a handshake in flight.
        let token = try factory.token(wallet: wallet, workspaceIdClaim: "team_id")
        let attestation = try WorkspaceMembershipAttestation.verify(
            token: token, publicKeyBase64URL: factory.publicKeyBase64URL
        )
        #expect(attestation.payload.workspaceId == "team-1")
    }

    @Test func payloadRole_unknownFallsBackToViewer() throws {
        let token = try factory.token(wallet: wallet, role: "superuser-9000")
        let attestation = try WorkspaceMembershipAttestation.verify(
            token: token, publicKeyBase64URL: factory.publicKeyBase64URL
        )
        // Least privilege: a role this client doesn't know must never unlock
        // member/admin affordances.
        #expect(attestation.payload.typedRole == .viewer)
    }
}

// MARK: - Redeem wire shapes

@Suite("Workspace redeem wire shapes")
struct WorkspaceRedeemWireTests {
    @Test func redeemMessage_lowercasesAddress() {
        let message = WorkspaceAgentAccess.redeemMessage(
            agentAddress: "0xABCdef012345", nonce: "n0nce"
        )
        #expect(message == "osaurus-workspaces:redeem:0xabcdef012345:n0nce")
    }

    @Test func envelope_roundTripsWithSnakeCaseKeys() throws {
        let envelope = WorkspacePairRedeemEnvelope(
            workspaceRedeem: .init(
                v: 1,
                agentAddress: "0xabc",
                attestation: "tok.sig",
                nonce: "n1",
                walletSignature: "0xsig",
                encPub: "pub"
            )
        )
        let data = try JSONEncoder().encode(envelope)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let redeem = object?["team_redeem"] as? [String: Any]
        #expect(redeem?["agent_address"] as? String == "0xabc")
        #expect(redeem?["wallet_signature"] as? String == "0xsig")
        #expect(redeem?["encPub"] as? String == "pub")

        let decoded = try JSONDecoder().decode(WorkspacePairRedeemEnvelope.self, from: data)
        #expect(decoded == envelope)
    }

    @Test func challengeResponse_decodesExpiresIn() throws {
        let body = #"{"team_challenge":{"nonce":"abc","expires_in":120}}"#
        let challenge = try JSONDecoder().decode(
            WorkspacePairChallengeResponse.self, from: Data(body.utf8)
        )
        #expect(challenge.workspaceChallenge.nonce == "abc")
        #expect(challenge.workspaceChallenge.expiresIn == 120)
    }
}

// MARK: - Host state machine

@Suite("Workspace agent access host", .serialized)
struct WorkspaceAgentAccessHostTests {
    private let factory = AttestationFactory()
    private let wallet = TestKeys.aliceAddress
    // No local agent carries this address in the test process, so a fully
    // valid redeem stops exactly at the local-agent lookup.
    private let agentAddress = "0x00000000000000000000000000000000deadbeef"

    private func makeHost(
        shared: Set<String>? = nil
    ) async -> WorkspaceAgentAccessHost {
        let host = WorkspaceAgentAccessHost()
        let key = factory.publicKeyBase64URL
        let roster = shared ?? [agentAddress.lowercased()]
        await host.setSeams(
            fetchAttestationKey: { key },
            fetchSharedAddresses: { _ in roster },
            verifyCurrentAccess: { _, _, _ in }
        )
        return host
    }

    private func challengeNonce(_ outcome: WorkspaceAgentAccessHost.Outcome) -> String? {
        if case .challenge(let nonce, _) = outcome { return nonce }
        return nil
    }

    @Test func stepOne_issuesChallengeForValidAttestation() async throws {
        let host = await makeHost()
        let outcome = await host.handle(
            .init(
                v: 1,
                agentAddress: agentAddress,
                attestation: try factory.token(wallet: wallet),
                nonce: nil,
                walletSignature: nil,
                encPub: nil
            )
        )
        let nonce = try #require(challengeNonce(outcome))
        #expect(!nonce.isEmpty)
    }

    @Test func stepOne_rejectsExpiredAttestation() async throws {
        let host = await makeHost()
        let outcome = await host.handle(
            .init(
                v: 1,
                agentAddress: agentAddress,
                attestation: try factory.token(wallet: wallet, expiresIn: -5),
                nonce: nil,
                walletSignature: nil,
                encPub: nil
            )
        )
        guard case .rejected(.attestationExpired) = outcome else {
            Issue.record("Expected attestationExpired, got \(outcome)")
            return
        }
    }

    @Test func stepOne_rejectsForeignSignatureAfterKeyRefresh() async throws {
        let host = await makeHost()
        let rogue = Curve25519.Signing.PrivateKey()
        let outcome = await host.handle(
            .init(
                v: 1,
                agentAddress: agentAddress,
                attestation: try factory.token(wallet: wallet, signWith: rogue),
                nonce: nil,
                walletSignature: nil,
                encPub: nil
            )
        )
        guard case .rejected(.attestationInvalid) = outcome else {
            Issue.record("Expected attestationInvalid, got \(outcome)")
            return
        }
    }

    @Test func stepTwo_rejectsUnknownNonce() async throws {
        let host = await makeHost()
        let outcome = await host.handle(
            .init(
                v: 1,
                agentAddress: agentAddress,
                attestation: try factory.token(wallet: wallet),
                nonce: "never-issued",
                walletSignature: "0x" + String(repeating: "1", count: 130),
                encPub: nil
            )
        )
        guard case .rejected(.unknownChallenge) = outcome else {
            Issue.record("Expected unknownChallenge, got \(outcome)")
            return
        }
    }

    @Test func stepTwo_nonceIsSingleUse() async throws {
        let host = await makeHost()
        let attestation = try factory.token(wallet: wallet)
        let stepOne = await host.handle(
            .init(
                v: 1, agentAddress: agentAddress, attestation: attestation,
                nonce: nil, walletSignature: nil, encPub: nil
            )
        )
        let nonce = try #require(challengeNonce(stepOne))
        let signature = try signEIP191Message(
            WorkspaceAgentAccess.redeemMessage(agentAddress: agentAddress, nonce: nonce),
            privateKey: TestKeys.alicePrivateKey
        ).hexEncodedString

        func redeem() async -> WorkspaceAgentAccessHost.Outcome {
            await host.handle(
                .init(
                    v: 1, agentAddress: agentAddress, attestation: attestation,
                    nonce: nonce, walletSignature: "0x\(signature)", encPub: nil
                )
            )
        }
        // First redeem consumes the nonce (and proceeds to the local-agent
        // lookup, which fails in this process — that's fine, the nonce is
        // spent either way).
        _ = await redeem()
        let replay = await redeem()
        guard case .rejected(.unknownChallenge) = replay else {
            Issue.record("Expected replay to hit unknownChallenge, got \(replay)")
            return
        }
    }

    @Test func stepTwo_rejectsWalletSignatureFromWrongKey() async throws {
        let host = await makeHost()
        let attestation = try factory.token(wallet: wallet)
        let stepOne = await host.handle(
            .init(
                v: 1, agentAddress: agentAddress, attestation: attestation,
                nonce: nil, walletSignature: nil, encPub: nil
            )
        )
        let nonce = try #require(challengeNonce(stepOne))
        // Bob signs, but the attestation names Alice's wallet.
        let signature = try signEIP191Message(
            WorkspaceAgentAccess.redeemMessage(agentAddress: agentAddress, nonce: nonce),
            privateKey: TestKeys.bobPrivateKey
        ).hexEncodedString
        let outcome = await host.handle(
            .init(
                v: 1, agentAddress: agentAddress, attestation: attestation,
                nonce: nonce, walletSignature: "0x\(signature)", encPub: nil
            )
        )
        guard case .rejected(.badWalletSignature) = outcome else {
            Issue.record("Expected badWalletSignature, got \(outcome)")
            return
        }
    }

    @Test func stepTwo_validSignatureStopsAtLocalAgentLookup() async throws {
        // Everything cryptographic is right; the host just doesn't own this
        // agent. Proves the wallet-signature gate passes a correct signer
        // (the previous test proves it fails a wrong one).
        let host = await makeHost()
        let attestation = try factory.token(wallet: wallet)
        let stepOne = await host.handle(
            .init(
                v: 1, agentAddress: agentAddress, attestation: attestation,
                nonce: nil, walletSignature: nil, encPub: nil
            )
        )
        let nonce = try #require(challengeNonce(stepOne))
        let signature = try signEIP191Message(
            WorkspaceAgentAccess.redeemMessage(agentAddress: agentAddress, nonce: nonce),
            privateKey: TestKeys.alicePrivateKey
        ).hexEncodedString
        let outcome = await host.handle(
            .init(
                v: 1, agentAddress: agentAddress, attestation: attestation,
                nonce: nonce, walletSignature: "0x\(signature)", encPub: nil
            )
        )
        guard case .rejected(.agentNotFound) = outcome else {
            Issue.record("Expected agentNotFound, got \(outcome)")
            return
        }
    }

    @Test func stepTwo_acceptsLegacyTeamsRedeemWording() async throws {
        // A teammate on a pre-rename build signs `osaurus-teams:redeem:…`.
        // The host must still recover the wallet from that wording so the
        // pair doesn't break across the client rollout.
        let host = await makeHost()
        let attestation = try factory.token(wallet: wallet)
        let stepOne = await host.handle(
            .init(
                v: 1, agentAddress: agentAddress, attestation: attestation,
                nonce: nil, walletSignature: nil, encPub: nil
            )
        )
        let nonce = try #require(challengeNonce(stepOne))
        let signature = try signEIP191Message(
            WorkspaceAgentAccess.legacyRedeemMessage(agentAddress: agentAddress, nonce: nonce),
            privateKey: TestKeys.alicePrivateKey
        ).hexEncodedString
        let outcome = await host.handle(
            .init(
                v: 1, agentAddress: agentAddress, attestation: attestation,
                nonce: nonce, walletSignature: "0x\(signature)", encPub: nil
            )
        )
        guard case .rejected(.agentNotFound) = outcome else {
            Issue.record("Expected the signature gate to pass (agentNotFound), got \(outcome)")
            return
        }
    }

    @Test func unsupportedVersion_rejectedAsMalformed() async throws {
        let host = await makeHost()
        let outcome = await host.handle(
            .init(
                v: 99,
                agentAddress: agentAddress,
                attestation: try factory.token(wallet: wallet),
                nonce: nil,
                walletSignature: nil,
                encPub: nil
            )
        )
        guard case .rejected(.malformedRequest) = outcome else {
            Issue.record("Expected malformedRequest, got \(outcome)")
            return
        }
    }
}

// MARK: - Viewer role

@Suite("Viewer role")
struct ViewerRoleTests {
    @Test func viewerDecodesAndUnknownRolesFallToNil() throws {
        let decoder = JSONDecoder()
        let viewer = try decoder.decode(
            OsaurusRouterWorkspaceMember.self,
            from: Data(
                #"{"account_id":"a1","wallet_address":"0xDeF1","role":"viewer","joined_at":"2026-08-31T00:00:00.000Z"}"#
                    .utf8
            )
        )
        #expect(viewer.typedRole == .viewer)

        // Unknown roles must decode (row still renders) but produce no typed
        // role, so the UI's `?? .viewer` fallback applies least privilege.
        let future = try decoder.decode(
            OsaurusRouterWorkspaceMember.self,
            from: Data(
                #"{"account_id":"a1","wallet_address":"0xDeF1","role":"superadmin","joined_at":"2026-08-31T00:00:00.000Z"}"#
                    .utf8
            )
        )
        #expect(future.typedRole == nil)
    }

    @Test func shareGating_viewersCannotShareAgents() {
        #expect(OsaurusRouterWorkspaceRole.owner.canShareAgents)
        #expect(OsaurusRouterWorkspaceRole.admin.canShareAgents)
        #expect(OsaurusRouterWorkspaceRole.member.canShareAgents)
        #expect(!OsaurusRouterWorkspaceRole.viewer.canShareAgents)
    }
}

// MARK: - Caller attribution

@Suite("Caller attribution")
struct CallerAttributionTests {
    @Test func workspaceContext_encodesCallerAttestationOnlyWhenPresent() throws {
        let without = OsaurusRouterWorkspaceContext(workspaceId: "team-1", agentAddress: "0xabc")
        let withoutPayload =
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(without))
            as? [String: Any]
        #expect(withoutPayload?["workspace_id"] as? String == "team-1")
        // Spec: omit — never null — when the host serves the sharer's own turn.
        #expect(withoutPayload?.keys.contains("caller_attestation") == false)

        let with = OsaurusRouterWorkspaceContext(
            workspaceId: "team-1", agentAddress: "0xabc", callerAttestation: "tok.sig"
        )
        let payload =
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(with))
            as? [String: Any]
        #expect(payload?["caller_attestation"] as? String == "tok.sig")
    }

    @Test func usageItem_decodesCallerNextToActor() throws {
        let row = """
            {"id":"u1","request_id":"r1","model":"m","provider":"p",
             "input_tokens":10,"output_tokens":5,"cost_micro":"1234",
             "status":"completed","token_source":"provider",
             "created_at":"2026-08-31T00:00:00.000Z",
             "actor":{"account_id":"acct-1","wallet_address":"0xAbC1","dino_id":null,"display_name":"Rexy"},
             "caller":{"account_id":"acct-9","wallet_address":"0xDeF1","dino_id":null,"display_name":"Blue"}}
            """
        let item = try JSONDecoder().decode(
            OsaurusRouterUsageItem.self, from: Data(row.utf8)
        )
        // actor = whose instance billed; caller = who asked.
        #expect(item.actor?.accountId == "acct-1")
        #expect(item.actor?.friendlyName == "Rexy")
        #expect(item.caller?.accountId == "acct-9")
        #expect(item.caller?.friendlyName == "Blue")

        // caller is optional — sharer's own turns and personal rows omit it.
        let ownTurn = """
            {"id":"u1","request_id":"r1","model":"m","provider":"p",
             "input_tokens":10,"output_tokens":5,"cost_micro":"1234",
             "status":"completed","token_source":"provider",
             "created_at":"2026-08-31T00:00:00.000Z",
             "actor":{"account_id":"acct-1","wallet_address":"0xAbC1","display_name":"Rexy"}}
            """
        let withoutCaller = try JSONDecoder().decode(
            OsaurusRouterUsageItem.self, from: Data(ownTurn.utf8)
        )
        #expect(withoutCaller.caller == nil)
    }

    @Test func boundWorkspaceBillingContextWinsOverAgentPreference() async throws {
        // A redeemed teammate session (task-local) must outrank the host's
        // own per-agent billing preference — and carry the attestation. The
        // agent id is deliberately one with NO stored preference (writing to
        // the shared standard-defaults map here would race the other billing
        // suites): the bound context must be used purely on its own.
        let agentId = UUID()

        let service = RemoteProviderService(
            provider: RemoteProvider(
                name: "router",
                host: "router.osaurus.ai",
                providerProtocol: .https,
                port: nil,
                basePath: "/v1",
                authType: .none,
                providerType: .osaurusRouter
            ),
            models: ["m"],
            resolvedHeaders: [:]
        )
        let params = GenerationParameters(temperature: 0.7, maxTokens: 128)
        let bound = OsaurusRouterWorkspaceContext(
            workspaceId: "team-session", agentAddress: "0xaaa111", callerAttestation: "tok.sig"
        )

        let request = await ChatExecutionContext.$workspaceBillingContext.withValue(bound) {
            await ChatExecutionContext.$currentAgentId.withValue(agentId) {
                await service.buildChatRequest(
                    messages: [ChatMessage(role: "user", content: "hi")],
                    parameters: params,
                    model: "osaurus/minimax-m3",
                    stream: true,
                    tools: nil,
                    toolChoice: nil
                )
            }
        }
        #expect(request.workspaceContext?.workspaceId == "team-session")
        #expect(request.workspaceContext?.callerAttestation == "tok.sig")
    }
}

// MARK: - Model badge (agentModel on the grant)

@Suite("Shared agent model badge")
struct SharedAgentModelBadgeTests {
    @Test func grantDecodesAgentModelWhenPresent() throws {
        let body = """
            {"agentAddress":"0xabc","agentName":"Release Assistant",
             "agentDescription":null,"agentModel":"anthropic/claude-sonnet-4-5",
             "apiKey":"","sealedApiKey":{"enc":"ZW5j","ct":"Y3Q="}}
            """
        let grant = try JSONDecoder().decode(
            WorkspaceAgentConnectService.GrantResponse.self, from: Data(body.utf8)
        )
        #expect(grant.agentModel == "anthropic/claude-sonnet-4-5")
        #expect(grant.sealedApiKey == PairingKeyEnvelope.Sealed(enc: "ZW5j", ct: "Y3Q="))
    }

    @Test func grantFromOlderHostHasNoModel() throws {
        // Hosts that predate the badge omit the field entirely; the
        // handshake must still succeed.
        let body = #"{"agentAddress":"0xabc","agentName":"HR","apiKey":"osk-v1.x"}"#
        let grant = try JSONDecoder().decode(
            WorkspaceAgentConnectService.GrantResponse.self, from: Data(body.utf8)
        )
        #expect(grant.agentModel == nil)
        #expect(grant.apiKey == "osk-v1.x")
    }

    @Test func remoteAgentModelIsOptionalOnDisk() throws {
        // Pairings persisted before the field existed decode with model == nil…
        let legacy = """
            {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","agentAddress":"0xabc",
             "name":"HR","description":"","relayBaseURL":"https://0xabc.agent.osaurus.ai",
             "providerId":"6F9619FF-8B86-D011-B42D-00C04FC964FE",
             "pairedAt":0}
            """
        let decoded = try JSONDecoder().decode(RemoteAgent.self, from: Data(legacy.utf8))
        #expect(decoded.model == nil)

        // …and a model round-trips once set.
        var withModel = decoded
        withModel.model = "gemma-4-26b-mxfp4"
        let data = try JSONEncoder().encode(withModel)
        #expect(try JSONDecoder().decode(RemoteAgent.self, from: data).model == "gemma-4-26b-mxfp4")
    }

    @Test func shortModelLabelDropsProviderPrefix() {
        #expect(RemoteAgent.shortModelLabel("anthropic/claude-sonnet-4-5") == "claude-sonnet-4-5")
        #expect(RemoteAgent.shortModelLabel("openai/gpt-5.2") == "gpt-5.2")
        #expect(RemoteAgent.shortModelLabel("gemma-4-26b-mxfp4") == "gemma-4-26b-mxfp4")
        #expect(RemoteAgent.shortModelLabel(" qwen3/ ") == "qwen3/")
        #expect(RemoteAgent.shortModelLabel("mlx-community/Qwen3-8B-4bit") == "Qwen3-8B-4bit")
    }
}
