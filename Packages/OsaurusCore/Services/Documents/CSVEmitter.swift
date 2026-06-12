//
//  CSVEmitter.swift
//  osaurus
//
//  Emits typed CSV/TSV documents back to delimited text. This is an explicit
//  document-emitter surface; it is not exposed as a default file-write tool.
//

import Foundation

public struct CSVEmitter: DocumentFormatEmitter {
    public let delimiter: CSVDelimiter
    public let allowFormulaLikeText: Bool

    public var formatId: String { delimiter.formatId }

    public init(delimiter: CSVDelimiter = .comma, allowFormulaLikeText: Bool = false) {
        self.delimiter = delimiter
        self.allowFormulaLikeText = allowFormulaLikeText
    }

    public func canEmit(_ document: StructuredDocument) -> Bool {
        guard let csv = document.representation.underlying as? CSVDocument else { return false }
        return document.formatId == formatId
            || document.representation.formatId == formatId
            || csv.delimiter == delimiter
    }

    public func emit(_ document: StructuredDocument, to url: URL) async throws {
        guard let csv = document.representation.underlying as? CSVDocument else {
            throw DocumentAdapterError.unsupportedFormat(formatId: document.formatId)
        }

        do {
            let data = try Self.data(
                for: csv,
                delimiter: delimiter,
                allowFormulaLikeText: allowFormulaLikeText
            )
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch let error as DocumentAdapterError {
            throw error
        } catch {
            throw DocumentAdapterError.writeFailed(underlying: error.localizedDescription)
        }
    }

    static func data(
        for csv: CSVDocument,
        delimiter: CSVDelimiter,
        allowFormulaLikeText: Bool = false
    ) throws -> Data {
        let lines = try csv.rows.map { row in
            try row.cells.map { cell in
                try encodeField(
                    cell.text,
                    delimiter: delimiter,
                    allowFormulaLikeText: allowFormulaLikeText
                )
            }.joined(separator: delimiter.rawValue)
        }
        guard let data = lines.joined(separator: "\n").data(using: .utf8) else {
            throw DocumentAdapterError.writeFailed(underlying: "CSV output could not be encoded as UTF-8")
        }
        return data
    }

    private static func encodeField(
        _ value: String,
        delimiter: CSVDelimiter,
        allowFormulaLikeText: Bool
    ) throws -> String {
        try validateText(value)
        if !allowFormulaLikeText, isFormulaLike(value) {
            throw DocumentAdapterError.writeFailed(
                underlying: "CSV output contains a spreadsheet formula-like field"
            )
        }
        let needsQuotes =
            value.contains(delimiter.rawValue) || value.contains("\"") || value.contains("\n") || value.contains("\r")
        guard needsQuotes else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func isFormulaLike(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return false }
        if first == "=" || first == "@" { return true }
        if first == "+" || first == "-", Double(trimmed) == nil { return true }
        return false
    }

    private static func validateText(_ value: String) throws {
        for scalar in value.unicodeScalars where !isAllowedTextScalar(scalar) {
            throw DocumentAdapterError.writeFailed(
                underlying: "CSV output contains an unsupported control character"
            )
        }
    }

    private static func isAllowedTextScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x9, 0xA, 0xD:
            return true
        case 0x20 ... 0xD7FF, 0xE000 ... 0xFFFD, 0x10000 ... 0x10FFFF:
            return true
        default:
            return false
        }
    }
}
