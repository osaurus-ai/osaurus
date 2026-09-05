//
//  ToolScopeGateRecoveryTests.swift
//  osaurusTests
//
//  Pins the execution-scope gate's error contract (#2145). A registered,
//  enabled dynamic tool the turn simply never exposed must come back as a
//  RETRYABLE tool_not_found pointing at the loader tool the request
//  exposes (`capabilities` on chat, `capabilities_load` legacy), so the model
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

/// A probe with an object schema, so the steer hint can be checked for the
/// target tool's own argument names.
private final class SchemaProbeTool: OsaurusTool, @unchecked Sendable {
    let name: String
    let description = "Test-only schema probe."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "urls": .object(["type": .string("array")]),
            "maxCharacters": .object(["type": .string("number")]),
        ]),
        "required": .array([.string("urls")]),
    ])
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
        ToolRegistry.shared.registerPluginTool(tool)
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
        // Empty scope exposes neither loader, so the hint falls back to the
        // only discoverable one on chat surfaces: `capabilities`.
        #expect(message.contains("Call capabilities with ids"))
        #expect(message.contains("tool/\(tool.name)"))
    }

    @Test
    func unscopedButLoadableTool_hintsLegacyLoaderWhenThatIsWhatTheRequestExposes() async throws {
        let tool = ScopeProbeTool(name: "test_scope_gate_legacy_loader_probe")
        ToolRegistry.shared.registerPluginTool(tool)
        ToolRegistry.shared.setEnabled(true, for: tool.name)
        defer {
            ToolRegistry.shared.setEnabled(false, for: tool.name)
            ToolRegistry.shared.unregister(names: [tool.name])
        }

        let loadSpec = Tool(
            type: "function",
            function: ToolFunction(
                name: "capabilities_load",
                description: "legacy loader",
                parameters: nil
            )
        )
        let scope = ToolExecutionScope(exposed: [loadSpec])
        let result = try await ChatExecutionContext.$toolExecutionScope.withValue(scope) {
            try await ToolRegistry.shared.execute(name: tool.name, argumentsJSON: "{}")
        }

        let parsed = try envelope(result)
        #expect(parsed?["retryable"] as? Bool == true)
        let message = parsed?["message"] as? String ?? ""
        #expect(message.contains("Call capabilities_load with ids"))
    }

    @Test
    func unexposedGatedBuiltInDoesNotSuggestCapabilitiesLoad() async throws {
        let scope = ToolExecutionScope(exposed: [])
        let result = try await ChatExecutionContext.$currentAgentId.withValue(UUID()) {
            try await ChatExecutionContext.$toolExecutionScope.withValue(scope) {
                try await ToolRegistry.shared.execute(
                    name: BrowserUseTool.toolName,
                    argumentsJSON: #"{"goal":"open example.com"}"#
                )
            }
        }

        let parsed = try envelope(result)
        #expect(parsed?["retryable"] as? Bool == false)
        let message = parsed?["message"] as? String ?? ""
        #expect(!message.contains("Call capabilities"))
    }

    @Test
    func unscopedUnknownName_keepsOpaqueNonRetryableRefusal() async throws {
        let unknown = "test_scope_gate_ghost_\(UUID().uuidString.prefix(8))"

        let scope = ToolExecutionScope(exposed: [])
        for guessed in [unknown, "plugin/\(unknown)"] {
            let result = try await ChatExecutionContext.$toolExecutionScope.withValue(scope) {
                try await ToolRegistry.shared.execute(name: guessed, argumentsJSON: "{}")
            }

            let parsed = try envelope(result)
            #expect(parsed?["ok"] as? Bool == false)
            #expect(parsed?["kind"] as? String == "tool_not_found")
            #expect(parsed?["retryable"] as? Bool == false)
            let message = parsed?["message"] as? String ?? ""
            #expect(!message.contains("Call capabilities"))
        }
    }

    @Test
    func pluginGroupIdCalledAsTool_redirectsToGatewayLoad() async throws {
        let plugin = SandboxPlugin(
            name: "Scope Group Rescue \(UUID().uuidString.prefix(6))",
            description: "Scope-gate group rescue fixture"
        )
        let member = SandboxPluginTool(
            spec: SandboxToolSpec(
                id: "probe",
                description: "Group rescue probe",
                parameters: [:],
                run: "echo rescued"
            ),
            plugin: plugin
        )
        ToolRegistry.shared.registerPluginTool(member)
        ToolRegistry.shared.setEnabled(true, for: member.name)
        defer { ToolRegistry.shared.unregister(names: [member.name]) }

        let gatewaySpec = Tool(
            type: "function",
            function: ToolFunction(
                name: "capabilities",
                description: "merged gateway",
                parameters: nil
            )
        )
        let scope = ToolExecutionScope(exposed: [gatewaySpec])

        for guessed in [plugin.id, "plugin/\(plugin.id)"] {
            let result = try await ChatExecutionContext.$toolExecutionScope.withValue(scope) {
                try await ToolRegistry.shared.execute(
                    name: guessed,
                    argumentsJSON: #"{"date":"tomorrow"}"#
                )
            }
            let parsed = try envelope(result)
            #expect(parsed?["ok"] as? Bool == false)
            #expect(parsed?["kind"] as? String == "tool_not_found")
            #expect(parsed?["retryable"] as? Bool == true)
            let message = parsed?["message"] as? String ?? ""
            #expect(message.contains("capability id for a plugin group"))
            #expect(message.contains(#"capabilities with {"ids":["plugin/\#(plugin.id)"]}"#))
            #expect(!message.contains(member.name))
        }
    }

    @Test
    func pluginGroupIdCalledAsTool_staysOpaqueWhenAgentWithholdsEveryMember() async throws {
        let plugin = SandboxPlugin(
            name: "Scope Group Withheld \(UUID().uuidString.prefix(6))",
            description: "Withheld scope-gate group fixture"
        )
        let member = SandboxPluginTool(
            spec: SandboxToolSpec(
                id: "probe",
                description: "Withheld group probe",
                parameters: [:],
                run: "echo should-not-run"
            ),
            plugin: plugin
        )
        ToolRegistry.shared.registerPluginTool(member)
        ToolRegistry.shared.setEnabled(true, for: member.name)
        defer { ToolRegistry.shared.unregister(names: [member.name]) }

        let agent = Agent(
            name: "GroupRescueDenied-\(UUID().uuidString.prefix(6))",
            agentAddress: "test-group-rescue-\(UUID().uuidString)",
            autonomousExec: AutonomousExecConfig(enabled: false),
            toolSelectionMode: .manual,
            memoryEnabled: false
        )
        AgentManager.shared.add(agent)
        AgentManager.shared.updateEnabledToolNames(["get_current_time"], for: agent.id)
        defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }

        let gatewaySpec = Tool(
            type: "function",
            function: ToolFunction(
                name: "capabilities",
                description: "merged gateway",
                parameters: nil
            )
        )
        let scope = ToolExecutionScope(exposed: [gatewaySpec])
        let result = try await ChatExecutionContext.$currentAgentId.withValue(agent.id) {
            try await ChatExecutionContext.$toolExecutionScope.withValue(scope) {
                try await ToolRegistry.shared.execute(
                    name: "plugin/\(plugin.id)",
                    argumentsJSON: "{}"
                )
            }
        }

        let parsed = try envelope(result)
        #expect(parsed?["retryable"] as? Bool == false)
        let message = parsed?["message"] as? String ?? ""
        #expect(!message.contains("capability id for a plugin group"))
        #expect(!message.contains("Call capabilities"))
        #expect(!message.contains(member.name))
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
        #expect(!message.contains("Call capabilities"))
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

    // MARK: - Hallucinated fetch-tool steering

    @Test
    func hallucinatedFetchName_isSteeredToSearchAndExtract_whenExposed() async throws {
        // `web_fetch` has never existed in osaurus, but models trained on
        // other harnesses call it as if it were universal — observed live as
        // a research run that burned its whole turn on it and read zero
        // pages. When the request exposes `search_and_extract`, the dead end
        // must instead point at the fetch tool already in the schema.
        let scope = ToolExecutionScope(exposed: [])
        scope.activate(["web_search", "search_and_extract"])
        let result = try await ChatExecutionContext.$toolExecutionScope.withValue(scope) {
            try await ToolRegistry.shared.execute(
                name: "web_fetch",
                argumentsJSON: "{\"url\": \"https://example.com\"}"
            )
        }
        let parsed = try envelope(result)
        #expect(parsed?["ok"] as? Bool == false)
        #expect(parsed?["kind"] as? String == "tool_not_found")
        #expect(parsed?["retryable"] as? Bool == true)
        let message = parsed?["message"] as? String ?? ""
        #expect(message.contains("search_and_extract"))
        #expect(message.contains("urls"))
    }

    @Test
    func hallucinatedFetchName_staysOpaque_whenRetrievalIsNotExposed() async throws {
        // Web disabled for this agent: the steering must not leak the name of
        // a tool the request cannot call. The plain unregistered-name refusal
        // applies.
        let scope = ToolExecutionScope(exposed: [])
        scope.activate(["get_current_time"])
        let result = try await ChatExecutionContext.$toolExecutionScope.withValue(scope) {
            try await ToolRegistry.shared.execute(name: "web_fetch", argumentsJSON: "{}")
        }
        let parsed = try envelope(result)
        #expect(parsed?["ok"] as? Bool == false)
        #expect(parsed?["kind"] as? String == "tool_not_found")
        let message = parsed?["message"] as? String ?? ""
        #expect(!message.contains("search_and_extract"))
    }

    // MARK: - Workspace-tool dead end names the real next step

    @Test
    func workspaceToolWithoutFolder_namesTheFolderChip_regardlessOfRegistration() async throws {
        // No folder attached to THIS chat: the model's file_write call must
        // not die on an opaque "not available" (the observed "file_write
        // wasn't available in this session" + silent artifact fallback), and
        // it must not be steered into a capabilities load either — on any
        // process where a folder was ever mounted, the registered
        // runtime-managed tool reads `.alreadyLoaded` and the loadable-hint
        // branch used to win, sending the model into a load the dynamic
        // gates refuse. The answer is keyed on the NAME, so it must be
        // byte-identical in BOTH registry states.
        let scope = ToolExecutionScope(exposed: [])
        for registered in [false, true] {
            if registered {
                FolderToolManager.shared.ensureFolderToolsRegistered()
            } else {
                FolderToolManager.shared._unregisterAllForTesting()
            }
            defer { if registered { FolderToolManager.shared._unregisterAllForTesting() } }

            let result = try await ChatExecutionContext.$toolExecutionScope.withValue(scope) {
                try await ToolRegistry.shared.execute(
                    name: "file_write",
                    argumentsJSON: "{}"
                )
            }
            let parsed = try envelope(result)
            #expect(parsed?["ok"] as? Bool == false, "registered=\(registered)")
            #expect(parsed?["retryable"] as? Bool == false, "registered=\(registered)")
            let message = parsed?["message"] as? String ?? ""
            #expect(message.contains("Folder chip"), "registered=\(registered)")
            #expect(message.contains("share_artifact"), "registered=\(registered)")
            #expect(
                !message.contains("Call capabilities"),
                "registered=\(registered): must never steer into a loader round-trip")
        }
    }

    @Test @MainActor
    func workspaceToolLoad_namesTheFolderChip_regardlessOfRegistration() async throws {
        // Same contract on the load path: `capabilities {"ids":
        // ["tool/file_write"]}` must answer with the folder guidance in both
        // registry states. The first cut nested this under `isBuiltIn`,
        // which is provably dead for runtime-managed workspace tools —
        // unregistered they hit "not found", registered they hit the
        // dynamic-grant refusals or a false "callable NOW".
        for registered in [false, true] {
            if registered {
                FolderToolManager.shared.ensureFolderToolsRegistered()
            } else {
                FolderToolManager.shared._unregisterAllForTesting()
            }
            defer { if registered { FolderToolManager.shared._unregisterAllForTesting() } }

            let result = try await ChatExecutionContext.$currentAgentId.withValue(UUID()) {
                try await CapabilitiesLoadTool().execute(
                    argumentsJSON: #"{"ids":["tool/file_write"]}"#
                )
            }
            #expect(ToolEnvelope.isError(result), "registered=\(registered)")
            #expect(result.contains("Folder chip"), "registered=\(registered)")
            #expect(result.contains("share_artifact"), "registered=\(registered)")
            #expect(!result.contains("callable NOW"), "registered=\(registered)")
        }
    }

    /// `web_fetch_exa` is the Exa plugin's `exa_search_web_fetch_exa` with
    /// the plugin prefix dropped (Ornith, 2026-09-05). When that one tool is
    /// exposed to the request, the model is pointed at its real name; when
    /// two candidates are exposed, nothing is guessed.
    @Test
    func prefixDroppedPluginToolName_isSteeredToTheUniqueExposedTool() async throws {
        let exa = SchemaProbeTool(name: "exa_search_web_fetch_exa")
        ToolRegistry.shared.registerPluginTool(exa)
        ToolRegistry.shared.setEnabled(true, for: exa.name)
        defer {
            ToolRegistry.shared.setEnabled(false, for: exa.name)
            ToolRegistry.shared.unregister(names: [exa.name])
        }
        let spec = ToolRegistry.shared.specs(forTools: [exa.name])
        let scope = ToolExecutionScope(exposed: spec)
        let result = try await ChatExecutionContext.$toolExecutionScope.withValue(scope) {
            try await ToolRegistry.shared.execute(name: "web_fetch_exa", argumentsJSON: #"{"urls":["https://x"]}"#)
        }
        #expect(exa.executions == 0, "steering names the tool; it must not run it")
        let parsed = try envelope(result)
        #expect(parsed?["kind"] as? String == "tool_not_found")
        #expect((parsed?["message"] as? String ?? "").contains("exa_search_web_fetch_exa"))
        // The hint must not tell the model to reuse the invented tool's
        // arguments; a tool with a schema gets its own argument names.
        let steerMessage = parsed?["message"] as? String ?? ""
        #expect(steerMessage.contains("same arguments") == false)
        #expect(steerMessage.contains("required: urls"), "the hint names the target tool's own arguments")

        // Not exposed to this request: no steer to it (falls through to the
        // generic fetch-intent handling / refusal).
        let unexposed = try await ChatExecutionContext.$toolExecutionScope.withValue(ToolExecutionScope(exposed: [])) {
            try await ToolRegistry.shared.execute(name: "web_fetch_exa", argumentsJSON: "{}")
        }
        #expect(!(try envelope(unexposed)?["message"] as? String ?? "").contains("exa_search_web_fetch_exa"))

        // Two exposed candidates: ambiguous, no guess.
        let other = ScopeProbeTool(name: "other_plugin_web_fetch_exa")
        ToolRegistry.shared.registerPluginTool(other)
        ToolRegistry.shared.setEnabled(true, for: other.name)
        defer {
            ToolRegistry.shared.setEnabled(false, for: other.name)
            ToolRegistry.shared.unregister(names: [other.name])
        }
        let both = ToolExecutionScope(exposed: ToolRegistry.shared.specs(forTools: [exa.name, other.name]))
        let ambiguous = try await ChatExecutionContext.$toolExecutionScope.withValue(both) {
            try await ToolRegistry.shared.execute(name: "web_fetch_exa", argumentsJSON: "{}")
        }
        let msg = try envelope(ambiguous)?["message"] as? String ?? ""
        #expect(!msg.contains("exa_search_web_fetch_exa") && !msg.contains("other_plugin_web_fetch_exa"))
    }
}
