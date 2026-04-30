//
//  RemoteProviderEditSheet.swift
//  osaurus
//
//  Sheet for adding/editing remote API providers.
//  Add mode: stepped flow (pick provider -> API key -> test -> save).
//  Edit mode: simplified form based on known vs custom provider.
//

import AppKit
import SwiftUI

private func parseManualModelIds(_ text: String) -> [String] {
    var seen = Set<String>()
    var values: [String] = []

    for part in text.split(whereSeparator: { $0 == "\n" || $0 == "," }) {
        let value = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { continue }

        let key = value.lowercased()
        guard !seen.contains(key) else { continue }

        seen.insert(key)
        values.append(value)
    }

    return values
}

// MARK: - Main View

struct RemoteProviderEditSheet: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let provider: RemoteProvider?
    var initialPreset: ProviderPreset?
    let onSave: (RemoteProvider, String?, RemoteProviderOAuthTokens?) -> Void

    var body: some View {
        Group {
            if let provider {
                EditProviderFlow(provider: provider, onSave: onSave)
            } else {
                AddProviderFlow(initialPreset: initialPreset, onSave: onSave)
            }
        }
        .environment(\.theme, themeManager.currentTheme)
    }
}

// MARK: - Add Provider Flow (stepped)

private struct AddProviderFlow: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    private var theme: ThemeProtocol { themeManager.currentTheme }

    let initialPreset: ProviderPreset?
    let onSave: (RemoteProvider, String?, RemoteProviderOAuthTokens?) -> Void

    @State private var selectedPreset: ProviderPreset?
    @State private var apiKey: String = ""
    @State private var openAIAuthMode: OpenAIProviderCredentialMode = .chatGPTSubscription
    @State private var oauthTokens: RemoteProviderOAuthTokens?
    @State private var isTesting = false
    @State private var testResult: ProviderTestResult?
    @State private var hasAppeared = false

    // Known provider connection overrides for presets whose endpoint is user-specific.
    @State private var knownHost: String = ""
    @State private var knownProtocol: RemoteProviderProtocol = .https
    @State private var knownPort: String = ""
    @State private var knownBasePath: String = "/v1"
    @State private var manualModelIdsText: String = ""

    // Custom provider fields
    @State private var customName: String = ""
    @State private var customHost: String = ""
    @State private var customProtocol: RemoteProviderProtocol = .https
    @State private var customPort: String = ""
    @State private var customBasePath: String = "/v1"
    @State private var customAuthType: RemoteProviderAuthType = .none

    // Advanced settings
    @State private var showAdvanced = false
    @State private var timeout: Double = 60
    @State private var customHeaders: [HeaderEntry] = []

    private var canTest: Bool {
        guard let preset = selectedPreset else { return false }
        if preset == .custom {
            return !customHost.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if preset == .azureOpenAI {
            return !knownHost.trimmingCharacters(in: .whitespaces).isEmpty && !apiKey.isEmpty && apiKey.count > 5
        }
        if preset == .openai && openAIAuthMode == .chatGPTSubscription {
            return true
        }
        return !apiKey.isEmpty && apiKey.count > 5
    }

    private var canSaveKnownProviderWithoutSuccessfulTest: Bool {
        guard selectedPreset == .azureOpenAI else { return false }
        return canTest && !parseManualModelIds(manualModelIdsText).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            sheetHeader

            // Content - stepped flow
            ZStack {
                if selectedPreset == nil {
                    providerSelectionStep
                        .transition(stepTransition)
                } else if selectedPreset == .custom {
                    customProviderStep
                        .transition(stepTransition)
                } else {
                    knownProviderStep
                        .transition(stepTransition)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selectedPreset)
        }
        .frame(width: 540, height: 620)
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
            if let initialPreset {
                initializeKnownConnection(for: initialPreset)
                selectedPreset = initialPreset
            }
            withAnimation { hasAppeared = true }
        }
    }

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 30)).combined(with: .scale(scale: 0.98)),
            removal: .opacity.combined(with: .offset(x: -30)).combined(with: .scale(scale: 0.98))
        )
    }

    // MARK: - Header

    private var sheetHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [theme.accentColor.opacity(0.2), theme.accentColor.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "cloud.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [theme.accentColor, theme.accentColor.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("Add Provider", bundle: .module)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text("Connect to a remote API provider", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            Button(
                action: { dismiss() },
                label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(theme.tertiaryBackground))
                }
            )
            .buttonStyle(PlainButtonStyle())
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(
            theme.secondaryBackground
                .overlay(
                    LinearGradient(
                        colors: [theme.accentColor.opacity(0.03), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    // MARK: - Step 1: Provider Selection

    private var providerSelectionStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose a provider", bundle: .module)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .padding(.horizontal, 4)

                VStack(spacing: 10) {
                    ForEach(ProviderPreset.knownPresets + [.custom]) { preset in
                        ProviderSelectionCard(preset: preset) {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                initializeKnownConnection(for: preset)
                                selectedPreset = preset
                            }
                        }
                    }
                }

                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                    Text("Your API key never leaves your device.", bundle: .module)
                        .font(.system(size: 12))
                }
                .foregroundColor(theme.tertiaryText)
                .padding(.top, 4)
            }
            .padding(24)
        }
    }

    // MARK: - Step 2a: Known Provider (API key only)

    private var knownProviderStep: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Back button
                    backToSelectionButton

                    // Title
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: selectedPreset?.gradient ?? [theme.tertiaryBackground],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 40, height: 40)
                            Image(systemName: selectedPreset?.icon ?? "cloud")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.white)
                        }

                        Text("Connect \(selectedPreset?.name ?? "Provider")", bundle: .module)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                    }

                    if selectedPreset == .openai {
                        openAIAuthChoiceSection
                    }

                    if selectedPreset == .azureOpenAI {
                        azureConnectionSection
                        azureDeploymentsSection
                    }

                    if selectedPreset != .openai || openAIAuthMode == .platformAPIKey {
                        apiKeySection
                    }

                    // Help section
                    if let preset = selectedPreset, preset.isKnown, !preset.consoleURL.isEmpty,
                        preset != .openai || openAIAuthMode == .platformAPIKey
                    {
                        helpSection(for: preset)
                    }

                    // Advanced settings toggle
                    advancedSettingsSection
                }
                .padding(24)
            }

            // Footer
            sheetFooter(canProceed: canTest) {
                if testResult?.isSuccess == true || canSaveKnownProviderWithoutSuccessfulTest {
                    saveKnownProvider()
                } else {
                    testKnownProvider()
                }
            }
        }
    }

    // MARK: - Step 2b: Custom Provider

    private var customProviderStep: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Back button
                    backToSelectionButton

                    // Title
                    Text("Connect custom provider", bundle: .module)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    // Connection form card
                    VStack(alignment: .leading, spacing: 0) {
                        connectionFormSection

                        sectionDivider

                        // Authentication section inside card
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                Image(systemName: "key.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(theme.accentColor)
                                Text("AUTHENTICATION", bundle: .module)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(theme.secondaryText)
                                    .tracking(0.5)
                            }

                            SegmentedToggle {
                                SegmentedToggleButton("No Auth", isSelected: customAuthType == .none) {
                                    customAuthType = .none
                                }
                                SegmentedToggleButton("API Key", isSelected: customAuthType == .apiKey) {
                                    customAuthType = .apiKey
                                }
                            }

                            if customAuthType == .apiKey {
                                ProviderSecureField(placeholder: "sk-...", text: $apiKey)
                                    .onChange(of: apiKey) { _, _ in testResult = nil }
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .padding(16)
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: customAuthType)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(theme.cardBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(theme.cardBorder, lineWidth: 1)
                            )
                    )

                    // Advanced settings toggle
                    advancedSettingsSection
                }
                .padding(24)
            }

            // Footer
            sheetFooter(canProceed: canTestCustom) {
                if testResult?.isSuccess == true {
                    saveCustomProvider()
                } else {
                    testCustomProvider()
                }
            }
        }
    }

    // MARK: - Shared Components

    private var backToSelectionButton: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                selectedPreset = nil
                apiKey = ""
                oauthTokens = nil
                openAIAuthMode = .chatGPTSubscription
                testResult = nil
                customName = ""
                customHost = ""
                customPort = ""
                customBasePath = "/v1"
                customProtocol = .https
                customAuthType = .none
                knownHost = ""
                knownProtocol = .https
                knownPort = ""
                knownBasePath = "/v1"
                manualModelIdsText = ""
                showAdvanced = false
                timeout = 60
                customHeaders = []
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                Text("Back", bundle: .module)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(theme.secondaryText)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func initializeKnownConnection(for preset: ProviderPreset) {
        let config = preset.configuration
        knownHost = config.host
        knownProtocol = config.providerProtocol
        knownPort = config.port.map(String.init) ?? ""
        knownBasePath = config.basePath
        manualModelIdsText = ""
        testResult = nil
    }

    private var azureConnectionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "network")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                Text("AZURE ENDPOINT", bundle: .module)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.secondaryText)
                    .tracking(0.5)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PROTOCOL", bundle: .module)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(theme.tertiaryText)
                        .tracking(0.5)

                    SegmentedToggle {
                        SegmentedToggleButton("HTTPS", isSelected: knownProtocol == .https) { knownProtocol = .https }
                        SegmentedToggleButton("HTTP", isSelected: knownProtocol == .http) { knownProtocol = .http }
                    }
                }
                .frame(width: 140)

                ProviderTextField(
                    label: "Host",
                    placeholder: "resource.cognitiveservices.azure.com",
                    text: $knownHost,
                    isMonospaced: true
                )
                .onChange(of: knownHost) { _, _ in testResult = nil }
            }

            HStack(spacing: 12) {
                ProviderTextField(
                    label: "Port",
                    placeholder: knownProtocol == .https ? "443" : "80",
                    text: $knownPort,
                    isMonospaced: true
                )
                .frame(width: 90)
                .onChange(of: knownPort) { _, _ in testResult = nil }

                ProviderTextField(
                    label: "Base Path",
                    placeholder: "/openai/v1",
                    text: $knownBasePath,
                    isMonospaced: true
                )
                .onChange(of: knownBasePath) { _, _ in testResult = nil }
            }

            if !knownHost.trimmingCharacters(in: .whitespaces).isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .font(.system(size: 11))
                        .foregroundColor(theme.accentColor)
                    Text(buildKnownEndpointPreview())
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.accentColor.opacity(0.1))
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private var azureDeploymentsSection: some View {
        DeploymentNamesEditor(
            text: $manualModelIdsText,
            title: "DEPLOYMENT NAMES",
            placeholder: "gpt-5.4\nmy-prod-chat",
            theme: theme
        )
        .onChange(of: manualModelIdsText) { _, _ in testResult = nil }
    }

    private func buildKnownEndpointPreview() -> String {
        var result = "\(knownProtocol.rawValue)://\(knownHost.trimmingCharacters(in: .whitespaces))"
        if let port = Int(knownPort), port != knownProtocol.defaultPort {
            result += ":\(port)"
        }
        let path = knownBasePath.trimmingCharacters(in: .whitespaces)
        result += path.isEmpty ? "/openai/v1" : (path.hasPrefix("/") ? path : "/" + path)
        return result
    }

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(selectedPreset == .openai ? "OPENAI PLATFORM API KEY" : "API KEY", bundle: .module)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(theme.tertiaryText)
                    .tracking(0.5)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                    Text("Stored in Keychain", bundle: .module)
                        .font(.system(size: 10))
                }
                .foregroundColor(theme.tertiaryText)
            }

            ProviderSecureField(placeholder: "sk-...", text: $apiKey)
                .onChange(of: apiKey) { _, _ in testResult = nil }
        }
    }

    private var openAIAuthChoiceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HOW DO YOU WANT TO CONNECT?", bundle: .module)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(theme.tertiaryText)
                .tracking(0.5)

            VStack(spacing: 10) {
                openAIAuthChoiceCard(
                    mode: .chatGPTSubscription,
                    title: OpenAIProviderCredentialMode.chatGPTSubscription.title,
                    subtitle: OpenAIProviderCredentialMode.chatGPTSubscription.subtitle,
                    icon: OpenAIProviderCredentialMode.chatGPTSubscription.icon
                )
                openAIAuthChoiceCard(
                    mode: .platformAPIKey,
                    title: OpenAIProviderCredentialMode.platformAPIKey.title,
                    subtitle: OpenAIProviderCredentialMode.platformAPIKey.subtitle,
                    icon: OpenAIProviderCredentialMode.platformAPIKey.icon
                )
            }
        }
    }

    private func openAIAuthChoiceCard(
        mode: OpenAIProviderCredentialMode,
        title: String,
        subtitle: String,
        icon: String
    ) -> some View {
        let selected = openAIAuthMode == mode
        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                openAIAuthMode = mode
                testResult = nil
                oauthTokens = nil
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(selected ? theme.accentColor : theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(selected ? theme.accentColor.opacity(0.12) : theme.tertiaryBackground))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(selected ? theme.accentColor : theme.tertiaryText)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(selected ? theme.accentColor.opacity(0.08) : theme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(selected ? theme.accentColor.opacity(0.55) : theme.cardBorder, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func helpSection(for preset: ProviderPreset) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Don't have a key?", bundle: .module)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.secondaryText)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(preset.helpSteps.enumerated()), id: \.offset) { index, text in
                    helpStep(number: index + 1, text: text)
                }
            }

            ProviderHelpLinks(
                preset: preset,
                accentColor: theme.accentColor,
                secondaryTextColor: theme.secondaryText
            )
            .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private func helpStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number).", bundle: .module)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 16, alignment: .trailing)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
        }
    }

    // MARK: - Connection Form (Custom Provider)

    private var connectionFormSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "network")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                Text("CONNECTION", bundle: .module)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.secondaryText)
                    .tracking(0.5)
            }

            ProviderTextField(label: "Name", placeholder: "e.g. My Provider", text: $customName)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PROTOCOL", bundle: .module)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(theme.tertiaryText)
                        .tracking(0.5)

                    SegmentedToggle {
                        SegmentedToggleButton("HTTPS", isSelected: customProtocol == .https) { customProtocol = .https }
                        SegmentedToggleButton("HTTP", isSelected: customProtocol == .http) { customProtocol = .http }
                    }
                }
                .frame(width: 140)

                ProviderTextField(label: "Host", placeholder: "api.example.com", text: $customHost, isMonospaced: true)
            }

            HStack(spacing: 12) {
                ProviderTextField(
                    label: "Port",
                    placeholder: customProtocol == .https ? "443" : "80",
                    text: $customPort,
                    isMonospaced: true
                )
                .frame(width: 90)

                ProviderTextField(
                    label: "Base Path",
                    placeholder: "/v1",
                    text: $customBasePath,
                    isMonospaced: true
                )
            }

            if !customHost.trimmingCharacters(in: .whitespaces).isEmpty {
                endpointPreview
            }
        }
        .padding(16)
    }

    private var endpointPreview: some View {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.accentColor.opacity(0.1))
        )
    }

    private func buildEndpointPreview() -> String {
        var result = customProtocol == .https ? "https://" : "http://"
        result += customHost.trimmingCharacters(in: .whitespaces)
        if !customPort.trimmingCharacters(in: .whitespaces).isEmpty {
            result += ":\(customPort.trimmingCharacters(in: .whitespaces))"
        }
        let path = customBasePath.trimmingCharacters(in: .whitespaces)
        result += path.isEmpty ? "/v1" : (path.hasPrefix("/") ? path : "/" + path)
        return result
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(theme.cardBorder)
            .frame(height: 1)
            .padding(.horizontal, 16)
    }

    // MARK: - Advanced Settings

    private var advancedSettingsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(
                action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showAdvanced.toggle()
                    }
                },
                label: {
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
            )
            .buttonStyle(PlainButtonStyle())

            if showAdvanced {
                VStack(alignment: .leading, spacing: 16) {
                    // Timeout
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("REQUEST TIMEOUT", bundle: .module)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(theme.tertiaryText)
                                .tracking(0.5)
                            Spacer()
                            Text("\(Int(timeout))s", bundle: .module)
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
                            Text("CUSTOM HEADERS", bundle: .module)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(theme.tertiaryText)
                                .tracking(0.5)
                            Spacer()
                            Button(
                                action: {
                                    customHeaders.append(HeaderEntry(key: "", value: "", isSecret: false))
                                },
                                label: {
                                    Image(systemName: "plus")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(theme.accentColor)
                                        .frame(width: 24, height: 24)
                                        .background(Circle().fill(theme.accentColor.opacity(0.1)))
                                }
                            )
                            .buttonStyle(PlainButtonStyle())
                        }

                        if customHeaders.isEmpty {
                            Text("No custom headers configured", bundle: .module)
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
                .padding(.top, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Footer

    private func sheetFooter(canProceed: Bool, onAction: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            testResultBadge

            Spacer()

            Button {
                dismiss()
            } label: {
                Text("Cancel", bundle: .module)
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

            Button(action: onAction) {
                HStack(spacing: 6) {
                    if isTesting {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 14, height: 14)
                    }
                    Text(actionButtonTitle)
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(canProceed ? actionButtonColor : theme.accentColor.opacity(0.4))
                )
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(!canProceed || isTesting)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            theme.secondaryBackground
                .overlay(
                    Rectangle().fill(theme.primaryBorder).frame(height: 1),
                    alignment: .top
                )
        )
    }

    @ViewBuilder
    private var testResultBadge: some View {
        if let result = testResult {
            HStack(spacing: 6) {
                switch result {
                case .success(let models):
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(theme.successColor)
                    Text("\(models.count) model\(models.count == 1 ? "" : "s") found", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.successColor)
                case .failure(let error):
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(theme.errorColor)
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(theme.errorColor)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(result.isSuccess ? theme.successColor.opacity(0.1) : theme.errorColor.opacity(0.1))
            )
        }
    }

    private var actionButtonTitle: String {
        if isTesting { return openAIAuthMode == .chatGPTSubscription ? L("Signing in...") : L("Testing...") }
        if testResult?.isSuccess == true || canSaveKnownProviderWithoutSuccessfulTest { return L("Add Provider") }
        if case .failure = testResult { return L("Retry") }
        if selectedPreset == .openai && openAIAuthMode == .chatGPTSubscription {
            return L("Sign in with ChatGPT")
        }
        return L("Test Connection")
    }

    private var actionButtonColor: Color {
        if testResult?.isSuccess == true || canSaveKnownProviderWithoutSuccessfulTest { return theme.successColor }
        if case .failure = testResult { return theme.errorColor }
        return theme.accentColor
    }

    private var canTestCustom: Bool {
        !customHost.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Actions

    func testKnownProvider() {
        guard let preset = selectedPreset else { return }
        let config = preset.configuration
        let connection = knownProviderConnection(for: preset)

        isTesting = true
        testResult = nil

        Task {
            do {
                let models: [String]
                if preset == .openai && openAIAuthMode == .chatGPTSubscription {
                    let tokens = try await OpenAICodexOAuthService.signIn()
                    await MainActor.run {
                        oauthTokens = tokens
                    }
                    models = OpenAICodexOAuthService.supportedModels
                } else {
                    models = try await RemoteProviderManager.shared.testConnection(
                        host: connection.host,
                        providerProtocol: connection.providerProtocol,
                        port: connection.port,
                        basePath: connection.basePath,
                        authType: .apiKey,
                        providerType: config.providerType,
                        apiKey: apiKey,
                        headers: HeaderEntry.buildHeaders(from: customHeaders)
                    )
                }
                await MainActor.run {
                    withAnimation {
                        testResult = .success(models); isTesting = false
                    }
                }
            } catch {
                await MainActor.run {
                    withAnimation {
                        testResult = .failure(error.localizedDescription); isTesting = false
                    }
                }
            }
        }
    }

    private func saveKnownProvider() {
        guard let preset = selectedPreset else { return }
        let config = preset.configuration
        let connection = knownProviderConnection(for: preset)
        let (regularHeaders, secretKeys) = HeaderEntry.partition(customHeaders)
        let isCodexOAuth = preset == .openai && openAIAuthMode == .chatGPTSubscription
        let providerConfig = isCodexOAuth ? OpenAICodexOAuthService.makeProvider() : nil

        let remoteProvider = RemoteProvider(
            id: providerConfig?.id ?? UUID(),
            name: providerConfig?.name ?? config.name,
            host: providerConfig?.host ?? connection.host,
            providerProtocol: providerConfig?.providerProtocol ?? connection.providerProtocol,
            port: providerConfig?.port ?? connection.port,
            basePath: providerConfig?.basePath ?? connection.basePath,
            customHeaders: regularHeaders,
            authType: providerConfig?.authType ?? .apiKey,
            providerType: providerConfig?.providerType ?? config.providerType,
            enabled: true,
            autoConnect: true,
            timeout: timeout,
            manualModelIds: parseManualModelIds(manualModelIdsText),
            secretHeaderKeys: secretKeys
        )

        saveSecretHeaders(for: remoteProvider.id)
        onSave(remoteProvider, isCodexOAuth ? nil : (apiKey.isEmpty ? nil : apiKey), isCodexOAuth ? oauthTokens : nil)
        dismiss()
    }

    func testCustomProvider() {
        let trimmedHost = customHost.trimmingCharacters(in: .whitespaces)
        let trimmedBasePath = customBasePath.trimmingCharacters(in: .whitespaces)
        let port: Int? = customPort.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Int(customPort)
        let testApiKey = customAuthType == .apiKey && !apiKey.isEmpty ? apiKey : nil

        isTesting = true
        testResult = nil

        Task {
            do {
                let models = try await RemoteProviderManager.shared.testConnection(
                    host: trimmedHost,
                    providerProtocol: customProtocol,
                    port: port,
                    basePath: trimmedBasePath.isEmpty ? "/v1" : trimmedBasePath,
                    authType: customAuthType,
                    providerType: .openaiLegacy,
                    apiKey: testApiKey,
                    headers: HeaderEntry.buildHeaders(from: customHeaders)
                )
                await MainActor.run {
                    withAnimation {
                        testResult = .success(models); isTesting = false
                    }
                }
            } catch {
                await MainActor.run {
                    withAnimation {
                        testResult = .failure(error.localizedDescription); isTesting = false
                    }
                }
            }
        }
    }

    private func saveCustomProvider() {
        let trimmedName = customName.trimmingCharacters(in: .whitespaces)
        let trimmedHost = customHost.trimmingCharacters(in: .whitespaces)
        let trimmedBasePath = customBasePath.trimmingCharacters(in: .whitespaces)
        let (regularHeaders, secretKeys) = HeaderEntry.partition(customHeaders)

        let remoteProvider = RemoteProvider(
            name: trimmedName.isEmpty ? "Custom Provider" : trimmedName,
            host: trimmedHost,
            providerProtocol: customProtocol,
            port: Int(customPort),
            basePath: trimmedBasePath.isEmpty ? "/v1" : trimmedBasePath,
            customHeaders: regularHeaders,
            authType: customAuthType,
            providerType: .openaiLegacy,
            enabled: true,
            autoConnect: true,
            timeout: timeout,
            secretHeaderKeys: secretKeys
        )

        saveSecretHeaders(for: remoteProvider.id)
        let savedApiKey = customAuthType == .apiKey && !apiKey.isEmpty ? apiKey : nil
        onSave(remoteProvider, savedApiKey, nil)
        dismiss()
    }

    private func saveSecretHeaders(for providerId: UUID) {
        for header in customHeaders where header.isSecret && !header.key.isEmpty && !header.value.isEmpty {
            RemoteProviderKeychain.saveHeaderSecret(header.value, key: header.key, for: providerId)
        }
    }

    private func knownProviderConnection(for preset: ProviderPreset) -> ProviderPresetConfiguration {
        let config = preset.configuration
        guard preset == .azureOpenAI else { return config }

        let trimmedHost = knownHost.trimmingCharacters(in: .whitespaces)
        let trimmedBasePath = knownBasePath.trimmingCharacters(in: .whitespaces)
        let port: Int? = knownPort.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Int(knownPort)

        return ProviderPresetConfiguration(
            name: config.name,
            host: trimmedHost,
            providerProtocol: knownProtocol,
            port: port,
            basePath: trimmedBasePath.isEmpty ? "/openai/v1" : trimmedBasePath,
            authType: config.authType,
            providerType: config.providerType
        )
    }
}

// MARK: - Edit Provider Flow (simplified)

private struct EditProviderFlow: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    private var theme: ThemeProtocol { themeManager.currentTheme }

    let provider: RemoteProvider
    let onSave: (RemoteProvider, String?, RemoteProviderOAuthTokens?) -> Void

    // Detect known preset
    private var matchedPreset: ProviderPreset? {
        ProviderPreset.matching(provider: provider)
    }

    // Basic settings (only shown in advanced for known providers)
    @State private var name: String = ""
    @State private var host: String = ""
    @State private var providerProtocol: RemoteProviderProtocol = .https
    @State private var portString: String = ""
    @State private var basePath: String = "/v1"
    @State private var authType: RemoteProviderAuthType = .none
    @State private var providerType: RemoteProviderType = .openaiLegacy

    // Editable fields
    @State private var apiKey: String = ""
    @State private var manualModelIdsText: String = ""

    // Advanced
    @State private var showAdvanced = false
    @State private var timeout: Double = 60
    @State private var customHeaders: [HeaderEntry] = []

    // UI state
    @State private var isTesting = false
    @State private var testResult: ProviderTestResult?
    @State private var hasAppeared = false

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let preset = matchedPreset {
                        knownProviderEditContent(preset: preset)
                    } else {
                        customProviderEditContent
                    }
                }
                .padding(24)
            }

            sheetFooter
        }
        .frame(width: 540, height: matchedPreset != nil ? 520 : 580)
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
            withAnimation { hasAppeared = true }
        }
    }

    // MARK: - Header

    private var sheetHeader: some View {
        HStack(spacing: 12) {
            if let preset = matchedPreset {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: preset.gradient,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    ProviderIcon(preset: preset, size: 16, color: .white)
                }
                .frame(width: 40, height: 40)
            } else {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [theme.accentColor.opacity(0.2), theme.accentColor.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [theme.accentColor, theme.accentColor.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .frame(width: 40, height: 40)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Edit \(provider.name)", bundle: .module)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text("Modify your API connection", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            Button(
                action: { dismiss() },
                label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(theme.tertiaryBackground))
                }
            )
            .buttonStyle(PlainButtonStyle())
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(
            theme.secondaryBackground
                .overlay(
                    LinearGradient(
                        colors: [theme.accentColor.opacity(0.03), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    // MARK: - Known Provider Edit

    private func knownProviderEditContent(preset: ProviderPreset) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            // API Key section
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("API KEY", bundle: .module)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(theme.tertiaryText)
                        .tracking(0.5)
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                        Text("Stored in Keychain", bundle: .module)
                            .font(.system(size: 10))
                    }
                    .foregroundColor(theme.tertiaryText)
                }

                ProviderSecureField(placeholder: "Leave blank to keep current", text: $apiKey)
            }

            if preset == .azureOpenAI {
                DeploymentNamesEditor(
                    text: $manualModelIdsText,
                    title: "DEPLOYMENT NAMES",
                    placeholder: "gpt-5.4\nmy-prod-chat",
                    theme: theme
                )
            }

            // Help section
            if !preset.consoleURL.isEmpty {
                helpSection(for: preset)
            }

            // Advanced settings (connection details + timeout + headers)
            advancedSettingsSection(showConnectionDetails: true)
        }
    }

    // MARK: - Custom Provider Edit

    private var customProviderEditContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Connection form
            VStack(alignment: .leading, spacing: 0) {
                connectionFormSection

                sectionDivider

                // Authentication
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(theme.accentColor)
                        Text("AUTHENTICATION", bundle: .module)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(theme.secondaryText)
                            .tracking(0.5)
                    }

                    if authType == .openAICodexOAuth {
                        HStack(spacing: 10) {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(theme.accentColor)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("ChatGPT / Codex subscription", bundle: .module)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(theme.primaryText)
                                Text("Signed in with ChatGPT Plus/Pro. Tokens are stored in Keychain.", bundle: .module)
                                    .font(.system(size: 12))
                                    .foregroundColor(theme.secondaryText)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(theme.accentColor.opacity(0.08)))
                    } else {
                        SegmentedToggle {
                            SegmentedToggleButton("No Auth", isSelected: authType == .none) { authType = .none }
                            SegmentedToggleButton("API Key", isSelected: authType == .apiKey) { authType = .apiKey }
                        }
                    }

                    if authType == .apiKey {
                        ProviderSecureField(placeholder: "Leave blank to keep current", text: $apiKey)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(16)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: authType)
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(theme.cardBorder, lineWidth: 1)
                    )
            )

            // Advanced settings (timeout + headers only)
            advancedSettingsSection(showConnectionDetails: false)
        }
    }

    // MARK: - Connection Form (Edit)

    private var connectionFormSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "network")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                Text("CONNECTION", bundle: .module)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.secondaryText)
                    .tracking(0.5)
            }

            ProviderTextField(label: "Name", placeholder: "e.g. My Provider", text: $name)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PROTOCOL", bundle: .module)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(theme.tertiaryText)
                        .tracking(0.5)

                    SegmentedToggle {
                        SegmentedToggleButton("HTTPS", isSelected: providerProtocol == .https) {
                            providerProtocol = .https
                        }
                        SegmentedToggleButton("HTTP", isSelected: providerProtocol == .http) {
                            providerProtocol = .http
                        }
                    }
                }
                .frame(width: 140)

                ProviderTextField(label: "Host", placeholder: "api.example.com", text: $host, isMonospaced: true)
            }

            HStack(spacing: 12) {
                ProviderTextField(
                    label: "Port",
                    placeholder: providerProtocol == .https ? "443" : "80",
                    text: $portString,
                    isMonospaced: true
                )
                .frame(width: 90)

                ProviderTextField(label: "Base Path", placeholder: "/v1", text: $basePath, isMonospaced: true)
            }

            if !host.trimmingCharacters(in: .whitespaces).isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .font(.system(size: 11))
                        .foregroundColor(theme.accentColor)
                    Text(buildEditEndpointPreview())
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.accentColor.opacity(0.1))
                )
            }
        }
        .padding(16)
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(theme.cardBorder)
            .frame(height: 1)
            .padding(.horizontal, 16)
    }

    private func buildEditEndpointPreview() -> String {
        var result = "\(providerProtocol.rawValue)://\(host.trimmingCharacters(in: .whitespaces))"
        if let port = Int(portString), port != providerProtocol.defaultPort {
            result += ":\(port)"
        }
        let normalizedPath = basePath.hasPrefix("/") ? basePath : "/" + basePath
        result += normalizedPath
        return result
    }

    // MARK: - Help Section (Edit)

    private func helpSection(for preset: ProviderPreset) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Need a new key?", bundle: .module)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.secondaryText)

            ProviderHelpLinks(
                preset: preset,
                accentColor: theme.accentColor,
                secondaryTextColor: theme.secondaryText
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    // MARK: - Advanced Settings (Edit)

    private func advancedSettingsSection(showConnectionDetails: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(
                action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showAdvanced.toggle()
                    }
                },
                label: {
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
            )
            .buttonStyle(PlainButtonStyle())

            if showAdvanced {
                VStack(alignment: .leading, spacing: 16) {
                    // Connection details (for known provider edit)
                    if showConnectionDetails {
                        VStack(alignment: .leading, spacing: 0) {
                            connectionFormSection
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

                    // Timeout
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("REQUEST TIMEOUT", bundle: .module)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(theme.tertiaryText)
                                .tracking(0.5)
                            Spacer()
                            Text("\(Int(timeout))s", bundle: .module)
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
                            Text("CUSTOM HEADERS", bundle: .module)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(theme.tertiaryText)
                                .tracking(0.5)
                            Spacer()
                            Button(
                                action: {
                                    customHeaders.append(HeaderEntry(key: "", value: "", isSecret: false))
                                },
                                label: {
                                    Image(systemName: "plus")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(theme.accentColor)
                                        .frame(width: 24, height: 24)
                                        .background(Circle().fill(theme.accentColor.opacity(0.1)))
                                }
                            )
                            .buttonStyle(PlainButtonStyle())
                        }

                        if customHeaders.isEmpty {
                            Text("No custom headers configured", bundle: .module)
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
                .padding(.top, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Footer

    private var sheetFooter: some View {
        HStack(spacing: 12) {
            // Test result badge
            testResultBadge

            Spacer()

            Button {
                dismiss()
            } label: {
                Text("Cancel", bundle: .module)
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

            Button(action: save) {
                Text("Save Changes", bundle: .module)
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
                    Rectangle().fill(theme.primaryBorder).frame(height: 1),
                    alignment: .top
                )
        )
    }

    @ViewBuilder
    private var testResultBadge: some View {
        // Test button
        Button(
            action: {
                if testResult != nil { testResult = nil } else { testConnection() }
            },
            label: {
                HStack(spacing: 6) {
                    if isTesting {
                        ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                    } else if let result = testResult {
                        Image(systemName: result.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 12))
                    } else {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 11))
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
        )
        .buttonStyle(PlainButtonStyle())
        .disabled(isTesting)
    }

    private var testButtonLabel: String {
        if isTesting { return L("Testing...") }
        if let result = testResult {
            switch result {
            case .success(let models): return "\(models.count) models"
            case .failure: return L("Retry")
            }
        }
        return L("Test")
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
        if matchedPreset != nil {
            // Known provider: always saveable (name/host come from preset or advanced)
            if providerType == .azureOpenAI {
                return !host.trimmingCharacters(in: .whitespaces).isEmpty
            }
            return true
        }
        return !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !host.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Actions

    private func loadProvider() {
        name = provider.name
        host = provider.host
        providerProtocol = provider.providerProtocol
        if let port = provider.port { portString = String(port) }
        basePath = provider.basePath
        authType = provider.authType
        providerType = provider.providerType
        timeout = provider.timeout
        manualModelIdsText = provider.manualModelIds.joined(separator: "\n")
        customHeaders = provider.customHeaders.map { HeaderEntry(key: $0.key, value: $0.value, isSecret: false) }
        for key in provider.secretHeaderKeys {
            customHeaders.append(HeaderEntry(key: key, value: "", isSecret: true))
        }
    }

    func testConnection() {
        isTesting = true
        testResult = nil

        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedBasePath = basePath.trimmingCharacters(in: .whitespaces)
        let port: Int? = portString.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Int(portString)
        let testApiKey =
            authType == .apiKey ? (!apiKey.isEmpty ? apiKey : RemoteProviderKeychain.getAPIKey(for: provider.id)) : nil

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
                    headers: HeaderEntry.buildHeaders(from: customHeaders)
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
        let (regularHeaders, secretKeys) = HeaderEntry.partition(customHeaders)

        let updatedProvider = RemoteProvider(
            id: provider.id,
            name: trimmedName,
            host: trimmedHost,
            providerProtocol: providerProtocol,
            port: Int(portString),
            basePath: basePath,
            customHeaders: regularHeaders,
            authType: authType,
            providerType: providerType,
            enabled: provider.enabled,
            autoConnect: true,
            timeout: timeout,
            manualModelIds: parseManualModelIds(manualModelIdsText),
            secretHeaderKeys: secretKeys
        )

        for header in customHeaders where header.isSecret && !header.key.isEmpty && !header.value.isEmpty {
            RemoteProviderKeychain.saveHeaderSecret(header.value, key: header.key, for: updatedProvider.id)
        }

        onSave(updatedProvider, apiKey.isEmpty ? nil : apiKey, nil)
        dismiss()
    }
}

// MARK: - Provider Selection Card

private struct ProviderSelectionCard: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let preset: ProviderPreset
    let action: () -> Void

    @State private var isHovered = false

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(
                            LinearGradient(
                                colors: isHovered
                                    ? preset.gradient : [theme.tertiaryBackground, theme.tertiaryBackground],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 42, height: 42)

                    ProviderIcon(preset: preset, size: 16, color: isHovered ? .white : theme.secondaryText)
                }

                // Text
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(preset.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.primaryText)

                        if let badge = preset.badge {
                            ProviderBadge(badge, gradient: preset.gradient)
                        }
                    }
                    Text(preset.description)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()

                // Arrow
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                isHovered ? theme.accentColor.opacity(0.4) : theme.cardBorder,
                                lineWidth: 1
                            )
                    )
            )
            .scaleEffect(isHovered ? 1.01 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Segmented Toggle

private struct SegmentedToggle<Content: View>: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        HStack(spacing: 0) {
            content()
        }
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

private struct SegmentedToggleButton: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let label: String
    let isSelected: Bool
    let action: () -> Void

    init(_ label: String, isSelected: Bool, action: @escaping () -> Void) {
        self.label = label
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundColor(
                    isSelected ? themeManager.currentTheme.primaryText : themeManager.currentTheme.tertiaryText
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? themeManager.currentTheme.tertiaryBackground : Color.clear)
                )
        }
        .buttonStyle(PlainButtonStyle())
        .padding(2)
    }
}

// MARK: - Shared Helper Types

private enum ProviderTestResult {
    case success([String])
    case failure(String)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

struct HeaderEntry: Identifiable {
    let id = UUID()
    var key: String
    var value: String
    var isSecret: Bool

    /// Build a flat dictionary of non-empty headers.
    static func buildHeaders(from entries: [HeaderEntry]) -> [String: String] {
        var headers: [String: String] = [:]
        for entry in entries where !entry.key.isEmpty && !entry.value.isEmpty {
            headers[entry.key] = entry.value
        }
        return headers
    }

    /// Partition entries into regular headers dict and secret key names.
    static func partition(_ entries: [HeaderEntry]) -> (regular: [String: String], secretKeys: [String]) {
        var regular: [String: String] = [:]
        var secretKeys: [String] = []
        for entry in entries where !entry.key.isEmpty {
            if entry.isSecret { secretKeys.append(entry.key) } else { regular[entry.key] = entry.value }
        }
        return (regular, secretKeys)
    }
}

// MARK: - Compact Header Row

private struct CompactHeaderRow: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Binding var header: HeaderEntry
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField(text: $header.key, prompt: Text("Key", bundle: .module)) {
                Text("Key", bundle: .module)
            }
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
                    SecureField(L("Value"), text: $header.value)
                } else {
                    TextField(text: $header.value, prompt: Text("Value", bundle: .module)) {
                        Text("Value", bundle: .module)
                    }
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

            Button(
                action: { header.isSecret.toggle() },
                label: {
                    Image(systemName: header.isSecret ? "lock.fill" : "lock.open")
                        .font(.system(size: 10))
                        .foregroundColor(
                            header.isSecret
                                ? themeManager.currentTheme.accentColor : themeManager.currentTheme.tertiaryText
                        )
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(themeManager.currentTheme.tertiaryBackground))
                }
            )
            .buttonStyle(PlainButtonStyle())
            .help(Text(header.isSecret ? L("This value is stored securely") : L("Click to make this a secret value")))

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(themeManager.currentTheme.tertiaryBackground))
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
            Text(LocalizedStringKey(label), bundle: .module)
                .textCase(.uppercase)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(themeManager.currentTheme.tertiaryText)
                .tracking(0.5)

            HStack(spacing: 10) {
                ZStack(alignment: .leading) {
                    if text.isEmpty {
                        Text(LocalizedStringKey(placeholder), bundle: .module)
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

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(LocalizedStringKey(placeholder), bundle: .module)
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

// MARK: - Deployment Names Editor

private struct DeploymentNamesEditor: View {
    @Binding var text: String
    let title: String
    let placeholder: String
    let theme: ThemeProtocol

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(title), bundle: .module)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(theme.tertiaryText)
                .tracking(0.5)

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(theme.placeholderText)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $text)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 6)
            }
            .frame(minHeight: 82)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }
}

// MARK: - Preview

#Preview {
    RemoteProviderEditSheet(provider: nil) { _, _, _ in }
        .environment(\.theme, DarkTheme())
}
