//
//  ConfigurationView.swift
//  osaurus
//
//  The "General" sidebar tab: how the app looks (Appearance), how it starts
//  (Startup), whether it stays awake for agents (Power), Updates,
//  Notifications, Legal links, and Factory Reset as the very last thing on
//  the page. It is about the app, not the models.
//
//  Elsewhere: the models folder and models already on this Mac → Local
//  Models → Sources; encryption, backup and file history → Privacy &
//  Security → Data & Storage; the Command Line Tool installer → Developer
//  Tools → Server → Overview.
//

import AppKit
import SwiftUI

// MARK: - Configuration View
struct ConfigurationView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var onboardingService = OnboardingService.shared
    @ObservedObject private var taskManager = BackgroundTaskManager.shared
    @EnvironmentObject private var updater: UpdaterViewModel
    @EnvironmentObject private var server: ServerController

    /// Use computed property to always get the current theme from ThemeManager
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var tempStartAtLogin: Bool = false
    @State private var tempHideDockIcon: Bool = false
    @State private var isResetting = false

    // General settings state. The chat-mode generation knobs live on Chat,
    // folder tool-permission policies on Tools, and the Core Model on Model
    // Defaults; the global hotkey stays here.
    @State private var tempChatHotkey: Hotkey? = nil

    /// Prevent idle system sleep while agent sessions are actively running
    /// or queued. Display sleep and explicit system sleep remain available.
    @AppStorage(AgentRunPowerManager.keepAwakeDefaultsKey)
    private var keepMacAwakeForAgentRuns: Bool = true

    // Notifications. The toast master switch, then where each kind of
    // request reaches you (`NotificationPreferences`). Toast position,
    // timeout and stack size keep their `ToastConfiguration` defaults
    // (opinionated, not exposed).
    @State private var tempToastEnabled: Bool = true
    @State private var notificationPrefs = NotificationPreferencesStore.snapshot()

    /// Baseline of the save-relevant fields as last loaded or saved. The
    /// debounced auto-save is gated on the live form differing from this, so a
    /// pristine settings screen never writes to disk. Fields applied
    /// immediately on change (external models, toasts, beta channel) are
    /// deliberately excluded — they never flow through `saveConfiguration`.
    @State private var savedFormState: SaveableFormState?

    /// Debounced auto-save. Save-relevant edits persist ~0.6s after the user
    /// stops, so there's no explicit "Save Changes" button. `autoSaveTask` is
    /// the pending debounce that each new edit cancels and reschedules.
    @State private var autoSaveTask: Task<Void, Never>?

    /// Last-loaded/saved full `ServerConfiguration`, kept so `saveConfiguration`
    /// can preserve the server fields this screen doesn't edit without a
    /// synchronous `ServerConfigurationStore.load()` disk read on the main
    /// thread each (auto-)save.
    @State private var loadedServerConfig: ServerConfiguration = .default

    var body: some View {
        ZStack {
            SettingsPage {
                headerView
            } content: {
                appearanceSection
                startupSection
                powerSection
                updatesSection
                notificationsSection
                legalSection
                factoryResetSection
            }

            // Factory reset loading overlay
            if isResetting {
                factoryResetOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.canvas)
        // Wipe-failure notice: `.contained` so it layers above the reset
        // overlay in this view rather than routing to the window host. The
        // binding's setter fires on dismiss and resumes `performFactoryReset`,
        // which then terminates the app.
        .themedAlert(
            "Factory Reset Incomplete",
            isPresented: Binding(
                get: { onboardingService.wipeFailureMessage != nil },
                set: { if !$0 { OnboardingService.shared.acknowledgeWipeFailure() } }
            ),
            message: onboardingService.wipeFailureMessage,
            buttons: [.destructive(L("Quit")) {}],
            presentationStyle: .contained
        )
        .environment(\.theme, themeManager.currentTheme)
        .onAppear { loadConfiguration() }
        // Any edit to a save-relevant field reschedules the debounced save.
        // `currentFormState` is the same snapshot the dirty check uses, so
        // immediately-applied toggles (toasts, external models, …) don't
        // trigger it.
        .onChange(of: currentFormState) { _, _ in scheduleAutoSave() }
        // `osaurus_config` can change the hotkey, login item, or notifications
        // while this page is open; a pending edit here still wins.
        .onReceive(NotificationCenter.default.publisher(for: .appConfigurationChanged)) { _ in
            if !hasUnsavedChanges { loadConfiguration() }
        }
        // Persist a pending edit if the user leaves before the debounce fires.
        .onDisappear { flushPendingSave() }
        .onChange(of: keepMacAwakeForAgentRuns) { _, _ in
            taskManager.refreshPowerAssertion()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        SettingsPageHeader(
            title: "General",
            subtitle: "Appearance, startup, power, updates and notifications"
        )
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        SettingsSection(title: "Appearance") {
            SettingsPickerRow(
                title: "Appearance",
                description: "System follows your Mac's light and dark setting",
                anchorId: "settings.general.appearance",
                selection: Binding(
                    get: { themeManager.appearanceMode },
                    set: { themeManager.setAppearanceMode($0) }
                ),
                options: AppearanceMode.allCases.map { .init($0, $0.displayName, verbatim: true) }
            )

            SettingsPickerRow(
                title: "Text Size",
                description: "Scales text in every window. View → Zoom In and Zoom Out change it too.",
                anchorId: "settings.general.textSize",
                style: .menu,
                selection: Binding(
                    get: { Self.textSizePercent(ThemeManager.fontScale) },
                    set: { themeManager.setFontScale(Double($0) / 100) }
                ),
                options: Self.textSizePercents.map {
                    .init($0, $0 == 100 ? "\($0)% (\(L("Default")))" : "\($0)%", verbatim: true)
                }
            )
        }
    }

    /// Every zoom step `ThemeManager` can land on, as whole percents.
    private static let textSizePercents: [Int] = {
        let range = ServerConfiguration.fontSizeMultiplierRange
        let step = Int((ThemeManager.fontScaleStep * 100).rounded())
        return Array(stride(
            from: Int((range.lowerBound * 100).rounded()),
            through: Int((range.upperBound * 100).rounded()),
            by: step
        ))
    }()

    private static func textSizePercent(_ scale: Double) -> Int {
        Int((scale * 100).rounded())
    }

    // MARK: - Startup

    private var startupSection: some View {
        SettingsSection(title: "Startup") {
            SettingsRow(title: "Global Hotkey", description: "Open Osaurus from anywhere", anchorId: "settings.general.hotkey") {
                HotkeyRecorder(value: $tempChatHotkey)
            }

            SettingsToggle(
                title: "Start at Login",
                description: "Launch Osaurus when you sign in",
                anchorId: "settings.general.login",
                isOn: $tempStartAtLogin
            )

            SettingsToggle(
                title: "Hide Dock Icon",
                description: "Run in menu bar only (requires restart)",
                anchorId: "settings.general.dock",
                isOn: $tempHideDockIcon
            )
        }
    }

    // MARK: - Power

    private var powerSection: some View {
        SettingsSection(title: "Power") {
            SettingsToggle(
                title: "Keep Mac Awake While Agents Run",
                description:
                    "Prevent idle sleep while agents are running or queued so long tasks can finish. The display may still sleep; closing the lid or choosing Sleep always wins.",
                anchorId: "settings.chat.keepAwakeForAgentRuns",
                isOn: $keepMacAwakeForAgentRuns
            )

            if keepMacAwakeForAgentRuns {
                HStack(spacing: theme.space.s8) {
                    Image(
                        systemName: taskManager.isPreventingIdleSystemSleep
                            ? "bolt.fill"
                            : "moon.stars.fill"
                    )
                    .textStyle(.footnote, weight: 600)
                    .foregroundColor(
                        taskManager.isPreventingIdleSystemSleep
                            ? theme.status.info.foreground
                            : theme.text.tertiary
                    )

                    Text(
                        taskManager.isPreventingIdleSystemSleep
                            ? L("Keeping this Mac awake while agents work")
                            : L("Ready — activates automatically with the next agent run")
                    )
                    .textStyle(.footnote, weight: 500)
                    .foregroundColor(theme.text.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Updates

    private var updatesSection: some View {
        SettingsSection(title: "Updates") {
            SettingsToggle(
                title: "Beta Updates",
                description: "Receive pre-release updates with new features before they're generally available",
                anchorId: "settings.general.updates",
                isOn: $updater.isBetaChannel
            )
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        SettingsSection(title: "Notifications") {
            SettingsToggle(
                title: "Show Notifications",
                description: "Every toast in the app: background tasks, events and requests that need you",
                anchorId: "settings.notifications.toasts",
                isOn: $tempToastEnabled
            )
            .onChange(of: tempToastEnabled) { _, _ in saveToastConfig() }
            ForEach(NotificationCategory.allCases, id: \.self) { category in
                NotificationRouteRow(
                    category: category,
                    prefs: $notificationPrefs,
                    appNotificationsOn: tempToastEnabled
                )
            }
            SettingsToggle(
                title: "Desktop Notifications Only in the Background",
                description: "While you're using Osaurus, its own cards and toasts show what's needed",
                anchorId: "settings.notifications.desktopWhenInactive",
                isOn: Binding(
                    get: { notificationPrefs.desktopOnlyWhenInactive },
                    set: {
                        notificationPrefs.desktopOnlyWhenInactive = $0
                        NotificationPreferencesStore.save(notificationPrefs)
                    }
                )
            )
        }
    }

    // MARK: - Legal

    private var legalSection: some View {
        SettingsSection(title: "Legal", anchorId: "settings.legal") {
            SettingsLinkRow(title: "Terms of Service", actionTitle: "View") {
                NSWorkspace.shared.open(OsaurusWebLinks.terms)
            }
            SettingsLinkRow(title: "Privacy Policy", actionTitle: "View") {
                NSWorkspace.shared.open(OsaurusWebLinks.privacy)
            }
        }
    }

    // MARK: - Factory Reset

    private var factoryResetSection: some View {
        SettingsDestructiveZone(anchorId: "settings.general.reset") {
            SettingsDestructiveRow(
                title: "Factory Reset",
                description:
                    "Permanently deletes all data and settings — chat history, agents, memory, and your identity keys — then quits Osaurus. This cannot be undone.",
                actionTitle: "Factory reset…"
            ) {
                showFactoryResetConfirmation()
            }
        }
    }

    private var factoryResetOverlay: some View {
        ZStack {
            Rectangle()
                .fill(theme.scrim)
                .ignoresSafeArea()

            VStack(spacing: theme.space.s24) {
                VStack(spacing: theme.space.s8) {
                    Text("Resetting Osaurus", bundle: .module)
                        .font(SettingsFont.detailTitle)
                        .foregroundColor(theme.text.primary)

                    Text("Deleting data and preferences. Please wait…", bundle: .module)
                        .font(SettingsFont.body)
                        .foregroundColor(theme.text.secondary)
                }

                if let journey = onboardingService.resetJourney {
                    VStack(alignment: .leading, spacing: theme.space.s10) {
                        ForEach(journey.steps) { step in
                            FactoryResetStepRow(step: step)
                        }
                    }
                    .frame(width: 260)
                    .padding(theme.space.s12)
                    .settingsChrome(.inset)
                    .animation(theme.motion.quick, value: journey)
                } else {
                    SettingsSpinner(size: .large, tint: theme.action.primary.default.background)
                }
            }
            .padding(theme.space.s40)
            .settingsChrome(.overlay)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
        .zIndex(100)
    }

    // MARK: - Auto-Save

    /// Reschedule the debounced save. No-op while the form matches the saved
    /// baseline — so loading the tab (which sets `temp*` then re-baselines)
    /// and immediately-applied toggles never trigger a write.
    private func scheduleAutoSave() {
        guard hasUnsavedChanges else { return }
        autoSaveTask?.cancel()
        autoSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, hasUnsavedChanges else { return }
            saveConfiguration()
        }
    }

    /// Cancel any pending debounce and save right now if the form is dirty.
    /// Called on disappear so a half-typed change isn't lost when the window
    /// closes before the 0.6s debounce elapses.
    private func flushPendingSave() {
        autoSaveTask?.cancel()
        autoSaveTask = nil
        if hasUnsavedChanges { saveConfiguration() }
    }

    // MARK: - Configuration Loading

    /// Wrapper so we can hand a single immutable snapshot back to
    /// MainActor instead of several typed return values. `Sendable` is
    /// required for `Task.detached`.
    private struct ConfigurationSnapshot: Sendable {
        let server: ServerConfiguration
        let chat: ChatConfiguration
        let toast: ToastConfiguration
    }

    /// Asynchronous loader. Moves the JSON+disk reads off the post-appear
    /// frame so the tab paints its shell first (see the detached task); the
    /// result is applied in a single MainActor batch via
    /// `applyLoadedConfiguration(_:)`.
    private func loadConfiguration() {
        Task { @MainActor in
            await Task.yield()

            let snapshot: ConfigurationSnapshot = await Task.detached(priority: .userInitiated) {
                async let server: ServerConfiguration = MainActor.run {
                    ServerConfigurationStore.load() ?? ServerConfiguration.default
                }
                async let chat: ChatConfiguration = MainActor.run {
                    ChatConfigurationStore.load()
                }
                let toast = ToastConfigurationStore.load()
                return await ConfigurationSnapshot(
                    server: server,
                    chat: chat,
                    toast: toast
                )
            }.value

            applyLoadedConfiguration(snapshot)
        }
    }

    private func applyLoadedConfiguration(_ snapshot: ConfigurationSnapshot) {
        let configuration = snapshot.server
        loadedServerConfig = configuration
        tempStartAtLogin = configuration.startAtLogin
        tempHideDockIcon = configuration.hideDockIcon

        let chat = snapshot.chat
        tempChatHotkey = chat.hotkey

        let toastConfig = snapshot.toast
        tempToastEnabled = toastConfig.enabled

        // Capture the pristine baseline so the auto-save stays idle until the
        // user actually edits something.
        savedFormState = currentFormState
    }

    // MARK: - Factory Reset

    private func showFactoryResetConfirmation() {
        let alert = NSAlert()
        alert.messageText = L("Factory Reset Osaurus?")
        alert.informativeText =
            L(
                "This will permanently delete all your data, including chat history, agents, memory, and your identity keys. This action cannot be undone and the application will close."
            )
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Factory Reset")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            Task { @MainActor in
                withAnimation(theme.motion.standard) {
                    isResetting = true
                }
                // Yield to allow UI to update before heavy deletion starts
                try? await Task.sleep(nanoseconds: 100_000_000)
                await OnboardingService.shared.performFactoryReset()
            }
        }
    }

    // MARK: - Dirty-State Tracking

    /// Snapshot of exactly the fields that `saveConfiguration` persists.
    private struct SaveableFormState: Equatable {
        var startAtLogin: Bool
        var hideDockIcon: Bool
        var hotkey: Hotkey?
    }

    private var currentFormState: SaveableFormState {
        SaveableFormState(
            startAtLogin: tempStartAtLogin,
            hideDockIcon: tempHideDockIcon,
            hotkey: tempChatHotkey
        )
    }

    /// True once the user has edited any save-relevant field away from the
    /// loaded/last-saved baseline. While the baseline is nil (initial load
    /// hasn't completed) we treat the form as clean.
    private var hasUnsavedChanges: Bool {
        guard let savedFormState else { return false }
        return currentFormState != savedFormState
    }

    // MARK: - Configuration Saving

    private func saveConfiguration() {
        // Use the cached last-loaded server config instead of a synchronous
        // disk read; the store writes back off the main thread below.
        let previousServerCfg = loadedServerConfig
        let previousChatCfg = ChatConfigurationStore.load()

        var configuration = previousServerCfg
        configuration.startAtLogin = tempStartAtLogin
        configuration.hideDockIcon = tempHideDockIcon

        let serverConfigChanged = previousServerCfg != configuration
        let startAtLoginChanged = previousServerCfg.startAtLogin != configuration.startAtLogin

        ServerConfigurationStore.save(configuration)
        loadedServerConfig = configuration

        // Load-modify-write: this view owns only the global hotkey within
        // `ChatConfiguration`; preserve whatever is on disk for the rest.
        var chatCfg = previousChatCfg
        chatCfg.hotkey = tempChatHotkey
        ChatConfigurationStore.save(chatCfg)

        let hotkeyChanged = previousChatCfg.hotkey != chatCfg.hotkey

        if hotkeyChanged {
            AppDelegate.shared?.applyChatHotkey()
        }
        if startAtLoginChanged {
            LoginItemService.shared.applyStartAtLogin(configuration.startAtLogin)
        }

        Task { @MainActor in
            if serverConfigChanged {
                AppDelegate.shared?.serverController.configuration = configuration
            }
        }

        // Re-baseline so the dirty check clears now that the live form
        // matches what's persisted.
        savedFormState = currentFormState
    }
}

// MARK: - Toast Configuration Helpers
extension ConfigurationView {
    /// Writes only the exposed master switch; position, timeout and stack size
    /// keep whatever is on disk — the defaults for everyone who never used the
    /// retired controls. The background task limit moved to the Default
    /// queue (Tasks → Queues).
    private func saveToastConfig() {
        let current = ToastManager.shared.configuration
        var config = current
        config.enabled = tempToastEnabled

        guard config != current else { return }
        ToastManager.shared.updateConfiguration(config)
    }
}

// MARK: - Factory Reset Journey Row

/// One row of the factory-reset overlay: status icon + phase label, in the
/// same visual language as the sandbox provisioning journey's `StepRow`.
private struct FactoryResetStepRow: View {
    let step: FactoryResetJourney.Step

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.space.s10) {
            statusIcon
                .frame(width: 16)
            Text(label)
                .font(step.status == .inProgress ? SettingsFont.rowTitle : SettingsFont.body)
                .foregroundColor(labelColor)
            Spacer(minLength: 0)
        }
    }

    private var label: String {
        switch step.id {
        case .browser: return L("Clearing browser data")
        case .keychain: return L("Removing Keychain secrets")
        case .preferences: return L("Clearing preferences")
        case .data: return L("Deleting app data")
        case .quit: return L("Quitting Osaurus")
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch step.status {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .glyphSize(.body)
                .foregroundColor(theme.status.success.foreground)
        case .inProgress:
            SettingsSpinner(size: .mini)
        case .pending:
            Image(systemName: "circle")
                .glyphSize(.body)
                .foregroundColor(theme.text.tertiary)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .glyphSize(.body)
                .foregroundColor(theme.status.error.foreground)
        }
    }

    private var labelColor: Color {
        switch step.status {
        case .completed, .inProgress: return theme.text.primary
        case .pending: return theme.text.tertiary
        case .failed: return theme.status.error.foreground
        }
    }
}
