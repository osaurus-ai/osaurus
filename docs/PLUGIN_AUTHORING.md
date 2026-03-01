# Osaurus Plugin Authoring

This document describes how to build external plugins for Osaurus using the Generic C ABI. Plugins are distributed as a `.dylib` in a zip file with a specific naming convention.

## TL;DR (Swift)

1. Scaffold a Swift plugin:

```bash
osaurus tools create MyPlugin --language swift
```

2. Build and package:

```bash
cd MyPlugin
swift build -c release
cp .build/release/libMyPlugin.dylib ./libMyPlugin.dylib

# Sign the dylib (REQUIRED for downloaded plugins)
codesign -s "Developer ID Application: Your Name (TEAMID)" ./libMyPlugin.dylib

# Package with the naming convention: <plugin_id>-<version>.zip
osaurus tools package dev.example.MyPlugin 0.1.0
```

3. Install:

```bash
# Install from the packaged zip (filename determines plugin_id and version)
osaurus tools install ./dev.example.MyPlugin-0.1.0.zip
```

The plugin will be unpacked into:
`~/.osaurus/Tools/<plugin_id>/<version>/`

## Packaging Convention

**Important:** Plugin zip files MUST follow the naming convention:

```
<plugin_id>-<version>.zip
```

Examples:

- `com.acme.echo-1.0.0.zip`
- `dev.example.MyPlugin-0.1.0.zip`
- `my-plugin-2.3.1-beta.zip`

The plugin_id and version are extracted from the filename during installation. The version must be valid semver.

### Zip Structure

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

## ABI Overview

The header is available at:
`Packages/OsaurusCore/Tools/PluginABI/osaurus_plugin.h`

Osaurus supports two ABI versions. Existing v1 plugins continue to work without changes.

### v1 ABI (Tools Only)

- **Entry Point**: Plugin exports `osaurus_plugin_entry` returning a pointer to `osr_plugin_api`.
- **Lifecycle**:
  - `init()`: Called once on load. Returns an opaque `context` pointer.
  - `destroy(ctx)`: Called on unload.
  - `get_manifest(ctx)`: Returns a JSON string describing capabilities.
  - `invoke(ctx, type, id, payload)`: Generic invocation function.
  - `free_string(s)`: Called by host to free strings returned by the plugin.

### v2 ABI (Tools + Routes + Storage + Config)

v2 extends v1 with HTTP route handling, persistent storage, and config change notifications. Osaurus tries the v2 entry point first and falls back to v1 if the symbol is not found.

- **Entry Point**: Plugin exports `osaurus_plugin_entry_v2(const osr_host_api* host)`. The host API struct provides callbacks for config access, database operations, and logging.
- **New fields on `osr_plugin_api`** (appended after v1 fields for binary compatibility):
  - `version`: Set to `2` (`OSR_ABI_VERSION_2`).
  - `handle_route(ctx, request_json)`: Called when an HTTP request hits a plugin route. Returns JSON. May be `NULL` if the plugin has no routes.
  - `on_config_changed(ctx, key, value)`: Called when a config value changes in the host UI. May be `NULL`.
- **Host API (`osr_host_api`)** — Injected at init, provides:
  - `config_get(key)` / `config_set(key, value)` / `config_delete(key)` — Keychain-backed config store.
  - `db_exec(sql, params_json)` / `db_query(sql, params_json)` — Sandboxed per-plugin SQLite database.
  - `log(level, message)` — Structured logging to the Osaurus log.

```c
// v2 entry point — receives host callbacks
const osr_plugin_api* osaurus_plugin_entry_v2(const osr_host_api* host);

// Host API struct
typedef struct {
    uint32_t           version;        // OSR_ABI_VERSION_2
    osr_config_get_fn  config_get;
    osr_config_set_fn  config_set;
    osr_config_delete_fn config_delete;
    osr_db_exec_fn     db_exec;
    osr_db_query_fn    db_query;
    osr_log_fn         log;
} osr_host_api;

// Extended plugin API struct (v2 fields appended after v1)
typedef struct {
    // v1 fields (unchanged)
    void (*free_string)(const char* s);
    osr_plugin_ctx_t (*init)(void);
    void (*destroy)(osr_plugin_ctx_t ctx);
    const char* (*get_manifest)(osr_plugin_ctx_t ctx);
    const char* (*invoke)(osr_plugin_ctx_t ctx, const char* type, const char* id, const char* payload);

    // v2 fields
    uint32_t version;
    const char* (*handle_route)(osr_plugin_ctx_t ctx, const char* request_json);
    void (*on_config_changed)(osr_plugin_ctx_t ctx, const char* key, const char* value);
} osr_plugin_api;
```

### Migration from v1 to v2

