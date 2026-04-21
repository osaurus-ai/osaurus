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
        OnboardingScaffold(
            title: "Ready to go",
            content: {
                VStack(spacing: 0) {
                    ZStack {
                        Circle()
                            .fill(theme.successColor)
                            .blur(radius: 50)
                            .frame(width: 100, height: 100)
                            .opacity(hasAppeared ? 0.4 : 0)

                        AnimatedOrb(
                            color: theme.successColor,
                            size: .custom(80),
                            seed: "onboarding-complete",
                            showGlow: true,
                            showFloat: true,
                            isInteractive: false
                        )
                        .frame(width: 80, height: 80)
                    }
                    .opacity(hasAppeared ? 1 : 0)
                    .scaleEffect(hasAppeared ? 1 : 0.6)
                    .animation(theme.springAnimation(), value: hasAppeared)

                    Spacer().frame(height: 24)

                    VStack(spacing: OnboardingMetrics.cardSpacing) {
                        OnboardingRowCard(
                            icon: .symbol("play.circle"),
                            title: "Quick walkthrough",
                            subtitle: "See what Osaurus can do",
                            accessory: .chevron,
                            action: onWalkthrough
                        )
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 15)
                        .animation(theme.springAnimation().delay(0.2), value: hasAppeared)

                        OnboardingRowCard(
                            icon: .symbol("gearshape"),
                            title: "Customize",
                            subtitle: "Permissions, providers, appearance",
                            accessory: .chevron,
                            action: onSettings
                        )
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 15)
                        .animation(theme.springAnimation().delay(0.25), value: hasAppeared)

                        OnboardingRowCard(
                            icon: .symbol("arrow.right.circle"),
                            title: "Jump in",
                            accessory: .chevron,
                            action: onSkip
                        )
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 15)
                        .animation(theme.springAnimation().delay(0.3), value: hasAppeared)
                    }
                }
            }
        )
        .onAppearAfter(OnboardingMetrics.appearDelay) { hasAppeared = true }
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
            .frame(width: OnboardingMetrics.windowWidth, height: 600)
        }
    }
#endif
