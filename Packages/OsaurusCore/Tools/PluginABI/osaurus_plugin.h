// osaurus_plugin.h
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

// ── Plugin → Host callbacks (injected at init for v2 plugins) ──

// Config store (Keychain-backed)
typedef const char* (*osr_config_get_fn)(const char* key);
typedef void        (*osr_config_set_fn)(const char* key, const char* value);
typedef void        (*osr_config_delete_fn)(const char* key);

// Data store (sandboxed SQLite)
typedef const char* (*osr_db_exec_fn)(const char* sql, const char* params_json);
typedef const char* (*osr_db_query_fn)(const char* sql, const char* params_json);

// Logging
typedef void        (*osr_log_fn)(int level, const char* message);

// Agent dispatch (via BackgroundTaskManager)
// dispatch: Non-blocking. request_json accepts "prompt" (required), "mode",
// "title", "id", "agent_address" (crypto address) or "agent_id" (UUID),
// "folder_bookmark". Returns JSON with task id and status, or error.
// No authentication required — the host trusts in-process plugin calls.
// Rate limited to 10 dispatches per minute per plugin.
typedef const char* (*osr_dispatch_fn)(const char* request_json);

// Returns JSON with task status, progress, activity feed, and clarification
// state. Terminal statuses: "completed", "failed", "cancelled".
typedef const char* (*osr_task_status_fn)(const char* task_id);

// Cancel a running or awaiting-clarification task.
typedef void        (*osr_dispatch_cancel_fn)(const char* task_id);

// Submit a clarification response (work mode only). Resumes the task.
typedef void        (*osr_dispatch_clarify_fn)(const char* task_id,
                                               const char* response);

// Inference — routes through the Osaurus unified inference layer.
// Model resolution: specific name, null/"" for default, "local" for MLX,
// "foundation" for Apple Foundation Model.

// Synchronous chat completion. request_json follows OpenAI chat format
// (model, messages, max_tokens, temperature). Returns full response JSON.
typedef const char* (*osr_complete_fn)(const char* request_json);

// Streaming chat completion. Calls on_chunk for each token delta.
// user_data is passed through to on_chunk. Returns aggregated response.
typedef const char* (*osr_complete_stream_fn)(
    const char* request_json,
    void (*on_chunk)(const char* chunk_json, void* user_data),
    void* user_data
);

// Generate embeddings. request_json has "model" and "input" (string or
// string array). Returns JSON with embedding vectors and usage stats.
typedef const char* (*osr_embed_fn)(const char* request_json);

// Models — enumerate available models (local MLX, Apple Foundation, remote).
// Returns JSON with "models" array containing id, name, provider, type,
// context_window, dimensions, and capabilities for each model.
typedef const char* (*osr_list_models_fn)(void);

// HTTP client — outbound HTTP requests with SSRF protection.
// request_json has "method", "url", "headers", "body", "body_encoding",
// "timeout_ms", "follow_redirects". Private IP ranges blocked by default.
// Returns JSON with "status", "headers", "body", "body_encoding", "elapsed_ms".
typedef const char* (*osr_http_request_fn)(const char* request_json);

// v3 additions: Events, Memory, Plugin CRUD, Identity

// Events — host-side event bus for plugin communication.
// event_type: dot-separated string (e.g. "message.received").
// payload_json: arbitrary JSON payload.
// on_event: callback invoked when a matching event fires.
// user_data: passed through to on_event.
// subscribe returns a subscription ID string (UUID). Caller must free via free_string.
typedef const char* (*osr_events_subscribe_fn)(
    const char* event_type,
    void (*on_event)(const char* event_type, const char* payload_json, void* user_data),
    void* user_data
);
typedef void (*osr_events_emit_fn)(const char* event_type, const char* payload_json);

// Memory — shared memory store accessible to all agents.
// memory_query: query_json has "query" (required), "agent_id", "top_k".
//   Returns JSON with "results" array.
// memory_store: content_json has "content" (required), "tags" (optional string array).
//   Stored tagged with the current agent_id. Returns JSON with "id", "status".
typedef const char* (*osr_memory_query_fn)(const char* query_json);
typedef const char* (*osr_memory_store_fn)(const char* content_json);

// Plugin CRUD — create, list, and remove sandbox plugins.
// plugin_create: plugin_json is a full sandbox plugin JSON recipe.
//   Returns JSON with "status":"ok" or error.
// plugin_list: Returns JSON with "plugins" array.
// plugin_remove: name is the plugin name to remove. Returns JSON status.
typedef const char* (*osr_plugin_create_fn)(const char* plugin_json);
typedef const char* (*osr_plugin_list_fn)(void);
typedef const char* (*osr_plugin_remove_fn)(const char* name);

