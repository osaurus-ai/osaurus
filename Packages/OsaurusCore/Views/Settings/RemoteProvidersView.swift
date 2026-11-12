//
//  RemoteProvidersView.swift
//  osaurus
//
//  View for managing remote API providers (OpenAI, Anthropic, etc.).
//

import AppKit
import SwiftUI

struct RemoteProvidersView: View {
    @ObservedObject private var badgeStore = ManagementBadgeStore.shared
    @ObservedObject private var manager = RemoteProviderManager.shared
    @ObservedObject private var themeManager = ThemeManager.shared

    /// Use computed property to always get the current theme from ThemeManager
    private var theme: any ThemeProtocol { themeManager.currentTheme }

    @State private var addSheetConfig: AddSheetConfig?
    @State private var editingProvider: RemoteProvider?
    @State private var showReorderSheet = false
    @State private var hasAppeared = false
    @State private var providerFilter: ProviderConnectivityFilter = .all
    @State private var selectedIssueKind: ProviderConnectivityIssueKind?
    @State private var credentialPresence: [UUID: RemoteProviderCredentialPresence] = [:]
    @State private var reconnectingAll = false
    @State private var reconnectingProviderIds: Set<UUID> = []
    /// Mirrors the sidebar's Developer Tools switch; gates the connectivity
    /// summary card.
    @State private var showDeveloperDetail = SidebarSectionExpansion.isDeveloperToolsOn

    private struct AddSheetConfig: Identifiable {
        let id = UUID()
        let preset: ProviderPreset?
        /// Open the add sheet directly on the grouped "Use an API key" sub-list
        /// (only meaningful when `preset` is nil).
        var startAtAPIKeyPicker: Bool = false
    }

    var body: some View {
        VStack(spacing: theme.space.s0) {
            // Header
            headerView
                .settingsHeaderEntrance(hasAppeared: hasAppeared)

            // Content
            ScrollView {
                SettingsPageContent {
                    if userConfiguredProviders.isEmpty {
                        emptyStateView
                    } else {
                        // The connectivity summary card is developer-grade
                        // detail; it rides the Developer Tools switch so the
                        // everyday page is just the provider list.
                        if showDeveloperDetail {
                            connectivityCenterView
                        }
                        providerListView
                    }
                }
            }
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.canvas)
        .environment(\.theme, theme)
        .onAppear {
            withAnimation(theme.motion.standard.delay(0.05)) {
                hasAppeared = true
            }
            refreshCredentialPresence()
        }
        .onReceive(NotificationCenter.default.publisher(for: SidebarSectionExpansion.changed)) { _ in
            withAnimation(theme.motion.quick) {
                showDeveloperDetail = SidebarSectionExpansion.isDeveloperToolsOn
            }
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
        // The connectivity states (All / Attention / Connected / Disabled)
        // are a status filter, not content categories, so they live behind a
        // funnel filter button in the header actions rather than a tab bar.
        SettingsPageHeader(
            title: "Providers",
            subtitle: subtitleText,
            count: badgeStore.headerCount(for: .providers),
            utilities: {
                if !userConfiguredProviders.isEmpty {
                    ConnectivityFilterButton(
                        selection: $providerFilter,
                        count: { connectivitySnapshot.filtered(by: $0, issueKind: nil).count }
                    )
                }
                if userConfiguredProviders.count > 1 {
                    SettingsIconButton("list.bullet.indent", help: "Reorder providers") {
                        showReorderSheet = true
                    }
                }
            },
            primary: {
                SettingsButton(.primary, "Add Provider", icon: "plus") {
                    addSheetConfig = AddSheetConfig(preset: nil)
                }
            }
        )
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
            // Count only the providers this list shows, so paired agents with
            // no shared models (and the managed router) don't inflate the total.
            let modelCount = manager.providerStates
                .filter { userProviderIds.contains($0.key) }
                .values
                .reduce(0) { $0 + $1.modelCount }
            return L("\(connectedCount) connected • \(modelCount) model\(modelCount == 1 ? "" : "s") available")
        }
    }

    // MARK: - Empty State

    private func presentAddSheet(for preset: ProviderPreset) {
        addSheetConfig = AddSheetConfig(preset: preset)
    }

