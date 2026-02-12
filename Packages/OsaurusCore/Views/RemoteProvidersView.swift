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

    @State private var showAddSheet = false
    @State private var editingProvider: RemoteProvider?
    @State private var hasAppeared = false

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
                    if manager.configuration.providers.isEmpty {
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
        .sheet(isPresented: $showAddSheet) {
            RemoteProviderEditSheet(provider: nil) { provider, apiKey in
                manager.addProvider(provider, apiKey: apiKey)
            }
        }
        .sheet(item: $editingProvider) { provider in
            RemoteProviderEditSheet(provider: provider) { updatedProvider, apiKey in
                manager.updateProvider(updatedProvider, apiKey: apiKey)
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: "Providers",
            subtitle: subtitleText
        ) {
            HeaderPrimaryButton("Add Provider", icon: "plus") {
                showAddSheet = true
            }
        }
    }

    private var subtitleText: String {
        let connectedCount = manager.providerStates.values.filter { $0.isConnected }.count
        let totalCount = manager.configuration.providers.count

        if totalCount == 0 {
            return "Connect to remote API providers"
        } else if connectedCount == 0 {
            return "\(totalCount) provider\(totalCount == 1 ? "" : "s") configured"
        } else {
            let modelCount = manager.providerStates.values.reduce(0) { $0 + $1.modelCount }
            return "\(connectedCount) connected \u{2022} \(modelCount) model\(modelCount == 1 ? "" : "s") available"
        }
    }

    // MARK: - Empty State

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
                Text("No Remote Providers")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text("Connect a provider to access remote models.")
                    .font(.system(size: 14))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
            }

            // Quick-add provider cards
            VStack(spacing: 8) {
                ForEach(ProviderPreset.knownPresets) { preset in
                    EmptyStateProviderCard(preset: preset) {
                        showAddSheet = true
                    }
                }

                // Custom option
                EmptyStateProviderCard(preset: .custom) {
                    showAddSheet = true
                }
            }
            .padding(.horizontal, 20)

            HStack(spacing: 4) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                Text("Your API keys are stored securely in Keychain.")
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
            ForEach(manager.configuration.providers) { provider in
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

// MARK: - Empty State Provider Card

private struct EmptyStateProviderCard: View {
    @Environment(\.theme) private var theme
    let preset: ProviderPreset
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            LinearGradient(
                                colors: isHovered
                                    ? preset.gradient : [theme.tertiaryBackground, theme.tertiaryBackground],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 36, height: 36)

                    Image(systemName: preset.icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(isHovered ? .white : theme.secondaryText)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(preset.description)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()

                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.secondaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                isHovered ? theme.accentColor.opacity(0.4) : theme.primaryBorder,
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                isHovered = hovering
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

    private var providerIcon: String {
        matchedPreset?.icon ?? "cloud.fill"
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
                    Image(systemName: providerIcon)
                        .font(.system(size: 22))
                        .foregroundColor(iconForeground)
                }
                .frame(width: 52, height: 52)

                // Info
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(provider.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(theme.primaryText)

                        statusBadge
                    }

                    Text(provider.displayEndpoint)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)

                    if isConnected, let modelCount = state?.modelCount, modelCount > 0 {
                        Text("\(modelCount) model\(modelCount == 1 ? "" : "s") available")
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
            "Delete Provider?",
            isPresented: $showDeleteConfirm,
            message: "This will remove '\(provider.name)' and disconnect any active sessions.",
            primaryButton: .destructive("Delete") { onDelete() },
            secondaryButton: .cancel("Cancel")
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
                Text("Connecting...")
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
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

#Preview {
    RemoteProvidersView()
        .environment(\.theme, DarkTheme())
}
