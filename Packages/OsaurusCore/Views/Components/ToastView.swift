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
        HStack(alignment: .top, spacing: 12) {
            leadingContent

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    textContent
                    Spacer(minLength: 4)
                    dismissButton
                }

                if let actionTitle = toast.effectiveActionTitle, hasAction {
                    actionButton(title: actionTitle)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(ToastBackground(accentColor: accentColor))
        .clipShape(RoundedRectangle(cornerRadius: ToastStyle.cornerRadius, style: .continuous))
        .overlay(ToastBorder(accentColor: accentColor, isHovering: isHovering))
        .toastShadow(theme: theme, isHovering: isHovering)
        .onHover { hovering in
            withAnimation(theme.animationQuick()) {
                isHovering = hovering
            }
        }
        .frame(maxWidth: 400, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Leading Content

    @ViewBuilder
    private var leadingContent: some View {
        if let avatarImage = toast.avatarImage {
            Image(nsImage: avatarImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 36, height: 36)
                .clipShape(Circle())
                .overlay(Circle().stroke(accentColor.opacity(0.5), lineWidth: 2))
        } else {
            iconView
        }
    }

    @ViewBuilder
    private var iconView: some View {
        ZStack {
            Circle()
                .fill(accentColor.opacity(theme.isDark ? 0.14 : 0.10))
                .frame(width: 28, height: 28)

            if toast.type == .loading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: accentColor))
                    .scaleEffect(0.6)
            } else {
                Image(systemName: toast.type.iconName)
                    .font(.system(size: 14, weight: .semibold))
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

            if toast.type == .loading, let progress = toast.progress {
                ProgressView(value: progress)
                    .progressViewStyle(ToastProgressStyle(color: accentColor))
                    .frame(height: 4)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private func actionButton(title: String) -> some View {
        Button(action: { onAction?() }) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(accentColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(accentColor.opacity(0.15)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(accentColor.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var dismissButton: some View {
        if isHovering || toast.type != .loading {
            ToastDismissButton(isHovering: isHovering, action: onDismiss)
                .transition(.opacity)
        }
    }

    // MARK: - Helpers

    private var hasAction: Bool {
        toast.type == .action || toast.action != nil || toast.actionId != nil
    }

    private var accentColor: Color {
        switch toast.type {
        case .success: return theme.successColor
        case .info: return theme.infoColor
        case .warning: return theme.warningColor
        case .error: return theme.errorColor
        case .action, .loading: return theme.accentColor
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
