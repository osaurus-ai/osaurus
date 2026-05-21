//
//  JSONLAdapter.swift
//  OsaurusStatsPack
//

import Foundation
import OsaurusCore

/// JSONL streams one value at a time so large telemetry or statistics exports
/// can become records without first materializing the whole file in memory.
public struct JSONLAdapter: FormatAdapter {
    public static let formatIdentifier = "jsonl"
    public static let detectionBytePatterns: [Data] = []

    private let state = OpenDocumentState()

    public init() {}

    public func openDocument(at url: URL) throws -> DocumentReference {
        guard url.pathExtension.lowercased() == "jsonl" else {
            throw FormatAdapterError.unsupportedURL(
                formatIdentifier: Self.formatIdentifier,
                pathExtension: url.pathExtension.lowercased()
            )
        }
        let reference = try documentReference(
            url: url,
            formatIdentifier: Self.formatIdentifier,
            metadata: ["encoding": "utf-8"]
        )
        state.update(url: url, reference: reference)
        return reference
    }

    public func streamRecords(into continuation: AsyncStream<Record>.Continuation) async throws {
        defer { continuation.finish() }
        guard let opened = state.openedDocument() else {
            throw FormatAdapterError.documentNotOpened(formatIdentifier: Self.formatIdentifier)
        }

        var recordIndex = 0
        try TextLineReader.forEachLine(at: opened.url) { line, lineNumber in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let value = try Self.parseJSONValue(trimmed, lineNumber: lineNumber)
            let record = try Self.record(
                value: value,
                recordIndex: recordIndex,
                lineNumber: lineNumber,
                reference: opened.reference
            )
            continuation.yield(record)
            recordIndex += 1
        }
    }

    private static func parseJSONValue(_ line: String, lineNumber: Int) throws -> Any {
        guard let data = line.data(using: .utf8) else {
            throw StatsPackError.unreadableUTF8Line(line: lineNumber)
        }
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw StatsPackError.invalidJSONLine(line: lineNumber)
        }
    }

    private static func record(
        value: Any,
        recordIndex: Int,
        lineNumber: Int,
        reference: DocumentReference
    ) throws -> Record {
        let fields: [String]
        var metadata = [
            "documentId": reference.id.uuidString,
            "formatIdentifier": reference.formatIdentifier,
            "lineNumber": "\(lineNumber)",
        ]

        if let object = value as? [String: Any] {
            let keys = object.keys.sorted()
            fields = try keys.map { try fieldString(object[$0] ?? NSNull()) }
            metadata["jsonShape"] = "object"
            metadata["jsonKeys"] = keys.joined(separator: "\t")
        } else if let array = value as? [Any] {
            fields = try array.map(fieldString)
            metadata["jsonShape"] = "array"
        } else {
            fields = [try fieldString(value)]
            metadata["jsonShape"] = "scalar"
        }

        return Record(
            index: recordIndex,
            fields: fields,
            text: try compactText(value),
            anchorIdentifier: "jsonl/lines/\(lineNumber)",
            metadata: metadata
        )
    }

    private static func fieldString(_ value: Any) throws -> String {
        if value is NSNull { return "" }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if JSONSerialization.isValidJSONObject(value) {
            return try compactText(value)
        }
        return "\(value)"
    }

    private static func compactText(_ value: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject(value) else {
            return try fieldString(value)
        }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? ""
    }
}
