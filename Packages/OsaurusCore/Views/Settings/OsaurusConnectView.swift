//
//  OsaurusConnectView.swift
//  osaurus
//
//  Settings → Osaurus Connect: pair the Osaurus iPhone app with a 6-digit
//  code, see / revoke the paired phone, and keep the Mac awake for it.
//  All state lives in `MobilePairingService`; this view only renders it.
//

import SwiftUI

struct OsaurusConnectView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var pairing = MobilePairingService.shared
    @ObservedObject private var highlightCoordinator = SettingsHighlightCoordinator.shared
    @ObservedObject private var relay = RelayTunnelManager.shared
    @EnvironmentObject private var server: ServerController

    @AppStorage(MobilePairingService.keepAwakeDefaultsKey) private var keepMacAwake: Bool = true
    @AppStorage(MobilePairingService.reachAnywhereDefaultsKey) private var reachFromAnywhere: Bool = true
    @State private var hasAppeared = false
    @State private var isEnablingNetwork = false
    @State private var showRevokeConfirm = false

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack(spacing: 0) {
            ManagerHeader(
                title: L("Osaurus Connect"),
                subtitle: L("Use your agents from your iPhone")
            )
            .managerHeaderEntrance(hasAppeared: hasAppeared)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        pairingSection
                        pairedDeviceSection
                        powerSection
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity)
                }
                .opacity(hasAppeared ? 1 : 0)
                .onChange(of: highlightCoordinator.pending) { _, id in scrollTo(id, proxy: proxy) }
                .onAppear { scrollTo(highlightCoordinator.pending, proxy: proxy) }
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.25)) { hasAppeared = true }
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

    // MARK: Pairing

    @ViewBuilder private var pairingSection: some View {
        SettingsSection(title: L("Pair an iPhone"), icon: "iphone.gen3") {
            VStack(alignment: .leading, spacing: 14) {
                Text(
                    "Open Osaurus on your iPhone, then generate a code here and type it in. Your iPhone must be on the same network as this Mac while pairing.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)

                if !server.configuration.exposeToNetwork {
                    networkBanner
                }

                if let code = pairing.activeCode {
                    activeCodeView(code)
                } else {
                    Button {
                        Task { await pairing.generateCode() }
                    } label: {
                        HStack(spacing: 6) {
                            if pairing.isGeneratingCode {
                                ProgressView().controlSize(.small)
                            }
                            Text("Generate Pairing Code", bundle: .module)
                        }
                    }
                    .buttonStyle(SettingsButtonStyle(isPrimary: true))
                    .disabled(pairing.isGeneratingCode || !server.configuration.exposeToNetwork)
                }

                if let error = pairing.lastError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(theme.errorColor)
                }
            }
        }
        .settingsLandingAnchor("settings.connect.pairing")
    }

    private var networkBanner: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundColor(theme.warningColor)
            Text("This Mac only accepts connections from itself. Allow local network access so your iPhone can reach it.", bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.primaryText)
            Spacer(minLength: 8)
            Button {
                Task { await enableNetworkAccess() }
            } label: {
                Text("Allow", bundle: .module)
            }
            .buttonStyle(SettingsButtonStyle(isPrimary: false))
            .disabled(isEnablingNetwork)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.warningColor.opacity(0.1)))
    }

    private func activeCodeView(_ code: PairingCode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Self.spaced(code.code))
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .textSelection(.enabled)
                .accessibilityLabel(Text(code.code.map(String.init).joined(separator: " ")))

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(code.expiresAt.timeIntervalSince(context.date)))
                Text("Expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            }

            Button {
                pairing.cancelCode()
            } label: {
                Text("Cancel", bundle: .module)
            }
            .buttonStyle(SettingsButtonStyle(isPrimary: false))
        }
    }

    // MARK: Paired device

    @ViewBuilder private var pairedDeviceSection: some View {
        SettingsSection(title: L("Paired iPhone"), icon: "checkmark.shield") {
            if let device = pairing.pairedDevice {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "iphone")
                        .font(.system(size: 22))
                        .foregroundColor(theme.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(device.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                            if device.isSimulator == true {
                                simulatorBadge
                            }
                        }
                        Text(Self.pairedSubtitle(device))
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                    }
                    Spacer()
                    Button {
                        showRevokeConfirm = true
                    } label: {
                        Text("Unpair", bundle: .module)
                    }
                    .buttonStyle(SettingsButtonStyle(isDestructive: true))
                }
            } else {
                Text("No iPhone is paired. Only one iPhone can be paired at a time; pairing a new one unpairs the old one.", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            }
        }
        .settingsLandingAnchor("settings.connect.pairedDevice")
    }

    private var simulatorBadge: some View {
        Text("Simulator", bundle: .module)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(theme.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.tertiaryBackground))
            .overlay(Capsule().stroke(theme.primaryBorder, lineWidth: 0.5))
            .help(Text("Paired from the iOS Simulator", bundle: .module))
    }

    // MARK: Power

    @ViewBuilder private var powerSection: some View {
        SettingsSection(title: L("Availability"), icon: "bolt.horizontal.circle.fill") {
            VStack(alignment: .leading, spacing: 14) {
                SettingsToggle(
                    title: L("Reach From Anywhere"),
                    description: L(
                        "Use your agents from your iPhone away from this network, through the Osaurus relay. Traffic stays end-to-end encrypted between your iPhone and this Mac."
                    ),
                    isOn: $reachFromAnywhere
                )
                .settingsLandingAnchor("settings.connect.reachAnywhere")

                if reachFromAnywhere, pairing.pairedDevice != nil {
                    relayStatusRow
                }

                SettingsToggle(
                    title: L("Keep Mac Awake for Paired iPhone"),
                    description: L(
                        "Prevent idle system sleep while an iPhone is paired so your agents stay reachable. The display may still sleep, and closing a MacBook lid or choosing Sleep always takes priority."
                    ),
                    isOn: $keepMacAwake
                )
                .settingsLandingAnchor("settings.connect.keepAwake")
            }
        }
    }

    /// Summarises the relay tunnels of the agents the phone can use.
    private var relayStatusRow: some View {
        let summary = relaySummary
        return HStack(spacing: 8) {
            Image(systemName: summary.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(summary.color)
            Text(summary.text)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
        }
    }

    private var relaySummary: (text: String, icon: String, color: Color) {
        let ids = MobilePairingService.remoteAgents().compactMap { UUID(uuidString: $0.id) }
        guard !ids.isEmpty else {
            return (L("Create an agent to use it from your iPhone."), "info.circle", theme.secondaryText)
        }
        let statuses = ids.map { relay.agentStatuses[$0] ?? .disconnected }
        let connected = statuses.filter { if case .connected = $0 { return true } else { return false } }.count
        if let error = statuses.lazy.compactMap({ status -> String? in
            if case .error(let message) = status { return message } else { return nil }
        }).first {
            return (L("Relay error: \(error)"), "exclamationmark.triangle.fill", theme.warningColor)
        }
        if statuses.contains(.servedElsewhere) {
            return (
                L("Another Mac with the same identity is serving some agents over the relay."),
                "exclamationmark.triangle.fill", theme.warningColor
            )
        }
        if connected == ids.count {
            return (L("Reachable from anywhere (\(connected) agents)"), "checkmark.circle.fill", theme.successColor)
        }
        return (L("Connecting to the relay… (\(connected) of \(ids.count) agents)"), "arrow.triangle.2.circlepath", theme.secondaryText)
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

    private func scrollTo(_ id: String?, proxy: ScrollViewProxy) {
        guard let id, id.hasPrefix("settings.connect.") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
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