// Identity — agent cryptographic identity (OsaurusID).
// identity_address: Returns the agent's address string, or NULL if none.
// identity_sign: data_hex is hex-encoded bytes. Returns JSON with "signature" (hex).
typedef const char* (*osr_identity_address_fn)(void);
typedef const char* (*osr_identity_sign_fn)(const char* data_hex);

typedef struct {
    uint32_t           version;       // OSR_ABI_VERSION_2 or OSR_ABI_VERSION_3

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
    osr_dispatch_clarify_fn dispatch_clarify;

    // Inference
    osr_complete_fn         complete;
    osr_complete_stream_fn  complete_stream;
    osr_embed_fn            embed;
    osr_list_models_fn      list_models;

    // HTTP Client
    osr_http_request_fn     http_request;

    // v3 fields (zeroed for v2 plugins)

    // Events
    osr_events_subscribe_fn events_subscribe;
    osr_events_emit_fn      events_emit;

    // Memory
    osr_memory_query_fn     memory_query;
    osr_memory_store_fn     memory_store;

    // Plugin CRUD
    osr_plugin_create_fn    plugin_create;
    osr_plugin_list_fn      plugin_list;
    osr_plugin_remove_fn    plugin_remove;

    // Identity
    osr_identity_address_fn identity_address;
    osr_identity_sign_fn    identity_sign;
} osr_host_api;

// ── Task lifecycle event types ──

#define OSR_TASK_EVENT_STARTED          0
#define OSR_TASK_EVENT_ACTIVITY         1
#define OSR_TASK_EVENT_PROGRESS         2
#define OSR_TASK_EVENT_CLARIFICATION    3
#define OSR_TASK_EVENT_COMPLETED        4
#define OSR_TASK_EVENT_FAILED           5
#define OSR_TASK_EVENT_CANCELLED        6
#define OSR_TASK_EVENT_OUTPUT           7

// Unified task lifecycle callback.
// event_type: one of the OSR_TASK_EVENT_* constants above.
// event_json: JSON payload whose shape depends on event_type.
typedef void (*osr_on_task_event_fn)(osr_plugin_ctx_t ctx,
                                     const char* task_id,
                                     int event_type,
                                     const char* event_json);

// ── Host → Plugin API struct ──

typedef struct {
    // v1 fields (unchanged)

    // Free a string returned by the plugin.
    void (*free_string)(const char* s);

    // Initialize the plugin. Returns an opaque context pointer or NULL on failure.
    osr_plugin_ctx_t (*init)(void);

    // Destroy the plugin context and free resources.
    void (*destroy)(osr_plugin_ctx_t ctx);

    // Returns a JSON string describing the plugin and its capabilities.
    // The host is responsible for calling free_string on the result.
    const char* (*get_manifest)(osr_plugin_ctx_t ctx);

    // Generic invocation point.
    // type: The type of capability (e.g., "tool", "provider").
    // id: The identifier of the specific function/capability (e.g., tool name).
    // payload: JSON string containing arguments/input.
    // Returns a JSON string response. Host must call free_string.
    const char* (*invoke)(osr_plugin_ctx_t ctx, const char* type, const char* id, const char* payload);

    // v2 fields (new — zeroed / absent for v1 plugins)

    // ABI version: 0 for v1 (field absent or zeroed), 2 for v2.
    uint32_t version;

    // HTTP route handler. Called when a request hits a plugin route.
    // request_json: JSON-encoded OsaurusHTTPRequest.
    // Returns a JSON-encoded OsaurusHTTPResponse. Host must call free_string.
    // May be NULL if the plugin has no routes.
    const char* (*handle_route)(osr_plugin_ctx_t ctx, const char* request_json);

    // Called when a config value changes in the host UI.
    // May be NULL if the plugin doesn't need config change notifications.
    void (*on_config_changed)(osr_plugin_ctx_t ctx, const char* key, const char* value);

    // Unified task lifecycle callback. Called for every dispatched-task event:
    // started, activity, progress, clarification, completed, failed, cancelled.
    // May be NULL if the plugin doesn't need task lifecycle notifications.
    void (*on_task_event)(osr_plugin_ctx_t ctx, const char* task_id,
                          int event_type, const char* event_json);

} osr_plugin_api;

// ── Entry points ──

// v1 (legacy): Plugins export this symbol. Returns a pointer to the static API struct.
const osr_plugin_api* osaurus_plugin_entry(void);

// v2 (new): Receives host-provided callbacks. Osaurus tries this symbol first.
// If the plugin was compiled against v1, this symbol won't exist and Osaurus
// falls back to osaurus_plugin_entry. Plugins should set api->version = 2.
const osr_plugin_api* osaurus_plugin_entry_v2(const osr_host_api* host);

#ifdef __cplusplus
}
#endif

#endif // OSAURUS_PLUGIN_H
