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

// MARK: - Onboarding Style Constants

/// Centralized styling constants for onboarding (similar to ToastStyle)
enum OnboardingStyle {
    // MARK: Animation
    static let appearDelay: Double = 0.1

    // MARK: Layout
    static let bottomButtonPadding: CGFloat = 40
    static let headerTopPadding: CGFloat = 30
    static let backButtonHorizontalPadding: CGFloat = 35

    // MARK: Glass Background
    static let glassOpacityDark: Double = 0.78
    static let glassOpacityLight: Double = 0.88

    // MARK: Accent Gradient
    static let accentGradientOpacityDark: Double = 0.08
    static let accentGradientOpacityLight: Double = 0.05

    // MARK: Border
    static let edgeLightOpacityDark: Double = 0.22
    static let edgeLightOpacityLight: Double = 0.35
    static let borderOpacityDark: Double = 0.18
    static let borderOpacityLight: Double = 0.28

    // MARK: Accent Edge
    static let accentEdgeHoverOpacity: Double = 0.18
    static let accentEdgeNormalOpacity: Double = 0.10

    // MARK: Button Glow
    static let buttonGlowRadiusNormal: CGFloat = 12
    static let buttonGlowRadiusHover: CGFloat = 16
    static let buttonGlowOpacityNormal: Double = 0.25
    static let buttonGlowOpacityHover: Double = 0.4
}

// MARK: - Onboarding Primary Button

/// Primary action button for onboarding with depth and polish
struct OnboardingPrimaryButton: View {
    let title: String
    let action: () -> Void
    var isEnabled: Bool = true

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    private var buttonColor: Color {
        isEnabled ? theme.accentColor : theme.tertiaryText
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                // Subtle glow behind button (always present, intensifies on hover)
                RoundedRectangle(cornerRadius: OnboardingLayout.buttonCornerRadius, style: .continuous)
                    .fill(buttonColor)
                    .blur(
                        radius: isHovered
                            ? OnboardingStyle.buttonGlowRadiusHover
                            : OnboardingStyle.buttonGlowRadiusNormal
                    )
                    .opacity(
                        isEnabled
                            ? (isHovered
                                ? OnboardingStyle.buttonGlowOpacityHover : OnboardingStyle.buttonGlowOpacityNormal)
                            : 0
                    )

                // Main button with inner gradient for depth
                RoundedRectangle(cornerRadius: OnboardingLayout.buttonCornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                buttonColor.opacity(1.0),
                                buttonColor,
                                buttonColor.opacity(0.85),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                // Inner highlight at top edge
                RoundedRectangle(cornerRadius: OnboardingLayout.buttonCornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isEnabled ? 0.2 : 0.1),
                                Color.clear,
                            ],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )

                // Gradient border for dimension
                RoundedRectangle(cornerRadius: OnboardingLayout.buttonCornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.25),
                                Color.white.opacity(0.1),
                                Color.black.opacity(0.1),
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
            .frame(maxWidth: .infinity)
            .frame(height: OnboardingLayout.buttonHeight)
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

// MARK: - Onboarding Stateful Button

/// Button state for connection testing
enum OnboardingButtonState: Equatable {
    case idle
    case loading
    case success
    case error(String)

    static func == (lhs: OnboardingButtonState, rhs: OnboardingButtonState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.success, .success):
            return true
        case (.error(let lMsg), .error(let rMsg)):
            return lMsg == rMsg
        default:
            return false
        }
    }
}

/// Stateful button that reflects connection test results with depth and polish
struct OnboardingStatefulButton: View {
    let state: OnboardingButtonState
    let idleTitle: String
    let loadingTitle: String
    let successTitle: String
    let errorTitle: String
    let action: () -> Void
    var isEnabled: Bool = true

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    private var currentTitle: String {
        switch state {
        case .idle: return idleTitle
        case .loading: return loadingTitle
        case .success: return successTitle
        case .error: return errorTitle
        }
    }

    private var backgroundColor: Color {
        switch state {
        case .idle: return theme.accentColor
        case .loading: return theme.accentColor
        case .success: return theme.successColor
        case .error: return theme.errorColor
        }
    }

    private var iconName: String? {
        switch state {
        case .idle: return nil
        case .loading: return nil
        case .success: return "checkmark"
        case .error: return "arrow.clockwise"
        }
    }

