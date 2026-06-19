# Sandbox

Run agent code in an isolated Linux virtual machine — safely, locally, and with full dev environment capabilities.

The Sandbox is a shared Linux container powered by Apple's [Containerization](https://developer.apple.com/documentation/containerization) framework. It gives every Osaurus agent access to a real Linux environment with shell, package managers, compilers, and file system access — all running natively on Apple Silicon with zero risk to your Mac.

> **Sandbox Tools vs Native Plugins:** Osaurus has two distinct extensibility systems. **Sandbox tools** (this guide) are JSON recipes that run inside the Linux container — no compiler, no code signing, ideal for shell-based workflows. **Native plugins** are compiled `.dylib` files with full host API access (inference, storage, HTTP routes, web UIs); see [`docs/plugins/README.md`](plugins/README.md). The terms used to overlap; this doc uses **Sandbox Tools** consistently.

---

## Why Sandbox?

### Safe Execution

Agents can run arbitrary code, install packages, and modify files without any risk to the host macOS system. The VM is a disposable, resettable environment. If something goes wrong, reset the container and start fresh — your Mac is never affected.

### Real Dev Environment

Agents gain a full Linux environment with shell access, Python (pip), Node.js (npm), system packages (apk), compilers, and standard POSIX tools. This far exceeds what macOS-sandboxed tools can offer, enabling agents to build, test, and run real software.

### Multi-Agent Isolation

Each agent gets its own Linux user and home directory. One agent's files, processes, and installed packages cannot interfere with another's. Run multiple specialized agents simultaneously — a Python data analyst, a Node.js web developer, and a system administration agent — without cross-contamination.

### Lightweight Tool Ecosystem

Sandbox tools are simple JSON recipes. No compiled dylibs, no Xcode, no code signing required. Anyone can write, share, and import tools that install dependencies, seed files, and define custom capabilities — dramatically lowering the barrier to extending agent capabilities. (For richer extensibility with full host API access, see [native plugins](plugins/README.md).)

### Local-First

Everything runs on-device using Apple's Virtualization framework. No Docker, no cloud VMs, no network dependency. The container boots in seconds and runs with native performance on Apple Silicon.

### Seamless Host Bridge

Despite running in isolation, agents inside the VM retain full access to Osaurus services — inference, memory, secrets, agent dispatch, and events — via a vsock bridge. The sandbox is isolated but not disconnected.

---

## Requirements

- **macOS 26+** (Tahoe) — required for Apple's Containerization framework
- **Apple Silicon** (M1 or newer)

---

## Getting Started

### 1. Open the Sandbox Tab

Open the Management window (`⌘ Shift M`) → **Sandbox**.

### 2. Provision the Container

Click **Provision** to download the Linux kernel and initial filesystem, then boot the container. This is a one-time setup that takes about a minute.

### 3. Start Using Sandbox Tools

Once the container is running, sandbox tools are automatically registered for the active agent. The agent can now execute commands, read/write files, install packages, and more — all inside the VM.

### 4. Install Sandbox Tools (Optional)

Switch to the **Sandbox** tab in the Tools manager to browse, import, or create JSON tool recipes that extend your agents with custom capabilities. For native dylib plugins (full host API access), use the **Available** tab and see [`docs/plugins/README.md`](plugins/README.md).

---

## Provisioning Preflight

Before provisioning, or when a sandbox setup looks unhealthy, open the
Management window (`⌘ Shift M`) → **Sandbox** and use **Provisioning
Preflight**. The report inspects the resolved Osaurus root, config directory
and `sandbox.json`, cache directory, temporary directory, container workspace,
agent/shared workspace roots, kernel/initfs assets, warm rootfs state, and the
runtime bridge socket.

Readiness is intentionally typed and conservative:

| Readiness | Meaning |
|-----------|---------|
| `ready` | Required host paths exist, are the expected type, and passed read/write checks. |
| `needs_setup` | Setup is incomplete or provisioning-created paths/assets are missing but repairable. |
| `blocked` | A required path, permission, platform, architecture, or disk-space check failed. |
| `unproven` | A check could not be proven and should not be treated as healthy. |

Each finding includes a code, severity, status, affected path when available,
and a concrete repair suggestion. Missing and unproven checks stay visible in
the report instead of being coerced to a pass state.

### Support and CI Proof

Use **Copy JSON** on the preflight card to attach a support artifact or CI proof
record. The JSON uses stable snake-case keys and includes:

- resolved paths and source (`default_home`, `environment_override`, or
  `test_override`);
- configuration source and setup state;
- per-location status, read/write probe result, file size, and volume capacity
  where available;
- typed findings with repair suggestions;
- overall readiness.

Maintainers can exercise the model and report output with:

