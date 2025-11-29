import SwiftUI

// MARK: - Configuration View
struct ConfigurationView: View {
    @StateObject private var themeManager = ThemeManager.shared
    @Environment(\.theme) private var theme

    @State private var tempPortString: String = ""
    @State private var tempExposeToNetwork: Bool = false
    @State private var tempStartAtLogin: Bool = false
    @State private var showAdvancedSettings: Bool = false
    @State private var cliInstallMessage: String? = nil
    @State private var cliInstallSuccess: Bool = false
    @State private var hasAppeared = false
    @State private var showSaveConfirmation = false

    // Chat settings state
    @State private var tempChatHotkey: Hotkey? = nil
    @State private var tempSystemPrompt: String = ""
    @State private var tempChatTemperature: String = ""
    @State private var tempChatMaxTokens: String = ""
    @State private var tempChatTopP: String = ""
    @State private var tempChatMaxToolAttempts: String = ""

    // Advanced settings state
    @State private var tempTopP: String = ""
    @State private var tempKVBits: String = ""
    @State private var tempKVGroup: String = ""
    @State private var tempQuantStart: String = ""
    @State private var tempMaxKV: String = ""
    @State private var tempPrefillStep: String = ""
    @State private var tempAllowedOrigins: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            // Scrollable content area
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Chat settings section
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Chat", systemImage: "message")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.primaryText)

