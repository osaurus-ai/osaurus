//
//  ToastView.swift
//  osaurus
//
//  Individual toast notification view with themed styling, icons,
//  avatar support, and smooth animations.
//

import SwiftUI

// MARK: - Toast View

/// A single toast notification card
struct ToastView: View {
    @Environment(\.theme) private var theme
    let toast: Toast
    let onDismiss: () -> Void
    let onAction: (() -> Void)?

    @State private var isHovering = false

    init(toast: Toast, onDismiss: @escaping () -> Void, onAction: (() -> Void)? = nil) {
        self.toast = toast
        self.onDismiss = onDismiss
        self.onAction = onAction
    }

    var body: some View {
        HStack(spacing: 0) {
            // Type indicator bar
            accentBar

            // Content
            HStack(spacing: 12) {
                // Avatar or icon
                leadingContent

                // Text content
                textContent

                Spacer(minLength: 8)

                // Action button or dismiss
                trailingContent
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(toastBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.cardBorder, lineWidth: 1)
        )
        .shadow(
            color: theme.shadowColor.opacity(theme.shadowOpacity),
            radius: isHovering ? 12 : 8,
            x: 0,
            y: isHovering ? 4 : 2
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
        .frame(maxWidth: 380, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Accent Bar

    private var accentBar: some View {
        Rectangle()
            .fill(accentColor)
            .frame(width: 4)
    }

    // MARK: - Leading Content (Icon or Avatar)

    @ViewBuilder
    private var leadingContent: some View {
        if let avatarImage = toast.avatarImage {
            // Persona avatar
            Image(nsImage: avatarImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 36, height: 36)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(accentColor.opacity(0.5), lineWidth: 2)
                )
        } else {
            // Type icon
            iconView
        }
    }

    @ViewBuilder
    private var iconView: some View {
        ZStack {
            Circle()
                .fill(accentColor.opacity(0.15))
                .frame(width: 32, height: 32)

            if toast.type == .loading {
                // Spinning indicator for loading
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: accentColor))
                    .scaleEffect(0.7)
            } else {
                Image(systemName: toast.type.iconName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(accentColor)
            }
        }
    }

    // MARK: - Text Content

    private var textContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(toast.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .lineLimit(2)

            if let message = toast.message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(3)
            }

            // Progress bar for loading toasts
            if toast.type == .loading, let progress = toast.progress {
                ProgressView(value: progress)
                    .progressViewStyle(ToastProgressStyle(color: accentColor))
                    .frame(height: 4)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Trailing Content (Action/Dismiss)

    @ViewBuilder
    private var trailingContent: some View {
        HStack(spacing: 8) {
            // Action button (supports both legacy actionTitle and new ToastAction)
            if let actionTitle = toast.effectiveActionTitle, hasAction {
                Button(action: { onAction?() }) {
                    Text(actionTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(accentColor.opacity(0.15))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(accentColor.opacity(0.3), lineWidth: 1)
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }

            // Dismiss button (shown on hover or for non-loading toasts)
            if isHovering || toast.type != .loading {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                        .frame(width: 20, height: 20)
                        .background(
                            Circle()
                                .fill(theme.tertiaryBackground)
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .opacity(isHovering ? 1 : 0.6)
                .transition(.opacity)
            }
        }
    }

    /// Whether this toast has an action (either legacy or new style)
    private var hasAction: Bool {
        toast.type == .action || toast.action != nil || toast.actionId != nil
    }

    // MARK: - Background

    private var toastBackground: some View {
        theme.cardBackground
    }

    // MARK: - Accent Color

    private var accentColor: Color {
        switch toast.type {
        case .success:
            return theme.successColor
        case .info:
            return theme.infoColor
        case .warning:
            return theme.warningColor
        case .error:
            return theme.errorColor
        case .action, .loading:
            return theme.accentColor
        }
    }
}

// MARK: - Toast Progress Style

private struct ToastProgressStyle: ProgressViewStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color.opacity(0.2))
                    .frame(height: 4)

                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: geometry.size.width * (configuration.fractionCompleted ?? 0), height: 4)
                    .animation(.easeInOut(duration: 0.3), value: configuration.fractionCompleted)
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Preview

#if DEBUG
    struct ToastView_Previews: PreviewProvider {
        static var previews: some View {
            VStack(spacing: 16) {
                ToastView(
                    toast: Toast(
                        type: .success,
                        title: "Task completed",
                        message: "Your file has been processed successfully"
                    ),
                    onDismiss: {}
                )

                ToastView(
                    toast: Toast(type: .error, title: "Connection failed", message: "Unable to connect to the server"),
                    onDismiss: {}
                )

                ToastView(
                    toast: Toast(type: .loading, title: "Processing...", message: "Please wait", progress: 0.6),
                    onDismiss: {}
                )

                ToastView(
                    toast: Toast(
                        type: .action,
                        title: "Update available",
                        message: "A new version is ready to install",
                        actionTitle: "Install",
                        actionId: "install"
                    ),
                    onDismiss: {},
                    onAction: {}
                )
            }
            .padding()
            .frame(width: 420)
            .background(Color.black.opacity(0.8))
        }
    }
#endif
