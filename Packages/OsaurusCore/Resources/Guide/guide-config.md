---
title: Declarative Configuration
summary: Describe your Osaurus entities as one YAML (or JSON) document — plan the diff, approve it, apply it, save it as a template.
order: 121
---

# Declarative Configuration

Osaurus's entities can be configured from a single YAML document that describes the desired state. The assistant plans a diff against the current state, shows you exactly what would change (with any risks called out), and applies it only after approval. The same engine powers three surfaces:

- **Chat** — the built-in assistant's `osaurus_config` tool (`schema`, `export`, `plan`, `apply`, `templates`), plus `osaurus_inspect` (`status`, `list`, `describe`) for read-only lookups against live state.
- **CLI** — `osaurus config export | plan | apply` (see below).
- **Local HTTP** — `GET /admin/config/export`, `POST /admin/config/plan`, `POST /admin/config/apply` (loopback-only).

## Sections

The document has 20 sections (plus `version`):

- `memory` — persistent memory: enabled, token budget, retention days.
- `harness_runtimes` — external agent harnesses (Settings → Agent Runtimes): `name`, `kind` (`claude_code` or `pi_rpc`; required to add, fixed after), `executable`, `arguments` (`{chat_id}`, `{agent_id}`, `{cwd}`, `{system_prompt_file}` are filled per launch), and `environment` (plain values, merged; never secrets). `builtin` is reserved. Adding one, or changing its command line or environment, is high risk: every chat of an agent on it runs that program.
- `default_agent` — the built-in Default agent (the Orchestrator): display name, model, temperature, max tokens, persona, and `runtime` / `claude_code` (as on `agents`, plus `claude_code.allow_osaurus_config_writes`).
- `configurator` — the built-in helper behind Osaurus questions and settings changes (Settings → Configurator): `model` (same format as `default_agent.model`; `null` uses the Orchestrator's model), `temperature` (0–2; `null` uses the model's default), and `system_prompt` (extra instructions added after the built-in ones). Its name is fixed.
- `new_chat_agent` — which agent **new** chats open with: `default` or a custom agent's name. (`active_agent` is still accepted as a legacy spelling; exports write `new_chat_agent`.)
- `model_defaults` — the model roles on Models → Model Defaults: `core_model` (titles, memory, follow-ups, transcript cleanup) and `compaction_model` (summarizes older messages near the context limit). Same model format as `default_agent.model`; `null` clears the role so the chat's model is used.
- `chat` — everyday switches from Settings → Chat: `smooth_streaming`, `group_activity`, `expand_thinking`, `spell_check`, `auto_titles`, `follow_up_suggestions`, `clipboard_monitoring`, `keep_mac_awake`. Top P, Max Tool Attempts, ⌘+N, and the Context Window Cap stay in Settings.
- `app` — app basics from Settings → General: `hotkey` (text such as `cmd+shift+o`: cmd, shift, option or ctrl plus one key; at least one of cmd, option or ctrl; `null` turns it off), `start_at_login`, `show_notifications`. The dock icon, beta updates and Factory Reset stay in Settings.
- `agents` — custom agents: prompt, model, sampling, and per-agent capability toggles (tools, web search, browser, computer use, relay, knowledge collections, `apple_apps`, …). `skills` is the agent's skill allow-list: omit it to leave it unchanged, `null` for every installed skill, or a list of skill names or slugs (`[]` means none); only listed skills appear in the agent's prompt, `capabilities_load`, and slash commands. `tools` with `mode: manual` is the exact tool list: an export lists a fully selected plugin or MCP group under `plugins` / `mcp_servers`, and a partly selected group as its exact tool names under `tools.enabled`. `capabilities.apple_apps` is the list of built-in Apple apps the agent may use (`calendar`, `reminders`, `contacts`, `notes`, `mail`, `messages`, `maps`, `music`, `shortcuts`); the full list replaces the set and `[]` turns them all off. Enabling `mail`, `messages`, or `shortcuts` adds a risk line to the plan. Specialist tools are off on a new agent: set `capabilities.calculator_enabled: true` for an agent that works with numbers (finance, budgets, invoices, data analysis) and `capabilities.redaction_tools_enabled: true` for one that scrubs personal data from files, in the same apply that creates it. `task_checklist_enabled`, `clarify_enabled`, and `artifacts_enabled` are on by default. `template: coder | researcher | writer | assistant | productivity` fills in the system prompt when omitted; `description` is an optional one-line routing summary (generated in the background from the system prompt when omitted); an omitted `model` means the Orchestrator's current model. `runtime` is `builtin` (Osaurus's own loop) or a `harness_runtimes` name; a name that isn't registered (and isn't added by the same document) fails validation rather than falling back to the built-in loop. `claude_code` (`model`, `mode: agent | text_only`, `allow_writes`, `allow_shell`, `allow_osaurus_tools`) applies when the runtime is Claude Code; only listed keys change. `shared_tool_approval` (`mode: deny | ask_owner`, `timeout_seconds` 30–86400, default 600) decides what happens when a teammate, invite-link peer, or another person's agent calls one of this agent's tools that needs approval: `deny` (the default) fails the call, `ask_owner` waits for you to answer and declines on timeout. In the app these are Workspaces → *workspace* → Shared Agents → **Require Approval for Teammate Tool Calls** and **Decline Unanswered Requests After**. It never unlocks a tool set to `deny` or one blocked for remote callers.
- `tools` — global tool enablement and per-tool policies (`auto` / `ask` / `deny`). Tools that send or delete as the user (`messages_send`, `calendar_delete_event`, `reminders_delete`, `delete_knowledge`) ask on every call regardless; `auto` on them is stored but has no effect, and the plan says so. `mail_compose` / `mail_reply` on `auto` covers drafts only — `send: true` still asks.
- `delegation` — the Orchestrator's allowed subagents and limits: `spawnable_agents` (custom agent names), `spawnable_workspace_agents` (teammates' shared agents), `workspace_auto_join`, `permission_defaults` (`spawn`, `spawn_workspace`, …), the per-subagent budgets (`budget_max_tokens`, `budget_max_turns`, `budget_max_seconds`, `budget_max_parallel_spawns`, `budget_max_remote_parallel_spawns`), RAM-safety preflight. See "Delegation" below.
- `commands` — user slash-command templates.
- `knowledge_collections` — folder-backed knowledge collections with include/exclude globs.
- `channels` — messages people send to agents, per platform (Telegram, Slack, …) as in a channel's sheet: receiving (`read_allowlist`, `sender_allowlist`, read limit), **routing** (`routing`: who answers which rooms — one rule per agent or workflow, `replies: automatic | approval`), and sending (`write_enabled`, `write_allowlist`, `posting`: agents that post on their own, `off | ask_first | without_asking`), plus the global write kill switch. n8n and custom HTTP connections take `routing` under `channels.connections` by connection name. `channels.email` has no `write_allowlist` or `posting`: agents only reply in the thread of mail they received. `channels.<platform>` edits the platform's first account; each extra bot, Slack workspace or email account is an entry in `channels.<platform>.accounts` with its connection `id` (as `agent_channel_list_connections` shows it) and the same keys. Bots and workspaces are added in Settings → Channels; an Email entry `email-<mail account id>` can add an account for a mail account no other Email account watches.
- `mcp_servers` — MCP servers, HTTP or stdio (`command` / `args` / `env`), with `token_ref` (HTTP bearer token), `secret_header_refs` (HTTP custom headers such as `X-API-Key`, header name → reference), and `secret_env_refs` (stdio environment) for credentials.
- `models` — the desired-state list of installed local model ids; adding an id starts the download, pruning deletes from disk.
- `plugins` — installed plugin ids.
- `providers` — cloud model providers, including endpoint fields (create-only) and `api_key_ref` / `set_api_key`.
- `search_providers` — web-search providers and their fallback ranking.
- `automations` — triggers that run work: `source` (`schedule`, `folder`, `webhook`, `rss`, `sse`, `run_failed`, `app`; a webhook may carry `sample_body` and a `provider` — `github`, `stripe`, `slack`, `shopify`, `twilio`, `microsoft_graph`, `facebook`, `sns` — which replaces `verification`; `rss` takes `url`, `poll_interval_seconds`, `catch_up`, `max_items_per_tick`; `sse` takes `url`, `headers`, `event_names`, `heartbeat_timeout_seconds`; `run_failed` takes `workflows` and `include_automation_runs`; `app` takes `reasons`: `app_launched`, `automation_enabled`, `automation_updated`), optional `filter`, `agent` + `instructions` or `workflow` + `input`, and `delivery` (queueing, `dedupe` — `none`, `window` with `dedupe_window_seconds`, or `durable` — and missed runs). Every required workflow input must be bound in `input` (to a trigger value such as `{{schedule.scheduled_for}}` or fixed text); an omitted `input` on create is prefilled the way the editor does. The older `events:`, `schedules:` and `watchers:` sections are translated into `automations:`; `channels.<platform>.inbound_*` keys and `automations` entries with `source.kind: channel_message` become `channels.<platform>.routing` rules, each with a deprecation note. Entries with `source.kind: email` are retired: they are ignored with a note pointing to `channels.email`.

