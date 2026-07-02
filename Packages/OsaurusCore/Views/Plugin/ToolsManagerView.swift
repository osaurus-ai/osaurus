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

    @State private var selectedTab: ToolsTab = .available
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
    @State private var builtInSandboxToolEntries: [ToolRegistry.ToolEntry] = []
    /// Built-in and native tools that don't belong to a plugin, provider, or
    /// the runtime/sandbox buckets. Surfaced as their own group so every
    /// registered tool has exactly one home on the Available tab.
    @State private var builtInNativeToolEntries: [ToolRegistry.ToolEntry] = []
    @State private var remoteProviderCount: Int = 0
    @State private var policyInfoCache: [String: ToolRegistry.ToolPolicyInfo] = [:]
    /// Precomputed once per refresh so tool rows never call
    /// `ToolRegistry.availability(forTool:)` during SwiftUI layout.
    @State private var availabilityCache: [String: ToolAvailability] = [:]
    @State private var exposureDiagnostic: ToolExposureDiagnostic?
    /// Per-tool exposure rows, precomputed once per refresh so grouped rows
    /// render their state pill from a snapshot instead of re-querying.
    @State private var exposureRowsByName: [String: ToolExposureDiagnostic.Row] = [:]
    /// Tool names that pass the active source/state filters. Re-derived purely
    /// in-memory from `exposureDiagnostic` whenever the filters change, so a
    /// filter/chip tap never triggers the DB-backed snapshot rebuild.
    @State private var allowedToolNames: Set<String> = []
    @State private var exposureSourceFilter: ToolExposureSourceFilter = .all
    @State private var exposureStateFilter: ToolExposureStateFilter = .all
    @State private var exposureExportError: String?

    // Cached filtered results
    @State private var installedPluginsWithTools: [(plugin: PluginState, tools: [ToolRegistry.ToolEntry])] = []
    @State private var remoteProviderTools: [(provider: MCPProvider, tools: [ToolRegistry.ToolEntry])] = []
    @State private var pluginsWithMissingPermissionsCount: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            headerBar
                .managerHeaderEntrance(hasAppeared: hasAppeared)

            Group {
                switch selectedTab {
                case .available:
                    availableToolsTabContent
                case .remote:
                    ProvidersView()
                case .sandbox:
                    SandboxPluginsTabContent(
                        builtInTools: builtInSandboxToolEntries,
                        policyInfoCache: policyInfoCache,
                        availabilityCache: availabilityCache,
                        onChange: { reload() }
                    )
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
            remoteProviderCount = providerManager.configuration.providers.count
            reload()
        }
        .onChange(of: exposureSourceFilter) { _, _ in
            recomputeAllowedToolNames()
        }
        .onChange(of: exposureStateFilter) { _, _ in
            recomputeAllowedToolNames()
        }
        .alert(
            Text("Export Failed", bundle: .module),
            isPresented: Binding(
                get: { exposureExportError != nil },
                set: { if !$0 { exposureExportError = nil } }
            )
        ) {
            Button(role: .cancel) {
                exposureExportError = nil
            } label: {
                Text("OK", bundle: .module)
            }
        } message: {
            if let error = exposureExportError {
                Text(error)
            }
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        ManagerHeaderWithTabs(
            title: L("Tools"),
            subtitle: L("Manage and discover tools")
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
            // Count only rows this view actually renders. Runtime-managed
            // folder/sandbox tools are visible as read-only operational
            // tools below, so they must be counted here too; otherwise chat
            // can have tools while Settings says every tool tab has zero.
            let runtimeShown = runtimeManagedToolEntries.count
            let availableShown =
                installedPluginsWithTools.reduce(0) { $0 + $1.tools.count }
                + remoteProviderTools.reduce(0) { $0 + $1.tools.count }
            HeaderTabsRow(
                selection: $selectedTab,
                counts: [
                    .available: availableShown + runtimeShown,
                    .remote: remoteProviderCount,
                    .sandbox: SandboxPluginLibrary.shared.plugins.count + builtInSandboxToolEntries.count,
                ],
                searchText: $searchText,
                searchPlaceholder: "Search tools"
            )
        }
    }

    // MARK: - Available Tools Tab (shows all tools from plugins and providers)

    private var availableToolsTabContent: some View {
        ScrollView {
            // A single LazyVStack so every tool row is an individual lazy child.
            // Group rows are emitted via bare `ForEach` (not wrapped in a
            // `VStack`), since a nested stack would be realized as one eager
            // child and defeat virtualization. Row spacing is 8; section
            // headers and intro cards add 8 more top padding for a 16 gap.
            LazyVStack(spacing: 8) {
                SectionHeader(
                    title: L("Available Tools"),
                    description: "Tools from installed plugins and connected providers"
                )

                if let exposureDiagnostic, !exposureDiagnostic.rows.isEmpty {
                    ToolExposureControlCenter(
                        diagnostic: exposureDiagnostic,
                        matchingCount: filteredExposureRows.count,
                        sourceFilter: $exposureSourceFilter,
                        stateFilter: $exposureStateFilter,
                        onExport: exportExposureReport
                    )
                    .padding(.top, 8)
                }

                let builtInNative = visibleTools(builtInNativeToolEntries)
                let runtimeTools = visibleTools(runtimeManagedToolEntries)
                let pluginGroups = visiblePluginGroups()
                let remoteGroups = visibleRemoteGroups()

                let hasAnyTool =
                    !builtInNativeToolEntries.isEmpty
                    || !runtimeManagedToolEntries.isEmpty
                    || !installedPluginsWithTools.isEmpty
                    || !remoteProviderTools.isEmpty
                let hasAnyVisible =
                    !builtInNative.isEmpty
                    || !runtimeTools.isEmpty
                    || !pluginGroups.isEmpty
                    || !remoteGroups.isEmpty

                if !hasAnyTool {
                    emptyState(
                        icon: "wrench.and.screwdriver",
                        title: L("No tools available"),
                        subtitle: searchText.isEmpty
                            ? L("Enable a working folder, sandbox, plugin, or remote provider to add tools")
                            : L("Try a different search term")
                    )
                } else if !hasAnyVisible {
                    filteredEmptyState
                } else {
                    if pluginsWithMissingPermissionsCount > 0 {
                        ToolPermissionBanner(count: pluginsWithMissingPermissionsCount)
                            .padding(.top, 8)
                    }

                    if !builtInNative.isEmpty {
                        InstalledSectionHeader(title: L("Built-in Tools"), icon: "shippingbox")
                            .padding(.top, 8)

                        cappedGroup(key: "builtInNative", tools: builtInNative) { entry in
                            RuntimeManagedToolEntryRow(
                                entry: entry,
                                badge: builtInBadge(for: entry),
                                policyInfo: policyInfoCache[entry.name],
                                availability: cachedAvailability(availabilityCache, for: entry),
                                exposureRow: exposureRowsByName[entry.name],
                                onChange: { applyLocalToolMutation(name: entry.name) }
                            )
                        }
                    }

                    if !runtimeTools.isEmpty {
                        InstalledSectionHeader(title: L("Runtime Tools"), icon: "terminal")
                            .padding(.top, 8)

                        cappedGroup(key: "runtime", tools: runtimeTools) { entry in
                            RuntimeManagedToolEntryRow(
                                entry: entry,
                                badge: runtimeBadge(for: entry),
                                policyInfo: policyInfoCache[entry.name],
                                availability: cachedAvailability(availabilityCache, for: entry),
                                exposureRow: exposureRowsByName[entry.name],
                                onChange: { applyLocalToolMutation(name: entry.name) }
                            )
                        }
                    }

                    if !pluginGroups.isEmpty {
                        InstalledSectionHeader(title: L("Plugin Tools"), icon: "puzzlepiece.extension")
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
                        InstalledSectionHeader(title: L("Remote Tools"), icon: "server.rack")
                            .padding(.top, 8)

                        ForEach(remoteGroups, id: \.provider.id) { item in
                            RemoteProviderToolsCard(
                                provider: item.provider,
                                tools: item.tools,
                                providerState: providerManager.providerStates[item.provider.id],
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
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
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

    // MARK: - Helpers

    private func updateFilteredLists() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryLower = query.lowercased()
        let currentToolEntries = toolEntries
        let runtimeManagedNames = ToolRegistry.shared.runtimeManagedToolNames
        let builtInSandboxNames = ToolRegistry.shared.builtInSandboxToolNamesSnapshot
        let currentPlugins = repoService.plugins
        let currentProviders = providerManager.configuration.providers
        let currentProviderStates = providerManager.providerStates

        // Snapshot the exposure diagnostic up front (the only DB-backed step)
        // so the detached pass below can also partition built-in/native tools
        // from the same source classification.
        let diagnostic = await ToolIndexService.shared.exposureSnapshot()
        guard !Task.isCancelled else { return }
        let rowsByName = Dictionary(uniqueKeysWithValues: diagnostic.rows.map { ($0.toolName, $0) })

        let (
            installedPluginsResult,
            remoteToolsResult,
            runtimeToolsResult,
            builtInSandboxToolsResult,
            builtInNativeToolsResult
        ) =
            await Task.detached(priority: .userInitiated) {

                func matchesToolSearch(_ tool: ToolRegistry.ToolEntry) -> Bool {
                    query.isEmpty
                        || SearchService.matches(query: query, in: tool.name)
                        || SearchService.matches(query: query, in: tool.description)
                }

                // 1. Installed Plugins with Tools (for Available tab)
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

                // 2. Remote Provider Tools (for Available tab)
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
                // sandbox mode is active. Settings must reflect them.
                let runtimeTools =
                    currentToolEntries
                    .filter { runtimeManagedNames.contains($0.name) }
                    .filter(matchesToolSearch)

                let builtInSandboxTools =
                    currentToolEntries
                    .filter { builtInSandboxNames.contains($0.name) }
                    .filter(matchesToolSearch)

                // 4. Built-in and native tools that have no other home. Every
                // other group (plugin/provider/runtime) is keyed off concrete
                // catalog entries; these are the remaining registered tools
                // (capability infrastructure, native helpers) classified as
                // built-in/native by the exposure diagnostic.
                let shownNames =
                    Set(runtimeTools.map(\.name))
                    .union(installedPlugins.flatMap { $0.tools.map(\.name) })
                    .union(remoteTools.flatMap { $0.tools.map(\.name) })
                let builtInNativeTools =
                    currentToolEntries
                    .filter { entry in
                        guard let source = rowsByName[entry.name]?.source else { return false }
                        return source == .builtIn || source == .native
                    }
                    .filter { !shownNames.contains($0.name) }
                    .filter(matchesToolSearch)

                return (installedPlugins, remoteTools, runtimeTools, builtInSandboxTools, builtInNativeTools)
            }.value

        guard !Task.isCancelled else { return }

        installedPluginsWithTools = installedPluginsResult
        remoteProviderTools = remoteToolsResult
        runtimeManagedToolEntries = runtimeToolsResult
        builtInSandboxToolEntries = builtInSandboxToolsResult
        builtInNativeToolEntries = builtInNativeToolsResult

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
        recomputeAllowedToolNames()
        recomputePermissionBannerCount()
    }

    private var filteredExposureRows: [ToolExposureDiagnostic.Row] {
        guard let exposureDiagnostic else { return [] }
        return exposureDiagnostic.filteredRows(
            query: searchText,
            source: exposureSourceFilter.source,
            state: exposureStateFilter.state
        )
    }

    /// Re-derive the source/state allowed-name set from the in-memory
    /// diagnostic. Cheap and main-thread only; called when the filters change
    /// or after a refresh, never triggering the DB-backed snapshot.
    private func recomputeAllowedToolNames() {
        guard let exposureDiagnostic else {
            allowedToolNames = []
            return
        }
        if exposureSourceFilter == .all && exposureStateFilter == .all {
            allowedToolNames = Set(exposureDiagnostic.rows.map(\.toolName))
        } else {
            allowedToolNames = Set(
                exposureDiagnostic.filteredRows(
                    source: exposureSourceFilter.source,
                    state: exposureStateFilter.state
                ).map(\.toolName)
            )
        }
    }

    private func recomputePermissionBannerCount() {
        var count = 0
        for (_, tools) in installedPluginsWithTools {
            let needsPermission = tools.contains { entry in
                policyInfoCache[entry.name]?.systemPermissionStates.values.contains(false) == true
            }
            if needsPermission { count += 1 }
        }
        pluginsWithMissingPermissionsCount = count
    }

    // MARK: - Grouped list filtering

    private var filterActive: Bool {
        exposureSourceFilter != .all || exposureStateFilter != .all
    }

    /// Narrow a group's tools by the active source/state filters. Free-text
    /// search is already applied while the groups are built in
    /// `updateFilteredLists()`, so this only intersects the in-memory
    /// allowed-name set.
    private func visibleTools(_ tools: [ToolRegistry.ToolEntry]) -> [ToolRegistry.ToolEntry] {
        guard filterActive else { return tools }
        return tools.filter { allowedToolNames.contains($0.name) }
    }

    private func visiblePluginGroups() -> [(plugin: PluginState, tools: [ToolRegistry.ToolEntry])] {
        installedPluginsWithTools.compactMap { item in
            let tools = visibleTools(item.tools)
            if tools.isEmpty {
                // Surface load-error plugins (which have no tools) only when not
                // narrowing by source/state, since a state filter can't match them.
                if !filterActive && item.plugin.hasLoadError {
                    return (item.plugin, [])
                }
                return nil
            }
            return (item.plugin, tools)
        }
    }

    private func visibleRemoteGroups() -> [(provider: MCPProvider, tools: [ToolRegistry.ToolEntry])] {
        remoteProviderTools.compactMap { item in
            let tools = visibleTools(item.tools)
            return tools.isEmpty ? nil : (item.provider, tools)
        }
    }

    private var filteredEmptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundColor(theme.tertiaryText)
            Text("No exposure rows match the current filters", bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground.opacity(0.5)))
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
        patch(&builtInSandboxToolEntries)
        patch(&builtInNativeToolEntries)
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
            recomputeAllowedToolNames()
        }
    }

    private func builtInBadge(for entry: ToolRegistry.ToolEntry) -> String {
        if exposureRowsByName[entry.name]?.source == .native {
            return L("Native")
        }
        return L("Built-in")
    }

    private func runtimeBadge(for entry: ToolRegistry.ToolEntry) -> String {
        if ToolRegistry.shared.builtInSandboxToolNamesSnapshot.contains(entry.name) {
            return L("Sandbox")
        }
        if ToolRegistry.folderToolNames.contains(entry.name) {
            return L("Folder")
        }
        return L("Runtime")
    }

    /// Snapshot the in-memory registry/provider state the filters read.
    /// Kept separate so the initial `.task` load can populate it without
    /// spawning a second `updateFilteredLists()` pass.
    private func refreshToolSnapshot() {
        toolEntries = ToolRegistry.shared.listTools()
        remoteProviderCount = providerManager.configuration.providers.count
    }

    private func reload() {
        refreshToolSnapshot()
        Task { await updateFilteredLists() }
    }

    private func exportExposureReport() {
        guard let exposureDiagnostic else { return }
        let report = exposureDiagnostic.reporterSafeMarkdown(rows: filteredExposureRows)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "osaurus-tool-exposure-report.md"
        Task { @MainActor in
            guard await panel.beginModal() == .OK, let url = panel.url else { return }
            do {
                try report.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                exposureExportError = error.localizedDescription
            }
        }
    }

    /// Honour one-shot navigation requests routed through
    /// `ManagementStateManager.pendingToolsSubTab` (e.g. the Claude plugin
    /// install summary deep-linking to the Remote MCP tab after OAuth or
    /// bearer-token imports).
    private func applyPendingSubTabRequest() {
        guard let raw = managementState.pendingToolsSubTab,
            let target = ToolsTab(rawValue: raw)
        else { return }
        selectedTab = target
        managementState.pendingToolsSubTab = nil
    }
}

/// Tool availability from a per-refresh snapshot, falling back to a direct
/// (O(1)) registry lookup if the cache hasn't been populated for this tool.
@MainActor
private func cachedAvailability(
    _ cache: [String: ToolAvailability],
    for entry: ToolRegistry.ToolEntry
) -> ToolAvailability {
    cache[entry.name] ?? ToolRegistry.shared.availability(forTool: entry.name)
}

// MARK: - Tool Exposure Control Center

private enum ToolExposureSourceFilter: String, CaseIterable, Identifiable {
    case all
    case builtIn
    case runtime
    case plugin
    case mcpProvider
    case sandboxPlugin
    case native
    case unknown

    var id: String { rawValue }

    var source: ToolExposureSource? {
        switch self {
        case .all:
            return nil
        case .builtIn:
            return .builtIn
        case .runtime:
            return .runtime
        case .plugin:
            return .plugin
        case .mcpProvider:
            return .mcpProvider
        case .sandboxPlugin:
            return .sandboxPlugin
        case .native:
            return .native
        case .unknown:
            return .unknown
        }
    }

    var title: String {
        source?.displayLabel ?? "All Sources"
    }
}

private enum ToolExposureStateFilter: String, CaseIterable, Identifiable {
    case all
    case exposed
    case loadable
    case hidden
    case disabled
    case blocked
    case unavailable

    var id: String { rawValue }

    var state: ToolExposureState? {
        switch self {
        case .all:
            return nil
        case .exposed:
            return .exposed
        case .loadable:
            return .loadable
        case .hidden:
            return .hidden
        case .disabled:
            return .disabled
        case .blocked:
            return .blocked
        case .unavailable:
            return .unavailable
        }
    }

    var title: String {
        state?.displayLabel ?? "All States"
    }

    static func filter(for state: ToolExposureState) -> ToolExposureStateFilter {
        switch state {
        case .exposed: return .exposed
        case .loadable: return .loadable
        case .hidden: return .hidden
        case .disabled: return .disabled
        case .blocked: return .blocked
        case .unavailable: return .unavailable
        }
    }
}

/// Shared color/icon styling for exposure states, used by the control-center
/// summary chips and the per-row state pill so they always agree.
private enum ToolExposureStateStyle {
    static func color(for state: ToolExposureState, theme: ThemeProtocol) -> Color {
        switch state {
        case .exposed: return theme.successColor
        case .loadable: return theme.accentColor
        case .hidden: return theme.warningColor
        case .disabled: return theme.secondaryText
        case .blocked, .unavailable: return theme.errorColor
        }
    }

    static func icon(for state: ToolExposureState) -> String {
        switch state {
        case .exposed: return "eye"
        case .loadable: return "arrow.down.circle"
        case .hidden: return "eye.slash"
        case .disabled: return "power"
        case .blocked: return "lock"
        case .unavailable: return "exclamationmark.triangle"
        }
    }
}

private struct ToolExposureControlCenter: View {
    @Environment(\.theme) private var theme

    let diagnostic: ToolExposureDiagnostic
    /// Number of tools matching the active search + source + state filters,
    /// used only for the `matching/total` badge.
    let matchingCount: Int
    @Binding var sourceFilter: ToolExposureSourceFilter
    @Binding var stateFilter: ToolExposureStateFilter
    let onExport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.accentColor.opacity(0.12))
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Tool Exposure Control Center", bundle: .module)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(theme.primaryText)
                    Text("Audit how each tool is exposed to the model", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text("\(matchingCount)/\(diagnostic.rows.count)", bundle: .module)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.tertiaryBackground))
                    .fixedSize()
            }

            FlowLayout(spacing: 6) {
                exposureCountChip(.exposed)
                exposureCountChip(.loadable)
                exposureCountChip(.hidden)
                exposureCountChip(.disabled)
                exposureCountChip(.blocked)
                exposureCountChip(.unavailable)
            }

            HStack(spacing: 8) {
                ExposureFilterMenu(
                    icon: "square.grid.2x2",
                    title: sourceFilter.title,
                    options: ToolExposureSourceFilter.allCases,
                    selection: $sourceFilter
                )

                ExposureFilterMenu(
                    icon: "line.3.horizontal.decrease.circle",
                    title: stateFilter.title,
                    options: ToolExposureStateFilter.allCases,
                    selection: $stateFilter
                )

                Spacer(minLength: 8)

                Button(action: onExport) {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Export", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(theme.primaryText)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(theme.tertiaryBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(theme.inputBorder, lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .fixedSize()
                .help(Text("Export reporter-safe exposure report", bundle: .module))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(HoverableCardBackground())
    }

    /// A summary chip that doubles as a one-tap state filter. `lineLimit(1)` +
    /// `fixedSize` keep each label on one line; `FlowLayout` wraps the row
    /// instead of letting labels break character-by-character.
    private func exposureCountChip(_ state: ToolExposureState) -> some View {
        let isActive = stateFilter.state == state
        let tint = ToolExposureStateStyle.color(for: state, theme: theme)
        return Button {
            stateFilter = isActive ? .all : ToolExposureStateFilter.filter(for: state)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: ToolExposureStateStyle.icon(for: state))
                    .font(.system(size: 9, weight: .semibold))
                Text("\(diagnostic.stateCounts[state, default: 0]) \(state.displayLabel)", bundle: .module)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundColor(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(tint.opacity(isActive ? 0.22 : 0.12))
                    .overlay(Capsule().stroke(tint.opacity(isActive ? 0.55 : 0), lineWidth: 1))
            )
        }
        .buttonStyle(PlainButtonStyle())
        .help(Text("Filter by this state", bundle: .module))
    }
}

