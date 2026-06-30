//
//  ImageModelsDownloadView.swift
//  osaurus
//
//  The "Models" sub-tab of the Image Generation panel. Stages on-device image
//  bundles (mflux diffusers repos) so they become selectable in chat and the
//  manual generate/edit panel. Presented as clean, sectioned list rows
//  (Installed / Available) on the shared settings card chrome so the surface
//  matches the Privacy tab and the rest of the app — instead of the heavy LLM
//  catalog grid, whose Size/Params columns are empty for image bundles.
//

import SwiftUI

struct ImageModelsDownloadView: View {
    @ObservedObject private var downloads = ImageModelDownloadService.shared
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    /// Routes the (rare) fully-empty state's CTA to the parent's Import sheet.
    var onImport: (() -> Void)? = nil

    @State private var installed: [InstalledModel] = []
    @State private var panel: PanelRequest?

    /// Resolved download sizes (bytes) for Available catalog rows, keyed by
    /// repo id. Filled lazily off the HF tree API (cache-backed) so the list
    /// renders instantly and each row's size fills in as it lands.
    @State private var sizes: [String: Int64] = [:]

    /// Installed bundle paired with its resolved source repo (for re-download),
    /// captured once per refresh so per-row rendering does no filesystem reads.
    private struct InstalledModel: Identifiable {
        let info: ImageModelInfo
        let repoId: String?
        var id: String { info.id }
    }

    /// Identifiable payload for the manual generate/edit panel.
    private struct PanelRequest: Identifiable {
        let id: String
        let displayName: String
        let isEdit: Bool
    }

    private func state(_ id: String) -> DownloadState {
        downloads.states[id] ?? .notStarted
    }

    private var installedIds: Set<String> { Set(installed.map(\.id)) }

