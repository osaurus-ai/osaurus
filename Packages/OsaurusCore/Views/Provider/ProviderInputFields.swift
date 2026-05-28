//
//  ProviderInputFields.swift
//  osaurus
//
//  Themed text/secure inputs shared between the provider edit sheet
//  (Settings) and the credential prompt sheet (chat-driven onboarding).
//  Pulls the same `inputBackground`, focus accent, placeholder, and
//  monospace treatment so the chat-driven flow looks identical to the
//  one in Settings.
//

import SwiftUI

/// Labelled, themed text field used in provider sheets. Wraps a plain
/// `TextField` with the standard Osaurus input chrome (rounded
/// background, focus accent, monospace option for keys/hosts).
struct ProviderTextField: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let label: String
    let placeholder: String
    @Binding var text: String
    var isMonospaced: Bool = false

    @State private var isFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(label), bundle: .module)
                .textCase(.uppercase)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(themeManager.currentTheme.tertiaryText)
                .tracking(0.5)

            HStack(spacing: 10) {
                ZStack(alignment: .leading) {
                    if text.isEmpty {
                        Text(LocalizedStringKey(placeholder), bundle: .module)
                            .font(.system(size: 13, design: isMonospaced ? .monospaced : .default))
                            .foregroundColor(themeManager.currentTheme.placeholderText)
                            .allowsHitTesting(false)
                    }

                    TextField(
                        "",
                        text: $text,
                        onEditingChanged: { editing in
                            withAnimation(.easeOut(duration: 0.15)) {
                                isFocused = editing
                            }
                        }
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: isMonospaced ? .monospaced : .default))
                    .foregroundColor(themeManager.currentTheme.primaryText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(themeManager.currentTheme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                isFocused
                                    ? themeManager.currentTheme.accentColor.opacity(0.5)
                                    : themeManager.currentTheme.inputBorder,
                                lineWidth: isFocused ? 1.5 : 1
                            )
                    )
            )
        }
    }
}

/// Themed secure field used in provider sheets. Same chrome as
/// `ProviderTextField`, always monospaced (it's almost always an API
/// key paste target).
struct ProviderSecureField: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(LocalizedStringKey(placeholder), bundle: .module)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(themeManager.currentTheme.placeholderText)
                        .allowsHitTesting(false)
                }

                SecureField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.primaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(themeManager.currentTheme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                )
        )
    }
}
