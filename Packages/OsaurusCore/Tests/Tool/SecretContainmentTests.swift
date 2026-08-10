//
//  SecretContainmentTests.swift
//  osaurusTests
//
//  Pins the two secret-containment layers added by the round-2 audit:
//   - `SecretScrubber`: known secret VALUES are redacted from exec
//     stdout/stderr before they reach the model's context.
//   - `SecretArgumentScrubber` / `ToolCallArgumentMaterial`: the direct-
//     `value` path of `sandbox_secret_set` reaches the execution seam
//     intact, but never re-enters recorded / model-visible / plugin-
//     visible tool-call material.
//

import Foundation
import Testing

@testable import OsaurusCore

struct SecretScrubberTests {

    @Test func replacesSecretValueWithKeyedMarker() {
        let out = SecretScrubber.scrub(
            "token is sk-abc123def and that's it",
            secrets: ["OPENAI_KEY": "sk-abc123def"]
        )
        #expect(out == "token is [REDACTED:OPENAI_KEY] and that's it")
    }

    @Test func replacesEveryOccurrence() {
        let out = SecretScrubber.scrub(
            "first=hunter2secret second=hunter2secret",
            secrets: ["PASS": "hunter2secret"]
        )
        #expect(!out.contains("hunter2secret"))
        #expect(out.components(separatedBy: "[REDACTED:PASS]").count == 3)
    }

    @Test func shortValuesAreNeverScrubbed() {
        // "dev" appears all over normal output; scrubbing it would
        // mangle innocent text.
        let text = "dev environment on /dev/null"
        let out = SecretScrubber.scrub(text, secrets: ["ENV_NAME": "dev"])
        #expect(out == text)
    }

    @Test func longerValuesScrubFirstSoSubstringSecretsLeaveNoTail() {
        let out = SecretScrubber.scrub(
            "combined: secretAB-secretAB-extra",
            secrets: [
                "SHORT": "secretAB",
                "LONG": "secretAB-secretAB-extra",
            ]
        )
        #expect(out == "combined: [REDACTED:LONG]")
    }

    @Test func emptyInputsPassThrough() {
        #expect(SecretScrubber.scrub("", secrets: ["K": "longvalue"]) == "")
        #expect(SecretScrubber.scrub("text", secrets: [:]) == "text")
    }
}

struct SecretArgumentScrubberTests {

    private let secret = "sk-live-secret-xyz-containment"
    private var secretSetArgs: String {
        """
        {"key":"API_KEY","description":"d","instructions":"i","value":"\(secret)"}
        """
    }

    @Test func valueIsRedactedForSandboxSecretSet() throws {
        let scrubbed = SecretArgumentScrubber.scrubForPersistence(
            toolName: "sandbox_secret_set",
            argumentsJSON: secretSetArgs
        )
        #expect(!scrubbed.contains(secret))

        let dict =
            try JSONSerialization.jsonObject(with: Data(scrubbed.utf8)) as? [String: Any]
        #expect(dict?["value"] as? String == "[REDACTED]")
        #expect(dict?["key"] as? String == "API_KEY")
        #expect(dict?["description"] as? String == "d")
        #expect(dict?["instructions"] as? String == "i")
    }

    @Test func otherToolsPassThroughUntouched() {
        let args = #"{"path":"notes.txt","value":"not-a-secret-field"}"#
        let scrubbed = SecretArgumentScrubber.scrubForPersistence(
            toolName: "file_write",
            argumentsJSON: args
        )
        // Byte-equivalent for every tool other than sandbox_secret_set.
        #expect(scrubbed == args)
    }

    @Test func promptPathWithoutValuePassesThrough() {
        let args = #"{"key":"API_KEY","description":"d","instructions":"i"}"#
        let scrubbed = SecretArgumentScrubber.scrubForPersistence(
            toolName: "sandbox_secret_set",
            argumentsJSON: args
        )
        #expect(scrubbed == args)
    }

    @Test func alreadyRedactedArgsAreStable() {
        let args =
            #"{"key":"API_KEY","description":"d","instructions":"i","value":"[REDACTED]"}"#
        let scrubbed = SecretArgumentScrubber.scrubForPersistence(
            toolName: "sandbox_secret_set",
            argumentsJSON: args
        )
        #expect(scrubbed == args)
    }

