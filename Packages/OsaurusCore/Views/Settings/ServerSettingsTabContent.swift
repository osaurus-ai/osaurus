//
//  ServerSettingsTabContent.swift
//  osaurus
//
//  Centralized Server → Settings panel. Single editing surface for
//  every runtime knob exposed by `VMLXServerRuntimeSettings` (network,
//  generation, concurrency, cache, multimodal, MTP, power, tools),
//  plus the Osaurus-specific model residency and HTTP body limits that
//  still live on `ServerConfiguration`.
//
//  Each section lives in its own file under `ServerSettings/`. This
//  file owns the draft state, the save-pending bookkeeping, validation
//  banner, restart banner, and the Save / Reset action row.
//

import AppKit
@preconcurrency import MLXLMCommon
import SwiftUI

struct ServerSettingsTabContent: View {
    @EnvironmentObject var server: ServerController
    @ObservedObject private var themeManager = ThemeManager.shared

    /// Local working copy — saved to disk only on "Save Changes" so
    /// typing in a text field doesn't restart the NIO server every
    /// keystroke.
    @State private var draft: VMLXServerRuntimeSettings = .init()

    /// Companion edit state for legacy fields that still live on
    /// `ServerConfiguration` (model eviction policy, idle residency,
    /// max body sizes).
    @State private var draftLegacy: ServerConfiguration = .default

    @State private var hasLoaded: Bool = false
    @State private var saving: Bool = false
    @State private var successMessage: String?

    private var theme: ThemeProtocol { themeManager.currentTheme }

    /// Fields that require a NIO restart or a host-side rebind.
    private var pendingRestart: Bool {
        draft.network.port != server.runtimeSettings.network.port
            || draft.network.host != server.runtimeSettings.network.host
            || draft.network.corsOrigins != server.runtimeSettings.network.corsOrigins
            || draft.concurrency.maxConcurrentSequences
                != server.runtimeSettings.concurrency.maxConcurrentSequences
            || draftLegacy.modelEvictionPolicy != server.configuration.modelEvictionPolicy
            || draftLegacy.maxRequestBodyBytes != server.configuration.maxRequestBodyBytes
            || draftLegacy.maxPairingBodyBytes != server.configuration.maxPairingBodyBytes
    }

    private var hasUnsavedChanges: Bool {
        draft != server.runtimeSettings
            || draftLegacy.modelEvictionPolicy != server.configuration.modelEvictionPolicy
            || draftLegacy.modelIdleResidencyPolicy != server.configuration.modelIdleResidencyPolicy
            || draftLegacy.maxRequestBodyBytes != server.configuration.maxRequestBodyBytes
            || draftLegacy.maxPairingBodyBytes != server.configuration.maxPairingBodyBytes
    }

    private var validationIssues: [VMLXServerSettingsIssue] {
        draft.validationIssues()
    }

    var body: some View {
        ZStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if pendingRestart && server.isRunning {
                        restartBanner
                    }
                    if !validationIssues.isEmpty {
                        validationIssuesBanner
                    }

                    NetworkSection(draft: $draft)
                    GenerationDefaultsSection(draft: $draft)
                    ConcurrencySection(draft: $draft)
                    CacheSection(draft: $draft)
                    MultimodalSection(draft: $draft)
                    MTPSection(draft: $draft)
                    PowerSection(draft: $draft)
                    ToolsTemplatesSection(draft: $draft)
                    ModelResidencySection(draft: $draftLegacy)
                    AdvancedHTTPSection(draft: $draftLegacy)

                    actionRow
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }

