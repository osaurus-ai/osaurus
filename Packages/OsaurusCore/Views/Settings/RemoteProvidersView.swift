//
//  RemoteProvidersView.swift
//  osaurus
//
//  View for managing remote API providers (OpenAI, Anthropic, etc.).
//

import SwiftUI

struct RemoteProvidersView: View {
    @ObservedObject private var manager = RemoteProviderManager.shared
    @ObservedObject private var themeManager = ThemeManager.shared

    /// Use computed property to always get the current theme from ThemeManager
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var addSheetConfig: AddSheetConfig?
    @State private var editingProvider: RemoteProvider?
    @State private var showReorderSheet = false
    @State private var hasAppeared = false

    private struct AddSheetConfig: Identifiable {
        let id = UUID()
        let preset: ProviderPreset?
        /// Open the add sheet directly on the grouped "Use an API key" sub-list
        /// (only meaningful when `preset` is nil).
        var startAtAPIKeyPicker: Bool = false
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if userConfiguredProviders.isEmpty {
                        emptyStateView
                    } else {
                        providerListView
                    }
                }
                .padding(24)
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
        .sheet(item: $addSheetConfig) { config in
            RemoteProviderEditSheet(
                provider: nil,
                initialPreset: config.preset,
                startAtAPIKeyPicker: config.startAtAPIKeyPicker
            ) { provider, apiKey, oauthTokens in
                manager.addProvider(provider, apiKey: apiKey, oauthTokens: oauthTokens)
            }
        }
        .sheet(item: $editingProvider) { provider in
            RemoteProviderEditSheet(provider: provider) { updatedProvider, apiKey, oauthTokens in
                manager.updateProvider(updatedProvider, apiKey: apiKey, oauthTokens: oauthTokens)
            }
        }
        .sheet(isPresented: $showReorderSheet) {
            RemoteProviderReorderSheet()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: L("Providers"),
            subtitle: subtitleText
        ) {
            if userConfiguredProviders.count > 1 {
                HeaderIconButton("list.bullet.indent", help: "Reorder providers") {
                    showReorderSheet = true
                }
            }
            HeaderPrimaryButton("Add Provider", icon: "plus") {
                addSheetConfig = AddSheetConfig(preset: nil)
            }
        }
    }

    private var subtitleText: String {
        let userProviders = userConfiguredProviders
        let userProviderIds = Set(userProviders.map(\.id))
        let connectedCount = manager.providerStates
            .filter { userProviderIds.contains($0.key) }
            .values
            .filter { $0.isConnected }.count
        let totalCount = userProviders.count

        if totalCount == 0 {
            return L("Connect to remote API providers")
        } else if connectedCount == 0 {
            return L("\(totalCount) provider\(totalCount == 1 ? "" : "s") configured")
        } else {
            let modelCount = manager.providerStates.values.reduce(0) { $0 + $1.modelCount }
            return L("\(connectedCount) connected • \(modelCount) model\(modelCount == 1 ? "" : "s") available")
        }
    }

    // MARK: - Empty State

    private func presentAddSheet(for preset: ProviderPreset) {
        addSheetConfig = AddSheetConfig(preset: preset)
    }

    private var userConfiguredProviders: [RemoteProvider] {
        manager.configuration.providers.filter { $0.providerType != .osaurusRouter }
    }

    private func presentAPIKeyPicker() {
        addSheetConfig = AddSheetConfig(preset: nil, startAtAPIKeyPicker: true)
    }

    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 20)

            ZStack {
                Circle()
                    .fill(theme.accentColor.opacity(0.1))
                    .frame(width: 72, height: 72)

                Image(systemName: "cloud.fill")
                    .font(.system(size: 32))
                    .foregroundColor(theme.accentColor)
            }

            VStack(spacing: 8) {
                Text("No Remote Providers", bundle: .module)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text("Connect a provider to access remote models.", bundle: .module)
                    .font(.system(size: 14))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
            }

            // Quick-add: OAuth providers first-class, everything else behind
            // a single "Use an API key" entry (mirrors the add-sheet picker).
            VStack(spacing: 10) {
                ForEach(ProviderCatalog.topLevel) { entry in
                    ProviderRowCard(entry: entry) {
                        presentAddSheet(for: entry.preset)
                    }
                }

                ProviderRowCard(
                    icon: "key.fill",
                    title: "Use an API key",
                    subtitle: "Anthropic, Google, Ollama, custom, and more"
                ) {
                    presentAPIKeyPicker()
                }
            }
            .padding(.horizontal, 20)

            HStack(spacing: 4) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                Text("Your API keys are stored securely in Keychain.", bundle: .module)
                    .font(.system(size: 12))
            }
            .foregroundColor(theme.tertiaryText)

            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 400)
    }

    // MARK: - Provider List

    private var providerListView: some View {
        VStack(spacing: 12) {
            ForEach(userConfiguredProviders) { provider in
                ProviderCardView(
                    provider: provider,
                    state: manager.providerStates[provider.id],
                    onEdit: { editingProvider = provider },
                    onDelete: { manager.removeProvider(id: provider.id) },
                    onToggleEnabled: { enabled in
                        manager.setEnabled(enabled, for: provider.id)
                    }
                )
            }
        }
    }
}

