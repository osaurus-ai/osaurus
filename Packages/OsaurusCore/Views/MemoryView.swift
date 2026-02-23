//
//  MemoryView.swift
//  osaurus
//
//  Memory management UI: user profile, overrides, agents,
//  statistics, core model configuration, and danger zone.
//

import SwiftUI

private func pluralized(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
    count == 1 ? "1 \(singular)" : "\(count) \(plural ?? "\(singular)s")"
}

struct MemoryView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared

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
    @State private var profile: UserProfile?
    @State private var userEdits: [UserEdit] = []
    @State private var processingStats = ProcessingStats()
    @State private var dbSizeBytes: Int64 = 0
    @State private var agentMemoryCounts: [(agent: Agent, count: Int)] = []
    @State private var defaultAgentEntries: [MemoryEntry] = []
    @State private var defaultAgentSummaries: [ConversationSummary] = []
    @State private var modelOptions: [ModelOption] = []

    // MARK: UI State

    @State private var selectedAgent: Agent?
    @State private var hasAppeared = false
    @State private var isLoading = true
    @State private var isRefreshing = false
    @State private var isSyncing = false
    @State private var showProfileEditor = false
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
                    onExport: { _ in },
                    onDelete: { _ in
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            selectedAgent = nil
                        }
                        loadData()
                    },
                    showSuccess: { msg in
                        showToast(msg)
                    }
                )
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
                            Text("Loading memory...")
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

                                profileSection
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
            loadModelOptions()
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
        .sheet(isPresented: $showProfileEditor) {
            ProfileEditSheet(
                profile: profile,
                onSave: { newContent in
                    saveProfileEdit(newContent)
                    showToast("Profile saved")
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
                "This will permanently delete your profile, all working memory entries, conversation summaries, and processing history. This cannot be undone.",
            primaryButton: .destructive("Clear Everything") {
                clearAllMemory()
            },
            secondaryButton: .cancel("Cancel")
        )
    }

    // MARK: - Header

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: "Memory",
            subtitle: "Manage your profile, overrides, and memory configuration"
        ) {
            HeaderIconButton("arrow.clockwise", isLoading: isRefreshing, help: "Refresh") {
                refreshData()
            }
            .accessibilityLabel("Refresh memory data")
        }
    }

    // MARK: - Disabled Banner

    private var disabledBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(theme.warningColor)

            Text("Memory system is disabled. Enable it below to start building memory.")
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)

            Spacer()

            Button {
                config.enabled = true
                MemoryConfigurationStore.save(config)
                loadData()
                showToast("Memory enabled")
            } label: {
                Text("Enable")
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

    // MARK: - User Profile Section

    private var profileSection: some View {
        MemorySection(title: "User Profile", icon: "person.text.rectangle") {
            SectionActionButton(isSyncing ? "Syncing..." : "Sync", icon: "arrow.triangle.2.circlepath") {
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

            SectionActionButton("Edit", icon: "pencil") {
                showProfileEditor = true
            }
        } content: {
            if let profile {
                VStack(alignment: .leading, spacing: 10) {
                    Text(profile.content)
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
                        metadataTag("v\(profile.version)")
                        metadataTag(pluralized(profile.tokenCount, "token"))
                        metadataTag(profile.model)

                        Spacer()

                        Text(Self.formatRelativeDate(profile.generatedAt))
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .help(profile.generatedAt)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13))
                        .foregroundColor(theme.tertiaryText)
                    Text(
                        "No profile generated yet. Chat with Osaurus and the memory system will build your profile automatically."
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
        MemorySection(title: "Your Overrides", icon: "pin.fill", count: userEdits.isEmpty ? nil : userEdits.count) {
            SectionActionButton("Add", icon: "plus") {
                showAddOverride = true
            }
        } content: {
            if userEdits.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13))
                        .foregroundColor(theme.tertiaryText)
                    Text("No overrides set. Add explicit facts that should always be in your profile.")
                        .font(.system(size: 13))
                        .foregroundColor(theme.tertiaryText)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(userEdits.enumerated()), id: \.element.id) { index, edit in
                        if index > 0 {
                            Divider().opacity(0.5)
                        }
                        OverrideRow(
                            edit: edit,
                            onDelete: {
                                removeOverride(id: edit.id)
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
            // Header
            HStack(spacing: 10) {
                Circle()
                    .fill(theme.accentColor)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Default Agent")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)

                    Text("Uses your global chat settings")
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }

                Spacer()

                let totalCount = defaultAgentEntries.count + defaultAgentSummaries.count
                if totalCount > 0 {
                    Text(pluralized(totalCount, "memory", "memories"))
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
                .help("Preview memory context")
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 4)

            if !defaultAgentEntries.isEmpty || !defaultAgentSummaries.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    // Working Memory
                    if !defaultAgentEntries.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "brain.head.profile")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(theme.tertiaryText)
                                Text("WORKING MEMORY")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(theme.tertiaryText)
                                    .tracking(0.3)
                                Text("\(defaultAgentEntries.count)")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(theme.tertiaryText)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(theme.tertiaryBackground))
                            }

                            AgentEntriesPanel(
                                entries: defaultAgentEntries,
                                onDelete: { entryId in
                                    try? MemoryDatabase.shared.deleteMemoryEntry(id: entryId)
                                    defaultAgentEntries.removeAll { $0.id == entryId }
                                }
                            )
                            .frame(maxHeight: 400)
                        }
                    }

                    // Conversation History
                    if !defaultAgentSummaries.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(theme.tertiaryText)
                                Text("CONVERSATION HISTORY")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(theme.tertiaryText)
                                    .tracking(0.3)
                                Text("\(defaultAgentSummaries.count)")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(theme.tertiaryText)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(theme.tertiaryBackground))
                            }

                            ScrollView {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(defaultAgentSummaries.enumerated()), id: \.element.id) {
                                        index,
                                        summary in
                                        if index > 0 {
                                            Divider().opacity(0.5)
                                        }
                                        MemorySummaryRow(summary: summary)
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
        MemorySection(title: "Agents", icon: "person.2") {
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
                        AgentMemoryRow(
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
        MemorySection(title: "Statistics", icon: "chart.bar") {
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
        MemorySection(title: "Configuration", icon: "gearshape") {
            VStack(alignment: .leading, spacing: 14) {
                // Core Model picker
                HStack(spacing: 12) {
                    Text("Core Model")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 100, alignment: .leading)

                    Picker(
                        "",
                        selection: Binding(
                            get: { config.coreModelIdentifier },
                            set: { newValue in
                                let parts = newValue.split(separator: "/", maxSplits: 1)
                                if parts.count == 2 {
                                    config.coreModelProvider = String(parts[0])
                                    config.coreModelName = String(parts[1])
                                } else {
                                    config.coreModelProvider = ""
                                    config.coreModelName = newValue
                                }
                                MemoryConfigurationStore.save(config)
                            }
                        )
                    ) {
                        if !modelOptions.contains(where: { $0.id == config.coreModelIdentifier }) {
                            Text(config.coreModelIdentifier)
                                .tag(config.coreModelIdentifier)
                        }
                        ForEach(modelOptions) { option in
                            Text(option.displayName)
                                .tag(option.id)
                        }
                    }
                    .frame(maxWidth: 280)
                }

                Divider().opacity(0.5)

                // Retention days
                HStack(spacing: 12) {
                    Text("Summary Retention")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 100, alignment: .leading)

                    HStack(spacing: 8) {
                        Stepper("", value: $config.summaryRetentionDays, in: 1 ... 365)
                            .labelsHidden()
                        Text(pluralized(config.summaryRetentionDays, "day"))
                            .font(.system(size: 13))
                            .foregroundColor(theme.primaryText)
                    }
                    .onChange(of: config.summaryRetentionDays) { _, _ in
                        MemoryConfigurationStore.save(config)
                    }
                }

                Divider().opacity(0.5)

                // Enable/Disable toggle
                HStack(spacing: 12) {
                    Text("Status")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 100, alignment: .leading)

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

                Text("DANGER ZONE")
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
                        Text("Clear All Memory")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.primaryText)
                        Text("Permanently delete all memory data including profile, entries, and summaries.")
                            .font(.system(size: 12))
                            .foregroundColor(theme.tertiaryText)
                    }

                    Spacer()

                    Button {
                        showClearConfirmation = true
                    } label: {
                        Text("Clear All")
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
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
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
            let loadedProfile: UserProfile?
            let loadedEdits: [UserEdit]
            let loadedStats: ProcessingStats
            let loadedSize: Int64
            do {
                loadedProfile = try db.loadUserProfile()
            } catch {
                MemoryLogger.database.error("Failed to load profile: \(error)")
                loadedProfile = nil
                loadError = "Failed to load profile"
            }
            do {
                loadedEdits = try db.loadUserEdits()
            } catch {
                MemoryLogger.database.error("Failed to load edits: \(error)")
                loadedEdits = []
                loadError = loadError ?? "Failed to load overrides"
            }
            do {
                loadedStats = try db.processingStats()
            } catch {
                MemoryLogger.database.error("Failed to load stats: \(error)")
                loadedStats = ProcessingStats()
            }
            loadedSize = db.databaseSizeBytes()

            let agentEntries = (try? db.agentIdsWithEntries()) ?? []

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
            let loadedDefaultEntries = (try? db.loadActiveEntries(agentId: defaultId)) ?? []
            let loadedDefaultSummaries = (try? db.loadSummaries(agentId: defaultId)) ?? []

            await MainActor.run {
                profile = loadedProfile
                userEdits = loadedEdits
                processingStats = loadedStats
                dbSizeBytes = loadedSize
                agentMemoryCounts = resolvedCounts
                defaultAgentEntries = loadedDefaultEntries
                defaultAgentSummaries = loadedDefaultSummaries
                isLoading = false
                onComplete?()
                if let loadError {
                    showToast(loadError, isError: true)
                }
            }
        }
    }

    private func loadModelOptions() {
        Task {
            var options: [ModelOption] = []

            if AppConfiguration.shared.foundationModelAvailable {
                options.append(.foundation())
            }

            let localModels = await Task.detached(priority: .userInitiated) {
                ModelManager.discoverLocalModels()
            }.value
            for model in localModels {
                options.append(.fromMLXModel(model))
            }

            let remoteModels = await MainActor.run {
                RemoteProviderManager.shared.cachedAvailableModels()
            }
            for providerInfo in remoteModels {
                for modelId in providerInfo.models {
                    options.append(
                        .fromRemoteModel(
                            modelId: modelId,
                            providerName: providerInfo.providerName,
                            providerId: providerInfo.providerId
                        )
                    )
                }
            }

            await MainActor.run {
                modelOptions = options
            }
        }
    }

    // MARK: - Actions

    private func removeOverride(id: Int) {
        do {
            try MemoryDatabase.shared.deleteUserEdit(id: id)
        } catch {
            MemoryLogger.database.error("Failed to remove override: \(error)")
            showToast("Failed to remove override", isError: true)
        }
        loadData()
    }

    private func addOverride(_ text: String) {
        do {
            try MemoryDatabase.shared.insertUserEdit(text)
            try MemoryDatabase.shared.insertProfileEvent(
                ProfileEvent(
                    agentId: "user",
                    eventType: "user_edit",
                    content: text
                )
            )
        } catch {
            MemoryLogger.database.error("Failed to add override: \(error)")
            showToast("Failed to add override", isError: true)
        }
        loadData()
    }

    private func saveProfileEdit(_ content: String) {
        let tokenCount = max(1, content.count / MemoryConfiguration.charsPerToken)
        var updated =
            profile
            ?? UserProfile(
                content: content,
                tokenCount: tokenCount,
                model: "user",
                generatedAt: Self.iso8601Formatter.string(from: Date())
            )
        updated.content = content
        updated.tokenCount = tokenCount

        do {
            try MemoryDatabase.shared.saveUserProfile(updated)
            try MemoryDatabase.shared.insertProfileEvent(
                ProfileEvent(
                    agentId: "user",
                    eventType: "user_edit",
                    content: "Profile manually edited"
                )
            )
        } catch {
            MemoryLogger.database.error("Failed to save profile: \(error)")
            showToast("Failed to save profile", isError: true)
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

// MARK: - Memory Section Card

private struct MemorySection<Trailing: View, Content: View>: View {
    @Environment(\.theme) private var theme

    let title: String
    let icon: String
    var count: Int? = nil
    let trailing: Trailing
    let content: Content

    init(
        title: String,
        icon: String,
        count: Int? = nil,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.count = count
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                    .frame(width: 20)

                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.primaryText)
                    .tracking(0.5)

                if let count {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(theme.tertiaryBackground)
                        )
                }

                Spacer()

                trailing
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }
}

extension MemorySection where Trailing == EmptyView {
    init(
        title: String,
        icon: String,
        count: Int? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.count = count
        self.trailing = EmptyView()
        self.content = content()
    }
}

// MARK: - Section Action Button

private struct SectionActionButton: View {
    @Environment(\.theme) private var theme

    let title: String
    let icon: String?
    let action: () -> Void

    @State private var isHovering = false

    init(_ title: String, icon: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(isHovering ? theme.accentColor : theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? theme.accentColor.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Override Row

private struct OverrideRow: View {
    @Environment(\.theme) private var theme

    let edit: UserEdit
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(theme.accentColor)
                .frame(width: 6, height: 6)

            Text(edit.content)
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
                .lineLimit(2)

            Spacer()

            if isHovering {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(PlainButtonStyle())
                .transition(.opacity)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Agent Memory Row

private struct AgentMemoryRow: View {
    @Environment(\.theme) private var theme

    let agent: Agent
    let count: Int
    let onSelect: () -> Void
    let onPreviewContext: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(agentColorFor(agent.name))
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.primaryText)

                        if !agent.description.isEmpty {
                            Text(agent.description)
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    Text(pluralized(count, "memory", "memories"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(theme.tertiaryBackground)
                        )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            Button(action: onPreviewContext) {
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
            .help("Preview context for this agent")

            Button(action: onSelect) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? theme.accentColor.opacity(0.06) : Color.clear)
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Profile Edit Sheet

private struct ProfileEditSheet: View {
    let profile: UserProfile?
    let onSave: (String) -> Void

    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @Environment(\.dismiss) private var dismiss
    @State private var editText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit User Profile")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Manually edit your profile content")
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.tertiaryBackground)
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(20)

            Divider().opacity(0.5)

            TextEditor(text: $editText)
                .font(.system(size: 13))
                .padding(12)
                .scrollContentBackground(.hidden)
                .background(theme.inputBackground)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

            Divider().opacity(0.5)

            HStack {
                Text(pluralized(max(1, editText.count / MemoryConfiguration.charsPerToken), "token"))
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
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

                Button {
                    onSave(editText)
                    dismiss()
                } label: {
                    Text("Save")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.accentColor)
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
            }
            .padding(20)
        }
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            editText = profile?.content ?? ""
        }
    }
}

// MARK: - Add Override Sheet

private struct AddOverrideSheet: View {
    let onAdd: (String) -> Void

    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Override")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Enter an explicit fact that should always be in your profile")
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.tertiaryBackground)
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(20)

            Divider().opacity(0.5)

            TextField("e.g., My name is Terence", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(
                                    isFocused ? theme.accentColor.opacity(0.5) : theme.inputBorder,
                                    lineWidth: isFocused ? 1.5 : 1
                                )
                        )
                )
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

            Divider().opacity(0.5)

            HStack {
                Spacer()

                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
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

                Button {
                    guard !trimmedText.isEmpty else { return }
                    onAdd(trimmedText)
                    dismiss()
                } label: {
                    Text("Add")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.accentColor)
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(trimmedText.isEmpty)
                .opacity(trimmedText.isEmpty ? 0.5 : 1)
            }
            .padding(20)
        }
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            isFocused = true
        }
    }
}

// MARK: - Context Preview Item

private struct ContextPreviewItem: Identifiable {
    let id = UUID()
    let text: String
}

// MARK: - Context Preview Sheet

private struct ContextPreviewSheet: View {
    let context: String

    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Memory Context Preview")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text("This is injected before the system prompt on each message")
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
                Spacer()

                Text("~\(pluralized(max(1, context.count / MemoryConfiguration.charsPerToken), "token"))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.tertiaryBackground))

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.tertiaryBackground)
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(20)

            Divider().opacity(0.5)

            ScrollView {
                Text(context)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
    }
}
