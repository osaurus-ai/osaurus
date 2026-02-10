//
//  RemoteProviderEditSheet.swift
//  osaurus
//
//  Sheet for adding/editing remote API providers (OpenAI, Anthropic, etc.).
//

import SwiftUI

// MARK: - Provider Presets

enum ProviderPreset: String, CaseIterable, Identifiable {
    case anthropic = "Anthropic"
    case openai = "OpenAI"
    case google = "Google"
    case xai = "xAI"
    case openrouter = "OpenRouter"
    case custom = "Custom"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .anthropic: return "brain.head.profile"
        case .openai: return "sparkles"
        case .google: return "globe"
        case .xai: return "bolt.fill"
        case .openrouter: return "arrow.triangle.branch"
        case .custom: return "slider.horizontal.3"
        }
    }

    var description: String {
        switch self {
        case .anthropic: return "Claude models"
        case .openai: return "GPT-4o, o1, etc."
        case .google: return "Gemini models"
        case .xai: return "Grok models"
        case .openrouter: return "Multi-provider"
        case .custom: return "Custom endpoint"
        }
    }

    var gradient: [Color] {
        switch self {
        case .anthropic: return [Color(red: 0.85, green: 0.55, blue: 0.35), Color(red: 0.75, green: 0.4, blue: 0.25)]
        case .openai: return [Color(red: 0.0, green: 0.65, blue: 0.52), Color(red: 0.0, green: 0.5, blue: 0.4)]
        case .google: return [Color(red: 0.26, green: 0.52, blue: 0.96), Color(red: 0.18, green: 0.38, blue: 0.85)]
        case .xai: return [Color(red: 0.1, green: 0.1, blue: 0.1), Color(red: 0.2, green: 0.2, blue: 0.2)]
        case .openrouter: return [Color(red: 0.95, green: 0.55, blue: 0.25), Color(red: 0.85, green: 0.4, blue: 0.2)]
        case .custom: return [Color(red: 0.55, green: 0.55, blue: 0.6), Color(red: 0.4, green: 0.4, blue: 0.45)]
        }
    }

    struct Configuration {
        let name: String
        let host: String
        let providerProtocol: RemoteProviderProtocol
        let port: Int?
        let basePath: String
        let authType: RemoteProviderAuthType
        let providerType: RemoteProviderType
    }

    var configuration: Configuration {
        switch self {
        case .anthropic:
            return Configuration(
                name: "Anthropic",
                host: "api.anthropic.com",
                providerProtocol: .https,
                port: nil,
                basePath: "/v1",
                authType: .apiKey,
                providerType: .anthropic
            )
        case .openai:
            return Configuration(
                name: "OpenAI",
                host: "api.openai.com",
                providerProtocol: .https,
                port: nil,
                basePath: "/v1",
                authType: .apiKey,
                providerType: .openai
            )
        case .google:
            return Configuration(
                name: "Google",
                host: "generativelanguage.googleapis.com",
                providerProtocol: .https,
                port: nil,
                basePath: "/v1beta",
                authType: .apiKey,
                providerType: .gemini
            )
        case .xai:
            return Configuration(
                name: "xAI",
                host: "api.x.ai",
                providerProtocol: .https,
                port: nil,
                basePath: "/v1",
                authType: .apiKey,
                providerType: .openai
            )
        case .openrouter:
            return Configuration(
                name: "OpenRouter",
                host: "openrouter.ai",
                providerProtocol: .https,
                port: nil,
                basePath: "/api/v1",
                authType: .apiKey,
                providerType: .openai
            )
        case .custom:
            return Configuration(
                name: "",
                host: "",
                providerProtocol: .https,
                port: nil,
                basePath: "/v1",
                authType: .none,
                providerType: .openai
            )
        }
    }
}

// MARK: - Main View

