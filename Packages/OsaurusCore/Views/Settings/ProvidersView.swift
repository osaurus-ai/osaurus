//
//  ProvidersView.swift
//  osaurus
//
//  UI for managing remote MCP providers.
//

import AppKit
import SwiftUI

/// A successful probe may refresh the executable catalog only when it tested
/// the exact persisted configuration. Publishing tools from a new or edited
/// draft would let unsaved settings affect active chats.
enum MCPProviderCatalogRefreshPolicy {
    static func shouldRefresh(
        savedProvider: MCPProvider?,
        configuredProvider: MCPProvider,
        hasCredentialEdits: Bool
    ) -> Bool {
        guard let savedProvider, savedProvider.enabled, !hasCredentialEdits else {
            return false
        }
        return savedProvider == configuredProvider
    }
}

/// Where the Add Service sheet opens. Tapping a Directory card skips the
/// sheet's own catalog step and lands straight on that service's setup.
enum MCPAddServiceStart: Equatable {
    case catalog
    case template(MCPProviderTemplate)
    case custom
}

struct ProvidersView: View {
    @Environment(\.theme) private var inheritedTheme
    private var theme: any ThemeProtocol { inheritedTheme }
    @ObservedObject private var manager = MCPProviderManager.shared
    @ObservedObject private var managementState = ManagementStateManager.shared
    /// Owned by the Tools & MCP shell so its header "Add Service" button can
    /// open the sheet from outside this view.
    @Binding var showAddSheet: Bool
    @State private var editingProvider: MCPProvider?
    /// The open add sheet: its starting step (set by the inline Directory)
    /// and any prefill from a `pendingMCPProviderDraft` hand-off. An item
    /// rather than state read only inside `.sheet(isPresented:)`, which can
    /// present with the previous value on first open.
    @State private var addRequest: AddSheetRequest?
    @State private var directoryQuery: String = ""
    @State private var directoryCategory: MCPProviderCategory?
    @State private var metadataDocumentPublished = false

    init(showAddSheet: Binding<Bool> = .constant(false)) {
        _showAddSheet = showAddSheet
    }
    @State private var hasAppeared = false
    @State private var providerFilter: MCPServerHubFilter = .all
    @State private var credentialPresence: [UUID: MCPProviderCredentialPresence] = [:]
    @State private var healthSnapshots: [UUID: MCPProviderHealthSnapshot] = MCPProviderHealthSnapshotStore.load()
    @State private var reconnectingAll = false
    @State private var probingAll = false
    @State private var probingProviderIds: Set<UUID> = []

