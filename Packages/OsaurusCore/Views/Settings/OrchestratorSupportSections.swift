//
//  OrchestratorSupportSections.swift
//  osaurus
//
//  Settings → Orchestrator building blocks that are not delegation policy:
//
//   • `OrchestratorModelReadinessRow` — the Orchestrator's current model, its
//     context window, and whether tools (configure + delegate) can run on it,
//     with a recommended-model hint when they cannot.
//   • `OrchestratorWorkingFolderSection` — the folder the Orchestrator reads
//     (`file_read` / `file_search`) and folder-less subagents inherit
//     read/write. Persists to `DefaultAgentConfiguration` through
//     `AgentManager.updateWorkingFolder(for: Agent.defaultId)`, the same
//     record the chat Folder chip writes.
//   • `OrchestratorDelegationsSection` — Sent / Received delegation rows
//     (agent, task, duration, tok/s, artifacts, Open Chat) backed by the
//     persisted child sessions and live background tasks.
//

import AppKit
import SwiftUI

// MARK: - Model readiness

struct OrchestratorModelReadinessRow: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var pickerCache = ModelPickerItemCache.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    /// Pure readiness verdict for one model id, unit-testable.
    struct Verdict: Equatable {
        enum Tools: Equatable { case ok, limited, off }
        let modelName: String?
        let contextLength: Int?
        let tools: Tools
        let hint: String?

        static func make(modelId: String?) -> Verdict {
            guard let modelId, !modelId.trimmingCharacters(in: .whitespaces).isEmpty else {
                return Verdict(
                    modelName: nil,
                    contextLength: nil,
                    tools: .off,
                    hint: L("Pick a model in Chat settings or the model picker so the Orchestrator can run.")
                )
            }
            let info = ContextSizeResolver.resolve(modelId: modelId)
            if info.sizeClass.disablesTools {
                return Verdict(
                    modelName: modelId,
                    contextLength: info.contextLength,
                    tools: .off,
                    hint: L(
                        "This model's context window is too small for tools, so the Orchestrator cannot configure Osaurus or delegate. Choose a model with at least a 16K context (a 7B+ instruct model works well)."
                    )
                )
            }
            if info.prefersCompactPrompt || info.sizeClass != .normal {
                return Verdict(
                    modelName: modelId,
                    contextLength: info.contextLength,
                    tools: .limited,
                    hint: L(
                        "Tools work, but this model gets a compact prompt. A larger model (14B+ or a cloud model) follows delegation instructions more reliably."
                    )
                )
            }
            return Verdict(modelName: modelId, contextLength: info.contextLength, tools: .ok, hint: nil)
        }
    }

    private var verdict: Verdict {
        Verdict.make(modelId: agentManager.effectiveModel(for: Agent.defaultId))
    }

    var body: some View {
        let verdict = verdict
        return SettingsRow(
            title: "Model Readiness",
            anchorId: "settings.orchestrator.modelReadiness"
        ) {
            VStack(alignment: .leading, spacing: theme.space.s2) {
                HStack(spacing: theme.space.s6) {
                    Text(verdict.modelName ?? L("No model selected"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("orchestrator.readiness.model")
                    Text(verbatim: "·")
                    if let ctx = verdict.contextLength {
                        Text(verbatim: L("Context: \(Self.formatTokens(ctx))"))
                    } else {
                        Text("Context: unknown", bundle: .module)
                    }
                }
                if let hint = verdict.hint {
                    Text(verbatim: hint)
                }
            }
        } trailing: {
            StatusChip(toolsLabel(for: verdict.tools), tone: tone(for: verdict.tools), icon: icon(for: verdict.tools))
        }
    }

    static func formatTokens(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM tokens", Double(value) / 1_000_000) }
        if value >= 1_000 { return "\(value / 1_000)K tokens" }
        return "\(value) tokens"
    }

    private func toolsLabel(for tools: Verdict.Tools) -> String {
        switch tools {
        case .ok: return L("Tools: OK")
        case .limited: return L("Tools: limited")
        case .off: return L("Tools: off")
        }
    }

    private func icon(for tools: Verdict.Tools) -> String {
        switch tools {
        case .ok: return "checkmark.circle.fill"
        case .limited: return "exclamationmark.triangle.fill"
        case .off: return "xmark.octagon.fill"
        }
    }

    private func tone(for tools: Verdict.Tools) -> StatusChip.Tone {
        switch tools {
        case .ok: return .success
        case .limited: return .warning
        case .off: return .error
        }
    }
}

// MARK: - Working folder

struct OrchestratorWorkingFolderSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var recentFolders = RecentFoldersStore.shared

    @State private var folderPath: String? = nil

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        SettingsSection(
            title: "Working Folder",
            subtitle:
                "The Orchestrator reads this folder to brief subagents and to read what they produce. Subagents without a folder of their own work here with full read/write access, so deliverables land where you can find them."
        ) {
            HStack(spacing: theme.space.s12) {
                Text(folderPath ?? L("No folder selected"))
                    .font(SettingsFont.rowTitle)
                    .foregroundColor(folderPath == nil ? theme.text.tertiary : theme.text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("orchestrator.workingFolderPath")
                Spacer()
                SettingsButton(.secondary, folderPath == nil ? "Choose…" : "Change…", icon: "folder", size: .compact) {
                    chooseFolder()
                }
                .accessibilityIdentifier("orchestrator.chooseWorkingFolder")
                if folderPath != nil {
                    SettingsIconButton("xmark", help: "Clear working folder", size: .compact) {
                        agentManager.clearWorkingFolder(for: Agent.defaultId)
                        folderPath = nil
                    }
                    .accessibilityIdentifier("orchestrator.clearWorkingFolder")
                }
            }
            .settingsRowChrome()
            .settingsLandingAnchor("settings.orchestrator.workingFolder")

            if !recentFolders.entries.isEmpty {
                RecentFoldersList(activePath: folderPath, showsPath: true, horizontalInset: 0) { entry in
                    applyRecent(entry)
                }
                .environment(\.theme, theme)
            }
        }
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .agentUpdated)) { _ in reload() }
    }

    private func reload() {
        folderPath = agentManager.workingFolder(for: Agent.defaultId)?.path
    }

    private func chooseFolder() {
        Task { @MainActor in
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.title = L("Select Working Folder")
            panel.message = L("Choose the folder the Orchestrator and its subagents work inside.")
            panel.prompt = L("Select")
            guard await panel.beginModal() == .OK, let url = panel.url else { return }
            guard let bookmark = FolderContextService.makeSecurityScopedBookmark(for: url) else {
                ToastManager.shared.error(L("Failed to grant folder access"))
                return
            }
            let path = url.standardizedFileURL.path
            agentManager.updateWorkingFolder(for: Agent.defaultId, bookmark: bookmark, path: path)
            RecentFoldersStore.shared.record(path: path, bookmark: bookmark)
            folderPath = path
        }
    }

    private func applyRecent(_ entry: RecentFoldersStore.Entry) {
        Task { @MainActor in
            guard let url = await RecentFoldersStore.resolveURL(for: entry) else {
                recentFolders.remove(path: entry.path)
                ToastManager.shared.error(L("Folder no longer available"), message: entry.path)
                return
            }
            let bookmark = await Task.detached(priority: .userInitiated) {
                FolderContextService.makeSecurityScopedBookmark(for: url)
            }.value
            guard let bookmark else {
                ToastManager.shared.error(L("Failed to grant folder access"))
                return
            }
            let path = url.standardizedFileURL.path
            agentManager.updateWorkingFolder(for: Agent.defaultId, bookmark: bookmark, path: path)
            recentFolders.record(path: path, bookmark: bookmark)
            folderPath = path
        }
    }
}

