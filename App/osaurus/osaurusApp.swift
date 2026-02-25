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
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var scheduleManager = ScheduleManager.shared
    @ObservedObject private var watcherManager = WatcherManager.shared
    @ObservedObject private var vadService = VADService.shared
    @ObservedObject private var speechModelManager = SpeechModelManager.shared

    var body: some SwiftUI.Scene {
        Settings {
            EmptyView()
        }
        .commands {
            fileMenuCommands
            fileMenuExtras
            settingsCommand
            aboutCommand
            viewMenuCommands
            windowMenuCommands
            helpMenuCommands
        }
    }
}

// MARK: - Menu Commands

private extension osaurusApp {

    // MARK: File Menu

    var fileMenuCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                Task { @MainActor in
                    ChatWindowManager.shared.createWindow()
                }
            }
            .keyboardShortcut("n", modifiers: .command)

            Menu("New Window with Agent") {
                ForEach(AgentManager.shared.agents, id: \.id) { agent in
                    Button(agent.name) {
                        Task { @MainActor in
                            ChatWindowManager.shared.createWindow(agentId: agent.id)
                        }
                    }
                }
            }
        }
    }

    var fileMenuExtras: some Commands {
        CommandGroup(after: .newItem) {
            Divider()

            Button(vadToggleLabel) {
                toggleVAD()
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled(!canToggleVAD)

            Divider()

            schedulesMenu
            watchersMenu
            agentsMenu
        }
    }

    // MARK: Settings

    var settingsCommand: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                openManagementTab(.settings)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }

    // MARK: About

    var aboutCommand: some Commands {
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
    }

    // MARK: View Menu

    var viewMenuCommands: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()

            Menu("Theme") {
                ForEach(themeManager.installedThemes, id: \.metadata.id) { theme in
                    Button {
                        themeManager.applyCustomTheme(theme)
                    } label: {
                        HStack {
                            Text(theme.metadata.name)
                            if themeManager.activeCustomTheme?.metadata.id == theme.metadata.id {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                Divider()

                Button("Manage Themes…") {
                    openManagementTab(.themes)
                }
            }
        }
    }

    // MARK: Window Menu

    var windowMenuCommands: some Commands {
        CommandGroup(after: .windowList) {
            Divider()
            Button("Models") { openManagementTab(.models) }
            Button("Plugins") { openManagementTab(.plugins) }
            Button("Server") { openManagementTab(.server) }
        }
    }

    // MARK: Help Menu

    var helpMenuCommands: some Commands {
        CommandGroup(replacing: .help) {
            Button("Osaurus Help") {
                openURL("https://docs.osaurus.ai/")
            }
            .keyboardShortcut("?", modifiers: .command)

            Divider()

            Button("Documentation") {
                openURL("https://docs.osaurus.ai/")
            }

            Button("Discord Community") {
                openURL("https://discord.gg/dinoki")
            }

            Button("Report an Issue…") {
                openURL("https://github.com/osaurus-ai/osaurus/issues/new")
            }

            Divider()

            Button("Keyboard Shortcuts") {
                openURL("https://docs.osaurus.ai/keyboard-shortcuts")
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

// MARK: - Submenus

private extension osaurusApp {

    var schedulesMenu: some View {
        Menu("Schedules") {
            ForEach(scheduleManager.schedules) { schedule in
                Button(schedule.name) {
                    openManagementTab(.schedules)
                }
            }

            if !scheduleManager.schedules.isEmpty {
                Divider()
            }

            Button("New Schedule…") {
                openManagementTab(.schedules)
            }

            Button("Manage Schedules…") {
                openManagementTab(.schedules)
            }
        }
    }

    var watchersMenu: some View {
        Menu("Watchers") {
            ForEach(watcherManager.watchers) { watcher in
                Button(watcher.name) {
                    openManagementTab(.watchers)
                }
            }

            if !watcherManager.watchers.isEmpty {
                Divider()
            }

            Button("New Watcher…") {
                openManagementTab(.watchers)
            }

            Button("Manage Watchers…") {
                openManagementTab(.watchers)
            }
        }
    }

    var agentsMenu: some View {
        Menu("Agents") {
            ForEach(AgentManager.shared.agents, id: \.id) { agent in
                Button(agent.name) {
                    Task { @MainActor in
                        ChatWindowManager.shared.createWindow(agentId: agent.id)
                    }
                }
            }

            Divider()

            Button("Manage Agents…") {
                openManagementTab(.agents)
            }
        }
    }
}

// MARK: - VAD Helpers

private extension osaurusApp {

    var canToggleVAD: Bool {
        speechModelManager.selectedModel != nil
    }

    var vadToggleLabel: String {
        let config = VADConfigurationStore.load()
        guard canToggleVAD else { return "Toggle Voice Detection" }
        return config.vadModeEnabled ? "Disable Voice Detection" : "Enable Voice Detection"
    }

    func toggleVAD() {
        Task { @MainActor in
            var config = VADConfigurationStore.load()
            let newState = !config.vadModeEnabled
            config.vadModeEnabled = newState
            VADConfigurationStore.save(config)
            vadService.loadConfiguration()

            do {
                if newState {
                    try await vadService.start()
                } else {
                    await vadService.stop()
                }
            } catch {
                if newState {
                    config.vadModeEnabled = false
                    VADConfigurationStore.save(config)
                    vadService.loadConfiguration()
                }
            }
        }
    }
}

// MARK: - Utilities

private extension osaurusApp {

    func openManagementTab(_ tab: ManagementTab) {
        Task { @MainActor in
            AppDelegate.shared?.showManagementWindow(initialTab: tab)
        }
    }

    func openURL(_ string: String) {
        if let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        }
    }
}
