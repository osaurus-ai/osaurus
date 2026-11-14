//
//  OsaurusConnectView.swift
//  osaurus
//
//  Sharing → Devices → Mobile: pair an Osaurus iPhone app that hasn't moved
//  to Sync yet with a 6-digit code, see / revoke the paired phone, and keep
//  the Mac awake and reachable for it. Kept for one release beside Sync;
//  once an iPhone joins in Devices the pairing retires
//  (`MobileConnectMigration`) and this page says so. All state lives in
//  `MobilePairingService`; this view only renders it.
//

import SwiftUI

struct OsaurusConnectView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var pairing = MobilePairingService.shared
    @ObservedObject private var relay = RelayTunnelManager.shared
    @EnvironmentObject private var server: ServerController

    @AppStorage(MobilePairingService.keepAwakeDefaultsKey) private var keepMacAwake: Bool = true
    @AppStorage(MobilePairingService.reachAnywhereDefaultsKey) private var reachFromAnywhere: Bool = true
    @AppStorage(MobileConnectMigration.doneKey) private var retired: Bool = false
    @State private var isEnablingNetwork = false
    @State private var showRevokeConfirm = false

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "Mobile",
                subtitle: "Pair the Osaurus iPhone app with a 6-digit code"
            )
        } content: {
            if retired {
                retiredSection
            } else {
                pairingSection
                pairedDeviceSection
                powerSection
            }
        }
        .onChange(of: keepMacAwake) { _, _ in pairing.refreshKeepAwake() }
        .onChange(of: reachFromAnywhere) { _, _ in pairing.syncRelay() }
        .alert(L("Unpair this iPhone?"), isPresented: $showRevokeConfirm) {
            Button(L("Unpair"), role: .destructive) { pairing.revokeDevice() }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text("Its access key stops working immediately. You can pair again with a new code.", bundle: .module)
        }
    }

    // MARK: Retired

    private var retiredSection: some View {
        SettingsSection {
            SettingsCallout(
                icon: "checkmark.circle.fill",
                title: "Your iPhone Uses Sync Now",
                message:
                    "An iPhone joined this Mac's devices, so the 6-digit pairing is off. Manage your iPhone in Devices.",
                tone: .success
            )
        }
        .settingsLandingAnchor("settings.connect.pairing")
    }

    // MARK: Pairing

    /// The pairing intro, "Osaurus" linking to the iPhone app's TestFlight
    /// for anyone who has yet to install it, underlined like a web link.
    private var pairingIntro: AttributedString {
        var text = AttributedString(
            localized:
                "For an [Osaurus](https://testflight.apple.com/join/yTF86bVb) iPhone app that doesn't offer Sync yet. Generate a code here and type it in on your iPhone, on the same network as this Mac. Once you add an iPhone in Devices, this pairing turns off.",
            bundle: .module
        )
        for run in text.runs where run.link != nil {
            text[run.range].underlineStyle = .single
            text[run.range].foregroundColor = theme.action.primary.default.background
        }
        return text
    }

    @ViewBuilder private var pairingSection: some View {
        SettingsSection(title: "Pair an iPhone") {
            VStack(alignment: .leading, spacing: theme.space.s12) {
                Text(pairingIntro)
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.secondary)

                if !server.configuration.exposeToNetwork {
                    networkBanner
                }

                if let code = pairing.activeCode {
                    activeCodeView(code)
                } else {
                    Button {
                        Task { await pairing.generateCode() }
                    } label: {
                        HStack(spacing: theme.space.s6) {
                            if pairing.isGeneratingCode {
                                SettingsSpinner()
                            }
                            Text("Generate 6-Digit Code", bundle: .module)
                        }
                    }
                    .buttonStyle(.settings(.primary))
                    .disabled(pairing.isGeneratingCode || !server.configuration.exposeToNetwork)
                }

                if let error = pairing.lastError {
                    Text(error)
                        .font(SettingsFont.caption)
                        .foregroundColor(theme.status.error.foreground)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .settingsLandingAnchor("settings.connect.pairing")
    }

    private var networkBanner: some View {
        SettingsCallout(
            icon: "wifi.exclamationmark",
            title: "Only This Mac Can Connect",
            message: "Allow local network access so your iPhone can reach this Mac.",
            tone: .warning
        ) {
            SettingsButton(.secondary, "Allow", size: .compact) {
                Task { await enableNetworkAccess() }
            }
            .disabled(isEnablingNetwork)
        }
    }

    private func activeCodeView(_ code: PairingCode) -> some View {
        SettingsStatusHero(
            valueLabel: "Pairing code",
            value: Self.spaced(code.code),
            valueAccessibilityLabel: code.code.map(String.init).joined(separator: " "),
            copyable: false,
            statusLabel: nil
        ) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(code.expiresAt.timeIntervalSince(context.date)))
                Text("Expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))", bundle: .module)
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.secondary)
            }
        } actions: {
            SettingsButton(.secondary, "Cancel", size: .compact) { pairing.cancelCode() }
        }
    }

    // MARK: Paired device

    @ViewBuilder private var pairedDeviceSection: some View {
        SettingsSection(title: "Your iPhone") {
            if let device = pairing.pairedDevice {
                SettingsRow(
                    title: device.name,
                    description: Self.pairedSubtitle(device),
                    verbatimTitle: true,
                    verbatimDescription: true,
                    leading: { SettingsIconTile(icon: "iphone") }
                ) {
                    HStack(spacing: theme.space.s8) {
                        if device.isSimulator == true {
                            StatusChip(L("Simulator"), tone: .neutral)
                                .help(Text("Paired from the iOS Simulator", bundle: .module))
                        }
                        SettingsButton(.destructive, "Unpair", size: .compact) { showRevokeConfirm = true }
                    }
                }
            } else {
                SettingsValueRow(title: "Your iPhone", value: L("Not paired"))
            }
        }
        .settingsLandingAnchor("settings.connect.pairedDevice")
    }

    // MARK: Power

    @ViewBuilder private var powerSection: some View {
        SettingsSection(title: "Availability") {
            SettingsToggle(
                title: "Remote Access for This iPhone",
                description: L(
                    "Use your agents from your paired iPhone away from this network, through the Osaurus relay. Traffic stays end-to-end encrypted between your iPhone and this Mac."
                ),
                anchorId: "settings.connect.reachAnywhere",
                isOn: $reachFromAnywhere
            )
            if reachFromAnywhere, pairing.pairedDevice != nil {
                relayStatusRow
            }
            SettingsToggle(
                title: "Keep Mac Awake for This iPhone",
                description: L(
                    "Prevent idle system sleep while an iPhone is paired so your agents stay reachable. The display may still sleep, and closing a MacBook lid or choosing Sleep always takes priority."
                ),
                anchorId: "settings.connect.keepAwake",
                isOn: $keepMacAwake
            )
        }
    }

    /// Summarises the relay tunnels of the agents the phone can use.
    private var relayStatusRow: some View {
        let summary = relaySummary
        return HStack(spacing: theme.space.s8) {
            Image(systemName: summary.icon)
                .glyphSize(.footnote, weight: .semibold)
                .foregroundColor(summary.color)
            Text(summary.text)
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.secondary)
        }
    }

    private var relaySummary: (text: String, icon: String, color: Color) {
        let ids = MobilePairingService.remoteAgents().compactMap { UUID(uuidString: $0.id) }
        guard !ids.isEmpty else {
            return (L("Create an agent to use it from your iPhone."), "info.circle", theme.text.secondary)
        }
        let statuses = ids.map { relay.agentStatuses[$0] ?? .disconnected }
        let connected = statuses.filter { if case .connected = $0 { return true } else { return false } }.count
        if let error = statuses.lazy.compactMap({ status -> String? in
            if case .error(let message) = status { return message } else { return nil }
        }).first {
            return (L("Relay error: \(error)"), "exclamationmark.triangle.fill", theme.status.warning.foreground)
        }
        if statuses.contains(.servedElsewhere) {
            return (
                L("Another Mac with the same identity is serving some agents over the relay."),
                "exclamationmark.triangle.fill", theme.status.warning.foreground
            )
        }
        if connected == ids.count {
            let label =
                connected == 1
                ? L("Reachable from anywhere (1 agent)") : L("Reachable from anywhere (\(connected) agents)")
            return (label, "checkmark.circle.fill", theme.status.success.foreground)
        }
        return (
            L("Connecting to the relay… (\(connected) of \(ids.count) agents)"), "arrow.triangle.2.circlepath",
            theme.text.secondary
        )
    }

    // MARK: Helpers

    private func enableNetworkAccess() async {
        isEnablingNetwork = true
        defer { isEnablingNetwork = false }
        server.configuration.exposeToNetwork = true
        server.runtimeSettings.network.host = "0.0.0.0"
        server.saveConfiguration()
        ServerRuntimeSettingsStore.save(server.runtimeSettings)
        if server.isRunning {
            await server.restartServer()
        }
    }

    /// "123456" → "123 456" for readability.
    static func spaced(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }

    private static func pairedSubtitle(_ device: PairedMobileDevice) -> String {
        let paired = device.pairedAt.formatted(date: .abbreviated, time: .shortened)
        guard let expires = device.keyExpiresAt else { return L("Paired \(paired)") }
        return L("Paired \(paired) · access until \(expires.formatted(date: .abbreviated, time: .omitted))")
    }
}
