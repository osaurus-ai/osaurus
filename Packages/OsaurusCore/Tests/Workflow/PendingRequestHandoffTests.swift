//
//  PendingRequestHandoffTests.swift
//  osaurusTests
//
//  A one-shot request set while the view that owns it is already on screen
//  is taken on the first try: a store link clicked with Workflows open
//  opens its import sheet without a second click.
//

import AppKit
import Combine
import Foundation
import SwiftUI
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct PendingRequestHandoffTests {
    @MainActor
    private final class Requests: ObservableObject {
        @Published var request: String?
        var taken: [String] = []
    }

    private struct Consumer: View {
        @ObservedObject var requests: Requests

        var body: some View {
            Color.clear
                .onPendingRequest(requests.$request) {
                    guard let request = requests.request else { return }
                    requests.request = nil
                    requests.taken.append(request)
                }
        }
    }

    private func mount<V: View>(_ view: V) -> NSWindow {
        let host = NSHostingView(rootView: view.frame(width: 640, height: 480))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()
        return window
    }

    private func settle(_ milliseconds: UInt64 = 300) async throws {
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }

    @Test func requestSetWhileMountedIsTakenOnce() async throws {
        let requests = Requests()
        let window = mount(Consumer(requests: requests))
        defer { window.orderOut(nil) }
        try await settle()

        requests.request = "first"
        try await settle()
        #expect(requests.taken == ["first"])
        #expect(requests.request == nil)

        requests.request = "second"
        try await settle()
        #expect(requests.taken == ["first", "second"])
        #expect(requests.request == nil)
    }

    @Test func requestSetBeforeMountIsTakenOnMount() async throws {
        let requests = Requests()
        requests.request = "early"
        let window = mount(Consumer(requests: requests))
        defer { window.orderOut(nil) }
        try await settle()
        #expect(requests.taken == ["early"])
        #expect(requests.request == nil)
    }

    @Test func workflowsViewTakesAnImportWhileOnScreen() async throws {
        try await ChatHistoryTestStorage.run {
            InstalledWorkflowStore.shared.reload()
            let state = ManagementStateManager.shared
            state.pendingTemplateImport = nil
            let windowState = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            let window = mount(WorkflowsView(windowState: windowState).environment(\.theme, ThemeManager.shared.currentTheme))
            defer {
                window.orderOut(nil)
                windowState.cleanup()
                state.pendingTemplateImport = nil
            }
            try await settle(600)

            state.pendingTemplateImport = PendingTemplateImport(text: "{}", kind: .workflow)
            try await settle()
            #expect(state.pendingTemplateImport == nil)
        }
    }
}
