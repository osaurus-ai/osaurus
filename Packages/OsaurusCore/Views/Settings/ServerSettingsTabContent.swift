//
//  ServerSettingsTabContent.swift
//  osaurus
//
//  Server → Settings panel. Two-pane layout with a sticky action bar:
//
//   ┌──────────────┬──────────────────────────────────────────┐
//   │ Sidebar      │  [Validation banner — only on errors]    │
//   │ (grouped     │                                          │
//   │  anchors,    │  ScrollView of section cards             │
//   │  pure nav)   │                                          │
//   ├──────────────┴──────────────────────────────────────────┤
//   │ [● Unsaved]  [⟳ Restart required]    [Reset] [Save]     │
//   └─────────────────────────────────────────────────────────┘
//
//  Click an anchor → `ScrollViewReader.scrollTo(...)`. Save / Reset
//  live in the full-width sticky `ServerSettingsActionBar` at the
//  bottom of the window so they're always in the user's eye line and
//  feel anchored to the entire panel, not just the content pane. The
//  restart-required signal lives as a chip in that same bar (not a
//  top banner) since it's "state about what happens when you Save".
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
    @State private var activeSection: ServerSettingsSection = .connection

    @ObservedObject private var managementState = ManagementStateManager.shared
    /// Section that just received a settings-search landing, briefly glowing.
    @State private var landedSection: ServerSettingsSection?
    @State private var landedClearTask: Task<Void, Never>?

    private var theme: ThemeProtocol { themeManager.currentTheme }

    /// Honour a settings-search result that targets a Server section: scroll to
    /// it and glow it once. Clears the one-shot request after applying.
    private func applySectionRequest() {
        guard let raw = managementState.serverSectionRequest,
            let section = ServerSettingsSection(rawValue: raw)
        else { return }
        managementState.serverSectionRequest = nil
        activeSection = section
        landedClearTask?.cancel()
        landedSection = section
        landedClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard !Task.isCancelled else { return }
            if landedSection == section { landedSection = nil }
        }
    }

    /// Fields that require a NIO restart or a host-side rebind.
    private var pendingRestart: Bool {
        draft.network.port != server.runtimeSettings.network.port
            || draft.network.host != server.runtimeSettings.network.host
            || draft.network.corsOrigins != server.runtimeSettings.network.corsOrigins
            || draftLegacy.modelEvictionPolicy != server.configuration.modelEvictionPolicy
            || draftLegacy.maxRequestBodyBytes != server.configuration.maxRequestBodyBytes
            || draftLegacy.maxPairingBodyBytes != server.configuration.maxPairingBodyBytes
    }

    private var hasUnsavedChanges: Bool {
        draft != server.runtimeSettings
            || draftLegacy.modelEvictionPolicy != server.configuration.modelEvictionPolicy
            || draftLegacy.globalProxyURL != server.configuration.globalProxyURL
            || draftLegacy.modelIdleResidencyPolicy != server.configuration.modelIdleResidencyPolicy
            || draftLegacy.maxRequestBodyBytes != server.configuration.maxRequestBodyBytes
            || draftLegacy.maxPairingBodyBytes != server.configuration.maxPairingBodyBytes
    }

    private var validationIssues: [VMLXServerSettingsIssue] {
        draft.validationIssues()
    }

    /// True when the current draft would force a server-side rebind on
    /// save AND the server is actually running. Drives the inline
    /// "Restart required" chip in `ServerSettingsActionBar`.
    private var requiresRestart: Bool { pendingRestart && server.isRunning }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ServerSettingsSidebarNav(selection: $activeSection)
                        .frame(width: 220)

                    contentPane
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                ServerSettingsActionBar(
                    hasUnsavedChanges: hasUnsavedChanges,
                    requiresRestart: requiresRestart,
                    saving: saving,
                    onSave: { Task { await save() } },
                    onReset: resetToDefaults
                )
            }

            if let message = successMessage {
                ThemedToastView(message, type: .success)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 70)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .onAppear {
            // Defer a beat so the section scroll runs after first layout.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                applySectionRequest()
            }
            guard !hasLoaded else { return }
            hasLoaded = true
            draft = server.runtimeSettings
            draftLegacy = server.configuration
        }
        .onChange(of: managementState.serverSectionRequest) { _, _ in
            applySectionRequest()
        }
        .onChange(of: server.runtimeSettings) { _, newValue in
            if !hasUnsavedChanges { draft = newValue }
        }
        .onChange(of: server.configuration) { _, newValue in
            if !hasUnsavedChanges { draftLegacy = newValue }
        }
    }

    // MARK: - Content pane

    private var contentPane: some View {
        VStack(spacing: 0) {
            validationBanner
            sectionScroll
        }
    }

    /// Top-of-content validation banner. Restart-required state is
    /// shown inline in `ServerSettingsActionBar`, so the top region is
    /// reserved for actionable error detail only.
    @ViewBuilder
    private var validationBanner: some View {
        if !validationIssues.isEmpty {
            ServerSettingsValidationBanner(issues: validationIssues)
                .padding(EdgeInsets(top: 18, leading: 24, bottom: 6, trailing: 24))
        }
    }

    private var sectionScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ConnectionSection(draft: $draft)
                        .id(ServerSettingsSection.connection)
                        .settingsSearchHighlight(landedSection == .connection)
                    GlobalProxySection(draft: $draftLegacy)
                        .id(ServerSettingsSection.globalProxy)
                        .settingsSearchHighlight(landedSection == .globalProxy)
                    AuthenticationSection(draft: $draft)
                        .id(ServerSettingsSection.authentication)
                        .settingsSearchHighlight(landedSection == .authentication)
                    GenerationDefaultsSection(draft: $draft)
                        .id(ServerSettingsSection.sampling)
                        .settingsSearchHighlight(landedSection == .sampling)
                    ConcurrencySection(draft: $draft)
                        .id(ServerSettingsSection.concurrency)
                        .settingsSearchHighlight(landedSection == .concurrency)
                    CacheSection(draft: $draft)
                        .id(ServerSettingsSection.cache)
                        .settingsSearchHighlight(landedSection == .cache)
                    MemorySafetySection(draft: $draft)
                        .id(ServerSettingsSection.memorySafety)
                        .settingsSearchHighlight(landedSection == .memorySafety)
                    DecodePerformanceSection(draft: $draft)
                        .id(ServerSettingsSection.decodePerformance)
                        .settingsSearchHighlight(landedSection == .decodePerformance)
                    MTPSection(draft: $draft)
                        .id(ServerSettingsSection.speculative)
                        .settingsSearchHighlight(landedSection == .speculative)
                    LiveActivitySection()
                        .id(ServerSettingsSection.liveActivity)
                        .settingsSearchHighlight(landedSection == .liveActivity)
                    MultimodalSection(draft: $draft)
                        .id(ServerSettingsSection.multimodal)
                        .settingsSearchHighlight(landedSection == .multimodal)
                    ToolsTemplatesSection(draft: $draft)
                        .id(ServerSettingsSection.tools)
                        .settingsSearchHighlight(landedSection == .tools)
                    ModelResidencySection(draft: $draftLegacy)
                        .id(ServerSettingsSection.modelMemory)
                        .settingsSearchHighlight(landedSection == .modelMemory)
                    PowerSection(draft: $draft)
                        .id(ServerSettingsSection.power)
                        .settingsSearchHighlight(landedSection == .power)
                    AdvancedHTTPSection(draft: $draftLegacy)
                        .id(ServerSettingsSection.requestLimits)
                        .settingsSearchHighlight(landedSection == .requestLimits)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            // Gives `scrollTo(_:anchor: .top)` a breathing-room buffer so
            // anchored sections don't kiss the top edge of the scroll.
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: 12)
            }
            .onChange(of: activeSection) { _, new in
                withAnimation(.smooth(duration: 0.45)) {
                    proxy.scrollTo(new, anchor: .top)
                }
            }
        }
    }

    // MARK: - Actions

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
        reset.globalProxyURL = defaults.globalProxyURL
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
        updatedConfig.globalProxyURL = draftLegacy.globalProxyURL
        updatedConfig.maxRequestBodyBytes = draftLegacy.maxRequestBodyBytes
        updatedConfig.maxPairingBodyBytes = draftLegacy.maxPairingBodyBytes
        if updatedConfig != server.configuration {
            server.configuration = updatedConfig
            server.saveConfiguration()
        }

        await server.saveRuntimeSettings(draft)
        mirrorMaxBatchSizeToUserDefaults(draft.concurrency.maxConcurrentSequences)
        showSuccess(L("Settings saved successfully"))
    }

    /// Mirror BatchEngine concurrency into the legacy UserDefaults key
    /// so existing readers stay in sync when nothing else consults the
    /// runtime snapshot.
    private func mirrorMaxBatchSizeToUserDefaults(_ value: Int?) {
        let defaults = UserDefaults.standard
        let key = "ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize"
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
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
