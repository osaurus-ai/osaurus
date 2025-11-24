// osaurus_plugin.h
#ifdef __cplusplus
extern "C" {
#endif

// Opaque context provided by the plugin, passed back to all function calls.
typedef void* osr_plugin_ctx_t;

typedef struct {
  // Free a string returned by the plugin.
  void (*free_string)(const char* s);

  // Initialize the plugin. Returns an opaque context pointer or NULL on failure.
  osr_plugin_ctx_t (*init)(void);

  // Destroy the plugin context and free resources.
  void (*destroy)(osr_plugin_ctx_t ctx);

  // Returns a JSON string describing the plugin and its capabilities (tools, providers, etc.).
  // The host is responsible for calling free_string on the result.
  const char* (*get_manifest)(osr_plugin_ctx_t ctx);

  // Generic invocation point.
  // type: The type of capability (e.g., "tool", "provider").
  // id: The identifier of the specific function/capability (e.g., tool name).
  // payload: JSON string containing arguments/input.
  // Returns a JSON string response. Host must call free_string.
  const char* (*invoke)(osr_plugin_ctx_t ctx, const char* type, const char* id, const char* payload);

} osr_plugin_api;

// Main entry point. Plugins must export this symbol.
// It returns a pointer to the static API struct.
const osr_plugin_api* osaurus_plugin_entry(void);

#ifdef __cplusplus
}
#endif
