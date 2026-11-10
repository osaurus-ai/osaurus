//
//  ModelFavoriteButtonStyle.swift
//  osaurus
//
//  The star toggle on model rows.
//

import SwiftUI

/// A visible, neutral hover target for the independent favorite action.
struct ModelFavoriteButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .fill(configuration.isPressed ? theme.surface.pressed : (isHovered ? theme.surface.hover : .clear))
            )
            .onHover { isHovered = $0 }
    }
}
