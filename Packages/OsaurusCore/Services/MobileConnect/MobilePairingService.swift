//
//  MobilePairingService.swift
//  osaurus
//
//  Mobile pairing: lets exactly one phone (the Osaurus iPhone app) pair
//  with this Mac by typing a 6-digit code shown in Settings → Mobile.
//
//  Flow:
//    1. The user clicks "Generate Pairing Code". We mint a master-scoped
//       `osk-v1` key right away — minting reads the Master Key, which needs
//       biometric auth, and the user is at the Mac at this moment — and hold
//       it in memory next to a fresh `PairingCode`.
//    2. The phone POSTs the code with an ephemeral X25519 key to
//       `POST /pair/code` (LAN only). On a match we HPKE-seal the key plus
//       the agent roster (ids + crypto addresses the phone pins for the
//       Secure Channel) to the phone's key, record the device, and revoke
//       whatever phone was paired before (one phone per Mac).
//    3. An unused code expires after `PairingCode.ttl` and its key is
//       deleted; so is one locked out by too many wrong guesses.
//
//  Wire format: docs/MOBILE_PROTOCOL.md §11.
//

import Combine
import Foundation

// MARK: - Wire types

struct MobilePairRequest: Decodable, Sendable {
    let v: Int
    let code: String
    let deviceId: String
    let deviceName: String
    /// Phone's ephemeral X25519 public key (base64url) the response is sealed to.
    let encPub: String
    /// Set by the iPhone app when running in the iOS Simulator (shown as a badge).
    var isSimulator: Bool? = nil
}

struct MobilePairResponse: Codable, Sendable {
    let v: Int
    /// HPKE-sealed `MobilePairPayload` JSON (see `MobilePairingService.envelopeInfo`).
    let sealed: PairingKeyEnvelope.Sealed
}

/// Pairing v2, step one (`POST /pair/code`, `v: 2`): the phone's SPAKE2
/// share. The code itself never travels.
struct MobilePairStartRequest: Decodable, Sendable {
    let v: Int
    let deviceId: String
    let deviceName: String
    /// pA (base64url, compressed secp256k1 point).
    let share: String
    var isSimulator: Bool? = nil
}

struct MobilePairStartResponse: Codable, Sendable {
    let v: Int
    /// Names this exchange in step two.
    let exchange: String
    /// pB (base64url).
    let share: String
    /// cB (base64url): the Mac's proof it used the same code.
    let confirm: String
}

/// Step two (`POST /pair/confirm`): cA, the phone's proof.
struct MobilePairConfirmRequest: Decodable, Sendable {
    let v: Int
    let exchange: String
    let confirm: String
}

struct MobilePairConfirmResponse: Codable, Sendable {
    let v: Int
    /// `MobilePairPayload` JSON sealed under the SPAKE2 session key.
    let sealed: String
}

extension Encodable {
    fileprivate var encoded: String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? #"{"error":"encoding_failed"}"#
    }
}

/// Plaintext inside `MobilePairResponse.sealed`.
struct MobilePairPayload: Codable, Sendable, Equatable {
    struct AgentEntry: Codable, Sendable, Equatable {
        let id: String
        let name: String
        let address: String
        /// Relay base URL (§6.1) when "Reach From Anywhere" is on; nil = LAN only.
        var relayURL: String? = nil
    }

    /// Master-scoped `osk-v1` access key covering every agent on this Mac.
    let apiKey: String
    let keyExpiresAt: Int?
    let hostName: String
    let agents: [AgentEntry]
}

/// The one phone paired with this Mac.
struct PairedMobileDevice: Codable, Sendable, Equatable {
    let deviceId: String
    let name: String
    let keyId: UUID
    let pairedAt: Date
    let keyExpiresAt: Date?
    var isSimulator: Bool? = nil
}

// MARK: - Service

@MainActor
final class MobilePairingService: ObservableObject {
    static let shared = MobilePairingService()

