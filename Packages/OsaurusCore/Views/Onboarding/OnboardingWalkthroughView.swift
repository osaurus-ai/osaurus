//
//  OnboardingWalkthroughView.swift
//  osaurus
//
//  4-step walkthrough tutorial showcasing Osaurus features with custom illustrations.
//

import SwiftUI

// MARK: - Navigation Direction

private enum NavigationDirection {
    case forward
    case backward
}

// MARK: - Walkthrough Step

private enum WalkthroughStepType: Int, CaseIterable {
    case modes = 0
    case skills = 1
    case personalization = 2
    case privacy = 3

    var title: String {
        switch self {
        case .modes: return "Chat or let it run"
        case .skills: return "Your AI, connected to your Mac"
        case .personalization: return "Personas, voice, and themes"
        case .privacy: return "Private by default"
        }
    }

    var body: String {
        switch self {
        case .modes:
            return
                "Chat Mode — Talk back and forth, like a conversation.\nAgent Mode — Give it a task and let it work in the background."
        case .skills:
            return
                "Enable Skills to let your AI read your calendar, send messages, search files, and more — all with your permission."
        case .personalization:
            return
                "Create different personas for different tasks. Talk hands-free with voice. Customize how everything looks."
        case .privacy:
            return "Conversations stay on your Mac. Switch providers anytime — your history comes with you."
        }
    }
}

// MARK: - Walkthrough View

struct OnboardingWalkthroughView: View {
    let onComplete: () -> Void

    @Environment(\.theme) private var theme
    @State private var currentStep = 0
    @State private var hasAppeared = false
    @State private var navigationDirection: NavigationDirection = .forward

    private var totalSteps: Int {
        WalkthroughStepType.allCases.count
    }

    private var isLastStep: Bool {
        currentStep == totalSteps - 1
    }

    private var step: WalkthroughStepType {
        WalkthroughStepType(rawValue: currentStep) ?? .modes
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 30)

            // Step indicator (clickable)
            stepIndicator
                .opacity(hasAppeared ? 1 : 0)
                .animation(.easeOut(duration: 0.5).delay(0.1), value: hasAppeared)

            Spacer().frame(height: 6)

            // Step label
            Text("Step \(currentStep + 1) of \(totalSteps)")
                .font(theme.font(size: 12, weight: .medium))
                .foregroundColor(theme.tertiaryText)
                .opacity(hasAppeared ? 1 : 0)
                .animation(.easeOut(duration: 0.5).delay(0.15), value: hasAppeared)

            Spacer().frame(height: 20)

            // Illustration
            illustrationView
                .frame(height: 140)
                .id("illustration-\(currentStep)")
                .transition(slideTransition)
                .opacity(hasAppeared ? 1 : 0)
                .animation(.easeOut(duration: 0.5).delay(0.2), value: hasAppeared)

            Spacer().frame(height: 24)

