# Sandbox

Run agent code in an isolated Linux virtual machine — safely, locally, and with full dev environment capabilities.

The Sandbox is a Linux VM powered by Apple's [Containerization](https://developer.apple.com/documentation/containerization) framework, with one container per agent inside it. It gives every Osaurus agent access to a real Linux environment with shell, package managers, compilers, and file system access — all running natively on Apple Silicon inside a hardware virtual machine, keeping agent code off your macOS system. (See [Security Boundaries](#security) for what the VM does and does not isolate.)

> **Sandbox Tools vs Native Plugins:** Osaurus has two distinct extensibility systems. **Sandbox tools** (this guide) are JSON recipes that run inside the Linux container — no compiler, no code signing, ideal for shell-based workflows. **Native plugins** are compiled `.dylib` files with full host API access (inference, storage, HTTP routes, web UIs); see [`docs/plugins/README.md`](plugins/README.md). The terms used to overlap; this doc uses **Sandbox Tools** consistently.

---

## Why Sandbox?

### Safe Execution

Agents can run arbitrary code, install packages, and modify files inside a disposable, resettable VM instead of on your Mac. If something goes wrong, reset the container and start fresh. The VM boundary protects the host filesystem and processes; sandboxed code can still use whatever network egress and host-bridge capabilities you grant it, so those are policy-controlled separately (see [Network Policy](#network-policy)).

### Real Dev Environment

Agents gain a full Linux environment with shell access, Python (pip), Node.js (npm), system packages (apk), compilers, and standard POSIX tools. This far exceeds what macOS-sandboxed tools can offer, enabling agents to build, test, and run real software.

### Multi-Agent Isolation

Each agent runs in its own container inside the VM, with its own root filesystem, process namespace, Linux user, and home directory. A container mounts only its agent's home and the shared folder, so other agents' files and processes are not visible at all. Packages installed with `apk` persist in that agent's own environment and never affect another agent. See [Pod isolation](#pod-isolation) for exactly what is and isn't separated.

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

On earlier macOS versions the sandbox automatically falls back to a native macOS Seatbelt backend — see [Seatbelt Fallback](#seatbelt-fallback-macos-15-and-earlier).

---

## Seatbelt Fallback (macOS 15 and earlier)

On Macs that can't run the Containerization VM, Osaurus still offers sandboxed execution using the system's Seatbelt facility (`sandbox-exec`). Commands run as regular host processes confined by a deny-by-default sandbox profile: they can read the system but can only write inside the sandbox workspace (`~/.osaurus/container/workspace/`, seen by agents as `/workspace`) and a scratch temp directory. The backend is chosen once at launch — macOS 26+ always uses the VM, older systems always use Seatbelt.

Everything in this guide applies to both backends unless noted. The differences:

| | Linux VM (macOS 26+) | Seatbelt (earlier) |
|---|---|---|
| Environment | Alpine Linux, full userland | macOS, BSD userland |
| Package managers | `pip`, `npm`, `apk` | `pip`, `npm` (no `apk`) |
| Tool recipe `dependencies` | Supported | Not supported — install via `setup` with pip/npm |
| Network policy | Off, on, or per-domain allowlist | All-or-nothing. A configured domain allowlist can't be enforced and fails closed to no network. An open agent still can't connect to the Mac's loopback (`localhost`), where the Osaurus server and other local services listen |
| Isolation boundary | Hardware VM, separate filesystem | Process-level write confinement. Reads of the host are not blocked |
| Per-agent environments | Separate Linux users, optional per-agent rootfs | Shared workspace tree with per-agent home directories |
| Sandboxed MCP servers | Supported | Not supported — set the provider's Run in to Host |
| Provisioning | Kernel + rootfs download (~1 min) | Instant, no download |

Two behavioral notes for Seatbelt: denied file lookups surface as "No such file or directory" rather than "Operation not permitted" (deliberate macOS anti-probing behavior), and `~` inside sandboxed commands resolves to the agent's workspace home, not your macOS home.

---

## Getting Started

### 1. Let the First Command Set It Up

Most people never open the Sandbox page. The first custom-agent chat that needs sandbox execution sets the sandbox up, and the chat shows **Preparing sandbox** with download progress in that turn. Stopping the chat during first-time setup cancels it; downloads resume next time.

### 2. Or Set It Up Ahead of Time

Open Settings… (`⌘,`) → **Developer Tools** → **Sandbox** and click **Set Up Sandbox** to download the Linux kernel and initial filesystem, then boot the sandbox. This is a one-time setup that takes about a minute. If you leave setup deferred, the first custom-agent chat that needs sandbox execution receives the transient `sandbox_init_pending` tool. Calling it waits for provisioning and, on success, adds the real sandbox schemas to the next model step in that same run. A startup failure returns an actionable `unavailable` envelope instead of requiring a blind retry.

### 3. Start Using Sandbox Tools

Once the container is running, sandbox tools are registered as one canonical process-wide runtime surface. Every call resolves the requesting agent from its chat/work execution context, so concurrent and non-active agent runs keep their own Linux user, home, config, secrets, package manifest, and plugin scope. Calls without an authorized request configuration fail closed. The model sees the stable public workspace names (`file_read`, `file_search`, `file_write`, `file_edit`, `shell_run`) plus enabled control-plane tools such as `sandbox_install` and `sandbox_plugin_register`; backend-specific `sandbox_read_file` / `sandbox_exec` adapters stay private. Capability ids name Osaurus tools/skills; sandbox commands and Python/Node libraries are separate and are checked with `shell_run` or installed with `sandbox_install`.

### 4. Sandbox Plugins (Optional)

With **Plugin Creation** on (Agents → the agent → Sandbox), an agent can write JSON tool recipes and register them with `sandbox_plugin_register`; their tools then appear read-only in **Tools & MCP** → **All Tools**. For native dylib plugins (full host API access), use **Tools & MCP** → **Plugins** and see [`docs/plugins/README.md`](plugins/README.md).

---

## Provisioning Preflight

Before provisioning, or when a sandbox setup looks unhealthy, open the
Settings… (`⌘,`) → **Developer Tools** → **Sandbox** →
**Troubleshooting** and use **Provisioning Preflight**. The report inspects the resolved Osaurus root, config directory
and `sandbox.json`, cache directory, temporary directory, container workspace,
agent/shared workspace roots, kernel/initfs assets, the rootfs template or an
agent environment, and the system container's bridge socket.

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
┌───────────────────────────────────────────────────────────────────┐
│                           macOS Host                              │
│                                                                   │
│  ┌──────────────┐   ┌───────────────────────────────────────────┐ │
│  │   Osaurus    │   │  Linux VM (LinuxPod)                      │ │
│  │              │   │                                           │ │
│  │  SandboxMgr ─┼───┤→ container agent-alice                    │ │
│  │              │   │    /workspace/agents/alice  (VirtioFS)    │ │
│  │  HostAPI  ←──┼─vsock─→ /tmp/osaurus-bridge.sock (alice only) │ │
│  │  Bridge      │   │    /workspace/shared        (VirtioFS)    │ │
│  │              │   │→ container agent-bob  (same shape)        │ │
│  │  ToolReg  ←──┼───┤→ container osaurus-system (no workspace)  │ │
│  └──────────────┘   └───────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────────────────┘
```

**Key components:**

| Component | Description |
|-----------|-------------|
| **Linux VM** | Alpine Linux with Kata Containers 3.32.0 production ARM64 kernel, 8 GiB root filesystem |
| **Pod** | One VM holding a container per agent plus a system container. Each agent container boots its own copy-on-write clone of the base image and has its own mount, PID, IPC, and UTS namespaces |
| **VirtioFS Mounts** | An agent container mounts only `~/.osaurus/container/workspace/agents/{name}/` at `/workspace/agents/{name}` and `workspace/shared/` at `/workspace/shared`. The `osaurus-host` shim is a read-only file mount |
| **Networking** | vmnet-backed interface shared by the pod: shared NAT in `outbound` mode, host-only + filtering egress proxy in `proxy` mode, absent in `none` mode |
| **Vsock Bridge** | One Unix socket per container, relayed via vsock to the Host API Bridge server; each socket accepts only its own agent's token |
| **Per-Agent Users** | Each agent gets a Linux user `agent-{name}` with home at `/workspace/agents/{name}/`, in its own container |
| **System Container** | `osaurus-system`: no workspace mounts. Runs the network readiness probe, VM metrics, and diagnostics |
| **Host API Bridge** | HTTP server on the host, accessible from the container via `osaurus-host` CLI shim |

---

## Configuration

Configure the container in Settings… (`⌘,`) → **Developer Tools** → **Sandbox** → **Settings**.

| Setting | Range | Default | Description |
|---------|-------|---------|-------------|
| CPUs | 1–8 | 2 | Virtual CPU cores allocated to the VM |
| Memory | 1–8 GB | 2 GB | RAM allocated to the VM, shared by all agent containers (also each container's limit) |
| Network | outbound / proxy / none | outbound | `outbound` = unrestricted NAT; `proxy` = host-only network with a domain-allowlist egress proxy (set per-agent Allowed Domains in Agent settings); `none` = no networking |
| Agents Kept Warm | 1–8 | 3 | How many agents keep their own container in the VM at once (see [Agent environments](#agent-environments-and-pod-membership)) |
| Auto-Start | on / off | on | Start the sandbox when Osaurus launches; when off, it starts the first time an agent runs a command |

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

### Rootfs templates and copy-on-write boots

The first cold boot unpacks the pinned OCI image into an 8 GiB ext4 image
that becomes the immutable **base template**
(`~/.osaurus/container/templates/`, keyed by image digest + rootfs format
version). Every container in the pod boots its own APFS `clonefile` of it —
an instant, block-sharing copy. Templates are never booted or mutated; a
pod that won't boot from its clones triggers exactly one fall back to a
full unpack, which drops the template and the members' clones first.
Templates and environments are excluded from Time Machine.

Templates and environments are keyed by `rootfsFormatVersion`, not by the
Containerization SDK version. An SDK bump changes `runtimeFormatVersion`,
which re-pulls only the ~64 MiB `vminit` initfs; existing environments stay
warm. `rootfsFormatVersion` changes only when the unpacked filesystem itself
becomes incompatible (see `SandboxRuntimeAssets.swift`).

### Agent environments and pod membership

Each agent's container boots from the agent's own clone of the template
(`~/.osaurus/container/environments/<agent>/rootfs.ext4`). System packages
an agent installs with `apk` persist there and are invisible to other
agents. The system container has one too (`environments/osaurus-system/`).
Agent home directories live on the VirtioFS workspace and are never
affected by environment eviction or reset.

Virtualization.framework can't add a device to a running VM, so the set of
containers is fixed when the VM boots. Each boot includes the agent that
asked for the sandbox and the most recently used others, up to **Agents
Kept Warm**. When another agent needs the sandbox, Osaurus restarts the VM
with that agent included: it first waits (up to two minutes) for other
agents' running commands and background jobs, then reboots warm, which
takes well under a second plus guest setup. Long-lived processes such as
stdio MCP servers restart with it. Clones beyond the cap are evicted least
recently used first and re-clone fresh on the next use.

Approximate cost per extra agent, measured on Containerization 0.54: about
0.06 s of boot time, about 60 MB of host memory for a light workload (the
VM's Memory setting caps the total), and no extra disk until the agent's
clone diverges from the template.

Each container has its own `/etc`, so user setup for one agent never
touches another's. Within a container, user changes (`adduser`, `deluser`)
run one at a time, and every boot clears lock files (`/etc/passwd+` and
friends) left by a run that was killed mid-write. When setup fails because
a disk is full, the error says which: the Mac's disk, or the agent's
environment, which the agent's packages can fill (reset it in Developer
Tools → Sandbox).

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
| Edit | Any time during a sandbox session | The agent edits its own soul via `file_write` or `file_edit`. Edits apply on the **next** session — within the active turn the cached system prompt stays byte-stable for KV-cache reuse. |

### Precedence with persona

Persona (the user-authored `systemPrompt` on the Agent) wins on conflict. Two reinforcements: render order pins persona above SOUL, and the SOUL section's intro line states "the user's instructions in earlier sections take precedence." In practice the two operate at different scopes (persona = role, SOUL = preferences) and direct conflict is rare.

### Reset

To wipe an agent's soul, delete `~/.osaurus/container/workspace/agents/{name}/SOUL.md`. The next provision will re-seed the boilerplate; the next chat compose will pick it up.

Sandbox-only by design — folder-mode agents are short-lived and project-bound.

---

## Built-in Tools

When the container is running, sandbox tools are automatically registered for the active agent. Model-facing file and shell operations use the same five names as folder mode and route to the sandbox backend through the request execution scope. Write and execution tools require `autonomous_exec` to be enabled on the agent.

> **Default ON for new custom agents (where supported):** The built-in Default agent is configuration-only and never receives autonomous execution. On supported machines, newly created custom agents default on. To avoid a surprise multi-GB download, a never-set-up sandbox stays un-provisioned until first use. The model initially sees only `sandbox_init_pending`; that call awaits boot and per-agent provisioning, then replaces itself with the real public tools in the same run. The placeholder is never frozen into the session baseline. Setting up from the Sandbox page or toggling a custom agent off→on also boots immediately; later launches auto-start after `setupComplete`.

### Anti-confusion cheat sheet (always prefer the dedicated tool)

| Don't                                | Do                                                                                                              |
|--------------------------------------|------------------------------------------------------------------------------------------------------------------|
| `cat` / `head` / `tail` in `shell_run` | `file_read`                                                                                                    |
| `grep` / `rg` / `find` / `ls` in `shell_run` | `file_search`                                                                                             |
| `sed` / `awk`                        | `file_edit` with `old_string` → `new_string`                                                                    |
| `echo` / `cat` heredoc to create files | `file_write` with `content`                                                                                   |
| `&` / `nohup` / `disown` for backgrounding | `shell_run` with its background option, then `sandbox_process` (poll/wait/kill)                         |

Reserve `shell_run` for builds, git, processes, network calls, and work without a dedicated tool. Use `sandbox_install` for package installation. For multi-line scripts, write the script with `file_write`, then run it with `shell_run`.

### Always Available (Read-Only)

| Tool | Description |
|------|-------------|
| `file_read` | Read a file or list a directory in the sandbox |
| `file_search` | Search sandbox file contents or find files by name |

`file_read` uses a bounded raw path for plain text, source, and
CSV/TSV: it reads at most 5 MiB before UTF-8 decoding and returns explicit
metadata when that cap truncates the preview. Rich documents and XLSX previews
use the document-adapter limits instead.

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
| `file_write` / `file_edit` | Create or replace files, or make an exact in-place edit |
| `shell_run` | Run a shell command in the sandbox; background jobs pair with `sandbox_process` |
| `sandbox_process` | Manage background jobs: `action="poll"` (alive + log tail), `"wait"` (block until exit, capped by `timeout`), `"kill"` (`force:true` for SIGKILL). |
| `sandbox_install` | Install exact package specifiers, one tool for all three managers via the required `manager` argument: `apk` (system packages, runs as root, auto-refreshes the index, serializes globally on apk's container-wide lock), `pip` (Python packages into the agent venv at `~/.venv/`, auto-created on first use, `--disable-pip-version-check --no-input`), or `npm` (Node packages into a per-agent workspace at `~/.osaurus/node_workspace/`, bootstraps `package.json`, `--no-audit --no-fund --no-update-notifier`). Try guessed alternative package names in separate calls; one invalid specifier fails a multi-package request. Python/Node libraries and CLI binaries resolve from any `shell_run` cwd (`NODE_PATH` includes the per-agent npm workspace). 240s timeout for pip/npm, 120s for apk. |
| `sandbox_secret_check` | Check whether a secret exists for this agent (never reveals the value) |
| `sandbox_secret_set` | Store a secret securely — pass `value` directly or omit to prompt the user |
| `sandbox_plugin_register` | Register an agent-created plugin (requires `pluginCreate` permission) |

The backend-specific `sandbox_read_file`, `sandbox_search_files`, `sandbox_write_file`, and `sandbox_exec` implementations remain registered but private. The public workspace tools route to them only after request mode, path, and execution-scope checks. Control-plane tools stay public only under their owning gates: process management requires background jobs, and registration requires Plugin Creation. Direct manual selection or a stale loaded-tool name cannot restore a hidden adapter or disabled control.

`share_artifact` is a global built-in (registered in `ToolRegistry`) and is the only way for sandbox-generated content to reach the chat thread. It's not in this sandbox-specific list because it's available everywhere, not just in sandbox mode.

All file paths are validated on the host side before container execution by `SandboxPathSanitizer`, which now returns structured rejection reasons (empty, traversal, null byte, dangerous character, outside allowed roots). Tools surface the reason to the model in an `invalid_args` envelope so the next call self-corrects instead of retrying with the same bad path.

### Install hardening

`sandbox_install`'s three managers (`apk` / `pip` / `npm`) share a hardening pipeline:

| Layer | Behaviour |
|---|---|
| **Per-agent serialization** | `SandboxInstallLock` queues install operations behind each other per agent so two concurrent calls can't race on `node_modules/` / venv / apk db. **apk's lock is container-wide**, so `sandbox_install` calls serialize *globally across every agent* under a synthetic key — a slow `apk add` on agent A briefly blocks agent B's `apk add`. npm/pip installs are isolated per-agent and run concurrently across agents. |
| **Request validation** | A shared normalizer caps package count and specifier length, rejects empty/control-character/option-injection values, accepts registry names only (no URLs, `git+`/`file:` sources, paths, or archives; `@scope/name` is allowed), and POSIX-quotes every accepted apk/pip/npm argument. Plugin-declared `dependencies` use the same path. Malformed requests return `invalid_args` before agent or root execution. |
| **Network preflight** | A disabled network setting returns a non-retryable `rejected` envelope. Configured-but-unavailable egress returns retryable `unavailable` before invoking a package manager. Plugin dependency failures carry the same actionable setting/readiness detail. |
| **Auto-recovery** | If the first attempt fails AND its output matches a known stale/transient signature (`Tracker "idealTree" already exists`, `EEXIST`, `ELOCKED` for npm; `ReadTimeoutError`, temporary DNS/network failure, or a stale distutils install for pip; `temporary error`, `unable to lock database` for apk), the tool runs a tool-specific cleanup and retries once. The result envelope includes `retried: true` so the model can see the recovery happened. |
| **Failure classification** | Package/version-not-found and malformed-specifier failures are deterministic and return `retryable:false` with `failure_class:"package_resolution"`. Known network/lock failures remain retryable. Every failed attempt identifies the manager, requested specifiers, retry status, exit code, failure class, and a correction hint. |
| **Cleanup actions** | npm: `rm -rf node_modules/.package-lock.json && npm cache clean --force`. pip: `pip cache purge`. apk: `apk update`. All run in the same exec context (agent for npm/pip, root for apk) as the install attempt. |
| **Workspace isolation** | npm installs into `~/.osaurus/node_workspace/` (bootstraps `package.json` on first use). Its `node_modules/.bin` is on `PATH`, `node_modules` is on `NODE_PATH`, and an absent home-level `node_modules` is linked to the workspace so CommonJS and ESM files under the agent home use normal upward module lookup. pip installs into the agent's venv at `~/.venv/`, whose `bin/` is also on `PATH`. |
| **Stable flags** | npm: `--no-audit --no-fund --no-update-notifier`. pip: `--disable-pip-version-check --no-input`. apk: `--no-cache` plus a leading `apk update --quiet`. |
| **Timeouts** | npm/pip: 240s (covers cold-cache installs of large packages like torch / pandas / scoped npm packages). apk: 120s. |

### Installed-package awareness

So the model doesn't re-probe or reinstall what it already has, `SandboxPackageManifest` keeps a host-side, per-agent record (`~/.osaurus/agents/<uuid>/installed-packages.json`) of installed packages by manager. Three writers feed it: `SandboxAgentProvisioner` seeds it once per provision via a cheap lazy reconcile (lists only top-level packages from the agent's pip venv and reads direct npm dependencies from `package.json` — `apk` is skipped because the base image carries hundreds of system packages and bare `apk add` can't succeed unprivileged), `sandbox_install` appends successful installs, and successful plugin-declared apk dependencies are attributed to the owning agent.

Context propagation has two deliberate phases. In the same tool loop, the successful install result carries `installed`, `manager`, `summary`, and `exit_code` (plugin registration carries `installed_dependencies`). The system prompt is not recomposed between tool steps. On the next composed turn, `SystemPromptComposer` renders the persisted state as a compact, capped **"Installed sandbox packages"** block inside the *dynamic* `## Sandbox state` section (alongside configured secrets). It states that packages are used from shell/code rather than loaded as capability ids, and directs the model to verify any capped/unlisted name with `shell_run`. That section sits after the static prefix break, so package/secret changes stay fresh without invalidating the reusable prefix. The manifest is cleared on unprovision so a rebuilt container starts from observed truth.

`apk` modifies the shared container, so an installed system package is physically visible to every agent even though the prompt manifest records which agent requested it. Plugin registration rolls back failed library/install records and files, but it cannot safely uninstall an apk package that may already be used by another agent; that shared side effect remains explicit and recorded.

### Result shape

Every sandbox tool returns a [ToolEnvelope](TOOL_CONTRACT.md) JSON string. Success payloads in `result`:

- Read/inspect: `{path, content, size}` (+ optional `start_line`/`line_count`/`tail_lines`/`max_chars`).
- Search: `{pattern, target, path, matches}` — `target` is `"content"` or `"files"`.
- Exec foreground: `{stdout, stderr, exit_code, cwd}`. Background (`background:true`): `{pid, log_file, cwd, background:true}`.
- Process management: `{pid, alive|exited|killed, log_file, log_tail, ...}`.
- Install (`sandbox_install`): `{installed, manager, exit_code, summary}` on success — the verbose installer log is trimmed (it's pure context noise); the failure path returns an `execution_error` envelope with combined output plus `{manager, requested, retried, failure_class, exit_code}`. Deterministic resolution errors are non-retryable and tell the model to correct/remove the invalid specifier and try alternatives separately. Failure envelopes additionally carry `cleanup_failed: true` if the cleanup step itself threw. On success, the installed names are recorded in the host-side package manifest described above.

Malformed inputs use `kind: invalid_args` with `field` pointing at the offending argument (`path`, `cwd`, `content`, `packages`, etc.) so the model can self-correct on the next turn. Configuration refusals use `rejected`; transient network/backend readiness uses `unavailable`.

---

## Streaming Exec & Terminate

Model-facing `shell_run` (foreground or `background:true`) routes to the private `sandbox_exec` backend in sandbox mode; both routes stream live output into the chat tool-call card while the process runs. The model still gets the final `{stdout, stderr, exit_code}` blob when the process exits — streaming is purely a side-channel for the user.

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

**Don't use `2>/dev/null` in pipelines.** It hides errors from the result envelope. If you genuinely need silent stderr, redirect to a log file you can inspect with `file_read` later.

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
6. Configure secrets from the Vault (`PluginCredentials`; see [CREDENTIALS.md](CREDENTIALS.md))
7. Run the setup command
8. Register plugin tools

**Managing plugins:**

- Agents create recipes with `sandbox_plugin_register` while **Plugin Creation** is on (Agents → the agent → Sandbox); see [Sandbox Plugins (Optional)](#4-sandbox-plugins-optional) above.
- Registered recipes appear read-only under **Custom** in Settings → **Tools & MCP** → **All Tools**. There is no in-app recipe editor, importer, or exporter.

Saving a custom tool publishes its schemas immediately, and app
startup republishes every recipe in the library. The recipe is installed into
an agent's isolated workspace on that agent's first invocation; no separate
manual install step is required.

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

Agents can check for and store secrets (API keys, tokens) using `sandbox_secret_check` and `sandbox_secret_set`. Values are saved in the Vault (General → Vault, [CREDENTIALS.md](CREDENTIALS.md)) as the agent's own keys. The sandbox environment is every global key marked **Agents Can Use This When Running Code**, overlaid by the agent's own keys, so an agent's value replaces the shared one.

### Two Storage Paths

| Path | When | How |
|------|------|-----|
| **Direct** | Agent already has the value (e.g., received via Host API or Telegram bot) | Pass `value` parameter to `sandbox_secret_set`. This asks the user first by default (Tools policy `ask`), since a supplied value can replace a key the user saved |
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
- **Credential scrubbing.** The agent's bridge token and its egress-proxy credential are in every command's environment too. They are scrubbed from command results, streamed logs, and `osaurus-host log` messages the same way. The live terminal view of a running command and sandboxed MCP server streams are not scrubbed.
- **Argument scrubbing.** When the agent uses the direct `value` path of `sandbox_secret_set`, the *recorded* copy of the tool-call arguments is rewritten (`value` → `[REDACTED]`) before it re-enters chat history, HTTP agent-run history, plugin complete/complete_stream history, or plugin streamed tool-call argument material; execution still sees the original. Malformed secret-set arguments fail closed rather than echoing the raw input. The prompt path never carries the value through the model at all and remains the recommended flow — the tool description steers models toward it.

---

## Building New Tools (Agent-Authored Plugins)

Agents can author, package, and register new sandbox plugins at runtime. The plugin-authoring recipe is injected into the system prompt as a **`## Building new tools`** section whenever plugin creation is enabled for the session (compact local models receive a shorter but complete manifest/register recipe). It is not modeled as a loadable skill, so it never appears in the capabilities manifest, discover, search, or load. Both the in-process `sandbox_plugin_register` tool and the host-API `POST /api/plugin/create` endpoint funnel through one shared registration pipeline (`SandboxPluginRegistration.register`) so they cannot drift. Registering adds tools for the rest of the session and runs the plugin's setup, so `sandbox_plugin_register` asks the user first by default (Tools policy `ask`), and the bridge endpoint additionally requires the agent's **Code Can Use Osaurus** setting.

### Requirements

- `autonomousExec.enabled` must be `true` on the agent
- `autonomousExec.pluginCreate` must be `true` (the default in `AutonomousExecConfig`) — this is the single control for plugin creation; turning it off both suppresses the injected section and disables `sandbox_plugin_register`

### Workflow

1. Agent writes script files with `file_write` to `~/plugins/{plugin-id}/scripts/` (or any subdirectory).
2. Agent writes a `plugin.json` manifest defining the required `name` and `description`, plus tools using `id`, simplified parameter specs, and `run`.
3. Agent calls `sandbox_plugin_register({"plugin_id":"<plugin-id>"})` (or the host CLI calls `POST /api/plugin/create`).
4. The shared registration pipeline validates the plugin, applies restricted defaults, persists to `SandboxPluginLibrary`, runs the install, and hot-registers the tools.
5. The in-process tool awaits schema buffering before it returns; chat and eval loops activate exactly those schemas for the next model step, so the agent can immediately call and verify the returned prefixed tool.
6. A non-blocking toast notifies the user with a **Remove** action for later review.

### File Auto-Packaging

When `sandbox_plugin_register` loads a plugin directory, it recursively collects every UTF-8 readable file (excluding `plugin.json` itself) and merges them into the plugin's `files` map. Files explicitly defined in `plugin.json` take precedence over auto-discovered ones. **Binary files are rejected up-front** — `plugin.files` is text-only and silently dropped binaries would break library-driven reinstalls. Either remove them, regenerate them at install time in `setup`, or fetch them from a setup-allowlisted host.

### Restricted Defaults (`SandboxPluginDefaults`)

Every agent-authored plugin is rewritten to enforce safe defaults before persistence:

- **`permissions.network`** is sanitised. Wildcard values (`outbound`) collapse to `none`. Comma-separated domain lists are accepted as-is when every entry parses as a valid domain; invalid lists collapse to `none`. Plan accordingly — declare exact API hostnames you need.
- **`permissions.inference`** is not honored. Whether code in an agent's sandbox (plugins included) may call `osaurus-host inference` or `agent dispatch` is the agent's own **Code Can Use Osaurus** setting (Agents → the agent → Sandbox → Execution), off by default; the bridge refuses both with `403` otherwise.
- **`metadata.created_by`** is stamped to `agent`; **`metadata.created_via`** records `agent_tool` or `host_bridge`.

### Validation Guarantees

The shared pipeline rejects a registration up-front (no library state is written) when:

- File paths fail `SandboxPathSanitizer.validatePluginFiles`
- The `setup` command references a host outside `SandboxNetworkPolicy.setupAllowlist`
- Any tool's `run` command references a host outside the same allowlist
- A declared `secrets` entry has no value in the Vault for the requesting agent (its own value or the one shared by all agents)
- The agent exceeds `SandboxRateLimiter` quota for `service: "http"`
- The sandbox container is not running (`unavailable` → HTTP 503)

### Plugin Persistence

Registered plugins are saved to the `SandboxPluginLibrary` (`~/.osaurus/sandbox-plugins/`) and survive app restarts. Per-agent install state lives under `~/.osaurus/agents/{agent-id}/sandbox-plugins/installed.json`. Their tools appear read-only in **Tools** → **All Tools**.

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
| `osaurus-host secrets get <name>` | Read a key marked **Agents Can Use This When Running Code** (the same values the agent's shell sees) |
| `osaurus-host config get <key>` | Read a plugin config value |
| `osaurus-host config set <key> <value>` | Write a plugin config value |
| `osaurus-host inference chat -m <message>` | Run a chat completion through Osaurus |
| `osaurus-host agent dispatch <id> <task>` | Dispatch a task to an agent |
| `osaurus-host agent memory query <text>` | Search agent memory |
| `osaurus-host agent memory store <text>` | Store a memory entry |
| `osaurus-host events emit <type> [payload]` | Emit a cross-plugin event |
| `osaurus-host plugin create` | Create a plugin from stdin JSON |

| `osaurus-host log <level> <message>` | Append to the sandbox log buffer (`level` is `debug`, `info`, `warn`, or `error`) |

`inference chat`, `agent dispatch`, and `plugin create` act as the agent on the host, so they are refused (`403`) unless the agent's **Code Can Use Osaurus** setting is on (Agents → the agent → Sandbox → Execution, off by default). A task started with `agent dispatch` runs as an external caller: tools that would ask first are refused instead of showing an approval card, externally denied tools stay denied, and it never runs in a host folder.

### Bridge authentication

Every request authenticates with a per-agent bearer token:

- The host mints a 256-bit token per agent and writes it to `/run/osaurus/<linuxName>.token` inside the guest, mode `0600`, owned by that agent's Linux user. The directory is mode `0711` so users can open their own file by name without enumerating siblings.
- The `osaurus-host` shim reads the token (allowed by uid) and sends it as `Authorization: Bearer <token>`. The shim refuses to run if the token file is missing or unreadable.
- The bridge resolves the token to an `(agentId, linuxName)` pair via `SandboxBridgeTokenStore`. Unknown or missing tokens get `401` — there is **no fallback to a default agent**.
- `X-Osaurus-User` is no longer trusted. Identity is bound to the token, which is bound to a Linux uid by file permissions inside the guest.
- Each container has its own bridge socket, and the host listener for that socket accepts only the token of the agent it belongs to (`403` otherwise). The guest socket is mode `0666`; without an explicit mode the relayed socket is created `0000` and only root could reach it.
- `X-Osaurus-Plugin` is still self-reported by the shim. It namespaces config within an agent but is not a security boundary between plugins of the same agent. For that reason `secrets get` ignores it: a plugin's declared keys that are not marked for code use reach the plugin only through the environment of its own tool and setup commands.

The `agent dispatch` route additionally rejects any body whose `agent_id` doesn't match the token-bound identity (`403`); `agent memory query` filters results to the calling agent's pinned facts.

Tokens are revoked when the agent is unprovisioned or the container is stopped, and re-minted on the next `ensureProvisioned`. After an Osaurus upgrade, plugin bridge calls fail closed until the container restarts and the new shim and token files are written — this happens automatically when Sparkle relaunches the app.

### Request size limits

Bridge requests are capped at **8 MiB** per body. Oversized requests are rejected with `413 Payload Too Large` before reaching any handler. Combined with the public HTTP server's pre-auth caps (32 MiB generic, 64 KiB on `/pair`), this prevents an unauthenticated client from forcing unbounded memory allocation.

---

## Security

### Path Sanitization

All file paths from tool arguments are validated by `SandboxPathSanitizer` before any container execution. Directory traversal attempts (`..`) are rejected, and paths are resolved relative to the agent's home directory.

### Per-Agent Isolation

**Unix file permissions do not separate agents on VirtioFS.** Apple's VirtioFS server reports every file as owned by whichever guest user accesses it, so a home's `chmod 700` admits every user that can see it. Earlier versions ran every agent in one container with the whole workspace mounted, which let any agent read, create, modify, and delete files in every other agent's home. Isolation now comes from mount namespaces instead: see [Pod isolation](#pod-isolation).

Also in place:

- **Host-side access is scoped per agent.** Everything the host reads, writes, copies, or serves on an agent's behalf (document reads and writes, `file_copy`, shared artifacts, database paths, `SOUL.md`, background-job logs, plugin installs) resolves through `SandboxAgentPathScope`: the agent's own home plus `/workspace/shared`. Symlinks are never followed out of that scope, and a home or plugin directory that has been replaced by a link is refused.
- **Bridge tokens** live in `/run/osaurus` on each container's own filesystem, and each bridge socket accepts only its own agent's token.
- **Seatbelt backend:** each agent's profile grants only its own home, `shared/`, and a per-agent scratch directory.

### Pod isolation

Each agent runs in its own container of a `LinuxPod`. Proven on the VM with Containerization 0.54:

- An agent container mounts only its own home, `shared/`, and the read-only shim. Other agents' homes and the VirtioFS share root (`/run/virtiofs` in the VM) don't exist in its mount namespace.
- Root inside a container can't mount the VirtioFS share, can't write or remove the shim, and sees no other agent's processes (separate PID namespace) or Linux users (separate rootfs).
- `shared/` is visible to every agent, by design.

Inside each container:

- `/proc` is mounted `hidepid=2`, so an agent user sees only its own processes, not root's. Boot fails if the mount option isn't in effect.
- Each agent's Linux user has its own UID (from 10000, kept in `~/.osaurus/config/sandbox-agent-uids.json`), so per-UID kernel limits don't couple agents. An environment clone that carries an older UID for the user is corrected on the next bootstrap.
- Commands run as the agent are limited to 4096 processes and 65536 open files, and write no core files. Root setup commands aren't limited.

Residual risks, not separated today:

- **Network namespace.** Containers share the VM's network stack, so loopback ports and abstract Unix sockets are reachable across agents. An agent that listens on `127.0.0.1` can be connected to by another agent.
- **Kernel and VM resources.** All containers share one guest kernel and the VM's memory; each container's cgroup is capped at the Memory setting, but agents together can still pressure each other up to the VM size.
- **No seccomp filter.** Containerization applies seccomp only through an OCI runtime, and the published `vminit` initfs ships no `runc`. Enabling it means building the initfs with a pinned `runc` added at `/sbin/runc`, then setting the pod's `ociRuntimePath` and `seccompProfile = .default`, which routes every exec through `runc exec`.
- **Membership restarts** stop every container, so another agent joining interrupts long-running work after the wait described in [Agent environments](#agent-environments-and-pod-membership).

### Network Policy

Network is set per agent (Agent → Sandbox): **Sandbox Network** on or off, and optional **Allowed Domains**. That gives each agent one of three policies: open, allowlist, or off.

The VM's network is a boot-time property shared by every container, so each boot composes it from the agents in the pod:

- **Every agent open** — shared NAT, every protocol (the default).
- **Every agent off** — no guest networking.
- **Anything else** — a **host-only** vmnet interface with no NAT to the outside, plus a filtering HTTP/HTTPS CONNECT proxy that Osaurus runs on the vmnet gateway address. The proxy applies each caller's own policy: an open agent reaches any public host name, an allowlist agent only its domains, and an agent with network off nothing. Only proxy-aware HTTP(S) clients get out; SSH, raw TCP, and UDP are blocked for every agent.

Workflow environments and diagnostics have no agent and count as open when the pod's network is composed. Within that, each Python step of a workflow gets its own proxy credential that reaches only the hosts the step declares in `network`, and none when it declares none; shell steps keep open access. The proxy variables are set in every pod, filtered or NAT, and always replace any `http_proxy`/`https_proxy` a caller passes. If the proxy can't start, a Python step's variables point at a closed port, so it fails rather than going out unfiltered. On Seatbelt a Python step with no declared hosts has no network. When a change to an agent's settings changes the composed network, the sandbox restarts once running commands finish; otherwise the proxy reads each policy per connection, so the change applies immediately. On the Seatbelt backend each command runs under its own agent's policy; an allowlist can't be enforced there, so it means no network.

Enforcement in the proxy is per-connection and per-agent:

- Guest processes receive `http_proxy`/`https_proxy` environment variables carrying the agent's bridge token; the proxy derives identity from that token alone.
- An allowlist agent's hostname must match its resolved allowlist — the union of the agent's own Allowed Domains and the domain lists declared by that agent's installed plugins (`permissions.network`). Patterns are `example.com` (exact) or `*.example.com` (subdomains, not the apex).
- IP literals are rejected outright, and resolved addresses are re-checked on the host before connecting: names that resolve to loopback, RFC1918/ULA, link-local, CGNAT, or multicast/reserved space are refused (DNS-rebinding defense). This applies to open agents in a filtered VM too, so they can't reach the LAN.
- Root setup commands (package installs) get a system credential limited to the package registries Osaurus uses.

**Known limitation:** in a filtered VM the guest can still reach the vmnet gateway address itself — i.e. the proxy and any host service bound to that interface. Closing that off from inside the guest requires in-guest firewall (nftables) support that upstream Containerization does not yet expose. Traffic to anything beyond the gateway is blocked by the host-only network itself.

Plugins declare their network requirements in the `permissions` field; those declarations are validated at install, reinstall, and repair time and feed the runtime allowlist.

### Rate Limiting

- `SandboxExecLimiter` — Limits the number of commands an agent can run per conversation turn
- `SandboxRateLimiter` — General rate limiting for sandbox operations and Host API bridge calls

### Artifact Integrity

Every external artifact the sandbox depends on is pinned to an immutable digest, and downloaded blobs are verified before they touch the on-disk container store. A registry, CDN, or release-host compromise cannot silently change the boundary the sandbox enforces.

| Artifact | Pin |
|----------|-----|
| GHCR image (`ghcr.io/osaurus-ai/sandbox`) | Multi-arch index digest (`@sha256:...`); the `:latest` tag is never used at runtime |
| Containerization SDK | Exact SwiftPM pin: 0.54.0 (`Package.swift` and both app workspace lockfiles) |
| Kata kernel | Kata 3.32.0, Linux `6.18.35-197` production/non-debug binary; both the release tarball and extracted kernel have pinned SHA-256 digests |
| vminit initfs | Containerization `vminit:0.54.0` OCI index pinned by digest (`SandboxRuntimeAssets.initfsReference`) |

A digest mismatch is **fail-closed**: the temp file is deleted, alternate mirrors are not tried (silent fallback would mask exactly the upstream-compromise scenario this defends against), and provisioning aborts with `SandboxError.integrityCheckFailed`. The hashing pass is bounded at 768 MiB to accommodate the pinned Kata archive while stopping a runaway download from turning into a multi-GB hash job.

Installed boot assets are checked again before every boot. The kernel must still match its pinned SHA-256; a kernel that doesn't (including one left by an older pin) is replaced from the bundled copy or the verified download. The initfs block is built locally from the digest-pinned `vminit` image, so its SHA-256 is recorded next to it (`initfs.ext4.sha256`) when it is built; a block with no record or a different digest is rebuilt from the content store.

To rotate a pin (e.g. after intentionally bumping the sandbox image): fetch the new digest with `crane digest …` or `docker buildx imagetools inspect …`, paste the multi-arch index digest into `containerImage` in `SandboxManager.swift`, and update the corresponding SHA-256 constants alongside the URL in the same file.

### Known limitations

These are accepted as-is. Each is either by design or needs support Osaurus doesn't have yet.

- **Trusted Folder host shell.** With a Trusted Folder attached, `shell_run` runs on the Mac, not in the sandbox: it can read anything the user can and inherits the app's environment. Host MCP servers inherit the app's environment as well.
- **Shared folder and loopback.** `/workspace/shared` is read-write for every agent, and agents share the VM's loopback and abstract Unix sockets (see [Pod isolation](#pod-isolation)).
- **Lexical path checks.** `SandboxPathSanitizer` checks tool paths as text. Inside the VM, the mount namespace is what actually confines an agent.
- **Raw sockets in a NAT pod.** When every pod member is open, the pod uses NAT and only proxy-aware clients go through a workflow step's allowlist; a Python step that opens a raw socket is not filtered. In a filtered pod the host-only network blocks it.
- **Seatbelt loopback.** Open-network Seatbelt commands can't connect to `localhost`, which also stops an agent from reaching a server it started itself on the host's loopback.
- **Workflow storage.** Each workflow with Python or npm dependencies keeps its own environment, so disk use grows with the number of installed workflows until they are uninstalled or cleaned up.
- **Workflow shell steps lose host folders.** Shell steps now run in the VM and see only the run workspace, not folders picked for the run.
- **Direct workflow starts.** A caller that starts `WorkflowRunService` directly, bypassing the queue, relies on the sandbox refusing a second claim on a busy workflow identity.
- **Workflow integrity record.** The hash in `~/.osaurus/workflows/.integrity.json` detects a workflow file changed outside Osaurus. It can't stop a writer that also rewrites that record.
- **Python step limits.** A Python step's address space is capped at 2 GB by default (`ulimit -v`, VM only) and it is killed at its time limit; network grants last only for that step.
- **Package sources.** `sandbox_install`, plugin dependencies, and workflow dependencies accept registry package names only.

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

The Diagnostics card also shows the most recent startup or provisioning failure as one monospaced line, e.g. `Last failure: agent_provision_failed · agent_provision.bootstrap_exec · sandbox_timeout · on_demand · warm · vm · 2 hr. ago`. It is read from the local ring buffer `~/.osaurus/container/startup-failures.json` and uses the same closed tokens as the `sandbox_provision_failure` telemetry event (see `docs/TELEMETRY.md`), so pasting it into a bug report gives us exactly the classification we would otherwise only see in aggregate. No error message, path, or agent identity is stored in that file.

---

## Container Management

### Start / Stop

- **Start** — Boots the container (provisions first if needed)
- **Stop** — Gracefully shuts down the container. A deliberate stop is not
  auto-restarted: the sandbox stays down until you press **Start**, or until a
  sandbox-enabled agent's first tool use calls the `sandbox_init_pending`
  placeholder. (Only a container that went away on its own — VM death after
  sleep/wake, for example — is warm-restarted automatically.) The same rule
  keeps the quit chain from re-booting the VM while the app is exiting, which
  is what a relaunched Osaurus used to collide with as `vmnet_in_use`.

### One sandbox VM per Mac user

Only one process can run the sandbox VM at a time. Every boot path (start,
provision, reset, restart, and the pod-membership restart) holds an advisory
lock, `$TMPDIR/osaurus-sandbox-vmnet-<uid>.lock`, from before the VM is
created until it is torn down. A restart keeps the lock between stop and
boot. Reset and Remove also take it before deleting the kernel, initfs,
templates, or environments, so one app can't delete the disks another app's
VM is running from. The descriptor is close-on-exec, so children spawned while
the VM runs can't keep it held after the app exits.

When another process holds the lock:

- A quitting Osaurus marks its lock record first, and the next process waits
  up to 30 seconds for it (8 seconds for an owner that isn't quitting).
- Otherwise the agent's sandbox is unavailable. Retries back off from 15
  seconds to 5 minutes and never count toward the startup-failure lockout.
  A cheap watcher retries as soon as the lock frees up.
- The Sandbox page's Overview says which app holds it. Start, Try Again, Reset, or Remove
  on Developer Tools → Sandbox offers the fix: quit the Osaurus app that owns
  the VM, end the eval or CLI process running it, or end processes that kept
  the lock after their app quit. Telemetry records one `vmnet_in_use` event
  per conflict, with `owner_state`.
- In chat, a sandbox agent's input bar shows a **Sandbox unavailable** chip
  that opens the same fix. The turn's system prompt carries the "Sandbox not
  ready" notice naming the holder, and `prompt_working_folder` is withheld
  while the agent's sandbox is on, so the model can't move the work to a
  host folder (picking one turns the agent's sandbox off).

### Reset

Removes the template and every agent environment and re-provisions from scratch. All agent workspaces and installed plugins are preserved (they live in the VirtioFS workspace). Workflow sandbox environments (below) are marked as needing their packages installed again, since `apk` packages and Linux users live in each environment's rootfs; the same happens to one workflow environment when its clone is evicted or re-cloned.

### Workflow environments

Every workflow runs its `shell_run` steps in a sandbox identity of its own instead of on the host, whether or not it declares **dependencies** (`dependencies: [{manager: pip|npm|apk, packages, binaries}]`). Dependencies are what get installed into that identity. The identity reuses the agent layout so every sandbox primitive works unchanged:

| | Agent | Workflow |
|---|---|---|
| Linux user | `agent-<name>` | `agent-wf-<template id>` |
| Home (`/workspace/...`) | `/workspace/agents/<name>` | `/workspace/agents/wf-<template id>` |
| PATH injection | `~/.venv/bin`, `~/.osaurus/node_workspace/node_modules/.bin` | same |
| Install lock / recovery | `SandboxInstallLock`, `runInstallWithRecovery` | same (`SandboxPackageInstaller`) |
| Enabled by | the agent's autonomous-exec config | the workflow's declared dependencies |

Environments are keyed by **template id**: a template installs at most once per Mac, an Architect draft's template id is the draft id, and the install wizard runs before an installed workflow exists, so one key follows a workflow from its first test run through install and every run. `WorkflowSandboxEnvironment` provisions the user (`bootstrapAgent`, idempotent, re-run before every run), installs each manager's packages, verifies every declared binary with `command -v`, and writes `.osaurus-environment.json` in the home recording backend, image digest, and what was installed. `SetupChecker` reads that manifest to decide **installed / not installed / stale / unsupported here** without booting the VM; `apk` is unsupported on the Seatbelt backend.

At run time `WorkflowRunner` places the run workspace under the environment's home (`.../wf-<id>/runs/<run id>`), so the host and the VM see one directory. `ShellRunTool` bridges into the VM with that directory as `cwd` (host share paths in the command are rewritten to `/workspace/...`), `SandboxToolRequestContext` resolves to the workflow identity, host file tools keep working against the shared workspace plus any folder or file the person picked (`format: "folder"` / `"file"` input fields, `folder` / `file` dialog fields; a shell step can't see those, and workflow validation warns when one runs on a picked folder), `file_copy` may write into those granted folders (4 GB cap for workflow runs), and a `shell_run` step that exits 127 / 126 fails the node with `command_not_found`. Uninstalling the workflow (or deleting a draft nothing installed) removes the home, manifest, and Linux user.

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
| `~/.osaurus/container/workspace/` | Host workspace. Its `agents/{name}/` and `shared/` are mounted into the matching containers; the root itself is never mounted |
| `~/.osaurus/container/workspace/shared/` | Mounted at `/workspace/shared` in every agent container. Loose files from the old workspace root move here once (`legacy-workspace-root/` on a name collision) |
| `~/.osaurus/container/templates/` | Immutable base rootfs template |
| `~/.osaurus/container/environments/{name}/` | Per-agent (and `osaurus-system`) rootfs clone |
| `$TMPDIR/osb-{rootHash}/` | Per-container host bridge sockets, keyed by the container root so each Space has its own. Kept out of the container root because a Space's root is too deep for the 104-byte Unix socket path limit |
| `~/.osaurus/container/shim/osaurus-host` | Host bridge shim, file-mounted read-only into every container |
| `~/.osaurus/container/workspace/agents/{name}/` | Per-agent home directory |
| `~/.osaurus/container/workspace/agents/{name}/SOUL.md` | Per-agent SOUL identity layer (seeded on first provision; agent-editable) |
| `~/.osaurus/container/workspace/agents/wf-{templateId}/` | A dependency-declaring workflow's environment (venv, npm workspace, `runs/{runId}` workspaces, `.osaurus-environment.json` manifest) |
| `~/.osaurus/sandbox-plugins/` | Plugin library (JSON recipes) |
| `~/.osaurus/agents/{agentId}/sandbox-plugins/installed.json` | Per-agent installed plugin records |
| `~/.osaurus/config/sandbox.json` | Sandbox configuration |
| `~/.osaurus/config/sandbox-agent-map.json` | Linux username to agent UUID mapping |
| `~/.osaurus/config/sandbox-agent-uids.json` | Linux username to guest UID |
