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
//  The 6-digit pairing itself stays open after it, so another iPhone still
//  on Classic can pair (`isRetired` only says the migration ran).
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
                // The old phone is forgotten, but pairing stays open for another iPhone still on Classic.
                endPairing: { MobilePairingService.shared.retire() }
            )
        }
    }

    struct Outcome: Equatable {
        var tunnelsDisabled: [UUID] = []
        var keysRevoked: [UUID] = []
        /// Left on for `tunnelGrace` (Move to Sync), so the old app hears it was unpaired.
        var tunnelsKept: [UUID] = []
    }

    /// Move to Sync: how long the old pairing's tunnels stay on after its key is revoked. A Classic iPhone app away
    /// from home reaches this Mac only through them, and learns it was unpaired only from this Mac's 401 for the
    /// revoked key: with the tunnels off it gets the relay's "offline" instead and thinks the Mac is asleep. The key
    /// is revoked at once, so nothing gets through them meanwhile.
    static let tunnelGrace: TimeInterval = 7 * 24 * 60 * 60
    /// Tunnels left on by Move to Sync, by agent id, to the time they go off.
    static let graceTunnelsKey = "mobileConnectGraceTunnels"

    @MainActor private static var phoneWatch: AnyCancellable?

    /// Runs the migration the first time an iPhone shows up in Sync.
    /// The Sync iPhones this Mac has seen, so one joining for the first time stands out.
    static let seenSyncPhonesKey = "mobileConnectSeenSyncPhones"

    /// Watches the account's iPhones for as long as the app runs: the first to join retires the old pairing, and
    /// since the 6-digit pairing stays open, a later one joining while a phone is paired with it (that phone moving
    /// to Sync) undoes that pairing too.
    @MainActor private static var graceSweep: Task<Void, Never>?

    /// Turns off the tunnels Move to Sync kept on, once their time is up: at launch, then every hour. One the old
    /// pairing manages again (a phone paired with a code since) is left to it.
    @MainActor
    @discardableResult
    static func sweepGraceTunnels(
        now: Date = Date(), defaults: UserDefaults = .standard, environment: Environment? = nil
    ) -> [UUID] {
        guard var grace = defaults.dictionary(forKey: graceTunnelsKey) as? [String: Double], !grace.isEmpty
        else { return [] }
        let env = environment ?? .live
        let managed = Set(defaults.stringArray(forKey: relayManagedAgentsKey) ?? [])
        var turnedOff: [UUID] = []
        for (id, until) in grace.sorted(by: { $0.key < $1.key }) where until <= now.timeIntervalSince1970 {
            grace[id] = nil
            guard let agentId = UUID(uuidString: id), !managed.contains(id), env.isTunnelEnabled(agentId) else {
                continue
            }
            env.disableTunnel(agentId)
            turnedOff.append(agentId)
        }
        if grace.isEmpty {
            defaults.removeObject(forKey: graceTunnelsKey)
        } else {
            defaults.set(grace, forKey: graceTunnelsKey)
        }
        if !turnedOff.isEmpty {
            MobileConnectLog.write("mobile: \(turnedOff.count) tunnel(s) kept for Move to Sync now off")
        }
        return turnedOff
    }

    @MainActor
    static func start() {
        if graceSweep == nil {
            graceSweep = Task { @MainActor in
                while !Task.isCancelled {
                    sweepGraceTunnels()
                    try? await Task.sleep(for: .seconds(60 * 60))
                }
            }
        }
        guard phoneWatch == nil else { return }
        phoneWatch = SyncPhoneDevices.shared.$phoneKeys
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { keys in
                MainActor.assumeIsolated { phonesChanged(keys) }
            }
    }

    /// `keys`: the account's iPhones now. Returns what was undone, if anything.
    @MainActor
    @discardableResult
    static func phonesChanged(
        _ keys: Set<String>,
        defaults: UserDefaults = .standard,
        environment: Environment? = nil
    ) -> Outcome? {
        guard !keys.isEmpty else { return nil }
        let recorded = defaults.stringArray(forKey: seenSyncPhonesKey)
        defaults.set(Array(keys.union(recorded ?? [])).sorted(), forKey: seenSyncPhonesKey)
        // The first iPhone in Sync: the one-time retirement.
        guard isRetired(defaults: defaults) else {
            return runIfNeeded(iPhoneInSync: true, defaults: defaults, environment: environment)
        }
        // Retired before this Mac recorded its iPhones: they're taken as the ones already there.
        guard let recorded else { return nil }
        let joined = keys.subtracting(recorded)
        guard !joined.isEmpty, defaults.object(forKey: pairedDeviceKey) != nil else { return nil }
        let outcome = undoLegacyPairing(defaults: defaults, environment: environment ?? .live)
        MobileConnectLog.write(
            "mobile: an iPhone paired with a code joined Sync; "
                + "\(outcome.tunnelsDisabled.count) tunnel(s) off, \(outcome.keysRevoked.count) key(s) revoked"
        )
        return outcome
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
        let outcome = undoLegacyPairing(defaults: defaults, environment: environment ?? .live)
        MobileConnectLog.write(
            "mobile: an iPhone joined Sync, retired the 6-digit pairing; "
                + "\(outcome.tunnelsDisabled.count) tunnel(s) off, \(outcome.keysRevoked.count) key(s) revoked"
        )
        return outcome
    }

    /// Move to Sync (Devices → Upgrading from Classic?): unpairs every device paired through the relay, as an iPhone
    /// joining Sync would. Chats stay on this Mac; the 6-digit pairing stays open.
    @MainActor
    static func unpairForSync(defaults: UserDefaults = .standard, environment: Environment? = nil) async {
        // A turn first, so the button's spinner shows before the work.
        await Task.yield()
        let outcome = undoLegacyPairing(
            defaults: defaults, environment: environment ?? .live,
            keepTunnelsUntil: Date().addingTimeInterval(tunnelGrace)
        )
        MobileConnectLog.write(
            "mobile: moved to Sync from Devices; \(outcome.keysRevoked.count) key(s) revoked, "
                + "\(outcome.tunnelsKept.count) tunnel(s) kept on to tell the old app it was unpaired"
        )
    }

    /// What the 6-digit pairing left: the tunnels it turned on, its phone's key, its defaults, the paired phone.
    @MainActor
    private static func undoLegacyPairing(
        defaults: UserDefaults, environment env: Environment, keepTunnelsUntil: Date? = nil
    ) -> Outcome {
        var outcome = Outcome()
        let managed = (defaults.stringArray(forKey: relayManagedAgentsKey) ?? []).compactMap(UUID.init(uuidString:))
        var grace = defaults.dictionary(forKey: graceTunnelsKey) as? [String: Double] ?? [:]
        for agentId in managed.sorted(by: { $0.uuidString < $1.uuidString }) where env.isTunnelEnabled(agentId) {
            if let until = keepTunnelsUntil {
                grace[agentId.uuidString] = until.timeIntervalSince1970
                outcome.tunnelsKept.append(agentId)
            } else {
                env.disableTunnel(agentId)
                outcome.tunnelsDisabled.append(agentId)
            }
        }
        if !outcome.tunnelsKept.isEmpty { defaults.set(grace, forKey: graceTunnelsKey) }
        for key in env.accessKeys() where legacyKeyLabels.contains(key.label) && !key.revoked {
            env.revokeKey(key.id)
            outcome.keysRevoked.append(key.id)
        }
        if let keepAwake = defaults.object(forKey: keepAwakeKey) as? Bool {
            defaults.set(keepAwake, forKey: SyncPhoneDevices.keepAwakeDefaultsKey)
        }
        for key in legacyDefaultsKeys { defaults.removeObject(forKey: key) }
        env.endPairing()
        return outcome
    }
}
