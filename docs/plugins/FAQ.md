# Plugin FAQ

Quick answers to common questions. For deeper guides see [README.md](README.md).

## General

### Do old plugins still work?

Yes. The Plugin ABI is **frozen** — the `osr_host_api` struct layout never changes; new versions only append optional slots at the end. Plugins compiled against v1 (`osaurus_plugin_entry`, no host API access) through v4 continue to load against the current v5 host unchanged. Two slots (`dispatch_clarify`, `dispatch_add_issue`) are reserved and return `not_supported` envelopes for backwards compat.

You only need to rebuild to pick up new callbacks (`complete_cancel` in v3, `get_active_agent_id` in v4, `log_structured` in v5). There is no forced migration. See [ABI_VERSIONS.md](ABI_VERSIONS.md) for the per-version evolution and the `host->version >= N` defensive-check pattern.

### What's the difference between native plugins and sandbox plugins?

| | **Native plugin** | **Sandbox plugin** |
|---|---|---|
| Format | macOS dylib (`.dylib`) | JSON recipe (`plugin.json`) |
| Runtime | In-process C ABI | Linux container subprocess |
| Host API | Full access (inference, storage, HTTP, etc.) | Tool execution via shell commands |
| Best for | Tools, routes, web UIs, deep integration | Shell-based tools that need package isolation |
| Distribution | Marketplace + sideload | JSON in agent workspace |

This guide is exclusively about native plugins. For sandbox recipes see [../SANDBOX.md](../SANDBOX.md).

### What language can I write plugins in?

Any language that produces a macOS dynamic library and exports the C ABI. Officially supported scaffolds:

- **Swift** — `osaurus tools create my-plugin`
- **Rust** — `osaurus tools create my-plugin --language rust`

Zig, C, C++, and Go (via `cgo`) all work. The `osr_host_api` struct is plain C.

## Lifecycle

### How do I reload a plugin during development?

`osaurus tools dev` watches your sources and reloads on save. To trigger a reload manually from anywhere:

```bash
osaurus tools reload
```

Or send the distributed notification yourself:

```bash
osascript -e 'tell application "System Events" to do shell script "echo"' \
  ; defaults write com.dinoki.osaurus _ _ \
  ; killall -USR1 Osaurus 2>/dev/null
```

(The CLI subcommand is the supported path.)

### Does a hot reload preserve plugin state?

In-memory state is lost — your `init` runs again. SQLite state (`host->db_*`) and Keychain state (`host->config_*`) survive across reloads and app restarts. Use them for anything you need to persist.

### Can I have multiple plugins talking to each other?

Not directly. Plugins are isolated by design. Cross-plugin coordination should go through:

- The user (one plugin produces an artifact, another consumes it via `host->file_read`)
- The agent's tool calls (one plugin's tool result feeds into another tool call)
- HTTP routes (one plugin calls another's route via `host->http_request`)

## Manifest

### What's the difference between `description`, `instructions`, and tool `description`?

- **`description`** (top level) — shown to the user in the marketplace and plugin detail page
- **`instructions`** — appended to the system prompt for inference calls **initiated by the plugin itself** (via `host->complete` etc.). Use sparingly; this isn't part of the user's chat system prompt.
- **Tool `description`** — fed to the model when it picks tools. Be specific: "Fetch authenticated user's GitHub profile" beats "Get user data".

### Why does my plugin need a `min_osaurus`?

It's optional but recommended once your plugin uses host APIs added after a specific Osaurus version. The host doesn't currently enforce it at load time, but the marketplace surfaces it to users so they know whether to upgrade.

### Can I declare runtime tools dynamically?

Not yet. The manifest is read once at load time. If you need to expose tools that depend on user config, you can:

- Declare a generic tool with a `mode` parameter and dispatch internally
- Trigger a reload after config changes via `host->log` and the `osaurus tools reload` workflow (won't work in installed builds without restarting)

A formal "dynamic tools" API may land in a future v4 surface.

## Routes and Web UI

### Why does my web UI 401 when I open the URL in Safari?

Browsers can't add the `X-Osaurus-Agent-Id` header to top-level navigation. Use the **Open Web App** button in the Osaurus plugin detail page — it appends `?osr_agent=<agent_uuid>` automatically and the injected `window.__osaurus.fetch` carries the header forward. See [DEBUGGING.md#why-does-my-web-ui-401](DEBUGGING.md#why-does-my-web-ui-401).

### Does the dev proxy work with Vite HMR?

Yes. The proxy now forwards the original method, headers, and body — POSTs, HMR pings, fetch calls all flow through. Set `~/Library/Application Support/Osaurus/Config/dev-proxy.json` per [ROUTES_AND_WEB.md#dev-proxy](ROUTES_AND_WEB.md#dev-proxy).

### Are paths case-sensitive?

The route's path is compared case-sensitively. The HTTP method is case-insensitive (`GET` and `get` both match a route declared with `["GET"]`).

### Can I have a route at `/health` AND a web mount at `/`?

No — the web mount would shadow the route, and the manifest validation will reject this at load time with a clear error. Move the route outside the mount, or change the mount to `/ui` (or similar).

## Inference

### How do I cancel a streaming completion?

Pass a `stream_id` UUID in the `complete_stream` request body, then call `complete_cancel(stream_id)` from anywhere — the `on_chunk` callback, a separate worker, etc. The host emits a final chunk with `finish_reason: "cancelled"` and the `complete_stream` return envelope is `{"error": "cancelled", "partial_content": "...", ...}`. The cancel call is non-blocking — the streaming task observes the flag between deltas and unwinds. See [HOST_API.md `complete_cancel`](HOST_API.md#complete_cancelstream_id---void) for the full envelope shape.

### Why does my streaming response not include `usage`?

It should. Look for the `delta.usage` chunk near the end of the stream — it carries `completion_tokens`, `tokens_per_second`, and `unclosed_reasoning`. The aggregated return value also includes a top-level `usage` block. If you're not seeing it, check that your chunk filter isn't dropping the `usage` field as an unknown delta key.

### What happens if I exceed `max_iterations` in a streaming completion?

You get `finish_reason: "max_iterations"` on the terminator chunk and a structured `{"error": "max_iterations_reached", "partial_content": "...", ...}` envelope as the aggregated return value. Both stream and non-stream paths now surface this consistently.

## Dispatch

### How does the `dispatch_interrupt` `message` argument work?

When `message` is non-empty, the trimmed text is appended to the running task's chat session as a `user`-role turn before the stream is cancelled. The model picks it up on the next completion round — when the user reopens the chat window or when the plugin dispatches a follow-up against the same `session_id`. Pass an empty string or `NULL` to soft-stop without injecting anything. See [HOST_API.md](HOST_API.md#dispatch_interrupttask_id-message---void) for the contract.

### How do I share a session across multiple `dispatch` calls?

Pass the same `session_id` (UUID) in every dispatch request. The host reattaches to the existing chat session if one matches.

### What's the dispatch rate limit?

10 dispatches per minute per `(plugin, agent)` pair. Two plugins running for the same agent each get their own 10/min budget. If you need more, batch into a single richer prompt or stagger the calls.

## Errors and observability

### How do I see what my plugin is doing?

Open Insights → Plugin Activity. Every host API call is logged with method, path, status, duration, and request/response bodies (truncated). Add `host->log(level, message)` calls inside your tools to surface plugin-internal state.

### Why am I seeing `context_unavailable` errors?

Your plugin called a host API from a thread Osaurus didn't register. See [DEBUGGING.md#context_unavailable-errors](DEBUGGING.md#context_unavailable-errors).

### Why am I seeing one-shot warnings in Console?

The host emits warning logs for ABI-level patterns that work but indicate a likely bug:

- `complete_stream` called with a NULL `on_chunk` callback
- `dispatch_cancel` / `send_draft` / `dispatch_interrupt` called with an invalid or unowned task ID
- Host call resolved via the racy `lastDispatchedPluginId` fallback

Each is logged once per plugin per process. Search Console.app for `[PluginHostAPI]` to find them.

## Distribution

### Does my plugin need to be code-signed?

For release builds, yes. The host verifies signatures and refuses to load unsigned plugins. DEBUG builds (running through `osaurus tools dev`) skip signature verification.

### Can I host my own plugin registry?

Today plugins are distributed via the [osaurus-tools](https://github.com/osaurus-ai/osaurus-tools) registry. Sideloading from arbitrary directories works for development and private distributions but is not user-facing in the marketplace.

### How do I update an installed plugin?

Bump the version in your manifest, tag a new release, and update the registry. Users get an upgrade prompt. Their `.user_consent` carries forward unless your `requirements` widened.

## See also

- [README.md](README.md) — full doc index
- [QUICKSTART.md](QUICKSTART.md) — first plugin in 5 minutes
- [HOST_API.md](HOST_API.md) — every callback in detail
