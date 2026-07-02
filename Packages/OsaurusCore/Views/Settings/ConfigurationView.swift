import AppKit
import SwiftUI

// MARK: - Configuration View
struct ConfigurationView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @EnvironmentObject private var updater: UpdaterViewModel

    /// Use computed property to always get the current theme from ThemeManager
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var tempStartAtLogin: Bool = false
    @State private var tempHideDockIcon: Bool = false
    @State private var cliInstallMessage: String? = nil
    @State private var cliInstallSuccess: Bool = false
    @State private var hasAppeared = false
    @State private var successMessage: String?
    @State private var isResetting = false

    // General settings state. The chat-mode generation knobs and folder
    // tool-permission policies moved to the dedicated Chat tab
    // (`ChatSettingsView`); the global hotkey and core model still live
    // here because the General section owns them.
    @State private var tempChatHotkey: Hotkey? = nil
    @State private var tempCoreModelProvider: String = ""
    @State private var tempCoreModelName: String = ""
    @State private var coreModelPickerItems: [ModelPickerItem] = []

    // Server / Local Inference settings now live in the Server →
    // Settings tab. Their state was deleted with the inline UI.

    // Toast settings state
    @State private var tempToastPosition: ToastPosition = .topRight
    @State private var tempToastTimeout: String = ""
    @State private var tempToastEnabled: Bool = true
    @State private var tempToastMaxVisible: String = ""
    @State private var tempToastMaxConcurrent: String = ""

    /// Baseline of the save-relevant fields as last loaded or saved. The
    /// debounced auto-save is gated on the live form differing from this, so a
    /// pristine settings screen never writes to disk. Fields applied
    /// immediately on change (privacy toggles, toasts, smooth streaming, beta
    /// channel) are deliberately excluded — they never flow through
    /// `saveConfiguration`.
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

    /// System runtime knobs for subagent helper jobs (local handoff, RAM-safety
    /// preflight, image load policy). Backed by `SubagentConfigurationStore`;
    /// the per-agent spawn/image config lives in each agent's Subagents tab.
    /// Saved immediately on change (like the toast toggles), not through the
    /// debounced `saveConfiguration` path.
    @State private var subagentConfiguration = SubagentConfigurationStore.snapshot()

    // Search (passed from sidebar)
    @Binding var searchText: String

    /// Drives scroll-to + glow when a settings-search result lands on this tab.
    @ObservedObject private var highlightCoordinator = SettingsHighlightCoordinator.shared

    init(searchText: Binding<String> = .constant("")) {
        self._searchText = searchText
    }

    /// Scrolls a freshly-landed search target into view. The control itself
    /// glows via its `settingsLandingAnchor`; this only handles positioning.
    /// `id` must be one of this tab's anchors (a no-op otherwise, including
    /// anchors that belong to other tabs).
    private func scrollToLandingTarget(_ id: String?, proxy: ScrollViewProxy) {
        guard let id, id.hasPrefix("settings.") else { return }
        // Defer a beat so the tab's layout settles before scrolling.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func matchesSearch(_ texts: [String]) -> Bool {
        guard isSearching else { return true }
        // Token/substring only (no fuzzy subsequence) so section visibility
        // aligns with the field-level glow — both key off the same matching,
        // and prose labels don't trip non-obvious subsequence hits.
        return texts.contains { SearchService.matches(query: searchText, in: $0, allowFuzzy: false) }
    }

    // Per-section search keywords. Each section's visibility gate and the
    // no-results empty state both read from these, so a query that matches no
    // section reliably surfaces the empty state instead of a blank pane.
    private static let generalKeywords = [
        "General", "System", "Hotkey", "Login", "Start at Login", "Beta", "Updates",
        "Core Model", "CLI", "Command Line", "Install", "Symlink", "Maintenance",
        "Reset", "Factory Reset", "Wipe",
    ]
    private static let notificationsKeywords = [
        "Notifications", "Toast", "Position", "Timeout", "Alerts", "Concurrent", "Background",
    ]
    private static let legalKeywords = [
        "Legal", "Terms", "Terms of Service", "Privacy", "Privacy Policy", "Policy", "About",
    ]
    private static let subagentKeywords = [
        "subagent", "spawn", "delegate", "delegation", "helper jobs",
        "handoff", "ram safety", "residency", "unload", "preflight",
        "load policy", "image jobs",
    ]

    private static let allSearchKeywordGroups: [[String]] = [
        generalKeywords, notificationsKeywords, subagentKeywords, legalKeywords,
    ]

    /// True when an active query matches at least one section. Drives the
    /// no-results empty state.
    private var hasAnySearchMatch: Bool {
        Self.allSearchKeywordGroups.contains { matchesSearch($0) }
    }

    /// A tappable legal link styled as a settings row. Opens the canonical
    /// osaurus.ai page in the default browser, matching the app-wide
    /// `NSWorkspace.shared.open` pattern.
    private func legalLinkRow(title: String, url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 13))
                    .foregroundColor(theme.accentColor)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Shown when an active search matches no settings section, so the detail
    /// pane never reads as blank/broken. Echoes the query and offers a clear
    /// action that mirrors the sidebar field's clear button.
    private var searchEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26))
                .foregroundColor(theme.tertiaryText)
            Text("No settings match \"\(searchText)\"", bundle: .module)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
            Text("Try a different term, like \u{201C}hotkey\u{201D} or \u{201C}privacy\u{201D}.", bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
                .multilineTextAlignment(.center)
            Button {
                searchText = ""
            } label: {
                Text("Clear search", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.accentColor)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }

    /// Extracted from `body` to keep the settings expression under Swift's
    /// type-checker complexity limit.
    @ViewBuilder private var generalSection: some View {
        if matchesSearch(Self.generalKeywords) {
            SettingsSection(title: "General", icon: "gear") {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Application behavior and system integration.", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)

                    // Global Hotkey
                    SettingsField(label: "Global Hotkey", anchorId: "settings.general.hotkey") {
                        HotkeyRecorder(value: $tempChatHotkey)
                    }

                    // Start at Login
                    SettingsToggle(
                        title: L("Start at Login"),
                        description: "Launch Osaurus when you sign in",
                        anchorId: "settings.general.login",
                        isOn: $tempStartAtLogin
                    )

                    SettingsToggle(
                        title: L("Hide Dock Icon"),
                        description: "Run in menu bar only (requires restart)",
                        isOn: $tempHideDockIcon
                    )

                    SettingsToggle(
                        title: L("Beta Updates"),
                        description:
                            "Receive pre-release updates with new features before they're generally available",
                        anchorId: "settings.general.updates",
                        isOn: $updater.isBetaChannel
                    )

                    SettingsDivider()

                    SettingsSubsection(label: "Core Model", anchorId: "settings.general.coreModel") {
                        VStack(alignment: .leading, spacing: 8) {
                            coreModelPicker
                            Text(
                                "Lightweight model used for memory consolidation and transcription cleanup. If unset, your active chat model is used as a fallback. Note: tools must also be enabled on the active agent — check Agent → Capabilities.",
                                bundle: .module
                            )
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                        }
                    }

                    SettingsDivider()

                    // Command Line Tool
                    SettingsSubsection(label: "Command Line Tool", anchorId: "settings.general.cli") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(
                                "Install the `osaurus` CLI into your PATH for terminal access.",
                                bundle: .module
                            )
                            .font(.system(size: 12))
                            .foregroundColor(theme.tertiaryText)

                            HStack(spacing: 12) {
                                Button(action: { installCLI() }) {
                                    Text("Install CLI", bundle: .module)
                                }
                                .buttonStyle(SettingsButtonStyle())
                                .localizedHelp("Create a symlink to the embedded CLI")

                                if let message = cliInstallMessage {
                                    HStack(spacing: 6) {
                                        Image(
                                            systemName: cliInstallSuccess
                                                ? "checkmark.circle.fill"
                                                : "exclamationmark.triangle.fill"
                                        )
                                        .font(.system(size: 12))
                                        Text(message)
                                            .font(.system(size: 11))
                                            .lineLimit(2)
                                    }
                                    .foregroundColor(
                                        cliInstallSuccess ? theme.successColor : theme.warningColor
                                    )
                                }
                            }

                            Text(
                                "If installed to ~/.local/bin, ensure it's in your PATH.",
                                bundle: .module
                            )
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                        }
                    }

                    SettingsDivider()

                    // Maintenance
                    SettingsSubsection(label: "Maintenance", anchorId: "settings.general.reset") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(
                                "Troubleshoot or reset the application. A factory reset permanently deletes all data and settings.",
                                bundle: .module
                            )
                            .font(.system(size: 12))
                            .foregroundColor(theme.tertiaryText)

                            Button(role: .destructive, action: { showFactoryResetConfirmation() }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 12))
                                    Text("Factory Reset…", bundle: .module)
                                }
                            }
                            .buttonStyle(SettingsButtonStyle(isDestructive: true))
                        }
                    }
                }
            }
        }
    }

    /// The relocated subagent runtime knobs (was the dedicated Spawn tab). The
    /// component wraps itself in a `SettingsSection` card, so this only adds the
    /// search-visibility gate.
    @ViewBuilder private var subagentSection: some View {
        if matchesSearch(Self.subagentKeywords) {
            SubagentSettingsSection(configuration: $subagentConfiguration)
        }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Header
                headerView
                    .managerHeaderEntrance(hasAppeared: hasAppeared)

                // Scrollable content area
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            // MARK: - General Section
                            generalSection

                            // MARK: - Subagents Section (relocated Spawn knobs)
                            subagentSection

                            // MARK: - Notifications Section
                            if matchesSearch(Self.notificationsKeywords) {
                                SettingsSection(
                                    title: "Notifications",
                                    icon: "bell",
                                    anchorId: "settings.notifications.toasts"
                                ) {
                                    VStack(alignment: .leading, spacing: 20) {
                                        // Enable Toasts Toggle
                                        SettingsToggle(
                                            title: L("Show Toast Notifications"),
                                            description: "Display notifications for background tasks and events",
                                            isOn: $tempToastEnabled
                                        )
                                        .onChange(of: tempToastEnabled) { _, _ in
                                            saveToastConfig()
                                        }

                                        // Position Picker
                                        SettingsField(
                                            label: "Toast Position",
                                            hint: "Where toasts appear on screen",
                                            anchorId: "settings.notifications.position"
                                        ) {
                                            ToastPositionPicker(selection: $tempToastPosition)
                                                .onChange(of: tempToastPosition) { _, _ in
                                                    saveToastConfig()
                                                }
                                        }

                                        // Timeout
                                        StyledSettingsTextField(
                                            label: "Default Timeout",
                                            text: $tempToastTimeout,
                                            placeholder: "5.0",
                                            help: "Seconds before auto-dismiss. Empty uses default 5s",
                                            anchorId: "settings.notifications.timeout"
                                        )
                                        .onChange(of: tempToastTimeout) { _, _ in
                                            saveToastConfig()
                                        }

                                        // Max Visible
                                        StyledSettingsTextField(
                                            label: "Max Visible Toasts",
                                            text: $tempToastMaxVisible,
                                            placeholder: "5",
                                            help: "Maximum toasts shown at once. Empty uses default 5"
                                        )
                                        .onChange(of: tempToastMaxVisible) { _, _ in
                                            saveToastConfig()
                                        }

                                        // Max Concurrent Background Tasks
                                        StyledSettingsTextField(
                                            label: "Max Concurrent Tasks",
                                            text: $tempToastMaxConcurrent,
                                            placeholder: "5",
                                            help: "Maximum background tasks running at once. Empty uses default 5"
                                        )
                                        .onChange(of: tempToastMaxConcurrent) { _, _ in
                                            saveToastConfig()
                                        }

                                        // Test Toast Button
                                        HStack {
                                            Spacer()
                                            Button(action: showTestToast) {
                                                HStack(spacing: 6) {
                                                    Image(systemName: "bell.badge")
                                                        .font(.system(size: 12))
                                                    Text("Test Toast", bundle: .module)
                                                        .font(.system(size: 12, weight: .medium))
                                                }
                                            }
                                            .buttonStyle(SettingsButtonStyle())
                                        }
                                    }
                                }
                            }

                            // MARK: - Legal Section
                            if matchesSearch(Self.legalKeywords) {
                                SettingsSection(title: "Legal", icon: "doc.text", anchorId: "settings.legal") {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text(
                                            "Review the agreements that govern your use of Osaurus.",
                                            bundle: .module
                                        )
                                        .font(.system(size: 12))
                                        .foregroundColor(theme.secondaryText)

                                        legalLinkRow(
                                            title: L("Terms of Service"),
                                            url: OsaurusWebLinks.terms
                                        )
                                        legalLinkRow(
                                            title: L("Privacy Policy"),
                                            url: OsaurusWebLinks.privacy
                                        )
                                    }
                                }
                            }

                            // MARK: - No Results
                            if isSearching && !hasAnySearchMatch {
                                searchEmptyState
                            }

                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity)
                    }
                    .opacity(hasAppeared ? 1 : 0)
                    // When a settings-search result lands here, scroll its control
                    // into view (the control glows itself via `settingsLandingAnchor`).
                    .onChange(of: highlightCoordinator.pending) { _, id in
                        scrollToLandingTarget(id, proxy: proxy)
                    }
                    .onAppear {
                        scrollToLandingTarget(highlightCoordinator.pending, proxy: proxy)
                    }
                }
            }

            // Success toast overlay
            if let message = successMessage {
                VStack {
                    Spacer()
                    ThemedToastView(message, type: .success)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 20)
                }
            }

            // Factory reset loading overlay
            if isResetting {
                ZStack {
                    Rectangle()
                        .fill(.regularMaterial)
                        .ignoresSafeArea()

                    VStack(spacing: 24) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(theme.accentColor)

                        VStack(spacing: 8) {
                            Text("Resetting Osaurus", bundle: .module)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(theme.primaryText)

                            Text("Deleting data and preferences. Please wait…", bundle: .module)
                                .font(.system(size: 14))
                                .foregroundColor(theme.secondaryText)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            loadConfiguration()
            subagentConfiguration = SubagentConfigurationStore.snapshot()
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
        .onReceive(ModelPickerItemCache.shared.$items) { options in
            coreModelPickerItems = options
        }
        // Subagent runtime knobs persist immediately (not via the debounced
        // `saveConfiguration`). The re-snapshot on the change notification keeps
        // this in sync if an agent's Subagents tab edits the shared store.
        .onChange(of: subagentConfiguration) { _, newValue in
            SubagentConfigurationStore.save(newValue)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .subagentConfigurationChanged)
        ) { _ in
            let latest = SubagentConfigurationStore.snapshot()
            if latest != subagentConfiguration { subagentConfiguration = latest }
        }
        // Any edit to a save-relevant field reschedules the debounced save.
        // `currentFormState` is the same snapshot the dirty check uses, so
        // immediately-applied toggles (privacy, toasts, …) don't trigger it.
        .onChange(of: currentFormState) { _, _ in scheduleAutoSave() }
        // Persist a pending edit if the user leaves before the debounce fires.
        .onDisappear { flushPendingSave() }
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

    // MARK: - Success Toast

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

    // MARK: - Header View

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: L("General"),
            subtitle: L("App behavior, system integration, and notifications")
        ) {
            HeaderSecondaryButton("Restore View Defaults", icon: "arrow.counterclockwise") {
                resetToDefaults()
            }
            .help(
                Text(
                    "Restore view settings to recommended defaults (saved automatically, like any change)",
                    bundle: .module
                )
            )
        }
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

    /// Asynchronous loader. The original synchronous version of this
    /// method called the `…ConfigurationStore.load()` functions on the
    /// main thread inside `.onAppear`, blocking SwiftUI from committing
    /// the post-appear frame with default values while the
    /// `JSONDecoder`+disk reads ran. On a fresh tab visit this was
    /// dozens of ms of visible jank. The detached task below moves the
    /// pure JSON reads (`ToastConfigurationStore` is already nonisolated)
    /// off the main thread; the remaining `@MainActor`-bound stores hop
    /// back briefly via `MainActor.run`, but the disk reads inside them
    /// happen on a separate tick so SwiftUI has already painted the
    /// shell. The result is applied in a single MainActor batch via
    /// `applyLoadedConfiguration(_:)`.
    private func loadConfiguration() {
        Task { @MainActor in
            // Yield once so SwiftUI gets to commit the post-`.onAppear`
            // frame with default `tempX` values before we start the
            // disk reads. The yield + detached pattern below is what
            // turns the "Settings tab blocks for ~30 ms on first visit"
            // case into a clean two-frame transition.
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
        // The General section owns the global hotkey and the core model;
        // the chat-mode generation knobs moved to the Chat tab.
        tempChatHotkey = chat.hotkey
        tempCoreModelProvider = chat.coreModelProvider ?? ""
        tempCoreModelName = chat.coreModelName ?? ""

        let toastConfig = snapshot.toast
        tempToastPosition = toastConfig.position
        tempToastEnabled = toastConfig.enabled
        let toastDefaults = ToastConfiguration.default
        tempToastTimeout =
            toastConfig.defaultTimeout == toastDefaults.defaultTimeout
            ? "" : String(toastConfig.defaultTimeout)
        tempToastMaxVisible =
            toastConfig.maxVisibleToasts == toastDefaults.maxVisibleToasts
            ? "" : String(toastConfig.maxVisibleToasts)
        tempToastMaxConcurrent =
            toastConfig.maxConcurrentTasks == toastDefaults.maxConcurrentTasks
            ? "" : String(toastConfig.maxConcurrentTasks)

        // Capture the pristine baseline so the Save button stays disabled
        // until the user actually edits something.
        savedFormState = currentFormState
    }

    // MARK: - Reset to Defaults

    private func resetToDefaults() {
        let serverDefaults = ServerConfiguration.default
        let chatDefaults = ChatConfiguration.default

        tempStartAtLogin = serverDefaults.startAtLogin
        tempHideDockIcon = serverDefaults.hideDockIcon

        tempChatHotkey = chatDefaults.hotkey
        tempCoreModelProvider = chatDefaults.coreModelProvider ?? ""
        tempCoreModelName = chatDefaults.coreModelName ?? ""

        showSuccess("Settings restored to defaults")
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
    /// Compared against the live form to decide whether the debounced
    /// auto-save has anything to write.
    private struct SaveableFormState: Equatable {
        var startAtLogin: Bool
        var hideDockIcon: Bool
        var hotkey: Hotkey?
        var coreModelProvider: String
        var coreModelName: String
    }

    /// Live snapshot of the save-relevant fields, built from the current
    /// `temp*` state.
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
        // core model within `ChatConfiguration`. The chat-mode generation
        // knobs (context length, top-P, tool attempts, clipboard, greeting
        // persona) are owned by the Chat tab, so we preserve whatever is on
        // disk for them rather than reconstructing the whole struct.
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
            // Note: Server / Local Inference settings (port, expose,
            // CORS, top-p, eviction, idle residency) moved to the
            // Server → Settings tab, which owns its own restart +
            // RuntimeConfig invalidation flow.
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

    private var coreModelPicker: some View {
        Picker("", selection: coreModelIdentifierBinding) {
            // Empty tag = "use chat model fallback". Renamed from the
            // previous "None" footgun (GitHub issue #823).
            Text("Use chat model (default)", bundle: .module).tag("")
            // Surface persisted-but-uninstalled values (e.g. "foundation"
            // on macOS < 26, a disconnected remote model) with an
            // "(unavailable)" hint so the row isn't an unlabelled orphan.
            if !coreModelIdentifierBinding.wrappedValue.isEmpty,
                !coreModelPickerItems.contains(where: { $0.id == coreModelIdentifierBinding.wrappedValue })
            {
                Text("\(coreModelIdentifierBinding.wrappedValue) (unavailable)", bundle: .module)
                    .tag(coreModelIdentifierBinding.wrappedValue)
            }
            ForEach(coreModelPickerItems) { option in
                Text(option.displayName)
                    .tag(option.id)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 280)
    }
}

// MARK: - CLI Install Helper
extension ConfigurationView {
    private func installCLI() {
        let fm = FileManager.default

        guard let cliURL = resolveCLIExecutableURL() else {
            cliInstallSuccess = false
            cliInstallMessage = "CLI not found. Build the app with 'make app' or install via release DMG."
            return
        }

        // Candidate target directories
        let brewBin = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)
        let usrLocalBin = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
        let userLocalBin = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)

        if tryInstall(cliURL: cliURL, into: brewBin) {
            cliInstallSuccess = true
            cliInstallMessage = "Installed to \(brewBin.appendingPathComponent("osaurus").path)"
            return
        }

        if tryInstall(cliURL: cliURL, into: usrLocalBin) {
            cliInstallSuccess = true
            cliInstallMessage = "Installed to \(usrLocalBin.appendingPathComponent("osaurus").path)"
            return
        }

        // Fallback to user-local bin
        do {
            try fm.createDirectory(at: userLocalBin, withIntermediateDirectories: true)
        } catch {
            cliInstallSuccess = false
            cliInstallMessage = "Failed to prepare ~/.local/bin (\(error.localizedDescription))"
            return
        }

        if tryInstall(cliURL: cliURL, into: userLocalBin) {
            let linkPath = userLocalBin.appendingPathComponent("osaurus").path
            let inPath = isDirInPATH(userLocalBin.path)
            cliInstallSuccess = true
            cliInstallMessage =
                inPath
                ? "Installed to \(linkPath)"
                : "Installed to \(linkPath). Add to PATH."
            return
        }

        cliInstallSuccess = false
        cliInstallMessage = "Installation failed. Try: scripts/install_cli_symlink.sh"
    }

    private func resolveCLIExecutableURL() -> URL? {
        let fm = FileManager.default
        let appURL = Bundle.main.bundleURL

        // 1. Prefer embedded CLI in Helpers (production build via 'make app')
        let helpers = appURL.appendingPathComponent("Contents/Helpers/osaurus", isDirectory: false)
        if fm.fileExists(atPath: helpers.path), fm.isExecutableFile(atPath: helpers.path) {
            return helpers
        }

        // 2. Try MacOS folder (legacy or alternative embedding)
        let macOS = appURL.appendingPathComponent("Contents/MacOS/osaurus", isDirectory: false)
        if fm.fileExists(atPath: macOS.path), fm.isExecutableFile(atPath: macOS.path) {
            return macOS
        }

        // 3. Development: try the build Products directory
        let productsDir = appURL.deletingLastPathComponent()

        // Check for osaurus-cli binary (the actual CLI product name)
        let debugCLI = productsDir.appendingPathComponent("osaurus-cli", isDirectory: false)
        if fm.fileExists(atPath: debugCLI.path), fm.isExecutableFile(atPath: debugCLI.path) {
            return debugCLI
        }

        // Check for osaurus binary in Products (might be named this in some builds)
        let debugOsaurus = productsDir.appendingPathComponent("osaurus", isDirectory: false)
        if fm.fileExists(atPath: debugOsaurus.path), fm.isExecutableFile(atPath: debugOsaurus.path) {
            return debugOsaurus
        }

        // Check Release folder
        let releaseDir = productsDir.deletingLastPathComponent().appendingPathComponent("Release")
        let releaseCLI = releaseDir.appendingPathComponent("osaurus-cli", isDirectory: false)
        if fm.fileExists(atPath: releaseCLI.path), fm.isExecutableFile(atPath: releaseCLI.path) {
            return releaseCLI
        }

        let releaseOsaurus = releaseDir.appendingPathComponent("osaurus", isDirectory: false)
        if fm.fileExists(atPath: releaseOsaurus.path), fm.isExecutableFile(atPath: releaseOsaurus.path) {
            return releaseOsaurus
        }

        // 4. Check inside Release app bundle's Helpers folder
        let releaseAppHelpers =
            releaseDir
            .appendingPathComponent("osaurus.app/Contents/Helpers/osaurus", isDirectory: false)
        if fm.fileExists(atPath: releaseAppHelpers.path), fm.isExecutableFile(atPath: releaseAppHelpers.path) {
            return releaseAppHelpers
        }

        // 5. Check inside Release app bundle's MacOS folder
        let releaseAppMacOS =
            releaseDir
            .appendingPathComponent("osaurus.app/Contents/MacOS/osaurus", isDirectory: false)
        if fm.fileExists(atPath: releaseAppMacOS.path), fm.isExecutableFile(atPath: releaseAppMacOS.path) {
            return releaseAppMacOS
        }

        return nil
    }

    private func tryInstall(cliURL: URL, into dir: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }

        let linkURL = dir.appendingPathComponent("osaurus")

        // If an entry exists, replace only if it's a symlink
        if fm.fileExists(atPath: linkURL.path) {
            do {
                _ = try fm.destinationOfSymbolicLink(atPath: linkURL.path)
                // It's a symlink – remove and replace
                try? fm.removeItem(at: linkURL)
            } catch {
                // Not a symlink (likely a real file); do not overwrite
                return false
            }
        }

        do {
            try fm.createSymbolicLink(atPath: linkURL.path, withDestinationPath: cliURL.path)
            return true
        } catch {
            return false
        }
    }

    private func isDirInPATH(_ dir: String) -> Bool {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":").map(String.init).contains { $0 == dir }
    }
}

