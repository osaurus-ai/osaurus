//
//  GlassMessageBubble.swift
//  osaurus
//
//  Floating glass message bubble with depth and hover effects
//

import SwiftUI

struct GlassMessageBubble: View {
    let role: MessageRole
    let isStreaming: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.theme) private var theme

    private var cornerRadius: Double { theme.bubbleCornerRadius }

    var body: some View {
        ZStack {
            // Background glass layers
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(glassBackground)
                )
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.white.opacity(theme.isDark ? 0.1 : 0.2))
                        .blur(radius: 20)
                        .offset(x: 0, y: 2)
                )

            if theme.showEdgeLight {
                // Edge lighting - using theme glass edge light
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(edgeColor, lineWidth: theme.messageBorderWidth)
            }

            // Subtle inner shadow for depth
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.05),
                            Color.clear,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: theme.messageBorderWidth
                )
                .blur(radius: 1)
                .opacity(theme.isDark ? 0.5 : 0.8)
        }
        .shadow(
            color: shadowColor,
            radius: 8,
            x: 0,
            y: 4
        )
    }

    private var glassBackground: some ShapeStyle {
        let bubbleColor =
            role == .user
            ? (theme.userBubbleColor ?? theme.accentColor)
            : (theme.assistantBubbleColor ?? theme.secondaryBackground)
        let opacity = role == .user ? theme.userBubbleOpacity : theme.assistantBubbleOpacity

        return LinearGradient(
            colors: [
                bubbleColor.opacity(opacity),
                bubbleColor.opacity(opacity * 0.7),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
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
            let bubbleColor = theme.userBubbleColor ?? theme.accentColor
            return bubbleColor.opacity(theme.shadowOpacity)
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
