//
//  PrivacyView.swift
//  osaurus / PrivacyFilter
//
//  Top-level "Privacy" management tab. Two visual modes, switched on
//  `PrivacyFilterModelDownloader.shared.state`:
//
//    • Pre-install: a full-viewport hero (`PrivacyInstallHero`) styled
//      like `SettingsEmptyState` so the empty/onboarding language
//      matches the rest of the app (Schedules, Watchers, Skills).
//      Sub-tabs are deliberately NOT rendered yet — the settings are
//      meaningless without a working classifier and would clutter the
//      install path.
//    • Post-install: `ManagerHeaderWithTabs` + four sub-tabs
//      (Overview / Rules / Providers / Model) so the surface scans
//      like Server and Voice instead of a 7-card scroll.
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
    /// Drives the entire view's mode switch — pre-install gets the
    /// install hero; post-install gets the tabbed settings surface.
    private var isModelReady: Bool {
        if case .ready = downloader.state { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            if isModelReady {
                ScrollView {
                    selectedTabContent
                        .padding(.horizontal, 24)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                .opacity(hasAppeared ? 1 : 0)
            } else {
                PrivacyInstallHero(
                    state: downloader.state,
                    hasAppeared: hasAppeared,
                    onPrimary: { handlePrimaryInstallAction() },
                    onCancel: { downloader.cancel() }
                )
            }
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

    /// Two-shape header: pre-install uses the simpler title + subtitle
    /// (no actions, no tabs); post-install promotes to the tabbed
    /// header so users can jump between Overview/Rules/Providers/Model
    /// without scrolling.
    @ViewBuilder
    private var headerView: some View {
        if isModelReady {
            ManagerHeaderWithTabs(
                title: L("Privacy"),
                subtitle: L("Redact sensitive content before it leaves your Mac, then restore it on responses.")
            ) {
                EmptyView()
            } tabsRow: {
                HeaderTabsRow(selection: $selectedTab)
            }
        } else {
            ManagerHeader(
                title: L("Privacy"),
                subtitle: L("Redact sensitive content before it leaves your Mac, then restore it on responses.")
            )
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
                forgetActionMessage: forgetActionMessage,
                forgetAllRedactions: forgetAllRedactions
            )
        case .rules:
            PrivacyRulesTab(
                configuration: $configuration,
                save: save,
                saveDebounced: saveDebounced,
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
                saveDebounced: saveDebounced
            )
        case .model:
            PrivacyModelTab(
                onReverify: downloader.reverify,
                onRemove: downloader.remove
            )
        }
    }

    // MARK: - Install action routing

    /// `.idle`/`.failed` -> kick off download. The progress states are
    /// the only ones that show a Cancel button, which uses a different
    /// closure on `PrivacyInstallHero` so the hero stays purely
    /// presentational.
    private func handlePrimaryInstallAction() {
        switch downloader.state {
        case .idle, .failed:
            downloader.startDownload()
        case .enumerating, .downloading, .verifying, .ready:
            break
        }
    }

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

/// The four sub-sections shown post-install. Providers stays in the
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
        case .model: return L("Model")
        }
    }
}

// MARK: - Install Hero (pre-install empty state)

/// Centered hero matching `SettingsEmptyState` visual weight: 88pt
/// glowing accent circle, 22pt rounded bold title, 14pt secondary
/// subtitle, 3 benefit bullets, prominent CTA. The download state
/// machine (idle → enumerating → downloading → verifying → ready /
/// failed) is folded INTO the same hero rather than swapping cards,
/// so the user never sees layout jank as install progresses.
private struct PrivacyInstallHero: View {
    @Environment(\.theme) private var theme
    let state: PrivacyFilterDownloadState
    let hasAppeared: Bool
    let onPrimary: () -> Void
    let onCancel: () -> Void

