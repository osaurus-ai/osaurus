//
//  ThemedToastView.swift
//  osaurus
//
//  Lightweight themed toast component for inline notifications.
//  Uses the same opaque styling as ToastView but with a simpler API.
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
/// Uses opaque styling consistent with the app's toast system
struct ThemedToastView: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var componentEnabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(18, enabled: componentEnabled) }

    let message: String
    let type: SimpleToastType

    @State private var isHovering = false

    init(_ message: String, type: SimpleToastType = .success) {
        self.message = message
        self.type = type
    }

    var body: some View {
        HStack(spacing: theme.catalogLayoutMetric("component.library.18.elements.layout.themedToastView.body.horizontalGap", inheriting: theme.catalogMetric("gap", fallback: theme.space.s10))) {
            ToastIcon(iconName: type.iconName, tone: tone, size: 24)

            Text(message)
                .assignedTypography("component.library.18.text", fallback: SettingsFont.caption)
                .foregroundColor(theme.text.primary)
                .lineLimit(2)
        }.catalogLayoutTarget("component.library.18.elements.layout.themedToastView.body.horizontalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.18.elements.layout.themedToastView.body.paddingX", inheriting: theme.catalogMetric("padding", fallback: theme.space.s14))).catalogLayoutTarget("component.library.18.elements.layout.themedToastView.body.paddingX")
        .padding(.vertical, theme.catalogLayoutMetric("component.library.18.elements.layout.themedToastView.body.paddingY", inheriting: theme.catalogMetric("padding", fallback: theme.space.s10))).catalogLayoutTarget("component.library.18.elements.layout.themedToastView.body.paddingY")
        .frame(minHeight: theme.catalogMetric("height", fallback: 0))
        .assignedBaseChrome(18)
        .toastShadow(theme: theme, isHovering: isHovering)
        .onHover { hovering in
            withAnimation(theme.motion.quick) {
                isHovering = hovering
            }
        }
    }

    private var tone: ThemeStatusSet<Color> {
        switch type {
        case .success: return theme.status.success
        case .error: return theme.status.error
        case .warning: return theme.status.warning
        case .info: return theme.status.info
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct ThemedToastView_Previews: PreviewProvider {
        @MainActor private static var theme: any ThemeProtocol { ThemeManager.shared.currentTheme }

        static var previews: some View {
            VStack(spacing: theme.space.s16) {
                ThemedToastView("Theme saved successfully", type: .success)
                ThemedToastView("Failed to load configuration", type: .error)
                ThemedToastView("Connection is unstable", type: .warning)
                ThemedToastView("New update available", type: .info)
            }
            .padding()
            .frame(width: 400)
            .background(CustomizableTheme.dark().surface.canvas)
        }
    }
#endif
