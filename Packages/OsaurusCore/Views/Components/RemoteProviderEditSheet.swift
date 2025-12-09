//
//  RemoteProviderEditSheet.swift
//  osaurus
//
//  Sheet for adding/editing remote OpenAI-compatible API providers.
//

import SwiftUI

struct RemoteProviderEditSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    
    let provider: RemoteProvider?
    let onSave: (RemoteProvider, String?) -> Void
    
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
    @State private var autoConnect: Bool = true
    @State private var timeout: Double = 60
    
    // UI state
    @State private var isTesting: Bool = false
    @State private var testResult: TestResult?
    @State private var showAdvanced: Bool = false
    
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
            HStack {
                Text(isEditing ? "Edit Provider" : "Add Remote Provider")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(20)
            
            Divider()
            
            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Basic section
                    RemoteProviderFormSection(title: "Connection") {
                        RemoteProviderFormField(label: "Name") {
                            TextField("OpenAI, Ollama, etc.", text: $name)
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground))
                                .foregroundColor(theme.primaryText)
                        }
                        
                        HStack(spacing: 12) {
                            RemoteProviderFormField(label: "Protocol") {
                                Picker("", selection: $providerProtocol) {
                                    Text("HTTPS").tag(RemoteProviderProtocol.https)
                                    Text("HTTP").tag(RemoteProviderProtocol.http)
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 140)
                            }
                            
                            RemoteProviderFormField(label: "Host") {
                                TextField("api.openai.com", text: $host)
                                    .textFieldStyle(.plain)
                                    .font(.system(.body, design: .monospaced))
                                    .padding(10)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground))
                                    .foregroundColor(theme.primaryText)
                            }
                        }
                        
                        HStack(spacing: 12) {
                            RemoteProviderFormField(label: "Port", hint: "Optional") {
                                TextField(providerProtocol == .https ? "443" : "80", text: $portString)
                                    .textFieldStyle(.plain)
                                    .font(.system(.body, design: .monospaced))
                                    .padding(10)
                                    .frame(width: 100)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground))
                                    .foregroundColor(theme.primaryText)
                            }
                            
                            RemoteProviderFormField(label: "Base Path") {
                                TextField("/v1", text: $basePath)
                                    .textFieldStyle(.plain)
                                    .font(.system(.body, design: .monospaced))
                                    .padding(10)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground))
                                    .foregroundColor(theme.primaryText)
                            }
                        }
                        
                        // Endpoint preview
                        if !host.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "link")
                                    .font(.system(size: 10))
                                    .foregroundColor(theme.tertiaryText)
                                Text(buildEndpointPreview())
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(theme.secondaryText)
                            }
                            .padding(.top, 4)
                        }
                    }
                    
                    // Authentication section
                    RemoteProviderFormSection(title: "Authentication") {
                        Picker("", selection: $authType) {
                            Text("None").tag(RemoteProviderAuthType.none)
                            Text("API Key").tag(RemoteProviderAuthType.apiKey)
                        }
                        .pickerStyle(.segmented)
                        
                        if authType == .apiKey {
                            RemoteProviderFormField(label: "API Key", hint: "Stored securely in Keychain") {
                                SecureField("sk-...", text: $apiKey)
                                    .textFieldStyle(.plain)
                                    .font(.system(.body, design: .monospaced))
                                    .padding(10)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground))
                                    .foregroundColor(theme.primaryText)
                            }
                        }
                    }
                    
                    // Headers section
                    RemoteProviderFormSection(title: "Custom Headers", trailing: { addHeaderButton }) {
                        if customHeaders.isEmpty {
                            Text("No custom headers")
                                .font(.system(size: 13))
                                .foregroundColor(theme.tertiaryText)
                                .padding(.vertical, 8)
                        } else {
                            ForEach($customHeaders) { $header in
                                RemoteProviderHeaderRow(header: $header) {
                                    customHeaders.removeAll { $0.id == header.id }
                                }
                            }
                        }
                    }
                    
                    // Advanced section
                    VStack(alignment: .leading, spacing: 0) {
                        Button(action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                showAdvanced.toggle()
                            }
                        }) {
                            HStack {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 12))
                                Text("Advanced Settings")
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                            }
                            .foregroundColor(theme.secondaryText)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        
                        if showAdvanced {
                            VStack(alignment: .leading, spacing: 20) {
                                HStack {
                                    Text("Auto-connect on Launch")
                                        .font(.system(size: 13))
                                        .foregroundColor(theme.primaryText)
                                    Spacer()
                                    Toggle("", isOn: $autoConnect)
                                        .toggleStyle(SwitchToggleStyle())
                                        .labelsHidden()
                                }
                                
                                RemoteProviderFormField(label: "Request Timeout: \(Int(timeout))s") {
                                    Slider(value: $timeout, in: 10...300, step: 10)
                                }
                            }
                            .padding(.top, 12)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                .padding(20)
            }
            
            Divider()
            
            // Footer
            HStack(spacing: 12) {
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
                                ProgressView().scaleEffect(0.6)
                            } else if let result = testResult {
                                switch result {
                                case .success:
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 12))
                                case .failure:
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 12))
                                }
                            } else {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.system(size: 12))
                            }
                        }
                        .frame(width: 16, height: 16)
                        
                        if let result = testResult {
                            switch result {
                            case .success(let models):
                                Text("Connected! (\(models.count) models)")
                                    .font(.system(size: 13, weight: .medium))
                            case .failure:
                                Text("Failed - Tap to retry")
                                    .font(.system(size: 13, weight: .medium))
                            }
                        } else {
                            Text("Test Connection")
                                .font(.system(size: 13, weight: .medium))
                        }
                    }
                    .foregroundColor(testResultColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(testResultBackground))
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(host.isEmpty || isTesting)
                
                Spacer()
                
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                
                Button(action: save) {
                    Text(isEditing ? "Save" : "Add Provider")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(canSave ? theme.accentColor : theme.accentColor.opacity(0.5))
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(!canSave)
            }
            .padding(20)
        }
        .frame(width: 560, height: 650)
        .background(theme.primaryBackground)
        .onAppear { loadProvider() }
    }
    
    // MARK: - Computed Properties
    
    private var addHeaderButton: some View {
        Button(action: {
            customHeaders.append(HeaderEntry(key: "", value: "", isSecret: false))
        }) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                Text("Add")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(theme.accentColor)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private var testResultColor: Color {
        guard let result = testResult else { return theme.secondaryText }
        switch result {
        case .success: return theme.successColor
        case .failure: return theme.errorColor
        }
    }
    
    private var testResultBackground: Color {
        guard let result = testResult else { return theme.tertiaryBackground }
        switch result {
        case .success: return theme.successColor.opacity(0.12)
        case .failure: return theme.errorColor.opacity(0.12)
        }
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
        autoConnect = provider.autoConnect
        timeout = provider.timeout
        
        // Load regular headers
        customHeaders = provider.customHeaders.map { HeaderEntry(key: $0.key, value: $0.value, isSecret: false) }
        
        // Add secret header keys (values not loaded for security)
        for key in provider.secretHeaderKeys {
            customHeaders.append(HeaderEntry(key: key, value: "", isSecret: true))
        }
        
        // Note: API key not loaded for security - user must re-enter if changing
    }
    
    private func testConnection() {
        isTesting = true
        testResult = nil
        
        let headers = buildHeaders()
        let testApiKey = authType == .apiKey && !apiKey.isEmpty ? apiKey : nil
        // Parse port - use nil if empty or invalid (will use default port)
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
        
        // Separate regular headers from secret headers
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
            autoConnect: autoConnect,
            timeout: timeout,
            secretHeaderKeys: secretKeys
        )
        
        // Save secret header values to Keychain
        for header in customHeaders where header.isSecret && !header.key.isEmpty && !header.value.isEmpty {
            RemoteProviderKeychain.saveHeaderSecret(header.value, key: header.key, for: updatedProvider.id)
        }
        
        // Pass API key (empty string means no change, nil means keep existing)
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

// MARK: - Form Components

private struct RemoteProviderFormSection<Content: View, Trailing: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    let trailing: Trailing
    @ViewBuilder let content: () -> Content
    
    init(
        title: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.trailing = trailing()
        self.content = content
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                Spacer()
                trailing
            }
            content()
        }
    }
}

private struct RemoteProviderFormField<Content: View>: View {
    @Environment(\.theme) private var theme
    let label: String
    var hint: String? = nil
    @ViewBuilder let content: () -> Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                if let hint = hint {
                    Text("• \(hint)")
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
            }
            content()
        }
    }
}

private struct RemoteProviderHeaderRow: View {
    @Environment(\.theme) private var theme
    @Binding var header: RemoteProviderEditSheet.HeaderEntry
    let onDelete: () -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            TextField("Key", text: $header.key)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .frame(width: 140)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground))
                .foregroundColor(theme.primaryText)
            
            if header.isSecret {
                SecureField("Value (secret)", text: $header.value)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground))
                    .foregroundColor(theme.primaryText)
            } else {
                TextField("Value", text: $header.value)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground))
                    .foregroundColor(theme.primaryText)
            }
            
            Toggle("Secret", isOn: $header.isSecret)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
            
            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .foregroundColor(theme.errorColor.opacity(0.7))
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
}

#Preview {
    RemoteProviderEditSheet(provider: nil) { _, _ in }
        .environment(\.theme, DarkTheme())
}

