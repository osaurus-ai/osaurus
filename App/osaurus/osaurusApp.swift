//
//  osaurusApp.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import AppKit
import Combine
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
    // NOTE: Do not add `@ObservedObject` singletons here. Every `@Published`
    // change on an object observed by the App struct re-evaluates the whole
    // `Commands` tree and rebuilds the main menu on the main thread. High-churn
    // publishers (e.g. `VADService.audioLevel`, `SpeechModelManager`
    // download progress) did exactly that and hung the UI. Observe state from
    // small, dedicated menu-item views instead (see `VADToggleMenuItem`,
    // `ThemeMenuItems`).
    private var scheduleManager = ScheduleManager.shared
    private var watcherManager = WatcherManager.shared
    /// Chat settings toggle: ⌘N starts a new chat in the frontmost chat
    /// window instead of opening a new window (see `NewChatShortcutSetting`).
    @AppStorage(NewChatShortcutSetting.defaultsKey)
    private var cmdNStartsNewChatInCurrentWindow: Bool = true

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
            // With the Chat setting on, ⌘N starts a new chat in the frontmost
            // window, staying in the current project (open project page or
            // the current chat's project) so a mid-project "out of context"
            // restart keeps its instructions, knowledge, and folder. "New
            // Window" moves to ⇧⌘N, matching most chat apps. Default keeps
            // the historical ⌘N = New Window behavior.
            if cmdNStartsNewChatInCurrentWindow {
                Button {
                    Task { @MainActor in
                        if !ChatWindowManager.shared.startNewChatInLastFocusedWindow() {
                            ChatWindowManager.shared.createWindow()
                        }
                    }
                } label: {
                    Text(verbatim: L("New Chat"))
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            Button {
                Task { @MainActor in
                    ChatWindowManager.shared.createWindow()
                }
            } label: {
                Text(verbatim: L("New Window"))
            }
            .keyboardShortcut(
                "n",
                modifiers: cmdNStartsNewChatInCurrentWindow ? [.command, .shift] : .command
            )

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

            VADToggleMenuItem()

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
            Button {
                Task { @MainActor in
                    ChatWindowManager.shared.toggleSidebarInFocusedWindow()
                }
            } label: {
                Text(verbatim: L("Toggle Sidebar"))
            }
            .keyboardShortcut("b", modifiers: .command)

            Button {
                Task { @MainActor in
                    ChatWindowManager.shared.cycleAgentInFocusedWindow()
                }
            } label: {
                Text(verbatim: L("Next Agent"))
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])

            Divider()

            ThemeMenuItems()
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
                openManagementTab(.tools)
            } label: {
                Text(verbatim: L("Tools"))
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

            Button {
                Task { @MainActor in ChatLayoutTour.shared.start() }
            } label: {
                Text(verbatim: L("Chat Layout Tour"))
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

// MARK: - VAD Menu Item

/// File-menu Voice Detection toggle.
///
/// Owns its own (narrow) state so VAD / speech-model changes only invalidate
/// this menu item instead of the whole App `Commands` tree. It intentionally
/// does NOT observe `VADService` (whose `audioLevel` publishes per audio
/// buffer while listening) or the full `SpeechModelManager` (whose
/// `downloadStates` publish on every download-progress tick).
private struct VADToggleMenuItem: View {
    @State private var isVADEnabled: Bool = VADConfigurationStore.load().vadModeEnabled
    @State private var hasSelectedModel: Bool = SpeechModelManager.shared.selectedModel != nil

    var body: some View {
        Button(label) {
            toggleVAD()
        }
        .keyboardShortcut("v", modifiers: [.command, .shift])
        .disabled(!hasSelectedModel)
        .onReceive(
            NotificationCenter.default.publisher(for: .voiceConfigurationChanged)
                .receive(on: RunLoop.main)
        ) { _ in
            let enabled = VADConfigurationStore.load().vadModeEnabled
            if enabled != isVADEnabled { isVADEnabled = enabled }
        }
        .onReceive(
            SpeechModelManager.shared.$selectedModelId
                .removeDuplicates()
                .receive(on: RunLoop.main)
        ) { _ in
            let hasModel = SpeechModelManager.shared.selectedModel != nil
            if hasModel != hasSelectedModel { hasSelectedModel = hasModel }
        }
    }

    private var label: String {
        guard hasSelectedModel else { return L("Toggle Voice Detection") }
        return isVADEnabled
            ? L("Disable Voice Detection") : L("Enable Voice Detection")
    }

    private func toggleVAD() {
        Task { @MainActor in
            let vadService = VADService.shared
            var config = VADConfigurationStore.load()
            let newState = !config.vadModeEnabled
            config.vadModeEnabled = newState
            VADConfigurationStore.save(config)
            isVADEnabled = newState
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
                    isVADEnabled = false
                    vadService.loadConfiguration()
                }
            }
        }
    }
}

