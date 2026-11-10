//
//  AgentTemplatesView.swift
//  osaurus
//
//  The Templates page of Agents: a grid of `AgentTemplateCard`s
//  over the agent templates in `TemplateStore`, with an empty state and
//  file drop. Templates leave the Mac as a file or, for the user's own, a
//  page on store.osaurus.ai (`ShareWorkflowSheet`). They arrive through
//  Choose File, a drop, or an install link. Actions that need a sheet
//  (import, rename, history) are owned by `AgentsView` so they present from
//  the same host as the Create Agent sheet.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Which list the Agents page shows: the agent grid, or the pushed
/// Templates page.
enum AgentsSection: String, CaseIterable, Identifiable {
    case agents
    case templates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agents: return L("Agents")
        case .templates: return L("Templates")
        }
    }

    var icon: String {
        switch self {
        case .agents: return "person.2"
        case .templates: return "square.on.square.dashed"
        }
    }
}

/// The chip row above the Templates grid.
enum AgentTemplateFilter: String, CaseIterable, Identifiable {
    case all
    case published
    case builtIn
    case yours

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return L("All")
        case .published: return L("Published")
        case .builtIn: return L("Built-in")
        case .yours: return L("Yours")
        }
    }

    var icon: String? {
        switch self {
        case .published: return "globe"
        default: return nil
        }
    }

    var help: String {
        switch self {
        case .all: return L("Every template")
        case .published: return L("Only templates you've published")
        case .builtIn: return L("Templates that ship with Osaurus")
        case .yours: return L("Templates you saved or imported")
        }
    }

    /// Past this many templates the chips show even when nothing is published.
    static let chipThreshold = 8

    static func showsChips(templateCount: Int, hasPublished: Bool) -> Bool {
        hasPublished || templateCount > chipThreshold
    }

    func apply(
        _ templates: [AgentTemplate], isBuiltIn: (AgentTemplate) -> Bool, isPublished: (AgentTemplate) -> Bool
    ) -> [AgentTemplate] {
        switch self {
        case .all: return templates
        case .published: return templates.filter(isPublished)
        case .builtIn: return templates.filter(isBuiltIn)
        case .yours: return templates.filter { !isBuiltIn($0) }
        }
    }
}

