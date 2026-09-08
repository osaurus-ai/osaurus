//
//  InlineBanner.swift
//  osaurus
//
//  Dismissible inline notice used at the top of a settings pane or sheet
//  body: an error the user should read before continuing, a pending action
//  that needs a decision, or a one-line success confirmation. One recipe
//  (icon · text · optional action · optional dismiss) so Workspaces, Identity,
//  and Agents banners read alike.
//

import SwiftUI

struct InlineBanner: View {
    @Environment(\.theme) private var theme

    enum Kind {
        case error
        case warning
        case info
        case success
        /// Accent-washed prompt for a staged action (invite ready, activation
        /// ready) — carries an action button.
        case action
    }

    struct Action {
        /// Already-localized title.
        let title: String
        var icon: String?
        let handler: () -> Void
    }

    let kind: Kind
    /// Already-localized headline. When `caption` is nil this is the whole
    /// banner text; otherwise it renders semibold above the caption.
    let title: String
    /// Already-localized second line.
    var caption: String?
    var icon: String?
    var action: Action?
    /// Secondary quiet button (e.g. "Discard" beside "Join").
    var secondaryAction: Action?
    var onDismiss: (() -> Void)?

    init(
        kind: Kind,
        title: String,
        caption: String? = nil,
        icon: String? = nil,
        action: Action? = nil,
        secondaryAction: Action? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.kind = kind
        self.title = title
        self.caption = caption
        self.icon = icon
        self.action = action
        self.secondaryAction = secondaryAction
        self.onDismiss = onDismiss
    }

    var body: some View {
        HStack(alignment: caption == nil ? .center : .top, spacing: 10) {
            iconView

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: caption == nil ? 12 : 13, weight: caption == nil ? .medium : .semibold))
                    .foregroundColor(caption == nil ? tint : theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let caption {
                    Text(caption)
                        .font(.system(size: 11.5))
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if let secondaryAction {
                Button(action: secondaryAction.handler) {
                    Text(secondaryAction.title)
                }
                .buttonStyle(SecondaryButtonStyle(size: .compact))
            }

            if let action {
                Button(action: action.handler) {
                    HStack(spacing: 5) {
                        if let icon = action.icon {
                            Image(systemName: icon)
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        Text(action.title)
                    }
                }
                .buttonStyle(PrimaryButtonStyle(size: .compact))
            }

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(tint.opacity(0.7))
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Dismiss"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, kind == .action ? 12 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    @ViewBuilder
    private var iconView: some View {
        if kind == .action {
            ZStack {
                Circle().fill(theme.accentColor.opacity(0.12))
                Image(systemName: icon ?? defaultIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.accentColor)
            }
            .frame(width: 30, height: 30)
        } else {
            Image(systemName: icon ?? defaultIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(tint)
                .padding(.top, caption == nil ? 0 : 1)
        }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(tint.opacity(kind == .action ? 0.06 : 0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(tint.opacity(kind == .action ? 0.18 : 0.25), lineWidth: 1)
            )
    }

    private var tint: Color {
        switch kind {
        case .error: return theme.errorColor
        case .warning: return theme.warningColor
        case .info: return theme.secondaryText
        case .success: return theme.successColor
        case .action: return theme.accentColor
        }
    }

    private var defaultIcon: String {
        switch kind {
        case .error: return "exclamationmark.triangle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .action: return "sparkles"
        }
    }
}
