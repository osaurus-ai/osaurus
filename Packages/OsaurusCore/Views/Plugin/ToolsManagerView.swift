//
//  ToolsManagerView.swift
//  osaurus
//
//  The Tools catalog: choose which tools agents can use, manage service
//  connections, and create custom tools. Organized as three tabs —
//  All (every usable tool, grouped by where it comes from), Connections
//  (remote MCP services), and Custom (user-created sandboxed tools).
//

import AppKit
import Foundation
import OsaurusRepository
import SwiftUI

/// Rows rendered per tool group/card before collapsing the rest behind a
/// "Show all" disclosure. Bounds eager layout work when a single source
/// exposes a very large number of tools. Shared by the flat groups in
/// `ToolsManagerView` and the per-provider/per-plugin cards.
let toolGroupRenderCapValue = 20

struct ToolsManagerView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private let repoService = PluginRepositoryService.shared
    private let providerManager = MCPProviderManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    /// Per-group render cap. See `toolGroupRenderCapValue`.
    static let toolGroupRenderCap = toolGroupRenderCapValue
    /// Group keys the user has chosen to fully expand past the render cap.
    @State private var expandedToolGroups: Set<String> = []

    @State private var selectedTab: ToolsTab = .all
    @State private var searchText: String = ""
    @State private var hasAppeared = false
    /// Guards against the redundant initial-refresh fan-out on appear
    /// (`.task(id:)` first run + `$plugins` subscribe emission). The `.task`
    /// owns the single initial load; everything else waits until after it.
    @State private var hasLoadedOnce = false
    @State private var isRefreshingInstalled = false
    @ObservedObject private var managementState = ManagementStateManager.shared

    // Snapshot values from services (updated via .onReceive / reload)
    @State private var toolEntries: [ToolRegistry.ToolEntry] = []
    @State private var runtimeManagedToolEntries: [ToolRegistry.ToolEntry] = []
    /// Built-in and native tools that don't belong to a plugin, provider,
    /// custom tool, or the runtime bucket. Surfaced with the runtime tools
    /// under a single Built-in group so every registered tool has exactly one
    /// home on the All tab.
    @State private var builtInNativeToolEntries: [ToolRegistry.ToolEntry] = []
    /// Tools registered by user-created (sandbox-plugin) custom tools, shown
    /// as the Custom group on the All tab.
    @State private var customToolEntries: [ToolRegistry.ToolEntry] = []
    @State private var policyInfoCache: [String: ToolRegistry.ToolPolicyInfo] = [:]
    /// Precomputed once per refresh so tool rows never call
    /// `ToolRegistry.availability(forTool:)` during SwiftUI layout.
    @State private var availabilityCache: [String: ToolAvailability] = [:]
    @State private var exposureDiagnostic: ToolExposureDiagnostic?
    /// Per-tool exposure rows, precomputed once per refresh so grouped rows
    /// render their catalog status from a snapshot instead of re-querying.
    @State private var exposureRowsByName: [String: ToolExposureDiagnostic.Row] = [:]

    /// Plain-language catalog filters (see `ToolCatalogPresentation`).
    @State private var statusFilter: ToolCatalogStatusFilter = .all
    @State private var sourceFilter: ToolCatalogSourceFilter = .all

    // Cached filtered results
    @State private var installedPluginsWithTools: [(plugin: PluginState, tools: [ToolRegistry.ToolEntry])] = []
    @State private var remoteProviderTools: [(provider: MCPProvider, tools: [ToolRegistry.ToolEntry])] = []
    /// Individual tools that cannot succeed until the user grants a macOS
    /// system permission. Drives the actionable banner on the All tab.
    @State private var toolsNeedingPermissionCount: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            headerBar
                .managerHeaderEntrance(hasAppeared: hasAppeared)

            Group {
                switch selectedTab {
                case .all:
                    allToolsTabContent
                case .connections:
                    ProvidersView()
                case .custom:
                    CustomToolsTabContent(onChange: { reload() })
                }
            }
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            withAnimation(.easeOut(duration: 0.25).delay(0.1)) {
                hasAppeared = true
            }
            applyPendingSubTabRequest()
        }
        .onChange(of: managementState.pendingToolsSubTab) { _, _ in
            applyPendingSubTabRequest()
        }
        .task(id: searchText) {
            // Single owner of the initial load: the first run snapshots tools
            // immediately, later runs (search edits) debounce. This replaces
            // the old onAppear reload() + task + $plugins triple refresh.
            if hasLoadedOnce {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
            } else {
                hasLoadedOnce = true
            }
            refreshToolSnapshot()
            await updateFilteredLists()
        }
        .onReceive(PluginRepositoryService.shared.$plugins) { _ in
            // Skip the emission fired on subscribe; the .task already loaded.
            guard hasLoadedOnce else { return }
            Task { await updateFilteredLists() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toolsListChanged)) { _ in
            reload()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: Foundation.Notification.Name.mcpProviderStatusChanged)
        ) { _ in
            reload()
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        ManagerHeaderWithTabs(
            title: L("Tools"),
            subtitle: L("Choose which tools agents can use")
        ) {
            HeaderIconButton(
                "arrow.clockwise",
                isLoading: isRefreshingInstalled,
                help: isRefreshingInstalled ? L("Refreshing...") : L("Reload tools")
            ) {
                Task {
                    isRefreshingInstalled = true
                    await PluginManager.shared.loadAll()
                    reload()
                    isRefreshingInstalled = false
                }
            }
        } tabsRow: {
            // Search only appears on the All tab, where it is actually wired
            // to the catalog results. Counts live inside each screen (section
            // headers, connection hub, custom library) instead of mixing
            // units in the tab bar.
            HeaderTabsRow(
                selection: $selectedTab,
                searchText: $searchText,
                searchPlaceholder: "Search tools",
                showSearch: selectedTab == .all
            )
        }
    }

    // MARK: - All Tools Tab (every tool agents can use, grouped by source)

    private var allToolsTabContent: some View {
        ScrollView {
            // A single LazyVStack so every tool row is an individual lazy child.
            // Group rows are emitted via bare `ForEach` (not wrapped in a
            // `VStack`), since a nested stack would be realized as one eager
            // child and defeat virtualization. Row spacing is 8; section
            // headers and intro cards add 8 more top padding for a 16 gap.
            LazyVStack(spacing: 8) {
                SectionHeader(
                    title: L("All Tools"),
                    description: "Everything agents can use, grouped by where each tool comes from"
                )

                let builtIn = visibleTools(builtInSectionToolEntries, section: .builtIn)
                let pluginGroups = visiblePluginGroups()
                let remoteGroups = visibleRemoteGroups()
                let custom = visibleTools(customToolEntries, section: .custom)

                let hasAnyTool =
                    !builtInSectionToolEntries.isEmpty
                    || !installedPluginsWithTools.isEmpty
                    || !remoteProviderTools.isEmpty
                    || !customToolEntries.isEmpty
                let hasAnyVisible =
                    !builtIn.isEmpty
                    || !pluginGroups.isEmpty
                    || !remoteGroups.isEmpty
                    || !custom.isEmpty

                if hasAnyTool {
                    filterToolbar
                        .padding(.top, 8)
                }

                if !hasAnyTool {
                    emptyState(
                        icon: "wrench.and.screwdriver",
                        title: L("No tools yet"),
                        subtitle: searchText.isEmpty
                            ? L("Install a plugin, add a connection, or create a custom tool to get started")
                            : L("Try a different search term")
                    )
                } else if !hasAnyVisible {
                    filteredEmptyState
                } else {
                    if toolsNeedingPermissionCount > 0 {
                        ToolPermissionBanner(count: toolsNeedingPermissionCount, subject: .tools)
                            .padding(.top, 8)
                    }

                    if !builtIn.isEmpty {
                        ToolSectionHeader(
                            title: L("Built-in"),
                            icon: "shippingbox",
                            count: builtIn.count
                        )
                        .padding(.top, 8)

                        cappedGroup(key: "builtIn", tools: builtIn) { entry in
                            RuntimeManagedToolEntryRow(
                                entry: entry,
                                badge: sourceBadge(for: entry),
                                policyInfo: policyInfoCache[entry.name],
                                availability: cachedAvailability(availabilityCache, for: entry),
                                status: catalogStatus(for: entry.name),
                                onChange: { applyLocalToolMutation(name: entry.name) }
                            )
                        }
                    }

                    if !pluginGroups.isEmpty {
                        ToolSectionHeader(
                            title: L("Plugins"),
                            icon: "puzzlepiece.extension",
                            count: pluginGroups.reduce(0) { $0 + $1.tools.count }
                        )
                        .padding(.top, 8)

                        ForEach(pluginGroups, id: \.plugin.id) { item in
                            ToolPluginCard(
                                plugin: item.plugin,
                                tools: item.tools,
                                policyInfoCache: policyInfoCache,
                                availabilityCache: availabilityCache,
                                exposureRowsByName: exposureRowsByName,
                                onToolMutated: { applyLocalToolMutation(name: $0) }
                            )
                        }
                    }

                    if !remoteGroups.isEmpty {
                        ToolSectionHeader(
                            title: L("Connections"),
                            icon: "server.rack",
                            count: remoteGroups.reduce(0) { $0 + $1.tools.count }
                        )
                        .padding(.top, 8)

                        ForEach(remoteGroups, id: \.provider.id) { item in
                            RemoteProviderToolsCard(
                                provider: item.provider,
                                tools: item.tools,
                                policyInfoCache: policyInfoCache,
                                availabilityCache: availabilityCache,
                                exposureRowsByName: exposureRowsByName,
                                onDisconnect: {
                                    providerManager.disconnect(providerId: item.provider.id)
                                },
                                onToolMutated: { applyLocalToolMutation(name: $0) }
                            )
                        }
                    }

                    if !custom.isEmpty {
                        ToolSectionHeader(
                            title: L("Custom"),
                            icon: "person.crop.square.badge.wrench",
                            count: custom.count
                        )
                        .padding(.top, 8)

                        cappedGroup(key: "custom", tools: custom) { entry in
                            ToolEntryRow(
                                entry: entry,
                                policyInfo: policyInfoCache[entry.name],
                                availability: cachedAvailability(availabilityCache, for: entry),
                                status: catalogStatus(for: entry.name),
                                onChange: { applyLocalToolMutation(name: entry.name) }
                            )
                        }
                    }
                }

                if let exposureDiagnostic, !exposureDiagnostic.rows.isEmpty {
                    ToolAdvancedDiagnosticsSection(
                        diagnostic: exposureDiagnostic,
                        searchText: searchText
                    )
                    .padding(.top, 8)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    /// Plain-language toolbar for narrowing the catalog by status and source.
    private var filterToolbar: some View {
        HStack(spacing: 8) {
            ToolFilterMenu(
                icon: "circle.lefthalf.filled",
                accessibilityTitle: L("Filter by status"),
                options: ToolCatalogStatusFilter.allCases,
                selection: $statusFilter
            )

            ToolFilterMenu(
                icon: "square.grid.2x2",
                accessibilityTitle: L("Filter by source"),
                options: ToolCatalogSourceFilter.allCases,
                selection: $sourceFilter
            )

            Spacer(minLength: 8)
        }
    }

    /// Emit a tool group's rows, capping the rendered count at
    /// `toolGroupRenderCap` until the user expands it. Keeps a single source
    /// with hundreds of tools from laying out every row at once.
    @ViewBuilder
    private func cappedGroup<Row: View>(
        key: String,
        tools: [ToolRegistry.ToolEntry],
        @ViewBuilder row: @escaping (ToolRegistry.ToolEntry) -> Row
    ) -> some View {
        let cap = Self.toolGroupRenderCap
        let isExpanded = expandedToolGroups.contains(key)
        let shown = (isExpanded || tools.count <= cap) ? tools : Array(tools.prefix(cap))

        ForEach(shown) { entry in
            row(entry)
        }

        if tools.count > cap {
            ShowAllToolsButton(
                hiddenCount: tools.count - cap,
                isExpanded: isExpanded
            ) {
                if isExpanded {
                    expandedToolGroups.remove(key)
                } else {
                    expandedToolGroups.insert(key)
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Empty / Loading States

    private func emptyState(icon: String, title: String, subtitle: String?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundColor(theme.tertiaryText)

            Text(LocalizedStringKey(title), bundle: .module)
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

    private var filteredEmptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundColor(theme.tertiaryText)
            Text("No tools match the current filters", bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground.opacity(0.5)))
    }

    // MARK: - Helpers

    private func updateFilteredLists() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryLower = query.lowercased()
        let currentToolEntries = toolEntries
        let runtimeManagedNames = ToolRegistry.shared.runtimeManagedToolNames
        let currentPlugins = repoService.plugins
        let currentProviders = providerManager.configuration.providers
        let currentProviderStates = providerManager.providerStates

        // Snapshot the exposure diagnostic up front (the only DB-backed step)
        // so the detached pass below can also partition built-in/native and
        // custom tools from the same source classification.
        let diagnostic = await ToolIndexService.shared.exposureSnapshot()
        guard !Task.isCancelled else { return }
        let rowsByName = Dictionary(uniqueKeysWithValues: diagnostic.rows.map { ($0.toolName, $0) })

        let (
            installedPluginsResult,
            remoteToolsResult,
            runtimeToolsResult,
            builtInNativeToolsResult,
            customToolsResult
        ) =
            await Task.detached(priority: .userInitiated) {

                func matchesToolSearch(_ tool: ToolRegistry.ToolEntry) -> Bool {
                    query.isEmpty
                        || SearchService.matches(query: query, in: tool.name)
                        || SearchService.matches(query: query, in: tool.description)
                }

                // 1. Installed Plugins with Tools (Plugins group)
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

                // 2. Connection tools (Connections group)
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

                // 3. Runtime-managed tools (folder and built-in sandbox).
                // These are not plugin catalog entries, but they are exactly
                // the tools chat can send to local models when folder or
                // sandbox mode is active. They render inside the Built-in
                // group with a Folder/Sandbox source badge.
                let runtimeTools =
                    currentToolEntries
                    .filter { runtimeManagedNames.contains($0.name) }
                    .filter(matchesToolSearch)

                // 4. Custom tools registered from user-created sandbox
                // recipes, classified by the exposure diagnostic.
                let customTools =
                    currentToolEntries
                    .filter { rowsByName[$0.name]?.source == .sandboxPlugin }
                    .filter { !runtimeManagedNames.contains($0.name) }
                    .filter(matchesToolSearch)

                // 5. Built-in and native tools that have no other home. Every
                // other group (plugin/provider/runtime/custom) is keyed off
                // concrete catalog entries; these are the remaining registered
                // tools (capability infrastructure, native helpers) classified
                // as built-in/native by the exposure diagnostic.
                let shownNames =
                    Set(runtimeTools.map(\.name))
                    .union(installedPlugins.flatMap { $0.tools.map(\.name) })
                    .union(remoteTools.flatMap { $0.tools.map(\.name) })
                    .union(customTools.map(\.name))
                let builtInNativeTools =
                    currentToolEntries
                    .filter { entry in
                        guard let source = rowsByName[entry.name]?.source else { return false }
                        return source == .builtIn || source == .native
                    }
                    .filter { !shownNames.contains($0.name) }
                    .filter(matchesToolSearch)

                return (installedPlugins, remoteTools, runtimeTools, builtInNativeTools, customTools)
            }.value

        guard !Task.isCancelled else { return }

        installedPluginsWithTools = installedPluginsResult
        remoteProviderTools = remoteToolsResult
        runtimeManagedToolEntries = runtimeToolsResult
        builtInNativeToolEntries = builtInNativeToolsResult
        customToolEntries = customToolsResult

        // Build policy info + availability caches once for all tools so the
        // rows render from snapshots instead of hitting the registry per body.
        var cache: [String: ToolRegistry.ToolPolicyInfo] = [:]
        var availability: [String: ToolAvailability] = [:]
        for entry in currentToolEntries {
            if let info = ToolRegistry.shared.policyInfo(for: entry.name) {
                cache[entry.name] = info
            }
            availability[entry.name] = ToolRegistry.shared.availability(forTool: entry.name)
        }
        policyInfoCache = cache
        availabilityCache = availability

        exposureDiagnostic = diagnostic
        exposureRowsByName = rowsByName
        recomputePermissionBannerCount()
    }

    /// The single Built-in group: shipped built-in/native tools plus the
    /// runtime-managed folder/sandbox execution tools. Kept as one list so
    /// the internal "runtime" category never leaks into the default UI.
    private var builtInSectionToolEntries: [ToolRegistry.ToolEntry] {
        builtInNativeToolEntries + runtimeManagedToolEntries
    }

    /// User-facing status for a tool, derived from the exposure snapshot and
    /// system-permission probe. See `ToolCatalogPresentation`.
    private func catalogStatus(for name: String) -> ToolCatalogStatus {
        ToolCatalogPresentation.status(
            state: exposureRowsByName[name]?.state,
            hasMissingSystemPermissions:
                policyInfoCache[name]?.systemPermissionStates.values.contains(false) == true
        )
    }

    private func recomputePermissionBannerCount() {
        let names =
            Set(builtInSectionToolEntries.map(\.name))
            .union(customToolEntries.map(\.name))
            .union(installedPluginsWithTools.flatMap { $0.tools.map(\.name) })
            .union(remoteProviderTools.flatMap { $0.tools.map(\.name) })
        toolsNeedingPermissionCount =
            names.filter { name in
                policyInfoCache[name]?.systemPermissionStates.values.contains(false) == true
            }.count
    }

    // MARK: - Grouped list filtering

    /// Narrow a flat group's tools by the active status filter, or hide the
    /// group entirely when the source filter excludes its section. Free-text
    /// search is already applied while the groups are built in
    /// `updateFilteredLists()`.
    private func visibleTools(
        _ tools: [ToolRegistry.ToolEntry],
        section: ToolCatalogSection
    ) -> [ToolRegistry.ToolEntry] {
        guard sourceFilter.matches(section) else { return [] }
        guard statusFilter != .all else { return tools }
        return tools.filter { statusFilter.matches(catalogStatus(for: $0.name)) }
    }

    private func visiblePluginGroups() -> [(plugin: PluginState, tools: [ToolRegistry.ToolEntry])] {
        guard sourceFilter.matches(.plugins) else { return [] }
        return installedPluginsWithTools.compactMap { item in
            let tools = visibleTools(item.tools, section: .plugins)
            if tools.isEmpty {
                // Surface load-error plugins (which have no tools) only when
                // not narrowing by status, since a status filter can't match
                // them.
                if statusFilter == .all && item.plugin.hasLoadError {
                    return (item.plugin, [])
                }
                return nil
            }
            return (item.plugin, tools)
        }
    }

    private func visibleRemoteGroups() -> [(provider: MCPProvider, tools: [ToolRegistry.ToolEntry])] {
        guard sourceFilter.matches(.connections) else { return [] }
        return remoteProviderTools.compactMap { item in
            let tools = visibleTools(item.tools, section: .connections)
            return tools.isEmpty ? nil : (item.provider, tools)
        }
    }

    /// Apply a single tool's enable/policy change locally instead of rebuilding
    /// the whole screen. Patches the cached snapshots in place and refreshes
    /// only that tool's exposure row, so toggling one tool never re-runs the
    /// DB-backed full snapshot.
    private func applyLocalToolMutation(name: String) {
        let live = ToolRegistry.shared.entry(named: name)
        func patch(_ tools: inout [ToolRegistry.ToolEntry]) {
            guard let live, let idx = tools.firstIndex(where: { $0.name == name }) else { return }
            tools[idx] = live
        }
        patch(&toolEntries)
        patch(&runtimeManagedToolEntries)
        patch(&builtInNativeToolEntries)
        patch(&customToolEntries)
        for i in installedPluginsWithTools.indices { patch(&installedPluginsWithTools[i].tools) }
        for i in remoteProviderTools.indices { patch(&remoteProviderTools[i].tools) }

        if let info = ToolRegistry.shared.policyInfo(for: name) {
            policyInfoCache[name] = info
        }
        availabilityCache[name] = ToolRegistry.shared.availability(forTool: name)
        recomputePermissionBannerCount()

        Task { @MainActor in
            let refreshed = await ToolIndexService.shared.exposureDiagnostic(forToolNames: [name])
            guard let row = refreshed.rows.first else { return }
            exposureRowsByName[name] = row
            if let current = exposureDiagnostic,
                let idx = current.rows.firstIndex(where: { $0.toolName == name })
            {
                var newRows = current.rows
                newRows[idx] = row
                exposureDiagnostic = ToolExposureDiagnostic(
                    registeredToolCount: current.registeredToolCount,
                    indexedToolCount: current.indexedToolCount,
                    rows: newRows
                )
            }
        }
    }

    /// Plain-language origin badge for a Built-in group row. Runtime-managed
    /// execution tools keep their concrete origin (Folder / Sandbox) so power
    /// users can still tell them apart.
    private func sourceBadge(for entry: ToolRegistry.ToolEntry) -> String {
        if ToolRegistry.shared.builtInSandboxToolNamesSnapshot.contains(entry.name) {
            return L("Sandbox")
        }
        if ToolRegistry.folderToolNames.contains(entry.name) {
            return L("Folder")
        }
        if exposureRowsByName[entry.name]?.source == .native {
            return L("Native")
        }
        return L("Built-in")
    }

    /// Snapshot the in-memory registry/provider state the filters read.
    /// Kept separate so the initial `.task` load can populate it without
    /// spawning a second `updateFilteredLists()` pass.
    private func refreshToolSnapshot() {
        toolEntries = ToolRegistry.shared.listTools()
    }

    private func reload() {
        refreshToolSnapshot()
        Task { await updateFilteredLists() }
    }

    /// Honour one-shot navigation requests routed through
    /// `ManagementStateManager.pendingToolsSubTab` (e.g. the Claude plugin
    /// install summary deep-linking to the Connections tab after OAuth or
    /// bearer-token imports). Legacy raw values from before the
    /// All / Connections / Custom rename are still accepted.
    private func applyPendingSubTabRequest() {
        guard let raw = managementState.pendingToolsSubTab,
            let target = ToolsTab.resolved(from: raw)
        else { return }
        selectedTab = target
        managementState.pendingToolsSubTab = nil
    }
}

/// Tool availability from a per-refresh snapshot, falling back to a direct
/// (O(1)) registry lookup if the cache hasn't been populated for this tool.
@MainActor
func cachedAvailability(
    _ cache: [String: ToolAvailability],
    for entry: ToolRegistry.ToolEntry
) -> ToolAvailability {
    cache[entry.name] ?? ToolRegistry.shared.availability(forTool: entry.name)
}

// MARK: - Custom Tools Tab

/// The Custom tab: tools the user creates or imports as JSON recipes. They
/// run inside Osaurus's sandbox, isolated from the rest of the Mac — the
/// sandbox is the safety mechanism, not the organizing concept.
private struct CustomToolsTabContent: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var pluginLibrary = SandboxPluginLibrary.shared

    let onChange: () -> Void

    @State private var showCreatePlugin = false
    @State private var editingPlugin: SandboxPlugin?
    @State private var pluginToDelete: SandboxPlugin?
    @State private var showDeleteConfirm = false
    @State private var actionError: String?

    var body: some View {
        ScrollView {
            // Mirror the All tab: a single LazyVStack with bare `ForEach`
            // groups so tool rows virtualize instead of laying out eagerly.
            LazyVStack(spacing: 8) {
                SectionHeader(
                    title: L("Custom Tools"),
                    description:
                        "Tools you create or import as JSON recipes. They run inside Osaurus's sandbox, isolated from the rest of your Mac."
                )

                HStack {
                    Spacer()

                    Button(action: importPluginFile) {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 11))
                            Text("Import", bundle: .module)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(theme.primaryText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.tertiaryBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(theme.inputBorder, lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help(Text("Import a custom tool from a JSON file", bundle: .module))

                    Button(action: { showCreatePlugin = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 11))
                            Text("New Custom Tool", bundle: .module)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.accentColor))
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                if pluginLibrary.plugins.isEmpty {
                    customToolsEmptyState
                } else {
                    ToolSectionHeader(
                        title: L("Your Custom Tools"),
                        icon: "person.crop.square.badge.wrench",
                        count: pluginLibrary.plugins.count
                    )
                    .padding(.top, 8)

                    ForEach(pluginLibrary.plugins) { plugin in
                        SandboxPluginToolCard(
                            plugin: plugin,
                            onEdit: { editingPlugin = plugin },
                            onDuplicate: { duplicatePlugin(plugin) },
                            onExport: { exportPlugin(plugin) },
                            onDelete: {
                                pluginToDelete = plugin
                                showDeleteConfirm = true
                            }
                        )
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showCreatePlugin) {
            SandboxPluginEditorView(
                plugin: .blank(),
                isNew: true,
                onSave: { plugin in pluginLibrary.save(plugin) },
                onDismiss: {}
            )
        }
        .sheet(item: $editingPlugin) { plugin in
            SandboxPluginEditorView(
                plugin: plugin,
                isNew: false,
                onSave: { updated in
                    pluginLibrary.update(oldId: plugin.id, plugin: updated)
                    editingPlugin = nil
                },
                onDismiss: { editingPlugin = nil }
            )
        }
        .alert(Text("Remove Custom Tool?", bundle: .module), isPresented: $showDeleteConfirm) {
            Button(role: .cancel) {
                pluginToDelete = nil
            } label: {
                Text("Cancel", bundle: .module)
            }
            Button(role: .destructive) {
                if let p = pluginToDelete {
                    pluginLibrary.delete(id: p.id)
                    ToolRegistry.shared.unregisterSandboxPluginTools(pluginId: p.id)
                    pluginToDelete = nil
                    onChange()
                }
            } label: {
                Text("Remove", bundle: .module)
            }
        } message: {
            if let p = pluginToDelete {
                Text(
                    "Remove \"\(p.name)\" from your custom tools? Agents will no longer be able to use its tools.",
                    bundle: .module
                )
            }
        }
        .alert(
            Text("Error", bundle: .module),
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )
        ) {
            Button(role: .cancel) {
                actionError = nil
            } label: {
                Text("OK", bundle: .module)
            }
        } message: {
            if let error = actionError {
                Text(error)
            }
        }
    }

    private var customToolsEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(theme.tertiaryText)

            Text("No custom tools yet", bundle: .module)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(theme.secondaryText)

            Text(
                "Create a tool or import a JSON recipe. Custom tools are set up automatically the first time an agent uses them.",
                bundle: .module
            )
            .font(.system(size: 13))
            .foregroundColor(theme.tertiaryText)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func importPluginFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        Task { @MainActor in
            guard await panel.beginModal() == .OK, let url = panel.url else { return }
            do {
                let plugin = try pluginLibrary.importFromFile(url)
                ToolRegistry.shared.registerSandboxPluginTools(plugin: plugin)
                onChange()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func duplicatePlugin(_ plugin: SandboxPlugin) {
        var copy = plugin
        copy.name = plugin.name + " Copy"
        copy.version = nil
        pluginLibrary.save(copy)
        ToolRegistry.shared.registerSandboxPluginTools(plugin: copy)
        onChange()
    }

    private func exportPlugin(_ plugin: SandboxPlugin) {
        guard let data = pluginLibrary.exportData(for: plugin.id) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(plugin.id).json"
        Task { @MainActor in
            guard await panel.beginModal() == .OK, let url = panel.url else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Sandbox Plugin Tool Card

private struct SandboxPluginToolCard: View {
    @Environment(\.theme) private var theme
    let plugin: SandboxPlugin
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void

    @State private var isExpanded = false
    @State private var isMenuHovering = false
    @State private var showAllTools = false

    private var toolCount: Int {
        plugin.tools?.count ?? 0
    }

    private var visibleToolSpecs: [SandboxToolSpec] {
        guard let tools = plugin.tools else { return [] }
        let cap = toolGroupRenderCapValue
        return (showAllTools || tools.count <= cap) ? tools : Array(tools.prefix(cap))
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
                                .fill(theme.accentColor.opacity(0.12))
                            Image(systemName: "puzzlepiece.extension.fill")
                                .font(.system(size: 20))
                                .foregroundColor(theme.accentColor)
                        }
                        .frame(width: 44, height: 44)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(plugin.name)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundColor(theme.primaryText)

                            Text(plugin.description)
                                .font(.system(size: 13))
                                .foregroundColor(theme.secondaryText)
                                .lineLimit(1)
                        }

                        Spacer()

                        if toolCount > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "wrench.and.screwdriver")
                                    .font(.system(size: 10))
                                Text("\(toolCount) tool\(toolCount == 1 ? "" : "s")", bundle: .module)
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
                .accessibilityLabel(Text("Custom tool \(plugin.name), \(toolCount) tools", bundle: .module))

                Menu {
                    Button(action: onEdit) {
                        Label {
                            Text("Edit", bundle: .module)
                        } icon: {
                            Image(systemName: "pencil")
                        }
                    }
                    Button(action: onDuplicate) {
                        Label {
                            Text("Duplicate", bundle: .module)
                        } icon: {
                            Image(systemName: "plus.square.on.square")
                        }
                    }
                    Button(action: onExport) {
                        Label {
                            Text("Export", bundle: .module)
                        } icon: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    Divider()
                    Button(role: .destructive, action: onDelete) {
                        Label {
                            Text("Remove", bundle: .module)
                        } icon: {
                            Image(systemName: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.tertiaryBackground.opacity(isMenuHovering ? 1 : 0))
                        )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .onHover { isMenuHovering = $0 }
                .accessibilityLabel(Text("Actions for \(plugin.name)", bundle: .module))
            }

            if isExpanded {
                Divider()
                    .padding(.vertical, 4)

                if let tools = plugin.tools, !tools.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(visibleToolSpecs, id: \.id) { spec in
                            let toolName = "\(plugin.id)_\(spec.id)"
                            let entry = ToolRegistry.shared.entry(named: toolName)
                            sandboxToolRow(spec: spec, entry: entry)
                        }

                        if tools.count > toolGroupRenderCapValue {
                            ShowAllToolsButton(
                                hiddenCount: tools.count - toolGroupRenderCapValue,
                                isExpanded: showAllTools
                            ) {
                                showAllTools.toggle()
                            }
                        }
                    }
                } else {
                    HStack {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundColor(theme.tertiaryText)
                        Text("No tools defined in this custom tool", bundle: .module)
                            .font(.system(size: 12))
                            .foregroundColor(theme.tertiaryText)
                    }
                    .padding(8)
                }

                if let deps = plugin.dependencies, !deps.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "shippingbox")
                            .font(.system(size: 10))
                            .foregroundColor(theme.tertiaryText)
                        Text("Dependencies: \(deps.joined(separator: ", "))", bundle: .module)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(HoverableCardBackground())
    }

    private func sandboxToolRow(spec: SandboxToolSpec, entry: ToolRegistry.ToolEntry?) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.accentColor.opacity(0.08))
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.accentColor)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(spec.id)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(theme.primaryText)
                Text(spec.description)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
            }

            Spacer()

            if let entry = entry {
                ToolEnableToggle(entry: entry, onChange: {})
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.tertiaryBackground.opacity(0.5))
        )
    }
}

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        ToolsManagerView()
    }
#endif

// MARK: - Tool Plugin Card

private struct ToolPluginCard: View {
    @Environment(\.theme) private var theme
    let plugin: PluginState
    let tools: [ToolRegistry.ToolEntry]
    let policyInfoCache: [String: ToolRegistry.ToolPolicyInfo]
    let availabilityCache: [String: ToolAvailability]
    let exposureRowsByName: [String: ToolExposureDiagnostic.Row]
    let onToolMutated: (String) -> Void

    @State private var isExpanded: Bool = false
    @State private var showAllTools = false

    private var visibleTools: [ToolRegistry.ToolEntry] {
        let cap = toolGroupRenderCapValue
        return (showAllTools || tools.count <= cap) ? tools : Array(tools.prefix(cap))
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
                                        Text("Error", bundle: .module)
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
                                Text("\(tools.count) tool\(tools.count == 1 ? "" : "s")", bundle: .module)
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
                .accessibilityLabel(
                    Text("Plugin \(plugin.displayName), \(tools.count) tools", bundle: .module))
            }

            if isExpanded, let loadError = plugin.loadError {
                Divider()
                    .padding(.vertical, 4)

                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.red)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Failed to load plugin", bundle: .module)
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
                .transition(.opacity)
            }

            if isExpanded && !tools.isEmpty && !plugin.hasLoadError {
                Divider()
                    .padding(.vertical, 4)

                VStack(spacing: 8) {
                    ForEach(visibleTools, id: \.id) { entry in
                        ToolEntryRow(
                            entry: entry,
                            policyInfo: policyInfoCache[entry.name],
                            availability: cachedAvailability(availabilityCache, for: entry),
                            status: ToolCatalogPresentation.status(
                                state: exposureRowsByName[entry.name]?.state,
                                hasMissingSystemPermissions:
                                    policyInfoCache[entry.name]?.systemPermissionStates.values
                                    .contains(false) == true
                            ),
                            onChange: { onToolMutated(entry.name) }
                        )
                    }

                    if tools.count > toolGroupRenderCapValue {
                        ShowAllToolsButton(
                            hiddenCount: tools.count - toolGroupRenderCapValue,
                            isExpanded: showAllTools
                        ) {
                            showAllTools.toggle()
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(HoverableCardBackground())
    }
}

// MARK: - Remote Provider Tools Card

private struct RemoteProviderToolsCard: View {
    @Environment(\.theme) private var theme
    let provider: MCPProvider
    let tools: [ToolRegistry.ToolEntry]
    let policyInfoCache: [String: ToolRegistry.ToolPolicyInfo]
    let availabilityCache: [String: ToolAvailability]
    let exposureRowsByName: [String: ToolExposureDiagnostic.Row]
    let onDisconnect: () -> Void
    let onToolMutated: (String) -> Void

    @State private var isExpanded: Bool = false
    @State private var isMenuHovering = false
    @State private var showAllTools = false

    private var visibleTools: [ToolRegistry.ToolEntry] {
        let cap = toolGroupRenderCapValue
        return (showAllTools || tools.count <= cap) ? tools : Array(tools.prefix(cap))
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
                                    Text("Connected", bundle: .module)
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
                            Text("\(tools.count) tool\(tools.count == 1 ? "" : "s")", bundle: .module)
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
                .accessibilityLabel(
                    Text("Connection \(provider.name), \(tools.count) tools", bundle: .module))

                Menu {
                    Button(action: onDisconnect) {
                        Label {
                            Text("Disconnect", bundle: .module)
                        } icon: {
                            Image(systemName: "bolt.slash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.tertiaryBackground.opacity(isMenuHovering ? 1 : 0))
                        )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .onHover { isMenuHovering = $0 }
                .accessibilityLabel(Text("Actions for \(provider.name)", bundle: .module))
            }

            if isExpanded && !tools.isEmpty {
                Divider()
                    .padding(.vertical, 4)

                VStack(spacing: 8) {
                    ForEach(visibleTools, id: \.id) { entry in
                        RemoteToolRow(
                            entry: entry,
                            providerName: provider.name,
                            policyInfo: policyInfoCache[entry.name],
                            availability: cachedAvailability(availabilityCache, for: entry),
                            status: ToolCatalogPresentation.status(
                                state: exposureRowsByName[entry.name]?.state,
                                hasMissingSystemPermissions:
                                    policyInfoCache[entry.name]?.systemPermissionStates.values
                                    .contains(false) == true
                            ),
                            onChange: { onToolMutated(entry.name) }
                        )
                    }

                    if tools.count > toolGroupRenderCapValue {
                        ShowAllToolsButton(
                            hiddenCount: tools.count - toolGroupRenderCapValue,
                            isExpanded: showAllTools
                        ) {
                            showAllTools.toggle()
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(HoverableCardBackground())
    }
}
