---
title: Server and API
summary: The local OpenAI-compatible HTTP server — endpoints, port, auth, and using Osaurus from other apps.
order: 110
---

# Server and API

Osaurus runs a local HTTP server so other apps, scripts, and SDKs can use your models. It speaks the OpenAI API (plus Anthropic and Ollama formats).

## Basics

- Default base URL: `http://127.0.0.1:1337`. The port and network exposure are changed only in the Server tab of the Settings UI (the chat assistant cannot change them); changing port/exposure restarts the server.
- List models: `GET /v1/models` — the models exposed in Server → Exposed Models: downloaded local models, connected remote provider models, and `foundation` (Apple's on-device model) when available.
- Chat: `POST /v1/chat/completions` (SSE streaming with `stream: true`). Also `POST /v1/responses` (Open Responses), Anthropic's `POST /v1/messages`, and Ollama's `/api/chat`.
- OpenAI SDK: set `base_url="http://127.0.0.1:1337/v1"` and any placeholder key (e.g. `"osaurus"`) on loopback; use a real access key from the Server tab if network exposure is on.

## Requiring a key from this Mac

By default, callers on this Mac need no key. Turning on Settings → Server → Server Settings → Authentication → **Require Access Key for Local Admin Routes** changes that for the routes that read chats, drive agents, run tools, or rewrite configuration: `/sessions`, `/agents` (and everything under them), `/attention`, `/conversations/*`, `/devices/*`, `/mcp/*`, `/admin/config/*` and `/admin/import/*`, with or without the `/v1` prefix.

- Without a valid access key (`Authorization: Bearer osk-v1…`) these return `401`. Inference and model routes (`/v1/chat/completions`, `/v1/models`, …) are unaffected.
- A request carrying a browser `Origin` header is refused with `403` (`browser_origin_refused`), key or not, unless that origin is listed by name in **Allowed Origins (CORS)**; `*` does not count. A listed origin still needs a key.
- An all-agents key gets the same local behavior as before. An agent-scoped key is confined exactly as it is for a remote caller.
- Siri / Shortcuts and local harness tokens keep working. The `osaurus` command asks for approval instead (next section); scripts can still pass `--access-key KEY` or `OSAURUS_API_KEY`. Without either, `osaurus import` still queues the bundle, and it applies the next time Osaurus opens.
- An Osaurus bundle can switch this (and add to Allowed Origins) during `osaurus import`, through its `settings` object. Turning it off or adding an origin needs `--yes`.

## Approving the osaurus command

With **Require Access Key for Local Admin Routes** or **Expose to Network** on, the `osaurus` command (`list`, `run`, `config`, `mcp`, `workflow`, `agent`, …) does not need an access key. The first time a command run from Terminal is refused, Osaurus shows **Allow the osaurus command-line tool?** on this Mac. **Allow** gives the command a token it keeps in `~/.osaurus/cli/access-token` (readable only by you); later commands send it as `X-Osaurus-CLI-Token` and work without a prompt.

- The token works only from this Mac over loopback, never from the network, a relay, or a browser page. Osaurus stores only its hash.
- **Don't Allow**, closing the prompt, or two minutes without an answer refuse the command. After **Don't Allow**, new requests are refused for 30 seconds.
- A command with no terminal (an MCP host, a script) never raises the prompt; it fails with a hint to run any `osaurus` command in Terminal once.
- Starting a workflow and answering an agent run's tool approvals need the approval even with both switches off, so `osaurus workflow run`, `osaurus agent run` and `osaurus mcp install` ask once in that case too.
- Settings → Server → Overview → **Command-Line Tool Access** shows whether the command is approved and has **Revoke**.
- The prompt is `POST /cli/access` (body `{"command": "list"}`); it answers `200` with `token`, `403 cli_access_denied`, `408 cli_access_timeout`, `409` while another prompt is open, or `429` during the cooldown.

## Workflows and agents from the command line

- `osaurus workflow list | run | status | runs | cancel` runs your installed workflows. A form the run asks for is answered in the terminal; without one, the command exits `3` and the form waits in Osaurus. See the Workflows topic.
- `osaurus agent list` and `osaurus agent run <name|id|default> -p "…"` run an agent with its own model, memory and tools; piped input is added to the prompt, the answer goes to stdout and tool activity to stderr. `--session ID` continues a conversation. See the Agents topic.
- Routes behind them, all owner-only: `GET /workflows` (each workflow's id, name, `tool_name`, input schema and setup state), `GET /workflows/runs` (`?workflow=` and `?limit=`, newest first), `GET /workflows/runs/{id}`, `POST /workflows/runs/{id}/cancel` (`404 run_not_found`, `409 run_finished`), and `POST /workflows/{id}/run`, which only Osaurus's own Shortcuts actions and the approved command may call (`403 app_only` otherwise).
- An approved command's agent run in a terminal sends `X-Osaurus-CLI-Approval-Session`; its Ask cards show on this Mac as usual and are also listed by `GET /approvals?session=ID` and answered with `POST /approvals/{id}` (body `{"decision": "allow_once", "session": "ID"}`). Without the approved token those requests are refused with `403 cli_only`.

## Using Osaurus from Codex CLI

OpenAI's Codex CLI can run against your local models. Settings → Server → Overview has a **Use with Codex CLI** card: pick a model, then **Copy** the generated config or click **Add to ~/.codex** to write it. Osaurus adds a `[model_providers.osaurus]` table to `~/.codex/config.toml` (inside marked comments it maintains; the rest of the file is untouched) and writes an `osaurus` profile at `~/.codex/osaurus.config.toml` holding `model` and `model_provider`. Start Codex with `codex --profile osaurus`. `CODEX_HOME` is honoured when set.

- Codex only speaks the Responses API (`wire_api = "responses"`), so requests land on `POST /v1/responses`.
- With network exposure off, Codex on the same Mac needs no key. With it on, the generated block adds `env_key = "OSAURUS_API_KEY"`; create an access key and export that variable in the shell running Codex.
- If `config.toml` already defines `model_providers.osaurus` by hand, the write is refused rather than duplicated; remove the manual table first.
- The profile's `model_context_window` is what the server actually keeps: the model's context length, capped by **KV Retention Override** under Settings… (⌘,) → Server → Server Settings → Cache. A blank override uses the Memory Safety profile. Codex compacts the thread against it.
- Each Codex thread is its own conversation for the on-disk prompt cache (its `prompt_cache_key` becomes the session id), so resuming a thread reuses its cached prefix.
- To resume a non-interactive run, put the profile before the subcommand: `codex exec --profile osaurus resume --last "…"`. Placed after `resume` the flag is rejected, and without it Codex uses OpenAI instead of Osaurus.

## Two ways to run tools

- `POST /v1/chat/completions` is strict OpenAI semantics: Osaurus returns `tool_calls` and your client executes them. No Osaurus memory or skills are injected.
- `POST /agents/{id}/run` runs a full server-side agent loop (what in-app chat uses): the agent executes its own tools, with memory and context. Tool iterations follow Settings → Chat → Advanced → Max Tool Attempts (30 by default, up to 120).
- Tools set to Ask are declined on an HTTP run, since nobody can click the card, except for your iPhone and the approved `osaurus agent run` in a terminal, which answer it.
- Dangerous tools (`file_write`, `file_edit`, `shell_run`, `git_commit`, …) are denied to external HTTP callers by default. An authenticated remote run (Secure Channel, agent-scoped key) of an agent with a working folder gets `file_read`, `file_write` and `file_edit` confined to that folder.

## Sessions and caching

Pass an optional `session_id` to group turns; KV-cache reuse is automatic. Prefix caching, paged KV, and the on-disk cache are configured in Settings → Server → Server Settings → Cache (cache changes unload loaded models to take effect); they are not part of the declarative configuration document.

## Server settings you can change

Port, network exposure, Sampling Defaults (temperature / top-p / top-k / max tokens — leave unset to use each model's own defaults), continuous batching, concurrent sequences, and cache toggles, all in Server → Server Settings. Server → **API Reference** lists every endpoint with copyable examples; Insights shows live request/response traffic.

## MCP surface

`GET /mcp/tools` and `POST /mcp/call` expose Osaurus tools over HTTP; `osaurus mcp` runs Osaurus as a stdio MCP server for other AI apps, and `osaurus mcp --workflows` adds your workflows as tools. `osaurus mcp install --client cursor|claude-code|claude-desktop|codex` registers it with an app and approves the command (see the MCP topic). With **Require Access Key for Local Admin Routes** or **Expose to Network** on, approve the command once (run `osaurus mcp install` or `osaurus list` in Terminal and click **Allow** in Osaurus); a host can also pass `--access-key KEY` or `OSAURUS_MCP_ACCESS_KEY`.

## Configuration endpoints (loopback only)

The declarative configuration surface (see the Declarative Configuration topic) is also exposed over local HTTP for automation:

- `GET /admin/config/export` — the current setup as a YAML document (never contains secrets).
- `POST /admin/config/plan` — body `{"yaml": "<document>"}` (or `{"template": "<name>"}`), optional `"prune": true`; returns the diff without changing anything.
- `POST /admin/config/apply` — same body; high-risk changes return `409` with the risk list until re-sent with `"confirm_high_risk": true`.

Unlike other admin routes, these are strictly restricted to local (loopback) callers — an access key never admits a remote caller, even with network exposure on. With **Require Access Key for Local Admin Routes** on, local callers also need a key. The `osaurus config` CLI wraps these endpoints; it uses its approval from Osaurus (see below), or `--access-key KEY` / `OSAURUS_API_KEY` when given.
