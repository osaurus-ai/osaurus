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
    case .blob(let v): return "<\(v.count) bytes>"
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
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("\(activity[agentId]) write\(activity[agentId] == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(.horizontal, 6)
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
            Label(localized: "Approaching storage limit", systemImage: "exclamationmark.triangle.fill")
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
                .localizedHelp("This agent's database is approaching its storage limit.")
        }
    }
}

// MARK: - Empty State Card

/// Centered onboarding card used by the workspace's empty states.
/// Wraps an SF Symbol, a title, optional sub-copy, and optional CTA
/// button into one consistent block so each empty state has the same
/// shape, weight, and rhythm.
struct DatabaseEmptyState: View {
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
    @Environment(\.theme) private var theme

    let row: EditingDatabaseRow
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
                subtitle: LocalizedStringKey("ID \(agentSQLDisplayString(row.rowId))"),
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
                                if newValue {
                                    nullValues.insert(column.name)
                                } else {
                                    nullValues.remove(column.name)
                                }
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
