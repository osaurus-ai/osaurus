//
//  OnboardingAPISetupView.swift
//  osaurus
//
//  Provider selection and API key entry for onboarding.
//  Includes full custom provider configuration for "Other provider" option.
//

import AppKit
import SwiftUI

// MARK: - Provider Option

/// Provider options for onboarding
enum OnboardingProviderOption: String, CaseIterable, Identifiable {
    case anthropic
    case openai
    case google
    case xai
    case other

    var id: String { rawValue }

    var name: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .google: return "Google"
        case .xai: return "xAI"
        case .other: return "Any OpenAI-compatible API"
        }
    }

    var description: String {
        switch self {
        case .anthropic: return "Claude models"
        case .openai: return "ChatGPT models"
        case .google: return "Gemini models"
        case .xai: return "Grok models"
        case .other: return "OpenRouter, MiniMax, etc."
        }
    }

    var icon: String {
        switch self {
        case .anthropic: return "brain.head.profile"
        case .openai: return "sparkles"
        case .google: return "globe"
        case .xai: return "bolt.fill"
        case .other: return "slider.horizontal.3"
        }
    }

    var consoleURL: String {
        switch self {
        case .anthropic: return "https://console.anthropic.com/settings/keys"
        case .openai: return "https://platform.openai.com/api-keys"
        case .google: return "https://aistudio.google.com/apikey"
        case .xai: return "https://console.x.ai/"
        case .other: return ""
        }
    }

    var host: String {
        switch self {
        case .anthropic: return "api.anthropic.com"
        case .openai: return "api.openai.com"
        case .google: return "generativelanguage.googleapis.com"
        case .xai: return "api.x.ai"
        case .other: return ""
        }
    }

    var providerType: RemoteProviderType {
        switch self {
        case .anthropic: return .anthropic
        case .google: return .gemini
        case .openai, .xai, .other: return .openai
        }
    }
}

// MARK: - API Setup View

struct OnboardingAPISetupView: View {
    let onComplete: () -> Void
    let onBack: () -> Void

    @Environment(\.theme) private var theme
    @State private var selectedProvider: OnboardingProviderOption? = nil
    @State private var apiKey: String = ""
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var testResult: TestResult? = nil
    @State private var hasAppeared = false

    // Custom provider fields
    @State private var customName: String = ""
    @State private var customHost: String = ""
    @State private var customProtocol: RemoteProviderProtocol = .https
    @State private var customPort: String = ""
    @State private var customBasePath: String = "/v1"

    private enum TestResult {
        case success
        case error(String)
    }

    private var canTest: Bool {
        guard let provider = selectedProvider else { return false }

        if provider == .other {
            return !customHost.isEmpty && !apiKey.isEmpty && apiKey.count > 5
        }
        return !apiKey.isEmpty && apiKey.count > 10
    }

    private var isSuccess: Bool {
        if case .success = testResult {
            return true
        }
        return false
    }

    private var buttonState: OnboardingButtonState {
        if isTesting || isSaving {
            return .loading
        }
        switch testResult {
        case .success:
            return .success
        case .error(let message):
            return .error(message)
        case nil:
            return .idle
        }
    }

    private var buttonLoadingTitle: String {
        isSaving ? "Connecting..." : "Testing..."
    }

