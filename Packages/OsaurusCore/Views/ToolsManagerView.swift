//
//  ToolsManagerView.swift
//  osaurus
//
//  Manage tools: search and toggle enablement, browse and install plugins.
//

import AppKit
import CryptoKit
import Foundation
import OsaurusRepository
import SwiftUI

struct ToolsManagerView: View {
    @StateObject private var themeManager = ThemeManager.shared
    @ObservedObject private var repoService = PluginRepositoryService.shared
    @ObservedObject private var providerManager = MCPProviderManager.shared

    /// Use computed property to always get the current theme from ThemeManager
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var selectedTab: ToolsTab = .available
    @State private var searchText: String = ""
    @State private var toolEntries: [ToolRegistry.ToolEntry] = []
    @State private var hasAppeared = false
    @State private var isRefreshingInstalled = false

    var body: some View {
        VStack(spacing: 0) {
            contentView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            reload()
            // Trigger initial refresh if repository is empty
            if repoService.plugins.isEmpty {
                Task {
                    // Small delay to prevent initial jank
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    await repoService.refresh()
                }
            }
            // Animate content appearance
            withAnimation(.easeOut(duration: 0.25).delay(0.1)) {
                hasAppeared = true
            }
        }
        .onChange(of: searchText) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .toolsListChanged)) { _ in
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: Foundation.Notification.Name.mcpProviderStatusChanged)) {
            _ in
            reload()
        }
    }

    private var contentView: some View {
        VStack(spacing: 0) {
            // Header with tabs and search
            headerBar
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            // Content area
            Group {
                switch selectedTab {
                case .available:
                    availableToolsTabContent
                case .plugins:
                    pluginsTabContent
                case .remote:
                    ProvidersView()
                }
            }
            .opacity(hasAppeared ? 1 : 0)
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        VStack(spacing: 16) {
            // Title row
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tools")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(theme.primaryText)

                    Text("Manage and discover tools")
                        .font(.system(size: 14))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()
            }

            // Tabs + Actions row - simplified
            HStack(spacing: 12) {
                AnimatedTabSelector(
                    selection: $selectedTab,
                    counts: [
                        .available: filteredEntries.count,
                        .plugins: filteredPlugins.count,
                        .remote: providerManager.configuration.providers.count,
                    ],
                    badges: repoService.updatesAvailableCount > 0
                        ? [.available: repoService.updatesAvailableCount]
                        : nil
                )

                Spacer()

                // Contextual action button
                if selectedTab == .available {
                    Button(action: {
                        Task { await repoService.refresh() }
                    }) {
                        Group {
                            if repoService.isRefreshing {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 16, height: 16)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 13, weight: .medium))
                            }
                        }
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.tertiaryBackground)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(repoService.isRefreshing)
                    .help(repoService.isRefreshing ? "Refreshing..." : "Refresh repository")
                } else {
                    Button(action: {
                        Task {
                            isRefreshingInstalled = true
                            await repoService.refresh()
                            PluginManager.shared.loadAll()
                            reload()
                            isRefreshingInstalled = false
                        }
                    }) {
                        Group {
                            if isRefreshingInstalled {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 16, height: 16)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 13, weight: .medium))
                            }
                        }
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.tertiaryBackground)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(isRefreshingInstalled)
                    .help(isRefreshingInstalled ? "Refreshing..." : "Reload tools")
                }

                SearchField(text: $searchText, placeholder: "Search tools")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .background(theme.secondaryBackground)
    }

    // MARK: - Available Tools Tab (shows all tools from plugins and providers)

    /// Count of plugins that have tools with missing system permissions
    private var pluginsWithMissingPermissions: Int {
        var count = 0
        for (_, tools) in installedPluginsWithTools {
            for tool in tools {
                if let info = ToolRegistry.shared.policyInfo(for: tool.name) {
                    if info.systemPermissionStates.values.contains(false) {
                        count += 1
                        break
                    }
                }
            }
        }
        return count
    }

    /// Remote provider tools grouped by provider
    private var remoteProviderTools: [(provider: MCPProvider, tools: [ToolRegistry.ToolEntry])] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return providerManager.configuration.providers
            .filter { provider in
                // Only include connected providers
                providerManager.providerStates[provider.id]?.isConnected == true
            }
            .compactMap { provider -> (provider: MCPProvider, tools: [ToolRegistry.ToolEntry])? in
                // Get the tool name prefix for this provider
                let safeProviderName = provider.name
                    .lowercased()
                    .replacingOccurrences(of: " ", with: "_")
                    .replacingOccurrences(of: "-", with: "_")
                    .filter { $0.isLetter || $0.isNumber || $0 == "_" }
                let prefix = "\(safeProviderName)_"

                // Filter tools that belong to this provider
                var matchedTools = toolEntries.filter { $0.name.hasPrefix(prefix) }

                // Apply search filter
                if !query.isEmpty {
                    let providerMatches =
                        provider.name.lowercased().contains(query)
                        || provider.url.lowercased().contains(query)

                    if !providerMatches {
                        matchedTools = matchedTools.filter { tool in
                            tool.name.lowercased().contains(query)
                                || tool.description.lowercased().contains(query)
                        }
                    }

                    if matchedTools.isEmpty && !providerMatches { return nil }
                }

                if matchedTools.isEmpty { return nil }
                return (provider, matchedTools)
            }
            .sorted { $0.provider.name < $1.provider.name }
    }

    private var availableToolsTabContent: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                // Section header
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
                    // Permission status banner
                    if pluginsWithMissingPermissions > 0 {
                        PermissionStatusBanner(count: pluginsWithMissingPermissions)
                    }

                    // Plugin tools section
                    if !plugins.isEmpty {
                        InstalledSectionHeader(title: "Plugin Tools", icon: "puzzlepiece.extension")

                        ForEach(Array(plugins.enumerated()), id: \.element.plugin.id) { index, item in
                            InstalledPluginCard(
                                plugin: item.plugin,
                                tools: item.tools,
                                repoService: repoService,
                                animationIndex: index
                            ) {
                                reload()
                            }
                        }
                    }

                    // Remote provider tools section
                    if !remoteTools.isEmpty {
                        InstalledSectionHeader(title: "Remote Tools", icon: "server.rack")

                        ForEach(Array(remoteTools.enumerated()), id: \.element.provider.id) { index, item in
                            RemoteProviderToolsCard(
                                provider: item.provider,
                                tools: item.tools,
                                providerState: providerManager.providerStates[item.provider.id],
                                animationIndex: index,
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
        }
    }

    // MARK: - Plugins Tab (browse and install plugins)

    private var pluginsTabContent: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                // Section header
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
                    ForEach(Array(filteredPlugins.enumerated()), id: \.element.id) { index, plugin in
                        PluginRow(
                            plugin: plugin,
                            repoService: repoService,
                            animationIndex: index
                        )
                    }
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

    private var filteredEntries: [ToolRegistry.ToolEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return toolEntries }
        return toolEntries.filter { e in
            let candidates = [e.name.lowercased(), e.description.lowercased()]
            let q = query.lowercased()
            return candidates.contains { SearchService.fuzzyMatch(query: q, in: $0) }
        }
    }

    private var filteredPlugins: [PluginState] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return repoService.plugins }
        let q = query.lowercased()
        return repoService.plugins.filter { plugin in
            let candidates = [
                plugin.spec.plugin_id.lowercased(),
                (plugin.spec.name ?? "").lowercased(),
                (plugin.spec.description ?? "").lowercased(),
            ]
            return candidates.contains { SearchService.fuzzyMatch(query: q, in: $0) }
        }
    }

    /// Installed plugins with their tool entries (includes plugins with load errors)
    private var installedPluginsWithTools: [(plugin: PluginState, tools: [ToolRegistry.ToolEntry])] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return repoService.plugins
            .filter { $0.isInstalled }
            .compactMap { plugin -> (plugin: PluginState, tools: [ToolRegistry.ToolEntry])? in
                let specTools = plugin.spec.capabilities?.tools ?? []
                let toolNames = Set(specTools.map { $0.name })
                var matchedTools = toolEntries.filter { toolNames.contains($0.name) }

                // Apply search filter
                if !query.isEmpty {
                    let pluginMatches = [
                        plugin.spec.plugin_id.lowercased(),
                        (plugin.spec.name ?? "").lowercased(),
                        (plugin.spec.description ?? "").lowercased(),
                    ].contains { SearchService.fuzzyMatch(query: query, in: $0) }

                    if !pluginMatches {
                        matchedTools = matchedTools.filter { tool in
                            let candidates = [tool.name.lowercased(), tool.description.lowercased()]
                            return candidates.contains { SearchService.fuzzyMatch(query: query, in: $0) }
                        }
                    }

                    // Exclude only if no search match and not a failed plugin
                    if matchedTools.isEmpty && !pluginMatches && !plugin.hasLoadError { return nil }
                }

                // Include plugins with load errors even if no tools are registered
                // This allows users to see and troubleshoot failed plugins
                if matchedTools.isEmpty && !plugin.hasLoadError { return nil }

                return (plugin, matchedTools)
            }
            .sorted {
                ($0.plugin.spec.name ?? $0.plugin.spec.plugin_id) < ($1.plugin.spec.name ?? $1.plugin.spec.plugin_id)
            }
    }

    private func reload() {
        toolEntries = ToolRegistry.shared.listTools()
    }
}

