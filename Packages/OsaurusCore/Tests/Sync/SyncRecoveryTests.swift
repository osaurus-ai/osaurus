//
//  SyncRecoveryTests.swift
//  OsaurusCoreTests
//
//  Sync failures show up under their own store in Storage recovery, and
//  Reset starts this Mac over whether or not the core could open.
//

import Foundation
import OsaurusSync
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct SyncRecoveryTests {
    @Test
    func syncErrorsMapToRecoveryKinds() {
        let newer = SyncError.NewerDatabase(code: SyncErrorCode.newerDatabase, detail: "v9")
        #expect(newer.storageIssueKind == .forwardVersion)
        #expect(StorageOpenIssueKind.classify(newer) == .forwardVersion)
        #expect(SyncError.Corrupt(code: SyncErrorCode.corrupt, detail: "").storageIssueKind == .corrupt)
        #expect(SyncError.KeyStore(code: SyncErrorCode.keyStore, detail: "").storageIssueKind == .locked)
        #expect(SyncError.Network(code: SyncErrorCode.network, detail: "").storageIssueKind == .unknown)
    }

    @Test
    func syncHasItsOwnStore() {
        #expect(StorageRecoveryService.Store.sync.path == OsaurusPaths.sync().path)
        #expect(StorageRecoveryService.Store.sync != .chatHistory)
    }

    @Test
    func resetStartsOverWhenTheCoreIsOpen() async throws {
        try await ChatHistoryTestStorage.run {
            let core = try SyncService.shared.open()
            let oldDevice = core.deviceKey()
            try SyncConversationStore.shared.saveSession(
                ChatSessionData(title: "Kept elsewhere", turns: [ChatTurnData(role: .user, content: "hi")]))
            #expect(!(try core.conversations()).isEmpty)

            let quarantined = await StorageRecoveryService.shared.resetStore(.sync)

            #expect(quarantined == nil)
            let fresh = try #require(SyncService.shared.core)
            #expect(fresh.deviceKey() != oldDevice)
            #expect(try fresh.conversations().isEmpty)
            #expect(PersistenceHealth.shared.storeIssue(for: StorageRecoveryService.Store.sync.rawValue) == nil)
        }
    }

    @Test
    func resetRecoversADamagedDatabase() async throws {
        try await ChatHistoryTestStorage.run {
            let oldDevice = try SyncService.shared.open().deviceKey()
            SyncService.shared.close()
            let database = OsaurusPaths.sync().appendingPathComponent("sync.db")
            for suffix in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: database.path + suffix)
            }
            try Data(repeating: 0x5A, count: 8192).write(to: database)
            #expect(throws: (any Error).self) { try SyncService.shared.open() }
            let issue = try #require(
                PersistenceHealth.shared.storeIssue(for: StorageRecoveryService.Store.sync.rawValue))
            #expect(issue.path == OsaurusPaths.sync().path)

            let quarantined = try #require(await StorageRecoveryService.shared.resetStore(.sync))

            #expect(FileManager.default.fileExists(atPath: quarantined.appendingPathComponent("sync.db").path))
            let fresh = try #require(SyncService.shared.core)
            #expect(fresh.deviceKey() != oldDevice)
            #expect(PersistenceHealth.shared.storeIssue(for: StorageRecoveryService.Store.sync.rawValue) == nil)
        }
    }
}
