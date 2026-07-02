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

    @State private var isHovering = false

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        // No entrance animation: rows live inside lazy stacks, where onAppear
        // re-fires on every scroll-back and would replay the fade.
        // Hover animates only shadow/border color at a fixed shadow radius —
        // animating radius forces an expensive shadow re-render per frame.
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
                        radius: theme.cardShadowRadius,
                        x: 0,
                        y: theme.cardShadowY
                    )
            )
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

// MARK: - Preview

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        VStack(spacing: 12) {
            ForEach(0 ..< 3) { index in
                GlassListRow {
                    HStack {
                        Text("Item \(index + 1)", bundle: .module)
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                }
            }
        }
        .padding(24)
        .background(Color(hex: "f9fafb"))
    }
#endif
