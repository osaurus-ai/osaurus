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

    @State private var isCreating = false
    @State private var editingCommand: SlashCommand? = nil
    @State private var hasAppeared = false

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            Spacer().frame(height: 2)

            ZStack {
                if registry.customCommands.isEmpty {
                    SettingsEmptyState(
                        icon: "command",
                        title: L("Create Your First Command"),
                        subtitle: L(
                            "Slash commands let you insert reusable prompts from the chat input by typing /name."
                        ),
                        examples: [
                            .init(
                                icon: "globe",
                                title: L("/translate"),
                                description: L("Please translate the following to Spanish:")
                            ),
                            .init(
                                icon: "doc.text",
                                title: L("/summarize"),
                                description: L("Summarize the following in 3 bullet points:")
                            ),
                            .init(
                                icon: "magnifyingglass",
                                title: L("/review"),
                                description: L("Review this code for bugs and improvements:")
                            ),
                        ],
                        primaryAction: .init(
                            title: L("New Command"),
                            icon: "plus",
                            handler: { isCreating = true }
                        ),
                        hasAppeared: hasAppeared
                    )
                } else {
                    commandList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
        .sheet(isPresented: $isCreating) {
            SlashCommandEditorSheet(command: nil) { cmd in
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
        ManagerHeaderWithActions(
            title: L("Commands"),
            subtitle: L("Reusable prompt shortcuts invoked by typing / in the chat input"),
            count: registry.customCommands.isEmpty ? nil : registry.customCommands.count
        ) {
            HeaderPrimaryButton(L("New Command"), icon: "plus") {
                isCreating = true
            }
        }
    }

    // MARK: - Command List

    private var commandList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(Array(registry.customCommands.enumerated()), id: \.element.id) { index, cmd in
                    commandRow(cmd, index: index)
                }
            }
            .padding(20)
        }
    }

    private func commandRow(_ cmd: SlashCommand, index: Int) -> some View {
        GlassListRow(animationIndex: index) {
            HStack(spacing: 12) {
                // Icon badge
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.accentColor.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: cmd.icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }

                // Name + description + template
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("/\(cmd.name)")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                    }
                    if !cmd.description.isEmpty {
                        Text(cmd.description)
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                    }
                    if let template = cmd.template, !template.isEmpty {
                        Text(template)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer()

                // Action buttons
                HStack(spacing: 4) {
                    Button {
                        editingCommand = cmd
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 13))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 30, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(theme.tertiaryBackground)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(Text("Edit command", bundle: .module))

                    Button {
                        registry.delete(id: cmd.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13))
                            .foregroundColor(theme.errorColor)
                            .frame(width: 30, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(theme.errorColor.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                    .help(Text("Delete command", bundle: .module))
                }
            }
        }
    }
}
