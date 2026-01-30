//
//  CapabilitiesSelectorView.swift
//  osaurus
//
//  Capabilities selector with tools grouped by plugin/provider and sticky headers.
//

import SwiftUI

// MARK: - Types

enum CapabilityTab: String, CaseIterable {
    case tools = "Tools"
    case skills = "Skills"
}

private struct ToolGroup: Identifiable {
    enum Source: Hashable {
        case plugin(id: String, name: String)
        case mcpProvider(id: UUID, name: String)
        case builtIn
    }

    let source: Source
    var tools: [ToolRegistry.ToolEntry]

    var id: String {
        switch source {
        case .plugin(let id, _): return "plugin-\(id)"
        case .mcpProvider(let id, _): return "mcp-\(id.uuidString)"
        case .builtIn: return "builtin"
        }
    }

    var displayName: String {
        switch source {
        case .plugin(_, let name), .mcpProvider(_, let name): return name
        case .builtIn: return "Built-in"
        }
    }

    var icon: String {
        switch source {
        case .plugin: return "puzzlepiece.extension"
        case .mcpProvider: return "cloud"
        case .builtIn: return "gearshape"
        }
    }

    var enabledCount: Int { tools.filter { $0.enabled }.count }
}

// MARK: - Capabilities Selector View

struct CapabilitiesSelectorView: View {
    let personaId: UUID

    @ObservedObject private var toolRegistry = ToolRegistry.shared
    @ObservedObject private var skillManager = SkillManager.shared
    @ObservedObject private var personaManager = PersonaManager.shared

    @State private var selectedTab: CapabilityTab = .tools
    @State private var searchText = ""
    @State private var expandedGroups: Set<String> = []
    @State private var cachedTools: [ToolRegistry.ToolEntry] = []
    @State private var cachedGroups: [ToolGroup] = []

    @Environment(\.theme) private var theme

    // MARK: - Data