#Preview {
    ToolsManagerView()
}

// MARK: - Permission Status Banner

private struct PermissionStatusBanner: View {
    @Environment(\.theme) private var theme
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            ZStack {
                Circle()
                    .fill(theme.warningColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 16))
                    .foregroundColor(theme.warningColor)
            }

            // Text
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count) plugin\(count == 1 ? "" : "s") need\(count == 1 ? "s" : "") system permissions")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text("Expand each plugin to grant the required permissions")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            // Action button
            Button(action: {
                // Open System Settings to the Privacy & Security pane
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

// MARK: - Remote Provider Tools Card

private struct RemoteProviderToolsCard: View {
    @Environment(\.theme) private var theme
    let provider: MCPProvider
    let tools: [ToolRegistry.ToolEntry]
    let providerState: MCPProviderState?
    var animationIndex: Int = 0
    let onDisconnect: () -> Void
    let onChange: () -> Void

    @State private var isExpanded: Bool = true
    @State private var isHovering = false
    @State private var hasAppeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Provider header
            HStack(spacing: 14) {
                // Clickable area for expand/collapse
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                }) {
                    HStack(spacing: 14) {
                        // Provider icon
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(theme.accentColor.opacity(0.12))
                            Image(systemName: "server.rack")
                                .font(.system(size: 20))
                                .foregroundColor(theme.accentColor)
                        }
                        .frame(width: 44, height: 44)

                        // Provider info
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(provider.name)
                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                    .foregroundColor(theme.primaryText)

                                // Connected badge
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

                        // Tool count
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

                        // Chevron
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.tertiaryText)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())

                // Accessory menu
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

            // Tools list (expandable)
            if isExpanded && !tools.isEmpty {
                Divider()
                    .padding(.vertical, 4)

                VStack(spacing: 8) {
                    ForEach(tools, id: \.id) { entry in
                        RemoteToolRow(entry: entry, providerName: provider.name, onChange: onChange)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .background(cardBackground)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .opacity(hasAppeared ? 1 : 0)
        .onAppear {
            let delay = Double(animationIndex) * 0.03
            withAnimation(.easeOut(duration: 0.25).delay(delay)) {
                hasAppeared = true
            }
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
                color: theme.shadowColor.opacity(
                    isHovering ? theme.shadowOpacity * 1.5 : theme.shadowOpacity
                ),
                radius: isHovering ? 12 : theme.cardShadowRadius,
                x: 0,
                y: isHovering ? 4 : theme.cardShadowY
            )
    }
}

// MARK: - Remote Tool Row

private struct RemoteToolRow: View {
    @Environment(\.theme) private var theme
    let entry: ToolRegistry.ToolEntry
    let providerName: String
    let onChange: () -> Void

    /// Display name without provider prefix
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
        let info = ToolRegistry.shared.policyInfo(for: entry.name)

        HStack(spacing: 10) {
            // Tool icon
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.accentColor.opacity(0.08))
                Image(systemName: "function")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.accentColor)
            }
            .frame(width: 28, height: 28)

            // Tool info
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

            // Permission policy dropdown
            if let info = info {
                Menu {
                    Button {
                        ToolRegistry.shared.setPolicy(.auto, for: entry.name)
                        onChange()
                    } label: {
                        HStack {
                            Image(systemName: "sparkles")
                            Text("Auto")
                        }
                    }
                    Button {
                        ToolRegistry.shared.setPolicy(.ask, for: entry.name)
                        onChange()
                    } label: {
                        HStack {
                            Image(systemName: "questionmark.circle")
                            Text("Ask")
                        }
                    }
                    Button {
                        ToolRegistry.shared.setPolicy(.deny, for: entry.name)
                        onChange()
                    } label: {
                        HStack {
                            Image(systemName: "xmark.circle")
                            Text("Deny")
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: iconForPolicy(info.effectivePolicy))
                            .font(.system(size: 9))
                            .foregroundColor(colorForPolicy(info.effectivePolicy))
                        Text(info.effectivePolicy.rawValue.capitalized)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(colorForPolicy(info.effectivePolicy))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                            .foregroundColor(theme.tertiaryText)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(colorForPolicy(info.effectivePolicy).opacity(0.12))
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            // Enable toggle
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
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.tertiaryBackground.opacity(0.5))
        )
    }

    private func iconForPolicy(_ policy: ToolPermissionPolicy) -> String {
        switch policy {
        case .auto: return "sparkles"
        case .ask: return "questionmark.circle"
        case .deny: return "xmark.circle"
        }
    }

    private func colorForPolicy(_ policy: ToolPermissionPolicy) -> Color {
        switch policy {
        case .auto: return ThemeManager.shared.currentTheme.accentColor
        case .ask: return .orange
        case .deny: return ThemeManager.shared.currentTheme.errorColor
        }
    }
}

