//
//  ProvidersView.swift
//  osaurus
//
//  UI for managing remote MCP providers.
//

import AppKit
import SwiftUI

struct ProvidersView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var manager = MCPProviderManager.shared
    @ObservedObject private var managementState = ManagementStateManager.shared
    @State private var showAddSheet = false
    @State private var editingProvider: MCPProvider?
    @State private var hasAppeared = false
    @State private var providerFilter: MCPServerHubFilter = .all
    @State private var credentialPresence: [UUID: MCPProviderCredentialPresence] = [:]
    @State private var healthSnapshots: [UUID: MCPProviderHealthSnapshot] = MCPProviderHealthSnapshotStore.load()
    @State private var reconnectingAll = false
    @State private var probingAll = false
    @State private var probingProviderIds: Set<UUID> = []

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                // Header with add button
                headerSection

                if manager.configuration.providers.isEmpty {
                    emptyState
                } else {
                    hubPanel

                    ForEach(Array(visibleProviderReports.enumerated()), id: \.element.id) { index, report in
                        ProviderCard(
                            report: report,
                            animationIndex: index,
                            isTesting: probingProviderIds.contains(report.id),
                            onEdit: { editingProvider = report.provider },
                            onDelete: { manager.removeProvider(id: report.id) },
                            onConnect: { Task { try? await manager.connect(providerId: report.id) } },
                            onDisconnect: { manager.disconnect(providerId: report.id) },
                            onTest: { probeProvider(report.provider) },
                            onCopyDiagnostics: { copyDiagnostics(report.diagnostics) },
                            onToggleEnabled: { enabled in
                                manager.setEnabled(enabled, for: report.id)
                            },
                            onSignIn: {
                                Task {
                                    do {
                                        _ = try await manager.oauthSignIn(providerId: report.id)
                                        await MainActor.run {
                                            refreshCredentialPresence()
                                        }
                                    } catch {
                                        // The manager already wrote the error into
                                        // `MCPProviderState.lastError`, so the inline
                                        // card banner will show it; we additionally
                                        // toast it so the user notices even if their
                                        // card is scrolled off-screen.
                                        await MainActor.run {
                                            _ = ToastManager.shared.error(
                                                L("OAuth sign-in failed"),
                                                message: error.localizedDescription
                                            )
                                        }
                                    }
                                }
                            },
                            onSaveBearerToken: { token in
                                // Persist directly to Keychain (the provider record
                                // itself doesn't change) and immediately retry.
                                _ = MCPProviderKeychain.saveToken(token, for: report.id)
                                refreshCredentialPresence()
                                // Enable the provider so the retry connect doesn't no-op.
                                if !report.provider.enabled {
                                    manager.setEnabled(true, for: report.id)
                                }
                                Task {
                                    do {
                                        try await manager.connect(providerId: report.id)
                                    } catch {
                                        await MainActor.run {
                                            _ = ToastManager.shared.error(
                                                L("Couldn't connect with new token"),
                                                message: error.localizedDescription
                                            )
                                        }
                                    }
                                }
                            }
                        )
                    }
                }
            }
            .padding(24)
        }
        .opacity(hasAppeared ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.25).delay(0.1)) {
                hasAppeared = true
            }
            refreshCredentialPresence()
            refreshHealthSnapshots()
            applyPendingEditRequest()
        }
        .onChange(of: managementState.pendingMCPProviderEditId) { _, _ in
            applyPendingEditRequest()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: Foundation.Notification.Name.mcpProviderHealthSnapshotChanged
            )
        ) { _ in
            refreshHealthSnapshots()
        }
        .sheet(isPresented: $showAddSheet) {
            ProviderEditSheet(provider: nil) { provider, token in
                manager.addProvider(provider, token: token)
                refreshCredentialPresence()
            }
        }
        .sheet(item: $editingProvider) { provider in
            ProviderEditSheet(provider: provider) { updatedProvider, token in
                manager.updateProvider(updatedProvider, token: token)
                refreshCredentialPresence()
                refreshHealthSnapshots()
            }
        }
    }

    /// Honour a one-shot `pendingMCPProviderEditId` from the install-report
    /// deep-link. The id may be stale (provider since deleted) so we treat
    /// "not found" as a no-op and clear it either way to avoid loops.
    private func applyPendingEditRequest() {
        guard let id = managementState.pendingMCPProviderEditId else { return }
        if let provider = manager.configuration.provider(id: id) {
            editingProvider = provider
        }
        managementState.pendingMCPProviderEditId = nil
    }

    private var hubSnapshot: MCPServerHubSnapshot {
        MCPServerHub.snapshot(
            providers: manager.configuration.providers,
            states: manager.providerStates,
            proxy: GlobalProxySettings.currentDiagnostic(),
            credentialsByProvider: credentialPresence,
            healthSnapshots: healthSnapshots
        )
    }

    private var visibleProviderReports: [MCPServerHubProviderReport] {
        hubSnapshot.filtered(by: providerFilter)
    }

    private var hubPanel: some View {
        MCPServerHubPanel(
            snapshot: hubSnapshot,
            filter: $providerFilter,
            isReconnecting: reconnectingAll,
            isProbing: probingAll,
            onReconnectAll: reconnectEnabledProviders,
            onProbeAll: probeEnabledProviders,
            onCopyReport: copyHubReport
        )
    }

    private func refreshCredentialPresence() {
        let providers = manager.configuration.providers
        Task {
            var next: [UUID: MCPProviderCredentialPresence] = [:]
            for provider in providers {
                let providerID = provider.id
                let presence = await Task.detached(priority: .utility) {
                    MCPProviderCredentialPresence(
                        bearerTokenPresent: MCPProviderKeychain.hasToken(for: providerID),
                        oauthTokensPresent: MCPProviderKeychain.hasOAuthTokens(for: providerID)
                    )
                }.value
                next[providerID] = presence
            }
            await MainActor.run {
                credentialPresence = next
            }
        }
    }

    private func refreshHealthSnapshots() {
        healthSnapshots = MCPProviderHealthSnapshotStore.load()
    }

    private func reconnectEnabledProviders() {
        let targets = manager.configuration.providers.filter(\.enabled)
        guard !targets.isEmpty else { return }
        reconnectingAll = true
        Task {
            for provider in targets {
                do {
                    try await manager.connect(providerId: provider.id)
                } catch {
                    // Row state keeps the user-facing diagnostic.
                }
            }
            await MainActor.run {
                reconnectingAll = false
            }
        }
    }

    private func probeEnabledProviders() {
        let targets = manager.configuration.providers.filter(\.enabled)
        guard !targets.isEmpty else { return }
        probingAll = true
        probingProviderIds.formUnion(targets.map(\.id))
        Task {
            for provider in targets {
                let result = await probeResult(for: provider)
                MCPProviderHealthSnapshotStore.record(result, for: provider)
            }
            await MainActor.run {
                refreshHealthSnapshots()
                probingProviderIds.subtract(targets.map(\.id))
                probingAll = false
            }
        }
    }

    private func probeProvider(_ provider: MCPProvider) {
        guard !probingProviderIds.contains(provider.id) else { return }
        probingProviderIds.insert(provider.id)
        Task {
            let result = await probeResult(for: provider)
            MCPProviderHealthSnapshotStore.record(result, for: provider)
            await MainActor.run {
                refreshHealthSnapshots()
                _ = probingProviderIds.remove(provider.id)
            }
        }
    }

    private func probeResult(for provider: MCPProvider) async -> MCPProviderProbeResult {
        switch provider.transport {
        case .http:
            let credentials = await Task.detached(priority: .utility) {
                let token: String? =
                    switch provider.authType {
                    case .bearerToken:
                        MCPProviderKeychain.getToken(for: provider.id)
                    case .oauth:
                        MCPProviderKeychain.getOAuthTokens(for: provider.id)?.accessToken
                    case .none:
                        nil
                    }
                return (
                    token,
                    provider.resolvedHeaders()
                )
            }.value
            return await MCPProviderProbeService.probeHTTP(
                providerId: provider.id,
                name: provider.name,
                url: provider.url,
                token: credentials.0,
                headers: credentials.1,
                streamingEnabled: provider.streamingEnabled,
                discoveryTimeout: provider.discoveryTimeout
            )
        case .stdio:
            return await MCPProviderProbeService.probeStdio(provider: provider)
        }
    }

    private func copyHubReport() {
        copyText(hubSnapshot.pasteboardText)
    }

    private func copyDiagnostics(_ report: ProviderDiagnosticReport) {
        copyText(report.pasteboardText)
    }

    private func copyText(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private var headerSection: some View {
        SectionHeader(
            title: "MCP Providers",
            description: "Connect to remote MCP servers to access additional tools"
        ) {
            Button(action: { showAddSheet = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Add Provider", bundle: .module)
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.accentColor)
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(theme.accentColor.opacity(0.1))
                    .frame(width: 80, height: 80)
                Image(systemName: "server.rack")
                    .font(.system(size: 32, weight: .light))
                    .foregroundColor(theme.accentColor)
            }

            Text("No MCP providers yet", bundle: .module)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(theme.primaryText)

            Text("Connect to a remote MCP server to give Osaurus more tools.", bundle: .module)
                .font(.system(size: 14))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)

            Button(action: { showAddSheet = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14))
                    Text("Connect a Service", bundle: .module)
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundColor(theme.accentColor)
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

// MARK: - MCP Server Hub Panel

private struct MCPServerHubPanel: View {
    @Environment(\.theme) private var theme

    let snapshot: MCPServerHubSnapshot
    @Binding var filter: MCPServerHubFilter
    let isReconnecting: Bool
    let isProbing: Bool
    let onReconnectAll: () -> Void
    let onProbeAll: () -> Void
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
                        Text("MCP Server Hub", bundle: .module)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)
                        Text(summaryText)
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer()

                hubIconButton(
                    systemName: "antenna.radiowaves.left.and.right",
                    isBusy: isProbing,
                    isDisabled: isProbing || snapshot.enabledCount == 0,
                    help: "Probe enabled",
                    action: onProbeAll
                )

                hubIconButton(
                    systemName: "arrow.clockwise",
                    isBusy: isReconnecting,
                    isDisabled: isReconnecting || snapshot.enabledCount == 0,
                    help: "Reconnect enabled",
                    action: onReconnectAll
                )

                hubIconButton(
                    systemName: "doc.on.doc",
                    isBusy: false,
                    isDisabled: snapshot.totalCount == 0,
                    help: "Copy diagnostics",
                    action: onCopyReport
                )
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 104), spacing: 8, alignment: .leading)],
                alignment: .leading,
                spacing: 8
            ) {
                MCPServerHubMetricPill(
                    title: L("Connected"),
                    value: "\(snapshot.connectedCount)",
                    color: theme.successColor
                )
                MCPServerHubMetricPill(
                    title: L("Attention"),
                    value: "\(snapshot.attentionCount)",
                    color: theme.warningColor
                )
                MCPServerHubMetricPill(title: L("Tools"), value: "\(snapshot.toolCount)", color: theme.accentColor)
                MCPServerHubMetricPill(title: L("Stdio"), value: "\(snapshot.stdioCount)", color: theme.infoColor)
                MCPServerHubMetricPill(title: L("Host"), value: "\(snapshot.hostStdioCount)", color: Color.orange)
            }

            Picker("", selection: $filter) {
                ForEach(MCPServerHubFilter.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
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

    private func hubIconButton(
        systemName: String,
        isBusy: Bool,
        isDisabled: Bool,
        help: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if isBusy {
                ProgressView()
                    .scaleEffect(0.55)
                    .frame(width: 28, height: 28)
            } else {
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .foregroundColor(theme.secondaryText)
        .background(Circle().fill(theme.tertiaryBackground))
        .disabled(isDisabled)
        .localizedHelp(help)
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
            return "server.rack"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .blocked:
            return "xmark.octagon.fill"
        }
    }

    private var summaryText: String {
        L(
            "\(snapshot.connectedCount)/\(snapshot.totalCount) connected - \(snapshot.attentionCount) attention - \(snapshot.toolCount) tools"
        )
    }
}

private struct MCPServerHubMetricPill: View {
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
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(color.opacity(0.1)))
    }
}

