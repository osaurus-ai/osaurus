//
//  AgentScopePolicyTests.swift
//  OsaurusCoreTests
//
//  Route-level confinement of agent-scoped access keys (default deny), task
//  ownership for `/tasks/{id}`, and the `/pair-invite` hardening helpers
//  (request-body redaction, relay-aware rate-limit key).
//

import CryptoKit
import Foundation
import NIOHTTP1
import Testing

@testable import OsaurusCore

// MARK: - Route allowlist

@Suite("Agent-scoped key route policy")
struct AgentScopePolicyTests {
    private let agentAudience = "0x00000000000000000000000000000000cafebabe"
    private let taskId = UUID().uuidString

    /// Workspace-minted key (strict allowlist) unless `legacy` is set. The
    /// owner's "share my models for inference" switch is passed explicitly
    /// (default off, matching a fresh install) so the policy is exercised in
    /// both positions without touching UserDefaults.
    private func rejection(
        _ method: HTTPMethod, _ path: String,
        audience: String? = "0x00000000000000000000000000000000cafebabe",
        master: Bool = false,
        legacy: Bool = false,
        sharing: Bool = false
    ) -> (code: String, message: String)? {
        HTTPHandler.agentScopedRouteRejection(
            method: method, path: path, authedAudience: audience, authedScopeIsMaster: master,
            isWorkspaceMintedKey: !legacy, peerInferenceEnabled: sharing
        )
    }

    /// Every route that runs the host's models for the caller. Refused to all
    /// agent-scoped keys while the owner has not shared inference.
    private let inferenceRoutes: [(HTTPMethod, String)] = [
        (.POST, "/chat/completions"),
        (.POST, "/completions"),
        (.POST, "/chat"),
        (.POST, "/generate"),
        (.POST, "/messages"),
        (.POST, "/responses"),
        (.POST, "/embeddings"),
        (.POST, "/embed"),
        (.POST, "/audio/transcriptions"),
        (.POST, "/images/generations"),
        (.POST, "/images/edits"),
        (.POST, "/images/upscale"),
        (.POST, "/videos/quote"),
        (.POST, "/videos/generations"),
    ]