    static let keepAwakeDefaultsKey = "mobileConnectKeepMacAwake"
    static let reachAnywhereDefaultsKey = "mobileConnectReachFromAnywhere"
    /// Agents whose relay tunnel THIS service turned on, so turning the
    /// feature off (or unpairing) never disables a tunnel the user enabled.
    private static let relayManagedAgentsKey = "mobileConnectRelayManagedAgents"
    static let wireVersion = 1
    private static let pairedDeviceDefaultsKey = "mobileConnectPairedDevice"
    /// Label of every pairing key minted from now on; phone chats keep it as
    /// their caller name and it is the row label under Identity → Access Keys.
    nonisolated static let keyLabel = "Mobile"
    /// Label pairing keys carried before the tab was renamed from
    /// "Osaurus Connect" to "Mobile". Still recognised so existing pairings
    /// and their chats keep working, and so their old titles can be fixed.
    nonisolated static let legacyKeyLabel = "Osaurus Connect"
    /// Every label a pairing key has ever been minted with.
    nonisolated static let allKeyLabels: Set<String> = [keyLabel, legacyKeyLabel]

    enum RedeemOutcome: Equatable, Sendable {
        case paired(MobilePairResponse, deviceName: String)
        /// A v2 step answered: the JSON body to send, and its log-safe twin.
        case answered(String, logBody: String)
        /// Wrong, expired, locked-out, or no code at all — deliberately one
        /// outcome so a guesser learns nothing about which.
        case invalidCode
        case badRequest(String)

        static func == (lhs: RedeemOutcome, rhs: RedeemOutcome) -> Bool {
            switch (lhs, rhs) {
            case (.invalidCode, .invalidCode): return true
            case (.badRequest(let a), .badRequest(let b)): return a == b
            case (.paired(_, let a), .paired(_, let b)): return a == b
            case (.answered(let a, _), .answered(let b, _)): return a == b
            default: return false
            }
        }
    }

    @Published private(set) var activeCode: PairingCode?
    @Published private(set) var pairedDevice: PairedMobileDevice?
    @Published private(set) var isGeneratingCode = false
    @Published private(set) var lastError: String?

