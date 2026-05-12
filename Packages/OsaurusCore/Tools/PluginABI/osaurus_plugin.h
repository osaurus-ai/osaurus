// osaurus_plugin.h
//
// Osaurus Plugin ABI — current documented surface is v5.
//
// COMPATIBILITY
// =============
// Both legacy entry points continue to load:
//
//   - osaurus_plugin_entry      (v1 — never received the host API)
//   - osaurus_plugin_entry_v2   (current — receives `osr_host_api*`)
//
// New plugins should target v5 by exporting `osaurus_plugin_entry_v2`
// and reading `host->version >= 5`. Plugins compiled against an older
// version (v3 / v4) keep working — `host->version` advertises the
// highest documented surface the host implements; new slots present
// on a newer host are simply unused by older plugins. Plugins
// compiled against a newer ABI than the host implements should
// defensively check `host->version >= N && host->callback != NULL`
// before invoking a new slot.
//
// See `docs/plugins/ABI_VERSIONS.md` for the per-version evolution
// (v1 base, v2 host injection, v3 streaming cancel, v4 agent
// introspection, v5 structured logging).
//
// The struct layout is FROZEN —
// position of every callback is preserved across versions. Two slots
// (dispatch_clarify, dispatch_add_issue) are RESERVED for ABI
// compatibility and return a structured `not_supported` JSON envelope
// when invoked. Do not call them from new plugins.
//
// JSON ENVELOPE POLICY
// ====================
// Host callbacks return JSON strings. On error every callback returns:
//
//   {"error": "<code>", "message": "<human-readable>"}
//
// The single exception is `config_get`, which returns NULL when the
// requested key is absent (because the value is itself an arbitrary
// string and "missing" is not an error condition). Every other
// callback uses the structured envelope.
//
// MEMORY OWNERSHIP
// ================
// All `const char*` strings returned from host callbacks are
// heap-allocated by the host with `strdup` and must be released with
// `host->free_string` (added in v6) — see below. Plugins compiled
// against v5 or earlier can equivalently call `libc free()` on the
// returned pointer, which is what the host's `free_string` does
// internally; the v6 callback exists so plugins don't have to depend
// on the libc symbol directly and so a future allocator change on the
// host side stays transparent. NEVER free a host-returned string with
// the plugin's own `free_string` callback — that one is for the
// reverse direction.
//
// Strings the host receives from the plugin (via `invoke`,
// `get_manifest`, `handle_route`) are released with the plugin's
// `free_string` callback.
//
// VERSIONING
// ==========
// The host populates `osr_host_api.version` with the highest version
// it implements. Plugins that read `version` should treat it as a
// monotonic forward-compatible field — a v3 host is a strict superset
// of v2 behavior with the same memory layout.

#ifndef OSAURUS_PLUGIN_H
#define OSAURUS_PLUGIN_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define OSR_ABI_VERSION_1 1
#define OSR_ABI_VERSION_2 2
#define OSR_ABI_VERSION_3 3
#define OSR_ABI_VERSION_4 4
#define OSR_ABI_VERSION_5 5
#define OSR_ABI_VERSION_6 6

// Opaque context provided by the plugin, passed back to all function calls.
typedef void* osr_plugin_ctx_t;

// ── Plugin → Host callbacks (injected at init for v2+ plugins) ──

// Config store (Keychain-backed).
//
// Scope. Every entry is keyed by `(plugin_id, agent_id, key)`. The
// `agent_id` is resolved from the host-enforced agent scope (see the
// "AGENT SCOPING" note on `osr_dispatch_fn` for how that's set). One
// plugin's config never collides with another plugin's, and one
// agent's config never collides with another agent's.
//
// Echo. `config_set` and `config_delete` do NOT echo the change back
// through `on_config_changed`. The plugin already knows what it just
// wrote; echoing would create a feedback loop for plugins that mutate
// state inside their config handler. UI-driven changes from the host
// (Save / Disconnect, tunnel up/down, fresh load) DO call
// `on_config_changed` so the plugin can reconcile.
//
// Cleared values. Empty string `""` is a real value, distinct from
// "deleted". Use `config_delete` to remove a key entirely. Host-side
// pushes that signal a transition (e.g. `tunnel_url` going down)
// deliver `""` to `on_config_changed`; treat it as "no value right
// now" rather than "no value ever stored".
//
// Size. `config_set` rejects values larger than 1 MiB silently with a
// one-shot warning. The keychain is for credentials and small state,
// not blob storage; use `db_exec` / `db_query` for larger payloads.
//
// Returns NULL when the key is missing. All other host callbacks return
// a structured JSON error envelope; `config_get` is the single exception
// because the value space is arbitrary strings.
typedef const char* (*osr_config_get_fn)(const char* key);
typedef void        (*osr_config_set_fn)(const char* key, const char* value);
typedef void        (*osr_config_delete_fn)(const char* key);

