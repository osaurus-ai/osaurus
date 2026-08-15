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

        // Regression (E4B loop): the bare dead-end message left small models
        // apologizing ("that tool is not available") when the real tool was
        // in their schema under another name. The envelope must steer back
        // to the schema without listing tool names (lists trigger invention).
        #expect(message.contains("tool schema"))
        #expect(message.contains("Do not guess"))

        // Regression (#2366): a model with strong priors on common tool names
        // (e.g. `run` for a shell) read the rejection, correctly explained it
        // could not run a shell, and then *fabricated* the output as if the
        // command had run. The envelope must explicitly say the tool was not
        // executed and the user cannot tell simulated output from real output,
        // so the model does not produce a plausible-looking result the user
        // will mistake for a real one.
        #expect(message.contains("Do not show what the tool's output would be"))
        #expect(message.contains("not actually executed"))
    }
}
