//
//  ProvidersView.swift
//  osaurus
//
//  UI for managing remote MCP providers.
//

import SwiftUI

struct ProvidersView: View {
    @Environment(\.theme) private var theme
    @StateObject private var manager = MCPProviderManager.shared
    @State private var showAddSheet = false
    @State private var editingProvider: MCPProvider?
    @State private var hasAppeared = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                // Header with add button
                headerSection

                if manager.configuration.providers.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(manager.configuration.providers.enumerated()), id: \.element.id) {
                        index,
                        provider in
                        ProviderCard(
                            provider: provider,
                            state: manager.providerStates[provider.id],
                            animationIndex: index,
                            onEdit: { editingProvider = provider },
                            onDelete: { manager.removeProvider(id: provider.id) },
                            onConnect: { Task { try? await manager.connect(providerId: provider.id) } },
                            onDisconnect: { manager.disconnect(providerId: provider.id) },
                            onToggleEnabled: { enabled in
                                manager.setEnabled(enabled, for: provider.id)
                            }
                        )
                    }
                }
            }
            .padding(24)
        }
        .opacity(hasAppeared ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.25).delay(0.1)) {
                hasAppeared = true
            }
        }
        .sheet(isPresented: $showAddSheet) {
            ProviderEditSheet(provider: nil) { provider, token in
                manager.addProvider(provider, token: token)
            }
        }
        .sheet(item: $editingProvider) { provider in
            ProviderEditSheet(provider: provider) { updatedProvider, token in
                manager.updateProvider(updatedProvider, token: token)
            }
        }
    }

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("MCP Providers")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundColor(theme.primaryText)

                Text("Connect to remote MCP servers to access additional tools")
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            Button(action: { showAddSheet = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Add Provider")
                        .font(.system(size: 13, weight: .semibold))
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

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(theme.accentColor.opacity(0.1))
                    .frame(width: 80, height: 80)
                Image(systemName: "server.rack")
                    .font(.system(size: 32, weight: .light))
                    .foregroundColor(theme.accentColor)
            }

            Text("No MCP Providers")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(theme.primaryText)

            Text("Add a remote MCP server to discover and use its tools")
                .font(.system(size: 14))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)

            Button(action: { showAddSheet = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14))
                    Text("Add Your First Provider")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundColor(theme.accentColor)
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

// MARK: - Provider Card

private struct ProviderCard: View {
    @Environment(\.theme) private var theme
    let provider: MCPProvider
    let state: MCPProviderState?
    var animationIndex: Int = 0
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onToggleEnabled: (Bool) -> Void

    @State private var isExpanded = false
    @State private var isHovering = false
    @State private var hasAppeared = false
    @State private var showDeleteConfirm = false

    private var isConnected: Bool {
        state?.isConnected ?? false
    }

    private var isConnecting: Bool {
        state?.isConnecting ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row
            HStack(spacing: 14) {
                // Provider icon with status
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(statusColor.opacity(0.12))
                    Image(systemName: "server.rack")
                        .font(.system(size: 20))
                        .foregroundColor(statusColor)
                }
                .frame(width: 44, height: 44)

                // Provider info
                Button(action: { withAnimation(.spring(response: 0.3)) { isExpanded.toggle() } }) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(provider.name)
                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                    .foregroundColor(theme.primaryText)

                                statusBadge
                            }