## Recipes

Route a Slack room to an agent, replying automatically (the plan flags the automatic replies for approval):

```yaml
channels:
  slack:
    routing:
      - name: Triage in support
        agent: Triage
        rooms: [C0123SUPPORT]          # omit for any room
        replies: automatic             # or approval (the default)
      - name: Helper everywhere else
        agent: Helper
```

Let an agent post in a room on its own, asking first:

```yaml
channels:
  slack:
    write_enabled: true
    write_allowlist: [C0456ANNOUNCE]
    posting:
      - agent: Triage
        mode: ask_first                # off | ask_first | without_asking (high risk)
        rooms: [C0456ANNOUNCE]         # omit for every writable room
```

Run a workflow every weekday at 9:00, binding its required `date` input:

```yaml
automations:
  - name: Weekday report
    source:
      kind: schedule
      frequency: cron
      frequency_value: "0 9 * * 1-5"
    workflow: Daily Report
    input:
      date: "{{schedule.scheduled_for}}"
```

Start an agent from a GitHub webhook, with a sample body so its fields are known:

```yaml
automations:
  - name: New GitHub issues
    source:
      kind: webhook
      provider: github
      sample_body: '{"action": "opened", "issue": {"title": "Crash on launch"}}'
    filter:
      conditions:
        webhook.body.action: opened
    agent: Triage
    instructions: "Triage the new issue: {{webhook.body.issue.title}}"
```

