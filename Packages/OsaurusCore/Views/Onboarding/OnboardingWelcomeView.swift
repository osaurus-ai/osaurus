//
//  OnboardingWelcomeView.swift
//  osaurus
//
//  Welcome step body + CTA — a single-column hero hosted in the chrome
//  shell. No wordmark or eyebrow on this screen; the dinosaur and the
//  headline carry the brand. Animation phases in over a tight cadence.
//

import SwiftUI

// MARK: - Welcome Body

struct WelcomeBody: View {
    @State private var visible = false

    var body: some View {
        OnboardingHeroBody(
            illustrationAsset: "osaurus-main",
            headline: "Own your AI.",
            subtitle:
                "Runs on your Mac. Your chats, files, and keys stay with you. No account, no cloud required."
        )
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.98)
        .animation(.easeOut(duration: 0.5), value: visible)
        .onAppearAfter(0.05) { visible = true }
    }
}

// MARK: - Welcome CTA

struct WelcomeCTA: View {
    let onContinue: () -> Void

    var body: some View {
        OnboardingBrandButton(title: "Get Started", action: onContinue)
            .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Preview

#if DEBUG
    struct OnboardingWelcomeView_Previews: PreviewProvider {
        static var previews: some View {
            VStack(spacing: 12) {
                WelcomeBody()
                    .frame(height: 420)
                WelcomeCTA(onContinue: {})
            }
            .frame(width: OnboardingMetrics.windowWidth, height: 540)
        }
    }
#endif
