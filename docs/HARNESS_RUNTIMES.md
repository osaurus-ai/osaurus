# Harness runtimes

An Osaurus agent normally runs on Osaurus's own agent loop. A **harness runtime** lets an external agent harness run it instead: Claude Code, Pi, or any harness built on Pi's RPC mode (for example a `~/.local/bin/spotlight --mode rpc` wrapper). The harness owns the model, the tools, and the conversation; Osaurus starts it, relays each user message, renders what it streams back, and stops it.

This document is the contract for harness authors.

## Registering a runtime

Settings → **Agent Runtimes** → **Add Runtime**:

| Field | Meaning |
|---|---|
| Protocol | `Claude Code` (stream-json) or `Pi (RPC)` |
| Name | Shown in the agent editor and the chat composer |
| Executable | A command on the login-shell `PATH` (`pi`, `spotlight`) or a path; `~` is expanded |
| Arguments | One per line. Placeholders are substituted per launch (below) |
| Environment | Extra `KEY=value` lines. Stored unencrypted in `~/.osaurus/config/harness-runtimes.json`, so don't put secrets here. `OSAURUS_*` names are reserved |

Then pick the runtime from the chat's model picker (each runtime is a column; Claude Code lists Sonnet, Opus, Fable, and Haiku) or in the agent's Configure tab under **Runtime → Runs on**. Both set the same per-agent runtime; picking a model row moves the agent back to Osaurus's own loop. **Test** starts the runtime once: a Pi runtime must answer `get_state`, and a Claude Code runtime must report its sign-in with `claude auth status`.

In the picker, a Claude Code column shows only once its executable resolves on the login-shell `PATH` (or while the agent already runs on it), and reads **Not signed in** when `claude auth status` says so. Osaurus checks both when the picker opens (at most every 30 seconds) and the install state again when runtimes change. Picking a Claude Code row while signed out, or on a runtime whose CLI is missing, opens the same sign-in steps as Settings first; the agent moves only after **Use Claude Code**, and **Back** leaves it on its current runtime and model. When the CLI is too old to report its sign-in, the row applies at once.

### From a configuration document

The declarative config (`osaurus config apply`, `osaurus_config`, `POST /admin/config/apply`) registers runtimes under `harness_runtimes` and moves agents onto them with `runtime`:

```yaml
harness_runtimes:
  - name: Spotlight
    kind: pi_rpc            # claude_code | pi_rpc; required to add, fixed after
    executable: ~/.local/bin/spotlight
    arguments: ["--mode", "rpc", "--session-id", "{chat_id}"]
    environment: { PI_LOG_LEVEL: info }   # merged; plain values only

agents:
  - name: Researcher
    runtime: Spotlight      # or "builtin"
default_agent:
  runtime: Claude Code
  claude_code: { model: opus, allow_writes: true }
```