                        // Global Hotkey
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Global Hotkey")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(theme.secondaryText)
                            HotkeyRecorder(value: $tempChatHotkey)
                        }

                        // System Prompt
                        VStack(alignment: .leading, spacing: 8) {
                            Text("System Prompt")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(theme.secondaryText)
                            ZStack(alignment: .topLeading) {
                                TextEditor(text: $tempSystemPrompt)
                                    .font(.system(size: 13, design: .monospaced))
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
                                        .foregroundColor(theme.tertiaryText)
                                        .padding(.top, 12)
                                        .padding(.leading, 14)
                                }
                            }
                        }

                        // Chat Generation (per-chat overrides)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Generation")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(theme.secondaryText)

                            VStack(spacing: 12) {
                                advancedField(
                                    "Temperature",
                                    text: $tempChatTemperature,
                                    placeholder: "0.7",
                                    help: "Controls randomness (0–2). Empty uses default 0.7"
                                )
                                advancedField(
                                    "Max Tokens",
                                    text: $tempChatMaxTokens,
                                    placeholder: "1024",
                                    help: "Maximum response tokens. Empty uses default 1024"
                                )
                                advancedField(
                                    "Top P Override",
                                    text: $tempChatTopP,
                                    placeholder: "",
                                    help: "Override server Top P (0–1). Empty uses server default"
                                )
                            }
                        }

                        // Tools (per-chat overrides)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Tools")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(theme.secondaryText)

                            VStack(spacing: 12) {
                                advancedField(
                                    "Max Tool Attempts",
                                    text: $tempChatMaxToolAttempts,
                                    placeholder: "3",
                                    help: "Max consecutive tool calls per prompt (min 1)"
                                )
                            }
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(theme.secondaryBackground)
                    )
                    // Port configuration section
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Network Settings", systemImage: "network")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.primaryText)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Port")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(theme.secondaryText)

                            TextField("1337", text: $tempPortString)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
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
                                .foregroundColor(theme.primaryText)

                            Text("Enter a port number between 1 and 65535")
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                        }

                        // Network exposure toggle
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Expose to network")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(theme.primaryText)
                                Text("Allow devices on your network to connect")
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.tertiaryText)
                            }

                            Spacer()

                            Toggle("", isOn: $tempExposeToNetwork)
                                .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                                .labelsHidden()
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(theme.secondaryBackground)
                    )

                    // System settings section
                    VStack(alignment: .leading, spacing: 16) {
                        Label("System", systemImage: "gear")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.primaryText)

                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Start at Login")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(theme.primaryText)
                                Text("Launch Osaurus when you sign in")
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.tertiaryText)
                            }

                            Spacer()

                            Toggle("", isOn: $tempStartAtLogin)
                                .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                                .labelsHidden()
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(theme.secondaryBackground)
                    )

                    // System Permissions section
                    SystemPermissionsSection()

                    // Command Line Tool section
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Command Line Tool", systemImage: "terminal")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.primaryText)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Install the `osaurus` CLI into your PATH.")
                                .font(.system(size: 12))
                                .foregroundColor(theme.secondaryText)

                            HStack(spacing: 8) {
                                Button(action: { installCLI() }) {
                                    Text("Install CLI")
                                        .font(.system(size: 13, weight: .medium))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(theme.buttonBackground)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .stroke(theme.buttonBorder, lineWidth: 1)
                                                )
                                        )
                                }
                                .buttonStyle(PlainButtonStyle())
                                .help("Create a symlink to the embedded CLI")

                                if let message = cliInstallMessage {
                                    Text(message)
                                        .font(.system(size: 11))
                                        .foregroundColor(cliInstallSuccess ? .green : .red)
                                        .lineLimit(2)
                                }
                            }

                            Text("If installed to ~/.local/bin, ensure it's in your PATH.")
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(theme.secondaryBackground)
                    )

                    // Models directory section
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Storage", systemImage: "folder")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.primaryText)

                        DirectoryPickerView()
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(theme.secondaryBackground)
                    )

                    // Advanced settings toggle
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showAdvancedSettings.toggle()
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .medium))
                                .rotationEffect(.degrees(showAdvancedSettings ? 90 : 0))
                                .animation(.easeInOut(duration: 0.2), value: showAdvancedSettings)

                            Text("Advanced Settings")
                                .font(.system(size: 13, weight: .medium))

                            Spacer()

                            if !showAdvancedSettings {
                                Text("Show more options")
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.tertiaryText)
                            }
                        }
                        .foregroundColor(theme.primaryText)
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(theme.secondaryBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(theme.primaryBorder, lineWidth: 0.5)
                                )
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())

                    if showAdvancedSettings {
                        VStack(alignment: .leading, spacing: 20) {
                            // Networking Section
                            VStack(alignment: .leading, spacing: 16) {
                                Label("CORS Settings", systemImage: "lock.shield")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(theme.primaryText)

                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Allowed Origins")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(theme.secondaryText)

                                    TextField("https://example.com, https://app.localhost", text: $tempAllowedOrigins)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 13, design: .monospaced))
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
                                        .foregroundColor(theme.primaryText)

                                    Text("Comma-separated list. Use * for any origin, or leave empty to disable CORS")
                                        .font(.system(size: 11))
                                        .foregroundColor(theme.tertiaryText)
                                }
                            }
                            .padding(16)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(theme.secondaryBackground)
                            )

                            // AI Parameters Section
                            VStack(alignment: .leading, spacing: 16) {
                                Label("AI Parameters", systemImage: "cpu")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(theme.primaryText)

                                VStack(spacing: 12) {
                                    advancedField(
                                        "Top P",
                                        text: $tempTopP,
                                        placeholder: "1.0",
                                        help: "Controls diversity of generated text"
                                    )
                                    advancedField(
                                        "KV Cache Bits",
                                        text: $tempKVBits,
                                        placeholder: "4",
                                        help: "Quantization bits for KV cache (empty = off)"
                                    )
                                    advancedField(
                                        "KV Group Size",
                                        text: $tempKVGroup,
                                        placeholder: "64",
                                        help: "Group size for KV quantization"
                                    )
                                    advancedField(
                                        "Quantized KV Start",
                                        text: $tempQuantStart,
                                        placeholder: "0",
                                        help: "Starting layer for KV quantization"
                                    )
                                    advancedField(
                                        "Max KV Size",
                                        text: $tempMaxKV,
                                        placeholder: "",
                                        help: "Maximum KV cache size (empty = unlimited)"
                                    )
                                    advancedField(
                                        "Prefill Step Size",
                                        text: $tempPrefillStep,
                                        placeholder: "512",
                                        help: "Step size for prefill operations"
                                    )
                                }
                            }
                            .padding(16)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(theme.secondaryBackground)
                            )
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
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
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .background(theme.secondaryBackground)
    }

    // MARK: - Configuration Loading

    private func loadConfiguration() {
        let configuration = ServerConfigurationStore.load() ?? ServerConfiguration.default
        tempPortString = String(configuration.port)
        tempExposeToNetwork = configuration.exposeToNetwork
        tempStartAtLogin = configuration.startAtLogin

        let chat = ChatConfigurationStore.load()
        tempChatHotkey = chat.hotkey
        tempSystemPrompt = chat.systemPrompt
        tempChatTemperature = chat.temperature.map { String($0) } ?? ""
        tempChatMaxTokens = chat.maxTokens.map(String.init) ?? ""
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
    }

    // MARK: - Configuration Saving

    private func saveConfiguration() {
        guard let port = Int(tempPortString), (1 ..< 65536).contains(port) else { return }

        var configuration = ServerConfigurationStore.load() ?? ServerConfiguration.default
        configuration.port = port
        configuration.exposeToNetwork = tempExposeToNetwork
        configuration.startAtLogin = tempStartAtLogin

        // Save advanced settings if they were modified
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
            maxToolAttempts: parsedMaxToolAttempts
        )
        ChatConfigurationStore.save(chatCfg)

        // Apply hotkey without relaunch
        AppDelegate.shared?.applyChatHotkey()

        // Apply login item state
        LoginItemService.shared.applyStartAtLogin(configuration.startAtLogin)

        // Restart server to apply changes
        Task { @MainActor in
            await AppDelegate.shared?.serverController.restartServer()
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

    @ViewBuilder
    private func advancedField(
        _ label: String,
        text: Binding<String>,
        placeholder: String,
        help: String
    )
        -> some View
    {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)

                Spacer()

                Text(help)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }

            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
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
                .foregroundColor(theme.primaryText)
        }
    }
}