// Data store (sandboxed SQLite).
// `params_json` may be NULL or a JSON array `[v1, v2, ...]` for `?` placeholders,
// or a JSON object `{":name": v1, ...}` for named placeholders.
typedef const char* (*osr_db_exec_fn)(const char* sql, const char* params_json);
typedef const char* (*osr_db_query_fn)(const char* sql, const char* params_json);

// Logging — level: 0=trace, 1=debug, 2=info, 3=warn, 4=error.
typedef void        (*osr_log_fn)(int level, const char* message);

// Agent dispatch (via BackgroundTaskManager).
//
// AGENT SCOPING (security boundary):
//   Plugin-initiated dispatches always run under the agent that invoked
//   the plugin — i.e. the agent whose route delivered the webhook
//   (`handle_route`), whose tool call entered (`invoke`), or whose
//   config / task-event callback fired. The host enforces this scope
//   from thread-local state captured before this trampoline is
//   entered. Caller-supplied `agent_address` / `agent_id` keys in
//   `request_json` are IGNORED, and a one-shot warning is logged so
//   cross-agent dispatch attempts remain visible. A plugin can never
//   spawn work in another agent's context. Background work the plugin
//   spawned itself (no invoke / route / event frame above it) is
//   resolved against the built-in default agent and also logged once.
//
// Schema for `osr_dispatch_request` (passed as JSON):
//   prompt          (required, string)        — initial prompt
//   mode            (optional, string)        — execution mode
//   title           (optional, string)        — display title
//   id              (optional, UUID string)   — caller-supplied request id
//   folder_bookmark (optional, base64 string) — security-scoped folder bookmark
//   session_id      (optional, UUID string)   — reattach to an existing
//                                                session. Reattach is
//                                                naturally agent-scoped:
//                                                a session belonging to a
//                                                different agent silently
//                                                misses and a fresh one
//                                                is created.
//
// Returns: {"id": "<uuid>", "status": "running"} on success or an error envelope.
// Non-blocking. Rate-limited to 10 dispatches per minute per (plugin, agent) pair.
// No authentication required — the host trusts in-process plugin calls.
typedef const char* (*osr_dispatch_fn)(const char* request_json);

// Returns JSON with task status, progress, activity feed.
// Terminal statuses: "completed", "failed", "cancelled".
// Returns {"error": "not_found"} if the task does not belong to the calling plugin.
typedef const char* (*osr_task_status_fn)(const char* task_id);

// Cancel a running task. No-ops silently if `task_id` is invalid or
// does not belong to the calling plugin.
typedef void        (*osr_dispatch_cancel_fn)(const char* task_id);

// RESERVED — preserved for ABI compatibility. Returns immediately; the
// agent loop now handles clarification inline via the `clarify` tool.
// New plugins should not invoke this slot.
typedef void        (*osr_dispatch_clarify_fn)(const char* task_id,
                                               const char* response);

// Inference — routes through the Osaurus unified inference layer.
// Model resolution: specific name, null/"" for default, "local" for MLX,
// "foundation" for Apple Foundation Model.
//
// AGENT SCOPING (security boundary): identical to `osr_dispatch_fn`.
// Inference inherits per-agent system prompt, tool surface, model
// override, temperature, and max_tokens from the agent that invoked
// the plugin. Caller-supplied `agent_address` / `agent_id` keys in
// `request_json` are IGNORED and warned-once. Use `messages` and
// the explicit `tools` / `model` fields to override per-call;
// agent identity itself cannot be overridden.
//
// Schema for `osr_complete_request` (passed as JSON, OpenAI-compatible):
//   model        (optional, string)
//   messages     (required, array of {role, content})
//   max_tokens   (optional, int)
//   temperature  (optional, number)
//   tools        (optional, array)
//   stream       (ignored — use complete_stream for streaming)

