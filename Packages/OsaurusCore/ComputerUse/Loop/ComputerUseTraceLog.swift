//
//  ComputerUseTraceLog.swift
//  OsaurusCore — Computer Use
//
//  Behavior-neutral, env-gated capture of the exact model response consumed by
//  the Computer Use loop. This distinguishes model-emitted malformed action
//  JSON from delta assembly/schema transport bugs without weakening the action
//  schema or exposing the trace in normal builds.
//

import Foundation

enum ComputerUseTraceLog {
    static let isEnabled =
        ProcessInfo.processInfo.environment["OSAURUS_COMPUTER_USE_TRACE"] == "1"
    static let path = "/tmp/osaurus-computer-use-trace.log"

    private static let queue = DispatchQueue(label: "com.osaurus.computer-use-trace")

    static func record(
        request: ChatCompletionRequest,
        response: ChatCompletionResponse,
        elapsedSeconds: TimeInterval
    ) {
        guard isEnabled else { return }
        var lines: [String] = []
        let stamp = ISO8601DateFormatter().string(from: Date())
        lines.append(
            "==== computer-use model step \(stamp) model=\(request.model) "
                + "requested_enable_thinking=\(String(reflecting: request.enable_thinking)) "
                + String(format: "elapsed=%.2fs ====", elapsedSeconds)
        )
        lines.append("request: \(request.messages.count) message(s)")
        for (index, message) in request.messages.enumerated() {
            var line = "  [\(index)] role=\(message.role) chars=\(message.content?.count ?? 0)"
            if message.role == "tool", let content = message.content {
                line += " content=\(String(reflecting: content))"
            }
            if let calls = message.tool_calls, !calls.isEmpty {
                line += " tool_calls=\(calls.count)"
            }
            lines.append(line)
        }
        let usage = response.usage
        lines.append(
            "response: finish=\(response.choices.first?.finish_reason ?? "(no choice)") "
                + "prompt_tokens=\(usage.prompt_tokens) completion_tokens=\(usage.completion_tokens)"
                + (usage.tokens_per_second.map { String(format: " tok/s=%.1f", $0) } ?? "")
        )
        if let message = response.choices.first?.message {
            lines.append("content: \(String(reflecting: message.content ?? ""))")
            lines.append("reasoning_chars: \(message.reasoning_content?.count ?? 0)")
            for (index, call) in (message.tool_calls ?? []).enumerated() {
                lines.append(
                    "tool_call[\(index)]: name=\(call.function.name) "
                        + "arguments=\(String(reflecting: call.function.arguments))"
                )
            }
        }
        write(lines.joined(separator: "\n"))
    }

    /// Capture the post-policy dispatch state that actually reaches prompt
    /// rendering. The Computer Use loop's request can legitimately carry nil
    /// while ChatEngine applies the agent/tool default; logging only the raw
    /// request made an effective false look like an unproven nil.
    static func recordEffectiveDispatch(
        request: ChatCompletionRequest,
        modelOptions: [String: ModelOptionValue]
    ) {
        guard isEnabled,
            request.tools?.contains(where: { $0.function.name == AgentAction.toolName }) == true
        else { return }
        let options = modelOptions.keys.sorted().map { key in
            "\(key)=\(String(describing: modelOptions[key]!))"
        }.joined(separator: ",")
        write(
            "dispatch model=\(request.model) is_agent=\(request.isAgentRequest) "
                + "requested_enable_thinking=\(String(reflecting: request.enable_thinking)) "
                + "effective_options={\(options)}"
        )
    }

    /// Capture the parser's raw tool invocation before ChatEngine coerces and
    /// schema-validates its arguments. This proves whether a malformed field
    /// was model/parser output or was introduced by canonicalization.
    static func recordRawInvocation(toolName: String, arguments: String) {
        guard isEnabled, toolName == AgentAction.toolName else { return }
        write("raw_invocation tool=\(toolName) arguments=\(String(reflecting: arguments))")
    }

    /// Record the effective autonomy-gate decision, including the classified
    /// effect that produced it. This distinguishes a real policy bypass from a
    /// model retry or a confirmation-card interaction without changing behavior.
    static func recordGate(
        step: Int,
        action: String,
        effect: EffectClass,
        appName: String?,
        decision: String
    ) {
        guard isEnabled else { return }
        write(
            "gate step=\(step) action=\(String(reflecting: action)) "
                + "effect=\(effect.rawValue) app=\(String(reflecting: appName)) "
                + "decision=\(decision)"
        )
    }

    static func recordGateResolution(step: Int, action: String, approved: Bool) {
        guard isEnabled else { return }
        write(
            "gate_resolution step=\(step) action=\(String(reflecting: action)) "
                + "approved=\(approved)"
        )
    }

    static func recordConfirmationQueue(
        toolCallId: String,
        requestId: UUID,
        event: String,
        preview: ActionPreview,
        approved: Bool? = nil
    ) {
        guard isEnabled else { return }
        write(
            "confirm_queue event=\(event) tool_call_id=\(toolCallId) "
                + "request_id=\(requestId.uuidString) app=\(String(reflecting: preview.appName)) "
                + "effect=\(preview.effect.rawValue) approved=\(String(reflecting: approved))"
        )
    }

    private static func write(_ message: String) {
        queue.async {
            guard let data = (message + "\n").data(using: .utf8) else { return }
            let url = URL(fileURLWithPath: path)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
