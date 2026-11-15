# Automations

Automations are the one way work starts on its own in Osaurus. In the UI an
automation is **When → Only When → Do → Queue → Reply**; in code it is an
*event* (`OsaurusEvent`, `EventManager`, `/events/{token}`) — the internal
names predate the rename and are kept. An automation is

```
source  →  filter  →  action  →  queueing  →  reply
(when)     (only when) (agent | workflow) (lanes, dedupe) (channel sources)
```

and it replaces three older systems: Schedules, Watchers, and each channel
connection's `inboundDispatch` routing. Every automation is a file in
`~/.osaurus/events/<id>.json`; every fire is a row in the run ledger.

Every fire that runs is a **Task** on a queue (Default unless the automation
picks another): admission, concurrency, the journal and the Tasks tab are
described in `docs/TASK_QUEUE.md`. The run ledger below is a projection of the
task.

User-facing guide: `Packages/OsaurusCore/Resources/Guide/guide-automations.md`
(`osaurus_help` topic `automations`; `events`, `schedules` and `watchers`
resolve to it).

Channels and Automations split responsibilities: **Channels** (Capabilities
sidebar group) is where agents talk — connections, credentials, allowlists,
the Outbox, and per channel **Agents on this channel** (who answers, whether
the reply is sent automatically, who may post on its own; see
`docs/AGENT_CHANNELS.md`, "Inbound routing is automations"). **Automations**
(pinned at the top of the Settings sidebar) is what runs on its own —
schedules, folders, webhooks, feeds, event streams, failure handlers and app
events. `channel_message` automations (channel routing rules) are not listed
there: they are edited in Channels → the platform → Routing, and Automations
shows only a note with their count and **Open Channels**. Every run is a task
in **Tasks → History**.

## Model (`Models/Event/`)

`OsaurusEvent` (`OsaurusEvent.swift`):

| Field | Meaning |
| --- | --- |
| `source` | `.schedule(ScheduleSourceConfig)`, `.folder(FolderSourceConfig)`, `.webhook(WebhookSourceConfig)`, `.rss(RSSSourceConfig)`, `.sse(SSESourceConfig)`, `.runFailed(RunFailedSourceConfig)`, `.app(AppEventsSourceConfig)`, `.email(EmailSourceConfig)`, `.channelMessage(ChannelMessageSourceConfig)` (the four newer configs are in `TriggerSourceConfigs.swift`) |
| `filter` | `EventFilter`: `senderAllowlist`, `keywordsAny`, `keywordsAll`, `pathGlobs`, `conditions` (payload path = value) |
| `action` | `.agent(AgentEventAction)` (target, instructions, working folder, `freshSessionPerFire`), `.workflow(WorkflowEventAction)` (workflow id, input mapping, run-as agent) or `.prompt(PromptEventAction)` (instructions, optional model: one tool-less generation by `PromptRunWorker`, saved as an `.automation` chat; never on channel rules, never the Default agent) |
| `delivery` | `EventDeliveryPolicy`: `mode` (serial / perConversation / parallel), `maxConcurrent`, `maxQueued`, `steerRunningTurn`, `dedupe` (`EventDedupePolicy`: `none` / `window(seconds)` / `durable`), `missedFirePolicy` |
| `reply` | `EventReplyPolicy`: `autoReply` (agent) / `replyWithWorkflowOutput` (workflow) |
| state | `lastFiredAt`, `lastRunAt`, `lastStatus`, `lastSessionId`, `lastWorkflowRunId` |

Defaults per source come from the kind's descriptor
(`EventDeliveryPolicy.defaults(for:)`, `AgentEventAction.defaultFreshSession(for:)`):
schedules and webhooks start a new chat per fire; folders keep one
chat so convergence passes share context; channels keep one per
conversation.

`delivery` is stored as `dedupe` (the mode) plus `dedupeWindowSeconds`. A
file without `dedupe` decodes as `window(dedupeWindowSeconds)`, and
`window(0)` is `none`, so files written before the substrate load unchanged.

`EventPayload.swift` builds the normalized JSON each occurrence carries:

```
event:    { id, name, source_kind }      fired_at: ISO-8601
text:     the main text (message, body, changed files)
schedule: { scheduled_for }              folder:  { path, changed_paths }
webhook:  { method, headers, query, body, content_type, event_type? }
feed:     { url, title, item: { id, title, link, published, author, summary, content, categories } }
sse:      { url, event, id, data }       data: parsed JSON when it parses, else the text
failure:  { kind: workflow_run | automation_run, run_id, error, workflow: { id, name }?,
            failed_step: { id, name?, kind? }?, automation: { id, name }?, caller, started_at, finished_at? }
app:      { reason: app_launched | automation_enabled | automation_updated, app_version, automation: { id, name } }
email:    { message_id, thread_id?, subject, from, from_name?, to, cc, date, mailbox, account,
            connection_id, snippet, body?, is_read, size?, attachments: [{ name, mime, size }] }
message:  { text, platform, connection_id, room_id, thread_id, sender_id, sender_name, attachments }
```

