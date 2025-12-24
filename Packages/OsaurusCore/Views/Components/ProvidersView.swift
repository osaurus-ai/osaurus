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
        SectionHeader(
            title: "MCP Providers",
            description: "Connect to remote MCP servers to access additional tools"
        ) {
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
                    // Connection button with fixed size to prevent jiggling
                    Group {
                        if isConnecting {
                            ProgressView()
                                .scaleEffect(0.6)
                        } else if isConnected {
                            Button(action: onDisconnect) {
                                Text("Disconnect")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(theme.errorColor)
                            }
                            .buttonStyle(PlainButtonStyle())
                        } else {
                            Button(action: onConnect) {
                                Text("Connect")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .disabled(!provider.enabled)
                            .opacity(provider.enabled ? 1 : 0.5)
                        }
                    }
                    .frame(width: 80, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(
                                isConnected
                                    ? theme.errorColor.opacity(0.1) : (isConnecting ? Color.clear : theme.accentColor)
                            )
                    )

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
                ProgressView()
                    .scaleEffect(0.4)
                    .frame(width: 6, height: 6)
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
                    Text("Provides:")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    ToolPillsFlowLayout(spacing: 6) {
                        ForEach(toolNames, id: \.self) { name in
                            HStack(spacing: 4) {
                                Image(systemName: "function")
                                    .font(.system(size: 9))
                                Text(name)
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(theme.tertiaryBackground)
                            )
                            .foregroundColor(theme.primaryText)
                            .help(name)
                        }
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
    @StateObject private var themeManager = ThemeManager.shared
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
            sheetHeader

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Connection section
                    EditorCard(title: "Connection", icon: "link") {
                        VStack(alignment: .leading, spacing: 14) {
                            MCPStyledTextField(
                                label: "Name",
                                placeholder: "My MCP Server",
                                text: $name
                            )

                            MCPStyledTextField(
                                label: "URL",
                                placeholder: "https://mcp.example.com",
                                text: $url,
                                isMonospaced: true
                            )

                            MCPStyledSecureField(
                                label: "Bearer Token",
                                placeholder: "Optional - stored securely in Keychain",
                                text: $token
                            )
                        }
                    }

                    // Headers section
                    EditorCard(title: "Custom Headers", icon: "list.bullet.rectangle") {
                        VStack(alignment: .leading, spacing: 12) {
                            if customHeaders.isEmpty {
                                HStack {
                                    Text("No custom headers configured")
                                        .font(.system(size: 13))
                                        .foregroundColor(themeManager.currentTheme.tertiaryText)
                                    Spacer()
                                    addHeaderButton
                                }
                                .padding(.vertical, 4)
                            } else {
                                HStack {
                                    Spacer()
                                    addHeaderButton
                                }
                                ForEach($customHeaders) { $header in
                                    HeaderRow(header: $header) {
                                        customHeaders.removeAll { $0.id == header.id }
                                    }
                                }
                            }
                        }
                    }

                    // Advanced section
                    EditorCard(title: "Advanced", icon: "gearshape") {
                        VStack(alignment: .leading, spacing: 0) {
                            Button(action: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    showAdvanced.toggle()
                                }
                            }) {
                                HStack {
                                    Text(showAdvanced ? "Hide advanced settings" : "Show advanced settings")
                                        .font(.system(size: 13))
                                        .foregroundColor(themeManager.currentTheme.accentColor)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(themeManager.currentTheme.tertiaryText)
                                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())

                            if showAdvanced {
                                VStack(alignment: .leading, spacing: 16) {
                                    Divider()
                                        .padding(.vertical, 8)

                                    // Connection options
                                    MCPToggleRow(
                                        title: "Enable Streaming",
                                        description: "Stream tool responses in real-time",
                                        isOn: $streamingEnabled
                                    )

                                    MCPToggleRow(
                                        title: "Auto-connect on Launch",
                                        description: "Connect automatically when app starts",
                                        isOn: $autoConnect
                                    )

                                    Divider()
                                        .padding(.vertical, 4)

                                    // Timeout settings
                                    VStack(alignment: .leading, spacing: 16) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack {
                                                Text("Discovery Timeout")
                                                    .font(.system(size: 12, weight: .medium))
                                                    .foregroundColor(themeManager.currentTheme.primaryText)
                                                Spacer()
                                                Text("\(Int(discoveryTimeout))s")
                                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                                    .foregroundColor(themeManager.currentTheme.accentColor)
                                            }
                                            Slider(value: $discoveryTimeout, in: 5 ... 60, step: 5)
                                                .tint(themeManager.currentTheme.accentColor)
                                        }

                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack {
                                                Text("Tool Call Timeout")
                                                    .font(.system(size: 12, weight: .medium))
                                                    .foregroundColor(themeManager.currentTheme.primaryText)
                                                Spacer()
                                                Text("\(Int(toolCallTimeout))s")
                                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                                    .foregroundColor(themeManager.currentTheme.accentColor)
                                            }
                                            Slider(value: $toolCallTimeout, in: 10 ... 120, step: 5)
                                                .tint(themeManager.currentTheme.accentColor)
                                        }
                                    }
                                }
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }
                }
                .padding(24)
            }

            // Footer
            sheetFooter
        }
        .frame(width: 540, height: 640)
        .background(themeManager.currentTheme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(themeManager.currentTheme.primaryBorder, lineWidth: 1)
        )
        .onAppear { loadProvider() }
    }

    // MARK: - Sheet Header

    private var sheetHeader: some View {
        HStack(spacing: 12) {
            // Icon with gradient background
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                themeManager.currentTheme.accentColor.opacity(0.2),
                                themeManager.currentTheme.accentColor.opacity(0.05),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: isEditing ? "pencil.circle.fill" : "server.rack")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                themeManager.currentTheme.accentColor,
                                themeManager.currentTheme.accentColor.opacity(0.7),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? "Edit MCP Provider" : "Add MCP Provider")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.primaryText)

                Text(isEditing ? "Modify your MCP server connection" : "Connect to a remote MCP server")
                    .font(.system(size: 12))
                    .foregroundColor(themeManager.currentTheme.secondaryText)
            }

            Spacer()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(themeManager.currentTheme.tertiaryBackground)
                    )
            }
            .buttonStyle(PlainButtonStyle())
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(
            themeManager.currentTheme.secondaryBackground
                .overlay(
                    LinearGradient(
                        colors: [
                            themeManager.currentTheme.accentColor.opacity(0.03),
                            Color.clear,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    // MARK: - Sheet Footer

    private var sheetFooter: some View {
        HStack(spacing: 12) {
            // Test connection button
            Button(action: {
                if testResult != nil {
                    testResult = nil
                } else {
                    testConnection()
                }
            }) {
                HStack(spacing: 6) {
                    Group {
                        if isTesting {
                            ProgressView().scaleEffect(0.6)
                        } else if let result = testResult {
                            switch result {
                            case .success:
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12))
                            case .failure:
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                            }
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 12))
                        }
                    }
                    .frame(width: 16, height: 16)

                    if let result = testResult {
                        switch result {
                        case .success(let count):
                            Text("Connected! (\(count) tools)")
                                .font(.system(size: 12, weight: .medium))
                        case .failure:
                            Text("Failed - Tap to retry")
                                .font(.system(size: 12, weight: .medium))
                        }
                    } else {
                        Text("Test")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .foregroundColor(testResultColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(testResultBackground))
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(url.isEmpty || isTesting)

            // Keyboard hint
            HStack(spacing: 4) {
                Text("⌘")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(themeManager.currentTheme.tertiaryBackground)
                    )
                Text("+ Enter to save")
                    .font(.system(size: 11))
            }
            .foregroundColor(themeManager.currentTheme.tertiaryText)

            Spacer()

            // Cancel
            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(MCPSecondaryButtonStyle())

            // Save/Add
            Button(action: save) {
                Text(isEditing ? "Save" : "Add Provider")
            }
            .buttonStyle(MCPPrimaryButtonStyle())
            .disabled(!canSave)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            themeManager.currentTheme.secondaryBackground
                .overlay(
                    Rectangle()
                        .fill(themeManager.currentTheme.primaryBorder)
                        .frame(height: 1),
                    alignment: .top
                )
        )
    }

    private var addHeaderButton: some View {
        Button(action: {
            customHeaders.append(HeaderEntry(key: "", value: "", isSecret: false))
        }) {
            HStack(spacing: 4) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 11))
                Text("Add Header")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(themeManager.currentTheme.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(themeManager.currentTheme.accentColor.opacity(0.1))
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var testResultColor: Color {
        guard let result = testResult else { return themeManager.currentTheme.secondaryText }
        switch result {
        case .success: return themeManager.currentTheme.successColor
        case .failure: return themeManager.currentTheme.errorColor
        }
    }

    private var testResultBackground: Color {
        guard let result = testResult else { return themeManager.currentTheme.tertiaryBackground }
        switch result {
        case .success: return themeManager.currentTheme.successColor.opacity(0.12)
        case .failure: return themeManager.currentTheme.errorColor.opacity(0.12)
        }
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
    @StateObject private var themeManager = ThemeManager.shared
    @Binding var header: ProviderEditSheet.HeaderEntry
    let onDelete: () -> Void

    @State private var isKeyFocused = false
    @State private var isValueFocused = false

    var body: some View {
        HStack(spacing: 8) {
            // Key field
            ZStack(alignment: .leading) {
                if header.key.isEmpty {
                    Text("Key")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(themeManager.currentTheme.placeholderText)
                        .allowsHitTesting(false)
                }
                TextField(
                    "",
                    text: $header.key,
                    onEditingChanged: { editing in
                        withAnimation(.easeOut(duration: 0.15)) {
                            isKeyFocused = editing
                        }
                    }
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(themeManager.currentTheme.primaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: 120)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(themeManager.currentTheme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                isKeyFocused
                                    ? themeManager.currentTheme.accentColor.opacity(0.5)
                                    : themeManager.currentTheme.inputBorder,
                                lineWidth: isKeyFocused ? 1.5 : 1
                            )
                    )
            )

            // Value field
            ZStack(alignment: .leading) {
                if header.value.isEmpty {
                    Text(header.isSecret ? "Secret value" : "Value")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(themeManager.currentTheme.placeholderText)
                        .allowsHitTesting(false)
                }
                if header.isSecret {
                    SecureField("", text: $header.value)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(themeManager.currentTheme.primaryText)
                } else {
                    TextField(
                        "",
                        text: $header.value,
                        onEditingChanged: { editing in
                            withAnimation(.easeOut(duration: 0.15)) {
                                isValueFocused = editing
                            }
                        }
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.primaryText)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(themeManager.currentTheme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                isValueFocused
                                    ? themeManager.currentTheme.accentColor.opacity(0.5)
                                    : themeManager.currentTheme.inputBorder,
                                lineWidth: isValueFocused ? 1.5 : 1
                            )
                    )
            )

            // Secret toggle
            Button(action: { header.isSecret.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: header.isSecret ? "lock.fill" : "lock.open")
                        .font(.system(size: 10))
                    Text(header.isSecret ? "Secret" : "Plain")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(
                    header.isSecret
                        ? themeManager.currentTheme.accentColor
                        : themeManager.currentTheme.tertiaryText
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            header.isSecret
                                ? themeManager.currentTheme.accentColor.opacity(0.1)
                                : themeManager.currentTheme.tertiaryBackground
                        )
                )
            }
            .buttonStyle(PlainButtonStyle())

            // Delete button
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.currentTheme.errorColor)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(themeManager.currentTheme.errorColor.opacity(0.1))
                    )
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
}

// MARK: - Styled Components

private struct EditorCard<Content: View>: View {
    @StateObject private var themeManager = ThemeManager.shared
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.accentColor)

                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(themeManager.currentTheme.secondaryText)
                    .tracking(0.5)
            }

            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(themeManager.currentTheme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(themeManager.currentTheme.cardBorder, lineWidth: 1)
                )
        )
    }
}

