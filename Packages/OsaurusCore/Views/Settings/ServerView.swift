//
//  ServerView.swift
//  osaurus
//
//  Developer tools and API reference for building with Osaurus.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Server Tab

/// Drill-in pages of Developer Tools → Server. Raw values are stable ids;
/// `overview` is the page itself.
enum ServerTab: String, CaseIterable, SettingsDrillInItem {
    case overview = "Overview"
    case models = "Models"
    case settings = "Settings"
    case apiReference = "API Reference"

    var id: String { rawValue }

    static let drillInItems: [ServerTab] = [.settings, .models, .apiReference]

    var title: String {
        switch self {
        case .overview: return L("Overview")
        case .models: return L("Exposed Models")
        case .settings: return L("Server Settings")
        case .apiReference: return L("API Reference")
        }
    }

    var icon: String {
        switch self {
        case .overview: return "server.rack"
        case .models: return "cube.box"
        case .settings: return "slider.horizontal.3"
        case .apiReference: return "book.closed"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return ""
        case .models: return L("Which models the HTTP API lists and serves.")
        case .settings: return L("Connection, sampling defaults, cache, concurrency, memory safety and more.")
        case .apiReference: return L("Every endpoint, with copyable examples.")
        }
    }
}

// MARK: - Cached Formatters

private let sharedMediumDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    return f
}()

private nonisolated(unsafe) let sharedByteCountFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f
}()

// MARK: - ServerView

struct ServerView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var managementState = ManagementStateManager.shared
    @EnvironmentObject var server: ServerController

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var selection: ServerTab?
    @State private var searchText: String = ""

    /// A settings-search result targeting a Server section opens Server
    /// Settings (the inner section scroll + glow is handled by the content).
    private func focusSettingsIfRequested() {
        if managementState.serverSectionRequest != nil {
            selection = .settings
        }
    }

    var body: some View {
        SettingsDrillInHost(rootTitle: L("Server"), selection: $selection) {
            SettingsPage {
                SettingsPageHeader(title: "Server", subtitle: "Local API server, exposed models and API reference")
            } content: {
                OverviewTabContent(onSelect: { selection = $0 })
            }
        } detail: { item in
            detail(item)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.canvas)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear(perform: focusSettingsIfRequested)
        .onChange(of: managementState.serverSectionRequest) { _, _ in
            focusSettingsIfRequested()
        }
        .onChange(of: selection) { _, _ in searchText = "" }
    }

    @ViewBuilder
    private func detail(_ item: ServerTab) -> some View {
        VStack(spacing: theme.space.s0) {
            SettingsPageHeader(
                title: item.title,
                subtitle: item.subtitle,
                toolbar: {
                    if item == .models || item == .apiReference {
                        SettingsHeaderToolbar(
                            searchText: $searchText,
                            searchPlaceholder: item == .models ? "Search models" : "Search endpoints"
                        )
                    }
                }
            )
            switch item {
            case .overview, .settings:
                ServerSettingsTabContent()
            case .models:
                ServerModelsTabContent(searchText: searchText)
            case .apiReference:
                APIReferenceTabContent(searchText: searchText)
            }
        }
    }
}

// MARK: - Overview Tab Content

private struct OverviewTabContent: View {
    let onSelect: (ServerTab) -> Void

    var body: some View {
        ServerStatusCard()
        SettingsDrillInList(items: ServerTab.drillInItems, onSelect: onSelect)
        AccessKeysSection()
        LocalRouterSpendSection()
        CommandLineToolSection()
        CodexCLISetupSection()
        SettingsSection(title: "Remote Access") {
            SettingsLinkRow(
                title: "Remote Access and Model Sharing",
                description: "Public addresses for your agents, guests, and whether peers may use your models are in Sharing → Access.",
                actionTitle: "Open Access"
            ) {
                ManagementStateManager.shared.selectedTab = .access
            }
        }
        #if DEBUG
            SettingsKitGallerySection()
        #endif
    }
}

// MARK: - Key-less local Router spend

/// Opt-in for key-less loopback Router spend. Off by default so a local
/// process can't spend credits through the unauthenticated loopback API;
/// callers with a valid access key are always allowed regardless.
private struct LocalRouterSpendSection: View {
    @Environment(\.theme) private var theme
    @State private var isEnabled = OsaurusRouter.allowsUnkeyedLoopbackSpend

    var body: some View {
        SettingsSection(title: "Osaurus Router") {
            SettingsToggle(
                title: "Allow local API access without a key",
                description:
                    "Lets local processes route requests through the Osaurus Router (spending credits) via the HTTP API without an access key. Keep this off unless you trust every process on this Mac.",
                anchorId: "server.localRouterSpend",
                isOn: $isEnabled
            )
        }
        .onChange(of: isEnabled) { _, newValue in
            OsaurusRouter.setAllowsUnkeyedLoopbackSpend(newValue)
        }
        .onAppear { isEnabled = OsaurusRouter.allowsUnkeyedLoopbackSpend }
    }
}

// MARK: - Server Status Card

private struct ServerStatusCard: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject var server: ServerController

    private var serverURL: String {
        "http://\(server.localNetworkAddress):\(server.port)"
    }

    var body: some View {
        SettingsStatusHero(
            title: "Status",
            icon: "antenna.radiowaves.left.and.right",
            valueLabel: "Server URL",
            value: serverURL
        ) {
            ServerStatusBadge(health: server.serverHealth)
        } actions: {
            if !server.isRunning && server.serverHealth == .stopped {
                SettingsButton(.primary, "Start Server", icon: "play.fill") {
                    Task { await server.startServer() }
                }
            }
        }
    }
}

// MARK: - Access Keys Section