    /// Everything the user manages here: no managed router, and no paired
    /// Osaurus agents whose owner has not shared their models for inference
    /// (they answer `/models` with an empty catalog). Those agents stay
    /// reachable for chat/delegation from the Workspaces tab, the Agents tab,
    /// and the chat sidebar.
    private var userConfiguredProviders: [RemoteProvider] {
        manager.configuration.providers.filter {
            $0.providerType != .osaurusRouter && manager.exposesModelsForInference($0)
        }
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
        connectivitySnapshot.filtered(
            by: providerFilter,
            issueKind: activeIssueKind
        )
    }

    private var activeIssueKind: ProviderConnectivityIssueKind? {
        switch providerFilter {
        case .all, .attention:
            guard let selectedIssueKind,
                connectivitySnapshot.issueKindCounts(for: providerFilter)[selectedIssueKind, default: 0] > 0
            else {
                return nil
            }
            return selectedIssueKind
        case .connected, .disabled:
            return nil
        }
    }

    private func presentAPIKeyPicker() {
        addSheetConfig = AddSheetConfig(preset: nil, startAtAPIKeyPicker: true)
    }

    private var emptyStateView: some View {
        SettingsEmptyState(
            icon: "cloud.fill",
            title: "No Remote Providers",
            subtitle: "Connect a provider to access remote models.",
            content: AnyView(quickAddProviders),
            compact: true,
            footnote: L("Your API keys are stored securely in Keychain.")
        )
        .frame(minHeight: 400)
    }

    /// Quick-add: OAuth providers first-class, everything else behind a
    /// single "Use an API key" entry (mirrors the add-sheet picker).
    private var quickAddProviders: some View {
        SettingsGroup {
            ForEach(ProviderCatalog.topLevel) { entry in
                ProviderRowCard(entry: entry) {
                    presentAddSheet(for: entry.preset)
                }
            }

            ProviderRowCard(
                icon: "key.fill",
                title: "Use an API Key",
                subtitle: "Anthropic, Google, Ollama, custom, and more"
            ) {
                presentAPIKeyPicker()
            }
        }
        .frame(maxWidth: 540)
    }

    // MARK: - Provider List