struct RemoteProviderEditSheet: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    private var theme: ThemeProtocol { themeManager.currentTheme }

    let provider: RemoteProvider?
    let onSave: (RemoteProvider, String?) -> Void

    // Preset selection (only for new providers)
    @State private var selectedPreset: ProviderPreset? = nil

    // Basic settings
    @State private var name: String = ""
    @State private var host: String = ""
    @State private var providerProtocol: RemoteProviderProtocol = .https
    @State private var portString: String = ""
    @State private var basePath: String = "/v1"

    // Authentication
    @State private var authType: RemoteProviderAuthType = .none
    @State private var apiKey: String = ""

    // Provider type
    @State private var providerType: RemoteProviderType = .openai

    // Custom headers
    @State private var customHeaders: [HeaderEntry] = []

    // Advanced settings
    @State private var timeout: Double = 60

    // UI state
    @State private var isTesting: Bool = false
    @State private var testResult: TestResult?
    @State private var showAdvanced: Bool = false
    @State private var hasAppeared: Bool = false

    private var isEditing: Bool { provider != nil }

    struct HeaderEntry: Identifiable {
        let id = UUID()
        var key: String
        var value: String
        var isSecret: Bool
    }

    enum TestResult {
        case success([String])
        case failure(String)

        var isSuccess: Bool {
            if case .success = self { return true }
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            sheetHeader

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Preset selector (only for new providers)
                    if !isEditing {
                        presetSelectorSection
                            .opacity(hasAppeared ? 1 : 0)
                            .offset(y: hasAppeared ? 0 : 10)
                    }

                    // Form sections in a card
                    formCard
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 10)
                }
                .padding(20)
            }

            // Footer
            sheetFooter
        }
        .frame(width: 580, height: isEditing ? 580 : 720)
        .background(theme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.primaryBorder.opacity(0.5), lineWidth: 1)
        )
        .opacity(hasAppeared ? 1 : 0)
        .scaleEffect(hasAppeared ? 1 : 0.95)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hasAppeared)
        .onAppear {
            loadProvider()
            withAnimation {
                hasAppeared = true
            }
        }
    }

    // MARK: - Header

    private var sheetHeader: some View {
        HStack(spacing: 12) {
            // Icon with gradient background
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.accentColor.opacity(0.2),
                                theme.accentColor.opacity(0.05),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: isEditing ? "pencil.circle.fill" : "cloud.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                theme.accentColor,
                                theme.accentColor.opacity(0.7),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? "Edit Provider" : "Add Provider")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text(isEditing ? "Modify your API connection" : "Connect to a remote API provider")
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(theme.tertiaryBackground)
                    )
            }
            .buttonStyle(PlainButtonStyle())
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(
            theme.secondaryBackground
                .overlay(
                    LinearGradient(
                        colors: [
                            theme.accentColor.opacity(0.03),
                            Color.clear,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    // MARK: - Preset Selector

    private var presetSelectorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: ProviderPreset.allCases.count > 4 ? 8 : 10) {
                ForEach(ProviderPreset.allCases) { preset in
                    PresetPill(
                        preset: preset,
                        isSelected: selectedPreset == preset,
                        action: { selectPreset(preset) }
                    )
                }
            }
        }
    }

    // MARK: - Form Card

    private var formCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Connection section
            connectionSection

            sectionDivider

            // Authentication section
            authenticationSection

            sectionDivider

            // Advanced section (collapsed by default)
            advancedSection
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(theme.cardBorder)
            .frame(height: 1)
            .padding(.horizontal, 16)
    }

    // MARK: - Connection Section

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section header
            HStack(spacing: 8) {
                Image(systemName: "network")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)

                Text("CONNECTION")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.secondaryText)
                    .tracking(0.5)
            }

            // Name field
            ProviderTextField(
                label: "Name",
                placeholder: "e.g. My OpenAI",
                text: $name
            )

            // Host row
            HStack(spacing: 12) {
                // Protocol
                VStack(alignment: .leading, spacing: 6) {
                    Text("PROTOCOL")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(theme.tertiaryText)
                        .tracking(0.5)

                    HStack(spacing: 0) {
                        protocolButton("HTTPS", protocol: .https)
                        protocolButton("HTTP", protocol: .http)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(theme.inputBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(theme.inputBorder, lineWidth: 1)
                            )
                    )
                }
                .frame(width: 140)

                // Host
                ProviderTextField(
                    label: "Host",
                    placeholder: "api.openai.com",
                    text: $host,
                    isMonospaced: true
                )
            }

            // Port and Path row
            HStack(spacing: 12) {
                ProviderTextField(
                    label: "Port",
                    placeholder: providerProtocol == .https ? "443" : "80",
                    text: $portString,
                    isMonospaced: true
                )
                .frame(width: 90)

                ProviderTextField(
                    label: "Base Path",
                    placeholder: "/v1",
                    text: $basePath,
                    isMonospaced: true
                )
            }

            // Endpoint preview
            if !host.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .font(.system(size: 11))
                        .foregroundColor(theme.accentColor)

                    Text(buildEndpointPreview())
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.accentColor.opacity(0.1))
                )
            }
        }
        .padding(16)
    }

    private func protocolButton(_ label: String, protocol proto: RemoteProviderProtocol) -> some View {
        Button(action: { providerProtocol = proto }) {
            Text(label)
                .font(.system(size: 11, weight: providerProtocol == proto ? .semibold : .medium))
                .foregroundColor(providerProtocol == proto ? theme.primaryText : theme.tertiaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(providerProtocol == proto ? theme.tertiaryBackground : Color.clear)
                )
        }
        .buttonStyle(PlainButtonStyle())
        .padding(2)
    }

    // MARK: - Authentication Section

    private var authenticationSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section header
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)

                Text("AUTHENTICATION")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.secondaryText)
                    .tracking(0.5)
            }

            HStack(spacing: 0) {
                authButton("No Auth", authType: .none)
                authButton("API Key", authType: .apiKey)
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )

            if authType == .apiKey {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("API KEY")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(theme.tertiaryText)
                            .tracking(0.5)

                        Spacer()

                        HStack(spacing: 4) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9))
                            Text("Stored in Keychain")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(theme.tertiaryText)
                    }

                    ProviderSecureField(
                        placeholder: "sk-...",
                        text: $apiKey
                    )
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: authType)
    }

    private func authButton(_ label: String, authType type: RemoteProviderAuthType) -> some View {
        Button(action: { authType = type }) {
            Text(label)
                .font(.system(size: 11, weight: authType == type ? .semibold : .medium))
                .foregroundColor(authType == type ? theme.primaryText : theme.tertiaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(authType == type ? theme.tertiaryBackground : Color.clear)
                )
        }
        .buttonStyle(PlainButtonStyle())
        .padding(2)
    }

    // MARK: - Advanced Section

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    showAdvanced.toggle()
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))

                    Text(showAdvanced ? "Hide advanced settings" : "Show advanced settings")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    Spacer()
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.tertiaryBackground.opacity(0.5))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .padding(16)

            if showAdvanced {
                VStack(alignment: .leading, spacing: 16) {
                    // Timeout slider
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("REQUEST TIMEOUT")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(theme.tertiaryText)
                                .tracking(0.5)
                            Spacer()
                            Text("\(Int(timeout))s")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(theme.secondaryText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(theme.inputBackground)
                                )
                        }

                        Slider(value: $timeout, in: 10 ... 300, step: 10)
                            .tint(theme.accentColor)
                    }

                    // Custom headers
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("CUSTOM HEADERS")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(theme.tertiaryText)
                                .tracking(0.5)

                            Spacer()

                            Button(action: {
                                customHeaders.append(HeaderEntry(key: "", value: "", isSecret: false))
                            }) {
                                Image(systemName: "plus")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(theme.accentColor)
                                    .frame(width: 24, height: 24)
                                    .background(
                                        Circle()
                                            .fill(theme.accentColor.opacity(0.1))
                                    )
                            }
                            .buttonStyle(PlainButtonStyle())
                        }

                        if customHeaders.isEmpty {
                            Text("No custom headers configured")
                                .font(.system(size: 12))
                                .foregroundColor(theme.tertiaryText)
                                .padding(.vertical, 6)
                        } else {
                            ForEach($customHeaders) { $header in
                                CompactHeaderRow(header: $header) {
                                    customHeaders.removeAll { $0.id == header.id }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Footer

    private var sheetFooter: some View {
        HStack(spacing: 12) {
            // Test connection button
            Button(action: {
                if testResult != nil {
                    testResult = nil
                } else {
                    testConnection()
                }
            }) {
                HStack(spacing: 6) {
                    Group {
                        if isTesting {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 14, height: 14)
                        } else if let result = testResult {
                            Image(systemName: result.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 12))
                        } else {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 11))
                        }
                    }

                    Text(testButtonLabel)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(testButtonColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(testButtonBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(testButtonColor.opacity(0.3), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(host.isEmpty || isTesting)
            .opacity(host.isEmpty ? 0.5 : 1)

            // Keyboard hint
            HStack(spacing: 4) {
                Text("⌘")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.tertiaryBackground)
                    )
                Text("+ Enter to save")
                    .font(.system(size: 11))
            }
            .foregroundColor(theme.tertiaryText)

            Spacer()

            // Cancel button
            Button("Cancel") {
                dismiss()
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(theme.primaryText)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.tertiaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )
            .buttonStyle(PlainButtonStyle())

            // Save/Add button
            Button(action: save) {
                Text(isEditing ? "Save Changes" : "Add Provider")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(canSave ? theme.accentColor : theme.accentColor.opacity(0.4))
                    )
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(!canSave)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            theme.secondaryBackground
                .overlay(
                    Rectangle()
                        .fill(theme.primaryBorder)
                        .frame(height: 1),
                    alignment: .top
                )
        )
    }

    private var testButtonLabel: String {
        if let result = testResult {
            switch result {
            case .success(let models): return "\(models.count) models"
            case .failure: return "Retry"
            }
        }
        return "Test"
    }

    private var testButtonColor: Color {
        guard let result = testResult else { return theme.secondaryText }
        return result.isSuccess ? theme.successColor : theme.errorColor
    }

    private var testButtonBackground: Color {
        guard let result = testResult else { return theme.tertiaryBackground }
        return result.isSuccess ? theme.successColor.opacity(0.12) : theme.errorColor.opacity(0.12)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !host.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func buildEndpointPreview() -> String {
        var result = "\(providerProtocol.rawValue)://\(host)"
        if let port = Int(portString), port != providerProtocol.defaultPort {
            result += ":\(port)"
        }
        let normalizedPath = basePath.hasPrefix("/") ? basePath : "/" + basePath
        result += normalizedPath
        return result
    }

    // MARK: - Actions

    private func selectPreset(_ preset: ProviderPreset) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            selectedPreset = preset
        }

        let config = preset.configuration
        name = config.name
        host = config.host
        providerProtocol = config.providerProtocol
        portString = config.port.map { String($0) } ?? ""
        basePath = config.basePath
        authType = config.authType
        providerType = config.providerType
        testResult = nil
    }

    private func loadProvider() {
        guard let provider = provider else { return }
        name = provider.name
        host = provider.host
        providerProtocol = provider.providerProtocol
        if let port = provider.port {
            portString = String(port)
        }
        basePath = provider.basePath
        authType = provider.authType
        providerType = provider.providerType
        timeout = provider.timeout
        customHeaders = provider.customHeaders.map { HeaderEntry(key: $0.key, value: $0.value, isSecret: false) }
        for key in provider.secretHeaderKeys {
            customHeaders.append(HeaderEntry(key: key, value: "", isSecret: true))
        }
    }

    private func testConnection() {
        isTesting = true
        testResult = nil

        let headers = buildHeaders()
        let testApiKey = authType == .apiKey && !apiKey.isEmpty ? apiKey : nil
        let port: Int? = portString.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Int(portString)
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedBasePath = basePath.trimmingCharacters(in: .whitespaces)

        Task {
            do {
                let models = try await RemoteProviderManager.shared.testConnection(
                    host: trimmedHost,
                    providerProtocol: providerProtocol,
                    port: port,
                    basePath: trimmedBasePath,
                    authType: authType,
                    providerType: providerType,
                    apiKey: testApiKey,
                    headers: headers
                )
                await MainActor.run {
                    testResult = .success(models)
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = .failure(error.localizedDescription)
                    isTesting = false
                }
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let port = Int(portString)

        var regularHeaders: [String: String] = [:]
        var secretKeys: [String] = []

        for header in customHeaders where !header.key.isEmpty {
            if header.isSecret {
                secretKeys.append(header.key)
            } else {
                regularHeaders[header.key] = header.value
            }
        }

        let updatedProvider = RemoteProvider(
            id: provider?.id ?? UUID(),
            name: trimmedName,
            host: trimmedHost,
            providerProtocol: providerProtocol,
            port: port,
            basePath: basePath,
            customHeaders: regularHeaders,
            authType: authType,
            providerType: providerType,
            enabled: provider?.enabled ?? true,
            autoConnect: true,
            timeout: timeout,
            secretHeaderKeys: secretKeys
        )

        for header in customHeaders where header.isSecret && !header.key.isEmpty && !header.value.isEmpty {
            RemoteProviderKeychain.saveHeaderSecret(header.value, key: header.key, for: updatedProvider.id)
        }

        let apiKeyToSave: String? = apiKey.isEmpty ? nil : apiKey
        onSave(updatedProvider, apiKeyToSave)
        dismiss()
    }

    private func buildHeaders() -> [String: String] {
        var headers: [String: String] = [:]
        for header in customHeaders where !header.key.isEmpty && !header.value.isEmpty {
            headers[header.key] = header.value
        }
        return headers
    }
}

// MARK: - Preset Pill

private struct PresetPill: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let preset: ProviderPreset
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: isSelected
                                    ? preset.gradient
                                    : [
                                        themeManager.currentTheme.tertiaryBackground,
                                        themeManager.currentTheme.tertiaryBackground,
                                    ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 38, height: 38)

                    Image(systemName: preset.icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(isSelected ? .white : themeManager.currentTheme.tertiaryText)
                }

                VStack(spacing: 2) {
                    Text(preset.rawValue)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(
                            isSelected ? themeManager.currentTheme.primaryText : themeManager.currentTheme.secondaryText
                        )

                    Text(preset.description)
                        .font(.system(size: 9))
                        .foregroundColor(themeManager.currentTheme.tertiaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? preset.gradient[0].opacity(0.1) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                isSelected
                                    ? preset.gradient[0].opacity(0.4)
                                    : themeManager.currentTheme.inputBorder.opacity(0.5),
                                lineWidth: isSelected ? 1.5 : 1
                            )
                    )
            )
            .scaleEffect(isHovered && !isSelected ? 1.02 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isHovered)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isSelected)
    }
}

