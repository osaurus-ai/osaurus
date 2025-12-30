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
        }
    }
}
