//
//  LocalModelInspector.swift
//  osaurus
//
//  The detail panel beside the Local Models table. MLX models (Language,
//  AppleScript) open the full `ModelDetailView`; the other kinds show their
//  row's facts and actions.
//

import AppKit
import SwiftUI

struct LocalModelInspector: View {
    let item: LocalModelCatalogItem
    /// A specific build to show instead of the row's representative (a deep
    /// link to one precision of a family).
    var model: MLXModel?
    let onClose: () -> Void
    let perform: (LocalModelCatalogItem.Action) -> Void

    var body: some View {
        if let model = model ?? item.model {
            ModelDetailView(model: model, variants: item.variants, onClose: onClose)
                .id(model.id)
        } else {
            LocalModelFactsInspector(item: item, onClose: onClose, perform: perform)
        }
    }
}

private struct LocalModelFactsInspector: View {
    @Environment(\.theme) private var theme

    let item: LocalModelCatalogItem
    let onClose: () -> Void
    let perform: (LocalModelCatalogItem.Action) -> Void

    var body: some View {
        VStack(spacing: theme.space.s0) {
            header
            ThemeHairlineDivider(color: theme.border.default)
            ScrollView {
                VStack(alignment: .leading, spacing: theme.space.s16) {
                    if hasChips {
                        FlowLayout(spacing: theme.space.s6) {
                            if let fit = item.fit {
                                StatusChip(fit.displayName, tone: fit.tone, showsDot: true)
                            }
                            if item.isTopPick {
                                StatusChip(L("Top Pick"), tone: .warning, icon: "star.fill")
                            }
                            ForEach(Array(item.badges.enumerated()), id: \.offset) { _, badge in
                                StatusChip(badge.text, tone: badge.tone, icon: badge.icon, help: badge.help)
                            }
                        }
                    }
                    if !item.description.isEmpty {
                        Text(verbatim: item.description)
                            .font(SettingsFont.body)
                            .foregroundColor(theme.text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if !item.facts.isEmpty {
                        facts
                    }
                }
                .padding(theme.space.s16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ThemeHairlineDivider(color: theme.border.default)
            footer
                .padding(theme.space.s16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.canvas)
    }

    private var hasChips: Bool {
        item.fit != nil || item.isTopPick || !item.badges.isEmpty
    }

    private var header: some View {
        HStack(spacing: theme.settingsControlGap) {
            SettingsIconTile(icon: item.icon)
            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(verbatim: item.name)
                    .font(SettingsFont.detailTitle)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(2)
                if !item.subtitle.isEmpty {
                    Text(verbatim: item.subtitle)
                        .font(SettingsFont.caption)
                        .foregroundColor(theme.text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: theme.space.s8)
            if let repo = item.huggingFaceRepo, let url = LocalModelCatalogFormat.huggingFaceURL(repo) {
                SettingsIconButton("arrow.up.right.square", help: "View on Hugging Face", size: .compact) {
                    NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
                }
            }
            SettingsIconButton("xmark", help: "Close", size: .compact, action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, theme.space.s16)
        .padding(.vertical, theme.space.s12)
    }

    private var facts: some View {
        VStack(spacing: theme.space.s0) {
            ForEach(Array(item.facts.enumerated()), id: \.element.id) { index, fact in
                if index > 0 { SettingsGroupDivider() }
                HStack(alignment: .firstTextBaseline, spacing: theme.settingsInlineGap) {
                    Text(LocalizedStringKey(fact.label), bundle: .module)
                        .font(SettingsFont.caption)
                        .foregroundColor(theme.text.tertiary)
                    Spacer(minLength: theme.space.s8)
                    Text(verbatim: fact.value)
                        .font(SettingsFont.caption)
                        .foregroundColor(theme.text.primary)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, theme.space.s12)
                .padding(.vertical, theme.space.s8)
            }
        }
        .settingsChrome(.surface)
    }

    @ViewBuilder
    private var footer: some View {
        switch item.status {
        case .inProgress(let progress, let detail, let isPaused):
            VStack(alignment: .leading, spacing: theme.space.s8) {
                if let progress {
                    SettingsProgressBar(value: progress, tint: isPaused ? theme.text.tertiary : nil, height: 6)
                } else {
                    SettingsSpinner()
                }
                HStack(spacing: theme.settingsControlGap) {
                    Text(verbatim: progressLine(progress: progress, detail: detail, isPaused: isPaused))
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.secondary)
                        .lineLimit(1)
                    Spacer()
                    if let onResume = item.onResume {
                        SettingsButton(.secondary, "Resume", size: .compact, action: onResume)
                    } else if let onPause = item.onPause {
                        SettingsButton(.secondary, "Pause", size: .compact, action: onPause)
                    }
                    if let onCancel = item.onCancel {
                        SettingsButton(.destructive, "Cancel", size: .compact, action: onCancel)
                    }
                }
            }
        default:
            VStack(alignment: .leading, spacing: theme.space.s8) {
                if case .failed(let message) = item.status {
                    Text(verbatim: message)
                        .font(SettingsFont.caption)
                        .foregroundColor(theme.status.error.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                HStack(spacing: theme.settingsControlGap) {
                    ForEach(item.menuActions) { action in
                        SettingsButton(
                            action.role == .destructive ? .destructive : .secondary,
                            action.title,
                            icon: action.icon,
                            size: .compact
                        ) { perform(action) }
                    }
                    Spacer(minLength: 0)
                    if item.isDefault, item.status == .installed {
                        StatusChip(L("Default"), tone: .accent, icon: "checkmark")
                    }
                    if let action = item.primaryAction {
                        SettingsButton(.primary, action.title, icon: action.icon, size: .compact) { perform(action) }
                    }
                }
            }
        }
    }

    private func progressLine(progress: Double?, detail: String?, isPaused: Bool) -> String {
        if isPaused { return L("Paused") }
        guard let progress else { return detail ?? L("Preparing…") }
        let percent = "\(Int((progress * 100).rounded()))%"
        return detail.map { "\(percent) · \($0)" } ?? percent
    }
}
