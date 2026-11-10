//
//  AttentionSurfaceRenderTests.swift
//  osaurusTests
//
//  Renders the attention surfaces offscreen (the Approvals page with
//  waiting requests, the owner approval card, a conversation event
//  row and the notification routing rows) and checks each draws content.
//  Set `ATTENTION_RENDER_DIR=/some/dir` to also write each render as a PNG
//  for review.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct AttentionSurfaceRenderTests {
    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private static func render<V: View>(_ name: String, width: CGFloat, height: CGFloat, _ view: V) async throws
        -> NSBitmapImageRep
    {
        let theme: ThemeProtocol = CustomizableTheme.dark()
        let root = view
            .frame(width: width, height: height, alignment: .topLeading)
            .background(theme.surface.canvas)
            .environment(\.theme, theme)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = KeyWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["ATTENTION_RENDER_DIR"] {
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(Int(width)).png"))
        }
        return rep
    }

    /// Distinct colors on a coarse grid: a blank or single-fill render has
    /// one or two.
    private static func distinctColors(_ rep: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let r = UInt32(c.redComponent * 255), g = UInt32(c.greenComponent * 255)
                let b = UInt32(c.blueComponent * 255)
                seen.insert(r << 16 | g << 8 | b)
            }
        }
        return seen.count
    }

    private static let alice = Participant(
        kind: .teammate, handle: "alice", wallet: "0x9c3e0000000000000000000000000000000011aa")
    private static let agent = Participant.agent(
        name: "Research Agent", address: "0xab1200000000000000000000000000000000f291")

    private static func seededCenter() -> AttentionCenter {
        let center = AttentionCenter()
        _ = center.raise(
            AttentionItem(
                kind: .ownerApproval, requester: Self.alice, agent: Self.agent, sessionId: UUID(),
                title: "@alice wants Research Agent to use web_fetch",
                body: "Fetch https://example.com/pricing", toolName: "web_fetch",
                expiresAt: Date().addingTimeInterval(600)))
        _ = center.raise(
            AttentionItem(
                kind: .toolApproval, agent: Self.agent, sessionId: UUID(),
                title: "Approve shell?", body: "Run a shell command on this Mac.", toolName: "shell"))
        _ = center.raise(
            AttentionItem(
                kind: .clarification, agent: Self.agent, sessionId: UUID(),
                title: "Research Agent has a question",
                body: "Which quarter should the report cover?"))
        _ = center.raise(
            AttentionItem(kind: .workflowDialog, title: "Weekly report needs input", body: "Pick the region."))
        _ = center.raise(
            AttentionItem(kind: .inboundMessage, requester: Self.alice, title: "@alice sent a message"))
        return center
    }

    @Test func approvals_listsBlockingRequestsOnly() {
        let center = Self.seededCenter()
        let waiting = ApprovalPresentation.waiting(in: center)
        #expect(center.pending.count == 5)
        #expect(waiting.map(\.kind) == [.ownerApproval, .toolApproval, .clarification, .workflowDialog])
    }

    @Test func approvals_rowsReadAsSentences() {
        let waiting = ApprovalPresentation.waiting(in: Self.seededCenter())
        #expect(ApprovalPresentation.title(waiting[1]) == "Research Agent wants to use shell")
        #expect(!ApprovalPresentation.subtitle(waiting[1]).contains("Research Agent"))
        #expect(!ApprovalPresentation.subtitle(waiting[1]).contains("shell command"))
        #expect(ApprovalPresentation.title(waiting[2]) == "Which quarter should the report cover?")
        #expect(ApprovalPresentation.subtitle(waiting[2]).hasPrefix("Asked by Research Agent"))
        #expect(ApprovalPresentation.subtitle(waiting[0]).hasPrefix("Fetch https://example.com/pricing\nFrom @alice"))
        #expect(ApprovalPresentation.subtitle(waiting[0]).contains("if unanswered"))
        #expect(ApprovalPresentation.openTitle(.workflowDialog) == "Fill In Form")
    }

    @Test func approvalsPage_draws() async throws {
        let center = Self.seededCenter()
        for width in [CGFloat(620), 900] {
            let rep = try await Self.render("approvals", width: width, height: 640, ApprovalsView(center: center))
            #expect(Self.distinctColors(rep) > 8)
        }
    }

    @Test func approvalsPage_drawsTheEmptyState() async throws {
        let rep = try await Self.render("approvals-empty", width: 720, height: 360, ApprovalsView(center: AttentionCenter()))
        #expect(Self.distinctColors(rep) > 4)
    }

    @Test func ownerApprovalCard_draws() async throws {
        let state = OwnerApprovalPromptState(
            attentionId: UUID(), caller: Self.alice, agentName: "Research Agent", toolName: "web_fetch",
            offersConversationLease: true, expiresAt: Date().addingTimeInterval(240))
        let rep = try await Self.render(
            "owner-approval-card", width: 640, height: 480,
            OwnerApprovalPromptOverlay(state: state, onDismiss: {}).padding(16))
        #expect(Self.distinctColors(rep) > 8)
    }

    @Test func conversationEventRow_draws() async throws {
        let rep = try await Self.render(
            "conversation-event", width: 640, height: 80,
            ConversationEventRow(
                text: "You allowed web_fetch for @alice · 0x9c3e…11aa · iPhone",
                icon: "checkmark.shield", attentionId: UUID()
            ).padding(.vertical, 16))
        #expect(Self.distinctColors(rep) > 4)
    }

    @Test func notificationRouting_draws() async throws {
        let prefs = NotificationPreferences.default
        let rep = try await Self.render(
            "notification-routing", width: 720, height: 520,
            SettingsSection(title: "Notifications") {
                ForEach(NotificationCategory.allCases, id: \.self) { category in
                    NotificationRouteRow(category: category, prefs: .constant(prefs), appNotificationsOn: true)
                }
            }.padding(24))
        #expect(Self.distinctColors(rep) > 8)
    }
}
