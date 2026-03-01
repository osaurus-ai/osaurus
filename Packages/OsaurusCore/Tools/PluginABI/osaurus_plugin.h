// osaurus_plugin.h
#ifndef OSAURUS_PLUGIN_H
#define OSAURUS_PLUGIN_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define OSR_ABI_VERSION_1 1
#define OSR_ABI_VERSION_2 2

// Opaque context provided by the plugin, passed back to all function calls.
typedef void* osr_plugin_ctx_t;

// ── Plugin → Host callbacks (injected at init for v2 plugins) ──

typedef const char* (*osr_config_get_fn)(const char* key);
typedef void        (*osr_config_set_fn)(const char* key, const char* value);
typedef void        (*osr_config_delete_fn)(const char* key);
typedef const char* (*osr_db_exec_fn)(const char* sql, const char* params_json);
typedef const char* (*osr_db_query_fn)(const char* sql, const char* params_json);
typedef void        (*osr_log_fn)(int level, const char* message);

typedef struct {
    uint32_t           version;       // OSR_ABI_VERSION_2
    osr_config_get_fn  config_get;
    osr_config_set_fn  config_set;
    osr_config_delete_fn config_delete;
    osr_db_exec_fn     db_exec;
    osr_db_query_fn    db_query;
    osr_log_fn         log;
} osr_host_api;

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
