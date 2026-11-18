//
//  WorkflowRunTabView.swift
//  osaurus
//
//  A workflow in a chat tab, from layouts saved before workflows moved to
//  the Workflows window: the same run page, with nothing to go back to.
//

import AppKit
import SwiftUI

struct WorkflowRunTabView: View {
    @ObservedObject var windowState: ChatWindowState
    let tabId: UUID
    let workflowID: UUID
    let runID: UUID?

    var body: some View {
        WorkflowRunPage(
            windowState: windowState, workflowID: workflowID, runID: runID, agentId: windowState.agentId,
            onShowRun: { windowState.setWorkflowTabRun(tabId: tabId, runID: $0) })
    }

    static func statusText(_ status: WorkflowRunStatus) -> String {
        switch status {
        case .running: return L("Running…")
        case .awaitingUser: return L("Waiting for your answer")
        case .completed: return L("Done")
        case .failed: return L("It didn't finish")
        case .cancelled: return L("Stopped")
        case .needsSetup: return L("Needs setup")
        }
    }

    /// The same states for a test of a draft, in the Architect's words.
    static func testStatusText(_ status: WorkflowRunStatus) -> String {
        switch status {
        case .running: return L("Testing…")
        case .awaitingUser: return L("Waiting for your answer")
        case .completed: return L("Test passed")
        case .failed: return L("Test failed")
        case .cancelled: return L("Test stopped")
        case .needsSetup: return L("Needs setup")
        }
    }
}

/// A run's result laid out by its output schema: each field titled, text
/// rendered as Markdown, each with its own Copy.
struct WorkflowResultCard: View {
    let output: JSONValue
    let schema: JSONValue
    /// Off where a header above already says "Result".
    var showsTitle = true
    /// The run's files, shown under the fields.
    var files: [WorkflowArtifact] = []

    @Environment(\.theme) private var theme

    /// Every field as "Label\nvalue", for Copy All; raw JSON when the
    /// output has no schema layout.
    static func plainText(_ output: JSONValue, schema: JSONValue) -> String {
        guard let fields = WorkflowOutputLayout.fields(output, schema: schema), !fields.isEmpty else {
            return output.prettyJSONString
        }
        return fields.map { "\($0.label)\n\($0.text)" }.joined(separator: "\n\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s14) {
            if showsTitle {
                Text("Result", bundle: .module)
                    .textStyle(.body, weight: 600)
                    .foregroundColor(theme.text.primary)
            }
            if let fields = WorkflowOutputLayout.fields(output, schema: schema), !fields.isEmpty {
                ForEach(fields) { field in
                    VStack(alignment: .leading, spacing: theme.space.s4) {
                        HStack {
                            Text(verbatim: field.label)
                                .textStyle(.caption, weight: 600)
                                .foregroundColor(theme.text.secondary)
                            Spacer()
                            SettingsIconButton("doc.on.doc", help: "Copy", size: .compact) { copy(field.text) }
                        }
                        if field.isStructured {
                            Text(verbatim: field.text)
                                .font(SettingsFont.monoSmall)
                                .foregroundColor(theme.text.primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            MarkdownDocument(text: field.text)
                        }
                    }
                }
            } else {
                Text(verbatim: output.prettyJSONString)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !files.isEmpty {
                WorkflowRunFiles(files: files)
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The Result header's copy of every field at once. Absent for a single
/// field, whose own Copy already does it; "Copy" for raw JSON, which has
/// no field copies.
struct WorkflowResultCopyAllButton: View {
    let output: JSONValue
    let schema: JSONValue

    @State private var copied = false

    var body: some View {
        let count = WorkflowOutputLayout.fields(output, schema: schema)?.count ?? 0
        if count != 1 {
            SettingsButton(
                .secondary, copied ? "Copied" : count == 0 ? "Copy" : "Copy All",
                icon: copied ? "checkmark" : "doc.on.doc", size: .extraSmall, action: copy)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(WorkflowResultCard.plainText(output, schema: schema), forType: .string)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { copied = false }
        }
    }
}