    private var shouldDisable: Bool {
        !isEnabled || state == .loading
    }

    private var buttonColor: Color {
        shouldDisable ? theme.tertiaryText : backgroundColor
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                // Subtle glow behind button
                RoundedRectangle(cornerRadius: OnboardingLayout.buttonCornerRadius, style: .continuous)
                    .fill(buttonColor)
                    .blur(
                        radius: isHovered
                            ? OnboardingStyle.buttonGlowRadiusHover
                            : OnboardingStyle.buttonGlowRadiusNormal
                    )
                    .opacity(
                        !shouldDisable
                            ? (isHovered
                                ? OnboardingStyle.buttonGlowOpacityHover : OnboardingStyle.buttonGlowOpacityNormal)
                            : 0
                    )

                // Main button with inner gradient for depth
                RoundedRectangle(cornerRadius: OnboardingLayout.buttonCornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                buttonColor.opacity(1.0),
                                buttonColor,
                                buttonColor.opacity(0.85),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                // Inner highlight at top edge
                RoundedRectangle(cornerRadius: OnboardingLayout.buttonCornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(!shouldDisable ? 0.2 : 0.1),
                                Color.clear,
                            ],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )

                // Gradient border for dimension
                RoundedRectangle(cornerRadius: OnboardingLayout.buttonCornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.25),
                                Color.white.opacity(0.1),
                                Color.black.opacity(0.1),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )

                // Content
                HStack(spacing: 8) {
                    if state == .loading {
                        ProgressView()
                            .progressViewStyle(
                                CircularProgressViewStyle(tint: theme.isDark ? theme.primaryText : .white)
                            )
                            .scaleEffect(0.8)
                    } else if let icon = iconName {
                        Image(systemName: icon)
                            .font(.system(size: 13, weight: .semibold))
                    }

                    Text(currentTitle)
                        .font(theme.font(size: 15, weight: .semibold))
                }
                .foregroundColor(theme.isDark ? theme.primaryText : .white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: OnboardingLayout.buttonHeight)
            .scaleEffect(isHovered && !shouldDisable ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(shouldDisable)
        .onHover { hovering in
            withAnimation(theme.animationQuick()) {
                isHovered = hovering
            }
        }
        .animation(theme.springAnimation(), value: state)
    }
}

// MARK: - Onboarding Shimmer Button

/// Polished button with animated shimmer effect
struct OnboardingShimmerButton: View {
    let title: String
    let action: () -> Void
    var isEnabled: Bool = true

    @Environment(\.theme) private var theme
    @State private var isHovered = false
    @State private var shimmerPhase: CGFloat = -0.3

    private var buttonColor: Color {
        isEnabled ? theme.accentColor : theme.tertiaryText
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                // Enhanced glow behind button
                RoundedRectangle(cornerRadius: OnboardingLayout.buttonCornerRadius, style: .continuous)
                    .fill(buttonColor)
                    .blur(radius: isHovered ? 18 : 14)
                    .opacity(isEnabled ? (isHovered ? 0.5 : 0.35) : 0)
                    .scaleEffect(isHovered ? 1.03 : 1.0)

                // Main button with inner gradient for depth
                RoundedRectangle(cornerRadius: OnboardingLayout.buttonCornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                buttonColor.opacity(1.0),
                                buttonColor,
                                buttonColor.opacity(0.85),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(shimmerOverlay)
                    .clipShape(RoundedRectangle(cornerRadius: OnboardingLayout.buttonCornerRadius, style: .continuous))

                // Inner highlight at top edge
                RoundedRectangle(cornerRadius: OnboardingLayout.buttonCornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isEnabled ? 0.2 : 0.1),
                                Color.clear,
                            ],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )

                // Enhanced gradient border
                RoundedRectangle(cornerRadius: OnboardingLayout.buttonCornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.35),
                                Color.white.opacity(0.15),
                                Color.black.opacity(0.05),
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
            .frame(maxWidth: .infinity)
            .frame(height: OnboardingLayout.buttonHeight)
            .scaleEffect(isHovered && isEnabled ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            withAnimation(theme.animationQuick()) {
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
                    Color.white.opacity(0.35),
                    Color.white.opacity(0),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 40)  // Fixed narrow width for crisp shimmer
            .offset(x: shimmerPhase * geometry.size.width)
            .blur(radius: 1)
        }
        .clipped()
    }

    private func startShimmerAnimation() {
        withAnimation(
            .easeInOut(duration: 1.8)  // Faster, smoother animation
                .repeatForever(autoreverses: false)
        ) {
            shimmerPhase = 1.3
        }
    }
}

