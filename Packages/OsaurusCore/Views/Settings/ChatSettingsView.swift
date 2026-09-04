//
//  ChatSettingsView.swift
//  osaurus
//
//  The "Chat" sidebar tab: chat-mode generation settings and the
//  folder-tool permission policies. Split out of the Settings tab so the
//  most-touched generation knobs sit one click away.
//
//  Persistence is scoped to the fields this view owns. Saving does a
//  load-modify-write on `ChatConfiguration` touching only the chat-owned
//  fields (top-P, tool attempts, clipboard, greeting
//  persona, compaction model) so the General settings' hotkey + core-model
//  values — which live in the same struct — are never clobbered. The
//  default-agent persona / generation knobs live in Settings →
//  Orchestrator (`OrchestratorSettingsView` → `DefaultAgentConfiguration`).
//  Tools and memory are deliberately not surfaced here: the default
//  agent's tools toggle lives in the Agents tab and the global memory
//  switch in the Memory tab, so this view never writes either.
//

import AppKit
import SwiftUI

// MARK: - Chat Settings View
// The Chat sidebar tab, sitting just above Settings.

struct ChatSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var taskManager = BackgroundTaskManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    // Chat settings state
    @State private var tempChatTopP: String = ""
    @State private var tempChatMaxToolAttempts: String = ""
    @State private var tempEnableClipboardMonitoring: Bool = false
    @State private var tempWarmModelsOnLoad: Bool = true
    /// AI-generated chat titles from the first completed exchange. Default
    /// on (see `ChatConfiguration.autoGenerateChatTitles`).
    @State private var tempAutoGenerateChatTitles: Bool = true
    /// Master switch for AI-generated follow-up questions after a completed
    /// turn. Default on (see
    /// `ChatConfiguration.generateFollowUpSuggestions`). Per-agent prompt /
    /// rules / model tweaks live in each agent's settings.
    @State private var tempGenerateFollowUpSuggestions: Bool = true
    /// Smooth streaming: pace the visible reveal at ~180 tok/s regardless
    /// of how fast / bursty the network delivers tokens. Default on.
    /// Bound to `UserDefaults` key `chatSmoothStreamingEnabled` which
    /// `StreamingDeltaProcessor` reads per delta. Applied immediately, so
    /// it's excluded from the debounced save baseline.
    @AppStorage("chatSmoothStreamingEnabled") private var smoothStreamingEnabled: Bool = true
    /// Auto-expand the thinking block while the model is actively reasoning
    /// and collapse it again once the answer starts. Default off. Bound to
    /// `UserDefaults` key `chatExpandThinkingWhileStreamingEnabled` which
    /// `ChatSession` reads on every visible-blocks rebuild. Applied
    /// immediately, so it's excluded from the debounced save baseline.
    @AppStorage("chatExpandThinkingWhileStreamingEnabled")
    private var expandThinkingWhileStreamingEnabled: Bool = false
    /// Auto-allow all tool calls without showing the approval card. Default
    /// off. Bound to `UserDefaults` key `ToolApprovalSettings
    /// .autoAllowAllDefaultsKey`, read by `ToolRegistry` at each `.ask`-policy
    /// tool invocation. Applied immediately, so it's excluded from the
    /// debounced save baseline.
    @AppStorage(ToolApprovalSettings.autoAllowAllDefaultsKey)
    private var autoAllowAllToolsEnabled: Bool = false
    /// Turning auto-allow ON disables a security gate for every tool, so the
    /// toggle's binding intercepts the off→on flip and routes it through a
    /// confirmation alert; only confirming persists the value. Turning it
    /// off applies immediately.
    @State private var showAutoAllowAllConfirm = false
    /// Roll up runs of consecutive thinking / tool-call rows into a single
    /// expandable "Worked for …" row so agent loops don't push the
    /// conversation out of view. Default on. Bound to `UserDefaults` key
    /// `ContentBlock.ActivityRollupSetting.defaultsKey`, read by
    /// `BlockMemoizer` on every display rebuild. Applied immediately (a
    /// notification rebuilds open chats), so it's excluded from the
    /// debounced save baseline.
    @AppStorage(ContentBlock.ActivityRollupSetting.defaultsKey)
    private var activityRollupEnabled: Bool = true
    /// Make ⌘N start a new chat in the frontmost chat window (the sidebar
    /// "New Chat" action) instead of opening a new window; "New Window" then
    /// moves to ⇧⌘N. Default on.
    /// Bound to `UserDefaults` key `NewChatShortcutSetting.defaultsKey`,
    /// read by the app's File menu commands. Applied immediately, so it's
    /// excluded from the debounced save baseline.
    @AppStorage(NewChatShortcutSetting.defaultsKey)
    private var cmdNStartsNewChatInCurrentWindow: Bool = true
    /// Model that runs LLM context compaction (summarizing older messages
    /// when a chat outgrows its context window). Same provider/name split
    /// as the Core Model picker; empty = "ask on first use" (the first-run
    /// dialog persists the user's choice back into these fields).
    @State private var tempCompactionModelProvider: String = ""
    @State private var tempCompactionModelName: String = ""
    @State private var showCompactionModelPicker = false
    @State private var compactionModelPickerItems: [ModelPickerItem] = []

    /// Placement of the task-progress notch overlay. With no saved preference,
    /// it defaults on for hardware-notch displays and off elsewhere. Off keeps
    /// it below the menu bar; on anchors it to the top of the display. Bound
    /// to `UserDefaults` key
    /// `NotchOverlayPlacement.defaultsKey`, stored as the enum raw value and
    /// read by `NotchWindowController` when it repositions the panel. Applied
    /// immediately, so it's excluded from the debounced save baseline.
    @AppStorage(NotchOverlayPlacement.defaultsKey) private var notchPlacementRaw: String =
        NotchOverlayPlacement.current.rawValue

    /// Prevent idle system sleep while agent sessions are actively running
    /// or queued. Display sleep and explicit system sleep remain available.
    @AppStorage(AgentRunPowerManager.keepAwakeDefaultsKey)
    private var keepMacAwakeForAgentRuns: Bool = true

    @State private var hasAppeared = false
    @State private var successMessage: String?

    /// Baseline of the save-relevant fields as last loaded or saved. The
    /// debounced auto-save is gated on the live form differing from this so a
    /// pristine screen never writes to disk. `smoothStreamingEnabled` is
    /// applied immediately and deliberately excluded.
    @State private var savedFormState: SaveableFormState?

    /// Debounced auto-save. Save-relevant edits persist ~0.6s after the user
    /// stops, so there's no explicit "Save Changes" button.
    @State private var autoSaveTask: Task<Void, Never>?

    /// Drives scroll-to + glow when a settings-search result lands on this tab.
    @ObservedObject private var highlightCoordinator = SettingsHighlightCoordinator.shared

    // MARK: - Body

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                headerView
                    .managerHeaderEntrance(hasAppeared: hasAppeared)

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            agentPowerSection

                            chatSection

                            generationSection

                            ToolPermissionsSection()
                                .settingsLandingAnchor("settings.toolPermissions")
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

            if let message = successMessage {
                VStack {
                    Spacer()
                    ThemedToastView(message, type: .success)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            loadConfiguration()
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
        // Shared model catalog for the compaction-model picker (same source
        // the General tab's Core Model picker reads).
        .onReceive(ModelPickerItemCache.shared.$items) { options in
            compactionModelPickerItems = options
        }
        // Any edit to a save-relevant field reschedules the debounced save.
        .onChange(of: currentFormState) { _, _ in scheduleAutoSave() }
        .onChange(of: keepMacAwakeForAgentRuns) { _, _ in
            taskManager.refreshPowerAssertion()
        }
        // Persist a pending edit if the user leaves before the debounce fires.
        .onDisappear { flushPendingSave() }
        .themedAlert(
            L("Auto-Allow All Tool Calls?"),
            isPresented: $showAutoAllowAllConfirm,
            message: L(
                "Every tool call will run immediately without asking for approval, including tools that can execute code, modify files, or send data. You can turn this off at any time in Chat settings."
            ),
            primaryButton: .destructive(L("Auto-Allow All")) { autoAllowAllToolsEnabled = true },
            secondaryButton: .cancel(L("Cancel"))
        )
    }

    /// See `showAutoAllowAllConfirm`: off→on asks first, on→off is immediate.
    private var autoAllowAllToolsBinding: Binding<Bool> {
        Binding(
            get: { autoAllowAllToolsEnabled },
            set: { isOn in
                if isOn && !autoAllowAllToolsEnabled {
                    showAutoAllowAllConfirm = true
                } else {
                    autoAllowAllToolsEnabled = isOn
                }
            }
        )
    }

    /// Bridges the string-backed placement preference to the boolean
    /// `SettingsToggle`. Writing flips the raw value and immediately asks the
    /// notch controller to reposition so the change is visible without a
    /// restart.
    private var notchOnMenuBarBinding: Binding<Bool> {
        Binding(
            get: { notchPlacementRaw == NotchOverlayPlacement.onMenuBar.rawValue },
            set: { isOn in
                notchPlacementRaw =
                    (isOn ? NotchOverlayPlacement.onMenuBar : .belowMenuBar).rawValue
                NotchWindowController.shared.refreshPlacement()
            }
        )
    }

    // MARK: - Agent Power Section

    @ViewBuilder private var agentPowerSection: some View {
        SettingsSection(title: L("Agent Sessions"), icon: "bolt.horizontal.circle.fill") {
            VStack(alignment: .leading, spacing: 14) {
                SettingsToggle(
                    title: L("Keep Mac Awake While Agents Run"),
                    description: L(
                        "Prevent idle system sleep while agent sessions are running or queued, so long tasks can finish. The display may still sleep, and closing a MacBook lid or choosing Sleep always takes priority."
                    ),
                    isOn: $keepMacAwakeForAgentRuns
                )
                .settingsLandingAnchor("settings.chat.keepAwakeForAgentRuns")

                if keepMacAwakeForAgentRuns {
                    HStack(spacing: 9) {
                        Image(
                            systemName: taskManager.isPreventingIdleSystemSleep
                                ? "bolt.fill"
                                : "moon.stars.fill"
                        )
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(
                            taskManager.isPreventingIdleSystemSleep
                                ? Color.accentColor
                                : theme.tertiaryText
                        )

                        Text(
                            taskManager.isPreventingIdleSystemSleep
                                ? L("Keeping this Mac awake while agents work")
                                : L("Ready — activates automatically with the next agent run")
                        )
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.tertiaryBackground.opacity(0.45))
                    )
                }
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: L("Chat"),
            subtitle: L("Configure how chat mode generates responses")
        ) {
            HeaderSecondaryButton("Restore Chat Defaults", icon: "arrow.counterclockwise") {
                resetToDefaults()
            }
            .help(
                Text(
                    "Restore chat settings to recommended defaults (saved automatically, like any change)",
                    bundle: .module
                )
            )
        }
    }

    /// Scrolls a freshly-landed search target into view. The control itself
    /// glows via its `settingsLandingAnchor`; this only handles positioning.
    private func scrollToLandingTarget(_ id: String?, proxy: ScrollViewProxy) {
        guard let id, id.hasPrefix("settings.") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    // MARK: - Chat Section

    @ViewBuilder private var chatSection: some View {
        SettingsSection(title: "Chat", icon: "text.bubble") {
            VStack(alignment: .leading, spacing: 20) {
                // The default agent's persona / temperature / max tokens
                // moved to Settings → Orchestrator (OrchestratorSettingsView).
                SettingsToggle(
                    title: L("Smooth Streaming"),
                    description:
                        "Pace incoming tokens at a steady rate so streaming looks like a typewriter across all providers. Disable to render tokens as soon as they arrive — useful with very fast remote providers that you'd rather see complete instantly.",
                    isOn: $smoothStreamingEnabled
                )

                SettingsToggle(
                    title: L("Expand Thinking While Streaming"),
                    description:
                        "Keep the model's reasoning expanded while it is actively thinking, then collapse it automatically once the response begins. Useful for monitoring long-running agent tasks in real time.",
                    isOn: $expandThinkingWhileStreamingEnabled
                )

                SettingsToggle(
                    title: L("Group Thinking & Tool Activity"),
                    description:
                        "Group consecutive thinking and tool-call rows into a single expandable summary row, so long agent runs don't push the conversation out of view. Turn off to always show every step as its own row.",
                    isOn: $activityRollupEnabled
                )
                .onChange(of: activityRollupEnabled) { _, _ in
                    NotificationCenter.default.post(
                        name: ContentBlock.activityRollupSettingChanged,
                        object: nil
                    )
                }

                SettingsToggle(
                    title: L("Auto-Allow All Tool Calls"),
                    description:
                        "Run every tool call without asking for approval, including tools that would normally show a confirmation card. Convenient for multi-step agent workflows, but tools can execute code and modify files. Enable only if you trust the tools you have installed. Per-tool Deny policies still apply.",
                    isOn: autoAllowAllToolsBinding
                )

                SettingsToggle(
                    title: L("⌘+N Starts a New Chat in the Current Window"),
                    description:
                        "Make ⌘+N start a new chat in the frontmost chat window, staying in the current project if there is one. New Window moves to ⇧+⌘+N, matching other chat apps. Turn off to keep ⌘+N opening a new window.",
                    isOn: $cmdNStartsNewChatInCurrentWindow
                )
                .settingsLandingAnchor("settings.chat.cmdNNewChat")

                SettingsToggle(
                    title: L("Clipboard Monitoring"),
                    description:
                        "Automatically detect and offer text from any app as context. Includes 'grab selection' feature when summoning Osaurus.",
                    isOn: $tempEnableClipboardMonitoring
                )

                SettingsToggle(
                    title: L("Automatically Warm Models on Load"),
                    description:
                        "Preload the selected local model and prefill your chat context so the first response starts faster. The model selector shows yellow while warming and green when warmed; with this off, it shows green only while the model is loaded.",
                    isOn: $tempWarmModelsOnLoad
                )

                autoTitleToggleRow

                followUpToggleRow

                SettingsToggle(
                    title: L("Show Notch Overlay on Menu Bar"),
                    description:
                        "Place the task-progress notch overlay on the menu bar. When off, it sits just below the menu bar so it never covers the clock, battery, or other system status controls.",
                    isOn: notchOnMenuBarBinding
                )
                .settingsLandingAnchor("settings.chat.notchPlacement")

                SettingsDivider()

                SettingsSubsection(
                    label: "Compaction Model", anchorId: "settings.chat.compactionModel"
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        compactionModelPicker
                        Text(
                            "Model used to summarize older messages when a chat outgrows its context window (context compaction). Remote models pass through your Privacy Filter. If unset, you'll be asked to pick a model the first time compaction runs.",
                            bundle: .module
                        )
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                    }
                }

            }
        }
    }

    // MARK: - Generation Section

    // Generation knobs sit last before permissions: the most technical
    // controls, used mainly by power users tuning sampling / token budgets.
    @ViewBuilder private var generationSection: some View {
        SettingsSection(title: "Generation", icon: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 12) {
                SettingsSliderField(
                    label: "Top P Override",
                    help: "Sampling diversity (0–1)",
                    text: $tempChatTopP,
                    range: 0 ... 1,
                    step: 0.05,
                    defaultValue: 1.0,
                    formatString: "%.2f",
                    anchorId: "settings.chat.topP"
                )
                SettingsStepperField(
                    label: "Max Tool Attempts",
                    help: "Max consecutive tool calls per turn",
                    text: $tempChatMaxToolAttempts,
                    range: 1 ... 50,
                    step: 1,
                    defaultValue: 15,
                    anchorId: "settings.chat.toolAttempts"
                )
            }
        }
    }

    /// Hand-built `SettingsToggle` twin: the stock control only takes a plain
    /// string description, and this one styles "core model" as an underlined
    /// accent-colored deep link into the General tab's Core Model picker —
    /// same pattern as the transcription cleanup toggle.
    private var autoTitleToggleRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Automatically Name Chats", bundle: .module)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.primaryText)
                Text(autoTitleDescription)
                    .font(.system(size: 11))
                    .tint(theme.accentColor)
                    .environment(
                        \.openURL,
                        OpenURLAction { _ in
                            navigateToCoreModelSetting()
                            return .handled
                        }
                    )
            }

            Spacer()

            Toggle("", isOn: $tempAutoGenerateChatTitles)
                .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                .labelsHidden()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
        )
        .settingsLandingAnchor("settings.chat.autoGenerateTitles")
    }

    /// Follow-up suggestions master switch, styled as the auto-title twin so
    /// the "core model" deep link into the General tab reads the same way.
    private var followUpToggleRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Suggest Follow-Up Questions", bundle: .module)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.primaryText)
                Text(followUpDescription)
                    .font(.system(size: 11))
                    .tint(theme.accentColor)
                    .environment(
                        \.openURL,
                        OpenURLAction { _ in
                            navigateToCoreModelSetting()
                            return .handled
                        }
                    )
            }

            Spacer()

            Toggle("", isOn: $tempGenerateFollowUpSuggestions)
                .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                .labelsHidden()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
        )
        .settingsLandingAnchor("settings.chat.generateFollowUps")
    }

    /// Description for the follow-up toggle, with "core model" rendered as an
    /// underlined accent link, matching `autoTitleDescription`.
    private var followUpDescription: AttributedString {
        var text = AttributedString(
            L(
                "Use the core model to suggest a few next questions after each response, shown as clickable rows the user can tap to continue. Runs in the background and never interrupts the conversation. Each agent can tailor the prompt, rules, and model in its own settings."
            )
        )
        text.foregroundColor = theme.tertiaryText
        if let range = text.range(of: L("core model")) {
            text[range].foregroundColor = theme.accentColor
            text[range].underlineStyle = .single
            text[range].link = URL(string: "osaurus-settings://core-model")
        }
        return text
    }

    /// Description for the auto-title toggle, with "core model" rendered as
    /// an underlined link in the theme's accent color.
    private var autoTitleDescription: AttributedString {
        var text = AttributedString(
            L(
                "Use the core model to generate a short descriptive title after a chat's first response, replacing the first-message preview. Runs in the background and never interrupts your conversation; manual renames always win."
            )
        )
        text.foregroundColor = theme.tertiaryText
        if let range = text.range(of: L("core model")) {
            text[range].foregroundColor = theme.accentColor
            text[range].underlineStyle = .single
            text[range].link = URL(string: "osaurus-settings://core-model")
        }
        return text
    }

    /// Deep-links to the Core Model picker in the General settings tab.
    private func navigateToCoreModelSetting() {
        SettingsHighlightCoordinator.shared.request("settings.general.coreModel")
        ManagementStateManager.shared.selectedTab = .settings
    }

    // MARK: - Compaction Model Picker

    private var compactionModelIdentifierBinding: Binding<String> {
        Binding(
            get: {
                if tempCompactionModelName.isEmpty { return "" }
                return tempCompactionModelProvider.isEmpty
                    ? tempCompactionModelName
                    : "\(tempCompactionModelProvider)/\(tempCompactionModelName)"
            },
            set: { newValue in
                if newValue.isEmpty {
                    tempCompactionModelProvider = ""
                    tempCompactionModelName = ""
                    return
                }
                let parts = newValue.split(separator: "/", maxSplits: 1)
                if parts.count == 2 {
                    tempCompactionModelProvider = String(parts[0])
                    tempCompactionModelName = String(parts[1])
                } else {
                    tempCompactionModelProvider = ""
                    tempCompactionModelName = newValue
                }
            }
        )
    }

    private var compactionModelSelectionBinding: Binding<String?> {
        Binding(
            get: {
                let id = compactionModelIdentifierBinding.wrappedValue
                return id.isEmpty ? nil : id
            },
            set: { compactionModelIdentifierBinding.wrappedValue = $0 ?? "" }
        )
    }

    /// Same trigger + rich `ModelPickerView` popover as the General tab's
    /// Core Model picker, with "unset" meaning "ask on first compaction run"
    /// rather than a chat-model fallback.
    private var compactionModelPicker: some View {
        let currentId = compactionModelIdentifierBinding.wrappedValue
        let currentItem = compactionModelPickerItems.first { $0.id == currentId }
        return HStack(spacing: 8) {
            Button {
                showCompactionModelPicker.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(currentId.isEmpty ? theme.tertiaryText : theme.accentColor)
                    if currentId.isEmpty {
                        Text("Ask on first use (default)", bundle: .module)
                            .font(.system(size: 13))
                            .foregroundColor(theme.placeholderText)
                    } else if let currentItem {
                        Text(currentItem.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)
                    } else {
                        // Persisted-but-uninstalled values (e.g. a disconnected
                        // remote model) keep an "(unavailable)" hint so the row
                        // isn't an orphan.
                        Text("\(currentId) (unavailable)", bundle: .module)
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
            .popover(isPresented: $showCompactionModelPicker, arrowEdge: .bottom) {
                ModelPickerView(
                    options: compactionModelPickerItems,
                    selectedModel: compactionModelSelectionBinding,
                    agentId: nil,
                    onDismiss: { showCompactionModelPicker = false }
                )
            }

            if !currentId.isEmpty {
                Button {
                    compactionModelIdentifierBinding.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .localizedHelp("Ask on first use (default)")
            }
        }
        .frame(maxWidth: 320)
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

    // MARK: - Configuration Loading

    private func loadConfiguration() {
        Task { @MainActor in
            await Task.yield()
            let chat: ChatConfiguration = ChatConfigurationStore.load()
            applyLoadedConfiguration(chat: chat)
        }
    }

    private func applyLoadedConfiguration(chat: ChatConfiguration) {
        // The Default agent's persona and generation knobs moved to
        // Settings → Orchestrator (`DefaultAgentConfiguration`); the numeric
        // generation knobs (top-P and tool attempts) and clipboard settings
        // live on `ChatConfiguration`. Tools and memory are intentionally
        // NOT surfaced here: the default agent's tools toggle lives in the
        // Agents tab and the global memory switch lives in the Memory tab.
        tempChatTopP = chat.topPOverride.map { String($0) } ?? ""
        tempChatMaxToolAttempts = chat.maxToolAttempts.map(String.init) ?? ""
        tempEnableClipboardMonitoring = chat.enableClipboardMonitoring
        tempWarmModelsOnLoad = chat.warmModelsOnLoad
        tempAutoGenerateChatTitles = chat.autoGenerateChatTitles
        tempGenerateFollowUpSuggestions = chat.generateFollowUpSuggestions
        tempCompactionModelProvider = chat.compactionModelProvider ?? ""
        tempCompactionModelName = chat.compactionModelName ?? ""

        // Capture the pristine baseline so the auto-save stays idle until the
        // user actually edits something.
        savedFormState = currentFormState
    }

    // MARK: - Reset to Defaults

    private func resetToDefaults() {
        let chatDefaults = ChatConfiguration.default

        tempChatTopP = ""
        tempChatMaxToolAttempts = ""
        tempEnableClipboardMonitoring = chatDefaults.enableClipboardMonitoring
        tempWarmModelsOnLoad = chatDefaults.warmModelsOnLoad
        tempAutoGenerateChatTitles = chatDefaults.autoGenerateChatTitles
        tempGenerateFollowUpSuggestions = chatDefaults.generateFollowUpSuggestions
        tempCompactionModelProvider = chatDefaults.compactionModelProvider ?? ""
        tempCompactionModelName = chatDefaults.compactionModelName ?? ""

        showSuccess("Chat settings restored to defaults")
    }

    // MARK: - Dirty-State Tracking

    /// Snapshot of exactly the fields that `saveConfiguration` persists.
    private struct SaveableFormState: Equatable {
        var topP: String
        var maxToolAttempts: String
        var enableClipboardMonitoring: Bool
        var warmModelsOnLoad: Bool
        var autoGenerateChatTitles: Bool
        var generateFollowUpSuggestions: Bool
        var compactionModelProvider: String
        var compactionModelName: String
    }

    private var currentFormState: SaveableFormState {
        SaveableFormState(
            topP: tempChatTopP,
            maxToolAttempts: tempChatMaxToolAttempts,
            enableClipboardMonitoring: tempEnableClipboardMonitoring,
            warmModelsOnLoad: tempWarmModelsOnLoad,
            autoGenerateChatTitles: tempAutoGenerateChatTitles,
            generateFollowUpSuggestions: tempGenerateFollowUpSuggestions,
            compactionModelProvider: tempCompactionModelProvider,
            compactionModelName: tempCompactionModelName
        )
    }

    private var hasUnsavedChanges: Bool {
        guard let savedFormState else { return false }
        return currentFormState != savedFormState
    }

    // MARK: - Auto-Save

    private func scheduleAutoSave() {
        guard hasUnsavedChanges else { return }
        autoSaveTask?.cancel()
        autoSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, hasUnsavedChanges else { return }
            saveConfiguration()
        }
    }

    private func flushPendingSave() {
        autoSaveTask?.cancel()
        autoSaveTask = nil
        if hasUnsavedChanges { saveConfiguration() }
    }

    // MARK: - Configuration Saving

    private func saveConfiguration() {
        let trimmedTopPChat = tempChatTopP.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedTopP: Float? = {
            guard !trimmedTopPChat.isEmpty, let v = Float(trimmedTopPChat) else { return nil }
            return max(0.0, min(1.0, v))
        }()

        let parsedMaxToolAttempts: Int? = {
            let s = tempChatMaxToolAttempts.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, let v = Int(s) else { return nil }
            return max(1, min(50, v))
        }()

        // Load-modify-write: only touch the chat-owned fields so the General
        // settings' hotkey + core-model values in the same struct survive.
        var chatCfg = ChatConfigurationStore.load()
        // `systemPrompt` / `temperature` / `maxTokens` are owned by
        // `DefaultAgentConfiguration`; keep their canonical empty values here.
        chatCfg.systemPrompt = ""
        chatCfg.temperature = nil
        chatCfg.maxTokens = nil
        // Unknown-model context metadata fallback is owned by
        // Server → Cache → Context & KV Policy. Never rewrite it from the
        // Chat form, which otherwise recreates a competing "context length"
        // control that users can mistake for the live KV cap.
        chatCfg.topPOverride = parsedTopP
        chatCfg.maxToolAttempts = parsedMaxToolAttempts
        chatCfg.enableClipboardMonitoring = tempEnableClipboardMonitoring
        chatCfg.warmModelsOnLoad = tempWarmModelsOnLoad
        chatCfg.autoGenerateChatTitles = tempAutoGenerateChatTitles
        chatCfg.generateFollowUpSuggestions = tempGenerateFollowUpSuggestions
        chatCfg.compactionModelProvider =
            tempCompactionModelProvider.isEmpty ? nil : tempCompactionModelProvider
        chatCfg.compactionModelName =
            tempCompactionModelName.isEmpty ? nil : tempCompactionModelName
        ChatConfigurationStore.save(chatCfg)

        // Default-agent specific fields (persona / temperature / max tokens)
        // are owned by Settings → Orchestrator and never written here.

        // Re-baseline so the dirty check clears now that the live form matches
        // what's persisted.
        savedFormState = currentFormState
    }
}

// MARK: - Tool Permissions Section

private struct ToolPermissionsSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var refreshId = UUID()

    // (name, display, desc, destructive, defaultPolicy)
    //
    // The dedicated `file_move` / `file_copy` / `file_delete` /
    // `dir_create` / `batch` rows were dropped when those tools were
    // folded into `shell_run` (`mv` / `cp` / `rm` / `mkdir`). Settings
    // for those names will still load from the persisted config (the
    // tool registry just won't have anything to dispatch them to), so
    // existing user preferences keep working.
    private static let folderTools:
        [(name: String, display: String, desc: String, destructive: Bool, defaultPolicy: ToolPermissionPolicy)] = [
            ("file_write", L("Write Files"), L("Create and modify files"), false, .auto),
            ("file_edit", L("Edit Files"), L("Edit file content with search/replace"), false, .auto),
            ("shell_run", L("Run Shell Commands"), L("Execute shell commands in the folder"), true, .ask),
            ("git_commit", L("Git Commit"), L("Commit changes to git repository"), true, .ask),
        ]

    var body: some View {
        SettingsSection(title: "Tool Permissions", icon: "lock.shield") {
            VStack(alignment: .leading, spacing: 16) {
                // Permissions
                SettingsSubsection(label: "Permissions") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(
                            "Control how folder tools execute when chat has access to a working folder.",
                            bundle: .module
                        )
                        .font(.system(size: 12))
                        .foregroundColor(themeManager.currentTheme.secondaryText)

                        VStack(spacing: 0) {
                            ForEach(Self.folderTools, id: \.name) { tool in
                                ToolPermissionRow(
                                    name: tool.name,
                                    displayName: tool.display,
                                    description: tool.desc,
                                    isDestructive: tool.destructive,
                                    defaultPolicy: tool.defaultPolicy,
                                    onPolicyChange: { refreshId = UUID() }
                                )
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(themeManager.currentTheme.inputBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                                )
                        )
                        .id(refreshId)

                        HStack {
                            Spacer()
                            Button(action: resetAllToDefault) {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.counterclockwise")
                                        .font(.system(size: 11))
                                    Text("Reset All to Default", bundle: .module)
                                        .font(.system(size: 12, weight: .medium))
                                }
                            }
                            .buttonStyle(SettingsButtonStyle())
                            .localizedHelp("Reset all tool permissions to default")
                        }
                    }
                }
            }
        }
    }

    private func resetAllToDefault() {
        for tool in Self.folderTools {
            ToolRegistry.shared.clearPolicy(for: tool.name)
        }
        refreshId = UUID()
    }
}

