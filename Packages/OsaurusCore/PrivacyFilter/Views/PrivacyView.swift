//
//  PrivacyView.swift
//  osaurus / PrivacyFilter
//
//  Top-level "Privacy" management tab. Always renders
//  `ManagerHeaderWithTabs` + four sub-tabs (Overview / Rules /
//  Providers / Model) so the surface scans like Server and Voice
//  instead of a long card scroll.
//
//  The on-device AI model is OPTIONAL: the regex / preset / custom-rule
//  layer works with zero download, so the panel is never gated on the
//  bundle. The install + status UI lives in the Model tab, and the
//  AI-detection toggle in Overview is the only control that needs the
//  bundle (disabled with an Install link until the model verifies).
//
//  Persistence: `save()` is intentionally synchronous now. The previous
//  `Task.detached { ... }` hop let the master toggle race app quit,
//  which is why the "Enable Privacy Filter" switch kept resetting to
//  off across restarts. See `PrivacyFilterStorePersistenceTests`.
//

import SwiftUI

/// Per-view holder for the debounced-save `DispatchWorkItem`. Lives
/// in a class so SwiftUI's `@StateObject` keeps the same instance
/// across view re-renders, and so the `deinit` flush has a clear
/// owner. `Sendable` because all writes happen on the main queue.
@MainActor
final class PrivacyViewSaveDebouncer: ObservableObject {
    /// Window matches the visible tick rate of the sliders / preset
    /// toggles; faster and the JSON write fires per-keystroke on a
    /// drag, slower and the user perceives a lag between flipping
    /// and the filter actually picking up the new value.
    static let debounceInterval: TimeInterval = 0.3

    private var pendingWork: DispatchWorkItem?

    /// Cancel any pending write and schedule a new one. The closure
    /// is captured by the work item, so each call snapshots the
    /// configuration at scheduling time — the trailing-edge value
    /// wins, which is the standard slider-drag behavior.
    func schedule(_ work: @escaping @Sendable () -> Void) {
        pendingWork?.cancel()
        let item = DispatchWorkItem(block: work)
        pendingWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: item)
    }

    /// Run any pending work right now and drop the work item.
    /// Called from `onDisappear` and on app-quit notifications so
    /// a debounced write can't be lost if the user closes the
    /// settings sheet or quits within the debounce window.
    func flush() {
        if let item = pendingWork {
            item.cancel()
            item.perform()
            pendingWork = nil
        }
    }

    // No `deinit` cancel: `DispatchWorkItem` is non-`Sendable` so
    // the nonisolated default deinit can't touch `pendingWork`,
    // and a custom deinit would have to hop to MainActor. The
    // `onDisappear` + `willTerminate` hooks on `PrivacyView`
    // already cover the graceful flush paths; if neither fires
    // (e.g. SwiftUI tears the view down silently), the work item
    // simply runs after the view is gone — its closure only
    // touches the file system, not view state, so that's a safe
    // tail.
}

