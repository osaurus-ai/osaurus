//
//  AgentCapabilityManagerView.swift
//  osaurus
//
//  Full-tab takeover UI for managing an agent's enabled tools and skills,
//  grouped by source (Built-in / per-Plugin / per-MCP-provider / Standalone Skills).
//
//  The picker is the single source of truth for what reaches the model. A top-level
//  "Auto-discover" toggle decides whether the model sees the entire enabled set every
//  turn (Manual) or a per-turn relevant subset chosen by pre-flight search (Auto).
//  Either way, the per-item Enabled toggles in the table are honored at runtime —
//  see `PreflightCapabilitySearch.search` and `SystemPromptComposer.compose` for the
//  wiring.
//

import SwiftUI

// MARK: - Source Grouping

/// Logical bucket for the picker. Each maps to one or more `CapabilityRow.groupHeader`s.
private enum CapabilitySource: Hashable {
    /// Built-in tools — always loaded by the runtime, shown for transparency.
    case builtIn
    /// One per native dylib plugin (its tools and skills together).
    case plugin(pluginId: String, displayName: String)
    /// One per remote MCP provider.
    case mcpProvider(name: String)
    /// One per provisioned sandbox plugin.
    case sandboxPlugin(pluginId: String)
    /// Skills not associated with any plugin (built-in skills and user-created ones).
    case standaloneSkills

    var groupId: String {
        switch self {
        case .builtIn: return "src:builtin"
        case .plugin(let pluginId, _): return "src:plugin:\(pluginId)"
        case .mcpProvider(let name): return "src:mcp:\(name)"
        case .sandboxPlugin(let pluginId): return "src:sandbox:\(pluginId)"
        case .standaloneSkills: return "src:standalone-skills"
        }
    }

    var displayName: String {
        switch self {
        case .builtIn: return "Built-in"
        case .plugin(_, let name): return name
        case .mcpProvider(let name): return name
        case .sandboxPlugin(let pluginId): return pluginId
        case .standaloneSkills: return "Standalone Skills"
        }
    }

    var icon: String {
        switch self {
        case .builtIn: return "shippingbox.circle"
        case .plugin: return "puzzlepiece.extension"
        case .mcpProvider: return "antenna.radiowaves.left.and.right"
        case .sandboxPlugin: return "shippingbox"
        case .standaloneSkills: return "lightbulb"
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

private enum CapabilityFilter: String, CaseIterable, Identifiable {
    case all
    case enabled
    case toolsOnly
    case skillsOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .enabled: return "Enabled"
        case .toolsOnly: return "Tools"
        case .skillsOnly: return "Skills"
        }
    }
}

// MARK: - Row Builder

/// Pure transform from snapshots of the live registries + agent state into the
/// `[CapabilityRow]` array consumed by `CapabilitiesTableRepresentable`. Kept
/// pure so it can be diffed cheaply on every state change.
@MainActor
private enum CapabilityRowBuilder {

    struct Input {
        let visibleTools: [ToolRegistry.ToolEntry]
        let visibleSkills: [Skill]
        let plugins: [PluginManager.LoadedPlugin]
        let enabledToolNames: Set<String>
        let enabledSkillNames: Set<String>
        let searchQuery: String
        let filter: CapabilityFilter
        let expandedGroups: Set<String>
    }

