//
//  AppDelegate.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import AppKit
import Combine
import Sparkle
import QuartzCore
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
  let serverController = ServerController()
  private var statusItem: NSStatusItem?
  private var popover: NSPopover?
  private var cancellables: Set<AnyCancellable> = []
  let updater = UpdaterViewModel()
  private var pendingDeepLink: (modelId: String, file: String?)?
  private var activityDot: NSView?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Configure as menu bar app (hide Dock icon)
    NSApp.setActivationPolicy(.accessory)

    // App has launched
    print("Osaurus server app launched")

    // Set up observers for server state changes
    setupObservers()

    // Apply saved Start at Login preference on launch
    LoginItemService.shared.applyStartAtLogin(serverController.configuration.startAtLogin)

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

      // Add a small green blinking dot at the bottom-right of the status bar button
      let dot = NSView()
      dot.wantsLayer = true
      dot.translatesAutoresizingMaskIntoConstraints = false
      dot.isHidden = true
      button.addSubview(dot)
      NSLayoutConstraint.activate([
        dot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -3),
        dot.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -3),
        dot.widthAnchor.constraint(equalToConstant: 7),
        dot.heightAnchor.constraint(equalToConstant: 7),
      ])
      if let layer = dot.layer {
        layer.backgroundColor = NSColor.systemGreen.cgColor
        layer.cornerRadius = 3.5
        layer.borderWidth = 1
        layer.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
      }
      activityDot = dot
    }
    statusItem = item
    updateStatusItemAndMenu()
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      handleDeepLink(url)
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // Ask for confirmation before quitting
    let alert = NSAlert()
    alert.messageText = "Quit Osaurus?"
    alert.informativeText =
      serverController.isRunning
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
    SharedConfigurationService.shared.remove()
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

    serverController.$activeRequestCount
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.updateStatusItemAndMenu()
      }
      .store(in: &cancellables)

    // Publish shared configuration on state/config/address changes
    Publishers.CombineLatest3(
      serverController.$serverHealth,
      serverController.$configuration,
      serverController.$localNetworkAddress
    )
    .receive(on: RunLoop.main)
    .sink { health, config, address in
      SharedConfigurationService.shared.update(
        health: health,
        configuration: config,
        localAddress: address
      )
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
      // Toggle green blinking dot overlay
      let isGenerating = serverController.activeRequestCount > 0
      if let dot = activityDot {
        if isGenerating {
          dot.isHidden = false
          if let layer = dot.layer, layer.animation(forKey: "blink") == nil {
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = 1.0
            anim.toValue = 0.2
            anim.duration = 0.8
            anim.autoreverses = true
            anim.repeatCount = .infinity
            layer.add(anim, forKey: "blink")
          }
        } else {
          if let layer = dot.layer {
            layer.removeAnimation(forKey: "blink")
          }
          dot.isHidden = true
        }
      }
      var tooltip: String
      switch serverController.serverHealth {
      case .stopped:
        tooltip = "Osaurus — Ready to start"
      case .starting:
        tooltip = "Osaurus — Starting…"
      case .running:
        tooltip = "Osaurus — Running on port \(serverController.port)"
      case .stopping:
        tooltip = "Osaurus — Stopping…"
      case .error(let message):
        tooltip = "Osaurus — Error: \(message)"
      }
      if serverController.activeRequestCount > 0 {
        tooltip += " — Generating…"
      }
      button.toolTip = tooltip
    }
  }

  // MARK: - Actions

  @objc private func togglePopover(_ sender: Any?) {
    if let popover, popover.isShown {
      popover.performClose(sender)
      return
    }
    showPopover()
  }

  // Expose a method to show the popover programmatically (e.g., for Cmd+,)
  func showPopover() {
    guard let statusButton = statusItem?.button else { return }
    if let popover, popover.isShown {
      // Already visible; bring app to front
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    let popover = NSPopover()
    popover.behavior = .transient
    popover.animates = true

    let themeManager = ThemeManager.shared
    let contentView = ContentView(
      isPopover: true,
      onClose: { [weak self] in
        self?.popover?.performClose(nil)
      }, deeplinkModelId: pendingDeepLink?.modelId, deeplinkFile: pendingDeepLink?.file
    )
    .environmentObject(serverController)
    .environment(\.theme, themeManager.currentTheme)
    .environmentObject(updater)

    popover.contentViewController = NSHostingController(rootView: contentView)
    self.popover = popover

    popover.show(relativeTo: statusButton.bounds, of: statusButton, preferredEdge: .minY)
    NSApp.activate(ignoringOtherApps: true)

    // Clear pending deeplink after presenting
    pendingDeepLink = nil
  }

}

extension AppDelegate {
  fileprivate func handleDeepLink(_ url: URL) {
    guard let scheme = url.scheme?.lowercased(), scheme == "huggingface" else { return }
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
    let items = components.queryItems ?? []
    let modelId = items.first(where: { $0.name.lowercased() == "model" })?.value?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let file = items.first(where: { $0.name.lowercased() == "file" })?.value?.trimmingCharacters(
      in: .whitespacesAndNewlines)

    guard let modelId, !modelId.isEmpty else {
      // No model id provided; ignore silently
      return
    }

    // Resolve to ensure it appears in the UI; enforce MLX-only
    if ModelManager.shared.resolveModel(byRepoId: modelId) == nil {
      let alert = NSAlert()
      alert.messageText = "Unsupported model"
      alert.informativeText = "Osaurus only supports MLX-compatible Hugging Face repositories."
      alert.alertStyle = .warning
      alert.addButton(withTitle: "OK")
      alert.runModal()
      return
    }

    pendingDeepLink = (modelId: modelId, file: file)
    showPopover()
  }
}