`email` is carried by Email channel messages (next to `message`); no
automation kind produces it anymore.

Webhook headers are redacted (`authorization`, `cookie`, `*signature*`,
`*secret*`, `*token*`) before they enter the payload. `EventTemplate` renders
`{{path}}` bindings (unknown roots are left as written);
`WorkflowInputMapper` maps payload → workflow input and coerces to the input
schema's declared types.

`EventRun` (`EventRun.swift`) is one ledger row: status
(`received`, `queued`, `running`, `awaitingUser`, `succeeded`, `failed`,
`cancelled`, `suppressed`, `filtered`, `duplicate`), reason, dedupe and
conversation keys, session / workflow run ids, timings, error, and a
`summary` of metadata (sizes, ids — never bodies).

## Pipeline (`Services/Event/`)

`EventManager` (`@Observable @MainActor`, `.shared`) owns the events, the
sources and the queue.

1. A source builds an `EventOccurrence` (payload, trigger `source`/`manual`,
   dedupe key, conversation key, optional agent prompt and folder, external
   flag, load intent, reply sink) and calls `submit`.
2. `admissionRejection`: disabled (source fires only — Run Now still runs),
   filter (`EventMatcher.filterRejection`), duplicate (see "Uniqueness"
   below; manual fires are never duplicates), a deleted target
   (`EventInspection.targetProblem`: `agent_deleted`, `workflow_deleted`,
   `channel_deleted`, `connection_deleted`; the list and detail show the same
   problem), unavailable
   agent (none chosen, or the built-in Default agent) or workflow. Rejections
   settle at once as `suppressed` / `filtered` / `duplicate` rows. Automations
   whose target is deleted are kept, never auto-disabled.
3. The fire becomes a task submitted to `TaskScheduler` on the automation's
   queue ([TASK_QUEUE.md](TASK_QUEUE.md)), with a lane limit per event
   (`serial`, `parallel` with `maxConcurrent`) or per event + conversation
   (`perConversation`) and a per-agent limit. Past `maxQueued` a fire is
   refused (`busy` when the event holds no queue, `queue_full` otherwise);
   the queue's own `maxConcurrent` caps background work across automations.
