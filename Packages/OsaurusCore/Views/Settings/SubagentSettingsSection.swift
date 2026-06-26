//
//  SubagentSettingsSection.swift
//  osaurus
//
//  Settings for bounded local helper jobs launched by the main chat agent.
//

import SwiftUI

struct SubagentSettingsSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    /// Source of the Agent personas offered as `spawn` targets. Observed directly
    /// so the Spawn & Delegation settings tab always reflects the live persona
    /// list without threading it through every initializer.
    @ObservedObject private var agentManager = AgentManager.shared

    @Binding var configuration: SubagentConfiguration
    let modelItems: [ModelPickerItem]

    private var imageGenerationCandidates: [ModelPickerItem] {
        modelItems.imageGenerationDelegateCandidates
    }

    private var imageEditCandidates: [ModelPickerItem] {
        modelItems.imageEditDelegateCandidates
    }

    var body: some View {
        SettingsSection(title: "Spawn & Delegation", icon: "person.2.wave.2") {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSubsection(label: "How It Works") {
                    VStack(alignment: .leading, spacing: 8) {
                        infoLine(
                            "The main chat model can run a bounded helper job — a local text/coder sub-agent, or an image generate/edit — and fold the compact result back into its reply."
                        )
                        infoLine(
                            "Local chat model: with handoff on, the orchestrator is unloaded, the helper model loads and runs, then the chat model reloads. RAM-Safety verifies it fits first."
                        )
                        infoLine(
                            "Cloud / API chat model: nothing is unloaded — the local helper model runs alongside and returns a compact result."
                        )
                        infoLine(
                            "Enabling this exposes two tools to chat: `spawn` (run a selected Agent persona) and `image` (generate, or edit when source images are passed)."
                        )
                    }
                }

                SettingsDivider()

                SettingsSubsection(label: "Enable") {
                    SettingsToggle(
                        title: "Enable Spawn & Delegation",
                        description:
                            "Expose the spawn and image helper tools to chat models. When off, both are removed from the model tool list.",
                        isOn: $configuration.agentDelegationEnabled
                    )
                }

                SettingsDivider()

                SettingsSubsection(label: "Spawnable Agents") {
                    VStack(alignment: .leading, spacing: 8) {
                        infoLine(
                            "Choose which Agent personas the chat model may launch with `spawn`. Off by default — `spawn` stays hidden until at least one agent is enabled here."
                        )
                        if agentManager.agents.isEmpty {
                            infoLine("No agents yet — create an Agent persona to make it spawnable.")
                        } else {
                            ForEach(agentManager.agents) { agent in
                                SettingsToggle(
                                    title: agent.name,
                                    description: agent.description,
                                    isOn: spawnableBinding(for: agent.name)
                                )
                            }
                        }
                    }
                    .disabled(!configuration.agentDelegationEnabled)
                }

                SettingsDivider()

                SettingsSubsection(label: "Local Handoff & RAM Safety") {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsToggle(
                            title: "Local Orchestrator Handoff",
                            description:
                                "When the main chat model is itself local, unload it to run the helper, then reload it afterward. Off keeps local-to-local handoff disabled to avoid double residency. (Cloud orchestrators never need this.)",
                            isOn: $configuration.localTextDelegationEnabled
                        )

                        SettingsToggle(
                            title: "RAM-Safety Preflight",
                            description:
                                "Before a spawned image or text job, verify the helper model fits in memory once the chat model is freed. If it won't fit, refuse the job instead of unloading the chat model and failing to load the helper.",
                            isOn: $configuration.ramSafetyPreflightEnabled
                        )
                    }
                    .disabled(!configuration.agentDelegationEnabled)
                }

                SettingsDivider()

                SettingsSubsection(label: "Image Models") {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsToggle(
                            title: "Enable Chat Image Jobs",
                            description:
                                "Expose the `image` tool (generate + edit) to chat models. Manual image panels keep their own loading behavior.",
                            isOn: $configuration.imageDelegationEnabled
                        )

                        modelPicker(
                            title: "Default Image Generator",
                            selection: Binding(
                                get: { configuration.defaultImageGenerationModelId ?? "" },
                                set: { configuration.defaultImageGenerationModelId = normalizedSelection($0) }
                            ),
                            candidates: imageGenerationCandidates,
                            currentId: configuration.defaultImageGenerationModelId,
                            emptyLabel: "Choose automatically"
                        )

                        modelPicker(
                            title: "Default Image Editor",
                            selection: Binding(
                                get: { configuration.defaultImageEditModelId ?? "" },
                                set: { configuration.defaultImageEditModelId = normalizedSelection($0) }
                            ),
                            candidates: imageEditCandidates,
                            currentId: configuration.defaultImageEditModelId,
                            emptyLabel: "Choose automatically"
                        )
                    }
                    .disabled(!configuration.agentDelegationEnabled)
                }

                SettingsDivider()

                SettingsSubsection(label: "Permissions") {
                    VStack(alignment: .leading, spacing: 12) {
                        // One permission row per delegation kind, driven by the
                        // registry so a future permissioned kind appears here with
                        // no edit to this view.
                        ForEach(SubagentCapabilityRegistry.delegationFamily, id: \.id) { capability in
                            permissionPicker(
                                title: capability.displayLabel,
                                selection: permissionBinding(for: capability.id)
                            )
                        }
                    }
                }

                SettingsDivider()

                SettingsSubsection(label: "Load Policy") {
                    enumPicker(
                        title: "Image Jobs",
                        selection: $configuration.imageJobLoadPolicy,
                        values: SubagentImageLoadPolicy.allCases
                    )
                }

                SettingsDivider()

                SettingsSubsection(label: "Budgets") {
                    VStack(alignment: .leading, spacing: 12) {
                        budgetStepper(
                            title: "Max Tokens",
                            value: $configuration.budgets.maxDelegateTokens,
                            range: 256 ... 32_768,
                            step: 256
                        )
                        budgetStepper(
                            title: "Max Turns",
                            value: $configuration.budgets.maxDelegateTurns,
                            range: 1 ... 8,
                            step: 1
                        )
                        // Note: no "Max Tool Calls" control — spawned subagents are
                        // text-only (no nested tool calls), so it would be a no-op.
                        // See SubagentBudgets.maxToolCalls (reserved).
                        budgetStepper(
                            title: "Max Seconds",
                            value: $configuration.budgets.maxElapsedSeconds,
                            range: 15 ... 1_800,
                            step: 15
                        )
                    }
                }
            }
        }
    }

    private func infoLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
                .font(.system(size: 11))
                .foregroundColor(themeManager.currentTheme.tertiaryText)
            Text(LocalizedStringKey(text), bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(themeManager.currentTheme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func modelPicker(
        title: String,
        selection: Binding<String>,
        candidates: [ModelPickerItem],
        currentId: String?,
        emptyLabel: String
    ) -> some View {
        SettingsField(label: title, hint: modelPickerHint(candidates: candidates)) {
            Picker("", selection: selection) {
                Text(LocalizedStringKey(emptyLabel), bundle: .module).tag("")
                if let currentId,
                    !currentId.isEmpty,
                    !candidates.contains(where: { $0.id == currentId })
                {
                    Text("\(currentId) (unavailable)", bundle: .module).tag(currentId)
                }
                ForEach(candidates) { item in
                    Text(item.displayName).tag(item.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 280, alignment: .leading)
        }
    }

    private func enumPicker<T>(
        title: String,
        selection: Binding<T>,
        values: [T]
    ) -> some View where T: CaseIterable & Hashable, T: IdentifiableDisplay {
        SettingsField(label: title, hint: "") {
            Picker("", selection: selection) {
                ForEach(values, id: \.self) { value in
                    Text(LocalizedStringKey(value.displayName), bundle: .module).tag(value)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 280, alignment: .leading)
        }
    }

    private func permissionPicker(
        title: String,
        selection: Binding<SubagentPermissionPolicy>
    ) -> some View {
        SettingsField(label: title, hint: "") {
            Picker("", selection: selection) {
                ForEach(SubagentPermissionPolicy.allCases, id: \.self) { policy in
                    Text(LocalizedStringKey(policy.displayName), bundle: .module).tag(policy)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
        }
    }

    private func budgetStepper(
        title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int
    ) -> some View {
        SettingsField(label: title, hint: "") {
            Stepper(value: value, in: range, step: step) {
                Text("\(value.wrappedValue)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.primaryText)
                    .frame(width: 72, alignment: .leading)
            }
            .frame(maxWidth: 180)
        }
    }

    private func modelPickerHint(candidates: [ModelPickerItem]) -> String {
        candidates.isEmpty ? "No compatible downloaded model found." : ""
    }

    private func normalizedSelection(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Read/write a single kind's permission policy through the keyed map, so the
    /// permission rows stay registry-driven (no per-kind struct field to bind).
    private func permissionBinding(for kindId: String) -> Binding<SubagentPermissionPolicy> {
        Binding(
            get: { configuration.permissionDefaults.policy(for: kindId) },
            set: { configuration.permissionDefaults.setPolicy($0, for: kindId) }
        )
    }

    /// Membership toggle for `spawnableAgentNames`. Case-insensitive to match
    /// `SubagentConfiguration.isAgentSpawnable`, and de-dupes on insert so a
    /// rename or a duplicate persona name can't stack entries.
    private func spawnableBinding(for name: String) -> Binding<Bool> {
        Binding(
            get: {
                configuration.spawnableAgentNames.contains {
                    $0.caseInsensitiveCompare(name) == .orderedSame
                }
            },
            set: { isOn in
                var names = configuration.spawnableAgentNames.filter {
                    $0.caseInsensitiveCompare(name) != .orderedSame
                }
                if isOn { names.append(name) }
                configuration.spawnableAgentNames = names
            }
        )
    }
}

protocol IdentifiableDisplay {
    var displayName: String { get }
}

extension SubagentImageLoadPolicy: IdentifiableDisplay {}