private struct AccessKeysSection: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject var server: ServerController

    @State private var accessKeys: [AccessKeyInfo] = []
    /// Ids of access keys that look like pre-#950 pair-issued credentials —
    /// master-scoped + never-expiring + labelled by the old pair flow.
    /// These grant access to every agent and never expire; we surface a
    /// "Legacy" pill so users can choose to revoke and re-pair.
    @State private var legacyKeyIds: Set<UUID> = []
    @State private var showingKeyGenerator = false
    @State private var newKeyLabel = ""
    @State private var newKeyExpiration: AccessKeyExpiration = .days90
    @State private var generatedKey: String?
    @State private var isGeneratingKey = false
    @State private var keyGenError: String?
    @State private var accessKeyError: String?
    @State private var didLoadAccessKeys = false

    var body: some View {
        SettingsSection(title: "Access Keys", subtitle: accessKeySummaryKey, layout: .plain) {
            SettingsIconButton("arrow.clockwise", help: "Refresh", size: .compact) {
                Task { await reloadAccessKeys(readKeychain: true) }
            }
            SettingsButton(.primary, "Generate Key", icon: "plus", size: .compact) {
                showingKeyGenerator = true
            }
        } content: {
            if let generatedKey {
                generatedKeyBanner(key: generatedKey)
            }

            if let accessKeyError {
                InlineBanner(kind: .error, title: accessKeyError)
            }

            if accessKeys.isEmpty {
                SettingsEmptyState(
                    inline: "lock.shield.fill",
                    title: "Server is locked",
                    hint: didLoadAccessKeys
                        ? emptyAccessKeyMessageKey
                        : "Access key metadata is loaded on demand so startup never reads Keychain. Refresh to inspect existing keys."
                )
            } else {
                SettingsGroup {
                    ForEach(accessKeys) { key in
                        accessKeyRow(key)
                    }
                }
            }
        }
        .sheet(isPresented: $showingKeyGenerator) {
            AccessKeyGeneratorSheet(
                theme: theme,
                label: $newKeyLabel,
                expiration: $newKeyExpiration,
                isGenerating: $isGeneratingKey,
                error: $keyGenError,
                onGenerate: generateAccessKey,
                onCancel: {
                    showingKeyGenerator = false
                    newKeyLabel = ""
                    keyGenError = nil
                }
            )
        }
    }

    private func generatedKeyBanner(key: String) -> some View {
        SettingsCallout(
            icon: "exclamationmark.triangle.fill",
            title: "Copy this key now. It won't be shown again.",
            message: "Anyone with this key can call the API.",
            tone: .warning
        ) {
            SettingsCodeBlock(code: key, wraps: false)
            SettingsButton(.secondary, "Dismiss", size: .compact) { withAnimation { generatedKey = nil } }
        }
    }

    private var accessKeySummaryKey: String {
        server.configuration.exposeToNetwork
            ? "Network and relay callers must present an access key. Local loopback bypass is disabled while network exposure is on."
            : "Localhost clients can call the API without a real key. Create access keys for LAN, relay, or clients that require a Bearer value."
    }

    private var emptyAccessKeyMessageKey: String {
        server.configuration.exposeToNetwork
            ? "Network and relay callers are restricted until you create an access key."
            : "No keys are stored. Localhost still works without a real token while network exposure is off."
    }

    private func accessKeyRow(_ key: AccessKeyInfo) -> some View {
        let isLegacy = legacyKeyIds.contains(key.id)
        return LibraryRow(
            title: key.label,
            subtitle: accessKeySubtitle(key, isLegacy: isLegacy),
            leading: {
                SettingsIconTile(icon: "key.fill", tint: key.isActive ? nil : theme.text.tertiary)
            },
            badges: {
                if key.revoked {
                    keyBadge("Revoked", color: theme.status.error.foreground)
                } else if key.isExpired {
                    keyBadge("Expired", color: theme.status.warning.foreground)
                } else {
                    keyBadge("Active", color: theme.status.success.foreground)
                }
                if isLegacy {
                    keyBadge("Legacy", color: theme.status.warning.foreground)
                } else if key.aud == key.iss {
                    keyBadge("All Agents", color: theme.action.primary.default.background)
                }
            },
            trailing: {
                if !key.revoked {
                    SettingsButton(.destructive, "Revoke", size: .compact) {
                        revokeAccessKey(key.id)
                    }
                }
            }
        )
    }

    private func accessKeySubtitle(_ key: AccessKeyInfo, isLegacy: Bool) -> String {
        var parts = [
            key.prefix + "...",
            String(format: L("Created %@"), sharedMediumDateFormatter.string(from: key.createdAt)),
        ]
        if let expiresAt = key.expiresAt {
            let date = sharedMediumDateFormatter.string(from: expiresAt)
            parts.append(String(format: key.isExpired ? L("Expired %@") : L("Expires %@"), date))
        }
        if isLegacy {
            parts.append(
                L(
                    "Pre-upgrade pairing — grants access to all agents and never expires. Revoke and re-pair to scope it to a single agent."
                )
            )
        }
        return parts.joined(separator: " · ")
    }

    private func keyBadge(_ text: String, color: Color) -> some View {
        StatusChip(text, tint: color)
    }

    private func reloadAccessKeys(readKeychain: Bool = false) async {
        if readKeychain {
            // Keychain reads block on the security daemon over XPC — keep
            // them off the main actor so the UI stays responsive.
            await Task.detached(priority: .userInitiated) {
                APIKeyManager.shared.reload()
            }.value
            didLoadAccessKeys = true
        }
        accessKeys = APIKeyManager.shared.listKeys().sorted { $0.createdAt > $1.createdAt }
        let knownAgentAddrs = Set(
            AgentManager.shared.agents.compactMap { $0.agentAddress }
        )
        // Restrict to pair-issued keys (the old pair flow's label was
        // "Paired – <host>") so a deliberately-generated all-agents key is
        // not mislabelled. Combined with master-scoped + never-expiring,
        // this is the exact pre-#950 pair-issued shape.
        let legacy = APIKeyManager.shared
            .legacyMasterScopedKeys(knownAgentAddresses: knownAgentAddrs)
            .filter { $0.label.hasPrefix("Paired") }
        legacyKeyIds = Set(legacy.map(\.id))
    }

    private func generateAccessKey() {
        let label = newKeyLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }

        isGeneratingKey = true
        keyGenError = nil
        accessKeyError = nil

        let expiration = newKeyExpiration
        Task {
            do {
                // Generation reads the master key and writes metadata to the
                // keychain, both of which block on the security daemon over
                // XPC. Run it off the main actor so the UI stays responsive.
                let result = try await Task.detached(priority: .userInitiated) {
                    try AccessKeyLifecycleService.shared.create(
                        label: label,
                        expiration: expiration
                    )
                }.value
                generatedKey = result.fullKey
                showingKeyGenerator = false
                newKeyLabel = ""
                await reloadAccessKeys()
                restartServerForKeyChange()
            } catch {
                keyGenError = error.localizedDescription
            }

            isGeneratingKey = false
        }
    }

    private func revokeAccessKey(_ id: UUID) {
        accessKeyError = nil
        do {
            try AccessKeyLifecycleService.shared.revokeAndRemove(id: id)
            Task { await reloadAccessKeys(readKeychain: true) }
            restartServerForKeyChange()
        } catch {
            accessKeyError = error.localizedDescription
            Task { await reloadAccessKeys(readKeychain: true) }
        }
    }

    private func restartServerForKeyChange() {
        guard server.isRunning else { return }
        Task { await server.restartServer() }
    }
}

// MARK: - Codex CLI Setup

