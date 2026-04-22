//
//  OnboardingProgress.swift
//  osaurus
//
//  Progress indicators used in the onboarding flow:
//   - `OnboardingShimmerBar` for download progress.
//   - `OnboardingStepIndicator` dots for the walkthrough.
//

import SwiftUI

// MARK: - Shimmer Progress Bar

/// Horizontal progress bar with a continuous shimmer overlay and a soft
/// glow at the leading edge of the fill.
struct OnboardingShimmerBar: View {
    let progress: Double
    let color: Color
    var height: CGFloat = 8

    @State private var shimmerOffset: CGFloat = -1

    private var trackShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: height / 2)
    }

    var body: some View {
        GeometryReader { geometry in
            let fillWidth = max(0, geometry.size.width * progress)

            ZStack(alignment: .leading) {
                // Background track
                trackShape
                    .fill(color.opacity(0.15))
                    .frame(height: height)

                // Progress fill with gradient + shimmer overlay
                trackShape
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.8), color, color.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: fillWidth, height: height)
                    .overlay(shimmerOverlay(width: fillWidth))
                    .clipShape(trackShape)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: progress)

                // Glow at the leading edge of progress
                Circle()
                    .fill(color)
                    .frame(width: height * 2.5, height: height * 2.5)
                    .blur(radius: 6)
                    .opacity(progress > 0 && progress < 1 ? 0.6 : 0)
                    .offset(x: max(0, fillWidth - height))
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: progress)
            }
        }
        .frame(height: height)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: false)) {
                shimmerOffset = 2
            }
        }
    }

    private func shimmerOverlay(width: CGFloat) -> some View {
        GeometryReader { _ in
            LinearGradient(
                colors: [
                    Color.white.opacity(0),
                    Color.white.opacity(0.4),
                    Color.white.opacity(0),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 50)
            .offset(x: shimmerOffset * width)
            .opacity(progress > 0 ? 1 : 0)
        }
        .clipped()
    }
}

// MARK: - Step Indicator

/// Dot-based step indicator. Shows `total` dots with `current` highlighted
/// in the accent color and slightly enlarged.
struct OnboardingStepIndicator: View {
    let current: Int
    let total: Int

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            ForEach(1 ... total, id: \.self) { step in
                Circle()
                    .fill(step == current ? theme.accentColor : theme.primaryBorder)
                    .frame(width: 8, height: 8)
                    .scaleEffect(step == current ? 1.2 : 1.0)
                    .animation(theme.springAnimation(), value: current)
            }
        }
    }
}