// MARK: - Compact Header Row

private struct CompactHeaderRow: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Binding var header: RemoteProviderEditSheet.HeaderEntry
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("Key", text: $header.key)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(width: 120)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(themeManager.currentTheme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                        )
                )
                .foregroundColor(themeManager.currentTheme.primaryText)

            Group {
                if header.isSecret {
                    SecureField("Value", text: $header.value)
                } else {
                    TextField("Value", text: $header.value)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(themeManager.currentTheme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                    )
            )
            .foregroundColor(themeManager.currentTheme.primaryText)

            Button(action: { header.isSecret.toggle() }) {
                Image(systemName: header.isSecret ? "lock.fill" : "lock.open")
                    .font(.system(size: 10))
                    .foregroundColor(
                        header.isSecret ? themeManager.currentTheme.accentColor : themeManager.currentTheme.tertiaryText
                    )
                    .frame(width: 26, height: 26)
                    .background(
                        Circle()
                            .fill(themeManager.currentTheme.tertiaryBackground)
                    )
            }
            .buttonStyle(PlainButtonStyle())
            .help(header.isSecret ? "This value is stored securely" : "Click to make this a secret value")

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle()
                            .fill(themeManager.currentTheme.tertiaryBackground)
                    )
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
}

// MARK: - Provider TextField

private struct ProviderTextField: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let label: String
    let placeholder: String
    @Binding var text: String
    var isMonospaced: Bool = false

    @State private var isFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(themeManager.currentTheme.tertiaryText)
                .tracking(0.5)

            HStack(spacing: 10) {
                ZStack(alignment: .leading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(.system(size: 13, design: isMonospaced ? .monospaced : .default))
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
                    .font(.system(size: 13, design: isMonospaced ? .monospaced : .default))
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

// MARK: - Provider Secure Field

private struct ProviderSecureField: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let placeholder: String
    @Binding var text: String

    @State private var isFocused = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(themeManager.currentTheme.placeholderText)
                        .allowsHitTesting(false)
                }

                SecureField("", text: $text)
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
                        .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                )
        )
    }
}

#Preview {
    RemoteProviderEditSheet(provider: nil) { _, _ in }
        .environment(\.theme, DarkTheme())
}
