//
//  GlassMessageBubble.swift
//  osaurus
//
//  Floating glass message bubble with depth and hover effects
//  Updated to use theme colors for customization support
//

import SwiftUI

struct GlassMessageBubble: View {
    let role: MessageRole
    let isStreaming: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            // Background glass layers
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(glassBackground)
                )
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white.opacity(colorScheme == .dark ? 0.1 : 0.2))
                        .blur(radius: 20)
                        .offset(x: 0, y: 2)
                )

            // Edge lighting - using theme glass edge light
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(edgeColor, lineWidth: 0.5)

            // Subtle inner shadow for depth
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.05),
                            Color.clear,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.5
                )
                .blur(radius: 1)
                .opacity(colorScheme == .dark ? 0.5 : 0.8)
        }
        .shadow(
            color: shadowColor,
            radius: 8,
            x: 0,
            y: 4
        )
    }

    private var glassBackground: some ShapeStyle {
        if role == .user {
            // Use theme accent color for user messages
            return LinearGradient(
                colors: [
                    theme.accentColor.opacity(0.15),
                    theme.accentColor.opacity(0.08),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            // Use theme secondary background for assistant messages
            return LinearGradient(
                colors: [
                    theme.secondaryBackground.opacity(colorScheme == .dark ? 0.5 : 0.8),
                    theme.secondaryBackground.opacity(colorScheme == .dark ? 0.3 : 0.6),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var edgeColor: some ShapeStyle {
        LinearGradient(
            colors: [
                theme.glassEdgeLight,
                theme.glassEdgeLight.opacity(0.4),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var shadowColor: Color {
        if role == .user {
            return theme.accentColor.opacity(0.3)
        } else {
            return theme.shadowColor.opacity(theme.shadowOpacity)
        }
    }
}

// Preview helper
struct GlassMessageBubble_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            GlassMessageBubble(role: .user, isStreaming: false)
                .frame(width: 300, height: 80)

            GlassMessageBubble(role: .assistant, isStreaming: false)
                .frame(width: 300, height: 80)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
    }
}
