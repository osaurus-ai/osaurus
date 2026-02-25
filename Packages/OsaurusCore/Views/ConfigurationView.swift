import SwiftUI

// MARK: - Configuration View
struct ConfigurationView: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    /// Use computed property to always get the current theme from ThemeManager
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var tempPortString: String = ""
    @State private var tempExposeToNetwork: Bool = false
    @State private var tempStartAtLogin: Bool = false
    @State private var tempHideDockIcon: Bool = false
    @State private var cliInstallMessage: String? = nil
    @State private var cliInstallSuccess: Bool = false
    @State private var hasAppeared = false
    @State private var successMessage: String?

    // Chat settings state
    @State private var tempChatHotkey: Hotkey? = nil
    @State private var tempSystemPrompt: String = ""
    @State private var tempChatTemperature: String = ""
    @State private var tempChatMaxTokens: String = ""
    @State private var tempChatContextLength: String = ""
    @State private var tempChatTopP: String = ""
    @State private var tempChatMaxToolAttempts: String = ""

    // Work generation settings state
    @State private var tempAgentTemperature: String = ""
    @State private var tempAgentMaxTokens: String = ""
    @State private var tempAgentTopP: String = ""
    @State private var tempAgentMaxIterations: String = ""

    // Server settings state
    @State private var tempAllowedOrigins: String = ""

    // Local Inference settings state
    @State private var tempTopP: String = ""
    @State private var tempKVBits: String = ""
    @State private var tempKVGroup: String = ""
    @State private var tempQuantStart: String = ""
    @State private var tempMaxKV: String = ""
    @State private var tempPrefillStep: String = ""
    @State private var tempEvictionPolicy: ModelEvictionPolicy = .strictSingleModel

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
                            "CLI",
                            "Command Line",
                            "Install",
                            "Symlink"
                        ) {
                            SettingsSection(title: "General", icon: "gear") {
                                VStack(alignment: .leading, spacing: 20) {
                                    Text("Application behavior and system integration.")
                                        .font(.system(size: 12))
                                        .foregroundColor(theme.secondaryText)

                                    // Global Hotkey
                                    SettingsField(label: "Global Hotkey") {
                                        HotkeyRecorder(value: $tempChatHotkey)
                                    }

                                    // Start at Login
                                    SettingsToggle(
                                        title: "Start at Login",
                                        description: "Launch Osaurus when you sign in",
                                        isOn: $tempStartAtLogin
                                    )

                                    SettingsToggle(
                                        title: "Hide Dock Icon",
                                        description: "Run in menu bar only (requires restart)",
                                        isOn: $tempHideDockIcon
                                    )

                                    SettingsDivider()

                                    // Command Line Tool
                                    SettingsSubsection(label: "Command Line Tool") {
                                        VStack(alignment: .leading, spacing: 12) {
                                            Text("Install the `osaurus` CLI into your PATH for terminal access.")
                                                .font(.system(size: 12))
                                                .foregroundColor(theme.tertiaryText)

                                            HStack(spacing: 12) {
                                                Button(action: { installCLI() }) {
                                                    Text("Install CLI")
                                                }
                                                .buttonStyle(SettingsButtonStyle())
                                                .help("Create a symlink to the embedded CLI")

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

                                            Text("If installed to ~/.local/bin, ensure it's in your PATH.")
                                                .font(.system(size: 11))
                                                .foregroundColor(theme.tertiaryText)
                                        }
                                    }

                                    SettingsDivider()

                                    // Storage
                                    SettingsSubsection(label: "Storage") {
                                        DirectoryPickerView()
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
                            "Generation"
                        ) {
                            SettingsSection(title: "Chat", icon: "message") {
                                VStack(alignment: .leading, spacing: 20) {
                                    Text("Configure how chat mode generates responses.")
                                        .font(.system(size: 12))
                                        .foregroundColor(theme.secondaryText)

                                    // System Prompt
                                    StyledSettingsTextArea(
                                        label: "System Prompt",
                                        text: $tempSystemPrompt,
                                        placeholder: "Enter instructions for all chats...",
                                        hint: "Optional. Shown as a system message for all chats."
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

                                }
                            }
                        }

                        // MARK: - Work Section
                        if matchesSearch(
                            "Work",
                            "Work Generation",
                            "Temperature",
                            "Max Tokens",
                            "Top P",
                            "Max Iterations",
                            "Folder",
                            "File",
                            "Shell",
                            "Git",
                            "Permissions",
                            "Write",
                            "Delete",
                            "Move",
                            "Copy"
                        ) {
                            AgentSettingsSection(
                                workTemperature: $tempAgentTemperature,
                                workMaxTokens: $tempAgentMaxTokens,
                                agentTopP: $tempAgentTopP,
                                workMaxIterations: $tempAgentMaxIterations
                            )
                        }

                        // MARK: - Server Section
                        if matchesSearch("Server", "Port", "Network", "Expose", "CORS", "Origins", "Allowed Origins") {
                            SettingsSection(title: "Server", icon: "network") {
                                VStack(alignment: .leading, spacing: 20) {
                                    Text("Configure the local API server for external integrations.")
                                        .font(.system(size: 12))
                                        .foregroundColor(theme.secondaryText)

                                    // Port
                                    SettingsStepperField(
                                        label: "Port",
                                        help: "Port number (1–65535)",
                                        text: $tempPortString,
                                        range: 1 ... 65535,
                                        step: 1,
                                        defaultValue: 1337
                                    )

                                    // Network Exposure Toggle
                                    SettingsToggle(
                                        title: "Expose to Network",
                                        description: "Allow devices on your network to connect",
                                        isOn: $tempExposeToNetwork
                                    )

                                    // CORS Settings
                                    StyledSettingsTextField(
                                        label: "Allowed Origins",
                                        text: $tempAllowedOrigins,
                                        placeholder: "https://example.com, https://app.localhost",
                                        help: "Comma-separated list. Use * for any, empty to disable CORS"
                                    )
                                }
                            }
                        }

                        // MARK: - Local Inference Section
                        if matchesSearch(
                            "Local Inference",
                            "Inference",
                            "Sampling",
                            "Top P",
                            "KV Cache",
                            "Quantization",
                            "Prefill",
                            "Max KV",
                            "CPU",
                            "Memory"
                        ) {
                            SettingsSection(title: "Local Inference", icon: "bolt") {
                                VStack(alignment: .leading, spacing: 20) {
                                    Text(
                                        "Tune the local model runtime. These settings only affect models running on this device."
                                    )
                                    .font(.system(size: 12))
                                    .foregroundColor(theme.secondaryText)

                                    // Sampling
                                    SettingsSubsection(label: "Sampling") {
                                        VStack(alignment: .leading, spacing: 12) {
                                            SettingsSliderField(
                                                label: "Top P",
                                                help: "Default sampling diversity (0–1)",
                                                text: $tempTopP,
                                                range: 0 ... 1,
                                                step: 0.05,
                                                defaultValue: 1.0,
                                                formatString: "%.2f"
                                            )
                                        }
                                    }

                                    // KV Cache Settings
                                    SettingsSubsection(label: "KV Cache") {
                                        VStack(alignment: .leading, spacing: 12) {
                                            SettingsStepperField(
                                                label: "Cache Bits",
                                                help: "Quantization bits. Empty disables",
                                                text: $tempKVBits,
                                                range: 2 ... 8,
                                                step: 1,
                                                defaultValue: 4
                                            )
                                            SettingsStepperField(
                                                label: "Group Size",
                                                help: "KV quantization group size",
                                                text: $tempKVGroup,
                                                range: 1 ... 256,
                                                step: 16,
                                                defaultValue: 64
                                            )
                                            SettingsStepperField(
                                                label: "Quantized Start",
                                                help: "Starting layer for quantization",
                                                text: $tempQuantStart,
                                                range: 0 ... 1024,
                                                step: 64,
                                                defaultValue: 0
                                            )
                                            SettingsStepperField(
                                                label: "Max Size",
                                                help: "Max KV cache size in tokens",
                                                text: $tempMaxKV,
                                                range: 1024 ... 131072,
                                                step: 1024,
                                                defaultValue: 8192
                                            )
                                            SettingsStepperField(
                                                label: "Prefill Step",
                                                help: "Tokens per prefill chunk",
                                                text: $tempPrefillStep,
                                                range: 64 ... 2048,
                                                step: 64,
                                                defaultValue: 512
                                            )
                                        }
                                    }

                                    SettingsDivider()

                                    // Eviction Policy
                                    SettingsSubsection(label: "Model Management") {
                                        VStack(alignment: .leading, spacing: 10) {
                                            Picker("", selection: $tempEvictionPolicy) {
                                                ForEach(ModelEvictionPolicy.allCases, id: \.self) { policy in
                                                    Text(policy.rawValue).tag(policy)
                                                }
                                            }
                                            .pickerStyle(.segmented)
                                            .labelsHidden()

                                            Text(tempEvictionPolicy.description)
                                                .font(.system(size: 11))
                                                .foregroundColor(theme.tertiaryText)
                                        }
                                    }
                                }
                            }
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
                                        title: "Show Toast Notifications",
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
                                                Text("Test Toast")
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
            title: "Settings",
            subtitle: "Configure your Osaurus settings"
        ) {
            HeaderSecondaryButton("Reset", icon: "arrow.counterclockwise") {
                resetToDefaults()
            }
            .help("Reset all settings to recommended defaults")
            HeaderPrimaryButton("Save Changes", icon: "checkmark") {
                saveConfiguration()
            }
        }
    }

    // MARK: - Configuration Loading

    private func loadConfiguration() {
        let configuration = ServerConfigurationStore.load() ?? ServerConfiguration.default
        tempPortString = String(configuration.port)
        tempExposeToNetwork = configuration.exposeToNetwork
        tempStartAtLogin = configuration.startAtLogin
        tempHideDockIcon = configuration.hideDockIcon

        let chat = ChatConfigurationStore.load()
        tempChatHotkey = chat.hotkey
        tempSystemPrompt = chat.systemPrompt
        tempChatTemperature = chat.temperature.map { String($0) } ?? ""
        tempChatMaxTokens = chat.maxTokens.map(String.init) ?? ""
        tempChatContextLength = chat.contextLength.map(String.init) ?? ""
        tempChatTopP = chat.topPOverride.map { String($0) } ?? ""
        tempChatMaxToolAttempts = chat.maxToolAttempts.map(String.init) ?? ""

        // Work generation settings
        tempAgentTemperature = chat.workTemperature.map { String($0) } ?? ""
        tempAgentMaxTokens = chat.workMaxTokens.map(String.init) ?? ""
        tempAgentTopP = chat.workTopPOverride.map { String($0) } ?? ""
        tempAgentMaxIterations = chat.workMaxIterations.map(String.init) ?? ""

        let defaults = ServerConfiguration.default
        tempTopP = configuration.genTopP == defaults.genTopP ? "" : String(configuration.genTopP)
        tempKVBits = configuration.genKVBits.map(String.init) ?? ""
        tempKVGroup =
            configuration.genKVGroupSize == defaults.genKVGroupSize
            ? "" : String(configuration.genKVGroupSize)
        tempQuantStart =
            configuration.genQuantizedKVStart == defaults.genQuantizedKVStart
            ? "" : String(configuration.genQuantizedKVStart)
        tempMaxKV = configuration.genMaxKVSize.map(String.init) ?? ""
        tempPrefillStep =
            configuration.genPrefillStepSize == defaults.genPrefillStepSize
            ? "" : String(configuration.genPrefillStepSize)
        tempAllowedOrigins = configuration.allowedOrigins.joined(separator: ", ")
        tempEvictionPolicy = configuration.modelEvictionPolicy

        // Load toast configuration
        let toastConfig = ToastConfigurationStore.load()
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
        // Reset all fields to default values
        let serverDefaults = ServerConfiguration.default
        let chatDefaults = ChatConfiguration.default

        // Server settings
        tempPortString = String(serverDefaults.port)
        tempExposeToNetwork = serverDefaults.exposeToNetwork
        tempStartAtLogin = serverDefaults.startAtLogin
        tempHideDockIcon = serverDefaults.hideDockIcon
        tempAllowedOrigins = ""

        // Chat settings - clear overrides to use defaults
        tempChatHotkey = chatDefaults.hotkey
        tempSystemPrompt = ""
        tempChatTemperature = ""
        tempChatMaxTokens = ""
        tempChatContextLength = ""
        tempChatTopP = ""
        tempChatMaxToolAttempts = ""

        // Work generation settings - clear to use defaults
        tempAgentTemperature = ""
        tempAgentMaxTokens = ""
        tempAgentTopP = ""
        tempAgentMaxIterations = ""

        // Local Inference settings - clear to use defaults
        tempTopP = ""
        tempKVBits = ""
        tempKVGroup = ""
        tempQuantStart = ""
        tempMaxKV = ""
        tempPrefillStep = ""
        tempEvictionPolicy = serverDefaults.modelEvictionPolicy

        // Show success toast
        showSuccess("Settings reset to defaults")
    }

    // MARK: - Configuration Saving

    private func saveConfiguration() {
        guard let port = Int(tempPortString), (1 ..< 65536).contains(port) else { return }

        let previousServerCfg = ServerConfigurationStore.load() ?? ServerConfiguration.default
        let previousChatCfg = ChatConfigurationStore.load()

        var configuration = previousServerCfg
        configuration.port = port
        configuration.exposeToNetwork = tempExposeToNetwork
        configuration.startAtLogin = tempStartAtLogin
        configuration.hideDockIcon = tempHideDockIcon

        // Save Local Inference settings
        let defaults = ServerConfiguration.default
        let trimmedTopP = tempTopP.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTopP.isEmpty {
            configuration.genTopP = defaults.genTopP
        } else {
            configuration.genTopP = Float(trimmedTopP) ?? defaults.genTopP
        }

        configuration.genKVBits = Int(tempKVBits)

        let trimmedKVGroup = tempKVGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedKVGroup.isEmpty {
            configuration.genKVGroupSize = defaults.genKVGroupSize
        } else {
            configuration.genKVGroupSize = Int(trimmedKVGroup) ?? defaults.genKVGroupSize
        }

        let trimmedQuantStart = tempQuantStart.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuantStart.isEmpty {
            configuration.genQuantizedKVStart = defaults.genQuantizedKVStart
        } else {
            configuration.genQuantizedKVStart =
                Int(trimmedQuantStart) ?? defaults.genQuantizedKVStart
        }

        configuration.genMaxKVSize = Int(tempMaxKV)

        let trimmedPrefill = tempPrefillStep.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPrefill.isEmpty {
            configuration.genPrefillStepSize = defaults.genPrefillStepSize
        } else {
            configuration.genPrefillStepSize =
                Int(trimmedPrefill) ?? defaults.genPrefillStepSize
        }

        // Save eviction policy
        configuration.modelEvictionPolicy = tempEvictionPolicy

        // Save CORS allowed origins
        let parsedOrigins: [String] =
            tempAllowedOrigins
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        configuration.allowedOrigins = parsedOrigins

        // Determine which side effects are actually needed
        let serverConfigChanged = previousServerCfg != configuration
        let startAtLoginChanged = previousServerCfg.startAtLogin != configuration.startAtLogin
        let serverRestartNeeded =
            previousServerCfg.port != configuration.port
            || previousServerCfg.exposeToNetwork != configuration.exposeToNetwork
            || previousServerCfg.allowedOrigins != configuration.allowedOrigins
            || previousServerCfg.genTopP != configuration.genTopP
            || previousServerCfg.genKVBits != configuration.genKVBits
            || previousServerCfg.genKVGroupSize != configuration.genKVGroupSize
            || previousServerCfg.genQuantizedKVStart != configuration.genQuantizedKVStart
            || previousServerCfg.genMaxKVSize != configuration.genMaxKVSize
            || previousServerCfg.genPrefillStepSize != configuration.genPrefillStepSize
            || previousServerCfg.modelEvictionPolicy != configuration.modelEvictionPolicy

        // Persist to disk
        ServerConfigurationStore.save(configuration)

        // Save Chat configuration (per-chat overrides)
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
            return max(1, min(10, v))
        }()

        // Parse work generation settings
        let parsedAgentTemp: Float? = {
            let s = tempAgentTemperature.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, let v = Float(s) else { return nil }
            return max(0.0, min(2.0, v))
        }()

        let parsedAgentMax: Int? = {
            let s = tempAgentMaxTokens.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, let v = Int(s) else { return nil }
            return max(1, v)
        }()

        let parsedAgentTopP: Float? = {
            let s = tempAgentTopP.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, let v = Float(s) else { return nil }
            return max(0.0, min(1.0, v))
        }()

        let parsedAgentMaxIterations: Int? = {
            let s = tempAgentMaxIterations.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, let v = Int(s) else { return nil }
            return max(1, min(100, v))
        }()

        // Preserve the existing defaultModel (auto-persisted via model picker)
        let existingDefaultModel = previousChatCfg.defaultModel
        let chatCfg = ChatConfiguration(
            hotkey: tempChatHotkey,
            systemPrompt: tempSystemPrompt,
            temperature: parsedTemp,
            maxTokens: parsedMax,
            contextLength: parsedContext,
            topPOverride: parsedTopP,
            maxToolAttempts: parsedMaxToolAttempts,
            defaultModel: existingDefaultModel,
            workTemperature: parsedAgentTemp,
            workMaxTokens: parsedAgentMax,
            workTopPOverride: parsedAgentTopP,
            workMaxIterations: parsedAgentMaxIterations
        )
        ChatConfigurationStore.save(chatCfg)

        let hotkeyChanged = previousChatCfg.hotkey != chatCfg.hotkey

        // Apply hotkey without relaunch (only if it changed)
        if hotkeyChanged {
            AppDelegate.shared?.applyChatHotkey()
        }

        // Apply login item state (only if it changed)
        if startAtLoginChanged {
            LoginItemService.shared.applyStartAtLogin(configuration.startAtLogin)
        }

        // Sync in-memory server configuration and restart only if needed
        Task { @MainActor in
            if serverConfigChanged {
                AppDelegate.shared?.serverController.configuration = configuration
            }
            if serverRestartNeeded {
                await AppDelegate.shared?.serverController.restartServer()
            }
        }

        // Show success toast
        showSuccess("Settings saved successfully")
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
            return max(1, min(20, v))
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

// MARK: - Reusable Settings Components

private struct SettingsSection<Content: View>: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header with icon and uppercase title
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.accentColor)

                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(themeManager.currentTheme.secondaryText)
                    .tracking(0.5)
            }

            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(themeManager.currentTheme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(themeManager.currentTheme.cardBorder, lineWidth: 1)
                )
        )
    }
}

