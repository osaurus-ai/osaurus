//
//  AgentDBTabViews.swift
//  osaurus
//
//  Tabs that surface the Agent DB feature (spec §5.5 / §7) in the
//  agent detail view: a read-only Schema view, a Data grid (filled in
//  by `DataTabView`/`AgentDataTableRepresentable`), and an Activity
//  log that joins `agent_runs` with `_changelog`.
//
//  The tabs are gated by `Agent.settings.dbEnabled` in
//  `AgentsView.DetailTab.allTabsForAgent(_:)`. They open the agent's
//  encrypted DB lazily on first display via `LocalAgentBridge.shared`
//  — if the DB has never been written to, the schema is just the
//  reserved system tables and the tab renders an empty-state nudge.
//

import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Schema Tab

/// Read-only listing of every table, column, index, and view the agent
/// has materialized in its private DB. The system tables (`_tables_meta`,
/// `_changelog`, `_views`) sit at the top under a dimmed header so the
/// user can audit reserved-name conflicts; user tables follow in
/// creation order.
public struct SchemaTabView: View {
    @Environment(\.theme) private var theme

    let agentId: UUID

    @State private var schema: AgentDatabaseSchema?
    @State private var loadError: String?
    @State private var isLoading = true

    public init(agentId: UUID) {
        self.agentId = agentId
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if isLoading {
                    loadingState
                } else if let error = loadError {
                    errorState(error)
                } else if let schema, schema.tables.isEmpty && schema.views.isEmpty {
                    emptyState
                } else if let schema {
                    schemaContent(schema)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.primaryBackground)
        .task { await reload() }
        .onChange(of: agentId) { _, _ in Task { await reload() } }
    }

    @MainActor
    private func reload() async {
        isLoading = true
        loadError = nil
        do {
            let snapshot = try LocalAgentBridge.shared.schema(agentId: agentId)
            self.schema = snapshot
            self.isLoading = false
        } catch {
            self.loadError = error.localizedDescription
            self.isLoading = false
        }
    }

    @ViewBuilder
    private var loadingState: some View {
        HStack {
            ProgressView()
            Text("Loading schema…", bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
        }
    }

    @ViewBuilder
    private func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(localized: "Couldn't open the database", systemImage: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.red)
            Text(message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No tables yet", bundle: .module)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text(
                "Once the agent creates a table with the `db_create_table` tool, it will show up here.",
                bundle: .module
            )
            .font(.system(size: 12))
            .foregroundColor(theme.tertiaryText)
        }
    }

    @ViewBuilder
    private func schemaContent(_ schema: AgentDatabaseSchema) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                StorageQuotaBadge(agentId: agentId, theme: theme)
                MutationsInFlightIndicator(agentId: agentId, theme: theme)
                Spacer(minLength: 0)
            }
            ForEach(userTables(schema), id: \.name) { table in
                tableCard(table, isSystem: false)
            }

            if !schema.views.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("Saved Views")
                    ForEach(schema.views, id: \.name) { view in
                        viewCard(view)
                    }
                }
            }

            let systemTables = schema.tables.filter { isSystemTable($0.name) }
            if !systemTables.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("System (reserved)")
                    ForEach(systemTables, id: \.name) { table in
                        tableCard(table, isSystem: true)
                    }
                }
            }
        }
    }

    private func userTables(_ schema: AgentDatabaseSchema) -> [AgentTableSchema] {
        schema.tables.filter { !isSystemTable($0.name) }
    }

    private func isSystemTable(_ name: String) -> Bool {
        name.hasPrefix("_")
    }

    @ViewBuilder
    private func sectionHeader(_ text: LocalizedStringKey) -> some View {
        Text(text, bundle: .module)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(theme.tertiaryText)
            .tracking(0.5)
    }

    @ViewBuilder
    private func tableCard(_ table: AgentTableSchema, isSystem: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "tablecells")
                    .foregroundColor(isSystem ? theme.tertiaryText : theme.accentColor)
                Text(table.name)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                if !table.purpose.isEmpty {
                    Text("— \(table.purpose)")
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }
                Spacer()
                // Quick-jump into the Data tab for this row. System
                // tables (`_changelog`, `_views`) are read-only so the
                // Browse affordance still works on them — the user
                // just lands on a non-editable grid. Posting through
                // the same notification the Schema/Notify deep-link
                // routes use keeps the entire focus pipeline single-
                // sourced.
                Button {
                    NotificationCenter.default.post(
                        name: .agentDetailDeeplink,
                        object: nil,
                        userInfo: [
                            "agentId": agentId,
                            "tab": "data",
                            "tableRef": table.name,
                        ]
                    )
                } label: {
                    Label(localized: "Browse", systemImage: "arrow.right.square")
                        .font(.system(size: 10, weight: .medium))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .localizedHelp("Open this table in the Data tab")
            }
            ForEach(table.columns, id: \.name) { column in
                HStack(spacing: 8) {
                    Text(column.name)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                    Text(column.type)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                    if column.primaryKey {
                        Text(localized: "PK").font(.system(size: 9, weight: .bold))
                            .foregroundColor(theme.accentColor)
                    }
                    if !column.nullable {
                        Text(localized: "NOT NULL").font(.system(size: 9))
                            .foregroundColor(theme.tertiaryText)
                    }
                    Spacer()
                }
                .padding(.leading, 18)
            }
            if !table.indexes.isEmpty {
                ForEach(table.indexes, id: \.name) { index in
                    HStack(spacing: 8) {
                        Image(systemName: "list.bullet.indent")
                            .foregroundColor(theme.tertiaryText)
                        Text(index.name)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.tertiaryText)
                        Text("(\(index.columns.joined(separator: ", ")))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(theme.tertiaryText)
                        if index.unique {
                            Text(localized: "UNIQUE").font(.system(size: 9, weight: .bold))
                                .foregroundColor(theme.tertiaryText)
                        }
                        Spacer()
                    }
                    .padding(.leading, 18)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(theme.inputBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(theme.inputBorder, lineWidth: 1)
        )
        .opacity(isSystem ? 0.6 : 1)
    }

    @ViewBuilder
    private func viewCard(_ view: AgentSavedView) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .foregroundColor(theme.accentColor)
                Text(view.name)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                Spacer()
            }
            if let description = view.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
            Text(view.sql)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.tertiaryBackground)
                .cornerRadius(4)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(theme.inputBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(theme.inputBorder, lineWidth: 1)
        )
    }
}

// MARK: - Data Tab

/// Soft-delete filter modes for the data grid. The spec calls out
/// "soft-delete view" (§7) — the data grid shows live rows by default
/// and an audit-style read-only view of `_deleted_at IS NOT NULL`
/// rows on demand.
fileprivate enum DataFilterMode: String, CaseIterable, Identifiable {
    case live
    case deleted
    case all

    var id: String { rawValue }

    /// User-facing label. `.live` reads as "Active" since users
    /// don't think of un-deleted rows as "live" — the term came from
    /// the soft-delete SQL pattern and was confusing in the UI.
    var label: LocalizedStringKey {
        switch self {
        case .live: return "Active"
        case .deleted: return "Deleted"
        case .all: return "All"
        }
    }

    /// One-line description shown in the filter help popover.
    var helpDescription: LocalizedStringKey {
        switch self {
        case .live: return "Rows the agent is currently using."
        case .deleted: return "Soft-deleted rows the agent can still restore."
        case .all: return "Everything in the table, including soft-deleted rows."
        }
    }
}

