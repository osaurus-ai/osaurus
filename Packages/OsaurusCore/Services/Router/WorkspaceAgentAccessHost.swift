//
//  WorkspaceAgentAccessHost.swift
//  osaurus
//
//  Host (sharer) side of the Workspaces shared-agent handshake. A teammate
//  presents a router-minted membership attestation over the relay; this
//  service answers with a single-use nonce challenge, verifies everything
//  OFFLINE against the router's published Ed25519 key (plus one roster
//  check that the agent is still actively shared), and mints an
//  agent-scoped `osk-v1` key whose in-token expiry equals the
//  attestation's — the revocation contract is therefore enforced by the
//  ordinary access-key validator with no separate sweep: a key outlives
//  its attestation only by being re-minted from a fresh one.
//

import Foundation

/// Typed rejection the HTTP surface maps onto a status + JSON error body.
enum WorkspaceRedeemRejection: Error, Equatable {
    case malformedRequest(String)
    case attestationInvalid(String)
    case attestationExpired
    case unknownChallenge
    case badWalletSignature
    case agentNotFound
    case notShared
    case rosterUnavailable
    case mintFailed

    var httpStatus: Int {
        switch self {
        case .malformedRequest: return 400
        case .attestationInvalid, .badWalletSignature, .unknownChallenge: return 401
        case .attestationExpired: return 410
        case .agentNotFound: return 404
        case .notShared: return 403
        case .rosterUnavailable: return 503
        case .mintFailed: return 500
        }
    }

    var wireMessage: String {
        switch self {
        case .malformedRequest(let detail): return detail
        case .attestationInvalid(let detail): return "Invalid attestation: \(detail)"
        case .attestationExpired: return "Attestation has expired"
        case .unknownChallenge: return "Unknown or expired challenge nonce"
        case .badWalletSignature: return "Wallet signature does not match the attestation"
        case .agentNotFound: return "Agent address not found on this server"
        case .notShared: return "Agent is not shared with this workspace"
        case .rosterUnavailable: return "Could not verify the workspace share right now"
        case .mintFailed: return "Failed to mint access key"
        }
    }
}

