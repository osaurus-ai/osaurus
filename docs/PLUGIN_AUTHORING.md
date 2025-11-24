# Osaurus Plugin Authoring

This document describes how to build external plugins for Osaurus using the Generic C ABI. Plugins are distributed as `.dylib` plus a `manifest.json` in a zip.

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
# Install the local directory directly (must contain manifest.json)
osaurus tools install .
```

The plugin will be unpacked into:
`~/Library/Application Support/com.dinoki.osaurus/Tools/<plugin_id>/<version>/`

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

### Manifest Format

The manifest JSON returned by `get_manifest` (and stored on disk as `manifest.json` for indexing) looks like this:

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
    // Future: "providers": [...], "agents": [...]
  }
}
```

### Invocation

When Osaurus needs to execute a capability, it calls `invoke`:

- `type`: e.g. `"tool"`
- `id`: e.g. `"echo_tool"`
- `payload`: JSON string arguments (e.g. `{"message": "hello"}`)

The plugin returns a JSON string response (allocated; host frees it).

## Permissions

- Policy defaults to `"ask"` unless configured by the user.
- `"deny"` blocks execution.
- `"ask"` requires approval (returns a friendly error if denied).
- `"auto"` executes if required grants are present.

Users can manage enablement and policies via the Osaurus UI/config.

## Distribution via Central Registry

Osaurus uses a single, git-backed central plugin index maintained by the Osaurus team.

1. Ensure your `manifest.json` contains publishing metadata (`homepage`, `license`, `authors`).
2. Publish release artifacts (.zip containing your `.dylib` and `manifest.json`) on GitHub Releases.
3. Generate a SHA256 checksum of the zip.
4. Sign the zip with Minisign (recommended).
5. Submit a PR to the central index repo adding `plugins/<your.plugin.id>.json` with your metadata.

## Minisign Signing

- Install Minisign: `brew install minisign`
- Generate a key pair (once): `minisign -G -p minisign.pub -s minisign.key`
- Sign your zip: `minisign -S -s minisign.key -m echo-macos-arm64.zip -x echo-macos-arm64.zip.minisig`
- Publish:
  - The public key (contents of `minisign.pub`) in your spec under `public_keys.minisign`
  - The signature (contents of `.minisig`) in the spec under `versions[].artifacts[].minisign.signature`

## Rust Authors

Create a `cdylib` exposing `osaurus_plugin_entry` that returns the generic function table. Implement `init`, `destroy`, `get_manifest`, and `invoke`.
