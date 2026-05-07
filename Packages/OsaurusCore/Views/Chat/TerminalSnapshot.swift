//
//  TerminalSnapshot.swift
//  osaurus
//
//  Self-contained snapshot of a finished shell command. Built by the
//  chat-row layer from a `sandbox_exec` / `shell_run` envelope and
//  passed to `TerminalDisplayView.bind(.completed(...))` so the post-
//  completion render uses the same chrome the live-streaming view did.
//
//  Lives in its own file so the routing logic
//  (`TerminalSnapshot.from(toolResult:item:)`) is discoverable from
//  the snapshot type itself rather than buried in the row view.
//

import Foundation

struct TerminalSnapshot: Sendable {
    /// Original command string the user / model issued. Rendered in
    /// the body's first line as `$ <command>`. Already-stripped of
    /// any `set -o pipefail; ` prefix at construction time is fine —
    /// the view also strips it defensively.
    let command: String
    /// Combined output buffer to render. Stdout + stderr concat
    /// (interleaved order is fine — the line tracker doesn't care).
    let output: Data
    /// Process exit code. Non-zero values surface as "exited (N)";
    /// zero as "exited".
    let exitCode: Int32
    /// When true, the status pill reads "terminated (user)" instead
    /// of "exited (N)". Mirrors `LiveExecRegistry.LiveExecStatus.killed`.
    let killedByUser: Bool
    /// Wall-clock duration. Rendered as `m:ss` next to the status
    /// pill. Nil ⇒ omit the duration label entirely.
    let duration: TimeInterval?

    init(
        command: String,
        output: Data,
        exitCode: Int32,
        killedByUser: Bool = false,
        duration: TimeInterval? = nil
    ) {
        self.command = command
        self.output = output
        self.exitCode = exitCode
        self.killedByUser = killedByUser
        self.duration = duration
    }
}

// MARK: - Tool-envelope routing

extension TerminalSnapshot {

    /// Tool names whose envelopes carry the stdout/stderr/exit_code
    /// shape the terminal pane can render. Other tools (file_read,
    /// git_status, MCP tools, …) keep the markdown / JSON fallback.
    private static let shellLikeToolNames: Set<String> = [
        "sandbox_exec", "shell_run",
    ]

    /// Build a snapshot from a tool envelope. Returns nil — and the
    /// caller should fall back to the markdown render — when:
    ///   - the tool name isn't in `shellLikeToolNames`
    ///   - the envelope is an error (model-facing error message must
    ///     stay verbatim)
    ///   - the envelope has no `exit_code` field (not a shell-shaped
    ///     payload after all)
    static func from(toolResult result: String, item: ToolCallItem) -> TerminalSnapshot? {
        guard shellLikeToolNames.contains(item.call.function.name),
            !ToolEnvelope.isError(result),
            let payload = ToolEnvelope.successPayload(result) as? [String: Any]
        else { return nil }

        let exitCode: Int32
        if let n = payload["exit_code"] as? Int {
            exitCode = Int32(clamping: n)
        } else if let n = payload["exit_code"] as? NSNumber {
            exitCode = n.int32Value
        } else {
            return nil
        }

        let stdout = (payload["stdout"] as? String) ?? ""
        let stderr = (payload["stderr"] as? String) ?? ""
        // Interleave: stdout first, stderr appended after a newline if
        // both have content. The line tracker doesn't care about
        // ordering — both streams get rendered through `\r` collapse.
        var combined = stdout
        if !stderr.isEmpty {
            if !combined.isEmpty && !combined.hasSuffix("\n") {
                combined.append("\n")
            }
            combined.append(stderr)
        }

        // Pull the original command out of the call's arguments JSON.
        // Empty fallback prints `$ ` which is still better than nothing.
        var command = ""
        if let data = item.call.function.arguments.data(using: .utf8),
            let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let cmd = args["command"] as? String
        {
            command = cmd
        }

        let killedByUser = (payload["killed_by"] as? String) == "user"

        return TerminalSnapshot(
            command: command,
            output: Data(combined.utf8),
            exitCode: exitCode,
            killedByUser: killedByUser,
            duration: nil  // not currently tracked end-to-end on the item
        )
    }
}
