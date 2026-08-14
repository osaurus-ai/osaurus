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

            TextField(text: $name, prompt: Text("Project name", bundle: .module)) {
                Text("Project name", bundle: .module)
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundColor(theme.primaryText)
            .focused($isFocused)
            .onSubmit(submit)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.primaryBackground.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )

            HStack {
                Spacer()
                Button(action: submit) {
                    Text(submitLabel, bundle: .module)
                        .font(.system(size: 12, weight: .semibold))
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
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
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
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.accentColor)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(theme.accentColor.opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(title, bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(subtitle, bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Multi-line editor for a project's shared instructions, prepended to the
/// system prompt of every chat in the project. Presented via
/// `ThemedAlertCenter` custom content, like `ProjectNamePromptSheet`.
struct ProjectInstructionsSheet: View {
    let initialInstructions: String
    let onSubmit: (String) -> Void

    @Environment(\.theme) private var theme
    @State private var instructions: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shared context added to every chat in this project.", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)

            TextEditor(text: $instructions)
                .font(.system(size: 12))
                .foregroundColor(theme.primaryText)
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .frame(minHeight: 120, maxHeight: 220)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.primaryBackground.opacity(0.5))
                )

            HStack {
                Spacer()
                Button {
                    onSubmit(instructions.trimmingCharacters(in: .whitespacesAndNewlines))
                } label: {
                    Text("Save", bundle: .module)
                        .font(.system(size: 12, weight: .semibold))
                }
            }
        }
        .onAppear {
            instructions = initialInstructions
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFocused = true
            }
        }
    }
}
