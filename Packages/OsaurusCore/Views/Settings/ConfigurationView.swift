//
//  ConfigurationView.swift
//  osaurus
//
//  The "General" sidebar tab. Everyday app behaviour up top (hotkey, login,
//  dock, updates, the Core Model, whether to use models already on this Mac,
//  notifications), the power-user controls under a collapsed Advanced
//  section (models directory, per-source model discovery, background task
//  limit, encryption and file history), Legal links, and Factory Reset as
//  the very last thing on the page.
//
//  The Command Line Tool installer moved to Developer Tools → Server →
//  Overview (`CommandLineToolSection`).
//

import AppKit
import SwiftUI

// MARK: - Configuration View
struct ConfigurationView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var onboardingService = OnboardingService.shared
    @EnvironmentObject private var updater: UpdaterViewModel
    @EnvironmentObject private var server: ServerController

    /// Use computed property to always get the current theme from ThemeManager
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var tempStartAtLogin: Bool = false
    @State private var tempHideDockIcon: Bool = false
    @State private var isResetting = false

    // General settings state. The chat-mode generation knobs and folder
    // tool-permission policies live on the Conversation / Tools tabs; the
    // global hotkey and core model still live here because the General
    // section owns them.
    @State private var tempChatHotkey: Hotkey? = nil
    @State private var tempCoreModelProvider: String = ""
    @State private var tempCoreModelName: String = ""
    @State private var coreModelPickerItems: [ModelPickerItem] = []
    @State private var showCoreModelPicker = false

    // Models already on this Mac (Hugging Face cache, LM Studio). The single
    // everyday switch drives both per-source keys; the per-source toggles
    // and custom path live under Advanced (`ExternalModelsSettingsView`).
    @AppStorage(ExternalModelLocator.importHFCacheDefaultsKey)
    private var importHFCache: Bool = true
    @AppStorage(ExternalModelLocator.importLMStudioDefaultsKey)
    private var importLMStudio: Bool = true

    // Notifications. Only the master switch is everyday UI; the background
    // task limit is an Advanced control. Position, timeout and stack size
    // keep their `ToastConfiguration` defaults (opinionated, not exposed).
    @State private var tempToastEnabled: Bool = true
    @State private var tempToastMaxConcurrent: String = ""

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

    /// Landing anchors rendered inside the Advanced disclosure, so a search
    /// result for one of them opens the disclosure before scrolling.
    private static let advancedAnchorIds: Set<String> = [
        "storage.location", "storage.externalModels", "settings.notifications.maxConcurrent",
        "storage.encryption", "storage.fileHistory.retention", "storage.fileHistory.sizeLimit",
    ]

    var body: some View {
        ZStack {
            SettingsPage {
                headerView
            } content: {
                generalSection
                coreModelSection
                modelsOnThisMacSection
                notificationsSection
                advancedSection
                legalSection
                factoryResetSection
            }

            // Factory reset loading overlay
            if isResetting {
                factoryResetOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
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
        .onReceive(ModelPickerItemCache.shared.$items) { options in
            coreModelPickerItems = options
        }
        // Any edit to a save-relevant field reschedules the debounced save.
        // `currentFormState` is the same snapshot the dirty check uses, so
        // immediately-applied toggles (toasts, external models, …) don't
        // trigger it.
        .onChange(of: currentFormState) { _, _ in scheduleAutoSave() }
        // Persist a pending edit if the user leaves before the debounce fires.
        .onDisappear { flushPendingSave() }
    }

    // MARK: - Header

    private var headerView: some View {
        ManagerHeader(
            title: L("General"),
            subtitle: L("App behavior, models on this Mac, and notifications")
        )
    }

    // MARK: - General

    private var generalSection: some View {
        SettingsSection(title: "General", icon: "gear") {
            SettingsRow(title: L("Global Hotkey"), description: "Open Osaurus from anywhere", anchorId: "settings.general.hotkey") {
                HotkeyRecorder(value: $tempChatHotkey)
            }

            SettingsToggle(
                title: L("Start at Login"),
                description: "Launch Osaurus when you sign in",
                anchorId: "settings.general.login",
                isOn: $tempStartAtLogin
            )

            SettingsToggle(
                title: L("Hide Dock Icon"),
                description: "Run in menu bar only (requires restart)",
                anchorId: "settings.general.dock",
                isOn: $tempHideDockIcon
            )

            SettingsToggle(
                title: L("Beta Updates"),
                description: "Receive pre-release updates with new features before they're generally available",
                anchorId: "settings.general.updates",
                isOn: $updater.isBetaChannel
            )
        }
    }

    // MARK: - Core Model

    private var coreModelSection: some View {
        SettingsSection(title: "Core Model", icon: "cube", anchorId: "settings.general.coreModel") {
            VStack(alignment: .leading, spacing: 8) {
                coreModelPicker
                Text(
                    "Lightweight model used for memory consolidation, chat titles and transcription cleanup. If unset, your active chat model is used as a fallback. Note: tools must also be enabled on the active agent — check Agent → Capabilities.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Models on this Mac

    /// One switch for "discover models from other apps". On when either source
    /// is on; flipping it sets both so the everyday control has no half state.
    private var useModelsOnThisMacBinding: Binding<Bool> {
        Binding(
            get: { importHFCache || importLMStudio },
            set: { isOn in
                importHFCache = isOn
                importLMStudio = isOn
                Task.detached(priority: .utility) { ExternalModelLocator.rescan() }
            }
        )
    }

    private var modelsOnThisMacSection: some View {
        SettingsSection(title: "Models on This Mac", icon: "internaldrive") {
            SettingsToggle(
                title: L("Use models already on this Mac"),
                description:
                    "Show models from Hugging Face and LM Studio in your catalog and run them in place. Nothing is copied, moved, or modified. Choose individual sources under Advanced.",
                anchorId: "storage.externalModels",
                isOn: useModelsOnThisMacBinding
            )
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        SettingsSection(title: "Notifications", icon: "bell", anchorId: "settings.notifications.toasts") {
            SettingsToggle(
                title: L("Show Notifications"),
                description: "Display notifications for background tasks and events",
                isOn: $tempToastEnabled
            )
            .onChange(of: tempToastEnabled) { _, _ in saveToastConfig() }
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        SettingsAdvancedDisclosure(anchorIds: Self.advancedAnchorIds) {
            SettingsSubsection(label: "Models Directory", anchorId: "storage.location") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Where Osaurus downloads and stores its own models.", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                    DirectoryPickerView()
                }
            }

            SettingsSubsection(label: "Model Sources") {
                ExternalModelsSettingsView()
            }

            SettingsSubsection(label: "Background Tasks") {
                StyledSettingsTextField(
                    label: "Max Concurrent Background Tasks",
                    text: $tempToastMaxConcurrent,
                    placeholder: "\(ToastConfiguration.default.maxConcurrentTasks)",
                    help:
                        "How many background tasks (downloads, indexing, scheduled runs) may run at once. Empty uses the default of \(ToastConfiguration.default.maxConcurrentTasks).",
                    anchorId: "settings.notifications.maxConcurrent"
                )
                .onChange(of: tempToastMaxConcurrent) { _, _ in saveToastConfig() }
            }

            SettingsSubsection(label: "Data & Storage") {
                VStack(alignment: .leading, spacing: 24) {
                    Text(
                        "How local data is protected on disk, and how long agent file changes stay revertible.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    StorageSettingsView(embedded: true)
                }
            }
        }
    }

    // MARK: - Legal

    private var legalSection: some View {
        SettingsSection(title: "Legal", icon: "doc.text", anchorId: "settings.legal") {
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
        SettingsDestructiveZone(title: "Reset", anchorId: "settings.general.reset") {
            SettingsDestructiveRow(
                title: "Factory Reset",
                description:
                    "Permanently deletes all data and settings — chat history, agents, memory, and your identity keys — then quits Osaurus. This cannot be undone.",
                actionTitle: "Factory Reset…"
            ) {
                showFactoryResetConfirmation()
            }
        }
    }

    private var factoryResetOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text("Resetting Osaurus", bundle: .module)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(theme.primaryText)

                    Text("Deleting data and preferences. Please wait…", bundle: .module)
                        .font(.system(size: 14))
                        .foregroundColor(theme.secondaryText)
                }

                if let journey = onboardingService.resetJourney {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(journey.steps) { step in
                            FactoryResetStepRow(step: step)
                        }
                    }
                    .frame(width: 260)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(theme.primaryBackground.opacity(0.5))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(theme.cardBorder, lineWidth: 1)
                            )
                    )
                    .animation(.easeOut(duration: 0.2), value: journey)
                } else {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(theme.accentColor)
                }
            }
            .padding(40)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(theme.cardBackground)
                    .shadow(color: theme.shadowColor.opacity(0.2), radius: 20, x: 0, y: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(theme.cardBorder, lineWidth: 1)
            )
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
        tempCoreModelProvider = chat.coreModelProvider ?? ""
        tempCoreModelName = chat.coreModelName ?? ""

        let toastConfig = snapshot.toast
        tempToastEnabled = toastConfig.enabled
        tempToastMaxConcurrent =
            toastConfig.maxConcurrentTasks == ToastConfiguration.default.maxConcurrentTasks
            ? "" : String(toastConfig.maxConcurrentTasks)

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
                withAnimation(.easeOut(duration: 0.25)) {
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
        var coreModelProvider: String
        var coreModelName: String
    }

    private var currentFormState: SaveableFormState {
        SaveableFormState(
            startAtLogin: tempStartAtLogin,
            hideDockIcon: tempHideDockIcon,
            hotkey: tempChatHotkey,
            coreModelProvider: tempCoreModelProvider,
            coreModelName: tempCoreModelName
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

        // Load-modify-write: this view owns only the global hotkey and the
        // core model within `ChatConfiguration`; the Conversation tab owns the
        // rest, so preserve whatever is on disk for those fields.
        var chatCfg = previousChatCfg
        chatCfg.hotkey = tempChatHotkey
        chatCfg.coreModelProvider = tempCoreModelProvider.isEmpty ? nil : tempCoreModelProvider
        chatCfg.coreModelName = tempCoreModelName.isEmpty ? nil : tempCoreModelName
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

    // MARK: - Core Model Picker

    private var coreModelIdentifierBinding: Binding<String> {
        Binding(
            get: {
                if tempCoreModelName.isEmpty { return "" }
                return tempCoreModelProvider.isEmpty
                    ? tempCoreModelName
                    : "\(tempCoreModelProvider)/\(tempCoreModelName)"
            },
            set: { newValue in
                if newValue.isEmpty {
                    tempCoreModelProvider = ""
                    tempCoreModelName = ""
                    return
                }
                let parts = newValue.split(separator: "/", maxSplits: 1)
                if parts.count == 2 {
                    tempCoreModelProvider = String(parts[0])
                    tempCoreModelName = String(parts[1])
                } else {
                    tempCoreModelProvider = ""
                    tempCoreModelName = newValue
                }
            }
        )
    }

    /// Bridges the ""-means-fallback identifier binding to the picker's
    /// optional selection.
    private var coreModelSelectionBinding: Binding<String?> {
        Binding(
            get: {
                let id = coreModelIdentifierBinding.wrappedValue
                return id.isEmpty ? nil : id
            },
            set: { coreModelIdentifierBinding.wrappedValue = $0 ?? "" }
        )
    }

    /// Trigger button + rich `ModelPickerView` popover. Replaced the native
    /// `Picker`, which dumped every provider's models into one flat context
    /// menu; the rich picker brings provider tabs, unified search, and the
    /// Add Model shortcut into the Models tab.
    private var coreModelPicker: some View {
        let currentId = coreModelIdentifierBinding.wrappedValue
        let currentItem = coreModelPickerItems.first { $0.id == currentId }
        // A persisted core model the router can't serve right now. For
        // Foundation this is the framework's own reason (Apple Intelligence
        // off, model still downloading); for remote models, the provider is
        // disconnected. Shown under the picker so "set but nothing works" has
        // a fix attached; utilities meanwhile run on the active chat model.
        let unavailableReason: String? =
            (currentId.isEmpty || currentItem != nil)
            ? nil
            : CoreModelService.unavailableReason(modelId: currentId)
        return VStack(alignment: .leading, spacing: 6) {
            coreModelPickerRow(currentId: currentId, currentItem: currentItem)
            if let unavailableReason {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.warningColor)
                    Text(
                        "\(unavailableReason) Until then, your active chat model handles these tasks.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 320, alignment: .leading)
            }
        }
    }

    /// Display name for a core model id that isn't in the picker catalog
    /// (so no `ModelPickerItem.displayName` is available).
    private static func coreModelDisplayName(_ id: String) -> String {
        if id.caseInsensitiveCompare(FoundationModelService.serviceId) == .orderedSame {
            return "Foundation"
        }
        return id
    }

    private func coreModelPickerRow(currentId: String, currentItem: ModelPickerItem?) -> some View {
        HStack(spacing: 8) {
            Button {
                showCoreModelPicker.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "cube.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(currentId.isEmpty ? theme.tertiaryText : theme.accentColor)
                    if currentId.isEmpty {
                        // Empty = "use chat model fallback". Renamed from the
                        // previous "None" footgun (GitHub issue #823).
                        Text("Use chat model (default)", bundle: .module)
                            .font(.system(size: 13))
                            .foregroundColor(theme.placeholderText)
                    } else if let currentItem {
                        Text(currentItem.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)
                    } else {
                        // Persisted-but-unserviceable values (e.g. "foundation"
                        // with Apple Intelligence off, a disconnected remote
                        // model) keep an "(unavailable)" hint so the row isn't
                        // an orphan; the reason renders under the picker.
                        Text(
                            "\(Self.coreModelDisplayName(currentId)) (unavailable)",
                            bundle: .module
                        )
                        .font(.system(size: 13))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10).stroke(theme.inputBorder, lineWidth: 1)
                        )
                )
            }
            .buttonStyle(PlainButtonStyle())
            .popover(isPresented: $showCoreModelPicker, arrowEdge: .bottom) {
                ModelPickerView(
                    options: coreModelPickerItems,
                    selectedModel: coreModelSelectionBinding,
                    agentId: nil,
                    onDismiss: { showCoreModelPicker = false }
                )
            }

            if !currentId.isEmpty {
                Button {
                    coreModelIdentifierBinding.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .localizedHelp("Use chat model (default)")
            }
        }
        .frame(maxWidth: 320)
    }
}

// MARK: - Toast Configuration Helpers
extension ConfigurationView {
    /// Writes only the two exposed fields (master switch + background task
    /// limit); position, timeout and stack size keep whatever is on disk —
    /// the defaults for everyone who never used the retired controls.
    private func saveToastConfig() {
        var config = ToastManager.shared.configuration
        config.enabled = tempToastEnabled

        let trimmedMaxConcurrent = tempToastMaxConcurrent.trimmingCharacters(in: .whitespacesAndNewlines)
        config.maxConcurrentTasks = {
            guard !trimmedMaxConcurrent.isEmpty, let v = Int(trimmedMaxConcurrent) else {
                return ToastConfiguration.default.maxConcurrentTasks
            }
            return max(1, min(50, v))
        }()

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
        HStack(spacing: 10) {
            statusIcon
                .frame(width: 16)
            Text(label)
                .font(.system(size: 13, weight: step.status == .inProgress ? .semibold : .regular))
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
                .font(.system(size: 14))
                .foregroundColor(theme.successColor)
        case .inProgress:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 14))
                .foregroundColor(theme.tertiaryText.opacity(0.6))
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 14))
                .foregroundColor(theme.errorColor)
        }
    }

    private var labelColor: Color {
        switch step.status {
        case .completed, .inProgress: return theme.primaryText
        case .pending: return theme.tertiaryText
        case .failed: return theme.errorColor
        }
    }
}
