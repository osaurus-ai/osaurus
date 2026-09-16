//
//  AgentTemplatesView.swift
//  osaurus
//
//  The Templates tab of the Agents section: a grid of `AgentTemplateCard`s
//  over `AgentTemplateStore`, with an empty state and file drop. Actions
//  that need a sheet (import, rename) are owned by `AgentsView` so they
//  present from the same host as the Create Agent sheet.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Which list the Agents section shows.
/// Conforms to `AnimatedTabItem` so it rides in the shared `HeaderTabsRow`.
enum AgentsSection: String, CaseIterable, Identifiable, AnimatedTabItem {
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
    @ObservedObject private var store = AgentTemplateStore.shared

    let columns: [GridItem]
    let hasAppeared: Bool
    let onUse: (AgentTemplate) -> Void
    let onImport: () -> Void
    let onImportText: (String) -> Void
    let onRename: (AgentTemplate) -> Void
    let showSuccess: (String) -> Void
    let showError: (String) -> Void

    @State private var isDropTargeted = false
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
            if store.allTemplates.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .onAppear { catalog = ConfigModelReference.liveCatalog() }
        .onChange(of: store.templates.map(\.id)) { _, _ in
            catalog = ConfigModelReference.liveCatalog()
        }
        .onDrop(of: [.fileURL, .json, .plainText], isTargeted: $isDropTargeted) { providers in
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
                subtitle: L("Save an agent as a template, or paste one someone shared with you."),
                examples: [
                    .init(
                        icon: "doc.on.clipboard", title: L("Paste JSON"),
                        description: L("Import from the clipboard or a file")),
                    .init(
                        icon: "sparkles", title: L("Tell the Orchestrator"),
                        description: L("\"Make me an agent from the Cloud Agent template\"")),
                    .init(
                        icon: "square.and.arrow.up", title: L("Send to a Friend"),
                        description: L("Copy JSON from any template card")),
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
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(Array(store.allTemplates.enumerated()), id: \.element.id) { index, template in
                    let builtIn = store.isBuiltIn(template)
                    AgentTemplateCard(
                        template: template,
                        isBuiltIn: builtIn,
                        modelAvailable: modelAvailable(template),
                        animationDelay: Double(index) * 0.05,
                        hasAppeared: hasAppeared,
                        onUse: { onUse(template) },
                        onCopyJSON: { copyJSON(template) },
                        onExportFile: { exportFile(template) },
                        onToggleOrchestrator: { toggleOrchestrator(template) },
                        onRename: { onRename(template) },
                        onDelete: { delete(template) },
                        onSaveToLibrary: builtIn ? { saveToLibrary(template) } : nil
                    )
                    .gridDiffCell()
                }
            }
            .padding(24)
            .gridDiffAnimation(token: store.allTemplates.map(\.id).joined(separator: ","))
        }
        .opacity(hasAppeared ? 1 : 0)
    }

    // MARK: - Actions

    private func copyJSON(_ template: AgentTemplate) {
        do {
            let json = try template.jsonString()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(json, forType: .string)
            showSuccess(L("Copied \"\(template.name)\" as JSON"))
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func exportFile(_ template: AgentTemplate) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(template.id).json"
        panel.title = L("Export Template")
        Task { @MainActor in
            guard await panel.beginModal() == .OK, let url = panel.url else { return }
            do {
                try Data(try template.jsonString().utf8).write(to: url, options: .atomic)
                showSuccess(L("Exported \"\(template.name)\""))
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    private func toggleOrchestrator(_ template: AgentTemplate) {
        do {
            try store.setAvailableToOrchestrator(!template.availableToOrchestrator, slug: template.id)
            showSuccess(
                template.availableToOrchestrator
                    ? L("Hidden from the Orchestrator") : L("Visible to the Orchestrator"))
        } catch {
            showError(error.localizedDescription)
        }
    }

    /// A built-in copied into the library keeps its slug, so it shadows the
    /// bundled one and becomes editable (rename, hide, delete).
    private func saveToLibrary(_ template: AgentTemplate) {
        var copy = template
        copy.author = nil
        copy.createdAt = Date()
        do {
            try store.save(copy)
            showSuccess(L("Saved \"\(template.name)\" to your library"))
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func delete(_ template: AgentTemplate) {
        do {
            try store.delete(slug: template.id)
            showSuccess(L("Deleted \"\(template.name)\""))
        } catch {
            showError(error.localizedDescription)
        }
    }

    // MARK: - Drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
                DispatchQueue.main.async { onImportText(text) }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                let text: String?
                if let data = item as? Data { text = String(data: data, encoding: .utf8) } else { text = item as? String }
                guard let text else { return }
                DispatchQueue.main.async { onImportText(text) }
            }
            return true
        }
        return false
    }
}
