//
//  AgentCapabilityManagerView.swift
//  osaurus
//
//  Full-tab takeover UI for managing an agent's assigned tools, grouped by
//  source (per-Plugin / per-MCP-provider / per-sandbox-plugin).
//
//  The picker is the single source of truth for which tools reach the model.
//  A top-level "Auto-discover" toggle decides whether the model sees the
//  entire assigned set every turn (Manual) or a small always-loaded hot set
//  that it grows on demand via `capabilities_discover` / `capabilities_load`
//  (Auto). Either way, the per-item toggles in the table are honored at
//  runtime — see `CapabilitySearch` and `SystemPromptComposer.compose` for
//  the wiring. Skills are not assigned per-agent: every installed skill is
//  automatically available to custom agents (see the Skills library).
//

import SwiftUI

// MARK: - Source Grouping

/// Logical bucket for the picker. Each maps to one or more `CapabilityRow.groupHeader`s.
///
/// Module-internal (not file-private) so `OsaurusCoreTests` can verify the
/// classifier helpers on `CapabilityRowBuilder` stay in lockstep with the
/// inline bucketing in `CapabilityRowBuilder.build`.
enum CapabilitySource: Hashable {
    /// Built-in tools — always loaded by the runtime, shown for transparency.
    case builtIn
    /// One per native dylib plugin.
    case plugin(pluginId: String, displayName: String)
    /// One per remote MCP provider.
    case mcpProvider(name: String)
    /// One per provisioned sandbox plugin.
    case sandboxPlugin(pluginId: String)

    var groupId: String {
        switch self {
        case .builtIn: return "src:builtin"
        case .plugin(let pluginId, _): return "src:plugin:\(pluginId)"
        case .mcpProvider(let name): return "src:mcp:\(name)"
        case .sandboxPlugin(let pluginId): return "src:sandbox:\(pluginId)"
        }
    }

    var displayName: String {
        switch self {
        case .builtIn: return L("Built-in")
        case .plugin(_, let name): return name
        case .mcpProvider(let name): return name
        case .sandboxPlugin(let pluginId): return pluginId
        }
    }

    var icon: String {
        switch self {
        case .builtIn: return "shippingbox.circle"
        case .plugin: return "puzzlepiece.extension"
        case .mcpProvider: return "antenna.radiowaves.left.and.right"
        case .sandboxPlugin: return "shippingbox"
        }
    }

    /// Built-in tools are surfaced for transparency only — toggling them
    /// has no effect at runtime (they're always loaded).
    var isInformational: Bool {
        switch self {
        case .builtIn: return true
        default: return false
        }
    }
}

// MARK: - Filter Chip

enum CapabilityFilter: String, CaseIterable, Identifiable {
    case all
    case assigned

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return L("All")
        case .assigned: return L("Assigned")
        }
    }
}

// MARK: - Row Builder

/// Pure transform from snapshots of the live registries + agent state into the
/// `[CapabilityRow]` array consumed by `CapabilitiesTableRepresentable`. Kept
/// pure so it can be diffed cheaply on every state change.
///
/// Module-internal (not file-private) so `OsaurusCoreTests` can drive
/// `build(_:)` and the `source(forTool:)` classifier directly. The "render
/// rows from a controlled `Input`" surface is the regression seam for #1003 —
/// the picker bug was caused by `childrenOf` disagreeing with `build`'s
/// bucketing.
@MainActor
enum CapabilityRowBuilder {

    struct Input {
        let visibleTools: [ToolRegistry.ToolEntry]
        let plugins: [PluginManager.LoadedPlugin]
        let enabledToolNames: Set<String>
        let toolMode: ToolSelectionMode
        let searchQuery: String
        let filter: CapabilityFilter
        let expandedGroups: Set<String>
    }

