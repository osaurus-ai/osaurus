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

    private static func envelopeDict(_ result: String) -> [String: Any]? {
        guard let data = result.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return dict
    }
}