struct PrivacyView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var downloader = PrivacyFilterModelDownloader.shared
    @ObservedObject private var rampartManager = RampartModelManager.shared
    @ObservedObject private var providerManager = RemoteProviderManager.shared
    @StateObject private var saveDebouncer = PrivacyViewSaveDebouncer()

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var configuration: PrivacyFilterConfiguration = PrivacyFilterStore.snapshot()
    @State private var hasAppeared = false
    @State private var forgetActionMessage: String?
    @State private var presetsExpanded = false
    @State private var customRuleEditorContext: CustomRuleEditorContext?
    @State private var selectedTab: PrivacyTab = .overview

    /// True when the detection model is fully installed + verified.
    /// Gates only the model-dependent affordances: the AI-detection
    /// toggle, the Model tab's installed/empty state, and whether the
    /// dry-run tester may use the model. The tabbed surface itself
    /// always renders since the regex layer needs no bundle.
    private var isModelReady: Bool {
        switch configuration.aiDetectionBackend {
        case .openai:
            if case .ready = downloader.state { return true }
            return false
        case .rampart:
            if case .ready = rampartManager.state { return true }
            return RampartModelManager.bundleExists()
        }
    }

    /// Tabs whose content is a centered full-screen state rather than a
    /// scrollable card list: the Providers empty state and the
    /// not-yet-installed Model hero. These fill the content area
    /// (bypassing the scroll view + insets) so the shared
    /// `SettingsEmptyState` centers like every other settings tab.
    private var isFullBleedTab: Bool {
        switch selectedTab {
        case .providers:
            return providerManager.configuration.providers.isEmpty
        case .model:
            return false
        default:
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .managerHeaderEntrance(hasAppeared: hasAppeared)

            // The tabbed surface is ALWAYS shown now — the regex /
            // custom-rule layer works without the on-device model, so
            // gating the whole panel on `isModelReady` would have
            // hidden the rules a no-download user can fully use. The
            // model's install / status UI lives in the Model tab.
            //
            // Full-bleed tabs (the Providers empty state, the
            // not-yet-installed Model hero) fill the content area so
            // their centered `SettingsEmptyState` reads like the rest
            // of the app; the card-list tabs scroll under 24pt insets.
            Group {
                if isFullBleedTab {
                    selectedTabContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        selectedTabContent
                            .padding(.horizontal, 24)
                            .padding(.vertical, 24)
                            .frame(maxWidth: .infinity, alignment: .top)
                            .settingsLandingAnchor("privacy.tab")
                    }
                }
            }
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            configuration = PrivacyFilterStore.snapshot()
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
        .onDisappear {
            // Flush any pending debounced write so closing Settings
            // (or the user navigating away) never strands a
            // half-second-old slider value off-disk. The flush also
            // runs naturally in the debouncer's `deinit`, but we
            // can't reach the MainActor from there, so the
            // disappear path is the canonical hook.
            saveDebouncer.flush()
        }
        .onReceive(NotificationCenter.default.publisher(for: .privacyFilterConfigurationChanged)) { _ in
            configuration = PrivacyFilterStore.snapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            // Belt-and-suspenders for the user-quits-while-sheet-open
            // race that motivated the synchronous master toggle.
            // `onDisappear` doesn't fire when the entire app
            // process is going down.
            saveDebouncer.flush()
        }
        .sheet(item: $customRuleEditorContext) { context in
            PrivacyCustomRuleEditor(
                initialRule: context.rule,
                onSave: { savedRule in
                    apply(editedRule: savedRule, replacing: context.rule?.id)
                    customRuleEditorContext = nil
                },
                onCancel: { customRuleEditorContext = nil }
            )
            .environment(\.theme, themeManager.currentTheme)
        }
    }

    // MARK: - Header

    /// Tabbed header so users can jump between
    /// Overview/Rules/Providers/Model without scrolling. No header
    /// actions today — install/verify/remove all live in the Model tab.
    private var headerView: some View {
        ManagerHeaderWithTabs(
            title: L("Privacy"),
            subtitle: L("Redact sensitive content before it leaves your Mac, then restore it on responses.")
        ) {
            EmptyView()
        } tabsRow: {
            HeaderTabsRow(selection: $selectedTab)
        }
    }

    // MARK: - Tab dispatch

    @ViewBuilder
    private var selectedTabContent: some View {
        switch selectedTab {
        case .overview:
            PrivacyOverviewTab(
                configuration: $configuration,
                save: save,
                isModelReady: isModelReady,
                onInstallModel: { selectedTab = .model },
                forgetActionMessage: forgetActionMessage,
                forgetAllRedactions: forgetAllRedactions
            )
        case .rules:
            PrivacyRulesTab(
                configuration: $configuration,
                save: save,
                saveDebounced: saveDebounced,
                isModelReady: isModelReady,
                presetsExpanded: $presetsExpanded,
                customRuleEditorContext: $customRuleEditorContext,
                onDeleteCustomRule: deleteCustomRule(id:),
                onToggleCustomRule: setCustomRuleEnabled(id:enabled:)
            )
        case .providers:
            PrivacyProvidersTab(
                providers: providerManager.configuration.providers,
                configuration: $configuration,
                save: save,
                saveDebounced: saveDebounced,
                hasAppeared: hasAppeared,
                onOpenProviders: { ManagementStateManager.shared.selectedTab = .providers }
            )
        case .model:
            VStack(alignment: .leading, spacing: 16) {
                Text(
                    "Choose the on-device model that powers AI detection. Pattern rules in the Rules tab work without any model.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)

                PrivacyModelSelector(configuration: $configuration, save: save, layout: .sections)
            }
        }
    }

    // MARK: - Install action routing

    // MARK: - Custom rule mutations

    private func setCustomRuleEnabled(id: UUID, enabled: Bool) {
        guard let idx = configuration.customRules.firstIndex(where: { $0.id == id })
        else { return }
        configuration.customRules[idx].enabled = enabled
        save()
    }

    private func deleteCustomRule(id: UUID) {
        configuration.customRules.removeAll { $0.id == id }
        save()
    }

    private func apply(editedRule rule: PrivacyRule, replacing existingId: UUID?) {
        if let existingId,
            let idx = configuration.customRules.firstIndex(where: { $0.id == existingId })
        {
            configuration.customRules[idx] = rule
        } else {
            configuration.customRules.append(rule)
        }
        save()
    }

    // MARK: - Forget redactions

    private func forgetAllRedactions() {
        Task { @MainActor in
            await SessionRedactionStore.shared.invalidateAll()
            forgetActionMessage = L("privacy.forget.cleared")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            forgetActionMessage = nil
        }
    }

    // MARK: - Persistence

    /// Synchronous on purpose. The previous `Task.detached { ... }`
    /// hop let the user toggle the master switch ON and then quit the
    /// app before the JSON write landed on disk — on next launch the
    /// store fell back to `enabled: false` (see
    /// `PrivacyFilterStorePersistenceTests`). JSON encode + atomic
    /// write of the ~1KB config is microseconds; this matches how
    /// `MemoryConfigurationStore.save` works in the rest of the app.
    ///
    /// Use this for fields where the user's perceived state MUST
    /// match the on-disk state immediately (master toggle,
    /// requireReview, master alwaysApprove). Slider-shaped or
    /// preset-toggle-shaped fields go through `saveDebounced()` so
    /// dragging a slider doesn't issue 60 atomic writes per second.
    private func save() {
        saveDebouncer.flush()
        PrivacyFilterStore.save(configuration)
    }

    /// Debounced variant. Each call snapshots `configuration`
    /// at scheduling time and cancels any pending write — only the
    /// trailing-edge value is written. If the view disappears or
    /// the user quits within `PrivacyViewSaveDebouncer.debounceInterval`,
    /// the `onDisappear` hook flushes synchronously so the change
    /// still lands.
    private func saveDebounced() {
        let snapshot = configuration
        saveDebouncer.schedule {
            PrivacyFilterStore.save(snapshot)
        }
    }
}

