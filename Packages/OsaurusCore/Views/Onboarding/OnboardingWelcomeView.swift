//
//  OnboardingWelcomeView.swift
//  osaurus
//
//  Welcome screen with theatrical orb animation and phased reveal.
//

import SwiftUI

// MARK: - Animation Phase

private enum WelcomePhase: Int {
    case initial = 0  // Nothing visible
    case orbAppear = 1  // Orb fades in at center
    case orbRise = 2  // Orb moves up, shrinks slightly
    case headline = 3  // Headline fades in
    case body = 4  // Body text fades in
    case button = 5  // Button fades in
}

// MARK: - Welcome View

struct OnboardingWelcomeView: View {
    let onContinue: () -> Void

    @Environment(\.theme) private var theme
    @State private var phase: WelcomePhase = .initial

    // Computed animation states
    private var orbVisible: Bool { phase.rawValue >= WelcomePhase.orbAppear.rawValue }
    private var orbRisen: Bool { phase.rawValue >= WelcomePhase.orbRise.rawValue }
    private var headlineVisible: Bool { phase.rawValue >= WelcomePhase.headline.rawValue }
    private var bodyVisible: Bool { phase.rawValue >= WelcomePhase.body.rawValue }
    private var buttonVisible: Bool { phase.rawValue >= WelcomePhase.button.rawValue }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Orb - starts centered, moves up
                orbSection
                    .position(
                        x: geometry.size.width / 2,
                        y: orbRisen ? geometry.size.height * 0.28 : geometry.size.height / 2
                    )
                    .animation(.easeInOut(duration: 0.9), value: orbRisen)

                // Content appears below orb after it rises
                VStack(spacing: 0) {
                    // Spacer to position content below orb
                    Spacer()
                        .frame(height: geometry.size.height * 0.42)

                    // Headline
                    Text("Your AI. Your Mac. Your data.")
                        .font(theme.font(size: 24, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .multilineTextAlignment(.center)
                        .opacity(headlineVisible ? 1 : 0)
                        .offset(y: headlineVisible ? 0 : 20)
                        .animation(.easeOut(duration: 0.6), value: headlineVisible)

                    Spacer().frame(height: 16)

                    // Body
                    Text(
                        "Everything stays on your machine — conversations,\nworkflows, memories. Connect any provider or run models locally."
                    )
                    .font(theme.font(size: 13))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .opacity(bodyVisible ? 1 : 0)
                    .offset(y: bodyVisible ? 0 : 15)
                    .animation(.easeOut(duration: 0.6), value: bodyVisible)

                    Spacer().frame(height: 40)

                    // Shimmer button
                    OnboardingShimmerButton(title: "Get Started", action: onContinue)
                        .frame(width: 160)
                        .opacity(buttonVisible ? 1 : 0)
                        .scaleEffect(buttonVisible ? 1 : 0.9)
                        .animation(.easeOut(duration: 0.5), value: buttonVisible)

                    Spacer()
                }
                .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            startAnimationSequence()
        }
    }

    // MARK: - Orb Section

    private var orbSection: some View {
        ZStack {
            // Ambient glow
            Circle()
                .fill(theme.accentColor)
                .blur(radius: 50)
                .frame(width: 100, height: 100)
                .opacity(orbVisible ? 0.35 : 0)

            // AnimatedOrb
            AnimatedOrb(
                color: theme.accentColor,
                size: .custom(orbRisen ? 90 : 110),
                seed: "welcome-onboarding",
                showGlow: true,
                showFloat: true,
                isInteractive: false
            )
            .frame(width: orbRisen ? 90 : 110, height: orbRisen ? 90 : 110)
            .opacity(orbVisible ? 1 : 0)
            .scaleEffect(orbVisible ? 1 : 0.5)
        }
        .animation(.easeOut(duration: 0.8), value: orbVisible)
    }

    // MARK: - Animation Sequence

    private func startAnimationSequence() {
        // Phase 1: Orb appears (0.3s delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            phase = .orbAppear
        }

        // Phase 2: Orb rises (1.2s delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            phase = .orbRise
        }

        // Phase 3: Headline (2.0s delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            phase = .headline
        }

        // Phase 4: Body (2.4s delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            phase = .body
        }

        // Phase 5: Button (2.8s delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            phase = .button
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct OnboardingWelcomeView_Previews: PreviewProvider {
        static var previews: some View {
            OnboardingWelcomeView(onContinue: {})
                .frame(width: 500, height: 560)
        }
    }
#endif
