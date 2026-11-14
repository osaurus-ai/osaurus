//
//  ArchitectSettingsView.swift
//  osaurus
//
//  The "Architect" sidebar tab: the built-in workflow designer's name,
//  avatar, extra instructions, model, and which of its steps ask first.
//  Identity and instructions persist to `ArchitectConfiguration` with the
//  same debounced load-modify-write as Settings → Orchestrator; the model,
//  avatar, and permissions save as soon as they change.
//

import SwiftUI

struct ArchitectSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var pickerCache = ModelPickerItemCache.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var tempDisplayName: String = ""
    @State private var tempSystemPrompt: String = ""
    @State private var model: String?
    @State private var savedFormState: SaveableFormState?
    @State private var autoSaveTask: Task<Void, Never>?
    /// Bumped after a permission change so the menus re-read the registry.
    @State private var policyRevision = 0
    @State private var successMessage: String?

    var body: some View {
        ZStack {
            SettingsPage {
                headerView
            } content: {
                capabilityStrip
                identitySection
                instructionsSection
                modelSection
                permissionsSection
                SettingsDestructiveZone {
                    SettingsDestructiveRow(
                        title: "Restore Defaults",
                        description: "Restore the Architect's name, avatar, and instructions to defaults",
                        actionTitle: "Restore Defaults",
                        severity: .warning,
                        anchorId: "settings.architect.restoreDefaults",
                        action: resetToDefaults
                    )
                }
            }

            if let message = successMessage {
                VStack {
                    Spacer()
                    ThemedToastView(message, type: .success)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, theme.space.s16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.canvas)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            loadConfiguration()
            if !pickerCache.isLoaded { pickerCache.prewarm() }
        }
        .onChange(of: currentFormState) { _, _ in scheduleAutoSave() }
        .onDisappear { flushPendingSave() }
    }

    // MARK: - Header

    private var headerView: some View {
        SettingsPageHeader(
            title: "Architect",
            subtitle: "Configure the built-in agent that designs, tests, and saves workflows"
        )
    }

    // MARK: - Capability Strip

    private var capabilityStrip: some View {
        SettingsFeatureCards(features: [
            SettingsFeature(
                icon: "pencil.and.outline",
                title: "Designs workflows",
                caption: "Turns what you describe into steps you can run again and again."
            ),
            SettingsFeature(
                icon: "play.circle",
                title: "Tests them for real",
                caption: "Runs each workflow with your models before offering to save it."
            ),
            SettingsFeature(
                icon: "hand.raised",
                title: "Saves only when you click",
                caption: "Nothing is added to your workflows until you press Save."
            ),
        ])
    }

    // MARK: - Identity

    private var identitySection: some View {
        BuiltInAgentIdentitySection(
            agentId: Agent.architectId,
            defaultName: "Architect",
            name: $tempDisplayName,
            nameHelp: "Optional. Shown in the agent picker and chat header. Leave blank to keep \"Architect\".",
            nameAnchorId: "settings.architect.name",
            avatarAnchorId: "settings.architect.avatar"
        )
    }

    // MARK: - Instructions

    private var instructionsSection: some View {
        SettingsSection(title: "Instructions") {
            StyledOrchestratorTextArea(
                label: "Extra Instructions",
                text: $tempSystemPrompt,
                placeholder: "For example: Keep every workflow to three steps or fewer.",
                hint: "Optional. Added after the Architect's built-in instructions on every message."
            )
            .settingsLandingAnchor("settings.architect.instructions")
        }
    }

    // MARK: - Model

    private var modelSection: some View {
        SettingsSection(title: "Model") {
            SettingsRow(title: "Architect Model", anchorId: "settings.architect.model") {
                Text("Builds and edits workflows when you chat with the Architect.", bundle: .module)
                if let effective = Self.effectiveModel(model), Self.runsWithoutTools(effective) {
                    Text(
                        "\(effective) runs with tools off, so the Architect can't build. Pick a larger model.",
                        bundle: .module
                    )
                    .foregroundColor(theme.status.warning.foreground)
                }
            } trailing: {
                ModelSearchablePicker(
                    items: Self.modelChoices,
                    selection: Binding(
                        get: { model },
                        set: { chosen in
                            model = chosen
                            ArchitectConfigurationStore.update { $0.model = chosen }
                        }),
                    noneTitle: L("Default model"),
                    style: .compact
                )
            }
        }
    }

    /// Tool-capable models that keep tools on: the Architect works only
    /// through its draft tools, which small-context models run without.
    private static var modelChoices: [ModelPickerItem] {
        WorkflowModelChoices.items(toolCapableOnly: true).filter { !runsWithoutTools($0.id) }
    }

    private static func runsWithoutTools(_ model: String) -> Bool {
        ContextSizeResolver.resolve(modelId: model).sizeClass.disablesTools
    }

    private static func effectiveModel(_ chosen: String?) -> String? {
        chosen ?? AgentManager.shared.effectiveModel(for: Agent.architectId)
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        SettingsSection(
            title: "Permissions",
            subtitle:
                "Choose what the Architect may do on its own. \"Ask before running\" shows a card in the chat each time, with Run once, Deny, and Don't ask again."
        ) {
            permissionRow(
                toolName: WorkflowDraftTool.toolName,
                title: "Edit the Draft",
                caption: "Add, change, and connect the steps of the workflow it is building.",
                anchorId: "settings.architect.permissions.draft"
            )
            permissionRow(
                toolName: WorkflowTestTool.toolName,
                title: "Run Test Workflows",
                caption: "Run the draft for real with your models and keys to check it works.",
                anchorId: "settings.architect.permissions.test"
            )
            SettingsRow(
                title: "Save as a Workflow",
                description: "Always shows a Save card. Nothing is saved until you click it."
            ) {
                StatusChip(L("Always asks you"), tone: .neutral, icon: "lock.fill")
            }
        }
    }

    private func permissionRow(toolName: String, title: String, caption: String, anchorId: String) -> some View {
        SettingsRow(title: title, description: caption, anchorId: anchorId) {
            if let info = ToolRegistry.shared.policyInfo(for: toolName) {
                ToolPolicyMenu(toolName: toolName, info: info) { policyRevision += 1 }
                    .id("\(toolName)-\(policyRevision)")
            }
        }
    }

    // MARK: - Load / Save

    private struct SaveableFormState: Equatable {
        var displayName: String
        var systemPrompt: String
    }

    private var currentFormState: SaveableFormState {
        SaveableFormState(displayName: tempDisplayName, systemPrompt: tempSystemPrompt)
    }

    private var hasUnsavedChanges: Bool {
        guard let savedFormState else { return false }
        return currentFormState != savedFormState
    }

    private func loadConfiguration() {
        let config = ArchitectConfigurationStore.load()
        tempDisplayName = config.displayName ?? ""
        tempSystemPrompt = config.systemPrompt
        model = config.model
        savedFormState = currentFormState
    }

    private func scheduleAutoSave() {
        guard hasUnsavedChanges else { return }
        autoSaveTask?.cancel()
        autoSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, hasUnsavedChanges else { return }
            saveConfiguration()
        }
    }

    private func flushPendingSave() {
        autoSaveTask?.cancel()
        autoSaveTask = nil
        if hasUnsavedChanges { saveConfiguration() }
    }

    private func saveConfiguration() {
        let trimmedName = tempDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = tempSystemPrompt
        let nameChanged = (ArchitectConfigurationStore.load().displayName ?? "") != trimmedName
        ArchitectConfigurationStore.update { config in
            config.displayName = trimmedName.isEmpty ? nil : trimmedName
            config.systemPrompt = prompt
        }
        // A rename rebuilds the published agent snapshot so the picker,
        // sidebar, and chat header pick up the new name in every window.
        if nameChanged { agentManager.refresh() }
        savedFormState = currentFormState
    }

    private func resetToDefaults() {
        tempDisplayName = ""
        tempSystemPrompt = ""
        agentManager.setBuiltInMascot(Agent.architectStockAvatar, for: Agent.architectId)
        withAnimation(theme.motion.springAnimation) {
            successMessage = L("Architect settings restored to defaults")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(theme.motion.quick) { successMessage = nil }
        }
    }
}
