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
    let onSubmit: (String) -> Void

    @Environment(\.theme) private var theme
    @State private var name: String = ""
    @FocusState private var isFocused: Bool

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
