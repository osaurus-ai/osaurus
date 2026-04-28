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

/// Full-tab takeover that replaces the cramped inline tool/skill picker.
/// Owns its own search / filter / expansion state but persists every selection
/// change to `AgentManager` immediately so the parent view's debounced save is
/// not on the critical path.
struct AgentCapabilityManagerView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared
    @State private var skillManager = SkillManager.shared

    let agentId: UUID
    let onDismiss: () -> Void

    // MARK: Local UI state
    @State private var searchText: String = ""
    @State private var filter: CapabilityFilter = .all
    @State private var expandedGroups: Set<String> = []

    // Mirror of the agent's enabled sets — kept here so updates feel instant.
    // Persistence happens via AgentManager helpers.
    @State private var enabledToolNames: Set<String> = []
    @State private var enabledSkillNames: Set<String> = []
    @State private var toolMode: ToolSelectionMode = .auto

    // Snapshot of the registries this turn (rebuilt on notifications).
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
                        .frame(height: 1),
                    alignment: .bottom
                )

            // NOTE: do NOT slap `.id()` on the table — it forces SwiftUI to recreate
            // the underlying NSScrollView on every state change and resets scroll
            // position to the top, which is jarring when toggling rows. The table's
            // coordinator already diffs its rows in place via NSDiffableDataSource
            // and reconfigures visible cells when only content (not structure)
            // changed, so identity is intentionally stable across updates here.
            CapabilitiesTableRepresentable(
                rows: rows,
                theme: theme,
                onToggleGroup: handleToggleGroup,
                onEnableAllInGroup: { handleEnableAll(in: $0) },
                onDisableAllInGroup: { handleDisableAll(in: $0) },
                onToggleTool: handleToggleTool,
                onToggleSkill: handleToggleSkill
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.primaryBackground)
        }
        .onAppear {
            loadFromRegistries()
            seedIfNeeded()
            loadFromAgent()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .toolsListChanged)
        ) { _ in
            loadFromRegistries()
            // After auto-grow, the agent's enabled set may have changed — reload.
            loadFromAgent()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .agentUpdated)
        ) { _ in
            loadFromAgent()
        }
    }

    // MARK: - Sticky header

    private var stickyHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button(action: onDismiss) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Done", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)

                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                Text("Capabilities", bundle: .module)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Spacer()

                summaryPill
            }

            searchField

            autoDiscoverCard

            filterChips
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
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
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            TextField(
                text: $searchText,
                prompt: Text("Search by name or description...", bundle: .module)
            ) {
                Text("Search by name or description...", bundle: .module)
            }
            .font(.system(size: 12))
            .textFieldStyle(.plain)
            .foregroundColor(theme.primaryText)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.inputBorder, lineWidth: 1))
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
                    set: { newValue in
                        let next: ToolSelectionMode = newValue ? .auto : .manual
                        guard next != toolMode else { return }
                        toolMode = next
                        agentManager.updateToolSelectionMode(next, for: agentId)
                    }
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

    private func seedIfNeeded() {
        let liveToolNames = ToolRegistry.shared.listDynamicTools().map(\.name)
        let liveSkillNames = SkillManager.shared.skills.map(\.name)
        agentManager.seedEnabledCapabilitiesIfNeeded(
            for: agentId,
            defaultToolNames: liveToolNames,
            defaultSkillNames: liveSkillNames
        )
    }

    private func loadFromAgent() {
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

    private func handleEnableAll(in groupId: String) {
        let (toolNames, skillNames) = childrenOf(groupId: groupId)
        guard !toolNames.isEmpty || !skillNames.isEmpty else { return }
        var nextTools = enabledToolNames
        nextTools.formUnion(toolNames)
        var nextSkills = enabledSkillNames
        nextSkills.formUnion(skillNames)
        commit(nextTools: nextTools, nextSkills: nextSkills)
    }

    private func handleDisableAll(in groupId: String) {
        let (toolNames, skillNames) = childrenOf(groupId: groupId)
        guard !toolNames.isEmpty || !skillNames.isEmpty else { return }
        var nextTools = enabledToolNames
        nextTools.subtract(toolNames)
        var nextSkills = enabledSkillNames
        nextSkills.subtract(skillNames)
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
        // Find the skill name from the current snapshot using its UUID payload.
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
            agentManager.updateEnabledToolNames(Array(nextTools), for: agentId)
        }
        if nextSkills != enabledSkillNames {
            enabledSkillNames = nextSkills
            agentManager.updateEnabledSkillNames(Array(nextSkills), for: agentId)
        }
    }
}

