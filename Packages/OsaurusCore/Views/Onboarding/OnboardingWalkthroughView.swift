//
//  OnboardingWalkthroughView.swift
//  osaurus
//
//  6-step walkthrough tutorial showcasing Osaurus features with rich illustrations.
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
    case tools = 1
    case sandbox = 2
    case personalization = 3
    case memory = 4
    case privacy = 5

    var title: String {
        switch self {
        case .modes: return L("Chat or let it run")
        case .tools: return L("Tools, skills, and plugins")
        case .sandbox: return L("Safe, isolated execution")
        case .personalization: return L("Agents, voice, and themes")
        case .memory: return L("Gets smarter over time")
        case .privacy: return L("Private by default")
        }
    }

    var body: String {
        switch self {
        case .modes:
            return L(
                "Chat Mode — Talk back and forth, like a conversation.\nWork Mode — Give it a task and let it work in the background."
            )
        case .tools:
            return L(
                "20+ built-in plugins for Mail, Calendar, Browser, Files, and more. Import skills from GitHub. Connect MCP servers. All with your permission."
            )
        case .sandbox:
            return L(
                "The Sandbox runs code in a Linux container on your Mac. Agents can execute commands, install packages, and work with files — fully isolated from your system."
            )
        case .personalization:
            return L(
                "Create different agents for different tasks. Talk hands-free with voice. Customize how everything looks."
            )
        case .memory:
            return L(
                "Osaurus builds a layered memory from your conversations — profile, working context, summaries, and a knowledge graph. Agents recall relevant facts automatically. Your memory stays with you, not a provider."
            )
        case .privacy:
            return L("Conversations stay on your Mac. Switch providers anytime — your history comes with you.")
        }
    }

    var color: Color {
        switch self {
        case .modes: return .blue
        case .tools: return .green
        case .sandbox: return .orange
        case .personalization: return .purple
        case .memory: return .cyan
        case .privacy: return .teal
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
    @State private var isCardHovered = false

    private var totalSteps: Int {
        WalkthroughStepType.allCases.count
    }

    private var isLastStep: Bool {
        currentStep == totalSteps - 1
    }

    private var step: WalkthroughStepType {
        WalkthroughStepType(rawValue: currentStep) ?? .modes
    }

    private var stepColor: Color {
        step.color
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 24)

            stepIndicator
                .opacity(hasAppeared ? 1 : 0)
                .animation(theme.springAnimation().delay(0.1), value: hasAppeared)

            Spacer().frame(height: 16)

            contentCard
                .opacity(hasAppeared ? 1 : 0)
                .animation(theme.springAnimation().delay(0.15), value: hasAppeared)

            Spacer()
                .frame(minHeight: 16)

            navigationButtons
                .opacity(hasAppeared ? 1 : 0)
                .animation(theme.springAnimation().delay(0.35), value: hasAppeared)

            Spacer().frame(height: OnboardingStyle.bottomButtonPadding)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + OnboardingStyle.appearDelay) {
                withAnimation {
                    hasAppeared = true
                }
            }
        }
    }

    // MARK: - Content Card

    private var contentCard: some View {
        VStack(spacing: 0) {
            // Tinted illustration band
            ZStack {
                // Background tint
                LinearGradient(
                    colors: [
                        stepColor.opacity(theme.isDark ? 0.1 : 0.08),
                        stepColor.opacity(theme.isDark ? 0.03 : 0.02),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                illustrationView
                    .frame(height: 200)
                    .id("illustration-\(currentStep)")
                    .transition(slideTransition)
            }
            .frame(height: 200)
            .clipped()

            // Subtle separator
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            stepColor.opacity(0.15),
                            stepColor.opacity(0.05),
                            Color.clear,
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)

            Spacer().frame(height: 20)

            Text(step.title)
                .font(theme.font(size: 22, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .multilineTextAlignment(.center)
                .id("title-\(currentStep)")
                .transition(slideTransition)

            Spacer().frame(height: 10)

            Text(step.body)
                .font(theme.font(size: 13))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
                .id("body-\(currentStep)")
                .transition(slideTransition)

            Spacer().frame(height: 20)
        }
        .frame(maxWidth: .infinity)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(cardBorder)
        .shadow(
            color: theme.shadowColor.opacity(theme.shadowOpacity * (isCardHovered ? 1.2 : 0.8)),
            radius: isCardHovered ? 20 : 12,
            x: 0,
            y: isCardHovered ? 8 : 4
        )
        .scaleEffect(isCardHovered ? 1.005 : 1.0)
        .animation(theme.animationQuick(), value: isCardHovered)
        .animation(theme.springAnimation(), value: currentStep)
        .onHover { hovering in
            isCardHovered = hovering
        }
    }

    // MARK: - Card Background

    private var cardBackground: some View {
        ZStack {
            if theme.glassEnabled {
                Rectangle().fill(.ultraThinMaterial)
            }

            theme.cardBackground.opacity(
                theme.glassEnabled
                    ? (theme.isDark ? 0.78 : 0.88)
                    : 1.0
            )

            LinearGradient(
                colors: [
                    stepColor.opacity(theme.isDark ? 0.04 : 0.03),
                    Color.clear,
                    theme.primaryBackground.opacity(theme.isDark ? 0.06 : 0.03),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    // MARK: - Card Border

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        theme.glassEdgeLight.opacity(theme.isDark ? 0.22 : 0.35),
                        theme.primaryBorder.opacity(theme.isDark ? 0.15 : 0.25),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
            .overlay(accentEdge)
    }

    private var accentEdge: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(
                stepColor.opacity(isCardHovered ? 0.22 : 0.10),
                lineWidth: 1
            )
            .mask(
                LinearGradient(
                    colors: [Color.white, Color.white.opacity(0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
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

    // MARK: - Step Indicator (Pill Style)

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< totalSteps, id: \.self) { stepIndex in
                let indicatorStep = WalkthroughStepType(rawValue: stepIndex) ?? .modes
                Capsule()
                    .fill(stepIndex == currentStep ? indicatorStep.color : theme.primaryBorder.opacity(0.5))
                    .frame(width: stepIndex == currentStep ? 24 : 8, height: 6)
                    .animation(theme.springAnimation(), value: currentStep)
                    .contentShape(Rectangle().inset(by: -8))
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
        case .tools:
            WalkthroughToolsIllustration()
        case .sandbox:
            WalkthroughSandboxIllustration()
        case .personalization:
            WalkthroughPersonalizationIllustration()
        case .memory:
            WalkthroughMemoryIllustration()
        case .privacy:
            WalkthroughPrivacyIllustration()
        }
    }

    // MARK: - Navigation Buttons (Fixed Layout)

    private var navigationButtons: some View {
        HStack(spacing: 12) {
            if currentStep > 0 {
                OnboardingSecondaryButton(title: "Back") {
                    navigateTo(currentStep - 1)
                }
                .frame(width: 120)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            Group {
                if isLastStep {
                    OnboardingShimmerButton(title: "Start using Osaurus") {
                        onComplete()
                    }
                } else {
                    OnboardingPrimaryButton(title: "Next") {
                        navigateTo(currentStep + 1)
                    }
                }
            }
            .frame(width: 180)
        }
    }

    // MARK: - Navigation

    private func navigateTo(_ stepIndex: Int) {
        guard stepIndex >= 0, stepIndex < totalSteps, stepIndex != currentStep else { return }

        navigationDirection = stepIndex > currentStep ? .forward : .backward

        withAnimation(theme.springAnimation(responseMultiplier: 0.8)) {
            currentStep = stepIndex
        }
    }
}

// MARK: - Modes Illustration (Overlapping Window Cards)

private struct WalkthroughModesIllustration: View {
    @Environment(\.theme) private var theme
    @State private var hasAppeared = false
    @State private var floatOffset: CGFloat = 0
    @State private var hoveredCard: String? = nil

    private let stepColor = Color.blue

    var body: some View {
        ZStack {
            // Chat card (behind, offset left and rotated)
            windowCard(
                id: "chat",
                icon: "bubble.left.and.bubble.right",
                label: L("Chat"),
                sublabel: L("Conversation"),
                rotation: -6,
                offsetX: -40,
                offsetY: 8,
                delay: 0
            )

            // Work card (front, offset right and rotated)
            windowCard(
                id: "work",
                icon: "bolt.fill",
                label: L("Work"),
                sublabel: L("Background"),
                rotation: 5,
                offsetX: 40,
                offsetY: -4,
                delay: 0.1
            )
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                hasAppeared = true
            }
            withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
                floatOffset = -5
            }
        }
    }

    private func windowCard(
        id: String,
        icon: String,
        label: String,
        sublabel: String,
        rotation: Double,
        offsetX: CGFloat,
        offsetY: CGFloat,
        delay: Double
    ) -> some View {
        let isHovered = hoveredCard == id

        return VStack(spacing: 0) {
            // Title bar
            HStack(spacing: 5) {
                Circle().fill(Color.red.opacity(0.7)).frame(width: 7, height: 7)
                Circle().fill(Color.yellow.opacity(0.7)).frame(width: 7, height: 7)
                Circle().fill(Color.green.opacity(0.7)).frame(width: 7, height: 7)
                Spacer()
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                Spacer()
                Spacer().frame(width: 26)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider().opacity(0.3)

            // Content area
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(stepColor)

                Text(sublabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .frame(width: 130, height: 100)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.cardBackground)
                .shadow(color: stepColor.opacity(isHovered ? 0.2 : 0.1), radius: isHovered ? 16 : 8, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            isHovered ? stepColor.opacity(0.5) : theme.glassEdgeLight.opacity(0.3),
                            theme.primaryBorder.opacity(0.15),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isHovered ? 1.5 : 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .rotationEffect(.degrees(isHovered ? 0 : rotation))
        .offset(x: offsetX, y: offsetY + floatOffset)
        .scaleEffect(isHovered ? 1.08 : 1.0)
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 20)
        .animation(.spring(response: 0.6, dampingFraction: 0.75).delay(delay), value: hasAppeared)
        .animation(.easeOut(duration: 0.25), value: isHovered)
        .onHover { hovering in
            hoveredCard = hovering ? id : nil
        }
        .zIndex(isHovered ? 1 : 0)
    }
}

// MARK: - Tools Illustration (Hub with Orbiting Icons)

private struct WalkthroughToolsIllustration: View {
    @Environment(\.theme) private var theme
    @State private var hasAppeared = false
    @State private var orbitRotation: Double = 0
    @State private var hoveredIndex: Int? = nil

    private let stepColor = Color.green
    private let tools: [(icon: String, angle: Double)] = [
        ("calendar", 0),
        ("message.fill", 90),
        ("note.text", 180),
        ("folder.fill", 270),
    ]

    var body: some View {
        ZStack {
            // Orbit ring
            Circle()
                .strokeBorder(
                    stepColor.opacity(hasAppeared ? 0.12 : 0),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )
                .frame(width: 150, height: 150)
                .animation(.easeOut(duration: 0.8).delay(0.2), value: hasAppeared)

            // Central hub
            ZStack {
                Circle()
                    .fill(stepColor.opacity(0.15))
                    .frame(width: 70, height: 70)
                    .blur(radius: 15)

                Circle()
                    .fill(theme.cardBackground)
                    .frame(width: 52, height: 52)
                    .overlay(
                        Circle()
                            .strokeBorder(stepColor.opacity(0.3), lineWidth: 1)
                    )

                Image(systemName: "desktopcomputer")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(stepColor)
            }
            .opacity(hasAppeared ? 1 : 0)
            .scaleEffect(hasAppeared ? 1 : 0.5)
            .animation(.spring(response: 0.6, dampingFraction: 0.7), value: hasAppeared)

            // Orbiting tool icons
            ForEach(Array(tools.enumerated()), id: \.offset) { index, skill in
                let isHovered = hoveredIndex == index
                let baseAngle = skill.angle + orbitRotation
                let radians = baseAngle * .pi / 180
                let radius: CGFloat = 75

                ZStack {
                    Circle()
                        .fill(stepColor.opacity(isHovered ? 0.25 : 0.1))
                        .frame(width: 44, height: 44)
                        .blur(radius: 8)

                    Circle()
                        .fill(theme.cardBackground)
                        .frame(width: 36, height: 36)
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    isHovered ? stepColor.opacity(0.5) : theme.primaryBorder.opacity(0.2),
                                    lineWidth: isHovered ? 1.5 : 1
                                )
                        )

                    Image(systemName: skill.icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(stepColor)
                }
                .scaleEffect(isHovered ? 1.15 : 1.0)
                .offset(
                    x: cos(radians) * radius,
                    y: sin(radians) * radius
                )
                .opacity(hasAppeared ? 1 : 0)
                .animation(
                    .spring(response: 0.5, dampingFraction: 0.7).delay(0.15 + Double(index) * 0.08),
                    value: hasAppeared
                )
                .animation(.easeOut(duration: 0.2), value: isHovered)
                .onHover { hovering in
                    hoveredIndex = hovering ? index : nil
                }
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                hasAppeared = true
            }
            withAnimation(.linear(duration: 60).repeatForever(autoreverses: false)) {
                orbitRotation = 360
            }
        }
    }
}

// MARK: - Sandbox Illustration (Terminal in Container)

private struct WalkthroughSandboxIllustration: View {
    @Environment(\.theme) private var theme
    @State private var hasAppeared = false
    @State private var floatOffset: CGFloat = 0
    @State private var cursorVisible = false
    @State private var isHovered = false

    private let stepColor = Color.orange

    var body: some View {
        ZStack {
            // Container outline
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    stepColor.opacity(hasAppeared ? 0.25 : 0),
                    style: StrokeStyle(lineWidth: 1.5, dash: [8, 6])
                )
                .frame(width: 180, height: 130)
                .animation(.easeOut(duration: 0.6).delay(0.1), value: hasAppeared)

            // Ambient glow
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(stepColor.opacity(isHovered ? 0.12 : 0.06))
                .frame(width: 160, height: 110)
                .blur(radius: 20)

            // Terminal window
            VStack(spacing: 0) {
                // Title bar
                HStack(spacing: 5) {
                    Circle().fill(Color.red.opacity(0.7)).frame(width: 6, height: 6)
                    Circle().fill(Color.yellow.opacity(0.7)).frame(width: 6, height: 6)
                    Circle().fill(Color.green.opacity(0.7)).frame(width: 6, height: 6)
                    Spacer()
                    Text("sandbox", bundle: .module)
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                    Spacer()
                    Spacer().frame(width: 22)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(theme.secondaryBackground.opacity(0.6))

                // Terminal content
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("$")
                            .foregroundColor(stepColor)
                        Text("pip install numpy", bundle: .module)
                            .foregroundColor(theme.secondaryText)
                    }
                    .font(.system(size: 10, design: .monospaced))

                    HStack(spacing: 4) {
                        Text("$")
                            .foregroundColor(stepColor)
                        Text("python run.py", bundle: .module)
                            .foregroundColor(theme.secondaryText)

                        Rectangle()
                            .fill(stepColor)
                            .frame(width: 6, height: 12)
                            .opacity(cursorVisible ? 1 : 0)
                    }
                    .font(.system(size: 10, design: .monospaced))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 150, height: 90)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.isDark ? Color.black.opacity(0.6) : theme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isHovered ? stepColor.opacity(0.4) : theme.primaryBorder.opacity(0.2),
                        lineWidth: isHovered ? 1.5 : 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: stepColor.opacity(isHovered ? 0.2 : 0.1), radius: isHovered ? 16 : 8, y: 4)
            .offset(y: floatOffset)
            .scaleEffect(isHovered ? 1.05 : 1.0)

            // Floating icons
            floatingIcon("shippingbox.fill", offset: CGPoint(x: -80, y: -40), delay: 0.2)
            floatingIcon("gearshape.fill", offset: CGPoint(x: 80, y: -35), delay: 0.3)
            floatingIcon("doc.text.fill", offset: CGPoint(x: 75, y: 40), delay: 0.35)
        }
        .opacity(hasAppeared ? 1 : 0)
        .scaleEffect(hasAppeared ? 1 : 0.8)
        .animation(.spring(response: 0.6, dampingFraction: 0.75).delay(0.05), value: hasAppeared)
        .animation(.easeOut(duration: 0.2), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                hasAppeared = true
            }
            withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                floatOffset = -4
            }
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true).delay(0.5)) {
                cursorVisible = true
            }
        }
    }

    private func floatingIcon(_ name: String, offset: CGPoint, delay: Double) -> some View {
        ZStack {
            Circle()
                .fill(stepColor.opacity(0.1))
                .frame(width: 30, height: 30)
                .blur(radius: 6)

            Image(systemName: name)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(stepColor.opacity(0.6))
        }
        .offset(x: offset.x, y: offset.y + floatOffset * 0.6)
        .opacity(hasAppeared ? 1 : 0)
        .scaleEffect(hasAppeared ? 1 : 0.3)
        .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(delay), value: hasAppeared)
    }
}