The webhook's URL and secret are created on apply and shown on the automation's detail in Settings; they never appear in a document or in the apply result. For providers that issue their own secret (Stripe, Slack, Shopify, Twilio, Meta), paste it on the automation's detail after apply.

Post new items from a feed, and hear about any failed workflow:

```yaml
automations:
  - name: Release notes
    source:
      kind: rss
      url: https://example.com/releases.xml
      poll_interval_seconds: 1800
    agent: Research Agent
    instructions: "Summarize this release: {{feed.item.title}} {{feed.item.link}}"
  - name: Workflow failures
    source:
      kind: run_failed
      include_automation_runs: true
    agent: Ops
    instructions: "{{failure.workflow.name}} failed at {{failure.failed_step.name}}: {{failure.error}}"
```

Let an agent answer invoice mail and reply in the thread after approval:

```yaml
channels:
  email:
    read_allowlist: [<mail account id>/INBOX]   # one room per watched mailbox
    sender_allowlist: ["@billing.example.com", "ap@vendor.com"]
    write_enabled: true                          # let agents reply in the thread
    routing:
      - name: Invoices
        agent: Bookkeeper
        instructions: "File the invoice: {{email.subject}} from {{email.from}}"
        replies: approval                        # or automatic (needs write_enabled)
```

The mail account must already exist: accounts hold passwords, so they are added in Settings (Channels → Email → Add Account…), never from a document. Rooms name the account by its id (export the config to see it) and a mailbox. Per-account options (only unread mail, message text and length, check interval, catch-up) are set in Settings. Each message reaches agents once, by its Message-ID.

## Delegation

```yaml
delegation:
  spawnable_agents: [Coder, Researcher]           # replaces the local allowed subagents
  spawnable_workspace_agents:
    - Research@Acme                                # Name@Workspace …
    - ws-1234:0x0123456789abcdef0123456789abcdef01234567   # … or the durable key
  workspace_auto_join:
    Acme: false                                    # stop this workspace's shared agents auto-joining
  permission_defaults:
    spawn: always_allow                            # local agents (default)
    spawn_workspace: ask                           # teammates' shared agents (default)
  budget_max_tokens: 8192                          # per worker turn, 256..65536
  budget_max_turns: 24                             # tool-call rounds per worker, 1..100
  budget_max_seconds: 900                          # 15..3600
  budget_max_parallel_spawns: 3                    # local workers per wave
  budget_max_remote_parallel_spawns: 8             # remote workers per wave
```

