//
//  LocalModelsTable.swift
//  osaurus
//
//  The Local Models table: one `SettingsDataTable` whose cells render a
//  `LocalModelCatalogItem` the same way for every model kind.
//

import SwiftUI

struct LocalModelsTable: View {
    let columns: [LocalModelColumn]
    let items: [LocalModelCatalogItem]
    @Binding var sort: SettingsDataTableSort<LocalModelSortKey>?
    @Binding var selection: String?
    var isLoading: Bool
    /// Runs a row action, asking first when it carries a confirmation.
    let perform: (LocalModelCatalogItem.Action) -> Void

    var body: some View {
        SettingsDataTable(
            columns: columns.map(\.tableColumn),
            rows: items,
            sort: $sort,
            selection: $selection,
            isLoading: isLoading
        ) { item, column in
            LocalModelCell(item: item, column: LocalModelColumn(rawValue: column.id) ?? .model, perform: perform)
        }
    }
}

private struct LocalModelCell: View {
    @Environment(\.theme) private var theme

    let item: LocalModelCatalogItem
    let column: LocalModelColumn
    let perform: (LocalModelCatalogItem.Action) -> Void

    var body: some View {
        switch column {
        case .model: modelCell
        case .fit: fitCell
        case .memory: metric(item.memoryText)
        case .size: metric(item.sizeText)
        case .released: metric(item.releasedText)
        case .status: LocalModelStatusCell(item: item, perform: perform)
        }
    }

    private var modelCell: some View {
        HStack(spacing: theme.settingsControlGap) {
            Image(systemName: item.icon)
                .glyphSize(13, weight: .medium)
                .foregroundColor(theme.text.tertiary)
                .frame(width: theme.space.s16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: theme.space.s2) {
                HStack(spacing: theme.space.s6) {
                    Text(verbatim: item.name)
                        .font(SettingsFont.rowTitle)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.isTopPick {
                        Image(systemName: "star.fill")
                            .glyphSize(9, weight: .semibold)
                            .foregroundColor(theme.status.warning.foreground)
                            .help(Text("Top Pick", bundle: .module))
                            .accessibilityLabel(Text("Top Pick", bundle: .module))
                    }
                    ForEach(Array(item.badges.enumerated()), id: \.offset) { _, badge in
                        StatusChip(badge.text, tone: badge.tone, icon: badge.icon, help: badge.help)
                            .fixedSize()
                    }
                }
                if !item.subtitle.isEmpty {
                    Text(verbatim: item.subtitle)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .saturation(item.isUnsupported ? 0 : 1)
        .opacity(item.isUnsupported ? 0.6 : 1)
    }

    @ViewBuilder
    private var fitCell: some View {
        if let fit = item.fit {
            StatusChip(fit.shortName, tone: fit.tone, showsDot: true, help: fit.displayName)
                .fixedSize()
        } else {
            placeholder
        }
    }

    @ViewBuilder
    private func metric(_ value: String?) -> some View {
        if let value {
            Text(verbatim: value)
                .font(SettingsFont.caption.monospacedDigit())
                .foregroundColor(theme.text.secondary)
                .lineLimit(1)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Text(verbatim: "—")
            .font(SettingsFont.caption)
            .foregroundColor(theme.text.tertiary)
            .accessibilityLabel(Text("Unknown", bundle: .module))
    }
}

/// Download progress, the row's main action, and its overflow menu.
struct LocalModelStatusCell: View {
    @Environment(\.theme) private var theme

    let item: LocalModelCatalogItem
    let perform: (LocalModelCatalogItem.Action) -> Void

    var body: some View {
        HStack(spacing: theme.space.s6) {
            switch item.status {
            case .inProgress(let progress, let detail, let isPaused):
                progressView(progress: progress, detail: detail, isPaused: isPaused)
            case .failed(let message):
                StatusChip(L("Failed"), tone: .error, icon: "exclamationmark.triangle.fill", help: message)
                    .fixedSize()
                primaryButton
            case .installed:
                if let action = item.primaryAction {
                    actionButton(action)
                } else if item.isDefault {
                    StatusChip(L("Default"), tone: .accent, icon: "checkmark")
                        .fixedSize()
                } else {
                    HStack(spacing: theme.space.s4) {
                        Image(systemName: "checkmark.circle.fill")
                            .glyphSize(11)
                            .foregroundColor(theme.status.success.foreground)
                        Text("On this Mac", bundle: .module)
                            .font(SettingsFont.caption)
                            .foregroundColor(theme.text.secondary)
                            .lineLimit(1)
                    }
                    .fixedSize()
                }
            case .available:
                primaryButton
            }
            if !item.menuActions.isEmpty, !item.status.isActive {
                SettingsOverflowMenu(help: "More actions", size: .compact) {
                    ForEach(item.menuActions) { action in
                        Button(role: action.role == .destructive ? .destructive : nil) {
                            perform(action)
                        } label: {
                            Label {
                                Text(LocalizedStringKey(action.title), bundle: .module)
                            } icon: {
                                Image(systemName: action.icon)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if let action = item.primaryAction {
            actionButton(action)
        }
    }

    private func actionButton(_ action: LocalModelCatalogItem.Action) -> some View {
        SettingsButton(
            action.role == .primary ? .secondary : action.role == .destructive ? .destructive : .tertiary,
            action.title,
            icon: action.icon,
            size: .compact
        ) {
            perform(action)
        }
        .fixedSize()
    }

    private func progressView(progress: Double?, detail: String?, isPaused: Bool) -> some View {
        HStack(spacing: theme.space.s6) {
            VStack(alignment: .trailing, spacing: theme.space.s2) {
                if let progress {
                    SettingsProgressBar(value: progress, tint: isPaused ? theme.text.tertiary : nil)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(verbatim: progressLabel(progress: progress, isPaused: isPaused))
                    .font(SettingsFont.caption.monospacedDigit())
                    .foregroundColor(theme.text.tertiary)
                    .lineLimit(1)
                    .help(detail.map { Text(verbatim: $0) } ?? Text(verbatim: ""))
            }
            if let onResume = item.onResume {
                SettingsIconButton("play.fill", help: "Resume", size: .compact, action: onResume)
            } else if let onPause = item.onPause {
                SettingsIconButton("pause.fill", help: "Pause", size: .compact, action: onPause)
            }
            if let onCancel = item.onCancel {
                SettingsIconButton("xmark", help: "Cancel", size: .compact, isDestructive: true, action: onCancel)
            }
        }
    }

    private func progressLabel(progress: Double?, isPaused: Bool) -> String {
        if isPaused { return L("Paused") }
        guard let progress else { return L("Preparing…") }
        return "\(Int((progress * 100).rounded()))%"
    }
}

extension ModelCompatibility {
    /// Fits in a table cell; `displayName` is the tooltip.
    var shortName: String {
        switch self {
        case .compatible: L("Runs well")
        case .tight: L("Tight fit")
        case .tooLarge: L("Too large")
        case .unknown: L("Unknown")
        }
    }

    var tone: StatusChip.Tone {
        switch self {
        case .compatible: .success
        case .tight: .warning
        case .tooLarge: .error
        case .unknown: .neutral
        }
    }
}
