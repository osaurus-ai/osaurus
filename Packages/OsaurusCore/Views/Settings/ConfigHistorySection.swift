//
//  ConfigHistorySection.swift
//  OsaurusCore
//
//  Settings → Agents → Configurator → Configuration History: every recorded
//  version of the declarative configuration, newest first. Select one row to
//  see what that change did, two to compare them. Row actions name a version
//  (named versions are never pruned), export it as YAML, or revert to it
//  through the same approval card the Configurator raises.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ConfigHistorySection: View {
    static let anchorId = "settings.configurator.history"
    nonisolated static let shownLimit = 100

    @Environment(\.theme) private var theme

    @State private var rows: [ConfigSnapshot] = []
    @State private var loaded = false
    /// Selected sequences, oldest selection first; at most two.
    @State private var selected: [Int] = []
    @State private var diffText: String?
    @State private var naming: ConfigSnapshot?
    @State private var nameDraft = ""
    @State private var status: String?
    @State private var reverting = false

    var body: some View {
        SettingsSection(title: "Configuration History") {
            VStack(alignment: .leading, spacing: theme.space.s10) {
                Text(
                    "Every change to agents, models, tools, automations, and the other settings the Configurator manages. Select a version to see what it changed, or two to compare them.",
                    bundle: .module
                )
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)

                if !loaded {
                    SettingsSpinner()
                } else if rows.isEmpty {
                    Text("No configuration changes recorded yet.", bundle: .module)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: theme.space.s2) {
                            ForEach(rows) { row in historyRow(row) }
                        }
                    }
                    .frame(maxHeight: 280)
                }

                if let diffText {
                    Text(diffCaption)
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.text.secondary)
                    if diffText.isEmpty {
                        Text("No differences.", bundle: .module)
                            .font(SettingsFont.rowDescription)
                            .foregroundColor(theme.text.tertiary)
                    } else {
                        ConfigDiffText(text: diffText, maxHeight: 320)
                    }
                }

                if let status {
                    Text(status)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.secondary)
                }
            }
            .settingsLandingAnchor(Self.anchorId)
        }
        .overlay { ConfigApprovalModal(scope: .management) }
        .task { await reload(noticeDrift: true) }
        .onReceive(NotificationCenter.default.publisher(for: ConfigHistoryRecorder.didChange)) { _ in
            Task { await reload(noticeDrift: false) }
        }
        .popover(item: $naming) { snapshot in namePopover(snapshot) }
    }

    // MARK: - Rows

    private func historyRow(_ row: ConfigSnapshot) -> some View {
        let isSelected = selected.contains(row.sequence)
        return HStack(alignment: .firstTextBaseline, spacing: theme.space.s10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .glyphSize(.caption)
                .foregroundColor(isSelected ? theme.action.primary.default.background : theme.text.tertiary)
            VStack(alignment: .leading, spacing: theme.space.s2) {
                HStack(spacing: theme.space.s6) {
                    Text(L("Version \(row.sequence)"))
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)
                    if let label = row.label {
                        StatusChip(label, tone: .info)
                    }
                    Text(row.takenAt.formatted(date: .abbreviated, time: .shortened))
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                }
                Text(rowDetail(row))
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            SettingsOverflowMenu(help: "More actions", size: .compact) {
                Button(L("Name…")) {
                    nameDraft = row.label ?? ""
                    naming = row
                }
                Button(L("Export…")) { export(row) }
                Button(L("Revert to This Version…")) { revert(to: row) }
                    .disabled(reverting || row.sequence == rows.first?.sequence)
            }
        }
        .padding(.vertical, theme.space.s6)
        .padding(.horizontal, theme.space.s8)
        .settingsChrome(isSelected ? .hover : nil)
        .contentShape(Rectangle())
        .onTapGesture { toggle(row.sequence) }
    }

    private func rowDetail(_ row: ConfigSnapshot) -> String {
        var parts = [row.caller.displayName]
        if row.sequence == 0 {
            parts.append(L("Configuration as first found"))
        } else if !row.sectionsChanged.isEmpty {
            parts.append(row.sectionsChanged.map(\.rawValue).joined(separator: ", "))
        }
        if let request = row.requestText { parts.append("“\(request)”") }
        return parts.joined(separator: " · ")
    }

    private var diffCaption: String {
        switch selected.count {
        case 2:
            let pair = selected.sorted()
            return L("Changes from version \(pair[0]) to version \(pair[1])")
        case 1:
            return L("What version \(selected[0]) changed")
        default:
            return ""
        }
    }

    private func namePopover(_ snapshot: ConfigSnapshot) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            SettingsFieldRow(
                label: L("Name version \(snapshot.sequence)"),
                hint: "Named versions are always kept.",
                verbatimLabel: true
            ) {
                SettingsTextField(placeholder: L("For example: Before the trip"), text: $nameDraft)
                    .frame(minWidth: 240)
                    .onSubmit { saveName(snapshot) }
            }
            HStack {
                Spacer()
                Button(L("Cancel")) { naming = nil }
                Button(L("Save")) { saveName(snapshot) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(theme.space.s12)
    }

    // MARK: - Actions

    private func toggle(_ sequence: Int) {
        if let index = selected.firstIndex(of: sequence) {
            selected.remove(at: index)
        } else {
            selected.append(sequence)
            if selected.count > 2 { selected.removeFirst() }
        }
        Task { await refreshDiff() }
    }

    @MainActor
    private func reload(noticeDrift: Bool) async {
        if noticeDrift { await ConfigApplier.noticeConfigDrift(.historyOpened) }
        let database = ConfigHistoryRecorder.database
        let list = await Task.detached { (try? database.list(limit: Self.shownLimit)) ?? [] }.value
        rows = list
        loaded = true
        selected = selected.filter { sequence in list.contains { $0.sequence == sequence } }
        await refreshDiff()
    }

    @MainActor
    private func refreshDiff() async {
        let database = ConfigHistoryRecorder.database
        let picks = selected.sorted()
        guard !picks.isEmpty else {
            diffText = nil
            return
        }
        let pair: (ConfigSnapshot?, ConfigSnapshot?) = await Task.detached {
            if picks.count == 2 {
                return ((try? database.snapshot(sequence: picks[0])), (try? database.snapshot(sequence: picks[1])))
            }
            let after = try? database.snapshot(sequence: picks[0])
            return ((try? database.snapshot(before: picks[0])), after)
        }.value
        guard let after = pair.1 else {
            diffText = nil
            return
        }
        let beforeYAML = pair.0?.yaml ?? ""
        let fromLabel = pair.0.map { "version \($0.sequence)" } ?? "nothing"
        diffText =
            ConfigDiff.compute(
                before: beforeYAML, after: after.yaml, fromLabel: fromLabel, toLabel: "version \(after.sequence)"
            ).unified
    }

    private func saveName(_ snapshot: ConfigSnapshot) {
        let draft = nameDraft
        naming = nil
        Task { @MainActor in
            let database = ConfigHistoryRecorder.database
            let outcome: Result<Void, Error> = await Task.detached {
                Result { try database.setLabel(draft, sequence: snapshot.sequence) }
            }.value
            if case .failure(let error) = outcome {
                status = error.localizedDescription
            } else {
                status = nil
            }
            await reload(noticeDrift: false)
        }
    }

    private func export(_ snapshot: ConfigSnapshot) {
        let yaml: String
        do {
            yaml = try ConfigYAML.encode(try snapshot.document())
        } catch {
            status = error.localizedDescription
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "osaurus-config-v\(snapshot.sequence).yaml"
        panel.allowedContentTypes = [UTType(filenameExtension: "yaml") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try yaml.write(to: url, atomically: true, encoding: .utf8)
            status = L("Exported version \(snapshot.sequence).")
        } catch {
            status = error.localizedDescription
        }
    }

    private func revert(to snapshot: ConfigSnapshot) {
        let document: OsaurusConfigDocument
        do {
            document = try snapshot.document()
        } catch {
            status = error.localizedDescription
            return
        }
        reverting = true
        status = nil
        let target = OsaurusConfigTool.versionLabel(snapshot)
        Task { @MainActor in
            let envelope = await OsaurusConfigTool().applyDocument(
                document, prune: false, basedOn: nil, autoNamed: nil, caller: .other(Self.revertCallerName),
                requestText: "Revert to \(target)", leadingNotes: ["Reverting to \(target)."])
            reverting = false
            status = Self.revertStatus(envelope, target: target)
            await reload(noticeDrift: false)
        }
    }

    /// Caller recorded for a revert started from this section.
    static let revertCallerName = "History revert"

    static func revertStatus(_ envelope: String, target: String) -> String {
        guard let data = envelope.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return L("Revert finished.") }
        if let result = object["result"] as? [String: Any], let status = result["status"] as? String {
            switch status {
            case "no_changes": return L("Already matches \(target). Nothing to change.")
            case "applied", "applied_downloads_running": return L("Reverted to \(target).")
            default: return L("Partly reverted to \(target). Some changes did not land.")
            }
        }
        if let message = object["message"] as? String { return message }
        return L("Revert finished.")
    }
}
