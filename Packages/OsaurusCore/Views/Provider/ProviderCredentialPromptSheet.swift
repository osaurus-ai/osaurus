//
//  ProviderCredentialPromptSheet.swift
//  osaurus
//
//  SwiftUI sheet driven by `ProviderCredentialPromptService`. Renders
//  curated, provider-specific instructions, collects either an API key
//  (with optional extra fields like Azure endpoint/deployment) or
//  drives an OAuth sign-in, and surfaces an inline "Test connection"
//  button so the model can ask the user to verify credentials before
//  persisting. The secret is handed back through the `onComplete`
//  closure — it never leaves this view or enters LLM context.
//

import AppKit
import SwiftUI

struct ProviderCredentialPromptSheet: View {
    let request: ProviderCredentialRequest
    let onComplete: (ProviderCredentialResult) -> Void

    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var apiKey: String = ""
    @State private var extraFieldValues: [String: String] = [:]
    @State private var isTesting = false
    @State private var testError: String?
    @State private var testSucceededModelCount: Int?
    @State private var isSigningIn = false
    @State private var signInError: String?
    @State private var oauthTokens: RemoteProviderOAuthTokens?

    private var cardGradient: LinearGradient {
        LinearGradient(
            colors: [theme.cardBackground, theme.cardBackground.opacity(0.95)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var isOAuthFlow: Bool {
        request.instructions.authMethod == .oauth
    }

    private var saveDisabled: Bool {
        if isOAuthFlow {
            return oauthTokens == nil || isSigningIn
        }
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        for field in request.instructions.extraFields where field.isRequired {
            let value = extraFieldValues[field.key] ?? ""
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        }
        return false
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(cardGradient)

            VStack(alignment: .leading, spacing: 16) {
                header
                instructionsBlock
                Divider().background(theme.primaryBorder)
                if isOAuthFlow {
                    oauthBody
                } else {
                    apiKeyBody
                }
                Spacer(minLength: 0)
                actionButtons
            }
            .padding(20)
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 360)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.primaryBorder, lineWidth: 0.5)
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isOAuthFlow ? "person.badge.key.fill" : "key.fill")
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(theme.accentColor)
                .frame(width: 36, height: 36)
                .background(theme.accentColor.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(headerSubtitle)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            Button {
                onComplete(.cancelled)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 22, height: 22)
                    .background(theme.primaryBorder.opacity(0.4), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
    }

    private var headerTitle: String {
        switch request.mode {
        case .addNew:
            return String(format: L("Connect %@"), request.instructions.displayName)
        case .rotate:
            return String(format: L("Update %@ credentials"), request.instructions.displayName)
        }
    }

    private var headerSubtitle: String {
        switch request.mode {
        case .addNew:
            return L("Required by the chat assistant to add this provider.")
        case .rotate:
            return L("Rotate or replace the credentials stored in Keychain.")
        }
    }

    // MARK: - Instructions

    @ViewBuilder
    private var instructionsBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let hint = request.instructions.keyFormatHint {
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            }
            if let url = request.instructions.getKeyURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "safari")
                            .font(.system(size: 11, weight: .medium))
                        Text(L("Open provider page"))
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - API key body

    @ViewBuilder
    private var apiKeyBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(request.instructions.extraFields, id: \.key) { field in
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.label + (field.isRequired ? " *" : ""))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                    TextField(
                        field.placeholder,
                        text: Binding(
                            get: { extraFieldValues[field.key] ?? "" },
                            set: { extraFieldValues[field.key] = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L("API key *"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                SecureField(L("sk-…"), text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
            }

            if let error = testError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(theme.errorColor)
            } else if let count = testSucceededModelCount {
                Label(
                    String(format: L("Connected. Found %d model(s)."), count),
                    systemImage: "checkmark.seal.fill"
                )
                .font(.system(size: 12))
                .foregroundColor(theme.successColor)
            }
        }
    }

    // MARK: - OAuth body

    @ViewBuilder
    private var oauthBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if oauthTokens != nil {
                Label(L("Signed in. Ready to save."), systemImage: "checkmark.seal.fill")
                    .font(.system(size: 13))
                    .foregroundColor(theme.successColor)
            } else {
                Text(L("Click the button below to sign in. A browser window will open."))
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)

                Button {
                    startOAuthSignIn()
                } label: {
                    HStack(spacing: 8) {
                        if isSigningIn {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "person.badge.shield.checkmark.fill")
                                .font(.system(size: 12, weight: .medium))
                        }
                        Text(String(format: L("Sign in with %@"), request.instructions.displayName))
                            .font(.system(size: 13, weight: .medium))
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)
                    .background(theme.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .foregroundColor(theme.cardBackground)
                }
                .buttonStyle(.plain)
                .disabled(isSigningIn)
            }

            if let error = signInError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(theme.errorColor)
            }
        }
    }

    // MARK: - Action buttons

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 10) {
            if !isOAuthFlow {
                Button {
                    runTestConnection()
                } label: {
                    HStack(spacing: 6) {
                        if isTesting {
                            ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 11, weight: .medium))
                        }
                        Text(L("Test"))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.accentColor)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(theme.accentColor.opacity(0.4), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(saveDisabled || isTesting)
            }

            Spacer()

            Button(L("Cancel")) {
                onComplete(.cancelled)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .font(.system(size: 13))
            .foregroundColor(theme.secondaryText)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)

            Button {
                save()
            } label: {
                Text(L("Save"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.cardBackground)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 16)
                    .background(theme.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(saveDisabled)
        }
    }

    // MARK: - Actions

    private func save() {
        if isOAuthFlow, let tokens = oauthTokens {
            onComplete(.oauthTokens(tokens))
            return
        }
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var headers: [String: String]? = nil
        if !request.instructions.extraFields.isEmpty {
            var collected: [String: String] = [:]
            for field in request.instructions.extraFields {
                let value = (extraFieldValues[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    collected[field.key] = value
                }
            }
            headers = collected.isEmpty ? nil : collected
        }
        onComplete(.apiKey(key: trimmed, headers: headers))
    }

    private func startOAuthSignIn() {
        isSigningIn = true
        signInError = nil
        Task { @MainActor in
            do {
                let outcome = try await OAuthSignInCoordinator.signIn(
                    providerType: request.providerType
                )
                isSigningIn = false
                switch outcome {
                case .tokens(let tokens):
                    self.oauthTokens = tokens
                case .apiKey(let key):
                    onComplete(.apiKey(key: key))
                }
            } catch {
                isSigningIn = false
                signInError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func runTestConnection() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Build the same temp provider shape `RemoteProviderEditSheet` does
        // so the inline test result accurately reflects what we'll persist.
        let providerType = request.providerType
        let storageAuth = request.instructions.storageAuthType
        let host = (extraFieldValues["host"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let deployment = (extraFieldValues["deployment"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let (defaultHost, defaultProtocol, defaultPort, defaultBasePath) = providerTypeDefaults(providerType)
        let effectiveHost = host.isEmpty ? defaultHost : host
        let basePath: String
        switch providerType {
        case .azureOpenAI:
            basePath = deployment.isEmpty ? defaultBasePath : "/openai/deployments/\(deployment)/v1"
        default:
            basePath = defaultBasePath
        }

        isTesting = true
        testError = nil
        testSucceededModelCount = nil

        Task { @MainActor in
            do {
                let models = try await RemoteProviderManager.shared.testConnection(
                    host: effectiveHost,
                    providerProtocol: defaultProtocol,
                    port: defaultPort,
                    basePath: basePath,
                    authType: storageAuth,
                    providerType: providerType,
                    apiKey: trimmed,
                    headers: [:]
                )
                isTesting = false
                testSucceededModelCount = models.count
            } catch {
                isTesting = false
                testError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Minimal per-provider default endpoint config used solely by the
    /// inline test button. Full provider creation goes through
    /// `RemoteProviderManager.addProvider(...)` which has its own
    /// defaulting; this duplicates only what we need to ping `/models`.
    private func providerTypeDefaults(
        _ type: RemoteProviderType
    ) -> (host: String, providerProtocol: RemoteProviderProtocol, port: Int?, basePath: String) {
        switch type {
        case .anthropic:
            return ("api.anthropic.com", .https, nil, "/v1")
        case .openResponses:
            return ("api.openai.com", .https, nil, "/v1")
        case .openaiLegacy:
            return ("api.openai.com", .https, nil, "/v1")
        case .azureOpenAI:
            return ("example.openai.azure.com", .https, nil, "/openai/v1")
        case .gemini:
            return ("generativelanguage.googleapis.com", .https, nil, "/v1beta")
        case .openAICodex:
            return ("chatgpt.com", .https, nil, "/backend-api")
        case .osaurus:
            return ("localhost", .http, 8080, "/v1")
        }
    }
}
