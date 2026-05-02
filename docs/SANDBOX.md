# Sandbox

Run agent code in an isolated Linux virtual machine — safely, locally, and with full dev environment capabilities.

The Sandbox is a shared Linux container powered by Apple's [Containerization](https://developer.apple.com/documentation/containerization) framework. It gives every Osaurus agent access to a real Linux environment with shell, package managers, compilers, and file system access — all running natively on Apple Silicon with zero risk to your Mac.

---

## Why Sandbox?

### Safe Execution

Agents can run arbitrary code, install packages, and modify files without any risk to the host macOS system. The VM is a disposable, resettable environment. If something goes wrong, reset the container and start fresh — your Mac is never affected.

### Real Dev Environment

Agents gain a full Linux environment with shell access, Python (pip), Node.js (npm), system packages (apk), compilers, and standard POSIX tools. This far exceeds what macOS-sandboxed tools can offer, enabling agents to build, test, and run real software.

### Multi-Agent Isolation

Each agent gets its own Linux user and home directory. One agent's files, processes, and installed packages cannot interfere with another's. Run multiple specialized agents simultaneously — a Python data analyst, a Node.js web developer, and a system administration agent — without cross-contamination.

### Lightweight Plugin Ecosystem

Sandbox plugins are simple JSON recipes. No compiled dylibs, no Xcode, no code signing required. Anyone can write, share, and import plugins that install dependencies, seed files, and define custom tools — dramatically lowering the barrier to extending agent capabilities.

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

### 4. Install Plugins (Optional)

Switch to the **Plugins** tab to browse, import, or create sandbox plugins that extend your agents with custom tools.

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

## Built-in Tools

When the container is running, sandbox tools are automatically registered for the active agent. Read-only tools are always available. Write and execution tools require `autonomous_exec` to be enabled on the agent.

### Anti-confusion cheat sheet (always prefer the dedicated tool)

| Don't                                | Do                                                                                                              |
|--------------------------------------|------------------------------------------------------------------------------------------------------------------|
| `cat` / `head` / `tail` in `sandbox_exec` | `sandbox_read_file`                                                                                              |
| `grep` / `rg` / `find` / `ls` in `sandbox_exec` | `sandbox_search_files` — `target="content"` (rg) or `target="files"` (find).                                     |
| `sed` / `awk`                        | `sandbox_edit_file` (`old_string` → `new_string`)                                                                 |
| `echo` / `cat` heredoc to create files | `sandbox_write_file`                                                                                             |
| `&` / `nohup` / `disown` for backgrounding | `sandbox_exec(background:true)` — pid + log_file ride back, manage with `sandbox_process` (poll/wait/kill)        |

Reserve `sandbox_exec` for builds, installs, git, processes, network calls, package managers, and any work that doesn't have a dedicated tool above. For ≥3 tool calls with logic between them, `sandbox_execute_code` lets you write a Python script that imports the same tools as helper functions.

### Always Available (Read-Only)

| Tool | Description |
|------|-------------|
| `sandbox_read_file` | Read a file's contents from the sandbox (supports line ranges, tail, char cap) |
| `sandbox_search_files` | Search file contents (`target="content"`, ripgrep) **or** find files by name (`target="files"`, glob). Folded the previously-separate `sandbox_find_files` and `sandbox_list_directory` here. |

### Requires Autonomous Exec

| Tool | Description |
|------|-------------|
| `sandbox_write_file` | Write content to a file (creates parent directories) |
| `sandbox_edit_file` | Edit a file by exact string replacement — `old_string` must match exactly once |
| `sandbox_exec` | Run a shell command. Foreground (default, max 300s) **or** `background:true` for servers/long tasks (the spawn shim returns immediately with `pid` + `log_file`). Pair the background form with `sandbox_process`. |
| `sandbox_process` | Manage background jobs: `action="poll"` (alive + log tail), `"wait"` (block until exit, capped by `timeout`), `"kill"` (`force:true` for SIGKILL). |
| `sandbox_execute_code` | Run a Python script that imports `read_file` / `write_file` / `edit_file` / `search_files` / `terminal` / `share_artifact` from `osaurus_tools`. Use for ≥3 tool calls with logic between them. 5-min timeout, 50KB stdout cap, 50 tool calls per script. |
| `sandbox_install` | Install system packages via `apk` (runs as root). Auto-refreshes the package index before install; serializes across all agents on a single apk lock. |
| `sandbox_pip_install` | Install Python packages into the agent's venv at `~/.venv/`. Auto-creates the venv on first use; the venv's `python3` and installed scripts are on PATH from any `sandbox_exec` cwd. 240s timeout, runs with `--disable-pip-version-check --no-input`. |
| `sandbox_npm_install` | Install Node packages into a per-agent project workspace at `~/.osaurus/node_workspace/`. Bootstraps `package.json` on first use; installed CLI binaries are on PATH from any `sandbox_exec` cwd. 240s timeout, runs with `--no-audit --no-fund --no-update-notifier`. |
| `sandbox_secret_check` | Check whether a secret exists for this agent (never reveals the value) |
| `sandbox_secret_set` | Store a secret securely — pass `value` directly or omit to prompt the user |
| `sandbox_plugin_register` | Register an agent-created plugin (requires `pluginCreate` permission) |