    static func build(_ input: Input) -> [CapabilityRow] {
        let normalized = input.searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let hasSearch = !normalized.isEmpty

        // Bucket tools into their source.
        struct Bucket {
            var tools: [ToolRegistry.ToolEntry] = []
            var skills: [Skill] = []
        }
        var buckets: [String: Bucket] = [:]
        var sources: [String: CapabilitySource] = [:]
        var sourceOrder: [String] = []

        func ensureSource(_ source: CapabilitySource) {
            let id = source.groupId
            if buckets[id] == nil {
                buckets[id] = Bucket()
                sources[id] = source
                sourceOrder.append(id)
            }
        }

        let pluginNameById = Dictionary(
            uniqueKeysWithValues: input.plugins.map {
                ($0.plugin.id, $0.plugin.manifest.name ?? $0.plugin.id)
            }
        )

        let registry = ToolRegistry.shared
        let builtInNames = registry.builtInToolNames
        let runtimeNames = registry.runtimeManagedToolNames

        for tool in input.visibleTools {
            // Built-in / runtime-managed tools are informational.
            if builtInNames.contains(tool.name) || runtimeNames.contains(tool.name) {
                ensureSource(.builtIn)
                buckets[CapabilitySource.builtIn.groupId]?.tools.append(tool)
                continue
            }
            if registry.isMCPTool(tool.name), let provider = registry.groupName(for: tool.name) {
                let src: CapabilitySource = .mcpProvider(name: provider)
                ensureSource(src)
                buckets[src.groupId]?.tools.append(tool)
                continue
            }
            if registry.isSandboxTool(tool.name), let pid = registry.groupName(for: tool.name) {
                let src: CapabilitySource = .sandboxPlugin(pluginId: pid)
                ensureSource(src)
                buckets[src.groupId]?.tools.append(tool)
                continue
            }
            if registry.isPluginTool(tool.name), let pid = registry.groupName(for: tool.name) {
                let src: CapabilitySource = .plugin(
                    pluginId: pid,
                    displayName: pluginNameById[pid] ?? pid
                )
                ensureSource(src)
                buckets[src.groupId]?.tools.append(tool)
                continue
            }
            // Fallback: treat unclassified tools as built-in / always-loaded.
            ensureSource(.builtIn)
            buckets[CapabilitySource.builtIn.groupId]?.tools.append(tool)
        }

        for skill in input.visibleSkills {
            if let pid = skill.pluginId {
                let src: CapabilitySource = .plugin(
                    pluginId: pid,
                    displayName: pluginNameById[pid] ?? pid
                )
                ensureSource(src)
                buckets[src.groupId]?.skills.append(skill)
            } else {
                ensureSource(.standaloneSkills)
                buckets[CapabilitySource.standaloneSkills.groupId]?.skills.append(skill)
            }
        }

        // Stable order: Built-in first, then plugins (alpha by display name), then
        // MCP providers (alpha), then sandbox plugins (alpha), then standalone skills.
        sourceOrder.sort { lhs, rhs in
            guard let l = sources[lhs], let r = sources[rhs] else { return lhs < rhs }
            return sortRank(l) < sortRank(r)
                || (sortRank(l) == sortRank(r)
                    && l.displayName.localizedCaseInsensitiveCompare(r.displayName) == .orderedAscending)
        }

        // Emit rows.
        var rows: [CapabilityRow] = []
        for groupId in sourceOrder {
            guard let source = sources[groupId], let bucket = buckets[groupId] else { continue }

            let tools = bucket.tools
            let skills = bucket.skills

            // Filter chip: whole groups can drop out.
            switch input.filter {
            case .toolsOnly where tools.isEmpty: continue
            case .skillsOnly where skills.isEmpty: continue
            default: break
            }

            // Search: keep only items that match. If empty, drop the group.
            let filteredTools = tools.filter { entry in
                guard !hasSearch else {
                    return matches(query: normalized, name: entry.name, description: entry.description)
                }
                return true
            }
            let filteredSkills = skills.filter { skill in
                guard !hasSearch else {
                    return matches(query: normalized, name: skill.name, description: skill.description)
                }
                return true
            }

            // Filter chip: enabled-only refines per-item.
            let toolsForRows: [ToolRegistry.ToolEntry] = {
                if input.filter == .enabled {
                    return filteredTools.filter { input.enabledToolNames.contains($0.name) }
                }
                if input.filter == .skillsOnly { return [] }
                return filteredTools
            }()
            let skillsForRows: [Skill] = {
                if input.filter == .enabled {
                    return filteredSkills.filter { input.enabledSkillNames.contains($0.name) }
                }
                if input.filter == .toolsOnly { return [] }
                return filteredSkills
            }()

            if hasSearch && toolsForRows.isEmpty && skillsForRows.isEmpty {
                continue
            }
            if input.filter == .enabled && toolsForRows.isEmpty && skillsForRows.isEmpty {
                continue
            }

            let totalToolEnabled = toolsForRows.reduce(0) { acc, t in
                acc + (input.enabledToolNames.contains(t.name) ? 1 : 0)
            }
            let totalSkillEnabled = skillsForRows.reduce(0) { acc, s in
                acc + (input.enabledSkillNames.contains(s.name) ? 1 : 0)
            }

            // Built-in group is informational — count every item as "enabled" for display.
            let enabledCount =
                source.isInformational
                ? toolsForRows.count + skillsForRows.count
                : totalToolEnabled + totalSkillEnabled
            let totalCount = toolsForRows.count + skillsForRows.count

            // Auto-expand groups when actively searching so matches are visible at a glance.
            let isExpanded = hasSearch || input.expandedGroups.contains(groupId)

            rows.append(
                .groupHeader(
                    id: groupId,
                    name: source.displayName,
                    icon: source.icon,
                    enabledCount: enabledCount,
                    totalCount: totalCount,
                    isExpanded: isExpanded,
                    toolCount: toolsForRows.count,
                    skillCount: skillsForRows.count,
                    hasRoutes: false
                )
            )

            guard isExpanded else { continue }

            for tool in toolsForRows {
                rows.append(
                    .tool(
                        id: "\(groupId)::tool::\(tool.name)",
                        name: tool.name,
                        description: tool.description,
                        enabled: source.isInformational ? true : input.enabledToolNames.contains(tool.name),
                        isAgentRestricted: source.isInformational,
                        catalogTokens: tool.estimatedTokens,
                        estimatedTokens: tool.estimatedTokens
                    )
                )
            }
            for skill in skillsForRows {
                rows.append(
                    .skill(
                        id: "\(groupId)::skill::\(skill.id.uuidString)",
                        name: skill.name,
                        description: skill.description,
                        enabled: input.enabledSkillNames.contains(skill.name),
                        isBuiltIn: skill.isBuiltIn,
                        isFromPlugin: skill.isFromPlugin,
                        estimatedTokens: 0
                    )
                )
            }
        }
        return rows
    }

