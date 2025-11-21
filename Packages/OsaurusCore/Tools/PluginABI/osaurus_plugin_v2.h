// osaurus_plugin_v2.h
#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  const char* name;                 // tool id
  const char* description;          // human readable
  const char* parameters_json;      // JSON Schema
  const char* requirements_json;    // JSON array of strings
  const char* permission_policy;    // "auto" | "ask" | "deny"
} osr_tool_spec_v1;

typedef struct {
  // Memory management implemented by plugin
  void (*free_string)(const char* s);

  // Manifest
  int  (*tool_count)(void);
  int  (*get_tool_spec)(int index, osr_tool_spec_v1* out_spec); // 0 success

  // Execution (returns malloc'ed UTF-8 JSON string; host calls free_string)
  const char* (*execute)(const char* tool_name, const char* arguments_json);

  // New in v2: plugin manifest for host-side validation
  // Returns malloc'ed UTF-8 JSON string like: {"plugin_id":"com.acme.echo","version":"1.2.0","abi":2}
  const char* (*get_plugin_manifest_json)(void);
} osr_plugin_api_v2;

// Main entry symbol resolved by host via dlsym()
const osr_plugin_api_v2* osaurus_plugin_entry_v2(void);

#ifdef __cplusplus
}
#endif


