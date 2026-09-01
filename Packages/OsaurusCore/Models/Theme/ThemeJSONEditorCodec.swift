//
//  ThemeJSONEditorCodec.swift
//  osaurus
//
//  Encode/decode helpers for the raw JSON theme editor.
//

import Foundation

enum ThemeJSONEditorError: LocalizedError, Equatable {
    case empty
    case invalidUTF8
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Theme JSON cannot be empty."
        case .invalidUTF8:
            return "Theme JSON must be valid UTF-8 text."
        case .decodeFailed(let message):
            return "Theme JSON is invalid: \(message)"
        }
    }
}

enum ThemeJSONEditorCodec {
    /// Marker used in editor-facing JSON in place of the base64 background
    /// image. The real payload can be megabytes of base64 on a single line,
    /// which TextKit cannot line-break without multi-second main-thread
    /// hangs, and it was never useful to hand-edit anyway.
    static let imageDataPlaceholderPrefix = "<embedded image"

    static func imageDataPlaceholder(byteCount: Int) -> String {
        let size = ByteCountFormatter.string(
            fromByteCount: Int64(byteCount), countStyle: .file)
        return "\(imageDataPlaceholderPrefix): \(size)>"
    }

    /// Encode for display in the raw JSON editor: identical to `encode`,
    /// except the background image payload is replaced with a short
    /// placeholder. `decodePreservingEditorIdentity` splices the real
    /// image back when the placeholder is left untouched.
    static func encodeForEditor(_ theme: CustomTheme) throws -> String {
        var redacted = theme
        if let imageData = redacted.background.imageData, !imageData.isEmpty {
            redacted.background.imageData = imageDataPlaceholder(byteCount: imageData.utf8.count)
        }
        return try encode(redacted)
    }

    static func encode(_ theme: CustomTheme) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(theme)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ThemeJSONEditorError.invalidUTF8
        }
        return json
    }

    static func decode(_ json: String) throws -> CustomTheme {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ThemeJSONEditorError.empty
        }
        guard let data = json.data(using: .utf8) else {
            throw ThemeJSONEditorError.invalidUTF8
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(CustomTheme.self, from: data)
        } catch {
            throw ThemeJSONEditorError.decodeFailed(error.localizedDescription)
        }
    }

    static func decodePreservingEditorIdentity(_ json: String, currentTheme: CustomTheme) throws -> CustomTheme {
        var decoded = try decode(json)
        decoded.metadata.id = currentTheme.metadata.id
        decoded.metadata.createdAt = currentTheme.metadata.createdAt
        decoded.isBuiltIn = currentTheme.isBuiltIn
        if let imageData = decoded.background.imageData,
            imageData.hasPrefix(imageDataPlaceholderPrefix)
        {
            decoded.background.imageData = currentTheme.background.imageData
        }
        return decoded
    }
}