// MARK: - Provider Card

private struct ProviderCard: View {
    @Environment(\.theme) private var theme
    let report: MCPServerHubProviderReport
    var animationIndex: Int = 0
    let isTesting: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onTest: () -> Void
    let onCopyDiagnostics: () -> Void
    let onToggleEnabled: (Bool) -> Void
    let onSignIn: () -> Void
    /// Inline "Add API token" submit for bearer-token providers that hit a 401.
    /// Receives the plaintext token; the caller is responsible for persisting it
    /// to Keychain and retrying the connection.
    let onSaveBearerToken: (String) -> Void

    @State private var isExpanded = false
    @State private var isHovering = false
    @State private var hasAppeared = false
    @State private var showDeleteConfirm = false
    /// Inline secure-field text for the bearer-token 401 banner. Cleared on submit.
    @State private var inlineBearerToken: String = ""

    private var provider: MCPProvider { report.provider }
    private var state: MCPProviderState? { report.state }

    private var isConnected: Bool {
        state?.isConnected ?? false
    }

    private var isConnecting: Bool {
        state?.isConnecting ?? false
    }

    private var requiresAuth: Bool {
        state?.requiresAuth ?? false
    }

    private var diagnosticsReport: ProviderDiagnosticReport {
        report.diagnostics
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row
            HStack(spacing: 14) {
                // Provider icon with status
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(statusColor.opacity(0.12))
                    Image(systemName: "server.rack")
                        .font(.system(size: 20))
                        .foregroundColor(statusColor)
                }
                .frame(width: 44, height: 44)

                // Provider info
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isExpanded.toggle() }
                }) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(provider.name)
                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                    .foregroundColor(theme.primaryText)

                                statusBadge

                                if provider.transport == .stdio {
                                    executionHostBadge
                                }
                            }

                            // Stdio providers don't have a meaningful `url`,
                            // so the second row shows the command + args
                            // instead. Middle-truncation preserves the
                            // binary name (left edge) and the final arg
                            // (right edge) — for `npx -y @scope/server-x
                            // --root /Users/me/long/path`, that's the
                            // signal users actually care about.
                            Text(providerSubtitle)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(theme.tertiaryText)
                                .lineLimit(1)
                                .truncationMode(
                                    provider.transport == .stdio ? .middle : .tail
                                )

                            if report.hasAttention {
                                Text(report.summary)
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.secondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }

                        Spacer()

                        // Tool count when connected
                        if isConnected, let toolCount = state?.discoveredToolCount, toolCount > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "wrench.and.screwdriver")
                                    .font(.system(size: 10))
                                Text("\(toolCount) tools", bundle: .module)
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(theme.secondaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(theme.tertiaryBackground))
                        }

                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.tertiaryText)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())

                // Actions
                HStack(spacing: 8) {
                    // Connection button with fixed size to prevent jiggling
                    Group {
                        if isConnecting {
                            ProgressView()
                                .scaleEffect(0.6)
                        } else if isConnected {
                            Button(action: onDisconnect) {
                                Text("Disconnect", bundle: .module)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(theme.errorColor)
                            }
                            .buttonStyle(PlainButtonStyle())
                        } else {
                            Button(action: onConnect) {
                                Text("Connect", bundle: .module)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .disabled(!provider.enabled)
                            .opacity(provider.enabled ? 1 : 0.5)
                        }
                    }
                    .frame(width: 80, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(
                                isConnected
                                    ? theme.errorColor.opacity(0.1) : (isConnecting ? Color.clear : theme.accentColor)
                            )
                    )

                    Button(action: onTest) {
                        if isTesting {
                            ProgressView()
                                .scaleEffect(0.55)
                                .frame(width: 28, height: 28)
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(theme.secondaryText)
                                .frame(width: 28, height: 28)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(theme.tertiaryBackground)
                    )
                    .disabled(isTesting)
                    .localizedHelp("Probe")

                    Button(action: onCopyDiagnostics) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(theme.tertiaryBackground)
                    )
                    .localizedHelp("Copy diagnostics")

                    Menu {
                        Button(action: onEdit) {
                            Label {
                                Text(localized: "Edit")
                            } icon: {
                                Image(systemName: "pencil")
                            }
                        }
                        Divider()
                        Button(role: .destructive, action: { showDeleteConfirm = true }) {
                            Label {
                                Text("Delete", bundle: .module)
                            } icon: {
                                Image(systemName: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 16))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 28, height: 28)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Toggle(
                        "",
                        isOn: Binding(
                            get: { provider.enabled },
                            set: { onToggleEnabled($0) }
                        )
                    )
                    .toggleStyle(SwitchToggleStyle())
                    .labelsHidden()
                    .scaleEffect(0.85)
                }
            }

            // Auth-required prompt. Branched so OAuth providers get a Sign In
            // button (which kicks off the loopback flow) while bearer-token
            // providers get an inline secure field — pressing Sign In on a
            // bearer provider would silently convert it to OAuth, which is
            // almost never what the user wants.
            if requiresAuth {
                if provider.authType == .bearerToken || provider.authType == .none {
                    bearerTokenAuthBanner
                } else {
                    oauthAuthBanner
                }
            } else if let error = state?.lastError, !isConnected {
                // Error message (only when not already showing the sign-in CTA).
                // For the common "command not found on PATH" case we add an
                // inline "Edit" CTA so nvm/asdf users can jump straight to
                // the command field without hunting through the row.
                HStack(spacing: 8) {
                    Image(systemName: errorIcon(for: error))
                        .font(.system(size: 12))
                        .foregroundColor(theme.errorColor)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(theme.errorColor)
                        .lineLimit(3)
                    if isCommandNotFoundError(error) {
                        Spacer(minLength: 6)
                        Button(action: onEdit) {
                            Text(localized: "Edit")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(theme.accentColor)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(theme.accentColor.opacity(0.12))
                                )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.errorColor.opacity(0.08))
                )
            }

            // Expanded content
            if isExpanded {
                Divider()
                    .padding(.vertical, 4)

                expandedContent
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .background(cardBackground)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { hovering in isHovering = hovering }
        .opacity(hasAppeared ? 1 : 0)
        .onAppear {
            let delay = Double(animationIndex) * 0.03
            withAnimation(.easeOut(duration: 0.25).delay(delay)) {
                hasAppeared = true
            }
        }
        .themedAlert(
            L("Delete Provider?"),
            isPresented: $showDeleteConfirm,
            message: L("This will remove the provider and all its tools. This cannot be undone."),
            primaryButton: .destructive(L("Delete")) { onDelete() },
            secondaryButton: .cancel(L("Cancel"))
        )
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

    /// True when the error message originated from a `commandNotFound`
    /// throw. Delegated to the error type itself so the description and
    /// the matcher can't drift; see `MCPStdioTransportError`.
    private func isCommandNotFoundError(_ message: String) -> Bool {
        MCPStdioTransportError.isCommandNotFoundMessage(message)
    }

    /// Pick a more helpful icon for `commandNotFound` so the row reads as
    /// "fix me" rather than "the server crashed".
    private func errorIcon(for message: String) -> String {
        isCommandNotFoundError(message)
            ? "wrench.and.screwdriver.fill"
            : "exclamationmark.triangle.fill"
    }

    /// Subtitle text for the card header. HTTP providers show their URL,
    /// stdio providers show the executable + args so the user can tell
    /// `uvx mcp-foo` apart from `npx @some/server` at a glance.
    private var providerSubtitle: String {
        switch provider.transport {
        case .http:
            return provider.url
        case .stdio:
            if provider.command.isEmpty {
                return L("stdio (command not set)")
            }
            let args = ShellArgs.join(provider.args)
            return args.isEmpty ? provider.command : "\(provider.command) \(args)"
        }
    }

    /// Small badge next to the provider name that tells users whether a
    /// stdio subprocess runs sandboxed or on the host. We never show it for
    /// HTTP providers because the distinction isn't meaningful there.
    @ViewBuilder
    private var executionHostBadge: some View {
        let isHost = provider.executionHost == .host
        HStack(spacing: 4) {
            Image(systemName: isHost ? "exclamationmark.shield.fill" : "shippingbox.fill")
                .font(.system(size: 8))
            Text(LocalizedStringKey(isHost ? "Host" : "Sandbox"), bundle: .module)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(isHost ? .orange : theme.accentColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill((isHost ? Color.orange : theme.accentColor).opacity(0.12))
        )
    }

    @ViewBuilder
    private var statusBadge: some View {
        if !provider.enabled {
            Text("Disabled", bundle: .module)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.tertiaryText)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(theme.tertiaryBackground))
        } else if isConnected {
            HStack(spacing: 4) {
                Circle().fill(theme.successColor).frame(width: 6, height: 6)
                Text("Connected", bundle: .module)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.successColor)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.successColor.opacity(0.12)))
        } else if isConnecting {
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.4)
                    .frame(width: 6, height: 6)
                Text("Connecting...", bundle: .module)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.accentColor)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.accentColor.opacity(0.12)))
        } else if state?.lastError != nil {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 8))
                Text("Error", bundle: .module)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(theme.errorColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.errorColor.opacity(0.12)))
        }
    }

    /// OAuth-flavoured auth-required banner. The Sign In button kicks off the
    /// browser loopback flow via `onSignIn`.
    @ViewBuilder
    private var oauthAuthBanner: some View {
        let signInError = state?.lastError
        HStack(spacing: 10) {
            Image(
                systemName: signInError == nil
                    ? "person.badge.key.fill" : "exclamationmark.triangle.fill"
            )
            .font(.system(size: 13))
            .foregroundColor(signInError == nil ? .orange : theme.errorColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sign in required", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                if let signInError {
                    Text(signInError)
                        .font(.system(size: 11))
                        .foregroundColor(theme.errorColor)
                        .lineLimit(3)
                } else {
                    Text("This server requires OAuth sign in to provide tools.", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button(action: onSignIn) {
                Text(signInError == nil ? "Sign In" : "Retry", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6).fill(theme.accentColor)
                    )
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill((signInError == nil ? Color.orange : theme.errorColor).opacity(0.10))
        )
    }

    /// Bearer-token-flavoured auth-required banner. Shows an inline secure
    /// field so the user can paste an API token without opening the edit
    /// sheet. Submitting fires `onSaveBearerToken` which persists the token
    /// and re-attempts the connection.
    @ViewBuilder
    private var bearerTokenAuthBanner: some View {
        let lastError = state?.lastError
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("API token required", bundle: .module)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(
                        lastError
                            ?? L("This server rejected the request as unauthorized. Paste an API token to retry.")
                    )
                    .font(.system(size: 11))
                    .foregroundColor(lastError == nil ? theme.secondaryText : theme.errorColor)
                    .lineLimit(3)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                SecureField(
                    "",
                    text: $inlineBearerToken,
                    prompt: Text("Paste API token here", bundle: .module)
                        .foregroundColor(theme.placeholderText)
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )
                .onSubmit(submitInlineBearerToken)

                Button(action: submitInlineBearerToken) {
                    Text("Save & Retry", bundle: .module)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6).fill(theme.accentColor)
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(
                    inlineBearerToken.trimmingCharacters(in: .whitespaces).isEmpty
                )
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.10))
        )
    }

    private func submitInlineBearerToken() {
        let trimmed = inlineBearerToken.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSaveBearerToken(trimmed)
        inlineBearerToken = ""
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Settings summary. Streaming is HTTP-only — stdio providers
            // multiplex over a single subprocess and don't have a
            // "streaming vs request/response" knob, so we hide that chip
            // for them (mirrors the editor, which already does the same).
            HStack(spacing: 16) {
                if provider.transport == .http {
                    settingItem(
                        icon: "bolt.fill",
                        label: L("Streaming"),
                        value: provider.streamingEnabled ? L("On") : L("Off")
                    )
                }
                settingItem(icon: "clock", label: L("Timeout"), value: L("\(Int(provider.toolCallTimeout))s"))
                settingItem(
                    icon: "arrow.clockwise",
                    label: L("Auto-connect"),
                    value: provider.autoConnect ? L("Yes") : L("No")
                )
            }

            ProviderDiagnosticsRowsView(report: diagnosticsReport, maxRows: nil)
                .padding(.horizontal, -16)

            // Custom headers summary
            if !provider.customHeaders.isEmpty || !provider.secretHeaderKeys.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                    Text(
                        "\(provider.customHeaders.count + provider.secretHeaderKeys.count) custom header\(provider.customHeaders.count + provider.secretHeaderKeys.count == 1 ? "" : "s")",
                        bundle: .module
                    )
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                }
            }

            // Discovered tools list
            if isConnected, let toolNames = state?.discoveredToolNames, !toolNames.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Provides:", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    ToolPillsFlowLayout(spacing: 6) {
                        ForEach(toolNames, id: \.self) { name in
                            HStack(spacing: 4) {
                                Image(systemName: "function")
                                    .font(.system(size: 9))
                                Text(name)
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(theme.tertiaryBackground)
                            )
                            .foregroundColor(theme.primaryText)
                            .help(name)
                        }
                    }
                }
            }
        }
    }

    private func settingItem(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
            Text("\(label):", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(theme.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isHovering ? theme.accentColor.opacity(0.2) : theme.cardBorder, lineWidth: 1)
            )
            .shadow(
                color: theme.shadowColor.opacity(isHovering ? theme.shadowOpacity * 1.5 : theme.shadowOpacity),
                radius: isHovering ? 12 : theme.cardShadowRadius,
                x: 0,
                y: isHovering ? 4 : theme.cardShadowY
            )
    }
}