Upgrading is additive. Change your entry point from `osaurus_plugin_entry` to `osaurus_plugin_entry_v2`, store the host API pointer, set `api.version = 2`, and populate the new function pointers (or leave them `NULL` if unused). Osaurus detects the ABI version from `api->version` and enables features accordingly.

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

**Full v2 manifest (tools + routes + config + web + docs):**

```json
{
  "plugin_id": "com.acme.slack",
  "version": "1.0.0",
  "description": "Slack integration",
  "capabilities": {
    "tools": [ ... ],
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

All v2 capabilities (`routes`, `config`, `web`, `docs`) are optional. A v2 plugin can declare any combination of them.

#### Tool Requirements

The `requirements` array specifies what permissions or capabilities the tool needs. There are two types:

1. **System Permissions** - macOS system-level permissions that users grant at the app level
2. **Custom Permissions** - Plugin-specific permissions that users grant per-tool

**System Permissions:**

| Requirement     | Description                                                                                       |
| --------------- | ------------------------------------------------------------------------------------------------- |
| `automation`    | AppleScript/Apple Events automation - allows controlling other applications                       |
| `accessibility` | Accessibility API access - allows UI interaction, input simulation, computer control              |
| `calendar`      | Calendar access (EventKit) - allows plugins to read and create calendar events directly           |
| `contacts`      | Contacts access - allows plugins to access and search contacts                                    |
| `location`      | Location access - allows plugins to access the user's current location                            |
| `maps`          | Maps access (via AppleScript) - allows plugins to control Maps app                                |
| `notes`         | Notes access (via AppleScript) - allows plugins to read and create notes                          |
| `reminders`     | Reminders access (EventKit) - allows plugins to read and create tasks and reminders               |
| `disk`          | Full Disk Access - allows accessing protected files like the Messages database and other app data |

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

1. Osaurus checks if the required permissions are granted at the OS level
2. If any are missing, execution fails with a clear error message
3. Users can grant permissions via Settings → System Permissions or when prompted by the tool

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

When a tool is invoked, Osaurus automatically injects configured secrets into the payload under the `_secrets` key:

```swift
private struct WeatherTool {
    let name = "get_weather"

    struct Args: Decodable {
        let location: String
        let _secrets: [String: String]?  // Secrets are injected here
    }

    func run(args: String) -> String {
        guard let data = args.data(using: .utf8),
              let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments\"}"
        }

        // Get the API key from secrets
        guard let apiKey = input._secrets?["api_key"] else {
            return "{\"error\": \"API key not configured. Please configure secrets in Osaurus settings.\"}"
        }

        // Use the API key
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

        // Resolve relative path using working directory
        let inputPath: String
        if let workingDir = input._context?.working_directory {
            inputPath = "\(workingDir)/\(input.input_path)"
        } else {
            // No folder context - assume absolute path
            inputPath = input.input_path
        }

