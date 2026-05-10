# Host API Reference

Reference for the v3 host API. Every callback your plugin can invoke is listed here, grouped by category. The canonical C declarations live in `Packages/OsaurusCore/Tools/PluginABI/osaurus_plugin.h`.

## Conventions

- **Most callbacks return JSON strings** with the structured envelope `{"error": "<code>", "message": "..."}` on error. The exceptions are `config_get` (returns `NULL` for missing key) and the void-returning callbacks (`config_set`, `config_delete`, `log`, `dispatch_cancel`, `send_draft`, `dispatch_interrupt`, `dispatch_clarify`, `complete_cancel`).
- **Memory ownership**: strings returned by host callbacks are heap-allocated. The plugin must release them with the same `free_string` callback the plugin provides to the host.
- **Threading**: callbacks are safe to call from any thread that carries the plugin context. Prefer the call frame Osaurus invoked you on (`invoke`, `handle_route`, `on_*`).
- **`host->version`** advertises the highest documented surface the host implements. Read it as a forward-compatible monotonic field.

## Categories

- [Config (Keychain-backed secrets)](#config)
- [Storage (per-plugin SQLite)](#storage)
- [Logging](#logging)
- [Inference](#inference)
- [Dispatch (background tasks)](#dispatch)
- [HTTP](#http)
- [File I/O](#file-io)
- [Reserved slots](#reserved-slots)

---

## Config

Per-plugin secrets, scoped by `(plugin_id, agent_id)` and stored in the macOS Keychain.

### `config_get(key) -> char*`

Returns the stored value or **NULL** if the key is missing. Free the returned string with the plugin's `free_string`.

```c
const char* api_key = host->config_get("api_key");
if (!api_key) {
    // missing — surface a setup hint to the user
} else {
    // use it
    plugin_free_string(api_key);
}
```

### `config_set(key, value) -> void`

Stores or overwrites a secret. **Does not** echo the change back to the calling plugin via `on_config_changed` — the plugin already knows what it just wrote, and echoing would create a feedback loop for plugins that mutate state inside their config handler. UI-driven changes from the host (Save / Disconnect, tunnel up/down) DO call `on_config_changed`.

Values larger than 1 MiB are silently rejected with a one-shot warning (the keychain is for credentials, not blob storage; use `db_exec` / `db_query` for larger payloads).

### `config_delete(key) -> void`

Removes a secret. Like `config_set`, the calling plugin does **not** receive an `on_config_changed` echo for its own delete. UI-driven deletes do.

### Cleared values: `""` vs deleted

Empty string `""` is a real value, distinct from a delete. Use `config_delete` to remove a key entirely. Host-side pushes that signal a transition (e.g. `tunnel_url` going down) deliver `""` to `on_config_changed`; treat that as "no value right now" rather than "no value ever stored."

### `on_config_changed(key, value) -> void` threading

The host serializes invocations of `on_config_changed` per plugin: two callbacks for the same plugin will never run in parallel, even when the host fans out per-agent notifications back-to-back at launch. State touched only from this callback can stay lock-free; state shared with `invoke` / `handle_route` still needs its own synchronization (those paths run concurrently).

---

## Storage

Per-plugin SQLite database, encrypted with SQLCipher and lazy-opened on first use. `ATTACH`, `DETACH`, and `LOAD_EXTENSION` are blocked at the SQL guard.

### `db_exec(sql, params_json) -> char*`

Executes a non-SELECT statement. `params_json` may be a JSON array `[v1, v2, ...]` for `?` placeholders or a JSON object `{":name": v1, ...}` for named placeholders. Returns `{"changes": <int>, "last_insert_rowid": <int>}` on success, error envelope on failure.

```c
const char* result = host->db_exec(
    "INSERT INTO notes (title, body) VALUES (?, ?)",
    "[\"My note\", \"Hello world\"]"
);
```

### `db_query(sql, params_json) -> char*`

Executes a SELECT and returns `{"rows": [{...}, ...], "columns": [...]}`.

---

## Logging

### `log(level, message) -> void`

Levels: `0=trace`, `1=debug`, `2=info`, `3=warn`, `4=error`. Messages flow to both the macOS unified log and Osaurus Insights.

```c
host->log(1, "Plugin started");
```

---

## Inference

Synchronous and streaming chat completion plus embeddings. Routed through the same inference layer the main chat uses, with full agent context (system prompt, tools, execution mode).

**Agent scoping (security boundary).** Every inference call (`complete`, `complete_stream`, `embed`) and every `dispatch` automatically inherits the agent that invoked the plugin — set by the host on `handle_route`, `invoke`, `on_config_changed`, and `on_task_event`. Plugins do **not** pass `agent_address` or `agent_id`; if either is present in the request body the host **ignores** it and logs a one-shot warning per `(plugin, op)`. A plugin called from agent A can never run inference or spawn dispatches in agent B's context. Background work the plugin spawned itself (no invoke / route / event frame above it) resolves to the built-in default agent and is also logged once. See the matching note on `dispatch` below.

**Concurrency cap**: each plugin can have at most 2 inference calls in flight at once. Bursts above this fail fast with `{"error": "plugin_busy"}` so a misbehaving plugin can't starve host worker threads.

### `complete(request_json) -> char*`

Synchronous chat completion. `request_json` is OpenAI-compatible:

```json
{
  "model": "local",
  "messages": [
    {"role": "system", "content": "You are concise."},
    {"role": "user", "content": "Hello"}
  ],
  "max_tokens": 256,
  "temperature": 0.7,
  "tools": [...],
  "session_id": "<optional UUID for transcript continuity>"
}
```

Model resolution: specific name, `null`/`""` for default, `"local"` for MLX, `"foundation"` for Apple Foundation Model.

Returns full OpenAI response with `choices[0].message.content` and `usage`. On exhaustion of the tool-iteration limit returns `{"error": "max_iterations_reached", "partial_content": "..."}`.

### `complete_stream(request_json, on_chunk, user_data) -> char*`

Streaming completion. `on_chunk` is called for each delta with `chunk_json` like:

```json
{"id": "...", "choices": [{"delta": {"content": "Hello"}}]}
```

Special chunks:

- Reasoning: `delta.reasoning_content` for models that emit reasoning
- Tool calls: `delta.tool_calls` with `finish_reason: "tool_calls"`
- Usage: `delta.usage = {completion_tokens, tokens_per_second, unclosed_reasoning}` (final chunk before terminator)
- Terminator: `finish_reason ∈ {"stop", "length", "tool_calls", "max_iterations", "cancelled"}`

The aggregated final response is returned as the function's return value (same shape as `complete`'s return) plus `usage` if the model surfaced stats.

If you pass a `NULL` `on_chunk` callback the host logs a one-shot warning and discards chunks; the aggregated return value still flows.

#### Cancellation: `stream_id` + `complete_cancel`

To support mid-stream cancellation, generate a UUID on the plugin side and pass it as `stream_id` in the request body:

```json
{
  "model": "local",
  "stream_id": "<uuid you generate>",
  "messages": [...]
}
```

From any thread (including the `on_chunk` callback or a separate worker), call `complete_cancel(stream_id)` to abort. The host emits a final chunk with `finish_reason: "cancelled"` and the function returns:

```json
{
  "error": "cancelled",
  "message": "Streaming completion cancelled by plugin via complete_cancel.",
  "partial_content": "...",
  "stream_id": "<the same uuid>",
  "usage": {...},
  "tool_calls_executed": [...],
  "shared_artifacts": [...]
}
```

`complete_cancel` is non-blocking — it only flips the cancellation flag. The streaming task observes it between deltas, so cancellation latency is bounded by the model's per-token decode time. Callers from `on_chunk` are safe (no deadlock).

### `complete_cancel(stream_id) -> void`

Cancels an in-flight `complete_stream` call. `stream_id` is the same UUID the plugin passed in the `complete_stream` request body. No-ops silently if no active stream matches the id (common case: the stream finished naturally before the cancel reached the host). The host logs the call to Insights for correlation.

### `embed(request_json) -> char*`

```json
{"model": "local", "input": "text or array"}
```

Returns `{"data": [{"embedding": [...], "index": 0}], "usage": {...}}`.

### `list_models() -> char*`

Returns `{"models": [{"id", "name", "provider", "type", "context_window", "dimensions", "capabilities"}, ...]}`.

---

## Dispatch

Fire-and-forget background tasks. Each task runs an agentic chat with full Osaurus tooling.

**Rate limit**: 10 dispatches per minute per `(plugin, agent)` pair. Two plugins running for the same agent each get their own 10/min budget — this is intentional to prevent cross-plugin starvation.

### `dispatch(request_json) -> char*`

Schema:

```json
{
  "prompt": "Required. The initial user message.",
  "mode": "optional execution mode",
  "title": "Optional title shown in the task toast",
  "id": "Optional caller-supplied UUID",
  "folder_bookmark": "Optional base64-encoded security-scoped bookmark",
  "session_id": "Optional UUID. Reattach to an existing session"
}
```

**Agent scoping.** The dispatched task always runs under the agent that invoked the plugin (see the "Agent scoping" note in the [Inference](#inference) section). `agent_address` / `agent_id` are not part of the schema; if either is present they are ignored and a one-shot warning is logged. `session_id` reattach is naturally agent-scoped — a session belonging to a different agent silently misses and a fresh task is created.

Returns `{"id": "<uuid>", "status": "running"}` immediately or an error envelope. Non-blocking.

### `task_status(task_id) -> char*`

Returns the current state. Statuses: `running`, `completed`, `failed`, `cancelled`. Includes `current_step`, `activity` feed, `output` (last assistant content), and `summary` on completion.

Returns `{"error": "not_found"}` if the task was not dispatched by the calling plugin.

### `dispatch_cancel(task_id) -> void`

Cancels a running task. No-ops silently if `task_id` doesn't belong to the plugin (a one-shot warning is logged on first invalid call).

### `list_active_tasks() -> char*`

Returns `{"tasks": [<task_status objects>]}` filtered to tasks dispatched by the calling plugin.

### `send_draft(task_id, draft_json) -> void`

Stores a draft on the task and emits a `draft` event. `draft_json` should have `text` (required) and optional `parse_mode`. Useful for live-updating UI panels driven by long-running tasks.

### `dispatch_interrupt(task_id, message) -> void`

Soft-stops a running task by cancelling its current stream.

When `message` is non-empty, the trimmed content is appended to the dispatched chat session as a `user`-role turn **before** the stream is cancelled. The model picks the message up on the next completion round — when the user reopens the chat window, when the plugin dispatches a follow-up against the same `session_id`, or when the session is otherwise resumed. Pass `NULL` or an empty string to soft-stop without injecting anything.

This lets a plugin redirect a long-running task ("stop and instead do X") without losing conversation context.

No-ops silently if `task_id` is invalid or does not belong to the calling plugin (a one-shot warning is logged on first invalid call).

---

## HTTP

### `http_request(request_json) -> char*`

Outbound HTTP with built-in SSRF protection. Loopback, link-local, RFC1918, and 169.254 ranges are blocked.

Schema:

```json
{
  "method": "GET",
  "url": "https://api.example.com/endpoint",
  "headers": {"Authorization": "Bearer ..."},
  "body": "optional",
  "body_encoding": "utf8",
  "timeout_ms": 30000,
  "follow_redirects": true
}
```

Returns:

```json
{
  "status": 200,
  "headers": {...},
  "body": "...",
  "body_encoding": "utf8",
  "elapsed_ms": 142
}
```

For binary responses, `body_encoding` will be `"base64"`.

---

## File I/O

### `file_read(request_json) -> char*`

Read a file from the artifacts directory (`~/.osaurus/artifacts/`). Hard-scoped to that prefix. 50 MB cap.

```json
{"path": "/Users/.../artifacts/abc/file.png"}
```

Returns `{"data": "<base64>", "size": <int>, "mime_type": "..."}` or an error envelope.

---

## Reserved slots

Two slots are reserved for ABI compatibility. The trampolines return structured `not_supported` envelopes (or void for the void-typed slot) and log an HTTP 410 in Insights. New plugins should not invoke them.

### `dispatch_clarify(task_id, response) -> void` *(RESERVED)*

Clarification is now handled inline via the `clarify` agent intercept. There is no out-of-band channel from the plugin into the agent's question.

### `dispatch_add_issue(task_id, issue_json) -> char*` *(RESERVED)*

The issue tracker was retired. Call `dispatch` to start a fresh task instead.

---

## Error envelope reference

Error codes returned by host callbacks:

| Code | Meaning |
|---|---|
| `invalid_request` | Malformed input JSON |
| `invalid_task_id` | UUID parse failure |
| `unauthorized` | Missing or invalid auth |
| `forbidden` | Resource exists but plugin lacks access |
| `access_denied` | Path outside the artifacts allow-list, etc. |
| `not_found` | Task / record / file does not exist (or is not owned by the calling plugin) |
| `rate_limit_exceeded` | Dispatch rate limit (10/min per plugin/agent) hit |
| `plugin_busy` | Per-plugin inference inflight cap hit |
| `task_limit_reached` | Global concurrent task ceiling hit |
| `not_supported` | Reserved slot called, or feature retired |
| `context_unavailable` | Host call from a thread with no resolvable plugin context |
| `max_iterations_reached` | Agentic completion exhausted iteration limit |
| `cancelled` | Streaming completion was cancelled via `complete_cancel` |
| `serialization_error` | Failed to serialize the response payload |
| `inference_error` | Underlying inference layer threw |
| `file_too_large` | File exceeds the 50 MB cap |

Plugins should branch on the `error` code when present rather than the message.

---

## See also

- [AUTHORING.md](AUTHORING.md) — overall mental model
- [ROUTES_AND_WEB.md](ROUTES_AND_WEB.md) — HTTP routes and web UIs
- [DEBUGGING.md](DEBUGGING.md) — when callbacks misbehave
- [`Packages/OsaurusCore/Tools/PluginABI/osaurus_plugin.h`](../../Packages/OsaurusCore/Tools/PluginABI/osaurus_plugin.h) — canonical C declarations
