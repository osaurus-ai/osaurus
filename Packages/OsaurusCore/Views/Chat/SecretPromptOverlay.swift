//
//  SecretPromptOverlay.swift
//  osaurus
//
//  Secure overlay for collecting secret values (API keys, tokens).
//  Uses `SecureField` to keep the value out of the conversation and
//  LLM context. The visual chrome is delegated to `PromptCard` so this
//  file owns just the secret-specific lifecycle (`SecretPromptState`)
//  and the input row.
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

    var body: some View {
        PromptOverlayHost(onCancelDismiss: cancelAndDismiss) {
            SecretPromptCard(state: state, onCancel: cancelAndDismiss, onSubmitted: onDismiss)
        }
        .onDisappear {
            // Safety net: if the overlay disappears without an explicit
            // resolution (e.g. the parent view goes away), make sure the
            // continuation still resumes so the agent loop doesn't hang.
            state.cancel()
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
    @FocusState private var isInputFocused: Bool
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var canSubmit: Bool {
        !secretValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        PromptCard(
            pillIcon: "lock.fill",
            pillLabel: "Secret Required",
            title: state.description,
            descriptionMarkdown: state.instructions,
            footnote: PromptCardFootnote(
                icon: "shield.lefthalf.filled",
                text: "Stored securely in Keychain as \(state.key)"
            ),
            onCancel: onCancel,
            bodyContent: { EmptyView() },
            inputRow: { inputAndActions }
        )
        .onAppear {
            // Auto-focus once the entry animation has had a moment to
            // land — the card is bottom-pinned and immediately accepts
            // typed input, so cursor blink shouldn't precede the slide.
            let delay: TimeInterval = reduceMotion ? 0 : 0.20
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                isInputFocused = true
            }
        }
    }

    private func submitSecret() {
        guard canSubmit else { return }
        state.submit(secretValue)
        onSubmitted()
    }

    // MARK: - Input

    private var inputAndActions: some View {
        HStack(spacing: 10) {
            SecureField("", text: $secretValue)
                .font(theme.font(size: CGFloat(theme.bodySize) - 1, weight: .regular))
                .foregroundColor(theme.primaryText)
                .textFieldStyle(.plain)
                .focused($isInputFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .overlay(alignment: .topLeading) {
                    if secretValue.isEmpty {
                        Text("Paste your \(state.key) here...", bundle: .module)
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
            .pointingHandCursor()
        }
    }
}
