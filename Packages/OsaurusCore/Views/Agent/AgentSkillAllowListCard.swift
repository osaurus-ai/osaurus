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
        HStack(spacing: 12) {
            Image(systemName: "lightbulb")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isLimited ? theme.accentColor : theme.secondaryText)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(
                        isLimited ? theme.accentColor.opacity(0.12) : theme.inputBackground)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("Limit to selected skills", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if isLimited {
                Button {
                    showingPicker = true
                } label: {
                    Text("Choose Skills…", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
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
            .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
            .labelsHidden()
            .accessibilityLabel(Text("Limit to selected skills", bundle: .module))
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
        .settingsLandingAnchor("agents.skills")
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Skills this agent can use", bundle: .module)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .padding(12)
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
                                    .font(.system(size: 12))
                                    .foregroundColor(theme.primaryText)
                                if !skill.description.isEmpty {
                                    Text(skill.description)
                                        .font(.system(size: 10))
                                        .foregroundColor(theme.tertiaryText)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                    ForEach(agent?.missingAllowListedSkills(in: installed) ?? [], id: \.self) { name in
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 10))
                                .foregroundColor(theme.warningColor)
                            Text("\(name) — not installed", bundle: .module)
                                .font(.system(size: 12))
                                .foregroundColor(theme.secondaryText)
                            Spacer()
                            Button {
                                removeEntry(name)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.tertiaryText)
                            }
                            .buttonStyle(.plain)
                            .localizedHelp("Remove from the list")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 320)
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
