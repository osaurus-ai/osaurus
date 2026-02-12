//
//  ToolsManagerView.swift
//  osaurus
//
//  Manage tools: view all available tools and configure remote providers.
//

import AppKit
import Foundation
import OsaurusRepository
import SwiftUI

struct ToolsManagerView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private let repoService = PluginRepositoryService.shared
    private let providerManager = MCPProviderManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var selectedTab: ToolsTab = .available
    @State private var searchText: String = ""
    @State private var hasAppeared = false
    @State private var isRefreshingInstalled = false

    // Snapshot values from services (updated via .onReceive / reload)
    @State private var toolEntries: [ToolRegistry.ToolEntry] = []
    @State private var remoteProviderCount: Int = 0
    @State private var policyInfoCache: [String: ToolRegistry.ToolPolicyInfo] = [:]

    // Cached filtered results
    @State private var filteredEntries: [ToolRegistry.ToolEntry] = []
    @State private var installedPluginsWithTools: [(plugin: PluginState, tools: [ToolRegistry.ToolEntry])] = []
    @State private var remoteProviderTools: [(provider: MCPProvider, tools: [ToolRegistry.ToolEntry])] = []
    @State private var pluginsWithMissingPermissionsCount: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            headerBar
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            Group {
                switch selectedTab {
                case .available:
                    availableToolsTabContent
                case .remote:
                    ProvidersView()
                }
            }
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            reload()
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
        .onReceive(NotificationCenter.default.publisher(for: .toolsListChanged)) { _ in
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: Foundation.Notification.Name.mcpProviderStatusChanged)) {
            _ in
            remoteProviderCount = providerManager.configuration.providers.count
            reload()
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        ManagerHeaderWithTabs(
            title: "Tools",
            subtitle: "Manage and discover tools"
        ) {
            HeaderIconButton(
                "arrow.clockwise",
                isLoading: isRefreshingInstalled,
                help: isRefreshingInstalled ? "Refreshing..." : "Reload tools"
            ) {
                Task {
                    isRefreshingInstalled = true
                    await PluginManager.shared.loadAll()
                    reload()
                    isRefreshingInstalled = false
                }
            }
        } tabsRow: {
            HeaderTabsRow(
                selection: $selectedTab,
                counts: [
                    .available: filteredEntries.count,
                    .remote: remoteProviderCount,
                ],
                searchText: $searchText,
                searchPlaceholder: "Search tools"
            )
        }
    }

    // MARK: - Available Tools Tab (shows all tools from plugins and providers)

    private var availableToolsTabContent: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                SectionHeader(
                    title: "Available Tools",
                    description: "Tools from installed plugins and connected providers"
                )

                let plugins = installedPluginsWithTools
                let remoteTools = remoteProviderTools

                if plugins.isEmpty && remoteTools.isEmpty {
                    emptyState(
                        icon: "wrench.and.screwdriver",
                        title: "No tools available",
                        subtitle: searchText.isEmpty
                            ? "Install plugins or connect to remote providers to add tools"
                            : "Try a different search term"
                    )
                } else {
                    if pluginsWithMissingPermissionsCount > 0 {
                        ToolPermissionBanner(count: pluginsWithMissingPermissionsCount)
                    }

                    if !plugins.isEmpty {
                        InstalledSectionHeader(title: "Plugin Tools", icon: "puzzlepiece.extension")

                        ForEach(plugins, id: \.plugin.id) { item in
                            ToolPluginCard(
                                plugin: item.plugin,
                                tools: item.tools,
                                policyInfoCache: policyInfoCache
                            ) {
                                reload()
                            }
                        }
                    }

                    if !remoteTools.isEmpty {
                        InstalledSectionHeader(title: "Remote Tools", icon: "server.rack")

                        ForEach(remoteTools, id: \.provider.id) { item in
                            RemoteProviderToolsCard(
                                provider: item.provider,
                                tools: item.tools,
                                providerState: providerManager.providerStates[item.provider.id],
                                policyInfoCache: policyInfoCache,
                                onDisconnect: {
                                    providerManager.disconnect(providerId: item.provider.id)
                                },
                                onChange: {
                                    reload()
                                }
                            )
                        }
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

    // MARK: - Helpers

    private func updateFilteredLists() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryLower = query.lowercased()
        let currentToolEntries = toolEntries
        let currentPlugins = repoService.plugins
        let currentProviders = providerManager.configuration.providers
        let currentProviderStates = providerManager.providerStates

        let (filteredEntriesResult, installedPluginsResult, remoteToolsResult) =
            await Task.detached(priority: .userInitiated) {

                // 1. Filtered Entries (for counts)
                let filteredEntries: [ToolRegistry.ToolEntry]
                if query.isEmpty {
                    filteredEntries = currentToolEntries
                } else {
                    filteredEntries = currentToolEntries.filter { e in
                        let candidates = [e.name.lowercased(), e.description.lowercased()]
                        return candidates.contains { SearchService.fuzzyMatch(query: queryLower, in: $0) }
                    }
                }

                // 2. Installed Plugins with Tools (for Available tab)
                let installedPlugins =
                    currentPlugins
                    .filter { $0.isInstalled }
                    .compactMap { plugin -> (plugin: PluginState, tools: [ToolRegistry.ToolEntry])? in
                        let capabilityTools = plugin.capabilities?.tools ?? []
                        let toolNames = Set(capabilityTools.map { $0.name })
                        var matchedTools = currentToolEntries.filter { toolNames.contains($0.name) }

                        if !query.isEmpty {
                            let pluginMatches = [
                                plugin.pluginId.lowercased(),
                                (plugin.name ?? "").lowercased(),
                                (plugin.pluginDescription ?? "").lowercased(),
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
                        $0.plugin.displayName < $1.plugin.displayName
                    }

                // 3. Remote Provider Tools (for Available tab)
                let remoteTools =
                    currentProviders
                    .filter { provider in
                        currentProviderStates[provider.id]?.isConnected == true
                    }
                    .compactMap { provider -> (provider: MCPProvider, tools: [ToolRegistry.ToolEntry])? in
                        let safeProviderName = provider.name
                            .lowercased()
                            .replacingOccurrences(of: " ", with: "_")
                            .replacingOccurrences(of: "-", with: "_")
                            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
                        let prefix = "\(safeProviderName)_"

                        var matchedTools = currentToolEntries.filter { $0.name.hasPrefix(prefix) }

                        if !query.isEmpty {
                            let providerMatches =
                                SearchService.matches(query: query, in: provider.name)
                                || SearchService.matches(query: query, in: provider.url)

                            if !providerMatches {
                                matchedTools = matchedTools.filter { tool in
                                    SearchService.matches(query: query, in: tool.name)
                                        || SearchService.matches(query: query, in: tool.description)
                                }
                            }

                            if matchedTools.isEmpty && !providerMatches { return nil }
                        }

                        if matchedTools.isEmpty { return nil }
                        return (provider, matchedTools)
                    }
                    .sorted { $0.provider.name < $1.provider.name }

                return (filteredEntries, installedPlugins, remoteTools)
            }.value

        guard !Task.isCancelled else { return }

        filteredEntries = filteredEntriesResult
        installedPluginsWithTools = installedPluginsResult
        remoteProviderTools = remoteToolsResult

        // Build policy info cache once for all tools
        var cache: [String: ToolRegistry.ToolPolicyInfo] = [:]
        for entry in currentToolEntries {
            if let info = ToolRegistry.shared.policyInfo(for: entry.name) {
                cache[entry.name] = info
            }
        }
        policyInfoCache = cache

        // Calculate plugins with missing permissions using the cache
        var permissionCount = 0
        for (_, tools) in installedPluginsResult {
            for tool in tools {
                if let info = cache[tool.name] {
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
        remoteProviderCount = providerManager.configuration.providers.count
        Task { await updateFilteredLists() }
    }
}

#Preview {
    ToolsManagerView()
}

// MARK: - Permission Status Banner (shared with PluginsView)

struct ToolPermissionBanner: View {
    @Environment(\.theme) private var theme
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(theme.warningColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 16))
                    .foregroundColor(theme.warningColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("\(count) plugin\(count == 1 ? "" : "s") need\(count == 1 ? "s" : "") system permissions")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text("Expand each plugin to grant the required permissions")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            Button(action: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "gear")
                        .font(.system(size: 11))
                    Text("System Settings")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(theme.accentColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.accentColor.opacity(0.1))
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.warningColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.warningColor.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

// MARK: - Installed Section Header

private struct InstalledSectionHeader: View {
    @Environment(\.theme) private var theme
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.accentColor)
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(theme.secondaryText)
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }
}

// MARK: - Tool Plugin Card

private struct ToolPluginCard: View {
    @Environment(\.theme) private var theme
    let plugin: PluginState
    let tools: [ToolRegistry.ToolEntry]
    let policyInfoCache: [String: ToolRegistry.ToolPolicyInfo]
    let onChange: () -> Void

    @State private var isExpanded: Bool = false
    @State private var isHovering = false

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
                                        : theme.accentColor.opacity(0.12)
                                )
                            Image(
                                systemName: plugin.hasLoadError
                                    ? "exclamationmark.triangle.fill"
                                    : "puzzlepiece.extension.fill"
                            )
                            .font(.system(size: 20))
                            .foregroundColor(
                                plugin.hasLoadError ? .red : theme.accentColor
                            )
                        }
                        .frame(width: 44, height: 44)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(plugin.displayName)
                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                    .foregroundColor(theme.primaryText)

                                if plugin.hasLoadError {
                                    HStack(spacing: 4) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.system(size: 10))
                                        Text("Error")
                                            .font(.system(size: 10, weight: .semibold))
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color.red.opacity(0.15)))
                                    .foregroundColor(.red)
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

            if isExpanded && !tools.isEmpty && !plugin.hasLoadError {
                Divider()
                    .padding(.vertical, 4)

                LazyVStack(spacing: 8) {
                    ForEach(tools, id: \.id) { entry in
                        ToolEntryRow(entry: entry, policyInfo: policyInfoCache[entry.name], onChange: onChange)
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
            .drawingGroup()
    }
}

// MARK: - Remote Provider Tools Card

private struct RemoteProviderToolsCard: View {
    @Environment(\.theme) private var theme
    let provider: MCPProvider
    let tools: [ToolRegistry.ToolEntry]
    let providerState: MCPProviderState?
    let policyInfoCache: [String: ToolRegistry.ToolPolicyInfo]
    let onDisconnect: () -> Void
    let onChange: () -> Void

    @State private var isExpanded: Bool = false
    @State private var isHovering = false

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
                            Image(systemName: "server.rack")
                                .font(.system(size: 20))
                                .foregroundColor(theme.accentColor)
                        }
                        .frame(width: 44, height: 44)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(provider.name)
                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                    .foregroundColor(theme.primaryText)

                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(theme.successColor)
                                        .frame(width: 6, height: 6)
                                    Text("Connected")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(theme.successColor)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(theme.successColor.opacity(0.12)))
                            }

                            Text(provider.url)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(theme.tertiaryText)
                                .lineLimit(1)
                        }

                        Spacer()

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

                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.tertiaryText)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())

                Menu {
                    Button(action: onDisconnect) {
                        Label("Disconnect", systemImage: "bolt.slash")
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

            if isExpanded && !tools.isEmpty {
                Divider()
                    .padding(.vertical, 4)

                LazyVStack(spacing: 8) {
                    ForEach(tools, id: \.id) { entry in
                        RemoteToolRow(
                            entry: entry,
                            providerName: provider.name,
                            policyInfo: policyInfoCache[entry.name],
                            onChange: onChange
                        )
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
            .drawingGroup()
    }
}

// MARK: - Tool Policy Helpers

/// Shared helpers for tool permission policy display.
enum ToolPolicyStyle {
    static func icon(for policy: ToolPermissionPolicy) -> String {
        switch policy {
        case .auto: "sparkles"
        case .ask: "questionmark.circle"
        case .deny: "xmark.circle"
        }
    }

    static func color(for policy: ToolPermissionPolicy, theme: ThemeProtocol) -> Color {
        switch policy {
        case .auto: theme.accentColor
        case .ask: .orange
        case .deny: theme.errorColor
        }
    }
}

// MARK: - Tool Policy Menu

/// Reusable policy selector menu for a single tool entry.
private struct ToolPolicyMenu: View {
    @Environment(\.theme) private var theme
    let toolName: String
    let info: ToolRegistry.ToolPolicyInfo
    let onChange: () -> Void

    var body: some View {
        Menu {
            ForEach([ToolPermissionPolicy.auto, .ask, .deny], id: \.self) { policy in
                Button {
                    ToolRegistry.shared.setPolicy(policy, for: toolName)
                    onChange()
                } label: {
                    HStack {
                        Image(systemName: ToolPolicyStyle.icon(for: policy))
                            .foregroundColor(ToolPolicyStyle.color(for: policy, theme: theme))
                        Text(policy.rawValue.capitalized)
                            .foregroundColor(ToolPolicyStyle.color(for: policy, theme: theme))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: ToolPolicyStyle.icon(for: info.effectivePolicy))
                    .font(.system(size: 9))
                    .foregroundColor(ToolPolicyStyle.color(for: info.effectivePolicy, theme: theme))
                Text(info.effectivePolicy.rawValue.capitalized)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(ToolPolicyStyle.color(for: info.effectivePolicy, theme: theme))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(ToolPolicyStyle.color(for: info.effectivePolicy, theme: theme).opacity(0.12))
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - Tool Enable Toggle

/// Reusable toggle for enabling/disabling a tool.
private struct ToolEnableToggle: View {
    let entry: ToolRegistry.ToolEntry
    let onChange: () -> Void

    var body: some View {
        Toggle(
            "",
            isOn: Binding(
                get: { entry.enabled },
                set: { newValue in
                    ToolRegistry.shared.setEnabled(newValue, for: entry.name)
                    onChange()
                }
            )
        )
        .toggleStyle(SwitchToggleStyle())
        .labelsHidden()
        .scaleEffect(0.85)
    }
}

// MARK: - Tool Entry Row (shared with PluginsView)

struct ToolEntryRow: View {
    @Environment(\.theme) private var theme
    let entry: ToolRegistry.ToolEntry
    let policyInfo: ToolRegistry.ToolPolicyInfo?
    let onChange: () -> Void

    private var hasMissingSystemPermissions: Bool {
        guard let info = policyInfo else { return false }
        return info.systemPermissionStates.values.contains(false)
    }

    var body: some View {
        HStack(spacing: 10) {
            toolIcon
            toolInfo
            Spacer()

            if let info = policyInfo {
                ToolPolicyMenu(
                    toolName: entry.name,
                    info: info,
                    onChange: onChange
                )
            }

            ToolEnableToggle(entry: entry, onChange: onChange)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.tertiaryBackground.opacity(0.5))
        )
    }

    private var toolIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    hasMissingSystemPermissions
                        ? theme.warningColor.opacity(0.1) : theme.accentColor.opacity(0.08)
                )
            Image(systemName: "function")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(hasMissingSystemPermissions ? theme.warningColor : theme.accentColor)

            if hasMissingSystemPermissions {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8))
                    .foregroundColor(theme.warningColor)
                    .offset(x: 10, y: -10)
            }
        }
        .frame(width: 28, height: 28)
    }

    private var toolInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(entry.name)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(theme.primaryText)

                if hasMissingSystemPermissions {
                    Text("Needs Permission")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(theme.warningColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(theme.warningColor.opacity(0.12))
                        )
                }
            }
            Text(entry.description)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .lineLimit(1)
        }
    }
}

// MARK: - Remote Tool Row

private struct RemoteToolRow: View {
    @Environment(\.theme) private var theme
    let entry: ToolRegistry.ToolEntry
    let providerName: String
    let policyInfo: ToolRegistry.ToolPolicyInfo?
    let onChange: () -> Void

    private var displayName: String {
        let safeProviderName =
            providerName
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
        let prefix = "\(safeProviderName)_"
        if entry.name.hasPrefix(prefix) {
            return String(entry.name.dropFirst(prefix.count))
        }
        return entry.name
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.accentColor.opacity(0.08))
                Image(systemName: "function")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.accentColor)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(theme.primaryText)
                Text(entry.description)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
            }

            Spacer()

            if let info = policyInfo {
                ToolPolicyMenu(
                    toolName: entry.name,
                    info: info,
                    onChange: onChange
                )
            }

            ToolEnableToggle(entry: entry, onChange: onChange)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.tertiaryBackground.opacity(0.5))
        )
    }
}
