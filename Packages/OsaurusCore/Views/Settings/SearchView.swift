//
//  SearchView.swift
//  osaurus
//
//  The Search settings tab — native web-search providers, following the
//  standard management-tab shell (SettingsPageHeader band + scrollable content):
//
//    - Hub panel with search status and provider/source metrics.
//    - Try-it playground running the exact cascade agents get.
//    - Preset gallery (empty state) / full-width provider cards (configured),
//      with a two-step connect flow that verifies keys automatically.
//    - Built-in sources and Advanced (per-category routing + custom JSON
//      definitions) as standard settings sections.
//

import AppKit
import SwiftUI

struct SearchView: View {
    @ObservedObject private var manager = SearchProviderManager.shared
    @ObservedObject private var themeManager = ThemeManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    // Try-it playground
    @State private var tryQuery: String = ""
    @State private var trySearching = false
    @State private var tryOutcome: SearchEngineOutcome?
    @State private var showAttempts = false

    // Sheets
    @State private var connectSheet: ConnectSheetConfig?
    @State private var showCustomEditor = false

    private struct ConnectSheetConfig: Identifiable {
        let id = UUID()
        /// nil = open on the preset picker phase.
        let definition: SearchProviderDefinition?
    }

    var body: some View {
        SettingsPage {
            headerView
        } content: {
            hubPanel
            premiumSearchSection
            tryItCard
            if apiProviderRows.isEmpty {
                presetGallery
            } else {
                providerCardList
            }
            freeSourcesSection
            advancedSection
        }
        .environment(\.theme, themeManager.currentTheme)
        .sheet(item: $connectSheet) { config in
            SearchProviderConnectSheet(initialDefinition: config.definition)
        }
        .sheet(isPresented: $showCustomEditor) {
            SearchCustomProviderSheet()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        SettingsPageHeader(
            title: "Web Search",
            subtitle: subtitleText,
            primary: {
                SettingsButton(.primary, "Connect Provider", icon: "plus") {
                    connectSheet = ConnectSheetConfig(definition: nil)
                }
            }
        )
    }

    private var subtitleText: String {
        let readyAPI = apiProviderRows.filter {
            $0.provider.enabled && manager.configuredProviderIds.contains($0.definition.id)
        }.count
        let freeOn = freeProviderRows.filter { $0.provider.enabled }.count
        if readyAPI > 0 {
            return L("\(readyAPI) provider\(readyAPI == 1 ? "" : "s") connected • \(freeOn) built-in source\(freeOn == 1 ? "" : "s") as backup")
        }
        if freeOn > 0 {
            return L("Running on built-in sources — connect a provider for better results")
        }
        return L("Web search is off — enable a source to let agents search")
    }

    // MARK: - Hub panel

    private var searchIsOn: Bool {
        manager.rankedProviders.contains { $0.provider.enabled }
    }

    /// Health verdict for the hub panel. Configuration alone can't prove
    /// search works (free scrapers may be challenge-blocked on this network),
    /// so a config-on state stays neutral until a real search — from a tool
    /// call or the Try-it box — verifies or contradicts it this session.
    private enum SearchHealthState {
        case off
        case unverified
        case healthy(SearchProviderManager.LastSearchOutcome)
        case failing(SearchProviderManager.LastSearchOutcome)
    }

    private var healthState: SearchHealthState {
        guard searchIsOn else { return .off }
        guard let last = manager.lastOutcome else { return .unverified }
        return last.ok ? .healthy(last) : .failing(last)
    }

    private var hubStatusChip: (label: String, tone: StatusChip.Tone) {
        switch healthState {
        case .off: (L("Off"), .error)
        case .unverified: (L("On"), .accent)
        case .healthy: (L("Working"), .success)
        case .failing: (L("Needs attention"), .warning)
        }
    }

    @ViewBuilder
    private var hubStatusSubtitle: some View {
        switch healthState {
        case .off:
            Text(
                "Enable at least one source below to let agents search the web.",
                bundle: .module)
        case .unverified:
            Text(
                "Providers are tried in order; if one fails, the next takes over. Run a test search below to confirm everything works.",
                bundle: .module)
        case .healthy(let last):
            Text(
                "Last search succeeded via \(providerDisplayName(last.providerId)) \(relativeTime(last.date)) — \(last.hitCount) result\(last.hitCount == 1 ? "" : "s").",
                bundle: .module)
        case .failing(let last):
            Text(
                "The last search \(relativeTime(last.date)) returned no results. Try a test search below, or connect a provider for more reliable results.",
                bundle: .module)
        }
    }

    private func providerDisplayName(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return L("built-in sources") }
        if id == OsaurusRouterSearchBackend.providerId { return L("Osaurus Premium") }
        return manager.definition(id: id)?.name ?? id
    }

