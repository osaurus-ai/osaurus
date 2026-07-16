//
//  SearchStructuredDataStore.swift
//  osaurus
//
//  Bounded, session-scoped handoff for structured web data. Large CSV/JSON
//  responses should move tool-to-tool instead of being re-prefilled through
//  the model just so a downstream chart tool can consume the same bytes.
//

import CoreFoundation
import Foundation

struct SearchStructuredDataEntry: Sendable {
    let raw: String
    let format: String
    let sourceURL: String
    let sessionId: String?
}

actor SearchStructuredDataStore {
    static let shared = SearchStructuredDataStore()

    private static let maxEntries = 32
    private static let maxCharactersPerEntry = 1_000_000

    private var entries: [String: SearchStructuredDataEntry] = [:]
    private var insertionOrder: [String] = []
    private var nextReferenceId: UInt64 = 0

    func store(raw: String, format: String, sourceURL: String, sessionId: String?) -> String? {
        guard !raw.isEmpty, raw.count <= Self.maxCharactersPerEntry else { return nil }

        // Keep repeated retrieval of the same source stable within a chat.
        // The live Bonsai route retried a direct CSV after one bad chart call;
        // issuing a new opaque token would make recovery harder and retain a
        // second copy of the same large payload.
        if let existingReference = insertionOrder.first(where: { reference in
            guard let entry = entries[reference] else { return false }
            return entry.sessionId == sessionId && entry.sourceURL == sourceURL
        }) {
            entries[existingReference] = SearchStructuredDataEntry(
                raw: raw,
                format: format,
                sourceURL: sourceURL,
                sessionId: sessionId
            )
            return existingReference
        }

        while insertionOrder.count >= Self.maxEntries, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            entries[oldest] = nil
        }

        // Model-facing references must be easy to copy exactly. Bonsai was
        // observed mutating one UUID three different ways while every content
        // and tool delta streamed normally. Session equality below is the
        // security boundary, so a process-local monotonic ordinal is enough;
        // it is opaque to the model without imposing a 36-character copy task.
        nextReferenceId &+= 1
        if nextReferenceId == 0 { nextReferenceId = 1 }
        let reference = "webdata:\(String(nextReferenceId, radix: 36))"
        entries[reference] = SearchStructuredDataEntry(
            raw: raw,
            format: format,
            sourceURL: sourceURL,
            sessionId: sessionId
        )
        insertionOrder.append(reference)
        return reference
    }

    func load(reference: String, sessionId: String?) -> SearchStructuredDataEntry? {
        guard let entry = entries[reference], entry.sessionId == sessionId else { return nil }
        return entry
    }
}

struct StructuredArrayDescriptor: Sendable, Equatable {
    enum Kind: String, Sendable {
        case number
        case string
        case boolean
        case mixed
    }

    let path: String
    let kind: Kind
    let count: Int
    let first: String?
    let last: String?

    var payload: [String: Any] {
        var value: [String: Any] = [
            "path": path,
            "element_type": kind.rawValue,
            "count": count,
        ]
        if let first { value["first"] = first }
        if let last { value["last"] = last }
        return value
    }
}

struct SuggestedStructuredChart: Sendable, Equatable {
    let xPath: String
    let seriesName: String
    let seriesPath: String

    func toolArguments(dataRef: String, title: String? = nil) -> [String: Any] {
        var arguments: [String: Any] = [
            "dataRef": dataRef,
            "format": "json",
            "chartType": "line",
            "xPath": xPath,
            "seriesPaths": [
                ["name": seriesName, "path": seriesPath]
            ],
        ]
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            arguments["title"] = title
        }
        return arguments
    }
}

enum SearchStructuredDataInspector {
    private static let maxDescriptors = 24
    private static let maxDepth = 10

    static func jsonArrayDescriptors(_ raw: String) -> [StructuredArrayDescriptor] {
        guard let data = raw.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data)
        else { return [] }

