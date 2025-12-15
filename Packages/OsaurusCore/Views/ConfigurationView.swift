import SwiftUI

// MARK: - Configuration View
struct ConfigurationView: View {
    @StateObject private var themeManager = ThemeManager.shared

    /// Use computed property to always get the current theme from ThemeManager
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var tempPortString: String = ""
    @State private var tempExposeToNetwork: Bool = false
    @State private var tempStartAtLogin: Bool = false
    @State private var cliInstallMessage: String? = nil
    @State private var cliInstallSuccess: Bool = false
    @State private var hasAppeared = false
    @State private var showSaveConfirmation = false
    @State private var showResetConfirmation = false

    // Chat settings state
    @State private var tempChatHotkey: Hotkey? = nil
    @State private var tempDefaultModel: String? = nil
    @State private var tempSystemPrompt: String = ""
    @State private var tempChatTemperature: String = ""
    @State private var tempChatMaxTokens: String = ""
    @State private var tempChatTopP: String = ""
    @State private var tempChatMaxToolAttempts: String = ""
    @State private var tempChatAlwaysOnTop: Bool = false
    @State private var availableModels: [ModelOption] = []

    // Server settings state
    @State private var tempAllowedOrigins: String = ""

    // Performance settings state
    @State private var tempTopP: String = ""
    @State private var tempKVBits: String = ""
    @State private var tempKVGroup: String = ""
    @State private var tempQuantStart: String = ""
    @State private var tempMaxKV: String = ""
    @State private var tempPrefillStep: String = ""

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
        let query = searchText.lowercased()
        return texts.contains { $0.lowercased().contains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            // Scrollable content area
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // MARK: - Chat Section
                    if matchesSearch(
                        "Chat",
                        "Hotkey",
                        "Model",
                        "System Prompt",
                        "Temperature",
                        "Max Tokens",
                        "Top P",
                        "Tools",
                        "Always on Top",
                        "Generation"
                    ) {
                        SettingsSection(title: "Chat", icon: "message") {
                            VStack(alignment: .leading, spacing: 20) {
                                // Global Hotkey
                                SettingsField(label: "Global Hotkey") {
                                    HotkeyRecorder(value: $tempChatHotkey)
                                }

                                // Default Model
                                SettingsField(
                                    label: "Default Model",
                                    hint: "Model used for new chat sessions"
                                ) {
                                    DefaultModelPicker(
                                        selection: $tempDefaultModel,
                                        models: availableModels
                                    )
                                }

                                // System Prompt
                                SettingsField(label: "System Prompt") {
                                    ZStack(alignment: .topLeading) {
                                        TextEditor(text: $tempSystemPrompt)
                                            .font(.system(size: 13, design: .monospaced))
                                            .scrollContentBackground(.hidden)
                                            .frame(minHeight: 80, maxHeight: 140)
                                            .padding(8)
                                            .background(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .fill(theme.inputBackground)
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 8)
                                                            .stroke(theme.inputBorder, lineWidth: 1)
                                                    )
                                            )
                                            .foregroundColor(theme.primaryText)
                                        if tempSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                            Text("Optional. Shown as a system message for all chats.")
                                                .font(.system(size: 11))
                                                .foregroundColor(theme.secondaryText)
                                                .padding(.top, 12)
                                                .padding(.leading, 14)
                                                .allowsHitTesting(false)
                                        }
                                    }
                                }

                                // Generation Settings
                                SettingsSubsection(label: "Generation") {
                                    VStack(spacing: 12) {
                                        settingsTextField(
                                            label: "Temperature",
                                            text: $tempChatTemperature,
                                            placeholder: "0.7",
                                            help: "Randomness (0–2). Values > 0.8 may cause erratic output"
                                        )
                                        settingsTextField(
                                            label: "Max Tokens",
                                            text: $tempChatMaxTokens,
                                            placeholder: "16384",
                                            help: "Maximum response tokens. Empty uses default 16384"
                                        )
                                        settingsTextField(
                                            label: "Top P Override",
                                            text: $tempChatTopP,
                                            placeholder: "",
                                            help: "Override server Top P (0–1). Empty uses server default"
                                        )
                                    }
                                }

                                // Tools Settings
                                SettingsSubsection(label: "Tools") {
                                    settingsTextField(
                                        label: "Max Tool Attempts",
                                        text: $tempChatMaxToolAttempts,
                                        placeholder: "",
                                        help: "Max consecutive tool calls (1–10). Empty uses no limit"
                                    )
                                }

                                Divider()
                                    .background(theme.primaryBorder)

                                // Window Settings
                                SettingsToggle(
                                    title: "Always on Top",
                                    description: "Keep chat window above other windows",
                                    isOn: $tempChatAlwaysOnTop
                                )
                            }
                        }
                    }

                    // MARK: - Server Section
                    if matchesSearch("Server", "Port", "Network", "Expose", "CORS", "Origins", "Allowed Origins") {
                        SettingsSection(title: "Server", icon: "network") {
                            VStack(alignment: .leading, spacing: 20) {
                                // Port
                                SettingsField(label: "Port", hint: "Enter a port number between 1 and 65535") {
                                    ZStack(alignment: .leading) {
                                        if tempPortString.isEmpty {
                                            Text("1337")
                                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                                .foregroundColor(theme.secondaryText)
                                                .padding(.leading, 12)
                                                .allowsHitTesting(false)
                                        }
                                        TextField("", text: $tempPortString)
                                            .textFieldStyle(.plain)
                                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .foregroundColor(theme.primaryText)
                                    }
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(theme.inputBackground)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .stroke(theme.inputBorder, lineWidth: 1)
                                            )
                                    )
                                }

                                // Network Exposure Toggle
                                SettingsToggle(
                                    title: "Expose to Network",
                                    description: "Allow devices on your network to connect",
                                    isOn: $tempExposeToNetwork
                                )

                                // CORS Settings
                                SettingsField(
                                    label: "Allowed Origins",
                                    hint: "Comma-separated list. Use * for any origin, or leave empty to disable CORS"
                                ) {
                                    ZStack(alignment: .leading) {
                                        if tempAllowedOrigins.isEmpty {
                                            Text("https://example.com, https://app.localhost")
                                                .font(.system(size: 13, design: .monospaced))
                                                .foregroundColor(theme.secondaryText)
                                                .padding(.leading, 12)
                                                .allowsHitTesting(false)
                                        }
                                        TextField("", text: $tempAllowedOrigins)
                                            .textFieldStyle(.plain)
                                            .font(.system(size: 13, design: .monospaced))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .foregroundColor(theme.primaryText)
                                    }
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
                        }
                    }

                    // MARK: - System Section
                    if matchesSearch("System", "Login", "Start at Login", "CLI", "Command Line", "Install", "Symlink") {
                        SettingsSection(title: "System", icon: "gear") {
                            VStack(alignment: .leading, spacing: 20) {
                                // Start at Login
                                SettingsToggle(
                                    title: "Start at Login",
                                    description: "Launch Osaurus when you sign in",
                                    isOn: $tempStartAtLogin
                                )

                                Divider()
                                    .background(theme.primaryBorder)

                                // Command Line Tool
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Command Line Tool")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(theme.secondaryText)

                                    Text("Install the `osaurus` CLI into your PATH for terminal access.")
                                        .font(.system(size: 12))
                                        .foregroundColor(theme.tertiaryText)

                                    HStack(spacing: 12) {
                                        Button(action: { installCLI() }) {
                                            Text("Install CLI")
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundColor(theme.primaryText)
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 8)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .fill(theme.tertiaryBackground)
                                                        .overlay(
                                                            RoundedRectangle(cornerRadius: 8)
                                                                .stroke(theme.inputBorder, lineWidth: 1)
                                                        )
                                                )
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        .help("Create a symlink to the embedded CLI")

                                        if let message = cliInstallMessage {
                                            HStack(spacing: 6) {
                                                Image(
                                                    systemName: cliInstallSuccess
                                                        ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
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

                                Divider()
                                    .background(theme.primaryBorder)

                                // Storage
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Storage")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(theme.secondaryText)

                                    DirectoryPickerView()
                                }
                            }
                        }
                    }

                    // MARK: - Performance Section
                    if matchesSearch(
                        "Performance",
                        "Top P",
                        "KV Cache",
                        "Quantization",
                        "Prefill",
                        "Max KV",
                        "CPU",
                        "Memory"
                    ) {
                        SettingsSection(title: "Performance", icon: "cpu") {
                            VStack(spacing: 12) {
                                settingsTextField(
                                    label: "Top P",
                                    text: $tempTopP,
                                    placeholder: "1.0",
                                    help: "Controls diversity of generated text (0–1). Empty uses default 1.0"
                                )
                                settingsTextField(
                                    label: "KV Cache Bits",
                                    text: $tempKVBits,
                                    placeholder: "",
                                    help: "Quantization bits for KV cache. Empty disables quantization"
                                )
                                settingsTextField(
                                    label: "KV Group Size",
                                    text: $tempKVGroup,
                                    placeholder: "64",
                                    help: "Group size for KV quantization. Empty uses default 64"
                                )
                                settingsTextField(
                                    label: "Quantized KV Start",
                                    text: $tempQuantStart,
                                    placeholder: "0",
                                    help: "Starting layer for KV quantization. Empty uses default 0"
                                )
                                settingsTextField(
                                    label: "Max KV Size",
                                    text: $tempMaxKV,
                                    placeholder: "",
                                    help: "Maximum KV cache size in tokens. Empty uses unlimited"
                                )
                                settingsTextField(
                                    label: "Prefill Step Size",
                                    text: $tempPrefillStep,
                                    placeholder: "512",
                                    help: "Step size for prefill operations. Empty uses default 512"
                                )
                            }
                        }
                    }

                    // MARK: - System Permissions Section
                    if matchesSearch("Permissions", "Accessibility", "Automation", "Privacy", "Security") {
                        SystemPermissionsSection()
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
                .frame(maxWidth: 700)
            }
            .opacity(hasAppeared ? 1 : 0)
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

    // MARK: - Header View

    private var headerView: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(theme.primaryText)

                    Text("Configure your server and chat settings")
                        .font(.system(size: 14))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()

                HStack(spacing: 12) {
                    Button(action: resetToDefaults) {
                        HStack(spacing: 6) {
                            if showResetConfirmation {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .semibold))
                            } else {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            Text(showResetConfirmation ? "Reset" : "Reset to Defaults")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundColor(showResetConfirmation ? .white : theme.secondaryText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(showResetConfirmation ? theme.warningColor : theme.tertiaryBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(theme.inputBorder, lineWidth: showResetConfirmation ? 0 : 1)
                                )
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Reset all settings to recommended defaults")

                    Button(action: saveConfiguration) {
                        HStack(spacing: 6) {
                            if showSaveConfirmation {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            Text(showSaveConfirmation ? "Saved" : "Save Changes")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(showSaveConfirmation ? Color.green : theme.accentColor)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .background(theme.secondaryBackground)
    }

    // MARK: - Settings Text Field

    @ViewBuilder
    private func settingsTextField(
        label: String,
        text: Binding<String>,
        placeholder: String,
        help: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)

                Spacer()

                Text(help)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
            }

            ZStack(alignment: .leading) {
                // Custom placeholder for better visibility in light mode
                if text.wrappedValue.isEmpty && !placeholder.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                        .padding(.leading, 12)
                        .allowsHitTesting(false)
                }
                TextField("", text: text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundColor(theme.primaryText)
            }
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

    // MARK: - Configuration Loading

    private func loadConfiguration() {
        let configuration = ServerConfigurationStore.load() ?? ServerConfiguration.default
        tempPortString = String(configuration.port)
        tempExposeToNetwork = configuration.exposeToNetwork
        tempStartAtLogin = configuration.startAtLogin

        let chat = ChatConfigurationStore.load()
        tempChatHotkey = chat.hotkey
        tempDefaultModel = chat.defaultModel
        tempSystemPrompt = chat.systemPrompt
        tempChatTemperature = chat.temperature.map { String($0) } ?? ""
        tempChatMaxTokens = chat.maxTokens.map(String.init) ?? ""
        tempChatTopP = chat.topPOverride.map { String($0) } ?? ""
        tempChatMaxToolAttempts = chat.maxToolAttempts.map(String.init) ?? ""
        tempChatAlwaysOnTop = chat.alwaysOnTop

        // Load available models for the default model picker
        availableModels = buildAvailableModels()

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
        tempAllowedOrigins = ""

        // Chat settings - clear overrides to use defaults
        tempChatHotkey = chatDefaults.hotkey
        tempDefaultModel = nil
        tempSystemPrompt = ""
        tempChatTemperature = ""
        tempChatMaxTokens = ""
        tempChatTopP = ""
        tempChatMaxToolAttempts = ""
        tempChatAlwaysOnTop = chatDefaults.alwaysOnTop

        // Performance settings - clear to use defaults
        tempTopP = ""
        tempKVBits = ""
        tempKVGroup = ""
        tempQuantStart = ""
        tempMaxKV = ""
        tempPrefillStep = ""

        // Show confirmation
        withAnimation(.easeInOut(duration: 0.2)) {
            showResetConfirmation = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.2)) {
                showResetConfirmation = false
            }
        }
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

        // Save performance settings
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

        let chatCfg = ChatConfiguration(
            hotkey: tempChatHotkey,
            systemPrompt: tempSystemPrompt,
            temperature: parsedTemp,
            maxTokens: parsedMax,
            topPOverride: parsedTopP,
            maxToolAttempts: parsedMaxToolAttempts,
            alwaysOnTop: tempChatAlwaysOnTop,
            defaultModel: tempDefaultModel
        )
        ChatConfigurationStore.save(chatCfg)

        let hotkeyChanged = previousChatCfg.hotkey != chatCfg.hotkey
        let alwaysOnTopChanged = previousChatCfg.alwaysOnTop != chatCfg.alwaysOnTop

        // Apply hotkey without relaunch (only if it changed)
        if hotkeyChanged {
            AppDelegate.shared?.applyChatHotkey()
        }

        // Apply chat window level immediately (only if it changed)
        if alwaysOnTopChanged {
            AppDelegate.shared?.applyChatWindowLevel()
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

        // Show confirmation
        withAnimation(.easeInOut(duration: 0.2)) {
            showSaveConfirmation = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.easeInOut(duration: 0.2)) {
                showSaveConfirmation = false
            }
        }
    }
}

// MARK: - Model Helper
extension ConfigurationView {
    /// Build available models list for the default model picker
    private func buildAvailableModels() -> [ModelOption] {
        var options: [ModelOption] = []

        // Add foundation model if available
        if FoundationModelService.isDefaultModelAvailable() {
            options.append(.foundation())
        }

        // Add local MLX models
        let localModels = ModelManager.discoverLocalModels()
        for model in localModels {
            options.append(.fromMLXModel(model))
        }

        // Add remote provider models
        let remoteModels = RemoteProviderManager.shared.cachedAvailableModels()
        for providerInfo in remoteModels {
            for modelId in providerInfo.models {
                options.append(
                    .fromRemoteModel(
                        modelId: modelId,
                        providerName: providerInfo.providerName,
                        providerId: providerInfo.providerId
                    )
                )
            }
        }

        return options
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

// MARK: - Reusable Settings Components

private struct SettingsSection<Content: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.primaryText)

            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.secondaryBackground)
        )
    }
}

