//
//  ChatContentPage.swift
//  osaurus
//
//  What the Chat destination's content column shows: the conversation, or
//  the All chats page over it.
//

import Foundation

enum ChatContentPage: Equatable {
    case conversation
    case allChats(AllChatsRequest)

    var isAllChats: Bool {
        if case .allChats = self { return true }
        return false
    }
}

/// The All chats page's single-choice filter chips.
enum AllChatsFilter: String, CaseIterable, Equatable, Sendable {
    case all, pinned, untitled, archived
}

/// How the All chats page opens: its chips and its search field.
struct AllChatsRequest: Equatable {
    var agentId: UUID? = nil
    var filter: AllChatsFilter = .all
    var query: String = ""
    /// Tells two identical requests apart, so asking again re-applies the
    /// chips over whatever the user changed on the page since.
    var id = UUID()

    init(agentId: UUID? = nil, filter: AllChatsFilter = .all, query: String = "") {
        self.agentId = agentId
        self.filter = filter
        self.query = query
    }

    /// `osaurus://chats/all`, optionally `?agent=<agent id>`. Any
    /// `osaurus://chats` link is claimed here, so it never falls through to
    /// pairing; an unknown path or agent id opens the unfiltered page.
    init?(url: URL) {
        guard url.host?.lowercased() == "chats" else { return nil }
        self.init()
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let raw = items.first(where: { $0.name.lowercased() == "agent" })?.value {
            agentId = UUID(uuidString: raw)
        }
    }
}