    @Test func unknownNestedFieldsFailClosed() {
        // `additionalProperties` is false. An unknown field can carry a
        // second secret copy even when the top-level value is redacted.
        let args = """
            {"key":"API_KEY","description":"d","instructions":"i","value":"\(secret)","meta":{"value":"nested-lookalike","note":"keep"}}
            """
        let scrubbed = SecretArgumentScrubber.recordedArguments(
            toolName: "sandbox_secret_set",
            argumentsJSON: args
        )
        #expect(!scrubbed.contains(secret))
        #expect(!scrubbed.contains("nested-lookalike"))
        #expect(scrubbed == SecretArgumentScrubber.failClosedArgumentsJSON)
    }

    @Test func malformedSecretSetJSONFailsClosedAndNeverEmitsOriginal() {
        // Truncated / non-JSON payloads may still contain the secret as
        // raw text. Fail closed rather than echoing the original input.
        let malformed = #"{"key":"API_KEY","value":"\#(secret)"#
        let scrubbed = SecretArgumentScrubber.scrubForPersistence(
            toolName: "sandbox_secret_set",
            argumentsJSON: malformed
        )
        #expect(scrubbed != malformed)
        #expect(!scrubbed.contains(secret))
        #expect(scrubbed.contains("[REDACTED]"))
        #expect(scrubbed == SecretArgumentScrubber.failClosedArgumentsJSON)
    }

    @Test func nonObjectJSONFailsClosed() {
        let arrayPayload = #"[{"value":"\#(secret)"}]"#
        let scrubbed = SecretArgumentScrubber.recordedArguments(
            toolName: "sandbox_secret_set",
            argumentsJSON: arrayPayload
        )
        #expect(!scrubbed.contains(secret))
        #expect(scrubbed == SecretArgumentScrubber.failClosedArgumentsJSON)
    }

    @Test func nonStringValueIsRedacted() throws {
        let args =
            #"{"key":"API_KEY","description":"d","instructions":"i","value":{"token":"nested-secret-blob"}}"#
        let scrubbed = SecretArgumentScrubber.recordedArguments(
            toolName: "sandbox_secret_set",
            argumentsJSON: args
        )
        #expect(!scrubbed.contains("nested-secret-blob"))
        #expect(scrubbed == SecretArgumentScrubber.failClosedArgumentsJSON)
    }

    @Test func directSecretDuplicatedInAllowedSiblingFieldsIsRedactedEverywhere() {
        let args =
            #"{"key":"API_\#(secret)","description":"credential \#(secret)","instructions":"paste \#(secret)","value":"\#(secret)"}"#
        let scrubbed = SecretArgumentScrubber.recordedArguments(
            toolName: "sandbox_secret_set",
            argumentsJSON: args
        )
        #expect(!scrubbed.contains(secret))
        #expect(scrubbed.components(separatedBy: "[REDACTED]").count == 5)
    }

    @Test func capabilityAliasIsRedacted() {
        let scrubbed = SecretArgumentScrubber.recordedArguments(
            toolName: "tool/sandbox_secret_set",
            argumentsJSON: secretSetArgs
        )
        #expect(!scrubbed.contains(secret))
        #expect(scrubbed.contains("[REDACTED]"))
    }

    @Test func splitKeepsSecretOnExecutionViewOnly() {
        let material = ToolCallArgumentMaterial.split(
            toolName: "sandbox_secret_set",
            argumentsJSON: secretSetArgs
        )
        // Execution seam must still see the real secret.
        #expect(material.forExecution == secretSetArgs)
        #expect(material.forExecution.contains(secret))
        // Recording seam must never reintroduce it.
        #expect(!material.forRecording.contains(secret))
        #expect(material.forRecording.contains("[REDACTED]"))
    }

    @Test func recordedToolCallUsesSecretSafeArguments() {
        let inv = ServiceToolInvocation(
            toolName: "sandbox_secret_set",
            jsonArguments: secretSetArgs,
            toolCallId: "call_secret_1"
        )
        let call = SecretArgumentScrubber.recordedToolCall(id: "call_secret_1", invocation: inv)
        #expect(call.function.name == "sandbox_secret_set")
        #expect(!call.function.arguments.contains(secret))
        #expect(call.function.arguments.contains("[REDACTED]"))
        // Original invocation is unchanged for ToolRegistry.execute.
        #expect(inv.jsonArguments.contains(secret))
    }