- `spawnable_workspace_agents` entries are resolved against the live workspace rosters: `Name@Workspace` (workspace display name or id, case-insensitive), a bare name when it is unique, a `0x…` address, or the durable `<workspace_id>:<address>` key. A name that matches more than one agent fails validation and lists the exact forms that disambiguate. Both `spawnable_*` lists replace the allowed subagents; `workspace_auto_join` and `permission_defaults` merge.
- Removed keys — `spawnable_models`, `spawn_tool_access`, `budget_max_tool_calls`, `image_enabled`, `video_enabled`, `applescript_enabled` — are still decoded from old documents (with a hint) and never exported. Image, Video, and AppleScript are custom-agent capabilities; turns and time bound a worker.

## Semantics

- **Merge by default.** A key absent from the document is left unchanged. An explicit `null` clears an optional override back to its default.
- **Entities match by name** (case-insensitive): agents, MCP servers, providers, automations and routing rules listed in the document are created if missing, patched if present. Automations and routing rules share one set of names; posting rows match by `agent`. `models` and `plugins` are plain desired-state id lists.
- **Plan is a dry run.** `plan` changes nothing — `apply` is the only action that mutates state. A planned change is not a done change.
- **Prune is explicit and destructive.** Prune is a *tool/CLI argument*, never a document key. Applying with prune additionally deletes entries *not* listed in the sections the document declares — it never touches undeclared sections. Inside `channels`, a declared `routing` or `posting` list prunes only that platform (an unlisted posting row falls back to the automatic ask-first place), and `automations` never prunes channel rules. A prune that would delete an agent while a surviving automation still runs on it is refused; delete or reassign them in the same document.
- **Validation is all-or-nothing.** Any invalid key, value, or reference fails the whole document with every issue listed — nothing is half-applied.
- **Model ids are grounded.** `default_agent.model` and `agents[].model` accept `foundation` (the built-in Apple Foundation on-device model), an installed local model id, or a cloud model as `<provider>/<model>` (the provider name lowercased, e.g. `anthropic/claude-x`). A bare cloud id is auto-prefixed when exactly one provider offers it; an id nothing offers fails validation instead of silently leaving the agent without a working model.
- **High-risk changes always require approval**: prune deletions, screen/browser grants, agent relay exposure, new MCP endpoints, stdio MCP commands, harness runtime commands and environment, moving an agent onto a harness, Claude Code shell or configuration-change permission, channel write enables, automatic channel replies, agents posting `without_asking`, setting a tool policy to `auto`, loosening delegation permissions (including `spawn_workspace` to `always_allow`).
- **JSON works everywhere YAML does.** `export` and `schema` accept `format: json` (CLI: `--format json`), and `plan`/`apply` accept a JSON document in the same field — JSON is a YAML subset, with the same strict unknown-key validation.

## History, compare, and revert

Every change that lands is kept as a version of the whole document: from a chat, a template install, a file import, the command line, your iPhone, or a change made in Settings (shown as **Changed in Settings** the next time Osaurus looks: at launch, before the next change, or when you open History). The first version is your setup as Osaurus first found it. Settings → Agents → Configurator → **Configuration History** lists them newest first; select one to see what it changed or two to compare, and use a row's ⋯ menu to **Name…** it (named versions are always kept; otherwise the newest 200 are), **Export…** it as `.yaml`, or **Revert to This Version…**. In chat, ask "what changed yesterday?" or "put my agents back the way they were on Monday": the assistant reads the history and compares versions before answering, and a revert shows the same approval card as any change. A revert is an ordinary apply of the old document, so it adds and updates but deletes nothing unless you ask for an exact mirror, and it can be limited to some sections (for example only `agents`). Setup that no longer exists, such as a removed provider, comes back as a step to finish in Settings. Versions hold only what the document holds: no keys or tokens, and not server runtime settings, appearance, voice, or working folders. The approval card also shows the exact lines a change will make, collapsed when it is long.

## Secrets

Secrets never appear in a document — exports contain none, and applies never accept a raw key. Exports also never reveal *whether* a credential is stored, so a document stays safe to share and version.

Two ways to wire credentials:

