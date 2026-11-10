//
//  ConfiguratorSettingsView.swift
//  osaurus
//
//  Settings → Agents → Configurator: the built-in helper that answers
//  questions about Osaurus and makes settings changes when you ask in chat.
//  Its name is fixed; its extra instructions, model, and temperature persist
//  to `ConfiguratorConfigurationStore`. Instructions save with the same
//  debounced load-modify-write as the Architect page; the model and
//  temperature save as soon as they change.
//

import SwiftUI

struct ConfiguratorSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var pickerCache = ModelPickerItemCache.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var tempSystemPrompt: String = ""
    @State private var savedSystemPrompt: String?
    @State private var model: String?
    @State private var tempTemperature: String = ""
    @State private var autoSaveTask: Task<Void, Never>?
    @State private var successMessage: String?

    var body: some View {
        ZStack {
            SettingsPage {
                SettingsPageHeader(
                    title: "Configurator",
                    subtitle: "Configure the built-in helper that explains Osaurus and changes its settings for you"
                )
            } content: {
                capabilityStrip
                identitySection
                instructionsSection
                modelSection
                ConfigHistorySection()
                SettingsDestructiveZone {
                    SettingsDestructiveRow(
                        title: "Restore Defaults",
                        description: "Clear the Configurator's instructions, model, and temperature",
                        actionTitle: "Restore Defaults",
                        severity: .warning,
                        anchorId: "settings.configurator.restoreDefaults",
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
        .onChange(of: tempSystemPrompt) { _, _ in scheduleAutoSave() }
        .onChange(of: tempTemperature) { _, newValue in saveTemperature(newValue) }
        .onDisappear { flushPendingSave() }
    }

    // MARK: - Capability Strip

    private var capabilityStrip: some View {
        SettingsFeatureCards(features: [
            SettingsFeature(
                icon: "questionmark.bubble",
                title: "Answers from the guide",
                caption: "Explains features and where settings are, using Osaurus's own help pages."
            ),
            SettingsFeature(
                icon: "slider.horizontal.3",
                title: "Changes settings for you",
                caption: "Ask in chat to switch a model, add an agent, or set up an automation."
            ),
            SettingsFeature(
                icon: "hand.raised",
                title: "Asks before changing",
                caption: "Every change shows a card first. Nothing changes until you approve it."
            ),
        ])
    }

    // MARK: - Identity

    private var identitySection: some View {
        SettingsSection(title: "Identity") {
            SettingsRow(
                title: "Name",
                description: "Fixed. The Configurator works behind your chats and never appears in the agent picker.",
                anchorId: "settings.configurator.name"
            ) {
                Text("Configurator", bundle: .module)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.secondary)
            }
        }
    }

    // MARK: - Instructions

    private var instructionsSection: some View {
        SettingsSection(title: "Instructions") {
            StyledOrchestratorTextArea(
                label: "Extra Instructions",
                text: $tempSystemPrompt,
                placeholder: "For example: Always explain what a change does before applying it.",
                hint: "Optional. Added after the Configurator's built-in instructions on every request."
            )
            .settingsLandingAnchor("settings.configurator.instructions")
        }
    }

    // MARK: - Model

    private var modelSection: some View {
        SettingsSection(title: "Model & Generation") {
            SettingsRow(
                title: "Configurator Model",
                description: "Answers Osaurus questions and makes settings changes. Leave unset to use the Orchestrator's model.",
                anchorId: "settings.configurator.model"
            ) {
                ModelSearchablePicker(
                    items: WorkflowModelChoices.items(toolCapableOnly: true),
                    selection: Binding(
                        get: { model },
                        set: { chosen in
                            model = chosen
                            ConfiguratorConfigurationStore.update { $0.model = chosen }
                        }),
                    noneTitle: L("Same as Orchestrator"),
                    style: .compact
                )
            }

            SettingsSliderRow(
                label: "Temperature",
                help: "Randomness (0–2). Leave off to use the model's own default.",
                text: $tempTemperature,
                range: 0 ... 2,
                step: 0.1,
                defaultValue: 0.3,
                formatString: "%.1f",
                anchorId: "settings.configurator.temperature"
            )
        }
    }

    // MARK: - Load / Save

    private func loadConfiguration() {
        let config = ConfiguratorConfigurationStore.load()
        tempSystemPrompt = config.systemPrompt
        savedSystemPrompt = config.systemPrompt
        model = config.model
        tempTemperature = config.temperature.map { String(format: "%.1f", $0) } ?? ""
    }

    private func scheduleAutoSave() {
        guard let savedSystemPrompt, tempSystemPrompt != savedSystemPrompt else { return }
        autoSaveTask?.cancel()
        autoSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            saveInstructions()
        }
    }

    private func flushPendingSave() {
        autoSaveTask?.cancel()
        autoSaveTask = nil
        if let savedSystemPrompt, tempSystemPrompt != savedSystemPrompt { saveInstructions() }
    }

    private func saveInstructions() {
        let prompt = tempSystemPrompt
        ConfiguratorConfigurationStore.update { $0.systemPrompt = prompt }
        savedSystemPrompt = prompt
    }

    private func saveTemperature(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: Float? = trimmed.isEmpty ? nil : Float(trimmed).map { min(max($0, 0), 2) }
        guard trimmed.isEmpty || value != nil else { return }
        guard ConfiguratorConfigurationStore.load().temperature != value else { return }
        ConfiguratorConfigurationStore.update { $0.temperature = value }
    }

    private func resetToDefaults() {
        autoSaveTask?.cancel()
        ConfiguratorConfigurationStore.save(ConfiguratorConfiguration())
        loadConfiguration()
        withAnimation(theme.motion.springAnimation) {
            successMessage = L("Configurator settings restored to defaults")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(theme.motion.quick) { successMessage = nil }
        }
    }
}
