//
//  SyncStatusModel.swift
//  osaurus
//
//  What Settings → Sync shows, and the account actions it runs: pairing,
//  devices, the recovery phrase, network settings and sign-out. Core
//  events that need the user's attention become toasts here.
//

import AppKit
import Foundation
import OsaurusSync
import os

@MainActor
final class SyncStatusModel: ObservableObject {
    static let shared = SyncStatusModel()

    enum Pairing: Equatable {
        case idle
        case offering(PairingOffer)
        case joining
        case confirming(PairingConfirmation)
        case paired(deviceName: String)
        case failed(String)
    }

    /// Both devices show the same number before the account is handed over.
    struct PairingConfirmation: Equatable {
        let device: String
        let name: String
        let code: String
        /// The offer this Mac showed; nil when this Mac is the one joining.
        let offer: PairingOffer?
        var confirmed = false
    }

    var isConfirmingPairing: Bool {
        if case .confirming = pairing { return true }
        return false
    }

    @Published private(set) var isOpen = false
    @Published private(set) var openError: String?
    @Published private(set) var configuration = SyncConfigurationStore.load()
    @Published private(set) var devices: [Device] = []
    @Published private(set) var peers: [PeerConnection] = []
    @Published private(set) var relays: [RelayState] = []
    @Published private(set) var pendingMessages = 0
    /// Synced chats whose older messages haven't all arrived yet.
    @Published private(set) var chatsDownloading = 0
    /// Older messages wait while the network is metered or in Low Data
    /// Mode, or Low Power Mode is on.
    @Published private(set) var historyPaused = false
    /// Same Network has found none of the user's other devices for a while.
    @Published private(set) var suggestAnywhere = false
    @Published private(set) var storage: StorageUsage?
    @Published private(set) var recoveryAvailable = false
    @Published private(set) var revoked = false
    @Published private(set) var pairing: Pairing = .idle

    private static let log = Logger(subsystem: "ai.osaurus", category: "sync.status")
    private static let pairingTTL: UInt64 = 5 * 60_000
    private var observers: [NSObjectProtocol] = []
    private var watchers = 0
    private var poll: Task<Void, Never>?
    private var pairingExpiry: Task<Void, Never>?
    private var unreachableSince: Date?

    /// How long Same Network finds nobody before suggesting Anywhere.
    static let anywhereHintDelay: TimeInterval = 30

