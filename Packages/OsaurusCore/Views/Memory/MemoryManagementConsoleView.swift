//
//  MemoryManagementConsoleView.swift
//  osaurus
//
//  User-visible console for inspecting, searching, disabling, forgetting,
//  and diagnosing stored memory.
//

import SwiftUI

struct MemoryManagementConsoleView: View {
    @Environment(\.theme) private var theme

    let agents: [Agent]
    let onMemoryChanged: () -> Void
    let showToast: (String, Bool) -> Void

    private let service = MemoryManagementConsoleService()

    @State private var searchText = ""
    @State private var scope: MemoryConsoleScope = .all
    @State private var agentFilter = MemoryAgentFilter.all
    @State private var includeDisabled = false
    @State private var isLoading = false
    @State private var showDiagnostics = false
    @State private var showContextPreview = false
    @State private var snapshot: MemoryConsoleSnapshot?
    @State private var selectedItem: MemoryConsoleItem?
    @State private var pendingAction: PendingMemoryConsoleAction?
    @State private var previewQuery = ""
    @State private var previewAgentId = Agent.defaultId.uuidString
    @State private var previewTokenLimit = 800
    @State private var contextPreview: MemoryContextPreview?
    @State private var isPreviewLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s14) {
            searchToolbar
            filtersRow

            if showDiagnostics, let health = snapshot?.health {
                diagnosticsPanel(health)
            }

            if showContextPreview {
                contextPreviewPanel
            }

            ThemeHairlineDivider()

            resultsPanel
        }
        .padding(theme.space.s16)
        .settingsChrome(.card)
        .onAppear {
            if snapshot == nil { refresh() }
        }
        .sheet(item: $selectedItem) { item in
            MemoryConsoleInspectSheet(item: item)
                .frame(minWidth: 560, minHeight: 520)
        }
        .themedAlert(
            pendingAction?.title ?? L("Memory Action"),
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            message: pendingAction?.message,
            primaryButton: .destructive(pendingAction?.buttonTitle ?? L("Confirm")) {
                performPendingAction()
            },
            secondaryButton: .cancel(L("Cancel")) {
                pendingAction = nil
            },
            presentationStyle: .contained
        )
    }

    private var searchToolbar: some View {
        HStack(spacing: theme.space.s10) {
            SearchField(text: $searchText, placeholder: "Search memories", fillsAvailableWidth: true)
                .onSubmit { refresh() }
                .onChange(of: searchText) { _, newValue in
                    if newValue.isEmpty { refresh() }
                }

            if isLoading {
                SettingsSpinner()
            }

            consoleToggleButton(
                title: "Storage health",
                icon: "stethoscope",
                isActive: showDiagnostics
            ) {
                showDiagnostics.toggle()
                if showDiagnostics { refresh() }
            }

            consoleToggleButton(
                title: "Context preview",
                icon: "doc.text.magnifyingglass",
                isActive: showContextPreview
            ) {
                showContextPreview.toggle()
            }
        }
    }

    private var filtersRow: some View {
        HStack(spacing: theme.space.s12) {
            AssignedBaseSegmentedPicker(
                selection: $scope,
                options: MemoryConsoleScope.allCases.map { .init($0, $0.displayName) }
            )
            .fixedSize()
            .onChange(of: scope) { _, _ in refresh() }

            SettingsMenuPicker(selection: $agentFilter) {
                Text("All agents", bundle: .module).tag(MemoryAgentFilter.all)
                Text(Agent.default.displayName).tag(MemoryAgentFilter.defaultAgent)
                ForEach(agents) { agent in
                    Text(agent.displayName).tag(MemoryAgentFilter.agent(agent.id.uuidString))
                }
            }
            .accessibilityLabel(Text("Agent", bundle: .module))
            .onChange(of: agentFilter) { _, _ in refresh() }

            Toggle(isOn: $includeDisabled) {
                Text("Include disabled", bundle: .module)
                    .font(SettingsFont.caption)
            }
            .settingsCheckbox()
            .onChange(of: includeDisabled) { _, _ in refresh() }

            Spacer(minLength: 0)
        }
    }

    private func consoleToggleButton(
        title: String,
        icon: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        FilterChip(
            String(localized: String.LocalizationValue(title), bundle: .module),
            icon: icon,
            isSelected: isActive,
            action: action
        )
    }

    private var contextPreviewPanel: some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            HStack(spacing: theme.space.s8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .glyphSize(.footnote, weight: .semibold)
                    .foregroundColor(theme.text.link)
                Text("Bounded context preview", bundle: .module)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.tertiary)
                Spacer()
                Text("~\(previewTokenLimit) tokens", bundle: .module)
                    .font(SettingsFont.smallLabel)
                    .foregroundColor(theme.text.secondary)
            }

            HStack(spacing: theme.space.s10) {
                SettingsTextField(placeholder: L("Preview query"), text: $previewQuery)

                SettingsMenuPicker(selection: $previewAgentId) {
                    Text(Agent.default.displayName).tag(Agent.defaultId.uuidString)
                    ForEach(agents) { agent in
                        Text(agent.displayName).tag(agent.id.uuidString)
                    }
                }
                .settingsFieldAccessibility(L("Preview Agent"))
                .frame(width: 190)

                SettingsStepper(value: $previewTokenLimit, range: 100 ... 2000, step: 100)
                    .settingsFieldAccessibility(L("Preview token limit"))

                Button {
                    loadContextPreview()
                } label: {
                    Image(systemName: "eye")
                        .glyphSize(.caption, weight: .semibold)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(isPreviewLoading)
                .help(Text("Preview bounded memory context", bundle: .module))
            }

            if isPreviewLoading {
                HStack(spacing: theme.space.s8) {
                    SettingsSpinner()
                    Text("Assembling preview...", bundle: .module)
                        .font(SettingsFont.caption)
                        .foregroundColor(theme.text.tertiary)
                }
            } else if let contextPreview {
                VStack(alignment: .leading, spacing: theme.space.s6) {
                    HStack {
                        Text(
                            contextPreview.wasEmpty
                                ? "No context assembled"
                                : "Preview context",
                            bundle: .module
                        )
                        .textStyle(.footnote, weight: 600)
                        .foregroundColor(theme.text.secondary)

                        Spacer()

                        if contextPreview.redactedContext.redactionCount > 0 {
                            let count = contextPreview.redactedContext.redactionCount
                            Text(
                                count == 1 ? L("1 redaction") : L("\(count) redactions")
                            )
                            .font(SettingsFont.smallLabel)
                            .foregroundColor(theme.status.warning.foreground)
                        }
                    }

                    Text(contextPreview.redactedContext.text)
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.primary)
                        .textSelection(.enabled)
                        .lineLimit(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(theme.space.s8)
                        .settingsChrome(.inset)
                }
            }
        }
        .padding(theme.space.s12)
        .settingsChrome(.inset)
    }

    @ViewBuilder
    private func diagnosticsPanel(_ health: MemoryStorageHealth) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            HStack(spacing: theme.space.s8) {
                Circle()
                    .fill(healthColor(health.level))
                    .frame(width: 8, height: 8)
                Text(health.level.displayName)
                    .font(SettingsFont.sectionTitle)
                    .foregroundColor(theme.text.primary)
                Spacer()
                Text(formatBytes(health.databaseSizeBytes))
                    .font(SettingsFont.smallLabel)
                    .foregroundColor(theme.text.secondary)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 126), spacing: theme.space.s8)], spacing: theme.space.s8) {
                healthTile("Pinned", "\(health.activePinnedCount)", footnote: "\(health.disabledPinnedCount) disabled")
                healthTile(
                    "Episodes",
                    "\(health.activeEpisodeCount)",
                    footnote: "\(health.disabledEpisodeCount) disabled"
                )
                healthTile("Transcript", "\(health.transcriptCount)", footnote: "stored turns")
                healthTile(
                    "Pending",
                    "\(health.pendingSignals.totalSignals)",
                    footnote:
                        health.pendingSignals.deadLetteredSignals > 0
                            ? "\(health.pendingSignals.deadLetteredSignals) dead"
                            : "signals"
                )
                healthTile(
                    "Schema",
                    health.schemaVersion.map(String.init) ?? "-",
                    footnote: "expected \(health.expectedSchemaVersion)"
                )
                healthTile("FTS", health.ftsTablesReady ? "Ready" : "Missing", footnote: "text mirrors")
                healthTile(
                    "Vector",
                    health.vectorSearchAvailable ? "Ready" : "Fallback",
                    footnote: "\(health.vectorIndexFailures) failures"
                )
                healthTile(
                    "Logs",
                    "\(health.processingStats.totalCalls)",
                    footnote:
                        "\(health.processingStats.errorCount) err · "
                        + "\(health.processingStats.skippedCount) skipped"
                )
            }

            if !health.diagnostics.isEmpty {
                VStack(alignment: .leading, spacing: theme.space.s4) {
                    ForEach(health.diagnostics, id: \.self) { diagnostic in
                        HStack(alignment: .top, spacing: theme.space.s6) {
                            Image(systemName: "exclamationmark.triangle")
                                .glyphSize(.micro, weight: .medium)
                                .foregroundColor(theme.status.warning.foreground)
                            Text(diagnostic)
                                .font(SettingsFont.rowDescription)
                                .foregroundColor(theme.text.secondary)
                        }
                    }
                }
            }
        }
        .padding(theme.space.s12)
        .settingsChrome(.control)
    }

    private var resultsPanel: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(spacing: theme.space.s8) {
                Text("Results", bundle: .module)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.tertiary)
                if let count = snapshot?.items.count {
                    CountBadge(count)
                }
                Spacer()
                if let generatedAt = snapshot?.generatedAt {
                    Text(generatedAt, style: .time)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                }
            }

            if isLoading && snapshot == nil {
                HStack(spacing: theme.space.s8) {
                    SettingsSpinner()
                    Text("Loading memories...", bundle: .module)
                        .font(SettingsFont.caption)
                        .foregroundColor(theme.text.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, theme.space.s24)
            } else if let items = snapshot?.items, !items.isEmpty {
                VStack(spacing: theme.space.s0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            ThemeHairlineDivider()
                        }
                        MemoryConsoleResultRow(
                            item: item,
                            onInspect: { selectedItem = item },
                            onDisable: {
                                pendingAction = PendingMemoryConsoleAction(
                                    mutation: .disable,
                                    item: item
                                )
                            },
                            onForget: {
                                pendingAction = PendingMemoryConsoleAction(
                                    mutation: .forget,
                                    item: item
                                )
                            }
                        )
                    }
                }
                .settingsChrome(.inset)
            } else {
                Text("No memories match this search.", bundle: .module)
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, theme.space.s24)
            }
        }
    }

    private func healthTile(_ label: String, _ value: String, footnote: String) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s2) {
            Text(label)
                .font(SettingsFont.chip)
                .foregroundColor(theme.text.tertiary)
            Text(value)
                .font(SettingsFont.cardTitle)
                .foregroundColor(theme.text.primary)
                .lineLimit(1)
            Text(footnote)
                .font(SettingsFont.footnote)
                .foregroundColor(theme.text.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(theme.space.s8)
        .settingsChrome(.surface)
    }

    private func refresh() {
        guard !isLoading else { return }
        isLoading = true
        let query = MemoryConsoleQuery(
            text: searchText,
            scope: scope,
            agentId: agentFilter.agentId,
            includeDisabled: includeDisabled,
            limit: 80
        )
        Task {
            do {
                let next = try await service.snapshot(query: query)
                await MainActor.run {
                    snapshot = next
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    let message = L("Failed to load memory console: \(error.localizedDescription)")
                    showToast(message, true)
                }
            }
        }
    }

    private func loadContextPreview() {
        guard !isPreviewLoading else { return }
        isPreviewLoading = true
        Task {
            let preview = await service.contextPreview(
                agentId: previewAgentId,
                query: previewQuery.isEmpty ? searchText : previewQuery,
                maxTokens: previewTokenLimit
            )
            await MainActor.run {
                contextPreview = preview
                isPreviewLoading = false
            }
        }
    }

    private func performPendingAction() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        Task {
            do {
                let result: MemoryConsoleMutationResult
                switch action.mutation {
                case .disable:
                    result = try await service.disable(itemId: action.item.id)
                case .forget:
                    result = try await service.forget(itemId: action.item.id)
                }
                await MainActor.run {
                    showToast(result.message, !result.changed && action.mutation == .forget)
                    refresh()
                    onMemoryChanged()
                }
            } catch {
                await MainActor.run {
                    let message = L("Memory action failed: \(error.localizedDescription)")
                    showToast(message, true)
                }
            }
        }
    }

    private func healthColor(_ level: MemoryStorageHealth.Level) -> Color {
        switch level {
        case .healthy: return theme.status.success.foreground
        case .degraded: return theme.status.warning.foreground
        case .unavailable: return theme.status.error.foreground
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

private enum MemoryAgentFilter: Hashable {
    case all
    case defaultAgent
    case agent(String)

    var agentId: String? {
        switch self {
        case .all:
            return nil
        case .defaultAgent:
            return Agent.defaultId.uuidString
        case .agent(let id):
            return id
        }
    }
}

private struct PendingMemoryConsoleAction {
    let mutation: MemoryConsoleMutation
    let item: MemoryConsoleItem

    var title: String {
        switch mutation {
        case .disable: return L("Disable Memory?")
        case .forget: return L("Forget Memory?")
        }
    }

    var buttonTitle: String {
        switch mutation {
        case .disable: return L("Disable")
        case .forget: return L("Forget")
        }
    }

    var message: String {
        switch mutation {
        case .disable:
            return L("This removes the memory from future recall while keeping the row available for diagnostics.")
        case .forget:
            return L(
                "This permanently deletes the selected memory row and removes its vector document when present."
            )
        }
    }
}

private struct MemoryConsoleResultRow: View {
    @Environment(\.theme) private var theme

    let item: MemoryConsoleItem
    let onInspect: () -> Void
    let onDisable: () -> Void
    let onForget: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: theme.space.s10) {
            Image(systemName: icon)
                .glyphSize(.caption, weight: .semibold)
                .foregroundColor(item.isDisabled ? theme.text.tertiary : theme.text.link)
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(theme.surface.hover)
                )

            VStack(alignment: .leading, spacing: theme.space.s6) {
                HStack(spacing: theme.space.s6) {
                    Text(LocalizedStringKey(item.kind.displayName), bundle: .module)
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)
                    if item.isDisabled {
                        StatusChip(L("Disabled"), tone: .warning)
                    }
                    if item.preview.redactionCount > 0 {
                        StatusChip(L("Redacted"), tone: .neutral)
                    }
                    Spacer()
                }

                Text(item.preview.text)
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(item.relevanceExplanation)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                    .lineLimit(2)
            }

            HStack(spacing: theme.space.s4) {
                iconButton("info.circle", help: "Inspect memory", action: onInspect)
                iconButton("pause.circle", help: "Disable memory", action: onDisable)
                    .disabled(!item.canDisable)
                    .opacity(item.canDisable ? 1 : 0.35)
                iconButton("trash", help: "Forget memory", action: onForget)
            }
            .fixedSize()
        }
        .padding(theme.space.s12)
    }

    private var icon: String {
        switch item.kind {
        case .pinnedFact: return "pin.fill"
        case .episode: return "doc.text"
        case .transcriptTurn: return "text.bubble"
        }
    }

    private func iconButton(
        _ systemName: String,
        help: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .glyphSize(.caption, weight: .medium)
                .foregroundColor(theme.text.secondary)
                .frame(width: 26, height: 26)
                .settingsChrome(.inset)
        }
        .buttonStyle(.plain)
        .help(Text(help, bundle: .module))
    }
}