/// "Use with Codex CLI": generates the `~/.codex` provider + profile config
/// that points OpenAI's Codex CLI at this server, and can write it in place.
///
/// The snippet is derived from the live `ServerController` state on every
/// render, so a port or exposure change is reflected immediately. Writing
/// goes through `CodexCLIConfiguration.write`, which refuses (rather than
/// duplicates) when the user already defines the provider by hand.
private struct CodexCLISetupSection: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject var server: ServerController

    @State private var modelIds: [String] = []
    @State private var hasLoadedModels = false
    @State private var selectedModelId: String = ""
    /// Resolved off-main from the bundle's `config.json`; nil omits
    /// `model_context_window` from the profile.
    @State private var contextWindow: Int?
    @State private var writeStatus: WriteStatus?

    private enum WriteStatus: Equatable {
        case success(configPath: String, profilePath: String, replaced: Bool)
        case failure(String)
    }

    private var codexHome: URL { CodexCLIConfiguration.codexHome() }

    private var snippet: String {
        CodexCLIConfiguration.snippet(
            port: server.port,
            exposeToNetwork: server.configuration.exposeToNetwork,
            modelId: selectedModelId.isEmpty ? "<model>" : selectedModelId,
            contextWindow: contextWindow,
            codexHome: codexHome
        )
    }

    var body: some View {
        SettingsSection(
            title: "Use with Codex CLI",
            subtitle:
                "Run OpenAI's Codex CLI against your local models. Osaurus registers itself as a Codex model provider and adds an `osaurus` profile; nothing else in your Codex config is touched.",
            anchorId: "server.codexCLI",
            layout: .plain
        ) {
            SettingsButton(
                .primary,
                String(format: L("Add to %@"), CodexCLIConfiguration.displayPath(codexHome)),
                icon: "square.and.arrow.down",
                size: .compact,
                verbatim: true,
                help: "Write config.toml and osaurus.config.toml",
                action: writeConfig
            )
            .disabled(selectedModelId.isEmpty)
        } content: {
            SettingsGroup { modelRow }

            SettingsCodeBlock(code: snippet)
                .accessibilityIdentifier("server.codexCLI.snippet")

            if let writeStatus {
                statusView(writeStatus)
            }

            if server.configuration.exposeToNetwork {
                SettingsCallout(
                    icon: "key.fill",
                    title: "Access key required",
                    message: String(
                        format: L(
                            "Network exposure is on, so Codex must send an access key even from this Mac. Create one under Access Keys and export %@ in the shell that runs codex."
                        ),
                        CodexCLIConfiguration.accessKeyEnvironmentVariable
                    ),
                    tone: .warning
                )
            }
        }
        .task { await loadModels() }
        .onChange(of: selectedModelId) { _, newValue in
            writeStatus = nil
            Task { await resolveContextWindow(for: newValue) }
        }
        .onChange(of: server.port) { _, _ in writeStatus = nil }
        .onChange(of: server.configuration.exposeToNetwork) { _, _ in writeStatus = nil }
    }

    private var modelRow: some View {
        SettingsRow(title: "Model", description: contextWindowDescription, verbatimDescription: true) {
            if !hasLoadedModels {
                SettingsSpinner()
            } else if modelIds.isEmpty {
                Text("No local models installed. Download one from the Models manager first.", bundle: .module)
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.tertiary)
            } else {
                SettingsMenuPicker(selection: $selectedModelId) {
                    ForEach(modelIds, id: \.self) { id in
                        Text(id).tag(id)
                    }
                }
                .accessibilityIdentifier("server.codexCLI.model")
            }
        }
    }

    private var contextWindowDescription: String {
        guard let contextWindow else { return "" }
        return String(
            format: L("%@ context"),
            Self.tokenFormatter.string(from: NSNumber(value: contextWindow)) ?? "\(contextWindow)"
        )
    }

    @ViewBuilder
    private func statusView(_ status: WriteStatus) -> some View {
        switch status {
        case .success(let configPath, let profilePath, let replaced):
            InlineBanner(
                kind: .success,
                title: String(
                    format: replaced
                        ? L("Updated %@ and wrote %@. Run `%@`.")
                        : L("Added the provider to %@ and wrote %@. Run `%@`."),
                    configPath, profilePath, CodexCLIConfiguration.usageCommand
                )
            )
            .accessibilityIdentifier("server.codexCLI.status")
        case .failure(let detail):
            InlineBanner(kind: .error, title: detail)
                .accessibilityIdentifier("server.codexCLI.status")
        }
    }

    // MARK: Actions

    private func writeConfig() {
        guard !selectedModelId.isEmpty else { return }
        do {
            let result = try CodexCLIConfiguration.write(
                port: server.port,
                exposeToNetwork: server.configuration.exposeToNetwork,
                modelId: selectedModelId,
                contextWindow: contextWindow,
                codexHome: codexHome
            )
            writeStatus = .success(
                configPath: CodexCLIConfiguration.displayPath(result.configURL),
                profilePath: CodexCLIConfiguration.displayPath(result.profileURL),
                replaced: result.replacedExistingBlock
            )
        } catch {
            writeStatus = .failure(error.localizedDescription)
        }
    }

    // MARK: Loading

    /// Same enumeration as Server → Models: repo slugs deduped
    /// case-insensitively, plus `foundation` when available.
    private func loadModels() async {
        let discovered = await ModelManager.discoverLocalModelsOffMain()
        var seen: Set<String> = []
        var ids: [String] = []
        for model in discovered {
            let slug =
                model.id.split(separator: "/").last.map(String.init)?.lowercased()
                ?? model.id.lowercased()
            guard !seen.contains(slug) else { continue }
            seen.insert(slug)
            ids.append(slug)
        }
        ids.sort()
        if FoundationModelService.isDefaultModelAvailable() {
            ids.insert("foundation", at: 0)
        }
        modelIds = ids
        hasLoadedModels = true
        if selectedModelId.isEmpty || !ids.contains(selectedModelId) {
            // Prefer a real bundle over Foundation, whose 4K window makes a
            // poor Codex default.
            selectedModelId = ids.first(where: { $0 != "foundation" }) ?? ids.first ?? ""
        }
    }

    private func resolveContextWindow(for modelId: String) async {
        guard !modelId.isEmpty else {
            contextWindow = nil
            return
        }
        let resolved: Int? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                // What the server will actually retain, not what the bundle
                // declares: past the KV retention cap the engine rolls the
                // window silently, so that cap is the number Codex must
                // compact against.
                let bundle = ContextSizeResolverBridge.contextLength(modelId: modelId)
                let cap = ServerRuntimeSettingsStore.resolvedKVRetentionCap()
                continuation.resume(
                    returning: CodexCLIConfiguration.effectiveContextWindow(
                        bundleContextLength: bundle, kvRetentionCap: cap))
            }
        }
        guard modelId == selectedModelId else { return }
        contextWindow = resolved
    }

    private static let tokenFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()
}

/// Off-main context-window lookup for the Codex card. `ModelInfo.load` does
/// the cold disk probe that `ContextSizeResolver.resolve` deliberately skips
/// (it runs inside layout); here we're already off the main thread, so the
/// full read is the right call and the result is exact rather than "warming".
private enum ContextSizeResolverBridge {
    static func contextLength(modelId: String) -> Int? {
        if modelId.caseInsensitiveCompare("foundation") == .orderedSame {
            return ContextSizeResolver.resolve(modelId: modelId).contextLength
        }
        return ModelInfo.load(modelId: modelId)?.model.contextLength
    }
}

// MARK: - API Reference Tab Content

