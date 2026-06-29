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
                    ImageModelRow(
                        title: model.info.displayName,
                        subtitle: installedSubtitle(model.info),
                        leading: leadingStyle(for: model.info),
                        kindLabel: kindLabel(model.info.kind),
                        quantLabel: quantText(bits: model.info.quantizationBits, id: model.info.id),
                        state: state(model.id),
                        metrics: downloads.metrics[model.id],
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
                    ImageModelRow(
                        title: entry.displayName,
                        subtitle: availableSubtitle(entry),
                        leading: ImageModelRow.Leading(icon: "photo", tint: theme.accentColor),
                        kindLabel: nil,
                        quantLabel: quantText(bits: nil, id: entry.repoId),
                        state: state(entry.id),
                        metrics: downloads.metrics[entry.id],
                        primary: ImageModelRow.Action(title: "Download", icon: "arrow.down.circle") {
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

    private func installedPrimaryAction(_ model: InstalledModel) -> ImageModelRow.Action? {
        let info = model.info
        // Ready + runnable kind → prominent Generate/Edit (opens the manual panel).
        if info.ready, info.kind == "imageGen" || info.kind == "imageEdit" {
            let isEdit = info.kind == "imageEdit"
            return ImageModelRow.Action(
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
            return ImageModelRow.Action(title: "Re-download", icon: "arrow.clockwise") {
                downloads.download(repoId: repo, displayName: info.displayName)
            }
        }
        return nil
    }

    private func installedMenuItems(_ model: InstalledModel) -> [ImageModelRow.Action] {
        let info = model.info
        var items: [ImageModelRow.Action] = []
        // Re-download for ready models lives in the menu (not-ready exposes it as
        // the primary action instead, so it isn't duplicated).
        if info.ready, let repo = model.repoId {
            items.append(
                ImageModelRow.Action(title: "Re-download", icon: "arrow.clockwise") {
                    downloads.download(repoId: repo, displayName: info.displayName)
                }
            )
        }
        // "View on Hugging Face" now lives inline as an always-visible link
        // button (see ImageModelRow), so the overflow menu keeps only the
        // heavier actions: Re-download (for ready bundles) and Delete.
        items.append(
            ImageModelRow.Action(title: "Delete", icon: "trash", role: .destructive) {
                downloads.delete(info.id)
            }
        )
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

    private func leadingStyle(for info: ImageModelInfo) -> ImageModelRow.Leading {
        info.ready
            ? ImageModelRow.Leading(icon: "checkmark.seal.fill", tint: theme.successColor)
            : ImageModelRow.Leading(icon: "exclamationmark.triangle.fill", tint: theme.warningColor)
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

// MARK: - Image Model Row

/// One clean list row for an image bundle, on the shared 10pt input-card chrome
/// (the same surface `SettingsToggle` and the Privacy rows use). The row is
/// static like the Privacy rows; inline controls surface the primary action
/// (Download / Generate / Edit / Re-download / Cancel), live download progress,
/// an always-visible "View on Hugging Face" link, and an overflow menu for the
/// remaining heavier actions (Re-download / Delete) when present.
private struct ImageModelRow: View {
    @Environment(\.theme) private var theme

    struct Leading {
        let icon: String
        let tint: Color
    }

    enum ActionRole { case normal, primary, destructive }

    struct Action: Identifiable {
        let id = UUID()
        let title: String
        let icon: String
        var role: ActionRole = .normal
        let handler: () -> Void
    }

    let title: String
    let subtitle: String
    let leading: Leading
    var kindLabel: String? = nil
    var quantLabel: String? = nil
    let state: DownloadState
    let metrics: ModelDownloadService.DownloadMetrics?
    var primary: Action? = nil
    var menuItems: [Action] = []
    /// Always-visible inline "View on Hugging Face" link (when the source repo
    /// is known). Pulled out of the overflow menu so it stays reachable while a
    /// download is in flight and isn't the lone item behind a 3-dot affordance.
    var onViewHuggingFace: (() -> Void)? = nil
    let onCancel: () -> Void

    private var isActive: Bool {
        switch state {
        case .downloading, .paused: return true
        default: return false
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
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
        )
    }

    // MARK: Pieces

    private var leadingIcon: some View {
        Image(systemName: leading.icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(leading.tint)
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(leading.tint.opacity(0.12)))
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            Text(verbatim: title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            if let kindLabel { pill(kindLabel, tint: theme.accentColor) }
            if let quantLabel { pill(quantLabel, tint: theme.secondaryText) }
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

    private var progressValue: Double {
        switch state {
        case .downloading(let p), .paused(let p): return p
        default: return 0
        }
    }

    private var trailing: some View {
        // The Hugging Face link is rendered first in both states so it never
        // disappears mid-download. Active downloads then show Cancel; idle rows
        // show the primary action plus an overflow menu only when real items
        // remain (Installed: Re-download / Delete).
        HStack(spacing: 8) {
            if let onViewHuggingFace {
                huggingFaceButton(onViewHuggingFace)
            }

            if isActive {
                Button(action: onCancel) {
                    Text("Cancel", bundle: .module)
                }
                .buttonStyle(SettingsButtonStyle())
            } else {
                if let primary {
                    Button(action: primary.handler) {
                        HStack(spacing: 4) {
                            Image(systemName: primary.icon)
                            Text(LocalizedStringKey(primary.title), bundle: .module)
                        }
                    }
                    .buttonStyle(
                        SettingsButtonStyle(
                            isPrimary: primary.role == .primary,
                            isDestructive: primary.role == .destructive
                        )
                    )
                }
                if !menuItems.isEmpty { overflowMenu }
            }
        }
    }

    /// Compact link button (Hugging Face mark) sharing the overflow menu's
    /// chrome so the two trailing controls read as one family.
    private func huggingFaceButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            controlChrome {
                Text(verbatim: "🤗")
                    .font(.system(size: 13))
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .localizedHelp("View on Hugging Face")
    }

    private var overflowMenu: some View {
        Menu {
            ForEach(menuItems) { item in
                Button(role: item.role == .destructive ? .destructive : nil, action: item.handler) {
                    Label {
                        Text(LocalizedStringKey(item.title), bundle: .module)
                    } icon: {
                        Image(systemName: item.icon)
                    }
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
    }

    /// Shared 28x28 rounded-square chrome for the trailing icon controls
    /// (Hugging Face link + overflow menu) so they read as one family.
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
