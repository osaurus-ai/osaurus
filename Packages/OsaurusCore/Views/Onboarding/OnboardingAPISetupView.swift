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
    case xai
    case other

    var id: String { rawValue }

    var name: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .xai: return "xAI"
        case .other: return "Other provider..."
        }
    }

    var description: String {
        switch self {
        case .anthropic: return "Claude models"
        case .openai: return "GPT-4o, o1, etc."
        case .xai: return "Grok models"
        case .other: return "Custom endpoint"
        }
    }

    var icon: String {
        switch self {
        case .anthropic: return "brain.head.profile"
        case .openai: return "sparkles"
        case .xai: return "bolt.fill"
        case .other: return "slider.horizontal.3"
        }
    }

    var consoleURL: String {
        switch self {
        case .anthropic: return "https://console.anthropic.com/settings/keys"
        case .openai: return "https://platform.openai.com/api-keys"
        case .xai: return "https://console.x.ai/"
        case .other: return ""
        }
    }

    var host: String {
        switch self {
        case .anthropic: return "api.anthropic.com"
        case .openai: return "api.openai.com"
        case .xai: return "api.x.ai"
        case .other: return ""
        }
    }

    var providerType: RemoteProviderType {
        switch self {
        case .anthropic: return .anthropic
        case .openai, .xai, .other: return .openai
        }
    }
}

// MARK: - API Setup View

struct OnboardingAPISetupView: View {
    let onComplete: () -> Void
    let onSkip: () -> Void

    @Environment(\.theme) private var theme
    @State private var selectedProvider: OnboardingProviderOption? = nil
    @State private var apiKey: String = ""
    @State private var isTesting = false
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

    var body: some View {
        VStack(spacing: 0) {
            if selectedProvider == nil {
                providerSelectionView
            } else if selectedProvider == .other {
                customProviderEntryView
            } else {
                apiKeyEntryView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation {
                    hasAppeared = true
                }
            }
        }
    }

    // MARK: - Provider Selection View