private struct SettingsField<Content: View>: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let label: String
    var hint: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(themeManager.currentTheme.secondaryText)

            content()

            if let hint = hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
            }
        }
    }
}

private struct SettingsSubsection<Content: View>: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Subsection header
            HStack(spacing: 6) {
                Rectangle()
                    .fill(themeManager.currentTheme.accentColor)
                    .frame(width: 3, height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))

                Text(label.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                    .tracking(0.5)
            }

            content()
                .padding(.leading, 9)
        }
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
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(themeManager.currentTheme.secondaryText)

            ZStack(alignment: .topLeading) {
                // Themed placeholder overlay
                if text.isEmpty {
                    Text(placeholder)
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

            Text(hint)
                .font(.system(size: 11))
                .foregroundColor(themeManager.currentTheme.tertiaryText)
        }
    }
}

// MARK: - Styled Settings Text Field

private struct StyledSettingsTextField: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let label: String
    @Binding var text: String
    let placeholder: String
    let help: String

    @State private var isFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.secondaryText)

                Spacer()

                Text(help)
                    .font(.system(size: 10))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                ZStack(alignment: .leading) {
                    // Themed placeholder overlay
                    if text.isEmpty && !placeholder.isEmpty {
                        Text(placeholder)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(themeManager.currentTheme.placeholderText)
                            .allowsHitTesting(false)
                    }

                    TextField(
                        "",
                        text: $text,
                        onEditingChanged: { editing in
                            withAnimation(.easeOut(duration: 0.15)) {
                                isFocused = editing
                            }
                        }
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.primaryText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(themeManager.currentTheme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                isFocused
                                    ? themeManager.currentTheme.accentColor.opacity(0.5)
                                    : themeManager.currentTheme.inputBorder,
                                lineWidth: isFocused ? 1.5 : 1
                            )
                    )
            )
        }
    }
}

