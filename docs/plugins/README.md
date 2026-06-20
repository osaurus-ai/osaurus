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
| **Test my plugin (`tools dev` loop, unit tests with `OsaurusPluginTestKit`)** | [TESTING.md](TESTING.md) |
| **Debug why my plugin won't load** | [DEBUGGING.md](DEBUGGING.md) |
| **See what changed in each ABI version** | [ABI_VERSIONS.md](ABI_VERSIONS.md) |
| **Find an answer to a quick question** | [FAQ.md](FAQ.md) |

## What you get from the host

Plugins target the **v6 host API surface** (current). Callbacks span:

- **Config** — read/write per-plugin secrets backed by Keychain (`config_get`, `config_set`, `config_delete`)
- **Storage** — per-plugin SQLite database (plaintext by default / FileVault-protected, or SQLCipher when the user opts in; 100 MiB default cap), `db_exec` / `db_query`
- **Logging** — `log` plus structured `log_structured` (v5) for searchable JSON fields in Insights
- **Inference** — synchronous and streaming chat completion (`complete`, `complete_stream`, `complete_cancel`) plus embeddings (`embed`), against the same models the main chat uses
- **Dispatch** — fire-and-forget background tasks (`dispatch`, `task_status`, `dispatch_cancel`, `dispatch_interrupt`, `send_draft`, `list_active_tasks`)
- **HTTP** — outbound requests with SSRF protection and a 60 req/min per-(plugin, agent) cap
- **File I/O** — read shared artifacts the user has explicitly provided
- **Agent context** — `get_active_agent_id` (v4) for per-agent state keying
- **Memory** — `host->free_string` (v6) to release strings the host returned, replacing the previously ambiguous "free with the plugin's `free_string`" path

Older plugins compiled against v1–v5 keep loading; the struct layout is frozen and v6 only appends one new optional slot. See [ABI_VERSIONS.md](ABI_VERSIONS.md) for the per-version evolution and the defensive `host->version >= N` check pattern.

The full reference for each callback lives in [HOST_API.md](HOST_API.md).

## What plugins look like at a glance

A plugin is a single `.dylib` that exports one symbol:

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

## Repository

The plugin registry lives at [github.com/osaurus-ai/osaurus-tools](https://github.com/osaurus-ai/osaurus-tools). Approved plugins are mirrored to the in-app marketplace. See [PACKAGING.md](PACKAGING.md) to publish.

## Quick links

- C ABI header: `Packages/OsaurusCore/Tools/PluginABI/osaurus_plugin.h`
- Tool result envelope contract: [../TOOL_CONTRACT.md](../TOOL_CONTRACT.md)
- Storage layout: [../STORAGE.md](../STORAGE.md)
