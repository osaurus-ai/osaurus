//
//  MemoryView.swift
//  osaurus
//
//  v2 memory management UI: identity, pinned facts, episodes,
//  consolidation, statistics, and danger zone.
//

import SwiftUI

// MARK: - Memory Tab

/// Sub-navigation for the Memory section. Mirrors the house pattern used by
/// `ToolsTab` / `VoiceTab` / `ServerTab` so Memory gets the same
/// `ManagerHeaderWithTabs` + `HeaderTabsRow` chrome as the rest of the app.
enum MemoryTab: String, CaseIterable, AnimatedTabItem {
    case identity
    case memories
    case agents
    case settings
    case diagnostics

    var title: String {
        switch self {
        case .identity: return L("Identity")
        case .memories: return L("Memories")
        case .agents: return L("Agents")
        case .settings: return L("Settings")
        case .diagnostics: return L("Diagnostics")
        }
    }
}

struct MemoryView: View {
    @ObservedObject var themeManager = ThemeManager.shared
    @ObservedObject var agentManager = AgentManager.shared
    @ObservedObject private var appConfig = AppConfiguration.shared
    @ObservedObject private var managementState = ManagementStateManager.shared

    var theme: ThemeProtocol { themeManager.currentTheme }

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
    @State private var processingStats = ProcessingStats()
    @State private var dbSizeBytes: Int64 = 0
    @State private var agentMemoryCounts: [(agent: Agent, count: Int)] = []
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

    @State private var selectedTab: MemoryTab = .identity
    @State private var selectedAgent: Agent?
    @State private var hasAppeared = false