private struct APIReferenceTabContent: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject var server: ServerController

    let searchText: String

    @State private var expandedEndpoint: String?
    @State private var editablePayloads: [String: String] = [:]
    @State private var endpointResponses: [String: EndpointTestResult] = [:]
    @State private var loadingEndpoints: Set<String> = []

    private var serverURL: String {
        "http://\(server.localNetworkAddress):\(server.port)"
    }

    /// URL used for the in-panel "Test endpoint" calls. Always points at the
    /// loopback address, even when the server is exposed to the LAN, because
    /// the request is issued from the osaurus UI process on the same machine
    /// and the server's auth gate trusts loopback without a Bearer token
    /// (see `HTTPHandler`'s `isLoopback` check). Using `localNetworkAddress`
    /// here sent self-test requests through the authenticated path, where
    /// the UI has no access key to attach, and the panel failed with
    /// `{"error":{"message":"Invalid access key: Unrecognized token format"}}`
    /// once exposure was enabled (issue #596).
    private var testURL: String {
        "http://127.0.0.1:\(server.port)"
    }

    private var filteredGroups: [(category: APIEndpoint.EndpointCategory, endpoints: [APIEndpoint])] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return APIEndpoint.groupedEndpoints }
        return APIEndpoint.groupedEndpoints.compactMap { group in
            let filtered = group.endpoints.filter {
                $0.path.lowercased().contains(query)
                    || $0.description.lowercased().contains(query)
                    || $0.method.lowercased().contains(query)
                    || ($0.compatibility?.lowercased().contains(query) ?? false)
            }
            guard !filtered.isEmpty else { return nil }
            return (category: group.category, endpoints: filtered)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: theme.space.s24) {
                if !server.isRunning {
                    serverStoppedBanner
                }
                endpointsCard
                documentationSection
            }
            .padding(.horizontal, theme.space.s24)
            .padding(.vertical, theme.space.s24)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Sections

    private var serverStoppedBanner: some View {
        HStack(spacing: theme.space.s10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .glyphSize(.label, weight: .semibold)
                .foregroundColor(theme.status.warning.foreground)
            SettingsRowText(compact: true) {
                Text("Server is not running", bundle: .module)
                    .foregroundColor(theme.status.warning.foreground)
            } description: {
                Text("Start the server from the Overview tab to test endpoints.", bundle: .module)
                    .foregroundColor(theme.text.secondary)
            }
            Spacer()
        }
        .padding(theme.space.s12)
        .settingsChrome(.status(.warning))
    }

    private var endpointsCard: some View {
        VStack(alignment: .leading, spacing: theme.space.s16) {
            Label {
                Text("API Endpoints", bundle: .module)
            } icon: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .textStyle(.label, weight: 600)
            .foregroundColor(theme.text.primary)

            Text("Available endpoints on your Osaurus server. Expand to test directly.", bundle: .module)
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.secondary)

            let groups = filteredGroups

            if groups.isEmpty {
                HStack(spacing: theme.space.s8) {
                    Image(systemName: "magnifyingglass")
                        .glyphSize(.body)
                        .foregroundColor(theme.text.tertiary)
                    Text("No endpoints match \"\(searchText)\"", bundle: .module)
                        .font(SettingsFont.caption)
                        .foregroundColor(theme.text.tertiary)
                }
                .padding(theme.space.s12)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: theme.space.s16) {
                    ForEach(groups, id: \.category.rawValue) { group in
                        endpointCategoryGroup(group)
                    }
                }
            }
        }
        .padding(theme.space.s16)
        .settingsChrome(.inset)
    }

    private func endpointCategoryGroup(
        _ group: (category: APIEndpoint.EndpointCategory, endpoints: [APIEndpoint])
    ) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(spacing: theme.space.s6) {
                Image(systemName: group.category.icon)
                    .glyphSize(.micro, weight: .semibold)
                    .foregroundColor(theme.dataInk(group.category.ink))
                Text(group.category.rawValue)
                    .font(SettingsFont.smallLabel)
                    .foregroundColor(theme.text.secondary)
            }
            .padding(.leading, theme.space.s4)

            VStack(spacing: theme.space.s2) {
                ForEach(group.endpoints, id: \.id) { endpoint in
                    if endpoint.isAudioEndpoint {
                        TranscriptionTestRow(
                            endpoint: endpoint,
                            serverURL: serverURL,
                            isServerRunning: server.isRunning,
                            isExpanded: expandedEndpoint == endpoint.id,
                            isLoading: loadingEndpoints.contains(endpoint.id),
                            response: endpointResponses[endpoint.id],
                            onToggleExpand: { toggleEndpoint(endpoint.id) },
                            onTest: { audioData in
                                runAudioTranscriptionTest(endpoint, audioData: audioData)
                            },
                            onClearResponse: { endpointResponses[endpoint.id] = nil }
                        )
                    } else {
                        EndpointRow(
                            endpoint: endpoint,
                            serverURL: serverURL,
                            isServerRunning: server.isRunning,
                            isExpanded: expandedEndpoint == endpoint.id,
                            isLoading: loadingEndpoints.contains(endpoint.id),
                            editablePayload: binding(for: endpoint),
                            response: endpointResponses[endpoint.id],
                            onToggleExpand: {
                                toggleEndpoint(endpoint.id)
                                if expandedEndpoint == endpoint.id,
                                    editablePayloads[endpoint.id] == nil
                                {
                                    editablePayloads[endpoint.id] = endpoint.examplePayload ?? "{}"
                                }
                            },
                            onTest: { runEndpointTest(endpoint) },
                            onClearResponse: { endpointResponses[endpoint.id] = nil }
                        )
                    }
                }
            }
        }
    }

    private var documentationSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            Label {
                Text("Documentation", bundle: .module)
            } icon: {
                Image(systemName: "book")
            }
            .textStyle(.label, weight: 600)
            .foregroundColor(theme.text.primary)

            Text("Learn how to integrate Osaurus into your applications.", bundle: .module)
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.secondary)

            Button(action: {
                if let url = URL(string: "https://docs.osaurus.ai/") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                HStack(spacing: theme.space.s8) {
                    Image(systemName: "arrow.up.right.square")
                    Text("Open Documentation", bundle: .module)
                }
            }
            .assignedSettingsButtonStyle(.primary)
        }
        .padding(theme.space.s16)
        .settingsChrome(.inset)
    }

    // MARK: - Actions

    private func toggleEndpoint(_ path: String) {
        withAnimation(theme.motion.quick) {
            expandedEndpoint = expandedEndpoint == path ? nil : path
        }
    }

    private func binding(for endpoint: APIEndpoint) -> Binding<String> {
        Binding(
            get: { editablePayloads[endpoint.id] ?? endpoint.examplePayload ?? "{}" },
            set: { editablePayloads[endpoint.id] = $0 }
        )
    }

    private func recordResult(_ endpoint: APIEndpoint, startTime: Date, data: Data, response: URLResponse) {
        let durationMs = Date().timeIntervalSince(startTime) * 1000
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        endpointResponses[endpoint.id] = EndpointTestResult(
            endpoint: endpoint,
            statusCode: statusCode,
            body: data,
            duration: durationMs / 1000,
            error: nil
        )
        loadingEndpoints.remove(endpoint.id)
    }

    private func recordError(_ endpoint: APIEndpoint, startTime: Date, error: Error) {
        let durationMs = Date().timeIntervalSince(startTime) * 1000
        endpointResponses[endpoint.id] = EndpointTestResult(
            endpoint: endpoint,
            statusCode: 0,
            body: Data(),
            duration: durationMs / 1000,
            error: error.localizedDescription
        )
        loadingEndpoints.remove(endpoint.id)
    }

    private func runEndpointTest(_ endpoint: APIEndpoint) {
        guard server.isRunning, !endpoint.hasPathParameters else { return }

        withAnimation(theme.motion.quick) {
            expandedEndpoint = endpoint.id
            loadingEndpoints.insert(endpoint.id)
        }

        if editablePayloads[endpoint.id] == nil {
            editablePayloads[endpoint.id] = endpoint.examplePayload ?? "{}"
        }

        let payload = editablePayloads[endpoint.id] ?? endpoint.examplePayload ?? "{}"

        Task {
            let startTime = Date()
            do {
                let url = URL(string: "\(testURL)\(endpoint.path)")!
                let data: Data
                let response: URLResponse

                if endpoint.method == "POST" {
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = payload.data(using: .utf8)
                    (data, response) = try await URLSession.shared.data(for: request)
                } else if endpoint.method == "DELETE" {
                    var request = URLRequest(url: url)
                    request.httpMethod = "DELETE"
                    (data, response) = try await URLSession.shared.data(for: request)
                } else {
                    (data, response) = try await URLSession.shared.data(from: url)
                }

                await MainActor.run { recordResult(endpoint, startTime: startTime, data: data, response: response) }
            } catch {
                await MainActor.run { recordError(endpoint, startTime: startTime, error: error) }
            }
        }
    }

    private func runAudioTranscriptionTest(_ endpoint: APIEndpoint, audioData: Data) {
        guard server.isRunning else { return }

        let modelId = SpeechModelManager.shared.selectedModel?.id ?? "parakeet-v3"

        withAnimation(theme.motion.quick) {
            expandedEndpoint = endpoint.path
            loadingEndpoints.insert(endpoint.path)
        }

        Task {
            let startTime = Date()
            do {
                let url = URL(string: "\(testURL)\(endpoint.path)")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"

                let boundary = "Boundary-\(UUID().uuidString)"
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

                var body = Data()
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append(
                    "Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\n".data(using: .utf8)!
                )
                body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
                body.append(audioData)
                body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
                body.append(modelId.data(using: .utf8)!)
                body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
                request.httpBody = body

                let (data, response) = try await URLSession.shared.data(for: request)
                await MainActor.run { recordResult(endpoint, startTime: startTime, data: data, response: response) }
            } catch {
                await MainActor.run { recordError(endpoint, startTime: startTime, error: error) }
            }
        }
    }
}

