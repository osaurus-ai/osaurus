# Tool Exposure Control Center

The Tools settings view includes a Tool Exposure Control Center panel for
inspecting the tools registered in the current session.

The panel shows each session tool's source, exposure state, availability
reason, capability-search indexing state, global enablement, and estimated
schema token cost. Source and state filters use the same typed diagnostic data
that backs `capabilities_discover` miss explanations.

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
