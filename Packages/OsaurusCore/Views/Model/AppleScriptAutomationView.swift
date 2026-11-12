//
//  AppleScriptAutomationView.swift
//  OsaurusCore — AppleScript Computer Use
//
//  AppleScript automation settings (Computer & Browser Use → AppleScript): the
//  Automation permission and how each generated script is gated. The models
//  themselves download under Local Models → AppleScript
//  (`AppleScriptCatalogSource`); which one runs, and how it stays loaded, is
//  chosen in Model Defaults (`AppleScriptDefaultModelGroup`).
//

import SwiftUI

struct AppleScriptAutomationView: View {
    @ObservedObject private var permissionService = SystemPermissionService.shared
    @Environment(\.theme) private var theme

    /// Global subagent defaults (the AppleScript model + execution mode the
    /// main chat and "choose automatically" agents fall back to). Persisted to
    /// the shared `SubagentConfiguration` store on edit.
    @State private var configuration = SubagentConfigurationStore.snapshot()
    @State private var configurationBaseline = SubagentConfigurationStore.snapshot()

    /// Gates persist-on-change until the initial snapshot has landed so loading
    /// the tab never round-trips a default back through `save()`. Mirrors the
    /// Image Generation settings tab.
    @State private var hasLoaded = false

    // MARK: - Body

    var body: some View {
        ScrollView {
            SettingsPageContent {
                permissionSection
                behaviorSection
            }
        }
        .onAppear {
            let latest = SubagentConfigurationStore.snapshot()
            configurationBaseline = latest
            configuration = latest
            DispatchQueue.main.async { hasLoaded = true }
        }
        .onChange(of: configuration) { _, newValue in
            guard hasLoaded else { return }
            let saved = SubagentConfigurationStore.saveEditorSnapshot(
                newValue,
                loadedBaseline: configurationBaseline
            )
            configurationBaseline = saved
            if saved != newValue { configuration = saved }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .subagentConfigurationChanged)
        ) { _ in
            let latest = SubagentConfigurationStore.snapshot()
            let reconciled = SubagentConfiguration.mergingEditorSnapshot(
                configuration,
                loadedBaseline: configurationBaseline,
                live: latest
            )
            configurationBaseline = latest
            if reconciled != configuration { configuration = reconciled }
        }
    }

    // MARK: - Permission

    /// AppleScript talks to other apps via Apple Events, which macOS gates with
    /// the per-app Automation permission. The first time an agent controls a new
    /// app the OS prompts (attributed to Osaurus); this primes the System Events
    /// grant up front so the first real run isn't interrupted.
    private var permissionSection: some View {
        SettingsSection(title: "Automation Permission") {
            VStack(alignment: .leading, spacing: theme.space.s12) {
                Text(
                    "Running AppleScript that controls another app needs macOS Automation permission. The first time an agent controls an app, macOS asks you to allow it for Osaurus. You can prime the System Events grant now.",
                    bundle: .module
                )
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: theme.space.s8) {
                    statusPill
                    Spacer()
                    SettingsButton(.secondary, "Test Automation", size: .compact) {
                        permissionService.requestPermission(.automation)
                    }
                    SettingsButton(.secondary, "Open Settings", icon: "gear", size: .compact) {
                        permissionService.openSystemSettings(for: .automation)
                    }
                }
            }
        }
    }

    private var automationGranted: Bool {
        permissionService.permissionStates[.automation] ?? false
    }

    private var statusPill: some View {
        let granted = automationGranted
        return StatusChip(granted ? L("Automation allowed") : L("Not yet granted"), tone: granted ? .success : .neutral)
    }

    // MARK: - Behavior (global defaults)

    private var behaviorSection: some View {
        SettingsSection(
            title: "Defaults",
            subtitle:
                "These apply to the main chat and any agent set to choose automatically. Each agent can override them in its own Subagents settings."
        ) {
            SettingsRow(title: "Script Execution") {
                VStack(alignment: .leading, spacing: theme.settingsTitleToDescription) {
                    Text("How each generated script is gated before it runs.", bundle: .module)
                    Text(verbatim: configuration.defaultAppleScriptExecutionMode.caption)
                }
            } trailing: {
                AssignedBaseSegmentedPicker(
                    selection: executionModeSelection,
                    options: AppleScriptExecutionMode.allCases.map { .init($0, $0.displayName, verbatim: true) }
                )
                .fixedSize()
                .accessibilityLabel(Text("Script Execution", bundle: .module))
            }
            SettingsRow(title: "Fast Reads on the Chat Model") {
                VStack(alignment: .leading, spacing: theme.settingsTitleToDescription) {
                    Text("Answer Mac queries with the loaded chat model when possible.", bundle: .module)
                    Text(
                        "Read-only Mac queries run on the already-loaded chat model when it supports tools, skipping the model swap. Automation tasks always use the AppleScript model, and queries still can't change anything.",
                        bundle: .module
                    )
                }
            } trailing: {
                Toggle("", isOn: queryPrefersResidentSelection)
                    .settingsSwitch()
            }
        }
    }

    private var executionModeSelection: Binding<AppleScriptExecutionMode> {
        Binding(
            get: { configuration.defaultAppleScriptExecutionMode },
            set: { configuration.defaultAppleScriptExecutionMode = $0 }
        )
    }

    private var queryPrefersResidentSelection: Binding<Bool> {
        Binding(
            get: { configuration.appleScriptQueryPrefersResidentModel },
            set: { configuration.appleScriptQueryPrefersResidentModel = $0 }
        )
    }
}

