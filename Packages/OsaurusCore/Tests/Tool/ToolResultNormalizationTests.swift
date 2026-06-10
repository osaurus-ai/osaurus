//
//  ToolResultNormalizationTests.swift
//  osaurusTests
//
//  Pins the registry-boundary result normalization
//  (`ToolRegistry.normalizeToolResult`): plain-text results wrap into
//  the canonical success envelope, oversized results are head+tail
//  truncated under the universal cap with `truncated: true` and a
//  recovery hint, and error-ness is never laundered into success.
//  Also pins the MCP / sandbox error-kind taxonomy added to
//  `ToolEnvelope.fromError`.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ToolResultNormalizationTests {

    // MARK: - Envelope normalization

    @Test func plainTextWrapsIntoSuccessEnvelope() {
        let normalized = ToolRegistry.normalizeToolResult("plain MCP prose", tool: "mcp_thing")
        #expect(ToolEnvelope.isSuccess(normalized))
        #expect(EnvelopeAssertions.successText(normalized) == "plain MCP prose")
    }

    @Test func existingSuccessEnvelopePassesThroughUntouched() {
        let envelope = ToolEnvelope.success(tool: "file_read", text: "contents")
        #expect(ToolRegistry.normalizeToolResult(envelope, tool: "file_read") == envelope)
    }

    @Test func existingFailureEnvelopePassesThroughUntouched() {
        let envelope = ToolEnvelope.failure(
            kind: .notFound,
            message: "missing.txt not found",
            tool: "file_read"
        )
        #expect(ToolRegistry.normalizeToolResult(envelope, tool: "file_read") == envelope)
    }

    // MARK: - Universal cap

    @Test func oversizedPlainResultIsCappedWithHeadAndTail() {
        let head = "HEAD-MARKER "
        let tail = " TAIL-MARKER"
        let raw = head + String(repeating: "x", count: ToolOutputCaps.universalResult + 10_000) + tail
        let normalized = ToolRegistry.normalizeToolResult(raw, tool: "mcp_dump")

        #expect(normalized.count < raw.count)
        #expect(ToolEnvelope.isSuccess(normalized))

        let payload = EnvelopeAssertions.successPayload(normalized)
        #expect(payload?["truncated"] as? Bool == true)
        #expect(payload?["original_chars"] as? Int == raw.count)
        let content = payload?["content"] as? String ?? ""
        #expect(content.contains("HEAD-MARKER"))
        #expect(content.contains("TAIL-MARKER"))
        #expect(content.contains("[TRUNCATED:"))
        #expect(normalized.contains("exceeded the per-call cap"))
    }

    @Test func oversizedErrorEnvelopeStaysAnError() {
        let giantMessage = String(repeating: "e", count: ToolOutputCaps.universalResult + 5_000)
        let raw = ToolEnvelope.failure(kind: .executionError, message: giantMessage, tool: "boom")
        let normalized = ToolRegistry.normalizeToolResult(raw, tool: "boom")

        #expect(normalized.count < raw.count)
        #expect(ToolEnvelope.isError(normalized))
        #expect(EnvelopeAssertions.failureKind(normalized) == "execution_error")
    }

    @Test func resultsAtTheCapAreUntouched() {
        let raw = String(repeating: "a", count: ToolOutputCaps.universalResult)
        let normalized = ToolRegistry.normalizeToolResult(raw, tool: "t")
        #expect(EnvelopeAssertions.successText(normalized) == raw)
    }

    // MARK: - MCP error taxonomy

    @Test func mcpTimeoutMapsToTimeoutKind() {
        let envelope = ToolEnvelope.fromError(MCPProviderError.timeout, tool: "mcp_tool")
        #expect(EnvelopeAssertions.failureKind(envelope) == "timeout")
        #expect(EnvelopeAssertions.failureRetryable(envelope) == true)
    }

    @Test func mcpNotConnectedMapsToUnavailable() {
        let envelope = ToolEnvelope.fromError(MCPProviderError.notConnected, tool: "mcp_tool")
        #expect(EnvelopeAssertions.failureKind(envelope) == "unavailable")
        #expect(EnvelopeAssertions.failureRetryable(envelope) == false)
    }

    @Test func mcpConnectionFailureIsRetryableUnavailable() {
        let envelope = ToolEnvelope.fromError(
            MCPProviderError.connectionFailed("socket reset"),
            tool: "mcp_tool"
        )
        #expect(EnvelopeAssertions.failureKind(envelope) == "unavailable")
        #expect(EnvelopeAssertions.failureRetryable(envelope) == true)
        #expect(EnvelopeAssertions.failureMessage(envelope)?.contains("socket reset") == true)
    }

    @Test func mcpToolExecutionFailureKeepsExecutionErrorKind() {
        let envelope = ToolEnvelope.fromError(
            MCPProviderError.toolExecutionFailed("upstream said no"),
            tool: "mcp_tool"
        )
        #expect(EnvelopeAssertions.failureKind(envelope) == "execution_error")
        #expect(EnvelopeAssertions.failureMessage(envelope) == "upstream said no")
    }

    // MARK: - Sandbox error taxonomy

    @Test func sandboxIdleTimeoutMapsToTimeoutKind() {
        let envelope = ToolEnvelope.fromError(
            SandboxError.timeout,
            tool: "sandbox_exec"
        )
        #expect(EnvelopeAssertions.failureKind(envelope) == "timeout")
        #expect(EnvelopeAssertions.failureMessage(envelope)?.contains("idle timeout") == true)
    }

    @Test func sandboxUnavailableMapsToUnavailableKind() {
        let envelope = ToolEnvelope.fromError(
            SandboxError.containerNotRunning,
            tool: "sandbox_exec"
        )
        #expect(EnvelopeAssertions.failureKind(envelope) == "unavailable")
        #expect(EnvelopeAssertions.failureRetryable(envelope) == true)
    }

    @Test func sandboxExecFailureKeepsExecutionErrorKind() {
        let envelope = ToolEnvelope.fromError(
            SandboxError.execFailed("exit 127"),
            tool: "sandbox_exec"
        )
        #expect(EnvelopeAssertions.failureKind(envelope) == "execution_error")
    }
}
