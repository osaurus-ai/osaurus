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

    /// Use computed property to always get the current theme from ThemeManager
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var hasAppeared = false
    @State private var expandedEndpoint: String?
    @State private var editablePayloads: [String: String] = [:]
    @State private var endpointResponses: [String: EndpointTestResult] = [:]
    @State private var loadingEndpoints: Set<String> = []

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

                    // Documentation Link
                    documentationSection
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
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

            VStack(spacing: 16) {
                ForEach(APIEndpoint.groupedEndpoints, id: \.category.rawValue) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        // Category header
                        HStack(spacing: 6) {
                            Image(systemName: categoryIcon(group.category))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(categoryColor(group.category))
                            Text(group.category.rawValue)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(theme.secondaryText)
                        }
                        .padding(.leading, 4)

                        VStack(spacing: 2) {
                            ForEach(group.endpoints, id: \.path) { endpoint in
                                EndpointRow(
                                    endpoint: endpoint,
                                    serverURL: serverURL,
                                    isServerRunning: server.isRunning,
                                    isExpanded: expandedEndpoint == endpoint.path,
                                    isLoading: loadingEndpoints.contains(endpoint.path),
                                    editablePayload: binding(for: endpoint),
                                    response: endpointResponses[endpoint.path],
                                    onToggleExpand: {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            if expandedEndpoint == endpoint.path {
                                                expandedEndpoint = nil
                                            } else {
                                                expandedEndpoint = endpoint.path
                                                // Initialize payload if not set
                                                if editablePayloads[endpoint.path] == nil {
                                                    editablePayloads[endpoint.path] = endpoint.examplePayload ?? "{}"
                                                }
                                            }
                                        }
                                    },
                                    onTest: {
                                        runEndpointTest(endpoint)
                                    },
                                    onClearResponse: {
                                        endpointResponses[endpoint.path] = nil
                                    }
                                )
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.secondaryBackground)
        )
    }

    private func categoryIcon(_ category: APIEndpoint.EndpointCategory) -> String {
        switch category {
        case .core: return "server.rack"
        case .chat: return "bubble.left.and.bubble.right"
        case .mcp: return "wrench.and.screwdriver"
        }
    }

    private func categoryColor(_ category: APIEndpoint.EndpointCategory) -> Color {
        switch category {
        case .core: return .blue
        case .chat: return .green
        case .mcp: return .purple
        }
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

    private func openDocumentation() {
        if let url = URL(string: "https://docs.osaurus.ai/") {
            NSWorkspace.shared.open(url)
        }
    }

    private func binding(for endpoint: APIEndpoint) -> Binding<String> {
        Binding(
            get: { editablePayloads[endpoint.path] ?? endpoint.examplePayload ?? "{}" },
            set: { editablePayloads[endpoint.path] = $0 }
        )
    }

    private func runEndpointTest(_ endpoint: APIEndpoint) {
        guard server.isRunning else { return }

        // Expand the endpoint to show results
        withAnimation(.easeInOut(duration: 0.2)) {
            expandedEndpoint = endpoint.path
            loadingEndpoints.insert(endpoint.path)
        }

        // Initialize payload if needed
        if editablePayloads[endpoint.path] == nil {
            editablePayloads[endpoint.path] = endpoint.examplePayload ?? "{}"
        }

        let payload = editablePayloads[endpoint.path] ?? endpoint.examplePayload ?? "{}"

        Task {
            let startTime = Date()
            do {
                let url = URL(string: "\(serverURL)\(endpoint.path)")!
                let data: Data
                let response: URLResponse

                if endpoint.method == "POST" {
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = payload.data(using: .utf8)
                    (data, response) = try await URLSession.shared.data(for: request)
                } else {
                    (data, response) = try await URLSession.shared.data(from: url)
                }

                let durationMs = Date().timeIntervalSince(startTime) * 1000
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

                await MainActor.run {
                    endpointResponses[endpoint.path] = EndpointTestResult(
                        endpoint: endpoint,
                        statusCode: statusCode,
                        body: data,
                        duration: durationMs / 1000,
                        error: nil
                    )
                    loadingEndpoints.remove(endpoint.path)
                }
            } catch {
                let durationMs = Date().timeIntervalSince(startTime) * 1000
                await MainActor.run {
                    endpointResponses[endpoint.path] = EndpointTestResult(
                        endpoint: endpoint,
                        statusCode: 0,
                        body: Data(),
                        duration: durationMs / 1000,
                        error: error.localizedDescription
                    )
                    loadingEndpoints.remove(endpoint.path)
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
    let category: EndpointCategory
    let examplePayload: String?

    enum EndpointCategory: String {
        case core = "Core"
        case chat = "Chat"
        case mcp = "MCP"
    }

    /// Returns the first available model name for use in example payloads.
    /// Prefers "foundation" when available, falls back to first local MLX model,
    /// then to a placeholder.
    private static var defaultExampleModel: String {
        if FoundationModelService.isDefaultModelAvailable() {
            return "foundation"
        }
        // Fall back to first local MLX model if available
        let localModels = ModelManager.discoverLocalModels()
        if let first = localModels.first {
            return first.id
        }
        // Final fallback to a placeholder
        return "your-model-name"
    }

    static var allEndpoints: [APIEndpoint] {
        let model = defaultExampleModel
        return [
            // Core endpoints
            APIEndpoint(
                method: "GET",
                path: "/",
                description: "Root endpoint - server status message",
                compatibility: nil,
                category: .core,
                examplePayload: nil
            ),
            APIEndpoint(
                method: "GET",
                path: "/health",
                description: "Health check endpoint",
                compatibility: nil,
                category: .core,
                examplePayload: nil
            ),
            APIEndpoint(
                method: "GET",
                path: "/models",
                description: "List available models",
                compatibility: "OpenAI",
                category: .core,
                examplePayload: nil
            ),
            APIEndpoint(
                method: "GET",
                path: "/tags",
                description: "List available models",
                compatibility: "Ollama",
                category: .core,
                examplePayload: nil
            ),
            APIEndpoint(
                method: "POST",
                path: "/show",
                description: "Show model metadata",
                compatibility: "Ollama",
                category: .core,
                examplePayload: """
                    {
                      "name": "\(model)"
                    }
                    """
            ),
            // Chat endpoints
            APIEndpoint(
                method: "POST",
                path: "/chat/completions",
                description: "Chat completions with streaming support",
                compatibility: "OpenAI",
                category: .chat,
                examplePayload: """
                    {
                      "model": "\(model)",
                      "messages": [
                        {"role": "user", "content": "Hello!"}
                      ],
                      "stream": false
                    }
                    """
            ),
            APIEndpoint(
                method: "POST",
                path: "/chat",
                description: "Chat endpoint (NDJSON streaming)",
                compatibility: "Ollama",
                category: .chat,
                examplePayload: """
                    {
                      "model": "\(model)",
                      "messages": [
                        {"role": "user", "content": "Hello!"}
                      ]
                    }
                    """
            ),
            APIEndpoint(
                method: "POST",
                path: "/messages",
                description: "Messages endpoint with streaming support",
                compatibility: "Anthropic",
                category: .chat,
                examplePayload: """
                    {
                      "model": "\(model)",
                      "max_tokens": 1024,
                      "messages": [
                        {"role": "user", "content": "Hello, Claude!"}
                      ],
                      "stream": false
                    }
                    """
            ),
            // MCP endpoints
            APIEndpoint(
                method: "GET",
                path: "/mcp/health",
                description: "MCP server health check",
                compatibility: "MCP",
                category: .mcp,
                examplePayload: nil
            ),
            APIEndpoint(
                method: "GET",
                path: "/mcp/tools",
                description: "List available tools",
                compatibility: "MCP",
                category: .mcp,
                examplePayload: nil
            ),
            APIEndpoint(
                method: "POST",
                path: "/mcp/call",
                description: "Execute a tool by name",
                compatibility: "MCP",
                category: .mcp,
                examplePayload: """
                    {
                      "name": "example_tool",
                      "arguments": {}
                    }
                    """
            ),
        ]
    }

    static var groupedEndpoints: [(category: EndpointCategory, endpoints: [APIEndpoint])] {
        let categories: [EndpointCategory] = [.core, .chat, .mcp]
        return categories.map { cat in
            (category: cat, endpoints: allEndpoints.filter { $0.category == cat })
        }
    }
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
    let isExpanded: Bool
    let isLoading: Bool
    @Binding var editablePayload: String
    let response: EndpointTestResult?
    let onToggleExpand: () -> Void
    let onTest: () -> Void
    let onClearResponse: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            // Main row - clickable header
            Button(action: {
                if isServerRunning {
                    onToggleExpand()
                }
            }) {
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
                            .foregroundColor(compatColor(compat))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(compatColor(compat).opacity(0.1))
                            )
                    }

                    Spacer()

                    // Description
                    Text(endpoint.description)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)

                    // Status indicator
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 20, height: 20)
                    } else if let resp = response {
                        // Status code badge
                        Text("\(resp.statusCode)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(resp.isSuccess ? Color.green : Color.red)
                            )
                    }

                    // Expand chevron
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(!isServerRunning)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovering || isExpanded ? theme.tertiaryBackground.opacity(0.5) : Color.clear)
            )
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isHovering = hovering
                }
            }

            // Expandable accordion with Request/Response panels
            if isExpanded {
                VStack(spacing: 0) {
                    Divider()
                        .background(theme.primaryBorder.opacity(0.3))

                    HStack(alignment: .top, spacing: 16) {
                        // LEFT: Request Panel
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label("Request", systemImage: "arrow.up.circle.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(theme.secondaryText)

                                Spacer()

                                if endpoint.method == "POST" {
                                    Button(action: {
                                        editablePayload = endpoint.examplePayload ?? "{}"
                                    }) {
                                        Text("Reset")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundColor(theme.tertiaryText)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }

                            if endpoint.method == "POST" {
                                // Editable JSON for POST
                                TextEditor(text: $editablePayload)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(minHeight: 120, maxHeight: 200)
                                    .scrollContentBackground(.hidden)
                                    .padding(8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(theme.inputBackground)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .stroke(theme.inputBorder, lineWidth: 1)
                                            )
                                    )
                                    .foregroundColor(theme.primaryText)
                            } else {
                                // GET request preview
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("GET \(serverURL)\(endpoint.path)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(theme.primaryText)
                                        .textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(theme.codeBlockBackground)
                                )
                            }

                            // Send button
                            Button(action: onTest) {
                                HStack(spacing: 6) {
                                    if isLoading {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                    } else {
                                        Image(systemName: "paperplane.fill")
                                            .font(.system(size: 10))
                                    }
                                    Text(isLoading ? "Sending..." : "Send Request")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(isLoading ? theme.tertiaryText : theme.accentColor)
                                )
                            }
                            .buttonStyle(PlainButtonStyle())
                            .disabled(isLoading)
                        }
                        .frame(maxWidth: .infinity)

                        // Divider between panels
                        Rectangle()
                            .fill(theme.primaryBorder.opacity(0.3))
                            .frame(width: 1)

                        // RIGHT: Response Panel
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label("Response", systemImage: "arrow.down.circle.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(theme.secondaryText)

                                Spacer()

                                if let resp = response {
                                    // Duration
                                    Text(String(format: "%.0fms", resp.duration * 1000))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(theme.tertiaryText)

                                    // Copy button
                                    Button(action: {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(resp.formattedBody, forType: .string)
                                    }) {
                                        Image(systemName: "doc.on.doc")
                                            .font(.system(size: 10))
                                            .foregroundColor(theme.tertiaryText)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .help("Copy response")

                                    // Clear button
                                    Button(action: onClearResponse) {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 10))
                                            .foregroundColor(theme.tertiaryText)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .help("Clear response")
                                }
                            }

                            if isLoading {
                                VStack {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("Waiting for response...")
                                        .font(.system(size: 11))
                                        .foregroundColor(theme.tertiaryText)
                                }
                                .frame(maxWidth: .infinity, minHeight: 120)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(theme.codeBlockBackground)
                                )
                            } else if let resp = response {
                                ScrollView {
                                    Text(resp.formattedBody)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(resp.isSuccess ? theme.primaryText : theme.errorColor)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(8)
                                }
                                .frame(minHeight: 120, maxHeight: 200)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(theme.codeBlockBackground)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(
                                                    resp.isSuccess ? Color.green.opacity(0.3) : Color.red.opacity(0.3),
                                                    lineWidth: 1
                                                )
                                        )
                                )
                            } else {
                                VStack(spacing: 8) {
                                    Image(systemName: "arrow.left.circle")
                                        .font(.system(size: 24))
                                        .foregroundColor(theme.tertiaryText.opacity(0.5))
                                    Text("Click 'Send Request' to test")
                                        .font(.system(size: 11))
                                        .foregroundColor(theme.tertiaryText)
                                }
                                .frame(maxWidth: .infinity, minHeight: 120)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(theme.codeBlockBackground)
                                )
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(16)
                }
                .background(theme.tertiaryBackground.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isExpanded ? theme.secondaryBackground : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isExpanded ? theme.primaryBorder.opacity(0.5) : Color.clear, lineWidth: 1)
                )
        )
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
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

    private func compatColor(_ compat: String) -> Color {
        switch compat {
        case "OpenAI": return .green
        case "Ollama": return .orange
        case "MCP": return .purple
        default: return theme.accentColor
        }
    }
}

// MARK: - Preview

#Preview {
    ServerView()
        .environmentObject(ServerController())
        .frame(width: 900, height: 700)
}
