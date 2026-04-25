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

        /// Spillover variant: image bytes have been written to
        /// `AttachmentBlobStore` (encrypted) and only a content-address
        /// hash + size live in the chat-history JSON column.
        /// Created by `AttachmentBlobStore.spillIfNeeded`.
        case imageRef(hash: String, byteCount: Int)

        /// Spillover variant: document `content` text has been written
        /// to `AttachmentBlobStore` (encrypted). `fileSize` is the
        /// original on-disk size; `hash` indexes the encrypted blob.
        case documentRef(filename: String, hash: String, fileSize: Int)

        private enum CodingKeys: String, CodingKey {
            case type, data, filename, content, fileSize, hash, byteCount
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
            case .imageRef(let hash, let byteCount):
                try container.encode("image_ref", forKey: .type)
                try container.encode(hash, forKey: .hash)
                try container.encode(byteCount, forKey: .byteCount)
            case .documentRef(let filename, let hash, let fileSize):
                try container.encode("document_ref", forKey: .type)
                try container.encode(filename, forKey: .filename)
                try container.encode(hash, forKey: .hash)
                try container.encode(fileSize, forKey: .fileSize)
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
            case "image_ref":
                let hash = try container.decode(String.self, forKey: .hash)
                let byteCount = try container.decode(Int.self, forKey: .byteCount)
                self = .imageRef(hash: hash, byteCount: byteCount)
            case "document_ref":
                let filename = try container.decode(String.self, forKey: .filename)
                let hash = try container.decode(String.self, forKey: .hash)
                let fileSize = try container.decode(Int.self, forKey: .fileSize)
                self = .documentRef(filename: filename, hash: hash, fileSize: fileSize)
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
        case .document(let name, _, _), .documentRef(let name, _, _): return name
        default: return nil
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
        default:
            return nil
        }
    }

    public var fileExtension: String? {
        guard let name = filename else { return nil }
        return (name as NSString).pathExtension.lowercased()
    }

    public var fileIcon: String {
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

    /// Estimated token count for context budget calculations
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
        }
    }
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

    public var hasImages: Bool {
        contains(where: \.isImage)
    }

    public var hasDocuments: Bool {
        contains(where: \.isDocument)
    }
}