    /// Legacy `/pair` and `AgentInvite` keys keep the agent surface they had
    /// before this policy existed. Only `/admin/*` (server administration)
    /// and — until the owner opts in — the inference routes are closed.
    @Test func legacyPairingKeysKeepTheirAgentSurfaceExceptServerAdministration() {
        let stillAllowed: [(HTTPMethod, String)] = [
            (.GET, "/models"),
            (.GET, "/tags"),
            (.GET, "/agents"),
            (.GET, "/agents/\(agentAudience)"),
            (.POST, "/agents/\(agentAudience)/run"),
            (.POST, "/agents/\(agentAudience)/dispatch"),
            (.GET, "/tasks/\(taskId)"),
            (.POST, "/memory/ingest"),
            (.POST, "/mcp/call"),
            (.GET, "/health"),
        ]
        for sharing in [false, true] {
            for (method, path) in stillAllowed {
                #expect(
                    rejection(method, path, legacy: true, sharing: sharing) == nil,
                    "\(method) \(path) must stay reachable (sharing=\(sharing))"
                )
            }
        }
        let closed: [(HTTPMethod, String)] = [
            (.GET, "/admin/runtime-settings"),
            (.PUT, "/admin/runtime-settings"),
            (.GET, "/admin/cache-stats"),
            (.GET, "/admin/config/export"),
            (.POST, "/admin/config/agents"),
        ]
        for sharing in [false, true] {
            for (method, path) in closed {
                #expect(
                    rejection(method, path, legacy: true, sharing: sharing)?.code == "agent_scope_denied",
                    "\(method) \(path) must be closed to agent-scoped keys (sharing=\(sharing))"
                )
            }
        }
    }

    /// Default off: no agent-scoped key — legacy or workspace-minted — may run
    /// inference on this host, and the refusal is distinguishable
    /// (`peer_inference_disabled`) so the peer's UI can explain it.
    @Test func inferenceRoutesAreClosedToEveryPeerUntilTheOwnerShares() {
        for legacy in [false, true] {
            for (method, path) in inferenceRoutes {
                let result = rejection(method, path, legacy: legacy, sharing: false)
                let origin = legacy ? "legacy" : "workspace"
                #expect(
                    result?.code == "peer_inference_disabled",
                    "\(method) \(path) should be refused for a \(origin) key while sharing is off; got \(result as Any)"
                )
            }
        }
    }

    /// Owner opted in: legacy keys regain their whole inference surface;
    /// workspace keys gain exactly the teammate client's Mode 1 route
    /// (`POST /chat/completions`) and nothing else.
    @Test func sharingOpensInferenceByKeyOrigin() {
        for (method, path) in inferenceRoutes {
            #expect(
                rejection(method, path, legacy: true, sharing: true) == nil,
                "\(method) \(path) must open to legacy keys once the owner shares"
            )
        }
        #expect(rejection(.POST, "/chat/completions", sharing: true) == nil)
        for (method, path) in inferenceRoutes where path != "/chat/completions" {
            #expect(
                rejection(method, path, sharing: true)?.code == "agent_scope_denied",
                "\(method) \(path) must stay closed to workspace keys even when sharing"
            )
        }
        // `GET /chat/completions` is not a thing; the allowlist is method-exact.
        #expect(rejection(.GET, "/chat/completions", sharing: true)?.code == "agent_scope_denied")
    }

    @Test func allowsExactlyTheTeammateClientSurface() {
        #expect(rejection(.GET, "/models") == nil)
        #expect(rejection(.HEAD, "/models") == nil)
        #expect(rejection(.GET, "/agents/\(agentAudience)") == nil)
        #expect(rejection(.GET, "/agents/6F9619FF-8B86-D011-B42D-00C04FC964FF") == nil)
        #expect(rejection(.POST, "/agents/\(agentAudience)/run") == nil)
        #expect(rejection(.POST, "/agents/\(agentAudience)/dispatch")?.code == "agent_scope_denied")
        #expect(rejection(.GET, "/tasks/\(taskId)")?.code == "agent_scope_denied")
        #expect(rejection(.DELETE, "/tasks/\(taskId)")?.code == "agent_scope_denied")
        #expect(rejection(.POST, "/tasks/\(taskId)/clarify")?.code == "agent_scope_denied")
    }

    @Test func deniesEverythingElse() {
        let denied: [(HTTPMethod, String)] = [
            (.GET, "/agents"),  // enumeration
            (.POST, "/memory/ingest"),
            (.POST, "/mcp/call"),
            (.GET, "/mcp/tools"),
            (.GET, "/admin/runtime-settings"),
            (.PUT, "/admin/runtime-settings"),
            (.GET, "/admin/cache-stats"),
            (.GET, "/admin/config/agents"),
            (.POST, "/admin/config/agents"),
            (.GET, "/health"),
            (.GET, "/tags"),
            (.POST, "/show"),
            (.GET, "/tasks"),
            (.GET, "/tasks/not-a-uuid"),
            (.PUT, "/agents/\(agentAudience)"),
            (.DELETE, "/agents/\(agentAudience)"),
            (.GET, "/agents/\(agentAudience)/run"),
            (.POST, "/agents/\(agentAudience)/history"),
            (.POST, "/agents//run"),
            (.POST, "/models"),
            (.PATCH, "/tasks/\(taskId)"),
            (.GET, "/tasks/\(taskId)/clarify"),
        ]
        for sharing in [false, true] {
            for (method, path) in denied {
                let result = rejection(method, path, sharing: sharing)
                #expect(result?.code == "agent_scope_denied", "\(method) \(path) should be denied (sharing=\(sharing))")
            }
        }
    }

    @Test func masterKeysAndKeylessCallersAreUnrestricted() {
        let routes: [(HTTPMethod, String)] = [
            (.GET, "/agents"),
            (.POST, "/chat/completions"),
            (.PUT, "/admin/runtime-settings"),
        ]
        for legacy in [false, true] {
            for sharing in [false, true] {
                for (method, path) in routes {
                    let master = rejection(
                        method, path, audience: "0xmaster", master: true, legacy: legacy, sharing: sharing
                    )
                    #expect(master == nil, "master key: \(method) \(path)")
                    #expect(
                        rejection(method, path, audience: nil, legacy: legacy, sharing: sharing) == nil,
                        "keyless caller: \(method) \(path)"
                    )
                }
            }
        }
    }

    /// The catalog itself is never gate-denied (the peer client must keep
    /// connecting for Mode 2); the handlers hide it instead. Only agent-scoped
    /// keys are hidden from, and only while sharing is off.
    @Test func modelCatalogIsHiddenFromPeersOnlyWhileSharingIsOff() {
        func hidden(_ audience: String?, master: Bool = false, sharing: Bool) -> Bool {
            HTTPHandler.peerModelCatalogIsHidden(
                authedAudience: audience, authedScopeIsMaster: master, peerInferenceEnabled: sharing
            )
        }
        #expect(hidden(agentAudience, sharing: false))
        #expect(!hidden(agentAudience, sharing: true))
        #expect(!hidden("0xmaster", master: true, sharing: false))
        #expect(!hidden(nil, sharing: false))
    }

    /// `PeerInferenceSharing` defaults off, round-trips, and an explicit off
    /// leaves no key behind (so "absent = off" is the only representation).
    @Test func peerInferenceSharingDefaultsOffAndRoundTrips() throws {
        let suite = "PeerInferenceSharingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(!PeerInferenceSharing.isEnabled(defaults: defaults))
        PeerInferenceSharing.setEnabled(true, defaults: defaults)
        #expect(PeerInferenceSharing.isEnabled(defaults: defaults))
        PeerInferenceSharing.setEnabled(false, defaults: defaults)
        #expect(!PeerInferenceSharing.isEnabled(defaults: defaults))
        #expect(defaults.object(forKey: PeerInferenceSharing.defaultsKey) == nil)
    }

    /// `X-Osaurus-Agent-Id` naming a *different* agent than the key's audience
    /// is refused for every agent-scoped key; absent, malformed, Default-agent,
    /// or same-agent headers pass through to the handlers' existing logic.
    @Test func crossAgentHeaderIsRefusedForAgentScopedKeys() {
        let mine = UUID()
        let theirs = UUID()
        let myAddress = "0x000000000000000000000000000000000000D00D"
        let directory: [UUID: String] = [mine: myAddress, theirs: "0x000000000000000000000000000000000000beef"]

        func check(_ header: String?, audience: String? = myAddress.lowercased(), master: Bool = false) -> String? {
            HTTPHandler.agentHeaderScopeRejection(
                headerValue: header, authedAudience: audience, authedScopeIsMaster: master,
                resolveAddress: { directory[$0] }
            )?.code
        }

        #expect(check(theirs.uuidString) == "agent_scope_denied")
        #expect(check(" \(theirs.uuidString.lowercased()) ") == "agent_scope_denied")
        #expect(check(UUID().uuidString) == "agent_scope_denied")  // unknown agent
        #expect(check(mine.uuidString) == nil)
        #expect(check(nil) == nil)
        #expect(check("") == nil)
        #expect(check("not-a-uuid") == nil)
        #expect(check(Agent.defaultId.uuidString) == nil)
        #expect(check(theirs.uuidString, audience: "0xmaster", master: true) == nil)
        #expect(check(theirs.uuidString, audience: nil) == nil)
    }

    @Test func rejectionShapeMatchesPerAgentCheck() {
        let perAgent = HTTPHandler.agentScopeRejection(
            forAgentId: UUID(), authedAudience: agentAudience, authedScopeIsMaster: false
        )
        let perRoute = rejection(.GET, "/agents")
        #expect(perAgent?.code == perRoute?.code)
        #expect(perRoute?.message.contains("/agents") == true)
    }
}

