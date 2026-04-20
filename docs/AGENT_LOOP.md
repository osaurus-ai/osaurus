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

The chat engine intercepts `clarify`, surfaces the question as an inline assistant bubble, and waits for the user. The user's next message becomes the answer, and the agent resumes from there.

| Field      | Type   | Required | Description                                                                                                                       |
| ---------- | ------ | -------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `question` | string | Yes      | A single, concrete question that would change the result if guessed wrong (e.g. "Use Postgres or SQLite?"). Avoid open-ended `what would you like?` phrasing. |

For minor preferences and recoverable choices the agent picks a sensible default and continues; `clarify` is reserved for genuinely blocking ambiguity.

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
| `file_tree`     | List directory structure with project-aware ignore patterns  |
| `file_read`     | Read file contents (supports line ranges and tail-only mode) |
| `file_write`    | Create or overwrite files                                    |
| `file_edit`     | Surgical exact-string replacement                            |
| `file_search`   | ripgrep-style search across the folder                       |
| `file_move`     | Move or rename                                               |
| `file_copy`     | Duplicate                                                    |
| `file_delete`   | Remove files                                                 |
| `dir_create`    | Create directories                                           |
| `batch`         | Execute up to 30 registered tool ops in sequence (continues on error, reports per-op status). `shell_run`, `git_commit`, and nested `batch` are denied. |

**Coding (registered when project type is detected):**

| Tool        | Description                                |
| ----------- | ------------------------------------------ |
| `shell_run` | Execute a shell command (requires approval) |

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
| `path`        | string | Relative path inside the working folder. Optional if `content` is provided.                       |
| `content`     | string | Inline text/markdown to share without writing a file first. Optional if `path` is provided.       |
| `filename`    | string | Required with `content`. Defaults to the basename of `path` otherwise.                            |
| `description` | string | Brief human-readable description.                                                                 |

Artifacts are persisted under `~/.osaurus/artifacts/<sessionId>/` and rendered inline in the chat thread. See [`SharedArtifact.swift`](../Packages/OsaurusCore/Models/Chat/SharedArtifact.swift).

---

## Memory Partitioning by Mode

Chat memory is partitioned by execution mode so a tool-using turn cannot leak facts into a no-tool-conversation context. The partitioning lives in [`ExecutionMode.swift`](../Packages/OsaurusCore/Folder/ExecutionMode.swift):

| `MemorySourceMode` | Set when                                            |
| ------------------ | --------------------------------------------------- |
| `chat`             | Plain chat, no tools                                |
| `chatSandbox`      | Chat with sandbox tools active                     |
| `workHost`         | Chat with a working folder selected (host folder tools) |
| `workSandbox`      | Chat with sandbox + autonomous exec                |

When the current request has no tools, memory entries written under `*Sandbox` / `workHost` modes are filtered out so the model isn't tempted to "remember" a tool result from a different context.

---

## Headless / HTTP / Plugin Use

Plugins and HTTP API callers reach the same loop through [`TaskDispatcher`](../Packages/OsaurusCore/Managers/TaskDispatcher.swift) and [`BackgroundTaskManager`](../Packages/OsaurusCore/Managers/BackgroundTaskManager.swift). Each dispatched task runs as a background chat session — same engine, same loop tools, same intercepts. See the [Plugin Authoring Guide](PLUGIN_AUTHORING.md) for the dispatch JSON schema and event types.

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