// MARK: - Settings Slider Field

private struct SettingsSliderField: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let label: String
    let help: String
    @Binding var text: String
    let range: ClosedRange<Float>
    let step: Float
    let defaultValue: Float
    let formatString: String

    @State private var sliderValue: Float = 0
    @State private var isInitialized = false

    private var effectiveValue: Float {
        if let v = Float(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return min(max(v, range.lowerBound), range.upperBound)
        }
        return defaultValue
    }

    private var displayValue: String {
        String(format: formatString, effectiveValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.secondaryText)

                Spacer()

                Text(help)
                    .font(.system(size: 10))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                    .lineLimit(1)
            }

            HStack(spacing: 12) {
                Text(String(format: formatString, range.lowerBound))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                    .frame(width: 28, alignment: .trailing)

                Slider(
                    value: $sliderValue,
                    in: range,
                    step: step
                )
                .tint(themeManager.currentTheme.accentColor)
                .onChange(of: sliderValue) { _, newValue in
                    guard isInitialized else { return }
                    text = String(format: formatString, newValue)
                }

                Text(String(format: formatString, range.upperBound))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                    .frame(width: 28, alignment: .leading)

                // Current value badge
                Text(displayValue)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.primaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(themeManager.currentTheme.inputBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                            )
                    )
                    .frame(width: 52)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(themeManager.currentTheme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                    )
            )
        }
        .onAppear {
            sliderValue = effectiveValue
            DispatchQueue.main.async {
                isInitialized = true
            }
        }
        .onChange(of: text) { _, _ in
            guard isInitialized else { return }
            let newEffective = effectiveValue
            if abs(sliderValue - newEffective) > step / 2 {
                sliderValue = newEffective
            }
        }
    }
}

