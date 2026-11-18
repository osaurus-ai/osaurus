//
//  WorkflowStoredDataSection.swift
//  osaurus
//
//  The tables a workflow keeps between runs through its `state` steps,
//  with their rows and a way to clear them. Shown in a workflow's detail
//  sheet when the workflow has a state step or has stored something.
//

import SwiftUI

struct WorkflowStoredDataSection: View {
    let workflowID: UUID
    let definition: WorkflowDefinition

    @ObservedObject private var store = WorkflowStateStore.shared
    @State private var expanded: Set<String> = []

    @Environment(\.theme) private var theme

    private var usesState: Bool {
        definition.nodes.contains { node in
            if case .state = node.kind { return true }
            if case .map(let spec) = node.kind, case .state = spec.body(parentID: node.id).kind { return true }
            return false
        }
    }

    var body: some View {
        // Reading `revision` keeps the section current as steps write.
        let tables = store.revision >= 0 ? store.tables(workflow: workflowID) : []
        if usesState || !tables.isEmpty {
            section(tables)
        }
    }

    private func section(_ tables: [WorkflowStateTable]) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            HStack {
                Text("Stored Data", bundle: .module)
                    .textStyle(.body, weight: 600)
                    .foregroundColor(theme.text.primary)
                Spacer()
                if !tables.isEmpty {
                    Button {
                        WorkflowErrorText.saving(L("Couldn’t clear the stored data")) {
                            for table in tables { _ = try store.clear(workflow: workflowID, table: table.name) }
                        }
                    } label: {
                        Text("Clear All", bundle: .module)
                    }
                    .assignedSettingsButtonStyle(.secondary)
                }
            }
            Text(
                "What this workflow remembers between runs: counters, items it has already handled, cached lookups. Kept on this Mac; never exported.",
                bundle: .module
            )
            .textStyle(.caption)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)

            if tables.isEmpty {
                Text("Nothing stored yet.", bundle: .module)
                    .textStyle(.caption)
                    .foregroundColor(theme.text.secondary)
                    .padding(.vertical, theme.space.s6)
            } else {
                ForEach(tables) { table in
                    tableRow(table)
                }
            }
        }
        .settingsLandingAnchor("workflows.storedData")
    }

    @ViewBuilder
    private func tableRow(_ table: WorkflowStateTable) -> some View {
        let isOpen = expanded.contains(table.name)
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(alignment: .firstTextBaseline, spacing: theme.space.s10) {
                Button {
                    if isOpen { expanded.remove(table.name) } else { expanded.insert(table.name) }
                } label: {
                    HStack(spacing: theme.space.s6) {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .glyphSize(.tiny, weight: .bold)
                            .foregroundColor(theme.text.tertiary)
                        Text(verbatim: table.name)
                            .textStyle(.code)
                            .foregroundColor(theme.text.primary)
                        Text(table.count == 1 ? L("1 row") : L("\(table.count) rows"))
                            .textStyle(.caption)
                            .foregroundColor(theme.text.secondary)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                if let updated = table.updatedAt {
                    Text(updated, style: .relative)
                        .textStyle(.caption)
                        .foregroundColor(theme.text.tertiary)
                }
                Button {
                    WorkflowErrorText.saving(L("Couldn’t clear \(table.name)")) {
                        _ = try store.clear(workflow: workflowID, table: table.name)
                    }
                } label: {
                    Text("Clear", bundle: .module)
                }
                .assignedSettingsButtonStyle(.secondary)
            }
            if isOpen {
                let loaded = Result { try store.list(workflow: workflowID, table: table.name, limit: 50) }
                let rows = (try? loaded.get()) ?? []
                VStack(alignment: .leading, spacing: theme.space.s4) {
                    if case .failure(let error) = loaded {
                        Text(verbatim: L("Couldn’t read \(table.name): \(WorkflowErrorText.text(error))"))
                            .textStyle(.caption)
                            .foregroundColor(theme.status.error.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(rows) { row in
                        HStack(alignment: .top, spacing: theme.space.s8) {
                            Text(verbatim: row.key)
                                .font(SettingsFont.monoSmall)
                                .foregroundColor(theme.text.primary)
                                .frame(minWidth: 80, alignment: .leading)
                            Text(verbatim: WorkflowSummary.preview(row.value))
                                .font(SettingsFont.monoSmall)
                                .foregroundColor(theme.text.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                            Spacer()
                            SettingsIconButton("xmark", help: "Forget this row", size: .compact) {
                                WorkflowErrorText.saving(L("Couldn’t forget the row")) {
                                    _ = try store.delete(workflow: workflowID, table: table.name, key: row.key)
                                }
                            }
                        }
                    }
                    if table.count > rows.count {
                        Text(L("Showing the \(rows.count) most recent of \(table.count)."))
                            .textStyle(.caption)
                            .foregroundColor(theme.text.tertiary)
                    }
                }
                .padding(.leading, theme.space.s16)
            }
        }
        .padding(theme.space.s8)
        .settingsChrome(.inset)
    }
}
