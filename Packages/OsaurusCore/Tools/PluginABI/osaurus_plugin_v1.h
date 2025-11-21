// osaurus_plugin_v1.h
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
} osr_plugin_api_v1;

// Main entry symbol resolved by host via dlsym()
const osr_plugin_api_v1* osaurus_plugin_entry_v1(void);

#ifdef __cplusplus
}
#endif


