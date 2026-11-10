//
//  HuggingFaceTokenViews.swift
//  osaurus
//
//  UI for the optional Hugging Face access token. Anonymous downloads are
//  rate-limited hard by Hugging Face; a free token raises those limits and
//  unlocks gated repos. A banner above the Language catalog offers the Add
//  flow while no token is set; Vault → App Keys manages a saved one.
//

import SwiftUI

// MARK: - Add-token sheet

/// Sheet presented from the catalog banner's Add button. Explains the
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
                    .font(SettingsFont.pageTitle)
                Text("Faster downloads with a Hugging Face token", bundle: .module)
                    .font(SettingsFont.cardTitle)
                    .foregroundColor(theme.text.primary)
            }

            Text(
                "Downloads without a token are rate-limited by Hugging Face and can be slow or fail under load.",
                bundle: .module
            )
            .font(SettingsFont.caption)
            .foregroundColor(theme.text.secondary)
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
                }
                .assignedSettingsButtonStyle(.secondary)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(action: save) {
                    Label(L("Save token"), systemImage: "checkmark.circle")
                }
                .assignedSettingsButtonStyle(.primary)
                .disabled(trimmedToken.isEmpty)
            }
        }
        .padding(theme.space.s24)
        .frame(width: 460)
        .background(theme.surface.canvas)
    }

    private func stepRow(_ number: Int, text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(SettingsFont.monoSmall)
                .foregroundColor(theme.text.link)
                .frame(width: 16, height: 16)
                .background(Circle().fill(theme.status.info.background))
            text
                .textStyle(.caption)
                .foregroundColor(theme.text.primary)
                .tint(theme.action.primary.default.background)
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

// MARK: - Catalog banner

/// One-line nudge above the Language catalog while no token is saved. The
/// token itself is managed under Vault → App Keys, so the banner only offers
/// the Add flow and disappears once a token exists.
struct HuggingFaceTokenBanner: View {
    /// Token presence. Seeded from the in-memory cache ONLY — never a
    /// synchronous keychain read on the render path, which can block the main
    /// thread for seconds and hang the catalog. `HuggingFaceAuth` is preloaded
    /// off-main at app launch, so the cache is warm in the common case; on a
    /// cold cache this starts hidden and `resolvePresence()` corrects it
    /// off-main.
    @State private var hasToken: Bool
    @State private var showAddSheet = false
    @Environment(\.theme) private var theme

    init() {
        _hasToken = State(initialValue: HuggingFaceAuth.cachedTokenPresence ?? true)
    }

    private func resolvePresence() async {
        guard HuggingFaceAuth.cachedTokenPresence == nil else { return }
        let present = await Task.detached(priority: .utility) {
            HuggingFaceAuth.hasToken
        }.value
        await MainActor.run { hasToken = present }
    }

    var body: some View {
        Group {
            if !hasToken {
                SettingsCallout(
                    icon: "bolt.horizontal.circle",
                    title: "Faster model downloads",
                    message: "A free Hugging Face token raises rate limits so models download faster.",
                    tone: .info
                ) {
                    SettingsButton(.secondary, "Add Token", icon: "plus", size: .compact) { showAddSheet = true }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            HuggingFaceTokenPromptSheet {
                withAnimation(theme.motion.quick) { hasToken = true }
            }
            .environment(\.theme, theme)
        }
        .task { await resolvePresence() }
    }
}

// MARK: - Shared token field

/// Masked token input shared by the add sheet and the card's replace row.
struct HuggingFaceTokenField: View {
    @Environment(\.theme) private var theme

    @Binding var tokenInput: String
    let onSubmit: () -> Void

    var body: some View {
        SettingsTextField(
            placeholder: "hf_…",
            text: $tokenInput,
            monospaced: true,
            isSecure: true,
            onSubmit: onSubmit
        )
    }
}
