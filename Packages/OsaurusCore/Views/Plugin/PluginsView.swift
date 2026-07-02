//
//  PluginsView.swift
//  osaurus
//
//  Manage plugins: browse repository, install, update, and configure installed plugins.
//

import Foundation
import OsaurusRepository
import SwiftUI

struct PluginsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private let repoService = PluginRepositoryService.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var selectedTab: PluginsTab = .installed
    @State private var searchText: String = ""
    @State private var hasAppeared = false
    @State private var isRefreshButtonLoading = false

    @State private var isRepoRefreshing = false
    @State private var updatesAvailableCount = 0
    @State private var repoLastError: String?
    @State private var missingPermissionsPerPlugin: [String: [SystemPermission]] = [:]

    @State private var filteredPlugins: [PluginState] = []
    @State private var installedPlugins: [PluginState] = []
    @State private var pluginsWithMissingPermissionsCount = 0

    @State private var showSecretsSheet: Bool = false
    @State private var secretsSheetPluginId: String?
    @State private var secretsSheetPluginName: String?
    @State private var secretsSheetPluginVersion: String?
    @State private var secretsSheetSecrets: [PluginManifest.SecretSpec] = []

    // Detail navigation
    @State private var selectedPlugin: PluginState?
    /// Detail navigation for an imported Claude plugin. Mutually
    /// exclusive with `selectedPlugin` — only one detail surface is
    /// visible at a time.
    @State private var selectedClaudePlugin: ClaudePluginInstalled?

    @ObservedObject private var managementState = ManagementStateManager.shared
    @StateObject private var claudeAggregator = InstalledClaudePluginsAggregator()

    // Live counts feeding the Claude aggregator's debounced refresh.
    private let claudeSkillManager = SkillManager.shared
    private let claudeScheduleManager = ScheduleManager.shared
    private let claudeSlashCommands = SlashCommandRegistry.shared
    @ObservedObject private var claudeMCPManager = MCPProviderManager.shared

    // GitHub-import sheet state.
    @State private var showGitHubImport: Bool = false
    // Claude userConfig sheet.
    @State private var showClaudeUserConfigSheet: Bool = false
    @State private var claudeUserConfigTarget: ClaudePluginInstalled?
    @State private var claudeRefreshDebounceTask: Task<Void, Never>?

    // Search-filtered Claude plugins.
    @State private var filteredClaudePlugins: [ClaudePluginInstalled] = []

    // Claude marketplace (Browse tab discovery surface).
    @ObservedObject private var claudeMarketplace = ClaudeMarketplaceService.shared
    /// Selected category key for the marketplace chips. `nil` == "All".
    @State private var selectedCategory: String?
    /// Search + category filtered marketplace entries.
    @State private var filteredMarketplaceEntries: [MarketplacePlugin] = []
    /// Detail navigation for a browsable (not-yet-installed) marketplace entry.
    @State private var selectedMarketplaceEntry: MarketplacePlugin?

    // Success toast
    @State private var successMessage: String?

    @ViewBuilder
    private var pluginDetailOverlay: some View {
        if let plugin = selectedPlugin {
            PluginDetailView(
                plugin: plugin,
                missingPermissions: missingPermissionsPerPlugin[plugin.pluginId] ?? [],
                onBack: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        selectedPlugin = nil
                    }
                },
                onUpgrade: { try await repoService.upgrade(pluginId: plugin.pluginId) },
                onUninstall: {
                    try await repoService.uninstall(pluginId: plugin.pluginId)
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        selectedPlugin = nil
                    }
                },
                onInstall: { try await repoService.install(pluginId: plugin.pluginId) },
                onChange: { reload() }
            )
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
    }

    @ViewBuilder
    private var claudeDetailOverlay: some View {
        if let claudePlugin = selectedClaudePlugin {
            ClaudePluginDetailView(
                plugin: claudePlugin,
                onBack: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        selectedClaudePlugin = nil
                    }
                },
                onUpdate: { try await updateClaudePlugin(claudePlugin) },
                onUninstall: {
                    await uninstallClaudePlugin(claudePlugin)
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        selectedClaudePlugin = nil
                    }
                },
                onConfigure: {
                    claudeUserConfigTarget = claudePlugin
                    showClaudeUserConfigSheet = true
                },
                onChange: {
                    claudeAggregator.refresh()
                    Task { await updateFilteredLists() }
                }
            )
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
    }

    @ViewBuilder
    private var marketplaceDetailOverlay: some View {
        if let entry = selectedMarketplaceEntry {
            ClaudeMarketplaceDetailView(
                entry: entry,
                onBack: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        selectedMarketplaceEntry = nil
                    }
                },
                onInstall: {
                    try await installMarketplaceEntry(entry)
                    // `installMarketplaceEntry` refreshes the aggregator
                    // synchronously, so the freshly installed plugin is now
                    // available. Transition into the rich installed detail
                    // (uninstall / previews / configure) for a continuous flow.
                    if let installed = installedClaudePlugin(for: entry) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            selectedMarketplaceEntry = nil
                            selectedClaudePlugin = installed
                        }
                    }
                }
            )
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
    }

    @ViewBuilder
    private var successToastOverlay: some View {
        if let message = successMessage {
            VStack {
                Spacer()
                ThemedToastView(message, type: .success)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 20)
            }
            .zIndex(100)
        }
    }

    var body: some View {
        marketplaceObservers
            .onChange(of: claudeSkillManager.skills.count) { _, _ in scheduleClaudeRefresh() }
            .onChange(of: claudeScheduleManager.schedules.count) { _, _ in scheduleClaudeRefresh() }
            .onChange(of: claudeSlashCommands.customCommands.count) { _, _ in scheduleClaudeRefresh() }
            .onChange(of: claudeMCPManager.configuration.providers.count) { _, _ in
                scheduleClaudeRefresh()
            }
    }

    private var marketplaceObservers: some View {
        decoratedContent
            .onReceive(claudeAggregator.$plugins) { _ in
                Task { await updateFilteredLists() }
            }
            .onReceive(claudeMarketplace.$entries) { _ in
                Task { await updateFilteredLists() }
            }
            .onChange(of: selectedCategory) { _, _ in
                Task { await updateFilteredLists() }
            }
    }

    private var decoratedContent: some View {
        ZStack {
            if selectedPlugin == nil && selectedClaudePlugin == nil
                && selectedMarketplaceEntry == nil
            {
                gridContent
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }

            pluginDetailOverlay
            claudeDetailOverlay
            marketplaceDetailOverlay
            successToastOverlay
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            reload()
            if repoService.plugins.isEmpty {
                Task {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    await repoService.refresh()
                    applyPendingPluginDetailRequest()
                }
            }
            // Kick off a Claude-plugin update check in the background so
            // the badge / Update button reflect the latest state on tab
            // entry without blocking initial render.
            Task { await claudeAggregator.checkForUpdates() }
            // Load the official Claude marketplace catalog once so the
            // Browse tab's discovery grid is ready when the user switches.
            claudeMarketplace.loadIfNeeded()
            withAnimation(.easeOut(duration: 0.25).delay(0.1)) {
                hasAppeared = true
            }
            applyPendingPluginDetailRequest()
        }
        .onReceive(managementState.$pendingPluginDetailId) { _ in
            applyPendingPluginDetailRequest()
        }
        .task(id: searchText) {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            await updateFilteredLists()
        }
        .onReceive(PluginRepositoryService.shared.$plugins) { newPlugins in
            if let selected = selectedPlugin,
                let updated = newPlugins.first(where: { $0.pluginId == selected.pluginId })
            {
                selectedPlugin = updated
            }
            Task { await updateFilteredLists() }
            applyPendingPluginDetailRequest(in: newPlugins)
        }
        .onReceive(PluginRepositoryService.shared.$isRefreshing) { isRepoRefreshing = $0 }
        .onReceive(PluginRepositoryService.shared.$updatesAvailableCount) { updatesAvailableCount = $0 }
        .onReceive(PluginRepositoryService.shared.$lastError) { repoLastError = $0 }
        .onReceive(PluginRepositoryService.shared.$pendingSecretsPlugin) { newValue in
            if let pluginId = newValue {
                showSecretsSheetForPlugin(pluginId: pluginId)
                repoService.pendingSecretsPlugin = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toolsListChanged)) { _ in
            reload()
        }
        .sheet(isPresented: $showSecretsSheet) {
            if let pluginId = secretsSheetPluginId {
                ToolSecretsSheet(
                    pluginId: pluginId,
                    agentId: Agent.defaultId,
                    pluginName: secretsSheetPluginName ?? pluginId,
                    pluginVersion: secretsSheetPluginVersion,
                    secrets: secretsSheetSecrets,
                    onSave: { reload() }
                )
            }
        }
        .sheet(isPresented: $showGitHubImport) {
            GitHubImportSheet(
                onImport: { skills in
                    Task { @MainActor in
                        _ = await claudeSkillManager.importSkillsFromMarkdown(skills)
                        showGitHubImport = false
                        claudeAggregator.refresh()
                        showSuccess(L("Imported \(skills.count) items"))
                    }
                },
                onCancel: { showGitHubImport = false },
                onPluginInstallComplete: { report in
                    Task { @MainActor in
                        await claudeSkillManager.refresh()
                        claudeAggregator.refresh()
                        await updateFilteredLists()
                        let total =
                            report.totalImportedSkills + report.totalImportedAgents
                            + report.totalImportedCommands + report.totalImportedMCPProviders
                        if total > 0 {
                            showSuccess(L("Installed \(total) items"))
                        }
                    }
                }
            )
        }
        .sheet(isPresented: $showClaudeUserConfigSheet) {
            if let target = claudeUserConfigTarget,
                let snap = target.snapshot
            {
                ClaudePluginUserConfigSheet(
                    pluginId: target.pluginId,
                    pluginName: target.displayName,
                    pluginVersion: target.version,
                    fields: snap.userConfigSpec,
                    onSave: {
                        showClaudeUserConfigSheet = false
                        claudeAggregator.refresh()
                    }
                )
            }
        }
    }

    /// Debounce aggregator refreshes so a burst of changes during an
    /// import doesn't cause repeated re-aggregations.
    private func scheduleClaudeRefresh() {
        claudeRefreshDebounceTask?.cancel()
        claudeRefreshDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            claudeAggregator.refresh()
        }
    }

    /// Re-fetch the source repo's marketplace and re-install the plugin
    /// in `replaceExisting` mode so any newly added artifacts come in
    /// alongside the version bump. Throws so the detail view's error
    /// surface can show the failure.
    private func updateClaudePlugin(_ plugin: ClaudePluginInstalled) async throws {
        guard let snap = plugin.snapshot else { return }
        let repo = GitHubRepo(
            owner: snap.sourceOwner,
            name: snap.sourceRepo,
            branch: snap.sourceBranch ?? "main"
        )
        let url = "https://github.com/\(snap.sourceOwner)/\(snap.sourceRepo)"
        let result = try await GitHubSkillService.shared.fetchPlugins(from: url)
        guard let manifest = result.plugins.first(where: { $0.name == snap.name }) else {
            throw GitHubSkillError.noSkillsFound
        }
        let selection = ClaudePluginSelection(manifest: manifest)
        _ = await ClaudePluginInstaller.shared.install(
            selections: [selection],
            from: repo,
            replaceExisting: true
        )
        await claudeSkillManager.refresh()
        claudeAggregator.refresh()
        await updateFilteredLists()
    }

    private func uninstallClaudePlugin(_ plugin: ClaudePluginInstalled) async {
        _ = await ClaudePluginInstaller.shared.uninstall(pluginId: plugin.pluginId)
        await claudeSkillManager.refresh()
        claudeAggregator.refresh()
        await updateFilteredLists()
    }

    /// Resolve + install a single marketplace entry, then refresh the
    /// installed-plugin surfaces and show a success toast. Throws so the
    /// calling card / detail view can surface the failure.
    private func installMarketplaceEntry(_ entry: MarketplacePlugin) async throws {
        let report = try await claudeMarketplace.install(entry: entry)
        await claudeSkillManager.refresh()
        claudeAggregator.refresh()
        await updateFilteredLists()
        if let report {
            let total =
                report.totalImportedSkills + report.totalImportedAgents
                + report.totalImportedCommands + report.totalImportedMCPProviders
            let baseMessage =
                total > 0
                ? L("Installed \(total) items from \(entry.name)")
                : L("Installed \(entry.name)")
            let message =
                report.requiresAttention
                ? "\(baseMessage); \(report.totalAttentionItems) need review"
                : baseMessage
            showSuccess(message)
        }
    }

    /// Honor a pending `osaurus://plugins-install?tool=<id>` deeplink request.
    /// switch to the right tab, open the plugin's detail view, then clear the request.
    /// called both on appear and whenever the repo's plugin list updates so the
    /// request can resolve as soon as the plugin becomes known
    private func applyPendingPluginDetailRequest(in plugins: [PluginState]? = nil) {
        guard let pluginId = managementState.pendingPluginDetailId, !pluginId.isEmpty else { return }
        let source = plugins ?? repoService.plugins
        guard let plugin = source.first(where: { $0.pluginId == pluginId }) else {
            // repo not loaded yet so leave the request in place and let the
            // `$plugins` receiver retry once it arrives
            return
        }

        if !installedPlugins.contains(where: { $0.pluginId == pluginId }) {
            selectedTab = .browse
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            selectedPlugin = plugin
        }
        managementState.pendingPluginDetailId = nil
    }

    private func showSecretsSheetForPlugin(pluginId: String) {
        guard let loaded = PluginManager.shared.plugins.first(where: { $0.plugin.id == pluginId }),
            let secrets = loaded.plugin.manifest.secrets,
            !secrets.isEmpty
        else {
            return
        }

        secretsSheetPluginId = pluginId
        secretsSheetPluginName = loaded.plugin.manifest.name ?? pluginId
        secretsSheetPluginVersion = loaded.plugin.manifest.version
        secretsSheetSecrets = secrets
        showSecretsSheet = true
    }

    // MARK: - Grid Content

    private var gridContent: some View {
        VStack(spacing: 0) {
            headerBar
                .managerHeaderEntrance(hasAppeared: hasAppeared)

            Group {
                switch selectedTab {
                case .installed:
                    installedTabContent
                case .browse:
                    browseTabContent
                case .claude:
                    claudePluginsTabContent
                }
            }
            .opacity(hasAppeared ? 1 : 0)
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        ManagerHeaderWithTabs(
            title: L("Plugins"),
            subtitle: L("Browse and manage plugins")
        ) {
            HeaderIconButton(
                "arrow.clockwise",
                isLoading: isRefreshButtonLoading,
                help: isRefreshButtonLoading ? L("Refreshing...") : L("Refresh repository")
            ) {
                Task {
                    isRefreshButtonLoading = true
                    await repoService.refresh()
                    await PluginManager.shared.loadAll()
                    await claudeAggregator.checkForUpdates()
                    reload()
                    isRefreshButtonLoading = false
                }
            }
            ClaudePluginImportButton {
                showGitHubImport = true
            }
        } tabsRow: {
            let claudeCount = filteredClaudePlugins.count
            let claudeUpdateCount = claudeAggregator.plugins.filter { $0.hasUpdate }.count
            HeaderTabsRow(
                selection: $selectedTab,
                counts: [
                    .installed: installedPlugins.count + claudeCount,
                    .browse: filteredPlugins.count,
                    .claude: filteredMarketplaceEntries.count,
                ],
                badges: (updatesAvailableCount + claudeUpdateCount) > 0
                    ? [.installed: updatesAvailableCount + claudeUpdateCount]
                    : nil,
                searchText: $searchText,
                searchPlaceholder: "Search plugins"
            )
        }
    }

    // MARK: - Installed Tab

    private var installedTabContent: some View {
        Group {
            if installedPlugins.isEmpty && filteredClaudePlugins.isEmpty {
                emptyState(
                    icon: "puzzlepiece.extension",
                    title: L("No plugins installed"),
                    subtitle: searchText.isEmpty
                        ? L("Browse the repository or import a Claude plugin")
                        : L("Try a different search term")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if pluginsWithMissingPermissionsCount > 0 {
                            ToolPermissionBanner(count: pluginsWithMissingPermissionsCount)
                        }

                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(minimum: 300), spacing: 20),
                                GridItem(.flexible(minimum: 300), spacing: 20),
                            ],
                            spacing: 20
                        ) {
                            ForEach(Array(installedPlugins.enumerated()), id: \.element.id) { index, plugin in
                                PluginCard(
                                    plugin: plugin,
                                    missingPermissions: missingPermissionsPerPlugin[plugin.pluginId] ?? [],
                                    animationDelay: Double(index) * 0.05,
                                    hasAppeared: hasAppeared,
                                    onSelect: {
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                            selectedPlugin = plugin
                                        }
                                    },
                                    onUpgrade: { try await repoService.upgrade(pluginId: plugin.pluginId) },
                                    onUninstall: {
                                        try await repoService.uninstall(pluginId: plugin.pluginId)
                                        reload()
                                    },
                                    onChange: { reload() }
                                )
                            }

                            let nativeOffset = installedPlugins.count
                            ForEach(
                                Array(filteredClaudePlugins.enumerated()),
                                id: \.element.id
                            ) { index, claudePlugin in
                                ClaudePluginCard(
                                    plugin: claudePlugin,
                                    animationDelay: Double(index + nativeOffset) * 0.05,
                                    hasAppeared: hasAppeared,
                                    onSelect: {
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                            selectedClaudePlugin = claudePlugin
                                        }
                                    },
                                    onUpdate: {
                                        try await updateClaudePlugin(claudePlugin)
                                    },
                                    onUninstall: {
                                        await uninstallClaudePlugin(claudePlugin)
                                    },
                                    onConfigure: {
                                        claudeUserConfigTarget = claudePlugin
                                        showClaudeUserConfigSheet = true
                                    },
                                    onChange: {
                                        claudeAggregator.refresh()
                                        Task { await updateFilteredLists() }
                                    }
                                )
                            }
                        }
                    }
                    .padding(24)
                }
            }
        }
    }

    // MARK: - Browse Tab

    private var twoColumnGrid: [GridItem] {
        [
            GridItem(.flexible(minimum: 300), spacing: 20),
            GridItem(.flexible(minimum: 300), spacing: 20),
        ]
    }

    /// The installed Claude plugin that corresponds to a marketplace entry,
    /// if any. Used to route already-installed entries straight to the rich
    /// installed-plugin detail (uninstall / previews / configure) instead of
    /// the discovery surface.
    private func installedClaudePlugin(for entry: MarketplacePlugin) -> ClaudePluginInstalled? {
        guard let id = claudeMarketplace.pluginId(for: entry) else { return nil }
        return claudeAggregator.plugins.first { $0.pluginId == id }
    }

    /// Open the best detail surface for a marketplace entry: the rich
    /// installed detail when it's already installed, otherwise the discovery
    /// detail with an Install call-to-action.
    private func openMarketplaceEntry(_ entry: MarketplacePlugin) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            if let installed = installedClaudePlugin(for: entry) {
                selectedClaudePlugin = installed
            } else {
                selectedMarketplaceEntry = entry
            }
        }
    }

    private var browseTabContent: some View {
        Group {
            if let errorMessage = repoLastError {
                VStack(spacing: 12) {
                    offlineBanner(message: errorMessage)
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                    nativeBrowseGrid
                }
            } else if isRepoRefreshing && filteredPlugins.isEmpty {
                loadingState
            } else if filteredPlugins.isEmpty {
                emptyState(
                    icon: "puzzlepiece.extension",
                    title: searchText.isEmpty ? "No plugins available" : "No plugins match your search",
                    subtitle: searchText.isEmpty ? nil : "Try a different search term"
                )
            } else {
                nativeBrowseGrid
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading repository...", bundle: .module)
                .font(.system(size: 14))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 60)
    }

    private var nativeBrowseGrid: some View {
        ScrollView {
            LazyVGrid(columns: twoColumnGrid, spacing: 20) {
                ForEach(Array(filteredPlugins.enumerated()), id: \.element.id) { index, plugin in
                    PluginCard(
                        plugin: plugin,
                        missingPermissions: [],
                        animationDelay: Double(index) * 0.05,
                        hasAppeared: hasAppeared,
                        onSelect: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                selectedPlugin = plugin
                            }
                        },
                        onUpgrade: { try await repoService.upgrade(pluginId: plugin.pluginId) },
                        onUninstall: {
                            try await repoService.uninstall(pluginId: plugin.pluginId)
                            reload()
                        },
                        onInstall: { try await repoService.install(pluginId: plugin.pluginId) },
                        onChange: { reload() }
                    )
                }
            }
            .padding(24)
        }
    }

    // MARK: - Claude Plugins Tab (marketplace discovery)

    private var claudePluginsTabContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !claudeMarketplace.categories.isEmpty {
                    MarketplaceCategoryChips(
                        categories: claudeMarketplace.categories,
                        totalCount: claudeMarketplace.entries.count,
                        selected: $selectedCategory
                    )
                }
                marketplaceSection
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private var marketplaceSection: some View {
        if claudeMarketplace.isLoading && claudeMarketplace.entries.isEmpty {
            marketplaceLoadingGrid
        } else if let error = claudeMarketplace.lastError, claudeMarketplace.entries.isEmpty {
            marketplaceErrorView(error)
        } else if filteredMarketplaceEntries.isEmpty {
            marketplaceEmptyView
        } else {
            // Installed plugins are excluded upstream (they live in the
            // Installed tab), so this grid is purely available discovery.
            LazyVGrid(columns: twoColumnGrid, spacing: 20) {
                ForEach(Array(filteredMarketplaceEntries.enumerated()), id: \.element.name) {
                    index,
                    entry in
                    ClaudeMarketplaceCard(
                        entry: entry,
                        animationDelay: Double(min(index, 12)) * 0.04,
                        hasAppeared: hasAppeared,
                        onSelect: { openMarketplaceEntry(entry) },
                        onInstall: { try await installMarketplaceEntry(entry) }
                    )
                }
            }
        }
    }

    private var marketplaceLoadingGrid: some View {
        LazyVGrid(columns: twoColumnGrid, spacing: 20) {
            ForEach(0 ..< 6, id: \.self) { _ in
                MarketplaceSkeletonCard()
            }
        }
    }

    private func marketplaceErrorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            offlineBanner(message: message)
            Button(action: { Task { await claudeMarketplace.refresh() } }) {
                Text("Retry", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.accentColor)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(claudeMarketplace.isLoading)
        }
    }

    private var marketplaceEmptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(theme.tertiaryText)
            Text(
                searchText.isEmpty
                    ? "No plugins in this category yet"
                    : "No plugins match your search",
                bundle: .module
            )
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - Empty / Loading States

    private func emptyState(icon: String, title: String, subtitle: String?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundColor(theme.tertiaryText)

            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(theme.secondaryText)

            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundColor(theme.tertiaryText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 60)
    }

    private func offlineBanner(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 14))
                .foregroundColor(theme.warningColor)

            Text(message)
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)

            Spacer()

            Button(action: {
                Task {
                    isRefreshButtonLoading = true
                    await repoService.refresh()
                    isRefreshButtonLoading = false
                }
            }) {
                Text("Retry", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.accentColor)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isRepoRefreshing)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.warningColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.warningColor.opacity(0.2), lineWidth: 1)
                )
        )
    }

    // MARK: - Success Toast

    private func showSuccess(_ message: String) {
        withAnimation(theme.springAnimation()) {
            successMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(theme.animationQuick()) {
                successMessage = nil
            }
        }
    }

    // MARK: - Helpers

    nonisolated private static func pluginMatchesQuery(_ plugin: PluginState, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let queryLower = query.lowercased()
        return [
            plugin.pluginId.lowercased(),
            (plugin.name ?? "").lowercased(),
            (plugin.pluginDescription ?? "").lowercased(),
        ].contains { SearchService.fuzzyMatch(query: queryLower, in: $0) }
    }

    nonisolated private static func claudePluginMatchesQuery(
        _ plugin: ClaudePluginInstalled,
        query: String
    ) -> Bool {
        guard !query.isEmpty else { return true }
        let queryLower = query.lowercased()
        var candidates: [String] = [
            plugin.displayName.lowercased(),
            plugin.pluginId.lowercased(),
            plugin.sourceLabel.lowercased(),
        ]
        if let snap = plugin.snapshot {
            if let description = snap.description {
                candidates.append(description.lowercased())
            }
            candidates.append(contentsOf: snap.keywords.map { $0.lowercased() })
            if let authorName = snap.authorName {
                candidates.append(authorName.lowercased())
            }
        }
        return candidates.contains { SearchService.fuzzyMatch(query: queryLower, in: $0) }
    }

    nonisolated private static func marketplaceEntryMatchesQuery(
        _ entry: MarketplacePlugin,
        query: String
    ) -> Bool {
        guard !query.isEmpty else { return true }
        let queryLower = query.lowercased()
        var candidates: [String] = [entry.name.lowercased()]
        if let description = entry.description { candidates.append(description.lowercased()) }
        if let author = entry.author?.name { candidates.append(author.lowercased()) }
        if let category = entry.category { candidates.append(category.lowercased()) }
        candidates.append(contentsOf: (entry.keywords ?? []).map { $0.lowercased() })
        return candidates.contains { SearchService.fuzzyMatch(query: queryLower, in: $0) }
    }

    private func updateFilteredLists() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentPlugins = repoService.plugins
        let currentClaudePlugins = claudeAggregator.plugins
        let currentMarketplace = claudeMarketplace.entries
        let category = selectedCategory
        // Installed Claude plugins live in the Installed tab. Exclude them from
        // the marketplace discovery grid so they aren't duplicated across tabs.
        let installedPluginIds = Set(currentClaudePlugins.map { $0.pluginId })
        let marketplaceRepo = claudeMarketplace.repo

        let (browseResult, installedResult, claudeResult, marketplaceResult) =
            await Task.detached(priority: .userInitiated) {
                let browse = currentPlugins.filter { Self.pluginMatchesQuery($0, query: query) }
                let installed =
                    currentPlugins
                    .filter { $0.isInstalled && Self.pluginMatchesQuery($0, query: query) }
                    .sorted { $0.displayName < $1.displayName }
                let claude =
                    currentClaudePlugins
                    .filter { Self.claudePluginMatchesQuery($0, query: query) }
                    .sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
                let marketplace =
                    currentMarketplace
                    .filter { entry in
                        let categoryMatches =
                            category == nil
                            || ClaudeMarketplaceService.categoryKey(for: entry) == category
                        let isInstalled: Bool = {
                            guard let marketplaceRepo else { return false }
                            let id = ClaudePluginInstaller.pluginId(
                                repo: marketplaceRepo,
                                pluginName: entry.name
                            )
                            return installedPluginIds.contains(id)
                        }()
                        return categoryMatches
                            && !isInstalled
                            && Self.marketplaceEntryMatchesQuery(entry, query: query)
                    }
                    .sorted { $0.name.lowercased() < $1.name.lowercased() }
                return (browse, installed, claude, marketplace)
            }.value

        guard !Task.isCancelled else { return }

        filteredPlugins = browseResult
        installedPlugins = installedResult
        filteredClaudePlugins = claudeResult
        filteredMarketplaceEntries = marketplaceResult

        var permissionCount = 0
        var missingPerms: [String: [SystemPermission]] = [:]
        for plugin in installedResult {
            let toolNames = (plugin.capabilities?.tools ?? []).map { $0.name }
            var missing = Set<SystemPermission>()
            for name in toolNames {
                if let info = ToolRegistry.shared.policyInfo(for: name) {
                    for (perm, granted) in info.systemPermissionStates where !granted {
                        missing.insert(perm)
                    }
                }
            }
            if !missing.isEmpty {
                missingPerms[plugin.pluginId] = Array(missing).sorted { $0.rawValue < $1.rawValue }
                permissionCount += 1
            }
        }
        missingPermissionsPerPlugin = missingPerms
        pluginsWithMissingPermissionsCount = permissionCount
    }

    private func reload() {
        updatesAvailableCount = repoService.updatesAvailableCount
        Task { await updateFilteredLists() }
    }
}

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        PluginsView()
    }
