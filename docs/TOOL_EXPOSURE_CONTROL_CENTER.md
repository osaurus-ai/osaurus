# Tool Exposure Control Center

Settings → Tools & MCP → **All Tools** is a single, de-duplicated tool catalog
(`ToolsManagerView`): every registered tool appears exactly once. The exact
exposure vocabulary lives in a collapsed **Advanced diagnostics** card at the
bottom of the same tab (`ToolAdvancedDiagnosticsSection`), so everyday rows
stay in plain language.

## Layout

- **Auto-allow switch** (`ToolAutoAllowToggle`) at the top, above the per-tool
  policies it overrides.
- **Catalog toolbar**: a source filter (All Sources, Built-in, Plugins,
  Connections, Custom) and a status filter (All Statuses, Ready, Off, Needs
  attention); the header search box narrows by text. A banner counts tools
  waiting on a macOS permission.
- **Catalog groups** (`ToolCatalogPresentation`): Connections (one card per
  remote MCP provider), Custom (sandbox-plugin tools you created), Plugins
  (one card per native plugin), and Built-in (built-in, native, and runtime
  folder/sandbox tools). Each row carries its management affordances (policy
  menu, enable toggle, plugin permissions, provider disconnect) and a status
  pill: **Ready** (exposed, loadable, or hidden by scope), **Off** (disabled),
  or **Needs attention** (blocked, unavailable, or missing a system
  permission).
- **Advanced diagnostics** (collapsed by default): a `matching/total` badge,
  summary chips for the exact states (Exposed, Loadable, Hidden, Disabled,
  Blocked, Unavailable) that double as one-tap state filters, exposure source
  and state filters, the per-tool rows with token estimates and
  capability-search indexing detail, and the reporter-safe **Export**.

Filters and chips are re-derived purely in memory from the last diagnostic
snapshot, so changing a filter never re-runs the DB-backed exposure scan. When
filters hide everything, the catalog shows a single empty-state message.

The diagnostic data (source, exposure state, availability reason,
capability-search indexing state, global enablement, and estimated schema token
cost) uses the same typed diagnostics that back `capabilities_discover` miss
explanations.

## Diagnostic Sources

The exact sources shown in Advanced diagnostics:

- Built-in: baseline tools registered by Osaurus.
- Runtime: folder and built-in sandbox tools managed by the active session.
- Plugin: native plugin tools.
- MCP: tools registered by connected remote MCP providers.
- Sandbox: JSON sandbox plugin tools.
- Native: registered tools that do not belong to the other buckets.
- Unknown: named diagnostics for tools that are not registered.

## Diagnostic States

The exact states shown in Advanced diagnostics (the catalog's Ready / Off /
Needs attention pill summarizes them):

- Exposed: callable in the active baseline.
- Loadable: registered and available through `capabilities_load`.
- Hidden: filtered by agent scope, execution mode, or preflight selection.
- Disabled: globally disabled by tool configuration.
- Blocked: permission policy or missing system permission blocks use.
- Unavailable: not registered, not installed, or otherwise unavailable.

## Reporter-Safe Export

The Advanced diagnostics **Export** button writes a Markdown report designed for issue reports. It
includes tool names, source/state, reason codes, indexing booleans, and token
estimates. It deliberately omits raw schemas, arguments, secrets, provider
URLs, manifest paths, and runtime paths.