// MARK: - Settings Stepper Field

private struct SettingsStepperField: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let label: String
    let help: String
    @Binding var text: String
    let range: ClosedRange<Int>
    let step: Int
    let defaultValue: Int

    @State private var isFocused = false

    private var effectiveValue: Int {
        if let v = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return min(max(v, range.lowerBound), range.upperBound)
        }
        return defaultValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.secondaryText)

                Spacer()

                Text(help)
                    .font(.system(size: 10))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                    .lineLimit(1)
            }

            HStack(spacing: 0) {
                ZStack(alignment: .leading) {
                    if text.isEmpty {
                        Text(String(defaultValue))
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(themeManager.currentTheme.placeholderText)
                            .allowsHitTesting(false)
                    }

                    TextField(
                        "",
                        text: $text,
                        onEditingChanged: { editing in
                            withAnimation(.easeOut(duration: 0.15)) {
                                isFocused = editing
                            }
                        }
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.primaryText)
                }
                .padding(.horizontal, 12)

                Divider()
                    .frame(height: 20)

                // Stepper buttons
                HStack(spacing: 0) {
                    Button(action: decrement) {
                        Image(systemName: "minus")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(
                                effectiveValue <= range.lowerBound
                                    ? themeManager.currentTheme.tertiaryText
                                    : themeManager.currentTheme.primaryText
                            )
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(effectiveValue <= range.lowerBound)

                    Divider()
                        .frame(height: 20)

                    Button(action: increment) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(
                                effectiveValue >= range.upperBound
                                    ? themeManager.currentTheme.tertiaryText
                                    : themeManager.currentTheme.primaryText
                            )
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(effectiveValue >= range.upperBound)
                }
            }
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(themeManager.currentTheme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                isFocused
                                    ? themeManager.currentTheme.accentColor.opacity(0.5)
                                    : themeManager.currentTheme.inputBorder,
                                lineWidth: isFocused ? 1.5 : 1
                            )
                    )
            )
        }
    }

    private func increment() {
        let newValue = min(effectiveValue + step, range.upperBound)
        text = String(newValue)
    }

    private func decrement() {
        let newValue = max(effectiveValue - step, range.lowerBound)
        text = String(newValue)
    }
}