// MARK: - API Endpoint Model

struct APIEndpoint {
    let method: String
    let path: String
    let description: String
    let compatibility: String?
    let category: EndpointCategory
    let examplePayload: String?
    let isAudioEndpoint: Bool

    var id: String { "\(method) \(path)" }
    var hasPathParameters: Bool { path.contains("{") }

    init(
        method: String,
        path: String,
        description: String,
        compatibility: String?,
        category: EndpointCategory,
        examplePayload: String?,
        isAudioEndpoint: Bool = false
    ) {
        self.method = method
        self.path = path
        self.description = description
        self.compatibility = compatibility
        self.category = category
        self.examplePayload = examplePayload
        self.isAudioEndpoint = isAudioEndpoint
    }

    enum EndpointCategory: String {
        case core = "Core"
        case chat = "Chat"
        case embeddings = "Embeddings"
        case audio = "Audio"
        case memory = "Memory"
        case agents = "Agents"
        case mcp = "MCP"

        var icon: String {
            switch self {
            case .core: return "server.rack"
            case .chat: return "bubble.left.and.bubble.right"
            case .embeddings: return "text.viewfinder"
            case .audio: return "waveform"
            case .memory: return "brain.head.profile"
            case .agents: return "person.2"
            case .mcp: return "wrench.and.screwdriver"
            }
        }

        var ink: DataInk {
            switch self {
            case .core: return .blue
            case .chat: return .green
            case .embeddings: return .cyan
            case .audio: return .orange
            case .memory: return .pink
            case .agents: return .indigo
            case .mcp: return .purple
            }
        }
    }

    private static let _defaultExampleModel: String = {
        if FoundationModelService.isDefaultModelAvailable() {
            return "foundation"
        }
        if let first = ModelManager.discoverLocalModels().first {
            return first.id
        }
        return "your-model-name"
    }()