    @State private var glowIntensity: CGFloat = 0.6

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            glowingIcon
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.85)
                .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.1), value: hasAppeared)

            VStack(spacing: 8) {
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(theme.primaryText)
                    .multilineTextAlignment(.center)

                Text(LocalizedStringKey(subtitle), bundle: .module)
                    .font(.system(size: 14))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 540)
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 15)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2), value: hasAppeared)

            benefitsRow
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 20)
                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.3), value: hasAppeared)

            VStack(spacing: 12) {
                primaryAction
                progressRow
                footnote
            }
            .frame(maxWidth: 540)
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 10)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.4), value: hasAppeared)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
        .onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                glowIntensity = 1.0
            }
        }
    }

    // MARK: - Hero parts

    private var glowingIcon: some View {
        ZStack {
            Circle()
                .fill(accentColor)
                .frame(width: 88, height: 88)
                .blur(radius: 25)
                .opacity(glowIntensity * 0.25)

            Circle()
                .fill(accentColor)
                .frame(width: 88, height: 88)
                .blur(radius: 12)
                .opacity(glowIntensity * 0.15)

            Circle()
                .fill(
                    LinearGradient(
                        colors: [accentColor.opacity(0.18), accentColor.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 88, height: 88)

            Image(systemName: icon)
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(
                    LinearGradient(
                        colors: [accentColor, accentColor.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }

    private var benefitsRow: some View {
        HStack(spacing: 12) {
            benefitCard(
                icon: "wand.and.stars",
                title: L("On-device detection"),
                description: L("Runs locally — none of your text touches an external model.")
            )
            benefitCard(
                icon: "checkmark.shield",
                title: L("Review redactions"),
                description: L("Approve every match before sending, or auto-approve once you trust the picks.")
            )
            benefitCard(
                icon: "arrow.uturn.backward.circle",
                title: L("Live unscrub"),
                description: L("Streaming replies are restored on the fly so chat reads naturally.")
            )
        }
        .frame(maxWidth: 660)
    }

    private func benefitCard(icon: String, title: String, description: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(theme.accentColor)
                .frame(width: 36, height: 36)
                .background(Circle().fill(theme.accentColor.opacity(0.1)))

            VStack(spacing: 4) {
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(LocalizedStringKey(description), bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.secondaryBackground.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.cardBorder.opacity(0.5), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch state {
        case .idle:
            actionButton(title: L("Install"), icon: "arrow.down.circle.fill", primary: true, action: onPrimary)
        case .failed:
            actionButton(title: L("Retry"), icon: "arrow.clockwise", primary: true, action: onPrimary)
        case .enumerating, .downloading, .verifying:
            actionButton(title: L("Cancel"), icon: "xmark", primary: false, action: onCancel)
        case .ready:
            EmptyView()
        }
    }

    private func actionButton(title: String, icon: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
            } icon: {
                Image(systemName: icon)
            }
            .foregroundColor(primary ? .white : theme.primaryText)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(primary ? theme.accentColor : theme.tertiaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(primary ? Color.clear : theme.inputBorder, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    @ViewBuilder
    private var progressRow: some View {
        switch state {
        case .downloading(let index, let count, let fileName, let downloaded, let total):
            VStack(alignment: .leading, spacing: 6) {
                let fraction: Double = total > 0 ? Double(downloaded) / Double(total) : 0
                ProgressView(value: fraction, total: 1.0)
                    .progressViewStyle(.linear)
                    .tint(theme.accentColor)
                HStack {
                    Text(verbatim: "\(fileName)  (\(index + 1)/\(count))")
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(verbatim: "\(formatBytes(downloaded)) / \(formatBytes(total))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                }
            }
        case .enumerating, .verifying:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(LocalizedStringKey(subtitle), bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
        case .idle, .failed, .ready:
            EmptyView()
        }
    }

    @ViewBuilder
    private var footnote: some View {
        if case .failed(let detail) = state {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.warningColor)
                Text(verbatim: detail)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if case .idle = state {
            footnoteRow(
                icon: "info.circle",
                text: L(
                    "About 2.8 GB. The detection model runs entirely on your Mac — no third-party traffic for detection."
                )
            )
        } else if case .downloading = state {
            footnoteRow(
                icon: "info.circle",
                text: L("The model is large; keep this window open while it downloads.")
            )
        }
    }

    private func footnoteRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
            Text(LocalizedStringKey(text), bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - State derivations

    private var icon: String {
        switch state {
        case .idle: return "hand.raised.fill"
        case .enumerating, .downloading, .verifying: return "arrow.down.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .ready: return "checkmark.seal.fill"
        }
    }

    private var accentColor: Color {
        switch state {
        case .failed: return theme.warningColor
        case .ready: return theme.successColor
        default: return theme.accentColor
        }
    }

    private var title: String {
        switch state {
        case .idle: return "privacy.install.title"
        case .enumerating: return "privacy.install.title.enumerating"
        case .downloading: return "privacy.install.title.downloading"
        case .verifying: return "privacy.install.title.verifying"
        case .failed: return "privacy.install.title.failed"
        case .ready: return "privacy.install.title.ready"
        }
    }

    private var subtitle: String {
        switch state {
        case .idle: return "privacy.install.subtitle"
        case .enumerating: return "privacy.install.subtitle.enumerating"
        case .downloading: return "privacy.install.subtitle.downloading"
        case .verifying: return "privacy.install.subtitle.verifying"
        case .failed: return "privacy.install.subtitle.failed"
        case .ready: return "privacy.install.subtitle.ready"
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Overview Tab

/// The "what does the filter actually do" tab: master enable toggle,
/// review behavior (always-approve / skip code), confidence threshold,
/// and the conversation-level Forget Redactions verb. These are the
/// most-touched controls so they live one tap away from the header.
private struct PrivacyOverviewTab: View {
    @Environment(\.theme) private var theme
    @Binding var configuration: PrivacyFilterConfiguration
    let save: () -> Void
    /// Read-only — the parent owns this `@State` and re-renders the
    /// tab when it changes; the tab never writes back to it.
    let forgetActionMessage: String?
    let forgetAllRedactions: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSection(title: L("Filter"), icon: "lock.shield.fill") {
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

                // Intentionally hidden until the underlying classifier
                // exposes a threshold knob. `confidenceThreshold` is
                // persisted (so a future build can round-trip the
                // user's choice without a migration) but
                // `PrivacyFilterEngine.detect` doesn't read it today,
                // so surfacing a slider that does nothing is worse
                // than not surfacing it at all.
            }

            SettingsSection(
                title: L("Conversation Privacy"),
                icon: "person.crop.circle.fill.badge.minus"
            ) {
                forgetCard
            }
        }
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
                .buttonStyle(.bordered)
                Spacer()
                if let message = forgetActionMessage {
                    Text(LocalizedStringKey(message), bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.successColor)
                }
            }
        }
        .padding(14)
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
    @Binding var presetsExpanded: Bool
    @Binding var customRuleEditorContext: CustomRuleEditorContext?
    let onDeleteCustomRule: (UUID) -> Void
    let onToggleCustomRule: (UUID, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            detectionPatternsSection
            presetRulesSection
            customRulesSection
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
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
        )
    }

    private func presetTitleKey(_ id: String) -> String { "privacy.presets.\(id).title" }
    private func presetDescriptionKey(_ id: String) -> String { "privacy.presets.\(id).description" }

    // MARK: Custom rules

    private var customRulesSection: some View {
        SettingsSection(title: L("Custom Rules"), icon: "wand.and.rays") {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "Define your own regex patterns — internal codenames, customer IDs, anything Osaurus's built-ins don't cover. Bad patterns are validated before save.",
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
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.inputBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(theme.inputBorder, lineWidth: 1)
                            )
                    )
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
        .buttonStyle(.borderedProminent)
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

                Button {
                    customRuleEditorContext = CustomRuleEditorContext(rule: rule)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .localizedHelp("Edit this rule.")

                Button(role: .destructive) {
                    onDeleteCustomRule(rule.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .localizedHelp("Delete this rule.")
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
        )
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
        VStack(spacing: 16) {
            Spacer().frame(height: 40)
            ZStack {
                Circle()
                    .fill(theme.accentColor.opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: "cloud.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundColor(theme.accentColor)
            }
            VStack(spacing: 6) {
                Text("privacy.providers.empty.title", bundle: .module)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundColor(theme.primaryText)
                Text("privacy.providers.empty.subtitle", bundle: .module)
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 420)
            Spacer().frame(height: 40)
        }
        .frame(maxWidth: .infinity)
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

// MARK: - Model Tab

/// Where the detection model lives. The Re-verify button used to be
/// duplicated in the header too; consolidating it here means the
/// destructive-leaning action (re-runs SHA-256 on the entire ~2.8GB
/// bundle) is one click away but never accidentally triggered while
/// the user is reaching for the header.
private struct PrivacyModelTab: View {
    @Environment(\.theme) private var theme
    let onReverify: () -> Void
    let onRemove: () -> Void

    @State private var showRemoveConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSection(title: L("Detection Model"), icon: "cube.box.fill") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.successColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Model installed", bundle: .module)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                            Text(verbatim: "\(PrivacyFilterModelBundle.version) — verified on disk.")
                                .font(.system(size: 11))
                                .foregroundColor(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button(action: onReverify) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                Text("Re-verify", bundle: .module)
                            }
                        }
                        .buttonStyle(.bordered)
                        .localizedHelp("Re-run the model bundle SHA-256 verification.")

                        // Destructive action lives in the same row as
                        // Re-verify so the user can audit the bundle
                        // (re-verify) or wipe it (remove) without
                        // hunting through a separate "danger zone"
                        // panel. The confirmation alert protects the
                        // ~2.8GB redownload the next install would
                        // need.
                        Button(role: .destructive) {
                            showRemoveConfirmation = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "trash")
                                Text("Remove", bundle: .module)
                            }
                        }
                        .buttonStyle(.bordered)
                        .localizedHelp(
                            "Delete the on-disk model bundle. You'll need to re-download it from the Install button to use the Privacy Filter again."
                        )
                    }
                }
                .padding(14)
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
        .confirmationDialog(
            Text("Remove Privacy Filter model?", bundle: .module),
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                onRemove()
            } label: {
                Text("Remove Bundle", bundle: .module)
            }
            Button(role: .cancel) {
            } label: {
                Text("Cancel", bundle: .module)
            }
        } message: {
            Text(
                "This deletes the on-disk model (~2.8 GB). The Privacy Filter stops detecting until you re-download it.",
                bundle: .module
            )
        }
    }
}

// MARK: - Category Badge

/// Tiny accent pill used in rule rows (preset + custom). Factored out
/// of the old in-line helper so both `PrivacyRulesTab.presetRow` and
/// `customRuleRow` use the same component without re-passing a theme
/// instance.
private struct PrivacyCategoryBadge: View {
    @Environment(\.theme) private var theme
    let category: EntityCategory

    var body: some View {
        Text(LocalizedStringKey(key), bundle: .module)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundColor(theme.accentColor)
            .background(Capsule().fill(theme.accentColor.opacity(0.12)))
    }

    private var key: String {
        switch category {
        case .accountNumber: return "privacy.category.accountNumber"
        case .address: return "privacy.category.address"
        case .email: return "privacy.category.email"
        case .person: return "privacy.category.person"
        case .phone: return "privacy.category.phone"
        case .url: return "privacy.category.url"
        case .date: return "privacy.category.date"
        case .secret: return "privacy.category.secret"
        }
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