// MARK: - Theme Menu Items

/// View-menu Theme submenu + font zoom items.
///
/// Observes `ThemeManager` locally so theme changes only invalidate these
/// items rather than re-evaluating every App-level `Commands` builder.
private struct ThemeMenuItems: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        Menu {
            appearanceButton(L("System"), mode: .system)
            appearanceButton(L("Light"), mode: .light)
            appearanceButton(L("Dark"), mode: .dark)

            Divider()

            ForEach(themeMenuThemeItems, id: \.metadata.id) { theme in
                Button {
                    if let mode = ThemeManager.appearanceMode(forBuiltInTheme: theme) {
                        themeManager.setAppearanceMode(mode, clearActiveTheme: true)
                    } else {
                        themeManager.applyCustomTheme(theme)
                    }
                } label: {
                    HStack {
                        Text(theme.metadata.name)
                        if isThemeMenuItemActive(theme) {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Divider()

            Button {
                Task { @MainActor in
                    AppDelegate.shared?.showManagementWindow(initialTab: .themes)
                }
            } label: {
                Text(verbatim: L("Manage Themes…"))
            }
        } label: {
            Text(verbatim: L("Theme"))
        }

        Divider()

        Button {
            themeManager.zoomFontIn()
        } label: {
            Text(verbatim: L("Zoom In"))
        }
        // "=" is the unshifted key under "+", matching how ⌘+ zoom is
        // reached without holding Shift in browsers.
        .keyboardShortcut("=", modifiers: .command)
        .disabled(!themeManager.canZoomFontIn)

        Button {
            themeManager.zoomFontOut()
        } label: {
            Text(verbatim: L("Zoom Out"))
        }
        .keyboardShortcut("-", modifiers: .command)
        .disabled(!themeManager.canZoomFontOut)

        Button {
            themeManager.resetFontScale()
        } label: {
            Text(verbatim: L("Actual Size"))
        }
        .keyboardShortcut("0", modifiers: .command)
        .disabled(themeManager.isDefaultFontScale)
    }

    private func appearanceButton(_ title: String, mode: AppearanceMode) -> some View {
        Button {
            themeManager.setAppearanceMode(mode, clearActiveTheme: true)
        } label: {
            HStack {
                Text(verbatim: title)
                if themeManager.activeCustomTheme == nil && themeManager.appearanceMode == mode {
                    Spacer()
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    private func isThemeMenuItemActive(_ theme: CustomTheme) -> Bool {
        if let mode = ThemeManager.appearanceMode(forBuiltInTheme: theme) {
            return themeManager.activeCustomTheme == nil && themeManager.appearanceMode == mode
        }
        return themeManager.activeCustomTheme?.metadata.id == theme.metadata.id
    }

    private var themeMenuThemeItems: [CustomTheme] {
        themeManager.installedThemes.filter { ThemeManager.appearanceMode(forBuiltInTheme: $0) == nil }
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