    private var connectivityCenterView: some View {
        ProviderConnectivityCenterPanel(
            snapshot: connectivitySnapshot,
            statusFilter: providerFilter,
            selectedIssueKind: activeIssueKind,
            isReconnecting: reconnectingAll,
            onReconnectAll: reconnectAllProviders,
            onCopyReport: copyConnectivityReport,
            onSelectIssueKind: { selectedIssueKind = $0 }
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
            SettingsGroup {
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
        SettingsEmptyState(
            inline: "line.3.horizontal.decrease.circle",
            title: "Nothing to show here",
            hint: "No providers match this filter."
        )
        .padding(.vertical, theme.settingsSectionGap)
    }

    private func refreshCredentialPresence() {
        let providers = userConfiguredProviders
        let previous = credentialPresence
        Task {
            var next: [UUID: RemoteProviderCredentialPresence] = [:]
            for provider in providers {
                let providerID = provider.id
                let previousPresence = previous[providerID]
                // Typed availability: a transiently unavailable keychain
                // (locked, interaction required) keeps the previous known
                // presence instead of flashing a false "missing key" warning.
                let presence = await RemoteProviderKeychain.runOffCooperativeExecutor {
                    RemoteProviderCredentialPresence(
                        apiKeyPresent: RemoteProviderKeychain.apiKeyAvailability(for: providerID)
                            .presenceForUI(previous: previousPresence?.apiKeyPresent),
                        oauthTokensPresent: RemoteProviderKeychain.oauthTokensAvailability(
                            for: providerID
                        )
                        .presenceForUI(previous: previousPresence?.oauthTokensPresent)
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
        if activeIssueKind != nil {
            copyText(connectivitySnapshot.groupedPasteboardText(issueKind: activeIssueKind))
        } else {
            copyText(connectivitySnapshot.pasteboardText)
        }
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
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }

    let snapshot: ProviderConnectivitySnapshot
    let statusFilter: ProviderConnectivityFilter
    let selectedIssueKind: ProviderConnectivityIssueKind?
    let isReconnecting: Bool
    let onReconnectAll: () -> Void
    let onCopyReport: () -> Void
    let onSelectIssueKind: (ProviderConnectivityIssueKind?) -> Void

    var body: some View {
        SettingsSection(title: "Provider Connectivity", caption: summaryText, layout: .plain) {
            StatusChip(severityLabel, tint: statusColor, icon: iconName)
            SettingsButton(
                .secondary,
                "Reconnect all",
                icon: "arrow.clockwise",
                isLoading: isReconnecting,
                size: .compact,
                action: onReconnectAll
            )
            .disabled(isReconnecting || snapshot.enabledCount == 0)
            SettingsIconButton("doc.on.doc", help: "Copy diagnostics", size: .compact, action: onCopyReport)
        } content: {
            SettingsStatStrip(stats: [
                SettingsStat(label: "Connected", value: "\(snapshot.connectedCount)"),
                SettingsStat(label: "Attention", value: "\(snapshot.attentionCount)"),
                SettingsStat(label: "Models", value: "\(snapshot.modelCount)"),
                SettingsStat(label: "Manual models", value: "\(snapshot.manualModelProviderCount)"),
            ])

            if showsIssueFilters {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: theme.settingsControlGap) {
                        FilterChip(
                            L("All"),
                            count: snapshot.issueReportCount(for: statusFilter),
                            isSelected: selectedIssueKind == nil,
                            tint: theme.status.warning.foreground
                        ) {
                            onSelectIssueKind(nil)
                        }
                        ForEach(snapshot.sortedIssueKinds(for: statusFilter)) { kind in
                            FilterChip(
                                kind.displayName,
                                count: snapshot.issueKindCounts(for: statusFilter)[kind, default: 0],
                                isSelected: selectedIssueKind == kind,
                                tint: issueColor(kind)
                            ) {
                                onSelectIssueKind(kind)
                            }
                        }
                    }
                    .padding(.vertical, theme.space.s2)
                }
            }
        }
    }

    private var severityLabel: String {
        switch snapshot.highestSeverity {
        case .ok: return L("Healthy")
        case .info: return L("Info")
        case .warning: return L("Needs attention")
        case .blocked: return L("Blocked")
        }
    }

    private var statusColor: Color {
        switch snapshot.highestSeverity {
        case .ok:
            return theme.status.success.foreground
        case .info:
            return theme.status.info.foreground
        case .warning:
            return theme.status.warning.foreground
        case .blocked:
            return theme.status.error.foreground
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
        let modelLabel = snapshot.modelCount == 1 ? L("1 model") : L("\(snapshot.modelCount) models")
        return L(
            "\(snapshot.connectedCount)/\(snapshot.totalCount) connected - \(snapshot.attentionCount) attention - \(modelLabel)"
        )
    }

    private var showsIssueFilters: Bool {
        switch statusFilter {
        case .all, .attention:
            return !snapshot.issueKindCounts(for: statusFilter).isEmpty
        case .connected, .disabled:
            return false
        }
    }

    private func issueColor(_ kind: ProviderConnectivityIssueKind) -> Color {
        if kind == .authentication || kind == .oauthContext {
            return theme.status.error.foreground
        }
        if kind == .connection || kind == .requestEvidence || kind == .proxy || kind == .repro {
            return theme.status.warning.foreground
        }
        if kind == .models {
            return theme.action.primary.default.background
        }
        if kind == .format || kind == .transport {
            return theme.status.info.foreground
        }
        return theme.status.warning.foreground
    }
}

// MARK: - Provider Card View

private struct ProviderCardView: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    let report: ProviderConnectivityProviderReport
    let state: RemoteProviderState?
    let isReconnecting: Bool
    let onReconnect: () -> Void
    let onCopyDiagnostics: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggleEnabled: (Bool) -> Void

    @State private var showDeleteConfirm = false

    private var provider: RemoteProvider { report.provider }
    private var isConnected: Bool { state?.isConnected ?? false }
    private var isConnecting: Bool { state?.isConnecting ?? false }

    /// Match to a known preset for icon/color
    private var matchedPreset: ProviderPreset? {
        ProviderPreset.matching(provider: provider)
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

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            LibraryRow(title: provider.name, subtitle: subtitle) {
                ProviderIconTile(
                    preset: matchedPreset,
                    size: 36,
                    isActive: isConnected,
                    inactiveTint: statusColor
                )
            } badges: {
                statusBadge
                if let primaryIssueKind = report.primaryIssueKind,
                    provider.enabled,
                    report.hasAttention
                {
                    issueBadge(primaryIssueKind)
                }
                if provider.providerType == .osaurus {
                    // Osaurus peers talk through the Secure Channel —
                    // agent traffic is end-to-end encrypted or refused.
                    StatusChip(
                        L("E2E"),
                        tone: .success,
                        icon: "lock.fill",
                        help: L(
                            "Agent traffic is protected by the Osaurus Secure Channel: forward-secret, mutually authenticated end-to-end encryption."
                        )
                    )
                }
            } trailing: {
                SettingsIconButton(
                    "arrow.clockwise",
                    isLoading: isReconnecting || isConnecting,
                    help: "Reconnect",
                    action: onReconnect
                )
                .disabled(!provider.enabled || isReconnecting || isConnecting)

                Toggle(
                    "",
                    isOn: Binding(
                        get: { provider.enabled },
                        set: { onToggleEnabled($0) }
                    )
                )
                .settingsSwitch()
            } menu: {
                Button(L("Copy diagnostics"), action: onCopyDiagnostics)
                Button(L("Edit"), action: onEdit)
                Divider()
                Button(L("Delete"), role: .destructive) { showDeleteConfirm = true }
            }

            if let error = state?.lastError, !isConnected, !isConnecting {
                InlineBanner(kind: .error, title: error)
            }

            // Diagnostics only when the provider is enabled AND actually has a
            // problem (`isAttentionWorthy`), not for merely disabled rows —
            // a disabled provider's "connection disabled" warning is expected
            // state, and rendering its full diagnostics block just adds noise.
            if report.isAttentionWorthy {
                ProviderDiagnosticsRowsView(report: report.diagnostics, maxRows: 3)
            }
        }
        .themedAlert(
            L("Delete Provider?"),
            isPresented: $showDeleteConfirm,
            message: L("This will remove '\(provider.name)' and disconnect any active sessions."),
            primaryButton: .destructive(L("Delete")) { onDelete() },
            secondaryButton: .cancel(L("Cancel"))
        )
    }

    /// Endpoint, then model count or the attention summary.
    private var subtitle: String {
        var lines = [provider.displayEndpoint]
        if isConnected, let modelCount = state?.modelCount, modelCount > 0 {
            lines.append(L("\(modelCount) model\(modelCount == 1 ? "" : "s") available"))
        } else if report.hasAttention {
            lines.append(report.summary)
        }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private var statusBadge: some View {
        if !provider.enabled {
            StatusChip(L("Disabled"), tint: theme.text.tertiary)
        } else if isConnected {
            StatusChip(L("Connected"), tone: .success, showsDot: true)
        } else if isConnecting {
            StatusChip(L("Connecting..."), tone: .accent)
        } else if state?.lastError != nil {
            StatusChip(L("Error"), tone: .error)
        } else {
            StatusChip(L("Disconnected"), tint: theme.text.secondary)
        }
    }

    private func issueBadge(_ kind: ProviderConnectivityIssueKind) -> some View {
        StatusChip(kind.displayName, tint: issueColor(kind))
    }

    private func issueColor(_ kind: ProviderConnectivityIssueKind) -> Color {
        if kind == .authentication || kind == .oauthContext {
            return theme.status.error.foreground
        }
        if kind == .connection || kind == .requestEvidence || kind == .proxy || kind == .repro {
            return theme.status.warning.foreground
        }
        if kind == .models {
            return theme.action.primary.default.background
        }
        if kind == .format || kind == .transport {
            return theme.status.info.foreground
        }
        return theme.status.warning.foreground
    }
}

// MARK: - Connectivity Filter Button

/// Funnel button in the header actions that filters the provider list by
/// connectivity state. Uses the same themed-popover row idiom as the model
/// picker's sort menu; the button tints accent while a non-default filter is
/// active so a filtered list is visible at a glance.
private struct ConnectivityFilterButton: View {
    @Binding var selection: ProviderConnectivityFilter
    /// Provider count for one filter, shown as the row's trailing figure.
    let count: (ProviderConnectivityFilter) -> Int

    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    @State private var showPopover = false

    private var isActive: Bool { selection != .all }

    var body: some View {
        SettingsIconButton(
            "line.3.horizontal.decrease.circle",
            help: "Filter by connectivity",
            isActive: isActive
        ) {
            showPopover.toggle()
        }
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: theme.space.s4) {
                ForEach(ProviderConnectivityFilter.allCases, id: \.self) { filter in
                    FilterOptionRow(
                        title: filter.displayName,
                        badge: count(filter),
                        isSelected: filter == selection
                    ) {
                        selection = filter
                        showPopover = false
                    }
                }
            }
            .padding(.vertical, theme.space.s6)
            .frame(width: 200)
            .background(theme.surface.canvas)
            .environment(\.theme, theme)
        }
    }

    /// One popover filter row: title, provider count, checkmark when active.
    private struct FilterOptionRow: View {
        let title: String
        let badge: Int
        let isSelected: Bool
        let action: () -> Void
        @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: theme.space.s8) {
                    Text(title)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                        .foregroundColor(isSelected ? theme.text.link : theme.text.primary)
                    Spacer(minLength: 0)
                    CountBadge(badge)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .glyphSize(.micro, weight: .bold)
                            .foregroundColor(theme.text.link)
                    }
                }
                .padding(.horizontal, theme.space.s12)
                .padding(.vertical, theme.space.s8)
                .settingsChrome(isSelected ? .selected : (isHovering ? .hover : nil), radius: theme.radius.small)
                .padding(.horizontal, theme.space.s6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(theme.motion.quick) {
                    isHovering = hovering
                }
            }
    }
    }
}

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        RemoteProvidersView()
            .environment(\.theme, CustomizableTheme.dark())
    }