// Synchronous chat completion. Returns full response JSON.
typedef const char* (*osr_complete_fn)(const char* request_json);

// Streaming chat completion. Calls `on_chunk` for each token delta.
// `user_data` is passed through to `on_chunk`. Returns aggregated final response.
//
// The chunk envelope follows OpenAI streaming format:
//   {"id": "...", "choices": [{"delta": {"content": "..."}, ...}]}
//
// Special chunks include:
//   - reasoning deltas (`choices[0].delta.reasoning`)
//   - tool-call deltas (`choices[0].delta.tool_calls`, finish_reason: "tool_calls")
//   - usage chunks (`choices[0].delta.usage`) — final token accounting
//   - terminator (`choices[0].finish_reason: "stop" | "length" | "tool_calls" | "max_iterations" | "cancelled"`)
//
// To support mid-stream cancellation, pass an optional `stream_id` UUID in
// `request_json`. The plugin can then call `complete_cancel(stream_id)` from
// any thread (typically `on_chunk`, or a separate worker) to abort. When a
// stream is cancelled, the host emits a final chunk with
// `finish_reason: "cancelled"` and returns an envelope with `error: "cancelled"`.
typedef const char* (*osr_complete_stream_fn)(
    const char* request_json,
    void (*on_chunk)(const char* chunk_json, void* user_data),
    void* user_data
);

// Cancels an in-flight `complete_stream` call identified by `stream_id`
// (the same UUID the plugin passed in the `complete_stream` request body).
// No-ops silently if the id does not match an active stream. Safe to call
// from `on_chunk` or any other thread; the call is non-blocking. The
// streaming task observes the cancellation between deltas and unwinds.
typedef void        (*osr_complete_cancel_fn)(const char* stream_id);

// Generate embeddings. `request_json` has "model" and "input" (string or
// string array). Returns JSON with embedding vectors and usage stats.
//
// AGENT SCOPING: identical to `osr_dispatch_fn`. The host enforces the
// invoking agent's scope; caller-supplied `agent_address` / `agent_id`
// is ignored and warned-once.
typedef const char* (*osr_embed_fn)(const char* request_json);

// Models — enumerate available models (local MLX, Apple Foundation, remote).
// Returns JSON with "models" array containing id, name, provider, type,
// context_window, dimensions, and capabilities for each model.
typedef const char* (*osr_list_models_fn)(void);

// HTTP client — outbound HTTP requests with SSRF protection.
//
// Schema for `osr_http_request` (passed as JSON):
//   method           (required, string)        — GET/POST/...
//   url              (required, string)
//   headers          (optional, object)
//   body             (optional, string)
//   body_encoding    (optional, "utf8" | "base64") — defaults to utf8
//   timeout_ms       (optional, integer)
//   follow_redirects (optional, boolean)       — defaults to true
//
// Private IP ranges are blocked by default (SSRF protection).
// Returns: {"status": <int>, "headers": {...}, "body": "...", "body_encoding": "...", "elapsed_ms": <int>}
typedef const char* (*osr_http_request_fn)(const char* request_json);

// File I/O — read files from allowed paths (e.g. shared artifacts).
// `request_json` has "path" (absolute file path). Restricted to artifact
// paths (`~/.osaurus/artifacts/`) for security; max 50 MB.
// Returns {"data": "<base64>", "size": N, "mime_type": "..."} or error envelope.
typedef const char* (*osr_file_read_fn)(const char* request_json);

// List all active tasks dispatched by the calling plugin.
// Returns JSON: {"tasks": [<task_status objects>]}.
typedef const char* (*osr_list_active_tasks_fn)(void);