    private init() {}

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [
            SyncService.didOpenNotification, SyncService.didReplaceIdentityNotification,
            SyncService.devicesDidChangeNotification,
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { SyncStatusModel.shared.refresh() }
            })
        }
        observers.append(
            center.addObserver(forName: SyncService.didReceiveEventNotification, object: nil, queue: .main) { note in
                guard let event = note.userInfo?[SyncService.eventUserInfoKey] as? CoreEvent else { return }
                MainActor.assumeIsolated { SyncStatusModel.shared.handle(event) }
            }
        )
        refresh()
    }

    /// Keeps the connection details current while a view shows them.
    func beginWatching() {
        watchers += 1
        guard poll == nil else { return }
        refresh()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.refresh()
            }
        }
    }

    func endWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        poll?.cancel()
        poll = nil
    }

    // MARK: - Reading

    private struct Snapshot: Sendable {
        var devices: [Device] = []
        var diagnostics: Diagnostics?
        var storage: StorageUsage?
        var recoveryAvailable = false
    }

    func refresh() {
        let service = SyncService.shared
        configuration = SyncConfigurationStore.load()
        guard let core = service.core else {
            isOpen = false
            openError = service.lastOpenError?.syncUserMessage
            devices = []
            peers = []
            relays = []
            pendingMessages = 0
            chatsDownloading = 0
            historyPaused = false
            suggestAnywhere = false
            storage = nil
            return
        }
        Task {
            let snapshot = await Task.detached(priority: .utility) {
                Snapshot(
                    devices: (try? core.devices()) ?? [],
                    diagnostics: core.diagnostics(),
                    storage: try? core.storageUsage(),
                    recoveryAvailable: (try? core.recoveryAvailable()) ?? false
                )
            }.value
            guard SyncService.shared.core === core else { return }
            self.isOpen = true
            self.openError = nil
            self.devices = Self.ordered(snapshot.devices)
            self.peers = snapshot.diagnostics?.peers ?? []
            self.relays = snapshot.diagnostics?.homeRelays ?? []
            self.pendingMessages = Int(snapshot.diagnostics?.scopes.reduce(0) { $0 + $1.pendingOutbox } ?? 0)
            self.chatsDownloading = snapshot.diagnostics?.scopes.filter { !$0.backfillComplete }.count ?? 0
            self.historyPaused = snapshot.diagnostics?.backfillPaused ?? false
            self.storage = snapshot.storage
            self.recoveryAvailable = snapshot.recoveryAvailable
            self.revoked = snapshot.devices.contains { $0.isSelf && $0.revoked }
            self.updateAnywhereHint(now: Date())
        }
    }

    private func updateAnywhereHint(now: Date) {
        let hint = Self.anywhereHint(
            configuration: configuration,
            otherDevices: otherDeviceCount,
            connected: connectedDeviceCount,
            unreachableSince: unreachableSince,
            now: now
        )
        unreachableSince = hint.unreachableSince
        suggestAnywhere = hint.suggest
    }

    /// Same Network with other devices and none connected starts a clock;
    /// the hint shows once it has run for `anywhereHintDelay`.
    static func anywhereHint(
        configuration: SyncConfiguration,
        otherDevices: Int,
        connected: Int,
        unreachableSince: Date?,
        now: Date
    ) -> (suggest: Bool, unreachableSince: Date?) {
        let stranded =
            configuration.networkEnabled && configuration.networkMode == .localNetworkOnly
            && otherDevices > 0 && connected == 0
        guard stranded else { return (false, nil) }
        let since = unreachableSince ?? now
        return (now.timeIntervalSince(since) >= anywhereHintDelay, since)
    }

    func isRelayed(_ device: Device) -> Bool {
        peers.contains { $0.device == device.id && $0.connected && $0.relayed }
    }

    /// This Mac first, then the rest by most recently seen; revoked last.
    private static func ordered(_ devices: [Device]) -> [Device] {
        devices.sorted { a, b in
            if a.isSelf != b.isSelf { return a.isSelf }
            if a.revoked != b.revoked { return !a.revoked }
            return (a.lastSeenMs ?? 0) > (b.lastSeenMs ?? 0)
        }
    }

    var deviceName: String {
        devices.first(where: \.isSelf)?.name ?? SyncService.deviceName
    }

    func isConnected(_ device: Device) -> Bool {
        isConnected(deviceId: device.id)
    }

    func isConnected(deviceId: String) -> Bool {
        peers.contains { $0.device == deviceId && $0.connected }
    }

    var connectedDeviceCount: Int {
        devices.filter { !$0.isSelf && !$0.revoked && isConnected($0) }.count
    }

    var otherDeviceCount: Int {
        devices.filter { !$0.isSelf && !$0.revoked }.count
    }

    // MARK: - Events

    private func handle(_ event: CoreEvent) {
        switch event {
        case let .paired(device):
            pairingExpiry?.cancel()
            pairingExpiry = nil
            let name = SyncService.shared.deviceName(forKey: device) ?? L("your other device")
            pairing = .paired(deviceName: name)
            FeatureTelemetry.syncDevicePaired(platform: SyncPhoneDevices.isPhone(deviceKey: device) ? "iphone" : "other")
            ToastManager.shared.success(L("Device added"), message: String(format: L("Your chats now sync with %@."), name))
        case let .pairingConfirmation(device, name, _, code):
            switch pairing {
            case let .offering(offer):
                pairing = .confirming(PairingConfirmation(device: device, name: name, code: code, offer: offer))
            case .joining:
                pairingExpiry?.cancel()
                pairing = .confirming(PairingConfirmation(device: device, name: name, code: code, offer: nil))
            default:
                // Nothing here is pairing any more; unconfirmed, it hands over nothing.
                Self.log.notice("ignored a pairing confirmation with no pairing in progress")
            }
        case let .pairingFailed(reason):
            Self.log.notice("pairing failed: \(reason, privacy: .public)")
            switch pairing {
            case .joining:
                pairingExpiry?.cancel()
                pairing = .failed(Self.pairingFailureMessage(reason))
            case let .confirming(confirmation):
                // A new device that leaves before confirming leaves the offer open.
                if let offer = confirmation.offer, Self.isOfferStillOpen(after: reason) {
                    pairing = .offering(offer)
                } else {
                    pairingExpiry?.cancel()
                    pairing = .failed(Self.pairingFailureMessage(reason))
                }
            default:
                // An offer shown here stays open.
                break
            }
        case let .incompatiblePeer(device, _):
            let message =
                SyncService.shared.deviceName(forKey: device).map {
                    String(format: L("%@ runs a version of Osaurus that can't sync with this one. Update both to the latest version."), $0)
                }
                ?? L("One of your devices runs a version of Osaurus that can't sync with this one. Update both to the latest version.")
            ToastManager.shared.warning(L("A device needs an update"), message: message)
        case .selfRevoked:
            revoked = true
            ToastManager.shared.warning(
                L("This Mac was removed from your devices"),
                message: L("Your chats stay on this Mac, but they no longer sync. Sign out in Sharing → Devices to add it again.")
            )
        case .recoveryAvailable:
            recoveryAvailable = true
            ToastManager.shared.info(
                L("Enter your recovery phrase"),
                message: L("This Mac was restored from a backup. Enter your recovery phrase in Sharing → Devices to read its chats.")
            )
        default:
            break
        }
        refresh()
    }

    // MARK: - Settings

    func setNetworkEnabled(_ enabled: Bool) {
        var next = SyncConfigurationStore.load()
        next.networkEnabled = enabled
        apply(next)
    }

    func setNetworkMode(_ mode: SyncConfiguration.NetworkMode) {
        var next = SyncConfigurationStore.load()
        next.networkMode = mode
        apply(next)
    }

    func setHostAgentsForOtherDevices(_ enabled: Bool) {
        var next = SyncConfigurationStore.load()
        next.hostAgentsForOtherDevices = enabled
        apply(next)
    }

    private func apply(_ next: SyncConfiguration) {
        configuration = next
        SyncService.shared.apply(next)
        refresh()
    }

    func retryOpen() {
        Task.detached(priority: .userInitiated) { _ = try? SyncService.shared.open() }
    }

    // MARK: - Pairing

    func startPairing() {
        guard let core = SyncService.shared.core else { return }
        do {
            let offer = try core.pairingOffer(ttlMs: Self.pairingTTL)
            pairing = .offering(offer)
            pairingExpiry?.cancel()
            pairingExpiry = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(Self.pairingTTL)))
                guard !Task.isCancelled, let self, case .offering = self.pairing else { return }
                self.pairing = .idle
            }
        } catch {
            pairing = .failed(error.syncUserMessage)
        }
    }

    func cancelPairing() {
        pairingExpiry?.cancel()
        SyncService.shared.core?.cancelPairing()
        pairing = .idle
    }

    func dismissPairingResult() {
        if case .offering = pairing { return }
        if isConfirmingPairing { return }
        pairing = .idle
    }

    /// The user saw the same number on the other device.
    func confirmPairing() {
        guard case var .confirming(confirmation) = pairing, !confirmation.confirmed,
            let core = SyncService.shared.core
        else { return }
        do {
            try core.confirmPairing(device: confirmation.device)
            confirmation.confirmed = true
            pairing = .confirming(confirmation)
        } catch {
            pairing = .failed(error.syncUserMessage)
        }
    }

    /// The numbers differ, or the user stopped: the other device gets a refusal.
    func rejectPairing() {
        guard case let .confirming(confirmation) = pairing else { return }
        try? SyncService.shared.core?.rejectPairing(device: confirmation.device)
        pairingExpiry?.cancel()
        pairing = .failed(L("Pairing stopped, and no device was added. To add your own device, start again with a new code."))
    }

    /// Whether `link` looks like a pairing link at all.
    static func isPairingLink(_ link: String) -> Bool {
        link.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("osaurus-pair:")
    }

    /// Joins the account of the device that showed `link`. The core reports
    /// the result as an event; a host that never answers sends none, so the
    /// join gives up after `joinTimeout`.
    func join(link: String) {
        let payload = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isPairingLink(payload) else {
            pairing = .failed(L("Paste the whole pairing link shown on your other device."))
            return
        }
        guard let core = SyncService.shared.core else { return }
        pairing = .joining
        pairingExpiry?.cancel()
        pairingExpiry = Task { [weak self] in
            try? await Task.sleep(for: Self.joinTimeout)
            guard !Task.isCancelled, let self, self.pairing == .joining else { return }
            self.pairing = .failed(Self.unreachableMessage(mode: self.configuration.networkMode))
        }
        Task {
            do {
                try await core.pairWithOffer(payload: payload)
            } catch {
                if self.pairing == .joining {
                    pairingExpiry?.cancel()
                    self.pairing = .failed(error.syncUserMessage)
                }
            }
        }
    }

    static let joinTimeout: Duration = .seconds(45)

    /// What the user can do about a pairing the core refused.
    static func pairingFailureMessage(_ reason: String) -> String {
        let reason = reason.lowercased()
        if reason.contains("invalid or expired") {
            return L("The code was wrong or has expired. Show a new code on your other device and paste its link again.")
        }
        if reason.contains("prove") || reason.contains("does not match") {
            return L("The other device couldn't confirm the code. Use a link shown on your own device's screen, then try again.")
        }
        if reason.contains("declined") {
            return L("The other device stopped pairing, so no device was added. If you're adding your own device, start again with a new code.")
        }
        if reason.contains("cancelled") {
            return L("Pairing was cancelled on the other device.")
        }
        if reason.contains("expired before the number") {
            return L("The code expired before both devices confirmed the number. Show a new code and try again.")
        }
        if reason.contains("update the app") {
            return L("The new device needs the latest version of Osaurus to pair. Update it, then try again.")
        }
        if reason.contains("another device is being paired") {
            return L("Another device is being added right now. Wait for it to finish, then try again.")
        }
        if reason.contains("disconnected") {
            return L("The other device disconnected before pairing finished. Try again.")
        }
        return L("Pairing didn't finish. Check the code and try again.")
    }

    /// The core keeps an offer open when the new device leaves before confirming.
    static func isOfferStillOpen(after reason: String) -> Bool {
        reason.lowercased().contains("new device disconnected")
    }

    /// The six digits both devices show, split for reading aloud.
    static func groupedConfirmationCode(_ code: String) -> String {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { return code }
        return "\(digits.prefix(3)) \(digits.suffix(3))"
    }

    static func unreachableMessage(mode: SyncConfiguration.NetworkMode) -> String {
        switch mode {
        case .localNetworkOnly:
            return L("This Mac couldn't reach the other device. Check that it still shows the code and is on the same network, or set Find Devices to Anywhere (Beta) on both.")
        case .anywhere:
            return L("This Mac couldn't reach the other device. Check that it still shows the code and is online, then try again.")
        }
    }

    // MARK: - Devices

    func revoke(_ device: Device) throws {
        guard let core = SyncService.shared.core else { return }
        do {
            try core.revokeDevice(device: device.id)
        } catch {
            Self.logRemoveFailure(error, device: device)
            throw error
        }
        FeatureTelemetry.syncDeviceRemoved(rotatedKeys: false)
        dismissPairingResult()
        refresh()
    }

    /// Revokes `device` and replaces this account's keys. Returns the new
    /// recovery phrase.
    func revokeAndRotate(_ device: Device) throws -> [String] {
        guard let core = SyncService.shared.core else { return [] }
        do {
            _ = try core.revokeAndRotate(devices: [device.id])
        } catch {
            Self.logRemoveFailure(error, device: device)
            throw error
        }
        FeatureTelemetry.syncDeviceRemoved(rotatedKeys: true)
        SyncWalletLink.clear()
        dismissPairingResult()
        refresh()
        return try core.recoveryPhrase()
    }

    /// Removing a device shows only "That Didn't Work" and a short message; the full error goes to
    /// the log (2026-11-12: two leftover simulator iPhones that never come off).
    private static func logRemoveFailure(_ error: Error, device: Device) {
        let detail = error.syncLogDetail
        let id = String(device.id.prefix(8))
        log.error("removing \(id, privacy: .public) failed: \(detail, privacy: .public)")
        #if DEBUG
            print("[SyncDevices] removing \(id) failed: \(detail)")
        #endif
    }

    // MARK: - Recovery

    func recoveryPhrase() throws -> [String] {
        guard let core = SyncService.shared.core else { return [] }
        return try core.recoveryPhrase()
    }

    func recover(phrase: String) throws {
        guard let core = SyncService.shared.core else { return }
        let words = phrase.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        try core.recoverFromPhrase(phrase: words)
        recoveryAvailable = false
        refresh()
    }

    // MARK: - Support and account

    func supportBundle() -> String? {
        SyncService.shared.core?.supportBundle()
    }

    func signOut(keepConversations: Bool) async throws {
        cancelPairing()
        try await SyncService.shared.signOut(keepConversations: keepConversations)
        revoked = false
        refresh()
    }
}