#endif

#if OSAURUS_DESIGN_INSPECTOR
/// Original provider cards driven by local report/state values. Callbacks only
/// update local text; no provider manager, keychain or network operation is used.
struct InspectorProviderStatesVerification: View {
    @Environment(\.theme) private var theme
    @State private var mode = "Connected"
    @State private var callbacks = 0
    private let modes = ["Connected", "Connecting", "Error", "Disabled"]
    private var provider: RemoteProvider { RemoteProvider(name: "Local display provider", host: "example.invalid", enabled: mode != "Disabled", autoConnect: false) }
    private var state: RemoteProviderState {
        var value = RemoteProviderState(providerId: provider.id)
        value.isConnected = mode == "Connected"; value.isConnecting = mode == "Connecting"
        value.discoveredModels = mode == "Connected" ? ["Local model"] : []
        value.lastError = mode == "Error" ? "Local display error; no connection attempted." : nil
        return value
    }
    private var report: ProviderConnectivityProviderReport {
        let p = provider, s = state
        let diagnostics = ProviderDiagnosticReport(title: "Local diagnostics", subtitle: "No network request", rows: [
            .init(id: "local-connection", title: "Connection", value: mode, severity: mode == "Error" ? .blocked : .ok,
                detail: "Local detail text with no actual credentials.", action: "Local action hint"),
            .init(id: "local-models", title: "Models", value: "1 local display model", severity: .info)])
        return .init(id: p.id, provider: p, state: s, diagnostics: diagnostics,
            status: mode == "Connected" ? .connected : mode == "Connecting" ? .connecting : mode == "Disabled" ? .disabled : .needsAttention,
            highestSeverity: mode == "Error" ? .blocked : .ok, summary: "Local display report", recommendedAction: nil,
            modelCount: s.modelCount, manualModelCount: 0, issueKinds: [], primaryIssueKind: nil)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            Text(verbatim: "Original provider cards · local status data only")
            SettingsMenuPicker(selection: $mode) { ForEach(modes, id: \.self) { Text(verbatim: $0).tag($0) } }
                .accessibilityLabel(Text(verbatim: "Local provider status"))
            ProviderCardView(report: report, state: state, isReconnecting: false,
                onReconnect: { callbacks += 1 }, onCopyDiagnostics: { callbacks += 1 }, onEdit: { callbacks += 1 },
                onDelete: { callbacks += 1 }, onToggleEnabled: { _ in callbacks += 1 })
            InspectorModelStatesVerification()
        }
    }
}
#endif
