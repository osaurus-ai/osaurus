//
//  OnboardingChoosePathView.swift
//  osaurus
//
//  Path selection view: Local Model vs API Provider.
//  Features glass cards with gradient borders and hover effects.
//

import SwiftUI

/// Setup path options
enum OnboardingSetupPath: String, CaseIterable {
    case local
    case apiProvider

    var title: String {
        switch self {
        case .local: return "Download a Local Model"
        case .apiProvider: return "Connect an AI Provider"
        }
    }

    var description: String {
        switch self {
        case .local: return "Runs entirely on your Mac. No account needed. ~1.5GB download."
        case .apiProvider: return "Use OpenAI, Anthropic, xAI, or another provider you trust. Requires an API key."
        }
    }

    var icon: String {
        switch self {
        case .local: return "desktopcomputer"
        case .apiProvider: return "cloud"
        }
    }
}

struct OnboardingChoosePathView: View {
    let onSelectLocal: () -> Void
    let onSelectAPI: () -> Void

    @Environment(\.theme) private var theme
    @State private var selectedPath: OnboardingSetupPath? = nil
    @State private var hasAppeared = false

    private let helpContent = """
        Local models run on your Mac using your hardware. They're private and free to use, but less capable than cloud models for complex tasks.

        Cloud providers like Claude and ChatGPT are more powerful but require an account and charge per use.

        Not sure? Start local. You can add providers later.
        """

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 45)

            // Headline
            Text("How do you want to power Osaurus?")
                .font(theme.font(size: 22, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 20)
                .animation(.easeOut(duration: 0.5).delay(0.1), value: hasAppeared)

            Spacer().frame(height: 30)

            // Option cards
            VStack(spacing: 12) {
                OnboardingOptionCard(
                    icon: OnboardingSetupPath.local.icon,
                    title: OnboardingSetupPath.local.title,
                    description: OnboardingSetupPath.local.description,
                    isSelected: selectedPath == .local
                ) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        selectedPath = .local
                    }
                }
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 15)
                .animation(.easeOut(duration: 0.5).delay(0.17), value: hasAppeared)

                OnboardingOptionCard(
                    icon: OnboardingSetupPath.apiProvider.icon,
                    title: OnboardingSetupPath.apiProvider.title,
                    description: OnboardingSetupPath.apiProvider.description,
                    isSelected: selectedPath == .apiProvider
                ) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        selectedPath = .apiProvider
                    }
                }
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 15)
                .animation(.easeOut(duration: 0.5).delay(0.24), value: hasAppeared)
            }
            .padding(.horizontal, 35)

            Spacer().frame(height: 18)

            // Expandable help
            OnboardingExpandableSection(
                title: "What's the difference?",
                content: helpContent
            )
            .padding(.horizontal, 35)
            .opacity(hasAppeared ? 1 : 0)
            .animation(.easeOut(duration: 0.5).delay(0.32), value: hasAppeared)

            Spacer()
                .frame(minHeight: 20)

            // Continue button
            OnboardingPrimaryButton(
                title: "Continue",
                action: {
                    if selectedPath == .local {
                        onSelectLocal()
                    } else {
                        onSelectAPI()
                    }
                },
                isEnabled: selectedPath != nil
            )
            .frame(width: 180)
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 15)
            .animation(.easeOut(duration: 0.5).delay(0.4), value: hasAppeared)

            Spacer().frame(height: 40)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation {
                    hasAppeared = true
                }
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct OnboardingChoosePathView_Previews: PreviewProvider {
        static var previews: some View {
            OnboardingChoosePathView(
                onSelectLocal: {},
                onSelectAPI: {}
            )
            .frame(width: OnboardingLayout.windowWidth, height: OnboardingLayout.windowHeight)
        }
    }
#endif
