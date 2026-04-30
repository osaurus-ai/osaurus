//
//  DocumentAdapterError.swift
//  osaurus
//
//  Shared error surface for every document format adapter, emitter, and
//  streamer. Callers that don't care about the specific failure can still
//  catch the common cases (size, cancellation) at the protocol boundary
//  without per-format knowledge.
//

import Foundation

public enum DocumentAdapterError: LocalizedError, Sendable {
    case unsupportedFormat(formatId: String)
    case sizeLimitExceeded(actual: Int64, limit: Int64)
    case readFailed(underlying: String)
    case writeFailed(underlying: String)
    case emptyContent
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let id):
            return "No registered adapter for format '\(id)'"
        case .sizeLimitExceeded(let actual, let limit):
            return "File exceeds size limit (\(actual) bytes > \(limit) bytes)"
        case .readFailed(let reason):
            return "Document read failed: \(reason)"
        case .writeFailed(let reason):
            return "Document write failed: \(reason)"
        case .emptyContent:
            return "Document contains no readable content"
        case .cancelled:
            return "Document parse was cancelled"
        }
    }
}