#endif

// MARK: - Claude Plugin Import Button

/// Single-action button mirroring the Skills header dropdown but
/// scoped to Claude plugins (GitHub-only). Lifts the dispatch-after-
/// dismiss safety net from `SkillsView`'s `ImportDropdownButton` so a
/// `.sheet` presented from inside the menu doesn't deadlock SwiftUI.
private struct ClaudePluginImportButton: View {
    @Environment(\.theme) private var theme
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: { dispatchAfterDismiss(onSelect) }) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 13, weight: .medium))
                Text("Import", bundle: .module)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(theme.secondaryText)
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.tertiaryBackground)
                    .opacity(isHovering ? 0.8 : 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
        .localizedHelp("Import Claude plugin from GitHub")
    }

    private func dispatchAfterDismiss(_ action: @escaping () -> Void) {
        Task { @MainActor in
            try? await Task.sleepForPopoverDismiss()
            action()
        }
    }
}

// MARK: - Plugin Card (Grid)

private struct PluginCard: View {
    @Environment(\.theme) private var theme
    let plugin: PluginState
    let missingPermissions: [SystemPermission]
    let animationDelay: Double
    let hasAppeared: Bool
    let onSelect: () -> Void
    var onUpgrade: (() async throws -> Void)?
    var onUninstall: (() async throws -> Void)?
    var onInstall: (() async throws -> Void)?
    var onChange: (() -> Void)?

