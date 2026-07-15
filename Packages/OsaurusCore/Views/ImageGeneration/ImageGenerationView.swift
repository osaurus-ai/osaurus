//
//  ImageGenerationView.swift
//  osaurus
//
//  Top-level Image Generation management view. Mirrors the Voice/Privacy
//  pattern: a header with sub-tabs for the global image-generation Settings
//  (default models, permission, load policy) and a Models browser for
//  downloading on-device image bundles (vMLXFlux / mflux).
//

import SwiftUI

// MARK: - Image Generation Tab Enum

enum ImageGenerationTab: String, CaseIterable, AnimatedTabItem {
    case settings = "Settings"
    case models = "Models"

    var title: String {
        switch self {
        case .settings: return L("Settings")
        case .models: return L("Models")
        }
    }
}

// MARK: - Image Generation View

struct ImageGenerationView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var managementState = ManagementStateManager.shared
    @ObservedObject private var downloads = ImageModelDownloadService.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var selectedTab: ImageGenerationTab = .settings
    @State private var hasAppeared = false
    @State private var installedCount = 0
    @State private var showImportSheet = false

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .managerHeaderEntrance(hasAppeared: hasAppeared)

            Group {
                switch selectedTab {
                case .settings:
                    ImageGenerationSettingsTab()
                case .models:
                    ImageModelsDownloadView(onImport: { showImportSheet = true })
                }
            }
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .task { await refreshInstalledCount() }
        .onReceive(NotificationCenter.default.publisher(for: .localModelsChanged)) { _ in
            Task { await refreshInstalledCount() }
        }
        .onAppear {
            applySubTabRequestIfNeeded()
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
        .onChange(of: managementState.imageGenerationSubTabRequest) { _, _ in
            applySubTabRequestIfNeeded()
        }
        .sheet(isPresented: $showImportSheet) {
            HuggingFaceImportSheet(
                onImported: { _ in
                    // A language model was pasted — route the user to the Models
                    // window where it has been resolved into the catalog.
                    showImportSheet = false
                    managementState.selectedTab = .models
                },
                onImportedImage: { _ in
                    showImportSheet = false
                    Task { await refreshInstalledCount() }
                }
            )
            .environment(\.theme, themeManager.currentTheme)
        }
    }

    // MARK: - Header

    private var headerView: some View {
        ManagerHeaderWithTabs(
            title: L("Images"),
            subtitle: headerSubtitle
        ) {
            if selectedTab == .models {
                HeaderSecondaryButton(L("Import"), icon: "square.and.arrow.down") {
                    showImportSheet = true
                }
            }
        } tabsRow: {
            HeaderTabsRow(
                selection: $selectedTab,
                counts: installedCount > 0 ? [.models: installedCount] : nil,
                badges: activeDownloadCount > 0
                    ? [.models: activeDownloadCount]
                    : nil
            )
        }
    }

    private var headerSubtitle: String {
        installedCount > 0
            ? L("Generate and edit images with on-device models • \(installedCount) on device")
            : L("Generate and edit images with on-device models")
    }

    /// Number of image bundles currently downloading, for the Models tab badge.
    private var activeDownloadCount: Int {
        downloads.states.values.filter { state in
            if case .downloading = state { return true }
            return false
        }.count
    }

    // MARK: - Helpers

    private func applySubTabRequestIfNeeded() {
        guard let requested = managementState.imageGenerationSubTabRequest else { return }
        if let tab = ImageGenerationTab(rawValue: requested) {
            selectedTab = tab
        }
        managementState.imageGenerationSubTabRequest = nil
    }

    private func refreshInstalledCount() async {
        let models = (try? await ImageGenerationService.shared.availableModels()) ?? []
        installedCount = models.count
    }
}

// MARK: - Image Generation Settings Tab

/// The global image-generation defaults: the fallback generation/edit models,
/// the permission gate, and the GPU residency (load) policy for image jobs.
/// Whether image generation is *enabled* is a per-agent toggle (Agents →
/// Subagents), so there is no master switch here. All persist to the shared
/// `SubagentConfiguration` store (`agent-delegation.json`).
private struct ImageGenerationSettingsTab: View {
    @Environment(\.theme) private var theme

