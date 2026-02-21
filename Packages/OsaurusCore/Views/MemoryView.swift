//
//  MemoryView.swift
//  osaurus
//
//  Full memory management UI: user profile, overrides, working memory,
//  conversation summaries, model stats, and core model configuration.
//

import SwiftUI

struct MemoryView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var hasAppeared = false
    @State private var config = MemoryConfiguration.default
    @State private var profile: UserProfile?
    @State private var userEdits: [UserEdit] = []
    @State private var recentEvents: [ProfileEvent] = []
    @State private var agentEntries: [(agentId: String, count: Int)] = []
    @State private var summaryStats: (today: Int, thisWeek: Int, total: Int) = (0, 0, 0)
    @State private var processingStats = ProcessingStats()
    @State private var dbSizeBytes: Int64 = 0

    @State private var showProfileEditor = false
    @State private var showAddOverride = false
    @State private var newOverrideText = ""
    @State private var showWorkingMemory = false
    @State private var selectedAgentId: String?
    @State private var selectedAgentEntries: [MemoryEntry] = []
    @State private var showAllEvents = false
    @State private var modelOptions: [ModelOption] = []
    @State private var isSyncing = false

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !config.enabled {
                        disabledBanner
                    }

                    profileSection
                    overridesSection
                    recentEventsSection
                    workingMemorySection
                    summariesSection
                    modelStatsSection
                    footerSection
                }
                .padding(24)
            }
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            loadData()
            loadModelOptions()
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
        .sheet(isPresented: $showProfileEditor) {
            ProfileEditSheet(profile: profile, onSave: { newContent in
                saveProfileEdit(newContent)
            })
            .frame(minWidth: 500, minHeight: 400)
        }
        .sheet(isPresented: $showWorkingMemory) {
            WorkingMemoryListSheet(
                agentId: selectedAgentId ?? "",
                entries: selectedAgentEntries,
                onDelete: { entryId in deleteEntry(entryId) }
            )
            .frame(minWidth: 600, minHeight: 500)
        }
        .sheet(isPresented: $showAddOverride) {
            addOverrideSheet
                .frame(minWidth: 400, minHeight: 200)
        }
    }

    // MARK: - Header

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: "Memory",
            subtitle: "Manage your profile, working memory, and conversation history"
        ) {
            HeaderSecondaryButton(isSyncing ? "Syncing..." : "Sync Now", icon: "arrow.triangle.2.circlepath") {
                guard !isSyncing else { return }
                isSyncing = true
                Task.detached {
                    await MemoryService.shared.syncNow()
                    await MainActor.run {
                        isSyncing = false
                        loadData()
                    }
                }
            }
            .disabled(isSyncing || !config.enabled)

            HeaderSecondaryButton("Refresh", icon: "arrow.clockwise") {
                loadData()
            }
        }
    }

    // MARK: - Disabled Banner

    private var disabledBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text("Memory system is disabled. Enable it below to start building memory.")
                .font(.callout)
                .foregroundColor(theme.secondaryText)
            Spacer()
            Button("Enable") {
                config.enabled = true
                MemoryConfigurationStore.save(config)
                loadData()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(theme.secondaryBackground.opacity(0.5))
        .cornerRadius(8)
    }

    // MARK: - User Profile Section

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("User Profile", systemImage: "person.text.rectangle")
                    .font(.headline)
                    .foregroundColor(theme.primaryText)
                Spacer()
                if let profile {
                    Text("\(profile.tokenCount) tokens")
                        .font(.caption)
                        .foregroundColor(theme.tertiaryText)
                }
                Button("Edit") { showProfileEditor = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            if let profile {
                Text(profile.content)
                    .font(.body)
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(6)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.secondaryBackground.opacity(0.3))
                    .cornerRadius(8)

                Text("v\(profile.version) — Generated \(profile.generatedAt) by \(profile.model)")
                    .font(.caption2)
                    .foregroundColor(theme.tertiaryText)
            } else {
                Text("No profile generated yet. Chat with Osaurus and the memory system will build your profile automatically.")
                    .font(.callout)
                    .foregroundColor(theme.tertiaryText)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.secondaryBackground.opacity(0.3))
                    .cornerRadius(8)
            }
        }
    }

    // MARK: - User Overrides Section

    private var overridesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Your Overrides (\(userEdits.count))", systemImage: "pin.fill")
                    .font(.headline)
                    .foregroundColor(theme.primaryText)
                Spacer()
                Button {
                    showAddOverride = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if userEdits.isEmpty {
                Text("No overrides set. Add explicit facts that should always be in your profile.")
                    .font(.callout)
                    .foregroundColor(theme.tertiaryText)
            } else {
                ForEach(userEdits) { edit in
                    HStack {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundColor(theme.accentColor)
                        Text(edit.content)
                            .font(.body)
                            .foregroundColor(theme.secondaryText)
                        Spacer()
                        Button {
                            removeOverride(id: edit.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(theme.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Recent Profile Events

    private var recentEventsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Recent Profile Updates", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                    .foregroundColor(theme.primaryText)
                Spacer()
                if recentEvents.count > 5 {
                    Button(showAllEvents ? "Show Less" : "View All") {
                        showAllEvents.toggle()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            let eventsToShow = showAllEvents ? recentEvents : Array(recentEvents.prefix(5))

            if eventsToShow.isEmpty {
                Text("No profile updates yet.")
                    .font(.callout)
                    .foregroundColor(theme.tertiaryText)
            } else {
                ForEach(eventsToShow) { event in
                    HStack(spacing: 8) {
                        eventIcon(for: event.eventType)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(event.agentId) — \(event.content)")
                                .font(.callout)
                                .foregroundColor(theme.secondaryText)
                                .lineLimit(2)
                            Text(event.createdAt)
                                .font(.caption2)
                                .foregroundColor(theme.tertiaryText)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func eventIcon(for type: String) -> some View {
        switch type {
        case "contribution":
            Image(systemName: "plus.circle.fill")
                .foregroundColor(.green)
                .font(.caption)
        case "user_edit":
            Image(systemName: "pencil.circle.fill")
                .foregroundColor(.blue)
                .font(.caption)
        case "regeneration":
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .foregroundColor(.orange)
                .font(.caption)
        default:
            Image(systemName: "circle.fill")
                .foregroundColor(theme.tertiaryText)
                .font(.caption)
        }
    }

    // MARK: - Working Memory Section

    private var workingMemorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Working Memory", systemImage: "brain")
                .font(.headline)
                .foregroundColor(theme.primaryText)

            if agentEntries.isEmpty {
                Text("No working memory entries yet. Memories are automatically extracted from conversations.")
                    .font(.callout)
                    .foregroundColor(theme.tertiaryText)
            } else {
                ForEach(agentEntries, id: \.agentId) { item in
                    HStack {
                        let agentName = agentDisplayName(item.agentId)
                        Text(agentName)
                            .font(.body)
                            .foregroundColor(theme.primaryText)
                        Spacer()
                        Text("\(item.count) entries")
                            .font(.callout)
                            .foregroundColor(theme.tertiaryText)
                        Button("View") {
                            selectedAgentId = item.agentId
                            if let entries = try? MemoryDatabase.shared.loadActiveEntries(agentId: item.agentId) {
                                selectedAgentEntries = entries
                            }
                            showWorkingMemory = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Summaries Section

    private var summariesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Conversation Summaries", systemImage: "doc.text")
                    .font(.headline)
                    .foregroundColor(theme.primaryText)
                Spacer()
                HStack(spacing: 4) {
                    Text("Retention:")
                        .font(.caption)
                        .foregroundColor(theme.tertiaryText)
                    Stepper("\(config.summaryRetentionDays) days", value: $config.summaryRetentionDays, in: 1...365)
                        .font(.caption)
                        .labelsHidden()
                    Text("\(config.summaryRetentionDays) days")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                }
                .onChange(of: config.summaryRetentionDays) { _ , _ in
                    MemoryConfigurationStore.save(config)
                }
            }

            HStack(spacing: 24) {
                statCell(label: "Today", value: "\(summaryStats.today)")
                statCell(label: "This Week", value: "\(summaryStats.thisWeek)")
                statCell(label: "Total", value: "\(summaryStats.total)")
            }
        }
    }

    // MARK: - Model Stats Section

    private var modelStatsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Model Stats", systemImage: "chart.bar")
                .font(.headline)
                .foregroundColor(theme.primaryText)

            HStack(spacing: 24) {
                statCell(label: "Total Calls", value: "\(processingStats.totalCalls)")
                statCell(label: "Avg Latency", value: "\(processingStats.avgDurationMs)ms")
                statCell(label: "Success", value: "\(processingStats.successCount)")
                statCell(label: "Errors", value: "\(processingStats.errorCount)")
            }
        }
    }

    // MARK: - Footer Section

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Core Model")
                        .font(.caption)
                        .foregroundColor(theme.tertiaryText)
                    Picker("", selection: Binding(
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
                    )) {
                        if !modelOptions.contains(where: { $0.id == config.coreModelIdentifier }) {
                            Text(config.coreModelIdentifier)
                                .tag(config.coreModelIdentifier)
                        }
                        ForEach(modelOptions) { option in
                            Text(option.displayName)
                                .tag(option.id)
                        }
                    }
                    .frame(maxWidth: 260)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Database")
                        .font(.caption)
                        .foregroundColor(theme.tertiaryText)
                    Text(formatBytes(dbSizeBytes))
                        .font(.callout)
                        .foregroundColor(theme.secondaryText)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Status")
                        .font(.caption)
                        .foregroundColor(theme.tertiaryText)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(config.enabled ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(config.enabled ? "Active" : "Disabled")
                            .font(.callout)
                            .foregroundColor(theme.secondaryText)
                    }
                }

                Spacer()

                Toggle("Enabled", isOn: $config.enabled)
                    .toggleStyle(.switch)
                    .onChange(of: config.enabled) { _, _ in
                        MemoryConfigurationStore.save(config)
                    }
            }
        }
    }

    // MARK: - Add Override Sheet

    private var addOverrideSheet: some View {
        VStack(spacing: 16) {
            Text("Add Override")
                .font(.headline)
                .foregroundColor(theme.primaryText)

            Text("Enter an explicit fact that should always be included in your profile. The memory system will never contradict this.")
                .font(.callout)
                .foregroundColor(theme.secondaryText)

            TextField("e.g., My name is Terence", text: $newOverrideText)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") {
                    newOverrideText = ""
                    showAddOverride = false
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Add") {
                    let text = newOverrideText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    try? MemoryDatabase.shared.insertUserEdit(text)
                    try? MemoryDatabase.shared.insertProfileEvent(ProfileEvent(
                        agentId: "user",
                        eventType: "user_edit",
                        content: text
                    ))
                    newOverrideText = ""
                    showAddOverride = false
                    loadData()
                }
                .buttonStyle(.borderedProminent)
                .disabled(newOverrideText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .background(theme.primaryBackground)
    }

    // MARK: - Helpers

    private func statCell(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.bold())
                .foregroundColor(theme.primaryText)
            Text(label)
                .font(.caption)
                .foregroundColor(theme.tertiaryText)
        }
        .frame(minWidth: 60)
    }

    private func loadData() {
        config = MemoryConfigurationStore.load()
        let db = MemoryDatabase.shared
        if !db.isOpen {
            try? db.open()
        }
        profile = try? db.loadUserProfile()
        userEdits = (try? db.loadUserEdits()) ?? []
        recentEvents = (try? db.loadRecentProfileEvents(limit: 20)) ?? []
        agentEntries = (try? db.agentIdsWithEntries()) ?? []
        summaryStats = (try? db.summaryStats()) ?? (0, 0, 0)
        processingStats = (try? db.processingStats()) ?? ProcessingStats()
        dbSizeBytes = db.databaseSizeBytes()
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

    private func removeOverride(id: Int) {
        try? MemoryDatabase.shared.deleteUserEdit(id: id)
        loadData()
    }

    private func deleteEntry(_ entryId: String) {
        try? MemoryDatabase.shared.deleteMemoryEntry(id: entryId)
        if let agentId = selectedAgentId {
            selectedAgentEntries = (try? MemoryDatabase.shared.loadActiveEntries(agentId: agentId)) ?? []
        }
        loadData()
    }

    private func saveProfileEdit(_ content: String) {
        let tokenCount = max(1, content.count / 4)
        var updated = profile ?? UserProfile(
            content: content,
            tokenCount: tokenCount,
            model: "user",
            generatedAt: ISO8601DateFormatter().string(from: Date())
        )
        updated.content = content
        updated.tokenCount = tokenCount

        try? MemoryDatabase.shared.saveUserProfile(updated)
        try? MemoryDatabase.shared.insertProfileEvent(ProfileEvent(
            agentId: "user",
            eventType: "user_edit",
            content: "Profile manually edited"
        ))
        loadData()
    }

    private func agentDisplayName(_ agentId: String) -> String {
        if let uuid = UUID(uuidString: agentId),
           let agent = agentManager.agent(for: uuid) {
            return agent.name
        }
        return agentId
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Profile Edit Sheet

private struct ProfileEditSheet: View {
    let profile: UserProfile?
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var editText: String = ""

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Edit User Profile")
                    .font(.headline)
                    .foregroundColor(theme.primaryText)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
            }

            TextEditor(text: $editText)
                .font(.body)
                .padding(8)
                .background(theme.secondaryBackground.opacity(0.3))
                .cornerRadius(8)

            HStack {
                Text("\(max(1, editText.count / 4)) tokens")
                    .font(.caption)
                    .foregroundColor(theme.tertiaryText)
                Spacer()
                Button("Save") {
                    onSave(editText)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .background(theme.primaryBackground)
        .onAppear {
            editText = profile?.content ?? ""
        }
    }
}

// MARK: - Working Memory List Sheet

private struct WorkingMemoryListSheet: View {
    let agentId: String
    let entries: [MemoryEntry]
    let onDelete: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var searchText = ""
    @State private var filterType: MemoryEntryType?

    private var filteredEntries: [MemoryEntry] {
        entries.filter { entry in
            if let filterType, entry.type != filterType { return false }
            if !searchText.isEmpty {
                return entry.content.localizedCaseInsensitiveContains(searchText)
            }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Working Memory")
                    .font(.headline)
                    .foregroundColor(theme.primaryText)
                Text("(\(entries.count) entries)")
                    .font(.subheadline)
                    .foregroundColor(theme.tertiaryText)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding(16)

            HStack(spacing: 8) {
                TextField("Search entries...", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                Picker("Type", selection: $filterType) {
                    Text("All Types").tag(nil as MemoryEntryType?)
                    ForEach(MemoryEntryType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type as MemoryEntryType?)
                    }
                }
                .frame(maxWidth: 140)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            Divider()

            if filteredEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundColor(theme.tertiaryText)
                    Text("No entries found")
                        .font(.callout)
                        .foregroundColor(theme.tertiaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredEntries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(entry.type.displayName)
                                    .font(.caption.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(typeColor(entry.type).opacity(0.15))
                                    .foregroundColor(typeColor(entry.type))
                                    .cornerRadius(4)

                                Text(String(format: "%.0f%%", entry.confidence * 100))
                                    .font(.caption)
                                    .foregroundColor(theme.tertiaryText)

                                Spacer()

                                Button {
                                    onDelete(entry.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                        .foregroundColor(.red.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                            }

                            Text(entry.content)
                                .font(.body)
                                .foregroundColor(theme.secondaryText)

                            HStack {
                                if !entry.tags.isEmpty {
                                    Text(entry.tags.joined(separator: ", "))
                                        .font(.caption2)
                                        .foregroundColor(theme.tertiaryText)
                                }
                                Spacer()
                                Text(entry.createdAt)
                                    .font(.caption2)
                                    .foregroundColor(theme.tertiaryText)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .background(theme.primaryBackground)
    }

    private func typeColor(_ type: MemoryEntryType) -> Color {
        switch type {
        case .fact: return .blue
        case .preference: return .purple
        case .decision: return .green
        case .correction: return .orange
        case .commitment: return .red
        case .relationship: return .cyan
        case .skill: return .indigo
        }
    }
}
