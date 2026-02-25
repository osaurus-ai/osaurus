//
//  StatusPanelView.swift
//  osaurus
//
//  The main status panel shown in the menu bar. Displays server status,
//  system resources, and quick actions for accessing AI chat and settings.
//

import AppKit
import SwiftUI

struct StatusPanelView: View {
    @EnvironmentObject var server: ServerController
    @ObservedObject private var themeManager = ThemeManager.shared

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
        .tint(theme.accentColor)
        .onAppear {
            portString = String(server.port)
        }
        .themedAlert(
            "Server Error",
            isPresented: $showError,
            message: server.lastErrorMessage ?? "An error occurred while managing the server.",
            primaryButton: .primary("OK") {}
        )
        .themedAlertScope(.content)
        .overlay(ThemedAlertHost(scope: .content))

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
    @Environment(\.theme) private var theme
    let color: Color
    let isAnimating: Bool

    var body: some View {
        ZStack {
            // Glow ring
            Circle()
                .fill(color.opacity(0.2))
                .frame(width: 16, height: 16)
                .blur(radius: 2)

            // Pulse animation
            Circle()
                .stroke(color.opacity(0.3), lineWidth: 2)
                .frame(width: 14, height: 14)
                .scaleEffect(isAnimating ? 1.8 : 1.0)
                .opacity(isAnimating ? 0 : 0.6)
                .animation(
                    isAnimating ? .easeOut(duration: 1.2).repeatForever(autoreverses: false) : .default,
                    value: isAnimating
                )

            // Core dot
            Circle()
                .fill(
                    RadialGradient(
                        colors: [color, color.opacity(0.8)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 5
                    )
                )
                .frame(width: 10, height: 10)
                .shadow(color: color.opacity(0.5), radius: 3, x: 0, y: 0)
        }
    }
}

// MARK: - Retry Button
private struct RetryButton: View {
    @Environment(\.theme) private var theme
    let action: () -> Void

    @State private var isHovered = false

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
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.errorColor)

                    if isHovered {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.15))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(isHovered ? 0.3 : 0.2), theme.errorColor.opacity(0.3)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: theme.errorColor.opacity(isHovered ? 0.4 : 0.25),
                radius: isHovered ? 6 : 3,
                x: 0,
                y: 2
            )
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
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

                // VAD Toggle Button
                VADToggleButton()

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

// MARK: - VAD Toggle Button
private struct VADToggleButton: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var vadService = VADService.shared
    @ObservedObject private var speechModelManager = SpeechModelManager.shared

    @State private var pulseAnimation = false

    /// Whether VAD can be toggled (requirements met)
    private var canToggleVAD: Bool {
        speechModelManager.selectedModel != nil
    }

    /// Whether VAD mode is configured (has enabled agents)
    /// Note: We ignore vadModeEnabled here because the button itself acts as the toggle for it.
    private var isVADConfigured: Bool {
        let config = VADConfigurationStore.load()
        // If agents are configured, we can toggle VAD mode
        return !config.enabledAgentIds.isEmpty
    }

    private var isActive: Bool {
        vadService.state == .listening
    }

    private var isVADEnabledGlobally: Bool {
        let config = VADConfigurationStore.load()
        return config.vadModeEnabled
    }

    private var iconColor: Color {
        guard canToggleVAD && isVADConfigured else {
            return theme.tertiaryText
        }

        // If VAD is disabled in settings, show as inactive (gray/tertiary)
        // unless it's running for some reason (state error?)
        if !isVADEnabledGlobally && vadService.state == .idle {
            return theme.tertiaryText
        }

        switch vadService.state {
        case .listening:
            return theme.successColor
        case .error:
            return theme.errorColor
        default:
            return theme.primaryText
        }
    }

    private var tooltipText: String {
        if !canToggleVAD {
            return "Voice Detection: No model selected"
        }
        if !isVADConfigured {
            return "Voice Detection: Not configured (Select agents in settings)"
        }

        if !isVADEnabledGlobally {
            return "Voice Detection: Disabled — Click to enable"
        }

        switch vadService.state {
        case .idle:
            return "Voice Detection: Ready — Click to disable"
        case .starting:
            return "Voice Detection: Starting..."
        case .listening:
            return "Voice Detection: Listening — Click to disable"
        case .error(let msg):
            return "Voice Detection Error: \(msg)"
        }
    }

    var body: some View {
        Button(action: toggleVAD) {
            ZStack {
                // Background
                Circle()
                    .fill(isActive ? iconColor.opacity(0.15) : theme.buttonBackground)

                // Accent gradient when active
                if isActive {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [iconColor.opacity(0.15), Color.clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                // Icon
                Image(systemName: isActive ? "waveform.circle.fill" : "waveform.circle")
                    .font(.system(size: 14))
                    .foregroundColor(iconColor)
                    .scaleEffect(pulseAnimation && vadService.state == .listening ? 1.08 : 1.0)
            }
            .frame(width: 28, height: 28)
            .overlay(
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                isActive ? iconColor.opacity(0.4) : theme.glassEdgeLight.opacity(0.15),
                                isActive ? iconColor.opacity(0.2) : theme.buttonBorder,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isActive ? iconColor.opacity(0.3) : .clear,
                radius: 4,
                x: 0,
                y: 1
            )
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!canToggleVAD || !isVADConfigured)
        .opacity(canToggleVAD && isVADConfigured ? 1.0 : 0.4)
        .help(tooltipText)
        .onAppear {
            startPulseIfNeeded()
        }
        .onChange(of: vadService.state) { _, newState in
            startPulseIfNeeded(for: newState)
        }
    }

    private func toggleVAD() {
        Task {
            // Act as a global toggle
            var config = VADConfigurationStore.load()
            let newState = !config.vadModeEnabled
            config.vadModeEnabled = newState
            VADConfigurationStore.save(config)

            // Reload service configuration
            vadService.loadConfiguration()

            do {
                if newState {
                    try await vadService.start()
                } else {
                    await vadService.stop()
                }
            } catch {
                print("[VADToggleButton] Failed to toggle VAD: \(error)")
                // Revert if start failed (optional, but good UX)
                if newState {
                    config.vadModeEnabled = false
                    VADConfigurationStore.save(config)
                    vadService.loadConfiguration()
                }
            }
        }
    }

    private func startPulseIfNeeded(for state: VADServiceState? = nil) {
        let currentState = state ?? vadService.state
        if currentState == .listening {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulseAnimation = true
            }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                pulseAnimation = false
            }
        }
    }
}

// MARK: - Ask AI Button
private struct AskAIButton: View {
    @Environment(\.theme) private var theme
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Text("Ask AI")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    ZStack {
                        // Base gradient
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [theme.accentColor, theme.accentColor.opacity(0.85)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )

                        // Hover highlight
                        if isHovered {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.12))
                        }
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isHovered ? 0.35 : 0.2),
                                    theme.accentColor.opacity(0.3),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(
                    color: theme.accentColor.opacity(isHovered ? 0.5 : 0.3),
                    radius: isHovered ? 10 : 5,
                    x: 0,
                    y: isHovered ? 4 : 2
                )
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(isPressed ? 0.96 : 1.0)
        .animation(.easeOut(duration: 0.1), value: isPressed)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
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
    StatusPanelView()
        .environmentObject(ServerController())
}
