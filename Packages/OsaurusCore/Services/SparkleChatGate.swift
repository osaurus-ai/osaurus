//
//  SparkleChatGate.swift
//  osaurus
//
//  Cheap process-wide flag: a real chat window has been shown.
//

import Foundation

/// Written from `ChatWindowManager.showWindow` / `focusAllWindows` so the
/// launch Sparkle check can wait for chat to be on screen. Does not import
/// Sparkle or mention `UpdaterViewModel` — first-touch of the lazy
/// controller stays in AppDelegate's delayed Task.
@MainActor
enum SparkleChatGate {
    private(set) static var chatHasBeenShown = false

    static func markChatVisible() {
        chatHasBeenShown = true
    }
}