                            Text(provider.url)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(theme.tertiaryText)
                                .lineLimit(1)
                        }

                        Spacer()

                        // Tool count when connected
                        if isConnected, let toolCount = state?.discoveredToolCount, toolCount > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "wrench.and.screwdriver")
                                    .font(.system(size: 10))
                                Text("\(toolCount) tools")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(theme.secondaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(theme.tertiaryBackground))
                        }

                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.tertiaryText)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())

                // Actions
                HStack(spacing: 8) {
                    if isConnecting {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 28, height: 28)
                    } else if isConnected {
                        Button(action: onDisconnect) {
                            Text("Disconnect")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(theme.errorColor)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(theme.errorColor.opacity(0.1))
                                )
                        }
                        .buttonStyle(PlainButtonStyle())
                    } else {
                        Button(action: onConnect) {
                            Text("Connect")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(theme.accentColor)
                                )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(!provider.enabled)
                        .opacity(provider.enabled ? 1 : 0.5)
                    }

                    Menu {
                        Button(action: onEdit) {
                            Label("Edit", systemImage: "pencil")
                        }
                        Divider()
                        Button(role: .destructive, action: { showDeleteConfirm = true }) {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 16))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 28, height: 28)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Toggle(
                        "",
                        isOn: Binding(
                            get: { provider.enabled },
                            set: { onToggleEnabled($0) }
                        )
                    )
                    .toggleStyle(SwitchToggleStyle())
                    .labelsHidden()
                    .scaleEffect(0.85)
                }
            }

            // Error message
            if let error = state?.lastError, !isConnected {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(theme.errorColor)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(theme.errorColor)
                        .lineLimit(2)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.errorColor.opacity(0.08))
                )
            }

            // Expanded content
            if isExpanded {
                Divider()
                    .padding(.vertical, 4)

                expandedContent
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .background(cardBackground)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { hovering in isHovering = hovering }
        .opacity(hasAppeared ? 1 : 0)
        .onAppear {
            let delay = Double(animationIndex) * 0.03
            withAnimation(.easeOut(duration: 0.25).delay(delay)) {
                hasAppeared = true
            }
        }
        .alert("Delete Provider?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { onDelete() }
        } message: {
            Text("This will remove the provider and all its tools. This cannot be undone.")
        }
    }

    private var statusColor: Color {
        if !provider.enabled {
            return theme.tertiaryText
        } else if isConnected {
            return theme.successColor
        } else if isConnecting {
            return theme.accentColor
        } else if state?.lastError != nil {
            return theme.errorColor
        } else {
            return theme.secondaryText
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if !provider.enabled {
            Text("Disabled")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.tertiaryText)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(theme.tertiaryBackground))
        } else if isConnected {
            HStack(spacing: 4) {
                Circle().fill(theme.successColor).frame(width: 6, height: 6)
                Text("Connected")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.successColor)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.successColor.opacity(0.12)))
        } else if isConnecting {
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.5)
                Text("Connecting...")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.accentColor)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.accentColor.opacity(0.12)))
        } else if state?.lastError != nil {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 8))
                Text("Error")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(theme.errorColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.errorColor.opacity(0.12)))
        }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Settings summary
            HStack(spacing: 16) {
                settingItem(icon: "bolt.fill", label: "Streaming", value: provider.streamingEnabled ? "On" : "Off")
                settingItem(icon: "clock", label: "Timeout", value: "\(Int(provider.toolCallTimeout))s")
                settingItem(
                    icon: "arrow.clockwise",
                    label: "Auto-connect",
                    value: provider.autoConnect ? "Yes" : "No"
                )
            }

            // Custom headers summary
            if !provider.customHeaders.isEmpty || !provider.secretHeaderKeys.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                    Text(
                        "\(provider.customHeaders.count + provider.secretHeaderKeys.count) custom header\(provider.customHeaders.count + provider.secretHeaderKeys.count == 1 ? "" : "s")"
                    )
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                }
            }

            // Discovered tools list
            if isConnected, let toolNames = state?.discoveredToolNames, !toolNames.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Discovered Tools")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.secondaryText)

                    FlowLayoutView(items: toolNames) { name in
                        HStack(spacing: 4) {
                            Image(systemName: "function")
                                .font(.system(size: 9))
                            Text(name)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(theme.tertiaryBackground))
                        .foregroundColor(theme.primaryText)
                    }
                }
            }
        }
    }

    private func settingItem(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
            Text("\(label):")
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(theme.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isHovering ? theme.accentColor.opacity(0.2) : theme.cardBorder, lineWidth: 1)
            )
            .shadow(
                color: theme.shadowColor.opacity(isHovering ? theme.shadowOpacity * 1.5 : theme.shadowOpacity),
                radius: isHovering ? 12 : theme.cardShadowRadius,
                x: 0,
                y: isHovering ? 4 : theme.cardShadowY
            )
    }
}

// MARK: - Provider Edit Sheet

