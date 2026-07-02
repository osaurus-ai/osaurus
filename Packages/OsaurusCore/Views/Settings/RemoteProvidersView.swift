//
//  RemoteProvidersView.swift
//  osaurus
//
//  View for managing remote API providers (OpenAI, Anthropic, etc.).
//

import AppKit
import SwiftUI

/// Lets the connectivity filter drive the header `HeaderTabsRow`, so the
/// Providers tab uses the same segmented control as every other settings tab.
/// `title` maps to the existing `displayName`.
extension ProviderConnectivityFilter: AnimatedTabItem {
    var title: String { displayName }
}

struct RemoteProvidersView: View {
    @ObservedObject private var manager = RemoteProviderManager.shared
    @ObservedObject private var themeManager = ThemeManager.shared

    /// Use computed property to always get the current theme from ThemeManager
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var addSheetConfig: AddSheetConfig?
    @State private var editingProvider: RemoteProvider?
    @State private var showReorderSheet = false
    @State private var hasAppeared = false
    @State private var providerFilter: ProviderConnectivityFilter = .all
    @State private var credentialPresence: [UUID: RemoteProviderCredentialPresence] = [:]
    @State private var reconnectingAll = false
    @State private var reconnectingProviderIds: Set<UUID> = []

    private struct AddSheetConfig: Identifiable {
        let id = UUID()
        let preset: ProviderPreset?
        /// Open the add sheet directly on the grouped "Use an API key" sub-list
        /// (only meaningful when `preset` is nil).
        var startAtAPIKeyPicker: Bool = false
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
                .managerHeaderEntrance(hasAppeared: hasAppeared)

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if userConfiguredProviders.isEmpty {
                        emptyStateView
                    } else {
                        connectivityCenterView
                        providerListView
                    }
                }
                .padding(24)
            }
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
            refreshCredentialPresence()
        }
        .sheet(item: $addSheetConfig) { config in
            RemoteProviderEditSheet(
                provider: nil,
                initialPreset: config.preset,
                startAtAPIKeyPicker: config.startAtAPIKeyPicker
            ) { provider, apiKey, oauthTokens in
                manager.addProvider(provider, apiKey: apiKey, oauthTokens: oauthTokens)
                refreshCredentialPresence()
            }
        }
        .sheet(item: $editingProvider) { provider in
            RemoteProviderEditSheet(provider: provider) { updatedProvider, apiKey, oauthTokens in
                manager.updateProvider(updatedProvider, apiKey: apiKey, oauthTokens: oauthTokens)
                refreshCredentialPresence()
            }
        }
        .sheet(isPresented: $showReorderSheet) {
            RemoteProviderReorderSheet()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerView: some View {
        // Once providers exist, the connectivity filter rides the header
        // `tabsRow` like every other settings tab. The empty state has nothing
        // to filter, so it falls back to the plain actions header (same pattern
        // as `ThemesView`).
        if userConfiguredProviders.isEmpty {
            ManagerHeaderWithActions(
                title: L("Providers"),
                subtitle: subtitleText
            ) {
                headerActions
            }
        } else {
            ManagerHeaderWithTabs(
                title: L("Providers"),
                subtitle: subtitleText
            ) {
                headerActions
            } tabsRow: {
                HeaderTabsRow(selection: $providerFilter)
            }
        }
    }

    @ViewBuilder
    private var headerActions: some View {
        if userConfiguredProviders.count > 1 {
            HeaderIconButton("list.bullet.indent", help: "Reorder providers") {
                showReorderSheet = true
            }
        }
        HeaderPrimaryButton("Add Provider", icon: "plus") {
            addSheetConfig = AddSheetConfig(preset: nil)
        }
    }

    private var subtitleText: String {
        let userProviders = userConfiguredProviders
        let userProviderIds = Set(userProviders.map(\.id))
        let connectedCount = manager.providerStates
            .filter { userProviderIds.contains($0.key) }
            .values
            .filter { $0.isConnected }.count
        let totalCount = userProviders.count

        if totalCount == 0 {
            return L("Connect to remote API providers")
        } else if connectedCount == 0 {
            return L("\(totalCount) provider\(totalCount == 1 ? "" : "s") configured")
        } else {
            let modelCount = manager.providerStates.values.reduce(0) { $0 + $1.modelCount }
            return L("\(connectedCount) connected • \(modelCount) model\(modelCount == 1 ? "" : "s") available")
        }
    }

    // MARK: - Empty State

    private func presentAddSheet(for preset: ProviderPreset) {
        addSheetConfig = AddSheetConfig(preset: preset)
    }

    private var userConfiguredProviders: [RemoteProvider] {
        manager.configuration.providers.filter { $0.providerType != .osaurusRouter }
    }

    private var connectivitySnapshot: ProviderConnectivitySnapshot {
        ProviderConnectivityCenter.snapshot(
            providers: userConfiguredProviders,
            states: manager.providerStates,
            proxy: GlobalProxySettings.currentDiagnostic(),
            credentialsByProvider: credentialPresence
        )
    }

    private var visibleProviderReports: [ProviderConnectivityProviderReport] {
        connectivitySnapshot.filtered(by: providerFilter)
    }

    private func presentAPIKeyPicker() {
        addSheetConfig = AddSheetConfig(preset: nil, startAtAPIKeyPicker: true)
    }

    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 20)

            ZStack {
                Circle()
                    .fill(theme.accentColor.opacity(0.1))
                    .frame(width: 72, height: 72)

                Image(systemName: "cloud.fill")
                    .font(.system(size: 32))
                    .foregroundColor(theme.accentColor)
            }

            VStack(spacing: 8) {
                Text("No Remote Providers", bundle: .module)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text("Connect a provider to access remote models.", bundle: .module)
                    .font(.system(size: 14))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
            }

            // Quick-add: OAuth providers first-class, everything else behind
            // a single "Use an API key" entry (mirrors the add-sheet picker).
            VStack(spacing: 10) {
                ForEach(ProviderCatalog.topLevel) { entry in
                    ProviderRowCard(entry: entry) {
                        presentAddSheet(for: entry.preset)
                    }
                }

                ProviderRowCard(
                    icon: "key.fill",
                    title: "Use an API key",
                    subtitle: "Anthropic, Google, Ollama, custom, and more"
                ) {
                    presentAPIKeyPicker()
                }
            }
            .padding(.horizontal, 20)

            HStack(spacing: 4) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                Text("Your API keys are stored securely in Keychain.", bundle: .module)
                    .font(.system(size: 12))
            }
            .foregroundColor(theme.tertiaryText)

            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 400)
    }

    // MARK: - Provider List

    private var connectivityCenterView: some View {
        ProviderConnectivityCenterPanel(
            snapshot: connectivitySnapshot,
            isReconnecting: reconnectingAll,
            onReconnectAll: reconnectAllProviders,
            onCopyReport: copyConnectivityReport
        )
    }

    @ViewBuilder
    private var providerListView: some View {
        if visibleProviderReports.isEmpty {
            // Providers exist, but none match the active connectivity filter
            // (e.g. "Attention" with nothing flagged). Show a placeholder
            // rather than a blank gap below the filter.
            filteredEmptyState
        } else {
            VStack(spacing: 12) {
                ForEach(visibleProviderReports) { report in
                    ProviderCardView(
                        report: report,
                        state: report.state,
                        isReconnecting: reconnectingProviderIds.contains(report.id),
                        onReconnect: { reconnectProvider(report.provider) },
                        onCopyDiagnostics: { copyDiagnostics(report.diagnostics) },
                        onEdit: { editingProvider = report.provider },
                        onDelete: { manager.removeProvider(id: report.id) },
                        onToggleEnabled: { enabled in
                            manager.setEnabled(enabled, for: report.id)
                        }
                    )
                }
            }
        }
    }

    private var filteredEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 26))
                .foregroundColor(theme.tertiaryText)
            Text("Nothing to show here", bundle: .module)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.secondaryText)
            Text("No providers match this filter.", bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private func refreshCredentialPresence() {
        let providers = userConfiguredProviders
        Task {
            var next: [UUID: RemoteProviderCredentialPresence] = [:]
            for provider in providers {
                let providerID = provider.id
                let presence = await RemoteProviderKeychain.runOffCooperativeExecutor {
                    RemoteProviderCredentialPresence(
                        apiKeyPresent: RemoteProviderKeychain.hasAPIKey(for: providerID),
                        oauthTokensPresent: RemoteProviderKeychain.hasOAuthTokens(for: providerID)
                    )
                }
                next[providerID] = presence
            }
            await MainActor.run {
                credentialPresence = next
            }
        }
    }

    private func reconnectProvider(_ provider: RemoteProvider) {
        guard provider.enabled else { return }
        reconnectingProviderIds.insert(provider.id)
        Task {
            do {
                try await manager.reconnect(providerId: provider.id)
            } catch {
                // RemoteProviderManager stores the user-facing failure in state.
            }
            await MainActor.run {
                _ = reconnectingProviderIds.remove(provider.id)
            }
        }
    }

    private func reconnectAllProviders() {
        let targets = userConfiguredProviders.filter(\.enabled)
        guard !targets.isEmpty else { return }
        reconnectingAll = true
        Task {
            for provider in targets {
                do {
                    try await manager.reconnect(providerId: provider.id)
                } catch {
                    // Individual provider rows keep their own diagnostics.
                }
            }
            await MainActor.run {
                reconnectingAll = false
            }
        }
    }

    private func copyConnectivityReport() {
        copyText(connectivitySnapshot.pasteboardText)
    }

    private func copyDiagnostics(_ report: ProviderDiagnosticReport) {
        copyText(report.pasteboardText)
    }

    private func copyText(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}

// MARK: - Provider Connectivity Center Panel

private struct ProviderConnectivityCenterPanel: View {
    @Environment(\.theme) private var theme

    let snapshot: ProviderConnectivitySnapshot
    let isReconnecting: Bool
    let onReconnectAll: () -> Void
    let onCopyReport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: iconName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(statusColor)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(statusColor.opacity(0.12)))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Provider Connectivity", bundle: .module)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                        Text(summaryText)
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                    }
                }

                Spacer()

                Button(action: onReconnectAll) {
                    if isReconnecting {
                        ProgressView()
                            .scaleEffect(0.55)
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(theme.secondaryText)
                .background(Circle().fill(theme.tertiaryBackground))
                .disabled(isReconnecting || snapshot.enabledCount == 0)
                .localizedHelp("Reconnect all")

                Button(action: onCopyReport) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(theme.secondaryText)
                .background(Circle().fill(theme.tertiaryBackground))
                .localizedHelp("Copy diagnostics")
            }

            HStack(spacing: 8) {
                ProviderConnectivityMetricPill(
                    title: L("Connected"),
                    value: "\(snapshot.connectedCount)",
                    color: theme.successColor
                )
                ProviderConnectivityMetricPill(
                    title: L("Attention"),
                    value: "\(snapshot.attentionCount)",
                    color: theme.warningColor
                )
                ProviderConnectivityMetricPill(
                    title: L("Models"),
                    value: "\(snapshot.modelCount)",
                    color: theme.accentColor
                )
                ProviderConnectivityMetricPill(
                    title: L("Manual models"),
                    value: "\(snapshot.manualModelProviderCount)",
                    color: theme.infoColor
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(statusColor.opacity(0.35), lineWidth: 1)
                )
        )
    }

    private var statusColor: Color {
        switch snapshot.highestSeverity {
        case .ok:
            return theme.successColor
        case .info:
            return theme.infoColor
        case .warning:
            return theme.warningColor
        case .blocked:
            return theme.errorColor
        }
    }

    private var iconName: String {
        switch snapshot.highestSeverity {
        case .ok:
            return "checkmark.seal.fill"
        case .info:
            return "network"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .blocked:
            return "xmark.octagon.fill"
        }
    }

    private var summaryText: String {
        L(
            "\(snapshot.connectedCount)/\(snapshot.totalCount) connected - \(snapshot.attentionCount) attention - \(snapshot.modelCount) models"
        )
    }
}

