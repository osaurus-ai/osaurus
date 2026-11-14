//
//  ImageGenerationView.swift
//  osaurus
//
//  "Images & Video" (Capabilities): who may start image and video jobs, and
//  the recent cloud video jobs. Which models those jobs use lives in Models →
//  Model Defaults; image bundles download from Local Models → Image. Whether
//  image generation is enabled at all is a per-agent switch (Agents →
//  Abilities → Subagents).
//

import AppKit
import Combine
import SwiftUI

// MARK: - Image Generation Tab Enum

/// Retired inner tabs, kept so settings-search `subTab` values and older
/// links still resolve: Defaults now opens Model Defaults, Image Models opens
/// Local Models filtered to Image.
enum ImageGenerationTab: String, CaseIterable {
    case settings = "Settings"
    case models = "Models"

    static func resolved(from rawValue: String) -> ImageGenerationTab? {
        if let tab = ImageGenerationTab(rawValue: rawValue) { return tab }
        switch rawValue.lowercased() {
        case "defaults": return .settings
        case "image models": return .models
        default: return nil
        }
    }
}

// MARK: - Subagent Configuration Editor

/// Shared editing state for `SubagentConfiguration` (`agent-delegation.json`):
/// persists each edit immediately and reconciles with changes made by other
/// surfaces, without round-tripping the initial load back through `save()`.
@MainActor
final class SubagentConfigurationEditorModel: ObservableObject {
    @Published var configuration: SubagentConfiguration {
        didSet {
            guard hasLoaded, configuration != oldValue else { return }
            let saved = SubagentConfigurationStore.saveEditorSnapshot(configuration, loadedBaseline: baseline)
            baseline = saved
            if saved != configuration { configuration = saved }
        }
    }

    private var baseline: SubagentConfiguration
    private var hasLoaded = false
    private var subscription: AnyCancellable?

    init() {
        let latest = SubagentConfigurationStore.snapshot()
        configuration = latest
        baseline = latest
        subscription = NotificationCenter.default.publisher(for: .subagentConfigurationChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcile() }
            }
    }

    /// Re-snapshot on appear so the UI reflects the latest persisted config,
    /// then start saving user edits on the next runloop turn.
    func reload() {
        hasLoaded = false
        let latest = SubagentConfigurationStore.snapshot()
        baseline = latest
        configuration = latest
        DispatchQueue.main.async { [weak self] in self?.hasLoaded = true }
    }

    private func reconcile() {
        let latest = SubagentConfigurationStore.snapshot()
        let reconciled = SubagentConfiguration.mergingEditorSnapshot(
            configuration,
            loadedBaseline: baseline,
            live: latest
        )
        baseline = latest
        if reconciled != configuration {
            let wasLoaded = hasLoaded
            hasLoaded = false
            configuration = reconciled
            hasLoaded = wasLoaded
        }
    }
}

// MARK: - Images & Video View

