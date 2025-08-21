//
//  AppDelegate.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import SwiftUI
import AppKit
import Combine
import Sparkle

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let serverController = ServerController()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables: Set<AnyCancellable> = []
    let updater = UpdaterViewModel()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Configure as menu bar app (hide Dock icon)
        NSApp.setActivationPolicy(.accessory)
        
        // App has launched
        print("Osaurus server app launched")

        // Set up observers for server state changes
        setupObservers()

        // Create status bar item and attach click handler
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let image = NSImage(systemSymbolName: "brain", accessibilityDescription: "Osaurus") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "Osaurus"
            }
            button.toolTip = "Osaurus Server"
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        statusItem = item
        updateStatusItemAndMenu()
    }


    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Ask for confirmation before quitting
        let alert = NSAlert()
        alert.messageText = "Quit Osaurus?"
        alert.informativeText = serverController.isRunning
            ? "The local server will stop and any active requests will be cancelled."
            : "Are you sure you want to quit?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return .terminateCancel
        }

        guard serverController.isRunning else {
            return .terminateNow
        }
        
        // Delay termination to allow async shutdown
        Task { @MainActor in
            await serverController.ensureShutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        
        return .terminateLater
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        print("Osaurus server app terminating")
    }
    
    // MARK: - Status Item / Menu
    
    private func setupObservers() {
        cancellables.removeAll()
        serverController.$serverHealth
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemAndMenu()
            }
            .store(in: &cancellables)
        serverController.$isRunning
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemAndMenu()
            }
            .store(in: &cancellables)
        serverController.$configuration
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemAndMenu()
            }
            .store(in: &cancellables)
    }
    
    private func updateStatusItemAndMenu() {
        guard let statusItem else { return }
        // Ensure no NSMenu is attached so button action is triggered
        statusItem.menu = nil
        if let button = statusItem.button {
            // Update symbol based on server activity
            let isActive = (serverController.serverHealth == .running)
            let desiredName = isActive ? "brain.fill" : "brain"
            var image = NSImage(systemSymbolName: desiredName, accessibilityDescription: "Osaurus")
            if image == nil && isActive {
                // Fallback if brain.fill is unavailable on this macOS version
                image = NSImage(systemSymbolName: "brain", accessibilityDescription: "Osaurus")
            }
            if let image {
                image.isTemplate = true
                button.image = image
            }
            switch serverController.serverHealth {
                case .stopped:
                    button.toolTip = "Osaurus — Ready to start"
                case .starting:
                    button.toolTip = "Osaurus — Starting…"
                case .running:
                    button.toolTip = "Osaurus — Running on port \(serverController.port)"
                case .stopping:
                    button.toolTip = "Osaurus — Stopping…"
                case .error(let message):
                    button.toolTip = "Osaurus — Error: \(message)"
                }
        }
    }

    
    // MARK: - Actions

    @objc private func togglePopover(_ sender: Any?) {
        guard let statusButton = statusItem?.button else { return }

        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true

        let themeManager = ThemeManager.shared
        let contentView = ContentView(isPopover: true, onClose: { [weak self] in
            self?.popover?.performClose(nil)
        })
            .environmentObject(serverController)
            .environment(\.theme, themeManager.currentTheme)
            .environmentObject(updater)

        popover.contentViewController = NSHostingController(rootView: contentView)
        self.popover = popover

        popover.show(relativeTo: statusButton.bounds, of: statusButton, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }
    

}