actor WorkspaceAgentAccessHost {
    static let shared = WorkspaceAgentAccessHost()

    /// Successful step-two outcome, ready for the HTTP surface to encode.
    struct RedeemGrant: Sendable {
        let agentAddress: String
        let agentName: String
        let agentDescription: String?
        /// The model the shared agent is configured to run, so the teammate's
        /// roster can show it. Informational only.
        let agentModel: String?
        /// Plaintext key, empty when sealed.
        let apiKeyForWire: String
        let sealedApiKey: PairingKeyEnvelope.Sealed?
    }

    enum Outcome: Sendable {
        case challenge(nonce: String, expiresIn: Int)
        case granted(RedeemGrant)
        case rejected(WorkspaceRedeemRejection)
    }

    /// Everything remembered about a workspace-minted key, keyed by the key's
    /// in-token nonce (what the auth gate exposes as `accessKeyId`). Used
    /// for caller attribution on workspace-billed calls, for unshare
    /// revocation, and for the audit trail. Persisted to
    /// `~/.osaurus/workspaces/keys.json` so a host restart inside a key's
    /// attestation window (~10 min) neither drops workspace billing /
    /// caller attribution for that key nor makes it invisible to
    /// `invalidateKeys`. The attestation token is stored because it must be
    /// re-presented as `caller_attestation` on every router-billed step.
    struct WorkspaceKeyRecord: Codable, Sendable, Equatable {
        let keyId: UUID
        let workspaceId: String
        let accountId: String
        let wallet: String
        /// The member's workspace role as attested by the router at mint time
        /// (`owner` / `admin` / `member` / `viewer`). Recorded for the audit
        /// trail; capability on the host is the same for every active member.
        let role: String
        let agentAddressLower: String
        let attestationToken: String
        let attestationExpiresAt: Date

        init(
            keyId: UUID,
            workspaceId: String,
            accountId: String,
            wallet: String,
            role: String,
            agentAddressLower: String,
            attestationToken: String,
            attestationExpiresAt: Date
        ) {
            self.keyId = keyId
            self.workspaceId = workspaceId
            self.accountId = accountId
            self.wallet = wallet
            self.role = role
            self.agentAddressLower = agentAddressLower
            self.attestationToken = attestationToken
            self.attestationExpiresAt = attestationExpiresAt
        }

        enum CodingKeys: String, CodingKey {
            case keyId, workspaceId, accountId, wallet, role, agentAddressLower, attestationToken,
                attestationExpiresAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            keyId = try c.decode(UUID.self, forKey: .keyId)
            workspaceId = try c.decode(String.self, forKey: .workspaceId)
            accountId = try c.decode(String.self, forKey: .accountId)
            wallet = try c.decode(String.self, forKey: .wallet)
            role = try c.decodeIfPresent(String.self, forKey: .role) ?? "member"
            agentAddressLower = try c.decode(String.self, forKey: .agentAddressLower)
            attestationToken = try c.decode(String.self, forKey: .attestationToken)
            attestationExpiresAt = try c.decode(Date.self, forKey: .attestationExpiresAt)
        }
    }

    private struct PendingChallenge {
        let agentAddressLower: String
        let wallet: String
        let expiresAt: Date
    }

    private var pendingChallenges: [String: PendingChallenge] = [:]
    private var workspaceKeys: [String: WorkspaceKeyRecord] = [:] {
        didSet { nonceIndex.replace(Set(workspaceKeys.keys)) }
    }
    private var didLoadPersistedKeys = false

    /// Synchronous mirror of `workspaceKeys.keys` for the HTTP auth gate,
    /// which runs on the NIO event loop and cannot hop onto this actor. The
    /// gate needs to know whether an agent-scoped key is *workspace-minted*
    /// (strict route allowlist) or a legacy pairing/invite key (unchanged
    /// contract) before dispatching the request. Kept in lock-step by the
    /// `didSet` above; lazily seeds itself from `keys.json` so a request
    /// arriving before the actor has been touched after a restart is still
    /// classified correctly.
    nonisolated let nonceIndex = WorkspaceKeyNonceIndex()

    /// `true` when `nonce` (the in-token key nonce the auth gate publishes as
    /// `accessKeyId`) belongs to a live workspace-minted key on this host.
    nonisolated static func isWorkspaceMintedKey(nonce: String?) -> Bool {
        guard let nonce, !nonce.isEmpty else { return false }
        return shared.nonceIndex.contains(nonce)
    }

    final class WorkspaceKeyNonceIndex: @unchecked Sendable {
        private let lock = NSLock()
        private var nonces: Set<String> = []
        private var loaded = false
        private var fileURL: () -> URL = {
            OsaurusPaths.workspaces().appendingPathComponent("keys.json")
        }

        func contains(_ nonce: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            loadIfNeededLocked()
            return nonces.contains(nonce)
        }

        func replace(_ set: Set<String>) {
            lock.lock()
            defer { lock.unlock() }
            nonces = set
            loaded = true
        }

        /// Test seam: mark a single nonce as workspace-minted without going
        /// through the redeem flow (parallel-safe, unlike `replace`).
        func insert(_ nonce: String) {
            lock.lock()
            defer { lock.unlock() }
            loadIfNeededLocked()
            nonces.insert(nonce)
        }

        func remove(_ nonce: String) {
            lock.lock()
            defer { lock.unlock() }
            nonces.remove(nonce)
        }

        /// Test seam: point at a different `keys.json` and forget everything.
        func reset(fileURL: @escaping () -> URL) {
            lock.lock()
            defer { lock.unlock() }
            self.fileURL = fileURL
            nonces = []
            loaded = false
        }

        private func loadIfNeededLocked() {
            guard !loaded else { return }
            loaded = true
            guard let data = try? Data(contentsOf: fileURL()),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            // Expiry is enforced by the in-token `exp`; a stale nonce here
            // only means "classify as workspace key", which is the safe side.
            nonces = Set(object.keys)
        }
    }

    /// Where the key records live. Injectable for tests.
    var keyRecordsFileURL: @Sendable () -> URL = {
        OsaurusPaths.workspaces().appendingPathComponent("keys.json")
    }

    private var cachedAttestationKey: (publicKey: String, fetchedAt: Date)?
    private static let attestationKeyMaxAge: TimeInterval = 3600

    /// Injectable seams for tests (nonisolated setup, actor-hop use).
    var fetchAttestationKey: @Sendable () async throws -> String = {
        try await OsaurusRouterAPIClient.shared.workspacesAttestationKey().publicKey
    }
    /// Returns the lowercase addresses currently shared to `workspaceId`, or
    /// throws when the roster can't be fetched.
    var fetchSharedAddresses: @Sendable (_ workspaceId: String) async throws -> Set<String> = {
        workspaceId in
        let agents = try await OsaurusRouterAPIClient.shared.workspaceAgents(id: workspaceId)
        return Set(agents.map { $0.agentAddress.lowercased() })
    }
    var verifyCurrentAccess: @Sendable (String, String, String) async throws -> Void = { workspaceId, address, token in
        try await OsaurusRouterAPIClient.shared.verifyWorkspaceAgentAccess(
            workspaceId: workspaceId,
            agentAddress: address,
            attestation: token
        )
    }

    var now: @Sendable () -> Date = { Date() }

    func setSeams(
        fetchAttestationKey: (@Sendable () async throws -> String)? = nil,
        fetchSharedAddresses: (@Sendable (_ workspaceId: String) async throws -> Set<String>)? = nil,
        verifyCurrentAccess: (@Sendable (String, String, String) async throws -> Void)? = nil,
        now: (@Sendable () -> Date)? = nil,
        keyRecordsFileURL: (@Sendable () -> URL)? = nil
    ) {
        if let fetchAttestationKey { self.fetchAttestationKey = fetchAttestationKey }
        if let fetchSharedAddresses { self.fetchSharedAddresses = fetchSharedAddresses }
        if let verifyCurrentAccess { self.verifyCurrentAccess = verifyCurrentAccess }
        if let now { self.now = now }
        if let keyRecordsFileURL {
            self.keyRecordsFileURL = keyRecordsFileURL
            workspaceKeys = [:]
            didLoadPersistedKeys = false
            // After the `didSet` above marked the index loaded-and-empty:
            // re-arm it so it lazily reads the injected file like a fresh host.
            nonceIndex.reset(fileURL: keyRecordsFileURL)
        }
        cachedAttestationKey = nil
    }

    // MARK: - Entry point

    /// Handles one `/pair-invite` workspace-mode envelope: step one (no nonce)
    /// issues a challenge; step two (nonce + signature) verifies and mints.
    func handle(_ payload: WorkspacePairRedeemEnvelope.Payload) async -> Outcome {
        guard payload.v == 1 else {
            return .rejected(.malformedRequest("Unsupported team_redeem version"))
        }
        let attestation: WorkspaceMembershipAttestation
        do {
            attestation = try await verifyAttestation(token: payload.attestation)
        } catch let rejection as WorkspaceRedeemRejection {
            // No verified workspace to attribute this to; the attestation
            // itself is what failed. The Insights request log still has the
            // 4xx row.
            return .rejected(rejection)
        } catch {
            return .rejected(.attestationInvalid(error.localizedDescription))
        }

        guard let nonce = payload.nonce, let signature = payload.walletSignature else {
            return issueChallenge(
                agentAddress: payload.agentAddress,
                wallet: attestation.payload.wallet
            )
        }
        let outcome = await redeem(
            payload: payload,
            attestation: attestation,
            nonce: nonce,
            walletSignature: signature
        )
        if case .rejected(let rejection) = outcome {
            await WorkspaceAuditLog.shared.recordAttestationDenied(
                attestation: attestation,
                agentAddress: payload.agentAddress,
                rejection: rejection
            )
        }
        return outcome
    }

    // MARK: - Step one: challenge

    /// Upper bound on outstanding challenges (mirrors
    /// `PairingChallengeStore.maxOutstanding`). Past the cap the OLDEST
    /// challenge is evicted so a flood of step-one requests cannot grow this
    /// table unbounded; a legitimate redeemer simply re-requests a challenge.
    static let maxPendingChallenges = 256

    private func issueChallenge(agentAddress: String, wallet: String) -> Outcome {
        prunePendingChallenges()
        while pendingChallenges.count >= Self.maxPendingChallenges,
            let oldest = pendingChallenges.min(by: { $0.value.expiresAt < $1.value.expiresAt })
        {
            pendingChallenges.removeValue(forKey: oldest.key)
        }
        var nonceBytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes) == errSecSuccess
        else {
            return .rejected(.mintFailed)
        }
        let nonce = Data(nonceBytes).base64urlEncoded
        pendingChallenges[nonce] = PendingChallenge(
            agentAddressLower: agentAddress.lowercased(),
            wallet: wallet.lowercased(),
            expiresAt: now().addingTimeInterval(WorkspaceAgentAccess.challengeTTL)
        )
        return .challenge(nonce: nonce, expiresIn: Int(WorkspaceAgentAccess.challengeTTL))
    }

    private func prunePendingChallenges() {
        let current = now()
        pendingChallenges = pendingChallenges.filter { $0.value.expiresAt > current }
    }

    // MARK: - Step two: verify + mint

    private func redeem(
        payload: WorkspacePairRedeemEnvelope.Payload,
        attestation: WorkspaceMembershipAttestation,
        nonce: String,
        walletSignature: String
    ) async -> Outcome {
        // Single-use nonce, bound to the same agent + wallet it was issued to.
        guard let challenge = pendingChallenges.removeValue(forKey: nonce),
            challenge.expiresAt > now(),
            challenge.agentAddressLower == payload.agentAddress.lowercased(),
            challenge.wallet == attestation.payload.wallet.lowercased()
        else {
            return .rejected(.unknownChallenge)
        }

        // The redeemer must control the attested wallet: EIP-191 over the
        // challenge must recover to `payload.wallet`.
        // Current wording first; the pre-rename wording is accepted so a
        // teammate on an older build can still redeem.
        let candidateMessages = [
            WorkspaceAgentAccess.redeemMessage(agentAddress: payload.agentAddress, nonce: nonce),
            WorkspaceAgentAccess.legacyRedeemMessage(agentAddress: payload.agentAddress, nonce: nonce),
        ]
        let expectedWallet = attestation.payload.wallet.lowercased()
        guard let signatureData = Data(hexEncoded: walletSignature.strippingHexPrefix),
            signatureData.count == 65,
            candidateMessages.contains(where: { message in
                guard
                    let recovered = try? recoverAddress(
                        payload: Data(message.utf8),
                        signature: signatureData,
                        domainPrefix: "Ethereum Signed Message"
                    )
                else { return false }
                return recovered.lowercased() == expectedWallet
            })
        else {
            return .rejected(.badWalletSignature)
        }

        // The redeemed agent must exist locally (this is the sharer's box).
        let addressLower = payload.agentAddress.lowercased()
        let resolved:
            (index: UInt32, address: String, name: String, description: String, model: String?)? =
                await MainActor.run {
                    guard
                        let agent = AgentManager.shared.agents.first(where: {
                            ($0.agentAddress?.lowercased() ?? "") == addressLower
                        }),
                        let index = agent.agentIndex,
                        let address = agent.agentAddress
                    else { return nil }
                    return (
                        index, address, agent.name, agent.description,
                        AgentManager.shared.effectiveModel(for: agent.id)
                    )
                }
        guard let resolved else {
            return .rejected(.agentNotFound)
        }
        let agentIndex = resolved.index
        let agentAddress = resolved.address

        // MUST from the spec: check the agent is still actively shared with
        // the attested workspace before honoring the attestation. Fail closed —
        // an unreachable router refuses rather than trusting a stale share.
        do {
            try await verifyCurrentAccess(attestation.payload.workspaceId, addressLower, payload.attestation)
            let shared = try await fetchSharedAddresses(attestation.payload.workspaceId)
            guard shared.contains(addressLower) else {
                return .rejected(.notShared)
            }
        } catch {
            return .rejected(.rosterUnavailable)
        }

        // Mint an agent-scoped key that dies exactly when the attestation
        // does. Re-presenting a fresh attestation mints a fresh key; nothing
        // extends silently.
        let memberLabel = OsaurusRouterWorkspacePerson.shortWallet(attestation.payload.wallet)
        let fullKey: String
        let keyInfo: AccessKeyInfo
        do {
            (fullKey, keyInfo) = try APIKeyManager.shared.generate(
                label: "Workspace – \(memberLabel)",
                expiration: .days30,
                agentIndex: agentIndex,
                overrideExpiresAt: attestation.expiresAt
            )
        } catch {
            return .rejected(.mintFailed)
        }

        // One live key per (workspace, member, agent): revoke the one a refresh
        // replaces so abandoned keys don't pile up in the key list.
        loadPersistedKeysIfNeeded()
        let previous = workspaceKeys.first { _, record in
            record.workspaceId == attestation.payload.workspaceId
                && record.wallet == attestation.payload.wallet.lowercased()
                && record.agentAddressLower == addressLower
        }
        if let previous {
            workspaceKeys.removeValue(forKey: previous.key)
            APIKeyManager.shared.delete(id: previous.value.keyId)
            await WorkspaceAuditLog.shared.recordKeyRevoked(
                record: previous.value, reason: .replacedByRefresh
            )
        }

        let record = WorkspaceKeyRecord(
            keyId: keyInfo.id,
            workspaceId: attestation.payload.workspaceId,
            accountId: attestation.payload.accountId,
            wallet: attestation.payload.wallet.lowercased(),
            role: attestation.payload.typedRole.rawValue,
            agentAddressLower: addressLower,
            attestationToken: attestation.token,
            attestationExpiresAt: attestation.expiresAt
        )
        workspaceKeys[keyInfo.nonce] = record

        // HPKE-seal when the redeemer supplied an ephemeral key (relay
        // terminates TLS). Fail closed on an unusable encPub.
        var sealed: PairingKeyEnvelope.Sealed?
        var apiKeyForWire = fullKey
        if let encPub = payload.encPub, !encPub.isEmpty {
            guard
                let sealedKey = try? PairingKeyEnvelope.seal(
                    secret: fullKey,
                    recipientPublicKeyBase64url: encPub,
                    info: PairingKeyEnvelope.info(agentAddress: agentAddress, nonce: nonce)
                )
            else {
                workspaceKeys.removeValue(forKey: keyInfo.nonce)
                APIKeyManager.shared.delete(id: keyInfo.id)
                persistKeys()
                return .rejected(.malformedRequest("Invalid encryption key"))
            }
            sealed = sealedKey
            apiKeyForWire = ""
        }
        persistKeys()

        await WorkspaceAuditLog.shared.recordAttestationGranted(
            record: record,
            agentName: resolved.name,
            sealed: sealed != nil
        )

        return .granted(
            RedeemGrant(
                agentAddress: agentAddress,
                agentName: resolved.name,
                agentDescription: resolved.description.isEmpty ? nil : resolved.description,
                agentModel: resolved.model,
                apiKeyForWire: apiKeyForWire,
                sealedApiKey: sealed
            )
        )
    }

    // MARK: - Attestation verification (offline + cached key)

    /// Verifies against the cached router key, refreshing it once on a
    /// signature/key failure (key rotation) before rejecting.
    private func verifyAttestation(token: String) async throws -> WorkspaceMembershipAttestation {
        let key = try await attestationKey(forceRefresh: false)
        do {
            return try WorkspaceMembershipAttestation.verify(
                token: token, publicKeyBase64URL: key, now: now()
            )
        } catch WorkspaceAttestationError.badSignature, WorkspaceAttestationError.malformedPublicKey {
            let freshKey = try await attestationKey(forceRefresh: true)
            do {
                return try WorkspaceMembershipAttestation.verify(
                    token: token, publicKeyBase64URL: freshKey, now: now()
                )
            } catch {
                throw Self.rejection(for: error)
            }
        } catch {
            throw Self.rejection(for: error)
        }
    }

    private static func rejection(for error: Error) -> WorkspaceRedeemRejection {
        switch error {
        case WorkspaceAttestationError.expired:
            return .attestationExpired
        case WorkspaceAttestationError.badSignature:
            return .attestationInvalid("signature verification failed")
        case WorkspaceAttestationError.unsupportedVersion:
            return .attestationInvalid("unsupported version")
        case WorkspaceAttestationError.malformedToken, WorkspaceAttestationError.malformedPublicKey:
            return .attestationInvalid("malformed token")
        default:
            return .attestationInvalid("verification failed")
        }
    }

    private func attestationKey(forceRefresh: Bool) async throws -> String {
        if !forceRefresh,
            let cached = cachedAttestationKey,
            now().timeIntervalSince(cached.fetchedAt) < Self.attestationKeyMaxAge
        {
            return cached.publicKey
        }
        do {
            let key = try await fetchAttestationKey()
            cachedAttestationKey = (key, now())
            return key
        } catch {
            // A stale-but-present key still beats rejecting outright while
            // the router is briefly unreachable.
            if let cached = cachedAttestationKey { return cached.publicKey }
            throw WorkspaceRedeemRejection.rosterUnavailable
        }
    }

    // MARK: - Caller attribution + revocation

    /// The record behind an inbound workspace-minted key (by the key's in-token
    /// nonce, which the auth gate publishes as `accessKeyId`). `nil` when the
    /// key isn't workspace-minted or its attestation has lapsed — the spec forbids
    /// sending a stale attestation, so expiry means "omit", never "best
    /// effort".
    func workspaceKeyRecord(forKeyNonce nonce: String) -> WorkspaceKeyRecord? {
        loadPersistedKeysIfNeeded()
        guard let record = workspaceKeys[nonce] else { return nil }
        guard record.attestationExpiresAt > now() else {
            workspaceKeys.removeValue(forKey: nonce)
            persistKeys()
            return nil
        }
        return record
    }

    /// All live (unexpired) workspace-minted key records. Expired entries are
    /// pruned as a side effect.
    func liveKeyRecords() -> [WorkspaceKeyRecord] {
        loadPersistedKeysIfNeeded()
        pruneExpiredKeys()
        return Array(workspaceKeys.values)
    }

    /// Unshare/delete revocation contract: kill every workspace-minted key for
    /// this (workspace, agent) immediately instead of letting them ride out the
    /// rest of their attestation window.
    func invalidateKeys(workspaceId: String, agentAddress: String) async {
        await MainActor.run {
            InboundSharedRunBridge.shared.stopWorkspaceRuns(workspaceId: workspaceId, agentAddress: agentAddress)
        }
        loadPersistedKeysIfNeeded()
        let addressLower = agentAddress.lowercased()
        let matching = workspaceKeys.filter { _, record in
            record.workspaceId == workspaceId && record.agentAddressLower == addressLower
        }
        for (nonce, record) in matching {
            workspaceKeys.removeValue(forKey: nonce)
            APIKeyManager.shared.revoke(id: record.keyId)
            await WorkspaceAuditLog.shared.recordKeyRevoked(record: record, reason: .agentUnshared)
        }
        if !matching.isEmpty { persistKeys() }
    }

    /// Workspace deletion: revoke every key minted for that workspace.
    func invalidateKeys(workspaceId: String) async {
        await MainActor.run { InboundSharedRunBridge.shared.stopWorkspaceRuns(workspaceId: workspaceId) }
        loadPersistedKeysIfNeeded()
        let matching = workspaceKeys.filter { $0.value.workspaceId == workspaceId }
        for (nonce, record) in matching {
            workspaceKeys.removeValue(forKey: nonce)
            APIKeyManager.shared.revoke(id: record.keyId)
            await WorkspaceAuditLog.shared.recordKeyRevoked(record: record, reason: .workspaceDeleted)
        }
        if !matching.isEmpty { persistKeys() }
    }

    func validateCurrentAccess(_ record: WorkspaceKeyRecord) async throws {
        guard record.attestationExpiresAt > now() else { throw WorkspaceRedeemRejection.attestationExpired }
        try await verifyCurrentAccess(record.workspaceId, record.agentAddressLower, record.attestationToken)
    }

    func reconcile(snapshot: WorkspaceSyncSnapshot) async {
        loadPersistedKeysIfNeeded()
        let rejected = workspaceKeys.filter { _, record in
            guard let entry = snapshot.workspaces.first(where: { $0.workspace.id == record.workspaceId }) else {
                return true
            }
            return !entry.agents.contains(where: { $0.agentAddress.lowercased() == record.agentAddressLower })
                || !entry.members.contains(where: {
                    $0.accountId == record.accountId && $0.walletAddress?.lowercased() == record.wallet.lowercased()
                })
        }
        for (nonce, record) in rejected {
            workspaceKeys.removeValue(forKey: nonce)
            APIKeyManager.shared.revoke(id: record.keyId)
            await MainActor.run {
                InboundSharedRunBridge.shared.stopWorkspaceRuns(
                    workspaceId: record.workspaceId,
                    agentAddress: record.agentAddressLower,
                    callerWallet: record.wallet
                )
            }
        }
        if !rejected.isEmpty { persistKeys() }
    }

    // MARK: - Persistence

    private func loadPersistedKeysIfNeeded() {
        guard !didLoadPersistedKeys else { return }
        didLoadPersistedKeys = true
        let url = keyRecordsFileURL()
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let loaded = try? decoder.decode([String: WorkspaceKeyRecord].self, from: data) else {
            return
        }
        // Persisted records never override anything minted this session.
        for (nonce, record) in loaded where workspaceKeys[nonce] == nil {
            workspaceKeys[nonce] = record
        }
        pruneExpiredKeys()
    }

    private func pruneExpiredKeys() {
        let current = now()
        let before = workspaceKeys.count
        workspaceKeys = workspaceKeys.filter { $0.value.attestationExpiresAt > current }
        if workspaceKeys.count != before { persistKeys() }
    }

    private func persistKeys() {
        let url = keyRecordsFileURL()
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if workspaceKeys.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                return
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(workspaceKeys)
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
        } catch {
            NSLog("[Osaurus][Workspaces] Failed to persist workspace key records: %@", "\(error)")
        }
    }
}

extension String {
    fileprivate var strippingHexPrefix: String {
        hasPrefix("0x") ? String(dropFirst(2)) : self
    }
}
