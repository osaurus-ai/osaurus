//
//  ThemedToastView.swift
//  osaurus
//
//  Lightweight themed toast component for inline notifications.
//  Uses the same glass-based styling as ToastView but with a simpler API.
//

import SwiftUI

// MARK: - Simple Toast Type

/// Simplified toast type for inline notifications
enum SimpleToastType {
    case success
    case error
    case warning
    case info

    /// SF Symbol icon name for this toast type
    var iconName: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
}

// MARK: - Themed Toast View

/// A lightweight themed toast for inline notifications
/// Uses glass-based styling consistent with the app's toast system
struct ThemedToastView: View {
    @Environment(\.theme) private var theme

    let message: String
    let type: SimpleToastType

    @State private var isHovering = false

    init(_ message: String, type: SimpleToastType = .success) {
        self.message = message
        self.type = type
    }

    var body: some View {
        HStack(spacing: 10) {
            ToastIcon(iconName: type.iconName, accentColor: accentColor, size: 24)

            Text(message)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(theme.primaryText)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(ToastBackground(accentColor: accentColor))
        .clipShape(RoundedRectangle(cornerRadius: ToastStyle.compactCornerRadius, style: .continuous))
        .overlay(
            ToastBorder(cornerRadius: ToastStyle.compactCornerRadius, accentColor: accentColor, isHovering: isHovering)
        )
        .toastShadow(theme: theme, isHovering: isHovering)
        .onHover { hovering in
            withAnimation(theme.animationQuick()) {
                isHovering = hovering
            }
        }
    }

    private var accentColor: Color {
        switch type {
        case .success: return theme.successColor
        case .error: return theme.errorColor
        case .warning: return theme.warningColor
        case .info: return theme.infoColor
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct ThemedToastView_Previews: PreviewProvider {
        static var previews: some View {
            VStack(spacing: 16) {
                ThemedToastView("Theme saved successfully", type: .success)
                ThemedToastView("Failed to load configuration", type: .error)
                ThemedToastView("Connection is unstable", type: .warning)
                ThemedToastView("New update available", type: .info)
            }
            .padding()
            .frame(width: 400)
            .background(Color.black.opacity(0.8))
        }
    }
#endif
