//
//  TemplateVersionHistorySheet.swift
//  osaurus
//
//  Every stored version of one template, newest first, with what changed
//  from the version before it. Restoring saves the old version as the
//  newest; history is never rewritten. Shared by agent and workflow
//  templates.
//

import SwiftUI

struct TemplateVersionHistorySheet: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var store = TemplateStore.shared

    let templateID: UUID
    let onDone: () -> Void

    @State private var selected: Int?
    @State private var expanded: Set<String> = []
    @State private var errorMessage: String?

    private var versions: [Template] { store.versions(of: templateID) }

    var body: some View {
        let all = versions
        let current = all.first { $0.version == selected } ?? all.first
        VStack(spacing: 0) {
            SettingsSheetHeader(
                icon: "clock.arrow.circlepath", title: "Version History", subtitleText: all.first?.name,
                onClose: onDone)
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(all, id: \.version) { version in
                            versionRow(version, isSelected: version.version == current?.version, isLatest: version.version == all.first?.version)
                        }
                    }
                    .padding(theme.space.s12)
                }
                .frame(width: 220)
                .background(theme.surface.subtle)
                Divider()
                ScrollView {
                    if let current {
                        detail(current, previous: all.first { $0.version < current.version }, isLatest: current.version == all.first?.version)
                            .padding(theme.space.s16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            SettingsSheetFooter(
                primary: SettingsSheetFooter.Action(label: "Done", handler: onDone),
                secondary: nil,
                hint: nil,
                warning: errorMessage
            )
        }
        .fittedSheetFrame(width: 780, height: 560)
        .settingsSheetSurface()
        .overlay(RoundedRectangle(cornerRadius: theme.radius.xlarge).stroke(theme.border.subtle, lineWidth: theme.stroke.default))
    }

    private func versionRow(_ template: Template, isSelected: Bool, isLatest: Bool) -> some View {
        Button {
            selected = template.version
            expanded = []
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("v\(template.version)")
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(isSelected ? theme.text.primary : theme.text.secondary)
                    if isLatest {
                        StatusChip(L("Current"), tone: .accent)
                    }
                    Spacer()
                }
                Text(template.changelog.isEmpty ? L("No notes") : template.changelog)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                    .lineLimit(2)
                Text(template.createdAt, style: .date)
                    .font(SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
            }
            .padding(.horizontal, theme.space.s8)
            .padding(.vertical, theme.space.s8)
            .settingsChrome(isSelected ? .selected : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func detail(_ template: Template, previous: Template?, isLatest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Version \(template.version)", bundle: .module)
                    .font(SettingsFont.detailTitle)
                    .foregroundColor(theme.text.primary)
                Spacer()
                if !isLatest {
                    Button {
                        restore(template)
                    } label: {
                        Text("Restore This Version", bundle: .module)
                    }
                    .assignedSettingsButtonStyle(.secondary)
                }
            }
            if !template.changelog.isEmpty {
                Text(template.changelog)
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let previous {
                let changes = TemplateDiff.changes(from: previous, to: template)
                Text("Changes from version \(previous.version)", bundle: .module)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.tertiary)
                if changes.isEmpty {
                    Text("No content changes.", bundle: .module)
                        .font(SettingsFont.caption)
                        .foregroundColor(theme.text.tertiary)
                } else {
                    ForEach(changes) { change in changeRow(change) }
                }
            } else {
                Text("First version.", bundle: .module)
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.tertiary)
            }
        }
    }

    private func changeRow(_ change: WorkflowDiff.Change) -> some View {
        let isOpen = expanded.contains(change.id)
        let color: Color = {
            switch change.kind {
            case .added: return theme.status.success.foreground
            case .removed: return theme.status.error.foreground
            case .changed: return theme.status.warning.foreground
            }
        }()
        let hasDetail = change.before != nil || change.after != nil
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                if isOpen { expanded.remove(change.id) } else { expanded.insert(change.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: change.kind == .added ? "plus" : change.kind == .removed ? "minus" : "pencil")
                        .glyphSize(10, weight: .bold)
                        .foregroundColor(color)
                        .frame(width: 14)
                    Text(change.line)
                        .font(SettingsFont.caption)
                        .foregroundColor(theme.text.primary)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    if hasDetail {
                        Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                            .glyphSize(9, weight: .semibold)
                            .foregroundColor(theme.text.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasDetail)
            if isOpen {
                HStack(alignment: .top, spacing: 10) {
                    if let before = change.before { codeBlock(L("Before"), before) }
                    if let after = change.after { codeBlock(L("After"), after) }
                }
            }
        }
        .padding(theme.space.s8)
        .settingsChrome(.inset)
    }

    private func codeBlock(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(SettingsFont.chip)
                .foregroundColor(theme.text.tertiary)
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.secondary)
                    .textSelection(.enabled)
                    .fixedSize()
            }
            .frame(maxHeight: 200)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func restore(_ template: Template) {
        do {
            let restored = try store.restore(id: template.id, version: template.version)
            selected = restored.version
            errorMessage = nil
            _ = ToastManager.shared.success(L("Restored version \(template.version) as version \(restored.version)"))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