// MARK: - Task ownership

@Suite("Dispatch task ownership")
struct DispatchTaskOwnershipTests {
    @Test func ownerMayActForeignKeyMayNot() {
        let registry = HTTPHandler.DispatchTaskOwnership(capacity: 8)
        let task = UUID()
        registry.record(taskId: task, audience: "0xAAAA", keyNonce: "key-a")

        #expect(registry.rejection(taskId: task, authedAudience: "0xaaaa", authedScopeIsMaster: false, keyNonce: "key-a") == nil)
        #expect(
            registry.rejection(taskId: task, authedAudience: "0xbbbb", authedScopeIsMaster: false, keyNonce: "key-a")?.code
                == "agent_scope_denied"
        )
        // A task nobody recorded (created by loopback or a master key) is
        // off-limits to every agent-scoped key.
        #expect(
            registry.rejection(taskId: UUID(), authedAudience: "0xaaaa", authedScopeIsMaster: false, keyNonce: "key-a")?.code
                == "agent_scope_denied"
        )
    }

    @Test func sameAgentDifferentCredentialIsDeniedAndOwnerSurvivesRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("owners.json")
        let task = UUID()
        let registry = HTTPHandler.DispatchTaskOwnership(fileURL: file)
        registry.record(taskId: task, audience: "0xaaaa", keyNonce: "caller-a")
        let restored = HTTPHandler.DispatchTaskOwnership(fileURL: file)
        #expect(
            restored.rejection(taskId: task, authedAudience: "0xaaaa", authedScopeIsMaster: false, keyNonce: "caller-a")
                == nil
        )
        #expect(
            restored.rejection(taskId: task, authedAudience: "0xaaaa", authedScopeIsMaster: false, keyNonce: "caller-b")
                != nil
        )
        #expect(restored.rejection(taskId: task, authedAudience: "0xaaaa", authedScopeIsMaster: false) != nil)
    }

    @Test func masterAndKeylessCallersAreUnrestricted() {
        let registry = HTTPHandler.DispatchTaskOwnership(capacity: 8)
        let task = UUID()
        registry.record(taskId: task, audience: "0xaaaa", keyNonce: "key-a")
        #expect(registry.rejection(taskId: task, authedAudience: "0xmaster", authedScopeIsMaster: true, keyNonce: "key-a") == nil)
        #expect(registry.rejection(taskId: task, authedAudience: nil, authedScopeIsMaster: false, keyNonce: "key-a") == nil)
        #expect(registry.rejection(taskId: UUID(), authedAudience: nil, authedScopeIsMaster: false, keyNonce: "key-a") == nil)
    }

    @Test func boundedFIFOEvictsOldest() {
        let registry = HTTPHandler.DispatchTaskOwnership(capacity: 3)
        let ids = (0 ..< 5).map { _ in UUID() }
        for id in ids { registry.record(taskId: id, audience: "0xaaaa", keyNonce: "key-a") }
        #expect(registry.owner(of: ids[0]) == nil)
        #expect(registry.owner(of: ids[1]) == nil)
        #expect(registry.owner(of: ids[2]) == "0xaaaa")
        #expect(registry.owner(of: ids[4]) == "0xaaaa")
    }

    @Test func reRecordingDoesNotDuplicateOrderEntries() {
        let registry = HTTPHandler.DispatchTaskOwnership(capacity: 2)
        let a = UUID()
        let b = UUID()
        registry.record(taskId: a, audience: "0x1", keyNonce: "key-a")
        registry.record(taskId: a, audience: "0x2", keyNonce: "key-a")  // re-stamp, same slot
        registry.record(taskId: b, audience: "0x3", keyNonce: "key-a")
        #expect(registry.owner(of: a) == "0x2")
        #expect(registry.owner(of: b) == "0x3")
    }
}