    // MARK: - Premium search

    /// The only Premium Search switch, next to the providers it front-runs;
    /// grants, auto-pay, and usage live on Wallet & Credits, which this links to.
    @ViewBuilder
    private var premiumSearchSection: some View {
        if OsaurusRouter.isEnabled {
            SettingsSection(title: "Premium Search", anchorId: "search.premium") {
                SettingsToggle(
                    title: "Use Premium Search",
                    description: premiumSearchDescription,
                    isOn: Binding(
                        get: { manager.hostedSearchEnabled },
                        set: { manager.setHostedSearchEnabled($0) }
                    )
                )
                SettingsLinkRow(
                    title: "Search Credits",
                    description: "Manage search credits and billing.",
                    icon: "creditcard",
                    actionTitle: "Open Wallet & Credits"
                ) {
                    ManagementStateManager.shared.selectedTab = .credits
                }
            }
        }
    }

    private var premiumSearchDescription: String {
        if !manager.hostedSearchEnabled {
            if manager.hasActiveUserProviderSetup {
                return "Off — your own providers below handle every search."
            }
            return "Off — searches use the providers and built-in sources below."
        }
        return
            "Searches go through Osaurus first — search credits, then your wallet — and fall back to the sources below."
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return L("just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var hubPanel: some View {
        let readyAPI = apiProviderRows.filter {
            $0.provider.enabled && manager.configuredProviderIds.contains($0.definition.id)
        }.count
        let freeOn = freeProviderRows.filter { $0.provider.enabled }.count
        let categories = manager.availableCategories()
        let chip = hubStatusChip

        return SettingsSection(title: "Status") {
            SettingsRow(title: "Web Search") {
                hubStatusSubtitle
            } trailing: {
                StatusChip(chip.label, tone: chip.tone, showsDot: true)
            }
            SettingsValueRow(
                title: "Categories",
                value: categories.isEmpty
                    ? L("None") : categories.map { $0.capitalized }.joined(separator: " · ")
            )
            SettingsValueRow(title: "Providers", value: "\(readyAPI)")
            SettingsValueRow(title: "Built-in Sources", value: "\(freeOn)")
        }
    }

    // MARK: - Try it

    private var tryItCard: some View {
        SettingsSection(
            title: "Test Search",
            subtitle: "The same search your agents get, so what you see here is what they see.",
            anchorId: "search.tryIt"
        ) {
            VStack(alignment: .leading, spacing: theme.space.s12) {
                HStack(spacing: theme.settingsControlGap) {
                    SettingsTextField(
                        placeholder: L("Search the web…"),
                        text: $tryQuery,
                        icon: "magnifyingglass",
                        onSubmit: runTrySearch
                    )
                    SettingsButton(.primary, "Search", isLoading: trySearching, action: runTrySearch)
                        .disabled(trySearching || tryQueryEmpty)
                }
                if let outcome = tryOutcome {
                    tryResults(outcome)
                }
            }
        }
    }

    private var tryQueryEmpty: Bool {
        tryQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @ViewBuilder
    private func tryResults(_ outcome: SearchEngineOutcome) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if outcome.hits.isEmpty {
                Text("No results. Try a different query.", bundle: .module)
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.secondary)
            } else {
                ForEach(Array(outcome.hits.prefix(5).enumerated()), id: \.offset) { _, hit in
                    VStack(alignment: .leading, spacing: 2) {
                        Button {
                            if let url = URL(string: hit.url) {
                                NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
                            }
                        } label: {
                            Text(hit.title.isEmpty ? hit.url : hit.title)
                                .font(SettingsFont.compactLabel)
                                .foregroundColor(theme.text.link)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                        }
                        if !hit.snippet.isEmpty {
                            Text(hit.snippet)
                                .font(SettingsFont.rowDescription)
                                .foregroundColor(theme.text.secondary)
                                .lineLimit(2)
                        }
                        Text(SearchHTML.sourceDomain(of: hit.url) ?? hit.url)
                            .font(SettingsFont.footnote)
                            .foregroundColor(theme.text.tertiary)
                            .lineLimit(1)
                    }
                }
            }

            HStack(spacing: 8) {
                if let provider = outcome.provider, !provider.isEmpty {
                    Text(
                        "via \(providerDisplayName(provider)) · \(String(format: "%.1f", outcome.elapsed))s"
                    )
                    .font(SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
                }
                Spacer()
                Button {
                    withAnimation(theme.motion.quick) { showAttempts.toggle() }
                } label: {
                    Text(showAttempts ? "Hide attempts" : "Show attempts", bundle: .module)
                        .font(SettingsFont.footnote)
                        .foregroundColor(theme.text.tertiary)
                }
                .buttonStyle(.plain)
            }

            if showAttempts {
                attemptsTrace(outcome.attempts)
            }
        }
        .padding(.top, theme.space.s4)
    }

