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

            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(title)
                    #if OSAURUS_DESIGN_SYSTEM
                    .assignedTypography(caption == nil ? "component.library.18.text" : "component.library.18.label", fallback: SettingsFont.rowTitle)
                    #else
                    .textStyle(caption == nil ? .caption : .label)
                    #endif
                    .foregroundColor(caption == nil ? tint : theme.text.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let caption {
                    Text(caption)
                        .assignedTypography("component.library.18.caption", fallback: SettingsFont.rowDescription)
                        .foregroundColor(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                    HStack(spacing: 5) {
                        if let icon = action.icon {
                            Image(systemName: icon)
                                .glyphSize(10.5, weight: .semibold)
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
        .padding(.vertical, kind == .action ? 12 : 10)
        .frame(maxWidth: .infinity, minHeight: theme.catalogMetric("height", fallback: 0), alignment: .leading)
        #if OSAURUS_DESIGN_SYSTEM
        .assignedBaseChrome(18)
        #else
        .background(background)
        #endif
    }

    @ViewBuilder
    private var iconView: some View {
        if kind == .action {
            ZStack {
                Circle().fill(theme.status.info.background)
                Image(systemName: icon ?? defaultIcon)
                    .glyphSize(13, weight: .semibold)
                    #if OSAURUS_DESIGN_SYSTEM
                    .foregroundColor(baseComponentEnabled ? theme.border.focus : theme.text.disabled)
                    #else
                    .foregroundColor(theme.text.link)
                    #endif
            }
            .frame(width: 30, height: 30)
        } else {
            Image(systemName: icon ?? defaultIcon)
                .glyphSize(12, weight: .semibold)
                .foregroundColor(tint)
                .padding(.top, caption == nil ? 0 : 1)
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
