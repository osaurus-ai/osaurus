//
//  DatabaseSavedViewsView.swift
//  osaurus
//
//  Saved-view manager (spec §5.7), now a section of the Database
//  workspace. Lists every view, lets the user pin one for the Overview
//  dashboard, drop one, or preview the rows it produces. Edits to the
//  view body itself happen inside chat — the agent owns SQL authoring
//  through `db_define_view`.
//
//  The preview grid reuses the same virtualized `NSTableView` renderer
//  as the row browser, so a view that returns thousands of rows no
//  longer builds an eager SwiftUI grid.
//

import SwiftUI

struct DatabaseSavedViewsView: View {
    @Environment(\.theme) private var theme

    let agentId: UUID
    /// Saved-view name to pre-select on first load (notification
    /// deep-link from `NotifyTool` / `viewRef`, spec §3.3). Honoured
    /// once — subsequent reloads honour the user's explicit selection.
    let initialFocusedViewName: String?

    @State private var views: [AgentSavedView] = []
    @State private var selection: AgentSavedView? = nil
    @State private var previewRows: AgentQueryResult? = nil
    @State private var isLoading = true
    @State private var isRunning = false
    @State private var loadError: String? = nil
    @State private var hasAppliedInitialFocus = false
    @State private var previewSelection: Set<String> = []

    init(agentId: UUID, initialFocusedViewName: String? = nil) {
        self.agentId = agentId
        self.initialFocusedViewName = initialFocusedViewName
    }

    var body: some View {
        // Minimums are deliberately conservative: the workspace body is
        // `maxWidth: .infinity` inside a Settings detail pane (~750pt at
        // standard width) and HSplitView refuses to compress past the
        // sum of its children's minWidths.
        HSplitView {
            sidebar.frame(minWidth: 180, idealWidth: 230, maxWidth: 340)
            detail
                .frame(minWidth: 280, maxWidth: .infinity)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .task { await reload() }
        .onChange(of: agentId) { _, _ in Task { await reload() } }
        .onChange(of: selection) { _, _ in Task { await runSelected() } }
        .onChange(of: initialFocusedViewName) { _, newValue in
            guard let newValue,
                let focused = views.first(where: { $0.name == newValue })
            else { return }
            selection = focused
        }
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
            .padding(.horizontal, 14).padding(.vertical, 9)
            Divider().foregroundColor(theme.primaryBorder)
            if isLoading {
                ProgressView().padding(24)
                Spacer(minLength: 0)
            } else if views.isEmpty {
                Text(
                    "No saved views yet. Ask the agent in chat to create one — it uses the `db_define_view` tool.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
                .padding(16)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(views, id: \.name) { view in
                            sidebarRow(view)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.secondaryBackground.opacity(0.25))
    }

    @ViewBuilder
    private func sidebarRow(_ view: AgentSavedView) -> some View {
        let isSelected = selection?.name == view.name
        Button {
            selection = view
        } label: {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: view.pinned ? "pin.fill" : "eye")
                    .font(.system(size: 11))
                    .foregroundColor(
                        view.pinned ? .orange : (isSelected ? theme.accentColor : theme.secondaryText)
                    )
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(view.name)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(view.renderHint)
                        .font(.system(size: 9))
                        .foregroundColor(theme.tertiaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
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
                        previewGrid(preview)
                        if preview.truncated {
                            Text("Preview shows the first \(preview.rows.count) rows.", bundle: .module)
                                .font(.system(size: 10))
                                .foregroundColor(theme.tertiaryText)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                        }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(view.name)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button {
                    Task { await togglePinned(view) }
                } label: {
                    Label(
                        view.pinned ? "Unpin" : "Pin to Overview",
                        systemImage: view.pinned ? "pin.slash" : "pin"
                    )
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .localizedHelp("Pinned views appear as cards on the Database Overview.")
                Button(role: .destructive) {
                    Task { await drop(view) }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .fixedSize()
                .localizedHelp("Drop this saved view. The underlying tables are not affected.")
            }
            if let desc = view.description, !desc.isEmpty {
                Text(desc).font(.system(size: 11)).foregroundColor(theme.secondaryText)
            }
            Text(view.sql)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
                .lineLimit(4)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.tertiaryBackground.opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(theme.primaryBorder.opacity(0.5), lineWidth: 1)
                )
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.secondaryBackground.opacity(0.4))
    }

    @ViewBuilder
    private func previewGrid(_ result: AgentQueryResult) -> some View {
        AgentDataGridRepresentable(
            columns: result.columns.map {
                DataGridColumn(title: $0, width: DataGridColumn.preferredWidth(forColumnNamed: $0))
            },
            rows: result.rows.enumerated().map { index, row in
                DataGridRowData(
                    key: "preview-\(index)",
                    cells: row.map(agentSQLDisplayString),
                    isDeleted: false,
                    selectable: false
                )
            },
            showsSelectionColumn: false,
            showsStatusColumn: false,
            showsOpenColumn: false,
            selectedRowKeys: $previewSelection,
            theme: theme
        )
    }

    @MainActor
    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            views = try LocalAgentBridge.shared.listViews(agentId: agentId)
            // Honour the notification-supplied focus exactly once, then
            // fall back to the normal "preserve previous selection, else
            // first row" behavior.
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
        guard let view = selection else {
            previewRows = nil
            return
        }
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