private protocol ToolExposureFilterOption: Identifiable, Hashable {
    var title: String { get }
}

extension ToolExposureSourceFilter: ToolExposureFilterOption {}
extension ToolExposureStateFilter: ToolExposureFilterOption {}

private struct ExposureFilterMenu<Option: ToolExposureFilterOption>: View {
    @Environment(\.theme) private var theme

    let icon: String
    let title: String
    let options: [Option]
    @Binding var selection: Option

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    HStack {
                        if option == selection {
                            Image(systemName: "checkmark")
                        }
                        Text(LocalizedStringKey(option.title), bundle: .module)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundColor(theme.primaryText)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(theme.tertiaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// Compact exposure-state pill shown on grouped tool rows. Renders nothing when
/// no diagnostic row is available; hovering reveals the verbose index/search
/// diagnostics so rows stay clean by default.
private struct ToolExposureStatePill: View {
    @Environment(\.theme) private var theme
    let row: ToolExposureDiagnostic.Row?

    var body: some View {
        if let row {
            ExposurePill(
                label: row.state.displayLabel,
                color: ToolExposureStateStyle.color(for: row.state, theme: theme)
            )
            .help(Self.diagnosticsDetail(for: row))
        }
    }

    private static func diagnosticsDetail(for row: ToolExposureDiagnostic.Row) -> String {
        let index = row.indexedForSearch ? "indexed" : "not indexed"
        let search = row.searchableByCapabilitiesDiscover ? "discoverable" : "not discoverable"
        let reasons = row.searchReasonCodes.map(\.rawValue).joined(separator: ", ")
        var detail = "\(index) / \(search)"
        if !reasons.isEmpty { detail += " / \(reasons)" }
        return detail + " · tokens \(row.tokenEstimate)"
    }
}

/// Availability reason plus the optional schema token estimate, shown as the
/// trailing detail line on every grouped tool row.
private struct ToolRowMetaLine: View {
    @Environment(\.theme) private var theme
    let availability: ToolAvailability
    let exposureRow: ToolExposureDiagnostic.Row?

    var body: some View {
        HStack(spacing: 6) {
            Text(availability.displayDetail)
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
                .lineLimit(1)
            if let exposureRow {
                Text("tokens \(exposureRow.tokenEstimate)", bundle: .module)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }
        }
    }
}

private struct ExposurePill: View {
    let label: String
    let color: Color

    var body: some View {
        Text(LocalizedStringKey(label), bundle: .module)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

// MARK: - Sandbox Plugins Tab

private struct SandboxPluginsTabContent: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var pluginLibrary = SandboxPluginLibrary.shared

    let builtInTools: [ToolRegistry.ToolEntry]
    let policyInfoCache: [String: ToolRegistry.ToolPolicyInfo]
    let availabilityCache: [String: ToolAvailability]
    let onChange: () -> Void

    @State private var showCreatePlugin = false
    @State private var editingPlugin: SandboxPlugin?
    @State private var pluginToDelete: SandboxPlugin?
    @State private var showDeleteConfirm = false
    @State private var actionError: String?

    var body: some View {
        ScrollView {
            // Mirror the Available tab: a single LazyVStack with bare `ForEach`
            // groups so tool rows virtualize instead of laying out eagerly.
            LazyVStack(spacing: 8) {
                SectionHeader(
                    title: L("Sandbox Tools"),
                    description:
                        "Built-in sandbox execution tools and JSON-defined plugin tools that run inside the sandbox container."
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

                    Button(action: { showCreatePlugin = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 11))
                            Text("Create Sandbox Tool", bundle: .module)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.accentColor))
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                if !builtInTools.isEmpty {
                    InstalledSectionHeader(title: L("Built-in Sandbox Tools"), icon: "terminal")
                        .padding(.top, 8)

                    ForEach(builtInTools) { entry in
                        RuntimeManagedToolEntryRow(
                            entry: entry,
                            badge: L("Sandbox"),
                            policyInfo: policyInfoCache[entry.name],
                            availability: cachedAvailability(availabilityCache, for: entry),
                            onChange: onChange
                        )
                    }
                }

                if pluginLibrary.plugins.isEmpty && builtInTools.isEmpty {
                    sandboxPluginEmptyState
                } else {
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
        .alert(Text("Remove Plugin?", bundle: .module), isPresented: $showDeleteConfirm) {
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
                }
            } label: {
                Text("Remove", bundle: .module)
            }
        } message: {
            if let p = pluginToDelete {
                Text("Remove \"\(p.name)\" from the library? This will also unregister its tools.", bundle: .module)
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

    private var sandboxPluginEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(theme.tertiaryText)

            Text("No sandbox tools", bundle: .module)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(theme.secondaryText)

            Text(
                "Create a plugin or import a JSON recipe. Plugins are automatically provisioned when any agent uses them.",
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

    private var toolCount: Int {
        plugin.tools?.count ?? 0
    }

    private var toolNames: [String] {
        plugin.tools?.map { "\(plugin.id)_\($0.id)" } ?? []
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
            }

            if isExpanded {
                Divider()
                    .padding(.vertical, 4)

                if let tools = plugin.tools, !tools.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(tools, id: \.id) { spec in
                            let toolName = "\(plugin.id)_\(spec.id)"
                            let entry = ToolRegistry.shared.entry(named: toolName)
                            sandboxToolRow(spec: spec, entry: entry)
                        }
                    }
                } else {
                    HStack {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundColor(theme.tertiaryText)
                        Text("No tools defined in this plugin", bundle: .module)
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

/// Rounded card chrome whose hover-reactive border/shadow live in their own
/// small subview. Used as a `.background(...)` so hovering a card re-renders
/// only this lightweight view instead of invalidating the card's content
/// body — important when the mouse sweeps across a list of cards.
private struct HoverableCardBackground: View {
    @Environment(\.theme) private var theme
    @State private var isHovering = false

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
            .onHover { isHovering = $0 }
    }
}

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        ToolsManagerView()
    }
#endif

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
                Text(
                    "\(count) plugin\(count == 1 ? "" : "s") need\(count == 1 ? "s" : "") system permissions",
                    bundle: .module
                )
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)
                Text("Expand each plugin to grant the required permissions", bundle: .module)
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
                    Text("System Settings", bundle: .module)
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

// MARK: - Show All Tools Button

/// Disclosure control that toggles a capped tool group between its first
/// `toolGroupRenderCap` rows and the full list.
private struct ShowAllToolsButton: View {
    @Environment(\.theme) private var theme
    let hiddenCount: Int
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                if isExpanded {
                    Text("Show fewer", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                } else {
                    Text("Show \(hiddenCount) more", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                }
                Spacer()
            }
            .foregroundColor(theme.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.tertiaryBackground.opacity(0.5))
            )
        }
        .buttonStyle(PlainButtonStyle())
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
                            exposureRow: exposureRowsByName[entry.name],
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
    let providerState: MCPProviderState?
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
                            exposureRow: exposureRowsByName[entry.name],
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

// MARK: - Runtime Managed Tool Entry Row

private struct RuntimeManagedToolEntryRow: View {
    @Environment(\.theme) private var theme
    let entry: ToolRegistry.ToolEntry
    let badge: String
    let policyInfo: ToolRegistry.ToolPolicyInfo?
    let availability: ToolAvailability
    var exposureRow: ToolExposureDiagnostic.Row? = nil
    let onChange: () -> Void

    private var hasMissingSystemPermissions: Bool {
        guard let info = policyInfo else { return false }
        return info.systemPermissionStates.values.contains(false)
    }

    var body: some View {
        HStack(spacing: 10) {
            toolIcon
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.name)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(theme.primaryText)

                    if hasMissingSystemPermissions {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundColor(theme.warningColor)
                    }

                    ToolAvailabilityBadge(availability: availability)
                    ToolExposureStatePill(row: exposureRow)
                }

                Text(entry.description)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
                ToolRowMetaLine(availability: availability, exposureRow: exposureRow)
            }
            // Expand the info column instead of a trailing Spacer so the row has
            // one fewer flexible layout child to negotiate per pass.
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(badge)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(theme.tertiaryBackground))

            if let info = policyInfo {
                ToolPolicyMenu(
                    toolName: entry.name,
                    info: info,
                    onChange: onChange
                )
            }
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
            Image(systemName: "terminal")
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
}

// MARK: - Tool Entry Row (shared with PluginsView)

struct ToolEntryRow: View {
    @Environment(\.theme) private var theme
    let entry: ToolRegistry.ToolEntry
    let policyInfo: ToolRegistry.ToolPolicyInfo?
    let availability: ToolAvailability
    var exposureRow: ToolExposureDiagnostic.Row? = nil
    let onChange: () -> Void

    private var hasMissingSystemPermissions: Bool {
        guard let info = policyInfo else { return false }
        return info.systemPermissionStates.values.contains(false)
    }

    var body: some View {
        HStack(spacing: 10) {
            toolIcon
            // Expand the info column instead of a trailing Spacer to drop one
            // flexible layout child from the row.
            toolInfo
                .frame(maxWidth: .infinity, alignment: .leading)

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

                ToolAvailabilityBadge(availability: availability)
                ToolExposureStatePill(row: exposureRow)
            }
            Text(entry.description)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .lineLimit(1)
            ToolRowMetaLine(availability: availability, exposureRow: exposureRow)
        }
    }
}

// MARK: - Remote Tool Row

private struct RemoteToolRow: View {
    @Environment(\.theme) private var theme
    let entry: ToolRegistry.ToolEntry
    let providerName: String
    let policyInfo: ToolRegistry.ToolPolicyInfo?
    let availability: ToolAvailability
    var exposureRow: ToolExposureDiagnostic.Row? = nil
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
                HStack(spacing: 4) {
                    Text(displayName)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(theme.primaryText)

                    ToolAvailabilityBadge(availability: availability)
                    ToolExposureStatePill(row: exposureRow)
                }
                Text(entry.description)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
                ToolRowMetaLine(availability: availability, exposureRow: exposureRow)
            }
            // Expand the info column instead of a trailing Spacer to drop one
            // flexible layout child from the row.
            .frame(maxWidth: .infinity, alignment: .leading)

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