    private static func sortRank(_ source: CapabilitySource) -> Int {
        switch source {
        case .builtIn: return 0
        case .plugin: return 1
        case .mcpProvider: return 2
        case .sandboxPlugin: return 3
        case .standaloneSkills: return 4
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
}

// MARK: - Manager View

/// Picker for an agent's enabled tools and skills, grouped by source. Hosts
/// either as the Capabilities tab body (live mode → writes through
/// `AgentManager`) or embedded in the Create Agent sheet (draft mode → writes
/// through `@Binding`s the caller bakes into the new agent on save).
struct AgentCapabilityManagerView: View {

    /// Where the picker reads and writes capability state.
    ///
    /// - `live`: Capabilities-tab path. Writes go through `AgentManager` and
    ///   persist immediately; `.agentUpdated` notifications keep the local
    ///   mirror in sync.
    /// - `draft`: Create-sheet path. Writes flow into the caller's bindings
    ///   and are baked into the new agent only when the user clicks "Create
    ///   Agent" — the agent doesn't exist yet, so no `AgentManager` calls.
    enum Source {
        case live(agentId: UUID)
        case draft(
            mode: Binding<ToolSelectionMode>,
            tools: Binding<Set<String>>,
            skills: Binding<Set<String>>
        )
    }

    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared

    let source: Source
    /// When non-nil, a "Done" affordance appears in the sticky header so the
    /// host (sheet / takeover) can be dismissed. When nil, the picker IS the
    /// host (e.g. the Capabilities tab body) and there's nothing to go back to.
    let onDismiss: (() -> Void)?

    /// Embedded mode used when the picker sits inside a host sheet that
    /// already supplies its own title chrome. Drops the picker's title row
    /// and bottom rule so the two headers don't stack, and relocates the
    /// Done affordance into the search row.
    let compact: Bool

    /// Live-mode init used by the Capabilities tab.
    init(agentId: UUID, onDismiss: (() -> Void)?, compact: Bool = false) {
        self.source = .live(agentId: agentId)
        self.onDismiss = onDismiss
        self.compact = compact
    }

    /// Draft-mode init used by the Create Agent sheet.
    init(
        draftMode: Binding<ToolSelectionMode>,
        draftTools: Binding<Set<String>>,
        draftSkills: Binding<Set<String>>,
        onDismiss: (() -> Void)?,
        compact: Bool = false
    ) {
        self.source = .draft(mode: draftMode, tools: draftTools, skills: draftSkills)
        self.onDismiss = onDismiss
        self.compact = compact
    }

    // MARK: Local UI state

    @State private var searchText: String = ""
    @State private var searchFocused: Bool = false
    @State private var filter: CapabilityFilter = .all
    @State private var expandedGroups: Set<String> = []

    /// Local mirror of capability state. In live mode it's seeded from
    /// `AgentManager` and re-synced on `.agentUpdated`; in draft mode it's
    /// seeded from the bindings and written back through them.
    @State private var enabledToolNames: Set<String> = []
    @State private var enabledSkillNames: Set<String> = []
    @State private var toolMode: ToolSelectionMode = .auto

    /// Snapshot of the registries this turn (rebuilt on `.toolsListChanged`).
    @State private var visibleTools: [ToolRegistry.ToolEntry] = []
    @State private var visibleSkills: [Skill] = []
    @State private var plugins: [PluginManager.LoadedPlugin] = []

    var body: some View {
        VStack(spacing: 0) {
            stickyHeader
                .background(theme.secondaryBackground)
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
            CapabilitiesTableRepresentable(
                rows: rows,
                theme: theme,
                onToggleGroup: handleToggleGroup,
                onEnableAllInGroup: { handleBulkToggle(in: $0, enable: true) },
                onDisableAllInGroup: { handleBulkToggle(in: $0, enable: false) },
                onToggleTool: handleToggleTool,
                onToggleSkill: handleToggleSkill
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            // Title row only renders in standalone (tab-host) mode. In compact
            // mode the host sheet's header already supplies the title context.
            if !compact {
                HStack(spacing: 10) {
                    if onDismiss != nil { doneButton }

                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                    Text("Capabilities", bundle: .module)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.primaryText)

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
            }

            autoDiscoverCard
            filterChips
        }
        .padding(.horizontal, 20)
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

    private var summaryPill: some View {
        let toolCount = enabledToolNames.count
        let skillCount = enabledSkillNames.count
        return HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 9))
            Text("\(toolCount) tool\(toolCount == 1 ? "" : "s") · \(skillCount) skill\(skillCount == 1 ? "" : "s")")
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
                .help(Text("Clear search", bundle: .module))
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
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(toolMode == .auto ? theme.accentColor : theme.secondaryText)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(
                        toolMode == .auto ? theme.accentColor.opacity(0.12) : theme.inputBackground
                    )
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("Auto-discover relevant capabilities", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(
                    toolMode == .auto
                        ? "We'll pick the most relevant ones from your enabled set each turn."
                        : "All enabled capabilities are sent to the model every turn.",
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
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.inputBackground.opacity(0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
        )
    }

    private var filterChips: some View {
        HStack(spacing: 6) {
            ForEach(CapabilityFilter.allCases) { option in
                let isSelected = option == filter
                Button {
                    filter = option
                } label: {
                    Text(LocalizedStringKey(option.label), bundle: .module)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(isSelected ? theme.accentColor.opacity(0.14) : theme.inputBackground)
                                .overlay(
                                    Capsule().strokeBorder(
                                        isSelected ? theme.accentColor.opacity(0.25) : theme.inputBorder,
                                        lineWidth: 1
                                    )
                                )
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: - Rows

    private var rows: [CapabilityRow] {
        CapabilityRowBuilder.build(
            CapabilityRowBuilder.Input(
                visibleTools: visibleTools,
                visibleSkills: visibleSkills,
                plugins: plugins,
                enabledToolNames: enabledToolNames,
                enabledSkillNames: enabledSkillNames,
                searchQuery: searchText,
                filter: filter,
                expandedGroups: expandedGroups
            )
        )
    }

    // MARK: - Loading

    private func loadFromRegistries() {
        // Built-in / runtime-managed tools are intentionally surfaced in the picker
        // for transparency (the `.builtIn` group renders them as informational rows
        // with a disabled toggle). We don't filter them out here.
        visibleTools = ToolRegistry.shared.listTools().filter { $0.enabled }
        visibleSkills = SkillManager.shared.skills.filter { $0.enabled || !$0.isBuiltIn }
        plugins = PluginManager.shared.plugins
    }

    /// Live mode only: ensure the agent's `manualToolNames` / `manualSkillNames`
    /// fields are populated so the picker reads a real list instead of "nil".
    /// Draft mode skips this — its bindings are seeded by the parent before
    /// the manager is shown.
    private func seedIfNeeded() {
        guard case .live(let agentId) = source else { return }
        let liveToolNames = ToolRegistry.shared.listDynamicTools().map(\.name)
        let liveSkillNames = SkillManager.shared.skills.map(\.name)
        agentManager.seedEnabledCapabilitiesIfNeeded(
            for: agentId,
            defaultToolNames: liveToolNames,
            defaultSkillNames: liveSkillNames
        )
    }

    /// Populate the local mirror from whichever source is authoritative.
    private func loadInitialState() {
        switch source {
        case .live:
            loadFromAgent()
        case .draft(let mode, let tools, let skills):
            toolMode = mode.wrappedValue
            enabledToolNames = tools.wrappedValue
            enabledSkillNames = skills.wrappedValue
        }
    }

    private func loadFromAgent() {
        guard case .live(let agentId) = source else { return }
        toolMode = agentManager.effectiveToolSelectionMode(for: agentId)
        enabledToolNames = Set(agentManager.effectiveEnabledToolNames(for: agentId) ?? [])
        enabledSkillNames = Set(agentManager.effectiveEnabledSkillNames(for: agentId) ?? [])
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
        let (toolNames, skillNames) = childrenOf(groupId: groupId)
        guard !toolNames.isEmpty || !skillNames.isEmpty else { return }
        var nextTools = enabledToolNames
        var nextSkills = enabledSkillNames
        if enable {
            nextTools.formUnion(toolNames)
            nextSkills.formUnion(skillNames)
        } else {
            nextTools.subtract(toolNames)
            nextSkills.subtract(skillNames)
        }
        commit(nextTools: nextTools, nextSkills: nextSkills)
    }

    private func handleToggleTool(_ rowId: String, _ wasEnabled: Bool) {
        guard let decoded = CapabilityRowBuilder.decode(rowId: rowId), decoded.kind == "tool" else { return }
        var next = enabledToolNames
        if wasEnabled {
            next.remove(decoded.payload)
        } else {
            next.insert(decoded.payload)
        }
        commit(nextTools: next, nextSkills: enabledSkillNames)
    }

    private func handleToggleSkill(_ rowId: String) {
        guard let decoded = CapabilityRowBuilder.decode(rowId: rowId), decoded.kind == "skill" else { return }
        // Skill rows encode their UUID, not their name (the name can change
        // when a plugin is renamed). Resolve via the live snapshot.
        guard let uuid = UUID(uuidString: decoded.payload),
            let skill = visibleSkills.first(where: { $0.id == uuid })
        else { return }
        var next = enabledSkillNames
        if next.contains(skill.name) {
            next.remove(skill.name)
        } else {
            next.insert(skill.name)
        }
        commit(nextTools: enabledToolNames, nextSkills: next)
    }

    private func childrenOf(groupId: String) -> (tools: Set<String>, skills: Set<String>) {
        var tools: Set<String> = []
        var skills: Set<String> = []
        for row in rows {
            switch row {
            case .tool(let id, let name, _, _, let restricted, _, _) where !restricted:
                if id.hasPrefix("\(groupId)::tool::") { tools.insert(name) }
            case .skill(let id, let name, _, _, _, _, _):
                if id.hasPrefix("\(groupId)::skill::") { skills.insert(name) }
            default: break
            }
        }
        return (tools, skills)
    }

    private func commit(nextTools: Set<String>, nextSkills: Set<String>) {
        if nextTools != enabledToolNames {
            enabledToolNames = nextTools
            switch source {
            case .live(let agentId):
                agentManager.updateEnabledToolNames(Array(nextTools), for: agentId)
            case .draft(_, let tools, _):
                tools.wrappedValue = nextTools
            }
        }
        if nextSkills != enabledSkillNames {
            enabledSkillNames = nextSkills
            switch source {
            case .live(let agentId):
                agentManager.updateEnabledSkillNames(Array(nextSkills), for: agentId)
            case .draft(_, _, let skills):
                skills.wrappedValue = nextSkills
            }
        }
    }

    private func commit(mode: ToolSelectionMode) {
        guard mode != toolMode else { return }
        toolMode = mode
        switch source {
        case .live(let agentId):
            agentManager.updateToolSelectionMode(mode, for: agentId)
        case .draft(let modeBinding, _, _):
            modeBinding.wrappedValue = mode
        }
    }
}
