//
//  DocumentParser.swift
//  osaurus
//
//  Compatibility facade over the registry-backed file import service.
//

import Foundation
import UniformTypeIdentifiers

enum DocumentParser {
    typealias ParseError = FileImportError

    static let maxParsedTextLength = FileImportService.maxParsedTextLength

    // MARK: - Public API

    static func parse(url: URL) async throws -> Attachment {
        try await FileImportService.parse(url: url)
    }

    /// Parse a file into one or more attachments.
    /// PDFs with no extractable text are rendered as page images (one per page).
    static func parseAll(url: URL) async throws -> [Attachment] {
        try await FileImportService.parseAll(url: url)
    }

    static func canParse(url: URL) -> Bool {
        FileImportService.canImport(url: url)
    }

    static func isImageFile(url: URL) -> Bool {
        guard let utType = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return utType.conforms(to: .image)
    }

    static var supportedDocumentTypes: [UTType] {
        FileImportService.supportedDocumentTypes
    }
}