// Store/emit draft content for a task (e.g. live-update messages).
// `draft_json` has "text" (required) and optional "parse_mode".
// No-ops silently if `task_id` is invalid or does not belong to the calling plugin.
typedef void        (*osr_send_draft_fn)(const char* task_id,
                                         const char* draft_json);

// Soft-stop a running task by cancelling its current stream.
//
// When `message` is non-empty, the trimmed content is appended to the
// dispatched chat session as a user-role turn BEFORE the stream is
// cancelled. The model picks it up on the next completion round — i.e.
// when the user reopens the chat window, when the plugin dispatches a
// follow-up against the same `session_id`, or when the session is
// otherwise resumed. This lets a plugin redirect a long-running task
// without losing the conversation context.
//
// Pass NULL or an empty string to soft-stop without injecting a message.
// No-ops silently if `task_id` is invalid or doesn't belong to the
// calling plugin.
typedef void        (*osr_dispatch_interrupt_fn)(const char* task_id,
                                                 const char* message);

// RESERVED — preserved for ABI compatibility. Returns a structured
// `not_supported` JSON envelope. The issue tracker was retired. New
// plugins should call `dispatch` to start a fresh task instead.
typedef const char* (*osr_dispatch_add_issue_fn)(const char* task_id,
                                                 const char* issue_json);

// Returns the UUID string of the agent that invoked the current
// callback frame (`handle_route`, `invoke`, `on_config_changed`,
// `on_task_event`), or NULL when the call is happening outside any
// per-agent frame (`init`, plugin-spawned background thread, callback
// fired before the host bound an agent to the calling thread).
//
// Free the returned string with `host->free_string` (v6+) or `libc
// free()` on older hosts. NEVER pass it to the plugin's own
// `free_string` — that callback is for the reverse direction. See
// `osr_host_free_string_fn` for the rationale. Always re-call when
// you need the value — do NOT cache it across frames. The same
// `osr_plugin_ctx_t` serves every agent the host loaded the plugin
// under, and the active agent changes between callbacks.
//
// Use this to key per-agent state on the plugin side (e.g. a map of
// `agent_id -> bot_session`) so that `(plugin_id, agent_id, key)`
// scoped config (`config_get` / `config_set`) lines up with your
// in-memory state. NULL means "no active agent" — the plugin should
// either skip per-agent work or capture the id from a previous
// per-agent frame and pass it to the background path explicitly.
//
// Added in OSR_ABI_VERSION_4. Plugins compiled against earlier ABI
// versions see a NULL slot and should defensively check before calling.
typedef const char* (*osr_get_active_agent_id_fn)(void);

// Structured logging companion to `osr_log_fn`. `level` matches the
// same scale (0=trace, 1=debug, 2=info, 3=warn, 4=error). `payload`
// is a JSON object string the host stores alongside the message —
// surfaced in Insights as searchable fields. Keys are arbitrary; the
// host does not enforce a schema. The plugin owns parsing the host's
// log filters / dashboards keyed by these fields. Pass NULL `payload`
// to log a message with no fields (equivalent to `osr_log_fn`).
//
// Example payloads:
//   {"event":"webhook_registered","agent_id":"...","status":200}
//   {"event":"oauth_failed","provider":"github","retry_count":3}
//
// Added in OSR_ABI_VERSION_5. Plugins compiled against earlier ABI
// versions see a NULL slot; check before calling.
typedef void (*osr_log_structured_fn)(int level,
                                       const char* message,
                                       const char* payload);

// Frees a `const char*` previously returned by ANY host callback
// (`config_get`, `dispatch`, `complete`, `task_status`,
// `http_request`, `file_read`, `get_active_agent_id`, etc.). Internally
// runs `libc free` on the pointer, which pairs with the `strdup` the
// host uses to allocate every returned string.
//
// Why this exists as a callback rather than letting the plugin call
// `libc free()` directly:
//   1. The plugin's own `free_string` (on `osr_plugin_api`) is for the
//      *opposite* direction — the host calling it on plugin-allocated
//      strings. Calling that on a host-allocated pointer is a recipe
//      for a malloc abort if the plugin's `free_string` does anything
//      other than plain `free()` (e.g. wraps an autorelease, holds a
//      lock, decrements a refcount). v6 plugins should always free
//      host-returned strings via `host->free_string`.
//   2. A future host allocator change (custom pool, debug zone, etc.)
//      stays transparent to plugins.
//
// NULL pointer is a no-op. Safe to call from any thread.
//
// Added in OSR_ABI_VERSION_6. Plugins compiled against earlier ABI
// versions see a NULL slot; fall back to `libc free()` directly:
//
//   if (host->version >= 6 && host->free_string) {
//       host->free_string(ptr);
//   } else {
//       free((void*)ptr);
//   }
typedef void (*osr_host_free_string_fn)(const char* s);