// MARK: - Provider Edit Sheet

private struct ProviderEditSheet: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    let provider: MCPProvider?
    let onSave: (MCPProvider, String?) -> Void

    /// Stable identity for "draft" providers (sheet not yet saved). Reused so OAuth
    /// tokens persisted to Keychain mid-flow stay tied to the provider once saved.
    @State private var draftId: UUID = UUID()

    @State private var name: String = ""
    @State private var url: String = ""
    @State private var token: String = ""
    @State private var customHeaders: [HeaderEntry] = []
    @State private var streamingEnabled: Bool = false
    @State private var discoveryTimeout: Double = 20
    @State private var toolCallTimeout: Double = 45
    @State private var autoConnect: Bool = true
    @State private var authType: MCPProviderAuthType = .bearerToken
    @State private var oauthConfig: MCPOAuthConfig?

    @State private var isTesting: Bool = false
    @State private var testResult: TestResult?
    @State private var showAdvanced: Bool = false

    @State private var isSigningIn: Bool = false
    @State private var oauthError: String?
    /// Whether OAuth tokens are currently present for this provider — drives the
    /// "Sign In" vs "Re-authenticate" button label and the green check badge.
    @State private var isOAuthSignedIn: Bool = false

    // Manual OAuth override fields. Surfaced under an "Advanced" disclosure
    // inside the OAuth section so users can wire up MCP servers that don't
    // implement RFC 9728 PRM — those servers must supply at least the
    // authorize + token endpoints by hand. `manualClientId` /
    // `manualClientSecret` are also reused by the connect-known
    // confidential-client flow (HubSpot's MCP Auth Apps) which forces both
    // values to be entered up front before sign-in is allowed.
    @State private var showOAuthAdvanced: Bool = false
    @State private var manualAuthEndpoint: String = ""
    @State private var manualTokenEndpoint: String = ""
    @State private var manualClientId: String = ""
    @State private var manualClientSecret: String = ""
    @State private var manualScopes: String = ""

    // Stdio editor state. `transport` drives the HTTP/stdio fork of the
    // editor; the stdio-only fields below are only meaningful when
    // `transport == .stdio` and are otherwise inert.
    @State private var transport: MCPProviderTransport = .http
    @State private var executionHost: MCPProviderExecutionHost = .sandbox
    @State private var command: String = ""
    @State private var argsString: String = ""
    @State private var workingDirectory: String = ""
    @State private var envEntries: [HeaderEntry] = []

    /// The sheet is a small two-step flow: first pick a service from the catalog
    /// (or "Custom"), then configure / sign in. Editing an existing provider
    /// jumps straight to `.configureCustom` and never sees the catalog.
    enum Phase: Equatable {
        case chooseProvider
        case configureKnown(MCPProviderTemplate)
        case configureCustom
    }

    @State private var phase: Phase = .chooseProvider

    /// Search/filter query for the catalog grid. Reset whenever the user
    /// returns to `.chooseProvider` so re-entering the catalog starts fresh.
    @State private var catalogQuery: String = ""

    private var isEditing: Bool { provider != nil }

    /// Resolves the provider id used for OAuth flows (existing or fresh draft).
    private var effectiveProviderId: UUID { provider?.id ?? draftId }

    /// Convenience: the template the user is currently configuring, if any.
    private var activeTemplate: MCPProviderTemplate? {
        if case .configureKnown(let template) = phase { return template }
        return nil
    }

    struct HeaderEntry: Identifiable {
        let id = UUID()
        var key: String
        var value: String
        var isSecret: Bool
    }

    enum TestResult {
        case success(MCPProviderProbeResult)
        case failure(MCPProviderProbeResult)

        var probeResult: MCPProviderProbeResult {
            switch self {
            case .success(let result), .failure(let result):
                return result
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader

            ScrollView {
                phaseBody
                    .padding(24)
            }

            sheetFooter
        }
        .frame(width: 560, height: 660)
        .background(themeManager.currentTheme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(themeManager.currentTheme.primaryBorder, lineWidth: 1)
        )
        .onAppear { loadProvider() }
    }

    @ViewBuilder
    private var phaseBody: some View {
        switch phase {
        case .chooseProvider:
            catalogGridBody
        case .configureKnown(let template):
            configureKnownBody(template: template)
        case .configureCustom:
            configureCustomBody
        }
    }

    // MARK: - Sheet Header

    /// Icon + title + subtitle for the current phase. Returning `Text` (rather
    /// than `String`) lets us use SwiftUI's `Text("foo \(arg)")` interpolation
    /// for the dynamic phases — that produces a stable localization key with
    /// a format argument instead of a unique key per template name.
    private var headerInfo: (icon: String, title: Text, subtitle: Text) {
        if isEditing {
            return (
                "pencil.circle.fill",
                Text("Edit MCP Provider", bundle: .module),
                Text("Modify your MCP server connection", bundle: .module)
            )
        }
        switch phase {
        case .chooseProvider:
            return (
                "square.grid.2x2.fill",
                Text("Add MCP Provider", bundle: .module),
                Text("Choose a service to connect", bundle: .module)
            )
        case .configureKnown(let template):
            return (
                template.iconSystemName,
                Text("Connect to \(template.displayName)", bundle: .module),
                Text("Sign in with your account to give Osaurus access", bundle: .module)
            )
        case .configureCustom:
            return (
                "slider.horizontal.3",
                Text("Custom Server", bundle: .module),
                Text("Connect to any MCP-compatible server", bundle: .module)
            )
        }
    }

    private var sheetHeader: some View {
        let info = headerInfo
        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                themeManager.currentTheme.accentColor.opacity(0.2),
                                themeManager.currentTheme.accentColor.opacity(0.05),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: info.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                themeManager.currentTheme.accentColor,
                                themeManager.currentTheme.accentColor.opacity(0.7),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                info.title
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.primaryText)

                info.subtitle
                    .font(.system(size: 12))
                    .foregroundColor(themeManager.currentTheme.secondaryText)
            }

            Spacer()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(themeManager.currentTheme.tertiaryBackground)
                    )
            }
            .buttonStyle(PlainButtonStyle())
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(
            themeManager.currentTheme.secondaryBackground
                .overlay(
                    LinearGradient(
                        colors: [
                            themeManager.currentTheme.accentColor.opacity(0.03),
                            Color.clear,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    // MARK: - Sheet Footer

    @ViewBuilder
    private var sheetFooter: some View {
        HStack(spacing: 12) {
            footerLeading
            Spacer()
            footerTrailing
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            themeManager.currentTheme.secondaryBackground
                .overlay(
                    Rectangle()
                        .fill(themeManager.currentTheme.primaryBorder)
                        .frame(height: 1),
                    alignment: .top
                )
        )
    }

    @ViewBuilder
    private var footerLeading: some View {
        if phase != .chooseProvider, !isEditing {
            Button(action: backToCatalog) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Use a different service", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(themeManager.currentTheme.secondaryText)
            }
            .buttonStyle(PlainButtonStyle())
        }

        if case .configureCustom = phase {
            testConnectionButton
        }
    }

    @ViewBuilder
    private var footerTrailing: some View {
        cancelButton
        if case .configureKnown(let template) = phase {
            primarySaveButton(
                label: Text("Add Provider", bundle: .module),
                enabled: canSaveKnown(template)
            )
        }
        if case .configureCustom = phase {
            primarySaveButton(
                label: Text(isEditing ? "Save" : "Add Provider", bundle: .module),
                enabled: canSave
            )
        }
    }

    private var cancelButton: some View {
        Button {
            dismiss()
        } label: {
            Text("Cancel", bundle: .module)
        }
        .buttonStyle(MCPSecondaryButtonStyle())
    }

    private func primarySaveButton(label: Text, enabled: Bool) -> some View {
        Button(action: save) { label }
            .buttonStyle(MCPPrimaryButtonStyle())
            .disabled(!enabled)
            .keyboardShortcut(.return, modifiers: .command)
    }

    @ViewBuilder
    private var testConnectionButton: some View {
        Button(action: {
            testConnection()
        }) {
            HStack(spacing: 6) {
                Group {
                    if isTesting {
                        ProgressView().scaleEffect(0.6)
                    } else if let result = testResult {
                        switch result {
                        case .success:
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                        case .failure:
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                        }
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 12))
                    }
                }
                .frame(width: 16, height: 16)

                if let result = testResult {
                    switch result {
                    case .success(let probe):
                        Text("Connected! (\(probe.toolCount) tools)", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                    case .failure(let probe):
                        Text("Failed - \(probe.reasonCode.rawValue)", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                    }
                } else {
                    Text("Test", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundColor(testResultColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(testResultBackground))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isTestDisabled)
    }

    /// Disable rule for the Test button: HTTP needs a URL, stdio needs a
    /// command. Either way, we don't run two probes in parallel.
    private var isTestDisabled: Bool {
        if isTesting { return true }
        switch transport {
        case .http:
            return url.trimmingCharacters(in: .whitespaces).isEmpty
        case .stdio:
            return command.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Return to the catalog grid and clear any sign-in state from the previous selection.
    private func backToCatalog() {
        clearDraft(authType: .bearerToken)
        catalogQuery = ""
        transition(to: .chooseProvider)
    }

    /// Reset the draft to a blank slate. Used when transitioning between phases
    /// so a previous selection's name / url / OAuth state doesn't leak through.
    /// Token state is dropped from Keychain via `resetDraftOAuthState`. Manual
    /// OAuth override fields are also wiped so a half-typed Client ID /
    /// Client Secret from one template doesn't bleed into the next.
    private func clearDraft(authType: MCPProviderAuthType, name: String = "", url: String = "") {
        self.name = name
        self.url = url
        self.authType = authType
        customHeaders.removeAll()
        testResult = nil
        manualAuthEndpoint = ""
        manualTokenEndpoint = ""
        manualClientId = ""
        manualClientSecret = ""
        manualScopes = ""
        showOAuthAdvanced = false
        resetDraftOAuthState()
    }

    private func transition(to newPhase: Phase) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            phase = newPhase
        }
    }

    // MARK: - Catalog Grid (Phase 1)

    private var catalogGridBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            catalogSearchField

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 160), spacing: 12)],
                spacing: 12
            ) {
                ProviderCatalogCard(
                    icon: "slider.horizontal.3",
                    title: "Custom Server",
                    tagline: "Connect to any other MCP-compatible server",
                    action: selectCustomServer
                )
                ForEach(filteredTemplates) { template in
                    ProviderCatalogCard(
                        icon: template.iconSystemName,
                        title: template.displayName,
                        tagline: template.tagline,
                        action: { selectTemplate(template) }
                    )
                }
            }

            if filteredTemplates.isEmpty && !trimmedCatalogQuery.isEmpty {
                catalogNoMatchesHint
            }
        }
    }

    /// Templates that match the current `catalogQuery`. Empty query returns the
    /// full catalog. Match is case-insensitive across `displayName` and
    /// `tagline` so users can find Linear by typing "issues".
    private var filteredTemplates: [MCPProviderTemplate] {
        let query = trimmedCatalogQuery
        guard !query.isEmpty else { return MCPProviderTemplate.allTemplates }
        return MCPProviderTemplate.allTemplates.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.tagline.localizedCaseInsensitiveContains(query)
        }
    }

    private var trimmedCatalogQuery: String {
        catalogQuery.trimmingCharacters(in: .whitespaces)
    }

    @ViewBuilder
    private var catalogSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(themeManager.currentTheme.tertiaryText)

            ZStack(alignment: .leading) {
                if catalogQuery.isEmpty {
                    Text("Search providers", bundle: .module)
                        .font(.system(size: 13))
                        .foregroundColor(themeManager.currentTheme.placeholderText)
                        .allowsHitTesting(false)
                }
                TextField("", text: $catalogQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(themeManager.currentTheme.primaryText)
            }

            if !catalogQuery.isEmpty {
                Button(action: { catalogQuery = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(themeManager.currentTheme.tertiaryText)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(themeManager.currentTheme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private var catalogNoMatchesHint: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .light))
                .foregroundColor(themeManager.currentTheme.tertiaryText)
            Text("No services match \"\(trimmedCatalogQuery)\"", bundle: .module)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(themeManager.currentTheme.secondaryText)
            Text("Try a different name, or pick Custom Server above.", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(themeManager.currentTheme.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func selectTemplate(_ template: MCPProviderTemplate) {
        // Self-hosting templates (e.g. Google Workspace) have no hosted endpoint;
        // open the docs in the browser and drop the user into the freeform editor
        // with the name pre-filled so they can paste their deployment's URL.
        if let helpURL = template.selfHostingHelpURL {
            NSWorkspace.shared.open(helpURL)
            clearDraft(authType: .bearerToken, name: template.displayName, url: "")
            transition(to: .configureCustom)
            return
        }
        // OAuth and bearer-token templates both go to .configureKnown — the screen
        // branches on template.authType for the correct sign-in vs. API-key UI.
        clearDraft(authType: template.authType, name: template.displayName, url: template.url)
        transition(to: .configureKnown(template))
    }

    private func selectCustomServer() {
        clearDraft(authType: .bearerToken)
        transition(to: .configureCustom)
    }

    // MARK: - Configure Known Provider (Phase 2a)

    @ViewBuilder
    private func configureKnownBody(template: MCPProviderTemplate) -> some View {
        VStack(spacing: 24) {
            // Hero
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    themeManager.currentTheme.accentColor.opacity(0.22),
                                    themeManager.currentTheme.accentColor.opacity(0.06),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: template.iconSystemName)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    themeManager.currentTheme.accentColor,
                                    themeManager.currentTheme.accentColor.opacity(0.7),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .frame(width: 72, height: 72)

                VStack(spacing: 4) {
                    Text(LocalizedStringKey(template.displayName), bundle: .module)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(themeManager.currentTheme.primaryText)
                    Text(LocalizedStringKey(template.tagline), bundle: .module)
                        .font(.system(size: 13))
                        .foregroundColor(themeManager.currentTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 12)

            // Auth-specific block
            VStack(spacing: 12) {
                switch template.authType {
                case .oauth:
                    if isOAuthSignedIn {
                        connectedBlock(template: template)
                    } else if template.requiresManualOAuthCredentials {
                        // Confidential-client OAuth flow (HubSpot's MCP Auth
                        // Apps): user must register an app in the vendor's
                        // portal first and paste both client_id +
                        // client_secret before sign-in is allowed.
                        confidentialOAuthBlock(template: template)
                    } else {
                        signInBlock(template: template)
                    }
                case .bearerToken:
                    apiKeyBlock(template: template)
                case .none:
                    noAuthBlock(template: template)
                }

                if let error = oauthError, template.authType == .oauth {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(themeManager.currentTheme.errorColor)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .padding(.horizontal, 8)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func signInBlock(template: MCPProviderTemplate) -> some View {
        VStack(spacing: 10) {
            oauthSignInButton(template: template, enabled: true)

            Text(
                "We'll open your browser to sign in. After approving, you'll be redirected back to Osaurus.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(themeManager.currentTheme.tertiaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
        }
    }

    /// Big "Sign In with [Provider]" button shared by the OAuth+DCR and
    /// confidential-client OAuth flows. Visual treatment matches across
    /// both so the connect-known screen reads as one design family — only
    /// the gating predicate differs (DCR is always enabled; confidential-
    /// client waits on Client ID + Client Secret being filled in).
    @ViewBuilder
    private func oauthSignInButton(template: MCPProviderTemplate, enabled: Bool) -> some View {
        Button(action: signInWithOAuth) {
            HStack(spacing: 8) {
                if isSigningIn {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "person.badge.key.fill")
                        .font(.system(size: 13, weight: .semibold))
                }
                Group {
                    if isSigningIn {
                        Text("Waiting for browser…", bundle: .module)
                    } else {
                        Text("Sign In with \(template.displayName)", bundle: .module)
                    }
                }
                .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        enabled
                            ? themeManager.currentTheme.accentColor
                            : themeManager.currentTheme.accentColor.opacity(0.4)
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isSigningIn || !enabled)
    }

    @ViewBuilder
    private func connectedBlock(template: MCPProviderTemplate) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(themeManager.currentTheme.successColor)
                Text("Connected to \(template.displayName)", bundle: .module)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.primaryText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(themeManager.currentTheme.successColor.opacity(0.12))
            )

            if let scopes = oauthConfig?.scopes, !scopes.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 9))
                    Text(scopes.joined(separator: " "))
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .foregroundColor(themeManager.currentTheme.tertiaryText)
                .frame(maxWidth: 360)
            }

            Button(action: signInWithOAuth) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                    Text("Re-authenticate", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(themeManager.currentTheme.secondaryText)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isSigningIn)
        }
    }

    /// Connect-known body for OAuth providers without DCR (HubSpot's MCP Auth
    /// Apps). Walks the user through registering an OAuth app in the vendor's
    /// portal, surfaces the exact loopback redirect URI they need to register
    /// (with a copy button), and collects the resulting Client ID + Client
    /// Secret before allowing the browser sign-in.
    @ViewBuilder
    private func confidentialOAuthBlock(template: MCPProviderTemplate) -> some View {
        // The template is expected to pin a port (see
        // `MCPProviderTemplateTests.confidentialOAuthTemplatesAreFullyConfigured`);
        // the `?? 0` fallback only fires for a programming error and renders
        // a deliberately-wrong URL so it surfaces in development.
        let redirectURI = "http://127.0.0.1:\(template.oauthFixedLoopbackPort ?? 0)/callback"
        let canSignIn =
            !manualClientId.trimmingCharacters(in: .whitespaces).isEmpty
            && !manualClientSecret.trimmingCharacters(in: .whitespaces).isEmpty

        VStack(alignment: .leading, spacing: 14) {
            confidentialOAuthSetupCard(template: template, redirectURI: redirectURI)

            if let helpURL = template.oauthSetupHelpURL {
                Button(action: { NSWorkspace.shared.open(helpURL) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "link.circle.fill")
                            .font(.system(size: 11))
                        Text("Open \(template.displayName) docs", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(themeManager.currentTheme.accentColor)
                }
                .buttonStyle(PlainButtonStyle())
            }

            VStack(spacing: 10) {
                MCPStyledTextField(
                    label: "Client ID",
                    placeholder: "Paste the Client ID",
                    text: $manualClientId,
                    isMonospaced: true
                )
                MCPStyledSecureField(
                    label: "Client Secret",
                    placeholder: "Paste the Client Secret",
                    text: $manualClientSecret
                )
            }
            .frame(maxWidth: 460)

            HStack {
                Spacer(minLength: 0)
                oauthSignInButton(template: template, enabled: canSignIn)
                Spacer(minLength: 0)
            }

            Text(
                "Your Client Secret is stored in your macOS Keychain and only sent to \(template.displayName).",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(themeManager.currentTheme.tertiaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
        }
    }

    /// Numbered setup-step card rendered above the credential fields. The
    /// order matters: register the OAuth app first, otherwise the redirect
    /// URI mismatch on the first sign-in attempt is the only feedback the
    /// user gets.
    @ViewBuilder
    private func confidentialOAuthSetupCard(
        template: MCPProviderTemplate,
        redirectURI: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            confidentialOAuthStep(
                number: 1,
                text: String(
                    format: L("Create an OAuth app in the %@ developer portal."),
                    template.displayName
                )
            )
            confidentialOAuthStep(
                number: 2,
                text: L("Register this exact redirect URI in the app's settings:")
            )
            redirectURIRow(redirectURI)
            confidentialOAuthStep(
                number: 3,
                text: L("Paste the resulting Client ID and Client Secret below, then click Sign In.")
            )
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(themeManager.currentTheme.tertiaryBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(themeManager.currentTheme.primaryBorder, lineWidth: 1)
        )
    }

    /// One numbered row in the confidential-OAuth setup card. Mirrors the
    /// "Where do I get my key?" tone but with explicit ordering since the
    /// steps are ordering-sensitive (URI must be registered before sign-in).
    @ViewBuilder
    private func confidentialOAuthStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(themeManager.currentTheme.tertiaryText)
                .frame(width: 18, alignment: .trailing)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(themeManager.currentTheme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Selectable redirect-URI value with a Copy button. Rendering the URI
    /// outside a `TextField` so it reads as documentation rather than an
    /// editable field — the user must register it byte-for-byte and an
    /// accidental edit here would silently break the next sign-in.
    @ViewBuilder
    private func redirectURIRow(_ uri: String) -> some View {
        HStack(spacing: 8) {
            Text(uri)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(themeManager.currentTheme.primaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(themeManager.currentTheme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                        )
                )
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)

            Button(action: { copyToPasteboard(uri) }) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                    Text("Copy", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(themeManager.currentTheme.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(themeManager.currentTheme.accentColor.opacity(0.10))
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.leading, 26)
    }

    /// Replace the system pasteboard contents with `value`. Pulled out so
    /// the Copy buttons can stay one-line readable.
    private func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    @ViewBuilder
    private func apiKeyBlock(template: MCPProviderTemplate) -> some View {
        VStack(spacing: 10) {
            MCPStyledSecureField(
                label: "API Key",
                placeholder: "Paste your API key",
                text: $token
            )
            .frame(maxWidth: 420)

            if let helpURL = template.apiKeyHelpURL {
                Button(action: { NSWorkspace.shared.open(helpURL) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "link.circle.fill")
                            .font(.system(size: 11))
                        Text("Where do I get my key?", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(themeManager.currentTheme.accentColor)
                }
                .buttonStyle(PlainButtonStyle())
            }

            Text(
                "Your API key is stored in your macOS Keychain and only sent to \(template.displayName).",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(themeManager.currentTheme.tertiaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
        }
    }

    @ViewBuilder
    private func noAuthBlock(template: MCPProviderTemplate) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.open.fill")
                .font(.system(size: 13))
                .foregroundColor(themeManager.currentTheme.successColor)
            Text("This server doesn't require authentication.", bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(themeManager.currentTheme.primaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(themeManager.currentTheme.successColor.opacity(0.10))
        )
    }

    /// "Add Provider" enable rule for the connect-known footer. OAuth waits on
    /// sign-in (which for confidential-client templates also implies that
    /// client_id + client_secret were filled in beforehand), bearer-token
    /// waits on a non-empty key, none is always ready.
    private func canSaveKnown(_ template: MCPProviderTemplate) -> Bool {
        switch template.authType {
        case .oauth:
            return isOAuthSignedIn
        case .bearerToken:
            return !token.trimmingCharacters(in: .whitespaces).isEmpty
        case .none:
            return true
        }
    }

    // MARK: - Configure Custom Server (Phase 2b)

    private var configureCustomBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            EditorCard(title: "Connection", icon: "link") {
                VStack(alignment: .leading, spacing: 14) {
                    MCPStyledTextField(
                        label: "Name",
                        placeholder: "My MCP Server",
                        text: $name
                    )

                    transportPicker

                    switch transport {
                    case .http:
                        MCPStyledTextField(
                            label: "URL",
                            placeholder: "https://mcp.example.com",
                            text: $url,
                            isMonospaced: true
                        )

                        authTypePicker

                        switch authType {
                        case .none:
                            EmptyView()
                        case .bearerToken:
                            MCPStyledSecureField(
                                label: "Bearer Token",
                                placeholder: "Optional - stored securely in Keychain",
                                text: $token
                            )
                        case .oauth:
                            oauthSection
                        }
                    case .stdio:
                        stdioFields
                    }
                }
            }

            if transport == .http {
                customHeadersCard
            } else {
                stdioEnvCard
            }

            advancedCard

            if let result = testResult {
                probeResultCard(result.probeResult)
            }
        }
        .padding(0)
    }

    private func probeResultCard(_ result: MCPProviderProbeResult) -> some View {
        EditorCard(
            title: result.succeeded ? "Probe Passed" : "Probe Failed",
            icon: result.succeeded ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    probeChip(title: "Reason", value: result.reasonCode.rawValue)
                    probeChip(title: "Stage", value: result.stage.rawValue)
                    probeChip(title: "Tools", value: "\(result.toolCount)")
                }

                Text(result.redactedMessage)
                    .font(.system(size: 12))
                    .foregroundColor(themeManager.currentTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let action = result.redactedAction {
                    Text(action)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(themeManager.currentTheme.accentColor)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: { copyProbeResult(result) }) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Copy Probe Result", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(themeManager.currentTheme.accentColor)
                }
                .buttonStyle(PlainButtonStyle())
                .localizedHelp("Copy")
            }
        }
    }

    private func probeChip(title: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(LocalizedStringKey(title), bundle: .module)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(themeManager.currentTheme.tertiaryText)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(themeManager.currentTheme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(themeManager.currentTheme.tertiaryBackground)
        )
    }

    private func copyProbeResult(_ result: MCPProviderProbeResult) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(result.pasteboardText, forType: .string)
    }

    private var customHeadersCard: some View {
        keyValueCard(
            title: "Custom Headers",
            icon: "list.bullet.rectangle",
            emptyLabel: "No custom headers configured",
            addLabel: "Add Header",
            entries: $customHeaders
        )
    }

    private var stdioEnvCard: some View {
        keyValueCard(
            title: "Environment Variables",
            icon: "wand.and.stars",
            emptyLabel: "No environment variables configured",
            addLabel: "Add Variable",
            entries: $envEntries
        )
    }

    /// Shared "list of key/value rows in a titled card" widget used for
    /// both HTTP custom headers and stdio env vars. The two surfaces had
    /// identical structure (empty-state row -> add button -> ForEach of
    /// rows) so we collapse them here.
    @ViewBuilder
    private func keyValueCard(
        title: String,
        icon: String,
        emptyLabel: String,
        addLabel: String,
        entries: Binding<[HeaderEntry]>
    ) -> some View {
        EditorCard(title: title, icon: icon) {
            VStack(alignment: .leading, spacing: 12) {
                let addButton = keyValueAddButton(label: addLabel, entries: entries)
                if entries.wrappedValue.isEmpty {
                    HStack {
                        Text(LocalizedStringKey(emptyLabel), bundle: .module)
                            .font(.system(size: 13))
                            .foregroundColor(themeManager.currentTheme.tertiaryText)
                        Spacer()
                        addButton
                    }
                    .padding(.vertical, 4)
                } else {
                    HStack {
                        Spacer()
                        addButton
                    }
                    ForEach(entries) { $entry in
                        HeaderRow(header: $entry) {
                            entries.wrappedValue.removeAll { $0.id == entry.id }
                        }
                    }
                }
            }
        }
    }

    private func keyValueAddButton(
        label: String,
        entries: Binding<[HeaderEntry]>
    ) -> some View {
        Button(action: {
            entries.wrappedValue.append(HeaderEntry(key: "", value: "", isSecret: false))
        }) {
            HStack(spacing: 4) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 11))
                Text(LocalizedStringKey(label), bundle: .module)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(themeManager.currentTheme.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(themeManager.currentTheme.accentColor.opacity(0.1))
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    /// Stdio-only Connection-card fields: where to run, the command, args,
    /// and an optional working directory. The env-var card lives outside
    /// this view because it has a different layout (a list of rows).
    @ViewBuilder
    private var stdioFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            executionHostPicker

            executionHostExplainer

            MCPStyledTextField(
                label: "Command",
                placeholder: "/usr/local/bin/uvx or npx",
                text: $command,
                isMonospaced: true
            )

            MCPStyledTextField(
                label: "Arguments",
                placeholder: "e.g. -y @scope/server --root '/path with spaces'",
                text: $argsString,
                isMonospaced: true
            )

            MCPStyledTextField(
                label: "Working Directory",
                placeholder: "Optional, e.g. /Users/me/projects/my-mcp",
                text: $workingDirectory,
                isMonospaced: true
            )
        }
    }

    private var transportPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Transport", bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(themeManager.currentTheme.primaryText)
            Picker("Transport", selection: $transport) {
                Text("HTTP / SSE", bundle: .module).tag(MCPProviderTransport.http)
                Text("Stdio", bundle: .module).tag(MCPProviderTransport.stdio)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var executionHostPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Run in", bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(themeManager.currentTheme.primaryText)
            Picker("Run in", selection: $executionHost) {
                Text("Sandbox", bundle: .module).tag(MCPProviderExecutionHost.sandbox)
                Text("Host", bundle: .module).tag(MCPProviderExecutionHost.host)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// Explanatory copy under the Sandbox / Host segmented picker. We
    /// show *something* for both choices — the previous UI only warned
    /// on Host, so users picking Sandbox had no idea what they were
    /// opting into (e.g. that the subprocess can't see their files but
    /// *can* talk to the internet).
    @ViewBuilder
    private var executionHostExplainer: some View {
        switch executionHost {
        case .sandbox:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.accentColor)
                Text(
                    "Runs in an isolated Linux VM with no access to host files or credentials. Outbound network is on by default and can be turned off per agent in the agent's Sandbox settings.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(themeManager.currentTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(themeManager.currentTheme.accentColor.opacity(0.08))
            )

        case .host:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.orange)
                Text(
                    "Running on the host means this subprocess can access your files, network, and credentials. Only use Host for tools you trust.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(themeManager.currentTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.10))
            )
        }
    }

    /// Streaming / auto-connect / timeout sliders. Shared between the HTTP
    /// and stdio editor flows so the user gets the same advanced surface
    /// regardless of transport.
    private var advancedCard: some View {
        EditorCard(title: "Advanced", icon: "gearshape") {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showAdvanced.toggle()
                    }
                }) {
                    HStack {
                        Text(showAdvanced ? L("Hide advanced settings") : L("Show advanced settings"))
                            .font(.system(size: 13))
                            .foregroundColor(themeManager.currentTheme.accentColor)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(themeManager.currentTheme.tertiaryText)
                            .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())

                if showAdvanced {
                    VStack(alignment: .leading, spacing: 16) {
                        Divider().padding(.vertical, 8)

                        // Streaming is HTTP-only (SSE); the stdio JSON-RPC
                        // protocol streams every response by default so the
                        // toggle is meaningless there.
                        if transport == .http {
                            MCPToggleRow(
                                title: "Enable Streaming",
                                description: "Stream tool responses in real-time",
                                isOn: $streamingEnabled
                            )
                        }

                        MCPToggleRow(
                            title: "Auto-connect on Launch",
                            description: "Connect automatically when app starts",
                            isOn: $autoConnect
                        )

                        Divider().padding(.vertical, 4)

                        VStack(alignment: .leading, spacing: 16) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Discovery Timeout", bundle: .module)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(themeManager.currentTheme.primaryText)
                                    Spacer()
                                    Text("\(Int(discoveryTimeout))s", bundle: .module)
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .foregroundColor(themeManager.currentTheme.accentColor)
                                }
                                Slider(value: $discoveryTimeout, in: 5 ... 60, step: 5)
                                    .tint(themeManager.currentTheme.accentColor)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Tool Call Timeout", bundle: .module)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(themeManager.currentTheme.primaryText)
                                    Spacer()
                                    Text("\(Int(toolCallTimeout))s", bundle: .module)
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .foregroundColor(themeManager.currentTheme.accentColor)
                                }
                                Slider(value: $toolCallTimeout, in: 10 ... 120, step: 5)
                                    .tint(themeManager.currentTheme.accentColor)
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    @ViewBuilder
    private var authTypePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Authentication", bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(themeManager.currentTheme.primaryText)

            Picker("Authentication", selection: $authType) {
                Text("None", bundle: .module).tag(MCPProviderAuthType.none)
                Text("Bearer Token", bundle: .module).tag(MCPProviderAuthType.bearerToken)
                Text("OAuth", bundle: .module).tag(MCPProviderAuthType.oauth)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// Drop any in-flight OAuth credentials for the current draft id and clear
    /// the matching UI flags. Safe to call repeatedly; Keychain delete is
    /// idempotent on missing items. Confidential-client `client_secret` is
    /// purged too so a half-finished HubSpot draft can't leak its secret into
    /// a fresh draft on the same `effectiveProviderId`.
    private func resetDraftOAuthState() {
        token = ""
        oauthError = nil
        oauthConfig = nil
        isOAuthSignedIn = false
        MCPProviderKeychain.deleteOAuthTokens(for: effectiveProviderId)
        MCPProviderKeychain.deleteOAuthClientSecret(for: effectiveProviderId)
    }

    @ViewBuilder
    private var oauthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                Text("Sign in via the server's OAuth login flow", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(themeManager.currentTheme.secondaryText)
            }

            HStack(spacing: 10) {
                Button(action: signInWithOAuth) {
                    HStack(spacing: 6) {
                        if isSigningIn {
                            ProgressView().scaleEffect(0.6)
                        } else {
                            Image(systemName: isOAuthSignedIn ? "arrow.clockwise" : "person.badge.key")
                                .font(.system(size: 12))
                        }
                        Text(
                            LocalizedStringKey(isOAuthSignedIn ? "Re-authenticate" : "Sign In"),
                            bundle: .module
                        )
                        .font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(MCPPrimaryButtonStyle())
                .disabled(isSigningIn || url.trimmingCharacters(in: .whitespaces).isEmpty)

                if isOAuthSignedIn {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(themeManager.currentTheme.successColor)
                        Text("Signed in", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(themeManager.currentTheme.successColor)
                    }
                }

                Spacer()
            }

            if let error = oauthError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.currentTheme.errorColor)
                    .lineLimit(3)
            }

            if let config = oauthConfig, !config.scopes.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 9))
                        .foregroundColor(themeManager.currentTheme.tertiaryText)
                    Text(config.scopes.joined(separator: " "))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(themeManager.currentTheme.tertiaryText)
                        .lineLimit(2)
                }
            }

            oauthAdvancedSection
        }
    }

    /// Manual OAuth override fields. Most users never need these — they're
    /// for MCP servers that don't implement RFC 9728 PRM (e.g. servers that
    /// ship explicit endpoints in a Claude plugin's `.mcp.json oauth` block).
    /// When both endpoints are filled in, the OAuth service skips discovery.
    private var oauthAdvancedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) { showOAuthAdvanced.toggle() }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(themeManager.currentTheme.tertiaryText)
                        .rotationEffect(.degrees(showOAuthAdvanced ? 90 : 0))
                    Text("Manual endpoints (advanced)", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(themeManager.currentTheme.secondaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            if showOAuthAdvanced {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "Fill these in only for servers that don't advertise OAuth metadata. Both the authorize and token URLs must be set to skip discovery.",
                        bundle: .module
                    )
                    .font(.system(size: 10))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)

                    MCPStyledTextField(
                        label: "Authorize URL",
                        placeholder: "https://auth.example.com/oauth/authorize",
                        text: $manualAuthEndpoint,
                        isMonospaced: true
                    )
                    MCPStyledTextField(
                        label: "Token URL",
                        placeholder: "https://auth.example.com/oauth/token",
                        text: $manualTokenEndpoint,
                        isMonospaced: true
                    )
                    MCPStyledTextField(
                        label: "Client ID",
                        placeholder: "Pre-registered OAuth client id (leave blank for DCR)",
                        text: $manualClientId,
                        isMonospaced: true
                    )
                    MCPStyledTextField(
                        label: "Scopes",
                        placeholder: "space- or comma-separated, e.g. read write offline_access",
                        text: $manualScopes
                    )
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func signInWithOAuth() {
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        guard !trimmedURL.isEmpty else { return }

        // Confidential-client templates (HubSpot's MCP Auth Apps) require the
        // user to paste both client_id + client_secret before sign-in. Stash
        // the secret in Keychain so `MCPOAuthService` can include it in the
        // token POST without ever copying it back into the in-memory provider
        // record.
        if let template = activeTemplate, template.requiresManualOAuthCredentials {
            let trimmedClientId = manualClientId.trimmingCharacters(in: .whitespaces)
            let trimmedClientSecret = manualClientSecret.trimmingCharacters(in: .whitespaces)
            guard !trimmedClientId.isEmpty, !trimmedClientSecret.isEmpty else { return }
            MCPProviderKeychain.saveOAuthClientSecret(
                trimmedClientSecret,
                for: effectiveProviderId
            )
        }

        isSigningIn = true
        oauthError = nil

        // Build a draft provider record carrying any cached client_id, manual
        // endpoint overrides from the Advanced disclosure, and the active
        // template's `oauthFixedLoopbackPort` (when set, e.g. HubSpot). When
        // both endpoints are present the OAuth service skips RFC 9728
        // discovery entirely; when `oauthFixedLoopbackPort` is set, the
        // loopback server binds the exact port the user registered with the
        // vendor instead of an ephemeral one.
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let mergedOAuth = mergedManualOAuthConfig()
        let draftProvider = MCPProvider(
            id: effectiveProviderId,
            name: trimmedName.isEmpty ? "MCP Provider" : trimmedName,
            url: trimmedURL,
            enabled: true,
            authType: .oauth,
            oauth: mergedOAuth
        )

        Task { @MainActor in
            do {
                let result = try await MCPOAuthService.signIn(provider: draftProvider, hint: nil, persist: true)
                self.oauthConfig = result.config
                self.isOAuthSignedIn = true
                self.isSigningIn = false
            } catch {
                self.oauthError = error.localizedDescription
                self.isSigningIn = false
            }
        }
    }

    /// Combine the manual override text fields with whatever `oauthConfig`
    /// already has cached from previous sign-ins. Empty manual fields fall
    /// through to the cached value so a partial override doesn't blow away
    /// data the user can't see. When the user is configuring a known template
    /// that pins a fixed loopback port (HubSpot), that port is baked into the
    /// merged config so `MCPOAuthService.signIn` and subsequent refreshes
    /// keep using it.
    private func mergedManualOAuthConfig() -> MCPOAuthConfig? {
        let auth = manualAuthEndpoint.trimmingCharacters(in: .whitespaces)
        let token = manualTokenEndpoint.trimmingCharacters(in: .whitespaces)
        let clientId = manualClientId.trimmingCharacters(in: .whitespaces)
        let scopes =
            manualScopes
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let templatePort = activeTemplate?.oauthFixedLoopbackPort

        let anyManual = !auth.isEmpty || !token.isEmpty || !clientId.isEmpty || !scopes.isEmpty
        guard anyManual || oauthConfig != nil || templatePort != nil else { return nil }

        var merged = oauthConfig ?? MCPOAuthConfig()
        if !auth.isEmpty { merged.authorizationEndpoint = auth }
        if !token.isEmpty { merged.tokenEndpoint = token }
        if !clientId.isEmpty { merged.clientId = clientId }
        if !scopes.isEmpty { merged.scopes = scopes }
        // Templates with a pinned port (HubSpot's MCP Auth Apps) win over a
        // previously-cached nil. We never let a saved nil clobber the
        // template's port either — the template is the source of truth here.
        if let templatePort, templatePort != 0 {
            merged.loopbackPort = templatePort
        }
        return merged
    }

    private var testResultColor: Color {
        guard let result = testResult else { return themeManager.currentTheme.secondaryText }
        switch result {
        case .success: return themeManager.currentTheme.successColor
        case .failure: return themeManager.currentTheme.errorColor
        }
    }

    private var testResultBackground: Color {
        guard let result = testResult else { return themeManager.currentTheme.tertiaryBackground }
        switch result {
        case .success: return themeManager.currentTheme.successColor.opacity(0.12)
        case .failure: return themeManager.currentTheme.errorColor.opacity(0.12)
        }
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch transport {
        case .http:
            return !url.trimmingCharacters(in: .whitespaces).isEmpty
        case .stdio:
            return !command.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func loadProvider() {
        guard let provider = provider else {
            // Add-mode: stay on the catalog grid. The draftId is preserved so
            // anything OAuth-saved mid-flow ends up on this id and persists
            // through save().
            phase = .chooseProvider
            return
        }
        // Edit-mode: jump straight to the freeform editor. Re-use the existing
        // record's id so OAuth tokens already in Keychain match.
        draftId = provider.id
        name = provider.name
        url = provider.url
        streamingEnabled = provider.streamingEnabled
        discoveryTimeout = provider.discoveryTimeout
        toolCallTimeout = provider.toolCallTimeout
        autoConnect = provider.autoConnect
        authType = provider.authType
        oauthConfig = provider.oauth
        isOAuthSignedIn =
            provider.authType == .oauth
            && MCPProviderKeychain.hasOAuthTokens(for: provider.id)

        // Pre-populate manual OAuth overrides from any existing config, so editing
        // a provider doesn't silently drop the manual endpoints on save.
        if let cfg = provider.oauth {
            manualAuthEndpoint = cfg.authorizationEndpoint ?? ""
            manualTokenEndpoint = cfg.tokenEndpoint ?? ""
            manualClientId = cfg.clientId ?? ""
            manualScopes = cfg.scopes.joined(separator: " ")
            // Auto-expand the advanced section when there's anything to show.
            showOAuthAdvanced =
                !manualAuthEndpoint.isEmpty
                || !manualTokenEndpoint.isEmpty
                || !manualClientId.isEmpty
                || !manualScopes.isEmpty
        }

        customHeaders = provider.customHeaders.map { HeaderEntry(key: $0.key, value: $0.value, isSecret: false) }
        for key in provider.secretHeaderKeys {
            customHeaders.append(HeaderEntry(key: key, value: "", isSecret: true))
        }
        // Note: Token not loaded for security - user must re-enter if changing.

        // Stdio fields. Args are joined into a single line so we don't need
        // a list editor for them; users can re-quote on save. Secret env
        // values are never pulled out of Keychain (same policy as headers).
        transport = provider.transport
        executionHost = provider.executionHost
        command = provider.command
        // `ShellArgs.join` re-quotes args that contain spaces / special
        // characters so a round-trip through the editor doesn't corrupt
        // a path like `/Users/me/long path` into two separate args.
        argsString = ShellArgs.join(provider.args)
        workingDirectory = provider.workingDirectory ?? ""
        envEntries = provider.env.map { HeaderEntry(key: $0.key, value: $0.value, isSecret: false) }
        for key in provider.secretEnvKeys {
            envEntries.append(HeaderEntry(key: key, value: "", isSecret: true))
        }

        phase = .configureCustom
    }

    private func testConnection() {
        isTesting = true
        testResult = nil

        Task {
            let provider = makeProbeProvider()
            let result: MCPProviderProbeResult
            switch transport {
            case .http:
                result = await MCPProviderProbeService.probeHTTP(
                    providerId: provider.id,
                    name: provider.name,
                    url: provider.url,
                    token: httpTestToken(),
                    headers: buildHeaders(),
                    streamingEnabled: provider.streamingEnabled,
                    discoveryTimeout: provider.discoveryTimeout
                )
            case .stdio:
                result = await MCPProviderProbeService.probeStdio(provider: provider)
            }
            MCPProviderHealthSnapshotStore.record(result, for: provider)

            await MainActor.run {
                testResult = result.succeeded ? .success(result) : .failure(result)
                isTesting = false
            }
        }
    }

    /// Token to use for the HTTP test request. OAuth providers reuse the
    /// access token already in Keychain so the user can probe the server
    /// before clicking Save.
    private func httpTestToken() -> String? {
        switch authType {
        case .bearerToken:
            return token.isEmpty ? nil : token
        case .oauth:
            return MCPProviderKeychain.getOAuthTokens(for: effectiveProviderId)?.accessToken
        case .none:
            return nil
        }
    }

    /// Snapshot of the stdio editor fields ready to drop into an
    /// `MCPProvider`. Sharing this between `save()` and the test-probe
    /// builder keeps the two call sites honest — there was previously a
    /// quiet drift where the probe skipped empty-value env vars and
    /// `save()` did not.
    private struct ParsedStdioFields {
        let command: String
        let args: [String]
        let env: [String: String]
        let secretEnvKeys: [String]
        let workingDirectory: String?
    }

    private func parseStdioFields() -> ParsedStdioFields {
        var regularEnv: [String: String] = [:]
        var secretEnvKeys: [String] = []
        for entry in envEntries where !entry.key.isEmpty {
            if entry.isSecret {
                secretEnvKeys.append(entry.key)
            } else if !entry.value.isEmpty {
                // Skip empty regular env vars — persisting `KEY=""`
                // would silently shadow whatever the subprocess
                // inherits from its environment, which is almost
                // never what the user intended.
                regularEnv[entry.key] = entry.value
            }
        }
        let trimmedCwd = workingDirectory.trimmingCharacters(in: .whitespaces)
        return ParsedStdioFields(
            command: command.trimmingCharacters(in: .whitespaces),
            args: ShellArgs.split(argsString),
            env: regularEnv,
            secretEnvKeys: secretEnvKeys,
            workingDirectory: trimmedCwd.isEmpty ? nil : trimmedCwd
        )
    }

    /// Synthesize an in-memory `MCPProvider` from the current editor
    /// state so we can hand it to `testStdioConnection`. This is **not**
    /// persisted; it lives just long enough to spawn + handshake.
    private func makeStdioProbeProvider() -> MCPProvider {
        let fields = parseStdioFields()
        return MCPProvider(
            id: effectiveProviderId,
            name: name.isEmpty ? "Stdio test" : name,
            url: "",
            authType: .none,
            transport: .stdio,
            executionHost: executionHost,
            command: fields.command,
            args: fields.args,
            env: fields.env,
            secretEnvKeys: fields.secretEnvKeys,
            workingDirectory: fields.workingDirectory
        )
    }

    private func makeProbeProvider() -> MCPProvider {
        switch transport {
        case .http:
            return MCPProvider(
                id: effectiveProviderId,
                name: name.isEmpty ? "HTTP MCP probe" : name,
                url: url.trimmingCharacters(in: .whitespaces),
                customHeaders: buildHeaders(),
                streamingEnabled: streamingEnabled,
                discoveryTimeout: discoveryTimeout,
                toolCallTimeout: toolCallTimeout,
                authType: authType,
                transport: .http
            )
        case .stdio:
            return makeStdioProbeProvider()
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)

        // Separate regular headers from secret headers
        var regularHeaders: [String: String] = [:]
        var secretKeys: [String] = []

        for header in customHeaders where !header.key.isEmpty {
            if header.isSecret {
                secretKeys.append(header.key)
            } else {
                regularHeaders[header.key] = header.value
            }
        }

        // Merge any manual OAuth overrides into the saved config so they
        // survive past sheet dismissal, even if the user hasn't clicked
        // Sign In yet.
        let oauthForSave: MCPOAuthConfig? =
            authType == .oauth ? mergedManualOAuthConfig() : nil

        // Stdio fields (command + args + env). Shared with the
        // test-connection probe so the two paths can't drift.
        let stdio = parseStdioFields()

        let updatedProvider = MCPProvider(
            id: effectiveProviderId,
            name: trimmedName,
            url: trimmedURL,
            enabled: provider?.enabled ?? true,
            customHeaders: regularHeaders,
            streamingEnabled: streamingEnabled,
            discoveryTimeout: discoveryTimeout,
            toolCallTimeout: toolCallTimeout,
            autoConnect: autoConnect,
            secretHeaderKeys: secretKeys,
            authType: authType,
            oauth: oauthForSave,
            // Preserve the plugin grouping so an edit-then-save on a
            // Claude-plugin-imported provider doesn't strip its uninstall
            // tag.
            pluginId: provider?.pluginId,
            transport: transport,
            executionHost: executionHost,
            command: stdio.command,
            args: stdio.args,
            env: stdio.env,
            secretEnvKeys: stdio.secretEnvKeys,
            workingDirectory: stdio.workingDirectory
        )

        // Save secret env values to Keychain. Like the bearer/secret-header
        // path, blank values mean "don't overwrite" so the user can leave
        // sensitive fields alone after the first save.
        for entry in envEntries
        where entry.isSecret && !entry.key.isEmpty && !entry.value.isEmpty {
            _ = MCPProviderKeychain.saveEnvSecret(
                entry.value,
                key: entry.key,
                for: updatedProvider.id
            )
        }

        // Save secret header values to Keychain
        for header in customHeaders where header.isSecret && !header.key.isEmpty && !header.value.isEmpty {
            MCPProviderKeychain.saveHeaderSecret(header.value, key: header.key, for: updatedProvider.id)
        }

        // Pass token (empty string means no change, nil means keep existing).
        // For OAuth this is unused (tokens went through MCPOAuthService directly).
        let tokenToSave: String? = (authType == .bearerToken && !token.isEmpty) ? token : nil

        onSave(updatedProvider, tokenToSave)
        dismiss()
    }

    private func buildHeaders() -> [String: String] {
        var headers: [String: String] = [:]
        for header in customHeaders where !header.key.isEmpty && !header.value.isEmpty {
            headers[header.key] = header.value
        }
        return headers
    }
}

extension ProviderEditSheet.TestResult {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

// MARK: - Provider Catalog Card

/// One cell in the catalog grid: icon, title, two-line tagline, full-cell tap target.
private struct ProviderCatalogCard: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let icon: String
    let title: String
    let tagline: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(themeManager.currentTheme.accentColor.opacity(0.12))
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(themeManager.currentTheme.accentColor)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(title), bundle: .module)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(themeManager.currentTheme.primaryText)
                        .lineLimit(1)
                    Text(LocalizedStringKey(tagline), bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(themeManager.currentTheme.secondaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        isHovering
                            ? themeManager.currentTheme.accentColor.opacity(0.06)
                            : themeManager.currentTheme.tertiaryBackground
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isHovering
                            ? themeManager.currentTheme.accentColor.opacity(0.4)
                            : themeManager.currentTheme.primaryBorder,
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
    }
}

// MARK: - Header Row

private struct HeaderRow: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Binding var header: ProviderEditSheet.HeaderEntry
    let onDelete: () -> Void

    @State private var isKeyFocused = false
    @State private var isValueFocused = false

    var body: some View {
        HStack(spacing: 8) {
            // Key field
            ZStack(alignment: .leading) {
                if header.key.isEmpty {
                    Text("Key", bundle: .module)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(themeManager.currentTheme.placeholderText)
                        .allowsHitTesting(false)
                }
                TextField(
                    "",
                    text: $header.key,
                    onEditingChanged: { editing in
                        withAnimation(.easeOut(duration: 0.15)) {
                            isKeyFocused = editing
                        }
                    }
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(themeManager.currentTheme.primaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: 120)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(themeManager.currentTheme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                isKeyFocused
                                    ? themeManager.currentTheme.accentColor.opacity(0.5)
                                    : themeManager.currentTheme.inputBorder,
                                lineWidth: isKeyFocused ? 1.5 : 1
                            )
                    )
            )

            // Value field
            ZStack(alignment: .leading) {
                if header.value.isEmpty {
                    Text(LocalizedStringKey(header.isSecret ? "Secret value" : "Value"), bundle: .module)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(themeManager.currentTheme.placeholderText)
                        .allowsHitTesting(false)
                }
                if header.isSecret {
                    SecureField("", text: $header.value)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(themeManager.currentTheme.primaryText)
                } else {
                    TextField(
                        "",
                        text: $header.value,
                        onEditingChanged: { editing in
                            withAnimation(.easeOut(duration: 0.15)) {
                                isValueFocused = editing
                            }
                        }
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.primaryText)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(themeManager.currentTheme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                isValueFocused
                                    ? themeManager.currentTheme.accentColor.opacity(0.5)
                                    : themeManager.currentTheme.inputBorder,
                                lineWidth: isValueFocused ? 1.5 : 1
                            )
                    )
            )

            // Secret toggle
            Button(action: { header.isSecret.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: header.isSecret ? "lock.fill" : "lock.open")
                        .font(.system(size: 10))
                    Text(LocalizedStringKey(header.isSecret ? "Secret" : "Plain"), bundle: .module)
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(
                    header.isSecret
                        ? themeManager.currentTheme.accentColor
                        : themeManager.currentTheme.tertiaryText
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            header.isSecret
                                ? themeManager.currentTheme.accentColor.opacity(0.1)
                                : themeManager.currentTheme.tertiaryBackground
                        )
                )
            }
            .buttonStyle(PlainButtonStyle())

            // Delete button
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.currentTheme.errorColor)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(themeManager.currentTheme.errorColor.opacity(0.1))
                    )
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
}

