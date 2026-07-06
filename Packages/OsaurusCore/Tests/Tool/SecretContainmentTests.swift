//
//  SecretContainmentTests.swift
//  osaurusTests
//
//  Pins the two secret-containment layers added by the round-2 audit:
//   - `SecretScrubber`: known secret VALUES are redacted from exec
//     stdout/stderr before they reach the model's context.
//   - `SecretArgumentScrubber`: the direct-`value` path of
//     `sandbox_secret_set` never persists the secret in the recorded
//     tool-call arguments.
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

    @Test func valueIsRedactedForSandboxSecretSet() throws {
        let args = """
            {"key":"API_KEY","description":"d","instructions":"i","value":"sk-live-12345"}
            """
        let scrubbed = SecretArgumentScrubber.scrubForPersistence(
            toolName: "sandbox_secret_set",
            argumentsJSON: args
        )
        #expect(!scrubbed.contains("sk-live-12345"))

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
        let args = #"{"key":"API_KEY","value":"[REDACTED]"}"#
        let scrubbed = SecretArgumentScrubber.scrubForPersistence(
            toolName: "sandbox_secret_set",
            argumentsJSON: args
        )
        #expect(scrubbed == args)
    }

    @Test func malformedArgumentsPassThrough() {
        let args = "not json at all"
        let scrubbed = SecretArgumentScrubber.scrubForPersistence(
            toolName: "sandbox_secret_set",
            argumentsJSON: args
        )
        #expect(scrubbed == args)
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
