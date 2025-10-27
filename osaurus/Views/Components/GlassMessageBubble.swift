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

      // Edge lighting
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
      return LinearGradient(
        colors: [
          Color.accentColor.opacity(0.15),
          Color.accentColor.opacity(0.08),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    } else {
      return LinearGradient(
        colors: [
          Color.white.opacity(colorScheme == .dark ? 0.15 : 0.25),
          Color.white.opacity(colorScheme == .dark ? 0.08 : 0.15),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    }
  }

  private var edgeColor: some ShapeStyle {
    LinearGradient(
      colors: [
        Color.white.opacity(0.5),
        Color.white.opacity(0.2),
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  private var shadowColor: Color {
    if role == .user {
      return Color.accentColor.opacity(0.3)
    } else {
      return Color.black.opacity(colorScheme == .dark ? 0.5 : 0.15)
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
