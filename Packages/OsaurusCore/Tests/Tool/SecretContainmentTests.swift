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
