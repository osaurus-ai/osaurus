//
//  WorkflowNodeEditorLayoutTests.swift
//  osaurusTests
//
//  The Edit Step sheet opened on a step the Architect filled with a long
//  message lays out, and follows the Architect's next patch, without
//  stalling the main thread.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct WorkflowNodeEditorLayoutTests {
    private static func editor(_ text: String) -> some View {
        let node = WorkflowNode(id: "post", name: "Post", kind: .reply(ReplySpec(text: text)))
        return WorkflowNodeEditor(draftID: UUID(), node: node, onClose: {})
            .environment(\.theme, CustomizableTheme.dark())
    }

    @Test func aLongReply_laysOutAndFollowsPatchesWithoutStalling() {
        let paragraph = "Thanks for reaching out about {{input.topic}}. Here is what we found, step by step.\n"
        let text = String(String(repeating: paragraph, count: 10_000 / paragraph.count + 1).prefix(10_000))
        let host = NSHostingView(rootView: AnyView(Self.editor(text)))
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 620, height: 760), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        let start = ContinuousClock.now
        host.layoutSubtreeIfNeeded()
        for patch in 0 ..< 5 {
            host.rootView = AnyView(Self.editor(text + String(repeating: "x", count: patch + 1)))
            host.layoutSubtreeIfNeeded()
        }
        // A vertical TextField takes many seconds per layout at this length.
        #expect(ContinuousClock.now - start < .seconds(8))
    }
}
