//
//  HuggingFaceTokenViews.swift
//  osaurus
//
//  UI for the optional Hugging Face access token. Anonymous downloads are
//  rate-limited hard by Hugging Face; a free token raises those limits and
//  unlocks gated repos. Two surfaces: a one-time prompt offered when the
//  user starts a download without a token, and a card on the Models →
//  Catalog tab for managing an already-configured token.
//

import SwiftUI

// MARK: - Download-time prompt

/// One-time sheet offered when a download starts and no token is
/// configured. Either path (saving a token or continuing without one)
/// marks the prompt dismissed and starts the download.
struct HuggingFaceTokenPromptSheet: View {
    @Environment(\.theme) private var theme

    /// Starts the pending download; called after the user's choice lands.
    let onContinue: () -> Void

    @State private var tokenInput: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text("🤗")
                    .font(.system(size: 24))
                Text("Faster downloads with a Hugging Face token", bundle: .module)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)
            }

            Text(
                "Downloads without a token are rate-limited by Hugging Face and can be slow or fail under load.",
                bundle: .module
            )
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                stepRow(1, text: Text("Sign in (or sign up free) at huggingface.co", bundle: .module))
                // Markdown link deep-links straight to Hugging Face's
                // new-token form with the Read type preselected.
                stepRow(
                    2,
                    text: Text(
                        .init(
                            L(
                                "Create a Read token using [this link](https://huggingface.co/settings/tokens/new?tokenType=read)"
                            )
                        )
                    )
                )
                stepRow(3, text: Text("Paste it below. It stays in your macOS Keychain", bundle: .module))
            }

            HuggingFaceTokenField(tokenInput: $tokenInput) { saveAndContinue() }

            HStack(spacing: 12) {
                Button(action: continueWithout) {
                    Text("Continue without token", bundle: .module)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
                .buttonStyle(PlainButtonStyle())

                Spacer()

                Button(action: saveAndContinue) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 13))
                        Text("Save & Download", bundle: .module)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.accentColor.opacity(trimmedToken.isEmpty ? 0.4 : 1.0))
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(trimmedToken.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(theme.primaryBackground)
    }

    private func stepRow(_ number: Int, text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(theme.accentColor)
                .frame(width: 16, height: 16)
                .background(Circle().fill(theme.accentColor.opacity(0.15)))
            text
                .font(.system(size: 12))
                .foregroundColor(theme.primaryText)
                .tint(theme.accentColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var trimmedToken: String {
        tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveAndContinue() {
        guard !trimmedToken.isEmpty else { return }
        HuggingFaceAuth.setToken(trimmedToken)
        HuggingFaceAuth.markPromptDismissed()
        onContinue()
    }

    private func continueWithout() {
        HuggingFaceAuth.markPromptDismissed()
        onContinue()
    }
}

// MARK: - Catalog tab card

/// Shown at the top of Models → Catalog when a token is configured.
/// Lets the user replace or remove it.
struct HuggingFaceAccountCard: View {
    @Environment(\.theme) private var theme

    /// Fired after the token is removed so the host can hide the card.
    let onRemoved: () -> Void

    @State private var isEditing = false
    @State private var tokenInput: String = ""
    @State private var statusText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("🤗")
                    .font(.system(size: 16))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Hugging Face token connected", bundle: .module)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(
                        "Model downloads use your account's higher rate limits and gated-repo access.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                }

                Spacer(minLength: 8)

                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        isEditing.toggle()
                        tokenInput = ""
                        statusText = nil
                    }
                } label: {
                    Text(isEditing ? "Cancel" : "Replace…", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.tertiaryBackground.opacity(0.6))
                        )
                }
                .buttonStyle(PlainButtonStyle())

                Button {
                    HuggingFaceAuth.setToken(nil)
                    onRemoved()
                } label: {
                    Text("Remove", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.red.opacity(0.12))
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }

            if isEditing {
                HStack(spacing: 8) {
                    HuggingFaceTokenField(tokenInput: $tokenInput) { replaceToken() }

                    Button(action: replaceToken) {
                        Text("Save", bundle: .module)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(
                                        theme.accentColor.opacity(trimmedToken.isEmpty ? 0.4 : 1.0)
                                    )
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(trimmedToken.isEmpty)
                }
            }

            if let statusText {
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.tertiaryBackground.opacity(0.4))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.cardBorder.opacity(0.6), lineWidth: 1)
                )
        )
    }

    private var trimmedToken: String {
        tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func replaceToken() {
        guard !trimmedToken.isEmpty else { return }
        HuggingFaceAuth.setToken(trimmedToken)
        withAnimation(.easeOut(duration: 0.15)) {
            isEditing = false
            tokenInput = ""
            statusText = L("Token updated.")
        }
    }
}

// MARK: - Shared token field

/// Masked token input shared by the prompt sheet and the account card.
struct HuggingFaceTokenField: View {
    @Environment(\.theme) private var theme

    @Binding var tokenInput: String
    let onSubmit: () -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            if tokenInput.isEmpty {
                Text(verbatim: "hf_…")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(theme.placeholderText)
                    .allowsHitTesting(false)
            }
            SecureField("", text: $tokenInput)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .onSubmit(onSubmit)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
        )
    }
}
