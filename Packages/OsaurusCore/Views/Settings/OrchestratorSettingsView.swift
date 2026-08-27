//
//  OrchestratorSettingsView.swift
//  osaurus
//
//  The "Orchestrator" sidebar tab: identity and generation settings for
//  the built-in Default agent (the Orchestrator) plus its delegation
//  helpers (Spawn policy, budgets, and RAM-safety knobs).
//
//  Identity fields persist to `DefaultAgentConfiguration` with the same
//  debounced load-modify-write pattern as Chat settings. The delegation
//  card is the shared `SubagentSettingsSection`, whose configuration
//  saves immediately through `SubagentConfigurationStore` (mirroring the
//  behavior it had on the General tab before moving here).
//

import SwiftUI

struct OrchestratorSettingsView: View {
    @EnvironmentObject private var server: ServerController
    @ObservedObject private var themeManager = ThemeManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    // Identity state (→ DefaultAgentConfiguration)
    @State private var tempDisplayName: String = ""
    @State private var tempSystemPrompt: String = ""
    @State private var tempTemperature: String = ""
    @State private var tempMaxTokens: String = ""

    /// Built-in/main-chat Spawn policy plus system runtime knobs for subagent
    /// helper jobs. Backed by `SubagentConfigurationStore`; saved immediately
    /// on change, not through the debounced identity path.
    @State private var subagentConfiguration = SubagentConfigurationStore.snapshot()
    @State private var subagentConfigurationBaseline = SubagentConfigurationStore.snapshot()

    @State private var hasAppeared = false
    @State private var successMessage: String?

    /// Baseline of the save-relevant identity fields as last loaded or
    /// saved; the debounced auto-save is gated on the live form differing
    /// from this so a pristine screen never writes to disk.
    @State private var savedFormState: SaveableFormState?
    @State private var autoSaveTask: Task<Void, Never>?

    /// Drives scroll-to + glow when a settings-search result lands on this tab.
    @ObservedObject private var highlightCoordinator = SettingsHighlightCoordinator.shared

    // MARK: - Body

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                headerView
                    .managerHeaderEntrance(hasAppeared: hasAppeared)

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            capabilityStrip

                            identitySection

                            generationSection

