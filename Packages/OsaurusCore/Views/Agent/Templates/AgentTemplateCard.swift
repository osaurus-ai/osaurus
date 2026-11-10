//
//  AgentTemplateCard.swift
//  osaurus
//
//  One card in the Templates tab. Mirrors `AgentCard` so the two grids
//  read as siblings: avatar circle, name + summary, prompt preview, a stat
//  row, and an overflow menu with the library actions. A template in the
//  user's library can be published to the registry like a workflow; the
//  card then shows its Live badge and the publish actions.
//

import SwiftUI

struct AgentTemplateCard: View {
    @Environment(\.theme) private var theme

    let template: AgentTemplate
    let isBuiltIn: Bool
    /// What the registry last said about it, when this Mac published it.
    var published: WorkflowRegistryRecord? = nil
    /// False when the template pins a model this Mac does not have; the
    /// model chip turns warning-coloured so the gap shows before Use.
    var modelAvailable: Bool = true
    let animationDelay: Double
    let hasAppeared: Bool
    let onUse: () -> Void
    let onExportFile: () -> Void
    /// The footer Share button: file or page before publishing, the
    /// dashboard after.
    var onShare: () -> Void = {}
    /// Search landing id for the footer button (set on one card only).
    var shareAnchor: String? = nil
    var onPublish: () -> Void = {}
    var onManage: () -> Void = {}
    var onTakeDown: () -> Void = {}
    var onVersionHistory: () -> Void = {}
    let onToggleOrchestrator: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    /// Built-ins only: copy into the user library so it can be edited.
    var onSaveToLibrary: (() -> Void)? = nil

    @State private var showDeleteConfirm = false
    @State private var confirmTakeDown = false

    private var accent: Color { agentColorFor(template.name) }

    var body: some View {
        LibraryCard(
            title: template.name,
            subtitle: (template.summary?.isEmpty ?? true) ? L("No description") : (template.summary ?? ""),
            subtitleIsPlaceholder: template.summary?.isEmpty ?? true,
            help: L("Create an agent from this template"),
            animationDelay: animationDelay,
            hasAppeared: hasAppeared,
            action: onUse
        ) {
            LibraryIcon(symbol: "square.on.square.dashed", tint: accent)
        } badges: {
            if isBuiltIn {
                StatusChip(L("Built-in"), tint: theme.status.info.foreground)
            }
            StatusChip("v\(template.version)", tint: theme.text.tertiary)
            if let published { LiveBadge(record: published, action: onManage) }
            if template.availableToOrchestrator {
                // Icon-only so the name keeps its room; the
                // menu spells out the state.
                Image(systemName: "sparkles")
                    .font(SettingsFont.glyphSmall)
                    .foregroundColor(theme.text.link)
                    .help(L("Visible to the Orchestrator"))
            }
        } content: {
            LibraryCardPreview(text: template.agent.systemPrompt ?? "", placeholder: "No system prompt")
        } footer: {
            HStack(spacing: theme.space.s8) {
                LibraryStatRow(stats: statChips)
                shareButton
                    .settingsLandingAnchor(shareAnchor)
            }
        } menu: {
            menuItems
        }
        .themedAlert(
            L("Delete Template"),
            isPresented: $showDeleteConfirm,
            message: L("Delete the template \"\(template.name)\"? Agents already created from it are not affected."),
            primaryButton: .destructive(L("Delete"), action: onDelete),
            secondaryButton: .cancel(L("Cancel"))
        )
        .themedAlert(
            WorkflowShareCopy.takeDownTitle(.agent),
            isPresented: $confirmTakeDown,
            message: WorkflowShareCopy.unpublishMessage(template.name),
            primaryButton: .destructive(L("Take Down"), action: onTakeDown),
            secondaryButton: .cancel(L("Cancel"))
        )
    }

