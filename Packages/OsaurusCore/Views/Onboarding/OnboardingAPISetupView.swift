//
//  OnboardingAPISetupView.swift
//  osaurus
//
//  Three-substate API provider setup:
//      provider list  ->  API-key form (known providers)
//                     \->  custom-provider form
//

import SwiftUI

// MARK: - Resolved Provider Configuration

/// Concrete connection configuration derived from either a `ProviderPreset`
/// or the custom-provider form fields.
private struct ResolvedProviderConfig {
    let name: String
    let host: String
    let port: Int?
    let basePath: String
    let providerType: RemoteProviderType
    let providerProtocol: RemoteProviderProtocol
}

// MARK: - Connection Test Result

private enum APITestResult: Equatable {
    case success
    case failure(String)
}

// MARK: - Custom Provider Form State

/// Bundled custom-provider form fields. Owning them in one struct (instead of
/// six `@State` properties on the view) makes reset and validation trivial.
private struct CustomProviderForm {
    var name: String = ""
    var host: String = ""
    var protocolKind: RemoteProviderProtocol = .https
    var port: String = ""
    var basePath: String = "/v1"

    mutating func reset() { self = CustomProviderForm() }

    /// `https://host[:port]/basePath`, used for the live endpoint preview.
    var endpointPreview: String {
        var url = (protocolKind == .https ? "https://" : "http://") + host
        if !port.isEmpty { url += ":\(port)" }
        url += basePath.isEmpty ? "/v1" : basePath
        return url
    }

    func resolved(displayName: String) -> ResolvedProviderConfig {
        ResolvedProviderConfig(
            name: name.isEmpty ? displayName : name,
            host: host,
            port: port.isEmpty ? nil : Int(port),
            basePath: basePath.isEmpty ? "/v1" : basePath,
            providerType: .openaiLegacy,
            providerProtocol: protocolKind
        )
    }
}

// MARK: - API Setup View

struct OnboardingAPISetupView: View {
    let onComplete: () -> Void
    let onBack: () -> Void

    @Environment(\.theme) private var theme
    @State private var selectedProvider: ProviderPreset? = nil
    @State private var apiKey: String = ""
    @State private var openAIAuthMode: OpenAIProviderCredentialMode = .chatGPTSubscription
    @State private var oauthTokens: RemoteProviderOAuthTokens? = nil
    @State private var customForm = CustomProviderForm()
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var testResult: APITestResult? = nil
    @State private var hasAppeared = false

    /// Subset of presets shown in onboarding (excludes OpenRouter for simplicity),
    /// alphabetical with Custom last.
    private static let onboardingPresets: [ProviderPreset] = [
        .anthropic, .google, .openai, .venice, .xai, .custom,
    ]

    // MARK: Computed state

    private var canTest: Bool {
        guard let provider = selectedProvider else { return false }
        if provider == .custom {
            return !customForm.host.isEmpty && apiKey.count > 5
        }
        if provider == .openai && openAIAuthMode == .chatGPTSubscription {
            return true
        }
        return apiKey.count > 10
    }

    private var isSuccess: Bool {
        if case .success = testResult { return true }
        return false
    }

    private var buttonState: OnboardingButtonState {
        if isTesting || isSaving { return .loading }
        switch testResult {
        case .success: return .success
        case .failure(let message): return .error(message)
        case nil: return .idle
        }
    }

    private var loadingTitle: LocalizedStringKey {
        if isSaving { return "Connecting..." }
        return selectedProvider == .openai && openAIAuthMode == .chatGPTSubscription ? "Signing in..." : "Testing..."
    }

    // MARK: Body