// MARK: - Personalization Illustration (Colored Orbs + Icons)

private struct WalkthroughPersonalizationIllustration: View {
    @Environment(\.theme) private var theme
    @State private var hasAppeared = false
    @State private var floatOffset: CGFloat = 0
    @State private var hoveredItem: String? = nil

    private let stepColor = Color.purple
    private let orbColors: [Color] = [.blue, .purple, .pink]

    var body: some View {
        HStack(spacing: 24) {
            // Agents: three colored orbs
            agentsOrbs
                .onHover { hovering in
                    hoveredItem = hovering ? "agents" : nil
                }

            // Voice
            iconCard(id: "voice", icon: "mic.fill", color: .indigo, delay: 0.2)

            // Themes
            iconCard(id: "themes", icon: "paintpalette.fill", color: .pink, delay: 0.25)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                hasAppeared = true
            }
            withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                floatOffset = -4
            }
        }
    }

    private var agentsOrbs: some View {
        let isHovered = hoveredItem == "agents"

        return ZStack {
            Circle()
                .fill(stepColor.opacity(isHovered ? 0.25 : 0.15))
                .frame(width: 80, height: 80)
                .blur(radius: isHovered ? 20 : 16)

            HStack(spacing: -10) {
                ForEach(Array(orbColors.enumerated()), id: \.offset) { index, color in
                    miniOrb(color: color, scale: index == 1 ? 1.0 : 0.85, delay: Double(index) * 0.05)
                }
            }
        }
        .offset(y: floatOffset)
        .scaleEffect(isHovered ? 1.1 : 1.0)
        .animation(.easeOut(duration: 0.2), value: isHovered)
    }

    private func miniOrb(color: Color, scale: CGFloat, delay: Double) -> some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            color.opacity(0.95),
                            color,
                        ],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 18 * scale
                    )
                )
                .frame(width: 28 * scale, height: 28 * scale)
                .overlay(
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
                .shadow(color: color.opacity(0.4), radius: 6, y: 2)
        }
        .zIndex(scale >= 1.0 ? 1 : 0)
        .opacity(hasAppeared ? 1 : 0)
        .scaleEffect(hasAppeared ? 1 : 0.5)
        .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(delay), value: hasAppeared)
    }

    private func iconCard(id: String, icon: String, color: Color, delay: Double) -> some View {
        let isHovered = hoveredItem == id

        return ZStack {
            Circle()
                .fill(color.opacity(isHovered ? 0.25 : 0.15))
                .frame(width: 64, height: 64)
                .blur(radius: isHovered ? 16 : 12)

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.cardBackground)
                .frame(width: 56, height: 56)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    isHovered ? color.opacity(0.5) : theme.glassEdgeLight.opacity(0.25),
                                    theme.primaryBorder.opacity(0.15),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: isHovered ? 1.5 : 1
                        )
                )

            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(color)
        }
        .offset(y: floatOffset * (id == "voice" ? 0.7 : 1.3))
        .scaleEffect(isHovered ? 1.12 : 1.0)
        .opacity(hasAppeared ? 1 : 0)
        .scaleEffect(hasAppeared ? 1 : 0.6)
        .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(delay), value: hasAppeared)
        .animation(.easeOut(duration: 0.2), value: isHovered)
        .onHover { hovering in
            hoveredItem = hovering ? id : nil
        }
    }
}

