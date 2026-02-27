//
//  CapabilitiesSelectorView.swift
//  osaurus
//
//  Capabilities selector with tools grouped by plugin/provider.
//

import SwiftUI

// MARK: - Types

enum CapabilityTab: String, CaseIterable {
    case plugins = "Plugins"
    case tools = "Tools"
    case skills = "Skills"
}

private struct ToolGroup: Identifiable {
    enum Source: Hashable {
        case plugin(id: String, name: String)
        case mcpProvider(id: UUID, name: String)
        case memory
        case builtIn
    }

    let source: Source
    var tools: [ToolRegistry.ToolEntry]

    var id: String {
        switch source {
        case .plugin(let id, _): return "plugin-\(id)"
        case .mcpProvider(let id, _): return "mcp-\(id.uuidString)"
        case .memory: return "memory"
        case .builtIn: return "builtin"
        }
    }

    var displayName: String {
        switch source {
        case .plugin(_, let name), .mcpProvider(_, let name): return name
        case .memory: return "Memory"
        case .builtIn: return "Built-in"
        }
    }

    var icon: String {
        switch source {
        case .plugin: return "puzzlepiece.extension"
        case .mcpProvider: return "cloud"
        case .memory: return "brain"
        case .builtIn: return "gearshape"
        }
    }

    var enabledCount: Int { tools.filter { $0.enabled }.count }
}

/// A compound plugin that provides both tools and skills.
private struct CompoundPluginGroup: Identifiable {
    let pluginId: String
    let name: String
    let toolNames: [String]
    let skillNames: [String]

    var id: String { "compound-\(pluginId)" }
}

// MARK: - Capabilities Selector View

struct CapabilitiesSelectorView: View {
    let agentId: UUID
    var isWorkMode: Bool = false
    var isInline: Bool = false

    @ObservedObject private var toolRegistry = ToolRegistry.shared
    @ObservedObject private var skillManager = SkillManager.shared
    @ObservedObject private var agentManager = AgentManager.shared

    @State private var selectedTab: CapabilityTab = .tools
    @State private var searchText = ""
    @State private var expandedGroups: Set<String> = []
    @State private var cachedTools: [ToolRegistry.ToolEntry] = []
    @State private var cachedGroups: [ToolGroup] = []
    @State private var cachedCompoundPlugins: [CompoundPluginGroup] = []

    @Environment(\.theme) private var theme

    /// Plugin tool names that conflict with built-in work tools (empty when not in work mode).
    private var agentRestrictedTools: Set<String> {
        isWorkMode ? toolRegistry.workConflictingToolNames : []
    }

    // MARK: - Data

    private func rebuildToolsCache() {
        let overrides = agentManager.effectiveToolOverrides(for: agentId)
        let tools = toolRegistry.listUserTools(withOverrides: overrides, excludeInternal: true)
        cachedTools = tools

        var groups: [ToolGroup] = []
        var compoundPlugins: [CompoundPluginGroup] = []
        var assignedNames: Set<String> = []

        // Single pass over installed plugins: build tool groups and detect compound plugins
        for plugin in PluginRepositoryService.shared.plugins where plugin.isInstalled {
            let pluginId = plugin.pluginId
            let displayName = plugin.displayName
            let specToolNames = (plugin.capabilities?.tools ?? []).map { $0.name }
            let matched = tools.filter { specToolNames.contains($0.name) }

            if !matched.isEmpty {
                groups.append(ToolGroup(source: .plugin(id: pluginId, name: displayName), tools: matched))
                assignedNames.formUnion(matched.map { $0.name })
            }

            // Compound plugin: has both tools and skills
            let pluginSkills = skillManager.pluginSkills(for: pluginId)
            if !specToolNames.isEmpty && !pluginSkills.isEmpty {
                compoundPlugins.append(
                    CompoundPluginGroup(
                        pluginId: pluginId,
                        name: displayName,
                        toolNames: specToolNames,
                        skillNames: pluginSkills.map { $0.name }
                    )
                )
            }
        }

        // Group by connected MCP providers
        let providerManager = MCPProviderManager.shared
        for provider in providerManager.configuration.providers {
            guard providerManager.providerStates[provider.id]?.isConnected == true else { continue }

            let prefix =
                provider.name.lowercased()
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "-", with: "_")
                .filter { $0.isLetter || $0.isNumber || $0 == "_" } + "_"

            let matched = tools.filter { $0.name.hasPrefix(prefix) && !assignedNames.contains($0.name) }
            if !matched.isEmpty {
                groups.append(ToolGroup(source: .mcpProvider(id: provider.id, name: provider.name), tools: matched))
                assignedNames.formUnion(matched.map { $0.name })
            }
        }