    @Test func recordedAssistantMessageScrubsSecretSetOnly() {
        let secretCall = ToolCall(
            id: "call_1",
            type: "function",
            function: ToolCallFunction(name: "sandbox_secret_set", arguments: secretSetArgs)
        )
        let otherArgs = #"{"path":"/tmp/notes.txt","value":"not-a-secret-field"}"#
        let otherCall = ToolCall(
            id: "call_2",
            type: "function",
            function: ToolCallFunction(name: "file_write", arguments: otherArgs)
        )
        let message = ChatMessage(
            role: "assistant",
            content: nil,
            tool_calls: [secretCall, otherCall],
            tool_call_id: nil
        )
        let recorded = SecretArgumentScrubber.recordedAssistantMessage(message)
        let calls = recorded.tool_calls ?? []
        #expect(calls.count == 2)
        #expect(!calls[0].function.arguments.contains(secret))
        #expect(calls[0].function.arguments.contains("[REDACTED]"))
        // Unrelated tool keeps exact argument text.
        #expect(calls[1].function.arguments == otherArgs)
    }

    @Test func completionAndInsightsHelpersNeverReemitSecretArguments() throws {
        let aliasCall = ToolCall(
            id: "call_alias",
            type: "function",
            function: ToolCallFunction(
                name: "tool/sandbox_secret_set",
                arguments: secretSetArgs
            )
        )
        let response = ChatCompletionResponse(
            id: "response-secret",
            created: 1,
            model: "test",
            choices: [
                ChatChoice(
                    index: 0,
                    message: ChatMessage(
                        role: "assistant",
                        content: nil,
                        tool_calls: [aliasCall],
                        tool_call_id: nil
                    ),
                    finish_reason: "tool_calls"
                )
            ],
            usage: Usage(prompt_tokens: 1, completion_tokens: 0, total_tokens: 1)
        )

        let serialized = try #require(ChatEngine.serializeResponseForLog(response))
        #expect(!serialized.contains(secret))
        #expect(serialized.contains("[REDACTED]"))

        let streamed = try #require(
            ChatEngine.streamResponseBody(
                accumulated: "",
                toolInvocation: ("tool/sandbox_secret_set", secretSetArgs)
            )
        )
        #expect(!streamed.contains(secret))
        #expect(streamed.contains("[REDACTED]"))

        #expect(
            ChatEngine.wireResponseBodyForLog(
                Data(#"{"arguments":"raw-secret"}"#.utf8),
                parsedToolNames: ["tool/sandbox_secret_set"],
                secretToolWasExposed: false
            ) == nil
        )
        // Batch parsing must inspect every call, not just the first.
        #expect(
            ChatEngine.wireResponseBodyForLog(
                Data(#"{"arguments":"raw-secret"}"#.utf8),
                parsedToolNames: ["file_read", "sandbox_secret_set"],
                secretToolWasExposed: false
            ) == nil
        )
        // Even malformed output that never yields a parsed invocation is
        // unsafe when the request exposed the secret-setting capability.
        #expect(
            ChatEngine.wireResponseBodyForLog(
                Data(#"{"malformed":"raw-secret""#.utf8),
                parsedToolNames: [],
                secretToolWasExposed: true
            ) == nil
        )
        #expect(
            ChatEngine.wireResponseBodyForLog(
                Data(#"{"content":"safe"}"#.utf8),
                parsedToolNames: ["file_read"],
                secretToolWasExposed: false
            ) == Data(#"{"content":"safe"}"#.utf8)
        )
    }
}

@Suite(.serialized)
@MainActor
struct SecretAliasPermissionTests {
    private struct AliasGateFixture: OsaurusTool {
        let name = "secret_alias_permission_fixture"
        let description = "Permission alias regression fixture"
        let parameters: JSONValue? = .object(["type": .string("object")])

        func execute(argumentsJSON: String) async throws -> String {
            ToolEnvelope.success(tool: name, text: "should not execute")
        }
    }