            if let message = successMessage {
                VStack {
                    Spacer()
                    ThemedToastView(message, type: .success)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 20)
                }
            }
        }
        .onAppear {
            guard !hasLoaded else { return }
            hasLoaded = true
            draft = server.runtimeSettings
            draftLegacy = server.configuration
        }
        .onChange(of: server.runtimeSettings) { _, newValue in
            if !hasUnsavedChanges { draft = newValue }
        }
        .onChange(of: server.configuration) { _, newValue in
            if !hasUnsavedChanges { draftLegacy = newValue }
        }
    }

    // MARK: - Banners

    private var validationIssuesBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.warningColor)
                Text("Configuration issues", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.warningColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(validationIssues, id: \.field) { issue in
                    issueRow(issue)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(banneredBackground(color: theme.warningColor))
    }

    private func issueRow(_ issue: VMLXServerSettingsIssue) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(
                systemName: issue.severity == .error
                    ? "xmark.octagon.fill" : "exclamationmark.bubble.fill"
            )
            .font(.system(size: 10))
            .foregroundColor(issue.severity == .error ? theme.errorColor : theme.warningColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.field)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                Text(issue.message)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var restartBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.warningColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Server restart required", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.warningColor)
                Text(
                    "Saving these changes will restart the NIO server to bind the new socket and refresh middleware.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
            }
            Spacer()
        }
        .padding(12)
        .background(banneredBackground(color: theme.warningColor))
    }

    private func banneredBackground(color: Color) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(color.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(color.opacity(0.15), lineWidth: 1)
            )
    }

    // MARK: - Actions

    private var actionRow: some View {
        HStack(spacing: 12) {
            Spacer()
            Button(action: resetToDefaults) {
                Text("Reset to Defaults", bundle: .module)
            }
            .buttonStyle(SettingsButtonStyle())
            .disabled(saving)

            Button(action: { Task { await save() } }) {
                HStack(spacing: 6) {
                    if saving {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text(saving ? "Saving…" : "Save Changes", bundle: .module)
                }
            }
            .buttonStyle(SettingsButtonStyle(isPrimary: true))
            .disabled(saving || !hasUnsavedChanges)
        }
        .padding(.top, 8)
    }

    private func resetToDefaults() {
        // Migrate from the current legacy ServerConfiguration so the
        // user gets predictable defaults that line up with what's
        // actually persisted today.
        draft = ServerRuntimeSettingsStore.migratedFromLegacy(
            serverConfiguration: ServerConfiguration.default,
            userDefaults: .standard
        )
        let defaults = ServerConfiguration.default
        var reset = draftLegacy
        reset.modelEvictionPolicy = defaults.modelEvictionPolicy
        reset.modelIdleResidencyPolicy = defaults.modelIdleResidencyPolicy
        reset.maxRequestBodyBytes = defaults.maxRequestBodyBytes
        reset.maxPairingBodyBytes = defaults.maxPairingBodyBytes
        draftLegacy = reset
    }

    private func save() async {
        saving = true
        defer { saving = false }

        // Persist legacy fields first so projection inside
        // `saveRuntimeSettings` reads the latest base.
        var updatedConfig = server.configuration
        updatedConfig.modelEvictionPolicy = draftLegacy.modelEvictionPolicy
        updatedConfig.modelIdleResidencyPolicy = draftLegacy.modelIdleResidencyPolicy
        updatedConfig.maxRequestBodyBytes = draftLegacy.maxRequestBodyBytes
        updatedConfig.maxPairingBodyBytes = draftLegacy.maxPairingBodyBytes
        if updatedConfig != server.configuration {
            server.configuration = updatedConfig
            server.saveConfiguration()
        }

        await server.saveRuntimeSettings(draft)

        // Mirror BatchEngine concurrency into the legacy UserDefaults
        // key so existing readers stay in sync when nothing else
        // consults the runtime snapshot.
        let defaults = UserDefaults.standard
        let key = "ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize"
        if let maxConcurrent = draft.concurrency.maxConcurrentSequences {
            defaults.set(maxConcurrent, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }

        showSuccess(L("Settings saved successfully"))
    }

    private func showSuccess(_ message: String) {
        withAnimation(theme.springAnimation()) {
            successMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(theme.animationQuick()) {
                successMessage = nil
            }
        }
    }
}
