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
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon(for: verdict.tools))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(color(for: verdict.tools))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verdict.modelName ?? L("No model selected"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("orchestrator.readiness.model")
                    HStack(spacing: 6) {
                        if let ctx = verdict.contextLength {
                            Text(verbatim: L("Context: \(Self.formatTokens(ctx))"))
                        } else {
                            Text("Context: unknown", bundle: .module)
                        }
                        Text(verbatim: "·")
                        Text(verbatim: toolsLabel(for: verdict.tools))
                    }
                    .font(.system(size: 10))
                    .foregroundColor(theme.secondaryText)
                }
                Spacer()
            }
            if let hint = verdict.hint {
                Text(verbatim: hint)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.tertiaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
        )
        .settingsLandingAnchor("settings.orchestrator.modelReadiness")
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

    private func color(for tools: Verdict.Tools) -> Color {
        switch tools {
        case .ok: return theme.successColor
        case .limited: return theme.warningColor
        case .off: return theme.errorColor
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
        SettingsSection(title: "Working Folder", icon: "folder") {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    "The Orchestrator reads this folder to brief subagents and to read what they produce. Subagents without a folder of their own work here with full read/write access, so deliverables land where you can find them.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Text(folderPath ?? L("No folder selected"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(folderPath == nil ? theme.tertiaryText : theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("orchestrator.workingFolderPath")
                    Spacer()
                    Button {
                        chooseFolder()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                                .font(.system(size: 10, weight: .semibold))
                            Text(folderPath == nil ? L("Choose…") : L("Change…"))
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(theme.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.accentColor.opacity(0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(theme.accentColor.opacity(0.2), lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("orchestrator.chooseWorkingFolder")
                    if folderPath != nil {
                        Button {
                            agentManager.clearWorkingFolder(for: Agent.defaultId)
                            folderPath = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(theme.tertiaryText)
                                .padding(6)
                        }
                        .buttonStyle(.plain)
                        .help(L("Clear working folder"))
                        .accessibilityIdentifier("orchestrator.clearWorkingFolder")
                    }
                }
                .settingsLandingAnchor("settings.orchestrator.workingFolder")

                if !recentFolders.entries.isEmpty {
                    RecentFoldersList(activePath: folderPath, showsPath: true, horizontalInset: 0) { entry in
                        applyRecent(entry)
                    }
                    .environment(\.theme, theme)
                    .padding(.top, 4)
                }
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
        SettingsSection(title: "Delegations", icon: "list.bullet.rectangle") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("", selection: $direction) {
                        Text("Sent", bundle: .module).tag(DelegationRecord.Direction.sent)
                        Text("Received", bundle: .module).tag(DelegationRecord.Direction.received)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                    .accessibilityIdentifier("orchestrator.delegations.direction")
                    Spacer()
                    Button {
                        reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .help(L("Refresh"))
                }
                .settingsLandingAnchor("settings.orchestrator.delegations")

                Text(
                    direction == .sent
                        ? "Every task the Orchestrator (or a custom agent) handed to a subagent. Open a chat to read the full worker transcript."
                        : "Runs of your shared agents that teammates' Osaurus instances dispatched to this Mac over a workspace relay.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

                if rows.isEmpty {
                    Text(
                        direction == .sent ? "No delegations yet." : "No received runs yet.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .padding(.vertical, 8)
                } else {
                    VStack(spacing: 6) {
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
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusIcon(row.status))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(statusColor(row.status))
                .frame(width: 14)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: row.agentName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    if let workspace = row.workspaceName {
                        Text(verbatim: "@\(workspace)")
                            .font(.system(size: 10))
                            .foregroundColor(theme.secondaryText)
                    }
                    if let caller = row.callerLabel {
                        Text(verbatim: L("from \(caller)"))
                            .font(.system(size: 10))
                            .foregroundColor(theme.secondaryText)
                    }
                    if row.needsInput {
                        Text("Needs input", bundle: .module)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(theme.warningColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(theme.warningColor.opacity(0.12)))
                    }
                }
                Text(verbatim: row.task)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(verbatim: metrics(row))
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }
            Spacer(minLength: 8)
            Button {
                openChat(row)
            } label: {
                Text("Open Chat", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("orchestrator.delegations.openChat")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.tertiaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
        )
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
        case .queued, .running: return theme.accentColor
        case .waitingForInput: return theme.warningColor
        case .completed: return theme.successColor
        case .failed: return theme.errorColor
        case .cancelled: return theme.tertiaryText
        }
    }

    private func openChat(_ row: DelegationRecord) {
        if row.isLive, BackgroundTaskManager.shared.taskState(for: row.id) != nil {
            BackgroundTaskManager.shared.openTaskWindow(row.id)
            return
        }
        let db = ChatHistoryDatabase.shared
        try? db.open()
        guard let session = db.loadSession(id: row.id) else {
            ToastManager.shared.error(L("This delegation's chat is no longer available."))
            return
        }
        ChatWindowManager.shared.openHistorySession(session)
    }
}
