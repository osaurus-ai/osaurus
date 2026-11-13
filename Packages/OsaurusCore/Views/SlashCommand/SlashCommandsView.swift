//
//  SlashCommandsView.swift
//  osaurus
//
//  Management view for creating and editing custom slash commands.
//  Accessible from the Commands tab in the sidebar.
//

import SwiftUI

struct SlashCommandsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private var registry = SlashCommandRegistry.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    /// The open create sheet, carrying its starting values.
    @State private var newCommandDraft: SlashCommand? = nil
    @State private var editingCommand: SlashCommand? = nil

    var body: some View {
        SettingsPage {
            headerView
        } content: {
            if registry.customCommands.isEmpty {
                SettingsEmptyState(
                    icon: "command",
                    title: "Create Your First Command",
                    subtitle: L(
                        "Slash commands let you insert reusable prompts from the chat input by typing /name."
                    ),
                    examples: [
                        exampleCommand("globe", L("/translate"), L("Please translate the following to Spanish:")),
                        exampleCommand("doc.text", L("/summarize"), L("Summarize the following in 3 bullet points:")),
                        exampleCommand(
                            "magnifyingglass", L("/review"), L("Review this code for bugs and improvements:")),
                    ],
                    primaryAction: .init(
                        title: L("New Command"),
                        icon: "plus",
                        handler: { newCommandDraft = SlashCommand(name: "") }
                    )
                )
            } else {
                SettingsGroup {
                    ForEach(registry.customCommands) { cmd in
                        commandRow(cmd)
                    }
                }
            }
        }
        .environment(\.theme, themeManager.currentTheme)
        .sheet(item: $newCommandDraft) { draft in
            SlashCommandEditorSheet(command: nil, draft: draft) { cmd in
                registry.create(
                    name: cmd.name,
                    description: cmd.description,
                    icon: cmd.icon,
                    template: cmd.template ?? ""
                )
            }
        }
        .sheet(item: $editingCommand) { cmd in
            SlashCommandEditorSheet(command: cmd) { updated in
                registry.update(updated)
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        SettingsPageHeader(
            title: "Commands",
            subtitle: "Reusable prompt shortcuts invoked by typing / in the chat input",
            count: registry.customCommands.count,
            primary: {
                SettingsButton(.primary, "New Command", icon: "plus") {
                    newCommandDraft = SlashCommand(name: "")
                }
            }
        )
    }

    // MARK: - Command List

    /// An example that opens the editor filled in with it.
    private func exampleCommand(_ icon: String, _ title: String, _ template: String) -> SettingsEmptyState.Example {
        .init(icon: icon, title: title, description: template) {
            newCommandDraft = SlashCommand(
                name: String(title.drop(while: { $0 == "/" })),
                icon: icon,
                template: template
            )
        }
    }

    private func commandRow(_ cmd: SlashCommand) -> some View {
        LibraryRow(
            title: "/\(cmd.name)",
            subtitle: [cmd.description, cmd.template ?? ""].filter { !$0.isEmpty }.joined(separator: "\n"),
            action: { editingCommand = cmd }
        ) {
            SettingsIconTile(icon: cmd.icon, size: 32)
        } menu: {
            Button(L("Edit command")) { editingCommand = cmd }
            Divider()
            Button(L("Delete command"), role: .destructive) { registry.delete(id: cmd.id) }
        }
    }
}
