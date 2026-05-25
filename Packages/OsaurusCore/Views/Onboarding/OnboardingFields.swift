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

// MARK: - Field Label (sentence-case caption)

/// Compact caption rendered above a form field. Sentence case + semibold
/// at 11pt — the previous ALL-CAPS + tracked treatment made every label
/// (`"API Key"`, `"Host"`, `"Port"`, `"Memory"`) read as an intimidating
/// micro-header. The form is friendlier without it.
private struct OnboardingFieldLabel: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(LocalizedStringKey(text), bundle: .module)
            .font(theme.font(size: 11, weight: .semibold))
            .foregroundColor(theme.tertiaryText)
    }
}

// MARK: - Secure Field

/// Styled secure field for API key entry.
///
/// Default font is the theme's regular size so the field doesn't immediately
/// read as "developer secret". Opt into `isMonospaced` for keys where a
/// fixed-width treatment is genuinely helpful (e.g. inspecting a pasted
/// hex token character-by-character).
struct OnboardingSecureField: View {
    let placeholder: String
    @Binding var text: String
    var label: String? = nil
    var isMonospaced: Bool = false

    @Environment(\.theme) private var theme
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let label = label {
                OnboardingFieldLabel(text: label)
            }

            SecureField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(isMonospaced ? .system(size: 14, design: .monospaced) : theme.font(size: 14))
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
            if !label.isEmpty {
                OnboardingFieldLabel(text: label)
            }

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

// MARK: - Multi-line Text Editor

/// Multi-line text editor with the same chrome as `OnboardingTextField`.
/// Uses a placeholder overlay since `TextEditor` has no native one.
///
/// The editor renders at a **fixed** `height`; longer content scrolls
/// inside the editor instead of growing the chrome and pushing surrounding
/// form rows around.
struct OnboardingTextEditor: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var isMonospaced: Bool = true
    var height: CGFloat = 100

    @Environment(\.theme) private var theme
    @FocusState private var isFocused: Bool

    private var font: Font {
        isMonospaced ? .system(size: 13, design: .monospaced) : theme.font(size: 14)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !label.isEmpty {
                OnboardingFieldLabel(text: label)
            }

            // `height` sizes the chrome — not the inner `TextEditor` —
            // so the field's outer footprint is deterministic. Applying
            // `.frame(height:)` to the editor itself and then wrapping
            // it in `.padding(...)` causes the underlying NSTextView's
            // last-line descender to be clipped against its own scroll
            // clip rect, which read as "textarea cuts off at the bottom".
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(LocalizedStringKey(placeholder), bundle: .module)
                        .font(font)
                        .foregroundColor(theme.placeholderText)
                        .padding(.top, 8)
                        .padding(.leading, 14)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(font)
                    .foregroundColor(theme.primaryText)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .focused($isFocused)
            }
            .frame(height: height)
            .onboardingFieldChrome(isFocused: isFocused)
        }
    }
}
