//
//  OnboardingFields.swift
//  osaurus
//
//  Form fields used by the API setup view (and any future onboarding form).
//

import SwiftUI

// MARK: - Field Box (Shared Input Background)

/// Shared rounded-input chrome used by both `OnboardingSecureField` and
/// `OnboardingTextField`.
private struct OnboardingFieldChrome: ViewModifier {
    let isFocused: Bool
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: OnboardingMetrics.buttonCornerRadius,
            style: .continuous
        )
        return
            content
            .background(shape.fill(theme.inputBackground))
            .overlay(
                shape.strokeBorder(
                    isFocused ? theme.accentColor : theme.inputBorder,
                    lineWidth: isFocused ? 2 : 1
                )
            )
    }
}

private extension View {
    func onboardingFieldChrome(isFocused: Bool) -> some View {
        modifier(OnboardingFieldChrome(isFocused: isFocused))
    }
}

// MARK: - Field Label (uppercase tracked caption)

private struct OnboardingFieldLabel: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(LocalizedStringKey(text), bundle: .module)
            .textCase(.uppercase)
            .font(theme.font(size: 10, weight: .bold))
            .foregroundColor(theme.tertiaryText)
            .tracking(0.5)
    }
}

// MARK: - Secure Field

/// Styled secure field for API key entry.
struct OnboardingSecureField: View {
    let placeholder: String
    @Binding var text: String
    var label: String? = nil

    @Environment(\.theme) private var theme
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let label = label {
                OnboardingFieldLabel(text: label)
            }

            SecureField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .padding(14)
                .focused($isFocused)
                .onboardingFieldChrome(isFocused: isFocused)
        }
    }
}

// MARK: - Text Field

/// Styled text field for onboarding forms.
struct OnboardingTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var isMonospaced: Bool = false

    @Environment(\.theme) private var theme
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            OnboardingFieldLabel(text: label)

            TextField(text: $text, prompt: Text(LocalizedStringKey(placeholder), bundle: .module)) {
                Text(LocalizedStringKey(placeholder), bundle: .module)
            }
            .textFieldStyle(.plain)
            .font(isMonospaced ? .system(size: 14, design: .monospaced) : theme.font(size: 14))
            .foregroundColor(theme.primaryText)
            .padding(12)
            .focused($isFocused)
            .onboardingFieldChrome(isFocused: isFocused)
        }
    }
}
