# Agent Loop & Folder Context

Every chat in Osaurus is an agent loop. The agent picks a model, decides what to do next, calls tools, and either finishes (`complete`), pauses for input (`clarify`), or keeps iterating until its task list is empty.

There is no separate "Agent" or "Work" tab — the same chat window handles a one-line question and a multi-step refactor. What changes between the two is the tool kit: pick a working folder to give the agent file tools, or toggle the Linux Sandbox to give it shell access. The four "always-on" loop tools (`todo`, `complete`, `clarify`, `share_artifact`) are global built-ins and present in every chat regardless of mode.

---

## The Loop in One Glance

```
┌──────────────┐     ┌──────────────┐     ┌──────────────────────┐
│  user input  │ ──▶ │ agent thinks │ ──▶ │ tool calls + replies │
└──────────────┘     └──────────────┘     └──────────────────────┘
                            ▲                       │
                            │                       │
                            └───── todo / clarify ──┘
                                          │
                                   complete(summary)
                                          │
                                          ▼
                                     loop ends
```

The chat layer intercepts three special tool results so the loop has structure without a separate planner: `todo`, `complete`, and `clarify`. The intercept fires AFTER `ToolRegistry.execute` returns — the registry runs the tool body like any other tool, and the chat view (`ChatView`'s post-execute branch) inspects the tool name and result string to drive the inline UI. The intercept is gated on `!ToolEnvelope.isError(resultText)` so a rejected summary (e.g. `complete` with a placeholder like "done") falls through to the model for a retry instead of surfacing in the completion banner. Every other tool (file, sandbox, plugin, MCP, …) just runs and returns its output to the model on the next turn.

See [Tool Contract](TOOL_CONTRACT.md) for the canonical success/failure envelope shape every tool returns.

---

## The Three Loop Tools

These live in [`Tools/AgentLoopTools.swift`](../Packages/OsaurusCore/Tools/AgentLoopTools.swift). Each one has a single required field — the smallest schema we can give a small local model and still get the right behavior — but they're called identically by frontier models too. They're registered as global built-ins in [`ToolRegistry`](../Packages/OsaurusCore/Tools/ToolRegistry.swift) so the model sees them in every chat (folder, sandbox, plain Q&A) and the system prompt's "Agent Loop" guidance block reinforces when to call which.

### `todo` — write or replace the task checklist

The agent calls `todo` whenever it wants the user to see the plan. Each call **replaces the entire list** (no merging) so the agent can fix mistakes, reorder, or check items off by sending the full list with new boxes.

| Field      | Type   | Required | Description                                                                                     |
| ---------- | ------ | -------- | ----------------------------------------------------------------------------------------------- |
| `markdown` | string | Yes      | Markdown checklist. Items begin with `- [ ]` (pending) or `- [x]` / `- [X]` (done). Indentation up to 6 spaces is allowed; lines that don't match are ignored as prose. |

The store is per chat session and surfaced in the chat as a live checklist. Use it for tasks with more than two obvious steps; skip it for trivial work.

### `complete` — end the task with a verified summary

The chat engine intercepts `complete` and ends the loop. The summary becomes a "Completed" banner in the chat.

| Field     | Type   | Required | Description                                                                                       |
| --------- | ------ | -------- | ------------------------------------------------------------------------------------------------- |
| `summary` | string | Yes      | What you did + how you verified, in one paragraph (≥ ~30 chars of meaningful prose). Placeholders like `done`, `ok`, `looks good`, `complete`, `finished` are rejected. |

Honesty is preferred: if the agent couldn't finish, it should say so in the summary instead of pretending. The same `validate(summary:)` helper runs both inside the tool and in the chat-engine intercept, so HTTP-API callers get the same gate.

### `clarify` — pause and ask one critical question

The chat engine intercepts `clarify`, surfaces the question in a bottom-pinned overlay (`ClarifyPromptOverlay`), and waits for the user. The user's answer dispatches as the next user turn through the existing send path, and the agent resumes from there.

| Field           | Type     | Required | Description                                                                                                                       |
| --------------- | -------- | -------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `question`      | string   | Yes      | A single, concrete question that would change the result if guessed wrong (e.g. "Use Postgres or SQLite?"). Avoid open-ended `what would you like?` phrasing. |
| `options`       | string[] | No       | Up to 6 short answer choices (≤80 chars each, deduped). When present the UI renders one chip per option; tapping a chip submits that option as the answer. Omit for free-form questions. |
| `allowMultiple` | boolean  | No       | When `true` and `options` is set, the user can pick more than one chip and submits the joined answer. Defaults to `false` and is ignored when `options` is empty. |

For minor preferences and recoverable choices the agent picks a sensible default and continues; `clarify` is reserved for genuinely blocking ambiguity. When the answer is one of a finite menu, prefer `options` over a free-form question — one tap is faster than typing.

#### Inline UI

The clarify card is rendered through the shared [`PromptCard`](../Packages/OsaurusCore/Views/Chat/PromptCard.swift) chrome (the same chrome the secret prompt uses) and routed through the single-slot [`PromptQueue`](../Packages/OsaurusCore/Views/Chat/PromptQueue.swift) so it cannot stack on top of a pending secret prompt — whichever arrived first stays mounted, and the second is shown after the first resolves. While the card is mounted, the message thread blurs slightly and the main chat input dims so the user's attention lands on the embedded answer affordance. Reduced-motion settings are respected.

The `clarify` (along with `todo` and `complete`) tool call is filtered out of the generic tool-chip group in the message thread, so the question only renders once — as the inline overlay — instead of also showing up as a chip with truncated arguments.

---

## Working Folder (Folder Context)

Selecting a working folder transforms the chat into a code-aware agent. The selector lives on the chat input bar; you can also point any chat at a folder programmatically via [`FolderContextService`](../Packages/OsaurusCore/Folder/FolderContextService.swift).

### What happens when you pick a folder

1. macOS issues a security-scoped bookmark that persists across launches.
2. [`FolderContextService`](../Packages/OsaurusCore/Folder/FolderContextService.swift) builds a `FolderContext` with project-type detection, file tree summary, manifest contents, and git status.
3. [`FolderToolManager`](../Packages/OsaurusCore/Tools/FolderToolManager.swift) registers the folder tools listed below into [`ToolRegistry`](../Packages/OsaurusCore/Tools/ToolRegistry.swift).
4. The system prompt composer injects the folder context (tree, manifest, git status, optional `AGENTS.md` / `CLAUDE.md` / `.cursorrules`) for the model.

Project type is auto-detected from manifests (defined in [`FolderContext.swift`](../Packages/OsaurusCore/Folder/FolderContext.swift)):

| Project | Manifests Detected                               | Default Ignores                                        |
| ------- | ------------------------------------------------ | ------------------------------------------------------ |
| Swift   | `Package.swift`                                  | `.build`, `DerivedData`, `Pods`, `.swiftpm`, `*.xcodeproj`, `*.xcworkspace` |
| Node    | `package.json`                                   | `node_modules`, `dist`, `.next`, `build`, `.cache`     |
| Python  | `pyproject.toml`, `setup.py`, `requirements.txt` | `__pycache__`, `.venv`, `venv`, `*.pyc`, `.pytest_cache`, `.mypy_cache` |
| Rust    | `Cargo.toml`                                     | `target`                                               |
| Go      | `go.mod`                                         | `vendor`                                               |
| Unknown | —                                                | —                                                      |

`.git` is always ignored. Project-level guidance (`.hermes.md` / `HERMES.md` / `AGENTS.md` / `CLAUDE.md` / `.cursorrules`) is loaded first-found-wins, capped at 20 KB with head + tail truncation so trailing instructions survive.

### Folder tool inventory

Built by [`FolderToolFactory`](../Packages/OsaurusCore/Folder/FolderTools.swift) when the folder is selected. Tools that operate on the filesystem all enforce the same path contract: paths must be relative to the working folder, and after `..`/`.` standardisation must stay strictly under it. `share_artifact` is NOT in this table — it lives as a global built-in (see below) so it's available in every chat.

**Core (always registered):**

| Tool            | Description                                                  |
| --------------- | ------------------------------------------------------------ |
| `file_tree`     | List directory structure with project-aware ignore patterns. Use this instead of `ls`/`tree` in `shell_run`. |
| `file_read`     | Read file contents (supports line ranges and tail-only mode). Use this instead of `cat`/`head`/`tail`. |
| `file_write`    | Create or overwrite files. Use this instead of `echo`/`cat` heredoc. |
| `file_edit`     | Surgical exact-string replacement. Use this instead of `sed`/`awk`. |
| `file_search`   | ripgrep-style search across the folder. Use this instead of `grep`/`rg`/`find`. |

The previously-discrete `file_move`, `file_copy`, `file_delete`, `dir_create`, and `batch` tools were dropped — `mv`, `cp`, `rm`, and `mkdir` go through `shell_run` so the model picks "shell command" once instead of differentiating four near-identical tool names. Multi-step orchestration goes through `shell_run` chains.

**Coding (registered when project type is detected):**

| Tool        | Description                                |
| ----------- | ------------------------------------------ |
| `shell_run` | Execute a shell command (requires approval). Reserve for `mv`/`cp`/`rm`/`mkdir`, builds, installs, and any work that can't be expressed via the dedicated `file_*` tools. |

**Git (registered when the folder is a git repo):**

| Tool         | Description                                       |
| ------------ | ------------------------------------------------- |
| `git_status` | Repository status                                 |
| `git_diff`   | Show diffs                                        |
| `git_commit` | Stage and commit (requires approval)              |

Every write/exec/git-mutating call is logged in [`FileOperationLog`](../Packages/OsaurusCore/Folder/FileOperationLog.swift) so the user can review or undo individual operations.

---

## Sandbox Toggle

On macOS 26+, the chat input bar also has a Sandbox toggle. The Sandbox is mutually exclusive with the working-folder backend — turning it on clears any selected folder, and selecting a folder disables autonomous sandbox exec. See the [Sandbox Guide](SANDBOX.md) for the full sandbox tool inventory.

The execution mode is captured as a first-class enum in [`ExecutionMode.swift`](../Packages/OsaurusCore/Folder/ExecutionMode.swift):

```swift
public enum ExecutionMode: Sendable {
    case hostFolder(FolderContext)
    case sandbox
    case none
}
```

`ExecutionMode` is what the system prompt composer, tool registry, and memory layer all key off when deciding which tools and instructions to surface. The single resolver is [`ToolRegistry.resolveExecutionMode(folderContext:autonomousEnabled:)`](../Packages/OsaurusCore/Tools/ToolRegistry.swift) and its priority is **sandbox > host folder > none**: if the user has both an open folder and the autonomous-exec toggle on (with `sandbox_exec` registered), the sandbox wins. Plugin and HTTP entry points use the same resolver so the same agent gets the same mode regardless of how it's invoked.

---

## `share_artifact` — Handing Files Back to the User

`share_artifact` is a **global built-in** registered in [`ToolRegistry.registerBuiltInTools()`](../Packages/OsaurusCore/Tools/ToolRegistry.swift) — it's available in plain chat, folder, and sandbox alike. If the agent generates an image, chart, website, report, or any file, it **must** call this tool. The user does not see arbitrary files the agent writes to disk or to the sandbox; the artifact tool is what surfaces them as cards in chat.

| Field         | Type   | Description                                                                                       |
| ------------- | ------ | ------------------------------------------------------------------------------------------------- |
| `path`        | string | Path to an existing file/dir. **The file must exist before the call — `share_artifact` does not create files.** Sandbox: relative to the agent home (e.g. `report.pdf`, `output/chart.svg`) or `/workspace/...` absolute. Folder: relative to the working folder. Optional if `content` is provided. |
| `content`     | string | Inline text/markdown to share without writing a file first. Optional if `path` is provided. Omit entirely (do **not** pass an empty string) when using `path`. |
| `filename`    | string | Required with `content`. Defaults to the basename of `path` otherwise. Omit entirely when not used. |
| `description` | string | Brief human-readable description.                                                                 |

Artifacts are persisted under `~/.osaurus/artifacts/<sessionId>/` and rendered inline in the chat thread. See [`SharedArtifact.swift`](../Packages/OsaurusCore/Models/Chat/SharedArtifact.swift).

#### `share_artifact` and `sandbox_execute_code`

`share_artifact` is **NOT** exposed to the `osaurus_tools` Python helper module. Calling it from inside a `sandbox_execute_code` script would create the marker envelope but the chat-layer post-processor that turns it into a real artifact card only fires for top-level tool calls — so an in-script `share_artifact` would silently no-op the chat UI even though the script "succeeds". The bridge endpoint enforces the same rule by hard-coding its allow-list to the file/exec helpers only.

The right pattern is two top-level tool calls:

1. `sandbox_execute_code({"code": "…write julia.png…"})` — script does the work, prints the resulting path to stdout.
2. `share_artifact({"path": "julia.png", "description": "…"})` — model surfaces the file as a chat card.

#### Failure modes

The chat-layer wrapper surfaces a differentiated error envelope per failure mode so the model can self-correct on the next turn:

| Failure                                         | What the model sees                                                                                                                     |
| ----------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| Path rejected by the sanitizer (traversal, etc.) | `invalid_args` envelope on `path` with the trusted root mentioned and a `sandbox_search_files(target="files", …)` hint.                 |
| File doesn't exist where the resolver looked    | `execution_error` listing every candidate path (`<home>/foo.png`, `<home>/output/foo.png`, `…/dist/foo.png`, …) so the model can `sandbox_search_files` for the real location. |
| File existed but the host-side copy threw       | `execution_error` carrying the FS error (disk full, perms) and the source path. |
| `path` and `content` both empty / missing       | `invalid_args` reminding the model to pass at least one. Empty-string filler in optional fields is treated as absent on entry. |

---

## Headless / HTTP / Plugin Use

Plugins and HTTP API callers reach the same loop through [`TaskDispatcher`](../Packages/OsaurusCore/Managers/TaskDispatcher.swift) and [`BackgroundTaskManager`](../Packages/OsaurusCore/Managers/BackgroundTaskManager.swift). Each dispatched task runs as a background chat session — same engine, same loop tools, same intercepts. See the [Plugin Authoring Guide](PLUGIN_AUTHORING.md) for the dispatch JSON schema and event types.

### Session Audit Dimension

Every persisted [`ChatSessionData`](../Packages/OsaurusCore/Models/Chat/ChatSessionData.swift) carries a [`SessionSource`](../Packages/OsaurusCore/Models/Chat/SessionSource.swift) tag — `chat`, `plugin`, `http`, `schedule`, or `watcher` — plus the originating `sourcePluginId`, `externalSessionKey`, and `dispatchTaskId`. The chat sidebar surfaces this as a per-row badge and a source filter rail so users can audit what spawned each conversation. Telegram-style plugins that pass `external_session_key` get one growing session per external thread instead of a new row per inbound message — see [Conversation Grouping](PLUGIN_AUTHORING.md#conversation-grouping). The dispatch task id and the persisted session id are intentionally the same UUID so HTTP pollers, plugins, and the sidebar deep-link to the same row.

### HTTP API divergence (intentional)

The OpenAI-compatible HTTP endpoint is **stateless** — there's no Osaurus session id on the request, so it cannot reuse `SessionToolStateStore.loadedToolNames`, run a real LLM-driven preflight, or freeze a per-session schema snapshot. To keep the schema predictable for HTTP callers (and to avoid paying a preflight LLM call on every request), the HTTP path deliberately bypasses [`SystemPromptComposer.resolveTools`](../Packages/OsaurusCore/Services/Chat/SystemPromptComposer.swift) and uses bare `ToolRegistry.alwaysLoadedSpecs(mode:)`. Manual-mode user picks, mid-session `capabilities_load` additions, and the inline `clarify` UI are chat-only. This is **by design** — see the comment block in [`HTTPHandler.swift`](../Packages/OsaurusCore/Networking/HTTPHandler.swift) before "fixing" it.

---

## Best Practices

- **Be specific in the prompt.** "Add a logout button to the navbar" beats "update the UI".
- **Pick the right backend.** Working folder for code in a real repo. Sandbox for "run a script", "scrape this URL", or "install this package". Neither for plain Q&A.
- **Let the model use `todo`.** It costs almost nothing and gives the user a live progress view.
- **Trust `complete`.** If a task is genuinely partial, the agent should say so honestly in the summary — that's the contract, and the validator will reject "done" / "looks good" / etc.

---

## Related Documentation

- [Sandbox Guide](SANDBOX.md) — Linux VM, sandbox tool inventory, plugin recipes
- [Skills Guide](SKILLS.md) — Reusable AI capabilities and methods
- [Plugin Authoring Guide](PLUGIN_AUTHORING.md) — Building tools and dispatching tasks
- [Features Overview](FEATURES.md) — Complete feature inventory