        var descriptors: [StructuredArrayDescriptor] = []
        collectArrays(root, path: "", depth: 0, into: &descriptors)
        return descriptors
    }

    static func suggestedJSONChart(
        descriptors: [StructuredArrayDescriptor]
    ) -> SuggestedStructuredChart? {
        let xCandidates = descriptors.filter {
            $0.kind == .number || $0.kind == .string
        }.sorted { xScore($0.path) > xScore($1.path) }
        guard let x = xCandidates.first, xScore(x.path) > 0 else { return nil }

        let yCandidates = descriptors.filter {
            $0.kind == .number && $0.count == x.count && $0.path != x.path
        }.sorted { yScore($0.path) > yScore($1.path) }
        guard let y = yCandidates.first else { return nil }

        return SuggestedStructuredChart(
            xPath: x.path,
            seriesName: displayName(for: y.path),
            seriesPath: y.path
        )
    }

    static func delimitedMetadata(
        _ raw: String,
        separator: Character,
        format: String,
        dataRef: String
    ) -> (columns: [String], rowCount: Int, nextAction: [String: Any]?) {
        let lines = raw.split(whereSeparator: \.isNewline).map(String.init)
        guard let headerLine = lines.first else { return ([], 0, nil) }
        let headers = headerLine.split(separator: separator, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !headers.isEmpty else { return ([], max(0, lines.count - 1), nil) }

        let firstData =
            lines.dropFirst().first?.split(
                separator: separator,
                omittingEmptySubsequences: false
            ).map(String.init) ?? []
        let numericIndices = firstData.indices.filter {
            Double(firstData[$0].trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        }
        let xIndex = headers.indices.first { !numericIndices.contains($0) } ?? 0
        let yIndex = numericIndices.first { $0 != xIndex }
        guard let yIndex, headers.indices.contains(xIndex), headers.indices.contains(yIndex) else {
            return (headers, max(0, lines.count - 1), nil)
        }

        let arguments: [String: Any] = [
            "dataRef": dataRef,
            "format": format,
            "chartType": "line",
            "xColumn": headers[xIndex],
            "series": [headers[yIndex]],
        ]
        return (
            headers,
            max(0, lines.count - 1),
            ["tool": "render_chart", "arguments": arguments]
        )
    }

    private static func collectArrays(
        _ value: Any,
        path: String,
        depth: Int,
        into descriptors: inout [StructuredArrayDescriptor]
    ) {
        guard depth <= maxDepth, descriptors.count < maxDescriptors else { return }

        if let object = value as? [String: Any] {
            for key in object.keys.sorted() where isSimplePathKey(key) {
                guard let child = object[key] else { continue }
                let childPath = path.isEmpty ? key : "\(path).\(key)"
                collectArrays(child, path: childPath, depth: depth + 1, into: &descriptors)
                if descriptors.count >= maxDescriptors { return }
            }
            return
        }

        guard let array = value as? [Any] else { return }
        let nonNull = array.filter { !($0 is NSNull) }
        if nonNull.allSatisfy({ isScalar($0) }) {
            descriptors.append(
                StructuredArrayDescriptor(
                    path: path,
                    kind: scalarKind(nonNull),
                    count: array.count,
                    first: array.first.flatMap(scalarDescription),
                    last: array.last.flatMap(scalarDescription)
                )
            )
            return
        }

        if let first = nonNull.first {
            collectArrays(first, path: path + "[0]", depth: depth + 1, into: &descriptors)
        }
    }

    private static func isSimplePathKey(_ key: String) -> Bool {
        !key.isEmpty
            && key.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).contains($0)
            }
    }

    private static func isScalar(_ value: Any) -> Bool {
        value is String || value is NSNumber || value is Bool
    }

    private static func scalarKind(_ values: [Any]) -> StructuredArrayDescriptor.Kind {
        guard !values.isEmpty else { return .mixed }
        if values.allSatisfy({ $0 is String }) { return .string }
        if values.allSatisfy({ isJSONBoolean($0) }) { return .boolean }
        if values.allSatisfy({ $0 is NSNumber && !isJSONBoolean($0) }) { return .number }
        return .mixed
    }

    private static func isJSONBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return value is Bool }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func scalarDescription(_ value: Any) -> String? {
        if value is NSNull { return nil }
        if let string = value as? String { return String(string.prefix(80)) }
        if let number = value as? NSNumber { return number.stringValue }
        return String(describing: value)
    }

    private static func xScore(_ path: String) -> Int {
        let leaf = pathLeaf(path).lowercased()
        if leaf == "timestamp" || leaf == "timestamps" { return 100 }
        if leaf == "date" || leaf == "dates" { return 90 }
        if leaf.contains("time") { return 70 }
        if leaf.contains("date") { return 60 }
        return 0
    }

    private static func yScore(_ path: String) -> Int {
        let leaf = pathLeaf(path).lowercased()
        if leaf == "close" { return 100 }
        if leaf == "adjclose" || leaf == "adjusted_close" { return 95 }
        if leaf == "value" || leaf == "values" { return 80 }
        if leaf.contains("price") { return 70 }
        if leaf == "open" { return 50 }
        if leaf == "high" || leaf == "low" { return 40 }
        return 10
    }

    private static func pathLeaf(_ path: String) -> String {
        path.split(separator: ".").last.map(String.init)?
            .replacingOccurrences(of: "[0]", with: "") ?? path
    }

    private static func displayName(for path: String) -> String {
        let leaf = pathLeaf(path).replacingOccurrences(of: "_", with: " ")
        return leaf.prefix(1).uppercased() + String(leaf.dropFirst())
    }
}
