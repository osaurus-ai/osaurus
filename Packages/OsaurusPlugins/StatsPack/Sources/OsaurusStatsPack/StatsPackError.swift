//
//  StatsPackError.swift
//  OsaurusStatsPack
//

import Foundation

/// Pack-specific parse failures report line or schema context so callers can
/// explain malformed stats inputs without leaking full file contents.
public enum StatsPackError: LocalizedError, Equatable, Sendable {
    case invalidSchemaSidecar(String)
    case invalidDelimitedLine(line: Int)
    case unreadableUTF8Line(line: Int)
    case invalidJSONLine(line: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidSchemaSidecar(let message):
            return "CSV schema sidecar is invalid: \(message)"
        case .invalidDelimitedLine(let line):
            return "Delimited text line \(line) has unbalanced quotes"
        case .unreadableUTF8Line(let line):
            return "Text line \(line) is not valid UTF-8"
        case .invalidJSONLine(let line):
            return "JSONL line \(line) is not valid JSON"
        }
    }
}
