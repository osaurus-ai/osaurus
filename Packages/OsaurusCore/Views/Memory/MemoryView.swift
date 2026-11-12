//
//  MemoryView.swift
//  osaurus
//
//  v2 memory management UI: identity, pinned facts, episodes,
//  consolidation, statistics, and danger zone.
//

import SwiftUI

// MARK: - Memory Tab

/// Drill-in pages of Memory. Raw values are stable deep-link ids
/// (`memorySubTabRequest`, settings-search `subTab`); `identity` predates
/// the "Profile" title.
enum MemoryTab: String, CaseIterable, SettingsDrillInItem {
    case identity
    case memories
    case agents
    case settings
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .identity: return L("Profile")
        case .memories: return L("Memories")
        case .agents: return L("Agents & Projects")
        case .settings: return L("Settings")
        case .diagnostics: return L("Diagnostics")
        }
    }

    var icon: String {
        switch self {
        case .identity: return "person.text.rectangle"
        case .memories: return "brain"
        case .agents: return "person.2"
        case .settings: return "gearshape"
        case .diagnostics: return "stethoscope"
        }
    }

    var subtitle: String {
        switch self {
        case .identity: return L("What Osaurus knows about you, and overrides it must always follow.")
        case .memories: return L("Pinned facts and episodes, searchable.")
        case .agents: return L("Memory kept per agent and per project.")
        case .settings: return L("Budget, retention, consolidation, and clearing memory.")
        case .diagnostics: return L("Processing queue, logs and recovery tools.")
        }
    }
}

struct MemoryView: View {
    @ObservedObject private var badgeStore = ManagementBadgeStore.shared
    @ObservedObject var themeManager = ThemeManager.shared
    @ObservedObject var agentManager = AgentManager.shared
    @ObservedObject private var appConfig = AppConfiguration.shared
    @ObservedObject private var managementState = ManagementStateManager.shared

    var theme: any ThemeProtocol { themeManager.currentTheme }

