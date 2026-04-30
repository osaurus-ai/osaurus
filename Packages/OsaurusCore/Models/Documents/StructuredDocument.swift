//
//  StructuredDocument.swift
//  osaurus
//
//  Typed parse result that carries both a format-native representation
//  AND a plain-text fallback. The fallback is load-bearing because the
//  existing chat attachment flow consumes
//  `Attachment.Kind.document(content: String, …)`; keeping a text view
//  on every parsed document lets adapters migrate onto the typed surface
//  one at a time without breaking that contract.
//

import Foundation

/// Marker protocol for per-format typed representations (`Workbook`,
/// `WordDocument`, `PDFDocument`, …). Concrete types live next to their
/// adapter under `Packages/OsaurusCore/Models/Documents/<Format>/`.
public protocol StructuredRepresentation: Sendable {}

/// Type-erasing container so a `StructuredDocument` can cross layers
/// (registry, tool surface, artifact pipeline) without leaking the
/// concrete representation type into every caller.
public struct AnyStructuredRepresentation: @unchecked Sendable {
    public let formatId: String
    public let underlying: any StructuredRepresentation

    public init(formatId: String, underlying: any StructuredRepresentation) {
        self.formatId = formatId
        self.underlying = underlying
    }
}

public struct StructuredDocument: @unchecked Sendable {
    public let formatId: String
    public let filename: String
    public let fileSize: Int64
    public let representation: AnyStructuredRepresentation
    public let textFallback: String
    public let createdAt: Date

    public init(
        formatId: String,
        filename: String,
        fileSize: Int64,
        representation: AnyStructuredRepresentation,
        textFallback: String,
        createdAt: Date = Date()
    ) {
        self.formatId = formatId
        self.filename = filename
        self.fileSize = fileSize
        self.representation = representation
        self.textFallback = textFallback
        self.createdAt = createdAt
    }
}
