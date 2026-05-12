# ABI Versioning

The Osaurus plugin ABI evolves by **append-only** struct extension. Older plugins keep loading against newer hosts; newer plugins detect older hosts via a one-line defensive check before calling new slots. This page is the single source of truth for what changed in each version.

> The canonical C declarations live in [`Packages/OsaurusCore/Tools/PluginABI/osaurus_plugin.h`](../../Packages/OsaurusCore/Tools/PluginABI/osaurus_plugin.h). When in doubt, the header wins.

## Forward-compat policy

Three rules the host promises to keep:

1. **Struct layout is frozen.** Field order and offsets in `osr_host_api` and `osr_plugin_api` never change. New callbacks are appended at the end.
2. **Removed callbacks are RESERVED, not deleted.** Two slots (`dispatch_clarify`, `dispatch_add_issue`) remain wired for ABI compatibility but return a structured `not_supported` JSON envelope. Calling them is a no-op safe; new plugins should not invoke them.
3. **Older plugins keep loading.** A plugin compiled against ABI v1 still loads against a v5 host. The plugin sees the v1 subset; the new slots are present but the plugin's struct has no fields for them.

The reverse direction needs a defensive check: a plugin compiled against v5 dlopen'd by a v3 host sees `host->log_structured == NULL`. **Always check before calling a new slot:**

```c
if (host->version >= 5 && host->log_structured) {
    host->log_structured(2, "event", "{\"key\":\"value\"}");
} else {
    host->log(2, "event {key=value}");  // fallback
}
```

The `host->version` field on `osr_host_api` advertises the highest documented surface the host implements — read it as a forward-compatible monotonic field.

## Version history

### v1 (`OSR_ABI_VERSION_1`) — original surface

- Plugin entry: `osaurus_plugin_entry` (no host API injection — v1 plugins cannot call any host callback).
- Plugin API: `init`, `destroy`, `get_manifest`, `invoke`, `free_string`.
- Use case: pure tools that do their work without storage, network, or inference.

### v2 (`OSR_ABI_VERSION_2`) — host API injection

- Plugin entry: `osaurus_plugin_entry_v2(const osr_host_api*)` introduced.
- Plugin API additions: `handle_route`, `on_config_changed`, `on_task_event`.
- Host API: config (Keychain), per-plugin SQLite, logging, dispatch, inference, HTTP, file I/O, models — the full base set.
- Migration: re-export the entry as `osaurus_plugin_entry_v2`, capture the `host` pointer at init, opt into `handle_route` / `on_config_changed` / `on_task_event` if needed.

### v3 (`OSR_ABI_VERSION_3`) — streaming control

- Host API addition: `complete_cancel(stream_id)`. Plugins pass an opaque `stream_id` UUID in the `complete_stream` request body; calling `complete_cancel(stream_id)` from any thread (including `on_chunk`) cancels the in-flight stream. Host emits a final chunk with `finish_reason: "cancelled"`.
- Migration: pass `stream_id` in your streaming requests if you want cancellation; otherwise existing v2 streaming code keeps working.

### v4 (`OSR_ABI_VERSION_4`) — agent context introspection