4. When the scheduler starts it, the worker runs the action. Agent
   (`AgentTurnWorker`): `BackgroundTaskManager` with a `DispatchRequest` from
   `dispatchRequest(event:action:occurrence:)` (session key per event, or per
   webhook conversation; the folder occurrence's path wins over the action's
   working folder; `externalSurface` for webhook and remote fires). Workflow
   (`WorkflowRunWorker`): `workflowInput` → `WorkflowRunService.start` with
   `WorkflowCaller(kind: .event, …)` → `settledOrParked`. Ask a Model
   (`PromptRunWorker`): the action's model (else the default model for new
   agents), one `ChatEngine` completion with no tools and implicit sampling
   (the bundle's defaults), the trigger's untrusted content wrapped as for an
   agent turn (`AgentTurnWorker.wrappedPrompt`); the prompt and answer are
   saved as an `.automation` chat keyed by the event id.
5. Settle: the row is finalized, the event's state updated, the ledger pruned
   (500 rows per event, 30 days; also once on `EventManager.start()`, so
   filtered-only traffic is trimmed too), `EventActivityLogger` writes
   Insights, and a channel workflow event replies through `ChannelReplySink`.
   The sink posts only while `ChannelWriteKillSwitch` allows writes; otherwise
   the delivery is logged as `blocked` (`global_writes_disabled`).

`EventManager.runAction` is the seam tests replace to drive the pipeline
without real runs.

### Sources

- **Schedule** (`ScheduleEventSource`): one timer armed for the soonest slot
  (`ScheduleTiming`), re-armed on change and on time-zone change. On launch
  `fireMissed` runs (or, with `missedFirePolicy: .skip`, ledgers as
  `missed_skipped`) the latest slot missed while the app was closed. The slot
  is the dedupe key; a one-shot turns itself off after its slot is submitted.
- **Folder** (`FolderEventSource`): one FSEvents stream over every enabled
  folder, a per-event debounce (`Responsiveness`), and the convergence loop:
  fingerprint → run with the changed paths → settle → re-fingerprint, up to 5
  passes, so an agent's own edits cannot loop forever. Nested watched folders
  are excluded from the outer event. The convergence anchor is persisted in
  `event_source_state` (`event:<id>:folder`, with the path it was taken of),
  so a relaunch diffs against it: files changed while the app was closed fire
  one pass at launch. Before the substrate the folder re-baselined on every
  launch and those changes were never seen. Disabling, re-pointing or
  deleting the automation drops the anchor.
- **Webhook** (`WebhookEventSource`, behind `EventWebhookIngress` and
  `HTTPHandler`): see below.
- **RSS Feed** (`Services/Event/Feed/`): a `poll` scope per automation
  (`rss:<uuid>`, interval from the config). `URLSessionFeedFetcher` sends
  `If-None-Match` / `If-Modified-Since` (a 304 is a quiet tick) and caps the
  body at 5 MB, stopping the read as soon as it passes; `FeedParser` reads RSS 2.0, RSS 1.0/RDF, Atom and JSON Feed
  (item id = guid / id, else link, else a hash of title + date). The scope
  state (`RSSFeedState`) keeps the validators and the last 500 item ids. The
  first ever tick records a baseline and emits nothing (as n8n does); later
  ticks emit unseen items oldest first, at most `maxItemsPerTick`. Dedupe is
  `durable` on `rss:<item id>`, so a restart never re-runs an item; the
  catch-up policy (default `latest_only`) applies to the first tick after
  launch. `sample(for:)` fetches the newest item for Run Now.
- **Event Stream** (`Services/Event/Stream/SSEEventSource.swift`): a
  `stream` scope per automation (`sse:<uuid>`) with the config's heartbeat
  timeout. `URLSessionSSEConnector` requires a 2xx `text/event-stream`
  answer; `SSEFrameParser` (over `OpenAICompatibleStreamFramer.SSELineParser`)
  assembles `event` / `data` / `id` / `retry` fields and comments, which
  count as heartbeats. The last event id is saved as scope state and sent as
  `Last-Event-ID` on reconnect; messages filtered out by `eventNames` still
  advance it. A message (or one line) over 256 KB, the webhook body limit,
  is skipped without dropping the connection: its id still advances and the
  detail shows the skip as the source's problem. Dedupe is a window on
  `sse:<id>` when the server sends ids.
- **Run Failed** (`RunFailedEventSource`): observes
  `.workflowRunFinished` (every installed workflow's run, whoever started
  it) and is called from `EventManager.finalize` for a failed automation run
  that never started a workflow run (agent actions, admission-time
  failures), when the handler sets `includeAutomationRuns`. Never re-entrant:
  runs a run-failed automation started, and its own failures, fire nothing.
  Test runs are skipped; runs nested in another workflow (`caller.kind ==
  .workflow`) are reported only to handlers that name that workflow. Dedupe
  is a window on `failure:<run id>`.
- **App Event** (`AppEventsSource`): `start()` fires `app_launched` once per
  launch; `eventDidChange` (the adapter hook `EventManager.create` / `update`
  call) fires `automation_enabled` when the automation is created on or
  turned on, and `automation_updated` when it is saved with a change other
  than run bookkeeping (`AppEventsSource.isEdit`), so a config re-apply that
  writes it back unchanged fires nothing. No dedupe.
- **Email** (`Services/Event/Email/`): retired; mail is a channel. See
  "Email (retired trigger; now a channel)" below.
- **Channel message** (`ChannelMessageEventSource`): each platform service
  calls `EventManager.ingestChannelMessage` after its own gates;
  `EventMatcher.rankChannelEvents` picks alias → room-scoped → any-room. Agent
  events go through `AgentChannelInboundRelay` (sessions, steering, typing,
  sanitized replies, `onOutcome` back to the ledger) — always one turn per
  conversation, with the event's `delivery.maxQueued` (0 = refuse with
  `conversation_busy`, else `conversation_queue_full` past the cap) and
  `delivery.steerRunningTurn` (fold follow-ups into the running turn, or queue
  them); the relay's auto-reply honors the same kill switch as the sink; workflow events go
  through `submit` with a `ChannelReplySink`. `ChannelEventListeners` is a
  locked snapshot the platform services and badges read off the main actor.
  A message no automation claims writes a channel audit row
  (`action: unclaimed_message`, `status: denied`, `reason`:
  `no_event_configured` / `no_event_for_room` / `mention_required` /
  `no_event_matched`) via `EventManager.unclaimedAuditRecord`, so History can
  show it.

## Source substrate

What a source kind is made of, so a new one (email, RSS, a provider
webhook, a stream) is a descriptor, an adapter and a config struct rather
than edits across the pipeline.

### Descriptor (`Models/Event/EventSourceDescriptor.swift`)

`EventSourceRegistry.descriptor(for:)` (also `EventSourceKind.descriptor`)
is the one lookup for everything static about a kind: display name, icon,
picker subtitle and whether it is offered in Add Automation, payload root,
`SessionSource` and `RequestSource`, default delivery and fresh-session
policy, `dedupeMode` (`none` / `window` / `durable`), `emitMode`
(`perItem` / `perBatch`), the connection types it uses, the History chip, the
filter clauses the editor shows, trigger values, workflow-input bindings, and
which payload text is untrusted (wrapped by `ChannelRemoteSafetyGate` before
it reaches a prompt). `EventTemplate.payloadRoots`, `EventTriggerValues`,
`EventActivityLogger`, `EventInspection` and the History chips all read it.

Config-dependent code (summaries, sample payloads, the `ConfigEvents`
document round-trip) stays on exhaustive `switch`es over the closed
`EventSource` enum, so adding a case is a compile error everywhere it must be
handled.