// MARK: - Onboarding Secondary Button

/// Secondary action button for onboarding with glass effect and gradient border
struct OnboardingSecondaryButton: View {
    let title: String
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                // Glass background layer
                if theme.glassEnabled {
                    RoundedRectangle(cornerRadius: OnboardingLayout.buttonCornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                }

                // Background fill
                RoundedRectangle(cornerRadius: OnboardingLayout.buttonCornerRadius, style: .continuous)
                    .fill(
                        isHovered
                            ? theme.cardBackground.opacity(theme.glassEnabled ? 0.9 : 1.0)
                            : theme.cardBackground.opacity(theme.glassEnabled ? 0.6 : 0.8)
                    )

                // Subtle accent gradient on hover
                RoundedRectangle(cornerRadius: OnboardingLayout.buttonCornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.accentColor.opacity(isHovered ? 0.08 : 0.03),
                                Color.clear,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                // Gradient border (like ToastBorder)
                RoundedRectangle(cornerRadius: OnboardingLayout.buttonCornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                isHovered
                                    ? theme.accentColor.opacity(0.5)
                                    : theme.glassEdgeLight.opacity(theme.isDark ? 0.25 : 0.35),
                                theme.primaryBorder.opacity(theme.isDark ? 0.3 : 0.4),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )

                // Text
                Text(title)
                    .font(theme.font(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)
            }
            .frame(maxWidth: .infinity)
            .frame(height: OnboardingLayout.buttonHeight)
            .scaleEffect(isHovered ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(theme.animationQuick()) {
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

// MARK: - Onboarding Back Button

/// Reusable back button with consistent styling across onboarding views
struct OnboardingBackButton: View {
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        HStack {
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Back")
                        .font(theme.font(size: 13, weight: .medium))
                }
                .foregroundColor(isHovered ? theme.accentColor : theme.secondaryText)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isHovered ? theme.cardBackground.opacity(0.6) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(theme.animationQuick()) {
                    isHovered = hovering
                }
            }

            Spacer()
        }
        .padding(.leading, -12)
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

/// Glass card with gradient border and accent edge for onboarding options
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

            theme.cardBackground.opacity(
                theme.glassEnabled
                    ? (theme.isDark ? OnboardingStyle.glassOpacityDark : OnboardingStyle.glassOpacityLight)
                    : 1.0
            )

            // Subtle accent gradient
            LinearGradient(
                colors: [
                    theme.accentColor.opacity(
                        theme.isDark
                            ? OnboardingStyle.accentGradientOpacityDark
                            : OnboardingStyle.accentGradientOpacityLight
                    ),
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
                            : (isHovered
                                ? theme.accentColor.opacity(0.4)
                                : theme.glassEdgeLight.opacity(
                                    theme.isDark
                                        ? OnboardingStyle.edgeLightOpacityDark
                                        : OnboardingStyle.edgeLightOpacityLight
                                )),
                        isSelected
                            ? theme.accentColor.opacity(0.6)
                            : theme.primaryBorder.opacity(
                                theme.isDark
                                    ? OnboardingStyle.borderOpacityDark
                                    : OnboardingStyle.borderOpacityLight
                            ),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: isSelected ? 2 : 1
            )
            .overlay(accentEdge)
    }

    /// Accent edge highlight (like ToastBorder)
    private var accentEdge: some View {
        RoundedRectangle(cornerRadius: OnboardingLayout.cornerRadius, style: .continuous)
            .strokeBorder(
                theme.accentColor.opacity(
                    isHovered || isSelected
                        ? OnboardingStyle.accentEdgeHoverOpacity
                        : OnboardingStyle.accentEdgeNormalOpacity
                ),
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

                // Glow at progress edge (animated smoothly)
                Circle()
                    .fill(color)
                    .frame(width: height * 2.5, height: height * 2.5)
                    .blur(radius: 6)
                    .opacity(progress > 0 && progress < 1 ? 0.6 : 0)
                    .offset(x: max(0, geometry.size.width * progress - height))
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: progress)
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
