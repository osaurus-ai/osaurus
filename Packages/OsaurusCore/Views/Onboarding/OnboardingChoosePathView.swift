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
    case appleFoundation
    case local
    case apiProvider

    var title: String {
        switch self {
        case .appleFoundation: return "Use Apple Intelligence"
        case .local: return "Download a Local Model"
        case .apiProvider: return "Connect an AI Provider"
        }
    }

    var description: String {
        switch self {
        case .appleFoundation: return "Built into macOS. Private, fast, and ready to use."
        case .local: return "Runs entirely on your Mac. No account needed."
        case .apiProvider: return "Use OpenAI, Anthropic, xAI, or another provider you trust. Requires an API key."
        }
    }

    var icon: String {
        switch self {
        case .appleFoundation: return "apple.logo"
        case .local: return "desktopcomputer"
        case .apiProvider: return "cloud"
        }
    }
}

struct OnboardingChoosePathView: View {
    let onSelectLocal: () -> Void
    let onSelectAPI: () -> Void
    let onSelectFoundation: () -> Void

    @Environment(\.theme) private var theme
    @State private var selectedPath: OnboardingSetupPath? = nil
    @State private var hasAppeared = false
    @State private var showHelpPopover = false

    private let foundationAvailable = FoundationModelService.isDefaultModelAvailable()

    private var helpContent: String {
        if foundationAvailable {
            return """
                Apple Intelligence is built into macOS and runs privately on your device. It's ready to use immediately.

                Local models run on your Mac using your hardware. They're private and free to use, but require a download.

                Cloud providers like Claude and ChatGPT are more powerful but require an account and charge per use.

                Not sure? Apple Intelligence is recommended for most users.
                """
        } else {
            return """
                Local models run on your Mac using your hardware. They're private and free to use, but less capable than cloud models for complex tasks.

                Cloud providers like Claude and ChatGPT are more powerful but require an account and charge per use.

                Not sure? Start local. You can add providers later.
                """
        }
    }

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
                // Apple Foundation option (shown first if available)
                if foundationAvailable {
                    OnboardingOptionCard(
                        icon: OnboardingSetupPath.appleFoundation.icon,
                        title: OnboardingSetupPath.appleFoundation.title,
                        description: OnboardingSetupPath.appleFoundation.description,
                        isSelected: selectedPath == .appleFoundation
                    ) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            selectedPath = .appleFoundation
                        }
                    }
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 15)
                    .animation(.easeOut(duration: 0.5).delay(0.17), value: hasAppeared)
                }

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
                .animation(.easeOut(duration: 0.5).delay(foundationAvailable ? 0.24 : 0.17), value: hasAppeared)

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
                .animation(.easeOut(duration: 0.5).delay(foundationAvailable ? 0.31 : 0.24), value: hasAppeared)
            }
            .padding(.horizontal, 35)

            Spacer().frame(height: 18)

            // Help popover button
            Button {
                showHelpPopover.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 13))
                    Text("What's the difference?")
                        .font(theme.font(size: 13, weight: .medium))
                }
                .foregroundColor(theme.secondaryText)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showHelpPopover, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("What's the difference?")
                        .font(theme.font(size: 14, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Text(helpContent)
                        .font(theme.font(size: 13))
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(width: 320)
                .background(theme.primaryBackground)
            }
            .opacity(hasAppeared ? 1 : 0)
            .animation(.easeOut(duration: 0.5).delay(foundationAvailable ? 0.38 : 0.32), value: hasAppeared)

            Spacer()
                .frame(minHeight: 20)

            // Continue button
            OnboardingPrimaryButton(
                title: "Continue",
                action: {
                    switch selectedPath {
                    case .appleFoundation:
                        onSelectFoundation()
                    case .local:
                        onSelectLocal()
                    case .apiProvider:
                        onSelectAPI()
                    case .none:
                        break
                    }
                },
                isEnabled: selectedPath != nil
            )
            .frame(width: 180)
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 15)
            .animation(.easeOut(duration: 0.5).delay(foundationAvailable ? 0.47 : 0.4), value: hasAppeared)

            Spacer().frame(height: 40)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // Default select Apple Foundation if available
            if foundationAvailable {
                selectedPath = .appleFoundation
            }
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
                onSelectAPI: {},
                onSelectFoundation: {}
            )
            .frame(width: OnboardingLayout.windowWidth, height: OnboardingLayout.windowHeight)
        }
    }
#endif