    private func rebuildToolsCache() {
        let overrides = personaManager.effectiveToolOverrides(for: personaId)
        let tools = toolRegistry.listUserTools(withOverrides: overrides, excludeInternal: true)
        cachedTools = tools

        var groups: [ToolGroup] = []
        var assignedNames: Set<String> = []

        // Group by installed plugins
        for plugin in PluginRepositoryService.shared.plugins where plugin.isInstalled {
            let specToolNames = Set((plugin.spec.capabilities?.tools ?? []).map { $0.name })
            let matched = tools.filter { specToolNames.contains($0.name) }
            if !matched.isEmpty {
                let name = plugin.spec.name ?? plugin.spec.plugin_id
                groups.append(ToolGroup(source: .plugin(id: plugin.spec.plugin_id, name: name), tools: matched))
                assignedNames.formUnion(matched.map { $0.name })
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

        // Remaining tools go to Built-in
        let remaining = tools.filter { !assignedNames.contains($0.name) }
        if !remaining.isEmpty {
            groups.append(ToolGroup(source: .builtIn, tools: remaining))
        }

        cachedGroups = groups

        if expandedGroups.isEmpty, let first = groups.first {
            expandedGroups.insert(first.id)
        }
    }

    private var filteredGroups: [ToolGroup] {
        guard !searchText.isEmpty else { return cachedGroups }

        return cachedGroups.compactMap { group in
            let groupMatches = SearchService.matches(query: searchText, in: group.displayName)
            let matchedTools = group.tools.filter {
                SearchService.matches(query: searchText, in: $0.name)
                    || SearchService.matches(query: searchText, in: $0.description)
            }

            if groupMatches {
                return group
            } else if !matchedTools.isEmpty {
                var filtered = group
                filtered.tools = matchedTools
                return filtered
            }
            return nil
        }
    }

    private func isGroupExpanded(_ groupId: String) -> Bool {
        !searchText.isEmpty || expandedGroups.contains(groupId)
    }

    private var enabledToolCount: Int {
        cachedTools.filter { $0.enabled }.count
    }

    // MARK: - Skill Data

    private var skills: [Skill] { skillManager.skills }

    private func isSkillEnabled(_ name: String) -> Bool {
        if let overrides = personaManager.effectiveSkillOverrides(for: personaId),
            let value = overrides[name]
        {
            return value
        }
        return skillManager.skill(named: name)?.enabled ?? false
    }

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

    // MARK: - Stats

    private var totalEnabledCount: Int { enabledToolCount + enabledSkillCount }
    private var totalCount: Int { cachedTools.count + skills.count }

    private var totalTokenEstimate: Int {
        let toolTokens = cachedTools.filter { $0.enabled }.reduce(0) { $0 + $1.catalogEntryTokens }
        let skillTokens = skills.filter { isSkillEnabled($0.name) }.reduce(0) { sum, skill in
            sum + max(5, (skill.name.count + skill.description.count + 6) / 4)
        }
        return toolTokens + skillTokens
    }

    private var currentTabFilteredCount: Int {
        selectedTab == .tools ? filteredGroups.reduce(0) { $0 + $1.tools.count } : filteredSkills.count
    }

    // MARK: - Actions

    private func toggleTool(_ name: String, enabled: Bool) {
        personaManager.setToolEnabled(!enabled, tool: name, for: personaId)
    }

    private func toggleSkill(_ name: String) {
        personaManager.setSkillEnabled(!isSkillEnabled(name), skill: name, for: personaId)
    }

    private func enableAll() {
        if selectedTab == .tools {
            personaManager.enableAllTools(for: personaId, tools: cachedTools.map { $0.name })
        } else {
            personaManager.enableAllSkills(for: personaId, skills: skills.map { $0.name })
        }
    }

    private func disableAll() {
        if selectedTab == .tools {
            personaManager.disableAllTools(for: personaId, tools: cachedTools.map { $0.name })
        } else {
            personaManager.disableAllSkills(for: personaId, skills: skills.map { $0.name })
        }
    }

    private func toggleGroup(_ group: ToolGroup) {
        if expandedGroups.contains(group.id) {
            expandedGroups.remove(group.id)
        } else {
            expandedGroups.insert(group.id)
        }
    }

    private func enableAllInGroup(_ group: ToolGroup) {
        personaManager.enableAllTools(for: personaId, tools: group.tools.map { $0.name })
    }

    private func disableAllInGroup(_ group: ToolGroup) {
        personaManager.disableAllTools(for: personaId, tools: group.tools.map { $0.name })
    }

    private func openManagement() {
        AppDelegate.shared?.showManagementWindow(initialTab: selectedTab == .tools ? .tools : .skills)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
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
        .frame(width: 420, height: min(CGFloat(totalCount * 48 + 200), 540))
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.primaryBackground)
                .shadow(color: .black.opacity(0.2), radius: 16, x: 0, y: 8)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.primaryBorder.opacity(0.3), lineWidth: 0.5)
        )
        .animation(.easeInOut(duration: 0.2), value: selectedTab)
        .onAppear { rebuildToolsCache() }
        .onReceive(toolRegistry.objectWillChange) { _ in
            // Debounce slightly to let the change complete
            DispatchQueue.main.async { rebuildToolsCache() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toolsListChanged)) { _ in rebuildToolsCache() }
        .onReceive(NotificationCenter.default.publisher(for: .skillsListChanged)) { _ in rebuildToolsCache() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Abilities")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Spacer()

                if totalEnabledCount > 0 {
                    HStack(spacing: 2) {
                        Text("~\(totalTokenEstimate)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                        Text("tokens")
                            .font(.system(size: 9))
                            .opacity(0.7)
                    }
                    .foregroundColor(theme.tertiaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(theme.secondaryBackground.opacity(0.5)))
                }

                Text("\(totalEnabledCount)/\(totalCount)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.secondaryBackground))
            }

            // Tab selector
            HStack(spacing: 0) {
                ForEach(CapabilityTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: tab == .tools ? "wrench.and.screwdriver" : "lightbulb")
                                .font(.system(size: 11))
                            Text(tab.rawValue)
                                .font(.system(size: 12, weight: .medium))
                            Text(
                                "(\(tab == .tools ? enabledToolCount : enabledSkillCount)/\(tab == .tools ? cachedTools.count : skills.count))"
                            )
                            .font(.system(size: 10))
                            .foregroundColor(selectedTab == tab ? theme.primaryText.opacity(0.7) : theme.tertiaryText)
                        }
                        .foregroundColor(selectedTab == tab ? theme.primaryText : theme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selectedTab == tab ? theme.secondaryBackground : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.primaryBorder.opacity(0.15)))

            // Actions
            HStack(spacing: 8) {
                Button(action: enableAll) {
                    Text("Enable All")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.secondaryBackground)
                        )
                }
                .buttonStyle(.plain)

