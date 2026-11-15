---
title: Automations
summary: Schedules, folder watchers, webhooks (generic or from GitHub, Stripe, Slack and other services), RSS feeds, event streams, failed runs and app events that run a workflow, ask a model, or run an agent — each read as When → Do → Result, with workflow inputs bound to the trigger's values; every run is a task in Tasks → History.
order: 90
---

# Automations

An automation is **When** something happens → **Do** something → a **Result**: a **When** (a schedule, a folder change, a webhook call, a new feed item, a stream message, a failed run or an app event), an optional **Only When** filter, a **Do** (an agent, a workflow, or one answer from a model) and a **Queue** (where its runs wait while busy). Make as many as you like, each with its own instructions and options.

Channels and Automations split the work: **Channels** is messages people send to agents — what each channel receives, who answers (its **Routing** rules) and what it may send. **Automations** is everything that runs on its own: schedules, folders, webhooks, feeds, event streams, failure handlers and app events. Email is a channel (Channels → **Email**): mail from allowed senders reaches an agent, which can reply in the thread. Channel rules are not listed in Automations; when there are some, a note under the list says how many and links to **Open Channels**.

## Adding an automation

- Settings… (⌘,) → **Automations** (pinned at the top of the sidebar) → **Add Automation**, then pick **When**:
  - **Schedule** — at set times or intervals (once, every N minutes, hourly, daily, weekly, monthly, yearly, cron).
  - **Folder** — when files in a folder change (Include subfolders; Responsiveness sets the debounce: Fast ~200 ms, Balanced ~1 s, Patient ~3 s, Relaxed ~1 min, Deferred ~5 min, Extended ~10 min).
  - **Webhook** — when a URL is called, from this Mac or through the agent relay.
  - **RSS Feed** — when an RSS, Atom or JSON feed publishes a new item.
  - **Event Stream** — when a server-sent events (`text/event-stream`) endpoint sends a message.
  - **Run Failed** — when a workflow run (or, optionally, an automation's run) fails. n8n calls this the Error Trigger.
  - **App Event** — when Osaurus starts, when this automation is turned on, or when it is changed.
  - Under **App Webhooks**: a Webhook preset for **GitHub**, **Stripe**, **Slack**, **Shopify**, **Twilio**, **Microsoft Graph**, **Meta** or **Amazon SNS** (see Webhooks from a service below).
  - To answer channel messages or new email, use Channels → the channel (or **Email**) → **Routing** → **Add Rule** instead. A channel with several accounts (bots, workspaces, email accounts) has rules per account; a rule's **Edit…** sheet has an **Account** picker.
- **Do**: **Run Agent** (a custom agent or a shared workspace agent, plus instructions), **Run Workflow** (an installed workflow, with its **Inputs** bound to what started it), or **Ask a Model** (instructions and a **Model**, *Default model* unless you pick one: one answer with no tools and no agent, saved as a chat). Ask a Model is not offered on channel routing rules.
- Instructions (for an agent or a model) can insert the trigger's values with the **Insert a value from the trigger** menu, or by typing `{{…}}`: `{{text}}`, `{{event.name}}`, `{{fired_at}}`, `{{schedule.scheduled_for}}`, `{{folder.path}}`, `{{folder.changed_paths}}`, `{{webhook.body.<field>}}`, `{{webhook.query.<name>}}`, `{{feed.item.title}}`, `{{feed.item.link}}`, `{{sse.data}}`, `{{sse.event}}`, `{{failure.error}}`, `{{failure.workflow.name}}`, `{{failure.failed_step.name}}`, `{{app.reason}}` (rules on the Email channel add `{{email.subject}}`, `{{email.from}}` and the rest).
- An automation never runs the built-in Default agent (the Osaurus assistant). Pick a workflow when one does the job; **Ask a Model** for a text answer that needs no tools; a custom agent only when the work needs its tools.
- Or ask the Osaurus assistant: it creates and edits automations with `osaurus_config` (`automations:` section). It binds an installed workflow first, asks the Architect to build a workflow (with the trigger, created when you save it) when none fits, uses `instructions` alone for a tool-less answer, and names an existing custom agent only for tool work — it does not create an agent just for an automation.

## Workflow inputs

- With **Run Workflow**, **Inputs** lists every input the workflow takes, with its label, a **Required** badge and its key. **Bind to…** chooses where each value comes from: a value **From the trigger** (each shown with an example, such as *Scheduled time*, *Changed files* or a webhook body field like *Body: issue.title*), a **Custom template…** mixing text and values (`New issue: {{webhook.body.issue.title}}`), a **Fixed value…**, or **Leave empty** for optional inputs. **Run as** picks whose keys and sessions the run uses: **No agent (shared keys)**, the default, uses the shared keys in the Vault; a custom agent uses its own values where it has them.
- Picking a workflow fills the inputs in: values named like the trigger's (a `files` input gets the changed files), `{{text}}` for the first other text input, and each required input's default as a fixed value. **Sample run:** under each input shows the value a run would get.
- Required inputs must be bound: the run does not fill defaults, so an unbound one fails every run. The editor marks it (**Choose a value: the workflow needs it.**) and Save is blocked until it is bound; the detail lists it as **Not set (required, runs will fail)**. In an `osaurus_config` document, a required input left out of `input` takes its schema default; one with no default must be bound, or the plan is refused.
- A binding that is the whole input passes the raw value (a JSON object stays an object); values are converted to the type the workflow declares.

## Only When (optional)

Narrow when an automation runs: **Text contains any of / all of**, **Senders** (ids or handles; on the Email channel, an address or `@domain`), **Changed file matches** (globs such as `*.pdf`, folder automations), and **Payload conditions** (`webhook.body.action = opened`). Who may reach a channel at all is still the channel's own sender allowlist.

## Webhooks

- The automation's detail shows its **Webhook URL**: `http://127.0.0.1:<port>/events/<token>` on this Mac, and `https://<agent-address>.agent.osaurus.ai/events/<token>` once an agent's Relay is connected. **Rotate URL** retires the old token at once.
- **How does the sender prove it's them?** (in the editor): *HMAC-SHA256 signature* (recommended and the default — the sender computes an HMAC-SHA256 of the raw body keyed with the secret and sends `sha256=<hex>` in `X-Osaurus-Signature`), *Shared secret header* (the secret itself in `X-Osaurus-Event-Secret`), or *URL token only* (no check). **Advanced** sets the header name — leave it empty for the default; GitHub needs `X-Hub-Signature-256` — and the limits below.
- Osaurus creates the secret when you save. The detail's **Webhook URL** card shows it (**Show** / copy / **Rotate Secret**), explains what the sender must send, and has **Try it**: a ready-to-run `curl` command (copied with the secret filled in) that calls the automation on this Mac. The secret is kept in the Keychain and never exported.
- **What does the sender post?** (in the editor): paste an example of the body the sender posts. Its JSON fields become trigger values (*Body: issue.title* → `{{webhook.body.issue.title}}`) for the instructions and workflow inputs, **Run Now** sends it, and **Try it** uses it.
- Limits per automation: max body (256 KB default) and calls per minute (60 default). JSON bodies are parsed, form bodies become fields; auth, cookie, token and signature headers never reach the agent.
- Responses: `202` with `run_id` and `status_url` (poll `GET /events/<token>/runs/<run_id>`), `200` when filtered or a repeat, `401` bad signature, `409` automation off, `413` body too large, `429` rate limited or busy.
- Repeats are dropped by delivery id (`Idempotency-Key`, `X-GitHub-Delivery`, `X-Request-Id`) within the duplicate window. Send `X-Osaurus-Conversation: <id>` to keep one chat per conversation.

## Webhooks from a service

- **Add Automation → App Webhooks** picks a service; on any Webhook automation the same choice is **Sender**. A service is checked the way it signs (GitHub `X-Hub-Signature-256`, `Stripe-Signature`, `X-Slack-Signature`, Shopify `X-Shopify-Hmac-Sha256`, `X-Twilio-Signature`, Graph `clientState`, Meta `X-Hub-Signature-256`; SNS has no signature check), so the verification choices are hidden. Setup handshakes are answered for you: Slack's URL check, Graph's validation token, Meta's hub challenge, and SNS subscription confirmation.
- **Signing Secret**: Stripe, Slack, Shopify, Twilio and Meta issue their own secret. Paste it in the editor, or later in the detail's **Webhook URL** card (**Save**). It is kept in the Keychain; until it is saved, requests are refused. GitHub and Microsoft Graph use the secret Osaurus creates (give it to GitHub as the webhook secret, or to Graph as `clientState`).
- Each service starts with an example body, so its fields are trigger values right away and **Run Now** sends it. **Try it** is replaced by the service's own test or redeliver button. Twilio and SNS need the relay URL: Twilio signs the public address.
- The service's delivery id drops repeats, and its event type fills `{{webhook.event_type}}` (for example GitHub's `X-GitHub-Event`).

