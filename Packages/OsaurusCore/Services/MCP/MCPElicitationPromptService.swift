//
//  MCPElicitationPromptService.swift
//  osaurus
//
//  Presents `elicitation/create` requests from connected MCP servers. Same
//  shape as `ToolPermissionPromptService`: each request is a queued entry with
//  its own continuation, exactly one panel is on screen, and every way out
//  resolves exactly its own entry and presents the next one.
//
//  The SDK client awaits a server request inline in its receive loop, so
//  while a handler is suspended the client reads nothing else from that
//  server. URL mode therefore answers `accept` the moment the user opens the
//  link (which is what `accept` means in URL mode) and keeps the card up on its
//  own until `notifications/elicitation/complete` arrives or the user clicks
//  Done. Holding the answer until completion would deadlock.
//

import AppKit
import Foundation
import SwiftUI

/// What the card asks the service to do.
enum MCPElicitationAction: Equatable {
    /// Answer the server and close the card.
    case respond(MCPElicitationOutcome)
    /// URL mode: the user opened the link. Answer `accept`, keep the card up
    /// until the server confirms.
    case openedURL
    /// Close a URL card that is waiting for confirmation.
    case done
}

@MainActor
enum MCPElicitationPromptService {
    private final class Entry {
        let request: MCPElicitationRequest
        var continuation: CheckedContinuation<MCPElicitationOutcome, Never>?

        init(request: MCPElicitationRequest, continuation: CheckedContinuation<MCPElicitationOutcome, Never>) {
            self.request = request
            self.continuation = continuation
        }

        var isAnswered: Bool { continuation == nil }

        func answer(_ outcome: MCPElicitationOutcome) {
            continuation?.resume(returning: outcome)
            continuation = nil
        }
    }

    private struct PanelHandles {
        let panel: NSPanel
        let closeObserver: NSObjectProtocol
        let keyMonitor: Any?
    }

    private static var queue: [Entry] = []
    private static var presented: (entry: Entry, handles: PanelHandles?)?

    // MARK: Test seams

    /// Replaces the panel. The test drives it with `performForTesting`. With
    /// no override a test process cancels, because nobody can type into a panel.
    static var presentationOverrideForTests: ((MCPElicitationRequest) -> Void)?

    static func performForTesting(id: UUID, _ action: MCPElicitationAction) {
        perform(action, id: id)
    }

    static var presentedRequestForTesting: MCPElicitationRequest? { presented?.entry.request }

    // MARK: Entry points

    static func present(_ request: MCPElicitationRequest) async -> MCPElicitationOutcome {
        if RuntimeEnvironment.isUnderTests && presentationOverrideForTests == nil { return .cancel }
        return await withCheckedContinuation { continuation in
            queue.append(Entry(request: request, continuation: continuation))
            pump()
        }
    }

    /// The tool call behind these prompts is over; nobody is waiting for an
    /// answer. A URL card that was already answered stays up for its
    /// completion notification.
    static func cancel(clientKey: ObjectIdentifier) {
        for entry in allEntries where entry.request.clientKey == clientKey && !entry.isAnswered {
            perform(.respond(.cancel), id: entry.request.id)
        }
    }

    /// `notifications/elicitation/complete`: the user finished the browser step.
    static func markCompleted(elicitationId: String) {
        for entry in allEntries {
            guard case .url(_, let id) = entry.request.mode, id == elicitationId else { continue }
            perform(.respond(.accept([:])), id: entry.request.id)
        }
    }

    // MARK: Queue core

    private static var allEntries: [Entry] {
        (presented.map { [$0.entry] } ?? []) + queue
    }

    private static func perform(_ action: MCPElicitationAction, id: UUID) {
        if let index = queue.firstIndex(where: { $0.request.id == id }) {
            switch action {
            case .respond(let outcome): queue.remove(at: index).answer(outcome)
            case .openedURL, .done: break
            }
            return
        }
        guard let current = presented, current.entry.request.id == id else { return }
        switch action {
        case .respond(let outcome):
            current.entry.answer(outcome)
            close(current)
        case .openedURL:
            current.entry.answer(.accept([:]))
        case .done:
            current.entry.answer(.accept([:]))
            close(current)
        }
    }

    private static func close(_ current: (entry: Entry, handles: PanelHandles?)) {
        presented = nil
        if let handles = current.handles { tearDown(handles) }
        pump()
    }

    private static func pump() {
        guard presented == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        presented = (next, nil)
        if let override = presentationOverrideForTests {
            override(next.request)
            return
        }
        let id = next.request.id
        let handles = makePanel(request: next.request) { action in perform(action, id: id) }
        // Resolved while the panel was being built.
        guard presented?.entry === next else {
            tearDown(handles)
            return
        }
        presented = (next, handles)
    }

    private static func tearDown(_ handles: PanelHandles) {
        NotificationCenter.default.removeObserver(handles.closeObserver)
        if let monitor = handles.keyMonitor { NSEvent.removeMonitor(monitor) }
        handles.panel.orderOut(nil)
    }

    // MARK: Presentation

    private static func makePanel(
        request: MCPElicitationRequest,
        onAction: @escaping (MCPElicitationAction) -> Void
    ) -> PanelHandles {
        let view = MCPElicitationView(request: request, onAction: onAction)
            .padding(24)
            .environment(\.theme, ThemeManager.shared.currentTheme)
        let hosting = NSHostingController(rootView: view)
        hosting.safeAreaRegions = []

        // Key-capable so the form's text fields take focus.
        let panel = CredentialPromptPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = L("Connector request")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .modalPanel
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .alertPanel
        panel.appearance = NSAppearance(named: ThemeManager.shared.currentTheme.isDark ? .darkAqua : .aqua)
        panel.contentViewController = hosting

        hosting.view.layoutSubtreeIfNeeded()
        let fitting = hosting.view.fittingSize
        let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let size = ToolPermissionPromptService.clampedWindowSize(
                NSSize(width: max(fitting.width, 520), height: fitting.height), to: visible.size)
            panel.setFrame(
                NSRect(
                    x: visible.origin.x + (visible.width - size.width) / 2,
                    y: visible.origin.y + (visible.height - size.height) / 2,
                    width: size.width, height: size.height),
                display: false)
        } else {
            panel.setContentSize(fitting)
            panel.center()
        }

        // Closing an unanswered card cancels; closing a waiting URL card is Done.
        nonisolated(unsafe) let onClose = onAction
        let closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { _ in onClose(.respond(.cancel)) }

        weak let weakPanel = panel
        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, weakPanel?.isKeyWindow == true else { return event }
            onAction(.respond(.cancel))
            return nil
        }

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        return PanelHandles(panel: panel, closeObserver: closeObserver, keyMonitor: keyMonitor)
    }
}
