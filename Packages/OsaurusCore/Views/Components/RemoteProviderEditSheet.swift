//
//  RemoteProviderEditSheet.swift
//  osaurus
//
//  Sheet for adding/editing remote OpenAI-compatible API providers.
//

import SwiftUI

// MARK: - Provider Presets

enum ProviderPreset: String, CaseIterable, Identifiable {
    case openai = "OpenAI"
    case ollama = "Ollama"
    case lmstudio = "LM Studio"
    case openrouter = "OpenRouter"
    case custom = "Custom"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .openai: return "sparkles"
        case .ollama: return "cube.fill"
        case .lmstudio: return "desktopcomputer"
        case .openrouter: return "arrow.triangle.branch"
        case .custom: return "slider.horizontal.3"
        }
    }

    var description: String {
        switch self {
        case .openai: return "GPT-4o, o1, etc."
        case .ollama: return "Local models"
        case .lmstudio: return "Local inference"
        case .openrouter: return "Multi-provider"
        case .custom: return "Custom endpoint"
        }
    }

    var gradient: [Color] {
        switch self {
        case .openai: return [Color(red: 0.0, green: 0.65, blue: 0.52), Color(red: 0.0, green: 0.5, blue: 0.4)]
        case .ollama: return [Color(red: 0.3, green: 0.5, blue: 0.9), Color(red: 0.2, green: 0.35, blue: 0.7)]
        case .lmstudio: return [Color(red: 0.7, green: 0.45, blue: 0.9), Color(red: 0.5, green: 0.3, blue: 0.7)]
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
    }

    var configuration: Configuration {
        switch self {
        case .openai:
            return Configuration(
                name: "OpenAI",
                host: "api.openai.com",
                providerProtocol: .https,
                port: nil,
                basePath: "/v1",
                authType: .apiKey
            )
        case .ollama:
            return Configuration(
                name: "Ollama",
                host: "localhost",
                providerProtocol: .http,
                port: 11434,
                basePath: "/v1",
                authType: .none
            )
        case .lmstudio:
            return Configuration(
                name: "LM Studio",
                host: "localhost",
                providerProtocol: .http,
                port: 1234,
                basePath: "/v1",
                authType: .none
            )
        case .openrouter:
            return Configuration(
                name: "OpenRouter",
                host: "openrouter.ai",
                providerProtocol: .https,
                port: nil,
                basePath: "/api/v1",
                authType: .apiKey
            )
        case .custom:
            return Configuration(
                name: "",
                host: "",
                providerProtocol: .https,
                port: nil,
                basePath: "/v1",
                authType: .none
            )
        }
    }
}

// MARK: - Main View

