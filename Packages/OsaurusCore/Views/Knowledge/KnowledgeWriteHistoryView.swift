//
//  KnowledgeWriteHistoryView.swift
//  OsaurusCore — Knowledge
//
//  "Recent agent changes" in the Knowledge tab: what agents wrote to your
//  collections, and the button that puts it back.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent agent changes", bundle: .module)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text(
                "Documents agents have written to your collections. You approved each of these when it ran; if something looks wrong, put it back here.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(runs) { run in
                runRow(run)
            }
        }
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

                // Expandable regardless of size. A single-document run still
                // has a path and an operation worth seeing before deciding.
                Button {
                    toggle(run.id)
                } label: {
                    Image(systemName: expanded.contains(run.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.secondaryText)

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
