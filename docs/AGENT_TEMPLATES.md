# Agent Templates

An agent template is one agent's configuration as a portable JSON document. Users save them from Agents → Templates, share them as `.osaurustemplate` files, and start new agents from them. Templates flagged `available_to_orchestrator` can be used by the Orchestrator when a user asks for an agent "from the X template".

## Format

```json
{
  "format": "osaurus.template",
  "format_version": 1,
  "id": "0f5c1a4e-6b7d-4c1a-9a01-000000000001",
  "kind": "agent",
  "version": 1,
  "changelog": "Built-in template",
  "name": "Cloud Agent",
  "summary": "General-purpose worker on a cloud model.",
  "author": { "name": "Osaurus" },
  "created_at": "2026-09-16T00:00:00Z",
  "available_to_orchestrator": true,
  "requirements": {
    "models": [{ "slot": "main", "preferred": "sonnet-5", "strictness": "preferred" }]
  },
  "agent": {
    "name": "Cloud Agent",
    "description": "...",
    "system_prompt": "...",
    "model": "sonnet-5",
    "capabilities": { "tools_enabled": true, "memory_enabled": false },
    "tools": { "mode": "manual", "enabled": ["get_current_time", "web_search"] },
    "mcp_servers": { "enabled": ["Linear"], "disabled": ["Notion"] },
    "plugins": { "enabled": ["osaurus.notes"] },
    "plugin_instructions": { "osaurus.notes": "File everything under Work." },
    "sandbox": { "enabled": true, "network_enabled": false, "allowed_domains": [] },
    "subagents": { "enabled": true, "agents": ["Researcher"] },
    "working_folder": "~/Downloads/Medical Stuff"
  }
}
```

- `agent` is exactly one entry of the declarative config document's `agents` section (`Configuration/Declarative/OsaurusConfigDocument.swift`, `AgentEntry`). The same strict validator, planner, and applier run it, so unknown keys are rejected with did-you-mean.
- `requirements` records what the author's machine had (models, MCP servers, plugins, permissions, knowledge collections, working folder, secrets, network hosts). The import review lists it, and the setup wizard turns each gap into a step.
- `strictness` on a model requirement is `always` (setup blocks until that model is available) or `preferred` (fall back to the user's default with a notice).
- `id` + `version` + `content_hash` identify a template. A new id imports, a higher version is an update, an older one joins the history, and the same version with different content asks Keep both or Replace.
- `kind` must be `agent`; any other kind is rejected with a wrong-kind error.

## Portability rules

- References are names or stable string ids, never UUIDs. MCP servers by name, plugins by registry id, knowledge collections by name, subagents by agent name.
- `working_folder` is a path hint. The security-scoped bookmark never leaves the Mac. On apply the folder is attached only when it exists locally and a bookmark can be minted; otherwise the result is `needs_user_action` and the agent is flagged for setup.
- Relay exposure and knowledge collection ids are stripped when a template is made from a live agent.
- Secrets never appear. `TemplateExportSanitizer` removes saved answers, secret values, and absolute paths before a file is written.

## Where templates live

`TemplateStore` keeps every version in `~/.osaurus/template-library/<template-id>/v<N>.json`, with per-Mac preferences in `index.json`. Built-ins ship in `Resources/Templates/`. Whole-config YAML templates saved by `osaurus_config export --save_as` stay in `~/.osaurus/templates/`.

## Accepted import shapes

`Template.parse` accepts, in order:

1. the envelope above (JSON or YAML),
2. a full declarative document containing exactly one agent,
3. a bare agent entry (a mapping with `name`).

Cases 2 and 3 are wrapped into a template named after the agent. Files arrive only through Import Template (Choose File) or a drop on the Templates page. There is no link, clipboard, or paste path.

## Export

**Export File…** on a template card writes the sanitized template through a save panel as `<slug>-v<N>.osaurustemplate` (JSON). When this Mac has an Osaurus master key the file is signed (`TemplateSigner.signedWithMasterKey`, domain `Osaurus Signed Template`); a signature that does not finish leaves the file unsigned rather than unwritten. A signed file whose signature no longer verifies is shown in the import review but never imported.

## Orchestrator

`osaurus_config`:

- `templates` lists whole-config YAML templates and, under `agent_templates`, the agent templates shown to the Orchestrator (name, summary, model, tools, MCP servers, plugins, sandbox, subagents, requirements). Hidden templates are not listed.
- `plan` / `apply` with `template: "<name>"` resolve an agent template first, then fall back to a YAML template of that name. `overrides: {name, description, system_prompt, model}` merge on top of the template's agent. The plan carries a "Based on template: X" note and a reminder of the template's non-model requirements.
- Applying a hidden template fails with a message pointing at the Templates page.

## MCP server hints

`mcp_server_hints` (optional) says how to connect each MCP server the payload names: `directory_id`, `transport`, `url`, `auth`, `command`, `args`, `env_keys`, `header_keys`, `working_directory`. Only names of headers and environment variables travel, never values. The import review lists them under "How to connect its MCP servers". When sealed, a hint for a server the payload does not name is dropped. A template with no hints encodes without the key, so its hash is unchanged.

## First-run setup

Every agent creation path (create, duplicate, config apply, template use) marks the agent in `SetupStateStore`. The marker survives relaunch and is cleared only when `SetupChecker` finds nothing to fix or the user finishes the wizard.

`SetupChecker` reports the machine-local gaps a creator cannot grant on someone else's Mac: a working folder path with no usable bookmark, a pinned model that does not resolve, missing system permissions, knowledge on with no collection, and manual tools no server or plugin here provides.

Where it runs:

- `spawn_agent` refuses a flagged agent with blocking items (`kind: unavailable`) and posts a toast that opens the Agents tab. Advisory-only items let the run proceed. A clean check clears the marker.
- The first time a chat window shows a flagged agent, `AgentSetupPromptCoordinator` runs the check and shows a checklist alert with Set Up Now / Later. Clean agents clear silently.
- Use Template opens the wizard directly on an UNSAVED draft. Steps edit the draft in memory and Create Agent writes the agent only when no blocking item remains, so a template this Mac cannot honour never produces a broken agent.
- Agent cards show a Needs setup badge and a Run Setup menu item while the marker is set.

`AgentSetupWizardView` builds its steps from the report (Model, Working Folder, Knowledge, Tools, Permissions, Review), so an agent with one gap gets one step plus Review.

## Code map

- `Models/Template/Template.swift`, `Template+Agent.swift`, `TemplateRequirements.swift`, `MCPServerHint.swift`: envelope, parsing, `make(from:)`, `resolvedEntry`, requirements, server hints.
- `Services/Template/TemplateStore.swift`: on-disk library and built-ins.
- `Services/Template/TemplateSigner.swift`, `TemplateExportSanitizer.swift`: signing and the export scrub.
- `Services/Template/SetupStateStore.swift`, `SetupChecker.swift`, `Services/AgentSetupPromptCoordinator.swift`: first-run marker, readiness report, chat prompt.
- `Configuration/Declarative/AgentToolSelectionResolver.swift`: tool list ⇄ MCP/plugin groups.
- `Configuration/Declarative/ConfigApplier.draftAgent`: unsaved agent from an entry.
- `Views/Agent/Templates/`: Templates page, cards, save and rename sheets.
- `Views/Template/`: file export, import sheet and review, shared setup wizard parts.
- `Views/Agent/Setup/AgentSetupWizardView.swift`: the wizard.
- `Views/Agent/AgentsView.swift`: Templates button, Save as Template, Use Template, Run Setup.
- `Tools/SpawnAgentTool.setupRefusal`: the orchestrator-side gate.
