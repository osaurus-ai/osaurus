//
//  ToastStyling.swift
//  osaurus
//
//  Shared styling components for toast notifications: opaque overlay
//  surface, flat borders, status-tone icons. No component glass.
//

import SwiftUI

// MARK: - Toast Style Constants

enum ToastStyle {
    /// Standard corner radius for full toasts (`radius.xlarge` is 16; toasts
    /// sit one step tighter so they read as transient).
    static let cornerRadius: CGFloat = 14

    /// Smaller corner radius for compact/inline toasts
    static let compactCornerRadius: CGFloat = 12
}

// MARK: - Toast Background

/// Opaque overlay surface for toast notifications (`color.surface.overlay`).
struct ToastBackground: View {
    @Environment(\.theme) private var theme

    var body: some View {
        theme.surface.overlay
    }
}

// MARK: - Toast Border

/// Flat border for toast notifications: the status border colour on hover,
/// `border.default` at rest.
struct ToastBorder: View {
    @Environment(\.theme) private var theme

    let cornerRadius: CGFloat
    let tone: ThemeStatusSet<Color>
    let isHovering: Bool

    init(cornerRadius: CGFloat = ToastStyle.cornerRadius, tone: ThemeStatusSet<Color>, isHovering: Bool = false) {
        self.cornerRadius = cornerRadius
        self.tone = tone
        self.isHovering = isHovering
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(isHovering ? tone.border : theme.border.default, lineWidth: theme.stroke.default)
    }
}

// MARK: - Toast Dismiss Button

/// Styled dismiss button for toast notifications (secondary action roles).
struct ToastDismissButton: View {
    @Environment(\.theme) private var theme

    let isHovering: Bool
    let action: () -> Void

    var body: some View {
        SettingsIconButton("xmark", help: "Dismiss notification", size: .compact, action: action)
    }

}

// MARK: - Toast Icon

/// Status icon on the status background disc.
struct ToastIcon: View {
    let iconName: String
    let tone: ThemeStatusSet<Color>
    let size: CGFloat

    init(iconName: String, tone: ThemeStatusSet<Color>, size: CGFloat = 28) {
        self.iconName = iconName
        self.tone = tone
        self.size = size
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(tone.background)
                .frame(width: size, height: size)

            Image(systemName: iconName)
                .glyphSize(points: size * 0.5, weight: .semibold)
                .foregroundColor(tone.foreground)
        }
    }
}

// MARK: - Toast Action Button

/// Action button for toast notifications: a compact secondary kit button.
struct ToastActionButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
        }
        .assignedSettingsButtonStyle(.secondary, size: .compact)
    }
}

// MARK: - View Modifier for Toast Shadow

extension View {
    /// Applies themed shadow to a toast view
    func toastShadow(theme: ThemeProtocol, isHovering: Bool) -> some View {
        // Hover no longer changes elevation (handoff: shadow is a single
        // overlay recipe; hover is expressed through surface/border roles).
        self.themeElevation(theme.elevation.overlay)
    }
}
