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
    /// Run the dispatcher's schema preflight (coerce + validate + per-tool
    /// argument hint) for a tool's arguments. Returns `.ready(<dispatch-args>)`
    /// when the validator accepts the (possibly rewritten) payload, or
    /// `.rejected(<envelope>)` with the failure JSON the dispatcher would
    /// have surfaced.
    @MainActor
    func preflightForTest(
        argumentsJSON: String,
        schema: JSONValue?,
        toolName: String,
        hint: ((String) -> String?)? = nil,
        preservingEmpty: Set<String> = []
    ) -> PreflightOutcomeForTest {
        switch ToolRegistry.preflight(
            argumentsJSON: argumentsJSON,
            schema: schema,
            toolName: toolName,
            hint: hint,
            preservingEmpty: preservingEmpty
        ) {
        case .ready(let args): return .ready(args)
        case .rejected(let envelope): return .rejected(envelope)
        }
    }
}
