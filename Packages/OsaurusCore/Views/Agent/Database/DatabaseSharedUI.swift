//
//  DatabaseSharedUI.swift
//  osaurus
//
//  Shared building blocks for the agent Database workspace: value
//  formatting, the storage-quota / writes-in-flight badges, the empty
//  state card, and the row editor sheet. These used to live scattered
//  through the per-surface DB tabs; the workspace's sections all pull
//  from here so the copy and chrome stay consistent.
//

import AppKit
import SwiftUI

// MARK: - Value Display

/// Human-readable rendering for a SQL value in grids, editors, and CSV.
func agentSQLDisplayString(_ value: AgentSQLValue) -> String {
    switch value {
    case .null: return "NULL"
    case .integer(let v): return String(v)
    case .double(let v): return String(v)
    case .text(let v): return v
    case .blob(let v): return v.count == 1 ? "<1 byte>" : "<\(v.count) bytes>"
    case .bool(let v): return v ? "true" : "false"
    }
}

extension AgentSQLValue {
    var isNotNull: Bool {
        if case .null = self { return false }
        return true
    }
}

// MARK: - In-Flight Mutation Spinner

/// Tiny progress spinner shown in Database workspace headers while the
/// bridge has serialized writes in flight for this agent (spec §16 Q1).
/// Reads `AgentMutationActivity.shared` so the indicator stays in sync
/// with the same counter `LocalAgentBridge.serialized` increments.
struct MutationsInFlightIndicator: View {
    let agentId: UUID
    let theme: ThemeProtocol

    @ObservedObject private var activity = AgentMutationActivity.shared

    init(agentId: UUID, theme: ThemeProtocol) {
        self.agentId = agentId
        self.theme = theme
    }

    var body: some View {
        if activity[agentId] > 0 {
            HStack(spacing: theme.space.s4) {
                SettingsSpinner(size: .mini)
                Text("\(activity[agentId]) write\(activity[agentId] == 1 ? "" : "s")")
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
            }
            .padding(.horizontal, theme.space.s6)
            .localizedHelp("The agent is writing to its database right now.")
        }
    }
}

// MARK: - Storage Quota Badge

/// Small "approaching quota" pill shown in the workspace headers when
/// the agent's DB file has crossed `storageWarnPercent` of its
/// `storageBytesLimit` (spec §11.2). Observes
/// `AgentManager.storageWarningAgentIds` so it stays in sync with the
/// same set the user-facing notification fires from.
struct StorageQuotaBadge: View {
    let agentId: UUID
    let theme: ThemeProtocol

    @ObservedObject private var agentManager = AgentManager.shared

    init(agentId: UUID, theme: ThemeProtocol) {
        self.agentId = agentId
        self.theme = theme
    }

    var body: some View {
        if agentManager.storageWarningAgentIds.contains(agentId) {
            StatusChip(
                L("Approaching storage limit"),
                tone: .warning,
                icon: "exclamationmark.triangle.fill",
                help: L("This agent's database is approaching its storage limit.")
            )
        }
    }
}

// MARK: - Editing Row

struct EditingDatabaseRow: Identifiable {
    /// Stable display-form id so SwiftUI's `sheet(item:)` machinery can
    /// drive presentation. The actual PK lives in `rowId` and is the
    /// value we pass back to `LocalAgentBridge.update / softDelete /
    /// restore`.
    var id: String { agentSQLDisplayString(rowId) }
    let rowId: AgentSQLValue
    let tableName: String
    let columns: [AgentColumnInfo]
    let values: [AgentSQLValue]
    let isDeleted: Bool
}

// MARK: - Row Editor Sheet

struct DatabaseRowEditorSheet: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }

    let row: EditingDatabaseRow
    let onSave: ([String: AgentSQLValue]) -> Void
    let onSoftDelete: () -> Void
    let onRestore: () -> Void
    let onCancel: () -> Void

    @State private var draftValues: [String: String] = [:]
    @State private var nullValues: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s0) {
            SettingsSheetHeader(
                icon: "square.and.pencil",
                title: "Edit row",
                subtitle: LocalizedStringKey("ID \(agentSQLDisplayString(row.rowId))"),
                onClose: onCancel
            )
            ScrollView {
                VStack(alignment: .leading, spacing: theme.space.s12) {
                    ForEach(row.columns, id: \.name) { column in
                        editorField(for: column)
                    }
                }
                .padding(.horizontal, theme.space.s16)
                .padding(.vertical, theme.space.s16)
            }
            .frame(minHeight: 200, maxHeight: 400)
            footer
        }
        .frame(width: 520)
        .settingsSheetSurface()
        .onAppear { hydrateDraft() }
    }

    @ViewBuilder
    private func editorField(for column: AgentColumnInfo) -> some View {
        let isReadOnly = isSystemColumn(column.name)
        let isNull = nullValues.contains(column.name)
        VStack(alignment: .leading, spacing: theme.space.s6) {
            HStack(spacing: theme.space.s8) {
                SettingsFieldLabel(LocalizedStringKey(column.name))
                Text(column.type)
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.chip)
                    .foregroundColor(theme.text.tertiary)
                    .padding(.horizontal, theme.space.s6)
                    .padding(.vertical, theme.space.s2)
                    .settingsChrome(.inset)
                if isReadOnly {
                    Text("read-only", bundle: .module)
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.chip)
                        .foregroundColor(theme.text.tertiary)
                }
                Spacer()
                if !isReadOnly, column.nullable {
                    Toggle(
                        isOn: Binding(
                            get: { nullValues.contains(column.name) },
                            set: { newValue in
                                if newValue {
                                    nullValues.insert(column.name)
                                } else {
                                    nullValues.remove(column.name)
                                }
                            }
                        )
                    ) {
                        Text("NULL", bundle: .module).catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                    }
                    .settingsSwitch(showsLabel: true)
                }
            }
            SettingsTextField(
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
        VStack(spacing: theme.space.s0) {
            ThemeHairlineDivider()
            HStack(spacing: theme.space.s8) {
                if row.isDeleted {
                    Button(action: onRestore) {
                        Text("Restore", bundle: .module)
                    }
                    .assignedSettingsButtonStyle(.secondary)
                } else {
                    Button(action: onSoftDelete) {
                        Text("Delete", bundle: .module)
                    }
                    .assignedSettingsButtonStyle(.destructive)
                }
                Spacer()
                Button(action: onCancel) {
                    Text("Cancel", bundle: .module)
                }
                .assignedSettingsButtonStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                Button {
                    onSave(buildUpdates())
                } label: {
                    Text("Save", bundle: .module)
                }
                .assignedSettingsButtonStyle(.primary)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, theme.space.s24)
            .padding(.vertical, theme.space.s16)
            .background(theme.surface.subtle)
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
                draftValues[column.name] = agentSQLDisplayString(value)
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