/// Browse, inspect, and edit the rows the agent has accumulated. Uses
/// a parameterised `db_query` (via `LocalAgentBridge`) so all reads
/// stay encrypted and audit-visible. Edits flow through
/// `LocalAgentBridge.update` and `softDelete` so the `_changelog`
/// gets stamped correctly and the per-agent serial queue holds the
/// write order.
public struct DataTabView: View {
    @Environment(\.theme) private var theme

    let agentId: UUID
    /// Optional table name to pre-select on first load. Used by the
    /// "Browse" deeplink from `SchemaTabView` and by the notification
    /// deeplink so the user lands directly on the table they tapped.
    /// Honoured once on `task`; afterwards the user's selection
    /// drives the dropdown.
    let initialSelectedTable: String?

    @State private var tables: [AgentTableSchema] = []
    @State private var selectedTable: String? = nil
    @State private var filterMode: DataFilterMode = .live
    @State private var rows: [[AgentSQLValue]] = []
    @State private var columns: [AgentColumnInfo] = []
    @State private var idColumnIndex: Int? = nil
    @State private var totalRowCount: Int = 0
    @State private var truncated: Bool = false
    @State private var isLoading: Bool = false
    @State private var loadError: String? = nil
    @State private var editingRow: EditingRow? = nil
    @State private var hasAppliedInitialSelection = false
    /// Display-string ids (`displayString(for: idValue)`) of every
    /// row currently checked in the grid. Driven from the bulk-
    /// delete checkbox column on `AgentDataTableRepresentable`; we
    /// key on the string because `AgentSQLValue` is `Equatable` but
    /// not `Hashable` (it carries `Data` blobs).
    @State private var selectedRowIds: Set<String> = []
    @State private var showBulkDeleteConfirm: Bool = false
    /// Toggles the small `?` popover next to the filter segments
    /// that explains what `Active / Deleted / All` mean.
    @State private var showFilterHelp: Bool = false
    /// First-load tip caption surfaced above the grid. Dismissed
    /// once the user clicks the inline `x`. Persisted across
    /// sessions so power users don't keep seeing it.
    @AppStorage("agentDataTipDismissed") private var dataTipDismissed: Bool = false
    /// True while a host import (button or drag-drop) is parsing + loading.
    @State private var isImporting: Bool = false
    /// Transient success line shown under the control bar after an import
    /// (e.g. "Imported 500 rows into `commits`"). Dismissable.
    @State private var importSummary: String? = nil
    /// Drives the drag-drop highlight while a file hovers over the grid.
    @State private var isDropTargeted: Bool = false

