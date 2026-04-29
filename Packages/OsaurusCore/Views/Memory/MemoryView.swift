//
//  MemoryView.swift
//  osaurus
//
//  v2 memory management UI: identity, pinned facts, episodes,
//  consolidation, statistics, and danger zone.
//

import SwiftUI

struct MemoryView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var appConfig = AppConfiguration.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    private static let iso8601Formatter = ISO8601DateFormatter()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static func formatRelativeDate(_ iso8601: String) -> String {
        guard let date = iso8601Formatter.date(from: iso8601) else { return iso8601 }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: Data State

    @State private var config = MemoryConfiguration.default
    @State private var identity: Identity?
    @State private var processingStats = ProcessingStats()
    @State private var dbSizeBytes: Int64 = 0
    @State private var agentMemoryCounts: [(agent: Agent, count: Int)] = []
    @State private var defaultAgentPinned: [PinnedFact] = []
    @State private var defaultAgentEpisodes: [Episode] = []

    // MARK: UI State

    @State private var selectedAgent: Agent?
    @State private var hasAppeared = false
    @State private var isLoading = true
    @State private var isRefreshing = false
    @State private var isSyncing = false
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
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : -10)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

                Group {
                    if isLoading {
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
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                if !config.enabled {
                                    disabledBanner
                                }

                                identitySection
                                overridesSection
                                agentsSection
                                statsSection
                                configurationSection
                                dangerZoneSection
                            }
                            .padding(24)
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
            loadData()
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
        .sheet(isPresented: $showIdentityEditor) {
            IdentityEditSheet(
                identity: identity,
                onSave: { newContent in
                    saveIdentityEdit(newContent)
                    showToast("Identity saved")
                }
            )
            .frame(minWidth: 500, minHeight: 400)
        }
        .sheet(isPresented: $showAddOverride) {
            AddOverrideSheet(
                onAdd: { text in
                    addOverride(text)
                    showToast("Override added")
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
                "This will permanently delete your identity, all pinned facts, episodes, and conversation history. This cannot be undone.",
            primaryButton: .destructive("Clear Everything") {
                clearAllMemory()
            },
            secondaryButton: .cancel("Cancel")
        )
    }

    // MARK: - Header

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: L("Memory"),
            subtitle: L("Manage your identity, overrides, and memory configuration")
        ) {
            HeaderIconButton("arrow.clockwise", isLoading: isRefreshing, help: "Refresh") {
                refreshData()
            }
            .accessibilityLabel(Text("Refresh memory data", bundle: .module))
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
                showToast("Memory enabled")
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
        MemorySectionCard(title: "Identity", icon: "person.text.rectangle") {
            MemorySectionActionButton(isSyncing ? "Syncing..." : "Sync", icon: "arrow.triangle.2.circlepath") {
                guard !isSyncing else { return }
                isSyncing = true
                Task.detached {
                    await MemoryService.shared.syncNow()
                    await MainActor.run {
                        isSyncing = false
                        loadData()
                        showToast("Sync complete")
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
            title: "Your Overrides",
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
                                showToast("Override removed")
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Default Agent Memory Group

    private var defaultAgentMemoryGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(theme.accentColor)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Default Agent", bundle: .module)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)

                    Text("Uses your global chat settings", bundle: .module)
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
                            ? "(No memory context assembled — memory may be empty or disabled)"
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
                .help(Text("Preview memory context", bundle: .module))
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 4)

            if !defaultAgentPinned.isEmpty || !defaultAgentEpisodes.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    if !defaultAgentPinned.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(theme.tertiaryText)
                                Text("PINNED FACTS", bundle: .module)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(theme.tertiaryText)
                                    .tracking(0.3)
                                Text("\(defaultAgentPinned.count)", bundle: .module)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(theme.tertiaryText)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(theme.tertiaryBackground))
                            }

                            PinnedFactsPanel(
                                facts: defaultAgentPinned,
                                onDelete: { factId in
                                    try? MemoryDatabase.shared.deletePinnedFact(id: factId)
                                    defaultAgentPinned.removeAll { $0.id == factId }
                                }
                            )
                            .frame(maxHeight: 400)
                        }
                    }

                    if !defaultAgentEpisodes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(theme.tertiaryText)
                                Text("EPISODES", bundle: .module)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(theme.tertiaryText)
                                    .tracking(0.3)
                                Text("\(defaultAgentEpisodes.count)", bundle: .module)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(theme.tertiaryText)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(theme.tertiaryBackground))
                            }

                            ScrollView {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(defaultAgentEpisodes.enumerated()), id: \.element.id) {
                                        index,
                                        episode in
                                        if index > 0 {
                                            Divider().opacity(0.5)
                                        }
                                        EpisodeRow(episode: episode)
                                    }
                                }
                            }
                            .frame(maxHeight: 300)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.inputBackground.opacity(0.5))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(theme.inputBorder, lineWidth: 1)
                                    )
                            )
                        }
                    }
                }
                .padding(.top, 4)
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
            }
        }
    }

    // MARK: - Agents Section

    private var agentsSection: some View {
        MemorySectionCard(title: "Agents", icon: "person.2") {
            VStack(spacing: 0) {
                defaultAgentMemoryGroup

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
                                        ? "(No memory context assembled — memory may be empty or disabled)"
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

    // MARK: - Statistics Section

    private var statsSection: some View {
        MemorySectionCard(title: "Statistics", icon: "chart.bar") {
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
        MemorySectionCard(title: "Configuration", icon: "gearshape") {
            VStack(alignment: .leading, spacing: 14) {
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

                Divider().opacity(0.5)

                HStack(spacing: 12) {
                    Text("Memory Budget", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 140, alignment: .leading)

                    HStack(spacing: 8) {
                        Stepper("", value: $config.memoryBudgetTokens, in: 100 ... 4000, step: 100)
                            .labelsHidden()
                        Text(pluralizedMemory(config.memoryBudgetTokens, "token"))
                            .font(.system(size: 13))
                            .foregroundColor(theme.primaryText)
                    }
                    .onChange(of: config.memoryBudgetTokens) { _, _ in
                        MemoryConfigurationStore.save(config)
                    }
                }

                Divider().opacity(0.5)

                HStack(spacing: 12) {
                    Text("Episode Retention", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 140, alignment: .leading)

                    HStack(spacing: 8) {
                        Stepper("", value: $config.episodeRetentionDays, in: 0 ... 3650, step: 30)
                            .labelsHidden()
                        Text(
                            config.episodeRetentionDays == 0
                                ? "forever" : pluralizedMemory(config.episodeRetentionDays, "day")
                        )
                        .font(.system(size: 13))
                        .foregroundColor(theme.primaryText)
                    }
                    .onChange(of: config.episodeRetentionDays) { _, _ in
                        MemoryConfigurationStore.save(config)
                    }
                }

                Divider().opacity(0.5)

                HStack(spacing: 12) {
                    Text("Consolidation", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 140, alignment: .leading)

                    HStack(spacing: 8) {
                        Stepper("", value: $config.consolidationIntervalHours, in: 1 ... 168)
                            .labelsHidden()
                        Text("every \(pluralizedMemory(config.consolidationIntervalHours, "hour"))", bundle: .module)
                            .font(.system(size: 13))
                            .foregroundColor(theme.primaryText)
                    }
                    .onChange(of: config.consolidationIntervalHours) { _, _ in
                        MemoryConfigurationStore.save(config)
                    }

                    Spacer()

                    Button {
                        guard !isConsolidating else { return }
                        isConsolidating = true
                        Task.detached {
                            await MemoryConsolidator.shared.runOnce()
                            await MainActor.run {
                                isConsolidating = false
                                loadData()
                                showToast("Consolidation complete")
                            }
                        }
                    } label: {
                        Text(isConsolidating ? "Running..." : "Run Now", bundle: .module)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(theme.tertiaryBackground)
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(isConsolidating || !config.enabled)
                }

                Divider().opacity(0.5)

                HStack(spacing: 12) {
                    Text("Status", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 140, alignment: .leading)

                    HStack(spacing: 8) {
                        Circle()
                            .fill(config.enabled ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(config.enabled ? "Active" : "Disabled")
                            .font(.system(size: 13))
                            .foregroundColor(theme.primaryText)
                    }

                    Spacer()

                    Toggle("", isOn: $config.enabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: config.enabled) { _, _ in
                            MemoryConfigurationStore.save(config)
                        }
                }
            }
        }
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

    private func loadData(onComplete: (@Sendable @MainActor () -> Void)? = nil) {
        config = MemoryConfigurationStore.load()
        Task.detached(priority: .userInitiated) {
            let db = MemoryDatabase.shared
            if !db.isOpen {
                do { try db.open() } catch {
                    MemoryLogger.database.error("Failed to open database from MemoryView: \(error)")
                    await MainActor.run {
                        isLoading = false
                        onComplete?()
                        showToast("Failed to open memory database", isError: true)
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

            await MainActor.run {
                identity = loadedIdentity
                processingStats = loadedStats
                dbSizeBytes = loadedSize
                agentMemoryCounts = resolvedCounts
                defaultAgentPinned = loadedDefaultPinned
                defaultAgentEpisodes = loadedDefaultEpisodes
                isLoading = false
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
            showToast("Failed to remove override", isError: true)
        }
        loadData()
    }

    private func addOverride(_ text: String) {
        do {
            try MemoryDatabase.shared.appendIdentityOverride(text)
        } catch {
            MemoryLogger.database.error("Failed to add override: \(error)")
            showToast("Failed to add override", isError: true)
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
            showToast("Failed to save identity", isError: true)
        }
        loadData()
    }

    private func clearAllMemory() {
        let db = MemoryDatabase.shared
        db.close()
        let dbFile = OsaurusPaths.memoryDatabaseFile()
        try? FileManager.default.removeItem(at: dbFile)
        try? db.open()
        Task { await MemorySearchService.shared.clearIndex() }
        loadData()
        showToast("All memory cleared")
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func showToast(_ message: String, isError: Bool = false) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            toastMessage = (message, isError)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeOut(duration: 0.3)) {
                toastMessage = nil
            }
        }
    }
}