// MARK: - Memory Illustration (Knowledge Graph)

private struct WalkthroughMemoryIllustration: View {
    @Environment(\.theme) private var theme
    @State private var hasAppeared = false
    @State private var pulseScale: CGFloat = 1.0
    @State private var isHovered = false

    private let stepColor = Color.cyan

    private struct GraphNode {
        let icon: String
        let angle: Double
        let radius: CGFloat
        let delay: Double
    }

    private let nodes: [GraphNode] = [
        GraphNode(icon: "person.fill", angle: 30, radius: 72, delay: 0.15),
        GraphNode(icon: "doc.text.fill", angle: 100, radius: 78, delay: 0.25),
        GraphNode(icon: "bubble.left.fill", angle: 170, radius: 70, delay: 0.35),
        GraphNode(icon: "lightbulb.fill", angle: 240, radius: 76, delay: 0.45),
        GraphNode(icon: "link", angle: 310, radius: 74, delay: 0.55),
    ]

    var body: some View {
        ZStack {
            Circle()
                .fill(stepColor.opacity(isHovered ? 0.18 : 0.1))
                .frame(width: 160, height: 160)
                .blur(radius: isHovered ? 50 : 40)
                .scaleEffect(pulseScale)
                .opacity(hasAppeared ? 1 : 0)
                .animation(.easeOut(duration: 0.8), value: hasAppeared)

            ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
                let radians = node.angle * .pi / 180
                let x = cos(radians) * node.radius
                let y = sin(radians) * node.radius

                Path { path in
                    path.move(to: CGPoint(x: 100, y: 100))
                    path.addLine(to: CGPoint(x: 100 + x, y: 100 + y))
                }
                .stroke(stepColor.opacity(0.15), lineWidth: 1)
                .opacity(hasAppeared ? 1 : 0)
                .animation(.easeOut(duration: 0.6).delay(node.delay), value: hasAppeared)
            }
            .frame(width: 200, height: 200)

            ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
                let radians = node.angle * .pi / 180

                ZStack {
                    Circle()
                        .fill(stepColor.opacity(isHovered ? 0.2 : 0.08))
                        .frame(width: 38, height: 38)
                        .blur(radius: 6)

                    Circle()
                        .fill(theme.cardBackground)
                        .frame(width: 30, height: 30)
                        .overlay(
                            Circle()
                                .strokeBorder(stepColor.opacity(0.25), lineWidth: 1)
                        )

                    Image(systemName: node.icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(stepColor)
                }
                .offset(
                    x: cos(radians) * node.radius,
                    y: sin(radians) * node.radius
                )
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.3)
                .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(node.delay), value: hasAppeared)
            }

            ZStack {
                Circle()
                    .fill(stepColor.opacity(0.2))
                    .frame(width: 74, height: 74)
                    .blur(radius: 18)
                    .scaleEffect(pulseScale)

                Circle()
                    .fill(theme.cardBackground)
                    .frame(width: 56, height: 56)
                    .overlay(
                        Circle()
                            .strokeBorder(stepColor.opacity(0.35), lineWidth: 1.5)
                    )

                Image(systemName: "brain")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [stepColor, stepColor.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .opacity(hasAppeared ? 1 : 0)
            .scaleEffect(hasAppeared ? 1 : 0.5)
            .scaleEffect(isHovered ? 1.08 : 1.0)
            .animation(.spring(response: 0.6, dampingFraction: 0.7), value: hasAppeared)
            .animation(.easeOut(duration: 0.2), value: isHovered)
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                hasAppeared = true
            }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                pulseScale = 1.12
            }
        }
    }
}

