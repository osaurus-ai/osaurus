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

## ABI Overview

The header is available at:
`Packages/OsaurusCore/Tools/PluginABI/osaurus_plugin.h`

Key points:

- **Entry Point**: Plugin exposes a single symbol `osaurus_plugin_entry` returning a pointer to `osr_plugin_api`.
- **Lifecycle**:
  - `init()`: Called once on load. Returns an opaque `context` pointer.
  - `destroy(ctx)`: Called on unload.
  - `get_manifest(ctx)`: Returns a JSON string describing capabilities.
  - `invoke(ctx, type, id, payload)`: Generic invocation function.
  - `free_string(s)`: Called by host to free strings returned by the plugin.

### Manifest Format

The manifest JSON returned by `get_manifest` describes the plugin's capabilities. This is the source of truth for plugin metadata at runtime:

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

Create a `cdylib` exposing `osaurus_plugin_entry` that returns the generic function table. Implement `init`, `destroy`, `get_manifest`, and `invoke`.
