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
        /// Both devices show `code` (osaurus-sync beta.6); the user says whether they match.
        case confirming(device: String, deviceName: String, code: String)
        case paired(deviceName: String)
        case failed(String)
    }

    @Published private(set) var isOpen = false
    @Published private(set) var openError: String?
    @Published private(set) var configuration = SyncConfigurationStore.load()
    @Published private(set) var devices: [Device] = []
    @Published private(set) var peers: [PeerConnection] = []
    @Published private(set) var relays: [RelayState] = []
    @Published private(set) var pendingMessages = 0
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
            self.storage = snapshot.storage
            self.recoveryAvailable = snapshot.recoveryAvailable
            self.revoked = snapshot.devices.contains { $0.isSelf && $0.revoked }
        }
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
            let name = SyncService.shared.deviceName(forKey: device) ?? L("your other device")
            pairing = .paired(deviceName: name)
            FeatureTelemetry.syncDevicePaired(platform: SyncPhoneDevices.isPhone(deviceKey: device) ? "iphone" : "other")
            ToastManager.shared.success(L("Device added"), message: String(format: L("Your chats now sync with %@."), name))
        case let .pairingConfirmation(device, name, _, code):
            pairingExpiry?.cancel()
            pairing = .confirming(device: device, deviceName: name, code: code)
        case let .pairingFailed(reason):
            pairingExpiry?.cancel()
            Self.log.notice("pairing failed: \(reason, privacy: .public)")
            pairing = .failed(L("Pairing didn't finish. Check the code and try again."))
        case .incompatiblePeer:
            ToastManager.shared.warning(
                L("A device needs an update"),
                message: L("One of your devices runs a version of Osaurus that can't sync with this one. Update both to the latest version.")
            )
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

    /// The other device shows the same number (or not): the account is handed over only once both
    /// devices confirmed. Off the main thread, as every core call.
    func answerPairingConfirmation(matches: Bool) {
        guard case let .confirming(device, _, _) = pairing, let core = SyncService.shared.core else { return }
        pairing = matches ? .joining : .idle
        Task.detached(priority: .userInitiated) {
            do {
                if matches {
                    try core.confirmPairing(device: device)
                } else {
                    try core.rejectPairing(device: device)
                }
            } catch {
                await MainActor.run { self.pairing = .failed(error.syncUserMessage) }
            }
        }
    }

    func cancelPairing() {
        pairingExpiry?.cancel()
        SyncService.shared.core?.cancelPairing()
        pairing = .idle
    }

    func dismissPairingResult() {
        if case .offering = pairing { return }
        pairing = .idle
    }

    /// Joins the account of the device that showed `link`.
    func join(link: String) {
        let payload = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard payload.hasPrefix("osaurus-pair:") else {
            pairing = .failed(L("Paste the whole pairing link shown on your other device."))
            return
        }
        guard let core = SyncService.shared.core else { return }
        pairing = .joining
        Task {
            do {
                try await core.pairWithOffer(payload: payload)
            } catch {
                if self.pairing == .joining { self.pairing = .failed(error.syncUserMessage) }
            }
        }
    }

    // MARK: - Devices

    func revoke(_ device: Device) throws {
        guard let core = SyncService.shared.core else { return }
        try core.revokeDevice(device: device.id)
        FeatureTelemetry.syncDeviceRemoved(rotatedKeys: false)
        dismissPairingResult()
        refresh()
    }

    /// Revokes `device` and replaces this account's keys. Returns the new
    /// recovery phrase.
    func revokeAndRotate(_ device: Device) throws -> [String] {
        guard let core = SyncService.shared.core else { return [] }
        _ = try core.revokeAndRotate(devices: [device.id])
        FeatureTelemetry.syncDeviceRemoved(rotatedKeys: true)
        SyncWalletLink.clear()
        dismissPairingResult()
        refresh()
        return try core.recoveryPhrase()
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
