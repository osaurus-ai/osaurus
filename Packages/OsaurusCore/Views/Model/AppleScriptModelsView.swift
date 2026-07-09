//
//  AppleScriptModelsView.swift
//  OsaurusCore — AppleScript Computer Use
//
//  The "Models" sub-tab of the Computer Use panel. Stages the curated on-device
//  AppleScript models (ordinary MLX bundles) that power the `applescript`
//  subagent, and exposes the global defaults the main chat / "choose
//  automatically" agents fall back to: which model to use and how each generated
//  script is gated (confirm each / auto-run with a warning).
//
//  AppleScript bundles download through the SAME stack as every other local LLM
//  (`ModelManager` + `ModelDownloadService`), so this view drives those directly
//  and reads progress off the shared `ModelDownloadService` publishes. The rows
//  reuse the app's settings-card chrome so the surface matches the Image Models
//  tab and the rest of the app.
//

import SwiftUI

struct AppleScriptModelsView: View {
    @ObservedObject private var downloads = ModelDownloadService.shared
    @ObservedObject private var permissionService = SystemPermissionService.shared
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    /// Global subagent defaults (the AppleScript model + execution mode the
    /// main chat and "choose automatically" agents fall back to). Persisted to
    /// the shared `SubagentConfiguration` store on edit.
    @State private var configuration = SubagentConfigurationStore.snapshot()

    /// Gates persist-on-change until the initial snapshot has landed so loading
    /// the tab never round-trips a default back through `save()`. Mirrors the
    /// Image Generation settings tab.
    @State private var hasLoaded = false

    /// Ids of installed catalog models, refreshed on appear / when downloads
    /// finish so the rows re-segment into Installed vs Available without each
    /// row re-reading the disk during a render pass.
    @State private var installedIds: Set<String> = []

    private var catalog: [MLXModel] { AppleScriptModelCatalog.models }
    private var installedModels: [MLXModel] { catalog.filter { installedIds.contains($0.id) } }
    private var availableModels: [MLXModel] { catalog.filter { !installedIds.contains($0.id) } }

    private func state(_ id: String) -> DownloadState {
        downloads.downloadStates[id] ?? .notStarted
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                aboutSection
                permissionSection
                behaviorSection
                modelsSection
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .task { refreshInstalled() }
        .onReceive(NotificationCenter.default.publisher(for: .localModelsChanged)) { _ in
            refreshInstalled()
        }
        .onReceive(downloads.$downloadStates) { _ in
            refreshInstalled()
        }
        .onAppear {
            configuration = SubagentConfigurationStore.snapshot()
            DispatchQueue.main.async { hasLoaded = true }
        }
        .onChange(of: configuration) { _, newValue in
            guard hasLoaded else { return }
            SubagentConfigurationStore.save(newValue)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .subagentConfigurationChanged)
        ) { _ in
            let latest = SubagentConfigurationStore.snapshot()
            if latest != configuration { configuration = latest }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        SettingsSection(title: "AppleScript automation", icon: "applescript") {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "Give agents a dedicated on-device model that writes and runs AppleScript to automate this Mac — controlling apps like Finder, Safari, Mail, Notes, and System Events. Turn it on per agent in the Agents tab; download a model below to make it available.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Permission

    /// AppleScript talks to other apps via Apple Events, which macOS gates with
    /// the per-app Automation permission. The first time an agent controls a new
    /// app the OS prompts (attributed to Osaurus); this primes the System Events
    /// grant up front so the first real run isn't interrupted.
    private var permissionSection: some View {
        SettingsSection(title: "Automation permission", icon: "lock.shield") {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "Running AppleScript that controls another app needs macOS Automation permission. The first time an agent controls an app, macOS asks you to allow it for Osaurus. You can prime the System Events grant now.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    statusPill
                    Spacer()
                    Button {
                        permissionService.requestPermission(.automation)
                    } label: {
                        Text("Test automation", bundle: .module)
                    }
                    .buttonStyle(SettingsButtonStyle())
                    Button {
                        permissionService.openSystemSettings(for: .automation)
                    } label: {
                        Text("Open Settings", bundle: .module)
                    }
                    .buttonStyle(SettingsButtonStyle())
                }
            }
        }
    }

    private var automationGranted: Bool {
        permissionService.permissionStates[.automation] ?? false
    }

    private var statusPill: some View {
        let granted = automationGranted
        return Text(
            granted ? "Automation allowed" : "Not yet granted",
            bundle: .module
        )
        .font(.system(size: 10, weight: .bold))
        .foregroundColor(granted ? theme.successColor : theme.tertiaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill((granted ? theme.successColor : theme.tertiaryText).opacity(0.12))
        )
    }