An installer can also ship a runtime in an Osaurus bundle (`harness_runtimes` in `osaurus-bundle.json`, installed with `osaurus import install --yes`); see [OSAURUS_BUNDLES.md](OSAURUS_BUNDLES.md#6a-harness-runtime-reference).

Runtimes apply before agents, so one document can add a runtime and move an agent onto it. A `runtime` that names no registered runtime fails validation; it never falls back to `builtin`. Adding a runtime, changing its command line or environment, moving an agent onto a harness, and turning on `allow_shell` or `allow_osaurus_config_writes` (Default agent only) are high-risk plan lines that need approval.

### Argument placeholders

| Placeholder | Value |
|---|---|
| `{chat_id}` | The Osaurus chat UUID (lowercase) |
| `{agent_id}` | The agent UUID (lowercase) |
| `{cwd}` | The process's working directory |
| `{system_prompt_file}` | A private (0600) file holding the agent's system prompt, e.g. `--append-system-prompt {system_prompt_file}` |

New Pi runtimes start with:

```
--mode
rpc
--session-id
{chat_id}
```

When a Pi runtime's arguments don't place `{system_prompt_file}` and the agent has a system prompt, Osaurus appends `--append-system-prompt <private file>` itself. A wrapper that doesn't accept that flag should place `{system_prompt_file}` where it wants the file.

## Process lifecycle

- **One process per chat.** It starts on the chat's first message and stays up across turns.
- **Working directory.** The chat's folder, or a private per-chat scratch folder (`~/.osaurus/harness/<chat id>/`) when the chat has none. A folder that can't be read fails the turn with an error naming it; Osaurus never silently falls back to scratch.
- **Restarts.** The process is restarted on the next message after the chat's folder, the agent's system prompt, the agent's Claude Code options, the Osaurus tools it is given (the agent's tool settings, its granted plugin and MCP tools, or, for the Default agent, its teammates), or the runtime's settings change. It is also restarted after it exits or crashes. A running turn is never interrupted for a restart, and the composer locks the folder while a reply is streaming.
- **Resuming.** Claude Code resumes with `--resume <chat id>`. Pi has no RPC command to load a session by an id Osaurus picks, so a Pi runtime resumes only if its arguments key the session on `{chat_id}` (for example `--session-id {chat_id}`). Otherwise a restart starts a fresh harness conversation, and Osaurus warns before a folder change. The Osaurus transcript is always kept.
- **Stop.** Pi gets `{"type":"abort"}`; Claude Code gets a stream-json `interrupt` control request. If the turn hasn't settled 8 seconds later, the process is killed and the next message relaunches (and, where supported, resumes) it. Any Osaurus tool call the harness still has open for the chat (a teammate's run, a workflow test) is cancelled when the turn ends, whether or not the harness cancels it itself.
- **Shutdown.** Osaurus closes stdin. If the process hasn't exited 5 seconds later it gets `SIGTERM`, then `SIGKILL` 3 seconds after that. This happens when the chat is closed or deleted, when its tab is torn down, when the agent moves to another runtime (idle processes only), when the runtime is edited or deleted (idle processes only), and when Osaurus quits.
- **Framing.** stdout is JSON Lines split on LF only. U+2028 and U+2029 inside a record are safe. stderr is kept as a bounded tail and shown when the process exits unexpectedly.

## Environment

Every harness process gets these variables. They always win over the runtime's own environment lines.