    static func build(_ input: Input) -> [CapabilityRow] {
        let normalized = input.searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let hasSearch = !normalized.isEmpty

        // Bucket tools into their source group.
        var buckets: [String: [ToolRegistry.ToolEntry]] = [:]
        var sources: [String: CapabilitySource] = [:]
        var sourceOrder: [String] = []

        func ensureSource(_ source: CapabilitySource) {
            let id = source.groupId
            if buckets[id] == nil {
                buckets[id] = []
                sources[id] = source
                sourceOrder.append(id)
            }
        }

        let pluginNameById = Dictionary(
            uniqueKeysWithValues: input.plugins.map {
                ($0.plugin.id, $0.plugin.manifest.name ?? $0.plugin.id)
            }
        )

        // Bucket every tool via the same classifier `childrenOf` uses.
        // Routing both call sites through one helper is what keeps
        // bulk-toggle and the rendered rows in sync (#1003) — if a future
        // tool source is ever added, only `source(forTool:)` needs to grow.
        for tool in input.visibleTools {
            let src = source(forTool: tool, pluginNameById: pluginNameById)
            ensureSource(src)
            buckets[src.groupId]?.append(tool)
        }

        // Stable order by `sortRank` (plugins, then MCP providers, then
        // sandbox plugins), ties broken alpha by display name. The built-in
        // bucket may be present in `sources` but gets filtered out at row
        // emission below — its sort rank doesn't matter.
        sourceOrder.sort { lhs, rhs in
            guard let l = sources[lhs], let r = sources[rhs] else { return lhs < rhs }
            return sortRank(l) < sortRank(r)
                || (sortRank(l) == sortRank(r)
                    && l.displayName.localizedCaseInsensitiveCompare(r.displayName) == .orderedAscending)
        }

        // Emit rows.
        var rows: [CapabilityRow] = []
        for groupId in sourceOrder {
            guard let source = sources[groupId], let tools = buckets[groupId] else { continue }

            // Informational sources (built-in / runtime-managed tools)
            // can't be toggled per-row and are skipped by `childrenOf` in
            // bulk operations, so showing them only adds confusion — the
            // master checkbox renders as "checked" but no click is
            // actionable. Hide the entire group from the picker.
            if source.isInformational { continue }

            // Search: keep only items that match. If empty, drop the group.
            let filteredTools = tools.filter { entry in
                guard !hasSearch else {
                    return matches(query: normalized, name: entry.name, description: entry.description)
                }
                return true
            }

            // Filter chip: assigned-only refines per-item.
            let toolsForRows: [ToolRegistry.ToolEntry] = {
                if input.filter == .assigned {
                    return filteredTools.filter { input.enabledToolNames.contains($0.name) }
                }
                return filteredTools
            }()

            if hasSearch && toolsForRows.isEmpty {
                continue
            }
            if input.filter == .assigned && toolsForRows.isEmpty {
                continue
            }

            // Counts reflect the FULL group, not the search/filter-reduced
            // subset, so the badge always agrees with what the master
            // checkbox toggles — `childrenOf` resolves bulk targets off the
            // registry, and a badge computed from the rendered subset would
            // claim "0/3" while the checkbox flips 21 tools.
            let enabledCount = tools.reduce(0) {
                $0 + (input.enabledToolNames.contains($1.name) ? 1 : 0)
            }
            let totalCount = tools.count

            // Auto-expand groups when actively searching so matches are visible at a glance.
            let isExpanded = hasSearch || input.expandedGroups.contains(groupId)

            rows.append(
                .groupHeader(
                    id: groupId,
                    name: source.displayName,
                    icon: source.icon,
                    enabledCount: enabledCount,
                    totalCount: totalCount,
                    isExpanded: isExpanded
                )
            )

            guard isExpanded else { continue }

            for tool in toolsForRows {
                let availability = availability(forTool: tool, input: input)
                rows.append(
                    .tool(
                        id: "\(groupId)::tool::\(tool.name)",
                        name: tool.name,
                        description: tool.description,
                        enabled: input.enabledToolNames.contains(tool.name),
                        availability: availability,
                        // Informational sources were filtered above; every
                        // tool that reaches this point is freely toggleable.
                        isAgentRestricted: false,
                        catalogTokens: tool.estimatedTokens,
                        estimatedTokens: tool.estimatedTokens
                    )
                )
            }
        }
        return rows
    }

    private static func availability(forTool tool: ToolRegistry.ToolEntry, input: Input) -> ToolAvailability {
        let base = ToolRegistry.shared.availability(
            forTool: tool.name,
            agentAllowedNames: input.enabledToolNames
        )
        guard input.toolMode == .manual,
            input.enabledToolNames.contains(tool.name),
            base.reasonCodes == [.loadableViaCapabilitiesLoad]
        else { return base }

        return ToolAvailability(
            toolName: tool.name,
            runtime: base.runtime,
            groupName: base.groupName,
            reasonCodes: [.available],
            detail: "enabled for this agent; sent every turn in manual mode"
        )
    }