// MARK: - /pair-invite hardening helpers

@Suite("Pair-invite hardening")
struct PairInviteHardeningTests {
    @Test func redactsCredentialBearingFieldsInWorkspaceEnvelope() throws {
        let body = """
            {"team_redeem":{"v":1,"agent_address":"0xabc","attestation":"eyJhIjoxfQ.c2ln",
             "nonce":"n0nce","wallet_signature":"0xdeadbeef","encPub":"pubkey"}}
            """
        let redacted = HTTPHandler.redactedPairInviteRequestBody(Data(body.utf8))
        let object = try JSONSerialization.jsonObject(with: Data(redacted.utf8)) as? [String: Any]
        let redeem = object?["team_redeem"] as? [String: Any]
        #expect(redeem?["attestation"] as? String == "<redacted>")
        #expect(redeem?["wallet_signature"] as? String == "<redacted>")
        #expect(redeem?["nonce"] as? String == "<redacted>")
        #expect(redeem?["encPub"] as? String == "<redacted>")
        // Non-secret routing fields survive so the log row stays useful.
        #expect(redeem?["agent_address"] as? String == "0xabc")
        #expect(redeem?["v"] as? Int == 1)
        #expect(!redacted.contains("eyJhIjoxfQ"))
        #expect(!redacted.contains("0xdeadbeef"))
    }

    @Test func redactsAgentInviteSignatureAndNonce() throws {
        let body = """
            {"v":1,"addr":"0xabc","name":"HR","desc":null,"url":"https://x.agent.osaurus.ai",
             "nonce":"replay-token","exp":1762000000,"sig":"0x0102","encPub":"pk"}
            """
        let redacted = HTTPHandler.redactedPairInviteRequestBody(Data(body.utf8))
        let object = try JSONSerialization.jsonObject(with: Data(redacted.utf8)) as? [String: Any]
        #expect(object?["sig"] as? String == "<redacted>")
        #expect(object?["nonce"] as? String == "<redacted>")
        #expect(object?["encPub"] as? String == "<redacted>")
        #expect(object?["addr"] as? String == "0xabc")
        #expect(object?["name"] as? String == "HR")
    }

    @Test func nonJSONBodiesAreNeverLoggedVerbatim() {
        #expect(HTTPHandler.redactedPairInviteRequestBody(Data("attestation=abc".utf8)) == "<redacted: non-JSON body>")
        #expect(HTTPHandler.redactedPairInviteRequestBody(Data()) == "")
    }

