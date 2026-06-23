//
//  ToolOutputCompressorTests.swift
//  osaurusTests
//
//  Pins the lossless ingest compaction (`ToolOutputCompressor`) and its wiring
//  through `ToolRegistry.normalizeToolResult`:
//  - external pretty JSON is crushed to compact JSON with IDENTICAL semantics
//    (re-parse equal), preserving key order, number lexemes, interior string
//    whitespace, and slash escaping;
//  - a `{`/`[`-leading payload that is NOT valid JSON is never corrupted;
//  - trailing whitespace is stripped while interior whitespace, line breaks,
//    and the final newline survive;
//  - the transform is deterministic and idempotent (KV-prefix safe);
//  - tiny payloads are left untouched.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ToolOutputCompressorTests {

    // A pretty-printed, jq-style JSON fixture comfortably over the 256-byte
    // minimum-length gate, with the semantic edge cases we must preserve:
    //   • interior spaces inside string values ("first  item", "keep   …")
    //   • a non-integer number lexeme (1.0 must not normalize to 1)
    //   • an unescaped slash in a path
    //   • nested objects/arrays, booleans, null
    private static let prettyJSON = """
        {
          "name": "osaurus",
          "ratio": 1.0,
          "path": "/usr/local/bin",
          "note": "keep   internal   spaces",
          "description": "A deliberately long description field so this fixture comfortably exceeds the 256-byte minimum-length gate that ToolOutputCompressor applies before doing any work.",
          "items": [
            { "id": 1, "label": "first  item" },
            { "id": 2, "label": "second", "flag": true, "empty": null }
          ]
        }
        """

    /// Order-independent, deep semantic equality of two JSON strings.
    private func jsonSemanticallyEqual(_ a: String, _ b: String) -> Bool {
        guard
            let da = a.data(using: .utf8), let db = b.data(using: .utf8),
            let oa = try? JSONSerialization.jsonObject(with: da),
            let ob = try? JSONSerialization.jsonObject(with: db)
        else { return false }
        return (oa as AnyObject).isEqual(ob)
    }

    // MARK: - JSON crush: lossless + smaller

    @Test func prettyJSONIsCrushedLosslessly() {
        let crushed = ToolOutputCompressor.compact(Self.prettyJSON)

        #expect(crushed.count < Self.prettyJSON.count)
        #expect(jsonSemanticallyEqual(crushed, Self.prettyJSON))
        // No insignificant whitespace survives outside strings.
        #expect(!crushed.contains("\n"))
        #expect(!crushed.contains(": "))
        #expect(!crushed.contains(", "))
    }

    @Test func crushPreservesInteriorStringWhitespace() {
        let crushed = ToolOutputCompressor.compact(Self.prettyJSON)
        #expect(crushed.contains("first  item"))
        #expect(crushed.contains("keep   internal   spaces"))
    }

    @Test func crushPreservesNumberLexemeAndSlash() {
        let crushed = ToolOutputCompressor.compact(Self.prettyJSON)
        // 1.0 must stay 1.0 (we scan the source, never reserialize).
        #expect(crushed.contains("\"ratio\":1.0"))
        // Unescaped slash preserved verbatim.
        #expect(crushed.contains("/usr/local/bin"))
    }

    @Test func crushIsIdempotent() {
        let once = ToolOutputCompressor.compact(Self.prettyJSON)
        let twice = ToolOutputCompressor.compact(once)
        #expect(once == twice)
    }

    @Test func compactJSONIsReturnedByteIdentical() {
        // Already-compact JSON (no insignificant whitespace), padded over the
        // minimum-length gate. The crush must be a true no-op.
        let pairs = (0 ..< 40).map { "{\"id\":\($0),\"v\":\"item-value-\($0)\"}" }
        let compactJSON = "[" + pairs.joined(separator: ",") + "]"
        #expect(compactJSON.utf8.count >= ToolOutputCompressor.minimumLength)
        #expect(ToolOutputCompressor.compact(compactJSON) == compactJSON)
    }

    // MARK: - JSON crush: safety on non-JSON

    @Test func braceLeadingNonJSONIsNotCorrupted() {
        // Looks like JSON (leading brace) but is not valid JSON. Must NOT be
        // whitespace-crushed — only trailing-stripped — so its words never
        // merge. Padded over the minimum-length gate.
        let notJSON =
            "{ this is not json just some braced prose with   interior   spacing "
            + String(repeating: "and more words to clear the threshold ", count: 6) + "}"
        let out = ToolOutputCompressor.compact(notJSON)
        #expect(out.contains("interior   spacing"))  // interior spaces intact
        #expect(out.contains("this is not json"))  // words never merged
        #expect(!jsonSemanticallyEqual(out, "{}"))
    }

    // MARK: - Trailing-whitespace strip

    @Test func trailingWhitespaceStrippedInteriorPreserved() {
        let raw =
            "line one has a trailing space   \n"
            + "line  two  keeps  interior  spaces\n"
            + "tab trailing\t\t\n"
            + String(repeating: "padding line to exceed the gate\n", count: 8)
        let out = ToolOutputCompressor.compact(raw)

        #expect(out.contains("line  two  keeps  interior  spaces"))  // interior kept
        #expect(out.contains("line one has a trailing space\n"))  // trailing dropped
        #expect(out.contains("tab trailing\n"))  // trailing tabs dropped
        #expect(out.hasSuffix("\n"))  // final newline preserved
        #expect(out.count < raw.count)
    }

    @Test func crlfLineBreaksPreserved() {
        let raw =
            "alpha   \r\nbeta\r\n"
            + String(repeating: "filler line to clear the minimum length\r\n", count: 8)
        let out = ToolOutputCompressor.compact(raw)
        #expect(out.contains("alpha\r\n"))  // trailing spaces gone, CRLF intact
        #expect(out.contains("beta\r\n"))
    }

    @Test func trailingStripIsIdempotent() {
        let raw = String(repeating: "value with trailing space \n", count: 16)
        let once = ToolOutputCompressor.compact(raw)
        let twice = ToolOutputCompressor.compact(once)
        #expect(once == twice)
    }

    // MARK: - Threshold

    @Test func tinyPayloadsAreUntouched() {
        let tiny = "{\n  \"a\": 1\n}"  // valid pretty JSON but under the gate
        #expect(tiny.utf8.count < ToolOutputCompressor.minimumLength)
        #expect(ToolOutputCompressor.compact(tiny) == tiny)
    }

    // MARK: - Wiring through normalizeToolResult

    @Test func normalizeCrushesExternalPrettyJSONUnderCap() {
        let normalized = ToolRegistry.normalizeToolResult(Self.prettyJSON, tool: "shell_run")
        #expect(ToolEnvelope.isSuccess(normalized))

        let text = EnvelopeAssertions.successText(normalized) ?? ""
        // The wrapped text is the crushed form, and it is semantically equal to
        // the original payload.
        #expect(text == ToolOutputCompressor.compact(Self.prettyJSON))
        #expect(text.count < Self.prettyJSON.count)
        #expect(jsonSemanticallyEqual(text, Self.prettyJSON))
    }

    // MARK: - Token-level savings on representative production payloads

    // A jq/REST/MCP-style pretty JSON response — the surface 2C actually
    // targets in production (Osaurus's own envelopes already serialize compact).
    private static let apiResponsePretty = """
        {
          "status": "ok",
          "elapsed_ms": 42,
          "data": {
            "page": 1,
            "per_page": 5,
            "total": 3,
            "users": [
              {
                "id": 1,
                "name": "Ada Lovelace",
                "email": "ada@example.com",
                "roles": ["admin", "engineer"],
                "active": true,
                "last_seen": "2026-06-20T18:04:11Z"
              },
              {
                "id": 2,
                "name": "Alan Turing",
                "email": "alan@example.com",
                "roles": ["engineer"],
                "active": true,
                "last_seen": "2026-06-21T07:55:02Z"
              },
              {
                "id": 3,
                "name": "Grace Hopper",
                "email": "grace@example.com",
                "roles": ["admin"],
                "active": false,
                "last_seen": "2026-05-30T12:00:00Z"
              }
            ]
          }
        }
        """

    @Test func tokenSavingsOnRepresentativePayloads() {
        // 1) External pretty JSON (curl | jq, REST/MCP text).
        let crushed = ToolOutputCompressor.compact(Self.apiResponsePretty)
        let beforeTok = ContextBudgetManager.estimateTokens(for: Self.apiResponsePretty)
        let afterTok = ContextBudgetManager.estimateTokens(for: crushed)
        let pct = 100.0 * (1.0 - Double(afterTok) / Double(beforeTok))
        print(
            "[2C-measure] pretty-JSON: chars \(Self.apiResponsePretty.count)->\(crushed.count), "
                + "tokens \(beforeTok)->\(afterTok) (\(String(format: "%.0f", pct))% fewer)"
        )
        #expect(jsonSemanticallyEqual(crushed, Self.apiResponsePretty))  // lossless
        #expect(afterTok < beforeTok)
        #expect(Double(afterTok) <= 0.85 * Double(beforeTok))  // >=15% — safe floor

        // 2) Log/listing output that carries trailing whitespace (common from
        // shells, formatters, and some loggers).
        let log =
            (1 ... 60).map { "[\($0)] processing batch \($0) status=ok   \t" }
            .joined(separator: "\n") + "\n"
        let stripped = ToolOutputCompressor.compact(log)
        let lBefore = ContextBudgetManager.estimateTokens(for: log)
        let lAfter = ContextBudgetManager.estimateTokens(for: stripped)
        let lpct = 100.0 * (1.0 - Double(lAfter) / Double(lBefore))
        print(
            "[2C-measure] trailing-ws log: chars \(log.count)->\(stripped.count), "
                + "tokens \(lBefore)->\(lAfter) (\(String(format: "%.0f", lpct))% fewer)"
        )
        #expect(lAfter <= lBefore)
        #expect(stripped.count < log.count)
    }

    @Test func normalizeKeepsAlreadyCompactEnvelopeIdentical() {
        // Regression guard: our own envelopes serialize compact, so ingest
        // compaction must be a no-op (byte-identical passthrough).
        let envelope = ToolEnvelope.success(
            tool: "file_read",
            text: "some contents with   interior spaces that must be preserved exactly, "
                + String(repeating: "padded out beyond the minimum length gate. ", count: 6)
        )
        #expect(envelope.utf8.count >= ToolOutputCompressor.minimumLength)
        #expect(ToolRegistry.normalizeToolResult(envelope, tool: "file_read") == envelope)
    }
}
