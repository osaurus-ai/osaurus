//
//  KnowledgeWriteHistoryView.swift
//  OsaurusCore — Knowledge
//
//  The History tab under Knowledge: what agents wrote to your collections,
//  and the button that puts it back.
//
//  This is the half of the direct-write design that makes call-time approval
//  defensible. Nobody reliably catches fabricated reference material by
//  skimming a diff at 2am — the documents in osaurus#2439 described a Windows
//  PowerShell framework as a tool for deploying Apple software, in confident
//  prose, with a real source URL in the frontmatter. What saves you there is
//  noticing later that search returns nonsense, and being able to undo it.
//
//  Grouped by RUN rather than by document, because the thing that goes wrong
//  is an import, not a file: a 62-document batch is one decision to make and
//  should be one decision to take back.
//

import SwiftUI

/// One agent run's writes, newest first.
struct KnowledgeWriteRun: Identifiable {
    var id: String { runId }
    var runId: String
    var collectionName: String
    var records: [KnowledgeWriteRecord]

    /// Filtering keys off the id, not the name: a renamed collection must not
    /// split its own history into two buckets.
    var collectionId: String { records.first?.collectionId ?? "" }

    var createdAt: String { records.last?.createdAt ?? "" }
    var rationale: String { records.first?.rationale ?? "" }
    var isFullyReverted: Bool { records.allSatisfy(\.isReverted) }
    var liveCount: Int { records.filter { !$0.isReverted }.count }

    /// Reads as a sentence, not a stat block. No em dashes, per the project's
    /// UI string convention.
    var summary: String {
        let created = records.filter { $0.operation == .create }.count
        let replaced = records.filter { $0.operation == .replace }.count
        let deleted = records.filter { $0.operation == .delete }.count
        var parts: [String] = []
        if created > 0 { parts.append("\(created) added") }
        if replaced > 0 { parts.append("\(replaced) replaced") }
        if deleted > 0 { parts.append("\(deleted) deleted") }
        return parts.joined(separator: ", ")
    }
}

extension KnowledgeWriteRun {
    /// Group flat records into runs, preserving newest-first order.
    ///
    /// Records with an empty `runId` each become their own run: they came from
    /// a surface with no run identity, and lumping them together would offer a
    /// "revert all" across unrelated changes.
    static func group(
        _ records: [KnowledgeWriteRecord],
        collectionNames: [String: String]
    ) -> [KnowledgeWriteRun] {
        var order: [String] = []
        var byRun: [String: [KnowledgeWriteRecord]] = [:]
        for record in records {
            let key = record.runId.isEmpty ? "single-\(record.id)" : record.runId
            if byRun[key] == nil { order.append(key) }
            byRun[key, default: []].append(record)
        }
        return order.map { key in
            let group = byRun[key] ?? []
            return KnowledgeWriteRun(
                runId: key,
                collectionName: group.first.map { collectionNames[$0.collectionId] ?? "" } ?? "",
                records: group
            )
        }
    }
}

struct KnowledgeWriteHistoryView: View {
    let runs: [KnowledgeWriteRun]
    /// Revert one whole run. The affordance that matters after a bad import.
    let onRevertRun: (KnowledgeWriteRun) -> Void
    /// Revert a single document.
    let onRevertRecord: (KnowledgeWriteRecord) -> Void

    @Environment(\.theme) private var theme
    @State private var expanded: Set<String> = []
    /// Empty means every collection. Held as an id so a rename cannot orphan
    /// the current selection.
    @State private var collectionFilter: String = ""
    /// Reverted runs are resolved history. They stay available, because
    /// "did I already put that back?" is a real question, but they do not
    /// deserve to crowd out the changes still standing.
    @State private var showsReverted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            filterBar

