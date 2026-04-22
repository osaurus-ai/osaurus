//
//  ToolErrorEnvelope.swift
//  osaurus
//
//  Compatibility shim. The canonical envelope shape is now `ToolEnvelope`
//  in `ToolEnvelope.swift`; this file preserves the legacy `ToolErrorEnvelope`
//  surface so HTTP / plugin / chat catch sites that constructed envelopes
//  the old way continue to compile and produce the new wire format.
//
//  Prefer `ToolEnvelope.failure(...)` / `ToolEnvelope.fromError(...)` in new
//  code. This shim will be removed in a future release.
//

import Foundation

/// Legacy envelope type. Forwards to `ToolEnvelope.failure(...)` so any
/// caller that builds one of these still emits the new on-the-wire shape.
public struct ToolErrorEnvelope: Sendable {
    public enum Kind: String, Sendable {
        case rejected
        case timeout
        case invalidArguments
        case executionError
        case toolNotFound
        case unavailable

        fileprivate var asEnvelopeKind: ToolEnvelope.Kind {
            switch self {
            case .rejected: return .rejected
            case .timeout: return .timeout
            case .invalidArguments: return .invalidArgs
            case .executionError: return .executionError
            case .toolNotFound: return .toolNotFound
            case .unavailable: return .unavailable
            }
        }
    }

    public let kind: Kind
    public let reason: String
    public let toolName: String?
    public let retryable: Bool

    public init(
        kind: Kind,
        reason: String,
        toolName: String? = nil,
        retryable: Bool? = nil
    ) {
        self.kind = kind
        self.reason = reason
        self.toolName = toolName
        self.retryable = retryable ?? Self.defaultRetryable(for: kind)
    }

    /// Encode as a JSON string in the new `ToolEnvelope` wire format.
    public func toJSONString() -> String {
        ToolEnvelope.failure(
            kind: kind.asEnvelopeKind,
            message: reason,
            tool: toolName,
            retryable: retryable
        )
    }

    /// True for any failure-shaped result string. Delegates to
    /// `ToolEnvelope.isError` so legacy and new shapes are both detected.
    public static func isErrorResult(_ result: String) -> Bool {
        ToolEnvelope.isError(result)
    }

    private static func defaultRetryable(for kind: Kind) -> Bool {
        switch kind {
        case .rejected, .toolNotFound: return false
        case .timeout, .invalidArguments, .executionError, .unavailable: return true
        }
    }
}
