//
//  SyncOwnChatTests.swift
//  osaurusTests
//
//  A Mac's own chats, continued from another of the user's devices
//  (docs/SYNC_MOBILE_CONTRACT.md §3.10): which conversations may be one,
//  and which message asks this Mac to answer.
//

import Foundation
import OsaurusSync
import Testing

@testable import OsaurusCore

struct SyncOwnChatTests {
    private let me = "mac-key"

    private func conversation(_ tags: [String: String]) -> Conversation {
        Conversation(
            scope: "scope", kind: .conversation, title: "t", pinned: false, sortOrder: nil, archived: false,
            lastActivityHlc: 0, lastPreview: nil, unread: 0, myRole: nil, members: [], replication: .synced,
            createdMs: 0, messageCount: 0, tags: tags.map { Tag(key: $0.key, value: $0.value) }, appData: [])
    }

    private func message(
        role: SyncMessageRole = .user, author: String = "iphone-key", isAgent: Bool = false, turn: String?
    ) -> SyncMessage {
        let appData = turn.map {
            [
                AppData(
                    namespace: SyncConversationMapper.turnNamespace, bytes: Data($0.utf8), blobs: [],
                    authorDevice: author, hlc: 0)
            ]
        }
        return SyncMessage(
            id: "m", scope: "scope", hlc: 0, timestampMs: 0, authorDevice: author, author: "u:me",
            isAgent: isAgent, role: role, content: "Hi", blobs: [], replyTo: nil, toolCallId: nil, toolName: nil,
            edited: false, delivery: .delivered, reactions: [], appData: appData ?? [])
    }

    // MARK: - Which conversations

    @Test func aChatNoDeviceHostsMayBeTheMacsOwn() {
        #expect(SyncHostRunner.mayBeOwnChat(conversation(["source": "chat", "osaurus.session": "s"])))
    }

    @Test func aHostedChatIsNeverAnOwnChat() {
        #expect(!SyncHostRunner.mayBeOwnChat(conversation(["source": "chat", "hostDevice": "other-mac"])))
        #expect(!SyncHostRunner.mayBeOwnChat(conversation(["source": "chat", "hostDevice": me])))
    }

    @Test func appConversationsAndHeadlessSourcesAreNotChats() {
        #expect(!SyncHostRunner.mayBeOwnChat(conversation(["ai.osaurus.kind": "attention", "source": "chat"])))
        #expect(!SyncHostRunner.mayBeOwnChat(conversation(["source": "plugin"])))
        #expect(!SyncHostRunner.mayBeOwnChat(conversation([:])))
    }

    // MARK: - Which message

    @Test func aUserTurnFromAnotherDeviceNamingThisMacAsks() {
        let turn = #"{"v":1,"id":"t","role":"user","hostRun":{"device":"mac-key","requestedMs":1}}"#
        #expect(SyncHostRunner.asksToContinueOwnChat(message(turn: turn), me: me))
    }

    @Test func aTurnNamingAnotherMacDoesntAsk() {
        let turn = #"{"v":1,"id":"t","role":"user","hostRun":{"device":"studio-key","requestedMs":1}}"#
        #expect(!SyncHostRunner.asksToContinueOwnChat(message(turn: turn), me: me))
    }

    @Test func thisMacsOwnTurnsAgentRepliesAndPlainTurnsDontAsk() {
        let turn = #"{"v":1,"id":"t","role":"user","hostRun":{"device":"mac-key","requestedMs":1}}"#
        #expect(!SyncHostRunner.asksToContinueOwnChat(message(author: me, turn: turn), me: me))
        #expect(!SyncHostRunner.asksToContinueOwnChat(message(isAgent: true, turn: turn), me: me))
        #expect(!SyncHostRunner.asksToContinueOwnChat(message(role: .assistant, turn: turn), me: me))
        #expect(!SyncHostRunner.asksToContinueOwnChat(message(turn: #"{"v":1,"id":"t","role":"user"}"#), me: me))
        #expect(!SyncHostRunner.asksToContinueOwnChat(message(turn: nil), me: me))
    }

    @Test func theDirectoryAdvertisesIt() {
        #expect(SyncDeviceFeedContract.features.contains("continue_own_chats"))
    }
}
