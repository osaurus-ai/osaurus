//
//  ClaudeCodeOptionsSection.swift
//  osaurus
//
//  The "Claude Code Options" section for an agent whose runtime is Claude
//  Code. Agents → Configure shows it for custom agents; Settings →
//  Orchestrator shows it for the Default agent, which has no agent editor.
//

import SwiftUI

struct ClaudeCodeOptionsSection: View {
    let agentId: UUID
    @Binding var config: ClaudeCodeAgentConfig
    /// Each control lands search on `"\(anchorPrefix).<control>"`; the
    /// permission switches land on the prefix itself.
    let anchorPrefix: String
    var onSave: () -> Void = {}

    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    private var isDefaultAgent: Bool { agentId == Agent.defaultId }

    var body: some View {
        SettingsSection(title: "Claude Code Options") {
            VStack(alignment: .leading, spacing: theme.space.s14) {
                labeledSegmented(L("Claude model")) {
                    AssignedBaseSegmentedPicker(
                        selection: Binding(
                            get: { config.resolvedModel },
                            set: { model in update { $0.model = model } }
                        ),
                        options: ClaudeCodeModel.allCases.map { .init($0.rawValue, $0.rawValue.capitalized, verbatim: true) }
                            + (ClaudeCodeModel(rawValue: config.resolvedModel) == nil
                                ? [.init(config.resolvedModel, config.resolvedModel, verbatim: true)] : [])
                    )
                }
                .settingsLandingAnchor(anchor("model"))

                Picker(
                    L("Claude effort"),
                    selection: Binding(
                        get: { config.resolvedEffort?.rawValue ?? "" },
                        set: { effort in update { $0.effort = effort.isEmpty ? nil : effort } }
                    )
                ) {
                    Text("Default", bundle: .module).tag("")
                    ForEach(ClaudeCodeEffort.allCases, id: \.rawValue) { effort in
                        Text(verbatim: effort.displayName).tag(effort.rawValue)
                    }
                }
                .settingsLandingAnchor(anchor("effort"))

                labeledSegmented(L("Execution mode")) {
                    AssignedBaseSegmentedPicker(
                        selection: Binding(
                            get: { config.mode },
                            set: { mode in update { $0.mode = mode } }
                        ),
                        options: [.init(ClaudeCodeMode.agent, "Agent"), .init(ClaudeCodeMode.textOnly, "Text only")]
                    )
                }

                Text(
                    config.mode == .agent
                        ? "Claude Code runs its own agent loop under your macOS account. Read, Grep, and Glob are allowed by default; every wider capability is opt-in."
                        : "Claude Code runs as a text generator with every built-in and MCP tool disabled.",
                    bundle: .module
                )
                .textStyle(.footnote)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)

                Toggle(
                    isOn: Binding(
                        get: { config.allowWrites },
                        set: { enabled in update { $0.allowWrites = enabled } }
                    )
                ) {
                    permissionLabel(
                        title: "Allow file changes",
                        detail: "Auto-approve Edit, Write, and NotebookEdit inside the chat folder, or the chat's private scratch folder when none is set."
                    )
                }
                .settingsCheckbox()
                .disabled(config.mode != .agent)

                Toggle(
                    isOn: Binding(
                        get: { config.allowShell },
                        set: { enabled in update { $0.allowShell = enabled } }
                    )
                ) {
                    permissionLabel(
                        title: "Allow shell commands",
                        detail: "Auto-approve Bash and Monitor under your macOS account. Osaurus can't confine shell commands to the chat folder, and this is not the Osaurus sandbox. When off, Claude isn't offered any tool that runs commands."
                    )
                }
                .settingsCheckbox()
                .disabled(config.mode != .agent)

                Toggle(
                    isOn: Binding(
                        get: { config.osaurusTools },
                        set: { enabled in
                            update {
                                $0.osaurusTools = enabled
                                if !enabled { $0.allowOsaurusConfigWrites = false }
                            }
                        }
                    )
                ) {
                    permissionLabel(
                        title: "Use Osaurus Tools",
                        detail: "Give Claude the tools this agent has in Osaurus (its plugins, apps, and MCP servers, plus osaurus_inspect and osaurus_help), with this agent's approvals. The Default agent can also hand tasks to your other agents. Needs the Osaurus server running."
                    )
                }
                .settingsCheckbox()
                .disabled(config.mode != .agent)
                .settingsLandingAnchor(anchor("osaurusTools"))

                Toggle(
                    isOn: Binding(
                        get: { config.allowOsaurusConfigWrites && isDefaultAgent },
                        set: { enabled in update { $0.allowOsaurusConfigWrites = enabled } }
                    )
                ) {
                    permissionLabel(
                        title: "Allow Osaurus configuration changes",
                        detail: isDefaultAgent
                            ? "Also attach osaurus_config, which changes agents, providers, models, plugins, and MCP servers."
                            : "Only the Default agent can change Osaurus configuration."
                    )
                }
                .settingsCheckbox()
                .disabled(config.mode != .agent || !config.osaurusTools || !isDefaultAgent)
                .settingsLandingAnchor(anchor("configWrites"))
            }
            .toggleStyle(.switch)
            .settingsLandingAnchor(anchorPrefix)
        }
    }

    private func anchor(_ suffix: String) -> String {
        "\(anchorPrefix).\(suffix)"
    }

    private func update(_ mutate: (inout ClaudeCodeAgentConfig) -> Void) {
        var next = config
        mutate(&next)
        config = next
        AgentManager.shared.updateClaudeCodeConfig(next, for: agentId)
        onSave()
    }

    private func permissionLabel(title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s2) {
            Text(title, bundle: .module)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.primary)
            Text(detail, bundle: .module)
                .font(SettingsFont.footnote)
                .foregroundColor(theme.text.tertiary)
        }
    }

    /// A segmented control with its label in front. `title` is already
    /// localized.
    private func labeledSegmented<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: theme.settingsInlineGap) {
            Text(verbatim: title)
                .font(SettingsFont.rowTitle)
                .foregroundColor(theme.text.primary)
            control()
                .fixedSize()
                .accessibilityLabel(Text(verbatim: title))
        }
    }
}
