//
//  ChatContentPageTests.swift
//  osaurusTests
//
//  The All chats page's routing: the `osaurus://chats/all` deep link (which
//  must never fall through to pairing), and the window returning to the
//  conversation whenever a chat is opened.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct AllChatsDeepLinkTests {

    @Test("osaurus://chats/all opens the unfiltered page")
    func plainLink() throws {
        let request = try #require(AllChatsRequest(url: URL(string: "osaurus://chats/all")!))
        #expect(request.agentId == nil)
        #expect(request.filter == .all)
        #expect(request.query.isEmpty)
    }

    @Test("?agent= filters the page to that agent")
    func agentLink() throws {
        let agent = UUID()
        let request = try #require(AllChatsRequest(url: URL(string: "osaurus://chats/all?agent=\(agent.uuidString)")!))
        #expect(request.agentId == agent)
    }

    @Test("an unreadable agent id still opens the page, unfiltered, and is never left to pairing")
    func badAgentStillClaimed() throws {
        let request = try #require(AllChatsRequest(url: URL(string: "osaurus://chats/all?agent=nope")!))
        #expect(request.agentId == nil)
    }

    @Test("other hosts are not claimed")
    func otherHosts() {
        #expect(AllChatsRequest(url: URL(string: "osaurus://workflows")!) == nil)
        #expect(AllChatsRequest(url: URL(string: "osaurus://0xabc")!) == nil)
    }

    @Test("two identical requests differ, so asking again re-applies the chips")
    func requestsAreDistinct() {
        #expect(AllChatsRequest() != AllChatsRequest())
    }
}

@Suite(.serialized)
@MainActor
struct ChatContentPageRoutingTests {

    @Test("All chats opens over the conversation; opening a chat or going back returns to it")
    func allChatsRoundTrip() async throws {
        try await ChatHistoryTestStorage.run {
            let state = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            state.showAllChats(AllChatsRequest(filter: .archived))
            #expect(state.chatPage.isAllChats)

            #expect(state.goBack())
            #expect(state.chatPage == .conversation)

            state.showAllChats()
            state.startNewChat()
            #expect(state.chatPage == .conversation)
        }
    }

    @Test("the selection survives moving between the conversation and All chats")
    func selectionSurvivesNavigation() async throws {
        try await ChatHistoryTestStorage.run {
            let state = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            let id = UUID()
            state.chatSelection.toggle(id)
            state.showAllChats()
            state.showConversation()
            #expect(state.chatSelection.contains(id))
        }
    }
}
