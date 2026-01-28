//
//  CapabilitiesSelectorView.swift
//  osaurus
//
//  Unified capabilities selector showing both tools and skills in a tabbed interface.
//  Toggles update persona overrides (or global config for Default persona).
//

import SwiftUI

// MARK: - Capability Tab

enum CapabilityTab: String, CaseIterable {
    case tools = "Tools"
    case skills = "Skills"
}

// MARK: - Capabilities Selector View

struct CapabilitiesSelectorView: View {
    /// The persona ID to update when toggling capabilities
    let personaId: UUID

    /// Observe registries for live updates
    @ObservedObject private var toolRegistry = ToolRegistry.shared
    @ObservedObject private var skillManager = SkillManager.shared
    @ObservedObject private var personaManager = PersonaManager.shared

    @State private var selectedTab: CapabilityTab = .tools
    @State private var searchText: String = ""
    @Environment(\.theme) private var theme

    // MARK: - Tool Data

    private var tools: [ToolRegistry.ToolEntry] {
        // Use centralized listUserTools which excludes agent tools
        // Also exclude internal tools like select_capabilities
        toolRegistry.listUserTools(withOverrides: toolOverrides, excludeInternal: true)
    }

    private var toolOverrides: [String: Bool]? {
        personaManager.effectiveToolOverrides(for: personaId)
    }

    private var filteredTools: [ToolRegistry.ToolEntry] {
        if searchText.isEmpty {
            return tools
        }
        return tools.filter {
            SearchService.matches(query: searchText, in: $0.name)
                || SearchService.matches(query: searchText, in: $0.description)
        }
    }

    private var enabledToolCount: Int {
        tools.filter { $0.enabled }.count
    }

    // MARK: - Skill Data

    private var skills: [Skill] { skillManager.skills }

    private var skillOverrides: [String: Bool]? {
        personaManager.effectiveSkillOverrides(for: personaId)
    }

    private func isSkillEnabled(_ name: String) -> Bool {
        if let overrides = skillOverrides, let value = overrides[name] {
            return value
        }
        return skillManager.skill(named: name)?.enabled ?? false
    }

    private var filteredSkills: [Skill] {
        if searchText.isEmpty {
            return skills
        }
        return skills.filter {
            SearchService.matches(query: searchText, in: $0.name)
                || SearchService.matches(query: searchText, in: $0.description)
        }
    }

    private var enabledSkillCount: Int {
        skills.filter { isSkillEnabled($0.name) }.count
    }

    // MARK: - Combined Stats

    private var totalEnabledCount: Int {
        enabledToolCount + enabledSkillCount
    }

    private var totalCount: Int {
        tools.count + skills.count
    }

    /// Estimate total tokens for all enabled capabilities
    private var totalTokenEstimate: Int {
        let toolTokens = tools.filter { $0.enabled }.reduce(0) { $0 + $1.catalogEntryTokens }
        let skillTokens = skills.filter { isSkillEnabled($0.name) }.reduce(0) { sum, skill in
            let chars = skill.name.count + skill.description.count + 6
            return sum + max(5, chars / 4)
        }
        return toolTokens + skillTokens
    }

    // MARK: - Current Tab Stats

    private var currentTabEnabledCount: Int {
        selectedTab == .tools ? enabledToolCount : enabledSkillCount
    }

    private var currentTabTotalCount: Int {
        selectedTab == .tools ? tools.count : skills.count
    }

    private var currentTabFilteredCount: Int {
        selectedTab == .tools ? filteredTools.count : filteredSkills.count
    }

    // MARK: - Actions

    private func toggleTool(_ name: String, currentlyEnabled: Bool) {
        personaManager.setToolEnabled(!currentlyEnabled, tool: name, for: personaId)
    }

    private func toggleSkill(_ name: String) {
        let currentlyEnabled = isSkillEnabled(name)
        personaManager.setSkillEnabled(!currentlyEnabled, skill: name, for: personaId)
    }

    private func enableAll() {
        if selectedTab == .tools {
            personaManager.enableAllTools(for: personaId, tools: tools.map { $0.name })
        } else {
            personaManager.enableAllSkills(for: personaId, skills: skills.map { $0.name })
        }
    }