// MARK: - Summary Card (used in the configure tab)

/// Compact preview shown in the agent's Configure tab. Tapping "Manage" replaces
/// the configure body with `AgentCapabilityManagerView` (in-place takeover). This
/// avoids the nested-scroll issue from the previous inline picker design.
struct CapabilitySummaryCard: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared

    let agentId: UUID
    let onManage: () -> Void

    @State private var enabledToolCount: Int = 0
    @State private var enabledSkillCount: Int = 0
    @State private var sourceCount: Int = 0
    @State private var toolMode: ToolSelectionMode = .auto

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(theme.accentColor.opacity(0.12))
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 4) {
                    Text(summaryHeadline)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(summarySubline)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(2)
                }

                Spacer()

                modePill
            }

            Button(action: onManage) {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Manage Capabilities", bundle: .module)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                }
                .foregroundColor(theme.accentColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.accentColor.opacity(0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(theme.accentColor.opacity(0.25), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
        )
        .onAppear { refresh() }
        .onReceive(
            NotificationCenter.default.publisher(for: .toolsListChanged)
        ) { _ in refresh() }
        .onReceive(
            NotificationCenter.default.publisher(for: .agentUpdated)
        ) { _ in refresh() }
    }

    private var modePill: some View {
        HStack(spacing: 5) {
            Image(systemName: toolMode == .auto ? "sparkles" : "list.bullet")
                .font(.system(size: 9, weight: .semibold))
            Text(toolMode == .auto ? "Auto-discover" : "Custom")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(toolMode == .auto ? theme.accentColor : theme.secondaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(toolMode == .auto ? theme.accentColor.opacity(0.12) : theme.inputBackground)
                .overlay(
                    Capsule()
                        .strokeBorder(
                            toolMode == .auto ? theme.accentColor.opacity(0.25) : theme.inputBorder,
                            lineWidth: 1
                        )
                )
        )
    }

    private var summaryHeadline: String {
        let total = enabledToolCount + enabledSkillCount
        if total == 0 { return "No tools or skills enabled" }
        let toolPart = "\(enabledToolCount) tool\(enabledToolCount == 1 ? "" : "s")"
        let skillPart = "\(enabledSkillCount) skill\(enabledSkillCount == 1 ? "" : "s")"
        return "\(toolPart) · \(skillPart) enabled"
    }

    private var summarySubline: String {
        if sourceCount == 0 {
            return toolMode == .auto
                ? "Auto-discover will load relevant capabilities each turn."
                : "Enable items below to give the agent capabilities."
        }
        let sourceLabel = "across \(sourceCount) source\(sourceCount == 1 ? "" : "s")"
        return toolMode == .auto
            ? "Auto-discover picks per turn from your enabled set, \(sourceLabel)."
            : "All enabled items are sent every turn, \(sourceLabel)."
    }

    private func refresh() {
        toolMode = agentManager.effectiveToolSelectionMode(for: agentId)
        let enabledTools = Set(agentManager.effectiveEnabledToolNames(for: agentId) ?? [])
        let enabledSkills = Set(agentManager.effectiveEnabledSkillNames(for: agentId) ?? [])
        enabledToolCount = enabledTools.count
        enabledSkillCount = enabledSkills.count
        sourceCount = computeSourceCount(toolNames: enabledTools, skillNames: enabledSkills)
    }

    private func computeSourceCount(toolNames: Set<String>, skillNames: Set<String>) -> Int {
        let registry = ToolRegistry.shared
        var sources: Set<String> = []
        let builtInNames = registry.builtInToolNames
        let runtimeNames = registry.runtimeManagedToolNames
        for name in toolNames {
            if builtInNames.contains(name) || runtimeNames.contains(name) {
                sources.insert("builtin")
            } else if let group = registry.groupName(for: name) {
                sources.insert(group)
            } else {
                sources.insert("misc")
            }
        }
        let pluginIdsForSkills = SkillManager.shared.skills
            .filter { skillNames.contains($0.name) }
            .compactMap { $0.pluginId }
        for pid in pluginIdsForSkills {
            sources.insert(pid)
        }
        if !skillNames.isEmpty,
            SkillManager.shared.skills.contains(where: { skillNames.contains($0.name) && $0.pluginId == nil })
        {
            sources.insert("standalone-skills")
        }
        return sources.count
    }
}
