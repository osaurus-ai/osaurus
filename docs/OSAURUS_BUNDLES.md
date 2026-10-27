# Osaurus Bundles

An **Osaurus bundle** lets you ship a ready-made Osaurus setup with your own installer. Your script installs Osaurus, stores your secrets in the user's Keychain, and runs `osaurus import install`. The first time the user opens Osaurus, your agents, skills and MCP servers are already there and working.

This guide is for third-party developers who package Osaurus for their users: IT teams, product vendors, consultants. You don't need to know the Osaurus source. You do need a Mac with Osaurus installed to test on, and basic shell scripting.

A complete working example lives in [`docs/examples/osaurus-bundle-example/`](examples/osaurus-bundle-example/). Every section below points at the matching file.

Contents:

1. [What a bundle is](#1-what-a-bundle-is)
2. [Quick start](#2-quick-start)
3. [Bundle layout and manifest reference](#3-bundle-layout-and-manifest-reference)
4. [Agent file reference](#4-agent-file-reference)
5. [Skill folder reference](#5-skill-folder-reference)
6. [MCP server reference](#6-mcp-server-reference)
7. [Secrets, step by step](#7-secrets-step-by-step)
8. [Writing the installer script](#8-writing-the-installer-script)
9. [Updating and uninstalling](#9-updating-and-uninstalling)
10. [What the user sees](#10-what-the-user-sees)
11. [Verifying and troubleshooting](#11-verifying-and-troubleshooting)
12. [Security checklist for authors](#12-security-checklist-for-authors)
13. [Reference](#13-reference)

---

## 1. What a bundle is

A bundle is a folder with an `osaurus-bundle.json` manifest at its root. It can contain five kinds of items:

- **Agents**: custom agents with their prompt, model, capability switches, skill allow-list, exact tool list, MCP servers, sandbox and network settings, and the runtime they run on.
- **Skills**: [Agent Skills](https://agentskills.io/) folders (`SKILL.md` plus optional `references/` and `assets/`).
- **MCP servers**: HTTP or stdio MCP servers your agents use, with their credentials given as Keychain references.
- **Harness runtimes**: external agent harnesses (Claude Code, Pi, or your own Pi-based CLI) that run an agent's chats instead of Osaurus's own loop ([section 6a](#6a-harness-runtime-reference)).
- **Settings**: a short list of Osaurus server settings, such as requiring an access key from apps on this Mac ([Settings](#settings)).

A bundle **can't** contain these. Each has its own path, covered in [section 8](#8-writing-the-installer-script):

| Not in a bundle | Use instead |
| --- | --- |
| Plugins | `osaurus tools install <plugin-id> --consent` in your script |
| Models | `strictness: preferred` so the agent falls back to the user's model, or `osaurus pull <model-id>` in your script |
| Raw secrets | Keychain items your script creates; the bundle holds only `keychain:SERVICE/ACCOUNT` references |
| Settings not in the [list](#settings) | Not provisioned by bundles. Users change them in Settings. |

**How it works.** `osaurus import` checks the bundle and copies the parts it needs into `~/.osaurus/import/pending/`. It never launches Osaurus. If Osaurus is running, the command asks it to apply the import right away. Otherwise Osaurus applies the queue the next time it opens. Either way, Osaurus records what your bundle installed, so later updates and removals touch only your items.

**Not the same as `.mcpb` files.** `osaurus bundle load` runs `.mcpb` MCP bundles (one MCP server packaged as a file). Osaurus bundles are a different, provisioning-only format handled only by `osaurus import`.

## 2. Quick start

1. Copy the example bundle:

   ```bash
   cp -R docs/examples/osaurus-bundle-example ~/acme-bundle
   cd ~/acme-bundle
   ```

2. Edit two files:
   - `osaurus-bundle.json`: change `id` to your reverse-DNS id (for example `com.yourcompany.starter`), `name`, `version` and `publisher`. Keep or delete the example MCP servers.
   - `agents/support-desk.json`: change the agent's `name`, `description` and `system_prompt`.

   If you delete an MCP server, delete the agent tools and `mcp_servers.enabled` entries that use it, and its secret from `install.sh`.

3. Check the bundle. Open Osaurus first, so the check includes the app's strict schema check:

   ```bash
   CLI=/Applications/Osaurus.app/Contents/Helpers/osaurus
   "$CLI" import validate --from ~/acme-bundle
   ```

4. Install it. The example's `install.sh` asks for its three secrets when run in a terminal:

   ```bash
   ~/acme-bundle/install.sh
   ```

   Or by hand, after storing the secrets ([section 7](#7-secrets-step-by-step)):

   ```bash
   "$CLI" import install --from ~/acme-bundle --yes
   ```

5. Open Osaurus. A toast says your agents are ready, and they appear under **Agents**.

## 3. Bundle layout and manifest reference

Layout of the example bundle:

```
osaurus-bundle-example/
├── osaurus-bundle.json          # the manifest
├── agents/
│   ├── support-desk.json        # agent template envelope
│   └── release-checker.json     # bare agent entry
├── skills/
│   └── triage-ticket/
│       ├── SKILL.md
│       └── references/priority-matrix.md
├── install.sh                   # your installer (not read by Osaurus)
└── uninstall.sh
```

Only the manifest and the files it lists are copied into the queue. Your scripts and any other files stay where they are, and you can delete the bundle folder as soon as `osaurus import` returns.

### The manifest

[`osaurus-bundle.json`](examples/osaurus-bundle-example/osaurus-bundle.json):

```json
{
  "format": "osaurus.bundle",
  "format_version": 1,
  "id": "com.example.acme-support",
  "name": "Acme Support Starter",
  "version": "1.0.0",
  "description": "Two starter agents for the Acme support team...",
  "publisher": { "name": "Acme Example", "url": "https://acme.example", "email": "it@acme.example" },
  "min_osaurus_version": "0.26.0",
  "skills": [{ "name": "triage-ticket", "path": "skills/triage-ticket" }],
  "mcp_servers": [{ "name": "Acme Tickets", "transport": "http", "url": "https://mcp.acme.example/mcp", "...": "..." }],
  "harness_runtimes": [{ "name": "Acme Pi", "kind": "pi_rpc", "executable": "pi", "...": "..." }],
  "agents": [{ "path": "agents/support-desk.json" }, { "path": "agents/release-checker.json" }, { "path": "agents/acme-coder.json" }]
}
```

| Key | Type | Required | Meaning |
| --- | --- | --- | --- |
| `format` | string | yes | Always `"osaurus.bundle"`. |
| `format_version` | integer | yes | Always `1`. A higher number needs a newer Osaurus and is refused. |
| `id` | string | yes | Reverse-DNS id, like `com.acme.starter`: at least two dot-separated parts of letters, digits and hyphens. |
| `name` | string | yes | Shown to the user in the launch toast and in `osaurus import list`. |
| `version` | string | yes | Semantic version, like `1.2.0`. |
| `description` | string | no | For your own records. |
| `publisher` | object | no | `name` (required inside the object), `url`, `email`. |
| `min_osaurus_version` | string | no | Oldest Osaurus that may install this bundle, like `0.26.0`. The CLI compares it with the installed app's version and refuses an older app. |
| `skills` | array | no | `{ "name", "path" }`. `path` is a folder relative to the bundle root. |
| `mcp_servers` | array | no | MCP server entries, written inline ([section 6](#6-mcp-server-reference)). |
| `harness_runtimes` | array | no | Harness runtime entries, written inline ([section 6a](#6a-harness-runtime-reference)). |
| `agents` | array | no | `{ "path" }`. `path` is a JSON file relative to the bundle root ([section 4](#4-agent-file-reference)). |
| `settings` | object | no | Osaurus settings to change, by key ([Settings](#settings)). |

At least one of `skills`, `mcp_servers`, `harness_runtimes`, `agents` or `settings` must list something. Unknown keys are rejected with a did-you-mean hint, so a typo fails `validate` instead of being silently ignored.

**Paths** must be relative and stay inside the bundle folder. Absolute paths, `~` paths, and paths that leave the folder through `..` or a symbolic link are refused. Each JSON file (the manifest and each agent file) is capped at 512 KB.

**The `id` is your ownership key.** Osaurus remembers which bundle id installed each item. A bundle can update and remove only the items installed under its own id, and never touches the user's own items or another bundle's. Pick an id once and never change it. A new id is treated as a different bundle, and its items conflict with the old ones by name.

**Versioning.** Bump `version` for every release you ship. `update` skips any item whose installed version is newer than the one you offer, so a stale installer can't downgrade a user. Within the same version, Osaurus compares content: an unchanged item reports `unchanged` and is not rewritten.

### Settings

The `settings` object changes Osaurus settings while the bundle installs. Only these keys are accepted; anything else fails `validate` with a did-you-mean hint.

| Key | Value | The control in Osaurus | What installing does |
| --- | --- | --- | --- |
| `require_local_access_key` | `true` or `false` | Server → Settings → Authentication → **Require Access Key for Local Admin Routes** | Turns it on or off. On, apps and scripts on this Mac need an access key for `/sessions`, `/agents`, `/mcp/*`, `/admin/config/*` and `/admin/import/*`, and browser pages are refused there unless their origin is in Allowed Origins. |
| `allowed_origins` | list of origins, like `["https://app.acme.example"]` | Server → Settings → Connection → **Allowed Origins (CORS)** | Adds your origins to the user's list. It never removes one. Osaurus restarts its server to use the new list. |

```json
"settings": {
  "require_local_access_key": true,
  "allowed_origins": ["https://app.acme.example"]
}
```

- **Origins** are written the way browsers send them: lowercase `https://host` or `http://host:port`, with no path, no trailing slash and no `*`.
- **High risk.** Settings that loosen security need `--yes` and are listed under `risks`: `require_local_access_key: false`, and every origin in `allowed_origins`. Turning the access key on is not high risk, but it changes what apps on the user's Mac can reach. Ship it only when your setup needs it.
- **No access key yet.** Bundles can't create access keys. If `require_local_access_key: true` applies when the user has no key, the item reports `needs_user_action` (exit code `3`): local apps lose access to those routes until the user creates a key in Server → Overview.
- **Shared values.** Settings belong to the user, not to your bundle. Osaurus records what you asked for so later updates respect the user:
  - `install` always sets the value.
  - `update` leaves a setting the user changed since your bundle set it (`skipped`, "Changed in … since … set it").
  - If another bundle turned `require_local_access_key` the other way, the item fails with a conflict.
  - `remove` leaves settings as they are.
- **Live imports with the key on.** Once Require Access Key for Local Admin Routes is on, `osaurus import` needs `--access-key KEY` (or `OSAURUS_API_KEY`) to apply an import while Osaurus is running. Without one, the import is queued (exit code `0`, with a warning) and applies the next time Osaurus opens.

## 4. Agent file reference

Each agent is one JSON file in one of these shapes:

1. **A template envelope** like [`agents/support-desk.json`](examples/osaurus-bundle-example/agents/support-desk.json), the same format Osaurus exports from Agents → Templates. Use it when you want model requirements or quick actions. It **must** have `"format": "osaurus.template"` and a top-level `name` (the template's name; use the agent's name).
2. **A bare agent entry** like [`agents/release-checker.json`](examples/osaurus-bundle-example/agents/release-checker.json): just the agent object.
3. A config document with exactly one agent (`{ "agents": [ { ... } ] }`).

Agent names must be unique within a bundle. JSON only: agent files are not YAML.

### Envelope keys

```json
{
  "format": "osaurus.template",
  "format_version": 1,
  "kind": "agent",
  "version": 1,
  "name": "Support Desk",
  "summary": "Triages and answers Acme support tickets.",
  "author": { "name": "Acme Example" },
  "requirements": {
    "models": [{ "slot": "main", "preferred": "foundation", "strictness": "preferred" }]
  },
  "actions": [
    { "icon": "tray.full", "text": "Triage my queue", "prompt": "Find my open Acme tickets and triage the five oldest." }
  ],
  "agent": { "name": "Support Desk", "...": "..." }
}
```

- `requirements.models[0].strictness`: `preferred` (the default) means that if the agent's `model` isn't available on this Mac, the agent uses the user's default model and the result says so. `always` means the agent keeps its model, and Osaurus asks the user to download or choose one before it runs (the item reports `needs_user_action`).
- `actions`: quick-action chips shown in the agent's empty chat. `icon` is an SF Symbol name.

### Agent keys

All keys except `name` are optional. These are the ones a bundle is likely to use. The full schema is the `agents` section of the declarative config (`osaurus config export` shows a live example).

```json
{
  "name": "Support Desk",
  "description": "Triages, prioritizes and drafts replies for Acme support tickets.",
  "system_prompt": "You are Acme's support desk assistant...",
  "model": "foundation",
  "temperature": 0.3,
  "max_tokens": 4096,
  "capabilities": {
    "tools_enabled": true,
    "memory_enabled": true,
    "web_search_enabled": false
  },
  "skills": ["triage-ticket"],
  "tools": {
    "mode": "manual",
    "enabled": ["get_current_time", "acme_tickets_search_tickets", "acme_tickets_get_ticket"]
  },
  "mcp_servers": { "enabled": ["GitHub"] },
  "plugins": { "enabled": ["osaurus.fetch"] },
  "plugin_instructions": { "osaurus.fetch": "Only fetch acme.example pages." },
  "sandbox": { "enabled": true, "network_enabled": true, "allowed_domains": ["api.acme.example"] },
  "subagents": { "enabled": true, "agents": ["Release Checker"] },
  "working_folder": "~/Documents/Acme"
}
```

| Key | Meaning |
| --- | --- |
| `name` | The agent's name, and how Osaurus matches it on update. |
| `description` | One line the Orchestrator uses to decide when to delegate to this agent. Generated from the prompt when omitted. |
| `system_prompt` | The agent's instructions. |
| `model` | `foundation` (Apple's on-device model), a local model id, or `<provider>/<model>` for a cloud provider the user has set up. Omit it to use the user's current model. See `strictness` above. |
| `temperature`, `max_tokens` | Sampling overrides. Omit them to use the model's own defaults. |
| `capabilities` | Per-agent switches: `tools_enabled`, `memory_enabled`, `search_memory_enabled`, `web_search_enabled`, `knowledge_enabled`, `db_enabled`, `self_scheduling_enabled`, `computer_use_enabled`, `browser_use_enabled`, `image_enabled`, `applescript_enabled`, `speak_enabled`, `render_chart_enabled`, `relay_enabled`, and `apple_apps` (a list such as `["calendar", "reminders"]`). |
| `skills` | The skill allow-list (below). |
| `tools` | `mode: manual` with `enabled` is the exact tool list (below). `mode: auto` lets Osaurus pick tools per message. |
| `mcp_servers` | `enabled` gives the agent **every** tool of the named servers; `disabled` removes them. |
| `plugins` | The same, for plugins, by registry id. |
| `sandbox` | `enabled` turns on sandboxed code execution. `network_enabled` controls network access from the sandbox, and `allowed_domains` narrows it to a list. Also `max_commands_per_turn`, `background_process_enabled`, `plugin_create`. |
| `subagents` | Whether this agent may delegate, and to which agents (by name). |
| `orchestrator_spawnable` | `false` keeps the agent out of the Orchestrator's delegation list (Settings → Orchestrator → Subagents → Allowed subagents) when the bundle creates it. Omitted or `true`, the agent joins the list as usual. It only applies at creation: an update leaves the list alone, so an agent the user added by hand stays added. Use it to ship agents in later bundle updates without needing `osaurus config` to take them out of the list. |
| `runtime` | `builtin` (Osaurus's own loop, the default) or a harness runtime's name: one from this bundle, or one already registered on the Mac such as `Claude Code`. |
| `claude_code` | For an agent on a Claude Code runtime: `model` (`sonnet`, `opus`, `haiku` or a full model id), `mode` (`agent` or `text_only`), `allow_writes`, `allow_shell`, `allow_osaurus_tools`. |
| `working_folder` | A path hint. macOS needs the user to grant folder access, so Osaurus asks the user to pick the folder the first time (the item reports `needs_user_action`) unless it can attach it on its own. |

**How names resolve.** Agents, skills, MCP servers and harness runtimes are referenced by name (case-insensitive; skills also by slug). Plugins are referenced by registry id. A name that isn't in your bundle must already exist on the Mac. `validate` warns about these.

### The skill allow-list (`skills`)

By default an agent can use every skill installed in Osaurus. `skills` limits it:

| Value | Effect |
| --- | --- |
| key omitted | Leave the agent's list unchanged (all skills for a new agent). |
| `null` | Every installed skill. |
| `["triage-ticket"]` | Only these skills, by name or slug. |
| `[]` | No skills. |

Only allowed skills appear in the agent's prompt, in `capabilities_load`, and as its slash commands. Installing an agent installs the skills it lists from the same bundle. A listed skill that isn't installed is shown as **not installed** in the agent's editor and starts working once it is installed.

Built-in Osaurus skills can be listed by slug: `web-researcher`, `content-summarizer`, `mac-automator`, `personal-organizer`, `document-builder`, `workspace-assistant`, `data-keeper`, `autonomous-scheduler`, `data-visualizer`. Use the slug, not the display name: display names are translated, slugs are the same in every language.

Users can change the list later in **Agents → (agent) → Abilities → Tools → Limit to selected skills**.

### The exact tool list (`tools`)

With `"mode": "manual"`, `tools.enabled` is the exact set of tools the agent may call:

- **Built-in tools** by name, for example `get_current_time`, `web_search`, `render_chart`.
- **MCP tools** by the name Osaurus gives them: the server name in lowercase with spaces and hyphens turned into underscores, then `_` and the server's own tool name. A tool `search_tickets` on the server `Acme Tickets` is `acme_tickets_search_tickets`. Check the exact names in Settings → Tools & MCP after connecting the server once, or in `osaurus config export`.

Use `mcp_servers.enabled` when the agent should get all of a server's tools. Use exact names in `tools.enabled` when it should get only some of them. Listing a server's tools by name also makes that server a dependency, so installing the agent installs the server too.

The two behave differently while a server isn't connected yet (still starting, or waiting for a secret):

- An exact tool name is kept on the list and works once the server connects.
- `mcp_servers.enabled` adds the tools the server has at the moment the agent is applied. A server that isn't connected has none to add, so the agent gets none of its tools, and the result says "Not connected yet" and asks for user action. Run `osaurus import update` after the server connects (for example, after its secret is stored). The same applies to tools a server adds in a later version of its own.

If your installer can't guarantee the server is connected when `install` runs, list the tools by exact name.

`osaurus config export` shows the result the same way: a server whose tools are all enabled under `mcp_servers.enabled`, and a partly enabled server as exact names under `tools.enabled`.

### Sandbox and network

```json
"sandbox": { "enabled": true, "network_enabled": false }
```

The example's *Release Checker* runs scripts in the sandbox with no network. With `network_enabled: true`, add `allowed_domains` to limit which hosts the sandbox can reach. On macOS 26 and later the sandbox is a Linux VM; on earlier macOS it falls back to a macOS sandbox with all-or-nothing network access (see [Sandbox](SANDBOX.md)).

## 5. Skill folder reference

A skill is a folder with a `SKILL.md` ([`skills/triage-ticket/SKILL.md`](examples/osaurus-bundle-example/skills/triage-ticket/SKILL.md)):

```markdown
---
name: triage-ticket
description: Triage an Acme support ticket - set priority, area and next step using Acme's priority matrix.
version: 1.0.0
author: Acme Example
---

# Triage a ticket

Use this when the user asks you to triage, prioritize or sort support tickets.
...
```

- `name` is required and must match the manifest's `skills[].name` by slug (`triage-ticket`, `Triage Ticket` and `triage_ticket` all match). Osaurus shows it as a title, so `triage-ticket` appears as "Triage Ticket".
- `description` is strongly recommended: agents pick skills by it. `validate` warns when it's missing.
- `references/` holds text files loaded into context with the skill. `assets/` holds supporting files.
- Limits: 512 files, 10 MB per file, 50 MB in total, 16 folders deep, plain files only (no symbolic links).

The skill is installed into `~/.osaurus/skills/<slug>/`.

**Name collisions.** If the user already has a skill with the same name (or slug) that your bundle didn't install, the import refuses that skill rather than overwrite it. A skill named like a built-in or plugin skill is refused too. Choose distinctive names, for example prefixed with your product (`acme-triage`).

## 6. MCP server reference

MCP server entries go inline in the manifest's `mcp_servers` array.

**HTTP** (remote servers):

```json
{
  "name": "Acme Tickets",
  "transport": "http",
  "url": "https://mcp.acme.example/mcp",
  "auth": "bearer",
  "token_ref": "keychain:com.example.acme-support/tickets-token",
  "secret_header_refs": { "X-Acme-Workspace-Key": "keychain:com.example.acme-support/tickets-workspace-key" }
}
```

- `auth`: `none`, `bearer` (send `token_ref` as `Authorization: Bearer …`) or `oauth` (the user signs in once in Osaurus; see [section 7](#oauth-servers)).
- `secret_header_refs`: custom headers that carry a secret, header name → reference.
- Use `https://` URLs.

**stdio** (a local process):

```json
{
  "name": "GitHub",
  "transport": "stdio",
  "command": "npx",
  "args": ["-y", "@modelcontextprotocol/server-github"],
  "env": { "GITHUB_API_URL": "https://api.github.com" },
  "secret_env_refs": { "GITHUB_PERSONAL_ACCESS_TOKEN": "keychain:com.example.acme-support/github-token" },
  "execution_host": "sandbox"
}
```

- `command`, `args`, `env` (non-secret environment), `working_directory`.
- `secret_env_refs`: environment variables that carry a secret, variable name → reference.
- `execution_host`: `sandbox` (the default) runs the process inside the Osaurus sandbox. `host` runs it directly on the Mac, outside the sandbox.
- `enabled: false` installs the server switched off.

**Why `--yes` is needed.** Adding an MCP server is a high-risk change: it connects Osaurus to a new endpoint or launches a local process, and `execution_host: host` runs it outside the sandbox. Every harness runtime is high-risk, and so is an agent that runs on one or turns on `computer_use_enabled`, `browser_use_enabled`, `relay_enabled` or `claude_code.allow_shell`. `osaurus import install` lists these under `risks` and refuses until you pass `--yes`, the same rule as `osaurus config apply`. Passing `--yes` in your script is your confirmation on the user's behalf. Keep the list short ([section 12](#12-security-checklist-for-authors)).

The `transport` of an installed server can't change. To move a server from stdio to HTTP, give it a new name.

## 6a. Harness runtime reference

A harness runtime is an external agent harness that runs an agent's chats in place of Osaurus's own loop. It owns the model, the tools and the conversation; Osaurus starts one process per chat and relays messages. The protocol contract for harness authors is [HARNESS_RUNTIMES.md](HARNESS_RUNTIMES.md). Entries go inline in the manifest's `harness_runtimes` array:

```json
{
  "name": "Acme Pi",
  "kind": "pi_rpc",
  "executable": "pi",
  "arguments": ["--mode", "rpc", "--session-id", "{chat_id}", "--append-system-prompt", "{system_prompt_file}"],
  "environment": { "PI_LOG_LEVEL": "info" }
}
```

- `kind`: `pi_rpc` (Pi or a Pi-based CLI in `--mode rpc`) or `claude_code`. It can't change after install; give the runtime a new name instead.
- `executable`: a command on the login shell's `PATH` or a path (`~` expands). Defaults to `pi` or `claude`. Your installer must install the program itself; `validate` and `install` warn when it isn't on `PATH`.
- `arguments`: `{chat_id}`, `{agent_id}`, `{cwd}` and `{system_prompt_file}` are filled in per launch. Key Pi sessions on `{chat_id}` so a chat resumes after a restart.
- `environment`: plain, non-secret values, stored unencrypted. `OSAURUS_*` names are reserved.
- `builtin` is reserved and can't be a runtime name.

An agent runs on a runtime with `"runtime": "Acme Pi"`. Installing that agent installs the runtime too, and removing the agent removes a runtime it pulled in once no other agent uses it. A runtime that any agent still runs on can't be removed. Users can switch an agent between runtimes and models from the chat model picker.

## 7. Secrets, step by step

Secrets never go in the bundle. Your script stores each one in the user's **login Keychain**, and the bundle refers to it as `keychain:SERVICE/ACCOUNT`. When Osaurus applies the import it reads the item once, copies the value into its own Keychain items, and keeps only the reference. Bundle files, the queue and Osaurus's records never contain a secret value.

`env:` references, which `osaurus config apply` accepts, are refused in bundles. Osaurus applies the bundle when it next opens, and by then your installer's environment is gone.

### Choose names

- **Service**: your reverse-DNS id, for example `com.example.acme-support`. One service for all your secrets.
- **Account**: one short name per secret, for example `tickets-token`, `github-token`.

The reference is then `keychain:com.example.acme-support/tickets-token`.

### Store the secret

Run this **as the user** (not root), **after** Osaurus is installed in `/Applications`:

```bash
printf '%s\n%s\n' "$TICKETS_TOKEN" "$TICKETS_TOKEN" \
  | security add-generic-password -U \
      -s com.example.acme-support -a tickets-token \
      -T /Applications/Osaurus.app -w
```

- `-T /Applications/Osaurus.app` adds Osaurus to the item's access list, so Osaurus can read it without a password prompt. **This is required.** Osaurus reads with prompts turned off, so an item that doesn't list Osaurus is silently unreadable: the import reports the secret as pending and the server can't connect.
- `-T` replaces the default access list, which would otherwise trust the app that created the item. After this command, `security find-generic-password -w` for the item asks for permission, which is expected. Add more `-T` flags only for apps that really need the secret.
- `-w` as the **last** argument makes `security` read the value from standard input, typed twice. `printf` is a shell built-in, so the value never appears on a command line where other processes could see it in `ps`. Avoid `-w "$SECRET"`.
- `-U` updates the item if it already exists, so re-running the script rotates the secret.
- Osaurus is signed with a stable Developer ID, so the access-list entry is expected to keep working across Osaurus updates. Check it on your own release cycle: install your bundle, update Osaurus, and confirm `osaurus import list` shows no pending secrets.

`osaurus import install` checks that each referenced item **exists** before queuing, and fails with the exact `security` command to run if one is missing. It can't check that Osaurus may read it, because access lists are per app. That shows up only when Osaurus applies the import.

### When a secret can't be read

The server and the agents are still installed. The item reports `needs_user_action` with the reference under `pending_secrets` (exit code 3), the agent shows **Needs setup**, and `osaurus import list` shows the server as "needs secrets". An agent's tools on that server aren't wired until the server connects.

To fix it, store the item again with `-T /Applications/Osaurus.app`, then re-run:

```bash
"$CLI" import update --from <bundle> --yes
```

`update` re-applies every item that still has something pending, even when the bundle hasn't changed.

### Rotating a secret

Store the new value with `security add-generic-password -U ...` as above, then run `osaurus import update --from <bundle> --yes`. Osaurus re-reads the reference and overwrites its copy.

### OAuth servers

An `auth: oauth` server can't be pre-provisioned. It is installed and the item reports `needs_user_action`. The user signs in once in Settings → Tools & MCP → Services, prompted by the agent's setup check.

### Deleting secrets on uninstall

When your bundle's server is removed, Osaurus deletes its own copies. Your script deletes the originals:

```bash
security delete-generic-password -s com.example.acme-support -a tickets-token
```

### Never

- Pass secrets as command-line arguments, to `osaurus` or to `security -w "$X"`.
- Commit secrets to the bundle folder or ship them inside the installer. Fetch them at install time (from your MDM, a prompt, or your provisioning service) and hand them to `security` on standard input.
- Log secret values. The example logs only `keychain:` references.

## 8. Writing the installer script

The complete example is [`install.sh`](examples/osaurus-bundle-example/install.sh). The steps:

### 8.1 Install and verify Osaurus

If your installer carries Osaurus itself, verify the copy before installing it:

```bash
codesign --verify --deep --strict "$SRC/Osaurus.app"
spctl --assess --type execute "$SRC/Osaurus.app"
codesign -dv "$SRC/Osaurus.app" 2>&1 | grep '^TeamIdentifier=4W8QF9VR2F$'
ditto "$SRC/Osaurus.app" /Applications/Osaurus.app
```

`4W8QF9VR2F` is the Osaurus Developer ID team. Copying into `/Applications` needs an admin user or root.

### 8.2 Find the CLI

Always use the CLI inside the app:

```bash
CLI=/Applications/Osaurus.app/Contents/Helpers/osaurus
```

`/usr/local/bin/osaurus` is an optional link the user may not have, or that may point at another copy. The CLI inside the app always matches the app.

### 8.3 Check the version

```bash
defaults read /Applications/Osaurus.app/Contents/Info CFBundleShortVersionString
```

Compare it with your bundle's `min_osaurus_version` to give a clear message early. `osaurus import` checks it too.

### 8.4 Run as the logged-in user, never as root

Osaurus keeps its data in the user's home folder and secrets in the user's login Keychain. `osaurus import` refuses to run as root: as root it would provision `/var/root`, and the user would see nothing.

A `.pkg` postinstall script runs as root. Run the user part of your script as the console user:

```bash
CONSOLE_USER=$(stat -f %Su /dev/console)
launchctl asuser "$(id -u "$CONSOLE_USER")" sudo -u "$CONSOLE_USER" -H /path/to/user-part.sh
```

`launchctl asuser` puts the command in the user's login session, which `security` needs to reach the login Keychain. `sudo -u` switches the user, and `-H` sets `HOME`. The example re-runs itself this way and passes the secrets in a temporary file only the user can read, never on the command line.

Caveats:

- **Nobody logged in** (at the login window or during setup): there is no login Keychain to write to. Install Osaurus as root, then run the user part at the user's next login, for example from a LaunchAgent or your MDM's "run at login" script.
- **Locked Keychain**: an MDM script that runs while the screen is locked may not be able to write to the Keychain. Run it in the user's session, after login.
- **Non-interactive runs** must have every secret up front: prompts only work in a terminal. The example reads them from the environment or `--secrets-file`.

### 8.5 Store the secrets

See [section 7](#7-secrets-step-by-step). Do this before `osaurus import install`, which checks the items exist.

### 8.6 Validate, then install

```bash
"$CLI" import validate --from "$BUNDLE_DIR" --json > validate.json || exit 1
"$CLI" import install --from "$BUNDLE_DIR" --yes --json > install.json
case $? in
  0) echo "Installed or queued" ;;
  3) echo "Installed; the user must finish a step in Osaurus" ;;
  *) echo "Failed; see install.json"; exit 1 ;;
esac
```

| Exit code | Meaning |
| --- | --- |
| `0` | Applied (Osaurus was running) or queued (it applies the next time Osaurus opens). The `state` field in the JSON says which. |
| `1` | A check or a change failed. Nothing was queued if a check failed. `issues` and the items' `message` say why. |
| `3` | Applied, but something must be finished in Osaurus: a secret Osaurus couldn't read, an OAuth sign-in, a model to download, a folder to pick. |

Read `state` with `plutil -extract state raw -o - install.json`. It is built into macOS, so you don't need `jq`.

### 8.7 Plugins and models

Plugins aren't part of a bundle. Install them in the same script, before the import, so agents that list them under `plugins.enabled` find them:

```bash
"$CLI" tools install osaurus.fetch --consent
```

For models, prefer `strictness: preferred` (or no `model` at all): the agent uses the user's model and works right away. To ship a specific local model, download it in the script. Downloads are large, so tell the user:

```bash
"$CLI" pull mlx-community/Qwen3-4B-4bit
```

### 8.8 Open Osaurus (optional)

```bash
open -a /Applications/Osaurus.app
```

The import doesn't need this. It applies whenever the user opens Osaurus. Opening right away just shows the result sooner.

## 9. Updating and uninstalling

### Updating

Ship the new bundle with a higher `version` and run:

```bash
"$CLI" import update --from "$BUNDLE_DIR" --yes --json
```

- Items whose content changed are re-applied. Unchanged items report `unchanged`.
- New items in the bundle are installed.
- Items the user **deleted** in Osaurus are not brought back by `update` (`skipped`, "Removed in Osaurus since it was installed"). `install` adds them back.
- Items installed at a newer version than you offer are skipped.
- Items you dropped from the new bundle stay installed. Remove them explicitly with `remove` (below).
- Settings the user changed since your bundle set them are left as they are ([Settings](#settings)).

**The user's edits.** An update re-applies only the keys your agent file declares; everything else keeps the user's changes. If your file sets `system_prompt`, the update resets the prompt. If it doesn't set `temperature`, the user's temperature stays. Lists you declare (`tools.enabled`, `skills`, `sandbox.allowed_domains`) replace the user's list. An agent the user renamed keeps the user's name. Declare only what you need to manage.

### Uninstalling

[`uninstall.sh`](examples/osaurus-bundle-example/uninstall.sh):

```bash
"$CLI" import remove --bundle com.example.acme-support --json
security delete-generic-password -s com.example.acme-support -a tickets-token
```

- `remove --bundle <id>` removes everything that bundle installed, and cancels any of its imports that are still queued. You don't need the bundle folder.
- `remove --bundle <id> agent "Support Desk"` removes one item. Removing an agent also removes the skills and servers that were installed only for it and that nothing else uses.
- A skill or server that an agent still uses isn't removed. The item fails with "Still used by …". This includes the user's own agents that list your skill.
- Items the user already deleted report "Already removed in Osaurus."
- Settings stay as they are. Removing a setting only drops Osaurus's record that your bundle set it.
- When Osaurus isn't running, the removal is queued and happens the next time it opens.

## 10. What the user sees

- **First launch.** Osaurus's onboarding still runs on first open. Your agents are there when it finishes, and onboarding may add its own starter agent next to them.
- **A toast** when the import applies at launch: "Agents ready — Support Desk, Release Checker · From Acme Support Starter", or "Bundle import finished with issues" naming what needs setup or failed.
- **Needs setup.** An agent with something left to finish (a pending secret, an OAuth sign-in, a missing model, a folder to pick) shows a **Needs setup** badge. The first time the user opens it in chat, Osaurus lists what's missing and offers **Set Up Now**.
- **Full control.** The user can edit, rename or delete anything you installed. It behaves like anything they created. Your receipts only stop your bundle from touching their items, and theirs from touching yours.

## 11. Verifying and troubleshooting

```bash
"$CLI" import list --json                    # what each bundle installed, pending secrets, queued imports
"$CLI" import list --bundle com.example.acme-support
cat ~/.osaurus/import/results/<request-id>.json   # per-item result of an applied import
"$CLI" config export                          # the agents and servers as Osaurus sees them
```

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| The agents aren't there after opening Osaurus | The script ran as root and provisioned `/var/root` | Run the import as the console user ([8.4](#84-run-as-the-logged-in-user-never-as-root)). |
| `import list` shows a queued import that never applies | Osaurus hasn't been opened since | Open Osaurus. Imports apply at launch. |
| "needs secrets" or `pending_secrets` | The Keychain item was created without `-T /Applications/Osaurus.app`, or before Osaurus was installed | Store it again with `-T`, then `import update`. |
| `no Keychain item keychain:…` at install | The item doesn't exist for this user, or has a different service or account | Check with `security find-generic-password -s SERVICE -a ACCOUNT` (without `-w`, so it doesn't prompt). |
| "A skill/agent named … already exists and was not installed by …" | The user, or another bundle, already has an item with that name | Rename your item, or ask the user to remove theirs. |
| `refused` with risks listed | High-risk items without `--yes` | Review the risks, then pass `--yes`. |
| `queued` with "did not accept the access key for /admin/import" while Osaurus is running | Require Access Key for Local Admin Routes is on | Pass `--access-key KEY` or set `OSAURUS_API_KEY`, or let the import apply when Osaurus next opens. |
| An agent is missing a tool | The server didn't connect (network, missing secret, `npx` not installed), or the tool name is wrong | Check Settings → Tools & MCP. Compare names with `osaurus config export`. |
| `validate` warns that agent and server entries were "only checked for shape" | Osaurus wasn't running | Open Osaurus and re-run `validate` for the full schema check. |
| "This bundle needs Osaurus X or newer" | The installed app is older than `min_osaurus_version` | Update Osaurus first. |

## 12. Security checklist for authors

- **Sign and notarize your installer**, and verify Osaurus's signature before installing it ([8.1](#81-install-and-verify-osaurus)).
- **Keep high-risk items to a minimum.** Every MCP server, every harness runtime, and every agent with computer use, browser use, relay or a harness runtime is something the user didn't choose. Prefer HTTP servers you operate over local processes, and `execution_host: sandbox` over `host`.
- **Use `https://` MCP endpoints.**
- **Keep `allowed_domains` narrow**, and leave `network_enabled` off unless the agent needs it.
- **Grant only the tools an agent needs**: use exact `tools.enabled` lists rather than enabling whole servers.
- **Handle secrets as in [section 7](#7-secrets-step-by-step)**: standard input, not arguments; `-T` for Osaurus only; deleted on uninstall.
- **Send no telemetry** from your installer about the user's Osaurus setup without their consent.
- **Pin your stdio packages** (`@scope/server@1.2.3`, not `@latest`) so an update to a package can't change what runs on the user's Mac.
- **Don't loosen the user's server settings** unless your setup can't work otherwise. List only the origins you operate in `allowed_origins`, and never ship `require_local_access_key: false`.

## 13. Reference

### CLI

```text
osaurus import validate --from <bundle> [--json]
osaurus import install  --from <bundle> [agent|skill|mcp|runtime|setting] [<name> ...] [--yes] [--json]
osaurus import update   --from <bundle> [agent|skill|mcp|runtime|setting] [<name> ...] [--yes] [--json]
osaurus import remove   --bundle <id> [agent|skill|mcp|runtime|setting] [<name> ...] [--json]
osaurus import list     [--bundle <id>] [--json]
```

Every command also takes `--access-key KEY` (or `OSAURUS_API_KEY` in the environment), needed to apply live when Require Access Key for Local Admin Routes is on.

- With no names, every item in the bundle (or everything the bundle installed, for `remove`) is processed.
- Naming an agent also installs the skills, servers and harness runtime it uses from the same bundle.
- When a name matches more than one kind (an agent and a skill both called "triage"), say which: `osaurus import install --from <bundle> skill triage`.
- `--yes` confirms the high-risk changes listed under `risks`.
- `--json` prints the result as JSON on standard output. Without it, the output is for people and may change.
- `remove` and `list` work from Osaurus's records and don't need the bundle folder.

### Exit codes

`0` applied or queued · `1` a check or change failed · `3` applied, but a step must be finished in Osaurus.

### `--json` output

```json
{
  "command": "install",
  "state": "applied",
  "exit_code": 3,
  "bundle_id": "com.example.acme-support",
  "bundle_name": "Acme Support Starter",
  "bundle_version": "1.0.0",
  "request_id": "20261022-143005-1a2b3c4d",
  "items": [
    { "kind": "skill", "name": "triage-ticket", "action": "install", "status": "done" },
    {
      "kind": "mcp", "name": "Acme Tickets", "action": "install", "status": "needs_user_action",
      "message": "...",
      "pending_secrets": ["keychain:com.example.acme-support/tickets-token"]
    }
  ],
  "risks": ["MCP server \"Acme Tickets\" connects to https://mcp.acme.example/mcp"],
  "warnings": [],
  "issues": [],
  "pending_secrets": ["keychain:com.example.acme-support/tickets-token"]
}
```

| Field | Values |
| --- | --- |
| `state` | `validated`, `applied`, `partial` (some items failed or need the user), `queued`, `failed`, `refused` (root, or high-risk without `--yes`), `listed`, `nothing_to_do` |
| `items[].kind` | `agent`, `skill`, `mcp`, `harness_runtime`, `setting` (named by its key, like `require_local_access_key`) |
| `items[].action` | `install`, `update`, `remove` |
| `items[].status` | `done`, `unchanged`, `needs_user_action`, `failed`, `skipped`, `queued` (not applied yet), `valid` (from `validate`) |
| `issues` | Why the command failed. Empty on success. |
| `warnings` | Advisory notes that didn't stop anything. |
| `installed` | (`list`) One receipt per installed item: `bundle_id`, `bundle_version`, `kind`, `name`, `explicit` (false for items pulled in as dependencies), `pending_secrets`, `needs_user_action`, `setting_value` (for settings: the value your bundle asked for), `installed_at`, `updated_at`. |
| `queued` | (`list`) Imports not applied yet: `request_id`, `bundle_id`, `operations`. |
| `cancelled_requests` | (`remove`) Queued imports of the bundle that were dropped. |

Fields with no value are omitted. New fields may be added, so ignore keys you don't know.

### On-disk paths

| Path | Contents |
| --- | --- |
| `~/.osaurus/import/pending/<request-id>/` | A queued import: `request.json` and a `bundle/` copy of the listed files. Removed once applied. |
| `~/.osaurus/import/results/<request-id>.json` | The result of an applied import. |
| `~/.osaurus/import/installed.json` | Osaurus's records of what each bundle installed. Written only by Osaurus. Don't edit it. |
| `~/.osaurus/skills/<slug>/` | Installed skills. |
| `/Applications/Osaurus.app/Contents/Helpers/osaurus` | The CLI. |

### Related

- [Agent Templates](AGENT_TEMPLATES.md): the agent file format.
- [Skills](SKILLS.md): skill authoring.
- [Remote MCP Providers](REMOTE_MCP_PROVIDERS.md): MCP servers in Osaurus.
- [Sandbox](SANDBOX.md): what `sandbox` turns on.
