//
//  DatabaseHistoryView.swift
//  osaurus
//
//  Audit + run history for the agent (the old Activity tab, now the
//  Database workspace's History section): every dispatched run from
//  the scheduler DB plus a per-run trace pulled from this agent's
//  `_changelog`. The runs list is the master pane, and selecting a row
//  populates the trace on the right. Mirrors §7's "Activity" design.
//

import SwiftUI

enum ActivityRunChatRouting {
    static func sessionBelongsToRun(sessionAgentId: UUID?, runAgentId: UUID) -> Bool {
        (sessionAgentId ?? Agent.defaultId) == runAgentId
    }
}

enum ActivityRunRefreshPolicy {
    static func shouldReload(previouslyLive: Bool, currentlyLive: Bool) -> Bool {
        previouslyLive || currentlyLive
    }
}

enum ActivityRunFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case completed
    case attention

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .all: return "All"
        case .active: return "Active"
        case .completed: return "Done"
        case .attention: return "Attention"
        }
    }

    func includes(_ run: AgentRunRecord, liveRunIds: Set<UUID>) -> Bool {
        switch self {
        case .all:
            return true
        case .active:
            return liveRunIds.contains(run.id)
        case .completed:
            return run.status == .success
        case .attention:
            return run.status == .error || run.status == .interrupted
        }
    }

    static func matchesSearch(_ run: AgentRunRecord, searchText: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return true }
        return run.status.rawValue.lowercased().contains(query)
            || run.triggerKind.rawValue.lowercased().contains(query)
            || run.instructions.lowercased().contains(query)
    }
}

