//
//  SyncPhoneDevices.swift
//  osaurus
//
//  The user's iPhones are ordinary sync devices. This names a device's
//  platform for the Devices list and the hosted-chat notices, and holds the
//  idle-sleep assertion that keeps this Mac reachable while an iPhone is in
//  the account (Sharing → Devices → Keep Mac Awake for iPhone).
//

import Foundation
import OsaurusSync

enum SyncDevicePlatform: Equatable, Sendable {
    case mac
    case iPhone
    case other

    /// `Device.platform` as the core reports it ("macOS", "iOS", …).
    init(_ raw: String) {
        let value = raw.lowercased().filter { $0.isLetter }
        switch value {
        case "ios", "iphone", "ipados", "ipad": self = .iPhone
        case "macos", "mac", "osx": self = .mac
        default: self = .other
        }
    }

    var symbol: String {
        switch self {
        case .mac: "desktopcomputer"
        case .iPhone: "iphone"
        case .other: "display"
        }
    }

    /// How the Devices list names a device of this kind that isn't this Mac.
    var kindLabel: String {
        switch self {
        case .mac: L("Mac")
        case .iPhone: L("iPhone")
        case .other: L("Device")
        }
    }
}

extension Device {
    var devicePlatform: SyncDevicePlatform { SyncDevicePlatform(platform) }
}

@MainActor
final class SyncPhoneDevices: ObservableObject {
    static let shared = SyncPhoneDevices()

    static let keepAwakeDefaultsKey = "devicesKeepMacAwakeForIPhone"

    /// Whether a non-revoked iPhone is in this sync account.
    @Published private(set) var hasPhone = false

    private let defaults: UserDefaults
    private var keepAwakeToken: NSObjectProtocol?
    private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func hasActivePhone(_ devices: [Device]) -> Bool {
        devices.contains { !$0.isSelf && !$0.revoked && $0.devicePlatform == .iPhone }
    }

    /// Whether `deviceKey` names one of the user's iPhones.
    static func isPhone(deviceKey: String?, devices: [Device] = SyncService.shared.devices) -> Bool {
        guard let deviceKey, !deviceKey.isEmpty else { return false }
        return devices.first { $0.id == deviceKey }?.devicePlatform == .iPhone
    }

    static func isKeepAwakeEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: keepAwakeDefaultsKey) as? Bool ?? true
    }

    func start() {
        guard observers.isEmpty else { return }
        for name in [SyncService.devicesDidChangeNotification, SyncService.didOpenNotification, SyncService.didCloseNotification] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
            )
        }
        refresh()
    }

    func refresh() {
        hasPhone = SyncService.shared.isOpen && Self.hasActivePhone(SyncService.shared.devices)
        refreshKeepAwake()
    }

    /// Display sleep, a closed lid and an explicit Sleep still win: this only
    /// stops idle system sleep.
    func refreshKeepAwake() {
        let shouldHold = hasPhone && Self.isKeepAwakeEnabled(in: defaults)
        if shouldHold, keepAwakeToken == nil {
            keepAwakeToken = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled],
                reason: "Osaurus: keep this Mac reachable from your iPhone"
            )
        } else if !shouldHold, let token = keepAwakeToken {
            ProcessInfo.processInfo.endActivity(token)
            keepAwakeToken = nil
        }
    }
}
