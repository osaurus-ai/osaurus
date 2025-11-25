//
//  GlassListRow.swift
//  osaurus
//
//  Card-based list row with enhanced shadows and hover effects.
//

import SwiftUI

struct GlassListRow<Content: View>: View {
    @Environment(\.theme) private var theme
    let content: () -> Content

    /// Index for staggered animation
    var animationIndex: Int = 0

    @State private var isHovering = false
    @State private var hasAppeared = false

    init(animationIndex: Int = 0, @ViewBuilder content: @escaping () -> Content) {
        self.animationIndex = animationIndex
        self.content = content
    }

    var body: some View {
        content()
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                isHovering ? theme.accentColor.opacity(0.2) : theme.cardBorder,
                                lineWidth: 1
                            )
                    )
                    .shadow(
                        color: theme.shadowColor.opacity(
                            isHovering ? theme.shadowOpacity * 1.5 : theme.shadowOpacity
                        ),
                        radius: isHovering ? 12 : theme.cardShadowRadius,
                        x: 0,
                        y: isHovering ? 4 : theme.cardShadowY
                    )
            )
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
            }
            .opacity(hasAppeared ? 1 : 0)
            .onAppear {
                let delay = Double(animationIndex) * 0.02
                withAnimation(.easeOut(duration: 0.2).delay(delay)) {
                    hasAppeared = true
                }
            }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 12) {
        ForEach(0 ..< 3) { index in
            GlassListRow(animationIndex: index) {
                HStack {
                    Text("Item \(index + 1)")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
            }
        }
    }
    .padding(24)
    .background(Color(hex: "f9fafb"))
}
