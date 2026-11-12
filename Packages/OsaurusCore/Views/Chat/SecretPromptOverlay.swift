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
        SandboxCredentials.save(value, key: key, agentId: uuid, description: description)
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
    var automaticallyFocus = true

    @State private var secretValue: String = ""
    @FocusState private var isInputFocused: Bool
    @Environment(\.theme) private var environmentTheme
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(36) }
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
                text: "Saved in Vault as \(state.key), only for this agent"
            ),
            onCancel: onCancel,
            bodyContent: { EmptyView() },
            inputRow: { inputAndActions }
        )
        .environment(\.theme, theme)
        .onAppear {
            guard automaticallyFocus else { return }
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
        HStack(spacing: theme.catalogLayoutMetric("component.library.36.elements.layout.secretPromptCard.inputAndActions.horizontalGap", inheriting: PromptInspectionStyle.metric("gap", theme.space.s10, theme))) {
            SecureField("", text: $secretValue)
                .promptText(.body, fallback: .bodySmall, theme: theme)
                .foregroundColor(theme.text.primary)
                .textFieldStyle(.plain)
                .focused($isInputFocused)
                .padding(.horizontal, theme.catalogLayoutMetric("component.library.36.elements.layout.secretPromptCard.inputAndActions.paddingX", inheriting: PromptInspectionStyle.metric("padding", theme.space.s12, theme))).catalogLayoutTarget("component.library.36.elements.layout.secretPromptCard.inputAndActions.paddingX")
                .padding(.vertical, theme.catalogLayoutMetric("component.library.36.elements.layout.secretPromptCard.inputAndActions.paddingY", inheriting: PromptInspectionStyle.metric("padding", theme.space.s8, theme))).catalogLayoutTarget("component.library.36.elements.layout.secretPromptCard.inputAndActions.paddingY")
                .frame(minHeight: PromptInspectionStyle.metric("height", 0, theme))
                .overlay(alignment: .topLeading) {
                    if secretValue.isEmpty {
                        Text("Paste your \(state.key) here...", bundle: .module)
                            .promptText(.body, fallback: .bodySmall, theme: theme)
                            .foregroundColor(theme.text.placeholder)
                            .padding(.leading, theme.catalogLayoutMetric("component.library.36.elements.layout.secretPromptCard.inputAndActions.paddingX2", inheriting: PromptInspectionStyle.metric("padding", theme.space.s12, theme))).catalogLayoutTarget("component.library.36.elements.layout.secretPromptCard.inputAndActions.paddingX2")
                            .padding(.top, theme.catalogLayoutMetric("component.library.36.elements.layout.secretPromptCard.inputAndActions.paddingY2", inheriting: PromptInspectionStyle.metric("padding", theme.space.s8, theme))).catalogLayoutTarget("component.library.36.elements.layout.secretPromptCard.inputAndActions.paddingY2")
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
                .onSubmit { submitSecret() }

            Button(action: submitSecret) {
                Image(systemName: "arrow.up")
                    .glyphSize(.caption, weight: .bold)
                    .foregroundColor(canSubmit ? theme.action.primary.default.foreground : theme.assignedColor(PromptInspectionStyle.key + "disabledForeground", fallback: theme.action.primary.disabled.foreground))
                    .frame(width: PromptInspectionStyle.metric("height", 32, theme), height: PromptInspectionStyle.metric("height", 32, theme))
                    .background(
                        Circle()
                            .fill(canSubmit ? theme.action.primary.default.background : theme.assignedColor(PromptInspectionStyle.key + "disabledBackground", fallback: theme.action.primary.disabled.background))
                    )
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.plain)
            .accessibilityLabel(L("Save \(state.key)"))
            .help(L("Save \(state.key)"))
            .disabled(!canSubmit)
            .pointingHandCursor()
        }.catalogLayoutTarget("component.library.36.elements.layout.secretPromptCard.inputAndActions.horizontalGap")
    }
}

extension SecretPromptOverlay {
    @MainActor static func inspectionCard() -> some View {
        SecretPromptCard(
            state: SecretPromptState(key: "LOCAL_DISPLAY_ONLY", description: "Local secret prompt",
                instructions: "Display-only sample. No credential is entered or stored.",
                agentId: "inspector-display-only", completion: { _ in }),
            onCancel: {}, onSubmitted: {}, automaticallyFocus: false
        ).allowsHitTesting(false)
    }
}