        // Validate path stays within working directory (security)
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

Include `SKILL.md` in your plugin's zip archive alongside the `.dylib`. During installation, Osaurus searches the entire archive for files named `SKILL.md` (case-insensitive) and copies them into a `skills/` directory within the plugin's install location.

You can place `SKILL.md` at the root of the archive or in a subdirectory — the installer will find it either way. If your plugin bundles multiple skills, place each in its own subdirectory; the parent directory name is used as a prefix for disambiguation.

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

### Invocation

When Osaurus needs to execute a capability, it calls `invoke`:

- `type`: e.g. `"tool"`
- `id`: e.g. `"echo_tool"`
- `payload`: JSON string arguments (e.g. `{"message": "hello"}`)
  - If the plugin has secrets configured, they are injected under the `_secrets` key
  - If a folder context is active, it is injected under the `_context` key

The plugin returns a JSON string response (allocated; host frees it).

## HTTP Routes

v2 plugins can register HTTP route handlers exposed through the Osaurus server and relay tunnel. This enables OAuth flows, webhook endpoints, and plugin-hosted web apps.

### Route Declaration

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
| `auth`        | string   | No       | Auth level: `none`, `verify`, or `owner` (default)   |

Paths support wildcards: `/app/*` matches `/app/`, `/app/index.html`, `/app/assets/style.css`, etc.

### Resulting URLs

Routes are namespaced under `/plugins/<plugin_id>/` to prevent collisions. Two plugins can both declare `path: "/callback"` with zero conflict.

```
Local:   http://127.0.0.1:1337/plugins/com.acme.slack/callback
Tunnel:  https://0x<agent-address>.agent.osaurus.ai/plugins/com.acme.slack/callback
```

### Auth Levels

| Level    | Meaning                                                                                    |
| -------- | ------------------------------------------------------------------------------------------ |
| `none`   | Public. No auth required. Used for OAuth callbacks and webhook verification.               |
| `verify` | Plugin handles its own verification (e.g., Slack signing secret). Raw request passed through. |
| `owner`  | Requires a valid Osaurus access key (`osk-v1`). For plugin web UIs and admin endpoints.    |

Rate limiting is applied to `none` and `verify` routes at 100 requests/minute per plugin. `owner` routes are unlimited.

### Agent-Scoped Routing

Plugin routes are scoped per agent. When a plugin is enabled for an agent, its routes are accessible on that agent's tunnel. When disabled, the routes are removed.

- All plugin route requests require an `X-Osaurus-Agent-Id` header identifying the requesting agent.
- Osaurus checks the agent's `enabledPlugins` map to verify the plugin is active for that agent.
- Agents manage plugin enablement in the Management window under Agents → Capabilities.

### Request / Response Schema

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
  "remote_addr": "203.0.113.42",
  "plugin_id": "com.acme.slack",
  "osaurus": {
    "base_url": "https://0x1234.agent.osaurus.ai",
    "plugin_url": "https://0x1234.agent.osaurus.ai/plugins/com.acme.slack"
  }
}
```

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

---

## Storage

v2 plugins have access to two storage tiers, both provided through the `osr_host_api` callbacks injected at init.

### Config Store (Secure, Small)

For secrets, tokens, and settings. Backed by the macOS Keychain. Accessed via the host API:

```c
const char* value = host->config_get("access_token");
host->config_set("access_token", "xoxb-...");
host->config_delete("access_token");
```

Config values are also used by the [Configuration UI](#configuration-ui) — fields of type `secret` are stored here automatically.

### Data Store (Structured, Larger)

Each plugin gets a sandboxed SQLite database at:

```
~/Library/Application Support/com.dinoki.osaurus/Tools/<plugin_id>/data.db
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
host->log(0, "Processing webhook event");  // 0 = info
host->log(1, "Missing signing secret");    // 1 = warning
host->log(2, "Database write failed");     // 2 = error
```

---

## Configuration UI

Plugins can declare a settings schema in the manifest that Osaurus renders natively in the Management window under the plugin's detail view.

### Manifest Declaration

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

### Supported Field Types

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

### Field Properties

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

### Validation

| Field          | Applies to    | Description                             |
| -------------- | ------------- | --------------------------------------- |
| `required`     | all           | Must be non-empty                       |
| `pattern`      | text, secret  | Regex the value must match              |
| `pattern_hint` | text, secret  | Human-readable error shown on mismatch  |
| `min` / `max`  | number        | Numeric bounds                          |
| `min_length` / `max_length` | text, secret | String length bounds       |

### Template Variables

Readonly and computed fields can reference dynamic values:

| Variable           | Value                                            |
| ------------------ | ------------------------------------------------ |
| `{{plugin_url}}`   | Full URL to plugin route prefix                  |
| `{{plugin_id}}`    | Plugin ID                                        |
| `{{config.KEY}}`   | Current value of another config key              |

### Config Change Notification

When the user updates a config value in the UI, the plugin's `on_config_changed` callback is invoked:

```c
void on_config_changed(osr_plugin_ctx_t ctx, const char* key, const char* value);
```

This lets the plugin react immediately to config changes (e.g., reconnect a WebSocket when a token changes).

---

## Static Web Serving

Plugins can ship a full frontend (React, Svelte, Vue, vanilla JS — anything that builds to static files). Osaurus serves the `web/` directory directly, without calling the dylib for static assets.

### Manifest Declaration

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

### Context Injection

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

The frontend can use these values for API calls:

```javascript
const res = await fetch(`${window.__osaurus.baseUrl}/api/widgets`);
```

---

## Plugin Documentation

Plugins can include a `README.md` and `CHANGELOG.md` that are displayed in the Osaurus Management window when viewing the plugin's detail page.

### Manifest Declaration

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

### UI Rendering

The plugin detail view shows tabbed content:

- **README** — Rendered as Markdown.
- **Settings** — The config UI from [Configuration UI](#configuration-ui).
- **Changelog** — Rendered as Markdown if `CHANGELOG.md` is present.
- **Doc Links** — External links displayed below the content.

---

## Developer Workflow

### Hot Reload

The `osaurus tools dev` command watches for `.dylib` changes and sends a reload signal to the Osaurus app:

```bash
osaurus tools dev com.acme.slack
```

Recompile your plugin and it reloads without restarting the server:

```bash
swift build -c release && cp .build/release/libSlack.dylib ~/.osaurus/Tools/com.acme.slack/1.0.0/
```

### Frontend Dev Proxy

For plugins with a `web/` frontend, use `--web-proxy` to proxy static file requests to a local dev server (e.g., Vite) instead of serving from disk:

```bash
# Terminal 1: Frontend dev server
cd my-plugin/frontend
npm run dev   # → http://localhost:5173