// MARK: - Privacy Tab

/// The four sub-sections of the Privacy tab. Providers stays in the
/// list even when zero remote providers are configured — the tab
/// surfaces an empty state pointing the user at the Remote Providers
/// manager rather than silently disappearing. Keeps the tab count
/// stable so the layout doesn't shift the moment a provider is
/// added/removed elsewhere.
///
/// `Hashable` is synthesized from the `String` raw value, which is
/// what `AnimatedTabItem`'s `ForEach(id: \.self)` needs.
private enum PrivacyTab: String, CaseIterable, AnimatedTabItem {
    case overview
    case rules
    case providers
    case model

    var title: String {
        switch self {
        case .overview: return L("Overview")
        case .rules: return L("Rules")
        case .providers: return L("Providers")
        case .model: return L("Models")
        }
    }
}

// MARK: - Model selector (shared by Overview + Models tabs)

/// Chooser between the available on-device detection models, rendered on the
/// shared `ModelListRow`. Self-contained: reads/writes
/// `configuration.aiDetectionBackend` and drives each model's download/manage
/// lifecycle through its manager singleton. The Overview tab renders the rows
/// flat (`.flat`); the Models tab groups them into Installed / Available
/// sections (`.sections`) to match the Voice and Images tabs.
private struct PrivacyModelSelector: View {
    enum Layout { case flat, sections }

    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @Binding var configuration: PrivacyFilterConfiguration
    let save: () -> Void
    var layout: Layout = .flat

    @ObservedObject private var downloader = PrivacyFilterModelDownloader.shared
    @ObservedObject private var rampart = RampartModelManager.shared
    @State private var pendingRemoval: PrivacyAIBackend?

    /// Rampart first (the lightweight default suggestion), then OpenAI.
    private let backends: [PrivacyAIBackend] = [.rampart, .openai]

    private var installedBackends: [PrivacyAIBackend] { backends.filter(isInstalled) }
    private var availableBackends: [PrivacyAIBackend] { backends.filter { !isInstalled($0) } }

