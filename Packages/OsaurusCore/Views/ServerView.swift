//
//  ServerView.swift
//  osaurus
//
//  Developer tools and API reference for building with Osaurus.
//

import AppKit
import SwiftUI

struct ServerView: View {
    @StateObject private var themeManager = ThemeManager.shared
    @EnvironmentObject var server: ServerController
    @Environment(\.theme) private var theme

    @State private var hasAppeared = false
    @State private var testResponse: EndpointTestResult?
    @State private var isTestingEndpoint = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Server Status Card
                    serverStatusCard

                    // API Endpoints Section
                    endpointsSection

                    // Response Viewer
                    if testResponse != nil {
                        responseViewer
                    }

                    // Documentation Link
                    documentationSection
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
                .frame(maxWidth: 800)
            }
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
    }

    // MARK: - Header View

    private var headerView: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Server")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(theme.primaryText)

                    Text("Developer tools and API reference")
                        .font(.system(size: 14))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .background(theme.secondaryBackground)
    }

    // MARK: - Server Status Card

    private var serverStatusCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Status", systemImage: "antenna.radiowaves.left.and.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.primaryText)

            HStack(spacing: 16) {
                // Server URL
                VStack(alignment: .leading, spacing: 8) {
                    Text("Server URL")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    HStack(spacing: 10) {
                        Text(serverURL)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.inputBackground)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(theme.inputBorder, lineWidth: 1)
                                    )
                            )

                        Button(action: copyServerURL) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(theme.secondaryText)
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(theme.tertiaryBackground)
                                )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Copy URL")
                    }
                }

                Spacer()

                // Status Badge
                VStack(alignment: .trailing, spacing: 8) {
                    Text("Status")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    ServerStatusBadge(health: server.serverHealth)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.secondaryBackground)
        )
    }

    // MARK: - Endpoints Section

    private var endpointsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("API Endpoints", systemImage: "arrow.left.arrow.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.primaryText)

            Text("Available endpoints on your Osaurus server. GET endpoints can be tested directly.")
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)

            VStack(spacing: 8) {
                ForEach(APIEndpoint.allEndpoints, id: \.path) { endpoint in
                    EndpointRow(
                        endpoint: endpoint,
                        serverURL: serverURL,
                        isServerRunning: server.isRunning,
                        onTest: { testEndpoint(endpoint) }
                    )
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.secondaryBackground)
        )
    }

    // MARK: - Response Viewer

    private var responseViewer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Response", systemImage: "doc.text")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Spacer()

                if let result = testResponse {
                    // Status code badge
                    Text("\(result.statusCode)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(result.isSuccess ? .white : .white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(result.isSuccess ? Color.green : Color.red)
                        )

                    // Duration
                    Text(String(format: "%.0fms", result.duration * 1000))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                }

                Button(action: copyResponse) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Copy response")

                Button(action: { testResponse = nil }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Close")
            }

            if let result = testResponse {
                ScrollView {
                    Text(result.formattedBody)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 300)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.codeBlockBackground)
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.secondaryBackground)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
        .animation(.easeInOut(duration: 0.2), value: testResponse != nil)
    }

    // MARK: - Documentation Section

    private var documentationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Documentation", systemImage: "book")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.primaryText)

            Text("Learn how to integrate Osaurus into your applications.")
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)

            Button(action: openDocumentation) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 12, weight: .medium))
                    Text("Open Documentation")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.accentColor)
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.secondaryBackground)
        )
    }

    // MARK: - Computed Properties

    private var serverURL: String {
        "http://\(server.localNetworkAddress):\(server.port)"
    }

    // MARK: - Actions

    private func copyServerURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(serverURL, forType: .string)
    }

    private func copyResponse() {
        guard let result = testResponse else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.formattedBody, forType: .string)
    }

    private func openDocumentation() {
        if let url = URL(string: "https://docs.osaurus.ai/") {
            NSWorkspace.shared.open(url)
        }
    }

    private func testEndpoint(_ endpoint: APIEndpoint) {
        guard server.isRunning else { return }
        guard endpoint.method == "GET" else { return }

        isTestingEndpoint = true

        Task {
            let startTime = Date()
            do {
                let url = URL(string: "\(serverURL)\(endpoint.path)")!
                let (data, response) = try await URLSession.shared.data(from: url)
                let duration = Date().timeIntervalSince(startTime)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

                await MainActor.run {
                    testResponse = EndpointTestResult(
                        endpoint: endpoint,
                        statusCode: statusCode,
                        body: data,
                        duration: duration,
                        error: nil
                    )
                    isTestingEndpoint = false
                }
            } catch {
                let duration = Date().timeIntervalSince(startTime)
                await MainActor.run {
                    testResponse = EndpointTestResult(
                        endpoint: endpoint,
                        statusCode: 0,
                        body: Data(),
                        duration: duration,
                        error: error.localizedDescription
                    )
                    isTestingEndpoint = false
                }
            }
        }
    }
}