// MARK: - Toast Configuration Helpers
extension ConfigurationView {
    private func saveToastConfig() {
        let defaults = ToastConfiguration.default

        let trimmedTimeout = tempToastTimeout.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedTimeout: TimeInterval = {
            guard !trimmedTimeout.isEmpty, let v = Double(trimmedTimeout) else {
                return defaults.defaultTimeout
            }
            return max(1.0, min(30.0, v))
        }()

        let trimmedMaxVisible = tempToastMaxVisible.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedMaxVisible: Int = {
            guard !trimmedMaxVisible.isEmpty, let v = Int(trimmedMaxVisible) else {
                return defaults.maxVisibleToasts
            }
            return max(1, min(10, v))
        }()

        let trimmedMaxConcurrent = tempToastMaxConcurrent.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedMaxConcurrent: Int = {
            guard !trimmedMaxConcurrent.isEmpty, let v = Int(trimmedMaxConcurrent) else {
                return defaults.maxConcurrentTasks
            }
            return max(1, min(50, v))
        }()

        let config = ToastConfiguration(
            position: tempToastPosition,
            defaultTimeout: parsedTimeout,
            maxVisibleToasts: parsedMaxVisible,
            groupByAgent: true,
            enabled: tempToastEnabled,
            maxConcurrentTasks: parsedMaxConcurrent
        )

        ToastManager.shared.updateConfiguration(config)
    }

