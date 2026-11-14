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

// MARK: - Pasted URL Detection

/// Endpoint components recovered from a full URL pasted into a host field,
/// so users can paste e.g. "https://api.example.com:8443/v1" and have the
/// protocol, host, port, and base path fields filled in automatically.
struct PastedEndpointComponents {
    var providerProtocol: RemoteProviderProtocol?
    var host: String
    var port: Int?
    var basePath: String?
}

/// Only restructure input that was pasted (multi-character change) or that
/// carries an explicit scheme; never mangle text the user is typing out
/// character by character.
func shouldSplitHostInput(previous: String, value: String) -> Bool {
    value.contains("://") || (value.count - previous.count > 1 && (value.contains("/") || value.contains(":")))
}

/// Parses host-field input that looks like a full URL. Returns nil when the
/// text is already a bare host so callers leave their state untouched.
func parsePastedEndpoint(_ text: String) -> PastedEndpointComponents? {
    var remainder = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !remainder.isEmpty else { return nil }

    var providerProtocol: RemoteProviderProtocol?
    if let schemeRange = remainder.range(of: "://") {
        switch remainder[..<schemeRange.lowerBound].lowercased() {
        case "https": providerProtocol = .https
        case "http": providerProtocol = .http
        default: break  // Unknown scheme: still salvage host/port/path below.
        }
        remainder = String(remainder[schemeRange.upperBound...])
    }

    // Plain host input has nothing to split apart.
    guard providerProtocol != nil || remainder.contains("/") || remainder.contains(":") else { return nil }

    // Drop query string and fragment.
    if let cutoff = remainder.firstIndex(where: { $0 == "?" || $0 == "#" }) {
        remainder = String(remainder[..<cutoff])
    }

    var basePath: String?
    if let slash = remainder.firstIndex(of: "/") {
        var path = String(remainder[slash...])
        remainder = String(remainder[..<slash])
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        basePath = normalizedPastedProviderBasePath(from: path)
    }

    var port: Int?
    if let colon = remainder.lastIndex(of: ":"),
        // Don't treat colons inside an IPv6 literal ("[::1]") as a port separator.
        remainder.lastIndex(of: "]").map({ colon > $0 }) ?? true
    {
        port = Int(remainder[remainder.index(after: colon)...])
        remainder = String(remainder[..<colon])
    }

    let host = remainder.trimmingCharacters(in: .whitespaces)
    guard !host.isEmpty else { return nil }
    return PastedEndpointComponents(providerProtocol: providerProtocol, host: host, port: port, basePath: basePath)
}

private func normalizedPastedProviderBasePath(from path: String) -> String? {
    guard path != "/" else { return nil }

    let operationSuffixes = [
        "/chat/completions",
        "/responses",
        "/messages",
        "/models",
    ]
    for suffix in operationSuffixes where path == suffix || path.hasSuffix(suffix) {
        let base = String(path.dropLast(suffix.count))
        return base.isEmpty ? "" : base
    }

    return path
}

// MARK: - Main View