                            SubagentSettingsSection(configuration: $subagentConfiguration)
                                .settingsLandingAnchor("settings.orchestrator.delegation")
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity)
                    }
                    .opacity(hasAppeared ? 1 : 0)
                    .onChange(of: highlightCoordinator.pending) { _, id in
                        scrollToLandingTarget(id, proxy: proxy)
                    }
                    .onAppear {
                        scrollToLandingTarget(highlightCoordinator.pending, proxy: proxy)
                    }
                }
            }

            if let message = successMessage {
                VStack {
                    Spacer()
                    ThemedToastView(message, type: .success)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            loadConfiguration()
            let latest = SubagentConfigurationStore.snapshot()
            subagentConfigurationBaseline = latest
            subagentConfiguration = latest
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
        // Delegation knobs persist immediately (not via the debounced
        // identity save). The re-snapshot on the change notification keeps
        // this in sync if an agent's Subagents tab edits the shared store.
        .onChange(of: subagentConfiguration) { _, newValue in
            // Only a direct edit of this form's batch limit may turn Server
            // Concurrent Sessions from Automatic into an explicit number;
            // store notifications update the baseline first, so mirrored
            // values compare equal and never echo back as a user override.
            let batchLimitWasExplicitlyEdited =
                SpawnBatchConcurrencyContract.configuredLimit(for: newValue)
                != SpawnBatchConcurrencyContract.configuredLimit(
                    for: subagentConfigurationBaseline
                )
            let saved = SubagentConfigurationStore.saveEditorSnapshot(
                newValue,
                loadedBaseline: subagentConfigurationBaseline
            )
            subagentConfigurationBaseline = saved
            if saved != newValue { subagentConfiguration = saved }
            if batchLimitWasExplicitlyEdited {
                Task { @MainActor in
                    await server.applyMainChatBatchLimit(from: saved)
                }
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .subagentConfigurationChanged)
        ) { _ in
            let latest = SubagentConfigurationStore.snapshot()
            let reconciled = SubagentConfiguration.mergingEditorSnapshot(
                subagentConfiguration,
                loadedBaseline: subagentConfigurationBaseline,
                live: latest
            )
            subagentConfigurationBaseline = latest
            if reconciled != subagentConfiguration {
                subagentConfiguration = reconciled
            }
        }
        // Any edit to a save-relevant identity field reschedules the
        // debounced save.
        .onChange(of: currentFormState) { _, _ in scheduleAutoSave() }
        // Persist a pending edit if the user leaves before the debounce fires.
        .onDisappear { flushPendingSave() }
    }

    // MARK: - Header

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: L("Orchestrator"),
            subtitle: L("Configure the built-in agent that sets up Osaurus and delegates work")
        ) {
            HeaderSecondaryButton("Restore Defaults", icon: "arrow.counterclockwise") {
                resetToDefaults()
            }
            .help(
                Text(
                    "Restore the Orchestrator's identity settings to defaults (saved automatically, like any change)",
                    bundle: .module
                )
            )
        }
    }

    /// Scrolls a freshly-landed search target into view. The control itself
    /// glows via its `settingsLandingAnchor`; this only handles positioning.
    private func scrollToLandingTarget(_ id: String?, proxy: ScrollViewProxy) {
        guard let id, id.hasPrefix("settings.") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    // MARK: - Capability Strip

    /// Three equal-weight tiles orienting the tab: what the Orchestrator
    /// does, what it can delegate, and what you can customize — each mapping
    /// onto a section below. Replaces prose so the page reads at a glance.
    private var capabilityStrip: some View {
        HStack(alignment: .top, spacing: 12) {
            capabilityTile(
                icon: "slider.horizontal.3",
                title: "Configures Osaurus",
                caption: "Changes settings, downloads models, and connects providers for you."
            )
            capabilityTile(
                icon: "point.3.connected.trianglepath.dotted",
                title: "Delegates work",
                caption: "Hands tasks to the agents and models you approve under Delegation."
            )
            capabilityTile(
                icon: "person.text.rectangle",
                title: "Yours to shape",
                caption: "Rename it and give it a persona under Identity."
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func capabilityTile(
        icon: String, title: LocalizedStringKey, caption: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(theme.accentColor.opacity(theme.isDark ? 0.16 : 0.10))
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                }
                .frame(width: 22, height: 22)

                Text(title, bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
            }

            Text(caption, bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.primaryBorder.opacity(0.5), lineWidth: 1)
                )
        )
    }

    // MARK: - Identity Section

    /// Display name shown by the live avatar preview: the field's current
    /// text, falling back to the built-in name while blank.
    private var previewName: String {
        let trimmed = tempDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Osaurus" : trimmed
    }

    @ViewBuilder private var identitySection: some View {
        SettingsSection(title: "Identity", icon: "person.text.rectangle") {
            VStack(alignment: .leading, spacing: 20) {
                // The name is edited next to the face it belongs to: the
                // avatar's tint tracks the typed name live, exactly as the
                // agent picker and chat header will render it.
                HStack(alignment: .center, spacing: 16) {
                    AgentAvatarView(
                        mascotId: Agent.default.avatar,
                        name: previewName,
                        tint: agentColorFor(previewName),
                        diameter: 48,
                        customImageURL: nil,
                        monogramFontSize: 20,
                        borderWidth: 0,
                        bleedsToEdge: true
                    )

                    StyledSettingsTextField(
                        label: "Name",
                        text: $tempDisplayName,
                        placeholder: "Osaurus",
                        help: "Optional. Shown in the agent picker and chat header. Leave blank to keep \"Osaurus\".",
                        anchorId: "settings.orchestrator.name"
                    )
                    .frame(maxWidth: 320)
                }

                StyledOrchestratorTextArea(
                    label: "System Prompt",
                    text: $tempSystemPrompt,
                    placeholder: "Enter the Orchestrator's instructions...",
                    hint: "Optional. Persona appended to the Orchestrator's built-in instructions."
                )
                .settingsLandingAnchor("settings.orchestrator.systemPrompt")
            }
        }
    }

    // MARK: - Generation Section

    @ViewBuilder private var generationSection: some View {
        SettingsSection(title: "Generation", icon: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSliderField(
                    label: "Temperature",
                    help: "Randomness (0–2). Higher = more creative",
                    text: $tempTemperature,
                    range: 0 ... 2,
                    step: 0.1,
                    defaultValue: 0.7,
                    formatString: "%.1f",
                    anchorId: "settings.orchestrator.temperature"
                )

                SettingsStepperField(
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
    }

    // MARK: - Success Toast

    private func showSuccess(_ message: String) {
        withAnimation(theme.springAnimation()) {
            successMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(theme.animationQuick()) {
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
/// Chat tab's system-prompt editor styling.
private struct StyledOrchestratorTextArea: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let label: String
    @Binding var text: String
    let placeholder: String
    let hint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(label), bundle: .module)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(themeManager.currentTheme.secondaryText)

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(LocalizedStringKey(placeholder), bundle: .module)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(themeManager.currentTheme.placeholderText)
                        .padding(.top, 12)
                        .padding(.leading, 16)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $text)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.primaryText)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 160, maxHeight: 300)
                    .padding(12)
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(themeManager.currentTheme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                    )
            )

            Text(LocalizedStringKey(hint), bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(themeManager.currentTheme.tertiaryText)
        }
    }
}

// MARK: - Preview

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        OrchestratorSettingsView()
    }
#endif
