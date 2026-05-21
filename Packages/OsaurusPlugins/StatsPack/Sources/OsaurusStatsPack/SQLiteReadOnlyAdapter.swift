//
//  SQLiteReadOnlyAdapter.swift
//  OsaurusStatsPack
//

import Foundation
import OsaurusCore

/// SQLite support is intentionally read-only because plugin packs should
/// inspect user databases without mutating files selected for analysis.
public struct SQLiteReadOnlyAdapter: FormatAdapter {
    public static let formatIdentifier = "sqlite"
    public static let detectionBytePatterns = [Data("SQLite format 3\u{0}".utf8)]

    private let state = OpenDocumentState()

    public init() {}

    public func openDocument(at url: URL) throws -> DocumentReference {
        guard Self.supportedExtensions.contains(url.pathExtension.lowercased()) else {
            throw FormatAdapterError.unsupportedURL(
                formatIdentifier: Self.formatIdentifier,
                pathExtension: url.pathExtension.lowercased()
            )
        }
        let reference = try documentReference(
            url: url,
            formatIdentifier: Self.formatIdentifier,
            metadata: ["mode": "read-only"]
        )
        state.update(url: url, reference: reference)
        return reference
    }

    public func streamRecords(into continuation: AsyncStream<Record>.Continuation) async throws {
        defer { continuation.finish() }
        guard let opened = state.openedDocument() else {
            throw FormatAdapterError.documentNotOpened(formatIdentifier: Self.formatIdentifier)
        }
        try await SQLiteReadOnlyRecordStreamer.streamRecords(
            from: opened.url,
            documentReference: opened.reference,
            into: continuation
        )
    }

    private static let supportedExtensions: Set<String> = ["sqlite", "sqlite3", "db"]
}
