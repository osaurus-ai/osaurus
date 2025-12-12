//
//  TypingIndicator.swift
//  osaurus
//
//  Animated typing indicator with bouncing dots
//

import SwiftUI

struct TypingIndicator: View {
    @State private var animatingDot: Int = 0
    @Environment(\.theme) private var theme

    private let dotCount = 3
    private let dotSize: CGFloat = 6
    private let spacing: CGFloat = 4

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0 ..< dotCount, id: \.self) { index in
                Circle()
                    .fill(dotColor(for: index))
                    .frame(width: dotSize, height: dotSize)
                    .offset(y: animatingDot == index ? -4 : 0)
                    .animation(
                        .spring(response: 0.3, dampingFraction: 0.5)
                            .delay(Double(index) * 0.1),
                        value: animatingDot
                    )
            }
        }
        .onAppear {
            startAnimation()
        }
    }

    private func dotColor(for index: Int) -> Color {
        if animatingDot == index {
            return theme.accentColor
        } else {
            return theme.tertiaryText.opacity(0.6)
        }
    }

    private func startAnimation() {
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                withAnimation {
                    animatingDot = (animatingDot + 1) % dotCount
                }
            }
        }
    }
}

// MARK: - Alternative Pulse Style

struct TypingIndicatorPulse: View {
    @State private var isAnimating = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< 3, id: \.self) { index in
                Circle()
                    .fill(theme.tertiaryText.opacity(0.5))
                    .frame(width: 6, height: 6)
                    .scaleEffect(isAnimating ? 1.0 : 0.5)
                    .opacity(isAnimating ? 1.0 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.2),
                        value: isAnimating
                    )
            }
        }
        .onAppear {
            isAnimating = true
        }
    }
}

// MARK: - Skeleton Placeholder

struct SkeletonLine: View {
    let width: CGFloat
    @State private var isAnimating = false
    @Environment(\.theme) private var theme

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(
                LinearGradient(
                    colors: [
                        theme.tertiaryBackground.opacity(0.3),
                        theme.tertiaryBackground.opacity(0.6),
                        theme.tertiaryBackground.opacity(0.3),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: width, height: 14)
            .mask(
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, .white, .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .offset(x: isAnimating ? width : -width)
            )
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    isAnimating = true
                }
            }
    }
}

// MARK: - Preview

#if DEBUG
    struct TypingIndicator_Previews: PreviewProvider {
        static var previews: some View {
            VStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bouncing Dots")
                        .font(.caption)
                    TypingIndicator()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Pulse Style")
                        .font(.caption)
                    TypingIndicatorPulse()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Skeleton Lines")
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonLine(width: 200)
                        SkeletonLine(width: 160)
                        SkeletonLine(width: 180)
                    }
                }
            }
            .padding(40)
            .background(Color(hex: "0f0f10"))
        }
    }
#endif
