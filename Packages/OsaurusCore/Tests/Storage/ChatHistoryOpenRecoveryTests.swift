import Foundation
import OsaurusSQLCipher
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct ChatHistoryOpenRecoveryTests {
    private static let store = StorageRecoveryService.Store.chatHistory.rawValue

    @Test
    func initialCorruptOpenRecordsRecoverableIssueAndPreservesFile() async throws {
        try await withPlaintextRoot {
            let bytes = try Self.seedCorruptHistory()
            #expect(throws: (any Error).self) { try ChatHistoryDatabase.shared.open() }
            #expect(!ChatHistoryDatabase.shared.isOpen)
            #expect(!ChatHistoryDatabase.shared.isOpenNonBlocking)
            let issue = try #require(PersistenceHealth.shared.storeIssue(for: Self.store))
            #expect(issue.kind == .corrupt)
            #expect(issue.path == OsaurusPaths.chatHistoryDatabaseFile().path)
            #expect(try Data(contentsOf: OsaurusPaths.chatHistoryDatabaseFile()) == bytes)
        }
    }

    @Test
    func failedRetryPreservesFileThenRestoredHistoryReopensAndClearsIssue() async throws {
        try await withPlaintextRoot {
            let session = ChatSessionData(
                title: "Recovery fixture — stored history",
                turns: [ChatTurnData(role: .assistant, content: "Stored fixture, not generated output")]
            )
            try ChatHistoryDatabase.shared.open()
            try ChatHistoryDatabase.shared.saveSession(session)
            ChatHistoryDatabase.shared.close()
            let path = OsaurusPaths.chatHistoryDatabaseFile()
            let healthy = try Data(contentsOf: path)
            let corrupt = try Self.seedCorruptHistory()
            #expect(throws: (any Error).self) { try ChatHistoryDatabase.shared.open() }
            #expect(PersistenceHealth.shared.storeIssue(for: Self.store) != nil)

            let failed = await StorageRecoveryService.shared.retryStore(.chatHistory)
            #expect(!failed)
            #expect(!ChatHistoryDatabase.shared.isOpenNonBlocking)
            #expect(PersistenceHealth.shared.storeIssue(for: Self.store)?.kind == .corrupt)
            #expect(try Data(contentsOf: path) == corrupt)

            // Restore only this test's closed fixture; Retry must reopen the real store.
            try healthy.write(to: path)
            let reopened = await StorageRecoveryService.shared.retryStore(.chatHistory)
            #expect(reopened)
            #expect(ChatHistoryDatabase.shared.isOpenNonBlocking)
            #expect(PersistenceHealth.shared.storeIssue(for: Self.store) == nil)
            let loaded = try #require(ChatHistoryDatabase.shared.loadSession(id: session.id))
            #expect(loaded.title == session.title)
            #expect(loaded.turns.first?.content == session.turns.first?.content)
        }
    }

    @Test
    func migrationFailureStillReportsIssueAndClosesConnection() async throws {
        try await withPlaintextRoot {
            // A readable database with an incompatible table fails after openConnection.
            try ChatHistoryDatabase.shared.open()
            ChatHistoryDatabase.shared.close()
            let connection = try OsaurusStorageOpener.open(path: OsaurusPaths.chatHistoryDatabaseFile().path)
            defer { sqlite3_close(connection) }
            #expect(sqlite3_exec(connection, "DROP TABLE turns; CREATE TABLE turns (broken TEXT)", nil, nil, nil) == SQLITE_OK)
            #expect(throws: (any Error).self) { try ChatHistoryDatabase.shared.open() }
            #expect(!ChatHistoryDatabase.shared.isOpen)
            #expect(!ChatHistoryDatabase.shared.isOpenNonBlocking)
            #expect(PersistenceHealth.shared.storeIssue(for: Self.store)?.kind == .migration)
        }
    }

    private static func seedCorruptHistory() throws -> Data {
        let path = OsaurusPaths.chatHistoryDatabaseFile()
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var bytes = Data("SQLite format 3\0".utf8)
        bytes.append(Data(repeating: 0xA5, count: 4096 - bytes.count))
        try bytes.write(to: path)
        return bytes
    }

    private func withPlaintextRoot(_ body: @Sendable () async throws -> Void) async throws {
        try await StoragePathsTestLock.shared.run {
            let previousRoot = OsaurusPaths.overrideRoot
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-open-recovery-\(UUID())")
            ChatHistoryDatabase.shared.close()
            OsaurusPaths.overrideRoot = root
            PersistenceHealth.shared.clearStoreIssue(store: Self.store)
            defer {
                ChatHistoryDatabase.shared.close()
                PersistenceHealth.shared.clearStoreIssue(store: Self.store)
                OsaurusPaths.overrideRoot = previousRoot
                StorageEncryptionPolicy.shared.invalidateCache()
                StorageKeyManager.shared.wipeCache()
                try? FileManager.default.removeItem(at: root)
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try StorageEncryptionPolicy.shared.setDesiredMode(.plaintext)
            StorageKeyManager.shared.wipeCache()
            try await body()
        }
    }
}