private struct ProviderConnectivityMetricPill: View {
    @Environment(\.theme) private var theme

    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(color.opacity(0.1)))
    }
}

// MARK: - Provider Card View

private struct ProviderCardView: View {
    @Environment(\.theme) private var theme
    let report: ProviderConnectivityProviderReport
    let state: RemoteProviderState?
    let isReconnecting: Bool
    let onReconnect: () -> Void
    let onCopyDiagnostics: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggleEnabled: (Bool) -> Void

    @State private var showDeleteConfirm = false
    @State private var isHovered = false

    private var provider: RemoteProvider { report.provider }
    private var isConnected: Bool { state?.isConnected ?? false }
    private var isConnecting: Bool { state?.isConnecting ?? false }

    /// Match to a known preset for icon/color
    private var matchedPreset: ProviderPreset? {
        ProviderPreset.matching(provider: provider)
    }

    private var statusColor: Color {
        if !provider.enabled {
            return theme.tertiaryText
        } else if isConnected {
            return theme.successColor
        } else if isConnecting {
            return theme.accentColor
        } else if state?.lastError != nil {
            return theme.errorColor
        } else {
            return theme.secondaryText
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main content
            HStack(spacing: 16) {
                // Icon
                ZStack {
                    iconBackground
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    if let preset = matchedPreset {
                        ProviderIcon(preset: preset, size: 22, color: iconForeground)
                    } else {
                        Image(systemName: "cloud.fill")
                            .font(.system(size: 22))
                            .foregroundColor(iconForeground)
                    }
                }
                .frame(width: 52, height: 52)

                // Info
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(provider.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(theme.primaryText)

                        statusBadge

                        if provider.providerType == .osaurus {
                            // Osaurus peers talk through the Secure Channel —
                            // agent traffic is end-to-end encrypted or refused.
                            HStack(spacing: 3) {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 8, weight: .semibold))
                                Text("E2E", bundle: .module)
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundColor(theme.successColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.successColor.opacity(0.12)))
                            .help(
                                L(
                                    "Agent traffic is protected by the Osaurus Secure Channel: forward-secret, mutually authenticated end-to-end encryption."
                                )
                            )
                        }
                    }

                    Text(provider.displayEndpoint)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)