    @State private var isHovered = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showKeyMismatch = false
    @State private var hasMissingSecrets = false
    @State private var cachedSecrets: [PluginManifest.SecretSpec] = []
    @State private var showSecretsSheet = false

    private var hasMissingPermissions: Bool { !missingPermissions.isEmpty }
    private var pluginColor: Color {
        plugin.hasLoadError
            ? .red
            : hasMissingPermissions || hasMissingSecrets
                ? .orange
                : theme.accentColor
    }

    private func handleInstallError(_ error: Error) {
        if let installError = error as? PluginInstallError, case .authorKeyMismatch = installError {
            showKeyMismatch = true
        } else {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 12) {
                // Header row: icon + name + menu
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(
                                LinearGradient(
                                    colors: [pluginColor.opacity(0.15), pluginColor.opacity(0.05)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Image(
                            systemName: plugin.hasLoadError
                                ? "exclamationmark.triangle.fill"
                                : "puzzlepiece.extension.fill"
                        )
                        .font(.system(size: 18))
                        .foregroundColor(pluginColor)
                    }
                    .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(plugin.displayName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            if let version = plugin.installedVersion ?? plugin.latestVersion {
                                Text("v\(version.description)", bundle: .module)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(theme.tertiaryText)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(theme.tertiaryBackground))
                            }

                            statusBadge
                        }
                    }

                    Spacer(minLength: 8)

                    cardMenu
                }

                // Description
                if let description = plugin.pluginDescription {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(2)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 0)

                // Compact stats row
                HStack(spacing: 0) {
                    if let caps = plugin.capabilities {
                        let toolCount = caps.tools?.count ?? 0
                        let skillCount = caps.skills?.count ?? 0
                        if toolCount > 0 {
                            statItem(icon: "wrench.and.screwdriver", text: "\(toolCount)")
                        }
                        if toolCount > 0 && skillCount > 0 {
                            statDot
                        }
                        if skillCount > 0 {
                            statItem(icon: "lightbulb", text: "\(skillCount)")
                        }
                    }

                    if plugin.capabilities?.tools?.count ?? 0 > 0 || plugin.capabilities?.skills?.count ?? 0 > 0 {
                        if plugin.authors != nil || plugin.license != nil {
                            statDot
                        }
                    }

                    if let authors = plugin.authors, !authors.isEmpty {
                        statItem(icon: "person", text: authors.joined(separator: ", "))
                    }
                    if plugin.authors != nil && plugin.license != nil {
                        statDot
                    }
                    if let license = plugin.license {
                        statItem(icon: "doc.text", text: license)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(16)
            .background(cardBackground)
            .overlay(hoverGradient)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(cardBorder)
            .shadow(
                color: Color.black.opacity(isHovered ? 0.08 : 0.04),
                radius: isHovered ? 10 : 5,
                x: 0,
                y: isHovered ? 3 : 2
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 20)
        .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(animationDelay), value: hasAppeared)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .onAppear {
            if let loaded = PluginManager.shared.plugins.first(where: { $0.plugin.id == plugin.pluginId }) {
                cachedSecrets = loaded.plugin.manifest.secrets ?? []
            }
            updateSecretsStatus()
        }
        .themedAlert(
            "Error",
            isPresented: $showError,
            message: errorMessage ?? "Unknown error",
            primaryButton: .primary("OK") {}
        )
        .themedAlert(
            "Signing Key Changed",
            isPresented: $showKeyMismatch,
            message:
                "The signing key for \"\(plugin.displayName)\" has changed. Uninstall the plugin and reinstall it to accept the new key.",
            primaryButton: .destructive("Uninstall") {
                guard let onUninstall else { return }
                Task {
                    do {
                        try await onUninstall()
                        onChange?()
                    } catch {
                        errorMessage = error.localizedDescription
                        showError = true
                    }
                }
            },
            secondaryButton: .cancel("Cancel")
        )
        .sheet(isPresented: $showSecretsSheet) {
            ToolSecretsSheet(
                pluginId: plugin.pluginId,
                agentId: Agent.defaultId,
                pluginName: plugin.displayName,
                pluginVersion: plugin.installedVersion?.description,
                secrets: cachedSecrets,
                onSave: {
                    updateSecretsStatus()
                    onChange?()
                }
            )
        }
    }

    // MARK: - Status Badge

    @ViewBuilder
    private var statusBadge: some View {
        if plugin.hasLoadError {
            StatusCapsuleBadge(icon: "exclamationmark.triangle.fill", text: L("Error"), color: .red)
        } else if hasMissingSecrets {
            StatusCapsuleBadge(icon: "key.fill", text: L("Key Required"), color: theme.warningColor)
        } else if hasMissingPermissions {
            StatusCapsuleBadge(icon: "lock.shield", text: L("Permission"), color: theme.warningColor)
        } else if plugin.hasUpdate {
            StatusCapsuleBadge(icon: "arrow.up.circle.fill", text: L("Update"), color: .orange)
        } else if plugin.isInstalled {
            StatusCapsuleBadge(icon: "checkmark.circle.fill", text: L("Installed"), color: .green)
        }
    }

    // MARK: - Card Menu

    @ViewBuilder
    private var cardMenu: some View {
        if plugin.isInstalling {
            ProgressView()
                .scaleEffect(0.7)
                .frame(width: 24, height: 24)
        } else {
            Menu {
                Button(action: onSelect) {
                    Label {
                        Text("View Details", bundle: .module)
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                }
                if plugin.hasUpdate, let onUpgrade {
                    Button {
                        Task {
                            do { try await onUpgrade() } catch { handleInstallError(error) }
                        }
                    } label: {
                        Label {
                            Text("Update", bundle: .module)
                        } icon: {
                            Image(systemName: "arrow.up.circle.fill")
                        }
                    }
                }
                if !cachedSecrets.isEmpty {
                    Button {
                        showSecretsSheet = true
                    } label: {
                        Label(
                            hasMissingSecrets ? L("Configure Secrets") : L("Edit Secrets"),
                            systemImage: "key.fill"
                        )
                    }
                }
                if !plugin.isInstalled, let onInstall {
                    Button {
                        Task {
                            do { try await onInstall() } catch { handleInstallError(error) }
                        }
                    } label: {
                        Label {
                            Text("Install", bundle: .module)
                        } icon: {
                            Image(systemName: "arrow.down.circle.fill")
                        }
                    }
                }
                if plugin.isInstalled, let onUninstall {
                    Divider()
                    Button(role: .destructive) {
                        Task {
                            do { try await onUninstall() } catch {
                                errorMessage = error.localizedDescription
                                showError = true
                            }
                        }
                    } label: {
                        Label {
                            Text("Uninstall", bundle: .module)
                        } icon: {
                            Image(systemName: "trash")
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(theme.tertiaryBackground))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
        }
    }

    // MARK: - Stats

    private func statItem(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(theme.tertiaryText)
    }

    private var statDot: some View {
        Circle()
            .fill(theme.tertiaryText.opacity(0.4))
            .frame(width: 3, height: 3)
            .padding(.horizontal, 8)
    }

    // MARK: - Card Styling

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(theme.cardBackground)
    }

    private var cardBorder: some View {
        let installedHealthy =
            plugin.isInstalled && !plugin.hasLoadError
            && !hasMissingPermissions && !hasMissingSecrets
        return RoundedRectangle(cornerRadius: 12)
            .strokeBorder(
                isHovered
                    ? pluginColor.opacity(0.25)
                    : installedHealthy ? Color.green.opacity(0.2) : theme.cardBorder,
                lineWidth: isHovered ? 1.5 : 1
            )
    }

    private var hoverGradient: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(
                LinearGradient(
                    colors: [
                        pluginColor.opacity(isHovered ? 0.06 : 0),
                        Color.clear,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.15), value: isHovered)
    }

    private func updateSecretsStatus() {
        guard !cachedSecrets.isEmpty else {
            hasMissingSecrets = false
            return
        }
        hasMissingSecrets = AgentManager.shared.agents.contains { agent in
            !ToolSecretsKeychain.hasAllRequiredSecrets(
                specs: cachedSecrets,
                for: plugin.pluginId,
                agentId: agent.id
            )
        }
    }
}

// MARK: - Plugin Detail View

private struct PluginDetailView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    let plugin: PluginState
    let missingPermissions: [SystemPermission]
    let onBack: () -> Void
    let onUpgrade: () async throws -> Void
    let onUninstall: () async throws -> Void
    let onInstall: () async throws -> Void
    let onChange: () -> Void

    @State private var hasAppeared = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showKeyMismatch = false
    @State private var showSecretsSheet = false
    @State private var showDeleteConfirm = false
    /// Confirmation gate for the failed-plugin Retry button — keeps
    /// "tap Retry" separate from "unquarantine + reload" so a user
    /// can't accidentally crash-loop the host on a still-broken
    /// plugin.
    @State private var showRetryConfirm = false
    @State private var readmeContent: String?
    @State private var changelogContent: String?
    @State private var hasMissingSecrets = false
    @State private var cachedSecrets: [PluginManifest.SecretSpec] = []

    private var loadedPlugin: PluginManager.LoadedPlugin? {
        PluginManager.shared.loadedPlugin(for: plugin.pluginId)
    }

    private var pluginColor: Color {
        plugin.hasLoadError ? .red : theme.accentColor
    }

    private func handleInstallError(_ error: Error) {
        if let installError = error as? PluginInstallError, case .authorKeyMismatch = installError {
            showKeyMismatch = true
        } else {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            detailHeaderBar

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    heroHeader
                        .padding(.bottom, 8)

                    if plugin.hasLoadError {
                        errorSection
                    }

                    if hasMissingSecrets && !plugin.hasLoadError {
                        secretsBanner
                    }

                    if !missingPermissions.isEmpty && !plugin.hasLoadError {
                        permissionsBanner
                    }

                    if readmeContent != nil {
                        readmeSection
                    }

                    capabilitiesSection

                    if plugin.isInstalled && !plugin.hasLoadError {
                        routesSection
                    }

                    if changelogContent != nil {
                        changelogSection
                    }

                    externalLinksSection
                }
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .opacity(hasAppeared ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: hasAppeared)
        .onAppear {
            loadPluginData()
            withAnimation { hasAppeared = true }
        }
        .themedAlert(
            L("Error"),
            isPresented: $showError,
            message: errorMessage ?? L("Unknown error"),
            primaryButton: .primary(L("OK")) {}
        )
        .themedAlert(
            L("Signing Key Changed"),
            isPresented: $showKeyMismatch,
            message:
                L(
                    "The signing key for \"\(plugin.displayName)\" has changed. Uninstall the plugin and reinstall it to accept the new key."
                ),
            primaryButton: .destructive(L("Uninstall")) {
                Task {
                    do {
                        try await onUninstall()
                        onChange()
                    } catch {
                        errorMessage = error.localizedDescription
                        showError = true
                    }
                }
            },
            secondaryButton: .cancel(L("Cancel"))
        )
        .themedAlert(
            L("Uninstall Plugin"),
            isPresented: $showDeleteConfirm,
            message: L("Are you sure you want to uninstall \"\(plugin.displayName)\"? This action cannot be undone."),
            primaryButton: .destructive(L("Uninstall")) {
                Task {
                    do {
                        try await onUninstall()
                    } catch {
                        errorMessage = error.localizedDescription
                        showError = true
                    }
                }
            },
            secondaryButton: .cancel(L("Cancel"))
        )
        .themedAlert(
            L("Retry plugin load?"),
            isPresented: $showRetryConfirm,
            message:
                L(
                    "The host quarantined this plugin after it caused a crash during load. Retrying re-runs the same dylib against the same host build, so if the underlying bug (most often a misaligned `osr_host_api` mirror in the plugin) is unfixed it will crash again. Use this only after the plugin has been rebuilt or re-installed. Otherwise, use Uninstall to remove it."
                ),
            primaryButton: .destructive(L("Retry Anyway")) {
                PluginManager.removeFromQuarantine(plugin.pluginId)
                Task {
                    await PluginManager.shared.loadAll(forceReload: true)
                    onChange()
                }
            },
            secondaryButton: .cancel(L("Cancel"))
        )
        .sheet(isPresented: $showSecretsSheet) {
            ToolSecretsSheet(
                pluginId: plugin.pluginId,
                agentId: Agent.defaultId,
                pluginName: plugin.displayName,
                pluginVersion: plugin.installedVersion?.description,
                secrets: cachedSecrets,
                onSave: {
                    updateSecretsStatus()
                    onChange()
                }
            )
        }
    }

    // MARK: - Header Bar

    private var detailHeaderBar: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Plugins", bundle: .module)
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(theme.accentColor)
            }
            .buttonStyle(PlainButtonStyle())

            Spacer()

            HStack(spacing: 6) {
                if plugin.isInstalled {
                    Button {
                        showDeleteConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.errorColor)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(theme.errorColor.opacity(0.1)))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .localizedHelp("Uninstall")
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(
            theme.secondaryBackground
                .overlay(
                    Rectangle()
                        .fill(theme.primaryBorder)
                        .frame(height: 1),
                    alignment: .bottom
                )
        )
    }

    // MARK: - Hero Header

    private var heroHeader: some View {
        HStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            colors: [pluginColor.opacity(0.2), pluginColor.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(pluginColor.opacity(0.3), lineWidth: 2)
                Image(
                    systemName: plugin.hasLoadError
                        ? "exclamationmark.triangle.fill"
                        : "puzzlepiece.extension.fill"
                )
                .font(.system(size: 28))
                .foregroundColor(pluginColor)
            }
            .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(plugin.displayName)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(theme.primaryText)

                    if let version = plugin.installedVersion ?? plugin.latestVersion {
                        Text("v\(version.description)", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.tertiaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(theme.tertiaryBackground))
                    }
                }

                if let description = plugin.pluginDescription {
                    Text(description)
                        .font(.system(size: 13))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(3)
                }

                HStack(spacing: 12) {
                    if let authors = plugin.authors, !authors.isEmpty {
                        heroStatBadge(
                            icon: "person",
                            text: authors.joined(separator: ", "),
                            color: theme.tertiaryText
                        )
                    }
                    if let license = plugin.license {
                        heroStatBadge(icon: "doc.text", text: license, color: theme.tertiaryText)
                    }
                    if let caps = plugin.capabilities {
                        let toolCount = caps.tools?.count ?? 0
                        let skillCount = caps.skills?.count ?? 0
                        if toolCount > 0 {
                            heroStatBadge(icon: "wrench.and.screwdriver", text: L("\(toolCount) tools"), color: .orange)
                        }
                        if skillCount > 0 {
                            heroStatBadge(icon: "lightbulb", text: L("\(skillCount) skills"), color: .cyan)
                        }
                    }
                    if loadedPlugin?.webConfig != nil {
                        heroStatBadge(icon: "globe", text: L("Web App"), color: .purple)
                    }
                }
            }

            Spacer(minLength: 0)

            VStack(spacing: 8) {
                if plugin.isInstalling {
                    ProgressView()
                        .scaleEffect(0.9)
                        .frame(width: 100, height: 36)
                } else if plugin.hasUpdate {
                    Button {
                        Task {
                            do { try await onUpgrade() } catch { handleInstallError(error) }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.up.circle.fill").font(.system(size: 12))
                            Text("Update", bundle: .module).font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange))
                    }
                    .buttonStyle(PlainButtonStyle())
                } else if !plugin.isInstalled {
                    Button {
                        Task {
                            do { try await onInstall() } catch { handleInstallError(error) }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.down.circle.fill").font(.system(size: 12))
                            Text("Install", bundle: .module).font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.accentColor))
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                if plugin.isInstalled && !plugin.hasLoadError,
                    let webConfig = loadedPlugin?.webConfig
                {
                    Button {
                        let port = loadServerPort()
                        // Browsers cannot set the X-Osaurus-Agent-Id header
                        // on top-level navigation; pass the agent id via the
                        // `osr_agent` query param so the server accepts the
                        // initial GET. The injected `window.__osaurus.fetch`
                        // helper then carries it forward to subsequent calls.
                        let agentId = Agent.defaultId.uuidString
                        let url = URL(
                            string:
                                "http://127.0.0.1:\(port)/plugins/\(plugin.pluginId)\(webConfig.mount)?osr_agent=\(agentId)"
                        )!
                        NSWorkspace.shared.open(url)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "globe").font(.system(size: 12))
                            Text("Open Web App", bundle: .module).font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(theme.accentColor)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.accentColor.opacity(0.1))
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
    }

    private func heroStatBadge(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(color)
    }

    // MARK: - Error Section

    private var errorSection: some View {
        Group {
            if let loadError = plugin.loadError {
                if loadError.hasPrefix(PluginManager.PluginLoadError.consentRequiredPrefix) {
                    detailCard {
                        HStack(spacing: 12) {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 20))
                                .foregroundColor(theme.warningColor)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Approval Required", bundle: .module)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(theme.primaryText)
                                Text("This plugin needs your approval before it can load.", bundle: .module)
                                    .font(.system(size: 12))
                                    .foregroundColor(theme.secondaryText)
                            }

                            Spacer()

                            Button {
                                Task {
                                    do {
                                        try PluginManager.shared.grantConsent(pluginId: plugin.pluginId)
                                        await PluginManager.shared.loadAll()
                                        onChange()
                                    } catch {
                                        errorMessage = error.localizedDescription
                                        showError = true
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.shield.fill").font(.system(size: 10))
                                    Text("Approve", bundle: .module).font(.system(size: 12, weight: .semibold))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 6).fill(theme.accentColor))
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                } else {
                    detailCard {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(.red)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Failed to load plugin", bundle: .module)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.red)
                                Text(loadError)
                                    .font(.system(size: 12))
                                    .foregroundColor(theme.secondaryText)
                                    .lineLimit(5)
                            }

                            Spacer()

                            Button {
                                showRetryConfirm = true
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                                    Text("Retry", bundle: .module).font(.system(size: 12, weight: .semibold))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue))
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
            }
        }
    }

    // MARK: - Secrets Banner

    private var secretsBanner: some View {
        detailCard {
            HStack(spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.system(size: 20))
                    .foregroundColor(theme.warningColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("API Keys Required", bundle: .module)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text("This plugin requires credentials to function properly.", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()

                Button {
                    showSecretsSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "key.fill").font(.system(size: 10))
                        Text("Configure", bundle: .module).font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.accentColor))
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    // MARK: - Permissions Banner

    private var permissionsBanner: some View {
        detailCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 20))
                        .foregroundColor(theme.warningColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("System Permissions Required", bundle: .module)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                        Text("Grant the following permissions to use all features:", bundle: .module)
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                    }

                    Spacer()
                }

                HStack(spacing: 8) {
                    ForEach(missingPermissions, id: \.rawValue) { perm in
                        Button {
                            SystemPermissionService.shared.requestPermission(perm)
                            onChange()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: perm.systemIconName).font(.system(size: 11))
                                Text("Grant \(perm.displayName)", bundle: .module).font(
                                    .system(size: 11, weight: .medium)
                                )
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(theme.accentColor))
                        }
                        .buttonStyle(PlainButtonStyle())
                    }