    static let allEndpoints: [APIEndpoint] = {
        let model = _defaultExampleModel
        return [
            APIEndpoint(
                method: "GET",
                path: "/",
                description: L("Root endpoint - server status message"),
                compatibility: nil,
                category: .core,
                examplePayload: nil
            ),
            APIEndpoint(
                method: "GET",
                path: "/health",
                description: L("Health check endpoint"),
                compatibility: nil,
                category: .core,
                examplePayload: nil
            ),
            APIEndpoint(
                method: "GET",
                path: "/models",
                description: L("List available models"),
                compatibility: "OpenAI",
                category: .core,
                examplePayload: nil
            ),
            APIEndpoint(
                method: "GET",
                path: "/tags",
                description: L("List available models"),
                compatibility: "Ollama",
                category: .core,
                examplePayload: nil
            ),
            APIEndpoint(
                method: "POST",
                path: "/show",
                description: L("Show model metadata"),
                compatibility: "Ollama",
                category: .core,
                examplePayload: "{\n  \"name\": \"\(model)\"\n}"
            ),
            APIEndpoint(
                method: "POST",
                path: "/chat/completions",
                description: L("Chat completions with streaming support"),
                compatibility: "OpenAI",
                category: .chat,
                examplePayload: """
                    {
                      "model": "\(model)",
                      "messages": [
                        {"role": "user", "content": "Hello!"}
                      ],
                      "stream": false
                    }
                    """
            ),
            APIEndpoint(
                method: "POST",
                path: "/chat",
                description: L("Chat endpoint (NDJSON streaming)"),
                compatibility: "Ollama",
                category: .chat,
                examplePayload: """
                    {
                      "model": "\(model)",
                      "messages": [
                        {"role": "user", "content": "Hello!"}
                      ]
                    }
                    """
            ),
            APIEndpoint(
                method: "POST",
                path: "/messages",
                description: L("Messages endpoint with streaming support"),
                compatibility: "Anthropic",
                category: .chat,
                examplePayload: """
                    {
                      "model": "\(model)",
                      "max_tokens": 1024,
                      "messages": [
                        {"role": "user", "content": "Hello, Claude!"}
                      ],
                      "stream": false
                    }
                    """
            ),
            APIEndpoint(
                method: "POST",
                path: "/v1/responses",
                description: L("Responses endpoint with streaming support"),
                compatibility: "Open Responses",
                category: .chat,
                examplePayload: """
                    {
                      "model": "\(model)",
                      "input": "Hello!",
                      "stream": false
                    }
                    """
            ),
            APIEndpoint(
                method: "POST",
                path: "/embeddings",
                description: L("Generate text embeddings"),
                compatibility: "OpenAI",
                category: .embeddings,
                examplePayload: "{\n  \"model\": \"\(EmbeddingService.modelName)\",\n  \"input\": \"Hello world\"\n}"
            ),
            APIEndpoint(
                method: "POST",
                path: "/embed",
                description: L("Generate text embeddings"),
                compatibility: "Ollama",
                category: .embeddings,
                examplePayload: "{\n  \"model\": \"\(EmbeddingService.modelName)\",\n  \"input\": \"Hello world\"\n}"
            ),
            APIEndpoint(
                method: "POST",
                path: "/audio/transcriptions",
                description: L("Transcribe audio to text"),
                compatibility: "OpenAI",
                category: .audio,
                examplePayload: nil,
                isAudioEndpoint: true
            ),
            APIEndpoint(
                method: "GET",
                path: "/agents",
                description: L("List all agents with memory counts"),
                compatibility: "Osaurus",
                category: .memory,
                examplePayload: nil
            ),
            APIEndpoint(
                method: "GET",
                path: "/agents/{id}",
                description: L("Return info for a single agent"),
                compatibility: "Osaurus",
                category: .agents,
                examplePayload: nil
            ),
            APIEndpoint(
                method: "POST",
                path: "/memory/ingest",
                description: L("Bulk-ingest conversation turns into memory"),
                compatibility: "Osaurus",
                category: .memory,
                examplePayload: """
                    {
                      "agent_id": "my-agent",
                      "conversation_id": "session-1",
                      "turns": [
                        {"user": "Hi, my name is Alice", "assistant": "Hello Alice!"}
                      ]
                    }
                    """
            ),
            APIEndpoint(
                method: "GET",
                path: "/mcp/health",
                description: L("MCP server health check"),
                compatibility: "MCP",
                category: .mcp,
                examplePayload: nil
            ),
            APIEndpoint(
                method: "GET",
                path: "/mcp/tools",
                description: L("List available tools"),
                compatibility: "MCP",
                category: .mcp,
                examplePayload: nil
            ),
            APIEndpoint(
                method: "POST",
                path: "/mcp/call",
                description: L("Execute a tool by name"),
                compatibility: "MCP",
                category: .mcp,
                examplePayload: "{\n  \"name\": \"example_tool\",\n  \"arguments\": {}\n}"
            ),
            APIEndpoint(
                method: "POST",
                path: "/agents/{id}/run",
                description: L("Run the full agent chat loop server-side, streaming SSE text deltas"),
                compatibility: "Osaurus",
                category: .agents,
                examplePayload: """
                    {
                      "model": "default",
                      "messages": [
                        {"role": "user", "content": "Summarize the repo"}
                      ],
                      "stream": true
                    }
                    """
            ),
            APIEndpoint(
                method: "POST",
                path: "/agents/{identifier}/dispatch",
                description: L("Dispatch a work or chat task to an agent"),
                compatibility: "Osaurus",
                category: .agents,
                examplePayload: """
                    {
                      "prompt": "Summarize the latest changes",
                      "mode": "work",
                      "title": "Summary task"
                    }
                    """
            ),
            APIEndpoint(
                method: "GET",
                path: "/tasks/{task_id}",
                description: L("Poll task status and activity"),
                compatibility: "Osaurus",
                category: .agents,
                examplePayload: nil
            ),
            APIEndpoint(
                method: "DELETE",
                path: "/tasks/{task_id}",
                description: L("Cancel a running task"),
                compatibility: "Osaurus",
                category: .agents,
                examplePayload: nil
            ),
            APIEndpoint(
                method: "POST",
                path: "/tasks/{task_id}/clarify",
                description: L("Submit a clarification response to a waiting task"),
                compatibility: "Osaurus",
                category: .agents,
                examplePayload: "{\n  \"response\": \"Yes, proceed with the changes\"\n}"
            ),
        ]
    }()

    static let groupedEndpoints: [(category: EndpointCategory, endpoints: [APIEndpoint])] = {
        let categories: [EndpointCategory] = [.core, .chat, .embeddings, .audio, .memory, .agents, .mcp]
        return categories.map { cat in
            (category: cat, endpoints: allEndpoints.filter { $0.category == cat })
        }
    }()
}

// MARK: - Endpoint Test Result

struct EndpointTestResult: Equatable {
    let endpoint: APIEndpoint
    let statusCode: Int
    let body: Data
    let duration: TimeInterval
    let error: String?

    var isSuccess: Bool { statusCode >= 200 && statusCode < 300 }

    var formattedBody: String {
        if let error { return "Error: \(error)" }
        if let json = try? JSONSerialization.jsonObject(with: body, options: []),
            let prettyData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
            let prettyString = String(data: prettyData, encoding: .utf8)
        {
            return prettyString
        }
        return String(data: body, encoding: .utf8) ?? "(Unable to decode response)"
    }

    static func == (lhs: EndpointTestResult, rhs: EndpointTestResult) -> Bool {
        lhs.endpoint.path == rhs.endpoint.path && lhs.statusCode == rhs.statusCode && lhs.duration == rhs.duration
    }
}

extension APIEndpoint: Equatable {
    static func == (lhs: APIEndpoint, rhs: APIEndpoint) -> Bool {
        lhs.path == rhs.path && lhs.method == rhs.method
    }
}

// MARK: - Server Status Badge

private struct ServerStatusBadge: View {
    @Environment(\.theme) private var theme
    let health: ServerHealth

    var body: some View {
        StatusChip(health.statusDescription, tint: statusColor, showsDot: true)
    }

    private var statusColor: Color {
        switch health {
        case .running: return theme.status.success.foreground
        case .stopped: return theme.text.tertiary
        case .starting, .restarting, .stopping: return theme.status.warning.foreground
        case .error: return theme.status.error.foreground
        }
    }
}

// MARK: - Shared Endpoint Row Header

private struct EndpointRowHeader: View {
    @Environment(\.theme) private var theme