struct AgentTemplatesView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var store = TemplateStore.shared
    @ObservedObject private var registryRecords = WorkflowRegistryRecordStore.shared

    let columns: [GridItem]
    let hasAppeared: Bool
    let onUse: (AgentTemplate) -> Void
    let onImport: () -> Void
    /// A dropped template file's contents, for the import sheet.
    let onImportText: (String) -> Void
    let onRename: (AgentTemplate) -> Void
    var onVersionHistory: (AgentTemplate) -> Void = { _ in }
    let showSuccess: (String) -> Void
    let showError: (String) -> Void

    @State private var isDropTargeted = false
    @State private var filter: AgentTemplateFilter = .all
    @State private var sharing: ShareRequest?
    private struct ShareRequest: Identifiable {
        let id = UUID()
        let template: AgentTemplate
        let entry: ShareWorkflowSheet.Entry
        let publishable: Bool
    }

    /// The explainer card above the grid stays until the user closes it.
    @AppStorage("agentTemplatesIntroDismissed") private var introDismissed = false
    /// Snapshot of the model catalog, refreshed on appear and when the
    /// library changes, so each card can mark a missing model without
    /// rebuilding the catalog per render.
    @State private var catalog: ConfigModelReference.Catalog?

    private func modelAvailable(_ template: AgentTemplate) -> Bool {
        guard let catalog else { return true }
        if case .available = template.modelResolution(catalog: catalog) { return true }
        return false
    }

    var body: some View {
        Group {
            if templates.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .onAppear { catalog = ConfigModelReference.liveCatalog() }
        .onChange(of: store.templates.map(\.id)) { _, _ in
            catalog = ConfigModelReference.liveCatalog()
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: theme.radius.large)
                    .strokeBorder(theme.border.focus, style: StrokeStyle(lineWidth: theme.stroke.focus, dash: [8, 6]))
                    .padding(theme.space.s12)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            store.reload()
            // The public read, never signed, so opening the tab never asks
            // to authenticate.
            Task { await WorkflowShareService.shared.refreshAllStats() }
            consumePendingShare()
        }
        .onReceive(ManagementStateManager.shared.$pendingTemplateShare) { _ in consumePendingShare() }
        .sheet(item: $sharing) { request in
            ShareWorkflowSheet(
                template: request.template, entry: request.entry, publishable: request.publishable,
                onDone: { sharing = nil }
            )
            .environment(\.theme, theme)
        }
    }

    private var emptyState: some View {
        ScrollView {
            SettingsEmptyState(
                icon: "square.on.square.dashed",
                title: "Share Agents as Templates",
                subtitle: "Save an agent as a template, or import a template file someone shared with you.",
                examples: [
                    .init(
                        icon: "doc", title: L("Import a File"),
                        description: L("Choose a template file or drop it here")),
                    .init(
                        icon: "sparkles", title: L("Tell the Orchestrator"),
                        description: L("\"Make me an agent from the Cloud Agent template\"")),
                    .init(
                        icon: "square.and.arrow.up", title: L("Send to a Friend"),
                        description: L("Save a file or publish a page from a template card")),
                ],
                primaryAction: .init(title: L("Import Template"), icon: "square.and.arrow.down", handler: onImport),
                secondaryAction: nil,
                hasAppeared: hasAppeared
            )
        }
        .opacity(hasAppeared ? 1 : 0)
    }

    private var grid: some View {
        ScrollView {
            SettingsPageContent {
                if !introDismissed {
                    AgentTemplatesIntroCard(onDismiss: {
                        withAnimation(theme.motion.quick) { introDismissed = true }
                    })
                    .transition(.opacity)
                }
                if showsChips || hasPublished {
                    HStack(alignment: .center, spacing: theme.space.s8) {
                        if showsChips { filterChips }
                        Spacer(minLength: 0)
                        PublishedByYouLine(kind: .agent, anchor: "agents.templates.publishedByYou")
                    }
                }
                if shown.isEmpty {
                    Text("No template matches.", bundle: .module)
                        .font(SettingsFont.caption)
                        .foregroundColor(theme.text.tertiary)
                }
                LazyVGrid(columns: columns, spacing: theme.libraryGridGap) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, template in
                        let builtIn = store.isBuiltIn(template)
                        AgentTemplateCard(
                            template: template,
                            isBuiltIn: builtIn,
                            published: builtIn ? nil : registryRecords.record(for: template.id),
                            modelAvailable: modelAvailable(template),
                            animationDelay: Double(index) * 0.05,
                            hasAppeared: hasAppeared,
                            onUse: { onUse(template) },
                            onExportFile: { share(template, entry: .file) },
                            onShare: { share(template, entry: shareEntry(for: template)) },
                            // Search for publishing lands on the first Share
                            // button the user can publish from.
                            shareAnchor: template.id == firstPublishableID ? "agents.templates.publish" : nil,
                            onPublish: { share(template, entry: .publish) },
                            onManage: { share(template, entry: .manage) },
                            onTakeDown: { takeDown(template) },
                            onVersionHistory: { onVersionHistory(template) },
                            onToggleOrchestrator: { toggleOrchestrator(template) },
                            onRename: { onRename(template) },
                            onDelete: { delete(template) },
                            onSaveToLibrary: builtIn ? { saveToLibrary(template) } : nil
                        )
                        .gridDiffCell()
                    }
                }
                .gridDiffAnimation(token: shown.map(\.id.uuidString).joined(separator: ","))
            }
        }
        .opacity(hasAppeared ? 1 : 0)
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(AgentTemplateFilter.allCases) { option in
                    if option != .published || hasPublished {
                        FilterChip(
                            option.label, icon: option.icon, count: apply(option).count,
                            isSelected: activeFilter == option, help: option.help
                        ) {
                            filter = option
                        }
                    }
                }
            }
        }
        .settingsLandingAnchor("agents.templates.filter")
    }

    // MARK: - Filter

    private var templates: [AgentTemplate] { store.allTemplates(kind: .agent) }

    private func isPublished(_ template: AgentTemplate) -> Bool {
        !store.isBuiltIn(template) && registryRecords.record(for: template.id) != nil
    }

    private var hasPublished: Bool { templates.contains(where: isPublished) }

    private var showsChips: Bool {
        AgentTemplateFilter.showsChips(templateCount: templates.count, hasPublished: hasPublished)
    }

    /// The chosen chip, or All once its chip is gone (nothing published any more).
    private var activeFilter: AgentTemplateFilter {
        guard showsChips else { return .all }
        if filter == .published && !hasPublished { return .all }
        return filter
    }

    private func apply(_ option: AgentTemplateFilter) -> [AgentTemplate] {
        option.apply(templates, isBuiltIn: store.isBuiltIn, isPublished: isPublished)
    }

    private var shown: [AgentTemplate] { apply(activeFilter) }

    // MARK: - Actions

    private var firstPublishableID: UUID? { shown.first { !store.isBuiltIn($0) }?.id }

    /// Choose between a file and a page before publishing; the dashboard
    /// once a record exists.
    private func shareEntry(for template: AgentTemplate) -> ShareWorkflowSheet.Entry {
        registryRecords.record(for: template.id) != nil ? .manage : .choose
    }

    /// The library template a pending Share names. Built-ins never arrive
    /// this way: only a template the user just saved does.
    static func pendingShareTarget(
        _ id: UUID?, in templates: [AgentTemplate], isBuiltIn: (AgentTemplate) -> Bool
    ) -> AgentTemplate? {
        guard let id else { return nil }
        return templates.first { $0.id == id && !isBuiltIn($0) }
    }

    /// Opens Share for the template Save as Template just saved, when the
    /// person chose Share… on its Saved state.
    private func consumePendingShare() {
        let state = ManagementStateManager.shared
        guard let id = state.pendingTemplateShare else { return }
        state.pendingTemplateShare = nil
        guard let template = Self.pendingShareTarget(id, in: templates, isBuiltIn: store.isBuiltIn) else { return }
        let entry = shareEntry(for: template)
        sharing = nil
        // The Save sheet is still closing; macOS drops a sheet presented mid-dismiss.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { share(template, entry: entry) }
    }

    /// Built-ins aren't the user's to sign, so they only export as a file.
    private func share(_ template: AgentTemplate, entry: ShareWorkflowSheet.Entry) {
        let publishable = !store.isBuiltIn(template)
        sharing = ShareRequest(template: template, entry: publishable ? entry : .file, publishable: publishable)
    }

    private func takeDown(_ template: AgentTemplate) {
        Task { @MainActor in
            do {
                try await WorkflowShareService.shared.unpublish(templateID: template.id)
                showSuccess(L("Took down \"\(template.name)\""))
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    private func toggleOrchestrator(_ template: AgentTemplate) {
        store.setAvailableToOrchestrator(!template.availableToOrchestrator, id: template.id)
        showSuccess(
            template.availableToOrchestrator
                ? L("Hidden from the Orchestrator") : L("Visible to the Orchestrator"))
    }

    /// A built-in copied into the library keeps its id, so it shadows the
    /// bundled one and becomes editable (rename, hide, delete).
    private func saveToLibrary(_ template: AgentTemplate) {
        var copy = template
        copy.author = nil
        do {
            try store.save(copy, changelog: L("Saved from the built-in template"))
            showSuccess(L("Saved \"\(template.name)\" to your library"))
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func delete(_ template: AgentTemplate) {
        do {
            try store.delete(id: template.id)
            showSuccess(L("Deleted \"\(template.name)\""))
        } catch {
            showError(error.localizedDescription)
        }
    }

    // MARK: - Drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        TemplateFileExport.loadDroppedFile(providers, onText: onImportText, onError: showError)
    }
}