    var body: some View {
        content
            .confirmationDialog(
                Text("Remove model?", bundle: .module),
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(role: .destructive) {
                    if let backend = pendingRemoval { remove(backend) }
                    pendingRemoval = nil
                } label: {
                    Text("Remove Model", bundle: .module)
                }
                Button(role: .cancel) {
                    pendingRemoval = nil
                } label: {
                    Text("Cancel", bundle: .module)
                }
            } message: {
                Text(
                    "This deletes the on-disk model. Detection for it stops until you re-download.",
                    bundle: .module
                )
            }
    }

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .flat:
            VStack(spacing: 8) {
                ForEach(backends, id: \.self) { row($0) }
            }
        case .sections:
            VStack(alignment: .leading, spacing: 24) {
                if !installedBackends.isEmpty {
                    SettingsSection(title: "Installed", icon: "checkmark.seal.fill") {
                        VStack(spacing: 8) {
                            ForEach(installedBackends, id: \.self) { row($0) }
                        }
                    }
                }
                if !availableBackends.isEmpty {
                    SettingsSection(title: "Available", icon: "square.and.arrow.down") {
                        VStack(spacing: 8) {
                            ForEach(availableBackends, id: \.self) { row($0) }
                        }
                    }
                }
            }
        }
    }

    // MARK: Row

    private func row(_ backend: PrivacyAIBackend) -> ModelListRow {
        let info = meta(backend)
        let installed = isInstalled(backend)
        let active = installed && configuration.aiDetectionBackend == backend
        return ModelListRow(
            title: info.name,
            subtitle: "\(info.size) · \(info.summary)",
            leading: leading(backend, installed: installed),
            isDefault: active,
            status: status(backend),
            primary: primaryAction(backend, installed: installed, active: active),
            menuItems: menuItems(backend, installed: installed),
            onViewHuggingFace: { openHuggingFace(repoId(backend)) },
            onCancel: cancelAction(backend)
        )
    }

    private func leading(_ backend: PrivacyAIBackend, installed: Bool) -> ModelListRow.Leading {
        if installed { return .init(icon: "checkmark.seal.fill", tint: theme.successColor) }
        if case .failed = status(backend) {
            return .init(icon: "exclamationmark.triangle.fill", tint: theme.warningColor)
        }
        return .init(icon: "cube.box.fill", tint: theme.accentColor)
    }

    // MARK: Metadata

    private func meta(_ backend: PrivacyAIBackend) -> (name: String, size: String, summary: String) {
        switch backend {
        case .rampart:
            return (
                "Rampart", "~37 MB",
                L("Tiny and fast. Catches names, addresses, and IDs/secrets. No date detection.")
            )
        case .openai:
            return (
                "OpenAI Privacy Filter", "~2.8 GB",
                L(
                    "Highest coverage. Adds names, addresses, dates, and free-form secrets beyond pattern rules."
                )
            )
        }
    }

    private func repoId(_ backend: PrivacyAIBackend) -> String {
        switch backend {
        case .openai: return PrivacyFilterModelDownloader.repoId
        case .rampart: return RampartModelManager.repoId
        }
    }

    private func isInstalled(_ backend: PrivacyAIBackend) -> Bool {
        switch backend {
        case .openai:
            if case .ready = downloader.state { return true }
            return false
        case .rampart:
            if case .ready = rampart.state { return true }
            return RampartModelManager.bundleExists()
        }
    }

    // MARK: Status mapping

    private func status(_ backend: PrivacyAIBackend) -> ModelListRow.Status {
        switch backend {
        case .openai:
            switch downloader.state {
            case .idle: return .idle
            case .enumerating: return .inProgress(progress: nil, detail: L("Preparing…"))
            case let .downloading(_, _, _, done, total):
                let progress = total > 0 ? Double(done) / Double(total) : nil
                return .inProgress(progress: progress, detail: nil)
            case .verifying: return .inProgress(progress: nil, detail: L("Verifying…"))
            case .ready: return .ready
            case .failed(let message): return .failed(message)
            }
        case .rampart:
            switch rampart.state {
            case .idle:
                return RampartModelManager.bundleExists() ? .ready : .idle
            case .downloading(let progress):
                return .inProgress(progress: progress, detail: nil)
            case .ready: return .ready
            case .failed(let message): return .failed(message)
            }
        }
    }

    // MARK: Actions

    private func primaryAction(_ backend: PrivacyAIBackend, installed: Bool, active: Bool)
        -> ModelListRow.Action?
    {
        if installed {
            // The active model shows the Default badge; other installed models
            // offer Set as Default. The active one needs no primary action.
            guard !active else { return nil }
            return ModelListRow.Action(title: "Set as Default", icon: "checkmark.circle") {
                configuration.aiDetectionBackend = backend
                save()
            }
        }
        // Not installed: Install, or Retry after a failed attempt.
        if case .failed = status(backend) {
            return ModelListRow.Action(title: "Retry", icon: "arrow.clockwise") {
                startDownload(backend)
            }
        }
        return ModelListRow.Action(title: "Install", icon: "arrow.down.circle") {
            startDownload(backend)
        }
    }

    private func menuItems(_ backend: PrivacyAIBackend, installed: Bool) -> [ModelListRow.Action] {
        guard installed else { return [] }
        var items: [ModelListRow.Action] = []
        // Re-verify recomputes the OpenAI bundle manifest; Rampart has no
        // verify step, so it only offers Remove.
        if backend == .openai {
            items.append(
                ModelListRow.Action(title: "Re-verify", icon: "arrow.clockwise") {
                    downloader.reverify()
                }
            )
        }
        items.append(
            ModelListRow.Action(title: "Remove", icon: "trash", role: .destructive) {
                pendingRemoval = backend
            }
        )
        return items
    }

    private func startDownload(_ backend: PrivacyAIBackend) {
        switch backend {
        case .openai: PrivacyFilterModelDownloader.shared.startDownload()
        case .rampart: RampartModelManager.shared.startDownload()
        }
    }

    private func cancelAction(_ backend: PrivacyAIBackend) -> () -> Void {
        switch backend {
        case .openai: return { downloader.cancel() }
        case .rampart: return { rampart.cancel() }
        }
    }

    private func openHuggingFace(_ repoId: String) {
        guard let url = URL(string: "https://huggingface.co/\(repoId)") else { return }
        openURL(url)
    }

    private func remove(_ backend: PrivacyAIBackend) {
        switch backend {
        case .openai:
            configuration.aiDetectionEnabled = false
            save()
            PrivacyFilterModelDownloader.shared.remove()
        case .rampart:
            RampartModelManager.shared.remove()
        }
    }
}

// MARK: - Overview Tab

/// The "what does the filter actually do" tab: master enable toggle,
/// the AI-detection layer toggle, review behavior (always-approve /
/// skip code), and the conversation-level Forget Redactions verb.
/// These are the most-touched controls so they live one tap away
/// from the header.
private struct PrivacyOverviewTab: View {
    @Environment(\.theme) private var theme
    @Binding var configuration: PrivacyFilterConfiguration
    let save: () -> Void
    /// Whether the on-device detection model is installed + verified.
    /// Gates the AI-detection toggle: AI can't be turned on without
    /// the bundle (an AI-on + no-model state would fail-close every
    /// cloud send), so when this is false we show an install prompt.
    let isModelReady: Bool
    /// Jump to the Models tab so the user can install a bundle.
    let onInstallModel: () -> Void
    /// Read-only — the parent owns this `@State` and re-renders the
    /// tab when it changes; the tab never writes back to it.
    let forgetActionMessage: String?
    let forgetAllRedactions: () -> Void

