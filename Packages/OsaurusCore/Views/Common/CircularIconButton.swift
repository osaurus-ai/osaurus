//
//  CircularIconButton.swift
//  osaurus
//
//  A reusable circular icon button on the secondary action roles.
//

import SwiftUI

struct CircularIconButton: View {
    @Environment(\.theme) private var theme
    let systemName: String
    let help: LocalizedStringKey?
    let action: () -> Void

    @State private var isHovered = false

    init(systemName: String, help: LocalizedStringKey? = nil, action: @escaping () -> Void) {
        self.systemName = systemName
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .glyphSize(14)
                .foregroundColor(
                    isHovered ? theme.action.secondary.hover.foreground : theme.action.secondary.default.foreground
                )
                .frame(width: theme.controlSize.compactHeight, height: theme.controlSize.compactHeight)
                .background(
                    Circle().fill(
                        isHovered ? theme.action.secondary.hover.background : theme.action.secondary.default.background)
                )
                .overlay(Circle().strokeBorder(theme.action.border, lineWidth: theme.stroke.default))
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(theme.motion.quick) {
                isHovered = hovering
            }
        }
        .help(help.map { Text(localized: $0) } ?? Text(verbatim: ""))
    }
}
