//
//  OwnerDeviceAccessHost.swift
//  osaurus
//
//  Host side of the "owner redeem" handshake: a device that holds the SAME
//  master identity as this host (a phone signed into the user's iCloud
//  Keychain, a second Mac restored from the recovery phrase) obtains an
//  agent-scoped `osk-v1` access key for one of the agents hosted here
//  without a Workspace, a router attestation, or a per-agent invite.
//
//  The proof is the master key itself: the redeemer signs the host's
//  single-use nonce with the master (EIP-191), and the host accepts only if
//  the recovered address equals its OWN master address. Nothing else is
//  consulted — no router, no roster, no pairing prompt — because a party
//  who can produce that signature already owns every agent on this box.
//
//  Runs on the same public `POST /pair-invite` route as the invite and
//  `team_redeem` flows (so relays need no new route), under the same rate
//  limiter, redaction, and HPKE sealing contract.
//

import CryptoKit
import Foundation
import LocalAuthentication

// MARK: - Constants

enum OwnerDeviceAccess {
    /// EIP-191 message the redeeming device signs with the MASTER key over
    /// the host's single-use nonce. Recovering the signer must yield the
    /// host's own master address.
    static func redeemMessage(agentAddress: String, nonce: String) -> String {
        "osaurus-owner:redeem:\(agentAddress.lowercased()):\(nonce)"
    }

    /// How long a host-issued owner nonce stays valid (same as workspaces).
    static let challengeTTL: TimeInterval = WorkspaceAgentAccess.challengeTTL

    /// Lifetime of an owner-device key. Long enough that a phone is not
    /// re-pairing weekly; the redeem can be repeated any time and each
    /// repeat replaces (revokes) the previous key for that device + agent.
    static let keyExpiration: AccessKeyExpiration = .days90

    /// Label prefix in the Identity → access-key list, so a user can tell
    /// their own devices' keys from pairings and workspace keys.
    static let labelPrefix = "Owner device – "

    static let maxDeviceIdLength = 64
    static let maxDeviceNameLength = 80
}

// MARK: - Wire shapes

/// `{"owner_redeem": {…}}` envelope on `POST /pair-invite`. Step one carries
/// agent + device (host answers with `owner_challenge`); step two adds the
/// nonce and the master-key signature (host answers with the access key in
/// the ordinary `PairInviteResponse` shape).
struct OwnerPairRedeemEnvelope: Codable, Equatable, Sendable {
    struct Payload: Codable, Equatable, Sendable {
        let v: Int
        /// Which hosted agent the device wants a key for.
        let agentAddress: String
        /// The redeeming device's ID (`DeviceKey` 8-hex on Osaurus clients;
        /// any stable opaque token ≤ 64 chars). One live key per
        /// `(device_id, agent)`.
        let deviceId: String
        /// Human label for the key ("iPhone", "Studio"). Optional.
        let deviceName: String?
        /// Step two only: the host's single-use challenge nonce.
        let nonce: String?
        /// Step two only: EIP-191 MASTER-key signature over
        /// `osaurus-owner:redeem:<agent_address_lowercase>:<nonce>`.
        let walletSignature: String?
        /// Step two: ephemeral X25519 public key (base64url, 32 raw bytes)
        /// the host HPKE-seals the minted key to. REQUIRED — the relay
        /// terminates TLS and is untrusted by design, so a 90-day agent key
        /// never crosses it in plaintext. Step two without a valid key is
        /// `400`, before the nonce is consumed.
        let encPub: String?

        enum CodingKeys: String, CodingKey {
            case v, nonce, encPub
            case agentAddress = "agent_address"
            case deviceId = "device_id"
            case deviceName = "device_name"
            case walletSignature = "wallet_signature"
        }
    }

    let ownerRedeem: Payload

    enum CodingKeys: String, CodingKey {
        case ownerRedeem = "owner_redeem"
    }
}

