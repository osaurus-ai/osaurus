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
//  fields (context length, top-P, tool attempts, clipboard, greeting
//  persona) so the General settings' hotkey + core-model values — which
//  live in the same struct — are never clobbered. The default-agent
//  persona / generation knobs persist to `DefaultAgentConfiguration`.
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

    private var theme: ThemeProtocol { themeManager.currentTheme }

    // Chat settings state
    @State private var tempSystemPrompt: String = ""
    @State private var tempChatTemperature: String = ""
    @State private var tempChatMaxTokens: String = ""
    @State private var tempChatContextLength: String = ""
    @State private var tempChatTopP: String = ""
    @State private var tempChatMaxToolAttempts: String = ""
    @State private var tempEnableClipboardMonitoring: Bool = false
    /// Smooth streaming: pace the visible reveal at ~180 tok/s regardless
    /// of how fast / bursty the network delivers tokens. Default on.
    /// Bound to `UserDefaults` key `chatSmoothStreamingEnabled` which
    /// `StreamingDeltaProcessor` reads per delta. Applied immediately, so
    /// it's excluded from the debounced save baseline.
    @AppStorage("chatSmoothStreamingEnabled") private var smoothStreamingEnabled: Bool = true
    /// Free-text "voice" instruction for AI-generated empty-state
    /// greetings — the global default voice. The on/off is per-agent
    /// (`AgentSettings.generativeGreetingsEnabled`). Empty = use the
    /// built-in playful default. Per-agent overrides live on
    /// `AgentSettings.greetingPersona`.
    @State private var tempGreetingPersona: String = ""

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
        // Any edit to a save-relevant field reschedules the debounced save.
        .onChange(of: currentFormState) { _, _ in scheduleAutoSave() }
        // Persist a pending edit if the user leaves before the debounce fires.
        .onDisappear { flushPendingSave() }
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
                // System Prompt
                StyledSettingsTextArea(
                    label: "System Prompt",
                    text: $tempSystemPrompt,
                    placeholder: "Enter the default Osaurus agent's instructions...",
                    hint: "Optional. Persona for the built-in Osaurus agent."
                )
                .settingsLandingAnchor("settings.chat.systemPrompt")

                SettingsToggle(
                    title: L("Smooth Streaming"),
                    description:
                        "Pace incoming tokens at a steady rate so streaming looks like a typewriter across all providers. Disable to render tokens as soon as they arrive — useful with very fast remote providers that you'd rather see complete instantly.",
                    isOn: $smoothStreamingEnabled
                )

                SettingsToggle(
                    title: L("Clipboard Monitoring"),
                    description:
                        "Automatically detect and offer text from any app as context. Includes 'grab selection' feature when summoning Osaurus.",
                    isOn: $tempEnableClipboardMonitoring
                )

                SettingsDivider()

                SettingsSubsection(label: "Generative Greetings") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(
                            "Default voice for AI-generated greetings + quick actions. Turn greetings on per agent under the agent's Features tab; each agent can also override this voice in its Customization tab.",
                            bundle: .module
                        )
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)

                        personalityEditorBlock
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
                    label: "Temperature",
                    help: "Randomness (0–2). Higher = more creative",
                    text: $tempChatTemperature,
                    range: 0 ... 2,
                    step: 0.1,
                    defaultValue: 0.7,
                    formatString: "%.1f",
                    anchorId: "settings.chat.temperature"
                )
                SettingsStepperField(
                    label: "Max Tokens",
                    help: "Maximum response tokens",
                    text: $tempChatMaxTokens,
                    range: 1 ... 65536,
                    step: 1024,
                    defaultValue: 16384,
                    anchorId: "settings.chat.maxTokens"
                )
                SettingsStepperField(
                    label: "Context Length",
                    help: "Context window for remote models",
                    text: $tempChatContextLength,
                    range: 2048 ... 256000,
                    step: 1024,
                    defaultValue: 128000,
                    anchorId: "settings.chat.contextLength"
                )
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

    private var personalityEditorBlock: some View {
        let defaultText = GenerativeGreetingService.defaultPersonaInstruction
        let isAtDefault =
            tempGreetingPersona.trimmingCharacters(in: .whitespacesAndNewlines)
            == defaultText.trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Personality (default for all agents)", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                Spacer()
                if !isAtDefault {
                    Button {
                        tempGreetingPersona = defaultText
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Reset to Default", bundle: .module)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(theme.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }

            TextEditor(text: $tempGreetingPersona)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 100, maxHeight: 200)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )

            Text(
                "Shapes the voice of AI-generated empty-state greetings and quick actions. Each agent can override this in its Customization tab.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
        }
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
            let defaultAgent = DefaultAgentConfigurationStore.load()
            applyLoadedConfiguration(chat: chat, defaultAgent: defaultAgent)
        }
    }

    private func applyLoadedConfiguration(
        chat: ChatConfiguration,
        defaultAgent: DefaultAgentConfiguration
    ) {
        // The Default agent's persona and generation knobs live on
        // `DefaultAgentConfiguration` (split off from `ChatConfiguration`);
        // the numeric generation knobs (context length, top-P, tool
        // attempts) and clipboard / greeting voice live on `ChatConfiguration`.
        // Tools and memory are intentionally NOT surfaced here: the default
        // agent's tools toggle lives in the Agents tab and the global memory
        // switch lives in the Memory tab.
        tempSystemPrompt = defaultAgent.systemPrompt
        tempChatTemperature = defaultAgent.temperature.map { String($0) } ?? ""
        tempChatMaxTokens = defaultAgent.maxTokens.map(String.init) ?? ""
        tempChatContextLength = chat.contextLength.map(String.init) ?? ""
        tempChatTopP = chat.topPOverride.map { String($0) } ?? ""
        tempChatMaxToolAttempts = chat.maxToolAttempts.map(String.init) ?? ""
        tempEnableClipboardMonitoring = chat.enableClipboardMonitoring
        // Storage convention: empty string = "use the built-in default."
        // The editor never displays an empty state — we hydrate it with the
        // built-in default so the text is editable in place. `saveConfiguration`
        // collapses an unedited default back to "" so future updates to the
        // built-in copy still propagate to users who never changed it.
        tempGreetingPersona =
            chat.greetingPersona.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? GenerativeGreetingService.defaultPersonaInstruction
            : chat.greetingPersona

        // Capture the pristine baseline so the auto-save stays idle until the
        // user actually edits something.
        savedFormState = currentFormState
    }

    // MARK: - Reset to Defaults

    private func resetToDefaults() {
        let chatDefaults = ChatConfiguration.default

        tempSystemPrompt = ""
        tempChatTemperature = ""
        tempChatMaxTokens = ""
        tempChatContextLength = ""
        tempChatTopP = ""
        tempChatMaxToolAttempts = ""
        tempEnableClipboardMonitoring = chatDefaults.enableClipboardMonitoring
        tempGreetingPersona = GenerativeGreetingService.defaultPersonaInstruction

        showSuccess("Chat settings restored to defaults")
    }

    // MARK: - Dirty-State Tracking

    /// Snapshot of exactly the fields that `saveConfiguration` persists.
    private struct SaveableFormState: Equatable {
        var systemPrompt: String
        var temperature: String
        var maxTokens: String
        var contextLength: String
        var topP: String
        var maxToolAttempts: String
        var enableClipboardMonitoring: Bool
        var greetingPersona: String
    }

    private var currentFormState: SaveableFormState {
        SaveableFormState(
            systemPrompt: tempSystemPrompt,
            temperature: tempChatTemperature,
            maxTokens: tempChatMaxTokens,
            contextLength: tempChatContextLength,
            topP: tempChatTopP,
            maxToolAttempts: tempChatMaxToolAttempts,
            enableClipboardMonitoring: tempEnableClipboardMonitoring,
            greetingPersona: tempGreetingPersona
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
        let trimmedTemp = tempChatTemperature.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedTemp: Float? = {
            guard !trimmedTemp.isEmpty, let v = Float(trimmedTemp) else { return nil }
            return max(0.0, min(2.0, v))
        }()

        let trimmedMax = tempChatMaxTokens.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedMax: Int? = {
            guard !trimmedMax.isEmpty, let v = Int(trimmedMax) else { return nil }
            return max(1, v)
        }()

        let trimmedContext = tempChatContextLength.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedContext: Int? = {
            guard !trimmedContext.isEmpty, let v = Int(trimmedContext) else { return nil }
            return max(2048, v)
        }()

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
        chatCfg.contextLength = parsedContext
        chatCfg.topPOverride = parsedTopP
        chatCfg.maxToolAttempts = parsedMaxToolAttempts
        chatCfg.enableClipboardMonitoring = tempEnableClipboardMonitoring
        chatCfg.greetingPersona = {
            // Collapse an unedited built-in default back to "" so storage stays
            // in "inherit the default" mode.
            let trimmed = tempGreetingPersona.trimmingCharacters(in: .whitespacesAndNewlines)
            let defaultTrimmed = GenerativeGreetingService.defaultPersonaInstruction
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed == defaultTrimmed ? "" : tempGreetingPersona
        }()
        ChatConfigurationStore.save(chatCfg)

        // Persist default-agent specific fields to their own store. Tools
        // (`disableTools`) are intentionally NOT written here — the default
        // agent's tools toggle lives in the Agents tab, and the global memory
        // switch lives in the Memory tab; this view leaves both untouched.
        var defaultAgentCfg = DefaultAgentConfigurationStore.load()
        defaultAgentCfg.systemPrompt = tempSystemPrompt
        defaultAgentCfg.temperature = parsedTemp
        defaultAgentCfg.maxTokens = parsedMax
        DefaultAgentConfigurationStore.save(defaultAgentCfg)

        // Re-baseline so the dirty check clears now that the live form matches
        // what's persisted.
        savedFormState = currentFormState
    }
}

// MARK: - Styled Settings Text Area

private struct StyledSettingsTextArea: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let label: String
    @Binding var text: String
    let placeholder: String
    let hint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(label), bundle: .module)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(themeManager.currentTheme.secondaryText)

            ZStack(alignment: .topLeading) {
                // Themed placeholder overlay
                if text.isEmpty {
                    Text(LocalizedStringKey(placeholder), bundle: .module)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(themeManager.currentTheme.placeholderText)
                        .padding(.top, 12)
                        .padding(.leading, 12)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $text)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.primaryText)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 100, maxHeight: 160)
                    .padding(10)
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(themeManager.currentTheme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                    )
            )

            Text(LocalizedStringKey(hint), bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(themeManager.currentTheme.tertiaryText)
        }
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
