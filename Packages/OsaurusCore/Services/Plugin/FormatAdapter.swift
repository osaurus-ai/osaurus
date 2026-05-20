//
//  FormatAdapter.swift
//  osaurus
//
//  In-process v1 surface for plugin-provided format readers. The protocol
//  intentionally stays record-oriented so plugin packs can add new tabular or
//  domain formats without inheriting the richer core `StructuredDocument`
//  pipeline before they need it.
//

import Foundation

/// A contained document identity that plugins can safely cite without
/// retaining or exposing the physical source path.
public struct DocumentReference: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let formatIdentifier: String
    public let displayName: String
    public let fileSize: Int64
    public let openedAt: Date
    public let metadata: [String: String]

    public init(
        id: UUID = UUID(),
        formatIdentifier: String,
        displayName: String,
        fileSize: Int64,
        openedAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        precondition(fileSize >= 0, "DocumentReference fileSize must be non-negative")
        self.id = id
        self.formatIdentifier = formatIdentifier
        self.displayName = displayName
        self.fileSize = fileSize
        self.openedAt = openedAt
        self.metadata = metadata
    }
}

/// A streamed plugin record keeps row-like data generic enough for domain
/// packs while preserving a text form for indexing and retrieval fallbacks.
public struct Record: Codable, Equatable, Hashable, Sendable {
    public let index: Int
    public let fields: [String]
    public let text: String
    public let anchorIdentifier: String?
    public let metadata: [String: String]

    public init(
        index: Int,
        fields: [String],
        text: String? = nil,
        anchorIdentifier: String? = nil,
        metadata: [String: String] = [:]
    ) {
        precondition(index >= 0, "Record index must be non-negative")
        self.index = index
        self.fields = fields
        self.text = text ?? fields.joined(separator: "\t")
        self.anchorIdentifier = anchorIdentifier
        self.metadata = metadata
    }
}

/// Adapter errors stay path-free so plugin-facing failures can cross logging
/// and tool boundaries without exposing user-selected filesystem locations.
public enum FormatAdapterError: LocalizedError, Equatable, Sendable {
    case unsupportedURL(formatIdentifier: String, pathExtension: String)
    case documentNotOpened(formatIdentifier: String)
    case representationMismatch(formatIdentifier: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedURL(let formatIdentifier, let pathExtension):
            return "Format adapter '\(formatIdentifier)' cannot open extension '\(pathExtension)'"
        case .documentNotOpened(let formatIdentifier):
            return "Format adapter '\(formatIdentifier)' has no opened document"
        case .representationMismatch(let formatIdentifier):
            return "Format adapter '\(formatIdentifier)' produced an unexpected representation"
        }
    }
}

/// Plugin format adapters use this small surface so future packs can stream
/// domain records without depending on core document internals.
public protocol FormatAdapter: Sendable {
    /// Stable plugin ABI key. This is static so a registry can reject
    /// duplicate plugin registrations before constructing parser state.
    static var formatIdentifier: String { get }

    /// Leading-byte signatures for cheap detection. Text formats that do not
    /// have reliable magic bytes should return an empty list and let callers
    /// choose them by extension, MIME type, or explicit user intent.
    static var detectionBytePatterns: [Data] { get }

    /// Opens a contained host URL and returns a path-free reference that can
    /// be recorded in logs, tests, or later indexing metadata.
    func openDocument(at url: URL) throws -> DocumentReference

    /// Streams format-native records after `openDocument(at:)` succeeds.
    /// The continuation is explicit so callers decide whether to bridge into
    /// `AsyncStream`, tool output, or a future back-pressured record sink.
    func streamRecords(into continuation: AsyncStream<Record>.Continuation) async throws
}