                    if isConnected, let modelCount = state?.modelCount, modelCount > 0 {
                        Text("\(modelCount) model\(modelCount == 1 ? "" : "s") available", bundle: .module)
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                    } else if report.hasAttention {
                        Text(report.summary)
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer()

                // Actions
                HStack(spacing: 12) {
                    Button(action: onReconnect) {
                        if isReconnecting || isConnecting {
                            ProgressView()
                                .scaleEffect(0.55)
                                .frame(width: 32, height: 32)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14))
                                .foregroundColor(theme.secondaryText)
                                .frame(width: 32, height: 32)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.tertiaryBackground)
                    )
                    .disabled(!provider.enabled || isReconnecting || isConnecting)
                    .localizedHelp("Reconnect")

                    Button(action: onCopyDiagnostics) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 14))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 32, height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.tertiaryBackground)
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .localizedHelp("Copy diagnostics")

                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                            .font(.system(size: 14))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 32, height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.tertiaryBackground)
                            )
                    }
                    .buttonStyle(PlainButtonStyle())

                    Button(
                        action: { showDeleteConfirm = true },
                        label: {
                            Image(systemName: "trash")
                                .font(.system(size: 14))
                                .foregroundColor(theme.errorColor.opacity(0.8))
                                .frame(width: 32, height: 32)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(theme.errorColor.opacity(0.1))
                                )
                        }
                    )
                    .buttonStyle(PlainButtonStyle())

                    Toggle(
                        "",
                        isOn: Binding(
                            get: { provider.enabled },
                            set: { onToggleEnabled($0) }
                        )
                    )
                    .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                    .labelsHidden()
                }
            }
            .padding(16)

            // Error message
            if let error = state?.lastError, !isConnected, !isConnecting {
                Divider()
                    .background(theme.errorColor.opacity(0.3))

                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                    Text(error)
                        .font(.system(size: 12))
                        .lineLimit(2)
                }
                .foregroundColor(theme.errorColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.errorColor.opacity(0.05))
            }

            if report.hasAttention {
                Divider()
                    .background(theme.primaryBorder)
                ProviderDiagnosticsRowsView(report: report.diagnostics, maxRows: 3)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(theme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(
                            isConnected ? theme.successColor.opacity(0.4) : theme.primaryBorder,
                            lineWidth: 1
                        )
                )
        )
        .scaleEffect(isHovered ? 1.005 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .themedAlert(
            L("Delete Provider?"),
            isPresented: $showDeleteConfirm,
            message: L("This will remove '\(provider.name)' and disconnect any active sessions."),
            primaryButton: .destructive(L("Delete")) { onDelete() },
            secondaryButton: .cancel(L("Cancel"))
        )
    }

    /// Icon background: use preset gradient if connected, otherwise status-tinted fill
    @ViewBuilder
    private var iconBackground: some View {
        if let preset = matchedPreset, isConnected {
            LinearGradient(
                colors: preset.gradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            statusColor.opacity(0.12)
        }
    }

    private var iconForeground: Color {
        if matchedPreset != nil, isConnected {
            return .white
        }
        return statusColor
    }

    @ViewBuilder
    private var statusBadge: some View {
        if !provider.enabled {
            badge(text: "Disabled", color: theme.tertiaryText)
        } else if isConnected {
            badge(text: "Connected", color: theme.successColor)
        } else if isConnecting {
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 12, height: 12)
                Text("Connecting...", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(theme.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(theme.accentColor.opacity(0.12)))
        } else if state?.lastError != nil {
            badge(text: "Error", color: theme.errorColor)
        } else {
            badge(text: "Disconnected", color: theme.secondaryText)
        }
    }

    private func badge(text: String, color: Color) -> some View {
        Text(LocalizedStringKey(text), bundle: .module)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        RemoteProvidersView()
            .environment(\.theme, DarkTheme())
    }
#endif