- **Secret references.** `api_key_ref` (providers), `token_ref` and `secret_header_refs` (MCP servers), `secret_env_refs` (stdio MCP env), and `bot_token_ref` (channels) accept `env:VAR_NAME` or `keychain:SERVICE/ACCOUNT`. Apply resolves the reference at apply time; the document only ever carries the pointer.
- **The credential sheet.** Creating a cloud provider opens the native credential sheet during apply. To set or rotate an *existing* provider's key, add `set_api_key: true` to its entry: apply opens the same secure sheet even when the provider already has working credentials. The flag is a one-shot request — never exported, and the secret itself still never touches the document.

## Typical flows

- "Give my research agent web search and switch to it" — the assistant writes the minimal document, shows the plan, and applies after your approval.
- "Export my setup" — saves a shareable snapshot; re-applying it later (or on another machine) recreates the configuration, prompting only for credentials.
- Templates: `export` with a save-as name stores the document under `~/.osaurus/templates/`; later say "apply my research-setup template".
- Agent templates: single-agent JSON files saved from Agents → Templates live in the same directory. `templates` lists the ones flagged for the Orchestrator; `plan` / `apply` with `template: "<name>"` plus `overrides: {name, description, system_prompt, model, capabilities}` creates an agent from one; `capabilities` merges onto the template's toggles (for example `{calculator_enabled: true}` for a finance agent). The `agents[]` entity carries the portable keys (`tools`, `mcp_servers`, `plugins`, `plugin_instructions`, `sandbox`, `subagents`, `working_folder`) that make this work across machines. `orchestrator_spawnable: false` on an entry that creates an agent keeps it out of Settings → Agents → Delegation → Allowed subagents; it is ignored when the entry patches an existing agent, and a `delegation.spawnable_agents` list in the same document still wins.

## CLI

```
osaurus config export [-o file.yaml] [--format json]  # snapshot current state
osaurus config plan <file.yaml|.json> [--prune]       # dry-run: show the diff
osaurus config apply <file.yaml|.json> [--prune] [--yes]
```

When Settings → Server → Server Settings → Authentication → **Require Access Key for Local Admin Routes** is on, the `/admin/config/*` endpoints need an access key even from this Mac: pass `--access-key KEY` or set `OSAURUS_API_KEY` (a missing or rejected key exits `1` with a hint).

To install agents, skills, MCP servers, and harness runtimes from a vendor's Osaurus bundle (an installer-shipped folder with `osaurus-bundle.json`), use `osaurus import install --from <folder>`; see `docs/OSAURUS_BUNDLES.md` in the repository. A bundle can also switch **Require Access Key for Local Admin Routes** and add to **Allowed Origins (CORS)** through its `settings` object; no other setting is provisioned that way.

High-risk applies are refused until re-run with `--yes` (the risks are printed first). Exit codes: `0` fully applied, `1` a change failed or was cancelled, `3` applied but a step must be finished in the app (typically credentials).

## Schema and samples

Ask the assistant to "show the configuration schema" (it calls `osaurus_config` with `action: schema`) for the full annotated YAML reference: every section, key, value range, and which changes are flagged high-risk. Validated sample documents covering every section ship in the repository under `docs/examples/` (`osaurus-config.sample.yaml` and `osaurus-config.sample.json`).

## Not configurable declaratively

Two classes, both by design:

- **Removed from the declarative surface** (Settings UI only): server runtime (port, network exposure, generation defaults, caches, concurrency, model exposure), Chat page sampling (Top P, Max Tool Attempts), the dock icon, beta updates, appearance and text size, the other Model Defaults roles (image, video, speech, privacy detection, AppleScript), voice/wake words, global computer-use presets, sandbox resources, privacy filter, image-generation targets, the Orchestrator's working folder, and the agent-target model override. Per-agent capability *toggles* (computer use, browser, relay, …) remain declarative under `agents[].capabilities`. Skills are not a declarative section (an agent's allow-list is `agents[].skills`). To install a skill, MCP server, agent, or command someone shared, paste the link, snippet, or command in chat: the Configurator's `osaurus_import` reads it, checks every value against the source, and shows a review card before anything installs (see the Importing from Chat topic). Third-party installers ship skills in an Osaurus bundle with `osaurus import`.
- **Inherently interactive**: macOS permission (TCC) grants, OAuth sign-in and device pairing, hotkey capture, folder pickers/bookmarks, download progress, destructive resets, and payment.
