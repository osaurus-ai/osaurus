//
//  HuggingFaceTokenViews.swift
//  osaurus
//
//  UI for the optional Hugging Face access token. Anonymous downloads are
//  rate-limited hard by Hugging Face; a free token raises those limits and
//  unlocks gated repos. A single card on the Models → Catalog tab is the
//  permanent home: it offers an Add flow when no token is set and lets the
//  user replace or remove an existing one. The Add button opens the token
//  sheet below.
//

import SwiftUI

// MARK: - Add-token sheet

/// Sheet presented from the Catalog card's Add button. Explains the
/// benefit, links to Hugging Face's Read-token form, and saves the pasted
/// token to the Keychain.
struct HuggingFaceTokenPromptSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    /// Called after a token is saved so the host can reflect the new state.
    let onSaved: () -> Void

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

            HuggingFaceTokenField(tokenInput: $tokenInput) { save() }

            HStack(spacing: 12) {
                Button(action: { dismiss() }) {
                    Text("Cancel", bundle: .module)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
                .buttonStyle(PlainButtonStyle())

                Spacer()

                Button(action: save) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 13))
                        Text("Save token", bundle: .module)
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

    private func save() {
        guard !trimmedToken.isEmpty else { return }
        HuggingFaceAuth.setToken(trimmedToken)
        onSaved()
        dismiss()
    }
}

// MARK: - Catalog tab card

/// Permanent card at the top of Models → Catalog. Offers an Add flow when
/// no token is configured, and Replace / Remove when one is. Owns its own
/// token-presence state so it can flip in place.
struct HuggingFaceTokenCard: View {
    @Environment(\.theme) private var theme

    /// Token presence, seeded synchronously at init. `HuggingFaceAuth`
    /// caches the token in memory and is preloaded off-main at app launch,
    /// so this read is warm by the time Models opens — no keychain hit on
    /// the render path, and no async flash. The value only changes through
    /// this card's own actions, which set it directly.
    @State private var hasToken: Bool
    @State private var showAddSheet = false
    @State private var isReplacing = false
    @State private var replaceInput: String = ""

    init() {
        _hasToken = State(initialValue: HuggingFaceAuth.hasToken)
    }

    var body: some View {
        Group {
            if hasToken {
                connectedCard
            } else {
                disconnectedCard
            }
        }
        .sheet(isPresented: $showAddSheet) {
            HuggingFaceTokenPromptSheet {
                hasToken = true
            }
            .environment(\.theme, theme)
        }
    }

    // MARK: Disconnected

    private var disconnectedCard: some View {
        cardSurface {
            HStack(spacing: 10) {
                Text("🤗")
                    .font(.system(size: 16))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Faster model downloads", bundle: .module)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(
                        "A free Hugging Face token raises rate limits so models download faster.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button { showAddSheet = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Add token", bundle: .module)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.accentColor))
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    // MARK: Connected

    private var connectedCard: some View {
        cardSurface {
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
                            isReplacing.toggle()
                            replaceInput = ""
                        }
                    } label: {
                        Text(isReplacing ? "Cancel" : "Replace…", bundle: .module)
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
                        withAnimation(.easeOut(duration: 0.15)) {
                            isReplacing = false
                            hasToken = false
                        }
                    } label: {
                        Text("Remove", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.red)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.12)))
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                if isReplacing {
                    HStack(spacing: 8) {
                        HuggingFaceTokenField(tokenInput: $replaceInput) { replaceToken() }

                        Button(action: replaceToken) {
                            Text("Save", bundle: .module)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(
                                            theme.accentColor.opacity(
                                                trimmedReplace.isEmpty ? 0.4 : 1.0
                                            )
                                        )
                                )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(trimmedReplace.isEmpty)
                    }
                }
            }
        }
    }

    private func cardSurface<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
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

    private var trimmedReplace: String {
        replaceInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func replaceToken() {
        guard !trimmedReplace.isEmpty else { return }
        HuggingFaceAuth.setToken(trimmedReplace)
        withAnimation(.easeOut(duration: 0.15)) {
            isReplacing = false
            replaceInput = ""
        }
    }
}

// MARK: - Shared token field

/// Masked token input shared by the add sheet and the card's replace row.
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
