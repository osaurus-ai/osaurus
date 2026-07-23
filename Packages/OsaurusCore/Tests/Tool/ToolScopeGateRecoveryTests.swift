//
//  ToolScopeGateRecoveryTests.swift
//  osaurusTests
//
//  Pins the execution-scope gate's error contract (#2145). A registered,
//  enabled dynamic tool the turn simply never exposed must come back as a
//  RETRYABLE tool_not_found pointing at `capabilities_load`, so the model
//  can load it and recover instead of apologizing and giving up. A name the
//  registry does not know keeps the opaque, non-retryable refusal — the
//  gate must not reveal anything about tools that were deliberately
//  withheld.
//

import Foundation
import Testing

@testable import OsaurusCore

private final class ScopeProbeTool: OsaurusTool, @unchecked Sendable {
    let name: String
    let description = "Test-only scope gate probe."
    let parameters: JSONValue? = nil
    private(set) var executions = 0

    init(name: String) { self.name = name }

    func execute(argumentsJSON: String) async throws -> String {
        executions += 1
        return ToolEnvelope.success(tool: name, text: "ran")
    }
}

@Suite(.serialized)
@MainActor
struct ToolScopeGateRecoveryTests {

    private func envelope(_ result: String) throws -> [String: Any]? {
        try JSONSerialization.jsonObject(with: result.data(using: .utf8)!) as? [String: Any]
    }

    @Test
    func unscopedButLoadableTool_returnsRetryableCapabilitiesLoadHint() async throws {
        let tool = ScopeProbeTool(name: "test_scope_gate_loadable_probe")
        ToolRegistry.shared.register(tool)
        ToolRegistry.shared.setEnabled(true, for: tool.name)
        defer {
            ToolRegistry.shared.setEnabled(false, for: tool.name)
            ToolRegistry.shared.unregister(names: [tool.name])
        }

        // Scope exposes nothing — the skill-invocation shape from #2145,
        // where the model calls a real tool it was never shown.
        let scope = ToolExecutionScope(exposed: [])
        let result = try await ChatExecutionContext.$toolExecutionScope.withValue(scope) {
            try await ToolRegistry.shared.execute(name: tool.name, argumentsJSON: "{}")
        }

        #expect(tool.executions == 0)
        let parsed = try envelope(result)
        #expect(parsed?["ok"] as? Bool == false)
        #expect(parsed?["kind"] as? String == "tool_not_found")
        #expect(parsed?["retryable"] as? Bool == true)
        let message = parsed?["message"] as? String ?? ""
        #expect(message.contains("capabilities_load"))
        #expect(message.contains("tool/\(tool.name)"))
    }

    @Test
    func unscopedUnknownName_keepsOpaqueNonRetryableRefusal() async throws {
        let unknown = "test_scope_gate_ghost_\(UUID().uuidString.prefix(8))"

        let scope = ToolExecutionScope(exposed: [])
        let result = try await ChatExecutionContext.$toolExecutionScope.withValue(scope) {
            try await ToolRegistry.shared.execute(name: unknown, argumentsJSON: "{}")
        }

        let parsed = try envelope(result)
        #expect(parsed?["ok"] as? Bool == false)
        #expect(parsed?["kind"] as? String == "tool_not_found")
        #expect(parsed?["retryable"] as? Bool == false)
        let message = parsed?["message"] as? String ?? ""
        #expect(!message.contains("capabilities_load"))
    }

    @Test
    func unscopedAgentWithheldTool_keepsOpaqueNonRetryableRefusal() async throws {
        let tool = ScopeProbeTool(name: "test_scope_gate_withheld_probe")
        ToolRegistry.shared.register(tool)
        // Registered but globally disabled: capabilities_load would refuse
        // it, so the gate must not hint at it.
        ToolRegistry.shared.setEnabled(false, for: tool.name)
        defer { ToolRegistry.shared.unregister(names: [tool.name]) }

        let scope = ToolExecutionScope(exposed: [])
        let result = try await ChatExecutionContext.$toolExecutionScope.withValue(scope) {
            try await ToolRegistry.shared.execute(name: tool.name, argumentsJSON: "{}")
        }

        #expect(tool.executions == 0)
        let parsed = try envelope(result)
        #expect(parsed?["retryable"] as? Bool == false)
        let message = parsed?["message"] as? String ?? ""
        #expect(!message.contains("capabilities_load"))
    }

    @Test
    func scopeActivationMakesTheToolExecutable() async throws {
        let tool = ScopeProbeTool(name: "test_scope_gate_activated_probe")
        ToolRegistry.shared.register(tool)
        ToolRegistry.shared.setEnabled(true, for: tool.name)
        defer {
            ToolRegistry.shared.setEnabled(false, for: tool.name)
            ToolRegistry.shared.unregister(names: [tool.name])
        }

        let scope = ToolExecutionScope(exposed: [])
        scope.activate([tool.name])
        let result = try await ChatExecutionContext.$toolExecutionScope.withValue(scope) {
            try await ToolRegistry.shared.execute(name: tool.name, argumentsJSON: "{}")
        }

        #expect(tool.executions == 1)
        #expect(!ToolEnvelope.isError(result))
    }
}