### Adapter (`Services/Event/EventSourceAdapter.swift`)

`@MainActor protocol EventSourceAdapter`, one per kind, built by
`EventManager.makeAdapter(for:)`. Everything but `kind`, `stop`, `reconcile`,
`fireNow` and `status` has a no-op default.

| Hook | Called |
| --- | --- |
| `start()` / `stop()` | `EventManager.start()` (after a first `reconcile`) and `stop()` |
| `reconcile(events)` | every change to the event list (`didChangeEvents`) |
| `forget(id)` | delete, or a source change; drops runtime state and persisted state |
| `cancel(id)` | Stop Runs |
| `install(event)` / `uninstall(event)` | enabled on create, or turned on, or re-sourced / turned off, deleted. Provider-side setup (register a webhook, a subscription); a failure is shown on the status, never disables the automation |
| `reconcileInstalled(events)` | launch, after `start`, for the kind's enabled events (verify the provider still has what `install` made) |
| `sample(for:)` | Run Now without a sample: the newest real item, when the kind can fetch one |
| `fireNow(event, sample:)` | Run Now (`EventManager.fireNow` checks busy first) |
| `eventDidChange(event, previous:)` | after `create` (previous nil) and every `update` of an event of this kind, including turning it on or off; `previous` is nil when the source kind changed. Not called for run bookkeeping |
| `status(id)` | `EventSourceStatus` for the detail and `osaurus_inspect` |

`EventSourceStatus` is generic: phase (`idle`, `folder(WatcherPhase)`,
`polling`, `connecting`, `connected`, `paused`), last/next check, cursor,
`installed`, `lastError`, and a free-form note. `EventManager.sourceStatus` is
the observable copy; `EventDetailView.sourceStatusRows` renders it in the
**When** step (Last check, Next check, Connection, Position, Provider setup, a
"The source reported a problem" finding). `isActive` (the list's running dot)
is a non-idle folder phase only.

### Ledger tables (`Storage/EventRunDatabase.swift`, schema v2)

- `event_seen_keys (event_id, dedupe_key, run_id, seen_at)`: delivery ids
  admitted under `durable` dedupe. Written at admission, pruned on their own
  90-day retention (`pruneSeenKeys`, run by `pruneAll`), never with
  `event_runs`.
- `event_source_state (scope_key, state_json, updated_at)`: adapter-defined
  JSON per scope. Scopes are `event:<uuid>:<suffix>` for per-event state (the
  folder anchor, a provider webhook id) or adapter-chosen keys for shared
  state (`conn:<id>:<mailbox>` poll cursors). `EventManager.sourceState` /
  `setSourceState` read and write it; deleting an event deletes its seen keys
  and every `event:<uuid>:` scope.

### Connections (`SourceConnection`, `SourceConnectionStore`, `SourceCredentialVault`)

An account a source reads from, shared by any number of automations. One
JSON file per connection in `~/.osaurus/connections/`, secrets in the
Keychain under `ai.osaurus.sources` (`<connection-id>:<field>`), never
exported. `SourceConnectionType` declares its auth shape: `none`,
`secret(fields:)`, or `oauth2(SourceOAuth2ProviderProfile)` (PKCE and
refresh through `SourceOAuth2Service`, which reuses the MCP OAuth pieces; no
provider profile ships yet). Deleting a connection an automation uses is
refused with the automations' names; an automation whose connection is gone
is skipped with `connection_deleted`.

### Runtime (`Services/Event/SourceRuntimeSupervisor.swift`)

An actor that runs adapter-registered scopes, so an adapter supplies one
tick or one stream and the supervisor owns timing:

- `poll(interval)`: an immediate first tick, then interval + jitter;
  exponential backoff on failure (base · 2ⁿ, capped at 15 minutes). The first
  tick with saved state applies the scope's `SourceCatchUpPolicy`
  (`since_cursor`, `latest_only`, `skip`). The tick's occurrences are
  submitted first, then its state is committed, so a crash in between
  re-delivers rather than loses (durable seen keys absorb the repeat).
- `stream`: a long-lived `stream(context)` the driver owns (IMAP IDLE, SSE,
  MQTT); reconnect with backoff, a forced reconnect interval, and a heartbeat
  timeout.
- `maintenance(interval)`: renewal ticks (Graph subscriptions, Gmail watch).

`register(scopes, owner:)` replaces an owner's scopes (unchanged ones keep
running), `tickNow` wakes a scope at once (for a "check now"), `stopAll` runs on
`EventManager.stop()`. Status goes back through `SourceRuntimeReport` →
`EventSourceStatus.apply`.

### Webhook provider profiles (`Services/Event/WebhookProviderProfile.swift`)