The previously-discrete `sandbox_list_directory`, `sandbox_find_files`, `sandbox_move`, `sandbox_delete`, `sandbox_exec_background`, and `sandbox_run_script` tools were dropped. Their behaviour now comes from a flag (`background:true` on `sandbox_exec`, `target` on `sandbox_search_files`) or a direct shell invocation (`mv` / `rm` in `sandbox_exec`). `sandbox_run_script`'s use case — multi-step Python orchestration — moved to `sandbox_execute_code`.

`share_artifact` is a global built-in (registered in `ToolRegistry`) and is the only way for sandbox-generated content to reach the chat thread. It's not in this sandbox-specific list because it's available everywhere, not just in sandbox mode.

All file paths are validated on the host side before container execution by `SandboxPathSanitizer`, which now returns structured rejection reasons (empty, traversal, null byte, dangerous character, outside allowed roots). Tools surface the reason to the model in an `invalid_args` envelope so the next call self-corrects instead of retrying with the same bad path.

### Install hardening

The three install tools (`sandbox_install`, `sandbox_pip_install`, `sandbox_npm_install`) share a hardening pipeline:

| Layer | Behaviour |
|---|---|
| **Per-agent serialization** | `SandboxInstallLock` queues install operations behind each other per agent so two concurrent calls can't race on `node_modules/` / venv / apk db. **apk's lock is container-wide**, so `sandbox_install` calls serialize *globally across every agent* under a synthetic key — a slow `apk add` on agent A briefly blocks agent B's `apk add`. npm/pip installs are isolated per-agent and run concurrently across agents. |
| **Auto-recovery** | If the first attempt fails AND its output matches a known stale-state signature (`Tracker "idealTree" already exists`, `EEXIST`, `ELOCKED` for npm; `Could not install packages due to an OSError`, `ReadTimeoutError` for pip; `temporary error`, `unable to lock database` for apk), the tool runs a tool-specific cleanup and retries once. The result envelope includes `retried: true` so the model can see the recovery happened. |
| **Cleanup actions** | npm: `rm -rf node_modules/.package-lock.json && npm cache clean --force`. pip: `pip cache purge`. apk: `apk update`. All run in the same exec context (agent for npm/pip, root for apk) as the install attempt. |
| **Workspace isolation** | npm installs into `~/.osaurus/node_workspace/` (bootstraps `package.json` on first use). pip installs into the agent's venv at `~/.venv/`. Both have their `bin/` on PATH from any `sandbox_exec` cwd. |
| **Stable flags** | npm: `--no-audit --no-fund --no-update-notifier`. pip: `--disable-pip-version-check --no-input`. apk: `--no-cache` plus a leading `apk update --quiet`. |
| **Timeouts** | npm/pip: 240s (covers cold-cache installs of large packages like torch / pandas / scoped npm packages). apk: 120s. |

### Result shape

Every sandbox tool returns a [ToolEnvelope](TOOL_CONTRACT.md) JSON string. Success payloads in `result`:

- Read/inspect: `{path, content, size}` (+ optional `start_line`/`line_count`/`tail_lines`/`max_chars`).
- Search: `{pattern, target, path, matches}` — `target` is `"content"` or `"files"`.
- Exec foreground: `{stdout, stderr, exit_code, cwd}`. Background (`background:true`): `{pid, log_file, cwd, background:true}`.
- Process management: `{pid, alive|exited|killed, log_file, log_tail, ...}`.
- `sandbox_execute_code`: `{stdout, stderr, exit_code, tool_calls, cwd}`.
- Install family: `{installed, exit_code, output}` on success; `execution_error` envelope on non-zero exit. Both shapes carry `retried: true` when the auto-recovery harness ran a cleanup + second attempt. Failure envelopes additionally carry `cleanup_failed: true` if the cleanup step itself threw — that signals to the model that it should not retry the same operation right away.

Failures use `kind: invalid_args` with `field` pointing at the offending argument (`path`, `cwd`, `content`, etc.) so the model can self-correct on the next turn.

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

---

## Sandbox Plugin Creator (Agent-Authored Plugins)

Agents can author, package, and register new sandbox plugins at runtime. The model-facing skill is named **Sandbox Plugin Creator** and is injected into the system prompt automatically when an autonomous agent has no other plugin/MCP tools available. Both the in-process `sandbox_plugin_register` tool and the host-API `POST /api/plugin/create` endpoint funnel through one shared registration pipeline (`SandboxPluginRegistration.register`) so they cannot drift.

### Requirements

- `autonomousExec.enabled` must be `true` on the agent
- `autonomousExec.pluginCreate` must be `true` (the default in `AutonomousExecConfig`)
- The **Sandbox Plugin Creator** skill must be enabled (it is, by default — disable it in the skill catalog to suppress the auto-injected backstop)

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
| `~/.osaurus/container/output/` | Mounted as `/output` in the VM |
| `~/.osaurus/sandbox-plugins/` | Plugin library (JSON recipes) |
| `~/.osaurus/agents/{agentId}/sandbox-plugins/installed.json` | Per-agent installed plugin records |
| `~/.osaurus/config/sandbox.json` | Sandbox configuration |
| `~/.osaurus/config/sandbox-agent-map.json` | Linux username to agent UUID mapping |
