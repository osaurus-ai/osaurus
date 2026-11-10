//
//  ProjectNamePromptSheet.swift
//  osaurus
//
//  Themed-alert custom content for naming a project (create or rename)
//

import SwiftUI

/// Single-field prompt used by the sidebar's "New Project" and
/// "Rename Project" flows. Presented via `ThemedAlertCenter` custom
/// content; the host owns dismissal and passes the trimmed name out
/// through `onSubmit`.
struct ProjectNamePromptSheet: View {
    let initialName: String
    let submitLabel: LocalizedStringKey
    /// When true, prefix the field with a short explainer of what a project
    /// is (shown for the "New Project" flow; the rename flow stays bare).
    var showsIntro: Bool = false
    /// Field placeholder; the tab strip reuses this sheet to rename a chat.
    var placeholder: LocalizedStringKey = "Project name"
    let onSubmit: (String) -> Void

    @Environment(\.theme) private var theme
    @State private var name: String = ""
    @FocusState private var isFocused: Bool

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsIntro {
                intro
                Divider().opacity(0.5)
            }

            TextField(text: $name, prompt: Text(placeholder, bundle: .module)) {
                Text(placeholder, bundle: .module)
            }
            .textFieldStyle(.plain)
            .textStyle(.bodySmall)
            .foregroundColor(theme.text.primary)
            .focused($isFocused)
            .onSubmit(submit)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                    .fill(theme.surface.canvas)
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                            .stroke(theme.border.strong, lineWidth: theme.stroke.default)
                    )
            )

            HStack {
                Spacer()
                Button(action: submit) {
                    Text(submitLabel, bundle: .module)
                        .textStyle(.caption, weight: 600)
                }
                .disabled(trimmed.isEmpty)
            }
        }
        .onAppear {
            name = initialName
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFocused = true
            }
        }
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
    }

    // MARK: - Intro

    /// Short explainer + the three things a project bundles, so the create
    /// dialog teaches what a project is instead of just asking for a name.
    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "Group related chats so they share the same instructions, knowledge, and memory across every agent.",
                bundle: .module
            )
            .textStyle(.caption)
            .foregroundColor(theme.text.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                featureRow(
                    icon: "list.bullet.rectangle",
                    title: "Instructions",
                    subtitle: "Guidance added to every chat."
                )
                featureRow(
                    icon: "books.vertical",
                    title: "Knowledge",
                    subtitle: "Shared collections every chat can search."
                )
                featureRow(
                    icon: "brain",
                    title: "Shared memory",
                    subtitle: "Facts that carry across every chat."
                )
            }
        }
    }

    private func featureRow(
        icon: String,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .glyphSize(12, weight: .medium)
                .foregroundColor(theme.text.primary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                        .fill(theme.surface.pressed)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(title, bundle: .module)
                    .textStyle(.caption, weight: 600)
                    .foregroundColor(theme.text.primary)
                Text(subtitle, bundle: .module)
                    .textStyle(.footnote)
                    .foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