`WebhookEventSource.receive` is driven by a `WebhookProviderProfile` picked
from `WebhookSourceConfig.provider`: a verifier (`none`,
`sharedSecretHeader`, `hmacSHA256(header, prefix)`, `timestampedHMAC` for
Stripe `t=,v1=` and Slack `v0:ts:body` with a 5-minute window,
`hmacSHA1OverURLAndForm` for Twilio, `hmacBase64` for Shopify,
`graphClientState`), pre-auth handshakes (Slack `url_verification`, Graph
`validationToken`, Meta `hub.challenge` on GET, SNS
`SubscriptionConfirmation` with an `sns.*.amazonaws.com` check), delivery-id
and event-type extractors (headers or body paths; the type fills
`webhook.event_type`), whether the provider issues the secret, an optional
notify-then-fetch `fetcher`, and an optional `registration`
(install/uninstall/verify). `generic` is the webhook as it was: the same
verification, the same delivery-id headers, no handshakes. Profiles exist for
GitHub, Stripe, Slack, Shopify, Twilio, Microsoft Graph, Meta and SNS.
Add Automation lists each under **App Webhooks**
(`EventSourceTemplate.providerWebhook`), the webhook editor has a **Sender**
picker (the generic verification controls are hidden for a named provider),
and the config document takes `source.provider`. Providers that issue their
secret (Stripe, Slack, Shopify, Twilio, Meta) get a paste-in **Signing
Secret** in the editor and on the detail, stored with
`EventSecretsKeychain.saveSecret`; `ensureWebhookSecret` never generates one
for them. Setup copy, icons and example bodies are on `WebhookProvider`
(`setupHint`, `verificationSummary`, `sampleBody`). No provider has a
`registration` yet, so the URL is pasted into the provider by hand.

### Uniqueness

Each delivery runs at most once per automation:

1. A source gives every occurrence a delivery id when it has one: the
   schedule slot, the webhook profile's delivery id, the channel event id, a
   mail `Message-ID`. The key is namespaced by source
   (`webhook:<id>`, `email:<connection>:<message-id>`).
2. `admissionRejection` checks it by the event's `delivery.dedupe`:
   `window(s)` against the in-memory window and then
   `EventRunDatabase.firstOccurrence` within `s`; `durable` against
   `event_seen_keys`, forever; `none` never. A repeat is ledgered as
   `duplicate` and answered 200 by the webhook.
3. Polling sources also keep a cursor per scope (advanced only after the
   batch is submitted) and may re-read an overlap window; the seen keys make
   the overlap harmless.
4. Run Now is never a duplicate. Two automations on the same source each run
   once (keys are per event). A run interrupted by quitting is closed as
   `cancelled` / `interrupted` at the next launch and is not re-fired: its key
   is already seen.

### n8n trigger coverage

How n8n's trigger nodes map onto the substrate. "Substrate" means no new
pipeline code: a descriptor, an adapter (or profile) and a config struct.