private struct MCPStyledTextField: View {
    @StateObject private var themeManager = ThemeManager.shared

    let label: String
    let placeholder: String
    @Binding var text: String
    var isMonospaced: Bool = false

    @State private var isFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(themeManager.currentTheme.primaryText)

            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13, design: isMonospaced ? .monospaced : .default))
                        .foregroundColor(themeManager.currentTheme.placeholderText)
                        .allowsHitTesting(false)
                }

                TextField(
                    "",
                    text: $text,
                    onEditingChanged: { editing in
                        withAnimation(.easeOut(duration: 0.15)) {
                            isFocused = editing
                        }
                    }
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: isMonospaced ? .monospaced : .default))
                .foregroundColor(themeManager.currentTheme.primaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(themeManager.currentTheme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                isFocused
                                    ? themeManager.currentTheme.accentColor.opacity(0.5)
                                    : themeManager.currentTheme.inputBorder,
                                lineWidth: isFocused ? 1.5 : 1
                            )
                    )
            )
        }
    }
}

private struct MCPStyledSecureField: View {
    @StateObject private var themeManager = ThemeManager.shared

    let label: String
    let placeholder: String
    @Binding var text: String

    @State private var isFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.primaryText)

                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
            }

            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(themeManager.currentTheme.placeholderText)
                        .allowsHitTesting(false)
                }

                SecureField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.primaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(themeManager.currentTheme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                isFocused
                                    ? themeManager.currentTheme.accentColor.opacity(0.5)
                                    : themeManager.currentTheme.inputBorder,
                                lineWidth: isFocused ? 1.5 : 1
                            )
                    )
            )
        }
    }
}

private struct MCPToggleRow: View {
    @StateObject private var themeManager = ThemeManager.shared

    let title: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(themeManager.currentTheme.primaryText)
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(themeManager.currentTheme.tertiaryText)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .toggleStyle(SwitchToggleStyle(tint: themeManager.currentTheme.accentColor))
                .labelsHidden()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(themeManager.currentTheme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                )
        )
    }
}

private struct MCPPrimaryButtonStyle: ButtonStyle {
    @StateObject private var themeManager = ThemeManager.shared

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(themeManager.currentTheme.accentColor)
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

private struct MCPSecondaryButtonStyle: ButtonStyle {
    @StateObject private var themeManager = ThemeManager.shared

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(themeManager.currentTheme.primaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(themeManager.currentTheme.tertiaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                    )
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

// MARK: - Flow Layout for Tool Tags

private struct ToolPillsFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: currentY + lineHeight), positions)
    }
}

#Preview {
    ProvidersView()
        .frame(width: 700, height: 500)
        .environment(\.theme, DarkTheme())
}