    @Test func capabilityAliasUsesCanonicalPermissionPolicy() async {
        let registry = ToolRegistry.shared
        let fixture = AliasGateFixture()
        registry.registerPluginTool(fixture)
        registry.setPolicy(.deny, for: fixture.name)
        defer {
            registry.clearPolicy(for: fixture.name)
            registry.unregister(names: [fixture.name])
        }

        do {
            try await registry.resolvePermissionGate(
                name: "tool/\(fixture.name)",
                argumentsJSON: "{}"
            )
            Issue.record("Capability alias bypassed the canonical tool's deny policy")
        } catch {
            let nsError = error as NSError
            #expect(nsError.code == 6)
            #expect(nsError.localizedDescription.contains(fixture.name))
        }
    }
}

/// Pins the production call sites, not hand-built copies of them. The pure
/// scrubber tests above prove the transformation; these checks fail if a
/// surface later bypasses it and records raw `jsonArguments` again.
struct SecretArgumentSurfaceWiringTests {
    private func source(_ relativePath: String) throws -> String {
        let coreRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tool
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // OsaurusCore
        return try String(
            contentsOf: coreRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    @Test func chatHTTPRegistryAndPluginSurfacesUseRecordedArguments() throws {
        let chat = try source("Views/Chat/ChatView.swift")
        #expect(chat.contains("SecretArgumentScrubber.recordedToolCall("))
        #expect(chat.contains("let recordedArgs = SecretArgumentScrubber.recordedArguments("))

        let http = try source("Networking/HTTPHandler.swift")
        #expect(http.contains("SecretArgumentScrubber.recordedToolCall("))
        #expect(http.contains("arguments: SecretArgumentScrubber.recordedArguments("))

        let registry = try source("Tools/ToolRegistry.swift")
        #expect(registry.contains("let approvalArgumentsJSON = SecretArgumentScrubber.recordedArguments("))
        #expect(registry.contains("let safeArguments = SecretArgumentScrubber.recordedArguments("))

        let plugin = try source("Services/Plugin/PluginHostAPI.swift")
        #expect(plugin.contains("SecretArgumentScrubber.recordedAssistantMessage("))
        #expect(plugin.contains("let recordedArgs = SecretArgumentScrubber.recordedArguments("))
        #expect(plugin.contains("SecretArgumentScrubber.recordedToolCall("))
        #expect(plugin.contains("let material = ToolCallArgumentMaterial.split("))
    }
}

/// End-to-end execution seam: the real secret reaches the tool body while
/// the recorded view stays redacted.
struct SecretArgumentExecutionSeamTests {

    @Test func realSecretReachesExecutionWhileRecordingIsRedacted() async throws {
        let secret = "tok-exec-seam-roundtrip-77"
        let argsDict: [String: Any] = [
            "key": "EVAL_API_TOKEN",
            "description": "d",
            "instructions": "i",
            "value": secret,
        ]
        let argsJSON = String(
            data: try JSONSerialization.data(withJSONObject: argsDict),
            encoding: .utf8
        )!
        let material = ToolCallArgumentMaterial.split(
            toolName: "sandbox_secret_set",
            argumentsJSON: argsJSON
        )
        #expect(material.forExecution.contains(secret))
        #expect(!material.forRecording.contains(secret))
        #expect(material.forRecording.contains("[REDACTED]"))

        try await AgentSecretsKeychain._withInMemoryStoreForTesting {
            let agentId = UUID()
            let tool = SandboxSecretSetTool(agentId: agentId.uuidString)
            // Execution seam receives the unredacted payload.
            let result = try await tool.execute(argumentsJSON: material.forExecution)
            let payload =
                try JSONSerialization.jsonObject(with: Data(result.utf8)) as! [String: Any]
            #expect(payload["ok"] as? Bool == true)
            let stored = payload["result"] as? [String: Any]
            #expect(stored?["stored"] as? Bool == true)
            // Keychain (in-memory under this harness) holds the real secret.
            #expect(
                AgentSecretsKeychain.getSecret(id: "EVAL_API_TOKEN", agentId: agentId) == secret
            )
            // Recorded material still must not contain it.
            #expect(!material.forRecording.contains(secret))
        }
    }
}

/// The secret-prompt marker must survive registry-boundary
/// normalization unwrapped — `SecretPromptParser` keys off the JSON
/// root and the chat loop swaps the marker for a real envelope.
struct SecretPromptMarkerNormalizationTests {