    private func attemptsTrace(_ attempts: [SearchAttempt]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(attempts.enumerated()), id: \.offset) { index, attempt in
                HStack(spacing: 6) {
                    Image(systemName: attempt.ok ? "checkmark.circle" : "xmark.circle")
                        .glyphSize(9)
                        .foregroundColor(attempt.ok ? theme.status.success.foreground : theme.status.error.foreground)
                    Text(
                        "\(index + 1). \(providerDisplayName(attempt.provider)) — "
                            + (attempt.ok
                                ? (attempt.count == 1 ? L("1 result") : L("\(attempt.count) results"))
                                : (attempt.error ?? "failed"))
                    )
                    .textStyle(.micro, family: .code)
                    .foregroundColor(theme.text.tertiary)
                    .lineLimit(1)
                }
            }
        }
        .padding(.top, theme.space.s2)
    }

    private func runTrySearch() {
        let query = tryQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !trySearching else { return }
        trySearching = true
        tryOutcome = nil
        Task {
            // Same premium-first path the tools run, so the health panel and
            // "via …" label reflect what agents actually get (including a
            // billed hosted request when premium is on).
            let run = await manager.runHostedFirstSearch(
                SearchRequest(query: query, maxResults: 5),
                idempotencyKey: UUID().uuidString
            )
            await MainActor.run {
                tryOutcome = run.outcome
                trySearching = false
            }
        }
    }

    // MARK: - Preset gallery (empty state)

    private var presetGallery: some View {
        SettingsSection(
            title: "Search Providers",
            subtitle:
                "Built-in sources work out of the box. Connect a search provider for faster, more relevant results — setup takes about 2 minutes.",
            footer: "Your API keys are stored securely in Keychain.",
            anchorId: "search.providers"
        ) {
            ForEach(manager.addableDefinitions) { definition in
                SearchPresetRowCard(definition: definition) {
                    connectSheet = ConnectSheetConfig(definition: definition)
                }
            }
        }
    }

    // MARK: - Provider cards (configured state)

    /// Ranked API-key providers (free scrapers are shown separately).
    private var apiProviderRows: [(provider: SearchProvider, definition: SearchProviderDefinition)] {
        manager.rankedProviders.filter { !$0.definition.isKeyless }
    }

    private var providerCardList: some View {
        let rows = apiProviderRows
        return SettingsSection(
            title: "Your Providers",
            subtitle: "Tried top to bottom — if one fails, the next takes over.",
            anchorId: "search.providers"
        ) {
            ForEach(Array(rows.enumerated()), id: \.element.provider.id) { index, row in
                SearchProviderCard(
                    provider: row.provider,
                    definition: row.definition,
                    rank: index + 1,
                    isFirst: index == 0,
                    isLast: index == rows.count - 1,
                    showReorder: rows.count > 1,
                    onMoveUp: { moveAPIProvider(definitionId: row.provider.definitionId, up: true) },
                    onMoveDown: {
                        moveAPIProvider(definitionId: row.provider.definitionId, up: false)
                    },
                    onEditKey: { connectSheet = ConnectSheetConfig(definition: row.definition) },
                    onRemove: { manager.removeProvider(definitionId: row.provider.definitionId) },
                    onToggle: { manager.setEnabled($0, for: row.provider.definitionId) }
                )
            }
        }
    }

    /// Move an API provider up/down within the API-provider block of the
    /// default ranking, leaving the free scrapers pinned after them.
    private func moveAPIProvider(definitionId: String, up: Bool) {
        var apiIds = apiProviderRows.map { $0.provider.definitionId }
        guard let idx = apiIds.firstIndex(of: definitionId) else { return }
        let target = up ? idx - 1 : idx + 1
        guard apiIds.indices.contains(target) else { return }
        apiIds.swapAt(idx, target)
        let freeIds = manager.rankedProviders.filter { $0.definition.isKeyless }
            .map { $0.provider.definitionId }
        manager.setDefaultRanking(apiIds + freeIds)
    }

    // MARK: - Built-in sources

    private var freeProviderRows: [(provider: SearchProvider, definition: SearchProviderDefinition)] {
        manager.rankedProviders.filter { $0.definition.isKeyless }
    }

    private var freeSourcesSection: some View {
        SettingsSection(
            title: "Built-in Sources",
            subtitle: "Built-in sources that need no key. Always available as backup when no provider answers."
        ) {
            ForEach(freeProviderRows, id: \.provider.id) { row in
                freeSourceRow(row.provider, row.definition)
            }
        }
    }

    private func freeSourceRow(
        _ provider: SearchProvider,
        _ definition: SearchProviderDefinition
    ) -> some View {
        HStack(spacing: theme.settingsControlGap) {
            VStack(alignment: .leading, spacing: theme.settingsTitleToDescription) {
                HStack(spacing: theme.space.s6) {
                    Text(definition.name)
                        .font(SettingsFont.rowTitle)
                        .foregroundColor(theme.text.primary)
                    if definition.lastResort {
                        StatusChip(L("Last resort"), tone: .warning)
                            .localizedHelp(
                                "Only used when every other source fails — this source sometimes returns unreliable results."
                            )
                    }
                }
                if let summary = definition.summary {
                    Text(summary)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                }
            }
            Spacer()

            testButton(for: definition.id)

            Toggle(
                "",
                isOn: Binding(
                    get: { provider.enabled },
                    set: { manager.setEnabled($0, for: provider.definitionId) }
                )
            )
            .settingsSwitch()
        }
    }

    private func testButton(for definitionId: String) -> some View {
        SettingsIconButton(
            "bolt.fill",
            isLoading: manager.testStatus[definitionId] == .testing,
            help: L("Run a test search"),
            size: .compact
        ) {
            Task { await manager.testProvider(definitionId: definitionId) }
        }
        .disabled(manager.testStatus[definitionId] == .testing)
    }

    // MARK: - Advanced

    @ViewBuilder
    private var advancedSection: some View {
        SettingsSection(
            title: "Category Preferences",
            subtitle:
                "Pick which provider answers first for each kind of search. The rest follow your main list order, with built-in sources as backup.",
            anchorId: "search.routing"
        ) {
            ForEach(allCategories, id: \.self) { category in
                routingRow(category: category)
            }
        }
        SettingsSection(
            title: "Custom Providers",
            subtitle:
                "Any REST search API (Perplexity, SearXNG, self-hosted…) can be added as a JSON definition — no app update required.",
            anchorId: "search.custom"
        ) {
            SettingsButton(.secondary, "Add Custom Provider", icon: "plus", size: .compact) {
                showCustomEditor = true
            }
        } content: {
            customProvidersContent
        }
    }

    private var allCategories: [String] {
        var out: Set<String> = []
        for (_, def) in manager.rankedProviders {
            out.formUnion(def.supportedCategories)
        }
        return out.sorted {
            (SearchCategory.sortIndex($0), $0) < (SearchCategory.sortIndex($1), $1)
        }
    }

    private func categoryIcon(_ category: String) -> String {
        switch category {
        case SearchCategory.web: return "globe"
        case SearchCategory.news: return "newspaper.fill"
        case SearchCategory.images: return "photo.fill"
        default: return "square.grid.2x2"
        }
    }

    /// Enabled providers that can serve this category, in effective try order.
    private func eligibleOrder(for category: String) -> [String] {
        manager.configuration.ranking(for: category).filter { id in
            manager.definition(id: id)?.supports(category: category) == true
                && manager.configuration.provider(id: id)?.enabled == true
        }
    }

    private func routingRow(category: String) -> some View {
        let order = eligibleOrder(for: category)
        let hasOverride = manager.configuration.routing[category]?.isEmpty == false

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: categoryIcon(category))
                    .glyphSize(11, weight: .medium)
                    .foregroundColor(theme.text.link)
                    .frame(width: 16)
                Text(category.capitalized)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)

                Spacer()

                if order.count > 1 {
                    Text("Try first:", bundle: .module)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                    tryFirstMenu(category: category, order: order, hasOverride: hasOverride)
                }
            }

            if order.isEmpty {
                Text("No enabled source can search this category.", bundle: .module)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
            } else if order.count == 1 {
                orderChip(rank: 1, definitionId: order[0], isFirst: true)
            } else {
                // Read-only trace of the effective try order; the menu above
                // is the only control, so nothing here needs decoding.
                HStack(spacing: 6) {
                    ForEach(Array(order.enumerated()), id: \.element) { index, id in
                        if index > 0 {
                            Image(systemName: "arrow.right")
                                .glyphSize(7, weight: .semibold)
                                .foregroundColor(theme.text.disabled)
                        }
                        orderChip(rank: index + 1, definitionId: id, isFirst: index == 0)
                    }
                }
            }
        }
    }

    /// One provider in the try-order trace. The first chip is accent-tinted;
    /// last-resort scrapers are visibly downgraded so the trace matches what
    /// the engine actually does.
    private func orderChip(rank: Int, definitionId: String, isFirst: Bool) -> some View {
        let isLastResort = manager.definition(id: definitionId)?.lastResort == true
        let name = providerDisplayName(definitionId)
        return StatusChip(
            isLastResort ? "\(name) · \(L("last resort"))" : name,
            tone: isLastResort ? .warning : (isFirst ? .accent : .neutral)
        )
        .localizedHelp(
            isLastResort
                ? "Only used when every other source fails."
                : (isFirst ? "Tried first for this category." : "Tried if earlier sources fail.")
        )
    }

    /// Dropdown that pins one provider first for a category. "Default order"
    /// clears the override; picking a provider stores a single-id override
    /// (`ranking(for:)` appends the rest in main-list order).
    private func tryFirstMenu(category: String, order: [String], hasOverride: Bool) -> some View {
        SettingsMenuPicker(
            selection: Binding(
                get: { hasOverride ? order.first : nil },
                set: { manager.setRouting(category: category, order: $0.map { [$0] }) }
            )
        ) {
            Text("Default order", bundle: .module).tag(String?.none)
            Divider()
            ForEach(order, id: \.self) { id in
                Text(providerDisplayName(id)).tag(String?.some(id))
            }
        }
    }

    @ViewBuilder
    private var customProvidersContent: some View {
        if manager.customDefinitions.isEmpty {
            SettingsEmptyState(inline: "curlybraces", title: "No custom providers yet")
        } else {
            ForEach(manager.customDefinitions) { definition in
                SettingsRow(title: definition.name, verbatimTitle: true) {
                    Text(verbatim: definition.id)
                        .font(SettingsFont.monoSmall)
                } trailing: {
                    HStack(spacing: theme.space.s6) {
                        SettingsIconButton("doc.on.doc", help: L("Copy definition JSON"), size: .compact) {
                            copyDefinitionJSON(definition)
                        }
                        SettingsIconButton(
                            "trash",
                            help: L("Delete this custom provider"),
                            size: .compact,
                            isDestructive: true
                        ) {
                            manager.deleteCustomDefinition(id: definition.id)
                        }
                    }
                }
            }
        }
    }

    private func copyDefinitionJSON(_ definition: SearchProviderDefinition) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(definition),
            let json = String(data: data, encoding: .utf8)
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
        _ = ToastManager.shared.success(L("Definition copied"))
    }

    // MARK: - Helpers

    private func providerDisplayName(_ definitionId: String) -> String {
        manager.definition(id: definitionId)?.name ?? definitionId
    }
}