private struct ProviderEditSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let provider: MCPProvider?
    let onSave: (MCPProvider, String?) -> Void

    @State private var name: String = ""
    @State private var url: String = ""
    @State private var token: String = ""
    @State private var customHeaders: [HeaderEntry] = []
    @State private var streamingEnabled: Bool = false
    @State private var discoveryTimeout: Double = 20
    @State private var toolCallTimeout: Double = 45
    @State private var autoConnect: Bool = true

    @State private var isTesting: Bool = false
    @State private var testResult: TestResult?
    @State private var showAdvanced: Bool = false

    private var isEditing: Bool { provider != nil }

    struct HeaderEntry: Identifiable {
        let id = UUID()
        var key: String
        var value: String
        var isSecret: Bool
    }

    enum TestResult {
        case success(Int)
        case failure(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isEditing ? "Edit Provider" : "Add Provider")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(20)

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Basic section
                    FormSection(title: "Basic") {
                        FormField(label: "Name") {
                            TextField("My MCP Server", text: $name)
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground))
                        }

                        FormField(label: "URL") {
                            TextField("https://mcp.example.com", text: $url)
                                .textFieldStyle(.plain)
                                .font(.system(.body, design: .monospaced))
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground))
                        }

                        FormField(label: "Bearer Token", hint: "Optional - stored securely in Keychain") {
                            SecureField("Enter token", text: $token)
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground))
                        }
                    }

                    // Headers section
                    FormSection(title: "Custom Headers", trailing: { addHeaderButton }) {
                        if customHeaders.isEmpty {
                            Text("No custom headers")
                                .font(.system(size: 13))
                                .foregroundColor(theme.tertiaryText)
                                .padding(.vertical, 8)
                        } else {
                            ForEach($customHeaders) { $header in
                                HeaderRow(header: $header) {
                                    customHeaders.removeAll { $0.id == header.id }
                                }
                            }
                        }
                    }

                    // Advanced section
                    DisclosureGroup(isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 16) {
                            Toggle("Enable Streaming", isOn: $streamingEnabled)
                                .toggleStyle(SwitchToggleStyle())

                            Toggle("Auto-connect on Launch", isOn: $autoConnect)
                                .toggleStyle(SwitchToggleStyle())

                            FormField(label: "Discovery Timeout: \(Int(discoveryTimeout))s") {
                                Slider(value: $discoveryTimeout, in: 5 ... 60, step: 5)
                            }

                            FormField(label: "Tool Call Timeout: \(Int(toolCallTimeout))s") {
                                Slider(value: $toolCallTimeout, in: 10 ... 120, step: 5)
                            }
                        }
                        .padding(.top, 12)
                    } label: {
                        HStack {
                            Image(systemName: "gearshape")
                                .font(.system(size: 12))
                            Text("Advanced Settings")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundColor(theme.secondaryText)
                    }

                    // Test result
                    if let result = testResult {
                        testResultView(result)
                    }
                }
                .padding(20)
            }

            Divider()

            // Footer
            HStack(spacing: 12) {
                Button(action: testConnection) {
                    HStack(spacing: 6) {
                        if isTesting {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 12))
                        }
                        Text("Test Connection")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground))
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(url.isEmpty || isTesting)

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Button(action: save) {
                    Text(isEditing ? "Save" : "Add Provider")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(canSave ? theme.accentColor : theme.accentColor.opacity(0.5))
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(!canSave)
            }
            .padding(20)
        }
        .frame(width: 520, height: 600)
        .background(theme.primaryBackground)
        .onAppear { loadProvider() }
    }

    private var addHeaderButton: some View {
        Button(action: {
            customHeaders.append(HeaderEntry(key: "", value: "", isSecret: false))
        }) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                Text("Add")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(theme.accentColor)
        }
        .buttonStyle(PlainButtonStyle())
    }

    @ViewBuilder
    private func testResultView(_ result: TestResult) -> some View {
        HStack(spacing: 10) {
            switch result {
            case .success(let count):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(theme.successColor)
                Text("Connection successful! Found \(count) tools.")
                    .foregroundColor(theme.successColor)
            case .failure(let error):
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(theme.errorColor)
                Text(error)
                    .foregroundColor(theme.errorColor)
                    .lineLimit(2)
            }
        }
        .font(.system(size: 13))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    (result.isSuccess ? theme.successColor : theme.errorColor).opacity(0.1)
                )
        )
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !url.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func loadProvider() {
        guard let provider = provider else { return }
        name = provider.name
        url = provider.url
        streamingEnabled = provider.streamingEnabled
        discoveryTimeout = provider.discoveryTimeout
        toolCallTimeout = provider.toolCallTimeout
        autoConnect = provider.autoConnect

        // Load headers
        customHeaders = provider.customHeaders.map { HeaderEntry(key: $0.key, value: $0.value, isSecret: false) }

        // Add secret header keys (values not loaded for security)
        for key in provider.secretHeaderKeys {
            customHeaders.append(HeaderEntry(key: key, value: "", isSecret: true))
        }

        // Note: Token not loaded for security - user must re-enter if changing
    }

    private func testConnection() {
        isTesting = true
        testResult = nil

        let headers = buildHeaders()
        let testToken = token.isEmpty ? nil : token

        Task {
            do {
                let count = try await MCPProviderManager.shared.testConnection(
                    url: url,
                    token: testToken,
                    headers: headers
                )
                await MainActor.run {
                    testResult = .success(count)
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = .failure(error.localizedDescription)
                    isTesting = false
                }
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)

        // Separate regular headers from secret headers
        var regularHeaders: [String: String] = [:]
        var secretKeys: [String] = []

        for header in customHeaders where !header.key.isEmpty {
            if header.isSecret {
                secretKeys.append(header.key)
            } else {
                regularHeaders[header.key] = header.value
            }
        }

        let updatedProvider = MCPProvider(
            id: provider?.id ?? UUID(),
            name: trimmedName,
            url: trimmedURL,
            enabled: provider?.enabled ?? true,
            customHeaders: regularHeaders,
            streamingEnabled: streamingEnabled,
            discoveryTimeout: discoveryTimeout,
            toolCallTimeout: toolCallTimeout,
            autoConnect: autoConnect,
            secretHeaderKeys: secretKeys
        )

        // Save secret header values to Keychain
        for header in customHeaders where header.isSecret && !header.key.isEmpty && !header.value.isEmpty {
            MCPProviderKeychain.saveHeaderSecret(header.value, key: header.key, for: updatedProvider.id)
        }

        // Pass token (empty string means no change, nil means keep existing)
        let tokenToSave: String? = token.isEmpty ? nil : token

        onSave(updatedProvider, tokenToSave)
        dismiss()
    }

    private func buildHeaders() -> [String: String] {
        var headers: [String: String] = [:]
        for header in customHeaders where !header.key.isEmpty && !header.value.isEmpty {
            headers[header.key] = header.value
        }
        return headers
    }
}