    @Test func promptMarkerIsNotWrappedByNormalization() {
        let marker = SecretToolResult.encode([
            "action": SecretPromptAction.actionKey,
            "key": "API_KEY",
            "description": "the key",
            "instructions": "paste it",
            "agent_id": UUID().uuidString,
        ])
        let normalized = ToolRegistry.normalizeToolResult(marker, tool: "sandbox_secret_set")
        #expect(normalized == marker)
        #expect(SecretPromptParser.parse(normalized) != nil)
    }
}

/// `sandbox_secret_set` with a `value` must report honestly: `stored:true`
/// only when the Keychain write actually succeeded. A silent write failure
/// (keychain-free process, locked keychain) previously returned success,
/// and the model then told the user the secret was available while
/// `sandbox_exec` saw an empty env var.
///
/// `.serialized`: both tests reach the same process-global in-memory
/// store; the wrapper's swap-in must not leak into the failure-path test.
@Suite(.serialized)
struct SecretSetStoreHonestyTests {

    private func execute(_ tool: SandboxSecretSetTool, _ args: [String: Any]) async throws -> [String: Any] {
        let json = String(
            data: try JSONSerialization.data(withJSONObject: args),
            encoding: .utf8
        )!
        let result = try await tool.execute(argumentsJSON: json)
        return try JSONSerialization.jsonObject(with: Data(result.utf8)) as! [String: Any]
    }

    @Test func storedTrueOnlyWhenWriteSucceeds() async throws {
        let agentId = UUID()
        try await AgentSecretsKeychain._withInMemoryStoreForTesting {
            let tool = SandboxSecretSetTool(agentId: agentId.uuidString)
            let payload = try await execute(
                tool,
                [
                    "key": "EVAL_API_TOKEN",
                    "description": "d",
                    "instructions": "i",
                    "value": "tok-roundtrip-42",
                ]
            )
            // Other suites swap the same process-global store in parallel,
            // so only the envelope contract is asserted here; the store
            // roundtrip itself is pinned by the synchronous test below.
            #expect(payload["ok"] as? Bool == true)
            let result = payload["result"] as? [String: Any]
            #expect(result?["stored"] as? Bool == true)
        }
    }

    /// The in-memory store must behave like the real one for the pipeline
    /// pieces around it: save → getFilteredSecrets (exec env injection) and
    /// deleteAllSecrets (per-case eval cleanup) purging only that agent.
    @Test func inMemoryStoreRoundtripAndScopedPurge() {
        AgentSecretsKeychain._withInMemoryStoreForTesting {
            let agent = UUID()
            let bystander = UUID()
            AgentSecretsKeychain.saveSecret("tok-a", id: "EVAL_API_TOKEN", agentId: agent)
            AgentSecretsKeychain.saveSecret("tok-b", id: "OTHER", agentId: bystander)

            #expect(
                AgentSecretsKeychain.getFilteredSecrets(agentId: agent)
                    == ["EVAL_API_TOKEN": "tok-a"]
            )

            AgentSecretsKeychain.deleteAllSecrets(agentId: agent)
            #expect(AgentSecretsKeychain.getFilteredSecrets(agentId: agent).isEmpty)
            // The other agent's secret survives the purge.
            #expect(
                AgentSecretsKeychain.getSecret(id: "OTHER", agentId: bystander) == "tok-b"
            )
        }
    }

    /// Runs only in the keychain-free lane (`OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`
    /// without the in-memory store): there `saveSecret` deterministically
    /// returns false, and the envelope must be ok:false with an actionable
    /// message — never `stored:true`.
    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS"] == "1"
                && ProcessInfo.processInfo.environment["OSAURUS_AGENT_SECRETS_IN_MEMORY"] != "1"
        )
    )
    func failedWriteIsATypedFailureNotStoredTrue() async throws {
        let tool = SandboxSecretSetTool(agentId: UUID().uuidString)
        let payload = try await execute(
            tool,
            [
                "key": "EVAL_API_TOKEN",
                "description": "d",
                "instructions": "i",
                "value": "tok-roundtrip-42",
            ]
        )
        #expect(payload["ok"] as? Bool == false)
        let message = payload["message"] as? String ?? ""
        #expect(message.contains("NOT be available"))
    }
}