    var body: some View {
        ScrollView {
            SettingsPageContent {
                servicesSection
                directorySection
            }
        }
        .opacity(hasAppeared ? 1 : 0)
        .onAppear {
            withAnimation(theme.motion.standard.delay(0.1)) {
                hasAppeared = true
            }
            refreshCredentialPresence()
            refreshHealthSnapshots()
            applyPendingEditRequest()
            applyPendingDraftRequest()
            if showAddSheet { openAddSheet(.catalog) }
        }
        .onChange(of: managementState.pendingMCPProviderEditId) { _, _ in
            applyPendingEditRequest()
        }
        .onChange(of: managementState.pendingMCPProviderDraft) { _, _ in
            applyPendingDraftRequest()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: Foundation.Notification.Name.mcpProviderHealthSnapshotChanged
            )
        ) { _ in
            refreshHealthSnapshots()
        }
        .onChange(of: showAddSheet) { _, show in
            if show { openAddSheet(.catalog) }
        }
        .sheet(item: $addRequest, onDismiss: { showAddSheet = false }) { request in
            ProviderEditSheet(provider: nil, prefill: request.prefill, start: request.start) { provider, token in
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

    /// Honour a one-shot `pendingMCPProviderDraft` hand-off (the API provider
    /// form detected an MCP server URL): open the add sheet straight in the
    /// custom editor with the URL and token carried over.
    private func applyPendingDraftRequest() {
        guard let draft = managementState.pendingMCPProviderDraft else { return }
        openAddSheet(.catalog, prefill: draft)
        managementState.pendingMCPProviderDraft = nil
    }

    private struct AddSheetRequest: Identifiable {
        let id = UUID()
        let start: MCPAddServiceStart
        var prefill: MCPProviderDraft?
    }

    private func openAddSheet(_ start: MCPAddServiceStart, prefill: MCPProviderDraft? = nil) {
        guard addRequest == nil else { return }
        addRequest = AddSheetRequest(start: start, prefill: prefill)
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

    // MARK: - Services

    /// Configured services as one grouped list. The header carries the live
    /// summary and a single ⋯ menu (filter + maintenance); there is no
    /// separate status panel.
    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(title: "Services", caption: servicesCaption) {
                if !manager.configuration.providers.isEmpty {
                    servicesMenu
                }
            }
            .settingsLandingAnchor("tools.services")

            SettingsGroup {
                if manager.configuration.providers.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(visibleProviderReports.enumerated()), id: \.element.id) { index, report in
                        serviceRow(report, index: index)
                    }
                    if visibleProviderReports.isEmpty {
                        Text("No services match this filter.", bundle: .module)
                            .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                            .foregroundColor(theme.text.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    /// "1 connected · 1 needs attention · 12 tools" — nil until there is
    /// at least one service.
    private var servicesCaption: String? {
        let summary = hubSnapshot.compactSummary
        guard hubSnapshot.totalCount > 0 else { return nil }
        var parts: [String] = []
        parts.append(
            summary.connected == 1 ? L("1 connected") : L("\(summary.connected) connected")
        )
        if summary.attention > 0 {
            parts.append(
                summary.attention == 1 ? L("1 needs attention") : L("\(summary.attention) need attention")
            )
        }
        parts.append(summary.tools == 1 ? L("1 tool") : L("\(summary.tools) tools"))
        return parts.joined(separator: " · ")
    }

    private var servicesMenu: some View {
        HStack(spacing: theme.space.s6) {
            if probingAll || reconnectingAll {
                ProgressView().controlSize(.small)
            }
            if providerFilter != .all {
                Text(providerFilter.displayName)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                    .foregroundColor(theme.text.secondary)
            }
            SettingsOverflowMenu(help: "Connection maintenance and diagnostics", size: .compact) {
                Picker(selection: $providerFilter) {
                    ForEach(MCPServerHubFilter.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                } label: {
                    Text("Show", bundle: .module)
                }

                Divider()

                Button(action: reconnectEnabledProviders) {
                    Label {
                        Text("Reconnect All", bundle: .module)
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(reconnectingAll || hubSnapshot.enabledCount == 0)

                Button(action: probeEnabledProviders) {
                    Label {
                        Text("Test Connections", bundle: .module)
                    } icon: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                }
                .disabled(probingAll || hubSnapshot.enabledCount == 0)

                Divider()

                Button(action: copyHubReport) {
                    Label {
                        Text("Copy Diagnostics", bundle: .module)
                    } icon: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
        }
    }

    private func serviceRow(_ report: MCPServerHubProviderReport, index: Int) -> some View {
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
                        // row banner will show it; we additionally
                        // toast it so the user notices even if their
                        // row is scrolled off-screen.
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
                _ = MCPCredentials.saveToken(token, provider: report.provider)
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

    private func refreshCredentialPresence() {
        let providers = manager.configuration.providers
        let previous = credentialPresence
        Task {
            var next: [UUID: MCPProviderCredentialPresence] = [:]
            for provider in providers {
                let providerID = provider.id
                let previousPresence = previous[providerID]
                // Typed availability: a transiently unavailable keychain
                // (locked, interaction required) keeps the previous known
                // presence instead of flashing a false "missing token" warning.
                let presence = await Task.detached(priority: .utility) {
                    MCPProviderCredentialPresence(
                        bearerTokenPresent: MCPCredentials.tokenAvailability(provider)
                            .presenceForUI(previous: previousPresence?.bearerTokenPresent),
                        oauthTokensPresent: MCPProviderKeychain.oauthTokensAvailability(
                            for: providerID
                        )
                        .presenceForUI(previous: previousPresence?.oauthTokensPresent)
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
                    try await manager.reconnect(providerId: provider.id)
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
                if result.succeeded {
                    try? await manager.reconnect(providerId: provider.id)
                }
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
            if result.succeeded, provider.enabled {
                try? await manager.reconnect(providerId: provider.id)
            }
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
                        provider.resolvedBearerToken()
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

    /// With no services configured, the group holds a one-line invitation and
    /// the Directory below does the rest.
    private var emptyState: some View {
        SettingsEmptyState(
            inline: "server.rack",
            title: "No services yet",
            hint: "Pick a service below to give your agents more tools."
        )
    }

    // MARK: - Directory

    /// Always-visible provider directory as a flat list. Tapping a row opens
    /// the Add Service sheet directly on that service's setup step.
    private var directorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(title: "Directory") {
                SearchField(text: $directoryQuery, placeholder: "Search services")
            }

            MCPProviderCategoryChips(selection: $directoryCategory)

            SettingsGroup {
                MCPProviderDirectoryRow(
                    icon: "slider.horizontal.3",
                    title: "Custom Server",
                    tagline: "Connect to any other MCP-compatible server"
                ) {
                    openAddSheet(.custom)
                }
                ForEach(directoryTemplates) { template in
                    MCPProviderDirectoryRow(
                        icon: template.iconSystemName,
                        title: template.displayName,
                        tagline: template.tagline,
                        requiresSubscription: template.requiresSubscription
                    ) {
                        openAddSheet(.template(template))
                    }
                }
                if directoryTemplates.isEmpty && directoryQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("No services in this category", bundle: .module)
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                        .foregroundColor(theme.text.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if directoryTemplates.isEmpty {
                    Text(
                        "No services match \"\(directoryQuery.trimmingCharacters(in: .whitespaces))\". Try another name, or pick Custom Server above.",
                        bundle: .module
                    )
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                    .foregroundColor(theme.text.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            SettingsGroupFooter("Each service adds tools your agents can use.")
        }
        .settingsLandingAnchor("tools.directory")
        .task { metadataDocumentPublished = await MCPOAuthClientMetadata.isDocumentPublished() }
    }

    private var directoryTemplates: [MCPProviderTemplate] {
        MCPProviderDirectoryView.templates(
            matching: directoryQuery,
            category: directoryCategory,
            metadataDocumentPublished: metadataDocumentPublished
        )
    }
}

// MARK: - Provider Card

/// A connector error in plain language, with the raw protocol text behind a
/// "Details" toggle when the presenter rewrote it.
private struct MCPProviderErrorText: View {
    let raw: String
    let providerName: String
    let color: Color

    @Environment(\.theme) private var inheritedTheme
    private var theme: any ThemeProtocol { inheritedTheme }
    @State private var showDetails = false

    var body: some View {
        let presentation = MCPProviderErrorPresenter.present(raw, providerName: providerName)
        VStack(alignment: .leading, spacing: 3) {
            Text(presentation.message)
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                .foregroundColor(color)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if let details = presentation.details {
                Button {
                    showDetails.toggle()
                } label: {
                    Text(showDetails ? "Hide details" : "Details", bundle: .module)
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.chip)
                        .foregroundColor(theme.text.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .pointingHandCursor()
                if showDetails {
                    Text(details)
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.monoSmall)
                        .foregroundColor(theme.text.tertiary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct ProviderCard: View {
    @Environment(\.theme) private var inheritedTheme
    private var theme: any ThemeProtocol { inheritedTheme }
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
        report.prioritizedDiagnostics
    }

    /// True while an auth/error line is rendered under the header, so the
    /// header's one-line summary (which says the same thing) is suppressed.
    private var showsAttentionLine: Bool {
        requiresAuth || (state?.lastError != nil && !isConnected)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            providerHeader

            // Auth-required prompt. Branched so OAuth providers get a Sign In
            // button (which kicks off the loopback flow) while bearer-token
            // providers get an inline secure field — pressing Sign In on a
            // bearer provider would silently convert it to OAuth, which is
            // almost never what the user wants.
            if requiresAuth {
                if provider.authType == .bearerToken
                    || (provider.authType == .none && state?.oauthAvailable != true)
                {
                    bearerTokenAuthBanner
                } else {
                    oauthAuthBanner
                }
            } else if let error = state?.lastError, !isConnected {
                // Error message (only when not already showing the sign-in CTA).
                // For the common "command not found on PATH" case we add an
                // inline "Edit" CTA so nvm/asdf users can jump straight to
                // the command field without hunting through the row.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: errorIcon(for: error))
                        .glyphSize(11)
                        .foregroundColor(theme.status.error.foreground)
                    MCPProviderErrorText(raw: error, providerName: provider.name, color: theme.status.error.foreground)
                    if isCommandNotFoundError(error) {
                        Spacer(minLength: 6)
                        SettingsButton(.secondary, "Edit", size: .compact, action: onEdit)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, theme.space.s16)
            }

            // Expanded content
            if isExpanded {
                Divider()
                    .padding(.vertical, theme.space.s2)

                expandedContent
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(hasAppeared ? 1 : 0)
        .onAppear {
            let delay = Double(animationIndex) * 0.03
            withAnimation(theme.motion.standard.delay(delay)) {
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

    private var providerHeader: some View {
        LibraryRow(
            title: provider.name,
            subtitle: headerSubtitle,
            action: {
                withAnimation(theme.motion.springAnimation) {
                    isExpanded.toggle()
                }
            }
        ) {
            SettingsChevron()
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 10)
        } badges: {
            StatusChip(statusLabel, tint: statusColor, showsDot: true)
            if provider.transport == .stdio {
                executionHostBadge
            }
        } trailing: {
            if isTesting {
                ProgressView().controlSize(.small)
            }
            connectionButton
            Toggle(
                "",
                isOn: Binding(
                    get: { provider.enabled },
                    set: { onToggleEnabled($0) }
                )
            )
            .settingsSwitch()
            .help(Text("Enable this service", bundle: .module))
        } menu: {
            Button(action: onTest) {
                Label {
                    Text("Test Connection", bundle: .module)
                } icon: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                }
            }
            .disabled(isTesting)

            Button(action: onCopyDiagnostics) {
                Label {
                    Text("Copy Diagnostics", bundle: .module)
                } icon: {
                    Image(systemName: "doc.on.doc")
                }
            }

            Button(action: onEdit) {
                Label {
                    Text("Edit", bundle: .module)
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
        }
    }

    /// Transport · endpoint · tool count, then the attention summary when no
    /// auth/error line is already saying it.
    private var headerSubtitle: String {
        var facts = [provider.transport == .http ? "HTTP" : "stdio", providerSubtitle]
        if let toolCount = state?.discoveredToolCount, toolCount > 0 {
            facts.append(toolCount == 1 ? L("1 tool") : L("\(toolCount) tools"))
        }
        var lines = [facts.joined(separator: " · ")]
        if report.hasAttention && !showsAttentionLine {
            lines.append(report.summary)
        }
        return lines.joined(separator: "\n")
    }

    private var connectionButton: some View {
        Group {
            if isConnecting {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 76, height: 24)
            } else if isConnected {
                SettingsButton(.destructive, "Disconnect", size: .compact, action: onDisconnect)
            } else {
                SettingsButton(.secondary, "Connect", size: .compact, action: onConnect)
                    .disabled(!provider.enabled)
            }
        }
    }

    private var statusColor: Color {
        if !provider.enabled {
            return theme.text.tertiary
        } else if isConnected {
            return theme.status.success.foreground
        } else if isConnecting {
            return theme.action.primary.default.background
        } else if state?.lastError != nil {
            return theme.status.error.foreground
        } else {
            return theme.text.secondary
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
    private var executionHostBadge: some View {
        let isHost = provider.executionHost == .host
        return StatusChip(
            isHost ? L("Host") : L("Sandbox"),
            tone: isHost ? .warning : .accent,
            icon: isHost ? "exclamationmark.shield.fill" : "shippingbox.fill"
        )
    }

    /// Status chip label, colored with `statusColor`.
    private var statusLabel: String {
        if !provider.enabled {
            return L("Disabled")
        } else if isConnected {
            return L("Connected")
        } else if state?.isAutoReconnecting == true {
            return L("Reconnecting…")
        } else if isConnecting {
            return L("Connecting...")
        } else if state?.lastError != nil {
            return L("Error")
        } else {
            return L("Not connected")
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
            .textStyle(.footnote)
            .foregroundColor(signInError == nil ? theme.status.warning.foreground : theme.status.error.foreground)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sign in required", bundle: .module)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                if let signInError {
                    MCPProviderErrorText(
                        raw: signInError,
                        providerName: provider.name,
                        color: theme.status.error.foreground
                    )
                } else {
                    Text("This server requires OAuth sign in to provide tools.", bundle: .module)
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                        .foregroundColor(theme.text.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            SettingsButton(.secondary, signInError == nil ? "Sign In" : "Retry", size: .compact, action: onSignIn)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, theme.space.s16)
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
                    .glyphSize(11)
                    .foregroundColor(theme.status.warning.foreground)
                VStack(alignment: .leading, spacing: 2) {
                    Text("API token required", bundle: .module)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)
                    if let lastError {
                        MCPProviderErrorText(
                            raw: lastError,
                            providerName: provider.name,
                            color: theme.status.error.foreground
                        )
                    } else {
                        Text(
                            "This server rejected the request as unauthorized. Paste an API token to retry.",
                            bundle: .module
                        )
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                        .foregroundColor(theme.text.secondary)
                        .lineLimit(3)
                    }
                }
                Spacer()
            }

            HStack(spacing: 8) {
                SettingsTextField(
                    placeholder: L("Paste API token here"),
                    text: $inlineBearerToken,
                    monospaced: true,
                    isSecure: true,
                    onSubmit: submitInlineBearerToken
                )

                SettingsButton(.secondary, "Save & Retry", size: .compact, action: submitInlineBearerToken)
                    .disabled(
                        inlineBearerToken.trimmingCharacters(in: .whitespaces).isEmpty
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, theme.space.s16)
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

            ProviderDiagnosticsRowsView(report: diagnosticsReport, maxRows: 3)
                .padding(.horizontal, -16)

            // Custom headers summary
            if !provider.customHeaders.isEmpty || !provider.secretHeaderKeys.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle")
                        .glyphSize(11)
                        .foregroundColor(theme.text.tertiary)
                    Text(
                        "\(provider.customHeaders.count + provider.secretHeaderKeys.count) custom header\(provider.customHeaders.count + provider.secretHeaderKeys.count == 1 ? "" : "s")",
                        bundle: .module
                    )
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                    .foregroundColor(theme.text.secondary)
                }
            }

            // Discovered tools list
            if isConnected, let tools = state?.discoveredToolSummaries, !tools.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Provides:", bundle: .module)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                        .foregroundColor(theme.text.secondary)

                    ToolPillsFlowLayout(spacing: 6) {
                        ForEach(tools) { tool in
                            StatusChip(
                                tool.displayName,
                                tone: tool.hints.isDestructive ? .warning : .neutral,
                                icon: toolPillIcon(tool.hints)
                            )
                                .help(toolPillHelp(tool))
                        }
                    }
                }
            }
        }
    }

    private func toolPillIcon(_ hints: MCPToolHints) -> String {
        if hints.isReadOnly { return "eye" }
        if hints.isDestructive { return "exclamationmark.triangle.fill" }
        return "function"
    }

    private func toolPillHelp(_ tool: MCPDiscoveredToolSummary) -> String {
        var lines = [tool.title == nil ? tool.name : "\(tool.displayName) (\(tool.name))"]
        if tool.hints.isReadOnly {
            lines.append(L("Server says this tool only reads data."))
        } else if tool.hints.isDestructive {
            lines.append(L("Server says this tool can modify or delete data."))
        }
        if tool.hints.openWorld == true {
            lines.append(L("Server says this tool reaches external services."))
        }
        return lines.joined(separator: "\n")
    }

    private func settingItem(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .glyphSize(10)
                .foregroundColor(theme.text.tertiary)
            Text("\(label):", bundle: .module)
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
            Text(value)
                .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                .foregroundColor(theme.text.secondary)
        }
    }
}

// MARK: - Provider Edit Sheet

struct ProviderEditSheet: View {
    private var theme: ThemeProtocol { themeManager.currentTheme }
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    let provider: MCPProvider?
    /// Add-mode prefill from a hand-off (e.g. the API provider form detected
    /// an MCP server URL). Skips the catalog and lands on the custom editor
    /// with URL/token filled in. Ignored in edit mode.
    var prefill: MCPProviderDraft? = nil
    /// Add-mode starting step. `.catalog` shows the directory first; the
    /// inline Directory on the Services tab passes the tapped service so the
    /// sheet opens straight on its setup. Ignored in edit mode or with a prefill.
    var start: MCPAddServiceStart = .catalog
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
    @State private var progressHardCap: Double = MCPProvider.defaultProgressHardCap
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

    @State private var phase: Phase

    /// Search/filter query for the catalog grid. Reset whenever the user
    /// returns to `.chooseProvider` so re-entering the catalog starts fresh.
    @State private var catalogQuery: String = ""

    /// The starting phase is decided here, not in `onAppear`, so a sheet
    /// opened from the inline Directory renders its service's setup on the
    /// very first frame instead of flashing the catalog and animating away.
    init(
        provider: MCPProvider?,
        prefill: MCPProviderDraft? = nil,
        start: MCPAddServiceStart = .catalog,
        onSave: @escaping (MCPProvider, String?) -> Void
    ) {
        self.provider = provider
        self.prefill = prefill
        self.start = start
        self.onSave = onSave

        let initialPhase: Phase
        if provider != nil || prefill != nil {
            initialPhase = .configureCustom
        } else {
            switch start {
            case .catalog:
                initialPhase = .chooseProvider
            case .template(let template):
                initialPhase = .configureKnown(template)
            case .custom:
                initialPhase = .configureCustom
            }
        }
        _phase = State(initialValue: initialPhase)

        // Seed the draft for template starts so the fields are populated on
        // the first frame too; `loadProvider` handles edit/prefill.
        if provider == nil, prefill == nil, case .template(let template) = start {
            _name = State(initialValue: template.displayName)
            _url = State(initialValue: template.url)
            _authType = State(initialValue: template.authType)
        }
    }

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
                    .padding(theme.space.s24)
            }

            sheetFooter
        }
        .fittedSheetFrame(width: 560, height: 660)
        .background(themeManager.currentTheme.surface.canvas)
        .clipShape(RoundedRectangle(cornerRadius: theme.radius.xlarge))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.xlarge)
                .stroke(themeManager.currentTheme.border.subtle, lineWidth: theme.stroke.default)
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
                "pencil",
                Text("Edit Service", bundle: .module),
                Text("Modify this MCP service", bundle: .module)
            )
        }
        switch phase {
        case .chooseProvider:
            return (
                "square.grid.2x2",
                Text("Add Service", bundle: .module),
                Text("Choose a service to connect", bundle: .module)
            )
        case .configureKnown(let template):
            return (
                template.iconSystemName,
                Text("Connect to \(template.displayName)", bundle: .module),
                Text(LocalizedStringKey(template.tagline), bundle: .module)
            )
        case .configureCustom:
            return (
                "slider.horizontal.3",
                Text("Custom Server", bundle: .module),
                Text("Connect to any MCP-compatible server", bundle: .module)
            )
        }
    }

    /// Flat header on the same surface as the content: small icon tile,
    /// title, one-line subtitle, close. No gradient band — the body below
    /// never repeats the service name.
    private var sheetHeader: some View {
        let info = headerInfo
        let theme = themeManager.currentTheme
        return HStack(spacing: 12) {
SettingsIconTile(icon: info.icon, size: 32)

            VStack(alignment: .leading, spacing: 2) {
                info.title
                    .textStyle(.heading)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)

                info.subtitle
                    .textStyle(.caption)
                    .foregroundColor(theme.text.secondary)
                    .lineLimit(1)
            }

            Spacer()

            SettingsIconButton("xmark", help: "Close", size: .compact, action: { dismiss() })
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, theme.space.s24)
        .padding(.top, theme.space.s16)
        .padding(.bottom, theme.space.s16)
        .background(theme.surface.canvas)
        .overlay(
            Rectangle()
                .fill(theme.border.subtle)
                .frame(height: 1),
            alignment: .bottom
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
        .padding(.horizontal, theme.space.s24)
        .padding(.vertical, theme.space.s16)
        .background(
            themeManager.currentTheme.surface.canvas
                .overlay(
                    Rectangle()
                        .fill(themeManager.currentTheme.border.subtle)
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
                        .glyphSize(11, weight: .semibold)
                    Text("Use a different service", bundle: .module)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                }
                .foregroundColor(themeManager.currentTheme.text.secondary)
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
                label: Text("Add Service", bundle: .module),
                enabled: canSaveKnown(template)
            )
        }
        if case .configureCustom = phase {
            primarySaveButton(
                label: Text(isEditing ? "Save" : "Add Service", bundle: .module),
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
        .assignedSettingsButtonStyle(.secondary)
    }

    private func primarySaveButton(label: Text, enabled: Bool) -> some View {
        Button(action: save) { label }
            .assignedSettingsButtonStyle(.primary)
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
                                .glyphSize(12)
                        case .failure:
                            Image(systemName: "xmark.circle.fill")
                                .glyphSize(12)
                        }
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .glyphSize(12)
                    }
                }
                .frame(width: 16, height: 16)

                if let result = testResult {
                    switch result {
                    case .success(let probe):
                        Text(
                            probe.toolCount == 1
                                ? L("Connected! (1 tool)")
                                : L("Connected! (\(probe.toolCount) tools)")
                        )
                            .textStyle(.caption, weight: 500)
                    case .failure(let probe):
                        Text("Failed - \(probe.reasonCode.rawValue)", bundle: .module)
                            .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                    }
                } else {
                    Text("Test", bundle: .module)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                }
            }
        }
        .assignedSettingsButtonStyle(.secondary, size: .compact)
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
        toolCallTimeout = 45
        progressHardCap = MCPProvider.defaultProgressHardCap
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
        withAnimation(theme.motion.springAnimation) {
            phase = newPhase
        }
    }

    // MARK: - Catalog Grid (Phase 1)

    private var catalogGridBody: some View {
        MCPProviderDirectoryView(
            query: $catalogQuery,
            onSelectTemplate: selectTemplate,
            onSelectCustom: selectCustomServer
        )
    }

    private func selectTemplate(_ template: MCPProviderTemplate) {
        // OAuth and bearer-token templates both go to .configureKnown — the screen
        // branches on template.authType for the correct sign-in vs. API-key UI.
        clearDraft(authType: template.authType, name: template.displayName, url: template.url)
        toolCallTimeout = template.defaultToolCallTimeout
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
            Spacer(minLength: 24)

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

                if template.requiresSubscription {
                    Text("\(template.displayName) needs a paid account or subscription.", bundle: .module)
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                        .foregroundColor(themeManager.currentTheme.text.tertiary)
                        .multilineTextAlignment(.center)
                }

                if let error = oauthError, template.authType == .oauth {
                    Text(error)
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                        .foregroundColor(themeManager.currentTheme.status.error.foreground)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .padding(.horizontal, theme.space.s8)
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
            .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
            .foregroundColor(themeManager.currentTheme.text.tertiary)
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
                }
                Group {
                    if isSigningIn {
                        Text("Waiting for browser…", bundle: .module)
                    } else {
                        Text("Sign In with \(template.displayName)", bundle: .module)
                    }
                }
            }
        }
        .assignedSettingsButtonStyle(.primary)
        .disabled(isSigningIn || !enabled)
    }

    @ViewBuilder
    private func connectedBlock(template: MCPProviderTemplate) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .glyphSize(18)
                    .foregroundColor(themeManager.currentTheme.status.success.foreground)
                Text("Connected to \(template.displayName)", bundle: .module)
                    .catalogTypography(.heading, theme: theme, fallback: SettingsFont.cardTitle)
                    .foregroundColor(themeManager.currentTheme.text.primary)
            }
            .padding(.horizontal, theme.space.s16)
            .padding(.vertical, theme.space.s8)
            .settingsChrome(.status(.success))

            if let scopes = oauthConfig?.scopes, !scopes.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "key.fill")
                        .glyphSize(9)
                    Text(scopes.joined(separator: " "))
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.monoSmall)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .foregroundColor(themeManager.currentTheme.text.tertiary)
                .frame(maxWidth: 360)
            }

            Button(action: signInWithOAuth) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .glyphSize(11)
                    Text("Re-authenticate", bundle: .module)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                }
                .foregroundColor(themeManager.currentTheme.text.secondary)
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
                            .glyphSize(11)
                        Text("Open \(template.displayName) docs", bundle: .module)
                            .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                    }
                    .foregroundColor(themeManager.currentTheme.text.link)
                }
                .buttonStyle(PlainButtonStyle())
            }

            VStack(spacing: 10) {
                SettingsFieldRow(label: "Client ID") {
                    SettingsTextField(placeholder: L("Paste the Client ID"), text: $manualClientId, monospaced: true)
                }
                SettingsFieldRow(label: "Client Secret") {
                    SettingsTextField(placeholder: L("Paste the Client Secret"), text: $manualClientSecret, monospaced: true, isSecure: true)
                }
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
            .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
            .foregroundColor(themeManager.currentTheme.text.tertiary)
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
        .padding(theme.space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.inset)
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.medium)
                .stroke(themeManager.currentTheme.border.subtle, lineWidth: theme.stroke.default)
        )
    }

