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
import Darwin
import Foundation
import os

public enum AttachmentBlobError: LocalizedError {
    case writeFailed(String)
    case readFailed(String)
    case invalidReference
    case symbolicLink
    case oversized(Int)
    case sizeMismatch(expected: Int, actual: Int)
    case integrityMismatch

    public var errorDescription: String? {
        switch self {
        case .writeFailed(let m): return "Failed to write attachment blob: \(m)"
        case .readFailed(let m): return "Failed to read attachment blob: \(m)"
        case .invalidReference: return "Attachment blob reference is invalid."
        case .symbolicLink: return "Attachment blob references may not resolve through a symbolic link."
        case .oversized(let limit): return "Attachment blob exceeds the \(limit)-byte read limit."
        case .sizeMismatch(let expected, let actual):
            return "Attachment blob size mismatch (expected \(expected), found \(actual))."
        case .integrityMismatch: return "Attachment blob content does not match its reference."
        }
    }
}

public enum AttachmentBlobStore {
    /// Bytes above which we spill image data or document content out of
    /// the JSON-in-TEXT column into a separate encrypted blob file.
    /// 16 KB chosen to keep tiny inline icons / short snippets fast and
    /// to spill almost every screenshot or non-trivial document.
    public static let spillThreshold: Int = 16 * 1024
    public static let maximumDocumentBytes = 64 * 1024 * 1024
    public static let maximumImageBytes = 128 * 1024 * 1024
    public static let maximumAudioBytes = 256 * 1024 * 1024
    public static let maximumVideoBytes = 512 * 1024 * 1024

    private static let log = Logger(subsystem: "ai.osaurus", category: "storage.blobs")

    // MARK: - Disk layout

    /// `~/.osaurus/chat-history/blobs/`
    public static func blobsDir() -> URL {
        OsaurusPaths.chatHistory().appendingPathComponent("blobs", isDirectory: true)
    }

    /// Logical (plaintext) blob path `~/.osaurus/chat-history/blobs/<sha256>`.
    /// In plaintext mode the bytes live here; in encrypted mode the `.osec`
    /// twin (`blobURL(for:)`) holds the AES-GCM envelope instead.
    public static func logicalBlobURL(for sha256: String) throws -> URL {
        try validatedLogicalBlobURL(for: sha256)
    }

    /// Encrypted blob twin `~/.osaurus/chat-history/blobs/<sha256>.osec`.
    public static func blobURL(for sha256: String) throws -> URL {
        try EncryptedFileStore.encryptedURL(for: validatedLogicalBlobURL(for: sha256))
    }

