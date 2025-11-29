//
//  ToolsManagerView.swift
//  osaurus
//
//  Manage chat tools: search and toggle enablement, browse and install plugins.
//

import AppKit
import CryptoKit
import Foundation
import OsaurusRepository
import SwiftUI

struct ToolsManagerView: View {
    @StateObject private var themeManager = ThemeManager.shared
    @ObservedObject private var repoService = PluginRepositoryService.shared
    @Environment(\.theme) private var theme

    @State private var selectedTab: ToolsTab = .installed
    @State private var searchText: String = ""
    @State private var toolEntries: [ToolRegistry.ToolEntry] = []
    @State private var hasAppeared = false

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
                case .installed:
                    installedTabContent
                case .available:
                    availableTabContent
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

                    Text("Manage and discover tools for chat")
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
                        .installed: filteredEntries.count,
                        .available: filteredPlugins.count,
                    ],
                    badges: repoService.updatesAvailableCount > 0
                        ? [.installed: repoService.updatesAvailableCount]
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
                        PluginManager.shared.loadAll()
                        reload()
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 32, height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.tertiaryBackground)
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Reload tools")
                }

                SearchField(text: $searchText, placeholder: "Search tools")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .background(theme.secondaryBackground)
    }

    // MARK: - Installed Tab

    private var installedTabContent: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                let plugins = installedPluginsWithTools
                let builtIn = builtInTools

                if plugins.isEmpty && builtIn.isEmpty {
                    emptyState(
                        icon: "wrench.and.screwdriver",
                        title: "No tools match your search",
                        subtitle: searchText.isEmpty ? nil : "Try a different search term"
                    )
                } else {
                    // Installed plugins section
                    if !plugins.isEmpty {
                        InstalledSectionHeader(title: "Plugins", icon: "puzzlepiece.extension")

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

                    // Built-in tools section
                    if !builtIn.isEmpty {
                        if !plugins.isEmpty {
                            Spacer().frame(height: 8)
                        }

                        InstalledSectionHeader(title: "Built-in Tools", icon: "hammer")

                        ForEach(Array(builtIn.enumerated()), id: \.element.id) { index, entry in
                            ToolSettingsRow(
                                entry: entry,
                                repoService: repoService,
                                animationIndex: plugins.count + index
                            ) {
                                reload()
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    // MARK: - Available Tab

    private var availableTabContent: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
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

    /// Built-in tools (not from any plugin)
    private var builtInTools: [ToolRegistry.ToolEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Collect all tool names from installed plugins
        let pluginToolNames = Set(
            repoService.plugins
                .filter { $0.isInstalled }
                .flatMap { $0.spec.capabilities?.tools?.map { $0.name } ?? [] }
        )

        var tools = toolEntries.filter { !pluginToolNames.contains($0.name) }

        // Apply search filter
        if !query.isEmpty {
            tools = tools.filter { tool in
                let candidates = [tool.name.lowercased(), tool.description.lowercased()]
                return candidates.contains { SearchService.fuzzyMatch(query: query, in: $0) }
            }
        }

        return tools
    }

    private func reload() {
        toolEntries = ToolRegistry.shared.listTools()
    }
}

#Preview {
    ToolsManagerView()
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
                        // Plugin icon (shows error state when load failed)
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(plugin.hasLoadError ? Color.red.opacity(0.12) : theme.accentColor.opacity(0.12))
                            Image(
                                systemName: plugin.hasLoadError
                                    ? "exclamationmark.triangle.fill" : "puzzlepiece.extension.fill"
                            )
                            .font(.system(size: 20))
                            .foregroundColor(plugin.hasLoadError ? .red : theme.accentColor)
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

    @State private var isExpanded: Bool = false
    @State private var refreshToken: Int = 0

    var body: some View {
        let info = ToolRegistry.shared.policyInfo(for: entry.name)

        VStack(alignment: .leading, spacing: 8) {
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
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                }) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundColor(theme.primaryText)
                            Text(entry.description)
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                                .lineLimit(1)
                        }

                        Spacer()

                        // Permission indicator
                        if let info = info {
                            HStack(spacing: 4) {
                                Image(systemName: iconForPolicy(info.effectivePolicy))
                                    .font(.system(size: 9))
                                    .foregroundColor(colorForPolicy(info.effectivePolicy))
                                Text(info.effectivePolicy.rawValue.capitalized)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(theme.tertiaryText)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(theme.tertiaryBackground)
                            )
                        }

                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(theme.tertiaryText)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())

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

            // Expanded permissions section
            if isExpanded, let info {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()

                    // Permission policy section
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Permission Policy")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(theme.primaryText)

                            Spacer()

                            if info.configuredPolicy != nil {
                                Button("Use Default") {
                                    ToolRegistry.shared.clearPolicy(for: entry.name)
                                    bump()
                                }
                                .font(.system(size: 10, weight: .medium))
                                .buttonStyle(.plain)
                                .foregroundColor(theme.accentColor)
                            }
                        }

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
                    }

                    // Required permissions section
                    if info.isPermissioned, !info.requirements.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Required Permissions")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(theme.primaryText)

                            VStack(alignment: .leading, spacing: 4) {
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
                                            .font(.system(size: 11))
                                            .foregroundColor(theme.primaryText)
                                    }
                                    .toggleStyle(.checkbox)
                                }
                            }
                        }
                    }
                }
                .padding(.leading, 38)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .id(refreshToken)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.tertiaryBackground.opacity(0.5))
        )
    }

    private func bump() {
        refreshToken &+= 1
        onChange()
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
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
                VStack(alignment: .leading, spacing: 6) {
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
                            .lineLimit(2)
                    }

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

                        if let tools = plugin.spec.capabilities?.tools, !tools.isEmpty {
                            Label("\(tools.count) tool\(tools.count == 1 ? "" : "s")", systemImage: "wrench")
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                        }
                    }
                }

                Spacer()

                // Action button
                actionButton
            }

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
