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
    @ObservedObject private var pickerCache = ModelPickerItemCache.shared

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
    @State private var showDiagnostics = false
    /// Mirrors the sidebar's Developer Tools switch; gates connection
    /// diagnostics so the everyday page is just the providers.
    @State private var showDeveloperDetail = SidebarSectionExpansion.isDeveloperToolsOn

    /// The connectivity filter only earns its header slot on a long list.
    private static let filterThreshold = 4

    private struct AddSheetConfig: Identifiable {
        let id = UUID()
        let preset: ProviderPreset?
        /// Open the add sheet directly on the grouped "Use an API key" sub-list
        /// (only meaningful when `preset` is nil).
        var startAtAPIKeyPicker: Bool = false
    }

    var body: some View {
        VStack(spacing: theme.space.s0) {
            headerView
                .settingsHeaderEntrance(hasAppeared: hasAppeared)

            ScrollView {
                SettingsPageContent {
                    if userConfiguredProviders.isEmpty {
                        emptyStateView
                    } else {
                        providersSection
                        addMoreSection
                        if showDeveloperDetail {
                            diagnosticsDisclosure
                        }
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

    private var headerView: some View {
        SettingsPageHeader(
            title: "Providers",
            subtitle: subtitleText,
            count: badgeStore.headerCount(for: .providers),
            utilities: {
                if userConfiguredProviders.count >= Self.filterThreshold {
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
        guard !userProviders.isEmpty else {
            return L("Use cloud models from OpenAI, Anthropic, Google and more alongside your local ones.")
        }
        let userProviderIds = Set(userProviders.map(\.id))
        let connected = manager.providerStates.filter { userProviderIds.contains($0.key) && $0.value.isConnected }
        guard !connected.isEmpty else {
            return userProviders.count == 1 ? L("1 provider, not connected") : L("\(userProviders.count) providers, none connected")
        }
        let modelCount = connected.values.reduce(0) { $0 + $1.modelCount }
        let models = modelCount == 1 ? L("1 model ready to use") : L("\(modelCount) models ready to use")
        return L("\(connected.count) connected · \(models)")
    }

    // MARK: - Data

    /// Everything the user manages here: no managed router, and no paired
    /// Osaurus agents whose owner has not shared their models for inference
    /// (they answer `/models` with an empty catalog). Those agents stay
    /// reachable for chat/delegation from the Workspaces tab, the Agents tab,
    /// and the chat sidebar.
    private var userConfiguredProviders: [RemoteProvider] {
        manager.userFacingProviders
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

    /// One-click sign-ins the user hasn't connected yet.
    private var unaddedSignIns: [ProviderCatalogEntry] {
        let added = Set(userConfiguredProviders.compactMap { ProviderPreset.matching(provider: $0)?.id })
        return ProviderCatalog.topLevel.filter { !added.contains($0.preset.id) }
    }

    // MARK: - Empty State

    private func presentAddSheet(for preset: ProviderPreset) {
        addSheetConfig = AddSheetConfig(preset: preset)
    }

    private func presentAPIKeyPicker() {
        addSheetConfig = AddSheetConfig(preset: nil, startAtAPIKeyPicker: true)
    }

    private var emptyStateView: some View {
        SettingsEmptyState(
            icon: "cloud.fill",
            title: "Add Your First Provider",
            subtitle: "Sign in with a subscription you already have, or paste an API key. Its models show up in chat right away.",
            content: AnyView(quickAddProviders(ProviderCatalog.topLevel)),
            compact: true,
            footnote: L("Sign-ins and API keys are kept in your Mac's Keychain.")
        )
        .frame(minHeight: 400)
    }

    /// Quick-add: OAuth providers first-class, everything else behind a
    /// single "Use an API key" entry (mirrors the add-sheet picker).
    private func quickAddProviders(_ signIns: [ProviderCatalogEntry]) -> some View {
        SettingsGroup {
            quickAddRows(signIns)
        }
        .frame(maxWidth: 540)
    }

    @ViewBuilder
    private func quickAddRows(_ signIns: [ProviderCatalogEntry]) -> some View {
        ForEach(signIns) { entry in
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

    // MARK: - Providers

    private var providersSection: some View {
        SettingsSection(
            title: "Your Providers",
            caption: providerFilter == .all ? nil : providerFilter.displayName,
            layout: .plain
        ) {
            if visibleProviderReports.isEmpty {
                // Providers exist, but none match the active connectivity filter.
                SettingsGroup {
                    SettingsEmptyState(
                        inline: "line.3.horizontal.decrease.circle",
                        title: "No providers match this filter",
                        action: SettingsEmptyState.Action(title: L("Show All"), icon: "") {
                            providerFilter = .all
                            selectedIssueKind = nil
                        }
                    )
                }
            } else {
                ForEach(visibleProviderReports) { report in
                    ProviderCardView(
                        report: report,
                        state: report.state,
                        models: modelSummaries(for: report.provider, state: report.state),
                        isReconnecting: reconnectingProviderIds.contains(report.id),
                        showsDeveloperDetail: showDeveloperDetail,
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

    /// The provider's chat models as the model picker knows them (catalog
    /// names, image input, reasoning, context window), or its bare ids before
    /// the picker cache has them.
    private func modelSummaries(for provider: RemoteProvider, state: RemoteProviderState?) -> [ProviderModelSummary] {
        let items = pickerCache.items.filter { item in
            guard item.mediaModel == nil, case .remote(_, let providerId) = item.source else { return false }
            return providerId == provider.id
        }
        if !items.isEmpty {
            return items.map {
                ProviderModelSummary(
                    id: $0.id,
                    name: ProviderModelSummary.friendlyName($0.displayName),
                    seesImages: $0.isVLM,
                    reasons: $0.reasoningCapabilities != nil,
                    contextLength: $0.contextLength
                )
            }
        }
        return (state?.discoveredModels ?? []).map {
            ProviderModelSummary(
                id: $0,
                name: ProviderModelSummary.friendlyName($0),
                seesImages: false,
                reasons: false,
                contextLength: nil
            )
        }
    }

    private var addMoreSection: some View {
        SettingsSection(
            title: "Add More",
            subtitle: "Bring in another subscription or API key. Every provider's models appear together in the model picker."
        ) {
            quickAddRows(unaddedSignIns)
        }
    }

    // MARK: - Diagnostics (Developer Tools)

    private var diagnosticsDisclosure: some View {
        let snapshot = connectivitySnapshot
        return SettingsAdvancedDisclosure(
            title: "Connection Diagnostics",
            summary: diagnosticsSummary(snapshot),
            isExpanded: $showDiagnostics
        ) {
            SettingsRow(
                title: "Status",
                description: L("\(snapshot.connectedCount) of \(snapshot.totalCount) connected · \(snapshot.modelCount) models · \(snapshot.manualModelProviderCount) with manual models"),
                verbatimDescription: true
            ) {
                StatusChip(severityLabel(snapshot), tone: severityTone(snapshot), showsDot: true)
            }
            if showsIssueFilters(snapshot) {
                FilterChipScroller(spacing: theme.settingsControlGap) {
                    FilterChip(
                        L("All Issues"),
                        count: snapshot.issueReportCount(for: providerFilter),
                        isSelected: activeIssueKind == nil
                    ) {
                        selectedIssueKind = nil
                    }
                    ForEach(snapshot.sortedIssueKinds(for: providerFilter)) { kind in
                        FilterChip(
                            kind.displayName,
                            count: snapshot.issueKindCounts(for: providerFilter)[kind, default: 0],
                            isSelected: activeIssueKind == kind
                        ) {
                            selectedIssueKind = kind
                        }
                    }
                }
            }
            SettingsRow(
                title: "Reconnect All",
                description: "Retry every provider that's turned on."
            ) {
                SettingsButton(
                    .secondary,
                    "Reconnect All",
                    icon: "arrow.clockwise",
                    isLoading: reconnectingAll,
                    size: .compact,
                    action: reconnectAllProviders
                )
                .disabled(reconnectingAll || snapshot.enabledCount == 0)
            }
            SettingsRow(
                title: "Diagnostics Report",
                description: "Copy a report of every provider's connection checks to share when asking for help."
            ) {
                SettingsButton(.secondary, "Copy Report", icon: "doc.on.doc", size: .compact, action: copyConnectivityReport)
            }
        }
    }

    private func diagnosticsSummary(_ snapshot: ProviderConnectivitySnapshot) -> String {
        snapshot.attentionCount == 0
            ? severityLabel(snapshot)
            : (snapshot.attentionCount == 1 ? L("1 needs attention") : L("\(snapshot.attentionCount) need attention"))
    }

    private func severityLabel(_ snapshot: ProviderConnectivitySnapshot) -> String {
        switch snapshot.highestSeverity {
        case .ok, .info: return L("Healthy")
        case .warning: return L("Needs attention")
        case .blocked: return L("Blocked")
        }
    }

    private func severityTone(_ snapshot: ProviderConnectivitySnapshot) -> StatusChip.Tone {
        switch snapshot.highestSeverity {
        case .ok, .info: return .success
        case .warning: return .warning
        case .blocked: return .error
        }
    }

    private func showsIssueFilters(_ snapshot: ProviderConnectivitySnapshot) -> Bool {
        switch providerFilter {
        case .all, .attention:
            return !snapshot.issueKindCounts(for: providerFilter).isEmpty
        case .connected, .disabled:
            return false
        }
    }

    // MARK: - Actions

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

// MARK: - Provider Model Summary

/// What a provider's model offers, in the terms the card shows.
struct ProviderModelSummary: Identifiable, Equatable {
    let id: String
    let name: String
    let seesImages: Bool
    let reasons: Bool
    let contextLength: Int?

    /// Roughly how many pages of text fit in the context window
    /// (~0.75 words per token, ~500 words per page), rounded to read as an
    /// estimate.
    static func pages(forTokens tokens: Int) -> Int {
        let raw = Double(tokens) * 0.75 / 500
        let step: Double = raw < 100 ? 10 : (raw < 1000 ? 50 : 100)
        return max(Int(step), Int((raw / step).rounded() * step))
    }

    /// A catalog name stays as is; a bare id ("grok-4-fast", "gpt-5.1-codex")
    /// reads as words ("Grok 4 Fast", "GPT-5.1 Codex"). Trailing date
    /// snapshots are dropped.
    static func friendlyName(_ raw: String) -> String {
        let bare = raw.split(separator: "/").last.map(String.init) ?? raw
        guard !bare.contains(" "), bare == bare.lowercased() else { return bare }
        var words = bare.split(separator: "-").map(String.init)
        if let last = words.last, last.count >= 6, last.allSatisfy(\.isNumber), words.count > 1 {
            words.removeLast()
        }
        var result: [String] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            if word == "gpt", index + 1 < words.count {
                result.append("GPT-" + words[index + 1])
                index += 2
                continue
            }
            if word.first?.isNumber == true || (word.count <= 3 && word.contains(where: \.isNumber)) {
                result.append(word)
            } else {
                result.append(word.prefix(1).uppercased() + word.dropFirst())
            }
            index += 1
        }
        return result.isEmpty ? bare : result.joined(separator: " ")
    }

    var helpText: String {
        var lines = [id]
        if seesImages { lines.append(L("Can look at images")) }
        if reasons { lines.append(L("Can think step by step")) }
        if let contextLength, contextLength > 0 {
            lines.append(L("Reads about \(Self.pages(forTokens: contextLength).formatted()) pages at once"))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Provider Card View

/// One provider as a card: who it is and how it signs in, what it offers
/// right now (connection time, model count, what the models can do), the
/// models themselves, and a plain-language fix when it needs one. Raw
/// diagnostics ride the Developer Tools switch.
private struct ProviderCardView: View {
    @Environment(\.theme) private var inheritedTheme
    private var theme: any ThemeProtocol { inheritedTheme }
    let report: ProviderConnectivityProviderReport
    let state: RemoteProviderState?
    var models: [ProviderModelSummary] = []
    let isReconnecting: Bool
    var showsDeveloperDetail: Bool = false
    let onReconnect: () -> Void
    let onCopyDiagnostics: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggleEnabled: (Bool) -> Void

    @State private var showDeleteConfirm = false
    @State private var showsAllModels = false

    private static let modelPreviewLimit = 8

    private var provider: RemoteProvider { report.provider }
    private var isConnected: Bool { state?.isConnected ?? false }
    private var isBusy: Bool { isReconnecting || (state?.isConnecting ?? false) }
    private var matchedPreset: ProviderPreset? { ProviderPreset.matching(provider: provider) }
    private var isLive: Bool { provider.enabled && isConnected }

    private var needsFix: Bool {
        provider.enabled && !isConnected && !isBusy
            && (state?.requiresAuth == true || state?.lastError != nil || report.isAttentionWorthy)
    }

    var body: some View {
        SettingsGroup {
            header
            if isLive {
                facts
                if !models.isEmpty {
                    modelsBlock
                }
            }
            if needsFix {
                fixBanner
            }
            if showsDeveloperDetail, report.isAttentionWorthy {
                ProviderDiagnosticsRowsView(report: report.diagnostics, maxRows: 3)
            }
        }
        .themedAlert(
            L("Delete \(provider.name)?"),
            isPresented: $showDeleteConfirm,
            message: L("Its models disappear from the model picker. You can add it again any time."),
            primaryButton: .destructive(L("Delete")) { onDelete() },
            secondaryButton: .cancel(L("Cancel"))
        )
    }

    // MARK: Header

    private var header: some View {
        LibraryRow(title: provider.name, subtitle: headerSubtitle, action: onEdit) {
            ProviderIconTile(
                preset: matchedPreset,
                size: 40,
                isActive: isConnected,
                inactiveTint: provider.enabled ? theme.text.secondary : theme.text.tertiary
            )
        } badges: {
            statusChip
            if provider.providerType == .osaurus {
                // Osaurus peers talk through the Secure Channel —
                // agent traffic is end-to-end encrypted or refused.
                StatusChip(
                    L("Encrypted"),
                    tone: .success,
                    icon: "lock.fill",
                    help: L(
                        "Agent traffic is protected by the Osaurus Secure Channel: forward-secret, mutually authenticated end-to-end encryption."
                    )
                )
            }
        } trailing: {
            Toggle(
                "",
                isOn: Binding(
                    get: { provider.enabled },
                    set: { onToggleEnabled($0) }
                )
            )
            .settingsSwitch()
            .help(provider.enabled ? L("Turn off to hide its models") : L("Turn on to use its models"))
        } menu: {
            Button(L("Edit…"), action: onEdit)
            Button(L("Reconnect"), action: onReconnect)
                .disabled(!provider.enabled || isBusy)
            if showsDeveloperDetail {
                Button(L("Copy Diagnostics"), action: onCopyDiagnostics)
            }
            Divider()
            Button(L("Delete…"), role: .destructive) { showDeleteConfirm = true }
        }
    }

    @ViewBuilder
    private var statusChip: some View {
        if !provider.enabled {
            StatusChip(L("Off"), tone: .neutral)
        } else if isBusy {
            StatusChip(L("Connecting…"), tone: .accent)
        } else if isConnected {
            StatusChip(L("Connected"), tone: .success, showsDot: true)
        } else if needsFix {
            StatusChip(L("Needs Attention"), tone: .warning, showsDot: true)
        } else {
            StatusChip(L("Not Connected"), tone: .neutral)
        }
    }

    private var headerSubtitle: String {
        if !provider.enabled {
            return accountSentence + "\n" + L("Turned off, so its models are hidden in chat.")
        }
        if isBusy {
            return accountSentence + "\n" + L("Connecting and fetching models…")
        }
        return accountSentence
    }

    /// How it signs in, in a sentence.
    private var accountSentence: String {
        switch provider.authType {
        case .openAICodexOAuth: return L("Signed in with your ChatGPT subscription")
        case .xaiOAuth: return L("Signed in with your Grok subscription")
        case .apiKey, .none: break
        }
        if provider.providerType == .osaurus { return L("Models shared from another Mac running Osaurus") }
        if Self.isLocalHost(provider.host) { return L("Running on this Mac") }
        if let preset = matchedPreset, preset != .custom {
            return provider.authType == .apiKey ? L("Connected with your \(preset.name) API key") : preset.name
        }
        return L("Custom server at \(provider.host)")
    }

    private static func isLocalHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        return lower == "localhost" || lower.hasPrefix("localhost:") || lower.hasPrefix("127.0.0.1") || lower == "::1"
    }

    // MARK: Facts

    private var facts: some View {
        let visionCount = models.filter(\.seesImages).count
        let reasoningCount = models.filter(\.reasons).count
        let longestContext = models.compactMap(\.contextLength).max()
        return HStack(alignment: .top, spacing: theme.space.s24) {
            if let since = state?.lastConnectedAt {
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    fact(
                        icon: "clock",
                        value: since.formatted(.relative(presentation: .named)),
                        label: L("Connected")
                    )
                }
            }
            fact(
                icon: "square.stack.3d.up",
                value: models.count == 1 ? L("1 model") : L("\(models.count) models"),
                label: L("Ready to use in chat")
            )
            if visionCount > 0 {
                fact(icon: "eye", value: "\(visionCount)", label: L("Can look at images"))
            }
            if reasoningCount > 0 {
                fact(icon: "brain", value: "\(reasoningCount)", label: L("Think step by step"))
            }
            if let longestContext, longestContext > 0 {
                fact(
                    icon: "doc.text",
                    value: L("~\(ProviderModelSummary.pages(forTokens: longestContext).formatted()) pages"),
                    label: L("Longest read at once")
                )
            }
            Spacer(minLength: 0)
        }
    }

    private func fact(icon: String, value: String, label: String) -> some View {
        HStack(alignment: .top, spacing: theme.space.s8) {
            Image(systemName: icon)
                .glyphSize(.footnote, weight: .medium)
                .foregroundColor(theme.text.tertiary)
                .padding(.top, theme.space.s2)
            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(verbatim: value)
                    .font(SettingsFont.rowTitle)
                    .foregroundColor(theme.text.primary)
                Text(verbatim: label)
                    .font(SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
            }
        }
        .fixedSize()
    }

    // MARK: Models

    private var modelsBlock: some View {
        let displayed = showsAllModels ? models : Array(models.prefix(Self.modelPreviewLimit))
        return VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack {
                Text("Models", bundle: .module)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.secondary)
                Spacer()
                if models.count > Self.modelPreviewLimit {
                    SettingsButton(
                        .tertiary,
                        showsAllModels ? L("Show Fewer") : L("Show All \(models.count)"),
                        size: .compact,
                        verbatim: true
                    ) {
                        withAnimation(theme.motion.quick) { showsAllModels.toggle() }
                    }
                }
            }
            FlowLayout(spacing: theme.space.s6) {
                ForEach(displayed) { model in
                    ProviderModelChip(model: model)
                }
            }
        }
    }

    // MARK: Fix

    private var fixBanner: some View {
        let isSignIn = provider.authType == .openAICodexOAuth || provider.authType == .xaiOAuth
        let kind = report.primaryIssueKind
        let banner: (title: String, caption: String, action: InlineBanner.Action)
        if state?.requiresAuth == true || kind == .authentication || kind == .oauthContext {
            banner = (
                isSignIn ? L("Sign in again") : L("Check your API key"),
                isSignIn
                    ? L("Your sign-in with \(provider.name) has expired.")
                    : L("\(provider.name) didn't accept the API key."),
                InlineBanner.Action(title: L("Fix…"), handler: onEdit)
            )
        } else if kind == .connection || kind == .proxy || kind == .transport {
            banner = (
                L("Couldn't reach \(provider.name)"),
                L("Check your internet connection, then try again."),
                InlineBanner.Action(title: L("Try Again"), handler: onReconnect)
            )
        } else if kind == .models {
            banner = (
                L("No models available"),
                L("\(provider.name) connected but didn't offer any models."),
                InlineBanner.Action(title: L("Edit…"), handler: onEdit)
            )
        } else {
            banner = (
                L("Couldn't connect to \(provider.name)"),
                showsDeveloperDetail ? (state?.lastError ?? report.summary) : L("Try again, or open Edit to check its settings."),
                InlineBanner.Action(title: L("Try Again"), handler: onReconnect)
            )
        }
        return InlineBanner(kind: .warning, title: banner.title, caption: banner.caption, action: banner.action)
    }
}

/// One model as a chip: its name, plus small glyphs for image input and
/// step-by-step reasoning. Hover for the id and what it can do.
private struct ProviderModelChip: View {
    @Environment(\.theme) private var theme
    let model: ProviderModelSummary

    var body: some View {
        HStack(spacing: theme.space.s4) {
            Text(verbatim: model.name)
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.primary)
                .lineLimit(1)
            if model.seesImages {
                Image(systemName: "eye")
                    .glyphSize(.micro, weight: .medium)
                    .foregroundColor(theme.text.tertiary)
            }
            if model.reasons {
                Image(systemName: "brain")
                    .glyphSize(.micro, weight: .medium)
                    .foregroundColor(theme.text.tertiary)
            }
        }
        .padding(.horizontal, theme.space.s8)
        .padding(.vertical, theme.space.s4)
        .settingsChrome(.inset)
        .help(model.helpText)
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
