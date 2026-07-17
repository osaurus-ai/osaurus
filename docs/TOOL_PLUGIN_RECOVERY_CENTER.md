# Plugin and Tool Recovery Center

The Tools settings view shows a compact Plugin and Tool Recovery Center above
the exposure diagnostics when a plugin, tool, search index, MCP provider, or
remote provider has an actionable issue.

This is not a marketplace browser. It only explains capabilities already known
to the current registry, plugin install state, provider configuration, or typed
diagnostic fixtures.

## What It Surfaces

- Tool state: disabled, hidden, blocked, unavailable, loadable, or exposed.
- Permission state: user-denied tool policy and missing macOS permissions.
- Search state: stale or unavailable capability search index, including cases
  where smaller models can only see `capabilities_discover` / `capabilities_load`
  and need the index to recover a deferred tool.
- Plugin state: load failures, consent-required trust gates, stale manifests,
  declared-vs-loaded tool/provider mismatches, provenance, and scope.
- Provider state: disabled, auth-required, bad configuration, connectivity
  failures, sandbox issues, missing stdio commands, and explicit MCP probe
  failures.

## Safe Actions

Recovery actions are intentionally bounded:

- Rebuild capability search and re-run discovery.
- Recheck installed plugins and manifests.
- Open provider settings or reconnect/probe the expected MCP provider.
- Open macOS privacy settings for the named permission.
- Filter blocked rows so the user can review policy, owner, provenance, and
  scope before enabling anything.

The center does not silently enable tools, change deny policies, install
untrusted plugins, grant credentials, or treat same-named tools from another
owner as equivalent.

## Reporter-Safe Export

The recovery export includes subject names, statuses, reason codes, summaries,
and suggested safe actions. It redacts raw secrets, provider URLs, manifest
paths, runtime paths, and schema payloads.