private struct SettingsField<Content: View>: View {
    @Environment(\.theme) private var theme
    let label: String
    var hint: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.secondaryText)

            content()

            if let hint = hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
        }
    }
}

private struct SettingsSubsection<Content: View>: View {
    @Environment(\.theme) private var theme
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.secondaryText)

            content()
        }
    }
}

private struct SettingsToggle: View {
    @Environment(\.theme) private var theme
    let title: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.primaryText)
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.tertiaryText)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                .labelsHidden()
        }
    }
}

// MARK: - System Permissions Section

private struct SystemPermissionsSection: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var permissionService = SystemPermissionService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("System Permissions", systemImage: "lock.shield")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.primaryText)

            Text(
                "Some plugins require additional system permissions to function. Grant permissions below to enable advanced features."
            )
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                ForEach(SystemPermission.allCases, id: \.rawValue) { permission in
                    SystemPermissionRow(permission: permission)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.secondaryBackground)
        )
        .onAppear {
            permissionService.startPeriodicRefresh(interval: 2.0)
        }
        .onDisappear {
            permissionService.stopPeriodicRefresh()
        }
    }
}

// MARK: - System Permission Row

private struct SystemPermissionRow: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var permissionService = SystemPermissionService.shared
    let permission: SystemPermission

    private var isGranted: Bool {
        permissionService.permissionStates[permission] ?? false
    }

    var body: some View {
        HStack(spacing: 12) {
            // Permission icon
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isGranted ? theme.successColor.opacity(0.1) : theme.tertiaryBackground)
                Image(systemName: permission.systemIconName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(isGranted ? theme.successColor : theme.secondaryText)
            }
            .frame(width: 36, height: 36)

            // Permission info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(permission.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)

                    // Status badge
                    Text(isGranted ? "Granted" : "Not Granted")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(isGranted ? theme.successColor : theme.warningColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(isGranted ? theme.successColor.opacity(0.1) : theme.warningColor.opacity(0.1))
                        )
                }

                Text(permission.description)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(2)
            }

            Spacer()

            // Action button
            if isGranted {
                Button(action: {
                    permissionService.openSystemSettings(for: permission)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "gear")
                            .font(.system(size: 11))
                        Text("Settings")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(theme.tertiaryBackground)
                    )
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                Button(action: {
                    permissionService.requestPermission(permission)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "hand.raised")
                            .font(.system(size: 11))
                        Text("Grant")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(theme.accentColor)
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isGranted ? theme.successColor.opacity(0.3) : theme.inputBorder, lineWidth: 1)
                )
        )
    }
}

// MARK: - Default Model Picker

private struct DefaultModelPicker: View {
    @Environment(\.theme) private var theme
    @Binding var selection: String?
    let models: [ModelOption]

    private var displayName: String {
        if let selected = selection,
            let model = models.first(where: { $0.id == selected })
        {
            return model.displayName
        }
        return "Auto (first available)"
    }

    var body: some View {
        Menu {
            // Auto option (nil selection)
            Button(action: { selection = nil }) {
                HStack {
                    Text("Auto (first available)")
                    if selection == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            // Group models by source
            let grouped = models.groupedBySource()
            ForEach(grouped, id: \.source.displayName) { group in
                Section(group.source.displayName) {
                    ForEach(group.models) { model in
                        Button(action: { selection = model.id }) {
                            HStack {
                                Text(model.displayName)
                                if selection == model.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack {
                Text(displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Spacer()

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )
        }
        .menuStyle(.borderlessButton)
    }
}