    private func disableAll() {
        if selectedTab == .tools {
            personaManager.disableAllTools(for: personaId, tools: tools.map { $0.name })
        } else {
            personaManager.disableAllSkills(for: personaId, skills: skills.map { $0.name })
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .background(theme.primaryBorder.opacity(0.3))

            searchField

            Divider()
                .background(theme.primaryBorder.opacity(0.3))

            if currentTabFilteredCount == 0 {
                emptyState
            } else {
                itemList
            }
        }
        .frame(width: 400, height: min(CGFloat(currentTabTotalCount * 56 + 180), 520))
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
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            // Title row with stats
            HStack {
                Text("Abilities")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Spacer()

                // Total token estimate
                if totalEnabledCount > 0 {
                    HStack(spacing: 2) {
                        Text("~\(totalTokenEstimate)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.tertiaryText)
                        Text("tokens")
                            .font(.system(size: 9))
                            .foregroundColor(theme.tertiaryText.opacity(0.7))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(theme.secondaryBackground.opacity(0.5))
                    )
                }

                // Total count badge
                Text("\(totalEnabledCount)/\(totalCount)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(theme.secondaryBackground)
                    )
            }

            // Custom segmented control
            HStack(spacing: 0) {
                ForEach(CapabilityTab.allCases, id: \.self) { tab in
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedTab = tab
                        }
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: tab == .tools ? "wrench.and.screwdriver" : "lightbulb")
                                .font(.system(size: 11))
                            Text(tab.rawValue)
                                .font(.system(size: 12, weight: .medium))
                            Text(
                                "(\(tab == .tools ? enabledToolCount : enabledSkillCount)/\(tab == .tools ? tools.count : skills.count))"
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
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.primaryBorder.opacity(0.15))
            )

            // Action buttons row
            HStack(spacing: 8) {
                Button(action: enableAll) {
                    Text("Enable All")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(theme.secondaryBackground)
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
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(theme.secondaryBackground)
                        )
                }
                .buttonStyle(.plain)

                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundColor(theme.tertiaryText)

            TextField(
                selectedTab == .tools ? "Search tools..." : "Search skills...",
                text: $searchText
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundColor(theme.primaryText)

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
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
            LazyVStack(spacing: 2) {
                if selectedTab == .tools {
                    ForEach(filteredTools) { tool in
                        CapabilityToolRowItem(
                            tool: tool,
                            onToggle: { toggleTool(tool.name, currentlyEnabled: tool.enabled) }
                        )
                    }
                } else {
                    ForEach(filteredSkills) { skill in
                        CapabilitySkillRowItem(
                            skill: skill,
                            isEnabled: isSkillEnabled(skill.name),
                            onToggle: { toggleSkill(skill.name) }
                        )
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - Tool Row Item

private struct CapabilityToolRowItem: View {
    let tool: ToolRegistry.ToolEntry
    let onToggle: () -> Void

    @State private var isHovered: Bool = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            // Toggle with theme accent color
            Toggle(
                "",
                isOn: Binding(
                    get: { tool.enabled },
                    set: { _ in onToggle() }
                )
            )
            .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
            .scaleEffect(0.7)
            .frame(width: 36)

            // Tool info
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

            // Token estimate
            HStack(spacing: 2) {
                Text("~\(tool.catalogEntryTokens)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)

                Text("tokens")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundColor(theme.tertiaryText.opacity(0.6))
            }
            .help(
                "Catalog entry: ~\(tool.catalogEntryTokens) tokens. Full schema if selected: ~\(tool.estimatedTokens) tokens"
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? theme.secondaryBackground.opacity(0.6) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Skill Row Item

private struct CapabilitySkillRowItem: View {
    let skill: Skill
    let isEnabled: Bool
    let onToggle: () -> Void

    @State private var isHovered: Bool = false
    @Environment(\.theme) private var theme

    /// Estimate tokens for catalog entry
    private var estimatedTokens: Int {
        let chars = skill.name.count + skill.description.count + 6
        return max(5, chars / 4)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Toggle with theme accent color
            Toggle(
                "",
                isOn: Binding(
                    get: { isEnabled },
                    set: { _ in onToggle() }
                )
            )
            .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
            .scaleEffect(0.7)
            .frame(width: 36)

            // Skill info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(isEnabled ? theme.primaryText : theme.secondaryText)
                        .lineLimit(1)

                    // Built-in badge
                    if skill.isBuiltIn {
                        Text("Built-in")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                Capsule()
                                    .fill(theme.secondaryBackground)
                            )
                    }
                }

                Text(skill.description)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(2)
            }

            Spacer()

            // Token estimate
            HStack(spacing: 2) {
                Text("~\(estimatedTokens)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)

                Text("tokens")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundColor(theme.tertiaryText.opacity(0.6))
            }
            .help("Catalog entry tokens (name + description)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? theme.secondaryBackground.opacity(0.6) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
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
