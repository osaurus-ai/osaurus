import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct ChatWindowSessionOwnershipTests {
    @Test(arguments: [false, true], ["history", "tab", "window", "closed-tab"])
    func historyOpenDoesNotCreateASecondWriter(ownerTabInactive: Bool, route: String) async throws {
        try await ChatHistoryTestStorage.run {
            let stored = ChatSessionData(
                id: UUID(), title: "Shared history ownership",
                turns: [
                    ChatTurnData(role: .user, content: "Question"),
                    ChatTurnData(role: .assistant, content: "Delete this response"),
                ], agentId: Agent.defaultId
            )
            ChatSessionStore.save(stored)
            let owner = ChatWindowState(
                windowId: UUID(), agentId: Agent.defaultId, sessionData: stored)
            let canonical = owner.session
            if ownerTabInactive { owner.newTab() }
            let other = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            if route == "closed-tab" {
                // Record a real closed tab before registering the different
                // window that subsequently owns this persisted conversation.
                other.loadSession(stored)
                other.closeTab(id: other.activeTabId)
            }
            other.session.turns = [ChatTurn(role: .user, content: "Unrelated draft conversation")]
            other.session.save()
            let otherId = other.session.sessionId

            ChatWindowManager.shared.withRegisteredWindowStateForTesting(owner) {
                switch route {
                case "history": other.loadSession(stored)
                case "tab": other.openSessionInNewTab(stored)
                case "closed-tab": other.reopenLastClosedTab()
                default:
                    #expect(ChatWindowManager.shared.createWindow(
                        agentId: Agent.defaultId, sessionData: stored,
                        showImmediately: false) == owner.windowId)
                }
                #expect(other.session.sessionId != stored.id, "History must focus the owner, not hydrate a second writer")
                #expect(other.session.sessionId == otherId)
                #expect(other.tabs.count == 1, "redirecting must not create an empty tab")
                if route == "window", ownerTabInactive {
                    #expect(owner.session !== canonical, "a hidden lookup must not switch the owner's active tab")
                } else {
                    #expect(owner.session === canonical, "a visible open must select the owning tab")
                }
                #expect(ChatWindowManager.shared.revealOpenSession(
                    stored.id, showImmediately: false) == owner.windowId)

                canonical.turns.removeLast()
                canonical.save()
                owner.cleanup()
                other.cleanup()
                let persisted = ChatHistoryDatabase.shared.loadSession(id: stored.id)
                #expect(persisted?.turns.map(\.id) == [stored.turns[0].id])
                #expect(persisted?.turns.map(\.content) == ["Question"])
            }
        }
    }
}
