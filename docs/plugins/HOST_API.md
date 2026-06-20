# Host API Reference

Reference for the **v6 host API**. Every callback your plugin can invoke is listed here, grouped by category. The canonical C declarations live in `Packages/OsaurusCore/Tools/PluginABI/osaurus_plugin.h`. Per-version evolution and the defensive-check pattern for older hosts are in [ABI_VERSIONS.md](ABI_VERSIONS.md).

## Conventions

- **Most callbacks return JSON strings** with the structured envelope `{"error": "<code>", "message": "..."}` on error. The exceptions are `config_get` (returns `NULL` for missing key) and the void-returning callbacks (`config_set`, `config_delete`, `log`, `log_structured`, `free_string`, `dispatch_cancel`, `send_draft`, `dispatch_interrupt`, `dispatch_clarify`, `complete_cancel`).
- **Memory ownership.** Strings returned by host callbacks are heap-allocated by the host with `strdup`. Free them with **`host->free_string(ptr)`** (v6+) — that's the host-controlled pair for `strdup` and stays correct across future allocator changes. On older hosts (v5 and earlier) the slot is NULL; fall back to **`libc free(ptr)`**:
  ```c
  if (host->version >= 6 && host->free_string) {
      host->free_string(ptr);
  } else {
      free((void*)ptr);
  }
  ```
  **Do NOT** route host-allocated strings through the plugin's own `free_string` callback (the one on `osr_plugin_api`). That direction is reversed — it's for the host calling on plugin-allocated strings — and routing host pointers through it WILL corrupt the heap (`pointer being freed was not allocated`) if your `free_string` does anything besides plain `free()`.
- **Threading**: callbacks are safe to call from any thread that carries the plugin context. Prefer the call frame Osaurus invoked you on (`invoke`, `handle_route`, `on_*`).
- **`host->version`** advertises the highest documented surface the host implements. Read it as a forward-compatible monotonic field.

## Mirror Struct Audit

If you mirror `osr_host_api` in a non-C language (Swift, Rust, etc.), the field order must match the host's frozen layout **exactly**. A skipped or reordered slot makes every callback past that point dispatch to the wrong host function — the production crash signature is `host->free_string(ptr)` resolving to `host->log_structured` (or another adjacent slot), which then either silently misbehaves or aborts inside `libc` on a non-malloc pointer (`pointer being freed was not allocated`).

The canonical pin is [`PluginHostAPIStructLayoutTests`](../../Packages/OsaurusCore/Tests/Plugin/PluginHostAPIStructLayoutTests.swift); the offsets below MUST match what those tests assert. The most common foot-gun is jumping from a v4 mirror straight to v6 and skipping the v5 `log_structured` slot — this puts `free_string` at the v5 offset (`184`) instead of the v6 offset (`192`), with the corruption signature above.

### Frozen field order

| # | Field | Type | Added in |
|---|---|---|---|
| 0 | `version` | `uint32_t` | v1 |
| 1 | `config_get` | `char* (*)(const char*)` | v2 |
| 2 | `config_set` | `void (*)(const char*, const char*)` | v2 |
| 3 | `config_delete` | `void (*)(const char*)` | v2 |
| 4 | `db_exec` | `char* (*)(const char*, const char*)` | v2 |
| 5 | `db_query` | `char* (*)(const char*, const char*)` | v2 |
| 6 | `log` | `void (*)(int32_t, const char*)` | v2 |
| 7 | `dispatch` | `char* (*)(const char*)` | v2 |
| 8 | `task_status` | `char* (*)(const char*)` | v2 |
| 9 | `dispatch_cancel` | `void (*)(const char*)` | v2 |
| 10 | `dispatch_clarify` *(RESERVED)* | `void (*)(const char*, const char*)` | v2 |
| 11 | `complete` | `char* (*)(const char*)` | v2 |
| 12 | `complete_stream` | `char* (*)(const char*, on_chunk_t, void*)` | v2 |
| 13 | `embed` | `char* (*)(const char*)` | v2 |
| 14 | `list_models` | `char* (*)()` | v2 |
| 15 | `http_request` | `char* (*)(const char*)` | v2 |
| 16 | `file_read` | `char* (*)(const char*)` | v2 |
| 17 | `list_active_tasks` | `char* (*)()` | v2 |
| 18 | `send_draft` | `void (*)(const char*, const char*)` | v2 |
| 19 | `dispatch_interrupt` | `void (*)(const char*, const char*)` | v2 |
| 20 | `dispatch_add_issue` *(RESERVED)* | `char* (*)(const char*, const char*)` | v2 |
| 21 | `complete_cancel` | `void (*)(const char*)` | v3 |
| 22 | `get_active_agent_id` | `char* (*)()` | v4 |
| 23 | **`log_structured`** | `void (*)(int32_t, const char*, const char*)` | **v5** |
| 24 | `free_string` | `void (*)(const char*)` | v6 |

