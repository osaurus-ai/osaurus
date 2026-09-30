//
//  ChatSettingsView.swift
//  osaurus
//
//  The "Conversation" sidebar tab (`ManagementTab.chat`): how chats look,
//  stream, name themselves and behave. Everyday switches sit in the open;
//  the power-user knobs (thinking display, compaction model, sampling, tool
//  attempt budget) sit under a collapsed Advanced section.
//
//  What this tab deliberately does not own:
//  - The Orchestrator's persona / temperature / max tokens → Orchestrator.
//  - Context window cap and sampling defaults → Server → Cache / Sampling.
//  - Tool permissions (auto-allow, per-tool policies) → Tools & MCP.
//  - Tools and memory switches → Agents / Memory.
//
//  Persistence is scoped to the fields this view owns. Saving does a
//  load-modify-write on `ChatConfiguration` touching only the chat-owned
//  fields so the General tab's hotkey + core-model values — which live in
//  the same struct — are never clobbered.
//

import AppKit
import SwiftUI

struct ChatSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var taskManager = BackgroundTaskManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    // `ChatConfiguration`-backed fields (debounced auto-save).
    @State private var tempChatTopP: String = ""
    @State private var tempChatMaxToolAttempts: String = ""
    @State private var tempEnableClipboardMonitoring: Bool = false
    /// AI-generated chat titles from the first completed exchange. Default
    /// on (see `ChatConfiguration.autoGenerateChatTitles`).
    @State private var tempAutoGenerateChatTitles: Bool = true
    /// Master switch for AI-generated follow-up questions after a completed
    /// turn. Default on (see `ChatConfiguration.generateFollowUpSuggestions`).
    @State private var tempGenerateFollowUpSuggestions: Bool = true
    /// Model that runs LLM context compaction (summarizing older messages
    /// when a chat outgrows its context window). Same provider/name split
    /// as the Core Model picker; empty = the chat's current model.
    @State private var tempCompactionModelProvider: String = ""
    @State private var tempCompactionModelName: String = ""
    @State private var showCompactionModelPicker = false
    @State private var compactionModelPickerItems: [ModelPickerItem] = []

    // `UserDefaults`-backed switches (applied immediately, excluded from the
    // debounced save baseline).
    /// Smooth streaming: pace the visible reveal at ~180 tok/s regardless of
    /// how fast / bursty the network delivers tokens. Read per delta by
    /// `StreamingDeltaProcessor`.
    @AppStorage("chatSmoothStreamingEnabled") private var smoothStreamingEnabled: Bool = true
    /// Auto-expand the thinking block while the model is actively reasoning
    /// and collapse it again once the answer starts. Read by `ChatSession`.
    @AppStorage("chatExpandThinkingWhileStreamingEnabled")
    private var expandThinkingWhileStreamingEnabled: Bool = false
    /// Roll up runs of consecutive thinking / tool-call rows into a single
    /// expandable "Worked for …" row. Read by `BlockMemoizer`.
    @AppStorage(ContentBlock.ActivityRollupSetting.defaultsKey)
    private var activityRollupEnabled: Bool = true
    /// Make ⌘N start a new chat in the frontmost chat window instead of
    /// opening a new window; "New Window" then moves to ⇧⌘N.
    @AppStorage(NewChatShortcutSetting.defaultsKey)
    private var cmdNStartsNewChatInCurrentWindow: Bool = true
    /// Run the macOS spell checker in the chat composer.
    @AppStorage(ComposerSpellCheckSetting.defaultsKey)
    private var composerSpellCheckEnabled: Bool = ComposerSpellCheckSetting.defaultValue
    /// Prevent idle system sleep while agent sessions are actively running
    /// or queued. Display sleep and explicit system sleep remain available.
    @AppStorage(AgentRunPowerManager.keepAwakeDefaultsKey)
    private var keepMacAwakeForAgentRuns: Bool = true

    /// Baseline of the save-relevant fields as last loaded or saved. The
    /// debounced auto-save is gated on the live form differing from this so a
    /// pristine screen never writes to disk.
    @State private var savedFormState: SaveableFormState?

    /// Debounced auto-save. Save-relevant edits persist ~0.6s after the user
    /// stops, so there's no explicit "Save Changes" button.
    @State private var autoSaveTask: Task<Void, Never>?

    /// Landing anchors rendered inside the Advanced disclosure, so a search
    /// result for one of them opens the disclosure before scrolling.
    private static let advancedAnchorIds: Set<String> = [
        "settings.chat.thinkingDisplay", "settings.chat.compactionModel",
        "settings.chat.topP", "settings.chat.toolAttempts",
    ]

    // MARK: - Body

    var body: some View {
        SettingsPage {
            headerView
        } content: {
            appearanceSection
            behaviorSection
            agentSessionsSection
            advancedSection
        }
        .environment(\.theme, themeManager.currentTheme)
        .onAppear { loadConfiguration() }
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
    }

    // MARK: - Header

    private var headerView: some View {
        ManagerHeader(
            title: L("Conversation"),
            subtitle: L("How chats look, stream, and behave. Model personality lives under Orchestrator.")
        )
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        SettingsSection(title: "Appearance", icon: "text.bubble") {
            SettingsToggle(
                title: L("Smooth Streaming"),
                description:
                    "Reveal replies at a steady, readable pace like a typewriter. Turn off to show text the instant it arrives.",
                anchorId: "settings.chat.smoothStreaming",
                isOn: $smoothStreamingEnabled
            )

            SettingsToggle(
                title: L("Group Thinking & Tool Activity"),
                description:
                    "Collapse runs of thinking and tool steps into one expandable summary row so long agent runs don't push the conversation out of view.",
                anchorId: "settings.chat.activityRollup",
                isOn: $activityRollupEnabled
            )
            .onChange(of: activityRollupEnabled) { _, _ in
                NotificationCenter.default.post(
                    name: ContentBlock.activityRollupSettingChanged,
                    object: nil
                )
            }

            SettingsToggle(
                title: L("Check Spelling While Typing"),
                description:
                    "Underline misspelled words in the chat input and offer corrections on right-click, using your macOS language and dictionary.",
                anchorId: "settings.chat.spellCheck",
                isOn: $composerSpellCheckEnabled
            )
        }
    }

    // MARK: - Behavior

    private var behaviorSection: some View {
        SettingsSection(title: "Behavior", icon: "sparkles") {
            SettingsToggle(
                title: L("Automatically Name Chats"),
                description:
                    "Give each chat a short descriptive title after its first reply. Runs in the background; manual renames always win.",
                anchorId: "settings.chat.autoGenerateTitles",
                isOn: $tempAutoGenerateChatTitles
            )

            SettingsToggle(
                title: L("Suggest Follow-Up Questions"),
                description:
                    "Offer a few next questions after each reply as tappable rows. Each agent can tailor the prompt and model in its own settings.",
                anchorId: "settings.chat.generateFollowUps",
                isOn: $tempGenerateFollowUpSuggestions
            )

            SettingsLinkRow(
                title: "Core Model",
                description: "Chat titles and follow-up questions are written by the Core Model set under General.",
                icon: "arrow.right",
                actionTitle: "Change"
            ) {
                navigateToCoreModelSetting()
            }

            SettingsToggle(
                title: L("Clipboard Monitoring"),
                description:
                    "Offer text you've just copied in any app as context, and grab the current selection when you summon Osaurus.",
                anchorId: "settings.chat.clipboard",
                isOn: $tempEnableClipboardMonitoring
            )

            SettingsToggle(
                title: L("⌘+N Starts a New Chat in the Current Window"),
                description:
                    "New Window moves to ⇧+⌘+N, matching other chat apps. Turn off to keep ⌘+N opening a new window.",
                anchorId: "settings.chat.cmdNNewChat",
                isOn: $cmdNStartsNewChatInCurrentWindow
            )
        }
    }

    // MARK: - Agent Sessions

    private var agentSessionsSection: some View {
        SettingsSection(title: "Agent Sessions", icon: "bolt.horizontal.circle.fill") {
            SettingsToggle(
                title: L("Keep Mac Awake While Agents Run"),
                description:
                    "Prevent idle sleep while agents are running or queued so long tasks can finish. The display may still sleep; closing the lid or choosing Sleep always wins.",
                anchorId: "settings.chat.keepAwakeForAgentRuns",
                isOn: $keepMacAwakeForAgentRuns
            )

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
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        SettingsAdvancedDisclosure(anchorIds: Self.advancedAnchorIds) {
            SettingsToggle(
                title: L("Expand Thinking While Streaming"),
                description:
                    "Keep the model's reasoning open while it is thinking, then collapse it once the answer begins. Useful for watching long agent tasks.",
                anchorId: "settings.chat.thinkingDisplay",
                isOn: $expandThinkingWhileStreamingEnabled
            )

            SettingsSubsection(label: "Compaction Model", anchorId: "settings.chat.compactionModel") {
                VStack(alignment: .leading, spacing: 8) {
                    compactionModelPicker
                    Text(
                        "Model used to summarize older messages when a chat outgrows its context window. Runs automatically near the limit and on demand from the context budget popover. Remote models pass through your Privacy Filter. If unset, the chat's current model summarizes.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsLinkRow(
                title: "Context Window Cap",
                description: "Lower every model's chat window. Lives under Server → Cache so there is one editor.",
                icon: "arrow.right",
                actionTitle: "Open"
            ) {
                navigateToContextWindowCap()
            }
            SettingsSliderField(
                label: "Top P Override",
                help: "Sampling diversity (0–1). Applies to chat only; the API uses Server → Sampling Defaults.",
                text: $tempChatTopP,
                range: 0 ... 1,
                step: 0.05,
                defaultValue: 1.0,
                formatString: "%.2f",
                anchorId: "settings.chat.topP"
            )
            SettingsStepperField(
                label: "Max Tool Attempts",
                help: "Maximum consecutive tool calls per turn before the agent must answer.",
                text: $tempChatMaxToolAttempts,
                range: 1 ... 50,
                step: 1,
                defaultValue: 15,
                anchorId: "settings.chat.toolAttempts"
            )
        }
    }

    // MARK: - Navigation

    /// Deep-links to the Core Model picker in the General settings tab.
    private func navigateToCoreModelSetting() {
        SettingsHighlightCoordinator.shared.request("settings.general.coreModel")
        ManagementStateManager.shared.selectedTab = .settings
    }

    /// The writable context cap lives on Server → Cache. Conversation only
    /// points there so we never recreate a competing editor.
    private func navigateToContextWindowCap() {
        ManagementStateManager.shared.serverSectionRequest = "cache"
        SettingsHighlightCoordinator.shared.request("settings.chat.contextLength")
        ManagementStateManager.shared.selectedTab = .server
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
    /// Core Model picker, with "unset" meaning "summarize with the chat's
    /// current model" (see `ContextCompactionService.effectiveModelIdentifier`).
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
                        Text("Use the current chat model (default)", bundle: .module)
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
                .localizedHelp("Use the current chat model (default)")
            }
        }
        .frame(maxWidth: 320)
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
        tempChatTopP = chat.topPOverride.map { String($0) } ?? ""
        tempChatMaxToolAttempts = chat.maxToolAttempts.map(String.init) ?? ""
        tempEnableClipboardMonitoring = chat.enableClipboardMonitoring
        tempAutoGenerateChatTitles = chat.autoGenerateChatTitles
        tempGenerateFollowUpSuggestions = chat.generateFollowUpSuggestions
        tempCompactionModelProvider = chat.compactionModelProvider ?? ""
        tempCompactionModelName = chat.compactionModelName ?? ""

        // Capture the pristine baseline so the auto-save stays idle until the
        // user actually edits something.
        savedFormState = currentFormState
    }

    // MARK: - Dirty-State Tracking

    /// Snapshot of exactly the fields that `saveConfiguration` persists.
    private struct SaveableFormState: Equatable {
        var topP: String
        var maxToolAttempts: String
        var enableClipboardMonitoring: Bool
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

        // Load-modify-write: only touch the fields this tab owns so the
        // General tab's hotkey + core-model values in the same struct survive.
        // `systemPrompt` / `temperature` / `maxTokens` belong to
        // `DefaultAgentConfiguration`; keep their canonical empty values. The
        // retired `warmModelsOnLoad` and the Server-owned context fallback are
        // left exactly as loaded.
        var chatCfg = ChatConfigurationStore.load()
        chatCfg.systemPrompt = ""
        chatCfg.temperature = nil
        chatCfg.maxTokens = nil
        chatCfg.topPOverride = parsedTopP
        chatCfg.maxToolAttempts = parsedMaxToolAttempts
        chatCfg.enableClipboardMonitoring = tempEnableClipboardMonitoring
        chatCfg.autoGenerateChatTitles = tempAutoGenerateChatTitles
        chatCfg.generateFollowUpSuggestions = tempGenerateFollowUpSuggestions
        chatCfg.compactionModelProvider =
            tempCompactionModelProvider.isEmpty ? nil : tempCompactionModelProvider
        chatCfg.compactionModelName =
            tempCompactionModelName.isEmpty ? nil : tempCompactionModelName
        ChatConfigurationStore.save(chatCfg)

        // Re-baseline so the dirty check clears now that the live form matches
        // what's persisted.
        savedFormState = currentFormState
    }
}

// MARK: - Preview

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        ChatSettingsView()
    }
#endif