```bash
swift test --package-path Packages/OsaurusCore --filter SandboxProvisioningDiagnostics
```

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                        macOS Host                            │
│                                                              │
│  ┌──────────────┐     ┌──────────────────────────────┐       │
│  │   Osaurus    │     │   Linux VM (Alpine)          │       │
│  │              │     │                              │       │
│  │  SandboxMgr ─┼─────┤→ /workspace (VirtioFS)      │       │
│  │              │     │→ /output    (VirtioFS)       │       │
│  │  HostAPI  ←──┼─vsock─→ /run/osaurus-bridge.sock  │       │
│  │  Bridge      │     │                              │       │
│  │              │     │  agent-alice  (Linux user)   │       │
│  │  ToolReg  ←──┼─────┤  agent-bob    (Linux user)  │       │
│  │              │     │  ...                         │       │
│  └──────────────┘     └──────────────────────────────┘       │
└──────────────────────────────────────────────────────────────┘
```

**Key components:**

| Component | Description |
|-----------|-------------|
| **Linux VM** | Alpine Linux with Kata Containers 3.17.0 ARM64 kernel, 8 GiB root filesystem |
| **VirtioFS Mounts** | `/workspace` maps to `~/.osaurus/container/workspace/`, `/output` maps to `~/.osaurus/container/output/` |
| **NAT Networking** | Container gets `10.0.2.15/24` via `VZNATNetworkDeviceAttachment` |
| **Vsock Bridge** | Unix socket relayed via vsock connects the container to the Host API Bridge server |
| **Per-Agent Users** | Each agent gets a Linux user `agent-{name}` with home at `/workspace/agents/{name}/` |
| **Host API Bridge** | HTTP server on the host, accessible from the container via `osaurus-host` CLI shim |

---

## Configuration

Configure the container via the Management window → **Sandbox** → **Container** tab → **Resources** section.

| Setting | Range | Default | Description |
|---------|-------|---------|-------------|
| CPUs | 1–8 | 2 | Virtual CPU cores allocated to the VM |
| Memory | 1–8 GB | 2 GB | RAM allocated to the VM |
| Network | outbound / none | outbound | NAT networking for outbound internet access |
| Auto-Start | on / off | on | Automatically start the container when Osaurus launches |

Changes require a container restart to take effect.

**Config file:** `~/.osaurus/config/sandbox.json`

```json
{
  "autoStart": true,
  "cpus": 2,
  "memoryGB": 2,
  "network": "outbound"
}
```

---

## SOUL.md — Per-Agent Identity Layer

Every sandboxed agent gets a `SOUL.md` file at `~/SOUL.md` inside its home (host path: `~/.osaurus/container/workspace/agents/{name}/SOUL.md`). This is the agent-authored complement to the user-authored persona slot — a place for the agent to record stable preferences and patterns it learns about working with you, persisted across sessions.

### What belongs in SOUL.md

- Stable user preferences (tooling choices, voice, formatting).
- Recurring patterns the user expects.
- Working agreements established over time.

### What does NOT belong

- Session-specific facts → use [Memory](MEMORY.md).
- Project-specific details → use `AGENTS.md` in folder mode.
- Transient context.

### Lifecycle

| Step | When | What happens |
|------|------|--------------|
| Seed | First sandbox provision for an agent | A documented seed is written to `~/SOUL.md` (idempotent — never overwrites an existing soul). |
| Read | Every chat compose in sandbox mode | Composer reads the file, caps it at 8 KB on a line boundary, and emits a `## SOUL` section into the system prompt between persona and operational directives. |
| Edit | Any time during a sandbox session | The agent edits its own soul via `sandbox_write_file` (whole-file write, or in-place edit via `old_string`+`new_string`). Edits apply on the **next** session — within the active turn the cached system prompt stays byte-stable for KV-cache reuse. |

### Precedence with persona

Persona (the user-authored `systemPrompt` on the Agent) wins on conflict. Two reinforcements: render order pins persona above SOUL, and the SOUL section's intro line states "the user's instructions in earlier sections take precedence." In practice the two operate at different scopes (persona = role, SOUL = preferences) and direct conflict is rare.

### Reset

To wipe an agent's soul, delete `~/.osaurus/container/workspace/agents/{name}/SOUL.md`. The next provision will re-seed the boilerplate; the next chat compose will pick it up.

Sandbox-only by design — folder-mode agents are short-lived and project-bound.

---

## Built-in Tools

When the container is running, sandbox tools are automatically registered for the active agent. Read-only tools are always available. Write and execution tools require `autonomous_exec` to be enabled on the agent.

> **Default ON (where supported):** On macOS 26+ the sandbox chip defaults **on** for the built-in Default agent and for newly created agents. To avoid a surprise multi-GB download for users who never touch it, the container is **not** booted eagerly — a never-set-up sandbox stays un-provisioned until first use. The first time the model reaches for a sandbox tool (the transient `sandbox_init_pending` placeholder), the container boots and provisions on demand; once `setupComplete` is recorded, later launches auto-start as normal. Provisioning the container from the Sandbox tab, or toggling the chip off→on, also boots it immediately. Existing agents that were left unconfigured keep their previous (off) state, and unsupported machines (pre-macOS 26) stay off.