// MARK: - CLI Install Helper
extension ConfigurationView {
    private func installCLI() {
        let fm = FileManager.default

        guard let cliURL = resolveCLIExecutableURL() else {
            cliInstallSuccess = false
            cliInstallMessage = "CLI not found. Build once (Run) in Xcode, then retry."
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
            // If we can't create ~/.local/bin, abort
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
        cliInstallMessage = "Installation failed. Try manual setup from README."
    }

    private func resolveCLIExecutableURL() -> URL? {
        let fm = FileManager.default
        let appURL = Bundle.main.bundleURL
        // Prefer embedded CLI in Helpers; fallback to MacOS for dev/main binary
        let helpers = appURL.appendingPathComponent("Contents/Helpers/osaurus", isDirectory: false)
        if fm.fileExists(atPath: helpers.path), fm.isExecutableFile(atPath: helpers.path) {
            return helpers
        }
        let embedded = appURL.appendingPathComponent("Contents/MacOS/osaurus", isDirectory: false)
        if fm.fileExists(atPath: embedded.path), fm.isExecutableFile(atPath: embedded.path) {
            return embedded
        }

        // Fallback for development when running from Xcode: try the build Products directory
        // Example: .../DerivedData/.../Build/Products/Debug/osaurus.app
        // CLI may be at: .../DerivedData/.../Build/Products/Debug/osaurus
        let productsDir = appURL.deletingLastPathComponent()
        let debugCLI = productsDir.appendingPathComponent("osaurus", isDirectory: false)
        if fm.fileExists(atPath: debugCLI.path), fm.isExecutableFile(atPath: debugCLI.path) {
            return debugCLI
        }
        let releaseCLI = productsDir.deletingLastPathComponent()
            .appendingPathComponent("Release/osaurus", isDirectory: false)
        if fm.fileExists(atPath: releaseCLI.path), fm.isExecutableFile(atPath: releaseCLI.path) {
            return releaseCLI
        }

        // Also try if the app got embedded but we ran before copy phase: check inside the app that lives in Products/Release
        let releaseDir = productsDir.deletingLastPathComponent()
        let releaseHelpers =
            releaseDir
            .appendingPathComponent("Release/osaurus.app/Contents/Helpers/osaurus", isDirectory: false)
        if fm.fileExists(atPath: releaseHelpers.path), fm.isExecutableFile(atPath: releaseHelpers.path) {
            return releaseHelpers
        }
        let releaseEmbedded =
            releaseDir
            .appendingPathComponent("Release/osaurus.app/Contents/MacOS/osaurus", isDirectory: false)
        if fm.fileExists(atPath: releaseEmbedded.path),
            fm.isExecutableFile(atPath: releaseEmbedded.path)
        {
            return releaseEmbedded
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