# Terminal 2: Plugin dev mode with proxy
osaurus tools dev com.acme.dashboard --web-proxy http://localhost:5173
```

When the proxy is active:

- Requests to `/plugins/com.acme.dashboard/app/*` are proxied to `http://localhost:5173/*`
- Requests to `/plugins/com.acme.dashboard/api/*` still hit the dylib
- Osaurus injects `window.__osaurus` context into the proxied HTML
- CORS headers are handled automatically

This gives you hot module replacement (HMR) and instant feedback during frontend development. The proxy configuration is stored in a `dev-proxy.json` file in the plugin directory.

---

## Permissions

### Permission Policies

Each tool can specify a `permission_policy`:

- `"ask"` (default) - Prompts user for approval before each execution
- `"auto"` - Executes automatically if all requirements are granted
- `"deny"` - Blocks execution entirely

Users can override these defaults per-tool via the Osaurus UI.

### System Permissions

Some tools require macOS system permissions that must be granted at the app level:

| Permission           | How to Grant                                             | Use Case                                          |
| -------------------- | -------------------------------------------------------- | ------------------------------------------------- |
| **Automation**       | System Settings → Privacy & Security → Automation        | AppleScript, controlling other apps               |
| **Accessibility**    | System Settings → Privacy & Security → Accessibility     | UI automation, input simulation, computer control |
| **Calendar**         | System Settings → Privacy & Security → Calendars         | Reading and creating calendar events directly     |
| **Contacts**         | System Settings → Privacy & Security → Contacts          | Searching contacts, reading contact info          |
| **Location**         | System Settings → Privacy & Security → Location Services | Accessing current location                        |
| **Maps**             | System Settings → Privacy & Security → Automation        | Controlling Maps app                              |
| **Notes**            | System Settings → Privacy & Security → Automation        | Reading and creating notes                        |
| **Reminders**        | System Settings → Privacy & Security → Reminders         | Reading and creating reminders                    |
| **Full Disk Access** | System Settings → Privacy & Security → Full Disk Access  | Accessing Messages, Safari data, other app data   |

**User Experience:**

- The Tools UI shows a warning badge on plugins/tools that need permissions
- Users see exactly which permissions are missing
- One-click buttons to grant permissions or open System Settings
- Settings → System Permissions shows all available permissions with status

**Runtime Behavior:**

- System permissions are checked before tool execution
- If missing, execution fails with a clear error message indicating which permissions are needed
- Users don't need to restart the app after granting permissions

## Code Signing

**Crucial:** macOS plugins (`.dylib`) must be code-signed with a valid **Developer ID Application** certificate. If they are not signed, macOS Gatekeeper will block them from loading when downloaded from the internet, and users will see an error.

To sign your plugin:

1.  Obtain a "Developer ID Application" certificate from the [Apple Developer](https://developer.apple.com) portal.
2.  Run the `codesign` tool on your `.dylib` before packaging:

```bash
codesign --force --options runtime --timestamp --sign "Developer ID Application: Your Name (TEAMID)" libMyPlugin.dylib
```

> **Note:** For local development/testing, ad-hoc signing (or no signing) might work if you haven't quarantined the file, but for distribution, a real certificate is required.

## Distribution via Central Registry

Osaurus uses a single, git-backed central plugin index maintained by the Osaurus team.

1. Package your plugin with the correct naming convention: `<plugin_id>-<version>.zip`
2. Publish release artifacts (.zip containing your `.dylib`) on GitHub Releases.
3. Generate a SHA256 checksum of the zip.
4. Sign the zip with Minisign (recommended).
5. Submit a PR to the central index repo adding `plugins/<your.plugin.id>.json` with your metadata.

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

## Artifact Signing (Minisign)

This step ensures the integrity and authenticity of the distributed ZIP file. It is distinct from the **Code Signing** step above (which authenticates the binary for macOS).

- Install Minisign: `brew install minisign`
- Generate a key pair (once): `minisign -G -p minisign.pub -s minisign.key`
- Sign your zip: `minisign -S -s minisign.key -m echo-macos-arm64.zip -x echo-macos-arm64.zip.minisig`
- Publish:
  - The public key (contents of `minisign.pub`) in your spec under `public_keys.minisign`
  - The signature (contents of `.minisig`) in the spec under `versions[].artifacts[].minisign.signature`

## Rust Authors

Create a `cdylib` exposing `osaurus_plugin_entry` (v1) or `osaurus_plugin_entry_v2` (v2) that returns the generic function table. For v1, implement `init`, `destroy`, `get_manifest`, `invoke`, and `free_string`. For v2, also set `version = 2` and optionally implement `handle_route` and `on_config_changed`. Store the `osr_host_api` pointer passed to the v2 entry point for access to config, database, and logging callbacks.