    /// One numbered row in the confidential-OAuth setup card. Mirrors the
    /// "Where do I get my key?" tone but with explicit ordering since the
    /// steps are ordering-sensitive (URI must be registered before sign-in).
    @ViewBuilder
    private func confidentialOAuthStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.monoSmall)
                .foregroundColor(themeManager.currentTheme.text.tertiary)
                .frame(width: 18, alignment: .trailing)
            Text(text)
                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                .foregroundColor(themeManager.currentTheme.text.secondary)
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
                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.monoSmall)
                .foregroundColor(themeManager.currentTheme.text.primary)
                .padding(.horizontal, theme.space.s8)
                .padding(.vertical, theme.space.s6)
                .settingsChrome(.control)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)

            Button(action: { copyToPasteboard(uri) }) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.doc")
                        .glyphSize(11)
                    Text("Copy", bundle: .module)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                }
                .foregroundColor(themeManager.currentTheme.text.link)
                .padding(.horizontal, theme.space.s8)
                .padding(.vertical, theme.space.s6)
                .settingsChrome(.selected)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.leading, theme.space.s24)
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
            SettingsFieldRow(label: "API Key") {
                SettingsTextField(placeholder: L("Paste your API key"), text: $token, monospaced: true, isSecure: true)
            }
            .frame(maxWidth: 420)

            if let helpURL = template.apiKeyHelpURL {
                Button(action: { NSWorkspace.shared.open(helpURL) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "link.circle.fill")
                            .glyphSize(11)
                        Text("Where do I get my key?", bundle: .module)
                            .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                    }
                    .foregroundColor(themeManager.currentTheme.text.link)
                }
                .buttonStyle(PlainButtonStyle())
            }

            Text(
                "Your API key is stored in your macOS Keychain and only sent to \(template.displayName).",
                bundle: .module
            )
            .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
            .foregroundColor(themeManager.currentTheme.text.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
        }
    }

    @ViewBuilder
    private func noAuthBlock(template: MCPProviderTemplate) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.open.fill")
                .glyphSize(13)
                .foregroundColor(themeManager.currentTheme.status.success.foreground)
            Text("This server doesn't require authentication.", bundle: .module)
                .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                .foregroundColor(themeManager.currentTheme.text.primary)
        }
        .padding(.horizontal, theme.space.s16)
        .padding(.vertical, theme.space.s8)
        .settingsChrome(.status(.success))
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
            SettingsSection(title: "Connection") {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsFieldRow(label: "Name") {
                        SettingsTextField(placeholder: L("My MCP Server"), text: $name)
                    }

                    transportPicker

                    switch transport {
                    case .http:
                        SettingsFieldRow(label: "URL") {
                            SettingsTextField(placeholder: "https://mcp.example.com", text: $url, monospaced: true)
                        }

                        authTypePicker

                        switch authType {
                        case .none:
                            EmptyView()
                        case .bearerToken:
                            SettingsFieldRow(label: "Bearer Token") {
                                SettingsTextField(placeholder: L("Optional - stored securely in Keychain"), text: $token, monospaced: true, isSecure: true)
                            }
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
        SettingsSection(
            title: result.succeeded ? "Probe Passed" : "Probe Failed"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    probeChip(title: "Reason", value: result.reasonCode.rawValue)
                    probeChip(title: "Stage", value: result.stage.rawValue)
                    probeChip(title: "Tools", value: "\(result.toolCount)")
                }

                Text(result.redactedMessage)
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                    .foregroundColor(themeManager.currentTheme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let action = result.redactedAction {
                    Text(action)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                        .foregroundColor(themeManager.currentTheme.text.link)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: { copyProbeResult(result) }) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.doc")
                            .glyphSize(11, weight: .semibold)
                        Text("Copy Probe Result", bundle: .module)
                            .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                    }
                    .foregroundColor(themeManager.currentTheme.text.link)
                }
                .buttonStyle(PlainButtonStyle())
                .localizedHelp("Copy")
            }
        }
    }

    private func probeChip(title: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(LocalizedStringKey(title), bundle: .module)
                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.chip)
                .foregroundColor(themeManager.currentTheme.text.tertiary)
            Text(value)
                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.monoSmall)
                .foregroundColor(themeManager.currentTheme.text.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, theme.space.s8)
        .padding(.vertical, theme.space.s4)
        .settingsChrome(.inset)
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
        SettingsSection(title: title) {
            SettingsButton(.secondary, addLabel, icon: "plus", size: .compact) {
                entries.wrappedValue.append(HeaderEntry(key: "", value: "", isSecret: false))
            }
        } content: {
            if entries.wrappedValue.isEmpty {
                SettingsEmptyState(inline: icon, title: emptyLabel)
            } else {
                ForEach(entries) { $entry in
                    HeaderRow(header: $entry) {
                        entries.wrappedValue.removeAll { $0.id == entry.id }
                    }
                }
            }
        }
    }

    /// Stdio-only Connection-card fields: where to run, the command, args,
    /// and an optional working directory. The env-var card lives outside
    /// this view because it has a different layout (a list of rows).
    @ViewBuilder
    private var stdioFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            executionHostPicker

            executionHostExplainer

            SettingsFieldRow(label: "Command") {
                SettingsTextField(placeholder: L("/usr/local/bin/uvx or npx"), text: $command, monospaced: true)
            }

            SettingsFieldRow(label: "Arguments") {
                SettingsTextField(placeholder: L("e.g. -y @scope/server --root '/path with spaces'"), text: $argsString, monospaced: true)
            }

            SettingsFieldRow(label: "Working Directory") {
                SettingsTextField(placeholder: L("Optional, e.g. /Users/me/projects/my-mcp"), text: $workingDirectory, monospaced: true)
            }
        }
    }

    private var transportPicker: some View {
        SettingsFieldRow(label: "Transport") {
            AssignedBaseSegmentedPicker(
                selection: $transport,
                options: [.init(MCPProviderTransport.http, "HTTP / SSE"), .init(MCPProviderTransport.stdio, "Stdio")]
            )
            .fixedSize()
            .accessibilityLabel(Text("Transport", bundle: .module))
        }
    }

    private var executionHostPicker: some View {
        SettingsFieldRow(label: "Run In") {
            AssignedBaseSegmentedPicker(
                selection: $executionHost,
                options: [.init(MCPProviderExecutionHost.sandbox, "Sandbox"), .init(MCPProviderExecutionHost.host, "Host")]
            )
            .fixedSize()
            .accessibilityLabel(Text("Run In", bundle: .module))
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
            // Seatbelt backend: sandboxed stdio doesn't exist (no VM
            // interactive exec bridge), so a provider left on Sandbox
            // will fail to start. Warn at selection time — the same
            // guidance the connect-time error gives.
            if SandboxBackend.current == .seatbelt {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .glyphSize(12, weight: .semibold)
                        .foregroundColor(theme.status.warning.foreground)
                    Text(
                        "Sandboxed MCP servers require macOS 26 or later and will fail to start on this Mac. Choose Host to run this provider — note it will then run without sandbox protection.",
                        bundle: .module
                    )
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(themeManager.currentTheme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(theme.space.s8)
                .settingsChrome(.status(.warning))
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "shippingbox.fill")
                        .glyphSize(12, weight: .semibold)
                        .foregroundColor(themeManager.currentTheme.text.link)
                    Text(
                        "Runs in an isolated Linux VM with no access to host files or credentials. Outbound network is on by default and can be turned off per agent in the agent's Sandbox settings.",
                        bundle: .module
                    )
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(themeManager.currentTheme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(theme.space.s8)
                .settingsChrome(.selected)
            }

        case .host:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .glyphSize(12, weight: .semibold)
                    .foregroundColor(theme.status.warning.foreground)
                Text(
                    "Running on the host means this subprocess can access your files, network, and credentials. Only use Host for tools you trust.",
                    bundle: .module
                )
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                .foregroundColor(themeManager.currentTheme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(theme.space.s8)
            .settingsChrome(.status(.warning))
        }
    }

    /// Streaming / auto-connect / timeout sliders. Shared between the HTTP
    /// and stdio editor flows so the user gets the same advanced surface
    /// regardless of transport.
    private var advancedCard: some View {
        SettingsSection(title: "Advanced") {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: {
                    withAnimation(theme.motion.springAnimation) {
                        showAdvanced.toggle()
                    }
                }) {
                    HStack {
                        Text(showAdvanced ? L("Hide advanced settings") : L("Show advanced settings"))
                            .catalogTypography(.body, theme: theme, fallback: SettingsFont.body)
                            .foregroundColor(themeManager.currentTheme.text.link)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .glyphSize(11, weight: .semibold)
                            .foregroundColor(themeManager.currentTheme.text.tertiary)
                            .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())

                if showAdvanced {
                    VStack(alignment: .leading, spacing: 16) {
                        Divider().padding(.vertical, theme.space.s8)

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

                        Divider().padding(.vertical, theme.space.s4)

                        VStack(alignment: .leading, spacing: 16) {
                            SettingsSlider(
                                title: "Discovery Timeout",
                                valueText: "\(Int(discoveryTimeout))s",
                                value: $discoveryTimeout,
                                range: 5 ... 60,
                                step: 5
                            )

                            SettingsSlider(
                                title: "Tool Call Timeout",
                                valueText: "\(Int(toolCallTimeout))s",
                                value: $toolCallTimeout,
                                range: 10 ... 120,
                                step: 5
                            )

                            SettingsSlider(
                                title: "Max Duration with Progress",
                                valueText: progressHardCapLabel,
                                description:
                                    "Calls that keep reporting progress can run this long. The timeout above is the longest gap between updates.",
                                value: $progressHardCap,
                                range: MCPProvider.progressHardCapRange,
                                step: 300
                            )
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    /// Minutes, with the hour form in parentheses past an hour so long caps
    /// stay readable ("90 min (1 h 30 min)").
    private var progressHardCapLabel: String {
        let minutes = Int(progressHardCap / 60)
        let hours = minutes / 60
        let remainder = minutes % 60
        if minutes <= 60 {
            return L("\(minutes) min")
        } else if remainder == 0 {
            return L("\(minutes) min (\(hours) h)")
        } else {
            return L("\(minutes) min (\(hours) h \(remainder) min)")
        }
    }

    @ViewBuilder
    private var authTypePicker: some View {
        SettingsFieldRow(label: "Authentication") {
            AssignedBaseSegmentedPicker(
                selection: $authType,
                options: [
                    .init(MCPProviderAuthType.none, "None"), .init(MCPProviderAuthType.bearerToken, "Bearer Token"),
                    .init(MCPProviderAuthType.oauth, "OAuth"),
                ]
            )
            .fixedSize()
            .accessibilityLabel(Text("Authentication", bundle: .module))
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
                    .glyphSize(11)
                    .foregroundColor(themeManager.currentTheme.text.tertiary)
                Text("Sign in via the server's OAuth login flow", bundle: .module)
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                    .foregroundColor(themeManager.currentTheme.text.secondary)
            }

            HStack(spacing: 10) {
                Button(action: signInWithOAuth) {
                    HStack(spacing: 6) {
                        if isSigningIn {
                            ProgressView().scaleEffect(0.6)
                        } else {
                            Image(systemName: isOAuthSignedIn ? "arrow.clockwise" : "person.badge.key")
                                .glyphSize(12)
                        }
                        Text(
                            LocalizedStringKey(isOAuthSignedIn ? "Re-authenticate" : "Sign In"),
                            bundle: .module
                        )
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                    }
                }
                .assignedSettingsButtonStyle(.primary)
                .disabled(isSigningIn || url.trimmingCharacters(in: .whitespaces).isEmpty)

                if isOAuthSignedIn {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .glyphSize(11)
                            .foregroundColor(themeManager.currentTheme.status.success.foreground)
                        Text("Signed in", bundle: .module)
                            .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                            .foregroundColor(themeManager.currentTheme.status.success.foreground)
                    }
                }

                Spacer()
            }

            if let error = oauthError {
                Text(error)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(themeManager.currentTheme.status.error.foreground)
                    .lineLimit(3)
            }

            if let config = oauthConfig, !config.scopes.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "key.fill")
                        .glyphSize(9)
                        .foregroundColor(themeManager.currentTheme.text.tertiary)
                    Text(config.scopes.joined(separator: " "))
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.monoSmall)
                        .foregroundColor(themeManager.currentTheme.text.tertiary)
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
                withAnimation(theme.motion.quick) { showOAuthAdvanced.toggle() }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .glyphSize(9, weight: .semibold)
                        .foregroundColor(themeManager.currentTheme.text.tertiary)
                        .rotationEffect(.degrees(showOAuthAdvanced ? 90 : 0))
                    Text("Manual endpoints (advanced)", bundle: .module)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                        .foregroundColor(themeManager.currentTheme.text.secondary)
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
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                    .foregroundColor(themeManager.currentTheme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                    SettingsFieldRow(label: "Authorize URL") {
                        SettingsTextField(placeholder: "https://auth.example.com/oauth/authorize", text: $manualAuthEndpoint, monospaced: true)
                    }
                    SettingsFieldRow(label: "Token URL") {
                        SettingsTextField(placeholder: "https://auth.example.com/oauth/token", text: $manualTokenEndpoint, monospaced: true)
                    }
                    SettingsFieldRow(label: "Client ID") {
                        SettingsTextField(placeholder: L("Pre-registered OAuth client id (leave blank for DCR)"), text: $manualClientId, monospaced: true)
                    }
                    SettingsFieldRow(label: "Scopes") {
                        SettingsTextField(placeholder: L("space- or comma-separated, e.g. read write offline_access"), text: $manualScopes)
                    }
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
        guard let result = testResult else { return themeManager.currentTheme.text.secondary }
        switch result {
        case .success: return themeManager.currentTheme.status.success.foreground
        case .failure: return themeManager.currentTheme.status.error.foreground
        }
    }

    private var testResultBackground: Color {
        guard let result = testResult else { return themeManager.currentTheme.surface.hover }
        switch result {
        case .success: return themeManager.currentTheme.status.success.background
        case .failure: return themeManager.currentTheme.status.error.background
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
            if let prefill {
                // Hand-off from the API provider form: skip the catalog and
                // land on the custom editor with the detected MCP endpoint.
                phase = .configureCustom
                name = prefill.name
                url = prefill.url
                token = prefill.bearerToken ?? ""
                authType = prefill.authType
                transport = prefill.transport
                command = prefill.command
                argsString = ShellArgs.join(prefill.args)
                workingDirectory = prefill.workingDirectory
                // Values never travel with a draft; the names are kept as
                // secrets so what the user types lands in the Keychain.
                envEntries = prefill.envKeys.map { HeaderEntry(key: $0, value: "", isSecret: true) }
                customHeaders = prefill.headerKeys.map { HeaderEntry(key: $0, value: "", isSecret: true) }
                return
            }
            // Add-mode. `init` already seeded `phase` and the draft fields.
            // The draftId is preserved so anything OAuth-saved mid-flow ends
            // up on this id and persists through save().
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
        progressHardCap = provider.progressHardCap
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
            let probeProvider = makeProbeProvider()
            let result: MCPProviderProbeResult
            switch transport {
            case .http:
                result = await MCPProviderProbeService.probeHTTP(
                    providerId: probeProvider.id,
                    name: probeProvider.name,
                    url: probeProvider.url,
                    token: httpTestToken(),
                    headers: buildHeaders(),
                    streamingEnabled: probeProvider.streamingEnabled,
                    discoveryTimeout: probeProvider.discoveryTimeout
                )
            case .stdio:
                result = await MCPProviderProbeService.probeStdio(provider: probeProvider)
            }
            MCPProviderHealthSnapshotStore.record(result, for: probeProvider)

            let shouldRefresh = MCPProviderCatalogRefreshPolicy.shouldRefresh(
                savedProvider: provider,
                configuredProvider: makeConfiguredProvider(),
                hasCredentialEdits: hasCredentialEdits
            )
            if result.succeeded, shouldRefresh, let provider {
                try? await MCPProviderManager.shared.reconnect(providerId: provider.id)
            }

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

    /// Whether the editor contains a secret value that is not represented in
    /// the persisted provider struct yet. Even if all visible non-secret
    /// fields match, testing with one of these values must remain probe-only.
    private var hasCredentialEdits: Bool {
        !token.isEmpty
            || !manualClientSecret.isEmpty
            || customHeaders.contains { $0.isSecret && !$0.value.isEmpty }
            || envEntries.contains { $0.isSecret && !$0.value.isEmpty }
    }

    /// Build the exact provider record Save would persist, without writing
    /// credentials or dismissing the sheet. Shared with the test-refresh
    /// eligibility check so draft detection cannot drift from Save.
    private func makeConfiguredProvider() -> MCPProvider {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)

        var regularHeaders: [String: String] = [:]
        var secretKeys: [String] = []
        for header in customHeaders where !header.key.isEmpty {
            if header.isSecret {
                secretKeys.append(header.key)
            } else {
                regularHeaders[header.key] = header.value
            }
        }

        let oauthForSave: MCPOAuthConfig? =
            authType == .oauth ? mergedManualOAuthConfig() : nil
        let stdio = parseStdioFields()

        return MCPProvider(
            id: effectiveProviderId,
            name: trimmedName,
            url: trimmedURL,
            enabled: provider?.enabled ?? true,
            customHeaders: regularHeaders,
            streamingEnabled: streamingEnabled,
            discoveryTimeout: discoveryTimeout,
            toolCallTimeout: toolCallTimeout,
            progressHardCap: progressHardCap,
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
    }

    private func save() {
        let updatedProvider = makeConfiguredProvider()

        // Save secret env values to Keychain. Like the bearer/secret-header
        // path, blank values mean "don't overwrite" so the user can leave
        // sensitive fields alone after the first save.
        for entry in envEntries
        where entry.isSecret && !entry.key.isEmpty && !entry.value.isEmpty {
            if !MCPCredentials.saveEnv(entry.value, provider: updatedProvider, name: entry.key) {
                NSLog("ProvidersView: failed to save secret env value to Keys")
            }
        }

        // Save secret header values to Keys
        for header in customHeaders where header.isSecret && !header.key.isEmpty && !header.value.isEmpty {
            if !MCPCredentials.saveHeader(header.value, provider: updatedProvider, header: header.key) {
                NSLog("ProvidersView: failed to save secret header to Keys")
            }
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

// MARK: - Header Row

private struct HeaderRow: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: any ThemeProtocol { themeManager.currentTheme }
    @Binding var header: ProviderEditSheet.HeaderEntry
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            SettingsTextField(placeholder: L("Key"), text: $header.key, monospaced: true)
                .frame(width: 120)

            SettingsTextField(
                placeholder: header.isSecret ? L("Secret value") : L("Value"),
                text: $header.value,
                monospaced: true,
                isSecure: header.isSecret
            )

            // Secret toggle
            Button(action: { header.isSecret.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: header.isSecret ? "lock.fill" : "lock.open")
                        .glyphSize(10)
                    Text(LocalizedStringKey(header.isSecret ? "Secret" : "Plain"), bundle: .module)
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.chip)
                }
                .foregroundColor(
                    header.isSecret
                        ? theme.action.primary.default.background
                        : theme.text.tertiary
                )
                .padding(.horizontal, theme.space.s8)
                .padding(.vertical, theme.space.s6)
                .settingsChrome(header.isSecret ? .selected : .inset)
            }
            .buttonStyle(PlainButtonStyle())

            // Delete button
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .glyphSize(11)
                    .foregroundColor(theme.status.error.foreground)
                    .frame(width: 28, height: 28)
                    .settingsChrome(.status(.error))
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
}

// MARK: - Styled Components

private struct MCPToggleRow: View {
    let title: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, description: description) {
            Toggle("", isOn: $isOn)
                .settingsSwitch()
        }
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
            .environment(\.theme, CustomizableTheme.dark())
    }
#endif