    private func showTestToast() {
        ToastManager.shared.success(
            "Test Notification",
            message: "Toast notifications are working!"
        )
    }
}

// MARK: - Toast Position Picker

private struct ToastPositionPicker: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Binding var selection: ToastPosition

    @State private var isHovered = false

    var body: some View {
        Menu {
            ForEach(ToastPosition.allCases, id: \.self) { position in
                Button(action: { selection = position }) {
                    HStack {
                        Text(position.displayName)
                        if selection == position {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: positionIcon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.accentColor)

                Text(selection.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.primaryText)

                Spacer()

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(themeManager.currentTheme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                isHovered
                                    ? themeManager.currentTheme.accentColor.opacity(0.5)
                                    : themeManager.currentTheme.inputBorder,
                                lineWidth: isHovered ? 1.5 : 1
                            )
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    private var positionIcon: String {
        switch selection {
        case .topRight, .topLeft, .topCenter:
            return "arrow.up.square"
        case .bottomRight, .bottomLeft, .bottomCenter:
            return "arrow.down.square"
        }
    }
}

// MARK: - Settings primitives (`SettingsSection`, `SettingsField`,
// `SettingsSubsection`, `StyledSettingsTextField`, `SettingsSliderField`,
// `SettingsStepperField`, `SettingsToggle`, `SettingsDivider`,
// `SettingsButtonStyle`) now live in
// `Packages/OsaurusCore/Views/Settings/Shared/SettingsPrimitives.swift`
// so the Server → Settings tab can reuse them.
