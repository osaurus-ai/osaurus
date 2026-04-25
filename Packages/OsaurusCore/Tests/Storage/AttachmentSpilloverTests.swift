//
//  AttachmentSpilloverTests.swift
//  osaurusTests
//
//  Verifies that large attachments spill out of the chat-history
//  TEXT column into encrypted blob files, that re-using the same
//  bytes dedups, and that orphaned blobs are GC'd on session delete.
//

import CryptoKit
import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct AttachmentSpilloverTests {

    private static func setUpEnv() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-spill-tests-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        OsaurusPaths.overrideRoot = root

        // Inject a deterministic key so we don't touch the real
        // Keychain. Available only in DEBUG builds.
        StorageKeyManager.shared._setKeyForTesting(
            SymmetricKey(data: Data(repeating: 0x33, count: 32))
        )
        return root
    }

    private static func tearDownEnv(_ root: URL) {
        OsaurusPaths.overrideRoot = nil
        try? FileManager.default.removeItem(at: root)
        StorageKeyManager.shared.wipeCache()
    }

    @Test
    func largeImageIsSpilledToBlobs() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try Self.setUpEnv()
            defer { Self.tearDownEnv(root) }

            let bigBytes = Data(repeating: 0xAB, count: 32 * 1024)
            let attachment = Attachment(kind: .image(bigBytes))
            let result = AttachmentBlobStore.spillIfNeeded([attachment])

            #expect(result.count == 1)
            switch result[0].kind {
            case .imageRef(let hash, let byteCount):
                #expect(byteCount == bigBytes.count)
                let url = AttachmentBlobStore.blobURL(for: hash)
                #expect(FileManager.default.fileExists(atPath: url.path))
                let head = try Data(contentsOf: url).prefix(1)
                #expect(head.first == EncryptedFileStore.version)
            default:
                Issue.record("expected imageRef, got \(result[0].kind)")
            }
        }
    }

    @Test
    func smallImageStaysInline() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try Self.setUpEnv()
            defer { Self.tearDownEnv(root) }

            let small = Data(repeating: 0xCD, count: 100)
            let attachment = Attachment(kind: .image(small))
            let result = AttachmentBlobStore.spillIfNeeded([attachment])

            if case .image = result[0].kind {
                // expected
            } else {
                Issue.record("small image should not spill")
            }
        }
    }

    @Test
    func dedupReusesSameBlob() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try Self.setUpEnv()
            defer { Self.tearDownEnv(root) }

            let bytes = Data(repeating: 0x55, count: 64 * 1024)
            let one = Attachment(kind: .image(bytes))
            let two = Attachment(kind: .image(bytes))
            let spilled = AttachmentBlobStore.spillIfNeeded([one, two])

            let hashes = spilled.compactMap { a -> String? in
                if case .imageRef(let h, _) = a.kind { return h }
                return nil
            }
            #expect(hashes.count == 2)
            #expect(hashes[0] == hashes[1])

            let dir = AttachmentBlobStore.blobsDir()
            let entries = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            #expect(entries.count == 1)
        }
    }

    @Test
    func gcRemovesOrphanedBlobsOnSessionDelete() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try Self.setUpEnv()
            defer { Self.tearDownEnv(root) }

            let db = ChatHistoryDatabase()
            try db.openInMemory()
            defer { db.close() }

            let bytes = Data(repeating: 0xEE, count: 24 * 1024)
            let attachment = Attachment(kind: .image(bytes))
            let session = ChatSessionData(
                id: UUID(),
                title: "Spill",
                createdAt: Date(),
                updatedAt: Date(),
                selectedModel: nil,
                turns: [
                    ChatTurnData(role: .user, content: "see this", attachments: [attachment])
                ],
                agentId: nil,
                source: .chat,
                sourcePluginId: nil,
                externalSessionKey: nil,
                dispatchTaskId: nil
            )
            try db.saveSession(session)

            // Find the hash that ended up persisted.
            let loaded = db.loadSession(id: session.id)
            guard let kind = loaded?.turns.first?.attachments.first?.kind,
                case .imageRef(let hash, _) = kind
            else {
                Issue.record("expected persisted imageRef")
                return
            }
            #expect(AttachmentBlobStore.exists(hash))

            try db.deleteSession(id: session.id)
            #expect(!AttachmentBlobStore.exists(hash))
        }
    }
}
