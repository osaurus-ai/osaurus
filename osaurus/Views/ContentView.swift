//
//  ContentView.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import SwiftUI
import AppKit
import Sparkle

struct ContentView: View {
    @EnvironmentObject var server: ServerController
    @EnvironmentObject private var updater: UpdaterViewModel
    @StateObject private var themeManager = ThemeManager.shared
    @Environment(\.theme) private var theme
    // Popover customization
    var isPopover: Bool = false
    var onClose: (() -> Void)? = nil
    @State private var portString: String = "8080"
    @State private var showError: Bool = false
    @State private var isHealthy: Bool = false
    @State private var lastHealthCheck: Date?
    @State private var selectedModelId: String?
    @State private var showModelManager = false
    @State private var isEditingPort = false
    
    var body: some View {
        ZStack {
            // Themed background
            theme.primaryBackground
                .ignoresSafeArea()
            
            VStack(spacing: 16) {
                // Top row: Logo and status
                HStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .scaledToFit()
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Osaurus")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundColor(theme.primaryText)
                        
                        if server.isRunning {
                            HStack(spacing: 4) {
                                Text("http://127.0.0.1:\(String(server.port))")
                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                    .foregroundColor(theme.secondaryText)
                                
                                Button(action: {
                                    let url = "http://127.0.0.1:\(String(server.port))"
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(url, forType: .string)
                                }) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 10))
                                        .foregroundColor(theme.tertiaryText)
                                }
                                .buttonStyle(PlainButtonStyle())
                                .help("Copy URL")
                            }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        } else {
                            Text(statusText)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(theme.secondaryText)
                        }
                    }
                    
                    Spacer()
                    
                    // Primary control button in top-right
                    SimpleToggleButton(
                        isOn: server.serverHealth == .running,
                        title: primaryButtonTitle,
                        icon: primaryButtonIcon,
                        action: toggleServer
                    )
                    .disabled(isBusy)
                }
                
                // Bottom row: Actions
                HStack(spacing: 12) {
                    // Port configuration (inline)
                    if !server.isRunning && (isEditingPort || !isPopover) {
                        HStack(spacing: 6) {
                            Text("Port:")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(theme.secondaryText)
                            
                            TextField("8080", text: $portString)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .frame(width: 50)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(theme.inputBackground)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(theme.inputBorder, lineWidth: 1)
                                        )
                                )
                                .foregroundColor(theme.primaryText)
                        }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    
                    Spacer()
                    
                    // Action buttons
                    HStack(spacing: 8) {
                        if isPopover && !server.isRunning {
                            Button(action: { 
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isEditingPort.toggle()
                                }
                            }) {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 14))
                                    .foregroundColor(theme.primaryText)
                                    .frame(width: 28, height: 28)
                                    .background(
                                        Circle()
                                            .fill(theme.buttonBackground)
                                            .overlay(
                                                Circle()
                                                    .stroke(theme.buttonBorder, lineWidth: 1)
                                            )
                                    )
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help("Configure port")
                        }
                        
                        Divider()
                            .frame(height: 20)
                            .padding(.horizontal, 2)
                        
                        
                        Button(action: { showModelManager = true }) {
                            Image(systemName: "cube.box")
                                .font(.system(size: 14))
                                .foregroundColor(theme.primaryText)
                                .frame(width: 28, height: 28)
                                .background(
                                    Circle()
                                        .fill(theme.buttonBackground)
                                        .overlay(
                                            Circle()
                                                .stroke(theme.buttonBorder, lineWidth: 1)
                                        )
                                )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Manage models")
                        .popover(isPresented: $showModelManager, attachmentAnchor: .point(.bottom), arrowEdge: .top) {
                            ModelDownloadView()
                        }

                        Button(action: { updater.checkForUpdates() }) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 14))
                                .foregroundColor(theme.primaryText)
                                .frame(width: 28, height: 28)
                                .background(
                                    Circle()
                                        .fill(theme.buttonBackground)
                                        .overlay(
                                            Circle()
                                                .stroke(theme.buttonBorder, lineWidth: 1)
                                        )
                                )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Check for Updates…")

                        Button(action: { NSApp.terminate(nil) }) {
                            Image(systemName: "power")
                                .font(.system(size: 14))
                                .foregroundColor(theme.primaryText)
                                .frame(width: 28, height: 28)
                                .background(
                                    Circle()
                                        .fill(theme.buttonBackground)
                                        .overlay(
                                            Circle()
                                                .stroke(theme.buttonBorder, lineWidth: 1)
                                        )
                                )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Quit")
                    }
                }
            }
            .padding(20)
        }
        .frame(
            width: isPopover ? 380 : 420,
            height: isPopover ? 140 : 160
        )
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            portString = String(server.port)
            startHealthCheck()
        }
        .alert("Server Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(server.lastErrorMessage ?? "An error occurred while managing the server.")
        }
        
    }

    
    private var statusText: String {
        switch server.serverHealth {
        case .stopped:
            return "Run LLMs locally"
        case .starting:
            return "Starting..."
        case .running:
            return "Running on port \(String(server.port))"
        case .stopping:
            return "Stopping..."
        case .error(let message):
            return "Error: \(message)"
        }
    }
    
    private var statusDescription: String {
        switch server.serverHealth {
        case .stopped: return "Stopped"
        case .starting: return "Starting..."
        case .running: return "Running"
        case .stopping: return "Stopping..."
        case .error: return "Error"
        }
    }
    
    private var statusColor: Color {
        switch server.serverHealth {
        case .stopped: return .gray
        case .starting, .stopping: return .orange
        case .running: return .green
        case .error: return .red
        }
    }
    
    private var isBusy: Bool {
        switch server.serverHealth {
        case .starting, .stopping: return true
        default: return false
        }
    }
    
    private func toggleServer() {
        if server.isRunning {
            Task { @MainActor in
                await server.stopServer()
            }
        } else {
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
    
    private func startHealthCheck() {
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            Task { @MainActor in
                if server.isRunning {
                    isHealthy = await server.checkServerHealth()
                    lastHealthCheck = Date()
                }
            }
        }
    }
}

private extension ContentView {
    var primaryButtonTitle: String {
        switch server.serverHealth {
        case .stopped: return "Start"
        case .starting: return "Starting…"
        case .running: return "Stop"
        case .stopping: return "Stopping…"
        case .error: return "Retry"
        }
    }
    
    var primaryButtonIcon: String {
        switch server.serverHealth {
        case .stopped: return "play.circle.fill"
        case .starting: return "hourglass"
        case .running: return "stop.circle.fill"
        case .stopping: return "hourglass"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(ServerController())
}