### Pinned offsets (Apple Silicon, default alignment)

The struct uses default C alignment — every pointer slot is 8 bytes after `version`'s 4-byte field plus its 4-byte trailing pad. The current locked offsets are:

| Slot | Offset (bytes) |
|---|---|
| `version` | 0 |
| `get_active_agent_id` | 176 |
| `log_structured` | 184 |
| `free_string` | 192 |
| (struct stride) | 200 |

If your mirror disagrees with any of these offsets, your `host->*` calls dispatch into adjacent slots and the host will look wedged or crash. Fix the mirror, don't add defensive checks downstream.

### Pre-flight ABI probe

The host pushes a synthetic `(__osaurus_abi_probe__, <fresh UUID>)` pair through every newly-loaded plugin's `on_config_changed` BEFORE any real config delivery, while a `.currently_loading` marker is on disk. Plugins that follow the documented pattern of resolving the active agent at the top of `on_config_changed` (i.e. `host->get_active_agent_id()` → `host->free_string(ptr)`) trigger a misalignment crash here, which:

- Quarantines the plugin on the next launch instead of crash-looping the host (`promoteStaleLoadingMarker` flips the marker into `.quarantine`).
- Surfaces a "Plugin failed to load" tab in the agent detail view with the structured error and a Retry button.

If you want to opt out of the probe (e.g. because your `on_config_changed` performs expensive work for every key), match the constant `"__osaurus_abi_probe__"` and early-return:

```c
void on_config_changed(osr_plugin_ctx_t* ctx, const char* key, const char* value) {
    if (strcmp(key, "__osaurus_abi_probe__") == 0) return;  // host's pre-flight handshake
    // ... your real handler ...
}
```

You give up the early misalignment detection if you do this, so prefer to leave the probe in place during development.

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

Returns the stored value or **NULL** if the key is missing. Free the returned string with `host->free_string` (v6+) or `libc free` on older hosts.

```c
const char* api_key = host->config_get("api_key");
if (!api_key) {
    // missing — surface a setup hint to the user
} else {
    // use it ...
    if (host->version >= 6 && host->free_string) {
        host->free_string(api_key);
    } else {
        free((void*)api_key);
    }
}
```

### `config_set(key, value) -> void`

Stores or overwrites a secret. **Does not** echo the change back to the calling plugin via `on_config_changed` — the plugin already knows what it just wrote, and echoing would create a feedback loop for plugins that mutate state inside their config handler. UI-driven changes from the host (Save / Disconnect, tunnel up/down) DO call `on_config_changed`.

Values larger than 1 MiB are silently rejected with a one-shot warning (the keychain is for credentials, not blob storage; use `db_exec` / `db_query` for larger payloads).

### `config_delete(key) -> void`

Removes a secret. Like `config_set`, the calling plugin does **not** receive an `on_config_changed` echo for its own delete. UI-driven deletes do.

### Cleared values: `""` vs deleted

