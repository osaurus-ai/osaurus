//
//  ServerView.swift
//  osaurus
//
//  Developer tools and API reference for building with Osaurus.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ServerView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @EnvironmentObject var server: ServerController

    /// Use computed property to always get the current theme from ThemeManager
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var hasAppeared = false
    @State private var expandedEndpoint: String?
    @State private var editablePayloads: [String: String] = [:]
    @State private var endpointResponses: [String: EndpointTestResult] = [:]
    @State private var loadingEndpoints: Set<String> = []

    @State private var accessKeys: [AccessKeyInfo] = []
    @State private var showingKeyGenerator = false
    @State private var newKeyLabel = ""
    @State private var newKeyExpiration: AccessKeyExpiration = .days90
    @State private var generatedKey: String?
    @State private var isGeneratingKey = false
    @State private var keyGenError: String?
    @State private var copiedKeyId: UUID?

    @ObservedObject private var relayManager = RelayTunnelManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @State private var showRelayConfirmation = false
    @State private var pendingRelayAgentId: UUID?
    @State private var copiedRelayURL: UUID?

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

                    accessKeysSection

                    relaysSection

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
        .sheet(isPresented: $showingKeyGenerator) {
            AccessKeyGeneratorSheet(
                theme: theme,
                label: $newKeyLabel,
                expiration: $newKeyExpiration,
                isGenerating: $isGeneratingKey,
                error: $keyGenError,
                onGenerate: generateAccessKey,
                onCancel: {
                    showingKeyGenerator = false
                    newKeyLabel = ""
                    keyGenError = nil
                }
            )
        }
        .alert("Expose Agent to Internet?", isPresented: $showRelayConfirmation) {
            Button("Enable Tunnel", role: .destructive) {
                if let id = pendingRelayAgentId {
                    relayManager.setTunnelEnabled(true, for: id)
                }
                pendingRelayAgentId = nil
            }
            Button("Cancel", role: .cancel) {
                pendingRelayAgentId = nil
            }
        } message: {
            Text(
                "This will create a public URL for this agent via agent.osaurus.ai. Anyone with the URL can send requests to your local server. Your access keys still protect the API endpoints."
            )
        }
        .onAppear {
            reloadAccessKeys()
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
    }

    // MARK: - Header View

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: "Server",
            subtitle: "Developer tools and API reference"
        ) {
            if OsaurusIdentity.exists() {
                Button(action: { showingKeyGenerator = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Generate Access Key")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.accentColor)
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
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

    // MARK: - Relays Section

    private var relaysSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Relays", systemImage: "globe")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.primaryText)

            Text("Expose agents to the public internet via relay tunnels.")
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)

            let agents = agentManager.agents

            if agents.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 14))
                        .foregroundColor(theme.tertiaryText)
                    Text("No agents configured. Create an agent first.")
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.tertiaryBackground.opacity(0.5))
                )
            } else {
                VStack(spacing: 2) {
                    ForEach(agents) { agent in
                        relayAgentRow(agent)
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

    private func relayAgentRow(_ agent: Agent) -> some View {
        let hasIdentity = agent.agentAddress != nil && agent.agentIndex != nil
        let status = relayManager.agentStatuses[agent.id] ?? .disconnected
        let isEnabled = relayManager.isTunnelEnabled(for: agent.id)

        return HStack(spacing: 12) {
            // Status dot
            relayStatusDot(status)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)

                    if agent.isBuiltIn {
                        Text("Built-in")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(theme.tertiaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.tertiaryText.opacity(0.12)))
                    }
                }

                if let address = agent.agentAddress {
                    let truncated = String(address.prefix(8)) + "..." + String(address.suffix(4))
                    Text(truncated)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                } else {
                    Text("No identity set up")
                        .font(.system(size: 11))
                        .foregroundColor(theme.warningColor)
                }

                if case .connected(let url) = status {
                    HStack(spacing: 4) {
                        Text(url)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(theme.accentColor)
                            .lineLimit(1)

                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url, forType: .string)
                            copiedRelayURL = agent.id
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                if copiedRelayURL == agent.id { copiedRelayURL = nil }
                            }
                        }) {
                            Image(systemName: copiedRelayURL == agent.id ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(copiedRelayURL == agent.id ? theme.successColor : theme.tertiaryText)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Copy relay URL")
                    }
                }

                if case .error(let msg) = status {
                    Text(msg)
                        .font(.system(size: 10))
                        .foregroundColor(theme.errorColor)
                }
            }

            Spacer()

            if hasIdentity {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { isEnabled },
                        set: { newValue in
                            if newValue {
                                pendingRelayAgentId = agent.id
                                showRelayConfirmation = true
                            } else {
                                relayManager.setTunnelEnabled(false, for: agent.id)
                            }
                        }
                    )
                )
                .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                .labelsHidden()
            } else {
                Text("Identity →")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .help("Set up this agent's identity in the Identity tab")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.tertiaryBackground.opacity(0.5))
        )
    }

    @ViewBuilder
    private func relayStatusDot(_ status: AgentRelayStatus) -> some View {
        switch status {
        case .disconnected:
            Circle()
                .fill(theme.tertiaryText.opacity(0.4))
                .frame(width: 8, height: 8)
        case .connecting:
            Circle()
                .fill(theme.warningColor)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .fill(theme.warningColor.opacity(0.3))
                        .frame(width: 16, height: 16)
                )
        case .connected:
            Circle()
                .fill(theme.successColor)
                .frame(width: 8, height: 8)
        case .error:
            Circle()
                .fill(theme.errorColor)
                .frame(width: 8, height: 8)
        }
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
                                if endpoint.isAudioEndpoint {
                                    TranscriptionTestRow(
                                        endpoint: endpoint,
                                        serverURL: serverURL,
                                        isServerRunning: server.isRunning,
                                        isExpanded: expandedEndpoint == endpoint.path,
                                        isLoading: loadingEndpoints.contains(endpoint.path),
                                        response: endpointResponses[endpoint.path],
                                        onToggleExpand: {
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                if expandedEndpoint == endpoint.path {
                                                    expandedEndpoint = nil
                                                } else {
                                                    expandedEndpoint = endpoint.path
                                                }
                                            }
                                        },
                                        onTest: { audioData in
                                            runAudioTranscriptionTest(endpoint, audioData: audioData)
                                        },
                                        onClearResponse: {
                                            endpointResponses[endpoint.path] = nil
                                        }
                                    )
                                } else {
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
                                                        editablePayloads[endpoint.path] =
                                                            endpoint.examplePayload ?? "{}"
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
        case .embeddings: return "text.viewfinder"
        case .audio: return "waveform"
        case .memory: return "brain.head.profile"
        case .mcp: return "wrench.and.screwdriver"
        }
    }

    private func categoryColor(_ category: APIEndpoint.EndpointCategory) -> Color {
        switch category {
        case .core: return .blue
        case .chat: return .green
        case .embeddings: return .cyan
        case .audio: return .orange
        case .memory: return .pink
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

    // MARK: - Access Keys Section

    private var accessKeysSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Access Keys", systemImage: "key.horizontal")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.primaryText)

            if let generatedKey {
                generatedKeyBanner(key: generatedKey)
            }

            if accessKeys.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(theme.warningColor)
                        Text("Server is locked")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(theme.warningColor)
                    }
                    Text(
                        "All API endpoints are restricted until you create an access key. Click \"Generate Access Key\" to get started."
                    )
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.warningColor.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(theme.warningColor.opacity(0.15), lineWidth: 1)
                        )
                )
            } else {
                VStack(spacing: 2) {
                    ForEach(accessKeys) { key in
                        accessKeyRow(key)
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

    private func generatedKeyBanner(key: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.warningColor)
                Text("Copy this key now. It won't be shown again.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.warningColor)
            }

            HStack(spacing: 8) {
                Text(key)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .textSelection(.enabled)
                    .lineLimit(1)

                Spacer()

                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key, forType: .string)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10, weight: .medium))
                        Text("Copy")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(theme.accentColor)
                    )
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: {
                    withAnimation { generatedKey = nil }
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .padding(5)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(theme.tertiaryBackground)
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.tertiaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.warningColor.opacity(0.3), lineWidth: 1)
                    )
            )
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.warningColor.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.warningColor.opacity(0.15), lineWidth: 1)
                )
        )
    }

    private func accessKeyRow(_ key: AccessKeyInfo) -> some View {
        let inactive = !key.isActive
        return HStack(spacing: 12) {
            Image(systemName: "key.fill")
                .font(.system(size: 11))
                .foregroundColor(inactive ? theme.tertiaryText : theme.accentColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(key.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(inactive ? theme.tertiaryText : theme.primaryText)

                    if key.revoked {
                        keyBadge("Revoked", color: theme.errorColor)
                    } else if key.isExpired {
                        keyBadge("Expired", color: theme.warningColor)
                    } else {
                        keyBadge("Active", color: theme.successColor)
                    }

                    if key.aud == key.iss {
                        keyBadge("All Agents", color: theme.accentColor)
                    }
                }

                HStack(spacing: 8) {
                    Text(key.prefix + "...")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)

                    Text("Created \(formattedDate(key.createdAt))")
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)

                    if let expiresAt = key.expiresAt {
                        Text(
                            key.isExpired
                                ? "Expired \(formattedDate(expiresAt))" : "Expires \(formattedDate(expiresAt))"
                        )
                        .font(.system(size: 10))
                        .foregroundColor(key.isExpired ? theme.warningColor : theme.tertiaryText)
                    }
                }
            }

            Spacer()

            if !key.revoked {
                Button(action: {
                    APIKeyManager.shared.revoke(id: key.id)
                    reloadAccessKeys()
                    restartServerForKeyChange()
                }) {
                    Text("Revoke")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.errorColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.errorColor.opacity(0.1))
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(inactive ? theme.tertiaryBackground.opacity(0.25) : theme.tertiaryBackground.opacity(0.5))
        )
    }

    private func keyBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(color.opacity(0.12))
            )
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }

    // MARK: - Access Key Actions

    private func reloadAccessKeys() {
        accessKeys = APIKeyManager.shared.listKeys().sorted { $0.createdAt > $1.createdAt }
    }

    private func generateAccessKey() {
        let label = newKeyLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }

        isGeneratingKey = true
        keyGenError = nil

        do {
            let result = try APIKeyManager.shared.generate(label: label, expiration: newKeyExpiration)
            generatedKey = result.fullKey
            showingKeyGenerator = false
            newKeyLabel = ""
            reloadAccessKeys()
            restartServerForKeyChange()
        } catch {
            keyGenError = error.localizedDescription
        }

        isGeneratingKey = false
    }

    private func restartServerForKeyChange() {
        guard server.isRunning else { return }
        Task { await server.restartServer() }
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

    private func runAudioTranscriptionTest(_ endpoint: APIEndpoint, audioData: Data) {
        guard server.isRunning else { return }

        // Get the selected model
        let modelId = SpeechModelManager.shared.selectedModel?.id ?? "parakeet-v3"

        // Expand and mark as loading
        withAnimation(.easeInOut(duration: 0.2)) {
            expandedEndpoint = endpoint.path
            loadingEndpoints.insert(endpoint.path)
        }

        Task {
            let startTime = Date()
            do {
                let url = URL(string: "\(serverURL)\(endpoint.path)")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"

                // Create multipart/form-data
                let boundary = "Boundary-\(UUID().uuidString)"
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

                var body = Data()

                // Add file field
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append(
                    "Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\n".data(using: .utf8)!
                )
                body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
                body.append(audioData)
                body.append("\r\n".data(using: .utf8)!)

                // Add model field
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
                body.append(modelId.data(using: .utf8)!)
                body.append("\r\n".data(using: .utf8)!)

                // Close boundary
                body.append("--\(boundary)--\r\n".data(using: .utf8)!)

                request.httpBody = body

                let (data, response) = try await URLSession.shared.data(for: request)

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

// MARK: - Access Key Generator Sheet

private struct AccessKeyGeneratorSheet: View {
    let theme: ThemeProtocol
    @Binding var label: String
    @Binding var expiration: AccessKeyExpiration
    @Binding var isGenerating: Bool
    @Binding var error: String?
    let onGenerate: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 20) {
                HStack {
                    Text("Generate Access Key")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(theme.primaryText)
                    Spacer()
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(theme.tertiaryText)
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Label")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                    TextField("e.g. Cursor, CLI, my-app", text: $label)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.inputBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(theme.inputBorder, lineWidth: 1)
                                )
                        )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Expiration")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                    HStack(spacing: 8) {
                        ForEach(AccessKeyExpiration.allCases, id: \.rawValue) { option in
                            Button(action: { expiration = option }) {
                                Text(option.displayName)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(expiration == option ? .white : theme.primaryText)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(expiration == option ? theme.accentColor : theme.tertiaryBackground)
                                    )
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }

                if let error {
                    Text(error)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.errorColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.errorColor.opacity(0.1))
                        )
                }

                HStack(spacing: 12) {
                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.primaryText)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.tertiaryBackground)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(theme.inputBorder, lineWidth: 1)
                                    )
                            )
                    }
                    .buttonStyle(PlainButtonStyle())

                    Button(action: onGenerate) {
                        HStack(spacing: 6) {
                            if isGenerating {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 14, height: 14)
                            } else {
                                Image(systemName: "key.fill")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            Text("Generate")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(
                                    label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? theme.accentColor.opacity(0.4)
                                        : theme.accentColor
                                )
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(24)
        }
        .frame(width: 420)
        .background(theme.primaryBackground)
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
    let isAudioEndpoint: Bool

    init(
        method: String,
        path: String,
        description: String,
        compatibility: String?,
        category: EndpointCategory,
        examplePayload: String?,
        isAudioEndpoint: Bool = false
    ) {
        self.method = method
        self.path = path
        self.description = description
        self.compatibility = compatibility
        self.category = category
        self.examplePayload = examplePayload
        self.isAudioEndpoint = isAudioEndpoint
    }

    enum EndpointCategory: String {
        case core = "Core"
        case chat = "Chat"
        case embeddings = "Embeddings"
        case audio = "Audio"
        case memory = "Memory"
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
            APIEndpoint(
                method: "POST",
                path: "/responses",
                description: "Responses endpoint with streaming support",
                compatibility: "Open Responses",
                category: .chat,
                examplePayload: """
                    {
                      "model": "\(model)",
                      "input": "Hello!",
                      "stream": false
                    }
                    """
            ),
            // Embeddings endpoints
            APIEndpoint(
                method: "POST",
                path: "/embeddings",
                description: "Generate text embeddings",
                compatibility: "OpenAI",
                category: .embeddings,
                examplePayload: """
                    {
                      "model": "potion-base-4M",
                      "input": "Hello world"
                    }
                    """
            ),
            APIEndpoint(
                method: "POST",
                path: "/embed",
                description: "Generate text embeddings",
                compatibility: "Ollama",
                category: .embeddings,
                examplePayload: """
                    {
                      "model": "potion-base-4M",
                      "input": "Hello world"
                    }
                    """
            ),
            // Audio endpoints
            APIEndpoint(
                method: "POST",
                path: "/audio/transcriptions",
                description: "Transcribe audio to text",
                compatibility: "OpenAI",
                category: .audio,
                examplePayload: nil,
                isAudioEndpoint: true
            ),
            // Memory endpoints
            APIEndpoint(
                method: "GET",
                path: "/agents",
                description: "List all agents with memory counts",
                compatibility: "Osaurus",
                category: .memory,
                examplePayload: nil
            ),
            APIEndpoint(
                method: "POST",
                path: "/memory/ingest",
                description: "Bulk-ingest conversation turns into memory",
                compatibility: "Osaurus",
                category: .memory,
                examplePayload: """
                    {
                      "agent_id": "my-agent",
                      "conversation_id": "session-1",
                      "turns": [
                        {"user": "Hi, my name is Alice", "assistant": "Hello Alice!"}
                      ]
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
        let categories: [EndpointCategory] = [.core, .chat, .embeddings, .audio, .memory, .mcp]
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

// MARK: - Transcription Test Row

private struct TranscriptionTestRow: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var speechModelManager = SpeechModelManager.shared

    let endpoint: APIEndpoint
    let serverURL: String
    let isServerRunning: Bool
    let isExpanded: Bool
    let isLoading: Bool
    let response: EndpointTestResult?
    let onToggleExpand: () -> Void
    let onTest: (Data) -> Void
    let onClearResponse: () -> Void

    @State private var isHovering = false
    @State private var selectedFileURL: URL?
    @State private var selectedFileName: String?
    @State private var audioData: Data?
    @State private var fileError: String?

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
                        .foregroundColor(.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.blue.opacity(0.15))
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
                            .foregroundColor(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.green.opacity(0.1))
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

            // Expandable content
            if isExpanded {
                VStack(spacing: 0) {
                    Divider()
                        .background(theme.primaryBorder.opacity(0.3))

                    HStack(alignment: .top, spacing: 16) {
                        // LEFT: Request Panel
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("Request", systemImage: "arrow.up.circle.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(theme.secondaryText)

                                Spacer()
                            }

                            // Model display
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Model")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(theme.tertiaryText)

                                HStack(spacing: 8) {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 12))
                                        .foregroundColor(.orange)

                                    if let model = speechModelManager.selectedModel {
                                        Text(model.name)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(theme.primaryText)
                                    } else {
                                        Text("No model selected")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(theme.tertiaryText)
                                            .italic()
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(theme.inputBackground)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(theme.inputBorder, lineWidth: 1)
                                        )
                                )
                            }

                            // Audio file section
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Audio File")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(theme.tertiaryText)

                                if let fileName = selectedFileName {
                                    // File selected - inline display
                                    HStack(spacing: 10) {
                                        Image(systemName: "waveform")
                                            .font(.system(size: 12))
                                            .foregroundColor(theme.accentColor)

                                        Text(fileName)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(theme.primaryText)
                                            .lineLimit(1)

                                        if let data = audioData {
                                            Text("(\(formatFileSize(data.count)))")
                                                .font(.system(size: 11))
                                                .foregroundColor(theme.tertiaryText)
                                        }

                                        Spacer()

                                        Button(action: clearFile) {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundColor(theme.tertiaryText)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        .help("Remove file")
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(theme.inputBackground)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .stroke(theme.inputBorder, lineWidth: 1)
                                            )
                                    )
                                } else {
                                    // Empty state - prompt to select
                                    HStack(spacing: 8) {
                                        Image(systemName: "doc.badge.plus")
                                            .font(.system(size: 12))
                                            .foregroundColor(theme.tertiaryText)

                                        Text("No file selected")
                                            .font(.system(size: 12))
                                            .foregroundColor(theme.tertiaryText)
                                            .italic()

                                        Spacer()

                                        Text("WAV, MP3, M4A")
                                            .font(.system(size: 10))
                                            .foregroundColor(theme.tertiaryText.opacity(0.7))
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(theme.inputBackground)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .stroke(theme.inputBorder, lineWidth: 1)
                                            )
                                    )
                                }

                                // Error display
                                if let error = fileError {
                                    HStack(spacing: 6) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.system(size: 10))
                                        Text(error)
                                            .font(.system(size: 11))
                                    }
                                    .foregroundColor(theme.errorColor)
                                    .padding(.top, 4)
                                }
                            }

                            // Action buttons - matching EndpointRow style
                            HStack(spacing: 8) {
                                // Choose file button (secondary style)
                                Button(action: selectFile) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "folder")
                                            .font(.system(size: 10))
                                        Text("Choose File")
                                            .font(.system(size: 11, weight: .medium))
                                    }
                                    .foregroundColor(theme.secondaryText)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(theme.tertiaryBackground)
                                    )
                                }
                                .buttonStyle(PlainButtonStyle())

                                // Send button (primary style - matches EndpointRow)
                                Button(action: sendFile) {
                                    HStack(spacing: 6) {
                                        if isLoading {
                                            ProgressView()
                                                .scaleEffect(0.7)
                                                .frame(width: 12, height: 12)
                                        } else {
                                            Image(systemName: "paperplane.fill")
                                                .font(.system(size: 10))
                                        }
                                        Text(isLoading ? "Sending..." : "Send Request")
                                            .font(.system(size: 11, weight: .semibold))
                                    }
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity, minHeight: 18)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(
                                                audioData != nil && !isLoading
                                                    ? theme.accentColor : theme.tertiaryText
                                            )
                                    )
                                }
                                .buttonStyle(PlainButtonStyle())
                                .disabled(audioData == nil || isLoading)
                            }
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
                                    Text(String(format: "%.0fms", resp.duration * 1000))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(theme.tertiaryText)

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
                                    Text("Transcribing audio...")
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
                                    Image(systemName: "text.bubble")
                                        .font(.system(size: 24))
                                        .foregroundColor(theme.tertiaryText.opacity(0.5))
                                    Text("Select an audio file and send to see transcription")
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

    // MARK: - File Selection

    private func selectFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .audio,
            .wav,
            .mp3,
            .mpeg4Audio,
        ]
        panel.message = "Select an audio file to transcribe"
        panel.prompt = "Select"

        if panel.runModal() == .OK, let url = panel.url {
            loadFile(from: url)
        }
    }

    private func loadFile(from url: URL) {
        fileError = nil

        do {
            // Start accessing security-scoped resource
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let data = try Data(contentsOf: url)

            // Check file size (max 25MB like OpenAI)
            if data.count > 25 * 1024 * 1024 {
                fileError = "File too large (max 25MB)"
                return
            }

            audioData = data
            selectedFileURL = url
            selectedFileName = url.lastPathComponent
        } catch {
            fileError = "Failed to read file: \(error.localizedDescription)"
        }
    }

    private func clearFile() {
        audioData = nil
        selectedFileURL = nil
        selectedFileName = nil
        fileError = nil
    }

    private func sendFile() {
        guard let data = audioData else { return }
        onTest(data)
    }

    private func formatFileSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - Preview

#Preview {
    ServerView()
        .environmentObject(ServerController())
        .frame(width: 900, height: 700)
}
