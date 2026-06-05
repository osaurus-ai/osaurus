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

    /// Usage-analytics consent. Mirrors `TelemetryService.shared.isEnabled`
    /// (opt-in: true only once the user has granted it). Applied immediately on
    /// change rather than via "Save Changes", like the notification toggles,
    /// since it's a privacy switch.
    @State private var tempTelemetryEnabled: Bool = false

    /// Crash-reporting consent. Mirrors `CrashReportingService.shared.isEnabled`
    /// (opt-out: defaults on). Applied immediately on change, as above.
    @State private var tempCrashReportingEnabled: Bool = true

    // Chat settings state
    @State private var tempChatHotkey: Hotkey? = nil
    @State private var tempSystemPrompt: String = ""
    @State private var tempChatTemperature: String = ""
    @State private var tempChatMaxTokens: String = ""
    @State private var tempChatContextLength: String = ""
    @State private var tempChatTopP: String = ""
    @State private var tempChatMaxToolAttempts: String = ""
    @State private var tempPreflightSearchMode: PreflightSearchMode = .balanced
    @State private var tempDisableTools: Bool = true
    @State private var tempMemoryEnabled: Bool = false
    @State private var tempCoreModelProvider: String = ""
    @State private var tempCoreModelName: String = ""
    @State private var coreModelPickerItems: [ModelPickerItem] = []
    @State private var tempEnableClipboardMonitoring: Bool = false
    /// Smooth streaming: pace the visible reveal at ~180 tok/s regardless
    /// of how fast / bursty the network delivers tokens. Default on.
    /// Bound to `UserDefaults` key `chatSmoothStreamingEnabled` which
    /// `StreamingDeltaProcessor` reads per delta.
    @AppStorage("chatSmoothStreamingEnabled") private var smoothStreamingEnabled: Bool = true
    /// Master switch for AI-generated empty-state greetings. Defaults to
    /// OFF; users opt in here. Per-agent overrides on
    /// `AgentSettings.generativeGreetingsEnabled` still win when set.
    @State private var tempGenerativeGreetingsEnabled: Bool = false
    /// Free-text "voice" instruction for AI-generated empty-state
    /// greetings. Empty = use the built-in playful default. Per-agent
    /// overrides live on `AgentSettings.greetingPersona`.
    @State private var tempGreetingPersona: String = ""

    // Server / Local Inference settings now live in the Server →
    // Settings tab. Their state was deleted with the inline UI.

    // Toast settings state
    @State private var tempToastPosition: ToastPosition = .topRight
    @State private var tempToastTimeout: String = ""
    @State private var tempToastEnabled: Bool = true
    @State private var tempToastMaxVisible: String = ""
    @State private var tempToastMaxConcurrent: String = ""

    // Search (passed from sidebar)
    @Binding var searchText: String

    init(searchText: Binding<String> = .constant("")) {
        self._searchText = searchText
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func matchesSearch(_ texts: String...) -> Bool {
        guard isSearching else { return true }
        return texts.contains { SearchService.matches(query: searchText, in: $0) }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Header
                headerView
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : -10)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

                // Scrollable content area
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        // MARK: - General Section
                        if matchesSearch(
                            "General",
                            "System",
                            "Hotkey",
                            "Login",
                            "Start at Login",
                            "Beta",
                            "Updates",
                            "Core Model",
                            "CLI",
                            "Command Line",
                            "Install",
                            "Symlink",
                            "Maintenance",
                            "Reset",
                            "Factory Reset",
                            "Wipe"
                        ) {
                            SettingsSection(title: "General", icon: "gear") {
                                VStack(alignment: .leading, spacing: 20) {
                                    Text("Application behavior and system integration.", bundle: .module)
                                        .font(.system(size: 12))
                                        .foregroundColor(theme.secondaryText)

                                    // Global Hotkey
                                    SettingsField(label: "Global Hotkey") {
                                        HotkeyRecorder(value: $tempChatHotkey)
                                    }

                                    // Start at Login
                                    SettingsToggle(
                                        title: L("Start at Login"),
                                        description: "Launch Osaurus when you sign in",
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
                                        isOn: $updater.isBetaChannel
                                    )

                                    SettingsDivider()

                                    SettingsSubsection(label: "Core Model") {
                                        VStack(alignment: .leading, spacing: 8) {
                                            coreModelPicker
                                            Text(
                                                "Lightweight model used for memory consolidation and preflight tool selection. If unset, your active chat model is used as a fallback. Note: tools must also be enabled on the active agent — check Agent → Capabilities.",
                                                bundle: .module
                                            )
                                            .font(.system(size: 11))
                                            .foregroundColor(theme.tertiaryText)
                                        }
                                    }

                                    SettingsDivider()

                                    // Command Line Tool
                                    SettingsSubsection(label: "Command Line Tool") {
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

                                    // Storage
                                    SettingsSubsection(label: "Storage") {
                                        DirectoryPickerView()
                                    }

                                    SettingsDivider()

                                    // Maintenance
                                    SettingsSubsection(label: "Maintenance") {
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

                        // MARK: - Privacy Section
                        if matchesSearch(
                            "Privacy",
                            "Telemetry",
                            "Analytics",
                            "Usage Data",
                            "Tracking",
                            "Diagnostics"
                        ) {
                            SettingsSection(title: "Privacy", icon: "hand.raised") {
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
                                        isOn: $tempTelemetryEnabled
                                    )
                                    .onChange(of: tempTelemetryEnabled) { _, newValue in
                                        TelemetryService.shared.setEnabled(newValue)
                                    }

                                    SettingsToggle(
                                        title: L("Send Crash Reports"),
                                        description:
                                            "Send anonymous crash and freeze reports so we can fix what breaks. Never includes your chats, prompts, files, or keys. Turn off any time.",
                                        isOn: $tempCrashReportingEnabled
                                    )
                                    .onChange(of: tempCrashReportingEnabled) { _, newValue in
                                        CrashReportingService.shared.setEnabled(newValue)
                                    }
                                }
                            }
                        }

                        // MARK: - Chat Section
                        if matchesSearch(
                            "Chat",
                            "System Prompt",
                            "Temperature",
                            "Max Tokens",
                            "Context Length",
                            "Top P",
                            "Max Tool Attempts",
                            "Generation",
                            "Preflight",
                            "Capability Search",
                            "Memory",
                            "Tools"
                        ) {
                            SettingsSection(title: "Chat", icon: "message") {
                                VStack(alignment: .leading, spacing: 20) {
                                    Text("Configure how chat mode generates responses.", bundle: .module)
                                        .font(.system(size: 12))
                                        .foregroundColor(theme.secondaryText)

                                    // System Prompt
                                    StyledSettingsTextArea(
                                        label: "System Prompt",
                                        text: $tempSystemPrompt,
                                        placeholder: "Enter the default Osaurus agent's instructions...",
                                        hint: "Optional. Persona for the built-in Osaurus agent."
                                    )

                                    // Generation Settings
                                    SettingsSubsection(label: "Generation") {
                                        VStack(alignment: .leading, spacing: 12) {
                                            SettingsSliderField(
                                                label: "Temperature",
                                                help: "Randomness (0–2). Higher = more creative",
                                                text: $tempChatTemperature,
                                                range: 0 ... 2,
                                                step: 0.1,
                                                defaultValue: 0.7,
                                                formatString: "%.1f"
                                            )
                                            SettingsStepperField(
                                                label: "Max Tokens",
                                                help: "Maximum response tokens",
                                                text: $tempChatMaxTokens,
                                                range: 1 ... 65536,
                                                step: 1024,
                                                defaultValue: 16384
                                            )
                                            SettingsStepperField(
                                                label: "Context Length",
                                                help: "Context window for remote models",
                                                text: $tempChatContextLength,
                                                range: 2048 ... 256000,
                                                step: 1024,
                                                defaultValue: 128000
                                            )
                                            SettingsSliderField(
                                                label: "Top P Override",
                                                help: "Sampling diversity (0–1)",
                                                text: $tempChatTopP,
                                                range: 0 ... 1,
                                                step: 0.05,
                                                defaultValue: 1.0,
                                                formatString: "%.2f"
                                            )
                                            SettingsStepperField(
                                                label: "Max Tool Attempts",
                                                help: "Max consecutive tool calls per turn",
                                                text: $tempChatMaxToolAttempts,
                                                range: 1 ... 50,
                                                step: 1,
                                                defaultValue: 15
                                            )
                                        }
                                    }

                                    SettingsDivider()

                                    SettingsSubsection(label: "Display") {
                                        SettingsToggle(
                                            title: L("Smooth streaming"),
                                            description:
                                                "Pace incoming tokens at a steady rate so streaming looks like a typewriter across all providers. Disable to render tokens as soon as they arrive — useful with very fast remote providers that you'd rather see complete instantly.",
                                            isOn: $smoothStreamingEnabled
                                        )
                                    }

                                    SettingsDivider()

                                    SettingsSubsection(label: "Capability Search") {
                                        VStack(alignment: .leading, spacing: 10) {
                                            Picker("", selection: $tempPreflightSearchMode) {
                                                ForEach(PreflightSearchMode.allCases, id: \.self) { mode in
                                                    Text(mode.rawValue.capitalized).tag(mode)
                                                }
                                            }
                                            .pickerStyle(.segmented)
                                            .labelsHidden()
                                            .disabled(tempDisableTools)

                                            Text(tempPreflightSearchMode.helpText)
                                                .font(.system(size: 11))
                                                .foregroundColor(theme.tertiaryText)
                                        }
                                    }

                                    SettingsDivider()

                                    SettingsSubsection(label: "Tools") {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Toggle(
                                                isOn: Binding(
                                                    get: { !tempDisableTools },
                                                    set: { tempDisableTools = !$0 }
                                                )
                                            ) {
                                                Text("Enable tools", bundle: .module)
                                                    .font(.system(size: 12))
                                            }
                                            Text(
                                                "Let agents use built-in and plugin tools. Turn off to send messages directly to the model with no tool specs or capability injection (chat-only).",
                                                bundle: .module
                                            )
                                            .font(.system(size: 11))
                                            .foregroundColor(theme.tertiaryText)
                                        }
                                    }

                                    SettingsDivider()

                                    SettingsSubsection(label: "Memory") {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Toggle(isOn: $tempMemoryEnabled) {
                                                Text("Enable memory", bundle: .module)
                                                    .font(.system(size: 12))
                                            }
                                            Text(
                                                "Inject persistent memory (identity, pinned facts, episodes) into the chat. A relevance gate decides whether memory is needed per-turn, with a single ~800 token budget when it is. Enable for agents that benefit from long-term context.",
                                                bundle: .module
                                            )
                                            .font(.system(size: 11))
                                            .foregroundColor(theme.tertiaryText)
                                        }
                                    }

                                    SettingsDivider()

                                    SettingsSubsection(label: "Clipboard") {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Toggle(isOn: $tempEnableClipboardMonitoring) {
                                                Text("Enable clipboard monitoring", bundle: .module)
                                                    .font(.system(size: 12))
                                            }
                                            Text(
                                                "Automatically detect and offer text from any app as context. Includes 'grab selection' feature when summoning Osaurus.",
                                                bundle: .module
                                            )
                                            .font(.system(size: 11))
                                            .foregroundColor(theme.tertiaryText)
                                        }
                                    }

                                    SettingsDivider()

                                    SettingsSubsection(label: "Generative Greetings") {
                                        VStack(alignment: .leading, spacing: 12) {
                                            VStack(alignment: .leading, spacing: 8) {
                                                Toggle(isOn: $tempGenerativeGreetingsEnabled) {
                                                    Text("AI-generated greetings", bundle: .module)
                                                        .font(.system(size: 12))
                                                }
                                                Text(
                                                    "Off by default. When on, each empty state generates a fresh greeting + quick actions on the configured Core Model. The first generation can feel slow on small models like Foundation; the static greeting still paints instantly. Per-agent overrides in the Customization tab still win.",
                                                    bundle: .module
                                                )
                                                .font(.system(size: 11))
                                                .foregroundColor(theme.tertiaryText)
                                            }

                                            personalityEditorBlock
                                                .disabled(!tempGenerativeGreetingsEnabled)
                                                .opacity(tempGenerativeGreetingsEnabled ? 1 : 0.5)
                                        }
                                    }

                                }
                            }
                        }

                        // MARK: - Tool Permissions Section
                        if matchesSearch(
                            "Tool Permissions",
                            "Permissions",
                            "Folder",
                            "File",
                            "Shell",
                            "Git",
                            "Write",
                            "Delete",
                            "Move",
                            "Copy"
                        ) {
                            ToolPermissionsSection()
                        }

                        // MARK: - Server settings moved
                        // The Server (Port/Expose/CORS) and Local
                        // Inference (Top P, eviction, idle residency)
                        // sections previously lived here. They're now
                        // the canonical home of the Server → Settings
                        // tab in `ServerView`, which is backed by
                        // `VMLXServerRuntimeSettings`. A small
                        // pointer card surfaces the move when the
                        // user searches for any of those keywords.
                        if matchesSearch(
                            "Server",
                            "Port",
                            "Network",
                            "Expose",
                            "CORS",
                            "Origins",
                            "Allowed Origins",
                            "Local Inference",
                            "Inference",
                            "Sampling",
                            "Top P",
                            "Eviction",
                            "Idle Residency",
                            "Keep model loaded"
                        ) {
                            ServerSettingsMovedNotice()
                        }

                        // MARK: - Voice Section
                        if matchesSearch("Voice", "Parakeet", "Transcription", "Model", "Speech") {
                            VoiceSettingsSection()
                        }

                        // MARK: - Notifications Section
                        if matchesSearch(
                            "Notifications",
                            "Toast",
                            "Position",
                            "Timeout",
                            "Alerts",
                            "Concurrent",
                            "Background"
                        ) {
                            SettingsSection(title: "Notifications", icon: "bell") {
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
                                        hint: "Where toasts appear on screen"
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
                                        help: "Seconds before auto-dismiss. Empty uses default 5s"
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

                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }
                .opacity(hasAppeared ? 1 : 0)
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
                            .shadow(color: Color.black.opacity(0.2), radius: 20, x: 0, y: 10)
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
            tempTelemetryEnabled = TelemetryService.shared.isEnabled
            tempCrashReportingEnabled = CrashReportingService.shared.isEnabled
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
        .onReceive(ModelPickerItemCache.shared.$items) { options in
            coreModelPickerItems = options
        }
    }

    // MARK: - Generative Greetings — Personality Editor

    /// Inline label row + multi-line editor + hint, replacing the
    /// previous `StyledSettingsTextArea` here. We need a custom layout
    /// so the "Reset to Default" button can sit next to the label and
    /// reveal/hide based on whether the editor matches the built-in
    /// default. The editor itself never renders an empty state — see
    /// `loadConfiguration` for the prefill convention.
    @ViewBuilder
    private var personalityEditorBlock: some View {
        let defaultText = GenerativeGreetingService.defaultPersonaInstruction
        let isAtDefault =
            tempGreetingPersona.trimmingCharacters(in: .whitespacesAndNewlines)
            == defaultText.trimmingCharacters(in: .whitespacesAndNewlines)

        VStack(alignment: .leading, spacing: 8) {
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

    // MARK: - Header View

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: L("Settings"),
            subtitle: L("Configure your Osaurus settings")
        ) {
            HeaderSecondaryButton("Restore View Defaults", icon: "arrow.counterclockwise") {
                resetToDefaults()
            }
            .help(
                Text(
                    "Restore view-only settings to recommended defaults (does not affect saved configuration)",
                    bundle: .module
                )
            )
            HeaderPrimaryButton("Save Changes", icon: "checkmark") {
                saveConfiguration()
            }
        }
    }

    // MARK: - Configuration Loading

    /// Wrapper so we can hand a single immutable snapshot back to
    /// MainActor instead of four typed return values. `Sendable` is
    /// required for `Task.detached`.
    private struct ConfigurationSnapshot: Sendable {
        let server: ServerConfiguration
        let chat: ChatConfiguration
        let memory: MemoryConfiguration
        let toast: ToastConfiguration
    }

    /// Asynchronous loader. The original synchronous version of this
    /// method called four `…ConfigurationStore.load()` functions on the
    /// main thread inside `.onAppear`, blocking SwiftUI from committing
    /// the post-appear frame with default values while four
    /// `JSONDecoder`+disk reads ran. On a fresh tab visit this was
    /// dozens of ms of visible jank. The detached task below moves the
    /// pure JSON reads (`MemoryConfigurationStore`, `ToastConfigurationStore`
    /// are already nonisolated) off the main thread; the two remaining
    /// `@MainActor`-bound stores hop back briefly via `MainActor.run`,
    /// but the disk reads inside them happen on a separate tick so
    /// SwiftUI has already painted the shell. The result is applied
    /// in a single MainActor batch via `applyLoadedConfiguration(_:)`.
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
                let memory = MemoryConfigurationStore.load()
                let toast = ToastConfigurationStore.load()
                return await ConfigurationSnapshot(
                    server: server,
                    chat: chat,
                    memory: memory,
                    toast: toast
                )
            }.value

            applyLoadedConfiguration(snapshot)
        }
    }

    private func applyLoadedConfiguration(_ snapshot: ConfigurationSnapshot) {
        let configuration = snapshot.server
        tempStartAtLogin = configuration.startAtLogin
        tempHideDockIcon = configuration.hideDockIcon

        let chat = snapshot.chat
        tempChatHotkey = chat.hotkey
        // The Default agent's persona and tool-off flag now live on
        // `DefaultAgentConfiguration` (split off from `ChatConfiguration`
        // in Phase B). Settings UI reads/writes go through the new store
        // so user edits land where `AgentManager.effective*` reads them.
        let defaultAgent = DefaultAgentConfigurationStore.load()
        tempSystemPrompt = defaultAgent.systemPrompt
        tempChatTemperature = defaultAgent.temperature.map { String($0) } ?? ""
        tempChatMaxTokens = defaultAgent.maxTokens.map(String.init) ?? ""
        tempChatContextLength = chat.contextLength.map(String.init) ?? ""
        tempChatTopP = chat.topPOverride.map { String($0) } ?? ""
        tempChatMaxToolAttempts = chat.maxToolAttempts.map(String.init) ?? ""
        tempPreflightSearchMode = chat.preflightSearchMode ?? .balanced
        tempDisableTools = defaultAgent.disableTools
        tempMemoryEnabled = snapshot.memory.enabled
        tempCoreModelProvider = chat.coreModelProvider ?? ""
        tempCoreModelName = chat.coreModelName ?? ""
        tempEnableClipboardMonitoring = chat.enableClipboardMonitoring
        tempGenerativeGreetingsEnabled = chat.generativeGreetingsEnabled
        // Storage convention: empty string = "use the built-in default."
        // The editor never displays an empty state — we hydrate it with
        // the built-in default so the text is selectable, copyable, and
        // editable in place. `saveConfiguration` collapses an unedited
        // default back to "" so future updates to the built-in copy
        // still propagate to users who never changed it.
        tempGreetingPersona =
            chat.greetingPersona.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? GenerativeGreetingService.defaultPersonaInstruction
            : chat.greetingPersona

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
    }

    // MARK: - Reset to Defaults

    private func resetToDefaults() {
        let serverDefaults = ServerConfiguration.default
        let chatDefaults = ChatConfiguration.default

        tempStartAtLogin = serverDefaults.startAtLogin
        tempHideDockIcon = serverDefaults.hideDockIcon

        tempChatHotkey = chatDefaults.hotkey
        tempSystemPrompt = ""
        tempChatTemperature = ""
        tempChatMaxTokens = ""
        tempChatContextLength = ""
        tempChatTopP = ""
        tempChatMaxToolAttempts = ""
        tempPreflightSearchMode = .balanced
        tempDisableTools = true
        tempMemoryEnabled = false
        tempCoreModelProvider = chatDefaults.coreModelProvider ?? ""
        tempCoreModelName = chatDefaults.coreModelName ?? ""
        tempEnableClipboardMonitoring = chatDefaults.enableClipboardMonitoring
        tempGenerativeGreetingsEnabled = chatDefaults.generativeGreetingsEnabled
        // Match `loadConfiguration`: hydrate the editor with the
        // built-in default rather than leaving it blank. Saving with
        // this exact text collapses back to "" so future default
        // updates still flow through.
        tempGreetingPersona = GenerativeGreetingService.defaultPersonaInstruction

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
                withAnimation(.easeIn(duration: 0.3)) {
                    isResetting = true
                }
                // Yield to allow UI to update before heavy deletion starts
                try? await Task.sleep(nanoseconds: 100_000_000)
                await OnboardingService.shared.performFactoryReset()
            }
        }
    }

    // MARK: - Configuration Saving

    private func saveConfiguration() {
        let previousServerCfg = ServerConfigurationStore.load() ?? ServerConfiguration.default
        let previousChatCfg = ChatConfigurationStore.load()

        var configuration = previousServerCfg
        configuration.startAtLogin = tempStartAtLogin
        configuration.hideDockIcon = tempHideDockIcon

        let serverConfigChanged = previousServerCfg != configuration
        let startAtLoginChanged = previousServerCfg.startAtLogin != configuration.startAtLogin

        ServerConfigurationStore.save(configuration)

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

        let existingDefaultModel = previousChatCfg.defaultModel
        let chatCfg = ChatConfiguration(
            hotkey: tempChatHotkey,
            // `systemPrompt` is owned by `DefaultAgentConfiguration` now;
            // we write it to that store below. Persisting it as "" here
            // keeps the JSON shape valid (the field is non-optional in
            // the struct) without re-introducing the split-source-of-
            // truth bug Phase B set out to fix.
            systemPrompt: "",
            temperature: nil,
            maxTokens: nil,
            contextLength: parsedContext,
            topPOverride: parsedTopP,
            maxToolAttempts: parsedMaxToolAttempts,
            defaultModel: existingDefaultModel,
            coreModelProvider: tempCoreModelProvider.isEmpty ? nil : tempCoreModelProvider,
            coreModelName: tempCoreModelName.isEmpty ? nil : tempCoreModelName,
            preflightSearchMode: tempPreflightSearchMode,
            disableTools: false,
            enableClipboardMonitoring: tempEnableClipboardMonitoring,
            generativeGreetingsEnabled: tempGenerativeGreetingsEnabled,
            greetingPersona: {
                // Collapse an unedited built-in default back to "" so
                // the storage stays in "inherit the default" mode.
                // Trim before comparison so trailing whitespace from
                // the editor doesn't accidentally diverge.
                let trimmed = tempGreetingPersona.trimmingCharacters(in: .whitespacesAndNewlines)
                let defaultTrimmed = GenerativeGreetingService.defaultPersonaInstruction
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed == defaultTrimmed ? "" : tempGreetingPersona
            }()
        )
        ChatConfigurationStore.save(chatCfg)

        // Persist default-agent specific fields to their own store.
        var defaultAgentCfg = DefaultAgentConfigurationStore.load()
        defaultAgentCfg.systemPrompt = tempSystemPrompt
        defaultAgentCfg.temperature = parsedTemp
        defaultAgentCfg.maxTokens = parsedMax
        defaultAgentCfg.disableTools = tempDisableTools
        DefaultAgentConfigurationStore.save(defaultAgentCfg)

        // Persist memory enable toggle. Budgets are not user-adjustable in
        // this UI — users can edit MemoryConfiguration.json directly for
        // advanced tuning.
        var memoryCfg = MemoryConfigurationStore.load()
        if memoryCfg.enabled != tempMemoryEnabled {
            memoryCfg.enabled = tempMemoryEnabled
            MemoryConfigurationStore.save(memoryCfg)
        }

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

        showSuccess("Settings saved successfully")
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

// MARK: - Server Settings Moved Notice

/// Surfaces when the user searches for Server/Local Inference
/// keywords inside the legacy Configuration view. Links to the new
/// Server → Settings tab where those controls now live.
private struct ServerSettingsMovedNotice: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        let theme = themeManager.currentTheme
        Button(action: openServerSettings) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Server settings moved", bundle: .module)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(
                        "Port, network exposure, CORS, top-P, model eviction, and idle residency now live in Server → Settings, backed by the vmlx server-runtime contract.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.leading)
                }
                Spacer()
                Text("Open", bundle: .module)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.accentColor)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(theme.accentColor.opacity(0.25), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func openServerSettings() {
        AppDelegate.shared?.showManagementWindow(initialTab: .server)
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

// MARK: - Voice Settings Section

private struct VoiceSettingsSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var modelManager = SpeechModelManager.shared
    @ObservedObject private var speechService = SpeechService.shared

    var body: some View {
        SettingsSection(title: "Voice (Advanced)", icon: "waveform") {
            VStack(alignment: .leading, spacing: 20) {
                Text("Configure voice settings directly in the Voice tab.", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(themeManager.currentTheme.secondaryText)

                // Status info
                HStack(spacing: 12) {
                    // Model status
                    HStack(spacing: 6) {
                        if speechService.isLoadingModel {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 8, height: 8)
                        } else {
                            Circle()
                                .fill(
                                    speechService.isModelLoaded
                                        ? themeManager.currentTheme.successColor
                                        : themeManager.currentTheme.tertiaryText
                                )
                                .frame(width: 8, height: 8)
                        }
                        Text(modelStatusText)
                            .font(.system(size: 11))
                            .foregroundColor(themeManager.currentTheme.secondaryText)
                    }

                    Spacer()

                    // Quick link to Voice tab
                    Button(action: {
                        AppDelegate.shared?.showManagementWindow(initialTab: .voice)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.right.circle")
                                .font(.system(size: 11))
                            Text("Open Voice Tab", bundle: .module)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(themeManager.currentTheme.accentColor)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(themeManager.currentTheme.tertiaryBackground)
                )
            }
        }
    }

    private var modelStatusText: String {
        if speechService.isLoadingModel {
            return "Loading model..."
        } else if speechService.isModelLoaded {
            if let modelId = speechService.loadedModelId,
                let model = modelManager.availableModels.first(where: { $0.id == modelId })
            {
                return model.name
            }
            return "Model Loaded"
        } else if modelManager.downloadedModelsCount == 0 {
            return "No models downloaded"
        } else {
            return "Model not loaded"
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