/// Step-one response.
struct OwnerPairChallengeResponse: Codable, Equatable, Sendable {
    struct Challenge: Codable, Equatable, Sendable {
        let nonce: String
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case nonce
            case expiresIn = "expires_in"
        }
    }

    let ownerChallenge: Challenge

    enum CodingKeys: String, CodingKey {
        case ownerChallenge = "owner_challenge"
    }
}

// MARK: - Rejections

enum OwnerRedeemRejection: Error, Equatable {
    case malformedRequest(String)
    case unknownChallenge
    /// Signature does not recover to this host's master address — the
    /// caller is not the owner (or the host has no unlocked master).
    case notOwner
    case noIdentity
    case agentNotFound
    case builtInAgent
    case mintFailed

    var httpStatus: Int {
        switch self {
        case .malformedRequest: return 400
        case .unknownChallenge, .notOwner: return 401
        case .noIdentity: return 503
        case .agentNotFound: return 404
        case .builtInAgent: return 403
        case .mintFailed: return 500
        }
    }

    var wireMessage: String {
        switch self {
        case .malformedRequest(let detail): return detail
        case .unknownChallenge: return "Unknown or expired challenge nonce"
        case .notOwner: return "Signature does not match this host's identity"
        case .noIdentity: return "Host identity is unavailable right now"
        case .agentNotFound: return "Agent address not found on this server"
        case .builtInAgent: return "Built-in agents are not reachable from other devices"
        case .mintFailed: return "Failed to mint access key"
        }
    }
}

// MARK: - Host