// MARK: - Model Defaults → AppleScript

/// The AppleScript default model and its residency, on Model Defaults. The
/// model dropdown lists every installed dedicated bundle, with a stale
/// "(unavailable)" row when the stored id is no longer on disk so the choice
/// isn't silently dropped.
struct AppleScriptDefaultModelGroup: View {
    @Environment(\.theme) private var theme
    @ObservedObject var editor: SubagentConfigurationEditorModel
    @State private var installedModels: [MLXModel] = []

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            SettingsSectionHeader(title: "AppleScript")
            SettingsGroup {
                SettingsRow(
                    title: "AppleScript Model",
                    description: installedModels.isEmpty
                        ? "Download a model in Local Models → AppleScript to choose one."
                        : "Used by the main chat and agents set to choose automatically. Each agent can override it.",
                    anchorId: "modelDefaults.appleScript"
                ) {
                    SettingsMenuPicker(selection: modelSelection) {
                        Text("Choose automatically", bundle: .module).tag("")
                        if let current = editor.configuration.defaultAppleScriptModelId,
                            !current.isEmpty,
                            !installedModels.contains(where: { $0.id == current })
                        {
                            Text("\(current) (unavailable)", bundle: .module).tag(current)
                        }
                        ForEach(installedModels) { model in
                            Text(verbatim: model.name).tag(model.id)
                        }
                    }
                }
                SettingsRow(
                    title: "AppleScript Model Residency",
                    description: editor.configuration.appleScriptLoadPolicy.caption,
                    anchorId: "modelDefaults.appleScriptResidency"
                ) {
                    AssignedBaseSegmentedPicker(
                        selection: $editor.configuration.appleScriptLoadPolicy,
                        options: AppleScriptLoadPolicy.allCases.map { .init($0, $0.displayName, verbatim: true) }
                    )
                    .fixedSize()
                    .accessibilityLabel(Text("AppleScript Model Residency", bundle: .module))
                }
            }
        }
        .task { installedModels = AppleScriptModelCatalog.installedModels() }
        .onReceive(NotificationCenter.default.publisher(for: .localModelsChanged)) { _ in
            installedModels = AppleScriptModelCatalog.installedModels()
        }
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: { editor.configuration.defaultAppleScriptModelId ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                editor.configuration.defaultAppleScriptModelId = trimmed.isEmpty ? nil : trimmed
            }
        )
    }
}
