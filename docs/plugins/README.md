# Osaurus Plugin Authoring

Welcome. This is the entry point for everything related to building Osaurus plugins.

Plugins are macOS dynamic libraries (`.dylib`) that extend Osaurus with new tools, HTTP routes, web UIs, and background tasks. They run in-process with full access to a curated host API for inference, storage, secrets, networking, and dispatch.

## Pick your path

| I want to... | Read |
|---|---|
| **Get a Hello World plugin running in 5 minutes** | [QUICKSTART.md](QUICKSTART.md) |
| **Understand the manifest, lifecycle, and capabilities** | [AUTHORING.md](AUTHORING.md) |
| **Look up a specific host API callback** | [HOST_API.md](HOST_API.md) |
| **Build HTTP routes or a web UI for my plugin** | [ROUTES_AND_WEB.md](ROUTES_AND_WEB.md) |
| **Sign, package, and distribute my plugin** | [PACKAGING.md](PACKAGING.md) |
| **Debug why my plugin won't load** | [DEBUGGING.md](DEBUGGING.md) |
| **Test my plugin without installing it** | [TESTING.md](TESTING.md) |
| **Find an answer to a quick question** | [FAQ.md](FAQ.md) |

## What you get from the host

Plugins target the **v3 host API surface**, currently 18 documented callbacks across:

- **Config** — read/write per-plugin secrets backed by Keychain
- **Storage** — per-plugin SQLite database (encrypted at rest)
- **Logging** — structured logs that flow to Insights
- **Inference** — synchronous and streaming chat completion plus embeddings, against the same models the main chat uses
- **Dispatch** — fire-and-forget background tasks that run agentic workloads on behalf of the plugin
- **HTTP** — outbound requests with built-in SSRF protection
- **File I/O** — read shared artifacts the user has explicitly provided

The full reference for each callback lives in [HOST_API.md](HOST_API.md).

## What plugins look like at a glance

A v3 plugin is a single `.dylib` that exports one symbol:

```c
const osr_plugin_api* osaurus_plugin_entry_v2(const osr_host_api* host);
```

It returns a struct describing how to:

- Initialize and tear down the plugin (`init`, `destroy`)
- Describe its capabilities to Osaurus (`get_manifest`)
- Run tool calls from chat (`invoke`)
- Optionally handle HTTP routes (`handle_route`)
- Optionally react to config changes and task lifecycle events

The `host` pointer gives the plugin everything it needs to call back into Osaurus.

## Compatibility

The Plugin ABI is **frozen**. Plugins compiled against v1 (`osaurus_plugin_entry`) and v2 (`osaurus_plugin_entry_v2` against the v2 struct) continue to load unchanged. The current documented surface is **v3** — a strict superset of the v2 behavior with the same memory layout. New plugins target v3.

See [FAQ.md](FAQ.md#do-old-plugins-still-work) for migration notes.

## Repository

The plugin registry lives at [github.com/osaurus-ai/osaurus-tools](https://github.com/osaurus-ai/osaurus-tools). Approved plugins are mirrored to the in-app marketplace. See [PACKAGING.md](PACKAGING.md) to publish.

## Quick links

- C ABI header: `Packages/OsaurusCore/Tools/PluginABI/osaurus_plugin.h`
- Tool result envelope contract: [../TOOL_CONTRACT.md](../TOOL_CONTRACT.md)
- Storage layout: [../STORAGE.md](../STORAGE.md)