    private static func sortRank(_ source: CapabilitySource) -> Int {
        switch source {
        case .builtIn: return 0
        case .plugin: return 1
        case .mcpProvider: return 2
        case .sandboxPlugin: return 3
        }
    }

    /// Cheap substring match over name and description. The pre-existing fuzzy
    /// helper in `AgentsView.fuzzyScore` is intentionally NOT reused — the table
    /// is rebuilt on every keystroke and a substring scan is more than fast
    /// enough for the picker's scale.
    private static func matches(query: String, name: String, description: String) -> Bool {
        name.lowercased().contains(query) || description.lowercased().contains(query)
    }

    /// Decode the row id back into (groupId, kind, name) so the toggle handlers
    /// know which source they're touching.
    static func decode(rowId: String) -> (groupId: String, kind: String, payload: String)? {
        let parts = rowId.components(separatedBy: "::")
        guard parts.count == 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    /// Single source of truth for which `CapabilitySource` a tool belongs
    /// to. Used by both `build(_:)` (to bucket rendered rows) and
    /// `AgentCapabilityManagerView.childrenOf(groupId:)` (to resolve
    /// bulk-toggle targets without depending on which rows are currently
    /// rendered). Routing both call sites through one helper is what
    /// prevents the picker bug fixed in #1003 from reappearing — if these
    /// two ever disagreed, collapsed-group bulk toggles would silently
    /// drop capabilities.
    static func source(forTool tool: ToolRegistry.ToolEntry, pluginNameById: [String: String]) -> CapabilitySource {
        let registry = ToolRegistry.shared
        if registry.builtInToolNames.contains(tool.name) || registry.runtimeManagedToolNames.contains(tool.name) {
            return .builtIn
        }
        if registry.isMCPTool(tool.name), let provider = registry.groupName(for: tool.name) {
            return .mcpProvider(name: provider)
        }
        if registry.isSandboxTool(tool.name), let pid = registry.groupName(for: tool.name) {
            return .sandboxPlugin(pluginId: pid)
        }
        if registry.isPluginTool(tool.name), let pid = registry.groupName(for: tool.name) {
            return .plugin(pluginId: pid, displayName: pluginNameById[pid] ?? pid)
        }
        // Unclassified tools fall back to the built-in / always-loaded
        // group so they're still surfaced for transparency.
        return .builtIn
    }
}

// MARK: - Manager View

/// Picker for an agent's assigned tools, grouped by source. Hosts either as
/// the Tools tab body (live mode → writes through `AgentManager`) or embedded
/// in the Create Agent sheet (draft mode → writes through `@Binding`s the
/// caller bakes into the new agent on save).
struct AgentCapabilityManagerView: View {

    /// Where the picker reads and writes tool state.
    ///
    /// - `live`: Tools-tab path. Writes go through `AgentManager` and
    ///   persist immediately; `.agentUpdated` notifications keep the local
    ///   mirror in sync.
    /// - `draft`: Create-sheet path. Writes flow into the caller's bindings
    ///   and are baked into the new agent only when the user clicks "Create
    ///   Agent" — the agent doesn't exist yet, so no `AgentManager` calls.
    enum Source {
        case live(agentId: UUID)
        case draft(
            mode: Binding<ToolSelectionMode>,
            tools: Binding<Set<String>>
        )
    }

    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared

    let source: Source
    /// When non-nil, a "Done" affordance appears in the sticky header so the
    /// host (sheet / takeover) can be dismissed. When nil, the picker IS the
    /// host (e.g. the Tools tab body) and there's nothing to go back to.
    let onDismiss: (() -> Void)?

    /// Embedded mode used when the picker sits inside a host sheet that
    /// already supplies its own title chrome. Drops the picker's title row
    /// and bottom rule so the two headers don't stack, and relocates the
    /// Done affordance into the search row.
    let compact: Bool

    /// Live-mode init used by the Tools tab.
    init(agentId: UUID, onDismiss: (() -> Void)?, compact: Bool = false) {
        self.source = .live(agentId: agentId)
        self.onDismiss = onDismiss
        self.compact = compact
    }

    /// Draft-mode init used by the Create Agent sheet.
    init(
        draftMode: Binding<ToolSelectionMode>,
        draftTools: Binding<Set<String>>,
        onDismiss: (() -> Void)?,
        compact: Bool = false
    ) {
        self.source = .draft(mode: draftMode, tools: draftTools)
        self.onDismiss = onDismiss
        self.compact = compact
    }