    let endpoint: APIEndpoint
    let isServerRunning: Bool
    let isExpanded: Bool
    let isLoading: Bool
    let response: EndpointTestResult?
    let onToggleExpand: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: {
            if isServerRunning { onToggleExpand() }
        }) {
            HStack(spacing: theme.space.s12) {
                Text(endpoint.method)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(methodColor)
                    .padding(.horizontal, theme.space.s8)
                    .padding(.vertical, theme.space.s4)
                    .background(
                        RoundedRectangle(cornerRadius: theme.radius.small)
                            .fill(DataInk.httpMethod(endpoint.method).map(theme.dataWash) ?? theme.surface.hover)
                    )
                    .frame(width: 58)

                Text(endpoint.path)
                    .font(SettingsFont.mono)
                    .foregroundColor(theme.text.primary)

                if let compat = endpoint.compatibility {
                    Text(compat)
                        .font(SettingsFont.chip)
                        .foregroundColor(compatColor(compat))
                        .padding(.horizontal, theme.space.s6)
                        .padding(.vertical, theme.space.s2)
                        .background(
                            RoundedRectangle(cornerRadius: theme.radius.small)
                                .fill(compatWash(compat))
                        )
                }

                Spacer()

                Text(endpoint.description)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                    .lineLimit(1)

                if isLoading {
                    SettingsSpinner()
                } else if let resp = response {
                    StatusChip("\(resp.statusCode)", tone: resp.isSuccess ? .success : .error)
                }

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .glyphSize(.micro, weight: .semibold)
                    .foregroundColor(theme.text.tertiary)
            }
            .padding(.horizontal, theme.space.s12)
            .padding(.vertical, theme.space.s8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!isServerRunning)
        .settingsChrome(isHovering || isExpanded ? .hover : nil)
        .onHover { hovering in
            withAnimation(theme.motion.quick) { isHovering = hovering }
        }
    }

    private var methodColor: Color {
        DataInk.httpMethod(endpoint.method).map(theme.dataInk) ?? theme.text.tertiary
    }

    private func compatColor(_ compat: String) -> Color {
        switch compat {
        case "OpenAI": return theme.dataInk(.green)
        case "Ollama": return theme.dataInk(.orange)
        case "MCP": return theme.dataInk(.purple)
        default: return theme.action.primary.default.background
        }
    }

    private func compatWash(_ compat: String) -> Color {
        switch compat {
        case "OpenAI": return theme.dataWash(.green)
        case "Ollama": return theme.dataWash(.orange)
        case "MCP": return theme.dataWash(.purple)
        default: return theme.surface.hover
        }
    }
}

// MARK: - Shared Response Panel

private struct ResponsePanel: View {
    @Environment(\.theme) private var theme

