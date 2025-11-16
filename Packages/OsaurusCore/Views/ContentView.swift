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
                    onRetry: toggleServer,
                    badgeText: statusBadgeText,
                    badgeColor: statusBadgeColor,
                    badgeAnimating: statusBadgeAnimating
                )

                BottomActionBar(portString: $portString)
            }
            .padding(16)
        }
        .frame(
            width: 300,
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
        guard let port = Int(portString), (1 ..< 65536).contains(port) else {
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

// MARK: - Subviews
private struct TopStatusHeader: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject var server: ServerController

    let appName: String
    let serverURL: String
    let statusLineText: String
    let onRetry: () -> Void
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

                    Spacer()

                    // Make the status badge clickable as "Retry" when in error state
                    if case .error = server.serverHealth {
                        Button(action: onRetry) {
                            StatusBadge(status: "Retry", color: badgeColor, isAnimating: badgeAnimating)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Retry")
                    } else {
                        StatusBadge(status: badgeText, color: badgeColor, isAnimating: badgeAnimating)
                    }
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
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundColor(theme.secondaryText)
                        .help(statusLineText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        VStack(spacing: 4) {
            SystemResourceMonitor()

            Spacer()

            HStack(spacing: 6) {
                CircularIconButton(systemName: "bubble.left", help: "Chat") {
                    AppDelegate.shared?.showChatOverlay()
                }

                CircularIconButton(systemName: "square.grid.2x2", help: "Management") {
                    AppDelegate.shared?.showManagementWindow()
                }

                CircularIconButton(systemName: "gearshape", help: "Configure server") {
                    showConfiguration = true
                }
                .popover(
                    isPresented: $showConfiguration,
                    attachmentAnchor: .point(.bottom),
                    arrowEdge: .top
                ) {
                    ConfigurationView(portString: $portString, configuration: $server.configuration)
                        .environmentObject(server)
                }

                CircularIconButton(systemName: "arrow.up.circle", help: "Check for Updates…") {
                    updater.checkForUpdates()
                }

                CircularIconButton(systemName: "questionmark.circle", help: "Documentation") {
                    if let url = URL(string: "https://docs.osaurus.ai/") {
                        NSWorkspace.shared.open(url)
                    }
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
