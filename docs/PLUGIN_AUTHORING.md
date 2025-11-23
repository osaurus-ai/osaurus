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
# Install the local directory directly (must contain manifest.json)
osaurus tools install .
```

The plugin will be unpacked into:
`~/Library/Application Support/com.dinoki.osaurus/Tools/<plugin_id>/<version>/`

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
- If you install via `osaurus tools install <zip>` or `osaurus tools install .`, the app will auto‑rescan. You can also press Reload in Tools UI.
- `install` will always override the installed version with the one provided.

## Rust Authors

Create a `cdylib` exposing `osaurus_plugin_entry_v1` and return the v1 function table. See the Swift scaffold for the struct layout to mirror.

## Distribution via Central Registry

Osaurus uses a single, git-backed central plugin index maintained by the Osaurus team. Users cannot add custom taps.

1. Ensure your `manifest.json` contains publishing metadata (`homepage`, `license`, `authors`).
2. Publish release artifacts (.zip containing your `.dylib` and `manifest.json`) on GitHub Releases (or any HTTPS URL).
3. Generate a SHA256 checksum of the zip.
4. Sign the zip with Minisign (recommended).
5. Submit a PR to the central index repo adding `plugins/<your.plugin.id>.json` with your metadata.

Example registry entry (abbreviated):

```json
{
  "plugin_id": "com.acme.echo",
  "name": "Echo Tools",
  "homepage": "https://github.com/acme/echo",
  "license": "MIT",
  "public_keys": { "minisign": "RWQ..." },
  "abi": { "min": 2, "max": 2 },
  "versions": [
    {
      "version": "1.2.0",
      "artifacts": [
        {
          "os": "macos",
          "arch": "arm64",
          "url": "https://github.com/acme/echo/releases/download/v1.2.0/echo-macos-arm64.zip",
          "sha256": "<sha256-of-zip>",
          "minisign": {
            "signature": "untrusted comment: signature...\\nRWQ...",
            "key_id": "acme-echo"
          }
        }
      ]
    }
  ]
}
```

## Minisign Signing

- Install Minisign: `brew install minisign`
- Generate a key pair (once): `minisign -G -p minisign.pub -s minisign.key`
- Sign your zip: `minisign -S -s minisign.key -m echo-macos-arm64.zip -x echo-macos-arm64.zip.minisig`
- Publish:
  - The public key (contents of `minisign.pub`) in your spec under `public_keys.minisign`
  - The signature (contents of `.minisig`) in the spec under `versions[].artifacts[].minisign.signature`

Osaurus verifies the SHA256 and Minisign signature during install, and rechecks the on-disk `.dylib` hash at load time.

## ABI v2 Manifest (optional but recommended)

Plugins may implement `osaurus_plugin_entry_v2()` and provide `get_plugin_manifest_json()` returning:

```json
{ "plugin_id": "com.acme.echo", "version": "1.2.0", "abi": 2 }
```

The host will cross-check this against the installed directory layout to detect mismatches.

## Versioning and Rollbacks

- Publish new versions by adding entries to your spec’s `versions[]`. Use semantic versioning.
- Users can upgrade with `osaurus plugins upgrade` and rollback with `osaurus plugins rollback <plugin_id>`.