Empty string `""` is a real value, distinct from a delete. Use `config_delete` to remove a key entirely. Host-side pushes that signal a transition (e.g. `tunnel_url` going down) deliver `""` to `on_config_changed`; treat that as "no value right now" rather than "no value ever stored."

### Repeat-value deliveries on relay reconnect

Normal config pushes are deduped on value equality — the host drops `(key, value)` pairs that match the prior delivery for the same `(agent, key)`, so plugins that do expensive work in `on_config_changed` (Telegram `setupWebhook`, OAuth refresh, etc.) don't re-run on no-op pushes. There is one explicit exception: when an agent's relay status transitions `non-.connected -> .connected(U)` (a relay reconnect), the host force-redelivers the **full per-agent config snapshot** plus `tunnel_url=U` to every loaded plugin, **bypassing the dedup**. The relay assigns a stable URL to each agent so the URL is usually unchanged across the gap, but the upstream service (Telegram, etc.) needs the plugin to re-assert the registration after the disconnect window.

The practical contract for plugin authors:

- `on_config_changed` MUST be idempotent for repeat values. A `setupWebhook(URL)` call with the same URL the upstream service already has should be safe (Telegram-style upstreams typically treat this as a no-op refresh; if your upstream isn't idempotent, gate the work yourself with an in-plugin "have I synced this value" check).
- The first observation of an agent's status on app launch is **not** treated as a reconnect — `runFirstDeliverySweep` already pushed the snapshot synchronously inside the loading marker. Only `non-.connected -> .connected(U)` transitions for agents the host has already observed (typically the same agent transitioning through `.connecting` or `.disconnected` and back) trigger the force redelivery.
- Newly added agents go through `host_agent_added` → `deliverInitialConfig` (NOT through the reconnect path), so the dedup contract for first-delivery on a new agent is unchanged.

### `on_config_changed(key, value) -> void` threading

The host serializes invocations of `on_config_changed` per plugin: two callbacks for the same plugin will never run in parallel, even when the host fans out per-agent notifications back-to-back at launch. State touched only from this callback can stay lock-free; state shared with `invoke` / `handle_route` still needs its own synchronization (those paths run concurrently).

### `get_active_agent_id() -> char*` (v4)

Returns the UUID string of the agent that invoked the current callback frame (`handle_route`, `invoke`, `on_config_changed`, `on_task_event`), or **NULL** when the call is happening outside any per-agent frame (`init`, plugin-spawned background thread, callback fired before the host bound an agent to the calling thread). Free with **`host->free_string`** (v6+) or **`libc free`** on older hosts — see the Conventions section above for why this is NOT the plugin's own `free_string`.

**Always re-call when you need the value — do not cache.** The same `osr_plugin_ctx_t` serves every agent the plugin runs under, and the active agent changes between callbacks. Use this to key per-agent state on the plugin side (e.g. a `bot_session` map keyed by agent UUID) so your in-memory state lines up with the `(plugin_id, agent_id, key)` scope of `config_get` / `config_set`.

```c
const char* agent_id = host->get_active_agent_id();
if (!agent_id) {
    // No active agent. Either:
    //   (a) we're in init — defer per-agent setup to on_config_changed
    //   (b) we're on a background thread we spawned — capture the agent
    //       inside an event frame and pass it down explicitly
    return;
}
// Use agent_id as the key into your per-agent state map, then:
if (host->version >= 6 && host->free_string) {
    host->free_string(agent_id);
} else {
    free((void*)agent_id);
}
```

If a plugin compiled against ABI v3 or earlier dlopens against a v4 host, the slot is still present (the struct layout is frozen; v4 only appends). If a v4-aware plugin is loaded by an older host, the slot is NULL — defensively check before calling.

The host also emits a one-shot warning per `(plugin, op)` to the unified log when `config_get` / `config_set` / `config_delete` runs without a TLS-bound agent (i.e. would silently use the default agent). This makes the failure mode visible to plugin authors at install time.

---

## Storage

Per-plugin SQLite database, lazy-opened on first use. It follows the app-wide storage posture — plaintext SQLite by default (protected by macOS FileVault), or SQLCipher-encrypted when the user opts in under **Settings → Storage** (see [STORAGE.md](../STORAGE.md)). Either way the API is identical; `ATTACH`, `DETACH`, and `LOAD_EXTENSION` are blocked at the SQL guard.

**Size cap.** Each plugin's database is capped at **100 MiB** by default (configurable per-context, but not via the plugin API — this is a host-side guard). INSERT / UPDATE statements that would push past the cap fail with `database or disk is full`; the plugin sees a normal SQL error in the response envelope (no host crash). For larger payloads, use shared artifacts via the chat / dispatch flow, not `db_exec`.

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
host->log(2, "Plugin started");
```

### `log_structured(level, message, payload) -> void` (v5)

Same level scale as `log`, but `payload` is a JSON object string the host stores alongside the message — surfaced in Insights as searchable fields. Pass `NULL` for `payload` to log without fields (equivalent to `log`). The host doesn't enforce a payload schema; pick keys your dashboards / log filters will look for.

```c
host->log_structured(
    2,
    "Webhook registered",
    "{\"event\":\"webhook_registered\",\"agent_id\":\"...\",\"status\":200}"
);
```

Plugins compiled against ABI v4 or earlier see a NULL slot — defensively check `host->version >= 5 && host->log_structured` before calling. Dashboards on the host side filter by `pluginId` and the structured payload's keys.

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
  "session_id": "Optional UUID. Reattach to an existing session",
  "tools": ["Optional. Tool names to expose to the model on top of the agent's normal selection."]
}
```

**Agent scoping.** The dispatched task always runs under the agent that invoked the plugin (see the "Agent scoping" note in the [Inference](#inference) section). `agent_address` / `agent_id` are not part of the schema; if either is present they are ignored and a one-shot warning is logged. `session_id` reattach is naturally agent-scoped — a session belonging to a different agent silently misses and a fresh task is created.

**Tool selection.** The optional `tools` array pins specific tool names so the dispatched chat is guaranteed to see them on turn 1 — useful for "the agent must be able to call `reply` to talk back to the user" patterns where you can't rely on the agent loading them on demand. Names are *additive* on top of the agent's existing selection (auto-mode hot set or manual list); they don't replace it. Allowed names are restricted to:

- the calling plugin's own manifest tool ids (the `id` field on each entry in `manifest.capabilities.tools`), and
- host built-in tool names such as `share_artifact`, `reply`, sandbox tools, etc. — including gated built-ins like `search_memory`, `render_chart`, `speak`, and the scheduler tools, which default off behind their per-agent feature toggles. Pinning a gated built-in here is additive and surfaces it for this dispatch even when the agent's toggle is off.

Names outside that set are dropped silently and a one-shot `[PluginHostAPI] Plugin '<id>' requested tool '<name>' on dispatch but it is not in the allowed set` warning is logged per `(plugin, name)` per process. The rest of the dispatch proceeds normally — a typo in `tools` never fails the call. Omitting the field, passing an empty array, or passing non-string entries all behave like the field wasn't there.

Example — a Telegram-style plugin guaranteeing the model can reply:

```json
{
  "prompt": "User said: hello",
  "session_id": "<deterministic-uuid-for-chat>",
  "tools": ["reply", "reply_typing", "reply_photo"]
}
```

The dispatched chat will see `reply` / `reply_typing` / `reply_photo` in its `<tools>` schema on turn 1, on top of the agent's auto-mode hot set. See [Example: Telegram bridge plugin](EXAMPLE_TELEGRAM.md) for the full flow.

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

### Task lifecycle events (`on_task_event`)

The host fans every dispatched task's lifecycle into the originating plugin's `on_task_event` callback as `(task_id, event_type, event_json)` tuples. Event types match the `OSR_TASK_EVENT_*` constants in `osaurus_plugin.h`:

| Type | Constant | Payload |
| ---- | -------- | ------- |
| 0 | `OSR_TASK_EVENT_STARTED` | `{status, title}` |
| 1 | `OSR_TASK_EVENT_ACTIVITY` | `{kind, title, detail?, timestamp, metadata?}` |
| 2 | `OSR_TASK_EVENT_PROGRESS` | `{progress, current_step?, title}` |
| 3 | `OSR_TASK_EVENT_CLARIFICATION` | `{question, allow_multiple, options?}` |
| 4 | `OSR_TASK_EVENT_COMPLETED` | `{success, summary, title, session_id?, output?, artifacts?}` |
| 5 | `OSR_TASK_EVENT_FAILED` | `{success, summary, title, session_id?, output?, artifacts?}` |
| 6 | `OSR_TASK_EVENT_CANCELLED` | `{title}` |
| 7 | `OSR_TASK_EVENT_OUTPUT` | `{text, title}` |
| 8 | `OSR_TASK_EVENT_DRAFT` | `{draft, title}` |

#### CLARIFICATION (type 3) and the COMPLETED-suppression contract

Fired when the agent calls the inline `clarify` tool to pause for a user response. The payload carries the parsed clarify call:

```json
{
  "question": "Use Postgres or SQLite?",
  "allow_multiple": false,
  "options": ["Postgres", "SQLite"]
}
```

`options` is **omitted entirely** (not an empty array) when the agent asked a free-form question. Plugins can use key-presence as the "free-form vs choice" discriminator.

**Contract — COMPLETED is suppressed for the duration of the pause.** Without this contract the chat-layer intercept's `break outer` would trip the streaming-state observer's terminal branch and fire COMPLETED with the literal `clarify` tool envelope (`{"ok":true,"result":{"text":"Awaiting user response."},"tool":"clarify"}`) in `output` — useless to users and missing the actual question text. With the contract, the host transitions the task to "awaiting clarification" and skips the COMPLETED emission. The next event for this task is either an ACTIVITY tick (the loop resumed inside the same task id and the same chat session) or a fresh terminal event after the user answers and the resumed loop runs to completion.

**Plugin guidance.** Render `question` (and `options`, when present) to your channel. Keep your `(task_id, reply_token)` binding alive across the pause — the agent will call `reply` once it resumes. Mark the task as "replied" in your local state so a hypothetical regression that ever does fire COMPLETED-with-clarify-output can't re-trigger your safety-net summary post.

---

## HTTP

### `http_request(request_json) -> char*`

Outbound HTTP with built-in SSRF protection.

**Blocked targets.** Literal loopback (`127.0.0.0/8`, `::1`, `ip6-localhost`), RFC1918 (`10/8`, `172.16/12`, `192.168/16`), CGN (`100.64/10`), link-local (`169.254/16` — including `169.254.169.254` cloud metadata), unspecified `0.0.0.0/8`, multicast `224.0.0.0/4`, IPv6 link-local `fe80::/10`, IPv6 unique-local `fc00::/7`, and **IPv4-mapped / IPv4-compatible IPv6** forms (`::ffff:127.0.0.1`, `::10.0.0.1`, etc.). Public hostnames and addresses pass through.

**Rate limit.** Capped at **60 requests per (plugin, agent) per 60 s** (sliding window). Bursts above this fail fast with `{"error": "rate_limit_exceeded", "retry_after_ms": 60000}`. The cap is host-side defense against runaway plugins; well-behaved plugins still need their own backoff against upstream APIs.

**Known limitation: DNS rebinding.** SSRF is enforced on the URL string before the request runs — the host does **not** resolve hostnames first. A hostname that looks public (`evil.example.com`) but resolves to a private IP at connection time will pass this check and the request will go through. End-to-end SSRF mitigation requires a network-layer hook on the resolved address; tracked separately. Plugins that issue user-controlled URLs should treat untrusted hostnames as a real threat and validate the upstream response.

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
