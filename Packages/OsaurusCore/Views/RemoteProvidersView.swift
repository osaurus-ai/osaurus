//
//  RemoteProvidersView.swift
//  osaurus
//
//  View for managing remote OpenAI-compatible API providers.
//

import SwiftUI

struct RemoteProvidersView: View {
    @StateObject private var manager = RemoteProviderManager.shared
    @StateObject private var themeManager = ThemeManager.shared

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
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Providers")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(theme.primaryText)

                    Text(subtitleText)
                        .font(.system(size: 14))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()

                Button(action: { showAddSheet = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Add Provider")
                            .font(.system(size: 13, weight: .medium))
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
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .background(theme.secondaryBackground)
    }

    private var subtitleText: String {
        let connectedCount = manager.providerStates.values.filter { $0.isConnected }.count
        let totalCount = manager.configuration.providers.count

        if totalCount == 0 {
            return "Connect to remote OpenAI-compatible APIs"
        } else if connectedCount == 0 {
            return "\(totalCount) provider\(totalCount == 1 ? "" : "s") configured"
        } else {
            let modelCount = manager.providerStates.values.reduce(0) { $0 + $1.modelCount }
            return "\(connectedCount) connected • \(modelCount) model\(modelCount == 1 ? "" : "s") available"
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(theme.accentColor.opacity(0.1))
                    .frame(width: 80, height: 80)

                Image(systemName: "cloud.fill")
                    .font(.system(size: 36))
                    .foregroundColor(theme.accentColor)
            }

            VStack(spacing: 8) {
                Text("No Remote Providers")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text("Connect to OpenAI, Ollama, LM Studio, or any\nOpenAI-compatible API to access remote models.")
                    .font(.system(size: 14))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
            }

            Button(action: { showAddSheet = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Add Your First Provider")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.accentColor)
                )
            }
            .buttonStyle(PlainButtonStyle())

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
                    RoundedRectangle(cornerRadius: 12)
                        .fill(statusColor.opacity(0.12))
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 22))
                        .foregroundColor(statusColor)
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
        .alert("Delete Provider?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { onDelete() }
        } message: {
            Text("This will remove '\(provider.name)' and disconnect any active sessions.")
        }
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