// MARK: - API Endpoint Model

struct APIEndpoint {
    let method: String
    let path: String
    let description: String
    let compatibility: String?

    static let allEndpoints: [APIEndpoint] = [
        APIEndpoint(
            method: "GET",
            path: "/",
            description: "Root endpoint - server status message",
            compatibility: nil
        ),
        APIEndpoint(
            method: "GET",
            path: "/health",
            description: "Health check endpoint",
            compatibility: nil
        ),
        APIEndpoint(
            method: "GET",
            path: "/models",
            description: "List available models",
            compatibility: "OpenAI"
        ),
        APIEndpoint(
            method: "GET",
            path: "/tags",
            description: "List available models",
            compatibility: "Ollama"
        ),
        APIEndpoint(
            method: "POST",
            path: "/chat/completions",
            description: "Chat completions with streaming support",
            compatibility: "OpenAI"
        ),
        APIEndpoint(
            method: "POST",
            path: "/chat",
            description: "Chat endpoint",
            compatibility: "Ollama"
        ),
    ]
}

// MARK: - Endpoint Test Result

struct EndpointTestResult: Equatable {
    let endpoint: APIEndpoint
    let statusCode: Int
    let body: Data
    let duration: TimeInterval
    let error: String?

    var isSuccess: Bool {
        statusCode >= 200 && statusCode < 300
    }

    var formattedBody: String {
        if let error = error {
            return "Error: \(error)"
        }

        if let json = try? JSONSerialization.jsonObject(with: body, options: []),
            let prettyData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
            let prettyString = String(data: prettyData, encoding: .utf8)
        {
            return prettyString
        }

        return String(data: body, encoding: .utf8) ?? "(Unable to decode response)"
    }

    static func == (lhs: EndpointTestResult, rhs: EndpointTestResult) -> Bool {
        lhs.endpoint.path == rhs.endpoint.path && lhs.statusCode == rhs.statusCode && lhs.duration == rhs.duration
    }
}

extension APIEndpoint: Equatable {
    static func == (lhs: APIEndpoint, rhs: APIEndpoint) -> Bool {
        lhs.path == rhs.path && lhs.method == rhs.method
    }
}

// MARK: - Server Status Badge

private struct ServerStatusBadge: View {
    @Environment(\.theme) private var theme
    let health: ServerHealth

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .fill(statusColor.opacity(0.3))
                        .frame(width: 16, height: 16)
                        .opacity(isAnimating ? 1 : 0)
                        .animation(
                            isAnimating ? .easeInOut(duration: 1).repeatForever(autoreverses: true) : .default,
                            value: isAnimating
                        )
                )

            Text(statusText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(statusColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(statusColor.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(statusColor.opacity(0.3), lineWidth: 1)
                )
        )
    }

    private var statusColor: Color {
        switch health {
        case .running: return theme.successColor
        case .stopped: return theme.tertiaryText
        case .starting, .restarting, .stopping: return theme.warningColor
        case .error: return theme.errorColor
        }
    }

    private var statusText: String {
        health.statusDescription
    }

    private var isAnimating: Bool {
        switch health {
        case .starting, .restarting, .stopping: return true
        default: return false
        }
    }
}

// MARK: - Endpoint Row

private struct EndpointRow: View {
    @Environment(\.theme) private var theme

    let endpoint: APIEndpoint
    let serverURL: String
    let isServerRunning: Bool
    let onTest: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            // Method badge
            Text(endpoint.method)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(methodColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(methodColor.opacity(0.15))
                )
                .frame(width: 50)

            // Path
            Text(endpoint.path)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(theme.primaryText)

            // Compatibility badge
            if let compat = endpoint.compatibility {
                Text(compat)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.accentColor.opacity(0.1))
                    )
            }

            Spacer()

            // Description
            Text(endpoint.description)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .lineLimit(1)

            // Test button (only for GET endpoints)
            if endpoint.method == "GET" {
                Button(action: onTest) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9))
                        Text("Test")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(isServerRunning ? theme.accentColor : theme.tertiaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isServerRunning ? theme.accentColor.opacity(0.1) : theme.tertiaryBackground)
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(!isServerRunning)
                .help(isServerRunning ? "Test this endpoint" : "Start the server to test")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovering ? theme.tertiaryBackground.opacity(0.5) : Color.clear)
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    private var methodColor: Color {
        switch endpoint.method {
        case "GET": return .green
        case "POST": return .blue
        case "PUT": return .orange
        case "DELETE": return .red
        default: return theme.tertiaryText
        }
    }
}

// MARK: - Preview

#Preview {
    ServerView()
        .environmentObject(ServerController())
        .frame(width: 900, height: 700)
}
