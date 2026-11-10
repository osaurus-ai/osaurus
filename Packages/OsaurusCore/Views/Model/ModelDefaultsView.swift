//
//  ModelDefaultsView.swift
//  osaurus
//
//  Models → Model Defaults: every "which model does Osaurus use for X"
//  choice on one page. Downloads live in Local Models; each agent can still
//  override its own chat model and subagent models.
//

import SwiftUI

struct ModelDefaultsView: View {
    @ObservedObject private var managementState = ManagementStateManager.shared
    @StateObject private var subagentEditor = SubagentConfigurationEditorModel()

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "Model Defaults",
                subtitle: "Which model Osaurus uses for each kind of job. Agents can override these."
            )
        } content: {
            textGroup
            ImageVideoDefaultModelsGroup(editor: subagentEditor)
            SpeechDefaultModelGroup()
            DetectionDefaultModelGroup()
            AppleScriptDefaultModelGroup(editor: subagentEditor)

            SettingsSection(title: "Downloads & Updates") {
                ModelUpdatesToggle()
                SettingsLinkRow(
                    title: "Local Models",
                    description: "Download and manage the models these defaults choose from.",
                    icon: ManagementTab.models.icon,
                    actionTitle: "Open Local Models"
                ) {
                    managementState.selectedTab = .models
                }
            }
        }
        .onAppear { subagentEditor.reload() }
    }

    private var textGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(title: "Text")
            SettingsGroup {
                SettingsRow(
                    title: "Core Model",
                    description:
                        "Lightweight model for memory consolidation, chat titles, follow-up suggestions and transcription cleanup. Unset uses your active chat model.",
                    anchorId: "settings.general.coreModel"
                ) {
                    ChatModelRolePicker(
                        providerKeyPath: \.coreModelProvider,
                        nameKeyPath: \.coreModelName,
                        fallbackLabel: "Use chat model (default)",
                        explainsUnavailable: true
                    )
                }
                SettingsRow(
                    title: "Compaction Model",
                    description:
                        "Summarizes older messages when a conversation nears the context limit. Unset uses the chat's current model.",
                    anchorId: "settings.chat.compactionModel"
                ) {
                    ChatModelRolePicker(
                        providerKeyPath: \.compactionModelProvider,
                        nameKeyPath: \.compactionModelName,
                        fallbackLabel: "Use chat model (default)"
                    )
                }
            }
            SettingsGroupFooter("Each agent picks its own chat model in its settings.")
        }
    }
}

// MARK: - Updates

/// Own view so download progress on `ModelManager` doesn't redraw the page.
private struct ModelUpdatesToggle: View {
    @ObservedObject private var modelManager = ModelManager.shared

    var body: some View {
        SettingsToggle(
            title: "Automatically Check Model Updates",
            description:
                "Checks installed OsaurusAI models every six hours. Never downloads model files automatically.",
            anchorId: "models.automaticUpdates",
            isOn: $modelManager.automaticallyChecksModelUpdates
        )
    }
}

// MARK: - Speech

/// Default speech-to-text model, chosen from the downloaded speech models.
private struct SpeechDefaultModelGroup: View {
    @ObservedObject private var modelManager = SpeechModelManager.shared

    private var installed: [SpeechModel] {
        modelManager.availableModels.filter { modelManager.effectiveDownloadState(for: $0) == .completed }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(title: "Speech")
            SettingsGroup {
                SettingsRow(
                    title: "Speech-to-Text Model",
                    description: installed.isEmpty
                        ? "Download a model in Local Models → Speech to choose one."
                        : "Used for voice input, Transcription Mode and Wake Word.",
                    anchorId: "modelDefaults.speech"
                ) {
                    if installed.isEmpty {
                        SettingsButton(.secondary, "Download") {
                            ManagementStateManager.shared.openLocalModels(kind: .speech)
                        }
                    } else {
                        SettingsMenuPicker(
                            selection: Binding(
                                get: { modelManager.selectedModelId ?? "" },
                                set: { if !$0.isEmpty { modelManager.setDefaultModel($0) } }
                            )
                        ) {
                            if modelManager.selectedModelId == nil {
                                Text("None", bundle: .module).tag("")
                            }
                            ForEach(installed) { model in
                                Text(verbatim: model.name).tag(model.id)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Privacy detection

/// Which installed on-device model powers the Privacy Filter's AI detection.
private struct DetectionDefaultModelGroup: View {
    @ObservedObject private var downloader = PrivacyFilterModelDownloader.shared
    @ObservedObject private var rampart = RampartModelManager.shared
    @State private var configuration = PrivacyFilterStore.snapshot()

    private var installed: [PrivacyAIBackend] {
        [.rampart, .openai].filter(isInstalled)
    }

    private func isInstalled(_ backend: PrivacyAIBackend) -> Bool {
        switch backend {
        case .openai:
            if case .ready = downloader.state { return true }
            return false
        case .rampart:
            if case .ready = rampart.state { return true }
            return RampartModelManager.bundleExists()
        }
    }

    private func title(_ backend: PrivacyAIBackend) -> String {
        switch backend {
        case .rampart: return "Rampart"
        case .openai: return "OpenAI Privacy Filter"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(title: "Privacy Detection")
            SettingsGroup {
                SettingsRow(
                    title: "Detection Model",
                    description: installed.isEmpty
                        ? "Optional. Download one in Local Models → Privacy Detection; pattern rules work without it."
                        : "Finds names, addresses and secrets that pattern rules miss.",
                    anchorId: "modelDefaults.detection"
                ) {
                    if installed.isEmpty {
                        SettingsButton(.secondary, "Download") {
                            ManagementStateManager.shared.openLocalModels(kind: .detection)
                        }
                    } else {
                        SettingsMenuPicker(
                            selection: Binding(
                                get: { configuration.resolvedAIBackend(isInstalled: isInstalled) ?? installed[0] },
                                set: { newValue in
                                    configuration.aiDetectionBackend = newValue
                                    PrivacyFilterStore.save(configuration)
                                }
                            )
                        ) {
                            ForEach(installed, id: \.self) { backend in
                                Text(verbatim: title(backend)).tag(backend)
                            }
                        }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .privacyFilterConfigurationChanged)) { _ in
            configuration = PrivacyFilterStore.snapshot()
        }
    }
}