| n8n trigger group | Examples | Osaurus shape | Status |
| --- | --- | --- | --- |
| Time | Schedule, Cron, Interval | Schedule kind | Shipped |
| Local | Local File Trigger | Folder kind (FSEvents + fingerprints, persisted anchor) | Shipped |
| Generic inbound HTTP | Webhook, Form | Webhook kind, `generic` profile (a form is a workflow's in-app form or any form tool posting to the webhook) | Shipped |
| Chat | Telegram, Slack, Discord, WhatsApp messages | Channel message kind (Agent Channels) | Shipped |
| Provider webhooks | GitHub, Stripe, Shopify, Slack Events, Twilio, Jira, Linear, Typeform, Calendly… (~60% of the catalog) | Webhook kind + `WebhookProviderProfile` (verifier, handshake, ids) + `registration` over a connection | Shipped for GitHub, Stripe, Slack, Shopify, Twilio, Microsoft Graph, Meta, SNS (App Webhooks; URL pasted by hand). Others: a profile each; auto-registration to come |
| Push-then-fetch | Gmail (Pub/Sub), Microsoft Outlook / OneDrive (Graph), Google Drive | Webhook profile with `fetcher` + `oauth2` connection + `maintenance` renewals | Substrate; needs OAuth client ids |
| Polling | Email (IMAP), RSS, Google Sheets, Calendar, Airtable, Notion | `poll` scope + cursor + `durable` dedupe | RSS Feed kind shipped; Email shipped as a channel (IMAP and Mail app, over the same supervisor); others substrate |
| Streams | Kafka, MQTT, RabbitMQ, Redis, Postgres LISTEN, SSE, IMAP IDLE | `stream` scope with reconnect and heartbeat | Event Stream (SSE) kind shipped; others substrate, each needs a client |
| Internal | Error Trigger, n8n Trigger (activated / updated), Workflow Trigger, Activation Trigger | `RunFailedEventSource` over `.workflowRunFinished` and `finalize`; `AppEventsSource` over launch and `eventDidChange` | Shipped as Run Failed and App Event. A workflow calling another is a workflow step, not a trigger |
| Manual / chat | Manual Trigger, Chat Trigger | Run Now; Chat itself | Shipped |

### Adding a source kind

1. `EventSourceKind` case and a config struct; an `EventSource` case. Build
   and fix every exhaustive switch the compiler reports (summary, sample
   payload, `ConfigEvents` export/build, inspection detail).
2. A descriptor in `EventSourceDescriptor.swift` and its line in
   `EventSourceRegistry.descriptor(for:)`. Pick `dedupeMode` from the
   provider's ids: a stable id that can repeat after a restart is `durable`.
3. An `EventPayload` builder for the kind's payload root.
4. An adapter conforming to `EventSourceAdapter`, returned from
   `EventManager.makeAdapter(for:)`. Polling or streaming goes through
   `manager.runtime` (`SourceRuntimeSupervisor`), not its own timers.
   Persisted positions go in `event_source_state`; an occurrence's
   `dedupeKey` is namespaced by kind.
5. A connection type, if it needs an account (`SourceConnectionType` with
   its auth shape; secrets only in `SourceCredentialVault`).
6. A draft and editor section in `Views/Event/EventSourceEditors.swift`
   (`EventSourceDrafts`, `EventSourceEditor`) — the sheet itself does not
   change.
7. Settings catalog rows, the guide, and `SettingsSearchSelfFindProbe`
   labels for every new control (see AGENTS.md, "Settings catalog").
8. Tests: the registry suite (descriptor, adapter, payload root), the
   adapter's own suite with a fake fetcher, the config round trip, and a
   dedupe case that survives a relaunch.

The Automations list groups and the History chips come from the registry
(`listTitle` / `listSubtitle`, `historyChipTitle`), so a kind offered in the
picker is listed without view changes.

## Email (retired trigger; now a channel)

Email is an Agent Channel (`AgentChannelKind.email`, see
[AGENT_CHANNELS.md](AGENT_CHANNELS.md#email)), so agents can reply in the
thread. The `.email` source kind stays decodable but is retired:

- `EmailSourceDescriptor.isOfferedInPicker` is false and it has no History
  chip; `EventSourceRegistry.listKinds` still lists a stored one, whose
  editor shows `EmailSourceRetiredNotice`.
- `EmailEventSource` is a no-op adapter: no scopes, status `paused` with
  `retiredMessage`, Run Now `suppressed` (`email_trigger_retired`).
- `EmailAutomationMigration.runIfNeeded` (from `EventManager.start`, after
  `EventMigration`) rewrites each email event in place as a
  `.channelMessage` rule (kind `.email`, connection `email`, rooms
  `<connection>/<mailbox>`, channel delivery defaults, replies after
  approval) and merges its account into `email.json` (mailboxes unioned,
  shortest interval, unread-only only if all, body if any, longest body
  cap; sender filters join the sender allowlist; receive on if any migrated
  event was on). Cursors move from `email:<connection>:<mailbox>` to
  `emailchannel:<connection>:<mailbox>` when the new scope is empty.
  `email.json` is saved first; if that fails the automations are kept. A
  rewritten event has no email source, so the migration is idempotent
  without a marker.
- `ConfigEvents`: `source.kind: email` is dropped by
  `translatingLegacyEvents` with `retiredEmailNote`, and a direct build
  fails with it. Email events are outside `ConfigEventScope.automations`:
  never exported, never pruned.
- The run payload keeps `email.*`: `EmailChannelService` puts
  `EventPayload.emailFields(…)` in `ChannelInboundMessage.extraPayload`, so
  `{{email.subject}}` bindings of migrated rules still render.

The mail-reading pieces below are shared with the channel transport
(`EmailChannelTransportRuntime`):

- **Fetchers** (`MailboxFetching`, chosen by `MailboxFetcherFactory` from the
  connection type):
  - `IMAPMailboxFetcher` over `IMAPClient`, a small IMAP4rev1 client on
    Network.framework (TLS; plain TCP only to loopback, e.g. Proton Mail
    Bridge; no STARTTLS). It signs in with `LOGIN`, selects with `EXAMINE`
    (read-only) and fetches `BODY.PEEK[]`, so checking never sets `\Seen`.
    The cursor is `{uidvalidity, last_uid}`; a changed `UIDVALIDITY` re-bases
    at the mailbox's current end instead of replaying it. Bodies are capped
    at 256 KB per message, literals at 2 MB.
  - `MailAppMailboxFetcher` over `MailService` (AppleScript). The cursor is
    `{received, recent ids}`, re-reading a 120 s overlap. Mail returns the
    newest end of a listing, so a full page (100) is followed by one ending
    at its oldest row (`MailQuery.until`), up to 10 pages; past that the
    oldest mail of the burst is skipped and the position says so. Mail must
    be running; while it is closed the tick does nothing and the status
    says so. `AppleToolError`s are typed: -1743 (Automation not allowed) is
    `automationDenied` with the System Settings path, Mail quitting is
    `mailNotRunning`, anything else `mailApp(message)`.
    Microsoft 365 and Outlook.com accounts go through this fetcher: they
    no longer accept password `LOGIN` over IMAP, and there is no XOAUTH2
    (no OAuth client is registered). `IMAPConnectionConfig.passwordSignInNote`
    warns in the account sheet and is appended to a refused sign-in.
  - `EmailMIME` parses headers (RFC 2047 words, folded lines, dates),
    multipart bodies (text/plain preferred, HTML reduced to text), transfer
    encodings and charsets, and attachment names (RFC 2231).
- **Accounts** are `SourceConnection`s (`.imap` or `.mailApp`); the IMAP
  password is in `SourceCredentialVault` (also used for SMTP replies).
  Config documents never create one.

## Webhook HTTP contract

Bearer-exempt like `/channels/`: the URL token selects the event and the
event's own check authenticates the caller. Reachable through the agent relay
(`https://<agent-address>.agent.osaurus.ai/events/<token>`), which proxies to
the loopback server.

`POST /events/{token}`

| Check (in order) | Refusal |
| --- | --- |
| token matches an event | `404 not_found` (not ledgered) |
| event enabled | `409 event_disabled` |
| body ≤ `maxBodyBytes` (default 256 KB; the editor allows up to 10 MB) | `413 body_too_large` |
| the profile's handshakes (none for `generic`) | answered here, before auth, and not ledgered |
| the profile's verifier; for `generic`, `hmac_sha256` over the raw body (`X-Osaurus-Signature: sha256=<hex>`, header and prefix configurable) or `shared_secret_header` (`X-Osaurus-Event-Secret`) | `401 unauthorized` (`secret_unavailable` in the ledger when no secret is stored) |
| `rateLimitPerMinute` (default 60) | `429 rate_limited` |

Then the occurrence is submitted: `202 {run_id, status, status_url}` when it
runs or queues; `200` with `status: filtered | duplicate`; `429` for
`busy`/`queue_full`; `503` for any other suppression. Dedupe keys come from
`Idempotency-Key`, `X-Idempotency-Key`, `X-GitHub-Delivery`, `X-Request-Id`;
`X-Osaurus-Conversation` sets the conversation key. Every refusal for a known
event is a ledger row. Secrets live in `EventSecretsKeychain`.

`GET /events/{token}` answers only a profile's GET handshake (Meta
`hub.challenge`); anything else is `405` with `Allow: POST`, as before.
Responses carry the profile's content type (handshake echoes are
`text/plain`; everything else is JSON).

`GET /events/{token}/runs/{run_id}` returns `{run_id, status, fired_at,
reason?, error?, started_at?, finished_at?, workflow_run_id?}`; a run of
another event is `404 run_not_found`.

## Declarative config (`Configuration/Declarative/ConfigEvents.swift`)

Section `automations:` (`ConfigSectionID.automations`) — a list of
`EventEntry` matched by name. The pre-rename `events:` key decodes into the
same list; export writes `automations:` only. `export` →
`build` → `export` is the identity (tokens and secrets never exported);
`build` patches over the stored event (absent keys keep their values; a new
`source.kind` replaces the source). `delivery.dedupe` (`none` / `window` /
`durable`) is exported with `dedupe_window_seconds` only for `window`; a
document that sets only `dedupe_window_seconds` (the older shape) sets a
window, and one with neither keeps the stored mode. `source.kind: email`
is retired (dropped with a note; write `channels.email`). `plan` emits create/update/delete rows
with risks (`unsignedWebhook`, `channelAutoReply`, `deleteEvent` on prune)
and a duplicate-folder note. A prune of `agents:` that would orphan an event
is refused (`validatePruneAgentReferences`).

Legacy input is still accepted: `schedules:`, `watchers:` and
`channels.<platform>.{inbound_enabled, inbound_agent, require_mention,
continue_threads, auto_reply_enabled}` are folded into `automations:` by
`OsaurusConfigDocument.translatingLegacyEvents()` with a deprecation note
(idempotent; inbound keys with no event to patch and no agent are reported as
ignored). `osaurus_inspect` scope `automations` (aliases `events` /
`schedules` / `watchers`, accepted but not listed in the schema enum) reads
`EventInspection`.

## Migration (`EventMigration`)

On the first start with no `events/migration.json`:

- `schedules/*.json` → schedule events (same ids), run history → ledger rows
  (`running` closed as `cancelled`/`interrupted`, `skipped` → `suppressed`).
- `watchers/*.json` → folder events (same ids, one continuing chat).
- Each platform file's `inboundDispatch` and each n8n connection's →
  one channel event for the default target plus one per route (stable ids
  from connection + route; disabled config migrates disabled).
- Legacy files are renamed `*.json.migrated`; the marker records counts and
  notes. Existing events are never overwritten.

## UI (`Views/Event/`)

Sidebar: **Automations**, pinned at the top (`ManagementTab.automations`; the
raw ids `events`, `schedules`, `watchers` resolve to it).

- `EventsView` — two pages (`AutomationsPage`): **Automations** (the list,
  **Add Automation**, and the header's **History** button, which opens
  **Tasks → History** filtered to automations) and **Channel Messages**
  (`AutomationHistoryView`, from the header's ⋯ menu, which also holds
  Import/Export). The list shows one group per trigger kind; channel rules are
  not listed, only a note with their count and **Open Channels**. The Add
  Automation picker shows the registry's triggers, then **App Webhooks** (one
  webhook template per named provider), then a hint pointing to Channels for
  message rules.
