# Osaurus Plugin Authoring

This document describes how to build external plugins for Osaurus using the Generic C ABI. Plugins are `.dylib` shared libraries distributed in a zip file. They can expose tools to the AI, register HTTP routes, ship web frontends, and call back into the host for storage, inference, and agent dispatch.

## Table of Contents

- [Quick Start](#quick-start)
- [Developer Workflow](#developer-workflow)
- [Core Concepts](#core-concepts)
  - [Plugin Lifecycle](#plugin-lifecycle)
  - [Manifest Format](#manifest-format)
  - [ABI Versions](#abi-versions)
- [Plugin Capabilities](#plugin-capabilities)
  - [Tools](#tools)
  - [Plugin Secrets](#plugin-secrets)
  - [Folder Context](#folder-context)
  - [Invocation](#invocation)
  - [HTTP Routes](#http-routes)
  - [Configuration UI](#configuration-ui)
  - [Static Web Serving](#static-web-serving)
  - [Plugin Skills (SKILL.md)](#plugin-skills-skillmd)
  - [Plugin Documentation](#plugin-documentation)
  - [Artifact Handling](#artifact-handling)
- [Host API Reference](#host-api-reference)
  - [Config Store](#config-store)
  - [Data Store](#data-store)
  - [Logging](#logging)
  - [Agent Dispatch](#agent-dispatch)
  - [Task Event Hooks](#task-event-hooks)
  - [Inference](#inference)
  - [Models](#models)
  - [HTTP Client](#http-client)
  - [File I/O](#file-io)
- [Tunnel Endpoints](#tunnel-endpoints)
- [Packaging & Distribution](#packaging--distribution)
  - [Packaging Convention](#packaging-convention)
  - [Code Signing](#code-signing)
  - [Artifact Signing (Minisign)](#artifact-signing-minisign)
  - [Central Registry](#central-registry)
- [Permissions Reference](#permissions-reference)
- [ABI Reference](#abi-reference)
- [Language-Specific Notes](#language-specific-notes)

```mermaid
graph LR
    Plugin["Plugin (.dylib)"] -- "osaurus_plugin_entry_v2(host)" --> Osaurus
    Osaurus -- "init / get_manifest / invoke / handle_route" --> Plugin
    Plugin -- "host->complete / dispatch / db_exec / ..." --> HostAPI["osr_host_api (20 callbacks)"]
    HostAPI --> Osaurus
```

---

## Quick Start

1. Scaffold a new plugin:

```bash
osaurus tools create MyPlugin              # Swift (default)
osaurus tools create MyPlugin --language rust   # Rust
```

2. Build, install, and start developing:

```bash
cd MyPlugin
osaurus tools dev
```

That's it. `osaurus tools dev` will:

- Detect the project language (Swift or Rust) from the build files
- Build the plugin in release mode
- Install the dylib, `SKILL.md`, `README.md`, and `web/` assets into `~/.osaurus/Tools/`
- Launch Osaurus if it isn't already running
- Send a reload signal so the plugin appears immediately
- Watch for source file changes and automatically rebuild + hot-reload

> **Publishing:** Code signing and minisign signatures are only required when distributing plugins through the central registry. See [Code Signing](#code-signing) and [Artifact Signing](#artifact-signing-minisign) below for details.

---

## Developer Workflow

### Project-Root Dev Mode (Recommended)

Run `osaurus tools dev` from your plugin's project root. This is the primary development workflow:

```bash
cd MyPlugin
osaurus tools dev
```

The command reads `osaurus-plugin.json` (created by `osaurus tools create`) to determine the plugin ID and version, then:

1. **Detects the language** — looks for `Package.swift` (Swift) or `Cargo.toml` (Rust)
2. **Builds** — runs `swift build -c release` or `cargo build --release`
3. **Installs** — copies the dylib, `SKILL.md`, `README.md`, `CHANGELOG.md`, and `web/` directory into `~/.osaurus/Tools/<plugin_id>/<version>/`
4. **Launches Osaurus** — starts the app if it isn't already running
5. **Sends a reload signal** — the plugin appears in Osaurus immediately
6. **Watches for changes** — monitors `Sources/` (Swift) or `src/` (Rust) and asset files; on change, rebuilds and hot-reloads automatically

No signing keys, no manual packaging, no manual installation steps.

#### The `osaurus-plugin.json` file

Scaffolded projects include this file at the project root:

```json
{
  "plugin_id": "dev.example.MyPlugin",
  "version": "0.1.0"
}
```

### Frontend Dev Proxy

For plugins with a `web/` frontend, use `--web-proxy` to proxy static file requests to a local dev server (e.g., Vite) instead of serving from disk:

```bash
# Terminal 1: Frontend dev server
cd my-plugin/web
npm run dev   # → http://localhost:5173

# Terminal 2: Plugin dev mode with proxy
cd my-plugin
osaurus tools dev --web-proxy http://localhost:5173
```

When the proxy is active:

- Requests to `/plugins/<plugin_id>/app/*` are proxied to your local dev server
- Requests to `/plugins/<plugin_id>/api/*` still hit the dylib
- Osaurus injects `window.__osaurus` context into the proxied HTML
- CORS headers are handled automatically

This gives you hot module replacement (HMR) and instant feedback during frontend development.

### Legacy Watch Mode

For advanced use, you can watch an already-installed plugin by passing its ID directly:

```bash
osaurus tools dev com.acme.slack
```

This watches the installed dylib at `~/.osaurus/Tools/com.acme.slack/` for changes and sends reload signals when it is modified. You are responsible for building and copying the dylib yourself.

### Manual Install (Development Only)

Installing from a local path or URL is intended for development and testing:

```bash
osaurus tools install ./my-plugin-1.0.0.zip
osaurus tools install https://example.com/my-plugin-1.0.0.zip
```

These paths skip minisign signature verification, TOFU author key checks, and do not grant user consent. They work in DEBUG builds of Osaurus; in release builds, plugins installed this way will fail to load because they cannot pass code signature and consent verification.

For distribution, always publish to the central registry and install with `osaurus tools install <plugin-id>`, which enforces the full verification chain (minisign, code signing, consent).

---

## Core Concepts

### Plugin Lifecycle

Osaurus loads plugins via `dlopen` and resolves entry point symbols. The lifecycle is:

1. **Load** — Osaurus opens the `.dylib` and looks for `osaurus_plugin_entry_v2` (v2) or `osaurus_plugin_entry` (v1).
2. **Init** — The host calls `init()`, which returns an opaque context pointer owned by the plugin.
3. **Manifest** — The host calls `get_manifest(ctx)` to discover capabilities (tools, routes, config, etc.).
4. **Runtime** — The host calls `invoke(ctx, ...)` for tool executions, `handle_route(ctx, ...)` for HTTP requests, and lifecycle callbacks as events occur.
5. **Teardown** — The host calls `destroy(ctx)` when the plugin is unloaded.

All strings returned by the plugin are freed by the host via `free_string(s)`.

### Manifest Format

The manifest JSON returned by `get_manifest` describes the plugin's capabilities. This is the source of truth for plugin metadata at runtime.

**Minimal v1 manifest (tools only):**

```json
{
  "plugin_id": "com.acme.echo",
  "version": "1.0.0",
  "description": "Echo plugin",
  "capabilities": {
    "tools": [
      {
        "id": "echo_tool",
        "description": "Echoes back input",
        "parameters": { ... },
        "requirements": [],
        "permission_policy": "ask"
      }
    ]
  }
}
```

**Full v2 manifest (tools + routes + config + web + artifact handler + docs):**

```json
{
  "plugin_id": "com.acme.slack",
  "version": "1.0.0",
  "description": "Slack integration",
  "instructions": "When using Slack tools, always confirm the target channel with the user before posting. Format messages using Slack mrkdwn syntax (e.g. *bold*, _italic_, `code`). Prefer threaded replies over top-level messages when responding to existing conversations.",
  "capabilities": {
    "tools": [ ... ],
    "artifact_handler": true,
    "routes": [
      {
        "id": "oauth_callback",
        "path": "/callback",
        "methods": ["GET"],
        "description": "OAuth 2.0 callback handler",
        "auth": "none"
      },
      {
        "id": "webhook",
        "path": "/events",
        "methods": ["POST"],
        "auth": "verify"
      },
      {
        "id": "app",
        "path": "/app/*",
        "methods": ["GET"],
        "auth": "owner"
      }
    ],
    "config": {
      "title": "Slack Integration",
      "sections": [ ... ]
    },
    "web": {
      "static_dir": "web",
      "entry": "index.html",
      "mount": "/app",
      "auth": "owner"
    }
  },
  "docs": {
    "readme": "README.md",
    "changelog": "CHANGELOG.md",
    "links": [
      { "label": "Documentation", "url": "https://docs.acme.com/slack" }
    ]
  }
}
```

All v2 capabilities (`routes`, `config`, `web`, `artifact_handler`, `docs`) are optional. A v2 plugin can declare any combination of them.

**Top-level fields:**

| Field          | Type   | Required | Description                                    |
| -------------- | ------ | -------- | ---------------------------------------------- |
| `plugin_id`    | string | Yes      | Unique reverse-domain identifier               |
| `version`      | string | No       | Semver version string                          |
| `description`  | string | No       | Short description of the plugin                |
| `instructions` | string | No       | Default system prompt instructions appended during plugin-initiated inference; users can override per-agent in agent settings |
| `capabilities` | object | Yes      | Tools, routes, config, web, artifact_handler   |
| `secrets`      | array  | No       | API key / credential declarations              |
| `docs`         | object | No       | README, changelog, external links              |

### ABI Versions

The C header is available at `Packages/OsaurusCore/Tools/PluginABI/osaurus_plugin.h`.

Osaurus supports two ABI versions. Existing v1 plugins continue to work without changes.

**v1 ABI (Tools Only):**

- **Entry Point**: Plugin exports `osaurus_plugin_entry` returning `const osr_plugin_api*`.
- **Functions**: `init`, `destroy`, `get_manifest`, `invoke`, `free_string`.

**v2 ABI (Full Host API):**

- **Entry Point**: Plugin exports `osaurus_plugin_entry_v2(const osr_host_api* host)`. The host API struct provides 20 callbacks across nine groups.
- **New fields on `osr_plugin_api`** (appended after v1 fields for binary compatibility):
  - `version`: Set to `2` (`OSR_ABI_VERSION_2`).
  - `handle_route(ctx, request_json)`: Called when an HTTP request hits a plugin route. Returns JSON. May be `NULL` if the plugin has no routes.
  - `on_config_changed(ctx, key, value)`: Called when a config value changes in the host UI. May be `NULL`.
  - `on_task_event(ctx, task_id, event_type, event_json)`: Unified task lifecycle callback. Called for dispatched-task events (started, activity, progress, clarification, completed, failed, cancelled, output). May be `NULL`.
- **Host API (`osr_host_api`)** — Injected at init, provides:
  - **Config Store**: `config_get` / `config_set` / `config_delete` — Keychain-backed secrets and settings.
  - **Data Store**: `db_exec` / `db_query` — Sandboxed per-plugin SQLite database.
  - **Logging**: `log` — Structured logging to the Insights tab.
  - **Agent Dispatch**: `dispatch` / `task_status` / `dispatch_cancel` / `dispatch_clarify` / `list_active_tasks` / `dispatch_interrupt` / `dispatch_add_issue` / `send_draft` — Background agent work with full tool access.
  - **Inference**: `complete` / `complete_stream` / `embed` — Chat completion and embeddings through any configured provider.
  - **Models**: `list_models` — Enumerate available models (local MLX, Apple Foundation, remote).
  - **HTTP Client**: `http_request` — Outbound HTTP with SSRF protection.
  - **File I/O**: `file_read` — Read shared artifact files (restricted to `~/.osaurus/artifacts/`).

See [ABI Reference](#abi-reference) for the full C struct definitions and type signatures.

**Migration from v1 to v2:**

Upgrading is additive. Change your entry point from `osaurus_plugin_entry` to `osaurus_plugin_entry_v2`, store the host API pointer, set `api.version = 2`, and populate the new function pointers (or leave them `NULL` if unused). Osaurus detects the ABI version from `api->version` and enables features accordingly.

New in v2:
- **`on_task_event`**: Set this on `osr_plugin_api` to receive lifecycle events for dispatched tasks. Set to `NULL` to opt out.
- **Host API callbacks**: The `osr_host_api` now provides 20 callbacks across 9 capability groups — config, data store, logging, agent dispatch (core + extended), inference, models, HTTP client, and file I/O. All are available from the moment `osaurus_plugin_entry_v2` returns.
- **Artifact handling**: Plugins can declare `"artifact_handler": true` in their manifest capabilities to intercept shared artifacts. See [Artifact Handling](#artifact-handling).

---

## Plugin Capabilities

### Tools

Tools are the primary way plugins extend the AI's abilities. Each tool is declared in the manifest under `capabilities.tools`.

#### Tool Requirements

The `requirements` array specifies what permissions or capabilities the tool needs. There are two types:

1. **System Permissions** - macOS system-level permissions that users grant at the app level
2. **Custom Permissions** - Plugin-specific permissions that users grant per-tool

**System Permissions:**

| Requirement             | Description                                                                                       |
| ----------------------- | ------------------------------------------------------------------------------------------------- |
| `automation`            | AppleScript/Apple Events automation — allows controlling other applications                       |
| `accessibility`         | Accessibility API access — allows UI interaction, input simulation, computer control              |
| `automation_calendar`   | Calendar automation (via AppleScript) — allows controlling Calendar app                           |
| `automation_mail`       | Mail automation (via AppleScript) — allows controlling Mail app                                   |
| `calendar`              | Calendar access (EventKit) — allows plugins to read and create calendar events directly           |
| `contacts`              | Contacts access — allows plugins to access and search contacts                                    |
| `location`              | Location access — allows plugins to access the user's current location                            |
| `maps`                  | Maps access (via AppleScript) — allows plugins to control Maps app                                |
| `microphone`            | Microphone access — allows plugins to capture audio input                                         |
| `notes`                 | Notes access (via AppleScript) — allows plugins to read and create notes                          |
| `reminders`             | Reminders access (EventKit) — allows plugins to read and create tasks and reminders               |
| `screen_recording`      | Screen recording access — allows plugins to capture screen content                                |
| `disk`                  | Full Disk Access — allows accessing protected files like the Messages database and other app data |

Example tool requiring automation:

```json
{
  "id": "run_applescript",
  "description": "Execute AppleScript commands",
  "parameters": {
    "type": "object",
    "properties": { "script": { "type": "string" } }
  },
  "requirements": ["automation"],
  "permission_policy": "ask"
}
```

Example tool requiring both automation and accessibility (e.g., for computer use):

```json
{
  "id": "computer_control",
  "description": "Control the computer via UI automation",
  "parameters": { ... },
  "requirements": ["automation", "accessibility"],
  "permission_policy": "ask"
}
```

Example tool requiring contacts (e.g., for looking up phone numbers):

```json
{
  "id": "find_contact",
  "description": "Find contact details by name",
  "parameters": {
    "type": "object",
    "properties": { "name": { "type": "string" } }
  },
  "requirements": ["contacts"],
  "permission_policy": "ask"
}
```

Example tool requiring calendar access (e.g., for scheduling meetings):

```json
{
  "id": "add_event",
  "description": "Add an event to the calendar",
  "parameters": {
    "type": "object",
    "properties": {
      "title": { "type": "string" },
      "start_date": { "type": "string" },
      "end_date": { "type": "string" }
    }
  },
  "requirements": ["calendar"],
  "permission_policy": "ask"
}
```

Example tool requiring Full Disk Access (e.g., for reading Messages):

```json
{
  "id": "read_messages",
  "description": "Read message history from a contact",
  "parameters": {
    "type": "object",
    "properties": { "phoneNumber": { "type": "string" } }
  },
  "requirements": ["disk"],
  "permission_policy": "ask"
}
```

When a tool with system permission requirements is executed:

1. Osaurus checks if the required permissions are granted at the OS level (system permissions are always enforced first, regardless of permission policy)
2. If any are missing, execution fails with a clear error message
3. Users can grant permissions via Settings → System Permissions or when prompted by the tool

#### Permission Policies

Each tool can specify a `permission_policy`:

- `"ask"` (default) — Prompts user for approval before each execution
- `"auto"` — Executes automatically if all requirements are granted
- `"deny"` — Blocks execution entirely

Users can override these defaults per-tool via the Osaurus UI.

### Plugin Secrets

Plugins that require API keys or other credentials can declare them in the manifest. Osaurus stores these securely in the system Keychain and prompts users to configure them during installation.

**Declaring Secrets in Manifest:**

```json
{
  "plugin_id": "com.acme.weather",
  "version": "1.0.0",
  "description": "Weather plugin",
  "secrets": [
    {
      "id": "api_key",
      "label": "OpenWeather API Key",
      "description": "Get your API key from [OpenWeather](https://openweathermap.org/api)",
      "required": true,
      "url": "https://openweathermap.org/api"
    },
    {
      "id": "backup_key",
      "label": "Backup API Key",
      "description": "Optional backup key for failover",
      "required": false
    }
  ],
  "capabilities": {
    "tools": [...]
  }
}
```

**Secret Specification Fields:**

| Field         | Type    | Required | Description                                                |
| ------------- | ------- | -------- | ---------------------------------------------------------- |
| `id`          | string  | Yes      | Unique identifier for the secret (e.g., `"api_key"`)       |
| `label`       | string  | Yes      | Human-readable label shown in the UI                       |
| `description` | string  | No       | Rich text description (supports markdown links)            |
| `required`    | boolean | Yes      | Whether the secret is required for the plugin to function  |
| `url`         | string  | No       | URL to the settings page where users can obtain the secret |

**Accessing Secrets in Tools:**

When a tool is invoked, Osaurus automatically injects all stored secrets for the plugin into the payload under the `_secrets` key. This includes both manifest-declared secrets and any other keys stored in the plugin's Keychain scope (e.g., tokens saved via `config_set`).

```swift
private struct WeatherTool {
    let name = "get_weather"

    struct Args: Decodable {
        let location: String
        let _secrets: [String: String]?
    }

    func run(args: String) -> String {
        guard let data = args.data(using: .utf8),
              let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments\"}"
        }

        guard let apiKey = input._secrets?["api_key"] else {
            return "{\"error\": \"API key not configured. Please configure secrets in Osaurus settings.\"}"
        }

        let result = fetchWeather(location: input.location, apiKey: apiKey)
        return "{\"weather\": \"\(result)\"}"
    }
}
```

**User Experience:**

1. When a plugin with secrets is installed, Osaurus prompts the user to configure them
2. If required secrets are missing, a "Needs API Key" badge appears on the plugin card
3. Users can configure or edit secrets anytime via the plugin menu → "Configure Secrets"
4. Secrets are stored securely in the macOS Keychain
5. Secrets are automatically cleaned up when the plugin is uninstalled

### Folder Context

When a user has a working directory selected in Work Mode, Osaurus automatically injects the folder context into tool payloads. This allows plugins to resolve relative paths provided by the LLM.

**Automatic Injection:**

When a folder context is active, every tool invocation receives a `_context` object:

```json
{
  "input_path": "Screenshots/image.png",
  "output_format": "jpg",
  "_context": {
    "working_directory": "/Users/foo/project"
  }
}
```

**Using Folder Context in Tools:**

```swift
private struct ImageTool {
    let name = "convert_image"

    struct Args: Decodable {
        let input_path: String
        let output_format: String
        let _context: FolderContext?
    }

    struct FolderContext: Decodable {
        let working_directory: String
    }

    func run(args: String) -> String {
        guard let data = args.data(using: .utf8),
              let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments\"}"
        }

        let inputPath: String
        if let workingDir = input._context?.working_directory {
            inputPath = "\(workingDir)/\(input.input_path)"
        } else {
            inputPath = input.input_path
        }

        if let workingDir = input._context?.working_directory {
            let resolvedPath = URL(fileURLWithPath: inputPath).standardized.path
            guard resolvedPath.hasPrefix(workingDir) else {
                return "{\"error\": \"Path outside working directory\"}"
            }
        }

        // Process the file...
        return "{\"success\": true}"
    }
}
```

**Security Considerations:**

- Always validate that resolved paths stay within `working_directory`
- The LLM is instructed to use relative paths for file operations
- Plugins should reject paths that attempt directory traversal (e.g., `../`)
- If `_context` is absent, the plugin should handle absolute paths or return an error

**Context Fields:**

| Field               | Type   | Description                                 |
| ------------------- | ------ | ------------------------------------------- |
| `working_directory` | string | Absolute path to the user's selected folder |

### Invocation

When Osaurus needs to execute a capability, it calls `invoke`:

- `type`: e.g. `"tool"`
- `id`: e.g. `"echo_tool"`
- `payload`: JSON string arguments (e.g. `{"message": "hello"}`)
  - If the plugin has secrets configured, they are injected under the `_secrets` key
  - If a folder context is active, it is injected under the `_context` key

The plugin returns a JSON string response (allocated; host frees it via `free_string`).

### HTTP Routes

v2 plugins can register HTTP route handlers exposed through the Osaurus server and relay tunnel. This enables OAuth flows, webhook endpoints, and plugin-hosted web apps.

#### Route Declaration

Declare routes in the manifest under `capabilities.routes`:

```json
{
  "capabilities": {
    "routes": [
      {
        "id": "oauth_callback",
        "path": "/callback",
        "methods": ["GET"],
        "description": "OAuth 2.0 callback handler",
        "auth": "none"
      },
      {
        "id": "webhook",
        "path": "/events",
        "methods": ["POST"],
        "description": "Slack Events API webhook",
        "auth": "verify"
      },
      {
        "id": "dashboard",
        "path": "/app/*",
        "methods": ["GET"],
        "description": "Web dashboard",
        "auth": "owner"
      }
    ]
  }
}
```

**Route Spec Fields:**

| Field         | Type     | Required | Description                                          |
| ------------- | -------- | -------- | ---------------------------------------------------- |
| `id`          | string   | Yes      | Unique identifier for the route                      |
| `path`        | string   | Yes      | Path relative to the plugin namespace                |
| `methods`     | string[] | Yes      | HTTP methods (`GET`, `POST`, `PUT`, `DELETE`, etc.)  |
| `description` | string   | No       | Human-readable description                           |
| `auth`        | string   | Yes      | Auth level: `"none"`, `"verify"`, or `"owner"`       |

Paths support wildcards: `/app/*` matches `/app/`, `/app/index.html`, `/app/assets/style.css`, etc.

#### Resulting URLs

Routes are namespaced under `/plugins/<plugin_id>/` to prevent collisions. Two plugins can both declare `path: "/callback"` with zero conflict.

```
Local:   http://127.0.0.1:1337/plugins/com.acme.slack/callback
Tunnel:  https://0x<agent-address>.agent.osaurus.ai/plugins/com.acme.slack/callback
```

#### Auth Levels

| Level    | Meaning                                                                                    |
| -------- | ------------------------------------------------------------------------------------------ |
| `none`   | Public. No auth required. Used for OAuth callbacks and webhook verification.               |
| `verify` | Same as `none` for HTTP handling. Use this to signal that your plugin performs its own request verification (e.g., Slack signing secret). |
| `owner`  | Requires a valid Osaurus access key (`osk-v1`). For plugin web UIs and admin endpoints.    |

Rate limiting is applied to `none` and `verify` dynamic routes at 100 requests/minute per plugin. `owner` routes are unlimited. Static web file serving is not rate-limited.

#### Agent-Scoped Routing

Plugin routes are scoped per agent. When a route request arrives, Osaurus resolves the agent context and makes the plugin's routes accessible.

- All plugin route requests require an `X-Osaurus-Agent-Id` header identifying the requesting agent.
- Agent identity is resolved at execution time via the work execution context.

#### Request / Response Schema

When a request hits a plugin route, Osaurus builds a JSON request, calls `handle_route`, and translates the JSON response back to HTTP.

**OsaurusHTTPRequest (sent to plugin):**

```json
{
  "route_id": "oauth_callback",
  "method": "GET",
  "path": "/callback",
  "query": { "code": "abc123", "state": "xyz" },
  "headers": { "content-type": "application/json" },
  "body": "",
  "body_encoding": "utf8",
  "remote_addr": "",
  "plugin_id": "com.acme.slack",
  "osaurus": {
    "base_url": "https://0x1234.agent.osaurus.ai",
    "plugin_url": "https://0x1234.agent.osaurus.ai/plugins/com.acme.slack",
    "agent_address": "0x1a2b3c4d5e6f7890abcdef1234567890abcdef12"
  }
}
```

> **Note:** `remote_addr` is currently always an empty string. Do not rely on it for client identification.

The `osaurus` context object provides host-resolved metadata:

| Field            | Description                                                                 |
| ---------------- | --------------------------------------------------------------------------- |
| `base_url`       | Root URL of the Osaurus server (tunnel or local)                            |
| `plugin_url`     | Full URL prefix for this plugin's routes                                    |
| `agent_address`  | Crypto address of the agent this request is scoped to — pass this to `dispatch()` and inference calls |

**OsaurusHTTPResponse (returned by plugin):**

```json
{
  "status": 200,
  "headers": {
    "content-type": "text/html",
    "set-cookie": "session=abc; HttpOnly; Secure"
  },
  "body": "<html>...</html>",
  "body_encoding": "utf8"
}
```

For binary responses, set `body_encoding` to `"base64"` and base64-encode the body.

### Configuration UI

Plugins can declare a settings schema in the manifest that Osaurus renders natively in the Management window under the plugin's detail view.

#### Manifest Declaration

```json
{
  "capabilities": {
    "config": {
      "title": "Slack Integration",
      "sections": [
        {
          "title": "Authentication",
          "fields": [
            {
              "key": "oauth_status",
              "type": "status",
              "label": "Connection",
              "connected_when": "access_token",
              "connect_action": { "type": "oauth", "url_route": "oauth_start" },
              "disconnect_action": { "clear_keys": ["access_token", "refresh_token"] }
            }
          ]
        },
        {
          "title": "Webhook",
          "fields": [
            {
              "key": "webhook_url",
              "type": "readonly",
              "label": "Webhook URL",
              "value_template": "{{plugin_url}}/events",
              "copyable": true
            },
            {
              "key": "signing_secret",
              "type": "secret",
              "label": "Signing Secret",
              "placeholder": "xoxb-...",
              "validation": { "required": true }
            }
          ]
        },
        {
          "title": "Preferences",
          "fields": [
            {
              "key": "default_channel",
              "type": "text",
              "label": "Default Channel",
              "placeholder": "#general"
            },
            {
              "key": "notify_on_mention",
              "type": "toggle",
              "label": "Notify on @mention",
              "default": true
            },
            {
              "key": "event_types",
              "type": "multiselect",
              "label": "Listen for events",
              "options": [
                { "value": "message", "label": "Messages" },
                { "value": "reaction", "label": "Reactions" },
                { "value": "file", "label": "File uploads" }
              ],
              "default": ["message"]
            }
          ]
        }
      ]
    }
  }
}
```

#### Supported Field Types

| Type          | Renders as                        | Storage                  |
| ------------- | --------------------------------- | ------------------------ |
| `text`        | Text field                        | Config store (plaintext) |
| `secret`      | Password field (masked)           | Config store (Keychain)  |
| `toggle`      | Switch                            | Config store             |
| `select`      | Dropdown                          | Config store             |
| `multiselect` | Multi-checkbox                    | Config store (JSON array)|
| `number`      | Number field                      | Config store             |
| `readonly`    | Non-editable display + copy button| Not stored               |
| `status`      | Connected/disconnected badge      | Derived from config key  |

#### Field Properties

| Property            | Type   | Description                                                    |
| ------------------- | ------ | -------------------------------------------------------------- |
| `key`               | string | Unique key for storage and lookup                              |
| `type`              | string | One of the supported field types above                         |
| `label`             | string | Display label                                                  |
| `placeholder`       | string | Placeholder text for input fields                              |
| `default`           | any    | Default value (string, bool, number, or string array)          |
| `options`           | array  | Options for `select` and `multiselect` fields                  |
| `validation`        | object | Validation rules (see below)                                   |
| `value_template`    | string | Template string for `readonly` fields                          |
| `copyable`          | bool   | Show a copy button for `readonly` fields                       |
| `connected_when`    | string | Config key that determines connected state for `status` fields |
| `connect_action`    | object | Action to perform on connect for `status` fields               |
| `disconnect_action` | object | Action to perform on disconnect for `status` fields            |

#### Validation

| Field          | Applies to    | Description                             |
| -------------- | ------------- | --------------------------------------- |
| `required`     | all           | Must be non-empty                       |
| `pattern`      | text, secret  | Regex the value must match              |
| `pattern_hint` | text, secret  | Human-readable error shown on mismatch  |
| `min` / `max`  | number        | Numeric bounds                          |
| `min_length` / `max_length` | text, secret | String length bounds       |

#### Template Variables

Readonly and computed fields can reference dynamic values:

| Variable           | Value                                            |
| ------------------ | ------------------------------------------------ |
| `{{plugin_url}}`   | Full URL to plugin route prefix                  |
| `{{tunnel_url}}`   | Tunnel URL for remote access                     |
| `{{plugin_id}}`    | Plugin ID                                        |
| `{{config.KEY}}`   | Current value of another config key              |

#### Config Change Notification

When the user updates a config value in the UI, the plugin's `on_config_changed` callback is invoked:

```c
void on_config_changed(osr_plugin_ctx_t ctx, const char* key, const char* value);
```

This lets the plugin react immediately to config changes (e.g., reconnect a WebSocket when a token changes).

### Static Web Serving

Plugins can ship a full frontend (React, Svelte, Vue, vanilla JS — anything that builds to static files). Osaurus serves the `web/` directory directly, without calling the dylib for static assets.

#### Manifest Declaration

```json
{
  "capabilities": {
    "web": {
      "static_dir": "web",
      "entry": "index.html",
      "mount": "/app",
      "auth": "owner"
    }
  }
}
```

**Web Spec Fields:**

| Field        | Type   | Description                                  |
| ------------ | ------ | -------------------------------------------- |
| `static_dir` | string | Directory in the plugin bundle to serve      |
| `entry`      | string | Entry HTML file (served for the mount root)  |
| `mount`      | string | URL mount point under the plugin namespace   |
| `auth`       | string | Auth level: `none`, `verify`, or `owner`     |

**Resulting layout:**

```
/plugins/com.acme.dashboard/app/           → web/index.html
/plugins/com.acme.dashboard/app/assets/*   → web/assets/*
/plugins/com.acme.dashboard/api/*          → handled by dylib via handle_route
```

#### Context Injection

Osaurus automatically injects a `window.__osaurus` context object into HTML responses before `</head>`:

```html
<script>
window.__osaurus = {
  pluginId: "com.acme.dashboard",
  baseUrl: "/plugins/com.acme.dashboard",
  apiUrl: "/plugins/com.acme.dashboard/api"
};
</script>
```

> **Note:** The `window.__osaurus` fields (`pluginId`, `baseUrl`, `apiUrl`) use camelCase and differ from the route request's `osaurus` context object (`base_url`, `plugin_url`, `agent_address`). The injected script does not include `agent_address`.

The frontend can use these values for API calls:

```javascript
const res = await fetch(`${window.__osaurus.baseUrl}/api/widgets`);
```

### Plugin Skills (SKILL.md)

Plugins can bundle a `SKILL.md` file that provides AI-specific guidance for using the plugin's tools. When a plugin includes a skill, Osaurus automatically loads it and makes it available to the AI during conversations. This is the recommended way to teach the AI how to use your plugin effectively.

Skills follow the [Agent Skills](https://agentskills.io/specification) specification — a markdown file with YAML frontmatter.

**Why include a SKILL.md?**

Tool descriptions and parameter schemas tell the AI _what_ a tool does, but a skill tells the AI _how_ to use the tools well. For example, a presentation plugin's skill can describe the correct workflow order, coordinate system, layout recipes, and design best practices — context that doesn't fit in individual tool descriptions.

**Format:**

```markdown
---
name: my-plugin-name
description: Short description of when this skill applies and what it helps with.
metadata:
  author: your-name
  version: "1.0.0"
---

# My Plugin Name

Detailed instructions for the AI...
```

**Frontmatter Fields:**

| Field              | Type   | Required | Description                                                                           |
| ------------------ | ------ | -------- | ------------------------------------------------------------------------------------- |
| `name`             | string | Yes      | Lowercase-hyphen identifier (e.g., `my-plugin`). Converted to title case for display. |
| `description`      | string | Yes      | Tells the AI when this skill applies. Max 1024 characters.                            |
| `metadata.author`  | string | No       | Skill author name.                                                                    |
| `metadata.version` | string | No       | Skill version (e.g., `"1.0.0"`).                                                      |

The body after the frontmatter contains the full instructions in markdown. This is what the AI sees when the skill is active.

**Packaging:**

Include `SKILL.md` in your plugin's zip archive alongside the `.dylib`. When installing from the central registry, Osaurus searches the entire archive for files named `SKILL.md` (case-insensitive) and copies them into a `skills/` directory within the plugin's install location. If your plugin bundles multiple skills, place each in its own subdirectory; the parent directory name is used as a prefix for disambiguation.

When using `osaurus tools dev`, only the root-level `SKILL.md` file is copied. For development, place your skill file at the project root.

**Lifecycle:**

1. When the plugin is installed, `SKILL.md` files are extracted to `<plugin-install-dir>/skills/`.
2. When the plugin loads, Osaurus parses each skill and registers it with the skill manager.
3. Plugin skills appear in the Skills UI with a "From: _plugin-name_" badge and are **read-only** — users cannot edit or delete them, but they can enable or disable them.
4. When the plugin is uninstalled, its skills are automatically unregistered and removed.

**Best Practices:**

- **Describe the workflow.** If tools must be called in a specific order, spell it out step by step.
- **Document the coordinate system.** If tools use coordinates, units, or dimensions, provide reference values and safe margins.
- **Include layout recipes.** Provide ready-to-use parameter combinations for common use cases.
- **List limitations.** If elements can't be modified after creation or slides can't be reordered, say so up front — this prevents the AI from attempting unsupported operations.
- **Add tool-specific tips.** Note quirks like "hex colors must omit the `#` prefix" or "the `layout` parameter is metadata only and does not auto-generate content."
- **Keep it focused.** The skill is loaded into the AI's context window. Be thorough but concise — avoid repeating what the tool schemas already convey.

**Example:**

The [osaurus-pptx](https://github.com/osaurus-ai/osaurus-pptx) plugin includes a SKILL.md that covers the required tool call sequence, slide coordinate system, layout recipes for common slide types, theme selection guidance, and design best practices.

### Plugin Documentation

Plugins can include a `README.md` and `CHANGELOG.md` that are displayed in the Osaurus Management window when viewing the plugin's detail page.

#### Manifest Declaration

```json
{
  "docs": {
    "readme": "README.md",
    "changelog": "CHANGELOG.md",
    "links": [
      { "label": "Documentation", "url": "https://docs.acme.com/slack" },
      { "label": "Report Issue", "url": "https://github.com/acme/osaurus-slack/issues" }
    ]
  }
}
```

**Docs Spec Fields:**

| Field       | Type   | Description                                     |
| ----------- | ------ | ----------------------------------------------- |
| `readme`    | string | Path to README file in the plugin bundle        |
| `changelog` | string | Path to CHANGELOG file in the plugin bundle     |
| `links`     | array  | External doc links shown below the README       |

Each link object has `label` (string) and `url` (string). Links open in the user's default browser.

> **Note:** The UI always resolves documentation files by looking for `README.md` and `CHANGELOG.md` (case-insensitive) on disk in the plugin's version directory, regardless of the `readme`/`changelog` values in the manifest. The `links` array is used as declared.

#### UI Rendering

The plugin detail view shows tabbed content:

- **README** — Rendered as Markdown.
- **Settings** — The config UI from [Configuration UI](#configuration-ui).
- **Changelog** — Rendered as Markdown if `CHANGELOG.md` is present.
- **Doc Links** — External links displayed below the content.

### Artifact Handling

Plugins can intercept shared artifacts — files produced by the agent (images, documents, code, etc.) during a conversation. This enables workflows like uploading artifacts to external services (Telegram, Slack, cloud storage, etc.).

#### Declaring the Capability

Set `"artifact_handler": true` in the manifest:

```json
{
  "plugin_id": "com.acme.uploader",
  "version": "1.0.0",
  "description": "Auto-uploads artifacts to cloud storage",
  "capabilities": {
    "artifact_handler": true,
    "tools": [ ... ]
  }
}
```

#### How It Works

1. The agent creates an artifact and calls `share_artifact`.
2. Osaurus saves the artifact locally to `~/.osaurus/artifacts/{contextId}/`.
3. Osaurus checks all loaded plugins for `artifact_handler: true` (requires ABI v2).
4. Each matching plugin receives an `invoke` call with artifact metadata.
5. The plugin can then use `host->file_read` to read the file contents and `host->http_request` to upload it to an external service.

#### Invocation Format

Artifact notifications are delivered via the standard `invoke` function:

- `type`: `"artifact"`
- `id`: `"share"`
- `payload`: JSON with artifact metadata

**Payload fields:**

| Field          | Type   | Description                                                    |
| -------------- | ------ | -------------------------------------------------------------- |
| `filename`     | string | Original filename (e.g., `"diagram.png"`)                      |
| `host_path`    | string | Absolute path to the saved artifact file                       |
| `mime_type`    | string | Detected MIME type (e.g., `"image/png"`)                       |
| `size`         | int    | File size in bytes                                             |
| `is_directory` | bool   | Whether the artifact is a directory                            |

**Example payload:**

```json
{
  "filename": "architecture-diagram.png",
  "host_path": "/Users/me/.osaurus/artifacts/ctx-abc123/architecture-diagram.png",
  "mime_type": "image/png",
  "size": 245760,
  "is_directory": false
}
```

#### Example: Uploading to a Cloud Service

```c
const char* invoke(osr_plugin_ctx_t ctx, const char* type,
                   const char* id, const char* payload) {
    MyPlugin* plugin = (MyPlugin*)ctx;

    if (strcmp(type, "artifact") == 0 && strcmp(id, "share") == 0) {
        // 1. Read the artifact file
        char read_req[1024];
        snprintf(read_req, sizeof(read_req),
            "{\"path\": \"%s\"}", extracted_path);
        const char* file_resp = plugin->host->file_read(read_req);

        // 2. Parse the base64 data from file_resp
        // ... extract "data", "mime_type" ...

        // 3. Upload via HTTP
        char upload_req[4096];
        snprintf(upload_req, sizeof(upload_req),
            "{\"method\": \"POST\","
            " \"url\": \"https://api.example.com/upload\","
            " \"headers\": {\"Content-Type\": \"application/json\","
            "               \"Authorization\": \"Bearer %s\"},"
            " \"body\": \"{\\\"filename\\\": \\\"%s\\\","
            "             \\\"data\\\": \\\"%s\\\"}\"}",
            api_key, filename, base64_data);
        const char* upload_resp = plugin->host->http_request(upload_req);

        plugin->host->log(1, "Artifact uploaded successfully");
        return strdup("{\"uploaded\": true}");
    }

    return strdup("{\"error\": \"unknown invocation\"}");
}
```

#### Behavior Notes

- Artifact notifications are dispatched **asynchronously**. A slow or failing plugin does not block the main application.
- Multiple plugins can register as artifact handlers. Each receives the notification independently.
- The plugin's `invoke` return value is not used by the host for artifact notifications — it is fire-and-forget.
- Only plugins with ABI version 2 or higher are eligible for artifact handling.
- Artifacts produced during plugin-initiated inference (`complete` / `complete_stream` with `share_artifact` in the agentic loop) are fully processed and trigger artifact handler notifications, just like artifacts from Chat and Work modes.

---

## Host API Reference

v2 plugins receive an `osr_host_api` struct at init time with 20 callbacks across nine capability groups. All callbacks are available from the moment `osaurus_plugin_entry_v2` returns.

### Config Store

For secrets, tokens, and settings. Backed by the macOS Keychain. Accessed via the host API:

```c
const char* value = host->config_get("access_token");
host->config_set("access_token", "xoxb-...");
host->config_delete("access_token");
```

Config values are also used by the [Configuration UI](#configuration-ui) — fields of type `secret` are stored here automatically.

### Data Store

Each plugin gets a sandboxed SQLite database at:

```
~/.osaurus/Tools/<plugin_id>/data/data.db
```

Accessed via the host API with raw SQL and JSON parameter binding:

```c
// Create a table
host->db_exec(
    "CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, type TEXT, payload TEXT, received_at INTEGER DEFAULT (unixepoch()))",
    NULL
);

// Parameterized insert
host->db_exec(
    "INSERT INTO events (id, type, payload) VALUES (?1, ?2, ?3)",
    "[\"evt-1\", \"message\", \"{...}\"]"
);

// Query
const char* result = host->db_query(
    "SELECT * FROM events WHERE type = ?1 ORDER BY received_at DESC LIMIT 50",
    "[\"message\"]"
);
```

**`db_exec` return format (writes):**

```json
{ "changes": 1, "last_insert_rowid": 42 }
```

**`db_query` return format (reads):**

```json
{
  "columns": ["id", "type", "payload", "received_at"],
  "rows": [["\"evt-1\"", "\"message\"", "\"{...}\"", "1709312400"]]
}
```

On error, both return `{"error": "..."}`.

**SQL Sandboxing:**

- Each plugin's database is isolated. No cross-plugin access.
- `ATTACH DATABASE` and `DETACH DATABASE` are blocked.
- `LOAD_EXTENSION` is blocked.
- WAL mode and foreign keys are enabled by default.
- Plugins manage their own schema with `CREATE TABLE IF NOT EXISTS` and `ALTER TABLE ... ADD COLUMN`.

### Logging

The host API provides structured logging:

```c
host->log(0, "Loaded 42 events from cache");   // 0 = debug
host->log(1, "Processing webhook event");      // 1 = info
host->log(2, "Missing signing secret");        // 2 = warning
host->log(3, "Database write failed");         // 3 = error
```

Log levels:

| Level | Name    | Description                  |
| ----- | ------- | ---------------------------- |
| 0     | Debug   | Verbose diagnostic output    |
| 1     | Info    | Normal operational messages  |
| 2     | Warning | Non-fatal issues             |
| 3     | Error   | Failures requiring attention |

Logs appear in the **Insights** tab in the Management window with plugin attribution. Filter by the "Plugin" source to see only plugin activity. All Host API calls (dispatch, inference, models, HTTP) also appear in Insights with the originating plugin ID.

### Agent Dispatch

v2 plugins can dispatch background agent tasks — autonomous work sessions that run with full tool access. This is useful for plugins that receive external events (webhooks, schedules) and need the agent to perform multi-step work.

#### Dispatching a Task

```c
const char* request = "{"
    "\"prompt\": \"Summarize the latest commit and post to Slack\","
    "\"mode\": \"work\","
    "\"title\": \"Commit Summary\","
    "\"agent_address\": \"0x1a2b3c...\""
"}";
const char* result = host->dispatch(request);
// result: {"id":"<uuid>","status":"running"}
// or:     {"error":"rate_limit_exceeded","message":"..."}
```

**Request fields:**

| Field            | Type   | Required | Description                                               |
| ---------------- | ------ | -------- | --------------------------------------------------------- |
| `prompt`         | string | Yes      | The task prompt for the agent                             |
| `mode`           | string | No       | `"work"` (default) or `"chat"`                            |
| `title`          | string | No       | Display title for the task                                |
| `agent_address`  | string | No       | Crypto address of the target agent                        |
| `agent_id`       | string | No       | UUID of the target agent (alternative to `agent_address`) |
| `folder_bookmark`| string | No       | Base64-encoded security-scoped bookmark for folder access |

If neither `agent_address` nor `agent_id` is provided, the task is dispatched to the default agent.

**Agent addressing:** Prefer `agent_address` from the route request's `osaurus.agent_address` field — it is always present in route handler requests and ensures the task runs under the correct agent with its configured model and settings. Both `agent_address` and `agent_id` are accepted and resolved automatically.

**Rate limiting:** Dispatch is limited to 10 requests per minute per plugin. Exceeding this returns an error with `"error": "rate_limit_exceeded"`.

#### Polling Task Status

```c
const char* status = host->task_status("<task_id>");
// Returns JSON with task state, progress, and activity feed
```

**Response fields:**

| Field          | Type   | Description                                                   |
| -------------- | ------ | ------------------------------------------------------------- |
| `id`           | string | Task UUID                                                     |
| `title`        | string | Task title                                                    |
| `mode`         | string | `"work"` or `"chat"`                                          |
| `status`       | string | `"running"`, `"completed"`, `"failed"`, `"cancelled"`, `"awaiting_clarification"` |
| `progress`     | number | 0.0 – 1.0 progress estimate                                  |
| `current_step` | string | Description of current activity (if running)                  |
| `output`       | string | Current streaming output text (running tasks only, may be absent if empty) |
| `draft`        | string | Draft content set via `send_draft` (if any)                   |

#### Cancelling a Task

```c
host->dispatch_cancel("<task_id>");
```

Cancels a running or awaiting-clarification task. No return value.

#### Submitting Clarification

When a task enters the `"awaiting_clarification"` state, the plugin can respond:

```c
host->dispatch_clarify("<task_id>", "Use the staging environment");
```

This resumes the task with the provided response. Clarification is only available in `"work"` mode.

#### Interrupting a Task (Soft Stop)

```c
// Plain soft stop — agent wraps up gracefully and returns partial results
host->dispatch_interrupt("<task_id>", NULL);

// Interrupt and redirect — interrupts current work, re-enters with new instructions
host->dispatch_interrupt("<task_id>", "Focus on the login page instead");
```

Unlike `dispatch_cancel` (hard stop), `dispatch_interrupt` lets the agent finish its current step. When a message is provided, the agent resumes with that message injected into the conversation. The task emits `COMPLETED` (not `CANCELLED`) when it finishes. Work mode only; chat mode falls back to `stop()`.

#### Adding Issues to a Running Task

```c
const char* result = host->dispatch_add_issue(
    "<task_id>",
    "{\"title\": \"Fix the navbar\", \"description\": \"The navbar overflows on mobile\"}"
);
// Returns: {"status": "queued", "title": "Fix the navbar"}
```

Adds a new issue to a running work-mode task. The issue is queued and executed after the current issue completes. Returns an error if the task is not found, not active, or not in work mode.

#### Listing Active Tasks

```c
const char* result = host->list_active_tasks();
// Returns: {"tasks": [<task_status objects>]}
```

Returns all active tasks dispatched by the calling plugin. Useful for recovering state after a plugin restart — call this during `init()` to discover tasks that are still running.

#### Sending Draft Content

```c
host->send_draft("<task_id>", "{\"text\": \"Working on it...\", \"parse_mode\": \"markdown\"}");
```

Stores draft content on a task and emits a `DRAFT` event (type 8) back to the originating plugin. Use this for live-update messages — for example, a Telegram plugin can call `editMessageText` (which works in groups) to show progressive updates.

#### Example: Webhook-Triggered Dispatch

```c
const char* handle_route(osr_plugin_ctx_t ctx, const char* request_json) {
    MyPlugin* plugin = (MyPlugin*)ctx;

    // Parse the webhook event
    // ... extract event_type, event_data ...

    // Store the event
    plugin->host->db_exec(
        "INSERT INTO events (id, type, payload) VALUES (?1, ?2, ?3)",
        "[\"evt-42\", \"push\", \"{...}\"]"
    );

    // Dispatch agent work
    const char* result = plugin->host->dispatch(
        "{\"prompt\": \"Review the latest push event and create a summary\","
        " \"mode\": \"work\","
        " \"title\": \"Push Event Review\"}"
    );

    plugin->host->log(1, "Dispatched task for push event");

    return "{\"status\": 200, \"body\": \"ok\"}";
}
```

### Task Event Hooks

Instead of polling `task_status`, plugins can receive push notifications for task lifecycle events by setting the `on_task_event` callback on `osr_plugin_api`.

#### Registering the Callback

```c
static void my_task_event(osr_plugin_ctx_t ctx, const char* task_id,
                          int event_type, const char* event_json) {
    // Handle event based on event_type
}

// In your entry point:
api->on_task_event = my_task_event;
```

Set `on_task_event` to `NULL` to opt out — the host will not call it.

#### Event Types

| Constant                       | Value | Fired When                        | Payload Fields                                              |
| ------------------------------ | ----- | --------------------------------- | ----------------------------------------------------------- |
| `OSR_TASK_EVENT_STARTED`       | 0     | Task begins execution             | `status`, `mode`, `title`                                   |
| `OSR_TASK_EVENT_ACTIVITY`      | 1     | Meaningful action occurs          | `kind`, `title`, `detail`, `timestamp`, `metadata`          |
| `OSR_TASK_EVENT_PROGRESS`      | 2     | Progress or step changes          | `progress`, `current_step`, `title`                         |
| `OSR_TASK_EVENT_CLARIFICATION` | 3     | Agent needs human input           | `question`, `options`                                       |
| `OSR_TASK_EVENT_COMPLETED`     | 4     | Task finishes successfully        | `success` (true), `summary`, `session_id`, `title`, `output` |
| `OSR_TASK_EVENT_FAILED`        | 5     | Task finishes with failure        | `success` (false), `summary`, `title`                       |
| `OSR_TASK_EVENT_CANCELLED`     | 6     | Task is cancelled                 | `title`                                                     |
| `OSR_TASK_EVENT_OUTPUT`        | 7     | Agent generates streaming text    | `text`, `title`                                             |
| `OSR_TASK_EVENT_DRAFT`         | 8     | Plugin sends draft content        | `title`, `draft`                                            |

#### Event Payloads

All payloads are JSON strings. Examples:

**Started:**
```json
{"status": "running", "mode": "work", "title": "Commit Summary"}
```

**Activity:**
```json
{"kind": "tool_call", "title": "Tool", "detail": "grep", "timestamp": "2025-06-15T10:30:00Z", "metadata": {"tool_name": "grep"}}
```

Activity events fire for meaningful actions: tool calls, issue starts/completes, and artifacts. Step-level noise (`willExecuteStep`, `completedStep`) is filtered out. The `metadata` field provides structured data when available (e.g., `tool_name` for tool calls, `filename` for artifacts).

Available `kind` values:

| Kind          | Description                                    |
| ------------- | ---------------------------------------------- |
| `tool`        | Generic tool usage (backward-compatible alias) |
| `tool_call`   | Agent invoked a tool                           |
| `tool_result` | Tool returned a result                         |
| `thinking`    | Agent is reasoning or summarizing context      |
| `writing`     | Agent is generating text output                |
| `info`        | Informational status update                    |
| `progress`    | Progress milestone                             |
| `warning`     | Recoverable warning (e.g. retry)               |
| `success`     | Successful completion of a sub-task            |
| `error`       | Error in a sub-task                            |

**Progress:**
```json
{"progress": 0.45, "current_step": "Analyzing code structure", "title": "Build feature"}
```

Progress events are throttled to one per 500ms per task to avoid flooding the plugin. The `title` field is the task title, enabling displays like "Build feature — 45%".

**Clarification:**
```json
{"question": "Which branch should I target?", "options": ["main", "develop", "staging"]}
```

When this event fires, the task is paused. Call `host->dispatch_clarify(task_id, response)` to resume.

**Completed:**
```json
{"success": true, "summary": "Created PR #42 with commit summary", "session_id": "abc-123", "title": "Build feature", "output": "Here is the full agent output..."}
```

The `output` field contains the full accumulated agent output text. This makes the completed event self-contained — plugins don't need to stitch together `OUTPUT` events to get the final result.

**Failed:**
```json
{"success": false, "summary": "Could not access repository", "title": "Build feature"}
```

**Cancelled:**
```json
{"title": "Build feature"}
```

**Output:**
```json
{"text": "Here are the best restaurants in Irvine:\n\n1. ...", "title": "Restaurant search"}
```

Output events stream the agent's accumulated response text during work-mode execution. Throttled to one per second per task. Use this to show progressive response updates (e.g. draft messages in a chat integration).

**Draft:**
```json
{"title": "Build feature", "draft": {"text": "Working on it...", "parse_mode": "markdown"}}
```

Draft events are emitted when a plugin calls `host->send_draft()`. The `draft` object mirrors the JSON passed to `send_draft`. Use this for live-update messages in chat integrations (e.g., editing a placeholder message with progressive status).

#### Example: Handling Events

```c
static void my_task_event(osr_plugin_ctx_t ctx, const char* task_id,
                          int event_type, const char* event_json) {
    MyPlugin* plugin = (MyPlugin*)ctx;

    switch (event_type) {
        case OSR_TASK_EVENT_COMPLETED:
            plugin->host->log(1, "Task completed");
            // Parse event_json for summary, post to Slack, etc.
            break;

        case OSR_TASK_EVENT_FAILED:
            plugin->host->log(3, "Task failed");
            // Alert the user or retry
            break;

        case OSR_TASK_EVENT_CLARIFICATION:
            // Auto-respond or forward to a human
            plugin->host->dispatch_clarify(task_id,
                "Use the default settings");
            break;

        case OSR_TASK_EVENT_PROGRESS:
            // Update a progress bar or status display
            break;

        default:
            break;
    }
}
```

### Inference

v2 plugins can run chat completions and generate embeddings through any model configured in Osaurus — local MLX models, Apple Foundation Models, or remote providers.

When an `agent_address` is provided, inference resolves the **full agent context** — system prompt, memory, model, temperature, max tokens, and available tools — so the model behaves exactly as the configured agent would.

#### Chat Completion

```c
const char* request = "{"
    "\"model\": \"\","
    "\"messages\": [{\"role\": \"user\", \"content\": \"Classify this: bug report\"}],"
    "\"max_tokens\": 50,"
    "\"temperature\": 0.0"
"}";
const char* response = host->complete(request);
```

**Request format** follows the OpenAI chat completion schema:

| Field            | Type          | Required | Description                                                                 |
| ---------------- | ------------- | -------- | --------------------------------------------------------------------------- |
| `model`          | string        | Yes      | Model name, or `""` / `"default"` for the agent's configured model         |
| `messages`       | array         | Yes      | Array of `{role, content}` message objects                                  |
| `max_tokens`     | int           | No       | Maximum tokens to generate                                                  |
| `temperature`    | number        | No       | Sampling temperature (0.0 – 2.0)                                            |
| `agent_address`  | string        | No       | Agent crypto address — resolves full agent context (model, system prompt, memory, tools) |
| `tools`          | array or bool | No       | Tool definitions (OpenAI format), or `true` to use the agent's configured tools |
| `tool_choice`    | string/object | No       | Tool selection strategy (`"auto"`, `"none"`, or `{"type":"function","function":{"name":"..."}}`) |
| `max_iterations` | int           | No       | Maximum agentic loop iterations (default: `1`). Set higher to enable automatic tool execution |
| `preflight`      | bool          | No       | When `true`, runs a preflight capability search before inference to auto-discover relevant tools and context |

**Preflight capability search:** When `preflight` is `true` and `tools` is also enabled, Osaurus analyzes the user's message and performs a capability search to find relevant tools and context that might not be explicitly provided. Discovered tools are merged with any tools already in the request (deduplicating by name), and relevant context snippets are appended to the system prompt. The search intensity is controlled by the user's global preflight mode setting (minimal, balanced, or thorough). This is useful for plugins that want the model to dynamically discover and use the best tools for a task without knowing them in advance.

**Agent context resolution:** When `agent_address` is present, the following are resolved from the agent's configuration and applied to the request (unless the request provides explicit values):

- **System prompt** — prepended to `messages` if no system message is present
- **Memory context** — working memory and conversation history prepended to the system prompt
- **Model** — used when `model` is `""`/`"default"`
- **Temperature** — used when `temperature` is not set
- **Max tokens** — used when `max_tokens` is not set
- **Tools** — available when `"tools": true` is set in the request
- **Sandbox tools** — when the agent has autonomous execution enabled, sandbox tools (`sandbox_exec`, `sandbox_read_file`, `sandbox_write_file`, `sandbox_list_directory`, `sandbox_search_files`, `sandbox_install`, etc.) are automatically included in the tool set. Sandbox environment instructions are also injected into the system prompt.
- **Plugin instructions** — if the plugin manifest includes an `instructions` field, its content is automatically appended to the system prompt after all host-managed sections (agent prompt, sandbox section, memory) but before any preflight context. This is injected for both `complete` and `complete_stream` calls, even when no `agent_address` is provided. Use this to declare behavioral constraints, output formatting rules, or tool-calling patterns. Users can customize the instructions per-agent in the agent detail view under the Configure tab; the manifest value serves as the default and per-agent overrides take precedence when set.

**Model resolution order:**

| Value         | Resolves To                              |
| ------------- | ---------------------------------------- |
| `""` or `"default"` | Agent's configured model (if `agent_address` is provided), otherwise system default |
| `"foundation"`| Apple Foundation Model                   |
| specific name | Exact model by ID (e.g., `"gpt-4o"`, `"mlx-community/Llama-3.2-3B-Instruct"`) |

**Response:** Standard OpenAI-compatible chat completion JSON with `choices`, `usage`, etc. When tools were executed during the agentic loop, the response includes a `tool_calls_executed` array listing each tool call that was made. If `share_artifact` was called, the response also includes a `shared_artifacts` array with artifact metadata (`filename`, `mime_type`, `size`, `host_path`, `is_directory`, and optional `description`). Plugins should prefer reading artifacts from this field rather than relying solely on the `invoke(type: "artifact")` callback, since the response is available while the originating request context (e.g., active chat) is still valid.

#### Streaming Completion

For longer outputs, use the streaming variant to process tokens as they arrive:

```c
static void on_chunk(const char* chunk_json, void* user_data) {
    // chunk_json: {"choices":[{"delta":{"content":"Hello"}}]}
    // Process each token delta
}

const char* response = host->complete_stream(request, on_chunk, my_context);
// `response` contains the aggregated final result
// `on_chunk` was called for each intermediate token
```

The `on_chunk` callback is called on the same background thread — avoid blocking. The `user_data` pointer is passed through unchanged.

#### Agentic Inference (Tool Execution)

When `max_iterations` is greater than 1 and tools are available, inference runs an **agentic loop**: the model can call tools, which are automatically executed, and the results are fed back into the conversation for the next iteration. This continues until the model produces a final text response or the iteration cap is reached.

```c
const char* request = "{"
    "\"agent_address\": \"0xABC...\","
    "\"messages\": [{\"role\": \"user\", \"content\": \"Read main.py and summarize it\"}],"
    "\"tools\": true,"
    "\"max_iterations\": 10"
"}";
const char* response = host->complete(request);
// response includes "tool_calls_executed" with each tool that ran
```

For streaming, tool activity is emitted as chunks alongside content deltas:

```c
static void on_chunk(const char* chunk_json, void* user_data) {
    // Content delta:
    //   {"choices":[{"delta":{"content":"The file contains..."}}]}
    //
    // Tool call (model requesting a tool):
    //   {"choices":[{"delta":{"tool_calls":[{"id":"call_xxx",
    //     "function":{"name":"file_read","arguments":"{...}"}}]},
    //     "finish_reason":"tool_calls"}]}
    //
    // Tool result (after execution):
    //   {"choices":[{"delta":{"role":"tool","tool_call_id":"call_xxx",
    //     "content":"file contents..."}}]}
    //
    // Final stop:
    //   {"choices":[{"delta":{},"finish_reason":"stop"}]}
}

const char* response = host->complete_stream(request, on_chunk, ctx);
```

The agentic loop runs for at most `max_iterations` iterations (capped at 30). Each iteration is one LLM call that may or may not produce a tool call. If the model produces a text response without requesting a tool, the loop ends.

**Sandbox execution:** When `"tools": true` is set and the resolved agent has autonomous execution enabled, the agentic loop includes full sandbox capabilities. The model can execute commands, read/write files, install packages, and run scripts inside the sandboxed Linux environment — matching the behavior of Chat and Work modes.

**Artifact handling:** When the model calls `share_artifact` during the agentic loop, the artifact is fully processed — files are copied from the sandbox to `~/.osaurus/artifacts/`, the tool result is enriched with `host_path` and `file_size`, and all plugins with `artifact_handler: true` are notified. This means plugins can both produce and consume artifacts through the inference API.

**Capabilities hot-loading:** When the model calls `capabilities_load` during the agentic loop, newly discovered tools are dynamically injected into subsequent iterations. This allows the model to progressively expand its tool set as it discovers relevant capabilities.

#### Embeddings

```c
const char* request = "{"
    "\"model\": \"\","
    "\"input\": [\"How to reset password\", \"Account locked out\"]"
"}";
const char* response = host->embed(request);
```

**Request fields:**

| Field   | Type            | Required | Description                         |
| ------- | --------------- | -------- | ----------------------------------- |
| `model` | string          | No       | Embedding model name                |
| `input` | string or array | Yes      | Text(s) to embed                    |

**Response:** JSON with `data` (array of embedding objects with `embedding` vector), `model`, and `usage`.

#### Example: Local Classification

```c
const char* classify_event(const osr_host_api* host, const char* event_text) {
    char request[4096];
    snprintf(request, sizeof(request),
        "{\"model\": \"\","
        " \"messages\": [{\"role\": \"system\", \"content\": \"Classify the event as: bug, feature, question. Reply with one word.\"},"
        "               {\"role\": \"user\", \"content\": \"%s\"}],"
        " \"max_tokens\": 5,"
        " \"temperature\": 0.0}",
        event_text);

    return host->complete(request);
}
```

#### Example: Agentic File Analysis

```c
const char* analyze_project(const osr_host_api* host, const char* agent_addr) {
    char request[4096];
    snprintf(request, sizeof(request),
        "{\"agent_address\": \"%s\","
        " \"messages\": [{\"role\": \"user\", \"content\": \"List all TODO comments in the project\"}],"
        " \"tools\": true,"
        " \"max_iterations\": 15}",
        agent_addr);

    return host->complete(request);
    // The model will use file_search, file_read, etc. autonomously
    // and return a final summary with tool_calls_executed metadata
}
```

#### Example: Sandbox Execution

When the agent has autonomous execution enabled, the model can use sandbox tools to run commands and manage files in the sandboxed Linux environment:

```c
const char* run_in_sandbox(const osr_host_api* host, const char* agent_addr) {
    char request[4096];
    snprintf(request, sizeof(request),
        "{\"agent_address\": \"%s\","
        " \"messages\": [{\"role\": \"user\", \"content\": \"Install numpy, write a Python script that generates a 10x10 random matrix, and run it\"}],"
        " \"tools\": true,"
        " \"max_iterations\": 20}",
        agent_addr);

    return host->complete(request);
    // The model will use sandbox_pip_install, sandbox_write_file,
    // sandbox_exec, etc. to complete the task autonomously
}
```

### Models

Plugins can enumerate all available models to present choices to users or make dynamic routing decisions.

```c
const char* models_json = host->list_models();
```

**Response format:**

```json
{
  "models": [
    {
      "id": "mlx-community/Llama-3.2-3B-Instruct",
      "name": "Llama 3.2 3B Instruct",
      "provider": "local",
      "type": "chat",
      "capabilities": ["chat", "tool_calling"]
    },
    {
      "id": "text-embedding-3-small",
      "name": "Text Embedding 3 Small",
      "provider": "openai",
      "type": "embedding",
      "dimensions": 1536,
      "capabilities": ["embedding"]
    }
  ]
}
```

**Model fields:**

| Field            | Type   | Description                                          |
| ---------------- | ------ | ---------------------------------------------------- |
| `id`             | string | Unique model identifier (used in `model` field)      |
| `name`           | string | Human-readable display name                          |
| `provider`       | string | Source: `"local"`, `"apple"`, `"openai"`, etc.       |
| `type`           | string | `"chat"` or `"embedding"`                            |
| `dimensions`     | int    | Embedding vector dimensions (embedding models only)  |
| `capabilities`   | array  | List of supported capabilities                       |

**Sources:** Models are aggregated from local MLX downloads, Apple Foundation Models (on supported hardware), and any remote providers configured in Osaurus settings.

### HTTP Client

v2 plugins can make outbound HTTP requests through the host, with built-in SSRF protection and resource limits.

#### Making a Request

```c
const char* request = "{"
    "\"method\": \"POST\","
    "\"url\": \"https://api.notion.com/v1/pages\","
    "\"headers\": {"
    "    \"Authorization\": \"Bearer ntn_...\","
    "    \"Notion-Version\": \"2022-06-28\","
    "    \"Content-Type\": \"application/json\""
    "},"
    "\"body\": \"{\\\"parent\\\":{\\\"database_id\\\":\\\"abc\\\"}}\","
    "\"timeout_ms\": 30000"
"}";
const char* response = host->http_request(request);
```

**Request fields:**

| Field              | Type   | Required | Description                                      |
| ------------------ | ------ | -------- | ------------------------------------------------ |
| `method`           | string | Yes      | HTTP method (`GET`, `POST`, `PUT`, `DELETE`, etc.)|
| `url`              | string | Yes      | Full URL (HTTPS recommended for external hosts)  |
| `headers`          | object | No       | Request headers as key-value pairs                |
| `body`             | string | No       | Request body                                      |
| `body_encoding`    | string | No       | `"utf8"` (default) or `"base64"`                  |
| `timeout_ms`       | int    | No       | Request timeout in milliseconds (default: 30000)  |
| `follow_redirects` | bool   | No       | Follow HTTP redirects (default: `true`)           |

**Response fields:**

| Field           | Type   | Description                              |
| --------------- | ------ | ---------------------------------------- |
| `status`        | int    | HTTP status code                         |
| `headers`       | object | Response headers                         |
| `body`          | string | Response body                            |
| `body_encoding` | string | `"utf8"` or `"base64"`                   |
| `elapsed_ms`    | int    | Request duration in milliseconds         |

**Error response** (on connection failure):

```json
{
  "error": "connection_timeout",
  "message": "Request timed out after 30000ms"
}
```

#### Error Types

| Error                | Description                                    |
| -------------------- | ---------------------------------------------- |
| `connection_timeout` | Request exceeded `timeout_ms`                  |
| `dns_failure`        | Could not resolve hostname                     |
| `tls_error`          | TLS handshake or certificate error             |
| `ssrf_blocked`       | Request to private/reserved IP range blocked   |
| `request_too_large`  | Request body exceeds 50 MB limit               |
| `response_too_large` | Response body exceeds 50 MB limit              |

#### SSRF Protection

Requests to private and reserved IP ranges are blocked by default to prevent server-side request forgery:

- `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` (RFC 1918)
- `127.0.0.0/8` (loopback)
- `169.254.0.0/16` (link-local)
- `::1`, `fe80::/10` (IPv6 loopback and link-local)

Attempts to reach these ranges return `{"error": "ssrf_blocked"}`.

#### Limits

| Limit                   | Value  |
| ----------------------- | ------ |
| Max response body       | 50 MB  |
| Concurrent requests     | 10 per plugin |
| Max timeout             | 5 minutes (300,000 ms) |

#### Example: Fetching from Notion API

```c
const char* fetch_notion_page(const osr_host_api* host, const char* page_id,
                              const char* api_key) {
    char request[2048];
    snprintf(request, sizeof(request),
        "{\"method\": \"GET\","
        " \"url\": \"https://api.notion.com/v1/pages/%s\","
        " \"headers\": {"
        "   \"Authorization\": \"Bearer %s\","
        "   \"Notion-Version\": \"2022-06-28\""
        " },"
        " \"timeout_ms\": 10000}",
        page_id, api_key);

    return host->http_request(request);
}
```

### File I/O

v2 plugins can read shared artifact files through the host API. This is primarily used by [artifact handlers](#artifact-handling) to retrieve file contents for uploading to external services.

#### Reading a File

```c
const char* request = "{\"path\": \"/Users/me/.osaurus/artifacts/ctx-123/image.png\"}";
const char* response = host->file_read(request);
```

**Request fields:**

| Field  | Type   | Required | Description                        |
| ------ | ------ | -------- | ---------------------------------- |
| `path` | string | Yes      | Absolute path to the file to read  |

**Response fields:**

| Field       | Type   | Description                          |
| ----------- | ------ | ------------------------------------ |
| `data`      | string | Base64-encoded file contents         |
| `size`      | int    | File size in bytes                   |
| `mime_type` | string | Detected MIME type (from extension)  |

**Error response:**

```json
{"error": "access_denied", "message": "File read restricted to artifact paths"}
```

#### Security Restrictions

- `file_read` is restricted to `~/.osaurus/artifacts/`. Attempts to read files outside this directory return `"error": "access_denied"`.
- Path traversal (e.g., `../../etc/passwd`) is blocked — paths are resolved and validated against the allowed prefix.
- Maximum file size is 50 MB. Files exceeding this limit return `"error": "file_too_large"`.

#### Error Types

| Error              | Description                                      |
| ------------------ | ------------------------------------------------ |
| `invalid_request`  | Missing or malformed `path` field                |
| `access_denied`    | Path is outside `~/.osaurus/artifacts/`          |
| `not_found`        | File does not exist at the given path            |
| `file_too_large`   | File exceeds the 50 MB limit                     |
| `read_error`       | I/O error while reading the file                 |

---

## Tunnel Endpoints

Osaurus exposes four authenticated HTTP endpoints for managing agent tasks from external callers — scripts, MCP clients, CI pipelines, or any HTTP-capable tool. These are distinct from the in-process C callbacks; use the C callbacks from within plugin dylibs and the tunnel endpoints from outside the process.

All tunnel endpoints require `osk-v1` Bearer authentication (loopback connections may bypass this requirement):

```
Authorization: Bearer osk-v1-<your-access-key>
```

### POST /v1/agents/{identifier}/dispatch

Dispatch a new task to an agent. The `{identifier}` can be a UUID or an `agent_address` (crypto address).

```bash
curl -X POST https://127.0.0.1:1337/v1/agents/0x1a2b3c.../dispatch \
  -H "Authorization: Bearer osk-v1-..." \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Summarize recent commits", "mode": "work"}'
```

**Request body:** Same fields as the C `dispatch()` function (`prompt`, `mode`, `title`, `folder_bookmark`). The `agent_id`/`agent_address` is inferred from the URL path.

**Response:** `{"id": "<uuid>", "status": "running"}`

### GET /v1/tasks/{task_id}

Poll the status of a dispatched task.

```bash
curl https://127.0.0.1:1337/v1/tasks/<task_id> \
  -H "Authorization: Bearer osk-v1-..."
```

**Response:** JSON with `status`, `progress`, `current_step`, and other task state fields.

### DELETE /v1/tasks/{task_id}

Cancel a running or awaiting-clarification task.

```bash
curl -X DELETE https://127.0.0.1:1337/v1/tasks/<task_id> \
  -H "Authorization: Bearer osk-v1-..."
```

**Response:** `{"status": "cancelled"}`

### POST /v1/tasks/{task_id}/clarify

Submit a clarification response for a task in `"awaiting_clarification"` state.

```bash
curl -X POST https://127.0.0.1:1337/v1/tasks/<task_id>/clarify \
  -H "Authorization: Bearer osk-v1-..." \
  -H "Content-Type: application/json" \
  -d '{"response": "Use the staging environment"}'
```

**Response:** `{"status": "running"}`

### When to Use Tunnel vs C Callbacks

| Caller                   | Use                    |
| ------------------------ | ---------------------- |
| Plugin dylib (in-process)| C callbacks on `osr_host_api` — no auth needed |
| External script / CI     | Tunnel HTTP endpoints — requires `osk-v1` auth |
| MCP client               | Tunnel HTTP endpoints — requires `osk-v1` auth |

---

## Packaging & Distribution

### Packaging Convention

**Important:** Plugin zip files MUST follow the naming convention:

```
<plugin_id>-<version>.zip
```

Examples:

- `com.acme.echo-1.0.0.zip`
- `dev.example.MyPlugin-0.1.0.zip`
- `my-plugin-2.3.1-beta.zip`

The plugin_id and version are extracted from the filename during installation. The version must be valid semver.

#### Zip Structure

A v2 plugin zip can include optional directories and files alongside the `.dylib`:

```
com.acme.slack-1.0.0.zip
├── libSlack.dylib        # Required
├── SKILL.md              # Optional: AI skill guidance
├── README.md             # Optional: displayed in plugin detail UI
├── CHANGELOG.md          # Optional: displayed in Changelog tab
└── web/                  # Optional: static frontend assets
    ├── index.html
    ├── assets/
    │   ├── app-3f8a2b.js
    │   └── app-7c1d4e.css
    └── favicon.ico
```

### Code Signing

**Required:** All distributed macOS plugins (`.dylib`) must be code-signed with a valid Apple developer certificate. Osaurus verifies the code signature at load time and will refuse to load unsigned or invalidly signed plugins.

To sign your plugin:

1.  Obtain a "Developer ID Application" certificate from the [Apple Developer](https://developer.apple.com) portal ($99/year).
2.  Run the `codesign` tool on your `.dylib` before packaging:

```bash
codesign --force --options runtime --timestamp --sign "Developer ID Application: Your Name (TEAMID)" libMyPlugin.dylib
```

> **Note:** In DEBUG builds, code signature verification is relaxed to allow unsigned plugins during development. For distribution, a valid code signature is mandatory.

### Artifact Signing (Minisign)

Minisign signature verification is **mandatory** for all plugins installed through the central registry. This ensures the integrity and authenticity of the distributed ZIP file and provides author binding (only the holder of the private key can publish updates).

- Install Minisign: `brew install minisign`
- Generate a key pair (once): `minisign -G -p minisign.pub -s minisign.key`
- Sign your zip: `minisign -S -s minisign.key -m echo-macos-arm64.zip -x echo-macos-arm64.zip.minisig`
- Publish:
  - The public key (contents of `minisign.pub`) in your spec under `public_keys.minisign`
  - The signature (contents of `.minisig`) in the spec under `versions[].artifacts[].minisign.signature`

#### Author Key Binding (Trust on First Use)

Once a plugin is first installed with a minisign public key, Osaurus records that key in the install receipt. On subsequent updates, the new spec's public key is compared against the stored key. If the key has changed, the update is rejected to prevent supply chain attacks.

**Important:** Keep your minisign private key secure. If you lose it, existing users will not be able to update your plugin without manual intervention. There is no key rotation mechanism — a key change is treated as a potential compromise.

### Central Registry

Osaurus uses a single, git-backed central plugin index maintained by the Osaurus team.

1. Package your plugin with the correct naming convention: `<plugin_id>-<version>.zip`
2. Code-sign your `.dylib` with a valid Developer ID Application certificate.
3. Publish release artifacts (.zip containing your signed `.dylib`) on GitHub Releases.
4. Generate a SHA256 checksum of the zip.
5. Sign the zip with Minisign (**required** — installation will fail without a valid signature).
6. Submit a PR to the central index repo adding `plugins/<your.plugin.id>.json` with your metadata.

The registry entry should include publishing metadata (`homepage`, `license`, `authors`) and artifact information. You can also declare a `capabilities` summary listing your plugin's tools and skills:

```json
{
  "plugin_id": "com.acme.pptx",
  "name": "PPTX",
  "description": "Create PowerPoint presentations",
  "capabilities": {
    "tools": [
      { "name": "create_presentation", "description": "Create a new presentation" }
    ],
    "skills": [
      { "name": "osaurus-pptx", "description": "Guides the AI through presentation creation workflows" }
    ]
  },
  "versions": [ ... ]
}
```

The `capabilities` block is **informational only** — it is used for the plugin listing in the registry UI. The actual skills are discovered automatically from `SKILL.md` files in the archive at install time (see [Plugin Skills](#plugin-skills-skillmd)).

> **Note:** If you use the shared CI workflow (`osaurus-ai/osaurus-tools/.github/workflows/build-plugin.yml`), the `capabilities` block is generated automatically. Tools are extracted from the dylib manifest, and skills are detected from any `SKILL.md` file at the repository root. You do not need to write this JSON by hand.

---

## Permissions Reference

Some tools require macOS system permissions that must be granted at the app level:

| Permission               | How to Grant                                             | Use Case                                          |
| ------------------------ | -------------------------------------------------------- | ------------------------------------------------- |
| **Automation**           | System Settings → Privacy & Security → Automation        | AppleScript, controlling other apps               |
| **Accessibility**        | System Settings → Privacy & Security → Accessibility     | UI automation, input simulation, computer control |
| **Calendar Automation**  | System Settings → Privacy & Security → Automation        | Controlling Calendar app via AppleScript          |
| **Mail Automation**      | System Settings → Privacy & Security → Automation        | Controlling Mail app via AppleScript              |
| **Calendar**             | System Settings → Privacy & Security → Calendars         | Reading and creating calendar events directly     |
| **Contacts**             | System Settings → Privacy & Security → Contacts          | Searching contacts, reading contact info          |
| **Location**             | System Settings → Privacy & Security → Location Services | Accessing current location                        |
| **Maps**                 | System Settings → Privacy & Security → Automation        | Controlling Maps app                              |
| **Microphone**           | System Settings → Privacy & Security → Microphone        | Capturing audio input                             |
| **Notes**                | System Settings → Privacy & Security → Automation        | Reading and creating notes                        |
| **Reminders**            | System Settings → Privacy & Security → Reminders         | Reading and creating reminders                    |
| **Screen Recording**     | System Settings → Privacy & Security → Screen Recording  | Capturing screen content                          |
| **Full Disk Access**     | System Settings → Privacy & Security → Full Disk Access  | Accessing Messages, Safari data, other app data   |

**User Experience:**

- The Tools UI shows a warning badge on plugins/tools that need permissions
- Users see exactly which permissions are missing
- One-click buttons to grant permissions or open System Settings
- Settings → System Permissions shows all available permissions with status

**Runtime Behavior:**

- System permissions are checked before tool execution
- If missing, execution fails with a clear error message indicating which permissions are needed
- Users don't need to restart the app after granting permissions

---

## ABI Reference

The C header is at `Packages/OsaurusCore/Tools/PluginABI/osaurus_plugin.h`.

```c
// v2 entry point — receives host callbacks
const osr_plugin_api* osaurus_plugin_entry_v2(const osr_host_api* host);

// v1 entry point (legacy)
const osr_plugin_api* osaurus_plugin_entry(void);

// Host API struct (20 callbacks across 9 capability groups)
typedef struct {
    uint32_t           version;           // OSR_ABI_VERSION_2

    // Config + Storage + Logging
    osr_config_get_fn       config_get;
    osr_config_set_fn       config_set;
    osr_config_delete_fn    config_delete;
    osr_db_exec_fn          db_exec;
    osr_db_query_fn         db_query;
    osr_log_fn              log;

    // Agent Dispatch
    osr_dispatch_fn         dispatch;
    osr_task_status_fn      task_status;
    osr_dispatch_cancel_fn  dispatch_cancel;
    osr_dispatch_clarify_fn dispatch_clarify;

    // Inference
    osr_complete_fn         complete;
    osr_complete_stream_fn  complete_stream;
    osr_embed_fn            embed;
    osr_list_models_fn      list_models;

    // HTTP Client
    osr_http_request_fn     http_request;

    // File I/O
    osr_file_read_fn        file_read;

    // Extended Agent Dispatch (v2 trailing fields)
    osr_list_active_tasks_fn   list_active_tasks;
    osr_send_draft_fn          send_draft;
    osr_dispatch_interrupt_fn  dispatch_interrupt;
    osr_dispatch_add_issue_fn  dispatch_add_issue;
} osr_host_api;

// Task lifecycle event types (for on_task_event callback)
#define OSR_TASK_EVENT_STARTED          0
#define OSR_TASK_EVENT_ACTIVITY         1
#define OSR_TASK_EVENT_PROGRESS         2
#define OSR_TASK_EVENT_CLARIFICATION    3
#define OSR_TASK_EVENT_COMPLETED        4
#define OSR_TASK_EVENT_FAILED           5
#define OSR_TASK_EVENT_CANCELLED        6
#define OSR_TASK_EVENT_OUTPUT           7
#define OSR_TASK_EVENT_DRAFT            8

// ABI version constants
#define OSR_ABI_VERSION_1 1
#define OSR_ABI_VERSION_2 2

// Extended plugin API struct (v2 fields appended after v1)
typedef struct {
    // v1 fields (unchanged)
    void (*free_string)(const char* s);
    osr_plugin_ctx_t (*init)(void);
    void (*destroy)(osr_plugin_ctx_t ctx);
    const char* (*get_manifest)(osr_plugin_ctx_t ctx);
    const char* (*invoke)(osr_plugin_ctx_t ctx, const char* type,
                          const char* id, const char* payload);

    // v2 fields
    uint32_t version;
    const char* (*handle_route)(osr_plugin_ctx_t ctx, const char* request_json);
    void (*on_config_changed)(osr_plugin_ctx_t ctx, const char* key,
                              const char* value);
    void (*on_task_event)(osr_plugin_ctx_t ctx, const char* task_id,
                          int event_type, const char* event_json);
} osr_plugin_api;
```

---

## Language-Specific Notes

### Rust Authors

Create a `cdylib` exposing `osaurus_plugin_entry` (v1) or `osaurus_plugin_entry_v2` (v2) that returns the generic function table. For v1, implement `init`, `destroy`, `get_manifest`, `invoke`, and `free_string`. For v2, also set `version = 2` and optionally implement `handle_route`, `on_config_changed`, and `on_task_event`. Store the `osr_host_api` pointer passed to the v2 entry point for access to all 20 host callbacks — config, data store, logging, agent dispatch (`dispatch`, `task_status`, `dispatch_cancel`, `dispatch_clarify`, `list_active_tasks`, `dispatch_interrupt`, `dispatch_add_issue`, `send_draft`), inference (`complete`, `complete_stream`, `embed`), model enumeration (`list_models`), outbound HTTP (`http_request`), and file I/O (`file_read`). All callbacks use C strings (null-terminated UTF-8) with JSON payloads; wrap them in safe Rust abstractions using `CStr`/`CString`.
