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

    // Success toast
    @State private var successMessage: String?

    var body: some View {
        ZStack {
            if selectedPlugin == nil {
                gridContent
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            reload()
            if repoService.plugins.isEmpty {
                Task {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    await repoService.refresh()
                }
            }
            withAnimation(.easeOut(duration: 0.25).delay(0.1)) {
                hasAppeared = true
            }
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
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            Group {
                switch selectedTab {
                case .installed:
                    installedTabContent
                case .browse:
                    browseTabContent
                }
            }
            .opacity(hasAppeared ? 1 : 0)
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        ManagerHeaderWithTabs(
            title: "Plugins",
            subtitle: "Browse and manage plugins"
        ) {
            HeaderIconButton(
                "arrow.clockwise",
                isLoading: isRefreshButtonLoading,
                help: isRefreshButtonLoading ? "Refreshing..." : "Refresh repository"
            ) {
                Task {
                    isRefreshButtonLoading = true
                    await repoService.refresh()
                    await PluginManager.shared.loadAll()
                    reload()
                    isRefreshButtonLoading = false
                }
            }
        } tabsRow: {
            HeaderTabsRow(
                selection: $selectedTab,
                counts: [
                    .installed: installedPlugins.count,
                    .browse: filteredPlugins.count,
                ],
                badges: updatesAvailableCount > 0
                    ? [.installed: updatesAvailableCount]
                    : nil,
                searchText: $searchText,
                searchPlaceholder: "Search plugins"
            )
        }
    }

    // MARK: - Installed Tab

    private var installedTabContent: some View {
        Group {
            if installedPlugins.isEmpty {
                emptyState(
                    icon: "puzzlepiece.extension",
                    title: "No plugins installed",
                    subtitle: searchText.isEmpty
                        ? "Browse the repository to install plugins"
                        : "Try a different search term"
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
                        }
                    }
                    .padding(24)
                }
            }
        }
    }

    // MARK: - Browse Tab

    private var browseTabContent: some View {
        Group {
            if let errorMessage = repoLastError {
                VStack(spacing: 12) {
                    offlineBanner(message: errorMessage)
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                    browseGrid
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
                browseGrid
            }
        }
    }

    private var browseGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(minimum: 300), spacing: 20),
                    GridItem(.flexible(minimum: 300), spacing: 20),
                ],
                spacing: 20
            ) {
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

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading repository...")
                .font(.system(size: 14))
                .foregroundColor(theme.secondaryText)
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
                Text("Retry")
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

    private func updateFilteredLists() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentPlugins = repoService.plugins

        let (browseResult, installedResult) =
            await Task.detached(priority: .userInitiated) {
                let browse = currentPlugins.filter { Self.pluginMatchesQuery($0, query: query) }
                let installed =
                    currentPlugins
                    .filter { $0.isInstalled && Self.pluginMatchesQuery($0, query: query) }
                    .sorted { $0.displayName < $1.displayName }
                return (browse, installed)
            }.value

        guard !Task.isCancelled else { return }

        filteredPlugins = browseResult
        installedPlugins = installedResult

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

#Preview {
    PluginsView()
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
                                Text("v\(version.description)")
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
            StatusCapsuleBadge(icon: "exclamationmark.triangle.fill", text: "Error", color: .red)
        } else if hasMissingSecrets {
            StatusCapsuleBadge(icon: "key.fill", text: "Key Required", color: theme.warningColor)
        } else if hasMissingPermissions {
            StatusCapsuleBadge(icon: "lock.shield", text: "Permission", color: theme.warningColor)
        } else if plugin.hasUpdate {
            StatusCapsuleBadge(icon: "arrow.up.circle.fill", text: "Update", color: .orange)
        } else if plugin.isInstalled {
            StatusCapsuleBadge(icon: "checkmark.circle.fill", text: "Installed", color: .green)
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
                    Label("View Details", systemImage: "info.circle")
                }
                if plugin.hasUpdate, let onUpgrade {
                    Button {
                        Task {
                            do { try await onUpgrade() } catch {
                                errorMessage = error.localizedDescription
                                showError = true
                            }
                        }
                    } label: {
                        Label("Update", systemImage: "arrow.up.circle.fill")
                    }
                }
                if !cachedSecrets.isEmpty {
                    Button {
                        showSecretsSheet = true
                    } label: {
                        Label(
                            hasMissingSecrets ? "Configure Secrets" : "Edit Secrets",
                            systemImage: "key.fill"
                        )
                    }
                }
                if !plugin.isInstalled, let onInstall {
                    Button {
                        Task {
                            do { try await onInstall() } catch {
                                errorMessage = error.localizedDescription
                                showError = true
                            }
                        }
                    } label: {
                        Label("Install", systemImage: "arrow.down.circle.fill")
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
                        Label("Uninstall", systemImage: "trash")
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
        let mgr = AgentManager.shared
        hasMissingSecrets = mgr.agents.contains { agent in
            mgr.isPluginEnabled(plugin.pluginId, for: agent.id)
                && !ToolSecretsKeychain.hasAllRequiredSecrets(
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
    @ObservedObject private var relayManager = RelayTunnelManager.shared
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
    @State private var showSecretsSheet = false
    @State private var showDeleteConfirm = false
    @State private var readmeContent: String?
    @State private var changelogContent: String?
    @State private var hasMissingSecrets = false
    @State private var cachedSecrets: [PluginManifest.SecretSpec] = []
    @State private var copiedURL: String?
    @State private var expandedAgents: Set<UUID> = []
    @State private var showRelayConfirmation = false
    @State private var pendingRelayAgentId: UUID?

    private var loadedPlugin: PluginManager.LoadedPlugin? {
        PluginManager.shared.loadedPlugin(for: plugin.pluginId)
    }

    private var pluginColor: Color {
        plugin.hasLoadError ? .red : theme.accentColor
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

                    if plugin.isInstalled && !plugin.hasLoadError {
                        agentsSection
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
            "Error",
            isPresented: $showError,
            message: errorMessage ?? "Unknown error",
            primaryButton: .primary("OK") {}
        )
        .themedAlert(
            "Uninstall Plugin",
            isPresented: $showDeleteConfirm,
            message: "Are you sure you want to uninstall \"\(plugin.displayName)\"? This action cannot be undone.",
            primaryButton: .destructive("Uninstall") {
                Task {
                    do {
                        try await onUninstall()
                    } catch {
                        errorMessage = error.localizedDescription
                        showError = true
                    }
                }
            },
            secondaryButton: .cancel("Cancel")
        )
        .themedAlert(
            "Expose Agent to Internet?",
            isPresented: $showRelayConfirmation,
            message:
                "This will create a public URL for this agent via agent.osaurus.ai. Anyone with the URL can send requests to your local server. Your access keys still protect the API endpoints.",
            primaryButton: .destructive("Enable Relay") {
                if let id = pendingRelayAgentId {
                    relayManager.setTunnelEnabled(true, for: id)
                }
                pendingRelayAgentId = nil
            },
            secondaryButton: .cancel("Cancel") {
                pendingRelayAgentId = nil
            }
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
                    Text("Plugins")
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
                    .help("Uninstall")
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
                        Text("v\(version.description)")
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
                            heroStatBadge(icon: "wrench.and.screwdriver", text: "\(toolCount) tools", color: .orange)
                        }
                        if skillCount > 0 {
                            heroStatBadge(icon: "lightbulb", text: "\(skillCount) skills", color: .cyan)
                        }
                    }
                    if loadedPlugin?.webConfig != nil {
                        heroStatBadge(icon: "globe", text: "Web App", color: .purple)
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
                            do { try await onUpgrade() } catch {
                                errorMessage = error.localizedDescription
                                showError = true
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.up.circle.fill").font(.system(size: 12))
                            Text("Update").font(.system(size: 13, weight: .semibold))
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
                            do { try await onInstall() } catch {
                                errorMessage = error.localizedDescription
                                showError = true
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.down.circle.fill").font(.system(size: 12))
                            Text("Install").font(.system(size: 13, weight: .semibold))
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
                        let url = URL(string: "http://127.0.0.1:\(port)/plugins/\(plugin.pluginId)\(webConfig.mount)")!
                        NSWorkspace.shared.open(url)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "globe").font(.system(size: 12))
                            Text("Open Web App").font(.system(size: 13, weight: .semibold))
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
                                Text("Approval Required")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(theme.primaryText)
                                Text("This plugin needs your approval before it can load.")
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
                                    Text("Approve").font(.system(size: 12, weight: .semibold))
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
                                Text("Failed to load plugin")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.red)
                                Text(loadError)
                                    .font(.system(size: 12))
                                    .foregroundColor(theme.secondaryText)
                                    .lineLimit(5)
                            }

                            Spacer()

                            Button {
                                Task {
                                    await PluginManager.shared.loadAll()
                                    onChange()
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                                    Text("Retry").font(.system(size: 12, weight: .semibold))
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
                    Text("API Keys Required")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text("This plugin requires credentials to function properly.")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()

                Button {
                    showSecretsSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "key.fill").font(.system(size: 10))
                        Text("Configure").font(.system(size: 12, weight: .semibold))
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
                        Text("System Permissions Required")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                        Text("Grant the following permissions to use all features:")
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
                                Text("Grant \(perm.displayName)").font(.system(size: 11, weight: .medium))
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
                            Text("Open Settings").font(.system(size: 11, weight: .medium))
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
        detailSection(title: "README", icon: "doc.text.fill") {
            if let content = readmeContent {
                MarkdownMessageView(text: content, baseWidth: 600)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Agents Section (toggle + config + endpoints per agent)

    private var agentsSection: some View {
        let customAgents = agentManager.agents
            .filter { !$0.isBuiltIn }
            .sorted { $0.name < $1.name }

        return detailSection(title: "Agents", icon: "person.2") {
            if customAgents.isEmpty {
                VStack(spacing: 8) {
                    Text("No agents yet")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                    Text("Create an agent in the Agents tab to enable this plugin.")
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(customAgents.enumerated()), id: \.element.id) { idx, agent in
                        if idx > 0 {
                            Divider().opacity(0.4).padding(.vertical, 2)
                        }
                        agentPluginRow(agent: agent)
                    }
                }
            }
        }
    }

    private func agentPluginRow(agent: Agent) -> some View {
        let isEnabled = agentManager.isPluginEnabled(plugin.pluginId, for: agent.id)
        let isExpanded = expandedAgents.contains(agent.id)
        let hasConfig = loadedPlugin?.plugin.manifest.capabilities.config != nil
        let hasRoutes = !(loadedPlugin?.routes.isEmpty ?? true)
        let canExpand = isEnabled && (hasConfig || hasRoutes)
        let tunnelStatus = relayManager.agentStatuses[agent.id]
        let tunnelURL: String? = {
            if case .connected(let baseURL) = tunnelStatus {
                return "\(baseURL)/plugins/\(plugin.pluginId)"
            }
            return nil
        }()

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { isEnabled },
                        set: { newValue in
                            agentManager.setPluginEnabled(newValue, plugin: plugin.pluginId, for: agent.id)
                            if !newValue {
                                expandedAgents.remove(agent.id)
                            }
                        }
                    )
                )
                .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                .labelsHidden()

                Text(agent.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)

                Spacer()

                if canExpand {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .padding(10)
            .contentShape(Rectangle())
            .onTapGesture {
                guard canExpand else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedAgents.remove(agent.id)
                    } else {
                        expandedAgents.insert(agent.id)
                    }
                }
            }

            if isEnabled && isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    if hasRoutes {
                        agentRelaySection(agent: agent, tunnelStatus: tunnelStatus, tunnelURL: tunnelURL)
                    }

                    if let loaded = loadedPlugin,
                        let configSpec = loaded.plugin.manifest.capabilities.config
                    {
                        PluginConfigView(
                            pluginId: plugin.pluginId,
                            agentId: agent.id,
                            configSpec: configSpec,
                            plugin: loaded.plugin
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isEnabled ? theme.tertiaryBackground.opacity(0.3) : Color.clear)
        )
    }

    @ViewBuilder
    private func agentRelaySection(agent: Agent, tunnelStatus: AgentRelayStatus?, tunnelURL: String?) -> some View {
        let isRelayEnabled = relayManager.isTunnelEnabled(for: agent.id)
        let hasIdentity = agent.agentAddress != nil && agent.agentIndex != nil
        let isConnected = tunnelURL != nil

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 12))
                    .foregroundColor(isConnected ? theme.successColor : theme.accentColor)
                Text("Relay")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Spacer()

                if hasIdentity {
                    relayStatusBadge(
                        tunnelStatus: tunnelStatus,
                        isConnected: isConnected,
                        isEnabled: isRelayEnabled
                    )

                    Toggle(
                        "",
                        isOn: Binding(
                            get: { isRelayEnabled },
                            set: { newValue in
                                if newValue {
                                    pendingRelayAgentId = agent.id
                                    showRelayConfirmation = true
                                } else {
                                    relayManager.setTunnelEnabled(false, for: agent.id)
                                }
                            }
                        )
                    )
                    .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                    .labelsHidden()
                }
            }

            if !hasIdentity {
                Text("Set up an identity for this agent in Agent Details to enable relay.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            } else if let url = tunnelURL {
                urlRow(label: "Tunnel", url: url)
            } else if !isRelayEnabled {
                Text(
                    "This plugin uses webhooks to receive messages. Enable relay to create a public URL that forwards requests to your local server."
                )
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.tertiaryBackground.opacity(0.3))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            (isConnected ? theme.successColor : theme.accentColor).opacity(0.2),
                            lineWidth: 1
                        )
                )
        )
    }

    @ViewBuilder
    private func relayStatusBadge(tunnelStatus: AgentRelayStatus?, isConnected: Bool, isEnabled: Bool) -> some View {
        if case .connecting = tunnelStatus {
            statusDot(label: "Connecting...", color: theme.warningColor)
        } else if case .error(let msg) = tunnelStatus {
            statusDot(label: msg, color: theme.errorColor)
        } else if isConnected {
            statusDot(label: "Connected", color: theme.successColor)
        } else if isEnabled {
            statusDot(label: "Start server", color: theme.warningColor, textColor: theme.secondaryText)
        }
    }

    private func statusDot(label: String, color: Color, textColor: Color? = nil) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(textColor ?? color)
                .lineLimit(1)
        }
    }

    private func urlRow(label: String, url: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(label == "Tunnel" ? theme.accentColor : theme.tertiaryText)
                .frame(width: 44, alignment: .leading)

            Text(url)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(label == "Tunnel" ? theme.accentColor : theme.secondaryText)
                .textSelection(.enabled)

            Spacer(minLength: 4)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
                copiedURL = url
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if copiedURL == url { copiedURL = nil }
                }
            } label: {
                Image(systemName: copiedURL == url ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(copiedURL == url ? theme.successColor : theme.tertiaryText)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(theme.tertiaryBackground))
            }
            .buttonStyle(PlainButtonStyle())
            .help("Copy URL")
        }
        .padding(.leading, 18)
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
            detailSection(title: "Capabilities", icon: "wrench.and.screwdriver.fill") {
                PluginProvidesSummary(tools: specTools, skills: specSkills)
            }
        }
    }

    // MARK: - Routes Section

    @ViewBuilder
    private var routesSection: some View {
        if let loaded = loadedPlugin, !loaded.routes.isEmpty {
            detailSection(title: "HTTP Routes", icon: "arrow.left.arrow.right") {
                PluginRoutesSummary(pluginId: plugin.pluginId, routes: loaded.routes)
            }
        }
    }

    // MARK: - Changelog Section

    private var changelogSection: some View {
        detailSection(title: "Changelog", icon: "clock.arrow.circlepath") {
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
            detailSection(title: "Links", icon: "link") {
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
            agentManager.isPluginEnabled(plugin.pluginId, for: agent.id)
                && !ToolSecretsKeychain.hasAllRequiredSecrets(
                    specs: cachedSecrets,
                    for: plugin.pluginId,
                    agentId: agent.id
                )
        }
    }
}

// MARK: - Shared Components

private struct StatusCapsuleBadge: View {
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
                        Text("\(toolCount)")
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
                        Text("\(skillCount)")
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

                    Text("/plugins/\(pluginId)\(route.path)")
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