// ── Host API struct (injected into v2+ plugins at init) ──
//
// The struct layout is FROZEN. Field order and offsets are stable across
// host versions. The `version` field advertises the highest documented
// surface the host implements.

typedef struct {
    uint32_t           version;       // OSR_ABI_VERSION_6 in current builds

    // Config + Storage + Logging
    osr_config_get_fn       config_get;
    osr_config_set_fn       config_set;
    osr_config_delete_fn    config_delete;
    osr_db_exec_fn          db_exec;
    osr_db_query_fn         db_query;
    osr_log_fn              log;

    // Agent Dispatch
    osr_dispatch_fn         dispatch;
    osr_task_status_fn      task_status;
    osr_dispatch_cancel_fn  dispatch_cancel;
    osr_dispatch_clarify_fn dispatch_clarify;  // RESERVED — returns no-op

    // Inference
    osr_complete_fn         complete;
    osr_complete_stream_fn  complete_stream;
    osr_embed_fn            embed;
    osr_list_models_fn      list_models;

    // HTTP Client
    osr_http_request_fn     http_request;

    // File I/O
    osr_file_read_fn        file_read;

    // Extended Agent Dispatch (added in v2; preserved in v3)
    osr_list_active_tasks_fn   list_active_tasks;
    osr_send_draft_fn          send_draft;
    osr_dispatch_interrupt_fn  dispatch_interrupt;
    osr_dispatch_add_issue_fn  dispatch_add_issue;  // RESERVED — returns not_supported

    // Streaming control (added in v3)
    osr_complete_cancel_fn     complete_cancel;

    // Agent context introspection (added in v4)
    osr_get_active_agent_id_fn get_active_agent_id;

    // Structured logging (added in v5)
    osr_log_structured_fn      log_structured;

    // Host-side free for strings the host returned (added in v6).
    // ALWAYS use this for host-returned `const char*` instead of the
    // plugin's own `free_string`. See typedef comment above for the
    // backwards-compat fallback to `libc free()` on older hosts.
    osr_host_free_string_fn    free_string;
} osr_host_api;

// ── Task lifecycle event types ──

#define OSR_TASK_EVENT_STARTED          0
#define OSR_TASK_EVENT_ACTIVITY         1
#define OSR_TASK_EVENT_PROGRESS         2
// Fired when the agent calls the inline `clarify` tool to pause for
// a user response. Payload JSON:
//   {"question": "<text>", "allow_multiple": <bool>,
//    "options"?: ["a","b",...]}
// `options` is OMITTED entirely (not an empty array) when the agent
// asked a free-form question, so `options` key-presence is a clean
// "free-form vs choice" discriminator on the plugin side.
//
// CONTRACT — COMPLETED suppression. The host transitions the task to
// "awaiting clarification" and SUPPRESSES the COMPLETED event that
// would otherwise fire when the agent loop yields on the intercept.
// The next event for this task is either the next ACTIVITY tick
// after the user answers (the loop resumes inside the same task
// id and the same chat session) or a fresh terminal event after
// the resumed loop runs to completion.
//
// Plugins should render `question`/`options` to their channel when
// this event arrives. Do NOT post the previous COMPLETED-style
// safety-net summary on this event — and after rendering, mark the
// task as "replied" in your local state so a stale or downgraded
// host that ever does fire COMPLETED-with-clarify-output still
// short-circuits the safety net.
#define OSR_TASK_EVENT_CLARIFICATION    3
#define OSR_TASK_EVENT_COMPLETED        4
#define OSR_TASK_EVENT_FAILED           5
#define OSR_TASK_EVENT_CANCELLED        6
#define OSR_TASK_EVENT_OUTPUT           7
#define OSR_TASK_EVENT_DRAFT            8