| Variable | Value |
|---|---|
| `OSAURUS_CHAT_ID` | The Osaurus chat UUID. Stable across restarts; use it as your chat or case key |
| `OSAURUS_AGENT_ID` | The UUID of the agent the chat runs as |
| `OSAURUS_AGENT_TOKEN` | A credential scoped to that agent (below). Present it as `Authorization: Bearer <token>` |
| `OSAURUS_API_BASE` | The local server, e.g. `http://127.0.0.1:1337`, from the configured port. The OpenAI-compatible API is under `/v1`. The server may be stopped; `GET /health` tells you |
| `OSAURUS_WORKING_DIRECTORY` | The working directory the process started in (the chat's folder or its scratch folder) |
| `OSAURUS_MCP_BRIDGE_GRANT` | The same token, under the name `osaurus mcp` (the stdio MCP proxy) reads, so a harness that runs the proxy is attributed to the agent automatically |

The rest of the environment is Osaurus's own, with these changes:

- `PATH` is the user's login-shell `PATH` (so tools installed by mise, nvm, asdf, Homebrew, and similar managers resolve), with the directory of a `#!/usr/bin/env node` script's interpreter placed first.
- `CLAUDECODE` and any inherited `OSAURUS_MCP_BRIDGE_GRANT` are removed.
- For Claude Code, `ANTHROPIC_API_KEY` is also removed, so runs stay on the user's signed-in Claude subscription.

## The agent token

`OSAURUS_AGENT_TOKEN` is minted for one process, given only to that process (through its environment, never its arguments), and revoked when the process exits or Osaurus quits. It has no time limit while the process lives, and it keeps working if the Osaurus server is stopped and started again. It also carries the chat: tools called with it run as that chat (the Architect's draft tools act on the chat's draft, and a workflow's forms ask in the chat while it is open in a window).

It is honored only on connections from this Mac's loopback interface, even when the server is exposed to the network. With it, a harness can call:

| Route | Use |
|---|---|
| `GET /health`, `GET /mcp/health` | Liveness |
| `GET /mcp/tools`, `POST /mcp/call` | Osaurus tools, as the agent |
| `GET /v1/models`, `/v1/tags`, `/v1/show` | Model discovery |
| `POST /v1/chat/completions`, `/v1/completions`, `/v1/messages`, `/v1/responses` | Inference on Osaurus's local and cloud models, e.g. as a Pi provider with base URL `$OSAURUS_API_BASE/v1` |

Any other route (`/admin/*`, `/agents/*`, pairing, credits, and the rest) returns `403` with error code `harness_token_scope`.

On the MCP routes the token binds the agent's identity, so tools behave as they would for that agent, but it never widens what the agent may do:

- `/mcp/tools` lists, and `/mcp/call` runs, only the tools the agent's own tool settings allow, narrowed to the token's list when it has one. A Claude Code token lists exactly the agent's resolved surface: the built-in tools its settings turn on, its workflow tools, its granted plugin and MCP tools, and `osaurus_inspect` / `osaurus_help`; for the Default agent that is `status`, `run_workflow`, and the inspect tools. Tools whose permission is **Ask** are refused, because nobody can approve a prompt from inside a harness.
- The exception is `run_workflow` while the token's chat is open in a window. The call then runs as that chat's own call (not an external surface, prompts allowed, the chat's folder), so a teammate the Default agent hands a request to shows its approvals and macOS permission panels in the app, and the run's card attaches to the harness's tool row. A harness call never parks the turn: it waits for the run, forms included. With no window open it stays external and any prompt is refused.
- `osaurus_inspect` and `osaurus_help` (read-only, no secrets) work for any agent whose token grants them.
- `osaurus_config` (configuration changes) is refused unless the runtime grants it, and only ever runs for the Default agent. Today that means the Default agent on Claude Code with **Allow Osaurus configuration changes** on.
- Always refused: `spawn_agent` (it starts a worker on the agent's built-in model, which a harness agent doesn't have; the Default agent delegates with `run_workflow`), the built-in loop's control tools (`todo`, `complete`, `speak`, and `clarify` for any agent but the Architect), and `prompt_working_folder` (it would restart the harness mid-turn).
- Never listed for a Claude Code agent: the capability loaders (`capabilities*`, since Claude Code's tool list is fixed at launch, granted tools are listed directly), `configurator_handoff` and `architect_handoff` (they run a sub-loop on a built-in model), and tools whose result only becomes a chat card inside Osaurus's own loop (`share_artifact`, `image`, `video`, `render_chart`).
- Refused with an "external harness" error: Computer Use, Browser Use, AppleScript, and Mac query. They run Osaurus's own sub-loop on the agent's model, which a harness agent doesn't have.
- A revoked or unknown token presented on the bridge header is rejected; it never falls back to unauthenticated loopback access.

A `POST /mcp/call` body is `{"name": "<tool>", "arguments": {…}}`. `osaurus mcp` forwards the client's id for the call (Claude Code's `_meta["claudecode/toolUseId"]`) as `X-Osaurus-Tool-Call-Id`, so Osaurus can tie the call to the tool row the chat shows: a live run attaches to it, and when the call ends the row shows the arguments Osaurus received and the result it returned (kept per chat, newest 200 calls, each field cut at 64,000 characters, dropped when the chat's harness closes). A call can run as long as its tool does (`workflow_test` runs a whole workflow), so don't put a short timeout on it. `osaurus mcp` waits 15 minutes by default; set `OSAURUS_MCP_CALL_TIMEOUT` (seconds) to change that.

## The Architect on a harness

The Architect (the workflow designer) can run on Claude Code or Pi. Its surface is fixed, whatever the runtime or its Claude Code options say:

- **Instructions.** Its own built-in instructions, plus the person's extra instructions, plus a harness section: the draft is its only output, `clarify` returns the person's answer from the chat's question card, and it stops after `workflow_propose_save`.
- **Tools.** `workflow_draft`, `workflow_test`, `workflow_runs`, `workflow_discover`, `workflow_propose_save`, `osaurus_inspect` (the narrowed form its own loop gets), and `clarify`. Its token grants exactly these and never `osaurus_config`; `clarify` is listed only for a token that names it, so no other agent's token can reach it.
- **Questions.** `clarify` (`HarnessClarifyBridge`) shows the question on the open chat's question card and holds the tool call until the person answers; the answer is the call's result. The card closes after 14 minutes, under Claude Code's 15-minute MCP tool timeout, and says when. Closing the card, the time running out, or no window showing the chat returns a failure that tells the model to ask in a plain reply. Stop closes the card. No built-in harness tools: Claude Code runs with `--tools ""`, Pi with `--no-builtin-tools`.
- **Server.** The tools need the Osaurus server. When it isn't reachable at launch, the Architect is told its tools aren't connected and says so instead of improvising; the process relaunches with the tools once the server is back.
- **Save card.** A successful `workflow_propose_save` raises the same Save card as on Osaurus's own loop when the turn ends. Only the card's Save writes.

## Pi RPC

Osaurus speaks Pi's `--mode rpc` protocol (tested against Pi 0.83).

Sent to the harness:

- `{"id", "type": "prompt", "message", "images": [{"type": "image", "data": <base64>, "mimeType"}]}`, one per user message. Only the newest message is sent; the harness keeps its own history. Attached documents are inlined into `message` as text.
- `{"type": "abort"}` on Stop.
- `{"type": "extension_ui_response", "id", …}` answering a dialog with `value`, `confirmed`, or `cancelled: true`.
- `{"id", "type": "get_state"}` after a prompt is accepted with no `agent_start`, to tell a prompt that an extension command consumed (no run will follow) from one still starting. Test also sends one.

Read from the harness:

- A `prompt` response with `success: false` fails the turn. "No API key", "/login", and "no model selected" errors read as a sign-in problem.
- `message_update` with `text_delta` and `thinking_delta` streams text and reasoning.
- `tool_execution_start` and `tool_execution_end` show as tool activity.
- `auto_retry_*`, `compaction_*`, and `extension_error` show as notices.
- `extension_ui_request`: `select`, `confirm`, `input`, and `editor` open a dialog in the chat (cancelled on Stop or when the chat is headless). `notify` and `setStatus` become inline notices. Terminal-only requests are ignored.
- `message_end` carries usage for tokens per second. A final `stopReason: "error"` fails the turn.
- `agent_settled` ends the turn.

Osaurus can't confine a Pi harness's tools. Narrow them with `--tools` in the runtime's arguments.

Pi has no MCP client. For the Architect, Osaurus loads a bundled extension (`-e <app bundle>/osaurus-pi-extension.ts`) that lists the token's tools from `GET $OSAURUS_API_BASE/mcp/tools`, registers each as a Pi tool with its JSON Schema, and runs it through `POST /mcp/call` with the `X-Osaurus-Bridge-Grant` header. `workflow_propose_save` returns `terminate: true`, so the turn ends on the Save card. Other agents' Pi runs don't load it; a harness author can do the same from their own extension with `OSAURUS_AGENT_TOKEN`.

## Claude Code

The runtime launches:

```
claude --print --input-format stream-json --output-format stream-json --verbose
       --include-partial-messages --strict-mcp-config --model <alias>
       [--effort <level>] --thinking-display summarized [--system-prompt-snapshot off]
       (--session-id | --resume) <chat id> <permission flags>
       [--mcp-config <file>] [--append-system-prompt-file <file>] <runtime arguments>
```

Verified against Claude Code 2.1.212 and 2.1.308.

The per-agent settings below are the agent's **Claude Code Options**: on a custom agent's Configure tab, and on Settings → Orchestrator for the Default agent.

- **Effort and thinking.** `--effort` is passed only when the agent's **Claude effort** is set; Default leaves Claude Code on its own per-model default. `--thinking-display summarized` makes Claude Code stream thinking summaries. In `--print` mode it ignores the `showThinkingSummaries` setting and sends empty thinking, so the flag is required.

- **Execution mode.** *Agent* runs with `--permission-mode dontAsk` and an allow list: `Read`, `Grep`, and `Glob`; `Edit(//<real folder path>/**)` when **Allow file changes** is on (symlinks resolved, so `/tmp/x` becomes `//private/tmp/x`); `Bash` when **Allow shell commands** is on; and the agent's Osaurus tools (`mcp__osaurus__<name>`) when **Use Osaurus Tools** is on, the default. *Text only* disables every tool.
- **Visible built-ins.** `--tools` names the only built-ins the model sees: `Read`, `Grep`, `Glob`, `TodoWrite` (where the CLI still has it; unknown names are ignored), plus `Edit`, `Write`, `NotebookEdit` with file changes and `Bash`, `Monitor` with shell commands. It is an allow list because new CLI releases add built-ins (sub-agents, agent teams, scheduling, worktrees) that a deny list never names. `--disallowedTools` stays as a second layer.
- **Refusals.** A call `dontAsk` refuses shows a tool card naming the setting to change. A call to a tool the run doesn't have ("No such tool available") says so instead of the generic failure. A `can_use_tool` control request (a permission prompt routed to the host) is denied at once, and any other control request is refused, so a turn never waits on a question nobody can answer.
- **Writes and shell.** File edits are limited to the chat's folder. Shell commands can't be confined.
- **System prompt.** The agent's system prompt is passed through a 0600 file, never through argv. When the CLI supports it, `--system-prompt-snapshot off` makes a resumed session read the current prompt instead of replaying the first turn's, so a relaunch after the prompt or the server's state changed takes effect.
- **Osaurus tools.** Claude Code reaches them through `osaurus mcp` and the per-process token. The same resolved list goes to the token, to the proxy's `--tools`, and (namespaced) to `--allowedTools`, so the server stays the trust boundary. The system prompt file says which tools are attached, or why none are (Use Osaurus Tools off, the agent's tools off, the server down, or the bundled CLI missing). For the Default agent it also lists its teammates from the `run_workflow` catalog, since Osaurus's own composed prompt never reaches a harness. Tool cards show the tools without the `mcp__osaurus__` prefix. `MCP_TOOL_TIMEOUT` is set to 15 minutes unless the runtime's environment sets it, so long `workflow_test` and delegated runs finish.
- **Session ids.** The chat id doubles as the Claude Code session id. If Osaurus guesses wrong about whether a session exists ("already in use" or "No conversation found"), it retries once with the other flag.
- **Upgrading.** Earlier builds ran Claude Code as `claude-code/<alias>` models. On launch, any agent whose own or inherited model is one of those ids moves to the Claude Code runtime with that alias as its **Claude model**. An agent that already has an explicit runtime keeps it. The dead model ids are cleared, so the check costs nothing afterwards, and an agent restored from an old backup still gets moved.

## What doesn't run on a harness (yet)

- `spawn_agent` delegation to a harness agent. Harness agents are left out of the Orchestrator's roster.
- `/agents/{id}/run`.
- Computer Use, Browser Use, and AppleScript targeting a harness agent.
- Apple app tools called directly by a custom agent on Claude Code (they stay external-only); the Default agent reaches them by handing the request to an agent that has them.
- `clarify` for agents other than the Architect, and Osaurus tools in non-Architect Pi runs.

Each of these returns a typed error naming the harness rather than silently running the agent on Osaurus's loop with different settings. Multiple folders per chat (Claude Code's `--add-dir`) are not supported.
