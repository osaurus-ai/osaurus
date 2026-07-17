//
//  SearchView.swift
//  osaurus
//
//  The Search settings tab — native web-search providers, following the
//  standard management-tab shell (ManagerHeader band + scrollable content):
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

    @State private var hasAppeared = false

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
        VStack(spacing: 0) {
            headerView
                .managerHeaderEntrance(hasAppeared: hasAppeared)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hubPanel
                    premiumSearchStrip
                    tryItCard
                    if apiProviderRows.isEmpty {
                        presetGallery
                    } else {
                        providerCardList
                    }
                    freeSourcesSection
                    advancedSection
                }
                .padding(24)
            }
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
        .sheet(item: $connectSheet) { config in
            SearchProviderConnectSheet(initialDefinition: config.definition)
        }
        .sheet(isPresented: $showCustomEditor) {
            SearchCustomProviderSheet()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: L("Search"),
            subtitle: subtitleText
        ) {
            HeaderPrimaryButton("Connect Provider", icon: "plus") {
                connectSheet = ConnectSheetConfig(definition: nil)
            }
        }
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

    private var hubStatusIcon: (name: String, color: Color) {
        switch healthState {
        case .off: ("xmark.octagon.fill", theme.errorColor)
        case .unverified: ("magnifyingglass.circle.fill", theme.accentColor)
        case .healthy: ("checkmark.seal.fill", theme.successColor)
        case .failing: ("exclamationmark.triangle.fill", theme.warningColor)
        }
    }

    private var hubStatusTitle: LocalizedStringKey {
        switch healthState {
        case .off: "Web Search is off"
        case .unverified, .healthy: "Web Search is on"
        case .failing: "Web Search needs attention"
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

    // MARK: - Premium search strip

    /// Compact premium-search state row: the on/off preference lives here for
    /// discoverability next to the providers it front-runs; grants, auto-pay,
    /// and usage live in the dedicated Credits section this links to.
    @ViewBuilder
    private var premiumSearchStrip: some View {
        if OsaurusRouter.isEnabled {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "magnifyingglass.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(
                        manager.hostedSearchEnabled ? theme.accentColor : theme.tertiaryText)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Premium search", bundle: .module)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(premiumStripSubtitle, bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button {
                    ManagementStateManager.shared.selectedTab = .credits
                } label: {
                    Text("Credits", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .localizedHelp("Manage search credits and billing.")

                Toggle(
                    "",
                    isOn: Binding(
                        get: { manager.hostedSearchEnabled },
                        set: { manager.setHostedSearchEnabled($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(theme.accentColor)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                manager.hostedSearchEnabled
                                    ? theme.accentColor.opacity(0.35) : theme.cardBorder,
                                lineWidth: 1
                            )
                    )
            )
        }
    }

    private var premiumStripSubtitle: LocalizedStringKey {
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
        let status = hubStatusIcon

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: status.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(status.color)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(status.color.opacity(0.12)))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(hubStatusTitle, bundle: .module)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                        hubStatusSubtitle
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                    }
                }
                Spacer()
            }

            HStack(spacing: 8) {
                metricPill(title: L("Providers"), value: "\(readyAPI)", color: theme.accentColor)
                metricPill(title: L("Built-in sources"), value: "\(freeOn)", color: theme.successColor)
                metricPill(
                    title: L("Categories"),
                    value: categories.map { $0.capitalized }.joined(separator: " · "),
                    color: theme.infoColor
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(status.color.opacity(0.35), lineWidth: 1)
                )
        )
    }

    private func metricPill(title: String, value: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(color.opacity(0.1)))
    }

    // MARK: - Try it

    private var tryItCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                Text("Try it", bundle: .module)
                    .textCase(.uppercase)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.secondaryText)
                    .tracking(0.5)
            }

            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                    TextField(L("Search the web…"), text: $tryQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(theme.primaryText)
                        .onSubmit { runTrySearch() }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )

                Button {
                    runTrySearch()
                } label: {
                    Group {
                        if trySearching {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Search", bundle: .module)
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(
                                trySearching || tryQueryEmpty
                                    ? theme.tertiaryBackground : theme.accentColor)
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(trySearching || tryQueryEmpty)
            }

            if let outcome = tryOutcome {
                tryResults(outcome)
            } else {
                Text(
                    "This uses the exact same search your agents get — what you see here is what they see.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
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
        .settingsLandingAnchor("search.tryIt")
    }

    private var tryQueryEmpty: Bool {
        tryQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @ViewBuilder
    private func tryResults(_ outcome: SearchEngineOutcome) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if outcome.hits.isEmpty {
                Text("No results. Try a different query.", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            } else {
                ForEach(Array(outcome.hits.prefix(5).enumerated()), id: \.offset) { _, hit in
                    VStack(alignment: .leading, spacing: 2) {
                        Button {
                            if let url = URL(string: hit.url) {
                                NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
                            }
                        } label: {
                            Text(hit.title.isEmpty ? hit.url : hit.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(theme.accentColor)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                        }
                        if !hit.snippet.isEmpty {
                            Text(hit.snippet)
                                .font(.system(size: 11))
                                .foregroundColor(theme.secondaryText)
                                .lineLimit(2)
                        }
                        Text(SearchHTML.sourceDomain(of: hit.url) ?? hit.url)
                            .font(.system(size: 10))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                    }
                }
            }

            HStack(spacing: 8) {
                if let provider = outcome.provider, !provider.isEmpty {
                    Text(
                        "via \(providerDisplayName(provider)) · \(String(format: "%.1f", outcome.elapsed))s"
                    )
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                }
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showAttempts.toggle() }
                } label: {
                    Text(showAttempts ? "Hide attempts" : "Show attempts", bundle: .module)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
            }

            if showAttempts {
                attemptsTrace(outcome.attempts)
            }
        }
        .padding(.top, 4)
    }

    private func attemptsTrace(_ attempts: [SearchAttempt]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(attempts.enumerated()), id: \.offset) { index, attempt in
                HStack(spacing: 6) {
                    Image(systemName: attempt.ok ? "checkmark.circle" : "xmark.circle")
                        .font(.system(size: 9))
                        .foregroundColor(attempt.ok ? theme.successColor : theme.errorColor)
                    Text(
                        "\(index + 1). \(providerDisplayName(attempt.provider)) — "
                            + (attempt.ok
                                ? "\(attempt.count) result(s)"
                                : (attempt.error ?? "failed"))
                    )
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
                }
            }
        }
        .padding(.top, 2)
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
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(theme.accentColor.opacity(0.1))
                        .frame(width: 56, height: 56)
                    Image(systemName: "globe.americas.fill")
                        .font(.system(size: 24))
                        .foregroundColor(theme.accentColor)
                }
                Text("Want better results?", bundle: .module)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(
                    "Built-in sources work out of the box. Connect a search provider for faster, more relevant results — setup takes about 2 minutes.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)

            VStack(spacing: 10) {
                ForEach(manager.addableDefinitions) { definition in
                    SearchPresetRowCard(definition: definition) {
                        connectSheet = ConnectSheetConfig(definition: definition)
                    }
                }
            }

            HStack(spacing: 4) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                Text("Your API keys are stored securely in Keychain.", bundle: .module)
                    .font(.system(size: 12))
            }
            .foregroundColor(theme.tertiaryText)
            .frame(maxWidth: .infinity)
        }
        .settingsLandingAnchor("search.providers")
    }

    // MARK: - Provider cards (configured state)

    /// Ranked API-key providers (free scrapers are shown separately).
    private var apiProviderRows: [(provider: SearchProvider, definition: SearchProviderDefinition)] {
        manager.rankedProviders.filter { !$0.definition.isKeyless }
    }

    private var providerCardList: some View {
        let rows = apiProviderRows
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your Providers", bundle: .module)
                    .textCase(.uppercase)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.secondaryText)
                    .tracking(0.5)
                Spacer()
                Text("Tried top to bottom — if one fails, the next takes over.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
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
        .settingsLandingAnchor("search.providers")
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
        SettingsSection(title: L("Built-in Sources"), icon: "globe") {
            VStack(alignment: .leading, spacing: 0) {
                Text(
                    "Built-in sources that need no key. Always available as backup when no provider answers.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .padding(.bottom, 10)

                ForEach(Array(freeProviderRows.enumerated()), id: \.element.provider.id) { index, row in
                    if index > 0 {
                        Divider().background(theme.primaryBorder)
                    }
                    freeSourceRow(row.provider, row.definition)
                }
            }
        }
    }

    private func freeSourceRow(
        _ provider: SearchProvider,
        _ definition: SearchProviderDefinition
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(definition.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    if definition.lastResort {
                        Text("Last resort", bundle: .module)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.warningColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(theme.warningColor.opacity(0.12)))
                            .localizedHelp(
                                "Only used when every other source fails — this source sometimes returns unreliable results."
                            )
                    }
                }
                if let summary = definition.summary {
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
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
            .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
            .controlSize(.small)
            .labelsHidden()
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func testButton(for definitionId: String) -> some View {
        Button {
            Task { await manager.testProvider(definitionId: definitionId) }
        } label: {
            Group {
                if manager.testStatus[definitionId] == .testing {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 28, height: 28)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(manager.testStatus[definitionId] == .testing)
        .localizedHelp("Run a test search")
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        SettingsSection(title: L("Advanced"), icon: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSubsection(label: L("Category preferences"), anchorId: "search.routing") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(
                            "Pick which provider answers first for each kind of search. The rest follow your main list order, with built-in sources as backup.",
                            bundle: .module
                        )
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)

                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(allCategories.enumerated()), id: \.element) { index, category in
                                if index > 0 {
                                    Divider().background(theme.primaryBorder)
                                }
                                routingRow(category: category)
                            }
                        }
                    }
                }

                SettingsSubsection(label: L("Custom providers"), anchorId: "search.custom") {
                    customProvidersContent
                }
            }
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
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.accentColor)
                    .frame(width: 16)
                Text(category.capitalized)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Spacer()

                if order.count > 1 {
                    Text("Try first:", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                    tryFirstMenu(category: category, order: order, hasOverride: hasOverride)
                }
            }

            if order.isEmpty {
                Text("No enabled source can search this category.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            } else if order.count == 1 {
                orderChip(rank: 1, definitionId: order[0], isFirst: true)
            } else {
                // Read-only trace of the effective try order; the menu above
                // is the only control, so nothing here needs decoding.
                HStack(spacing: 6) {
                    ForEach(Array(order.enumerated()), id: \.element) { index, id in
                        if index > 0 {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 7, weight: .semibold))
                                .foregroundColor(theme.tertiaryText.opacity(0.6))
                        }
                        orderChip(rank: index + 1, definitionId: id, isFirst: index == 0)
                    }
                }
            }
        }
        .padding(.vertical, 10)
    }

    /// One provider in the try-order trace. The first chip is accent-tinted;
    /// last-resort scrapers are visibly downgraded so the trace matches what
    /// the engine actually does.
    private func orderChip(rank: Int, definitionId: String, isFirst: Bool) -> some View {
        let isLastResort = manager.definition(id: definitionId)?.lastResort == true
        let tint: Color = isLastResort ? theme.warningColor : (isFirst ? theme.accentColor : theme.secondaryText)
        return HStack(spacing: 4) {
            Text(providerDisplayName(definitionId))
                .font(.system(size: 10, weight: isFirst ? .semibold : .regular))
                .foregroundColor(isFirst || isLastResort ? tint : theme.secondaryText)
            if isLastResort {
                Text("last resort", bundle: .module)
                    .font(.system(size: 9))
                    .foregroundColor(theme.warningColor)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(
                isFirst
                    ? theme.accentColor.opacity(0.1)
                    : (isLastResort ? theme.warningColor.opacity(0.08) : theme.tertiaryBackground))
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
        Menu {
            Button {
                manager.setRouting(category: category, order: nil)
            } label: {
                if hasOverride {
                    Text("Default order", bundle: .module)
                } else {
                    Label(L("Default order"), systemImage: "checkmark")
                }
            }
            Divider()
            ForEach(order, id: \.self) { id in
                Button {
                    manager.setRouting(category: category, order: [id])
                } label: {
                    if hasOverride, id == order.first {
                        Label(providerDisplayName(id), systemImage: "checkmark")
                    } else {
                        Text(providerDisplayName(id))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(hasOverride ? providerDisplayName(order.first ?? "") : L("Default order"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.tertiaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var customProvidersContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "Any REST search API (Perplexity, SearXNG, self-hosted…) can be added as a JSON definition — no app update required.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(manager.customDefinitions) { definition in
                HStack(spacing: 10) {
                    Image(systemName: "curlybraces")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(theme.tertiaryBackground))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(definition.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.primaryText)
                        Text(definition.id)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(theme.tertiaryText)
                    }

                    Spacer()

                    Button {
                        copyDefinitionJSON(definition)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 26, height: 26)
                            .background(RoundedRectangle(cornerRadius: 7).fill(theme.tertiaryBackground))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .localizedHelp("Copy definition JSON")

                    Button {
                        manager.deleteCustomDefinition(id: definition.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(theme.errorColor.opacity(0.8))
                            .frame(width: 26, height: 26)
                            .background(RoundedRectangle(cornerRadius: 7).fill(theme.errorColor.opacity(0.1)))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .localizedHelp("Delete this custom provider")
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(theme.cardBorder, lineWidth: 1)
                        )
                )
            }

            // Dashed full-width add affordance so "add" reads as creating a
            // new row, not a global action.
            Button {
                showCustomEditor = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Add custom provider", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(theme.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.inputBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(PlainButtonStyle())
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

/// Selection row for the connect gallery, mirroring `ProviderRowCard`'s
/// treatment (icon tile, hover accent stroke) with search-provider content
/// (pricing note, Recommended badge).
private struct SearchPresetRowCard: View {
    let definition: SearchProviderDefinition
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(
                            LinearGradient(
                                colors: isHovered
                                    ? [theme.accentColor, theme.accentColor.opacity(0.7)]
                                    : [theme.tertiaryBackground, theme.tertiaryBackground],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 42, height: 42)
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(isHovered ? .white : theme.secondaryText)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(definition.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                        if definition.recommended {
                            Text("Recommended", bundle: .module)
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(theme.accentColor.opacity(0.15)))
                                .foregroundColor(theme.accentColor)
                        }
                        if let pricing = definition.pricingNote {
                            Text(pricing)
                                .font(.system(size: 10))
                                .foregroundColor(theme.tertiaryText)
                        }
                    }
                    if let summary = definition.summary {
                        Text(summary)
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

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

// MARK: - Provider card

/// Full-width card for one configured API provider, mirroring the remote
/// provider card treatment: icon tile, capsule status badge, action cluster,
/// enable toggle.
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
    @State private var isHovered = false

    private var isConfigured: Bool {
        manager.configuredProviderIds.contains(definition.id)
    }

    private var isReady: Bool { provider.enabled && isConfigured }

    private var statusColor: Color {
        if !provider.enabled { return theme.tertiaryText }
        if case .failed = manager.testStatus[definition.id] { return theme.errorColor }
        if !isConfigured { return theme.warningColor }
        return theme.successColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                // Icon tile
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(statusColor.opacity(0.12))
                    Image(systemName: "globe.americas.fill")
                        .font(.system(size: 20))
                        .foregroundColor(statusColor)
                }
                .frame(width: 44, height: 44)

                // Info
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("#\(rank)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(theme.tertiaryText)
                        Text(definition.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                        statusBadge
                    }
                    if let summary = definition.summary {
                        Text(summary)
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Actions
                HStack(spacing: 10) {
                    if showReorder {
                        VStack(spacing: 2) {
                            reorderButton(icon: "chevron.up", disabled: isFirst, action: onMoveUp)
                            reorderButton(icon: "chevron.down", disabled: isLast, action: onMoveDown)
                        }
                    }

                    cardIconButton(icon: nil, help: "Run a test search") {
                        Task { await manager.testProvider(definitionId: definition.id) }
                    }

                    cardIconButton(icon: "key.fill", help: "Update API key", action: onEditKey)

                    Button {
                        showDeleteConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundColor(theme.errorColor.opacity(0.8))
                            .frame(width: 30, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.errorColor.opacity(0.1))
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .localizedHelp("Remove provider and its key")

                    Toggle(
                        "",
                        isOn: Binding(
                            get: { provider.enabled },
                            set: { onToggle($0) }
                        )
                    )
                    .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                    .labelsHidden()
                }
            }
            .padding(16)

            // Test-failure detail
            if case .failed(let message) = manager.testStatus[definition.id] {
                Divider().background(theme.errorColor.opacity(0.3))
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                    Text(message)
                        .font(.system(size: 12))
                        .lineLimit(2)
                }
                .foregroundColor(theme.errorColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.errorColor.opacity(0.05))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(theme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(
                            isReady ? theme.successColor.opacity(0.4) : theme.primaryBorder,
                            lineWidth: 1
                        )
                )
        )
        .scaleEffect(isHovered ? 1.005 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
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
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 12, height: 12)
                Text("Checking…", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(theme.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(theme.accentColor.opacity(0.12)))
        case .ok:
            badge(L("Working"), color: theme.successColor)
        case .failed:
            badge(isConfigured ? L("Key invalid") : L("Needs key"), color: theme.errorColor)
        case nil:
            if !isConfigured {
                badge(L("Needs key"), color: theme.warningColor)
            } else if !provider.enabled {
                badge(L("Off"), color: theme.tertiaryText)
            } else {
                badge(L("Ready"), color: theme.successColor)
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private func reorderButton(icon: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(disabled ? theme.tertiaryText.opacity(0.35) : theme.secondaryText)
                .frame(width: 30, height: 14)
                .background(RoundedRectangle(cornerRadius: 4).fill(theme.tertiaryBackground))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(disabled)
    }

    /// 30×30 tertiary action button. `icon == nil` renders the test action
    /// (bolt, or a spinner while a test is in flight).
    private func cardIconButton(
        icon: String?,
        help: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if icon == nil, manager.testStatus[definition.id] == .testing {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 30, height: 30)
                } else {
                    Image(systemName: icon ?? "bolt.fill")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 30, height: 30)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(icon == nil && manager.testStatus[definition.id] == .testing)
        .localizedHelp(help)
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
                .padding(24)
            }

            sheetFooter
        }
        .frame(width: 560, height: definition == nil ? 560 : 480)
        .background(theme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.primaryBorder, lineWidth: 1)
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

    private var sheetHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.accentColor.opacity(0.2),
                                theme.accentColor.opacity(0.05),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "magnifyingglass")
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
                Group {
                    if let definition {
                        Text("Connect \(definition.name)", bundle: .module)
                    } else {
                        Text("Connect a Search Provider", bundle: .module)
                    }
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(theme.primaryText)

                Group {
                    if definition != nil {
                        Text("Paste your API key — it's verified with a real search", bundle: .module)
                    } else {
                        Text("Choose a service to connect", bundle: .module)
                    }
                }
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(theme.tertiaryBackground))
            }
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

    // MARK: Picker phase

    private var pickerBody: some View {
        VStack(spacing: 10) {
            if manager.addableDefinitions.isEmpty {
                Text("All bundled providers are already connected.", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .padding(.vertical, 24)
            } else {
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

    // MARK: Configure phase

    @ViewBuilder
    private func configureBody(_ definition: SearchProviderDefinition) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let steps = definition.instructions, !steps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(theme.accentColor)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(theme.accentColor.opacity(0.12)))
                            Text(step)
                                .font(.system(size: 12))
                                .foregroundColor(theme.secondaryText)
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
                            .font(.system(size: 11, weight: .medium))
                        Text("Open signup page", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(theme.primaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.tertiaryBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(theme.inputBorder, lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }

            ForEach(definition.secrets ?? []) { field in
                secretField(field)
            }

            HStack(spacing: 4) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                Text("Stored securely in Keychain. Never sent anywhere except this provider.", bundle: .module)
                    .font(.system(size: 11))
            }
            .foregroundColor(theme.tertiaryText)
        }
    }

    private func secretField(_ field: SearchSecretField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(field.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.primaryText)

            SecureField(field.help ?? L("Paste here"), text: binding(for: field.id))
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )

            if let help = field.help {
                Text(help)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
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
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                } else if verified {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(theme.successColor)
                    Text("Connected. You're all set.", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.successColor)
                } else if let error = verifyError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(theme.errorColor)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(theme.errorColor)
                        .lineLimit(2)
                }
            }

            Spacer()

            if definition != nil, initialDefinition == nil {
                Button {
                    selectedDefinition = nil
                    verified = false
                    verifyError = nil
                    values = [:]
                } label: {
                    Text("Back", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.tertiaryBackground)
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }

            if verified {
                Button {
                    dismiss()
                } label: {
                    Text("Done", bundle: .module)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.accentColor)
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(theme.secondaryBackground)
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
                    "Describe any REST search API as JSON. Placeholders: {{query}}, {{max_results}}, {{offset}}, {{page}}, {{start}}, {{time_range}}, {{after_date}}, {{region}}, {{secret.<id>}}.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)

                TextEditor(text: $jsonText)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(theme.inputBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(theme.inputBorder, lineWidth: 1)
                            )
                    )
                    .frame(minHeight: 280)

                if let errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                        Text(errorMessage)
                            .font(.system(size: 11))
                            .lineLimit(3)
                    }
                    .foregroundColor(theme.errorColor)
                }
            }
            .padding(24)

            sheetFooter
        }
        .frame(width: 560, height: 540)
        .background(theme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.primaryBorder, lineWidth: 1)
        )
    }

    private var sheetHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.accentColor.opacity(0.2),
                                theme.accentColor.opacity(0.05),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "slider.horizontal.3")
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
                Text("Custom Provider", bundle: .module)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text("Describe any REST search API as a JSON definition", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(theme.tertiaryBackground))
            }
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

    private var sheetFooter: some View {
        HStack {
            Spacer()
            Button {
                saveDefinition()
            } label: {
                Text("Validate & Save", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.accentColor))
            }
            .buttonStyle(PlainButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(theme.secondaryBackground)
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
            .environment(\.theme, DarkTheme())
    }
#endif
