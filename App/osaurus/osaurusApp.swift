//
//  osaurusApp.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import AppKit
import Foundation
import OsaurusCore
import SwiftUI

/// Process entry point.
///
/// `OSAURUS_SPAWN_CHECK=1` makes the binary print a sentinel and exit before any
/// app singleton initializes. CI's launch gate (`scripts/build/verify_launch.sh`)
/// relies on this: a signed-but-unspawnable build (e.g. AMFI rejecting a
/// restricted entitlement, the failure that bricked 0.19.3) produces no sentinel
/// and a nonzero exit, so the release fails instead of shipping a dead app.
@main
enum OsaurusMain {
    static func main() {
        if ProcessInfo.processInfo.environment["OSAURUS_SPAWN_CHECK"] == "1" {
            print("OSAURUS_SPAWN_OK")
            exit(0)
        }
        // Writes to a peer-closed socket or pipe (a local HTTP client
        // disconnecting mid-response, a plugin process exiting with
        // stdio still open) raise SIGPIPE, which terminates the process
        // by default. Ignore it so those writes fail with EPIPE and
        // surface as ordinary errors on the write path instead.
        signal(SIGPIPE, SIG_IGN)
        osaurusApp.main()
    }
}

struct osaurusApp: SwiftUI.App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var themeManager = ThemeManager.shared
    private var scheduleManager = ScheduleManager.shared
    private var watcherManager = WatcherManager.shared
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
            Button {
                Task { @MainActor in
                    ChatWindowManager.shared.createWindow()
                }
            } label: {
                Text(verbatim: L("New Window"))
            }
            .keyboardShortcut("n", modifiers: .command)

            Menu {
                ForEach(AgentManager.shared.agents, id: \.id) { agent in
                    Button {
                        Task { @MainActor in
                            ChatWindowManager.shared.createWindow(agentId: agent.id)
                        }
                    } label: {
                        Text(verbatim: agent.displayName)
                    }
                }
            } label: {
                Text(verbatim: L("New Window with Agent"))
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
            Button {
                openManagementTab(nil)
            } label: {
                Text(verbatim: L("Settings…"))
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }

    // MARK: About

    var aboutCommand: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button {
                NSApp.orderFrontStandardAboutPanel(options: [
                    .applicationName: "Osaurus",
                    .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                        ?? "1.0",
                    .version: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1",
                ])
            } label: {
                Text(verbatim: L("About Osaurus"))
            }
        }
    }

    // MARK: View Menu

    var viewMenuCommands: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()

            Menu {
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

                Button {
                    openManagementTab(.themes)
                } label: {
                    Text(verbatim: L("Manage Themes…"))
                }
            } label: {
                Text(verbatim: L("Theme"))
            }
        }
    }

    // MARK: Window Menu

    var windowMenuCommands: some Commands {
        CommandGroup(after: .windowList) {
            Divider()
            Button {
                openManagementTab(.models)
            } label: {
                Text(verbatim: L("Models"))
            }
            Button {
                openManagementTab(.plugins)
            } label: {
                Text(verbatim: L("Plugins"))
            }
            Button {
                openManagementTab(.server)
            } label: {
                Text(verbatim: L("Server"))
            }
        }
    }

    // MARK: Help Menu

    var helpMenuCommands: some Commands {
        CommandGroup(replacing: .help) {
            Button {
                openURL("https://docs.osaurus.ai/")
            } label: {
                Text(verbatim: L("Osaurus Help"))
            }
            .keyboardShortcut("?", modifiers: .command)

            Divider()

            Button {
                openURL("https://docs.osaurus.ai/")
            } label: {
                Text(verbatim: L("Documentation"))
            }

            Button {
                openURL("https://discord.gg/osaurus")
            } label: {
                Text(verbatim: L("Discord Community"))
            }

            Button {
                openURL("https://github.com/osaurus-ai/osaurus/issues/new")
            } label: {
                Text(verbatim: L("Report an Issue…"))
            }

            Divider()

            Button {
                openURL("https://docs.osaurus.ai/keyboard-shortcuts")
            } label: {
                Text(verbatim: L("Keyboard Shortcuts"))
            }

            Divider()

            Button {
                Task { @MainActor in
                    appDelegate.showAcknowledgements()
                }
            } label: {
                Text(verbatim: L("Acknowledgements…"))
            }
        }
    }
}

// MARK: - Submenus

private extension osaurusApp {

    var schedulesMenu: some View {
        Menu {
            ForEach(scheduleManager.schedules) { schedule in
                Button {
                    openManagementTab(.schedules)
                } label: {
                    Text(verbatim: schedule.name)
                }
            }

            if !scheduleManager.schedules.isEmpty {
                Divider()
            }

            Button {
                openManagementTab(.schedules)
            } label: {
                Text(verbatim: L("New Schedule…"))
            }

            Button {
                openManagementTab(.schedules)
            } label: {
                Text(verbatim: L("Manage Schedules…"))
            }
        } label: {
            Text(verbatim: L("Schedules"))
        }
    }

    var watchersMenu: some View {
        Menu {
            ForEach(watcherManager.watchers) { watcher in
                Button {
                    openManagementTab(.watchers)
                } label: {
                    Text(verbatim: watcher.name)
                }
            }

            if !watcherManager.watchers.isEmpty {
                Divider()
            }

            Button {
                openManagementTab(.watchers)
            } label: {
                Text(verbatim: L("New Watcher…"))
            }

            Button {
                openManagementTab(.watchers)
            } label: {
                Text(verbatim: L("Manage Watchers…"))
            }
        } label: {
            Text(verbatim: L("Watchers"))
        }
    }

    var agentsMenu: some View {
        Menu {
            ForEach(AgentManager.shared.agents, id: \.id) { agent in
                Button {
                    Task { @MainActor in
                        ChatWindowManager.shared.createWindow(agentId: agent.id)
                    }
                } label: {
                    Text(verbatim: agent.displayName)
                }
            }

            Divider()

            Button {
                openManagementTab(.agents)
            } label: {
                Text(verbatim: L("Manage Agents…"))
            }
        } label: {
            Text(verbatim: L("Agents"))
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
        guard canToggleVAD else { return L("Toggle Voice Detection") }
        return config.vadModeEnabled
            ? L("Disable Voice Detection") : L("Enable Voice Detection")
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

    func openManagementTab(_ tab: ManagementTab?) {
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
