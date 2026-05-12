# Debugging Plugins

Decision trees and tactics for fault-finding when something isn't working.

## Where to look first

| Symptom | Best signal |
|---|---|
| Plugin not appearing | `osaurus tools list` and Console.app log messages prefixed `[Osaurus]` |
| Plugin loaded but tool not callable | Insights → Plugin Activity, then chat transcripts |
| Tool runs but returns wrong data | `host->log` from inside your tool plus Insights body capture |
| Web UI shows 401 | [Why does my web UI 401?](#why-does-my-web-ui-401) |
| Plugin crashes during init | Console.app for `[Plugin:<id>]` and `[Osaurus]` lines |
| Hot reload not picking up changes | Make sure `osaurus tools dev` is running and shows a successful build |

Console.app filter to capture all plugin-related logs:

```
process:Osaurus AND (subsystem:com.dinoki.osaurus OR message:"[Plugin:")
```

## Plugin failed to load — decision tree

```mermaid
flowchart TD
    Start[Plugin fails to load] --> ConsoleCheck["Console.app: [Osaurus] log message"]
    ConsoleCheck -->|"dlopen failed"| Sig["Check codesign -vv MyPlugin.dylib"]
    ConsoleCheck -->|"Missing entry"| Symbols["Check exports with nm -gU MyPlugin.dylib | grep osaurus_plugin"]
    ConsoleCheck -->|"v2 entry returned null API"| InitCrash["Plugin's init returned NULL — check init code"]
    ConsoleCheck -->|"Plugin initialization failed"| InitCrash
    ConsoleCheck -->|"Failed to parse plugin manifest"| ManifestJSON["JSON-validate the get_manifest output"]
    ConsoleCheck -->|"declares route ... under web mount"| Mount["Move the route or change the web.mount in the manifest"]
    ConsoleCheck -->|"consent_required"| Consent["DEBUG builds: skipped. Release: open the plugin in app and grant consent"]
    Sig -->|"unsigned or invalid"| Resign["Re-sign with Developer ID Application certificate"]
    Symbols -->|"missing v2 symbol"| Export["Add @_cdecl(\"osaurus_plugin_entry_v2\") in Swift, or pub extern \"C\" fn osaurus_plugin_entry_v2 in Rust"]
```

### Common diagnostic commands

```bash
# What symbols does the dylib export?
nm -gU MyPlugin.dylib | grep osaurus_plugin

# Is it signed correctly?
codesign -vv MyPlugin.dylib

# What architecture?
file MyPlugin.dylib

# What does it link against?
otool -L MyPlugin.dylib
```

## Why does my web UI 401?

The most common cause is opening the plugin's URL directly in a browser without the `X-Osaurus-Agent-Id` header. Browsers can't add custom headers on top-level navigation.

**Fix**:

- Use the **Open Web App** button inside the Osaurus plugin detail page. It appends `?osr_agent=<agent_uuid>` automatically.
- If you're scripting deep links, append the same query parameter.
- Inside your web UI, use `window.__osaurus.fetch(...)` instead of the global `fetch` — the helper attaches the agent header to every request.

If you're seeing 401 *after* the page has loaded, the injected helper might not be running. Check the page source for the `<script>window.__osaurus = {...}</script>` block. If it's absent, either:

- The response wasn't `text/html` (the helper is only injected into HTML)
- You bypassed `window.__osaurus.fetch` on a fetch call

## Tool not invoked

You think your tool should run but the model doesn't call it.

1. **Check the manifest** — does the tool actually appear in `osaurus tools list`?
2. **Check the description** — is it specific enough that the model knows when to use it? "Get user data" is vague; "Fetch the authenticated user's profile from the GitHub API" is better.
3. **Check the model** — small local models often don't tool-call well. Try `gpt-4o-mini` or a tool-calling-capable local model.
4. **Check for permission denial** — Insights logs `[Osaurus][Tool] permission denied: <name>` if the user denied a prior prompt. Reset in Settings → Tool Permissions.

## Tool runs but returns the wrong shape

Tool returns must match `ToolEnvelope` from [../TOOL_CONTRACT.md](../TOOL_CONTRACT.md):

```json
{"ok": true, "data": {...}, "summary": "..."}
```

Common issues:

- Forgetting `"ok"`: the host treats this as a plain string and shows it raw
- Returning a non-string from `invoke`: the C contract requires a JSON-encoded `const char*`
- Forgetting to `strdup` the result: the host calls your `free_string` on the returned pointer

## Hung handlers

If `handle_route` doesn't respond within 30 seconds the host returns 500 with `Plugin route handler timed out after 30s`. Check Insights for the timed-out request.

For long-running work, return 202 immediately and dispatch a background task via `host->dispatch`. The plugin can poll `task_status` from a separate route or surface the task id in the response.

## `context_unavailable` errors

If you see `{"error": "context_unavailable"}` from a host call, your plugin called a host API from a thread Osaurus never registered. Common causes:

- Spawning your own `DispatchQueue.global().async` and calling `host->complete` from inside without capturing the host pointer
- Calling host APIs from a callback fired by a third-party library on its own thread

**Fix**: capture the `host` pointer and the relevant inputs on the dispatching thread, do the heavy lifting on your own thread, then wrap host calls in something that hops back to a thread Osaurus knows about. The simplest pattern is to do all host work synchronously inside `invoke` / `handle_route` / `on_*`.

## `plugin_busy` errors

Each plugin is capped at 2 concurrent inference calls. If you're seeing this, you've fired three or more `complete` / `complete_stream` / `embed` calls in flight at once. Either serialize them or batch the work into a single `complete` request with a richer prompt.

## `dispatch_interrupt` not behaving as expected?

`dispatch_interrupt(task_id, message)` cancels the task's current stream. When `message` is non-empty (and not just whitespace), the trimmed content is appended to the underlying chat session as a `user`-role turn **before** the cancel — so the model picks it up on the next completion round (when the user reopens the chat window, when the plugin dispatches a follow-up against the same `session_id`, or when the session is otherwise resumed). Pass `NULL` or an empty string to soft-stop without injecting context.

If you're not seeing the injected message reach the model, confirm:

- The `task_id` actually belongs to your plugin (host silently no-ops + warns once otherwise).
- The task is still active (`task_status` should report `running` or `awaitingClarification` before the interrupt).
- The session is being resumed somewhere — the appended turn waits for the next completion round; it doesn't trigger one on its own.

See `osr_dispatch_interrupt_fn` in [HOST_API.md](HOST_API.md) and the example flow in [MESSAGING_PATTERN.md](MESSAGING_PATTERN.md) for the canonical usage.

## Streaming chunks dropped

If you're calling `complete_stream` with `on_chunk = NULL`, the host warns once per process and discards chunks. The aggregated return value still flows. If you actually want incremental updates, pass a callback.

If chunks reach your callback but you're missing usage stats, look for the `delta.usage` chunk near the end of the stream — it carries `completion_tokens` and `tokens_per_second`.

## Insights as your first stop

Open Insights → Plugin Activity. Every host API call your plugin makes is logged with:

- Method (e.g. `POST`)
- Path (e.g. `/host-api/chat/completions`)
- Status code (mapped from the response envelope's `error` code)
- Duration in ms
- Request and response bodies (truncated for size)

If a call doesn't appear, the trampoline never ran — check that the `host` pointer is non-NULL inside your plugin.

## Sandbox vs native plugins

Two systems share the word "plugin":

| | **Native plugin** (this guide) | **Sandbox plugin** |
|---|---|---|
| Distribution | dylib in `~/Library/.../Osaurus/Tools` | JSON recipe |
| Runtime | In-process C ABI | Linux container subprocess |
| Manifest | `get_manifest()` returns JSON | `plugin.json` file |
| Use cases | Tools, routes, web UIs, host API access | Shell-based tools that need package isolation |

If you wanted the JSON sandbox flavor, see [../SANDBOX.md](../SANDBOX.md). This guide is exclusively about native dylib plugins.

## See also

- [HOST_API.md](HOST_API.md) — what each callback does
- [TESTING.md](TESTING.md) — pre-flight checks
- [FAQ.md](FAQ.md)
