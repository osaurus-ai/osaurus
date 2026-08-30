//
//  ClaudeCodeStreamDecoder.swift
//  osaurus
//
//  Decodes Claude Code's `--output-format stream-json` NDJSON into typed
//  events. Pure and synchronous so it unit-tests against recorded fixtures
//  without spawning anything.
//
//  Wire shape (verified against CLI 2.1.212). Each line is one JSON object:
//
//    {"type":"system","subtype":"init", ...}          session id, tool list
//    {"type":"system","subtype":"status", ...}        "requesting", ...
//    {"type":"rate_limit_event","rate_limit_info":{...}}
//    {"type":"stream_event","event":{ <raw Anthropic SSE event> }}
//    {"type":"assistant","message":{...}}             COMPLETE message — ignored
//    {"type":"user","message":{"content":[{"type":"tool_result",...}]}}
//    {"type":"result","subtype":"success", ...}       final usage + stop reason
//
//  Two traps that cost visible correctness if missed:
//
//  1. `type: "assistant"` repeats the whole message that the `stream_event`
//     deltas already carried. Emitting both doubles every answer.
//  2. `content_block_delta` is a union. `signature_delta` carries a base64
//     thinking signature and `input_json_delta` carries raw tool arguments —
//     neither is prose, and both must be dropped rather than treated as text.
//

import Foundation

/// One decoded event from the CLI stream.
public enum ClaudeCodeStreamEvent: Sendable, Equatable {
    /// Visible assistant prose.
    case text(String)
    /// Reasoning / extended-thinking prose.
    case reasoning(String)
    /// Sanitized tool trace — name, phase, and error state only. Never args
    /// or results; those stay inside the CLI.
    case toolTrace(StreamingAgentToolHint.Trace)
    /// Terminal usage frame.
    case stats(outputTokens: Int, tokensPerSecond: Double, stopReason: String?)
    /// Subscription rate-limit notice. Surfaced verbatim rather than retried.
    case rateLimit(status: String, utilization: Double, resetsAt: Date?)
    /// The CLI reported a failed turn.
    case failure(String)
}

/// Incremental NDJSON → `ClaudeCodeStreamEvent` decoder.
///
/// Not thread-safe by design: one decoder belongs to one subprocess, driven
/// from that process's single reader.
public struct ClaudeCodeStreamDecoder: Sendable {
    /// `tool_use` id → tool name, so the later `tool_result` (which carries
    /// only `tool_use_id`) can be reported with a human-readable name.
    private var toolNamesByCallId: [String: String] = [:]
    /// Captured from `message_delta` because the terminal `result` frame does
    /// not always repeat it.
    private var lastStopReason: String?
    /// Session id from the `init` frame; diagnostics only.
    private(set) public var sessionId: String?

    public init() {}

    /// Decode one NDJSON line. Returns zero or more events.
    ///
    /// Unparseable or unrecognized lines yield `[]` rather than throwing: the
    /// CLI's schema grows between releases and an unknown frame is not a
    /// reason to fail a user's turn.
    public mutating func decode(line: Data) -> [ClaudeCodeStreamEvent] {
        guard !line.isEmpty,
            let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let type = root["type"] as? String
        else { return [] }

        switch type {
        case "stream_event":
            guard let event = root["event"] as? [String: Any] else { return [] }
            return decodeStreamEvent(event)

        case "user":
            return decodeToolResults(root)

        case "result":
            return decodeResult(root)

        case "rate_limit_event":
            return decodeRateLimit(root)

        case "system":
            if (root["subtype"] as? String) == "init", let id = root["session_id"] as? String {
                sessionId = id
            }
            return []

        // `assistant` is the assembled duplicate of the deltas we already
        // emitted. Dropping it is load-bearing, not an omission.
        default:
            return []
        }
    }

    // MARK: - stream_event