// MARK: - Provider Card View

private struct ProviderCardView: View {
    @Environment(\.theme) private var theme
    let provider: RemoteProvider
    let state: RemoteProviderState?
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggleEnabled: (Bool) -> Void

    @State private var showDeleteConfirm = false
    @State private var isHovered = false

    private var isConnected: Bool { state?.isConnected ?? false }
    private var isConnecting: Bool { state?.isConnecting ?? false }

    /// Match to a known preset for icon/color
    private var matchedPreset: ProviderPreset? {
        ProviderPreset.matching(provider: provider)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main content
            HStack(spacing: 16) {
                // Icon
                ZStack {
                    iconBackground
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    if let preset = matchedPreset {
                        ProviderIcon(preset: preset, size: 22, color: iconForeground)
                    } else {
                        Image(systemName: "cloud.fill")
                            .font(.system(size: 22))
                            .foregroundColor(iconForeground)
                    }
                }
                .frame(width: 52, height: 52)

                // Info
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(provider.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(theme.primaryText)

                        statusBadge

                        if provider.providerType == .osaurus {
                            // Osaurus peers talk through the Secure Channel —
                            // agent traffic is end-to-end encrypted or refused.
                            HStack(spacing: 3) {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 8, weight: .semibold))
                                Text("E2E", bundle: .module)
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundColor(theme.successColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.successColor.opacity(0.12)))
                            .help(
                                L(
                                    "Agent traffic is protected by the Osaurus Secure Channel: forward-secret, mutually authenticated end-to-end encryption."
                                )
                            )
                        }
                    }

                    Text(provider.displayEndpoint)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)

                    if isConnected, let modelCount = state?.modelCount, modelCount > 0 {
                        Text("\(modelCount) model\(modelCount == 1 ? "" : "s") available", bundle: .module)
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                    }
                }

                Spacer()

                // Actions
                HStack(spacing: 12) {
                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                            .font(.system(size: 14))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 32, height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.tertiaryBackground)
                            )
                    }
                    .buttonStyle(PlainButtonStyle())

                    Button(action: { showDeleteConfirm = true }) {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundColor(theme.errorColor.opacity(0.8))
                            .frame(width: 32, height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.errorColor.opacity(0.1))
                            )
                    }
                    .buttonStyle(PlainButtonStyle())

                    Toggle(
                        "",
                        isOn: Binding(
                            get: { provider.enabled },
                            set: { onToggleEnabled($0) }
                        )
                    )
                    .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                    .labelsHidden()
                }
            }
            .padding(16)

            // Error message
            if let error = state?.lastError, !isConnected, !isConnecting {
                Divider()
                    .background(theme.errorColor.opacity(0.3))

                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                    Text(error)
                        .font(.system(size: 12))
                        .lineLimit(2)
                }
                .foregroundColor(theme.errorColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.errorColor.opacity(0.05))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(theme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(
                            isConnected ? theme.successColor.opacity(0.4) : theme.primaryBorder,
                            lineWidth: 1
                        )
                )
        )
        .scaleEffect(isHovered ? 1.005 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .themedAlert(
            L("Delete Provider?"),
            isPresented: $showDeleteConfirm,
            message: L("This will remove '\(provider.name)' and disconnect any active sessions."),
            primaryButton: .destructive(L("Delete")) { onDelete() },
            secondaryButton: .cancel(L("Cancel"))
        )
    }

    /// Icon background: use preset gradient if connected, otherwise status-tinted fill
    @ViewBuilder
    private var iconBackground: some View {
        if let preset = matchedPreset, isConnected {
            LinearGradient(
                colors: preset.gradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            statusColor.opacity(0.12)
        }
    }

    private var iconForeground: Color {
        if matchedPreset != nil, isConnected {
            return .white
        }
        return statusColor
    }

    @ViewBuilder
    private var statusBadge: some View {
        if !provider.enabled {
            badge(text: "Disabled", color: theme.tertiaryText)
        } else if isConnected {
            badge(text: "Connected", color: theme.successColor)
        } else if isConnecting {
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 12, height: 12)
                Text("Connecting...", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(theme.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(theme.accentColor.opacity(0.12)))
        } else if state?.lastError != nil {
            badge(text: "Error", color: theme.errorColor)
        } else {
            badge(text: "Disconnected", color: theme.secondaryText)
        }
    }

    private func badge(text: String, color: Color) -> some View {
        Text(LocalizedStringKey(text), bundle: .module)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        RemoteProvidersView()
            .environment(\.theme, DarkTheme())
    }
#endif