// MARK: - Styled Components

private struct EditorCard<Content: View>: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.accentColor)

                Text(LocalizedStringKey(title), bundle: .module)
                    .textCase(.uppercase)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(themeManager.currentTheme.secondaryText)
                    .tracking(0.5)
            }

            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(themeManager.currentTheme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(themeManager.currentTheme.cardBorder, lineWidth: 1)
                )
        )
    }
}

private struct MCPStyledTextField: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let label: String
    let placeholder: String
    @Binding var text: String
    var isMonospaced: Bool = false

    @State private var isFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(label), bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(themeManager.currentTheme.primaryText)

            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(LocalizedStringKey(placeholder), bundle: .module)
                        .font(.system(size: 13, design: isMonospaced ? .monospaced : .default))
                        .foregroundColor(themeManager.currentTheme.placeholderText)
                        .allowsHitTesting(false)
                }

                TextField(
                    "",
                    text: $text,
                    onEditingChanged: { editing in
                        withAnimation(.easeOut(duration: 0.15)) {
                            isFocused = editing
                        }
                    }
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: isMonospaced ? .monospaced : .default))
                .foregroundColor(themeManager.currentTheme.primaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(themeManager.currentTheme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                isFocused
                                    ? themeManager.currentTheme.accentColor.opacity(0.5)
                                    : themeManager.currentTheme.inputBorder,
                                lineWidth: isFocused ? 1.5 : 1
                            )
                    )
            )
        }
    }
}