    private var pendingKey: (fullKey: String, info: AccessKeyInfo)?
    /// Read off-main with the key, so `redeem` never touches the Keychain.
    private var pendingConnectAddress: String?
    private var expiryTask: Task<Void, Never>?
    private var keepAwakeToken: NSObjectProtocol?
    private let defaults: UserDefaults
    private var agentsCancellable: AnyCancellable?
    private var deviceExpiryTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.pairedDeviceDefaultsKey) {
            pairedDevice = try? JSONDecoder().decode(PairedMobileDevice.self, from: data)
        }
        refreshKeepAwake()
        // A key that lapsed while the app was closed ends the pairing now.
        scheduleDeviceExpiry()
        // Agents created while a phone is paired get the relay too.
        agentsCancellable = AgentManager.shared.$agents
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.syncRelay() }
            }
    }

    // MARK: Code lifecycle

    /// Mint the device key (biometric prompt) and show a fresh code.
    func generateCode() async {
        guard !isGeneratingCode else { return }
        cancelCode()
        lastError = nil
        guard OsaurusIdentity.exists() else {
            lastError = L("Set up your Osaurus identity first (Settings → Identity).")
            return
        }
        isGeneratingCode = true
        defer { isGeneratingCode = false }
        // A code is only worth showing with the server up to take it: the
        // phone would otherwise search for a Mac that never answers.
        await ServerController.ensureRunning()
        if let reason = ServerController.notRunningReason() {
            MobileConnectLog.write("pairing: no code, the server isn't running: \(reason)")
            lastError = L("Your Mac can't take a pairing right now. \(reason)")
            return
        }
        do {
            let label = Self.keyLabel
            let (minted, connectAddress) = try await Task.detached(priority: .userInitiated) {
                (try APIKeyManager.shared.generate(label: label, expiration: .days90), MobileConnectIdentity.address())
            }.value
            pendingKey = minted
            pendingConnectAddress = connectAddress
            let code = PairingCode(code: PairingCode.generate(), issuedAt: Date())
            activeCode = code
            scheduleExpiry(of: code)
            MobileConnectLog.write("pairing: code generated, valid for \(Int(PairingCode.ttl))s")
        } catch {
            MobileConnectLog.write("pairing: could not create an access key: \(error.localizedDescription)")
            lastError = L("Couldn't create an access key: \(error.localizedDescription)")
        }
    }

    /// Discard the visible code and delete its unused key.
    func cancelCode() {
        expiryTask?.cancel()
        expiryTask = nil
        exchanges.removeAll()
        activeCode = nil
        if let pending = pendingKey {
            APIKeyManager.shared.delete(id: pending.info.id)
            pendingKey = nil
        }
    }

    private func scheduleExpiry(of code: PairingCode) {
        expiryTask = Task { [weak self] in
            let delay = max(0, code.expiresAt.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.activeCode?.code == code.code else { return }
            self.cancelCode()
        }
    }

    /// Test seam: install a code and an already-minted key, skipping the
    /// biometric mint in `generateCode()`.
    func installPendingCodeForTesting(
        _ code: PairingCode,
        fullKey: String,
        info: AccessKeyInfo,
        connectAddress: String? = nil
    ) {
        pendingKey = (fullKey, info)
        pendingConnectAddress = connectAddress
        activeCode = code
    }

    // MARK: Redeem (POST /pair/code)

    func redeem(_ request: MobilePairRequest, now: Date = Date()) -> RedeemOutcome {
        guard request.v == Self.wireVersion else { return .badRequest("Unsupported version") }
        let deviceId = request.deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceName = String(request.deviceName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !deviceId.isEmpty, deviceId.count <= 128, !deviceName.isEmpty else {
            return .badRequest("Missing device id or name")
        }

        guard var code = activeCode, let pending = pendingKey else { return .invalidCode }
        switch code.attempt(request.code, at: now) {
        case .accepted:
            break
        case .rejected:
            activeCode = code
            return .invalidCode
        case .lockedOut, .expired:
            cancelCode()
            return .invalidCode
        }

        guard let plaintext = try? JSONEncoder().encode(makePayload(pending)),
            let sealed = try? PairingKeyEnvelope.seal(
                secret: String(decoding: plaintext, as: UTF8.self),
                recipientPublicKeyBase64url: request.encPub,
                info: Self.envelopeInfo(deviceId: deviceId)
            )
        else {
            // Keep the code alive: a malformed key is the phone's bug, not a guess.
            return .badRequest("Invalid encryption key")
        }

        completePairing(
            pending,
            deviceId: deviceId,
            deviceName: deviceName,
            isSimulator: request.isSimulator,
            now: now
        )
        return .paired(MobilePairResponse(v: Self.wireVersion, sealed: sealed), deviceName: deviceName)
    }

    private func makePayload(_ pending: (fullKey: String, info: AccessKeyInfo)) -> MobilePairPayload {
        let agents = Self.remoteAgents(includeRelay: Self.isReachAnywhereEnabled(in: defaults))
        return MobilePairPayload(
            apiKey: pending.fullKey,
            keyExpiresAt: pending.info.expiresAt.map { Int($0.timeIntervalSince1970) },
            hostName: Host.current().localizedName ?? "Mac",
            agents: agents.isEmpty ? Self.connectEntry(address: pendingConnectAddress) : agents
        )
    }

    /// Records the phone and spends the code. One phone per Mac: the
    /// previous phone's key stops working now.
    private func completePairing(
        _ pending: (fullKey: String, info: AccessKeyInfo),
        deviceId: String,
        deviceName: String,
        isSimulator: Bool?,
        now: Date
    ) {
        if let previous = pairedDevice {
            APIKeyManager.shared.revoke(id: previous.keyId)
        }
        expiryTask?.cancel()
        expiryTask = nil
        activeCode = nil
        pendingKey = nil
        exchanges.removeAll()
        setPairedDevice(
            PairedMobileDevice(
                deviceId: deviceId,
                name: deviceName,
                keyId: pending.info.id,
                pairedAt: now,
                keyExpiresAt: pending.info.expiresAt,
                isSimulator: isSimulator == true ? true : nil
            )
        )
    }

    // MARK: Redeem v2 (POST /pair/code, then POST /pair/confirm)

    /// An exchange the Mac has answered, waiting for the phone to prove it
    /// used the same code.
    private struct PendingExchange {
        let deviceId: String
        let deviceName: String
        let isSimulator: Bool?
        let keys: PairingSPAKE2.Keys
    }

    private var exchanges: [String: PendingExchange] = [:]

    /// Step one: answer the phone's SPAKE2 share with the Mac's and its
    /// confirmation. Spends one of the code's attempts whatever the phone
    /// typed — the Mac can't tell — so the budget caps guessing.
    func startExchange(_ request: MobilePairStartRequest, now: Date = Date()) -> RedeemOutcome {
        guard request.v == PairingSPAKE2.version else { return .badRequest("Unsupported version") }
        let deviceId = request.deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceName = String(request.deviceName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !deviceId.isEmpty, deviceId.count <= 128, !deviceName.isEmpty else {
            return .badRequest("Missing device id or name")
        }
        guard let phoneShare = Data(base64urlEncoded: request.share) else { return .badRequest("Invalid key share") }

        guard var code = activeCode, pendingKey != nil else { return .invalidCode }
        switch code.spendAttempt(at: now) {
        case .accepted:
            activeCode = code
        case .rejected, .lockedOut, .expired:
            cancelCode()
            return .invalidCode
        }

        let identity = PairingSPAKE2.phoneIdentity(deviceId: deviceId, deviceName: deviceName)
        guard let mac = try? PairingSPAKE2.Party(role: .mac, code: code.code),
            let keys = try? mac.finish(peerShare: phoneShare, phoneIdentity: identity)
        else { return .badRequest("Invalid key share") }

        let exchange = UUID().uuidString
        exchanges[exchange] = PendingExchange(
            deviceId: deviceId,
            deviceName: deviceName,
            isSimulator: request.isSimulator,
            keys: keys
        )
        let response = MobilePairStartResponse(
            v: PairingSPAKE2.version,
            exchange: exchange,
            share: mac.share.base64urlEncoded,
            confirm: keys.macConfirmation.base64urlEncoded
        )
        return .answered(response.encoded, logBody: #"{"v":2,"exchange":"<redacted>"}"#)
    }

    /// Step two: the phone's confirmation proves it used the same code. Only
    /// then is the key handed over, sealed under the agreed session key.
    func confirmExchange(_ request: MobilePairConfirmRequest, now: Date = Date()) -> RedeemOutcome {
        guard request.v == PairingSPAKE2.version else { return .badRequest("Unsupported version") }
        guard let exchange = exchanges.removeValue(forKey: request.exchange),
            let code = activeCode, !code.isExpired(at: now), let pending = pendingKey,
            let confirm = Data(base64urlEncoded: request.confirm),
            PairingSPAKE2.constantTimeEquals(confirm, exchange.keys.phoneConfirmation)
        else { return .invalidCode }

        guard let plaintext = try? JSONEncoder().encode(makePayload(pending)),
            let sealed = try? PairingSPAKE2.seal(plaintext, key: exchange.keys.sessionKey, deviceId: exchange.deviceId)
        else { return .badRequest("Couldn't seal the pairing") }

        completePairing(
            pending,
            deviceId: exchange.deviceId,
            deviceName: exchange.deviceName,
            isSimulator: exchange.isSimulator,
            now: now
        )
        let response = MobilePairConfirmResponse(v: PairingSPAKE2.version, sealed: sealed)
        return .answered(response.encoded, logBody: #"{"v":2,"sealed":"<redacted>"}"#)
    }

    /// Binds the envelope to this exchange's device so it can't be replayed
    /// into another pairing.
    static func envelopeInfo(deviceId: String) -> Data {
        Data("osaurus-connect-pair-v1:\(deviceId)".utf8)
    }

    /// Agents a paired phone can talk to: custom agents with a derived
    /// address. The built-in Default agent is never reachable remotely.
    static func remoteAgents(includeRelay: Bool = false) -> [MobilePairPayload.AgentEntry] {
        AgentManager.shared.agents.compactMap { agent in
            guard !agent.isBuiltIn, let address = agent.agentAddress, !address.isEmpty else { return nil }
            return .init(
                id: agent.id.uuidString,
                name: agent.name,
                address: address.lowercased(),
                relayURL: includeRelay ? RelayTunnelManager.publicURL(forAddress: address) : nil
            )
        }
    }

    /// The built-in agent's roster entry, carrying the Mac's connect identity
    /// (`MobileConnectIdentity`) so a Mac with no custom agents still gives
    /// the phone a Secure Channel to pin. Only offered then: otherwise the
    /// phone rides a custom agent's channel, which the relay can also carry.
    static func connectEntry(address: String?) -> [MobilePairPayload.AgentEntry] {
        guard let address, !address.isEmpty else { return [] }
        return [.init(id: Agent.defaultId.uuidString, name: Agent.default.name, address: address)]
    }

    /// Nonce of the paired phone's access key, which run rows carry as their
    /// caller identity — how a chat started on the phone is recognised.
    var pairedKeyNonce: String? {
        guard let device = pairedDevice else { return nil }
        return APIKeyManager.shared.listKeys().first { $0.id == device.keyId }?.nonce
    }

    // MARK: Paired device

    /// `POST /pair/unpair`: the paired phone unpairs itself. Only the key
    /// minted for the current paired device may do this.
    /// Whether `nonce` is the paired phone's access key.
    func isPairedKey(nonce: String) -> Bool {
        guard let device = pairedDevice,
            let info = APIKeyManager.shared.listKeys().first(where: { $0.id == device.keyId })
        else { return false }
        return PairingCode.constantTimeEquals(info.nonce, nonce)
    }

    func unpairIfCaller(keyNonce: String) -> Bool {
        guard let device = pairedDevice,
            let info = APIKeyManager.shared.listKeys().first(where: { $0.id == device.keyId }),
            PairingCode.constantTimeEquals(info.nonce, keyNonce)
        else { return false }
        revokeDevice()
        return true
    }

    func revokeDevice() {
        guard let device = pairedDevice else { return }
        APIKeyManager.shared.revoke(id: device.keyId)
        setPairedDevice(nil)
    }

    private func setPairedDevice(_ device: PairedMobileDevice?) {
        pairedDevice = device
        if let device, let data = try? JSONEncoder().encode(device) {
            defaults.set(data, forKey: Self.pairedDeviceDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.pairedDeviceDefaultsKey)
        }
        refreshKeepAwake()
        syncRelay()
        scheduleDeviceExpiry()
    }

    /// The phone's key lasts 90 days (docs/MOBILE_PROTOCOL.md §11.4); after
    /// that the phone can no longer reach this Mac, so it stops counting as
    /// paired, as if unpaired: the keep-awake assertion and the relay
    /// tunnels this service turned on go with it. Continuous clock, so time
    /// the Mac spends asleep counts.
    private func scheduleDeviceExpiry() {
        deviceExpiryTask?.cancel()
        deviceExpiryTask = nil
        guard let device = pairedDevice, let expiresAt = device.keyExpiresAt else { return }
        let remaining = expiresAt.timeIntervalSinceNow
        guard remaining > 0 else {
            revokeDevice()
            return
        }
        deviceExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(remaining), clock: .continuous)
            guard !Task.isCancelled, let self, self.pairedDevice?.keyId == device.keyId else { return }
            self.revokeDevice()
        }
    }

    // MARK: Keep awake

    static func isKeepAwakeEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: keepAwakeDefaultsKey) as? Bool ?? true
    }

    /// Hold an idle-system-sleep assertion while a phone is paired and the
    /// preference is on, so the Mac stays reachable. Display sleep, lid
    /// close, and explicit Sleep are never overridden.
    func refreshKeepAwake() {
        let shouldHold = pairedDevice != nil && Self.isKeepAwakeEnabled(in: defaults)
        if shouldHold, keepAwakeToken == nil {
            keepAwakeToken = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled],
                reason: "Osaurus Mobile: keep this Mac reachable from the paired phone"
            )
        } else if !shouldHold, let token = keepAwakeToken {
            ProcessInfo.processInfo.endActivity(token)
            keepAwakeToken = nil
        }
    }
}

