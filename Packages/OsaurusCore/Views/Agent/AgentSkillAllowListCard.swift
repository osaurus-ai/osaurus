//
//  AgentSkillAllowListCard.swift
//  osaurus
//
//  The per-agent skill allow-list (`Agent.skillNames`, `agents[].skills`)
//  in Abilities → Tools. Off: the agent sees every installed skill. On:
//  only the ticked ones, in the prompt manifest, `capabilities_load` and
//  slash commands. Entries for skills not installed here stay on the list
//  and are flagged, so a bundle's agent picks its skill up once it lands.
//

import SwiftUI

struct AgentSkillAllowListCard: View {
    let agentId: UUID

    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared
    @State private var showingPicker = false

    /// Matches the Auto-discover card above it.
    private static let glyphTileSize: CGFloat = 26

    private var agent: Agent? { agentManager.agent(for: agentId) }

    private var installed: [Skill] {
        SkillManager.shared.skills.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var isLimited: Bool { agent?.skillNames != nil }

    private var summary: String {
        guard let agent, let names = agent.skillNames else {
            return L("Off: the agent can use every installed skill.")
        }
        let allowed = installed.filter { agent.allowsSkill($0) }.count
        let missing = agent.missingAllowListedSkills(in: installed).count
        var text = L("\(allowed) of \(installed.count) skills.")
        if names.isEmpty { text = L("No skills: the agent cannot load any.") }
        if missing > 0 { text += " " + L("\(missing) not installed.") }
        return text
    }

    var body: some View {
        HStack(spacing: theme.space.s12) {
            Image(systemName: "lightbulb")
                .glyphSize(13, weight: .semibold)
                .foregroundColor(isLimited ? theme.text.link : theme.text.secondary)
                .frame(width: Self.glyphTileSize, height: Self.glyphTileSize)
                .settingsChrome(isLimited ? .selected : .inset)

            VStack(alignment: .leading, spacing: 2) {
                Text("Limit to selected skills", bundle: .module)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                Text(summary)
                    .textStyle(.footnote)
                    .foregroundColor(theme.text.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if isLimited {
                SettingsButton(.tertiary, "Choose Skills…", size: .compact) {
                    showingPicker = true
                }
                .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
                    picker
                }
            }

            Toggle(
                "",
                isOn: Binding(
                    get: { isLimited },
                    set: { setLimited($0) }
                )
            )
            .settingsSwitch()
            .accessibilityLabel(Text("Limit to selected skills", bundle: .module))
        }
        .padding(theme.space.s12)
        .settingsChrome(.surface)
        .settingsLandingAnchor("agents.skills")
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Skills this agent can use", bundle: .module)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.primary)
                .padding(theme.space.s12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(installed) { skill in
                        Toggle(
                            isOn: Binding(
                                get: { agent?.allowsSkill(skill) ?? false },
                                set: { setSkill(skill, allowed: $0) }
                            )
                        ) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(skill.name)
                                    .font(SettingsFont.body)
                                    .foregroundColor(theme.text.primary)
                                if !skill.description.isEmpty {
                                    Text(skill.description)
                                        .textStyle(.footnote)
                                        .foregroundColor(theme.text.tertiary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .settingsCheckbox()
                        .padding(.horizontal, theme.space.s12)
                        .padding(.vertical, theme.space.s4)
                    }
                    ForEach(agent?.missingAllowListedSkills(in: installed) ?? [], id: \.self) { name in
                        HStack(spacing: theme.space.s6) {
                            Image(systemName: "exclamationmark.triangle")
                                .glyphSize(10)
                                .foregroundColor(theme.status.warning.foreground)
                            Text("\(name) — not installed", bundle: .module)
                                .font(SettingsFont.body)
                                .foregroundColor(theme.text.secondary)
                            Spacer()
                            SettingsIconButton("xmark", help: "Remove from the list", size: .compact) {
                                removeEntry(name)
                            }
                        }
                        .padding(.horizontal, theme.space.s12)
                        .padding(.vertical, theme.space.s4)
                    }
                }
                .padding(.vertical, theme.space.s6)
            }
            .frame(maxHeight: 320)
        }
        .frame(width: SettingsSheetWidth.compact)
        .background(theme.surface.overlay)
    }

    // MARK: - Writes

    /// Turning the limit on starts from every installed skill, so nothing
    /// changes until the user unticks some.
    private func setLimited(_ limited: Bool) {
        guard var agent else { return }
        agent.skillNames = limited ? installed.map(\.name) : nil
        agentManager.update(agent)
    }

    private func setSkill(_ skill: Skill, allowed: Bool) {
        guard var agent, var names = agent.skillNames else { return }
        if allowed {
            if !agent.allowsSkill(skill) { names.append(skill.name) }
        } else {
            names.removeAll { skill.matchesAllowListEntry($0) }
        }
        agent.skillNames = names
        agentManager.update(agent)
    }

    private func removeEntry(_ entry: String) {
        guard var agent, var names = agent.skillNames else { return }
        names.removeAll { $0 == entry }
        agent.skillNames = names
        agentManager.update(agent)
    }
}
