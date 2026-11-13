//
//  DatabaseHistoryView.swift
//  osaurus
//
//  Audit + run history for the agent (the old Activity tab, now the
//  Database workspace's History section): the agent's tasks plus a
//  per-run trace pulled from this agent's `_changelog` (stamped with the
//  task id). The runs list is the master pane, and selecting a row
//  populates the trace on the right. Mirrors §7's "Activity" design.
//

import SwiftUI

struct DatabaseHistoryView: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    var inspectionTheme: (any ThemeProtocol)?
    private var theme: any ThemeProtocol {
        if let value = inspectionTheme { return value }
        return inheritedTheme
    }

    let agentId: UUID

    @State private var runs: [OsaurusTask] = []
    @State private var selectedRunId: UUID? = nil
    @State private var changelogRows: [ChangelogEntry] = []
    @State private var isLoadingRuns = true
    @State private var isLoadingTrace = false
    @State private var loadError: String? = nil

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
        .background(theme.surface.canvas)
        .task { await loadRuns() }
        .onChange(of: agentId) { _, _ in Task { await loadRuns() } }
        .onChange(of: selectedRunId) { _, _ in Task { await loadTrace() } }
    }

    @ViewBuilder
    private var runsList: some View {
        VStack(alignment: .leading, spacing: theme.space.s0) {
            HStack {
                Text("Runs", bundle: .module)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                    .foregroundColor(theme.text.tertiary)
                Spacer()
                Button {
                    Task { await loadRuns() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .glyphSize(.footnote)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, theme.space.s12)
            .padding(.vertical, theme.space.s8)
            Divider().foregroundColor(theme.border.subtle)
            if isLoadingRuns {
                SettingsSpinner(size: .large).padding(.horizontal, theme.settingsPageInset).padding(.vertical, theme.space.s24)
            } else if runs.isEmpty {
                Text(
                    "No runs yet. When the agent works on a schedule or automation, each run shows up here.",
                    bundle: .module
                )
                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                .foregroundColor(theme.text.tertiary)
                .padding(.horizontal, theme.space.s24).padding(.vertical, theme.space.s24)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: theme.space.s2) {
                        ForEach(runs, id: \.id) { run in
                            runRow(run)
                        }
                    }
                    .padding(.horizontal, theme.space.s6)
                    .padding(.vertical, theme.space.s6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.surface.hover)
    }

    @ViewBuilder
    private func runRow(_ run: OsaurusTask) -> some View {
        let isSelected = selectedRunId == run.id
        Button {
            selectedRunId = run.id
        } label: {
            VStack(alignment: .leading, spacing: theme.space.s4) {
                HStack(spacing: theme.space.s6) {
                    statusIcon(for: run.state)
                    Text(run.state.displayName)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                        .foregroundColor(theme.text.primary)
                    Spacer()
                    Text(run.origin.displayName)
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.chip)
                        .foregroundColor(theme.text.tertiary)
                        .padding(.horizontal, theme.space.s6)
                        .padding(.vertical, theme.space.s2)
                        .settingsChrome(.inset)
                }
                Text(run.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
                Text(run.title)
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, theme.space.s8)
            .padding(.vertical, theme.space.s8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsChrome(isSelected ? .selected : nil)
            .contentShape(RoundedRectangle(cornerRadius: theme.radius.medium))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    @ViewBuilder
    private func statusIcon(for state: TaskState) -> some View {
        switch state {
        case .received, .queued, .admitted, .running, .waitingUser:
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundColor(theme.status.info.foreground)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(theme.status.success.foreground)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(theme.status.error.foreground)
        case .cancelled, .interrupted:
            Image(systemName: "stop.circle.fill")
                .foregroundColor(theme.status.warning.foreground)
        case .filtered, .duplicate, .suppressed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(theme.status.warning.foreground)
        }
    }

    @ViewBuilder
    private var tracePane: some View {
        VStack(alignment: .leading, spacing: theme.space.s0) {
            if let runId = selectedRunId, let run = runs.first(where: { $0.id == runId }) {
                traceHeader(for: run)
                Divider().foregroundColor(theme.border.subtle)
                if isLoadingTrace {
                    SettingsSpinner(size: .large).padding(.horizontal, theme.settingsPageInset).padding(.vertical, theme.space.s24)
                } else if changelogRows.isEmpty {
                    Text("No database changes were recorded for this run.", bundle: .module)
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                        .foregroundColor(theme.text.tertiary)
                        .padding(.horizontal, theme.space.s24).padding(.vertical, theme.space.s24)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: theme.space.s0) {
                            ForEach(changelogRows) { row in
                                changelogRowView(row)
                            }
                        }
                    }
                }
            } else {
                Text("Select a run to see its trace.", bundle: .module)
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                    .foregroundColor(theme.text.tertiary)
                    .padding(.horizontal, theme.space.s24).padding(.vertical, theme.space.s24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func traceHeader(for run: OsaurusTask) -> some View {
        SettingsRowText(compact: true) {
            HStack(spacing: theme.space.s6) {
                statusIcon(for: run.state)
                Text(run.state.displayName)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                Text("·")
                    .foregroundColor(theme.text.tertiary)
                Text(run.origin.displayName)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                Spacer()
                if let ended = run.finishedAt {
                    Text(durationLabel(from: run.startedAt ?? run.createdAt, to: ended))
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                }
            }
        } description: {
            VStack(alignment: .leading, spacing: theme.space.s6) {
                if let error = run.lastError, !error.isEmpty {
                    Text(error)
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.monoSmall)
                        .foregroundColor(theme.status.error.foreground)
                        .lineLimit(3)
                }
                HStack(spacing: theme.space.s12) {
                    if let tin = run.result?.tokensIn {
                        statBadge(label: "in", value: "\(tin)")
                    }
                    if let tout = run.result?.tokensOut {
                        statBadge(label: "out", value: "\(tout)")
                    }
                    if let cost = run.result?.costUSD {
                        statBadge(label: "$", value: String(format: "%.4f", cost))
                    }
                    Spacer()
                }
                Text(run.title)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, theme.space.s12).padding(.vertical, theme.space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func statBadge(label: String, value: String) -> some View {
        HStack(spacing: theme.space.s4) {
            Text(label)
                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                .foregroundColor(theme.text.tertiary)
            Text(value)
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.monoSmall)
                .foregroundColor(theme.text.primary)
        }
    }

    @ViewBuilder
    private func changelogRowView(_ row: ChangelogEntry) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s2) {
            HStack(spacing: theme.space.s6) {
                Text(row.op)
                    .componentInspectionText(53, role: .code, fallback: .footnote, family: .code, theme: theme)
                    .foregroundColor(theme.text.link)
                if let table = row.tableName {
                    Text(table)
                        .componentInspectionText(53, role: .code, fallback: .footnote, family: .code, theme: theme)
                        .foregroundColor(theme.text.primary)
                }
                if let pk = row.rowPK {
                    Text(pk)
                        .componentInspectionText(53, role: .code, fallback: .footnote, family: .code, theme: theme)
                        .foregroundColor(theme.text.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                Text(row.actor)
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
                Text(row.timestamp.formatted(date: .omitted, time: .standard))
                    .componentInspectionText(53, role: .code, fallback: .footnote, family: .code, theme: theme)
                    .foregroundColor(theme.text.tertiary)
            }
            if let sql = row.sql, !sql.isEmpty {
                Text(sql)
                    .componentInspectionText(53, role: .code, fallback: .footnote, family: .code, theme: theme)
                    .foregroundColor(theme.text.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Divider().foregroundColor(theme.border.subtle), alignment: .bottom)
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
        isLoadingRuns = true
        defer { isLoadingRuns = false }
        runs = await TaskStore.shared.tasks(TaskQuery(agentId: agentId, limit: 200))
        if let current = selectedRunId,
            runs.contains(where: { $0.id == current })
        {
            // Keep current selection across refreshes.
        } else {
            selectedRunId = runs.first?.id
        }
    }

    @MainActor
    private func loadTrace() async {
        guard let runId = selectedRunId else {
            changelogRows = []
            return
        }
        isLoadingTrace = true
        defer { isLoadingTrace = false }
        do {
            let sql =
                "SELECT ts, actor, op, table_name, row_pk, sql "
                + "FROM _changelog WHERE run_id = ?1 ORDER BY ts ASC"
            let result = try LocalAgentBridge.shared.query(
                agentId: agentId,
                sql: sql,
                params: [.text(runId.uuidString)]
            )
            changelogRows = result.rows.enumerated().compactMap { (index, row) in
                guard row.count >= 6 else { return nil }
                let ts: Int64 = {
                    if case .integer(let v) = row[0] { return v }
                    return 0
                }()
                return ChangelogEntry(
                    index: index,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(ts)),
                    actor: textValue(row[1]) ?? "",
                    op: textValue(row[2]) ?? "",
                    tableName: textValue(row[3]),
                    rowPK: textValue(row[4]),
                    sql: textValue(row[5])
                )
            }
        } catch {
            changelogRows = []
        }
    }

    private func textValue(_ value: AgentSQLValue) -> String? {
        if case .text(let v) = value { return v }
        return nil
    }
}

private struct ChangelogEntry: Identifiable {
    var id: Int { index }
    let index: Int
    let timestamp: Date
    let actor: String
    let op: String
    let tableName: String?
    let rowPK: String?
    let sql: String?
}

#if OSAURUS_DESIGN_INSPECTOR
extension DatabaseHistoryView {
    static func inspectionPopulatedHistory() -> some View { InspectorDatabaseHistoryDisplay() }
    fileprivate static func renderInspection(_ theme: any ThemeProtocol) -> some View {
        var view = DatabaseHistoryView(agentId: UUID(uuidString: "ABC00000-0000-4000-8000-000000000053")!)
        view.inspectionTheme = theme
        let states: [TaskState] = [.running, .succeeded, .failed, .cancelled, .suppressed]
        let rows = states.enumerated().map { index, state in
            var task = OsaurusTask(
                title: "Local display run \(index + 1)", origin: .manual,
                createdBy: .init(kind: .user),
                work: .agentTurn(.init(agentId: view.agentId, source: .chat)), state: state)
            task.startedAt = Date()
            task.finishedAt = state == .running ? nil : Date()
            task.result = TaskResult(tokensIn: 1234, tokensOut: 56, costUSD: 0.0123)
            task.lastError = state == .failed ? "Local run error display" : nil
            return task
        }
        return VStack(alignment: .leading, spacing: theme.space.s12) {
            ForEach(rows, id: \.id) { view.runRow($0) }
            view.traceHeader(for: rows[2])
            view.changelogRowView(ChangelogEntry(index: 1, timestamp: Date(), actor: "local sample", op: "UPDATE", tableName: "local_notes", rowPK: "1", sql: "UPDATE local_notes SET title = 'Local display';"))
        }.allowsHitTesting(false)
    }
}
#endif

#if OSAURUS_DESIGN_INSPECTOR
private struct InspectorDatabaseHistoryDisplay: View {
    @ObservedObject private var manager = ThemeManager.shared
    var body: some View { DatabaseHistoryView.renderInspection(manager.currentTheme) }
}
#endif
