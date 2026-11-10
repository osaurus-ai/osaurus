//
//  WorkflowDialogLayoutTests.swift
//  osaurusTests
//
//  A workflow form prefilled with a long draft (an approval step showing a
//  drafted post) lays out and takes edits without stalling the main thread.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct WorkflowDialogLayoutTests {
    private static func post(_ chars: Int) -> String {
        let paragraph = """
            ## GLM-5.3-Flash-JANGHT2.4

            A new **OsaurusAI** quant is up: [OsaurusAI/GLM-5.3-Flash-JANGHT2.4](https://huggingface.co/OsaurusAI/GLM-5.3-Flash-JANGHT2.4).
            - Size: 14.2 GB, 2.4 bits per weight, `JANGHT` mixed precision
            - Context: 128k tokens; tool calls and reasoning supported

            """
        var text = ""
        while text.count < chars { text += paragraph }
        return String(text.prefix(chars))
    }

    @Test func aLongDraft_laysOutAndEditsWithoutStalling() async throws {
        let body = Self.post(10_000)
        let dialog = PendingDialog(
            id: UUID(), runID: UUID(), workflowID: UUID(), workflowName: "Cross-post", nodeID: "approve",
            title: "Approve the post", message: "Edit the draft, then publish or skip.",
            fields: [
                DialogField(key: "title", label: "Title"),
                DialogField(key: "body", label: "Body", type: .longText),
                DialogField(key: "decision", label: "Decision", type: .choice, options: ["Publish", "Skip"]),
            ],
            prefill: ["title": .string("New model: GLM-5.3-Flash-JANGHT2.4"), "body": .string(body)],
            caller: WorkflowCaller(kind: .test), createdAt: Date())
        let state = WorkflowDialogPromptState(dialog: dialog)
        let host = NSHostingView(
            rootView: WorkflowDialogPromptOverlay(state: state).environment(\.theme, CustomizableTheme.dark()))
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 620, height: 700), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        let start = ContinuousClock.now
        host.layoutSubtreeIfNeeded()
        for edit in 0 ..< 10 {
            state.answer.values["body"] = .string(body + String(repeating: "x", count: edit))
            host.layoutSubtreeIfNeeded()
        }
        // A vertical TextField took ~18 s to lay this out and ~10 s per edit.
        // Shared CI runners take over 2 s for the healthy path.
        #expect(ContinuousClock.now - start < .seconds(8))
    }
}
