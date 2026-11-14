# Agent Templates

An agent template is one agent's configuration as a portable JSON document. Users save them from the Agents → Templates tab, share them as files or publish them to store.osaurus.ai, and start new agents from them. Templates flagged `available_to_orchestrator` can be used by the Orchestrator when a user asks for an agent "from the X template".

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
    "tools": { "mode": "manual", "enabled": ["get_current_time", "web_search"] },
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

`TemplateStore` keeps every version in `~/.osaurus/template-library/<template-id>/v<N>.json`, with per-Mac preferences in `index.json` and what this Mac published in `registry.json` (`WorkflowRegistryRecordStore`). Whole-config YAML templates saved by `osaurus_config export --save_as` stay in `~/.osaurus/templates/`.

## Accepted import shapes

`AgentTemplate.parse` accepts, in order:

1. the envelope above (JSON or YAML),
2. a full declarative document containing exactly one agent,
3. a bare agent entry (a mapping with `name`).

Cases 2 and 3 are wrapped into a template named after the agent.

## Installing from the command line

Installers can pre-load agents without the import sheet: an Osaurus bundle is a folder of agent files in any of the shapes above, plus skills and MCP servers, installed with `osaurus import install --from <folder>`. The CLI queues the bundle and the app applies it at launch (or right away when running) through the same parser, planner, and applier. Agent files in a bundle must be JSON, and an envelope needs its top-level `name`. See the [Osaurus Bundles guide](OSAURUS_BUNDLES.md).

## Orchestrator

`osaurus_config`:

- `templates` lists whole-config YAML templates and, under `agent_templates`, the agent templates flagged for the Orchestrator (name, summary, model, tools, MCP servers, plugins, sandbox, subagents, requires). Hidden templates are not listed.
- `plan` / `apply` with `template: "<name>"` resolve an agent template first, then fall back to a YAML template of that name. `overrides: {name, description, system_prompt, model}` merge on top of the template's agent. The plan carries a "Based on template: X" note and a reminder of the template's non-model requirements.
- Applying a hidden template fails with a message pointing at the Templates tab.

## Opening a file from outside the app

Templates travel as `.osaurustemplate` files (exported type `ai.osaurus.template`, which conforms to `public.json`; Osaurus is its owner in `Info.plist`). `TemplateImportRouter` brings one to the import sheet of the tab that owns its kind (workflow to Workflows, agent to Agents → Templates). It handles three entry points:

- A file opened from Finder (double-click, Open With, a drop on the Dock icon), through `AppDelegate.application(_:open:)`.
- `osaurus://templates-import?url=<registry template URL>`, the **Install agent** / **Install workflow** button on a store.osaurus.ai page. Only versioned template files on the configured registry are accepted (`WorkflowsRegistryAPIClient.isRegistryTemplateURL`); the file is downloaded with a 2 MB cap, and the sheet shows the host it came from. After the import is confirmed, `WorkflowShareService.recordInstall` sends the signed install receipt. For an agent, `recordAgentInstall` sends the agent's receipt, then reads the agent's detail and sends one for each bundled workflow the import added to the library whose page the agent links to (`workflows[].listing`), at the bundled version or that page's newest when the copy is newer, all with one key read. Best effort: a failed read or receipt never touches the import.
- A file dropped on the other tab's import sheet.

Each sets `ManagementStateManager.pendingTemplateImport`. The review sheet always shows, so nothing is saved until the user confirms.

## Publishing

A template in the user's library publishes the same way a workflow does: its card's footer has the shared `ShareFooterButton` (**Share**, or **Live · … installs** once published, opening the dashboard), and its **…** menu has **Save as File…** and **Publish…**, all through `ShareWorkflowSheet` and `WorkflowShareService`. Built-ins show **Export** instead. Save as Template ends on a Saved state whose **Share…** sets `ManagementStateManager.pendingTemplateShare`; `AgentsView` switches to Templates and `AgentTemplatesView` opens Share for it. Above the grid, `PublishedByYouLine` (shared with Workflows) shows the published count, installs, and the author page link, and `AgentTemplateFilter` chips (All, Published, Built-in, Yours) narrow the grid once anything is published or more than eight templates exist. The upload is the sanitized, sealed template signed with the Osaurus ID; workflows the agent uses travel inside it as `bundled` templates and are validated with it. The registry stores the listing with `kind = agent` and pages it at `/a/<slug>`.