    /// Text-backed mirrors of the numeric config knobs, so the Settings
    /// sub-tab can use the shared `SettingsStepperField`. Hydrated in
    /// `loadData()`; edits parse + clamp + persist via `onChange`.
    @State private var tempMemoryBudget: String = ""
    @State private var tempEpisodeRetention: String = ""
    @State private var tempConsolidationInterval: String = ""
    @State private var isLoading = true
    @State private var isRefreshing = false
    @State private var isSyncing = false
    @State private var isDistilling = false
    @State private var isConsolidating = false
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
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            selectedAgent = nil
                        }
                    },
                    onDelete: { _ in
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
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
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
    }

    private var memoryContent: some View {
        ZStack {
            VStack(spacing: 0) {
                headerView
                    .managerHeaderEntrance(hasAppeared: hasAppeared)

                Group {
                    if isLoading {
                        loadingView
                    } else {
                        VStack(spacing: 0) {
                            if !config.enabled {
                                disabledBanner
                                    .padding(.horizontal, 24)
                                    .padding(.top, 16)
                            }

                            tabContent
                                .settingsLandingAnchor("memory.settings")
                        }
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
                        .padding(.bottom, 20)
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
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
        .onChange(of: managementState.memorySubTabRequest) { _, newValue in
            guard let requested = newValue, let tab = MemoryTab(rawValue: requested) else { return }
            selectedTab = tab
            managementState.memorySubTabRequest = nil
        }
        .sheet(isPresented: $showIdentityEditor) {
            IdentityEditSheet(
                identity: identity,
                onSave: { newContent in
                    saveIdentityEdit(newContent)
                    showToast(L("Identity saved"))
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
        ManagerHeaderWithTabs(
            title: L("Memory"),
            subtitle: L("Manage your identity, overrides, and memory configuration")
        ) {
            HeaderIconButton("arrow.clockwise", isLoading: isRefreshing, help: "Refresh") {
                refreshData()
            }
            .accessibilityLabel(Text("Refresh memory data", bundle: .module))
        } tabsRow: {
            HeaderTabsRow(
                selection: $selectedTab,
                counts: [
                    .memories: totalPinned + totalEpisodes,
                    .agents: agentMemoryCounts.count,
                ],
                badges: [.diagnostics: pendingSignals.totalSignals]
            )
        }
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .identity: identityTab
        case .memories: memoriesTab
        case .agents: agentsTab
        case .settings: settingsTab
        case .diagnostics: diagnosticsTab
        }
    }

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView()
                .controlSize(.small)
                .padding(.bottom, 4)
            Text("Loading memory...", bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var identityTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                identitySection
                overridesSection
            }
            .padding(24)
        }
    }

    private var memoriesTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                memoryConsoleSection
            }
            .padding(24)
        }
    }

    private var agentsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                agentsSection
            }
            .padding(24)
        }
    }

    private var settingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statsSection
                configurationSection
                dangerZoneSection
            }
            .padding(24)
        }
    }

    private var diagnosticsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                diagnosticsSection
            }
            .padding(24)
        }
    }

    // MARK: - Disabled Banner

    private var disabledBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(theme.warningColor)

            Text("Memory system is disabled. Enable it below to start building memory.", bundle: .module)
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)

            Spacer()

            Button {
                config.enabled = true
                MemoryConfigurationStore.save(config)
                loadData()
                showToast(L("Memory enabled"))
            } label: {
                Text("Enable", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.accentColor))
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.warningColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.warningColor.opacity(0.25), lineWidth: 1)
                )
        )
    }

    // MARK: - Identity Section

    private var identitySection: some View {
        MemorySectionCard(title: L("Identity"), icon: "person.text.rectangle") {
            // "Distill pending" goes through `syncNow()` directly. The
            // important difference vs `recoverOrphanedSignals()` (which
            // runs at app launch) is that this path skips the
            // `canDistillCheaply` guard, so it works for users who picked
            // a large local MLX model that isn't resident yet.
            MemorySectionActionButton(
                isDistilling ? L("Distilling...") : L("Distill pending"),
                icon: "wand.and.stars"
            ) {
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
            .disabled(isDistilling || !config.enabled)

            MemorySectionActionButton(isSyncing ? "Syncing..." : "Sync", icon: "arrow.triangle.2.circlepath") {
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

            MemorySectionActionButton("Edit", icon: "pencil") {
                showIdentityEditor = true
            }
        } content: {
            if let identity, !identity.content.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(identity.content)
                        .font(.system(size: 13))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.inputBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(theme.inputBorder, lineWidth: 1)
                                )
                        )

                    HStack(spacing: 12) {
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
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                                .help(identity.generatedAt)
                        }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13))
                        .foregroundColor(theme.tertiaryText)
                    Text(
                        "No identity yet. Chat with Osaurus and the memory system will build your identity from session distillations.",
                        bundle: .module
                    )
                    .font(.system(size: 13))
                    .foregroundColor(theme.tertiaryText)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )
            }
        }
    }

    // MARK: - Overrides Section

    private var overridesSection: some View {
        let overrides = identity?.overrides ?? []
        return MemorySectionCard(
            title: L("Your Overrides"),
            icon: "pin.fill",
            count: overrides.isEmpty ? nil : overrides.count
        ) {
            MemorySectionActionButton("Add", icon: "plus") {
                showAddOverride = true
            }
        } content: {
            if overrides.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13))
                        .foregroundColor(theme.tertiaryText)
                    Text(
                        "No overrides set. Add explicit facts that should always be in your identity.",
                        bundle: .module
                    )
                    .font(.system(size: 13))
                    .foregroundColor(theme.tertiaryText)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(overrides.enumerated()), id: \.offset) { index, content in
                        if index > 0 {
                            Divider().opacity(0.5)
                        }
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
    }

    // MARK: - Default Agent Summary Row

    /// Compact default-agent entry for the Agents tab. Full browsing of the
    /// default agent's pinned facts / episodes now lives in the Memories
    /// console (its agent filter has a Default Agent option), so this row
    /// only surfaces the memory count, a context preview, and a jump into
    /// the Memories tab — no more duplicated pinned/episode panels.
    private var defaultAgentSummaryRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(theme.accentColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text("Default Agent", bundle: .module)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)

                Text("Uses your global memory settings", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
            }

            Spacer()

            let totalCount = defaultAgentPinned.count + defaultAgentEpisodes.count
            if totalCount > 0 {
                Text(pluralizedMemory(totalCount, "memory", "memories"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(theme.tertiaryBackground)
                    )
            }

            Button {
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
            } label: {
                Image(systemName: "eye")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(theme.tertiaryBackground)
                    )
            }
            .buttonStyle(PlainButtonStyle())
            .localizedHelp("Preview memory context")

            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    selectedTab = .memories
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "rectangle.and.text.magnifyingglass")
                        .font(.system(size: 10, weight: .medium))
                    Text("Browse in Memories", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.tertiaryBackground)
                )
            }
            .buttonStyle(PlainButtonStyle())
            .localizedHelp("Browse the default agent's memories")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
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
        MemorySectionCard(title: L("Agents"), icon: "person.2") {
            VStack(spacing: 0) {
                defaultAgentSummaryRow

                if !agentMemoryCounts.isEmpty {
                    Divider()
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)

                    ForEach(Array(agentMemoryCounts.enumerated()), id: \.element.agent.id) { index, pair in
                        if index > 0 {
                            Divider().opacity(0.5)
                        }
                        MemoryAgentRow(
                            agent: pair.agent,
                            count: pair.count,
                            onSelect: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
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
        SettingsSection(title: "Statistics", icon: "chart.bar") {
            HStack(spacing: 0) {
                statBlock(label: "Total Calls", value: "\(processingStats.totalCalls)")
                Divider().frame(height: 36).opacity(0.5)
                statBlock(label: "Avg Latency", value: "\(processingStats.avgDurationMs)ms")
                Divider().frame(height: 36).opacity(0.5)
                statBlock(label: "Success", value: "\(processingStats.successCount)")
                Divider().frame(height: 36).opacity(0.5)
                statBlock(label: "Errors", value: "\(processingStats.errorCount)")
                Divider().frame(height: 36).opacity(0.5)
                statBlock(label: "Database", value: formatBytes(dbSizeBytes))
            }
        }
    }

    // MARK: - Configuration Section

    private var configurationSection: some View {
        SettingsSection(title: "Configuration", icon: "gearshape") {
            VStack(alignment: .leading, spacing: 14) {
                SettingsToggle(
                    title: L("Enable Memory"),
                    description: "Build identity and long-term memories from your chats",
                    isOn: $config.enabled
                )
                .onChange(of: config.enabled) { _, _ in
                    MemoryConfigurationStore.save(config)
                }

                SettingsDivider()

                HStack(spacing: 12) {
                    Text("Core Model", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 140, alignment: .leading)

                    Text(appConfig.chatConfig.coreModelIdentifier ?? "None")
                        .font(.system(size: 13))
                        .foregroundColor(theme.primaryText)

                    Spacer()

                    Text("Change in Settings → General", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }

                SettingsDivider()

                SettingsStepperField(
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

                SettingsStepperField(
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

                HStack(alignment: .bottom, spacing: 12) {
                    SettingsStepperField(
                        label: "Consolidation Interval",
                        help: "Hours between decay / dedup / eviction runs",
                        text: $tempConsolidationInterval,
                        range: 1 ... 168,
                        step: 1,
                        defaultValue: 24
                    )
                    .onChange(of: tempConsolidationInterval) { _, newValue in
                        applyConfigEdit(newValue, range: 1 ... 168, keyPath: \.consolidationIntervalHours)
                    }

                    Button {
                        guard !isConsolidating else { return }
                        isConsolidating = true
                        Task.detached {
                            await MemoryConsolidator.shared.runOnce()
                            await MainActor.run {
                                isConsolidating = false
                                loadData()
                                showToast(L("Consolidation complete"))
                            }
                        }
                    } label: {
                        Text(isConsolidating ? "Running..." : "Run Now", bundle: .module)
                    }
                    .buttonStyle(SettingsButtonStyle())
                    .disabled(isConsolidating || !config.enabled)
                    .padding(.bottom, 20)
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.errorColor)
                    .frame(width: 20)

                Text("DANGER ZONE", bundle: .module)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.errorColor)
                    .tracking(0.5)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clear All Memory", bundle: .module)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.primaryText)
                        Text(
                            "Permanently delete identity, pinned facts, episodes, and conversation history.",
                            bundle: .module
                        )
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                    }

                    Spacer()

                    Button {
                        showClearConfirmation = true
                    } label: {
                        Text("Clear All", bundle: .module)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(theme.errorColor)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.errorColor.opacity(0.1))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(theme.errorColor.opacity(0.3), lineWidth: 1)
                                    )
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.errorColor.opacity(0.2), lineWidth: 1)
                )
        )
    }

    // MARK: - Helpers

    private func metadataTag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(theme.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(theme.tertiaryBackground)
            )
    }

    private func statBlock(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(theme.primaryText)
            Text(LocalizedStringKey(label), bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(LocalizedStringKey(label), bundle: .module) + Text(": \(value)"))
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

            let agentEntries = (try? db.agentIdsWithPinnedFacts()) ?? []

            let agents = await MainActor.run { agentManager.agents }
            let agentLookup = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
            let resolvedCounts: [(agent: Agent, count: Int)] = agentEntries.compactMap { pair in
                guard let uuid = UUID(uuidString: pair.agentId),
                    !Agent.isDefaultAgentId(pair.agentId),
                    let agent = agentLookup[uuid]
                else { return nil }
                return (agent: agent, count: pair.count)
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

            await MainActor.run {
                identity = loadedIdentity
                processingStats = loadedStats
                dbSizeBytes = loadedSize
                agentMemoryCounts = resolvedCounts
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
        withAnimation(theme.springAnimation()) {
            toastMessage = (message, isError)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(theme.animationQuick()) {
                toastMessage = nil
            }
        }
    }
}