            // Title
            Text(step.title)
                .font(theme.font(size: 22, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .multilineTextAlignment(.center)
                .id("title-\(currentStep)")
                .transition(slideTransition)
                .opacity(hasAppeared ? 1 : 0)
                .animation(.easeOut(duration: 0.5).delay(0.25), value: hasAppeared)

            Spacer().frame(height: 14)

            // Body
            Text(step.body)
                .font(theme.font(size: 13))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 40)
                .id("body-\(currentStep)")
                .transition(slideTransition)
                .opacity(hasAppeared ? 1 : 0)
                .animation(.easeOut(duration: 0.5).delay(0.3), value: hasAppeared)

            Spacer()
                .frame(minHeight: 20)

            // Navigation buttons (fixed layout)
            navigationButtons
                .opacity(hasAppeared ? 1 : 0)
                .animation(.easeOut(duration: 0.5).delay(0.35), value: hasAppeared)

            Spacer().frame(height: 40)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation {
                    hasAppeared = true
                }
            }
        }
    }

    // MARK: - Slide Transition

    private var slideTransition: AnyTransition {
        let offset: CGFloat = 30
        let insertionOffset = navigationDirection == .forward ? offset : -offset
        let removalOffset = navigationDirection == .forward ? -offset : offset

        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: insertionOffset)),
            removal: .opacity.combined(with: .offset(x: removalOffset))
        )
    }

    // MARK: - Step Indicator (Clickable)

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0 ..< totalSteps, id: \.self) { stepIndex in
                Circle()
                    .fill(stepIndex == currentStep ? theme.accentColor : theme.primaryBorder)
                    .frame(width: 8, height: 8)
                    .scaleEffect(stepIndex == currentStep ? 1.2 : 1.0)
                    .animation(theme.springAnimation(), value: currentStep)
                    .contentShape(Circle().scale(2.5))
                    .onTapGesture {
                        navigateTo(stepIndex)
                    }
            }
        }
    }

    // MARK: - Illustration View

    @ViewBuilder
    private var illustrationView: some View {
        switch step {
        case .modes:
            WalkthroughModesIllustration()
        case .skills:
            WalkthroughSkillsIllustration()
        case .personalization:
            WalkthroughPersonalizationIllustration()
        case .privacy:
            WalkthroughPrivacyIllustration()
        }
    }

    // MARK: - Navigation Buttons (Fixed Layout)

    private var navigationButtons: some View {
        HStack(spacing: 12) {
            // Back button - always present, invisible on first step
            OnboardingSecondaryButton(title: "Back") {
                navigateTo(currentStep - 1)
            }
            .frame(width: 100)
            .opacity(currentStep > 0 ? 1 : 0)
            .disabled(currentStep == 0)

            // Forward button
            if isLastStep {
                OnboardingShimmerButton(title: "Start using Osaurus") {
                    onComplete()
                }
                .frame(width: 200)
            } else {
                OnboardingPrimaryButton(title: "Next") {
                    navigateTo(currentStep + 1)
                }
                .frame(width: 100)
            }
        }
    }

    // MARK: - Navigation

    private func navigateTo(_ stepIndex: Int) {
        guard stepIndex >= 0, stepIndex < totalSteps, stepIndex != currentStep else { return }

        navigationDirection = stepIndex > currentStep ? .forward : .backward

        withAnimation(.easeInOut(duration: 0.35)) {
            currentStep = stepIndex
        }
    }
}

// MARK: - Modes Illustration (Chat vs Agent)

private struct WalkthroughModesIllustration: View {
    @Environment(\.theme) private var theme
    @State private var hasAppeared = false
    @State private var floatOffset: CGFloat = 0
    @State private var hoveredCard: String? = nil

    var body: some View {
        HStack(spacing: 24) {
            // Chat Mode Card
            modeCard(
                id: "chat",
                icon: "bubble.left.and.bubble.right",
                label: "Chat",
                delay: 0
            )

            // Agent Mode Card
            modeCard(
                id: "agent",
                icon: "bolt.fill",
                label: "Agent",
                delay: 0.1
            )
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                hasAppeared = true
            }
            // Floating animation
            withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                floatOffset = -4
            }
        }
    }

    private func modeCard(id: String, icon: String, label: String, delay: Double) -> some View {
        let isHovered = hoveredCard == id

        return VStack(spacing: 12) {
            ZStack {
                // Glow
                Circle()
                    .fill(theme.accentColor.opacity(isHovered ? 0.35 : 0.2))
                    .frame(width: 80, height: 80)
                    .blur(radius: isHovered ? 25 : 20)

                // Card background
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(theme.cardBackground)
                    .frame(width: 80, height: 80)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        isHovered ? theme.accentColor.opacity(0.5) : theme.accentColor.opacity(0.3),
                                        theme.primaryBorder.opacity(0.2),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: isHovered ? 1.5 : 1
                            )
                    )

                // Icon
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(theme.accentColor)
            }
            .offset(y: floatOffset)
            .scaleEffect(isHovered ? 1.08 : 1.0)

            Text(label)
                .font(theme.font(size: 13, weight: .medium))
                .foregroundColor(isHovered ? theme.primaryText : theme.secondaryText)
        }
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 15)
        .animation(.spring(response: 0.6, dampingFraction: 0.8).delay(delay), value: hasAppeared)
        .animation(.easeOut(duration: 0.2), value: isHovered)
        .onHover { hovering in
            hoveredCard = hovering ? id : nil
        }
    }
}

