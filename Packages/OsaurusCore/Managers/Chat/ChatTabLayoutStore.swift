//
//  ChatTabLayoutStore.swift
//  osaurus
//
//  Remembers which conversations each chat window had open as tabs, so a
//  relaunch (or closing and reopening the window) brings the tabs back
//  instead of a lone blank chat. Only ids are stored: the transcript stays
//  in `ChatSessionStore`, and restored tabs come back hibernated (metadata
//  only) until selected, exactly like a run retained across relaunch.
//

import Foundation

/// One window's open tabs at the time they were last saved.
struct ChatTabLayoutRecord: Codable, Equatable {
    struct Tab: Codable, Equatable {
        let sessionId: UUID
        let lastActivatedAt: Date
    }

    /// Persisted conversations in strip order (all agents). Blank tabs and
    /// registry-owned runs are never recorded: a blank has nothing to
    /// reopen, and the `BackgroundTaskManager` retains runs itself.
    var tabs: [Tab]
    /// The tab that was showing, when it was a persisted conversation.
    var activeSessionId: UUID?
    var savedAt: Date
}

/// Keyed by window id. A record whose window is no longer open is an
/// orphan: the next plain chat window adopts every orphan (relaunch, or a
/// window closed and reopened in the same run), then the records are
/// removed so the tabs are not restored twice.
struct ChatTabLayout: Codable, Equatable {
    var windows: [UUID: ChatTabLayoutRecord] = [:]
}

struct ChatTabLayoutStore {
    static let shared = ChatTabLayoutStore()
    static let defaultsKey = "chatTabLayout.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ChatTabLayout {
        guard let data = defaults.data(forKey: Self.defaultsKey),
            let layout = try? JSONDecoder().decode(ChatTabLayout.self, from: data)
        else { return ChatTabLayout() }
        return layout
    }

    func save(_ layout: ChatTabLayout) {
        if layout.windows.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(layout) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Records for windows that are not in `openWindowIds`, oldest first.
    func orphanRecords(openWindowIds: Set<UUID>) -> [(id: UUID, record: ChatTabLayoutRecord)] {
        load().windows
            .filter { !openWindowIds.contains($0.key) }
            .map { (id: $0.key, record: $0.value) }
            .sorted { $0.record.savedAt < $1.record.savedAt }
    }

    func remove(windowIds: [UUID]) {
        var layout = load()
        for id in windowIds { layout.windows.removeValue(forKey: id) }
        save(layout)
    }
}