                    Spacer()

                    Button {
                        if let firstPerm = missingPermissions.first {
                            SystemPermissionService.shared.openSystemSettings(for: firstPerm)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "gear").font(.system(size: 10))
                            Text("Open Settings", bundle: .module).font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
    }

    // MARK: - README Section

    private var readmeSection: some View {
        detailSection(title: L("README"), icon: "doc.text.fill") {
            if let content = readmeContent {
                MarkdownMessageView(text: content, baseWidth: 600)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func loadServerPort() -> Int {
        let url = OsaurusPaths.serverConfigFile()
        guard let data = try? Data(contentsOf: url),
            let config = try? JSONDecoder().decode(ServerConfiguration.self, from: data)
        else { return 1337 }
        return config.port
    }

    // MARK: - Capabilities Section

    @ViewBuilder
    private var capabilitiesSection: some View {
        let specTools = plugin.capabilities?.tools ?? []
        let specSkills = plugin.capabilities?.skills ?? []
        if !specTools.isEmpty || !specSkills.isEmpty {
            detailSection(title: L("Capabilities"), icon: "wrench.and.screwdriver.fill") {
                PluginProvidesSummary(tools: specTools, skills: specSkills)
            }
        }
    }

    // MARK: - Routes Section

    @ViewBuilder
    private var routesSection: some View {
        if let loaded = loadedPlugin, !loaded.routes.isEmpty {
            detailSection(title: L("HTTP Routes"), icon: "arrow.left.arrow.right") {
                PluginRoutesSummary(pluginId: plugin.pluginId, routes: loaded.routes)
            }
        }
    }

    // MARK: - Changelog Section

    private var changelogSection: some View {
        detailSection(title: L("Changelog"), icon: "clock.arrow.circlepath") {
            if let content = changelogContent {
                ScrollView {
                    Text(content)
                        .font(.system(size: 12))
                        .foregroundColor(theme.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 300)
            }
        }
    }

    // MARK: - External Links Section

    @ViewBuilder
    private var externalLinksSection: some View {
        if let loaded = loadedPlugin,
            let links = loaded.plugin.manifest.docs?.links,
            !links.isEmpty
        {
            detailSection(title: L("Links"), icon: "link") {
                HStack(spacing: 12) {
                    ForEach(links, id: \.url) { link in
                        Button {
                            if let url = URL(string: link.url) {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "link").font(.system(size: 10))
                                Text(link.label).font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(theme.accentColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(theme.accentColor.opacity(0.1))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - Section Helpers

    private func detailSection<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
            }

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private func detailCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(theme.cardBorder, lineWidth: 1)
                    )
            )
    }

    // MARK: - Data Loading

    private func loadPluginData() {
        if let loaded = PluginManager.shared.plugins.first(where: { $0.plugin.id == plugin.pluginId }) {
            cachedSecrets = loaded.plugin.manifest.secrets ?? []
        }
        updateSecretsStatus()

        if let loaded = loadedPlugin {
            if let path = loaded.readmePath {
                readmeContent = try? String(contentsOf: path, encoding: .utf8)
            }
            if let path = loaded.changelogPath {
                changelogContent = try? String(contentsOf: path, encoding: .utf8)
            }
        }
    }

    private func updateSecretsStatus() {
        guard !cachedSecrets.isEmpty else {
            hasMissingSecrets = false
            return
        }
        hasMissingSecrets = agentManager.agents.contains { agent in
            !ToolSecretsKeychain.hasAllRequiredSecrets(
                specs: cachedSecrets,
                for: plugin.pluginId,
                agentId: agent.id
            )
        }
    }
}

// MARK: - Shared Components

/// Compact pill used by both native and Claude plugin cards to surface a
/// short "Installed" / "Update" / "Error" / "Key Required" state next to
/// the version badge.
struct StatusCapsuleBadge: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 9, weight: .bold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.12)))
        .foregroundColor(color)
        .fixedSize()
    }
}

private struct PluginCapabilitiesBadge: View {
    @Environment(\.theme) private var theme

    let toolCount: Int
    let skillCount: Int

    var body: some View {
        if toolCount > 0 || skillCount > 0 {
            HStack(spacing: 4) {
                if toolCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 9))
                        Text("\(toolCount)", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                if toolCount > 0 && skillCount > 0 {
                    Text("+")
                        .font(.system(size: 9))
                        .foregroundColor(theme.tertiaryText)
                }
                if skillCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "lightbulb")
                            .font(.system(size: 9))
                        Text("\(skillCount)", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                    }
                }
            }
            .foregroundColor(theme.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(theme.tertiaryBackground))
        }
    }
}