### Anti-confusion cheat sheet (always prefer the dedicated tool)

| Don't                                | Do                                                                                                              |
|--------------------------------------|------------------------------------------------------------------------------------------------------------------|
| `cat` / `head` / `tail` in `sandbox_exec` | `sandbox_read_file`                                                                                              |
| `grep` / `rg` / `find` / `ls` in `sandbox_exec` | `sandbox_search_files` — `target="content"` (rg) or `target="files"` (find).                                     |
| `sed` / `awk`                        | `sandbox_write_file` with `old_string` → `new_string` (in-place edit)                                            |
| `echo` / `cat` heredoc to create files | `sandbox_write_file` with `content` (whole file)                                                               |
| `&` / `nohup` / `disown` for backgrounding | `sandbox_exec(background:true)` — pid + log_file ride back, manage with `sandbox_process` (poll/wait/kill)        |

Reserve `sandbox_exec` for builds, installs, git, processes, network calls, package managers, and any work that doesn't have a dedicated tool above. For multi-line scripts (Python, Node, etc.), `sandbox_write_file` the script then run it with `sandbox_exec` (e.g. `python3 script.py`) — never inline multi-line code in `python3 -c` / `node -e`.

### Always Available (Read-Only)

| Tool | Description |
|------|-------------|
| `sandbox_read_file` | Read a file's contents from the sandbox (supports line ranges, tail, char cap) |
| `sandbox_search_files` | Search file contents (`target="content"`, ripgrep) **or** find files by name (`target="files"`, glob). Folded the previously-separate `sandbox_find_files` and `sandbox_list_directory` here. |

Folder-mode `file_read` uses a bounded raw path for plain text, source, and
CSV/TSV: it reads at most 5 MiB before UTF-8 decoding and returns explicit
metadata when that cap truncates the preview. Rich documents and XLSX previews
use the document-adapter limits instead. `sandbox_read_file` remains a raw
sandbox utility with its own character/range controls; it does not currently
share the folder `file_read` document-adapter path.