- `AutomationHistoryView` (**Channel Messages**) — channel messages that never
  reached an automation (refused by an allowlist, failed, or claimed by no
  automation) and those taken as a workflow form's answer, each with the
  reason and the fix. Automation runs are not listed: they are tasks in
  Tasks → History. The rows come from the channel audit store through
  `AutomationHistoryFeed.merge(runs: [], audit:filter:)`; the page has a
  channel picker, Received / Denied / Duplicates tiles, refresh, and Copy
  redacted export (`AgentChannelAuditWorkbenchService.exportRedactedJSON`).
  Message rows show the guidance text and open Channels.
- `EventEditorSheet` (source templates, When / Only When / Do / Queue /
  Reply; each kind's section is in `EventSourceEditors.swift`; a stored
  email automation shows `EmailSourceRetiredNotice`), `EventDetailView`
  (overview with the source status, Run Now, Stop Runs, Webhook URL with
  relay URL and secret rotation, Runs ledger).
- Settings search rows: `automations.*` in `SettingsSearchIndex`
  (`automations.history` lands on the History tab via
  `ManagementStateManager.automationsSubTabRequest`).

## Tests

`Packages/OsaurusCore/Tests/Event/`:

- `EventMatcherTests` — channel tiers, aliases, mention gates, filters.
- `EventPipelineTests` — queue lanes, ledger retention and dedupe lookups,
  admission, cancellation, interrupted-run cleanup, missed schedule slots,
  folder convergence on a real temp folder.