struct DatabaseHistoryView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var backgroundManager = BackgroundTaskManager.shared

    let agentId: UUID

    @State private var runs: [AgentRunRecord] = []
    @State private var filter: ActivityRunFilter = .all
    @State private var searchText = ""
    @State private var selectedRunId: UUID? = nil
    @State private var changelogRows: [ChangelogEntry] = []
    @State private var traceInspection: RunTraceInspection?
    @State private var isLoadingRuns = true
    @State private var isLoadingTrace = false
    @State private var loadError: String? = nil
    @State private var traceLoadError: String?
    @State private var traceLoadRequestID: UUID?
    @State private var traceLoaderTask: Task<TraceLoadResult, Never>?
    @State private var didReconcileInterruptedRuns = false
    @State private var actionError: String?

    init(agentId: UUID) {
        self.agentId = agentId
    }

    var body: some View {
        // Minimums are deliberately conservative: the workspace body is
        // dropped into a Settings detail pane (~750pt at standard width)
        // and HSplitView refuses to compress past the sum of its
        // children's `minWidth`.
        HSplitView {
            runsList
                .frame(minWidth: 210, idealWidth: 300, maxWidth: 420)
            tracePane
                .frame(minWidth: 300, maxWidth: .infinity)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .task { await activityRefreshLoop() }
        .onChange(of: agentId) { _, _ in
            didReconcileInterruptedRuns = false
            actionError = nil
            selectedRunId = nil
            runs = []
            Task { await loadRuns() }
        }
        .onChange(of: selectedRunId) { _, _ in
            actionError = nil
            Task { await loadTrace() }
        }
        .onDisappear { traceLoaderTask?.cancel() }
    }

    private var filteredRuns: [AgentRunRecord] {
        runs.filter { run in
            filter.includes(run, liveRunIds: backgroundManager.liveAgentRunIds)
                && ActivityRunFilter.matchesSearch(run, searchText: searchText)
        }
    }

    @ViewBuilder
    private var runsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Runs", bundle: .module)
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.5)
                    .foregroundColor(theme.tertiaryText)
                Spacer()
                Button {
                    Task { await loadRuns() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            VStack(spacing: 7) {
                Picker("Run status", selection: $filter) {
                    ForEach(ActivityRunFilter.allCases) { value in
                        Text(value.label, bundle: .module).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(theme.tertiaryText)
                    TextField("Search runs", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(theme.secondaryBackground)
                )
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            Divider().foregroundColor(theme.primaryBorder)
            if isLoadingRuns {
                ProgressView().padding(24)
            } else if let loadError {
                Text(loadError)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .padding(16)
            } else if filteredRuns.isEmpty {
                Text(
                    runs.isEmpty
                        ? "No runs yet. When the agent works on a schedule or automation, each run shows up here."
                        : "No runs match this filter.",
                    bundle: .module
                )
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)
                    .padding(24)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(filteredRuns, id: \.id) { run in
                            runRow(run)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.secondaryBackground.opacity(0.25))
    }

    @ViewBuilder
    private func runRow(_ run: AgentRunRecord) -> some View {
        let isSelected = selectedRunId == run.id
        Button {
            selectedRunId = run.id
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    statusIcon(for: run.status)
                    Text(run.status.rawValue.capitalized)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Spacer()
                    Text(run.triggerKind.rawValue)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(theme.tertiaryBackground)
                        )
                }
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                Text(run.instructions)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? theme.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    @ViewBuilder
    private func statusIcon(for status: AgentRunStatus) -> some View {
        switch status {
        case .running:
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundColor(.blue)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
        case .cancelled:
            Image(systemName: "stop.circle.fill")
                .foregroundColor(.orange)
        case .clamped:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)
        case .interrupted:
            Image(systemName: "bolt.slash.circle.fill")
                .foregroundColor(.orange)
        }
    }

    @ViewBuilder
    private var tracePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let runId = selectedRunId, let run = runs.first(where: { $0.id == runId }) {
                traceHeader(for: run)
                Divider().foregroundColor(theme.primaryBorder)
                if isLoadingTrace {
                    ProgressView().padding(24)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if let traceInspection {
                                RunTraceDiagnosticView(inspection: traceInspection)
                            }
                            if let traceLoadError {
                                Text("Changelog unavailable: \(traceLoadError)", bundle: .module)
                                    .font(.system(size: 10))
                                    .foregroundColor(.orange)
                                    .padding(12)
                            }
                            if !changelogRows.isEmpty {
                                changelogSection
                            } else if traceInspection == nil && traceLoadError == nil {
                                Text("No trace artifact or database changes were recorded for this run.", bundle: .module)
                                    .font(.system(size: 12))
                                    .foregroundColor(theme.tertiaryText)
                                    .padding(24)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            } else {
                Text("Select a run to see its trace.", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var changelogSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Database Writes", bundle: .module)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(theme.tertiaryText)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
            ForEach(changelogRows) { row in
                changelogRowView(row)
            }
        }
    }

    @ViewBuilder
    private func traceHeader(for run: AgentRunRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                statusIcon(for: run.status)
                Text(run.status.rawValue.capitalized)
                    .font(.system(size: 12, weight: .semibold))
                Text("·")
                    .foregroundColor(theme.tertiaryText)
                Text(run.triggerKind.rawValue)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                Spacer()
                if let ended = run.endedAt {
                    Text(durationLabel(from: run.startedAt, to: ended))
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
            }
            if let error = run.error, !error.isEmpty {
                Text(error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.red)
                    .lineLimit(3)
            }
            if run.status == .interrupted {
                Text(
                    "Osaurus stopped before this run recorded completion. The model did not report a failure, and the prior stream cannot be resumed.",
                    bundle: .module
                )
                .font(.system(size: 10))
                .foregroundColor(.orange)
            }
            HStack(spacing: 12) {
                if let tin = run.tokensIn {
                    statBadge(label: "in", value: "\(tin)")
                }
                if let tout = run.tokensOut {
                    statBadge(label: "out", value: "\(tout)")
                }
                if let cost = run.costUSD {
                    statBadge(label: "$", value: String(format: "%.4f", cost))
                }
                Spacer()
            }
            Text(run.instructions)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .lineLimit(3)
            HStack(spacing: 8) {
                if run.sessionId != nil
                    || backgroundManager.taskId(forAgentRunId: run.id, agentId: run.agentId) != nil
                {
                    Button {
                        openChat(for: run)
                    } label: {
                        Label {
                            Text("Open Chat", bundle: .module)
                        } icon: {
                            Image(systemName: "bubble.left.and.bubble.right")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                if let taskId = backgroundManager.taskId(
                    forAgentRunId: run.id,
                    agentId: run.agentId
                ) {
                    Button(role: .destructive) {
                        backgroundManager.cancelTask(taskId)
                        Task { await loadRuns() }
                    } label: {
                        Label {
                            Text("Cancel Run", bundle: .module)
                        } icon: {
                            Image(systemName: "stop.fill")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Spacer()
            }
            if let actionError {
                Text(actionError)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func statBadge(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.primaryText)
        }
    }

    @ViewBuilder
    private func changelogRowView(_ row: ChangelogEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(row.op)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.accentColor)
                if let table = row.tableName {
                    Text(table)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                }
                if let pk = row.rowPK {
                    Text(pk)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }
                Spacer()
                Text(row.actor)
                    .font(.system(size: 9))
                    .foregroundColor(theme.tertiaryText)
                Text(row.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
            }
            if let sql = row.sql, !sql.isEmpty {
                Text(sql)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Divider().foregroundColor(theme.primaryBorder), alignment: .bottom)
    }

    private func durationLabel(from start: Date, to end: Date) -> String {
        let seconds = end.timeIntervalSince(start)
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let minutes = Int(seconds) / 60
        let rem = Int(seconds) % 60
        return "\(minutes)m \(rem)s"
    }

    // MARK: - Loading

    @MainActor
    private func loadRuns() async {
        let requestedAgentId = agentId
        let shouldReconcile = !didReconcileInterruptedRuns
        let showInitialSpinner = runs.isEmpty
        if showInitialSpinner { isLoadingRuns = true }
        defer {
            if showInitialSpinner { isLoadingRuns = false }
        }
        do {
            try SchedulerDatabase.shared.open()
            if shouldReconcile {
                _ = try SchedulerDatabase.shared.reconcileInterruptedRuns(
                    startedBefore: backgroundManager.processStartedAt,
                    excluding: backgroundManager.liveAgentRunIds
                )
                didReconcileInterruptedRuns = true
            }
            let refreshedRuns = try await Task.detached(priority: .utility) {
                try SchedulerDatabase.shared.runs(agentId: requestedAgentId, limit: 200)
            }.value
            guard agentId == requestedAgentId else { return }
            runs = refreshedRuns
            loadError = nil
            if let current = selectedRunId,
                runs.contains(where: { $0.id == current })
            {
                // Keep current selection across refreshes.
            } else {
                selectedRunId = runs.first?.id
            }
        } catch {
            loadError = error.localizedDescription
            runs = []
        }
    }

    @MainActor
    private func loadTrace() async {
        traceLoaderTask?.cancel()
        guard let runId = selectedRunId else {
            traceLoaderTask = nil
            traceLoadRequestID = nil
            changelogRows = []
            traceInspection = nil
            traceLoadError = nil
            isLoadingTrace = false
            return
        }
        let requestID = UUID()
        let agentId = agentId
        traceLoadRequestID = requestID
        isLoadingTrace = true

        let task = Task.detached(priority: .userInitiated) {
            DatabaseHistoryTraceLoader.load(agentId: agentId, runId: runId)
        }
        traceLoaderTask = task
        let result = await task.value
        guard traceLoadRequestID == requestID, selectedRunId == runId else {
            return
        }
        traceLoaderTask = nil
        traceInspection = result.inspection
        changelogRows = result.changelogRows
        traceLoadError = result.errorMessage
        isLoadingTrace = false
    }

    @MainActor
    private func activityRefreshLoop() async {
        await loadRuns()
        var previouslyLive = !backgroundManager.liveAgentRunIds.isEmpty
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            let currentlyLive = !backgroundManager.liveAgentRunIds.isEmpty
            if ActivityRunRefreshPolicy.shouldReload(
                previouslyLive: previouslyLive,
                currentlyLive: currentlyLive
            ) {
                await loadRuns()
            }
            previouslyLive = currentlyLive
        }
    }

    @MainActor
    private func openChat(for run: AgentRunRecord) {
        actionError = nil
        if let taskId = backgroundManager.taskId(forAgentRunId: run.id, agentId: run.agentId) {
            backgroundManager.openTaskWindow(taskId)
            return
        }
        guard let sessionId = run.sessionId else {
            actionError = String(localized: "No chat is linked to this run.", bundle: .module)
            return
        }
        if let existing = ChatWindowManager.shared.findWindow(bySessionId: sessionId) {
            guard ActivityRunChatRouting.sessionBelongsToRun(
                sessionAgentId: existing.agentId,
                runAgentId: run.agentId
            ) else {
                actionError = String(
                    localized: "The linked chat belongs to another agent.",
                    bundle: .module
                )
                return
            }
            ChatWindowManager.shared.showWindow(id: existing.id)
            return
        }
        guard let session = ChatSessionStore.load(id: sessionId) else {
            actionError = String(
                localized: "The linked chat is no longer available.",
                bundle: .module
            )
            return
        }
        guard ActivityRunChatRouting.sessionBelongsToRun(
            sessionAgentId: session.agentId,
            runAgentId: run.agentId
        ) else {
            actionError = String(
                localized: "The linked chat belongs to another agent.",
                bundle: .module
            )
            return
        }
        ChatWindowManager.shared.createWindow(
            agentId: run.agentId,
            sessionData: session,
            showImmediately: true
        )
    }
}

private enum DatabaseHistoryTraceLoader {
    static func load(agentId: UUID, runId: UUID) -> TraceLoadResult {
        let traceURL = OsaurusPaths.agentRunTraceFile(agentId: agentId, runId: runId)
        let inspection: RunTraceInspection?
        if FileManager.default.fileExists(atPath: traceURL.path) {
            inspection = RunTraceInspector.inspectFile(at: traceURL)
        } else {
            inspection = nil
        }

        do {
            let sql =
                "SELECT ts, actor, op, table_name, row_pk, sql "
                + "FROM _changelog WHERE run_id = ?1 ORDER BY ts ASC"
            let result = try LocalAgentBridge.shared.query(
                agentId: agentId,
                sql: sql,
                params: [.text(runId.uuidString)]
            )
            let rows: [ChangelogEntry] = result.rows.enumerated().compactMap { (index, row) in
                guard row.count >= 6 else { return nil }
                let timestamp: Int64 = {
                    if case .integer(let value) = row[0] { return value }
                    return 0
                }()
                return ChangelogEntry(
                    index: index,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp)),
                    actor: textValue(row[1]) ?? "",
                    op: textValue(row[2]) ?? "",
                    tableName: textValue(row[3]),
                    rowPK: textValue(row[4]),
                    sql: textValue(row[5])
                )
            }
            return TraceLoadResult(inspection: inspection, changelogRows: rows, errorMessage: nil)
        } catch {
            return TraceLoadResult(
                inspection: inspection,
                changelogRows: [],
                errorMessage: error.localizedDescription
            )
        }
    }

    private static func textValue(_ value: AgentSQLValue) -> String? {
        if case .text(let value) = value { return value }
        return nil
    }
}

private struct TraceLoadResult: Sendable {
    let inspection: RunTraceInspection?
    let changelogRows: [ChangelogEntry]
    let errorMessage: String?
}

fileprivate struct ChangelogEntry: Identifiable, Sendable {
    var id: Int { index }
    let index: Int
    let timestamp: Date
    let actor: String
    let op: String
    let tableName: String?
    let rowPK: String?
    let sql: String?
}
