//
//  ChatBatchActionsTests.swift
//  osaurusTests
//
//  The rules behind batch archive, pin and delete: chats deleted since
//  they were selected are skipped and counted, Undo restores each chat's
//  own prior archived state, and the bar offers Unarchive / Unpin only
//  when every selected chat already is.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct ChatBatchActionsTests {

    private func chat(archived: Bool = false, pinned: Bool = false) -> ChatSessionData {
        ChatSessionData(id: UUID(), title: "Chat", archived: archived, pinned: pinned)
    }

    @Test("chats no longer in the list are skipped and counted")
    func eligibility() {
        let a = chat(), b = chat()
        let gone = UUID()
        let result = ChatBatchActions.eligible([a.id, b.id, gone], in: [a, b])
        #expect(result.ids == [a.id, b.id])
        #expect(result.skipped == 1)
    }

    @Test("the Undo snapshot keeps each chat's own prior archived state, and only the chats acted on")
    func undoSnapshot() {
        let live = chat(), alreadyArchived = chat(archived: true), untouched = chat()
        let snapshot = ChatBatchActions.archivedSnapshot(
            [live.id, alreadyArchived.id], in: [live, alreadyArchived, untouched])
        #expect(snapshot == [live.id: false, alreadyArchived.id: true])
    }

    @Test("Unarchive and Unpin are offered only when every selected chat already is")
    func toggleLabels() {
        let archived = chat(archived: true), pinned = chat(pinned: true), plain = chat()
        let all = [archived, pinned, plain]
        #expect(ChatBatchActions.allArchived([archived.id], in: all))
        #expect(!ChatBatchActions.allArchived([archived.id, plain.id], in: all))
        #expect(ChatBatchActions.allPinned([pinned.id], in: all))
        #expect(!ChatBatchActions.allPinned([pinned.id, plain.id], in: all))
        #expect(!ChatBatchActions.allArchived([], in: all))
    }

    @Test("toast and confirmation copy is singular for one chat and counts skips")
    func copy() {
        #expect(ChatBatchActions.deleteTitle(count: 1) == "Delete 1 chat?")
        #expect(ChatBatchActions.deleteTitle(count: 10) == "Delete 10 chats?")
        #expect(ChatBatchActions.deleteButtonTitle(count: 3) == "Delete 3 chats")
        #expect(ChatBatchActions.archivedToastTitle(count: 1, archived: true, skipped: 0) == "1 chat archived")
        #expect(ChatBatchActions.archivedToastTitle(count: 4, archived: false, skipped: 0) == "4 chats moved back to the list")
        #expect(ChatBatchActions.archivedToastTitle(count: 3, archived: true, skipped: 1) == "3 archived, 1 skipped")
        #expect(ChatBatchActions.deletedToastTitle(count: 2, skipped: 0) == "2 chats deleted")
    }
}
