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

The document has 16 sections (plus `version`):

- `memory` — persistent memory: enabled, token budget, retention days.
- `default_agent` — the built-in Default agent (the Orchestrator): display name, model, temperature, max tokens, persona, tools on/off.
- `active_agent` — which agent is active in chat (switch by name).
- `agents` — custom agents: prompt, model, sampling, and per-agent capability toggles (tools, web search, browser, computer use, relay, knowledge collections, …).
- `tools` — global tool enablement and per-tool policies (`auto` / `ask` / `deny`).
- `delegation` — subagent budgets (tokens, turns, tool calls, seconds, parallel spawns), spawnable agents, permission defaults, RAM-safety preflight.
- `commands` — user slash-command templates.
- `knowledge_collections` — folder-backed knowledge collections with include/exclude globs.
- `channels` — messaging platforms (Telegram, Slack, …): read limits, allowlists, write enables, and the global write kill switch.
- `mcp_servers` — MCP servers, HTTP or stdio (`command` / `args` / `env`), with `token_ref` / `secret_env_refs` for credentials.
- `models` — the desired-state list of installed local model ids; adding an id starts the download, pruning deletes from disk.
- `plugins` — installed plugin ids.
- `providers` — cloud model providers, including endpoint fields (create-only) and `api_key_ref` / `set_api_key`.
- `search_providers` — web-search providers and their fallback ranking.
- `schedules` — scheduled agent runs (interval, daily, weekly, cron).
- `watchers` — folder/file watchers that trigger an agent.

## Semantics

- **Merge by default.** A key absent from the document is left unchanged. An explicit `null` clears an optional override back to its default.
- **Entities match by name** (case-insensitive): agents, MCP servers, providers, schedules, and watchers listed in the document are created if missing, patched if present. `models` and `plugins` are plain desired-state id lists.
- **Plan is a dry run.** `plan` changes nothing — `apply` is the only action that mutates state. A planned change is not a done change.
- **Prune is explicit and destructive.** Prune is a *tool/CLI argument*, never a document key. Applying with prune additionally deletes entries *not* listed in the sections the document declares — it never touches undeclared sections. A prune that would delete an agent while a surviving schedule or watcher still runs on it is refused; delete or reassign them in the same document.
- **Validation is all-or-nothing.** Any invalid key, value, or reference fails the whole document with every issue listed — nothing is half-applied.
- **Model ids are grounded.** `default_agent.model` and `agents[].model` accept `foundation` (the built-in Apple Foundation on-device model), an installed local model id, or a cloud model as `<provider>/<model>` (the provider name lowercased, e.g. `anthropic/claude-x`). A bare cloud id is auto-prefixed when exactly one provider offers it; an id nothing offers fails validation instead of silently leaving the agent without a working model.
- **High-risk changes always require approval**: prune deletions, screen/browser grants, agent relay exposure, new MCP endpoints, stdio MCP commands, channel write enables, setting a tool policy to `auto`, loosening delegation permissions.
- **JSON works everywhere YAML does.** `export` and `schema` accept `format: json` (CLI: `--format json`), and `plan`/`apply` accept a JSON document in the same field — JSON is a YAML subset, with the same strict unknown-key validation.

## Secrets

Secrets never appear in a document — exports contain none, and applies never accept a raw key. Exports also never reveal *whether* a credential is stored, so a document stays safe to share and version.

Two ways to wire credentials:

- **Secret references.** `api_key_ref` (providers), `token_ref` (MCP servers), `secret_env_refs` (stdio MCP env), and `bot_token_ref` (channels) accept `env:VAR_NAME` or `keychain:SERVICE/ACCOUNT`. Apply resolves the reference at apply time; the document only ever carries the pointer.
- **The credential sheet.** Creating a cloud provider opens the native credential sheet during apply. To set or rotate an *existing* provider's key, add `set_api_key: true` to its entry: apply opens the same secure sheet even when the provider already has working credentials. The flag is a one-shot request — never exported, and the secret itself still never touches the document.

## Typical flows

- "Give my research agent web search and switch to it" — the assistant writes the minimal document, shows the plan, and applies after your approval.
- "Export my setup" — saves a shareable snapshot; re-applying it later (or on another machine) recreates the configuration, prompting only for credentials.
- Templates: `export` with a save-as name stores the document under `~/.osaurus/templates/`; later say "apply my research-setup template".

## CLI

```
osaurus config export [-o file.yaml] [--format json]  # snapshot current state
osaurus config plan <file.yaml|.json> [--prune]       # dry-run: show the diff
osaurus config apply <file.yaml|.json> [--prune] [--yes]
```

High-risk applies are refused until re-run with `--yes` (the risks are printed first). Exit codes: `0` fully applied, `1` a change failed or was cancelled, `3` applied but a step must be finished in the app (typically credentials).

## Schema and samples

Ask the assistant to "show the configuration schema" (it calls `osaurus_config` with `action: schema`) for the full annotated YAML reference: every section, key, value range, and which changes are flagged high-risk. Validated sample documents covering every section ship in the repository under `docs/examples/` (`osaurus-config.sample.yaml` and `osaurus-config.sample.json`).

## Not configurable declaratively

Two classes, both by design:

- **Removed from the declarative surface** (Settings UI only): server runtime (port, network exposure, generation defaults, caches, concurrency, model exposure), chat behavior (core model), app shell (login item, dock icon, appearance/themes/toasts), voice/wake words, global computer-use presets, sandbox resources, privacy filter, and image-generation targets. Per-agent capability *toggles* (computer use, browser, relay, …) remain declarative under `agents[].capabilities`. Skills are read-only via `osaurus_inspect` — installing a skill is content acquisition, not configuration state.
- **Inherently interactive**: macOS permission (TCC) grants, OAuth sign-in and device pairing, hotkey capture, folder pickers/bookmarks, download progress, destructive resets, and payment.
