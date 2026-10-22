//
//  AgentTemplatesView.swift
//  osaurus
//
//  The Templates page of Agents: a grid of `AgentTemplateCard`s
//  over the agent templates in `TemplateStore`, with an empty state and
//  file drop. Templates leave the Mac only as an exported file and arrive
//  only through Choose File or a drop. Actions that need a sheet (import,
//  rename) are owned by `AgentsView` so they present from the
//  same host as the Create Agent sheet.
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

struct AgentTemplatesView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var store = TemplateStore.shared

    let columns: [GridItem]
    let hasAppeared: Bool
    let onUse: (AgentTemplate) -> Void
    let onImport: () -> Void
    /// A dropped template file's contents, for the import sheet.
    let onImportText: (String) -> Void
    let onRename: (AgentTemplate) -> Void
    let showSuccess: (String) -> Void
    let showError: (String) -> Void

    @State private var isDropTargeted = false
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
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(theme.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .onAppear { store.reload() }
    }

    private var emptyState: some View {
        ScrollView {
            SettingsEmptyState(
                icon: "square.on.square.dashed",
                title: L("Share Agents as Templates"),
                subtitle: L("Save an agent as a template, or import a template file someone shared with you."),
                examples: [
                    .init(
                        icon: "doc", title: L("Import a File"),
                        description: L("Choose a template file or drop it here")),
                    .init(
                        icon: "sparkles", title: L("Tell the Orchestrator"),
                        description: L("\"Make me an agent from the Cloud Agent template\"")),
                    .init(
                        icon: "square.and.arrow.up", title: L("Send to a Friend"),
                        description: L("Export a file from any template card")),
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
            VStack(alignment: .leading, spacing: 20) {
                if !introDismissed {
                    AgentTemplatesIntroCard(onDismiss: {
                        withAnimation(.easeInOut(duration: 0.2)) { introDismissed = true }
                    })
                    .transition(.opacity)
                }
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(Array(templates.enumerated()), id: \.element.id) { index, template in
                        let builtIn = store.isBuiltIn(template)
                        AgentTemplateCard(
                            template: template,
                            isBuiltIn: builtIn,
                            modelAvailable: modelAvailable(template),
                            animationDelay: Double(index) * 0.05,
                            hasAppeared: hasAppeared,
                            onUse: { onUse(template) },
                            onExportFile: { TemplateFileExport.export(template) },
                            onToggleOrchestrator: { toggleOrchestrator(template) },
                            onRename: { onRename(template) },
                            onDelete: { delete(template) },
                            onSaveToLibrary: builtIn ? { saveToLibrary(template) } : nil
                        )
                        .gridDiffCell()
                    }
                }
                .gridDiffAnimation(token: templates.map(\.id.uuidString).joined(separator: ","))
            }
            .padding(24)
        }
        .opacity(hasAppeared ? 1 : 0)
    }

    // MARK: - Actions

    private var templates: [AgentTemplate] { store.allTemplates(kind: .agent) }

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
