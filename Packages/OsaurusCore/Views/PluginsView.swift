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

    // Snapshot values from service (updated via .onReceive / reload)
    @State private var isRepoRefreshing = false
    @State private var updatesAvailableCount = 0
    @State private var repoLastError: String?
    @State private var missingPermissionsPerPlugin: [String: [SystemPermission]] = [:]

    // Cached filtered results
    @State private var filteredPlugins: [PluginState] = []
    @State private var installedPlugins: [PluginState] = []
    @State private var pluginsWithMissingPermissionsCount = 0

    // Secrets sheet state for post-installation prompt
    @State private var showSecretsSheet: Bool = false
    @State private var secretsSheetPluginId: String?
    @State private var secretsSheetPluginName: String?
    @State private var secretsSheetPluginVersion: String?
    @State private var secretsSheetSecrets: [PluginManifest.SecretSpec] = []

    var body: some View {
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
        .onReceive(PluginRepositoryService.shared.$plugins) { _ in
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
                    pluginName: secretsSheetPluginName ?? pluginId,
                    pluginVersion: secretsSheetPluginVersion,
                    secrets: secretsSheetSecrets,
                    onSave: { reload() }
                )
            }
        }
    }

    /// Show the secrets sheet for a specific plugin
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
        ScrollView {
            LazyVStack(spacing: 16) {
                SectionHeader(
                    title: "Installed Plugins",
                    description: "Manage your installed plugins"
                )

                if installedPlugins.isEmpty {
                    emptyState(
                        icon: "puzzlepiece.extension",
                        title: "No plugins installed",
                        subtitle: searchText.isEmpty
                            ? "Browse the repository to install plugins"
                            : "Try a different search term"
                    )
                } else {
                    if pluginsWithMissingPermissionsCount > 0 {
                        ToolPermissionBanner(count: pluginsWithMissingPermissionsCount)
                    }

                    ForEach(installedPlugins, id: \.id) { plugin in
                        InstalledPluginCard(
                            plugin: plugin,
                            missingPermissions: missingPermissionsPerPlugin[plugin.pluginId] ?? [],
                            onUpgrade: { try await repoService.upgrade(pluginId: plugin.pluginId) },
                            onUninstall: { try await repoService.uninstall(pluginId: plugin.pluginId) }
                        ) {
                            reload()
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Browse Tab

    private var browseTabContent: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                SectionHeader(
                    title: "Plugin Repository",
                    description: "Browse and install plugins to add new capabilities"
                )
                .padding(.bottom, 4)

                if let errorMessage = repoLastError {
                    offlineBanner(message: errorMessage)
                }

                if isRepoRefreshing && filteredPlugins.isEmpty {
                    loadingState
                } else if filteredPlugins.isEmpty {
                    emptyState(
                        icon: "puzzlepiece.extension",
                        title: searchText.isEmpty ? "No plugins available" : "No plugins match your search",
                        subtitle: searchText.isEmpty ? nil : "Try a different search term"
                    )
                } else {
                    ForEach(filteredPlugins, id: \.id) { plugin in
                        PluginBrowseRow(
                            plugin: plugin,
                            onInstall: { try await repoService.install(pluginId: plugin.pluginId) },
                            onUpgrade: { try await repoService.upgrade(pluginId: plugin.pluginId) },
                            onUninstall: { try await repoService.uninstall(pluginId: plugin.pluginId) }
                        )
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
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
        .frame(maxWidth: .infinity)
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
        .frame(maxWidth: .infinity)
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

    // MARK: - Helpers

    /// Whether a plugin matches the current search query.
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

        // Calculate per-plugin missing permissions from capability tool names
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

// MARK: - Installed Plugin Card

private struct InstalledPluginCard: View {
    @Environment(\.theme) private var theme
    let plugin: PluginState
    let missingPermissions: [SystemPermission]
    let onUpgrade: () async throws -> Void
    let onUninstall: () async throws -> Void
    let onChange: () -> Void

    @State private var isExpanded: Bool = false
    @State private var isHovering = false
    @State private var errorMessage: String?
    @State private var showError: Bool = false
    @State private var showSecretsSheet: Bool = false

    @State private var hasMissingSecrets: Bool = false
    @State private var cachedSecrets: [PluginManifest.SecretSpec] = []

    private var hasMissingPermissions: Bool {
        !missingPermissions.isEmpty
    }

    private var hasSecrets: Bool {
        !cachedSecrets.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                }) {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(
                                    plugin.hasLoadError
                                        ? Color.red.opacity(0.12)
                                        : hasMissingPermissions
                                            ? theme.warningColor.opacity(0.12)
                                            : theme.accentColor.opacity(0.12)
                                )
                            Image(
                                systemName: plugin.hasLoadError
                                    ? "exclamationmark.triangle.fill"
                                    : "puzzlepiece.extension.fill"
                            )
                            .font(.system(size: 20))
                            .foregroundColor(
                                plugin.hasLoadError
                                    ? .red
                                    : hasMissingPermissions
                                        ? theme.warningColor
                                        : theme.accentColor
                            )

                            if hasMissingPermissions && !plugin.hasLoadError {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(theme.warningColor)
                                    .background(Circle().fill(theme.cardBackground).padding(-2))
                                    .offset(x: 16, y: -16)
                            }
                        }
                        .frame(width: 44, height: 44)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(plugin.displayName)
                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                    .foregroundColor(theme.primaryText)

                                if let version = plugin.installedVersion {
                                    Text("v\(version.description)")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(theme.tertiaryText)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            Capsule()
                                                .fill(theme.tertiaryBackground)
                                        )
                                }

                                if plugin.hasLoadError {
                                    StatusCapsuleBadge(
                                        icon: "exclamationmark.triangle.fill",
                                        text: "Error",
                                        color: .red
                                    )
                                } else if hasMissingSecrets {
                                    StatusCapsuleBadge(
                                        icon: "key.fill",
                                        text: "Needs API Key",
                                        color: theme.warningColor
                                    )
                                } else if hasMissingPermissions {
                                    StatusCapsuleBadge(
                                        icon: "lock.shield",
                                        text: "Needs Permission",
                                        color: theme.warningColor
                                    )
                                } else if plugin.hasUpdate {
                                    StatusCapsuleBadge(icon: "arrow.up.circle.fill", text: "Update", color: .orange)
                                }
                            }

                            if let description = plugin.pluginDescription {
                                Text(description)
                                    .font(.system(size: 13))
                                    .foregroundColor(theme.secondaryText)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        PluginCapabilitiesBadge(
                            toolCount: plugin.capabilities?.tools?.count ?? 0,
                            skillCount: plugin.capabilities?.skills?.count ?? 0
                        )

                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.tertiaryText)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())

                HStack(spacing: 8) {
                    if plugin.isInstalling {
                        ProgressView()
                            .scaleEffect(0.8)
                            .frame(width: 32, height: 32)
                    } else if plugin.hasLoadError {
                        Button(action: { retryLoad() }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11))
                                Text("Retry")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.blue)
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                    } else if plugin.hasUpdate {
                        Button(action: { upgrade() }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 11))
                                Text("Update")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.orange)
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }

                    Menu {
                        if plugin.hasLoadError {
                            Button {
                                retryLoad()
                            } label: {
                                Label("Retry Loading", systemImage: "arrow.clockwise")
                            }
                        }
                        if hasSecrets {
                            Button {
                                showSecretsSheet = true
                            } label: {
                                Label(
                                    hasMissingSecrets ? "Configure Secrets" : "Edit Secrets",
                                    systemImage: "key.fill"
                                )
                            }
                        }
                        Button(role: .destructive) {
                            uninstall()
                            onChange()
                        } label: {
                            Label("Uninstall", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 16))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(theme.tertiaryBackground.opacity(isHovering ? 1 : 0))
                            )
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            if isExpanded, let loadError = plugin.loadError {
                Divider()
                    .padding(.vertical, 4)

                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.red)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Failed to load plugin")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.red)
                        Text(loadError)
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(3)
                    }

                    Spacer()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.red.opacity(0.08))
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if isExpanded && hasMissingSecrets && !plugin.hasLoadError {
                Divider()
                    .padding(.vertical, 4)

                HStack(spacing: 12) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 16))
                        .foregroundColor(theme.warningColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("API Keys Required")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                        Text("This plugin requires credentials to function properly.")
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                    }

                    Spacer()

                    Button(action: { showSecretsSheet = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "key.fill")
                                .font(.system(size: 10))
                            Text("Configure")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.accentColor)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.warningColor.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(theme.warningColor.opacity(0.2), lineWidth: 1)
                        )
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if isExpanded && hasMissingPermissions && !plugin.hasLoadError {
                Divider()
                    .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 16))
                            .foregroundColor(theme.warningColor)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("System Permissions Required")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                            Text("Grant the following permissions to use all features of this plugin:")
                                .font(.system(size: 11))
                                .foregroundColor(theme.secondaryText)
                        }

                        Spacer()
                    }

                    HStack(spacing: 8) {
                        ForEach(missingPermissions, id: \.rawValue) { perm in
                            Button(action: {
                                SystemPermissionService.shared.requestPermission(perm)
                                onChange()
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: perm.systemIconName)
                                        .font(.system(size: 11))
                                    Text("Grant \(perm.displayName)")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(theme.accentColor)
                                )
                            }
                            .buttonStyle(PlainButtonStyle())
                        }

                        Spacer()

                        Button(action: {
                            if let firstPerm = missingPermissions.first {
                                SystemPermissionService.shared.openSystemSettings(for: firstPerm)
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "gear")
                                    .font(.system(size: 10))
                                Text("Open Settings")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(theme.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(theme.tertiaryBackground)
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.warningColor.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(theme.warningColor.opacity(0.2), lineWidth: 1)
                        )
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Read-only capabilities summary
            if isExpanded && !plugin.hasLoadError {
                let specTools = plugin.capabilities?.tools ?? []
                let specSkills = plugin.capabilities?.skills ?? []
                if !specTools.isEmpty || !specSkills.isEmpty {
                    Divider()
                        .padding(.vertical, 4)

                    PluginProvidesSummary(tools: specTools, skills: specSkills)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            // Plugin config UI (rendered from manifest config spec)
            if isExpanded && !plugin.hasLoadError {
                if let loaded = PluginManager.shared.plugins.first(where: { $0.plugin.id == plugin.pluginId }),
                    let configSpec = loaded.plugin.manifest.capabilities.config
                {
                    Divider()
                        .padding(.vertical, 4)

                    PluginConfigView(
                        pluginId: plugin.pluginId,
                        configSpec: configSpec,
                        plugin: loaded.plugin
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            // Routes summary
            if isExpanded && !plugin.hasLoadError {
                if let loaded = PluginManager.shared.loadedPlugin(for: plugin.pluginId),
                    !loaded.routes.isEmpty
                {
                    Divider()
                        .padding(.vertical, 4)

                    PluginRoutesSummary(pluginId: plugin.pluginId, routes: loaded.routes)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            // Documentation (README, links)
            if isExpanded && !plugin.hasLoadError {
                if let loaded = PluginManager.shared.loadedPlugin(for: plugin.pluginId) {
                    let manifest = loaded.plugin.manifest

                    if loaded.readmePath != nil || manifest.docs?.links != nil {
                        Divider()
                            .padding(.vertical, 4)

                        PluginDocsSection(
                            readmePath: loaded.readmePath,
                            changelogPath: loaded.changelogPath,
                            docLinks: manifest.docs?.links
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(PluginCardBackground(isHovering: isHovering))
        .onHover { isHovering = $0 }
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

    private func updateSecretsStatus() {
        hasMissingSecrets =
            !cachedSecrets.isEmpty
            && !ToolSecretsKeychain.hasAllRequiredSecrets(specs: cachedSecrets, for: plugin.pluginId)
    }

    private func retryLoad() {
        Task {
            await PluginManager.shared.loadAll()
            onChange()
        }
    }

    private func upgrade() {
        Task {
            do {
                try await onUpgrade()
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func uninstall() {
        Task {
            do {
                try await onUninstall()
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}

// MARK: - Plugin Browse Row

private struct PluginBrowseRow: View {
    @Environment(\.theme) private var theme
    let plugin: PluginState
    let onInstall: () async throws -> Void
    let onUpgrade: () async throws -> Void
    let onUninstall: () async throws -> Void

    @State private var errorMessage: String?
    @State private var showError: Bool = false
    @State private var isHovering = false
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                }) {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(theme.accentColor.opacity(0.12))
                            Image(systemName: "puzzlepiece.extension.fill")
                                .font(.system(size: 20))
                                .foregroundColor(theme.accentColor)
                        }
                        .frame(width: 44, height: 44)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(plugin.displayName)
                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                    .foregroundColor(theme.primaryText)

                                if let version = plugin.latestVersion {
                                    Text("v\(version.description)")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(theme.tertiaryText)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            Capsule()
                                                .fill(theme.tertiaryBackground)
                                        )
                                }

                                if plugin.hasUpdate {
                                    StatusCapsuleBadge(icon: "arrow.up.circle.fill", text: "Update", color: .orange)
                                }
                            }

                            if let description = plugin.pluginDescription {
                                Text(description)
                                    .font(.system(size: 13))
                                    .foregroundColor(theme.secondaryText)
                                    .lineLimit(isExpanded ? nil : 1)
                            }
                        }

                        Spacer()

                        PluginCapabilitiesBadge(
                            toolCount: plugin.capabilities?.tools?.count ?? 0,
                            skillCount: plugin.capabilities?.skills?.count ?? 0
                        )

                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.tertiaryText)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())

                actionButton
            }

            if isExpanded {
                HStack(spacing: 12) {
                    if let authors = plugin.authors, !authors.isEmpty {
                        Label(authors.joined(separator: ", "), systemImage: "person")
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                    }

                    if let license = plugin.license {
                        Label(license, systemImage: "doc.text")
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                    }
                }
                .padding(.leading, 58)

                let specTools = plugin.capabilities?.tools ?? []
                let specSkills = plugin.capabilities?.skills ?? []
                if !specTools.isEmpty || !specSkills.isEmpty {
                    Divider()
                        .padding(.vertical, 4)

                    PluginProvidesSummary(tools: specTools, skills: specSkills)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(PluginCardBackground(isHovering: isHovering))
        .onHover { isHovering = $0 }
        .themedAlert(
            "Installation Error",
            isPresented: $showError,
            message: errorMessage ?? "Unknown error",
            primaryButton: .primary("OK") {}
        )
    }

    @ViewBuilder
    private var actionButton: some View {
        if plugin.isInstalling {
            ProgressView()
                .scaleEffect(0.8)
                .frame(width: 90, height: 32)
        } else if plugin.hasUpdate {
            Button(action: { upgrade() }) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 12))
                    Text("Update")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange)
                )
            }
            .buttonStyle(PlainButtonStyle())
        } else if plugin.isInstalled {
            Menu {
                Button(role: .destructive) {
                    uninstall()
                } label: {
                    Label("Uninstall", systemImage: "trash")
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                    Text("Installed")
                        .font(.system(size: 13, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundColor(theme.successColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.successColor.opacity(0.1))
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        } else {
            Button(action: { install() }) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 12))
                    Text("Install")
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

    private func install() {
        Task {
            do {
                try await onInstall()
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func upgrade() {
        Task {
            do {
                try await onUpgrade()
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func uninstall() {
        Task {
            do {
                try await onUninstall()
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}

// MARK: - Shared Components

/// Small status capsule badge (e.g. "Update", "Error", "Needs Permission").
private struct StatusCapsuleBadge: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.15)))
        .foregroundColor(color)
    }
}

/// Reusable badge showing tool and skill counts for a plugin.
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

/// Read-only "Provides:" summary showing tool/skill name capsules.
private struct PluginProvidesSummary: View {
    @Environment(\.theme) private var theme

    let tools: [RegistryCapabilities.ToolSummary]
    let skills: [RegistryCapabilities.SkillSummary]

    var body: some View {
        if !tools.isEmpty || !skills.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Provides:")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)

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

/// Card background with hover-sensitive border used by both installed and browse cards.
private struct PluginCardBackground: View {
    @Environment(\.theme) private var theme
    let isHovering: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(theme.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isHovering ? theme.accentColor.opacity(0.2) : theme.cardBorder,
                        lineWidth: 1
                    )
            )
            .shadow(
                color: theme.shadowColor.opacity(theme.shadowOpacity),
                radius: theme.cardShadowRadius,
                x: 0,
                y: theme.cardShadowY
            )
            .drawingGroup()
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
            Text("HTTP Routes:")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.secondaryText)

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

// MARK: - Documentation Section

private struct PluginDocsSection: View {
    @Environment(\.theme) private var theme

    let readmePath: URL?
    let changelogPath: URL?
    let docLinks: [PluginManifest.DocLink]?

    @State private var selectedDocTab: DocTab = .readme
    @State private var readmeContent: String?
    @State private var changelogContent: String?

    enum DocTab: String, CaseIterable {
        case readme = "README"
        case changelog = "Changelog"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("Documentation")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                Spacer()

                if readmePath != nil || changelogPath != nil {
                    HStack(spacing: 0) {
                        if readmePath != nil {
                            docTabButton(.readme)
                        }
                        if changelogPath != nil {
                            docTabButton(.changelog)
                        }
                    }
                }
            }

            // Content area
            if selectedDocTab == .readme, let content = readmeContent {
                ScrollView {
                    Text(content)
                        .font(.system(size: 12))
                        .foregroundColor(theme.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 300)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.primaryBackground.opacity(0.5))
                )
            } else if selectedDocTab == .changelog, let content = changelogContent {
                ScrollView {
                    Text(content)
                        .font(.system(size: 12))
                        .foregroundColor(theme.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 300)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.primaryBackground.opacity(0.5))
                )
            }

            // External links
            if let links = docLinks, !links.isEmpty {
                HStack(spacing: 12) {
                    ForEach(links, id: \.url) { link in
                        Button {
                            if let url = URL(string: link.url) {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "link")
                                    .font(.system(size: 10))
                                Text(link.label)
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(theme.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .onAppear {
            loadDocs()
            if readmePath == nil && changelogPath != nil {
                selectedDocTab = .changelog
            }
        }
    }

    @ViewBuilder
    private func docTabButton(_ tab: DocTab) -> some View {
        Button {
            selectedDocTab = tab
        } label: {
            Text(tab.rawValue)
                .font(.system(size: 11, weight: selectedDocTab == tab ? .semibold : .regular))
                .foregroundColor(selectedDocTab == tab ? theme.accentColor : theme.tertiaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(selectedDocTab == tab ? theme.accentColor.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    private func loadDocs() {
        if let path = readmePath {
            readmeContent = try? String(contentsOf: path, encoding: .utf8)
        }
        if let path = changelogPath {
            changelogContent = try? String(contentsOf: path, encoding: .utf8)
        }
    }
}
