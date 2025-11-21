# Osaurus Plugin Authoring (v1)

This document describes how to build external tools (plugins) for Osaurus using the C ABI. Plugins are distributed as `.dylib` plus a `manifest.json` in a zip.

## TL;DR (Swift)

1. Scaffold a Swift plugin:

```bash
osaurus tools create MyPlugin --language swift
```

2. Build and package:

```bash
cd MyPlugin
swift build -c release
# Copy the built dylib next to manifest.json (or rename to match manifest.dylib)
cp .build/release/libMyPlugin.dylib ./libMyPlugin.dylib
osaurus tools package
```

3. Install:

```bash
osaurus tools install ./MyPlugin.zip
```

The plugin will be unpacked into:
`~/Library/Application Support/com.dinoki.osaurus/Tools/<MyPlugin>/`

## ABI Overview

Header is shipped at:
`Packages/OsaurusCore/Tools/PluginABI/osaurus_plugin_v1.h`

Key points:

- JSON-in/JSON-out boundary (UTF-8 strings), no Swift symbols.
- Plugin exposes a single entry symbol `osaurus_plugin_entry_v1`.
- Host calls `tool_count`, `get_tool_spec`, and `execute`.
- Plugin returns malloc'ed strings; host frees via `free_string`.

Tool spec fields:

- `name`: unique id
- `description`: human readable
- `parameters_json`: JSON Schema for arguments
- `requirements_json`: JSON array like `["permission:web", "permission:folder"]`
- `permission_policy`: `"auto" | "ask" | "deny"`

## Permissions (v1)

- Policy defaults to `"ask"` unless configured by the user.
- `"deny"` blocks execution.
- `"ask"` requires approval (v1 returns a friendly error).
- `"auto"` executes if required grants are present; otherwise returns an error.

Users can manage enablement and policies via the Osaurus UI/config. Plugins should declare only the minimum requirements they need.

If downloaded from the web, clear quarantine:

```bash
xattr -dr com.apple.quarantine "/path/to/libYour.dylib"
```

Reload tools: `osaurus tools reload`

Notes

- Ad‑hoc signatures may still be rejected under Hardened Runtime; prefer a real Apple signing identity.
- If you install via `osaurus tools install <zip>`, the app will auto‑rescan. You can also press Reload in Tools UI.

## Rust Authors

Create a `cdylib` exposing `osaurus_plugin_entry_v1` and return the v1 function table. See the Swift scaffold for the struct layout to mirror.