// MARK: - Skills Illustration (Icons Grid)

private struct WalkthroughSkillsIllustration: View {
    @Environment(\.theme) private var theme
    @State private var hasAppeared = false
    @State private var pulseScale: CGFloat = 1.0
    @State private var hoveredIndex: Int? = nil

    private let skills: [String] = ["calendar", "message.fill", "note.text", "folder.fill"]

    var body: some View {
        HStack(spacing: 16) {
            ForEach(Array(skills.enumerated()), id: \.offset) { index, icon in
                skillIcon(index: index, icon: icon, delay: Double(index) * 0.08)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                hasAppeared = true
            }
            // Subtle pulse animation
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                pulseScale = 1.05
            }
        }
    }

    private func skillIcon(index: Int, icon: String, delay: Double) -> some View {
        let isHovered = hoveredIndex == index

        return ZStack {
            // Subtle glow
            Circle()
                .fill(theme.accentColor.opacity(isHovered ? 0.25 : 0.12))
                .frame(width: 60, height: 60)
                .blur(radius: isHovered ? 15 : 12)
                .scaleEffect(isHovered ? 1.1 : pulseScale)

            // Glass background
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.cardBackground)
                .frame(width: 56, height: 56)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    isHovered ? theme.accentColor.opacity(0.4) : theme.glassEdgeLight.opacity(0.25),
                                    theme.primaryBorder.opacity(0.15),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: isHovered ? 1.5 : 1
                        )
                )

            // Icon
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(theme.accentColor)
        }
        .scaleEffect(isHovered ? 1.1 : 1.0)
        .opacity(hasAppeared ? 1 : 0)
        .scaleEffect(hasAppeared ? 1 : 0.6)
        .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(delay), value: hasAppeared)
        .animation(.easeOut(duration: 0.2), value: isHovered)
        .onHover { hovering in
            hoveredIndex = hovering ? index : nil
        }
    }
}

// MARK: - Personalization Illustration (Orbs + Mic + Theme)

private struct WalkthroughPersonalizationIllustration: View {
    @Environment(\.theme) private var theme
    @State private var hasAppeared = false
    @State private var floatOffset: CGFloat = 0
    @State private var hoveredItem: String? = nil