    // MARK: Local UI state

    @State private var searchText: String = ""
    @State private var searchFocused: Bool = false
    @State private var filter: CapabilityFilter = .all
    @State private var expandedGroups: Set<String> = []

    /// Local mirror of tool state. In live mode it's seeded from
    /// `AgentManager` and re-synced on `.agentUpdated`; in draft mode it's
    /// seeded from the bindings and written back through them.
    @State private var enabledToolNames: Set<String> = []
    @State private var toolMode: ToolSelectionMode = .auto

    /// Snapshot of the registries this turn (rebuilt on `.toolsListChanged`).
    @State private var visibleTools: [ToolRegistry.ToolEntry] = []
    @State private var plugins: [PluginManager.LoadedPlugin] = []

    var body: some View {
        VStack(spacing: 0) {
            stickyHeader
                .background(theme.primaryBackground)
                .overlay(
                    Rectangle()
                        .fill(theme.primaryBorder)
                        .frame(height: 1)
                        .opacity(compact ? 0 : 1),
                    alignment: .bottom
                )

            // Intentionally NO `.id()` on the table: SwiftUI would recreate
            // the underlying NSScrollView on every state change and snap the
            // scroll position to the top. The coordinator already diffs rows
            // in place via NSDiffableDataSource, so identity stays stable.
            // The empty state overlays the (empty) table instead of replacing
            // it for the same reason.
            ZStack {
                CapabilitiesTableRepresentable(
                    rows: rows,
                    theme: theme,
                    onToggleGroup: handleToggleGroup,
                    onEnableAllInGroup: { handleBulkToggle(in: $0, enable: true) },
                    onDisableAllInGroup: { handleBulkToggle(in: $0, enable: false) },
                    onToggleTool: handleToggleTool
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if rows.isEmpty {
                    emptyState
                }
            }
            .background(theme.primaryBackground)
        }
        .onAppear {
            loadFromRegistries()
            seedIfNeeded()
            loadInitialState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toolsListChanged)) { _ in
            loadFromRegistries()
            // Live mode auto-grows the agent's enabled set when new tools
            // register, so the local mirror needs to re-sync. Draft mode's
            // bindings stay authoritative.
            loadFromAgent()
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentUpdated)) { _ in
            loadFromAgent()
        }
    }

    // MARK: - Sticky header