// MARK: - Preset row card

/// Selection row for the connect gallery: the `ProviderRowCard` shape with
/// search-provider content (pricing note, Recommended badge).
private struct SearchPresetRowCard: View {
    let definition: SearchProviderDefinition
    let action: () -> Void

    var body: some View {
        LibraryRow(
            title: definition.name,
            subtitle: [definition.summary, definition.pricingNote].compactMap { $0 }.joined(separator: " · "),
            showsChevron: true,
            action: action
        ) {
            SettingsIconTile(icon: "magnifyingglass", size: 32)
        } badges: {
            if definition.recommended {
                StatusChip(L("Recommended"), tone: .accent)
            }
        }
    }
}

// MARK: - Provider card

/// One configured API provider, in fallback rank order: status, reorder,
/// test, enable; key and removal in the menu.
private struct SearchProviderCard: View {
    let provider: SearchProvider
    let definition: SearchProviderDefinition
    let rank: Int
    let isFirst: Bool
    let isLast: Bool
    let showReorder: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onEditKey: () -> Void
    let onRemove: () -> Void
    let onToggle: (Bool) -> Void

    @Environment(\.theme) private var theme
    @ObservedObject private var manager = SearchProviderManager.shared

    @State private var showDeleteConfirm = false

    private var isConfigured: Bool {
        manager.configuredProviderIds.contains(definition.id)
    }

