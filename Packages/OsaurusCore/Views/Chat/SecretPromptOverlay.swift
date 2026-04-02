//
//  SecretPromptOverlay.swift
//  osaurus
//
//  Secure overlay for collecting secret values (API keys, tokens).
//  Uses SecureField to keep the value out of the conversation and LLM context.
//  Shared between Chat and Work modes.
//

import SwiftUI

// MARK: - State

/// Pending secret prompt state, shared between the execution loop and UI.
@MainActor
public final class SecretPromptState: ObservableObject {
    let key: String
    let description: String
    let instructions: String
    let agentId: String
    private let completion: (String?) -> Void
    private var resolved = false

    init(
        key: String,
        description: String,
        instructions: String,
        agentId: String,
        completion: @escaping (String?) -> Void
    ) {
        self.key = key
        self.description = description
        self.instructions = instructions
        self.agentId = agentId
        self.completion = completion
    }

    func submit(_ value: String) {
        guard !resolved else { return }
        resolved = true
        guard let uuid = UUID(uuidString: agentId) else {
            completion(nil)
            return
        }
        AgentSecretsKeychain.saveSecret(value, id: key, agentId: uuid)
        completion(value)
    }

    func cancel() {
        guard !resolved else { return }
        resolved = true
        completion(nil)
    }
}

// MARK: - Overlay

struct SecretPromptOverlay: View {
    let state: SecretPromptState
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme
    @State private var isAppearing = false

    var body: some View {
        VStack {
            Spacer()

            SecretPromptCard(state: state, onCancel: cancelAndDismiss, onSubmitted: onDismiss)
                .opacity(isAppearing ? 1 : 0)
                .offset(y: isAppearing ? 0 : 30)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
        .onAppear {
            withAnimation(theme.springAnimation()) {
                isAppearing = true
            }
        }
        .onDisappear {
            state.cancel()
        }
        .onExitCommand {
            cancelAndDismiss()
        }
    }

    private func cancelAndDismiss() {
        state.cancel()
        onDismiss()
    }
}

// MARK: - Card

private struct SecretPromptCard: View {
    let state: SecretPromptState
    let onCancel: () -> Void
    let onSubmitted: () -> Void

    @State private var secretValue: String = ""
    @Environment(\.theme) private var theme

    private var canSubmit: Bool {
        !secretValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            descriptionArea
            inputAndActions
        }
        .padding(16)
        .background(overlayBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(borderOverlay)
        .shadow(color: theme.shadowColor.opacity(0.12), radius: 16, x: 0, y: 6)
    }

    private func submitSecret() {
        guard canSubmit else { return }
        state.submit(secretValue)
        onSubmitted()
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)

                Text("Secret Required")
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .semibold))
                    .foregroundColor(theme.accentColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(theme.accentColor.opacity(theme.isDark ? 0.15 : 0.1))
            )

            Spacer()

            Button(action: onCancel) {
                Text("Cancel")
                    .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - Description

    private var descriptionArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.description)
                .font(theme.font(size: CGFloat(theme.bodySize), weight: .medium))
                .foregroundColor(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            Text(markdownInstructions)
                .font(theme.font(size: CGFloat(theme.captionSize), weight: .regular))
                .foregroundColor(theme.tertiaryText)
                .tint(theme.accentColor)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            HStack(spacing: 4) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 10))
                Text("Stored securely in Keychain as \(state.key)")
                    .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .regular))
            }
            .foregroundColor(theme.tertiaryText.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.inputBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.inputBorder, lineWidth: 1)
        )
    }

    private var markdownInstructions: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if var attributed = try? AttributedString(markdown: state.instructions, options: options) {
            attributed.foregroundColor = theme.tertiaryText
            return attributed
        }
        return AttributedString(state.instructions)
    }

    // MARK: - Input & Actions

    private var inputAndActions: some View {
        HStack(spacing: 10) {
            SecureField("", text: $secretValue)
                .font(theme.font(size: CGFloat(theme.bodySize) - 1, weight: .regular))
                .foregroundColor(theme.primaryText)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .overlay(alignment: .topLeading) {
                    if secretValue.isEmpty {
                        Text("Paste your \(state.key) here...")
                            .font(theme.font(size: CGFloat(theme.bodySize) - 1, weight: .regular))
                            .foregroundColor(theme.placeholderText)
                            .padding(.leading, 12)
                            .padding(.top, 9)
                            .allowsHitTesting(false)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.tertiaryBackground.opacity(0.4))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.primaryBorder.opacity(0.15), lineWidth: 1)
                )
                .onSubmit { submitSecret() }

            Button(action: submitSecret) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(canSubmit ? .white : theme.tertiaryText)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(canSubmit ? theme.accentColor : theme.tertiaryBackground)
                    )
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.plain)
            .disabled(!canSubmit)
        }
    }

    // MARK: - Background & Border

    private var overlayBackground: some View {
        ZStack {
            if theme.glassEnabled {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
            }

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.cardBackground.opacity(theme.isDark ? 0.85 : 0.92))

            LinearGradient(
                colors: [theme.accentColor.opacity(theme.isDark ? 0.08 : 0.05), Color.clear],
                startPoint: .top,
                endPoint: .center
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var borderOverlay: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        theme.glassEdgeLight.opacity(0.2),
                        theme.cardBorder,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }
}
