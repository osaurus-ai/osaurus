//
//  AppleScriptTraceLog.swift
//  OsaurusCore — AppleScript Computer Use
//
//  Env-gated raw model-step trace for the AppleScript loop. OFF by default;
//  enabled with `OSAURUS_APPLESCRIPT_TRACE=1`. For every model step it appends
//  the exact response surface the loop scored — visible content, each raw
//  tool-call arguments string, finish reason, and token usage — plus the
//  request's message shapes, to a single append-only file in /tmp.
//
//  This is an INVESTIGATION AID (MODEL_ISSUES_TRIAGE Issue 3: multi-step
//  marker-leak / degeneration): it observes, it never alters the request or
//  the response. All file I/O runs on a dedicated serial queue so tracing
//  never blocks the inference path (mirrors PrefillDebugLog).
//

import Foundation

/// Append-only `/tmp` trace of AppleScript-loop model steps.
enum AppleScriptTraceLog {

    /// Resolved once: enabled only when `OSAURUS_APPLESCRIPT_TRACE=1`.
    static let isEnabled =
        ProcessInfo.processInfo.environment["OSAURUS_APPLESCRIPT_TRACE"] == "1"

    /// Stable destination so repeated runs accumulate; each step writes a
    /// banner line so steps are easy to find.
    static let path = "/tmp/osaurus-applescript-trace.log"

    private static let queue = DispatchQueue(label: "com.osaurus.applescript-trace")

    /// Record the behavior-neutral dispatch context that selected app
    /// knowledge and grounded a working-document reference. Values of user
    /// literals remain out of the trace; only their keys are recorded.
    static func recordDispatchContext(
        frontmost: String?,
        targetApps: [String],
        workingReference: Bool,
        taskGrounded: Bool,
        literalKeys: [String]
    ) {
        guard isEnabled else { return }
        write(
            "dispatch_context frontmost=\(String(reflecting: frontmost)) "
                + "target_apps=\(targetApps) working_reference=\(workingReference) "
                + "task_grounded=\(taskGrounded) literal_keys=\(literalKeys)"
        )
    }

    /// Record the effective user setting and the gate selected for a proposed
    /// script. This is trace-only evidence that the UI setting reached the
    /// runtime; it never changes the decision.
    static func recordGate(
        mode: AppleScriptRunMode,
        executionMode: AppleScriptExecutionMode,
        effect: EffectClass,
        verifying: Bool,
        decision: String
    ) {
        guard isEnabled else { return }
        write(
            "gate mode=\(mode.rawValue) execution_mode=\(executionMode.rawValue) "
                + "effect=\(String(describing: effect)) verifying=\(verifying) "
                + "decision=\(decision)"
        )
    }

    /// Record the post-policy model options that actually reach the template.
    /// The loop's raw request may legitimately carry `enable_thinking=nil`
    /// while ChatEngine applies the direct-agent default. Keeping this next to
    /// the raw step trace prevents an omitted wire value from being mistaken
    /// for reasoning-on execution during live UI proof.
    static func recordEffectiveDispatch(
        request: ChatCompletionRequest,
        modelOptions: [String: ModelOptionValue]
    ) {
        guard isEnabled,
            request.tools?.contains(where: {
                $0.function.name == AppleScriptAction.toolName
            }) == true
        else { return }
        let options = modelOptions.keys.sorted().map { key in
            "\(key)=\(String(describing: modelOptions[key]!))"
        }.joined(separator: ",")
        write(
            "effective_dispatch model=\(request.model) is_agent=\(request.isAgentRequest) "
                + "requested_enable_thinking=\(String(reflecting: request.enable_thinking)) "
                + "effective_options={\(options)}"
        )
    }

    /// Record one model step: request message shapes + the full raw response
    /// surface (content, tool-call arguments, finish reason, usage).
    static func record(
        request: ChatCompletionRequest,
        response: ChatCompletionResponse,
        elapsedSeconds: TimeInterval? = nil
    ) {
        guard isEnabled else { return }
        var lines: [String] = []
        let stamp = ISO8601DateFormatter().string(from: Date())
        let elapsed = elapsedSeconds.map { String(format: " elapsed=%.1fs", $0) } ?? ""
        let sampling =
            request.samplingParametersAreImplicit
            ? ""
            : (request.temperature.map { String(format: " temp=%.2f(explicit)", $0) } ?? "")
        lines.append(
            "==== applescript model step \(stamp) model=\(request.model) "
                + "requested_enable_thinking=\(String(reflecting: request.enable_thinking))"
                + "\(sampling)\(elapsed) ===="
        )
        // Request shape: role + size per message (content stays out of the
        // trace by default to keep the file readable; the last tool result is
        // included verbatim because it is the step's distinguishing input).
        let messages = request.messages
        lines.append("request: \(messages.count) message(s)")
        for (index, message) in messages.enumerated() {
            let chars = message.content?.count ?? 0
            var line = "  [\(index)] role=\(message.role) chars=\(chars)"
            if message.role == "tool", let content = message.content {
                line += " content=\(String(reflecting: content))"
            }
            if let calls = message.tool_calls, !calls.isEmpty {
                line += " tool_calls=\(calls.count)"
            }
            lines.append(line)
        }
        let usage = response.usage
        let finish = response.choices.first.map(\.finish_reason) ?? "(no choice)"
        lines.append(
            "response: finish=\(finish) prompt_tokens=\(usage.prompt_tokens) "
                + "completion_tokens=\(usage.completion_tokens)"
                + (usage.tokens_per_second.map { String(format: " tok/s=%.1f", $0) } ?? "")
        )
        if let message = response.choices.first?.message {
            // `String(reflecting:)` escapes control characters so pads /
            // markers / empty output are unambiguous in the trace.
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
