//
//  MobileConnectMigration.swift
//  osaurus
//
//  The iPhone used to pair with a 6-digit code over HTTP and reach agents
//  through one relay tunnel per agent ("Reach From Anywhere"). It is now an
//  ordinary sync device (docs/SYNC_MOBILE_CONTRACT.md). For one release both
//  work side by side, so a phone that hasn't updated keeps working. This runs
//  once, the first time an iPhone is in this Mac's Sync account, and undoes
//  what the old pairing left behind:
//
//  - turns off exactly the tunnels the old pairing turned on
//    (`mobileConnectRelayManagedAgents`); tunnels the user turned on for a
//    workspace, a guest link or a webhook stay on;
//  - revokes the phone's master-scoped `osk-v1` key (labelled "Mobile", or
//    "Osaurus Connect" before the rename);
//  - carries the keep-awake preference over to Devices and clears every
//    `mobileConnect*` default.
//
//  From then on the pairing routes answer `410 update_required`
//  (`isRetired`) and the Mobile page says the iPhone uses Sync.
//

import Combine
import Foundation

enum MobileConnectMigration {
    /// `.v1` was set by builds that retired the pairing at launch, before an
    /// iPhone had joined Sync; it is ignored so those Macs can pair again.
    static let doneKey = "mobileConnectRetiredToSync.v2"

    /// Every label the old pairing minted its key with. Chats the phone
    /// started still carry it as their caller name.
    static let legacyKeyLabels: Set<String> = ["Mobile", "Osaurus Connect"]

    static let pairedDeviceKey = "mobileConnectPairedDevice"
    static let reachAnywhereKey = "mobileConnectReachFromAnywhere"
    static let relayManagedAgentsKey = "mobileConnectRelayManagedAgents"
    static let keepAwakeKey = "mobileConnectKeepMacAwake"

    static let legacyDefaultsKeys = [pairedDeviceKey, reachAnywhereKey, relayManagedAgentsKey, keepAwakeKey]

    /// Whether the 6-digit pairing is retired on this Mac: an iPhone joined
    /// Sync and the migration ran.
    nonisolated static func isRetired(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: doneKey)
    }

    /// What the migration touches outside `UserDefaults`, so tests can run
    /// it without a relay or a Keychain.
    struct Environment {
        var isTunnelEnabled: (UUID) -> Bool
        var disableTunnel: (UUID) -> Void
        var accessKeys: () -> [AccessKeyInfo]
        var revokeKey: (UUID) -> Void
        /// Forgets the paired phone, its showing code and the pairing
        /// advertisement. Runs last, once the defaults are cleared.
        var endPairing: () -> Void = {}

        @MainActor static var live: Environment {
            Environment(
                isTunnelEnabled: { RelayTunnelManager.shared.isTunnelEnabled(for: $0) },
                disableTunnel: { RelayTunnelManager.shared.setTunnelEnabled(false, for: $0) },
                accessKeys: { APIKeyManager.shared.listKeys() },
                revokeKey: { APIKeyManager.shared.revoke(id: $0) },
                endPairing: {
                    MobilePairingService.shared.retire()
                    MobileConnectAdvertiser.shared.stopAdvertising()
                }
            )
        }
    }

    struct Outcome: Equatable {
        var tunnelsDisabled: [UUID] = []
        var keysRevoked: [UUID] = []
    }

    @MainActor private static var phoneWatch: AnyCancellable?

    /// Runs the migration the first time an iPhone shows up in Sync.
    @MainActor
    static func start() {
        guard phoneWatch == nil, !isRetired() else { return }
        phoneWatch = SyncPhoneDevices.shared.$hasPhone
            .removeDuplicates()
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { _ in
                MainActor.assumeIsolated {
                    runIfNeeded(iPhoneInSync: true)
                    phoneWatch = nil
                }
            }
    }

    /// Nil when it already ran, or when no iPhone has joined Sync yet. Once an
    /// iPhone has, it marks the pairing retired even on a Mac that never had
    /// it, and returns what it undid.
    @MainActor
    @discardableResult
    static func runIfNeeded(
        iPhoneInSync: Bool,
        defaults: UserDefaults = .standard,
        environment: Environment? = nil
    ) -> Outcome? {
        guard iPhoneInSync, !isRetired(defaults: defaults) else { return nil }
        defaults.set(true, forKey: doneKey)
        let env = environment ?? .live

        var outcome = Outcome()
        let managed = (defaults.stringArray(forKey: relayManagedAgentsKey) ?? []).compactMap(UUID.init(uuidString:))
        for agentId in managed.sorted(by: { $0.uuidString < $1.uuidString }) where env.isTunnelEnabled(agentId) {
            env.disableTunnel(agentId)
            outcome.tunnelsDisabled.append(agentId)
        }
        for key in env.accessKeys() where legacyKeyLabels.contains(key.label) && !key.revoked {
            env.revokeKey(key.id)
            outcome.keysRevoked.append(key.id)
        }
        if let keepAwake = defaults.object(forKey: keepAwakeKey) as? Bool {
            defaults.set(keepAwake, forKey: SyncPhoneDevices.keepAwakeDefaultsKey)
        }
        for key in legacyDefaultsKeys { defaults.removeObject(forKey: key) }
        env.endPairing()
        MobileConnectLog.write(
            "mobile: an iPhone joined Sync, retired the 6-digit pairing; "
                + "\(outcome.tunnelsDisabled.count) tunnel(s) off, \(outcome.keysRevoked.count) key(s) revoked"
        )
        return outcome
    }
}