    private var providerSelectionView: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 60)

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
                        withAnimation(theme.springAnimation()) {
                            selectedProvider = provider
                        }
                    }
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 15)
                    .animation(theme.springAnimation().delay(0.17 + Double(index) * 0.05), value: hasAppeared)
                }
            }
            .padding(.horizontal, 40)

            Spacer().frame(height: 28)

            // Footer
            Text("Your API key stays on your Mac. Osaurus never sees it.")
                .font(theme.font(size: 13))
                .foregroundColor(theme.tertiaryText)
                .opacity(hasAppeared ? 1 : 0)
                .animation(theme.springAnimation().delay(0.4), value: hasAppeared)

            Spacer()

            // Skip option
            OnboardingTextButton(title: "Skip for now", action: onSkip)
                .opacity(hasAppeared ? 1 : 0)
                .animation(theme.springAnimation().delay(0.45), value: hasAppeared)

            Spacer().frame(height: 50)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - API Key Entry View (for known providers)

    private var apiKeyEntryView: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 30)

            // Back button
            backButton
                .padding(.horizontal, 40)

            Spacer().frame(height: 30)

            // Headline
            Text("Connect \(selectedProvider?.name ?? "Provider")")
                .font(theme.font(size: 26, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .multilineTextAlignment(.center)

            Spacer().frame(height: 36)

            // API Key field
            VStack(alignment: .leading, spacing: 10) {
                OnboardingSecureField(placeholder: "sk-...", text: $apiKey, label: "API Key")
                    .onChange(of: apiKey) { _, _ in
                        testResult = nil
                    }

                // Test result indicator
                testResultView
            }
            .padding(.horizontal, 40)

            Spacer().frame(height: 28)

            // Help section
            if let provider = selectedProvider, provider != .other {
                helpSection(for: provider)
                    .padding(.horizontal, 40)
            }

            Spacer()

            // Action buttons
            actionButtons
                .frame(width: 200)

            Spacer().frame(height: 50)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Custom Provider Entry View

    private var customProviderEntryView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                Spacer().frame(height: 30)

                // Back button
                backButton
                    .padding(.horizontal, 40)

                Spacer().frame(height: 24)

                // Headline
                Text("Connect custom provider")
                    .font(theme.font(size: 26, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .multilineTextAlignment(.center)

                Spacer().frame(height: 32)

                // Connection fields
                VStack(spacing: 20) {
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

                    // API Key
                    OnboardingSecureField(placeholder: "sk-...", text: $apiKey, label: "API Key")
                        .onChange(of: apiKey) { _, _ in
                            testResult = nil
                        }

                    // Test result indicator
                    testResultView
                }
                .padding(.horizontal, 40)

                Spacer().frame(height: 32)

                // Action buttons
                actionButtons
                    .frame(width: 200)

                Spacer().frame(height: 50)
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Shared Components

    private var backButton: some View {
        HStack {
            Button {
                withAnimation(theme.springAnimation()) {
                    selectedProvider = nil
                    apiKey = ""
                    testResult = nil
                    customName = ""
                    customHost = ""
                    customPort = ""
                    customBasePath = "/v1"
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Back")
                        .font(theme.font(size: 13, weight: .medium))
                }
                .foregroundColor(theme.secondaryText)
            }
            .buttonStyle(.plain)

            Spacer()
        }
    }

    @ViewBuilder
    private var testResultView: some View {
        if let result = testResult {
            HStack(spacing: 8) {
                switch result {
                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(theme.successColor)
                    Text("Connection successful")
                        .foregroundColor(theme.successColor)
                case .error(let message):
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(theme.errorColor)
                    Text(message)
                        .foregroundColor(theme.errorColor)
                        .lineLimit(2)
                }
            }
            .font(theme.font(size: 13))
            .transition(.opacity.combined(with: .move(edge: .top)))
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
        VStack(spacing: 12) {
            if isSuccess {
                OnboardingPrimaryButton(
                    title: "Continue",
                    action: {
                        saveProviderAndContinue()
                    }
                )
            } else {
                OnboardingPrimaryButton(
                    title: isTesting ? "Testing..." : "Test Connection",
                    action: testConnection,
                    isEnabled: canTest && !isTesting
                )
            }

            OnboardingTextButton(title: "Skip for now", action: onSkip)
        }
    }

    // MARK: - Actions

    private func testConnection() {
        guard let provider = selectedProvider else { return }

        isTesting = true
        testResult = nil

        let host: String
        let port: Int?
        let basePath: String
        let providerType: RemoteProviderType
        let providerProtocol: RemoteProviderProtocol

        if provider == .other {
            host = customHost
            port = customPort.isEmpty ? nil : Int(customPort)
            basePath = customBasePath.isEmpty ? "/v1" : customBasePath
            providerType = .openai
            providerProtocol = customProtocol
        } else {
            host = provider.host
            port = nil
            basePath = "/v1"
            providerType = provider.providerType
            providerProtocol = .https
        }

        Task {
            do {
                let _ = try await RemoteProviderManager.shared.testConnection(
                    host: host,
                    providerProtocol: providerProtocol,
                    port: port,
                    basePath: basePath,
                    authType: .apiKey,
                    providerType: providerType,
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
        guard let provider = selectedProvider else { return }

        let name: String
        let host: String
        let port: Int?
        let basePath: String
        let providerType: RemoteProviderType
        let providerProtocol: RemoteProviderProtocol

        if provider == .other {
            name = customName.isEmpty ? "Custom Provider" : customName
            host = customHost
            port = customPort.isEmpty ? nil : Int(customPort)
            basePath = customBasePath.isEmpty ? "/v1" : customBasePath
            providerType = .openai
            providerProtocol = customProtocol
        } else {
            name = provider.name
            host = provider.host
            port = nil
            basePath = "/v1"
            providerType = provider.providerType
            providerProtocol = .https
        }

        let remoteProvider = RemoteProvider(
            name: name,
            host: host,
            providerProtocol: providerProtocol,
            port: port,
            basePath: basePath,
            customHeaders: [:],
            authType: .apiKey,
            providerType: providerType,
            enabled: true,
            autoConnect: true,
            timeout: 60
        )

        RemoteProviderManager.shared.addProvider(remoteProvider, apiKey: apiKey)

        onComplete()
    }
}

// MARK: - Protocol Toggle

struct OnboardingProtocolToggle: View {
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
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
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
                onSkip: {}
            )
            .frame(width: 580, height: 700)
        }
    }
#endif
