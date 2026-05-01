//
//  Attachment.swift
//  osaurus
//
//  Unified attachment model for images and documents in chat messages
//

import Foundation

public struct Attachment: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: Kind

    public enum Kind: Codable, Sendable, Equatable {
        case image(Data)
        case document(filename: String, content: String, fileSize: Int)

        /// Audio bytes + format hint (e.g. "wav", "mp3", "m4a", "flac",
        /// "ogg"). Format flows into `MessageContentPart.audioInput.format`
        /// and onto the temp-file extension that drives vmlx's
        /// AVAudioConverter dispatch (`materializeMediaDataUrl`).
        /// Only routed for models whose `ModelMediaCapabilities` advertise
        /// audio support — `FloatingInputCard` rejects audio attachments
        /// for non-audio models at drop time.
        case audio(Data, format: String, filename: String?)

        /// Video bytes. Container format inferred from filename
        /// extension (mp4 / mov / m4v / webm). Routed only for models
        /// advertising video support.
        case video(Data, filename: String?)

        /// Spillover variant: image bytes have been written to
        /// `AttachmentBlobStore` (encrypted) and only a content-address
        /// hash + size live in the chat-history JSON column.
        /// Created by `AttachmentBlobStore.spillIfNeeded`.
        case imageRef(hash: String, byteCount: Int)

        /// Spillover variant: document `content` text has been written
        /// to `AttachmentBlobStore` (encrypted). `fileSize` is the
        /// original on-disk size; `hash` indexes the encrypted blob.
        case documentRef(filename: String, hash: String, fileSize: Int)

        /// Spillover variant: audio bytes spilled to encrypted blob store.
        case audioRef(hash: String, byteCount: Int, format: String, filename: String?)

        /// Spillover variant: video bytes spilled to encrypted blob store.
        case videoRef(hash: String, byteCount: Int, filename: String?)

        private enum CodingKeys: String, CodingKey {
            case type, data, filename, content, fileSize, hash, byteCount, format
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .image(let data):
                try container.encode("image", forKey: .type)
                try container.encode(data, forKey: .data)
            case .document(let filename, let content, let fileSize):
                try container.encode("document", forKey: .type)
                try container.encode(filename, forKey: .filename)
                try container.encode(content, forKey: .content)
                try container.encode(fileSize, forKey: .fileSize)
            case .audio(let data, let format, let filename):
                try container.encode("audio", forKey: .type)
                try container.encode(data, forKey: .data)
                try container.encode(format, forKey: .format)
                try container.encodeIfPresent(filename, forKey: .filename)
            case .video(let data, let filename):
                try container.encode("video", forKey: .type)
                try container.encode(data, forKey: .data)
                try container.encodeIfPresent(filename, forKey: .filename)
            case .imageRef(let hash, let byteCount):
                try container.encode("image_ref", forKey: .type)
                try container.encode(hash, forKey: .hash)
                try container.encode(byteCount, forKey: .byteCount)
            case .documentRef(let filename, let hash, let fileSize):
                try container.encode("document_ref", forKey: .type)
                try container.encode(filename, forKey: .filename)
                try container.encode(hash, forKey: .hash)
                try container.encode(fileSize, forKey: .fileSize)
            case .audioRef(let hash, let byteCount, let format, let filename):
                try container.encode("audio_ref", forKey: .type)
                try container.encode(hash, forKey: .hash)
                try container.encode(byteCount, forKey: .byteCount)
                try container.encode(format, forKey: .format)
                try container.encodeIfPresent(filename, forKey: .filename)
            case .videoRef(let hash, let byteCount, let filename):
                try container.encode("video_ref", forKey: .type)
                try container.encode(hash, forKey: .hash)
                try container.encode(byteCount, forKey: .byteCount)
                try container.encodeIfPresent(filename, forKey: .filename)
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "image":
                let data = try container.decode(Data.self, forKey: .data)
                self = .image(data)
            case "document":
                let filename = try container.decode(String.self, forKey: .filename)
                let content = try container.decode(String.self, forKey: .content)
                let fileSize = try container.decode(Int.self, forKey: .fileSize)
                self = .document(filename: filename, content: content, fileSize: fileSize)
            case "audio":
                let data = try container.decode(Data.self, forKey: .data)
                let format = try container.decode(String.self, forKey: .format)
                let filename = try container.decodeIfPresent(String.self, forKey: .filename)
                self = .audio(data, format: format, filename: filename)
            case "video":
                let data = try container.decode(Data.self, forKey: .data)
                let filename = try container.decodeIfPresent(String.self, forKey: .filename)
                self = .video(data, filename: filename)
            case "image_ref":
                let hash = try container.decode(String.self, forKey: .hash)
                let byteCount = try container.decode(Int.self, forKey: .byteCount)
                self = .imageRef(hash: hash, byteCount: byteCount)
            case "document_ref":
                let filename = try container.decode(String.self, forKey: .filename)
                let hash = try container.decode(String.self, forKey: .hash)
                let fileSize = try container.decode(Int.self, forKey: .fileSize)
                self = .documentRef(filename: filename, hash: hash, fileSize: fileSize)
            case "audio_ref":
                let hash = try container.decode(String.self, forKey: .hash)
                let byteCount = try container.decode(Int.self, forKey: .byteCount)
                let format = try container.decode(String.self, forKey: .format)
                let filename = try container.decodeIfPresent(String.self, forKey: .filename)
                self = .audioRef(hash: hash, byteCount: byteCount, format: format, filename: filename)
            case "video_ref":
                let hash = try container.decode(String.self, forKey: .hash)
                let byteCount = try container.decode(Int.self, forKey: .byteCount)
                let filename = try container.decodeIfPresent(String.self, forKey: .filename)
                self = .videoRef(hash: hash, byteCount: byteCount, filename: filename)
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown attachment type: \(type)"
                )
            }
        }
    }

    public init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }

    // MARK: - Factory Methods

    public static func image(_ data: Data) -> Attachment {
        Attachment(kind: .image(data))
    }

    public static func document(filename: String, content: String, fileSize: Int) -> Attachment {
        Attachment(kind: .document(filename: filename, content: content, fileSize: fileSize))
    }

    public static func audio(_ data: Data, format: String, filename: String? = nil) -> Attachment {
        Attachment(kind: .audio(data, format: format, filename: filename))
    }

    public static func video(_ data: Data, filename: String? = nil) -> Attachment {
        Attachment(kind: .video(data, filename: filename))
    }

    // MARK: - Queries

    public var isImage: Bool {
        switch kind {
        case .image, .imageRef: return true
        default: return false
        }
    }

    public var isDocument: Bool {
        switch kind {
        case .document, .documentRef: return true
        default: return false
        }
    }

    public var isAudio: Bool {
        switch kind {
        case .audio, .audioRef: return true
        default: return false
        }
    }

    public var isVideo: Bool {
        switch kind {
        case .video, .videoRef: return true
        default: return false
        }
    }

    /// Returns inline image bytes if present. For `imageRef` variants
    /// you must hydrate via `AttachmentBlobStore.read(hash)`. Use
    /// `loadImageData()` for a unified accessor that lazily resolves
    /// either case.
    public var imageData: Data? {
        if case .image(let data) = kind { return data }
        return nil
    }

    public var filename: String? {
        switch kind {
        case .document(let name, _, _), .documentRef(let name, _, _):
            return name
        case .audio(_, _, let name), .audioRef(_, _, _, let name),
             .video(_, let name), .videoRef(_, _, let name):
            return name
        default:
            return nil
        }
    }

    /// Audio format hint ("wav" / "mp3" / "m4a" / etc.). The host uses
    /// this both for display and to populate `MessageContentPart.audioInput.format`,
    /// which becomes the temp-file extension that drives vmlx's
    /// AVAudioConverter dispatch (`materializeMediaDataUrl`'s audio
    /// canonicalization table — see PR #967 audit-fix).
    public var audioFormat: String? {
        switch kind {
        case .audio(_, let format, _), .audioRef(_, _, let format, _):
            return format
        default:
            return nil
        }
    }

    public var documentContent: String? {
        if case .document(_, let content, _) = kind { return content }
        return nil
    }

    /// Resolves the attachment to its raw image bytes — inline or
    /// hydrated from the blob store. Returns `nil` for non-image kinds
    /// or read failures.
    public func loadImageData() -> Data? {
        switch kind {
        case .image(let data):
            return data
        case .imageRef(let hash, _):
            return try? AttachmentBlobStore.read(hash)
        default:
            return nil
        }
    }

    /// Resolves the attachment to its raw audio bytes — inline or
    /// hydrated from the encrypted blob store. Returns `nil` for non-audio
    /// kinds or read failures.
    ///
    /// Memory note: audio attachments are eligible for spillover via
    /// `AttachmentBlobStore.spillIfNeeded` so chat-history JSON columns
    /// don't bloat with raw PCM. A 30-second wav at 16 kHz mono is
    /// ~960 KB inline; spillover writes the bytes to an encrypted blob
    /// keyed by content-hash and persists only the hash inline.
    public func loadAudioData() -> Data? {
        switch kind {
        case .audio(let data, _, _):
            return data
        case .audioRef(let hash, _, _, _):
            return try? AttachmentBlobStore.read(hash)
        default:
            return nil
        }
    }

    /// Resolves the attachment to its raw video bytes — inline or
    /// hydrated from the encrypted blob store.
    ///
    /// Memory note: video attachments are heavyweight — even a 1-min mp4
    /// is typically ~30 MB. Always use spillover (`AttachmentBlobStore.
    /// spillIfNeeded`) for video; never inline more than a frame
    /// thumbnail in chat-history JSON.
    public func loadVideoData() -> Data? {
        switch kind {
        case .video(let data, _):
            return data
        case .videoRef(let hash, _, _):
            return try? AttachmentBlobStore.read(hash)
        default:
            return nil
        }
    }

    /// Resolves the attachment to its document content text — inline or
    /// hydrated from the blob store. Returns `nil` for non-document
    /// kinds or read failures.
    public func loadDocumentContent() -> String? {
        switch kind {
        case .document(_, let content, _):
            return content
        case .documentRef(_, let hash, _):
            return (try? AttachmentBlobStore.read(hash)).flatMap { String(data: $0, encoding: .utf8) }
        default:
            return nil
        }
    }

    // MARK: - Display Helpers

    public var fileSizeFormatted: String? {
        switch kind {
        case .document(_, _, let size), .documentRef(_, _, let size):
            return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        case .audio(let data, _, _):
            return ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        case .video(let data, _):
            return ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        case .audioRef(_, let byteCount, _, _), .videoRef(_, let byteCount, _):
            return ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        default:
            return nil
        }
    }

    public var fileExtension: String? {
        guard let name = filename else { return nil }
        return (name as NSString).pathExtension.lowercased()
    }

    public var fileIcon: String {
        if isAudio { return "waveform" }
        if isVideo { return "film" }
        guard let ext = fileExtension else { return "photo" }
        switch ext {
        case "pdf": return "doc.richtext"
        case "docx", "doc": return "doc.text"
        case "md", "markdown": return "text.document"
        case "csv": return "tablecells"
        case "json": return "curlybraces"
        case "xml", "html", "htm": return "chevron.left.forwardslash.chevron.right"
        case "rtf": return "doc.richtext"
        default: return "doc.plaintext"
        }
    }

    /// Estimated token count for context budget calculations.
    ///
    /// Empirical baselines from OmniBench / vmlx:
    /// - Image: ~256 vision tokens/frame after spatial-merge 2×2
    /// - Audio: Parakeet emits ~50 acoustic tokens/sec at 16 kHz mono,
    ///   so 1 byte ≈ (1 sec / 32k bytes) × 50 = ~0.0016 tokens/byte
    /// - Video: ~256 vision tokens × frame_count, where vmlx samples
    ///   8 frames default → ~2K vision tokens/clip regardless of duration
    ///
    /// These are approximations for budget gating. The real token count
    /// is determined by the model's processor at decode time.
    public var estimatedTokens: Int {
        switch kind {
        case .image(let data):
            return max(1, (data.count * 4) / 3 / 4)
        case .imageRef(_, let byteCount):
            return max(1, (byteCount * 4) / 3 / 4)
        case .document(_, let content, _):
            return max(1, content.count / 4)
        case .documentRef(_, _, let fileSize):
            return max(1, fileSize / 4)
        case .audio(let data, _, _):
            // ~50 acoustic tokens/sec @ 16kHz mono → ~1 token / 640 bytes
            return max(1, data.count / 640)
        case .audioRef(_, let byteCount, _, _):
            return max(1, byteCount / 640)
        case .video, .videoRef:
            // Bounded ~2K tokens regardless of file size (8 frames × 256 tokens)
            return 2048
        }
    }

    // MARK: - Spillover hooks (memory + disk-cache integration)

    /// Threshold above which inline payloads SHOULD spill to encrypted
    /// blob storage. Mirrors the existing image-spill policy and keeps
    /// chat-history JSON columns bounded.
    ///
    /// Audio threshold is lower (256 KB) because chat-history is read
    /// often and a single 5-min wav (~9.6 MB) read on every history
    /// open would tax the SQLite page cache.
    ///
    /// Video threshold is even lower (64 KB) — virtually all real video
    /// attachments will spill. The inline path exists only for
    /// in-memory request lifetimes; persistence always goes via
    /// `AttachmentBlobStore.spillIfNeeded`.
    public static let audioSpillThresholdBytes = 256 * 1024
    public static let videoSpillThresholdBytes = 64 * 1024
}

// MARK: - Array Helpers

extension Array where Element == Attachment {
    /// Inline image bytes only. For spilled `imageRef` attachments use
    /// `loadImages()` to hydrate from the blob store.
    public var images: [Data] {
        compactMap(\.imageData)
    }

    /// Resolve every image attachment (inline + spilled) into its raw
    /// bytes. Performs blocking disk reads for spilled blobs — call
    /// off the main thread for chats with many attachments.
    public func loadImages() -> [Data] {
        compactMap { $0.loadImageData() }
    }

    public var documents: [Attachment] {
        filter(\.isDocument)
    }

    public var audios: [Attachment] {
        filter(\.isAudio)
    }

    public var videos: [Attachment] {
        filter(\.isVideo)
    }

    public var hasImages: Bool {
        contains(where: \.isImage)
    }

    public var hasDocuments: Bool {
        contains(where: \.isDocument)
    }

    public var hasAudios: Bool {
        contains(where: \.isAudio)
    }

    public var hasVideos: Bool {
        contains(where: \.isVideo)
    }
}
