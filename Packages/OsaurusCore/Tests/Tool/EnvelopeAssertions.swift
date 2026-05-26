//
//  EnvelopeAssertions.swift
//
//  Tiny shared helpers for resilience tests. Pulls the `field` / `kind`
//  off a `ToolEnvelope` JSON string so callers don't repeat the
//  `JSONSerialization` boilerplate. Use from any test file that needs
//  to assert the structured failure envelope shape (matrix tests,
//  per-tool resilience tests).
//

import Foundation

@testable import OsaurusCore

enum EnvelopeAssertions {
    /// `field` from a failure envelope JSON, or nil when the input
    /// isn't a JSON object or the field isn't present.
    static func failureField(_ result: String) -> String? {
        envelopeDict(result)?["field"] as? String
    }

    /// `kind` from a failure envelope JSON, or nil when the input
    /// isn't a JSON object or the kind isn't present.
    static func failureKind(_ result: String) -> String? {
        envelopeDict(result)?["kind"] as? String
    }

    /// `retryable` from a failure envelope JSON, or nil when the input
    /// isn't a JSON object or the field isn't present. Tests that pin
    /// non-retryable error paths assert against `== false` so retries
    /// don't silently regress to the kind-default behaviour.
    static func failureRetryable(_ result: String) -> Bool? {
        envelopeDict(result)?["retryable"] as? Bool
    }

    /// `message` from a failure envelope JSON, or nil if absent. Used by
    /// tests that care about the prose the model will see (e.g. binary
    /// hints, extension callouts).
    static func failureMessage(_ result: String) -> String? {
        envelopeDict(result)?["message"] as? String
    }

    /// Pull `result.text` out of a success envelope produced by the
    /// `ToolEnvelope.success(tool:text:)` convenience. Returns nil when
    /// the envelope is a failure, isn't an object, or doesn't carry a
    /// `result.text` payload (e.g. the structured `result: [...]`
    /// shape from `shell_run`).
    static func successText(_ result: String) -> String? {
        guard let dict = envelopeDict(result),
            let inner = dict["result"] as? [String: Any],
            let text = inner["text"] as? String
        else { return nil }
        return text
    }

    /// Structured `result` object from a success envelope, when present.
    static func successPayload(_ result: String) -> [String: Any]? {
        guard let dict = envelopeDict(result),
            let inner = dict["result"] as? [String: Any]
        else { return nil }
        return inner
    }

    private static func envelopeDict(_ result: String) -> [String: Any]? {
        guard let data = result.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return dict
    }
}