private struct SettingsToggle: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let title: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(themeManager.currentTheme.primaryText)
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(themeManager.currentTheme.tertiaryText)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .toggleStyle(SwitchToggleStyle(tint: themeManager.currentTheme.accentColor))
                .labelsHidden()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(themeManager.currentTheme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                )
        )
    }
}

private struct SettingsDivider: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        Rectangle()
            .fill(themeManager.currentTheme.cardBorder)
            .frame(height: 1)
    }
}

private struct SettingsButtonStyle: ButtonStyle {
    @ObservedObject private var themeManager = ThemeManager.shared
    let isPrimary: Bool

    init(isPrimary: Bool = false) {
        self.isPrimary = isPrimary
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(isPrimary ? .white : themeManager.currentTheme.primaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isPrimary ? themeManager.currentTheme.accentColor : themeManager.currentTheme.tertiaryBackground
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isPrimary ? Color.clear : themeManager.currentTheme.inputBorder, lineWidth: 1)
                    )
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
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
                Text("Configure voice settings directly in the Voice tab.")
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
                            Text("Open Voice Tab")
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

// MARK: - Work Settings Section

private struct AgentSettingsSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var refreshId = UUID()

    @Binding var workTemperature: String
    @Binding var workMaxTokens: String
    @Binding var agentTopP: String
    @Binding var workMaxIterations: String

