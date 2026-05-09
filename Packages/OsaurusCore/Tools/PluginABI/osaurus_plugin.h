// osaurus_plugin.h
//
// Osaurus Plugin ABI — current documented surface is v3.
//
// COMPATIBILITY
// =============
// Both legacy entry points continue to load:
//
//   - osaurus_plugin_entry      (v1 — never received the host API)
//   - osaurus_plugin_entry_v2   (current — receives `osr_host_api*`)
//
// New plugins should target v3 by exporting `osaurus_plugin_entry_v2`
// and reading `host->version >= 3`. The struct layout is FROZEN —
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
// heap-allocated by the host. The plugin must call the host's
// `free_string` (the same one it provides to the host) to release
// them. Strings the host receives from the plugin (via `invoke`,
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

// Opaque context provided by the plugin, passed back to all function calls.
typedef void* osr_plugin_ctx_t;

// ── Plugin → Host callbacks (injected at init for v2+ plugins) ──

// Config store (Keychain-backed).
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
// Schema for `osr_dispatch_request` (passed as JSON):
//   prompt          (required, string)        — initial prompt
//   mode            (optional, string)        — execution mode
//   title           (optional, string)        — display title
//   id              (optional, UUID string)   — caller-supplied request id
//   agent_address   (optional, string)        — crypto address; or:
//   agent_id        (optional, UUID string)
//   folder_bookmark (optional, base64 string) — security-scoped folder bookmark
//   session_id      (optional, UUID string)   — reattach to an existing session
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

// ── Host API struct (injected into v2+ plugins at init) ──
//
// The struct layout is FROZEN. Field order and offsets are stable across
// host versions. The `version` field advertises the highest documented
// surface the host implements.

typedef struct {
    uint32_t           version;       // OSR_ABI_VERSION_3 in current builds

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
} osr_host_api;

// ── Task lifecycle event types ──

#define OSR_TASK_EVENT_STARTED          0
#define OSR_TASK_EVENT_ACTIVITY         1
#define OSR_TASK_EVENT_PROGRESS         2
#define OSR_TASK_EVENT_CLARIFICATION    3  // RESERVED — clarification is inline now
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
