//
//  CloudSecondaryButtonStyle.swift
//  osaurus
//
//  Compact, quiet Cloud-dialog action. Reuses the neutral secondary tint
//  treatment from ThemedAlertDialog without adding a prominent outline.
//

import SwiftUI

struct CloudSecondaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.tertiaryBackground.opacity(backgroundOpacity(isPressed: configuration.isPressed)))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovered = $0 }
    }

    private func backgroundOpacity(isPressed: Bool) -> Double {
        guard isEnabled else { return 0.5 }
        if isPressed { return 1 }
        return isHovered ? 0.8 : 0.5
    }
}

/// A visible, neutral hover target for the independent favorite action.
struct ModelFavoriteButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.primaryText.opacity(configuration.isPressed ? 0.12 : (isHovered ? 0.08 : 0)))
            )
            .onHover { isHovered = $0 }
    }
}
