//
//  MobilePairingService.swift
//  osaurus
//
//  Osaurus Connect pairing: lets exactly one phone (the iOSaurus app) pair
//  with this Mac by typing a 6-digit code shown in Settings → Osaurus Connect.
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
}

struct MobilePairResponse: Codable, Sendable {
    let v: Int
    /// HPKE-sealed `MobilePairPayload` JSON (see `MobilePairingService.envelopeInfo`).
    let sealed: PairingKeyEnvelope.Sealed
}

/// Plaintext inside `MobilePairResponse.sealed`.
struct MobilePairPayload: Codable, Sendable, Equatable {
    struct AgentEntry: Codable, Sendable, Equatable {
        let id: String
        let name: String
        let address: String
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
}

// MARK: - Service

@MainActor
final class MobilePairingService: ObservableObject {
    static let shared = MobilePairingService()

    static let keepAwakeDefaultsKey = "mobileConnectKeepMacAwake"
    static let wireVersion = 1
    private static let pairedDeviceDefaultsKey = "mobileConnectPairedDevice"
    private static let keyLabel = "Osaurus Connect"

    enum RedeemOutcome: Equatable, Sendable {
        case paired(MobilePairResponse, deviceName: String)
        /// Wrong, expired, locked-out, or no code at all — deliberately one
        /// outcome so a guesser learns nothing about which.
        case invalidCode
        case badRequest(String)

        static func == (lhs: RedeemOutcome, rhs: RedeemOutcome) -> Bool {
            switch (lhs, rhs) {
            case (.invalidCode, .invalidCode): return true
            case (.badRequest(let a), .badRequest(let b)): return a == b
            case (.paired(_, let a), .paired(_, let b)): return a == b
            default: return false
            }
        }
    }

    @Published private(set) var activeCode: PairingCode?
    @Published private(set) var pairedDevice: PairedMobileDevice?
    @Published private(set) var isGeneratingCode = false
    @Published private(set) var lastError: String?

    private var pendingKey: (fullKey: String, info: AccessKeyInfo)?
    private var expiryTask: Task<Void, Never>?
    private var keepAwakeToken: NSObjectProtocol?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.pairedDeviceDefaultsKey) {
            pairedDevice = try? JSONDecoder().decode(PairedMobileDevice.self, from: data)
        }
        refreshKeepAwake()
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
        do {
            let label = Self.keyLabel
            let minted = try await Task.detached(priority: .userInitiated) {
                try APIKeyManager.shared.generate(label: label, expiration: .days90)
            }.value
            pendingKey = minted
            let code = PairingCode(code: PairingCode.generate(), issuedAt: Date())
            activeCode = code
            scheduleExpiry(of: code)
        } catch {
            lastError = L("Couldn't create an access key: \(error.localizedDescription)")
        }
    }

    /// Discard the visible code and delete its unused key.
    func cancelCode() {
        expiryTask?.cancel()
        expiryTask = nil
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
    func installPendingCodeForTesting(_ code: PairingCode, fullKey: String, info: AccessKeyInfo) {
        pendingKey = (fullKey, info)
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

        let payload = MobilePairPayload(
            apiKey: pending.fullKey,
            keyExpiresAt: pending.info.expiresAt.map { Int($0.timeIntervalSince1970) },
            hostName: Host.current().localizedName ?? "Mac",
            agents: Self.remoteAgents()
        )
        guard let plaintext = try? JSONEncoder().encode(payload),
            let sealed = try? PairingKeyEnvelope.seal(
                secret: String(decoding: plaintext, as: UTF8.self),
                recipientPublicKeyBase64url: request.encPub,
                info: Self.envelopeInfo(deviceId: deviceId)
            )
        else {
            // Keep the code alive: a malformed key is the phone's bug, not a guess.
            return .badRequest("Invalid encryption key")
        }

        // One phone per Mac: the previous phone's key stops working now.
        if let previous = pairedDevice {
            APIKeyManager.shared.revoke(id: previous.keyId)
        }
        expiryTask?.cancel()
        expiryTask = nil
        activeCode = nil
        pendingKey = nil
        setPairedDevice(
            PairedMobileDevice(
                deviceId: deviceId,
                name: deviceName,
                keyId: pending.info.id,
                pairedAt: now,
                keyExpiresAt: pending.info.expiresAt
            )
        )
        return .paired(MobilePairResponse(v: Self.wireVersion, sealed: sealed), deviceName: deviceName)
    }

    /// Binds the envelope to this exchange's device so it can't be replayed
    /// into another pairing.
    static func envelopeInfo(deviceId: String) -> Data {
        Data("osaurus-connect-pair-v1:\(deviceId)".utf8)
    }

    /// Agents a paired phone can talk to: custom agents with a derived
    /// address. The built-in Default agent is never reachable remotely.
    static func remoteAgents() -> [MobilePairPayload.AgentEntry] {
        AgentManager.shared.agents.compactMap { agent in
            guard !agent.isBuiltIn, let address = agent.agentAddress, !address.isEmpty else { return nil }
            return .init(id: agent.id.uuidString, name: agent.name, address: address.lowercased())
        }
    }

    // MARK: Paired device

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
                reason: "Osaurus Connect: keep this Mac reachable from the paired phone"
            )
        } else if !shouldHold, let token = keepAwakeToken {
            ProcessInfo.processInfo.endActivity(token)
            keepAwakeToken = nil
        }
    }
}
