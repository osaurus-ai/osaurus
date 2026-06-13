# Telemetry & KPIs

This document is the complete, authoritative description of the anonymous
usage analytics Osaurus can collect. It exists so anyone — user, contributor,
or auditor — can see *exactly* what is captured, why, and what is deliberately
left out. If the code and this document ever disagree, that is a bug; please
open an issue.

Analytics are sent via [Aptabase](https://aptabase.com), an
[open-source](https://github.com/aptabase/aptabase), privacy-first analytics
project. Crash reporting (Sentry) is a **separate, independent** switch and is
documented in the [README](../README.md#crash-reporting); it is not covered
here.

## Defaults & consent

Analytics are on by default and opt-out, with one switch to turn them off.

- **On by default.** The first onboarding step shows a pre-checked "Share
  anonymous usage data" box; uncheck it to decline. An info button next to it
  explains what's collected and where to turn it off.
- **Nothing leaves before you confirm.** The handful of events from launch up
  to the welcome step are held in memory (bounded), never on disk. Continuing
  with the box checked sends them; unchecking drops them.
- **Off anytime** in **Settings → Privacy → Share Anonymous Usage Data**.
  Sending stops immediately.
- **Silent in source builds.** With no Aptabase key (the contributor default),
  the SDK never initializes and every event is a no-op.

See [`TelemetryService`](../Packages/OsaurusCore/Services/TelemetryService.swift)
for the consent gate and buffering, and
[`FeatureTelemetry`](../Packages/OsaurusCore/Services/FeatureTelemetry.swift)
for the event definitions below.

## What we never collect

We do not collect, and the code does not attach, any of the following:

- Chat content: prompts, messages, system prompts, completions, or model
  output of any kind.
- Tool-call arguments or results, file contents, or file paths.
- API keys, tokens, credentials, or remote provider URLs.
- Agent names, chat titles, session ids, or conversation history.
- Exact token counts or message text length.
- Names of user-configured remote providers, or the raw model id of a remote
  model (see "Remote identifiers" below).
- Any persistent per-user identifier, account, IP address, or precise
  location. Events are not tied to you.

## KPI pillars

The events are organized around three product questions.

| Pillar | Question | Primary signals |
|--------|----------|-----------------|
| Engagement | Are people using the core product? | `message_sent`, `chat_session_started`, `agent_run` |
| Retention / lifecycle | Do people come back and run the server? | `app_launched`, `server_started` (DAU/WAU/sessions derived by Aptabase) |
| Feature adoption | Which features get used? | `model_downloaded`, `remote_provider_added`, `mcp_provider_added`, `agent_created` |

Retention, session counts, new-vs-returning users, app version, OS version,
and locale are derived by Aptabase from its **anonymous** session model plus
the events below. No persistent per-user identifier is added by Osaurus to
make this work.

## Common properties (every event)

One coarse property is attached automatically to **every** event by
`TelemetryService.track`:

| Property | Type | Values / meaning |
|----------|------|------------------|
| `total_memory_gb` | string | Coarse physical-RAM bucket for this Mac, snapped to a fixed tier: `8`, `16`, `18`, `24`, `32`, `36`, `48`, `64`, `96`, or `128+`. Sourced from `ProcessInfo.physicalMemory`. |

This lets any metric (bounce, funnel, adoption) be segmented by machine class —
e.g. checking whether a 26B MoE bounces more on lower-RAM Macs — without
shipping an exact, potentially-identifying memory size. It is anonymous and
stays behind the same opt-out consent gate as every other event.

## Event catalog

Every property listed below is the complete event-specific set. In addition,
the common `total_memory_gb` property above is attached to every event.
No other data is attached.

### `message_sent` (primary metric)

Emitted once per top-level, user/client-initiated chat turn, across every
surface (in-app Chat, the HTTP API, plugins, and agent runs). Internal
tool-loop continuations are intentionally **not** counted, so an agent that
takes several internal steps to answer one prompt still records a single
`message_sent`. (Mechanically: the event only fires when the request's last
message is a `user` message; tool-loop re-entries end in a `tool` message and
are skipped. Only the message *role* is inspected — never the content.)

| Property | Type | Values / meaning |
|----------|------|------------------|
| `source` | string | `chat_ui`, `http_api`, or `plugin` — the originating surface |
| `model_source` | string | `foundation` (Apple on-device), `local` (MLX), or `remote` |
| `provider_type` | string | `foundation`, `mlx`, or the remote provider type enum (`openai`, `anthropic`, `gemini`, `azureOpenAI`, `openResponses`, `openAICodex`, `osaurus`) |
| `model` | string | The exact model id — **only** for `foundation`/`local` (curated, non-identifying). Omitted for remote. |
| `model_hash` | string | **Remote only.** Salted, truncated hash of the remote model id (see "Remote identifiers"). Omitted otherwise. |
| `is_agent` | bool | Whether the turn came from an autonomous agent run (the `/agents/{id}/run` endpoint) vs a plain completion |
| `stream` | bool | Whether a streaming response was requested |

### `chat_session_started`

Emitted when a new chat conversation is started from the UI. No properties.

### `first_time_chat_shown`

Emitted exactly once per install, the first time a chat window becomes
visible after completing onboarding. Together with `first_time_chat_used` it
bridges the gap between `onboarding_completed` and the engagement events: did
a new user ever reach chat, and did they ever send anything? No properties.

### `first_time_chat_used`

Emitted exactly once per install, when the first ever message is sent from
the in-app chat. No properties — the accompanying `message_sent` carries the
dimensions.

### `agent_run`

Emitted once when an agent run is initiated.

| Property | Type | Values / meaning |
|----------|------|------------------|
| `source` | string | `http_api` (the `/agents/{id}/run` endpoint) or `dispatch` (background / scheduled / plugin dispatch) |

### `server_started`

Emitted when the local server transitions to running. No properties. (No port
or bind address is attached.)

### `app_launched`

Emitted once at launch. No properties. Baseline signal for retention.

### `model_downloaded`

Emitted when a model finishes downloading and is verified on disk.

| Property | Type | Values / meaning |
|----------|------|------------------|
| `model` | string | Curated-catalog model id (safe to send) |
| `param_count` | string | Coarse size, e.g. `7B` (omitted if unknown) |
| `quantization` | string | e.g. `4-bit` (omitted if unknown) |
| `is_vlm` | bool | Whether the model is a vision-language model |

### `remote_provider_added`

Emitted when a user configures a remote inference provider. Bonjour-discovered
ephemeral providers are excluded.

| Property | Type | Values / meaning |
|----------|------|------------------|
| `provider_type` | string | The provider type enum only — never the user-chosen name, URL, or key |

### `mcp_provider_added`

Emitted when a user configures an MCP (tool) provider.

| Property | Type | Values / meaning |
|----------|------|------------------|
| `transport` | string | `http` or `stdio` — never the command, URL, or args |

### `agent_created`

Emitted when a user creates an agent. Built-in agents seeded by the app are
excluded. No properties — count only, with no name or configuration.

### Onboarding funnel

The onboarding funnel events — `onboarding_started`, `onboarding_step_viewed`,
`onboarding_step_skipped`, `onboarding_completed` — carry only a stable step
name/index and a completion reason. They are defined in
[`OnboardingTelemetry`](../Packages/OsaurusCore/Views/Onboarding/OnboardingTelemetry.swift).

## Remote identifiers

For user-configured **remote** providers, the provider name and model id are
free text you typed and can be identifying (for example,
`acme-internal/legal-bot`). We therefore:

1. Never send the provider name or the raw remote model id in plaintext.
2. Send `provider_type` (a fixed enum) as the primary remote dimension.
3. Send `model_hash`, a salted SHA-256 of the remote model id, truncated to 12
   hex characters, so the dashboard can count *distinct* custom models in
   aggregate without ever receiving the string.

**Honest limitation.** The salt is a fixed app constant (not a per-device
random) so that the same custom model produces the same hash across users —
that's what makes distinct-counting possible. The trade-off is that a fixed
salt plus a low-entropy input is **not** cryptographically irreversible: a
party holding the salt could brute-force a guessed string back to its hash.
This is an accepted trade-off because the hash is only ever applied to
user-typed remote ids (never to built-in catalog ids), it is truncated, and it
is only a secondary distinct-count signal — `provider_type` is the dimension
we actually rely on. Built-in Foundation and local MLX model ids come from a
curated catalog and are sent verbatim.

## Build & environment notes

- DEBUG builds report to Aptabase's **Debug** bucket (filtered out of
  production dashboards), so local testing never pollutes real metrics.
- The Aptabase key is injected at build time; without it the SDK stays
  uninitialized. See the [README](../README.md#local-development) for local
  setup.