// MARK: - Installed Plugin Card

private struct InstalledPluginCard: View {
    @Environment(\.theme) private var theme
    let plugin: PluginState
    let tools: [ToolRegistry.ToolEntry]
    @ObservedObject var repoService: PluginRepositoryService
    var animationIndex: Int = 0
    let onChange: () -> Void

    @State private var isExpanded: Bool = true
    @State private var isHovering = false
    @State private var hasAppeared = false
    @State private var errorMessage: String?
    @State private var showError: Bool = false

    /// Check if any tools in this plugin have missing system permissions
    private var missingSystemPermissions: [SystemPermission] {
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
        return Array(missing).sorted { $0.rawValue < $1.rawValue }
    }

    private var hasMissingPermissions: Bool {
        !missingSystemPermissions.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Plugin header
            HStack(spacing: 14) {
                // Clickable area for expand/collapse (icon + info)
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                }) {
                    HStack(spacing: 14) {
                        // Plugin icon (shows error/warning state)
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

                            // Warning overlay badge for missing permissions
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

                        // Tool count badge
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

                        // Chevron indicator
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.tertiaryText)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())

                // Action buttons (separate from clickable area)
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
                        Button(role: .destructive) {
                            uninstall()
                            onChange()  // Trigger immediate reload after uninstall
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

            // Error message (when plugin failed to load)
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

                    // Permission buttons
                    HStack(spacing: 8) {
                        ForEach(missingSystemPermissions, id: \.rawValue) { perm in
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

            // Tools list (expandable) - only show when there's no load error
            if isExpanded && !tools.isEmpty && !plugin.hasLoadError {
                Divider()
                    .padding(.vertical, 4)

                VStack(spacing: 8) {
                    ForEach(tools, id: \.id) { entry in
                        InstalledToolRow(entry: entry, onChange: onChange)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .background(cardBackground)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .opacity(hasAppeared ? 1 : 0)
        .onAppear {
            let delay = Double(animationIndex) * 0.03
            withAnimation(.easeOut(duration: 0.25).delay(delay)) {
                hasAppeared = true
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
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
                color: theme.shadowColor.opacity(
                    isHovering ? theme.shadowOpacity * 1.5 : theme.shadowOpacity
                ),
                radius: isHovering ? 12 : theme.cardShadowRadius,
                x: 0,
                y: isHovering ? 4 : theme.cardShadowY
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

// MARK: - Installed Tool Row (Compact)

private struct InstalledToolRow: View {
    @Environment(\.theme) private var theme
    let entry: ToolRegistry.ToolEntry
    let onChange: () -> Void

    private var hasMissingSystemPermissions: Bool {
        guard let info = ToolRegistry.shared.policyInfo(for: entry.name) else { return false }
        return info.systemPermissionStates.values.contains(false)
    }

    var body: some View {
        let info = ToolRegistry.shared.policyInfo(for: entry.name)

        HStack(spacing: 10) {
            // Tool icon with warning overlay if system permissions missing
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        hasMissingSystemPermissions
                            ? theme.warningColor.opacity(0.1) : theme.accentColor.opacity(0.08)
                    )
                Image(systemName: "function")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(hasMissingSystemPermissions ? theme.warningColor : theme.accentColor)

                // Warning badge
                if hasMissingSystemPermissions {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .foregroundColor(theme.warningColor)
                        .offset(x: 10, y: -10)
                }
            }
            .frame(width: 28, height: 28)

            // Tool info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.name)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(theme.primaryText)

                    // Warning badge for missing system permissions
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

            Spacer()

            // Permission policy dropdown
            if let info = info {
                Menu {
                    Button {
                        ToolRegistry.shared.setPolicy(.auto, for: entry.name)
                        onChange()
                    } label: {
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundColor(colorForPolicy(.auto))
                            Text("Auto")
                                .foregroundColor(colorForPolicy(.auto))
                        }
                    }
                    Button {
                        ToolRegistry.shared.setPolicy(.ask, for: entry.name)
                        onChange()
                    } label: {
                        HStack {
                            Image(systemName: "questionmark.circle")
                                .foregroundColor(colorForPolicy(.ask))
                            Text("Ask")
                                .foregroundColor(colorForPolicy(.ask))
                        }
                    }
                    Button {
                        ToolRegistry.shared.setPolicy(.deny, for: entry.name)
                        onChange()
                    } label: {
                        HStack {
                            Image(systemName: "xmark.circle")
                                .foregroundColor(colorForPolicy(.deny))
                            Text("Deny")
                                .foregroundColor(colorForPolicy(.deny))
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: iconForPolicy(info.effectivePolicy))
                            .font(.system(size: 9))
                            .foregroundColor(colorForPolicy(info.effectivePolicy))
                        Text(info.effectivePolicy.rawValue.capitalized)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(colorForPolicy(info.effectivePolicy))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                            .foregroundColor(theme.tertiaryText)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(colorForPolicy(info.effectivePolicy).opacity(0.12))
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            // Enable toggle
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
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.tertiaryBackground.opacity(0.5))
        )
    }

    private func iconForPolicy(_ policy: ToolPermissionPolicy) -> String {
        switch policy {
        case .auto: return "sparkles"
        case .ask: return "questionmark.circle"
        case .deny: return "xmark.circle"
        }
    }

    private func colorForPolicy(_ policy: ToolPermissionPolicy) -> Color {
        switch policy {
        case .auto: return ThemeManager.shared.currentTheme.accentColor
        case .ask: return .orange
        case .deny: return ThemeManager.shared.currentTheme.errorColor
        }
    }
}

// MARK: - Plugin Row (Available Tab)

private struct PluginRow: View {
    @Environment(\.theme) private var theme
    let plugin: PluginState
    @ObservedObject var repoService: PluginRepositoryService
    var animationIndex: Int = 0

    @State private var errorMessage: String?
    @State private var showError: Bool = false
    @State private var isHovering = false
    @State private var hasAppeared = false
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row
            HStack(spacing: 14) {
                // Clickable area for expand/collapse
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                }) {
                    HStack(spacing: 14) {
                        // Plugin icon
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(theme.accentColor.opacity(0.12))
                            Image(systemName: "puzzlepiece.extension.fill")
                                .font(.system(size: 20))
                                .foregroundColor(theme.accentColor)
                        }
                        .frame(width: 44, height: 44)

                        // Plugin info
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

                        // Tool count badge
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

                        // Chevron indicator
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.tertiaryText)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())

                // Action button
                actionButton
            }

            // Expanded content
            if isExpanded {
                // Metadata row
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

                // Show tools provided
                if let tools = plugin.spec.capabilities?.tools, !tools.isEmpty {
                    Divider()
                        .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Provides:")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.secondaryText)

                        FlowLayout(spacing: 6) {
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
        .background(cardBackground)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .opacity(hasAppeared ? 1 : 0)
        .onAppear {
            let delay = Double(animationIndex) * 0.02
            withAnimation(.easeOut(duration: 0.2).delay(delay)) {
                hasAppeared = true
            }
        }
        .alert("Installation Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
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
                color: theme.shadowColor.opacity(
                    isHovering ? theme.shadowOpacity * 1.5 : theme.shadowOpacity
                ),
                radius: isHovering ? 12 : theme.cardShadowRadius,
                x: 0,
                y: isHovering ? 4 : theme.cardShadowY
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

private struct FlowLayout: Layout {
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

// MARK: - Tool Settings Row with Policy/Grants

private struct ToolSettingsRow: View {
    @Environment(\.theme) private var theme
    let entry: ToolRegistry.ToolEntry
    @ObservedObject var repoService: PluginRepositoryService
    var animationIndex: Int = 0
    let onChange: () -> Void

    @State private var isExpanded: Bool = false
    @State private var refreshToken: Int = 0
    @State private var isHovering = false
    @State private var hasAppeared = false

    // Check if this tool's plugin has an update
    private var pluginState: PluginState? {
        // Match tool name prefix to plugin_id (tools are named like plugin.toolname)
        let parts = entry.name.split(separator: "_")
        if parts.count >= 2 {
            // For external tools, try to find matching plugin
            for plugin in repoService.plugins {
                if let tools = plugin.spec.capabilities?.tools {
                    if tools.contains(where: { $0.name == entry.name }) {
                        return plugin
                    }
                }
            }
        }
        return nil
    }

    var body: some View {
        let info = ToolRegistry.shared.policyInfo(for: entry.name)

        VStack(alignment: .leading, spacing: 12) {
            // Main row content
            HStack(spacing: 12) {
                // Tool icon
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.accentColor.opacity(0.1))
                    Image(systemName: "function")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
                .frame(width: 36, height: 36)

                // Tool info and expand button combined
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                }) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(entry.name)
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .foregroundColor(theme.primaryText)

                                // Show update badge if plugin has update
                                if let plugin = pluginState, plugin.hasUpdate {
                                    updateBadge
                                }
                            }
                            Text(entry.description)
                                .font(.system(size: 12))
                                .foregroundColor(theme.secondaryText)
                                .lineLimit(1)
                        }

                        Spacer()

                        // Update button if available
                        if let plugin = pluginState, plugin.hasUpdate {
                            Button(action: {
                                Task {
                                    try? await repoService.upgrade(pluginId: plugin.spec.plugin_id)
                                }
                            }) {
                                Text("Update")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.orange)
                                    )
                            }
                            .buttonStyle(PlainButtonStyle())
                        }

                        // Permission indicator
                        if let info = info {
                            HStack(spacing: 5) {
                                Image(systemName: iconForPolicy(info.effectivePolicy))
                                    .font(.system(size: 10))
                                    .foregroundColor(colorForPolicy(info.effectivePolicy))
                                Text(info.effectivePolicy.rawValue.capitalized)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(theme.secondaryText)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(theme.tertiaryBackground)
                            )
                        }

                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(theme.tertiaryText)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())

                // Enable toggle - separate from expand area
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
            }

            // Expanded permissions section
            if isExpanded, let info {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                        .padding(.vertical, 4)

                    // Permission policy section
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Permission Policy")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(theme.primaryText)

                            Spacer()

                            if info.configuredPolicy != nil {
                                Button("Use Default") {
                                    ToolRegistry.shared.clearPolicy(for: entry.name)
                                    bump()
                                }
                                .font(.system(size: 11, weight: .medium))
                                .buttonStyle(.plain)
                                .foregroundColor(theme.accentColor)
                            }
                        }

                        // Simple segmented picker
                        Picker(
                            "",
                            selection: Binding(
                                get: { info.configuredPolicy ?? info.effectivePolicy },
                                set: { newValue in
                                    ToolRegistry.shared.setPolicy(newValue, for: entry.name)
                                    bump()
                                }
                            )
                        ) {
                            Label("Auto", systemImage: "sparkles").tag(ToolPermissionPolicy.auto)
                            Label("Ask", systemImage: "questionmark.circle").tag(ToolPermissionPolicy.ask)
                            Label("Deny", systemImage: "xmark.circle").tag(ToolPermissionPolicy.deny)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        if let configured = info.configuredPolicy, configured != info.defaultPolicy {
                            Text("Default is \(info.defaultPolicy.rawValue)")
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                        }
                    }

                    // Required permissions section (if applicable)
                    if info.isPermissioned, !info.requirements.isEmpty {
                        Divider()
                            .padding(.vertical, 4)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Required Permissions")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(theme.primaryText)

                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(info.requirements, id: \.self) { req in
                                    Toggle(
                                        isOn: Binding(
                                            get: { info.grantsByRequirement[req] ?? false },
                                            set: { val in
                                                ToolRegistry.shared.setGrant(val, requirement: req, for: entry.name)
                                                bump()
                                            }
                                        )
                                    ) {
                                        Text(req)
                                            .font(.system(size: 12))
                                            .foregroundColor(theme.primaryText)
                                    }
                                    .toggleStyle(.checkbox)
                                }
                            }
                            .padding(.leading, 2)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
                .id(refreshToken)
            }
        }
        .padding(16)
        .background(cardBackground)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .opacity(hasAppeared ? 1 : 0)
        .onAppear {
            let delay = Double(animationIndex) * 0.02
            withAnimation(.easeOut(duration: 0.2).delay(delay)) {
                hasAppeared = true
            }
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
                color: theme.shadowColor.opacity(
                    isHovering ? theme.shadowOpacity * 1.5 : theme.shadowOpacity
                ),
                radius: isHovering ? 12 : theme.cardShadowRadius,
                x: 0,
                y: isHovering ? 4 : theme.cardShadowY
            )
    }

    private var updateBadge: some View {
        Image(systemName: "arrow.up.circle.fill")
            .font(.system(size: 10))
            .foregroundColor(.orange)
    }

    private func bump() {
        refreshToken &+= 1
        onChange()
    }

    private func iconForPolicy(_ policy: ToolPermissionPolicy) -> String {
        switch policy {
        case .auto:
            return "sparkles"
        case .ask:
            return "questionmark.circle"
        case .deny:
            return "xmark.circle"
        }
    }

    private func colorForPolicy(_ policy: ToolPermissionPolicy) -> Color {
        switch policy {
        case .auto:
            return theme.accentColor
        case .ask:
            return .orange
        case .deny:
            return theme.errorColor
        }
    }
}

// MARK: - Installed Plugins Summary

private struct InstalledPluginsSummaryView: View {
    @Environment(\.theme) private var theme
    @State private var summaryText: String = ""
    @State private var isVerifying: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 12))
                .foregroundColor(theme.accentColor)
            Text(summaryText.isEmpty ? "No plugins" : summaryText)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            Button(action: { Task { await verifyAll() } }) {
                HStack(spacing: 4) {
                    if isVerifying {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    }
                    Text(isVerifying ? "Verifying..." : "Verify")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.tertiaryBackground)
                )
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isVerifying)
        }
        .onAppear { refreshSummary() }
    }

    private func refreshSummary() {
        let fm = FileManager.default
        let root = ToolsPaths.toolsRootDirectory()
        guard let pluginDirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            summaryText = ""
            return
        }

        // Find installed plugins by looking for directories with a "current" symlink
        var installedIds: [String] = []
        for pluginDir in pluginDirs where pluginDir.hasDirectoryPath {
            let currentLink = pluginDir.appendingPathComponent("current")
            if let dest = try? fm.destinationOfSymbolicLink(atPath: currentLink.path) {
                let versionDir = pluginDir.appendingPathComponent(dest, isDirectory: true)
                let receiptURL = versionDir.appendingPathComponent("receipt.json")
                if fm.fileExists(atPath: receiptURL.path) {
                    installedIds.append(pluginDir.lastPathComponent)
                }
            }
        }

        let count = installedIds.count
        let ids = installedIds.sorted()
        summaryText = count == 0 ? "" : "\(count) plugin\(count == 1 ? "" : "s"): \(ids.joined(separator: ", "))"
    }

    private func verifyAll() async {
        isVerifying = true
        defer { isVerifying = false }
        let fm = FileManager.default
        let root = ToolsPaths.toolsRootDirectory()
        guard let pluginDirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return
        }
        for pluginDir in pluginDirs where pluginDir.hasDirectoryPath {
            let currentLink = pluginDir.appendingPathComponent("current")
            let versionDir: URL?
            if let dest = try? fm.destinationOfSymbolicLink(atPath: currentLink.path) {
                versionDir = pluginDir.appendingPathComponent(dest, isDirectory: true)
            } else {
                versionDir = nil
            }
            guard let vdir = versionDir else { continue }
            let receiptURL = vdir.appendingPathComponent("receipt.json")
            guard let rdata = try? Data(contentsOf: receiptURL),
                let receipt = try? JSONDecoder().decode(PluginReceipt.self, from: rdata)
            else { continue }
            let dylibURL = vdir.appendingPathComponent(receipt.dylib_filename)
            guard let dylibData = try? Data(contentsOf: dylibURL) else { continue }
            let digest = CryptoKit.SHA256.hash(data: dylibData)
            let sha = Data(digest).map { String(format: "%02x", $0) }.joined()
            if sha.lowercased() != receipt.dylib_sha256.lowercased() {
                // Show a non-blocking alert via notification center
                NotificationService.shared.postPluginVerificationFailed(
                    name: receipt.plugin_id,
                    version: receipt.version.description
                )
            }
        }
        refreshSummary()
    }
}
