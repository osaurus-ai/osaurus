//
//  ToolEnvelopeTests.swift
//  osaurusTests
//
//  Contract tests for `ToolEnvelope` — the canonical success/failure
//  shapes every tool emits. Pins down the on-the-wire JSON keys and the
//  detection helpers (`isError`, `isSuccess`, `successPayload`,
//  `failureMessage`) that ChatView / HTTPHandler rely on to distinguish
//  outcomes.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct ToolEnvelopeTests {

    // MARK: - Failure shape

    @Test func failureHasCanonicalKeys() throws {
        let json = ToolEnvelope.failure(
            kind: .invalidArgs,
            message: "missing `path`",
            field: "path",
            expected: "relative path",
            tool: "sandbox_write_file"
        )
        let dict = try parse(json)
        #expect(dict["ok"] as? Bool == false)
        #expect(dict["kind"] as? String == "invalid_args")
        #expect(dict["message"] as? String == "missing `path`")
        #expect(dict["field"] as? String == "path")
        #expect(dict["expected"] as? String == "relative path")
        #expect(dict["tool"] as? String == "sandbox_write_file")
        #expect(dict["retryable"] as? Bool == true)
    }

    @Test func failureOmitsOptionalFieldsWhenUnset() throws {
        let json = ToolEnvelope.failure(kind: .executionError, message: "boom")
        let dict = try parse(json)
        #expect(dict["ok"] as? Bool == false)
        #expect(dict["field"] == nil)
        #expect(dict["expected"] == nil)
        #expect(dict["tool"] == nil)
    }

    @Test func retryableDefaultsByKind() {
        let cases: [(ToolEnvelope.Kind, Bool)] = [
            (.invalidArgs, true),
            (.timeout, true),
            (.executionError, true),
            (.unavailable, true),
            (.rejected, false),
            (.toolNotFound, false),
            (.userDenied, false),
        ]
        for (kind, expected) in cases {
            let json = ToolEnvelope.failure(kind: kind, message: "m")
            let dict = try! parse(json)
            #expect(dict["retryable"] as? Bool == expected, "kind=\(kind.rawValue)")
        }
    }

    @Test func retryableOverrideWins() throws {
        let json = ToolEnvelope.failure(kind: .rejected, message: "try again", retryable: true)
        let dict = try parse(json)
        #expect(dict["retryable"] as? Bool == true)
    }

    // MARK: - Success shape

    @Test func successWithStructuredResult() throws {
        let json = ToolEnvelope.success(
            tool: "sandbox_read_file",
            result: ["path": "/h/a", "size": 42],
            warnings: ["slow disk"]
        )
        let dict = try parse(json)
        #expect(dict["ok"] as? Bool == true)
        #expect(dict["tool"] as? String == "sandbox_read_file")
        let result = dict["result"] as? [String: Any]
        #expect(result?["path"] as? String == "/h/a")
        #expect(result?["size"] as? Int == 42)
        #expect(dict["warnings"] as? [String] == ["slow disk"])
    }

    @Test func successWithTextConvenience() throws {
        let json = ToolEnvelope.success(tool: "file_tree", text: "./\n├── a\n└── b")
        let dict = try parse(json)
        let result = dict["result"] as? [String: Any]
        #expect(result?["text"] as? String == "./\n├── a\n└── b")
    }

    @Test func successDoesNotEscapeSlashesInToolReplayJSON() throws {
        let text = "     1| #!/usr/bin/env python3\n"
        let json = ToolEnvelope.success(tool: "file_read", text: text)

        #expect(json.contains(#"\/"#) == false)
        #expect(json.contains("#!/usr/bin/env python3"))
        let payload = try #require(ToolEnvelope.successPayload(json) as? [String: Any])
        #expect(payload["text"] as? String == text)
    }

    @Test func failureDoesNotEscapeSlashesInToolReplayJSON() throws {
        let json = ToolEnvelope.failure(
            kind: .executionError,
            message: "File not found: /Users/eric/Desktop/testmandel/mandelbrot.py",
            tool: "file_read"
        )

        #expect(json.contains(#"\/"#) == false)
        #expect(json.contains("/Users/eric/Desktop/testmandel/mandelbrot.py"))
        #expect(ToolEnvelope.failureMessage(json) == "File not found: /Users/eric/Desktop/testmandel/mandelbrot.py")
    }

    // MARK: - Detection

    @Test func isErrorDetectsNewShape() {
        let json = ToolEnvelope.failure(kind: .timeout, message: "slow")
        #expect(ToolEnvelope.isError(json))
        #expect(!ToolEnvelope.isSuccess(json))
    }

    @Test func isSuccessDetectsNewShape() {
        let json = ToolEnvelope.success(tool: "t", text: "ok")
        #expect(ToolEnvelope.isSuccess(json))
        #expect(!ToolEnvelope.isError(json))
    }

    @Test func isErrorDetectsLegacyPrefixes() {
        #expect(ToolEnvelope.isError("[REJECTED] permission denied"))
        #expect(ToolEnvelope.isError("[TIMEOUT] 30s"))
    }

    /// Detection only scans a bounded head of the payload, so the `ok` marker
    /// must lead the envelope. A failure with a message far larger than that
    /// window would otherwise sort `ok` past it (keys are canonically sorted)
    /// and be mis-read as a non-error — which laundered oversized errors into
    /// successes at the registry boundary.
    @Test func isErrorDetectsFailureWithVeryLargeMessage() {
        let bigMessage = String(repeating: "e", count: 200_000)
        let json = ToolEnvelope.failure(kind: .executionError, message: bigMessage, tool: "boom")
        #expect(json.hasPrefix("{\"ok\":false"))
        #expect(ToolEnvelope.isError(json))
        #expect(!ToolEnvelope.isSuccess(json))
    }

    /// Symmetric guard for success envelopes carrying a large payload.
    @Test func isSuccessDetectsEnvelopeWithVeryLargePayload() {
        let bigText = String(repeating: "x", count: 200_000)
        let json = ToolEnvelope.success(tool: "dump", text: bigText)
        #expect(json.hasPrefix("{\"ok\":true"))
        #expect(ToolEnvelope.isSuccess(json))
        #expect(!ToolEnvelope.isError(json))
    }

    @Test func isErrorDetectsLegacyEnvelope() {
        // Legacy `ToolErrorEnvelope` output — now routes through the shim
        // which emits the new shape, but third-party callers that still
        // hand-roll the old shape `{"error":"...","reason":"...","retryable":...}`
        // must still be recognised as errors.
        let legacy = #"{"error":"timeout","reason":"slow","retryable":true}"#
        #expect(ToolEnvelope.isError(legacy))
    }

    @Test func isErrorIgnoresOrdinaryJSON() {
        #expect(!ToolEnvelope.isError(#"{"value": 42}"#))
        #expect(!ToolEnvelope.isError("plain text"))
        #expect(!ToolEnvelope.isError(""))
    }

    @Test func successPayloadExtraction() {
        let json = ToolEnvelope.success(
            tool: "t",
            result: ["k": "v"]
        )
        let payload = ToolEnvelope.successPayload(json) as? [String: Any]
        #expect(payload?["k"] as? String == "v")
    }

    @Test func successPayloadReturnsNilForFailure() {
        let json = ToolEnvelope.failure(kind: .invalidArgs, message: "m")
        #expect(ToolEnvelope.successPayload(json) == nil)
    }

    @Test func failureMessageExtraction() {
        let json = ToolEnvelope.failure(kind: .invalidArgs, message: "bad path")
        #expect(ToolEnvelope.failureMessage(json) == "bad path")
    }

    // MARK: - fromError mapping

    @Test func fromErrorMapsFolderInvalidArgs() throws {
        let env = ToolEnvelope.fromError(
            FolderToolError.invalidArguments("missing `path`"),
            tool: "file_read"
        )
        let dict = try parse(env)
        #expect(dict["kind"] as? String == "invalid_args")
    }

    @Test func fromErrorMapsFolderPathOutsideRoot() throws {
        let env = ToolEnvelope.fromError(
            FolderToolError.pathOutsideRoot("../etc/passwd"),
            tool: "file_read"
        )
        let dict = try parse(env)
        #expect(dict["kind"] as? String == "invalid_args")
        #expect(dict["field"] as? String == "path")
        #expect((dict["message"] as? String)?.contains("../etc/passwd") == true)
    }

    @Test func fromErrorMapsFolderFileNotFound() throws {
        let env = ToolEnvelope.fromError(
            FolderToolError.fileNotFound("README.md"),
            tool: "file_read"
        )
        let dict = try parse(env)
        // Distinct `not_found` kind so the harness can classify the result
        // as a not-found transition (steer to the last listing) instead of a
        // generic execution error.
        #expect(dict["kind"] as? String == "not_found")
        #expect(dict["retryable"] as? Bool == false)
    }

    @Test func fromErrorMapsRegistryUserDenied() throws {
        let nserr = NSError(
            domain: "ToolRegistry",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "User denied execution"]
        )
        let env = ToolEnvelope.fromError(nserr, tool: "git_commit")
        let dict = try parse(env)
        #expect(dict["kind"] as? String == "user_denied")
        #expect(dict["retryable"] as? Bool == false)
    }

    @Test func fromErrorMapsRegistryPolicyRejected() throws {
        let nserr = NSError(
            domain: "ToolRegistry",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Policy deny"]
        )
        let env = ToolEnvelope.fromError(nserr, tool: "shell_run")
        let dict = try parse(env)
        #expect(dict["kind"] as? String == "rejected")
        #expect(dict["retryable"] as? Bool == false)
    }

    @Test func fromErrorDefaultsToExecutionError() throws {
        struct RandomError: Error {
            var localizedDescription: String { "boom" }
        }
        let env = ToolEnvelope.fromError(RandomError(), tool: "x")
        let dict = try parse(env)
        #expect(dict["kind"] as? String == "execution_error")
    }

    // MARK: - Helpers

    private func parse(_ json: String) throws -> [String: Any] {
        let data = try #require(json.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
