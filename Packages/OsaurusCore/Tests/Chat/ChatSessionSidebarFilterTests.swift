//
//  ChatSessionSidebarFilterTests.swift
//  osaurusTests
//
//  The navigator's search row narrows the Agents and Projects lenses by
//  name, and agents by their chats' titles too, with the same matching the
//  chat search uses; an empty or blank query shows everything and keeps
//  the list's order. Pinned chats leave their agent's list for the
//  Pinned group. Workspace chats list under their workspace's agent row:
//  the user's chats with a teammate's agent, and the chats teammates
//  started with the user's own agent.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct ChatSessionSidebarFilterTests {

    private struct Named { let name: String }

    private let items = [
        Named(name: "Orchestrator"),
        Named(name: "Content Writer"),
        Named(name: "Code Reviewer"),
        Named(name: "Résumé Coach"),
    ]

    @Test("an empty or blank query is no filter and keeps the order")
    func emptyQueryKeepsEverything() {
        #expect(ChatSessionSidebar.filterByName(items, query: "", name: \.name).map(\.name) == items.map(\.name))
        #expect(ChatSessionSidebar.filterByName(items, query: "   ", name: \.name).map(\.name) == items.map(\.name))
    }

    @Test("names match case-insensitively on any word, with surrounding whitespace ignored")
    func matchesByName() {
        #expect(
            ChatSessionSidebar.filterByName(items, query: "reviewer", name: \.name).map(\.name) == ["Code Reviewer"]
        )
        #expect(
            ChatSessionSidebar.filterByName(items, query: " writer ", name: \.name).map(\.name) == ["Content Writer"]
        )
        #expect(ChatSessionSidebar.filterByName(items, query: "Coach", name: \.name).map(\.name) == ["Résumé Coach"])
        #expect(ChatSessionSidebar.filterByName(items, query: "ORCH", name: \.name).map(\.name) == ["Orchestrator"])
    }

    @Test("a query nothing matches leaves an empty list for the lens's empty state")
    func noMatches() {
        #expect(ChatSessionSidebar.filterByName(items, query: "zzz", name: \.name).isEmpty)
    }

    @Test("search keeps an agent listed when its name or one of its chats' titles matches")
    func agentsMatchByChatTitle() {
        let chats = ["Fetch Downloads", "Quarterly taxes"]
        #expect(ChatSessionSidebar.navigatorShowsAgent(name: "Dinoki", chatTitles: chats, query: ""))
        #expect(ChatSessionSidebar.navigatorShowsAgent(name: "Dinoki", chatTitles: chats, query: "dino"))
        #expect(ChatSessionSidebar.navigatorShowsAgent(name: "Dinoki", chatTitles: chats, query: "downloads"))
        #expect(ChatSessionSidebar.navigatorShowsAgent(name: "Dinoki", chatTitles: chats, query: " TAXES "))
        #expect(!ChatSessionSidebar.navigatorShowsAgent(name: "Dinoki", chatTitles: chats, query: "calendar"))
        #expect(!ChatSessionSidebar.navigatorShowsAgent(name: "Dinoki", chatTitles: [], query: "downloads"))
    }

    @Test("pinned chats move from their agent's list to the Pinned group, newest first")
    func pinnedChatsGroupTogether() {
        let dinoki = UUID()
        let now = Date()
        let sessions = [
            ChatSessionData(title: "Fetch Downloads", updatedAt: now, agentId: dinoki),
            ChatSessionData(title: "Taxes", updatedAt: now.addingTimeInterval(-60), agentId: dinoki, pinned: true),
            ChatSessionData(title: "Plan", updatedAt: now, pinned: true),
            ChatSessionData(title: "Old", updatedAt: now, agentId: dinoki, archived: true, pinned: true),
            ChatSessionData(title: "hey", updatedAt: now, agentId: dinoki, archived: true),
        ]

        #expect(ChatSessionSidebar.agentHistorySessions(sessions, agentId: dinoki).map(\.title) == ["Fetch Downloads"])
        #expect(ChatSessionSidebar.agentHistorySessions(sessions, agentId: Agent.defaultId).isEmpty)
        #expect(ChatSessionSidebar.pinnedSessions(sessions).map(\.title) == ["Plan", "Taxes"])
    }

    @Test("Show Archived brings archived chats back into their agent's list and the Pinned group")
    func showArchivedIncludesArchived() {
        let dinoki = UUID()
        let now = Date()
        let sessions = [
            ChatSessionData(title: "Fetch Downloads", updatedAt: now, agentId: dinoki),
            ChatSessionData(title: "hey", updatedAt: now.addingTimeInterval(-60), agentId: dinoki, archived: true),
            ChatSessionData(title: "Old", updatedAt: now, agentId: dinoki, archived: true, pinned: true),
        ]

        #expect(
            ChatSessionSidebar.agentHistorySessions(sessions, agentId: dinoki, includeArchived: true).map(\.title)
                == ["Fetch Downloads", "hey"]
        )
        #expect(ChatSessionSidebar.pinnedSessions(sessions, includeArchived: true).map(\.title) == ["Old"])
        #expect(ChatSessionSidebar.pinnedSessions(sessions).isEmpty)
    }

    @Test("an archived chat with a live run stays listed while Show Archived is off")
    func liveArchivedChatsStayListed() {
        let dinoki = UUID()
        let now = Date()
        let running = ChatSessionData(title: "hey", updatedAt: now, agentId: dinoki, archived: true)
        let runningPinned = ChatSessionData(title: "Old", updatedAt: now, agentId: dinoki, archived: true, pinned: true)
        let sessions = [
            ChatSessionData(title: "Fetch Downloads", updatedAt: now, agentId: dinoki),
            running,
            ChatSessionData(title: "idle", updatedAt: now, agentId: dinoki, archived: true),
            runningPinned,
        ]
        let live: Set<UUID> = [running.id, runningPinned.id]

        #expect(
            ChatSessionSidebar.agentHistorySessions(sessions, agentId: dinoki, keepingArchived: live).map(\.title)
                == ["Fetch Downloads", "hey"]
        )
        #expect(ChatSessionSidebar.pinnedSessions(sessions, keepingArchived: live).map(\.title) == ["Old"])
    }

    @Test("a chat in an existing project is listed under the project, not its agent")
    func projectChatsLeaveTheirAgentsList() {
        let dinoki = UUID()
        let project = UUID()
        let now = Date()
        let sessions = [
            ChatSessionData(title: "Loose", updatedAt: now, agentId: dinoki),
            ChatSessionData(title: "Spec", updatedAt: now, agentId: dinoki, projectId: project),
            ChatSessionData(title: "Notes", updatedAt: now, projectId: project),
        ]

        #expect(
            ChatSessionSidebar.agentHistorySessions(sessions, agentId: dinoki, excludingProjects: [project])
                .map(\.title) == ["Loose"])
        #expect(
            ChatSessionSidebar.agentHistorySessions(sessions, agentId: Agent.defaultId, excludingProjects: [project])
                .isEmpty)
        #expect(
            ChatSessionSidebar.projectHistorySessions(sessions, projectId: project).map(\.title)
                == ["Spec", "Notes"])
    }

    @Test("a chat tagged with a project missing on this Mac stays under its agent")
    func orphanedProjectChatsStayWithTheirAgent() {
        let dinoki = UUID()
        let synced = UUID()
        let sessions = [ChatSessionData(title: "From the laptop", updatedAt: Date(), agentId: dinoki, projectId: synced)]

        #expect(
            ChatSessionSidebar.agentHistorySessions(sessions, agentId: dinoki, excludingProjects: [UUID()])
                .map(\.title) == ["From the laptop"])
    }

    @Test("pinned and archived project chats follow the same rules as an agent's")
    func projectListPinnedAndArchived() {
        let project = UUID()
        let now = Date()
        let running = ChatSessionData(title: "Running", updatedAt: now, archived: true, projectId: project)
        let sessions = [
            ChatSessionData(title: "Spec", updatedAt: now, projectId: project),
            ChatSessionData(title: "Pinned", updatedAt: now, pinned: true, projectId: project),
            ChatSessionData(title: "Archived", updatedAt: now, archived: true, projectId: project),
            running,
        ]

        #expect(ChatSessionSidebar.projectHistorySessions(sessions, projectId: project).map(\.title) == ["Spec"])
        #expect(
            ChatSessionSidebar.projectHistorySessions(sessions, projectId: project, keepingArchived: [running.id])
                .map(\.title) == ["Spec", "Running"])
        #expect(
            ChatSessionSidebar.projectHistorySessions(sessions, projectId: project, includeArchived: true)
                .map(\.title) == ["Spec", "Archived", "Running"])
        #expect(ChatSessionSidebar.pinnedSessions(sessions).map(\.title) == ["Pinned"])
    }

    private static let teamAgent = "0xabc"

    private func teamChat(_ title: String, workspace: String, pinned: Bool = false, archived: Bool = false)
        -> ChatSessionData
    {
        ChatSessionData(
            title: title, updatedAt: Date(), archived: archived, pinned: pinned,
            workspace: WorkspaceSessionContext(workspaceId: workspace, agentAddress: Self.teamAgent))
    }

    private func servedChat(_ title: String, agentId: UUID, workspace: String, pinned: Bool = false)
        -> ChatSessionData
    {
        ChatSessionData(
            title: title, updatedAt: Date(), agentId: agentId, pinned: pinned,
            workspace: WorkspaceSessionContext(
                workspaceId: workspace, agentAddress: "0xmine", callerWallet: "0xteammate", callerName: "Sam"))
    }

    @Test("a teammate's agent row lists the user's chats with it in that workspace only")
    func workspaceAgentChatsStayInTheirWorkspace() {
        let sessions = [
            teamChat("Brief", workspace: "w1"),
            teamChat("Other team", workspace: "w2"),
            teamChat("Pinned", workspace: "w1", pinned: true),
            teamChat("Old", workspace: "w1", archived: true),
            ChatSessionData(title: "Local", updatedAt: Date()),
        ]

        #expect(
            ChatSessionSidebar.workspaceAgentSessions(sessions, address: "0xABC", workspaceId: "w1").map(\.title)
                == ["Brief"])
        #expect(
            ChatSessionSidebar.workspaceAgentSessions(sessions, address: Self.teamAgent, workspaceId: "w1",
                includeArchived: true).map(\.title) == ["Brief", "Old"])
        #expect(
            ChatSessionSidebar.agentHistorySessions(sessions, agentId: Agent.defaultId).map(\.title) == ["Local"])
        var inProject = teamChat("Filed", workspace: "w1")
        let project = UUID()
        inProject.projectId = project
        #expect(ChatSessionSidebar.projectHistorySessions([inProject], projectId: project).isEmpty)
    }

    @Test("search keeps a workspace agent by the workspace's name, its own name, or a chat title")
    func workspaceSearch() {
        let titles = ["Launch brief"]
        #expect(ChatSessionSidebar.workspaceListsMember(
            workspaceName: "Acme", agentName: "Researcher", chatTitles: titles, query: "acme"))
        #expect(ChatSessionSidebar.workspaceListsMember(
            workspaceName: "Acme", agentName: "Researcher", chatTitles: titles, query: "research"))
        #expect(ChatSessionSidebar.workspaceListsMember(
            workspaceName: "Acme", agentName: "Researcher", chatTitles: titles, query: "brief"))
        #expect(!ChatSessionSidebar.workspaceListsMember(
            workspaceName: "Acme", agentName: "Researcher", chatTitles: titles, query: "taxes"))
    }

    @Test("chats teammates started with the user's agent list under its workspace row, not under Agents")
    func servedChatsLeaveTheAgentsList() {
        let dinoki = UUID()
        let sessions = [
            ChatSessionData(title: "Mine", updatedAt: Date(), agentId: dinoki),
            servedChat("Sam's question", agentId: dinoki, workspace: "w1"),
            servedChat("Elsewhere", agentId: dinoki, workspace: "w2"),
            servedChat("Pinned", agentId: dinoki, workspace: "w1", pinned: true),
        ]

        #expect(
            ChatSessionSidebar.servedSessions(sessions, agentId: dinoki, workspaceId: "w1").map(\.title)
                == ["Sam's question"])
        #expect(ChatSessionSidebar.servedSessions(sessions, agentId: dinoki, workspaceId: "").isEmpty)
        #expect(
            ChatSessionSidebar.agentHistorySessions(sessions, agentId: dinoki, excludingServedIn: ["w1"])
                .map(\.title) == ["Mine", "Elsewhere"])
        // No workspace row for it (roster not loaded): they stay under Agents.
        #expect(
            ChatSessionSidebar.agentHistorySessions(sessions, agentId: dinoki).map(\.title)
                == ["Mine", "Sam's question", "Elsewhere"])
    }

    @Test("pinned workspace chats join the Pinned group")
    func pinnedWorkspaceChatsArePinned() {
        let sessions = [
            teamChat("Team pin", workspace: "w1", pinned: true),
            servedChat("Served pin", agentId: UUID(), workspace: "w1", pinned: true),
            teamChat("Unpinned", workspace: "w1"),
        ]

        #expect(Set(ChatSessionSidebar.pinnedSessions(sessions).map(\.title)) == ["Team pin", "Served pin"])
    }

    @Test("folding a group flips only its key and forgets groups that are gone")
    func groupFoldStorage() {
        #expect(ChatSessionSidebar.toggling("w1", in: "") == "w1")
        #expect(ChatSessionSidebar.toggling("w2", in: "w1") == "w1,w2")
        #expect(ChatSessionSidebar.toggling("w1", in: "w1,w2") == "w2")
        #expect(ChatSessionSidebar.toggling("w3", in: "w1,w2", keeping: ["w2"]) == "w2,w3")
        #expect(ChatSessionSidebar.groupKeys("host:abc,shared") == ["host:abc", "shared"])
        #expect(
            ChatSessionSidebar.workspaceRowKey(workspaceId: "w1", address: "0xABC")
                != ChatSessionSidebar.workspaceRowKey(workspaceId: "w2", address: "0xabc"))
    }

    private struct Chat: Identifiable { let id = UUID() }

    @Test("live chats past the Show more cap stay visible, in order, without duplicates")
    func liveChatsPastTheCapStayVisible() {
        let chats = (0..<8).map { _ in Chat() }
        let ids = chats.map(\.id)

        #expect(ChatSessionSidebar.navigatorVisibleChats(chats, cap: 5, activeIds: []).map(\.id) == Array(ids[0..<5]))
        #expect(
            ChatSessionSidebar.navigatorVisibleChats(chats, cap: 5, activeIds: [ids[6], ids[1]]).map(\.id)
                == Array(ids[0..<5]) + [ids[6]]
        )
        #expect(ChatSessionSidebar.navigatorVisibleChats(chats, cap: 20, activeIds: [ids[7]]).map(\.id) == ids)
    }
}
