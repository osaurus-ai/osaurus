//
//  KnowledgeWritePreviewView.swift
//  OsaurusCore — Knowledge
//
//  Renders a pending knowledge write inside the tool-permission modal, in
//  place of the generic pretty-printed JSON block.
//
//  A reader cannot consent to a 29KB document replacement shown as a JSON
//  blob. This is the surface that makes call-time approval defensible rather
//  than a downgrade from the deferred review it replaces: each document says
//  which of create / replace / delete it is, and shows the diff.
//
//  A dumb renderer over `KnowledgeWritePreview`; every decision the reader
//  depends on (what the operation really is, whether an entry can be applied,
//  whether the text was truncated) is resolved in the model and tested there.
//

import SwiftUI

struct KnowledgeWritePreviewView: View {
    let preview: KnowledgeWritePreview

    @Environment(\.theme) private var theme
    /// Collapsed by default past this many documents: a 62-document import
    /// must not push the action buttons off-screen. The manifest stays fully
    /// scrollable either way.
    private static let autoExpandLimit = 3
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if let parseError = preview.parseError {
                problemRow(parseError)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(preview.entries) { entry in
                            entryRow(entry)
                        }
                    }
                    .padding(.vertical, theme.space.s6)
                }
                .frame(maxHeight: 240)
                .settingsChrome(.subtle)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(preview.summary)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.primary)
                .fixedSize(horizontal: false, vertical: true)

            if !preview.rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(preview.rationale)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Entries

    private func entryRow(_ entry: KnowledgeWritePreviewEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                toggle(entry.id)
            } label: {
                HStack(spacing: 6) {
                    operationBadge(entry.operation)

                    Text(entry.relPath)
                        .textStyle(.footnote, family: .code)
                        .foregroundColor(
                            entry.isValid ? theme.text.primary : theme.text.secondary
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 6)

                    if entry.isValid, entry.operation != .delete {
                        // The +/- pair describes the DISPLAYED diff. When that is
                        // capped, or a substitution summary, it does not describe
                        // the document: a large deletion reads as a small one, and
                        // a 120 occurrence edit read as `+40 -38`. Exact before/
                        // after line counts cannot mislead either way.
                        Text(
                            (entry.diffTruncated || !entry.countsDescribeDocument)
                                ? "\(entry.priorLineCount) → \(entry.newLineCount) lines"
                                : "+\(entry.addedLines) -\(entry.removedLines)"
                        )
                        .textStyle(.micro, family: .code)
                        .foregroundColor(theme.text.secondary)
                    }

                    Image(systemName: isExpanded(entry) ? "chevron.down" : "chevron.right")
                        .glyphSize(9, weight: .semibold)
                        .foregroundColor(theme.text.secondary)
                }
                .padding(.horizontal, theme.space.s8)
                .padding(.vertical, theme.space.s6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let problem = entry.problem {
                problemRow(problem)
                    .padding(.horizontal, theme.space.s8)
            }

            // Non-blocking: the write is fine, the content will just not
            // behave as the agent intended. Always shown, never hidden behind
            // the expander, because it is the kind of thing a reader would
            // want to catch before approving rather than after searching.
            ForEach(entry.warnings, id: \.self) { warning in
                problemRow(warning)
                    .padding(.horizontal, theme.space.s8)
            }

            if isExpanded(entry) {
                detail(entry)
                    .padding(.horizontal, theme.space.s8)
                    .padding(.bottom, theme.space.s4)
            }
        }
    }

    @ViewBuilder
    private func detail(_ entry: KnowledgeWritePreviewEntry) -> some View {
        let body = entry.operation == .delete ? entry.deletedContent : entry.diff
        if body.isEmpty {
            Text("Nothing to show.", bundle: .module)
                .font(SettingsFont.footnote)
                .foregroundColor(theme.text.secondary)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(body)
                        .textStyle(.micro, family: .code)
                        .foregroundColor(theme.text.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if entry.diffTruncated {
                    // Say it plainly: implying the reader saw the whole
                    // document is exactly the failure this view exists to fix.
                    Text("Shortened for display. Not the whole document.", bundle: .module)
                        .font(SettingsFont.footnote)
                        .foregroundColor(theme.status.warning.foreground)
                }
            }
            .padding(theme.space.s8)
            .settingsChrome(.inset)
        }
    }

    private func operationBadge(_ operation: KnowledgeWriteOperation) -> some View {
        StatusChip(label(for: operation), tint: color(for: operation))
    }

    private func problemRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .glyphSize(9)
            Text(text)
                .font(SettingsFont.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(theme.status.warning.foreground)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    /// Localized in the caller's bundle via `Text(_:bundle:)` at the call
    /// sites above; these three are short enough to read as labels.
    private func label(for operation: KnowledgeWriteOperation) -> String {
        switch operation {
        case .create: return "NEW"
        case .replace: return "REPLACE"
        case .delete: return "DELETE"
        }
    }

    private func color(for operation: KnowledgeWriteOperation) -> Color {
        switch operation {
        case .create: return theme.status.success.foreground
        case .replace: return theme.action.primary.default.background
        // Delete reads as the destructive one at a glance, because it is.
        case .delete: return theme.status.error.foreground
        }
    }

    private func isExpanded(_ entry: KnowledgeWritePreviewEntry) -> Bool {
        if expanded.contains(entry.id) { return true }
        // A single-document call is the common case; make the reader click for
        // nothing there, and they stop reading the ones that matter.
        return expanded.isEmpty && preview.entries.count <= Self.autoExpandLimit
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            if expanded.isEmpty, preview.entries.count <= Self.autoExpandLimit {
                // Materialize the implicit auto-expansion before collapsing
                // one, so the first click collapses only what was clicked.
                expanded = Set(preview.entries.map(\.id))
                expanded.remove(id)
                return
            }
            expanded.insert(id)
        }
    }
}
