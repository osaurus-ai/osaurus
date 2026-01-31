//
//  CircularIconButton.swift
//  osaurus
//
//  A reusable circular icon button with glassmorphism styling.
//

import SwiftUI

struct CircularIconButton: View {
    @Environment(\.theme) private var theme
    let systemName: String
    let help: String?
    let action: () -> Void

    @State private var isHovered = false

    init(systemName: String, help: String? = nil, action: @escaping () -> Void) {
        self.systemName = systemName
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                // Background
                Circle()
                    .fill(theme.buttonBackground.opacity(isHovered ? 0.95 : 0.8))

                // Hover accent gradient
                if isHovered {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [theme.accentColor.opacity(0.1), Color.clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                // Icon
                Image(systemName: systemName)
                    .font(.system(size: 14))
                    .foregroundColor(isHovered ? theme.accentColor : theme.primaryText)
            }
            .frame(width: 28, height: 28)
            .overlay(
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                theme.glassEdgeLight.opacity(isHovered ? 0.2 : 0.12),
                                theme.buttonBorder.opacity(isHovered ? 0.15 : 0.1),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isHovered ? theme.accentColor.opacity(0.15) : .clear,
                radius: 4,
                x: 0,
                y: 1
            )
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .help(help ?? "")
    }
}