            if visibleRuns.isEmpty {
                emptyState
            } else {
                ForEach(visibleRuns) { run in
                    runRow(run)
                }
            }
        }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 8)

            collectionMenu

            Toggle(isOn: $showsReverted) {
                Text("Show reverted", bundle: .module)
                    .font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// The stock macOS pop-up button.
    ///
    /// `.fixedSize()` rather than a fixed width: a `.frame(width:)` is wider
    /// than the button's intrinsic size, and the control centers inside it,
    /// which is what pushed it out of alignment with the rows below.
    private var collectionMenu: some View {
        Picker(selection: $collectionFilter) {
            Text("All Collections", bundle: .module).tag("")
            ForEach(collectionOptions, id: \.id) { option in
                Text(option.name).tag(option.id)
            }
        } label: {
            Text("Collection", bundle: .module)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }

    private var emptyState: some View {
        // Reachable only by filtering everything out: the tab itself is
        // hidden until an agent has written something.
        Text("No changes match these filters.", bundle: .module)
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
    }

    // MARK: - Filtering

    /// Collections that appear in the log, named. Built from the runs rather
    /// than from the collection list so a collection the user has since
    /// removed still filters its own leftover history.
    private var collectionOptions: [(id: String, name: String)] {
        var seen: Set<String> = []
        var options: [(id: String, name: String)] = []
        for run in runs where !run.collectionId.isEmpty {
            guard seen.insert(run.collectionId).inserted else { continue }
            options.append(
                (
                    id: run.collectionId,
                    name: run.collectionName.isEmpty ? run.collectionId : run.collectionName
                )
            )
        }
        return options.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var visibleRuns: [KnowledgeWriteRun] {
        var filtered = runs
        if !collectionFilter.isEmpty {
            filtered = filtered.filter { $0.collectionId == collectionFilter }
        }
        if !showsReverted {
            filtered = filtered.filter { !$0.isFullyReverted }
        }
        return filtered
    }

    private func runRow(_ run: KnowledgeWriteRun) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: run.isFullyReverted ? "arrow.uturn.backward.circle" : "doc.badge.gearshape")
                    .font(.system(size: 13))
                    .foregroundColor(run.isFullyReverted ? theme.tertiaryText : theme.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(headline(for: run))
                        .font(
                            run.records.count == 1
                                ? theme.monoFont(size: 11.5) : .system(size: 12, weight: .medium)
                        )
                        .foregroundColor(
                            run.isFullyReverted ? theme.tertiaryText : theme.primaryText
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)

                    // Collection, operation and time: what actually tells two
                    // otherwise identical rows apart.
                    Text(subtitle(for: run))
                        .font(.system(size: 10.5))
                        .foregroundColor(theme.tertiaryText)

                    if !run.rationale.isEmpty {
                        Text(run.rationale)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                // Only multi-document runs expand: a single-document row
                // already shows its path, operation and time, so a chevron
                // there opens a list of one and just crowds the Revert button.
                if run.records.count > 1 {
                    Button {
                        toggle(run.id)
                    } label: {
                        Image(systemName: expanded.contains(run.id) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.secondaryText)
                }

                if !run.isFullyReverted {
                    Button {
                        onRevertRun(run)
                    } label: {
                        Text(
                            run.records.count > 1 ? "Revert all" : "Revert",
                            bundle: .module
                        )
                        .font(.system(size: 11, weight: .medium))
                    }
                }
            }

            if expanded.contains(run.id) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(run.records) { record in
                        recordRow(record)
                    }
                }
                .padding(.leading, 24)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.secondaryBackground))
    }

    private func recordRow(_ record: KnowledgeWriteRecord) -> some View {
        HStack(spacing: 6) {
            Text(label(for: record.operation))
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(color(for: record.operation))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(color(for: record.operation).opacity(0.15)))

            Text(record.relPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(record.isReverted ? theme.tertiaryText : theme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 6)

            if record.isReverted {
                Text("Reverted", bundle: .module)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            } else {
                Button {
                    onRevertRecord(record)
                } label: {
                    Text("Revert", bundle: .module)
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.accentColor)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    /// Name the DOCUMENT when a run touched exactly one.
    ///
    /// "1 document in kb-ops: 1 replaced" is what five consecutive rows looked
    /// like in testing, with no way to tell them apart or decide which to put
    /// back. The path is the thing a reader is actually looking for, and it is
    /// already on the record.
    private func headline(for run: KnowledgeWriteRun) -> String {
        if run.records.count == 1, let record = run.records.first {
            return record.relPath
        }
        let scope = run.collectionName.isEmpty ? "" : " in \(run.collectionName)"
        return "\(run.records.count) documents\(scope): \(run.summary)"
    }

    /// Collection, what happened, and when — the three facts that separate one
    /// row from the next.
    private func subtitle(for run: KnowledgeWriteRun) -> String {
        var parts: [String] = []
        if !run.collectionName.isEmpty { parts.append(run.collectionName) }
        if run.records.count == 1, let record = run.records.first {
            parts.append(pastTense(record.operation))
        }
        if run.isFullyReverted { parts.append("reverted") }
        if let when = Self.relativeTime(run.createdAt) { parts.append(when) }
        return parts.joined(separator: " · ")
    }

    private func pastTense(_ operation: KnowledgeWriteOperation) -> String {
        switch operation {
        case .create: return "added"
        case .replace: return "replaced"
        case .delete: return "deleted"
        }
    }

    /// "3 min ago" from the stored ISO8601 stamp. Nil when it cannot be
    /// parsed, so a row degrades to no timestamp rather than a wrong one.
    static func relativeTime(_ iso8601: String) -> String? {
        guard let date = ISO8601DateFormatter().date(from: iso8601) else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func label(for operation: KnowledgeWriteOperation) -> String {
        switch operation {
        case .create: return "NEW"
        case .replace: return "REPLACE"
        case .delete: return "DELETE"
        }
    }

    private func color(for operation: KnowledgeWriteOperation) -> Color {
        switch operation {
        case .create: return theme.successColor
        case .replace: return theme.accentColor
        case .delete: return theme.errorColor
        }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }
}
