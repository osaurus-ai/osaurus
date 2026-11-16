//
//  AppReopenPolicy.swift
//  osaurus
//
//  What a Dock icon click brings back: the window the person was last
//  looking at, as they left it.
//

import AppKit

/// Which window a Dock icon click (app reopen) brings back.
enum AppReopenPolicy {
    struct Candidate: Equatable {
        /// On screen (possibly behind other apps' windows).
        let isOnScreen: Bool
        let isMinimized: Bool
        /// A chat window. A chat hidden with the hotkey comes back; any
        /// other window that is neither on screen nor minimized counts as
        /// closed.
        let isChat: Bool
    }

    /// The index in `candidates` (most recently focused first) of the
    /// window to bring forward; nil when there is none and a chat opens.
    /// Only that window changes: other minimized windows stay in the Dock.
    static func pick(_ candidates: [Candidate]) -> Int? {
        candidates.firstIndex(where: \.isOnScreen)
            ?? candidates.firstIndex(where: \.isMinimized)
            ?? candidates.firstIndex(where: \.isChat)
    }
}

/// This app's windows in the order they last became key. AppKit's
/// `orderedWindows` leaves out panels, and every chat window is one, so
/// the Dock reopen and the hotkey keep their own record.
@MainActor
final class WindowFocusHistory: NSObject {
    static let shared = WindowFocusHistory()

    /// Most recent first.
    private var order: [ObjectIdentifier] = []
    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(windowDidBecomeKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(
            self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
    }

    func record(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
    }

    func forget(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        order.removeAll { $0 == id }
    }

    /// `windows`, most recently focused first; those never focused keep
    /// their given order after the rest.
    func mostRecentFirst(_ windows: [NSWindow]) -> [NSWindow] {
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return windows.enumerated()
            .sorted {
                (rank[ObjectIdentifier($0.element)] ?? Int.max, $0.offset)
                    < (rank[ObjectIdentifier($1.element)] ?? Int.max, $1.offset)
            }
            .map(\.element)
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        record(window)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        forget(window)
    }
}