## Feeds and event streams

- **RSS Feed**: **Feed URL** (RSS 2.0, RSS 1.0/RDF, Atom or JSON Feed), **Check Every** (15 min default), **Items per Check** (20 default; older items in a burst are skipped) and **After a Restart** (*Only the newest* by default, *Everything since last check*, or *Skip what arrived while closed*). The first check notes what is in the feed now and runs nothing; each item published later runs the automation once, oldest first, even after a restart (the item's id is remembered). Osaurus sends `If-None-Match` / `If-Modified-Since`, so an unchanged feed costs one small request. **Run Now** uses the feed's newest item.
- **Event Stream**: **Stream URL**, **Event Names** (the SSE `event:` names that run it; empty = every message), **Request Headers** (stored and exported as written — not for secrets) and **Reconnect When Silent** (0 = off). Osaurus stays connected while the automation is on, reconnects with backoff after drops, and sends `Last-Event-ID` so the server can resume. A JSON `data:` becomes fields (`{{sse.data.<field>}}`); other text is `{{sse.data}}`. A message over 256 KB is skipped (the stream stays connected and the detail notes the skip). The detail shows **Connection** and the last event id as **Position**.
- Feed and stream text comes from outside, so an agent (or the model, for Ask a Model) sees it marked as untrusted content.

## Run failed and app events

- **Run Failed**: pick **Workflows** (none picked: any workflow) and, if you want, **Also when an automation's run fails** (automations that run an agent). The failure's values: `{{failure.error}}`, `{{failure.workflow.name}}`, `{{failure.failed_step.name}}`, `{{failure.automation.name}}`, `{{failure.run_id}}`, `{{failure.kind}}` (`workflow_run` or `automation_run`), `{{failure.caller}}`. Runs a Run Failed automation starts never start it again, test runs are not reported, and a step nested in another workflow is reported through the outer run unless that workflow is picked by name.
- **App Event**: **Run when** *Osaurus starts*, *This automation is turned on* (including created on), and/or *This automation is changed* (saved with changes while on; a save that changes nothing runs nothing). `{{app.reason}}` is `app_launched`, `automation_enabled` or `automation_updated`.

## Email moved to Channels

Email used to be a **When** here. It is now a channel, so agents can also reply in the thread: see Channels → **Email**. At the first launch after the update each email automation becomes a rule on the Email channel (same mailboxes, same agent or workflow, replies *After approval*), its account options and position move to the channel, and its sender filter becomes the channel's **Allowed Senders**. An email automation that could not be moved stays in the list, never checks mail, and says where mail went.

## Queue

The editor reads **When → Only When → Do → Queue**. In **Queue**:

- **Queue**: where its runs wait for a free slot — **Default**, or a queue you made with **Developer Tools → Tasks → Add Queue**. The picker appears once a second queue exists. The queue's **Max Concurrent Tasks** (Default: 20) caps how many tasks on it run at once, across every automation, background chat and plugin dispatch on that queue; each agent still runs at most 5 tasks at a time.
- **Allow Overlapping Runs**: off (the default) runs one at a time. On, runs overlap; for webhooks with conversation keys, different conversations run side by side, each in order.
- **Ignore repeats within** N minutes, and for schedules **If the App Was Closed** — *Run once on launch*, *Skip*, or *Run every missed time* (each missed slot once, newest 24 at most).

Older config files' `delivery:` (`mode`, `max_concurrent`, `max_queued`) still apply; `delivery.queue` names a queue by slug and `delivery.allow_overlapping_runs` sets the toggle. Every run is a task: see **Tasks** for what is running, waiting, or done.

Channel rules (edited from a rule's **Edit…** in Channels → Routing) that run an agent always answer one reply at a time per conversation, with different conversations answered side by side, so there is no Runs choice. **Hold up to N messages while it's replying** sets how many new messages in a busy conversation wait for the next reply (0 = skip them; Tasks → History shows `conversation_busy` or `conversation_queue_full`). **Add follow-up messages to a running reply** folds a new message into the reply already in progress; off, it waits its turn.

## History and runs

- The list is grouped into **Schedules**, **Folder watchers**, **Webhooks**, **Feeds**, **Event streams**, **Failure handlers** and **App events**, each with a count (plus **Email** while an email automation that could not be moved remains); the search in the header matches name, source and target. Each row reads *trigger → what it runs → result* ("Every day at 8:00 → Research Agent → New chat each run") with the next run, last result and whether it is running; click it for the detail, whose **When / Do / Result** card also lists each workflow input's binding. **Run Now** (the play button on hover, the row's menu, or the detail's footer) runs an automation immediately (even when off; webhooks run with their sample body, or an empty JSON body; feeds with their newest item; Run Failed and App Event with an example).
- **History** in the header opens **Tasks → History** filtered to automations: every run, newest first, with how it ended (**Ran / Skipped / Failed**). Each run is a task; its detail has the timeline, the chat or workflow run, and **Stop** while it runs.
- **Automations → ⋯ → Channel Messages** lists the channel messages that never reached an automation — refused by an allowlist, failed, or claimed by no automation (no automation for the channel or room, mention required, no alias matched) — each with the reason and the fix. Messages that answered a workflow's form over the channel show as *Form answer*, with what the answer did. Pick one channel and see **Received / Denied / Duplicates** counts. **Copy redacted export** copies a redacted JSON bundle for support; **Open** on a message opens that channel's settings.
- **Runs** on an automation's detail lists its recent tasks with status and reason — including ones that were filtered, repeats, refused (bad signature, rate limit, queue full) or cancelled; each opens the task's detail, with the chat or workflow run. **Stop Runs** cancels queued and running runs.
- If the agent, workflow, channel or account an automation uses is deleted, the automation is kept but marked **Needs attention**, its detail names what is missing, and each start is skipped with `agent_deleted`, `workflow_deleted`, `channel_deleted` or `connection_deleted` until you pick another one in **Edit**.
- The detail's **When** step shows what the trigger last reported, when it has something to say: **Last check** and **Next check**, **Connection**, **Position** (how far it has read), **Provider setup**, and **The source reported a problem** with the error.
- Schedule and webhook automations start a new chat per run by default; folder automations keep one chat (the follow-up pass after an agent changes files builds on it); channel rules keep one chat per conversation. **Start a new chat every time** overrides this.
- Folder runs converge: after the agent finishes, the folder is checked again and, if the agent itself changed files, the automation runs a follow-up pass (at most 5), so an organizer cannot re-trigger itself forever. Only file metadata is read for change detection. Osaurus remembers the folder's last state across quits: files that changed while it was closed start one run at the next launch. Turning the automation off, or pointing it at another folder, starts over from the folder as it is then.

## Import, export, migration

- **Export Automations…** / **Import Automations…** (the ⋯ menu next to Add Automation) write and read the `automations:` section as a config document; webhook secrets and tokens are not included. Channel rules, Email's included, export with Channels (`channels.<platform>.routing`); entries with `source.kind: email` are ignored on import with a note pointing to `channels.email`.
- On first launch after the update, schedules (with their run history), watchers and each channel's routing become automations with the same behavior; the channel ones are the rows of each channel's Routing table. The older `events:`, `schedules:` and `watchers:` config sections are still accepted and translated into `automations:`; `channels.<platform>.inbound_*` keys and `automations` entries with `source.kind: channel_message` become `channels.<platform>.routing` rules, each with a deprecation note. Email automations become Email channel rules at launch (see Email moved to Channels above).

## Notes

- Automations only run while Osaurus is running.
- Write idempotent instructions ("skip files already in a subfolder") so repeat runs are harmless.
- A workflow's **Reply** step posts only when a channel message started the run (a Channels → Routing rule). Run from a schedule, folder or webhook, or by an agent's tool call, it does not fail: it outputs `sent: false` with `reason: no_conversation`.
- A channel rule's workflow run that was running or waiting on a form when Osaurus quit is followed again at the next launch: its row stays open until the run ends, and the rule's final post still goes out. Other runs left open are closed as `interrupted`.
- Agent self-scheduling (`schedule_next_run`) is separate: see Agent Database and Self-Scheduling.
