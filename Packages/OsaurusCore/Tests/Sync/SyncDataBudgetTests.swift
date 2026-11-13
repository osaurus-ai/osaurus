//
//  SyncDataBudgetTests.swift
//  OsaurusCoreTests
//
//  A turn too big for one app data write moves its largest values to blobs
//  until it fits, and drops optional fields in the documented order only
//  when that isn't enough. The synced copy says it was truncated, and this
//  device keeps the dropped fields.
//

import Foundation
import OsaurusSync
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct SyncDataBudgetTests {
    private let medium = 15 * 1024

    private func crowdedTurn() -> ChatTurnData {
        var turn = ChatTurnData(
            role: .assistant,
            content: "Done.",
            toolResults: [
                "call_1": String(repeating: "a", count: medium),
                "call_2": String(repeating: "b", count: medium),
                "call_3": String(repeating: "c", count: medium),
            ],
            thinking: String(repeating: "t", count: medium),
            createdAt: Date(timeIntervalSince1970: 1_767_225_600)
        )
        turn.injectedContextPrefix = String(repeating: "m", count: medium)
        return turn
    }

    /// Medium fields plus `count` tool results too small to move to a blob.
    private func manySmallResultsTurn(count: Int) -> ChatTurnData {
        var results: [String: String] = [:]
        for i in 0 ..< count { results[String(format: "call_%05d", i)] = String(repeating: "r", count: 10) }
        var turn = ChatTurnData(
            role: .assistant,
            content: "Done.",
            toolResults: results,
            thinking: String(repeating: "t", count: medium),
            createdAt: Date(timeIntervalSince1970: 1_767_225_600)
        )
        turn.injectedContextPrefix = String(repeating: "m", count: medium)
        return turn
    }

    /// The smallest turn of that shape that needs a field dropped.
    private func justTooBigTurn() throws -> ChatTurnData {
        var low = 1000
        var high = 4000
        #expect(try SyncConversationMapper.encode(turn: manySmallResultsTurn(count: low), toolName: nil).overflow.isEmpty)
        #expect(try !SyncConversationMapper.encode(turn: manySmallResultsTurn(count: high), toolName: nil).overflow.isEmpty)
        while high - low > 1 {
            let mid = (low + high) / 2
            if try SyncConversationMapper.encode(turn: manySmallResultsTurn(count: mid), toolName: nil).overflow.isEmpty {
                low = mid
            } else {
                high = mid
            }
        }
        return manySmallResultsTurn(count: high)
    }

    @Test
    func mediumValuesMoveToBlobsBeforeAnyFieldIsDropped() throws {
        let turn = crowdedTurn()
        let encoded = try SyncConversationMapper.encode(turn: turn, toolName: nil)
        let object = try #require(SyncConversationMapper.parseObject(encoded.appData))

        #expect(encoded.appData.count <= SyncConversationMapper.maxAppDataBytes)
        #expect(encoded.appDataBlobs.map(\.name) == ["toolResults.call_1"])
        #expect(encoded.overflow.isEmpty)
        #expect(object["truncated"] == nil)
        #expect((object["injectedContextPrefix"] as? String)?.count == medium)
        #expect((object["thinking"] as? String)?.count == medium)
        for _ in 0 ..< 5 {
            #expect(try SyncConversationMapper.encode(turn: turn, toolName: nil).appData == encoded.appData)
        }
    }

    @Test
    func fieldsDropInOrderOnlyWhenBlobsCantMakeItFit() throws {
        let encoded = try SyncConversationMapper.encode(turn: justTooBigTurn(), toolName: nil)
        let object = try #require(SyncConversationMapper.parseObject(encoded.appData))

        #expect(encoded.appData.count <= SyncConversationMapper.maxAppDataBytes)
        #expect(Set(encoded.overflow.keys) == ["injectedContextPrefix"])
        #expect((encoded.overflow["injectedContextPrefix"] as? String)?.count == medium)
        #expect(object["injectedContextPrefix"] == nil)
        #expect(encoded.appDataBlobs.map(\.name) == ["thinking"])
        #expect((object["thinking"] as? [String: Any])?["$blob"] as? Int == 0)
        #expect(object["truncated"] as? Bool == true)
    }

    @Test
    func blobbedAndDroppedFieldsStayOnThisDevice() async throws {
        let crowded = crowdedTurn()
        let tooBig = try justTooBigTurn()
        try await ChatHistoryTestStorage.run {
            let store = SyncConversationStore.shared
            let core = try SyncService.shared.open()
            let session = ChatSessionData(
                id: UUID(),
                title: "Crowded",
                turns: [
                    ChatTurnData(role: .user, content: "Go", createdAt: crowded.createdAt),
                    crowded,
                    ChatTurnData(role: .user, content: "More", createdAt: crowded.createdAt),
                    tooBig,
                ],
                source: .chat
            )
            try store.saveSession(session)

            let scope = try #require(store.scope(forSession: session.id))
            let stored = try core.messages(scope: scope, before: nil, limit: 10).messages
            let synced = try #require(stored.last?.appData(SyncConversationMapper.turnNamespace))
            #expect(SyncConversationMapper.parseObject(synced.bytes)?["injectedContextPrefix"] == nil)

            store.invalidateCaches()
            let loaded = try #require(store.loadSession(id: session.id))
            #expect(loaded.turns[1].injectedContextPrefix == crowded.injectedContextPrefix)
            #expect(loaded.turns[1].thinking == crowded.thinking)
            #expect(loaded.turns[1].toolResults == crowded.toolResults)
            #expect(loaded.turns[3].injectedContextPrefix == tooBig.injectedContextPrefix)
            #expect(loaded.turns[3].thinking == tooBig.thinking)
            #expect(loaded.turns[3].toolResults == tooBig.toolResults)
        }
    }
}