    var body: some View {
        HStack(spacing: 20) {
            // Personas - Three orbs in a row (overlapping slightly)
            personasOrbs
                .onHover { hovering in
                    hoveredItem = hovering ? "personas" : nil
                }

            // Voice
            iconCard(id: "voice", icon: "mic.fill", delay: 0.2)

            // Themes
            iconCard(id: "themes", icon: "paintpalette.fill", delay: 0.25)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                hasAppeared = true
            }
            // Floating animation
            withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                floatOffset = -3
            }
        }
    }

    private var personasOrbs: some View {
        let isHovered = hoveredItem == "personas"

        return ZStack {
            // Glow
            Circle()
                .fill(theme.accentColor.opacity(isHovered ? 0.25 : 0.15))
                .frame(width: 70, height: 70)
                .blur(radius: isHovered ? 18 : 14)

            // Three orbs in a horizontal row, overlapping
            HStack(spacing: -8) {
                miniOrb(scale: 0.85, opacity: 0.6, delay: 0.05)
                miniOrb(scale: 1.0, opacity: 1.0, delay: 0.1)
                    .zIndex(1)
                miniOrb(scale: 0.85, opacity: 0.6, delay: 0.15)
            }
        }
        .offset(y: floatOffset)
        .scaleEffect(isHovered ? 1.1 : 1.0)
        .animation(.easeOut(duration: 0.2), value: isHovered)
    }

    private func miniOrb(scale: CGFloat, opacity: Double, delay: Double) -> some View {
        ZStack {
            // Orb body
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            theme.accentColor.opacity(0.95),
                            theme.accentColor,
                        ],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 18 * scale
                    )
                )
                .frame(width: 26 * scale, height: 26 * scale)
                .overlay(
                    // Highlight
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.5), Color.clear],
                                startPoint: .topLeading,
                                endPoint: .center
                            )
                        )
                        .frame(width: 10 * scale, height: 10 * scale)
                        .offset(x: -4 * scale, y: -4 * scale)
                        .blur(radius: 2)
                )
                .shadow(color: theme.accentColor.opacity(0.4), radius: 6, y: 2)
        }
        .opacity(hasAppeared ? opacity : 0)
        .scaleEffect(hasAppeared ? 1 : 0.5)
        .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(delay), value: hasAppeared)
    }

    private func iconCard(id: String, icon: String, delay: Double) -> some View {
        let isHovered = hoveredItem == id

        return ZStack {
            // Glow
            Circle()
                .fill(theme.accentColor.opacity(isHovered ? 0.25 : 0.15))
                .frame(width: 60, height: 60)
                .blur(radius: isHovered ? 15 : 12)

            // Background
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.cardBackground)
                .frame(width: 52, height: 52)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    isHovered ? theme.accentColor.opacity(0.4) : theme.glassEdgeLight.opacity(0.25),
                                    theme.primaryBorder.opacity(0.15),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: isHovered ? 1.5 : 1
                        )
                )

            // Icon
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(theme.accentColor)
        }
        .scaleEffect(isHovered ? 1.1 : 1.0)
        .opacity(hasAppeared ? 1 : 0)
        .scaleEffect(hasAppeared ? 1 : 0.6)
        .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(delay), value: hasAppeared)
        .animation(.easeOut(duration: 0.2), value: isHovered)
        .onHover { hovering in
            hoveredItem = hovering ? id : nil
        }
    }
}

// MARK: - Privacy Illustration (Shield with Lock)

private struct WalkthroughPrivacyIllustration: View {
    @Environment(\.theme) private var theme
    @State private var hasAppeared = false
    @State private var glowPulse: CGFloat = 1.0
    @State private var floatOffset: CGFloat = 0
    @State private var isHovered = false

    var body: some View {
        ZStack {
            // Ambient glow (pulsing)
            Circle()
                .fill(theme.accentColor.opacity(isHovered ? 0.2 : 0.12))
                .frame(width: 140, height: 140)
                .blur(radius: isHovered ? 50 : 40)
                .scaleEffect(isHovered ? 1.2 : glowPulse)
                .opacity(hasAppeared ? 1 : 0)
                .animation(.easeOut(duration: 0.8), value: hasAppeared)

            // Shield with lock - using the combined SF Symbol
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 90, weight: .medium))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            theme.accentColor,
                            theme.accentColor.opacity(0.85),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: theme.accentColor.opacity(0.4), radius: isHovered ? 20 : 12, y: 4)
                .offset(y: floatOffset)
                .scaleEffect(isHovered ? 1.1 : 1.0)
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.7)
                .animation(.spring(response: 0.7, dampingFraction: 0.7).delay(0.1), value: hasAppeared)
                .animation(.easeOut(duration: 0.2), value: isHovered)
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                hasAppeared = true
            }
            // Floating animation
            withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                floatOffset = -5
            }
            // Glow pulse
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                glowPulse = 1.15
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct OnboardingWalkthroughView_Previews: PreviewProvider {
        static var previews: some View {
            OnboardingWalkthroughView(onComplete: {})
                .frame(width: OnboardingLayout.windowWidth, height: OnboardingLayout.windowHeight)
        }
    }
#endif