    // (name, display, desc, destructive, defaultPolicy)
    private static let folderTools:
        [(name: String, display: String, desc: String, destructive: Bool, defaultPolicy: ToolPermissionPolicy)] = [
            ("file_write", "Write Files", "Create and modify files", false, .auto),
            ("file_move", "Move Files", "Move files and directories", false, .auto),
            ("file_copy", "Copy Files", "Copy files and directories", false, .auto),
            ("file_delete", "Delete Files", "Delete files and directories", true, .ask),
            ("dir_create", "Create Directories", "Create new directories", false, .auto),
            ("file_edit", "Edit Files", "Edit file content with search/replace", false, .auto),
            ("shell_run", "Run Shell Commands", "Execute shell commands in the folder", true, .ask),
            ("git_commit", "Git Commit", "Commit changes to git repository", true, .ask),
            ("batch", "Batch Operations", "Execute multiple tool operations in sequence", false, .ask),
        ]

    var body: some View {
        SettingsSection(title: "Work", icon: "cpu") {
            VStack(alignment: .leading, spacing: 16) {
                // Generation Settings
                SettingsSubsection(label: "Generation") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Controls how the AI reasons and calls tools. Lower temperature improves reliability.")
                            .font(.system(size: 12))
                            .foregroundColor(themeManager.currentTheme.secondaryText)

                        SettingsSliderField(
                            label: "Temperature",
                            help: "Lower = more reliable tool use",
                            text: $workTemperature,
                            range: 0 ... 2,
                            step: 0.1,
                            defaultValue: 0.3,
                            formatString: "%.1f"
                        )
                        SettingsStepperField(
                            label: "Max Tokens",
                            help: "Tokens per work iteration",
                            text: $workMaxTokens,
                            range: 1 ... 65536,
                            step: 512,
                            defaultValue: 4096
                        )
                        SettingsSliderField(
                            label: "Top P Override",
                            help: "Sampling diversity (0–1)",
                            text: $agentTopP,
                            range: 0 ... 1,
                            step: 0.05,
                            defaultValue: 1.0,
                            formatString: "%.2f"
                        )
                        SettingsStepperField(
                            label: "Max Iterations",
                            help: "Max reasoning loop iterations",
                            text: $workMaxIterations,
                            range: 1 ... 100,
                            step: 5,
                            defaultValue: 30
                        )
                    }
                }

                SettingsDivider()

                // Permissions
                SettingsSubsection(label: "Permissions") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Control how work folder tools execute when working with folders in Work mode.")
                            .font(.system(size: 12))
                            .foregroundColor(themeManager.currentTheme.secondaryText)

                        VStack(spacing: 0) {
                            ForEach(Self.folderTools, id: \.name) { tool in
                                AgentToolPermissionRow(
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
                                    Text("Reset All to Default")
                                        .font(.system(size: 12, weight: .medium))
                                }
                            }
                            .buttonStyle(SettingsButtonStyle())
                            .help("Reset all work tool permissions to default")
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

// MARK: - Work Tool Permission Row

private struct AgentToolPermissionRow: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var isHovered = false

    let name: String
    let displayName: String
    let description: String
    let isDestructive: Bool
    let defaultPolicy: ToolPermissionPolicy
    let onPolicyChange: () -> Void

    /// Returns the configured policy, or nil if using default
    private var configuredPolicy: ToolPermissionPolicy? {
        ToolConfigurationStore.load().policy[name]
    }

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
                Text(description)
                    .font(.system(size: 10))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
            }

            Spacer()

            Picker(
                "",
                selection: Binding(
                    get: { effectivePolicy },
                    set: { newValue in
                        ToolRegistry.shared.setPolicy(newValue, for: name)
                        onPolicyChange()
                    }
                )
            ) {
                Text("Auto").tag(ToolPermissionPolicy.auto)
                Text("Ask").tag(ToolPermissionPolicy.ask)
                Text("Deny").tag(ToolPermissionPolicy.deny)
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isHovered ? themeManager.currentTheme.tertiaryBackground.opacity(0.5) : Color.clear)
        .onHover { isHovered = $0 }
    }
}
