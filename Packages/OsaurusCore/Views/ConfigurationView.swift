import SwiftUI

// MARK: - Configuration View
struct ConfigurationView: View {
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var personaManager = PersonaManager.shared

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
    @State private var tempDefaultPersonaId: UUID = Persona.defaultId
    @State private var tempSystemPrompt: String = ""
    @State private var tempChatTemperature: String = ""
    @State private var tempChatMaxTokens: String = ""
    @State private var tempChatContextLength: String = ""
    @State private var tempChatTopP: String = ""
    @State private var tempChatMaxToolAttempts: String = ""

    // Server settings state
    @State private var tempAllowedOrigins: String = ""

    // Performance settings state
    @State private var tempTopP: String = ""
    @State private var tempKVBits: String = ""
    @State private var tempKVGroup: String = ""
    @State private var tempQuantStart: String = ""
    @State private var tempMaxKV: String = ""
    @State private var tempPrefillStep: String = ""
    @State private var tempEvictionPolicy: ModelEvictionPolicy = .strictSingleModel

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
                        // MARK: - Chat Section
                        if matchesSearch(
                            "Chat",
                            "Hotkey",
                            "Model",
                            "Persona",
                            "System Prompt",
                            "Temperature",
                            "Max Tokens",
                            "Context Length",
                            "Top P",
                            "Tools",
                            "Tool Call",
                            "Generation"
                        ) {
                            SettingsSection(title: "Chat", icon: "message") {
                                VStack(alignment: .leading, spacing: 20) {
                                    // Global Hotkey
                                    SettingsField(label: "Global Hotkey") {
                                        HotkeyRecorder(value: $tempChatHotkey)
                                    }

                                    // Default Persona
                                    SettingsField(
                                        label: "Default Persona",
                                        hint: "Persona to use when opening chat"
                                    ) {
                                        DefaultPersonaPicker(
                                            selection: $tempDefaultPersonaId,
                                            personas: personaManager.personas
                                        )
                                    }

                                    // System Prompt
                                    StyledSettingsTextArea(
                                        label: "System Prompt",
                                        text: $tempSystemPrompt,
                                        placeholder: "Enter instructions for all chats...",
                                        hint: "Optional. Shown as a system message for all chats."
                                    )

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
                                                label: "Context Length",
                                                text: $tempChatContextLength,
                                                placeholder: "128000",
                                                help:
                                                    "Assumed context window for remote models. Empty uses default 128k"
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

                                }
                            }
                        }