// MARK: - Tool Permission Row

private struct ToolPermissionRow: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    /// Observing `ToolRegistry` here is what lets us read the configured
    /// policy from memory instead of doing a synchronous `tools.json`
    /// disk read in every body evaluation. `setPolicy()` updates the
    /// registry's `@Published configuration`, which republishes here.
    @ObservedObject private var toolRegistry = ToolRegistry.shared
    @State private var isHovered = false
    /// Cached configured policy. Sourced from `ToolRegistry.shared` on
    /// `.onAppear` and refreshed when the registry publishes a change.
    /// Avoids the per-render `ToolConfigurationStore.load()` (which used
    /// to call `JSONDecoder().decode` and `FileManager.fileExists`).
    @State private var configuredPolicy: ToolPermissionPolicy?

    let name: String
    let displayName: String
    let description: String
    let isDestructive: Bool
    let defaultPolicy: ToolPermissionPolicy
    let onPolicyChange: () -> Void

    /// Returns the effective policy (configured or default)
    private var effectivePolicy: ToolPermissionPolicy {
        configuredPolicy ?? defaultPolicy
    }

    var body: some View {
        HStack(spacing: 12) {
            if isDestructive {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.currentTheme.warningColor)
                    .frame(width: 16)
            } else {
                Color.clear.frame(width: 16)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.primaryText)
                Text(LocalizedStringKey(description), bundle: .module)
                    .font(.system(size: 10))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
            }

            Spacer()

            Picker(
                "",
                selection: Binding(
                    get: { effectivePolicy },
                    set: { newValue in
                        toolRegistry.setPolicy(newValue, for: name)
                        configuredPolicy = toolRegistry.configuredPolicy(for: name)
                        onPolicyChange()
                    }
                )
            ) {
                Text("Auto", bundle: .module).tag(ToolPermissionPolicy.auto)
                Text("Ask", bundle: .module).tag(ToolPermissionPolicy.ask)
                Text("Deny", bundle: .module).tag(ToolPermissionPolicy.deny)
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isHovered ? themeManager.currentTheme.tertiaryBackground.opacity(0.5) : Color.clear)
        .onHover { isHovered = $0 }
        .onAppear {
            configuredPolicy = toolRegistry.configuredPolicy(for: name)
        }
        .onReceive(toolRegistry.objectWillChange) { _ in
            // Registry's `@Published configuration` republishes on any
            // `setPolicy` / `clearPolicy` call (including the bulk
            // "Reset All to Default" flow). Re-read in case another
            // row mutated our key.
            let latest = toolRegistry.configuredPolicy(for: name)
            if latest != configuredPolicy {
                configuredPolicy = latest
            }
        }
    }
}

// MARK: - Preview

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        ChatSettingsView()
    }
#endif