struct RemoteProviderEditSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

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
        .frame(width: 520, height: isEditing ? 560 : 680)
        .background(theme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear {
            loadProvider()
            withAnimation(.easeOut(duration: 0.3).delay(0.05)) {
                hasAppeared = true
            }
        }
    }

    // MARK: - Header

    private var sheetHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? "Edit Provider" : "Add Provider")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                if !isEditing {
                    Text("Connect to an OpenAI-compatible API")
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
            }

            Spacer()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(theme.tertiaryBackground))
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
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
                .fill(theme.primaryBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.primaryBorder.opacity(0.5), lineWidth: 1)
        )
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(theme.primaryBorder.opacity(0.5))
            .frame(height: 1)
            .padding(.horizontal, 16)
    }

    // MARK: - Connection Section

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Name field
            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .textCase(.uppercase)

                TextField("e.g. My OpenAI", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.tertiaryBackground)
                    )
                    .foregroundColor(theme.primaryText)
            }

            // Host row
            HStack(spacing: 10) {
                // Protocol
                VStack(alignment: .leading, spacing: 6) {
                    Text("Protocol")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .textCase(.uppercase)

                    HStack(spacing: 0) {
                        protocolButton("HTTPS", protocol: .https)
                        protocolButton("HTTP", protocol: .http)
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground))
                }
                .frame(width: 130)

                // Host
                VStack(alignment: .leading, spacing: 6) {
                    Text("Host")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .textCase(.uppercase)

                    TextField("api.openai.com", text: $host)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground))
                        .foregroundColor(theme.primaryText)
                }
            }

            // Port and Path row
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Port")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .textCase(.uppercase)

                    TextField(providerProtocol == .https ? "443" : "80", text: $portString)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground))
                        .foregroundColor(theme.primaryText)
                }
                .frame(width: 80)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Base Path")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .textCase(.uppercase)

                    TextField("/v1", text: $basePath)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground))
                        .foregroundColor(theme.primaryText)
                }
            }

            // Endpoint preview
            if !host.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.system(size: 10))
                    Text(buildEndpointPreview())
                        .font(.system(size: 11, design: .monospaced))
                }
                .foregroundColor(theme.tertiaryText)
                .padding(.top, 2)
            }
        }
        .padding(16)
    }

    private func protocolButton(_ label: String, protocol proto: RemoteProviderProtocol) -> some View {
        Button(action: { providerProtocol = proto }) {
            Text(label)
                .font(.system(size: 12, weight: providerProtocol == proto ? .semibold : .regular))
                .foregroundColor(providerProtocol == proto ? theme.primaryText : theme.tertiaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(providerProtocol == proto ? theme.secondaryBackground : Color.clear)
                )
        }
        .buttonStyle(PlainButtonStyle())
        .padding(2)
    }

    // MARK: - Authentication Section

    private var authenticationSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 0) {
                authButton("No Auth", authType: .none)
                authButton("API Key", authType: .apiKey)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground))

            if authType == .apiKey {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("API Key")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .textCase(.uppercase)

                        Spacer()

                        HStack(spacing: 4) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9))
                            Text("Keychain")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(theme.tertiaryText)
                    }

                    SecureField("sk-...", text: $apiKey)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground))
                        .foregroundColor(theme.primaryText)
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
                .font(.system(size: 12, weight: authType == type ? .semibold : .regular))
                .foregroundColor(authType == type ? theme.primaryText : theme.tertiaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(authType == type ? theme.secondaryBackground : Color.clear)
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
                HStack {
                    Text("Advanced")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            if showAdvanced {
                VStack(alignment: .leading, spacing: 14) {
                    // Timeout slider
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Request Timeout")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(theme.secondaryText)
                                .textCase(.uppercase)
                            Spacer()
                            Text("\(Int(timeout))s")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(theme.tertiaryText)
                        }

                        Slider(value: $timeout, in: 10 ... 300, step: 10)
                            .tint(theme.accentColor)
                    }

                    // Custom headers
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Custom Headers")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(theme.secondaryText)
                                .textCase(.uppercase)

                            Spacer()

                            Button(action: {
                                customHeaders.append(HeaderEntry(key: "", value: "", isSecret: false))
                            }) {
                                Image(systemName: "plus")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(theme.accentColor)
                                    .frame(width: 22, height: 22)
                                    .background(Circle().fill(theme.accentColor.opacity(0.1)))
                            }
                            .buttonStyle(PlainButtonStyle())
                        }

                        if customHeaders.isEmpty {
                            Text("No custom headers")
                                .font(.system(size: 12))
                                .foregroundColor(theme.tertiaryText)
                                .padding(.vertical, 4)
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
        HStack(spacing: 10) {
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
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(testButtonBackground)
                )
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(host.isEmpty || isTesting)
            .opacity(host.isEmpty ? 0.5 : 1)

            Spacer()

            // Cancel
            Button("Cancel") {
                dismiss()
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(theme.secondaryText)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .buttonStyle(PlainButtonStyle())

            // Save/Add
            Button(action: save) {
                Text(isEditing ? "Save" : "Add Provider")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(canSave ? theme.accentColor : theme.accentColor.opacity(0.4))
                    )
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(!canSave)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(theme.primaryBackground)
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
    @Environment(\.theme) private var theme
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
                                    ? preset.gradient : [theme.tertiaryBackground, theme.tertiaryBackground],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 36, height: 36)

                    Image(systemName: preset.icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(isSelected ? .white : theme.tertiaryText)
                }

                VStack(spacing: 1) {
                    Text(preset.rawValue)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)

                    Text(preset.description)
                        .font(.system(size: 8))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? preset.gradient[0].opacity(0.1) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isSelected ? preset.gradient[0].opacity(0.3) : Color.clear, lineWidth: 1)
                    )
            )
            .scaleEffect(isHovered && !isSelected ? 1.03 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isHovered)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isSelected)
    }
}

// MARK: - Compact Header Row

private struct CompactHeaderRow: View {
    @Environment(\.theme) private var theme
    @Binding var header: RemoteProviderEditSheet.HeaderEntry
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            TextField("Key", text: $header.key)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(width: 100)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground))
                .foregroundColor(theme.primaryText)

            Group {
                if header.isSecret {
                    SecureField("Value", text: $header.value)
                } else {
                    TextField("Value", text: $header.value)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground))
            .foregroundColor(theme.primaryText)

            Button(action: { header.isSecret.toggle() }) {
                Image(systemName: header.isSecret ? "lock.fill" : "lock.open")
                    .font(.system(size: 10))
                    .foregroundColor(header.isSecret ? theme.accentColor : theme.tertiaryText)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(theme.tertiaryBackground))
            }
            .buttonStyle(PlainButtonStyle())

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(theme.tertiaryBackground))
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
}

#Preview {
    RemoteProviderEditSheet(provider: nil) { _, _ in }
        .environment(\.theme, DarkTheme())
}
