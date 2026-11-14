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
- **Off anytime** in **Settings → Privacy & Security → Data Collection → Share Anonymous Usage Data**.
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

The events are organized around four product questions.

| Pillar | Question | Primary signals |
|--------|----------|-----------------|
| Engagement | Are people using the core product? | `message_sent`, `chat_session_started`, `agent_run` |
| Workflows & automations | Do people build workflows and let them run on their own? | `workflow_run_started`, `workflow_run_finished`, `workflow_draft_started`, `automation_created`, `automation_run_finished` |
| Retention / lifecycle | Do people come back and run the server? | `daily_active`, `app_launched`, `server_started` |
| Feature adoption | Which features get used? | `model_downloaded`, `remote_provider_added`, `mcp_provider_added`, `agent_created`, `phone_paired`, `template_shared`, `workspace_created` |

Session counts, app version, OS version, and locale are derived by Aptabase
from its **anonymous** session model plus the events below. Cohort retention
is computed from event *counts* using the install-cohort dimensions described
under "Install cohort and age" — no persistent per-user identifier is added by
Osaurus to make this work.

## Common properties (every event)

Two coarse properties are attached automatically to **every** event by
`TelemetryService.track`:

| Property | Type | Values / meaning |
|----------|------|------------------|
| `total_memory_gb` | string | Coarse physical-RAM bucket for this Mac, snapped to a fixed tier: `8`, `16`, `18`, `24`, `32`, `36`, `48`, `64`, `96`, or `128+`. Sourced from `ProcessInfo.physicalMemory`. |
| `build_channel` | string | `release` (the shipped `com.dinoki.osaurus` app), `beta` (Osaurus Beta, `com.dinoki.osaurus.beta`), `proof` (a re-bundled live-proof app, any other `com.dinoki.osaurus.<id>`), `dev` (any other bundle id, or a Release build run from Xcode DerivedData or a SwiftPM `.build` directory), `debug` (DEBUG builds, which also report to the Debug bucket). Lets proof and dev builds, which report to the production bucket, be filtered out. |

This lets any metric (bounce, funnel, adoption) be segmented by machine class —
e.g. checking whether a 26B MoE bounces more on lower-RAM Macs — without
shipping an exact, potentially-identifying memory size. It is anonymous and
stays behind the same opt-out consent gate as every other event.

## Event catalog

### `model_memory_sample` (silent diagnostics)

Observed on the existing off-main two-second resource tick, independently of
chat windows. One initial observation per sampled local-model residency episode,
then phase/severity changes only, capped at eight events per episode. Very short
episodes between ticks can be missed. Synthetic QA states never transmit.
This uses the same consent gate and source-build no-key behavior described above.

| Property | Values |
|---|---|
| `phase` | `loading`, `resident` |
| `severity` | `none`, `elevated`, `critical` (existing swap-growth classifier) |
| `host_swap_gib`, `peak_swap_growth_gib`, `process_footprint_gib` | `0`, `<1`, `1-4`, `4-16`, `16-64`, `64+` GiB buckets |
| `host_swapins_pages_s`, `host_decompressions_pages_s` | `0`, `<100`, `100-1000`, `1000-10000`, `10000-100000`, `100000+`, `unknown` |

No model name/path, episode identifier, exact timestamp, content or token counts
are attached. The in-memory episode identifier only deduplicates ticks. Swap and
page rates are host-wide observations, not proof that Osaurus caused swapping or
that swapping caused slow generation. Peak growth follows the existing
cold-load-through-first-output observation window. These events never influence
admission, model selection, unload timing, samplers, caches, or macOS swap policy.

### Other events