struct RemoteProviderEditSheet: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let provider: RemoteProvider?
    var initialPreset: ProviderPreset?
    /// When `true` and no `initialPreset` is given, the add flow opens directly
    /// on the grouped "Use an API key" sub-list instead of the OAuth-first top
    /// level. Used by the empty-state "Use an API key" shortcut.
    var startAtAPIKeyPicker: Bool = false
    let onSave: (RemoteProvider, String?, RemoteProviderOAuthTokens?) -> Void

    var body: some View {
        Group {
            if let provider {
                EditProviderFlow(provider: provider, onSave: onSave)
            } else {
                AddProviderFlow(
                    initialPreset: initialPreset,
                    startAtAPIKeyPicker: startAtAPIKeyPicker,
                    onSave: onSave
                )
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
    var startAtAPIKeyPicker: Bool = false
    let onSave: (RemoteProvider, String?, RemoteProviderOAuthTokens?) -> Void

    @State private var selectedPreset: ProviderPreset?
    /// When `selectedPreset == nil`, controls whether the OAuth-first top level
    /// (`false`) or the grouped "Use an API key" sub-list (`true`) is shown.
    @State private var showingAPIKeyPicker = false
    /// Which picker level the configuration form was entered from, so Back
    /// returns there. The custom endpoint now lives on the top level but still
    /// pins `.apiKey`, so the auth method alone can no longer tell the levels
    /// apart.
    @State private var enteredFromAPIKeyPicker = false
    @State private var apiKey: String = ""
    /// The connection method pinned for the selected provider. Set at selection
    /// time from the catalog (OAuth for top-level rows, `.apiKey` for the "Use
    /// an API key" sub-list) so there's no in-form fork. Drives the CTA, the key
    /// field, save/test branches, and back-routing.
    @State private var selectedAuthMethod: ProviderPickerAuthMethod = .apiKey
    @State private var oauthTokens: RemoteProviderOAuthTokens?
    @State private var isTesting = false
    @State private var testResult: ProviderTestResult?
    /// The connect test found an MCP server at the entered URL; offer to move
    /// the setup to Tools & MCP > Services instead of leaving a dead-end error.
    @State private var showMCPRedirectPrompt = false
    @State private var hasAppeared = false
    /// Guards against saving twice: a successful test auto-finalizes the add,
    /// but the footer button is also still tappable during the brief green
    /// confirmation window, so both routes funnel through this one-shot latch.
    @State private var hasFinalized = false

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
    @State private var disableTimeout: Bool = false
    @State private var showNoTimeoutWarning = false
    @State private var customHeaders: [HeaderEntry] = []

    private var canTest: Bool {
        guard let preset = selectedPreset else { return false }
        if preset == .custom {
            return !customHost.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if preset == .azureOpenAI {
            return !knownHost.trimmingCharacters(in: .whitespaces).isEmpty && !apiKey.isEmpty && apiKey.count > 5
        }
        // A browser sign-in is connectable as soon as the provider is picked —
        // the OAuth flow itself collects the credential.
        if selectedAuthMethod.isOAuth {
            return true
        }
        return !apiKey.isEmpty && apiKey.count > 5
    }

    private var canSaveKnownProviderWithoutSuccessfulTest: Bool {
        guard selectedPreset == .azureOpenAI else { return false }
        return canTest && !parseManualModelIds(manualModelIdsText).isEmpty
    }

    var body: some View {
        VStack(spacing: theme.space.s0) {
            // Header bar
            sheetHeader

            // Content - stepped flow
            ZStack {
                if selectedPreset == nil {
                    if showingAPIKeyPicker {
                        apiKeyProviderSelectionStep
                            .transition(stepTransition)
                    } else {
                        providerSelectionStep
                            .transition(stepTransition)
                    }
                } else if selectedPreset == .custom {
                    customProviderStep
                        .transition(stepTransition)
                } else {
                    knownProviderStep
                        .transition(stepTransition)
                }
            }
            .animation(theme.motion.springAnimation, value: selectedPreset)
            .animation(theme.motion.springAnimation, value: showingAPIKeyPicker)
        }
        .fittedSheetFrame(width: 540, height: 620)
        .background(theme.surface.canvas)
        .clipShape(RoundedRectangle(cornerRadius: theme.radius.xlarge))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.xlarge)
                .stroke(theme.border.subtle, lineWidth: theme.stroke.default)
        )
        .opacity(hasAppeared ? 1 : 0)
        .scaleEffect(hasAppeared ? 1 : 0.95)
        .animation(theme.motion.springAnimation, value: hasAppeared)
        .onAppear {
            if let initialPreset {
                initializeKnownConnection(for: initialPreset)
                // Pin the entry's primary method (OAuth for the top-level rows
                // that open the sheet pre-selected) so dual-mode providers open
                // their sign-in flow, not the API-key form.
                selectedAuthMethod =
                    ProviderCatalog.entry(for: initialPreset)?.authMethods.first ?? .apiKey
                // A pre-selected key-only preset has no picker origin; Back
                // lands on the sub-list where that preset lives, as before.
                enteredFromAPIKeyPicker = !selectedAuthMethod.isOAuth && initialPreset != .custom
                selectedPreset = initialPreset
            } else if startAtAPIKeyPicker {
                showingAPIKeyPicker = true
            }
            withAnimation { hasAppeared = true }
        }
        .themedAlert(
            "Disable request timeout?",
            isPresented: $showNoTimeoutWarning,
            accessory: AnyView(NoTimeoutWarningContent()),
            buttons: [
                .cancel("Cancel"),
                .destructive("Disable Timeout") { disableTimeout = true },
            ],
            presentationStyle: .contained
        )
        .themedAlert(
            L("This looks like an MCP server"),
            isPresented: $showMCPRedirectPrompt,
            message: L(
                "This URL answers like an MCP server, not a chat completions API. Osaurus can add it as an MCP service instead — the URL and token you entered will be carried over."
            ),
            buttons: [
                .cancel(L("Cancel")),
                .primary(L("Add as MCP Service")) { redirectToMCPConnections() },
            ],
            // Wide enough that the CTA label stays on one line and both
            // buttons keep the same height.
            width: 420,
            presentationStyle: .contained
        )
    }

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 30)).combined(with: .scale(scale: 0.98)),
            removal: .opacity.combined(with: .offset(x: -30)).combined(with: .scale(scale: 0.98))
        )
    }

    // MARK: - Header

    private var sheetHeader: some View {
        let title: LocalizedStringKey =
            switch selectedPreset {
            case nil: "Add Provider"
            case .custom: "Connect Custom Provider"
            case let preset?: "Connect \(preset.name)"
            }
        var header = SettingsSheetHeader(
            icon: selectedPreset == .custom ? "server.rack" : "cloud.fill",
            title: title,
            subtitle: "Connect to a remote API provider"
        ) { dismiss() }
        if let preset = selectedPreset, preset != .custom {
            header.leading = AnyView(
                Circle()
                    .fill(LinearGradient(colors: preset.gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(ProviderIcon(preset: preset, size: 13, color: FixedPalette.onMedia))
            )
        }
        return header
    }

    // MARK: - Step 1: Provider Selection

    private var providerSelectionStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space.s16) {
                // Subscription-backed sign-ins first, then
                // a single "Use an API key" drill-in that holds every
                // paste-a-key vendor and Ollama (local), and a direct row for
                // the custom endpoint.
                SettingsGroup {
                    ForEach(ProviderCatalog.topLevel) { entry in
                        ProviderRowCard(entry: entry) {
                            selectCatalogEntry(entry)
                        }
                    }

                    ProviderRowCard(
                        icon: "key.fill",
                        title: "Use an API Key",
                        subtitle: "Anthropic, Google, Ollama, and more"
                    ) {
                        withAnimation(theme.motion.springAnimation) {
                            showingAPIKeyPicker = true
                        }
                    }

                    // The custom endpoint used to sit three clicks deep at the
                    // bottom of the API-key sub-list. Surface it here so an
                    // OpenAI-compatible server is one click from the chooser.
                    if let custom = ProviderCatalog.entry(for: .custom) {
                        ProviderRowCard(
                            icon: custom.preset.icon,
                            title: "Add Custom Endpoint",
                            subtitle: custom.pickerSubtitle(preferAPIKey: false)
                        ) {
                            selectCatalogEntry(custom)
                        }
                    }
                }

                HStack(spacing: theme.space.s4) {
                    Image(systemName: "lock.fill")
                        .glyphSize(.micro)
                    Text("Your API key never leaves your device.", bundle: .module)
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                }
                .foregroundColor(theme.text.tertiary)
                .padding(.top, theme.space.s4)
            }
            .padding(theme.space.s24)
        }
    }

    // MARK: - Step 1b: "Use an API key" sub-list (grouped)

    private var apiKeyProviderSelectionStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space.s16) {
                SettingsBackButton(title: "Providers") {
                    withAnimation(theme.motion.springAnimation) {
                        showingAPIKeyPicker = false
                    }
                }

                // The custom endpoint has its own row on the top level, so
                // the sub-list only carries the key vendors and Ollama.
                ForEach(ProviderCatalog.apiKeyGroups(includeAzure: true).filter { $0.id != "custom" }) {
                    section in
                    SettingsSection(title: section.title) {
                        ForEach(section.entries) { entry in
                            ProviderRowCard(entry: entry, preferAPIKey: true) {
                                selectCatalogEntry(entry, preferAPIKey: true)
                            }
                        }
                    }
                }
            }
            .padding(theme.space.s24)
        }
    }

    /// Small uppercase label above a group of picker rows. `title` is a
    /// localization key.
    /// Commit a catalog selection from either picker level and drill into its
    /// configuration step.
    ///
    /// The connection method is decided by where the card lives: the OAuth-first
    /// top level uses the entry's primary (OAuth) method, the "Use an API key"
    /// sub-list (`preferAPIKey`) uses `.apiKey`. There is no in-form fork, so we
    /// pin `selectedAuthMethod` here at selection time.
    private func selectCatalogEntry(_ entry: ProviderCatalogEntry, preferAPIKey: Bool = false) {
        withAnimation(theme.motion.springAnimation) {
            initializeKnownConnection(for: entry.preset)
            selectedAuthMethod = preferAPIKey ? .apiKey : (entry.authMethods.first ?? .apiKey)
            enteredFromAPIKeyPicker = preferAPIKey
            selectedPreset = entry.preset
        }
    }

    /// The OAuth flavor of the current selection, if any.
    private var selectedOAuthKind: ProviderOAuthKind? {
        if case .oauth(let kind) = selectedAuthMethod { return kind }
        return nil
    }

    // MARK: - Step 2a: Known Provider (API key only)

    private var knownProviderStep: some View {
        VStack(spacing: theme.space.s0) {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.space.s20) {
                    // Back button
                    backToSelectionButton

                    if selectedPreset == .azureOpenAI {
                        azureConnectionSection
                        azureDeploymentsSection
                    }

                    if let kind = selectedOAuthKind {
                        oauthInfoSection(for: kind)
                    }

                    if shouldShowKnownAPIKeyField {
                        apiKeySection
                    }

                    // Help section
                    if let preset = selectedPreset, preset.isKnown, !preset.consoleURL.isEmpty,
                        shouldShowKnownAPIKeyField
                    {
                        helpSection(for: preset)
                    }

                    // Advanced settings toggle
                    advancedSettingsSection
                }
                .padding(theme.space.s24)
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
        VStack(spacing: theme.space.s0) {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.space.s20) {
                    // Back button
                    backToSelectionButton

                    // Connection form card
                    VStack(alignment: .leading, spacing: theme.space.s0) {
                        connectionFormSection

                        sectionDivider

                        // Authentication section inside card
                        VStack(alignment: .leading, spacing: theme.space.s12) {
                            HStack(spacing: theme.space.s8) {
                                Image(systemName: "key.fill")
                                    .glyphSize(.caption, weight: .semibold)
                                    .foregroundColor(theme.text.link)
                                Text("Authentication", bundle: .module)
                                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                                    .foregroundColor(theme.text.secondary)
                            }

                            AssignedBaseSegmentedPicker(selection: $customAuthType, options: RemoteProviderAuthType.segmentedOptions)

                            if customAuthType == .apiKey {
                                SettingsTextField(
                                    placeholder: "sk-...",
                                    text: $apiKey,
                                    monospaced: true,
                                    isSecure: true
                                )
                                    .onChange(of: apiKey) { _, _ in testResult = nil }
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .padding(theme.space.s16)
                        .animation(theme.motion.springAnimation, value: customAuthType)
                    }
                    .settingsChrome(.card)

                    // Advanced settings toggle
                    advancedSettingsSection
                }
                .padding(theme.space.s24)
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
            withAnimation(theme.motion.springAnimation) {
                // Return to the level the form was reached from. Dual-mode
                // presets appear at both levels and the custom endpoint sits on
                // the top level despite pinning `.apiKey`, so use the origin
                // recorded at selection time.
                showingAPIKeyPicker = enteredFromAPIKeyPicker && selectedPreset != nil
                enteredFromAPIKeyPicker = false
                selectedPreset = nil
                apiKey = ""
                oauthTokens = nil
                selectedAuthMethod = .apiKey
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
                disableTimeout = false
                customHeaders = []
            }
        } label: {
            HStack(spacing: theme.space.s6) {
                Image(systemName: "chevron.left")
                    .glyphSize(.footnote, weight: .semibold)
                Text("Back", bundle: .module)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.rowTitle)
            }
            .foregroundColor(theme.text.secondary)
        }
        .buttonStyle(PlainButtonStyle())
    }

    /// When a full URL lands in the known-provider host field, distribute its
    /// pieces across the protocol/port/base path fields so users can paste
    /// the whole endpoint instead of hand-splitting it.
    private func handleKnownHostChange(previous: String, value: String) {
        testResult = nil
        guard shouldSplitHostInput(previous: previous, value: value),
            let components = parsePastedEndpoint(value)
        else { return }
        knownHost = components.host
        if let providerProtocol = components.providerProtocol { knownProtocol = providerProtocol }
        if let port = components.port { knownPort = String(port) }
        if let basePath = components.basePath { knownBasePath = basePath }
    }

    /// Same full-URL paste handling for the custom provider host field.
    private func handleCustomHostChange(previous: String, value: String) {
        guard shouldSplitHostInput(previous: previous, value: value),
            let components = parsePastedEndpoint(value)
        else { return }
        testResult = nil
        customHost = components.host
        if let providerProtocol = components.providerProtocol { customProtocol = providerProtocol }
        if let port = components.port { customPort = String(port) }
        if let basePath = components.basePath { customBasePath = basePath }
    }

    private func initializeKnownConnection(for preset: ProviderPreset) {
        let config = preset.configuration
        knownHost = config.host
        knownProtocol = config.providerProtocol
        knownPort = config.port.map(String.init) ?? ""
        knownBasePath = config.basePath
        manualModelIdsText = config.defaultManualModelIds.joined(separator: "\n")
        testResult = nil
    }

    private var azureConnectionSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s16) {
            HStack(spacing: theme.space.s8) {
                Image(systemName: "network")
                    .glyphSize(.caption, weight: .semibold)
                    .foregroundColor(theme.text.link)
                Text("Azure endpoint", bundle: .module)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                    .foregroundColor(theme.text.secondary)
            }

            HStack(spacing: theme.space.s12) {
                SettingsFieldRow(label: "Protocol") {
                    AssignedBaseSegmentedPicker(selection: $knownProtocol, options: RemoteProviderProtocol.segmentedOptions)
                }
                .fixedSize(horizontal: true, vertical: false)

                SettingsFieldRow(label: "Host") {
                    SettingsTextField(placeholder: "resource.cognitiveservices.azure.com", text: $knownHost, monospaced: true)
                }
                .onChange(of: knownHost) { previous, value in
                    handleKnownHostChange(previous: previous, value: value)
                }
            }

            HStack(spacing: theme.space.s12) {
                SettingsFieldRow(label: "Port") {
                    SettingsTextField(placeholder: knownProtocol == .https ? "443" : "80", text: $knownPort, monospaced: true)
                }
                .frame(width: 90)
                .onChange(of: knownPort) { _, _ in testResult = nil }

                SettingsFieldRow(label: "Base Path") {
                    SettingsTextField(placeholder: "/openai/v1", text: $knownBasePath, monospaced: true)
                }
                .onChange(of: knownBasePath) { _, _ in testResult = nil }
            }

            if !knownHost.trimmingCharacters(in: .whitespaces).isEmpty {
                HStack(spacing: theme.space.s8) {
                    Image(systemName: "link")
                        .glyphSize(.footnote)
                        .foregroundColor(theme.text.link)
                    Text(buildKnownEndpointPreview())
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.monoSmall)
                        .foregroundColor(theme.text.secondary)
                }
                .padding(.horizontal, theme.space.s12)
                .padding(.vertical, theme.space.s8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsChrome(.selected)
            }
        }
        .padding(theme.space.s16)
        .settingsChrome(.card)
    }

    private var azureDeploymentsSection: some View {
        DeploymentNamesEditor(
            text: $manualModelIdsText,
            title: "DEPLOYMENT NAMES",
            placeholder: "gpt-6.1-sol\nmy-prod-chat",
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

    /// Whether the add flow shows the optional endpoint override for the
    /// selected known preset. Hidden for Azure (which has its own required
    /// endpoint section) and for OpenAI's ChatGPT/Codex OAuth mode, which
    /// talks to OpenAI's fixed OAuth backend so a base-URL override is moot.
    private var showsKnownEndpointOverride: Bool {
        guard let preset = selectedPreset, preset.isKnown, preset != .azureOpenAI else { return false }
        // OAuth providers talk to a fixed backend, so a base-URL override is moot.
        if selectedAuthMethod.isOAuth { return false }
        return true
    }

    /// Optional base-URL override for known presets, shown under "Advanced".
    /// Pre-filled with the preset's official endpoint; editing it points the
    /// native provider type (Anthropic, OpenAI, Gemini)
    private var knownEndpointOverrideSection: some View {
        let officialHost = selectedPreset?.configuration.host ?? ""
        return VStack(alignment: .leading, spacing: theme.space.s12) {
            HStack(spacing: theme.space.s8) {
                Image(systemName: "network")
                    .glyphSize(.footnote, weight: .semibold)
                    .foregroundColor(theme.text.link)
                Text("Endpoint", bundle: .module)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                    .foregroundColor(theme.text.tertiary)
            }

            Text(
                "Override the base URL to route through a proxy or self-hosted gateway. Leave as-is for the official endpoint.",
                bundle: .module
            )
            .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)

            HStack(spacing: theme.space.s12) {
                SettingsFieldRow(label: "Protocol") {
                    AssignedBaseSegmentedPicker(selection: $knownProtocol, options: RemoteProviderProtocol.segmentedOptions)
                }
                .fixedSize(horizontal: true, vertical: false)

                SettingsFieldRow(label: "Host") {
                    SettingsTextField(placeholder: officialHost, text: $knownHost, monospaced: true)
                }
                .onChange(of: knownHost) { previous, value in
                    handleKnownHostChange(previous: previous, value: value)
                }
            }

            HStack(spacing: theme.space.s12) {
                SettingsFieldRow(label: "Port") {
                    SettingsTextField(placeholder: knownProtocol == .https ? "443" : "80", text: $knownPort, monospaced: true)
                }
                .frame(width: 90)
                .onChange(of: knownPort) { _, _ in testResult = nil }

                SettingsFieldRow(label: "Base Path") {
                    SettingsTextField(placeholder: selectedPreset?.configuration.basePath ?? "/v1", text: $knownBasePath, monospaced: true)
                }
                .onChange(of: knownBasePath) { _, _ in testResult = nil }
            }

            if !knownHost.trimmingCharacters(in: .whitespaces).isEmpty {
                HStack(spacing: theme.space.s8) {
                    Image(systemName: "link")
                        .glyphSize(.footnote)
                        .foregroundColor(theme.text.link)
                    Text(buildKnownEndpointPreview())
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.monoSmall)
                        .foregroundColor(theme.text.secondary)
                }
                .padding(.horizontal, theme.space.s12)
                .padding(.vertical, theme.space.s8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsChrome(.selected)
            }
        }
    }

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            HStack {
                Text(selectedPreset == .openai ? "OpenAI platform API key" : "API key", bundle: .module)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                    .foregroundColor(theme.text.tertiary)
                Spacer()
                HStack(spacing: theme.space.s4) {
                    Image(systemName: "lock.fill")
                        .glyphSize(.tiny)
                    Text("Stored in Keychain", bundle: .module)
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                }
                .foregroundColor(theme.text.tertiary)
            }

            SettingsTextField(
                placeholder: "sk-...",
                text: $apiKey,
                monospaced: true,
                isSecure: true
            )
                .onChange(of: apiKey) { _, _ in testResult = nil }
        }
    }

    /// Whether the known-provider API key + help sections should render. For
    /// dual-mode providers we hide the raw key field when the user picked the
    /// browser sign-in; everything else always shows it.
    private var shouldShowKnownAPIKeyField: Bool {
        guard let preset = selectedPreset, let entry = ProviderCatalog.entry(for: preset) else { return true }
        if entry.primaryOAuthKind != nil { return selectedAuthMethod == .apiKey }
        return true
    }

    /// Body shown for the OAuth-first entry of a dual-mode preset. There's no
    /// key field — the footer button starts the browser flow — so this banner
    /// carries the short "here's how this works" context.
    private func oauthInfoSection(for kind: ProviderOAuthKind) -> some View {
        HStack(spacing: theme.space.s12) {
            Image(systemName: kind.icon)
                .glyphSize(.medium, weight: .semibold)
                .foregroundColor(theme.text.link)
                .frame(width: 28, height: 28)
                .background(Circle().fill(theme.status.info.background))
            Text(LocalizedStringKey(kind.subtitle), bundle: .module)
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.body)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(theme.space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.card)
    }

    private func helpSection(for preset: ProviderPreset) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            Text("Don't have a key?", bundle: .module)
                .catalogTypography(.label, theme: theme, fallback: SettingsFont.rowTitle)
                .foregroundColor(theme.text.secondary)

            VStack(alignment: .leading, spacing: theme.space.s8) {
                ForEach(Array(preset.helpSteps.enumerated()), id: \.offset) { index, text in
                    helpStep(number: index + 1, text: text)
                }
            }

            ProviderHelpLinks(
                preset: preset,
                accentColor: theme.status.info.foreground,
                secondaryTextColor: theme.text.secondary
            )
            .padding(.top, theme.space.s4)
        }
        .padding(theme.space.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.card)
    }

    private func helpStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: theme.space.s10) {
            Text("\(number).", bundle: .module)
                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.monoSmall)
                .foregroundColor(theme.text.tertiary)
                .frame(width: 16, alignment: .trailing)
            Text(text)
                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                .foregroundColor(theme.text.secondary)
        }
    }

    // MARK: - Connection Form (Custom Provider)

    private var connectionFormSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s16) {
            HStack(spacing: theme.space.s8) {
                Image(systemName: "network")
                    .glyphSize(.caption, weight: .semibold)
                    .foregroundColor(theme.text.link)
                Text("Connection", bundle: .module)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                    .foregroundColor(theme.text.secondary)
            }

            SettingsFieldRow(label: "Name") {
                SettingsTextField(placeholder: L("e.g. My Provider"), text: $customName)
            }

            HStack(spacing: theme.space.s12) {
                SettingsFieldRow(label: "Protocol") {
                    AssignedBaseSegmentedPicker(selection: $customProtocol, options: RemoteProviderProtocol.segmentedOptions)
                }
                .fixedSize(horizontal: true, vertical: false)

                SettingsFieldRow(label: "Host") {
                    SettingsTextField(placeholder: "api.example.com", text: $customHost, monospaced: true)
                }
                    .onChange(of: customHost) { previous, value in
                        handleCustomHostChange(previous: previous, value: value)
                    }
            }

            HStack(spacing: theme.space.s12) {
                SettingsFieldRow(label: "Port") {
                    SettingsTextField(placeholder: customProtocol == .https ? "443" : "80", text: $customPort, monospaced: true)
                }
                .frame(width: 90)

                SettingsFieldRow(label: "Base Path") {
                    SettingsTextField(placeholder: "/v1", text: $customBasePath, monospaced: true)
                }
            }

            if !customHost.trimmingCharacters(in: .whitespaces).isEmpty {
                endpointPreview
            }
        }
        .padding(theme.space.s16)
    }

    private var endpointPreview: some View {
        HStack(spacing: theme.space.s8) {
            Image(systemName: "link")
                .glyphSize(.footnote)
                .foregroundColor(theme.text.link)
            Text(buildEndpointPreview())
                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.monoSmall)
                .foregroundColor(theme.text.secondary)
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.selected)
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
        ThemeHairlineDivider()
            .padding(.horizontal, theme.space.s16)
    }

    // MARK: - Advanced Settings

    private var advancedSettingsSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s0) {
            Button(
                action: {
                    withAnimation(theme.motion.springAnimation) {
                        showAdvanced.toggle()
                    }
                },
                label: {
                    HStack(spacing: theme.space.s8) {
                        Image(systemName: "chevron.right")
                            .glyphSize(.micro, weight: .semibold)
                            .foregroundColor(theme.text.tertiary)
                            .rotationEffect(.degrees(showAdvanced ? 90 : 0))

                        Text(showAdvanced ? L("Hide advanced settings") : L("Show advanced settings"))
                            .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                            .foregroundColor(theme.text.secondary)

                        Spacer()
                    }
                    .padding(.vertical, theme.space.s8)
                    .padding(.horizontal, theme.space.s12)
                    .settingsChrome(.inset)
                    .contentShape(Rectangle())
                }
            )
            .buttonStyle(PlainButtonStyle())

            if showAdvanced {
                VStack(alignment: .leading, spacing: theme.space.s16) {
                    // Optional base-URL override for known presets.
                    if showsKnownEndpointOverride {
                        knownEndpointOverrideSection
                    }

                    // Timeout
                    timeoutSection

                    // Custom headers
                    VStack(alignment: .leading, spacing: theme.space.s10) {
                        HStack {
                            Text("Custom headers", bundle: .module)
                                .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                                .foregroundColor(theme.text.tertiary)
                            Spacer()
                            SettingsIconButton("plus", help: L("Add header"), size: .compact) {
                                customHeaders.append(HeaderEntry(key: "", value: "", isSecret: false))
                            }
                        }

                        if customHeaders.isEmpty {
                            Text("No custom headers configured", bundle: .module)
                                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                                .foregroundColor(theme.text.tertiary)
                                .padding(.vertical, theme.space.s6)
                        } else {
                            ForEach($customHeaders) { $header in
                                CompactHeaderRow(header: $header) {
                                    customHeaders.removeAll { $0.id == header.id }
                                }
                            }
                        }
                    }
                }
                .padding(.top, theme.space.s12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Timeout

    private var timeoutSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            SettingsSlider(
                title: "Request Timeout",
                valueText: disableTimeout ? L("No limit") : "\(Int(timeout))s",
                value: $timeout,
                range: 10 ... 300,
                step: 10
            )
            .disabled(disableTimeout)

            // Intercepting binding: turning the switch ON only opens the warning;
            // `disableTimeout` flips to true after the user confirms. Turning OFF
            // is immediate. This keeps loadProvider() (which sets the @State
            // directly) from spuriously triggering the alert on sheet open.
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text("Disable timeout", bundle: .module)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)
                    Text("Let requests run with no time limit", bundle: .module)
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                        .foregroundColor(theme.text.tertiary)
                }
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { disableTimeout },
                        set: { wantsOn in
                            if wantsOn {
                                showNoTimeoutWarning = true
                            } else {
                                disableTimeout = false
                            }
                        }
                    )
                )
                .settingsSwitch()
            }
            .padding(.top, theme.space.s6)
        }
    }

    // MARK: - Footer

    private func sheetFooter(canProceed: Bool, onAction: @escaping () -> Void) -> some View {
        HStack(spacing: theme.space.s12) {
            testResultBadge

            Spacer()

            Button {
                dismiss()
            } label: {
                Text("Cancel", bundle: .module)
            }
            .assignedSettingsButtonStyle(.secondary)
            .keyboardShortcut(.cancelAction)

            Button(action: onAction) {
                Text(actionButtonTitle)
            }
            .assignedSettingsButtonStyle(.primary, isLoading: isTesting)
            .disabled(!canProceed || isTesting)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, theme.space.s24)
        .padding(.vertical, theme.space.s16)
        .background(
            theme.surface.subtle
                .overlay(
                    ThemeHairlineDivider(),
                    alignment: .top
                )
        )
    }

    @ViewBuilder
    private var testResultBadge: some View {
        if let result = testResult {
            HStack(spacing: theme.space.s6) {
                switch result {
                case .success(let models):
                    Image(systemName: "checkmark.circle.fill")
                        .glyphSize(.caption)
                        .foregroundColor(theme.status.success.foreground)
                    Text("\(models.count) model\(models.count == 1 ? "" : "s") found", bundle: .module)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                        .foregroundColor(theme.status.success.foreground)
                case .failure(let error):
                    Image(systemName: "xmark.circle.fill")
                        .glyphSize(.caption)
                        .foregroundColor(theme.status.error.foreground)
                    Text(error)
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                        .foregroundColor(theme.status.error.foreground)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, theme.space.s8)
            .padding(.vertical, theme.space.s6)
            .settingsChrome(result.isSuccess ? .status(.success) : .status(.error))
        }
    }

    private var actionButtonTitle: String {
        let oauthKind = selectedOAuthKind
        if isTesting { return oauthKind != nil ? L("Signing in...") : L("Testing...") }
        if testResult?.isSuccess == true || canSaveKnownProviderWithoutSuccessfulTest { return L("Add Provider") }
        if case .failure = testResult { return L("Retry") }
        if let oauthKind {
            return NSLocalizedString(oauthKind.ctaTitle, bundle: .module, comment: "")
        }
        return L("Test Connection")
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
                if selectedOAuthKind == .openAICodex {
                    let tokens = try await OpenAICodexOAuthService.signIn()
                    await MainActor.run {
                        oauthTokens = tokens
                    }
                    models = await OpenAICodexOAuthService.availableModels(for: tokens)
                } else if selectedOAuthKind == .openRouter {
                    // The browser sign-in mints a regular OpenRouter API key.
                    // Stash it in `apiKey` so `saveKnownProvider` persists it
                    // via the same path as a pasted key, then verify by
                    // running the usual /models probe with the new key.
                    let key = try await OpenRouterOAuthService.signIn()
                    await MainActor.run {
                        apiKey = key
                    }
                    models = try await RemoteProviderManager.shared.testConnection(
                        host: connection.host,
                        providerProtocol: connection.providerProtocol,
                        port: connection.port,
                        basePath: connection.basePath,
                        authType: .apiKey,
                        providerType: config.providerType,
                        apiKey: key,
                        headers: HeaderEntry.buildHeaders(from: customHeaders),
                        manualModelIds: parseManualModelIds(manualModelIdsText)
                    )
                } else if selectedOAuthKind == .xai {
                    // Grok sign-in returns access/refresh tokens; stash them so
                    // `saveKnownProvider` persists them as `.xaiOAuth`. The
                    // browser sign-in IS the test — xAI OAuth tokens cannot list
                    // models (HTTP 403), so we surface the built-in catalog
                    // rather than probing /models.
                    let tokens = try await XAIOAuthService.signIn()
                    await MainActor.run {
                        oauthTokens = tokens
                    }
                    models = XAIOAuthService.supportedModels
                } else {
                    models = try await RemoteProviderManager.shared.testConnection(
                        host: connection.host,
                        providerProtocol: connection.providerProtocol,
                        port: connection.port,
                        basePath: connection.basePath,
                        authType: .apiKey,
                        providerType: config.providerType,
                        apiKey: apiKey,
                        headers: HeaderEntry.buildHeaders(from: customHeaders),
                        manualModelIds: parseManualModelIds(manualModelIdsText)
                    )
                }
                await MainActor.run {
                    withAnimation {
                        testResult = .success(models); isTesting = false
                    }
                }
                // Auto-complete on green: a successful test/sign-in is the
                // confirmation, so finalize without a second "Add Provider"
                // press. The brief pause lets the green success state register.
                try? await Task.sleep(nanoseconds: 450_000_000)
                await MainActor.run { saveKnownProvider() }
            } catch {
                let message: String
                switch selectedOAuthKind {
                case .openAICodex: message = OpenAICodexOAuthService.diagnosticMessage(for: error)
                case .xai: message = XAIOAuthService.diagnosticMessage(for: error)
                default: message = error.localizedDescription
                }
                await MainActor.run {
                    withAnimation {
                        testResult = .failure(message); isTesting = false
                    }
                }
            }
        }
    }

    private func saveKnownProvider() {
        guard !hasFinalized else { return }
        guard let preset = selectedPreset else { return }
        hasFinalized = true
        let config = preset.configuration
        let connection = knownProviderConnection(for: preset)
        let (regularHeaders, secretKeys) = HeaderEntry.partition(customHeaders)
        // OpenAI Codex and xAI persist OAuth tokens via a service-provided
        // provider config; OpenRouter's OAuth mints a plain key handled by the
        // standard apiKey path below.
        let isCodexOAuth = selectedOAuthKind == .openAICodex
        let isXAIOAuth = selectedOAuthKind == .xai
        let usesOAuthTokens = isCodexOAuth || isXAIOAuth
        let providerConfig: RemoteProvider? =
            isCodexOAuth
            ? OpenAICodexOAuthService.makeProvider()
            : (isXAIOAuth ? XAIOAuthService.makeProvider() : nil)

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
            disableTimeout: disableTimeout,
            manualModelIds: parseManualModelIds(manualModelIdsText),
            secretHeaderKeys: secretKeys
        )

        saveSecretHeaders(for: remoteProvider.id)
        onSave(
            remoteProvider,
            usesOAuthTokens ? nil : (apiKey.isEmpty ? nil : apiKey),
            usesOAuthTokens ? oauthTokens : nil
        )
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
                    headers: HeaderEntry.buildHeaders(from: customHeaders),
                    manualModelIds: parseManualModelIds(manualModelIdsText)
                )
                await MainActor.run {
                    withAnimation {
                        testResult = .success(models); isTesting = false
                    }
                }
                // Auto-complete on green (see `testKnownProvider`).
                try? await Task.sleep(nanoseconds: 450_000_000)
                await MainActor.run { saveCustomProvider() }
            } catch {
                let isMCPEndpoint: Bool
                if let serviceError = error as? RemoteProviderServiceError,
                    case .mcpEndpointDetected = serviceError
                {
                    isMCPEndpoint = true
                } else {
                    isMCPEndpoint = false
                }
                await MainActor.run {
                    withAnimation {
                        testResult = .failure(error.localizedDescription); isTesting = false
                    }
                    if isMCPEndpoint {
                        showMCPRedirectPrompt = true
                    }
                }
            }
        }
    }

    /// Hand the entered endpoint off to the MCP connections flow: navigate to
    /// Tools & MCP > Services and open the add sheet prefilled with the URL and
    /// (when present) the API key as a bearer token.
    private func redirectToMCPConnections() {
        let trimmedName = customName.trimmingCharacters(in: .whitespaces)
        let trimmedHost = customHost.trimmingCharacters(in: .whitespaces)
        let trimmedBasePath = customBasePath.trimmingCharacters(in: .whitespaces)
        // Reuse RemoteProvider's URL normalization (host-with-path splitting,
        // port handling) rather than re-deriving the string here.
        let endpoint = RemoteProvider(
            name: "Draft",
            host: trimmedHost,
            providerProtocol: customProtocol,
            port: Int(customPort),
            // Mirror the fallback the failed test used, so the hand-off
            // carries the exact URL that answered like an MCP server.
            basePath: trimmedBasePath.isEmpty ? "/v1" : trimmedBasePath,
            authType: customAuthType,
            providerType: .openaiLegacy
        )
        guard let url = endpoint.baseURL?.absoluteString else { return }
        // Match the test's auth gating: only carry the key when the user
        // actually selected API-key auth, not stale text behind "No Auth".
        let trimmedKey =
            customAuthType == .apiKey
            ? apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let management = ManagementStateManager.shared
        management.pendingMCPProviderDraft = MCPProviderDraft(
            name: trimmedName,
            url: url,
            bearerToken: trimmedKey.isEmpty ? nil : trimmedKey
        )
        management.pendingToolsSubTab = ToolsTab.services.rawValue
        management.selectedTab = .tools
        dismiss()
    }

    private func saveCustomProvider() {
        guard !hasFinalized else { return }
        hasFinalized = true
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
            disableTimeout: disableTimeout,
            secretHeaderKeys: secretKeys
        )

        saveSecretHeaders(for: remoteProvider.id)
        let savedApiKey = customAuthType == .apiKey && !apiKey.isEmpty ? apiKey : nil
        onSave(remoteProvider, savedApiKey, nil)
        dismiss()
    }

    private func saveSecretHeaders(for providerId: UUID) {
        for header in customHeaders where header.isSecret && !header.key.isEmpty && !header.value.isEmpty {
            if !RemoteProviderKeychain.saveHeaderSecret(header.value, key: header.key, for: providerId) {
                NSLog("RemoteProviderEditSheet: failed to save secret header to Keychain")
            }
        }
    }

    /// Resolve the connection for a known preset, applying the user's endpoint
    /// overrides (`knownHost` etc.) on top of the preset defaults. Blank fields
    /// fall back to the official preset values, so users who never touch the
    /// override get the stock endpoint
    private func knownProviderConnection(for preset: ProviderPreset) -> ProviderPresetConfiguration {
        let config = preset.configuration
        let trimmedHost = knownHost.trimmingCharacters(in: .whitespaces)
        let trimmedBasePath = knownBasePath.trimmingCharacters(in: .whitespaces)
        let port: Int? = knownPort.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Int(knownPort)

        return ProviderPresetConfiguration(
            name: config.name,
            host: trimmedHost.isEmpty ? config.host : trimmedHost,
            providerProtocol: knownProtocol,
            port: port,
            basePath: trimmedBasePath.isEmpty ? config.basePath : trimmedBasePath,
            authType: config.authType,
            providerType: config.providerType,
            defaultManualModelIds: config.defaultManualModelIds
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

    private var diagnosticsReport: ProviderDiagnosticReport {
        ProviderNetworkDiagnostics.remoteProviderReport(
            provider: provider,
            state: RemoteProviderManager.shared.providerStates[provider.id],
            proxy: GlobalProxySettings.currentDiagnostic(),
            apiKeyPresent: apiKeyPresent,
            oauthTokensPresent: oauthTokensPresent
        )
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
    @State private var pendingOAuthTokens: RemoteProviderOAuthTokens?
    @State private var manualModelIdsText: String = ""

    // Advanced
    @State private var showAdvanced = false
    @State private var timeout: Double = 60
    @State private var disableTimeout: Bool = false
    @State private var showNoTimeoutWarning = false
    @State private var customHeaders: [HeaderEntry] = []

    // UI state
    @State private var isTesting = false
    @State private var testResult: ProviderTestResult?
    @State private var hasAppeared = false

    // Diagnostics credential presence (drives the diagnostics report)
    @State private var apiKeyPresent = false
    @State private var oauthTokensPresent = false

    // OpenRouter re-authorization. Collapsed to a single state so we can't
    // accidentally render both "succeeded" and "failed" feedback at once.
    @State private var reauthorizeState: ReauthorizeState = .idle

    enum ReauthorizeState: Equatable {
        case idle
        case signingIn
        case succeeded
        case failed(String)

        var isSigningIn: Bool {
            if case .signingIn = self { return true }
            return false
        }
    }

    private var usesCodexOAuth: Bool {
        provider.authType == .openAICodexOAuth || provider.providerType == .openAICodex
    }

    var body: some View {
        VStack(spacing: theme.space.s0) {
            sheetHeader

            ScrollView {
                VStack(alignment: .leading, spacing: theme.space.s20) {
                    if usesCodexOAuth {
                        providerReauthorizeSection
                        advancedSettingsSection(showConnectionDetails: true)
                    } else if let preset = matchedPreset {
                        knownProviderEditContent(preset: preset)
                    } else {
                        customProviderEditContent
                    }

                    // Cancel the surrounding 24pt inset so diagnostics rows span
                    // the full sheet width (they carry their own internal padding).
                    ProviderDiagnosticsRowsView(report: diagnosticsReport, maxRows: nil)
                        .padding(.horizontal, -24)
                }
                .padding(theme.space.s24)
            }

            sheetFooter
        }
        .frame(width: 540, height: matchedPreset != nil ? 520 : 580)
        .background(theme.surface.canvas)
        .clipShape(RoundedRectangle(cornerRadius: theme.radius.xlarge))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.xlarge)
                .stroke(theme.border.subtle, lineWidth: theme.stroke.default)
        )
        .opacity(hasAppeared ? 1 : 0)
        .scaleEffect(hasAppeared ? 1 : 0.95)
        .animation(theme.motion.springAnimation, value: hasAppeared)
        .onAppear {
            loadProvider()
            Task { await refreshCredentialState() }
            withAnimation { hasAppeared = true }
        }
        .themedAlert(
            "Disable request timeout?",
            isPresented: $showNoTimeoutWarning,
            accessory: AnyView(NoTimeoutWarningContent()),
            buttons: [
                .cancel("Cancel"),
                .destructive("Disable Timeout") { disableTimeout = true },
            ],
            presentationStyle: .contained
        )
    }

    // MARK: - Header

    private var sheetHeader: some View {
        var header = SettingsSheetHeader(
            icon: "pencil",
            title: "Edit \(provider.name)",
            subtitle: "Modify your API connection"
        ) { dismiss() }
        if let preset = matchedPreset {
            header.leading = AnyView(
                Circle()
                    .fill(LinearGradient(colors: preset.gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(ProviderIcon(preset: preset, size: 13, color: FixedPalette.onMedia))
            )
        }
        return header
    }

    // MARK: - Known Provider Edit

    private func knownProviderEditContent(preset: ProviderPreset) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s20) {
            if preset == .openrouter {
                providerReauthorizeSection
            }

            // API Key section
            VStack(alignment: .leading, spacing: theme.space.s6) {
                HStack {
                    Text("API key", bundle: .module)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                        .foregroundColor(theme.text.tertiary)
                    Spacer()
                    HStack(spacing: theme.space.s4) {
                        Image(systemName: "lock.fill")
                            .glyphSize(.tiny)
                        Text("Stored in Keychain", bundle: .module)
                            .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                    }
                    .foregroundColor(theme.text.tertiary)
                }

                SettingsTextField(
                    placeholder: L("Leave blank to keep current"),
                    text: $apiKey,
                    monospaced: true,
                    isSecure: true
                )
                    .onChange(of: apiKey) { _, _ in
                        // User edited the field manually — clear any prior
                        // re-authorize confirmation/error so we don't show
                        // stale feedback against a typed key.
                        if reauthorizeState != .idle && !reauthorizeState.isSigningIn {
                            reauthorizeState = .idle
                        }
                    }
            }

            if preset == .azureOpenAI {
                DeploymentNamesEditor(
                    text: $manualModelIdsText,
                    title: "DEPLOYMENT NAMES",
                    placeholder: "gpt-6.1-sol\nmy-prod-chat",
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

    // MARK: - Provider Re-authorization

    /// Reuse browser sign-in for existing providers. Stage the refreshed
    /// credential until Save, preserving the provider ID and configuration.
    private var providerReauthorizeSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            Text("Account", bundle: .module)
                .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                .foregroundColor(theme.text.tertiary)

            HStack(spacing: theme.space.s12) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .glyphSize(.medium, weight: .semibold)
                    .foregroundColor(theme.text.link)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(theme.status.info.background))

                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text(usesCodexOAuth ? "Sign in with ChatGPT" : "Re-authorize with OpenRouter", bundle: .module)
                        .catalogTypography(.heading, theme: theme, fallback: SettingsFont.sectionTitle)
                        .foregroundColor(theme.text.primary)
                    Text(usesCodexOAuth ? "Use your ChatGPT account with Codex access. Save after signing in." : "Mint a fresh key in your browser without leaving this sheet.", bundle: .module)
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                        .foregroundColor(theme.text.secondary)
                }

                Spacer()

                let signingIn = reauthorizeState.isSigningIn
                Button(action: reauthorizeProvider) {
                    HStack(spacing: theme.space.s6) {
                        if signingIn {
                            SettingsSpinner()
                        }
                        Text(signingIn ? "Signing in..." : "Sign in", bundle: .module)
                    }
                }
                .assignedSettingsButtonStyle(.primary)
                .disabled(signingIn)
            }
            .padding(theme.space.s12)
            .settingsChrome(.selected)

            reauthorizeStatusLine
        }
    }

    @ViewBuilder
    private var reauthorizeStatusLine: some View {
        switch reauthorizeState {
        case .succeeded:
            HStack(spacing: theme.space.s6) {
                Image(systemName: "checkmark.circle.fill")
                    .glyphSize(.footnote)
                    .foregroundColor(theme.status.success.foreground)
                Text(usesCodexOAuth ? "Signed in. Save to apply." : "New key minted. Save to apply.", bundle: .module)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                    .foregroundColor(theme.status.success.foreground)
            }
        case .failed(let message):
            HStack(spacing: theme.space.s6) {
                Image(systemName: "xmark.circle.fill")
                    .glyphSize(.footnote)
                    .foregroundColor(theme.status.error.foreground)
                Text(message)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.status.error.foreground)
                    .lineLimit(2)
            }
        case .idle, .signingIn:
            EmptyView()
        }
    }

    private func reauthorizeProvider() {
        reauthorizeState = .signingIn
        Task { @MainActor in
            do {
                if usesCodexOAuth {
                    pendingOAuthTokens = try await OpenAICodexOAuthService.signIn()
                } else {
                    apiKey = try await OpenRouterOAuthService.signIn()
                }
                reauthorizeState = .succeeded
            } catch {
                reauthorizeState = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Custom Provider Edit

    private var customProviderEditContent: some View {
        VStack(alignment: .leading, spacing: theme.space.s20) {
            // Connection form
            VStack(alignment: .leading, spacing: theme.space.s0) {
                connectionFormSection

                sectionDivider

                // Authentication
                VStack(alignment: .leading, spacing: theme.space.s12) {
                    HStack(spacing: theme.space.s8) {
                        Image(systemName: "key.fill")
                            .glyphSize(.caption, weight: .semibold)
                            .foregroundColor(theme.text.link)
                        Text("Authentication", bundle: .module)
                            .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                            .foregroundColor(theme.text.secondary)
                    }

                    if authType == .openAICodexOAuth {
                        HStack(spacing: theme.space.s10) {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                                .glyphSize(.medium, weight: .semibold)
                                .foregroundColor(theme.text.link)
                            VStack(alignment: .leading, spacing: theme.space.s2) {
                                Text("ChatGPT / Codex subscription", bundle: .module)
                                    .catalogTypography(.heading, theme: theme, fallback: SettingsFont.sectionTitle)
                                    .foregroundColor(theme.text.primary)
                                Text("Signed in with ChatGPT Plus/Pro. Tokens are stored in Keychain.", bundle: .module)
                                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                                    .foregroundColor(theme.text.secondary)
                            }
                            Spacer()
                        }
                        .padding(theme.space.s12)
                        .settingsChrome(.selected)
                    } else if authType == .xaiOAuth {
                        HStack(spacing: theme.space.s10) {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                                .glyphSize(.medium, weight: .semibold)
                                .foregroundColor(theme.text.link)
                            VStack(alignment: .leading, spacing: theme.space.s2) {
                                Text("Grok (SuperGrok / X Premium+)", bundle: .module)
                                    .catalogTypography(.heading, theme: theme, fallback: SettingsFont.sectionTitle)
                                    .foregroundColor(theme.text.primary)
                                Text("Signed in with Grok. Tokens are stored in Keychain.", bundle: .module)
                                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                                    .foregroundColor(theme.text.secondary)
                            }
                            Spacer()
                        }
                        .padding(theme.space.s12)
                        .settingsChrome(.selected)
                    } else {
                        AssignedBaseSegmentedPicker(selection: $authType, options: RemoteProviderAuthType.segmentedOptions)
                    }

                    if authType == .apiKey {
                        SettingsTextField(
                            placeholder: L("Leave blank to keep current"),
                            text: $apiKey,
                            monospaced: true,
                            isSecure: true
                        )
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(theme.space.s16)
                .animation(theme.motion.springAnimation, value: authType)
            }
            .settingsChrome(.card)

            // Advanced settings (timeout + headers only)
            advancedSettingsSection(showConnectionDetails: false)
        }
    }

    // MARK: - Connection Form (Edit)

    private var connectionFormSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s16) {
            HStack(spacing: theme.space.s8) {
                Image(systemName: "network")
                    .glyphSize(.caption, weight: .semibold)
                    .foregroundColor(theme.text.link)
                Text("Connection", bundle: .module)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                    .foregroundColor(theme.text.secondary)
            }

            SettingsFieldRow(label: "Name") {
                SettingsTextField(placeholder: L("e.g. My Provider"), text: $name)
            }

            HStack(spacing: theme.space.s12) {
                SettingsFieldRow(label: "Protocol") {
                    AssignedBaseSegmentedPicker(selection: $providerProtocol, options: RemoteProviderProtocol.segmentedOptions)
                }
                .fixedSize(horizontal: true, vertical: false)

                SettingsFieldRow(label: "Host") {
                    SettingsTextField(placeholder: "api.example.com", text: $host, monospaced: true)
                }
                    .onChange(of: host) { previous, value in
                        handleHostChange(previous: previous, value: value)
                    }
            }

            HStack(spacing: theme.space.s12) {
                SettingsFieldRow(label: "Port") {
                    SettingsTextField(placeholder: providerProtocol == .https ? "443" : "80", text: $portString, monospaced: true)
                }
                .frame(width: 90)

                SettingsFieldRow(label: "Base Path") {
                    SettingsTextField(placeholder: "/v1", text: $basePath, monospaced: true)
                }
            }

            if !host.trimmingCharacters(in: .whitespaces).isEmpty {
                HStack(spacing: theme.space.s8) {
                    Image(systemName: "link")
                        .glyphSize(.footnote)
                        .foregroundColor(theme.text.link)
                    Text(buildEditEndpointPreview())
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.monoSmall)
                        .foregroundColor(theme.text.secondary)
                }
                .padding(.horizontal, theme.space.s12)
                .padding(.vertical, theme.space.s8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsChrome(.selected)
            }
        }
        .padding(theme.space.s16)
    }

    private var sectionDivider: some View {
        ThemeHairlineDivider()
            .padding(.horizontal, theme.space.s16)
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
        VStack(alignment: .leading, spacing: theme.space.s12) {
            Text("Need a new key?", bundle: .module)
                .catalogTypography(.label, theme: theme, fallback: SettingsFont.rowTitle)
                .foregroundColor(theme.text.secondary)

            ProviderHelpLinks(
                preset: preset,
                accentColor: theme.status.info.foreground,
                secondaryTextColor: theme.text.secondary
            )
        }
        .padding(theme.space.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.card)
    }

    // MARK: - Advanced Settings (Edit)

    private func advancedSettingsSection(showConnectionDetails: Bool) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s0) {
            Button(
                action: {
                    withAnimation(theme.motion.springAnimation) {
                        showAdvanced.toggle()
                    }
                },
                label: {
                    HStack(spacing: theme.space.s8) {
                        Image(systemName: "chevron.right")
                            .glyphSize(.micro, weight: .semibold)
                            .foregroundColor(theme.text.tertiary)
                            .rotationEffect(.degrees(showAdvanced ? 90 : 0))

                        Text(showAdvanced ? L("Hide advanced settings") : L("Show advanced settings"))
                            .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                            .foregroundColor(theme.text.secondary)

                        Spacer()
                    }
                    .padding(.vertical, theme.space.s8)
                    .padding(.horizontal, theme.space.s12)
                    .settingsChrome(.inset)
                    .contentShape(Rectangle())
                }
            )
            .buttonStyle(PlainButtonStyle())

            if showAdvanced {
                VStack(alignment: .leading, spacing: theme.space.s16) {
                    // Connection details (for known provider edit)
                    if showConnectionDetails {
                        VStack(alignment: .leading, spacing: theme.space.s0) {
                            connectionFormSection
                        }
                        .settingsChrome(.card)
                    }

                    // Timeout
                    timeoutSection

                    // Custom headers
                    VStack(alignment: .leading, spacing: theme.space.s10) {
                        HStack {
                            Text("Custom headers", bundle: .module)
                                .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                                .foregroundColor(theme.text.tertiary)
                            Spacer()
                            SettingsIconButton("plus", help: L("Add header"), size: .compact) {
                                customHeaders.append(HeaderEntry(key: "", value: "", isSecret: false))
                            }
                        }

                        if customHeaders.isEmpty {
                            Text("No custom headers configured", bundle: .module)
                                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                                .foregroundColor(theme.text.tertiary)
                                .padding(.vertical, theme.space.s6)
                        } else {
                            ForEach($customHeaders) { $header in
                                CompactHeaderRow(header: $header) {
                                    customHeaders.removeAll { $0.id == header.id }
                                }
                            }
                        }
                    }
                }
                .padding(.top, theme.space.s12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Timeout

    private var timeoutSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            SettingsSlider(
                title: "Request Timeout",
                valueText: disableTimeout ? L("No limit") : "\(Int(timeout))s",
                value: $timeout,
                range: 10 ... 300,
                step: 10
            )
            .disabled(disableTimeout)

            // Intercepting binding: turning the switch ON only opens the warning;
            // `disableTimeout` flips to true after the user confirms. Turning OFF
            // is immediate. This keeps loadProvider() (which sets the @State
            // directly) from spuriously triggering the alert on sheet open.
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text("Disable timeout", bundle: .module)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)
                    Text("Let requests run with no time limit", bundle: .module)
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                        .foregroundColor(theme.text.tertiary)
                }
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { disableTimeout },
                        set: { wantsOn in
                            if wantsOn {
                                showNoTimeoutWarning = true
                            } else {
                                disableTimeout = false
                            }
                        }
                    )
                )
                .settingsSwitch()
            }
            .padding(.top, theme.space.s6)
        }
    }

    // MARK: - Footer

    private var sheetFooter: some View {
        HStack(spacing: theme.space.s12) {
            // Test result badge
            testResultBadge

            Spacer()

            Button {
                dismiss()
            } label: {
                Text("Cancel", bundle: .module)
            }
            .assignedSettingsButtonStyle(.secondary)
            .keyboardShortcut(.cancelAction)

            Button(action: save) {
                Text("Save Changes", bundle: .module)
            }
            .assignedSettingsButtonStyle(.primary)
            .disabled(!canSave)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, theme.space.s24)
        .padding(.vertical, theme.space.s16)
        .background(
            theme.surface.subtle
                .overlay(
                    ThemeHairlineDivider(),
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
                HStack(spacing: theme.space.s6) {
                    if isTesting {
                        SettingsSpinner()
                    } else if let result = testResult {
                        Image(systemName: result.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .glyphSize(.caption)
                    } else {
                        Image(systemName: "bolt.fill")
                            .glyphSize(.footnote)
                    }

                    Text(testButtonLabel)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                }
            }
        )
        .assignedSettingsButtonStyle(.secondary)
        .disabled(isTesting || reauthorizeState.isSigningIn || pendingOAuthTokens != nil)
    }

    private var testButtonLabel: String {
        if isTesting { return L("Testing...") }
        if let result = testResult {
            switch result {
            case .success(let models):
                return models.count == 1 ? L("1 model") : L("\(models.count) models")
            case .failure: return L("Retry")
            }
        }
        return L("Test")
    }

    private var testButtonColor: Color {
        guard let result = testResult else { return theme.text.secondary }
        return result.isSuccess ? theme.status.success.foreground : theme.status.error.foreground
    }

    private var testButtonBackground: Color {
        guard let result = testResult else { return theme.surface.hover }
        return result.isSuccess
            ? theme.status.success.background : theme.status.error.background
    }

    private var canSave: Bool {
        guard !reauthorizeState.isSigningIn else { return false }
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

    /// When a full URL lands in the host field, distribute its pieces across
    /// the protocol/port/base path fields so users can paste the whole
    /// endpoint instead of hand-splitting it.
    private func handleHostChange(previous: String, value: String) {
        guard shouldSplitHostInput(previous: previous, value: value),
            let components = parsePastedEndpoint(value)
        else { return }
        testResult = nil
        host = components.host
        if let pastedProtocol = components.providerProtocol { providerProtocol = pastedProtocol }
        if let port = components.port { portString = String(port) }
        if let basePath = components.basePath { self.basePath = basePath }
    }

    private func loadProvider() {
        name = provider.name
        host = provider.host
        providerProtocol = provider.providerProtocol
        if let port = provider.port { portString = String(port) }
        basePath = provider.basePath
        authType = provider.authType
        providerType = provider.providerType
        timeout = provider.timeout
        disableTimeout = provider.disableTimeout
        manualModelIdsText = provider.manualModelIds.joined(separator: "\n")
        customHeaders = provider.customHeaders.map { HeaderEntry(key: $0.key, value: $0.value, isSecret: false) }
        for key in provider.secretHeaderKeys {
            customHeaders.append(HeaderEntry(key: key, value: "", isSecret: true))
        }
    }

    @MainActor
    private func refreshCredentialState() async {
        let providerID = provider.id
        let credentials = await RemoteProviderKeychain.runOffCooperativeExecutor {
            (
                RemoteProviderKeychain.hasAPIKey(for: providerID),
                RemoteProviderKeychain.hasOAuthTokens(for: providerID)
            )
        }
        apiKeyPresent = credentials.0
        oauthTokensPresent = credentials.1
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
                // xAI OAuth tokens cannot list models (HTTP 403); the manager
                // short-circuits to the built-in catalog for `.xaiOAuth`.
                // Passing the provider id lets ChatGPT/Codex use the stored
                // OAuth tokens to query the live catalog when signed in.
                let models = try await RemoteProviderManager.shared.testConnection(
                    host: trimmedHost,
                    providerProtocol: providerProtocol,
                    port: port,
                    basePath: trimmedBasePath,
                    authType: authType,
                    providerType: providerType,
                    apiKey: testApiKey,
                    headers: HeaderEntry.buildHeaders(from: customHeaders),
                    manualModelIds: parseManualModelIds(manualModelIdsText),
                    providerId: provider.id
                )
                await MainActor.run {
                    testResult = .success(models)
                    isTesting = false
                }
            } catch {
                let message: String
                if authType == .openAICodexOAuth || providerType == .openAICodex {
                    message = OpenAICodexOAuthService.diagnosticMessage(for: error)
                } else if authType == .xaiOAuth {
                    message = XAIOAuthService.diagnosticMessage(for: error)
                } else {
                    message = error.localizedDescription
                }
                await MainActor.run {
                    testResult = .failure(message)
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
            // Editing must not overwrite the user's auto-connect choice.
            autoConnect: provider.autoConnect,
            timeout: timeout,
            disableTimeout: disableTimeout,
            manualModelIds: parseManualModelIds(manualModelIdsText),
            secretHeaderKeys: secretKeys
        )

        for header in customHeaders where header.isSecret && !header.key.isEmpty && !header.value.isEmpty {
            if !RemoteProviderKeychain.saveHeaderSecret(header.value, key: header.key, for: updatedProvider.id) {
                NSLog("RemoteProviderEditSheet: failed to save secret header to Keychain")
            }
        }

        onSave(updatedProvider, apiKey.isEmpty ? nil : apiKey, pendingOAuthTokens)
        dismiss()
    }
}

// MARK: - No-Timeout Warning Content

private struct NoTimeoutWarningContent: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            Text("Requests will run with no time limit. Before enabling:", bundle: .module)
            bullet(
                "A stalled provider or dropped connection can hang a request indefinitely. You'll have to stop it manually"
            )
            bullet("Upstream timeouts (LM Studio, proxies, tunnels) still apply")
            bullet("Only use this on trusted hardware for long-running work")
        }
        .textStyle(.bodySmall)
        .foregroundColor(theme.text.secondary)
        .lineSpacing(2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, theme.space.s8)
    }

    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: theme.space.s8) {
            Text(verbatim: "•")
            Text(text, bundle: .module)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Segmented Options

private extension RemoteProviderProtocol {
    static var segmentedOptions: [SettingsPickerRow<RemoteProviderProtocol>.Option] {
        [.init(.https, "HTTPS", verbatim: true), .init(.http, "HTTP", verbatim: true)]
    }
}

private extension RemoteProviderAuthType {
    static var segmentedOptions: [SettingsPickerRow<RemoteProviderAuthType>.Option] {
        [.init(.none, "No Auth"), .init(.apiKey, "API Key")]
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

    /// Build a flat dictionary of non-empty headers. Entries whose name or
    /// value contains CR/LF or other control characters are dropped so a
    /// malformed header can't be persisted (and later crash or split the
    /// upstream request); the wire layer enforces the same rule.
    static func buildHeaders(from entries: [HeaderEntry]) -> [String: String] {
        var headers: [String: String] = [:]
        for entry in entries
        where !entry.key.isEmpty && !entry.value.isEmpty
            && RemoteProviderService.isSafeHeader(name: entry.key, value: entry.value)
        {
            headers[entry.key] = entry.value
        }
        return headers
    }

    /// Partition entries into regular headers dict and secret key names.
    /// Secret values live in Keychain, so only the name is validated for
    /// secret entries; regular entries validate both name and value.
    static func partition(_ entries: [HeaderEntry]) -> (regular: [String: String], secretKeys: [String]) {
        var regular: [String: String] = [:]
        var secretKeys: [String] = []
        for entry in entries where !entry.key.isEmpty {
            if entry.isSecret {
                if RemoteProviderService.isSafeHeader(name: entry.key, value: "") {
                    secretKeys.append(entry.key)
                }
            } else if RemoteProviderService.isSafeHeader(name: entry.key, value: entry.value) {
                regular[entry.key] = entry.value
            }
        }
        return (regular, secretKeys)
    }
}

// MARK: - Compact Header Row

private struct CompactHeaderRow: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var themeManager = ThemeManager.shared
    @Binding var header: HeaderEntry
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: theme.space.s8) {
            SettingsTextField(placeholder: L("Key"), text: $header.key, monospaced: true)
                .frame(width: 120)

            SettingsTextField(
                placeholder: L("Value"),
                text: $header.value,
                monospaced: true,
                isSecure: header.isSecret
            )

            SettingsIconButton(
                header.isSecret ? "lock.fill" : "lock.open",
                help: header.isSecret ? "This value is stored securely" : "Click to make this a secret value",
                size: .compact,
                isActive: header.isSecret
            ) {
                header.isSecret.toggle()
            }

            SettingsIconButton("xmark", help: "Remove", size: .compact, action: onDelete)
        }
    }
}

// MARK: - Deployment Names Editor

private struct DeploymentNamesEditor: View {
    @Binding var text: String
    let title: String
    let placeholder: String
    let theme: ThemeProtocol

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            Text(LocalizedStringKey(title), bundle: .module)
                .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                .foregroundColor(theme.text.tertiary)

            SettingsTextEditor(text: $text, placeholder: placeholder, minHeight: 82, monospaced: true)
        }
        .padding(theme.space.s16)
        .settingsChrome(.card)
    }
}

// MARK: - Preview

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        RemoteProviderEditSheet(provider: nil) { _, _, _ in }
            .environment(\.theme, CustomizableTheme.dark())
    }
#endif
