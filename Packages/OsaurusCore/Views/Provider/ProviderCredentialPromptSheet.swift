//
//  ProviderCredentialPromptSheet.swift
//  osaurus
//
//  SwiftUI sheet driven by `ProviderCredentialPromptService`. Renders
//  curated, provider-branded instructions, collects either an API key
//  (with optional extra fields like Azure endpoint/deployment) or
//  drives an OAuth sign-in, and surfaces an inline "Test connection"
//  state on the primary CTA so the model can ask the user to verify
//  credentials before persisting. The secret is handed back through
//  the `onComplete` closure — it never leaves this view or enters
//  LLM context.
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
    /// User opted to paste an API key instead of running the OAuth flow.
    /// Only meaningful when `supportsApiKeyAlternative` (today: OpenRouter,
    /// whose OAuth merely mints a key we store as an API key).
    @State private var preferApiKeyEntry = false
    @FocusState private var apiKeyFieldFocused: Bool

    /// Stable preset for branding/help. Falls back to `.custom` when
    /// the request didn't carry a preset (Osaurus peer agent path) —
    /// `.custom` skips the gradient and the help-steps card.
    private var preset: ProviderPreset {
        request.preset ?? .custom
    }

    /// 95%-opacity diagonal gradient over `cardBackground`. Same shape
    /// `ToolPermissionView` uses so floating modal cards across the app
    /// share one visual identity (gradient base + glass edge + shadow).
    private var cardGradient: LinearGradient {
        LinearGradient(
            colors: [theme.surface.raised, theme.surface.raised],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var hasBrandedPreset: Bool {
        preset != .custom
    }

    private var isOAuthFlow: Bool {
        request.instructions.authMethod == .oauth && !(supportsApiKeyAlternative && preferApiKeyEntry)
    }

    /// True when the provider authenticates via OAuth but ultimately stores
    /// a plain API key (OpenRouter). For these, the user can skip the browser
    /// dance and paste a key directly — matching the dual mode Settings
    /// already offers. Codex (storageAuthType == .oauth) deliberately does
    /// not qualify and stays OAuth-only.
    private var supportsApiKeyAlternative: Bool {
        request.instructions.authMethod == .oauth
            && request.instructions.storageAuthType == .apiKey
    }

    private var isCodexOAuth: Bool {
        isOAuthFlow && request.providerType == .openAICodex
    }

    private var canSave: Bool {
        if isOAuthFlow { return oauthTokens != nil }
        if requiresApiKey, trimmed(apiKey).isEmpty { return false }
        return request.instructions.extraFields
            .filter { $0.isRequired }
            .allSatisfy { !trimmed(extraFieldValue(for: $0.key)).isEmpty }
    }

    /// True when the catalog requires a secret to authenticate. Ollama and
    /// other `.none` providers can be saved (and tested) without one — the
    /// sheet must let the user proceed with an empty `apiKey` field there,
    /// otherwise the catalog hint "Leave blank if your local Ollama
    /// doesn't require one" is unreachable.
    private var requiresApiKey: Bool {
        request.instructions.storageAuthType != .none
    }

    /// True once we've either tested successfully or completed OAuth —
    /// the primary CTA flips to "Save" in this state.
    private var hasVerified: Bool {
        if isOAuthFlow { return oauthTokens != nil }
        return testSucceededModelCount != nil
    }

    private func extraFieldValue(for key: String) -> String {
        extraFieldValues[key] ?? ""
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Seed `extraFieldValues` from a tool-supplied host override (or any
    /// other prefilled extra field) exactly once, when the sheet appears.
    /// This makes a tool-driven `host` visible and editable in the field —
    /// and, crucially, part of what the inline "Test Connection" hits — so
    /// the user approves the real endpoint their credentials will reach
    /// instead of a preset host that gets swapped out after the sheet
    /// closes.
    private func seedPrefilledExtraFieldsIfNeeded() {
        guard extraFieldValues.isEmpty, !request.prefilledExtraFields.isEmpty else { return }
        for field in request.instructions.extraFields {
            if let value = request.prefilledExtraFields[field.key],
                !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                extraFieldValues[field.key] = value
            }
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: theme.radius.xlarge, style: .continuous)
                .fill(cardGradient)

            VStack(spacing: theme.space.s0) {
                header
                bodyDivider
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: theme.space.s16) {
                        if hasBrandedPreset {
                            helpCard
                        } else if let hint = request.instructions.keyFormatHint {
                            unbrandedHint(hint)
                        }
                        if isOAuthFlow {
                            oauthBody
                        } else {
                            apiKeyBody
                        }
                        if case .rotate = request.mode {
                            rotateFooterNote
                        }
                    }
                    .padding(.horizontal, theme.space.s24)
                    .padding(.vertical, theme.space.s16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Propagate the natural content height up through the
                    // ScrollView so the outer panel hugs short forms (no
                    // dead space) while Azure's longer layout still gets
                    // to scroll inside `scrollMaxHeight`.
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: scrollMaxHeight)
                footer
            }
        }
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: theme.radius.xlarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.xlarge, style: .continuous)
                .strokeBorder(
                    theme.border.default,
                    lineWidth: theme.stroke.default
                )
        )
        // Subtle ambient shadow — just enough lift to separate the
        // card from the window behind without the bloomy halo
        // `ToolPermissionView` uses for its more dramatic floating
        // permission prompt.
        .themeElevation(theme.elevation.overlay)
        .onAppear {
            seedPrefilledExtraFieldsIfNeeded()
            autoFocusApiKeyField()
        }
        // OpenRouter's "Paste an API key instead" swaps the OAuth body for
        // the key form mid-flight — focus the field then too.
        .onChange(of: preferApiKeyEntry) { _, prefersKey in
            if prefersKey { autoFocusApiKeyField() }
        }
    }

    /// Focus the API key field once the hosting panel has had a beat to
    /// become key (the service makes the panel key ~50ms after ordering
    /// it front; focusing before that is dropped by AppKit).
    private func autoFocusApiKeyField() {
        guard !isOAuthFlow else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            apiKeyFieldFocused = true
        }
    }

    /// Hairline divider under the header. Matches the rule
    /// `ToolPermissionView` draws above its action band so every modal
    /// card uses the same separator weight.
    private var bodyDivider: some View {
        ThemeHairlineDivider()
    }

    /// Ceiling for the scroll area. Picked so the tallest realistic
    /// form (Azure: endpoint + deployment + API key + test pill) fits
    /// without scrolling, and anything longer scrolls cleanly without
    /// pushing the footer off-screen.
    private var scrollMaxHeight: CGFloat { 460 }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: theme.space.s14) {
            brandedIcon

            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(headerTitle)
                    .font(SettingsFont.detailTitle)
                    .foregroundColor(theme.text.primary)
                Text(headerSubtitle)
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, theme.space.s24)
        .padding(.vertical, theme.space.s16)
    }

    @ViewBuilder
    private var brandedIcon: some View {
        ZStack {
            if hasBrandedPreset {
                LinearGradient(
                    colors: preset.gradient,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .clipShape(RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous))
                ProviderIcon(preset: preset, size: 20, color: FixedPalette.onMedia)
            } else {
                SettingsIconTile(icon: isOAuthFlow ? "person.badge.key.fill" : "key.fill", size: 44)
            }
        }
        .frame(width: 44, height: 44)
    }

    private var isRotateMode: Bool {
        if case .rotate = request.mode { return true }
        return false
    }

    private var headerTitle: String {
        let format = isRotateMode ? L("Update %@ credentials") : L("Connect %@")
        return String(format: format, request.instructions.displayName)
    }

    private var headerSubtitle: String {
        isRotateMode
            ? L("Rotate or replace the credentials stored in Keychain.")
            : L("Required by the chat assistant to add this provider.")
    }

    // MARK: - Help card

    private var helpCard: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            Text(L("Don't have a key?"))
                .font(SettingsFont.sectionTitle)
                .foregroundColor(theme.text.secondary)

            if let hint = request.instructions.keyFormatHint {
                helpStep(number: 1, text: hint)
            }

            ProviderHelpLinks(
                preset: preset,
                accentColor: theme.status.info.foreground,
                secondaryTextColor: theme.text.secondary
            )
            .padding(.top, theme.space.s2)
        }
        .padding(theme.space.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.card)
    }

    private func helpStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: theme.space.s10) {
            Text("\(number).")
                .font(SettingsFont.monoSmall)
                .foregroundColor(theme.text.tertiary)
                .frame(width: 16, alignment: .trailing)
            Text(text)
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Plain info-icon label. No card background — the inputs below already
    /// use `inputBackground`, and wrapping this in another rounded rect made
    /// the hint read like an empty input field.
    private func unbrandedHint(_ hint: String) -> some View {
        HStack(alignment: .top, spacing: theme.space.s6) {
            Image(systemName: "info.circle")
                .glyphSize(.footnote)
                .foregroundColor(theme.text.tertiary)
                .padding(.top, theme.space.s2)
            Text(hint)
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - API key body

    private var apiKeyBody: some View {
        VStack(alignment: .leading, spacing: theme.space.s14) {
            if supportsApiKeyAlternative && preferApiKeyEntry {
                Button {
                    preferApiKeyEntry = false
                    testError = nil
                    testSucceededModelCount = nil
                } label: {
                    Text(String(format: L("Sign in with %@ instead"), request.instructions.displayName))
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.text.link)
                }
                .buttonStyle(.plain)
            }
            ForEach(request.instructions.extraFields, id: \.key) { field in
                SettingsFieldRow(
                    label: field.label + (field.isRequired ? " *" : ""),
                    hint: field.helpText,
                    verbatimHint: true,
                    verbatimLabel: true
                ) {
                    SettingsTextField(
                        placeholder: LCached(field.placeholder),
                        text: Binding(
                            get: { extraFieldValue(for: field.key) },
                            set: { extraFieldValues[field.key] = $0 }
                        )
                    )
                }
            }

            SettingsFieldRow(label: requiresApiKey ? "API key *" : "API key (optional)") {
                SettingsTextField(
                    placeholder: "sk-…",
                    text: $apiKey,
                    monospaced: true,
                    isSecure: true,
                    focus: $apiKeyFieldFocused
                )
            }
        }
    }

    // MARK: - OAuth body

    @ViewBuilder
    private var oauthBody: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            if oauthTokens != nil {
                signedInPill
            } else {
                Text(L("Click the button below to sign in. A browser window will open."))
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.secondary)

                oauthSignInButton

                if supportsApiKeyAlternative {
                    Button {
                        preferApiKeyEntry = true
                        signInError = nil
                    } label: {
                        Text(L("Paste an API key instead"))
                            .font(SettingsFont.compactLabel)
                            .foregroundColor(theme.text.link)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let error = signInError {
                inlineError(error)
            }
        }
    }

    private var oauthSignInButton: some View {
        Button(action: startOAuthSignIn) {
            HStack(spacing: theme.space.s8) {
                if isSigningIn {
                    SettingsSpinner()
                } else {
                    Image(systemName: "person.badge.shield.checkmark.fill")
                        .glyphSize(.caption, weight: .medium)
                }
                Text(String(format: L("Sign in with %@"), request.instructions.displayName))
                    .font(SettingsFont.sectionTitle)
            }
        }
        .assignedSettingsButtonStyle(.primary)
        .disabled(isSigningIn)
    }

    /// OAuth button background: use the ChatGPT/OpenAI brand gradient
    /// for the Codex path so the sign-in card visually matches what
    /// the user will see in the browser. Other OAuth providers fall
    /// back to the active accent.
    private var oauthButtonBackground: AnyShapeStyle {
        if isCodexOAuth {
            return AnyShapeStyle(
                LinearGradient(
                    colors: ProviderPreset.openai.gradient,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        return AnyShapeStyle(theme.action.primary.default.background)
    }

    private var signedInPill: some View {
        HStack(spacing: theme.space.s8) {
            Image(systemName: "checkmark.circle.fill")
                .glyphSize(.label)
                .foregroundColor(theme.status.success.foreground)
            Text(L("Signed in. Ready to save."))
                .font(SettingsFont.rowTitle)
                .foregroundColor(theme.status.success.foreground)
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s8)
        .settingsChrome(.status(.success))
    }

    private func inlineError(_ text: String) -> some View {
        HStack(alignment: .top, spacing: theme.space.s6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .glyphSize(.footnote)
                .foregroundColor(theme.status.error.foreground)
            Text(text)
                .font(SettingsFont.caption)
                .foregroundColor(theme.status.error.foreground)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var rotateFooterNote: some View {
        HStack(spacing: theme.space.s6) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .glyphSize(.footnote)
                .foregroundColor(theme.text.tertiary)
            Text(String(format: L("Replacing key for %@. Cancel keeps the existing key."), request.providerName))
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .lineLimit(2)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: theme.space.s0) {
            // Single hairline rule above the action band — same weight
            // as `bodyDivider` so the modal card reads as one surface
            // with section dividers rather than stacked panels.
            ThemeHairlineDivider()

            HStack(spacing: theme.space.s8) {
                testResultBadge

                Spacer(minLength: 0)

                Button {
                    onComplete(.cancelled)
                } label: {
                    Text(L("Cancel"))
                }
                .assignedSettingsButtonStyle(.secondary)
                .keyboardShortcut(.cancelAction)

                primaryButton
            }
            .padding(.horizontal, theme.settingsSheetInset)
            .padding(.vertical, theme.space.s16)
        }
    }

    private var primaryButton: some View {
        Button(action: primaryAction) {
            Text(primaryButtonTitle)
        }
        .assignedSettingsButtonStyle(.primary, isLoading: isTesting || isSigningIn)
        .disabled(!primaryButtonEnabled)
        .keyboardShortcut(.return, modifiers: .command)
    }

    @ViewBuilder
    private var testResultBadge: some View {
        if let count = testSucceededModelCount {
            badgePill(
                icon: "checkmark.circle.fill",
                text: count == 1 ? L("1 model found") : L("\(count) models found"),
                tint: theme.status.success.foreground
            )
        } else if let error = testError {
            badgePill(
                icon: "xmark.circle.fill",
                text: error,
                tint: theme.status.error.foreground
            )
        }
    }

    private func badgePill(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: theme.space.s6) {
            Image(systemName: icon)
                .glyphSize(.caption)
                .foregroundColor(tint)
            Text(text)
                .font(SettingsFont.smallLabel)
                .foregroundColor(tint)
                .lineLimit(2)
        }
        .padding(.horizontal, theme.space.s8)
        .padding(.vertical, theme.space.s6)
        .settingsChrome(.tinted(tint))
    }

    private var primaryButtonTitle: String {
        if isOAuthFlow {
            if isSigningIn { return L("Signing in…") }
            if oauthTokens != nil { return L("Save") }
            return String(format: L("Sign in with %@"), request.instructions.displayName)
        }
        if isTesting { return L("Testing…") }
        if hasVerified { return L("Save") }
        if testError != nil { return L("Retry") }
        return L("Test Connection")
    }

    /// Mirror the edit sheet's color story: green when verified,
    /// red after a failure to draw attention to the retry, accent
    /// while neutral.
    private var primaryButtonColor: Color {
        if hasVerified { return theme.status.success.foreground }
        if testError != nil { return theme.status.error.foreground }
        return theme.action.primary.default.background
    }

    private var primaryButtonEnabled: Bool {
        guard !isTesting, !isSigningIn else { return false }
        // OAuth flow always exposes a click target (sign in or save);
        // API-key flow needs the required fields filled.
        return isOAuthFlow || canSave
    }

    private func primaryAction() {
        if isOAuthFlow {
            if oauthTokens != nil { save() } else { startOAuthSignIn() }
        } else if hasVerified {
            save()
        } else {
            runTestConnection()
        }
    }

    // MARK: - Actions

    private func save() {
        if isOAuthFlow, let tokens = oauthTokens {
            onComplete(.oauthTokens(tokens))
            return
        }
        let key = trimmed(apiKey)
        if requiresApiKey, key.isEmpty { return }
        onComplete(.apiKey(key: key, headers: collectedExtraHeaders()))
    }

    /// Snapshot of the non-secret extra fields (Azure endpoint, host, etc.)
    /// keyed by their catalog id. Returns nil when nothing was filled in so
    /// callers can persist a "no extra headers" record cleanly.
    private func collectedExtraHeaders() -> [String: String]? {
        let pairs = request.instructions.extraFields.compactMap { field -> (String, String)? in
            let value = trimmed(extraFieldValue(for: field.key))
            return value.isEmpty ? nil : (field.key, value)
        }
        return pairs.isEmpty ? nil : Dictionary(uniqueKeysWithValues: pairs)
    }

    private func startOAuthSignIn() {
        isSigningIn = true
        signInError = nil
        Task { @MainActor in
            defer { isSigningIn = false }
            do {
                let outcome = try await runOAuthFlow()
                switch outcome {
                case .tokens(let tokens): oauthTokens = tokens
                case .apiKey(let key): onComplete(.apiKey(key: key))
                }
            } catch {
                signInError = readableMessage(for: error)
            }
        }
    }

    /// Dispatch the OAuth flow on the right axis. Codex uses the legacy
    /// provider-type entry (the `.openai` preset is API-key only), while
    /// OpenRouter (and any future preset-keyed OAuth provider) goes
    /// through the preset coordinator.
    @MainActor
    private func runOAuthFlow() async throws -> OAuthSignInOutcome {
        if request.providerType == .openAICodex {
            return try await OAuthSignInCoordinator.signIn(
                providerType: .openAICodex
            )
        }
        if let preset = request.preset {
            return try await OAuthSignInCoordinator.signIn(preset: preset)
        }
        throw OAuthSignInCoordinatorError.unsupportedProvider(
            providerType: request.providerType
        )
    }

    private func readableMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func runTestConnection() {
        let key = trimmed(apiKey)
        if requiresApiKey, key.isEmpty { return }

        // Build the same temp provider shape `RemoteProviderEditSheet` does
        // so the inline test result accurately reflects what we'll persist.
        let providerType = request.providerType
        let defaults = testConnectionDefaults()
        let host = trimmed(extraFieldValue(for: "host"))
        let deployment = trimmed(extraFieldValue(for: "deployment"))
        let effectiveHost = host.isEmpty ? defaults.host : host
        let deploymentModelIds =
            deployment
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let basePath: String = {
            guard providerType == .azureOpenAI, !deployment.isEmpty else { return defaults.basePath }
            // The deployment field accepts a comma/newline-separated list
            // (persisted to `manualModelIds` on save). The inline connection
            // test only needs one valid deployment in the path — embedding the
            // whole raw string would corrupt it.
            let first = deploymentModelIds.first ?? ""
            return first.isEmpty ? defaults.basePath : "/openai/deployments/\(first)/v1"
        }()

        isTesting = true
        testError = nil
        testSucceededModelCount = nil

        Task { @MainActor in
            defer { isTesting = false }
            do {
                // Custom secret headers (legacy OpenAI-compatible servers) are
                // collected as extra fields. `host` / `deployment` are reserved
                // endpoint keys, not headers, so exclude them — mirrors
                // `ProviderConfigurationDomain.reservedExtraKeys`.
                let testHeaders =
                    collectedExtraHeaders()?
                    .filter { !["host", "deployment"].contains($0.key) } ?? [:]
                let models = try await RemoteProviderManager.shared.testConnection(
                    host: effectiveHost,
                    providerProtocol: defaults.providerProtocol,
                    port: defaults.port,
                    basePath: basePath,
                    authType: request.instructions.storageAuthType,
                    providerType: providerType,
                    apiKey: key,
                    headers: testHeaders,
                    manualModelIds: providerType == .azureOpenAI ? deploymentModelIds : []
                )
                testSucceededModelCount = models.count
            } catch {
                testError = readableMessage(for: error)
            }
        }
    }

    /// Minimal per-provider default endpoint config used solely by the
    /// inline test button. Sources from `preset.configuration` so the
    /// five legacy-shaped vendors (OpenRouter, DeepSeek, xAI, Venice,
    /// Ollama) each ping their own host. Falls back to the legacy
    /// provider-type defaults when no preset is attached (Osaurus peer
    /// agent) or when Codex bypasses the preset path.
    private func testConnectionDefaults() -> (
        host: String, providerProtocol: RemoteProviderProtocol, port: Int?, basePath: String
    ) {
        if let preset = request.preset, preset != .custom {
            let cfg = preset.configuration
            return (cfg.host, cfg.providerProtocol, cfg.port, cfg.basePath)
        }
        switch request.providerType {
        case .openAICodex:
            return ("chatgpt.com", .https, nil, "/backend-api")
        case .osaurus:
            return ("localhost", .http, 8080, "/v1")
        default:
            return ("api.openai.com", .https, nil, "/v1")
        }
    }
}
