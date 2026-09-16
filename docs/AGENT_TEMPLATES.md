# Agent Templates

An agent template is one agent's configuration as a portable JSON document. Users save them from the Agents → Templates tab, share them as text or files, and start new agents from them. Templates flagged `available_to_orchestrator` can be used by the Orchestrator when a user asks for an agent "from the X template".

## Format

```json
{
  "format": "osaurus.agent-template",
  "version": 1,
  "name": "Cloud Agent",
  "summary": "General cloud-backed worker with fetch and time",
  "author": "optional display name",
  "created_at": "2026-09-16T10:00:00Z",
  "available_to_orchestrator": true,
  "agent": {
    "name": "Cloud Agent",
    "description": "...",
    "system_prompt": "...",
    "model": "sonnet-5",
    "temperature": 0.7,
    "capabilities": { "tools_enabled": true, "memory_enabled": false },
    "tools": { "mode": "manual", "enabled": ["fetch", "time"] },
    "mcp_servers": { "enabled": ["Linear"], "disabled": ["Notion"] },
    "plugins": { "enabled": ["osaurus.notes"] },
    "plugin_instructions": { "osaurus.notes": "File everything under Work." },
    "sandbox": { "enabled": true, "network_enabled": false, "allowed_domains": [] },
    "subagents": { "enabled": true, "agents": ["Researcher"], "models": ["qwen3-coder-30b"] },
    "working_folder": "~/Downloads/Medical Stuff"
  },
  "requires": [
    { "kind": "working_folder", "value": "~/Downloads/Medical Stuff", "label": "Folder with invoice examples" },
    { "kind": "knowledge_collection", "value": "Clinical Guides" },
    { "kind": "plugin", "value": "osaurus.notes" },
    { "kind": "mcp_server", "value": "Linear" },
    { "kind": "system_permission", "value": "accessibility" },
    { "kind": "model", "value": "sonnet-5", "policy": "preferred" }
  ]
}
```

- `agent` is exactly one entry of the declarative config document's `agents` section (`Configuration/Declarative/OsaurusConfigDocument.swift`, `AgentEntry`). The same strict validator, planner, and applier run it, so unknown keys are rejected with did-you-mean.
- `requires` records what the author's machine had. Phase 1 shows it as a checklist on import and in the Create Agent sheet. The setup wizard (phase 2) turns each entry into a step.
- `policy` on a `model` requirement is `always` (setup blocks until the exact model is available) or `preferred` (fall back to the user's default with a notice).

## Portability rules

- References are names or stable string ids, never UUIDs. MCP servers by name, plugins by registry id, knowledge collections by name (inside `requires`), subagents by agent name.
- `working_folder` is a path hint. The security-scoped bookmark never leaves the Mac. On apply the folder is attached only when it exists locally and a bookmark can be minted; otherwise the result is `needs_user_action` and the agent carries no folder path, so it can never claim access it does not have.
- Relay exposure and knowledge collection ids are stripped when a template is made from a live agent.
- Secrets never appear. The schema has no secret-bearing fields.

## Where templates live

`~/.osaurus/templates/<slug>.json`, in the same directory as whole-config YAML templates saved by `osaurus_config export --save_as`. Slugs are lowercase, `[a-z0-9._-]`, and confined to the directory (symlinks are resolved before the prefix check). Files whose `format` is not `osaurus.agent-template` are ignored by the Templates tab and left alone.

## Accepted import shapes

`AgentTemplate.parse` accepts, in order:

1. the envelope above (JSON or YAML),
2. a full declarative document containing exactly one agent,
3. a bare agent entry (a mapping with `name`).

Cases 2 and 3 are wrapped into a template named after the agent.

## Orchestrator

`osaurus_config`:

- `templates` lists whole-config YAML templates and, under `agent_templates`, the agent templates flagged for the Orchestrator (name, summary, model, tools, MCP servers, plugins, sandbox, subagents, requires). Hidden templates are not listed.
- `plan` / `apply` with `template: "<name>"` resolve an agent template first, then fall back to a YAML template of that name. `overrides: {name, description, system_prompt, model}` merge on top of the template's agent. The plan carries a "Based on template: X" note and a reminder of the template's non-model requirements.
- Applying a hidden template fails with a message pointing at the Templates tab.

## Code map

- `Models/Agent/AgentTemplate.swift`: envelope, parsing, `make(from:)`, `resolvedEntry`.
- `Services/AgentTemplateStore.swift`: on-disk library.
- `Configuration/Declarative/AgentToolSelectionResolver.swift`: tool list ⇄ MCP/plugin groups.
- `Configuration/Declarative/ConfigApplier.draftAgent`: unsaved agent from an entry (sheet prefill).
- `Views/Agent/Templates/`: tab, cards, import/save/rename sheets.
- `Views/Agent/AgentsView.swift`: Agents | Templates switch, Save as Template, Use Template → prefilled Create Agent sheet.