private struct MemoryConsoleInspectSheet: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    let item: MemoryConsoleItem

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack(spacing: theme.space.s0) {
            HStack(alignment: .top, spacing: theme.space.s12) {
                VStack(alignment: .leading, spacing: theme.space.s4) {
                    Text(item.kind.displayName)
                        .font(SettingsFont.detailTitle)
                        .foregroundColor(theme.text.primary)
                    Text(item.relevanceExplanation)
                        .font(SettingsFont.caption)
                        .foregroundColor(theme.text.tertiary)
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .glyphSize(.caption, weight: .semibold)
                        .foregroundColor(theme.text.secondary)
                        .frame(width: 28, height: 28)
                        .settingsChrome(.inset)
                }
                .buttonStyle(.plain)
                .help(Text("Close", bundle: .module))
            }
            .padding(theme.space.s16)

            ThemeHairlineDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: theme.space.s16) {
                    inspectBlock("Privacy-safe detail", item.detail.text, monospaced: false)

                    if item.detail.redactionCount > 0 {
                        VStack(alignment: .leading, spacing: theme.space.s6) {
                            Text("Redactions", bundle: .module)
                                .font(SettingsFont.compactLabel)
                                .foregroundColor(theme.text.tertiary)
                            ForEach(item.detail.redactionCounts.keys.sorted(), id: \.self) { key in
                                Text("\(key): \(item.detail.redactionCounts[key] ?? 0)", bundle: .module)
                                    .font(SettingsFont.caption)
                                    .foregroundColor(theme.text.secondary)
                            }
                        }
                    }

                    metadataGrid
                }
                .padding(theme.space.s16)
            }
        }
        .background(theme.surface.canvas)
        .environment(\.theme, themeManager.currentTheme)
    }

    private var metadataGrid: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            Text("Metadata", bundle: .module)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.tertiary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: theme.space.s8)], spacing: theme.space.s8) {
                metadataTile("Storage ID", item.storageId)
                metadataTile("Agent", item.agentId)
                if let status = item.metadata.status { metadataTile("Status", status) }
                if let salience = item.metadata.salience { metadataTile("Salience", "\(Int(salience * 100))%") }
                if let useCount = item.metadata.useCount { metadataTile("Use count", "\(useCount)") }
                if let sourceCount = item.metadata.sourceCount { metadataTile("Sources", "\(sourceCount)") }
                if let sourceEpisodeId = item.metadata.sourceEpisodeId {
                    metadataTile("Source episode", "\(sourceEpisodeId)")
                }
                if let tokenCount = item.metadata.tokenCount { metadataTile("Tokens", "\(tokenCount)") }
                if let conversationId = item.metadata.conversationId {
                    metadataTile("Conversation", conversationId)
                }
                if let chunkIndex = item.metadata.chunkIndex { metadataTile("Chunk", "\(chunkIndex)") }
                if let role = item.metadata.role { metadataTile("Role", role) }
                if let model = item.metadata.model, !model.isEmpty { metadataTile("Model", model) }
                if let createdAt = item.metadata.createdAt { metadataTile("Created", createdAt) }
                if let conversationAt = item.metadata.conversationAt {
                    metadataTile("Conversation at", conversationAt)
                }
                if !item.metadata.tags.isEmpty { metadataTile("Tags", item.metadata.tags.joined(separator: ", ")) }
                if !item.metadata.topics.isEmpty {
                    metadataTile("Topics", item.metadata.topics.joined(separator: ", "))
                }
                if !item.metadata.entities.isEmpty {
                    metadataTile("Entities", item.metadata.entities.joined(separator: ", "))
                }
            }
        }
    }

    private func inspectBlock(_ title: String, _ text: String, monospaced: Bool) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            Text(title)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.tertiary)

            Text(text)
                .textStyle(monospaced ? .code : .bodySmall)
                .foregroundColor(theme.text.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(theme.space.s12)
                .settingsChrome(.inset)
        }
    }

    private func metadataTile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s2) {
            Text(label)
                .font(SettingsFont.chip)
                .foregroundColor(theme.text.tertiary)
            Text(value)
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(theme.space.s8)
        .settingsChrome(.inset)
    }
}