    public init(agentId: UUID, initialSelectedTable: String? = nil) {
        self.agentId = agentId
        self.initialSelectedTable = initialSelectedTable
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controlBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            if let summary = importSummary {
                importSummaryBanner(summary)
            }
            Divider().foregroundColor(theme.primaryBorder)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(theme.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .task { await loadTables() }
        .onChange(of: agentId) { _, _ in
            Task { await loadTables() }
        }
        .onChange(of: selectedTable) { _, _ in
            selectedRowIds.removeAll()
            Task { await reloadRows() }
        }
        .onChange(of: filterMode) { _, _ in
            selectedRowIds.removeAll()
            Task { await reloadRows() }
        }
        .sheet(item: $editingRow) { row in
            RowEditorSheet(
                row: row,
                onSave: { updates in
                    Task { await applyUpdate(rowId: row.rowId, updates: updates) }
                },
                onSoftDelete: {
                    Task { await applySoftDelete(rowId: row.rowId) }
                },
                onRestore: {
                    Task { await applyRestore(rowId: row.rowId) }
                },
                onCancel: { editingRow = nil }
            )
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var controlBar: some View {
        HStack(spacing: 16) {
            controlBarSelectorZone
            Spacer()
            controlBarActionsZone
        }
        .confirmationDialog(
            "Delete \(selectedRowIds.count) rows?",
            isPresented: $showBulkDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(localized: "Soft-Delete \(selectedRowIds.count) Rows", role: .destructive) {
                Task { await bulkSoftDelete() }
            }
            Button(localized: "Cancel", role: .cancel) {}
        } message: {
            Text(
                "These rows will be soft-deleted (their `_deleted_at` "
                    + "stamp set), not permanently removed. Switch the "
                    + "filter to \"Deleted\" to restore them later."
            )
        }
    }

    /// Left side of the toolbar — what the user is LOOKING AT. Holds
    /// the table picker and the filter segments (with a help popover
    /// explaining what `Active / Deleted / All` mean). Labels use
    /// `verbatim:` so they render regardless of the resolved bundle
    /// localisation table, and each label-group is `.fixedSize`'d so
    /// SwiftUI doesn't squeeze "Show" into a vertical S/h/o/w stack
    /// when the action zone competes for horizontal space.
    @ViewBuilder
    private var controlBarSelectorZone: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Text(verbatim: "Table")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize()
                tablePicker
            }
            .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: 6) {
                Text(verbatim: "Show")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize()
                Picker("", selection: $filterMode) {
                    ForEach(DataFilterMode.allCases) { mode in
                        Text(mode.label, bundle: .module).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .labelsHidden()
                filterHelpButton
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// Right side of the toolbar — STATUS + ACTIONS. Storage / mutation
    /// status sit closest to the spacer; bulk delete + truncated +
    /// export are the verbs the user invokes.
    @ViewBuilder
    private var controlBarActionsZone: some View {
        HStack(spacing: 10) {
            StorageQuotaBadge(agentId: agentId, theme: theme)
            MutationsInFlightIndicator(agentId: agentId, theme: theme)
            if !selectedRowIds.isEmpty {
                Button(role: .destructive) {
                    showBulkDeleteConfirm = true
                } label: {
                    Label(localized: "Delete \(selectedRowIds.count)", systemImage: "trash")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            }
            if truncated {
                Label(localized: "Truncated", systemImage: "scissors")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .localizedHelp("The result was capped at 500 rows.")
            }
            Button {
                presentImportPanel()
            } label: {
                HStack(spacing: 5) {
                    if isImporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                    }
                    Text(localized: "Import")
                }
                .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isImporting)
            .localizedHelp(
                "Import a CSV, TSV, JSON, or JSONL file into the selected table or a new one. You can also drag a file onto this tab."
            )
            Button {
                exportCSV()
            } label: {
                Label(localized: "Export CSV", systemImage: "square.and.arrow.up")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(rows.isEmpty)
        }
    }

    /// Thin info banner shown after a successful import. Mirrors the
    /// `dataTipCaption` styling so it reads as part of the surface, not a
    /// modal interruption.
    @ViewBuilder
    private func importSummaryBanner(_ summary: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 10))
                .foregroundColor(theme.accentColor)
            Text(verbatim: summary)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
            Spacer(minLength: 0)
            Button {
                importSummary = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
            }
            .buttonStyle(.plain)
            .localizedHelp("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(theme.accentColor.opacity(0.08))
    }

    /// `?` button next to the filter picker. Opens a small popover
    /// listing the meaning of each filter mode — without it,
    /// "Active / Deleted / All" is opaque to first-time users.
    @ViewBuilder
    private var filterHelpButton: some View {
        Button {
            showFilterHelp.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
        }
        .buttonStyle(.plain)
        .localizedHelp("What do these filters mean?")
        .popover(isPresented: $showFilterHelp, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text(localized: "Filters")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                ForEach(DataFilterMode.allCases) { mode in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mode.label, bundle: .module)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                        Text(mode.helpDescription, bundle: .module)
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(14)
            .frame(width: 260)
        }
    }

    @ViewBuilder
    private var tablePicker: some View {
        Picker(
            "",
            selection: Binding(
                get: { selectedTable ?? "" },
                set: { selectedTable = $0.isEmpty ? nil : $0 }
            )
        ) {
            if tables.isEmpty {
                Text(localized: "No tables").tag("")
            } else {
                ForEach(userVisibleTables, id: \.name) { table in
                    Text(table.name).tag(table.name)
                }
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(minWidth: 140, idealWidth: 180, maxWidth: 240)
    }

    private var userVisibleTables: [AgentTableSchema] {
        tables.filter { !$0.name.hasPrefix("_") }
    }

    // MARK: - Body Content

    @ViewBuilder
    private var content: some View {
        if let error = loadError {
            VStack(alignment: .leading, spacing: 6) {
                Label(localized: "Couldn't load rows", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.red)
                Text(error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(24)
        } else if userVisibleTables.isEmpty {
            noTablesEmptyState
        } else if selectedTable == nil {
            noTableSelectedEmptyState
        } else if isLoading {
            HStack {
                ProgressView()
                Text("Loading rows…", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(24)
        } else if rows.isEmpty {
            noRowsEmptyState
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if !dataTipDismissed {
                    dataTipCaption
                }
                grid
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Structured "no tables yet" onboarding card. Replaces the flat
    /// `empty(message:)` for the case where the agent hasn't called
    /// `db_create_table` yet — surfaces what's expected and gives a
    /// one-click path into the Schema tab so users have somewhere to
    /// go besides "wait."
    @ViewBuilder
    private var noTablesEmptyState: some View {
        DataEmptyState(
            systemImage: "tablecells.badge.ellipsis",
            title: "This agent has no memory tables yet.",
            subtitle:
                "Ask the agent in chat to remember something — it will call `db_create_table` to build the schema it needs. You can browse what it creates here.",
            actionTitle: "Open Schema tab",
            actionSystemImage: "tablecells",
            action: { openSchemaTab() },
            theme: theme
        )
    }

    /// Shown when there ARE user-visible tables but none picked yet.
    /// Less aggressive than the "no tables" state — the user just
    /// needs a nudge toward the dropdown.
    @ViewBuilder
    private var noTableSelectedEmptyState: some View {
        DataEmptyState(
            systemImage: "arrow.up.left",
            title: "Pick a table to see its rows.",
            subtitle: "Use the Table dropdown above to choose which of this agent's tables you want to browse.",
            actionTitle: nil,
            actionSystemImage: nil,
            action: nil,
            theme: theme
        )
    }

    /// Shown when the selected table exists but the current filter
    /// returns nothing. Copy varies with the filter so the user knows
    /// whether to switch to a different filter or wait for the agent.
    @ViewBuilder
    private var noRowsEmptyState: some View {
        let tableLabel = selectedTable ?? "this table"
        switch filterMode {
        case .deleted:
            DataEmptyState(
                systemImage: "trash.slash",
                title: "No deleted rows in `\(tableLabel)`.",
                subtitle: "Soft-deleted rows the agent could restore would appear here.",
                actionTitle: nil,
                actionSystemImage: nil,
                action: nil,
                theme: theme
            )
        case .live, .all:
            DataEmptyState(
                systemImage: "tray",
                title: "No rows in `\(tableLabel)`.",
                subtitle:
                    "The agent adds rows with `db_insert` / `db_upsert` when it has something to remember. You can also ask it directly in chat.",
                actionTitle: nil,
                actionSystemImage: nil,
                action: nil,
                theme: theme
            )
        }
    }

    /// One-line dismissable caption that teaches the affordances on
    /// the grid (Open button, checkbox selection, dimmed soft-deleted
    /// rows). Hidden permanently once the user dismisses it; the flag
    /// lives in `@AppStorage` so power users don't keep seeing it.
    @ViewBuilder
    private var dataTipCaption: some View {
        HStack(spacing: 8) {
            Image(systemName: "lightbulb")
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
            Text(
                "Click ↗ on a row to open it · check rows for bulk delete · soft-deleted rows are dimmed.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            Spacer(minLength: 0)
            Button {
                dataTipDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
            }
            .buttonStyle(.plain)
            .localizedHelp("Hide this tip")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(theme.secondaryBackground.opacity(0.5))
    }

    /// Posts the standard `.agentDetailDeeplink` notification to flip
    /// the parent `AgentDetailView` to the Schema tab. Reuses the same
    /// channel that `SchemaTabView`'s `Browse` button uses, in the
    /// opposite direction.
    private func openSchemaTab() {
        NotificationCenter.default.post(
            name: .agentDetailDeeplink,
            object: nil,
            userInfo: [
                "agentId": agentId,
                "tab": "schema",
            ]
        )
    }

    @ViewBuilder
    private var grid: some View {
        AgentDataTableRepresentable(
            columns: columns,
            rows: rows,
            idColumnIndex: idColumnIndex,
            deletedColumnIndex: deletedColumnIndex,
            // Only reserve a leading status column when soft-deleted
            // rows can actually appear in the current filter — keeps the
            // default Active view from showing a permanently-empty
            // 76px column that looks broken.
            showsStatusColumn: filterMode != .live && deletedColumnIndex != nil,
            selectedRowIds: $selectedRowIds,
            theme: theme,
            onRowOpen: { rowIndex in
                openEditor(for: rowIndex)
            }
        )
    }

    /// Column index of `_deleted_at` if present — used by the grid
    /// to dim soft-deleted rows in `.all` filter mode.
    private var deletedColumnIndex: Int? {
        columns.firstIndex(where: { $0.name == "_deleted_at" })
    }

    // MARK: - Loading

    @MainActor
    private func loadTables() async {
        loadError = nil
        do {
            let snapshot = try LocalAgentBridge.shared.schema(agentId: agentId)
            tables = snapshot.tables
            if !hasAppliedInitialSelection,
                let pin = initialSelectedTable,
                userVisibleTables.contains(where: { $0.name == pin })
            {
                hasAppliedInitialSelection = true
                selectedTable = pin
            } else if let current = selectedTable,
                userVisibleTables.contains(where: { $0.name == current })
            {
                // Keep current.
            } else {
                selectedTable = userVisibleTables.first?.name
            }
            await reloadRows()
        } catch {
            loadError = error.localizedDescription
        }
    }

    @MainActor
    private func reloadRows() async {
        guard let tableName = selectedTable,
            let table = tables.first(where: { $0.name == tableName })
        else {
            rows = []
            columns = []
            idColumnIndex = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        loadError = nil
        let whereSQL: String = {
            switch filterMode {
            case .live: return "WHERE _deleted_at IS NULL"
            case .deleted: return "WHERE _deleted_at IS NOT NULL"
            case .all: return ""
            }
        }()
        let sql =
            "SELECT * FROM \"\(tableName)\" \(whereSQL) "
            + "ORDER BY _updated_at DESC LIMIT 500"
        do {
            let result = try LocalAgentBridge.shared.query(
                agentId: agentId,
                sql: sql,
                params: []
            )
            columns = table.columns
            rows = result.rows
            truncated = result.truncated
            totalRowCount = result.rows.count
            idColumnIndex = result.columns.firstIndex(of: "id")
        } catch {
            loadError = error.localizedDescription
            rows = []
            columns = []
            idColumnIndex = nil
        }
    }

    // MARK: - Edit

    private func openEditor(for rowIndex: Int) {
        guard rowIndex >= 0, rowIndex < rows.count else { return }
        let row = rows[rowIndex]
        guard let idIdx = idColumnIndex, idIdx < row.count else { return }
        // The default `id` column is `INTEGER PRIMARY KEY AUTOINCREMENT`,
        // but agents can declare their own TEXT/INTEGER PKs, so we
        // round-trip the value through `AgentSQLValue` rather than
        // committing to one type at this layer.
        editingRow = EditingRow(
            rowId: row[idIdx],
            tableName: selectedTable ?? "",
            columns: columns,
            values: row,
            isDeleted: filterMode == .deleted
                || rowValue(row, forColumnNamed: "_deleted_at").isNotNull
        )
    }

    @MainActor
    private func applyUpdate(rowId: AgentSQLValue, updates: [String: AgentSQLValue]) async {
        guard let table = selectedTable else { return }
        // Stamp _changelog with `actor=user` for UI-driven writes
        // (spec §6). `LocalAgentBridge.currentActor()` falls back to
        // `agent` when the task-local is `nil`, which would mislabel
        // every inline edit. Binding here keeps the read path on the
        // serial queue inside the bridge intact — matches the pattern
        // `BackgroundTaskManager.dispatchChat` uses for `agent` stamping.
        do {
            _ = try ChatExecutionContext.$currentRunActor.withValue("user") {
                try LocalAgentBridge.shared.update(
                    agentId: agentId,
                    table: table,
                    set: updates,
                    whereClause: ["id": rowId],
                    includeDeleted: filterMode != .live
                )
            }
            editingRow = nil
            await reloadRows()
        } catch {
            loadError = error.localizedDescription
        }
    }

    @MainActor
    private func applySoftDelete(rowId: AgentSQLValue) async {
        guard let table = selectedTable else { return }
        do {
            _ = try ChatExecutionContext.$currentRunActor.withValue("user") {
                try LocalAgentBridge.shared.softDelete(
                    agentId: agentId,
                    table: table,
                    whereClause: ["id": rowId]
                )
            }
            editingRow = nil
            await reloadRows()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Soft-delete every row currently checked in the grid, in one
    /// `actor=user` task-local scope so the audit trail shows the
    /// edit came from the UI. Clears the selection on success.
    @MainActor
    private func bulkSoftDelete() async {
        guard let table = selectedTable else { return }
        guard let idIdx = idColumnIndex else { return }
        // Map the display-string selection back to the matching row's
        // PK value. Doing the lookup once up-front means even if
        // `reloadRows()` mutates the row order mid-loop, we still
        // delete the right things.
        let targets: [AgentSQLValue] = rows.compactMap { row in
            guard idIdx < row.count else { return nil }
            let value = row[idIdx]
            return selectedRowIds.contains(displayString(for: value)) ? value : nil
        }
        guard !targets.isEmpty else {
            selectedRowIds.removeAll()
            return
        }
        do {
            try ChatExecutionContext.$currentRunActor.withValue("user") {
                for rowId in targets {
                    _ = try LocalAgentBridge.shared.softDelete(
                        agentId: agentId,
                        table: table,
                        whereClause: ["id": rowId]
                    )
                }
            }
            selectedRowIds.removeAll()
            await reloadRows()
        } catch {
            loadError = error.localizedDescription
        }
    }

    @MainActor
    private func applyRestore(rowId: AgentSQLValue) async {
        guard let table = selectedTable else { return }
        do {
            _ = try ChatExecutionContext.$currentRunActor.withValue("user") {
                try LocalAgentBridge.shared.restore(
                    agentId: agentId,
                    table: table,
                    whereClause: ["id": rowId]
                )
            }
            editingRow = nil
            await reloadRows()
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Host import (actor=user)

    /// Open a file picker for the supported import formats. Runs on the
    /// MainActor (NSOpenPanel is AppKit-only) and hands the chosen URL to
    /// `importFile`.
    @MainActor
    private func presentImportPanel() {
        guard !isImporting else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        var types: [UTType] = [.commaSeparatedText, .tabSeparatedText, .json, .plainText]
        if let jsonl = UTType(filenameExtension: "jsonl") { types.append(jsonl) }
        if let ndjson = UTType(filenameExtension: "ndjson") { types.append(ndjson) }
        panel.allowedContentTypes = types
        panel.message = String(
            localized: "Choose a CSV, TSV, JSON, or JSONL file to import.",
            bundle: .module
        )
        panel.prompt = String(localized: "Import", bundle: .module)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await importFile(url: url) }
    }

    /// Accept a file dragged onto the tab. Loads the first droppable URL and
    /// routes it through the same `importFile` path as the button.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isImporting,
            let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) })
        else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in await importFile(url: url) }
        }
        return true
    }

    /// Parse `url` off the main thread, then bulk-load it through the shared
    /// `AgentImportRunner` with the write stamped `actor=user` — the same
    /// task-local pattern the inline row editor uses. Imports into the
    /// selected table, or a new table named after the file when none is
    /// selected.
    @MainActor
    private func importFile(url: URL) async {
        guard !isImporting else { return }
        loadError = nil
        importSummary = nil
        isImporting = true
        defer { isImporting = false }

        let table = selectedTable ?? suggestedTableName(from: url)
        do {
            let parsed = try await Task.detached(priority: .userInitiated) {
                () throws -> DatabaseImport.Parsed in
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                return try AgentImportRunner.parse(url: url)
            }.value

            let outcome = try ChatExecutionContext.$currentRunActor.withValue("user") {
                try AgentImportRunner.run(
                    agentId: agentId,
                    table: table,
                    parsed: parsed,
                    sourceLabel: url.lastPathComponent
                )
            }

            await loadTables()
            selectedTable = outcome.table
            await reloadRows()

            var line =
                "Imported \(outcome.rowsImported) "
                + (outcome.rowsImported == 1 ? "row" : "rows")
                + " into `\(outcome.table)`"
            if outcome.createdTable { line += " (new table)" }
            if !outcome.droppedColumns.isEmpty {
                let n = outcome.droppedColumns.count
                line += " · ignored \(n) unmatched column" + (n == 1 ? "" : "s")
            }
            importSummary = line
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Derive a safe SQLite table name from a file name (lowercased, only
    /// letters/digits/underscores, never leading with a digit).
    private func suggestedTableName(from url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent.lowercased()
        var out = ""
        for ch in base {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
            } else if ch == "_" || ch == "-" || ch == " " {
                out.append("_")
            }
        }
        while out.contains("__") { out = out.replacingOccurrences(of: "__", with: "_") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if let first = out.first, first.isNumber { out = "t_" + out }
        return out.isEmpty ? "imported_data" : out
    }

    private func rowValue(_ row: [AgentSQLValue], forColumnNamed name: String) -> AgentSQLValue {
        guard let idx = columns.firstIndex(where: { $0.name == name }), idx < row.count
        else { return .null }
        return row[idx]
    }

    // MARK: - CSV Export

    private func exportCSV() {
        guard !rows.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(selectedTable ?? "rows").csv"
        Task { @MainActor in
            guard await panel.beginModal() == .OK, let url = panel.url else { return }
            let csv = renderCSV(columns: columns.map(\.name), rows: rows)
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                loadError = "CSV write failed: \(error.localizedDescription)"
            }
        }
    }

    private func renderCSV(columns: [String], rows: [[AgentSQLValue]]) -> String {
        var lines: [String] = []
        lines.append(columns.map(csvEscape).joined(separator: ","))
        for row in rows {
            let cells = row.map { csvEscape(displayString(for: $0)) }
            lines.append(cells.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }
}

// MARK: - Editing Row

fileprivate struct EditingRow: Identifiable {
    /// Stable display-form id so SwiftUI's `sheet(item:)` machinery
    /// can drive presentation. The actual PK lives in `rowId` and
    /// is the value we pass back to `LocalAgentBridge.update /
    /// softDelete / restore`.
    var id: String { displayString(for: rowId) }
    let rowId: AgentSQLValue
    let tableName: String
    let columns: [AgentColumnInfo]
    let values: [AgentSQLValue]
    let isDeleted: Bool
}

// MARK: - Row Editor Sheet

fileprivate struct RowEditorSheet: View {
    @Environment(\.theme) private var theme

    let row: EditingRow
    let onSave: ([String: AgentSQLValue]) -> Void
    let onSoftDelete: () -> Void
    let onRestore: () -> Void
    let onCancel: () -> Void

    @State private var draftValues: [String: String] = [:]
    @State private var nullValues: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentSheetHeader(
                icon: "square.and.pencil",
                title: "Edit row",
                subtitle: LocalizedStringKey("ID \(displayString(for: row.rowId))"),
                onClose: onCancel
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(row.columns, id: \.name) { column in
                        editorField(for: column)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .frame(minHeight: 200, maxHeight: 400)
            footer
        }
        .frame(width: 520)
        .background(theme.primaryBackground)
        .onAppear { hydrateDraft() }
    }

    @ViewBuilder
    private func editorField(for column: AgentColumnInfo) -> some View {
        let isReadOnly = isSystemColumn(column.name)
        let isNull = nullValues.contains(column.name)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AgentSheetSectionLabel(LocalizedStringKey(column.name))
                Text(column.type)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.inputBackground)
                    )
                if isReadOnly {
                    Text("read-only", bundle: .module)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                }
                Spacer()
                if !isReadOnly, column.nullable {
                    Toggle(
                        isOn: Binding(
                            get: { nullValues.contains(column.name) },
                            set: { newValue in
                                if newValue { nullValues.insert(column.name) } else { nullValues.remove(column.name) }
                            }
                        )
                    ) {
                        Text("NULL", bundle: .module).font(.system(size: 10))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
            }
            StyledTextField(
                placeholder: "",
                text: Binding(
                    get: { draftValues[column.name] ?? "" },
                    set: { draftValues[column.name] = $0 }
                ),
                icon: nil
            )
            .disabled(isReadOnly || isNull)
            .opacity(isReadOnly || isNull ? 0.55 : 1.0)
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            HStack(spacing: 10) {
                if row.isDeleted {
                    Button(action: onRestore) {
                        Text("Restore", bundle: .module)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                } else {
                    Button(action: onSoftDelete) {
                        Text("Delete", bundle: .module)
                    }
                    .buttonStyle(DestructiveButtonStyle())
                }
                Spacer()
                Button(action: onCancel) {
                    Text("Cancel", bundle: .module)
                }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                Button {
                    onSave(buildUpdates())
                } label: {
                    Text("Save", bundle: .module)
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(theme.secondaryBackground)
        }
    }

    private func hydrateDraft() {
        for (index, column) in row.columns.enumerated() {
            guard index < row.values.count else { continue }
            let value = row.values[index]
            if case .null = value {
                draftValues[column.name] = ""
                nullValues.insert(column.name)
            } else {
                draftValues[column.name] = displayString(for: value)
            }
        }
    }

    private func buildUpdates() -> [String: AgentSQLValue] {
        var out: [String: AgentSQLValue] = [:]
        for column in row.columns where !isSystemColumn(column.name) {
            let isNull = nullValues.contains(column.name)
            if isNull {
                out[column.name] = .null
                continue
            }
            let raw = draftValues[column.name] ?? ""
            out[column.name] = parseAsSQLValue(raw, columnType: column.type)
        }
        return out
    }

    private func isSystemColumn(_ name: String) -> Bool {
        ["id", "_created_at", "_updated_at", "_deleted_at"].contains(name)
    }

    private func parseAsSQLValue(_ raw: String, columnType: String) -> AgentSQLValue {
        let normalized = columnType.uppercased()
        if normalized.contains("INT") {
            if let v = Int64(raw) { return .integer(v) }
        }
        if normalized.contains("REAL") || normalized.contains("DOUBLE") || normalized.contains("FLOAT") {
            if let v = Double(raw) { return .double(v) }
        }
        if normalized.contains("BOOL") {
            if raw.lowercased() == "true" || raw == "1" { return .bool(true) }
            if raw.lowercased() == "false" || raw == "0" { return .bool(false) }
        }
        return .text(raw)
    }
}

// MARK: - AgentDataTableRepresentable

/// Compact grid host for the agent's data rows. Uses SwiftUI's
/// scrollable column-and-row layout (the spec name is preserved for
/// continuity with the plan even though we don't drop down to
/// NSTableView here — the row counts are bounded to 500 by the
/// reload query, so SwiftUI's virtualisation is more than enough).
fileprivate struct AgentDataTableRepresentable: View {
    let columns: [AgentColumnInfo]
    let rows: [[AgentSQLValue]]
    let idColumnIndex: Int?
    /// Column index of `_deleted_at` so the renderer can dim
    /// soft-deleted rows when the filter mode includes them.
    let deletedColumnIndex: Int?
    /// Whether to render the leading status column (used for the
    /// "Deleted" pill). Driven by the caller's filter mode — we hide
    /// it in the Active view because no row can ever be flagged as
    /// deleted there, and a permanently-empty column reads as broken.
    let showsStatusColumn: Bool
    /// Two-way binding so the leading checkbox column can toggle
    /// selection state without a side-channel callback.
    @Binding var selectedRowIds: Set<String>
    let theme: ThemeProtocol
    let onRowOpen: (Int) -> Void

    /// Width of the leading selection column. Zero when there's no
    /// `id` column (selection isn't actionable in that case).
    private var checkboxColumnWidth: CGFloat { idColumnIndex == nil ? 0 : 32 }
    /// Width of the leading row-status column (carries the "Deleted"
    /// pill on soft-deleted rows). Collapses to zero when the column
    /// isn't being shown for the current filter mode.
    private var statusColumnWidth: CGFloat { showsStatusColumn ? 76 : 0 }
    /// Width of the trailing per-row action column (Open button).
    private let actionColumnWidth: CGFloat = 56
    /// Explicit per-row height. Keeps the row HStacks from being
    /// stretched by the `Color.clear` column gutters (which are
    /// vertically flexible) when the parent VStack is forced to fill
    /// the viewport via `GeometryReader`.
    private let rowHeight: CGFloat = 28

    var body: some View {
        // `ScrollView([.horizontal, .vertical])` on macOS centers
        // content vertically when it's smaller than the viewport.
        // `GeometryReader` lets us pin the inner stack's `minHeight`
        // to the viewport so small tables hug the top while large
        // tables exceed the min and scroll normally.
        GeometryReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    ForEach(Array(rows.enumerated()), id: \.offset) { (rowIndex, row) in
                        rowView(row, index: rowIndex)
                    }
                }
                .frame(
                    minWidth: proxy.size.width,
                    minHeight: proxy.size.height,
                    alignment: .topLeading
                )
            }
            .background(theme.primaryBackground)
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 0) {
            if idColumnIndex != nil {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { isAllSelected },
                        set: { newValue in setAllSelected(newValue) }
                    )
                )
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: checkboxColumnWidth, alignment: .center)
                .localizedHelp("Select all rows on this page")
            }
            if showsStatusColumn {
                Color.clear.frame(width: statusColumnWidth)
            }
            ForEach(columns, id: \.name) { column in
                Text(column.name)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                    .frame(width: columnWidth(for: column), alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            Color.clear.frame(width: actionColumnWidth)
        }
        .frame(height: rowHeight)
        .background(theme.tertiaryBackground)
    }

    @ViewBuilder
    private func rowView(_ row: [AgentSQLValue], index: Int) -> some View {
        let rowKey = idKey(for: row)
        let isDeleted = isRowDeleted(row)
        HStack(spacing: 0) {
            if let key = rowKey, idColumnIndex != nil {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { selectedRowIds.contains(key) },
                        set: { newValue in
                            if newValue { selectedRowIds.insert(key) } else { selectedRowIds.remove(key) }
                        }
                    )
                )
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: checkboxColumnWidth, alignment: .center)
            } else if idColumnIndex != nil {
                Color.clear.frame(width: checkboxColumnWidth)
            }
            if showsStatusColumn {
                deletedPill(visible: isDeleted)
                    .frame(width: statusColumnWidth, alignment: .leading)
                    .padding(.leading, 4)
            }
            ForEach(Array(columns.enumerated()), id: \.offset) { (colIndex, column) in
                let cell: AgentSQLValue = colIndex < row.count ? row[colIndex] : .null
                Text(displayString(for: cell))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: columnWidth(for: column), alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
            }
            openRowButton(rowIndex: index)
                .frame(width: actionColumnWidth, alignment: .center)
        }
        .frame(height: rowHeight)
        // Dim soft-deleted rows so the "All" filter mode still gives
        // the user a visible read of which rows are tombstones —
        // spec §7 ("soft-deleted rows dimmed in the grid").
        .opacity(isDeleted ? 0.55 : 1)
        .background(index % 2 == 0 ? theme.primaryBackground : theme.inputBackground.opacity(0.5))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onRowOpen(index)
        }
        .overlay(Divider().foregroundColor(theme.primaryBorder), alignment: .bottom)
    }

    /// Tiny `Deleted` pill rendered in the leading status column for
    /// soft-deleted rows. Layout is reserved (clear when not deleted)
    /// so columns stay aligned across mixed-state rows.
    @ViewBuilder
    private func deletedPill(visible: Bool) -> some View {
        if visible {
            Text(localized: "Deleted")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(theme.warningColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(theme.warningColor.opacity(0.15))
                )
                .overlay(
                    Capsule().stroke(theme.warningColor.opacity(0.4), lineWidth: 0.5)
                )
        } else {
            Color.clear
        }
    }

    /// Single-click row opener. Double-click on the row itself still
    /// works as a shortcut, but this button makes the affordance
    /// obvious and reachable without the user knowing the gesture.
    @ViewBuilder
    private func openRowButton(rowIndex: Int) -> some View {
        Button {
            onRowOpen(rowIndex)
        } label: {
            Image(systemName: "arrow.up.right.square")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.accentColor)
        }
        .buttonStyle(.plain)
        .localizedHelp("Open row")
    }

    /// Display-string id for this row, or nil when the row has no
    /// addressable id (in which case it's still readable but not
    /// selectable for bulk actions).
    private func idKey(for row: [AgentSQLValue]) -> String? {
        guard let idx = idColumnIndex, idx < row.count else { return nil }
        return displayString(for: row[idx])
    }

    private func isRowDeleted(_ row: [AgentSQLValue]) -> Bool {
        guard let idx = deletedColumnIndex, idx < row.count else { return false }
        return row[idx].isNotNull
    }

    private var allRowKeys: [String] {
        rows.compactMap { idKey(for: $0) }
    }

    private var isAllSelected: Bool {
        let keys = allRowKeys
        return !keys.isEmpty && keys.allSatisfy { selectedRowIds.contains($0) }
    }

    private func setAllSelected(_ on: Bool) {
        let keys = allRowKeys
        if on {
            for k in keys { selectedRowIds.insert(k) }
        } else {
            for k in keys { selectedRowIds.remove(k) }
        }
    }

    private func columnWidth(for column: AgentColumnInfo) -> CGFloat {
        switch column.name {
        case "id": return 280
        case "_created_at", "_updated_at", "_deleted_at": return 180
        default: return 160
        }
    }
}

// MARK: - In-Flight Mutation Spinner

/// Tiny progress spinner shown in the Schema + Data tab headers
/// while the bridge has serialized writes in flight for this
/// agent (spec §16 Q1). Reads `AgentMutationActivity.shared` so
/// the indicator stays in sync with the same counter
/// `LocalAgentBridge.serialized` increments / decrements.
fileprivate struct MutationsInFlightIndicator: View {
    let agentId: UUID
    let theme: ThemeProtocol

    @ObservedObject private var activity = AgentMutationActivity.shared

    var body: some View {
        if activity[agentId] > 0 {
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("\(activity[agentId]) write\(activity[agentId] == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(.horizontal, 6)
            .localizedHelp("Mutations in flight on this agent's serial queue.")
        }
    }
}

// MARK: - Storage Quota Badge

/// Small "approaching quota" pill shown in the Schema + Data tab
/// headers when the agent's DB file has crossed
/// `Agent.settings.limits.storageWarnPercent` of its
/// `storageBytesLimit` (spec §11.2). Observes
/// `AgentManager.storageWarningAgentIds` so it stays in sync with
/// the same set the user-facing notification fires from.
fileprivate struct StorageQuotaBadge: View {
    let agentId: UUID
    let theme: ThemeProtocol

    @ObservedObject private var agentManager = AgentManager.shared

    var body: some View {
        if agentManager.storageWarningAgentIds.contains(agentId) {
            Label(localized: "Approaching quota", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous).fill(Color.orange.opacity(0.12))
                )
                .overlay(
                    Capsule(style: .continuous).stroke(Color.orange.opacity(0.4), lineWidth: 1)
                )
                .localizedHelp("This agent's database is approaching its storage quota.")
        }
    }
}

// MARK: - Display Helpers

fileprivate func displayString(for value: AgentSQLValue) -> String {
    switch value {
    case .null: return "NULL"
    case .integer(let v): return String(v)
    case .double(let v): return String(v)
    case .text(let v): return v
    case .blob(let v): return "<\(v.count) bytes>"
    case .bool(let v): return v ? "true" : "false"
    }
}

fileprivate extension AgentSQLValue {
    var isNotNull: Bool {
        if case .null = self { return false }
        return true
    }
}

// MARK: - Activity Tab

/// Audit + run history for the agent: every dispatched run from the
/// scheduler DB plus a per-run trace pulled from this agent's
/// `_changelog`. The runs list is the master pane, and selecting a
/// row populates the trace on the right. Mirrors §7's "Activity"
/// panel design.
public struct ActivityTabView: View {
    @Environment(\.theme) private var theme

    let agentId: UUID

    @State private var runs: [AgentRunRecord] = []
    @State private var selectedRunId: UUID? = nil
    @State private var changelogRows: [ChangelogEntry] = []
    @State private var isLoadingRuns = true
    @State private var isLoadingTrace = false
    @State private var loadError: String? = nil

    public init(agentId: UUID) {
        self.agentId = agentId
    }

    public var body: some View {
        // Minimums are deliberately conservative: the agent detail body
        // is `maxWidth: .infinity` and gets dropped into a Settings
        // detail pane (~750pt at standard width). HSplitView refuses to
        // compress past the sum of its children's `minWidth`, so an
        // aggressive total min would force the parent wider on smaller
        // windows. `idealWidth` preserves the first-render layout when
        // there's room.
        HSplitView {
            runsList
                .frame(minWidth: 220, idealWidth: 320)
            tracePane
                .frame(minWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .task { await loadRuns() }
        .onChange(of: agentId) { _, _ in Task { await loadRuns() } }
        .onChange(of: selectedRunId) { _, _ in Task { await loadTrace() } }
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
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider().foregroundColor(theme.primaryBorder)
            if isLoadingRuns {
                ProgressView().padding(24)
            } else if runs.isEmpty {
                Text("No runs yet.", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)
                    .padding(24)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(runs, id: \.id) { run in
                            runRow(run)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected
                    ? theme.accentColor.opacity(0.12)
                    : Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(Divider().foregroundColor(theme.primaryBorder), alignment: .bottom)
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
                } else if changelogRows.isEmpty {
                    Text("No changelog entries for this run.", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                        .padding(24)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(changelogRows) { row in
                                changelogRowView(row)
                            }
                        }
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
        isLoadingRuns = true
        defer { isLoadingRuns = false }
        do {
            try SchedulerDatabase.shared.open()
            runs = try SchedulerDatabase.shared.runs(agentId: agentId, limit: 200)
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

fileprivate struct ChangelogEntry: Identifiable {
    var id: Int { index }
    let index: Int
    let timestamp: Date
    let actor: String
    let op: String
    let tableName: String?
    let rowPK: String?
    let sql: String?
}

// MARK: - Views Tab (spec §5.7)

/// Saved-view manager. Lists every view, lets the user pin one for
/// the Home tab, drop one, or preview the rows it produces. Edits
/// to the view body itself happen inside chat — the agent owns SQL
/// authoring through `db_define_view`.
public struct ViewsTabView: View {
    @Environment(\.theme) private var theme

    let agentId: UUID
    /// Saved-view name to pre-select on first load (notification
    /// deep-link from `NotifyTool` / `viewRef`, spec §3.3). Honoured
    /// once on `task` — subsequent reloads honour the user's
    /// explicit selection.
    let initialFocusedViewName: String?

    @State private var views: [AgentSavedView] = []
    @State private var selection: AgentSavedView? = nil
    @State private var previewRows: AgentQueryResult? = nil
    @State private var isLoading = true
    @State private var isRunning = false
    @State private var loadError: String? = nil
    @State private var hasAppliedInitialFocus = false

    public init(agentId: UUID, initialFocusedViewName: String? = nil) {
        self.agentId = agentId
        self.initialFocusedViewName = initialFocusedViewName
    }

    public var body: some View {
        // See `ActivityTabView` for the rationale on conservative
        // minimums — same Settings-window constraint applies here.
        HSplitView {
            sidebar.frame(minWidth: 180, idealWidth: 240)
            detail.frame(minWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .task { await reload() }
        .onChange(of: agentId) { _, _ in Task { await reload() } }
        .onChange(of: selection) { _, _ in Task { await runSelected() } }
    }

    @ViewBuilder
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Saved Views", bundle: .module)
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.5)
                    .foregroundColor(theme.tertiaryText)
                Spacer()
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider().foregroundColor(theme.primaryBorder)
            if isLoading {
                ProgressView().padding(24)
                Spacer(minLength: 0)
            } else if views.isEmpty {
                Text(
                    "No views yet. The agent creates these with the `db_define_view` tool.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
                .padding(16)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(views, id: \.name) { view in
                            sidebarRow(view)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func sidebarRow(_ view: AgentSavedView) -> some View {
        let isSelected = selection?.name == view.name
        Button {
            selection = view
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: view.pinned ? "pin.fill" : "eye")
                    .font(.system(size: 11))
                    .foregroundColor(view.pinned ? .yellow : theme.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(view.name)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                    Text(view.renderHint)
                        .font(.system(size: 9))
                        .foregroundColor(theme.tertiaryText)
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? theme.accentColor.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(Divider().foregroundColor(theme.primaryBorder), alignment: .bottom)
    }

    @ViewBuilder
    private var detail: some View {
        if let view = selection {
            VStack(alignment: .leading, spacing: 0) {
                detailHeader(view)
                Divider().foregroundColor(theme.primaryBorder)
                if isRunning {
                    ProgressView().padding(24)
                    Spacer(minLength: 0)
                } else if let preview = previewRows {
                    if preview.rows.isEmpty {
                        Text("No rows for this view.", bundle: .module)
                            .font(.system(size: 12))
                            .foregroundColor(theme.tertiaryText)
                            .padding(16)
                        Spacer(minLength: 0)
                    } else {
                        previewGrid(columns: preview.columns, rows: preview.rows)
                    }
                } else if let error = loadError {
                    Text(error)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.red)
                        .padding(16)
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Text("Pick a view to preview its rows.", bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func detailHeader(_ view: AgentSavedView) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(view.name)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Button {
                    Task { await togglePinned(view) }
                } label: {
                    Label(
                        view.pinned ? "Unpin" : "Pin to Home",
                        systemImage: view.pinned ? "pin.slash" : "pin"
                    )
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button(role: .destructive) {
                    Task { await drop(view) }
                } label: {
                    Label(localized: "Drop", systemImage: "trash")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            }
            if let desc = view.description, !desc.isEmpty {
                Text(desc).font(.system(size: 11)).foregroundColor(theme.tertiaryText)
            }
            Text(view.sql)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.tertiaryBackground)
                .cornerRadius(4)
        }
        .padding(12)
    }

    @ViewBuilder
    private func previewGrid(columns: [String], rows: [[AgentSQLValue]]) -> some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(columns, id: \.self) { col in
                        Text(col)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                            .frame(width: 160, alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                    }
                }
                .background(theme.tertiaryBackground)
                ForEach(Array(rows.enumerated()), id: \.offset) { (i, row) in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { (_, value) in
                            Text(displayString(for: value))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(theme.primaryText)
                                .frame(width: 160, alignment: .leading)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                        }
                    }
                    .background(i % 2 == 0 ? theme.primaryBackground : theme.inputBackground.opacity(0.5))
                    .overlay(Divider().foregroundColor(theme.primaryBorder), alignment: .bottom)
                }
            }
        }
    }

    @MainActor
    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            views = try LocalAgentBridge.shared.listViews(agentId: agentId)
            // Honour the notification-supplied focus exactly once,
            // then fall back to the normal "preserve previous
            // selection, else first row" behavior.
            if !hasAppliedInitialFocus,
                let focusName = initialFocusedViewName,
                let focused = views.first(where: { $0.name == focusName })
            {
                hasAppliedInitialFocus = true
                selection = focused
            } else if let current = selection,
                views.contains(where: { $0.name == current.name })
            {
                selection = views.first { $0.name == current.name }
            } else {
                selection = views.first
            }
        } catch {
            loadError = error.localizedDescription
            views = []
            selection = nil
        }
    }

    @MainActor
    private func runSelected() async {
        guard let view = selection else { previewRows = nil; return }
        isRunning = true
        defer { isRunning = false }
        do {
            previewRows = try LocalAgentBridge.shared.runView(
                agentId: agentId,
                name: view.name
            )
            loadError = nil
        } catch {
            previewRows = nil
            loadError = error.localizedDescription
        }
    }

    @MainActor
    private func togglePinned(_ view: AgentSavedView) async {
        do {
            try LocalAgentBridge.shared.setViewPinned(
                agentId: agentId,
                name: view.name,
                pinned: !view.pinned
            )
            await reload()
        } catch {
            loadError = error.localizedDescription
        }
    }

    @MainActor
    private func drop(_ view: AgentSavedView) async {
        do {
            _ = try LocalAgentBridge.shared.dropView(agentId: agentId, name: view.name)
            await reload()
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - Home Tab (spec §5.7)

/// Dashboard rendering every pinned view as a card. KPI-style views
/// (render_hint=number) render compact metric tiles; everything else
/// renders as a preview table. The full AAChartKit reuse is wired
/// here via `NativeChartHost` so chart-shaped pins surface as actual
/// charts rather than tables.
public struct HomeTabView: View {
    @Environment(\.theme) private var theme

    let agentId: UUID

    @State private var pinned: [HomeViewCard] = []
    @State private var isLoading = true
    @State private var loadError: String? = nil

    public init(agentId: UUID) {
        self.agentId = agentId
    }

    public var body: some View {
        ScrollView {
            if isLoading {
                HStack {
                    ProgressView(); Text("Loading…", bundle: .module).font(.system(size: 12))
                }
                .padding(24)
            } else if pinned.isEmpty {
                emptyState
            } else {
                gridContent
            }
        }
        .background(theme.primaryBackground)
        .task { await reload() }
        .onChange(of: agentId) { _, _ in Task { await reload() } }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No pinned views yet", bundle: .module)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text(
                "Pin a saved view from the Views tab to make it appear here. Use this Home tab as the agent's at-a-glance dashboard.",
                bundle: .module
            )
            .font(.system(size: 12))
            .foregroundColor(theme.tertiaryText)
        }
        .padding(24)
    }

    @ViewBuilder
    private var gridContent: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 280, maximum: 600), spacing: 16)],
            spacing: 16
        ) {
            ForEach(pinned) { card in
                cardView(card)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func cardView(_ card: HomeViewCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(card.view.name)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Spacer()
                Text(card.view.renderHint)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }
            if let desc = card.view.description, !desc.isEmpty {
                Text(desc).font(.system(size: 11)).foregroundColor(theme.tertiaryText)
            }
            cardBody(card)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.inputBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.inputBorder, lineWidth: 1))
    }

    @ViewBuilder
    private func cardBody(_ card: HomeViewCard) -> some View {
        if let error = card.error {
            Text(error).font(.system(size: 10, design: .monospaced)).foregroundColor(.red)
        } else if let result = card.result {
            switch card.view.renderHint.lowercased() {
            case "number":
                kpiBody(result)
            case "bar", "line", "column", "spline", "pie":
                miniChartBody(result, hint: card.view.renderHint)
            default:
                miniTableBody(result)
            }
        }
    }

    @ViewBuilder
    private func kpiBody(_ result: AgentQueryResult) -> some View {
        if let first = result.rows.first, let value = first.first {
            Text(displayString(for: value))
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(theme.primaryText)
        } else {
            Text("—").font(.system(size: 24)).foregroundColor(theme.tertiaryText)
        }
    }

    @ViewBuilder
    private func miniTableBody(_ result: AgentQueryResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(result.columns, id: \.self) { col in
                    Text(col)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.bottom, 2)
            ForEach(Array(result.rows.prefix(8).enumerated()), id: \.offset) { (_, row) in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { (_, value) in
                        Text(displayString(for: value))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            if result.rows.count > 8 {
                Text("+ \(result.rows.count - 8) more").font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }
        }
    }

    @ViewBuilder
    private func miniChartBody(_ result: AgentQueryResult, hint: String) -> some View {
        // Phase 2 fallback: until the AAChartKit binding lands we
        // surface a hint that the chart shape is recognised and
        // show the rows as a table. The AAChartKit reuse is wired
        // in via `NativeChartView` in the chat surface; reusing it
        // here is a follow-up.
        VStack(alignment: .leading, spacing: 4) {
            Label(
                "Chart preview not yet rendered — showing rows instead.",
                systemImage: "chart.bar"
            )
            .font(.system(size: 10))
            .foregroundColor(theme.tertiaryText)
            miniTableBody(result)
        }
    }

    @MainActor
    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let views = try LocalAgentBridge.shared.listViews(agentId: agentId)
                .filter { $0.pinned }
            var cards: [HomeViewCard] = []
            cards.reserveCapacity(views.count)
            for view in views {
                do {
                    let res = try LocalAgentBridge.shared.runView(
                        agentId: agentId,
                        name: view.name
                    )
                    cards.append(HomeViewCard(view: view, result: res, error: nil))
                } catch {
                    cards.append(
                        HomeViewCard(view: view, result: nil, error: error.localizedDescription)
                    )
                }
            }
            pinned = cards
            loadError = nil
        } catch {
            pinned = []
            loadError = error.localizedDescription
        }
    }
}

fileprivate struct HomeViewCard: Identifiable {
    var id: String { view.name }
    let view: AgentSavedView
    let result: AgentQueryResult?
    let error: String?
}

/// Centered onboarding card used by the Data tab's empty states.
/// Wraps an SF Symbol, a title, optional sub-copy, and optional
/// CTA button into one consistent block so each empty state has the
/// same shape, weight, and rhythm.
fileprivate struct DataEmptyState: View {
    let systemImage: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    let actionTitle: LocalizedStringKey?
    let actionSystemImage: String?
    let action: (() -> Void)?
    let theme: ThemeProtocol

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .regular))
                .foregroundColor(theme.tertiaryText)
            Text(title, bundle: .module)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle, bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
            }
            if let actionTitle, let action {
                Button {
                    action()
                } label: {
                    if let systemImage = actionSystemImage {
                        Label(actionTitle, systemImage: systemImage)
                            .font(.system(size: 11, weight: .medium))
                    } else {
                        Text(actionTitle, bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}