    // MARK: - Behavior (global defaults)

    private var behaviorSection: some View {
        SettingsSection(title: "Defaults", icon: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 16) {
                Text(
                    "These apply to the main chat and any agent set to choose automatically. Each agent can override them in its own Subagents settings.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

                controlRow(
                    "Model",
                    hint: installedModels.isEmpty
                        ? "Download a model below to choose one."
                        : "Which AppleScript model the agent uses."
                ) {
                    modelPicker
                }

                SettingsDivider()

                VStack(alignment: .leading, spacing: 6) {
                    controlRow(
                        "Script execution",
                        hint: "How each generated script is gated before it runs."
                    ) {
                        Picker("", selection: executionModeSelection) {
                            ForEach(AppleScriptExecutionMode.allCases, id: \.self) { mode in
                                Text(verbatim: mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    Text(verbatim: configuration.defaultAppleScriptExecutionMode.caption)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                SettingsDivider()

                VStack(alignment: .leading, spacing: 6) {
                    controlRow(
                        "Model residency",
                        hint: "How the AppleScript model is kept loaded between runs."
                    ) {
                        Picker("", selection: loadPolicySelection) {
                            ForEach(AppleScriptLoadPolicy.allCases, id: \.self) { policy in
                                Text(verbatim: policy.displayName).tag(policy)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    Text(verbatim: configuration.appleScriptLoadPolicy.caption)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                SettingsDivider()

                VStack(alignment: .leading, spacing: 6) {
                    controlRow(
                        "Fast reads on the chat model",
                        hint: "Answer Mac queries with the loaded chat model when possible."
                    ) {
                        Toggle("", isOn: queryPrefersResidentSelection)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                    Text(
                        "Read-only Mac queries run on the already-loaded chat model when it supports tools, skipping the model swap. Automation tasks always use the AppleScript model, and queries still can't change anything.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// The global default-model dropdown: "Choose automatically" plus each
    /// installed catalog model, with a stale "(unavailable)" row when the stored
    /// id is no longer on disk so the choice isn't silently dropped.
    private var modelPicker: some View {
        Picker("", selection: modelSelection) {
            Text("Choose automatically", bundle: .module).tag("")
            if let current = configuration.defaultAppleScriptModelId,
                !current.isEmpty,
                !installedModels.contains(where: { $0.id == current })
            {
                Text("\(current) (unavailable)", bundle: .module).tag(current)
            }
            ForEach(installedModels) { model in
                Text(verbatim: model.name).tag(model.id)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: { configuration.defaultAppleScriptModelId ?? "" },
            set: { configuration.defaultAppleScriptModelId = normalized($0) }
        )
    }

    private var executionModeSelection: Binding<AppleScriptExecutionMode> {
        Binding(
            get: { configuration.defaultAppleScriptExecutionMode },
            set: { configuration.defaultAppleScriptExecutionMode = $0 }
        )
    }

    private var loadPolicySelection: Binding<AppleScriptLoadPolicy> {
        Binding(
            get: { configuration.appleScriptLoadPolicy },
            set: { configuration.appleScriptLoadPolicy = $0 }
        )
    }

    private var queryPrefersResidentSelection: Binding<Bool> {
        Binding(
            get: { configuration.appleScriptQueryPrefersResidentModel },
            set: { configuration.appleScriptQueryPrefersResidentModel = $0 }
        )
    }

    // MARK: - Models (download)

    @ViewBuilder
    private var modelsSection: some View {
        if !installedModels.isEmpty {
            SettingsSection(title: "Installed", icon: "checkmark.seal.fill") {
                VStack(spacing: 8) {
                    ForEach(installedModels) { model in
                        modelRow(model, isInstalled: true)
                    }
                }
            }
        }
        if !availableModels.isEmpty {
            SettingsSection(title: "Available", icon: "square.and.arrow.down") {
                VStack(spacing: 8) {
                    ForEach(availableModels) { model in
                        modelRow(model, isInstalled: false)
                    }
                }
            }
        }
    }

    private func modelRow(_ model: MLXModel, isInstalled: Bool) -> some View {
        AppleScriptModelRow(
            title: model.name,
            subtitle: subtitle(for: model, isInstalled: isInstalled),
            sizeLabel: sizeLabel(for: model),
            isTopPick: model.isTopSuggestion,
            isInstalled: isInstalled,
            state: state(model.id),
            metrics: downloads.downloadMetrics[model.id],
            onDownload: { ModelManager.shared.downloadModel(model) },
            onCancel: { ModelManager.shared.cancelDownload(model.id) },
            onDelete: { Task { await ModelManager.shared.deleteModel(model) } },
            onViewHuggingFace: { openHuggingFace(model.id) }
        )
    }

    private func subtitle(for model: MLXModel, isInstalled: Bool) -> String {
        isInstalled ? L("Installed") : model.description
    }

    private func sizeLabel(for model: MLXModel) -> String? {
        guard let bytes = model.downloadSizeBytes, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Helpers

    private func controlRow<Control: View>(
        _ label: String,
        hint: String? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(label), bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                if let hint {
                    Text(LocalizedStringKey(hint), bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
    }

    private func openHuggingFace(_ repoId: String) {
        guard let url = URL(string: "https://huggingface.co/\(repoId)") else { return }
        openURL(url)
    }

    private func refreshInstalled() {
        installedIds = Set(catalog.filter { $0.isDownloaded }.map(\.id))
    }

    private func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - AppleScript Model Row

/// One clean list row for an AppleScript model bundle, on the shared input-card
/// chrome (matching the Image Models rows). Surfaces the primary action
/// (Download / Cancel / Delete), live download progress, a size + "Top Pick"
/// badge, and an always-visible "View on Hugging Face" link.
private struct AppleScriptModelRow: View {
    @Environment(\.theme) private var theme

    let title: String
    let subtitle: String
    var sizeLabel: String? = nil
    var isTopPick: Bool = false
    let isInstalled: Bool
    let state: DownloadState
    let metrics: ModelDownloadService.DownloadMetrics?
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void
    let onViewHuggingFace: () -> Void

    private var isActive: Bool {
        switch state {
        case .downloading, .paused: return true
        default: return false
        }
    }

    private var progressValue: Double {
        switch state {
        case .downloading(let p), .paused(let p): return p
        default: return 0
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            leadingIcon

            VStack(alignment: .leading, spacing: 4) {
                titleRow
                if isActive {
                    progressRow
                } else {
                    Text(verbatim: subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            trailing
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            isInstalled ? theme.successColor.opacity(0.3) : theme.inputBorder,
                            lineWidth: 1
                        )
                )
        )
    }

    private var leadingIcon: some View {
        let tint = isInstalled ? theme.successColor : theme.accentColor
        return Image(systemName: isInstalled ? "checkmark.seal.fill" : "applescript")
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(tint)
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.12)))
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            Text(verbatim: title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            if isTopPick { pill(L("Top Pick"), tint: theme.accentColor) }
            if let sizeLabel { pill(sizeLabel, tint: theme.secondaryText) }
        }
    }

    private func pill(_ text: String, tint: Color) -> some View {
        Text(verbatim: text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.12)))
            .overlay(Capsule().stroke(tint.opacity(0.22), lineWidth: 0.5))
    }

    private var progressRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(theme.tertiaryBackground)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(theme.accentColor)
                        .frame(width: max(0, geo.size.width * progressValue))
                        .animation(.easeOut(duration: 0.3), value: progressValue)
                }
            }
            .frame(height: 4)

            HStack(spacing: 6) {
                Text(verbatim: "\(Int(progressValue * 100))%")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                if let line = metrics?.formattedLine {
                    Text(verbatim: "·").foregroundColor(theme.tertiaryText)
                    Text(verbatim: line)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    private var trailing: some View {
        HStack(spacing: 8) {
            huggingFaceButton

            if isActive {
                Button(action: onCancel) {
                    Text("Cancel", bundle: .module)
                }
                .buttonStyle(SettingsButtonStyle())
            } else if isInstalled {
                Menu {
                    Button(role: .destructive, action: onDelete) {
                        Label {
                            Text("Delete", bundle: .module)
                        } icon: {
                            Image(systemName: "trash")
                        }
                    }
                } label: {
                    controlChrome {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(theme.secondaryText)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                Button(action: onDownload) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                        Text("Download", bundle: .module)
                    }
                }
                .buttonStyle(SettingsButtonStyle(isPrimary: true))
            }
        }
    }

    private var huggingFaceButton: some View {
        Button(action: onViewHuggingFace) {
            controlChrome {
                Text(verbatim: "🤗").font(.system(size: 13))
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .localizedHelp("View on Hugging Face")
    }

    private func controlChrome<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.tertiaryBackground)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.inputBorder, lineWidth: 1))
            )
    }
}
