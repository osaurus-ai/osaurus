//
//  SkillSelectorView.swift
//  osaurus
//
//  Skill selector showing available skills and their current state.
//  Toggles update persona overrides (or global config for Default persona).
//

import SwiftUI

struct SkillSelectorView: View {
    /// The persona ID to update when toggling skills
    let personaId: UUID

    /// Observe SkillManager for live updates when skills change
    @ObservedObject private var skillManager = SkillManager.shared
    /// Observe PersonaManager for live updates when persona overrides change
    @ObservedObject private var personaManager = PersonaManager.shared

    @State private var searchText: String = ""
    @Environment(\.theme) private var theme

    private var skills: [Skill] { skillManager.skills }

    private var personaOverrides: [String: Bool]? {
        personaManager.effectiveSkillOverrides(for: personaId)
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

    /// Check if a skill is enabled (persona override > global config)
    private func isSkillEnabled(_ name: String) -> Bool {
        if let overrides = personaOverrides, let value = overrides[name] {
            return value
        }
        return skillManager.skill(named: name)?.enabled ?? false
    }

    /// Count of enabled skills
    private var enabledCount: Int {
        skills.filter { isSkillEnabled($0.name) }.count
    }

    /// Estimate total tokens for enabled skills (catalog entry only for two-phase loading)
    private var enabledTokenEstimate: Int {
        skills.filter { isSkillEnabled($0.name) }.reduce(0) { sum, skill in
            // Catalog format: "- **name**: description\n" ≈ 6 chars overhead
            let chars = skill.name.count + skill.description.count + 6
            return sum + max(5, chars / 4)
        }
    }

    /// Toggle a skill's enabled state for this persona
    private func toggleSkill(_ name: String) {
        let currentlyEnabled = isSkillEnabled(name)
        personaManager.setSkillEnabled(!currentlyEnabled, skill: name, for: personaId)
    }

    /// Enable all skills for this persona
    private func enableAll() {
        personaManager.enableAllSkills(for: personaId, skills: skills.map { $0.name })
    }

    /// Disable all skills for this persona
    private func disableAll() {
        personaManager.disableAllSkills(for: personaId, skills: skills.map { $0.name })
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with count
            header

            Divider()
                .background(theme.primaryBorder.opacity(0.3))

            // Search field
            searchField

            Divider()
                .background(theme.primaryBorder.opacity(0.3))

            // Skill list
            if filteredSkills.isEmpty {
                emptyState
            } else {
                skillList
            }
        }
        .frame(width: 360, height: min(CGFloat(skills.count * 56 + 160), 480))
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
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            // Title row
            HStack {
                Text("Available Skills")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Spacer()

                // Token estimate for enabled skills
                if enabledCount > 0 {
                    HStack(spacing: 2) {
                        Text("~\(enabledTokenEstimate)")
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

                Text("\(enabledCount)/\(skills.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(theme.secondaryBackground)
                    )
            }

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

            TextField("Search skills...", text: $searchText)
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
            Text("No skills found")
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Skill List

    private var skillList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(filteredSkills) { skill in
                    SkillRowItem(
                        skill: skill,
                        isEnabled: isSkillEnabled(skill.name),
                        onToggle: { toggleSkill(skill.name) }
                    )
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - Skill Row Item

private struct SkillRowItem: View {
    let skill: Skill
    let isEnabled: Bool
    let onToggle: () -> Void

    @State private var isHovered: Bool = false
    @Environment(\.theme) private var theme

    /// Estimate tokens for catalog entry (two-phase loading shows name + description only)
    private var estimatedTokens: Int {
        // Catalog format: "- **name**: description\n" ≈ 6 chars overhead
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
    struct SkillSelectorView_Previews: PreviewProvider {
        struct PreviewWrapper: View {
            var body: some View {
                SkillSelectorView(personaId: Persona.defaultId)
                    .padding()
                    .frame(width: 450, height: 550)
                    .background(Color.gray.opacity(0.2))
            }
        }

        static var previews: some View {
            PreviewWrapper()
        }
    }
#endif
