//
//  OnboardingWelcomeView.swift
//  osaurus
//
//  Welcome screen with an orb hero and phased content reveal.
//

import SwiftUI

// MARK: - Animation Phase

private enum WelcomePhase: Int {
    case initial = 0
    case orb = 1
    case headline = 2
    case body = 3
    case button = 4
}

// MARK: - Welcome View

struct OnboardingWelcomeView: View {
    let onContinue: () -> Void

    @Environment(\.theme) private var theme
    @State private var phase: WelcomePhase = .initial

    private var orbVisible: Bool { phase.rawValue >= WelcomePhase.orb.rawValue }
    private var headlineVisible: Bool { phase.rawValue >= WelcomePhase.headline.rawValue }
    private var bodyVisible: Bool { phase.rawValue >= WelcomePhase.body.rawValue }
    private var buttonVisible: Bool { phase.rawValue >= WelcomePhase.button.rawValue }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 32)

            // Orb hero
            ZStack {
                Circle()
                    .fill(theme.accentColor)
                    .blur(radius: 50)
                    .frame(width: 100, height: 100)
                    .opacity(orbVisible ? 0.35 : 0)

                AnimatedOrb(
                    color: theme.accentColor,
                    size: .custom(96),
                    seed: "welcome-onboarding",
                    showGlow: true,
                    showFloat: true,
                    isInteractive: false
                )
                .frame(width: 96, height: 96)
                .opacity(orbVisible ? 1 : 0)
                .scaleEffect(orbVisible ? 1 : 0.5)
            }
            .animation(.easeOut(duration: 0.8), value: orbVisible)

            Spacer().frame(height: 28)

            Text("Own your AI.", bundle: .module)
                .font(theme.font(size: OnboardingMetrics.heroTitleSize, weight: .bold))
                .foregroundColor(theme.primaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(headlineVisible ? 1 : 0)
                .offset(y: headlineVisible ? 0 : 16)
                .animation(.easeOut(duration: 0.5), value: headlineVisible)

            Spacer().frame(height: 14)

            Text(
                "Agents, memory, tools, and identity that live on your Mac.\nModels are interchangeable — everything else compounds, stays with you.",
                bundle: .module
            )
            .font(theme.font(size: OnboardingMetrics.subtitleSize))
            .foregroundColor(theme.secondaryText)
            .multilineTextAlignment(.center)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .opacity(bodyVisible ? 1 : 0)
            .offset(y: bodyVisible ? 0 : 12)
            .animation(.easeOut(duration: 0.5), value: bodyVisible)

            Spacer(minLength: 24)

            OnboardingShimmerButton(title: "Get Started", action: onContinue)
                .frame(width: OnboardingMetrics.ctaWidthCompact)
                .opacity(buttonVisible ? 1 : 0)
                .scaleEffect(buttonVisible ? 1 : 0.9)
                .animation(theme.springAnimation(), value: buttonVisible)

            Spacer().frame(height: OnboardingMetrics.bottomInset)
        }
        .padding(.horizontal, OnboardingMetrics.contentHorizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            // Allow impatient users to skip straight to the CTA reveal
            guard phase != .button else { return }
            withAnimation(.easeOut(duration: 0.35)) {
                phase = .button
            }
        }
        .task { await runAnimationSequence() }
    }

    /// Reveal the orb, then the headline, body and CTA in a tight cadence.
    /// Steps are sequenced via `Task.sleep` so they cancel together if the
    /// view disappears mid-animation (e.g. user clicks "Get Started" early).
    private func runAnimationSequence() async {
        let cadence: [(phase: WelcomePhase, delay: UInt64)] = [
            (.orb, 250_000_000),
            (.headline, 650_000_000),
            (.body, 350_000_000),
            (.button, 350_000_000),
        ]
        for step in cadence {
            try? await Task.sleep(nanoseconds: step.delay)
            guard !Task.isCancelled else { return }
            phase = step.phase
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct OnboardingWelcomeView_Previews: PreviewProvider {
        static var previews: some View {
            OnboardingWelcomeView(onContinue: {})
                .frame(width: OnboardingMetrics.windowWidth, height: 560)
        }
    }
#endif
