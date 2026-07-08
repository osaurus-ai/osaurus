//
//  HuggingFaceTokenSettingsView.swift
//  osaurus
//
//  Settings control for the optional Hugging Face access token. Anonymous
//  requests are rate-limited hard enough to stall model downloads; a token
//  raises those limits and unlocks gated repos the user can access.
//

import SwiftUI

struct HuggingFaceTokenSettingsView: View {
    @Environment(\.theme) private var theme

    @State private var tokenInput: String = ""
    @State private var storedTokenPresent = false
    @State private var statusText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "Model downloads without a token are rate-limited by Hugging Face and can be very slow or fail under load. A free access token raises those limits and lets you download gated models you've been granted access to. Create a read-only token at huggingface.co/settings/tokens.",
                bundle: .module
            )
            .font(.system(size: 12))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    if tokenInput.isEmpty {
                        Text(storedTokenPresent ? "••••••••••••••••" : "hf_…")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(theme.placeholderText)
                            .allowsHitTesting(false)
                    }
                    SecureField("", text: $tokenInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .onSubmit { saveToken() }
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

                Button(action: saveToken) {
                    Text("Save", bundle: .module)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(
                                    theme.accentColor.opacity(
                                        tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                            .isEmpty ? 0.4 : 1.0
                                    )
                                )
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if storedTokenPresent {
                    Button(action: removeToken) {
                        Text("Remove", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.red)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.red.opacity(0.12))
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }

            if let statusText {
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
            }
        }
        .task {
            // First token access can read the keychain; keep it off the
            // main thread.
            let present = await Task.detached(priority: .userInitiated) {
                HuggingFaceAuth.hasToken
            }.value
            storedTokenPresent = present
            if present { statusText = L("Token saved in your macOS Keychain.") }
        }
    }

    private func saveToken() {
        let trimmed = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        HuggingFaceAuth.setToken(trimmed)
        tokenInput = ""
        storedTokenPresent = true
        statusText = L("Token saved in your macOS Keychain.")
    }

    private func removeToken() {
        HuggingFaceAuth.setToken(nil)
        tokenInput = ""
        storedTokenPresent = false
        statusText = L("Token removed.")
    }
}
