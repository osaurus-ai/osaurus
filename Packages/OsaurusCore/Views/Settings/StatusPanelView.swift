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
            theme.surface.canvas
                .ignoresSafeArea()

            VStack(spacing: 12) {
                TopStatusHeader(
                    appName: "Osaurus",
                    serverURL: "http://\(server.localNetworkAddress):\(String(server.port))",
                    statusLineText: statusText,
                    onRetry: toggleServer,
                    badgeText: statusBadgeText,
                    badgeColor: statusBadgeColor,
                    badgeKind: statusBadgeKind,
                    badgeAnimating: statusBadgeAnimating
                )

                BottomActionBar(portString: $portString)
            }
            .padding(theme.space.s16)
        }
        .frame(
            width: 320,
            height: 170
        )
        .environment(\.theme, themeManager.currentTheme)
        .tint(theme.action.primary.default.background)
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
            return L("Run LLMs locally")
        case .starting:
            return L("Starting...")
        case .running:
            return L("Running on port \(String(server.port))")
        case .restarting:
            return L("Restarting...")
        case .stopping:
            return L("Stopping...")
        case .error(let message):
            return L("Error: \(message)")
        }
    }

    private var statusBadgeText: String {
        switch server.serverHealth {
        case .stopped: return L("Stopped")
        case .starting: return L("Starting")
        case .running: return L("Running")
        case .restarting: return L("Restarting")
        case .stopping: return L("Stopping")
        case .error: return L("Error")
        }
    }

    private var statusBadgeKind: ThemeStatusKind? {
        switch server.serverHealth {
        case .stopped: return nil
        case .starting, .restarting, .stopping: return .warning
        case .running: return .success
        case .error: return .error
        }
    }

    private var statusBadgeColor: Color {
        statusBadgeKind.map { theme.status[$0].foreground } ?? theme.text.tertiary
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
    let badgeKind: ThemeStatusKind?
    let badgeAnimating: Bool

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .scaledToFit()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous))
                .onTapGesture {
                    AppDelegate.shared?.showManagementWindow(initialTab: .server)
                }
                .localizedHelp("Open Server Management")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Text(appName)
                            .font(SettingsFont.detailTitle)
                            .foregroundColor(theme.text.primary)

                        Text(verbatim: appVersion)
                            .font(SettingsFont.caption)
                            .foregroundColor(theme.text.tertiary)
                    }

                    Spacer()

                    // Show status indicator
                    if case .error = server.serverHealth {
                        RetryButton(action: onRetry)
                            .localizedHelp("Retry starting the server")
                    } else if case .running = server.serverHealth {
                        // Simple green dot for running state
                        StatusDot(color: badgeColor, isAnimating: false)
                            .localizedHelp("Server is running")
                    } else {
                        // Show full badge for transitional states
                        StatusBadge(status: badgeText, kind: badgeKind, isAnimating: badgeAnimating)
                    }
                }

                if server.isRunning || server.isRestarting {
                    HStack(spacing: 6) {
                        Text(serverURL)
                            .font(SettingsFont.monoSmall)
                            .minimumScaleFactor(0.8)
                            .foregroundColor(theme.text.secondary)

                        Button(action: copyURL) {
                            Image(systemName: "doc.on.doc")
                                .glyphSize(10)
                                .foregroundColor(theme.text.tertiary)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .localizedHelp("Copy URL")
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    Text(statusLineText)
                        .font(SettingsFont.monoSmall)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundColor(theme.text.secondary)
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
                .stroke(color.opacity(0.3), lineWidth: theme.stroke.focus)
                .frame(width: 14, height: 14)
                .scaleEffect(isAnimating ? 1.8 : 1.0)
                .opacity(isAnimating ? 0 : 0.6)
                .animation(
                    isAnimating ? theme.motion.loop(.easeOut, duration: 1.2) : theme.motion.standard,
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
        }
    }
}

// MARK: - Retry Button
private struct RetryButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(L("Retry"), systemImage: "arrow.clockwise")
        }
        .assignedSettingsButtonStyle(.destructive, size: .compact)
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
                        // Async variant avoids a synchronous LaunchServices XPC
                        // round-trip that can hang the main thread.
                        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            return theme.text.tertiary
        }

        // If VAD is disabled in settings, show as inactive (gray/tertiary)
        // unless it's running for some reason (state error?)
        if !isVADEnabledGlobally && vadService.state == .idle {
            return theme.text.tertiary
        }

        switch vadService.state {
        case .listening:
            return theme.status.success.foreground
        case .error:
            return theme.status.error.foreground
        default:
            return theme.text.primary
        }
    }

    private var tooltipText: String {
        if !canToggleVAD {
            return L("Voice Detection: No model selected")
        }
        if !isVADConfigured {
            return L("Voice Detection: Not configured (Select agents in settings)")
        }

        if !isVADEnabledGlobally {
            return L("Voice Detection: Disabled — Click to enable")
        }

        switch vadService.state {
        case .idle:
            return L("Voice Detection: Ready — Click to disable")
        case .starting:
            return L("Voice Detection: Starting...")
        case .listening:
            return L("Voice Detection: Listening — Click to disable")
        case .error(let msg):
            return L("Voice Detection Error: \(msg)")
        }
    }

    var body: some View {
        Button(action: toggleVAD) {
            ZStack {
                // Background
                Circle()
                    .fill(isActive ? iconColor.opacity(0.15) : theme.action.secondary.default.background)

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
                    .glyphSize(14)
                    .foregroundColor(iconColor)
                    .scaleEffect(pulseAnimation && vadService.state == .listening ? 1.08 : 1.0)
            }
            .frame(width: 28, height: 28)
            .overlay(
                Circle()
                    .strokeBorder(
                        isActive ? iconColor.opacity(0.4) : theme.border.subtle,
                        lineWidth: theme.stroke.default
                    )
            )
            .themeElevation(isActive ? theme.elevation.raised : .none)
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
        // Continuous decorative motion: keep the icon static under Reduce Motion.
        if currentState == .listening, !reduceMotion {
            withAnimation(theme.motion.loop(.easeInOut, duration: 1.0, autoreverses: true)) {
                pulseAnimation = true
            }
        } else {
            withAnimation(theme.motion.quick) {
                pulseAnimation = false
            }
        }
    }
}

// MARK: - Ask AI Button
private struct AskAIButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Ask AI", bundle: .module)
        }
        .assignedSettingsButtonStyle(.primary)
        .localizedHelp("Open AI Chat")
    }
}

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        StatusPanelView()
            .environmentObject(ServerController())
    }
#endif