    /// Usage-analytics consent. Mirrors `TelemetryService.shared.isEnabled`
    /// (opt-in: true only once granted). Applied immediately on change.
    @State private var telemetryEnabled = false
    /// Crash-reporting consent. Mirrors `CrashReportingService.shared.isEnabled`
    /// (opt-out: defaults on). Applied immediately on change.
    @State private var crashReportingEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            dataCollectionSection

            SettingsSection(title: L("Filter"), icon: "lock.shield.fill") {
                SettingsSubsection(label: "Detection") {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsToggle(
                            title: L("Scrub PII before sending to cloud providers"),
                            description: L(
                                "Detects PII in your messages and asks you to review before any cloud-bound request. Local models (MLX, Foundation) and on-device tools bypass the filter."
                            ),
                            isOn: Binding(
                                get: { configuration.enabled },
                                set: { newValue in
                                    configuration.enabled = newValue
                                    save()
                                }
                            )
                        )

                        if configuration.enabled {
                            SettingsToggle(
                                title: L("AI detection (on-device model)"),
                                description: L(
                                    "Use an on-device model to catch names, addresses, and secrets that pattern rules miss. Pick and install a model below."
                                ),
                                isOn: Binding(
                                    get: { configuration.aiDetectionEnabled },
                                    set: { newValue in
                                        configuration.aiDetectionEnabled = newValue
                                        save()
                                    }
                                )
                            )

                            PrivacyModelSelector(configuration: $configuration, save: save)
                        }

                        if configuration.enabled && !hasActiveDetector {
                            noDetectorNote
                        }
                    }
                }

                SettingsSubsection(label: "Review") {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsToggle(
                            title: L("Skip Code Blocks"),
                            description: L("Don't scan fenced (```) or inline (`) code spans."),
                            isOn: Binding(
                                get: { configuration.skipCodeBlocks },
                                set: { newValue in
                                    configuration.skipCodeBlocks = newValue
                                    save()
                                }
                            )
                        )

                        SettingsToggle(
                            title: L("Always Approve by Default"),
                            description: L("Skip the review sheet — still redact, just don't ask each turn."),
                            isOn: Binding(
                                get: { configuration.alwaysApproveByDefault },
                                set: { newValue in
                                    configuration.alwaysApproveByDefault = newValue
                                    save()
                                }
                            )
                        )
                    }
                }
            }

            SettingsSection(
                title: L("Conversation Privacy"),
                icon: "person.crop.circle.fill.badge.minus"
            ) {
                forgetCard
            }
        }
        .onAppear {
            telemetryEnabled = TelemetryService.shared.isEnabled
            crashReportingEnabled = CrashReportingService.shared.isEnabled
        }
    }

    // MARK: - Data collection

    /// Anonymous usage-analytics + crash-reporting consent. Lives at the top
    /// of the Privacy overview so the app's data-collection switches sit with
    /// the rest of the privacy controls. Both apply immediately on change.
    private var dataCollectionSection: some View {
        SettingsSection(title: L("Data Collection"), icon: "hand.raised") {
            VStack(alignment: .leading, spacing: 20) {
                Text(
                    "Control what anonymous data Osaurus collects.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)

                SettingsToggle(
                    title: L("Share Anonymous Usage Data"),
                    description:
                        "Send anonymous, aggregated usage analytics to help improve Osaurus. Never includes your chats, prompts, files, or keys. Turn off any time.",
                    anchorId: "settings.privacy.usage",
                    isOn: $telemetryEnabled
                )
                .onChange(of: telemetryEnabled) { _, newValue in
                    TelemetryService.shared.setEnabled(newValue)
                }

                SettingsToggle(
                    title: L("Send Crash Reports"),
                    description:
                        "Send anonymous crash and freeze reports so we can fix what breaks. Never includes your chats, prompts, files, or keys. Turn off any time.",
                    anchorId: "settings.privacy.crash",
                    isOn: $crashReportingEnabled
                )
                .onChange(of: crashReportingEnabled) { _, newValue in
                    CrashReportingService.shared.setEnabled(newValue)
                }
            }
        }
    }

    /// True when at least one detection source would actually run for
    /// an outbound send: the AI layer (model installed + enabled) or
    /// any active regex source (a built-in category, an enabled preset,
    /// or an enabled custom rule).
    private var hasActiveDetector: Bool {
        if isModelReady && configuration.aiDetectionEnabled { return true }
        let anyBuiltin = PrivacyFilterConfiguration.builtinPatternCategories
            .contains { configuration.isBuiltinPatternEnabled($0) }
        if anyBuiltin { return true }
        let anyPreset = PrivacyRulePresets.all.contains { configuration.isPresetEnabled($0.id) }
        if anyPreset { return true }
        return configuration.customRules.contains { $0.enabled }
    }

    /// Real informational note (not a gate): the filter is on but no
    /// detector would fire, so nothing gets redacted. Points the user
    /// at the two ways to fix it.
    private var noDetectorNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.warningColor)
            Text(
                "Privacy Filter is on, but no detector is active. Turn on AI detection above, or enable a pattern in the Rules tab — otherwise messages send unredacted.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.warningColor.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.warningColor.opacity(0.3), lineWidth: 1)
                )
        )
    }

    private var forgetCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "Clear every interned placeholder for every open conversation. Future sends mint fresh placeholders.",
                bundle: .module
            )
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(action: forgetAllRedactions) {
                    Text("Forget Redactions in Every Conversation", bundle: .module)
                }
                .buttonStyle(SettingsButtonStyle())
                Spacer()
                if let message = forgetActionMessage {
                    Text(LocalizedStringKey(message), bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.successColor)
                }
            }
        }
        .settingsRowCard()
    }
}

