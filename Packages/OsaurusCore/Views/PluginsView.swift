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
    @ObservedObject private var repoService = PluginRepositoryService.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var selectedTab: PluginsTab = .installed
    @State private var searchText: String = ""
    @State private var hasAppeared = false
    @State private var isRefreshing = false

    // Cached filtered results
    @State private var toolEntries: [ToolRegistry.ToolEntry] = []
    @State private var filteredPlugins: [PluginState] = []
    @State private var installedPluginsWithTools: [(plugin: PluginState, tools: [ToolRegistry.ToolEntry])] = []
    @State private var pluginsWithMissingPermissionsCount: Int = 0

    // Secrets sheet state for post-installation prompt
    @State private var showSecretsSheet: Bool = false
    @State private var secretsSheetPluginId: String?
    @State private var secretsSheetPluginName: String?
    @State private var secretsSheetPluginVersion: String?
    @State private var secretsSheetSecrets: [PluginManifest.SecretSpec] = []

    var body: some View {
        VStack(spacing: 0) {
            // Header with tabs and search
            headerBar
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            // Content area
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
        .task(id: repoService.plugins) { await updateFilteredLists() }
        .onReceive(NotificationCenter.default.publisher(for: .toolsListChanged)) { _ in
            reload()
        }
        .onChange(of: repoService.pendingSecretsPlugin) { _, newValue in
            if let pluginId = newValue {
                showSecretsSheetForPlugin(pluginId: pluginId)
                repoService.pendingSecretsPlugin = nil
            }
        }
        .sheet(isPresented: $showSecretsSheet) {
            if let pluginId = secretsSheetPluginId {
                ToolSecretsSheet(
                    pluginId: pluginId,
                    pluginName: secretsSheetPluginName ?? pluginId,
                    pluginVersion: secretsSheetPluginVersion,
                    secrets: secretsSheetSecrets,
                    onSave: {
                        reload()
                        Task { await updateFilteredLists() }
                    }
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
                isLoading: isRefreshing,
                help: isRefreshing ? "Refreshing..." : "Refresh repository"
            ) {
                Task {
                    isRefreshing = true
                    await repoService.refresh()
                    PluginManager.shared.loadAll()
                    reload()
                    isRefreshing = false
                }
            }
        } tabsRow: {
            HeaderTabsRow(
                selection: $selectedTab,
                counts: [
                    .installed: installedPluginsWithTools.count,
                    .browse: filteredPlugins.count,
                ],
                badges: repoService.updatesAvailableCount > 0
                    ? [.installed: repoService.updatesAvailableCount]
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
                    description: "Manage your installed plugins and their tools"
                )

                let plugins = installedPluginsWithTools

                if plugins.isEmpty {
                    emptyState(
                        icon: "puzzlepiece.extension",
                        title: "No plugins installed",
                        subtitle: searchText.isEmpty
                            ? "Browse the repository to install plugins"
                            : "Try a different search term"
                    )
                } else {
                    // Permission status banner
                    if pluginsWithMissingPermissionsCount > 0 {
                        ToolPermissionBanner(count: pluginsWithMissingPermissionsCount)
                    }

                    ForEach(plugins, id: \.plugin.id) { item in
                        InstalledPluginCard(
                            plugin: item.plugin,
                            tools: item.tools,
                            repoService: repoService
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

                if repoService.isRefreshing && repoService.plugins.isEmpty {
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
                            repoService: repoService
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

    // MARK: - Helpers

    private func updateFilteredLists() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryLower = query.lowercased()
        let currentToolEntries = toolEntries
        let currentPlugins = repoService.plugins

        let (filteredPluginsResult, installedPluginsResult) =
            await Task.detached(priority: .userInitiated) {

                // 1. Filtered Plugins (for Browse tab)
                let filteredPlugins: [PluginState]
                if query.isEmpty {
                    filteredPlugins = currentPlugins
                } else {
                    filteredPlugins = currentPlugins.filter { plugin in
                        let candidates = [
                            plugin.spec.plugin_id.lowercased(),
                            (plugin.spec.name ?? "").lowercased(),
                            (plugin.spec.description ?? "").lowercased(),
                        ]
                        return candidates.contains { SearchService.fuzzyMatch(query: queryLower, in: $0) }
                    }
                }

                // 2. Installed Plugins with Tools (for Installed tab)
                let installedPlugins =
                    currentPlugins
                    .filter { $0.isInstalled }
                    .compactMap { plugin -> (plugin: PluginState, tools: [ToolRegistry.ToolEntry])? in
                        let specTools = plugin.spec.capabilities?.tools ?? []
                        let toolNames = Set(specTools.map { $0.name })
                        var matchedTools = currentToolEntries.filter { toolNames.contains($0.name) }

                        if !query.isEmpty {
                            let pluginMatches = [
                                plugin.spec.plugin_id.lowercased(),
                                (plugin.spec.name ?? "").lowercased(),
                                (plugin.spec.description ?? "").lowercased(),
                            ].contains { SearchService.fuzzyMatch(query: queryLower, in: $0) }

                            if !pluginMatches {
                                matchedTools = matchedTools.filter { tool in
                                    let candidates = [tool.name.lowercased(), tool.description.lowercased()]
                                    return candidates.contains { SearchService.fuzzyMatch(query: queryLower, in: $0) }
                                }
                            }

                            if matchedTools.isEmpty && !pluginMatches && !plugin.hasLoadError { return nil }
                        }

                        if matchedTools.isEmpty && !plugin.hasLoadError { return nil }

                        return (plugin, matchedTools)
                    }
                    .sorted {
                        ($0.plugin.spec.name ?? $0.plugin.spec.plugin_id)
                            < ($1.plugin.spec.name ?? $1.plugin.spec.plugin_id)
                    }

                return (filteredPlugins, installedPlugins)
            }.value

        guard !Task.isCancelled else { return }

        filteredPlugins = filteredPluginsResult
        installedPluginsWithTools = installedPluginsResult

        // Calculate plugins with missing permissions
        var permissionCount = 0
        for (_, tools) in installedPluginsResult {
            for tool in tools {
                if let info = ToolRegistry.shared.policyInfo(for: tool.name) {
                    if info.systemPermissionStates.values.contains(false) {
                        permissionCount += 1
                        break
                    }
                }
            }
        }
        pluginsWithMissingPermissionsCount = permissionCount
    }

    private func reload() {
        toolEntries = ToolRegistry.shared.listTools()
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
    let tools: [ToolRegistry.ToolEntry]
    @ObservedObject var repoService: PluginRepositoryService
    let onChange: () -> Void

    @State private var isExpanded: Bool = false
    @State private var isHovering = false
    @State private var errorMessage: String?
    @State private var showError: Bool = false
    @State private var showSecretsSheet: Bool = false

    @State private var missingSystemPermissions: [SystemPermission] = []
    @State private var hasMissingSecrets: Bool = false

    private var hasMissingPermissions: Bool {
        !missingSystemPermissions.isEmpty
    }

    private var pluginSecrets: [PluginManifest.SecretSpec] {
        if let loaded = PluginManager.shared.plugins.first(where: { $0.plugin.id == plugin.spec.plugin_id }) {
            return loaded.plugin.manifest.secrets ?? []
        }
        return []
    }

    private var hasSecrets: Bool {
        !pluginSecrets.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Plugin header
            HStack(spacing: 14) {
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                }) {
                    HStack(spacing: 14) {
                        // Plugin icon
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

                        // Plugin info
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(plugin.spec.name ?? plugin.spec.plugin_id)
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
                                    loadErrorBadge
                                } else if hasMissingSecrets {
                                    secretsWarningBadge
                                } else if hasMissingPermissions {
                                    permissionWarningBadge
                                } else if plugin.hasUpdate {
                                    updateBadge
                                }
                            }

                            if let description = plugin.spec.description {
                                Text(description)
                                    .font(.system(size: 13))
                                    .foregroundColor(theme.secondaryText)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        if !tools.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "wrench.and.screwdriver")
                                    .font(.system(size: 10))
                                Text("\(tools.count) tool\(tools.count == 1 ? "" : "s")")
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

                // Action buttons
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

            // Error message
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

            // Secrets warning banner
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

            // Permission warning banner
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
                        ForEach(missingSystemPermissions, id: \.rawValue) { perm in
                            Button(action: {
                                SystemPermissionService.shared.requestPermission(perm)
                                updatePermissions()
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
                            if let firstPerm = missingSystemPermissions.first {
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

            // Tools list (expandable)
            if isExpanded && !tools.isEmpty && !plugin.hasLoadError {
                Divider()
                    .padding(.vertical, 4)

                VStack(spacing: 8) {
                    ForEach(tools, id: \.id) { entry in
                        ToolEntryRow(entry: entry, onChange: onChange)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(cardBackground)
        .onHover { hovering in
            isHovering = hovering
        }
        .onAppear {
            updatePermissions()
            updateSecretsStatus()
        }
        .onChange(of: tools.map { $0.id }) { _, _ in
            updatePermissions()
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
                pluginId: plugin.spec.plugin_id,
                pluginName: plugin.spec.name ?? plugin.spec.plugin_id,
                pluginVersion: plugin.installedVersion?.description,
                secrets: pluginSecrets,
                onSave: {
                    updateSecretsStatus()
                    onChange()
                }
            )
        }
    }

    private func updatePermissions() {
        var missing = Set<SystemPermission>()
        for tool in tools {
            if let info = ToolRegistry.shared.policyInfo(for: tool.name) {
                for (perm, granted) in info.systemPermissionStates {
                    if !granted {
                        missing.insert(perm)
                    }
                }
            }
        }
        missingSystemPermissions = Array(missing).sorted { $0.rawValue < $1.rawValue }
    }

    private func updateSecretsStatus() {
        let secrets = pluginSecrets
        if secrets.isEmpty {
            hasMissingSecrets = false
        } else {
            hasMissingSecrets = !ToolSecretsKeychain.hasAllRequiredSecrets(
                specs: secrets,
                for: plugin.spec.plugin_id
            )
        }
    }

    private var cardBackground: some View {
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
    }

    private var updateBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 10))
            Text("Update")
                .font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Color.orange.opacity(0.15))
        )
        .foregroundColor(.orange)
    }

    private var loadErrorBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text("Error")
                .font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Color.red.opacity(0.15))
        )
        .foregroundColor(.red)
    }

    private var permissionWarningBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.shield")
                .font(.system(size: 10))
            Text("Needs Permission")
                .font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(theme.warningColor.opacity(0.15))
        )
        .foregroundColor(theme.warningColor)
    }

    private var secretsWarningBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "key.fill")
                .font(.system(size: 10))
            Text("Needs API Key")
                .font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(theme.warningColor.opacity(0.15))
        )
        .foregroundColor(theme.warningColor)
    }

    private func retryLoad() {
        PluginManager.shared.loadAll()
        onChange()
    }

    private func upgrade() {
        Task {
            do {
                try await repoService.upgrade(pluginId: plugin.spec.plugin_id)
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func uninstall() {
        do {
            try repoService.uninstall(pluginId: plugin.spec.plugin_id)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - Plugin Browse Row

private struct PluginBrowseRow: View {
    @Environment(\.theme) private var theme
    let plugin: PluginState
    @ObservedObject var repoService: PluginRepositoryService

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
                                Text(plugin.spec.name ?? plugin.spec.plugin_id)
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
                                    updateBadge
                                }
                            }

                            if let description = plugin.spec.description {
                                Text(description)
                                    .font(.system(size: 13))
                                    .foregroundColor(theme.secondaryText)
                                    .lineLimit(isExpanded ? nil : 1)
                            }
                        }

                        Spacer()

                        if let tools = plugin.spec.capabilities?.tools, !tools.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "wrench.and.screwdriver")
                                    .font(.system(size: 10))
                                Text("\(tools.count) tool\(tools.count == 1 ? "" : "s")")
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

                actionButton
            }

            if isExpanded {
                HStack(spacing: 12) {
                    if let authors = plugin.spec.authors, !authors.isEmpty {
                        Label(authors.joined(separator: ", "), systemImage: "person")
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                    }

                    if let license = plugin.spec.license {
                        Label(license, systemImage: "doc.text")
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                    }
                }
                .padding(.leading, 58)

                if let tools = plugin.spec.capabilities?.tools, !tools.isEmpty {
                    Divider()
                        .padding(.vertical, 4)

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
                                .background(
                                    Capsule()
                                        .fill(theme.tertiaryBackground)
                                )
                                .foregroundColor(theme.primaryText)
                                .help(tool.description)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(cardBackground)
        .onHover { hovering in
            isHovering = hovering
        }
        .themedAlert(
            "Installation Error",
            isPresented: $showError,
            message: errorMessage ?? "Unknown error",
            primaryButton: .primary("OK") {}
        )
    }

    private var cardBackground: some View {
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
    }

    private var updateBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 10))
            Text("Update")
                .font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Color.orange.opacity(0.15))
        )
        .foregroundColor(.orange)
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
                try await repoService.install(pluginId: plugin.spec.plugin_id)
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func upgrade() {
        Task {
            do {
                try await repoService.upgrade(pluginId: plugin.spec.plugin_id)
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func uninstall() {
        do {
            try repoService.uninstall(pluginId: plugin.spec.plugin_id)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
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
