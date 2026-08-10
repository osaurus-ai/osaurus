//
//  DatabaseTablesView.swift
//  osaurus
//
//  The Database workspace's Tables section: one surface that merges
//  the old Schema and Data tabs. A persistent table list sits on the
//  left; the right pane shows the selected table's rows (virtualized,
//  incrementally paged) or its structure (columns + indexes) behind a
//  simple Rows / Columns switch.
//
//  All reads go through `AgentDataBrowserModel` (paged `db_query` via
//  `LocalAgentBridge`) so they stay encrypted and audit-visible. Edits
//  flow through `LocalAgentBridge.update / softDelete(Many) / restore`
//  so `_changelog` gets stamped correctly and the per-agent serial
//  queue holds the write order.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DatabaseTablesView: View {
    @Environment(\.theme) private var theme

    let agentId: UUID
    /// Table to focus. Set by the workspace when a deep-link carries a
    /// `tableRef` (e.g. a notification or an older `data`/`schema` link).
    let focusedTableName: String?

    @State private var tables: [AgentTableSchema] = []
    @State private var schemaError: String? = nil
    @State private var selectedTable: String? = nil
    @State private var viewMode: TableViewMode = .rows
    @State private var filterMode: DataFilterMode = .live
    @StateObject private var browser: AgentDataBrowserModel
    @State private var selectedRowKeys: Set<String> = []
    @State private var editingRow: EditingDatabaseRow? = nil
    @State private var showBulkDeleteConfirm = false
    @State private var showFilterHelp = false
    @State private var hasAppliedInitialFocus = false
    /// First-load tip caption surfaced above the grid. Dismissed once
    /// the user clicks the inline `x`; persisted across sessions.
    @AppStorage("agentDataTipDismissed") private var dataTipDismissed: Bool = false
    @State private var isImporting = false
    @State private var importSummary: String? = nil
    @State private var isDropTargeted = false
    @State private var isExporting = false
    @State private var actionError: String? = nil

    @ObservedObject private var mutationActivity = AgentMutationActivity.shared

    private enum TableViewMode: String, CaseIterable, Identifiable {
        case rows
        case structure

        var id: String { rawValue }

        var label: String {
            switch self {
            case .rows: return L("Rows")
            case .structure: return L("Columns")
            }
        }
    }

    init(agentId: UUID, focusedTableName: String? = nil) {
        self.agentId = agentId
        self.focusedTableName = focusedTableName
        _browser = StateObject(
            wrappedValue: AgentDataBrowserModel(
                backend: AgentDataBrowserModel.liveBackend(agentId: agentId)
            )
        )
    }

    var body: some View {
        Group {
            if let error = schemaError {
                schemaErrorState(error)
            } else if userTables.isEmpty && systemTables.isEmpty {
                noTablesEmptyState
            } else {
                HSplitView {
                    tableList
                        .frame(minWidth: 180, idealWidth: 230, maxWidth: 340)
                    detailPane
                        .frame(minWidth: 320, maxWidth: .infinity)
                        .layoutPriority(1)
                }
            }
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
        .task { await loadTables(applyFocus: true) }
        .onChange(of: agentId) { _, _ in
            Task { await loadTables(applyFocus: true) }
        }
        .onChange(of: focusedTableName) { _, newValue in
            guard let newValue, allTables.contains(where: { $0.name == newValue }) else { return }
            selectedTable = newValue
        }
        .onChange(of: selectedTable) { _, _ in
            selectedRowKeys.removeAll()
            actionError = nil
            reloadBrowser()
        }
        .onChange(of: filterMode) { _, _ in
            selectedRowKeys.removeAll()
            reloadBrowser()
        }
        .onChange(of: mutationActivity[agentId]) { oldValue, newValue in
            // Refresh once the agent's serialized writes settle so the
            // grid doesn't sit stale while the user watches the spinner.
            // Skip when the user has rows checked — clobbering an
            // in-progress bulk selection is worse than staleness.
            guard oldValue > 0, newValue == 0 else { return }
            Task { await loadTables(applyFocus: false) }
            if selectedRowKeys.isEmpty, viewMode == .rows {
                browser.refresh()
            }
        }
        .sheet(item: $editingRow) { row in
            DatabaseRowEditorSheet(
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
        .confirmationDialog(
            selectedRowKeys.count == 1
                ? L("Delete 1 row?")
                : L("Delete \(selectedRowKeys.count) rows?"),
            isPresented: $showBulkDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await bulkSoftDelete() }
            } label: {
                Text(
                    selectedRowKeys.count == 1
                        ? L("Delete 1 Row")
                        : L("Delete \(selectedRowKeys.count) Rows")
                )
            }
            Button(localized: "Cancel", role: .cancel) {}
        } message: {
            Text(
                "These rows are marked deleted, not permanently removed. "
                    + "Switch the filter to \"Deleted\" to restore them later."
            )
        }
    }

    // MARK: - Table collections

    private var allTables: [AgentTableSchema] { tables }

    private var userTables: [AgentTableSchema] {
        tables.filter { !$0.name.hasPrefix("_") }
    }

    /// Host-managed tables (`_changelog`, `_views`, …). Read-only but
    /// browsable so the user can audit what the host records.
    private var systemTables: [AgentTableSchema] {
        tables.filter { $0.name.hasPrefix("_") }
    }

    private var selectedTableSchema: AgentTableSchema? {
        guard let selectedTable else { return nil }
        return tables.first { $0.name == selectedTable }
    }

    private var selectedTableIsSystem: Bool {
        selectedTable?.hasPrefix("_") ?? false
    }

    // MARK: - Table list

    @ViewBuilder
    private var tableList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tables", bundle: .module)
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.5)
                    .foregroundColor(theme.tertiaryText)
                Spacer()
                Button {
                    Task { await loadTables(applyFocus: false) }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .localizedHelp("Refresh the table list")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            Divider().foregroundColor(theme.primaryBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(userTables, id: \.name) { table in
                        tableListRow(table, isSystem: false)
                    }
                    if !systemTables.isEmpty {
                        Text("System (managed by Osaurus)", bundle: .module)
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.5)
                            .foregroundColor(theme.tertiaryText)
                            .padding(.horizontal, 14)
                            .padding(.top, 16)
                            .padding(.bottom, 4)
                        ForEach(systemTables, id: \.name) { table in
                            tableListRow(table, isSystem: true)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.secondaryBackground.opacity(0.25))
    }

    @ViewBuilder
    private func tableListRow(_ table: AgentTableSchema, isSystem: Bool) -> some View {
        let isSelected = selectedTable == table.name
        Button {
            selectedTable = table.name
        } label: {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: isSystem ? "gearshape" : "tablecells")
                    .font(.system(size: 11))
                    .foregroundColor(
                        isSelected ? theme.accentColor : (isSystem ? theme.tertiaryText : theme.secondaryText)
                    )
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(table.name)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(table.rowCount) \(table.rowCount == 1 ? L("row") : L("rows"))")
                        .font(.system(size: 9))
                        .foregroundColor(theme.tertiaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? theme.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .opacity(isSystem && !isSelected ? 0.75 : 1)
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let table = selectedTableSchema {
            VStack(alignment: .leading, spacing: 0) {
                detailHeader(table)
                Divider().foregroundColor(theme.primaryBorder)
                if let actionError {
                    errorBanner(actionError)
                }
                if let summary = importSummary {
                    importSummaryBanner(summary)
                }
                switch viewMode {
                case .rows:
                    rowsPane(table)
                case .structure:
                    structurePane(table)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            DatabaseEmptyState(
                systemImage: "arrow.left",
                title: "Pick a table to see what's inside.",
                subtitle: "Choose one of this agent's tables from the list on the left.",
                actionTitle: nil,
                actionSystemImage: nil,
                action: nil,
                theme: theme
            )
        }
    }

    @ViewBuilder
    private func detailHeader(_ table: AgentTableSchema) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                // Long table names must truncate (middle, so the
                // distinguishing suffix survives) rather than push the
                // Rows/Columns switch out of the pane.
                Text(table.name)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if selectedTableIsSystem {
                    Text("read-only", bundle: .module)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(theme.tertiaryBackground))
                        .fixedSize()
                }
                Spacer(minLength: 8)
                Picker("", selection: $viewMode) {
                    ForEach(TableViewMode.allCases) { mode in
                        Text(verbatim: mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .localizedHelp("Switch between the table's rows and its column layout.")
            }
            if !table.purpose.isEmpty {
                Text(table.purpose)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.secondaryBackground.opacity(0.4))
    }

    // MARK: - Rows pane

    @ViewBuilder
    private func rowsPane(_ table: AgentTableSchema) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            rowsControlBar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            Divider().foregroundColor(theme.primaryBorder)
            if !dataTipDismissed && !browser.rows.isEmpty {
                dataTipCaption
            }
            if browser.isLoadingFirstPage {
                HStack {
                    ProgressView()
                    Text("Loading rows…", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
                .padding(24)
                Spacer(minLength: 0)
            } else if let error = browser.loadError {
                VStack(alignment: .leading, spacing: 6) {
                    Label(localized: "Couldn't load rows", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.red)
                    Text(error)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                }
                .padding(24)
                Spacer(minLength: 0)
            } else if browser.rows.isEmpty {
                noRowsEmptyState
            } else {
                grid
                Divider().foregroundColor(theme.primaryBorder)
                rowsFooter
            }
        }
    }

    @ViewBuilder
    private var rowsControlBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Picker("", selection: $filterMode) {
                    ForEach(DataFilterMode.allCases) { mode in
                        Text(verbatim: mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .labelsHidden()
                filterHelpButton
            }
            .fixedSize(horizontal: true, vertical: false)
            .disabled(selectedTableIsSystem)
            .opacity(selectedTableIsSystem ? 0.4 : 1)

            Spacer(minLength: 8)

            if !selectedRowKeys.isEmpty {
                Button(role: .destructive) {
                    showBulkDeleteConfirm = true
                } label: {
                    Label(localized: "Delete \(selectedRowKeys.count)", systemImage: "trash")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .fixedSize()
            }
            // Icon-only actions keep the bar within the pane's minimum
            // width — the labels live in tooltips instead.
            controlBarIconButton(
                systemImage: "square.and.arrow.down",
                isBusy: isImporting,
                disabled: isImporting || selectedTableIsSystem,
                help: "Import a CSV, TSV, JSON, or JSONL file into this table. You can also drag a file onto this screen."
            ) {
                presentImportPanel()
            }
            controlBarIconButton(
                systemImage: "square.and.arrow.up",
                isBusy: isExporting,
                disabled: isExporting || (browser.totalCount ?? browser.rows.count) == 0,
                help: "Export every matching row to a CSV file — not just the rows loaded here."
            ) {
                exportCSV()
            }
            controlBarIconButton(
                systemImage: "arrow.clockwise",
                isBusy: false,
                disabled: false,
                help: "Reload rows"
            ) {
                browser.refresh()
                Task { await loadTables(applyFocus: false) }
            }
        }
    }

    @ViewBuilder
    private func controlBarIconButton(
        systemImage: String,
        isBusy: Bool,
        disabled: Bool,
        help: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .frame(width: 16, height: 14)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(disabled)
        .help(Text(help, bundle: .module))
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
                        Text(verbatim: mode.label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                        Text(verbatim: mode.helpDescription)
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

    /// One-line dismissable caption that teaches the affordances on
    /// the grid (Open button, checkbox selection, dimmed deleted rows).
    @ViewBuilder
    private var dataTipCaption: some View {
        HStack(spacing: 8) {
            Image(systemName: "lightbulb")
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
            Text(
                "Double-click a row (or press ↗) to open it · check rows to delete several at once · deleted rows are dimmed.",
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

    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundColor(.red)
            Text(verbatim: message)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button {
                actionError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.08))
    }

    /// Thin info banner shown after a successful import.
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

    // MARK: - Grid

    private var canSelectRows: Bool {
        !selectedTableIsSystem && browser.idColumnIndex != nil && !browser.rows.isEmpty
    }

    private var allLoadedSelectedBinding: Binding<Bool> {
        Binding(
            get: {
                let keys = loadedRowKeys
                return !keys.isEmpty && keys.allSatisfy { selectedRowKeys.contains($0) }
            },
            set: { newValue in
                if newValue {
                    selectedRowKeys.formUnion(loadedRowKeys)
                } else {
                    selectedRowKeys.removeAll()
                }
            }
        )
    }

    private var loadedRowKeys: [String] {
        guard let idIdx = browser.idColumnIndex else { return [] }
        return browser.rows.compactMap { row in
            guard idIdx < row.count else { return nil }
            return agentSQLDisplayString(row[idIdx])
        }
    }

    private var gridColumns: [DataGridColumn] {
        browser.columnNames.map { name in
            DataGridColumn(title: name, width: DataGridColumn.preferredWidth(forColumnNamed: name))
        }
    }

    private var gridRows: [DataGridRowData] {
        let idIdx = browser.idColumnIndex
        let deletedIdx = browser.deletedColumnIndex
        return browser.rows.enumerated().map { index, row in
            let key: String
            let selectable: Bool
            if let idIdx, idIdx < row.count, row[idIdx].isNotNull {
                key = agentSQLDisplayString(row[idIdx])
                selectable = !selectedTableIsSystem
            } else {
                key = "row-\(index)"
                selectable = false
            }
            let isDeleted: Bool = {
                guard let deletedIdx, deletedIdx < row.count else { return false }
                return row[deletedIdx].isNotNull
            }()
            return DataGridRowData(
                key: key,
                cells: row.map(agentSQLDisplayString),
                isDeleted: isDeleted,
                selectable: selectable
            )
        }
    }

    @ViewBuilder
    private var grid: some View {
        AgentDataGridRepresentable(
            columns: gridColumns,
            rows: gridRows,
            showsSelectionColumn: canSelectRows,
            // Only reserve a leading status column when deleted rows can
            // actually appear in the current filter — keeps the default
            // Active view from showing a permanently-empty column.
            showsStatusColumn: filterMode != .live && browser.deletedColumnIndex != nil,
            showsOpenColumn: !selectedTableIsSystem,
            selectedRowKeys: $selectedRowKeys,
            theme: theme,
            onRowOpen: { rowIndex in
                openEditor(for: rowIndex)
            },
            onNeedsMoreRows: {
                browser.loadMoreIfNeeded()
            }
        )
    }

    @ViewBuilder
    private var rowsFooter: some View {
        HStack(spacing: 8) {
            if let total = browser.totalCount {
                Text("Showing \(browser.rows.count) of \(total) \(total == 1 ? L("row") : L("rows"))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            } else {
                Text("Showing \(browser.rows.count) \(browser.rows.count == 1 ? L("row") : L("rows"))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }
            if browser.isLoadingMore {
                ProgressView().controlSize(.mini)
                Text("Loading more…", bundle: .module)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            } else if browser.hasMore {
                Button {
                    browser.loadMoreIfNeeded()
                } label: {
                    Text("Load more", bundle: .module)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .localizedHelp("More rows load automatically as you scroll — this fetches the next batch now.")
            }
            Spacer(minLength: 8)
            if !selectedRowKeys.isEmpty {
                Text("\(selectedRowKeys.count) selected")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.accentColor)
            }
            if canSelectRows {
                Toggle(isOn: allLoadedSelectedBinding) {
                    Text("Select all", bundle: .module)
                        .font(.system(size: 10))
                        .foregroundColor(theme.secondaryText)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .fixedSize()
                .localizedHelp("Select every row loaded so far (\(browser.rows.count))")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(theme.secondaryBackground.opacity(0.4))
    }

    @ViewBuilder
    private var noRowsEmptyState: some View {
        let tableLabel = selectedTable ?? "this table"
        Group {
            switch filterMode {
            case .deleted:
                DatabaseEmptyState(
                    systemImage: "trash.slash",
                    title: "No deleted rows in `\(tableLabel)`.",
                    subtitle: "Rows the agent (or you) deleted would appear here, ready to restore.",
                    actionTitle: nil,
                    actionSystemImage: nil,
                    action: nil,
                    theme: theme
                )
            case .live, .all:
                DatabaseEmptyState(
                    systemImage: "tray",
                    title: "No rows in `\(tableLabel)` yet.",
                    subtitle:
                        "The agent adds rows when it has something to remember. You can also ask it directly in chat, or import a file.",
                    actionTitle: "Import a file…",
                    actionSystemImage: "square.and.arrow.down",
                    action: selectedTableIsSystem ? nil : { presentImportPanel() },
                    theme: theme
                )
            }
        }
    }

    // MARK: - Structure pane

    @ViewBuilder
    private func structurePane(_ table: AgentTableSchema) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Columns", bundle: .module)
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.5)
                        .foregroundColor(theme.tertiaryText)
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
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.inputBackground))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.inputBorder, lineWidth: 1))

                if !table.indexes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Indexes", bundle: .module)
                            .font(.system(size: 11, weight: .bold))
                            .tracking(0.5)
                            .foregroundColor(theme.tertiaryText)
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
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.inputBackground))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.inputBorder, lineWidth: 1))
                }

                Text(
                    "The agent designs this layout itself with the `db_create_table` tool. Ask it in chat if you want new columns.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Empty / error states

    @ViewBuilder
    private var noTablesEmptyState: some View {
        DatabaseEmptyState(
            systemImage: "tablecells.badge.ellipsis",
            title: "This agent hasn't stored anything yet.",
            subtitle:
                "Ask the agent in chat to remember something — it will create the tables it needs, and you can browse them here. You can also import a CSV or JSON file to start a table yourself.",
            actionTitle: "Import a file…",
            actionSystemImage: "square.and.arrow.down",
            action: { presentImportPanel() },
            theme: theme
        )
    }

    @ViewBuilder
    private func schemaErrorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(localized: "Couldn't open the database", systemImage: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.red)
            Text(message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Loading

    @MainActor
    private func loadTables(applyFocus: Bool) async {
        schemaError = nil
        do {
            let snapshot = try LocalAgentBridge.shared.schema(agentId: agentId)
            tables = snapshot.tables
            if applyFocus, !hasAppliedInitialFocus,
                let pin = focusedTableName,
                tables.contains(where: { $0.name == pin })
            {
                hasAppliedInitialFocus = true
                selectedTable = pin
            } else if let current = selectedTable,
                tables.contains(where: { $0.name == current })
            {
                // Keep current selection.
            } else {
                selectedTable = userTables.first?.name
            }
        } catch {
            schemaError = error.localizedDescription
        }
    }

    private func reloadBrowser() {
        guard let table = selectedTableSchema else {
            browser.clear()
            return
        }
        browser.load(
            table: table.name,
            schemaColumns: table.columns,
            filter: selectedTableIsSystem ? .all : filterMode
        )
    }

    // MARK: - Edit

    private func openEditor(for rowIndex: Int) {
        guard !selectedTableIsSystem else { return }
        guard rowIndex >= 0, rowIndex < browser.rows.count else { return }
        let row = browser.rows[rowIndex]
        guard let idIdx = browser.idColumnIndex, idIdx < row.count else { return }
        let deletedIdx = browser.deletedColumnIndex
        // The default `id` column is `INTEGER PRIMARY KEY AUTOINCREMENT`,
        // but agents can declare their own TEXT/INTEGER PKs, so we
        // round-trip the value through `AgentSQLValue` rather than
        // committing to one type at this layer.
        editingRow = EditingDatabaseRow(
            rowId: row[idIdx],
            tableName: selectedTable ?? "",
            columns: browser.columns,
            values: row,
            isDeleted: filterMode == .deleted
                || (deletedIdx.map { $0 < row.count && row[$0].isNotNull } ?? false)
        )
    }

    @MainActor
    private func applyUpdate(rowId: AgentSQLValue, updates: [String: AgentSQLValue]) async {
        guard let table = selectedTable else { return }
        // Stamp _changelog with `actor=user` for UI-driven writes
        // (spec §6). `LocalAgentBridge.currentActor()` falls back to
        // `agent` when the task-local is `nil`, which would mislabel
        // every inline edit.
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
            browser.refresh()
        } catch {
            actionError = error.localizedDescription
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
            browser.refresh()
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Soft-delete every checked row in ONE serialized transaction
    /// (`softDeleteMany`), stamped `actor=user` so the audit trail shows
    /// the edit came from the UI. Clears the selection on success.
    @MainActor
    private func bulkSoftDelete() async {
        guard let table = selectedTable else { return }
        guard let idIdx = browser.idColumnIndex else { return }
        let targets: [AgentSQLValue] = browser.rows.compactMap { row in
            guard idIdx < row.count else { return nil }
            let value = row[idIdx]
            return selectedRowKeys.contains(agentSQLDisplayString(value)) ? value : nil
        }
        guard !targets.isEmpty else {
            selectedRowKeys.removeAll()
            return
        }
        do {
            _ = try ChatExecutionContext.$currentRunActor.withValue("user") {
                try LocalAgentBridge.shared.softDeleteMany(
                    agentId: agentId,
                    table: table,
                    ids: targets
                )
            }
            selectedRowKeys.removeAll()
            browser.refresh()
        } catch {
            actionError = error.localizedDescription
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
            browser.refresh()
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: - Host import (actor=user)

    /// Open a file picker for the supported import formats. Runs on the
    /// MainActor (NSOpenPanel is AppKit-only) and hands the chosen URL
    /// to `importFile`.
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

    /// Accept a file dragged onto the section. Loads the first droppable
    /// URL and routes it through the same `importFile` path as the button.
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

    /// Parse `url` off the main thread, then bulk-load it through the
    /// shared `AgentImportRunner` with the write stamped `actor=user`.
    /// Imports into the selected table, or a new table named after the
    /// file when none is selected.
    @MainActor
    private func importFile(url: URL) async {
        guard !isImporting else { return }
        actionError = nil
        importSummary = nil
        isImporting = true
        defer { isImporting = false }

        let table = (selectedTableIsSystem ? nil : selectedTable) ?? suggestedTableName(from: url)
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

            await loadTables(applyFocus: false)
            selectedTable = outcome.table
            browser.refresh()

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
            actionError =
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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

    // MARK: - CSV Export (streams the FULL filtered result)

    /// Export every row matching the current table + filter via the same
    /// streaming path `db_export` uses — the old grid export silently
    /// wrote only the rows loaded in memory.
    private func exportCSV() {
        guard let table = selectedTable else { return }
        let filter = selectedTableIsSystem ? DataFilterMode.all : filterMode
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(table).csv"
        Task { @MainActor in
            guard await panel.beginModal() == .OK, let url = panel.url else { return }
            isExporting = true
            actionError = nil
            let agentId = agentId
            let hasDeletedColumn = browser.deletedColumnIndex != nil
            let sql: String = {
                var conditions: [String] = []
                if hasDeletedColumn {
                    switch filter {
                    case .live: conditions.append("_deleted_at IS NULL")
                    case .deleted: conditions.append("_deleted_at IS NOT NULL")
                    case .all: break
                    }
                }
                let whereSQL = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
                return "SELECT * FROM \"\(table)\" \(whereSQL)"
            }()
            let outcome: Result<DatabaseExport.Result, Error> = await Task.detached(
                priority: .userInitiated
            ) {
                Result {
                    try LocalAgentBridge.shared.exportQueryToFile(
                        agentId: agentId,
                        sql: sql,
                        params: [],
                        url: url,
                        format: .csv,
                        maxBytes: 1_073_741_824
                    )
                }
            }.value
            isExporting = false
            switch outcome {
            case .success(let result):
                importSummary =
                    "Exported \(result.rowsExported) "
                    + (result.rowsExported == 1 ? "row" : "rows")
                    + " to \(url.lastPathComponent)"
                    + (result.truncated ? " (stopped at the 1 GB export limit)" : "")
            case .failure(let error):
                actionError = "Export failed: \(error.localizedDescription)"
            }
        }
    }
}
