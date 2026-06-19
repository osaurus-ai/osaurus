# Tool Exposure Control Center

The Tools settings view (Available tab) is organized as a single, de-duplicated
tool browser. A Tool Exposure Control Center bar sits at the top and drives one
origin-grouped list below it; every registered tool appears exactly once.

## Layout

- Overview & control bar: title, a `matching/total` badge, a wrapping row of
  summary chips (Exposed, Loadable, Hidden, Disabled, Blocked, Unavailable),
  and a controls row with the Source filter, State filter, and reporter-safe
  Export. Each summary chip doubles as a one-tap state filter.
- Grouped list: tools are grouped by origin — Built-in & Native, Runtime
  (folder + built-in sandbox), Plugins (one group per plugin), and Remote
  providers (one group per provider). Each row carries the source-specific
  management affordances (policy menu, enable toggle, plugin permissions,
  provider disconnect) plus an exposure state pill and token estimate. Hover
  the state pill to see the capability-search indexing detail.

The Source and State filters and the summary chips narrow the grouped list; the
search box narrows by text. When filters hide everything, the list shows a
single empty-state message. Filtering is re-derived purely in memory from the
last diagnostic snapshot, so changing a filter never re-runs the DB-backed
exposure scan.

The diagnostic data (source, exposure state, availability reason,
capability-search indexing state, global enablement, and estimated schema token
cost) uses the same typed diagnostics that back `capabilities_discover` miss
explanations.

## Sources

- Built-in: baseline tools registered by Osaurus.
- Runtime: folder and built-in sandbox tools managed by the active session.
- Plugin: native plugin tools.
- MCP: tools registered by connected remote MCP providers.
- Sandbox: JSON sandbox plugin tools.
- Native: registered tools that do not belong to the other buckets.
- Unknown: named diagnostics for tools that are not registered.

## States

- Exposed: callable in the active baseline.
- Loadable: registered and available through `capabilities_load`.
- Hidden: filtered by agent scope, execution mode, or preflight selection.
- Disabled: globally disabled by tool configuration.
- Blocked: permission policy or missing system permission blocks use.
- Unavailable: not registered, not installed, or otherwise unavailable.

## Reporter-Safe Export

The export button writes a Markdown report designed for issue reports. It
includes tool names, source/state, reason codes, indexing booleans, and token
estimates. It deliberately omits raw schemas, arguments, secrets, provider
URLs, manifest paths, and runtime paths.
