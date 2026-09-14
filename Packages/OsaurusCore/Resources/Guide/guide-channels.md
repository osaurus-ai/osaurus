---
title: Agent Channels
summary: Let agents read and post on Discord, Slack, Telegram, iMessage, and n8n — with strict allowlists.
order: 150
---

# Agent Channels

Channels (Beta) connect agents to your messaging platforms: Discord, Slack, Telegram, and iMessage (macOS), plus n8n and custom HTTP channels. Agents can read, draft, and — only with your consent — send messages.

## Setup

- Settings → Channels: add a connection per platform with native credential sheets (tokens go to the Keychain, never JSON).
- Slack uses a bot token with Socket Mode; Telegram uses a bot via long polling; Discord polls REST (plus Gateway for presence); iMessage uses a local helper downloaded from settings.
- iMessage needs Full Disk Access to read and Messages Automation consent to send.

## n8n

- Settings → Channels → n8n: a secret-verified webhook (`POST /channels/n8n/{id}/inbound`) with pollable replies. n8n sends an envelope; Osaurus answers with a task id to poll, or pushes the reply to an n8n Webhook trigger.
- The sheet has five steps in the order the pairing code needs them: *Name this channel* (connection id), *Who may speak* (allowlists), *How Osaurus replies* (which agent answers, optional push), *Connect n8n* (secret and pairing code), *Live check*.
- **Pair with n8n** (in *Connect n8n*) shows one copyable pairing code; a new channel gets a random secret automatically so the code is ready as soon as the id is typed. Paste it into the **Osaurus Channel** credential of the `@osaurus/n8n-nodes-osaurus` community node and press *Test*. The code carries every URL that reaches this Mac, the connection id, the channel secret, and the verification method; the node tries the URLs in order and keeps the first that answers `GET …/ping`. Treat the code like the secret.
- Remote or hosted n8n: bind a local agent in *How Osaurus replies* and enable that agent's Relay. The pairing code then includes the agent address and the public relay URL, and the node talks Secure Channel end-to-end — the relay cannot read prompts and the *Remote callers* plaintext toggle in *Connect n8n* stays off. Without a bound agent the node sends plaintext HTTP, which remote callers may only do when that toggle is on.
- *Connect n8n → Advanced* holds everything for workflows that use a plain HTTP Request node instead: the inbound and poll URLs per topology, the verification method and header override, sample envelope, HMAC Code node, curl, and the osk-v1 access key for the node's Agent resource.
- *Who may speak* is fail-closed: `conversation_id` and `sender.id` in each event must match the allowlists, or the node reports the event as rejected.

## Safety model

- Inbound is deny-by-default: only allowlisted spaces/rooms/senders reach an agent; bots and self are ignored unless explicitly allowed.
- Writes require the agent to pass `confirm_send: true` and the room to be on a write allowlist; broadcast mentions (@channel and similar) are blocked unless you allow them.
- Channel tools work only inside the app — external HTTP/MCP callers are denied.

## Proactive posting

- Agents → agent → Automation → Channel Posting plus Settings → Channels → Agent Posting.
- Modes: Off / Draft (writes land in an Outbox for review) / Confirm (asks each time) / Autonomous (sends directly — use sparingly).
- The Outbox (Settings → Channels → Outbox) holds drafts with mark-sent / retry / discard.

## Diagnostics

Each connection has a diagnostics view (connection state, recent events). Combine channels with Schedules for recurring digests posted as drafts.