private struct PluginProvidesSummary: View {
    @Environment(\.theme) private var theme

    let tools: [RegistryCapabilities.ToolSummary]
    let skills: [RegistryCapabilities.SkillSummary]

    var body: some View {
        if !tools.isEmpty || !skills.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                PluginFlowLayout(spacing: 6) {
                    ForEach(tools, id: \.name) { tool in
                        HStack(spacing: 4) {
                            Image(systemName: "function")
                                .font(.system(size: 9))
                            Text(tool.name)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(theme.tertiaryBackground))
                        .foregroundColor(theme.primaryText)
                        .help(tool.description)
                    }

                    ForEach(skills, id: \.name) { skill in
                        HStack(spacing: 4) {
                            Image(systemName: "lightbulb")
                                .font(.system(size: 9))
                            Text(skill.name)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(theme.accentColor.opacity(0.12)))
                        .foregroundColor(theme.primaryText)
                        .help(skill.description)
                    }
                }
            }
        }
    }
}

// MARK: - Flow Layout for Tool Tags

private struct PluginFlowLayout: Layout {
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

// MARK: - Routes Summary

private struct PluginRoutesSummary: View {
    @Environment(\.theme) private var theme

    let pluginId: String
    let routes: [PluginManifest.RouteSpec]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(routes, id: \.id) { route in
                HStack(spacing: 8) {
                    Text(route.methods.joined(separator: ", "))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(theme.accentColor.opacity(0.12))
                        )

                    Text("/plugins/\(pluginId)\(route.path)", bundle: .module)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)

