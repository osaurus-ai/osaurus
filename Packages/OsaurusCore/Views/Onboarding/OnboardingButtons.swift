//
//  OnboardingButtons.swift
//  osaurus
//
//  Buttons used across the onboarding flow:
//    • `OnboardingBrandButton`     — hero CTA (cream/navy, capsule, shimmer)
//    • `OnboardingStatefulButton`  — capsule CTA that mirrors a connect/test result
//    • `OnboardingTextButton`      — tertiary text link (e.g. "Skip for now")
//    • `OnboardingBackButton`      — header back chevron + label
//
//  The header close affordance (`OnboardingCloseButton`) lives in
//  `OnboardingChromeShell.swift` because it's only ever consumed there.
//

import SwiftUI

// MARK: - Stateful Button State

/// Reflects the result of an in-flight connection test for `OnboardingStatefulButton`.
enum OnboardingButtonState: Equatable {
    case idle
    case loading
    case success
    case error(String)
}

// MARK: - Stateful Button

/// Brand-styled button that reflects the result of an in-flight connection test.
/// Idle/loading use `theme.buttonBackground` (cream/navy); success/error switch to
/// their semantic colors. Capsule-shaped to match `OnboardingBrandButton`.
struct OnboardingStatefulButton: View {
    let state: OnboardingButtonState
    let idleTitle: LocalizedStringKey
    let loadingTitle: LocalizedStringKey
    let successTitle: LocalizedStringKey
    let errorTitle: LocalizedStringKey
    let action: () -> Void
    var isEnabled: Bool = true

    @Environment(\.theme) private var theme
    @State private var isHovered = false
    @State private var shimmerPhase: CGFloat = -0.4

    private var currentTitle: LocalizedStringKey {
        switch state {
        case .idle: return idleTitle
        case .loading: return loadingTitle
        case .success: return successTitle
        case .error: return errorTitle
        }
    }

    private var iconName: String? {
        switch state {
        case .idle: return "arrow.right"
        case .loading: return nil
        case .success: return "checkmark"
        case .error: return "arrow.clockwise"
        }
    }

    private var fillColor: Color {
        switch state {
        case .idle, .loading: return shouldDisable ? theme.tertiaryText : theme.primaryText
        case .success: return theme.successColor
        case .error: return theme.errorColor
        }
    }

    private var labelColor: Color {
        switch state {
        case .idle, .loading: return theme.primaryBackground
        case .success, .error: return .white
        }
    }

    private var shouldDisable: Bool { !isEnabled || state == .loading }

    var body: some View {
        Button(action: action) {
            ZStack {
                // Outer glow — kept very soft so the button stays grounded
                // in the footer instead of looking like a floating halo.
                Capsule()
                    .fill(fillColor)
                    .blur(radius: isHovered ? 6 : 4)
                    .opacity(shouldDisable ? 0 : (isHovered ? 0.22 : 0.12))
                    .scaleEffect(isHovered ? 1.02 : 1.0)

                // Main fill
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [fillColor.opacity(1.0), fillColor.opacity(0.9)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                // Sweep shimmer (idle only)
                if state == .idle {
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0),
                                Color.white.opacity(0.28),
                                Color.white.opacity(0),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 50)
                        .offset(x: shimmerPhase * geo.size.width)
                        .blur(radius: 1.5)
                    }
                    .clipShape(Capsule())
                }

                // Top-edge highlight
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.22), Color.clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )

                // Border
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.4), Color.white.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )

                // Label
                HStack(spacing: 8) {
                    if state == .loading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: labelColor))
                            .scaleEffect(0.8)
                    } else if let icon = iconName {
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .bold))
                            .offset(x: state == .idle && isHovered ? 2 : 0)
                    }

                    Text(currentTitle)
                        .font(theme.font(size: 15, weight: .semibold))
                }
                .foregroundColor(labelColor)
            }
            .frame(maxWidth: .infinity)
            .frame(height: OnboardingMetrics.buttonHeight)
            .scaleEffect(isHovered && !shouldDisable ? 1.015 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(shouldDisable)
        .onHover { hovering in
            withAnimation(theme.springAnimation()) { isHovered = hovering && !shouldDisable }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: false)) {
                shimmerPhase = 1.4
            }
        }
        .animation(theme.springAnimation(), value: state)
    }
}

// MARK: - Brand CTA Button

/// Hero welcome button — capsule-shaped, filled with `theme.buttonBackground`
/// (cream on dark, navy on light) so it uses the brand palette rather than
/// the generic accent colour. Includes a sweep-shimmer and lift-on-hover.
struct OnboardingBrandButton: View {
    let title: String
    let action: () -> Void
    var isEnabled: Bool = true

    @Environment(\.theme) private var theme
    @State private var isHovered = false
    @State private var shimmerPhase: CGFloat = -0.4

    private var fillColor: Color { isEnabled ? theme.primaryText : theme.tertiaryText }
    private var labelColor: Color { theme.primaryBackground }

    var body: some View {
        Button(action: action) {
            ZStack {
                // Outer glow — kept very soft so the button stays grounded
                // in the footer instead of looking like a floating halo.
                Capsule()
                    .fill(fillColor)
                    .blur(radius: isHovered ? 6 : 4)
                    .opacity(isHovered ? 0.22 : 0.12)
                    .scaleEffect(isHovered ? 1.02 : 1.0)

                // Main fill
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                fillColor.opacity(1.0),
                                fillColor.opacity(0.9),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                // Sweep shimmer
                GeometryReader { geo in
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0),
                            Color.white.opacity(0.28),
                            Color.white.opacity(0),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 50)
                    .offset(x: shimmerPhase * geo.size.width)
                    .blur(radius: 1.5)
                }
                .clipShape(Capsule())

                // Top-edge inner highlight
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.22), Color.clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )

                // Border
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.4),
                                Color.white.opacity(0.1),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )

                // Label + arrow
                HStack(spacing: 8) {
                    Text(LocalizedStringKey(title), bundle: .module)
                        .font(theme.font(size: 15, weight: .semibold))

                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .bold))
                        .offset(x: isHovered ? 2 : 0)
                }
                .foregroundColor(labelColor)
            }
            .frame(maxWidth: .infinity)
            .frame(height: OnboardingMetrics.buttonHeight)
            .scaleEffect(isHovered ? 1.015 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            withAnimation(theme.springAnimation()) { isHovered = hovering && isEnabled }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: false)) {
                shimmerPhase = 1.4
            }
        }
    }
}

// MARK: - Text Button

/// Text-only tertiary button (e.g. "Skip for now", "Download later").
struct OnboardingTextButton: View {
    let title: String
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(LocalizedStringKey(title), bundle: .module)
                .font(theme.font(size: 13, weight: .medium))
                .foregroundColor(isHovered ? theme.accentColor : theme.secondaryText)
                .underline(isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(theme.animationQuick()) { isHovered = hovering }
        }
    }
}

// MARK: - Back Button

/// Back chevron + label pinned at the leading edge of `OnboardingChromeShell`'s header.
struct OnboardingBackButton: View {
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                Text("Back", bundle: .module)
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
        // Outdent so the chevron visually aligns with the content's leading edge
        // rather than the back button's interior padding.
        .padding(.leading, -12)
        .onHover { hovering in
            withAnimation(theme.animationQuick()) { isHovered = hovering }
        }
    }
}