// MARK: - Rules Tab

/// Detection patterns + preset rules + custom rules. Keeps all the
/// "what does the matcher look for" controls in one place so users
/// don't have to hop between sub-tabs to enable a preset and then
/// add a custom regex.
private struct PrivacyRulesTab: View {
    @Environment(\.theme) private var theme
    @Binding var configuration: PrivacyFilterConfiguration
    let save: () -> Void
    /// Slider-shaped writes (preset toggles, built-in category
    /// toggles) route through this so a fast user-interaction
    /// (e.g. enabling four presets in a row) coalesces into one
    /// JSON write instead of four. Falls through to `save` on
    /// `onDisappear` / quit.
    let saveDebounced: () -> Void
    /// Lets the dry-run tester include the on-device model's spans
    /// when it's installed + loaded (otherwise it previews the regex
    /// layer alone).
    let isModelReady: Bool
    @Binding var presetsExpanded: Bool
    @Binding var customRuleEditorContext: CustomRuleEditorContext?
    let onDeleteCustomRule: (UUID) -> Void
    let onToggleCustomRule: (UUID, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            detectionPatternsSection
            presetRulesSection
            customRulesSection
            PrivacyDryRunTester(configuration: configuration, isModelReady: isModelReady)
        }
    }

    // MARK: Detection patterns

    private var detectionPatternsSection: some View {
        SettingsSection(title: L("Detection Patterns"), icon: "ruler") {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "Built-in deterministic detectors run alongside the on-device model. Turning a category off stops Osaurus from flagging it AND from blocking sends when it leaks past redaction.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)

                builtinPatternToggle(
                    category: .phone,
                    title: L("Phone numbers"),
                    description: L("US-style 10–12 digit phone numbers, with or without separators.")
                )
                builtinPatternToggle(
                    category: .email,
                    title: L("Email addresses"),
                    description: L("Standard local@domain.tld addresses.")
                )
                builtinPatternToggle(
                    category: .url,
                    title: L("URLs"),
                    description: L("http(s) URLs that include a scheme.")
                )
                builtinPatternToggle(
                    category: .accountNumber,
                    title: L("Account numbers"),
                    description: L("US Social Security numbers and Luhn-valid credit card numbers.")
                )
            }
        }
    }

    private func builtinPatternToggle(
        category: EntityCategory,
        title: String,
        description: String
    ) -> some View {
        SettingsToggle(
            title: title,
            description: description,
            isOn: Binding(
                get: { configuration.isBuiltinPatternEnabled(category) },
                set: { newValue in
                    configuration.builtinPatternEnabled[category] = newValue
                    saveDebounced()
                }
            )
        )
    }

    // MARK: Preset rules

    private var presetRulesSection: some View {
        SettingsSection(title: L("Preset Rules"), icon: "books.vertical.fill") {
            VStack(alignment: .leading, spacing: 0) {
                presetsHeaderRow
                if presetsExpanded {
                    Divider()
                        .padding(.vertical, 8)
                    VStack(spacing: 10) {
                        ForEach(PrivacyRulePresets.all) { preset in
                            presetRow(preset)
                        }
                    }
                }
            }
        }
    }

    private var presetsHeaderRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                presetsExpanded.toggle()
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        "Opt-in patterns for common secrets and IDs.",
                        bundle: .module
                    )
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)

                    Text(
                        "All disabled by default. Enable individually — Osaurus will redact matches and block sends that leak them.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text(verbatim: "\(enabledPresetCount)/\(PrivacyRulePresets.all.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                Image(systemName: presetsExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var enabledPresetCount: Int {
        PrivacyRulePresets.all.filter { configuration.isPresetEnabled($0.id) }.count
    }

    private func presetRow(_ preset: PrivacyRulePresets.Preset) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(LocalizedStringKey(presetTitleKey(preset.id)), bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    PrivacyCategoryBadge(category: preset.category)
                }
                Text(LocalizedStringKey(presetDescriptionKey(preset.id)), bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: preset.sample)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            Toggle(
                "",
                isOn: Binding(
                    get: { configuration.isPresetEnabled(preset.id) },
                    set: { newValue in
                        configuration.presetRules[preset.id] = newValue
                        saveDebounced()
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .settingsRowCard()
    }

    private func presetTitleKey(_ id: String) -> String { "privacy.presets.\(id).title" }
    private func presetDescriptionKey(_ id: String) -> String { "privacy.presets.\(id).description" }

    // MARK: Custom rules

    private var customRulesSection: some View {
        SettingsSection(title: L("Custom Rules"), icon: "wand.and.rays") {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "Catch internal codenames, customer IDs, or anything the built-ins miss. Build a rule with no regex, or write your own pattern.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

                if configuration.customRules.isEmpty {
                    HStack {
                        Text("No custom rules yet.", bundle: .module)
                            .font(.system(size: 12))
                            .foregroundColor(theme.tertiaryText)
                        Spacer()
                        addCustomRuleButton
                    }
                    .settingsRowCard()
                } else {
                    VStack(spacing: 8) {
                        ForEach(configuration.customRules) { rule in
                            customRuleRow(rule)
                        }
                    }
                    HStack {
                        Spacer()
                        addCustomRuleButton
                    }
                }
            }
        }
    }

    private var addCustomRuleButton: some View {
        Button {
            customRuleEditorContext = CustomRuleEditorContext(rule: nil)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus.circle.fill")
                Text("Add Rule", bundle: .module)
            }
        }
        .buttonStyle(SettingsButtonStyle(isPrimary: true))
    }

    /// Compact icon-tile button for the per-row Edit/Delete actions.
    /// Matches the app's tertiary icon-tile language (28pt rounded
    /// surface) instead of system `.bordered` buttons; `destructive`
    /// swaps the neutral chrome for a tinted error treatment.
    private func ruleRowIconButton(
        systemName: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(destructive ? theme.errorColor : theme.secondaryText)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(destructive ? theme.errorColor.opacity(0.10) : theme.tertiaryBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(
                                    destructive ? theme.errorColor.opacity(0.25) : theme.inputBorder,
                                    lineWidth: 1
                                )
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private func customRuleRow(_ rule: PrivacyRule) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(verbatim: rule.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    PrivacyCategoryBadge(category: rule.category)
                }
                Text(verbatim: rule.pattern)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            HStack(spacing: 6) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { rule.enabled },
                        set: { newValue in
                            onToggleCustomRule(rule.id, newValue)
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)

                ruleRowIconButton(systemName: "pencil") {
                    customRuleEditorContext = CustomRuleEditorContext(rule: rule)
                }
                .localizedHelp("Edit this rule.")

                ruleRowIconButton(systemName: "trash", destructive: true) {
                    onDeleteCustomRule(rule.id)
                }
                .localizedHelp("Delete this rule.")
            }
        }
        .settingsRowCard()
    }
}

// MARK: - Providers Tab

/// Per-provider override toggles. When no remote providers exist,
/// shows an empty state pointing the user at the Remote Providers
/// manager. Keeping the tab visible (rather than hiding it from the
/// tab bar) means the tab count stays stable and the user can
/// discover the feature even before configuring a provider.
private struct PrivacyProvidersTab: View {
    @Environment(\.theme) private var theme
    let providers: [RemoteProvider]
    @Binding var configuration: PrivacyFilterConfiguration
    let save: () -> Void
    /// Provider-toggle writes funnel through here so flipping a
    /// handful of providers in a row doesn't issue a JSON write
    /// per toggle.
    let saveDebounced: () -> Void
    /// Drives the shared empty state's entrance animation in step with
    /// the rest of the panel.
    let hasAppeared: Bool
    /// Jump to the Remote Providers manager so the user can add one.
    let onOpenProviders: () -> Void

    var body: some View {
        if providers.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 24) {
                SettingsSection(title: L("Per-Provider"), icon: "cloud.fill") {
                    VStack(spacing: 10) {
                        ForEach(providers) { provider in
                            providerToggleRow(provider)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        SettingsEmptyState(
            icon: "cloud.fill",
            title: "privacy.providers.empty.title",
            subtitle: "privacy.providers.empty.subtitle",
            examples: [],
            primaryAction: .init(
                title: L("Open Remote Providers"),
                icon: "cloud.fill",
                handler: onOpenProviders
            ),
            hasAppeared: hasAppeared
        )
    }

    private func providerToggleRow(_ provider: RemoteProvider) -> some View {
        SettingsToggle(
            title: provider.name,
            description: providerDescription(provider),
            isOn: Binding(
                get: { configuration.providerOverrides[provider.id.uuidString] ?? true },
                set: { newValue in
                    configuration.setProviderEnabled(provider.id, enabled: newValue)
                    saveDebounced()
                }
            )
        )
    }

    private func providerDescription(_ provider: RemoteProvider) -> String {
        let host = provider.host.isEmpty ? provider.providerType.rawValue : provider.host
        return String(
            format: L("privacy.providers.row.subtitle %@"),
            host
        )
    }
}

// MARK: - Dry-run Tester

/// All-rules dry-run tester. Paste sample text and preview exactly
/// what the live configuration would redact — the deterministic regex
/// layer always, plus the on-device model when it's installed + the
/// user has AI detection on. Runs the real `PrivacyFilterEngine.detect`
/// against a throwaway `RedactionMap` so the previewed placeholder
/// tokens match what an actual send would mint.
private struct PrivacyDryRunTester: View {
    @Environment(\.theme) private var theme
    let configuration: PrivacyFilterConfiguration
    let isModelReady: Bool

    @State private var sample: String = ""
    @State private var results: [DetectedEntity] = []
    @State private var didRun: Bool = false
    @State private var isRunning: Bool = false

    var body: some View {
        SettingsSection(title: L("Test Your Rules"), icon: "play.circle.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "Paste sample text to preview exactly what Osaurus would redact with your current rules — before anything reaches a provider.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

                TextField(L("Paste text to test…"), text: $sample, axis: .vertical)
                    .lineLimit(3 ... 8)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 10) {
                    Button(action: runTest) {
                        Text("Run test", bundle: .module)
                    }
                    .buttonStyle(SettingsButtonStyle(isPrimary: true))
                    .disabled(sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRunning)

                    if isRunning {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    Text(verbatim: layerNote)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                }

                if didRun {
                    resultsView
                }
            }
        }
    }

    /// Which detection layers the next run will use, so the user isn't
    /// surprised that model-only categories (names, addresses) don't
    /// appear when AI detection is off or the bundle isn't installed.
    private var layerNote: String {
        if configuration.aiDetectionEnabled && isModelReady {
            return L("Using AI + pattern rules")
        }
        return L("Using pattern rules only")
    }

    @ViewBuilder
    private var resultsView: some View {
        Divider().padding(.vertical, 2)
        if results.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .foregroundColor(theme.tertiaryText)
                Text("No matches — nothing would be redacted.", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: summaryText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                ForEach(EntityCategory.allCases, id: \.self) { category in
                    let items = uniqueResults.filter { $0.category == category }
                    if !items.isEmpty {
                        categoryGroup(category: category, items: items)
                    }
                }
            }
        }
    }

    private func categoryGroup(category: EntityCategory, items: [DetectedEntity]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            PrivacyCategoryBadge(category: category)
            ForEach(items) { item in
                HStack(spacing: 6) {
                    Text(verbatim: item.original)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9))
                        .foregroundColor(theme.tertiaryText)
                    Text(verbatim: item.placeholder.token)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.accentColor)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsRowCard()
    }

    /// De-duplicate by minted token: the same original appearing twice
    /// in the sample interns to one placeholder, so show it once.
    private var uniqueResults: [DetectedEntity] {
        var seen = Set<String>()
        var out: [DetectedEntity] = []
        for entity in results where seen.insert(entity.placeholder.token).inserted {
            out.append(entity)
        }
        return out
    }

    private var summaryText: String {
        let count = uniqueResults.count
        let format = String(
            localized: "\(count) item(s) would be redacted",
            bundle: .module,
            comment: "Dry-run match count"
        )
        return format
    }

    private func runTest() {
        let text = sample
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isRunning = true
        Task { @MainActor in
            let map = RedactionMap(conversationID: UUID())
            let ruleset = RegexEntityDetector.EffectiveRuleSet.build(from: configuration)
            // Only ask for the model when it's actually loaded so the
            // tester never triggers a 2.8 GB download or throws
            // `.notLoaded`; otherwise preview the regex layer alone.
            let modelLoaded = PrivacyFilterEngine.shared.isLoaded
            let useModel = configuration.aiDetectionEnabled && isModelReady && modelLoaded
            let detected =
                (try? await PrivacyFilterEngine.shared.detect(
                    in: text,
                    map: map,
                    skipCodeBlocks: configuration.skipCodeBlocks,
                    ruleset: ruleset,
                    useModel: useModel
                )) ?? []
            results = detected
            didRun = true
            isRunning = false
        }
    }
}

// MARK: - Card Surface

private extension View {
    /// Canonical Privacy card chrome: the same 10pt rounded
    /// `inputBackground` + 1pt `inputBorder` surface the shared
    /// `SettingsToggle` uses, so every hand-rolled Privacy card matches
    /// the toggles and each other. 12pt inner padding.
    func settingsRowCard() -> some View {
        modifier(PrivacySettingsRowCard())
    }
}

private struct PrivacySettingsRowCard: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )
    }
}

// MARK: - Category Badge

/// Tiny accent pill used in rule rows (preset + custom) and the dry-run
/// tester. Factored out of the old in-line helper so every call site
/// uses the same component without re-passing a theme instance.
private struct PrivacyCategoryBadge: View {
    @Environment(\.theme) private var theme
    let category: EntityCategory

    var body: some View {
        Text(LocalizedStringKey(category.localizationKey), bundle: .module)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundColor(theme.accentColor)
            .background(Capsule().fill(theme.accentColor.opacity(0.12)))
            .overlay(Capsule().stroke(theme.accentColor.opacity(0.25), lineWidth: 0.5))
    }
}

/// `sheet(item:)` requires an `Identifiable` payload — wrap the
/// optional `PrivacyRule` so we can present add (`rule == nil`) and
/// edit (`rule != nil`) modes with one binding. The `id` is a fresh
/// `UUID` per presentation so the sheet animates correctly when
/// editing different rules back-to-back.
private struct CustomRuleEditorContext: Identifiable {
    let id = UUID()
    let rule: PrivacyRule?
}

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        PrivacyView()
    }
#endif
