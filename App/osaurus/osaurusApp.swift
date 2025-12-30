//
//  osaurusApp.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import AppKit
import OsaurusCore
import SwiftUI

@main
struct osaurusApp: SwiftUI.App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some SwiftUI.Scene {
        Settings {
            EmptyView()
        }
        .commands {
            // File menu commands
            CommandGroup(replacing: .newItem) {
                Button("New Window") {
                    Task { @MainActor in
                        ChatWindowManager.shared.createWindow()
                    }
                }
                .keyboardShortcut("n", modifiers: .command)

                Menu("New Window with Persona") {
                    ForEach(PersonaManager.shared.personas, id: \.id) { persona in
                        Button(persona.name) {
                            Task { @MainActor in
                                ChatWindowManager.shared.createWindow(personaId: persona.id)
                            }
                        }
                    }
                }
            }

            // Settings command
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.showPopover()
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            // About command
            CommandGroup(replacing: .appInfo) {
                Button("About Osaurus") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Osaurus",
                        .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                            ?? "1.0",
                        .version: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1",
                    ])
                }
            }

            // Help menu commands
            CommandGroup(replacing: .help) {
                Button("Osaurus Help") {
                    if let url = URL(string: "https://docs.osaurus.ai/") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .keyboardShortcut("?", modifiers: .command)

                Divider()

                Button("Documentation") {
                    if let url = URL(string: "https://docs.osaurus.ai/") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Button("Discord Community") {
                    if let url = URL(string: "https://discord.gg/dinoki") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Button("Report an Issue…") {
                    if let url = URL(string: "https://github.com/dinoki-ai/osaurus/issues/new") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Divider()

                Button("Keyboard Shortcuts") {
                    if let url = URL(string: "https://docs.osaurus.ai/keyboard-shortcuts") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Divider()

                Button("Acknowledgements…") {
                    Task { @MainActor in
                        appDelegate.showAcknowledgements()
                    }
                }
            }
        }
    }
}