When `file_read` is pointed at a **directory** (host or, in combined mode, a
`/workspace/...` sandbox path), it returns a structured `kind: "listing"`
envelope with `entries[]` (`{name, path, type}`) instead of an ASCII tree —
the sandbox route builds it with `find -maxdepth N -printf '%y\t%p\n'`. Each
entry's `path` is a ready-to-use argument for the next `file_read`, so a small
model descends by copying a field rather than parsing a tree. The agent loop's
`AgentTaskState` harness classifies the listing to steer the next step; see
[Agent Loop — Harness Task State](AGENT_LOOP.md#harness-task-state-agenttaskstate).

### Requires Autonomous Exec

| Tool | Description |
|------|-------------|
| `sandbox_write_file` | Write a whole file via `content` (creates parent directories), **or** edit in place via `old_string`+`new_string` (exact match, must match exactly once). The presence of `old_string` selects the edit path; folds in the previously-separate `sandbox_edit_file`. |
| `sandbox_exec` | Run a shell command. Foreground (default, max 300s) **or** `background:true` for servers/long tasks (the spawn shim returns immediately with `pid` + `log_file`). Pair the background form with `sandbox_process`. |
| `sandbox_process` | Manage background jobs: `action="poll"` (alive + log tail), `"wait"` (block until exit, capped by `timeout`), `"kill"` (`force:true` for SIGKILL). |
| `sandbox_install` | Install packages, one tool for all three managers via the required `manager` argument: `apk` (system packages, runs as root, auto-refreshes the index, serializes globally on apk's container-wide lock), `pip` (Python packages into the agent venv at `~/.venv/`, auto-created on first use, `--disable-pip-version-check --no-input`), or `npm` (Node packages into a per-agent workspace at `~/.osaurus/node_workspace/`, bootstraps `package.json`, `--no-audit --no-fund --no-update-notifier`). Installed `python3`/CLI binaries are on PATH from any `sandbox_exec` cwd. 240s timeout for pip/npm, 120s for apk. |
| `sandbox_secret_check` | Check whether a secret exists for this agent (never reveals the value) |
| `sandbox_secret_set` | Store a secret securely — pass `value` directly or omit to prompt the user |
| `sandbox_plugin_register` | Register an agent-created plugin (requires `pluginCreate` permission) |

The previously-discrete `sandbox_list_directory`, `sandbox_find_files`, `sandbox_move`, `sandbox_delete`, `sandbox_exec_background`, `sandbox_run_script`, `sandbox_edit_file`, and `sandbox_execute_code` tools were dropped. Their behaviour now comes from a flag (`background:true` on `sandbox_exec`, `target` on `sandbox_search_files`), an argument (`old_string`+`new_string` on `sandbox_write_file` for in-place edits), or a direct shell invocation (`mv` / `rm` in `sandbox_exec`). `sandbox_run_script` and `sandbox_execute_code`'s use case — multi-step scripts/orchestration — is now `sandbox_write_file` the script then `sandbox_exec` to run it (e.g. `python3 script.py`). The separate `sandbox_pip_install` / `sandbox_npm_install` tools were folded into `sandbox_install` (select with `manager:"pip"` / `"npm"`); a bare `apk add` / `pip install` / `npm install` run through `sandbox_exec` that fails surfaces a self-heal hint pointing back at `sandbox_install`.

`share_artifact` is a global built-in (registered in `ToolRegistry`) and is the only way for sandbox-generated content to reach the chat thread. It's not in this sandbox-specific list because it's available everywhere, not just in sandbox mode.

All file paths are validated on the host side before container execution by `SandboxPathSanitizer`, which now returns structured rejection reasons (empty, traversal, null byte, dangerous character, outside allowed roots). Tools surface the reason to the model in an `invalid_args` envelope so the next call self-corrects instead of retrying with the same bad path.

### Install hardening

`sandbox_install`'s three managers (`apk` / `pip` / `npm`) share a hardening pipeline:

| Layer | Behaviour |
|---|---|
| **Per-agent serialization** | `SandboxInstallLock` queues install operations behind each other per agent so two concurrent calls can't race on `node_modules/` / venv / apk db. **apk's lock is container-wide**, so `sandbox_install` calls serialize *globally across every agent* under a synthetic key — a slow `apk add` on agent A briefly blocks agent B's `apk add`. npm/pip installs are isolated per-agent and run concurrently across agents. |
| **Auto-recovery** | If the first attempt fails AND its output matches a known stale-state signature (`Tracker "idealTree" already exists`, `EEXIST`, `ELOCKED` for npm; `Could not install packages due to an OSError`, `ReadTimeoutError` for pip; `temporary error`, `unable to lock database` for apk), the tool runs a tool-specific cleanup and retries once. The result envelope includes `retried: true` so the model can see the recovery happened. |
| **Cleanup actions** | npm: `rm -rf node_modules/.package-lock.json && npm cache clean --force`. pip: `pip cache purge`. apk: `apk update`. All run in the same exec context (agent for npm/pip, root for apk) as the install attempt. |
| **Workspace isolation** | npm installs into `~/.osaurus/node_workspace/` (bootstraps `package.json` on first use). pip installs into the agent's venv at `~/.venv/`. Both have their `bin/` on PATH from any `sandbox_exec` cwd. |
| **Stable flags** | npm: `--no-audit --no-fund --no-update-notifier`. pip: `--disable-pip-version-check --no-input`. apk: `--no-cache` plus a leading `apk update --quiet`. |
| **Timeouts** | npm/pip: 240s (covers cold-cache installs of large packages like torch / pandas / scoped npm packages). apk: 120s. |

### Installed-package awareness

So the model doesn't re-probe or reinstall what it already has, `SandboxPackageManifest` keeps a host-side, per-agent record (`~/.osaurus/agents/<uuid>/installed-packages.json`) of installed packages by manager. Two writers feed it: `SandboxAgentProvisioner` seeds it once per provision via a cheap lazy reconcile (lists the agent's pip venv and reads its npm `package.json` — `apk` is skipped because the base image carries hundreds of system packages and bare `apk add` can't succeed unprivileged), and `sandbox_install` appends successful installs. `SystemPromptComposer` renders it as a compact, capped **"Already installed"** block inside the *dynamic* `## Sandbox state` section (alongside configured secrets), which sits after the static prefix break — so a mid-session `sandbox_install` or new secret stays fresh turn-to-turn without rewriting the cached KV prefix. The static sandbox framing above it never changes mid-session. The manifest is cleared on unprovision so a rebuilt container starts from observed truth.

### Result shape

Every sandbox tool returns a [ToolEnvelope](TOOL_CONTRACT.md) JSON string. Success payloads in `result`:

- Read/inspect: `{path, content, size}` (+ optional `start_line`/`line_count`/`tail_lines`/`max_chars`).
- Search: `{pattern, target, path, matches}` — `target` is `"content"` or `"files"`.
- Exec foreground: `{stdout, stderr, exit_code, cwd}`. Background (`background:true`): `{pid, log_file, cwd, background:true}`.
- Process management: `{pid, alive|exited|killed, log_file, log_tail, ...}`.
- Install (`sandbox_install`): `{installed, exit_code, summary}` on success — the verbose installer log is trimmed (it's pure context noise); the failure path returns an `execution_error` envelope that *does* carry the combined output for debugging. Both shapes carry `retried: true` when the auto-recovery harness ran a cleanup + second attempt. Failure envelopes additionally carry `cleanup_failed: true` if the cleanup step itself threw — that signals to the model that it should not retry the same operation right away. On success, the installed names are recorded in a host-side manifest surfaced as an "Already installed" line in the system prompt (see below).

Failures use `kind: invalid_args` with `field` pointing at the offending argument (`path`, `cwd`, `content`, etc.) so the model can self-correct on the next turn.

---

## Streaming Exec & Terminate

`sandbox_exec` (foreground OR `background: true`) and folder-mode `shell_run` stream their live output into the chat tool-call card while the process runs. The model still gets the final `{stdout, stderr, exit_code}` blob when the process exits — streaming is purely a side-channel for the user.

### What the user sees

When a long-running command starts, the tool-call card mounts an inline terminal pane:

- **Status pill** in the header: `running 0:42`, `exited (0)`, `terminated (user)`.
- **Live output** below: monospaced, ANSI-stripped, auto-follows the tail unless the user scrolls up.
- **`[Copy]`** button: snapshots the current output to the clipboard.
- **`[Terminate]`** button: red-tinted, only visible while the process is running. Sends SIGTERM, then SIGKILL after a 3 s grace.

The pane is capped at ~14 lines of monospaced text (240 pt); content beyond that scrolls inside the pane rather than growing the row, so a 10 MB build log can't blow up the chat layout.

### Untimed by default

Phase 1 dropped the wall-clock timeouts that used to kill long commands at ~2 minutes:

- The registry-level 120 s safety net is bypassed for `sandbox_exec` and `shell_run` via `OsaurusTool.bypassRegistryTimeout`.
- The tool's own `timeout` parameter is now an **optional inactivity ceiling**, not a wall-clock cap. When the model omits it, the command runs to completion or until the user terminates.
- Pass `timeout: <seconds>` ONLY when you want a hard idle ceiling (kill if no output for N seconds). The user's `[Terminate]` button is the primary control.

The inactivity timer (when set) resets on every byte of output, so a `cargo build` that produces silent stretches between status lines won't trip it as long as it's actually progressing.

When the idle ceiling does fire, the failure envelope carries the honest `kind: "timeout"` (retryable, with wording that explains it was an inactivity kill, not a wall-clock cap — "re-run with a longer `timeout` or emit progress output"). Sandbox-not-ready states (container not running, VM still provisioning) map to `kind: "unavailable"` (also retryable) so the model waits and retries instead of pivoting to a different approach. The same taxonomy applies to MCP provider calls: a provider timeout is `kind: "timeout"`, an unreachable/disabled provider is `kind: "unavailable"`.

### Terminate semantics

When the user presses `[Terminate]`:

1. SIGTERM is sent to the process group.
2. After a 3 s grace, SIGKILL.
3. The result envelope returned to the model carries `killed_by: "user"` (alongside the usual `stdout` / `stderr` / `exit_code`) so it can decide whether to retry, fall back, or move on.
4. The status pill flips to `terminated (user)`.

Terminating from the chat card races the model the same way `sandbox_process(kill)` does — both end up at the SIGTERM/SIGKILL path. A model `read` mid-flight returns the captured output up to termination.

### Pipeline diagnostics

Two related changes catch the silent-pipeline-failure pattern that used to surface as `{exit_code: 0, stdout: "", stderr: ""}` from a failed `curl ... 2>/dev/null | grep ... | head -80`:

- **`set -o pipefail` is on by default** for both `sandbox_exec` and `shell_run`. A real upstream failure now surfaces as the rightmost non-zero exit instead of being masked by `head` / `tee` / `cat`.
- **Empty-output warning**. When `exit_code == 0` AND stdout AND stderr are all empty AND the command contained `|` or `2>/dev/null`, the result envelope's `warnings:` array carries a hint pointing at the suppressed-stderr / pipeline pattern.
- **SIGPIPE soft note**. `cmd | head -n N` legitimately kills `cmd` with SIGPIPE (exit 141) once `head` reaches its limit. The result envelope flags this with a softer "captured stdout is still trustworthy" warning so the model doesn't treat it as a failure.

**Don't use `2>/dev/null` in pipelines.** It hides errors from the result envelope. If you genuinely need silent stderr, redirect to a log file you can `sandbox_read_file` later.

---

## Sandbox Plugins

Sandbox plugins are JSON recipes that extend agent capabilities inside the container. They can install system dependencies, seed files, define custom tools, and configure secrets — all without compiling code.

### Plugin Format

```json
{
  "name": "Python Data Tools",
  "description": "Data analysis toolkit with pandas and matplotlib",
  "version": "1.0.0",
  "author": "your-name",
  "dependencies": ["python3", "py3-pip"],
  "setup": "pip install --user pandas matplotlib seaborn",
  "files": {
    "helpers.py": "import pandas as pd\nimport matplotlib\nmatplotlib.use('Agg')\nimport matplotlib.pyplot as plt\n"
  },
  "tools": [
    {
      "id": "analyze_csv",
      "description": "Load a CSV file and return summary statistics",
      "parameters": {
        "file": {
          "type": "string",
          "description": "Path to the CSV file"
        }
      },
      "run": "cd $HOME/plugins/python-data-tools && python3 -c \"import pandas as pd; df = pd.read_csv('$PARAM_FILE'); print(df.describe().to_string())\""
    }
  ],
  "secrets": ["OPENAI_API_KEY"],
  "permissions": {
    "network": "outbound",
    "inference": true
  }
}
```

### Plugin Properties

| Property | Type | Required | Description |
|----------|------|----------|-------------|
| `name` | string | Yes | Display name |
| `description` | string | Yes | Brief description |
| `version` | string | No | Semantic version |
| `author` | string | No | Author name |
| `source` | string | No | Source URL (e.g., GitHub repo) |
| `dependencies` | string[] | No | System packages installed via `apk add` (runs as root) |
| `setup` | string | No | Setup command run as the agent's Linux user |
| `files` | object | No | Files seeded into the plugin folder (key = relative path, value = contents) |
| `tools` | SandboxToolSpec[] | No | Custom tool definitions |
| `secrets` | string[] | No | Secret names the plugin requires (user prompted on install) |
| `permissions` | object | No | Network policy and inference access |

### Per-Agent Installation

Plugins are installed per agent. Each agent can have a different set of plugins installed, and each installation is isolated in its own directory within the agent's workspace.

**Install flow:**

1. Validate plugin file paths
2. Start the container (if not running)
3. Create the agent's Linux user
4. Install system dependencies via `apk`
5. Create plugin directory and seed files via VirtioFS
6. Configure secrets from Keychain
7. Run the setup command
8. Register plugin tools

**Managing plugins:**

- Open Management window → **Sandbox** → **Plugins** tab
- **Import** plugins from JSON files, URLs, or GitHub repos
- **Create** new plugins with the built-in editor
- **Install** plugins to specific agents
- **Export** and **duplicate** plugins for sharing

### Plugin Tools

Each tool in a plugin's `tools` array becomes an AI-callable tool. The tool name is `{pluginId}_{toolId}`.

Parameters are passed as environment variables with the prefix `PARAM_`:

| Parameter Name | Environment Variable |
|---------------|---------------------|
| `file` | `$PARAM_FILE` |
| `query` | `$PARAM_QUERY` |
| `output_format` | `$PARAM_OUTPUT_FORMAT` |

The `run` field is a shell command executed as the agent's Linux user with the working directory set to the plugin folder.

---

## Secret Management

Agents can check for and store secrets (API keys, tokens) using `sandbox_secret_check` and `sandbox_secret_set`. Secrets are stored in the macOS Keychain, scoped per agent.

### Two Storage Paths

| Path | When | How |
|------|------|-----|
| **Direct** | Agent already has the value (e.g., received via Host API or Telegram bot) | Pass `value` parameter to `sandbox_secret_set` |
| **Prompt** | Agent needs the user to provide the value (Chat) | Omit `value` — a secure overlay appears with `SecureField` input |

The prompt path keeps secret values out of the conversation history and LLM context entirely. The execution loop pauses via `withCheckedContinuation` until the user submits or cancels.

### Prompt Flow

1. Agent calls `sandbox_secret_set` without `value`
2. Tool returns a `secret_prompt` marker (JSON with key, description, instructions)
3. The chat execution loop intercepts the marker and shows `SecretPromptOverlay`
4. User enters the secret value in a `SecureField` and submits (or cancels via button/ESC)
5. The value is stored in Keychain and the tool result is rewritten to `{"stored": true, "key": "..."}` (or cancelled)
6. Execution resumes with the sanitized result — the LLM never sees the secret

### Robustness

- `SecretPromptState` tracks a `resolved` flag, making `submit()` and `cancel()` idempotent
- `onDisappear` on the overlay calls `cancel()` as a safety net if the view is dismissed unexpectedly
- All session reset paths (`cancelExecution`, `finishExecution`, etc.) dismiss pending prompts before clearing state

### Secret Containment

Storing a secret is only half the problem — the other half is keeping its **value** out of the model context and the persisted transcript afterwards:

- **Output scrubbing.** Agent secrets are injected into the exec environment, so `echo $KEY` would otherwise land the value in the model's context. `SecretScrubber` rewrites every known secret value in `sandbox_exec` stdout/stderr, background-job log tails, and sandbox-plugin tool output to `[REDACTED:<ENV_KEY>]` before the result is enveloped. Longer values scrub first (substring-safe); values under 6 characters are exempt to avoid false positives on ordinary output.
- **Argument scrubbing.** When the agent uses the direct `value` path of `sandbox_secret_set`, the *recorded* copy of the tool-call arguments is rewritten (`value` → `[REDACTED]`) before it is persisted into chat history; execution still sees the original. The prompt path never carries the value through the model at all and remains the recommended flow — the tool description steers models toward it.

---

## Building New Tools (Agent-Authored Plugins)

Agents can author, package, and register new sandbox plugins at runtime. The plugin-authoring recipe is injected into the system prompt as a **`## Building new tools`** section whenever plugin creation is enabled for the session (it is not modeled as a loadable skill, so it never appears in the capabilities manifest, discover, search, or load). Both the in-process `sandbox_plugin_register` tool and the host-API `POST /api/plugin/create` endpoint funnel through one shared registration pipeline (`SandboxPluginRegistration.register`) so they cannot drift.

### Requirements

- `autonomousExec.enabled` must be `true` on the agent
- `autonomousExec.pluginCreate` must be `true` (the default in `AutonomousExecConfig`) — this is the single control for plugin creation; turning it off both suppresses the injected section and disables `sandbox_plugin_register`

### Workflow

1. Agent writes script files to `~/plugins/{plugin-id}/scripts/` (or any subdirectory)
2. Agent writes a `plugin.json` manifest defining the plugin name, description, tools, and dependencies
3. Agent calls `sandbox_plugin_register` with the `plugin_id` (or the host-CLI calls `POST /api/plugin/create`)
4. The shared registration pipeline validates the plugin, applies restricted defaults, persists to `SandboxPluginLibrary`, runs the install, and hot-registers the tools via `CapabilityLoadBuffer`
5. A non-blocking toast notifies the user with a **Remove** action for later review

### File Auto-Packaging

When `sandbox_plugin_register` loads a plugin directory, it recursively collects every UTF-8 readable file (excluding `plugin.json` itself) and merges them into the plugin's `files` map. Files explicitly defined in `plugin.json` take precedence over auto-discovered ones. **Binary files are rejected up-front** — `plugin.files` is text-only and silently dropped binaries would break library-driven reinstalls. Either remove them, regenerate them at install time in `setup`, or fetch them from a setup-allowlisted host.

### Restricted Defaults (`SandboxPluginDefaults`)

Every agent-authored plugin is rewritten to enforce safe defaults before persistence:

- **`permissions.network`** is sanitised. Wildcard values (`outbound`) collapse to `none`. Comma-separated domain lists are accepted as-is when every entry parses as a valid domain; invalid lists collapse to `none`. Plan accordingly — declare exact API hostnames you need.
- **`permissions.inference`** is forced to `false`. Agent-authored plugins cannot call inference APIs.
- **`metadata.created_by`** is stamped to `agent`; **`metadata.created_via`** records `agent_tool` or `host_bridge`.

### Validation Guarantees

The shared pipeline rejects a registration up-front (no library state is written) when:

- File paths fail `SandboxPathSanitizer.validatePluginFiles`
- The `setup` command references a host outside `SandboxNetworkPolicy.setupAllowlist`
- Any tool's `run` command references a host outside the same allowlist
- A declared `secrets` entry has no value in `AgentSecretsKeychain` for the requesting agent
- The agent exceeds `SandboxRateLimiter` quota for `service: "http"`
- The sandbox container is not running (`unavailable` → HTTP 503)

### Plugin Persistence

Registered plugins are saved to the `SandboxPluginLibrary` (`~/.osaurus/sandbox-plugins/`) and survive app restarts. Per-agent install state lives under `~/.osaurus/agents/{agent-id}/sandbox-plugins/installed.json`. Manage, export, or remove plugins from the **Sandbox → Plugins** tab.

### Capture Capability Policy

Screenshot or screen-capture access is policy-defined but not installed as a
default tool. A capture request is denied unless a trusted plugin owns the
capability, the plugin is installed and enabled, the user explicitly opted in,
the plugin has a permission grant, and the request is interactive. Background
capture is always denied. Denials use stable codes:
`unknownCapability`, `pluginNotInstalled`, `pluginDisabled`,
`userOptInRequired`, `missingPermissionGrant`, and
`backgroundCaptureDenied`.

---

## Host API Bridge

The Host API Bridge connects the container to Osaurus services on the host. Inside the container, the `osaurus-host` CLI communicates with the bridge server over a vsock-relayed Unix socket.

| Command | Description |
|---------|-------------|
| `osaurus-host secrets get <name>` | Read a secret from the macOS Keychain |
| `osaurus-host config get <key>` | Read a plugin config value |
| `osaurus-host config set <key> <value>` | Write a plugin config value |
| `osaurus-host inference chat -m <message>` | Run a chat completion through Osaurus |
| `osaurus-host agent dispatch <id> <task>` | Dispatch a task to an agent |
| `osaurus-host agent memory query <text>` | Search agent memory |
| `osaurus-host agent memory store <text>` | Store a memory entry |
| `osaurus-host events emit <type> [payload]` | Emit a cross-plugin event |
| `osaurus-host plugin create` | Create a plugin from stdin JSON |
| `osaurus-host log <message>` | Append to the sandbox log buffer |

### Bridge authentication

Every request authenticates with a per-agent bearer token:

- The host mints a 256-bit token per agent and writes it to `/run/osaurus/<linuxName>.token` inside the guest, mode `0600`, owned by that agent's Linux user. The directory is mode `0711` so users can open their own file by name without enumerating siblings.
- The `osaurus-host` shim reads the token (allowed by uid) and sends it as `Authorization: Bearer <token>`. The shim refuses to run if the token file is missing or unreadable.
- The bridge resolves the token to an `(agentId, linuxName)` pair via `SandboxBridgeTokenStore`. Unknown or missing tokens get `401` — there is **no fallback to a default agent**.
- `X-Osaurus-User` is no longer trusted. Identity is bound to the token, which is bound to a Linux uid by file permissions inside the guest.
- `X-Osaurus-Plugin` is still self-reported by the shim. It namespaces config and secrets within an agent but is not a security boundary between plugins of the same agent.

The `agent dispatch` route additionally rejects any body whose `agent_id` doesn't match the token-bound identity (`403`); `agent memory query` filters results to the calling agent's pinned facts.

Tokens are revoked when the agent is unprovisioned or the container is stopped, and re-minted on the next `ensureProvisioned`. After an Osaurus upgrade, plugin bridge calls fail closed until the container restarts and the new shim and token files are written — this happens automatically when Sparkle relaunches the app.

### Request size limits

Bridge requests are capped at **8 MiB** per body. Oversized requests are rejected with `413 Payload Too Large` before reaching any handler. Combined with the public HTTP server's pre-auth caps (32 MiB generic, 64 KiB on `/pair`), this prevents an unauthenticated client from forcing unbounded memory allocation.

---

## Security

### Path Sanitization

All file paths from tool arguments are validated by `SandboxPathSanitizer` before any container execution. Directory traversal attempts (`..`) are rejected, and paths are resolved relative to the agent's home directory.

### Per-Agent Isolation

Each agent runs as a separate Linux user (`agent-{name}`). Standard Unix file permissions prevent agents from accessing each other's files and processes.

### Network Policy

Container networking can be set to `outbound` (NAT with internet access) or `none` (completely isolated). Plugins can declare their own network requirements in the `permissions` field.

### Rate Limiting

- `SandboxExecLimiter` — Limits the number of commands an agent can run per conversation turn
- `SandboxRateLimiter` — General rate limiting for sandbox operations and Host API bridge calls

### Artifact Integrity

Every external artifact the sandbox depends on is pinned to an immutable digest, and downloaded blobs are verified before they touch the on-disk container store. A registry, CDN, or release-host compromise cannot silently change the boundary the sandbox enforces.

| Artifact | Pin |
|----------|-----|
| GHCR image (`ghcr.io/osaurus-ai/sandbox`) | Multi-arch index digest (`@sha256:...`); the `:latest` tag is never used at runtime |
| Kata kernel tarball | SHA-256 verified after download against an in-source constant |
| Initfs blob | SHA-256 verified after download against an in-source constant |

A digest mismatch is **fail-closed**: the temp file is deleted, alternate mirrors are not tried (silent fallback would mask exactly the upstream-compromise scenario this defends against), and provisioning aborts with `SandboxError.integrityCheckFailed`. The hashing pass is bounded at 512 MiB to stop a runaway download from turning into a multi-GB hash job.

To rotate a pin (e.g. after intentionally bumping the sandbox image): fetch the new digest with `crane digest …` or `docker buildx imagetools inspect …`, paste the multi-arch index digest into `containerImage` in `SandboxManager.swift`, and update the corresponding SHA-256 constants alongside the URL in the same file.

---

## Diagnostics

The Sandbox UI includes built-in diagnostic checks accessible from the **Container** tab. Click **Run Diagnostics** to verify the container is functioning correctly.

| Check | What It Verifies |
|-------|-----------------|
| Exec | Can execute commands in the container |
| NAT | Outbound network connectivity |
| Agent User | Agent's Linux user exists and can run commands |
| APK | Package manager is functional |
| Vsock Bridge | Host API bridge is reachable from the container |

---

## Container Management

### Start / Stop

- **Start** — Boots the container (provisions first if needed)
- **Stop** — Gracefully shuts down the container

### Reset

Removes the container and re-provisions from scratch. All agent workspaces and installed plugins are preserved (they live in the VirtioFS-mounted `/workspace`).

### Remove

Completely removes the container and all associated assets (kernel, init filesystem). Agent workspaces are preserved.

Access these operations from the **Container** tab → **Danger Zone** section.

---

## Storage Paths

| Path | Description |
|------|-------------|
| `~/.osaurus/container/` | Container root directory |
| `~/.osaurus/container/kernel/vmlinux` | Linux kernel |
| `~/.osaurus/container/initfs.ext4` | Initial filesystem |
| `~/.osaurus/container/workspace/` | Mounted as `/workspace` in the VM |
| `~/.osaurus/container/workspace/agents/{name}/` | Per-agent home directory |
| `~/.osaurus/container/workspace/agents/{name}/SOUL.md` | Per-agent SOUL identity layer (seeded on first provision; agent-editable) |
| `~/.osaurus/container/output/` | Mounted as `/output` in the VM |
| `~/.osaurus/sandbox-plugins/` | Plugin library (JSON recipes) |
| `~/.osaurus/agents/{agentId}/sandbox-plugins/installed.json` | Per-agent installed plugin records |
| `~/.osaurus/config/sandbox.json` | Sandbox configuration |
| `~/.osaurus/config/sandbox-agent-map.json` | Linux username to agent UUID mapping |