    private var stickyHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Helper-text row (standalone mode only) — mirrors the info line
            // every other detail tab leads with; the tab strip already names
            // the tab, so repeating a "Tools" title here was noise. In
            // compact mode the host sheet's header supplies the context.
            if !compact {
                HStack(spacing: 10) {
                    if onDismiss != nil { doneButton }

                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                    Text(
                        "Pick which tools this agent can use. Skills come from the shared library and are always available.",
                        bundle: .module
                    )
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)

                    Spacer()
                    summaryPill
                }
            }

            // Compact mode places the Done affordance left of the search field
            // so it reads as a "back" arrow into the host form, not a trailing
            // accessory of the input.
            HStack(spacing: 10) {
                if compact, onDismiss != nil { doneButton }
                searchField
                if compact { summaryPill }
                filterChips
            }

            autoDiscoverCard
        }
        .padding(.horizontal, compact ? 20 : 24)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var doneButton: some View {
        if let onDismiss {
            Button(action: onDismiss) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Done", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(theme.accentColor)
            }
            .buttonStyle(.plain)
        }
    }

    /// Names of every tool the picker can actually toggle (informational /
    /// built-in sources excluded). Drives the summary pill and chip counts
    /// so "X of N" always refers to the same universe the list shows.
    private var actionableToolNames: Set<String> {
        var names: Set<String> = []
        for tool in visibleTools {
            let source = CapabilityRowBuilder.source(forTool: tool, pluginNameById: [:])
            if !source.isInformational { names.insert(tool.name) }
        }
        return names
    }

    /// Assigned tools that still exist in the registry — stale allowlist
    /// entries (e.g. from an uninstalled plugin) shouldn't inflate counts.
    private var assignedActionableCount: Int {
        actionableToolNames.intersection(enabledToolNames).count
    }

    private var summaryPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 9))
            Text(
                "\(assignedActionableCount) of \(actionableToolNames.count) assigned",
                bundle: .module
            )
            .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(theme.accentColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(theme.accentColor.opacity(0.12))
                .overlay(Capsule().strokeBorder(theme.accentColor.opacity(0.2), lineWidth: 1))
        )
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(searchFocused ? theme.accentColor : theme.tertiaryText)
                .frame(width: 16)

            ZStack(alignment: .leading) {
                if searchText.isEmpty {
                    Text("Search by name or description...", bundle: .module)
                        .font(.system(size: 13))
                        .foregroundColor(theme.placeholderText)
                        .allowsHitTesting(false)
                }
                TextField(
                    "",
                    text: $searchText,
                    onEditingChanged: { editing in
                        withAnimation(.easeOut(duration: 0.15)) {
                            searchFocused = editing
                        }
                    }
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(theme.primaryText)
            }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .localizedHelp("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            searchFocused ? theme.accentColor.opacity(0.5) : theme.inputBorder,
                            lineWidth: searchFocused ? 1.5 : 1
                        )
                )
        )
    }

    private var autoDiscoverCard: some View {
        HStack(spacing: 12) {
            Image(systemName: toolMode == .auto ? "sparkles" : "list.bullet.rectangle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(toolMode == .auto ? theme.accentColor : theme.secondaryText)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(
                        toolMode == .auto ? theme.accentColor.opacity(0.12) : theme.inputBackground
                    )
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("Auto-discover relevant tools", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(
                    toolMode == .auto
                        ? "The model starts with a small set and loads more of your assigned tools on demand."
                        : "All assigned tools are sent to the model every turn.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { toolMode == .auto },
                    set: { newValue in commit(mode: newValue ? .auto : .manual) }
                )
            )
            .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
            .labelsHidden()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private var filterChips: some View {
        HStack(spacing: 6) {
            ForEach(CapabilityFilter.allCases) { option in
                let isSelected = option == filter
                let count = option == .all ? actionableToolNames.count : assignedActionableCount
                Button {
                    filter = option
                } label: {
                    HStack(spacing: 4) {
                        // Constant weight so chips don't change width (and
                        // shift their neighbor) when the selection moves.
                        Text(LocalizedStringKey(option.label), bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                        Text("\(count)", bundle: .module)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundColor(isSelected ? theme.accentColor : theme.tertiaryText)
                            .opacity(0.85)
                    }
                    .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(isSelected ? theme.accentColor.opacity(0.14) : theme.inputBackground)
                            .overlay(
                                Capsule(style: .continuous).strokeBorder(
                                    isSelected ? theme.accentColor.opacity(0.25) : theme.inputBorder,
                                    lineWidth: 1
                                )
                            )
                    )
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }

    // MARK: - Empty state

    /// Overlay shown when the row builder yields nothing. The copy and
    /// recovery action are contextual to WHY the list is empty — an active
    /// search, the Assigned filter with nothing assigned, or a genuinely
    /// empty tool registry.
    private var emptyState: some View {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(spacing: 8) {
            Image(systemName: trimmedSearch.isEmpty ? "wrench.and.screwdriver" : "magnifyingglass")
                .font(.system(size: 24, weight: .regular))
                .foregroundColor(theme.tertiaryText)
                .padding(.bottom, 4)

            if !trimmedSearch.isEmpty {
                Text("No tools match \u{201C}\(trimmedSearch)\u{201D}", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text("Try a different name or description.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                emptyStateAction(label: L("Clear Search")) {
                    searchText = ""
                }
            } else if filter == .assigned {
                Text("No tools assigned yet", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text("Switch to All and turn on the tools this agent should use.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                emptyStateAction(label: L("Show All Tools")) {
                    filter = .all
                }
            } else {
                Text("No tools available", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text("Install plugins or connect MCP servers to add tools.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
    }

    private func emptyStateAction(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.accentColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(theme.accentColor.opacity(0.12))
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(theme.accentColor.opacity(0.25), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
    }

    // MARK: - Rows

    private var rows: [CapabilityRow] {
        CapabilityRowBuilder.build(
            CapabilityRowBuilder.Input(
                visibleTools: visibleTools,
                plugins: plugins,
                enabledToolNames: enabledToolNames,
                toolMode: toolMode,
                searchQuery: searchText,
                filter: filter,
                expandedGroups: expandedGroups
            )
        )
    }

    // MARK: - Loading

    private func loadFromRegistries() {
        // We pass every enabled tool through to the row builder; built-in /
        // runtime-managed entries get classified into the informational
        // `.builtIn` source and then dropped at row-emission time so the
        // picker only surfaces actionable groups. See
        // `CapabilityRowBuilder.build` for the filter.
        visibleTools = ToolRegistry.shared.listTools().filter { $0.enabled }
        plugins = PluginManager.shared.plugins
    }

    /// Live mode only: ensure the agent's `manualToolNames` field is
    /// populated so the picker reads a real list instead of "nil".
    /// Draft mode skips this — its bindings are seeded by the parent before
    /// the manager is shown.
    private func seedIfNeeded() {
        guard case .live(let agentId) = source else { return }
        let liveToolNames = ToolRegistry.shared.listDynamicTools().map(\.name)
        // If the registry hasn't loaded yet, don't seed an empty allowlist —
        // the next `.toolsListChanged` would treat every later-registered
        // tool as "newly discovered" and grow the agent back to full.
        guard !liveToolNames.isEmpty else { return }
        agentManager.seedEnabledCapabilitiesIfNeeded(
            for: agentId,
            defaultToolNames: liveToolNames
        )
    }

    /// Populate the local mirror from whichever source is authoritative.
    private func loadInitialState() {
        switch source {
        case .live:
            loadFromAgent()
        case .draft(let mode, let tools):
            toolMode = mode.wrappedValue
            enabledToolNames = tools.wrappedValue
        }
    }

    private func loadFromAgent() {
        guard case .live(let agentId) = source else { return }
        toolMode = agentManager.effectiveToolSelectionMode(for: agentId)
        enabledToolNames = Set(agentManager.effectiveEnabledToolNames(for: agentId) ?? [])
    }

    // MARK: - Toggle Handlers

    private func handleToggleGroup(_ groupId: String) {
        if expandedGroups.contains(groupId) {
            expandedGroups.remove(groupId)
        } else {
            expandedGroups.insert(groupId)
        }
    }

    /// Bulk-flip every (non-restricted) child of a group on or off in one
    /// commit. Wired to the group header's enable-all / disable-all glyphs.
    private func handleBulkToggle(in groupId: String, enable: Bool) {
        let toolNames = childrenOf(groupId: groupId)
        guard !toolNames.isEmpty else { return }
        var next = enabledToolNames
        if enable {
            next.formUnion(toolNames)
        } else {
            next.subtract(toolNames)
        }
        commit(nextTools: next)
    }

    private func handleToggleTool(_ rowId: String, _ wasEnabled: Bool) {
        guard let decoded = CapabilityRowBuilder.decode(rowId: rowId), decoded.kind == "tool" else { return }
        var next = enabledToolNames
        if wasEnabled {
            next.remove(decoded.payload)
        } else {
            next.insert(decoded.payload)
        }
        commit(nextTools: next)
    }

    /// Collect every (non-restricted) child of a group directly from the live
    /// registry snapshots. Intentionally does NOT walk `rows` — collapsed
    /// groups omit their children from the rendered list, so a row-based
    /// implementation would silently no-op the master checkbox until the
    /// section was expanded (#1003).
    ///
    /// `pluginNameById` is intentionally empty: the classifier's display
    /// names matter for the rendered group header, but `groupId` only
    /// derives from the structural identity (`pluginId` / provider / etc.),
    /// so we don't need to materialize the lookup just to compare.
    private func childrenOf(groupId: String) -> Set<String> {
        var tools: Set<String> = []

        for tool in visibleTools {
            let source = CapabilityRowBuilder.source(forTool: tool, pluginNameById: [:])
            // Built-in / runtime-managed tools are surfaced for transparency
            // only; their toggles are disabled at the row level
            // (`isAgentRestricted`) so bulk operations must skip them too.
            guard !source.isInformational, source.groupId == groupId else { continue }
            tools.insert(tool.name)
        }

        return tools
    }

    private func commit(nextTools: Set<String>) {
        guard nextTools != enabledToolNames else { return }
        enabledToolNames = nextTools
        switch source {
        case .live(let agentId):
            agentManager.updateEnabledToolNames(Array(nextTools), for: agentId)
        case .draft(_, let tools):
            tools.wrappedValue = nextTools
        }
    }

    private func commit(mode: ToolSelectionMode) {
        guard mode != toolMode else { return }
        toolMode = mode
        switch source {
        case .live(let agentId):
            agentManager.updateToolSelectionMode(mode, for: agentId)
        case .draft(let modeBinding, _):
            modeBinding.wrappedValue = mode
        }
    }
}
