//
//  ProvidersView.swift
//  osaurus
//
//  UI for managing remote MCP providers.
//

import AppKit
import SwiftUI

struct ProvidersView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var manager = MCPProviderManager.shared
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
                            },
                            onSignIn: {
                                Task { try? await manager.oauthSignIn(providerId: provider.id) }
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
                    Text("Add Provider", bundle: .module)
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

            Text("No MCP providers yet", bundle: .module)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(theme.primaryText)

            Text("Connect to a remote MCP server to give Osaurus more tools.", bundle: .module)
                .font(.system(size: 14))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)

            Button(action: { showAddSheet = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14))
                    Text("Connect a Service", bundle: .module)
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
    let onSignIn: () -> Void

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

    private var requiresAuth: Bool {
        state?.requiresAuth ?? false
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
                                Text("\(toolCount) tools", bundle: .module)
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
                                Text("Disconnect", bundle: .module)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(theme.errorColor)
                            }
                            .buttonStyle(PlainButtonStyle())
                        } else {
                            Button(action: onConnect) {
                                Text("Connect", bundle: .module)
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
                            Label {
                                Text("Edit", bundle: .module)
                            } icon: {
                                Image(systemName: "pencil")
                            }
                        }
                        Divider()
                        Button(role: .destructive, action: { showDeleteConfirm = true }) {
                            Label {
                                Text("Delete", bundle: .module)
                            } icon: {
                                Image(systemName: "trash")
                            }
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

            // Sign-in required prompt — shown for OAuth providers (or any provider that
            // hit a 401 with WWW-Authenticate). Sits above the generic error so the
            // CTA is the obvious next action.
            if requiresAuth {
                HStack(spacing: 10) {
                    Image(systemName: "person.badge.key.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sign in required", bundle: .module)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                        Text("This server requires OAuth sign in to provide tools.", bundle: .module)
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button(action: onSignIn) {
                        Text("Sign In", bundle: .module)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(theme.accentColor)
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange.opacity(0.10))
                )
            } else if let error = state?.lastError, !isConnected {
                // Error message (only when not already showing the sign-in CTA)
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
        .themedAlert(
            "Delete Provider?",
            isPresented: $showDeleteConfirm,
            message: "This will remove the provider and all its tools. This cannot be undone.",
            primaryButton: .destructive("Delete") { onDelete() },
            secondaryButton: .cancel("Cancel")
        )
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
            Text("Disabled", bundle: .module)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.tertiaryText)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(theme.tertiaryBackground))
        } else if isConnected {
            HStack(spacing: 4) {
                Circle().fill(theme.successColor).frame(width: 6, height: 6)
                Text("Connected", bundle: .module)
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
                Text("Connecting...", bundle: .module)
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
                Text("Error", bundle: .module)
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
                        "\(provider.customHeaders.count + provider.secretHeaderKeys.count) custom header\(provider.customHeaders.count + provider.secretHeaderKeys.count == 1 ? "" : "s")",
                        bundle: .module
                    )
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                }
            }

            // Discovered tools list
            if isConnected, let toolNames = state?.discoveredToolNames, !toolNames.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Provides:", bundle: .module)
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
            Text("\(label):", bundle: .module)
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
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    let provider: MCPProvider?
    let onSave: (MCPProvider, String?) -> Void

    /// Stable identity for "draft" providers (sheet not yet saved). Reused so OAuth
    /// tokens persisted to Keychain mid-flow stay tied to the provider once saved.
    @State private var draftId: UUID = UUID()

    @State private var name: String = ""
    @State private var url: String = ""
    @State private var token: String = ""
    @State private var customHeaders: [HeaderEntry] = []
    @State private var streamingEnabled: Bool = false
    @State private var discoveryTimeout: Double = 20
    @State private var toolCallTimeout: Double = 45
    @State private var autoConnect: Bool = true
    @State private var authType: MCPProviderAuthType = .bearerToken
    @State private var oauthConfig: MCPOAuthConfig?

    @State private var isTesting: Bool = false
    @State private var testResult: TestResult?
    @State private var showAdvanced: Bool = false

    @State private var isSigningIn: Bool = false
    @State private var oauthError: String?
    /// Whether OAuth tokens are currently present for this provider — drives the
    /// "Sign In" vs "Re-authenticate" button label and the green check badge.
    @State private var isOAuthSignedIn: Bool = false

    /// The sheet is a small two-step flow: first pick a service from the catalog
    /// (or "Custom"), then configure / sign in. Editing an existing provider
    /// jumps straight to `.configureCustom` and never sees the catalog.
    enum Phase: Equatable {
        case chooseProvider
        case configureKnown(MCPProviderTemplate)
        case configureCustom
    }

    @State private var phase: Phase = .chooseProvider

    /// Search/filter query for the catalog grid. Reset whenever the user
    /// returns to `.chooseProvider` so re-entering the catalog starts fresh.
    @State private var catalogQuery: String = ""

    private var isEditing: Bool { provider != nil }

    /// Resolves the provider id used for OAuth flows (existing or fresh draft).
    private var effectiveProviderId: UUID { provider?.id ?? draftId }

    /// Convenience: the template the user is currently configuring, if any.
    private var activeTemplate: MCPProviderTemplate? {
        if case .configureKnown(let template) = phase { return template }
        return nil
    }

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
            sheetHeader

            ScrollView {
                phaseBody
                    .padding(24)
            }

            sheetFooter
        }
        .frame(width: 560, height: 660)
        .background(themeManager.currentTheme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(themeManager.currentTheme.primaryBorder, lineWidth: 1)
        )
        .onAppear { loadProvider() }
    }

    @ViewBuilder
    private var phaseBody: some View {
        switch phase {
        case .chooseProvider:
            catalogGridBody
        case .configureKnown(let template):
            configureKnownBody(template: template)
        case .configureCustom:
            configureCustomBody
        }
    }

    // MARK: - Sheet Header

    /// Icon + title + subtitle for the current phase. Returning `Text` (rather
    /// than `String`) lets us use SwiftUI's `Text("foo \(arg)")` interpolation
    /// for the dynamic phases — that produces a stable localization key with
    /// a format argument instead of a unique key per template name.
    private var headerInfo: (icon: String, title: Text, subtitle: Text) {
        if isEditing {
            return (
                "pencil.circle.fill",
                Text("Edit MCP Provider", bundle: .module),
                Text("Modify your MCP server connection", bundle: .module)
            )
        }
        switch phase {
        case .chooseProvider:
            return (
                "square.grid.2x2.fill",
                Text("Add MCP Provider", bundle: .module),
                Text("Choose a service to connect", bundle: .module)
            )
        case .configureKnown(let template):
            return (
                template.iconSystemName,
                Text("Connect to \(template.displayName)", bundle: .module),
                Text("Sign in with your account to give Osaurus access", bundle: .module)
            )
        case .configureCustom:
            return (
                "slider.horizontal.3",
                Text("Custom Server", bundle: .module),
                Text("Connect to any MCP-compatible server", bundle: .module)
            )
        }
    }

    private var sheetHeader: some View {
        let info = headerInfo
        return HStack(spacing: 12) {
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
                Image(systemName: info.icon)
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
                info.title
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.primaryText)

                info.subtitle
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

    @ViewBuilder
    private var sheetFooter: some View {
        HStack(spacing: 12) {
            footerLeading
            Spacer()
            footerTrailing
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

    @ViewBuilder
    private var footerLeading: some View {
        if phase != .chooseProvider, !isEditing {
            Button(action: backToCatalog) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Use a different service", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(themeManager.currentTheme.secondaryText)
            }
            .buttonStyle(PlainButtonStyle())
        }

        if case .configureCustom = phase {
            testConnectionButton
        }
    }

    @ViewBuilder
    private var footerTrailing: some View {
        cancelButton
        if case .configureKnown(let template) = phase {
            primarySaveButton(
                label: Text("Add Provider", bundle: .module),
                enabled: canSaveKnown(template)
            )
        }
        if case .configureCustom = phase {
            primarySaveButton(
                label: Text(isEditing ? "Save" : "Add Provider", bundle: .module),
                enabled: canSave
            )
        }
    }

    private var cancelButton: some View {
        Button {
            dismiss()
        } label: {
            Text("Cancel", bundle: .module)
        }
        .buttonStyle(MCPSecondaryButtonStyle())
    }

    private func primarySaveButton(label: Text, enabled: Bool) -> some View {
        Button(action: save) { label }
            .buttonStyle(MCPPrimaryButtonStyle())
            .disabled(!enabled)
            .keyboardShortcut(.return, modifiers: .command)
    }

    @ViewBuilder
    private var testConnectionButton: some View {
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
                        Text("Connected! (\(count) tools)", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                    case .failure:
                        Text("Failed - Tap to retry", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                    }
                } else {
                    Text("Test", bundle: .module)
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
    }

    /// Return to the catalog grid and clear any sign-in state from the previous selection.
    private func backToCatalog() {
        clearDraft(authType: .bearerToken)
        catalogQuery = ""
        transition(to: .chooseProvider)
    }

    /// Reset the draft to a blank slate. Used when transitioning between phases
    /// so a previous selection's name / url / OAuth state doesn't leak through.
    /// Token state is dropped from Keychain via `resetDraftOAuthState`.
    private func clearDraft(authType: MCPProviderAuthType, name: String = "", url: String = "") {
        self.name = name
        self.url = url
        self.authType = authType
        customHeaders.removeAll()
        testResult = nil
        resetDraftOAuthState()
    }

    private func transition(to newPhase: Phase) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            phase = newPhase
        }
    }

    // MARK: - Catalog Grid (Phase 1)

    private var catalogGridBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            catalogSearchField

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 160), spacing: 12)],
                spacing: 12
            ) {
                ProviderCatalogCard(
                    icon: "slider.horizontal.3",
                    title: "Custom Server",
                    tagline: "Connect to any other MCP-compatible server",
                    action: selectCustomServer
                )
                ForEach(filteredTemplates) { template in
                    ProviderCatalogCard(
                        icon: template.iconSystemName,
                        title: template.displayName,
                        tagline: template.tagline,
                        action: { selectTemplate(template) }
                    )
                }
            }

            if filteredTemplates.isEmpty && !trimmedCatalogQuery.isEmpty {
                catalogNoMatchesHint
            }
        }
    }

    /// Templates that match the current `catalogQuery`. Empty query returns the
    /// full catalog. Match is case-insensitive across `displayName` and
    /// `tagline` so users can find Linear by typing "issues".
    private var filteredTemplates: [MCPProviderTemplate] {
        let query = trimmedCatalogQuery
        guard !query.isEmpty else { return MCPProviderTemplate.allTemplates }
        return MCPProviderTemplate.allTemplates.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.tagline.localizedCaseInsensitiveContains(query)
        }
    }

    private var trimmedCatalogQuery: String {
        catalogQuery.trimmingCharacters(in: .whitespaces)
    }

    @ViewBuilder
    private var catalogSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(themeManager.currentTheme.tertiaryText)

            ZStack(alignment: .leading) {
                if catalogQuery.isEmpty {
                    Text("Search providers", bundle: .module)
                        .font(.system(size: 13))
                        .foregroundColor(themeManager.currentTheme.placeholderText)
                        .allowsHitTesting(false)
                }
                TextField("", text: $catalogQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(themeManager.currentTheme.primaryText)
            }

            if !catalogQuery.isEmpty {
                Button(action: { catalogQuery = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(themeManager.currentTheme.tertiaryText)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(themeManager.currentTheme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private var catalogNoMatchesHint: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .light))
                .foregroundColor(themeManager.currentTheme.tertiaryText)
            Text("No services match \"\(trimmedCatalogQuery)\"", bundle: .module)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(themeManager.currentTheme.secondaryText)
            Text("Try a different name, or pick Custom Server above.", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(themeManager.currentTheme.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func selectTemplate(_ template: MCPProviderTemplate) {
        // Self-hosting templates (e.g. Google Workspace) have no hosted endpoint;
        // open the docs in the browser and drop the user into the freeform editor
        // with the name pre-filled so they can paste their deployment's URL.
        if let helpURL = template.selfHostingHelpURL {
            NSWorkspace.shared.open(helpURL)
            clearDraft(authType: .bearerToken, name: template.displayName, url: "")
            transition(to: .configureCustom)
            return
        }
        // OAuth and bearer-token templates both go to .configureKnown — the screen
        // branches on template.authType for the correct sign-in vs. API-key UI.
        clearDraft(authType: template.authType, name: template.displayName, url: template.url)
        transition(to: .configureKnown(template))
    }

    private func selectCustomServer() {
        clearDraft(authType: .bearerToken)
        transition(to: .configureCustom)
    }

    // MARK: - Configure Known Provider (Phase 2a)

    @ViewBuilder
    private func configureKnownBody(template: MCPProviderTemplate) -> some View {
        VStack(spacing: 24) {
            // Hero
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    themeManager.currentTheme.accentColor.opacity(0.22),
                                    themeManager.currentTheme.accentColor.opacity(0.06),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: template.iconSystemName)
                        .font(.system(size: 30, weight: .semibold))
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
                .frame(width: 72, height: 72)

                VStack(spacing: 4) {
                    Text(LocalizedStringKey(template.displayName), bundle: .module)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(themeManager.currentTheme.primaryText)
                    Text(LocalizedStringKey(template.tagline), bundle: .module)
                        .font(.system(size: 13))
                        .foregroundColor(themeManager.currentTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 12)

            // Auth-specific block
            VStack(spacing: 12) {
                switch template.authType {
                case .oauth:
                    if isOAuthSignedIn {
                        connectedBlock(template: template)
                    } else {
                        signInBlock(template: template)
                    }
                case .bearerToken:
                    apiKeyBlock(template: template)
                case .none:
                    noAuthBlock(template: template)
                }

                if let error = oauthError, template.authType == .oauth {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(themeManager.currentTheme.errorColor)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .padding(.horizontal, 8)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func signInBlock(template: MCPProviderTemplate) -> some View {
        VStack(spacing: 10) {
            Button(action: signInWithOAuth) {
                HStack(spacing: 8) {
                    if isSigningIn {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "person.badge.key.fill")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    Group {
                        if isSigningIn {
                            Text("Waiting for browser…", bundle: .module)
                        } else {
                            Text("Sign In with \(template.displayName)", bundle: .module)
                        }
                    }
                    .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(themeManager.currentTheme.accentColor)
                )
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isSigningIn)

            Text(
                "We'll open your browser to sign in. After approving, you'll be redirected back to Osaurus.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(themeManager.currentTheme.tertiaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
        }
    }

    @ViewBuilder
    private func connectedBlock(template: MCPProviderTemplate) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(themeManager.currentTheme.successColor)
                Text("Connected to \(template.displayName)", bundle: .module)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.primaryText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(themeManager.currentTheme.successColor.opacity(0.12))
            )

            if let scopes = oauthConfig?.scopes, !scopes.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 9))
                    Text(scopes.joined(separator: " "))
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .foregroundColor(themeManager.currentTheme.tertiaryText)
                .frame(maxWidth: 360)
            }

            Button(action: signInWithOAuth) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                    Text("Re-authenticate", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(themeManager.currentTheme.secondaryText)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isSigningIn)
        }
    }

    @ViewBuilder
    private func apiKeyBlock(template: MCPProviderTemplate) -> some View {
        VStack(spacing: 10) {
            MCPStyledSecureField(
                label: "API Key",
                placeholder: "Paste your API key",
                text: $token
            )
            .frame(maxWidth: 420)

            if let helpURL = template.apiKeyHelpURL {
                Button(action: { NSWorkspace.shared.open(helpURL) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "link.circle.fill")
                            .font(.system(size: 11))
                        Text("Where do I get my key?", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(themeManager.currentTheme.accentColor)
                }
                .buttonStyle(PlainButtonStyle())
            }

            Text(
                "Your API key is stored in your macOS Keychain and only sent to \(template.displayName).",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(themeManager.currentTheme.tertiaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
        }
    }

    @ViewBuilder
    private func noAuthBlock(template: MCPProviderTemplate) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.open.fill")
                .font(.system(size: 13))
                .foregroundColor(themeManager.currentTheme.successColor)
            Text("This server doesn't require authentication.", bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(themeManager.currentTheme.primaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(themeManager.currentTheme.successColor.opacity(0.10))
        )
    }

    /// "Add Provider" enable rule for the connect-known footer. OAuth waits on
    /// sign-in, bearer-token waits on a non-empty key, none is always ready.
    private func canSaveKnown(_ template: MCPProviderTemplate) -> Bool {
        switch template.authType {
        case .oauth:
            return isOAuthSignedIn
        case .bearerToken:
            return !token.trimmingCharacters(in: .whitespaces).isEmpty
        case .none:
            return true
        }
    }

    // MARK: - Configure Custom Server (Phase 2b)

    private var configureCustomBody: some View {
        VStack(alignment: .leading, spacing: 16) {
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

                    authTypePicker

                    switch authType {
                    case .none:
                        EmptyView()
                    case .bearerToken:
                        MCPStyledSecureField(
                            label: "Bearer Token",
                            placeholder: "Optional - stored securely in Keychain",
                            text: $token
                        )
                    case .oauth:
                        oauthSection
                    }
                }
            }

            EditorCard(title: "Custom Headers", icon: "list.bullet.rectangle") {
                VStack(alignment: .leading, spacing: 12) {
                    if customHeaders.isEmpty {
                        HStack {
                            Text("No custom headers configured", bundle: .module)
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
                            Divider().padding(.vertical, 8)

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

                            Divider().padding(.vertical, 4)

                            VStack(alignment: .leading, spacing: 16) {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text("Discovery Timeout", bundle: .module)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(themeManager.currentTheme.primaryText)
                                        Spacer()
                                        Text("\(Int(discoveryTimeout))s", bundle: .module)
                                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                                            .foregroundColor(themeManager.currentTheme.accentColor)
                                    }
                                    Slider(value: $discoveryTimeout, in: 5 ... 60, step: 5)
                                        .tint(themeManager.currentTheme.accentColor)
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text("Tool Call Timeout", bundle: .module)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(themeManager.currentTheme.primaryText)
                                        Spacer()
                                        Text("\(Int(toolCallTimeout))s", bundle: .module)
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
    }

    @ViewBuilder
    private var authTypePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Authentication", bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(themeManager.currentTheme.primaryText)

            Picker("Authentication", selection: $authType) {
                Text("None", bundle: .module).tag(MCPProviderAuthType.none)
                Text("Bearer Token", bundle: .module).tag(MCPProviderAuthType.bearerToken)
                Text("OAuth", bundle: .module).tag(MCPProviderAuthType.oauth)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// Drop any in-flight OAuth credentials for the current draft id and clear
    /// the matching UI flags. Safe to call repeatedly; Keychain delete is
    /// idempotent on missing items.
    private func resetDraftOAuthState() {
        token = ""
        oauthError = nil
        oauthConfig = nil
        isOAuthSignedIn = false
        MCPProviderKeychain.deleteOAuthTokens(for: effectiveProviderId)
    }

    @ViewBuilder
    private var oauthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                Text("Sign in via the server's OAuth login flow", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(themeManager.currentTheme.secondaryText)
            }

            HStack(spacing: 10) {
                Button(action: signInWithOAuth) {
                    HStack(spacing: 6) {
                        if isSigningIn {
                            ProgressView().scaleEffect(0.6)
                        } else {
                            Image(systemName: isOAuthSignedIn ? "arrow.clockwise" : "person.badge.key")
                                .font(.system(size: 12))
                        }
                        Text(
                            LocalizedStringKey(isOAuthSignedIn ? "Re-authenticate" : "Sign In"),
                            bundle: .module
                        )
                        .font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(MCPPrimaryButtonStyle())
                .disabled(isSigningIn || url.trimmingCharacters(in: .whitespaces).isEmpty)

                if isOAuthSignedIn {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(themeManager.currentTheme.successColor)
                        Text("Signed in", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(themeManager.currentTheme.successColor)
                    }
                }

                Spacer()
            }

            if let error = oauthError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.currentTheme.errorColor)
                    .lineLimit(3)
            }

            if let config = oauthConfig, !config.scopes.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 9))
                        .foregroundColor(themeManager.currentTheme.tertiaryText)
                    Text(config.scopes.joined(separator: " "))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(themeManager.currentTheme.tertiaryText)
                        .lineLimit(2)
                }
            }
        }
    }

    private func signInWithOAuth() {
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        guard !trimmedURL.isEmpty else { return }
        isSigningIn = true
        oauthError = nil

        // Build a draft provider record carrying any client_id we already DCR-registered.
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let draftProvider = MCPProvider(
            id: effectiveProviderId,
            name: trimmedName.isEmpty ? "MCP Provider" : trimmedName,
            url: trimmedURL,
            enabled: true,
            authType: .oauth,
            oauth: oauthConfig
        )

        Task { @MainActor in
            do {
                let result = try await MCPOAuthService.signIn(provider: draftProvider, hint: nil, persist: true)
                self.oauthConfig = result.config
                self.isOAuthSignedIn = true
                self.isSigningIn = false
            } catch {
                self.oauthError = error.localizedDescription
                self.isSigningIn = false
            }
        }
    }

    private var addHeaderButton: some View {
        Button(action: {
            customHeaders.append(HeaderEntry(key: "", value: "", isSecret: false))
        }) {
            HStack(spacing: 4) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 11))
                Text("Add Header", bundle: .module)
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
        guard let provider = provider else {
            // Add-mode: stay on the catalog grid. The draftId is preserved so
            // anything OAuth-saved mid-flow ends up on this id and persists
            // through save().
            phase = .chooseProvider
            return
        }
        // Edit-mode: jump straight to the freeform editor. Re-use the existing
        // record's id so OAuth tokens already in Keychain match.
        draftId = provider.id
        name = provider.name
        url = provider.url
        streamingEnabled = provider.streamingEnabled
        discoveryTimeout = provider.discoveryTimeout
        toolCallTimeout = provider.toolCallTimeout
        autoConnect = provider.autoConnect
        authType = provider.authType
        oauthConfig = provider.oauth
        isOAuthSignedIn =
            provider.authType == .oauth
            && MCPProviderKeychain.hasOAuthTokens(for: provider.id)

        customHeaders = provider.customHeaders.map { HeaderEntry(key: $0.key, value: $0.value, isSecret: false) }
        for key in provider.secretHeaderKeys {
            customHeaders.append(HeaderEntry(key: key, value: "", isSecret: true))
        }
        // Note: Token not loaded for security - user must re-enter if changing.

        phase = .configureCustom
    }

    private func testConnection() {
        isTesting = true
        testResult = nil

        let headers = buildHeaders()
        let testToken: String?
        switch authType {
        case .bearerToken:
            testToken = token.isEmpty ? nil : token
        case .oauth:
            // Use the access token already saved during sign-in (if any) so the test
            // request can succeed before the user clicks Save.
            testToken = MCPProviderKeychain.getOAuthTokens(for: effectiveProviderId)?.accessToken
        case .none:
            testToken = nil
        }

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
            id: effectiveProviderId,
            name: trimmedName,
            url: trimmedURL,
            enabled: provider?.enabled ?? true,
            customHeaders: regularHeaders,
            streamingEnabled: streamingEnabled,
            discoveryTimeout: discoveryTimeout,
            toolCallTimeout: toolCallTimeout,
            autoConnect: autoConnect,
            secretHeaderKeys: secretKeys,
            authType: authType,
            oauth: authType == .oauth ? oauthConfig : nil
        )

        // Save secret header values to Keychain
        for header in customHeaders where header.isSecret && !header.key.isEmpty && !header.value.isEmpty {
            MCPProviderKeychain.saveHeaderSecret(header.value, key: header.key, for: updatedProvider.id)
        }

        // Pass token (empty string means no change, nil means keep existing).
        // For OAuth this is unused (tokens went through MCPOAuthService directly).
        let tokenToSave: String? = (authType == .bearerToken && !token.isEmpty) ? token : nil

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

// MARK: - Provider Catalog Card

/// One cell in the catalog grid: icon, title, two-line tagline, full-cell tap target.
private struct ProviderCatalogCard: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let icon: String
    let title: String
    let tagline: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(themeManager.currentTheme.accentColor.opacity(0.12))
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(themeManager.currentTheme.accentColor)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(title), bundle: .module)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(themeManager.currentTheme.primaryText)
                        .lineLimit(1)
                    Text(LocalizedStringKey(tagline), bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(themeManager.currentTheme.secondaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        isHovering
                            ? themeManager.currentTheme.accentColor.opacity(0.06)
                            : themeManager.currentTheme.tertiaryBackground
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isHovering
                            ? themeManager.currentTheme.accentColor.opacity(0.4)
                            : themeManager.currentTheme.primaryBorder,
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
    }
}

// MARK: - Header Row

private struct HeaderRow: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Binding var header: ProviderEditSheet.HeaderEntry
    let onDelete: () -> Void

    @State private var isKeyFocused = false
    @State private var isValueFocused = false

    var body: some View {
        HStack(spacing: 8) {
            // Key field
            ZStack(alignment: .leading) {
                if header.key.isEmpty {
                    Text("Key", bundle: .module)
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
                    Text(LocalizedStringKey(header.isSecret ? "Secret value" : "Value"), bundle: .module)
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
                    Text(LocalizedStringKey(header.isSecret ? "Secret" : "Plain"), bundle: .module)
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
    @ObservedObject private var themeManager = ThemeManager.shared
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.accentColor)

                Text(LocalizedStringKey(title), bundle: .module)
                    .textCase(.uppercase)
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
    @ObservedObject private var themeManager = ThemeManager.shared

    let label: String
    let placeholder: String
    @Binding var text: String
    var isMonospaced: Bool = false

    @State private var isFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(label), bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(themeManager.currentTheme.primaryText)

            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(LocalizedStringKey(placeholder), bundle: .module)
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
    @ObservedObject private var themeManager = ThemeManager.shared

    let label: String
    let placeholder: String
    @Binding var text: String

    @State private var isFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(LocalizedStringKey(label), bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.primaryText)

                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
            }

            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(LocalizedStringKey(placeholder), bundle: .module)
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
    @ObservedObject private var themeManager = ThemeManager.shared

    let title: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(themeManager.currentTheme.primaryText)
                Text(LocalizedStringKey(description), bundle: .module)
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
    @ObservedObject private var themeManager = ThemeManager.shared

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
    @ObservedObject private var themeManager = ThemeManager.shared

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

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        ProvidersView()
            .frame(width: 700, height: 500)
            .environment(\.theme, DarkTheme())
    }
#endif
