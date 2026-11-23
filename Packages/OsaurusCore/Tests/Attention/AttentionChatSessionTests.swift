//
//  AttentionChatSessionTests.swift
//  osaurusTests
//
//  An attention item names the chat the user sees, so an iPhone can show it
//  in that chat (docs/SYNC_MOBILE_CONTRACT.md §4). A hidden handoff (the
//  Configurator) runs its tools under a "handoff-…" session id that is no
//  chat; its items name the launching chat instead.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct AttentionChatSessionTests {

    @Test func aHiddenHandoffsItemNamesTheLaunchingChat() async {
        let chat = ChatSession()
        let chatId = UUID()
        chat.sessionId = chatId
        let item = await ChatExecutionContext.$currentChatSessionBox.withValue(WeakChatSessionBox(chat)) {
            await ChatExecutionContext.$currentSessionId.withValue("handoff-configurator-\(UUID().uuidString)") {
                AttentionProducers.item(id: UUID(), kind: .configApproval, title: "Apply 1 configuration change?")
            }
        }
        #expect(item.sessionId == chatId)
    }

    @Test func aChatsOwnIdIsKept() async {
        let launcher = ChatSession()
        launcher.sessionId = UUID()
        let own = UUID()
        let item = await ChatExecutionContext.$currentChatSessionBox.withValue(WeakChatSessionBox(launcher)) {
            await ChatExecutionContext.$currentSessionId.withValue(own.uuidString) {
                AttentionProducers.item(id: UUID(), kind: .toolApproval, title: "Allow web_fetch?")
            }
        }
        #expect(item.sessionId == own)
    }
}