                Button(action: disableAll) {
                    Text("Disable All")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.secondaryBackground)
                        )
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: openManagement) {
                    HStack(spacing: 4) {
                        Image(systemName: "gearshape").font(.system(size: 10))
                        Text("Manage").font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(
                            theme.secondaryBackground.opacity(0.5)
                        )
                    )
                }
                .buttonStyle(.plain)
                .help("Open \(selectedTab == .tools ? "Tools" : "Skills") management")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundColor(theme.tertiaryText)

            TextField(
                selectedTab == .tools ? "Search tools or plugins..." : "Search skills...",
                text: $searchText
            )
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
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.secondaryBackground.opacity(0.5))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundColor(theme.tertiaryText)
            Text("No \(selectedTab == .tools ? "tools" : "skills") found")
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Item List

    private var itemList: some View {
        ScrollView {
            LazyVStack(spacing: 2, pinnedViews: [.sectionHeaders]) {
                if selectedTab == .tools {
                    ForEach(filteredGroups) { group in
                        Section {
                            if isGroupExpanded(group.id) {
                                ForEach(group.tools) { tool in
                                    ToolRowItem(tool: tool) { toggleTool(tool.name, enabled: tool.enabled) }
                                        .padding(.leading, 20)
                                }
                            }
                        } header: {
                            GroupHeader(
                                group: group,
                                isExpanded: isGroupExpanded(group.id),
                                onToggle: { toggleGroup(group) },
                                onEnableAll: { enableAllInGroup(group) },
                                onDisableAll: { disableAllInGroup(group) }
                            )
                        }
                    }
                } else {
                    ForEach(filteredSkills) { skill in
                        SkillRowItem(skill: skill, isEnabled: isSkillEnabled(skill.name)) {
                            toggleSkill(skill.name)
                        }
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - Group Header

private struct GroupHeader: View {
    let group: ToolGroup
    let isExpanded: Bool
    let onToggle: () -> Void
    let onEnableAll: () -> Void
    let onDisableAll: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    private var allEnabled: Bool { group.enabledCount == group.tools.count }
    private var noneEnabled: Bool { group.enabledCount == 0 }

    var body: some View {
        HStack(spacing: 8) {
            // Expand/collapse area
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                    .frame(width: 12)

                Image(systemName: group.icon)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)

                Text(group.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { onToggle() }

            Spacer()

            // All/None buttons (on hover)
            if isHovered {
                HStack(spacing: 4) {
                    Button { onEnableAll() } label: {
                        Text("All")
                            .font(.system(size: 9, weight: allEnabled ? .bold : .medium))
                            .foregroundColor(allEnabled ? theme.accentColor : theme.tertiaryText)
                    }
                    Text("/").font(.system(size: 9)).foregroundColor(theme.tertiaryText)
                    Button { onDisableAll() } label: {
                        Text("None")
                            .font(.system(size: 9, weight: noneEnabled ? .bold : .medium))
                            .foregroundColor(noneEnabled ? theme.accentColor : theme.tertiaryText)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(theme.primaryBackground))
            }

            // Count badge
            Text("\(group.enabledCount)/\(group.tools.count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(group.enabledCount > 0 ? theme.accentColor : theme.tertiaryText)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(group.enabledCount > 0 ? theme.accentColor.opacity(0.15) : theme.primaryBackground))
                .onTapGesture { onToggle() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.secondaryBackground))
        .onHover { isHovered = $0 }
    }
}

// MARK: - Row Items

private struct ToolRowItem: View {
    let tool: ToolRegistry.ToolEntry
    let onToggle: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { tool.enabled }, set: { _ in onToggle() }))
                .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                .scaleEffect(0.7)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(tool.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(tool.enabled ? theme.primaryText : theme.secondaryText)
                    .lineLimit(1)
                Text(tool.description)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(2)
            }

            Spacer()

            tokenBadge(tool.catalogEntryTokens)
                .help("Catalog: ~\(tool.catalogEntryTokens), Full: ~\(tool.estimatedTokens) tokens")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isHovered ? theme.secondaryBackground.opacity(0.6) : Color.clear))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private func tokenBadge(_ count: Int) -> some View {
        HStack(spacing: 2) {
            Text("~\(count)").font(.system(size: 10, weight: .medium, design: .monospaced))
            Text("tokens").font(.system(size: 9)).opacity(0.6)
        }
        .foregroundColor(theme.tertiaryText)
    }
}

private struct SkillRowItem: View {
    let skill: Skill
    let isEnabled: Bool
    let onToggle: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    private var estimatedTokens: Int {
        max(5, (skill.name.count + skill.description.count + 6) / 4)
    }

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { isEnabled }, set: { _ in onToggle() }))
                .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                .scaleEffect(0.7)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(isEnabled ? theme.primaryText : theme.secondaryText)
                        .lineLimit(1)

                    if skill.isBuiltIn {
                        Text("Built-in")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(theme.secondaryBackground))
                    }
                }
                Text(skill.description)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(2)
            }

            Spacer()

            HStack(spacing: 2) {
                Text("~\(estimatedTokens)").font(.system(size: 10, weight: .medium, design: .monospaced))
                Text("tokens").font(.system(size: 9)).opacity(0.6)
            }
            .foregroundColor(theme.tertiaryText)
            .help("Catalog entry tokens")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isHovered ? theme.secondaryBackground.opacity(0.6) : Color.clear))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

// MARK: - Preview

#if DEBUG
    struct CapabilitiesSelectorView_Previews: PreviewProvider {
        struct PreviewWrapper: View {
            var body: some View {
                CapabilitiesSelectorView(personaId: Persona.defaultId)
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