                    Spacer()

                    Text(route.auth.rawValue)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(authColor(route.auth))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(authColor(route.auth).opacity(0.12))
                        )
                }
            }
        }
    }

    private func authColor(_ auth: PluginManifest.RouteAuth) -> Color {
        switch auth {
        case .none: return .green
        case .verify: return .orange
        case .owner: return .blue
        }
    }
}

// MARK: - Marketplace Category Chips

/// Horizontal, scrollable filter chips for the Claude marketplace. The first
/// chip ("All") clears the filter; each category chip shows its plugin count
/// and adopts the shared category palette color when selected.
private struct MarketplaceCategoryChips: View {
    @Environment(\.theme) private var theme

    let categories: [ClaudeMarketplaceCategory]
    let totalCount: Int
    @Binding var selected: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(key: nil, label: L("All"), count: totalCount, color: theme.accentColor)
                ForEach(categories) { category in
                    chip(
                        key: category.id,
                        label: category.displayName,
                        count: category.count,
                        color: ClaudeMarketplacePalette.color(for: category.id)
                    )
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    private func chip(key: String?, label: String, count: Int, color: Color) -> some View {
        let isSelected = selected == key
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selected = key
            }
        } label: {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundColor(isSelected ? .white.opacity(0.85) : theme.tertiaryText)
            }
            .foregroundColor(isSelected ? .white : theme.secondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected ? color : theme.tertiaryBackground)
            )
            .overlay(
                Capsule()
                    .stroke(
                        isSelected ? Color.clear : theme.cardBorder,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Marketplace Skeleton Card

/// Subtle shimmering placeholder shown while the marketplace catalog loads,
/// so the Browse tab feels alive instead of blank.
private struct MarketplaceSkeletonCard: View {
    @Environment(\.theme) private var theme
    @State private var shimmer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.tertiaryBackground)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 6) {
                    bar(width: 120, height: 12)
                    bar(width: 64, height: 9)
                }
                Spacer()
            }
            bar(width: nil, height: 10)
            bar(width: 220, height: 10)
            Spacer(minLength: 0)
            bar(width: 90, height: 9)
        }
        .frame(height: 132, alignment: .top)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.cardBorder, lineWidth: 1))
        .opacity(shimmer ? 0.55 : 1.0)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: shimmer)
        .onAppear { shimmer = true }
    }

    @ViewBuilder
    private func bar(width: CGFloat?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(theme.tertiaryBackground)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}