    @Test func insightsRedactorCatchesAttestationAndWalletSignatureValues() {
        let body =
            #"{"team_redeem":{"attestation":"eyJhIjoxfQ.c2ln","wallet_signature":"0xabcdef","agent_address":"0xabc"}}"#
        let redacted = InsightsService.redactCredentials(body)
        #expect(!redacted.contains("eyJhIjoxfQ.c2ln"))
        #expect(!redacted.contains("0xabcdef"))
        #expect(redacted.contains(#""attestation":"<redacted>""#))
        #expect(redacted.contains(#""wallet_signature":"<redacted>""#))
        #expect(redacted.contains("0xabc"))
    }

    @Test func relayRateLimitKeyIsPerForwardedCallerAndNeverCollidesWithLAN() {
        let a = HTTPHandler.relayRateLimitKey(forwardedFor: "203.0.113.7, 10.0.0.1", socketIP: "127.0.0.1")
        let b = HTTPHandler.relayRateLimitKey(forwardedFor: "198.51.100.9", socketIP: "127.0.0.1")
        let none = HTTPHandler.relayRateLimitKey(forwardedFor: nil, socketIP: "127.0.0.1")
        #expect(a == "relay:203.0.113.7")
        #expect(b == "relay:198.51.100.9")
        #expect(a != b)
        #expect(none == "relay:127.0.0.1")
        // A LAN caller from the same literal address is a different bucket.
        #expect(a != "203.0.113.7")
        // Hostile header values are bounded.
        let huge = HTTPHandler.relayRateLimitKey(forwardedFor: String(repeating: "x", count: 5000), socketIP: "1.2.3.4")
        #expect(huge.count <= "relay:".count + 64)
    }

    @Test func pendingChallengeCapEvictsOldestInsteadOfGrowing() async throws {
        // 300 step-one requests must not leave more than the cap outstanding;
        // the most recent challenge must still be redeemable (it reaches the
        // signature gate rather than `unknownChallenge`).
        let host = WorkspaceAgentAccessHost()
        let factory = ScopePolicyAttestationFactory()
        let key = factory.publicKeyBase64URL
        let agent = "0x00000000000000000000000000000000deadbeef"
        await host.setSeams(fetchAttestationKey: { key }, fetchSharedAddresses: { _ in [agent] })
        let attestation = try factory.token(wallet: TestKeys.aliceAddress)

        var first: String?
        var last: String?
        for i in 0 ..< (WorkspaceAgentAccessHost.maxPendingChallenges + 44) {
            let outcome = await host.handle(
                .init(v: 1, agentAddress: agent, attestation: attestation, nonce: nil, walletSignature: nil, encPub: nil)
            )
            guard case .challenge(let nonce, _) = outcome else {
                Issue.record("step one \(i) did not issue a challenge: \(outcome)")
                return
            }
            if first == nil { first = nonce }
            last = nonce
        }
        let evicted = await host.handle(
            .init(
                v: 1, agentAddress: agent, attestation: attestation,
                nonce: try #require(first), walletSignature: "0x" + String(repeating: "1", count: 130), encPub: nil
            )
        )
        guard case .rejected(.unknownChallenge) = evicted else {
            Issue.record("oldest challenge should have been evicted, got \(evicted)")
            return
        }
        let recent = await host.handle(
            .init(
                v: 1, agentAddress: agent, attestation: attestation,
                nonce: try #require(last), walletSignature: "0x" + String(repeating: "1", count: 130), encPub: nil
            )
        )
        guard case .rejected(.badWalletSignature) = recent else {
            Issue.record("newest challenge should still be live (signature gate), got \(recent)")
            return
        }
    }
}

/// Local attestation factory (the one in WorkspaceAgentAccessTests is file-private).
struct ScopePolicyAttestationFactory {
    let signingKey = CryptoKit.Curve25519.Signing.PrivateKey()

    var publicKeyBase64URL: String {
        signingKey.publicKey.rawRepresentation.base64urlEncoded
    }

    func token(
        workspaceId: String = "team-1",
        accountId: String = "acct-1",
        wallet: String,
        role: String = "member",
        expiresIn: TimeInterval = 600
    ) throws -> String {
        let now = Int(Date().timeIntervalSince1970)
        let payload: [String: Any] = [
            "v": 1,
            "workspace_id": workspaceId,
            "account_id": accountId,
            "wallet": wallet.lowercased(),
            "role": role,
            "iat": now,
            "exp": now + Int(expiresIn),
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let signature = try signingKey.signature(for: payloadData)
        return payloadData.base64urlEncoded + "." + signature.base64urlEncoded
    }
}