    private var isReady: Bool { provider.enabled && isConfigured }

    private var statusColor: Color {
        if !provider.enabled { return theme.text.tertiary }
        if case .failed = manager.testStatus[definition.id] { return theme.status.error.foreground }
        if !isConfigured { return theme.status.warning.foreground }
        return theme.status.success.foreground
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            LibraryRow(title: definition.name, subtitle: definition.summary) {
                HStack(spacing: theme.space.s8) {
                    Text(verbatim: "#\(rank)")
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.tertiary)
                        .frame(minWidth: 18, alignment: .trailing)
                    SettingsIconTile(icon: "globe.americas.fill", size: 32, tint: statusColor)
                }
            } badges: {
                statusBadge
            } trailing: {
                if showReorder {
                    SettingsIconButton("chevron.up", help: "Move up", size: .compact, action: onMoveUp)
                        .disabled(isFirst)
                    SettingsIconButton("chevron.down", help: "Move down", size: .compact, action: onMoveDown)
                        .disabled(isLast)
                }
                SettingsIconButton(
                    "bolt.fill",
                    isLoading: manager.testStatus[definition.id] == .testing,
                    help: "Run a test search"
                ) {
                    Task { await manager.testProvider(definitionId: definition.id) }
                }
                .disabled(manager.testStatus[definition.id] == .testing)

                Toggle(
                    "",
                    isOn: Binding(
                        get: { provider.enabled },
                        set: { onToggle($0) }
                    )
                )
                .settingsSwitch()
            } menu: {
                Button(L("Update API key"), action: onEditKey)
                Divider()
                Button(L("Remove provider and its key"), role: .destructive) { showDeleteConfirm = true }
            }