struct ImageGenerationView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var managementState = ManagementStateManager.shared
    @StateObject private var editor = SubagentConfigurationEditorModel()

    @State private var videoJobs: [DurableMediaJob] = []

    private var theme: any ThemeProtocol { themeManager.currentTheme }
    private var imageKindId: String { SubagentCapabilityRegistry.image.id }

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "Images & Video",
                subtitle: "Who can start image and video jobs, and what they made recently."
            )
        } content: {
            VStack(alignment: .leading, spacing: theme.space.s8) {
                SettingsSectionHeader(title: "Permissions")
                SettingsGroup {
                    SettingsPickerRow(
                        title: "Image Jobs",
                        description: "Ask before each image job, always allow, or deny.",
                        anchorId: "imageGeneration.permission",
                        selection: permissionSelection(imageKindId),
                        options: SubagentPermissionPolicy.allCases.map { .init($0, $0.displayName) }
                    )
                    SettingsPickerRow(
                        title: "Video Jobs",
                        description: "Ask before each local or cloud video job, always allow, or deny.",
                        anchorId: "imageGeneration.videoPermission",
                        selection: permissionSelection(SubagentCapabilityRegistry.video.id),
                        options: SubagentPermissionPolicy.allCases.map { .init($0, $0.displayName) }
                    )
                }
                SettingsGroupFooter(
                    "Turn image or video generation on per agent under Agents → the agent → Abilities → Subagents."
                )
            }

            VStack(alignment: .leading, spacing: theme.space.s8) {
                SettingsSectionHeader(title: "Models")
                SettingsGroup {
                    SettingsNavigationRow(
                        icon: ManagementTab.modelDefaults.icon,
                        title: "Default Image and Video Models",
                        subtitle: "Generation, edit, text-to-video and image-to-video models, and the image load policy.",
                        anchorId: "imageGeneration.models"
                    ) {
                        managementState.selectedTab = .modelDefaults
                    }
                    SettingsNavigationRow(
                        icon: LocalModelKind.image.icon,
                        title: "Download Image Models",
                        subtitle: "On-device image generation and editing bundles.",
                        anchorId: "imageGeneration.download"
                    ) {
                        managementState.openLocalModels(kind: .image)
                    }
                }
            }

            if !videoJobs.isEmpty {
                VStack(alignment: .leading, spacing: theme.space.s8) {
                    SettingsSectionHeader(title: "Recent Video Jobs")
                    SettingsGroup {
                        ForEach(videoJobs.prefix(10)) { job in
                            videoJobRow(job)
                        }
                    }
                    SettingsGroupFooter(
                        "Video can run locally on this Mac or on connected cloud providers. Local jobs are free and stop when cancelled. Paid cloud jobs are quoted before queueing and keep being recovered after Stop or relaunch because providers do not offer upstream cancellation."
                    )
                }
                .settingsLandingAnchor("imageGeneration.video")
            }
        }
        .environment(\.theme, theme)
        .onAppear {
            editor.reload()
            applySubTabRequestIfNeeded()
            Task { await refreshVideoJobs() }
        }
        .onChange(of: managementState.imageGenerationSubTabRequest) { _, _ in
            applySubTabRequestIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaJobChanged)) { _ in
            Task { await refreshVideoJobs() }
        }
    }

    /// Forwards the retired Defaults / Image Models sub-tabs to their new homes.
    private func applySubTabRequestIfNeeded() {
        guard let requested = managementState.imageGenerationSubTabRequest else { return }
        managementState.imageGenerationSubTabRequest = nil
        switch ImageGenerationTab.resolved(from: requested) {
        case .settings: managementState.selectedTab = .modelDefaults
        case .models: managementState.openLocalModels(kind: .image)
        case nil: break
        }
    }

    @MainActor
    private func refreshVideoJobs() async {
        videoJobs = await MediaGenerationCoordinator.shared.videoJobs()
    }

    private func permissionSelection(_ kindId: String) -> Binding<SubagentPermissionPolicy> {
        Binding(
            get: { editor.configuration.permissionDefaults.policy(for: kindId) },
            set: { editor.configuration.permissionDefaults.setPolicy($0, for: kindId) }
        )
    }

    private func videoJobRow(_ job: DurableMediaJob) -> some View {
        HStack(spacing: theme.space.s12) {
            Image(systemName: job.state == .completed ? "checkmark.circle.fill" : "clock")
                .foregroundColor(job.state == .completed ? theme.status.success.foreground : theme.text.tertiary)
            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(job.modelID)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
                Text(videoJobDetail(job))
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                    .foregroundColor(job.state == .failed ? theme.status.error.foreground : theme.text.tertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if let output = job.outputURL, job.state == .completed {
                Button(L("Open")) { NSWorkspace.shared.open(output) }
                    .buttonStyle(.borderless)
                Button(L("Reveal")) {
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func videoJobDetail(_ job: DurableMediaJob) -> String {
        var values = [job.state.rawValue.replacingOccurrences(of: "_", with: " ").capitalized]
        if let quote = job.quoteUSD {
            values.append(OsaurusRouter.formatUSDAsCredits(quote))
        }
        if let error = job.errorMessage, !error.isEmpty {
            values.append(error)
        }
        return values.joined(separator: " · ")
    }
}

// MARK: - Image & Video Default Models

/// The models image and video jobs fall back to, plus the image-model load
/// policy. Rendered on Models → Model Defaults; each agent can override the
/// models in its own Subagents settings.
struct ImageVideoDefaultModelsGroup: View {
    @ObservedObject var editor: SubagentConfigurationEditorModel

    @State private var pickerItems: [ModelPickerItem] = []

    var body: some View {
        SettingsSection(title: "Images & Video") {
                SettingsRow(
                    title: "Image Generation Model",
                    description: "Used when an agent generates an image without naming a model.",
                    anchorId: "modelDefaults.imageGeneration"
                ) {
                    targetDropdown(
                        selection: $editor.configuration.defaultImageGenerationTarget,
                        candidates: pickerItems.imageGenerationDelegateCandidates
                    )
                }
                SettingsRow(
                    title: "Edit Model",
                    description: pickerItems.imageEditDelegateCandidates.isEmpty
                        ? "No image-edit models installed, so editing is unavailable. Download an edit-capable model (e.g. Qwen-Image-Edit) from Local Models → Image."
                        : "Used when an agent edits an image.",
                    anchorId: "modelDefaults.imageEdit"
                ) {
                    menuPicker(
                        options: modelOptions(
                            candidates: pickerItems.imageEditDelegateCandidates,
                            currentId: editor.configuration.defaultImageEditModelId
                        ),
                        selection: Binding(
                            get: { editor.configuration.defaultImageEditModelId ?? "" },
                            set: {
                                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                                editor.configuration.defaultImageEditModelId = trimmed.isEmpty ? nil : trimmed
                            }
                        )
                    )
                }
                SettingsRow(
                    title: "Text-to-Video Model",
                    description: videoHint,
                    anchorId: "modelDefaults.textToVideo"
                ) {
                    targetDropdown(
                        selection: $editor.configuration.defaultTextToVideoTarget,
                        candidates: videoCandidates(.textToVideo)
                    )
                }
                SettingsRow(
                    title: "Image-to-Video Model",
                    description: "",
                    anchorId: "modelDefaults.imageToVideo"
                ) {
                    targetDropdown(
                        selection: $editor.configuration.defaultImageToVideoTarget,
                        candidates: videoCandidates(.imageToVideo)
                    )
                }
                SettingsRow(
                    title: "Image Model Load Policy",
                    description:
                        "Controls image-model cleanup after a job. Swap Local Models for Subagents (Orchestrator) controls whether the invoking chat model unloads; restoring it always unloads the image model first.",
                    anchorId: "imageGeneration.loadPolicy"
                ) {
                    menuPicker(
                        options: SubagentImageLoadPolicy.visibleCases.map { value in
                            .init(tag: value, label: Text(LocalizedStringKey(value.displayName), bundle: .module))
                        },
                        selection: Binding(
                            get: { editor.configuration.imageJobLoadPolicy.effectiveCleanupPolicy },
                            set: { editor.configuration.imageJobLoadPolicy = $0 }
                        )
                    )
                }
        }
        .onReceive(ModelPickerItemCache.shared.$items) { pickerItems = $0 }
    }

    private var videoHint: String {
        pickerItems.videoGenerationDelegateCandidates.isEmpty
            ? "Add a native Wan bundle to your image models folder, connect a Venice API-key provider, or enable Osaurus Cloud when its media catalog is available."
            : "Video runs on this Mac for free, or on connected cloud providers quoted before queueing."
    }

    private func videoCandidates(_ kind: MediaGenerationKind) -> [ModelPickerItem] {
        pickerItems.videoGenerationDelegateCandidates.filter { $0.mediaModel?.kind == kind }
    }

    private func targetDropdown(
        selection: Binding<MediaModelTarget?>,
        candidates: [ModelPickerItem]
    ) -> some View {
        menuPicker(
            options: targetOptions(candidates: candidates, current: selection.wrappedValue),
            selection: selection
        )
    }

    private func targetOptions(
        candidates: [ModelPickerItem],
        current: MediaModelTarget?
    ) -> [MenuOption<MediaModelTarget?>] {
        var options: [MenuOption<MediaModelTarget?>] = [
            .init(tag: nil, label: Text("Choose automatically", bundle: .module))
        ]
        let targets = candidates.map {
            $0.mediaModel?.target ?? MediaModelTarget(backend: .local, modelID: $0.id)
        }
        if let current, !targets.contains(current) {
            options.append(.init(tag: current, label: Text(verbatim: "\(current.modelID) (unavailable)")))
        }
        options += zip(candidates, targets).map { item, target in
            let price =
                item.mediaModel?.pricing?.minimumUSD.map {
                    " · from \(OsaurusRouter.formatUSDAsCredits($0))"
                } ?? ""
            return .init(
                tag: Optional(target),
                label: Text(verbatim: "\(item.displayName) · \(item.source.displayName)\(price)")
            )
        }
        return options
    }

    /// "Choose automatically" first, a stale "(unavailable)" row when the
    /// stored id is no longer downloaded, then the live candidates.
    private func modelOptions(
        candidates: [ModelPickerItem],
        currentId: String?
    ) -> [MenuOption<String>] {
        var options: [MenuOption<String>] = [
            .init(tag: "", label: Text("Choose automatically", bundle: .module))
        ]
        if let currentId, !currentId.isEmpty, !candidates.contains(where: { $0.id == currentId }) {
            options.append(.init(tag: currentId, label: Text("\(currentId) (unavailable)", bundle: .module)))
        }
        options += candidates.map { .init(tag: $0.id, label: Text(verbatim: $0.displayName)) }
        return options
    }
}

// MARK: - Menu Options

/// One pop-up row with a fully-formed `Text`, so each call site keeps its
/// own localization (localized policy names, verbatim model names).
private struct MenuOption<Tag: Hashable>: Identifiable {
    let tag: Tag
    let label: Text
    var id: Tag { tag }
}

@MainActor
private func menuPicker<Tag: Hashable>(options: [MenuOption<Tag>], selection: Binding<Tag>) -> some View {
    SettingsMenuPicker(selection: selection) {
        ForEach(options) { $0.label.tag($0.tag) }
    }
    .settingsPickerHugging()
}

// MARK: - Preview

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        ImageGenerationView()
    }
#endif
