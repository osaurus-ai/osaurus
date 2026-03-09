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

### Always Available (Read-Only)

| Tool | Description |
|------|-------------|
| `sandbox_read_file` | Read a file's contents from the sandbox |
| `sandbox_list_directory` | List files and directories (supports recursive listing) |
| `sandbox_search_files` | Search file contents with grep (regex, glob filters) |

### Requires Autonomous Exec

| Tool | Description |
|------|-------------|
| `sandbox_write_file` | Write content to a file (creates parent directories) |
| `sandbox_move` | Move or rename files and directories |
| `sandbox_delete` | Delete files or directories |
| `sandbox_exec` | Run a shell command (configurable timeout, max 300s) |
| `sandbox_exec_background` | Start a background process with log file output |
| `sandbox_exec_kill` | Kill a background process by PID |
| `sandbox_install` | Install system packages via `apk` (runs as root) |
| `sandbox_pip_install` | Install Python packages via `pip install --user` |
| `sandbox_npm_install` | Install Node.js packages via `npm install` |
| `sandbox_whoami` | Get agent identity, home directory, installed plugins, and disk usage |
| `sandbox_processes` | List running processes for this agent |

All file paths are validated on the host side before container execution. Path traversal attacks are blocked by `SandboxPathSanitizer`.

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

All requests include the calling Linux username for identity verification.

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
