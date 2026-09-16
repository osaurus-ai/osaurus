//
//  AgentTemplateCard.swift
//  osaurus
//
//  One card in the Templates tab. Mirrors `AgentCard` so the two grids
//  read as siblings: avatar circle, name + summary, prompt preview, a stat
//  row, and an overflow menu with the library actions.
//

import SwiftUI

struct AgentTemplateCard: View {
    @Environment(\.theme) private var theme

    let template: AgentTemplate
    let isBuiltIn: Bool
    /// False when the template pins a model this Mac does not have; the
    /// model chip turns warning-coloured so the gap shows before Use.
    var modelAvailable: Bool = true
    let animationDelay: Double
    let hasAppeared: Bool
    let onUse: () -> Void
    let onCopyJSON: () -> Void
    /// Puts an `osaurus://templates-import` link on the clipboard.
    var onCopyShareLink: () -> Void = {}
    let onExportFile: () -> Void
    let onToggleOrchestrator: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    /// Built-ins only: copy into the user library so it can be edited.
    var onSaveToLibrary: (() -> Void)? = nil

    @State private var isHovered = false
    @State private var showDeleteConfirm = false

    private var accent: Color { agentColorFor(template.name) }

    var body: some View {
        Button(action: onUse) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    avatar
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(template.name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                                .lineLimit(1)
                                .layoutPriority(1)
                            if isBuiltIn {
                                badge(L("Built-in"), color: theme.infoColor)
                            }
                            if template.availableToOrchestrator {
                                // Icon-only so the name keeps its room; the
                                // menu spells out the state.
                                Image(systemName: "sparkles")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(theme.accentColor)
                                    .help(L("Visible to the Orchestrator"))
                            }
                        }
                        Text(
                            (template.summary?.isEmpty ?? true) ? L("No description") : (template.summary ?? "")
                        )
                        .font(.system(size: 11))
                        .foregroundColor(
                            (template.summary?.isEmpty ?? true) ? theme.tertiaryText : theme.secondaryText
                        )
                        .lineLimit(1)
                        .truncationMode(.tail)
                    }
                    Spacer(minLength: 8)
                    menu
                }

                if let prompt = template.agent.systemPrompt, !prompt.isEmpty {
                    Text(prompt)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(2)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("No system prompt", bundle: .module)
                        .font(.system(size: 12).italic())
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 0)
                stats
            }
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .top)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovered ? theme.cardBackground.opacity(0.9) : theme.cardBackground)
            )
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                    .padding(12)
                    .opacity(isHovered ? 1 : 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isHovered ? theme.accentColor.opacity(0.35) : theme.cardBorder, lineWidth: 1)
            )
            .shadow(
                color: Color.black.opacity(isHovered ? 0.08 : 0.04),
                radius: isHovered ? 10 : 5, x: 0, y: isHovered ? 3 : 2
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 20)
        .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(animationDelay), value: hasAppeared)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .help(L("Create an agent from this template"))
        .themedAlert(
            L("Delete Template"),
            isPresented: $showDeleteConfirm,
            message: L("Delete the template \"\(template.name)\"? Agents already created from it are not affected."),
            primaryButton: .destructive(L("Delete"), action: onDelete),
            secondaryButton: .cancel(L("Cancel"))
        )
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(accent.opacity(0.15))
                .frame(width: 40, height: 40)
            Circle()
                .stroke(accent.opacity(0.35), lineWidth: 1)
                .frame(width: 40, height: 40)
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(accent)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private var menu: some View {
        Menu {
            Button(action: onUse) {
                Label { Text("Use Template", bundle: .module) } icon: { Image(systemName: "plus.circle") }
            }
            Button(action: onCopyJSON) {
                Label { Text("Copy JSON", bundle: .module) } icon: { Image(systemName: "doc.on.clipboard") }
            }
            Button(action: onCopyShareLink) {
                Label { Text("Copy Share Link", bundle: .module) } icon: { Image(systemName: "link") }
            }
            Button(action: onExportFile) {
                Label { Text("Export File…", bundle: .module) } icon: { Image(systemName: "square.and.arrow.up") }
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
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .frame(width: 24, height: 24)
                .background(Circle().fill(theme.tertiaryBackground))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24)
    }

    // MARK: - Stats

    /// Same rhythm as `AgentCard`: model, tool count, then icon-only
    /// markers for sandbox / subagents so the row never truncates at the
    /// default window width. The setup count keeps its text because it is
    /// the one thing a user must act on.
    private var stats: some View {
        HStack(spacing: 0) {
            let chips = statChips
            ForEach(Array(chips.enumerated()), id: \.offset) { index, chip in
                if index > 0 {
                    Circle().fill(theme.tertiaryText.opacity(0.4)).frame(width: 3, height: 3)
                        .padding(.horizontal, 8)
                }
                HStack(spacing: 4) {
                    Image(systemName: chip.icon)
                        .font(.system(size: 9, weight: .medium))
                    if let text = chip.text {
                        Text(text)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .layoutPriority(chip.priority)
                .foregroundColor(chip.isWarning ? theme.warningColor : theme.tertiaryText)
                .help(chip.help)
            }
            Spacer(minLength: 0)
        }
    }

    private struct StatChip {
        let icon: String
        let text: String?
        let help: String
        /// Higher wins when the row is tight; the model name gives way first.
        var priority: Double = 1
        var isWarning: Bool = false
    }

    private var statChips: [StatChip] {
        var chips: [StatChip] = []
        let model = template.agent.model.valueOrNil ?? L("Default")
        let modelMissing = template.agent.model.valueOrNil != nil && !modelAvailable
        chips.append(
            StatChip(
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
                StatChip(
                    icon: "wrench.and.screwdriver", text: "\(toolCount + groupCount)",
                    help: L("Custom Tools")))
        }
        if template.agent.sandbox?.enabled == true {
            chips.append(StatChip(icon: "shippingbox", text: nil, help: L("Sandbox")))
        }
        if template.agent.subagents?.enabled == true {
            chips.append(StatChip(icon: "person.2", text: nil, help: L("Subagents")))
        }
        if !template.requires.isEmpty {
            let text = L("\(template.requires.count) to set up")
            chips.append(StatChip(icon: "checklist", text: text, help: text, priority: 2))
        }
        return chips
    }

    /// Last path component of a model id, matching the agent card's
    /// `formatModelName` so "mlx-community/Qwen…" reads as "Qwen…".
    private func formatTemplateModelName(_ model: String) -> String {
        model.split(separator: "/").last.map(String.init) ?? model
    }
}
