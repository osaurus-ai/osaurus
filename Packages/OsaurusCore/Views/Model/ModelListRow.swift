//
//  ModelListRow.swift
//  osaurus
//
//  The single, shared list row used by every feature "Models" tab (Voice,
//  Privacy, Images — and the future Computer Use tab). Generalized from the
//  Image tab's row so each downloadable-model surface renders identically:
//  a 32pt leading icon, a title with badges, a subtitle or live download
//  progress, an always-visible "View on Hugging Face" link, a primary action
//  (Download / Install / Set as Default / Generate / …), and an overflow menu
//  for the heavier actions (Delete / Remove / Re-verify / Re-download).
//
//  Sits on the shared 10pt input-card chrome (the same surface `SettingsToggle`
//  uses) and is grouped by callers under `SettingsSection` "Installed" /
//  "Available". Presentation-only: each feature maps its own download manager
//  state into `ModelListRow.Status` and supplies the actions, so the row stays
//  decoupled from any specific download service.
//

import SwiftUI

// MARK: - Model Badge

/// The one pill used by every model row — replaces the previously divergent
/// per-tab capsules ("EN", "Default", "Installed", quant chips, kind chips).
/// Callers pass already-localized text (mirroring the rest of the row), so the
/// label renders verbatim.
struct ModelBadge: View {
    @Environment(\.theme) private var theme

    enum Style { case neutral, accent, success, warning }

    struct Item {
        let text: String
        var icon: String? = nil
        var style: Style = .neutral
    }

    let item: Item

    private var tint: Color {
        switch item.style {
        case .neutral: return theme.secondaryText
        case .accent: return theme.accentColor
        case .success: return theme.successColor
        case .warning: return theme.warningColor
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            if let icon = item.icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(verbatim: item.text)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.12)))
        .overlay(Capsule().stroke(tint.opacity(0.22), lineWidth: 0.5))
    }
}

// MARK: - Model List Row

struct ModelListRow: View {
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

    /// Normalized download lifecycle. `inProgress(progress: nil, …)` renders an
    /// indeterminate spinner + detail (for phases like verify/enumerate that
    /// have no fraction); a non-nil progress renders the linear bar + percent.
    enum Status {
        case idle
        case inProgress(progress: Double?, detail: String?)
        case ready
        case failed(String)
    }

    let title: String
    let subtitle: String
    let leading: Leading
    var badges: [ModelBadge.Item] = []
    /// When true the row shows a success "Default" badge and an accent border —
    /// the single, unified "this model is the active choice" treatment shared
    /// by every Models tab.
    var isDefault: Bool = false
    let status: Status
    var primary: Action? = nil
    var menuItems: [Action] = []
    /// Always-visible inline "View on Hugging Face" link (when the source repo
    /// is known). Pulled out of the overflow menu so it stays reachable while a
    /// download is in flight and isn't the lone item behind a 3-dot affordance.
    var onViewHuggingFace: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil

    private var isActive: Bool {
        if case .inProgress = status { return true }
        return false
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
                        .stroke(
                            isDefault ? theme.accentColor : theme.inputBorder,
                            lineWidth: isDefault ? 1.5 : 1
                        )
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
            if isDefault {
                ModelBadge(item: ModelBadge.Item(text: L("Default"), style: .success))
            }
            ForEach(badges.indices, id: \.self) { index in
                ModelBadge(item: badges[index])
            }
        }
    }

    @ViewBuilder
    private var progressRow: some View {
        if case let .inProgress(progress, detail) = status {
            if let progress {
                VStack(alignment: .leading, spacing: 4) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(theme.tertiaryBackground)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(theme.accentColor)
                                .frame(width: max(0, geo.size.width * progress))
                                .animation(.easeOut(duration: 0.3), value: progress)
                        }
                    }
                    .frame(height: 4)

                    HStack(spacing: 6) {
                        Text(verbatim: "\(Int(progress * 100))%")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(theme.secondaryText)
                        if let detail {
                            Text(verbatim: "·").foregroundColor(theme.tertiaryText)
                            Text(verbatim: detail)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(theme.tertiaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: detail ?? L("Loading…"))
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
            }
        }
    }

    private var trailing: some View {
        // The Hugging Face link renders first in both states so it never
        // disappears mid-download. Active downloads then show Cancel; idle rows
        // show the primary action plus an overflow menu only when items remain.
        HStack(spacing: 8) {
            if let onViewHuggingFace {
                huggingFaceButton(onViewHuggingFace)
            }

            if isActive {
                if let onCancel {
                    Button(action: onCancel) {
                        Text("Cancel", bundle: .module)
                    }
                    .buttonStyle(SettingsButtonStyle())
                }
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
