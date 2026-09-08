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

    /// The cap guards a token budget; multi-byte text must not slip a 3×
    /// larger payload through by having fewer Swift characters. 100,000
    /// CJK characters (~300 KB) are truncated; the ASCII path is unchanged.
    @Test func oversizedMultiByteResultIsCappedByBytes() {
        let cjk = String(repeating: "漢字テスト文章", count: 15_000)  // 105,000 chars, ~315 KB
        #expect(cjk.count > ToolOutputCaps.universalResult)
        let normalized = ToolRegistry.normalizeToolResult(cjk, tool: "mcp_thing")
        let payload = ToolEnvelope.successPayload(normalized) as? [String: Any]
        #expect(payload?["truncated"] as? Bool == true)
        let ascii = String(repeating: "a", count: ToolOutputCaps.universalResult)
        #expect(!ToolRegistry.normalizeToolResult(ascii, tool: "mcp_thing").contains("\"truncated\":true"))
        let smallCjk = String(repeating: "漢字", count: 10_000)  // 20,000 chars, 60 KB: under the cap
        #expect(!ToolRegistry.normalizeToolResult(smallCjk, tool: "mcp_thing").contains("\"truncated\":true"))
    }

    /// A proportional character slice under-counts when the payload is ASCII
    /// at the front and emoji at the back (the kept tail is 4 bytes per
    /// character): the kept text must fit the BYTE cap, whatever the mix.
    @Test func mixedAsciiEmojiResultIsCappedByBytes() {
        let cap = ToolOutputCaps.universalResult
        let mixed = String(repeating: "a", count: 80_000) + String(repeating: "🦖", count: 60_000)  // 140,000 chars, 320,000 bytes
        let normalized = ToolRegistry.normalizeToolResult(mixed, tool: "mcp_thing")
        let payload = ToolEnvelope.successPayload(normalized) as? [String: Any]
        #expect(payload?["truncated"] as? Bool == true)
        let kept = payload?["content"] as? String ?? ""
        #expect(kept.utf8.count <= cap, "kept \(kept.utf8.count) bytes over a \(cap)-byte cap")
        #expect(kept.utf8.count > cap / 2, "the cap should be used, not collapsed")
        #expect(kept.hasPrefix("aaaa") && kept.hasSuffix("🦖"))
    }

    /// A single grapheme can be larger than the whole cap (Codex counterexample:
    /// "x" + 60,000 combining acutes = one Character, 120,001 bytes); character
    /// slicing returns it unchanged, so the byte-exact cut must take over.
    @Test func aSingleHugeGraphemeIsCappedByBytes() {
        let cap = ToolOutputCaps.universalResult
        let huge = "x" + String(repeating: "\u{0301}", count: 60_000)
        #expect(huge.count == 1)
        #expect(huge.utf8.count == 120_001)
        let normalized = ToolRegistry.normalizeToolResult(huge, tool: "mcp_thing")
        let payload = ToolEnvelope.successPayload(normalized) as? [String: Any]
        #expect(payload?["truncated"] as? Bool == true)
        let kept = payload?["content"] as? String ?? ""
        #expect(kept.utf8.count <= cap, "kept \(kept.utf8.count) bytes over a \(cap)-byte cap")
        #expect(kept.utf8.count > cap / 2, "the cap should be used, not collapsed")
        #expect(kept.utf8.first == UInt8(ascii: "x"))  // byte compare: "x" + its surviving marks is one grapheme
        #expect(!kept.contains("\u{FFFD}"), "cuts land on scalar boundaries: no replacement characters")

        // Helper contract: the marker's bytes count against the cap, and a
        // multi-byte tail is cut at a scalar boundary (the last "é" survives whole).
        let tailHeavy = String(repeating: "a", count: 10) + String(repeating: "\u{0301}", count: 50_000) + String(repeating: "é", count: 5)
        let out = HeadTailTruncation.applyByteExact(tailHeavy, byteCap: 1_000, headFraction: 2.0 / 3.0)
        #expect(out.utf8.count <= 1_000, "\(out.utf8.count) bytes")
        // Byte comparisons: the tenth "a" plus its combining marks is ONE grapheme,
        // so `hasPrefix("aaaaaaaaaa")` would be false even for a correct cut.
        #expect(out.utf8.starts(with: "aaaaaaaaaa".utf8) && Array(out.utf8).suffix(2) == Array("é".utf8) && out.contains("[TRUNCATED:"))
        #expect(!out.contains("\u{FFFD}"))
        // A text that fits is returned untouched; a cap smaller than the marker still returns ≤ cap bytes.
        #expect(HeadTailTruncation.applyByteExact("short", byteCap: 100, headFraction: 0.5) == "short")
        #expect(HeadTailTruncation.applyByteExact(huge, byteCap: 40, headFraction: 0.5).utf8.count <= 40 + 120)  // marker floor
    }
}
