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
    @StateObject private var themeManager = ThemeManager.shared

    /// Use computed property to always get the current theme from ThemeManager
    private var theme: ThemeProtocol { themeManager.currentTheme }

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
        .tint(theme.selectionColor)
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

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .scaledToFit()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .onTapGesture {
                    AppDelegate.shared?.showManagementWindow(initialTab: .server)
                }
                .help("Open Server Management")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(appName)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(theme.primaryText)

                    Text("v\(appVersion)")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(theme.tertiaryText)

                    Spacer()

                    // Show status indicator
                    if case .error = server.serverHealth {
                        RetryButton(action: onRetry)
                            .help("Retry starting the server")
                    } else if case .running = server.serverHealth {
                        // Simple green dot for running state
                        StatusDot(color: badgeColor, isAnimating: false)
                            .help("Server is running")
                    } else {
                        // Show full badge for transitional states
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

// MARK: - Status Dot (Simple indicator)
private struct StatusDot: View {
    let color: Color
    let isAnimating: Bool

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.3), lineWidth: 3)
                    .scaleEffect(isAnimating ? 2.0 : 1.0)
                    .opacity(isAnimating ? 0 : 1)
                    .animation(
                        isAnimating ? .easeInOut(duration: 1.5).repeatForever(autoreverses: true) : .default,
                        value: isAnimating
                    )
            )
    }
}

// MARK: - Retry Button
private struct RetryButton: View {
    @Environment(\.theme) private var theme
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                Text("Retry")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(theme.errorColor)
            )
            .opacity(isHovering ? 0.85 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

private struct BottomActionBar: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject var server: ServerController
    @Binding var portString: String

    var body: some View {
        VStack(spacing: 4) {
            SystemResourceMonitor()

            Spacer()

            HStack(spacing: 6) {
                // Primary "Ask AI" button
                AskAIButton {
                    AppDelegate.shared?.showChatOverlay()
                }

                Spacer()

                CircularIconButton(systemName: "gearshape", help: "Settings") {
                    AppDelegate.shared?.showManagementWindow()
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

// MARK: - Ask AI Button
private struct AskAIButton: View {
    @Environment(\.theme) private var theme
    let action: () -> Void

    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Text("Ask AI")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.accentColor)
                )
                .shadow(
                    color: theme.accentColor.opacity(isHovering ? 0.4 : 0.2),
                    radius: isHovering ? 6 : 3,
                    x: 0,
                    y: 2
                )
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(isPressed ? 0.96 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isPressed)
        .animation(.easeInOut(duration: 0.2), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .onLongPressGesture(
            minimumDuration: .infinity,
            maximumDistance: .infinity,
            pressing: { pressing in
                isPressed = pressing
            },
            perform: {}
        )
        .help("Open AI Chat")
    }
}

#Preview {
    ContentView()
        .environmentObject(ServerController())
}