            // Test-failure detail
            if case .failed(let message) = manager.testStatus[definition.id] {
                InlineBanner(kind: .error, title: message)
            }
        }
        .themedAlert(
            L("Remove Provider?"),
            isPresented: $showDeleteConfirm,
            message: L("This will remove '\(definition.name)' and delete its API key from Keychain."),
            primaryButton: .destructive(L("Remove")) { onRemove() },
            secondaryButton: .cancel(L("Cancel"))
        )
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch manager.testStatus[definition.id] {
        case .testing:
            StatusChip(L("Checking…"), tone: .accent)
        case .ok:
            badge(L("Working"), color: theme.status.success.foreground)
        case .failed:
            badge(isConfigured ? L("Key invalid") : L("Needs key"), color: theme.status.error.foreground)
        case nil:
            if !isConfigured {
                badge(L("Needs key"), color: theme.status.warning.foreground)
            } else if !provider.enabled {
                badge(L("Off"), color: theme.text.tertiary)
            } else {
                badge(L("Ready"), color: theme.status.success.foreground)
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        StatusChip(text, tint: color)
    }
}

// MARK: - Connect sheet

/// Two-phase connect sheet following the provider edit-sheet scaffold:
/// a preset picker (when opened from the header button) and a configure
/// phase with plain-language steps, a "Get key" shortcut, and automatic
/// verification of pasted keys against a real search.
private struct SearchProviderConnectSheet: View {
    /// Non-nil skips the picker and opens directly on the configure phase.
    let initialDefinition: SearchProviderDefinition?

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = SearchProviderManager.shared

    @State private var selectedDefinition: SearchProviderDefinition?

    @State private var values: [String: String] = [:]
    @State private var verifying = false
    @State private var verified = false
    @State private var verifyError: String?
    /// Debounces auto-verification while the user is still typing/pasting.
    @State private var verifyTask: Task<Void, Never>?

