//
//  PreflightTestHelper.swift
//
//  Exposes the schema preflight (coerce + validate) as a standalone
//  hook for resilience tests. Mirrors the dispatcher's private
//  `ToolRegistry.preflight(...)` so callers can assert what the
//  validator accepts / rejects without executing the tool body — which
//  is important for tools that touch the filesystem, network, or
//  sandbox container during execute.
//

import Foundation

@testable import OsaurusCore

extension ToolRegistry {
    /// Outcome of `preflightForTest`. Mirrors `ToolRegistry`'s private
    /// `PreflightOutcome` so tests inspect the same decision the
    /// production dispatcher makes without having to register tools.
    enum PreflightOutcomeForTest {
        case ready(String)
        case rejected(String)
    }

    /// Run only the schema preflight (coerce + validate) for a tool's
    /// arguments. Returns `.ready(<dispatch-args>)` when the validator
    /// accepts the (possibly rewritten) payload, or `.rejected(<envelope>)`
    /// with the failure JSON the dispatcher would have surfaced.
    @MainActor
    func preflightForTest(
        argumentsJSON: String,
        schema: JSONValue?,
        toolName: String
    ) -> PreflightOutcomeForTest {
        guard let schema,
            let data = argumentsJSON.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data)
        else { return .ready(argumentsJSON) }
        let coerced = SchemaValidator.coerceArguments(parsed, against: schema)
        let result = SchemaValidator.validate(arguments: coerced, against: schema)
        if !result.isValid, let message = result.errorMessage {
            return .rejected(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: message,
                    field: result.field,
                    tool: toolName
                )
            )
        }
        guard
            let coercedData = try? JSONSerialization.data(
                withJSONObject: coerced,
                options: [.sortedKeys]
            ),
            let coercedJSON = String(data: coercedData, encoding: .utf8)
        else { return .ready(argumentsJSON) }
        return .ready(coercedJSON)
    }
}