        // Memory recall tools get their own group
        let memoryToolNames: Set<String> = [
            "search_working_memory", "search_conversations",
            "search_summaries", "search_graph",
        ]
        let memoryTools = tools.filter { memoryToolNames.contains($0.name) && !assignedNames.contains($0.name) }
        if !memoryTools.isEmpty {
            groups.insert(ToolGroup(source: .memory, tools: memoryTools), at: 0)
            assignedNames.formUnion(memoryTools.map { $0.name })
        }

        // Remaining tools go to Built-in
        let remaining = tools.filter { !assignedNames.contains($0.name) }
        if !remaining.isEmpty {
            groups.append(ToolGroup(source: .builtIn, tools: remaining))
        }

        cachedGroups = groups
        cachedCompoundPlugins = compoundPlugins
    }

    // MARK: - Plugins

    private var filteredCompoundPlugins: [CompoundPluginGroup] {
        guard !searchText.isEmpty else { return cachedCompoundPlugins }
        return cachedCompoundPlugins.filter { SearchService.matches(query: searchText, in: $0.name) }
    }

    private var enabledCompoundPluginCount: Int {
        cachedCompoundPlugins.filter { isCompoundPluginActive($0) }.count
    }

    private func isCompoundPluginActive(_ group: CompoundPluginGroup) -> Bool {
        group.toolNames.allSatisfy { name in
            cachedTools.first(where: { $0.name == name })?.enabled ?? false
        }
            && group.skillNames.allSatisfy { isSkillEnabled($0) }
    }

    private func toggleCompoundPlugin(_ group: CompoundPluginGroup) {
        let isActive = isCompoundPluginActive(group)
        if isActive {
            agentManager.disableAllTools(for: agentId, tools: group.toolNames)
            agentManager.disableAllSkills(for: agentId, skills: group.skillNames)
        } else {
            let restricted = agentRestrictedTools
            agentManager.enableAllTools(for: agentId, tools: group.toolNames.filter { !restricted.contains($0) })
            agentManager.enableAllSkills(for: agentId, skills: group.skillNames)
        }
    }

    // MARK: - Tools

    private var filteredGroups: [ToolGroup] {
        guard !searchText.isEmpty else { return cachedGroups }
        return cachedGroups.compactMap { group in
            let groupMatches = SearchService.matches(query: searchText, in: group.displayName)
            let matchedTools = group.tools.filter {
                SearchService.matches(query: searchText, in: $0.name)
                    || SearchService.matches(query: searchText, in: $0.description)
            }
            if groupMatches { return group }
            if !matchedTools.isEmpty {
                var filtered = group
                filtered.tools = matchedTools
                return filtered
            }
            return nil
        }
    }

    private var enabledToolCount: Int {
        cachedTools.filter { $0.enabled }.count
    }

    private func isGroupExpanded(_ groupId: String) -> Bool {
        !searchText.isEmpty || expandedGroups.contains(groupId)
    }

    // MARK: - Skills

    private var skills: [Skill] { skillManager.skills }

    private var filteredSkills: [Skill] {
        guard !searchText.isEmpty else { return skills }
        return skills.filter {
            SearchService.matches(query: searchText, in: $0.name)
                || SearchService.matches(query: searchText, in: $0.description)
        }
    }

    private var enabledSkillCount: Int {
        skills.filter { isSkillEnabled($0.name) }.count
    }

    private func isSkillEnabled(_ name: String) -> Bool {
        if let overrides = agentManager.effectiveSkillOverrides(for: agentId),
            let value = overrides[name]
        {
            return value
        }
        return skillManager.skill(named: name)?.enabled ?? false
    }

    // MARK: - Counts & Tokens

    private var totalEnabledCount: Int { enabledToolCount + enabledSkillCount }
    private var totalCount: Int { cachedTools.count + skills.count }

    private var phasedLoading: Bool {
        ChatConfigurationStore.load().phasedContextLoading
    }

    private func skillTokenEstimate(_ skill: Skill) -> Int {
        if phasedLoading {
            return max(5, (skill.name.count + skill.description.count + 6) / 4)
        }
        return max(5, (skill.name.count + skill.description.count + skill.instructions.count + 50) / 4)
    }

    private var totalTokenEstimate: Int {
        let toolTokens = cachedTools.filter { $0.enabled }.reduce(0) {
            $0 + (phasedLoading ? $1.catalogEntryTokens : $1.estimatedTokens)
        }
        let skillTokens = skills.filter { isSkillEnabled($0.name) }.reduce(0) {
            $0 + skillTokenEstimate($1)
        }
        return toolTokens + skillTokens
    }

    private var currentTabFilteredCount: Int {
        switch selectedTab {
        case .plugins: return filteredCompoundPlugins.count
        case .tools: return filteredGroups.reduce(0) { $0 + $1.tools.count }
        case .skills: return filteredSkills.count
        }
    }

    /// Only show Plugins tab when compound plugins exist.
    private var visibleTabs: [CapabilityTab] {
        cachedCompoundPlugins.isEmpty ? [.tools, .skills] : CapabilityTab.allCases
    }

    // MARK: - Actions

    private func toggleTool(_ name: String, enabled: Bool) {
        agentManager.setToolEnabled(!enabled, tool: name, for: agentId)
    }

    private func toggleSkill(_ name: String) {
        agentManager.setSkillEnabled(!isSkillEnabled(name), skill: name, for: agentId)
    }

    private func enableAll() {
        let restricted = agentRestrictedTools
        switch selectedTab {
        case .plugins:
            for group in cachedCompoundPlugins {
                agentManager.enableAllTools(
                    for: agentId,
                    tools: group.toolNames.filter { !restricted.contains($0) }
                )
                agentManager.enableAllSkills(for: agentId, skills: group.skillNames)
            }
        case .tools:
            agentManager.enableAllTools(
                for: agentId,
                tools: cachedTools.map { $0.name }.filter { !restricted.contains($0) }
            )
        case .skills:
            agentManager.enableAllSkills(for: agentId, skills: skills.map { $0.name })
        }
    }

    private func disableAll() {
        switch selectedTab {
        case .plugins:
            for group in cachedCompoundPlugins {
                agentManager.disableAllTools(for: agentId, tools: group.toolNames)
                agentManager.disableAllSkills(for: agentId, skills: group.skillNames)
            }
        case .tools:
            agentManager.disableAllTools(for: agentId, tools: cachedTools.map { $0.name })
        case .skills:
            agentManager.disableAllSkills(for: agentId, skills: skills.map { $0.name })
        }
    }

    private func toggleGroup(_ group: ToolGroup) {
        expandedGroups.formSymmetricDifference([group.id])
    }

    private func enableAllInGroup(_ group: ToolGroup) {
        let restricted = agentRestrictedTools
        agentManager.enableAllTools(
            for: agentId,
            tools: group.tools.map { $0.name }.filter { !restricted.contains($0) }
        )
    }

    private func disableAllInGroup(_ group: ToolGroup) {
        agentManager.disableAllTools(for: agentId, tools: group.tools.map { $0.name })
    }

    private func openManagement() {
        switch selectedTab {
        case .plugins, .tools:
            AppDelegate.shared?.showManagementWindow(initialTab: .tools)
        case .skills:
            AppDelegate.shared?.showManagementWindow(initialTab: .skills)
        }
    }

    private func resetToDefaults() {
        guard var agent = agentManager.agent(for: agentId) else { return }
        switch selectedTab {
        case .plugins:
            // Reset both tools and skills for compound plugins
            agent.enabledTools = nil
            agent.enabledSkills = nil
        case .tools:
            agent.enabledTools = nil
        case .skills:
            agent.enabledSkills = nil
        }
        agentManager.update(agent)
        NotificationCenter.default.post(name: .toolsListChanged, object: nil)
        NotificationCenter.default.post(name: .skillsListChanged, object: nil)
    }

    private var hasOverrides: Bool {
        let agent = agentManager.agent(for: agentId)
        switch selectedTab {
        case .plugins:
            return (agent?.enabledTools?.isEmpty == false) || (agent?.enabledSkills?.isEmpty == false)
        case .tools:
            return agent?.enabledTools?.isEmpty == false
        case .skills:
            return agent?.enabledSkills?.isEmpty == false
        }
    }

    // MARK: - Tab Helpers

    private func tabIcon(for tab: CapabilityTab) -> String {
        switch tab {
        case .plugins: return "puzzlepiece.extension"
        case .tools: return "wrench.and.screwdriver"
        case .skills: return "lightbulb"
        }
    }

    private func tabCountLabel(for tab: CapabilityTab) -> String {
        switch tab {
        case .plugins: return "\(enabledCompoundPluginCount)/\(cachedCompoundPlugins.count)"
        case .tools: return "\(enabledToolCount)/\(cachedTools.count)"
        case .skills: return "\(enabledSkillCount)/\(skills.count)"
        }
    }

    // MARK: - Body

    var body: some View {
        let content = VStack(spacing: 0) {
            header
            Divider().background(theme.primaryBorder.opacity(0.3))
            searchField
            Divider().background(theme.primaryBorder.opacity(0.3))

            if currentTabFilteredCount == 0 {
                emptyState
            } else {
                itemList
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selectedTab)
        .onAppear {
            rebuildToolsCache()
            // Default to plugins tab when compound plugins exist
            if !cachedCompoundPlugins.isEmpty {
                selectedTab = .plugins
            }
        }
        .onReceive(toolRegistry.objectWillChange) { _ in
            DispatchQueue.main.async { rebuildToolsCache() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toolsListChanged)) { _ in rebuildToolsCache() }
        .onReceive(NotificationCenter.default.publisher(for: .skillsListChanged)) { _ in rebuildToolsCache() }
        .onChange(of: cachedCompoundPlugins.count) { _, newCount in
            // If plugins tab is selected but no compound plugins remain, switch to tools
            if newCount == 0 && selectedTab == .plugins {
                selectedTab = .tools
            }
        }

        if isInline {
            content
                .frame(maxWidth: .infinity)
                .frame(height: min(CGFloat(totalCount * 48 + 200), 600))
        } else {
            content
                .frame(width: 420, height: min(CGFloat(totalCount * 48 + 200), 540))
                .background(popoverBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(popoverBorder)
                .shadow(color: theme.shadowColor.opacity(0.25), radius: 20, x: 0, y: 10)
        }
    }

    // MARK: - Background & Border

    private var popoverBackground: some View {
        ZStack {
            if theme.glassEnabled {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
            }

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.primaryBackground.opacity(theme.isDark ? 0.85 : 0.92))

            LinearGradient(
                colors: [
                    theme.accentColor.opacity(theme.isDark ? 0.06 : 0.04),
                    Color.clear,
                ],
                startPoint: .top,
                endPoint: .center
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var popoverBorder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        theme.glassEdgeLight.opacity(0.2),
                        theme.primaryBorder.opacity(0.15),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            if !isInline {
                HStack {
                    Text("Abilities")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Spacer()

                    if totalEnabledCount > 0 {
                        TokenBadge(count: totalTokenEstimate)
                    }

                    Text("\(totalEnabledCount)/\(totalCount)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(theme.secondaryBackground))
                }
            }

            // Tab selector
            HStack(spacing: 0) {
                ForEach(visibleTabs, id: \.self) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: tabIcon(for: tab))
                                .font(.system(size: 11))
                            Text(tab.rawValue)
                                .font(.system(size: 12, weight: .medium))
                            Text("(\(tabCountLabel(for: tab)))")
                                .font(.system(size: 10))
                                .foregroundColor(
                                    selectedTab == tab ? theme.primaryText.opacity(0.7) : theme.tertiaryText
                                )
                        }
                        .foregroundColor(selectedTab == tab ? theme.primaryText : theme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .background(
                            Group {
                                if selectedTab == tab {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(theme.secondaryBackground)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .strokeBorder(theme.primaryBorder.opacity(0.12), lineWidth: 1)
                                        )
                                }
                            }
                        )
                        .shadow(
                            color: selectedTab == tab ? theme.shadowColor.opacity(0.08) : .clear,
                            radius: 2,
                            x: 0,
                            y: 1
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.secondaryBackground.opacity(theme.isDark ? 0.4 : 0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(theme.primaryBorder.opacity(0.1), lineWidth: 1)
                    )
            )

            // Actions
            HStack(spacing: 8) {
                CapabilityActionButton(title: "Enable All", action: enableAll)
                CapabilityActionButton(title: "Disable All", action: disableAll)

                if isInline && hasOverrides {
                    CapabilityActionButton(
                        title: "Reset to Defaults",
                        icon: "arrow.uturn.backward",
                        action: resetToDefaults
                    )
                }

                Spacer()

                CapabilityActionButton(title: "Manage", icon: "gearshape", isSecondary: true, action: openManagement)
                    .help("Open \(selectedTab == .skills ? "Skills" : "Tools") management")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, isInline ? 8 : 12)
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundColor(theme.tertiaryText)

            TextField("Search \(selectedTab.rawValue.lowercased())...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(theme.primaryText)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.secondaryBackground.opacity(theme.isDark ? 0.4 : 0.5))
        .animation(.easeOut(duration: 0.15), value: searchText.isEmpty)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundColor(theme.tertiaryText)
            Text("No \(selectedTab.rawValue.lowercased()) found")
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Flattened Rows

    private var flattenedRows: [CapabilityRow] {
        var rows: [CapabilityRow] = []
        switch selectedTab {
        case .plugins:
            for group in filteredCompoundPlugins {
                rows.append(
                    .compoundPlugin(
                        id: group.pluginId,
                        name: group.name,
                        toolCount: group.toolNames.count,
                        skillCount: group.skillNames.count,
                        isActive: isCompoundPluginActive(group)
                    )
                )
            }

        case .tools:
            let restricted = agentRestrictedTools
            for group in filteredGroups {
                let expanded = isGroupExpanded(group.id)
                rows.append(
                    .groupHeader(
                        id: group.id,
                        name: group.displayName,
                        icon: group.icon,
                        enabledCount: group.enabledCount,
                        totalCount: group.tools.count,
                        isExpanded: expanded
                    )
                )
                if expanded {
                    let phased = phasedLoading
                    for tool in group.tools {
                        rows.append(
                            .tool(
                                id: tool.name,
                                name: tool.name,
                                description: tool.description,
                                enabled: tool.enabled,
                                isAgentRestricted: restricted.contains(tool.name),
                                catalogTokens: phased ? tool.catalogEntryTokens : tool.estimatedTokens,
                                estimatedTokens: tool.estimatedTokens
                            )
                        )
                    }
                }
            }

        case .skills:
            for skill in filteredSkills {
                let enabled = isSkillEnabled(skill.name)
                rows.append(
                    .skill(
                        id: skill.name,
                        name: skill.name,
                        description: skill.description,
                        enabled: enabled,
                        isBuiltIn: skill.isBuiltIn,
                        isFromPlugin: skill.isFromPlugin,
                        estimatedTokens: skillTokenEstimate(skill)
                    )
                )
            }
        }
        return rows
    }

    // MARK: - Item List

    private var itemList: some View {
        CapabilitiesTableRepresentable(
            rows: flattenedRows,
            theme: theme,
            onToggleGroup: { groupId in
                if let group = cachedGroups.first(where: { $0.id == groupId }) {
                    toggleGroup(group)
                }
            },
            onEnableAllInGroup: { groupId in
                if let group = cachedGroups.first(where: { $0.id == groupId }) {
                    enableAllInGroup(group)
                }
            },
            onDisableAllInGroup: { groupId in
                if let group = cachedGroups.first(where: { $0.id == groupId }) {
                    disableAllInGroup(group)
                }
            },
            onToggleTool: { name, enabled in
                toggleTool(name, enabled: enabled)
            },
            onToggleSkill: { name in
                toggleSkill(name)
            },
            onToggleCompoundPlugin: { pluginId in
                if let group = cachedCompoundPlugins.first(where: { $0.pluginId == pluginId }) {
                    toggleCompoundPlugin(group)
                }
            }
        )
    }
}

// MARK: - Token Badge (used in header)

/// Token count badge (e.g. "~42 tokens").
private struct TokenBadge: View {
    let count: Int

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            Text("~\(count)").font(.system(size: 10, weight: .medium, design: .monospaced))
            Text("tokens").font(.system(size: 9)).opacity(0.6)
        }
        .foregroundColor(theme.tertiaryText)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(theme.secondaryBackground.opacity(0.5)))
    }
}

// MARK: - Action Button

private struct CapabilityActionButton: View {
    let title: String
    var icon: String? = nil
    var isSecondary: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 10))
                }
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(foregroundColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.secondaryBackground.opacity(isSecondary ? 0.5 : (isHovered ? 0.95 : 0.8)))
                    .overlay(
                        isHovered
                            ? RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [theme.accentColor.opacity(0.08), Color.clear],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            : nil
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                theme.glassEdgeLight.opacity(isHovered ? 0.2 : 0.1),
                                theme.primaryBorder.opacity(isHovered ? 0.15 : 0.08),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onPopoverHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
    }

    private var foregroundColor: Color {
        if isSecondary {
            return isHovered ? theme.accentColor : theme.secondaryText
        }
        return isHovered ? theme.accentColor : theme.primaryText
    }
}

// MARK: - Preview

#if DEBUG
    struct CapabilitiesSelectorView_Previews: PreviewProvider {
        struct PreviewWrapper: View {
            var body: some View {
                CapabilitiesSelectorView(agentId: Agent.defaultId, isWorkMode: false)
                    .padding()
                    .frame(width: 500, height: 600)
                    .background(Color.gray.opacity(0.2))
            }
        }

        static var previews: some View {
            PreviewWrapper()
        }
    }
#endif
