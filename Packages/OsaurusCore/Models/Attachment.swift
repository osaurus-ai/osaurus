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

        private enum CodingKeys: String, CodingKey {
            case type, data, filename, content, fileSize
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
        if case .image = kind { return true }
        return false
    }

    public var isDocument: Bool {
        if case .document = kind { return true }
        return false
    }

    public var imageData: Data? {
        if case .image(let data) = kind { return data }
        return nil
    }

    public var filename: String? {
        if case .document(let name, _, _) = kind { return name }
        return nil
    }

    public var documentContent: String? {
        if case .document(_, let content, _) = kind { return content }
        return nil
    }

    // MARK: - Display Helpers

    public var fileSizeFormatted: String? {
        if case .document(_, _, let size) = kind {
            return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
        return nil
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
        case .document(_, let content, _):
            return max(1, content.count / 4)
        }
    }
}

// MARK: - Array Helpers

extension Array where Element == Attachment {
    public var images: [Data] {
        compactMap(\.imageData)
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
