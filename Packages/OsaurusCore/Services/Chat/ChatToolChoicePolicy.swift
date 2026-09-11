//
//  ChatToolChoicePolicy.swift
//

import Foundation

/// Execution-side enforcement for a forced `tool_choice`. Local chat
/// templates receive the forced function only as a template variable
/// (`tool_choice_name`); a template that ignores it leaves decoding
/// unconstrained, and the model can emit a different tool even when the
/// request's spec contained exactly one (observed live: `toolsInSpec=1`
/// forced to `redact_file`, model emitted `file_read`, and the loop
/// executed it). The gate is armed per model step and consulted before
/// each execution: a mismatched call is refused with a corrective
/// envelope instead of running, and the gate disarms after one wave so
/// follow-up iterations (which return to `.auto`) run unimpeded.
final class ForcedToolChoiceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var forcedName: String?

    /// Arm (or disarm) from the tool choice the request was built with.
    func arm(_ choice: ToolChoiceOption?) {
        let name: String?
        if case .function(let target) = choice {
            name = target.function.name
        } else {
            name = nil
        }
        lock.withLock { forcedName = name }
    }

    /// Nil when the call may execute. Non-nil is the refusal envelope for
    /// a call that ignored the forced choice. A matching call disarms the
    /// gate; a mismatch keeps it armed so every stray call in the same
    /// wave is refused (the next model step re-arms or clears it anyway).
    func violationEnvelope(calledTool: String) -> String? {
        let forced: String? = lock.withLock {
            if forcedName == calledTool { forcedName = nil }
            return forcedName
        }
        guard let forced, forced != calledTool else { return nil }
        return ToolEnvelope.failure(
            kind: .invalidArgs,
            message:
                "This request requires calling `\(forced)` — `\(calledTool)` was not offered for "
                + "this step. Call `\(forced)` with the appropriate arguments instead.",
            tool: calledTool,
            retryable: true
        )
    }
}

/// Ordinary UI chat offers tools without translating prose into API constraints.
/// Explicit API tool choices are handled by the request/adapter path separately.
enum ChatToolChoicePolicy {
    static func resolve(
        tools: [Tool],
        userText _: String,
        attempt _: Int
    ) -> ToolChoiceOption? {
        guard !tools.isEmpty else { return nil }
        return .auto
    }
}
