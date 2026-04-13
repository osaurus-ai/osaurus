//
//  SlashCommandsSettingsSection.swift
//  osaurus
//
//  Settings section for creating and managing custom slash commands.
//  Embedded in ConfigurationView under Chat settings.
//

import SwiftUI

// MARK: - Slash Commands Settings Section

struct SlashCommandsSettingsSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private var registry = SlashCommandRegistry.shared

    @State private var showAddSheet = false
    @State private var editingCommand: SlashCommand? = nil

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row
            HStack {
                Text(
                    "Define reusable prompt shortcuts. Type / in the chat input to invoke them.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)

                Spacer()

                Button {
                    showAddSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Add Command", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(SlashCommandButtonStyle(isPrimary: true, theme: theme))
            }

            if registry.customCommands.isEmpty {
                emptyState
            } else {
                commandList
            }
        }
        .sheet(isPresented: $showAddSheet) {
            SlashCommandEditorSheet(command: nil) { newCmd in
                registry.create(
                    name: newCmd.name,
                    description: newCmd.description,
                    icon: newCmd.icon,
                    template: newCmd.template ?? ""
                )
            }
        }
        .sheet(item: $editingCommand) { cmd in
            SlashCommandEditorSheet(command: cmd) { updated in
                registry.update(updated)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 20))
                    .foregroundColor(theme.tertiaryText)
                Text("No custom commands yet", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                Text("Click \"Add Command\" to create your first shortcut.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding(.vertical, 20)
    }

    // MARK: - Command List

    private var commandList: some View {
        VStack(spacing: 0) {
            ForEach(Array(registry.customCommands.enumerated()), id: \.element.id) { idx, cmd in
                commandRow(cmd, isLast: idx == registry.customCommands.count - 1)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
        )
    }

    private func commandRow(_ cmd: SlashCommand, isLast: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                // Icon badge
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(theme.tertiaryBackground)
                    Image(systemName: cmd.icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
                .frame(width: 24, height: 24)

                // Name + description
                VStack(alignment: .leading, spacing: 2) {
                    Text("/\(cmd.name)")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                    if !cmd.description.isEmpty {
                        Text(cmd.description)
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Template preview
                if let template = cmd.template, !template.isEmpty {
                    Text(template)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                        .frame(maxWidth: 160, alignment: .trailing)
                        .truncationMode(.tail)
                }

                // Actions
                HStack(spacing: 2) {
                    Button {
                        editingCommand = cmd
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Text("Edit command", bundle: .module))

                    Button {
                        registry.delete(id: cmd.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(theme.errorColor)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Text("Delete command", bundle: .module))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if !isLast {
                Divider()
                    .padding(.leading, 46)
                    .opacity(0.4)
            }
        }
    }
}

// MARK: - Editor Sheet

struct SlashCommandEditorSheet: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    let command: SlashCommand?
    let onSave: (SlashCommand) -> Void

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var template: String = ""
    @State private var icon: String = "text.bubble"
    @State private var nameError: String? = nil

    private var theme: ThemeProtocol { themeManager.currentTheme }
    private var isEditing: Bool { command != nil }

    private let availableIcons = [
        "text.bubble", "wand.and.stars", "doc.text", "globe", "scissors",
        "pencil", "magnifyingglass", "arrow.triangle.2.circlepath", "lightbulb",
        "list.bullet", "checkmark.circle", "tag", "bookmark", "star",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text(isEditing ? "Edit Command" : "New Command", bundle: .module)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider().opacity(0.3)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Icon picker
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Icon", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(36)), count: 7), spacing: 6) {
                            ForEach(availableIcons, id: \.self) { sym in
                                Button {
                                    icon = sym
                                } label: {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(
                                                icon == sym
                                                    ? theme.accentColor.opacity(0.15)
                                                    : theme.tertiaryBackground
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .strokeBorder(
                                                        icon == sym
                                                            ? theme.accentColor.opacity(0.4)
                                                            : Color.clear,
                                                        lineWidth: 1
                                                    )
                                            )
                                        Image(systemName: sym)
                                            .font(.system(size: 13))
                                            .foregroundColor(icon == sym ? theme.accentColor : theme.secondaryText)
                                    }
                                    .frame(width: 36, height: 36)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Name field
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Name", bundle: .module)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(theme.secondaryText)
                            Text("(no spaces)", bundle: .module)
                                .font(.system(size: 10))
                                .foregroundColor(theme.tertiaryText)
                        }
                        TextField("/command-name", text: $name)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.inputBackground)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(
                                                nameError != nil ? Color.red.opacity(0.6) : theme.inputBorder,
                                                lineWidth: 1
                                            )
                                    )
                            )
                            .onChange(of: name) { _, newValue in
                                // Strip spaces and leading slash
                                let cleaned =
                                    newValue
                                    .replacingOccurrences(of: " ", with: "-")
                                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                                if cleaned != newValue { name = cleaned }
                                nameError = nil
                            }
                        if let error = nameError {
                            Text(error)
                                .font(.system(size: 11))
                                .foregroundColor(.red.opacity(0.8))
                        }
                    }

                    // Description field
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Description", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                        TextField("Short description shown in the popup", text: $description)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundColor(theme.primaryText)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.inputBackground)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(theme.inputBorder, lineWidth: 1)
                                    )
                            )
                    }

                    // Template field
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Prompt Template", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.secondaryText)

                        ZStack(alignment: .topLeading) {
                            if template.isEmpty {
                                Text("e.g. Please translate the following to Spanish:", bundle: .module)
                                    .font(.system(size: 13))
                                    .foregroundColor(theme.placeholderText)
                                    .padding(.top, 12)
                                    .padding(.leading, 12)
                                    .allowsHitTesting(false)
                            }
                            TextEditor(text: $template)
                                .font(.system(size: 13))
                                .foregroundColor(theme.primaryText)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 80, maxHeight: 120)
                                .padding(10)
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.inputBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(theme.inputBorder, lineWidth: 1)
                                )
                        )

                        Text(
                            "This text is inserted into the chat input when you select the command. You continue typing after it.",
                            bundle: .module
                        )
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                    }
                }
                .padding(20)
            }

            Divider().opacity(0.3)

            // Footer
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Cancel", bundle: .module)
                }
                .buttonStyle(SlashCommandButtonStyle(theme: theme))

                Button {
                    save()
                } label: {
                    Text(isEditing ? "Save" : "Add Command", bundle: .module)
                }
                .buttonStyle(SlashCommandButtonStyle(isPrimary: true, theme: theme))
            }
            .padding(16)
        }
        .frame(width: 420)
        .background(theme.cardBackground)
        .onAppear {
            if let cmd = command {
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
            nameError = "Name is required"
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

// MARK: - Button Style

struct SlashCommandButtonStyle: ButtonStyle {
    var isPrimary: Bool = false
    let theme: ThemeProtocol

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(isPrimary ? .white : theme.primaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isPrimary ? theme.accentColor : theme.tertiaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(isPrimary ? Color.clear : theme.inputBorder, lineWidth: 1)
                    )
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}
