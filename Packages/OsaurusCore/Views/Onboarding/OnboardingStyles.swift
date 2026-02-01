//
//  OnboardingStyles.swift
//  osaurus
//
//  Shared styling constants and components for onboarding.
//  Uses the app's theme system for consistent dark/light mode support.
//

import SwiftUI

// MARK: - Onboarding Layout Constants

/// Layout constants for onboarding (theme-independent)
enum OnboardingLayout {
    /// Standard corner radius
    static let cornerRadius: CGFloat = 12

    /// Smaller corner radius for buttons
    static let buttonCornerRadius: CGFloat = 10

    /// Standard padding
    static let padding: CGFloat = 32

    /// Content max width
    static let contentMaxWidth: CGFloat = 440

    /// Window size
    static let windowWidth: CGFloat = 500
    static let windowHeight: CGFloat = 560

    /// Button height for consistency
    static let buttonHeight: CGFloat = 44
}

// MARK: - Onboarding Primary Button

/// Primary action button for onboarding
struct OnboardingPrimaryButton: View {
    let title: String
    let action: () -> Void
    var isEnabled: Bool = true

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(theme.font(size: 15, weight: .semibold))
                .foregroundColor(theme.isDark ? theme.primaryText : .white)
                .frame(maxWidth: .infinity)
                .frame(height: OnboardingLayout.buttonHeight)
                .background(
                    RoundedRectangle(cornerRadius: OnboardingLayout.buttonCornerRadius, style: .continuous)
                        .fill(isEnabled ? theme.accentColor : theme.tertiaryText)
                )
                .shadow(
                    color: isEnabled && isHovered ? theme.accentColor.opacity(0.4) : .clear,
                    radius: 12,
                    y: 4
                )
                .scaleEffect(isHovered && isEnabled ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            withAnimation(theme.animationQuick()) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Onboarding Shimmer Button

/// Futuristic button with animated shimmer effect
struct OnboardingShimmerButton: View {
    let title: String
    let action: () -> Void
    var isEnabled: Bool = true

    @Environment(\.theme) private var theme
    @State private var isHovered = false
    @State private var shimmerPhase: CGFloat = -0.5

    var body: some View {
        Button(action: action) {
            ZStack {
                // Glow behind button
                RoundedRectangle(cornerRadius: OnboardingLayout.buttonCornerRadius, style: .continuous)
                    .fill(theme.accentColor)
                    .blur(radius: isHovered ? 20 : 16)
                    .opacity(isHovered ? 0.5 : 0.35)
                    .scaleEffect(isHovered ? 1.05 : 1.0)

                // Button background with shimmer
                RoundedRectangle(cornerRadius: OnboardingLayout.buttonCornerRadius, style: .continuous)
                    .fill(theme.accentColor)
                    .overlay(shimmerOverlay)
                    .clipShape(RoundedRectangle(cornerRadius: OnboardingLayout.buttonCornerRadius, style: .continuous))

                // Border gradient
                RoundedRectangle(cornerRadius: OnboardingLayout.buttonCornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.3),
                                Color.white.opacity(0.1),
                                Color.white.opacity(0.0),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )

                // Text
                Text(title)
                    .font(theme.font(size: 15, weight: .semibold))
                    .foregroundColor(theme.isDark ? theme.primaryText : .white)
            }
            .frame(height: OnboardingLayout.buttonHeight)
            .scaleEffect(isHovered ? 1.03 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .onAppear {
            startShimmerAnimation()
        }
    }

    private var shimmerOverlay: some View {
        GeometryReader { geometry in
            LinearGradient(
                colors: [
                    Color.white.opacity(0),
                    Color.white.opacity(0.25),
                    Color.white.opacity(0),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: geometry.size.width * 0.6)
            .offset(x: shimmerPhase * geometry.size.width)
            .blur(radius: 2)
        }
        .clipped()
    }

    private func startShimmerAnimation() {
        withAnimation(
            .easeInOut(duration: 2.5)
                .repeatForever(autoreverses: false)
        ) {
            shimmerPhase = 1.5
        }
    }
}

// MARK: - Onboarding Secondary Button

/// Secondary action button for onboarding (outlined style)
struct OnboardingSecondaryButton: View {
    let title: String
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(theme.font(size: 15, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .frame(maxWidth: .infinity)
                .frame(height: OnboardingLayout.buttonHeight)
                .background(
                    RoundedRectangle(cornerRadius: OnboardingLayout.buttonCornerRadius, style: .continuous)
                        .fill(isHovered ? theme.cardBackground : theme.primaryBackground.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: OnboardingLayout.buttonCornerRadius, style: .continuous)
                        .strokeBorder(
                            isHovered ? theme.accentColor.opacity(0.5) : theme.primaryBorder,
                            lineWidth: 1
                        )
                )
                .scaleEffect(isHovered ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Onboarding Text Button

/// Text-only button for onboarding
struct OnboardingTextButton: View {
    let title: String
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(theme.font(size: 13, weight: .medium))
                .foregroundColor(isHovered ? theme.accentColor : theme.secondaryText)
                .underline(isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(theme.animationQuick()) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Onboarding Secure Field

/// Styled secure field for API key entry
struct OnboardingSecureField: View {
    let placeholder: String
    @Binding var text: String
    var label: String? = nil

    @Environment(\.theme) private var theme
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let label = label {
                Text(label.uppercased())
                    .font(theme.font(size: 10, weight: .bold))
                    .foregroundColor(theme.tertiaryText)
                    .tracking(0.5)
            }

            SecureField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .padding(14)
                .focused($isFocused)
                .background(
                    RoundedRectangle(cornerRadius: OnboardingLayout.buttonCornerRadius, style: .continuous)
                        .fill(theme.inputBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: OnboardingLayout.buttonCornerRadius, style: .continuous)
                        .strokeBorder(
                            isFocused ? theme.accentColor : theme.inputBorder,
                            lineWidth: isFocused ? 2 : 1
                        )
                )
        }
    }
}

// MARK: - Onboarding Text Field

/// Styled text field for onboarding forms
struct OnboardingTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var isMonospaced: Bool = false

    @Environment(\.theme) private var theme
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(theme.font(size: 10, weight: .bold))
                .foregroundColor(theme.tertiaryText)
                .tracking(0.5)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(isMonospaced ? .system(size: 14, design: .monospaced) : theme.font(size: 14))
                .foregroundColor(theme.primaryText)
                .padding(12)
                .focused($isFocused)
                .background(
                    RoundedRectangle(cornerRadius: OnboardingLayout.buttonCornerRadius, style: .continuous)
                        .fill(theme.inputBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: OnboardingLayout.buttonCornerRadius, style: .continuous)
                        .strokeBorder(
                            isFocused ? theme.accentColor : theme.inputBorder,
                            lineWidth: isFocused ? 2 : 1
                        )
                )
        }
    }
}

// MARK: - Onboarding Expandable Section

/// Expandable help section
struct OnboardingExpandableSection: View {
    let title: String
    let content: String
    @State private var isExpanded = false

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(theme.springAnimation()) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 13))
                        .foregroundColor(theme.secondaryText)

                    Text(title)
                        .font(theme.font(size: 13, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(content)
                    .font(theme.font(size: 13))
                    .foregroundColor(theme.secondaryText)
                    .lineSpacing(4)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: OnboardingLayout.buttonCornerRadius, style: .continuous)
                .fill(theme.cardBackground)
        )
    }
}

// MARK: - Onboarding Step Indicator

/// Step indicator for walkthrough
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

// MARK: - Glass Card

/// Glass card with gradient border for onboarding options
struct OnboardingGlassCard<Content: View>: View {
    let isSelected: Bool
    let content: Content

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    init(isSelected: Bool = false, @ViewBuilder content: () -> Content) {
        self.isSelected = isSelected
        self.content = content()
    }

    var body: some View {
        content
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: OnboardingLayout.cornerRadius, style: .continuous))
            .overlay(cardBorder)
            .shadow(
                color: theme.shadowColor.opacity(isHovered ? 0.15 : 0.08),
                radius: isHovered ? 16 : 8,
                y: isHovered ? 6 : 3
            )
            .scaleEffect(isHovered ? 1.01 : 1.0)
            .onHover { hovering in
                withAnimation(theme.animationQuick()) {
                    isHovered = hovering
                }
            }
    }

