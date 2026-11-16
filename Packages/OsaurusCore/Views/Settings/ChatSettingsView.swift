//
//  ChatSettingsView.swift
//  osaurus
//
//  The "Chat" category (`ManagementTab.chat`): how the transcript reads,
//  how the composer behaves, what chats do on their own, and which models
//  write titles and summaries, plus a drill-in to Commands. The sampling
//  and tool-attempt knobs sit under a collapsed Advanced section.
//
//  What this tab deliberately does not own:
//  - Keep Mac Awake While Agents Run → General → Power.
//  - The Orchestrator's persona / temperature / max tokens → Orchestrator.
//  - Context window cap and sampling defaults → Server → Cache / Sampling.
//  - Tool permissions (auto-allow, per-tool policies) → Tools & MCP.
//  - Tools and memory switches → Agents / Memory.
//  - Core Model and Compaction Model → Models → Model Defaults.
//
//  Persistence is scoped to the fields this view owns. Saving does a
//  load-modify-write on `ChatConfiguration` touching only the chat-owned
//  fields so the hotkey and model-role values — which live in the same
//  struct — are never clobbered.
//

import AppKit
import SwiftUI

struct ChatSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared

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
    /// Turn large pastes into an attachment chip instead of composer text.
    @AppStorage(ComposerPasteCollapseSetting.defaultsKey)
    private var collapseLongPastes: Bool = ComposerPasteCollapseSetting.defaultValue
    /// One card under the greeting of a new chat (`DiscoveryCenter`).
    @AppStorage(DiscoveryStore.enabledKey) private var discoveryCardsEnabled: Bool = true

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
        "settings.chat.topP", "settings.chat.toolAttempts",
    ]

    // MARK: - Body

    var body: some View {
        SettingsPage {
            headerView
        } content: {
            ManagementChildLinks(parent: .chat)
            transcriptSection
            composerSection
            behaviorSection
            modelsSection
            advancedSection
        }
        .environment(\.theme, themeManager.currentTheme)
        .onAppear { loadConfiguration() }
        // Any edit to a save-relevant field reschedules the debounced save.
        .onChange(of: currentFormState) { _, _ in scheduleAutoSave() }
        // `osaurus_config` can change these while the page is open; a pending
        // edit here still wins.
        .onReceive(NotificationCenter.default.publisher(for: .appConfigurationChanged)) { _ in
            if !hasUnsavedChanges { applyLoadedConfiguration(chat: ChatConfigurationStore.load()) }
        }
        // Persist a pending edit if the user leaves before the debounce fires.
        .onDisappear { flushPendingSave() }
    }

    // MARK: - Header

    private var headerView: some View {
        SettingsPageHeader(
            title: "Chat",
            subtitle: "How chats read, stream and behave"
        )
    }

    // MARK: - Transcript

    private var transcriptSection: some View {
        SettingsSection(title: "Transcript") {
            SettingsToggle(
                title: "Smooth Streaming",
                description:
                    "Reveal replies at a steady, readable pace like a typewriter. Turn off to show text the instant it arrives.",
                anchorId: "settings.chat.smoothStreaming",
                isOn: $smoothStreamingEnabled
            )

            SettingsToggle(
                title: "Group Thinking & Tool Activity",
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
                title: "Expand Thinking While Streaming",
                description:
                    "Keep the model's reasoning open while it is thinking, then collapse it once the answer begins. Useful for watching long agent tasks.",
                anchorId: "settings.chat.thinkingDisplay",
                isOn: $expandThinkingWhileStreamingEnabled
            )
        }
    }

    // MARK: - Composer

    private var composerSection: some View {
        SettingsSection(title: "Composer") {
            SettingsToggle(
                title: "Check Spelling While Typing",
                description:
                    "Underline misspelled words in the chat input and offer corrections on right-click, using your macOS language and dictionary.",
                anchorId: "settings.chat.spellCheck",
                isOn: $composerSpellCheckEnabled
            )

            SettingsToggle(
                title: "Collapse Long Pastes",
                description:
                    "Turn long pasted text into a compact attachment instead of filling the message box. Turn off if a dictation or automation tool needs the pasted text to stay in the field.",
                anchorId: "settings.chat.collapseLongPastes",
                isOn: $collapseLongPastes
            )

            SettingsToggle(
                title: "⌘+N Starts a New Chat in the Current Window",
                description:
                    "New Window moves to ⇧+⌘+N, matching other chat apps. Turn off to keep ⌘+N opening a new window.",
                anchorId: "settings.chat.cmdNNewChat",
                isOn: $cmdNStartsNewChatInCurrentWindow
            )
        }
    }

    // MARK: - Behavior

    private var behaviorSection: some View {
        SettingsSection(title: "Behavior") {
            SettingsToggle(
                title: "Automatically Name Chats",
                description:
                    "Give each chat a short descriptive title after its first reply. Runs in the background; manual renames always win.",
                anchorId: "settings.chat.autoGenerateTitles",
                isOn: $tempAutoGenerateChatTitles
            )

            SettingsToggle(
                title: "Suggest Follow-Up Questions",
                description:
                    "Offer a few next questions after each reply as tappable rows. Each agent can tailor the prompt and model in its own settings.",
                anchorId: "settings.chat.generateFollowUps",
                isOn: $tempGenerateFollowUpSuggestions
            )

            SettingsToggle(
                title: "Clipboard Monitoring",
                description:
                    "Offer text you've just copied in any app as context, and grab the current selection when you summon Osaurus.",
                anchorId: "settings.chat.clipboard",
                isOn: $tempEnableClipboardMonitoring
            )

            SettingsToggle(
                title: "Show Discovery Cards",
                description:
                    "Offer one thing you have not tried yet, and what is left to set up, under the greeting of a new chat. At most one new card a day.",
                anchorId: "settings.chat.discoveryCards",
                isOn: $discoveryCardsEnabled
            )
            .onChange(of: discoveryCardsEnabled) { _, enabled in
                FeatureTelemetry.discoveryToggled(enabled: enabled)
            }

            SettingsLinkRow(
                title: "Set Up Osaurus",
                description: "Open a chat that lists what is left to set up.",
                icon: "arrow.right",
                anchorId: "settings.chat.setUpOsaurus"
            ) {
                DiscoveryCenter.shared.openSetUp(from: .settings)
            }
        }
    }

    // MARK: - Models

    private var modelsSection: some View {
        SettingsSection(title: "Models") {
            SettingsLinkRow(
                title: "Core Model",
                description: "Writes chat titles and follow-up questions. Set in Model Defaults.",
                icon: "arrow.right",
                actionTitle: "Change"
            ) {
                navigateToModelDefault("settings.general.coreModel")
            }

            SettingsLinkRow(
                title: "Compaction Model",
                description: "Summarizes older messages near the context limit. Set in Model Defaults.",
                icon: "arrow.right",
                actionTitle: "Change"
            ) {
                navigateToModelDefault("settings.chat.compactionModel")
            }
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        SettingsAdvancedDisclosure(anchorIds: Self.advancedAnchorIds) {
            SettingsSliderRow(
                label: "Top P Override",
                help: "Sampling diversity (0–1). Applies to chat only; the API uses Server → Sampling Defaults.",
                text: $tempChatTopP,
                range: 0 ... 1,
                step: 0.05,
                defaultValue: 1.0,
                formatString: "%.2f",
                anchorId: "settings.chat.topP"
            )
            SettingsStepperRow(
                label: "Max Tool Attempts",
                help: "Maximum consecutive tool calls per turn before the agent must answer.",
                text: $tempChatMaxToolAttempts,
                range: 1 ... 50,
                step: 1,
                defaultValue: 15,
                anchorId: "settings.chat.toolAttempts"
            )
            SettingsLinkRow(
                title: "Context Window Cap",
                description: "Lower every model's chat window. Lives under Server → Cache so there is one editor.",
                icon: "arrow.right",
                actionTitle: "Open"
            ) {
                navigateToContextWindowCap()
            }
        }
    }

    // MARK: - Navigation

    /// Deep-links to a model-role picker on Model Defaults.
    private func navigateToModelDefault(_ anchorId: String) {
        SettingsHighlightCoordinator.shared.request(anchorId)
        ManagementStateManager.shared.selectedTab = .modelDefaults
    }

    /// The writable context cap lives on Server → Cache. Conversation only
    /// points there so we never recreate a competing editor.
    private func navigateToContextWindowCap() {
        ManagementStateManager.shared.serverSectionRequest = "cache"
        SettingsHighlightCoordinator.shared.request("settings.chat.contextLength")
        ManagementStateManager.shared.selectedTab = .server
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
    }

    private var currentFormState: SaveableFormState {
        SaveableFormState(
            topP: tempChatTopP,
            maxToolAttempts: tempChatMaxToolAttempts,
            enableClipboardMonitoring: tempEnableClipboardMonitoring,
            autoGenerateChatTitles: tempAutoGenerateChatTitles,
            generateFollowUpSuggestions: tempGenerateFollowUpSuggestions
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
        // hotkey and model-role values in the same struct survive.
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
