//
//  ThinkingBlockView.swift
//  osaurus
//
//  Collapsible UI to display model thinking/reasoning content.
//  Collapsed by default to reduce noise, expandable on click.
//

import AppKit
import SwiftUI

struct ThinkingBlockView: View {
    let thinking: String
    let baseWidth: CGFloat
    let isStreaming: Bool

    @State private var isExpanded: Bool = false
    @State private var isHovered: Bool = false
    @Environment(\.theme) private var theme

    /// Accent color for the thinking block - a subtle purple/indigo tone
    private var thinkingColor: Color {
        Color(red: 0.55, green: 0.45, blue: 0.85)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            // Expandable content with smooth height animation
            VStack(spacing: 0) {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.primaryBorder.opacity(0.0),
                                theme.primaryBorder.opacity(0.2),
                                theme.primaryBorder.opacity(0.0),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 1)
                    .padding(.horizontal, 14)

                content
                    .padding(.top, 10)
            }
            .frame(maxHeight: isExpanded ? nil : 0, alignment: .top)
            .clipped()
            .opacity(isExpanded ? 1 : 0)
            .animation(theme.springAnimation(), value: isExpanded)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(thinkingColor.opacity(isHovered ? 0.08 : 0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            thinkingColor.opacity(isHovered ? 0.25 : 0.15),
                            lineWidth: 0.5
                        )
                )
        )
        .shadow(
            color: thinkingColor.opacity(isHovered ? 0.06 : 0.03),
            radius: isHovered ? 4 : 2,
            x: 0,
            y: isHovered ? 2 : 1
        )
        .animation(theme.animationQuick(), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var header: some View {
        Button(action: {
            withAnimation(theme.springAnimation()) {
                isExpanded.toggle()
            }
        }) {
            HStack(spacing: 8) {
                // Brain icon with subtle animated background
                ZStack {
                    Circle()
                        .fill(thinkingColor.opacity(isStreaming ? 0.18 : 0.12))
                        .frame(width: 24, height: 24)

                    Image(systemName: "brain.head.profile")
                        .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                        .foregroundColor(thinkingColor)
                        .opacity(isStreaming ? pulseOpacity : 1.0)
                }

                // Title
                Text("Thinking")
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .semibold))
                    .foregroundColor(thinkingColor)

                // Streaming indicator
                if isStreaming {
                    ProgressView()
                        .scaleEffect(0.4)
                        .frame(width: 10, height: 10)
                }

                Spacer()

                // Character count hint when collapsed
                if !isExpanded {
                    Text(formatCharacterCount(thinking.count))
                        .font(theme.font(size: CGFloat(theme.captionSize) - 2, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(theme.tertiaryBackground.opacity(0.5))
                        )
                }

                // Expand/collapse chevron
                Image(systemName: "chevron.right")
                    .font(theme.font(size: CGFloat(theme.captionSize) - 2, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(theme.springAnimation(), value: isExpanded)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @State private var pulseOpacity: Double = 1.0

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Render thinking content as styled text
            ScrollView {
                Text(thinking)
                    .font(theme.font(size: CGFloat(theme.bodySize) - 1, weight: .regular))
                    .foregroundColor(theme.primaryText.opacity(0.85))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)  // Limit height with scroll for very long thinking
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    private func formatCharacterCount(_ count: Int) -> String {
        if count < 1000 {
            return "\(count) chars"
        } else if count < 10000 {
            let k = Double(count) / 1000.0
            return String(format: "%.1fk chars", k)
        } else {
            let k = count / 1000
            return "\(k)k chars"
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct ThinkingBlockView_Previews: PreviewProvider {
        static let sampleThinking = """
            Let me analyze this step by step...

            First, I need to understand what the user is asking for. They want to create a collapsible thinking block component.

            Key considerations:
            1. The component should be collapsed by default
            2. It should expand smoothly when clicked
            3. The styling should be consistent with the rest of the app

            I'll follow the pattern established by GroupedToolResponseView for the collapsible animation.
            """

        static var previews: some View {
            VStack(spacing: 16) {
                ThinkingBlockView(
                    thinking: sampleThinking,
                    baseWidth: 500,
                    isStreaming: false
                )

                ThinkingBlockView(
                    thinking: "Quick reasoning here...",
                    baseWidth: 500,
                    isStreaming: true
                )
            }
            .frame(width: 500)
            .padding()
            .background(Color(hex: "0f0f10"))
        }
    }
#endif
