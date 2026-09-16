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

/// Pill segmented control under the section header.
struct AgentsSectionPicker: View {
    @Environment(\.theme) private var theme
    @Binding var selection: AgentsSection
    var counts: [AgentsSection: Int] = [:]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AgentsSection.allCases) { section in
                let isSelected = selection == section
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { selection = section }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: section.icon)
                            .font(.system(size: 10, weight: .semibold))
                        Text(section.title)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        if let count = counts[section], count > 0 {
                            Text("\(count)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(isSelected ? theme.accentColor : theme.tertiaryText)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule().fill(
                                        isSelected ? theme.accentColor.opacity(0.12) : theme.tertiaryBackground))
                        }
                    }
                    .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(isSelected ? theme.accentColor.opacity(0.12) : Color.clear)
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            isSelected ? theme.accentColor.opacity(0.35) : theme.inputBorder, lineWidth: 1)
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
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

    var body: some View {
        Group {
            if store.templates.isEmpty {
                emptyState
            } else {
                grid
            }
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
                ForEach(Array(store.templates.enumerated()), id: \.element.id) { index, template in
                    AgentTemplateCard(
                        template: template,
                        isBuiltIn: false,
                        animationDelay: Double(index) * 0.05,
                        hasAppeared: hasAppeared,
                        onUse: { onUse(template) },
                        onCopyJSON: { copyJSON(template) },
                        onExportFile: { exportFile(template) },
                        onToggleOrchestrator: { toggleOrchestrator(template) },
                        onRename: { onRename(template) },
                        onDelete: { delete(template) }
                    )
                    .gridDiffCell()
                }
            }
            .padding(24)
            .gridDiffAnimation(token: store.templates.map(\.id).joined(separator: ","))
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