// MARK: - Privacy Illustration (Shield with Orbiting Data)

private struct WalkthroughPrivacyIllustration: View {
    @Environment(\.theme) private var theme
    @State private var hasAppeared = false
    @State private var glowPulse: CGFloat = 1.0
    @State private var floatOffset: CGFloat = 0
    @State private var orbitAngle: Double = 0
    @State private var isHovered = false

    private let stepColor = Color.teal
    private let dataIcons = ["bubble.left.fill", "doc.fill", "photo.fill"]

    var body: some View {
        ZStack {
            // Ambient glow (pulsing)
            Circle()
                .fill(stepColor.opacity(isHovered ? 0.2 : 0.12))
                .frame(width: 150, height: 150)
                .blur(radius: isHovered ? 50 : 40)
                .scaleEffect(isHovered ? 1.2 : glowPulse)
                .opacity(hasAppeared ? 1 : 0)
                .animation(.easeOut(duration: 0.8), value: hasAppeared)

            // Orbiting data icons (stay within shield boundary)
            ForEach(Array(dataIcons.enumerated()), id: \.offset) { index, icon in
                let angle = (Double(index) * 120 + orbitAngle)
                let radians = angle * .pi / 180
                let radius: CGFloat = 58

                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(stepColor.opacity(0.5))
                    .offset(
                        x: cos(radians) * radius,
                        y: sin(radians) * radius
                    )
                    .opacity(hasAppeared ? 1 : 0)
                    .animation(.easeOut(duration: 0.5).delay(0.3 + Double(index) * 0.1), value: hasAppeared)
            }

            // Shield with lock
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 80, weight: .medium))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            stepColor,
                            stepColor.opacity(0.8),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: stepColor.opacity(0.4), radius: isHovered ? 20 : 12, y: 4)
                .offset(y: floatOffset)
                .scaleEffect(isHovered ? 1.08 : 1.0)
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
            withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                floatOffset = -5
            }
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                glowPulse = 1.15
            }
            withAnimation(.linear(duration: 40).repeatForever(autoreverses: false)) {
                orbitAngle = 360
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
