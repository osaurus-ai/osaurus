//
//  PrivacyView.swift
//  osaurus / PrivacyFilter
//
//  The "Privacy & Security" management tab. The overview lists what
//  Osaurus collects, then drill-ins: Privacy Filter (the redaction filter,
//  per-provider overrides, and the non-interactive review policy under
//  Advanced), Detection Rules (what the matcher looks for), Data & Storage
//  (at-rest encryption, backup and file history, `StorageSettingsView`),
//  and the Permissions child tab.
//
//  The on-device AI model is OPTIONAL: the regex / preset / custom-rule
//  layer works with zero download, so the panel is never gated on the
//  bundle. Installing it lives in Local Models → Privacy Detection, and
//  the AI-detection toggle on Privacy Filter is the only control that
//  needs the bundle (disabled with an Install link until the model
//  verifies).
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
    @ObservedObject private var managementState = ManagementStateManager.shared

    private var theme: any ThemeProtocol { themeManager.currentTheme }

    @State private var configuration: PrivacyFilterConfiguration = PrivacyFilterStore.snapshot()
    @State private var forgetActionMessage: String?
    @State private var customRuleEditorContext: CustomRuleEditorContext?
    @State private var selectedTab: PrivacyTab?

    /// True when the detection model is fully installed + verified.
    /// Gates only the model-dependent affordances: the AI-detection
    /// toggle, the Model tab's installed/empty state, and whether the
    /// dry-run tester may use the model. The tabbed surface itself
    /// always renders since the regex layer needs no bundle.
    private var isModelReady: Bool {
        configuration.resolvedAIBackend(isInstalled: isBackendInstalled) != nil
    }

    /// Install state per backend, read off the observed managers so the
    /// view re-evaluates when a download finishes.
    private func isBackendInstalled(_ backend: PrivacyAIBackend) -> Bool {
        switch backend {
        case .openai:
            if case .ready = downloader.state { return true }
            return false
        case .rampart:
            if case .ready = rampartManager.state { return true }
            return RampartModelManager.bundleExists()
        }
    }

    var body: some View {
        // Never gated on `isModelReady`: the regex / custom-rule layer
        // works without the on-device model.
        SettingsDrillInHost(rootTitle: L("Privacy & Security"), selection: $selectedTab) {
            overview
        } detail: { tab in
            detail(tab)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.canvas)
        .environment(\.theme, theme)
        .onAppear {
            configuration = PrivacyFilterStore.snapshot()
            applySubTabRequest(managementState.privacySubTabRequest)
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
        .onChange(of: managementState.privacySubTabRequest) { _, newValue in
            applySubTabRequest(newValue)
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
            .environment(\.theme, theme)
        }
    }

    private func applySubTabRequest(_ requested: String?) {
        guard let requested else { return }
        managementState.privacySubTabRequest = nil
        switch PrivacyTab.resolved(from: requested) {
        case .model: managementState.openLocalModels(kind: .detection)
        case let tab?: selectedTab = tab
        case nil: break
        }
    }

    // MARK: - Overview

    private var overview: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "Privacy & Security",
                subtitle: "What leaves your Mac, what Osaurus collects, and what agents may do."
            )
        } content: {
            SettingsDrillInList(items: PrivacyTab.drillInItems) { selectedTab = $0 }
            ManagementChildLinks(parent: .privacy)
            PrivacyOverviewTab(
                part: .collection,
                configuration: $configuration,
                save: save,
                saveDebounced: saveDebounced,
                isModelReady: isModelReady,
                providers: providerManager.configuration.providers,
                onOpenModels: {},
                onOpenProviders: {},
                forgetActionMessage: nil,
                forgetAllRedactions: {}
            )
        }
    }

    // MARK: - Drill-in pages

    @ViewBuilder
    private func detail(_ tab: PrivacyTab) -> some View {
        SettingsPage {
            SettingsPageHeader(title: tab.title, subtitle: tab.subtitle)
        } content: {
            switch tab {
            case .overview, .model:
                PrivacyOverviewTab(
                    part: .filter,
                    configuration: $configuration,
                    save: save,
                    saveDebounced: saveDebounced,
                    isModelReady: isModelReady,
                    providers: providerManager.configuration.providers,
                    onOpenModels: { managementState.openLocalModels(kind: .detection) },
                    onOpenProviders: { managementState.selectedTab = .providers },
                    forgetActionMessage: forgetActionMessage,
                    forgetAllRedactions: forgetAllRedactions
                )
            case .storage:
                StorageSettingsView()
            case .rules:
                PrivacyRulesTab(
                    configuration: $configuration,
                    save: save,
                    saveDebounced: saveDebounced,
                    isModelReady: isModelReady,
                    customRuleEditorContext: $customRuleEditorContext,
                    onDeleteCustomRule: deleteCustomRule(id:),
                    onToggleCustomRule: setCustomRuleEnabled(id:enabled:)
                )
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

/// Drill-in pages of Privacy & Security. Raw values are stable deep-link ids
/// (`privacySubTabRequest`, settings-search `subTab`); the visible titles
/// differ, so use `resolved(from:)` for inbound requests. `model` is kept
/// only so older links forward to Local Models → Privacy Detection.
enum PrivacyTab: String, CaseIterable, SettingsDrillInItem {
    /// The redaction filter (per-provider overrides folded in).
    case overview
    case rules
    /// Encryption at rest, backup and key, and file history.
    case storage
    case model

    var id: String { rawValue }

    static let drillInItems: [PrivacyTab] = [.overview, .rules, .storage]

    var title: String {
        switch self {
        case .overview: return L("Privacy Filter")
        case .rules: return L("Detection Rules")
        case .storage: return L("Data & Storage")
        case .model: return L("Detection Models")
        }
    }

    var icon: String {
        switch self {
        case .overview: return "lock.shield.fill"
        case .rules: return "ruler"
        case .storage: return "internaldrive"
        case .model: return "eye.slash"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return L("Scrub personal data before anything goes to a cloud provider.")
        case .rules: return L("Patterns, presets and custom rules the filter looks for.")
        case .storage: return L("How local data is protected on disk, and how long agent file changes stay revertible.")
        case .model: return L("On-device models that power AI detection.")
        }
    }

    /// Accepts the visible titles and the retired `providers` sub-tab (its
    /// toggles now live on Filter).
    static func resolved(from rawValue: String) -> PrivacyTab? {
        if let tab = PrivacyTab(rawValue: rawValue) { return tab }
        switch rawValue.lowercased() {
        case "filter", "privacy filter", "providers", "provider": return .overview
        case "detection rules": return .rules
        case "data & storage", "data", "encryption", "file history": return .storage
        case "models", "detection models": return .model
        default: return nil
        }
    }
}

// MARK: - Overview Tab

/// The "Filter" tab: data-collection consent, the master scrub toggle,
/// the AI-detection layer toggle (with one link to Models), review
/// behaviour, per-provider overrides, the conversation-level Forget
/// Redactions verb, and — under Advanced — the non-interactive review
/// policy. These are the most-touched controls so they live one tap
/// away from the header.
private struct PrivacyOverviewTab: View {
    /// `.collection` = data-collection consent + activity log (the
    /// Privacy & Security overview); `.filter` = the Privacy Filter page.
    enum Part { case collection, filter }

    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    let part: Part
    @Binding var configuration: PrivacyFilterConfiguration
    let save: () -> Void
    /// Provider-toggle writes funnel through here so flipping a handful
    /// of providers in a row doesn't issue a JSON write per toggle.
    let saveDebounced: () -> Void
    /// Whether the on-device detection model is installed + verified.
    /// Gates the AI-detection toggle: AI can't be turned on without
    /// the bundle (an AI-on + no-model state would fail-close every
    /// cloud send), so when this is false we show an install prompt.
    let isModelReady: Bool
    /// Configured remote providers, for the per-provider override rows.
    let providers: [RemoteProvider]
    /// Jump to the Models tab (install a bundle / pick a backend).
    let onOpenModels: () -> Void
    /// Jump to the Providers manager so the user can add one.
    let onOpenProviders: () -> Void
    /// Read-only — the parent owns this `@State` and re-renders the
    /// tab when it changes; the tab never writes back to it.
    let forgetActionMessage: String?
    let forgetAllRedactions: () -> Void

    private static let advancedAnchorIds: Set<String> = ["privacy.filter.nonInteractive"]

    /// Usage-analytics consent. Mirrors `TelemetryService.shared.isEnabled`
    /// (opt-in: true only once granted). Applied immediately on change.
    @State private var telemetryEnabled = false
    /// Crash-reporting consent. Mirrors `CrashReportingService.shared.isEnabled`
    /// (opt-out: defaults on). Applied immediately on change.
    @State private var crashReportingEnabled = true
    /// Persisted activity-log policy (retention + content). Read live from
    /// the Insights facade so the picker reflects what the logger enforces.
    @ObservedObject private var insights = InsightsService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: theme.settingsSectionGap) {
            switch part {
            case .collection:
                dataCollectionSection
                activityLogSection
            case .filter:
                filterSections
            }
        }
        .onAppear {
            telemetryEnabled = TelemetryService.shared.isEnabled
            crashReportingEnabled = CrashReportingService.shared.isEnabled
        }
    }

    @ViewBuilder
    private var filterSections: some View {
            SettingsSection(title: "Filter") {
                SettingsToggle(
                    title: "Scrub Personal Data Before Sending to Cloud Providers",
                    description: L(
                        "Detects PII in your messages and asks you to review before any cloud-bound request. Local models (MLX, Foundation) and on-device tools bypass the filter."
                    ),
                    anchorId: "privacy.filter.enabled",
                    isOn: Binding(
                        get: { configuration.enabled },
                        set: { newValue in
                            configuration.enabled = newValue
                            save()
                        }
                    )
                )

                if configuration.enabled {
                    // Installing a model turns this on by itself
                    // (see `PrivacyFilterStore.enableAIDetectionAfterInstall`),
                    // so the toggle is a deliberate off switch, not
                    // a prerequisite. With nothing installed it is
                    // disabled: AI-on + no-model would fail-close
                    // every cloud send.
                    SettingsToggle(
                        title: "AI Detection (On-Device Model)",
                        description: isModelReady
                            ? L(
                                "Use the installed model to catch names, addresses, and secrets that pattern rules miss. Turns on automatically when you install a model."
                            )
                            : L("Install a model in Local Models → Privacy Detection to turn this on."),
                        anchorId: "privacy.filter.aiDetection",
                        isOn: Binding(
                            get: { configuration.aiDetectionEnabled && isModelReady },
                            set: { newValue in
                                configuration.aiDetectionEnabled = newValue
                                save()
                            }
                        )
                    )
                    .disabled(!isModelReady)
                    .opacity(isModelReady ? 1 : 0.6)

                    SettingsLinkRow(
                        title: "Detection Model",
                        description: isModelReady
                            ? "Choose or update the on-device model that powers AI detection."
                            : "No model installed. Pattern rules still work without one.",
                        icon: "arrow.right",
                        actionTitle: isModelReady ? "Manage" : "Install"
                    ) {
                        onOpenModels()
                    }
                }

                if configuration.enabled && !hasActiveDetector {
                    noDetectorNote
                }

                SettingsToggle(
                    title: "Skip Code Blocks",
                    description: "Don't scan fenced (```) or inline (`) code spans.",
                    anchorId: "privacy.filter.skipCode",
                    isOn: Binding(
                        get: { configuration.skipCodeBlocks },
                        set: { newValue in
                            configuration.skipCodeBlocks = newValue
                            save()
                        }
                    )
                )

                SettingsToggle(
                    title: "Always Approve by Default",
                    description: "Skip the review sheet — still redact, just don't ask each turn.",
                    anchorId: "privacy.filter.alwaysApprove",
                    isOn: Binding(
                        get: { configuration.alwaysApproveByDefault },
                        set: { newValue in
                            configuration.alwaysApproveByDefault = newValue
                            save()
                        }
                    )
                )
            }

            if configuration.enabled {
                SettingsSection(title: "Per-Provider", anchorId: "privacy.filter.providers") {
                    providerOverrides
                }
            }

            SettingsSection(
                title: "Conversation Privacy"
            ) {
                forgetCard
            }

            SettingsAdvancedDisclosure(anchorIds: Self.advancedAnchorIds) {
                SettingsToggle(
                    title: "Require Review for Background Requests",
                    description:
                        "Also hold cloud-bound requests from the HTTP API, schedules, and other non-interactive callers until you review them. Turn off to let those requests auto-approve silently after redaction.",
                    anchorId: "privacy.filter.nonInteractive",
                    isOn: Binding(
                        get: { configuration.requireReviewForNonInteractive },
                        set: { newValue in
                            configuration.requireReviewForNonInteractive = newValue
                            save()
                        }
                    )
                )
            }
    }

    // MARK: - Data collection

    /// Anonymous usage-analytics + crash-reporting consent. Lives at the top
    /// of the Privacy overview so the app's data-collection switches sit with
    /// the rest of the privacy controls. Both apply immediately on change.
    private var dataCollectionSection: some View {
        SettingsSection(title: "Data Collection") {
            SettingsToggle(
                title: "Share Anonymous Usage Data",
                description:
                    "Send anonymous, aggregated usage analytics to help improve Osaurus. Never includes your chats, prompts, files, or keys. Turn off any time.",
                anchorId: "settings.privacy.usage",
                isOn: $telemetryEnabled
            )
            .onChange(of: telemetryEnabled) { _, newValue in
                TelemetryService.shared.setEnabled(newValue)
            }

            SettingsToggle(
                title: "Send Crash Reports",
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

    // MARK: - Activity log

    /// Retention + content policy for the on-device activity log that
    /// Insights reads. Retention changes prune immediately; the content
    /// switch applies to records written from now on (existing rows keep
    /// whatever was stored at the time).
    private var activityLogSection: some View {
        SettingsSection(title: "Activity Log") {
            SettingsPickerRow(
                title: "Keep Activity History",
                description:
                    "How long Insights keeps the record of every model request, web search, URL fetch, MCP call, channel delivery, and Router call made from this Mac. Older records are removed automatically.",
                anchorId: "privacy.activityLog.retention",
                style: .menu,
                selection: Binding(
                    get: { insights.settings.retentionDays ?? 0 },
                    set: { newValue in
                        var next = insights.settings
                        next.retentionDays = newValue == 0 ? nil : newValue
                        insights.updateSettings(next)
                    }
                ),
                options: ActivityLogSettings.retentionChoices.map { days in
                    .init(days ?? 0, ActivityLogSettings.retentionLabel(days))
                }
            )

            SettingsToggle(
                title: "Store Prompts and Responses",
                description:
                    "Keep the full prompt, response, tool arguments, and wire payloads in the activity log so a reviewer can read exactly what was sent. Turn off to keep only metadata (destination, sizes, timing, tokens) for new records.",
                anchorId: "privacy.activityLog.storeContent",
                isOn: Binding(
                    get: { insights.settings.storeContent },
                    set: { newValue in
                        var next = insights.settings
                        next.storeContent = newValue
                        insights.updateSettings(next)
                    }
                )
            )

            SettingsLinkRow(
                title: "Review Activity in Insights",
                description: "Filter, verify the tamper-evident chain, and export the log for outside review.",
                icon: "chart.bar.doc.horizontal",
                actionTitle: "Open Insights",
                anchorId: "privacy.activityLog.openInsights"
            ) {
                ManagementStateManager.shared.selectedTab = .insights
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
        HStack(alignment: .top, spacing: theme.space.s8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .glyphSize(.caption, weight: .semibold)
                .foregroundColor(theme.status.warning.foreground)
            Text(
                "Privacy Filter is on, but no detector is active. Turn on AI detection above, or enable a pattern in Detection Rules — otherwise messages send unredacted.",
                bundle: .module
            )
            .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
            .foregroundColor(theme.text.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Per-provider override toggles. With no remote providers configured,
    /// a single link row points at the Providers manager instead of an
    /// empty list.
    @ViewBuilder
    private var providerOverrides: some View {
        if providers.isEmpty {
            SettingsLinkRow(
                title: "privacy.providers.empty.title",
                description: "privacy.providers.empty.subtitle",
                icon: "cloud.fill",
                actionTitle: "Open Providers"
            ) {
                onOpenProviders()
            }
        } else {
            ForEach(providers) { provider in
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
        }
    }

    private func providerDescription(_ provider: RemoteProvider) -> String {
        let host = provider.host.isEmpty ? provider.providerType.rawValue : provider.host
        return String(format: L("privacy.providers.row.subtitle %@"), host)
    }

    private var forgetCard: some View {
        SettingsRow(
            title: "Forget Redactions in Every Conversation",
            // `forgetActionMessage` is already localized by the parent.
            description: forgetActionMessage
                ?? L("Clear every interned placeholder for every open conversation. Future sends mint fresh placeholders."),
            anchorId: "privacy.filter.forget"
        ) {
            SettingsButton(.secondary, "Forget", size: .compact, action: forgetAllRedactions)
        }
    }
}

// MARK: - Rules Tab

/// Detection patterns + preset rules + custom rules. Keeps all the
/// "what does the matcher look for" controls in one place so users
/// don't have to hop between sub-tabs to enable a preset and then
/// add a custom regex.
private struct PrivacyRulesTab: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
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
    @Binding var customRuleEditorContext: CustomRuleEditorContext?
    let onDeleteCustomRule: (UUID) -> Void
    let onToggleCustomRule: (UUID, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: theme.settingsSectionGap) {
            detectionPatternsSection
            PrivacyRegionsSection(configuration: $configuration, save: save)
            PrivacyPresetRulesSection(configuration: $configuration, saveDebounced: saveDebounced)
            customRulesSection
            PrivacyDryRunTester(configuration: configuration, isModelReady: isModelReady)
        }
    }

    // MARK: Detection patterns

    private var detectionPatternsSection: some View {
        SettingsSection(title: "Detection Patterns", anchorId: "privacy.rules.detectionPatterns") {
            VStack(alignment: .leading, spacing: theme.space.s8) {
                Text(
                    "Built-in deterministic detectors run alongside the on-device model. Turning a category off stops Osaurus from flagging it AND from blocking sends when it leaks past redaction.",
                    bundle: .module
                )
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, theme.space.s4)

                builtinPatternToggle(
                    category: .phone,
                    title: L("Phone Numbers"),
                    description: L(
                        "International phone numbers: +country-code, national 0-prefixed, and North American formats."
                    )
                )
                builtinPatternToggle(
                    category: .email,
                    title: L("Email Addresses"),
                    description: L("Standard local@domain.tld addresses.")
                )
                builtinPatternToggle(
                    category: .url,
                    title: L("URLs"),
                    description: L("http(s) URLs that include a scheme.")
                )
                builtinPatternToggle(
                    category: .accountNumber,
                    title: L("Account Numbers"),
                    description: L(
                        "Luhn-valid credit and debit card numbers. National ID numbers are in Preset Rules."
                    )
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

    // MARK: Custom rules

    private var customRulesSection: some View {
        SettingsSection(title: "Custom Rules", anchorId: "privacy.rules.custom") {
            VStack(alignment: .leading, spacing: theme.space.s8) {
                Text(
                    "Catch internal codenames, customer IDs, or anything the built-ins miss. Build a rule with no regex, or write your own pattern.",
                    bundle: .module
                )
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)

                if configuration.customRules.isEmpty {
                    HStack {
                        Text("No custom rules yet.", bundle: .module)
                            .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                            .foregroundColor(theme.text.tertiary)
                        Spacer()
                        addCustomRuleButton
                    }
                    .settingsRowChrome()
                } else {
                    VStack(spacing: theme.space.s8) {
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
        SettingsButton(.primary, "Add rule", icon: "plus") {
            customRuleEditorContext = CustomRuleEditorContext(rule: nil)
        }
    }

    private func customRuleRow(_ rule: PrivacyRule) -> some View {
        HStack(alignment: .top, spacing: theme.space.s12) {
            VStack(alignment: .leading, spacing: theme.space.s4) {
                HStack(spacing: theme.space.s8) {
                    Text(verbatim: rule.name)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)
                    PrivacyCategoryBadge(category: rule.category)
                }
                Text(verbatim: rule.pattern)
                    .catalogTypography(.code, theme: theme, fallback: SettingsFont.monoSmall)
                    .foregroundColor(theme.text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            HStack(spacing: theme.space.s6) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { rule.enabled },
                        set: { newValue in
                            onToggleCustomRule(rule.id, newValue)
                        }
                    )
                )
                .settingsSwitch()
                .accessibilityLabel(Text(verbatim: rule.name))

                SettingsIconButton("pencil", help: "Edit this rule.", size: .compact) {
                    customRuleEditorContext = CustomRuleEditorContext(rule: rule)
                }

                SettingsIconButton("trash", help: "Delete this rule.", size: .compact, isDestructive: true) {
                    onDeleteCustomRule(rule.id)
                }
            }
        }
        .settingsRowChrome()
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
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    let configuration: PrivacyFilterConfiguration
    let isModelReady: Bool

    @State private var sample: String = ""
    @State private var results: [DetectedEntity] = []
    @State private var didRun: Bool = false
    @State private var isRunning: Bool = false

    var body: some View {
        SettingsSection(title: "Test Your Rules", anchorId: "privacy.rules.test") {
            VStack(alignment: .leading, spacing: theme.space.s8) {
                Text(
                    "Paste sample text to preview exactly what Osaurus would redact with your current rules — before anything reaches a provider.",
                    bundle: .module
                )
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)

                SettingsTextField(
                    placeholder: L("Paste text to test…"),
                    text: $sample,
                    axis: .vertical,
                    lineLimit: 8,
                    monospaced: true
                )

                HStack(spacing: theme.space.s8) {
                    SettingsButton(.primary, "Run test", isLoading: isRunning, action: runTest)
                    .disabled(sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRunning)

                    Spacer()
                    Text(verbatim: layerNote)
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                        .foregroundColor(theme.text.tertiary)
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
        Divider().padding(.vertical, theme.space.s2)
        if results.isEmpty {
            HStack(spacing: theme.space.s6) {
                Image(systemName: "checkmark.circle")
                    .foregroundColor(theme.text.tertiary)
                Text("No matches — nothing would be redacted.", bundle: .module)
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                    .foregroundColor(theme.text.tertiary)
            }
        } else {
            VStack(alignment: .leading, spacing: theme.space.s8) {
                Text(verbatim: summaryText)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                    .foregroundColor(theme.text.secondary)
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
        VStack(alignment: .leading, spacing: theme.space.s4) {
            PrivacyCategoryBadge(category: category)
            ForEach(items) { item in
                HStack(spacing: theme.space.s6) {
                    Text(verbatim: item.original)
                        .catalogTypography(.code, theme: theme, fallback: SettingsFont.monoSmall)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "arrow.right")
                        .glyphSize(.tiny)
                        .foregroundColor(theme.text.tertiary)
                    Text(verbatim: item.placeholder.token)
                        .catalogTypography(.code, theme: theme, fallback: SettingsFont.monoSmall)
                        .foregroundColor(theme.text.link)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsRowChrome()
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
        return count == 1
            ? L("1 item would be redacted", comment: "Dry-run match count")
            : L("\(count) items would be redacted", comment: "Dry-run match count")
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

// MARK: - Category Badge

/// Tiny accent pill used in rule rows (preset + custom) and the dry-run
/// tester. Factored out of the old in-line helper so every call site
/// uses the same component without re-passing a theme instance.
struct PrivacyCategoryBadge: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    let category: EntityCategory

    var body: some View {
        StatusChip(
            String(localized: String.LocalizationValue(category.localizationKey), bundle: .module),
            tone: .accent
        )
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
