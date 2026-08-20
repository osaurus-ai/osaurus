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
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 240)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.codeBlockBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(theme.primaryBorder.opacity(0.6), lineWidth: 1)
                )
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(preview.summary)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            if !preview.rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(preview.rationale)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
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
                        .font(theme.monoFont(size: 11))
                        .foregroundColor(
                            entry.isValid ? theme.primaryText : theme.secondaryText
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 6)

                    if entry.isValid, entry.operation != .delete {
                        Text("+\(entry.addedLines) -\(entry.removedLines)")
                            .font(theme.monoFont(size: 10))
                            .foregroundColor(theme.secondaryText)
                    }

                    Image(systemName: isExpanded(entry) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let problem = entry.problem {
                problemRow(problem)
                    .padding(.horizontal, 10)
            }

            if isExpanded(entry) {
                detail(entry)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            }
        }
    }

    @ViewBuilder
    private func detail(_ entry: KnowledgeWritePreviewEntry) -> some View {
        let body = entry.operation == .delete ? entry.deletedContent : entry.diff
        if body.isEmpty {
            Text("Nothing to show.", bundle: .module)
                .font(.system(size: 10))
                .foregroundColor(theme.secondaryText)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(body)
                        .font(theme.monoFont(size: 10.5))
                        .foregroundColor(theme.primaryText.opacity(0.9))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if entry.diffTruncated {
                    // Say it plainly: implying the reader saw the whole
                    // document is exactly the failure this view exists to fix.
                    Text("Shortened for display. Not the whole document.", bundle: .module)
                        .font(.system(size: 10))
                        .foregroundColor(theme.warningColor)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.tertiaryBackground.opacity(0.5))
            )
        }
    }

    private func operationBadge(_ operation: KnowledgeWriteOperation) -> some View {
        Text(label(for: operation))
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(color(for: operation))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(color(for: operation).opacity(0.15))
            )
    }

    private func problemRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(theme.warningColor)
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
        case .create: return theme.successColor
        case .replace: return theme.accentColor
        // Delete reads as the destructive one at a glance, because it is.
        case .delete: return theme.errorColor
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