    private static let iso8601Formatter = ISO8601DateFormatter()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func formatRelativeDate(_ iso8601: String) -> String {
        guard let date = iso8601Formatter.date(from: iso8601) else { return iso8601 }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: Data State

    // The diagnostics-related state below is internal (not private) so
    // `MemoryView+Diagnostics` (sibling extension file) can read & write
    // it. Swift extensions in another file see `internal` members but
    // not `private` ones — adopting internal here is the simplest way
    // to keep the diagnostics view-builders out of this file without
    // resorting to a view-model wrapper.
    @State var config = MemoryConfiguration.default
    @State private var identity: Identity?
    @State var processingStats = ProcessingStats()
    @State private var dbSizeBytes: Int64 = 0
    @State private var agentMemoryCounts: [(agent: Agent, count: Int)] = []
    /// Shared project-memory namespaces with content. `name` is nil for an
    /// orphan (project deleted but its purge never completed) so the row
    /// can offer cleanup instead of hiding rows the user can't account for.
    @State private var projectMemoryCounts: [(namespaceKey: String, name: String?, count: Int)] = []
    @State private var defaultAgentPinned: [PinnedFact] = []
    @State private var defaultAgentEpisodes: [Episode] = []
    @State var pendingSignals = PendingSignalsSummary()
    @State var totalEpisodes: Int = 0
    @State var totalPinned: Int = 0
    @State var coreModelStatus: CoreModelStatus = .unset
    @State var recentLogs: [ProcessingLogRow] = []
    @State var bufferTelemetry = BufferTurnTelemetry()
    @State var memoryDBOpen: Bool = false
    /// True while a Retry/Reset recovery action is running for the memory
    /// store, so the diagnostics buttons disable to prevent re-entrancy.
    @State var memoryRecoveryRunning: Bool = false
    /// Drives the "Reset memory store?" confirmation before quarantining.
    @State var showMemoryResetConfirm: Bool = false
    @State var chatActive: Bool = false
    @State var distillSnapshot = DistillationCoordinator.Snapshot(queued: 0, active: false)
    @State var probeBufferRunning: Bool = false
    @State var probeBufferResult: BufferProbeOutcome?
    @State var backfillRunning: Bool = false
    @State var backfillProgress = MemoryBackfillProgress()
    @State var backfillTask: Task<Void, Never>?
    @State var backfillSummary: String?
    @State var showBackfillConfirm: Bool = false

    /// Wall-clock timestamp of the last `loadData()` that landed values
    /// on MainActor. Used by the on-appear path to short-circuit when
    /// the user re-enters the Memory tab and our cached state is still
    /// fresh — the in-view mutation sites (`saveIdentityEdit`, override
    /// add/remove, distill, consolidate, clear, etc.) still pass
    /// `forceReload: true` so they always re-fetch.
    @State var lastLoadedAt: Date?

    /// Default freshness window for `.onAppear` refreshes. The Memory
    /// tab opens many SQLite cursors per load; a 10 s window means a
    /// quick tab-toggle round trip (Settings → Memory → Settings →
    /// Memory) no longer re-hits the database.
    static let memoryDataFreshWindow: TimeInterval = 10

    // MARK: UI State

    @State private var selectedTab: MemoryTab?
    @State private var selectedAgent: Agent?
    @State private var hasAppeared = false
    /// Mirrors the sidebar's Developer Tools switch; gates the Diagnostics
    /// tab.
    @State private var showDeveloperDetail = SidebarSectionExpansion.isDeveloperToolsOn

    /// Diagnostics is developer-grade detail: hidden unless the Developer
    /// Tools switch is on — or it's already the active tab (a sub-tab
    /// request landed there), so the selection is never stranded invisibly.
    private var visibleTabs: [MemoryTab] {
        MemoryTab.allCases.filter {
            $0 != .diagnostics || showDeveloperDetail || selectedTab == .diagnostics
        }
    }

    /// Text-backed mirrors of the numeric config knobs, so the Settings
    /// sub-tab can use the shared `SettingsStepperField`. Hydrated in
    /// `loadData()`; edits parse + clamp + persist via `onChange`.
    @State private var tempMemoryBudget: String = ""
    @State private var tempEpisodeRetention: String = ""
    @State private var tempConsolidationInterval: String = ""
    @State private var isLoading = true
    @State private var isRefreshing = false
    @State private var isSyncing = false
    // Internal (not private) so the MemoryView+Diagnostics extension can
    // drive the same "Distill pending" action from the pending-signals row.
    @State var isDistilling = false
    @State private var isConsolidating = false
    @State private var lastConsolidationRun: Date?
    @State private var showIdentityEditor = false
    @State private var showAddOverride = false
    @State private var contextPreviewItem: ContextPreviewItem?
    @State private var showClearConfirmation = false
    @State private var toastMessage: (text: String, isError: Bool)?

    var body: some View {
        ZStack {
            if selectedAgent == nil {
                memoryContent
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }

            if let agent = selectedAgent {
                AgentDetailView(
                    agent: agent,
                    onBack: {
                        withAnimation(theme.motion.springAnimation) {
                            selectedAgent = nil
                        }
                    },
                    onDelete: { _ in
                        withAnimation(theme.motion.springAnimation) {
                            selectedAgent = nil
                        }
                        loadData()
                    },
                    onSwitchAgent: { newAgent in
                        // Same id-based reload pattern as `AgentsView`. Memory's
                        // entry point is read-only context (no Agents grid), so we
                        // just swap the in-memory selection.
                        selectedAgent = newAgent
                    },
                    onSwitchRemoteAgent: { remoteId in
                        // Memory has no remote-agent surface of its own, so hand
                        // off to the Agents tab and let it open the remote detail.
                        ManagementStateManager.shared.pendingRemoteAgentDetailId = remoteId
                        ManagementStateManager.shared.selectedTab = .agents
                    },
                    showSuccess: { msg in
                        showToast(msg)
                    }
                )
                .id(agent.id)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.canvas)
        .environment(\.theme, theme)
    }

    private var memoryContent: some View {
        ZStack {
            VStack(spacing: theme.space.s0) {
                if selectedTab == nil {
                    headerView
                        .settingsHeaderEntrance(hasAppeared: hasAppeared)
                }

                Group {
                    if isLoading {
                        loadingView
                    } else {
                        tabContent
                            .settingsLandingAnchor("memory.settings")
                    }
                }
                .opacity(hasAppeared ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let toast = toastMessage {
                VStack {
                    Spacer()
                    ThemedToastView(toast.text, type: toast.isError ? .error : .success)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, theme.space.s16)
                }
                .zIndex(100)
            }
        }
        .onAppear {
            // Honour a cross-view sub-tab request (e.g. a settings-search result
            // that lands on the Settings sub-tab) before the default selection.
            if let requested = managementState.memorySubTabRequest,
                let tab = MemoryTab(rawValue: requested)
            {
                selectedTab = tab
                managementState.memorySubTabRequest = nil
            }
            loadData(staleAfter: Self.memoryDataFreshWindow)
            applyPendingProjectPreview()
            withAnimation(theme.motion.standard.delay(0.05)) {
                hasAppeared = true
            }
        }
        .onChange(of: managementState.memorySubTabRequest) { _, newValue in
            guard let requested = newValue, let tab = MemoryTab(rawValue: requested) else { return }
            selectedTab = tab
            managementState.memorySubTabRequest = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: SidebarSectionExpansion.changed)) { _ in
            withAnimation(theme.motion.quick) {
                showDeveloperDetail = SidebarSectionExpansion.isDeveloperToolsOn
                // Don't strand the selection on a tab that just disappeared.
                if !showDeveloperDetail, selectedTab == .diagnostics {
                    selectedTab = nil
                }
            }
        }
        // Deep link from a project page's memory section: jump to the Agents
        // subtab and open that project's shared-memory preview.
        .onChange(of: managementState.pendingMemoryProjectPreview) { _, _ in
            applyPendingProjectPreview()
        }
        .sheet(isPresented: $showIdentityEditor) {
            IdentityEditSheet(
                identity: identity,
                onSave: { newContent in
                    saveIdentityEdit(newContent)
                    showToast(L("Profile saved"))
                }
            )
            .frame(minWidth: 500, minHeight: 400)
        }
        .sheet(isPresented: $showAddOverride) {
            AddOverrideSheet(
                onAdd: { text in
                    addOverride(text)
                    showToast(L("Override added"))
                }
            )
            .frame(minWidth: 440, minHeight: 220)
        }
        .sheet(item: $contextPreviewItem) { item in
            ContextPreviewSheet(context: item.text)
                .frame(minWidth: 560, minHeight: 420)
        }
        .themedAlert(
            "Clear All Memory",
            isPresented: $showClearConfirmation,
            message:
                L(
                    "This will permanently delete your identity, all pinned facts, episodes, and conversation history. This cannot be undone."
                ),
            primaryButton: .destructive(L("Clear Everything")) {
                clearAllMemory()
            },
            secondaryButton: .cancel(L("Cancel"))
        )
    }

    // MARK: - Header

    private var headerView: some View {
        SettingsPageHeader(
            title: "Memory",
            subtitle: "What Osaurus remembers about you, your agents and your projects",
            count: badgeStore.headerCount(for: .memory),
            onRefresh: { refreshData() },
            refreshHelp: "Refresh memory data",
            isRefreshing: isRefreshing
        )
    }

    // MARK: - Overview and drill-in pages

    @ViewBuilder
    private var tabContent: some View {
        SettingsDrillInHost(rootTitle: L("Memory"), selection: $selectedTab) {
            ScrollView {
                SettingsPageContent {
                    if !config.enabled {
                        disabledBanner
                    }
                    statsSection
                    SettingsDrillInList(
                        items: visibleTabs,
                        badges: [
                            .memories: totalPinned + totalEpisodes,
                            .agents: agentMemoryCounts.count + projectMemoryCounts.count,
                            .diagnostics: pendingSignals.totalSignals,
                        ]
                    ) { selectedTab = $0 }
                }
            }
        } detail: { tab in
            VStack(spacing: theme.space.s0) {
                SettingsPageHeader(title: tab.title, subtitle: tab.subtitle)
                switch tab {
                case .identity: identityTab
                case .memories: memoriesTab
                case .agents: agentsTab
                case .settings: settingsTab
                case .diagnostics: diagnosticsTab
                }
            }
        }
    }

    private var loadingView: some View {
        SettingsEmptyState(loading: "Loading memory…")
            .settingsPageInsets()
            .frame(maxHeight: .infinity, alignment: .top)
    }

    private var identityTab: some View {
        ScrollView {
            SettingsPageContent {
                identitySection
                overridesSection
            }
        }
    }

    private var memoriesTab: some View {
        ScrollView {
            SettingsPageContent {
                memoryConsoleSection
            }
        }
    }

    private var agentsTab: some View {
        ScrollView {
            SettingsPageContent {
                agentsSection
                if !projectMemoryCounts.isEmpty {
                    projectsSection
                }
            }
        }
    }

    private var settingsTab: some View {
        ScrollView {
            SettingsPageContent {
                configurationSection
                dangerZoneSection
            }
        }
    }

    private var diagnosticsTab: some View {
        ScrollView {
            SettingsPageContent {
                diagnosticsSection
            }
        }
    }

    // MARK: - Disabled Banner

    private var disabledBanner: some View {
        SettingsCallout(
            icon: "exclamationmark.triangle.fill",
            title: "Memory is off",
            message: "Memory system is disabled. Enable it below to start building memory.",
            tone: .warning
        ) {
            SettingsButton(.primary, "Enable", size: .compact) {
                config.enabled = true
                MemoryConfigurationStore.save(config)
                loadData()
                showToast(L("Memory enabled"))
            }
        }
    }

    // MARK: - Identity Section

    private var identitySection: some View {
        SettingsSection(title: "About You") {
            // "Distill pending" goes through `syncNow()` directly. The
            // important difference vs `recoverOrphanedSignals()` (which
            // runs at app launch) is that this path skips the
            // `canDistillCheaply` guard, so it works for users who picked
            // a large local MLX model that isn't resident yet.
            SettingsButton(.secondary, isDistilling ? "Distilling..." : "Distill pending", icon: "wand.and.stars", size: .compact) {
                runDistillPending()
            }
            .disabled(isDistilling || !config.enabled)

            SettingsButton(.secondary, isSyncing ? "Syncing..." : "Sync", icon: "arrow.triangle.2.circlepath", size: .compact) {
                guard !isSyncing else { return }
                isSyncing = true
                Task.detached {
                    await MemoryService.shared.syncNow(force: true)
                    await MainActor.run {
                        isSyncing = false
                        loadData()
                        showToast(L("Sync complete"))
                    }
                }
            }
            .disabled(isSyncing || !config.enabled)

            SettingsButton(.secondary, "Edit", icon: "pencil", size: .compact) {
                showIdentityEditor = true
            }
        } content: {
            if let identity, !identity.content.isEmpty {
                VStack(alignment: .leading, spacing: theme.space.s8) {
                    Text(identity.content)
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.body)
                        .foregroundColor(theme.text.secondary)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, theme.space.s12).padding(.vertical, theme.space.s12)
                        .settingsChrome(.control)

                    HStack(spacing: theme.space.s12) {
                        if identity.version > 0 {
                            metadataTag("v\(identity.version)")
                        }
                        metadataTag(pluralizedMemory(identity.tokenCount, "token"))
                        if !identity.model.isEmpty {
                            metadataTag(identity.model)
                        }

                        Spacer()

                        if !identity.generatedAt.isEmpty {
                            Text(Self.formatRelativeDate(identity.generatedAt))
                                .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                                .foregroundColor(theme.text.tertiary)
                                .help(identity.generatedAt)
                        }
                    }
                }
            } else {
                HStack(spacing: theme.space.s8) {
                    Image(systemName: "info.circle")
                        .glyphSize(.label)
                        .foregroundColor(theme.text.tertiary)
                    Text(
                        "No identity yet. Chat with Osaurus and the memory system will build your identity from session distillations.",
                        bundle: .module
                    )
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.body)
                    .foregroundColor(theme.text.tertiary)
                }
                .padding(.horizontal, theme.space.s12).padding(.vertical, theme.space.s12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsChrome(.control)
            }
        }
    }