Publishing an agent cascades to its workflows (`WorkflowShareService.shareAgent`). `TemplateCascadePlan.make` sorts each `bundled` template into `.alreadyPublished(record)` (live at that version or newer), `.willPublish` (yours: no author address or this Osaurus ID's, not live yet or live at an older version), `.linkedToAuthor(address)` (another Osaurus ID's address, signed or not, so an edit that dropped their signature still isn't republished under your name), or `.bundledOnly(reason)` (password-protected agent, built-in, taken down, removed by the Osaurus team, or the **Give my workflows their own pages** toggle off). With one key read, the `.willPublish` ones upload first with the agent's visibility (`inheritedVisibility`: Public and Unlisted carry over, Password publishes none), each record stamped `publishedWith` = the agent's template id, then the agent. A workflow that fails is reported in `WorkflowShareOutcome.cascade` and doesn't stop the agent. The registry's `listing_links` then link the agent to each workflow listing: the same owner's by template id, another owner's only when the bundled copy's recomputed content hash equals one of that listing's versions. Agent pages show **Its own page** on a linked workflow, and workflow pages list **Used by agents**; links only point at what the page's visitors may see. Changing the agent's visibility in its dashboard offers **Also change its workflows** (`TemplateCascadePlan.visibilityFollowers`: live records with `publishedWith` = the agent, not password-protected on their own, not already at the inherited visibility; none for Password), and `WorkflowShareService.setAgentVisibility` changes the agent and then each of them with one key read, reporting the ones that fail. Taking the agent down leaves the workflow pages up: the agent's dashboard lists them under **Workflows it brings** (`TemplateCascadeViews.swift`) with their own **Take Down…**, and a workflow's dashboard and card say which agent its page came with. Records keep the kind, so the Workflows page's published summary counts only workflows and reconcile rebuilds agent listings too. Built-in templates export as a file only; Save to Library makes a publishable copy.

## MCP server hints

`mcp_server_hints` (optional) says how to connect each MCP server the payload names: `directory_id`, `transport`, `url`, `auth`, `command`, `args`, `env_keys`, `header_keys`, `working_directory`. Only names of headers and environment variables travel, never values. Export fills hints from this Mac's servers when **Include how to connect my MCP servers** is on. `TemplateExportSanitizer` strips URL user info, credential-named query items, and credential-looking path segments and arguments (they become `YOUR_KEY`). When sealed, a hint for a server the payload does not name is dropped. A template with no hints encodes without the key, so its hash is unchanged.

On import, `MCPServerResolution` decides what each template server means on this Mac. It tries, in order: the install binding, a configured server with the same name (ignoring case and punctuation) or the same endpoint or command, an MCP Directory entry, then the hint. Setup cards offer the matching action. A server bound under another name has its tools rewritten to that server's prefix before setup checks and runs (`MCPServerResolution.applying`).

## First-run setup

Every agent creation path (create, duplicate, config apply, bundle import, backup restore, template use) marks the agent in `AgentSetupStateStore` (`~/.osaurus/agents/setup-pending.json`). The marker survives relaunch and is cleared only when `AgentSetupChecker` finds nothing to fix or the user finishes the wizard.

`AgentSetupChecker` reports the machine-local gaps a creator cannot grant on someone else's Mac: a working folder path with no usable bookmark (blocking), a pinned model that does not resolve (blocking), Computer Use without Accessibility (blocking), knowledge on with no collection (advisory), AppleScript without Automation (advisory), manual tools no server or plugin here provides (advisory).

Where it runs:

- `spawn_agent` refuses a flagged agent with blocking items (`kind: unavailable`, `needs_user_action` metadata, not retryable) and posts a toast that opens the Agents tab. Advisory-only items let the run proceed. A clean check clears the marker so later spawns cost nothing.
- The first time a chat window shows a flagged agent, `AgentSetupPromptCoordinator` runs the check and shows a checklist alert with Set Up Now / Later. Clean agents clear silently and never see a prompt.
- Use Template opens the wizard directly on an UNSAVED draft. Steps edit the draft in memory and the primary button (Create Agent) writes the agent only when no blocking item remains, so a template this Mac cannot honour never produces a broken agent. A `preferred` template's missing model shows as an advisory Brain step with Use Default Model; `always` blocks. The Review step carries the agent name and a summary of what will be created; everything else is edited after creation. The Model step is a Default Model dropdown or one contextual action (Download for a local id, Configure Provider for a cloud one).
- Agent cards show a Needs setup badge and a Run Setup menu item while the marker is set.

`AgentSetupWizardView` builds its steps from the report (Brain, Working Folder, Knowledge, Tools, Permissions, Review), so an agent with one gap gets one step plus Review. Each step fixes in place: pick or reset the model or open Local Models / Providers, choose the folder (mints the bookmark), grant or create a knowledge collection, open MCP Servers / Plugins or drop the missing tool names, open System Settings for the permission and re-check when the app becomes active. Finish clears the marker only when no blocking item remains; Later keeps the agent and the marker (plan test case 34).

## Code map

- `Models/Agent/AgentTemplate.swift`: envelope, parsing, `make(from:)`, `resolvedEntry`.
- `Services/AgentTemplateStore.swift`: on-disk library.
- `Configuration/Declarative/AgentToolSelectionResolver.swift`: tool list ⇄ MCP/plugin groups.
- `Configuration/Declarative/ConfigApplier.draftAgent`: unsaved agent from an entry (sheet prefill).
- `Views/Agent/Templates/`: tab, cards, import/save/rename sheets.
- `Views/Agent/AgentsView.swift`: Agents | Templates switch, Save as Template, Use Template → prefilled Create Agent sheet.
- `Services/AgentSetupStateStore.swift`, `Services/AgentSetupChecker.swift`, `Services/AgentSetupPromptCoordinator.swift`: first-run marker, readiness report, chat prompt.
- `Views/Agent/Setup/AgentSetupWizardView.swift`: the wizard.
- `Tools/SpawnAgentTool.setupRefusal`: the orchestrator-side gate.
- `Services/Template/TemplateImportRouter.swift`: Finder files and `osaurus://templates-import?url=` links to the import sheet.
- `Services/Template/MCPServerResolution.swift`, `Models/Template/MCPServerHint.swift`: template server names to servers here, and the hints that set them up.
- `Services/Template/TemplateShareOptions.swift`, `Views/Template/ShareWorkflowSheet.swift`: export suggestions, signing, preview, and publishing.
- `Services/Template/WorkflowShareService.swift`, `WorkflowsRegistryAPIClient.swift`, `WorkflowRegistryRecordStore.swift`: the registry client, signed requests, and what this Mac published.
- `Services/Template/TemplateCascadePlan.swift`, `Views/Template/TemplateCascadeViews.swift`: what publishing an agent does for its bundled workflows, and the rows that show it.