    private var definition: SearchProviderDefinition? {
        selectedDefinition ?? initialDefinition
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader

            ScrollView {
                Group {
                    if let definition {
                        configureBody(definition)
                    } else {
                        pickerBody
                    }
                }
                .padding(theme.space.s24)
            }

            sheetFooter
        }
        .frame(width: 560, height: definition == nil ? 560 : 480)
        .background(theme.surface.canvas)
        .clipShape(RoundedRectangle(cornerRadius: theme.radius.xlarge))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.xlarge)
                .stroke(theme.border.subtle, lineWidth: theme.stroke.default)
        )
        .onAppear {
            // Prefill presence indicators for already-saved secrets (values
            // themselves are never read back into the UI).
            if let definition {
                verified = manager.configuredProviderIds.contains(definition.id)
                    && manager.configuration.provider(id: definition.id) != nil
            }
        }
        .onDisappear { verifyTask?.cancel() }
    }

    // MARK: Header

    @ViewBuilder
    private var sheetHeader: some View {
        if let definition {
            SettingsSheetHeader(
                icon: "magnifyingglass",
                title: "Connect \(definition.name)",
                subtitle: "Paste your API key — it's verified with a real search"
            ) { dismiss() }
        } else {
            SettingsSheetHeader(
                icon: "magnifyingglass",
                title: "Connect a Search Provider",
                subtitle: "Choose a service to connect"
            ) { dismiss() }
        }
    }

    // MARK: Picker phase

    private var pickerBody: some View {
        VStack(spacing: 10) {
            if manager.addableDefinitions.isEmpty {
                Text("All bundled providers are already connected.", bundle: .module)
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.secondary)
                    .padding(.vertical, theme.space.s24)
            } else {
                SettingsGroup {
                    ForEach(manager.addableDefinitions) { candidate in
                        SearchPresetRowCard(definition: candidate) {
                            selectedDefinition = candidate
                            verified = false
                            verifyError = nil
                        }
                    }
                }
            }
        }
    }

    // MARK: Configure phase

    @ViewBuilder
    private func configureBody(_ definition: SearchProviderDefinition) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let steps = definition.instructions, !steps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1)")
                                .font(SettingsFont.monoSmall)
                                .foregroundColor(theme.text.link)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(theme.status.info.background))
                            Text(step)
                                .font(SettingsFont.caption)
                                .foregroundColor(theme.text.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if let signup = definition.signupURL, let url = URL(string: signup) {
                Button {
                    // The no-configuration overload round-trips to
                    // LaunchServices over blocking XPC and has hung the main
                    // thread for seconds; the completion-handler variant
                    // returns immediately.
                    NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "safari")
                            .glyphSize(11, weight: .medium)
                        Text("Open signup page", bundle: .module)
                            .font(SettingsFont.compactLabel)
                    }
                    .foregroundColor(theme.text.primary)
                    .padding(.horizontal, theme.space.s12)
                    .padding(.vertical, theme.space.s8)
                    .settingsChrome(.subtle)
                }
                .buttonStyle(PlainButtonStyle())
            }

            ForEach(definition.secrets ?? []) { field in
                secretField(field)
            }

            HStack(spacing: 4) {
                Image(systemName: "lock.fill")
                    .glyphSize(9)
                Text("Stored securely in Keychain. Never sent anywhere except this provider.", bundle: .module)
                    .font(SettingsFont.rowDescription)
            }
            .foregroundColor(theme.text.tertiary)
        }
    }

    private func secretField(_ field: SearchSecretField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(field.label)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.primary)

            SettingsTextField(
                placeholder: field.help ?? L("Paste here"),
                text: binding(for: field.id),
                monospaced: true,
                isSecure: true
            )

            if let help = field.help {
                Text(help)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
            }
        }
    }

    // MARK: Footer

    private var sheetFooter: some View {
        HStack(spacing: 12) {
            if definition != nil {
                if verifying {
                    ProgressView().controlSize(.small)
                    Text("Checking your key with a real search…", bundle: .module)
                        .font(SettingsFont.caption)
                        .foregroundColor(theme.text.secondary)
                } else if verified {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(theme.status.success.foreground)
                    Text("Connected. You're all set.", bundle: .module)
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.status.success.foreground)
                } else if let error = verifyError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(theme.status.error.foreground)
                    Text(error)
                        .font(SettingsFont.caption)
                        .foregroundColor(theme.status.error.foreground)
                        .lineLimit(2)
                }
            }

            Spacer()

            if definition != nil, initialDefinition == nil {
                SettingsButton(.secondary, "Back") {
                    selectedDefinition = nil
                    verified = false
                    verifyError = nil
                    values = [:]
                }
            }

            if verified {
                Button {
                    dismiss()
                } label: {
                    Text("Done", bundle: .module)
                }
                .assignedSettingsButtonStyle(.primary)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, theme.space.s24)
        .padding(.vertical, theme.space.s16)
        .background(theme.surface.subtle)
    }

    // MARK: Verification

    private func binding(for fieldId: String) -> Binding<String> {
        Binding(
            get: { values[fieldId] ?? "" },
            set: { newValue in
                values[fieldId] = newValue
                scheduleVerification()
            }
        )
    }

    private var allFieldsFilled: Bool {
        guard let definition else { return false }
        return (definition.secrets ?? []).allSatisfy { field in
            !(values[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Auto-verify on paste: once every field has a value, wait a beat for
    /// typing to settle, then save + run a real one-query test.
    private func scheduleVerification() {
        verified = false
        verifyError = nil
        verifyTask?.cancel()
        guard allFieldsFilled else { return }
        verifyTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await verifyAndSave()
        }
    }

    @MainActor
    private func verifyAndSave() async {
        guard let definition else { return }
        verifying = true
        defer { verifying = false }

        for field in definition.secrets ?? [] {
            manager.saveSecret(values[field.id] ?? "", field: field.id, for: definition.id)
        }
        if manager.configuration.provider(id: definition.id) == nil {
            manager.addProvider(definitionId: definition.id)
        }
        let outcome = await manager.testProvider(definitionId: definition.id)
        if case .ok = manager.testStatus[definition.id] {
            verified = true
            verifyError = nil
        } else {
            let reason = outcome?.attempts.first(where: { !$0.ok })?.error
            verifyError =
                reason.map { String(format: L("That key didn't work: %@"), $0) }
                ?? L("That key didn't work. Double-check it and paste again.")
        }
    }
}

// MARK: - Custom provider editor

/// Paste-a-JSON-definition editor following the sheet scaffold. The definition
/// format is the same one the bundled providers use; validated by decoding
/// before saving.
private struct SearchCustomProviderSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = SearchProviderManager.shared

    @State private var jsonText: String = SearchCustomProviderSheet.template
    @State private var errorMessage: String?

    static let template = """
        {
          "id": "my_search_api",
          "name": "My Search API",
          "summary": "One-line description",
          "secrets": [
            { "id": "api_key", "label": "API key", "url": "https://example.com/keys" }
          ],
          "endpoints": {
            "web": {
              "url": "https://api.example.com/search",
              "method": "GET",
              "headers": { "Authorization": "Bearer {{secret.api_key}}" },
              "query": [
                { "name": "q", "value": "{{query}}" },
                { "name": "count", "value": "{{max_results}}" }
              ],
              "body": [],
              "response": {
                "resultsPath": "results",
                "item": { "title": "title", "url": "url", "snippet": "snippet" }
              }
            }
          }
        }
        """

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader

            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "Placeholders: {{query}}, {{max_results}}, {{offset}}, {{page}}, {{start}}, {{time_range}}, {{after_date}}, {{region}}, {{secret.<id>}}.",
                    bundle: .module
                )
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)

                SettingsTextEditor(text: $jsonText, minHeight: 280, maxHeight: 300, monospaced: true)

                if let errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .glyphSize(11)
                        Text(errorMessage)
                            .font(SettingsFont.rowDescription)
                            .lineLimit(3)
                    }
                    .foregroundColor(theme.status.error.foreground)
                }
            }
            .padding(theme.space.s24)

            sheetFooter
        }
        .fittedSheetFrame(width: 560, height: 540)
        .background(theme.surface.canvas)
        .clipShape(RoundedRectangle(cornerRadius: theme.radius.xlarge))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.xlarge)
                .stroke(theme.border.subtle, lineWidth: theme.stroke.default)
        )
    }

    private var sheetHeader: some View {
        SettingsSheetHeader(
            icon: "slider.horizontal.3",
            title: "Custom Provider",
            subtitle: "Describe any REST search API as a JSON definition"
        ) { dismiss() }
    }

    private var sheetFooter: some View {
        SettingsSheetFooter(
            primary: .init(label: "Validate & Save", handler: saveDefinition),
            secondary: .init(label: "Cancel") { dismiss() }
        )
    }

    private func saveDefinition() {
        errorMessage = nil
        guard let data = jsonText.data(using: .utf8) else { return }
        do {
            let definition = try JSONDecoder().decode(SearchProviderDefinition.self, from: data)
            guard definition.runtime == .declarative else {
                errorMessage = L("Custom providers must be declarative (runtime: declarative).")
                return
            }
            guard let endpoints = definition.endpoints, !endpoints.isEmpty else {
                errorMessage = L("The definition needs at least one endpoint (e.g. \"web\").")
                return
            }
            if SearchProviderCatalog.bundled.contains(where: { $0.id == definition.id }) {
                errorMessage = String(
                    format: L("The id \"%@\" is taken by a bundled provider. Pick another id."),
                    definition.id)
                return
            }
            try manager.saveCustomDefinition(definition)
            _ = ToastManager.shared.success(
                String(format: L("Added %@"), definition.name),
                message: definition.isKeyless
                    ? nil : L("Add its API key from the provider list to finish setup."))
            dismiss()
        } catch let decodeError as DecodingError {
            errorMessage = describeDecodingError(decodeError)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func describeDecodingError(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            return "Missing \"\(key.stringValue)\" at \(path(context)). "
        case .typeMismatch(_, let context):
            return "Wrong type at \(path(context)): \(context.debugDescription)"
        case .valueNotFound(_, let context):
            return "Missing value at \(path(context))."
        case .dataCorrupted(let context):
            return context.debugDescription.isEmpty ? "Invalid JSON." : context.debugDescription
        @unknown default:
            return "Invalid definition JSON."
        }
    }

    private func path(_ context: DecodingError.Context) -> String {
        let p = context.codingPath.map { $0.stringValue }.joined(separator: ".")
        return p.isEmpty ? "top level" : p
    }
}

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        SearchView()
            .environment(\.theme, CustomizableTheme.dark())
    }
#endif