Every property listed below is the complete event-specific set. In addition,
the common `total_memory_gb` and `build_channel` properties above are attached
to every event.
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
| `source` | string | The originating surface. Direct requests: `chat_ui`, `http_api`, `plugin`, `p2p`, `channel`, `agent`, `evaluation`, `scheduled`, `schedule`, `watcher`, `webhook`, `email`, `automation`, `self_schedule`, `tool`, or `system`. Model calls made on behalf of something else take precedence, in this order: `workflow` (a step of a workflow run), `subagent` (a delegated helper, Computer Use, or AppleScript loop), `synced_device` (a run hosted for another of the person's devices) |
| `model_source` | string | `foundation` (Apple on-device), `local` (MLX), or `remote` |
| `provider_type` | string | `foundation`, `mlx`, or the remote provider type enum (`openai`, `anthropic`, `gemini`, `azureOpenAI`, `openResponses`, `openAICodex`, `osaurus`) |
| `model` | string | The exact model id — **only** for `foundation`/`local` (curated, non-identifying). Omitted for remote. |
| `model_hash` | string | **Remote only.** Salted, truncated hash of the remote model id (see "Remote identifiers"). Omitted otherwise. |
| `is_agent` | bool | Whether the turn came from an autonomous agent run (the `/agents/{id}/run` endpoint) vs a plain completion |
| `stream` | bool | Whether a streaming response was requested |
| `capability` | string | What the request asked the model to do: `chat`, or `embedding` when a chat request resolved to a local encoder-only bundle. Classified from the bundle's `config.json` model type (never a model-name list), so new embedding models are bucketed automatically. Reserved for future API families (e.g. `search`). |
| `brain_source` | string | **`chat_ui` sends only** (omitted for every other `source`). The brain chosen in onboarding or in the first-run chat's Choose a Brain sheet, joined to activation: `local`, `hosted`, `provider_key`, `claude_code` — or an explicit fallback: `none` (onboarding ended without committing a brain), `pre_choice` (install completed onboarding before the choice existed), `unknown` (defensive; should not occur). Always present on chat-UI sends, so coverage of this dimension is total by construction. |

**Note on `brain_source` history.** Before the fallback tokens existed, the
property was simply omitted whenever no choice had been persisted, which left
an unattributable gap (roughly 20% of chat-UI messages on 0.22.x). Events from
those older versions cannot be backfilled; from the version introducing the
tokens onward, every chat-UI send carries a named bucket and the historical
gap is explained by the `none` / `pre_choice` composition. From 1.0 a brain
picked later in the Choose a Brain sheet replaces `none`.

**Note on `source` history (1.0, November 2026).** Before 1.0, workflow steps
and delegated helpers ran on chat-owned engines and reported as `chat_ui`
(with a `brain_source`), and runs hosted for a synced device reported under
their direct surface. From 1.0 they report as `workflow`, `subagent`, and
`synced_device`, and carry no `brain_source`. Expect `chat_ui` counts to drop
at the 1.0 boundary without any change in what people type; compare across
it with `chat_ui + workflow + subagent`, or use `first_time_chat_used` and
`chat_session_started` for activation.

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

### `attention_resolved`

Emitted when something that needed a person settles: a tool approval, an
owner approval for a shared agent, a clarifying question, a workflow form, and
so on (docs/AGENT_ATTENTION.md). Every value is a closed token. The requester,
agent, tool name, and any reply text are never attached.

| Property | Type | Values / meaning |
|----------|------|------------------|
| `kind` | string | `AttentionKind`: `tool_approval`, `owner_approval`, `clarification`, `workflow_dialog`, `config_approval`, `computer_use`, `secret_request`, `elicitation`, `inbound_message`, `inbound_shared_run`, `agent_notice` |
| `outcome` | string | `approved`, `denied`, `allowed_for_conversation`, `replied`, `dismissed`, `timed_out`, `abandoned`, or `retracted` (withdrawn by the app) |
| `surface` | string | Where it was answered: `inline`, `desktop`, `phone`, `push`, or `system` (no person) |
| `wait_bucket` | string | Time waited: `lt_10s`, `10_60s`, `1_5m`, `5_30m`, `gte_30m`, or `none` |

### `notification_delivered`

Emitted once per notification channel an item was delivered to.

| Property | Type | Values / meaning |
|----------|------|------------------|
| `kind` | string | `AttentionKind` token, as above |
| `channel` | string | `in_app`, `desktop`, `phone`, or `push` |

### `server_started`

Emitted when the local server transitions to running. No properties. (No port
or bind address is attached.)

### `sandbox_boot`

Emitted once per successful sandbox VM boot, when provisioning reaches the
running state. Full-fidelity phase timings stay in a local file
(`~/.osaurus/container/startup-metrics.json`); only the coarse dimensions
below are sent.

| Property | Type | Values / meaning |
|----------|------|------------------|
| `kind` | string | `cold` (full image unpack into the base template), `warm` (every container's environment clone reused), `template` (at least one environment cloned copy-on-write from the template), or `warmFallback` (booting from the template failed, a fresh unpack succeeded) |
| `duration_bucket` | string | Coarse total-boot latency bucket: `lt_1s`, `1_5s`, `5_15s`, `15_60s`, `1_5m`, `gte_5m` |
| `dominant_phase` | string | The longest measured boot phase: `asset` (kernel, initfs, and image download or lookup), `create` (image unpack into the template and environment clones), `vm_boot` (VM and container start), `configure` (in-guest setup), or `unknown` when no phase was measured |

### `sandbox_membership_restart`

Emitted when the sandbox VM restarts so another agent can get its own
container (the set of containers is fixed when the VM boots). No agent
identity is attached.

| Property | Type | Values / meaning |
|----------|------|------------------|
| `wait_bucket` | string | How long the restart waited for other agents' running commands and background jobs, in the `duration_bucket` buckets above |
| `interrupted_work` | bool | Whether that work was still running when the wait (capped at two minutes) ended |

### `sandbox_provision_failure`

Emitted once per distinct sandbox startup or per-agent provisioning failure
recorded by `SandboxToolRegistrar`. The cool-down and lockout notices that
follow one failure are local-only and do not re-emit. Every value is a token
from a closed list; the user-facing error message, paths, hosts, and agent
identity stay on the machine (a mirror of the same tokens is kept in
`~/.osaurus/container/startup-failures.json` and shown in Developer Tools → Sandbox →
Troubleshooting so users can self-report).

| Property | Type | Values / meaning |
|----------|------|------------------|
| `category` | string | `container_unavailable` (cold start could not provision), `runtime_start_failed` (a previously provisioned VM did not start or was lost), `agent_provision_failed` (VM up, per-agent bootstrap failed), `vmnet_in_use` (another Osaurus process owns the VM) |
| `backend` | string | `vm` (macOS 26+ Containerization VM) or `seatbelt` (macOS 15 and earlier `sandbox-exec` fallback) |
| `phase` | string | `availability`, `runtime_start`, `vm_ownership`, `agent_provision`, or the refined `agent_provision.bootstrap_exec` / `agent_provision.bootstrap_script` / `agent_provision.bootstrap_timeout` |
| `error_class` | string | One of `SandboxToolRegistrar.failureErrorClasses`: `sandbox_*` cases of `SandboxError`, `posix_*` (`eexist`, `ebusy`, `eaddrinuse`, `eacces`, `eperm`, `enospc`, `other`), `cocoa_*` (`file_exists`, `out_of_space`, `no_permission`, `other`), `url_*` (`offline`, `timeout`, `dns`, `other`), `sdk_grpc`, `sdk_vmnet`, `cancelled`, `none`, `other` |
| `trigger` | string | What ran the registration: `launch_autostart`, `on_demand` (first sandboxed tool use), `agent_switch`, `agent_updated`, `status_change`, `auto_retry`, `runtime_recovery`, `external` (chat send / plugin host / evals) |
| `cold_start` | bool | `true` when the sandbox had never completed setup on this machine (first-run download path), `false` for a warm restart |
| `owner_state` | string | `vmnet_in_use` only. Who holds the VM lease: `self` (this process leaked it), `osaurus_alive` (another Osaurus app or eval process), `other_alive` (a non-Osaurus process has the lease file open, e.g. a child that inherited it), `owner_dead_lock_held` (the recorded owner exited but the lock is still held), `unknown`. The holders' PIDs and paths are recorded only in the local failure file |
| `bootstrap_step` | string | `agent_provision.bootstrap_script` only. The script line that failed: `adduser`, `chmod_home`, `plugins_dir`, `token_dir`, `token_write`, `token_chown`, `soul_seed`, or `unknown` |

### `app_launched`

Emitted once at launch. Carries the three install-cohort dimensions below
(see "Install cohort and age") so launches can be segmented by cohort, plus
which kind of Space the app opened in.

| Property | Type | Values / meaning |
|----------|------|------------------|
| `install_cohort` | string | ISO week the install belongs to, e.g. `2026-W38` |
| `install_age_days` | string | Whole local calendar days since the install's first launch: `0`, `1`, … `364`, or `365+` |
| `install_cohort_source` | string | How the install date was determined: `install`, `inferred`, or `unknown` |
| `space` | string | `default` for the Default Space, `custom` for any other Space. A new Space has its own preferences, so it reports as a fresh install; filter on `custom` to drop those runs from the fresh-install funnel |

### `daily_active`

Emitted **at most once per local calendar day per install**, on the first
launch (or first event-producing launch) of that day. Carries exactly the
three install-cohort dimensions listed under `app_launched`. This is the
retention numerator and denominator: launch frequency within a day cannot
inflate it, and it does not depend on Aptabase's own daily-user heuristic.

### Install cohort and age

Aptabase has no user id, and the daily user count it derives server-side is
not joinable across days. Cohort retention therefore cannot be computed from
`app_launched` alone. Instead, each install keeps a **first-launch date**
locally (in `UserDefaults`) and sends two derived, low-cardinality dimensions:
the ISO week of that date and the number of days since it. Day-N retention
for cohort W is then a ratio of two counts:

```
count(daily_active where install_cohort = W and install_age_days = N)
count(daily_active where install_cohort = W and install_age_days = 0)
```

No identifier is involved — this is the same pattern as `brain_source` and
`total_memory_gb`: a fact stored on the device, attached as a coarse bucket.

**How the date is determined** (`install_cohort_source`):

- `install` — the install's first-ever launch stamped the current date.
- `inferred` — the install predates this dimension (it existed before the
  version that introduced it). Its date is the earliest filesystem creation
  time of the Osaurus data directories (`~/.osaurus`, and the retired
  `~/Library/Application Support/com.dinoki.osaurus` where it still exists).
  Day-level precision; two file-metadata reads, no database is opened.
- `unknown` — the install predates this dimension and neither data directory
  could be inspected. The stamp is the launch that introduced the dimension.
  Dashboards should exclude these rows from cohort math.

The stamp is written once and never updated, so re-running onboarding or
upgrading cannot move a user between cohorts. Caveats: resetting
`UserDefaults` (or a fresh macOS user account) starts a new cohort, and
combining `install_cohort` with `install_age_days` and the event date can
reconstruct the install *day* — a ~365-valued bucket per year, not an
identifier.

### `model_downloaded`

Emitted when a model finishes downloading and is verified on disk.

| Property | Type | Values / meaning |
|----------|------|------------------|
| `model` | string | Curated-catalog model id (safe to send) |
| `param_count` | string | Coarse size, e.g. `7B` (omitted if unknown) |
| `quantization` | string | e.g. `4-bit` (omitted if unknown) |
| `is_vlm` | bool | Whether the model is a vision-language model |

### `remote_provider_added`

Emitted when a user configures a remote inference provider. Ephemeral
providers (eval harness and test fixtures) are excluded.

| Property | Type | Values / meaning |
|----------|------|------------------|
| `provider_type` | string | The provider type enum only — never the user-chosen name, URL, or key |

### `mcp_provider_added`

Emitted when a user configures an MCP (tool) provider.

| Property | Type | Values / meaning |
|----------|------|------------------|
| `transport` | string | `http` or `stdio` — never the command, URL, or args |

### `agent_created`

Emitted when an agent is created. Built-in agents seeded by the app are
excluded. No name, prompt, or configuration is attached.

| Property | Type | Values / meaning |
|----------|------|------------------|
| `number_of_agents` | int | Total agents on the install after this one was added (built-in included). Lets the dashboard derive the typical number of agents per user. |
| `origin` | string | `user` (New Agent or the setup wizard), `team_seed` (the day-one team, Create Starter Agents, or a discovery card adding a teammate), `template_install`, `import` (`osaurus import` bundles), `config` (the Configurator, the admin API, or a phone-approved apply), or `plugin`. Filter on `user` for agents people made themselves; before 1.0 the property was absent and every row meant a user-made agent. |

### Agent creation chat

The New Agent chat funnel. Counts and field ids only.

| Event | Properties |
|-------|------------|
| `agent_creation_started` | `source`: `agents_page`, `discovery`, or `deeplink` |
| `agent_creation_drafted` | none — the Configurator's first change to the draft |
| `agent_creation_edited` | `field`: `name`, `description`, `avatar`, `model`, `tools`, or `instructions` — the first hand edit of that field, never its value |
| `agent_creation_finished` | `user_messages`, `edited_fields`: counts; `needed_setup`: bool, whether the setup wizard ran first |
| `agent_creation_abandoned` | `touched_fields`: count — closed before Create (the draft stays resumable) |

### `settings_opened`

Emitted when the Settings (management) window is opened, and again on each
tab switch while it is open. The hidden launch-time window prewarm never
emits. Exists to measure whether early detours into settings correlate with
lower activation. No setting names or values are ever attached.

| Property | Type | Values / meaning |
|----------|------|------------------|
| `tab` | string | Stable token for the settings tab (closed enum): `general`, `chat`, `voice`, `orchestrator`, `architect`, `configurator`, `delegation`, `models`, `providers`, `image_generation`, `agents`, `agent_channels`, `agent_runtimes`, `memory`, `projects`, `knowledge`, `tools`, `search`, `skills`, `commands`, `workflows`, `automations`, `approvals`, `tasks`, `sandbox`, `computer_use`, `browser`, `server`, `privacy`, `permissions`, `identity`, `credits`, `workspaces`, `access`, `devices`, `connect`, `insights`, `model_defaults`, `keys`. Opening `workflows` redirects to the Workflows surface, which reports `workflows_opened` instead. |
| `before_first_message` | bool | Whether this install has never sent a chat-UI message yet — separates pre-activation settings visits from post-activation ones |

### Workflows

| Event | Properties |
|-------|------------|
| `workflow_run_started` | `caller`: who started it — `agent` (an agent's workflow tool), `orchestrator` (`run_workflow`), `user` (a workflow tab or the Workflows screen), `test` (an Architect test run), `workflow` (a step of another workflow), or `event` (an automation); `resumed`: bool, a run continuing after a pause |
| `workflow_run_finished` | `caller`, as above; `status`: `completed`, `failed`, `cancelled`, `needs_setup`, or `awaiting_user` (paused for a person); `duration_bucket`: `lt_10s`, `10_60s`, `1_5m`, `5_30m`, `gte_30m`, or `none` |
| `workflow_draft_started` | `origin`: `blank` (new in the Architect), `edit` (a saved workflow opened in the Architect), or `inline` (a chat handed a task to the Architect) |
| `workflows_opened` | `page`: the page it opened on — `home`, `workflow`, `run`, or `new`. Fires when the surface comes on screen, not on navigation inside it |

Each step of a run also sends `message_sent` with `source=workflow`.

### Automations

| Event | Properties |
|-------|------------|
| `automation_created` | `trigger`: `schedule`, `folder`, `webhook`, `rss`, `sse`, `run_failed`, `app`, `email`, or `channel_message`; `origin`: `user` (Settings or the editor) or `config` (`osaurus_config`, including onboarding's Turn On). Automations an agent schedules for itself and those a plugin installs are not counted |
| `automation_run_finished` | `trigger`, as above; `status`: `succeeded`, `failed`, `cancelled`, or `awaiting_user`. Deliveries dropped as filtered or duplicate never reach this |

### Computer Use

| Event | Properties |
|-------|------------|
| `computer_use_attempt` | none — the model invoked `computer_use` (the funnel's denominator) |
| `computer_use_refused` | `stage`: the gate that stopped it before the loop began — `permission_accessibility`, `agent_auth`, `model_unavailable`, `handoff_denied`, `recursion`, `admission_timeout`, `ram_safety`, `cancelled`, or `other` |
| `computer_use_run` | `outcome`: `done`, `gave_up`, `dead_end`, `step_cap`, `interrupted`, or `failed`; `max_tier`: `ax`, `som`, or `vision`; `steps_bucket`, `confirms_bucket`, `unverified_acts_bucket`: `0`, `1-3`, `4-9`, `10+`; `ax_resolvable`, `verify_pass`: `low`, `med`, `high`, or `na`; `had_dead_end`, `had_block`, `cloud_vision_used`, `done_without_change`: bool; `route_used`: `sky_light`, `per_pid`, `hid_fallback`, `mixed`, or `none` |

Never the goal, the app, or anything on screen.

### Credits

| Event | Properties |
|-------|------------|
| `balance_topup_initiated` | none — a Checkout session for a credits top-up opened. No amount |
| `balance_topup_succeeded` | none — the balance rose after returning from Checkout (best effort) |

### Announcements and history import

| Event | Properties |
|-------|------------|
| `announcement_shown` | `slug`: the operator-defined announcement key |
| `announcement_clicked` | `slug`; `action`: `dismiss` or `cta`; for `cta`, `cta_kind` (`external_url` or `deeplink`) and `cta_index` (0-based) |
| `import_history_prompt_shown` | none — the one-time post-onboarding import prompt appeared |
| `import_history_prompt_clicked` | `action`: `import` or `skip` |
| `chat_history_imported` | `source`: `sidebar`, `onboarding_prompt`, or `discovery`; `imported`, `duplicates`, `unreadable`, `failed_files`: counts. Never file names, formats, or content |

### Phone and Sync

No device name, key, or id is attached.

| Event | Properties |
|-------|------------|
| `phone_paired` | none — a phone finished pairing (simulators excluded) |
| `phone_unpaired` | `via`: `mac` (removed here) or `phone` (the phone unpaired itself) |
| `sync_device_paired` | `platform`: `iphone` or `other` — a device joined this Mac's Sync account |
| `sync_device_removed` | `rotated_keys`: bool, whether the account's keys were replaced with the removal |

### Templates

| Event | Properties |
|-------|------------|
| `template_shared` | `kind`: `workflow` or `agent`; `visibility`: `public`, `hidden`, `password`, or `workspace`; `bundled_published`: how many workflows an agent share published with it |
| `template_imported` | `kind`, as above; `origin`: `registry` (the store, a link, or a workspace catalog) or `file`; `result`: `new`, `update`, `copy` (kept both), `replace`, `older` (older than the newest version here, stored for history only), or `already_present` (the same version and content) |

### Account, keys, and credentials

Never the site, account, key, label, or value.

| Event | Properties |
|-------|------------|
| `login_with_osaurus` | `outcome`: `signed_in`, `answered_error` (the error was delivered to the site), or `rejected_locally` (the request could not be answered safely; only the person saw it) |
| `access_key_created` | none |
| `access_key_revoked` | none |
| `credential_saved` | `scope`: `shared` or `agent`; `origin`: `user`, `mcp`, `plugin`, `channel`, `workflow`, `sandboxPrompt`, or `config`. New credentials only; updates and legacy migrations are not counted |
| `credential_deleted` | `scope`, as above. The bulk removal when an agent is deleted is not counted |

### Spaces, workspaces, and sharing

No names, codes, or prices are attached.

| Event | Properties |
|-------|------------|
| `space_created` | none |
| `space_switched` | none — the switch was confirmed and the app is relaunching |
| `space_deleted` | `mode`: `immediate` or `after_relaunch` |
| `workspace_created` | `via`: `direct`, `checkout` (after a browser purchase), or `activation_code` |
| `workspace_joined` | none |
| `workspace_agent_shared` | none — an agent was shared into a workspace |
| `guest_access_revoked` | `state`: `active` (a guest who had connected) or `unused_link` |
| `shared_agent_added` | none — another person's agent was added from a guest link |

### Onboarding funnel

The onboarding funnel events — `onboarding_started`, `onboarding_step_viewed`,
`onboarding_step_skipped`, `onboarding_completed` — carry only a stable step
name/index and a completion reason. They are defined in
[`OnboardingTelemetry`](../Packages/OsaurusCore/Views/Onboarding/OnboardingTelemetry.swift).

**Note on `step_index` (1.0).** The 1.0 onboarding window has two steps,
`welcome` (index 0) and `configure_ai` (index 1); the rest of setup moved to
the first-run chat below. Earlier versions had more steps, so the same index
named a different step. Key funnels on `step`, which is stable across
versions, not on `step_index`.

The Configure AI step adds `brain_source_selected` when the user chooses
Osaurus Cloud, downloads a local model, connects a provider, or chooses
Claude Code. Its low-cardinality `source` is `hosted`, `local`,
`provider_key`, or `claude_code`; the provider path adds the closed-enum
`provider` type and the local path adds boolean `download_started` — whether
committing kicked off a background model download. `surface` is
`onboarding` (the onboarding window) or `chat_sheet` (the Choose a Brain
sheet over the first-run chat, for people who left the window without a
model). No key, model id, or URL is ever attached.

`team_seeded` fires when the day-one team is created: `source` is
`fresh_install` (end of onboarding) or `starter_agents` (Settings' Create
Starter Agents); `teammates` and `workflows` count what was created;
`developer_mac` is whether this Mac got Builder and Repo Digest. The
teammates themselves arrive as `agent_created` with `origin=team_seed`.

#### First run in chat and discovery

Every property is a closed token or a count: no message text, file or folder
name, workflow input or output, or model id is attached. The first-run
events carry `distribution` like the rest of the funnel.

| Event | Properties |
|-------|------------|
| `onboarding_agent_opening_shown` | `brain`: `local`, `bridged`, `downloading`, `provider`, `cloud_connecting`, or `none` |
| `onboarding_brain_chooser_opened` | none — the Choose a Brain sheet opened over the first-run chat; the denominator for its `brain_source_selected` with `surface=chat_sheet` |
| `onboarding_agent_path_selected` | `path`: `planner`, `courier`, `keeper`, `scout`, `builder`, or `skip` |
| `onboarding_agent_finished` | `reason`: `first_task` or `dismissed`; `step`: the step it ended on (`brain`, `choice`, `first_task`, `keep`); `ask`: whether an authored ask ran |
| `onboarding_keep_resolved` | `offer`: `turn_on` (a discovery card's offer to run a default workflow on its own); `outcome`: `taken`, `declined` (the approval card was refused), or `failed` |
| `discovery_card_shown` | `item`: the discovery id (below); `new`: false when the card was shown before |
| `discovery_opened` | `item`; `source`: `card` or `set_up` |
| `discovery_taken` | `item` — the walkthrough's primary step was taken |
| `discovery_declined` | `item`; `via`: `dismiss` (retired for good) or `not_now` |
| `discovery_completed` | `item` — an item that had shown as a card became done in app state |
| `discovery_toggled` | `enabled`: bool — Show Discovery Cards changed; `source`: `settings`, `greeting` (Skip setup under a new chat's greeting), or `undo` (that notice's Undo) |
| `set_up_osaurus_opened` | `source`: `menu` or `settings`; `remaining`: how many items it listed |

Discovery ids: `try_workflow`, `turn_on_workflow`, `keeper_folders`,
`keeper_redaction`, `history`, `people`, `navigator`, `builder`, `own_agent`,
`privacy_ai`, `search`, `shortcuts`, `store`, `messages`, `phone`,
`encryption`, `music`, `voice`, `memory`, `tool_server`, `channels`,
`skills`, `orchestrator_folder`, `computer_use`. Older versions also sent
`working_folder`, which is no longer an item. `chat_history_imported` gains the `source`
value `discovery` for an import started from a card.

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
  uninitialized. See [Telemetry in local builds](CONTRIBUTING.md#telemetry-in-local-builds)
  for local setup.