// Unified task lifecycle callback.
// `event_type`: one of the OSR_TASK_EVENT_* constants above.
// `event_json`: JSON payload whose shape depends on `event_type`.
typedef void (*osr_on_task_event_fn)(osr_plugin_ctx_t ctx,
                                     const char* task_id,
                                     int event_type,
                                     const char* event_json);

// ── Host → Plugin API struct ──

typedef struct {
    // ── Required (every plugin) ──

    // Free a string returned by the plugin.
    void (*free_string)(const char* s);

    // Initialize the plugin. Returns an opaque context pointer or NULL on failure.
    osr_plugin_ctx_t (*init)(void);

    // Destroy the plugin context and free resources.
    void (*destroy)(osr_plugin_ctx_t ctx);

    // Returns a JSON string describing the plugin and its capabilities.
    // The host is responsible for calling `free_string` on the result.
    const char* (*get_manifest)(osr_plugin_ctx_t ctx);

    // Generic invocation point for tools.
    // type: capability kind (e.g. "tool").
    // id: capability identifier (e.g. tool name).
    // payload: JSON string containing arguments/input.
    // Returns a JSON string response. Host must call `free_string`.
    const char* (*invoke)(osr_plugin_ctx_t ctx, const char* type, const char* id, const char* payload);

    // ── Optional (zero / NULL when unused) ──

    // ABI version the plugin was compiled against.
    // 0 (or absent) for v1 plugins, 2+ for v2/v3 plugins.
    uint32_t version;

    // HTTP route handler. Called when a request hits a plugin route.
    // `request_json`: JSON-encoded OsaurusHTTPRequest.
    // Returns: JSON-encoded OsaurusHTTPResponse. Host must call `free_string`.
    // May be NULL if the plugin has no routes.
    const char* (*handle_route)(osr_plugin_ctx_t ctx, const char* request_json);

    // Called when a config value changes in the host UI.
    // May be NULL if the plugin doesn't need config change notifications.
    //
    // THREADING: the host serializes invocations of this callback per
    // plugin — two `on_config_changed` calls for the same plugin never
    // run in parallel, even when the host fans out per-agent
    // notifications back-to-back at launch. State touched only from
    // here can stay lock-free; state shared with `invoke` /
    // `handle_route` still needs its own synchronization (those paths
    // run concurrently).
    void (*on_config_changed)(osr_plugin_ctx_t ctx, const char* key, const char* value);

    // Unified task lifecycle callback. Called for every dispatched-task event:
    // started, activity, progress, completed, failed, cancelled, output, draft.
    // May be NULL if the plugin doesn't need task lifecycle notifications.
    void (*on_task_event)(osr_plugin_ctx_t ctx, const char* task_id,
                          int event_type, const char* event_json);

} osr_plugin_api;

// ── Entry points ──

// LEGACY (v1): Plugins export this symbol. Returns a pointer to the static
// API struct. Plugins exporting only this symbol cannot use any host
// callbacks — they are limited to `init`, `destroy`, `get_manifest`, `invoke`,
// `free_string`. The host loads them with a one-time deprecation log.
const osr_plugin_api* osaurus_plugin_entry(void);

// CURRENT (v2 entry, v3 surface): Receives host-provided callbacks. Osaurus
// tries this symbol first. If the plugin was compiled against v1, this
// symbol won't exist and Osaurus falls back to `osaurus_plugin_entry`.
// New plugins should:
//   - Export this symbol
//   - Set `api->version = OSR_ABI_VERSION_2` (or higher) so the host
//     enables v2+ features (route handlers, config-changed callbacks,
//     task-event callbacks)
//   - Read `host->version` and treat anything >= 2 as "host API available"
const osr_plugin_api* osaurus_plugin_entry_v2(const osr_host_api* host);

#ifdef __cplusplus
}
#endif

#endif // OSAURUS_PLUGIN_H