    /// OsaurusAI org image bundles (fetched from HF) not yet on disk.
    private var availableEntries: [ImageModelDownload] {
        downloads.fetchedCatalog.filter { !installedIds.contains($0.id) }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if installed.isEmpty && availableEntries.isEmpty && !downloads.isLoadingCatalog {
                    emptyState
                } else {
                    if !installed.isEmpty { installedSection }
                    if !availableEntries.isEmpty || downloads.isLoadingCatalog { availableSection }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .task {
            // Start the org fetch and the local scan together so the loading
            // state engages immediately (no empty-state flash before the list).
            async let installedRefresh: Void = refreshInstalled()
            async let catalogRefresh: Void = downloads.refreshCatalog()
            _ = await (installedRefresh, catalogRefresh)
        }
        // Resolve Available-row sizes whenever the catalog (minus installed)
        // changes. Re-keys on the entry ids so newly fetched rows get a size
        // and rows that disappear (e.g. just installed) stop being queried.
        .task(id: availableEntries.map(\.id)) {
            await refreshAvailableSizes()
        }
        .onReceive(NotificationCenter.default.publisher(for: .localModelsChanged)) { _ in
            Task { await refreshInstalled() }
        }
        .sheet(item: $panel) { request in
            ImageGenerationPanelView(
                modelId: request.id,
                displayName: request.displayName,
                isEdit: request.isEdit
            )
            .environment(\.theme, theme)
        }
    }

    // MARK: - Sections

    private var installedSection: some View {
        SettingsSection(title: "Installed", icon: "checkmark.seal.fill") {
            VStack(spacing: 8) {
                ForEach(installed) { model in
                    ModelListRow(
                        title: model.info.displayName,
                        subtitle: installedSubtitle(model.info),
                        leading: leadingStyle(for: model.info),
                        badges: badges(
                            kind: kindLabel(model.info.kind),
                            quant: quantText(bits: model.info.quantizationBits, id: model.info.id)
                        ),
                        status: rowStatus(model.id),
                        primary: installedPrimaryAction(model),
                        menuItems: installedMenuItems(model),
                        onViewHuggingFace: huggingFaceAction(model.repoId),
                        onCancel: { downloads.cancel(model.id) }
                    )
                }
            }
        }
    }

    private var availableSection: some View {
        SettingsSection(title: "Available", icon: "square.and.arrow.down") {
            VStack(spacing: 8) {
                ForEach(availableEntries) { entry in
                    ModelListRow(
                        title: entry.displayName,
                        subtitle: availableSubtitle(entry),
                        leading: ModelListRow.Leading(icon: "photo", tint: theme.accentColor),
                        badges: badges(kind: nil, quant: quantText(bits: nil, id: entry.repoId)),
                        status: rowStatus(entry.id),
                        primary: ModelListRow.Action(title: "Download", icon: "arrow.down.circle") {
                            downloads.download(entry)
                        },
                        onViewHuggingFace: huggingFaceAction(entry.repoId),
                        onCancel: { downloads.cancel(entry.id) }
                    )
                }
                if downloads.isLoadingCatalog { catalogLoadingRow }
            }
        }
    }

    private var catalogLoadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Checking Hugging Face for more models…", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
            Spacer()
        }
        .padding(12)
    }

    private var emptyState: some View {
        SettingsEmptyState(
            icon: "photo.on.rectangle.angled",
            title: "No image models yet",
            subtitle: "Import an mflux image model to generate and edit images on device.",
            examples: [],
            primaryAction: .init(
                title: L("Import"),
                icon: "square.and.arrow.down",
                handler: { onImport?() }
            ),
            hasAppeared: true
        )
        .frame(minHeight: 380)
    }

    // MARK: - Row models

    private func installedPrimaryAction(_ model: InstalledModel) -> ModelListRow.Action? {
        let info = model.info
        // Ready + runnable kind → prominent Generate/Edit (opens the manual panel).
        if info.ready, info.kind == "imageGen" || info.kind == "imageEdit" {
            let isEdit = info.kind == "imageEdit"
            return ModelListRow.Action(
                title: isEdit ? "Edit" : "Generate",
                icon: isEdit ? "wand.and.stars" : "sparkles",
                role: .primary
            ) {
                panel = PanelRequest(id: info.id, displayName: info.displayName, isEdit: isEdit)
            }
        }
        // Not ready → surface Re-download as the primary fix (when the source repo
        // is known); otherwise the only action is delete, left to the menu.
        if !info.ready, let repo = model.repoId {
            return ModelListRow.Action(title: "Re-download", icon: "arrow.clockwise") {
                downloads.download(repoId: repo, displayName: info.displayName)
            }
        }
        return nil
    }

    private func installedMenuItems(_ model: InstalledModel) -> [ModelListRow.Action] {
        let info = model.info
        var items: [ModelListRow.Action] = []
        // Re-download for ready models lives in the menu (not-ready exposes it as
        // the primary action instead, so it isn't duplicated).
        if info.ready, let repo = model.repoId {
            items.append(
                ModelListRow.Action(title: "Re-download", icon: "arrow.clockwise") {
                    downloads.download(repoId: repo, displayName: info.displayName)
                }
            )
        }
        // "View on Hugging Face" lives inline as an always-visible link button
        // (see ModelListRow), so the overflow menu keeps only the heavier
        // actions: Re-download (for ready bundles) and Delete.
        items.append(
            ModelListRow.Action(title: "Delete", icon: "trash", role: .destructive) {
                downloads.delete(info.id)
            }
        )
        return items
    }

    /// Map the shared `DownloadState` (+ live metrics) onto the row's
    /// presentation status. Paused mirrors downloading here since the image
    /// tab exposes Cancel (not Resume) while a transfer is staged.
    private func rowStatus(_ id: String) -> ModelListRow.Status {
        switch state(id) {
        case .notStarted:
            return .idle
        case .downloading(let progress):
            return .inProgress(progress: progress, detail: downloads.metrics[id]?.formattedLine)
        case .paused(let progress):
            return .inProgress(progress: progress, detail: downloads.metrics[id]?.formattedLine)
        case .completed:
            return .ready
        case .failed(let error):
            return .failed(error)
        }
    }

    /// Build the row's leading badges from the optional capability (kind) and
    /// quantization labels. Both are already localized / formatted by callers.
    private func badges(kind: String?, quant: String?) -> [ModelBadge.Item] {
        var items: [ModelBadge.Item] = []
        if let kind { items.append(ModelBadge.Item(text: kind, style: .accent)) }
        if let quant { items.append(ModelBadge.Item(text: quant, style: .neutral)) }
        return items
    }

    private func installedSubtitle(_ info: ImageModelInfo) -> String {
        guard info.ready else { return info.blockedReasons.first ?? L("Not ready") }
        var parts: [String] = []
        if info.totalBytes > 0 {
            parts.append(
                ByteCountFormatter.string(fromByteCount: Int64(info.totalBytes), countStyle: .file)
            )
        }
        parts.append(L("Ready"))
        return parts.joined(separator: " · ")
    }

    /// Subtitle for an Available row: the catalog note plus the resolved
    /// download size once it's known (e.g. "Text-to-image · mflux · 6.2 GB").
    /// Falls back to the note alone while the size is still resolving, and to
    /// the generic hint when there's nothing else to show.
    private func availableSubtitle(_ entry: ImageModelDownload) -> String {
        var parts: [String] = []
        if let note = entry.note { parts.append(note) }
        if let bytes = sizes[entry.repoId], bytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        return parts.isEmpty ? L("Not downloaded yet") : parts.joined(separator: " · ")
    }

    private func leadingStyle(for info: ImageModelInfo) -> ModelListRow.Leading {
        info.ready
            ? ModelListRow.Leading(icon: "checkmark.seal.fill", tint: theme.successColor)
            : ModelListRow.Leading(icon: "exclamationmark.triangle.fill", tint: theme.warningColor)
    }

    /// A short capability pill for non-default image kinds; plain generation
    /// needs none (everything in this tab is an image model).
    private func kindLabel(_ kind: String) -> String? {
        switch kind {
        case "imageEdit": return L("Edit")
        case "imageUpscale": return L("Upscale")
        default: return nil
        }
    }

    // MARK: - Actions

    private func openHuggingFace(_ repoId: String) {
        guard let url = URL(string: "https://huggingface.co/\(repoId)") else { return }
        openURL(url)
    }

    /// Wrap a (possibly unknown) source repo into a row's "View on Hugging
    /// Face" action, returning `nil` when there's no repo to link to so the
    /// row simply hides the link.
    private func huggingFaceAction(_ repoId: String?) -> (() -> Void)? {
        guard let repoId else { return nil }
        return { openHuggingFace(repoId) }
    }

    private func refreshInstalled() async {
        let models = (try? await ImageGenerationService.shared.availableModels()) ?? []
        installed = models.map {
            InstalledModel(info: $0, repoId: downloads.sourceRepoId(for: $0.id))
        }
    }

    /// Fill in download sizes for Available rows that don't have one yet.
    /// Sequential and cache-backed: the OsaurusAI image catalog is small and
    /// `ModelSizeCache` makes repeats free, so this stays gentle on the HF API
    /// while letting each size appear as soon as it resolves.
    private func refreshAvailableSizes() async {
        for entry in availableEntries where sizes[entry.repoId] == nil {
            if Task.isCancelled { return }
            if let bytes = await downloads.estimateDownloadSize(repoId: entry.repoId), bytes > 0 {
                sizes[entry.repoId] = bytes
            }
        }
    }

    /// Best-effort quantization label: explicit bit width when known, else parsed
    /// from the repo/dir name (fp8, NF4, 4/6/8-bit).
    private func quantText(bits: Int?, id: String) -> String? {
        if let bits { return "\(bits)-bit" }
        let lower = id.lowercased()
        if lower.contains("fp8") { return "FP8" }
        if lower.contains("nf4") { return "NF4" }
        if lower.contains("8bit") || lower.contains("8-bit") { return "8-bit" }
        if lower.contains("6bit") || lower.contains("6-bit") { return "6-bit" }
        if lower.contains("4bit") || lower.contains("4-bit") { return "4-bit" }
        return nil
    }
}