    private mutating func decodeStreamEvent(_ event: [String: Any]) -> [ClaudeCodeStreamEvent] {
        switch event["type"] as? String {
        case "content_block_start":
            guard let block = event["content_block"] as? [String: Any],
                (block["type"] as? String) == "tool_use",
                let name = block["name"] as? String
            else { return [] }
            let callId = block["id"] as? String
            if let callId { toolNamesByCallId[callId] = name }
            return [
                .toolTrace(
                    StreamingAgentToolHint.Trace(
                        phase: "started",
                        name: name,
                        callId: callId,
                        isError: false,
                        endRun: false
                    )
                )
            ]

        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any] else { return [] }
            switch delta["type"] as? String {
            case "text_delta":
                guard let text = delta["text"] as? String, !text.isEmpty else { return [] }
                return [.text(text)]
            case "thinking_delta":
                guard let text = delta["thinking"] as? String, !text.isEmpty else { return [] }
                return [.reasoning(text)]
            // `signature_delta` (base64 thinking signature) and
            // `input_json_delta` (raw tool arguments) are deliberately dropped.
            default:
                return []
            }

        case "message_delta":
            if let delta = event["delta"] as? [String: Any],
                let stop = delta["stop_reason"] as? String
            {
                lastStopReason = stop
            }
            return []

        default:
            return []
        }
    }

    // MARK: - tool results

    private mutating func decodeToolResults(_ root: [String: Any]) -> [ClaudeCodeStreamEvent] {
        guard let message = root["message"] as? [String: Any],
            let blocks = message["content"] as? [[String: Any]]
        else { return [] }

        var events: [ClaudeCodeStreamEvent] = []
        for block in blocks where (block["type"] as? String) == "tool_result" {
            let callId = block["tool_use_id"] as? String
            let name = callId.flatMap { toolNamesByCallId[$0] } ?? ""
            events.append(
                .toolTrace(
                    StreamingAgentToolHint.Trace(
                        phase: "completed",
                        name: name,
                        callId: callId,
                        isError: (block["is_error"] as? Bool) ?? false,
                        endRun: false
                    )
                )
            )
        }
        return events
    }

    // MARK: - result

    private mutating func decodeResult(_ root: [String: Any]) -> [ClaudeCodeStreamEvent] {
        var events: [ClaudeCodeStreamEvent] = []

        // Close out any tool activity the UI is still showing as running.
        events.append(
            .toolTrace(
                StreamingAgentToolHint.Trace(
                    phase: "completed",
                    name: "",
                    callId: nil,
                    isError: false,
                    endRun: true
                )
            )
        )

        let usage = root["usage"] as? [String: Any]
        let outputTokens = (usage?["output_tokens"] as? Int) ?? 0
        // Prefer API generation time over end-to-end CLI wall time so startup,
        // MCP work, and local tool execution do not depress the displayed
        // decode rate. Older versions only report `duration_ms`.
        let apiDurationMs =
            (root["duration_api_ms"] as? Double)
            ?? Double(root["duration_api_ms"] as? Int ?? 0)
        let wallDurationMs =
            (root["duration_ms"] as? Double)
            ?? Double(root["duration_ms"] as? Int ?? 0)
        let durationMs = apiDurationMs > 0 ? apiDurationMs : wallDurationMs
        let tps = durationMs > 0 ? Double(outputTokens) / (durationMs / 1000.0) : 0

        let stopReason = (root["stop_reason"] as? String) ?? lastStopReason
        events.append(
            .stats(outputTokens: outputTokens, tokensPerSecond: tps, stopReason: stopReason)
        )

        if (root["is_error"] as? Bool) == true {
            let detail =
                (root["result"] as? String)
                ?? (root["api_error_status"] as? String)
                ?? (root["subtype"] as? String)
                ?? "unknown error"
            events.append(.failure(detail))
        }

        return events
    }

    // MARK: - rate limit

    private func decodeRateLimit(_ root: [String: Any]) -> [ClaudeCodeStreamEvent] {
        guard let info = root["rate_limit_info"] as? [String: Any] else { return [] }
        let status = (info["status"] as? String) ?? "unknown"
        let utilization = (info["utilization"] as? Double) ?? 0
        let resetsAt = (info["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return [.rateLimit(status: status, utilization: utilization, resetsAt: resetsAt)]
    }
}
