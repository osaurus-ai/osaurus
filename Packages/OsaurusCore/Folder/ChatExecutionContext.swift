//
//  ChatExecutionContext.swift
//  osaurus
//
//  TaskLocal context populated by the chat engine before dispatching every
//  tool call so per-session state (the agent todo, file-operation undo
//  log, method telemetry, etc.) can be addressed by the active session.
//

import Foundation

/// TaskLocal storage carrying the active chat session / agent / batch ids
/// down through tool execution. The chat engine seeds these in
/// `ChatSession.send` (and equivalent headless paths) so any tool reading
/// them picks up the right scope without an explicit parameter.
public enum ChatExecutionContext {
    /// The current chat session id whose tool calls are running. Tools that
    /// need per-conversation state (todo store, file-op undo log, method
    /// telemetry) key off this.
    @TaskLocal public static var currentSessionId: String?

    /// The current batch ID for grouped operations (nil for non-batch operations).
    @TaskLocal public static var currentBatchId: UUID?

    /// The agent ID whose context is active for the current execution.
    @TaskLocal public static var currentAgentId: UUID?

    /// Assistant turn dispatching the current tool call. Used by `speak`
    /// to bind TTS playback to the right message bubble
    @TaskLocal public static var currentAssistantTurnId: UUID?

    /// Specific tool invocation id. Used by `speak` so the inline card
    /// can swap its check for a spinner while its audio plays
    @TaskLocal public static var currentToolCallId: String?

    /// The current `agent_runs.id` row (`SchedulerDatabase`) so every
    /// mutation done by `db.*` tools or scheduling tools can stamp its
    /// originating run on the `_changelog` audit trail (spec §1.4,
    /// §8). Bound by `BackgroundTaskManager.dispatchChat` for any
    /// dispatched chat (chat / schedule / watcher / self-scheduled
    /// triggers). `nil` for paths that didn't go through dispatch
    /// (e.g. direct UI edits via `RowEditorSheet`) — the bridge
    /// stamps `_changelog.run_id` as NULL in that case but actor
    /// resolution is independent (see `currentRunActor`).
    @TaskLocal public static var currentRunId: UUID?

    /// String tag identifying who's "driving" the current execution.
    /// One of "agent" (an inference loop), "user" (UI edit), "system"
    /// (background job), or "migration" (migration runner). Used by
    /// `LocalAgentBridge` when stamping `_changelog.actor` on writes
    /// that go through the bridge. When `nil`, `LocalAgentBridge`
    /// falls back to `agent` — UI paths that want `user` stamping
    /// must bind this explicitly.
    @TaskLocal public static var currentRunActor: String?

    /// The current `BackgroundTaskState.id` for the running chat task,
    /// so streaming producers (chat engine, HTTP SSE relay, plugin
    /// host bridge) can forward token-usage deltas into
    /// `BackgroundTaskManager.recordUsage(...)` for mid-stream budget
    /// enforcement (spec §11.3). Bound by
    /// `BackgroundTaskManager.dispatchChat` alongside `currentRunId`.
    @TaskLocal public static var currentBackgroundId: UUID?

    /// Root of the read-only host workspace when the current execution
    /// is in combined sandbox + host-read mode
    /// (`ExecutionMode.sandbox(hostRead: ctx)`). Bound by the send paths
    /// when that mode resolves. The host read tools key off this to
    /// enforce combined-mode-only policy (secret-file refusal) without
    /// changing plain folder-mode behavior — it is `nil` in every other
    /// mode.
    @TaskLocal public static var hostReadOnlyScope: URL?

    /// Per-session override that relaxes the combined-mode secret-file
    /// refusal in `file_read`. Defaults to `false` (refuse secret files
    /// inside the read-only host workspace). A future per-session
    /// setting can bind this `true` to allow reading `.env` / key /
    /// credential files when the user explicitly opts in. Only consulted
    /// when `hostReadOnlyScope` is non-nil.
    @TaskLocal public static var allowHostSecretReads: Bool = false

    /// Sandbox identity for combined mode, letting the unified host
    /// `file_*` tools serve an absolute `/workspace/...` path from the
    /// Linux sandbox (path-routed file access). Bound by
    /// `ToolRegistry.execute` only in combined sandbox + host-read mode;
    /// `nil` everywhere else, so plain folder and plain sandbox modes are
    /// untouched.
    @TaskLocal public static var sandboxReadBridge: SandboxReadBridge?
}
