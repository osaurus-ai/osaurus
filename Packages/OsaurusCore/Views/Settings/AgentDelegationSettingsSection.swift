//
//  AgentDelegationSettingsSection.swift
//  osaurus
//
//  Settings for bounded local helper jobs launched by the main chat agent.
//

import SwiftUI

struct AgentDelegationSettingsSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    @Binding var configuration: AgentDelegationConfiguration
    let modelItems: [ModelPickerItem]

    private var textDelegateCandidates: [ModelPickerItem] {
        modelItems.localTextDelegateCandidates
    }

    private var imageGenerationCandidates: [ModelPickerItem] {
        modelItems.imageGenerationDelegateCandidates
    }

    private var imageEditCandidates: [ModelPickerItem] {
        modelItems.imageEditDelegateCandidates
    }

    var body: some View {
        SettingsSection(title: "Agent Delegation", icon: "person.2.wave.2") {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSubsection(label: "How It Works") {
                    VStack(alignment: .leading, spacing: 8) {
                        infoLine(
                            "Spawn lets the main chat model run a bounded helper job — image generation/editing or a local text/coder sub-agent — and fold the result back into its reply."
                        )
                        infoLine(
                            "Local chat model: the orchestrator is unloaded, the spawn model loads and runs, then the chat model reloads. Memory Safety verifies it fits first."
                        )
                        infoLine(
                            "Cloud / API chat model: nothing is unloaded — the local spawn model runs alongside and returns a compact result."
                        )
                        infoLine(
                            "Enabling Agent Delegation exposes these tools to chat: image_generate, image_edit, local_delegate, spawn."
                        )
                    }
                }

                SettingsDivider()

                SettingsSubsection(label: "Availability") {
                    SettingsToggle(
                        title: "Enable Agent Delegation",
                        description:
                            "Expose delegated local helper jobs to chat models. When off, delegate tools are removed from the model tool list.",
                        isOn: $configuration.agentDelegationEnabled
                    )
                }

                SettingsDivider()

                SettingsSubsection(label: "Cloud Cost Saver") {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsToggle(
                            title: "Enable Cloud-to-Local Text Delegate",
                            description:
                                "Allow cloud/API chat models to ask a selected downloaded local model for bounded helper work.",
                            isOn: $configuration.cloudTextDelegationEnabled
                        )

                        SettingsToggle(
                            title: "Local Orchestrator Handoff",
                            description:
                                "When the main chat model is itself local, unload it to run the delegate, then reload it afterward. Off keeps local-to-local delegation disabled to avoid double residency.",
                            isOn: $configuration.localTextDelegationEnabled
                        )

                        modelPicker(
                            title: "Local Text Delegate",
                            selection: Binding(
                                get: { configuration.defaultLocalTextDelegateModelId ?? "" },
                                set: { configuration.defaultLocalTextDelegateModelId = normalizedSelection($0) }
                            ),
                            candidates: textDelegateCandidates,
                            currentId: configuration.defaultLocalTextDelegateModelId,
                            emptyLabel: "Choose automatically"
                        )
                    }
                    .disabled(!configuration.agentDelegationEnabled)
                }

                SettingsDivider()

                SettingsSubsection(label: "Image Jobs") {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsToggle(
                            title: "Enable Chat Image Jobs",
                            description:
                                "Expose image generation and image editing tools to chat models. Manual image panels keep their own loading behavior.",
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

                SettingsSubsection(label: "Load Policy") {
                    VStack(alignment: .leading, spacing: 12) {
                        enumPicker(
                            title: "Text Delegate",
                            selection: $configuration.textDelegateLoadPolicy,
                            values: AgentDelegationTextLoadPolicy.allCases
                        )
                        enumPicker(
                            title: "Image Jobs",
                            selection: $configuration.imageJobLoadPolicy,
                            values: AgentDelegationImageLoadPolicy.allCases
                        )
                        enumPicker(
                            title: "Cloud Sharing",
                            selection: $configuration.sharingPolicy,
                            values: AgentDelegationSharingPolicy.allCases
                        )
                    }
                }

                SettingsDivider()

                SettingsSubsection(label: "Memory Safety") {
                    SettingsToggle(
                        title: "RAM-Safety Preflight",
                        description:
                            "Before a spawned image or text job, verify the spawn model fits in memory once the chat model is freed. If it won't fit, refuse the job instead of unloading the chat model and failing to load the spawn model.",
                        isOn: $configuration.ramSafetyPreflightEnabled
                    )
                }

                SettingsDivider()

                SettingsSubsection(label: "Permissions") {
                    VStack(alignment: .leading, spacing: 12) {
                        permissionPicker(
                            title: "Local Text Delegate",
                            selection: $configuration.permissionDefaults.localTextDelegate
                        )
                        permissionPicker(
                            title: "Delegate Tool Use",
                            selection: $configuration.permissionDefaults.localTextDelegateToolUse
                        )
                        permissionPicker(
                            title: "Image Generate",
                            selection: $configuration.permissionDefaults.imageGenerate
                        )
                        permissionPicker(
                            title: "Image Edit",
                            selection: $configuration.permissionDefaults.imageEdit
                        )
                    }
                }

                SettingsDivider()

                SettingsSubsection(label: "Delegate Budgets") {
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
                        budgetStepper(
                            title: "Max Tool Calls",
                            value: $configuration.budgets.maxToolCalls,
                            range: 0 ... 32,
                            step: 1
                        )
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
        selection: Binding<AgentDelegationPermissionPolicy>
    ) -> some View {
        SettingsField(label: title, hint: "") {
            Picker("", selection: selection) {
                ForEach(AgentDelegationPermissionPolicy.allCases, id: \.self) { policy in
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
}

protocol IdentifiableDisplay {
    var displayName: String { get }
}

extension AgentDelegationTextLoadPolicy: IdentifiableDisplay {}
extension AgentDelegationImageLoadPolicy: IdentifiableDisplay {}
extension AgentDelegationSharingPolicy: IdentifiableDisplay {}