    // MARK: - Overrides Section

    private var overridesSection: some View {
        let overrides = identity?.overrides ?? []
        return SettingsSection(
            title: "Your Overrides",
            caption: overrides.isEmpty ? nil : "\(overrides.count)"
        ) {
            SettingsButton(.secondary, "Add", icon: "plus", size: .compact) {
                showAddOverride = true
            }
        } content: {
            if overrides.isEmpty {
                HStack(spacing: theme.space.s8) {
                    Image(systemName: "info.circle")
                        .glyphSize(.label)
                        .foregroundColor(theme.text.tertiary)
                    Text(
                        "No overrides set. Add explicit facts that should always be in your identity.",
                        bundle: .module
                    )
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.body)
                    .foregroundColor(theme.text.tertiary)
                }
            } else {
                ForEach(Array(overrides.enumerated()), id: \.offset) { index, content in
                    MemoryOverrideRow(
                        content: content,
                        onDelete: {
                            removeOverride(index: index)
                            showToast(L("Override removed"))
                        }
                    )
                }
            }
        }
    }

    // MARK: - Default Agent Summary Row

    /// Compact default-agent entry for the Agents tab. Full browsing of the
    /// default agent's pinned facts / episodes now lives in the Memories
    /// console (its agent filter has a Default Agent option), so this row
    /// only surfaces the memory count, a context preview, and a jump into
    /// the Memories tab — no more duplicated pinned/episode panels.
    private var defaultAgentSummaryRow: some View {
        LibraryRow(
            title: L("Default Agent"),
            subtitle: L("Uses your global memory settings")
        ) {
            Circle()
                .fill(theme.action.primary.default.background)
                .frame(width: 8, height: 8)
        } trailing: {
            let totalCount = defaultAgentPinned.count + defaultAgentEpisodes.count
            if totalCount > 0 {
                MemoryCountLabel(count: totalCount)
            }
            SettingsIconButton("eye", help: "Preview memory context", size: .compact) {
                Task {
                    let cfg = MemoryConfigurationStore.load()
                    let ctx = await MemoryContextAssembler.assembleContext(
                        agentId: Agent.defaultId.uuidString,
                        config: cfg
                    )
                    let trimmed = ctx.trimmingCharacters(in: .whitespacesAndNewlines)
                    let text =
                        trimmed.isEmpty
                        ? L("(No memory context assembled — memory may be empty or disabled)")
                        : trimmed
                    contextPreviewItem = ContextPreviewItem(text: text)
                }
            }
            SettingsButton(
                .secondary, "Browse in Memories", icon: "rectangle.and.text.magnifyingglass", size: .compact,
                help: "Browse the default agent's memories"
            ) {
                withAnimation(theme.motion.quick) {
                    selectedTab = .memories
                }
            }
        }
    }

    // MARK: - Agents Section

    private var memoryConsoleSection: some View {
        MemoryManagementConsoleView(
            agents: agentManager.agents,
            onMemoryChanged: { loadData() },
            showToast: { message, isError in
                showToast(message, isError: isError)
            }
        )
    }

    private var agentsSection: some View {
        SettingsSection(title: "Agents") {
            defaultAgentSummaryRow

            if !agentMemoryCounts.isEmpty {
                ForEach(agentMemoryCounts, id: \.agent.id) { pair in
                    MemoryAgentRow(
                        agent: pair.agent,
                        count: pair.count,
                        onSelect: {
                            withAnimation(theme.motion.springAnimation) {
                                selectedAgent = pair.agent
                            }
                        },
                        onPreviewContext: {
                            Task {
                                let cfg = MemoryConfigurationStore.load()
                                let ctx = await MemoryContextAssembler.assembleContext(
                                    agentId: pair.agent.id.uuidString,
                                    config: cfg
                                )
                                let trimmed = ctx.trimmingCharacters(in: .whitespacesAndNewlines)
                                let text =
                                    trimmed.isEmpty
                                    ? L("(No memory context assembled — memory may be empty or disabled)")
                                    : trimmed
                                contextPreviewItem = ContextPreviewItem(text: text)
                            }
                        }
                    )
                }
            }
        }
    }

    // MARK: - Projects Section

    /// Shared project memory: what each project's chats have contributed to
    /// its `project-<uuid>` namespace. Read-only apart from Forget — grants
    /// and membership are managed on the project pages; this surface exists
    /// so project memory stays inspectable and deletable like agent memory.
    private var projectsSection: some View {
        SettingsSection(title: "Projects") {
            ForEach(projectMemoryCounts, id: \.namespaceKey) { entry in
                MemoryProjectRow(
                    name: entry.name,
                    count: entry.count,
                    onPreviewContext: {
                        // Read stored rows directly instead of going through
                        // `assembleContext`: the assembler's relevance gate
                        // returns `.none` for an empty query, which made this
                        // preview always come back blank even with memories
                        // present. Chat injection is unaffected (it passes the
                        // user's message as the query).
                        Task.detached {
                            let text = Self.projectNamespacePreview(entry.namespaceKey)
                            await MainActor.run {
                                contextPreviewItem = ContextPreviewItem(text: text)
                            }
                        }
                    },
                    onForget: {
                        forgetProjectNamespace(entry.namespaceKey)
                    }
                )
            }
        }
    }

    /// Force-drain every pending signal. Shared by the Identity tab's
    /// "Distill pending" button and the Diagnostics pending-signals row.
    /// Internal so the MemoryView+Diagnostics extension can call it.
    func runDistillPending() {
        guard !isDistilling else { return }
        isDistilling = true
        Task.detached {
            // `force: true` — user explicitly asked, so the
            // coordinator's residency gate is bypassed. Chat-
            // idle wait still applies per-distill so a live
            // chat doesn't get its tok/sec halved.
            await MemoryService.shared.syncNow(force: true)
            await MainActor.run {
                isDistilling = false
                loadData()
                showToast(L("Pending distillation complete"))
            }
        }
    }

    /// Everything stored under a project namespace, formatted like the
    /// "## Shared project memory" block the composer injects. Reads the
    /// rows directly (no relevance gate, no vector search) so the preview
    /// always reflects what's on disk. Blocking DB reads — call off main.
    /// Consume a one-shot deep link to a project's shared memory: switch to
    /// the Agents subtab (where the project rows live) and open its preview.
    private func applyPendingProjectPreview() {
        guard let key = managementState.pendingMemoryProjectPreview else { return }
        managementState.pendingMemoryProjectPreview = nil
        selectedTab = .agents
        Task.detached {
            let text = Self.projectNamespacePreview(key)
            await MainActor.run { contextPreviewItem = ContextPreviewItem(text: text) }
        }
    }

    private nonisolated static func projectNamespacePreview(_ namespaceKey: String) -> String {
        let facts = (try? MemoryDatabase.shared.loadPinnedFacts(agentId: namespaceKey, limit: 50)) ?? []
        let episodes =
            (try? MemoryDatabase.shared.loadEpisodes(agentId: namespaceKey, days: 3650, limit: 50)) ?? []

        var blocks: [String] = []
        if !facts.isEmpty {
            blocks.append(
                "## Things I remember\n" + facts.map { "- \($0.content)" }.joined(separator: "\n"))
        }
        if !episodes.isEmpty {
            let lines = episodes.map { ep in
                "- [\(String(ep.conversationAt.prefix(10)))] \(ep.summary)"
            }
            blocks.append("## What we discussed before\n" + lines.joined(separator: "\n"))
        }
        // Raw turns mirrored on write (immediate memory) — shown so the
        // project's shared memory is inspectable before distillation runs.
        let transcripts =
            (try? MemoryDatabase.shared.loadTranscript(agentId: namespaceKey, days: 3650, limit: 30))
            ?? []
        if !transcripts.isEmpty {
            let lines = transcripts.prefix(30).map { turn -> String in
                let text = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let clipped = text.count > 200 ? String(text.prefix(200)) + "…" : text
                return "- [\(turn.role)] \(clipped)"
            }
            blocks.append("## Recent project notes\n" + lines.joined(separator: "\n"))
        }
        guard !blocks.isEmpty else {
            return L("(No memory context assembled — memory may be empty or disabled)")
        }
        return "## Shared project memory\n\n" + blocks.joined(separator: "\n\n")
    }

    /// Purge one project namespace (rows + vector index + cache) and
    /// refresh. Same path project deletion uses, so no second way to be
    /// wrong.
    private func forgetProjectNamespace(_ namespaceKey: String) {
        Task {
            try? MemoryDatabase.shared.deleteNamespaceData(agentId: namespaceKey)
            await MemorySearchService.shared.purgeNamespaceStorage(agentId: namespaceKey)
            await MemoryContextAssembler.shared.invalidateCache(agentId: namespaceKey)
            await MainActor.run {
                projectMemoryCounts.removeAll { $0.namespaceKey == namespaceKey }
                showToast(L("Project memory cleared"))
                refreshData()
            }
        }
    }

    // MARK: - Diagnostics Section
    //
    // The diagnostics card is large enough to live in its own file —
    // see `MemoryDiagnosticsViews.swift` for `diagnosticsSection`,
    // `runBackfill`, `runBufferProbe`, and all of the row / banner /
    // headline helpers. The state those views read & write is declared
    // above (intentionally non-private so a sibling extension file can
    // see it).

    // MARK: - Statistics Section

    private var statsSection: some View {
        SettingsSection(title: "Statistics") {
            SettingsStatStrip(stats: [
                SettingsStat(label: "Total Calls", value: "\(processingStats.totalCalls)"),
                SettingsStat(label: "Avg Latency", value: "\(processingStats.avgDurationMs)ms"),
                SettingsStat(label: "Success", value: "\(processingStats.successCount)"),
                SettingsStat(label: "Errors", value: "\(processingStats.errorCount)"),
                SettingsStat(label: "Skipped", value: "\(processingStats.skippedCount)"),
                SettingsStat(label: "Database", value: formatBytes(dbSizeBytes)),
            ])
        }
    }

    // MARK: - Configuration Section

    private var configurationSection: some View {
        SettingsSection(title: "Configuration") {
            VStack(alignment: .leading, spacing: theme.space.s12) {
                SettingsToggle(
                    title: "Enable Memory",
                    description: "Build identity and long-term memories from your chats",
                    isOn: $config.enabled
                )
                .settingsLandingAnchor("memory.settings.enabled")
                .onChange(of: config.enabled) { _, _ in
                    MemoryConfigurationStore.save(config)
                }

                SettingsNavigationRow(
                    icon: ManagementTab.modelDefaults.icon,
                    title: "Core Model",
                    subtitle: appConfig.chatConfig.coreModelIdentifier ?? L("Not chosen yet")
                ) {
                    managementState.selectedTab = .modelDefaults
                }

                SettingsStepperRow(
                    label: "Memory Budget",
                    help: "Tokens of memory context injected per turn",
                    text: $tempMemoryBudget,
                    range: 100 ... 4000,
                    step: 100,
                    defaultValue: 800,
                    anchorId: "memory.settings.budget"
                )
                .onChange(of: tempMemoryBudget) { _, newValue in
                    applyConfigEdit(newValue, range: 100 ... 4000, keyPath: \.memoryBudgetTokens)
                }

                SettingsStepperRow(
                    label: "Episode Retention",
                    help: "Days episodes are kept before pruning. 0 keeps them forever",
                    text: $tempEpisodeRetention,
                    range: 0 ... 3650,
                    step: 30,
                    defaultValue: 365,
                    anchorId: "memory.settings.retention"
                )
                .onChange(of: tempEpisodeRetention) { _, newValue in
                    applyConfigEdit(newValue, range: 0 ... 3650, keyPath: \.episodeRetentionDays)
                }

                HStack(alignment: .bottom, spacing: theme.space.s12) {
                    SettingsStepperRow(
                        label: "Consolidation Interval",
                        help: "Hours between decay / dedup / eviction runs",
                        text: $tempConsolidationInterval,
                        range: 1 ... 168,
                        step: 1,
                        defaultValue: 24,
                        anchorId: "memory.settings.consolidation"
                    )
                    .onChange(of: tempConsolidationInterval) { _, newValue in
                        applyConfigEdit(newValue, range: 1 ... 168, keyPath: \.consolidationIntervalHours)
                    }

                    VStack(alignment: .trailing, spacing: theme.space.s4) {
                        Button {
                            guard !isConsolidating else { return }
                            isConsolidating = true
                            Task.detached {
                                let outcome = await MemoryConsolidator.shared.runOnce()
                                await MainActor.run {
                                    isConsolidating = false
                                    loadData()
                                    switch outcome {
                                    case .completed:
                                        showToast(L("Consolidation complete"))
                                    case .skippedAlreadyRunning:
                                        showToast(L("Consolidation is already running"))
                                    case .skippedDisabled:
                                        showToast(L("Enable memory to run consolidation"), isError: true)
                                    case .skippedDatabaseClosed:
                                        showToast(L("Memory database is not open"), isError: true)
                                    }
                                }
                            }
                        } label: {
                            Text(isConsolidating ? "Running..." : "Run Now", bundle: .module)
                        }
                        .assignedSettingsButtonStyle()
                        .disabled(isConsolidating || !config.enabled)

                        HStack(spacing: theme.space.s4) {
                            Text("Last run:", bundle: .module)
                            if let lastConsolidationRun {
                                Text(lastConsolidationRun, style: .relative)
                                Text("ago", bundle: .module)
                            } else {
                                Text("Never", bundle: .module)
                            }
                        }
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                        .help(lastConsolidationRun.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                    }
                    .padding(.bottom, theme.space.s4)
                }
            }
        }
    }

    /// Parses a stepper-field edit, clamps it to `range`, and persists the
    /// config when the value actually changed. Non-numeric text (mid-typing)
    /// is ignored; `loadData()` re-hydrates the field on next visit.
    private func applyConfigEdit(
        _ text: String,
        range: ClosedRange<Int>,
        keyPath: WritableKeyPath<MemoryConfiguration, Int>
    ) {
        guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        guard config[keyPath: keyPath] != clamped else { return }
        config[keyPath: keyPath] = clamped
        MemoryConfigurationStore.save(config)
    }

    // MARK: - Danger Zone

    private var dangerZoneSection: some View {
        SettingsDestructiveZone {
            SettingsDestructiveRow(
                title: "Clear All Memory",
                description: "Permanently delete identity, pinned facts, episodes, and conversation history.",
                actionTitle: "Clear all…"
            ) {
                showClearConfirmation = true
            }
        }
    }

    // MARK: - Helpers

    private func metadataTag(_ text: String) -> some View {
        StatusChip(text, tone: .neutral)
    }

    // MARK: - Data Loading

    private func refreshData() {
        guard !isRefreshing else { return }
        isRefreshing = true
        loadData {
            isRefreshing = false
        }
    }

    func loadData(
        onComplete: (@Sendable @MainActor () -> Void)? = nil,
        staleAfter: TimeInterval = 0
    ) {
        // Skip if the previous load is still within the freshness
        // window. Setting `staleAfter` to 0 (the default) preserves the
        // existing always-reload behavior for in-view mutation
        // callsites; `.onAppear` passes `memoryDataFreshWindow` to
        // avoid the redundant SQLite walk on quick tab revisits.
        if staleAfter > 0,
            let last = lastLoadedAt,
            Date().timeIntervalSince(last) < staleAfter,
            !isLoading
        {
            onComplete?()
            return
        }

        config = MemoryConfigurationStore.load()
        tempMemoryBudget = String(config.memoryBudgetTokens)
        tempEpisodeRetention = String(config.episodeRetentionDays)
        tempConsolidationInterval = String(config.consolidationIntervalHours)
        Task.detached(priority: .userInitiated) {
            let db = MemoryDatabase.shared
            if !db.isOpen {
                do { try db.open() } catch {
                    MemoryLogger.database.error("Failed to open database from MemoryView: \(error)")
                    await MainActor.run {
                        isLoading = false
                        onComplete?()
                        showToast(L("Failed to open memory database"), isError: true)
                    }
                    return
                }
            }
            var loadError: String?
            let loadedIdentity: Identity?
            let loadedStats: ProcessingStats
            let loadedSize: Int64
            do {
                loadedIdentity = try db.loadIdentity()
            } catch {
                MemoryLogger.database.error("Failed to load identity: \(error)")
                loadedIdentity = nil
                loadError = "Failed to load identity"
            }
            do {
                loadedStats = try db.processingStats()
            } catch {
                MemoryLogger.database.error("Failed to load stats: \(error)")
                loadedStats = ProcessingStats()
            }
            loadedSize = db.databaseSizeBytes()

            // Episodes + pinned facts, so episode-only agents (nothing
            // pinned yet) still get a row in the Agents card.
            let agentEntries = (try? db.agentNamespaceCounts()) ?? []

            let agents = await MainActor.run { agentManager.agents }
            // Duplicate-tolerant: two agent files can share an id, and
            // uniqueKeysWithValues traps.
            let agentLookup = Dictionary(
                agents.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let resolvedCounts: [(agent: Agent, count: Int)] = agentEntries.compactMap { pair in
                guard let uuid = UUID(uuidString: pair.agentId),
                    !Agent.isDefaultAgentId(pair.agentId),
                    let agent = agentLookup[uuid]
                else { return nil }
                return (agent: agent, count: pair.count)
            }

            let projectEntries = (try? db.projectNamespaceCounts()) ?? []
            let resolvedProjectCounts: [(namespaceKey: String, name: String?, count: Int)] =
                await MainActor.run {
                    projectEntries.map { pair in
                        let name = MemoryNamespace(key: pair.namespaceKey).flatMap { ns -> String? in
                            guard case .project(let id) = ns else { return nil }
                            return ProjectManager.shared.project(for: id)?.name
                        }
                        return (pair.namespaceKey, name, pair.count)
                    }
                }

            let defaultId = Agent.defaultId.uuidString
            let loadedDefaultPinned = (try? db.loadPinnedFacts(agentId: defaultId, limit: 100)) ?? []
            let loadedDefaultEpisodes = (try? db.loadEpisodes(agentId: defaultId, limit: 50)) ?? []

            // Diagnostics panel data — kept in the same Task so we don't
            // re-open the database three times per refresh.
            let loadedPending = (try? db.pendingSignalsSummary()) ?? PendingSignalsSummary()
            let loadedTotalEpisodes = (try? db.episodeCount()) ?? 0
            let loadedTotalPinned = (try? db.pinnedFactCount()) ?? 0
            let loadedRecentLogs = (try? db.recentProcessingLog(limit: 20)) ?? []
            let loadedCoreModelStatus = await CoreModelService.shared.resolveStatus()
            let loadedTelemetry = await MemoryService.shared.bufferTelemetry()
            let loadedDBOpen = MemoryDatabase.shared.isOpen
            let loadedChatActive = await InferenceLoadCoordinator.shared.chatActive
            let loadedDistillSnapshot = await DistillationCoordinator.shared.snapshot()
            let loadedLastConsolidation = await MemoryConsolidator.shared.lastRunDate

            await MainActor.run {
                identity = loadedIdentity
                lastConsolidationRun = loadedLastConsolidation
                processingStats = loadedStats
                dbSizeBytes = loadedSize
                agentMemoryCounts = resolvedCounts
                projectMemoryCounts = resolvedProjectCounts
                defaultAgentPinned = loadedDefaultPinned
                defaultAgentEpisodes = loadedDefaultEpisodes
                pendingSignals = loadedPending
                totalEpisodes = loadedTotalEpisodes
                totalPinned = loadedTotalPinned
                recentLogs = loadedRecentLogs
                coreModelStatus = loadedCoreModelStatus
                bufferTelemetry = loadedTelemetry
                memoryDBOpen = loadedDBOpen
                chatActive = loadedChatActive
                distillSnapshot = loadedDistillSnapshot
                isLoading = false
                lastLoadedAt = Date()
                onComplete?()
                if let loadError {
                    showToast(loadError, isError: true)
                }
            }
        }
    }

    // MARK: - Actions

    private func removeOverride(index: Int) {
        do {
            try MemoryDatabase.shared.removeIdentityOverride(at: index)
        } catch {
            MemoryLogger.database.error("Failed to remove override: \(error)")
            showToast(L("Failed to remove override"), isError: true)
        }
        loadData()
    }

    private func addOverride(_ text: String) {
        do {
            try MemoryDatabase.shared.appendIdentityOverride(text)
        } catch {
            MemoryLogger.database.error("Failed to add override: \(error)")
            showToast(L("Failed to add override"), isError: true)
        }
        loadData()
    }

    private func saveIdentityEdit(_ content: String) {
        let tokenCount = max(1, content.count / MemoryConfiguration.charsPerToken)
        var updated = identity ?? Identity()
        updated.content = content
        updated.tokenCount = tokenCount
        updated.model = "user"
        updated.generatedAt = Self.iso8601Formatter.string(from: Date())
        if updated.version == 0 { updated.version = 1 }

        do {
            try MemoryDatabase.shared.saveIdentity(updated)
        } catch {
            MemoryLogger.database.error("Failed to save identity: \(error)")
            showToast(L("Failed to save identity"), isError: true)
        }
        loadData()
    }

    private func clearAllMemory() {
        let db = MemoryDatabase.shared
        db.close()
        // Remove the database *and* its -wal/-shm sidecars. Deleting only the
        // main file leaves a stale WAL that SQLite would replay on reopen,
        // resurrecting "cleared" rows or corrupting the fresh database.
        StorageFile.remove(path: OsaurusPaths.memoryDatabaseFile().path)
        try? db.open()
        Task { await MemorySearchService.shared.clearIndex() }
        loadData()
        showToast(L("All memory cleared"))
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    func showToast(_ message: String, isError: Bool = false) {
        // Same rhythm as the General/Chat tabs' success toasts: theme spring
        // in, quick ease out, 2.5 s hold.
        withAnimation(theme.motion.springAnimation) {
            toastMessage = (message, isError)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(theme.motion.quick) {
                toastMessage = nil
            }
        }
    }
}
