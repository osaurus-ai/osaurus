//
//  ToolNotFoundSelfHealTests.swift
//  osaurusTests
//
//  Verifies that ToolRegistry.execute does NOT throw on unknown tools.
//  Instead it returns a structured `ToolEnvelope.failure(kind: .toolNotFound)`
//  so the agent loop stays alive and the model can recover by calling
//  capabilities_load.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ToolNotFoundSelfHealTests {

    @Test
    func unknownTool_returnsToolNotFoundEnvelopeWithoutThrowing() async throws {
        // Pick a name that no built-in / plugin / sandbox tool will ever
        // claim — we just need the registry to miss in `toolsByName`.
        let unknownName = "definitely_not_a_real_tool_\(UUID().uuidString.prefix(8))"

        let result = try await ToolRegistry.shared.execute(
            name: unknownName,
            argumentsJSON: "{}"
        )

        // Result must look like the new envelope and carry the toolNotFound kind.
        #expect(ToolEnvelope.isError(result))
        let data = result.data(using: .utf8)!
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["ok"] as? Bool == false)
        #expect(parsed?["kind"] as? String == "tool_not_found")
        #expect(parsed?["tool"] as? String == unknownName)
        #expect(parsed?["retryable"] as? Bool == false)

        // Message must mention the tool name so the model knows what failed.
        let message = parsed?["message"] as? String ?? ""
        #expect(message.contains(unknownName))
    }
}
