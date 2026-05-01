//
//  AttachmentBlobStore.swift
//  osaurus
//
//  Content-addressed encrypted blob storage for chat attachments that
//  would otherwise bloat `chat-history/history.sqlite`.
//
//  Until now, every `Attachment.image(Data)` and large
//  `Attachment.document(content:)` was JSON-encoded directly into the
//  `turns.attachments` TEXT column (see `ChatHistoryDatabase.bindTurn`,
//  lines 543–545). Sessions with screenshots and PDFs ballooned the DB
//  file, slowed full-session loads, and forced every save to rewrite
//  every attachment byte.
//
//  Now: we spill any image or document payload above
//  `Self.spillThreshold` to `~/.osaurus/chat-history/blobs/<sha256>.osec`,
//  AES-GCM encrypted with the same `StorageKeyManager` key SQLCipher
//  uses for the DB. SQLite stores only `{ "ref": "<sha256>", ... }`.
//
//  Content-addressed = same image attached to multiple turns lives in
//  one blob on disk. GC happens when sessions are deleted (see
//  `ChatHistoryDatabase.deleteSession` for the hook).
//

import CryptoKit
import Foundation
import os

public enum AttachmentBlobError: LocalizedError {
    case writeFailed(String)
    case readFailed(String)

    public var errorDescription: String? {
        switch self {
        case .writeFailed(let m): return "Failed to write attachment blob: \(m)"
        case .readFailed(let m): return "Failed to read attachment blob: \(m)"
        }
    }
}

public enum AttachmentBlobStore {
    /// Bytes above which we spill image data or document content out of
    /// the JSON-in-TEXT column into a separate encrypted blob file.
    /// 16 KB chosen to keep tiny inline icons / short snippets fast and
    /// to spill almost every screenshot or non-trivial document.
    public static let spillThreshold: Int = 16 * 1024

    private static let log = Logger(subsystem: "ai.osaurus", category: "storage.blobs")

    // MARK: - Disk layout

    /// `~/.osaurus/chat-history/blobs/`
    public static func blobsDir() -> URL {
        OsaurusPaths.chatHistory().appendingPathComponent("blobs", isDirectory: true)
    }

    /// `~/.osaurus/chat-history/blobs/<sha256>.osec`
    public static func blobURL(for sha256: String) -> URL {
        blobsDir().appendingPathComponent("\(sha256).osec")
    }

    // MARK: - Hashing

    /// Lowercase hex SHA-256 of `data`. Used as a content-address for
    /// dedup and as the on-disk filename.
    public static func contentHash(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// String overload — reads bytes from UTF-8.
    public static func contentHash(string: String) -> String {
        contentHash(Data(string.utf8))
    }

    // MARK: - Write / read

    /// Encrypt-and-write `data`, return its content hash. Idempotent —
    /// existing files with the same hash are not rewritten.
    @discardableResult
    public static func write(_ data: Data) throws -> String {
        let hash = contentHash(data)
        let url = blobURL(for: hash)
        if FileManager.default.fileExists(atPath: url.path) {
            return hash
        }
        do {
            try EncryptedFileStore.write(data, to: url)
        } catch {
            throw AttachmentBlobError.writeFailed(error.localizedDescription)
        }
        return hash
    }

    /// Read and decrypt the blob with the given content hash.
    public static func read(_ hash: String) throws -> Data {
        let url = blobURL(for: hash)
        do {
            return try EncryptedFileStore.read(url)
        } catch {
            throw AttachmentBlobError.readFailed(error.localizedDescription)
        }
    }

    /// Returns true when a blob with this hash exists on disk.
    public static func exists(_ hash: String) -> Bool {
        FileManager.default.fileExists(atPath: blobURL(for: hash).path)
    }

    /// Delete a blob. Caller is responsible for ensuring no other turn
    /// references it.
    public static func delete(_ hash: String) {
        try? FileManager.default.removeItem(at: blobURL(for: hash))
    }

    // MARK: - Spillover for `Attachment` arrays

    /// Walk `attachments` and spill any image bytes / document content
    /// over the threshold to the encrypted blob store. Returns the
    /// transformed array — payloads are replaced with `Spillover` refs
    /// (see `Attachment+Persistence.swift`).
    ///
    /// Safe to call multiple times: already-spilled refs are passed
    /// through unchanged because they don't carry inline bytes.
    public static func spillIfNeeded(_ attachments: [Attachment]) -> [Attachment] {
        attachments.map(spillOne)
    }

    private static func spillOne(_ attachment: Attachment) -> Attachment {
        switch attachment.kind {
        case .image(let data):
            guard data.count >= spillThreshold else { return attachment }
            do {
                let hash = try write(data)
                return Attachment(
                    id: attachment.id,
                    kind: .imageRef(hash: hash, byteCount: data.count)
                )
            } catch {
                log.warning("image spill failed; keeping inline (size=\(data.count)): \(error.localizedDescription)")
                return attachment
            }

        case .document(let filename, let content, let fileSize):
            let bytes = Data(content.utf8)
            guard bytes.count >= spillThreshold else { return attachment }
            do {
                let hash = try write(bytes)
                return Attachment(
                    id: attachment.id,
                    kind: .documentRef(filename: filename, hash: hash, fileSize: fileSize)
                )
            } catch {
                log.warning(
                    "document spill failed; keeping inline (size=\(bytes.count)): \(error.localizedDescription)"
                )
                return attachment
            }

        case .audio(let data, let format, let filename):
            // Audio uses its own threshold (256 KB) so chat-history JSON
            // doesn't bloat with raw PCM. A 30 s wav at 16 kHz mono is
            // ~960 KB → always spills. Tiny clips < 256 KB stay inline.
            guard data.count >= Attachment.audioSpillThresholdBytes else { return attachment }
            do {
                let hash = try write(data)
                return Attachment(
                    id: attachment.id,
                    kind: .audioRef(
                        hash: hash, byteCount: data.count, format: format, filename: filename)
                )
            } catch {
                log.warning(
                    "audio spill failed; keeping inline (size=\(data.count)): \(error.localizedDescription)"
                )
                return attachment
            }

        case .video(let data, let filename):
            // Video uses an aggressive 64 KB threshold — virtually all
            // real attachments spill. Inline path only for in-memory
            // request lifetime; persistence always goes through here.
            guard data.count >= Attachment.videoSpillThresholdBytes else { return attachment }
            do {
                let hash = try write(data)
                return Attachment(
                    id: attachment.id,
                    kind: .videoRef(
                        hash: hash, byteCount: data.count, filename: filename)
                )
            } catch {
                log.warning(
                    "video spill failed; keeping inline (size=\(data.count)): \(error.localizedDescription)"
                )
                return attachment
            }

        case .imageRef, .documentRef, .audioRef, .videoRef:
            return attachment
        }
    }

    // MARK: - GC

    /// Compute the union of every `<hash>` referenced by a session's
    /// turns. Used during session-delete GC to know which blobs are
    /// safe to remove.
    public static func referencedHashes(in turns: [ChatTurnData]) -> Set<String> {
        var refs: Set<String> = []
        for turn in turns {
            for attachment in turn.attachments {
                switch attachment.kind {
                case .imageRef(let hash, _),
                     .documentRef(_, let hash, _),
                     .audioRef(let hash, _, _, _),
                     .videoRef(let hash, _, _):
                    refs.insert(hash)
                default:
                    continue
                }
            }
        }
        return refs
    }
}
