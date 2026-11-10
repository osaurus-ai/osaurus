//
//  SlashCommandEditorSheet.swift
//  osaurus
//
//  Editor sheet for creating and editing custom slash commands.
//  Presented from SlashCommandsView (Capabilities → Commands).
//

import SwiftUI

// MARK: - Editor Sheet

struct SlashCommandEditorSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let command: SlashCommand?
    /// Starting values for a new command; ignored when editing.
    var draft: SlashCommand? = nil
    let onSave: (SlashCommand) -> Void

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var template: String = ""
    @State private var icon: String = "text.bubble"
    @State private var nameError: String? = nil

    private var isEditing: Bool { command != nil }

    /// True when an edited command still differs from what's stored, so
    /// "Save" can disable itself once there's nothing to apply. Create
    /// mode is always "changed" so its button keeps surfacing the
    /// name-required validation on click.
    private var hasChanges: Bool {
        guard let command else { return true }
        return name.trimmingCharacters(in: .whitespacesAndNewlines) != command.name
            || description != command.description
            || template != (command.template ?? "")
            || icon != command.icon
    }

    private let availableIcons = [
        "text.bubble", "wand.and.stars", "doc.text", "globe", "scissors",
        "pencil", "magnifyingglass", "arrow.triangle.2.circlepath", "lightbulb",
        "list.bullet", "checkmark.circle", "tag", "bookmark", "star",
    ]

    var body: some View {
        SettingsSheet(
            icon: icon,
            title: isEditing ? "Edit Command" : "New Command",
            primary: .init(
                label: isEditing ? "Save" : "Add Command",
                isEnabled: !isEditing || hasChanges,
                handler: save
            ),
            secondary: .init(label: "Cancel") { dismiss() },
            onClose: { dismiss() }
        ) {
            SettingsFieldRow(label: "Icon") {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(32)), count: 9), spacing: theme.space.s6) {
                    ForEach(availableIcons, id: \.self) { sym in
                        Button {
                            icon = sym
                        } label: {
                            Image(systemName: sym)
                        }
                        .assignedSettingsIconButtonStyle(isActive: icon == sym)
                        .accessibilityLabel(Text(verbatim: sym))
                        .accessibilityAddTraits(icon == sym ? .isSelected : [])
                    }
                }
            }

            SettingsFieldRow(label: "Name", hint: nameError ?? "No spaces. Type it after / in chat.", verbatimHint: nameError != nil) {
                SettingsTextField(placeholder: L("/command-name"), text: $name, monospaced: true, isInvalid: nameError != nil)
                    .onChange(of: name) { _, newValue in
                        // Strip spaces and leading slash
                        let cleaned =
                            newValue
                            .replacingOccurrences(of: " ", with: "-")
                            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        if cleaned != newValue { name = cleaned }
                        nameError = nil
                    }
            }

            SettingsFieldRow(label: "Description") {
                SettingsTextField(placeholder: L("Short description shown in the popup"), text: $description)
            }

            SettingsFieldRow(
                label: "Prompt Template",
                hint: "This text is inserted into the chat input when you select the command. You continue typing after it."
            ) {
                SettingsTextEditor(
                    text: $template,
                    placeholder: L("e.g. Please translate the following to Spanish:"),
                    minHeight: 80,
                    maxHeight: 120
                )
            }
        }
        .onAppear {
            if let cmd = command ?? draft {
                name = cmd.name
                description = cmd.description
                template = cmd.template ?? ""
                icon = cmd.icon
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            nameError = L("Name is required")
            return
        }

        var saved = command ?? SlashCommand(name: trimmed)
        saved.name = trimmed
        saved.description = description
        saved.template = template
        saved.icon = icon
        saved.kind = .template
        saved.updatedAt = Date()

        onSave(saved)
        dismiss()
    }
}
