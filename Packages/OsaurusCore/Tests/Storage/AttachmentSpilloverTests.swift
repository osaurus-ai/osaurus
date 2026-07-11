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

    private static func expectReadError(
        hash: String,
        maximumBytes: Int = AttachmentBlobStore.maximumVideoBytes,
        expectedByteCount: Int? = nil,
        matching predicate: (AttachmentBlobError) -> Bool
    ) {
        do {
            _ = try AttachmentBlobStore.read(
                hash,
                maximumBytes: maximumBytes,
                expectedByteCount: expectedByteCount
            )
            Issue.record("expected attachment blob read to fail")
        } catch let error as AttachmentBlobError {
            #expect(predicate(error))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    private static func setUpEnv() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-spill-tests-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        OsaurusPaths.overrideRoot = root

        // These tests verify the SQLCipher/`.osec` spillover path, so opt in to
        // encrypted at-rest mode and inject a deterministic key (DEBUG-only) so
        // we don't touch the real Keychain.
        try StorageEncryptionPolicy.shared.setDesiredMode(.encrypted)
        StorageKeyManager.shared._setKeyForTesting(
            SymmetricKey(data: Data(repeating: 0x33, count: 32))
        )
        return root
    }

    private static func tearDownEnv(_ root: URL) {
        OsaurusPaths.overrideRoot = nil
        try? FileManager.default.removeItem(at: root)
        StorageKeyManager.shared.wipeCache()
        StorageEncryptionPolicy.shared.invalidateCache()
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
                let url = try AttachmentBlobStore.blobURL(for: hash)
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
    func structuredDocumentMetadataSurvivesEncryptedSpillover() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try Self.setUpEnv()
            defer { Self.tearDownEnv(root) }

            let body = String(repeating: "cell,", count: 8 * 1024)
            let document = StructuredDocument(
                formatId: "csv",
                filename: "large.csv",
                fileSize: Int64(body.utf8.count),
                representation: AnyStructuredRepresentation(
                    formatId: "csv",
                    underlying: PlainTextRepresentation(text: body)
                ),
                textFallback: body,
                createdAt: Date(timeIntervalSince1970: 1_783_939_200)
            )
            let result = AttachmentBlobStore.spillIfNeeded([.structuredDocument(document)])

            #expect(result.count == 1)
            switch result[0].kind {
            case .documentRef(let filename, let hash, let fileSize):
                #expect(filename == "large.csv")
                #expect(fileSize == body.utf8.count)
                #expect(result[0].structuredDocumentMetadata == StructuredDocumentAttachmentMetadata(document))
                #expect(result[0].loadDocumentContent() == body)

                let url = try AttachmentBlobStore.blobURL(for: hash)
                let encrypted = try Data(contentsOf: url)
                #expect(encrypted.first == EncryptedFileStore.version)

                let entries = try FileManager.default.contentsOfDirectory(
                    at: AttachmentBlobStore.blobsDir(),
                    includingPropertiesForKeys: nil
                )
                #expect(entries.count == 1)
                #expect(entries.allSatisfy { $0.pathExtension == "osec" })
                #expect(
                    !FileManager.default.fileExists(
                        atPath: AttachmentBlobStore.blobsDir().appendingPathComponent("large.csv").path
                    )
                )
            default:
                Issue.record("expected documentRef, got \(result[0].kind)")
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
    func readRejectsTraversalNonHexAndWrongLengthBeforePathResolution() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try Self.setUpEnv()
            defer { Self.tearDownEnv(root) }

            for invalid in ["../history.sqlite", String(repeating: "g", count: 64), String(repeating: "a", count: 63)] {
                Self.expectReadError(hash: invalid) {
                    if case .invalidReference = $0 { return true }
                    return false
                }
            }

            #expect(!AttachmentBlobStore.exists("../history.sqlite"))
        }
    }

    @Test
    func readRejectsSymbolicLinkEvenWhenTargetBytesMatchHash() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try Self.setUpEnv()
            defer { Self.tearDownEnv(root) }

            let bytes = Data("outside secret".utf8)
            let hash = AttachmentBlobStore.contentHash(bytes)
            let outside = root.appendingPathComponent("outside-secret")
            try bytes.write(to: outside)
            let logical = try AttachmentBlobStore.logicalBlobURL(for: hash)
            try FileManager.default.createDirectory(
                at: logical.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(at: logical, withDestinationURL: outside)

            Self.expectReadError(hash: hash) {
                if case .symbolicLink = $0 { return true }
                return false
            }
        }
    }

    @Test
    func readRejectsOversizedBlobBeforeLoadingIt() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try Self.setUpEnv()
            defer { Self.tearDownEnv(root) }

            let bytes = Data(repeating: 0xA5, count: 32)
            let hash = AttachmentBlobStore.contentHash(bytes)
            let logical = try AttachmentBlobStore.logicalBlobURL(for: hash)
            try FileManager.default.createDirectory(
                at: logical.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try bytes.write(to: logical)

            Self.expectReadError(hash: hash, maximumBytes: 16) {
                if case .oversized(16) = $0 { return true }
                return false
            }
        }
    }

    @Test
    func readRejectsHashAndDeclaredSizeMismatches() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try Self.setUpEnv()
            defer { Self.tearDownEnv(root) }

            let expected = Data("expected".utf8)
            let hash = AttachmentBlobStore.contentHash(expected)
            let logical = try AttachmentBlobStore.logicalBlobURL(for: hash)
            try FileManager.default.createDirectory(
                at: logical.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("tampered".utf8).write(to: logical)

            Self.expectReadError(hash: hash) {
                if case .integrityMismatch = $0 { return true }
                return false
            }

            let sizeChecked = Data("size checked".utf8)
            let validHash = try AttachmentBlobStore.write(sizeChecked)
            Self.expectReadError(hash: validHash, expectedByteCount: expected.count + 1) {
                if case .sizeMismatch(let declared, let actual) = $0 {
                    return declared == expected.count + 1 && actual == sizeChecked.count
                }
                return false
            }
        }
    }

    @Test
    func attachmentLoadersDoNotCrossHydrateKinds() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try Self.setUpEnv()
            defer { Self.tearDownEnv(root) }

            let bytes = Data("plain document".utf8)
            let hash = try AttachmentBlobStore.write(bytes)
            let document = Attachment(
                kind: .documentRef(filename: "notes.txt", hash: hash, fileSize: bytes.count)
            )
            let image = Attachment(kind: .imageRef(hash: hash, byteCount: bytes.count + 1))

            #expect(document.loadDocumentContent() == "plain document")
            #expect(document.loadImageData() == nil)
            #expect(image.loadDocumentContent() == nil)
            #expect(image.loadImageData() == nil)
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