- `EventWebhookIngressTests` — routing, HMAC / shared secret / fail-closed,
  body cap, rate limit, dedupe, busy/queue_full, run status, token rotation,
  ledgered refusals.
- `EventWorkflowActionTests` — input mapping and coercion, schema
  validation against an installed workflow, caller flags, outcome mapping,
  reply text, channel reply with workflow output.
- `EventMigrationTests` — conversions and an isolated end-to-end migration.
- `ConfigEventsRoundTripTests` — round trip per source kind, patching,
  validation messages, risks, diff lines, legacy translation, the pre-rename
  `events:` key.
- `AutomationHistoryFeedTests` — History merge order, source / status /
  channel filters, and the unclaimed-message audit row.
- `EventSourceSubstrateTests` — registry (every kind has a descriptor and
  an adapter, payload roots, defaults, History chips), dedupe policy decode
  and normalization, the v2 ledger tables, durable dedupe across ledger
  pruning and a relaunch, adapter dispatch on create / enable / disable /
  re-source / delete / launch, the folder anchor across a relaunch, and
  connection delete refusal.
- `SourceRuntimeSupervisorTests` — first tick, catch-up policies, submit
  before commit, backoff and its cap, `tickNow`, re-registration, stream
  reconnect, forced reconnect and heartbeat timeout, maintenance ticks.
- `FeedParserTests` — RSS 2.0, RDF, Atom, JSON Feed, item identity
  fallbacks, dates, HTML reduced to text.
- `RSSEventSourceTests` — first-tick baseline, new items oldest first, the
  per-tick cap, conditional request headers and 304, catch-up after a
  relaunch, durable dedupe, Run Now with the newest item.
- `SSEEventSourceTests` — frame parsing (multi-line data, comments, ids,
  retry, CRLF), `Last-Event-ID` resume, event-name filter, emitted payload,
  the 256 KB message cap.
- `RunFailedEventSourceTests` — workflow and automation failures, filters,
  the loop guard, test and nested runs, the payload.
- `AppEventsSourceTests` — launch, created on, turned on, edited, and a
  no-op save.
- `WebhookProviderProfileTests` — each verifier against a signature built
  the provider's documented way (GitHub, Stripe, Slack, Shopify, Twilio,
  Graph), replay windows, every handshake, delivery-id and event-type
  extraction, and the generic profile matching the webhook as it was.
- `Email/EmailMIMETests` — headers, encoded words, quoted-printable,
  multipart/alternative, attachments, charsets, HTML-only mail.
- `Email/IMAPClientTests` — response framing and literals over chunked
  reads, a scripted server session (capability, login, list, examine, UID
  search and fetch), timeouts, mailbox name encoding, and the fetcher's
  baseline, cursor and `UIDVALIDITY` re-base.
- `Email/EmailEventSourceTests` — the retired adapter (no scopes, paused
  status, Run Now suppressed, not in the picker); plus the Mail app fetcher.
- `Email/EmailAutomationMigrationTests` — email automations → Email channel
  rules, account merge, sender allowlist, cursor moves, idempotence.