    @State private var configuration = SubagentConfigurationStore.snapshot()
    @State private var pickerItems: [ModelPickerItem] = []

    /// Gates the persist-on-change save until the initial snapshot/re-snapshot
    /// has landed, so loading the tab (which assigns `configuration`) never
    /// round-trips a transient/default value back through `save()` and clobbers
    /// the stored config. Mirrors `AgentsView`'s `isInitialLoadComplete`.
    @State private var hasLoaded = false

    private var imageKindId: String { SubagentCapabilityRegistry.image.id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsSection(title: "Default Models", icon: "photo.stack") {
                    VStack(alignment: .leading, spacing: 16) {
                        sectionBlurb(
                            "The models image jobs fall back to. Each agent can override these in its own Subagents settings."
                        )

                        controlRow("Generation model") {
                            modelDropdown(
                                \.defaultImageGenerationModelId,
                                candidates: pickerItems.imageGenerationDelegateCandidates
                            )
                        }
                        controlRow("Edit model") {
                            modelDropdown(
                                \.defaultImageEditModelId,
                                candidates: pickerItems.imageEditDelegateCandidates
                            )
                        }
                        if pickerItems.imageEditDelegateCandidates.isEmpty {
                            editModelEmptyStateHint
                        }
                    }
                }

                SettingsSection(title: "Image Jobs", icon: "wand.and.stars") {
                    VStack(alignment: .leading, spacing: 16) {
                        sectionBlurb(
                            "How image jobs ask for permission and manage GPU memory between runs."
                        )

                        controlRow(
                            "Permission",
                            hint: "Ask before each image job, always allow, or deny."
                        ) {
                            Picker("", selection: permissionSelection) {
                                ForEach(SubagentPermissionPolicy.allCases, id: \.self) { policy in
                                    Text(LocalizedStringKey(policy.displayName), bundle: .module)
                                        .tag(policy)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                        }

                        SettingsDivider()

                        controlRow(
                            "Load policy",
                            hint: "Controls GPU residency after an image job runs."
                        ) {
                            SettingsMenuDropdown(
                                options: SubagentImageLoadPolicy.allCases.map { value in
                                    SettingsMenuDropdown<SubagentImageLoadPolicy>.Option(
                                        tag: value,
                                        label: Text(
                                            LocalizedStringKey(value.displayName),
                                            bundle: .module
                                        )
                                    )
                                },
                                selection: $configuration.imageJobLoadPolicy
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
        }
        .onReceive(ModelPickerItemCache.shared.$items) { options in
            pickerItems = options
        }
        // Re-snapshot the store on appear so the UI always reflects the latest
        // persisted config even if the `@State` default was captured against a
        // cold/stale cache (the "all settings reset on open" report). The save
        // guard below is flipped on the next runloop tick so this assignment —
        // and the change-notification re-snapshot — never round-trip back
        // through `save()`.
        .onAppear {
            configuration = SubagentConfigurationStore.snapshot()
            DispatchQueue.main.async { hasLoaded = true }
        }
        // Persist immediately on edit, mirroring the Settings → Subagents card.
        // Gated on `hasLoaded` so only real user edits write back.
        .onChange(of: configuration) { _, newValue in
            guard hasLoaded else { return }
            SubagentConfigurationStore.save(newValue)
        }
        // Re-snapshot if another surface mutates the shared store.
        .onReceive(
            NotificationCenter.default.publisher(for: .subagentConfigurationChanged)
        ) { _ in
            let latest = SubagentConfigurationStore.snapshot()
            if latest != configuration { configuration = latest }
        }
    }

    // MARK: - Controls

    /// One settings row: label (and optional hint) on the leading edge with the
    /// control pinned to the trailing edge — the same shape as `SettingsToggle`
    /// and the per-agent Subagents rows. This lets the control sit naturally at
    /// the right (filling the row) instead of in a narrow, left-pinned box.
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

    /// Section-level descriptive copy shown above a section's control rows.
    private func sectionBlurb(_ text: String) -> some View {
        Text(LocalizedStringKey(text), bundle: .module)
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Shown under the Edit model row when no image-edit model is installed.
    /// The dropdown can only offer "Choose automatically" in that state, so
    /// without this the empty control looks broken. Explains why editing is
    /// unavailable and offers a one-tap jump to the Models browser to download
    /// an edit-capable bundle (e.g. Qwen-Image-Edit), which makes the dropdown
    /// populate and chat image-editing work.
    private var editModelEmptyStateHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            Text(
                "No image-edit models installed, so editing is unavailable. Download an edit-capable model (e.g. Qwen-Image-Edit) to enable it.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                ManagementStateManager.shared.imageGenerationSubTabRequest =
                    ImageGenerationTab.models.rawValue
            } label: {
                Text("Browse models", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.accentColor)
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
    }

    /// The trailing image-model dropdown for one default-model field.
    /// `nil` (Choose automatically) resolves to the first ready model at run
    /// time; a stored id no longer on disk shows an "(unavailable)" row so the
    /// selection isn't silently dropped.
    private func modelDropdown(
        _ keyPath: WritableKeyPath<SubagentConfiguration, String?>,
        candidates: [ModelPickerItem]
    ) -> some View {
        SettingsMenuDropdown(
            options: modelOptions(candidates: candidates, currentId: configuration[keyPath: keyPath]),
            selection: modelBinding(keyPath)
        )
    }

    /// The dropdown rows for a model picker: "Choose automatically" first, a
    /// stale "(unavailable)" row when the stored id is no longer downloaded,
    /// then the live candidates.
    private func modelOptions(
        candidates: [ModelPickerItem],
        currentId: String?
    ) -> [SettingsMenuDropdown<String>.Option] {
        var options: [SettingsMenuDropdown<String>.Option] = [
            .init(tag: "", label: Text("Choose automatically", bundle: .module))
        ]
        if let currentId,
            !currentId.isEmpty,
            !candidates.contains(where: { $0.id == currentId })
        {
            options.append(
                .init(tag: currentId, label: Text("\(currentId) (unavailable)", bundle: .module))
            )
        }
        options += candidates.map { .init(tag: $0.id, label: Text(verbatim: $0.displayName)) }
        return options
    }

    // MARK: - Bindings

    /// Two-way binding to an optional model-id default, mapping "" (the
    /// "Choose automatically" row) to `nil`. Shared by the generation/edit rows.
    private func modelBinding(
        _ keyPath: WritableKeyPath<SubagentConfiguration, String?>
    ) -> Binding<String> {
        Binding(
            get: { configuration[keyPath: keyPath] ?? "" },
            set: { configuration[keyPath: keyPath] = normalized($0) }
        )
    }

    private var permissionSelection: Binding<SubagentPermissionPolicy> {
        Binding(
            get: { configuration.permissionDefaults.policy(for: imageKindId) },
            set: { configuration.permissionDefaults.setPolicy($0, for: imageKindId) }
        )
    }

    /// Trims whitespace; an empty result becomes `nil` (Choose automatically).
    private func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Settings Menu Dropdown

/// The app's compact custom dropdown, matching `presetPickerMenu` in the
/// Computer Use settings: a borderless `Menu` that hugs its content on the
/// shared tertiary-fill control chrome, with the selected value followed by a
/// trailing `chevron.up.chevron.down`. Pinned to the trailing edge of a
/// `controlRow`, it reads like every other settings control rather than a raw
/// native pop-up. (`.fixedSize()` is what lets the borderless `Menu` keep this
/// custom label/background — without it the control collapses to the system
/// default chevron-and-text rendering.)
private struct SettingsMenuDropdown<Tag: Hashable>: View {
    @Environment(\.theme) private var theme

    /// One selectable row. `label` is a fully-formed `Text` so each call site
    /// keeps its own localization (localized policy names, verbatim model names).
    struct Option: Identifiable {
        let tag: Tag
        let label: Text
        var id: Tag { tag }
    }

    let options: [Option]
    @Binding var selection: Tag

    private var currentLabel: Text {
        options.first { $0.tag == selection }?.label ?? Text(verbatim: "")
    }

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    selection = option.tag
                } label: {
                    if option.tag == selection {
                        HStack {
                            Image(systemName: "checkmark")
                            option.label
                        }
                    } else {
                        option.label
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                currentLabel
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.tertiaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Preview

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        ImageGenerationView()
    }
#endif