// MARK: - Delegations

struct OrchestratorDelegationsSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var backgroundTasks = BackgroundTaskManager.shared

    @State private var direction: DelegationRecord.Direction = .sent
    @State private var sent: [DelegationRecord] = []
    @State private var received: [DelegationRecord] = []
    @State private var refreshTick = 0

    private var theme: ThemeProtocol { themeManager.currentTheme }

    private var rows: [DelegationRecord] { direction == .sent ? sent : received }

    var body: some View {
        SettingsSection(
            title: "Delegations",
            subtitle: direction == .sent
                ? "Every task the Orchestrator (or a custom agent) handed to a subagent. Open a chat to read the full worker transcript."
                : "Runs of your shared agents that teammates' Osaurus instances dispatched to this Mac over a workspace relay."
        ) {
            VStack(alignment: .leading, spacing: theme.space.s12) {
                HStack {
                    AssignedBaseSegmentedPicker(
                        selection: $direction,
                        options: [
                            .init(DelegationRecord.Direction.sent, L("Sent"), verbatim: true),
                            .init(DelegationRecord.Direction.received, L("Received"), verbatim: true),
                        ]
                    )
                    .accessibilityLabel(Text("Delegations", bundle: .module))
                    .accessibilityIdentifier("orchestrator.delegations.direction")
                    Spacer()
                    SettingsIconButton("arrow.clockwise", help: "Refresh", size: .compact) {
                        reload()
                    }
                }
                .settingsLandingAnchor("settings.orchestrator.delegations")

                if rows.isEmpty {
                    SettingsEmptyState(
                        inline: "arrow.triangle.branch",
                        title: direction == .sent ? "No delegations yet" : "No received runs yet"
                    )
                } else {
                    VStack(spacing: theme.space.s6) {
                        ForEach(rows) { row in
                            delegationRow(row)
                        }
                    }
                }
            }
        }
        .onAppear { reload() }
        .onReceive(backgroundTasks.objectWillChange) { _ in
            // Live status changes (queued → running → completed) refresh the
            // list; coalesced by the small state hop so a busy run doesn't
            // re-read the DB per token.
            refreshTick += 1
        }
        .task(id: refreshTick) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            reload()
        }
    }

    private func reload() {
        let loaded = DelegationRecordLoader.load()
        sent = loaded.sent
        received = loaded.received
    }

    private func delegationRow(_ row: DelegationRecord) -> some View {
        HStack(alignment: .top, spacing: theme.space.s10) {
            Image(systemName: statusIcon(row.status))
                .glyphSize(.footnote, weight: .semibold)
                .foregroundColor(statusColor(row.status))
                .frame(width: 14)
                .padding(.top, theme.space.s2)
            VStack(alignment: .leading, spacing: theme.space.s2) {
                HStack(spacing: theme.space.s6) {
                    Text(verbatim: row.agentName)
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(1)
                    if let workspace = row.workspaceName {
                        Text(verbatim: "@\(workspace)")
                            .font(SettingsFont.footnote)
                            .foregroundColor(theme.text.secondary)
                    }
                    if let caller = row.callerLabel {
                        Text(verbatim: L("from \(caller)"))
                            .font(SettingsFont.footnote)
                            .foregroundColor(theme.text.secondary)
                    }
                    if row.needsInput {
                        StatusChip(L("Needs input"), tone: .warning)
                    }
                }
                Text(verbatim: row.task)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(verbatim: metrics(row))
                    .font(SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
            }
            Spacer(minLength: 8)
            SettingsButton(.tertiary, "Open Chat", size: .compact) {
                openChat(row)
            }
            .accessibilityIdentifier("orchestrator.delegations.openChat")
        }
        .padding(theme.space.s8)
        .settingsChrome(.subtle)
    }

    /// Compact "status · 1m 12s · 42.5 tok/s · 2 files" line. Pure, for tests.
    static func metricsLine(_ row: DelegationRecord) -> String {
        var parts: [String] = [statusLabel(row.status)]
        parts.append(Self.formatDuration(row.duration))
        if let tps = row.tokensPerSecond {
            parts.append(String(format: "%.1f tok/s", tps))
        }
        if let tokens = row.completionTokens {
            parts.append("\(tokens) tokens")
        }
        if row.artifactCount > 0 {
            parts.append(row.artifactCount == 1 ? "1 file" : "\(row.artifactCount) files")
        }
        return parts.joined(separator: " · ")
    }

    private func metrics(_ row: DelegationRecord) -> String {
        Self.metricsLine(row)
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }

    static func statusLabel(_ status: DelegationRecord.Status) -> String {
        switch status {
        case .queued: return L("Queued")
        case .running: return L("Running")
        case .waitingForInput: return L("Waiting for input")
        case .completed: return L("Completed")
        case .failed: return L("Failed")
        case .cancelled: return L("Cancelled")
        }
    }

    private func statusIcon(_ status: DelegationRecord.Status) -> String {
        switch status {
        case .queued: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .waitingForInput: return "questionmark.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "minus.circle"
        }
    }

    private func statusColor(_ status: DelegationRecord.Status) -> Color {
        switch status {
        case .queued, .running: return theme.status.info.foreground
        case .waitingForInput: return theme.status.warning.foreground
        case .completed: return theme.status.success.foreground
        case .failed: return theme.status.error.foreground
        case .cancelled: return theme.text.tertiary
        }
    }

    private func openChat(_ row: DelegationRecord) {
        if row.isLive, BackgroundTaskManager.shared.taskState(for: row.id) != nil {
            BackgroundTaskManager.shared.openTaskWindow(row.id)
            return
        }
        let db = ConversationStores.current
        if !db.isOpenNonBlocking { try? db.open() }
        guard let session = db.loadSession(id: row.id) else {
            ToastManager.shared.error(L("This delegation's chat is no longer available."))
            return
        }
        ChatWindowManager.shared.openHistorySession(session)
    }
}
