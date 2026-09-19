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
- n8n connects to Osaurus, not the other way around. The pairing code is the whole hand-off; the only n8n URL Osaurus ever stores is the optional *Outbound Webhook URL* under *Who answers?* for pushing replies.
- The sheet has five steps: *Name it* (display name; the connection id is filled from it), *Where is your n8n?* (This Mac / Docker Desktop / another machine on my network / Remote), *Who answers?* (which agent replies, Relay for that agent, optional push), *Pair* (the pairing code), *Prove it* (approve workflows, verify). The on/off switch for a saved channel is on its card in the channel list, not in the sheet.
- *Where is your n8n?* decides everything downstream: the single URL the pairing code carries (`127.0.0.1`, `host.docker.internal`, the LAN address, or the relay URL), whether Relay is required (Remote), whether the connection is end-to-end encrypted, and whether the *Allow plaintext HTTP from other machines* toggle is shown at all (LAN only).
- **Pair with n8n** (in *Pair*) shows one copyable pairing code only once it can work — for Remote that means a local agent is bound in *Who answers?* and its Relay reports connected; otherwise the card names the blocker and the step that clears it. A new channel gets a random secret automatically (under *Pair → Advanced*, with Rotate). Install the `@osaurus/n8n-nodes-osaurus` community node, paste the code into its **Osaurus Channel** credential and press *Test*. Treat the code like the secret. If you move n8n, change *Where is your n8n?* and copy the code again.
- *Pair → Advanced* holds everything for workflows that use a plain HTTP Request node instead: the inbound and poll URLs for the chosen location, the verification method and header override, sample envelope, HMAC Code node, curl, and the osk-v1 access key for the node's Agent resource.
- *Prove it → Who may speak* is approve-on-first-contact: run the workflow once and it appears as "Workflow *conversation_id* (sender *sender.id*) wants to use *channel* — Allow / Deny". Allow adds those ids to the allowlists and saves immediately; run the workflow again. Until then the node reports `pending_approval` and nothing reaches the agent. Allowlists stay fail-closed and can still be edited by hand under *Advanced*. Hand-typed allowlists do not suppress the prompt: a workflow whose conversation or sender does not match what you typed still shows up under *Who may speak* with Allow / Deny, alongside the existing chips.
- The first run of a new workflow also raises a toast with *Open Channels* when Settings is closed; repeats of the same conversation/sender do not. Pending requests and Deny decisions live only for the current app session — after a relaunch, run the workflow again and it reappears. Approved ids are saved in the allowlists and survive relaunch.
- Channels saved before this flow existed open with *Where is your n8n?* unanswered (unless plaintext was allowed, which only LAN offers). Pick it once; the existing n8n credential keeps working meanwhile, and the next Save stores the choice.

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