actor OwnerDeviceAccessHost {
    static let shared = OwnerDeviceAccessHost()

    struct Grant: Sendable {
        let agentAddress: String
        let agentName: String
        let agentDescription: String?
        let agentModel: String?
        /// The minted key, HPKE-sealed to the redeemer's `encPub`. Owner
        /// redeem never returns a plaintext key.
        let sealedApiKey: PairingKeyEnvelope.Sealed
    }

    enum Outcome: Sendable {
        case challenge(nonce: String, expiresIn: Int)
        case granted(Grant)
        case rejected(OwnerRedeemRejection)
    }

    /// One minted owner-device key. Persisted to
    /// `~/.osaurus/identity/owner-devices.json` (keyed by the key's in-token
    /// nonce) so the Identity UI can list and revoke a device's keys after a
    /// restart. Expiry lives in the token itself.
    struct OwnerDeviceKeyRecord: Codable, Sendable, Equatable {
        let keyId: UUID
        let deviceId: String
        let deviceName: String
        let agentAddressLower: String
        let issuedAt: Date
    }

    private struct PendingChallenge {
        let agentAddressLower: String
        let deviceId: String
        let expiresAt: Date
    }

    /// Outstanding step-one nonces. Bounded two ways, because step one is
    /// unauthenticated and deliberately does not reveal whether the agent
    /// exists (so it cannot filter on the agent):
    ///   1. one outstanding challenge per `(agent, device_id)` — a repeat
    ///      request replaces (invalidates) the earlier nonce for that pair,
    ///      so a single caller cannot grow the table by re-asking;
    ///   2. a hard cap on the whole table, oldest-expiring evicted first.
    /// Entries also expire after `challengeTTL`.
    private var pendingChallenges: [String: PendingChallenge] = [:]
    private var keyRecords: [String: OwnerDeviceKeyRecord] = [:]
    private var didLoadPersistedKeys = false

    /// Hard upper bound on outstanding challenges (shared with workspace
    /// redeem); the oldest-expiring entry is evicted past the cap.
    static let maxPendingChallenges = WorkspaceAgentAccessHost.maxPendingChallenges

    /// Test seam: how many challenges are outstanding right now.
    var pendingChallengeCount: Int { pendingChallenges.count }

    // MARK: Seams

    var now: @Sendable () -> Date = { Date() }

    var keyRecordsFileURL: @Sendable () -> URL = {
        OsaurusPaths.root().appendingPathComponent("identity", isDirectory: true)
            .appendingPathComponent("owner-devices.json")
    }

    /// This host's master address, derived without any UI prompt (the
    /// request arrives over the relay while the app may be unattended). Nil
    /// when the master is missing or locked.
    var resolveHostWallet: @Sendable () -> String? = {
        guard MasterKey.exists() else { return nil }
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 300
        context.interactionNotAllowed = true
        guard var masterKey = try? MasterKey.getPrivateKey(context: context) else { return nil }
        defer { masterKey.zeroOut() }
        return try? deriveOsaurusId(from: masterKey)
    }

    /// What the host knows about a locally hosted agent, by address.
    struct ResolvedAgent: Sendable {
        let id: UUID
        let keyPath: AgentKeyPath
        let address: String
        let name: String
        let description: String
        let model: String?
        let isBuiltIn: Bool
    }

    /// Local agent lookup by lowercased address. Seam so the built-in gate
    /// can be exercised (the manager refuses to give the built-in an
    /// address in the first place, which is the production invariant).
    var resolveAgent: @Sendable (_ addressLower: String) async -> ResolvedAgent? = { addressLower in
        await MainActor.run {
            guard
                let agent = AgentManager.shared.agents.first(where: {
                    ($0.agentAddress?.lowercased() ?? "") == addressLower
                }),
                let keyPath = agent.agentKeyPath,
                let address = agent.agentAddress
            else { return nil }
            return ResolvedAgent(
                id: agent.id,
                keyPath: keyPath,
                address: address,
                name: agent.name,
                description: agent.description,
                model: AgentManager.shared.effectiveModel(for: agent.id),
                isBuiltIn: agent.isBuiltIn
            )
        }
    }

    func setSeams(
        resolveHostWallet: (@Sendable () -> String?)? = nil,
        resolveAgent: (@Sendable (_ addressLower: String) async -> ResolvedAgent?)? = nil,
        now: (@Sendable () -> Date)? = nil,
        keyRecordsFileURL: (@Sendable () -> URL)? = nil
    ) {
        if let resolveHostWallet { self.resolveHostWallet = resolveHostWallet }
        if let resolveAgent { self.resolveAgent = resolveAgent }
        if let now { self.now = now }
        if let keyRecordsFileURL {
            self.keyRecordsFileURL = keyRecordsFileURL
            keyRecords = [:]
            didLoadPersistedKeys = false
        }
    }

    // MARK: Entry point

    func handle(_ payload: OwnerPairRedeemEnvelope.Payload) async -> Outcome {
        guard payload.v == 1 else {
            return .rejected(.malformedRequest("Unsupported owner_redeem version"))
        }
        guard Self.isPlausibleAddress(payload.agentAddress) else {
            return .rejected(.malformedRequest("agent_address must be a 0x-prefixed 20-byte hex address"))
        }
        let deviceId = payload.deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deviceId.isEmpty, deviceId.count <= OwnerDeviceAccess.maxDeviceIdLength,
            deviceId.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." })
        else {
            return .rejected(.malformedRequest("device_id must be 1–64 characters of [A-Za-z0-9._-]"))
        }
        if let name = payload.deviceName, name.count > OwnerDeviceAccess.maxDeviceNameLength {
            return .rejected(.malformedRequest("device_name must be at most 80 characters"))
        }

        guard let nonce = payload.nonce, let signature = payload.walletSignature else {
            return issueChallenge(agentAddress: payload.agentAddress, deviceId: deviceId)
        }
        // Step two must name a usable recipient key BEFORE anything is
        // consumed or minted: the nonce survives a malformed retry, and no
        // key exists to leak or clean up.
        guard let encPub = payload.encPub, Self.isValidEncPub(encPub) else {
            return .rejected(
                .malformedRequest("encPub is required: a base64url X25519 public key (32 bytes)")
            )
        }
        return await redeem(
            payload: payload,
            deviceId: deviceId,
            nonce: nonce,
            walletSignature: signature,
            encPub: encPub
        )
    }

    static func isPlausibleAddress(_ address: String) -> Bool {
        guard address.hasPrefix("0x"), address.count == 42 else { return false }
        return address.dropFirst(2).allSatisfy(\.isHexDigit)
    }

    /// Same parse `PairingKeyEnvelope.seal` performs, run up front.
    static func isValidEncPub(_ encPub: String) -> Bool {
        guard let raw = Data(base64urlEncoded: encPub), raw.count == 32 else { return false }
        return (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)) != nil
    }

    // MARK: Step one

    private func issueChallenge(agentAddress: String, deviceId: String) -> Outcome {
        prunePendingChallenges()
        let addressLower = agentAddress.lowercased()

        // One outstanding challenge per (agent, device): re-asking replaces
        // the earlier nonce instead of adding a second entry.
        for (existingNonce, pending) in pendingChallenges
        where pending.agentAddressLower == addressLower && pending.deviceId == deviceId {
            pendingChallenges.removeValue(forKey: existingNonce)
        }

        // Hard cap on the table regardless of how many distinct pairs ask.
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
            agentAddressLower: addressLower,
            deviceId: deviceId,
            expiresAt: now().addingTimeInterval(OwnerDeviceAccess.challengeTTL)
        )
        return .challenge(nonce: nonce, expiresIn: Int(OwnerDeviceAccess.challengeTTL))
    }

    private func prunePendingChallenges() {
        let current = now()
        pendingChallenges = pendingChallenges.filter { $0.value.expiresAt > current }
    }

    // MARK: Step two

    private func redeem(
        payload: OwnerPairRedeemEnvelope.Payload,
        deviceId: String,
        nonce: String,
        walletSignature: String,
        encPub: String
    ) async -> Outcome {
        // Single-use nonce, bound to the agent + device it was issued for.
        let addressLower = payload.agentAddress.lowercased()
        guard let challenge = pendingChallenges.removeValue(forKey: nonce),
            challenge.expiresAt > now(),
            challenge.agentAddressLower == addressLower,
            challenge.deviceId == deviceId
        else {
            return .rejected(.unknownChallenge)
        }

        // The signer must be THIS host's master. Resolve the host wallet
        // first so a locked/missing master is reported as such rather than
        // as a bad signature.
        guard let hostWallet = resolveHostWallet()?.lowercased() else {
            return .rejected(.noIdentity)
        }
        let message = OwnerDeviceAccess.redeemMessage(agentAddress: payload.agentAddress, nonce: nonce)
        let signatureHex = walletSignature.hasPrefix("0x") ? String(walletSignature.dropFirst(2)) : walletSignature
        guard let signatureData = Data(hexEncoded: signatureHex), signatureData.count == 65,
            let recovered = try? recoverAddress(
                payload: Data(message.utf8),
                signature: signatureData,
                domainPrefix: "Ethereum Signed Message"
            ),
            recovered.lowercased() == hostWallet
        else {
            return .rejected(.notOwner)
        }

        // The agent must be hosted here and must not be the built-in.
        guard let resolved = await resolveAgent(addressLower) else { return .rejected(.agentNotFound) }
        if resolved.isBuiltIn
            || Agent.rejectBuiltInForExternalSurface(resolved.id, source: "http/pair-invite/owner_redeem") != nil
        {
            return .rejected(.builtInAgent)
        }

        // Mint.
        let deviceName = Self.cleanDeviceName(payload.deviceName)
        let fullKey: String
        let keyInfo: AccessKeyInfo
        do {
            (fullKey, keyInfo) = try APIKeyManager.shared.generate(
                label: OwnerDeviceAccess.labelPrefix + deviceName,
                expiration: OwnerDeviceAccess.keyExpiration,
                agentKeyPath: resolved.keyPath
            )
        } catch {
            return .rejected(.mintFailed)
        }

        // One live key per (device, agent): a re-redeem replaces the old key.
        loadPersistedKeysIfNeeded()
        let previous = keyRecords.filter { _, record in
            record.deviceId == deviceId && record.agentAddressLower == addressLower
        }
        for (recordNonce, record) in previous {
            keyRecords.removeValue(forKey: recordNonce)
            APIKeyManager.shared.delete(id: record.keyId)
        }
        keyRecords[keyInfo.nonce] = OwnerDeviceKeyRecord(
            keyId: keyInfo.id,
            deviceId: deviceId,
            deviceName: deviceName,
            agentAddressLower: addressLower,
            issuedAt: now()
        )

        // HPKE-seal to the (pre-validated) ephemeral key. There is no
        // plaintext path: if sealing still fails, the minted key is deleted
        // and nothing is returned.
        guard
            let sealed = try? PairingKeyEnvelope.seal(
                secret: fullKey,
                recipientPublicKeyBase64url: encPub,
                info: PairingKeyEnvelope.info(agentAddress: resolved.address, nonce: nonce)
            )
        else {
            keyRecords.removeValue(forKey: keyInfo.nonce)
            APIKeyManager.shared.delete(id: keyInfo.id)
            persistKeys()
            return .rejected(.mintFailed)
        }
        persistKeys()

        return .granted(
            Grant(
                agentAddress: resolved.address,
                agentName: resolved.name,
                agentDescription: resolved.description.isEmpty ? nil : resolved.description,
                agentModel: resolved.model,
                sealedApiKey: sealed
            )
        )
    }

    static func cleanDeviceName(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Device" }
        return String(trimmed.prefix(OwnerDeviceAccess.maxDeviceNameLength))
    }

    // MARK: Records + revocation

    /// Every owner-device key record this host still knows about (keys may
    /// have expired in-token; the access-key list is the source of truth
    /// for validity).
    func keyRecordsSnapshot() -> [OwnerDeviceKeyRecord] {
        loadPersistedKeysIfNeeded()
        return Array(keyRecords.values).sorted { $0.issuedAt > $1.issuedAt }
    }

    /// Revoke every key minted for one device (all agents). Returns the
    /// number of keys revoked.
    @discardableResult
    func revokeKeys(deviceId: String) -> Int {
        loadPersistedKeysIfNeeded()
        let matching = keyRecords.filter { $0.value.deviceId == deviceId }
        for (nonce, record) in matching {
            keyRecords.removeValue(forKey: nonce)
            APIKeyManager.shared.revoke(id: record.keyId)
        }
        if !matching.isEmpty { persistKeys() }
        return matching.count
    }

    /// Drop records for an agent whose address was rotated or revoked (the
    /// keys themselves are already revoked by `AgentManager`).
    func forgetRecords(agentAddress: String) {
        loadPersistedKeysIfNeeded()
        let lower = agentAddress.lowercased()
        let before = keyRecords.count
        keyRecords = keyRecords.filter { $0.value.agentAddressLower != lower }
        if keyRecords.count != before { persistKeys() }
    }

    // MARK: Persistence

    private func loadPersistedKeysIfNeeded() {
        guard !didLoadPersistedKeys else { return }
        didLoadPersistedKeys = true
        guard let data = try? Data(contentsOf: keyRecordsFileURL()) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let loaded = try? decoder.decode([String: OwnerDeviceKeyRecord].self, from: data) else { return }
        for (nonce, record) in loaded where keyRecords[nonce] == nil {
            keyRecords[nonce] = record
        }
    }

    private func persistKeys() {
        let url = keyRecordsFileURL()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if keyRecords.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                return
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(keyRecords).write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("[Osaurus][Identity] Failed to persist owner-device key records: %@", "\(error)")
        }
    }
}