    let isLoading: Bool
    let response: EndpointTestResult?
    let emptyMessage: String
    let onClearResponse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack {
                Label {
                    Text("Response", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.down.circle.fill")
                }
                .textStyle(.footnote, weight: 600)
                .foregroundColor(theme.text.secondary)

                Spacer()

                if let resp = response {
                    Text(String(format: "%.0fms", resp.duration * 1000))
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.tertiary)

                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(resp.formattedBody, forType: .string)
                    }) {
                        Image(systemName: "doc.on.doc")
                            .glyphSize(.micro)
                            .foregroundColor(theme.text.tertiary)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .localizedHelp("Copy response")

                    SettingsIconButton("xmark", help: "Clear response", size: .compact, action: onClearResponse)
                }
            }

            if isLoading {
                VStack {
                    SettingsSpinner(size: .large)
                    Text("Waiting for response...", bundle: .module)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .settingsChrome(.inset)
            } else if let resp = response {
                ScrollView {
                    Text(resp.formattedBody)
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(resp.isSuccess ? theme.text.primary : theme.status.error.foreground)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(theme.space.s8)
                }
                .frame(minHeight: 120, maxHeight: 200)
                .settingsChrome(.subtle)
            } else {
                VStack(spacing: theme.space.s8) {
                    Image(systemName: "arrow.left.circle")
                        .glyphSize(.xxlarge)
                        .foregroundColor(theme.text.tertiary)
                    Text(emptyMessage)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .settingsChrome(.inset)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Endpoint Row

private struct EndpointRow: View {
    @Environment(\.theme) private var theme

    let endpoint: APIEndpoint
    let serverURL: String
    let isServerRunning: Bool
    let isExpanded: Bool
    let isLoading: Bool
    @Binding var editablePayload: String
    let response: EndpointTestResult?
    let onToggleExpand: () -> Void
    let onTest: () -> Void
    let onClearResponse: () -> Void

    var body: some View {
        VStack(spacing: theme.space.s0) {
            EndpointRowHeader(
                endpoint: endpoint,
                isServerRunning: isServerRunning,
                isExpanded: isExpanded,
                isLoading: isLoading,
                response: response,
                onToggleExpand: onToggleExpand
            )

            if isExpanded {
                VStack(spacing: theme.space.s0) {
                    Divider().background(theme.border.subtle)

                    HStack(alignment: .top, spacing: theme.space.s16) {
                        requestPanel
                        ThemeHairlineDivider(axis: .vertical)
                        ResponsePanel(
                            isLoading: isLoading,
                            response: response,
                            emptyMessage: endpoint.hasPathParameters
                                ? L("Test with curl or your HTTP client")
                                : L("Click 'Send Request' to test"),
                            onClearResponse: onClearResponse
                        )
                    }
                    .padding(theme.space.s16)
                }
                .background(theme.surface.hover)
                .clipShape(RoundedRectangle(cornerRadius: theme.radius.medium))
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .settingsChrome(isExpanded ? .surface : nil)
        .animation(theme.motion.quick, value: isExpanded)
    }

    private var requestPanel: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack {
                Label {
                    Text("Request", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.up.circle.fill")
                }
                .textStyle(.footnote, weight: 600)
                .foregroundColor(theme.text.secondary)
                Spacer()
                if endpoint.examplePayload != nil, !endpoint.hasPathParameters {
                    Button(action: { editablePayload = endpoint.examplePayload ?? "{}" }) {
                        Text("Reset", bundle: .module)
                            .font(SettingsFont.chip)
                            .foregroundColor(theme.text.tertiary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }

            if endpoint.hasPathParameters {
                VStack(alignment: .leading, spacing: theme.space.s6) {
                    Text("\(endpoint.method) \(serverURL)\(endpoint.path)", bundle: .module)
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.primary)
                        .textSelection(.enabled)

                    if let payload = endpoint.examplePayload {
                        Text(payload)
                            .font(SettingsFont.monoSmall)
                            .foregroundColor(theme.text.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(theme.space.s12)
                .settingsChrome(.inset)

                HStack(spacing: theme.space.s6) {
                    Image(systemName: "info.circle")
                        .glyphSize(.micro)
                    Text(
                        "Replace path parameters with real values. Test via curl or your HTTP client.",
                        bundle: .module
                    )
                    .font(SettingsFont.footnote)
                }
                .foregroundColor(theme.text.tertiary)
            } else if endpoint.examplePayload != nil {
                SettingsTextEditor(text: $editablePayload, minHeight: 120, maxHeight: 200, monospaced: true)
            } else {
                Text("\(endpoint.method) \(serverURL)\(endpoint.path)", bundle: .module)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(theme.space.s12)
                    .settingsChrome(.inset)
            }

            if !endpoint.hasPathParameters {
                Button(action: onTest) {
                    HStack(spacing: theme.space.s6) {
                        if isLoading {
                            SettingsSpinner()
                        } else {
                            Image(systemName: "paperplane.fill").glyphSize(.micro)
                        }
                        Text(LocalizedStringKey(isLoading ? "Sending..." : "Send Request"), bundle: .module)
                            .font(SettingsFont.smallLabel)
                    }
                    .frame(maxWidth: .infinity)
                }
                .assignedSettingsButtonStyle(.primary)
                .disabled(isLoading)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Transcription Test Row

private struct TranscriptionTestRow: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var speechModelManager = SpeechModelManager.shared

    let endpoint: APIEndpoint
    let serverURL: String
    let isServerRunning: Bool
    let isExpanded: Bool
    let isLoading: Bool
    let response: EndpointTestResult?
    let onToggleExpand: () -> Void
    let onTest: (Data) -> Void
    let onClearResponse: () -> Void

    @State private var selectedFileURL: URL?
    @State private var selectedFileName: String?
    @State private var audioData: Data?
    @State private var fileError: String?

    var body: some View {
        VStack(spacing: theme.space.s0) {
            EndpointRowHeader(
                endpoint: endpoint,
                isServerRunning: isServerRunning,
                isExpanded: isExpanded,
                isLoading: isLoading,
                response: response,
                onToggleExpand: onToggleExpand
            )

            if isExpanded {
                VStack(spacing: theme.space.s0) {
                    Divider().background(theme.border.subtle)

                    HStack(alignment: .top, spacing: theme.space.s16) {
                        requestPanel
                        ThemeHairlineDivider(axis: .vertical)
                        ResponsePanel(
                            isLoading: isLoading,
                            response: response,
                            emptyMessage: "Select an audio file and send to see transcription",
                            onClearResponse: onClearResponse
                        )
                    }
                    .padding(theme.space.s16)
                }
                .background(theme.surface.hover)
                .clipShape(RoundedRectangle(cornerRadius: theme.radius.medium))
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .settingsChrome(isExpanded ? .surface : nil)
        .animation(theme.motion.quick, value: isExpanded)
    }

    private var requestPanel: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            Label {
                Text("Request", bundle: .module)
            } icon: {
                Image(systemName: "arrow.up.circle.fill")
            }
            .textStyle(.footnote, weight: 600)
            .foregroundColor(theme.text.secondary)

            VStack(alignment: .leading, spacing: theme.space.s6) {
                Text("Model", bundle: .module)
                    .font(SettingsFont.chip)
                    .foregroundColor(theme.text.tertiary)

                HStack(spacing: theme.space.s8) {
                    Image(systemName: "waveform")
                        .glyphSize(.caption)
                        .foregroundColor(theme.status.warning.foreground)

                    if let model = speechModelManager.selectedModel {
                        Text(model.name)
                            .font(SettingsFont.compactLabel)
                            .foregroundColor(theme.text.primary)
                    } else {
                        Text("No model selected", bundle: .module)
                            .font(SettingsFont.compactLabel)
                            .foregroundColor(theme.text.tertiary)
                            .italic()
                    }
                }
                .padding(.horizontal, theme.space.s12)
                .padding(.vertical, theme.space.s8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsChrome(.control)
            }

            audioFileField

            HStack(spacing: theme.space.s8) {
                Button(action: selectFile) {
                    HStack(spacing: theme.space.s6) {
                        Image(systemName: "folder").glyphSize(.micro)
                        Text("Choose File", bundle: .module).font(SettingsFont.smallLabel)
                    }
                    .foregroundColor(theme.text.secondary)
                    .padding(.horizontal, theme.space.s12)
                    .padding(.vertical, theme.space.s8)
                    .settingsChrome(.inset)
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: { if let data = audioData { onTest(data) } }) {
                    HStack(spacing: theme.space.s6) {
                        if isLoading {
                            SettingsSpinner(size: .mini)
                        } else {
                            Image(systemName: "paperplane.fill").glyphSize(.micro)
                        }
                        Text(LocalizedStringKey(isLoading ? "Sending..." : "Send Request"), bundle: .module)
                            .font(SettingsFont.smallLabel)
                    }
                    .frame(maxWidth: .infinity, minHeight: 18)
                }
                .assignedSettingsButtonStyle(.primary)
                .disabled(audioData == nil || isLoading)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var audioFileField: some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            Text("Audio File", bundle: .module)
                .font(SettingsFont.chip)
                .foregroundColor(theme.text.tertiary)

            if let fileName = selectedFileName {
                HStack(spacing: theme.space.s10) {
                    Image(systemName: "waveform")
                        .glyphSize(.caption)
                        .foregroundColor(theme.text.link)
                    Text(fileName)
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(1)
                    if let data = audioData {
                        Text("(\(sharedByteCountFormatter.string(fromByteCount: Int64(data.count))))", bundle: .module)
                            .font(SettingsFont.rowDescription)
                            .foregroundColor(theme.text.tertiary)
                    }
                    Spacer()
                    SettingsIconButton("xmark", help: "Remove file", size: .compact, action: clearFile)
                }
                .padding(.horizontal, theme.space.s12)
                .padding(.vertical, theme.space.s8)
                .settingsChrome(.control)
            } else {
                HStack(spacing: theme.space.s8) {
                    Image(systemName: "doc.badge.plus")
                        .glyphSize(.caption)
                        .foregroundColor(theme.text.tertiary)
                    Text("No file selected", bundle: .module)
                        .font(SettingsFont.caption)
                        .foregroundColor(theme.text.tertiary)
                        .italic()
                    Spacer()
                    Text("WAV, MP3, M4A", bundle: .module)
                        .font(SettingsFont.footnote)
                        .foregroundColor(theme.text.tertiary)
                }
                .padding(.horizontal, theme.space.s12)
                .padding(.vertical, theme.space.s8)
                .settingsChrome(.control)
            }

            if let error = fileError {
                HStack(spacing: theme.space.s6) {
                    Image(systemName: "exclamationmark.triangle.fill").glyphSize(.micro)
                    Text(error).font(SettingsFont.rowDescription)
                }
                .foregroundColor(theme.status.error.foreground)
                .padding(.top, theme.space.s4)
            }
        }
    }

    // MARK: - File Handling

    private func selectFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio, .wav, .mp3, .mpeg4Audio]
        panel.message = L("Select an audio file to transcribe")
        panel.prompt = L("Select")

        Task { @MainActor in
            guard await panel.beginModal() == .OK, let url = panel.url else { return }
            loadFile(from: url)
        }
    }

    private func loadFile(from url: URL) {
        fileError = nil
        do {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let data = try Data(contentsOf: url)
            if data.count > 25 * 1024 * 1024 {
                fileError = "File too large (max 25MB)"
                return
            }
            audioData = data
            selectedFileURL = url
            selectedFileName = url.lastPathComponent
        } catch {
            fileError = "Failed to read file: \(error.localizedDescription)"
        }
    }

    private func clearFile() {
        audioData = nil
        selectedFileURL = nil
        selectedFileName = nil
        fileError = nil
    }
}

// MARK: - Preview

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        ServerView()
            .environmentObject(ServerController())
            .frame(width: 900, height: 700)
    }
#endif