private struct MCPStyledSecureField: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let label: String
    let placeholder: String
    @Binding var text: String

    @State private var isFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(LocalizedStringKey(label), bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.primaryText)

                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
            }

            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(LocalizedStringKey(placeholder), bundle: .module)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(themeManager.currentTheme.placeholderText)
                        .allowsHitTesting(false)
                }

                SecureField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.primaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(themeManager.currentTheme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                isFocused
                                    ? themeManager.currentTheme.accentColor.opacity(0.5)
                                    : themeManager.currentTheme.inputBorder,
                                lineWidth: isFocused ? 1.5 : 1
                            )
                    )
            )
        }
    }
}

private struct MCPToggleRow: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let title: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(themeManager.currentTheme.primaryText)
                Text(LocalizedStringKey(description), bundle: .module)
                    .font(.system(size: 11))
                    .foregroundStyle(themeManager.currentTheme.tertiaryText)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .toggleStyle(SwitchToggleStyle(tint: themeManager.currentTheme.accentColor))
                .labelsHidden()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(themeManager.currentTheme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                )
        )
    }
}

private struct MCPPrimaryButtonStyle: ButtonStyle {
    @ObservedObject private var themeManager = ThemeManager.shared

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(themeManager.currentTheme.accentColor)
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

private struct MCPSecondaryButtonStyle: ButtonStyle {
    @ObservedObject private var themeManager = ThemeManager.shared

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(themeManager.currentTheme.primaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(themeManager.currentTheme.tertiaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                    )
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

// MARK: - Flow Layout for Tool Tags

private struct ToolPillsFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: currentY + lineHeight), positions)
    }
}

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        ProvidersView()
            .frame(width: 700, height: 500)
            .environment(\.theme, DarkTheme())
    }
#endif
