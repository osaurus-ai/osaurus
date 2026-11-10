//
//  OrchestratorSettingsView.swift
//  osaurus
//
//  The "Orchestrator" sidebar tab: identity and generation settings for
//  the built-in Default agent (the Orchestrator), its working folder, and a
//  link to Agents → Delegation, where its allowed subagents and the
//  delegation limits live (`DelegationSettingsView`).
//
//  Identity fields persist to `DefaultAgentConfiguration` with the same
//  debounced load-modify-write pattern as Chat settings.
//

import SwiftUI

struct OrchestratorSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var managementState = ManagementStateManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    // Identity state (→ DefaultAgentConfiguration)
    @State private var tempDisplayName: String = ""
    @State private var tempSystemPrompt: String = ""
    @State private var tempTemperature: String = ""
    @State private var tempMaxTokens: String = ""

    @State private var successMessage: String?

    /// Baseline of the save-relevant identity fields as last loaded or
    /// saved; the debounced auto-save is gated on the live form differing
    /// from this so a pristine screen never writes to disk.
    @State private var savedFormState: SaveableFormState?
    @State private var autoSaveTask: Task<Void, Never>?


    // MARK: - Body

    var body: some View {
        ZStack {
            SettingsPage {
                headerView
            } content: {
                capabilityStrip
                identitySection
                instructionsSection
                generationSection
                OrchestratorWorkingFolderSection()
                subagentsLink
                OrchestratorDelegationsSection()
                SettingsDestructiveZone {
                    SettingsDestructiveRow(
                        title: "Restore Defaults",
                        description:
                            "Restore the Orchestrator's identity settings to defaults (saved automatically, like any change)",
                        actionTitle: "Restore Defaults",
                        severity: .warning,
                        anchorId: "settings.orchestrator.restoreDefaults",
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
        .onAppear { loadConfiguration() }
        // Any edit to a save-relevant identity field reschedules the
        // debounced save.
        .onChange(of: currentFormState) { _, _ in scheduleAutoSave() }
        // Persist a pending edit if the user leaves before the debounce fires.
        .onDisappear { flushPendingSave() }
    }

    // MARK: - Header

    private var headerView: some View {
        SettingsPageHeader(
            title: "Orchestrator",
            subtitle: "Configure the built-in agent that sets up Osaurus and delegates work"
        )
    }

    // MARK: - Capability Strip

    /// Three equal-weight tiles orienting the tab: what the Orchestrator
    /// does, what it can delegate, and what you can customize — each mapping
    /// onto a section below. Replaces prose so the page reads at a glance.
    private var capabilityStrip: some View {
        SettingsFeatureCards(features: [
            SettingsFeature(
                icon: "slider.horizontal.3",
                title: "Configures Osaurus",
                caption: "Changes settings, downloads models, and connects providers for you."
            ),
            SettingsFeature(
                icon: "point.3.connected.trianglepath.dotted",
                title: "Delegates work",
                caption: "Hands real tasks to the agents allowed in Agents → Delegation; each runs with its own tools."
            ),
            SettingsFeature(
                icon: "folder",
                title: "Works in a folder",
                caption: "Reads its Working Folder to brief subagents; subagents write deliverables there."
            ),
        ])
    }

    // MARK: - Subagents Link

    /// The Orchestrator's allowed subagents and delegation limits live on
    /// Agents → Delegation, shared with every agent.
    private var subagentsLink: some View {
        SettingsSection(title: "Subagents") {
            SettingsNavigationRow(
                icon: ManagementTab.delegation.icon,
                title: L("Allowed Subagents and Limits"),
                subtitle: L("Which agents the Orchestrator hands work to, whether it asks first, and how much each may do. In Agents → Delegation."),
                anchorId: "settings.orchestrator.subagents"
            ) {
                withAnimation(theme.motion.quick) { managementState.selectedTab = .delegation }
            }
        }
    }

    // MARK: - Identity Section

    private var identitySection: some View {
        BuiltInAgentIdentitySection(
            agentId: Agent.defaultId,
            defaultName: "Osaurus",
            name: $tempDisplayName,
            nameHelp: "Optional. Shown in the agent picker and chat header. Leave blank to keep \"Osaurus\".",
            nameAnchorId: "settings.orchestrator.name",
            avatarAnchorId: "settings.orchestrator.avatar"
        )
    }

    private var instructionsSection: some View {
        SettingsSection(title: "Instructions") {
            StyledOrchestratorTextArea(
                label: "System Prompt",
                text: $tempSystemPrompt,
                placeholder: "Enter the Orchestrator's instructions...",
                hint: "Optional. Persona appended to the Orchestrator's built-in instructions."
            )
            .settingsLandingAnchor("settings.orchestrator.systemPrompt")
        }
    }

    // MARK: - Generation Section

    @ViewBuilder private var generationSection: some View {
        SettingsSection(title: "Model & Generation") {
            OrchestratorModelReadinessRow()

            SettingsSliderRow(
                label: "Temperature",
                help: "Randomness (0–2). Leave off to use the model's own default.",
                text: $tempTemperature,
                range: 0 ... 2,
                step: 0.1,
                defaultValue: 0.7,
                formatString: "%.1f",
                anchorId: "settings.orchestrator.temperature"
            )

            SettingsStepperRow(
                label: "Max Output Tokens",
                help:
                    "Optional per-response output cap for the Orchestrator. Leave blank to inherit the active model bundle's generation_config maximum. This is not the model context window or KV retention.",
                text: $tempMaxTokens,
                range: 1 ... 65536,
                step: 1024,
                defaultValue: 16384,
                anchorId: "settings.orchestrator.maxTokens"
            )
        }
    }

    // MARK: - Success Toast

    private func showSuccess(_ message: String) {
        withAnimation(theme.motion.springAnimation) {
            successMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(theme.motion.quick) {
                successMessage = nil
            }
        }
    }

    // MARK: - Configuration Loading

    private func loadConfiguration() {
        Task { @MainActor in
            await Task.yield()
            let defaultAgent = DefaultAgentConfigurationStore.load()
            tempDisplayName = defaultAgent.displayName ?? ""
            tempSystemPrompt = defaultAgent.systemPrompt
            tempTemperature = defaultAgent.temperature.map { String($0) } ?? ""
            tempMaxTokens = defaultAgent.maxTokens.map(String.init) ?? ""
            // Capture the pristine baseline so the auto-save stays idle
            // until the user actually edits something.
            savedFormState = currentFormState
        }
    }

    // MARK: - Reset to Defaults

    private func resetToDefaults() {
        tempDisplayName = ""
        tempSystemPrompt = ""
        tempTemperature = ""
        tempMaxTokens = ""
        agentManager.setBuiltInMascot(Agent.defaultAgentStockAvatar, for: Agent.defaultId)
        showSuccess(L("Orchestrator settings restored to defaults"))
    }

    // MARK: - Dirty-State Tracking

    /// Snapshot of exactly the fields that `saveConfiguration` persists.
    private struct SaveableFormState: Equatable {
        var displayName: String
        var systemPrompt: String
        var temperature: String
        var maxTokens: String
    }

    private var currentFormState: SaveableFormState {
        SaveableFormState(
            displayName: tempDisplayName,
            systemPrompt: tempSystemPrompt,
            temperature: tempTemperature,
            maxTokens: tempMaxTokens
        )
    }

    private var hasUnsavedChanges: Bool {
        guard let savedFormState else { return false }
        return currentFormState != savedFormState
    }

    // MARK: - Auto-Save

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

    // MARK: - Configuration Saving

    private func saveConfiguration() {
        let trimmedName = tempDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)

        let trimmedTemp = tempTemperature.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedTemp: Float? = {
            guard !trimmedTemp.isEmpty, let v = Float(trimmedTemp) else { return nil }
            return max(0.0, min(2.0, v))
        }()

        let trimmedMax = tempMaxTokens.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedMax: Int? = {
            guard !trimmedMax.isEmpty, let v = Int(trimmedMax) else { return nil }
            return max(1, v)
        }()

        // Load-modify-write: only touch the identity fields this view owns
        // so tools / model / sandbox values in the same struct survive.
        var cfg = DefaultAgentConfigurationStore.load()
        let nameChanged = (cfg.displayName ?? "") != trimmedName
        cfg.displayName = trimmedName.isEmpty ? nil : trimmedName
        cfg.systemPrompt = tempSystemPrompt
        cfg.temperature = parsedTemp
        cfg.maxTokens = parsedMax
        DefaultAgentConfigurationStore.save(cfg)

        // A name change must rebuild the published agent snapshot so the
        // picker pill, chat header, and empty-state hero re-render with the
        // new name in every open window.
        if nameChanged {
            AgentManager.shared.refresh()
        }

        // Re-baseline so the dirty check clears now that the live form
        // matches what's persisted.
        savedFormState = currentFormState
    }
}

// MARK: - Styled Text Area

/// Themed multi-line text editor with placeholder + hint, matching the
/// Chat tab's system-prompt editor styling. Shared with Settings → Architect.
struct StyledOrchestratorTextArea: View {
    let label: String
    @Binding var text: String
    let placeholder: String
    let hint: String

    var body: some View {
        SettingsFieldRow(label: label, hint: hint) {
            SettingsTextEditor(text: $text, placeholder: String(localized: String.LocalizationValue(placeholder), bundle: .module), minHeight: 160, maxHeight: 300, monospaced: true)
        }
    }
}

// MARK: - Preview

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        OrchestratorSettingsView()
    }
#endif