extension ProviderEditSheet.TestResult {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

// MARK: - Header Row

private struct HeaderRow: View {
    @Environment(\.theme) private var theme
    @Binding var header: ProviderEditSheet.HeaderEntry
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("Key", text: $header.key)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .frame(width: 140)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground))

            if header.isSecret {
                SecureField("Value (secret)", text: $header.value)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground))
            } else {
                TextField("Value", text: $header.value)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground))
            }

            Toggle("Secret", isOn: $header.isSecret)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)

            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .foregroundColor(theme.errorColor.opacity(0.7))
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
}

// MARK: - Form Components

private struct FormSection<Content: View, Trailing: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    let trailing: Trailing
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.trailing = trailing()
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                Spacer()
                trailing
            }
            content()
        }
    }
}

private struct FormField<Content: View>: View {
    @Environment(\.theme) private var theme
    let label: String
    var hint: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                if let hint = hint {
                    Text("• \(hint)")
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
            }
            content()
        }
    }
}

// MARK: - Flow Layout for Tool Tags

private struct FlowLayoutView<Item: Hashable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 200), spacing: 6)], spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.element) { _, item in
                content(item)
            }
        }
    }
}

#Preview {
    ProvidersView()
        .frame(width: 700, height: 500)
        .environment(\.theme, DarkTheme())
}
