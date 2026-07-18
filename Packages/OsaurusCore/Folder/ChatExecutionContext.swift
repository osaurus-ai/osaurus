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

    /// What this request is allowed to EXECUTE, as opposed to what it merely exposed.
    ///
    /// See ``ToolExecutionScope``. `nil` means no scope was published — the surface gates its own
    /// tools and the registry behaves exactly as it did before. That is deliberately permissive:
    /// binding it on every entrypoint at once would risk breaking a surface we cannot gate live,
    /// and a guard that breaks working features is not an improvement. The chat/agent loop — where
    /// an unexposed tool was actually observed executing — publishes one.
    @TaskLocal static var toolExecutionScope: ToolExecutionScope?

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

    /// Headless auto-approval for `.ask`-gated tools. Bound `true` only by
    /// the eval harness (`AgentLoopEvaluator`), whose runs operate on
    /// isolated temp workspaces with no UI run loop — presenting the
    /// approval `NSPanel` from the eval CLI would hang the run on a card
    /// nobody can click. Never bound by chat/HTTP/plugin surfaces.
    ///
    /// Scope is deliberately narrow: it skips ONLY the `.ask` user prompt
    /// in `ToolRegistry.runPermissionGate`. `.deny` policies still throw,
    /// and missing system permissions (automation/accessibility) still
    /// block. Module-internal so out-of-module callers (HTTP clients,
    /// plugins, eval kit) cannot bind it.
    @TaskLocal static var autoApproveToolPrompts: Bool = false

    /// Headless auto-DENIAL for `.ask`-gated tools — the counterpart to
    /// `autoApproveToolPrompts`. Bound `true` by eval lanes that must NOT
    /// execute state-mutating `.ask` tools yet also cannot present the
    /// approval `NSPanel` (no UI run loop). The `capability_claims` lane
    /// uses it: those cases score the model's tool SELECTION and honest
    /// claims, NOT the side effects of running configure/agent WRITE tools.
    /// Auto-approving them instead (as `default_agent` intentionally does)
    /// would let the model really execute `osaurus_agent`/configure writes
    /// mid-eval, mutating global agent + scheduler state and deadlocking a
    /// later case's isolated-agent teardown. Denying records the call and
    /// feeds the model a typed "denied by policy" envelope — the honest
    /// representation of "no human approved" in a headless run — so the
    /// loop continues without a hang, a 25s timeout, or a mutation.
    ///
    /// Only consulted when `autoApproveToolPrompts` is false (approve wins).
    /// Same narrow scope as approve: it resolves ONLY the `.ask` user prompt
    /// in `runPermissionGate`; `.deny` and missing system permissions are
    /// unaffected. Module-internal so out-of-module callers cannot bind it.
    @TaskLocal static var denyUnapprovedToolPrompts: Bool = false

    /// Per-session override that relaxes the combined-mode secret-file
    /// refusal in `file_read`. Defaults to `false` (refuse secret files
    /// inside the read-only host workspace). A future per-session
    /// setting can bind this `true` to allow reading `.env` / key /
    /// credential files when the user explicitly opts in. Only consulted
    /// when `hostReadOnlyScope` is non-nil.
    @TaskLocal public static var allowHostSecretReads: Bool = false

    /// Combined-mode write grant: `true` when the active agent's
    /// `allowHostFolderWrites` opt-in is on for the current execution.
    /// Bound by `ToolRegistry.execute` alongside `hostReadOnlyScope` so
    /// tool BODIES that route by path (`file_copy`) can gate host-bound
    /// destinations at execute time — schema visibility alone can't,
    /// because the same tool serves both directions. `false` in every
    /// other mode (and in read-only combined mode).
    @TaskLocal public static var allowHostFolderWrites: Bool = false

    /// Sandbox identity for combined mode, letting the unified host
    /// `file_*` tools serve an absolute `/workspace/...` path from the
    /// Linux sandbox (path-routed file access). Bound by
    /// `ToolRegistry.execute` only in combined sandbox + host-read mode;
    /// `nil` everywhere else, so plain folder and plain sandbox modes are
    /// untouched.
    @TaskLocal public static var sandboxReadBridge: SandboxReadBridge?

    /// Linux sandbox agent name for the current execution. Bound alongside
    /// `sandboxReadBridge` so Agent DB file tools can resolve paths under
    /// `/workspace/...` even in plain sandbox mode (no host folder).
    @TaskLocal public static var sandboxAgentName: String?

    /// Default idle-timeout (seconds) for `shell_run`, applied ONLY when the
    /// model passed no `timeout` argument. Bound by headless drivers
    /// (`AgentLoopEvaluator`) where no user [Terminate] button exists, so a
    /// hung command can't wedge a run forever. `nil` on the chat / HTTP /
    /// plugin surfaces, preserving run-to-completion semantics there.
    @TaskLocal public static var defaultShellIdleTimeout: TimeInterval?

    /// True when the current tool execution was initiated by an EXTERNAL
    /// surface (the HTTP `/agents/{id}/run` loop or the `/mcp/call`
    /// bridge) rather than the in-app chat/plugin surfaces. The registry
    /// refuses workspace-mutating tool classes
    /// (`ToolRegistry.externallyDeniedToolNames`) under this flag — with
    /// a folder open those tools are registered process-wide with policy
    /// `.auto`, and loopback callers skip Bearer auth entirely.
    /// Module-internal so out-of-module callers cannot unbind it.
    @TaskLocal static var isExternalSurface: Bool = false

    /// Root of a host folder an AUTHENTICATED remote agent run (Secure
    /// Channel, agent-scoped) is permitted to read/write inside. Bound by
    /// `handleAgentRunEndpoint` ONLY after the secure-transport, built-in
    /// rejection, and agent-scope gates pass AND the agent has a configured
    /// `Agent.hostWorkspaceBookmark`. When set, `isDeniedForCurrentSurface`
    /// permits the host *file* tools (`file_write` / `file_edit`; `file_read`
    /// is never on the deny list) — confined to this folder by the folder
    /// tools' own root — while `shell_run` / `git_commit` / `file_undo` stay
    /// denied even for an authenticated run. Never bound for loopback, the
    /// `/mcp/call` bridge, plaintext callers, or a cross-agent key, so the
    /// relaxation can't be reached from an untrusted surface. Module-internal
    /// so out-of-module callers cannot bind it.
    @TaskLocal static var authenticatedHostFolderRoot: URL?

    /// True when the current execution is an UNATTENDED, app-authored
    /// background dispatch — a recurring schedule, a self-scheduled
    /// wake-up, or a file-system watcher trigger — fired with no
    /// interactive user present to answer an approval card. Bound `true`
    /// by `BackgroundTaskManager.dispatchChat` for those sources only, and
    /// only when the run is NOT an external surface (loopback/HTTP/MCP/
    /// plugin dispatches never set it). `ToolRegistry.runPermissionGate`
    /// consults it to auto-approve the narrow set of `.ask` tools in
    /// `ToolRegistry.unattendedAutoApprovableToolNames` — today only the
    /// curator's `propose_knowledge_update`, whose output is an inert
    /// draft that still requires a separate human diff-approval in the
    /// Knowledge tab before anything is written. Every other `.ask` tool
    /// is unaffected. Module-internal so out-of-module callers cannot bind
    /// it.
    @TaskLocal static var isUnattendedDispatch: Bool = false

    /// Identity a spawned subagent's KNOWLEDGE tools resolve grants and the
    /// curator role against. A spawned worker keeps `currentAgentId` inherited
    /// from its launcher (so budget/limiter/sandbox routing bill the launcher),
    /// but knowledge is an access-control boundary that must follow the agent
    /// actually running — otherwise a spawned helper would silently inherit its
    /// launcher's collection grants and curator role. `TextSubagentKind` binds
    /// this to the target agent's id for the duration of the child run; knowledge
    /// tools read `knowledgeAgentId` (this when set, else `currentAgentId`).
    /// Module-internal so out-of-module callers cannot rebind the boundary.
    @TaskLocal static var knowledgeGrantAgentIdOverride: UUID? = nil

    /// The agent identity knowledge tools use for grant / curator-role
    /// resolution: the subagent override when a spawned worker is running, else
    /// the normal `currentAgentId`.
    static var knowledgeAgentId: UUID? { knowledgeGrantAgentIdOverride ?? currentAgentId }
}
