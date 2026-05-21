//
//  DelimitedText.swift
//  OsaurusStatsPack
//

import Foundation
import OsaurusCore

/// CSV gets its own stats-pack adapter so schema sidecars can enrich records
/// without changing the core CSV adapter's broader document contract.
public struct CSVWithSchemaAdapter: FormatAdapter {
    public static let formatIdentifier = "csv-schema"
    public static let detectionBytePatterns: [Data] = []

    private let state = OpenDocumentState()

    public init() {}

    public func openDocument(at url: URL) throws -> DocumentReference {
        guard url.pathExtension.lowercased() == "csv" else {
            throw FormatAdapterError.unsupportedURL(
                formatIdentifier: Self.formatIdentifier,
                pathExtension: url.pathExtension.lowercased()
            )
        }
        let schema = try CSVSchema.load(for: url)
        let reference = try documentReference(
            url: url,
            formatIdentifier: Self.formatIdentifier,
            metadata: schema?.referenceMetadata ?? ["schemaSidecar": "false"]
        )
        state.update(url: url, reference: reference)
        return reference
    }

    public func streamRecords(into continuation: AsyncStream<Record>.Continuation) async throws {
        defer { continuation.finish() }
        guard let opened = state.openedDocument() else {
            throw FormatAdapterError.documentNotOpened(formatIdentifier: Self.formatIdentifier)
        }
        let schema = try CSVSchema.load(for: opened.url)
        try streamDelimitedRecords(
            at: opened.url,
            delimiter: ",",
            reference: opened.reference,
            extraMetadata: schema?.recordMetadata ?? ["schemaSidecar": "false"],
            into: continuation
        )
    }
}

/// TSV remains separate from CSV because statistics exports often rely on
/// literal tabs and empty cells where CSV quoting rules would be surprising.
public struct TSVStatsAdapter: FormatAdapter {
    public static let formatIdentifier = "tsv"
    public static let detectionBytePatterns: [Data] = []

    private let state = OpenDocumentState()

    public init() {}

    public func openDocument(at url: URL) throws -> DocumentReference {
        guard url.pathExtension.lowercased() == "tsv" else {
            throw FormatAdapterError.unsupportedURL(
                formatIdentifier: Self.formatIdentifier,
                pathExtension: url.pathExtension.lowercased()
            )
        }
        let reference = try documentReference(
            url: url,
            formatIdentifier: Self.formatIdentifier,
            metadata: ["delimiter": "tab"]
        )
        state.update(url: url, reference: reference)
        return reference
    }

    public func streamRecords(into continuation: AsyncStream<Record>.Continuation) async throws {
        defer { continuation.finish() }
        guard let opened = state.openedDocument() else {
            throw FormatAdapterError.documentNotOpened(formatIdentifier: Self.formatIdentifier)
        }
        try streamDelimitedRecords(
            at: opened.url,
            delimiter: "\t",
            reference: opened.reference,
            extraMetadata: ["delimiter": "tab"],
            into: continuation
        )
    }
}

private struct CSVSchema {
    struct Column {
        let name: String
        let type: String?
    }

    let columns: [Column]

    var referenceMetadata: [String: String] {
        var metadata = recordMetadata
        metadata["schemaSidecar"] = "true"
        return metadata
    }

    var recordMetadata: [String: String] {
        var metadata = [
            "schemaColumnNames": columns.map(\.name).joined(separator: "\t")
        ]
        let types = columns.compactMap(\.type)
        if !types.isEmpty {
            metadata["schemaColumnTypes"] = types.joined(separator: "\t")
        }
        return metadata
    }

    static func load(for url: URL) throws -> CSVSchema? {
        guard let sidecar = schemaSidecarURL(for: url) else { return nil }
        let data = try Data(contentsOf: sidecar)
        let root = try JSONSerialization.jsonObject(with: data)
        guard let object = root as? [String: Any], let rawColumns = object["columns"] as? [Any] else {
            throw StatsPackError.invalidSchemaSidecar("expected a top-level columns array")
        }

        let columns = try rawColumns.map { raw -> Column in
            if let name = raw as? String, !name.isEmpty {
                return Column(name: name, type: nil)
            }
            if let object = raw as? [String: Any],
                let name = object["name"] as? String,
                !name.isEmpty
            {
                return Column(name: name, type: object["type"] as? String)
            }
            throw StatsPackError.invalidSchemaSidecar("columns must be names or { name, type } objects")
        }
        guard !columns.isEmpty else {
            throw StatsPackError.invalidSchemaSidecar("columns must not be empty")
        }
        return CSVSchema(columns: columns)
    }

    private static func schemaSidecarURL(for url: URL) -> URL? {
        let candidates = [
            url.deletingPathExtension().appendingPathExtension("csvschema"),
            url.appendingPathExtension("csvschema"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

private func streamDelimitedRecords(
    at url: URL,
    delimiter: Character,
    reference: DocumentReference,
    extraMetadata: [String: String],
    into continuation: AsyncStream<Record>.Continuation
) throws {
    try TextLineReader.forEachLine(at: url) { line, lineNumber in
        let fields = try DelimitedLineParser.parse(line, delimiter: delimiter, lineNumber: lineNumber)
        var metadata = extraMetadata
        metadata["documentId"] = reference.id.uuidString
        metadata["formatIdentifier"] = reference.formatIdentifier
        metadata["lineNumber"] = "\(lineNumber)"
        continuation.yield(
            Record(
                index: lineNumber - 1,
                fields: fields,
                anchorIdentifier: "line/\(lineNumber)",
                metadata: metadata
            )
        )
    }
}

private enum DelimitedLineParser {
    static func parse(_ line: String, delimiter: Character, lineNumber: Int) throws -> [String] {
        var fields: [String] = []
        var field = ""
        var isQuoted = false
        var index = line.startIndex

        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                let nextIndex = line.index(after: index)
                if isQuoted, nextIndex < line.endIndex, line[nextIndex] == "\"" {
                    field.append("\"")
                    index = line.index(after: nextIndex)
                    continue
                }
                isQuoted.toggle()
                index = nextIndex
                continue
            }

            if character == delimiter, !isQuoted {
                fields.append(field)
                field = ""
            } else {
                field.append(character)
            }
            index = line.index(after: index)
        }

        guard !isQuoted else {
            throw StatsPackError.invalidDelimitedLine(line: lineNumber)
        }
        fields.append(field)
        return fields
    }
}

func documentReference(
    url: URL,
    formatIdentifier: String,
    metadata: [String: String]
) throws -> DocumentReference {
    guard (try? url.checkResourceIsReachable()) == true else {
        throw FormatAdapterError.unsupportedURL(
            formatIdentifier: formatIdentifier,
            pathExtension: url.pathExtension.lowercased()
        )
    }
    let fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    return DocumentReference(
        formatIdentifier: formatIdentifier,
        displayName: url.lastPathComponent,
        fileSize: fileSize,
        metadata: metadata
    )
}