    private var cardBackground: some View {
        ZStack {
            if theme.glassEnabled {
                Rectangle().fill(.ultraThinMaterial)
            }

            theme.cardBackground.opacity(theme.glassEnabled ? 0.85 : 1.0)

            // Subtle accent gradient
            LinearGradient(
                colors: [
                    theme.accentColor.opacity(theme.isDark ? 0.08 : 0.04),
                    Color.clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: OnboardingLayout.cornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        isSelected
                            ? theme.accentColor
                            : (isHovered ? theme.accentColor.opacity(0.4) : theme.glassEdgeLight.opacity(0.3)),
                        isSelected
                            ? theme.accentColor.opacity(0.6)
                            : theme.primaryBorder.opacity(0.4),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: isSelected ? 2 : 1
            )
    }
}

// MARK: - Shimmer Progress Bar

/// Progress bar with shimmer effect and glow
struct OnboardingShimmerBar: View {
    let progress: Double
    let color: Color
    var height: CGFloat = 8

    @State private var shimmerOffset: CGFloat = -1

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(color.opacity(0.15))
                    .frame(height: height)

                // Progress fill with gradient
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(
                        LinearGradient(
                            colors: [
                                color.opacity(0.8),
                                color,
                                color.opacity(0.8),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, geometry.size.width * progress), height: height)
                    .overlay(shimmerOverlay(width: geometry.size.width * progress))
                    .clipShape(RoundedRectangle(cornerRadius: height / 2))
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: progress)

                // Glow at progress edge
                if progress > 0 && progress < 1 {
                    Circle()
                        .fill(color)
                        .frame(width: height * 2.5, height: height * 2.5)
                        .blur(radius: 6)
                        .opacity(0.6)
                        .offset(x: max(0, geometry.size.width * progress - height))
                }
            }
        }
        .frame(height: height)
        .onAppear {
            startShimmerAnimation()
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

    private func startShimmerAnimation() {
        withAnimation(
            .easeInOut(duration: 1.8)
                .repeatForever(autoreverses: false)
        ) {
            shimmerOffset = 2
        }
    }
}

// MARK: - Option Card

/// Selectable option card with glass styling
struct OnboardingOptionCard: View {
    let icon: String
    let title: String
    let description: String
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            OnboardingGlassCard(isSelected: isSelected) {
                HStack(spacing: 16) {
                    // Icon with glow
                    ZStack {
                        if isSelected {
                            Circle()
                                .fill(theme.accentColor)
                                .blur(radius: 8)
                                .frame(width: 40, height: 40)
                        }

                        Circle()
                            .fill(isSelected ? theme.accentColor : theme.cardBackground)
                            .frame(width: 48, height: 48)

                        Image(systemName: icon)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(isSelected ? .white : theme.secondaryText)
                    }

                    // Text content
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(theme.font(size: 15, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(description)
                            .font(theme.font(size: 13))
                            .foregroundColor(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(2)
                    }

                    Spacer(minLength: 12)

                    // Selection indicator
                    ZStack {
                        Circle()
                            .strokeBorder(
                                isSelected ? theme.accentColor : theme.primaryBorder,
                                lineWidth: isSelected ? 6 : 1.5
                            )
                            .frame(width: 22, height: 22)

                        if isSelected {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 8, height: 8)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - View Extension for Onboarding Background

extension View {
    /// Apply onboarding background styling with theme
    func onboardingBackground(theme: ThemeProtocol) -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.primaryBackground)
    }
}
