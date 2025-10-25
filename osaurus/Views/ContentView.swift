//
//  ContentView.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import AppKit
import SwiftUI

struct ContentView: View {
  @EnvironmentObject var server: ServerController
  @EnvironmentObject private var updater: UpdaterViewModel
  @StateObject private var themeManager = ThemeManager.shared
  @Environment(\.theme) private var theme

  @State private var portString: String = "1337"
  @State private var showError: Bool = false

  var body: some View {
    ZStack {
      // Themed background
      theme.primaryBackground
        .ignoresSafeArea()

      VStack(spacing: 12) {
        TopStatusHeader(
          appName: "Osaurus",
          serverURL: "http://\(server.localNetworkAddress):\(String(server.port))",
          statusLineText: statusText,
          showPrimaryButton: shouldShowPrimaryButton,
          primaryButtonTitle: primaryButtonTitle,
          primaryButtonIcon: primaryButtonIcon,
          isPrimaryButtonBusy: isBusy,
          onPrimaryAction: toggleServer,
          badgeText: statusBadgeText,
          badgeColor: statusBadgeColor,
          badgeAnimating: statusBadgeAnimating
        )

        BottomActionBar(portString: $portString)
      }
      .padding(16)
    }
    .frame(
      width: 380,
      height: 150
    )
    .environment(\.theme, themeManager.currentTheme)
    .onAppear {
      portString = String(server.port)
    }
    .alert("Server Error", isPresented: $showError) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(server.lastErrorMessage ?? "An error occurred while managing the server.")
    }

  }

  // MARK: - Computed Properties
  private var statusText: String {
    switch server.serverHealth {
    case .stopped:
      return "Run LLMs locally"
    case .starting:
      return "Starting..."
    case .running:
      return "Running on port \(String(server.port))"
    case .restarting:
      return "Restarting..."
    case .stopping:
      return "Stopping..."
    case .error(let message):
      return "Error: \(message)"
    }
  }

  private var isBusy: Bool {
    switch server.serverHealth {
    case .starting, .restarting, .stopping: return true
    default: return false
    }
  }

  private var statusBadgeText: String {
    switch server.serverHealth {
    case .stopped: return "Stopped"
    case .starting: return "Starting"
    case .running: return "Running"
    case .restarting: return "Restarting"
    case .stopping: return "Stopping"
    case .error: return "Error"
    }
  }

  private var statusBadgeColor: Color {
    switch server.serverHealth {
    case .stopped: return .gray
    case .starting, .restarting, .stopping: return theme.warningColor
    case .running: return theme.successColor
    case .error: return theme.errorColor
    }
  }

  private var statusBadgeAnimating: Bool {
    switch server.serverHealth {
    case .starting, .restarting, .stopping: return true
    default: return false
    }
  }

  // MARK: - Private Helpers
  private func toggleServer() {
    guard server.serverHealth != .running else { return }
    guard let port = Int(portString), (1..<65536).contains(port) else {
      server.lastErrorMessage = "Please enter a valid port between 1 and 65535"
      showError = true
      return
    }
    server.port = port
    Task { @MainActor in
      await server.startServer()
      if server.lastErrorMessage != nil {
        showError = true
      }
    }
  }

}

extension ContentView {
  // MARK: - Primary Button State
  private var shouldShowPrimaryButton: Bool {
    if server.isRestarting { return false }
    switch server.serverHealth {
    case .stopped, .starting, .error:
      return true
    case .running, .restarting, .stopping:
      return false
    }
  }

  fileprivate var primaryButtonTitle: String {
    if server.isRestarting { return "" }
    switch server.serverHealth {
    case .stopped, .error: return "Start"
    case .starting: return "Starting…"
    case .restarting: return ""  // not shown
    case .stopping: return "Stopping…"  // not shown
    case .running: return ""
    }
  }

  fileprivate var primaryButtonIcon: String {
    if server.isRestarting { return "" }
    switch server.serverHealth {
    case .stopped, .error: return "play.circle.fill"
    case .starting, .restarting, .stopping: return "hourglass"
    case .running: return ""
    }
  }
}

// MARK: - Subviews
private struct TopStatusHeader: View {
  @Environment(\.theme) private var theme
  @EnvironmentObject var server: ServerController

  let appName: String
  let serverURL: String
  let statusLineText: String
  let showPrimaryButton: Bool
  let primaryButtonTitle: String
  let primaryButtonIcon: String
  let isPrimaryButtonBusy: Bool
  let onPrimaryAction: () -> Void
  let badgeText: String
  let badgeColor: Color
  let badgeAnimating: Bool

  var body: some View {
    HStack(spacing: 8) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .interpolation(.high)
        .antialiased(true)
        .scaledToFit()
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 8))

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(appName)
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .foregroundColor(theme.primaryText)

          StatusBadge(status: badgeText, color: badgeColor, isAnimating: badgeAnimating)
        }

        if server.isRunning || server.isRestarting {
          HStack(spacing: 6) {
            Text(serverURL)
              .font(.system(size: 11, weight: .regular, design: .monospaced))
              .minimumScaleFactor(0.8)
              .foregroundColor(theme.secondaryText)

            Button(action: copyURL) {
              Image(systemName: "doc.on.doc")
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
            }
            .buttonStyle(PlainButtonStyle())
            .help("Copy URL")
          }
          .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
          Text(statusLineText)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(theme.secondaryText)
        }
      }

      Spacer()

      if showPrimaryButton {
        SimpleToggleButton(
          isOn: false,
          title: primaryButtonTitle,
          icon: primaryButtonIcon,
          action: onPrimaryAction
        )
        .disabled(isPrimaryButtonBusy)
      }
    }
  }

  private func copyURL() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(serverURL, forType: .string)
  }
}

private struct BottomActionBar: View {
  @Environment(\.theme) private var theme
  @EnvironmentObject var server: ServerController
  @EnvironmentObject private var updater: UpdaterViewModel
  @Binding var portString: String
  @State private var showConfiguration = false

  var body: some View {
    HStack(spacing: 4) {
      SystemResourceMonitor()

      Spacer()

      HStack(spacing: 6) {
        CircularIconButton(systemName: "gearshape", help: "Configure server") {
          showConfiguration = true
        }
        .popover(
          isPresented: $showConfiguration, attachmentAnchor: .point(.bottom), arrowEdge: .top
        ) {
          ConfigurationView(portString: $portString, configuration: $server.configuration)
            .environmentObject(server)
        }

        CircularIconButton(systemName: "cube.box", help: "Manage models") {
          AppDelegate.shared?.showModelManagerWindow()
        }

        CircularIconButton(systemName: "arrow.up.circle", help: "Check for Updates…") {
          updater.checkForUpdates()
        }

        CircularIconButton(systemName: "power", help: "Quit") {
          NSApp.terminate(nil)
        }
      }
    }
  }
}

#Preview {
  ContentView()
    .environmentObject(ServerController())
}
