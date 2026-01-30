//
//  ToastStyling.swift
//  osaurus
//
//  Shared styling components for toast notifications.
//  Provides consistent glass-based backgrounds, borders, and styling across all toast views.
//

import SwiftUI

// MARK: - Toast Style Constants

enum ToastStyle {
    /// Standard corner radius for full toasts
    static let cornerRadius: CGFloat = 14

    /// Smaller corner radius for compact/inline toasts
    static let compactCornerRadius: CGFloat = 12

    /// Glass background opacity in dark mode
    static let glassOpacityDark: Double = 0.78

    /// Glass background opacity in light mode
    static let glassOpacityLight: Double = 0.88

    /// Accent gradient opacity in dark mode
    static let accentGradientOpacityDark: Double = 0.08

    /// Accent gradient opacity in light mode
    static let accentGradientOpacityLight: Double = 0.05

    /// Border edge light opacity in dark mode
    static let edgeLightOpacityDark: Double = 0.22

    /// Border edge light opacity in light mode
    static let edgeLightOpacityLight: Double = 0.35

    /// Border primary opacity in dark mode
    static let borderOpacityDark: Double = 0.18

    /// Border primary opacity in light mode
    static let borderOpacityLight: Double = 0.28

    /// Accent edge opacity when hovering
    static let accentEdgeHoverOpacity: Double = 0.22

    /// Accent edge opacity when not hovering
    static let accentEdgeNormalOpacity: Double = 0.12
}

// MARK: - Toast Background

/// Glass-based background for toast notifications
struct ToastBackground: View {
    @Environment(\.theme) private var theme

    let accentColor: Color

    var body: some View {
        ZStack {
            if theme.glassEnabled {
                Rectangle().fill(.ultraThinMaterial)
            }

            theme.cardBackground.opacity(
                theme.glassEnabled
                    ? (theme.isDark ? ToastStyle.glassOpacityDark : ToastStyle.glassOpacityLight)
                    : 1.0
            )

            LinearGradient(
                colors: [
                    accentColor.opacity(
                        theme.isDark ? ToastStyle.accentGradientOpacityDark : ToastStyle.accentGradientOpacityLight
                    ),
                    Color.clear,
                    theme.primaryBackground.opacity(theme.isDark ? 0.08 : 0.04),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

// MARK: - Toast Border

/// Gradient border with accent edge highlight for toast notifications
struct ToastBorder: View {
    @Environment(\.theme) private var theme

    let cornerRadius: CGFloat
    let accentColor: Color
    let isHovering: Bool

    init(cornerRadius: CGFloat = ToastStyle.cornerRadius, accentColor: Color, isHovering: Bool = false) {
        self.cornerRadius = cornerRadius
        self.accentColor = accentColor
        self.isHovering = isHovering
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        theme.glassEdgeLight.opacity(
                            theme.isDark ? ToastStyle.edgeLightOpacityDark : ToastStyle.edgeLightOpacityLight
                        ),
                        theme.primaryBorder.opacity(
                            theme.isDark ? ToastStyle.borderOpacityDark : ToastStyle.borderOpacityLight
                        ),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
            .overlay(accentEdge)
    }

    private var accentEdge: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                accentColor.opacity(
                    isHovering ? ToastStyle.accentEdgeHoverOpacity : ToastStyle.accentEdgeNormalOpacity
                ),
                lineWidth: 1
            )
            .mask(
                LinearGradient(
                    colors: [Color.white, Color.white.opacity(0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
    }
}

// MARK: - Toast Dismiss Button

/// Styled dismiss button for toast notifications
struct ToastDismissButton: View {
    @Environment(\.theme) private var theme

    let isHovering: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 20, height: 20)
                .background(
                    Circle()
                        .fill(theme.tertiaryBackground.opacity(isHovering ? 0.9 : 0.6))
                )
                .overlay(
                    Circle()
                        .strokeBorder(theme.primaryBorder.opacity(isHovering ? 0.25 : 0.12), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .opacity(isHovering ? 1 : 0.6)
    }
}

// MARK: - Toast Icon

/// Status icon with accent-colored background circle
struct ToastIcon: View {
    @Environment(\.theme) private var theme

    let iconName: String
    let accentColor: Color
    let size: CGFloat

    init(iconName: String, accentColor: Color, size: CGFloat = 28) {
        self.iconName = iconName
        self.accentColor = accentColor
        self.size = size
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(accentColor.opacity(theme.isDark ? 0.14 : 0.10))
                .frame(width: size, height: size)

            Image(systemName: iconName)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundColor(accentColor)
        }
    }
}

// MARK: - Toast Action Button

/// Styled action button for toast notifications
struct ToastActionButton: View {
    let title: String
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(accentColor.opacity(0.15))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(accentColor.opacity(0.2), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - View Modifier for Toast Shadow

extension View {
    /// Applies themed shadow to a toast view
    func toastShadow(theme: ThemeProtocol, isHovering: Bool) -> some View {
        self.shadow(
            color: theme.shadowColor.opacity(theme.shadowOpacity),
            radius: isHovering ? theme.cardShadowRadiusHover : theme.cardShadowRadius,
            x: 0,
            y: isHovering ? theme.cardShadowYHover : theme.cardShadowY
        )
    }
}
