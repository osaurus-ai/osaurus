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
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(18, enabled: baseComponentEnabled) }

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
        HStack(alignment: caption == nil ? .center : .top, spacing: theme.space.s8) {
            iconView

            SettingsRowText {
                Text(title)
                    .assignedTypography(caption == nil ? "component.library.18.text" : "component.library.18.label", fallback: SettingsFont.rowTitle)
                    .foregroundColor(caption == nil ? tint : theme.text.primary)
                    .fixedSize(horizontal: false, vertical: true)
            } description: {
                if let caption {
                    Text(caption)
                        .assignedTypography("component.library.18.caption", fallback: SettingsFont.rowDescription)
                        .foregroundColor(theme.text.secondary)
                }
            }

            Spacer(minLength: 8)

            if let secondaryAction {
                Button(action: secondaryAction.handler) {
                    Text(secondaryAction.title)
                }
                .assignedSettingsButtonStyle(.secondary, size: .compact)
            }

            if let action {
                Button(action: action.handler) {
                    HStack(spacing: theme.space.s4) {
                        if let icon = action.icon {
                            Image(systemName: icon)
                                .glyphSize(.footnote, weight: .semibold)
                        }
                        Text(action.title)
                    }
                }
                .assignedSettingsButtonStyle(.primary, size: .compact)
            }

            if let onDismiss {
                SettingsIconButton("xmark", help: "Dismiss", size: .compact, action: onDismiss)
            }
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, kind == .action ? theme.space.s12 : theme.space.s10)
        .frame(maxWidth: .infinity, minHeight: theme.catalogMetric("height", fallback: 0), alignment: .leading)
        .assignedBaseChrome(18)
    }

    @ViewBuilder
    private var iconView: some View {
        if kind == .action {
            ZStack {
                Circle().fill(theme.status.info.background)
                Image(systemName: icon ?? defaultIcon)
                    .glyphSize(.label, weight: .semibold)
                    .foregroundColor(baseComponentEnabled ? theme.border.focus : theme.text.disabled)
            }
            .frame(width: 30, height: 30)
        } else {
            Image(systemName: icon ?? defaultIcon)
                .glyphSize(.caption, weight: .semibold)
                .foregroundColor(tint)
                .padding(.top, caption == nil ? theme.space.s0 : theme.space.s2)
        }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
            .fill(tint.opacity(kind == .action ? 0.06 : 0.08))
            .overlay(
                RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                    .stroke(tint.opacity(kind == .action ? 0.18 : 0.25), lineWidth: theme.stroke.default)
            )
    }

    private var tint: Color {
        switch kind {
        case .error: return theme.status.error.foreground
        case .warning: return theme.status.warning.foreground
        case .info: return theme.text.secondary
        case .success: return theme.status.success.foreground
        case .action: return theme.action.primary.default.background
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