    /// Built-ins aren't the user's to sign, so they only export a file.
    @ViewBuilder
    private var shareButton: some View {
        if isBuiltIn {
            SettingsButton(.secondary, "Export", icon: "square.and.arrow.up", size: .compact, action: onExportFile)
                .help(L("Save a copy as a file to send"))
        } else {
            ShareFooterButton(record: published, onShare: onShare, onManage: onManage)
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        Group {
            Button(action: onUse) {
                Label { Text("Use Template", bundle: .module) } icon: { Image(systemName: "plus.circle") }
            }
            if isBuiltIn {
                Button(action: onExportFile) {
                    Label { Text("Export File…", bundle: .module) } icon: { Image(systemName: "square.and.arrow.up") }
                }
            } else {
                Button(action: onExportFile) {
                    Label { Text("Save as File…", bundle: .module) } icon: { Image(systemName: "doc.badge.arrow.up") }
                }
                PublishMenuItems(
                    record: published, version: template.version, onPublish: onPublish, onManage: onManage,
                    onTakeDown: { confirmTakeDown = true })
            }
            Button(action: onVersionHistory) {
                Label { Text("Version History", bundle: .module) } icon: { Image(systemName: "clock.arrow.circlepath") }
            }
            if isBuiltIn, let onSaveToLibrary {
                Divider()
                Button(action: onSaveToLibrary) {
                    Label { Text("Save to Library", bundle: .module) } icon: { Image(systemName: "tray.and.arrow.down") }
                }
            }
            if !isBuiltIn {
                Divider()
                Button(action: onToggleOrchestrator) {
                    Label {
                        Text(
                            template.availableToOrchestrator
                                ? "Hide from Orchestrator" : "Show to Orchestrator",
                            bundle: .module)
                    } icon: {
                        Image(systemName: template.availableToOrchestrator ? "eye.slash" : "eye")
                    }
                }
                Button(action: onRename) {
                    Label { Text("Rename…", bundle: .module) } icon: { Image(systemName: "pencil") }
                }
                Divider()
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label { Text("Delete", bundle: .module) } icon: { Image(systemName: "trash") }
                }
            }
        }
    }

    // MARK: - Stats

    /// Model, tool count, then icon-only markers for sandbox / subagents
    /// so the row never truncates at the default window width. The setup
    /// count keeps its text because it is the one thing a user must act on.
    private var statChips: [LibraryStat] {
        var chips: [LibraryStat] = []
        let model = template.agent.model.valueOrNil ?? L("Default")
        let modelMissing = template.agent.model.valueOrNil != nil && !modelAvailable
        chips.append(
            LibraryStat(
                icon: modelMissing ? "cube.transparent" : "cube",
                text: formatTemplateModelName(model),
                help: modelMissing
                    ? (template.modelPolicy == .always
                        ? L("\(model) is not installed. This template requires it.")
                        : L("\(model) is not installed. Your default model will be used."))
                    : model,
                // A missing model must stay readable; it is the one chip
                // the user needs to act on.
                priority: modelMissing ? 2 : 0,
                isWarning: modelMissing))
        let toolCount = template.agent.tools?.enabled?.count ?? 0
        let groupCount = (template.agent.mcpServers?.enabled?.count ?? 0) + (template.agent.plugins?.enabled?.count ?? 0)
        if template.agent.tools?.mode == "manual" || toolCount + groupCount > 0 {
            chips.append(
                LibraryStat(
                    icon: "wrench.and.screwdriver", text: "\(toolCount + groupCount)",
                    help: L("Custom Tools")))
        }
        if template.agent.sandbox?.enabled == true {
            chips.append(LibraryStat(icon: "shippingbox", text: nil, help: L("Sandbox")))
        }
        if template.agent.subagents?.enabled == true {
            chips.append(LibraryStat(icon: "person.2", text: nil, help: L("Subagents")))
        }
        if !template.requires.isEmpty {
            let text = L("\(template.requires.count) to set up")
            chips.append(LibraryStat(icon: "checklist", text: text, help: text, priority: 2))
        }
        return chips
    }

    /// Last path component of a model id, matching the agent card's
    /// `formatModelName` so "mlx-community/Qwen…" reads as "Qwen…".
    private func formatTemplateModelName(_ model: String) -> String {
        model.split(separator: "/").last.map(String.init) ?? model
    }
}
