//
//  ChatSidebarNewChatTests.swift
//  osaurusTests
//
//  The sidebar's New chat row and agent rows: exactly one row reads as
//  current, an untouched chat is its agent's New chat row rather than a
//  row of its own, clicking a closed agent opens it to its new chat and
//  clicking an open one only folds it, and Delete Agent… says what goes.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct ChatSidebarNewChatTests {

    @Test("All chats wins, then an untouched chat's New chat row, then the chat on screen")
    func singleHighlight() {
        let agent = UUID(), chat = UUID()
        #expect(
            ChatSessionSidebar.highlightedRow(showingAllChats: true, activeChatId: chat, untouchedChatAgentId: agent)
                == .allChats)
        #expect(
            ChatSessionSidebar.highlightedRow(showingAllChats: false, activeChatId: chat, untouchedChatAgentId: agent)
                == .newChat(agent))
        #expect(
            ChatSessionSidebar.highlightedRow(showingAllChats: false, activeChatId: chat, untouchedChatAgentId: nil)
                == .chat(chat))
        #expect(
            ChatSessionSidebar.highlightedRow(showingAllChats: false, activeChatId: nil, untouchedChatAgentId: nil)
                == .none)
    }

    @Test("an untouched chat is never its own row under an agent; elsewhere only while on screen")
    func untouchedChatRule() {
        #expect(!ChatSessionSidebar.listsLiveChat(isUntouched: true, isOnScreen: true, underAgent: true))
        #expect(!ChatSessionSidebar.listsLiveChat(isUntouched: true, isOnScreen: false, underAgent: true))
        #expect(ChatSessionSidebar.listsLiveChat(isUntouched: true, isOnScreen: true, underAgent: false))
        #expect(!ChatSessionSidebar.listsLiveChat(isUntouched: true, isOnScreen: false, underAgent: false))
        #expect(ChatSessionSidebar.listsLiveChat(isUntouched: false, isOnScreen: false, underAgent: true))
    }

    @Test("a closed agent opens to its new chat; an open one folds without navigating")
    func agentRowClick() {
        #expect(ChatSessionSidebar.agentRowClick(isOpen: false) == .openToNewChat)
        #expect(ChatSessionSidebar.agentRowClick(isOpen: true) == .close)
    }

    @Test("deleting an agent counts every one of its chats, archived and pinned too")
    func agentChatCount() {
        let agent = UUID()
        let sessions = [
            ChatSessionData(title: "a", updatedAt: Date(), agentId: agent),
            ChatSessionData(title: "b", updatedAt: Date(), agentId: agent, archived: true),
            ChatSessionData(title: "c", updatedAt: Date(), agentId: agent, pinned: true),
            ChatSessionData(title: "d", updatedAt: Date()),
        ]
        #expect(ChatSessionSidebar.agentChatCount(sessions, agentId: agent) == 3)
        #expect(ChatSessionSidebar.agentChatCount(sessions, agentId: Agent.defaultId) == 1)
    }

    @Test("Delete Agent… names the agent, its memory and its chats")
    func deleteCopy() {
        #expect(AgentSidebarActions.deleteTitle(name: "Editor") == "Delete Editor?")
        #expect(
            AgentSidebarActions.deleteMessage(name: "Editor", chatCount: 3)
                == "Editor, its memory and its 3 chats are removed from this Mac. This cannot be undone.")
        #expect(
            AgentSidebarActions.deleteMessage(name: "Editor", chatCount: 1)
                == "Editor, its memory and its 1 chat are removed from this Mac. This cannot be undone.")
        #expect(
            AgentSidebarActions.deleteMessage(name: "Editor", chatCount: 0)
                == "Editor and its memory are removed from this Mac. This cannot be undone.")
    }
}