                        // MARK: - Server Section
                        if matchesSearch("Server", "Port", "Network", "Expose", "CORS", "Origins", "Allowed Origins") {
                            SettingsSection(title: "Server", icon: "network") {
                                VStack(alignment: .leading, spacing: 20) {
                                    // Port
                                    StyledSettingsTextField(
                                        label: "Port",
                                        text: $tempPortString,
                                        placeholder: "1337",
                                        help: "Enter a port number between 1 and 65535"
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

                        // MARK: - System Section
                        if matchesSearch(
                            "System",
                            "Login",
                            "Start at Login",
                            "CLI",
                            "Command Line",
                            "Install",
                            "Symlink"
                        ) {
                            SettingsSection(title: "System", icon: "gear") {
                                VStack(alignment: .leading, spacing: 20) {
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
                                VStack(alignment: .leading, spacing: 20) {
                                    // Generation
                                    SettingsSubsection(label: "Generation") {
                                        VStack(spacing: 12) {
                                            settingsTextField(
                                                label: "Top P",
                                                text: $tempTopP,
                                                placeholder: "1.0",
                                                help:
                                                    "Controls diversity of generated text (0–1). Empty uses default 1.0"
                                            )
                                        }
                                    }

                                    // KV Cache Settings
                                    SettingsSubsection(label: "KV Cache") {
                                        VStack(spacing: 12) {
                                            settingsTextField(
                                                label: "Cache Bits",
                                                text: $tempKVBits,
                                                placeholder: "",
                                                help: "Quantization bits for KV cache. Empty disables quantization"
                                            )
                                            settingsTextField(
                                                label: "Group Size",
                                                text: $tempKVGroup,
                                                placeholder: "64",
                                                help: "Group size for KV quantization. Empty uses default 64"
                                            )
                                            settingsTextField(
                                                label: "Quantized Start",
                                                text: $tempQuantStart,
                                                placeholder: "0",
                                                help: "Starting layer for KV quantization. Empty uses default 0"
                                            )
                                            settingsTextField(
                                                label: "Max Size",
                                                text: $tempMaxKV,
                                                placeholder: "8192",
                                                help: "Maximum KV cache size in tokens. Empty uses default 8192"
                                            )
                                            settingsTextField(
                                                label: "Prefill Step",
                                                text: $tempPrefillStep,
                                                placeholder: "512",
                                                help: "Step size for prefill operations. Empty uses default 512"
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
                        if matchesSearch("Voice", "Whisper", "Transcription", "Model", "Language", "Speech") {
                            VoiceSettingsSection()
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

            // Success toast overlay
            if let message = successMessage {
                VStack {
                    Spacer()
                    successToast(message)
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

    private func successToast(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundColor(theme.successColor)

            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.primaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Capsule()
                .fill(theme.cardBackground)
                .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 4)
        )
        .overlay(
            Capsule()
                .stroke(theme.successColor.opacity(0.3), lineWidth: 1)
        )
    }

    private func showSuccess(_ message: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            successMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeOut(duration: 0.2)) {
                successMessage = nil
            }
        }
    }

    // MARK: - Header View

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: "Settings",
            subtitle: "Configure your server and chat settings"
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

    // MARK: - Settings Text Field

    @ViewBuilder
    private func settingsTextField(
        label: String,
        text: Binding<String>,
        placeholder: String,
        help: String
    ) -> some View {
        StyledSettingsTextField(label: label, text: text, placeholder: placeholder, help: help)
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
        tempDefaultPersonaId = personaManager.activePersonaId
        tempSystemPrompt = chat.systemPrompt
        tempChatTemperature = chat.temperature.map { String($0) } ?? ""
        tempChatMaxTokens = chat.maxTokens.map(String.init) ?? ""
        tempChatContextLength = chat.contextLength.map(String.init) ?? ""
        tempChatTopP = chat.topPOverride.map { String($0) } ?? ""
        tempChatMaxToolAttempts = chat.maxToolAttempts.map(String.init) ?? ""

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
        tempDefaultPersonaId = Persona.defaultId
        tempSystemPrompt = ""
        tempChatTemperature = ""
        tempChatMaxTokens = ""
        tempChatContextLength = ""
        tempChatTopP = ""
        tempChatMaxToolAttempts = ""

        // Performance settings - clear to use defaults
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
            defaultModel: existingDefaultModel
        )
        ChatConfigurationStore.save(chatCfg)

        // Save default persona setting
        let previousPersonaId = personaManager.activePersonaId
        if tempDefaultPersonaId != previousPersonaId {
            personaManager.setActivePersona(tempDefaultPersonaId)
        }

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

// MARK: - Reusable Settings Components

private struct SettingsSection<Content: View>: View {
    @StateObject private var themeManager = ThemeManager.shared

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
    @StateObject private var themeManager = ThemeManager.shared

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
    @StateObject private var themeManager = ThemeManager.shared

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
    @StateObject private var themeManager = ThemeManager.shared

    let label: String
    @Binding var text: String
    let placeholder: String
    let hint: String

    @State private var isFocused = false

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
    @StateObject private var themeManager = ThemeManager.shared

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

private struct SettingsToggle: View {
    @StateObject private var themeManager = ThemeManager.shared

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
    @StateObject private var themeManager = ThemeManager.shared

    var body: some View {
        Rectangle()
            .fill(themeManager.currentTheme.cardBorder)
            .frame(height: 1)
    }
}

private struct SettingsButtonStyle: ButtonStyle {
    @StateObject private var themeManager = ThemeManager.shared
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
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var modelManager = WhisperModelManager.shared
    @StateObject private var whisperService = WhisperKitService.shared

    @State private var tempWordTimestamps: Bool = false
    @State private var hasLoadedConfig = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header with icon and uppercase title
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.accentColor)

                Text("VOICE (ADVANCED)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(themeManager.currentTheme.secondaryText)
                    .tracking(0.5)
            }

            VStack(alignment: .leading, spacing: 20) {
                // Info text
                Text("Configure voice settings directly in the Voice tab. Advanced options below.")
                    .font(.system(size: 12))
                    .foregroundColor(themeManager.currentTheme.secondaryText)

                // Advanced Options - Word Timestamps
                SettingsToggle(
                    title: "Word Timestamps",
                    description: "Include word-level timing in transcription results",
                    isOn: $tempWordTimestamps
                )
                .onChange(of: tempWordTimestamps) { _, _ in
                    saveVoiceConfig()
                }

                // Status info
                HStack(spacing: 12) {
                    // Model status
                    HStack(spacing: 6) {
                        if whisperService.isLoadingModel {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 8, height: 8)
                        } else {
                            Circle()
                                .fill(
                                    whisperService.isModelLoaded
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
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(themeManager.currentTheme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(themeManager.currentTheme.cardBorder, lineWidth: 1)
                )
        )
        .onAppear {
            if !hasLoadedConfig {
                loadVoiceConfig()
                hasLoadedConfig = true
            }
        }
    }

    private var modelStatusText: String {
        if whisperService.isLoadingModel {
            return "Loading model..."
        } else if whisperService.isModelLoaded {
            if let modelId = whisperService.loadedModelId,
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

    private func loadVoiceConfig() {
        let config = WhisperConfigurationStore.load()
        tempWordTimestamps = config.wordTimestamps
    }

    private func saveVoiceConfig() {
        var config = WhisperConfigurationStore.load()
        config.wordTimestamps = tempWordTimestamps
        WhisperConfigurationStore.save(config)
    }
}

// MARK: - Voice Settings Subsection

private struct VoiceSettingsSubsection<Content: View>: View {
    @StateObject private var themeManager = ThemeManager.shared

    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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

// MARK: - Voice Settings Text Field

private struct VoiceSettingsTextField: View {
    @StateObject private var themeManager = ThemeManager.shared

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

// MARK: - Voice Model Picker

private struct VoiceModelPicker: View {
    @StateObject private var themeManager = ThemeManager.shared
    @Binding var selection: String
    let models: [WhisperModel]

    @State private var isHovered = false

    private var displayName: String {
        if let model = models.first(where: { $0.id == selection }) {
            return model.name
        }
        return "Select a model"
    }

    var body: some View {
        Menu {
            if models.isEmpty {
                Text("No models downloaded")
                    .foregroundColor(.secondary)
            } else {
                ForEach(models) { model in
                    Button(action: { selection = model.id }) {
                        HStack {
                            Text(model.name)
                            if model.isRecommended {
                                Text("Recommended")
                                    .foregroundColor(.secondary)
                            }
                            if selection == model.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.accentColor)

                Text(displayName)
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
}

// MARK: - Voice Input Device Picker

private struct VoiceInputDevicePicker: View {
    @StateObject private var themeManager = ThemeManager.shared
    @Binding var selection: String?
    let devices: [AudioInputDevice]

    @State private var isHovered = false

    private var displayName: String {
        if let selectedId = selection,
            let device = devices.first(where: { $0.id == selectedId })
        {
            return device.name
        }
        return "System Default"
    }

    var body: some View {
        Menu {
            // System Default option
            Button(action: { selection = nil }) {
                HStack {
                    Text("System Default")
                    if selection == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            // Available devices
            ForEach(devices) { device in
                Button(action: { selection = device.id }) {
                    HStack {
                        Text(device.name)
                        if device.isDefault {
                            Text("(Default)")
                                .foregroundColor(.secondary)
                        }
                        if selection == device.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.accentColor)

                Text(displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.primaryText)
                    .lineLimit(1)

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
}

// MARK: - System Permissions Section

private struct SystemPermissionsSection: View {
    @StateObject private var themeManager = ThemeManager.shared
    @ObservedObject private var permissionService = SystemPermissionService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header with icon and uppercase title
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.accentColor)

                Text("SYSTEM PERMISSIONS")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(themeManager.currentTheme.secondaryText)
                    .tracking(0.5)
            }

            Text(
                "Some plugins require additional system permissions to function. Grant permissions below to enable advanced features."
            )
            .font(.system(size: 12))
            .foregroundColor(themeManager.currentTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                ForEach(SystemPermission.allCases, id: \.rawValue) { permission in
                    SystemPermissionRow(permission: permission)
                }
            }
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
    @StateObject private var themeManager = ThemeManager.shared
    @ObservedObject private var permissionService = SystemPermissionService.shared
    let permission: SystemPermission

    @State private var isTesting = false
    @State private var testResult: String? = nil
    @State private var isHovered = false

    private var isGranted: Bool {
        permissionService.permissionStates[permission] ?? false
    }

    // Only automation permissions support the diagnostic test
    private var canTest: Bool {
        permission == .automation || permission == .automationCalendar || permission == .contacts
            || permission == .calendar || permission == .reminders || permission == .location || permission == .notes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                // Permission icon with gradient background
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(
                            LinearGradient(
                                colors: isGranted
                                    ? [
                                        themeManager.currentTheme.successColor.opacity(0.15),
                                        themeManager.currentTheme.successColor.opacity(0.05),
                                    ]
                                    : [
                                        themeManager.currentTheme.tertiaryBackground,
                                        themeManager.currentTheme.tertiaryBackground.opacity(0.8),
                                    ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: permission.systemIconName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(
                            isGranted ? themeManager.currentTheme.successColor : themeManager.currentTheme.secondaryText
                        )
                }
                .frame(width: 40, height: 40)

                // Permission info
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(permission.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(themeManager.currentTheme.primaryText)

                        // Status badge
                        Text(isGranted ? "Granted" : "Not Granted")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(
                                isGranted
                                    ? themeManager.currentTheme.successColor : themeManager.currentTheme.warningColor
                            )
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(
                                        isGranted
                                            ? themeManager.currentTheme.successColor.opacity(0.1)
                                            : themeManager.currentTheme.warningColor.opacity(0.1)
                                    )
                            )
                    }

                    Text(permission.description)
                        .font(.system(size: 11))
                        .foregroundColor(themeManager.currentTheme.tertiaryText)
                        .lineLimit(2)
                }

                Spacer()

                HStack(spacing: 8) {
                    // Test Button (for automation permissions)
                    if canTest {
                        Button(action: runTest) {
                            if isTesting {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 12, height: 12)
                            } else {
                                Text("Test")
                                    .font(.system(size: 12, weight: .medium))
                            }
                        }
                        .foregroundColor(themeManager.currentTheme.primaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(themeManager.currentTheme.tertiaryBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                                )
                        )
                        .buttonStyle(PlainButtonStyle())
                        .disabled(isTesting)
                        .help("Run a diagnostic test to verify permission")
                    }

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
                            .foregroundColor(themeManager.currentTheme.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(themeManager.currentTheme.tertiaryBackground)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                                    )
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
                                    .fill(themeManager.currentTheme.accentColor)
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }

            // Inline Test Result
            if let result = testResult {
                let isSuccess = result.hasPrefix("SUCCESS")
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(
                            isSuccess ? themeManager.currentTheme.successColor : themeManager.currentTheme.warningColor
                        )
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(result)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(4)
                            .textSelection(.enabled)
                            .foregroundColor(
                                isSuccess
                                    ? themeManager.currentTheme.successColor : themeManager.currentTheme.warningColor
                            )

                        if !isSuccess {
                            Text("Xcode builds need separate grants. Try 'tccutil reset AppleEvents' if stuck.")
                                .font(.system(size: 10))
                                .foregroundColor(themeManager.currentTheme.tertiaryText)
                                .padding(.top, 2)
                        }
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            (isSuccess
                                ? themeManager.currentTheme.successColor : themeManager.currentTheme.warningColor)
                                .opacity(0.1)
                        )
                )
                .padding(.leading, 52)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(themeManager.currentTheme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            isGranted
                                ? themeManager.currentTheme.successColor.opacity(0.3)
                                : themeManager.currentTheme.inputBorder,
                            lineWidth: 1
                        )
                )
        )
        .scaleEffect(isHovered ? 1.005 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private func runTest() {
        guard !isTesting else { return }
        isTesting = true
        testResult = nil

        DispatchQueue.global(qos: .userInitiated).async {
            let result: String
            if permission == .automationCalendar {
                result = SystemPermissionService.debugTestCalendarAccess()
            } else if permission == .calendar {
                result = SystemPermissionService.debugTestCalendarEventKitAccess()
            } else if permission == .reminders {
                result = SystemPermissionService.debugTestRemindersAccess()
            } else if permission == .location {
                result = SystemPermissionService.debugTestLocationAccess()
            } else if permission == .notes {
                result = SystemPermissionService.debugTestNotesAccess()
            } else if permission == .automation {
                result = SystemPermissionService.debugTestAutomationAccess()
            } else if permission == .contacts {
                result = SystemPermissionService.debugTestContactsAccess()
            } else {
                result = "Test not available"
            }

            DispatchQueue.main.async {
                testResult = result
                isTesting = false

                // Update permission state if test succeeded
                if result.hasPrefix("SUCCESS") {
                    permissionService.updatePermissionState(permission, isGranted: true)
                }
            }
        }
    }
}

// MARK: - Default Persona Picker

private struct DefaultPersonaPicker: View {
    @StateObject private var themeManager = ThemeManager.shared
    @Binding var selection: UUID
    let personas: [Persona]

    @State private var isHovered = false

    private var displayName: String {
        if let persona = personas.first(where: { $0.id == selection }) {
            return persona.name
        }
        return "Default"
    }

    /// Generate a consistent color based on persona name
    private var personaColor: Color {
        let hash = abs(displayName.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.8)
    }

    var body: some View {
        Menu {
            ForEach(personas) { persona in
                Button(action: { selection = persona.id }) {
                    HStack {
                        Text(persona.name)
                        if persona.isBuiltIn {
                            Text("Built-in")
                                .foregroundColor(.secondary)
                        }
                        if selection == persona.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Divider()

            Button(action: {
                AppDelegate.shared?.showManagementWindow(initialTab: .personas)
            }) {
                Label("Manage Personas", systemImage: "person.2.badge.gearshape")
            }
        } label: {
            HStack(spacing: 10) {
                // Persona icon
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(personaColor)

                Text(displayName)
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
}
