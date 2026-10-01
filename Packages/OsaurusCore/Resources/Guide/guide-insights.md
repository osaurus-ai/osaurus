---
title: Insights and the Activity Log
summary: Review every interaction on this Mac — local or cloud — filter it, verify it has not been altered, and export it for outside review.
order: 175
---

# Insights and the Activity Log

Insights is the audit dashboard. Every interaction Osaurus performs is recorded as one row, persisted on this Mac, and marked **Local** (data stayed on this Mac) or **Cloud** (data left this Mac). Open it from Settings… (⌘,) → Insights, from Privacy → Activity Log → **Review Activity in Insights**, or from the Insights button on any assistant message (which jumps to that turn's row).

## What gets recorded

- **Inference** — every model request from Chat, agents, schedules, watchers, channels and plugins, whether it ran on a local model or went to a cloud provider / workspace agent. Includes model, tokens, speed, finish reason, tool calls, the prompt, the request/response payloads, and whether the Privacy Filter redacted anything before sending. Hidden one-shots (chat titles, follow-up suggestions, memory distillation, transcription cleanup) appear here with an `/internal/…` path and a plain-language label.
- **Compaction** — hidden conversation-summary generations, with the same detail as inference.
- **Web search** — the query, which providers were tried and which one answered, the result count, and the destination host (DuckDuckGo, Brave, Tavily, Osaurus Router hosted search…).
- **URL fetch** — pages fetched for `search_and_extract` / readability, either directly from this Mac or through the Osaurus Router.
- **MCP tool** — tool calls forwarded to an MCP server (arguments, result preview, transport). Local stdio servers are **Local**; HTTP servers are **Cloud**.
- **Channel** — messages delivered to Slack, Discord, Telegram, WhatsApp, iMessage, n8n or a custom webhook — both proactive posts (`PUBLISH`) and automatic replies to incoming messages (`REPLY`). Metadata only (destination, room, size, outcome, attachments sent) — the message text is not copied into the log.
- **Router** — Osaurus Router control-plane calls (workspaces, credits, media, pairing, account).
- **API** — inbound requests to the local HTTP server from API clients and paired peers, with the caller address.
- **Plugin call / Plugin log** — host API calls and log lines from installed plugins (log lines are hidden until you enable **Show plugin console logs** in the Filter popover).
- **Embedding** — each local embedding batch used for memory recall, memory indexing and tool / skill search, and `/v1/embeddings` API calls. Counts and sizes only; the embedded text is never stored.
- **Transcription** — each dictation session (live) or audio file transcribed on this Mac, with the transcript, audio length and model.
- **Speech** — each spoken reply (Read Aloud or the `speak` tool), with the text spoken, voice, audio length and engine. On-device Pocket TTS is **Local**; an OpenAI-compatible TTS server is **Cloud**.
- **Media** — each image or video job: prompt, size, steps, output count, job id and provider. Local MLX jobs are **Local**; Venice is **Cloud**; Osaurus Cloud media is recorded as a Router row.
- **System** — chain-of-custody events about the log itself (see below). Pick the **System** scope tab to see only these.

Delegated subagents and Computer Use / AppleScript helper steps are shown with source **Agent** and share the parent turn's id, so you can follow a delegated task from the parent turn to every helper step.

## Not captured

The log records interactions, not every byte on the wire. These do **not** produce rows: cloud-provider model-list and Test connection probes, provider / MCP sign-in (OAuth) flows, MCP capability probes, pages the managed browser loads during Browser Use, channel polling and incoming-message receipt, workspace handshake and keep-alives, theme fetches, skill / plugin / sandbox package downloads, and local tool side effects (file edits, shell commands, clicks). Anonymous usage analytics, crash reports, app updates and model downloads are separate consent switches under Privacy → Data Collection.

## Reading the dashboard

- The glance strip at the top shows four numbers for the current filter: **Events**, **Left this Mac** (Cloud rows and their share), **Failed** and **Privacy-filtered**. Click the last three to narrow the list to just those rows; click again to undo. Below it a local/cloud bar and a **destinations** disclosure list every host that received data, with request counts and bytes — click one to filter by it.
- The toolbar is one row: search, a time range control (Today, 7 days, 30 days, All time), and **Filter**, which opens a popover for Local/Cloud, status, source (Chat UI, Agent, HTTP API, Schedule…), destination, model, privacy-filtered only and plugin console logs. Every active criterion appears as a removable token under the row; **Clear all** resets them.
- The scope tabs group the categories: **All**, **Models** (inference, compaction, embedding), **Web** (search, URL fetch), **Tools** (MCP, plugin calls and logs), **Channels**, **API** (inbound API, Router), **Audio & Media** (transcription, speech, media) and **System**. Filters apply to the list, the glance strip and Export.
- Rows are grouped by day with the day header pinned while you scroll. Each row shows the time, a category glyph, the title with a secondary line (category · agent · destination), the source and the duration. Failed rows get a red dot and a red title; everything else stays quiet. Use ↑/↓ to move between rows.
- Click a row to open its detail. In a wide window it opens as an inspector beside the list so you can click through rows (Escape or × closes it); in a narrow window it replaces the list and **Back** returns. The detail shows **Overview** (key facts, one plain-language sentence, then collapsible **Where it went**, **Who drove this**, **Generation settings** and **Integrity** groups — each with a one-line summary while collapsed; long ids are shortened and copy on click), **Prompt** for chat-shaped rows, and **Raw** for the request and response bodies (with a Server / Local sub-toggle when a wire capture exists). **Copy** in the header copies any captured body.
- Rows written while **Store Prompts and Responses** was off show a "content withheld" marker instead of bodies; metadata is always present.
- Rows appear in the list immediately and are written to disk a moment later; after a hard crash the last few rows may be missing from the persisted log.

## Limits

- Prompt, response and wire bodies are kept up to 256 KB each; longer bodies end with a "truncated" note and the original size.
- Per-row detail values (queries, previews, URLs) are kept up to 2 KB each, at most 32 per row.
- Credentials are scrubbed before anything is stored: Bearer tokens, `sk-…` keys, JWTs, API-key headers and workspace attestations are replaced with `<redacted>`.
- Secret-setting tool arguments and all Agent Channel tool arguments are replaced with a redaction marker.

## Verify

Every record is chained to the previous one with SHA-256 (`hash = SHA-256(prevHash + "\n" + canonical JSON of the record)`). **Verify Integrity** (in the **⋯** menu next to Export) walks the whole log and reports the record count, the head hash, and any broken links, gaps or edits. A log that passes Verify has not been modified since it was written. Running Verify is itself recorded as a System row.

The log is tamper-**evident**, not tamper-proof: someone with write access to your home folder could rewrite the whole chain. For outside assurance, export regularly and keep the manifest's head hash somewhere else.

## Export

**Export** writes the current filter (or everything) as:

- **JSONL** — a manifest line (export time, filters, record count, head hash, whether the chain was intact, and the exact hash recipe) followed by one canonical record per line, so a reviewer can re-verify the chain without Osaurus.
- **CSV** — one row per record for spreadsheets (no bodies).
- **Markdown** — a readable report.

Choose whether to include prompt/response bodies; metadata-only exports are safe to share more widely. Each export is recorded as a System row with the format, record count, file name and head hash.

## System rows (chain of custody)

Everything done *to* the log is on the log:

- **Cleared** — you pressed Clear; how many rows were removed.
- **Pruned** — retention removed rows older than the cutoff; how many, and the new chain anchor.
- **Verified** — a Verify run; records checked, head hash, problems found.
- **Exported** — an export; format, records, content included or not, file name, head hash.
- **Settings changed** — retention or content policy changed; old and new values.
- **Recovered** — on open, the chain head file disagreed with the database (crash, restored backup, or tampering); both sequence numbers are recorded and the log continues from the database.

## Settings

Retention and content policy live under Settings… (⌘,) → Privacy → **Activity Log**:

- **Keep Activity History** — 7 days, 30 days (default), 90 days, 1 year, or Keep forever. Older records are pruned automatically (at launch, every six hours, and when the setting changes).
- **Store Prompts and Responses** — on by default. Turn off to keep metadata only for new records; records already written are not rewritten.
- **Review Activity in Insights** — jumps to the dashboard.

**Clear Activity Log** (in the **⋯** menu on the Insights page) deletes every row, moves the chain anchor forward and writes one **System** record noting that the log was cleared, so the log still verifies afterwards and the clearing itself is visible to a reviewer.

## Storage

`~/.osaurus/activity/activity.sqlite` (plus an `activity.head` sidecar with the chain head). Covered by the same at-rest encryption and backup controls as the rest of `~/.osaurus` (General → Advanced → Data & Storage).
