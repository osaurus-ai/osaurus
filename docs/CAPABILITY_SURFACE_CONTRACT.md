# Capability Surface Contract

Osaurus distinguishes three states that must never be presented as one:

1. **Configured** — the user's persisted selection.
2. **Effective** — configuration after global, agent, model, permission, and
   execution-mode gates.
3. **Callable** — a tool is in this request's schema and its runtime
   prerequisites are currently available.

`AgentCapabilityReadiness` is the presentation contract for that distinction.
It is read-only: it explains runtime state and never grants authority.

## Authoritative flow

1. Settings persist to `Agent`, `AgentSettings`,
   `DefaultAgentConfiguration`, `SubagentConfiguration`, and
   `ToolConfiguration`.
2. `AgentManager.effectiveCapabilities(for:)` resolves Default-versus-custom
   agent behavior and global memory state.
3. `AgentConfigSnapshot.capture(...)` freezes one turn's agent configuration.
4. `SystemPromptComposer.resolveToolset` resolves the exact request schema.
5. `SubagentToolVisibility` and `SpawnDescriptors.resolveForRequest` narrow
   model-backed helpers to enabled, installed, and runnable targets.
6. `ToolExecutionScope` is seeded from the final schema. `ToolRegistry.execute`
   refuses guessed or stale tools that the request did not expose.
7. Individual tools re-check durable authorization and runtime safety where
   their arguments select resources, targets, or side effects.

The native app chat and HTTP agent-run path must consume the same capability
snapshot and subagent visibility rules. Raw `/v1/chat/completions` is a
non-agentic surface and does not inherit an Osaurus agent's capabilities.

## Global gates

- `ChatConfiguration.disableTools` is an absolute tools kill switch.
- A custom agent's `toolsEnabled` switch pauses all of its tool-backed
  abilities. Sandbox execution may override only this per-agent switch for the
  sandbox primitives; it never overrides the global kill switch.
- Tiny context classes may remove the whole tool surface.
- Manual mode limits dynamic/plugin tools to the user's selection. Authoritative
  per-agent Browser Use, Computer Use, and delegation gates still apply.
- A configured value is preserved while paused or unavailable. The UI must show
  the blocker instead of displaying it as active.

## Built-in agent abilities

- Charts, Speak, Memory Recall, Web Search, Self-scheduling, Database, and
  Knowledge are custom-agent settings resolved through `AgentCapabilities`.
- Knowledge is callable only with at least one enabled granted collection.
- The built-in Default agent has its fixed configure-oriented baseline and
  native Web Search. It does not receive Browser Use or Computer Use.
- Folder and sandbox tools are session execution-mode capabilities, not
  persisted subagent toggles.

## Dynamic plugin, MCP, and skill capabilities

- `ToolConfiguration` and the per-agent allow-list decide which dynamic tools
  are enabled.
- `capabilities_discover` and `capabilities_load` operate only on loadable
  dynamic capabilities (plus the Default agent's deferred configure writes).
- The Enabled capabilities manifest describes loadable dynamic tools and
  installed skills. Always-injected gated built-ins are grounded by their live
  schema and capability-specific guidance; they must not be advertised as
  loadable when their authoritative flag is off.
- A disconnected MCP/provider tool is not callable merely because its persisted
  grant remains configured.

## Model-backed helper capabilities

### Browser Use

- Custom agents only.
- Requires Tools, `AgentSettings.browserUseEnabled`, and a resolvable parent or
  per-kind override model.
- `browser_use` is injected directly when effective. It is not discoverable or
  loadable through `capabilities_load`.
- Web Search, Browser Use, and Computer Use opening a desktop browser are
  separate capabilities.

### Computer Use

- Custom agents only.
- Requires Tools, `AgentSettings.computerUseEnabled`, a resolvable model, and
  Accessibility permission at execution.
- Screen context is subordinate to Computer Use.

### Spawn

- Default agent: configured by the main-chat pools in
  `SubagentConfiguration`.
- Custom agent: requires `spawnDelegationEnabled` and its own pool.
- At least one target must be runnable. Missing local models, deleted agents,
  disconnected providers, self-only pools, and cold target discovery remain
  visible for repair but are not advertised to the model.
- `.deny` remains persisted and is shown as unavailable; execution also
  enforces permissions, allow-lists, RAM admission, residency, budgets, and
  cancellation.

### Image

- Default agent uses `SubagentConfiguration.imageDelegationEnabled`; custom
  agents use `AgentSettings.imageEnabled`.
- Requires an installed ready generation or edit model. The schema narrows to
  generation-only when no edit model is ready.
- Permission and residency policy are enforced at execution.

### AppleScript

- Default agent uses `SubagentConfiguration.appleScriptDelegationEnabled`;
  custom agents use `AgentSettings.appleScriptEnabled`.
- Requires an installed curated AppleScript model.
- Script execution mode, macOS Automation consent, read/write classification,
  and residency policy remain execution-time gates.

## Readiness states

- **Active**: configured and callable under the current preview.
- **Paused**: configuration is valid but a broad switch currently suppresses
  it, such as Tools off or context auto-disable.
- **Needs setup**: the user must select or install a prerequisite.
- **Unavailable**: configuration exists but current runtime truth blocks it,
  such as no runnable targets, a disconnected provider, denied policy, missing
  system permission, or an unsupported surface.
- **Disabled**: not configured.

Request composition remains the final authority. Readiness UI must be derived
from the same stores and resolvers and may never be used as an authorization
shortcut.
