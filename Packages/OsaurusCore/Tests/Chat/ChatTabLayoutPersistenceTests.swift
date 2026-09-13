//
//  ChatTabLayoutPersistenceTests.swift
//  osaurusTests
//
//  Open chat tabs survive window close and relaunch: a window's persisted
//  conversations are recorded in `ChatTabLayoutStore` (ids only), records
//  of windows that are no longer open are orphans, and a new window adopts
//  them as hibernated tabs. Blank tabs are never recorded, an untouched
//  blank tab is reused by ⌘T / ⌘N rather than duplicated, and ⌘W on the
//  last conversation tab leaves a blank chat instead of closing the window.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatTabLayoutPersistenceTests {

    private func makeStore() -> (ChatTabLayoutStore, UserDefaults) {
        let suite = "ChatTabLayoutPersistenceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (ChatTabLayoutStore(defaults: defaults), defaults)
    }

    private func addTurn(_ session: ChatSession, _ text: String) {
        session.turns.append(ChatTurn(role: .user, content: text))
    }

    private func storedSession(_ title: String, agentId: UUID = Agent.defaultId) -> ChatSessionData {
        let data = ChatSessionData(
            id: UUID(), title: title,
            turns: [ChatTurnData(role: .user, content: "\(title) question")],
            agentId: agentId
        )
        ChatSessionStore.save(data)
        return data
    }

    // MARK: Store

    @Test func store_roundTripsRecords_andForgetsRemovedWindows() {
        let (store, defaults) = makeStore()
        #expect(store.load().windows.isEmpty)

        let windowA = UUID()
        let windowB = UUID()
        let a = ChatTabLayoutRecord(
            tabs: [.init(sessionId: UUID(), lastActivatedAt: Date(timeIntervalSince1970: 10))],
            activeSessionId: nil, savedAt: Date(timeIntervalSince1970: 100))
        let b = ChatTabLayoutRecord(
            tabs: [.init(sessionId: UUID(), lastActivatedAt: Date(timeIntervalSince1970: 20))],
            activeSessionId: nil, savedAt: Date(timeIntervalSince1970: 50))
        store.save(ChatTabLayout(windows: [windowA: a, windowB: b]))

        let loaded = store.load()
        #expect(loaded.windows[windowA] == a)
        #expect(loaded.windows[windowB] == b)

        // Orphans exclude open windows and come back oldest first.
        #expect(store.orphanRecords(openWindowIds: [windowA]).map(\.id) == [windowB])
        #expect(store.orphanRecords(openWindowIds: []).map(\.id) == [windowB, windowA])

        store.remove(windowIds: [windowA, windowB])
        #expect(store.load().windows.isEmpty)
        #expect(defaults.data(forKey: ChatTabLayoutStore.defaultsKey) == nil, "an empty layout leaves no key behind")
    }

    // MARK: Snapshot

    @Test func snapshot_recordsPersistedTabsInOrder_andSkipsBlankOnes() async throws {
        try await ChatHistoryTestStorage.run {
            let first = storedSession("First")
            let second = storedSession("Second")
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }

            window.loadSession(first)
            window.openSessionInNewTab(second)
            // A conversation typed into a fresh tab: switching away saves
            // it (it gets its id then), so it is remembered like the others.
            window.newTab(agentId: Agent.defaultId)
            addTurn(window.session, "typed here")
            #expect(window.session.sessionId == nil, "unsaved until the tab switch")
            // A trailing blank tab with nothing typed (⌘T) — not remembered.
            window.newTab(agentId: Agent.defaultId)
            #expect(window.tabs.count == 4)
            let third = try #require(window.tabs[2].session.sessionId, "saved on the way out")

            let record = window.tabLayoutSnapshot()
            #expect(record.tabs.map(\.sessionId) == [first.id, second.id, third])
            #expect(record.activeSessionId == nil, "the active blank tab has nothing to reopen")

            window.selectTab(id: window.tabs[1].id)
            #expect(window.tabLayoutSnapshot().activeSessionId == second.id)
        }
    }

    @Test func snapshot_changeHookFiresOnTabMutations() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            var fired = 0
            window.onTabLayoutChanged = { fired += 1 }

            addTurn(window.session, "d1")
            window.newTab(agentId: Agent.defaultId)
            #expect(fired > 0, "a new tab reports a layout change")

            let before = fired
            window.selectTab(id: window.tabs[0].id)
            #expect(fired > before, "switching tabs reports a layout change")
        }
    }

    // MARK: Restore

    @Test func restore_bringsTabsBackHibernated_andOpensOnTheRememberedActiveChat() async throws {
        try await ChatHistoryTestStorage.run {
            let first = storedSession("First")
            let second = storedSession("Second")
            let deleted = UUID()  // never saved: a chat deleted since
            let record = ChatTabLayoutRecord(
                tabs: [
                    .init(sessionId: first.id, lastActivatedAt: Date(timeIntervalSince1970: 1)),
                    .init(sessionId: deleted, lastActivatedAt: Date(timeIntervalSince1970: 2)),
                    .init(sessionId: second.id, lastActivatedAt: Date(timeIntervalSince1970: 3)),
                ],
                activeSessionId: second.id, savedAt: Date())

            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            #expect(window.restoreTabs(from: record) == 2)

            // The initial blank tab is gone; the two chats are back in order.
            #expect(window.tabs.count == 2)
            #expect(window.tabs.map(\.session.sessionId) == [first.id, second.id])
            #expect(window.session.sessionId == second.id, "reopens on the chat that was showing")
            // The transcript is read off the main thread: the tab is selected
            // at once, shows a loading state, and fills in when the load lands.
            #expect(window.session.isHydratingTranscript)
            #expect(window.session.turns.isEmpty)
            await window.awaitTranscriptHydration()
            #expect(!window.session.isHydratingTranscript)
            #expect(window.session.turns.count == 1, "the active tab is woken from disk")
            #expect(window.tabs.first { $0.session.sessionId == second.id }?.isHibernated == false)

            let inactive = try #require(window.tabs.first { $0.session.sessionId == first.id })
            #expect(inactive.isHibernated)
            #expect(inactive.session.title == "First", "a hibernated tab keeps its title")
            #expect(inactive.session.turns.isEmpty, "metadata only until selected")

            // Restoring the same record again is a no-op.
            #expect(window.restoreTabs(from: record) == 0)
            #expect(window.tabs.count == 2)
        }
    }

    @Test func restore_keepsAnActiveChatTheUserAlreadyOpened() async throws {
        try await ChatHistoryTestStorage.run {
            let first = storedSession("First")
            let other = storedSession("Other")
            let record = ChatTabLayoutRecord(
                tabs: [.init(sessionId: first.id, lastActivatedAt: Date())],
                activeSessionId: first.id, savedAt: Date())

            // "Open in New Window" from History: the window starts on a
            // conversation, so the remembered tabs join it without stealing focus.
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId, sessionData: other)
            defer { window.cleanup() }
            #expect(window.restoreTabs(from: record) == 1)
            #expect(window.session.sessionId == other.id)
            #expect(window.tabs.count == 2)
            #expect(window.tabs.last?.isHibernated == true)
        }
    }

    @Test func restore_buildsStubsFromMetadataOnly() async throws {
        try await ChatHistoryTestStorage.run {
            // A chat NOT in the sessions manager cache (saved straight to the
            // store) still comes back, via the batched metadata query, with
            // its title but no transcript.
            let stored = storedSession("Cold")
            let record = ChatTabLayoutRecord(
                tabs: [.init(sessionId: stored.id, lastActivatedAt: Date())],
                activeSessionId: nil, savedAt: Date())
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            addTurn(window.session, "keep the initial tab")

            #expect(window.restoreTabs(from: record) == 1)
            let tab = try #require(window.tabs.first { $0.session.sessionId == stored.id })
            #expect(tab.isHibernated)
            #expect(tab.session.title == "Cold")
            #expect(tab.session.turns.isEmpty)
            #expect(!tab.session.isHydratingTranscript, "nothing loads until the tab is selected")
        }
    }

    // MARK: Waking

    @Test func wake_switchingAwayBeforeTheLoadLands_hydratesInPlaceWithoutStealingFocus() async throws {
        try await ChatHistoryTestStorage.run {
            let stored = storedSession("Slow")
            let record = ChatTabLayoutRecord(
                tabs: [.init(sessionId: stored.id, lastActivatedAt: Date())],
                activeSessionId: nil, savedAt: Date())
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            addTurn(window.session, "home")
            let home = window.activeTabId
            #expect(window.restoreTabs(from: record) == 1)
            let cold = try #require(window.tabs.first { $0.session.sessionId == stored.id })

            window.selectTab(id: cold.id)
            #expect(cold.session.isHydratingTranscript)
            // Selecting it again while loading must not start a second load.
            window.selectTab(id: home)
            window.selectTab(id: cold.id)
            window.selectTab(id: home)

            await window.awaitTranscriptHydration()
            #expect(window.activeTabId == home, "the load completing never changes the selection")
            let woken = try #require(window.tabs.first { $0.id == cold.id })
            #expect(!woken.isHibernated)
            #expect(woken.session.turns.count == 1, "hydrated in place")
        }
    }

    @Test func wake_closingTheTabBeforeTheLoadLands_isDropped() async throws {
        try await ChatHistoryTestStorage.run {
            let stored = storedSession("Closed early")
            let record = ChatTabLayoutRecord(
                tabs: [.init(sessionId: stored.id, lastActivatedAt: Date())],
                activeSessionId: nil, savedAt: Date())
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            addTurn(window.session, "home")
            #expect(window.restoreTabs(from: record) == 1)
            let cold = try #require(window.tabs.first { $0.session.sessionId == stored.id })

            window.selectTab(id: cold.id)
            window.closeTab(id: cold.id)
            #expect(window.tabs.count == 1)

            await window.awaitTranscriptHydration()
            #expect(window.tabs.count == 1, "a closed tab does not come back")
            #expect(cold.session.turns.isEmpty, "the discarded stand-in is left alone")
        }
    }

    @Test func store_loadMetadataByIds_returnsRowsWithoutTurns() async throws {
        try await ChatHistoryTestStorage.run {
            let a = storedSession("A")
            let b = storedSession("B")
            let missing = UUID()
            let rows = ChatSessionStore.loadMetadata(ids: [b.id, missing, a.id])
            #expect(rows.map(\.id) == [b.id, a.id], "requested order, missing ids absent")
            #expect(rows.allSatisfy { $0.turns.isEmpty })
            #expect(rows.map(\.title) == ["B", "A"])
        }
    }

    // MARK: Blank tab reuse

    @Test func newTab_reusesAnUntouchedBlankActiveTab() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            let blank = window.activeTabId

            window.newTab()
            window.newTab()
            window.newTabInCurrentProject()
            #expect(window.tabs.count == 1, "⌘T / ⌘N on a blank tab stay on it")
            #expect(window.activeTabId == blank)

            // Anything typed makes the tab worth keeping.
            window.session.noteComposerDraft("half a thought")
            window.newTab()
            #expect(window.tabs.count == 2)

            // A conversation always gets a fresh tab.
            addTurn(window.session, "work")
            window.newTab()
            #expect(window.tabs.count == 3)
        }
    }

    // MARK: ⌘W

    @Test func closeActiveTabIfPossible_leavesABlankChatOnTheLastConversation() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            addTurn(window.session, "d1")
            window.newTab(agentId: Agent.defaultId)
            addTurn(window.session, "d2")

            #expect(window.closeActiveTabIfPossible(), "a sibling exists")
            #expect(window.tabs.count == 1)
            #expect(window.session.turns.first?.content == "d1")

            #expect(window.closeActiveTabIfPossible(), "the lone conversation tab closes into a blank chat")
            #expect(window.tabs.count == 1)
            #expect(window.session.turns.isEmpty)

            #expect(!window.closeActiveTabIfPossible(), "a lone blank tab falls through to the window")
            #expect(window.tabs.count == 1)
        }
    }
}