- Host API addition: `get_active_agent_id() -> char*`. Returns the UUID string of the agent that invoked the current callback frame (`handle_route`, `invoke`, `on_config_changed`, `on_task_event`), or NULL outside any per-agent frame (`init`, plugin-spawned background thread). Free with `free_string`. **Always re-call** when you need the value — the same `osr_plugin_ctx_t` serves every agent.
- Why it exists: `config_get` / `config_set` are scoped by `(plugin_id, agent_id, key)` automatically via TLS, but plugins that maintain their own per-agent state in their `ctx` (HTTP clients, webhook session pools, OAuth caches) had no way to ask "which agent is invoking me right now?". Without this, a plugin would either cache state across agents (cross-agent leak) or read agent identifiers from the keychain via heuristics. v4 provides the direct accessor.
- Also tightened in v4: caller-supplied `agent_address` / `agent_id` in `dispatch` / `complete` / `complete_stream` / `embed` request JSON is **ignored** with a one-shot warning. The host enforces that plugin-initiated work always runs under the agent that invoked the plugin.
- Migration: see [HOST_API.md `get_active_agent_id`](HOST_API.md#get_active_agent_id---char-v4).

### v5 (`OSR_ABI_VERSION_5`) — structured logging

- Host API addition: `log_structured(level, message, payload)`. Same level scale as `log` (0=trace … 4=error). `payload` is a JSON object string that surfaces in Insights as searchable fields. NULL payload degrades to plain `log` shape.
- Why it exists: plugin authors couldn't filter Insights logs by anything except message substring. Structured fields let dashboards group by `event`, `agent_id`, `status_code`, etc.
- Migration: nothing required for existing plugins. Opt in by adopting `log_structured` for logs you want to filter on.

### v6 (`OSR_ABI_VERSION_6`) — host-side `free_string`

- Host API addition: `free_string(const char*)`. Pairs with the `strdup` every host trampoline uses to allocate its return value. NULL is a no-op so plugins can wire it into a generic defer block without an explicit guard.
- Why it exists: the previous contract said "free host-returned strings with the plugin's `free_string`" — but `osr_plugin_api.free_string` is the *reverse* direction (host calling on plugin-allocated strings). Plugins whose `free_string` did anything besides `libc free()` (autorelease, refcount, custom pool) would corrupt the heap on every host pointer they touched. v6 gives plugins a host-controlled, allocator-stable free path.
- Migration: replace `plugin_free_string(host_returned_ptr)` (or `free(ptr)` in C) with `host->free_string(ptr)`. On older hosts (v5 and earlier) the slot is NULL — fall back to `libc free()`:
  ```c
  if (host->version >= 6 && host->free_string) {
      host->free_string(ptr);
  } else {
      free((void*)ptr);
  }
  ```
- Behavior preservation: nothing about what the host returns changed. Existing plugins that already call `libc free()` directly keep working unchanged.

### Event additions (no struct change)

These changes alter `on_task_event` payloads or fire previously-silent slots without bumping `OSR_ABI_VERSION`. The struct layout is untouched, so older plugins keep loading; newer plugins simply add a `case` to their switch.

- **`OSR_TASK_EVENT_CLARIFICATION` (type 3) un-reserved.** Previously documented as RESERVED and never emitted. Now fired when the agent calls the inline `clarify` tool to pause for a user response, with payload `{question, allow_multiple, options?}`. The host transitions the task to "awaiting clarification" and **suppresses** the COMPLETED event that would otherwise fire when the agent loop yields on the intercept. Plugins that only switch on COMPLETED/FAILED keep working unchanged (they fall through `default`); plugins that opt into a `case 3` branch render the question to their channel. See [HOST_API.md — Task lifecycle events](HOST_API.md#task-lifecycle-events-on_task_event) for the full contract.

## Mirror Struct Audit

Plugins that mirror `osr_host_api` in a non-C language (Swift, Rust, Zig, etc.) MUST keep their mirror byte-identical to the host's frozen layout. The host appends new callbacks to the end of the struct on every version bump (v4: `get_active_agent_id`, v5: `log_structured`, v6: `free_string`); mirrors that drop or reorder a slot dispatch every callback past the mismatch into the wrong host function.

The classic foot-gun is jumping from a v4 mirror straight to v6 and skipping `log_structured` (v5). The plugin's `host->free_string(ptr)` then resolves to `host->log_structured` (one slot earlier), which discards the pointer. The plugin's *next* host call may also misroute — and the first call that returns a value reads garbage from the wrong slot, eventually crashing inside `libc free()` on a non-malloc pointer (`pointer being freed was not allocated`).

The canonical pin for the layout lives in [`PluginHostAPIStructLayoutTests`](../../Packages/OsaurusCore/Tests/Plugin/PluginHostAPIStructLayoutTests.swift); see [HOST_API.md `Mirror Struct Audit`](HOST_API.md#mirror-struct-audit) for the full field-order table and pinned offsets. Quick reference:

| Slot | Pinned offset (bytes) | Added in |
|---|---|---|
| `version` | 0 | v1 |
| `get_active_agent_id` | 176 | v4 |
| `log_structured` | 184 | **v5 — most commonly skipped** |
| `free_string` | 192 | v6 |
| (struct stride) | 200 | — |

### Pre-flight handshake

Starting with the v6 host, every newly-loaded plugin receives a synthetic `(__osaurus_abi_probe__, <UUID>)` pair through `on_config_changed` BEFORE any real per-agent config push, while a per-plugin `.currently_loading` marker is on disk. Plugins that resolve the active agent at the top of `on_config_changed` (`host->get_active_agent_id()` → `host->free_string(ptr)`) trip the misalignment crash here, which leaves the marker on disk and quarantines the plugin on the next launch (instead of re-crashing the host on every restart). The agent detail view surfaces the failure as a "Plugin failed to load" tab with a Retry button.

Plugins that want to opt out of the probe match the documented constant `"__osaurus_abi_probe__"` and early-return — see [HOST_API.md](HOST_API.md#pre-flight-abi-probe). Opting out keeps your `on_config_changed` snappier but gives up the early-detection benefit.

## What's NOT in the ABI (and won't be silently added)

- **File write.** No `file_write` callback. Plugins write via `db_exec` (SQLite) or by emitting artifacts through dispatch flows.
- **Process spawn.** No host API for it. Plugins are in-process dylibs and could `posix_spawn` themselves, but doing so puts you outside the documented surface and likely outside the registry's review criteria.
- **Other-plugin discovery.** No `list_plugins` callback. Plugins should not assume a specific other plugin is installed; depend on the host's primitives.

If you need one of the above, file an issue — extending the ABI is cheap as long as we follow the append-only rule.

## Compatibility table

| Host version | v1 plugins | v2 plugins | v3 plugins | v4 plugins | v5 plugins | v6 plugins |
|---|---|---|---|---|---|---|
| v1 (legacy) | works | won't load | won't load | won't load | won't load | won't load |
| v2 | works | works | missing `complete_cancel` | missing v4 + v3 | missing v4 + v5 + v3 | missing v4 + v5 + v6 + v3 |
| v3 | works | works | works | missing `get_active_agent_id` | missing `log_structured` | missing `free_string` (use `libc free`) |
| v4 | works | works | works | works | missing `log_structured` | missing `free_string` (use `libc free`) |
| v5 | works | works | works | works | works | missing `free_string` (use `libc free`) |
| **v6 (current)** | **works** | **works** | **works** | **works** | **works** | **works** |

"Missing" means the slot is `NULL` on the older host — the newer plugin's defensive `if (host->version >= N && host->callback)` check correctly falls through.

## When to bump the version

Bump on a host PR that:

- Adds a new optional callback to `osr_host_api` (append-only).
- Documents a new behavior contract that older plugins might not expect (e.g. v4's agent-scope enforcement was a behavior change layered on the existing dispatch slot — it got a new constant because the contract differs).

Don't bump for:

- Bug fixes that don't change the callback shape.
- Internal refactors of the trampoline plumbing.
- Documentation-only changes.