    var body: some View {
        ZStack {
            if selectedProvider == nil {
                providerSelectionView
                    .transition(nestedTransition)
            } else if selectedProvider == .other {
                customProviderEntryView
                    .transition(nestedTransition)
            } else {
                apiKeyEntryView
                    .transition(nestedTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(theme.springAnimation(responseMultiplier: 0.8), value: selectedProvider)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + OnboardingStyle.appearDelay) {
                withAnimation {
                    hasAppeared = true
                }
            }
        }
    }

    /// Nested screen transition (consistent with main onboarding)
    private var nestedTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .offset(x: 30))
                .combined(with: .scale(scale: 0.98)),
            removal: .opacity
                .combined(with: .offset(x: -30))
                .combined(with: .scale(scale: 0.98))
        )
    }

    // MARK: - Provider Selection View

    private var providerSelectionView: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: OnboardingStyle.headerTopPadding)

            // Back button
            OnboardingBackButton(action: onBack)
                .padding(.horizontal, OnboardingStyle.backButtonHorizontalPadding)
                .opacity(hasAppeared ? 1 : 0)
                .animation(theme.springAnimation().delay(0.05), value: hasAppeared)

            Spacer().frame(height: 20)

            // Headline
            Text("Connect a provider")
                .font(theme.font(size: 26, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 20)
                .animation(theme.springAnimation().delay(0.1), value: hasAppeared)

            Spacer().frame(height: 40)

            // Provider cards
            VStack(spacing: 12) {
                ForEach(Array(OnboardingProviderOption.allCases.enumerated()), id: \.element.id) { index, provider in
                    ProviderCard(provider: provider) {
                        withAnimation(theme.springAnimation(responseMultiplier: 0.8)) {
                            selectedProvider = provider
                        }
                    }
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 15)
                    .animation(theme.springAnimation().delay(0.17 + Double(index) * 0.05), value: hasAppeared)
                }
            }
            .padding(.horizontal, OnboardingStyle.backButtonHorizontalPadding + 5)

            Spacer().frame(height: 28)

            // Footer
            Text("Your key never leaves your device.")
                .font(theme.font(size: 13))
                .foregroundColor(theme.tertiaryText)
                .opacity(hasAppeared ? 1 : 0)
                .animation(theme.springAnimation().delay(0.4), value: hasAppeared)

            Spacer()
        }
        .padding(.horizontal, 20)
    }

    // MARK: - API Key Entry View (for known providers)

    private var apiKeyEntryView: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: OnboardingStyle.headerTopPadding)

            // Back button (custom - resets state)
            backButton
                .padding(.horizontal, OnboardingStyle.backButtonHorizontalPadding)

            Spacer().frame(height: 30)

            // Headline
            Text("Connect \(selectedProvider?.name ?? "Provider")")
                .font(theme.font(size: 26, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .multilineTextAlignment(.center)

            Spacer().frame(height: 36)

            // API Key field
            OnboardingSecureField(placeholder: "sk-...", text: $apiKey, label: "API Key")
                .onChange(of: apiKey) { _, _ in
                    testResult = nil
                }
                .padding(.horizontal, OnboardingStyle.backButtonHorizontalPadding + 5)

            Spacer().frame(height: 28)

            // Help section
            if let provider = selectedProvider, provider != .other {
                helpSection(for: provider)
                    .padding(.horizontal, OnboardingStyle.backButtonHorizontalPadding + 5)
            }

            Spacer()

            // Action buttons
            actionButtons
                .frame(width: 200)

            Spacer().frame(height: OnboardingStyle.bottomButtonPadding)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Custom Provider Entry View

    private var customProviderEntryView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                Spacer().frame(height: OnboardingStyle.headerTopPadding)

                // Back button (custom - resets state)
                backButton
                    .padding(.horizontal, OnboardingStyle.backButtonHorizontalPadding)

                Spacer().frame(height: 24)

                // Headline
                Text("Connect custom provider")
                    .font(theme.font(size: 26, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .multilineTextAlignment(.center)

                Spacer().frame(height: 28)

                // Connection fields in glass card
                OnboardingGlassCard {
                    VStack(spacing: 16) {
                        // Name field
                        OnboardingTextField(
                            label: "Name",
                            placeholder: "e.g. My Provider",
                            text: $customName
                        )

                        // Protocol and Host row
                        HStack(spacing: 12) {
                            // Protocol toggle
                            VStack(alignment: .leading, spacing: 6) {
                                Text("PROTOCOL")
                                    .font(theme.font(size: 10, weight: .bold))
                                    .foregroundColor(theme.tertiaryText)
                                    .tracking(0.5)

                                OnboardingProtocolToggle(selection: $customProtocol)
                                    .frame(height: 40)
                            }
                            .frame(width: 130)

                            // Host field
                            OnboardingTextField(
                                label: "Host",
                                placeholder: "api.example.com",
                                text: $customHost,
                                isMonospaced: true
                            )
                        }

                        // Port and Base Path row
                        HStack(spacing: 12) {
                            OnboardingTextField(
                                label: "Port",
                                placeholder: customProtocol == .https ? "443" : "80",
                                text: $customPort,
                                isMonospaced: true
                            )
                            .frame(width: 100)

                            OnboardingTextField(
                                label: "Base Path",
                                placeholder: "/v1",
                                text: $customBasePath,
                                isMonospaced: true
                            )
                        }

                        // Endpoint preview
                        if !customHost.isEmpty {
                            endpointPreview
                        }
                    }
                    .padding(18)
                }
                .padding(.horizontal, OnboardingStyle.backButtonHorizontalPadding + 5)

                Spacer().frame(height: 16)

                // API Key (outside card for visual separation)
                OnboardingSecureField(placeholder: "sk-...", text: $apiKey, label: "API Key")
                    .onChange(of: apiKey) { _, _ in
                        testResult = nil
                    }
                    .padding(.horizontal, OnboardingStyle.backButtonHorizontalPadding + 5)

                Spacer().frame(height: 28)

                // Action buttons
                actionButtons
                    .frame(width: 200)

                Spacer().frame(height: OnboardingStyle.bottomButtonPadding)
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Shared Components

    /// Back button for API key/custom provider views - goes back to provider selection (with state reset)
    private var backButton: some View {
        OnboardingBackButton {
            withAnimation(theme.springAnimation(responseMultiplier: 0.8)) {
                selectedProvider = nil
                apiKey = ""
                testResult = nil
                customName = ""
                customHost = ""
                customPort = ""
                customBasePath = "/v1"
            }
        }
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
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.accentColor.opacity(0.1))
        )
    }

    private func buildEndpointPreview() -> String {
        var endpoint = customProtocol == .https ? "https://" : "http://"
        endpoint += customHost

        if !customPort.isEmpty {
            endpoint += ":\(customPort)"
        }

        let path = customBasePath.isEmpty ? "/v1" : customBasePath
        endpoint += path

        return endpoint
    }

    private func helpSection(for provider: OnboardingProviderOption) -> some View {
        OnboardingGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Don't have a key?")
                    .font(theme.font(size: 14, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                VStack(alignment: .leading, spacing: 8) {
                    HelpStep(number: 1, text: "Go to \(provider.name) console")
                    HelpStep(number: 2, text: "Sign in or create an account")
                    HelpStep(number: 3, text: "Click \"API Keys\" → \"Create Key\"")
                    HelpStep(number: 4, text: "Copy and paste it here")
                }

                Button {
                    if let url = URL(string: provider.consoleURL) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("Open \(provider.name) Console")
                            .font(theme.font(size: 13, weight: .medium))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
    }

    private var actionButtons: some View {
        OnboardingStatefulButton(
            state: buttonState,
            idleTitle: "Test Connection",
            loadingTitle: buttonLoadingTitle,
            successTitle: "Continue",
            errorTitle: "Try Again",
            action: {
                if isSuccess {
                    saveProviderAndContinue()
                } else {
                    testConnection()
                }
            },
            isEnabled: canTest
        )
    }

    // MARK: - Actions

    /// Builds provider configuration from current state
    private func buildProviderConfig() -> (
        name: String, host: String, port: Int?, basePath: String, providerType: RemoteProviderType,
        providerProtocol: RemoteProviderProtocol
    )? {
        guard let provider = selectedProvider else { return nil }

        if provider == .other {
            return (
                name: customName.isEmpty ? "Custom Provider" : customName,
                host: customHost,
                port: customPort.isEmpty ? nil : Int(customPort),
                basePath: customBasePath.isEmpty ? "/v1" : customBasePath,
                providerType: .openai,
                providerProtocol: customProtocol
            )
        } else {
            let basePath = provider == .google ? "/v1beta" : "/v1"
            return (
                name: provider.name,
                host: provider.host,
                port: nil,
                basePath: basePath,
                providerType: provider.providerType,
                providerProtocol: .https
            )
        }
    }

    private func testConnection() {
        guard let config = buildProviderConfig() else { return }

        isTesting = true
        testResult = nil

        Task {
            do {
                _ = try await RemoteProviderManager.shared.testConnection(
                    host: config.host,
                    providerProtocol: config.providerProtocol,
                    port: config.port,
                    basePath: config.basePath,
                    authType: .apiKey,
                    providerType: config.providerType,
                    apiKey: apiKey,
                    headers: [:]
                )

                await MainActor.run {
                    withAnimation(theme.springAnimation()) {
                        testResult = .success
                        isTesting = false
                    }
                }
            } catch {
                await MainActor.run {
                    withAnimation(theme.springAnimation()) {
                        testResult = .error(error.localizedDescription)
                        isTesting = false
                    }
                }
            }
        }
    }

    private func saveProviderAndContinue() {
        guard let config = buildProviderConfig() else { return }

        isSaving = true

        let remoteProvider = RemoteProvider(
            name: config.name,
            host: config.host,
            providerProtocol: config.providerProtocol,
            port: config.port,
            basePath: config.basePath,
            customHeaders: [:],
            authType: .apiKey,
            providerType: config.providerType,
            enabled: true,
            autoConnect: true,
            timeout: 60
        )

        // addProvider() already starts connect() internally for enabled providers,
        // and the app-level cache invalidation observer ensures model options update
        // when connection completes. No need to call connect() again.
        RemoteProviderManager.shared.addProvider(remoteProvider, apiKey: apiKey)

        isSaving = false
        onComplete()
    }
}

// MARK: - Protocol Toggle

private struct OnboardingProtocolToggle: View {
    @Binding var selection: RemoteProviderProtocol

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            protocolButton("HTTPS", protocol: .https)
            protocolButton("HTTP", protocol: .http)
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

    private func protocolButton(_ label: String, protocol proto: RemoteProviderProtocol) -> some View {
        Button {
            withAnimation(theme.animationQuick()) {
                selection = proto
            }
        } label: {
            Text(label)
                .font(theme.font(size: 11, weight: .semibold))
                .foregroundColor(selection == proto ? .white : theme.secondaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selection == proto ? theme.accentColor : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Provider Card

private struct ProviderCard: View {
    let provider: OnboardingProviderOption
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            OnboardingGlassCard {
                HStack(spacing: 16) {
                    // Icon
                    ZStack {
                        Circle()
                            .fill(theme.cardBackground)
                            .frame(width: 44, height: 44)

                        Image(systemName: provider.icon)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(isHovered ? theme.accentColor : theme.secondaryText)
                    }

                    // Text
                    VStack(alignment: .leading, spacing: 4) {
                        Text(provider.name)
                            .font(theme.font(size: 15, weight: .semibold))
                            .foregroundColor(theme.primaryText)

                        Text(provider.description)
                            .font(theme.font(size: 13))
                            .foregroundColor(theme.secondaryText)
                    }

                    Spacer()

                    // Arrow
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(theme.animationQuick()) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Help Step

private struct HelpStep: View {
    let number: Int
    let text: String

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number).")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 16, alignment: .trailing)

            Text(text)
                .font(theme.font(size: 12))
                .foregroundColor(theme.secondaryText)
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct OnboardingAPISetupView_Previews: PreviewProvider {
        static var previews: some View {
            OnboardingAPISetupView(
                onComplete: {},
                onBack: {}
            )
            .frame(width: 580, height: 700)
        }
    }
#endif