// MARK: - Reach From Anywhere (relay)

extension MobilePairingService {
    static func isReachAnywhereEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: reachAnywhereDefaultsKey) as? Bool ?? true
    }

    /// Agent ids whose tunnel this service enabled (see `relayManagedAgentsKey`).
    var relayManagedAgentIds: Set<UUID> {
        Set((defaults.stringArray(forKey: Self.relayManagedAgentsKey) ?? []).compactMap { UUID(uuidString: $0) })
    }

    /// Keeps the relay tunnel on for every remote agent while a phone is
    /// paired and "Reach From Anywhere" is on; otherwise turns off exactly
    /// the tunnels this service turned on.
    func syncRelay() {
        let relay = RelayTunnelManager.shared
        var managed = relayManagedAgentIds
        let shouldReach = pairedDevice != nil && Self.isReachAnywhereEnabled(in: defaults)

        if shouldReach {
            let remoteIds = Set(Self.remoteAgents().compactMap { UUID(uuidString: $0.id) })
            for agentId in remoteIds where !relay.isTunnelEnabled(for: agentId) {
                relay.setTunnelEnabled(true, for: agentId)
                managed.insert(agentId)
            }
            // Forget agents that were deleted.
            managed.formIntersection(remoteIds)
        } else {
            for agentId in managed where relay.isTunnelEnabled(for: agentId) {
                relay.setTunnelEnabled(false, for: agentId)
            }
            managed.removeAll()
        }
        defaults.set(managed.map(\.uuidString).sorted(), forKey: Self.relayManagedAgentsKey)
    }
}
