//
//  HostedSecretCard.swift
//  osaurus
//
//  A secret the agent running on another of the user's Macs asked for. The
//  value is sealed to that Mac before it leaves this one.
//

import SwiftUI

struct HostedSecretCard: View {
    let prompt: SyncHostedRunContract.PendingPrompt
    let hostName: String
    let onAnswer: (String?) -> Void

    @Environment(\.theme) private var theme
    @State private var value = ""

    private var canSubmit: Bool { !value.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(spacing: theme.space.s8) {
                Image(systemName: "key.fill")
                    .glyphSize(12, weight: .semibold)
                    .foregroundColor(theme.status.warning.foreground)
                Text(String(format: L("The agent on %1$@ needs %2$@"), hostName, prompt.key))
                    .textStyle(.label, weight: 600)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
            }
            if !prompt.description.isEmpty {
                Text(prompt.description)
                    .textStyle(.caption)
                    .foregroundColor(theme.text.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !prompt.instructions.isEmpty {
                Text(prompt.instructions)
                    .textStyle(.caption)
                    .foregroundColor(theme.text.tertiary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SecureField("", text: $value)
                .textStyle(.bodySmall)
                .foregroundColor(theme.text.primary)
                .textFieldStyle(.plain)
                .padding(.horizontal, theme.space.s12)
                .padding(.vertical, theme.space.s8)
                .overlay(alignment: .leading) {
                    if value.isEmpty {
                        Text("Paste your \(prompt.key) here...", bundle: .module)
                            .textStyle(.bodySmall)
                            .foregroundColor(theme.text.placeholder)
                            .padding(.leading, theme.space.s12)
                            .allowsHitTesting(false)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                        .fill(theme.surface.hover)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                        .strokeBorder(theme.border.subtle, lineWidth: theme.stroke.default)
                )
                .onSubmit(submit)
            HStack(spacing: theme.space.s6) {
                Text(L("Sent encrypted to that Mac only."))
                    .textStyle(.micro)
                    .foregroundColor(theme.text.tertiary)
                Spacer(minLength: 0)
                Button(action: { onAnswer(nil) }) { Text(L("Cancel")) }
                    .buttonStyle(.settings(.secondary, size: .compact))
                Button(action: submit) { Text(L("Save")) }
                    .buttonStyle(.settings(.primary, size: .compact))
                    .disabled(!canSubmit)
            }
        }
        .padding(theme.space.s12)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous)
                .fill(theme.status.warning.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous)
                .strokeBorder(theme.status.warning.border, lineWidth: theme.stroke.default)
        )
        .padding(.bottom, theme.space.s8)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private func submit() {
        guard canSubmit else { return }
        let sent = value
        value = ""
        onAnswer(sent)
    }
}