    public static func isValidContentHash(_ hash: String) -> Bool {
        hash.count == 64 && hash.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        }
    }

    private static func validatedLogicalBlobURL(for hash: String) throws -> URL {
        guard isValidContentHash(hash) else { throw AttachmentBlobError.invalidReference }
        let root = blobsDir().standardizedFileURL
        let candidate = root.appendingPathComponent(hash, isDirectory: false).standardizedFileURL
        guard candidate.deletingLastPathComponent().path == root.path else {
            throw AttachmentBlobError.invalidReference
        }
        return candidate
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
        if exists(hash) {
            return hash
        }
        do {
            // Honors the at-rest policy: plaintext bytes by default, AES-GCM
            // `.osec` twin when encryption is enabled.
            try EncryptedFileStore.writePolicyAware(data, toPlaintextURL: logicalBlobURL(for: hash))
        } catch {
            throw AttachmentBlobError.writeFailed(error.localizedDescription)
        }
        return hash
    }

    /// Read the blob with the given content hash (detection-first: plaintext
    /// twin preferred, `.osec` decrypted otherwise).
    public static func read(
        _ hash: String,
        maximumBytes: Int = maximumVideoBytes,
        expectedByteCount: Int? = nil
    ) throws -> Data {
        do {
            guard maximumBytes >= 0, maximumBytes <= maximumVideoBytes else {
                throw AttachmentBlobError.oversized(maximumVideoBytes)
            }
            if let expectedByteCount {
                guard expectedByteCount >= 0 else { throw AttachmentBlobError.invalidReference }
                guard expectedByteCount <= maximumBytes else { throw AttachmentBlobError.oversized(maximumBytes) }
            }

            let logicalURL = try validatedLogicalBlobURL(for: hash)
            guard let existingURL = EncryptedFileStore.existingTwin(forPlaintextURL: logicalURL) else {
                throw EncryptedFileStoreError.fileMissing
            }
            let isEncrypted = try validateExistingBlobURL(
                existingURL,
                logicalURL: logicalURL,
                maximumBytes: maximumBytes
            )
            let storedLimit = maximumBytes + (isEncrypted ? 29 : 0)
            let stored = try boundedRead(existingURL, maximumBytes: storedLimit)
            let data = isEncrypted ? try EncryptedFileStore.open(envelope: stored) : stored
            guard data.count <= maximumBytes else { throw AttachmentBlobError.oversized(maximumBytes) }
            if let expectedByteCount, data.count != expectedByteCount {
                throw AttachmentBlobError.sizeMismatch(expected: expectedByteCount, actual: data.count)
            }
            guard contentHash(data) == hash else { throw AttachmentBlobError.integrityMismatch }
            return data
        } catch let error as AttachmentBlobError {
            throw error
        } catch {
            throw AttachmentBlobError.readFailed(error.localizedDescription)
        }
    }

    private static func validateExistingBlobURL(
        _ existingURL: URL,
        logicalURL: URL,
        maximumBytes: Int
    ) throws -> Bool {
        let values = try existingURL.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true else { throw AttachmentBlobError.symbolicLink }

        let root = blobsDir().resolvingSymlinksInPath().standardizedFileURL
        let resolvedParent = existingURL.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL
        guard resolvedParent.path == root.path else { throw AttachmentBlobError.invalidReference }

        let encrypted = existingURL.pathExtension == String(EncryptedFileStore.suffix.dropFirst())
        let envelopeOverhead = encrypted ? 29 : 0
        guard let fileSize = values.fileSize, fileSize <= maximumBytes + envelopeOverhead else {
            throw AttachmentBlobError.oversized(maximumBytes)
        }

        let expectedPlain = logicalURL.standardizedFileURL
        let expectedEncrypted = EncryptedFileStore.encryptedURL(for: expectedPlain).standardizedFileURL
        let actual = existingURL.standardizedFileURL
        guard actual == expectedPlain || actual == expectedEncrypted else {
            throw AttachmentBlobError.invalidReference
        }
        return encrypted
    }

    private static func boundedRead(_ url: URL, maximumBytes: Int) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw AttachmentBlobError.symbolicLink }
            throw AttachmentBlobError.readFailed(String(cString: strerror(errno)))
        }
        var statBuffer = stat()
        guard fstat(descriptor, &statBuffer) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw AttachmentBlobError.readFailed(message)
        }
        guard (statBuffer.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            throw AttachmentBlobError.invalidReference
        }
        guard statBuffer.st_size <= off_t(maximumBytes) else {
            Darwin.close(descriptor)
            throw AttachmentBlobError.oversized(maximumBytes)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw AttachmentBlobError.oversized(maximumBytes) }
        return data
    }

    /// Returns true when a blob with this hash exists on disk (either twin).
    public static func exists(_ hash: String) -> Bool {
        guard let url = try? validatedLogicalBlobURL(for: hash) else { return false }
        return EncryptedFileStore.existingTwin(forPlaintextURL: url) != nil
    }

    /// Delete a blob. Caller is responsible for ensuring no other turn
    /// references it.
    public static func delete(_ hash: String) {
        guard let url = try? validatedLogicalBlobURL(for: hash) else { return }
        EncryptedFileStore.removeTwins(forPlaintextURL: url)
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
                    kind: .imageRef(hash: hash, byteCount: data.count),
                    structuredDocumentMetadata: attachment.structuredDocumentMetadata
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
                    kind: .documentRef(filename: filename, hash: hash, fileSize: fileSize),
                    structuredDocumentMetadata: attachment.structuredDocumentMetadata
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
                        hash: hash,
                        byteCount: data.count,
                        format: format,
                        filename: filename
                    )
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
                        hash: hash,
                        byteCount: data.count,
                        filename: filename
                    )
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