    var body: some View {
        ZStack {
            switch selectedProvider {
            case nil:
                providerSelectionView.transition(nestedTransition)
            case .custom:
                customProviderEntryView.transition(nestedTransition)
            case .some:
                apiKeyEntryView.transition(nestedTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(theme.springAnimation(responseMultiplier: 0.8), value: selectedProvider)
        .onAppearAfter(OnboardingMetrics.appearDelay) {
            withAnimation { hasAppeared = true }
        }
    }

    /// Slide-and-fade transition between the three substates.
    private var nestedTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 30)).combined(with: .scale(scale: 0.98)),
            removal: .opacity.combined(with: .offset(x: -30)).combined(with: .scale(scale: 0.98))
        )
    }

    // MARK: - Substate: Provider Selection

    private var providerSelectionView: some View {
        OnboardingScaffold(
            title: "Connect a provider",
            footer: "Secrets are stored securely in Keychain.",
            onBack: onBack,
            content: {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: OnboardingMetrics.cardSpacing) {
                        ForEach(Array(Self.onboardingPresets.enumerated()), id: \.element.id) { index, provider in
                            providerCard(for: provider, index: index)
                        }
                    }
                }
            }
        )
    }

    private func providerCard(for preset: ProviderPreset, index: Int) -> some View {
        OnboardingRowCard(
            icon: .custom {
                ProviderIcon(preset: preset, size: 18, color: theme.secondaryText)
            },
            title: preset == .custom ? L("Any OpenAI-compatible API") : preset.name,
            subtitle: preset == .custom
                ? L("OpenRouter, MiniMax, etc.")
                : (preset == .openai ? L("ChatGPT/Codex or Platform API") : preset.description),
            badges: preset.badge.map { [OnboardingRowBadge($0)] } ?? [],
            accessory: .chevron
        ) {
            withAnimation(theme.springAnimation(responseMultiplier: 0.8)) {
                selectedProvider = preset
            }
        }
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 15)
        .animation(theme.springAnimation().delay(0.17 + Double(index) * 0.05), value: hasAppeared)
    }

    // MARK: - Substate: API Key Entry (known providers)

    private var apiKeyEntryView: some View {
        OnboardingScaffold(
            title: "Connect \(selectedProvider?.name ?? "Provider")",
            onBack: resetAndBack,
            content: {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 20) {
                        if selectedProvider == .openai {
                            openAIAuthChoiceSection
                        }

                        if selectedProvider != .openai || openAIAuthMode == .platformAPIKey {
                            apiKeyField
                        }

                        if let provider = selectedProvider, provider != .custom,
                            provider != .openai || openAIAuthMode == .platformAPIKey
                        {
                            helpSection(for: provider)
                        }
                    }
                    .padding(.bottom, 4)
                }
            },
            cta: { actionButton }
        )
    }

    // MARK: - Substate: Custom Provider Entry

    private var customProviderEntryView: some View {
        OnboardingScaffold(
            title: "Connect custom provider",
            onBack: resetAndBack,
            content: {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 14) {
                        OnboardingGlassCard {
                            customProviderForm.padding(16)
                        }
                        apiKeyField
                    }
                    .padding(.bottom, 4)
                }
            },
            cta: { actionButton }
        )
    }

    private var customProviderForm: some View {
        VStack(spacing: 14) {
            OnboardingTextField(
                label: "Name",
                placeholder: "e.g. My Provider",
                text: $customForm.name
            )

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PROTOCOL", bundle: .module)
                        .font(theme.font(size: 10, weight: .bold))
                        .foregroundColor(theme.tertiaryText)
                        .tracking(0.5)
                    OnboardingProtocolToggle(selection: $customForm.protocolKind)
                        .frame(height: 40)
                }
                .frame(width: 130)

                OnboardingTextField(
                    label: "Host",
                    placeholder: "api.example.com",
                    text: $customForm.host,
                    isMonospaced: true
                )
            }

            HStack(spacing: 12) {
                OnboardingTextField(
                    label: "Port",
                    placeholder: customForm.protocolKind == .https ? "443" : "80",
                    text: $customForm.port,
                    isMonospaced: true
                )
                .frame(width: 100)

                OnboardingTextField(
                    label: "Base Path",
                    placeholder: "/v1",
                    text: $customForm.basePath,
                    isMonospaced: true
                )
            }

            if !customForm.host.isEmpty {
                endpointPreview
            }
        }
    }

    // MARK: - Shared Subviews

    private var apiKeyField: some View {
        OnboardingSecureField(
            placeholder: "sk-...",
            text: $apiKey,
            label: selectedProvider == .openai ? "OpenAI Platform API Key" : "API Key"
        )
        .onChange(of: apiKey) { _, _ in testResult = nil }
    }

    private var openAIAuthChoiceSection: some View {
        OnboardingGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose your OpenAI access", bundle: .module)
                    .font(theme.font(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
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
            .padding(16)
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
            withAnimation(theme.springAnimation(responseMultiplier: 0.8)) {
                openAIAuthMode = mode
                oauthTokens = nil
                testResult = nil
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
                        .font(theme.font(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(subtitle)
                        .font(theme.font(size: 12))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(selected ? theme.accentColor : theme.tertiaryText)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? theme.accentColor.opacity(0.08) : theme.cardBackground.opacity(0.4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(selected ? theme.accentColor.opacity(0.55) : theme.cardBorder, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var actionButton: some View {
        OnboardingStatefulButton(
            state: buttonState,
            idleTitle: selectedProvider == .openai && openAIAuthMode == .chatGPTSubscription
                ? "Sign in with ChatGPT" : "Test Connection",
            loadingTitle: loadingTitle,
            successTitle: "Continue",
            errorTitle: "Try Again",
            action: { isSuccess ? saveProviderAndContinue() : testConnection() },
            isEnabled: canTest
        )
        .frame(width: OnboardingMetrics.ctaWidth)
    }

    private var endpointPreview: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 11))
                .foregroundColor(theme.accentColor)

            Text(customForm.endpointPreview)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.secondaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(theme.accentColor.opacity(0.1))
        )
    }

    private func helpSection(for preset: ProviderPreset) -> some View {
        OnboardingGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Don't have a key?", bundle: .module)
                    .font(theme.font(size: 14, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(preset.helpSteps.enumerated()), id: \.offset) { index, text in
                        HelpStep(number: index + 1, text: text)
                    }
                }

                ProviderHelpLinks(
                    preset: preset,
                    accentColor: theme.accentColor,
                    secondaryTextColor: theme.secondaryText
                )
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    // MARK: - Actions

    /// Returns to the provider list and clears any in-flight form / test state.
    private func resetAndBack() {
        withAnimation(theme.springAnimation(responseMultiplier: 0.8)) {
            selectedProvider = nil
            apiKey = ""
            openAIAuthMode = .chatGPTSubscription
            oauthTokens = nil
            testResult = nil
            customForm.reset()
        }
    }

    /// Resolves the active substate into a concrete `ResolvedProviderConfig`.
    private func resolvedConfig() -> ResolvedProviderConfig? {
        guard let provider = selectedProvider else { return nil }

        if provider == .custom {
            return customForm.resolved(displayName: L("Custom Provider"))
        }

        let config = provider.configuration
        return ResolvedProviderConfig(
            name: config.name,
            host: config.host,
            port: config.port,
            basePath: config.basePath,
            providerType: config.providerType,
            providerProtocol: config.providerProtocol
        )
    }

    private func testConnection() {
        guard let config = resolvedConfig() else { return }

        isTesting = true
        testResult = nil

        Task {
            let result: APITestResult
            do {
                if selectedProvider == .openai && openAIAuthMode == .chatGPTSubscription {
                    let tokens = try await OpenAICodexOAuthService.signIn()
                    await MainActor.run {
                        oauthTokens = tokens
                    }
                } else {
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
                }
                result = .success
            } catch {
                result = .failure(error.localizedDescription)
            }

            await MainActor.run {
                withAnimation(theme.springAnimation()) {
                    testResult = result
                    isTesting = false
                }
            }
        }
    }

    private func saveProviderAndContinue() {
        guard let config = resolvedConfig() else { return }

        isSaving = true

        if selectedProvider == .openai && openAIAuthMode == .chatGPTSubscription {
            let provider = OpenAICodexOAuthService.makeProvider()
            RemoteProviderManager.shared.addProvider(provider, apiKey: nil, oauthTokens: oauthTokens)
            isSaving = false
            onComplete()
            return
        }

        // `addProvider` already calls `connect()` internally for enabled providers,
        // and the app-level cache invalidation observer refreshes model options
        // when the connection completes — no follow-up call needed here.
        let provider = RemoteProvider(
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
        RemoteProviderManager.shared.addProvider(provider, apiKey: apiKey)

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
            withAnimation(theme.animationQuick()) { selection = proto }
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

// MARK: - Help Step

private struct HelpStep: View {
    let number: Int
    let text: String

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number).", bundle: .module)
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
            .frame(width: OnboardingMetrics.windowWidth, height: 680)
        }
    }
#endif
