//
//  OnboardingCompleteView.swift
//  osaurus
//
//  Setup complete view with AnimatedOrb celebration and walkthrough options.
//

import SwiftUI

struct OnboardingCompleteView: View {
    let onWalkthrough: () -> Void
    let onSkip: () -> Void
    let onSettings: () -> Void

    @Environment(\.theme) private var theme
    @State private var hasAppeared = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
                .frame(minHeight: 30, maxHeight: 45)

            // Celebration orb (same size as welcome orb)
            ZStack {
                // Success glow
                Circle()
                    .fill(theme.successColor)
                    .blur(radius: 50)
                    .frame(width: 100, height: 100)
                    .opacity(hasAppeared ? 0.4 : 0)

                AnimatedOrb(
                    color: theme.successColor,
                    size: .custom(90),
                    seed: "onboarding-complete",
                    showGlow: true,
                    showFloat: true,
                    isInteractive: false
                )
                .frame(width: 90, height: 90)
            }
            .opacity(hasAppeared ? 1 : 0)
            .scaleEffect(hasAppeared ? 1 : 0.6)
            .animation(.easeOut(duration: 0.8), value: hasAppeared)

            Spacer().frame(height: 20)

            // Headline
            Text("Ready to go")
                .font(theme.font(size: 24, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .multilineTextAlignment(.center)
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 20)
                .animation(.easeOut(duration: 0.6).delay(0.1), value: hasAppeared)

            Spacer().frame(height: 35)

            // Options
            VStack(spacing: 12) {
                CompleteOptionCard(
                    title: "Quick walkthrough",
                    description: "See what Osaurus can do",
                    icon: "play.circle",
                    action: onWalkthrough
                )
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 15)
                .animation(.easeOut(duration: 0.5).delay(0.2), value: hasAppeared)

                CompleteOptionCard(
                    title: "Customize",
                    description: "Permissions, providers, appearance",
                    icon: "gearshape",
                    action: onSettings
                )
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 15)
                .animation(.easeOut(duration: 0.5).delay(0.2), value: hasAppeared)

                CompleteOptionCard(
                    title: "Jump in",
                    description: "",
                    icon: "arrow.right.circle",
                    isSecondary: true,
                    action: onSkip
                )
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 15)
                .animation(.easeOut(duration: 0.5).delay(0.25), value: hasAppeared)
            }
            .padding(.horizontal, 40)

            Spacer()
                .frame(minHeight: 30)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                hasAppeared = true
            }
        }
    }
}

// MARK: - Complete Option Card

private struct CompleteOptionCard: View {
    let title: String
    let description: String
    let icon: String
    var isSecondary: Bool = false
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            OnboardingGlassCard {
                HStack(spacing: 14) {
                    // Icon
                    ZStack {
                        Circle()
                            .fill(isSecondary ? theme.cardBackground : theme.accentColor)
                            .frame(width: 42, height: 42)

                        Image(systemName: icon)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(isSecondary ? theme.secondaryText : .white)
                    }

                    // Text
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(theme.font(size: 14, weight: .semibold))
                            .foregroundColor(theme.primaryText)

                        if !description.isEmpty {
                            Text(description)
                                .font(theme.font(size: 12))
                                .foregroundColor(theme.secondaryText)
                        }
                    }

                    Spacer()

                    // Arrow
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct OnboardingCompleteView_Previews: PreviewProvider {
        static var previews: some View {
            OnboardingCompleteView(
                onWalkthrough: {},
                onSkip: {},
                onSettings: {}
            )
            .frame(width: OnboardingLayout.windowWidth, height: OnboardingLayout.windowHeight)
        }
    }
#endif
